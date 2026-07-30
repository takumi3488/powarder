## Type definitions shared across every layer of powarder.
##
## This module performs no I/O. By not importing `std/asyncnet` /
## `std/osproc` / `std/os`, it keeps the logic that depends on it unit-testable
## without side effects (`std/json` is pure data conversion, so it doesn't
## violate this policy).

import std/nativesockets
import std/json

export Port

proc `%`*(p: Port): JsonNode =
  ## `Port` is a `distinct uint16`, and `std/json` has no generic `%` for
  ## `distinct` types. Without this, `%` / `%*` for any type containing
  ## `Port`, such as `ForwardSpec`, fails to compile.
  ##
  ## **Placing this here (alongside the shared type definitions) matters.**
  ## It used to live in `ipc/protocol.nim`, but that forced any module that
  ## just wants JSON conversion (e.g. `config/statefile.nim`) to import
  ## `ipc/protocol`, and since this overload is only ever invoked via generic
  ## dispatch, the compiler falsely flagged it as `imported and not used`
  ## (removing it in response to the warning actually broke the build, which
  ## made for an awkward situation). Placing it together with the type avoids
  ## that inconsistency.
  ##
  ## The decode direction needs no extra handling (`std/json`'s
  ## `initFromJson[T: distinct]` automatically handles `distinct` types, so
  ## `to()` just works — empirically confirmed).
  % p.uint16.int

type
  ForwardKind* = enum ## corresponds to ssh's -L / -R
    fkLocal = "L"     ## powarder listens locally, and has ssh set up a UDS
    fkRemote = "R"    ## the remote side listens. powarder does not sit in the data path

  ForwardSpec* = object
    kind*: ForwardKind
    bindAddr*: string ## fkLocal: powarder binds this / fkRemote: the remote side binds this
    bindPort*: Port
    targetHost*: string
    targetPort*: Port

  RetryPolicy* = object
    maxConsecutiveFailures*: int ## 0 means retry without limit (default)
    backoffMaxSeconds*: float

  TunnelConfig* = object
    name*: string
    host*: string ## Host alias from ~/.ssh/config. Connection route and authentication are ssh_config's responsibility
    spec*: ForwardSpec
    autostart*: bool
    profile*: string
    sshExtraArgs*: seq[string]
    retry*: RetryPolicy

  HostSessionKey* = object
    ## The master connection's identity. Including a fingerprint derived from
    ## `ssh -G`'s resolved result, rather than the `host` name itself, means
    ## both "a change of host" and "a change of sshExtraArgs" reduce to a
    ## plain Add/Remove.
    host*: string ## for display purposes
    fingerprint*: string ## the result of sshgparse.fingerprint()

  HostSessionState* = enum
    hsIdle, hsConnecting, hsConnected, hsReconnecting, hsStopping, hsStopped, hsFailed

  ForwardState* = enum
    fwPending,   ## master not connected yet, or waiting to attach
    fwAttaching, ## -O forward in progress
    fwActive,    ## attached and up
    fwDegraded,  ## health check has been failing consecutively (attach itself is still held)
    fwDetaching, ## -O cancel in progress
    fwError      ## automatic retry has stopped

  UpstreamKind* = enum
    ukUnix, ## has ssh set up a UDS (default)
    ukTcp   ## fallback for environments where UDS is unusable

  UpstreamTarget* = object
    case kind*: UpstreamKind
    of ukUnix:
      path*: string
    of ukTcp:
      port*: Port

const
  defaultBindAddr* = "127.0.0.1"
    ## The default when bind_address is omitted. Matched to OpenSSH's -L / -R
    ## behavior (GatewayPorts no), structurally preventing the accident of
    ## "powarder being more permissive than ssh".

  defaultBackoffMaxSeconds* = 30.0
  defaultMaxConns* = 100 ## Upper limit on concurrent connections per forward

func initRetryPolicy*(maxConsecutiveFailures = 0;
                      backoffMaxSeconds = defaultBackoffMaxSeconds): RetryPolicy =
  RetryPolicy(maxConsecutiveFailures: maxConsecutiveFailures,
              backoffMaxSeconds: backoffMaxSeconds)

func isLocal*(spec: ForwardSpec): bool {.inline.} = spec.kind == fkLocal
func isRemote*(spec: ForwardSpec): bool {.inline.} = spec.kind == fkRemote

func exposesExternally*(spec: ForwardSpec): bool =
  ## Whether the listener is bound to something other than loopback, making
  ## it reachable from outside. A warning is emitted when true.
  spec.bindAddr notin ["127.0.0.1", "localhost", "::1", "[::1]"]

func `==`*(a, b: UpstreamTarget): bool =
  ## `UpstreamTarget` is a variant object containing a case, and the compiler's
  ## auto-generated `==` does not support variant objects
  ## (`"parallel 'fields' iterator does not work for 'case' objects"`), so
  ## this is written by hand.
  if a.kind != b.kind: return false
  case a.kind
  of ukUnix: a.path == b.path
  of ukTcp: a.port == b.port
