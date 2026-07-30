## Bidirectional byte relay between the client socket and the upstream socket.

import std/asyncdispatch
import std/asyncnet

const
  RelayBufSize* = 16384 ## Because an SSH channel's max payload per message is roughly 16KB

proc pump(src, dst: AsyncSocket; buf: pointer; bufLen: int;
          onBytes: proc (n: int) {.closure, gcsafe.}) {.async.} =
  ## A one-way loop that reads from `src` and streams it straight to `dst`.
  ##
  ## `recvInto` returns `0` rather than raising an exception when the
  ## connection is closed and there is no data. Furthermore, with the
  ## default flag `{SocketFlag.SafeDisconn}`, `ECONNRESET` / `EPIPE` /
  ## `ENETRESET` are also treated as EOF-equivalent (`0`), so `if n <= 0:
  ## break` alone covers both the normal case and abnormal disconnects.
  while true:
    let n = await src.recvInto(buf, bufLen)
    if n <= 0: break
    await dst.send(buf, n)
    onBytes(n)

proc relay*(client, upstream: AsyncSocket;
            onRx, onTx: proc (n: int) {.closure, gcsafe.}) {.async.} =
  ## Relays `client` <-> `upstream`. Closes both as soon as either side
  ## hits EOF (half-close is not handled: almost no application makes use
  ## of half-close over an SSH port forward, and this keeps the code much
  ## simpler).
  ##
  ## Uses `recvInto` (rather than `recv`, which returns a string) plus a
  ## pre-allocated buffer reused for the lifetime of the connection, to
  ## avoid allocating on every call.
  var bufA = newString(RelayBufSize)
  var bufB = newString(RelayBufSize)
  let c2u = pump(client, upstream, addr bufA[0], RelayBufSize, onRx)
  let u2c = pump(upstream, client, addr bufB[0], RelayBufSize, onTx)
  await c2u or u2c
  # AsyncSocket.close() is idempotent (`if socket.closed: return`), so a
  # double close is safe too.
  client.close()
  upstream.close()
  # If the other Future is left unattended after one side finishes, an
  # unhandled Future warning appears, so explicitly await it after close()
  # and swallow any exception.
  try: await c2u
  except CatchableError: discard
  try: await u2c
  except CatchableError: discard
