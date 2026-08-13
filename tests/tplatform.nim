import std/[unittest, os, posix, options, osproc, strutils]
import powarder/platform/lock
import powarder/platform/procinfo
import powarder/platform/daemonize

suite "lock: basic acquire/release":

  test "can reacquire after release":
    let path = "/tmp/pw-lock-basic.lock"
    removeFile(path)
    let lock1 = acquireSingletonLock(path)
    lock1.release()
    let lock2 = acquireSingletonLock(path)
    lock2.release()
    removeFile(path)

  test "release is idempotent (doesn't fail when called twice)":
    let path = "/tmp/pw-lock-idem.lock"
    removeFile(path)
    let lock = acquireSingletonLock(path)
    lock.release()
    lock.release() # must not raise here
    removeFile(path)

  test "writePid / readPid round-trip":
    let path = "/tmp/pw-lock-pid.lock"
    removeFile(path)
    let lock = acquireSingletonLock(path)
    lock.writePid(12345)
    check readPid(path) == some(12345)
    lock.release()
    removeFile(path)

  test "readPid: none if the file doesn't exist":
    let path = "/tmp/pw-lock-nofile.lock"
    removeFile(path)
    check readPid(path).isNone

suite "lock: cross-process exclusion (uses fork)":
  ## An fcntl advisory lock is scoped per process, so acquiring it twice
  ## within the same process succeeds anyway. Verifying multi-launch
  ## prevention requires a separate process, so fork() is used. The child
  ## process exits via posix.exitnow (_exit) rather than quit(). quit()
  ## would drag in the Nim runtime's exit-time processing and unittest's
  ## global state, causing the child process to re-run the test suite.

  test "the same lock can't be acquired from a different process":
    let lockFile = "/tmp/pw-lock-cross.lock"
    removeFile(lockFile)
    let lock = acquireSingletonLock(lockFile)

    let pid = fork()
    if pid == 0:
      # Child process: exit with 0 if it couldn't acquire, 1 if it did
      let got = tryAcquireSingletonLock(lockFile)
      exitnow(if got.isSome: 1 else: 0)

    var status: cint
    discard waitpid(pid, status, 0)
    check WEXITSTATUS(status) == 0

    lock.release()
    removeFile(lockFile)

  test "the kernel releases a SIGKILLed process's lock":
    let lockFile = "/tmp/pw-lock-sigkill.lock"
    removeFile(lockFile)

    let pid = fork()
    if pid == 0:
      # Child process: hold the lock and wait for SIGKILL from the parent.
      # In case SIGKILL never arrives, bail out after a cap
      # (100 * 50ms = 5 seconds) so the test doesn't hang forever.
      discard tryAcquireSingletonLock(lockFile)
      for i in 0 ..< 100:
        os.sleep(50)
      exitnow(2) # normally we'd be killed by SIGKILL before reaching here

    os.sleep(200) # wait for the child to finish acquiring the lock
    discard kill(pid, SIGKILL)
    var status: cint
    discard waitpid(pid, status, 0)

    # By the time the child was terminated with SIGKILL, the kernel should
    # have released the lock, so the parent (this process) can acquire it.
    # With a PID-file approach this is where a "stale file left behind"
    # problem would occur, but that doesn't happen with an fcntl lock.
    let got = tryAcquireSingletonLock(lockFile)
    check got.isSome
    got.get.release()
    removeFile(lockFile)

suite "lock: free-ness probes":
  ## `isSingletonLockFree` / `lockHolderPid` let a CLI
  ## process (which never holds the lock itself) check whether the daemon's
  ## singleton lock is free, so it can decide whether a fresh daemon may be
  ## spawned. Both are pure `fcntl(F_GETLK)` queries: they never
  ## acquire the lock, so a probe cannot deny a concurrently starting daemon
  ## (a try-acquire probe could, and did — see the probe/acquire race test
  ## below). `F_GETLK` ignores the *caller's own* locks, so these procs must
  ## never be called from a process that already holds the lock: the answer
  ## would be a spurious "free". That is why every "held" case below has a
  ## forked child hold the lock while the parent (which holds nothing)
  ## probes it.

  test "true for a free path":
    let path = "/tmp/pw-lock-free.lock"
    removeFile(path)
    check isSingletonLockFree(path)
    removeFile(path)

  test "a lock held by another process is not free":
    let lockFile = "/tmp/pw-lock-held.lock"
    let markerFile = "/tmp/pw-lock-held-ready"
    removeFile(lockFile)
    removeFile(markerFile)

    let pid = fork()
    if pid == 0:
      # Child process: take the lock, write the readiness marker, then
      # hold until SIGKILLed by the parent. The 5s cap (100 * 50ms) keeps
      # the test from hanging if the kill never arrives. Never discard the
      # acquire result: a lost race exits with a distinct status so the
      # parent can report it as such instead of as a confusing probe
      # failure 2s later.
      let got = tryAcquireSingletonLock(lockFile)
      if got.isNone:
        exitnow(3)
      writeFile(markerFile, "ready")
      for i in 0 ..< 100:
        os.sleep(50)
      exitnow(2)

    # Readiness = the marker file the child writes only after a successful
    # acquire, never a probe of the lock itself: probing the primitive
    # under test as a readiness signal would (with an acquire-based probe)
    # steal the lock from the child in the microseconds before its F_SETLK.
    var status: cint
    var waited = 0
    var childLostRace = false
    while not fileExists(markerFile) and waited < 2000:
      # A child that lost the race exits immediately with the failure
      # status; reap it without blocking and report that, so the failure
      # reads "the child could not take the lock", not "marker missing".
      if waitpid(pid, status, WNOHANG) == pid:
        childLostRace = true
        break
      os.sleep(50)
      waited += 50

    if childLostRace:
      checkpoint("the forked child could not take the lock (exit " & $WEXITSTATUS(status) & ")")
      fail()
    else:
      check not isSingletonLockFree(lockFile)

      discard kill(pid, SIGKILL)
      discard waitpid(pid, status, 0)

      # The kernel released the child's lock together with the process, so
      # the path is free again.
      check isSingletonLockFree(lockFile)

    removeFile(lockFile)
    removeFile(markerFile)

  test "a path inside a nonexistent directory counts as free (OSError is free)":
    # Nothing can hold a lock on a file that cannot even be opened, so an
    # OSError from the probe must be treated as "free" and never propagate.
    let path = "/tmp/pw-lock-missing-dir/pw-lock-missing.lock"
    removeFile(path) # no-op: the parent directory does not exist
    check isSingletonLockFree(path) # must not raise
    removeFile(path) # still nothing to remove, but keep cleanup consistent

  test "probing the lock never prevents a concurrent acquire (F_GETLK query, not a try-acquire)":
    ## Regression test for the root cause of the original flakiness in
    ## this suite. `isSingletonLockFree` used to be implemented as
    ## tryAcquireSingletonLock + immediate release, so for the microseconds
    ## the probe held the lock it made the answer false for everyone else —
    ## including a real daemon in runDaemon's single tryAcquireSingletonLock,
    ## which does not retry and exits exitAlreadyRunning (7). Measured on an
    ## idle 8-core box, the forked child failed to acquire in 22/3000 and
    ## 5/3000 trials; with the parent's probe deleted, 0/3000. The F_GETLK
    ## rewrite made the probe a pure query that never acquires, so it cannot
    ## deny anyone. Regressing to a try-acquire probe would reintroduce the
    ## race, and this test would start failing again.
    for trial in 0 ..< 300:
      let lockFile = "/tmp/pw-lock-probe-race.lock"
      removeFile(lockFile)
      let pid = fork()
      if pid == 0:
        # Child: a single acquire with no retry, exactly like runDaemon.
        # Sleep 1ms first so the parent's hammer loop is already probing
        # when the acquire lands. Exit 0 on success, 1 if a probe denied it.
        os.sleep(1)
        let got = tryAcquireSingletonLock(lockFile)
        exitnow(if got.isSome: 0 else: 1)
      # Hammer both probes in a tight loop until the child is reaped, so
      # probes land across the child's acquire moment on every trial.
      var status: cint = 0
      while waitpid(pid, status, WNOHANG) == 0:
        discard isSingletonLockFree(lockFile)
        discard lockHolderPid(lockFile)
      check WEXITSTATUS(status) == 0 # 1 would mean a probe denied the acquire
      removeFile(lockFile)

  test "lockHolderPid: none while the lock is free":
    let path = "/tmp/pw-lock-holder-free.lock"
    removeFile(path)
    check lockHolderPid(path).isNone
    check isSingletonLockFree(path) # the two probes agree
    removeFile(path)

  test "lockHolderPid: reports the forked holder's pid, and none after it releases":
    let lockFile = "/tmp/pw-lock-holder-held.lock"
    let markerFile = "/tmp/pw-lock-holder-held-ready"
    removeFile(lockFile)
    removeFile(markerFile)

    let pid = fork()
    if pid == 0:
      # Child: take the lock, write the readiness marker, then hold until
      # SIGKILLed by the parent (5s cap). A lost race exits with a distinct
      # status instead of being discarded.
      let got = tryAcquireSingletonLock(lockFile)
      if got.isNone:
        exitnow(3)
      writeFile(markerFile, "ready")
      for i in 0 ..< 100:
        os.sleep(50)
      exitnow(2)

    var status: cint
    var waited = 0
    var childLostRace = false
    while not fileExists(markerFile) and waited < 2000:
      if waitpid(pid, status, WNOHANG) == pid:
        childLostRace = true
        break
      os.sleep(50)
      waited += 50

    if childLostRace:
      checkpoint("the forked child could not take the lock (exit " & $WEXITSTATUS(status) & ")")
      fail()
    else:
      check fileExists(markerFile)
      # F_GETLK reports the holder's pid in l_pid; it must be the forked
      # child's pid exactly.
      check lockHolderPid(lockFile) == some(pid.int)
      # Reporting the holder must not disturb the held lock.
      check not isSingletonLockFree(lockFile)

      discard kill(pid, SIGKILL)
      discard waitpid(pid, status, 0)
      # The kernel released the lock together with the child process, so
      # the holder is gone again.
      check lockHolderPid(lockFile).isNone

    removeFile(lockFile)
    removeFile(markerFile)

  test "lockHolderPid: none for a path in a nonexistent directory (OSError is free)":
    # Nothing can hold a lock on a file that cannot even be opened, so an
    # OSError from the probe counts as "no holder" and must never propagate
    # (the same failure-counts-as-free rule as isSingletonLockFree).
    let path = "/tmp/pw-lock-holder-missing-dir/pw-lock-holder.lock"
    removeFile(path) # no-op: the parent directory does not exist
    check lockHolderPid(path).isNone # must not raise
    removeFile(path)

suite "procinfo: liveness check":

  test "pidAlive(getpid()) is true":
    check pidAlive(getpid().int)

  test "pidAlive(a large nonexistent PID) is false":
    check not pidAlive(999999)

suite "procinfo: retrieving the command line":

  test "can retrieve our own cmdline":
    let cmd = processCmdline(getpid().int)
    check cmd.len > 0

suite "procinfo: long argument lists and cmdlineMatches":

  test "-ww retrieves a long argument list without truncation, and cmdlineMatches judges it correctly":
    # ssh, as launched by powarder, has a long argument list like
    # `-o BatchMode=yes -o ControlPersist=no ...`. Launch a child process
    # with an argument list longer than what `ps` truncates to by default,
    # and confirm it can be retrieved in full with -ww.
    #
    # Launching via `sh -c "..."` triggers the shell's "replace the last
    # simple command with exec" optimization (a tail call), which drops the
    # extra arguments passed to sh itself from the post-exec argv (this
    # actually caused a failure once). So instead of going through a shell,
    # launch `/bin/cat -` directly. The leading "-" makes it block waiting
    # on stdin, so it never tries to process the following arguments, and
    # the argv we passed remains in cmdline as-is.
    # The dummy arguments must not start with `--`. **GNU coreutils' `cat`
    # (Linux) interprets `--dummy-...` as an invalid long option and exits
    # with an error immediately**, causing the process to disappear before
    # `processCmdline` is called (BSD `cat` (macOS) has no long options and
    # treats it as a filename, which is why only Linux failed on this
    # difference).
    # Since "-" is placed first, `cat` blocks waiting on stdin and never
    # tries to open the following arguments as files.
    var args = @["-"]
    for i in 0 ..< 20:
      args.add("dummy-argument-" & $i & "-" & "x".repeat(20))
    args.add("POWARDER_END_MARKER")

    let p = startProcess("/bin/cat", args = args)
    let pid = p.processID
    os.sleep(200) # grace period for ps to pick it up

    let cmd = processCmdline(pid)
    check "POWARDER_END_MARKER" in cmd

    check cmdlineMatches(pid, ["POWARDER_END_MARKER"])
    check not cmdlineMatches(pid, ["this-marker-does-not-exist-zzz"])

    p.kill()
    discard p.waitForExit()
    p.close()

suite "daemonize: spawnDetached":
  ## daemonize() itself makes the calling process quit(0), so it can't be
  ## called directly inside unittest (it would take the whole test process
  ## down with it). Instead, spawnDetached(), which uses the same double
  ## fork + setsid mechanism, is used to verify that "the calling process is
  ## no longer its parent." The manual verification steps for daemonize()
  ## itself are noted in the report.

  test "the launched process is no longer a child of the caller (detached from the parent)":
    let markerFile = "/tmp/pw-spawn-marker"
    removeFile(markerFile)

    # $$ becomes the PID of the actual post-exec process (the grandchild) itself
    let scriptArgs = ["-c", "echo $$ > " & markerFile & "; sleep 3"]
    let intermediatePid = spawnDetached("/bin/sh", scriptArgs)
    check intermediatePid > 0 # the intermediate process's PID (already exited; see doc)

    var waited = 0
    while not fileExists(markerFile) and waited < 2000:
      os.sleep(50)
      waited += 50
    check fileExists(markerFile)

    let daemonPid = parseInt(readFile(markerFile).strip())

    # Verify that the grandchild process is no longer a child of ourselves
    # (the test process) (i.e. it has been adopted by init/launchd), by
    # checking its actual PPID via ps.
    let ppidOut = execProcess("ps", args = ["-o", "ppid=", "-p", $daemonPid],
                              options = {poUsePath}).strip()
    check ppidOut.len > 0
    let ppid = parseInt(ppidOut)
    check ppid != getpid().int

    discard kill(Pid(daemonPid), SIGKILL)
    removeFile(markerFile)
