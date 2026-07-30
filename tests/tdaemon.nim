## `powarder/daemon/run` のテスト。
##
## 実 SSH サーバなしにテストするため、`tests/fixtures/ssh` という fake ssh を
## `PATH` の先頭に置いて powarder に `ssh` として掴ませる（`tforward.nim` /
## `treconcile.nim` と同じ手法。環境構築もそのまま踏襲する）。
##
## `runDaemon()` は無限ループ（`mainLoop`）を回すため、テストプロセス内で直接
## 呼ぶことはできない。加えて `tests/tipc.nim` で判明した通り、asyncdispatch
## （`newAsyncSocket` に一度でも触れる）を使った**後**に `fork()` すると、子の
## kqueue fd が壊れて `accept()` が失敗するようになる。
##
## そのため、このファイルでは方針を使い分ける:
##
## 1. **多重起動防止**（1本目）だけは `fork()` を使う。ただし forked された
##    子プロセスは「ロック取得に失敗 -> `newIpcServer` 等の asyncdispatch には
##    一切触れずに即座に return 7」という経路しか通らないので、親プロセスが
##    このテストの前後で asyncdispatch に触れていても子は影響を受けない
##    （`tests/tplatform.nim` と同じ fork の使い方）。
## 2. **それ以外の全テスト**は `newDaemon()` でハンドラ一式を持つ `Daemon` を
##    直接構築し、`d.server.handlers[methodName](params)` を IPC ソケット越しに
##    経由せず直接呼ぶ。ハンドラは素の `proc (params: JsonNode): JsonNode`
##    なので、実際のソケット通信・accept ループ（`serve()`）を一切回さずに
##    RPC スキーマとロジックを検証できる。
## 3. メインループを進める必要があるテスト（`tunnel.up` 後に実際に
##    `fwActive` になるのを待つ、など）は、公開 proc `tickOnce(d)` を
##    `waitFor` の中で繰り返し呼ぶ（`treconcile.nim` の `waitUntil` /
##    `pollAsync` と同じ「ポーリングしながら async イベントループを回す」手法）。

import std/[unittest, os, posix, json, tables, strutils]
import std/asyncdispatch
import std/nativesockets ## `ForwardSpec` の自動生成 `==` などが `Port` の `==` を
                          ## 使うために必要（他のテストファイルと同じ理由）。

import powarder/core/types
import powarder/core/paths
import powarder/config/configfile
import powarder/platform/lock
import powarder/daemon/registry
import powarder/ipc/protocol
import powarder/ipc/server
import powarder/daemon/run

const fixturesDir = currentSourcePath().parentDir() / "fixtures"
const testRuntimeDir = "/tmp/pw-d-rt"
const testStateDir = "/tmp/pw-d-state"
const testConfigDir = "/tmp/pw-d-cfg"

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

proc setupSuite() =
  removeDir(testRuntimeDir)
  createDir(testRuntimeDir)
  removeDir(testStateDir)
  createDir(testStateDir)
  removeDir(testConfigDir)
  createDir(testConfigDir)
  putEnv(envRuntimeDir, testRuntimeDir)
  putEnv(envStateDir, testStateDir)
  let curPath = getEnv("PATH")
  if not curPath.startsWith(fixturesDir & ":"):
    putEnv("PATH", fixturesDir & ":" & curPath)
  delEnv("POWARDER_FAKE_SSH_MODE")
  delEnv("POWARDER_FAKE_SSH_LOG")

setupSuite()

proc processAlive(pid: int): bool =
  ## `platform/procinfo.pidAlive` と同じ判定だが、`platform/` のうち
  ## run.nim が使わないモジュールへは依存しないという既存テストの慣習
  ## （`treconcile.nim` の同名ヘルパーの doc comment を参照）に倣い、
  ## テスト内で最小限だけ複製する。
  if kill(Pid(pid), 0.cint) == 0:
    return true
  cint(osLastError()) == EPERM

var allDaemons: seq[Daemon]
  ## 後片付け漏れを防ぐため、生成した Daemon を全部覚えておいてファイルの
  ## 末尾で shutdown する（`treconcile.nim` の `allRegistries` と同じ手法）。

proc track(d: Daemon): Daemon =
  allDaemons.add(d)
  d

var daemonCounter = 0

proc freshOpts(tunnels: seq[TunnelConfig] = @[];
    activeProfiles: seq[string] = @[]): DaemonOpts =
  ## テストごとに独立した設定ファイル・ソケットパスを持つ `DaemonOpts` を作る。
  inc daemonCounter
  let cfgPath = testConfigDir / ("cfg-" & $daemonCounter & ".json")
  saveConfig(cfgPath, ConfigFile(version: 1, tunnels: tunnels,
      forbiddenKeyWarnings: @[]))
  DaemonOpts(configPath: cfgPath,
      socketPath: testRuntimeDir / ("d-" & $daemonCounter & ".sock"),
      activeProfiles: activeProfiles, tickIntervalMs: 50,
      stateSaveIntervalMs: 200)

proc newTc(name, host: string; spec: ForwardSpec; autostart = true;
    profile = ""): TunnelConfig =
  TunnelConfig(name: name, host: host, spec: spec, autostart: autostart,
      profile: profile, sshExtraArgs: @[], retry: initRetryPolicy())

proc waitUntilD(d: Daemon; cond: proc(): bool {.closure.}; tries = 300;
    delayMs = 20): Future[bool] {.async.} =
  ## `tickOnce` を呼びながら `cond` が満たされるのを待つ。detach の副作用確認
  ## （`probeUpstream`）や attach の完了はイベントループを回す必要があるため
  ## `sleepAsync` で間を作る（`treconcile.pollAsync` と同じ手法）。
  for i in 0 ..< tries:
    discard await d.tickOnce()
    if cond():
      return true
    await sleepAsync(delayMs)
  result = cond()

proc listAll(d: Daemon): JsonNode =
  d.server.handlers[mTunnelList](%*{"all": true})

proc findEntry(list: JsonNode; name: string): JsonNode =
  for e in list:
    if e["name"].getStr == name:
      return e
  nil

# ---------------------------------------------------------------------------
# 1. 多重起動防止: ロックを保持中に runDaemon すると終了コード7
# ---------------------------------------------------------------------------

suite "多重起動防止":
  test "ロックを保持している間に runDaemon すると終了コード7で終了する":
    let rt = "/tmp/pw-d-lock-rt"
    removeDir(rt)
    createDir(rt)
    let hadRt = existsEnv(envRuntimeDir)
    let oldRt = getEnv(envRuntimeDir)
    putEnv(envRuntimeDir, rt)

    let heldLock = acquireSingletonLock(lockPath())
    heldLock.writePid(getCurrentProcessId())

    let pid = fork()
    if pid == 0:
      # 子プロセス: ロック取得に失敗し、`newIpcServer`（asyncdispatch）には
      # 一切触れずに即座に return する経路しか通らない。したがって親プロセスが
      # このテストの前後で asyncdispatch を使っていても子には影響しない
      # （run.nim モジュール doc comment / このファイル冒頭の設計メモ参照）。
      let code = runDaemon(DaemonOpts(socketPath: rt / "sub.sock"))
      exitnow(code.cint)

    var status: cint
    discard waitpid(pid, status, 0)
    check WIFEXITED(status)
    check WEXITSTATUS(status) == exitAlreadyRunning
    check WEXITSTATUS(status) == 7

    heldLock.release()
    if hadRt: putEnv(envRuntimeDir, oldRt)
    else: delEnv(envRuntimeDir)
    removeDir(rt)

# ---------------------------------------------------------------------------
# 2. daemon.ping / daemon.info
# ---------------------------------------------------------------------------

suite "daemon.ping / daemon.info":
  test "daemon.ping は ok/pid/version を返す":
    let d = track(newDaemon(freshOpts()))
    let res = d.server.handlers[mDaemonPing](nil)
    check res["ok"].getBool == true
    check res["pid"].getInt == getCurrentProcessId()
    check res["version"].getStr == daemonVersion
    shutdown(d)

  test "daemon.info はスキーマ通りのフィールドを持つ":
    let d = track(newDaemon(freshOpts()))
    let res = d.server.handlers[mDaemonInfo](nil)
    check res["pid"].getInt == getCurrentProcessId()
    check res["version"].getStr == daemonVersion
    check res["socket"].getStr == d.server.path
    check res["uptime_seconds"].getInt >= 0
    check res["started_at"].getStr.len > 0
    check res["hosts"].getInt == 0
    check res["forwards"].getInt == 0
    check res["config_path"].getStr == d.opts.configPath
    shutdown(d)

# ---------------------------------------------------------------------------
# 3. tunnel.up でトンネルが登録され、tunnel.list に現れる
# ---------------------------------------------------------------------------

suite "tunnel.up / tunnel.list":
  test "tunnel.up でトンネルが登録され、tunnel.list に現れる":
    let spec = ForwardSpec(kind: fkLocal, bindAddr: defaultBindAddr,
        bindPort: Port(19301), targetHost: "db.internal", targetPort: Port(5432))
    let tc = newTc("up-1", "host-daemon-up-1", spec, autostart = false)
    let d = track(newDaemon(freshOpts(@[tc])))

    withMode("ok", proc() =
      proc scenario() {.async.} =
        # autostart = false かつ override 無しなので、up 前は無効（"stopped"）表示
        block:
          let before = findEntry(listAll(d), "up-1")
          check before != nil
          check before["status"].getStr == "stopped"
          check before["state"].getStr != "fwActive"

        let upRes = d.server.handlers[mTunnelUp](%*{"names": %*["up-1"]})
        check upRes["started"].len == 1
        check upRes["started"][0].getStr == "up-1"
        check upRes["failed"].len == 0

        check await waitUntilD(d, proc(): bool =
          let e = findEntry(listAll(d), "up-1")
          e != nil and e["state"].getStr == "fwActive")

      waitFor scenario())
    shutdown(d)

  test "存在しない名前を指定すると failed に入る":
    let d = track(newDaemon(freshOpts(@[])))
    let res = d.server.handlers[mTunnelUp](%*{"names": %*["no-such-tunnel"]})
    check res["started"].len == 0
    check res["failed"].len == 1
    check res["failed"][0]["name"].getStr == "no-such-tunnel"
    shutdown(d)

# ---------------------------------------------------------------------------
# 4. tunnel.list: -R の行では conns/total_conns/rx/tx/last_activity_seconds が null
# ---------------------------------------------------------------------------

suite "tunnel.list: -R の統計は null":
  test "-R のトンネルは conns/total_conns/rx/tx/last_activity_seconds が null":
    let spec = ForwardSpec(kind: fkRemote, bindAddr: defaultBindAddr,
        bindPort: Port(19302), targetHost: "internal.example", targetPort: Port(80))
    let tc = newTc("remote-1", "host-daemon-remote-1", spec, autostart = true)
    let d = track(newDaemon(freshOpts(@[tc])))

    withMode("ok", proc() =
      proc scenario() {.async.} =
        check await waitUntilD(d, proc(): bool =
          let e = findEntry(listAll(d), "remote-1")
          e != nil and e["state"].getStr == "fwActive")

        let e = findEntry(listAll(d), "remote-1")
        check e["type"].getStr == "R"
        check e["conns"].kind == JNull
        check e["total_conns"].kind == JNull
        check e["rx"].kind == JNull
        check e["tx"].kind == JNull
        check e["last_activity_seconds"].kind == JNull
      waitFor scenario())
    shutdown(d)

# ---------------------------------------------------------------------------
# 5. tunnel.stop → 状態が変わり、reload しても勝手に再開しない
# ---------------------------------------------------------------------------

suite "tunnel.stop と daemon.reload":
  test "stop 後は fwActive でなくなり、無関係な reload をしても再開しない":
    let spec = ForwardSpec(kind: fkLocal, bindAddr: defaultBindAddr,
        bindPort: Port(19303), targetHost: "db.internal", targetPort: Port(5432))
    let tc = newTc("stop-1", "host-daemon-stop-1", spec, autostart = true)
    let d = track(newDaemon(freshOpts(@[tc])))

    withMode("ok", proc() =
      proc scenario() {.async.} =
        check await waitUntilD(d, proc(): bool =
          let e = findEntry(listAll(d), "stop-1")
          e != nil and e["state"].getStr == "fwActive")

        let stopRes = d.server.handlers["tunnel.stop"](%*{"names": %*["stop-1"]})
        check stopRes["stopped"][0].getStr == "stop-1"

        # 同期的に反映される（reconcile はハンドラの中で直接呼ばれる）
        block:
          let e = findEntry(listAll(d), "stop-1")
          check e != nil
          check e["state"].getStr != "fwActive"

        # 数 tick 進めても再度 fwActive にはならない
        for i in 0 ..< 5:
          discard await d.tickOnce()
          await sleepAsync(20)
        check findEntry(listAll(d), "stop-1")["state"].getStr != "fwActive"

        # 無関係な reload をしても勝手に再開しない
        discard d.server.handlers[mDaemonReload](nil)
        for i in 0 ..< 5:
          discard await d.tickOnce()
          await sleepAsync(20)
        check findEntry(listAll(d), "stop-1")["state"].getStr != "fwActive"
        check isEnabled(d.reg, "stop-1", tc.autostart) == false

      waitFor scenario())
    shutdown(d)

# ---------------------------------------------------------------------------
# 6. 同じ host の2トンネルが1つのマスターを共有し、host.list が1件だけ返す
# ---------------------------------------------------------------------------

suite "マスター共有":
  test "同じ host を指す2トンネルが1つのマスターを共有し、host.list が1件だけ返す":
    let hostName = "host-daemon-shared"
    let spec1 = ForwardSpec(kind: fkLocal, bindAddr: defaultBindAddr,
        bindPort: Port(19304), targetHost: "db1.internal", targetPort: Port(1))
    let spec2 = ForwardSpec(kind: fkLocal, bindAddr: defaultBindAddr,
        bindPort: Port(19305), targetHost: "db2.internal", targetPort: Port(2))
    let tc1 = newTc("share-a", hostName, spec1, autostart = true)
    let tc2 = newTc("share-b", hostName, spec2, autostart = true)
    let d = track(newDaemon(freshOpts(@[tc1, tc2])))

    withMode("ok", proc() =
      proc scenario() {.async.} =
        check await waitUntilD(d, proc(): bool =
          let l = listAll(d)
          if l.len != 2: return false
          for e in l:
            if e["state"].getStr != "fwActive": return false
          true)

        let hosts = d.server.handlers[mHostList](nil)
        check hosts.len == 1
        check hosts[0]["host"].getStr == hostName
        check hosts[0]["tunnels"].getInt == 2
      waitFor scenario())
    shutdown(d)

# ---------------------------------------------------------------------------
# 7. tunnel.inspect: 存在しない名前は RpcError(errTunnelNotFound)
# ---------------------------------------------------------------------------

suite "tunnel.inspect":
  test "存在しないトンネル名は RpcError(errTunnelNotFound)":
    let d = track(newDaemon(freshOpts(@[])))
    var caught = false
    try:
      discard d.server.handlers[mTunnelInspect](%*{"name": "no-such"})
    except RpcError as e:
      caught = true
      check e.code == errTunnelNotFound
    check caught
    shutdown(d)

# ---------------------------------------------------------------------------
# 8. daemon.reload: 設定の変更を反映する
# ---------------------------------------------------------------------------

suite "daemon.reload":
  test "設定に1つトンネルを追加してから reload すると反映される":
    let spec0 = ForwardSpec(kind: fkLocal, bindAddr: defaultBindAddr,
        bindPort: Port(19306), targetHost: "db.internal", targetPort: Port(5432))
    let tc0 = newTc("base-1", "host-daemon-base-1", spec0, autostart = true)
    let opts = freshOpts(@[tc0])
    let d = track(newDaemon(opts))

    withMode("ok", proc() =
      proc scenario() {.async.} =
        check await waitUntilD(d, proc(): bool = listAll(d).len == 1)

        let spec1 = ForwardSpec(kind: fkLocal, bindAddr: defaultBindAddr,
            bindPort: Port(19307), targetHost: "db2.internal", targetPort: Port(2))
        let tc1 = newTc("added-1", "host-daemon-added-1", spec1,
            autostart = true)
        saveConfig(opts.configPath, ConfigFile(version: 1, tunnels: @[tc0, tc1],
            forbiddenKeyWarnings: @[]))

        let reloadRes = d.server.handlers[mDaemonReload](nil)
        check reloadRes["tunnels"].getInt == 2
        check reloadRes.hasKey("actions")
        check reloadRes.hasKey("warnings")

        check await waitUntilD(d, proc(): bool =
          let l = listAll(d)
          l.len == 2 and findEntry(l, "added-1") != nil)
      waitFor scenario())
    shutdown(d)

# ---------------------------------------------------------------------------
# 9. ハンドラが例外を投げてもデーモンの状態が壊れない
# ---------------------------------------------------------------------------

suite "ハンドラの例外耐性":
  test "ハンドラが例外を投げても daemon の状態は壊れず、他のハンドラは動き続ける":
    let d = track(newDaemon(freshOpts(@[])))
    d.server.register("test.boom", proc(p: JsonNode): JsonNode =
      raise newException(ValueError, "boom"))

    var caught = false
    try:
      discard d.server.handlers["test.boom"](nil)
    except ValueError:
      caught = true
    check caught

    # daemon の状態は壊れておらず、他のハンドラは引き続き動く
    check d.reg.forwards.len == 0
    check d.reg.hosts.len == 0
    let pingRes = d.server.handlers[mDaemonPing](nil)
    check pingRes["ok"].getBool == true
    shutdown(d)

# ---------------------------------------------------------------------------
# 10. graceful shutdown: reg.forwards / reg.hosts が空になり、残骸が無い
# ---------------------------------------------------------------------------

suite "graceful shutdown":
  test "shutdown 後に reg.forwards / reg.hosts が空になり、プロセスの残骸が無い":
    let spec = ForwardSpec(kind: fkLocal, bindAddr: defaultBindAddr,
        bindPort: Port(19308), targetHost: "db.internal", targetPort: Port(5432))
    let tc = newTc("shutdown-1", "host-daemon-shutdown-1", spec,
        autostart = true)
    let d = newDaemon(freshOpts(@[tc])) ## この test 自身で shutdown まで確認するので track しない

    withMode("ok", proc() =
      proc scenario() {.async.} =
        check await waitUntilD(d, proc(): bool =
          let e = findEntry(listAll(d), "shutdown-1")
          e != nil and e["state"].getStr == "fwActive")

        let hosts = d.server.handlers[mHostList](nil)
        let hpid = hosts[0]["pid"].getInt
        check hpid > 0
        check processAlive(hpid)

        let sockPath = d.server.path
        shutdown(d)

        check d.reg.forwards.len == 0
        check d.reg.hosts.len == 0
        check not processAlive(hpid)
        check not socketExists(sockPath)
      waitFor scenario())

# ---------------------------------------------------------------------------
# 後片付け: すべての Daemon を shutdown し、ランタイム/状態/設定ディレクトリを消す
# ---------------------------------------------------------------------------

for d in allDaemons:
  shutdown(d) ## 各テストで既に片付けていれば一瞬で終わる安全網

removeDir(testRuntimeDir)
removeDir(testStateDir)
removeDir(testConfigDir)
delEnv("POWARDER_FAKE_SSH_MODE")
delEnv("POWARDER_FAKE_SSH_LOG")
delEnv(envRuntimeDir)
delEnv(envStateDir)

# fake ssh のリスナー（nc / python3 / perl）は、`hostsession.teardown` が最終手段の
# SIGKILL を送ると fake ssh 側の trap が発火しないため孤児化して残る。残ったままだと
# 親から継承した pipe が閉じず、`nimble test` が EOF を待って**ハングする**
# （実測: Linux コンテナで3時間ハングした）。fake ssh 側で fd を閉じる方法は
# dash の挙動と asyncdispatch の fd 継承の2点で壊れたため、ここで確実に掃除する。
#
# `[p]` のブラケットは `pkill` が自分自身のコマンドラインにマッチして自滅するのを
# 防ぐための定石（実測で踏んだ。exit 144 になる）。
discard execShellCmd("pkill -f '" & testRuntimeDir & "' >/dev/null 2>&1 || true")
