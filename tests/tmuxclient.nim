## Tests for `powarder/daemon/muxclient`.
##
## To test without a real SSH server, we place the fake ssh at
## `tests/fixtures/ssh` at the front of `PATH` and let powarder pick it up
## as `ssh`. The fake ssh's behavior is switched via
## `POWARDER_FAKE_SSH_MODE` (see `tests/fixtures/ssh` for details).

import std/[unittest, os, strutils]
import powarder/core/types
import powarder/core/muxparse
import powarder/core/sshgparse
import powarder/core/forwardspec
import powarder/daemon/muxclient

const fixturesDir = currentSourcePath().parentDir() / "fixtures"
const testRuntimeDir = "/tmp/pw-muxclient-rt"
const testLogFile = "/tmp/pw-muxclient-log"

const ctlPath = testRuntimeDir / "ctl.sock"
const host = "example-host"

proc withMode(mode: string; body: proc()) =
  ## Temporarily switches `POWARDER_FAKE_SSH_MODE` and runs the test body.
  let had = existsEnv("POWARDER_FAKE_SSH_MODE")
  let old = getEnv("POWARDER_FAKE_SSH_MODE")
  putEnv("POWARDER_FAKE_SSH_MODE", mode)
  try:
    body()
  finally:
    if had: putEnv("POWARDER_FAKE_SSH_MODE", old)
    else: delEnv("POWARDER_FAKE_SSH_MODE")

proc withLog(body: proc()) =
  ## Temporarily enables `POWARDER_FAKE_SSH_LOG` and runs the test body.
  ## Always cleans up the log file and the environment variable on exit.
  removeFile(testLogFile)
  putEnv("POWARDER_FAKE_SSH_LOG", testLogFile)
  try:
    body()
  finally:
    delEnv("POWARDER_FAKE_SSH_LOG")
    removeFile(testLogFile)

proc setupSuite() =
  ## Puts fake ssh at the front of PATH and isolates the temp directory.
  removeDir(testRuntimeDir)
  createDir(testRuntimeDir)
  putEnv("POWARDER_RUNTIME_DIR", testRuntimeDir)
  let curPath = getEnv("PATH")
  if not curPath.startsWith(fixturesDir & ":"):
    putEnv("PATH", fixturesDir & ":" & curPath)
  delEnv("POWARDER_FAKE_SSH_MODE")
  delEnv("POWARDER_FAKE_SSH_LOG")

setupSuite()

# ---------------------------------------------------------------------------
# 1. masterCommandLine
# ---------------------------------------------------------------------------

suite "masterCommandLine":
  test "includes all required options and does not include ExitOnForwardFailure":
    let logPath = testRuntimeDir / "master.log"
    let cmd = masterCommandLine(ctlPath, logPath, host)
    check cmd.len == 3
    check cmd[0] == "/bin/sh"
    check cmd[1] == "-c"

    let inner = cmd[2]
    check inner.startsWith("exec ")
    check ">>" in inner
    check logPath in inner

    for token in ["-M", "-S", "-N", "-v",
                  "BatchMode=yes", "ControlPersist=no",
                  "ServerAliveInterval=15", "ServerAliveCountMax=3",
                  "ConnectTimeout=10",
                  "StreamLocalBindMask=0177", "StreamLocalBindUnlink=yes",
                  ctlPath, host]:
      check token in inner

    check not ("ExitOnForwardFailure" in inner)

  test "extraArgs are appended after the host name":
    let logPath = testRuntimeDir / "master.log"
    let cmd = masterCommandLine(ctlPath, logPath, host, ["-p", "2222"])
    let inner = cmd[2]
    check inner.find(host) < inner.find("-p")
    check "2222" in inner

# ---------------------------------------------------------------------------
# 2, 3. checkMaster
# ---------------------------------------------------------------------------

suite "checkMaster":
  test "ok mode gives alive:true, pid a number":
    withMode("ok", proc() =
      let r = checkMaster(ctlPath, host)
      check r.alive
      check r.pid > 0)

  test "no-master mode gives alive:false, pid:0":
    withMode("no-master", proc() =
      let r = checkMaster(ctlPath, host)
      check not r.alive
      check r.pid == 0)

# ---------------------------------------------------------------------------
# 4. addForward
# ---------------------------------------------------------------------------

suite "addForward":
  let spec = ForwardSpec(kind: fkLocal, bindAddr: defaultBindAddr,
                          bindPort: Port(15432), targetHost: "db.internal",
                          targetPort: Port(5432))

  test "ok mode gives moSuccess":
    withMode("ok", proc() =
      check addForward(ctlPath, host, spec) == moSuccess)

  test "bind-failed mode gives moBindFailed":
    withMode("bind-failed", proc() =
      check addForward(ctlPath, host, spec) == moBindFailed)

# ---------------------------------------------------------------------------
# 5. cancelForward — verifying that cancel's exit code cannot be trusted
# ---------------------------------------------------------------------------

suite "cancelForward":
  let spec = ForwardSpec(kind: fkLocal, bindAddr: defaultBindAddr,
                          bindPort: Port(15432), targetHost: "db.internal",
                          targetPort: Port(5432))

  test "ok mode gives moSuccess":
    withMode("ok", proc() =
      check cancelForward(ctlPath, host, spec) == moSuccess)

  test "not-forwarded: fake ssh's exit code is 0 but it is judged moNotForwarded":
    withMode("not-forwarded", proc() =
      # Explicitly cross-checks, against runSsh's raw result, the design
      # where cancel's judgment doesn't trust the exit code and is made
      # solely from the stderr wording (core/muxparse.parseCancelResult).
      let raw = runSsh(["-S", ctlPath, "-O", "cancel", "-L",
                        toSshForwardArg(spec), host])
      check raw.exitCode == 0 ## IMPORTANT: looking only at the exit code
                               ## makes this look like a success
      check cancelForward(ctlPath, host, spec) == moNotForwarded)

# ---------------------------------------------------------------------------
# 6. resolveSshConfig — parsing stdout only
# ---------------------------------------------------------------------------

suite "resolveSshConfig":
  test "-G's stdout can be parsed":
    withMode("ok", proc() =
      let cfg = resolveSshConfig(host)
      check cfg.getFirst("host") == host
      check cfg.getFirst("port") == "22")

  test "even if fake ssh writes extra output to stderr, only stdout gets parsed":
    withMode("ok", proc() =
      # tests/fixtures/ssh always writes
      # "Pseudo-terminal will not be allocated ..." to stderr in -G mode.
      # Confirms it still isn't mistakenly picked up as a key.
      let cfg = resolveSshConfig(host)
      check not cfg.has("pseudo-terminal")
      check cfg.getFirst("host") == host)

# ---------------------------------------------------------------------------
# 7. Recording arguments (POWARDER_FAKE_SSH_LOG)
# ---------------------------------------------------------------------------

suite "recording arguments":
  test "addForward builds the argument in the form -L <uds>:<target>:<port>":
    withLog(proc() =
      withMode("ok", proc() =
        let spec = ForwardSpec(kind: fkLocal, bindAddr: defaultBindAddr,
                                bindPort: Port(15432),
                                    targetHost: "db.internal",
                                targetPort: Port(5432))
        discard addForward(ctlPath, host, spec, udsPath = "/tmp/pw-fwd.sock"))

      let fields = readFile(testLogFile).strip().split("\x1F")
      check "-L" in fields
      check "/tmp/pw-fwd.sock:db.internal:5432" in fields
      check ctlPath in fields
      check host in fields)

# ---------------------------------------------------------------------------
# 8. Escaping via quoteShell
# ---------------------------------------------------------------------------

suite "escaping via quoteShell":
  test "checkMaster doesn't break even with a host name containing whitespace":
    withMode("ok", proc() =
      let r = checkMaster(ctlPath, "my host with spaces")
      check r.alive)

  test "a host name / UDS path / target containing whitespace is kept as a single argument by addForward":
    withLog(proc() =
      let weirdHost = "my host"
      let weirdUds = "/tmp/pw dir/uds sock"
      let spec = ForwardSpec(kind: fkLocal, bindAddr: defaultBindAddr,
                              bindPort: Port(1), targetHost: "db host",
                              targetPort: Port(2))
      withMode("ok", proc() =
        check addForward(ctlPath, weirdHost, spec, udsPath = weirdUds) == moSuccess)

      let fields = readFile(testLogFile).strip().split("\x1F")
      check weirdHost in fields ## Arrives as a single argument, whitespace
                                ## included
      check (weirdUds & ":db host:2") in fields)

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

removeDir(testRuntimeDir)
removeFile(testLogFile)
delEnv("POWARDER_FAKE_SSH_MODE")
delEnv("POWARDER_FAKE_SSH_LOG")
delEnv("POWARDER_RUNTIME_DIR")

# The fake ssh listener (nc / python3 / perl) is orphaned and left behind
# when `hostsession.teardown`'s last resort, SIGKILL, is sent, because the
# fake ssh's trap never fires. If it's left behind, the pipe inherited from
# the parent never closes, and `nimble test` **hangs** waiting for EOF
# (observed in practice: hung for 3 hours in a Linux container). The
# approach of closing the fd on the fake ssh side broke on two points --
# dash's behavior and asyncdispatch's fd inheritance -- so we clean it up
# reliably here instead.
#
# The `[p]` bracket trick is the standard idiom for preventing `pkill` from
# matching its own command line and killing itself (hit this in practice;
# it results in exit 144).
discard execShellCmd("pkill -f '" & testRuntimeDir & "' >/dev/null 2>&1 || true")
