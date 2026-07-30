## Conversion between `ForwardSpec` and strings fully compatible with ssh's
## `-L` / `-R` arguments.
##
## This is the entry point for both CLI arguments and config file settings, so
## it strictly follows ssh's own format. IPv6 addresses are handled with the
## `[addr]` bracket notation.
##
## This module performs no I/O. It does not import `std/asyncnet` /
## `std/osproc` / `std/os`.

import std/strutils
import std/nativesockets ## needed to use `Port`'s `$` / `==`
                          ## (types.nim re-exports only the type via `export Port`)
import powarder/core/types
import powarder/core/hashid

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

proc bracketize(host: string): string =
  ## Wraps only IPv6 literals (which contain `:`) in brackets. IPv4 addresses
  ## and hostnames don't contain `:`, so they pass through unchanged.
  if host.contains(':'):
    "[" & host & "]"
  else:
    host

proc tokenizeFields(s: string): seq[string] =
  ## Splits `[bind_address:]port:host:hostport` on `:`.
  ## A `:` inside an IPv6 literal enclosed in `[...]` is not treated as a
  ## top-level separator.
  result = @[]
  var i = 0
  let n = s.len
  while true:
    if i < n and s[i] == '[':
      let closeIdx = s.find(']', i + 1)
      if closeIdx < 0:
        raise newException(ValueError, "Unterminated '[' found: " & s)
      result.add(s[i + 1 ..< closeIdx])
      i = closeIdx + 1
      if i >= n:
        break
      if s[i] != ':':
        raise newException(ValueError,
            "The character right after the IPv6 literal's ']' must be ':': " & s)
      inc i
      if i == n:
        result.add("")
        break
    else:
      let colonIdx = s.find(':', i)
      if colonIdx < 0:
        result.add(s[i ..< n])
        break
      else:
        result.add(s[i ..< colonIdx])
        i = colonIdx + 1
        if i == n:
          result.add("")
          break

proc parsePortStrict(token, input: string): Port =
  ## Validates that the token is a valid port number (an integer from 1 to
  ## 65535) and converts it to `Port`.
  var value: int
  try:
    value = parseInt(token)
  except ValueError:
    raise newException(ValueError,
        "Port number is not numeric (\"" & token & "\"): " & input)
  if value < 1 or value > 65535:
    raise newException(ValueError,
        "Port number out of range (must be between 1 and 65535, got " &
        $value & "): " & input)
  Port(value)

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

proc parseForwardSpec*(s: string, kind: ForwardKind): ForwardSpec =
  ## Parses the ssh-compatible `[bind_address:]port:host:hostport` format.
  ##
  ## - With 3 fields, `bind_address` is considered omitted and
  ##   `defaultBindAddr` is used. With 4 fields, the first one is
  ##   `bind_address`.
  ## - `*` is normalized to `0.0.0.0`, matching ssh's convention of accepting
  ##   it as "all addresses" (this simplifies the internal representation and
  ##   comparisons; the round-trip conversion outputs `0.0.0.0`).
  ## - IPv6 is accepted only in `[addr]` bracket notation.
  ## - port must be an integer from 1 to 65535 (ssh itself also rejects 0 via
  ##   `-O forward` as `Bad local forwarding specification`, so powarder
  ##   rejects it the same way).
  if s.len == 0:
    raise newException(ValueError, "Empty string is not allowed")

  let fields = tokenizeFields(s)

  var bindAddr: string
  var bindPortTok: string
  var targetHost: string
  var targetPortTok: string

  case fields.len
  of 3:
    bindAddr = defaultBindAddr
    bindPortTok = fields[0]
    targetHost = fields[1]
    targetPortTok = fields[2]
  of 4:
    bindAddr = fields[0]
    bindPortTok = fields[1]
    targetHost = fields[2]
    targetPortTok = fields[3]
  else:
    raise newException(ValueError,
        "Invalid field count (must be 3 or 4 fields as in " &
        "[bind_address:]port:host:hostport, got " &
        $fields.len & "): " & s)

  if bindAddr == "*":
    bindAddr = "0.0.0.0"

  if bindAddr.len == 0:
    raise newException(ValueError, "bind_address is empty: " & s)
  if targetHost.len == 0:
    raise newException(ValueError, "target host is empty: " & s)

  let bindPort = parsePortStrict(bindPortTok, s)
  let targetPort = parsePortStrict(targetPortTok, s)

  ForwardSpec(kind: kind, bindAddr: bindAddr, bindPort: bindPort,
              targetHost: targetHost, targetPort: targetPort)

proc formatForwardSpec*(spec: ForwardSpec): string =
  ## The inverse of `parseForwardSpec`. Even when `bindAddr` equals
  ## `defaultBindAddr`, it is still output explicitly rather than omitted (so
  ## no information is lost on round-trip conversion). IPv6 literals are
  ## bracketed.
  bracketize(spec.bindAddr) & ":" & $spec.bindPort & ":" &
    bracketize(spec.targetHost) & ":" & $spec.targetPort

proc toSshForwardArg*(spec: ForwardSpec, udsPath = ""): string =
  ## Builds the argument string passed to `ssh -O forward -L` / `-R`.
  ##
  ## - `fkLocal` with a non-empty `udsPath`: powarder has ssh set up the UDS,
  ##   and does not pass its own listening `bindPort` to ssh.
  ##   -> `<udsPath>:<targetHost>:<targetPort>`
  ## - `fkLocal` with an empty `udsPath`: TCP fallback.
  ##   -> `<bindAddr>:<bindPort>:<targetHost>:<targetPort>`
  ## - `fkRemote`: UDS is not used (the remote side does the listening).
  ##   -> `<bindAddr>:<bindPort>:<targetHost>:<targetPort>`
  let targetHostStr = bracketize(spec.targetHost)
  if spec.kind == fkLocal and udsPath.len > 0:
    udsPath & ":" & targetHostStr & ":" & $spec.targetPort
  else:
    bracketize(spec.bindAddr) & ":" & $spec.bindPort & ":" &
      targetHostStr & ":" & $spec.targetPort

proc forwardId*(spec: ForwardSpec, host: string): string =
  ## Forward's unique identifier, deterministically derived from what it binds.
  ##
  ## - `fkLocal`: the local port must be globally unique across the whole
  ##   machine, so `host` is not included. This lets us detect the
  ##   misconfiguration of "two tunnels fighting over the same local port".
  ## - `fkRemote`: the remote-side bind only needs to be unique per host, so
  ##   `host` is included.
  case spec.kind
  of fkLocal:
    "L:" & spec.bindAddr & ":" & $spec.bindPort
  of fkRemote:
    "R:" & host & ":" & spec.bindAddr & ":" & $spec.bindPort

proc udsBasename*(id: string): string =
  ## Derives the UDS filename from `forwardId`'s result. Because of the
  ## `sun_path` length limit, it is shortened to 8 hex digits (32 bits,
  ## lowercase hex) via `hashid.hashHex`.
  ##
  ## 8 hex digits = 32 bits, so a collision is theoretically possible, but
  ## with only a few dozen forwards existing at once, the collision
  ## probability is negligible even accounting for the birthday problem. Even
  ## in the rare event of a collision, it does not fail silently: `-O forward`
  ## returns `Port forwarding failed`, which routes into the path where
  ## `daemon/forward.nim` unlinks the leftover file and retries once.
  hashHex(id, 8)
