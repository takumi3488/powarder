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
import powarder/platform/lock
import powarder/core/paths

proc ensureDaemon*(noAutostart = false; timeoutMs = 5000): bool =
  ## Starts the daemon if it isn't running, and polls until it comes up.
  ##
  ## Steps:
  ## 1. Check whether it's alive via `ipc/client.ping()`. If alive, return
  ##    `true` immediately.
  ## 2. If `noAutostart` is true, give up here and return `false` (this is the
  ##    actual behavior behind the `--no-autostart` flag).
  ## 3. Wait for the singleton lock to be free
  ##    (`platform/lock.isSingletonLockFree(lockPath())`), probing every 100ms
  ##    for at most `timeoutMs`. This phase can also succeed without spawning:
  ##    if a daemon comes up on its own meanwhile (a racing `ensureDaemon`
  ##    won), return `true` immediately. If the lock is still held when the
  ##    budget runs out, return the result of one final `ping()` — the lock
  ##    being held only means "don't spawn" (spawning would just add another
  ##    `the daemon is already running (lock: ...)` line to the log), and it
  ##    says nothing about whether some daemon is already reachable.
  ##    **Why the lock and not the socket**: `daemon/run.shutdown` closes the
  ##    IPC socket first and releases the singleton lock last, spending
  ##    seconds inside `teardownAll()` in between — a shutting-down daemon has
  ##    no socket but still holds the lock. A child spawned into that window
  ##    fails `tryAcquireSingletonLock` instantly and exits `exitAlreadyRunning`
  ##    (7), and we would then burn the whole poll budget on a socket that
  ##    will never appear. The fcntl lock is the authoritative gate for
  ##    starting a new daemon (`platform/lock.nim`); the socket only tells us
  ##    whether the daemon is accepting RPCs.
  ## 4. Start the daemon via
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
  ## 5. Poll `ping()` every 100ms, waiting up to `timeoutMs`.
  ## 6. Return `true` once startup is confirmed, or `false` on timeout.
  ##
  ## **Phase 1 (wait for the lock) and phase 2 (spawn + poll) each get the
  ## full `timeoutMs` rather than splitting one budget.** They wait for two
  ## different events — an old daemon going away (lock released) versus a new
  ## one coming up (socket accepting). Collapsing them into a single budget
  ## would let a slow shutdown starve the spawn poll down to zero and report
  ## failure for a daemon that was about to appear. In the common case — no
  ## daemon running, lock free — phase 1 costs exactly one extra probe and no
  ## extra sleep, so nothing gets slower.
  ##
  ## The lock probes are safe here because the CLI process never holds the
  ## lock itself; the daemon (which does) must never call them (the trap is
  ## documented at the top of `platform/lock.nim`).
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

  # **Phase 1: wait for the singleton lock to be free before spawning.** A
  # still-shutting-down daemon has already removed its IPC socket but not yet
  # released the lock (`daemon/run.shutdown` closes the socket first and
  # releases the lock last), so spawning now would only produce a child that
  # exits `exitAlreadyRunning` (7) and we would wait the whole budget for a
  # socket that will never appear. The lock is the authoritative gate; the
  # socket is only reachability. See step 3 in the doc comment above.
  #
  # The loop condition is the observed lock state, not the elapsed counter, and
  # the first probe happens before any sleep. That keeps `timeoutMs <= 0`
  # meaning "probe exactly once" instead of "never probe, always fail": the
  # lock is always observed at least once, and if it is still held when the
  # budget is exhausted the loop simply falls through to the final `ping()`
  # below.
  let pollIntervalMs = 100
  var lockWaited = 0
  var lockFree = isSingletonLockFree(lockPath())
  while not lockFree and lockWaited < timeoutMs:
    if ping():
      return true ## A racing ensureDaemon brought the daemon up; nothing to spawn.
    os.sleep(pollIntervalMs)
    lockWaited += pollIntervalMs
    lockFree = isSingletonLockFree(lockPath())
  if not lockFree:
    # Lock still held; spawning would just add another "already running" line.
    # But the lock being held is only a reason not to SPAWN — it says nothing
    # about reachability: another process's daemon (or a racing
    # `ensureDaemon`) may have become reachable inside the final poll interval,
    # after the loop's last `ping()`. So the honest answer to "is a daemon
    # available?" is one more ping rather than a flat false, which also
    # guarantees we never spawn while the lock is held.
    return ping()

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

  # **Phase 2: poll until the freshly spawned daemon comes up.**
  var waited = 0
  while waited < timeoutMs:
    os.sleep(pollIntervalMs)
    waited += pollIntervalMs
    if ping():
      return true
  false
