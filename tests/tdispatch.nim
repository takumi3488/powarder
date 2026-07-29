## `powarder/cli/dispatch` とその周辺（`names` / `autostart` / `cmd_completion`）のテスト。
##
## デーモンを実際に起動せずにテストできる範囲を最大化する方針:
## - テーブル整形・ログ tail の増分読みは「文字列を組み立てる純粋関数」
##   （`renderPsTable` / `renderHostsTable` / `tailLines` / `readIncrement`）を
##   直接呼んでテストする。
## - `dispatch` 自体の実行は、デーモンに絶対到達できない
##   （`POWARDER_RUNTIME_DIR` を隔離した上でソケットが存在しない）状況を作り、
##   `--no-autostart` で終了コード 7 になることだけを確認する。
##   実際にデーモンを自動起動させるテストは実行ファイルが要るため行わない
##   （報告参照）。

import std/unittest
import std/os
import std/json
import std/strutils
import std/times
import powarder/cli/dispatch
import powarder/cli/argv
import powarder/cli/output
import powarder/cli/names
import powarder/cli/cmd_completion
import powarder/core/paths
import powarder/core/fmt
import powarder/ipc/protocol

proc withEnv(pairs: openArray[(string, string)], body: proc()) =
  ## 環境変数を一時的に差し替える（`tests/tpaths.nim` / `tests/tcli.nim` の
  ## ヘルパーを踏襲）。
  var saved: seq[(string, bool, string)]
  for (k, v) in pairs:
    saved.add (k, existsEnv(k), getEnv(k))
    putEnv(k, v)
  try:
    body()
  finally:
    for (k, existed, old) in saved:
      if existed: putEnv(k, old) else: delEnv(k)

proc mkRow(name, typ, bindAddr, target, host, state, status: string;
    conns, totalConns, rx, tx, lastActivity, uptime: JsonNode): JsonNode =
  result = newJObject()
  result["name"] = %name
  result["type"] = %typ
  result["bind"] = %bindAddr
  result["target"] = %target
  result["host"] = %host
  result["state"] = %state
  result["status"] = %status
  result["conns"] = conns
  result["total_conns"] = totalConns
  result["rx"] = rx
  result["tx"] = tx
  result["last_activity_seconds"] = lastActivity
  result["uptime_seconds"] = uptime
  result["last_error"] = newJNull()

# ===========================================================================
# names.randomName
# ===========================================================================

suite "names: randomName(seed)":
  test "同じ seed からは常に同じ名前になる":
    check randomName(1) == randomName(1)
    check randomName(42) == randomName(42)

  test "「形容詞-名詞」形式（小文字英字とハイフンのみ）":
    let n = randomName(7)
    let parts = n.split('-')
    check parts.len == 2
    for p in parts:
      check p.len > 0
      for c in p:
        check c in {'a' .. 'z'}

  test "seed を変えれば違う名前になりうる":
    let first = randomName(0)
    var sawDifferent = false
    for s in 1 .. 30:
      if randomName(s) != first:
        sawDifferent = true
        break
    check sawDifferent

# ===========================================================================
# cmd_completion.completionScript
# ===========================================================================

suite "cmd_completion: completionScript":
  test "zsh は #compdef powarder で始まり、主要サブコマンド・daemon のサブサブコマンドを含む":
    let s = completionScript("zsh")
    check s.startsWith("#compdef powarder")
    check "run" in s
    check "daemon" in s
    check "completion" in s
    check "status" in s ## daemon status
    check "install" in s ## daemon install

  test "bash / fish は簡易版でもサブコマンド名を含む":
    check "run" in completionScript("bash")
    check "daemon" in completionScript("bash")
    check "run" in completionScript("fish")
    check "daemon" in completionScript("fish")

  test "未知のシェルは例外":
    expect ValueError:
      discard completionScript("powershell")

# ===========================================================================
# dispatch.exitCodeForRpcError: RpcRemoteError.code -> 終了コードの全パターン
# ===========================================================================

suite "dispatch: exitCodeForRpcError":
  test "errTunnelNotFound -> ecNotFound (4)":
    check exitCodeForRpcError(errTunnelNotFound) == ecNotFound
    check ecNotFound.int == 4

  test "errTunnelNameConflict -> ecConflict (5)":
    check exitCodeForRpcError(errTunnelNameConflict) == ecConflict
    check ecConflict.int == 5

  test "errSshFailed -> ecSshFailed (6)":
    check exitCodeForRpcError(errSshFailed) == ecSshFailed
    check ecSshFailed.int == 6

  test "errConfigInvalid -> ecConfig (3)":
    check exitCodeForRpcError(errConfigInvalid) == ecConfig
    check ecConfig.int == 3

  test "その他のコードは ecGeneral (1) にフォールバックする":
    check exitCodeForRpcError(errHostNotFound) == ecGeneral
    check exitCodeForRpcError(errForwardBindFailed) == ecGeneral
    check exitCodeForRpcError(-99999) == ecGeneral
    check ecGeneral.int == 1

# ===========================================================================
# dispatch.renderPsTable: tunnel.list のモック JSON -> テーブル文字列
# ===========================================================================

suite "dispatch: renderPsTable":
  test "-L 行は統計が出て、-R 行は統計列が '-' になる":
    let w = newWriter(noColor = true)

    let localRow = mkRow("prod-db", "L", "127.0.0.1:15432", "db.internal:5432",
        "prod-bastion", "fwActive", "healthy",
        %3, %128, %47398912, %12687360, %2, %11528)
    let remoteRow = mkRow("webhook", "R", "0.0.0.0:8443", "localhost:3000",
        "dev-box", "fwActive", "up",
        newJNull(), newJNull(), newJNull(), newJNull(), newJNull(), %3900)

    var rows = newJArray()
    rows.add localRow
    rows.add remoteRow

    let rendered = renderPsTable(rows, w)
    let lines = rendered.splitLines()
    check lines.len == 3
    check lines[0].splitWhitespace() == @["NAME", "TYPE", "BIND", "TARGET",
        "HOST", "CONNS", "RX/TX", "LAST", "UPTIME", "STATUS"]

    let expectedLocal = @["prod-db", "-L", "127.0.0.1:15432",
        "db.internal:5432", "prod-bastion", "3",
        formatBytes(47398912'u64) & "/" & formatBytes(12687360'u64),
        formatAgo(initDuration(seconds = 2)),
        formatDuration(initDuration(seconds = 11528)), "healthy"]
    check lines[1].splitWhitespace() == expectedLocal

    let expectedRemote = @["webhook", "-R", "0.0.0.0:8443", "localhost:3000",
        "dev-box", "-", "-", "-",
        formatDuration(initDuration(seconds = 3900)), "up"]
    check lines[2].splitWhitespace() == expectedRemote
    # -R の行では原理的に取れない統計列が "-" になっていること（最重要ポイント）
    check expectedRemote[5] == "-" ## CONNS
    check expectedRemote[6] == "-" ## RX/TX
    check expectedRemote[7] == "-" ## LAST

  test "行が無くてもヘッダだけは出る":
    let w = newWriter(noColor = true)
    let rendered = renderPsTable(newJArray(), w)
    check rendered.splitLines().len == 1
    check rendered.splitWhitespace() == @["NAME", "TYPE", "BIND", "TARGET",
        "HOST", "CONNS", "RX/TX", "LAST", "UPTIME", "STATUS"]

# ===========================================================================
# dispatch.renderHostsTable
# ===========================================================================

suite "dispatch: renderHostsTable":
  test "host.list のモック JSON をテーブルに整形できる":
    let w = newWriter(noColor = true)
    var row = newJObject()
    row["host"] = %"prod-bastion"
    row["fingerprint"] = %"5f675d2b"
    row["state"] = %"hsConnected"
    row["tunnels"] = %2
    row["pid"] = %41213
    row["uptime_seconds"] = %11528
    row["retries"] = %0
    row["last_error"] = newJNull()
    row["ctl_path"] = %"/some/path"
    var rows = newJArray()
    rows.add row

    let rendered = renderHostsTable(rows, w)
    let lines = rendered.splitLines()
    check lines.len == 2
    check lines[0].splitWhitespace() == @["HOST", "STATE", "TUNNELS", "PID",
        "UPTIME", "RETRIES"]
    check lines[1].splitWhitespace() == @["prod-bastion", "hsConnected", "2",
        "41213", formatDuration(initDuration(seconds = 11528)), "0"]

# ===========================================================================
# dispatch.tailLines
# ===========================================================================

suite "dispatch: tailLines":
  test "末尾 n 行を返す":
    let path = "/tmp/pw-dtail-1.log"
    removeFile(path)
    writeFile(path, "a\nb\nc\nd\ne\n")
    check tailLines(path, 3) == @["c", "d", "e"]
    check tailLines(path, 100) == @["a", "b", "c", "d", "e"]
    removeFile(path)

  test "ファイルが無ければ空 seq":
    let path = "/tmp/pw-dtail-nonexist.log"
    removeFile(path)
    check tailLines(path, 10) == newSeq[string]()

  test "末尾に改行が無くても最後の行を落とさない":
    let path = "/tmp/pw-dtail-2.log"
    removeFile(path)
    writeFile(path, "a\nb\nc")
    check tailLines(path, 2) == @["b", "c"]
    removeFile(path)

# ===========================================================================
# dispatch.readIncrement: logs -f の増分読み取り
# ===========================================================================

suite "dispatch: readIncrement":
  test "初回は offset 0 から全部読める":
    let path = "/tmp/pw-dincr-1.log"
    removeFile(path)
    writeFile(path, "hello\n")
    let (data, off) = readIncrement(path, 0)
    check data == "hello\n"
    check off == 6
    removeFile(path)

  test "追記分だけを増分として読める":
    let path = "/tmp/pw-dincr-2.log"
    removeFile(path)
    writeFile(path, "line1\n")
    let (_, off1) = readIncrement(path, 0)
    let f = open(path, fmAppend)
    f.write("line2\n")
    f.close()
    let (data2, off2) = readIncrement(path, off1)
    check data2 == "line2\n"
    check off2 == off1 + 6
    removeFile(path)

  test "truncate（ローテーション）されたら先頭から読み直す":
    let path = "/tmp/pw-dincr-3.log"
    removeFile(path)
    writeFile(path, "aaaaaaaaaa\n") # 11 バイト
    let (_, off1) = readIncrement(path, 0)
    check off1 == 11
    writeFile(path, "new\n") # ローテーション後の短い新しい内容
    let (data2, off2) = readIncrement(path, off1)
    check data2 == "new\n"
    check off2 == 4
    removeFile(path)

  test "ファイルが存在しない場合は増分無しで offset をそのまま返す":
    let path = "/tmp/pw-dincr-nonexist.log"
    removeFile(path)
    let (data, off) = readIncrement(path, 42)
    check data == ""
    check off == 42

# ===========================================================================
# dispatch: daemon --foreground（DaemonRunner の依存性注入）
# ===========================================================================
# `daemon/run.nim` を import しなくてもテストできる部分。ダミーの
# `DaemonRunner` を渡して、正しくそこへ委譲されることだけを確認する。
# IPC も daemon プロセスも一切必要ない。

suite "dispatch: daemon --foreground (DaemonRunner 注入)":
  test "subsubcommand が空なら runDaemon() の戻り値がそのまま返る":
    let args = ParsedArgs(subcommand: "daemon", subsubcommand: "", tailLines: 50)
    let fakeRunDaemon: DaemonRunner = proc (): int = 42
    check dispatch(args, fakeRunDaemon) == 42

  test "runDaemon が nil なら ecGeneral (1)":
    let args = ParsedArgs(subcommand: "daemon", subsubcommand: "", tailLines: 50)
    check dispatch(args) == ecGeneral.int

# ===========================================================================
# dispatch: daemon install / uninstall は M7 で実装済み（`platform/service`）
# ===========================================================================
# **ここでは `dispatch(args)` に subsubcommand "install"/"uninstall" を
# 実際に流すテストは書かない。** `installService()` / `uninstallService()` は
# 本物の `launchctl` / `systemctl` を呼び、実ファイル
# （`~/Library/LaunchAgents/...` / `~/.config/systemd/user/...`）を書き出す
# 副作用があるため、ここで呼ぶとテスト実行環境（開発者の実マシン）に
# 実際に LaunchAgent/systemd unit が登録されてしまう（しかもテストバイナリ
# 自身のパスが登録されるという最悪の事故になりうる）。
#
# `installService` / `uninstallService` が内部で使う純粋関数
# （`renderUnitFile` / `unitFilePath` / `serviceLabel` / `lingerNote`）は
# `tests/tservice.nim` で `platform/service_darwin` / `platform/service_linux`
# を直接 import して検証している（そちらも実際の `launchctl` / `systemctl` は
# 呼ばない）。手動での実機検証手順は M7 の報告に記載する。

# ===========================================================================
# dispatch.prunableNames: tunnel.list のモック JSON -> 削除対象の名前
# ===========================================================================

suite "dispatch: prunableNames":
  test "status == \"stopped\" の行だけを集める":
    let stoppedRow = mkRow("idle-tunnel", "L", "127.0.0.1:1", "x:1", "h",
        "fwPending", "stopped", newJNull(), newJNull(), newJNull(),
        newJNull(), newJNull(), newJNull())
    let activeRow = mkRow("busy-tunnel", "L", "127.0.0.1:2", "x:2", "h",
        "fwActive", "healthy", %0, %0, %0, %0, newJNull(), %10)
    var rows = newJArray()
    rows.add stoppedRow
    rows.add activeRow
    check prunableNames(rows) == @["idle-tunnel"]

  test "空配列を渡すと空配列が返る":
    check prunableNames(newJArray()) == newSeq[string]()

  test "全行 stopped なら全部集める":
    let a = mkRow("a", "L", "1", "2", "h", "fwPending", "stopped",
        newJNull(), newJNull(), newJNull(), newJNull(), newJNull(), newJNull())
    let b = mkRow("b", "R", "1", "2", "h", "fwPending", "stopped",
        newJNull(), newJNull(), newJNull(), newJNull(), newJNull(), newJNull())
    var rows = newJArray()
    rows.add a
    rows.add b
    check prunableNames(rows) == @["a", "b"]

  test "全行 stopped でなければ空配列":
    let activeRow = mkRow("busy-tunnel", "L", "127.0.0.1:2", "x:2", "h",
        "fwActive", "healthy", %0, %0, %0, %0, newJNull(), %10)
    var rows = newJArray()
    rows.add activeRow
    check prunableNames(rows) == newSeq[string]()

# ===========================================================================
# usage(): 主要サブコマンドを含む
# ===========================================================================

suite "argv.usage":
  test "主要サブコマンドを全部含む":
    let u = usage()
    for cmd in ["run", "up", "down", "ps", "start", "stop", "restart",
                "inspect", "check", "logs", "rm", "hosts", "daemon",
                "completion", "version", "help"]:
      check cmd in u

# ===========================================================================
# dispatch: --no-autostart かつデーモン無しなら終了コード 7
# ===========================================================================

suite "dispatch: --no-autostart":
  test "デーモンに到達できず --no-autostart なら ecDaemonUnreachable (7)":
    withEnv({envRuntimeDir: "/tmp/pw-dispatch-rt-noexist"}, proc() =
      removeFile("/tmp/pw-dispatch-rt-noexist/powarder.sock")
      let args = ParsedArgs(subcommand: "ps", noAutostart: true, tailLines: 50)
      check dispatch(args) == ecDaemonUnreachable.int
      check ecDaemonUnreachable.int == 7)

  test "start / stop / restart / rm / prune も同様に 7 になる":
    withEnv({envRuntimeDir: "/tmp/pw-dispatch-rt-noexist2"}, proc() =
      removeFile("/tmp/pw-dispatch-rt-noexist2/powarder.sock")
      for sub in ["start", "stop", "restart", "rm", "prune"]:
        let args = ParsedArgs(subcommand: sub, positional: @["prod-db"],
            noAutostart: true, tailLines: 50)
        check dispatch(args) == ecDaemonUnreachable.int)

# ===========================================================================
# dispatch: logs
# ===========================================================================
#
# ログの実体は **ホスト単位**（1 ControlMaster = 1 ログファイル）に書かれ、
# ファイル名にホストの fingerprint が入るため、**トンネル名だけからパスを
# 決定できない**。よって `logs` は `tunnel.inspect` で `log_path` を問い合わせる。
#
# その結果、デーモンが停止している場合は「ログが無い」のではなく
# 「どのファイルを読めばよいか特定できない」状態になるので、
# `ecOk` ではなく `ecDaemonUnreachable`（7）を返し、
# `logs/` 配下のファイル一覧を案内する（ファイル自体はデーモンの生死に
# 関係なく残っているので、直接読めば内容は確認できる）。
#
# 「デーモン稼働中でログファイルがまだ無い」ケースだけは `ecOk` を返すが、
# それには実デーモンが必要なので単体テストでは検証できない（E2E で確認済み）。

suite "dispatch: logs":
  test "デーモンが停止していればパスを特定できないので 7 を返す":
    withEnv({envStateDir: "/tmp/pw-dispatch-state-empty",
             envRuntimeDir: "/tmp/pw-dispatch-rt-empty"}, proc() =
      let args = ParsedArgs(subcommand: "logs",
          positional: @["nonexistent-tunnel"], tailLines: 50)
      check dispatch(args) == ecDaemonUnreachable.int)

  test "トンネル名を省略すると使用法エラー（2）":
    let args = ParsedArgs(subcommand: "logs", positional: @[], tailLines: 50)
    check dispatch(args) == ecUsage.int
