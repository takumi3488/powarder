## `powarder/core/statemachine` のユニットテスト。
## 全状態 x 全イベントの組み合わせを総当たりし、期待される遷移先と、
## それ以外の組み合わせが `none`（不正な遷移）になることを確認する。

import std/[unittest, options]

import powarder/core/types
import powarder/core/statemachine

suite "nextBackoff":
  test "初期値 0 または未設定から呼ぶと 1 を返す":
    check nextBackoff(0.0) == 1.0
    check nextBackoff(-5.0) == 1.0

  test "1 → 2 → 4 → 8 → 16 → 30(上限) と倍々に増える":
    check nextBackoff(1.0) == 2.0
    check nextBackoff(2.0) == 4.0
    check nextBackoff(4.0) == 8.0
    check nextBackoff(8.0) == 16.0
    check nextBackoff(16.0) == 30.0

  test "上限に達したあとは頭打ちのまま":
    check nextBackoff(30.0) == 30.0
    check nextBackoff(100.0) == 30.0

  test "maxSeconds を指定するとその値で頭打ちになる":
    check nextBackoff(1.0, maxSeconds = 5.0) == 2.0
    check nextBackoff(4.0, maxSeconds = 5.0) == 5.0
    check nextBackoff(5.0, maxSeconds = 5.0) == 5.0

suite "shouldGiveUp":
  test "maxConsecutiveFailures == 0 なら常に false（既定は無限リトライ）":
    let policy = initRetryPolicy()
    check policy.maxConsecutiveFailures == 0
    check not shouldGiveUp(0, policy)
    check not shouldGiveUp(1, policy)
    check not shouldGiveUp(1_000_000, policy)

  test "maxConsecutiveFailures > 0 なら閾値以上で true":
    let policy = initRetryPolicy(maxConsecutiveFailures = 3)
    check not shouldGiveUp(0, policy)
    check not shouldGiveUp(2, policy)
    check shouldGiveUp(3, policy)
    check shouldGiveUp(4, policy)

suite "nextHostState":
  ## (現在状態, イベント, 遷移先) の正解表。ここに載っていない
  ## (状態, イベント) の組み合わせはすべて `none` になるべき。
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

  test "正解表どおりの遷移が起きる（明示ケース）":
    for (s, e, target) in expected:
      check nextHostState(s, e) == some(target)

  test "全状態 x 全イベントを総当たりし、正解表以外は none になる":
    var checkedCount = 0
    for s in HostSessionState:
      for e in HostEvent:
        check nextHostState(s, e) == expectedNext(s, e)
        inc checkedCount
    # 7 状態 x 9 イベント = 63 通りをすべて検証したことを保証する
    check checkedCount == 63

  test "heRestartRequested は hsFailed 以外からは受け付けない":
    for s in HostSessionState:
      if s != hsFailed:
        check nextHostState(s, heRestartRequested).isNone

  test "heRetryLimitReached は hsReconnecting 以外からは受け付けない":
    for s in HostSessionState:
      if s != hsReconnecting:
        check nextHostState(s, heRetryLimitReached).isNone

suite "nextForwardState":
  ## feHostLost / feDetachRequested は「任意の状態から」有効なため
  ## ループ内で個別に扱う。それ以外の (状態, イベント) の正解表。
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

  test "正解表どおりの遷移が起きる（明示ケース）":
    for (s, e, target) in expected:
      check nextForwardState(s, e) == some(target)

  test "feHostLost はどの状態からでも fwPending へ遷移する":
    for s in ForwardState:
      check nextForwardState(s, feHostLost) == some(fwPending)

  test "feDetachRequested はどの状態からでも fwDetaching へ遷移する":
    for s in ForwardState:
      check nextForwardState(s, feDetachRequested) == some(fwDetaching)

  test "fwDetaching が feDetachConfirmed を受けると破棄扱い（none だが isDiscard は true）":
    check nextForwardState(fwDetaching, feDetachConfirmed).isNone
    check isDiscard(fwDetaching, feDetachConfirmed)

  test "全状態 x 全イベントを総当たりし、正解表・特殊ケース以外は none になる":
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
    # 6 状態 x 11 イベント = 66 通りをすべて検証したことを保証する
    check checkedCount == 66

suite "healthVerdict":
  test "fwActive: 閾値未満なら fwActive のまま":
    check healthVerdict(0, fwActive) == fwActive
    check healthVerdict(1, fwActive) == fwActive
    check healthVerdict(2, fwActive) == fwActive

  test "fwActive: degradeThreshold 以上で fwDegraded":
    check degradeThreshold == 3
    check healthVerdict(3, fwActive) == fwDegraded
    check healthVerdict(8, fwActive) == fwDegraded

  test "fwActive/fwDegraded: reattachThreshold 以上で強制 fwPending":
    check reattachThreshold == 9
    check healthVerdict(9, fwActive) == fwPending
    check healthVerdict(100, fwActive) == fwPending
    check healthVerdict(9, fwDegraded) == fwPending

  test "fwDegraded: 0 回に戻れば回復して fwActive":
    check healthVerdict(0, fwDegraded) == fwActive

  test "fwDegraded: degradeThreshold 以上 reattachThreshold 未満は fwDegraded 継続":
    check healthVerdict(3, fwDegraded) == fwDegraded
    check healthVerdict(8, fwDegraded) == fwDegraded

  test "fwActive/fwDegraded 以外は no-op（current をそのまま返す）":
    check healthVerdict(100, fwPending) == fwPending
    check healthVerdict(100, fwAttaching) == fwAttaching
    check healthVerdict(100, fwDetaching) == fwDetaching
    check healthVerdict(100, fwError) == fwError
