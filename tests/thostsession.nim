## `powarder/daemon/hostsession` のテスト。
##
## 実 SSH サーバなしにテストするため、`tests/fixtures/ssh` という fake ssh を
## `PATH` の先頭に置いて powarder に `ssh` として掴ませる。fake ssh の挙動は
## `POWARDER_FAKE_SSH_MODE` で切り替える（詳細は `tests/fixtures/ssh` 参照）。
## 実装済みのモードは `ok` / `bind-failed` / `not-forwarded` / `no-master` /
## `auth-failed` / `slow-start`。

import std/[unittest, os, posix, options, monotimes, times, strutils]

import powarder/core/types
import powarder/core/errorclass
import powarder/daemon/hostsession

const fixturesDir = currentSourcePath().parentDir() / "fixtures"
const testRuntimeDir = "/tmp/pw-hs-rt"
const testStateDir = "/tmp/pw-hs-state"

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

var allSessions: seq[HostSession]
  ## 後片付け漏れを防ぐため、生成した HostSession を全部覚えておいて
  ## ファイルの末尾で teardown する。

proc track(hs: HostSession): HostSession =
  allSessions.add(hs)
  hs

proc processAlive(pid: int): bool =
  ## `platform/procinfo.pidAlive` と同じ判定だが、`platform/` を import
  ## しないという制約（別エージェントの担当領域）を守るため、テスト内で
  ## 最小限だけ複製する。
  if kill(Pid(pid), 0.cint) == 0:
    return true
  cint(osLastError()) == EPERM

proc waitForState(hs: HostSession; target: HostSessionState;
                  timeoutMs = 5000): bool =
  ## `target` に達するまで `tick` を呼び続ける（`readinessPollInterval` 間隔）。
  ## デーモンの本物のループ（500ms 周期）の代わりに、テストではもっと
  ## 細かい間隔でポーリングする。
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while hs.state != target:
    tick(hs)
    if hs.state == target:
      return true
    if getMonoTime() >= deadline:
      return false
    sleep(readinessPollInterval.inMilliseconds.int)
  true

proc stopAndCleanup(hs: HostSession) =
  ## 各テストの後始末用ヘルパー。`teardown` だけに頼ると、`-O exit` が
  ## 空振りするたびに律儀に `teardownGracePeriod`（5秒）を待ってしまい
  ## テストが遅くなるので、まず `requestStop(immediate = true)`
  ## （内部で SIGTERM も送る）で素早く止め、`teardown` は最後の安全網として
  ## 呼ぶ（既に死んでいれば一瞬で終わる）。
  requestStop(hs, immediate = true)
  discard waitForState(hs, hsStopped, timeoutMs = 5000)
  teardown(hs)

# ---------------------------------------------------------------------------
# 1. newHostSession: fingerprint 付き key
# ---------------------------------------------------------------------------

suite "newHostSession: key":
  test "同じ host なら同じ key になる":
    withMode("ok", proc() =
      let a = newHostSession("host-key-a")
      let b = newHostSession("host-key-a")
      check a.key == b.key
      check a.key.fingerprint.len > 0)

  test "host が違えば違う key になる":
    withMode("ok", proc() =
      let a = newHostSession("host-key-a")
      let b = newHostSession("host-key-b")
      check a.key != b.key
      check a.key.fingerprint != b.key.fingerprint)

# ---------------------------------------------------------------------------
# 2. 参照カウント
# ---------------------------------------------------------------------------

suite "参照カウント":
  test "addForwardRef / removeForwardRef で refCount と idleSince が連動する":
    withMode("ok", proc() =
      let hs = newHostSession("host-refcount")
      check refCount(hs) == 0
      check hs.idleSince.isNone

      addForwardRef(hs, "fwd-1")
      check refCount(hs) == 1
      check hs.idleSince.isNone ## 0 から増えたのでクリアされている

      addForwardRef(hs, "fwd-2")
      check refCount(hs) == 2
      addForwardRef(hs, "fwd-2") ## 同じ id の二重追加は冪等
      check refCount(hs) == 2

      removeForwardRef(hs, "fwd-1")
      check refCount(hs) == 1
      check hs.idleSince.isNone ## まだ 0 になっていない

      removeForwardRef(hs, "fwd-2")
      check refCount(hs) == 0
      check hs.idleSince.isSome ## 0 になったのでセットされた

      addForwardRef(hs, "fwd-3")
      check refCount(hs) == 1
      check hs.idleSince.isNone) ## 増えたので再度クリア

# ---------------------------------------------------------------------------
# 3. spawn -> hsConnected
# ---------------------------------------------------------------------------

suite "spawn から hsConnected まで":
  test "ok モードで hsIdle -> hsConnecting -> hsConnected に到達する":
    withMode("ok", proc() =
      let hs = track(newHostSession("host-spawn-ok"))
      check hs.state == hsIdle

      addForwardRef(hs, "fwd")
      check waitForState(hs, hsConnected)
      check hs.pid > 0
      check hs.process.isSome
      check isConnected(hs)

      stopAndCleanup(hs)
      check hs.state == hsStopped)

# ---------------------------------------------------------------------------
# 4. slow-start: readiness ポーリングが待つ
# ---------------------------------------------------------------------------

suite "slow-start":
  test "制御ソケットが3秒後に現れるまで hsConnecting に留まり、その後 hsConnected になる":
    withMode("slow-start", proc() =
      let hs = track(newHostSession("host-slow-start"))
      addForwardRef(hs, "fwd")

      tick(hs) ## hsIdle -> hsConnecting（spawn）
      check hs.state == hsConnecting

      tick(hs) ## まだソケットは無いはず（3秒待つモード）
      check hs.state == hsConnecting

      check waitForState(hs, hsConnected, timeoutMs = 8000)

      stopAndCleanup(hs)
      check hs.state == hsStopped)

# ---------------------------------------------------------------------------
# 5. auth-failed: 即死 -> hsReconnecting、バックオフの伸長
# ---------------------------------------------------------------------------

suite "auth-failed":
  test "即死を検知して hsReconnecting に落ち、consecutiveFailures とバックオフが伸びる":
    withMode("auth-failed", proc() =
      let hs = track(newHostSession("host-auth-failed"))
      addForwardRef(hs, "fwd")

      check waitForState(hs, hsReconnecting)
      check hs.consecutiveFailures == 1
      check hs.backoffSeconds == 1.0
      check hs.nextRetryAt.isSome
      check hs.nextRetryAt.get() > getMonoTime()
      check hs.process.isNone ## 死亡検知時に刈り取り済み

      # nextRetryAt が来るまでは何度 tick しても再 spawn されない
      for i in 0 ..< 5:
        tick(hs)
        check hs.state == hsReconnecting

      # バックオフを待たず明けさせて2回目の失敗を発生させ、倍々に伸びることを確認する
      hs.nextRetryAt = some(getMonoTime() - initDuration(milliseconds = 10))
      tick(hs) ## hsReconnecting -> hsConnecting（再 spawn）
      check hs.state == hsConnecting

      check waitForState(hs, hsReconnecting)
      check hs.consecutiveFailures == 2
      check hs.backoffSeconds == 2.0

      stopAndCleanup(hs))

# ---------------------------------------------------------------------------
# 6. エラー分類
# ---------------------------------------------------------------------------

suite "エラー分類":
  test "auth-failed のログから ekAuthFailed が分類され lastErrorKind に入る":
    withMode("auth-failed", proc() =
      let hs = track(newHostSession("host-error-classify"))
      addForwardRef(hs, "fwd")

      check waitForState(hs, hsReconnecting)
      check hs.lastErrorKind == ekAuthFailed
      check hs.lastError.len > 0

      stopAndCleanup(hs))

# ---------------------------------------------------------------------------
# 7. requestStop -> hsStopping -> hsStopped、teardown 後に子プロセスが残らない
# ---------------------------------------------------------------------------

suite "requestStop と teardown":
  test "requestStop(immediate=true) で hsStopping に入り、hsStopped まで進む。teardown 後にプロセスは残らない":
    withMode("ok", proc() =
      let hs = track(newHostSession("host-requeststop"))
      addForwardRef(hs, "fwd")
      check waitForState(hs, hsConnected)
      let pid = hs.pid
      check pid > 0
      check processAlive(pid)

      requestStop(hs, immediate = true)
      check hs.state == hsStopping ## 同期的に即座に遷移している

      check waitForState(hs, hsStopped)
      check hs.process.isNone

      teardown(hs) ## 既に停止済みでも安全に呼べる（no-op に近い）
      check hs.state == hsStopped
      check not processAlive(pid)) ## OS レベルでも本当に残っていない

# ---------------------------------------------------------------------------
# 8. grace period
# ---------------------------------------------------------------------------

suite "grace period":
  test "refCount が 0 でも idleGracePeriod 未満なら hsConnected を維持する":
    withMode("ok", proc() =
      let hs = track(newHostSession("host-grace"))
      addForwardRef(hs, "fwd")
      check waitForState(hs, hsConnected)

      removeForwardRef(hs, "fwd")
      check refCount(hs) == 0
      check hs.idleSince.isSome

      tick(hs)
      check hs.state == hsConnected ## まだ猶予期間内

      # 25 秒待つのはテストとして長すぎるので idleSince を過去に書き換える
      hs.idleSince = some(getMonoTime() - idleGracePeriod - initDuration(seconds = 1))
      tick(hs)
      check hs.state == hsStopping

      stopAndCleanup(hs)
      check hs.state == hsStopped)

  test "requestStop(immediate=true) は grace を待たず即座に停止処理へ入る":
    withMode("ok", proc() =
      let hs = track(newHostSession("host-grace-immediate"))
      addForwardRef(hs, "fwd")
      check waitForState(hs, hsConnected)

      requestStop(hs, immediate = true)
      check hs.state == hsStopping ## grace を待たず即座に遷移している

      check waitForState(hs, hsStopped)
      teardown(hs))

# ---------------------------------------------------------------------------
# 9. バックオフのリセット
# ---------------------------------------------------------------------------

suite "バックオフのリセット":
  test "lastConnectedAt を過去に書き換えて tick すると consecutiveFailures が 0 に戻る":
    withMode("ok", proc() =
      let hs = track(newHostSession("host-backoff-reset"))
      # 過去に失敗が続いていた状態を模擬する
      hs.consecutiveFailures = 3
      hs.backoffSeconds = 8.0

      addForwardRef(hs, "fwd")
      check waitForState(hs, hsConnected)
      check hs.consecutiveFailures == 3 ## まだ 60 秒経っていないのでリセットされない

      hs.lastConnectedAt = some(getMonoTime() - connectedStableFor -
          initDuration(seconds = 1))
      tick(hs)
      check hs.consecutiveFailures == 0
      check hs.backoffSeconds == 0.0

      stopAndCleanup(hs))

# ---------------------------------------------------------------------------
# 後片付け: すべてのマスターを teardown し、ランタイム/状態ディレクトリを消す
# ---------------------------------------------------------------------------

for hs in allSessions:
  teardown(hs) ## 各テストで既に止めていれば一瞬で終わる安全網

removeDir(testRuntimeDir)
removeDir(testStateDir)
delEnv("POWARDER_FAKE_SSH_MODE")
delEnv("POWARDER_FAKE_SSH_LOG")
delEnv("POWARDER_RUNTIME_DIR")
delEnv("POWARDER_STATE_DIR")
