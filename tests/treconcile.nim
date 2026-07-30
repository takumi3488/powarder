## Tests for `powarder/daemon/registry` and `powarder/daemon/reconcile`.
##
## To test without a real SSH server, we place the fake ssh at
## `tests/fixtures/ssh` at the front of `PATH` and let powarder pick it up
## as `ssh` (the same technique as `thostsession.nim` / `tforward.nim`; the
## environment setup is carried over as-is).
## The implemented modes are `ok` / `bind-failed` / `not-forwarded` /
## `no-master` / `auth-failed` / `slow-start`. Here we mainly use only the
## `ok` mode (what registry/reconcile look at is not the failure recovery
## of individual hosts or forwards, but reconciling against the "desired
## state", so the failure-case variations are already covered on the
## `thostsession.nim` / `tforward.nim` side).

import std/[unittest, os, posix, tables, monotimes, times, strutils]
import std/nativesockets ## Needed because the auto-generated `==` for
                          ## `ForwardSpec` uses `Port`'s `==` internally
                          ## (same reason as in `reconcile.nim`).
import std/asyncdispatch

import powarder/core/types
import powarder/core/forwardspec
import powarder/daemon/hostsession
import powarder/daemon/forward
import powarder/daemon/registry
import powarder/daemon/reconcile

const fixturesDir = currentSourcePath().parentDir() / "fixtures"
const testRuntimeDir = "/tmp/pw-rec-rt"
const testStateDir = "/tmp/pw-rec-state"

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
  ## Puts fake ssh at the front of PATH and isolates the runtime/state
  ## directories.
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

var allRegistries: seq[Registry]
  ## To avoid missing cleanup, remember every generated Registry and
  ## teardownAll them all at the end of the file (the same technique as
  ## `allSessions` in `thostsession.nim`).

proc track(reg: Registry): Registry =
  allRegistries.add(reg)
  reg

proc processAlive(pid: int): bool =
  ## Same judgment as `platform/procinfo.pidAlive`, but to respect the
  ## constraint of not importing `platform/` (that's another agent's
  ## territory), we duplicate just the minimum inside the test (same
  ## technique as `thostsession.nim`).
  if kill(Pid(pid), 0.cint) == 0:
    return true
  cint(osLastError()) == EPERM

proc newTunnelConfig(name, host: string; spec: ForwardSpec; autostart = true;
    profile = ""; sshExtraArgs: seq[string] = @[]): TunnelConfig =
  ## A small helper that assembles a `TunnelConfig` for tests.
  TunnelConfig(name: name, host: host, spec: spec, autostart: autostart,
      profile: profile, sshExtraArgs: sshExtraArgs, retry: initRetryPolicy())

proc waitUntil(reg: Registry; cond: proc(): bool {.closure.};
    timeoutMs = 5000): bool =
  ## Synchronous polling. Used to wait for a transition that doesn't
  ## involve async internal processing, like waiting for a host to
  ## connect (same technique as `thostsession.waitForState`).
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while not cond():
    tickAll(reg)
    if cond():
      return true
    if getMonoTime() >= deadline:
      return false
    sleep(20)
  true

proc pollAsync(reg: Registry; cond: proc(): bool {.closure.}; tries = 300;
    delayMs = 20): Future[bool] {.async.} =
  ## Confirming detach's side effect (`probeUpstream`) progresses in
  ## stages through a Future, so just calling `tick` synchronously won't
  ## advance it. We poll while yielding control back to the event loop
  ## via `sleepAsync` (same technique as `tforward.pollForward`).
  for i in 0 ..< tries:
    tickAll(reg)
    if cond():
      return true
    await sleepAsync(delayMs)
  result = cond()

# ---------------------------------------------------------------------------
# 1. getOrCreateHost: the heart of master sharing
# ---------------------------------------------------------------------------

suite "getOrCreateHost":
  test "returns the same HostSession instance for the same host":
    withMode("ok", proc() =
      let reg = track(newRegistry())
      let a = getOrCreateHost(reg, "host-getorcreate-a")
      let b = getOrCreateHost(reg, "host-getorcreate-a")
      check a == b ## Identical as a reference (HostSession is a ref object)
      check reg.hosts.len == 1)

  test "a different host yields a different HostSession":
    withMode("ok", proc() =
      let reg = track(newRegistry())
      let a = getOrCreateHost(reg, "host-getorcreate-b1")
      let b = getOrCreateHost(reg, "host-getorcreate-b2")
      check a != b
      check a.key != b.key
      check reg.hosts.len == 2)

# ---------------------------------------------------------------------------
# 2. reconcile: idempotency
# ---------------------------------------------------------------------------

suite "reconcile: idempotency":
  test "calling twice with the same desired leaves the second call's actions empty":
    withMode("ok", proc() =
      let reg = track(newRegistry())
      let spec1 = ForwardSpec(kind: fkLocal, bindAddr: defaultBindAddr,
          bindPort: Port(18200), targetHost: "db1.internal", targetPort: Port(1))
      let spec2 = ForwardSpec(kind: fkLocal, bindAddr: defaultBindAddr,
          bindPort: Port(18201), targetHost: "db2.internal", targetPort: Port(2))
      let tc1 = newTunnelConfig("idem-1", "host-idem-1", spec1)
      let tc2 = newTunnelConfig("idem-2", "host-idem-2", spec2)
      let desired = DesiredState(tunnels: @[tc1, tc2], activeProfiles: @[])

      let report1 = reconcile(desired, reg)
      check report1.actions.len > 0 ## The first call creates the host/forward

      let report2 = reconcile(desired, reg)
      check report2.actions.len == 0
      check report2.warnings.len == 0)

# ---------------------------------------------------------------------------
# 3. reconcile: multiple tunnels pointing at the same host share a master
#    (M5 completion criterion)
# ---------------------------------------------------------------------------

suite "reconcile: master sharing":
  test "two tunnels pointing at the same host share a single master":
    withMode("ok", proc() =
      let reg = track(newRegistry())
      let spec1 = ForwardSpec(kind: fkLocal, bindAddr: defaultBindAddr,
          bindPort: Port(18202), targetHost: "db1.internal", targetPort: Port(1))
      let spec2 = ForwardSpec(kind: fkLocal, bindAddr: defaultBindAddr,
          bindPort: Port(18203), targetHost: "db2.internal", targetPort: Port(2))
      let tc1 = newTunnelConfig("share-1", "host-shared-master", spec1)
      let tc2 = newTunnelConfig("share-2", "host-shared-master", spec2)
      let desired = DesiredState(tunnels: @[tc1, tc2], activeProfiles: @[])

      discard reconcile(desired, reg)

      check reg.hosts.len == 1
      let host = getOrCreateHost(reg, "host-shared-master")
      check refCount(host) == 2)

# ---------------------------------------------------------------------------
# 4. reconcile: detaching a tunnel removed from the config
# ---------------------------------------------------------------------------

suite "reconcile: a tunnel removed from the config":
  test "the forward of a tunnel removed from the config gets detached":
    withMode("ok", proc() =
      let reg = track(newRegistry())
      let spec1 = ForwardSpec(kind: fkLocal, bindAddr: defaultBindAddr,
          bindPort: Port(18204), targetHost: "db1.internal", targetPort: Port(1))
      let spec2 = ForwardSpec(kind: fkLocal, bindAddr: defaultBindAddr,
          bindPort: Port(18205), targetHost: "db2.internal", targetPort: Port(2))
      let tc1 = newTunnelConfig("removed-1", "host-removed", spec1)
      let tc2 = newTunnelConfig("removed-2", "host-removed", spec2)
      let desired1 = DesiredState(tunnels: @[tc1, tc2], activeProfiles: @[])
      discard reconcile(desired1, reg)

      let id2 = forwardId(spec2, tc2.host)
      check id2 in reg.forwards

      let desired2 = DesiredState(tunnels: @[tc1], activeProfiles: @[])
      let report2 = reconcile(desired2, reg)

      check (raDetachForward, "removed-2") in report2.actions
      check reg.forwards[id2].state == fwDetaching)

# ---------------------------------------------------------------------------
# 5. reconcile: detach -> recreate when the spec changes
# ---------------------------------------------------------------------------

suite "reconcile: spec change":
  test "detaches and rebuilds when the id is the same but targetPort differs":
    withMode("ok", proc() =
      let reg = track(newRegistry())
      let spec1 = ForwardSpec(kind: fkLocal, bindAddr: defaultBindAddr,
          bindPort: Port(18206), targetHost: "db1.internal", targetPort: Port(1))
      let spec1b = ForwardSpec(kind: fkLocal, bindAddr: defaultBindAddr,
          bindPort: Port(18206), targetHost: "db1.internal", targetPort: Port(2))
      check spec1 != spec1b ## Only targetPort differs
      let tc1 = newTunnelConfig("spec-change", "host-spec-change", spec1)
      let id = forwardId(spec1, tc1.host)
      check id == forwardId(spec1b, tc1.host) ## The id is determined only
                                               ## by bindAddr:bindPort, so
                                               ## it doesn't change

      let desired1 = DesiredState(tunnels: @[tc1], activeProfiles: @[])
      discard reconcile(desired1, reg)

      let host = getOrCreateHost(reg, tc1.host)
      check waitUntil(reg, proc(): bool = isConnected(host))
      check reg.forwards[id].state == fwActive ## Already attached via
                                                ## tickAll after the host
                                                ## connects

      let tc1b = newTunnelConfig("spec-change", "host-spec-change", spec1b)
      let desired2 = DesiredState(tunnels: @[tc1b], activeProfiles: @[])
      let report2 = reconcile(desired2, reg)
      check (raDetachForward, "spec-change") in report2.actions
      check reg.forwards[id].state == fwDetaching

      proc scenario() {.async.} =
        check await pollAsync(reg, proc(): bool = id notin reg.forwards)
      waitFor scenario()

      let report3 = reconcile(desired2, reg)
      check (raCreateForward, "spec-change") in report3.actions
      check id in reg.forwards
      check reg.forwards[id].spec == spec1b)

# ---------------------------------------------------------------------------
# 6. reconcile: enabledOverride takes effect (M5 completion criterion)
# ---------------------------------------------------------------------------

suite "reconcile: enabledOverride":
  test "setEnabled(false) detaches it, and an unrelated reload does not resume it":
    withMode("ok", proc() =
      let reg = track(newRegistry())
      let spec1 = ForwardSpec(kind: fkLocal, bindAddr: defaultBindAddr,
          bindPort: Port(18207), targetHost: "db1.internal", targetPort: Port(1))
      let spec2 = ForwardSpec(kind: fkLocal, bindAddr: defaultBindAddr,
          bindPort: Port(18208), targetHost: "db2.internal", targetPort: Port(2))
      let tc1 = newTunnelConfig("stop-me", "host-stop-me", spec1)
      let tc2 = newTunnelConfig("keep-me", "host-keep-me", spec2)
      let desired = DesiredState(tunnels: @[tc1, tc2], activeProfiles: @[])
      discard reconcile(desired, reg)

      let id1 = forwardId(spec1, tc1.host)

      setEnabled(reg, "stop-me", false)
      let report2 = reconcile(desired, reg)
      check report2.actions == @[(raDisableForward, "stop-me")]
      check reg.forwards[id1].state == fwDetaching

      # An unrelated reload: stop-me / keep-me stay as they are; only a
      # new tunnel was added
      let spec3 = ForwardSpec(kind: fkLocal, bindAddr: defaultBindAddr,
          bindPort: Port(18209), targetHost: "db3.internal", targetPort: Port(3))
      let tc3 = newTunnelConfig("unrelated-new", "host-unrelated", spec3)
      let desired2 = DesiredState(tunnels: @[tc1, tc2, tc3], activeProfiles: @[])
      let report3 = reconcile(desired2, reg)

      check (raCreateForward, "unrelated-new") in report3.actions
      var resumed = false
      for a in report3.actions:
        if a.target == "stop-me":
          resumed = true
      check not resumed ## The stopped tunnel did not resume on its own
      check reg.forwards[id1].state == fwDetaching
      check isEnabled(reg, "stop-me", tc1.autostart) == false)

# ---------------------------------------------------------------------------
# 7. reconcile: profile filter
# ---------------------------------------------------------------------------

suite "reconcile: profile filter":
  test "when activeProfiles is empty, only tunnels with no profile are targeted":
    withMode("ok", proc() =
      let reg = track(newRegistry())
      let specNo = ForwardSpec(kind: fkLocal, bindAddr: defaultBindAddr,
          bindPort: Port(18210), targetHost: "db1.internal", targetPort: Port(1))
      let specDev = ForwardSpec(kind: fkLocal, bindAddr: defaultBindAddr,
          bindPort: Port(18211), targetHost: "db2.internal", targetPort: Port(2))
      let tcNo = newTunnelConfig("prof-none", "host-prof-none", specNo)
      let tcDev = newTunnelConfig("prof-dev", "host-prof-dev", specDev,
          profile = "dev")

      check isTargeted(tcNo, []) == true
      check isTargeted(tcDev, []) == false
      check isTargeted(tcDev, ["dev"]) == true

      let desiredEmpty = DesiredState(tunnels: @[tcNo, tcDev],
          activeProfiles: @[])
      discard reconcile(desiredEmpty, reg)

      check forwardsOfTunnel(reg, "prof-none").len == 1
      check forwardsOfTunnel(reg, "prof-dev").len == 0

      let desiredDev = DesiredState(tunnels: @[tcNo, tcDev],
          activeProfiles: @["dev"])
      discard reconcile(desiredDev, reg)

      check forwardsOfTunnel(reg, "prof-dev").len == 1)

# ---------------------------------------------------------------------------
# 8. tickAll: ordering and iterator safety
# ---------------------------------------------------------------------------

suite "tickAll":
  test "host -> forward -> removal of discardable forwards is safe even with multiple at once":
    withMode("ok", proc() =
      let reg = track(newRegistry())
      let host = getOrCreateHost(reg, "host-tickall")

      var ids: seq[string] = @[]
      for i in 0 ..< 3:
        let spec = ForwardSpec(kind: fkLocal, bindAddr: defaultBindAddr,
            bindPort: Port(18220 + i), targetHost: "db.internal",
            targetPort: Port(1 + i))
        let fw = addForward(reg, "tickall-" & $i, spec, host)
        ids.add(fw.id)

      check waitUntil(reg, proc(): bool = isConnected(host))
      for id in ids:
        check reg.forwards[id].state == fwActive
      check refCount(host) == 3

      for id in ids:
        requestDetach(reg.forwards[id])

      proc scenario() {.async.} =
        check await pollAsync(reg, proc(): bool = reg.forwards.len == 0)
      waitFor scenario()

      check reg.forwards.len == 0
      check reg.hosts.len == 1 ## Hosts are, by design, never actively
                                ## removed from reconcile/registry (left to
                                ## self-stop via the grace period)
      check refCount(host) == 0)

# ---------------------------------------------------------------------------
# 9. teardownAll: no leftover processes
# ---------------------------------------------------------------------------

suite "teardownAll":
  test "after teardownAll, forwards/hosts are empty and no process debris remains":
    withMode("ok", proc() =
      let reg = newRegistry() ## Not tracked, since this test itself
                              ## verifies teardown
      let host = getOrCreateHost(reg, "host-teardownall")
      let spec = ForwardSpec(kind: fkLocal, bindAddr: defaultBindAddr,
          bindPort: Port(18230), targetHost: "db.internal", targetPort: Port(1))
      discard addForward(reg, "teardown-fwd", spec, host)

      check waitUntil(reg, proc(): bool = isConnected(host))
      let pid = host.pid
      check pid > 0
      check processAlive(pid)

      teardownAll(reg)

      check reg.forwards.len == 0
      check reg.hosts.len == 0
      check not processAlive(pid))

# ---------------------------------------------------------------------------
# 10. pruneOverrides
# ---------------------------------------------------------------------------

suite "pruneOverrides":
  test "removes the override for a tunnel name that disappeared from the config":
    let reg = newRegistry() ## No withMode needed since ssh is never invoked
    setEnabled(reg, "ghost", false)
    setEnabled(reg, "real", true)

    pruneOverrides(reg, ["real"])

    check "ghost" notin reg.enabledOverride
    check "real" in reg.enabledOverride

# ---------------------------------------------------------------------------
# Cleanup: teardownAll every Registry and remove the runtime/state
# directories
# ---------------------------------------------------------------------------

for reg in allRegistries:
  teardownAll(reg) ## A safety net that finishes instantly if each test
                    ## already cleaned up

removeDir(testRuntimeDir)
removeDir(testStateDir)
delEnv("POWARDER_FAKE_SSH_MODE")
delEnv("POWARDER_FAKE_SSH_LOG")
delEnv("POWARDER_RUNTIME_DIR")
delEnv("POWARDER_STATE_DIR")

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
