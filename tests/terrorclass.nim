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

  test "Error-style / listen-path-style also classify the same":
    check classify("Error: remote port forwarding failed for listen path /tmp/x.sock\n") ==
      ekGatewayPortsDisabled

suite "classify: ekUnknownHost":

  test "Could not resolve hostname":
    check classify("ssh: Could not resolve hostname typo.example: Name or service not known\n") ==
      ekUnknownHost

  test "Name or service not known alone":
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

  test "REMOTE HOST IDENTIFICATION HAS CHANGED banner":
    check classify(
        "@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@\n" &
        "@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @\n" &
        "@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@\n" &
        "Host key for example.com has changed and you have requested strict checking.\n" &
        "Host key verification failed.\n") == ekHostKeyChanged

  test "REVOKED HOST KEY DETECTED banner":
    check classify(
        "@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@\n" &
        "@       WARNING: REVOKED HOST KEY DETECTED!               @\n" &
        "@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@\n" &
        "Host key verification failed.\n") == ekHostKeyChanged

  test "StrictHostKeyChecking=yes explicit rejection (no banner)":
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

  test "Host key verification failed alone (BatchMode swallowed the new host key confirmation)":
    check classify("Host key verification failed.\n") == ekBatchModeNoAuth

suite "classify: ekForwardingDenied":

  test "administratively prohibited / open failed":
    check classify("channel 3: open failed: administratively prohibited: open failed\n") ==
      ekForwardingDenied

suite "classify: ekUnknown":

  test "Unclassifiable text":
    check classify("something totally unexpected\n") == ekUnknown

suite "classify: priority order":

  test "Host key change banner takes priority over Permission denied":
    check classify(
        "@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @\n" &
        "Host key verification failed.\n" &
        "user@host: Permission denied (publickey).\n") == ekHostKeyChanged

  test "publickey,keyboard-interactive takes priority over the plain publickey match":
    # msgPermDeniedPubkey ("Permission denied (publickey") also partially
    # matches, but the more specific msgPermDeniedPubkeyKbdInteractive is
    # checked first, so the result is ekBatchModeNoAuth.
    check classify("user@host: Permission denied (publickey,keyboard-interactive).\n") ==
      ekBatchModeNoAuth

  test "Picks the most specific cause, not just the last line":
    # The first line is a plain Permission denied, but when the second line
    # has a more specific BatchMode-derived pattern, that one takes priority.
    check classify(
        "user@host: Permission denied (publickey,password).\n" &
        "some trailing unrelated log line\n") == ekBatchModeNoAuth

suite "explain: placeholder embedding":

  test "ekPortInUse: bindPort appears in both summary and hints":
    let ctx = initErrorContext(bindPort = 8080)
    let ex = explain(ekPortInUse, langJa, ctx)
    check "8080" in ex.summary
    check ex.hints.len > 0
    check ex.hints.anyIt("8080" in it)

  test "ekAuthFailed: host is embedded":
    let ctx = initErrorContext(host = "prod-db")
    let ex = explain(ekAuthFailed, langEn, ctx)
    check "prod-db" in ex.summary
    check ex.hints.anyIt("prod-db" in it)

  test "ekUnknown: the raw stderr passes through unchanged":
    let ctx = initErrorContext(rawStderr = "some very specific ssh error text")
    let ex = explain(ekUnknown, langEn, ctx)
    check ex.hints.anyIt("some very specific ssh error text" in it)

  test "langEn and langJa now return identical text (Japanese wording was removed from the source)":
    # errorclass.nim's `templates` table now holds the same English text in
    # both its langEn and langJa columns, since the Japanese wording was
    # removed. This documents that behavioral change rather than asserting
    # the old (no longer true) "they differ" expectation.
    let ctx = initErrorContext(host = "prod-db")
    let exEn = explain(ekConnectionRefused, langEn, ctx)
    let exJa = explain(ekConnectionRefused, langJa, ctx)
    check exEn.summary == exJa.summary
