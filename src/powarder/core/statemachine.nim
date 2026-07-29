## HostSession / Forward の状態遷移とバックオフ計算を扱う純粋ロジック層。
##
## このモジュールは「この状態でこのイベントが起きたら次はどの状態か」を
## 返す関数の集まりであり、実際の状態の保持・ssh プロセスの起動や停止・
## タイマーの管理は daemon 層の責務。`std/asyncnet` / `std/osproc` /
## `std/os` は import しない。

import std/options

import powarder/core/types

# ---------------------------------------------------------------------------
# バックオフ
# ---------------------------------------------------------------------------

proc nextBackoff*(current: float; maxSeconds = defaultBackoffMaxSeconds): float =
  ## バックオフ秒数を次の値へ進める。`1 → 2 → 4 → 8 → 16 → 30(上限)` と
  ## 倍々に増え、`maxSeconds` で頭打ちになる。
  ## `current` が 0 以下（未設定/初期値）のときは 1 を返す。
  if current <= 0.0:
    1.0
  else:
    min(current * 2.0, maxSeconds)

proc shouldGiveUp*(consecutiveFailures: int; policy: RetryPolicy): bool =
  ## `policy.maxConsecutiveFailures == 0` なら常に false（既定は無限リトライ。
  ## ノート PC のスリープ復帰や VPN の瞬断で `hsFailed` に落ちて手動介入が
  ## 必要になる事態を避けるため）。
  ## `> 0` の場合は `consecutiveFailures >= maxConsecutiveFailures` で true。
  if policy.maxConsecutiveFailures == 0:
    false
  else:
    consecutiveFailures >= policy.maxConsecutiveFailures

# ---------------------------------------------------------------------------
# HostSession の遷移
# ---------------------------------------------------------------------------

type
  HostEvent* = enum
    hePreparedToConnect ## 参照カウントが 0→1 になった / 再接続の backoff が明けた
    heCheckSucceeded   ## `-O check` が Master running を返した
    heMasterDied       ## `peekExitCode` で終了を検知、または `-O check` が失敗
    heReadinessTimeout ## 制御ソケットが出現しないまま上限時間が経過
    heIdleGraceExpired ## 参照カウント 0 のまま猶予時間が経過
    heStopRequested    ## `down` / 明示停止
    heProcessReaped    ## 停止処理後にプロセス終了を確認
    heRetryLimitReached ## リトライ上限に達した（`shouldGiveUp` が true）
    heRestartRequested ## `hsFailed` からの復帰。カウンタをリセットする

## HostSession の遷移表
## ==========================
##
## 表の見方: 行 = 現在の状態、列 = イベント。`-` は不正な遷移で `none` を返す。
## `(self)` は同じ状態にとどまる自己ループ（idempotent な正常系）。
##
## ```
## state \ event      | hePrepared | heCheckOK | heMasterDied | heReadyTO | heIdleGrace | heStopReq   | heProcReaped | heRetryLimit | heRestartReq
## -------------------+------------+-----------+--------------+-----------+-------------+-------------+--------------+--------------+--------------
## hsIdle             | Connecting | -         | -            | -         | -           | Stopped     | -            | -            | -
## hsConnecting       | -          | Connected | Reconnecting | Reconn.   | -           | Stopping    | -            | -            | -
## hsConnected        | -          | (self)    | Reconnecting | -         | Stopping    | Stopping    | -            | -            | -
## hsReconnecting     | Connecting | -         | -            | -         | -           | Stopped     | -            | Failed       | -
## hsStopping         | -          | -         | -            | -         | -           | (self)      | Stopped      | -            | -
## hsStopped          | Connecting | -         | -            | -         | -           | -           | -            | -            | -
## hsFailed           | -          | -         | -            | -         | -           | Stopped     | -            | -            | Connecting
## ```
##
## 設計メモ:
## - `hsConnected` で `heCheckSucceeded` を受けても状態は変わらない
##   （定期ヘルスチェックが「まだ生きている」ことを確認しただけの正常系）。
## - `heMasterDied` によって配下の全 `Forward` を `fwPending` に戻す処理は
##   daemon 層の責務（`ForwardState.feHostLost` を各 Forward に配ること）。
## - `hsReconnecting` / `hsStopped` / `hsFailed` はいずれも実行中の ssh
##   プロセスを持たない（backoff 待ち、既に停止済み、既に失敗済み）ため、
##   `heStopRequested` は `hsStopping` を経由せず直接 `hsStopped` に落ちる。
## - `hsStopping` / `hsStopped` で `heStopRequested` を重ねて受けても
##   エラーにはせず自己ループする（多重の停止要求を許容する）。
proc nextHostState*(state: HostSessionState; event: HostEvent):
    Option[HostSessionState] =
  case state
  of hsIdle:
    case event
    of hePreparedToConnect: some(hsConnecting)
    of heStopRequested: some(hsStopped)
    else: none(HostSessionState)
  of hsConnecting:
    case event
    of heCheckSucceeded: some(hsConnected)
    of heMasterDied, heReadinessTimeout: some(hsReconnecting)
    of heStopRequested: some(hsStopping)
    else: none(HostSessionState)
  of hsConnected:
    case event
    of heCheckSucceeded: some(hsConnected)
    of heMasterDied: some(hsReconnecting)
    of heIdleGraceExpired, heStopRequested: some(hsStopping)
    else: none(HostSessionState)
  of hsReconnecting:
    case event
    of hePreparedToConnect: some(hsConnecting)
    of heRetryLimitReached: some(hsFailed)
    of heStopRequested: some(hsStopped)
    else: none(HostSessionState)
  of hsStopping:
    case event
    of heProcessReaped: some(hsStopped)
    of heStopRequested: some(hsStopping)
    else: none(HostSessionState)
  of hsStopped:
    case event
    of hePreparedToConnect: some(hsConnecting)
    else: none(HostSessionState)
  of hsFailed:
    case event
    of heRestartRequested: some(hsConnecting)
    of heStopRequested: some(hsStopped)
    else: none(HostSessionState)

# ---------------------------------------------------------------------------
# Forward の遷移
# ---------------------------------------------------------------------------

type
  ForwardEvent* = enum
    feHostConnected     ## 所属ホストが `hsConnected` になった
    feAttachStarted     ## `-O forward` 実行中
    feAttachSucceeded   ## `-O forward` が成功した
    feAttachBindFailed  ## `Port forwarding failed`（UDS の残骸が原因）
    feAttachFailedOther ## bind 失敗以外の理由で attach が失敗した
    feHealthFailed      ## ヘルスチェックが失敗した
    feHealthRecovered   ## ヘルスチェックが回復した
    feHostLost          ## 所属ホストが `hsConnected` を離脱した
    feDetachRequested   ## 明示的な detach 要求
    feDetachConfirmed   ## `-O cancel` 後にプロセス側の解除を確認した
    feDegradeLimitReached ## 劣化が続き強制 re-attach の閾値に達した

## Forward の遷移表
## ==========================
##
## `feHostLost` と `feDetachRequested` は **任意の状態から** 有効
## （テーブルの他のセルより優先して先に適用される）。
##
## ```
## state \ event  | feHostConn | feAttachSt | feAttachOK | feBindFail | feOtherFail | feHealthNG | feHealthOK | feHostLost | feDetachReq | feDetachOK | feDegradeLim
## ---------------+------------+------------+------------+------------+-------------+------------+------------+------------+-------------+------------+--------------
## fwPending      | (self)     | Attaching  | -          | -          | -           | -          | -          | Pending*   | Detaching*  | -          | -
## fwAttaching    | -          | -          | Active     | Pending    | Error       | -          | -          | Pending*   | Detaching*  | -          | -
## fwActive       | -          | -          | -          | -          | -           | (self)     | (self)     | Pending*   | Detaching*  | -          | -
## fwDegraded     | -          | -          | -          | -          | -           | (self)     | Active     | Pending*   | Detaching*  | -          | Pending
## fwDetaching    | -          | -          | -          | -          | -           | -          | -          | Pending*   | (self)*     | (discard)  | -
## fwError        | -          | -          | -          | -          | -           | -          | -          | Pending*   | Detaching*  | -          | -
## ```
## （`*` は「任意の状態から」ルールにより到達する遷移）
##
## 設計メモ:
## - `feHealthFailed` / `feHealthRecovered` は「1回のイベントだけでは
##   `degradeThreshold` / `reattachThreshold` を跨げない」ので自己ループを
##   返す。実際の閾値判定は `healthVerdict` を使うこと
##   （daemon 層のヘルスチェックループは `nextForwardState` ではなく
##   `healthVerdict` を主に使う想定）。ただし `fwDegraded` の
##   `feHealthRecovered` だけは参考設計どおり単発で `fwActive` に戻す。
## - `feAttachBindFailed` は「unlink して1回だけ再試行する」設計だが、
##   その再試行回数のカウントは daemon 層の責務。2回目以降の bind 失敗は
##   `feAttachBindFailed` ではなく `feAttachFailedOther` を渡して
##   `fwError` に落とすこと。
## - `ForwardState` には「破棄済み」に対応する値がないため、
##   `fwDetaching` が `feDetachConfirmed` を受けたケースは `none` を返す。
##   これは「不正な遷移」の `none` と区別する必要があるため、
##   `isDiscard` で判定できるようにしている。
## - `fwDetaching` 中に `feHostLost` を受けても素直に `fwPending` に戻す
##   （参考設計の「任意」を素直に適用）。daemon 層は `feDetachRequested`
##   を出した時点で対象を管理対象から外す実装にすれば、この事象は
##   実質発生しない想定。
proc nextForwardState*(state: ForwardState; event: ForwardEvent):
    Option[ForwardState] =
  if event == feHostLost:
    return some(fwPending)
  if event == feDetachRequested:
    return some(fwDetaching)
  case state
  of fwPending:
    case event
    of feHostConnected: some(fwPending)
    of feAttachStarted: some(fwAttaching)
    else: none(ForwardState)
  of fwAttaching:
    case event
    of feAttachSucceeded: some(fwActive)
    of feAttachBindFailed: some(fwPending)
    of feAttachFailedOther: some(fwError)
    else: none(ForwardState)
  of fwActive:
    case event
    of feHealthFailed: some(fwActive)
    of feHealthRecovered: some(fwActive)
    else: none(ForwardState)
  of fwDegraded:
    case event
    of feHealthFailed: some(fwDegraded)
    of feHealthRecovered: some(fwActive)
    of feDegradeLimitReached: some(fwPending)
    else: none(ForwardState)
  of fwDetaching:
    none(ForwardState)
  of fwError:
    none(ForwardState)

proc isDiscard*(state: ForwardState; event: ForwardEvent): bool =
  ## `nextForwardState` が `none` を返したとき、それが「不正な遷移」ではなく
  ## 「`fwDetaching` が `feDetachConfirmed` を受けて正常に破棄される」
  ## ケースなのかを区別するためのヘルパ。呼び出し側はまずこれを見て、
  ## true なら Forward レコード自体を破棄し、false なら不正遷移として
  ## ログに残すとよい。
  state == fwDetaching and event == feDetachConfirmed

# ---------------------------------------------------------------------------
# ヘルスチェックの閾値判定
# ---------------------------------------------------------------------------

const
  degradeThreshold* = 3
    ## 連続失敗 3 回で `fwActive` -> `fwDegraded`
  reattachThreshold* = 9
    ## さらに続いたら強制 re-attach（`degradeThreshold` の 3 倍）

proc healthVerdict*(consecutiveFailures: int;
    current: ForwardState): ForwardState =
  ## ヘルスチェックの連続失敗回数 `consecutiveFailures` から、
  ## `fwActive` / `fwDegraded` 間の遷移、および強制 re-attach
  ## （`fwPending` へのフォールバック）を一括で判定する。
  ##
  ## - `consecutiveFailures == 0`: 健全 -> `fwActive`
  ## - `degradeThreshold` 回以上: 劣化 -> `fwDegraded`
  ## - `reattachThreshold` 回以上: 強制 re-attach -> `fwPending`
  ##
  ## `current` が `fwActive` / `fwDegraded` 以外
  ## （`fwPending` / `fwAttaching` / `fwDetaching` / `fwError`）の場合は
  ## ヘルスチェックの対象外の状態なので、`current` をそのまま返す（no-op）。
  if current != fwActive and current != fwDegraded:
    return current
  if consecutiveFailures >= reattachThreshold:
    fwPending
  elif consecutiveFailures >= degradeThreshold:
    fwDegraded
  else:
    fwActive
