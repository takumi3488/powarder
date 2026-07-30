## Linux (systemd --user) OS service registration implementation.
##
## Generates `~/.config/systemd/user/powarder.service`, and
## registers/deregisters it via `systemctl --user enable --now` /
## `disable --now`.
##
## ### IMPORTANT: `Restart=on-failure` (not `Restart=always`)
##
## If set to `Restart=always`, even `powarder daemon stop` (= the process
## exiting with exit 0) causes systemd to restart it immediately, which
## would be a serious bug preventing the daemon from ever being stopped.
## Since we only want it to restart on a crash (exit != 0), `on-failure` is
## used.
##
## ### loginctl enable-linger
##
## `systemctl --user` is only effective while the user manager tied to the
## user's login session is running. Without running
## `loginctl enable-linger $USER`, the user manager itself terminates on
## logout, and the tunnels go down along with the daemon. This is a
## fatally easy-to-miss pitfall, so the guidance must always be included in
## the `ServiceInfo.notes` returned by `installService` / `serviceStatus`
## (`lingerNote()` assembles the wording. Tests call this pure function
## directly to verify it).
##
## `renderUnitFile` is a **pure function** that touches neither files nor
## sockets. Only `installService` / `uninstallService` / `serviceStatus`
## actually call `systemctl` (`tests/tservice.nim` never calls into here at
## all, to avoid polluting the user's real environment).

import std/[os, osproc, strutils]
import powarder/platform/service_types

const
  unitBasename = "powarder.service"

proc unitFilePath*(): string =
  getHomeDir() / ".config" / "systemd" / "user" / unitBasename

proc execStartLine(exePath, configPath: string): string =
  ## The value of `ExecStart=`. Relying on systemd's simple command-line
  ## expansion (space-separated) is not as strict as the plist's
  ## `ProgramArguments` (an array), but this matches the format specified
  ## (a single-line `ExecStart=`).
  var s = exePath
  s.add " daemon"
  if configPath.len > 0:
    s.add " --config "
    s.add configPath
  s

proc renderUnitFile*(exePath: string; configPath = ""): string =
  var s = ""
  s.add "[Unit]\n"
  s.add "Description=powarder — SSH port forward manager\n"
  s.add "After=network-online.target\n"
  s.add "\n"
  s.add "[Service]\n"
  s.add "Type=simple\n"
  s.add "ExecStart="
  s.add execStartLine(exePath, configPath)
  s.add "\n"
  s.add "Restart=on-failure\n"
  s.add "RestartSec=5\n"
  s.add "\n"
  s.add "[Install]\n"
  s.add "WantedBy=default.target\n"
  s

proc lingerNote*(): string =
  ## Guidance for `loginctl enable-linger`. Made a pure function so it can
  ## be tested without actually calling `systemctl`.
  "To keep the daemon running after logout, run " &
    "`loginctl enable-linger $USER` " &
    "(if you don't, the systemd user manager stops entirely on logout, " &
    "taking the tunnels down with it)"

# ---------------------------------------------------------------------------
# Executing systemctl (has side effects. Not called from tests)
# ---------------------------------------------------------------------------

proc runSystemctl(args: varargs[string]): tuple[output: string; exitCode: int] =
  try:
    execCmdEx("systemctl --user " & args.join(" "))
  except OSError as e:
    (e.msg, -1)

proc serviceStatus*(): ServiceInfo =
  ## Determines the status from whether the unit file exists and the
  ## result of `systemctl --user is-active`.
  let path = unitFilePath()
  if not fileExists(path):
    return ServiceInfo(label: serviceLabel(), unitPath: path,
        status: ssNotInstalled, notes: @[lingerNote()])
  let (outp, code) = runSystemctl("is-active", unitBasename)
  let status =
    if code == 0 and outp.strip() == "active": ssRunning
    else: ssInstalled
  ServiceInfo(label: serviceLabel(), unitPath: path, status: status,
      notes: @[lingerNote()])

proc installService*(exePath: string; configPath = ""): ServiceInfo =
  ## Writes out the unit file, then runs `daemon-reload` before
  ## `enable --now`.
  let path = unitFilePath()
  createDir(path.parentDir)
  writeFile(path, renderUnitFile(exePath, configPath))

  discard runSystemctl("daemon-reload")
  let (outp, code) = runSystemctl("enable", "--now", unitBasename)

  result = serviceStatus()
  if code != 0:
    result.notes.add "Registration via systemctl may have failed: " &
        outp.strip()

proc uninstallService*(): ServiceInfo =
  ## Runs `disable --now`, then deletes the unit file and runs
  ## `daemon-reload`.
  discard runSystemctl("disable", "--now", unitBasename)
  let path = unitFilePath()
  if fileExists(path):
    removeFile(path)
  discard runSystemctl("daemon-reload")
  ServiceInfo(label: serviceLabel(), unitPath: path, status: ssNotInstalled,
      notes: @[lingerNote()])
