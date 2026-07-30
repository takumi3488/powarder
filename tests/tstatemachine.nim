## Unit tests for `powarder/core/statemachine`.
## Exhaustively checks every (state, event) combination: the expected
## transitions land where they should, and every other combination yields
## `none` (an invalid transition).

import std/[unittest, options]

import powarder/core/types
import powarder/core/statemachine

suite "nextBackoff":
  test "calling from the initial value 0 (or unset) returns 1":
    check nextBackoff(0.0) == 1.0
    check nextBackoff(-5.0) == 1.0

  test "doubles as 1 -> 2 -> 4 -> 8 -> 16 -> 30 (cap)":
    check nextBackoff(1.0) == 2.0
    check nextBackoff(2.0) == 4.0
    check nextBackoff(4.0) == 8.0
    check nextBackoff(8.0) == 16.0
    check nextBackoff(16.0) == 30.0

  test "stays capped once the limit is reached":
    check nextBackoff(30.0) == 30.0
    check nextBackoff(100.0) == 30.0

  test "specifying maxSeconds caps out at that value instead":
    check nextBackoff(1.0, maxSeconds = 5.0) == 2.0
    check nextBackoff(4.0, maxSeconds = 5.0) == 5.0
    check nextBackoff(5.0, maxSeconds = 5.0) == 5.0

suite "shouldGiveUp":
  test "always false when maxConsecutiveFailures == 0 (default: infinite retry)":
    let policy = initRetryPolicy()
    check policy.maxConsecutiveFailures == 0
    check not shouldGiveUp(0, policy)
    check not shouldGiveUp(1, policy)
    check not shouldGiveUp(1_000_000, policy)

  test "true once at or above the threshold when maxConsecutiveFailures > 0":
    let policy = initRetryPolicy(maxConsecutiveFailures = 3)
    check not shouldGiveUp(0, policy)
    check not shouldGiveUp(2, policy)
    check shouldGiveUp(3, policy)
    check shouldGiveUp(4, policy)

suite "nextHostState":
  ## The answer key of (current state, event, target state). Any
  ## (state, event) combination not listed here should yield `none`.
  const expected = [
    (hsIdle, hePreparedToConnect, hsConnecting),
    (hsIdle, heStopRequested, hsStopped),
    (hsConnecting, heCheckSucceeded, hsConnected),
    (hsConnecting, heMasterDied, hsReconnecting),
    (hsConnecting, heReadinessTimeout, hsReconnecting),
    (hsConnecting, heStopRequested, hsStopping),
    (hsConnected, heCheckSucceeded, hsConnected),
    (hsConnected, heMasterDied, hsReconnecting),
    (hsConnected, heIdleGraceExpired, hsStopping),
    (hsConnected, heStopRequested, hsStopping),
    (hsReconnecting, hePreparedToConnect, hsConnecting),
    (hsReconnecting, heRetryLimitReached, hsFailed),
    (hsReconnecting, heStopRequested, hsStopped),
    (hsStopping, heProcessReaped, hsStopped),
    (hsStopping, heStopRequested, hsStopping),
    (hsStopped, hePreparedToConnect, hsConnecting),
    (hsFailed, heRestartRequested, hsConnecting),
    (hsFailed, heStopRequested, hsStopped),
  ]

  proc expectedNext(s: HostSessionState; e: HostEvent): Option[
      HostSessionState] =
    for (es, ee, target) in expected:
      if es == s and ee == e:
        return some(target)
    none(HostSessionState)

  test "transitions happen exactly as the answer key says (explicit cases)":
    for (s, e, target) in expected:
      check nextHostState(s, e) == some(target)

  test "exhaustively checking every state x event, anything outside the answer key is none":
    var checkedCount = 0
    for s in HostSessionState:
      for e in HostEvent:
        check nextHostState(s, e) == expectedNext(s, e)
        inc checkedCount
    # confirms all 7 states x 9 events = 63 combinations were checked
    check checkedCount == 63

  test "heRestartRequested is only accepted from hsFailed":
    for s in HostSessionState:
      if s != hsFailed:
        check nextHostState(s, heRestartRequested).isNone

  test "heRetryLimitReached is only accepted from hsReconnecting":
    for s in HostSessionState:
      if s != hsReconnecting:
        check nextHostState(s, heRetryLimitReached).isNone

suite "nextForwardState":
  ## feHostLost / feDetachRequested are valid "from any state", so they're
  ## handled separately in the loop below. This is the answer key for the
  ## remaining (state, event) combinations.
  const expected = [
    (fwPending, feHostConnected, fwPending),
    (fwPending, feAttachStarted, fwAttaching),
    (fwAttaching, feAttachSucceeded, fwActive),
    (fwAttaching, feAttachBindFailed, fwPending),
    (fwAttaching, feAttachFailedOther, fwError),
    (fwActive, feHealthFailed, fwActive),
    (fwActive, feHealthRecovered, fwActive),
    (fwDegraded, feHealthFailed, fwDegraded),
    (fwDegraded, feHealthRecovered, fwActive),
    (fwDegraded, feDegradeLimitReached, fwPending),
  ]

  proc expectedNext(s: ForwardState; e: ForwardEvent): Option[ForwardState] =
    if e == feHostLost:
      return some(fwPending)
    if e == feDetachRequested:
      return some(fwDetaching)
    for (es, ee, target) in expected:
      if es == s and ee == e:
        return some(target)
    none(ForwardState)

  test "transitions happen exactly as the answer key says (explicit cases)":
    for (s, e, target) in expected:
      check nextForwardState(s, e) == some(target)

  test "feHostLost transitions to fwPending from any state":
    for s in ForwardState:
      check nextForwardState(s, feHostLost) == some(fwPending)

  test "feDetachRequested transitions to fwDetaching from any state":
    for s in ForwardState:
      check nextForwardState(s, feDetachRequested) == some(fwDetaching)

  test "fwDetaching receiving feDetachConfirmed is treated as discarded (none, but isDiscard is true)":
    check nextForwardState(fwDetaching, feDetachConfirmed).isNone
    check isDiscard(fwDetaching, feDetachConfirmed)

  test "exhaustively checking every state x event, anything outside the answer key / special case is none":
    var checkedCount = 0
    for s in ForwardState:
      for e in ForwardEvent:
        if s == fwDetaching and e == feDetachConfirmed:
          check nextForwardState(s, e).isNone
          check isDiscard(s, e)
        else:
          check nextForwardState(s, e) == expectedNext(s, e)
          if nextForwardState(s, e).isNone:
            check not isDiscard(s, e)
        inc checkedCount
    # confirms all 6 states x 11 events = 66 combinations were checked
    check checkedCount == 66

suite "healthVerdict":
  test "fwActive: stays fwActive below the threshold":
    check healthVerdict(0, fwActive) == fwActive
    check healthVerdict(1, fwActive) == fwActive
    check healthVerdict(2, fwActive) == fwActive

  test "fwActive: becomes fwDegraded at or above degradeThreshold":
    check degradeThreshold == 3
    check healthVerdict(3, fwActive) == fwDegraded
    check healthVerdict(8, fwActive) == fwDegraded

  test "fwActive/fwDegraded: forced to fwPending at or above reattachThreshold":
    check reattachThreshold == 9
    check healthVerdict(9, fwActive) == fwPending
    check healthVerdict(100, fwActive) == fwPending
    check healthVerdict(9, fwDegraded) == fwPending

  test "fwDegraded: recovers to fwActive once the count returns to 0":
    check healthVerdict(0, fwDegraded) == fwActive

  test "fwDegraded: stays fwDegraded between degradeThreshold and reattachThreshold":
    check healthVerdict(3, fwDegraded) == fwDegraded
    check healthVerdict(8, fwDegraded) == fwDegraded

  test "anything other than fwActive/fwDegraded is a no-op (returns current as-is)":
    check healthVerdict(100, fwPending) == fwPending
    check healthVerdict(100, fwAttaching) == fwAttaching
    check healthVerdict(100, fwDetaching) == fwDetaching
    check healthVerdict(100, fwError) == fwError
