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
import powarder/config/statefile
import powarder/daemon/reconcile
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
# 11. activeProfiles: restore from state.json, precedence over --profile, persist
# ---------------------------------------------------------------------------

proc removeStateFile() =
  ## All daemons in this file share one state file (`stateFile()` resolves
  ## via `POWARDER_STATE_DIR`, which `setupSuite` points at
  ## `testStateDir`), so each test in this suite removes it first to start
  ## from a clean slate.
  if fileExists(stateFile()):
    removeFile(stateFile())

proc captureStderr(body: proc()): string =
  ## Redirect fd 2 (stderr) to a file under the test's own state dir for
  ## the duration of `body`, then restore the original fd -- even if
  ## `body` raises -- and return what was written.
  ##
  ## `dup`/`dup2` operate on the raw fd, so the asyncdispatch state
  ## (kqueue fds) is untouched. The restore lives in a `finally`, so a
  ## failing `check` inside `body` cannot leave the test process with a
  ## redirected stderr.
  let savedFd = dup(2)
  let capturePath = testStateDir / "stderr-capture.log"
  let fd = open(cstring(capturePath), O_WRONLY or O_CREAT or O_TRUNC,
      0o644.cint)
  if fd < 0:
    discard close(savedFd)
    raise newException(IOError,
        "captureStderr: cannot open capture file: " & $strerror(errno))
  discard dup2(fd, 2)
  discard close(fd)
  try:
    body()
  finally:
    discard dup2(savedFd, 2)
    discard close(savedFd)
  readFile(capturePath)

suite "activeProfiles restore/precedence/persist":
  test "restore: a profile-tagged autostart tunnel is targeted again after activeProfiles is restored from state.json":
    # `powarder up -p dev` fixes the session profile and (via the fix under
    # test) persists it. The next daemon starts as bare `powarder daemon`
    # (no `--profile`), so this restore is the only way profile-tagged
    # tunnels come back up -- the actual bug this persistence exists for.
    removeStateFile()
    saveState(stateFile(), PersistedState(version: 1, savedAt: "",
        activeProfiles: @["dev"], hosts: @[], forwards: @[]))

    let spec = ForwardSpec(kind: fkLocal, bindAddr: defaultBindAddr,
        bindPort: Port(19310), targetHost: "db.internal", targetPort: Port(5432))
    let tc = newTc("dev-1", "host-daemon-dev-1", spec, autostart = true,
        profile = "dev")
    let d = track(newDaemon(freshOpts(@[tc]))) ## no --profile: activeProfiles left empty

    # Field-level contract: the persisted set is restored verbatim.
    check d.opts.activeProfiles == @["dev"]

    withMode("ok", proc() =
      proc scenario() {.async.} =
        # Effect-level contract (the observable bug): with the profile
        # restored, `reconcile.isTargeted` targets the profile-tagged
        # tunnel again -- the first tick schedules its forward...
        let r = await d.tickOnce()
        check (raCreateForward, "dev-1") in r.actions
        # ...and the fake ssh brings it to fwActive, exactly as if
        # `up -p dev` had been run against this session.
        check await waitUntilD(d, proc(): bool =
          let e = findEntry(listAll(d), "dev-1")
          e != nil and e["state"].getStr == "fwActive")
      waitFor scenario())
    shutdown(d)

  test "precedence: an explicit --profile wins over the persisted set and is never merged":
    # The stale state says "dev", but this daemon was launched with an
    # explicit `--profile prod`. Decision D4: the explicit set wins and is
    # never merged -- merging would silently re-activate tunnels the user
    # deliberately left out of the command line.
    removeStateFile()
    saveState(stateFile(), PersistedState(version: 1, savedAt: "",
        activeProfiles: @["dev"], hosts: @[], forwards: @[]))

    let specDev = ForwardSpec(kind: fkLocal, bindAddr: defaultBindAddr,
        bindPort: Port(19311), targetHost: "db.internal", targetPort: Port(5432))
    let specProd = ForwardSpec(kind: fkLocal, bindAddr: defaultBindAddr,
        bindPort: Port(19312), targetHost: "api.internal", targetPort: Port(443))
    let tcDev = newTc("dev-t", "host-daemon-dev-t", specDev,
        autostart = true, profile = "dev")
    let tcProd = newTc("prod-t", "host-daemon-prod-t", specProd,
        autostart = true, profile = "prod")
    let d = track(newDaemon(freshOpts(@[tcDev, tcProd],
        activeProfiles = @["prod"])))

    # Not overwritten, not merged with the persisted "dev".
    check d.opts.activeProfiles == @["prod"]

    withMode("ok", proc() =
      proc scenario() {.async.} =
        # Effect level: prod is targeted, dev (present in state.json but
        # absent from the explicit set) stays untargeted.
        check await waitUntilD(d, proc(): bool =
          let e = findEntry(listAll(d), "prod-t")
          e != nil and e["state"].getStr == "fwActive")
        let devEntry = findEntry(listAll(d), "dev-t")
        check devEntry != nil
        check devEntry["state"].getStr != "fwActive"
        check devEntry["status"].getStr == "stopped"
      waitFor scenario())
    shutdown(d)

  test "no state.json: activeProfiles stays empty and the daemon still runs":
    removeStateFile()
    let spec = ForwardSpec(kind: fkLocal, bindAddr: defaultBindAddr,
        bindPort: Port(19313), targetHost: "db.internal", targetPort: Port(5432))
    let tc = newTc("plain-1", "host-daemon-plain-1", spec, autostart = true)
    let d = track(newDaemon(freshOpts(@[tc])))
    check d.opts.activeProfiles.len == 0
    withMode("ok", proc() =
      proc scenario() {.async.} =
        # Nothing crashes, and a profile-less tunnel behaves exactly as
        # before the fix.
        check await waitUntilD(d, proc(): bool =
          let e = findEntry(listAll(d), "plain-1")
          e != nil and e["state"].getStr == "fwActive")
      waitFor scenario())
    shutdown(d)

  test "state.json with an empty activeProfiles array restores nothing and does not crash":
    removeStateFile()
    saveState(stateFile(), PersistedState(version: 1, savedAt: "",
        activeProfiles: @[], hosts: @[], forwards: @[]))
    let spec = ForwardSpec(kind: fkLocal, bindAddr: defaultBindAddr,
        bindPort: Port(19314), targetHost: "db.internal", targetPort: Port(5432))
    let tc = newTc("dev-2", "host-daemon-dev-2", spec, autostart = true,
        profile = "dev")
    let d = track(newDaemon(freshOpts(@[tc])))
    check d.opts.activeProfiles.len == 0

    # `withMode` only serves as the real `proc` wrapper that hosts the
    # async scenario (an `{.async.}` proc cannot be declared directly in
    # a `test` block; see the other suites' identical pattern). The mode
    # itself is irrelevant here: with no active profile the tunnel is
    # untargeted, so no ssh is ever spawned.
    withMode("ok", proc() =
      proc scenario() {.async.} =
        # Ticks run without raising; the profile-tagged tunnel stays
        # untargeted (docker compose semantics: no active profile, no
        # target).
        discard await d.tickOnce()
        discard await d.tickOnce()
        let e = findEntry(listAll(d), "dev-2")
        check e != nil
        check e["state"].getStr != "fwActive"
      waitFor scenario())
    shutdown(d)

  test "persist: `up --profile` is written to state.json and restored by the next daemon":
    removeStateFile()
    let spec = ForwardSpec(kind: fkLocal, bindAddr: defaultBindAddr,
        bindPort: Port(19315), targetHost: "db.internal", targetPort: Port(5432))
    let tc = newTc("dev-3", "host-daemon-dev-3", spec, autostart = true,
        profile = "dev")

    withMode("ok", proc() =
      proc scenario() {.async.} =
        # Session 1: started as a bare daemon, then the IPC handler
        # receives the same call `powarder up -p dev` makes. This fixes
        # the session profile without any --profile on the daemon cmdline.
        let d1 = track(newDaemon(freshOpts(@[tc])))
        let upRes = d1.server.handlers[mTunnelUp](%*{"profiles": %*["dev"]})
        check upRes["started"].len == 1
        check upRes["started"][0].getStr == "dev-3"
        check d1.opts.activeProfiles == @["dev"]

        # Bring the forward up so ticks run; the session profile must end
        # up in state.json (`buildPersistedState` carries it, and the
        # first tick always saves because `lastPersistedJson` starts
        # empty).
        check await waitUntilD(d1, proc(): bool =
          let e = findEntry(listAll(d1), "dev-3")
          e != nil and e["state"].getStr == "fwActive")
        check loadState(stateFile()).activeProfiles == @["dev"]
        shutdown(d1)

        # Session 2: a bare `powarder daemon` restart (no --profile).
        # The chain `up --profile` -> persisted -> restored must bring
        # dev-3 back to fwActive all on its own.
        let d2 = track(newDaemon(freshOpts(@[tc])))
        check d2.opts.activeProfiles == @["dev"]
        check await waitUntilD(d2, proc(): bool =
          let e = findEntry(listAll(d2), "dev-3")
          e != nil and e["state"].getStr == "fwActive")
        shutdown(d2)
      waitFor scenario())

  test "bare `powarder up` (profiles: []) does not clobber the session profile":
    # Regression: `cli/dispatch.cmdUp` ALWAYS serialises
    # `"profiles": args.profiles` into the tunnel.up payload. For a bare
    # `powarder up` that is an empty `seq[string]`, which `%*` renders as
    # a present-but-empty JArray. `handleTunnelUp` must treat that empty
    # array as "no `--profile` was given" (empty means don't touch, the
    # same precedence `newDaemon` applies to the persisted set), NOT as
    # "deactivate every profile".
    #
    # Without the non-empty guard, a bare `powarder up` writes
    # `"activeProfiles": []` to state.json, and the restore in `newDaemon`
    # then has nothing left to restore: the next daemon start silently
    # drops every profile-tagged tunnel even with `autostart: true`
    # (`reconcile.isTargeted` refuses them).
    removeStateFile()
    let spec = ForwardSpec(kind: fkLocal, bindAddr: defaultBindAddr,
        bindPort: Port(19316), targetHost: "db.internal", targetPort: Port(5432))
    let tc = newTc("dev-4", "host-daemon-dev-4", spec, autostart = true,
        profile = "dev")

    withMode("ok", proc() =
      proc scenario() {.async.} =
        let d = track(newDaemon(freshOpts(@[tc])))
        # The session profile is fixed the same way `powarder up -p dev`
        # fixes it (dispatch.cmdUp payload: empty names + the profile set).
        let upDev = d.server.handlers[mTunnelUp](%*{"names": %*[],
            "profiles": %*["dev"]})
        check upDev["started"].len == 1
        check upDev["started"][0].getStr == "dev-4"
        check d.opts.activeProfiles == @["dev"]
        check await waitUntilD(d, proc(): bool =
          let e = findEntry(listAll(d), "dev-4")
          e != nil and e["state"].getStr == "fwActive")
        # The set reached state.json (the first tick always saves).
        check loadState(stateFile()).activeProfiles == @["dev"]

        # Now the exact payload a bare `powarder up` sends follows.
        let upBare = d.server.handlers[mTunnelUp](%*{"names": %*[],
            "profiles": %*[]})
        check upBare["started"].len == 1
        check upBare["started"][0].getStr == "dev-4"
        # Field contract: the session set is untouched by the empty array.
        check d.opts.activeProfiles == @["dev"]
        # ...and the next ticks keep persisting dev, not an empty array.
        check await waitUntilD(d, proc(): bool =
          loadState(stateFile()).activeProfiles == @["dev"])
        check d.opts.activeProfiles == @["dev"]
        # Effect contract (the observable bug): the tunnel stayed
        # targeted/active across the bare up instead of being detached.
        # Ticks ran inside the waitUntilD above, so any detach caused by a
        # clobbered profile set would already have happened by now.
        let e = findEntry(listAll(d), "dev-4")
        check e != nil
        check e["state"].getStr == "fwActive"
        shutdown(d)
      waitFor scenario())

  test "a non-empty `profiles` array still replaces the session set":
    # The non-empty guard must not have turned the assignment into an
    # append/merge: `up -p dev` followed by `up -p prod` leaves exactly
    # `["prod"]`, never `["dev", "prod"]`.
    removeStateFile()
    let d = track(newDaemon(freshOpts(@[])))
    discard d.server.handlers[mTunnelUp](%*{"names": %*[],
        "profiles": %*["dev"]})
    check d.opts.activeProfiles == @["dev"]
    discard d.server.handlers[mTunnelUp](%*{"names": %*[],
        "profiles": %*["prod"]})
    check d.opts.activeProfiles == @["prod"]
    shutdown(d)

  test "restore log: a genuine restore emits the line":
    # The startup line is the only user-visible proof that the restore
    # took effect, so it must be there when it actually did.
    removeStateFile()
    saveState(stateFile(), PersistedState(version: 1, savedAt: "",
        activeProfiles: @["dev"], hosts: @[], forwards: @[]))
    let spec = ForwardSpec(kind: fkLocal, bindAddr: defaultBindAddr,
        bindPort: Port(19319), targetHost: "db.internal", targetPort: Port(5432))
    let tc = newTc("dev-5", "host-daemon-dev-5", spec, autostart = true,
        profile = "dev")
    let err = captureStderr(proc() =
      let d = track(newDaemon(freshOpts(@[tc]))) ## bare daemon: no --profile
      check d.opts.activeProfiles == @["dev"]
      shutdown(d))
    check "restored active profiles from state: dev" in err

  test "restore log: no state file means no line":
    # Nothing was restored, so claiming "restored from state" would be a
    # lie -- and the absence of the line is what tells a user the set
    # really came from somewhere else (or from nowhere).
    removeStateFile()
    let spec = ForwardSpec(kind: fkLocal, bindAddr: defaultBindAddr,
        bindPort: Port(19320), targetHost: "db.internal", targetPort: Port(5432))
    let tc = newTc("dev-6", "host-daemon-dev-6", spec, autostart = true,
        profile = "dev")
    let err = captureStderr(proc() =
      let d = track(newDaemon(freshOpts(@[tc])))
      check d.opts.activeProfiles.len == 0
      shutdown(d))
    check "restored active profiles" notin err

  test "restore log: an empty activeProfiles array in the state file means no line":
    # Guards the `and persisted.activeProfiles.len > 0` half of the
    # restore condition: an empty array is "nothing to restore". Without
    # that guard, a state file saved by a bare `powarder up` (see the
    # regression test above -- before the non-empty guard in
    # `handleTunnelUp` this is exactly what such a file contained) would
    # still print a bogus "restored" line.
    removeStateFile()
    saveState(stateFile(), PersistedState(version: 1, savedAt: "",
        activeProfiles: @[], hosts: @[], forwards: @[]))
    let spec = ForwardSpec(kind: fkLocal, bindAddr: defaultBindAddr,
        bindPort: Port(19321), targetHost: "db.internal", targetPort: Port(5432))
    let tc = newTc("dev-7", "host-daemon-dev-7", spec, autostart = true,
        profile = "dev")
    let err = captureStderr(proc() =
      let d = track(newDaemon(freshOpts(@[tc])))
      check d.opts.activeProfiles.len == 0
      shutdown(d))
    check "restored active profiles" notin err

# ---------------------------------------------------------------------------
# 12. activeProfiles: tunnel.down symmetry and persist gaps (review round 2)
# ---------------------------------------------------------------------------

suite "activeProfiles: tunnel.down symmetry and persist gaps":
  test "bare `powarder down` (profiles: []) stops what a bare `up` started":
    # The reproduced bug. `cli/dispatch.cmdDown` ALWAYS serialises
    # `"profiles": args.profiles` into the tunnel.down payload, so a bare
    # `powarder down` sends a present-but-empty JArray. Before the fix,
    # `handleTunnelDown` read that empty array verbatim and
    # `isTargeted(tc, @[])` matched only profile-LESS tunnels -- so the
    # profile-tagged tunnels a bare `powarder up` starts (and that this
    # change now keeps alive across restarts) were silently left running.
    # Verified end to end against a real host: `down` reported success,
    # the tunnel stayed `active`, and `curl` still returned 200. The wire
    # rule shared with `handleTunnelUp` -- an empty `profiles` array means
    # "the flag was not given", never "the empty set" -- makes the
    # fallback to `d.opts.activeProfiles` reachable, so a bare `down`
    # stops what a bare `up` started.
    removeStateFile()
    let spec = ForwardSpec(kind: fkLocal, bindAddr: defaultBindAddr,
        bindPort: Port(19322), targetHost: "db.internal", targetPort: Port(5432))
    let tc = newTc("down-1", "host-daemon-down-1", spec, autostart = true,
        profile = "dev")
    let d = track(newDaemon(freshOpts(@[tc])))

    withMode("ok", proc() =
      proc scenario() {.async.} =
        # The same call `powarder up -p dev` makes: fixes the session
        # profile and starts the tunnel.
        let upRes = d.server.handlers[mTunnelUp](%*{"names": %*[],
            "profiles": %*["dev"]})
        check upRes["started"].len == 1
        check upRes["started"][0].getStr == "down-1"
        check d.opts.activeProfiles == @["dev"]
        check await waitUntilD(d, proc(): bool =
          let e = findEntry(listAll(d), "down-1")
          e != nil and e["state"].getStr == "fwActive")

        # Now the exact payload a bare `powarder down` sends
        # (dispatch.cmdDown: empty names + empty profiles + immediate).
        let downRes = d.server.handlers[mTunnelDown](%*{"names": %*[],
            "profiles": %*[], "immediate": true})
        # The returned `stopped` list contains the tunnel...
        check downRes["stopped"].len == 1
        check downRes["stopped"][0].getStr == "down-1"
        # ...and the observable state is no longer active. (Before the
        # fix, the same call returned success while the tunnel kept
        # serving traffic.)
        check await waitUntilD(d, proc(): bool =
          let e = findEntry(listAll(d), "down-1")
          e != nil and e["state"].getStr != "fwActive")
        let e = findEntry(listAll(d), "down-1")
        check e["status"].getStr == "stopped"
        # It does not come back on its own: further ticks keep it down.
        for i in 0 ..< 5:
          discard await d.tickOnce()
          await sleepAsync(20)
        check findEntry(listAll(d), "down-1")["state"].getStr != "fwActive"
        shutdown(d)
      waitFor scenario())

  test "`down` with an explicit non-empty `profiles` targets exactly that profile":
    # The empty-array fallback must not have swallowed the explicit case:
    # when `--profile dev` IS given on the wire, only the dev tunnel is
    # stopped and a prod tunnel is left alone.
    removeStateFile()
    let specDev = ForwardSpec(kind: fkLocal, bindAddr: defaultBindAddr,
        bindPort: Port(19323), targetHost: "db.internal", targetPort: Port(5432))
    let specProd = ForwardSpec(kind: fkLocal, bindAddr: defaultBindAddr,
        bindPort: Port(19324), targetHost: "api.internal", targetPort: Port(443))
    let tcDev = newTc("down-dev", "host-daemon-down-dev", specDev,
        autostart = true, profile = "dev")
    let tcProd = newTc("down-prod", "host-daemon-down-prod", specProd,
        autostart = true, profile = "prod")
    let d = track(newDaemon(freshOpts(@[tcDev, tcProd])))

    withMode("ok", proc() =
      proc scenario() {.async.} =
        # Both profiles active, the way `powarder up -p dev -p prod`
        # leaves the session (`up` replaces the set, so both must arrive
        # in the one call).
        let upRes = d.server.handlers[mTunnelUp](%*{"names": %*[],
            "profiles": %*["dev", "prod"]})
        check upRes["started"].len == 2
        check d.opts.activeProfiles == @["dev", "prod"]
        check await waitUntilD(d, proc(): bool =
          let l = listAll(d)
          l.len == 2 and
            findEntry(l, "down-dev")["state"].getStr == "fwActive" and
            findEntry(l, "down-prod")["state"].getStr == "fwActive")

        # down -p dev: exactly the dev tunnel is stopped.
        let downRes = d.server.handlers[mTunnelDown](%*{"names": %*[],
            "profiles": %*["dev"], "immediate": true})
        check downRes["stopped"].len == 1
        check downRes["stopped"][0].getStr == "down-dev"
        check await waitUntilD(d, proc(): bool =
          let e = findEntry(listAll(d), "down-dev")
          e != nil and e["state"].getStr != "fwActive")
        # The prod tunnel keeps serving traffic.
        let prodEntry = findEntry(listAll(d), "down-prod")
        check prodEntry != nil
        check prodEntry["state"].getStr == "fwActive"
        # The session set is untouched by `down` (D5: handleTunnelDown
        # does not rewrite activeProfiles).
        check d.opts.activeProfiles == @["dev", "prod"]
        shutdown(d)
      waitFor scenario())

  test "an explicit daemon `--profile` is persisted to state.json":
    # README now claims a daemon started with `--profile prod` leaves
    # `prod` in the state file for later bare restarts. The precedence
    # test in the sibling suite proves the explicit set wins at startup;
    # this proves it also reaches disk (`buildPersistedState` carries
    # `d.opts.activeProfiles`, and the first tick always saves because
    # `lastPersistedJson` starts empty).
    removeStateFile()
    saveState(stateFile(), PersistedState(version: 1, savedAt: "",
        activeProfiles: @["dev"], hosts: @[], forwards: @[]))
    let d = track(newDaemon(freshOpts(@[], activeProfiles = @["prod"])))
    check d.opts.activeProfiles == @["prod"]

    withMode("ok", proc() =
      proc scenario() {.async.} =
        discard await d.tickOnce()
        check loadState(stateFile()).activeProfiles == @["prod"]
        shutdown(d)
      waitFor scenario())

  test "a non-empty `profiles` array replacement is observed in state.json":
    # The existing "non-empty replaces the set" test is field-only; this
    # closes the disk half: after `up -p dev` then `up -p prod`, the next
    # tick writes exactly `["prod"]` to state.json -- never a merged
    # `["dev", "prod"]`, never a leftover `["dev"]`. That file is what a
    # later bare restart restores from, so the replacement must be
    # observable there.
    removeStateFile()
    let d = track(newDaemon(freshOpts(@[])))

    withMode("ok", proc() =
      proc scenario() {.async.} =
        discard d.server.handlers[mTunnelUp](%*{"names": %*[],
            "profiles": %*["dev"]})
        check d.opts.activeProfiles == @["dev"]
        discard await d.tickOnce()
        check loadState(stateFile()).activeProfiles == @["dev"]

        discard d.server.handlers[mTunnelUp](%*{"names": %*[],
            "profiles": %*["prod"]})
        check d.opts.activeProfiles == @["prod"]
        discard await d.tickOnce()
        check loadState(stateFile()).activeProfiles == @["prod"]
        shutdown(d)
      waitFor scenario())

  test "restore log: an explicit --profile wins, so no restore line is emitted":
    # The exact case the log guard exists for: an explicit `--profile`
    # AND a non-empty persisted set. `newDaemon` must not log "restored
    # active profiles from state" -- the set came from the command line,
    # not from state.json, and claiming otherwise would lie to the user.
    removeStateFile()
    saveState(stateFile(), PersistedState(version: 1, savedAt: "",
        activeProfiles: @["dev"], hosts: @[], forwards: @[]))
    let err = captureStderr(proc() =
      let d = track(newDaemon(freshOpts(@[], activeProfiles = @["prod"])))
      check d.opts.activeProfiles == @["prod"]
      shutdown(d))
    check "restored active profiles" notin err

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
