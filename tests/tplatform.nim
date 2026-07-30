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
