## Tests for `powarder/daemon/hostsession`.
##
## To test without a real SSH server, a fake ssh at `tests/fixtures/ssh` is
## placed at the front of `PATH` so powarder picks it up as `ssh`. The fake
## ssh's behavior is switched via `POWARDER_FAKE_SSH_MODE` (see
## `tests/fixtures/ssh` for details). The implemented modes are `ok` /
## `bind-failed` / `not-forwarded` / `no-master` / `auth-failed` /
## `slow-start`.

import std/[unittest, os, posix, options, monotimes, times, strutils]

import powarder/core/types
import powarder/core/errorclass
import powarder/daemon/hostsession

const fixturesDir = currentSourcePath().parentDir() / "fixtures"
const testRuntimeDir = "/tmp/pw-hs-rt"
const testStateDir = "/tmp/pw-hs-state"

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
  ## Put fake ssh at the front of PATH and isolate the runtime/state directories.
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
  ## them all down at the end of the file.

proc track(hs: HostSession): HostSession =
  allSessions.add(hs)
  hs

proc processAlive(pid: int): bool =
  ## Same check as `platform/procinfo.pidAlive`, but to respect the
  ## constraint of not importing `platform/` (another agent's area of
  ## ownership), it is minimally duplicated here in the test.
  if kill(Pid(pid), 0.cint) == 0:
    return true
  cint(osLastError()) == EPERM

proc waitForState(hs: HostSession; target: HostSessionState;
                  timeoutMs = 5000): bool =
  ## Keep calling `tick` until `target` is reached (at
  ## `readinessPollInterval` intervals). Instead of the daemon's real loop
  ## (500ms cycle), the test polls at a finer interval.
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while hs.state != target:
    tick(hs)
    if hs.state == target:
      return true
    if getMonoTime() >= deadline:
      return false
    sleep(readinessPollInterval.inMilliseconds.int)
  true

proc stopAndCleanup(hs: HostSession) =
  ## Helper for cleaning up after each test. Relying on `teardown` alone
  ## would dutifully wait out the `teardownGracePeriod` (5 seconds) every
  ## time `-O exit` comes up empty, slowing the tests down. So first stop
  ## quickly with `requestStop(immediate = true)` (which also sends
  ## SIGTERM internally), then call `teardown` as a last-resort safety net
  ## (it finishes instantly if the process is already dead).
  requestStop(hs, immediate = true)
  discard waitForState(hs, hsStopped, timeoutMs = 5000)
  teardown(hs)

# ---------------------------------------------------------------------------
# 1. newHostSession: key with fingerprint
# ---------------------------------------------------------------------------

suite "newHostSession: key":
  test "the same host yields the same key":
    withMode("ok", proc() =
      let a = newHostSession("host-key-a")
      let b = newHostSession("host-key-a")
      check a.key == b.key
      check a.key.fingerprint.len > 0)

  test "different hosts yield different keys":
    withMode("ok", proc() =
      let a = newHostSession("host-key-a")
      let b = newHostSession("host-key-b")
      check a.key != b.key
      check a.key.fingerprint != b.key.fingerprint)

# ---------------------------------------------------------------------------
# 2. Reference counting
# ---------------------------------------------------------------------------

suite "reference counting":
  test "addForwardRef / removeForwardRef keep refCount and idleSince in sync":
    withMode("ok", proc() =
      let hs = newHostSession("host-refcount")
      check refCount(hs) == 0
      check hs.idleSince.isNone

      addForwardRef(hs, "fwd-1")
      check refCount(hs) == 1
      check hs.idleSince.isNone ## Cleared because it increased from 0

      addForwardRef(hs, "fwd-2")
      check refCount(hs) == 2
      addForwardRef(hs, "fwd-2") ## Adding the same id twice is idempotent
      check refCount(hs) == 2

      removeForwardRef(hs, "fwd-1")
      check refCount(hs) == 1
      check hs.idleSince.isNone ## Not yet back to 0

      removeForwardRef(hs, "fwd-2")
      check refCount(hs) == 0
      check hs.idleSince.isSome ## Set because it reached 0

      addForwardRef(hs, "fwd-3")
      check refCount(hs) == 1
      check hs.idleSince.isNone) ## Cleared again because it increased

# ---------------------------------------------------------------------------
# 3. spawn -> hsConnected
# ---------------------------------------------------------------------------

suite "from spawn to hsConnected":
  test "in ok mode, it reaches hsIdle -> hsConnecting -> hsConnected":
    withMode("ok", proc() =
      let hs = track(newHostSession("host-spawn-ok"))
      check hs.state == hsIdle

      addForwardRef(hs, "fwd")
      check waitForState(hs, hsConnected)
      check hs.pid > 0
      check hs.process.isSome
      check isConnected(hs)

      stopAndCleanup(hs)
      check hs.state == hsStopped)

# ---------------------------------------------------------------------------
# 4. slow-start: readiness polling waits
# ---------------------------------------------------------------------------

suite "slow-start":
  test "stays in hsConnecting until the control socket appears after 3 seconds, then becomes hsConnected":
    withMode("slow-start", proc() =
      let hs = track(newHostSession("host-slow-start"))
      addForwardRef(hs, "fwd")

      tick(hs) ## hsIdle -> hsConnecting (spawn)
      check hs.state == hsConnecting

      tick(hs) ## the socket should not exist yet (mode that waits 3 seconds)
      check hs.state == hsConnecting

      check waitForState(hs, hsConnected, timeoutMs = 8000)

      stopAndCleanup(hs)
      check hs.state == hsStopped)

# ---------------------------------------------------------------------------
# 5. auth-failed: instant death -> hsReconnecting, backoff growth
# ---------------------------------------------------------------------------

suite "auth-failed":
  test "detects instant death and falls to hsReconnecting, with consecutiveFailures and backoff growing":
    withMode("auth-failed", proc() =
      let hs = track(newHostSession("host-auth-failed"))
      addForwardRef(hs, "fwd")

      check waitForState(hs, hsReconnecting)
      check hs.consecutiveFailures == 1
      check hs.backoffSeconds == 1.0
      check hs.nextRetryAt.isSome
      check hs.nextRetryAt.get() > getMonoTime()
      check hs.process.isNone ## Already reaped when death was detected

      # No matter how many times tick is called, it is not re-spawned until nextRetryAt arrives
      for i in 0 ..< 5:
        tick(hs)
        check hs.state == hsReconnecting

      # Force the backoff to expire without waiting, trigger a second failure, and confirm it doubles
      hs.nextRetryAt = some(getMonoTime() - initDuration(milliseconds = 10))
      tick(hs) ## hsReconnecting -> hsConnecting (re-spawn)
      check hs.state == hsConnecting

      check waitForState(hs, hsReconnecting)
      check hs.consecutiveFailures == 2
      check hs.backoffSeconds == 2.0

      stopAndCleanup(hs))

# ---------------------------------------------------------------------------
# 6. Error classification
# ---------------------------------------------------------------------------

suite "error classification":
  test "ekAuthFailed is classified from the auth-failed log and stored in lastErrorKind":
    withMode("auth-failed", proc() =
      let hs = track(newHostSession("host-error-classify"))
      addForwardRef(hs, "fwd")

      check waitForState(hs, hsReconnecting)
      check hs.lastErrorKind == ekAuthFailed
      check hs.lastError.len > 0

      stopAndCleanup(hs))

# ---------------------------------------------------------------------------
# 7. requestStop -> hsStopping -> hsStopped, no child process left after teardown
# ---------------------------------------------------------------------------

suite "requestStop and teardown":
  test "requestStop(immediate=true) enters hsStopping and proceeds to hsStopped; no process remains after teardown":
    withMode("ok", proc() =
      let hs = track(newHostSession("host-requeststop"))
      addForwardRef(hs, "fwd")
      check waitForState(hs, hsConnected)
      let pid = hs.pid
      check pid > 0
      check processAlive(pid)

      requestStop(hs, immediate = true)
      check hs.state == hsStopping ## Transitions synchronously and immediately

      check waitForState(hs, hsStopped)
      check hs.process.isNone

      teardown(hs) ## Safe to call even if already stopped (close to a no-op)
      check hs.state == hsStopped
      check not processAlive(pid)) ## Really gone at the OS level too

# ---------------------------------------------------------------------------
# 8. grace period
# ---------------------------------------------------------------------------

suite "grace period":
  test "keeps hsConnected if under idleGracePeriod even when refCount is 0":
    withMode("ok", proc() =
      let hs = track(newHostSession("host-grace"))
      addForwardRef(hs, "fwd")
      check waitForState(hs, hsConnected)

      removeForwardRef(hs, "fwd")
      check refCount(hs) == 0
      check hs.idleSince.isSome

      tick(hs)
      check hs.state == hsConnected ## Still within the grace period

      # Waiting 25 seconds would make the test too long, so rewrite idleSince into the past
      hs.idleSince = some(getMonoTime() - idleGracePeriod - initDuration(seconds = 1))
      tick(hs)
      check hs.state == hsStopping

      stopAndCleanup(hs)
      check hs.state == hsStopped)

  test "requestStop(immediate=true) enters the stop process immediately without waiting for grace":
    withMode("ok", proc() =
      let hs = track(newHostSession("host-grace-immediate"))
      addForwardRef(hs, "fwd")
      check waitForState(hs, hsConnected)

      requestStop(hs, immediate = true)
      check hs.state == hsStopping ## Transitions immediately without waiting for grace

      check waitForState(hs, hsStopped)
      teardown(hs))

# ---------------------------------------------------------------------------
# 9. Backoff reset
# ---------------------------------------------------------------------------

suite "backoff reset":
  test "rewriting lastConnectedAt into the past and ticking resets consecutiveFailures to 0":
    withMode("ok", proc() =
      let hs = track(newHostSession("host-backoff-reset"))
      # Simulate a state where failures had been continuing in the past
      hs.consecutiveFailures = 3
      hs.backoffSeconds = 8.0

      addForwardRef(hs, "fwd")
      check waitForState(hs, hsConnected)
      check hs.consecutiveFailures == 3 ## Not reset yet because 60 seconds have not passed

      hs.lastConnectedAt = some(getMonoTime() - connectedStableFor -
          initDuration(seconds = 1))
      tick(hs)
      check hs.consecutiveFailures == 0
      check hs.backoffSeconds == 0.0

      stopAndCleanup(hs))

# ---------------------------------------------------------------------------
# Cleanup: tear down all masters and remove the runtime/state directories
# ---------------------------------------------------------------------------

for hs in allSessions:
  teardown(hs) ## Safety net that finishes instantly if each test already stopped it

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
