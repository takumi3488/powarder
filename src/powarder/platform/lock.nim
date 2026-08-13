## Preventing multiple daemon instances (singleton lock).
##
## Rather than a PID file, use an `fcntl` advisory lock (`F_SETLK` /
## `F_WRLCK`) as the primary mechanism for detecting multiple launches. The
## PID file approach has classic weaknesses:
## - the file survives after the process dies via SIGKILL (a stale file)
## - false positives from PID reuse (a different process happens to get the
##   same PID)
## but an `fcntl` advisory lock is **automatically released by the kernel**
## once the process holding it terminates (even via SIGKILL), so a stale
## state can never occur in principle.
##
## A Nim binding for `flock(2)` does not exist in the standard library, but
## `fcntl` and the `F_SETLK` / `F_WRLCK` / `Tflock` structure are available
## in `std/posix`, so those are used instead.
##
## **Important caveat (the fcntl lock trap)**: POSIX fcntl record locks are
## managed "per process." Therefore, if the same process opens the same
## file again through a different fd while holding the lock, and **closes
## even just one of the two fds, every lock that process holds on that
## file gets released** (it does not matter whether the fd used for the
## close is the one that was used to acquire the lock). Consequently, while
## holding the lock, you must not perform a separate open/close on that
## lock file through another path such as `readPid`. `readPid` is intended
## to be used from "a different process that does not hold this lock" to
## peek at the state (`writePid` writes using the held `lock.fd` directly,
## so it does not fall into this trap).

import std/[options, posix, os, strutils]

type
  SingletonLock* = object
    fd*: FileHandle
    path*: string

  SingletonLockError* = object of CatchableError
    ## Raised by `acquireSingletonLock` when another process already holds
    ## the lock and it could not be acquired.

proc isHeldByOther(errCode: OSErrorCode): bool =
  ## The errno returned when `F_SETLK` conflicts with an existing lock.
  ## POSIX leaves it implementation-defined which one is returned, so both
  ## are checked.
  cint(errCode) == EACCES or cint(errCode) == EAGAIN

proc tryAcquireSingletonLock*(path: string): Option[SingletonLock] =
  ## Attempts to acquire an advisory lock (exclusive, whole file) on `path`.
  ##
  ## - Acquired: `Some(SingletonLock)`.
  ## - Already held by another process (errno is `EACCES` / `EAGAIN`):
  ##   `none`.
  ## - Any other failure (open fails, fcntl returns some other error, etc.):
  ##   raises `OSError`.
  let fd = posix.open(path.cstring, O_CREAT or O_RDWR, 0o600)
  if fd < 0:
    raiseOSError(osLastError(), path)

  var fl: Tflock
  fl.l_type = F_WRLCK.cshort
  fl.l_whence = SEEK_SET.cshort
  fl.l_start = 0
  fl.l_len = 0 # 0 means the whole file

  if fcntl(fd, F_SETLK, addr fl) == -1:
    let err = osLastError()
    discard close(fd)
    if isHeldByOther(err):
      return none(SingletonLock)
    raiseOSError(err, path)

  some(SingletonLock(fd: fd, path: path))

proc acquireSingletonLock*(path: string): SingletonLock =
  ## A wrapper around `tryAcquireSingletonLock` that raises
  ## `SingletonLockError` when the lock could not be acquired.
  let got = tryAcquireSingletonLock(path)
  if got.isNone:
    raise newException(SingletonLockError,
      "already running: another process holds the lock at " & path)
  got.get

proc release*(lock: SingletonLock) =
  ## Releases the lock and closes the fd.
  ##
  ## Idempotent: does not raise even for an already-closed fd (`fd < 0`, or
  ## when `release` is called twice). `close(2)` simply returns -1 for an
  ## invalid fd, so it is fine to call and discard the result.
  if lock.fd >= 0:
    discard close(lock.fd)

proc queryLock(path: string): tuple[free: bool, holder: int] =
  ## One `F_GETLK` probe of `path`: `free` is true when no OTHER process
  ## holds the singleton lock (or when the query itself failed), and
  ## `holder` is the pid the kernel reported in `l_pid` (0 when free or on
  ## failure). The rationale for `F_GETLK` over a try-acquire probe, and
  ## the per-process caveat, live on `isSingletonLockFree` below.
  let fd = posix.open(path.cstring, O_CREAT or O_RDWR, 0o600)
  if fd < 0:
    return (true, 0)
  var fl: Tflock
  fl.l_type = F_WRLCK.cshort
  fl.l_whence = SEEK_SET.cshort
  fl.l_start = 0
  fl.l_len = 0 # 0 means the whole file, same convention as tryAcquireSingletonLock
  let rc = fcntl(fd, F_GETLK, addr fl)
  discard close(fd)
  if rc == -1:
    return (true, 0)
  if fl.l_type == F_UNLCK:
    (true, 0)
  else:
    (false, int(fl.l_pid))

proc isSingletonLockFree*(path: string): bool =
  ## Whether a new daemon may start right now: a single `F_GETLK` probe of
  ## whether any OTHER process holds the singleton fcntl lock on `path`.
  ##
  ## This lock — not the IPC socket — is the authoritative gate for "may a
  ## new daemon start". `daemon/run.shutdown` closes the IPC socket first,
  ## so `ipc/client.ping()` starts failing immediately, but releases this
  ## lock only at the very end, after `reg.teardownAll()` has stopped every
  ## forward and ssh ControlMaster, which takes seconds when tunnels are
  ## up. Anything that waits on `ping()` and then spawns a fresh daemon
  ## fires into the window where `runDaemon` cannot acquire the lock and
  ## exits `exitAlreadyRunning` (7); the lock being free is the one
  ## condition that makes the spawn safe.
  ##
  ## **Why `F_GETLK` and not a try-acquire probe.** A try-acquire probe
  ## (what this proc used to do) answers the question by momentarily
  ## BECOMING the holder, so for the microseconds it holds the lock every
  ## other process is told "held" — including a real daemon sitting in
  ## `runDaemon`'s `tryAcquireSingletonLock`, which does not retry and
  ## exits `exitAlreadyRunning` (7). A pre-flight check that can cause the
  ## very failure it exists to prevent is the wrong primitive. `F_GETLK`
  ## instead asks the kernel whether this lock WOULD conflict, and acquires
  ## nothing: no `F_SETLK`, no window in which the answer is wrong, and no
  ## interaction with a concurrent acquire. This also removed a measured
  ## flake in the fork-based tests, where the parent's probe stole the lock
  ## from the child's single acquire in ~0.2-0.7% of trials (22/3000 and
  ## 5/3000 with the probe, 0/3000 without it).
  ##
  ## **Never call this from a process that already holds this lock.** POSIX
  ## `F_GETLK` ignores locks held by the CALLING process, so a process that
  ## holds the singleton lock is told the lock is FREE — a false "free"
  ## rather than the stolen-lock hazard of the old probe, but wrong in the
  ## same direction. Opening the file through a fresh fd also trips the
  ## per-process trap documented in the module header above (lines 17-27)
  ## for `readPid`: closing that fd releases every lock the process holds
  ## on the file. Callers are CLI processes only, which never hold the
  ## lock; the daemon must never call this proc.
  ##
  ## A failed `open` or failed `fcntl` counts as **free** and never
  ## propagates: nothing can hold a lock on a file that cannot even be
  ## opened, every caller creates the runtime directory in its very next
  ## step anyway, and treating failure as "held" or raising would turn this
  ## optional pre-flight check into a new failure mode of its own.
  queryLock(path).free

proc lockHolderPid*(path: string): Option[int] =
  ## The pid `F_GETLK` reports as holding the singleton lock on `path`, or
  ## `none` when the lock is free, the query failed, or `l_pid` is
  ## meaningless (0 or negative).
  ##
  ## **Diagnostic only.** It exists so CLI error messages can name who is
  ## holding the lock when a wait times out; exclusion decisions are still
  ## the kernel's, made by `F_SETLK` in `tryAcquireSingletonLock`. The pid
  ## can be stale the instant it is read (the holder may have exited and
  ## released the lock), so never branch control flow on it.
  ##
  ## Same caller restriction as `isSingletonLockFree`: CLI processes only,
  ## never a process that already holds this lock.
  let q = queryLock(path)
  if q.free or q.holder <= 0:
    none(int)
  else:
    some(q.holder)

proc writePid*(lock: SingletonLock; pid: int) =
  ## Writes `pid` into the lock file.
  ##
  ## **This is nothing more than auxiliary information for humans /
  ## debugging.** The determination of multiple launches is authoritatively
  ## made by the `fcntl` advisory lock alone; the PID value written here is
  ## never itself used for exclusion control (it exists only so that
  ## peeking with `cat` etc. immediately shows "who currently holds the
  ## lock").
  ##
  ## Writes via `pwrite`/`ftruncate` on the already-open `lock.fd` (does not
  ## `open` it again. As noted at the top of the module, opening the same
  ## file through a different fd while holding the lock and then closing it
  ## would release the lock along with it).
  let payload = $pid & "\n"
  discard ftruncate(lock.fd, 0.Off)
  discard pwrite(lock.fd, payload.cstring, payload.len, 0.Off)

proc readPid*(path: string): Option[int] =
  ## Reads the PID written in the lock file.
  ##
  ## **Not used to determine multiple launches** (that is the fcntl lock's
  ## responsibility). This is strictly for human-facing display /
  ## debugging. Returns `none` if the file does not exist or its contents
  ## cannot be parsed as a number.
  ##
  ## If the caller already holds this lock, as noted at the top of the
  ## module, this call (which internally opens a new fd and then closes it)
  ## will release the lock itself. It is intended to be used from a
  ## different process that does not hold the lock.
  if not fileExists(path):
    return none(int)
  try:
    let content = readFile(path).strip()
    if content.len == 0:
      return none(int)
    some(parseInt(content))
  except CatchableError:
    none(int)
