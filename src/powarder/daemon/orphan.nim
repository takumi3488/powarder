## デーモン起動時の孤児マスター adopt（M6）。
##
## デーモンが `kill -9` やクラッシュで死んでも、子の `ssh -M ... -N` マスター
## プロセスは init/launchd に引き取られて**生き残る**（トンネル自体は維持
## されるので、これ自体は望ましい挙動）。デーモンを再起動したときにこれを
## 「知らないプロセス」として放置すると、ポートが二重に使われたり残骸が
## 溜まったりする。**引き継げるなら引き継ぐ**のがこのモジュールの役割。
##
## ## 生死判定の設計（実測で確定済み。変更しないこと）
##
## 1. **「同じ forward を `-O forward` で再送して `bind: Address already in
##    use` が返れば生きている証拠」という判定は成立しない。** 既存の同一
##    forward への再送は exit 0 / stderr 空で冪等成功する（実機検証済み）。
##    だから生死判定には使えない。
## 2. **代わりに UDS へ直接 connect して判定する**
##    （`proxy/upstream.probeUpstream`）。実測で確定した挙動:
##    - forward が生きている: 接続成功 + SSH バナーが返る
##    - cancel 済み / マスター死亡（ソケットファイルは残っている）:
##      `ECONNREFUSED`
##    - ソケットファイルも無い: `ENOENT`
##    このプローブは宛先に実接続を発生させる（OpenSSH の
##    `channel_post_port_listener` が accept 直後に `direct-tcpip` を開くため
##    回避不可能）が、adopt は起動時に1回だけなので許容する。
## 3. **adopt したマスターは自分の子プロセスではないので `peekExitCode` /
##    `waitForExit` が原理的に使えない**（`waitpid` は自分の子しか回収
##    できない）。`daemon/hostsession.adoptHostSession` が `adopted = true`
##    にし、死活監視を `-O check` のみに依存させる（`hostsession.nim` を
##    参照）。
## 4. **`ps` は `-ww` が必須。** `platform/procinfo.processCmdline` が既に
##    対応済み。
##
## ## host と forward の対応付け
##
## `PersistedForward` 自体は所属ホストを持たない（`fkLocal` はローカル
## ポートがマシン全体で一意という設計上、`forwardId` に host を含めない。
## `core/forwardspec.forwardId` の doc comment を参照）。そのため、
## 各 `PersistedHostSession.forwardIds`（ホスト側が持つ「自分に属する
## forward id 一覧」）を辿ることで対応付ける。ホストが adopt できなかった
## （`aoNoSocket` / `aoDeadReclaimed` / `aoMismatch`）場合、そのホストに
## 属していた forward は一切処理しない（persisted な記録を静かに捨てる）。
## 設定にまだ存在するトンネルであれば、後続の通常の `reconcile` が新しい
## ホスト・新しい forward を普通に作り直す。

import std/[os, tables, asyncdispatch]

import powarder/core/types
import powarder/core/paths
import powarder/config/statefile
import powarder/daemon/muxclient
import powarder/daemon/hostsession
import powarder/daemon/forward
import powarder/daemon/registry
import powarder/proxy/upstream
import powarder/platform/procinfo

type
  AdoptOutcome* = enum
    aoAdopted  ## 生きていたので引き継いだ
    aoDeadReclaimed ## 死んでいたので記録を破棄し、残骸を掃除した
    aoMismatch ## PID は生きているが cmdline が一致しない（別プロセスの PID 再利用）
    aoNoSocket ## 制御ソケットが無い

  AdoptReport* = object
    hosts*: seq[tuple[host: string, outcome: AdoptOutcome]]
    adoptedForwards*: seq[string] ## 引き継げた Forward の id
    reattachForwards*: seq[string] ## 死んでいた/楽観的に再 attach へ回した id
    staleSocketsRemoved*: int
    notes*: seq[string]

# ---------------------------------------------------------------------------
# 内部ヘルパー
# ---------------------------------------------------------------------------

proc probeAlive(target: UpstreamTarget): bool =
  ## `probeUpstream` を同期的に橋渡しする。`adoptOrphans` はデーモン起動時に
  ## 1回だけ呼ばれる同期関数（`newDaemon` の中。`mainLoop`/`serve` が
  ## 始まる前）であり、ここが唯一の `waitFor` なのでネストの心配は無い
  ## （`daemon/run.handleTunnelCheck` の単発 `waitFor` と同じ考え方）。
  ## 万一応答が返らない場合に備えて `withTimeout` で上限を設ける。
  let fut = probeUpstream(target)
  let completed =
    try: waitFor(withTimeout(fut, 3000))
    except CatchableError: false
  completed and (try: fut.read() except CatchableError: false)

# ---------------------------------------------------------------------------
# 公開 API
# ---------------------------------------------------------------------------

proc adoptOrphans*(reg: Registry; st: PersistedState): AdoptReport =
  ## デーモン起動シーケンスから1回だけ呼ぶ。`st`（前回保存された
  ## `PersistedState`）を元に、生きている孤児マスター/forward を `reg` へ
  ## 引き継ぐ。手順はモジュール doc comment を参照。
  result = AdoptReport(hosts: @[], adoptedForwards: @[],
      reattachForwards: @[], staleSocketsRemoved: 0, notes: @[])

  # --- 手順1: ホストの adopt -------------------------------------------------
  # adopt できたホストだけを (persisted 記録, 作った HostSession) の組で
  # 憶えておく。forward 側の処理（手順2）はこの組だけを辿る。
  var adopted: seq[tuple[phs: PersistedHostSession, hs: HostSession]] = @[]

  for phs in st.hosts:
    if not socketExists(phs.ctlPath):
      result.hosts.add (host: phs.host, outcome: aoNoSocket)
      continue

    let (alive, _) = checkMaster(phs.ctlPath, phs.host)
    if not alive:
      # ソケットファイルは残っている（`ECONNREFUSED` の場合。存在は既に
      # 上で確認済み）ので消す。マスター死亡 + 残骸掃除。
      removeFile(phs.ctlPath)
      inc result.staleSocketsRemoved
      result.hosts.add (host: phs.host, outcome: aoDeadReclaimed)
      continue

    if not (pidAlive(phs.pid) and cmdlineMatches(phs.pid, phs.argv)):
      # 生きてはいるが記録済みの argv と一致しない
      # （＝別プロセスへの PID 再利用の疑い）。偽陽性を避けるため何もしない。
      result.hosts.add (host: phs.host, outcome: aoMismatch)
      continue

    let hs = adoptHostSession(phs.host, phs.fingerprint, phs.ctlPath,
        phs.logPath, phs.pid, phs.argv, phs.forwardIds)
    adoptHost(reg, hs)
    result.hosts.add (host: phs.host, outcome: aoAdopted)
    adopted.add (phs: phs, hs: hs)

  # --- 手順2: forward の adopt / 再 attach ------------------------------------
  var forwardById = initTable[string, PersistedForward]()
  for pfw in st.forwards:
    forwardById[pfw.id] = pfw

  for pair in adopted:
    for fid in pair.phs.forwardIds:
      if fid notin forwardById:
        var note = "adopt: ホスト " & pair.phs.host
        note.add " の forward 記録が見つかりません (id=" & fid & ")"
        result.notes.add note
        continue
      let pfw = forwardById[fid]

      case pfw.spec.kind
      of fkLocal:
        let alive = probeAlive(UpstreamTarget(kind: ukUnix, path: pfw.udsPath))
        if alive:
          let fw = forward.adoptForward(pfw.tunnelName, pfw.spec, pair.hs)
          registry.adoptForward(reg, fw)
          result.adoptedForwards.add fw.id
        else:
          if socketExists(pfw.udsPath):
            removeFile(pfw.udsPath)
          discard registry.addForward(reg, pfw.tunnelName, pfw.spec, pair.hs)
          result.reattachForwards.add pfw.id
      of fkRemote:
        # `fkRemote` はプローブする手段が無い（powarder がデータパスに
        # 介在しないため）。楽観的に `fwPending` にして再 attach させる。
        # `-O forward -R` は冪等成功するので、二重に張られる心配は無い。
        discard registry.addForward(reg, pfw.tunnelName, pfw.spec, pair.hs)
        result.reattachForwards.add pfw.id
