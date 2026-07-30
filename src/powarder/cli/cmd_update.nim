## `powarder update` — self-update the CLI/daemon binary.
##
## **All of the actual download/verify/install work is delegated to
## `install.sh`** (fetched from GitHub at update time; see the repository
## root). This module deliberately does not re-implement checksum
## verification or atomic file replacement — duplicating that logic here
## would create two independent, driftable copies of "how to install
## powarder" (one in a shell script, one in Nim), and only the shell script
## is what a fresh install actually runs. Instead, `powarder update`:
##
## 1. Figures out where the currently running binary lives
##    (`installDirFromExePath(expandFilename(getAppFilename()))`), so
##    install.sh overwrites *this* installation rather than falling back to
##    some default location like `/usr/local/bin`.
## 2. Picks `curl` (preferred) or `wget` (fallback) via `findExe`, exactly
##    the way a user's shell would resolve either command.
## 3. Runs `<downloader> <install.sh URL> | sh` through `std/osproc`, with
##    `POWARDER_INSTALL_DIR` (and, if `--to` was given, `POWARDER_VERSION`)
##    set as environment-variable assignments prefixed onto that same shell
##    command line — see `updateShellCommand`.
## 4. Passes install.sh's own exit code straight through as `powarder
##    update`'s exit code. It is *not* translated into `cli/dispatch`'s
##    `ExitCode` enum, since that enum only covers powarder's own semantics
##    (tunnel-not-found, config-invalid, etc.) and has nothing meaningful to
##    say about an arbitrary shell script's exit status.
##
## `update --check` is different: it never touches install.sh (which only
## knows how to *install*, not report on itself), and instead asks GitHub's
## REST API directly (`GET /repos/takumi3488/powarder/releases/latest`) for
## the latest tag, parses it with `std/json`, and compares it against
## `powarder/version.powarderVersion`.
##
## **Design split (mirrors `core/*` vs. the `cmdXxx` procs in
## `cli/dispatch.nim`)**: the functions in the first half of this file build
## strings/argv and touch no filesystem, network, or process state at all
## (`downloaderArgv`, `envAssignments`, `updateShellCommand`,
## `installDirFromExePath`, `normalizeVersion`, `isUpdateAvailable`,
## `parseTagName`) and are unit-tested directly in `tests/tupdate.nim`. The
## second half (`findDownloader`, `canWriteDir`, `daemonAppearsRunning`,
## `cmdUpdateCheck`, `cmdUpdateApply`, `cmdUpdate`) is the "actually do it"
## layer and is intentionally *not* covered by automated tests, since it
## either shells out to the network or inspects the real filesystem/daemon
## (see the test file's own doc comment for what is and isn't covered).
##
## **This module does not import `cli/dispatch`** (which would create a
## circular import, since `dispatch.nim` is the one that imports this module
## to wire up `of "update":`). That means the plain `int`s this module
## returns for its own pre-flight failures (no downloader found, install
## directory not writable, GitHub API unreachable) can't reference
## `dispatch.ExitCode` directly; they use the literal values `0` / `1`
## instead, documented below as mirroring `ecOk` / `ecGeneral`
## (a duplicate, manually-kept-in-sync value beats an import cycle).
## install.sh's own exit code (the common case) is passed through as-is and
## needs no such mapping at all.
##
## Following `platform/service`'s policy (`ServiceStatus.ssRunning` decides
## whether to print a "restart the daemon" hint, never to restart it
## automatically), this module never runs `powarder daemon restart` itself
## — only suggests it.

import std/[os, osproc, json, strutils, posix]
import powarder/version
import powarder/cli/argv
import powarder/cli/output
import powarder/ipc/client
import powarder/platform/service

const
  ecOkInt = 0      ## Mirrors `cli/dispatch.ecOk` (see the module doc comment).
  ecGeneralInt = 1 ## Mirrors `cli/dispatch.ecGeneral`.

  installScriptUrl* = "https://raw.githubusercontent.com/takumi3488/powarder/main/install.sh"
  latestReleaseApiUrl* = "https://api.github.com/repos/takumi3488/powarder/releases/latest"

  envInstallDir* = "POWARDER_INSTALL_DIR"
    ## The env var install.sh reads for where to place the binary.
  envVersion* = "POWARDER_VERSION"
    ## The env var install.sh reads for which release to install (omitted
    ## entirely when unset, so install.sh's own "latest" default applies).

  noDownloaderMsg =
    "powarder update requires curl or wget, but neither was found on PATH"

type
  Downloader* = enum
    dlCurl
    dlWget

# ---------------------------------------------------------------------------
# Pure functions (no I/O; unit-tested in tests/tupdate.nim)
# ---------------------------------------------------------------------------

proc installDirFromExePath*(exePath: string): string =
  ## Derives the install directory from the path `os.getAppFilename()`
  ## returns, so install.sh replaces *this* installation rather than some
  ## default location. Pure string manipulation (`os.parentDir`) — it is the
  ## caller's job to make `exePath` absolute first (`expandFilename` does
  ## filesystem I/O, so it stays out of this function; see `cmdUpdateApply`,
  ## which calls `expandFilename(getAppFilename())` before passing the
  ## result in here, the same idiom `dispatch.cmdDaemonInstall` already
  ## uses).
  ##
  ## Falls back to `"."` if `exePath` has no directory component at all
  ## (e.g. a bare `"powarder"`), which should not happen in practice once
  ## the caller has expanded it, but keeps this total rather than ever
  ## returning an empty string that could be misused as a path.
  let d = exePath.parentDir()
  if d.len == 0: "." else: d

proc downloaderArgv*(downloader: Downloader; url: string): seq[string] =
  ## The argv (not a shell string) that fetches `url` and writes the
  ## response body to stdout, staying silent on success. Used both to fetch
  ## install.sh (piped into `sh`; see `updateShellCommand`) and to fetch the
  ## GitHub releases API response for `--check` (see `cmdUpdateCheck`).
  ##
  ## `-fsSL` (curl): fail on HTTP errors (`-f`), silent (`-s`) but still show
  ## errors (`-S`), follow redirects (`-L`, needed since GitHub API/raw URLs
  ## redirect). `-qO-` (wget): quiet (`-q`), write to stdout (`-O-`).
  case downloader
  of dlCurl: @["curl", "-fsSL", url]
  of dlWget: @["wget", "-qO-", url]

proc envAssignments*(installDir, toVersion: string): seq[string] =
  ## The `VAR='value'` shell-assignment tokens to prefix onto the install.sh
  ## pipeline. `POWARDER_INSTALL_DIR` is always set. `POWARDER_VERSION` is
  ## set only when `toVersion` is non-empty (empty means "latest", which is
  ## install.sh's own default; explicitly setting it to an empty string
  ## could instead be read by install.sh as "the version named empty
  ## string", so we omit the variable entirely rather than pass `""`).
  ## Values are escaped with `os.quoteShell` so a path or version string
  ## containing whitespace or shell metacharacters can't break out of the
  ## assignment (mirrors `daemon/muxclient.nim`'s use of `quoteShell` for
  ## the same reason).
  result = @[envInstallDir & "=" & quoteShell(installDir)]
  if toVersion.len > 0:
    result.add envVersion & "=" & quoteShell(toVersion)

proc updateShellCommand*(installDir, toVersion: string; downloader: Downloader;
    url = installScriptUrl): string =
  ## The full command line executed via `/bin/sh -c` to perform the actual
  ## update: the env-var assignments from `envAssignments`, followed by
  ## "download install.sh, pipe it into `sh`" (`os.quoteShellCommand`,
  ## again mirroring `muxclient.nim`, escapes the downloader's own argv).
  ##
  ## Building this as one plain string (rather than passing the env
  ## overrides through `osproc.startProcess`'s `env:` parameter) keeps the
  ## whole command reproducible and directly comparable with `==` in tests,
  ## without having to snapshot-and-diff an entire environment table.
  let pipeline = quoteShellCommand(downloaderArgv(downloader, url)) & " | sh"
  (envAssignments(installDir, toVersion) & @[pipeline]).join(" ")

proc normalizeVersion*(v: string): string =
  ## Strips surrounding whitespace and one leading `v`/`V`, so `"v1.2.3"`,
  ## `"V1.2.3"`, and `"1.2.3"` all normalize to `"1.2.3"`. `powarderVersion`
  ## (from `powarder.nimble`'s `version`) never has a `v` prefix, but GitHub
  ## release tags (per the repository's `v<nimble version>` convention) do,
  ## so this is what lets the two be compared directly.
  var s = v.strip()
  if s.len > 0 and (s[0] == 'v' or s[0] == 'V'): s = s[1 .. ^1]
  s

proc isUpdateAvailable*(currentVersion, latestTag: string): bool =
  ## Whether the (normalized) latest release tag differs from the
  ## (normalized) currently running version.
  ##
  ## This is a plain **inequality** check, not a semver-ordering comparison.
  ## install.sh always installs whatever GitHub calls "latest" (there is no
  ## concept of "downgrade" wired up), so `powarder update --check` only
  ## needs to answer "is there something different available", not "is it
  ## numerically newer".
  normalizeVersion(currentVersion) != normalizeVersion(latestTag)

proc parseTagName*(body: string): string =
  ## Extracts `tag_name` from a GitHub "get the latest release" API response
  ## body. Raises `ValueError` (either from `std/json`'s own parse failure,
  ## or explicitly here if the shape doesn't match) so callers can report
  ## "couldn't determine the latest version" without a raw JSON stack trace
  ## leaking into the CLI's output.
  let node = parseJson(body)
  if node.kind != JObject or not node.hasKey("tag_name") or
      node["tag_name"].kind != JString:
    raise newException(ValueError,
        "unexpected response from the GitHub releases API " &
        "(no \"tag_name\" field)")
  node["tag_name"].getStr

# ---------------------------------------------------------------------------
# Execution (I/O: PATH lookups, filesystem, network, subprocess)
# ---------------------------------------------------------------------------

proc findDownloader(): Downloader =
  ## Picks curl if available, else wget. Raises `ValueError` if neither is
  ## on `PATH`. Uses `os.findExe` (a pure PATH search, per the task's
  ## requirement) rather than trying to invoke either command speculatively.
  if findExe("curl").len > 0: dlCurl
  elif findExe("wget").len > 0: dlWget
  else: raise newException(ValueError, noDownloaderMsg)

proc canWriteDir(dir: string): bool =
  ## Whether the current user can write into `dir`, checked via POSIX
  ## `access()` (`W_OK`). This intentionally does not reimplement
  ## `core/paths.isUsableDir`'s manual `lstat` + uid/mode comparison: that
  ## helper additionally guards against symlink takeover for powarder's own
  ## runtime directory, a concern that doesn't apply here (an install
  ## directory is expected to be a normal, possibly shared, location like
  ## `/usr/local/bin`), and `access()` already accounts for group membership
  ## and ACLs the same way install.sh's own `mv` will when it actually tries
  ## to write there.
  access(dir.cstring, W_OK) == 0

proc runCapture(argv: seq[string]): tuple[output: string; exitCode: int] =
  ## Runs `argv` and captures combined stdout+stderr. Mirrors
  ## `platform/service_darwin.runLaunchctl`'s pattern of falling back to
  ## `(e.msg, -1)` if the process can't even be started (e.g. the binary
  ## vanished from PATH between `findExe` and now).
  try:
    execCmdEx(quoteShellCommand(argv))
  except OSError as e:
    (e.msg, -1)

proc daemonAppearsRunning(): bool =
  ## Best-effort "is the daemon alive right now" check, used only to decide
  ## whether to print a "run `powarder daemon restart`" hint after a
  ## successful update (never to restart it automatically).
  ##
  ## Checks two independent signals, since either can be true depending on
  ## how the daemon was started:
  ## - `ipc/client.ping()`: the daemon process itself is alive right now,
  ##   regardless of whether it was ever registered as an OS service (e.g.
  ##   autostarted, or started via `powarder daemon start`). Never raises.
  ## - `platform/service.serviceStatus()`: the daemon is registered as a
  ##   launchd/systemd service and that service reports itself as running.
  ##   Raises `OSError` on an unsupported OS (or if the underlying
  ##   `launchctl`/`systemctl` call fails), in which case we just fall back
  ##   to the `ping()` result alone.
  if ping():
    return true
  try:
    serviceStatus().status == ssRunning
  except OSError:
    false

# ---------------------------------------------------------------------------
# update --check
# ---------------------------------------------------------------------------

proc cmdUpdateCheck(w: Writer): int =
  ## Reports whether an update is available, without installing anything.
  ## install.sh has no "check" mode of its own, so this talks to GitHub's
  ## releases API directly (see the module doc comment).
  let downloader =
    try:
      findDownloader()
    except ValueError as e:
      echo w.failure(e.msg)
      return ecGeneralInt

  let (body, exitCode) = runCapture(downloaderArgv(downloader,
      latestReleaseApiUrl))
  if exitCode != 0:
    echo w.failure("failed to check for updates: " & body.strip())
    return ecGeneralInt

  let latestTag =
    try:
      parseTagName(body)
    except ValueError as e:
      echo w.failure("failed to check for updates: " & e.msg)
      return ecGeneralInt

  let available = isUpdateAvailable(powarderVersion, latestTag)
  let latest = normalizeVersion(latestTag)

  if w.mode == omJson:
    echo (%*{
      "current_version": powarderVersion,
      "latest_version": latest,
      "update_available": available,
    }).pretty()
    return ecOkInt

  if available:
    echo w.info("update available: " & powarderVersion & " -> " & latest &
        " (run 'powarder update' to install it)")
  else:
    echo w.success("already up to date (" & powarderVersion & ")")
  ecOkInt

# ---------------------------------------------------------------------------
# update (the actual install, delegated to install.sh)
# ---------------------------------------------------------------------------

proc reportApplyResult(w: Writer; exitCode: int; daemonRunning: bool) =
  if w.mode == omJson:
    echo (%*{
      "success": exitCode == 0,
      "exit_code": exitCode,
      "daemon_running": daemonRunning,
    }).pretty()
    return
  if exitCode == 0:
    echo w.success("update complete")
    if daemonRunning:
      echo w.info("run 'powarder daemon restart' to apply the update")
  else:
    echo w.failure("update failed (install.sh exited with code " & $exitCode & ")")

proc cmdUpdateApply(args: ParsedArgs; w: Writer): int =
  let downloader =
    try:
      findDownloader()
    except ValueError as e:
      echo w.failure(e.msg)
      return ecGeneralInt

  let exe = expandFilename(getAppFilename())
  let installDir = installDirFromExePath(exe)

  if not canWriteDir(installDir):
    echo w.failure("no write permission to " & installDir)
    echo w.info(
      "re-run with sudo, or set POWARDER_INSTALL_DIR to a writable " &
      "directory and install manually")
    return ecGeneralInt

  let cmd = updateShellCommand(installDir, args.toVersion, downloader)

  # `install.sh` itself streams progress/verification messages, so the
  # child inherits the parent's stdio directly rather than going through
  # pipes (see `daemon/muxclient.nim`'s module doc comment for the deadlock
  # that capturing both stdout and stderr via pipes can cause; inheriting
  # the parent's streams sidesteps that entirely, and lets the user watch
  # install.sh's own output live).
  var exitCode: int
  let process = startProcess("/bin/sh", args = ["-c", cmd],
      options = {poParentStreams})
  try:
    exitCode = process.waitForExit()
  finally:
    process.close()

  let daemonRunning = daemonAppearsRunning()
  reportApplyResult(w, exitCode, daemonRunning)
  # install.sh's own exit code is passed straight through (see the module
  # doc comment for why this isn't mapped through `cli/dispatch.ExitCode`).
  exitCode

proc cmdUpdate*(args: ParsedArgs; w: Writer): int =
  ## Entry point called from `cli/dispatch.dispatch()`.
  if args.checkOnly: cmdUpdateCheck(w)
  else: cmdUpdateApply(args, w)
