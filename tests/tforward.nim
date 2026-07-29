## `powarder/daemon/forward` のテスト。
##
## 実 SSH サーバなしにテストするため、`tests/fixtures/ssh` という fake ssh を
## `PATH` の先頭に置いて powarder に `ssh` として掴ませる（`thostsession.nim` /
## `tmuxclient.nim` と同じ手法）。fake ssh は `-O forward` を受けても実際には
## UDS を作らないので、「forward が張られた状態」を模擬するために、テスト側で
## ダミーのエコーサーバを `paths.forwardSocketPath(udsBasename(id))` の
## 決定的なパスに自分で bind する（`tests/tproxy.nim` と同じ手法）。

import std/[unittest, os, options, monotimes, times, strutils]
import std/asyncdispatch
import std/asyncnet
import std/nativesockets

import powarder/core/types
import powarder/core/statemachine
import powarder/core/forwardspec
import powarder/core/paths
import powarder/core/errorclass
import powarder/daemon/hostsession
import powarder/daemon/forward
import powarder/proxy/listener
import powarder/proxy/stats

const fixturesDir = currentSourcePath().parentDir() / "fixtures"
const testRuntimeDir = "/tmp/pw-fwd-rt"
const testStateDir = "/tmp/pw-fwd-state"
const testLogFile = "/tmp/pw-fwd-log"

# ---------------------------------------------------------------------------
# セットアップ / ヘルパー
# ---------------------------------------------------------------------------

proc withMode(mode: string; body: proc()) =
  ## `POWARDER_FAKE_SSH_MODE` を一時的に切り替えてテスト本体を実行する。
  let had = existsEnv("POWARDER_FAKE_SSH_MODE")
  let old = getEnv("POWARDER_FAKE_SSH_MODE")
  putEnv("POWARDER_FAKE_SSH_MODE", mode)
  try:
    body()
  finally:
    if had: putEnv("POWARDER_FAKE_SSH_MODE", old)
    else: delEnv("POWARDER_FAKE_SSH_MODE")

proc withLog(body: proc()) =
  ## `POWARDER_FAKE_SSH_LOG` を一時的に有効にしてテスト本体を実行する。
  removeFile(testLogFile)
  putEnv("POWARDER_FAKE_SSH_LOG", testLogFile)
  try:
    body()
  finally:
    delEnv("POWARDER_FAKE_SSH_LOG")
    removeFile(testLogFile)

proc setupSuite() =
  removeDir(testRuntimeDir)
  createDir(testRuntimeDir)
  removeDir(testStateDir)
  createDir(testStateDir)
  putEnv("POWARDER_RUNTIME_DIR", testRuntimeDir)
  putEnv("POWARDER_STATE_DIR", testStateDir)
  let curPath = getEnv("PATH")
  if not curPath.startsWith(fixturesDir & ":"):
    putEnv("PATH", fixturesDir & ":" & curPath)
  delEnv("POWARDER_FAKE_SSH_MODE")
  delEnv("POWARDER_FAKE_SSH_LOG")

setupSuite()

var allSessions: seq[HostSession]
  ## 後片付け漏れを防ぐため、生成した HostSession を全部覚えておいて
  ## ファイルの末尾で teardown する（thostsession.nim と同じ手法）。

proc track(hs: HostSession): HostSession =
  allSessions.add(hs)
  hs

proc waitForHostState(hs: HostSession; target: HostSessionState;
                      timeoutMs = 5000): bool =
  ## `target` に達するまで hostsession.tick を呼び続ける。
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while hs.state != target:
    hostsession.tick(hs)
    if hs.state == target:
      return true
    if getMonoTime() >= deadline:
      return false
    sleep(20)
  true

proc stopAndCleanup(hs: HostSession) =
  requestStop(hs, immediate = true)
  discard waitForHostState(hs, hsStopped, timeoutMs = 5000)
  hostsession.teardown(hs)

proc pollForward(fw: Forward; cond: proc(): bool {.closure.}; tries = 300;
                 delayMs = 20): Future[bool] {.async.} =
  ## `tick(fw)` を呼びながら `cond` が満たされるのを待つ。`fw.tick` が
  ## 段階的に進める非同期の後始末（プロキシの Future 回収 / probeUpstream）
  ## にはイベントループを回す必要があるため `sleepAsync` で間を作る
  ## (`tests/tproxy.nim` の `waitUntil` と同じ手法)。
  for i in 0 ..< tries:
    tick(fw)
    if cond():
      return true
    await sleepAsync(delayMs)
  result = cond()

# ---- 「forward が張られた状態」を模擬するダミーのエコーサーバ (UDS) --------

type
  EchoServer = ref object
    listener: AsyncSocket
    closing: bool

proc echoConn(sock: AsyncSocket) {.async.} =
  var buf = newString(65536)
  while true:
    let n = await sock.recvInto(addr buf[0], buf.len)
    if n <= 0: break
    await sock.send(addr buf[0], n)
  sock.close()

proc newEchoServerUnix(path: string): EchoServer =
  removeFile(path) ## fileExists は UDS には常に false を返すが removeFile は無条件に呼んでよい
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
# 1. newForward: id と UDS パスの決定的な導出、参照カウント
# ---------------------------------------------------------------------------

suite "newForward":
  test "id は forwardId() から、UDS パスは udsBasename() から決定的に導出され、参照カウントが増える":
    withMode("ok", proc() =
      let hs = track(newHostSession("host-fwd-newforward"))
      let spec = ForwardSpec(kind: fkLocal, bindAddr: defaultBindAddr,
                              bindPort: Port(18101), targetHost: "db.internal",
                              targetPort: Port(5432))
      check refCount(hs) == 0

      let fw = newForward("t1", spec, hs)

      check fw.id == forwardspec.forwardId(spec, hs.host)
      check fw.upstream.kind == ukUnix
      check fw.upstream.path == forwardSocketPath(udsBasename(fw.id))
      check fw.state == fwPending
      check fw.proxy.isNone
      check refCount(hs) == 1
      check hs.forwardIds[0] == fw.id

      hostsession.teardown(hs))

  test "同じ spec なら同じ id になる（決定的）":
    withMode("ok", proc() =
      let hs = track(newHostSession("host-fwd-newforward-2"))
      let spec = ForwardSpec(kind: fkLocal, bindAddr: defaultBindAddr,
                              bindPort: Port(18111), targetHost: "db.internal",
                              targetPort: Port(5432))
      let fwA = newForward("a", spec, hs)
      let fwB = newForward("b", spec, hs)
      check fwA.id == fwB.id
      check refCount(hs) == 1 ## 同じ id の二重追加は hostsession 側で冪等

      hostsession.teardown(hs))

# ---------------------------------------------------------------------------
# 2. attach -> プロキシ経由で疎通 -> 統計が計上される
# ---------------------------------------------------------------------------

suite "attach -> 疎通 -> 統計":
  test "fwActive になり、bindPort への接続がエコーされ bytesRx/bytesTx が増える":
    withMode("ok", proc() =
      let hs = track(newHostSession("host-fwd-active"))
      let spec = ForwardSpec(kind: fkLocal, bindAddr: defaultBindAddr,
                              bindPort: Port(18102), targetHost: "db.internal",
                              targetPort: Port(5432))
      let fw = newForward("t2", spec, hs)
      check waitForHostState(hs, hsConnected)

      proc scenario() {.async.} =
        tick(fw)
        check fw.state == fwActive
        check fw.proxy.isSome

        let udsPath = fw.upstream.path
        let echo = newEchoServerUnix(udsPath)
        asyncCheck echo.serve()

        let client = await newTcpClient(18102)
        await client.send("hello")
        var buf = newString(5)
        let n = await client.recvInto(addr buf[0], 5)
        buf.setLen(n)
        check buf == "hello"

        check fw.stats().isSome
        check fw.stats().get().bytesRx >= 5
        check fw.stats().get().bytesTx >= 5
        check fw.stats().get().totalConns >= 1

        client.close()
        echo.close()
        removeFile(udsPath)
        await sleepAsync(50)

      waitFor scenario()

      forward.teardown(fw)
      stopAndCleanup(hs))

# ---------------------------------------------------------------------------
# 3. bind-failed: 1回だけ再試行してから fwError
# ---------------------------------------------------------------------------

suite "attach: bind-failed":
  test "1回だけ再試行し、それでも失敗すれば fwError になる（attachRetried が true）":
    withMode("bind-failed", proc() =
      let hs = track(newHostSession("host-fwd-bindfailed"))
      let spec = ForwardSpec(kind: fkLocal, bindAddr: defaultBindAddr,
                              bindPort: Port(18103), targetHost: "db.internal",
                              targetPort: Port(5432))
      let fw = newForward("t3", spec, hs)
      check waitForHostState(hs, hsConnected)

      tick(fw)
      check fw.state == fwError
      check fw.attachRetried
      check fw.proxy.isNone ## ssh 側が失敗したので powarder 側リスナーは起動されない

      forward.teardown(fw)
      stopAndCleanup(hs))

# ---------------------------------------------------------------------------
# 4. ユーザー指定ポートが既に使用中: ekPortInUse + ssh 側 forward の巻き戻し
# ---------------------------------------------------------------------------

suite "ユーザー指定ポートが使用中":
  test "newForwardProxy の bind 失敗で fwError + ekPortInUse になり、ssh 側が cancelForward で巻き戻される":
    withLog(proc() =
      withMode("ok", proc() =
        let hs = track(newHostSession("host-fwd-portinuse"))
        let blockerPort = Port(18104)

        var blocker = newAsyncSocket(buffered = false)
        blocker.setSockOpt(OptReuseAddr, true)
        blocker.bindAddr(blockerPort, defaultBindAddr)
        blocker.listen()

        let spec = ForwardSpec(kind: fkLocal, bindAddr: defaultBindAddr,
                                bindPort: blockerPort,
                                targetHost: "db.internal",
                                targetPort: Port(5432))
        let fw = newForward("t4", spec, hs)
        check waitForHostState(hs, hsConnected)

        tick(fw)
        check fw.state == fwError
        check fw.lastErrorKind == ekPortInUse
        check fw.proxy.isNone

        let logged = readFile(testLogFile)
        check "cancel" in logged ## ssh 側の forward が巻き戻された

        blocker.close()
        forward.teardown(fw)
        stopAndCleanup(hs)))

# ---------------------------------------------------------------------------
# 5. detach: プロキシが閉じる、cancel、UDS 残骸削除、参照カウント減少
# ---------------------------------------------------------------------------

suite "detach":
  test "プロキシが閉じてポートに繋がらなくなり、cancel が呼ばれ、UDS が消え、参照カウントが減る":
    withLog(proc() =
      withMode("ok", proc() =
        let hs = track(newHostSession("host-fwd-detach"))
        let spec = ForwardSpec(kind: fkLocal, bindAddr: defaultBindAddr,
                                bindPort: Port(18105),
                                    targetHost: "db.internal",
                                targetPort: Port(5432))
        let fw = newForward("t5", spec, hs)
        check waitForHostState(hs, hsConnected)
        check refCount(hs) == 1

        let udsPath = fw.upstream.path

        proc scenario() {.async.} =
          tick(fw)
          check fw.state == fwActive

          let echo = newEchoServerUnix(udsPath)
          asyncCheck echo.serve()

          let client = await newTcpClient(18105)
          await client.send("ping")
          var buf = newString(4)
          let n = await client.recvInto(addr buf[0], 4)
          buf.setLen(n)
          check buf == "ping"
          client.close()
          await sleepAsync(30)

          # ssh 側が forward を外した状態を模擬するため、フィクスチャの
          # エコーサーバを先に片付ける（cancel の副作用確認 = probeUpstream
          # の対象にする）。
          echo.close()
          removeFile(udsPath)
          await sleepAsync(30)

          requestDetach(fw)
          check fw.state == fwDetaching

          # 手順1（proxy.close）は requestDetach 内で同期的に行われるので、
          # 新規接続は即座に拒否されるはず。
          var refused = false
          try:
            discard await newTcpClient(18105)
          except OSError:
            refused = true
          check refused

          check await pollForward(fw, proc(): bool = isDiscardable(fw))
          check isDiscardable(fw)

        waitFor scenario()

        check refCount(hs) == 0
        check not socketExists(udsPath)

        let logged = readFile(testLogFile)
        check "cancel" in logged

        stopAndCleanup(hs)))

# ---------------------------------------------------------------------------
# 6. ★M4 の完了条件: 1本の失敗が他の forward もマスターも巻き込まない
# ---------------------------------------------------------------------------

suite "M4 完了条件":
  test "1本の forward を bind-failed で失敗させても、同じホストの他の forward もマスターも無傷":
    withMode("ok", proc() =
      let hs = track(newHostSession("host-fwd-m4"))

      let spec1 = ForwardSpec(kind: fkLocal, bindAddr: defaultBindAddr,
                              bindPort: Port(18106), targetHost: "db1.internal",
                              targetPort: Port(1))
      let fw1 = newForward("m4-1", spec1, hs)
      check waitForHostState(hs, hsConnected) ## master は ok モードで起動

      # fw1 の attach だけ bind-failed モードで行わせる
      putEnv("POWARDER_FAKE_SSH_MODE", "bind-failed")
      tick(fw1)
      check fw1.state == fwError
      check fw1.attachRetried
      putEnv("POWARDER_FAKE_SSH_MODE", "ok")

      check isConnected(hs) ## マスターは無傷
      check hs.state == hsConnected

      let spec2 = ForwardSpec(kind: fkLocal, bindAddr: defaultBindAddr,
                              bindPort: Port(18107), targetHost: "db2.internal",
                              targetPort: Port(2))
      let fw2 = newForward("m4-2", spec2, hs)
      tick(fw2)
      check fw2.state == fwActive
      check isConnected(hs) ## fw2 の成功後もマスターは無傷

      forward.teardown(fw1)
      forward.teardown(fw2)
      stopAndCleanup(hs))

# ---------------------------------------------------------------------------
# 7. feHostLost: ホストが hsConnected を離脱すると全 Forward が fwPending に戻る
# ---------------------------------------------------------------------------

suite "feHostLost":
  test "ホストが切断すると attach 済みの Forward がすべて fwPending に戻る":
    withMode("ok", proc() =
      let hs = track(newHostSession("host-fwd-hostlost"))

      let spec1 = ForwardSpec(kind: fkLocal, bindAddr: defaultBindAddr,
                              bindPort: Port(18108), targetHost: "db1.internal",
                              targetPort: Port(1))
      let spec2 = ForwardSpec(kind: fkLocal, bindAddr: defaultBindAddr,
                              bindPort: Port(18109), targetHost: "db2.internal",
                              targetPort: Port(2))
      let fw1 = newForward("hl-1", spec1, hs)
      let fw2 = newForward("hl-2", spec2, hs)
      check waitForHostState(hs, hsConnected)

      tick(fw1)
      tick(fw2)
      check fw1.state == fwActive
      check fw2.state == fwActive

      requestStop(hs, immediate = true)
      check waitForHostState(hs, hsStopped)

      tick(fw1)
      tick(fw2)
      check fw1.state == fwPending
      check fw2.state == fwPending

      forward.teardown(fw1)
      forward.teardown(fw2)
      hostsession.teardown(hs))

# ---------------------------------------------------------------------------
# 8. Tier3 ヘルスチェック
# ---------------------------------------------------------------------------

suite "Tier3 ヘルスチェック":
  test "failedConns が増えると consecutiveHealthFailures が増え、degradeThreshold で fwDegraded になる":
    withMode("ok", proc() =
      let hs = track(newHostSession("host-fwd-health"))
      let spec = ForwardSpec(kind: fkLocal, bindAddr: defaultBindAddr,
                              bindPort: Port(18110), targetHost: "db.internal",
                              targetPort: Port(5432))
      let fw = newForward("t8", spec, hs)
      check waitForHostState(hs, hsConnected)

      tick(fw)
      check fw.state == fwActive
      check fw.proxy.isSome

      for i in 1 .. statemachine.degradeThreshold:
        fw.proxy.get().stats.recordFailed() ## 実トラフィックの副産物を手で模擬する
        tick(fw)
        check fw.consecutiveHealthFailures == i

      check fw.state == fwDegraded

      forward.teardown(fw)
      stopAndCleanup(hs))

# ---------------------------------------------------------------------------
# 9. fkRemote: プロキシは起動されず、stats は none、それでも fwActive になる
# ---------------------------------------------------------------------------

suite "fkRemote":
  test "プロキシを起動せず stats も none だが fwActive になる":
    withMode("ok", proc() =
      let hs = track(newHostSession("host-fwd-remote"))
      let spec = ForwardSpec(kind: fkRemote, bindAddr: defaultBindAddr,
                             bindPort: Port(18112),
                                 targetHost: "internal.example",
                             targetPort: Port(80))
      let fw = newForward("t9", spec, hs)
      check waitForHostState(hs, hsConnected)

      tick(fw)
      check fw.state == fwActive
      check fw.proxy.isNone
      check fw.stats().isNone

      forward.teardown(fw)
      stopAndCleanup(hs))

# ---------------------------------------------------------------------------
# 後片付け: すべてのマスターを teardown し、ランタイム/状態ディレクトリを消す
# ---------------------------------------------------------------------------

for hs in allSessions:
  hostsession.teardown(hs) ## 各テストで既に止めていれば一瞬で終わる安全網

removeDir(testRuntimeDir)
removeDir(testStateDir)
delEnv("POWARDER_FAKE_SSH_MODE")
delEnv("POWARDER_FAKE_SSH_LOG")
delEnv("POWARDER_RUNTIME_DIR")
delEnv("POWARDER_STATE_DIR")
