## 個々のポートフォワード1本のライフサイクル管理。
##
## powarder は「1ホスト = 1つの長命マスター」(`daemon/hostsession`) を維持し、
## 個々のフォワードはそのマスターに `-O forward` で後付けする
## (`daemon/muxclient`)。**`fkLocal`（`-L`）では ssh に UDS を張らせ、
## ユーザー指定ポートは powarder 自身が listen してその UDS へ中継する**
## (`proxy/listener`)。このモジュールは上記2つを繋ぐ層であり、
##
## ```
## クライアント → [powarder が listen] → [ssh が listen: UDS] → 踏み台 → 宛先
## ```
##
## の構図のうち「ssh 側に forward を張る/外す」と「powarder 側のリスナーを
## 起動する/閉じる」を1本の `Forward` として一体管理する。
##
## **状態遷移の判断はすべて `core/statemachine` に委譲する。** ここでは
## `nextForwardState` / `healthVerdict` / `isDiscard` の適用結果をそのまま
## 反映するだけで、独自の if 文で遷移条件を書き直すことはしない。
##
## ## 同期 / 非同期
##
## `tick()` は `daemon/hostsession.tick` と同じ理由で**同期関数**にする
## （デーモンは 500ms ループから両方を呼ぶ）。一方 `proxy/listener.serve()` は
## async proc なので、その `Future[void]` は `proxyTask` に保持し、`close()` の
## 後に回収（読み取り）する。`tick` 内で Future の完了を待つ必要が生じても
## `waitFor` は使わない（イベントループ内からのネストになり得るため）。
## 未完了なら何もせず次回の `tick` に持ち越す（ポーリング）。
##
## `teardown()` だけは例外的に `waitFor` を使う同期関数にする。**これは
## デーモンの async ループが完全に停止した後に呼ばれる前提**
## （`daemon/hostsession.teardown` と同じ制約）。tick が回っている最中に
## `teardown` を呼んではいけない。
##
## ## ヘルスチェック: Tier 3 が主体
##
## 定期プローブ（Tier 2、`proxy/upstream.probeUpstream` を周期実行する方式）は
## デフォルトで行わない。`probeUpstream` は OpenSSH の
## `channel_post_port_listener()` の実装上、宛先への実接続を必ず発生させて
## しまうため、定期実行すると宛先の接続ログにノイズを撒き続けることになる。
##
## 代わりに **Tier 3（実トラフィックの副産物）** を使う: `proxy/stats` の
## `failedConns` が前回 tick から増えていたら、実際のクライアント接続が上流に
## 繋がらなかったということなので不健全とみなす。この設計の利点は
## **トラフィックの多いフォワードほど異常検知が速くなる**こと
## （次の定期プローブを待たずに、接続が来た瞬間に検知できる）。
##
## `fkRemote` は powarder がデータパスに介在しないため統計を原理的に取れず
## Tier 3 が使えない。`-R` のヘルスチェックは「マスターが生きているか」
## （`hostsession` の責務）だけに留まる。

import std/[os, options, asyncdispatch]

import powarder/core/types
import powarder/core/statemachine
import powarder/core/forwardspec
import powarder/core/paths
import powarder/core/muxparse
import powarder/core/errorclass
import powarder/daemon/hostsession
import powarder/daemon/muxclient
import powarder/proxy/listener
import powarder/proxy/stats
import powarder/proxy/upstream

type
  Forward* = ref object
    id*: string ## forwardspec.forwardId() の結果。実体（bind 対象）から決定的に導出される
    tunnelName*: string
    spec*: ForwardSpec
    host*: HostSession ## 所属マスター（参照。所有はしない）
    upstream*: UpstreamTarget ## fkLocal: ukUnix の UDS パス / fkRemote: 未使用
    proxy*: Option[ForwardProxy]          ## fkLocal のみ。fkRemote では none
    proxyTask*: Option[Future[void]] ## serve() の Future。close 後に await して未処理 Future を残さない
    state*: ForwardState
    consecutiveHealthFailures*: int
    lastSeenFailedConns*: int ## Tier3 判定用。前回 tick 時点の stats.failedConns
    attachRetried*: bool ## bind 失敗後の「1回だけ再試行」を使ったか
    lastError*: string
    lastErrorKind*: ErrorKind
    # ---- 以下、公開型定義には無い内部専用フィールド（テストからは触らない）。
    # fwDetaching の副作用確認（cancel -> probe）を tick をまたいで段階的に
    # 進めるための進捗フラグ。`hostsession.HostSession.lastPeriodicCheckAt` と
    # 同じ考え方。
    detachCancelIssued: bool ## -O cancel を既に投げたか（1回でよい）
    detachProbeTask: Option[Future[bool]] ## probeUpstream() の進行中 Future
    detachConfirmed: bool ## 副作用確認済み。isDiscardable がこれを見る
    detachStuck: bool ## cancel の副作用が確認できず recycle 待ちで詰まっている

# ---------------------------------------------------------------------------
# 内部ヘルパー: 状態遷移
# ---------------------------------------------------------------------------

proc transition(fw: Forward; event: ForwardEvent) =
  ## `statemachine.nextForwardState` の結果をそのまま適用する内部ヘルパー。
  ## `none` が返るのは本来ここに来ないはずの実装バグを意味するが、
  ## `hostsession.transition` と同じ理由でデーモン全体を巻き込んで落ちることは
  ## 避け、状態を変えずに黙って無視する。
  ##
  ## **例外**: `fwDetaching` + `feDetachConfirmed` は「破棄可能」を表す正常な
  ## `none`（`ForwardState` に「破棄済み」の値が無いため）。この組み合わせは
  ## `finishDetach` が `isDiscard` 経由で個別に扱うので、ここからは呼ばない。
  let next = nextForwardState(fw.state, event)
  if next.isSome:
    fw.state = next.get()

# ---------------------------------------------------------------------------
# attach
# ---------------------------------------------------------------------------

proc recordSshAttachFailure(fw: Forward; outcome: MuxOutcome) =
  ## ssh 側の `-O forward` 失敗（bind 失敗の再試行も尽きた場合を含む）を記録する。
  ## `core/errorclass` の分類はマスターの stderr ログ全体を対象にした設計で
  ## `-O forward` 単発の結果（`MuxOutcome`）とは語彙が異なるため、ここでは
  ## 専用の文言を組み立てる。
  fw.lastErrorKind = ekUnknown
  fw.lastError = "ssh -O forward が失敗しました (" & $outcome & ")"

proc attach(fw: Forward) =
  ## fwPending から実際の attach を試みる。ssh 側（-O forward）と powarder 側
  ## （fkLocal のみ、ユーザー指定ポートの listener）の両方が確認できて初めて
  ## fwActive に遷移する。途中はすべて fwAttaching のまま進める。
  ##
  ## 手順（順序が重要。詳細は各ステップのコメントを参照）:
  ## 1. UDS の残骸を消す
  ## 2. `-O forward` を張る
  ## 3. bind 失敗なら1回だけ再試行する
  ## 4. 成功したら fkLocal のみ powarder 側リスナーを起動する
  ## 5. リスナーの bind に失敗したら ssh 側を cancel で巻き戻す
  transition(fw, feAttachStarted) ## fwPending -> fwAttaching

  let udsPath = if fw.spec.kind == fkLocal: fw.upstream.path else: ""

  # 手順1: UDS の残骸を消す。
  # **`os.fileExists` を使ってはいけない** — `S_ISREG` しか見ないのでソケット
  # には常に false を返す。`paths.socketExists` を使う。
  if fw.spec.kind == fkLocal and socketExists(udsPath):
    removeFile(udsPath)

  # 手順2: ssh 側に forward を張る
  var outcome = muxclient.addForward(fw.host.ctlPath, fw.host.host, fw.spec, udsPath)

  # 手順3: bind 失敗は「まだ再試行していなければ」1回だけ再試行する。
  # ssh は `-o StreamLocalBindUnlink=yes` 付きで起動されているので通常はここに
  # 来ないが、権限の問題などで残骸が消せないケースの保険。
  if outcome == moBindFailed and not fw.attachRetried:
    fw.attachRetried = true
    if fw.spec.kind == fkLocal:
      removeFile(udsPath)
    outcome = muxclient.addForward(fw.host.ctlPath, fw.host.host, fw.spec, udsPath)

  if outcome != moSuccess:
    # 初回で bind 失敗以外だった場合、または再試行後もなお失敗した場合は
    # feAttachFailedOther 相当（2回目以降の bind 失敗を feAttachBindFailed で
    # 表現しないのは statemachine.nim の設計メモのとおり）。
    recordSshAttachFailure(fw, outcome)
    transition(fw, feAttachFailedOther) ## fwAttaching -> fwError
    return

  # 手順4: ssh 側は張れた。fkLocal なら powarder 側のリスナーを起動する。
  #
  # **既に起動済み（ホスト再接続による re-attach）ならそのまま使い回す。**
  # bindPort も UDS パスも forwardId から決定的に導出され、ホストの再接続
  # だけでは変わらない。リスナーを毎回作り直すと、既にこのプロセスが握って
  # いる同じユーザー指定ポートへ二重に bind しようとして必ず失敗する。
  # 各クライアント接続は毎回 `dialUpstream` で UDS へ新規に接続し直すので
  # （`proxy/listener.handleConnection` を参照）、UDS の中身がマスター再接続で
  # 入れ替わっていても powarder 側のリスナーは無停止で動き続けられる。
  if fw.spec.kind == fkLocal and fw.proxy.isNone:
    try:
      let proxy = newForwardProxy(fw.spec.bindAddr, fw.spec.bindPort,
          UpstreamTarget(kind: ukUnix, path: udsPath))
      fw.proxy = some(proxy)
      fw.proxyTask = some(serve(proxy))
    except CatchableError:
      # 手順5: ユーザー指定ポートが既に使用中など。これは ssh 側の失敗とは
      # 別物なので errorclass.ekPortInUse として記録し、既に張ってしまった
      # ssh 側の forward を cancelForward で巻き戻す（張ったまま放置すると
      # 次回 attach で残骸扱いになる）。
      discard muxclient.cancelForward(fw.host.ctlPath, fw.host.host, fw.spec, udsPath)
      let expl = explain(ekPortInUse, langEn,
          initErrorContext(bindPort = int(fw.spec.bindPort)))
      fw.lastErrorKind = ekPortInUse
      fw.lastError = expl.summary
      transition(fw, feAttachFailedOther) ## fwAttaching -> fwError
      return

  # fkRemote はリモート側が listen するので powarder は介在しない
  # （プロキシは起動しない）。
  transition(fw, feAttachSucceeded) ## fwAttaching -> fwActive
  fw.consecutiveHealthFailures = 0
  fw.lastSeenFailedConns =
    if fw.proxy.isSome: fw.proxy.get().stats.failedConns else: 0

# ---------------------------------------------------------------------------
# ヘルスチェック（Tier 3）
# ---------------------------------------------------------------------------

proc healthCheck(fw: Forward) =
  ## `fwActive` / `fwDegraded` で毎 tick 呼ばれる。判定は
  ## `statemachine.healthVerdict` に一任する（モジュール doc comment の
  ## 「ヘルスチェック: Tier 3 が主体」を参照）。
  if fw.spec.kind != fkLocal or fw.proxy.isNone:
    # fkRemote は統計を取れないので Tier3 は使えない。マスター生死の監視は
    # hostsession の責務なのでここでは何もしない。
    return

  let currentFailed = fw.proxy.get().stats.failedConns
  if currentFailed > fw.lastSeenFailedConns:
    inc fw.consecutiveHealthFailures
  else:
    fw.consecutiveHealthFailures = 0
  fw.lastSeenFailedConns = currentFailed

  let verdict = healthVerdict(fw.consecutiveHealthFailures, fw.state)
  if verdict == fwPending:
    # 強制 re-attach。次の attach で「1回だけ再試行」をまた使えるようにする。
    fw.attachRetried = false
    fw.consecutiveHealthFailures = 0
  fw.state = verdict

# ---------------------------------------------------------------------------
# detach
# ---------------------------------------------------------------------------

proc finishDetach(fw: Forward) =
  ## cancel + 副作用確認（または fkRemote の場合は cancel のみ）が完了した。
  ## `nextForwardState(fwDetaching, feDetachConfirmed)` は `none` を返す設計
  ## （`ForwardState` に「破棄済み」の値が無いため）なので、`isDiscard` で
  ## それが正常な「破棄してよい」の合図であることを確認したうえで、`state`
  ## 自体は変えず `detachConfirmed` フラグで破棄可能を表す
  ## （`isDiscardable` はこのフラグを見る）。
  doAssert isDiscard(fw.state, feDetachConfirmed)
  if fw.spec.kind == fkLocal:
    removeFile(fw.upstream.path)
  fw.host.removeForwardRef(fw.id)
  fw.detachConfirmed = true

proc checkDetachProgress(fw: Forward) =
  ## `fwDetaching` で毎 tick 呼ばれる。detach の手順を tick をまたいで段階的に
  ## 進める（`tick` は同期関数で、`serve()` の Future や `probeUpstream` の
  ## Future を `waitFor` で待つとイベントループ内でネストしてしまうため）。
  ##
  ## 手順（`requestDetach` の doc comment、モジュール先頭の設計と対応）:
  ## 1. プロキシの `Future` を回収する（`close()` 自体は `requestDetach` で
  ##    既に呼んである）
  ## 2. `-O cancel`（1回だけ発行する。exit code は信用しない）
  ## 3. 副作用を実測して確認する（`probeUpstream` が false を返すことを見る。
  ##    宛先へ実接続を発生させるため1回だけに留める）
  ## 4. UDS 残骸を消す
  ## 5. 参照カウントを減らす
  if fw.detachConfirmed or fw.detachStuck:
    return ## 既に確定済み（破棄可能、またはホスト recycle 待ちで詰まっている）

  # 手順1: プロキシの Future を回収する
  if fw.proxyTask.isSome:
    let fut = fw.proxyTask.get()
    if not fut.finished:
      return ## 次回の tick に持ち越す
    try:
      fut.read() ## 失敗していれば例外が飛ぶので握りつぶす
    except CatchableError:
      discard
    fw.proxyTask = none(Future[void])

  # 手順2: -O cancel（1回だけ発行する）。exit code は一切信用できない
  # （成功・失敗どちらも 0 を返す）ので、ここでは結果を見ずに投げるだけ。
  # 真の判定は手順3の副作用確認で行う。
  if not fw.detachCancelIssued:
    let udsPath = if fw.spec.kind == fkLocal: fw.upstream.path else: ""
    discard muxclient.cancelForward(fw.host.ctlPath, fw.host.host, fw.spec, udsPath)
    fw.detachCancelIssued = true
    return ## 副作用確認は次 tick 以降で行う

  # fkRemote は「宛先への実接続」による副作用確認手段が無い
  # （powarder がデータパスに介在しないため）。cancel を投げた事実だけで
  # 確定させる。
  if fw.spec.kind == fkRemote:
    finishDetach(fw)
    return

  # 手順3: 副作用を実測して確認する。
  # **注意**: `probeUpstream` は宛先に実接続を発生させる（OpenSSH の
  # `channel_post_port_listener` が accept 直後に `direct-tcpip` を開くため
  # 回避不可能）。detach 時の1回だけなので許容する（繰り返しプローブはしない）。
  if fw.detachProbeTask.isNone:
    fw.detachProbeTask = some(probeUpstream(fw.upstream))
    return ## 次回の tick で結果を回収する

  let probeFut = fw.detachProbeTask.get()
  if not probeFut.finished:
    return ## 次回の tick に持ち越す
  let stillReachable = probeFut.read()
  fw.detachProbeTask = none(Future[bool])

  if stillReachable:
    # cancel が嘘をついている（成功報告なのに実際には解除されていない）。
    # ホストごと recycle が必要な状態としてここで詰まる（自動では復旧しない）。
    fw.detachStuck = true
    fw.lastErrorKind = ekUnknown
    fw.lastError = "cancel 後も UDS " & fw.upstream.path &
        " へ接続できてしまうため、ホストごと recycle が必要です"
    return

  finishDetach(fw)

# ---------------------------------------------------------------------------
# 公開 API
# ---------------------------------------------------------------------------

proc newForward*(tunnelName: string; spec: ForwardSpec;
    host: HostSession): Forward =
  ## `id` を `forwardspec.forwardId(spec, host.host)` で決め、`fkLocal` なら
  ## `paths.forwardSocketPath(forwardspec.udsBasename(id))` で UDS パスを決める。
  ## `host.addForwardRef(id)` を呼んで参照カウントを増やす。
  ## 状態は `fwPending`。プロセスもプロキシもまだ起動しない（実際の attach は
  ## `tick()` 経由で行う）。
  let id = forwardId(spec, host.host)
  let upstream =
    if spec.kind == fkLocal:
      UpstreamTarget(kind: ukUnix, path: forwardSocketPath(udsBasename(id)))
    else:
      UpstreamTarget(kind: ukUnix, path: "") ## fkRemote では未使用

  result = Forward(
    id: id,
    tunnelName: tunnelName,
    spec: spec,
    host: host,
    upstream: upstream,
    proxy: none(ForwardProxy),
    proxyTask: none(Future[void]),
    state: fwPending,
    consecutiveHealthFailures: 0,
    lastSeenFailedConns: 0,
    attachRetried: false,
    lastError: "",
    lastErrorKind: ekUnknown,
    detachCancelIssued: false,
    detachProbeTask: none(Future[bool]),
    detachConfirmed: false,
    detachStuck: false,
  )
  host.addForwardRef(id)

proc adoptForward*(tunnelName: string; spec: ForwardSpec;
    host: HostSession): Forward =
  ## 孤児 Forward の adopt（M6）用コンストラクタ。呼び出し側
  ## （`daemon/orphan.adoptOrphans`）が UDS への `probeUpstream` で「まだ
  ## 生きている」ことを確認済みの `fkLocal` Forward を、いきなり `fwActive`
  ## として引き継ぐ。
  ##
  ## **`attach()` は経由しない。** `attach()` の手順1は UDS の残骸を無条件に
  ## `removeFile` するが、ここで扱うのは残骸ではなく生きている UDS なので、
  ## 消してしまうと引き継ぐはずのフォワードを自分で壊すことになる。
  ##
  ## fkLocal は powarder 側リスナーもここで起動する（前回のプロセスが握って
  ## いた `bindPort` を引き継ぐだけなので、adopt 直後の1回はまず衝突しない
  ## 想定）。bind に失敗した場合は例外を投げず `fwError` にして返す
  ## （`attach()` のユーザー指定ポート使用中ハンドリングと同じ方針だが、
  ## adopt では ssh 側を巻き戻す cancelForward は行わない。まだ生きている
  ## UDS を壊さないという上記の理由と同様、意図せず forward を失う方向には
  ## 倒さない）。
  let id = forwardId(spec, host.host)
  let upstream =
    if spec.kind == fkLocal:
      UpstreamTarget(kind: ukUnix, path: forwardSocketPath(udsBasename(id)))
    else:
      UpstreamTarget(kind: ukUnix, path: "") ## fkRemote では未使用（このパスは通常呼ばれない）

  result = Forward(
    id: id,
    tunnelName: tunnelName,
    spec: spec,
    host: host,
    upstream: upstream,
    proxy: none(ForwardProxy),
    proxyTask: none(Future[void]),
    state: fwActive,
    consecutiveHealthFailures: 0,
    lastSeenFailedConns: 0,
    attachRetried: false,
    lastError: "",
    lastErrorKind: ekUnknown,
    detachCancelIssued: false,
    detachProbeTask: none(Future[bool]),
    detachConfirmed: false,
    detachStuck: false,
  )
  host.addForwardRef(id)

  if spec.kind == fkLocal:
    try:
      let proxy = newForwardProxy(spec.bindAddr, spec.bindPort,
          UpstreamTarget(kind: ukUnix, path: upstream.path))
      result.proxy = some(proxy)
      result.proxyTask = some(serve(proxy))
      result.lastSeenFailedConns = proxy.stats.failedConns
    except CatchableError as e:
      result.state = fwError
      result.lastErrorKind = ekPortInUse
      result.lastError = "adopt 時の powarder 側リスナー起動に失敗しました: " & e.msg

proc tick*(fw: Forward) =
  ## デーモンの 500ms ループから毎回呼ばれる。現在の状態に応じて必要な処理を
  ## 1回だけ進める（`hostsession.tick` と同じ設計）。
  ##
  ## 所属ホストが `isConnected` でなくなったら、どの状態からでも
  ## `feHostLost` で `fwPending` に戻す（`statemachine` の「任意の状態から」
  ## ルール）。`fwDetaching` 中にこれが起きるケースは稀な想定
  ## （`statemachine.nim` の設計メモを参照。daemon 層が `requestDetach` 済みの
  ## 対象を管理対象から外していれば実質発生しない）だが、備えとして
  ## `requestDetach` は毎回 detach 用の内部フラグをリセットするので、
  ## 万一その後に再度 detach されても正しくやり直せる。
  if not fw.host.isConnected():
    if fw.state != fwPending:
      transition(fw, feHostLost)
    return

  case fw.state
  of fwPending:
    attach(fw)
  of fwAttaching:
    discard ## attach() が同期的に完結させるので、tick 単独でここに来ることは無い
  of fwActive, fwDegraded:
    healthCheck(fw)
  of fwDetaching:
    checkDetachProgress(fw)
  of fwError:
    discard ## 自動では復帰しない。requestDetach か feHostLost 経由のみ

proc requestDetach*(fw: Forward) =
  ## 設定から消えた / stop されたときに呼ぶ。`fwDetaching` へ遷移させる。
  ##
  ## 手順1（プロキシを先に閉じ、新規接続を受け付けなくする）はここで即座に
  ## 行う。`close()` は同期関数。`proxyTask` の回収（await 相当）は
  ## `tick`（`checkDetachProgress`）に委ねる。
  ##
  ## 前回の detach サイクルの内部状態が残っていても正しく最初からやり直せる
  ## よう、副作用確認用の内部フラグをここで毎回リセットする。
  fw.detachCancelIssued = false
  fw.detachProbeTask = none(Future[bool])
  fw.detachConfirmed = false
  fw.detachStuck = false
  if fw.proxy.isSome:
    fw.proxy.get().close()
  transition(fw, feDetachRequested)

proc teardown*(fw: Forward) =
  ## 同期的に完全に片付ける（デーモンの graceful shutdown 用）。
  ##
  ## **デーモンの async ループが停止した後に呼ばれる前提。** `tick` が回って
  ## いる最中に呼んではいけない（`waitFor` をイベントループ内からネストして
  ## 呼ぶことになり問題が起きるため。`hostsession.teardown` と同じ制約）。
  ##
  ## `tick` 駆動の段階的な detach（`checkDetachProgress`）とは異なり、これは
  ## どの状態から呼ばれても「呼び出しが返った時点で後始末が終わっている」
  ## ことを保証する。副作用の実測確認（`probeUpstream`）は行わない
  ## （teardown はとにかく片付けきる契約であり、そのために宛先へ余分な実接続を
  ## 発生させる必要は無いため）。
  if fw.proxy.isSome:
    let proxy = fw.proxy.get()
    proxy.close()
    if fw.proxyTask.isSome:
      let fut = fw.proxyTask.get()
      try:
        waitFor fut
      except CatchableError:
        discard
      fw.proxyTask = none(Future[void])

  let udsPath = if fw.spec.kind == fkLocal: fw.upstream.path else: ""
  discard muxclient.cancelForward(fw.host.ctlPath, fw.host.host, fw.spec, udsPath)

  if fw.spec.kind == fkLocal:
    removeFile(udsPath)

  fw.host.removeForwardRef(fw.id)
  fw.state = fwDetaching
  fw.detachCancelIssued = true
  fw.detachConfirmed = true

proc isDiscardable*(fw: Forward): bool =
  ## `fwDetaching` かつ副作用確認が済んで、レジストリから削除してよい状態か。
  fw.state == fwDetaching and fw.detachConfirmed

proc stats*(fw: Forward): Option[ForwardStats] =
  ## `fkLocal` ならプロキシの統計。`fkRemote` は none（統計が原理的に取れない）。
  if fw.spec.kind == fkLocal and fw.proxy.isSome:
    some(fw.proxy.get().stats)
  else:
    none(ForwardStats)

proc describeState*(fw: Forward): string =
  case fw.state
  of fwPending: "pending"
  of fwAttaching: "attaching"
  of fwActive: "active"
  of fwDegraded: "degraded (health failures: " & $fw.consecutiveHealthFailures & ")"
  of fwDetaching:
    if fw.detachStuck: "detaching (stuck: " & fw.lastError & ")"
    elif fw.detachConfirmed: "detached"
    else: "detaching"
  of fwError: "error: " & fw.lastError
