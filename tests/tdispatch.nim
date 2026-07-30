## Tests for `powarder/cli/dispatch` and its surroundings (`names` /
## `autostart` / `cmd_completion`).
##
## Policy for maximizing the range that can be tested without actually
## starting the daemon:
## - Table formatting and incremental log-tail reads are "pure functions
##   that assemble strings" (`renderPsTable` / `renderHostsTable` /
##   `tailLines` / `readIncrement`), tested by calling them directly.
## - For `dispatch` itself, we create a situation where the daemon can
##   never be reached (isolate `POWARDER_RUNTIME_DIR` so the socket doesn't
##   exist), and only check that `--no-autostart` produces exit code 7.
##   A test that actually lets the daemon autostart isn't done here, since
##   it would require the built executable (see the report).

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
  ## Temporarily overrides environment variables (mirrors the helper in
  ## `tests/tpaths.nim` / `tests/tcli.nim`).
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
  test "the same seed always gives the same name":
    check randomName(1) == randomName(1)
    check randomName(42) == randomName(42)

  test "\"adjective-noun\" format (lowercase letters and hyphens only)":
    let n = randomName(7)
    let parts = n.split('-')
    check parts.len == 2
    for p in parts:
      check p.len > 0
      for c in p:
        check c in {'a' .. 'z'}

  test "changing the seed can give a different name":
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
  test "zsh starts with #compdef powarder and includes the main subcommands and daemon sub-subcommands":
    let s = completionScript("zsh")
    check s.startsWith("#compdef powarder")
    check "run" in s
    check "daemon" in s
    check "completion" in s
    check "status" in s ## daemon status
    check "install" in s ## daemon install

  test "bash / fish are simplified but still include subcommand names":
    check "run" in completionScript("bash")
    check "daemon" in completionScript("bash")
    check "run" in completionScript("fish")
    check "daemon" in completionScript("fish")

  test "unknown shell raises an exception":
    expect ValueError:
      discard completionScript("powershell")

# ===========================================================================
# dispatch.exitCodeForRpcError: RpcRemoteError.code -> every exit-code pattern
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

  test "other codes fall back to ecGeneral (1)":
    check exitCodeForRpcError(errHostNotFound) == ecGeneral
    check exitCodeForRpcError(errForwardBindFailed) == ecGeneral
    check exitCodeForRpcError(-99999) == ecGeneral
    check ecGeneral.int == 1

# ===========================================================================
# dispatch.renderPsTable: mock tunnel.list JSON -> table string
# ===========================================================================

suite "dispatch: renderPsTable":
  test "-L rows show stats, -R rows have '-' stat columns":
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
    # stat columns that can't be obtained in principle for -R rows must be
    # "-" (the most important point)
    check expectedRemote[5] == "-" ## CONNS
    check expectedRemote[6] == "-" ## RX/TX
    check expectedRemote[7] == "-" ## LAST

  test "the header still appears even with no rows":
    let w = newWriter(noColor = true)
    let rendered = renderPsTable(newJArray(), w)
    check rendered.splitLines().len == 1
    check rendered.splitWhitespace() == @["NAME", "TYPE", "BIND", "TARGET",
        "HOST", "CONNS", "RX/TX", "LAST", "UPTIME", "STATUS"]

# ===========================================================================
# dispatch.renderHostsTable
# ===========================================================================

suite "dispatch: renderHostsTable":
  test "can format mock host.list JSON into a table":
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
  test "returns the last n lines":
    let path = "/tmp/pw-dtail-1.log"
    removeFile(path)
    writeFile(path, "a\nb\nc\nd\ne\n")
    check tailLines(path, 3) == @["c", "d", "e"]
    check tailLines(path, 100) == @["a", "b", "c", "d", "e"]
    removeFile(path)

  test "returns an empty seq if the file doesn't exist":
    let path = "/tmp/pw-dtail-nonexist.log"
    removeFile(path)
    check tailLines(path, 10) == newSeq[string]()

  test "doesn't drop the last line even without a trailing newline":
    let path = "/tmp/pw-dtail-2.log"
    removeFile(path)
    writeFile(path, "a\nb\nc")
    check tailLines(path, 2) == @["b", "c"]
    removeFile(path)

# ===========================================================================
# dispatch.readIncrement: incremental reads for logs -f
# ===========================================================================

suite "dispatch: readIncrement":
  test "the first read starts at offset 0 and reads everything":
    let path = "/tmp/pw-dincr-1.log"
    removeFile(path)
    writeFile(path, "hello\n")
    let (data, off) = readIncrement(path, 0)
    check data == "hello\n"
    check off == 6
    removeFile(path)

  test "can read just the appended part as an increment":
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

  test "re-reads from the start after a truncate (rotation)":
    let path = "/tmp/pw-dincr-3.log"
    removeFile(path)
    writeFile(path, "aaaaaaaaaa\n") # 11 bytes
    let (_, off1) = readIncrement(path, 0)
    check off1 == 11
    writeFile(path, "new\n") # short new content after rotation
    let (data2, off2) = readIncrement(path, off1)
    check data2 == "new\n"
    check off2 == 4
    removeFile(path)

  test "returns the offset unchanged with no data if the file doesn't exist":
    let path = "/tmp/pw-dincr-nonexist.log"
    removeFile(path)
    let (data, off) = readIncrement(path, 42)
    check data == ""
    check off == 42

# ===========================================================================
# dispatch: daemon --foreground (DaemonRunner dependency injection)
# ===========================================================================
# The part that can be tested without importing `daemon/run.nim`. Just
# passes a dummy `DaemonRunner` and confirms it's delegated to correctly.
# Needs no IPC and no daemon process at all.

suite "dispatch: daemon --foreground (DaemonRunner injection)":
  test "when subsubcommand is empty, the return value of runDaemon() is passed through":
    let args = ParsedArgs(subcommand: "daemon", subsubcommand: "", tailLines: 50)
    let fakeRunDaemon: DaemonRunner = proc (): int = 42
    check dispatch(args, fakeRunDaemon) == 42

  test "ecGeneral (1) when runDaemon is nil":
    let args = ParsedArgs(subcommand: "daemon", subsubcommand: "", tailLines: 50)
    check dispatch(args) == ecGeneral.int

# ===========================================================================
# dispatch: daemon install / uninstall was implemented in M7 (`platform/service`)
# ===========================================================================
# **We deliberately don't write a test that actually feeds subsubcommand
# "install"/"uninstall" into `dispatch(args)` here.** `installService()` /
# `uninstallService()` call the real `launchctl` / `systemctl` and write
# real files (`~/Library/LaunchAgents/...` / `~/.config/systemd/user/...`)
# as a side effect, so calling them here would actually register a
# LaunchAgent/systemd unit on the test-running environment (the developer's
# real machine) -- and worse, it could register the test binary's own path,
# which would be the worst-case accident.
#
# The pure functions that `installService` / `uninstallService` use
# internally (`renderUnitFile` / `unitFilePath` / `serviceLabel` /
# `lingerNote`) are verified in `tests/tservice.nim` by directly importing
# `platform/service_darwin` / `platform/service_linux` (that one also never
# calls the real `launchctl` / `systemctl`). The manual on-machine
# verification steps are recorded in the M7 report.

# ===========================================================================
# dispatch.prunableNames: mock tunnel.list JSON -> names to remove
# ===========================================================================

suite "dispatch: prunableNames":
  test "collects only rows with status == \"stopped\"":
    let stoppedRow = mkRow("idle-tunnel", "L", "127.0.0.1:1", "x:1", "h",
        "fwPending", "stopped", newJNull(), newJNull(), newJNull(),
        newJNull(), newJNull(), newJNull())
    let activeRow = mkRow("busy-tunnel", "L", "127.0.0.1:2", "x:2", "h",
        "fwActive", "healthy", %0, %0, %0, %0, newJNull(), %10)
    var rows = newJArray()
    rows.add stoppedRow
    rows.add activeRow
    check prunableNames(rows) == @["idle-tunnel"]

  test "passing an empty array returns an empty array":
    check prunableNames(newJArray()) == newSeq[string]()

  test "collects everything when every row is stopped":
    let a = mkRow("a", "L", "1", "2", "h", "fwPending", "stopped",
        newJNull(), newJNull(), newJNull(), newJNull(), newJNull(), newJNull())
    let b = mkRow("b", "R", "1", "2", "h", "fwPending", "stopped",
        newJNull(), newJNull(), newJNull(), newJNull(), newJNull(), newJNull())
    var rows = newJArray()
    rows.add a
    rows.add b
    check prunableNames(rows) == @["a", "b"]

  test "returns an empty array unless every row is stopped":
    let activeRow = mkRow("busy-tunnel", "L", "127.0.0.1:2", "x:2", "h",
        "fwActive", "healthy", %0, %0, %0, %0, newJNull(), %10)
    var rows = newJArray()
    rows.add activeRow
    check prunableNames(rows) == newSeq[string]()

# ===========================================================================
# usage(): includes the main subcommands
# ===========================================================================

suite "argv.usage":
  test "includes every main subcommand":
    let u = usage()
    for cmd in ["run", "up", "down", "ps", "start", "stop", "restart",
                "inspect", "check", "logs", "rm", "hosts", "daemon",
                "completion", "version", "help"]:
      check cmd in u

# ===========================================================================
# dispatch: exit code 7 when --no-autostart and no daemon
# ===========================================================================

suite "dispatch: --no-autostart":
  test "ecDaemonUnreachable (7) when the daemon can't be reached and --no-autostart is set":
    withEnv({envRuntimeDir: "/tmp/pw-dispatch-rt-noexist"}, proc() =
      removeFile("/tmp/pw-dispatch-rt-noexist/powarder.sock")
      let args = ParsedArgs(subcommand: "ps", noAutostart: true, tailLines: 50)
      check dispatch(args) == ecDaemonUnreachable.int
      check ecDaemonUnreachable.int == 7)

  test "start / stop / restart / rm / prune also give 7 the same way":
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
# The log itself is written **per host** (1 ControlMaster = 1 log file), and
# the file name includes the host's fingerprint, so **the path can't be
# determined from the tunnel name alone**. That's why `logs` queries
# `log_path` via `tunnel.inspect`.
#
# As a result, when the daemon is stopped, the situation isn't "there's no
# log" but "we can't pin down which file to read", so it returns
# `ecDaemonUnreachable` (7) instead of `ecOk`, and points the user at the
# file listing under `logs/` (the files themselves remain regardless of
# whether the daemon is alive, so reading them directly still works).
#
# Only the case "the daemon is running but the log file doesn't exist yet"
# returns `ecOk`, but that requires a real daemon so it can't be verified in
# a unit test (confirmed via E2E).

suite "dispatch: logs":
  test "returns 7 because the path can't be determined when the daemon is stopped":
    withEnv({envStateDir: "/tmp/pw-dispatch-state-empty",
             envRuntimeDir: "/tmp/pw-dispatch-rt-empty"}, proc() =
      let args = ParsedArgs(subcommand: "logs",
          positional: @["nonexistent-tunnel"], tailLines: 50)
      check dispatch(args) == ecDaemonUnreachable.int)

  test "omitting the tunnel name gives a usage error (2)":
    let args = ParsedArgs(subcommand: "logs", positional: @[], tailLines: 50)
    check dispatch(args) == ecUsage.int
