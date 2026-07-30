## Classifies the stderr of the ssh master process and translates it into
## explanations a beginner can understand.
##
## This is the part of powarder that most strongly delivers on its promise of
## "simplicity". Raw ssh error messages (full of jargon, requiring ssh/network
## knowledge to pinpoint the cause) are converted into "what happened" and
## "what to do next".
##
## This module performs no I/O whatsoever. It does not import `std/asyncnet`,
## `std/osproc`, or `std/os`. Determining `Lang` (e.g. reading the `LANG`
## environment variable) is I/O, so that is the caller's responsibility; this
## module only does "given a fixed `Lang`, return fixed wording".

import std/strutils
import std/sequtils

# ---------------------------------------------------------------------------
# String constants to match against
#
# If an OpenSSH version bump changes the wording, check and fix these first.
# The source actually verified for each is noted in its comment.
# ---------------------------------------------------------------------------

const
  msgAddressInUse = "Address already in use"
    ## The body (strerror(EADDRINUSE)) of the `error("bind [%s]:%s: %.100s", ...)`
    ## that `channel_setup_fwd_listener_tcpip()` in channels.c emits when bind(2)
    ## fails. The prefix (the `bind [addr]:port:` part) varies with the address
    ## notation, so only the strerror wording is matched.

  msgPermDeniedPubkey = "Permission denied (publickey"
  msgPermDeniedPassword = "Permission denied (password"
    ## sshconnect2.c: `fatal("%s@%s: Permission denied (%s).", user, host, authlist)`.
    ## The `%s` holds a comma-separated list of the remaining auth methods (e.g.
    ## `Permission denied (publickey).` / `Permission denied (publickey,password).`).

  msgTooManyAuthFailures = "Too many authentication failures"
    ## auth.c: the string that `auth_maxtries_exceeded()` sends as the
    ## disconnect reason via
    ## `ssh_packet_disconnect(ssh, "Too many authentication failures")`.
    ## On the client side, packet.c prints it to stderr as
    ## `Received disconnect from <host> port <port>:<code>: Too many authentication failures`.

  msgPermDeniedPubkeyKbdInteractive = "Permission denied (publickey,keyboard-interactive"
  msgPermDeniedPubkeyPassword = "Permission denied (publickey,password"
    ## Same underlying implementation as `msgPermDeniedPubkey` above, but the
    ## specific case where the remaining auth-method list **starts with publickey
    ## and has only interactive methods left after it**. Under BatchMode, ssh
    ## cannot show any prompt to attempt these interactive methods (see below),
    ## so this string alone is enough to identify "publickey didn't work, and
    ## nothing but an interactive prompt can get us further".

  msgHostIdentificationChanged = "REMOTE HOST IDENTIFICATION HAS CHANGED"
    ## One line of the warning banner emitted by `warn_changed_key()` in
    ## sshconnect.c (`@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @`).
    ## The host key registered in known_hosts differs from the key actually
    ## presented -- the most critical case, since it may indicate a MITM attack.

  msgRevokedHostKey = "REVOKED HOST KEY DETECTED"
    ## The warning banner emitted by the `HOST_REVOKED` branch of
    ## `check_host_key()` in sshconnect.c (`@ WARNING: REVOKED HOST KEY DETECTED! @`).
    ## Treated on par with `msgHostIdentificationChanged` as a serious warning
    ## about host key trust.

  msgHostKeyVerificationFailed = "Host key verification failed"
    ## sshconnect2.c: `verify_host_key_callback()` emits
    ## `fatal("Host key verification failed.")`. Every path where
    ## `check_host_key()` returns failure converges here, so this line alone
    ## cannot pin down the cause (it is judged together with `msgStrictChecking`
    ## below).

  msgStrictChecking = "requested strict checking"
    ## Part of the explanation appended by the `HOST_NEW` / `HOST_CHANGED`
    ## branches in sshconnect.c when rejecting due to
    ## `StrictHostKeyChecking=yes` (e.g.
    ## `Host key for <host> has changed and you have requested strict checking.`).
    ## When this wording **is present**, the stderr itself tells us the cause is
    ## the StrictHostKeyChecking setting. Conversely, when
    ## `msgHostKeyVerificationFailed` appears **alone without** this wording, we
    ## can conclude that `confirm()` in sshconnect.c saw `options.batch_mode`,
    ## printed nothing, and rejected immediately (unable to ask interactively
    ## whether to accept the new host's key).

  msgRemoteForwardFailed = "remote port forwarding failed for listen"
    ## ssh.c: `client_global_request_reply_fwd()` emits this as either
    ## `logit("Warning: remote port forwarding failed for listen port %d", ...)` or
    ## `fatal("Error: remote port forwarding failed for listen path %s", ...)`.
    ## Every combination of Warning/Error and port/path shares the same cause
    ## (the remote side refused the bind -- usually because `GatewayPorts no`
    ## on the remote sshd disallowed the requested bind_address), so only the
    ## common substring is matched.

  msgAdministrativelyProhibited = "administratively prohibited"
  msgOpenFailed = "open failed"
    ## channels.c: the return value of `reason2txt()` when a channel open
    ## request is rejected by remote policy (`AllowTcpForwarding no` /
    ## `PermitOpen` mismatch), plus the accompanying msg string the server
    ## sends. In practice both appear together, e.g.
    ## `channel N: open failed: administratively prohibited: open failed`
    ## (the msg is always the fixed string "open failed" too, due to how the
    ## server implementation works -- this looks redundant but is confirmed by
    ## empirical testing to be the actual form).

  msgUnknownHostResolve = "Could not resolve hostname"
    ## ssh.c: emitted by the `resolve_host()` family as
    ## `fatal("%s: Could not resolve hostname %.100s: %s", ...)`. The trailing
    ## `%s` holds the getaddrinfo(3) error string (gai_strerror), whose wording
    ## varies by OS libc implementation (see `msgUnknownHostGlibc` /
    ## `msgUnknownHostBsd` below).

  msgUnknownHostGlibc = "Name or service not known"
    ## glibc's wording for gai_strerror(EAI_NONAME). Occurs on Linux.

  msgUnknownHostBsd = "nodename nor servname provided"
    ## macOS/BSD libc's wording for gai_strerror(EAI_NONAME)
    ## ("nodename nor servname provided, or not known").

  msgConnectionRefused = "Connection refused"
  msgTimeoutLinux = "Connection timed out"
  msgTimeoutBsd = "Operation timed out"
    ## All three come from the `strerror(errno)` part of sshconnect.c:
    ## `error("ssh: connect to host %s port %s: %s", host, strport,
    ##     errno == 0 ? "failure" : strerror(errno))`.
    ## ECONNREFUSED's wording doesn't vary across OSes, but ETIMEDOUT does:
    ## Linux glibc returns "Connection timed out" while macOS/BSD libc returns
    ## "Operation timed out", so both are defined as constants.

type
  ErrorKind* = enum
    ekPortInUse, ekAuthFailed, ekGatewayPortsDisabled, ekUnknownHost,
    ekConnectionRefused, ekTimeout, ekHostKeyChanged, ekForwardingDenied,
    ekBatchModeNoAuth, ekUnknown

  Lang* = enum langEn, langJa

  ErrorContext* = object
    ## Information used to fill host names, port numbers, etc. into the
    ## translated text. powarder always runs with BatchMode=yes fixed, so
    ## `interactiveAuthUnavailable` is expected to always be true, but it is
    ## kept as a field for tests and future extension.
    host*: string ## The Host alias from ~/.ssh/config
    bindPort*: int ## The port powarder / the remote side tried to bind
    targetHost*: string ## The forward destination host name
    targetPort*: int ## The forward destination port
    rawStderr*: string ## Used to present the raw stderr as-is for `ekUnknown`

  Explanation* = object
    summary*: string    ## One-line explanation of the cause
    hints*: seq[string] ## Candidate remedies (may include example commands)

proc initErrorContext*(host = ""; bindPort = 0; targetHost = ""; targetPort = 0;
                       rawStderr = ""): ErrorContext =
  ## Helper to build an ErrorContext specifying only the fields you need.
  ErrorContext(host: host, bindPort: bindPort, targetHost: targetHost,
               targetPort: targetPort, rawStderr: rawStderr)

proc classify*(stderr: string): ErrorKind =
  ## Classifies the stderr of the ssh master process (the whole multi-line
  ## log is expected to be passed in).
  ##
  ## **Prefer the most specific classification, not the last line emitted.**
  ## ssh often prints the course of a failure across multiple lines (e.g.
  ## ending in `Permission denied` after repeated auth attempts, or a host key
  ## warning banner followed by `Host key verification failed.`). Looking only
  ## at the last line tells you nothing more than "it failed in the end" and
  ## misses the specific cause that matters most to the user. So the
  ## following priority order picks "the classification most directly useful
  ## for remediation, among all that could match".
  ##
  ## Priority order (checked top to bottom, first match wins):
  ## 1. `ekHostKeyChanged`
  ##    -- The `REMOTE HOST IDENTIFICATION HAS CHANGED` or
  ##       `REVOKED HOST KEY DETECTED` banner is present. This is the most
  ##       critical warning, since it may indicate a MITM attack, so it takes
  ##       priority over every other judgment rather than being casually
  ##       classified as, say, "an interactive-auth problem" (a deliberate
  ##       fail-safe design choice).
  ## 2. `ekBatchModeNoAuth`
  ##    a. `Permission denied (publickey,keyboard-interactive` /
  ##       `Permission denied (publickey,password` -- the specific case where
  ##       publickey auth didn't work and only interactive methods remain.
  ##       Since powarder always runs with BatchMode=yes, this alone is enough
  ##       to conclude "failed because it couldn't go interactive".
  ##    b. `Host key verification failed` is present, but neither the banner
  ##       from case 1 nor the `requested strict checking` wording (an
  ##       explicit rejection from StrictHostKeyChecking=yes) is present.
  ##       Based on the OpenSSH source (`confirm()` in sshconnect.c), when
  ##       BatchMode prevents asking interactively whether to accept an
  ##       unknown host key, no confirmation message is printed at all --
  ##       `confirm()` just returns 0, leaving only this one line behind. This
  ##       is the basis for treating a lone, unexplained
  ##       "Host key verification failed" as originating from BatchMode.
  ## 3. `ekAuthFailed` -- a plain `Permission denied` / `Too many authentication failures`.
  ## 4. `ekPortInUse` -- the local-side bind failed.
  ## 5. `ekGatewayPortsDisabled` -- the remote-side bind failed (specific to `-R`).
  ## 6. `ekForwardingDenied` -- the channel open itself was rejected by remote policy.
  ## 7. `ekUnknownHost` -- name resolution failed.
  ## 8. `ekConnectionRefused` -- rejected at the TCP level.
  ## 9. `ekTimeout` -- unreachable.
  ## 10. `ekUnknown` if none of the above match.
  if msgHostIdentificationChanged in stderr or msgRevokedHostKey in stderr:
    return ekHostKeyChanged
  if msgPermDeniedPubkeyKbdInteractive in stderr or
      msgPermDeniedPubkeyPassword in stderr:
    return ekBatchModeNoAuth
  if msgHostKeyVerificationFailed in stderr and msgStrictChecking notin stderr:
    return ekBatchModeNoAuth
  if msgPermDeniedPubkey in stderr or msgPermDeniedPassword in stderr or
      msgTooManyAuthFailures in stderr:
    return ekAuthFailed
  if msgHostKeyVerificationFailed in stderr:
    # Reaching here only happens when msgStrictChecking is also present (see above).
    return ekHostKeyChanged
  if msgAddressInUse in stderr:
    return ekPortInUse
  if msgRemoteForwardFailed in stderr:
    return ekGatewayPortsDisabled
  if msgAdministrativelyProhibited in stderr or msgOpenFailed in stderr:
    return ekForwardingDenied
  if msgUnknownHostResolve in stderr or msgUnknownHostGlibc in stderr or
      msgUnknownHostBsd in stderr:
    return ekUnknownHost
  if msgConnectionRefused in stderr:
    return ekConnectionRefused
  if msgTimeoutLinux in stderr or msgTimeoutBsd in stderr:
    return ekTimeout
  ekUnknown

# ---------------------------------------------------------------------------
# Table mapping classification code -> template strings
#
# To add a language, just add an enum value to `Lang` and one more column to
# this array (no changes needed to the `classify` / `explain` logic).
# `{host}` `{bindPort}` `{targetHost}` `{targetPort}` in the templates are
# replaced with `ErrorContext` values by `fill()`.
# ---------------------------------------------------------------------------

type
  Template = tuple[summary: string; hints: seq[string]]

const
  templates: array[ErrorKind, array[Lang, Template]] = [
    ekPortInUse: [
      langEn: (
        summary: "Local port {bindPort} is already in use by another process.",
        hints: @[
          "Find out what's using it: lsof -nP -iTCP:{bindPort} -sTCP:LISTEN",
          "Stop that process, or choose a different bindPort for this tunnel.",
    ]),
      langJa: (
        summary: "Local port {bindPort} is already in use by another process.",
        hints: @[
          "Find out what's using it: lsof -nP -iTCP:{bindPort} -sTCP:LISTEN",
          "Stop that process, or choose a different bindPort for this tunnel.",
    ]),
  ],
    ekAuthFailed: [
      langEn: (
        summary: "SSH authentication to {host} failed (publickey/password rejected).",
        hints: @[
          "Try connecting by hand to see the real prompt: ssh {host}",
          "Check that your key is loaded: ssh-add -l",
    ]),
      langJa: (
        summary: "SSH authentication to {host} failed (publickey/password rejected).",
        hints: @[
          "Try connecting by hand to see the real prompt: ssh {host}",
          "Check that your key is loaded: ssh-add -l",
    ]),
  ],
    ekGatewayPortsDisabled: [
      langEn: (
        summary: "The remote side refused to bind the requested forwarding port.",
        hints: @[
          "Ask the remote admin to enable `GatewayPorts` in sshd_config if you " &
              "need it reachable from outside the remote host.",
          "Or bind to 127.0.0.1 on the remote side if only local access on " &
              "that host is needed.",
    ]),
      langJa: (
        summary: "The remote side refused to bind the requested forwarding port.",
        hints: @[
          "Ask the remote admin to enable `GatewayPorts` in sshd_config if you " &
              "need it reachable from outside the remote host.",
          "Or bind to 127.0.0.1 on the remote side if only local access on " &
              "that host is needed.",
    ]),
  ],
    ekUnknownHost: [
      langEn: (
        summary: "Could not resolve host \"{host}\".",
        hints: @[
          "Check for typos in the host name.",
          "Make sure the host is defined in ~/.ssh/config (or is a resolvable DNS name).",
    ]),
      langJa: (
        summary: "Could not resolve host \"{host}\".",
        hints: @[
          "Check for typos in the host name.",
          "Make sure the host is defined in ~/.ssh/config (or is a resolvable DNS name).",
    ]),
  ],
    ekConnectionRefused: [
      langEn: (
        summary: "Connection to {host} was refused.",
        hints: @[
          "The sshd on the remote host may not be running.",
          "Double-check you're connecting to the right port.",
    ]),
      langJa: (
        summary: "Connection to {host} was refused.",
        hints: @[
          "The sshd on the remote host may not be running.",
          "Double-check you're connecting to the right port.",
    ]),
  ],
    ekTimeout: [
      langEn: (
        summary: "Connection to {host} timed out.",
        hints: @[
          "Check network reachability and any firewalls between here and {host}.",
    ]),
      langJa: (
        summary: "Connection to {host} timed out.",
        hints: @[
          "Check network reachability and any firewalls between here and {host}.",
    ]),
  ],
    ekHostKeyChanged: [
      langEn: (
        summary: "The host key presented by {host} does not match the one " &
            "saved in known_hosts.",
        hints: @[
          "Do NOT simply delete the known_hosts entry. Verify the new host " &
              "key out-of-band with the server owner first (this could be a " &
              "man-in-the-middle attack).",
          "Only after verifying, remove the stale entry: ssh-keygen -R {host}",
    ]),
      langJa: (
        summary: "The host key presented by {host} does not match the one " &
            "saved in known_hosts.",
        hints: @[
          "Do NOT simply delete the known_hosts entry. Verify the new host " &
              "key out-of-band with the server owner first (this could be a " &
              "man-in-the-middle attack).",
          "Only after verifying, remove the stale entry: ssh-keygen -R {host}",
    ]),
  ],
    ekForwardingDenied: [
      langEn: (
        summary: "The remote sshd refused to open this forwarding channel.",
        hints: @[
          "Ask the remote admin to check `AllowTcpForwarding` (and `PermitOpen` " &
              "if set) in sshd_config for {host}.",
    ]),
      langJa: (
        summary: "The remote sshd refused to open this forwarding channel.",
        hints: @[
          "Ask the remote admin to check `AllowTcpForwarding` (and `PermitOpen` " &
              "if set) in sshd_config for {host}.",
    ]),
  ],
    ekBatchModeNoAuth: [
      langEn: (
        summary: "{host} requires interactive authentication, which powarder " &
            "cannot provide (it always connects with BatchMode=yes).",
        hints: @[
          "Set up non-interactive publickey authentication for {host} " &
              "(ssh-copy-id, or add the key to the agent: ssh-add).",
          "If this is the first connection to {host}, connect once by hand " &
              "(plain `ssh {host}`) so the host key gets added to known_hosts, " &
              "then retry.",
    ]),
      langJa: (
        summary: "{host} requires interactive authentication, which powarder " &
            "cannot provide (it always connects with BatchMode=yes).",
        hints: @[
          "Set up non-interactive publickey authentication for {host} " &
              "(ssh-copy-id, or add the key to the agent: ssh-add).",
          "If this is the first connection to {host}, connect once by hand " &
              "(plain `ssh {host}`) so the host key gets added to known_hosts, " &
              "then retry.",
    ]),
  ],
    ekUnknown: [
      langEn: (
        summary: "ssh reported an error that powarder doesn't recognize yet.",
        hints: @[
          "Raw ssh stderr: {rawStderr}",
    ]),
      langJa: (
        summary: "ssh reported an error that powarder doesn't recognize yet.",
        hints: @[
          "Raw ssh stderr: {rawStderr}",
    ]),
  ],
  ]

proc fill(t: string; ctx: ErrorContext): string =
  ## Replaces the placeholders in the template with values from `ctx`.
  t.multiReplace(
    ("{host}", ctx.host),
    ("{bindPort}", $ctx.bindPort),
    ("{targetHost}", ctx.targetHost),
    ("{targetPort}", $ctx.targetPort),
    ("{rawStderr}", ctx.rawStderr),
  )

proc explain*(kind: ErrorKind; lang: Lang; ctx: ErrorContext): Explanation =
  ## Looks up the template for `kind` and `lang`, fills in the values from
  ## `ctx`, and returns the result.
  let t = templates[kind][lang]
  Explanation(summary: t.summary.fill(ctx), hints: t.hints.mapIt(it.fill(ctx)))
