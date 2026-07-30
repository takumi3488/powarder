import std/unittest
import powarder/core/muxparse

# ---------------------------------------------------------------------------
# Empirically captured data (2026-07-29, OpenSSH_10.2p1 / macOS) used directly
# as test cases. This is the whole reason this module exists, so do not
# change the values by even a single character.
# ---------------------------------------------------------------------------

suite "parseForwardResult: empirically captured data":

  test "success":
    check parseForwardResult(0, "", "") == moSuccess

  test "resending an identical existing forward succeeds idempotently":
    # Both stdout/stderr are empty and exitCode is 0 alone, which is
    # empirically indistinguishable from a fresh bind -- that's the observed
    # semantics.
    check parseForwardResult(0, "", "") == moSuccess

  test "an actual bind failure":
    check parseForwardResult(255, "",
        "mux_client_forward: forwarding request failed: Port forwarding failed\n" &
        "muxclient: master forward request failed\n") == moBindFailed

suite "parseForwardResult: not empirically captured, but certain from the source":

  test "cannot connect to the control socket (ENOENT)":
    check parseForwardResult(255, "",
        "Control socket connect(/tmp/x.sock): No such file or directory\n") == moNoMaster

  test "cannot connect to the control socket (ECONNREFUSED)":
    check parseForwardResult(255, "",
        "Control socket connect(/tmp/x.sock): Connection refused\n") == moNoMaster

  test "policy rejection":
    check parseForwardResult(255, "",
        "Master refused forwarding request: administratively prohibited\n") == moRefused

  test "-L syntax error":
    check parseForwardResult(255, "",
        "Bad local forwarding specification '0:localhost:22'\n") == moBadSpec

  test "-R syntax error also becomes moBadSpec (confirms it's not special-cased)":
    check parseForwardResult(255, "",
        "Bad remote forwarding specification '0:localhost:22'\n") == moBadSpec

  test "an unclassifiable failure is moUnknownFailure":
    check parseForwardResult(255, "", "something unexpected happened\n") == moUnknownFailure

  test "priority: moNoMaster takes priority over any other wording":
    # In practice these shouldn't appear together, but this confirms the
    # priority order as a fail-safe.
    check parseForwardResult(255, "",
        "Control socket connect(/tmp/x.sock): No such file or directory\n" &
        "Port forwarding failed\n") == moNoMaster

suite "parseCancelResult: empirically captured data":

  test "success":
    check parseCancelResult(0, "", "") == moSuccess

  test "the target doesn't exist":
    check parseCancelResult(0, "",
        "mux_client_forward: forwarding request failed: port not forwarded\n" &
        "muxclient: master cancel forward request failed\n") == moNotForwarded

suite "parseCancelResult: exitCode is ignored (confirmed empirically)":

  test "exitCode 255 with empty stderr is still moSuccess":
    check parseCancelResult(255, "", "") == moSuccess

  test "exitCode 0 can still be a failure, depending on stderr's content":
    check parseCancelResult(0, "",
        "mux_client_forward: forwarding request failed: port not forwarded\n") == moNotForwarded

suite "parseCancelResult: not empirically captured, but certain from the source":

  test "cannot connect to the control socket":
    check parseCancelResult(0, "",
        "Control socket connect(/tmp/x.sock): Connection refused\n") == moNoMaster

  test "policy rejection":
    check parseCancelResult(0, "",
        "Master refused forwarding request: administratively prohibited\n") == moRefused

  test "an unclassifiable non-empty stderr is moUnknownFailure":
    check parseCancelResult(0, "", "something unexpected happened\n") == moUnknownFailure

  test "whitespace-only stderr also counts as success":
    check parseCancelResult(0, "", "   \n\t \n") == moSuccess

suite "parseCheckResult: empirically captured data":

  test "master is alive":
    check parseCheckResult(0, "", "Master running (pid=48916)\r\n") ==
      (alive: true, pid: 48916)

suite "parseCheckResult: looks at stderr, not stdout":

  test "the same wording on stdout is ignored (empirically: it only appears on stderr)":
    check parseCheckResult(0, "Master running (pid=1)\r\n", "") == (
        alive: false, pid: 0)

suite "parseCheckResult: when the pid can't be extracted":

  test "alive is false when there's no \"Master running (pid=\" wording":
    check parseCheckResult(255, "",
        "Control socket connect(/tmp/x.sock): No such file or directory\n") ==
      (alive: false, pid: 0)

  test "if what follows pid= isn't a digit, pid is 0 and alive is false":
    check parseCheckResult(0, "", "Master running (pid=)\r\n") == (alive: false, pid: 0)
