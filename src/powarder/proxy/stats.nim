## Connection statistics for a single forward. Holds only raw numbers and
## timestamps; formatting for display is not done here (that is
## `core/fmt.nim`'s responsibility).
##
## Since `asyncdispatch` is single-threaded cooperative multitasking, no
## data race occurs even when multiple connection handlers update the
## integer fields of the same `ForwardStats` (this assumes the
## `--threads:on` thread pool is not used. Updates always happen within a
## synchronous section between awaits and are never interrupted).

import std/deques
import std/monotimes
import std/times
import powarder/core/types

const
  maxRecentSources* = 5 ## Number of recent connection sources kept in `recentSources`

type
  SourceEntry* = object
    address*: string
    port*: Port
    at*: Time ## For display (wall clock)

  ForwardStats* = ref object
    activeConns*, totalConns*, rejectedConns*, failedConns*: int
    bytesRx*, bytesTx*: uint64
    lastActivityMono*: MonoTime ## For idle detection / elapsed-time computation
    lastActivityWall*: Time     ## For display
    startedAtMono*: MonoTime
    startedAtWall*: Time
    recentSources*: Deque[SourceEntry] ## The most recent `maxRecentSources` entries

proc newForwardStats*(): ForwardStats =
  ## Creates an empty stats object with the start time initialized to the
  ## current time.
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
  ## Internal helper that updates the last-activity time (both Mono/Wall)
  ## to "now."
  s.lastActivityMono = getMonoTime()
  s.lastActivityWall = getTime()

proc recordConnect*(s: ForwardStats; address: string; port: Port) =
  ## Records a new connection. Appends to `recentSources`, and discards
  ## the oldest entries via `popFirst` once the limit is exceeded.
  inc s.activeConns
  inc s.totalConns
  s.recentSources.addLast(SourceEntry(address: address, port: port, at: getTime()))
  while s.recentSources.len > maxRecentSources:
    discard s.recentSources.popFirst()
  s.touch()

proc recordDisconnect*(s: ForwardStats) =
  ## Records a connection ending. `activeConns` is never allowed to go
  ## below 0.
  if s.activeConns > 0:
    dec s.activeConns
  s.touch()

proc recordRx*(s: ForwardStats; n: int) =
  ## Adds to the byte count in the client -> upstream direction.
  s.bytesRx += n.uint64
  s.touch()

proc recordTx*(s: ForwardStats; n: int) =
  ## Adds to the byte count in the upstream -> client direction.
  s.bytesTx += n.uint64
  s.touch()

proc recordRejected*(s: ForwardStats) =
  ## Records a connection that was closed immediately due to exceeding
  ## `maxConns`.
  inc s.rejectedConns

proc recordFailed*(s: ForwardStats) =
  ## Records the number of times establishing a connection to the
  ## upstream failed.
  inc s.failedConns

proc uptime*(s: ForwardStats): Duration =
  ## Elapsed time since this forward started. Since it is a `MonoTime`
  ## difference, it is unaffected by NTP adjustments or manual clock
  ## changes.
  getMonoTime() - s.startedAtMono

proc idleFor*(s: ForwardStats): Duration =
  ## Elapsed time since the last communication.
  getMonoTime() - s.lastActivityMono
