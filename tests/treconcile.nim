## `powarder/daemon/registry` と `powarder/daemon/reconcile` のテスト。
##
## 実 SSH サーバなしにテストするため、`tests/fixtures/ssh` という fake ssh を
## `PATH` の先頭に置いて powarder に `ssh` として掴ませる（`thostsession.nim` /
## `tforward.nim` と同じ手法。環境構築はそのまま踏襲する）。
## 実装済みのモードは `ok` / `bind-failed` / `not-forwarded` / `no-master` /
## `auth-failed` / `slow-start`。ここでは主に `ok` モードだけを使う
## （registry/reconcile が見るのはホストやフォワード個々の障害復旧ではなく
## 「望ましい状態」との突き合わせなので、異常系のバリエーションは
## `thostsession.nim` / `tforward.nim` 側で既にカバーされている）。

import std/[unittest, os, posix, tables, monotimes, times, strutils]
import std/nativesockets ## `ForwardSpec` の自動生成 `==` が `Port` の `==` を
                          ## 使うために必要（`reconcile.nim` と同じ理由）。
import std/asyncdispatch

import powarder/core/types
import powarder/core/forwardspec
import powarder/daemon/hostsession
import powarder/daemon/forward
import powarder/daemon/registry
import powarder/daemon/reconcile

const fixturesDir = currentSourcePath().parentDir() / "fixtures"
const testRuntimeDir = "/tmp/pw-rec-rt"
const testStateDir = "/tmp/pw-rec-state"

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
  ## PATH の先頭に fake ssh を置き、ランタイム/状態ディレクトリを隔離する。
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

var allRegistries: seq[Registry]
  ## 後片付け漏れを防ぐため、生成した Registry を全部覚えておいて
  ## ファイルの末尾で teardownAll する（`thostsession.nim` の `allSessions` と
  ## 同じ手法）。

proc track(reg: Registry): Registry =
  allRegistries.add(reg)
  reg

proc processAlive(pid: int): bool =
  ## `platform/procinfo.pidAlive` と同じ判定だが、`platform/` を import
  ## しないという制約（別エージェントの担当領域）を守るため、テスト内で
  ## 最小限だけ複製する（`thostsession.nim` と同じ手法）。
  if kill(Pid(pid), 0.cint) == 0:
    return true
  cint(osLastError()) == EPERM

proc newTunnelConfig(name, host: string; spec: ForwardSpec; autostart = true;
    profile = ""; sshExtraArgs: seq[string] = @[]): TunnelConfig =
  ## テスト用に `TunnelConfig` を組み立てる小さなヘルパー。
  TunnelConfig(name: name, host: host, spec: spec, autostart: autostart,
      profile: profile, sshExtraArgs: sshExtraArgs, retry: initRetryPolicy())

proc waitUntil(reg: Registry; cond: proc(): bool {.closure.};
    timeoutMs = 5000): bool =
  ## 同期的なポーリング。ホストの接続待ちのように async な内部処理を伴わない
  ## 遷移を待つのに使う（`thostsession.waitForState` と同じ手法）。
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while not cond():
    tickAll(reg)
    if cond():
      return true
    if getMonoTime() >= deadline:
      return false
    sleep(20)
  true

proc pollAsync(reg: Registry; cond: proc(): bool {.closure.}; tries = 300;
    delayMs = 20): Future[bool] {.async.} =
  ## detach の副作用確認（`probeUpstream`）は Future で段階的に進むため、
  ## 同期的に `tick` を呼ぶだけでは進まない。`sleepAsync` でイベントループに
  ## 制御を返しながらポーリングする（`tforward.pollForward` と同じ手法）。
  for i in 0 ..< tries:
    tickAll(reg)
    if cond():
      return true
    await sleepAsync(delayMs)
  result = cond()

# ---------------------------------------------------------------------------
# 1. getOrCreateHost: マスター共有の核心
# ---------------------------------------------------------------------------

suite "getOrCreateHost":
  test "同じ host なら同じ HostSession インスタンスを返す":
    withMode("ok", proc() =
      let reg = track(newRegistry())
      let a = getOrCreateHost(reg, "host-getorcreate-a")
      let b = getOrCreateHost(reg, "host-getorcreate-a")
      check a == b ## 参照として同一（HostSession は ref object）
      check reg.hosts.len == 1)

  test "host が違えば違う HostSession になる":
    withMode("ok", proc() =
      let reg = track(newRegistry())
      let a = getOrCreateHost(reg, "host-getorcreate-b1")
      let b = getOrCreateHost(reg, "host-getorcreate-b2")
      check a != b
      check a.key != b.key
      check reg.hosts.len == 2)

# ---------------------------------------------------------------------------
# 2. reconcile: 冪等性
# ---------------------------------------------------------------------------

suite "reconcile: 冪等性":
  test "同じ desired で2回呼んでも2回目の actions は空":
    withMode("ok", proc() =
      let reg = track(newRegistry())
      let spec1 = ForwardSpec(kind: fkLocal, bindAddr: defaultBindAddr,
          bindPort: Port(18200), targetHost: "db1.internal", targetPort: Port(1))
      let spec2 = ForwardSpec(kind: fkLocal, bindAddr: defaultBindAddr,
          bindPort: Port(18201), targetHost: "db2.internal", targetPort: Port(2))
      let tc1 = newTunnelConfig("idem-1", "host-idem-1", spec1)
      let tc2 = newTunnelConfig("idem-2", "host-idem-2", spec2)
      let desired = DesiredState(tunnels: @[tc1, tc2], activeProfiles: @[])

      let report1 = reconcile(desired, reg)
      check report1.actions.len > 0 ## 初回は host/forward の作成が起きる

      let report2 = reconcile(desired, reg)
      check report2.actions.len == 0
      check report2.warnings.len == 0)

# ---------------------------------------------------------------------------
# 3. reconcile: 同じ host を指す複数トンネルがマスターを共有する（M5 完了条件）
# ---------------------------------------------------------------------------

suite "reconcile: マスター共有":
  test "同じ host を指す2つのトンネルが1つのマスターを共有する":
    withMode("ok", proc() =
      let reg = track(newRegistry())
      let spec1 = ForwardSpec(kind: fkLocal, bindAddr: defaultBindAddr,
          bindPort: Port(18202), targetHost: "db1.internal", targetPort: Port(1))
      let spec2 = ForwardSpec(kind: fkLocal, bindAddr: defaultBindAddr,
          bindPort: Port(18203), targetHost: "db2.internal", targetPort: Port(2))
      let tc1 = newTunnelConfig("share-1", "host-shared-master", spec1)
      let tc2 = newTunnelConfig("share-2", "host-shared-master", spec2)
      let desired = DesiredState(tunnels: @[tc1, tc2], activeProfiles: @[])

      discard reconcile(desired, reg)

      check reg.hosts.len == 1
      let host = getOrCreateHost(reg, "host-shared-master")
      check refCount(host) == 2)

# ---------------------------------------------------------------------------
# 4. reconcile: 設定から消えたトンネルの detach
# ---------------------------------------------------------------------------

suite "reconcile: 設定から消えたトンネル":
  test "設定から消えたトンネルの forward が detach される":
    withMode("ok", proc() =
      let reg = track(newRegistry())
      let spec1 = ForwardSpec(kind: fkLocal, bindAddr: defaultBindAddr,
          bindPort: Port(18204), targetHost: "db1.internal", targetPort: Port(1))
      let spec2 = ForwardSpec(kind: fkLocal, bindAddr: defaultBindAddr,
          bindPort: Port(18205), targetHost: "db2.internal", targetPort: Port(2))
      let tc1 = newTunnelConfig("removed-1", "host-removed", spec1)
      let tc2 = newTunnelConfig("removed-2", "host-removed", spec2)
      let desired1 = DesiredState(tunnels: @[tc1, tc2], activeProfiles: @[])
      discard reconcile(desired1, reg)

      let id2 = forwardId(spec2, tc2.host)
      check id2 in reg.forwards

      let desired2 = DesiredState(tunnels: @[tc1], activeProfiles: @[])
      let report2 = reconcile(desired2, reg)

      check (raDetachForward, "removed-2") in report2.actions
      check reg.forwards[id2].state == fwDetaching)

# ---------------------------------------------------------------------------
# 5. reconcile: spec が変わった場合の detach -> 再作成
# ---------------------------------------------------------------------------

suite "reconcile: spec 変更":
  test "同じ id・違う targetPort の場合に detach してから作り直す":
    withMode("ok", proc() =
      let reg = track(newRegistry())
      let spec1 = ForwardSpec(kind: fkLocal, bindAddr: defaultBindAddr,
          bindPort: Port(18206), targetHost: "db1.internal", targetPort: Port(1))
      let spec1b = ForwardSpec(kind: fkLocal, bindAddr: defaultBindAddr,
          bindPort: Port(18206), targetHost: "db1.internal", targetPort: Port(2))
      check spec1 != spec1b ## targetPort だけが違う
      let tc1 = newTunnelConfig("spec-change", "host-spec-change", spec1)
      let id = forwardId(spec1, tc1.host)
      check id == forwardId(spec1b, tc1.host) ## id は bindAddr:bindPort だけで
                                               ## 決まるので変わらない

      let desired1 = DesiredState(tunnels: @[tc1], activeProfiles: @[])
      discard reconcile(desired1, reg)

      let host = getOrCreateHost(reg, tc1.host)
      check waitUntil(reg, proc(): bool = isConnected(host))
      check reg.forwards[id].state == fwActive ## host 接続後 tickAll で attach 済み

      let tc1b = newTunnelConfig("spec-change", "host-spec-change", spec1b)
      let desired2 = DesiredState(tunnels: @[tc1b], activeProfiles: @[])
      let report2 = reconcile(desired2, reg)
      check (raDetachForward, "spec-change") in report2.actions
      check reg.forwards[id].state == fwDetaching

      proc scenario() {.async.} =
        check await pollAsync(reg, proc(): bool = id notin reg.forwards)
      waitFor scenario()

      let report3 = reconcile(desired2, reg)
      check (raCreateForward, "spec-change") in report3.actions
      check id in reg.forwards
      check reg.forwards[id].spec == spec1b)

# ---------------------------------------------------------------------------
# 6. reconcile: enabledOverride が効く（M5 完了条件）
# ---------------------------------------------------------------------------

suite "reconcile: enabledOverride":
  test "setEnabled(false) で detach され、無関係な reload では再開しない":
    withMode("ok", proc() =
      let reg = track(newRegistry())
      let spec1 = ForwardSpec(kind: fkLocal, bindAddr: defaultBindAddr,
          bindPort: Port(18207), targetHost: "db1.internal", targetPort: Port(1))
      let spec2 = ForwardSpec(kind: fkLocal, bindAddr: defaultBindAddr,
          bindPort: Port(18208), targetHost: "db2.internal", targetPort: Port(2))
      let tc1 = newTunnelConfig("stop-me", "host-stop-me", spec1)
      let tc2 = newTunnelConfig("keep-me", "host-keep-me", spec2)
      let desired = DesiredState(tunnels: @[tc1, tc2], activeProfiles: @[])
      discard reconcile(desired, reg)

      let id1 = forwardId(spec1, tc1.host)

      setEnabled(reg, "stop-me", false)
      let report2 = reconcile(desired, reg)
      check report2.actions == @[(raDisableForward, "stop-me")]
      check reg.forwards[id1].state == fwDetaching

      # 無関係な reload: stop-me / keep-me はそのまま、新しいトンネルが増えただけ
      let spec3 = ForwardSpec(kind: fkLocal, bindAddr: defaultBindAddr,
          bindPort: Port(18209), targetHost: "db3.internal", targetPort: Port(3))
      let tc3 = newTunnelConfig("unrelated-new", "host-unrelated", spec3)
      let desired2 = DesiredState(tunnels: @[tc1, tc2, tc3], activeProfiles: @[])
      let report3 = reconcile(desired2, reg)

      check (raCreateForward, "unrelated-new") in report3.actions
      var resumed = false
      for a in report3.actions:
        if a.target == "stop-me":
          resumed = true
      check not resumed ## stop したトンネルが勝手に再開していない
      check reg.forwards[id1].state == fwDetaching
      check isEnabled(reg, "stop-me", tc1.autostart) == false)

# ---------------------------------------------------------------------------
# 7. reconcile: profile フィルタ
# ---------------------------------------------------------------------------

suite "reconcile: profile フィルタ":
  test "activeProfiles が空なら profile 無しのトンネルだけが対象になる":
    withMode("ok", proc() =
      let reg = track(newRegistry())
      let specNo = ForwardSpec(kind: fkLocal, bindAddr: defaultBindAddr,
          bindPort: Port(18210), targetHost: "db1.internal", targetPort: Port(1))
      let specDev = ForwardSpec(kind: fkLocal, bindAddr: defaultBindAddr,
          bindPort: Port(18211), targetHost: "db2.internal", targetPort: Port(2))
      let tcNo = newTunnelConfig("prof-none", "host-prof-none", specNo)
      let tcDev = newTunnelConfig("prof-dev", "host-prof-dev", specDev,
          profile = "dev")

      check isTargeted(tcNo, []) == true
      check isTargeted(tcDev, []) == false
      check isTargeted(tcDev, ["dev"]) == true

      let desiredEmpty = DesiredState(tunnels: @[tcNo, tcDev],
          activeProfiles: @[])
      discard reconcile(desiredEmpty, reg)

      check forwardsOfTunnel(reg, "prof-none").len == 1
      check forwardsOfTunnel(reg, "prof-dev").len == 0

      let desiredDev = DesiredState(tunnels: @[tcNo, tcDev],
          activeProfiles: @["dev"])
      discard reconcile(desiredDev, reg)

      check forwardsOfTunnel(reg, "prof-dev").len == 1)

# ---------------------------------------------------------------------------
# 8. tickAll: 順序とイテレータの安全性
# ---------------------------------------------------------------------------

suite "tickAll":
  test "host -> forward -> 破棄可能な forward の除去、複数同時でも安全":
    withMode("ok", proc() =
      let reg = track(newRegistry())
      let host = getOrCreateHost(reg, "host-tickall")

      var ids: seq[string] = @[]
      for i in 0 ..< 3:
        let spec = ForwardSpec(kind: fkLocal, bindAddr: defaultBindAddr,
            bindPort: Port(18220 + i), targetHost: "db.internal",
            targetPort: Port(1 + i))
        let fw = addForward(reg, "tickall-" & $i, spec, host)
        ids.add(fw.id)

      check waitUntil(reg, proc(): bool = isConnected(host))
      for id in ids:
        check reg.forwards[id].state == fwActive
      check refCount(host) == 3

      for id in ids:
        requestDetach(reg.forwards[id])

      proc scenario() {.async.} =
        check await pollAsync(reg, proc(): bool = reg.forwards.len == 0)
      waitFor scenario()

      check reg.forwards.len == 0
      check reg.hosts.len == 1 ## ホストは reconcile/registry からは能動的に
                                ## 削除しない設計（grace period 経由の自己停止に任せる）
      check refCount(host) == 0)

# ---------------------------------------------------------------------------
# 9. teardownAll: プロセスの残骸が無いこと
# ---------------------------------------------------------------------------

suite "teardownAll":
  test "teardownAll 後に forwards/hosts が空になり、プロセスの残骸が無い":
    withMode("ok", proc() =
      let reg = newRegistry() ## この test 自身で teardown まで確認するので track しない
      let host = getOrCreateHost(reg, "host-teardownall")
      let spec = ForwardSpec(kind: fkLocal, bindAddr: defaultBindAddr,
          bindPort: Port(18230), targetHost: "db.internal", targetPort: Port(1))
      discard addForward(reg, "teardown-fwd", spec, host)

      check waitUntil(reg, proc(): bool = isConnected(host))
      let pid = host.pid
      check pid > 0
      check processAlive(pid)

      teardownAll(reg)

      check reg.forwards.len == 0
      check reg.hosts.len == 0
      check not processAlive(pid))

# ---------------------------------------------------------------------------
# 10. pruneOverrides
# ---------------------------------------------------------------------------

suite "pruneOverrides":
  test "設定から消えたトンネル名の override を消す":
    let reg = newRegistry() ## ssh を一切呼ばないので withMode 不要
    setEnabled(reg, "ghost", false)
    setEnabled(reg, "real", true)

    pruneOverrides(reg, ["real"])

    check "ghost" notin reg.enabledOverride
    check "real" in reg.enabledOverride

# ---------------------------------------------------------------------------
# 後片付け: すべての Registry を teardownAll し、ランタイム/状態ディレクトリを消す
# ---------------------------------------------------------------------------

for reg in allRegistries:
  teardownAll(reg) ## 各テストで既に片付けていれば一瞬で終わる安全網

removeDir(testRuntimeDir)
removeDir(testStateDir)
delEnv("POWARDER_FAKE_SSH_MODE")
delEnv("POWARDER_FAKE_SSH_LOG")
delEnv("POWARDER_RUNTIME_DIR")
delEnv("POWARDER_STATE_DIR")
