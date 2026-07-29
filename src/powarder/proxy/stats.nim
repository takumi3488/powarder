## フォワード1本あたりの接続統計。生の数値と時刻だけを保持し、表示用の整形は
## 行わない（`core/fmt.nim` の担当）。
##
## `asyncdispatch` は単一スレッドの協調的マルチタスクなので、複数の接続ハンドラが
## 同じ `ForwardStats` の整数フィールドを更新してもデータ競合は起きない
## （`--threads:on` のスレッドプールは使わない前提。更新は常に await の間の
## 同期区間で行われ、割り込まれることがない）。

import std/deques
import std/monotimes
import std/times
import powarder/core/types

const
  maxRecentSources* = 5 ## `recentSources` に保持する直近の接続元の件数

type
  SourceEntry* = object
    address*: string
    port*: Port
    at*: Time ## 表示用（壁時計）

  ForwardStats* = ref object
    activeConns*, totalConns*, rejectedConns*, failedConns*: int
    bytesRx*, bytesTx*: uint64
    lastActivityMono*: MonoTime        ## アイドル判定・経過時間計算用
    lastActivityWall*: Time            ## 表示用
    startedAtMono*: MonoTime
    startedAtWall*: Time
    recentSources*: Deque[SourceEntry] ## 直近 `maxRecentSources` 件

proc newForwardStats*(): ForwardStats =
  ## 開始時刻を現在時刻で初期化した空の統計を作る。
  let nowMono = getMonoTime()
  let nowWall = getTime()
  ForwardStats(
    startedAtMono: nowMono,
    startedAtWall: nowWall,
    lastActivityMono: nowMono,
    lastActivityWall: nowWall,
    recentSources: initDeque[SourceEntry]()
  )

proc touch(s: ForwardStats) =
  ## 最終通信時刻（Mono/Wall 両方）を「今」に更新する内部ヘルパー。
  s.lastActivityMono = getMonoTime()
  s.lastActivityWall = getTime()

proc recordConnect*(s: ForwardStats; address: string; port: Port) =
  ## 新規接続を記録する。`recentSources` に追記し、上限を超えた分は
  ## 古いものから `popFirst` で捨てる。
  inc s.activeConns
  inc s.totalConns
  s.recentSources.addLast(SourceEntry(address: address, port: port, at: getTime()))
  while s.recentSources.len > maxRecentSources:
    discard s.recentSources.popFirst()
  s.touch()

proc recordDisconnect*(s: ForwardStats) =
  ## 接続終了を記録する。`activeConns` は 0 未満にはしない。
  if s.activeConns > 0:
    dec s.activeConns
  s.touch()

proc recordRx*(s: ForwardStats; n: int) =
  ## クライアント→上流方向のバイト数を加算する。
  s.bytesRx += n.uint64
  s.touch()

proc recordTx*(s: ForwardStats; n: int) =
  ## 上流→クライアント方向のバイト数を加算する。
  s.bytesTx += n.uint64
  s.touch()

proc recordRejected*(s: ForwardStats) =
  ## `maxConns` 超過で即 close された接続を記録する。
  inc s.rejectedConns

proc recordFailed*(s: ForwardStats) =
  ## 上流への接続確立に失敗した回数を記録する。
  inc s.failedConns

proc uptime*(s: ForwardStats): Duration =
  ## このフォワードが起動してからの経過時間。`MonoTime` 差分なので
  ## NTP 補正・時刻の手動変更の影響を受けない。
  getMonoTime() - s.startedAtMono

proc idleFor*(s: ForwardStats): Duration =
  ## 最後に通信があってからの経過時間。
  getMonoTime() - s.lastActivityMono
