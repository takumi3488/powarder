## Tests for `powarder/daemon/run`.
##
## To test without a real SSH server, a fake ssh at `tests/fixtures/ssh` is
## placed at the front of `PATH` so powarder picks it up as `ssh` (the same
## technique as `tforward.nim` / `treconcile.nim`; the environment setup is
## copied as-is too).
##
## `runDaemon()` runs an infinite loop (`mainLoop`), so it cannot be called
## directly inside the test process. In addition, as discovered in
## `tests/tipc.nim`, calling `fork()` **after** touching asyncdispatch (even
## once, via `newAsyncSocket`) breaks the child's kqueue fd, causing
## `accept()` to fail.
##
## For that reason, this file switches strategy depending on the test:
##
## 1. Only the **duplicate-launch prevention** test (the first one) uses
##    `fork()`. However, the forked child only ever takes the path
##    "lock acquisition fails -> return 7 immediately without touching
##    asyncdispatch such as `newIpcServer` at all", so the child is
##    unaffected even if the parent process has touched asyncdispatch
##    before or after this test (the same fork usage as
##    `tests/tplatform.nim`).
## 2. **All other tests** construct a `Daemon` directly via `newDaemon()`,
##    which carries the full set of handlers, and call
##    `d.server.handlers[methodName](params)` directly, without going
##    through the IPC socket. Because handlers are plain
##    `proc (params: JsonNode): JsonNode`, the RPC schema and logic can be
##    verified without ever running the actual socket communication /
##    accept loop (`serve()`).
## 3. Tests that need to advance the main loop (e.g. waiting for
##    `fwActive` to actually be reached after `tunnel.up`) repeatedly call
##    the public proc `tickOnce(d)` inside `waitFor` (the same "poll while
##    spinning the async event loop" technique as `waitUntil` /
##    `pollAsync` in `treconcile.nim`).

import std/[unittest, os, posix, json, tables, strutils]
import std/asyncdispatch
import std/nativesockets ## Needed because the auto-generated `==` for
                          ## `ForwardSpec` etc. uses `Port`'s `==` (same
                          ## reason as the other test files).

import powarder/core/types
import powarder/core/paths
import powarder/config/configfile
import powarder/platform/lock
import powarder/daemon/registry
import powarder/ipc/protocol
import powarder/ipc/server
import powarder/daemon/run

const fixturesDir = currentSourcePath().parentDir() / "fixtures"
const testRuntimeDir = "/tmp/pw-d-rt"
const testStateDir = "/tmp/pw-d-state"
const testConfigDir = "/tmp/pw-d-cfg"

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

proc setupSuite() =
  removeDir(testRuntimeDir)
  createDir(testRuntimeDir)
  removeDir(testStateDir)
  createDir(testStateDir)
  removeDir(testConfigDir)
  createDir(testConfigDir)
  putEnv(envRuntimeDir, testRuntimeDir)
  putEnv(envStateDir, testStateDir)
  let curPath = getEnv("PATH")
  if not curPath.startsWith(fixturesDir & ":"):
    putEnv("PATH", fixturesDir & ":" & curPath)
  delEnv("POWARDER_FAKE_SSH_MODE")
  delEnv("POWARDER_FAKE_SSH_LOG")

setupSuite()

proc processAlive(pid: int): bool =
  ## Same check as `platform/procinfo.pidAlive`, but following the existing
  ## test convention of not depending on `platform/` modules that run.nim
  ## doesn't use (see the doc comment on the same-named helper in
  ## `treconcile.nim`), it is minimally duplicated here in the test.
  if kill(Pid(pid), 0.cint) == 0:
    return true
  cint(osLastError()) == EPERM

var allDaemons: seq[Daemon]
  ## To avoid missing cleanup, remember every Daemon created and shut them
  ## all down at the end of the file (same technique as `allRegistries` in
  ## `treconcile.nim`).

proc track(d: Daemon): Daemon =
  allDaemons.add(d)
  d

var daemonCounter = 0

proc freshOpts(tunnels: seq[TunnelConfig] = @[];
    activeProfiles: seq[string] = @[]): DaemonOpts =
  ## Create a `DaemonOpts` with a config file and socket path independent
  ## per test.
  inc daemonCounter
  let cfgPath = testConfigDir / ("cfg-" & $daemonCounter & ".json")
  saveConfig(cfgPath, ConfigFile(version: 1, tunnels: tunnels,
      forbiddenKeyWarnings: @[]))
  DaemonOpts(configPath: cfgPath,
      socketPath: testRuntimeDir / ("d-" & $daemonCounter & ".sock"),
      activeProfiles: activeProfiles, tickIntervalMs: 50,
      stateSaveIntervalMs: 200)

proc newTc(name, host: string; spec: ForwardSpec; autostart = true;
    profile = ""): TunnelConfig =
  TunnelConfig(name: name, host: host, spec: spec, autostart: autostart,
      profile: profile, sshExtraArgs: @[], retry: initRetryPolicy())

proc waitUntilD(d: Daemon; cond: proc(): bool {.closure.}; tries = 300;
    delayMs = 20): Future[bool] {.async.} =
  ## Wait for `cond` to be satisfied while calling `tickOnce`. Checking the
  ## side effects of detach (`probeUpstream`) or the completion of attach
  ## requires spinning the event loop, so `sleepAsync` is used to create
  ## gaps between calls (same technique as `treconcile.pollAsync`).
  for i in 0 ..< tries:
    discard await d.tickOnce()
    if cond():
      return true
    await sleepAsync(delayMs)
  result = cond()

proc listAll(d: Daemon): JsonNode =
  d.server.handlers[mTunnelList](%*{"all": true})

proc findEntry(list: JsonNode; name: string): JsonNode =
  for e in list:
    if e["name"].getStr == name:
      return e
  nil

# ---------------------------------------------------------------------------
# 1. Duplicate-launch prevention: running runDaemon while the lock is held exits with code 7
# ---------------------------------------------------------------------------

suite "duplicate-launch prevention":
  test "runDaemon exits with code 7 while the lock is held":
    let rt = "/tmp/pw-d-lock-rt"
    removeDir(rt)
    createDir(rt)
    let hadRt = existsEnv(envRuntimeDir)
    let oldRt = getEnv(envRuntimeDir)
    putEnv(envRuntimeDir, rt)

    let heldLock = acquireSingletonLock(lockPath())
    heldLock.writePid(getCurrentProcessId())

    let pid = fork()
    if pid == 0:
      # Child process: lock acquisition fails, and only the path that
      # returns immediately without ever touching asyncdispatch (e.g.
      # `newIpcServer`) is taken. So the child is unaffected even if the
      # parent process uses asyncdispatch before or after this test (see
      # the run.nim module doc comment / the design note at the top of
      # this file).
      let code = runDaemon(DaemonOpts(socketPath: rt / "sub.sock"))
      exitnow(code.cint)

    var status: cint
    discard waitpid(pid, status, 0)
    check WIFEXITED(status)
    check WEXITSTATUS(status) == exitAlreadyRunning
    check WEXITSTATUS(status) == 7

    heldLock.release()
    if hadRt: putEnv(envRuntimeDir, oldRt)
    else: delEnv(envRuntimeDir)
    removeDir(rt)

# ---------------------------------------------------------------------------
# 2. daemon.ping / daemon.info
# ---------------------------------------------------------------------------

suite "daemon.ping / daemon.info":
  test "daemon.ping returns ok/pid/version":
    let d = track(newDaemon(freshOpts()))
    let res = d.server.handlers[mDaemonPing](nil)
    check res["ok"].getBool == true
    check res["pid"].getInt == getCurrentProcessId()
    check res["version"].getStr == daemonVersion
    shutdown(d)

  test "daemon.info has fields matching the schema":
    let d = track(newDaemon(freshOpts()))
    let res = d.server.handlers[mDaemonInfo](nil)
    check res["pid"].getInt == getCurrentProcessId()
    check res["version"].getStr == daemonVersion
    check res["socket"].getStr == d.server.path
    check res["uptime_seconds"].getInt >= 0
    check res["started_at"].getStr.len > 0
    check res["hosts"].getInt == 0
    check res["forwards"].getInt == 0
    check res["config_path"].getStr == d.opts.configPath
    shutdown(d)

# ---------------------------------------------------------------------------
# 3. tunnel.up registers a tunnel and it shows up in tunnel.list
# ---------------------------------------------------------------------------

suite "tunnel.up / tunnel.list":
  test "tunnel.up registers a tunnel and it shows up in tunnel.list":
    let spec = ForwardSpec(kind: fkLocal, bindAddr: defaultBindAddr,
        bindPort: Port(19301), targetHost: "db.internal", targetPort: Port(5432))
    let tc = newTc("up-1", "host-daemon-up-1", spec, autostart = false)
    let d = track(newDaemon(freshOpts(@[tc])))

    withMode("ok", proc() =
      proc scenario() {.async.} =
        # autostart = false and no override, so before up it shows disabled ("stopped")
        block:
          let before = findEntry(listAll(d), "up-1")
          check before != nil
          check before["status"].getStr == "stopped"
          check before["state"].getStr != "fwActive"

        let upRes = d.server.handlers[mTunnelUp](%*{"names": %*["up-1"]})
        check upRes["started"].len == 1
        check upRes["started"][0].getStr == "up-1"
        check upRes["failed"].len == 0

        check await waitUntilD(d, proc(): bool =
          let e = findEntry(listAll(d), "up-1")
          e != nil and e["state"].getStr == "fwActive")

      waitFor scenario())
    shutdown(d)

  test "specifying a nonexistent name goes into failed":
    let d = track(newDaemon(freshOpts(@[])))
    let res = d.server.handlers[mTunnelUp](%*{"names": %*["no-such-tunnel"]})
    check res["started"].len == 0
    check res["failed"].len == 1
    check res["failed"][0]["name"].getStr == "no-such-tunnel"
    shutdown(d)

# ---------------------------------------------------------------------------
# 4. tunnel.list: for -R rows, conns/total_conns/rx/tx/last_activity_seconds are null
# ---------------------------------------------------------------------------

suite "tunnel.list: -R stats are null":
  test "for a -R tunnel, conns/total_conns/rx/tx/last_activity_seconds are null":
    let spec = ForwardSpec(kind: fkRemote, bindAddr: defaultBindAddr,
        bindPort: Port(19302), targetHost: "internal.example", targetPort: Port(80))
    let tc = newTc("remote-1", "host-daemon-remote-1", spec, autostart = true)
    let d = track(newDaemon(freshOpts(@[tc])))

    withMode("ok", proc() =
      proc scenario() {.async.} =
        check await waitUntilD(d, proc(): bool =
          let e = findEntry(listAll(d), "remote-1")
          e != nil and e["state"].getStr == "fwActive")

        let e = findEntry(listAll(d), "remote-1")
        check e["type"].getStr == "R"
        check e["conns"].kind == JNull
        check e["total_conns"].kind == JNull
        check e["rx"].kind == JNull
        check e["tx"].kind == JNull
        check e["last_activity_seconds"].kind == JNull
      waitFor scenario())
    shutdown(d)

# ---------------------------------------------------------------------------
# 5. tunnel.stop -> state changes, and it does not restart on its own even after reload
# ---------------------------------------------------------------------------

suite "tunnel.stop and daemon.reload":
  test "after stop it is no longer fwActive, and an unrelated reload does not restart it":
    let spec = ForwardSpec(kind: fkLocal, bindAddr: defaultBindAddr,
        bindPort: Port(19303), targetHost: "db.internal", targetPort: Port(5432))
    let tc = newTc("stop-1", "host-daemon-stop-1", spec, autostart = true)
    let d = track(newDaemon(freshOpts(@[tc])))

    withMode("ok", proc() =
      proc scenario() {.async.} =
        check await waitUntilD(d, proc(): bool =
          let e = findEntry(listAll(d), "stop-1")
          e != nil and e["state"].getStr == "fwActive")

        let stopRes = d.server.handlers["tunnel.stop"](%*{"names": %*["stop-1"]})
        check stopRes["stopped"][0].getStr == "stop-1"

        # Reflected synchronously (reconcile is called directly inside the handler)
        block:
          let e = findEntry(listAll(d), "stop-1")
          check e != nil
          check e["state"].getStr != "fwActive"

        # Even after advancing a few ticks, it does not become fwActive again
        for i in 0 ..< 5:
          discard await d.tickOnce()
          await sleepAsync(20)
        check findEntry(listAll(d), "stop-1")["state"].getStr != "fwActive"

        # An unrelated reload does not restart it on its own
        discard d.server.handlers[mDaemonReload](nil)
        for i in 0 ..< 5:
          discard await d.tickOnce()
          await sleepAsync(20)
        check findEntry(listAll(d), "stop-1")["state"].getStr != "fwActive"
        check isEnabled(d.reg, "stop-1", tc.autostart) == false

      waitFor scenario())
    shutdown(d)

# ---------------------------------------------------------------------------
# 6. Two tunnels for the same host share one master, and host.list returns only one entry
# ---------------------------------------------------------------------------

suite "master sharing":
  test "two tunnels pointing at the same host share one master, and host.list returns only one entry":
    let hostName = "host-daemon-shared"
    let spec1 = ForwardSpec(kind: fkLocal, bindAddr: defaultBindAddr,
        bindPort: Port(19304), targetHost: "db1.internal", targetPort: Port(1))
    let spec2 = ForwardSpec(kind: fkLocal, bindAddr: defaultBindAddr,
        bindPort: Port(19305), targetHost: "db2.internal", targetPort: Port(2))
    let tc1 = newTc("share-a", hostName, spec1, autostart = true)
    let tc2 = newTc("share-b", hostName, spec2, autostart = true)
    let d = track(newDaemon(freshOpts(@[tc1, tc2])))

    withMode("ok", proc() =
      proc scenario() {.async.} =
        check await waitUntilD(d, proc(): bool =
          let l = listAll(d)
          if l.len != 2: return false
          for e in l:
            if e["state"].getStr != "fwActive": return false
          true)

        let hosts = d.server.handlers[mHostList](nil)
        check hosts.len == 1
        check hosts[0]["host"].getStr == hostName
        check hosts[0]["tunnels"].getInt == 2
      waitFor scenario())
    shutdown(d)

# ---------------------------------------------------------------------------
# 7. tunnel.inspect: a nonexistent name is RpcError(errTunnelNotFound)
# ---------------------------------------------------------------------------

suite "tunnel.inspect":
  test "a nonexistent tunnel name is RpcError(errTunnelNotFound)":
    let d = track(newDaemon(freshOpts(@[])))
    var caught = false
    try:
      discard d.server.handlers[mTunnelInspect](%*{"name": "no-such"})
    except RpcError as e:
      caught = true
      check e.code == errTunnelNotFound
    check caught
    shutdown(d)

# ---------------------------------------------------------------------------
# 8. daemon.reload: reflects configuration changes
# ---------------------------------------------------------------------------

suite "daemon.reload":
  test "adding a tunnel to the config and then reloading reflects it":
    let spec0 = ForwardSpec(kind: fkLocal, bindAddr: defaultBindAddr,
        bindPort: Port(19306), targetHost: "db.internal", targetPort: Port(5432))
    let tc0 = newTc("base-1", "host-daemon-base-1", spec0, autostart = true)
    let opts = freshOpts(@[tc0])
    let d = track(newDaemon(opts))

    withMode("ok", proc() =
      proc scenario() {.async.} =
        check await waitUntilD(d, proc(): bool = listAll(d).len == 1)

        let spec1 = ForwardSpec(kind: fkLocal, bindAddr: defaultBindAddr,
            bindPort: Port(19307), targetHost: "db2.internal", targetPort: Port(2))
        let tc1 = newTc("added-1", "host-daemon-added-1", spec1,
            autostart = true)
        saveConfig(opts.configPath, ConfigFile(version: 1, tunnels: @[tc0, tc1],
            forbiddenKeyWarnings: @[]))

        let reloadRes = d.server.handlers[mDaemonReload](nil)
        check reloadRes["tunnels"].getInt == 2
        check reloadRes.hasKey("actions")
        check reloadRes.hasKey("warnings")

        check await waitUntilD(d, proc(): bool =
          let l = listAll(d)
          l.len == 2 and findEntry(l, "added-1") != nil)
      waitFor scenario())
    shutdown(d)

# ---------------------------------------------------------------------------
# 9. Daemon state is not corrupted even if a handler raises an exception
# ---------------------------------------------------------------------------

suite "handler exception resilience":
  test "even if a handler raises an exception, the daemon's state is not corrupted and other handlers keep working":
    let d = track(newDaemon(freshOpts(@[])))
    d.server.register("test.boom", proc(p: JsonNode): JsonNode =
      raise newException(ValueError, "boom"))

    var caught = false
    try:
      discard d.server.handlers["test.boom"](nil)
    except ValueError:
      caught = true
    check caught

    # The daemon's state is not corrupted, and other handlers keep working
    check d.reg.forwards.len == 0
    check d.reg.hosts.len == 0
    let pingRes = d.server.handlers[mDaemonPing](nil)
    check pingRes["ok"].getBool == true
    shutdown(d)

# ---------------------------------------------------------------------------
# 10. graceful shutdown: reg.forwards / reg.hosts become empty, no leftovers
# ---------------------------------------------------------------------------

suite "graceful shutdown":
  test "after shutdown, reg.forwards / reg.hosts are empty and no process is left behind":
    let spec = ForwardSpec(kind: fkLocal, bindAddr: defaultBindAddr,
        bindPort: Port(19308), targetHost: "db.internal", targetPort: Port(5432))
    let tc = newTc("shutdown-1", "host-daemon-shutdown-1", spec,
        autostart = true)
    let d = newDaemon(freshOpts(@[tc])) ## Not tracked because this test itself verifies through shutdown

    withMode("ok", proc() =
      proc scenario() {.async.} =
        check await waitUntilD(d, proc(): bool =
          let e = findEntry(listAll(d), "shutdown-1")
          e != nil and e["state"].getStr == "fwActive")

        let hosts = d.server.handlers[mHostList](nil)
        let hpid = hosts[0]["pid"].getInt
        check hpid > 0
        check processAlive(hpid)

        let sockPath = d.server.path
        shutdown(d)

        check d.reg.forwards.len == 0
        check d.reg.hosts.len == 0
        check not processAlive(hpid)
        check not socketExists(sockPath)
      waitFor scenario())

# ---------------------------------------------------------------------------
# Cleanup: shutdown all Daemons and remove the runtime/state/config directories
# ---------------------------------------------------------------------------

for d in allDaemons:
  shutdown(d) ## Safety net that finishes instantly if each test already cleaned up

removeDir(testRuntimeDir)
removeDir(testStateDir)
removeDir(testConfigDir)
delEnv("POWARDER_FAKE_SSH_MODE")
delEnv("POWARDER_FAKE_SSH_LOG")
delEnv(envRuntimeDir)
delEnv(envStateDir)

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
