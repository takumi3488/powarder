## Unit tests for the proxy layer (stats / upstream / relay / listener).
##
## Uses neither ssh nor a real SSH server. Sets up a dummy echo server with
## `asyncnet` as the "internal endpoint," sends data through the proxy, and
## checks that it echoes back.

import std/unittest
import std/asyncdispatch
import std/asyncnet
import std/nativesockets
import std/os
import std/deques
import powarder/core/types
import powarder/proxy/stats
import powarder/proxy/listener
import powarder/proxy/relay

# ---------------------------------------------------------------------------
# Test helpers
# ---------------------------------------------------------------------------

proc tcpTarget(port: int): UpstreamTarget =
  UpstreamTarget(kind: ukTcp, port: Port(port))

proc unixTarget(path: string): UpstreamTarget =
  UpstreamTarget(kind: ukUnix, path: path)

proc waitUntil(cond: proc(): bool {.closure.}; tries = 200;
               delayMs = 10): Future[bool] {.async.} =
  ## Polls until the condition is satisfied. A test-only helper for
  ## absorbing timing differences in asynchronous processing.
  for i in 0 ..< tries:
    if cond():
      return true
    await sleepAsync(delayMs)
  result = cond()

proc echoConn(sock: AsyncSocket) {.async.} =
  ## A single-connection handler that sends back whatever bytes it received.
  var buf = newString(65536)
  while true:
    let n = await sock.recvInto(addr buf[0], buf.len)
    if n <= 0: break
    await sock.send(addr buf[0], n)
  sock.close()

type
  EchoServer = ref object
    ## The test's "internal endpoint." Used as the target in place of ssh.
    listener: AsyncSocket
    closing: bool

proc newEchoServerTcp(port: int): EchoServer =
  let l = newAsyncSocket(AF_INET, buffered = false)
  l.setSockOpt(OptReuseAddr, true)
  l.bindAddr(Port(port), "127.0.0.1")
  l.listen()
  EchoServer(listener: l, closing: false)

proc newEchoServerUnix(path: string): EchoServer =
  # fileExists only looks at regular files, so it always returns false for a
  # UDS. removeFile does not fail even if the file doesn't exist, so call it
  # unconditionally.
  removeFile(path)
  let l = newAsyncSocket(AF_UNIX, SOCK_STREAM, IPPROTO_NONE, buffered = false)
  l.bindUnix(path)
  l.listen()
  EchoServer(listener: l, closing: false)

proc serve(e: EchoServer) {.async.} =
  while not e.closing:
    try:
      let conn = await e.listener.acceptAddr()
      asyncCheck echoConn(conn.client)
    except CatchableError:
      if e.closing: break
      else: raise

proc close(e: EchoServer) =
  e.closing = true
  e.listener.close()

proc newTcpClient(port: int): Future[AsyncSocket] {.async.} =
  result = newAsyncSocket(buffered = false)
  await result.connect("127.0.0.1", Port(port))

# ---------------------------------------------------------------------------
# 1. Relaying works & 2. byte counts are tallied
# ---------------------------------------------------------------------------

test "relaying works & byte counts are tallied":
  proc scenario() {.async.} =
    let echo = newEchoServerTcp(17312)
    asyncCheck echo.serve()

    let proxy = newForwardProxy("127.0.0.1", Port(17302), tcpTarget(17312))
    asyncCheck proxy.serve()

    let client = await newTcpClient(17302)
    await client.send("hello")

    var buf = newString(5)
    let n = await client.recvInto(addr buf[0], 5)
    buf.setLen(n)
    check buf == "hello"

    check proxy.stats.bytesRx >= 5
    check proxy.stats.bytesTx >= 5

    client.close()
    proxy.close()
    echo.close()
    await sleepAsync(50)

  waitFor scenario()

# ---------------------------------------------------------------------------
# 3. Connection counts
# ---------------------------------------------------------------------------

test "connection counts: activeConns / totalConns":
  proc scenario() {.async.} =
    let echo = newEchoServerTcp(17313)
    asyncCheck echo.serve()

    let proxy = newForwardProxy("127.0.0.1", Port(17303), tcpTarget(17313))
    asyncCheck proxy.serve()

    let client = await newTcpClient(17303)
    check await waitUntil(proc(): bool = proxy.stats.activeConns == 1)
    check proxy.stats.totalConns == 1

    client.close()
    check await waitUntil(proc(): bool = proxy.stats.activeConns == 0)
    check proxy.stats.totalConns == 1

    proxy.close()
    echo.close()
    await sleepAsync(50)

  waitFor scenario()

# ---------------------------------------------------------------------------
# 4. Upstream is dead
# ---------------------------------------------------------------------------

test "upstream is dead: client gets immediate EOF, failedConns increases":
  proc scenario() {.async.} =
    # 17314 is a TCP port nobody is listening on
    let proxy = newForwardProxy("127.0.0.1", Port(17304), tcpTarget(17314))
    asyncCheck proxy.serve()

    let client = await newTcpClient(17304)
    var buf = newString(16)
    let n = await client.recvInto(addr buf[0], 16)
    check n == 0
    check proxy.stats.failedConns == 1

    client.close()
    proxy.close()
    await sleepAsync(50)

  waitFor scenario()

# ---------------------------------------------------------------------------
# 5. Exceeding maxConns
# ---------------------------------------------------------------------------

test "exceeding maxConns: the 2nd connection is closed immediately and rejectedConns increases":
  proc scenario() {.async.} =
    let echo = newEchoServerTcp(17315)
    asyncCheck echo.serve()

    let proxy = newForwardProxy("127.0.0.1", Port(17305), tcpTarget(17315),
                                maxConns = 1)
    asyncCheck proxy.serve()

    let client1 = await newTcpClient(17305)
    check await waitUntil(proc(): bool = proxy.stats.activeConns == 1)

    let client2 = await newTcpClient(17305)
    var buf = newString(16)
    let n = await client2.recvInto(addr buf[0], 16)
    check n == 0
    check proxy.stats.rejectedConns == 1
    # The 2nd connection was merely rejected, so it isn't counted in activeConns
    check proxy.stats.activeConns == 1

    client1.close()
    client2.close()
    proxy.close()
    echo.close()
    await sleepAsync(50)

  waitFor scenario()

# ---------------------------------------------------------------------------
# 6. UDS path
# ---------------------------------------------------------------------------

test "relaying, byte counts, and connection counts also hold over the UDS path":
  proc scenario() {.async.} =
    let sockPath = "/tmp/pwt-t6.sock"
    let echo = newEchoServerUnix(sockPath)
    asyncCheck echo.serve()

    let proxy = newForwardProxy("127.0.0.1", Port(17306), unixTarget(sockPath))
    asyncCheck proxy.serve()

    let client = await newTcpClient(17306)
    await client.send("hello")

    var buf = newString(5)
    let n = await client.recvInto(addr buf[0], 5)
    buf.setLen(n)
    check buf == "hello"
    check proxy.stats.bytesRx >= 5
    check proxy.stats.bytesTx >= 5
    check proxy.stats.activeConns == 1
    check proxy.stats.totalConns == 1

    client.close()
    check await waitUntil(proc(): bool = proxy.stats.activeConns == 0)

    proxy.close()
    echo.close()
    removeFile(sockPath)
    await sleepAsync(50)

  waitFor scenario()

# ---------------------------------------------------------------------------
# 7. Larger data (exceeding RelayBufSize)
# ---------------------------------------------------------------------------

test "data exceeding RelayBufSize round-trips without corruption":
  proc scenario() {.async.} =
    let echo = newEchoServerTcp(17317)
    asyncCheck echo.serve()

    let proxy = newForwardProxy("127.0.0.1", Port(17307), tcpTarget(17317))
    asyncCheck proxy.serve()

    let client = await newTcpClient(17307)

    # Use a size offset from a multiple of RelayBufSize so boundary-crossing
    # behavior is also covered
    let payloadSize = RelayBufSize * 4 + 37
    var payload = newString(payloadSize)
    for i in 0 ..< payloadSize:
      payload[i] = char(i mod 251)

    await client.send(payload)

    var received = newString(payloadSize)
    var got = 0
    while got < payloadSize:
      let n = await client.recvInto(addr received[got], payloadSize - got)
      if n <= 0: break
      got += n

    check got == payloadSize
    check received == payload
    check proxy.stats.bytesRx >= payloadSize.uint64
    check proxy.stats.bytesTx >= payloadSize.uint64

    client.close()
    proxy.close()
    echo.close()
    await sleepAsync(50)

  waitFor scenario()

# ---------------------------------------------------------------------------
# 8. retarget
# ---------------------------------------------------------------------------

test "retarget: only new connections go to the new target":
  proc scenario() {.async.} =
    let echoOld = newEchoServerTcp(17318)
    asyncCheck echoOld.serve()
    let echoNew = newEchoServerTcp(17319)
    asyncCheck echoNew.serve()

    let proxy = newForwardProxy("127.0.0.1", Port(17308), tcpTarget(17318))
    asyncCheck proxy.serve()

    # Keep a connection open to the old target
    let clientOld = await newTcpClient(17308)
    check await waitUntil(proc(): bool = proxy.stats.activeConns == 1)

    proxy.retarget(tcpTarget(17319))

    # A new connection goes to the new target
    let clientNew = await newTcpClient(17308)
    check await waitUntil(proc(): bool = proxy.stats.activeConns == 2)

    await clientNew.send("new")
    var buf = newString(3)
    let n = await clientNew.recvInto(addr buf[0], 3)
    buf.setLen(n)
    check buf == "new"

    # The old connection is still alive and can talk to the old target
    await clientOld.send("old")
    var bufOld = newString(3)
    let nOld = await clientOld.recvInto(addr bufOld[0], 3)
    bufOld.setLen(nOld)
    check bufOld == "old"

    clientOld.close()
    clientNew.close()
    proxy.close()
    echoOld.close()
    echoNew.close()
    await sleepAsync(50)

  waitFor scenario()

# ---------------------------------------------------------------------------
# 9. Recording connection sources (recentSources)
# ---------------------------------------------------------------------------

test "connection sources are recorded in recentSources, and older ones are dropped past maxRecentSources":
  proc scenario() {.async.} =
    let echo = newEchoServerTcp(17320)
    asyncCheck echo.serve()

    let proxy = newForwardProxy("127.0.0.1", Port(17309), tcpTarget(17320))
    asyncCheck proxy.serve()

    let total = maxRecentSources + 2 # 5 + 2 = 7, the first 2 should be dropped
    var clients: seq[AsyncSocket] = @[]
    var expectedPorts: seq[Port] = @[]

    for i in 0 ..< total:
      let c = await newTcpClient(17309)
      let (_, localPort) = c.getLocalAddr()
      expectedPorts.add localPort
      clients.add c

    check await waitUntil(proc(): bool = proxy.stats.totalConns == total)
    let recentLen = proxy.stats.recentSources.len
    check recentLen == maxRecentSources

    var recordedPorts: seq[Port] = @[]
    for entry in proxy.stats.recentSources:
      check entry.address == "127.0.0.1"
      recordedPorts.add entry.port

    # The first (total - maxRecentSources) entries are dropped, leaving only
    # the most recent maxRecentSources entries
    let dropCount = expectedPorts.len - maxRecentSources
    var expectedRemaining: seq[Port] = @[]
    for i in dropCount ..< expectedPorts.len:
      expectedRemaining.add expectedPorts[i]
    check recordedPorts == expectedRemaining

    for c in clients: c.close()
    proxy.close()
    echo.close()
    await sleepAsync(50)

  waitFor scenario()
