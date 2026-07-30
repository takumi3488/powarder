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
