## Judges the outcome of `ssh -O forward` / `-O cancel` / `-O check` runs.
##
## This confines the most fragile part of powarder to a single place. Whether
## an ssh multiplex control command succeeded can only be judged from the
## combination of the "exit code" and the "stderr wording", and that
## combination differs per subcommand (see each proc's doc comment for
## details). If OpenSSH's version bumps change the wording and this matching
## logic goes stale, powarder can end up treating a success as a failure or a
## failure as a success. That's why the tests (`tests/tmuxparse.nim`) pin down
## empirically observed data, so a test breaks the moment this wording changes.
##
## This module performs no I/O. It does not import `std/asyncnet` /
## `std/osproc` / `std/os`. Actually running `ssh -O ...` to obtain
## `(exitCode, stdout, stderr)` is the caller's responsibility (expected to be
## `daemon/muxclient.nim`); this module only provides pure functions that take
## that result and judge it.

import std/strutils

# ---------------------------------------------------------------------------
# String constants to match against
#
# If an OpenSSH version bump changes the output wording in mux.c / ssh.c,
# check and fix this section first. The actual place to verify is around
# `mux_client_forward()` / `mux_client_request_forwards()` / `control_client()`
# (mux.c).
# ---------------------------------------------------------------------------

const
  msgControlSocketConnect = "Control socket connect("
    ## Only look at the fixed first-half part for when the control socket
    ## can't be reached.
    ## The actual message includes the path and error text, e.g.
    ## `Control socket connect(/tmp/x.sock): No such file or directory` (ENOENT) or
    ## `Control socket connect(/tmp/x.sock): Connection refused` (ECONNREFUSED),
    ## and since the path and error text vary, only the fixed first-half part is used for matching.

  msgMasterRefused = "Master refused forwarding request:"
    ## When the master rejects a forward/cancel request due to policy (the
    ## mux's own permission setting, not e.g. `PermitLocalCommand`). mux.c's
    ## `mux_client_forward()` uses this same wording for both forward and
    ## cancel.

  msgBindFailed = "Port forwarding failed"
    ## When `-O forward` fails to actually bind. Empirically this appears as
    ## `mux_client_forward: forwarding request failed: Port forwarding failed`,
    ## but only the distinctive latter half is used for matching.

  msgNotForwarded = "port not forwarded"
    ## When the `-O cancel` target does not exist in the forward table.
    ## Empirically this appears as
    ## `mux_client_forward: forwarding request failed: port not forwarded`.

  msgBadSpecLocal = "Bad local forwarding specification"
  msgBadSpecRemote = "Bad remote forwarding specification"
    ## A `-L` / `-R` syntax error. This is rejected at ssh.c's argument-parsing
    ## stage (before the mux layer), so it normally does not appear alongside
    ## `moNoMaster` etc.

  msgMasterRunningPrefix = "Master running (pid="
    ## Appears on **stderr** (not stdout, empirically confirmed) when
    ## `-O check` finds the master alive. Immediately followed by the pid
    ## digits, closed with `)`.

type
  MuxOutcome* = enum
    moSuccess ## Success (covers both a fresh bind and idempotent success against an existing entry)
    moBindFailed     ## Bind failed (Port forwarding failed)
    moNotForwarded   ## Cancel target not in the forward table (port not forwarded)
    moRefused        ## Master rejected due to policy
    moNoMaster       ## Cannot connect to the control socket
    moBadSpec        ## Syntax error in the forward specification
    moUnknownFailure ## A failure that doesn't match any of the above

proc parseForwardResult*(exitCode: int; stdout, stderr: string): MuxOutcome =
  ## Judges the result of `ssh -O forward`.
  ##
  ## **exitCode is usable for judging** (empirically: 0 on success / 255 on
  ## failure). However, exitCode being 0 does not mean a "fresh bind" was
  ## made. Resending the exact same forward specification as an existing one
  ## also returns 0 from ssh (idempotent success). If the caller wants to know
  ## whether a fresh bind was actually made, it needs to check its own prior
  ## state (`ForwardState`) in addition to this result.
  ##
  ## stdout is empirically always empty and is not used for judging (it is
  ## accepted as an argument just to keep the API shape consistent with
  ## `parseCancelResult` / `parseCheckResult`).
  ##
  ## Priority order (when multiple patterns could match simultaneously, judge
  ## from the top down):
  ## 1. `moNoMaster`   -- cannot connect to the control socket. If this is
  ##                      true, ssh could not even send the forward request
  ##                      itself, so it is the most fundamental cause and
  ##                      takes top priority.
  ## 2. `moBadSpec`    -- `-L`/`-R` syntax error. This should theoretically
  ##                      never occur alongside `moNoMaster` since it's
  ##                      rejected before reaching the mux layer, but it's
  ##                      placed second as a fail-safe.
  ## 3. `moRefused`    -- master's policy rejection.
  ## 4. `moBindFailed` -- actual bind failure.
  ## 5. A failure that doesn't match any of these is `moUnknownFailure`.
  discard stdout
  if exitCode == 0:
    return moSuccess
  if msgControlSocketConnect in stderr:
    return moNoMaster
  if msgBadSpecLocal in stderr or msgBadSpecRemote in stderr:
    return moBadSpec
  if msgMasterRefused in stderr:
    return moRefused
  if msgBindFailed in stderr:
    return moBindFailed
  moUnknownFailure

proc parseCancelResult*(exitCode: int; stdout, stderr: string): MuxOutcome =
  ## Judges the result of `ssh -O cancel`.
  ##
  ## **exitCode cannot be trusted at all** (empirically: both success and
  ## failure return 0). Judging is done purely from the stderr wording. If
  ## stderr is empty (including when it contains only whitespace), it's
  ## `moSuccess`.
  ##
  ## Priority order (judge from the top down):
  ## 1. `moNoMaster`     -- cannot connect to the control socket itself.
  ## 2. `moRefused`      -- master's policy rejection (forward and cancel
  ##                        share the same wording).
  ## 3. `moNotForwarded` -- cancel target not in the forward table.
  ## 4. If none of the above match and stderr is non-empty, `moUnknownFailure`.
  discard stdout
  discard exitCode
  if stderr.strip().len == 0:
    return moSuccess
  if msgControlSocketConnect in stderr:
    return moNoMaster
  if msgMasterRefused in stderr:
    return moRefused
  if msgNotForwarded in stderr:
    return moNotForwarded
  moUnknownFailure

proc parseCheckResult*(exitCode: int; stdout, stderr: string): tuple[
    alive: bool; pid: int] =
  ## Judges the result of `ssh -O check`.
  ##
  ## The message `Master running (pid=N)` for a live master appears on
  ## **stderr** (not stdout, empirically confirmed). If the pid digits
  ## can't be extracted, returns `(alive: false, pid: 0)`.
  discard stdout
  discard exitCode
  let idx = stderr.find(msgMasterRunningPrefix)
  if idx < 0:
    return (alive: false, pid: 0)
  var i = idx + msgMasterRunningPrefix.len
  var pidStr = ""
  while i < stderr.len and stderr[i] in Digits:
    pidStr.add stderr[i]
    inc i
  if pidStr.len == 0:
    return (alive: false, pid: 0)
  (alive: true, pid: parseInt(pidStr))
