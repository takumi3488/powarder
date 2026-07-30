## The pure logic layer handling HostSession / Forward state transitions and
## backoff calculation.
##
## This module is a collection of functions that answer "given this state and
## this event, what's the next state?" Actually holding the state, starting
## or stopping the ssh process, and managing timers are the daemon layer's
## responsibility. It does not import `std/asyncnet` / `std/osproc` /
## `std/os`.

import std/options

import powarder/core/types

# ---------------------------------------------------------------------------
# Backoff
# ---------------------------------------------------------------------------

proc nextBackoff*(current: float; maxSeconds = defaultBackoffMaxSeconds): float =
  ## Advances the backoff seconds to the next value. It doubles as
  ## `1 -> 2 -> 4 -> 8 -> 16 -> 30 (cap)`, capping out at `maxSeconds`.
  ## Returns 1 when `current` is 0 or less (unset/initial value).
  if current <= 0.0:
    1.0
  else:
    min(current * 2.0, maxSeconds)

proc shouldGiveUp*(consecutiveFailures: int; policy: RetryPolicy): bool =
  ## Always false if `policy.maxConsecutiveFailures == 0` (the default is
  ## infinite retry, to avoid falling into `hsFailed` and needing manual
  ## intervention over a laptop waking from sleep or a brief VPN blip).
  ## If `> 0`, true when `consecutiveFailures >= maxConsecutiveFailures`.
  if policy.maxConsecutiveFailures == 0:
    false
  else:
    consecutiveFailures >= policy.maxConsecutiveFailures

# ---------------------------------------------------------------------------
# HostSession transitions
# ---------------------------------------------------------------------------

type
  HostEvent* = enum
    hePreparedToConnect ## refcount went 0 -> 1 / reconnect backoff elapsed
    heCheckSucceeded    ## `-O check` returned Master running
    heMasterDied        ## exit detected via `peekExitCode`, or `-O check` failed
    heReadinessTimeout  ## control socket never appeared before the time limit
    heIdleGraceExpired  ## grace period elapsed while refcount stayed 0
    heStopRequested     ## `down` / explicit stop
    heProcessReaped     ## process exit confirmed after stop processing
    heRetryLimitReached ## retry limit reached (`shouldGiveUp` is true)
    heRestartRequested  ## recovery from `hsFailed`. Resets the counter

## HostSession transition table
## ==========================
##
## How to read the table: row = current state, column = event. `-` is an
## invalid transition that returns `none`.
## `(self)` is a self-loop that stays in the same state (an idempotent normal
## path).
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
## Design notes:
## - `hsConnected` stays in the same state when it receives
##   `heCheckSucceeded` (this is just the normal path where a periodic health
##   check confirmed "still alive").
## - Resetting all `Forward`s under this host to `fwPending` when
##   `heMasterDied` fires is the daemon layer's responsibility (distributing
##   `ForwardState.feHostLost` to each Forward).
## - `hsReconnecting` / `hsStopped` / `hsFailed` all have no running ssh
##   process (waiting on backoff, already stopped, already failed), so
##   `heStopRequested` falls straight through to `hsStopped` without going
##   through `hsStopping`.
## - Receiving `heStopRequested` repeatedly while in `hsStopping` /
##   `hsStopped` does not error; it self-loops (multiple stop requests are
##   tolerated).
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
# Forward transitions
# ---------------------------------------------------------------------------

type
  ForwardEvent* = enum
    feHostConnected     ## the owning host became `hsConnected`
    feAttachStarted     ## `-O forward` in progress
    feAttachSucceeded   ## `-O forward` succeeded
    feAttachBindFailed  ## `Port forwarding failed` (caused by a leftover UDS)
    feAttachFailedOther ## attach failed for a reason other than bind failure
    feHealthFailed      ## health check failed
    feHealthRecovered   ## health check recovered
    feHostLost          ## the owning host left `hsConnected`
    feDetachRequested   ## an explicit detach request
    feDetachConfirmed   ## confirmed the process-side release after `-O cancel`
    feDegradeLimitReached ## sustained degradation reached the forced re-attach threshold

## Forward transition table
## ==========================
##
## `feHostLost` and `feDetachRequested` are valid from **any state** (applied
## before, and with priority over, the table's other cells).
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
## (`*` marks transitions reached via the "from any state" rule)
##
## Design notes:
## - `feHealthFailed` / `feHealthRecovered` self-loop, since "a single event
##   alone cannot cross the `degradeThreshold` / `reattachThreshold`". Use
##   `healthVerdict` for the actual threshold judgment (the daemon layer's
##   health-check loop is expected to mainly use `healthVerdict` rather than
##   `nextForwardState`). The one exception is `fwDegraded`'s
##   `feHealthRecovered`, which, per the reference design, does revert to
##   `fwActive` on a single event.
## - `feAttachBindFailed` is designed to "unlink and retry exactly once", but
##   counting that retry is the daemon layer's responsibility. A second or
##   later bind failure must be passed as `feAttachFailedOther` rather than
##   `feAttachBindFailed`, dropping it into `fwError`.
## - Since `ForwardState` has no value corresponding to "discarded", the case
##   where `fwDetaching` receives `feDetachConfirmed` returns `none`. This
##   needs to be distinguished from the `none` of an "invalid transition",
##   which is why `isDiscard` is provided for that judgment.
## - Receiving `feHostLost` while in `fwDetaching` still reverts plainly to
##   `fwPending` (faithfully applying the reference design's "any state"
##   rule). If the daemon layer is implemented to remove the target from
##   management the moment it issues `feDetachRequested`, this case is
##   expected to essentially never occur.
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
  ## A helper to distinguish, when `nextForwardState` returns `none`, whether
  ## that is an "invalid transition" or the case of "`fwDetaching` receiving
  ## `feDetachConfirmed` and being normally discarded". The caller should
  ## check this first: if true, discard the Forward record itself; if false,
  ## leave it in the log as an invalid transition.
  state == fwDetaching and event == feDetachConfirmed

# ---------------------------------------------------------------------------
# Health-check threshold judgment
# ---------------------------------------------------------------------------

const
  degradeThreshold* = 3
    ## 3 consecutive failures moves `fwActive` -> `fwDegraded`
  reattachThreshold* = 9
    ## further continued failures force a re-attach (3x `degradeThreshold`)

proc healthVerdict*(consecutiveFailures: int;
    current: ForwardState): ForwardState =
  ## From the health check's consecutive failure count
  ## `consecutiveFailures`, judges in one pass the transition between
  ## `fwActive` / `fwDegraded`, as well as the forced re-attach (falling back
  ## to `fwPending`).
  ##
  ## - `consecutiveFailures == 0`: healthy -> `fwActive`
  ## - `degradeThreshold` or more: degraded -> `fwDegraded`
  ## - `reattachThreshold` or more: forced re-attach -> `fwPending`
  ##
  ## If `current` is something other than `fwActive` / `fwDegraded` (i.e.
  ## `fwPending` / `fwAttaching` / `fwDetaching` / `fwError`), it's a state
  ## outside the scope of health checking, so `current` is returned as-is
  ## (no-op).
  if current != fwActive and current != fwDegraded:
    return current
  if consecutiveFailures >= reattachThreshold:
    fwPending
  elif consecutiveFailures >= degradeThreshold:
    fwDegraded
  else:
    fwActive
