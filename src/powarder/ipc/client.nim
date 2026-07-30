## The CLI-side IPC transport: a single, one-shot synchronous RPC call over
## a Unix domain socket.
##
## The CLI is a short-lived process (start -> run one command -> exit), so
## unlike the daemon side (`ipc/server`), it doesn't need to run a
## `std/asyncdispatch` event loop. This is implemented entirely with
## `std/net`'s synchronous API.
##
## No JSON encoding/decoding of messages happens here at all (that's fully
## delegated to `ipc/protocol`).

import std/[net, nativesockets, posix, json, options]
import powarder/ipc/protocol
import powarder/core/paths

type
  IpcClientError* = object of CatchableError

  DaemonNotRunningError* = object of IpcClientError
    ## The socket doesn't exist (`ENOENT`), or only a stale remnant exists
    ## with nobody listening (`ECONNREFUSED`). The CLI uses this to decide
    ## whether to try auto-starting the daemon, so it's made sure to be
    ## distinguishable from other errors (permission errors, malformed
    ## responses, etc.).

  RpcRemoteError* = object of IpcClientError
    code*: int
    data*: JsonNode
    ## The daemon returned an error response. `code` is kept so it can be
    ## mapped to a CLI exit code (e.g. `errTunnelNotFound` -> exit code 4).

var callIdCounter = 0
  ## A monotonically increasing counter for request ids. A CLI process
  ## normally calls `call` only once per invocation, but this ensures ids
  ## won't collide even if it's called more than once.

proc nextCallId(): int =
  inc callIdCounter
  callIdCounter

proc classifyConnectFailure(e: ref OSError): ref DaemonNotRunningError =
  ## Looks at the errno of the `OSError` raised by `connectUnix` to
  ## determine whether this is a "the daemon isn't running" case.
  ##
  ## Returns `nil` (the caller falls back to a generic `IpcClientError`)
  ## unless it's one of:
  ## - `ENOENT` (the socket file doesn't exist)
  ## - `ECONNREFUSED` (the file exists but nobody is listening -- a
  ##   remnant left behind by a crashed daemon)
  ##
  ## The errno is taken from `(ref OSError).errorCode` (`int32`). Reading
  ## `osLastError()` again at the call site risks errno being overwritten
  ## between when the exception was raised and when it's caught (even if
  ## nothing else happens in between), so this field -- which the
  ## exception object already holds at the moment `raiseOSError` runs -- is
  ## more reliable.
  if e.errorCode == ENOENT.int32 or e.errorCode == ECONNREFUSED.int32:
    result = newException(DaemonNotRunningError,
        "daemon is not running (" & e.msg & ")")

proc call*(methodName: string; params: JsonNode = nil; path = "";
    timeoutMs = 5000): JsonNode =
  ## Performs a single RPC call: connect -> send request -> receive one
  ## line -> disconnect.
  ##
  ## - If `path` is empty, uses `paths.ipcSocketPath()`
  ## - `DaemonNotRunningError` if the socket doesn't exist / can't be connected to
  ## - `RpcRemoteError` (with `code`) if the daemon returns an error response
  ## - `IpcClientError` if no response arrives within `timeoutMs`
  ##
  ## **`connectUnix` has no timeout argument.** Since a UDS connection is
  ## local to the host with no network latency, the risk of connect itself
  ## hanging is judged to be low, so it isn't handled here (send /
  ## recvLine do get a timeout applied, since `std/net` provides one for
  ## those).
  let p = if path.len > 0: path else: ipcSocketPath()

  var sock: Socket
  try:
    # `AF_UNIX` / `SOCK_STREAM` / `IPPROTO_IP` also exist as identically
    # named (`cint`) constants in `std/posix`, and since `std/posix` is
    # imported here for its errno constants, this becomes an ambiguous
    # call. Disambiguate by using `nativesockets`'s enum versions.
    sock = newSocket(nativesockets.AF_UNIX, nativesockets.SOCK_STREAM,
        nativesockets.IPPROTO_IP)
  except OSError as e:
    raise newException(IpcClientError, "failed to create socket: " & e.msg)

  try:
    try:
      sock.connectUnix(p)
    except OSError as e:
      let daemonErr = classifyConnectFailure(e)
      if daemonErr != nil:
        raise daemonErr
      raise newException(IpcClientError,
          "failed to connect to " & p & ": " & e.msg)

    let id = nextCallId()
    let requestLine = encodeRequest(id, methodName, params)
    try:
      sock.send(requestLine & "\n")
    except OSError as e:
      raise newException(IpcClientError, "failed to send request: " & e.msg)

    var responseLine: string
    try:
      responseLine = sock.recvLine(timeout = timeoutMs)
    except TimeoutError as e:
      raise newException(IpcClientError,
          "timed out waiting for a response: " & e.msg)
    except OSError as e:
      raise newException(IpcClientError, "failed to receive response: " & e.msg)

    if responseLine.len == 0:
      # `recvLine` returns an empty string on disconnect (passing an empty
      # string to `protocol.decodeResponse` would always produce an
      # `RpcParseError`, so it is distinguished here first).
      raise newException(IpcClientError,
          "daemon closed the connection before sending a response")

    let response =
      try:
        decodeResponse(responseLine)
      except RpcParseError as e:
        raise newException(IpcClientError,
            "received an invalid response from the daemon: " & e.msg)

    if response.error.isSome:
      let errInfo = response.error.get
      var remoteErr = newException(RpcRemoteError, errInfo.message)
      remoteErr.code = errInfo.code
      remoteErr.data = errInfo.data
      raise remoteErr

    result = response.result
  finally:
    sock.close()

proc ping*(path = ""): bool =
  ## Sends `daemon.ping` to check whether the daemon is alive.
  ##
  ## **This is the one exception that never raises.** Used for the CLI's
  ## auto-start decision ("if the daemon isn't there, start it and
  ## retry"), it catches `DaemonNotRunningError` and simply returns `false`.
  try:
    discard call(mDaemonPing, path = path)
    true
  except DaemonNotRunningError:
    false
