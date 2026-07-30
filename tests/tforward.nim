## Tests for `powarder/daemon/forward`.
##
## To test without a real SSH server, a fake ssh at `tests/fixtures/ssh` is
## placed at the front of `PATH` so powarder picks it up as `ssh` (the same
## technique as `thostsession.nim` / `tmuxclient.nim`). Since the fake ssh
## does not actually create a UDS even when it receives `-O forward`, to
## simulate the state of "a forward is established", the test side itself
## binds a dummy echo server to the deterministic path
## `paths.forwardSocketPath(udsBasename(id))` (the same technique as
## `tests/tproxy.nim`).

import std/[unittest, os, options, monotimes, times, strutils]
import std/asyncdispatch
import std/asyncnet
import std/nativesockets

import powarder/core/types
import powarder/core/statemachine
import powarder/core/forwardspec
import powarder/core/paths
import powarder/core/errorclass
import powarder/daemon/hostsession
import powarder/daemon/forward
import powarder/proxy/listener
import powarder/proxy/stats

const fixturesDir = currentSourcePath().parentDir() / "fixtures"
const testRuntimeDir = "/tmp/pw-fwd-rt"
const testStateDir = "/tmp/pw-fwd-state"
const testLogFile = "/tmp/pw-fwd-log"

# ---------------------------------------------------------------------------
# Setup / helpers
# ---------------------------------------------------------------------------

proc withMode(mode: string; body: proc()) =
  ## Temporarily switch `POWARDER_FAKE_SSH_MODE` and run the test body.
  let had = existsEnv("POWARDER_FAKE_SSH_MODE")
  let old = getEnv("POWARDER_FAKE_SSH_MODE")
  putEnv("POWARDER_FAKE_SSH_MODE", mode)
  try:
    body()
  finally:
    if had: putEnv("POWARDER_FAKE_SSH_MODE", old)
    else: delEnv("POWARDER_FAKE_SSH_MODE")

proc withLog(body: proc()) =
  ## Temporarily enable `POWARDER_FAKE_SSH_LOG` and run the test body.
  removeFile(testLogFile)
  putEnv("POWARDER_FAKE_SSH_LOG", testLogFile)
  try:
    body()
  finally:
    delEnv("POWARDER_FAKE_SSH_LOG")
    removeFile(testLogFile)

proc setupSuite() =
  removeDir(testRuntimeDir)
  createDir(testRuntimeDir)
  removeDir(testStateDir)
  createDir(testStateDir)
  putEnv("POWARDER_RUNTIME_DIR", testRuntimeDir)
  putEnv("POWARDER_STATE_DIR", testStateDir)
  let curPath = getEnv("PATH")
  if not curPath.startsWith(fixturesDir & ":"):
    putEnv("PATH", fixturesDir & ":" & curPath)
  delEnv("POWARDER_FAKE_SSH_MODE")
  delEnv("POWARDER_FAKE_SSH_LOG")

setupSuite()

var allSessions: seq[HostSession]
  ## To avoid missing cleanup, remember every HostSession created and tear
  ## them all down at the end of the file (same technique as
  ## thostsession.nim).

proc track(hs: HostSession): HostSession =
  allSessions.add(hs)
  hs

proc waitForHostState(hs: HostSession; target: HostSessionState;
                      timeoutMs = 5000): bool =
  ## Keep calling hostsession.tick until `target` is reached.
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while hs.state != target:
    hostsession.tick(hs)
    if hs.state == target:
      return true
    if getMonoTime() >= deadline:
      return false
    sleep(20)
  true

proc stopAndCleanup(hs: HostSession) =
  requestStop(hs, immediate = true)
  discard waitForHostState(hs, hsStopped, timeoutMs = 5000)
  hostsession.teardown(hs)

proc pollForward(fw: Forward; cond: proc(): bool {.closure.}; tries = 300;
                 delayMs = 20): Future[bool] {.async.} =
  ## Wait for `cond` to be satisfied while calling `tick(fw)`. The
  ## asynchronous cleanup that `fw.tick` advances step by step (reclaiming
  ## the proxy's Future / probeUpstream) requires spinning the event loop,
  ## so `sleepAsync` is used to create gaps (same technique as `waitUntil`
  ## in `tests/tproxy.nim`).
  for i in 0 ..< tries:
    tick(fw)
    if cond():
      return true
    await sleepAsync(delayMs)
  result = cond()

# ---- Dummy echo server (UDS) simulating the state of "a forward is established" --------

type
  EchoServer = ref object
    listener: AsyncSocket
    closing: bool

proc echoConn(sock: AsyncSocket) {.async.} =
  var buf = newString(65536)
  while true:
    let n = await sock.recvInto(addr buf[0], buf.len)
    if n <= 0: break
    await sock.send(addr buf[0], n)
  sock.close()

proc newEchoServerUnix(path: string): EchoServer =
  removeFile(path) ## fileExists always returns false for a UDS, but removeFile can be called unconditionally
  let l = newAsyncSocket(AF_UNIX, SOCK_STREAM, IPPROTO_NONE, buffered = false)
  l.bindUnix(path)
  l.listen()
  EchoServer(listener: l, closing: false)

proc serve(e: EchoServer) {.async.} =
  while not e.closing:
    try:
      let conn = await e.listener.acceptAddr()
      asyncCheck echoConn(conn.client)
    except CatchableError:
      if e.closing: break
      else: raise

proc close(e: EchoServer) =
  e.closing = true
  e.listener.close()

proc newTcpClient(port: int): Future[AsyncSocket] {.async.} =
  result = newAsyncSocket(buffered = false)
  await result.connect("127.0.0.1", Port(port))

# ---------------------------------------------------------------------------
# 1. newForward: deterministic derivation of id and UDS path, reference counting
# ---------------------------------------------------------------------------

suite "newForward":
  test "id is deterministically derived from forwardId() and the UDS path from udsBasename(), and the ref count increases":
    withMode("ok", proc() =
      let hs = track(newHostSession("host-fwd-newforward"))
      let spec = ForwardSpec(kind: fkLocal, bindAddr: defaultBindAddr,
                              bindPort: Port(18101), targetHost: "db.internal",
                              targetPort: Port(5432))
      check refCount(hs) == 0

      let fw = newForward("t1", spec, hs)

      check fw.id == forwardspec.forwardId(spec, hs.host)
      check fw.upstream.kind == ukUnix
      check fw.upstream.path == forwardSocketPath(udsBasename(fw.id))
      check fw.state == fwPending
      check fw.proxy.isNone
      check refCount(hs) == 1
      check hs.forwardIds[0] == fw.id

      hostsession.teardown(hs))

  test "the same spec yields the same id (deterministic)":
    withMode("ok", proc() =
      let hs = track(newHostSession("host-fwd-newforward-2"))
      let spec = ForwardSpec(kind: fkLocal, bindAddr: defaultBindAddr,
                              bindPort: Port(18111), targetHost: "db.internal",
                              targetPort: Port(5432))
      let fwA = newForward("a", spec, hs)
      let fwB = newForward("b", spec, hs)
      check fwA.id == fwB.id
      check refCount(hs) == 1 ## Adding the same id twice is idempotent on the hostsession side

      hostsession.teardown(hs))

# ---------------------------------------------------------------------------
# 2. attach -> connectivity through the proxy -> stats are recorded
# ---------------------------------------------------------------------------

suite "attach -> connectivity -> stats":
  test "becomes fwActive, and a connection to bindPort is echoed with bytesRx/bytesTx increasing":
    withMode("ok", proc() =
      let hs = track(newHostSession("host-fwd-active"))
      let spec = ForwardSpec(kind: fkLocal, bindAddr: defaultBindAddr,
                              bindPort: Port(18102), targetHost: "db.internal",
                              targetPort: Port(5432))
      let fw = newForward("t2", spec, hs)
      check waitForHostState(hs, hsConnected)

      proc scenario() {.async.} =
        tick(fw)
        check fw.state == fwActive
        check fw.proxy.isSome

        let udsPath = fw.upstream.path
        let echo = newEchoServerUnix(udsPath)
        asyncCheck echo.serve()

        let client = await newTcpClient(18102)
        await client.send("hello")
        var buf = newString(5)
        let n = await client.recvInto(addr buf[0], 5)
        buf.setLen(n)
        check buf == "hello"

        check fw.stats().isSome
        check fw.stats().get().bytesRx >= 5
        check fw.stats().get().bytesTx >= 5
        check fw.stats().get().totalConns >= 1

        client.close()
        echo.close()
        removeFile(udsPath)
        await sleepAsync(50)

      waitFor scenario()

      forward.teardown(fw)
      stopAndCleanup(hs))

# ---------------------------------------------------------------------------
# 3. bind-failed: retries exactly once, then fwError
# ---------------------------------------------------------------------------

suite "attach: bind-failed":
  test "retries exactly once, and if it still fails becomes fwError (attachRetried is true)":
    withMode("bind-failed", proc() =
      let hs = track(newHostSession("host-fwd-bindfailed"))
      let spec = ForwardSpec(kind: fkLocal, bindAddr: defaultBindAddr,
                              bindPort: Port(18103), targetHost: "db.internal",
                              targetPort: Port(5432))
      let fw = newForward("t3", spec, hs)
      check waitForHostState(hs, hsConnected)

      tick(fw)
      check fw.state == fwError
      check fw.attachRetried
      check fw.proxy.isNone ## The powarder-side listener is not started because the ssh side failed

      forward.teardown(fw)
      stopAndCleanup(hs))

# ---------------------------------------------------------------------------
# 4. The user-specified port is already in use: ekPortInUse + rollback of the ssh-side forward
# ---------------------------------------------------------------------------

suite "user-specified port already in use":
  test "a bind failure in newForwardProxy results in fwError + ekPortInUse, and the ssh side is rolled back with cancelForward":
    withLog(proc() =
      withMode("ok", proc() =
        let hs = track(newHostSession("host-fwd-portinuse"))
        let blockerPort = Port(18104)

        var blocker = newAsyncSocket(buffered = false)
        blocker.setSockOpt(OptReuseAddr, true)
        blocker.bindAddr(blockerPort, defaultBindAddr)
        blocker.listen()

        let spec = ForwardSpec(kind: fkLocal, bindAddr: defaultBindAddr,
                                bindPort: blockerPort,
                                targetHost: "db.internal",
                                targetPort: Port(5432))
        let fw = newForward("t4", spec, hs)
        check waitForHostState(hs, hsConnected)

        tick(fw)
        check fw.state == fwError
        check fw.lastErrorKind == ekPortInUse
        check fw.proxy.isNone

        let logged = readFile(testLogFile)
        check "cancel" in logged ## The ssh-side forward was rolled back

        blocker.close()
        forward.teardown(fw)
        stopAndCleanup(hs)))

# ---------------------------------------------------------------------------
# 5. detach: the proxy closes, cancel, UDS leftovers removed, ref count decreases
# ---------------------------------------------------------------------------

suite "detach":
  test "the proxy closes so the port can no longer be reached, cancel is called, the UDS disappears, and the ref count decreases":
    withLog(proc() =
      withMode("ok", proc() =
        let hs = track(newHostSession("host-fwd-detach"))
        let spec = ForwardSpec(kind: fkLocal, bindAddr: defaultBindAddr,
                                bindPort: Port(18105),
                                    targetHost: "db.internal",
                                targetPort: Port(5432))
        let fw = newForward("t5", spec, hs)
        check waitForHostState(hs, hsConnected)
        check refCount(hs) == 1

        let udsPath = fw.upstream.path

        proc scenario() {.async.} =
          tick(fw)
          check fw.state == fwActive

          let echo = newEchoServerUnix(udsPath)
          asyncCheck echo.serve()

          let client = await newTcpClient(18105)
          await client.send("ping")
          var buf = newString(4)
          let n = await client.recvInto(addr buf[0], 4)
          buf.setLen(n)
          check buf == "ping"
          client.close()
          await sleepAsync(30)

          # To simulate a state where the ssh side removed the forward,
          # clean up the fixture's echo server first (this is what
          # probeUpstream targets, to confirm the side effect of cancel).
          echo.close()
          removeFile(udsPath)
          await sleepAsync(30)

          requestDetach(fw)
          check fw.state == fwDetaching

          # Step 1 (proxy.close) happens synchronously inside
          # requestDetach, so new connections should be rejected
          # immediately.
          var refused = false
          try:
            discard await newTcpClient(18105)
          except OSError:
            refused = true
          check refused

          check await pollForward(fw, proc(): bool = isDiscardable(fw))
          check isDiscardable(fw)

        waitFor scenario()

        check refCount(hs) == 0
        check not socketExists(udsPath)

        let logged = readFile(testLogFile)
        check "cancel" in logged

        stopAndCleanup(hs)))

# ---------------------------------------------------------------------------
# 6. IMPORTANT: M4 completion criteria: one failure must not drag down other forwards or the master
# ---------------------------------------------------------------------------

suite "M4 completion criteria":
  test "failing one forward with bind-failed leaves other forwards on the same host and the master unaffected":
    withMode("ok", proc() =
      let hs = track(newHostSession("host-fwd-m4"))

      let spec1 = ForwardSpec(kind: fkLocal, bindAddr: defaultBindAddr,
                              bindPort: Port(18106), targetHost: "db1.internal",
                              targetPort: Port(1))
      let fw1 = newForward("m4-1", spec1, hs)
      check waitForHostState(hs, hsConnected) ## The master starts up in ok mode

      # Make only fw1's attach happen in bind-failed mode
      putEnv("POWARDER_FAKE_SSH_MODE", "bind-failed")
      tick(fw1)
      check fw1.state == fwError
      check fw1.attachRetried
      putEnv("POWARDER_FAKE_SSH_MODE", "ok")

      check isConnected(hs) ## The master is unaffected
      check hs.state == hsConnected

      let spec2 = ForwardSpec(kind: fkLocal, bindAddr: defaultBindAddr,
                              bindPort: Port(18107), targetHost: "db2.internal",
                              targetPort: Port(2))
      let fw2 = newForward("m4-2", spec2, hs)
      tick(fw2)
      check fw2.state == fwActive
      check isConnected(hs) ## The master remains unaffected even after fw2 succeeds

      forward.teardown(fw1)
      forward.teardown(fw2)
      stopAndCleanup(hs))

# ---------------------------------------------------------------------------
# 7. feHostLost: when the host leaves hsConnected, all Forwards return to fwPending
# ---------------------------------------------------------------------------

suite "feHostLost":
  test "when the host disconnects, all attached Forwards return to fwPending":
    withMode("ok", proc() =
      let hs = track(newHostSession("host-fwd-hostlost"))

      let spec1 = ForwardSpec(kind: fkLocal, bindAddr: defaultBindAddr,
                              bindPort: Port(18108), targetHost: "db1.internal",
                              targetPort: Port(1))
      let spec2 = ForwardSpec(kind: fkLocal, bindAddr: defaultBindAddr,
                              bindPort: Port(18109), targetHost: "db2.internal",
                              targetPort: Port(2))
      let fw1 = newForward("hl-1", spec1, hs)
      let fw2 = newForward("hl-2", spec2, hs)
      check waitForHostState(hs, hsConnected)

      tick(fw1)
      tick(fw2)
      check fw1.state == fwActive
      check fw2.state == fwActive

      requestStop(hs, immediate = true)
      check waitForHostState(hs, hsStopped)

      tick(fw1)
      tick(fw2)
      check fw1.state == fwPending
      check fw2.state == fwPending

      forward.teardown(fw1)
      forward.teardown(fw2)
      hostsession.teardown(hs))

# ---------------------------------------------------------------------------
# 8. Tier3 health check
# ---------------------------------------------------------------------------

suite "Tier3 health check":
  test "as failedConns increases, consecutiveHealthFailures increases, and it becomes fwDegraded at degradeThreshold":
    withMode("ok", proc() =
      let hs = track(newHostSession("host-fwd-health"))
      let spec = ForwardSpec(kind: fkLocal, bindAddr: defaultBindAddr,
                              bindPort: Port(18110), targetHost: "db.internal",
                              targetPort: Port(5432))
      let fw = newForward("t8", spec, hs)
      check waitForHostState(hs, hsConnected)

      tick(fw)
      check fw.state == fwActive
      check fw.proxy.isSome

      for i in 1 .. statemachine.degradeThreshold:
        fw.proxy.get().stats.recordFailed() ## Manually simulate a byproduct of real traffic
        tick(fw)
        check fw.consecutiveHealthFailures == i

      check fw.state == fwDegraded

      forward.teardown(fw)
      stopAndCleanup(hs))

# ---------------------------------------------------------------------------
# 9. fkRemote: the proxy is not started and stats is none, yet it still becomes fwActive
# ---------------------------------------------------------------------------

suite "fkRemote":
  test "does not start a proxy and stats is none, but still becomes fwActive":
    withMode("ok", proc() =
      let hs = track(newHostSession("host-fwd-remote"))
      let spec = ForwardSpec(kind: fkRemote, bindAddr: defaultBindAddr,
                             bindPort: Port(18112),
                                 targetHost: "internal.example",
                             targetPort: Port(80))
      let fw = newForward("t9", spec, hs)
      check waitForHostState(hs, hsConnected)

      tick(fw)
      check fw.state == fwActive
      check fw.proxy.isNone
      check fw.stats().isNone

      forward.teardown(fw)
      stopAndCleanup(hs))

# ---------------------------------------------------------------------------
# Cleanup: tear down all masters and remove the runtime/state directories
# ---------------------------------------------------------------------------

for hs in allSessions:
  hostsession.teardown(hs) ## Safety net that finishes instantly if each test already stopped it

removeDir(testRuntimeDir)
removeDir(testStateDir)
delEnv("POWARDER_FAKE_SSH_MODE")
delEnv("POWARDER_FAKE_SSH_LOG")
delEnv("POWARDER_RUNTIME_DIR")
delEnv("POWARDER_STATE_DIR")

# The fake ssh listener (nc / python3 / perl) is orphaned when
# `hostsession.teardown`'s last resort, SIGKILL, is sent, because the fake
# ssh side's trap does not fire. If it is left behind, the pipe inherited
# from the parent does not close, and `nimble test` **hangs** waiting for
# EOF (observed in practice: hung for 3 hours in a Linux container). The
# approach of closing the fd on the fake ssh side broke due to two issues
# -- dash's behavior and asyncdispatch's fd inheritance -- so it is
# reliably cleaned up here instead.
#
# The `[p]` bracket trick is the standard way to prevent `pkill` from
# matching its own command line and killing itself (hit this in practice;
# it results in exit 144).
discard execShellCmd("pkill -f '" & testRuntimeDir & "' >/dev/null 2>&1 || true")
