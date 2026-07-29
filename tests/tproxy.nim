## proxy 層（stats / upstream / relay / listener）の単体テスト。
##
## ssh も実 SSH サーバも使わない。「内部エンドポイント役」として `asyncnet` で
## ダミーのエコーサーバを立て、プロキシ経由でデータを送って折り返しを確認する。

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
# テスト用ヘルパー
# ---------------------------------------------------------------------------

proc tcpTarget(port: int): UpstreamTarget =
  UpstreamTarget(kind: ukTcp, port: Port(port))

proc unixTarget(path: string): UpstreamTarget =
  UpstreamTarget(kind: ukUnix, path: path)

proc waitUntil(cond: proc(): bool {.closure.}; tries = 200;
               delayMs = 10): Future[bool] {.async.} =
  ## 条件が満たされるまでポーリングする。非同期処理のタイミング差を
  ## 吸収するためのテスト専用ヘルパー。
  for i in 0 ..< tries:
    if cond():
      return true
    await sleepAsync(delayMs)
  result = cond()

proc echoConn(sock: AsyncSocket) {.async.} =
  ## 受け取ったバイト列をそのまま送り返す1接続分のハンドラ。
  var buf = newString(65536)
  while true:
    let n = await sock.recvInto(addr buf[0], buf.len)
    if n <= 0: break
    await sock.send(addr buf[0], n)
  sock.close()

type
  EchoServer = ref object
    ## テストの「内部エンドポイント役」。ssh の代わりにこれを target にする。
    listener: AsyncSocket
    closing: bool

proc newEchoServerTcp(port: int): EchoServer =
  let l = newAsyncSocket(AF_INET, buffered = false)
  l.setSockOpt(OptReuseAddr, true)
  l.bindAddr(Port(port), "127.0.0.1")
  l.listen()
  EchoServer(listener: l, closing: false)

proc newEchoServerUnix(path: string): EchoServer =
  # fileExists は正規ファイルのみを見るため UDS には常に false を返す。
  # removeFile はファイルが存在しなくても失敗しないので無条件に呼ぶ。
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
# 1. 中継が通る & 2. バイト数が計上される
# ---------------------------------------------------------------------------

test "中継が通る & バイト数が計上される":
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
# 3. 接続数
# ---------------------------------------------------------------------------

test "接続数: activeConns / totalConns":
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
# 4. 上流が死んでいる
# ---------------------------------------------------------------------------

test "上流が死んでいる: クライアントは即 EOF、failedConns が増える":
  proc scenario() {.async.} =
    # 17314 は誰も listen していない TCP ポート
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
# 5. maxConns 超過
# ---------------------------------------------------------------------------

test "maxConns 超過: 2本目が即 close され rejectedConns が増える":
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
    # 2本目は拒否されただけで activeConns にはカウントされない
    check proxy.stats.activeConns == 1

    client1.close()
    client2.close()
    proxy.close()
    echo.close()
    await sleepAsync(50)

  waitFor scenario()

# ---------------------------------------------------------------------------
# 6. UDS 経路
# ---------------------------------------------------------------------------

test "UDS 経路でも中継・バイト数・接続数が成立する":
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
# 7. 大きめのデータ（RelayBufSize 超え）
# ---------------------------------------------------------------------------

test "RelayBufSize を超えるデータが壊れずに往復する":
  proc scenario() {.async.} =
    let echo = newEchoServerTcp(17317)
    asyncCheck echo.serve()

    let proxy = newForwardProxy("127.0.0.1", Port(17307), tcpTarget(17317))
    asyncCheck proxy.serve()

    let client = await newTcpClient(17307)

    # RelayBufSize の倍数からずらしたサイズにして、境界をまたぐ挙動も含める
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

test "retarget: 新規接続だけが新しい target に向く":
  proc scenario() {.async.} =
    let echoOld = newEchoServerTcp(17318)
    asyncCheck echoOld.serve()
    let echoNew = newEchoServerTcp(17319)
    asyncCheck echoNew.serve()

    let proxy = newForwardProxy("127.0.0.1", Port(17308), tcpTarget(17318))
    asyncCheck proxy.serve()

    # 旧 target 宛の接続を張ったままにする
    let clientOld = await newTcpClient(17308)
    check await waitUntil(proc(): bool = proxy.stats.activeConns == 1)

    proxy.retarget(tcpTarget(17319))

    # 新規接続は新 target に向く
    let clientNew = await newTcpClient(17308)
    check await waitUntil(proc(): bool = proxy.stats.activeConns == 2)

    await clientNew.send("new")
    var buf = newString(3)
    let n = await clientNew.recvInto(addr buf[0], 3)
    buf.setLen(n)
    check buf == "new"

    # 旧接続はまだ生きていて旧 target と話せる
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
# 9. 接続元の記録 (recentSources)
# ---------------------------------------------------------------------------

test "recentSources に接続元が記録され maxRecentSources を超えると古いものが落ちる":
  proc scenario() {.async.} =
    let echo = newEchoServerTcp(17320)
    asyncCheck echo.serve()

    let proxy = newForwardProxy("127.0.0.1", Port(17309), tcpTarget(17320))
    asyncCheck proxy.serve()

    let total = maxRecentSources + 2 # 5 + 2 = 7本、うち先頭2本が落ちるはず
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

    # 先頭 (total - maxRecentSources) 本は落ち、直近 maxRecentSources 本だけ残る
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
