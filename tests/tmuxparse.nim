import std/unittest
import powarder/core/muxparse

# ---------------------------------------------------------------------------
# 実測データ（2026-07-29, OpenSSH_10.2p1 / macOS）をそのままテストケースにする。
# これがこのモジュールの存在意義なので、値は一字一句変えないこと。
# ---------------------------------------------------------------------------

suite "parseForwardResult: 実測データ":

  test "成功":
    check parseForwardResult(0, "", "") == moSuccess

  test "既存の同一 forward への再送は冪等成功する":
    # stdout/stderr ともに空、exitCode 0 のみで新規 bind と区別が付かないのが実測の意味論。
    check parseForwardResult(0, "", "") == moSuccess

  test "本当の bind 失敗":
    check parseForwardResult(255, "",
        "mux_client_forward: forwarding request failed: Port forwarding failed\n" &
        "muxclient: master forward request failed\n") == moBindFailed

suite "parseForwardResult: 未実測だがソースから確実な系":

  test "制御ソケットに繋がらない (ENOENT)":
    check parseForwardResult(255, "",
        "Control socket connect(/tmp/x.sock): No such file or directory\n") == moNoMaster

  test "制御ソケットに繋がらない (ECONNREFUSED)":
    check parseForwardResult(255, "",
        "Control socket connect(/tmp/x.sock): Connection refused\n") == moNoMaster

  test "ポリシー拒否":
    check parseForwardResult(255, "",
        "Master refused forwarding request: administratively prohibited\n") == moRefused

  test "-L 構文エラー":
    check parseForwardResult(255, "",
        "Bad local forwarding specification '0:localhost:22'\n") == moBadSpec

  test "-R 構文エラーも moBadSpec になる（局所性の確認）":
    check parseForwardResult(255, "",
        "Bad remote forwarding specification '0:localhost:22'\n") == moBadSpec

  test "分類不能な失敗は moUnknownFailure":
    check parseForwardResult(255, "", "something unexpected happened\n") == moUnknownFailure

  test "優先順位: moNoMaster はどの文言より優先される":
    # 実際には同時に出ないはずだが、フェイルセーフとしての優先順位を確認する。
    check parseForwardResult(255, "",
        "Control socket connect(/tmp/x.sock): No such file or directory\n" &
        "Port forwarding failed\n") == moNoMaster

suite "parseCancelResult: 実測データ":

  test "成功":
    check parseCancelResult(0, "", "") == moSuccess

  test "対象が存在しない":
    check parseCancelResult(0, "",
        "mux_client_forward: forwarding request failed: port not forwarded\n" &
        "muxclient: master cancel forward request failed\n") == moNotForwarded

suite "parseCancelResult: exitCode は無視される（実測で確定）":

  test "exitCode が 255 でも stderr が空なら moSuccess":
    check parseCancelResult(255, "", "") == moSuccess

  test "exitCode が 0 でも stderr の内容次第で失敗判定になる":
    check parseCancelResult(0, "",
        "mux_client_forward: forwarding request failed: port not forwarded\n") == moNotForwarded

suite "parseCancelResult: 未実測だがソースから確実な系":

  test "制御ソケットに繋がらない":
    check parseCancelResult(0, "",
        "Control socket connect(/tmp/x.sock): Connection refused\n") == moNoMaster

  test "ポリシー拒否":
    check parseCancelResult(0, "",
        "Master refused forwarding request: administratively prohibited\n") == moRefused

  test "分類不能な非空 stderr は moUnknownFailure":
    check parseCancelResult(0, "", "something unexpected happened\n") == moUnknownFailure

  test "空白のみの stderr も成功扱い":
    check parseCancelResult(0, "", "   \n\t \n") == moSuccess

suite "parseCheckResult: 実測データ":

  test "マスター生存":
    check parseCheckResult(0, "", "Master running (pid=48916)\r\n") ==
      (alive: true, pid: 48916)

suite "parseCheckResult: stdout ではなく stderr を見る":

  test "stdout に同じ文言があっても無視する（実測: stderr のみに出る）":
    check parseCheckResult(0, "Master running (pid=1)\r\n", "") == (
        alive: false, pid: 0)

suite "parseCheckResult: pid が取れない場合":

  test "Master running (pid= の文言が無ければ alive false":
    check parseCheckResult(255, "",
        "Control socket connect(/tmp/x.sock): No such file or directory\n") ==
      (alive: false, pid: 0)

  test "pid の直後が数字でなければ pid 0 で alive false":
    check parseCheckResult(0, "", "Master running (pid=)\r\n") == (alive: false, pid: 0)
