## Autostart logic that makes the daemon feel like "ambient" infrastructure.
##
## Docker doesn't autostart `dockerd` behind the scenes when you run `docker
## run`, because `dockerd` is a privileged, multi-user daemon running as root,
## and it shouldn't be started casually. The powarder daemon is just a local
## process confined to a single user on a single machine, so that constraint
## doesn't apply. The experience we're aiming for is tailscale's (you just run
## `tailscale up`, and whether `tailscaled` is alive behind the scenes is
## barely something the user has to think about), and `ensureDaemon` is the
## heart of that.

import std/os
import powarder/ipc/client
import powarder/platform/daemonize
import powarder/core/paths

proc ensureDaemon*(noAutostart = false; timeoutMs = 5000): bool =
  ## Starts the daemon if it isn't running, and polls until it comes up.
  ##
  ## Steps:
  ## 1. Check whether it's alive via `ipc/client.ping()`. If alive, return
  ##    `true` immediately.
  ## 2. If `noAutostart` is true, give up here and return `false` (this is the
  ##    actual behavior behind the `--no-autostart` flag).
  ## 3. Start the daemon via
  ##    `platform/daemonize.spawnDetached(exe, ["daemon"])`, using our own
  ##    executable path (`os.getAppFilename()`). The only argument is
  ##    `["daemon"]`; `"--foreground"` is not appended.
  ##    **Why**: `argv.nim` doesn't define a `--foreground` flag at all (it
  ##    would become an unknown flag, raising `ArgvError`, and the freshly
  ##    spawned child would exit immediately). On the other hand,
  ##    `argv.parseArgv(["daemon"])` produces `subcommand == "daemon"`,
  ##    `subsubcommand == ""`, and `dispatch` interprets that as "the daemon
  ##    subsubcommand is empty, so start the daemon itself in the foreground"
  ##    (see `cli/dispatch.nim`). In other words, `["daemon"]` alone is enough
  ##    to take the intended startup path.
  ## 4. Poll `ping()` every 100ms, waiting up to `timeoutMs`.
  ## 5. Return `true` once startup is confirmed, or `false` on timeout.
  ##
  ## **Do not mistake `spawnDetached`'s return value (the intermediate
  ## process's PID) for the daemon's PID.** It's the PID of the intermediate
  ## process from the double fork, and by the time `spawnDetached` returns it
  ## has already been `waitpid`'d and no longer exists. To find the daemon's
  ## actual PID, read it via `platform/lock.readPid(paths.lockPath())` (from a
  ## different process that does not hold this lock).
  ##
  ## **Why `spawnDetached()` instead of `daemonize()`**: the daemon uses
  ## `std/asyncdispatch` (which listens for the IPC server via
  ## `newAsyncSocket`). If `fork()` happens **after** asyncdispatch has already
  ## touched an event notification mechanism like kqueue/epoll, the kqueue fd
  ## inherited by the child process ends up broken (empirically verified on
  ## macOS), and subsequent `accept()` calls fail with "Bad file descriptor".
  ## `daemonize()` daemonizes "the calling process itself" via a double fork,
  ## so it runs into this problem. `spawnDetached()`, on the other hand,
  ## replaces the entire process image via `execvp()` at the end of a double
  ## fork, so the grandchild process starts from a clean state that has never
  ## touched asyncdispatch. Therefore, rather than daemonizing the CLI process
  ## itself, the daemon must be started **as a new process**.
  if ping():
    return true
  if noAutostart:
    return false

  let exe = getAppFilename()

  # **The daemon's stdout/stderr must always be redirected to a log file.**
  # Without redirecting them, the spawned daemon keeps running while still
  # inheriting the CLI's stdout/stderr, so if it's captured via a pipe or
  # command substitution like `powarder up | tee log` or `$(powarder ps)`,
  # **the write end of the pipe never closes, and the shell waits forever even
  # though the CLI itself has already exited** (hit this empirically).
  # `open` fails if the directory doesn't exist, so create it first.
  try:
    ensureStateDirs()
  except CatchableError:
    discard ## Even if this fails, spawnDetached falls back to /dev/null
  discard spawnDetached(exe, ["daemon"], daemonLogPath())

  let pollIntervalMs = 100
  var waited = 0
  while waited < timeoutMs:
    os.sleep(pollIntervalMs)
    waited += pollIntervalMs
    if ping():
      return true
  false
