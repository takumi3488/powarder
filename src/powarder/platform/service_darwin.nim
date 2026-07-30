## macOS (launchd) OS service registration implementation.
##
## Generates `~/Library/LaunchAgents/dev.powarder.daemon.plist`, and
## registers/deregisters it via `launchctl bootstrap` / `bootout`.
##
## ### IMPORTANT: `KeepAlive.SuccessfulExit = false`
##
## For launchd's `KeepAlive`, a simple value like `true` results in "always
## restart regardless of exit code" behavior. This would be a serious bug:
## `powarder daemon stop` (= the process exiting with exit 0) would be
## immediately restarted by launchd, and the daemon could never be stopped.
## Since we only want it to restart on a crash (exit != 0), the dict form
## `<dict><key>SuccessfulExit</key><false/></dict>` is used to explicitly
## state "do not keep-alive on a normal exit."
##
## launchd does not inherit an interactive shell's environment (`PATH` /
## `SSH_AUTH_SOCK` etc.). Without writing at least a minimal `PATH` in
## `EnvironmentVariables`, powarder cannot find `ssh`. `SSH_AUTH_SOCK`
## cannot be resolved via launchd in principle (since it depends on the
## user's login session's ssh-agent), so this is left to be covered in the
## README's troubleshooting section instead (it can be worked around using
## Keychain integration's `UseKeychain yes`).
##
## `renderUnitFile` is a **pure function** that touches neither files nor
## sockets. Only `installService` / `uninstallService` / `serviceStatus`
## actually call `launchctl` (`tests/tservice.nim` never calls into here at
## all, to avoid polluting the user's real environment).

import std/[os, osproc, strutils, posix]
import powarder/platform/service_types
import powarder/core/paths

const
  launchdPath = "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin"
    ## Since launchd does not inherit an interactive shell's PATH, minimal
    ## candidates are specified explicitly.

proc escapeXml(s: string): string =
  ## Since a plist is XML, embedding a path that may contain `&` `<` `>`
  ## as-is would break it.
  s.multiReplace(("&", "&amp;"), ("<", "&lt;"), (">", "&gt;"))

proc unitFilePath*(): string =
  getHomeDir() / "Library" / "LaunchAgents" / (serviceLabel() & ".plist")

proc programArguments(exePath, configPath: string): seq[string] =
  ## The element sequence for `ProgramArguments` corresponding to
  ## `powarder <exePath> daemon [--config <configPath>]`.
  result = @[exePath, "daemon"]
  if configPath.len > 0:
    result.add "--config"
    result.add configPath

proc renderUnitFile*(exePath: string; configPath = ""): string =
  ## Assembles the contents of the plist. `daemonLogPath()` returns an
  ## absolute path (since the plist's `StandardOutPath` does not expand
  ## `~`, the caller must resolve it to an absolute path beforehand).
  let logPath = daemonLogPath()
  var s = ""
  s.add "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
  s.add "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" "
  s.add "\"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
  s.add "<plist version=\"1.0\">\n"
  s.add "<dict>\n"
  s.add "  <key>Label</key><string>"
  s.add escapeXml(serviceLabel())
  s.add "</string>\n"
  s.add "  <key>ProgramArguments</key>\n"
  s.add "  <array>\n"
  for a in programArguments(exePath, configPath):
    s.add "    <string>"
    s.add escapeXml(a)
    s.add "</string>\n"
  s.add "  </array>\n"
  s.add "  <key>RunAtLoad</key><true/>\n"
  s.add "  <key>KeepAlive</key>\n"
  s.add "  <dict><key>SuccessfulExit</key><false/></dict>\n"
  s.add "  <key>StandardOutPath</key><string>"
  s.add escapeXml(logPath)
  s.add "</string>\n"
  s.add "  <key>StandardErrorPath</key><string>"
  s.add escapeXml(logPath)
  s.add "</string>\n"
  s.add "  <key>EnvironmentVariables</key>\n"
  s.add "  <dict>\n"
  s.add "    <key>PATH</key><string>"
  s.add launchdPath
  s.add "</string>\n"
  s.add "  </dict>\n"
  s.add "</dict>\n"
  s.add "</plist>\n"
  s

# ---------------------------------------------------------------------------
# Executing launchctl (has side effects. Not called from tests)
# ---------------------------------------------------------------------------

proc guiDomain(): string =
  "gui/" & $getuid()

proc runLaunchctl(args: varargs[string]): tuple[output: string; exitCode: int] =
  try:
    execCmdEx("launchctl " & args.join(" "))
  except OSError as e:
    (e.msg, -1)

proc serviceStatus*(): ServiceInfo =
  ## Determines the status from whether the plist file exists and whether
  ## `launchctl print` succeeds.
  let path = unitFilePath()
  if not fileExists(path):
    return ServiceInfo(label: serviceLabel(), unitPath: path,
        status: ssNotInstalled, notes: @[])
  let (_, code) = runLaunchctl("print", guiDomain() & "/" & serviceLabel())
  let status = if code == 0: ssRunning else: ssInstalled
  ServiceInfo(label: serviceLabel(), unitPath: path, status: status, notes: @[])

proc installService*(exePath: string; configPath = ""): ServiceInfo =
  ## Writes out the plist and registers it via `launchctl bootstrap`.
  ## Falls back to the older `launchctl load` for environments where
  ## `bootstrap` (the newer API) fails.
  let path = unitFilePath()
  createDir(path.parentDir)
  writeFile(path, renderUnitFile(exePath, configPath))

  let domain = guiDomain()
  var (outp, code) = runLaunchctl("bootstrap", domain, quoteShell(path))
  if code != 0:
    (outp, code) = runLaunchctl("load", quoteShell(path))

  result = serviceStatus()
  if code != 0:
    result.notes.add "Registration via launchctl may have failed: " &
        outp.strip()

proc uninstallService*(): ServiceInfo =
  ## Deregisters via `launchctl bootout`, then deletes the plist file.
  let path = unitFilePath()
  discard runLaunchctl("bootout", guiDomain() & "/" & serviceLabel())
  if fileExists(path):
    removeFile(path)
  ServiceInfo(label: serviceLabel(), unitPath: path, status: ssNotInstalled,
      notes: @[])
