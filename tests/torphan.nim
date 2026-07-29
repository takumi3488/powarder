## `powarder/daemon/orphan` のテスト。
##
## 実 SSH サーバなしにテストするため、`tests/fixtures/ssh` という fake ssh を
## `PATH` の先頭に置いて powarder に `ssh` として掴ませる（`tdaemon.nim` /
## `thostsession.nim` と同じ手法。環境構築もそのまま踏襲する）。
##
## 「生きているマスター」を作る必要があるテスト（aoAdopted / aoMismatch /
## fkLocal の adopt）は、`daemon/hostsession.spawnMaster` と同じ手順
## （`muxclient.masterCommandLine` を組んで `startProcess`）を自前で行い、
## fake ssh の `-M -N` モードで実際に UDS 制御ソケットを持つプロセスを
## 立ち上げる。テストプロセス自身がその子プロセスの親になるので、後始末は
## `terminate` + `waitForExit` で確実に行う（adopt 側が「自分の子ではない」
## 前提で動くこととは独立に、テスト自身はちゃんと親として刈り取る）。

import std/[unittest, os, options, monotimes, times, strutils, osproc, tables]
import std/asyncnet
import std/nativesockets

import powarder/core/types
import powarder/core/paths
import powarder/config/statefile
import powarder/daemon/muxclient
import powarder/daemon/hostsession
import powarder/daemon/forward
import powarder/daemon/registry
import powarder/daemon/orphan

const fixturesDir = currentSourcePath().parentDir() / "fixtures"
const testRuntimeDir = "/tmp/pw-orp-rt"

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
  putEnv("POWARDER_RUNTIME_DIR", testRuntimeDir)
  let curPath = getEnv("PATH")
  if not curPath.startsWith(fixturesDir & ":"):
    putEnv("PATH", fixturesDir & ":" & curPath)
  delEnv("POWARDER_FAKE_SSH_MODE")
  delEnv("POWARDER_FAKE_SSH_LOG")

setupSuite()

var allMasters: seq[Process]
  ## 後片付け漏れを防ぐため、テストで自前起動した fake ssh マスターを
  ## 全部覚えておいてファイルの末尾で確実に terminate する。

proc trackMaster(p: Process): Process =
  allMasters.add(p)
  p

proc startFakeMaster(host, ctlPath, logPath: string): Process =
  ## `hostsession.spawnMaster` と同じ手順で fake ssh の `-M -N` マスターを
  ## 直接起動する（`adoptOrphans` の対象は「デーモンが管理していない
  ## 既存プロセス」なので、`HostSession` は経由せずここで自前に起動する）。
  let cmd = masterCommandLine(ctlPath, logPath, host)
  result = trackMaster(startProcess(cmd[0], args = cmd[1 .. ^1], options = {}))

proc stopFakeMaster(p: Process; ctlPath: string) =
  try:
    p.terminate()
  except OSError:
    discard
  discard p.waitForExit()
  try:
    p.close()
  except CatchableError:
    discard
  removeFile(ctlPath)
  removeFile(ctlPath & ".pid")

proc waitForSocket(path: string; timeoutMs = 3000): bool =
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while not socketExists(path):
    if getMonoTime() >= deadline:
      return false
    sleep(20)
  true

proc touchDeadSocket(path: string) =
  ## `bind` だけして `listen` しない UNIX ソケットファイルを作る。
  ## listen していない UDS への `connect` は `ECONNREFUSED` になる
  ## （実測どおりの「マスター死亡・ソケットファイルは残っている」を模擬する）。
  removeFile(path)
  let s = newAsyncSocket(AF_UNIX, SOCK_STREAM, IPPROTO_NONE, buffered = false)
  s.bindUnix(path)
  s.close()

proc newUnixListener(path: string): AsyncSocket =
  ## `bind` + `listen` する UNIX ソケット。`accept` を回さなくても、
  ## listen backlog があるので `connect` はカーネルレベルで即座に成立する
  ## （`probeUpstream` は connect + 即 close だけなのでこれで十分）。
  removeFile(path)
  result = newAsyncSocket(AF_UNIX, SOCK_STREAM, IPPROTO_NONE, buffered = false)
  result.bindUnix(path)
  result.listen()

var portCounter = 18300
proc nextPort(): Port =
  inc portCounter
  Port(portCounter)

# ---------------------------------------------------------------------------
# 1. 制御ソケットが無い記録 -> aoNoSocket
# ---------------------------------------------------------------------------

suite "aoNoSocket":
  test "制御ソケットが無い記録は aoNoSocket になり、記録が捨てられる":
    let reg = newRegistry()
    let st = PersistedState(version: 1, savedAt: "", hosts: @[
      PersistedHostSession(host: "h-nosocket", fingerprint: "fp-nosocket",
          ctlPath: testRuntimeDir / "does-not-exist.sock",
          logPath: testRuntimeDir / "h-nosocket.log", pid: 999999,
          argv: @[], state: hsConnected, forwardIds: @[])
    ], forwards: @[])

    let report = adoptOrphans(reg, st)

    check report.hosts.len == 1
    check report.hosts[0].host == "h-nosocket"
    check report.hosts[0].outcome == aoNoSocket
    check reg.hosts.len == 0

# ---------------------------------------------------------------------------
# 2. -O check が失敗する記録 -> aoDeadReclaimed、残骸ソケット削除
# ---------------------------------------------------------------------------

suite "aoDeadReclaimed":
  test "-O check が失敗する記録は aoDeadReclaimed になり、残骸ソケットが削除される":
    withMode("no-master", proc() =
      let ctlPath = testRuntimeDir / "dead.sock"
      touchDeadSocket(ctlPath)
      check socketExists(ctlPath)

      let reg = newRegistry()
      let st = PersistedState(version: 1, savedAt: "", hosts: @[
        PersistedHostSession(host: "h-dead", fingerprint: "fp-dead",
            ctlPath: ctlPath, logPath: testRuntimeDir / "h-dead.log",
            pid: 999998, argv: @[], state: hsConnected, forwardIds: @[])
      ], forwards: @[])

      let report = adoptOrphans(reg, st)

      check report.hosts.len == 1
      check report.hosts[0].outcome == aoDeadReclaimed
      check report.staleSocketsRemoved == 1
      check not socketExists(ctlPath)
      check reg.hosts.len == 0)

# ---------------------------------------------------------------------------
# 3. 生きているマスター -> aoAdopted、adopted=true で登録
# 8. adopted ホストは process.isNone。tick を繰り返しても peekExitCode を
#    使わない（クラッシュしない）
# ---------------------------------------------------------------------------

suite "aoAdopted":
  test "生きているマスターが aoAdopted になり、reg.hosts に adopted=true で登録される。process.isNone で tick してもクラッシュしない":
    withMode("ok", proc() =
      let host = "adopt-host-alive"
      let ctlPath = testRuntimeDir / "alive.sock"
      let logPath = testRuntimeDir / "alive.log"
      let p = startFakeMaster(host, ctlPath, logPath)
      check waitForSocket(ctlPath)
      let pid = p.processID()

      let reg = newRegistry()
      let st = PersistedState(version: 1, savedAt: "", hosts: @[
        PersistedHostSession(host: host, fingerprint: "fp-alive",
            ctlPath: ctlPath, logPath: logPath, pid: pid,
            argv: @[ctlPath, host], state: hsConnected, forwardIds: @[])
      ], forwards: @[])

      let report = adoptOrphans(reg, st)

      check report.hosts.len == 1
      check report.hosts[0].outcome == aoAdopted
      check reg.hosts.len == 1

      var adoptedHs: HostSession = nil
      for hs in reg.hosts.values:
        adoptedHs = hs
      check adoptedHs != nil
      check adoptedHs.adopted
      check adoptedHs.process.isNone ## ★項目8: 自分の子ではないので process は常に none
      check adoptedHs.state == hsConnected
      check adoptedHs.pid == pid

      # ★項目8続き: `process` が none でも `tick` を繰り返し呼んでクラッシュ
      # しないこと（`ownProcessExited` が `peekExitCode` を呼ぼうとすると
      # `Option` の unpack で例外になる）。
      for i in 0 ..< 5:
        tick(adoptedHs)
        check adoptedHs.state == hsConnected

      stopFakeMaster(p, ctlPath))

# ---------------------------------------------------------------------------
# 4. cmdline が一致しない -> aoMismatch、何もしない
# ---------------------------------------------------------------------------

suite "aoMismatch":
  test "cmdlineMatches が一致しない記録は aoMismatch になり、何もしない":
    withMode("ok", proc() =
      let host = "adopt-host-mismatch"
      let ctlPath = testRuntimeDir / "mismatch.sock"
      let logPath = testRuntimeDir / "mismatch.log"
      let p = startFakeMaster(host, ctlPath, logPath)
      check waitForSocket(ctlPath)
      let pid = p.processID()

      let reg = newRegistry()
      let st = PersistedState(version: 1, savedAt: "", hosts: @[
        PersistedHostSession(host: host, fingerprint: "fp-mismatch",
            ctlPath: ctlPath, logPath: logPath, pid: pid,
            argv: @["this-argv-does-not-match-anything-zzz"],
            state: hsConnected, forwardIds: @[])
      ], forwards: @[])

      let report = adoptOrphans(reg, st)

      check report.hosts.len == 1
      check report.hosts[0].outcome == aoMismatch
      check reg.hosts.len == 0 ## adopt していない

      stopFakeMaster(p, ctlPath))

# ---------------------------------------------------------------------------
# 5. UDS が生きている fkLocal Forward -> fwActive として引き継がれる
# 6. UDS が死んでいる fkLocal Forward -> 残骸削除 + fwPending
# 7. fkRemote Forward -> 楽観的に fwPending
# ---------------------------------------------------------------------------

suite "forward の adopt":
  test "UDS が生きている fkLocal は fwActive として引き継がれる":
    withMode("ok", proc() =
      let host = "adopt-host-fwd-alive"
      let ctlPath = testRuntimeDir / "fwd-alive-host.sock"
      let logPath = testRuntimeDir / "fwd-alive-host.log"
      let p = startFakeMaster(host, ctlPath, logPath)
      check waitForSocket(ctlPath)
      let pid = p.processID()

      let udsPath = testRuntimeDir / "fwd-alive.uds"
      let listener = newUnixListener(udsPath)

      let spec = ForwardSpec(kind: fkLocal, bindAddr: defaultBindAddr,
          bindPort: nextPort(), targetHost: "db.internal", targetPort: Port(5432))

      let reg = newRegistry()
      let st = PersistedState(version: 1, savedAt: "", hosts: @[
        PersistedHostSession(host: host, fingerprint: "fp-fwd-alive",
            ctlPath: ctlPath, logPath: logPath, pid: pid,
            argv: @[ctlPath, host], state: hsConnected,
            forwardIds: @["fwd-alive-id"])
      ], forwards: @[
        PersistedForward(id: "fwd-alive-id", tunnelName: "t-alive",
            spec: spec, state: fwActive, udsPath: udsPath)
      ])

      let report = adoptOrphans(reg, st)

      check report.hosts[0].outcome == aoAdopted
      # `report.adoptedForwards` には `forward.adoptForward` が決定的に導出した
      # `fw.id`（`forwardId(spec, host)`）が入る。persisted 側の id
      # （"fwd-alive-id"）とは無関係なので、内容ではなく件数だけを見る。
      check report.adoptedForwards.len == 1
      check report.reattachForwards.len == 0

      let fws = forwardsOfTunnel(reg, "t-alive")
      check fws.len == 1
      check fws[0].state == fwActive
      check fws[0].proxy.isSome

      listener.close()
      removeFile(udsPath)
      forward.teardown(fws[0])
      stopFakeMaster(p, ctlPath))

  test "UDS が死んでいる fkLocal は残骸が削除されて fwPending になる":
    withMode("ok", proc() =
      let host = "adopt-host-fwd-dead"
      let ctlPath = testRuntimeDir / "fwd-dead-host.sock"
      let logPath = testRuntimeDir / "fwd-dead-host.log"
      let p = startFakeMaster(host, ctlPath, logPath)
      check waitForSocket(ctlPath)
      let pid = p.processID()

      let udsPath = testRuntimeDir / "fwd-dead.uds"
      touchDeadSocket(udsPath)
      check socketExists(udsPath)

      let spec = ForwardSpec(kind: fkLocal, bindAddr: defaultBindAddr,
          bindPort: nextPort(), targetHost: "db.internal", targetPort: Port(5432))

      let reg = newRegistry()
      let st = PersistedState(version: 1, savedAt: "", hosts: @[
        PersistedHostSession(host: host, fingerprint: "fp-fwd-dead",
            ctlPath: ctlPath, logPath: logPath, pid: pid,
            argv: @[ctlPath, host], state: hsConnected,
            forwardIds: @["fwd-dead-id"])
      ], forwards: @[
        PersistedForward(id: "fwd-dead-id", tunnelName: "t-dead",
            spec: spec, state: fwActive, udsPath: udsPath)
      ])

      let report = adoptOrphans(reg, st)

      check report.adoptedForwards.len == 0
      check report.reattachForwards == @["fwd-dead-id"]
      check not socketExists(udsPath) ## 残骸が削除されている

      let fws = forwardsOfTunnel(reg, "t-dead")
      check fws.len == 1
      check fws[0].state == fwPending

      forward.teardown(fws[0])
      stopFakeMaster(p, ctlPath))

  test "fkRemote は楽観的に fwPending になる":
    withMode("ok", proc() =
      let host = "adopt-host-fwd-remote"
      let ctlPath = testRuntimeDir / "fwd-remote-host.sock"
      let logPath = testRuntimeDir / "fwd-remote-host.log"
      let p = startFakeMaster(host, ctlPath, logPath)
      check waitForSocket(ctlPath)
      let pid = p.processID()

      let spec = ForwardSpec(kind: fkRemote, bindAddr: defaultBindAddr,
          bindPort: nextPort(), targetHost: "internal.example",
              targetPort: Port(80))

      let reg = newRegistry()
      let st = PersistedState(version: 1, savedAt: "", hosts: @[
        PersistedHostSession(host: host, fingerprint: "fp-fwd-remote",
            ctlPath: ctlPath, logPath: logPath, pid: pid,
            argv: @[ctlPath, host], state: hsConnected,
            forwardIds: @["fwd-remote-id"])
      ], forwards: @[
        PersistedForward(id: "fwd-remote-id", tunnelName: "t-remote",
            spec: spec, state: fwActive, udsPath: "")
      ])

      let report = adoptOrphans(reg, st)

      check report.adoptedForwards.len == 0
      check report.reattachForwards == @["fwd-remote-id"]

      let fws = forwardsOfTunnel(reg, "t-remote")
      check fws.len == 1
      check fws[0].state == fwPending
      check fws[0].proxy.isNone

      forward.teardown(fws[0])
      stopFakeMaster(p, ctlPath))

# ---------------------------------------------------------------------------
# 後片付け
# ---------------------------------------------------------------------------

for p in allMasters:
  try:
    if p.peekExitCode() == -1:
      p.terminate()
    discard p.waitForExit()
    p.close()
  except CatchableError:
    discard

removeDir(testRuntimeDir)
delEnv("POWARDER_FAKE_SSH_MODE")
delEnv("POWARDER_FAKE_SSH_LOG")
delEnv("POWARDER_RUNTIME_DIR")
