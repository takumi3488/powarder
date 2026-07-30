## Resolution of config, state, and runtime directories.
##
## UDS paths must fit within `sockaddr_un.sun_path`'s length limit (104 bytes
## on macOS / 108 on Linux). Since powarder places both the ControlPath and
## the forward UDS in the runtime directory, the directory name is kept to 1
## character and the filename to 8 hex digits; if it still doesn't fit, it
## falls back to `/tmp/powarder-<uid>`.
##
## This module touches environment variables and the filesystem, so it is not
## pure. During tests, isolate it by overriding `POWARDER_CONFIG` /
## `POWARDER_RUNTIME_DIR` / `XDG_*`.

import std/[os, posix, strutils]

const
  appName* = "powarder"

  maxSunPath* = 104
    ## macOS's `sockaddr_un.sun_path` is 104 bytes. Linux is 108, but we
    ## follow the stricter limit.

  envConfig* = "POWARDER_CONFIG"
  envRuntimeDir* = "POWARDER_RUNTIME_DIR"
  envStateDir* = "POWARDER_STATE_DIR"

  ctlSubdir* = "c" ## Where the ControlPath lives. 1 character to save sun_path space
  fwdSubdir* = "f" ## Where the forward UDS lives

func expandHome(p: string): string =
  if p.startsWith("~/"): getHomeDir() / p[2 .. ^1] else: p

# ---------------------------------------------------------------- Config / state

proc configDir*(): string =
  let xdg = getEnv("XDG_CONFIG_HOME")
  if xdg.len > 0: expandHome(xdg) / appName
  else: getHomeDir() / ".config" / appName

proc configFile*(): string =
  ## Prefers `POWARDER_CONFIG` if set.
  let override = getEnv(envConfig)
  if override.len > 0: expandHome(override) else: configDir() / "config.json"

proc localConfigFile*(): string =
  ## The project-local config in the current directory. Only `up` / `down` look for this.
  getCurrentDir() / (appName & ".json")

proc stateDir*(): string =
  let override = getEnv(envStateDir)
  if override.len > 0: return expandHome(override)
  let xdg = getEnv("XDG_STATE_HOME")
  if xdg.len > 0: expandHome(xdg) / appName
  else: getHomeDir() / ".local" / "state" / appName

proc stateFile*(): string = stateDir() / "state.json"
proc logsDir*(): string = stateDir() / "logs"
proc tunnelLogPath*(name: string): string = logsDir() / (name & ".log")
proc daemonLogPath*(): string = logsDir() / "daemon.log"

# -------------------------------------------------------------- Runtime

proc isUsableDir(p: string): bool =
  ## Is this a directory we own and that others can't write to?
  ## Verifies owner and permissions to guard against symlink-based takeover.
  if not dirExists(p): return false
  var st: Stat
  if lstat(p.cstring, st) != 0: return false
  if not S_ISDIR(st.st_mode): return false
  if st.st_uid != getuid(): return false
  (st.st_mode.cint and 0o077) == 0

proc socketExists*(path: string): bool =
  ## Whether the path exists as a unix domain socket.
  ##
  ## **Do not use `os.fileExists`.** It only returns true for `S_ISREG`
  ## (regular files), so it always returns false for a socket. Getting this
  ## wrong when waiting for the ControlPath to appear (readiness check) or
  ## when detecting a leftover forward UDS produces the hard-to-notice bug of
  ## "the socket exists but we judge it doesn't, and wait forever".
  ##
  ## `os.removeFile` can be used as-is to remove a leftover file (internally
  ## it's `unlink`, which doesn't error if the target is absent, so it's fine
  ## to call without an existence check first).
  var st: Stat
  if lstat(path.cstring, st) != 0: return false
  S_ISSOCK(st.st_mode)

proc longestSocketPath(runtime: string): string =
  ## The longest UDS path that can be generated in that runtime directory. Used for length validation.
  runtime / fwdSubdir / repeat('0', 8)

proc runtimeDirCandidates(): seq[string] =
  let override = getEnv(envRuntimeDir)
  if override.len > 0:
    return @[expandHome(override)]

  when defined(linux):
    let xdgRun = getEnv("XDG_RUNTIME_DIR")
    if xdgRun.len > 0 and isUsableDir(xdgRun):
      result.add xdgRun / appName
  else:
    # macOS has no equivalent standard to XDG_RUNTIME_DIR, but $TMPDIR is
    # user-exclusive with mode 0700, so it serves as a substitute.
    let tmp = getEnv("TMPDIR")
    if tmp.len > 0:
      result.add tmp.strip(chars = {'/'}, leading = false) / appName

  result.add "/tmp" / (appName & "-" & $getuid())

proc runtimeDir*(): string =
  ## The runtime directory actually used. Looks at the candidates in order and
  ## picks **the first one whose UDS path fits within sun_path**.
  let candidates = runtimeDirCandidates()
  for c in candidates:
    if longestSocketPath(c).len < maxSunPath:
      return c
  # If none fit, return the last candidate (the /tmp-based one). The caller
  # validates via ensureRuntimeDir() and fails explicitly.
  candidates[^1]

proc ipcSocketPath*(): string = runtimeDir() / (appName & ".sock")
proc lockPath*(): string = runtimeDir() / (appName & ".lock")
proc pidPath*(): string = runtimeDir() / (appName & ".pid")

proc controlPath*(fingerprint: string): string =
  ## The ControlMaster's control socket. Uses only the first 8 characters of the fingerprint.
  runtimeDir() / ctlSubdir / fingerprint[0 ..< min(8, fingerprint.len)]

proc forwardSocketPath*(basename: string): string =
  ## The forward UDS ssh sets up. `basename` is the result of forwardspec.udsBasename().
  runtimeDir() / fwdSubdir / basename

# ------------------------------------------------------------------ Creation

proc ensureDir0700(p: string) =
  createDir(p)
  setFilePermissions(p, {fpUserRead, fpUserWrite, fpUserExec})

proc ensureRuntimeDir*() =
  ## Sets up the runtime directory tree with mode 0700.
  ## Fails explicitly here if the UDS path doesn't fit within sun_path.
  let rt = runtimeDir()
  let longest = longestSocketPath(rt)
  if longest.len >= maxSunPath:
    raise newException(IOError,
      "runtime directory path is too long for a unix socket (" & $longest.len &
      " >= " & $maxSunPath & "): " & rt &
      " — set " & envRuntimeDir & " to a shorter path")
  ensureDir0700(rt)
  ensureDir0700(rt / ctlSubdir)
  ensureDir0700(rt / fwdSubdir)

proc ensureStateDirs*() =
  ensureDir0700(stateDir())
  ensureDir0700(logsDir())

proc ensureConfigDir*() =
  ensureDir0700(configDir())
