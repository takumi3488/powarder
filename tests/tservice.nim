## Tests for `powarder/platform/service` (OS service registration).
##
## **No test actually calls `launchctl` / `systemctl`,** since that would
## pollute the user's real environment (`~/Library/LaunchAgents/` or
## `~/.config/systemd/user/`, and the actual service registration state).
## `installService` / `uninstallService` / `serviceStatus` are never called
## here.
##
## `renderUnitFile` / `unitFilePath` / `lingerNote` have been made pure
## functions, so the policy here is to verify **only the generated string**.
##
## Since we want to verify both macOS and Linux output, this imports not
## only `platform/service` (the frontend that dispatches based on the
## current OS) but also `platform/service_darwin` / `platform/service_linux`
## **directly**. Neither of these two modules depends at all on the actual
## `launchctl`/`systemctl` binaries (aside from the side-effecting procs
## that merely invoke a command name via `osproc`, they are cross-platform
## Nim code that only assembles strings), so this compiles and runs on a dev
## machine whether it's macOS or Linux.
##
## **Caution (a pitfall when reading this module)**: `powarder/platform/service`
## / `service_darwin` / `service_linux` are structured to import the shared
## types and `serviceLabel` from `platform/service_types` in one direction
## only (`service_types` <- `service_darwin`/`service_linux` <- `service`),
## so there is no circular import between modules. However,
## **`unitFilePath` / `renderUnitFile` / `installService` / `uninstallService`
## / `serviceStatus` exist as identically-named procs in all three of
## `service` / `service_darwin` / `service_linux`**, so when importing all of
## them at once as this test file does, **they must always be called
## qualified, like `service_darwin.xxx` / `service_linux.xxx`** (calling them
## unqualified results in an `ambiguous call`. This is a plain same-name-proc
## ambiguity issue unrelated to circular imports). `serviceLabel` /
## `ServiceInfo` / `ServiceStatus` are defined only in `service_types`, and
## `service_darwin` / `service_linux` merely import it (they don't
## redefine it), so no qualification is needed for those.

import std/[unittest, os, strutils]
import powarder/platform/service
import powarder/platform/service_darwin
import powarder/platform/service_linux
import powarder/core/paths

proc withEnv(pairs: openArray[(string, string)], body: proc()) =
  ## Temporarily swaps environment variables (follows the helper pattern in
  ## `tests/tpaths.nim`).
  var saved: seq[(string, bool, string)]
  for (k, v) in pairs:
    saved.add (k, existsEnv(k), getEnv(k))
    putEnv(k, v)
  try:
    body()
  finally:
    for (k, existed, old) in saved:
      if existed: putEnv(k, old) else: delEnv(k)

proc extractPlistString(content, key: string): string =
  ## A simple parser that extracts the V part of `<key>K</key><string>V</string>`
  ## (a full plist parser isn't needed, so this is good enough for testing).
  let marker = "<key>" & key & "</key><string>"
  let idx = content.find(marker)
  if idx < 0: return ""
  let valueStart = idx + marker.len
  let valueEnd = content.find("</string>", valueStart)
  if valueEnd < 0: return ""
  content[valueStart ..< valueEnd]

# ===========================================================================
# serviceLabel / unitFilePath (the OS dispatch in `platform/service`)
# ===========================================================================

suite "service: serviceLabel / unitFilePath":
  test "serviceLabel is \"dev.powarder.daemon\" regardless of OS":
    check serviceLabel() == "dev.powarder.daemon"

  test "unitFilePath returns the expected path for the current OS":
    when defined(macosx):
      check service.unitFilePath() ==
          getHomeDir() / "Library" / "LaunchAgents" / "dev.powarder.daemon.plist"
    elif defined(linux):
      check service.unitFilePath() ==
          getHomeDir() / ".config" / "systemd" / "user" / "powarder.service"

# ===========================================================================
# macOS: plist generation (service_darwin.renderUnitFile)
# ===========================================================================

suite "service_darwin: renderUnitFile":
  test "unitFilePath is ~/Library/LaunchAgents/dev.powarder.daemon.plist":
    check service_darwin.unitFilePath() ==
        getHomeDir() / "Library" / "LaunchAgents" / "dev.powarder.daemon.plist"

  test "IMPORTANT: KeepAlive's SuccessfulExit is false":
    # If this were reversed (true, or absent), `powarder daemon stop` (exit
    # 0) would get immediately restarted by launchd, and the daemon could
    # never be stopped.
    let plist = service_darwin.renderUnitFile("/usr/local/bin/powarder")
    check "<key>KeepAlive</key>" in plist
    check "<dict><key>SuccessfulExit</key><false/></dict>" in plist
    # Also explicitly confirm it isn't a naive single <true/> KeepAlive
    check "<key>KeepAlive</key><true/>" notin plist

  test "includes RunAtLoad / Label / ProgramArguments (the executable path and daemon)":
    let plist = service_darwin.renderUnitFile("/opt/homebrew/bin/powarder")
    check "<key>RunAtLoad</key><true/>" in plist
    check "<key>Label</key><string>dev.powarder.daemon</string>" in plist
    check "<key>ProgramArguments</key>" in plist
    check "<string>/opt/homebrew/bin/powarder</string>" in plist
    check "<string>daemon</string>" in plist

  test "passing configPath adds --config to ProgramArguments":
    let plist = service_darwin.renderUnitFile("/usr/local/bin/powarder",
        "/home/x/.config/powarder/config.json")
    check "<string>--config</string>" in plist
    check "<string>/home/x/.config/powarder/config.json</string>" in plist

  test "--config does not appear when configPath is omitted":
    let plist = service_darwin.renderUnitFile("/usr/local/bin/powarder")
    check "--config" notin plist

  test "EnvironmentVariables includes PATH (since launchd doesn't inherit an interactive shell's PATH)":
    let plist = service_darwin.renderUnitFile("/usr/local/bin/powarder")
    check "<key>EnvironmentVariables</key>" in plist
    let pathValue = extractPlistString(plist, "PATH")
    check pathValue.len > 0
    check "/usr/bin" in pathValue
    check "/opt/homebrew/bin" in pathValue

  test "StandardOutPath / StandardErrorPath are absolute paths (since ~ isn't expanded)":
    withEnv({envStateDir: "/tmp/pw-service-state"}, proc() =
      let plist = service_darwin.renderUnitFile("/usr/local/bin/powarder")
      let outPath = extractPlistString(plist, "StandardOutPath")
      let errPath = extractPlistString(plist, "StandardErrorPath")
      check outPath.len > 0
      check errPath.len > 0
      check outPath == daemonLogPath()
      check isAbsolute(outPath)
      check isAbsolute(errPath)
      check not outPath.startsWith("~"))

# ===========================================================================
# Linux: systemd unit generation (service_linux.renderUnitFile)
# ===========================================================================

suite "service_linux: renderUnitFile":
  test "unitFilePath is ~/.config/systemd/user/powarder.service":
    check service_linux.unitFilePath() ==
        getHomeDir() / ".config" / "systemd" / "user" / "powarder.service"

  test "IMPORTANT: includes Restart=on-failure, and does not include Restart=always":
    # If this were `always`, systemd would restart it immediately even on
    # `powarder daemon stop` (exit 0), and the daemon could never be
    # stopped.
    let unit = service_linux.renderUnitFile("/usr/local/bin/powarder")
    check "Restart=on-failure" in unit
    check "Restart=always" notin unit

  test "includes ExecStart / WantedBy=default.target":
    let unit = service_linux.renderUnitFile("/usr/local/bin/powarder")
    check "ExecStart=/usr/local/bin/powarder daemon" in unit
    check "WantedBy=default.target" in unit
    check "[Unit]" in unit
    check "[Service]" in unit
    check "[Install]" in unit

  test "passing configPath adds --config to ExecStart":
    let unit = service_linux.renderUnitFile("/usr/local/bin/powarder",
        "/home/x/.config/powarder/config.json")
    check "ExecStart=/usr/local/bin/powarder daemon --config " &
        "/home/x/.config/powarder/config.json" in unit

  test "RestartSec is also set":
    let unit = service_linux.renderUnitFile("/usr/local/bin/powarder")
    check "RestartSec=5" in unit

suite "service_linux: lingerNote":
  test "includes guidance for loginctl enable-linger":
    # Wording that must always be included in the `notes` returned by
    # `installService` / `serviceStatus`. Separated out as a pure function
    # so it can be tested without actually calling systemctl.
    let note = lingerNote()
    check "loginctl" in note
    check "enable-linger" in note
