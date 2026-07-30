## Tests for `powarder/cli/cmd_update`'s pure functions.
##
## Only the string/argv-building functions and the version-comparison logic
## are tested here (`installDirFromExePath` / `downloaderArgv` /
## `envAssignments` / `updateShellCommand` / `normalizeVersion` /
## `isUpdateAvailable` / `parseTagName`). **No test in this file touches the
## network or the real filesystem, and none actually replaces a binary.**
##
## `findDownloader` / `canWriteDir` / `runCapture` / `daemonAppearsRunning` /
## `cmdUpdateCheck` / `cmdUpdateApply` / `cmdUpdate` are deliberately left
## untested here: the first three shell out to `PATH`/the filesystem/a
## subprocess, `daemonAppearsRunning` talks to the daemon and to
## `launchctl`/`systemctl`, and the `cmdUpdateXxx` procs either hit the
## GitHub API (`--check`) or actually run install.sh against the network and
## overwrite the current binary (the plain `update` path) — none of which
## belong in a unit test (see `tests/tservice.nim`'s doc comment for the
## same reasoning applied to `installService`/`uninstallService`).

import std/unittest
import std/os
import std/strutils
import powarder/cli/cmd_update

# ===========================================================================
# installDirFromExePath
# ===========================================================================

suite "cmd_update: installDirFromExePath":
  test "returns the parent directory of an absolute path":
    check installDirFromExePath("/usr/local/bin/powarder") == "/usr/local/bin"

  test "works for a homebrew-style path too":
    check installDirFromExePath("/opt/homebrew/bin/powarder") ==
        "/opt/homebrew/bin"

  test "falls back to \".\" when there is no directory component":
    check installDirFromExePath("powarder") == "."

# ===========================================================================
# downloaderArgv
# ===========================================================================

suite "cmd_update: downloaderArgv":
  test "curl uses -fsSL":
    check downloaderArgv(dlCurl, "https://example.com/x") ==
        @["curl", "-fsSL", "https://example.com/x"]

  test "wget uses -qO-":
    check downloaderArgv(dlWget, "https://example.com/x") ==
        @["wget", "-qO-", "https://example.com/x"]

# ===========================================================================
# envAssignments
# ===========================================================================

suite "cmd_update: envAssignments":
  test "always includes POWARDER_INSTALL_DIR":
    let a = envAssignments("/usr/local/bin", "")
    check a.len == 1
    check a[0] == "POWARDER_INSTALL_DIR=/usr/local/bin"

  test "includes POWARDER_VERSION only when toVersion is non-empty":
    let a = envAssignments("/usr/local/bin", "v1.2.3")
    check a.len == 2
    check a[0] == "POWARDER_INSTALL_DIR=/usr/local/bin"
    check a[1] == "POWARDER_VERSION=v1.2.3"

  test "quotes a directory containing a space":
    let a = envAssignments("/opt/my dir", "")
    check a[0] == "POWARDER_INSTALL_DIR=" & quoteShell("/opt/my dir")

# ===========================================================================
# updateShellCommand
# ===========================================================================

suite "cmd_update: updateShellCommand":
  test "assembles env assignments + downloader pipeline (curl, latest)":
    let cmd = updateShellCommand("/usr/local/bin", "", dlCurl,
        "https://example.com/install.sh")
    check cmd == "POWARDER_INSTALL_DIR=/usr/local/bin curl -fsSL " &
        "https://example.com/install.sh | sh"

  test "includes POWARDER_VERSION when --to is given":
    let cmd = updateShellCommand("/usr/local/bin", "v1.2.3", dlCurl,
        "https://example.com/install.sh")
    check cmd == "POWARDER_INSTALL_DIR=/usr/local/bin " &
        "POWARDER_VERSION=v1.2.3 curl -fsSL " &
        "https://example.com/install.sh | sh"

  test "wget variant pipes through wget instead of curl":
    let cmd = updateShellCommand("/usr/local/bin", "", dlWget,
        "https://example.com/install.sh")
    check cmd == "POWARDER_INSTALL_DIR=/usr/local/bin wget -qO- " &
        "https://example.com/install.sh | sh"

  test "defaults to the real install.sh URL when none is given":
    let cmd = updateShellCommand("/usr/local/bin", "", dlCurl)
    check installScriptUrl in cmd
    check cmd.endsWith(" | sh")

# ===========================================================================
# normalizeVersion / isUpdateAvailable
# ===========================================================================

suite "cmd_update: normalizeVersion":
  test "strips a leading v":
    check normalizeVersion("v1.2.3") == "1.2.3"

  test "strips a leading V too":
    check normalizeVersion("V1.2.3") == "1.2.3"

  test "leaves a version with no prefix untouched":
    check normalizeVersion("1.2.3") == "1.2.3"

  test "trims surrounding whitespace":
    check normalizeVersion("  v1.2.3\n") == "1.2.3"

suite "cmd_update: isUpdateAvailable":
  test "false when versions match after normalizing the v prefix":
    check not isUpdateAvailable("1.2.3", "v1.2.3")
    check not isUpdateAvailable("v1.2.3", "1.2.3")
    check not isUpdateAvailable("1.2.3", "1.2.3")

  test "true when versions differ":
    check isUpdateAvailable("1.2.3", "v1.3.0")

# ===========================================================================
# parseTagName
# ===========================================================================

suite "cmd_update: parseTagName":
  test "extracts tag_name from a GitHub releases API response":
    let body = """{"tag_name": "v1.2.3", "name": "v1.2.3", "draft": false}"""
    check parseTagName(body) == "v1.2.3"

  test "raises ValueError when tag_name is missing":
    expect ValueError:
      discard parseTagName("""{"name": "v1.2.3"}""")

  test "raises ValueError when tag_name is not a string":
    expect ValueError:
      discard parseTagName("""{"tag_name": 123}""")

  test "raises (from std/json) on malformed JSON":
    expect ValueError:
      discard parseTagName("not json")
