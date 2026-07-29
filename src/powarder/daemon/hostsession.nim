## SSH ControlMaster プロセス（1ホストにつき1つの長命 `ssh -M -N` マスター）の
## ライフサイクル管理。
##
## 個々のポートフォワードは `addForwardRef` / `removeForwardRef` を通じて
## マスターへの参照カウントを持つだけで、実際のマスターの spawn / 監視 /
## 再接続 / 停止はすべてこのモジュールが `core/statemachine.nextHostState()`
## の判定に従って進める。**状態遷移の可否判定はすべて `statemachine` に
## 委譲し、ここで if 文により状態遷移を書き直すことはしない。**
##
## マスターの起動コマンドラインは `daemon/muxclient.masterCommandLine()` が
## 組む（ここでは組み直さない）。`-O check` / `-O exit` / `ssh -G` の実行も
## 同モジュールの `checkMaster` / `exitMaster` / `resolveSshConfig` に委譲する。
##
## ## 孤児プロセスの adopt（M6）
##
## 実際の adopt 判定（生死確認・`platform/procinfo` を使った cmdline 照合）は
## `daemon/orphan.nim` の責務。このモジュールが持つのは、その判定結果を受けて
## `hsConnected` の `HostSession` を直接組み立てる `adoptHostSession()` と、
## `process = none(Process)`（自分の子プロセスではない）な `HostSession` を
## 正しく監視・停止するための `tick()` / `teardown()` の対応部分だけ。
##
## adopt したセッションは `adopted = true` を立てる。**`peekExitCode` /
## `waitForExit` は自分の子プロセスにしか使えない**（`waitpid` の制約）ため、
## `adopted` な間は死活監視を `-O check`（`checkIntervalAdopted`。通常より
## 短い間隔）だけに頼り、終了させる必要が生じたら親子関係を要求しない
## `posix.kill(pid, SIGTERM)` を使う。ゾンビ化の心配は無い（自分の子ではない
## ので init/launchd が回収する）。

import std/[os, osproc, posix, options, monotimes, times, strutils]

import powarder/core/types
import powarder/core/statemachine
import powarder/core/paths
import powarder/core/sshgparse
import powarder/core/errorclass
import powarder/core/fmt
import powarder/daemon/muxclient

type
  HostSession* = ref object
    key*: HostSessionKey
    host*: string ## ssh に渡すホスト（~/.ssh/config の Host エイリアス）
    extraArgs*: seq[string]
    ctlPath*: string
    logPath*: string
    process*: Option[Process] ## 自分が spawn した場合のみ Some。adopt では常に none
    pid*: int
    argv*: seq[string]
      ## adopt 時の `cmdlineMatches` 照合用に保持する部分文字列集合。
      ## `/bin/sh -c 'exec ssh ...'` は `exec` により実プロセスの argv が
      ## sh のものから ssh 本体のものに置き換わる（`platform/procinfo` の
      ## doc comment を参照）ため、sh -c ラッパー全体ではなく実際に `ps` に
      ## 現れるはずの断片（`ctlPath` と `host`）だけを持つ（`spawnMaster`
      ## を参照）。
    state*: HostSessionState
    forwardIds*: seq[string] ## ★参照カウントの実体。独立フィールドにしない
    consecutiveFailures*: int
    backoffSeconds*: float
    lastConnectedAt*: Option[MonoTime]
    connectingSince*: Option[MonoTime] ## readiness タイムアウト判定用
    nextRetryAt*: Option[MonoTime]
    idleSince*: Option[MonoTime] ## forwardIds が空になった時刻（grace 判定）
    retry*: RetryPolicy
    lastError*: string ## ログ末尾から errorclass で分類した結果
    lastErrorKind*: ErrorKind
    adopted*: bool
      ## M6: 孤児マスターを adopt して作られたセッションか。`true` の間は
      ## `process` が常に `none` で、死活監視は `-O check` のみに依存する
      ## （モジュール doc comment を参照）。自分で再 spawn したプロセスに
      ## 置き換わった時点（`spawnMaster`）で `false` に戻る。
    lastPeriodicCheckAt: Option[MonoTime]
      ## `hsConnected` 中の低頻度 `checkMaster` 保険チェックの間引き用。
      ## 公開型定義には無い内部専用フィールド（テストからは触らない）。

const
  readinessTimeout* = initDuration(seconds = 15)
    ## ConnectTimeout=10 + マージン。実測では制御ソケットは 273ms で出現する
  readinessPollInterval* = initDuration(milliseconds = 150)
  idleGracePeriod* = initDuration(seconds = 25)
    ## 参照カウントが 0 になってもすぐ -O exit せず維持する猶予。
    ## reload の差分適用で一瞬 0 になるケースを無停止で吸収するため（ControlPersist の powarder 版）
  connectedStableFor* = initDuration(seconds = 60)
    ## これだけ hsConnected を維持できたら backoff をリセットする
  checkIntervalSelfSpawned* = initDuration(seconds = 15)
    ## peekExitCode が主なので -O check は保険。低頻度でよい
  checkIntervalAdopted* = initDuration(seconds = 5)
    ## adopt したホストは `peekExitCode` が使えず `-O check` だけが死活監視の
    ## 手段なので、`checkIntervalSelfSpawned` より短い間隔にする（M6）。
  teardownGracePeriod* = initDuration(seconds = 5)
    ## -O exit / SIGTERM の後 SIGKILL するまでの猶予

# ---------------------------------------------------------------------------
# 小さなヘルパー
# ---------------------------------------------------------------------------

proc sanitizeForFilename(s: string): string =
  ## ログファイル名にホスト名を含めるための下処理。パス区切りになりうる
  ## 文字だけ潰す（それ以外はデバッグのためできるだけ元の見た目を保つ）。
  s.replace('/', '_')

proc readLogTail(path: string; maxLines = 50; maxBytes = 8192): string =
  ## ログファイルの末尾だけを読む。エラー分類（`errorclass.classify`）の
  ## 材料にするだけなので、ログ全体を読み込む必要は無い。ファイル末尾から
  ## `maxBytes` だけシークして読むことで、ローテーション前の巨大なログでも
  ## 全体を読み込まずに済む。ファイルが無い/開けない場合も落ちずに空文字列
  ## を返す。
  if not fileExists(path):
    return ""
  try:
    var f: File
    if not open(f, path, fmRead):
      return ""
    defer: f.close()
    let size = f.getFileSize()
    let start = max(0'i64, size - maxBytes.int64)
    f.setFilePos(start)
    let toRead = int(size - start)
    if toRead <= 0:
      return ""
    var buf = newString(toRead)
    let n = f.readBuffer(addr buf[0], toRead)
    buf.setLen(n)
    var lines = buf.splitLines()
    if lines.len > maxLines:
      lines = lines[^maxLines .. ^1]
    lines.join("\n")
  except CatchableError:
    ""

# ---------------------------------------------------------------------------
# 参照カウント
# ---------------------------------------------------------------------------

proc refCount*(hs: HostSession): int {.inline.} =
  ## `hs.forwardIds.len` を返すだけ（派生値。独立したカウンタを持たない）
  hs.forwardIds.len

proc addForwardRef*(hs: HostSession; forwardId: string) =
  ## 参照カウントの増加。`forwardIds` を直接操作する。同じ id を二重に
  ## 追加しても冪等（無視する）。0 から増えたら `idleSince` をクリアする。
  if forwardId in hs.forwardIds:
    return
  let wasIdle = hs.forwardIds.len == 0
  hs.forwardIds.add(forwardId)
  if wasIdle:
    hs.idleSince = none(MonoTime)

proc removeForwardRef*(hs: HostSession; forwardId: string) =
  ## 参照カウントの減少。`forwardIds` を直接操作する。0 になったら
  ## `idleSince` をセットする。
  var idx = -1
  for i, id in hs.forwardIds:
    if id == forwardId:
      idx = i
      break
  if idx < 0:
    return
  hs.forwardIds.delete(idx)
  if hs.forwardIds.len == 0:
    hs.idleSince = some(getMonoTime())

# ---------------------------------------------------------------------------
# 生成
# ---------------------------------------------------------------------------

proc newHostSession*(host: string; extraArgs: seq[string] = @[];
                     retry = initRetryPolicy()): HostSession =
  ## `muxclient.resolveSshConfig()` で ssh -G を解決し、`sshgparse.fingerprint()`
  ## から `HostSessionKey` を作る。ctlPath / logPath も paths から導出する。
  ## **プロセスはまだ起動しない**（状態は hsIdle）。
  let cfg = resolveSshConfig(host, extraArgs)
  let fp = fingerprint(cfg)
  let key = HostSessionKey(host: host, fingerprint: fp)
  let ctl = controlPath(fp)
  let fpPrefix = fp[0 ..< min(8, fp.len)]
  let log = tunnelLogPath(sanitizeForFilename(host) & "-" & fpPrefix)
  HostSession(
    key: key,
    host: host,
    extraArgs: extraArgs,
    ctlPath: ctl,
    logPath: log,
    process: none(Process),
    pid: 0,
    argv: @[],
    state: hsIdle,
    forwardIds: @[],
    consecutiveFailures: 0,
    backoffSeconds: 0.0,
    lastConnectedAt: none(MonoTime),
    connectingSince: none(MonoTime),
    nextRetryAt: none(MonoTime),
    idleSince: none(MonoTime),
    retry: retry,
    lastError: "",
    lastErrorKind: ekUnknown,
    adopted: false,
    lastPeriodicCheckAt: none(MonoTime),
  )

proc adoptHostSession*(host, fingerprint, ctlPath, logPath: string; pid: int;
    argv: seq[string]; forwardIds: seq[string] = @[];
    retry = initRetryPolicy()): HostSession =
  ## 孤児マスターの adopt（M6）用コンストラクタ。`daemon/orphan.adoptOrphans`
  ## から呼ばれる想定。`ssh -G` は実行せず、記録済みの `fingerprint` を
  ## そのまま使う。呼び出し側が既に `muxclient.checkMaster` で生存を、
  ## `platform/procinfo` で pid の生存と cmdline 一致を確認済みという前提で、
  ## 検証は一切行わない。
  ##
  ## `process = none(Process)`（自分の子プロセスではないので `peekExitCode` /
  ## `waitForExit` は原理的に使えない）。`adopted = true` にすることで
  ## `tick()` は死活監視を `-O check` のみに依存させ、間隔も
  ## `checkIntervalAdopted`（5秒）に短縮する。状態は最初から `hsConnected`
  ## （生きていることを確認済みのマスターを引き継ぐため、`hsConnecting` の
  ## readiness 待ちは不要）。
  let key = HostSessionKey(host: host, fingerprint: fingerprint)
  let now = getMonoTime()
  HostSession(
    key: key,
    host: host,
    extraArgs: @[],
    ctlPath: ctlPath,
    logPath: logPath,
    process: none(Process),
    pid: pid,
    argv: argv,
    state: hsConnected,
    forwardIds: forwardIds,
    consecutiveFailures: 0,
    backoffSeconds: 0.0,
    lastConnectedAt: some(now),
    connectingSince: none(MonoTime),
    nextRetryAt: none(MonoTime),
    idleSince: (if forwardIds.len == 0: some(now) else: none(MonoTime)),
    retry: retry,
    lastError: "",
    lastErrorKind: ekUnknown,
    adopted: true,
    lastPeriodicCheckAt: some(now),
  )

# ---------------------------------------------------------------------------
# 状態遷移の内部ヘルパー
# ---------------------------------------------------------------------------

proc transition(hs: HostSession; event: HostEvent) =
  ## `statemachine.nextHostState` の結果をそのまま適用する内部ヘルパー。
  ## `tick` の各分岐は「その状態で意味のあるイベント」だけを渡す設計に
  ## しているので、`none` が返るのは本来ここに来ないはずの実装バグを
  ## 意味する。それでもデーモン全体を巻き込んで落ちることは避けたいので、
  ## `none` のときは状態を変えずに黙って無視する（防御的プログラミング。
  ## ロガー層がまだ無いのでログには出さない）。
  let next = nextHostState(hs.state, event)
  if next.isSome:
    hs.state = next.get()

proc reapOwnProcess(hs: HostSession; forceKill = false) =
  ## 自分が spawn したプロセスを刈り取る。`forceKill=true` はまだ生きて
  ## いれば SIGKILL してから刈る（readiness タイムアウトなど、行儀よく
  ## 待つ理由が無い場合用。SIGKILL は即座に効くので、続く `waitForExit` の
  ## ブロックはごく短時間で済む）。既に終了していれば `waitForExit` は
  ## `peekExitCode` がキャッシュした終了コードを返すだけで追加の syscall は
  ## 起きない（`std/osproc` の実装を確認済み）。
  if hs.process.isSome:
    let p = hs.process.get()
    if forceKill and p.peekExitCode() == -1:
      try:
        p.kill()
      except OSError:
        discard
    discard p.waitForExit()
    try:
      p.close()
    except CatchableError:
      discard
  hs.process = none(Process)
  hs.pid = 0

proc ownProcessExited(hs: HostSession): bool =
  ## 自分が spawn したプロセスが終了しているかを非ブロッキングで確認する。
  ## `process` が None（M6: adopt したホスト）のときは自分の子プロセスでは
  ## ないので `peekExitCode` が原理的に使えず「分かる方法が無い」。ここで
  ## 安易に「死んでいる」扱いにすると adopt 直後に即座に死亡判定してしまう
  ## ため、false（＝生きている前提で、判定は呼び出し側の `-O check` に委ねる）
  ## を返す。
  if hs.process.isNone:
    return false
  hs.process.get().peekExitCode() != -1

proc recordFailureAndTransition(hs: HostSession; event: HostEvent) =
  ## マスター死亡 / readiness タイムアウトの共通後処理。
  ## ログ末尾からエラーを分類し、失敗カウンタとバックオフを進めてから
  ## `event`（heMasterDied / heReadinessTimeout）で hsReconnecting へ遷移
  ## する。リトライ上限に達していれば続けて `heRetryLimitReached` を適用し
  ## hsFailed まで進める（既定の `RetryPolicy` では上限が無いので、通常は
  ## ここまで進まない）。
  let tail = readLogTail(hs.logPath)
  let kind = classify(tail)
  hs.lastErrorKind = kind
  hs.lastError = explain(kind, langEn,
      initErrorContext(host = hs.host, rawStderr = tail)).summary

  inc hs.consecutiveFailures
  hs.backoffSeconds = nextBackoff(hs.backoffSeconds, hs.retry.backoffMaxSeconds)
  hs.nextRetryAt = some(getMonoTime() +
      initDuration(milliseconds = (hs.backoffSeconds * 1000.0).int64))
  hs.connectingSince = none(MonoTime)
  hs.lastConnectedAt = none(MonoTime)
  hs.lastPeriodicCheckAt = none(MonoTime)

  transition(hs, event)
  if shouldGiveUp(hs.consecutiveFailures, hs.retry):
    transition(hs, heRetryLimitReached)

proc handleMasterDeath(hs: HostSession) =
  ## `hsConnecting` / `hsConnected` で自スポーンのマスターの死亡を検知した
  ## ときの処理。
  reapOwnProcess(hs)
  recordFailureAndTransition(hs, heMasterDied)

proc handleReadinessTimeout(hs: HostSession) =
  ## `hsConnecting` で制御ソケットが `readinessTimeout` 以内に出現しなかった
  ## ときの処理。ここまで待って繋がらないプロセスに行儀よく退場を待つ理由が
  ## 無いので即座に SIGKILL する。
  reapOwnProcess(hs, forceKill = true)
  recordFailureAndTransition(hs, heReadinessTimeout)

proc spawnMaster(hs: HostSession) =
  ## マスターを実際に起動する。ctlPath / logPath の親ディレクトリはここで
  ## 初めて用意する（一度も接続したことが無いホストでも安全なように）。
  ## `/bin/sh -c 'exec ssh ...'` 形式（`masterCommandLine` が組む）で
  ## 起動する。`exec` があるので `sh` の PID = ssh の PID になり、
  ## `peekExitCode` で ssh 本体を追跡できる（実測確認済み。
  ## `masterCommandLine` の doc comment を参照）。
  ##
  ## `options = {}` は pipe を作らせないため……と言いたいところだが、
  ## `std/osproc` の実装を確認したところ `poParentStreams notin options`
  ## である限り実際には stdin/stdout/stderr 用の pipe が作られる。
  ## ただしマスターは shell リダイレクトで自分の stdout/stderr を
  ## `logPath` に付け替えるため、その pipe には誰も書き込まず、
  ## パイプが埋まって親がブロックするという事態はそもそも起こらない
  ## （`daemon/muxclient.runSsh` と全く同じ理由・同じイディオムなので
  ## そちらの doc comment も参照）。
  ensureRuntimeDir()
  ensureStateDirs()

  # **既存の ControlPath ソケットを必ず片付けてから起動する。**
  #
  # デーモンが `kill -9` された直後などに、前回のマスターが孤児として
  # （PPID=1 で）まだ生きていることがある。通常はそれを `daemon/orphan.nim` が
  # adopt するが、`state.json` への保存は数秒間隔なので**記録が残る前に
  # クラッシュすると adopt する手がかりが無い**。そのまま同じ ControlPath で
  # `ssh -M -S <同じパス>` を起動すると、**同一 ControlPath を持つマスターが
  # 2つ並立する**という壊れた状態になり、`-O check` / `-O forward` が
  # どちらに届くか不定になって詰まる（実測で踏んだ）。
  #
  # そこで起動前に「生きているなら `-O exit` で明示的に終わらせ、
  # 残骸ソケットなら unlink する」を必ず通す。捨てるのは前世代の接続だけなので
  # 副作用は「再認証が1回走る」だけであり、並立の危険と引き換えなら安い。
  #
  # `paths.socketExists` を使うこと（`os.fileExists` は `S_ISREG` しか見ないので
  # ソケットには常に false を返す）。
  if socketExists(hs.ctlPath):
    let (aliveBefore, oldPid) = checkMaster(hs.ctlPath, hs.host)
    if aliveBefore:
      discard exitMaster(hs.ctlPath, hs.host)
      # `-O exit` は「終了要求を送った」ことしか意味しない（実測）。
      # ソケットが消えるまで短く待ち、消えなければ SIGTERM で押す。
      var waited = 0
      while socketExists(hs.ctlPath) and waited < 2000:
        sleep(50)
        waited += 50
      if socketExists(hs.ctlPath) and oldPid > 0:
        discard posix.kill(Pid(oldPid), SIGTERM)
        sleep(200)
    removeFile(hs.ctlPath) ## 残骸（あるいは exit しきらなかった分）を消す

  let cmd = masterCommandLine(hs.ctlPath, hs.logPath, hs.host, hs.extraArgs)
  # `hs.argv` には `cmd`（`/bin/sh -c 'exec ssh ...'`）そのものではなく、
  # `ctlPath` と `host` だけを持たせる。`exec` により実プロセスの argv は
  # sh ではなく ssh 本体のものに置き換わる（型定義側の doc comment を参照）
  # ため、`platform/procinfo.cmdlineMatches` が実際に `ps` へ現れる断片と
  # 突き合わせられるのはこの2つ。
  hs.argv = @[hs.ctlPath, hs.host]
  let process = startProcess(cmd[0], args = cmd[1 .. ^1], options = {})
  hs.process = some(process)
  hs.pid = process.processID()
  hs.connectingSince = some(getMonoTime())
  hs.adopted = false ## 自分で spawn した以上、もう adopt 由来ではない

proc nudgeStop(hs: HostSession) =
  ## `hsStopping` 中、プロセスがまだ生きていれば停止を促す。
  ##
  ## `-O exit` の成功報告は過信しない: fake ssh フィクスチャの `-O exit` は
  ## 実際のマスタープロセスの生死と結び付いていない単純なスタブなので、
  ## 成功と報告されても実プロセスが生きていることがある（実 ssh でも
  ## タイミング次第であり得る）。そのため `exitMaster` の戻り値では
  ## 分岐せず、行儀よい `-O exit` を試したうえで、いずれにせよ SIGTERM を
  ## 重ねて送る。既に死んでいるプロセスに SIGTERM を送ってもエラーは
  ## 無視するだけで副作用は無く、`kill(2)` 自体は非ブロッキングなので
  ## tick を長時間止めない。実際の終了確認は次回以降の tick の
  ## `ownProcessExited`（自スポーン）/ `-O check`（adopt）に委ねる。
  discard exitMaster(hs.ctlPath, hs.host)
  if hs.process.isSome:
    try:
      hs.process.get().terminate()
    except OSError:
      discard
  elif hs.pid > 0:
    # adopt したマスター: `Process` を持たないので `terminate` は使えない。
    # 親子関係を要求しない `posix.kill` で SIGTERM を送る（M6）。
    discard posix.kill(Pid(hs.pid), SIGTERM)

proc maybeStartConnecting(hs: HostSession) =
  ## refCount > 0 なら hePreparedToConnect を適用してマスターを spawn する。
  ## `hsIdle` / `hsStopped` のどちらも `nextHostState` 上
  ## `hePreparedToConnect -> hsConnecting` が有効なので、この共通ロジックを
  ## 両方の分岐で使い回せる（`hsStopped` から再度参照が増えたときに新しい
  ## `HostSession` を作り直さなくても再利用できる）。
  if refCount(hs) > 0:
    transition(hs, hePreparedToConnect)
    if hs.state == hsConnecting:
      spawnMaster(hs)

# ---------------------------------------------------------------------------
# tick
# ---------------------------------------------------------------------------

proc tick*(hs: HostSession) =
  ## デーモンの 500ms ループから毎回呼ばれる。現在の状態に応じて必要な処理を
  ## 1回だけ進める（同じ呼び出し内で状態が変わっても、次の状態向けの処理
  ## までは行わない。次に進むのは次回の `tick` 呼び出し）。
  ##
  ## **同期関数にしている理由**: `checkMaster` / `exitMaster` は短命な ssh
  ## サブプロセスを起動して `waitForExit` するため数十ms ブロックする。
  ## しかしこれが起きるのは readiness 確認の瞬間に1回と、その後は
  ## `checkIntervalSelfSpawned`（15秒）間隔でしかない。この程度のブロックは
  ## デーモン全体の応答性に対して十分小さく許容範囲。これを非同期にすると
  ## `osproc`（同期 API 前提）と `asyncdispatch` の混在という複雑さが増える
  ## 一方、得られる利益（この稀にしか起きない数十msの短縮）は小さいため、
  ## あえて非同期化していない。
  case hs.state
  of hsIdle:
    maybeStartConnecting(hs)

  of hsConnecting:
    if ownProcessExited(hs):
      handleMasterDeath(hs)
      return
    if socketExists(hs.ctlPath):
      ## `checkMaster` が返す pid は使わない: 自スポーンの場合は spawn
      ## 時点で既に正しい pid（`hs.pid`）を知っているので上書きの必要が
      ## 無い。それどころか実測では、fake ssh フィクスチャの `-O check`
      ## は実マスターの pid ではなく `-O check` 呼び出し自身の（短命な）
      ## `$$` を返すため、ここで上書きすると誤った pid で監視すること
      ## になってしまう（実 ssh では正しい pid が返るはずだが、
      ## 自スポーンの場合はそもそも上書きする理由が無い）。
      let (alive, _) = checkMaster(hs.ctlPath, hs.host)
      if alive:
        hs.lastConnectedAt = some(getMonoTime())
        hs.lastPeriodicCheckAt = some(getMonoTime())
        hs.connectingSince = none(MonoTime)
        transition(hs, heCheckSucceeded)
        return
      # ソケットはあるが check が失敗した（レアケース）。下の readiness
      # タイムアウト判定に委ねて次 tick 以降も待つ。
    if hs.connectingSince.isSome and
        getMonoTime() - hs.connectingSince.get() >= readinessTimeout:
      handleReadinessTimeout(hs)

  of hsConnected:
    if ownProcessExited(hs):
      handleMasterDeath(hs)
      return
    if hs.lastConnectedAt.isSome and
        getMonoTime() - hs.lastConnectedAt.get() >= connectedStableFor:
      hs.consecutiveFailures = 0
      hs.backoffSeconds = 0.0
    # adopt したホスト（`process` が None）は `peekExitCode` が使えず
    # `-O check` だけが死活監視の手段なので、間隔を短くする（M6）。
    let checkInterval =
      if hs.adopted: checkIntervalAdopted else: checkIntervalSelfSpawned
    if hs.lastPeriodicCheckAt.isNone or
        getMonoTime() - hs.lastPeriodicCheckAt.get() >= checkInterval:
      hs.lastPeriodicCheckAt = some(getMonoTime())
      let (alive, _) = checkMaster(hs.ctlPath, hs.host)
      if not alive:
        handleMasterDeath(hs)
        return
    if refCount(hs) == 0 and hs.idleSince.isSome and
        getMonoTime() - hs.idleSince.get() >= idleGracePeriod:
      transition(hs, heIdleGraceExpired)
      if hs.state == hsStopping:
        nudgeStop(hs)

  of hsReconnecting:
    if hs.nextRetryAt.isSome and getMonoTime() >= hs.nextRetryAt.get():
      hs.nextRetryAt = none(MonoTime)
      if refCount(hs) > 0:
        transition(hs, hePreparedToConnect)
        if hs.state == hsConnecting:
          spawnMaster(hs)
      else:
        # 誰も参照していない状態でバックオフが明けても再接続する意味が
        # 無い。hsReconnecting は生存プロセスを持たないので
        # heStopRequested は hsStopping を経由せず直接 hsStopped に落ちる
        # （statemachine.nim の設計メモを参照）。
        transition(hs, heStopRequested)

  of hsStopping:
    if hs.process.isSome:
      if ownProcessExited(hs):
        reapOwnProcess(hs)
        transition(hs, heProcessReaped)
        return
    else:
      # adopt したマスター: `waitpid` が使えないので `-O check` で死活を見る
      # （M6）。`nudgeStop` が既に `-O exit` / SIGTERM を送っているはずなので、
      # ここでは単に「もう死んだか」を確認するだけでよい。
      let (alive, _) = checkMaster(hs.ctlPath, hs.host)
      if not alive:
        hs.pid = 0
        transition(hs, heProcessReaped)
        return
    nudgeStop(hs)

  of hsStopped:
    maybeStartConnecting(hs)

  of hsFailed:
    ## 諦めた状態。既定の `RetryPolicy`（上限無し）では到達しない。
    ## 抜けるには `heRestartRequested` の適用が必要だが、そのための
    ## 公開 API（例: 明示的な再試行コマンド）は M3 のスコープ外なので
    ## ここでは実装しない。
    discard

# ---------------------------------------------------------------------------
# 明示停止
# ---------------------------------------------------------------------------

proc requestStop*(hs: HostSession; immediate = false) =
  ## 明示停止。
  ##
  ## - `immediate = false`（既定）: `hsConnected` のときは `forwardIds` を
  ##   空にして `idleSince` をセットするに留め、通常の grace 判定
  ##   （`tick` の `idleGracePeriod` 満了チェック）に委ねる。それ以外の
  ##   状態では grace の概念自体が状態機械上に無い（`heStopRequested` は
  ##   常に即座に適用される）ので、そのまま即座に遷移させる。
  ## - `immediate = true`（`powarder down` 相当）: grace を待たず今すぐ
  ##   `heStopRequested` を適用し、必要ならその場で停止処理も1回進める。
  hs.forwardIds = @[]
  if hs.state == hsConnected and not immediate:
    if hs.idleSince.isNone:
      hs.idleSince = some(getMonoTime())
    return
  transition(hs, heStopRequested)
  if hs.state == hsStopping:
    nudgeStop(hs)

proc waitUntilDead(p: Process; timeout: Duration): bool =
  ## `p` が `timeout` 以内に終了するのを非ブロッキングポーリングで待つ。
  let deadline = getMonoTime() + timeout
  while p.peekExitCode() == -1:
    if getMonoTime() >= deadline:
      return false
    sleep(20)
  true

proc teardown*(hs: HostSession) =
  ## 同期的に完全終了させる（デーモンの graceful shutdown 用）。
  ##
  ## `tick` が駆動する非同期的な `hsStopping` の遷移とは異なり、これは
  ## どの状態から呼ばれても「呼び出しが返った時点でプロセスが残っていない」
  ## ことを保証しなければならない。そのため状態機械のイベントを1つずつ
  ## 適用するのではなく、生存確認 → `-O exit` → 猶予 → SIGTERM → 猶予 →
  ## SIGKILL → `waitForExit` という手順を直接実行し、最後に `hsStopped` を
  ## 直接セットする（`nextHostState` を経由しない。教義的には
  ## hsConnecting からは2段階のイベント適用が必要になる等、状態ごとに
  ## 経路が異なり煩雑なため、「強制的に確実に止める」という teardown の
  ## 契約上は直接セットの方が素直）。
  ##
  ## `waitForExit` を最後に必ず呼ぶ: `osproc` は SIGCHLD ハンドラを持たない
  ## ので、`terminate`/`kill` しただけではゾンビが残る。
  if hs.process.isSome:
    let p = hs.process.get()
    if p.peekExitCode() == -1:
      discard exitMaster(hs.ctlPath, hs.host)
      if not waitUntilDead(p, teardownGracePeriod):
        try:
          p.terminate()
        except OSError:
          discard
        if not waitUntilDead(p, teardownGracePeriod):
          try:
            p.kill()
          except OSError:
            discard
    discard p.waitForExit()
    try:
      p.close()
    except CatchableError:
      discard
  elif hs.adopted and hs.pid > 0:
    # adopt したマスター: `Process` を持たないので `waitForExit` は使えない
    # （M6）。`-O exit` を試み、それでもまだ `-O check` で生きていることが
    # 確認できれば SIGTERM を送るだけに留める（`waitpid` できないので終了を
    # 確認する手段が無いが、自分の子ではないのでゾンビ化の心配は無く、
    # init/launchd が回収する）。
    discard exitMaster(hs.ctlPath, hs.host)
    let (alive, _) = checkMaster(hs.ctlPath, hs.host)
    if alive:
      discard posix.kill(Pid(hs.pid), SIGTERM)
  hs.process = none(Process)
  hs.pid = 0
  hs.forwardIds = @[]
  hs.state = hsStopped

# ---------------------------------------------------------------------------
# 表示
# ---------------------------------------------------------------------------

proc isConnected*(hs: HostSession): bool {.inline.} =
  hs.state == hsConnected

proc describeState*(hs: HostSession): string =
  ## `powarder hosts` の表示用（state と retry 回数を人間可読にする）。
  case hs.state
  of hsIdle: "idle"
  of hsConnecting: "connecting"
  of hsConnected: "connected"
  of hsReconnecting:
    var s = "reconnecting (failures: " & $hs.consecutiveFailures
    if hs.nextRetryAt.isSome:
      let remain = hs.nextRetryAt.get() - getMonoTime()
      let clipped = if remain > DurationZero: remain else: DurationZero
      s.add(", retry in " & formatDuration(clipped))
    s.add(")")
    s
  of hsStopping: "stopping"
  of hsStopped: "stopped"
  of hsFailed: "failed (gave up after " & $hs.consecutiveFailures & " failures)"
