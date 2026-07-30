## The daemon-side IPC transport: the accept loop and request dispatch over
## a Unix domain socket.
##
## No JSON encoding/decoding of messages happens here at all (that's fully
## delegated to `ipc/protocol`'s `decodeRequest` / `encodeSuccess` /
## `encodeError`). This module's responsibility is limited to just these
## four things:
## - bind / listen / accept on the socket
## - reading one line and writing one line (newlines are the framing)
## - dispatching to registered handlers and converting errors into JSON-RPC
## - making sure nothing a handler throws takes the daemon process down with it
## The daemon is assumed to run on a single-threaded async event loop
## (`std/asyncdispatch`).

import std/[asyncdispatch, asyncnet, nativesockets, json, options, os, tables]
import powarder/ipc/protocol
import powarder/core/paths

type
  RpcHandler* = proc (params: JsonNode): JsonNode {.closure, gcsafe.}
    ## On success, returns the `JsonNode` that becomes the response's
    ## `result`. On failure, either raises `RpcError` (for an error where
    ## you want to specify a code), or raises some other exception (which
    ## gets rounded down to `rpcInternalError`).

  RpcError* = object of CatchableError
    code*: int
    data*: JsonNode
    ## The exception a handler raises when it wants to return a JSON-RPC
    ## error response. `code` holds one of `ipc/protocol`'s error code
    ## constants (`errTunnelNotFound`, etc.). `msg` (inherited from
    ## `CatchableError`) becomes the error response's `message` as-is.

  IpcServer* = ref object
    socket*: AsyncSocket
    path*: string
    handlers*: Table[string, RpcHandler]
    closing*: bool
    conns: seq[Future[void]]
      ## Futures for in-flight `handleClient` calls. Finished ones are
      ## pruned at the top of `serve()`'s accept loop (see `serve()`'s doc
      ## comment for why this is used instead of `asyncCheck`).

proc newRpcError*(code: int; message: string;
    data: JsonNode = nil): ref RpcError =
  ## A helper constructor used on the handler side like
  ## `raise newRpcError(errTunnelNotFound, "...")` (the same shape as
  ## `ipc/protocol`'s `newRpcParseError`).
  result = (ref RpcError)(msg: message, code: code, data: data)

proc newIpcServer*(path = ""): IpcServer =
  ## If `path` is empty, uses `paths.ipcSocketPath()`.
  ##
  ## **Note on the security boundary**: this version of powarder's IPC has
  ## no authentication mechanism at all. Setting the socket file's
  ## permissions to 0600, so that only the owner can connect, stands in
  ## for authentication (since a UDS's reachability is determined by
  ## filesystem permissions, this is the same design decision as Docker's
  ## `/var/run/docker.sock`). This means the runtime directory's own
  ## permissions matter too (this relies on `core/paths.ensureRuntimeDir`
  ## creating it with 0700).
  let p = if path.len > 0: path else: ipcSocketPath()

  if path.len == 0:
    # Only ensure the runtime directory exists when using the default
    # socket path. If the caller passes an explicit `path` (e.g. a short
    # path for tests), preparing that path's parent directory is
    # considered the caller's responsibility, and no directory creation
    # unrelated to `runtimeDir()` happens here.
    ensureRuntimeDir()

  # Remove any leftover remnant of an existing socket. `os.fileExists`
  # only checks S_ISREG, so it always returns false for a socket --
  # always use `socketExists` instead (see the doc comment in
  # `core/paths.nim`).
  if socketExists(p):
    removeFile(p)

  let sock = newAsyncSocket(AF_UNIX, SOCK_STREAM, IPPROTO_IP)
  sock.bindUnix(p)
  # Tighten permissions right after bind. There is theoretically a window
  # between bind and setFilePermissions, but since the runtime directory
  # itself is assumed to be 0700 (unreachable by anyone but the owner),
  # there's no real-world harm.
  setFilePermissions(p, {fpUserRead, fpUserWrite})
  sock.listen()

  result = IpcServer(socket: sock, path: p,
      handlers: initTable[string, RpcHandler](), closing: false)

proc register*(s: IpcServer; methodName: string; handler: RpcHandler) =
  s.handlers[methodName] = handler

proc handleClient(s: IpcServer; client: AsyncSocket) {.async.} =
  ## Handles a single connection.
  ##
  ## **Design choice**: "1 UDS connection = 1 logical command" is the
  ## basic design, but to prepare for future extension (multiple requests
  ## on the same connection), this is implemented as a loop that can
  ## process multiple requests until the connection closes. The CLI side's
  ## current `client.call()` opens a new connection each time and
  ## disconnects after one request, so the actual communication pattern is
  ## unchanged and still behaves as "1 connection = 1 command".
  try:
    while not s.closing:
      let line = await client.recvLine()
      if line.len == 0:
        break # disconnected (`recvLine` returns an empty string on disconnect)

      var req: RpcRequest
      var parseFailed = false
      try:
        req = decodeRequest(line)
      except RpcParseError as e:
        # The id is unknown (the line is malformed, so the request's
        # contents can't be recovered), so 0 is used. The JSON-RPC 2.0
        # spec says null is correct here, but `ipc/protocol`'s
        # `encodeError` requires `id: int`, so this compromise is made.
        parseFailed = true
        await client.send(encodeError(0, rpcParseError, e.msg) & "\n")

      if parseFailed:
        continue

      if req.methodName notin s.handlers:
        if req.id.isSome:
          await client.send(encodeError(req.id.get, rpcMethodNotFound,
              "method not found: " & req.methodName) & "\n")
        continue # a notification returns no response at all

      var resJson: JsonNode = nil
      var errCode = 0
      var errMsg = ""
      var errData: JsonNode = nil
      var handlerFailed = false
      try:
        resJson = s.handlers[req.methodName](req.params)
      except RpcError as e:
        handlerFailed = true
        errCode = e.code
        errMsg = e.msg
        errData = e.data
      except CatchableError as e:
        # Even if a handler raises an unexpected exception, the daemon
        # must not go down with it. A resident process dying because a
        # single request failed is out of the question, so it's reliably
        # caught here and converted into `rpcInternalError`.
        handlerFailed = true
        errCode = rpcInternalError
        errMsg = e.msg
        errData = nil

      if req.id.isNone:
        continue # no response is returned for a notification

      if handlerFailed:
        await client.send(encodeError(req.id.get, errCode, errMsg, errData) & "\n")
      else:
        await client.send(encodeSuccess(req.id.get, resJson) & "\n")
  except CatchableError:
    # Sending/receiving itself failed (e.g. the client disconnected
    # before reading). Give up on just this connection; the server keeps
    # running.
    discard
  finally:
    client.close()

proc pruneFinished(s: IpcServer) =
  ## Removes finished `handleClient` Futures from `s.conns`.
  ## `handleClient` is designed to swallow all of its own exceptions, but
  ## just in case, if a Future did fail, its `readError` is read here to
  ## prevent an additional warning about "a Future's exception was never
  ## retrieved".
  var alive: seq[Future[void]] = @[]
  for f in s.conns:
    if f.finished:
      if f.failed:
        discard f.readError
    else:
      alive.add f
  s.conns = alive

proc serve*(s: IpcServer) {.async.} =
  ## The accept loop.
  ##
  ## For each connection, `handleClient` is started by keeping the
  ## `Future` itself in `s.conns`, rather than using `asyncCheck`.
  ## `asyncCheck` doesn't retain a reference to the Future, so there would
  ## be no way to wait for connections still outstanding after `close()`.
  ## Since the number of connections is unbounded, finished Futures are
  ## pruned at the top of the loop instead (`pruneFinished`).
  ##
  ## When `close()` closes the listener socket, a pending `accept()` fails
  ## with an OSError. This is distinguished from an "intentional
  ## shutdown" via the `s.closing` flag, and the loop exits normally when
  ## it is indeed a shutdown.
  while true:
    pruneFinished(s)
    var client: AsyncSocket
    try:
      client = await s.socket.accept()
    except CatchableError:
      if s.closing:
        break
      else:
        # The listener itself is broken (unexpected). Propagate to the caller.
        raise
    s.conns.add handleClient(s, client)

proc close*(s: IpcServer) =
  ## Sets `closing`, then closes the socket and removes the socket file.
  ## Order matters here: unless `closing = true` is set first, `serve()`
  ## will mistake the `accept()` failure caused by `socket.close()` for an
  ## "abnormal" error.
  s.closing = true
  s.socket.close()
  if socketExists(s.path):
    removeFile(s.path)
