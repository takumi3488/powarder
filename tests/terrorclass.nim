import std/unittest
import std/strutils
import std/sequtils
import powarder/core/errorclass

suite "classify: ekPortInUse":

  test "bind: Address already in use":
    check classify("bind [127.0.0.1]:8080: Address already in use\n") == ekPortInUse

suite "classify: ekAuthFailed":

  test "Permission denied (publickey":
    check classify("user@host: Permission denied (publickey).\n") == ekAuthFailed

  test "Permission denied (password":
    check classify("user@host: Permission denied (password).\n") == ekAuthFailed

  test "Too many authentication failures":
    check classify(
        "Received disconnect from 203.0.113.5 port 22:2: Too many authentication failures\n") ==
      ekAuthFailed

suite "classify: ekGatewayPortsDisabled":

  test "Warning: remote port forwarding failed for listen port":
    check classify("Warning: remote port forwarding failed for listen port 8080\n") ==
      ekGatewayPortsDisabled

  test "Error 系 / listen path 系でも同じ分類になる":
    check classify("Error: remote port forwarding failed for listen path /tmp/x.sock\n") ==
      ekGatewayPortsDisabled

suite "classify: ekUnknownHost":

  test "Could not resolve hostname":
    check classify("ssh: Could not resolve hostname typo.example: Name or service not known\n") ==
      ekUnknownHost

  test "Name or service not known 単体":
    check classify("getaddrinfo failed: Name or service not known\n") == ekUnknownHost

  test "nodename nor servname provided (macOS/BSD)":
    check classify(
        "ssh: Could not resolve hostname typo.example: nodename nor servname provided, " &
        "or not known\n") == ekUnknownHost

suite "classify: ekConnectionRefused":

  test "Connection refused":
    check classify("ssh: connect to host 203.0.113.5 port 22: Connection refused\n") ==
      ekConnectionRefused

suite "classify: ekTimeout":

  test "Connection timed out (Linux)":
    check classify("ssh: connect to host 203.0.113.5 port 22: Connection timed out\n") ==
      ekTimeout

  test "Operation timed out (macOS/BSD)":
    check classify("ssh: connect to host 203.0.113.5 port 22: Operation timed out\n") ==
      ekTimeout

suite "classify: ekHostKeyChanged":

  test "REMOTE HOST IDENTIFICATION HAS CHANGED バナー":
    check classify(
        "@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@\n" &
        "@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @\n" &
        "@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@\n" &
        "Host key for example.com has changed and you have requested strict checking.\n" &
        "Host key verification failed.\n") == ekHostKeyChanged

  test "REVOKED HOST KEY DETECTED バナー":
    check classify(
        "@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@\n" &
        "@       WARNING: REVOKED HOST KEY DETECTED!               @\n" &
        "@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@\n" &
        "Host key verification failed.\n") == ekHostKeyChanged

  test "StrictHostKeyChecking=yes による明示的拒否（バナー無し）":
    check classify(
        "No ed25519 host key is known for example.com and you have requested " &
        "strict checking.\nHost key verification failed.\n") == ekHostKeyChanged

suite "classify: ekBatchModeNoAuth":

  test "Permission denied (publickey,keyboard-interactive)":
    check classify("user@host: Permission denied (publickey,keyboard-interactive).\n") ==
      ekBatchModeNoAuth

  test "Permission denied (publickey,password)":
    check classify("user@host: Permission denied (publickey,password).\n") ==
      ekBatchModeNoAuth

  test "Host key verification failed が単独（BatchMode が新規ホスト鍵の確認を潰した）":
    check classify("Host key verification failed.\n") == ekBatchModeNoAuth

suite "classify: ekForwardingDenied":

  test "administratively prohibited / open failed":
    check classify("channel 3: open failed: administratively prohibited: open failed\n") ==
      ekForwardingDenied

suite "classify: ekUnknown":

  test "分類不能な文言":
    check classify("something totally unexpected\n") == ekUnknown

suite "classify: 優先順位":

  test "ホスト鍵変更バナーは Permission denied より優先される":
    check classify(
        "@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @\n" &
        "Host key verification failed.\n" &
        "user@host: Permission denied (publickey).\n") == ekHostKeyChanged

  test "publickey,keyboard-interactive は素の publickey 判定より優先される":
    # msgPermDeniedPubkey ("Permission denied (publickey") も部分一致するが、
    # より具体的な msgPermDeniedPubkeyKbdInteractive を先にチェックするため
    # ekBatchModeNoAuth になる。
    check classify("user@host: Permission denied (publickey,keyboard-interactive).\n") ==
      ekBatchModeNoAuth

  test "最後の行ではなく最も具体的な原因を拾う":
    # 1行目は一般的な Permission denied だが、2行目により具体的な
    # BatchMode 由来のパターンがある場合、後者を優先する。
    check classify(
        "user@host: Permission denied (publickey,password).\n" &
        "some trailing unrelated log line\n") == ekBatchModeNoAuth

suite "explain: プレースホルダの埋め込み":

  test "ekPortInUse: bindPort が summary と hints の両方に入る":
    let ctx = initErrorContext(bindPort = 8080)
    let ex = explain(ekPortInUse, langJa, ctx)
    check "8080" in ex.summary
    check ex.hints.len > 0
    check ex.hints.anyIt("8080" in it)

  test "ekAuthFailed: host が埋め込まれる":
    let ctx = initErrorContext(host = "prod-db")
    let ex = explain(ekAuthFailed, langEn, ctx)
    check "prod-db" in ex.summary
    check ex.hints.anyIt("prod-db" in it)

  test "ekUnknown: 生の stderr がそのまま出る":
    let ctx = initErrorContext(rawStderr = "some very specific ssh error text")
    let ex = explain(ekUnknown, langEn, ctx)
    check ex.hints.anyIt("some very specific ssh error text" in it)

  test "langEn と langJa で異なる文言が返る":
    let ctx = initErrorContext(host = "prod-db")
    let exEn = explain(ekConnectionRefused, langEn, ctx)
    let exJa = explain(ekConnectionRefused, langJa, ctx)
    check exEn.summary != exJa.summary
