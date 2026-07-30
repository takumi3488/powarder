## Tests for `powarder/daemon/orphan`.
##
## To test without a real SSH server, we place the fake ssh at
## `tests/fixtures/ssh` at the front of `PATH` and let powarder pick it up
## as `ssh` (the same technique as `tdaemon.nim` / `thostsession.nim`; the
## environment setup is carried over as-is).
##
## Tests that need to create a "live master" (aoAdopted / aoMismatch /
## the fkLocal adopt) do this by hand, following the same procedure as
## `daemon/hostsession.spawnMaster` (build the command via
## `muxclient.masterCommandLine` and `startProcess`), and launch a real
## process holding a UDS control socket using fake ssh's `-M -N` mode. The
## test process itself becomes the parent of that child process, so
## cleanup is done reliably with `terminate` + `waitForExit` (independent
## of the adopt side operating on the premise of "not my own child", the
## test itself properly reaps it as the parent).

import std/[unittest, os, options, monotimes, times, strutils, osproc, tables]
import std/asyncnet
import std/nativesockets

import powarder/core/types
import powarder/core/paths
import powarder/config/statefile
import powarder/daemon/muxclient
import powarder/daemon/hostsession
import powarder/daemon/forward
import powarder/daemon/registry
import powarder/daemon/orphan

const fixturesDir = currentSourcePath().parentDir() / "fixtures"
const testRuntimeDir = "/tmp/pw-orp-rt"

# ---------------------------------------------------------------------------
# Setup / helpers
# ---------------------------------------------------------------------------

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

proc setupSuite() =
  removeDir(testRuntimeDir)
  createDir(testRuntimeDir)
  putEnv("POWARDER_RUNTIME_DIR", testRuntimeDir)
  let curPath = getEnv("PATH")
  if not curPath.startsWith(fixturesDir & ":"):
    putEnv("PATH", fixturesDir & ":" & curPath)
  delEnv("POWARDER_FAKE_SSH_MODE")
  delEnv("POWARDER_FAKE_SSH_LOG")

setupSuite()

var allMasters: seq[Process]
  ## To avoid missing cleanup, remember every fake ssh master that the
  ## test launched by hand, and reliably terminate them all at the end of
  ## the file.

proc trackMaster(p: Process): Process =
  allMasters.add(p)
  p

proc startFakeMaster(host, ctlPath, logPath: string): Process =
  ## Directly launches a fake ssh `-M -N` master using the same procedure
  ## as `hostsession.spawnMaster` (since what `adoptOrphans` targets is "an
  ## existing process the daemon doesn't manage", we launch it by hand here
  ## rather than going through `HostSession`).
  let cmd = masterCommandLine(ctlPath, logPath, host)
  result = trackMaster(startProcess(cmd[0], args = cmd[1 .. ^1], options = {}))

proc stopFakeMaster(p: Process; ctlPath: string) =
  try:
    p.terminate()
  except OSError:
    discard
  discard p.waitForExit()
  try:
    p.close()
  except CatchableError:
    discard
  removeFile(ctlPath)
  removeFile(ctlPath & ".pid")

proc waitForSocket(path: string; timeoutMs = 3000): bool =
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while not socketExists(path):
    if getMonoTime() >= deadline:
      return false
    sleep(20)
  true

proc touchDeadSocket(path: string) =
  ## Creates a UNIX socket file that only `bind`s and never `listen`s.
  ## `connect`ing to a UDS that isn't listening results in `ECONNREFUSED`
  ## (this simulates the "master is dead, but the socket file remains"
  ## situation, matching what was observed in practice).
  removeFile(path)
  let s = newAsyncSocket(AF_UNIX, SOCK_STREAM, IPPROTO_NONE, buffered = false)
  s.bindUnix(path)
  s.close()

proc newUnixListener(path: string): AsyncSocket =
  ## A UNIX socket that does `bind` + `listen`. Even without running
  ## `accept`, the listen backlog means `connect` succeeds immediately at
  ## the kernel level (since `probeUpstream` only does connect + an
  ## immediate close, this is sufficient).
  removeFile(path)
  result = newAsyncSocket(AF_UNIX, SOCK_STREAM, IPPROTO_NONE, buffered = false)
  result.bindUnix(path)
  result.listen()

var portCounter = 18300
proc nextPort(): Port =
  inc portCounter
  Port(portCounter)

# ---------------------------------------------------------------------------
# 1. A record with no control socket -> aoNoSocket
# ---------------------------------------------------------------------------

suite "aoNoSocket":
  test "a record with no control socket becomes aoNoSocket, and the record is discarded":
    let reg = newRegistry()
    let st = PersistedState(version: 1, savedAt: "", hosts: @[
      PersistedHostSession(host: "h-nosocket", fingerprint: "fp-nosocket",
          ctlPath: testRuntimeDir / "does-not-exist.sock",
          logPath: testRuntimeDir / "h-nosocket.log", pid: 999999,
          argv: @[], state: hsConnected, forwardIds: @[])
    ], forwards: @[])

    let report = adoptOrphans(reg, st)

    check report.hosts.len == 1
    check report.hosts[0].host == "h-nosocket"
    check report.hosts[0].outcome == aoNoSocket
    check reg.hosts.len == 0

# ---------------------------------------------------------------------------
# 2. A record where -O check fails -> aoDeadReclaimed, stale socket removed
# ---------------------------------------------------------------------------

suite "aoDeadReclaimed":
  test "a record where -O check fails becomes aoDeadReclaimed, and the stale socket is removed":
    withMode("no-master", proc() =
      let ctlPath = testRuntimeDir / "dead.sock"
      touchDeadSocket(ctlPath)
      check socketExists(ctlPath)

      let reg = newRegistry()
      let st = PersistedState(version: 1, savedAt: "", hosts: @[
        PersistedHostSession(host: "h-dead", fingerprint: "fp-dead",
            ctlPath: ctlPath, logPath: testRuntimeDir / "h-dead.log",
            pid: 999998, argv: @[], state: hsConnected, forwardIds: @[])
      ], forwards: @[])

      let report = adoptOrphans(reg, st)

      check report.hosts.len == 1
      check report.hosts[0].outcome == aoDeadReclaimed
      check report.staleSocketsRemoved == 1
      check not socketExists(ctlPath)
      check reg.hosts.len == 0)

# ---------------------------------------------------------------------------
# 3. A live master -> aoAdopted, registered with adopted=true
# 8. An adopted host has process.isNone. Repeatedly calling tick does not
#    use peekExitCode (does not crash)
# ---------------------------------------------------------------------------

suite "aoAdopted":
  test "a live master becomes aoAdopted and is registered into reg.hosts with adopted=true; tick does not crash with process.isNone":
    withMode("ok", proc() =
      let host = "adopt-host-alive"
      let ctlPath = testRuntimeDir / "alive.sock"
      let logPath = testRuntimeDir / "alive.log"
      let p = startFakeMaster(host, ctlPath, logPath)
      check waitForSocket(ctlPath)
      let pid = p.processID()

      let reg = newRegistry()
      let st = PersistedState(version: 1, savedAt: "", hosts: @[
        PersistedHostSession(host: host, fingerprint: "fp-alive",
            ctlPath: ctlPath, logPath: logPath, pid: pid,
            argv: @[ctlPath, host], state: hsConnected, forwardIds: @[])
      ], forwards: @[])

      let report = adoptOrphans(reg, st)

      check report.hosts.len == 1
      check report.hosts[0].outcome == aoAdopted
      check reg.hosts.len == 1

      var adoptedHs: HostSession = nil
      for hs in reg.hosts.values:
        adoptedHs = hs
      check adoptedHs != nil
      check adoptedHs.adopted
      check adoptedHs.process.isNone ## IMPORTANT: item 8: process is
                                      ## always none since this is not our
                                      ## own child
      check adoptedHs.state == hsConnected
      check adoptedHs.pid == pid

      # IMPORTANT: item 8 continued: repeatedly calling `tick` does not
      # crash even when `process` is none (if `ownProcessExited` tried to
      # call `peekExitCode`, unpacking the `Option` would raise an
      # exception).
      for i in 0 ..< 5:
        tick(adoptedHs)
        check adoptedHs.state == hsConnected

      stopFakeMaster(p, ctlPath))

# ---------------------------------------------------------------------------
# 4. cmdline doesn't match -> aoMismatch, do nothing
# ---------------------------------------------------------------------------

suite "aoMismatch":
  test "a record whose cmdlineMatches doesn't match becomes aoMismatch, and nothing is done":
    withMode("ok", proc() =
      let host = "adopt-host-mismatch"
      let ctlPath = testRuntimeDir / "mismatch.sock"
      let logPath = testRuntimeDir / "mismatch.log"
      let p = startFakeMaster(host, ctlPath, logPath)
      check waitForSocket(ctlPath)
      let pid = p.processID()

      let reg = newRegistry()
      let st = PersistedState(version: 1, savedAt: "", hosts: @[
        PersistedHostSession(host: host, fingerprint: "fp-mismatch",
            ctlPath: ctlPath, logPath: logPath, pid: pid,
            argv: @["this-argv-does-not-match-anything-zzz"],
            state: hsConnected, forwardIds: @[])
      ], forwards: @[])

      let report = adoptOrphans(reg, st)

      check report.hosts.len == 1
      check report.hosts[0].outcome == aoMismatch
      check reg.hosts.len == 0 ## Not adopted

      stopFakeMaster(p, ctlPath))

# ---------------------------------------------------------------------------
# 5. An fkLocal Forward whose UDS is alive -> taken over as fwActive
# 6. An fkLocal Forward whose UDS is dead -> debris removed + fwPending
# 7. An fkRemote Forward -> optimistically fwPending
# ---------------------------------------------------------------------------

suite "adopting a forward":
  test "an fkLocal with a live UDS is taken over as fwActive":
    withMode("ok", proc() =
      let host = "adopt-host-fwd-alive"
      let ctlPath = testRuntimeDir / "fwd-alive-host.sock"
      let logPath = testRuntimeDir / "fwd-alive-host.log"
      let p = startFakeMaster(host, ctlPath, logPath)
      check waitForSocket(ctlPath)
      let pid = p.processID()

      let udsPath = testRuntimeDir / "fwd-alive.uds"
      let listener = newUnixListener(udsPath)

      let spec = ForwardSpec(kind: fkLocal, bindAddr: defaultBindAddr,
          bindPort: nextPort(), targetHost: "db.internal", targetPort: Port(5432))

      let reg = newRegistry()
      let st = PersistedState(version: 1, savedAt: "", hosts: @[
        PersistedHostSession(host: host, fingerprint: "fp-fwd-alive",
            ctlPath: ctlPath, logPath: logPath, pid: pid,
            argv: @[ctlPath, host], state: hsConnected,
            forwardIds: @["fwd-alive-id"])
      ], forwards: @[
        PersistedForward(id: "fwd-alive-id", tunnelName: "t-alive",
            spec: spec, state: fwActive, udsPath: udsPath)
      ])

      let report = adoptOrphans(reg, st)

      check report.hosts[0].outcome == aoAdopted
      # `report.adoptedForwards` contains the `fw.id` that
      # `forward.adoptForward` deterministically derives
      # (`forwardId(spec, host)`). It has nothing to do with the persisted
      # side's id ("fwd-alive-id"), so we check only the count, not the
      # content.
      check report.adoptedForwards.len == 1
      check report.reattachForwards.len == 0

      let fws = forwardsOfTunnel(reg, "t-alive")
      check fws.len == 1
      check fws[0].state == fwActive
      check fws[0].proxy.isSome

      listener.close()
      removeFile(udsPath)
      forward.teardown(fws[0])
      stopFakeMaster(p, ctlPath))

  test "an fkLocal with a dead UDS has its debris removed and becomes fwPending":
    withMode("ok", proc() =
      let host = "adopt-host-fwd-dead"
      let ctlPath = testRuntimeDir / "fwd-dead-host.sock"
      let logPath = testRuntimeDir / "fwd-dead-host.log"
      let p = startFakeMaster(host, ctlPath, logPath)
      check waitForSocket(ctlPath)
      let pid = p.processID()

      let udsPath = testRuntimeDir / "fwd-dead.uds"
      touchDeadSocket(udsPath)
      check socketExists(udsPath)

      let spec = ForwardSpec(kind: fkLocal, bindAddr: defaultBindAddr,
          bindPort: nextPort(), targetHost: "db.internal", targetPort: Port(5432))

      let reg = newRegistry()
      let st = PersistedState(version: 1, savedAt: "", hosts: @[
        PersistedHostSession(host: host, fingerprint: "fp-fwd-dead",
            ctlPath: ctlPath, logPath: logPath, pid: pid,
            argv: @[ctlPath, host], state: hsConnected,
            forwardIds: @["fwd-dead-id"])
      ], forwards: @[
        PersistedForward(id: "fwd-dead-id", tunnelName: "t-dead",
            spec: spec, state: fwActive, udsPath: udsPath)
      ])

      let report = adoptOrphans(reg, st)

      check report.adoptedForwards.len == 0
      check report.reattachForwards == @["fwd-dead-id"]
      check not socketExists(udsPath) ## The debris has been removed

      let fws = forwardsOfTunnel(reg, "t-dead")
      check fws.len == 1
      check fws[0].state == fwPending

      forward.teardown(fws[0])
      stopFakeMaster(p, ctlPath))

  test "fkRemote optimistically becomes fwPending":
    withMode("ok", proc() =
      let host = "adopt-host-fwd-remote"
      let ctlPath = testRuntimeDir / "fwd-remote-host.sock"
      let logPath = testRuntimeDir / "fwd-remote-host.log"
      let p = startFakeMaster(host, ctlPath, logPath)
      check waitForSocket(ctlPath)
      let pid = p.processID()

      let spec = ForwardSpec(kind: fkRemote, bindAddr: defaultBindAddr,
          bindPort: nextPort(), targetHost: "internal.example",
              targetPort: Port(80))

      let reg = newRegistry()
      let st = PersistedState(version: 1, savedAt: "", hosts: @[
        PersistedHostSession(host: host, fingerprint: "fp-fwd-remote",
            ctlPath: ctlPath, logPath: logPath, pid: pid,
            argv: @[ctlPath, host], state: hsConnected,
            forwardIds: @["fwd-remote-id"])
      ], forwards: @[
        PersistedForward(id: "fwd-remote-id", tunnelName: "t-remote",
            spec: spec, state: fwActive, udsPath: "")
      ])

      let report = adoptOrphans(reg, st)

      check report.adoptedForwards.len == 0
      check report.reattachForwards == @["fwd-remote-id"]

      let fws = forwardsOfTunnel(reg, "t-remote")
      check fws.len == 1
      check fws[0].state == fwPending
      check fws[0].proxy.isNone

      forward.teardown(fws[0])
      stopFakeMaster(p, ctlPath))

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

for p in allMasters:
  try:
    if p.peekExitCode() == -1:
      p.terminate()
    discard p.waitForExit()
    p.close()
  except CatchableError:
    discard

removeDir(testRuntimeDir)
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
