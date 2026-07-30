## The accept loop for the public listener (the bind address:port specified
## by the user).

import std/asyncdispatch
import std/asyncnet
import std/nativesockets
import powarder/core/types
import powarder/proxy/stats
import powarder/proxy/upstream
import powarder/proxy/relay

type
  ForwardProxy* = ref object
    listener*: AsyncSocket
    target*: UpstreamTarget
    stats*: ForwardStats
    maxConns*: int
    closing*: bool

proc newForwardProxy*(bindAddr: string; bindPort: Port; target: UpstreamTarget;
                      maxConns = defaultMaxConns): ForwardProxy =
  ## Binds & listens on the public listener. **If the bind fails, the
  ## exception is simply propagated as-is** (this is the correct layer to
  ## detect "the local port is already in use," since it is powarder — not
  ## ssh — that binds the user-specified port).
  let domain = if bindAddr.contains(':'): AF_INET6 else: AF_INET
  let listener = newAsyncSocket(domain, buffered = false)
  listener.setSockOpt(OptReuseAddr, true)
  listener.bindAddr(bindPort, bindAddr)
  listener.listen()
  ForwardProxy(listener: listener, target: target, stats: newForwardStats(),
               maxConns: maxConns, closing: false)

proc handleConnection(p: ForwardProxy; client: AsyncSocket) {.async.} =
  ## Handler for a single connection. Closes immediately if the concurrent
  ## connection limit is exceeded, and also closes the client immediately
  ## if connecting to the upstream fails (since this is a raw TCP relay,
  ## there is no way to convey the error's meaning to the client, so an
  ## immediate close is the only option).
  if p.stats.activeConns >= p.maxConns:
    p.stats.recordRejected()
    client.close()
    return

  let (peerAddr, peerPort) = client.getPeerAddr()
  p.stats.recordConnect(peerAddr, peerPort)

  var upstream: AsyncSocket
  try:
    upstream = await dialUpstream(p.target)
  except UpstreamUnhealthyError:
    p.stats.recordFailed()
    p.stats.recordDisconnect()
    client.close()
    return

  let stats = p.stats
  proc onRx(n: int) {.closure, gcsafe.} = stats.recordRx(n)
  proc onTx(n: int) {.closure, gcsafe.} = stats.recordTx(n)

  await relay(client, upstream, onRx, onTx)
  p.stats.recordDisconnect()

proc serve*(p: ForwardProxy) {.async.} =
  ## The accept loop. Launches the handler with `asyncCheck` for each
  ## connection.
  ##
  ## When `close()` closes the listener, the pending `acceptAddr` raises an
  ## exception, so the `closing` flag is checked to distinguish a normal
  ## termination (break out of the loop) from a genuine accept failure.
  while not p.closing:
    try:
      let conn = await p.listener.acceptAddr()
      asyncCheck handleConnection(p, conn.client)
    except CatchableError:
      if p.closing:
        break
      else:
        raise

proc close*(p: ForwardProxy) =
  ## Sets `closing = true` and closes the listener. The accept loop checks
  ## `closing` and exits.
  p.closing = true
  p.listener.close()

proc retarget*(p: ForwardProxy; target: UpstreamTarget) =
  ## Switches to a new upstream when the forward's destination changes.
  ## Existing connections keep flowing to the old target (since they
  ## already hold a socket that has already been through `dialUpstream`),
  ## and only new connections go to the new target. This allows switching
  ## with essentially no downtime.
  p.target = target
