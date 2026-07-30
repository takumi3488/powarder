## Backgrounding (daemonization).
##
## Used when the CLI detects that the daemon is not running, to launch a daemon
## process itself and detach it from the terminal. `daemonize()` daemonizes
## "the calling process itself" via a double fork. `spawnDetached()` launches
## "a separate executable" fully detached (the calling CLI process itself
## keeps running as-is).

import std/[os, posix]

proc daemonize*(keepCwd = false) =
  ## Detach from the terminal via a double fork + `setsid()`. **The parent
  ## process (and the intermediate process that becomes the session leader)
  ## calls `quit(0)` and never returns.** The caller must write its code on
  ## the assumption that "if this call returns, it is the grandchild process
  ## left after the double fork."
  ##
  ## Steps:
  ## 1. First `fork()`. The parent exits via `quit(0)`. The child calls
  ##    `setsid()` and becomes the leader of a new session with no
  ##    controlling terminal.
  ## 2. Second `fork()`. The session leader itself exits via `quit(0)`. The
  ##    remaining grandchild becomes a process that is "not a session
  ##    leader," so it can never acquire a controlling terminal again through
  ##    any path (on SVr4-family OSes, when a session leader opens a terminal
  ##    device it automatically becomes its controlling terminal; the purpose
  ##    of the double fork is to structurally block this path).
  ## 3. `umask(0)`: avoid being affected by an inherited file creation mask.
  ## 4. `chdir("/")` (skipped when `keepCwd` is true): give up the current
  ##    directory so the daemon process's existence does not block
  ##    unmounting the filesystem.
  ## 5. Redirect fd 0/1/2 to `/dev/null`, leaving no reads/writes to the
  ##    terminal at all.
  let pid1 = fork()
  if pid1 < 0:
    raiseOSError(osLastError(), "fork (1st)")
  if pid1 > 0:
    quit(0)

  if setsid() < 0:
    raiseOSError(osLastError(), "setsid")

  let pid2 = fork()
  if pid2 < 0:
    raiseOSError(osLastError(), "fork (2nd)")
  if pid2 > 0:
    quit(0)

  discard umask(0)
  if not keepCwd:
    discard chdir("/")

  let devNull = posix.open("/dev/null", O_RDWR)
  if devNull >= 0:
    discard dup2(devNull, 0)
    discard dup2(devNull, 1)
    discard dup2(devNull, 2)
    if devNull > 2:
      discard close(devNull)

proc spawnDetached*(exePath: string; args: openArray[string];
                    logPath = ""): int =
  ## Launch `exePath` with `args`, fully detached from the caller.
  ##
  ## Internally performs a double fork, and the "grandchild process" that
  ## finally execs `exePath` is adopted by init (PID 1, or launchd on
  ## macOS), so it keeps running even after the calling process exits,
  ## without being dragged down with it.
  ##
  ## **Always pass `logPath` (falls back to `/dev/null` if empty).**
  ## If fd 0/1/2 are not redirected before the exec, the launched daemon
  ## **keeps running while inheriting the calling CLI's stdout/stderr**. Then
  ## when received via a pipe or command substitution such as
  ## `powarder up | tee log` or `$(powarder ps)`,
  ## **the write end of the pipe never closes, so the reader can never
  ## detect EOF, and the shell waits forever even though the CLI itself has
  ## already exited** (empirically verified — this was actually hit).
  ##
  ## This redirection cannot be designed to be delegated to `daemonize()` on
  ## the `exePath` side. Because powarder's daemon uses asyncdispatch, it
  ## follows a policy of not calling `daemonize()` in order to avoid the
  ## issue where "calling `fork()` after touching asyncdispatch corrupts the
  ## child's kqueue fd," which means **there is no longer anyone left to do
  ## the redirection**. That is why it is done here (right before the exec,
  ## after the fork).
  ##
  ## **The return value is the PID of the "intermediate process," and does
  ## not match the PID of the daemon that is ultimately launched.** This
  ## constraint arises because we are here deliberately using, in reverse,
  ## the same mechanism as the problem where `ssh -f` or `ControlPersist`
  ## slip out of `startProcess` tracking due to a double fork (a behavior
  ## that powarder deliberately avoids elsewhere). The intermediate process
  ## exits immediately after launching the grandchild and has already been
  ## reaped via `waitpid` before this procedure returns, so the returned PID
  ## **points to a process that no longer exists**. If you need to know the
  ## daemon's actual PID, read the value the daemon side wrote to the lock
  ## file with `lock.writePid()` via `lock.readPid()` instead (do not trust
  ## this return value as a PID).
  let pid1 = fork()
  if pid1 < 0:
    raiseOSError(osLastError(), "fork (1st)")

  if pid1 == 0:
    # Intermediate process. Using quit() here would also run the Nim
    # runtime's exit-time processing (GC / atexit-equivalent handling) that
    # the calling process had, in this forked copy too, so always exit via
    # posix.exitnow (_exit(2)) instead.
    if setsid() < 0:
      exitnow(1)
    let pid2 = fork()
    if pid2 < 0:
      exitnow(1)
    if pid2 == 0:
      # Grandchild process: redirect fds, then exec into exePath.
      # The process image is replaced entirely, so from here on it runs as
      # exePath's own process (open fds are carried across the exec).
      #
      # stdin is always /dev/null. stdout/stderr go to logPath (or
      # /dev/null if empty).
      # **Omitting this keeps holding onto the caller's pipe and hangs the
      # shell** (see this proc's doc comment).
      let inFd = posix.open("/dev/null".cstring, O_RDONLY)
      if inFd >= 0:
        discard dup2(inFd, 0)
        if inFd > 2: discard close(inFd)

      let outTarget = if logPath.len > 0: logPath else: "/dev/null"
      # Open in append mode (accumulate onto the daemon's previous log).
      # Created with mode 0600.
      let outFd = posix.open(outTarget.cstring,
                             O_WRONLY or O_CREAT or O_APPEND, 0o600)
      if outFd >= 0:
        discard dup2(outFd, 1)
        discard dup2(outFd, 2)
        if outFd > 2: discard close(outFd)
      else:
        # Even if the log can't be opened, avoid continuing to hold onto
        # stdout (it would cause a hang).
        let nullFd = posix.open("/dev/null".cstring, O_WRONLY)
        if nullFd >= 0:
          discard dup2(nullFd, 1)
          discard dup2(nullFd, 2)
          if nullFd > 2: discard close(nullFd)

      var argv = @[exePath]
      for a in args:
        argv.add a
      discard execvp(exePath.cstring, allocCStringArray(argv))
      exitnow(127) # Only reached if the exec itself fails
    else:
      exitnow(0) # The intermediate process exits immediately after launching the grandchild

  var status: cint
  discard waitpid(pid1, status, 0)
  pid1.int
