## Lifecycle management for the SSH ControlMaster process (one long-lived
## `ssh -M -N` master per host).
##
## Each individual port forward only holds a reference count against the
## master via `addForwardRef` / `removeForwardRef`; the actual spawn /
## monitoring / reconnect / stop of the master is all driven by this module
## following the decisions of `core/statemachine.nextHostState()`.
## **All state-transition legality decisions are delegated to `statemachine`;
## this module never rewrites a transition with an if-statement.**
##
## The master's launch command line is assembled by
## `daemon/muxclient.masterCommandLine()` (never reassembled here). Running
## `-O check` / `-O exit` / `ssh -G` is likewise delegated to that same
## module's `checkMaster` / `exitMaster` / `resolveSshConfig`.
##
## ## Adopting orphan processes (M6)
##
## The actual adopt decision (liveness check, cmdline matching via
## `platform/procinfo`) is the responsibility of `daemon/orphan.nim`. What
## this module owns, given that decision, is just `adoptHostSession()`,
## which directly builds a `HostSession` in `hsConnected`, and the parts of
## `tick()` / `teardown()` that correctly monitor and stop a `HostSession`
## whose `process = none(Process)` (i.e. not our own child process).
##
## An adopted session has `adopted = true` set. Because **`peekExitCode` /
## `waitForExit` only work on our own child processes** (a `waitpid`
## constraint), while `adopted` we rely solely on `-O check`
## (`checkIntervalAdopted` -- shorter than the usual interval) for liveness
## monitoring, and use `posix.kill(pid, SIGTERM)` (which does not require a
## parent-child relationship) whenever we need to terminate it. There is no
## risk of it becoming a zombie (it is not our child, so init/launchd reaps
## it).

import std/[os, osproc, posix, options, monotimes, times, strutils]

import powarder/core/types
import powarder/core/statemachine
import powarder/core/paths
import powarder/core/sshgparse
import powarder/core/errorclass
import powarder/core/fmt
import powarder/daemon/muxclient

type
  HostSession* = ref object
    key*: HostSessionKey
    host*: string ## Host passed to ssh (the Host alias from ~/.ssh/config)
    extraArgs*: seq[string]
    ctlPath*: string
    logPath*: string
    process*: Option[Process] ## Some only if we spawned it ourselves; always none when adopted
    pid*: int
    argv*: seq[string]
      ## The set of substrings kept for `cmdlineMatches` matching at adopt
      ## time. Because `exec` in `/bin/sh -c 'exec ssh ...'` replaces the
      ## real process's argv from sh's to the ssh binary's own (see the doc
      ## comment on `platform/procinfo`), this holds only the fragments
      ## (`ctlPath` and `host`) that should actually show up in `ps`,
      ## rather than the whole sh -c wrapper (see `spawnMaster`).
    state*: HostSessionState
    forwardIds*: seq[string] ## IMPORTANT: the actual reference count; do not add a separate counter field
    consecutiveFailures*: int
    backoffSeconds*: float
    lastConnectedAt*: Option[MonoTime]
    connectingSince*: Option[MonoTime] ## Used for readiness-timeout detection
    nextRetryAt*: Option[MonoTime]
    idleSince*: Option[MonoTime] ## Timestamp when forwardIds became empty (used for the grace-period check)
    retry*: RetryPolicy
    lastError*: string ## Result of classifying the log tail with errorclass
    lastErrorKind*: ErrorKind
    adopted*: bool
      ## M6: whether this session was created by adopting an orphaned
      ## master. While `true`, `process` is always `none` and liveness
      ## monitoring depends solely on `-O check` (see the module doc
      ## comment). It reverts to `false` once replaced by a process we
      ## spawned ourselves (`spawnMaster`).
    lastPeriodicCheckAt: Option[MonoTime]
      ## Used to throttle the low-frequency safety-net `checkMaster` check
      ## while in `hsConnected`. An internal-only field not part of the
      ## public type definition (tests should not touch it).

const
  readinessTimeout* = initDuration(seconds = 15)
    ## ConnectTimeout=10 + margin. Measured in practice, the control socket
    ## appears after 273ms.
  readinessPollInterval* = initDuration(milliseconds = 150)
  idleGracePeriod* = initDuration(seconds = 25)
    ## Grace period during which the master is kept alive instead of being
    ## torn down immediately (-O exit) once the reference count hits 0.
    ## This absorbs, without a hiccup, the case where reload's diff
    ## application briefly drops the count to 0 (powarder's own version of
    ## ControlPersist).
  connectedStableFor* = initDuration(seconds = 60)
    ## Once hsConnected has been maintained for this long, reset the backoff.
  checkIntervalSelfSpawned* = initDuration(seconds = 15)
    ## peekExitCode does the main work, so -O check is just a safety net;
    ## a low frequency is fine.
  checkIntervalAdopted* = initDuration(seconds = 5)
    ## Adopted hosts cannot use `peekExitCode`, so `-O check` is the only
    ## means of liveness monitoring; use a shorter interval than
    ## `checkIntervalSelfSpawned` (M6).
  teardownGracePeriod* = initDuration(seconds = 5)
    ## Grace period after -O exit / SIGTERM before sending SIGKILL.

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

proc sanitizeForFilename(s: string): string =
  ## Preprocessing so the host name can be included in a log file name.
  ## Only collapses characters that could act as a path separator (leaving
  ## everything else as close to the original look as possible, for
  ## debugging).
  s.replace('/', '_')

proc readLogTail(path: string; maxLines = 50; maxBytes = 8192): string =
  ## Reads only the tail of the log file. Since this is only used as
  ## material for error classification (`errorclass.classify`), there is no
  ## need to read the whole log. By seeking to the last `maxBytes` of the
  ## file and reading from there, even a huge pre-rotation log does not
  ## have to be read in full. Returns an empty string without crashing if
  ## the file does not exist or cannot be opened.
  if not fileExists(path):
    return ""
  try:
    var f: File
    if not open(f, path, fmRead):
      return ""
    defer: f.close()
    let size = f.getFileSize()
    let start = max(0'i64, size - maxBytes.int64)
    f.setFilePos(start)
    let toRead = int(size - start)
    if toRead <= 0:
      return ""
    var buf = newString(toRead)
    let n = f.readBuffer(addr buf[0], toRead)
    buf.setLen(n)
    var lines = buf.splitLines()
    if lines.len > maxLines:
      lines = lines[^maxLines .. ^1]
    lines.join("\n")
  except CatchableError:
    ""

# ---------------------------------------------------------------------------
# Reference counting
# ---------------------------------------------------------------------------

proc refCount*(hs: HostSession): int {.inline.} =
  ## Just returns `hs.forwardIds.len` (a derived value; there is no separate counter).
  hs.forwardIds.len

proc addForwardRef*(hs: HostSession; forwardId: string) =
  ## Increments the reference count by directly operating on `forwardIds`.
  ## Adding the same id twice is idempotent (ignored). Clears `idleSince`
  ## when going from 0 to a positive count.
  if forwardId in hs.forwardIds:
    return
  let wasIdle = hs.forwardIds.len == 0
  hs.forwardIds.add(forwardId)
  if wasIdle:
    hs.idleSince = none(MonoTime)

proc removeForwardRef*(hs: HostSession; forwardId: string) =
  ## Decrements the reference count by directly operating on `forwardIds`.
  ## Sets `idleSince` once it reaches 0.
  var idx = -1
  for i, id in hs.forwardIds:
    if id == forwardId:
      idx = i
      break
  if idx < 0:
    return
  hs.forwardIds.delete(idx)
  if hs.forwardIds.len == 0:
    hs.idleSince = some(getMonoTime())

# ---------------------------------------------------------------------------
# Construction
# ---------------------------------------------------------------------------

proc newHostSession*(host: string; extraArgs: seq[string] = @[];
                     retry = initRetryPolicy()): HostSession =
  ## Resolves ssh -G via `muxclient.resolveSshConfig()` and builds a
  ## `HostSessionKey` from `sshgparse.fingerprint()`. ctlPath / logPath are
  ## also derived from paths. **Does not start the process yet** (state is
  ## hsIdle).
  let cfg = resolveSshConfig(host, extraArgs)
  let fp = fingerprint(cfg)
  let key = HostSessionKey(host: host, fingerprint: fp)
  let ctl = controlPath(fp)
  let fpPrefix = fp[0 ..< min(8, fp.len)]
  let log = tunnelLogPath(sanitizeForFilename(host) & "-" & fpPrefix)
  HostSession(
    key: key,
    host: host,
    extraArgs: extraArgs,
    ctlPath: ctl,
    logPath: log,
    process: none(Process),
    pid: 0,
    argv: @[],
    state: hsIdle,
    forwardIds: @[],
    consecutiveFailures: 0,
    backoffSeconds: 0.0,
    lastConnectedAt: none(MonoTime),
    connectingSince: none(MonoTime),
    nextRetryAt: none(MonoTime),
    idleSince: none(MonoTime),
    retry: retry,
    lastError: "",
    lastErrorKind: ekUnknown,
    adopted: false,
    lastPeriodicCheckAt: none(MonoTime),
  )

proc adoptHostSession*(host, fingerprint, ctlPath, logPath: string; pid: int;
    argv: seq[string]; forwardIds: seq[string] = @[];
    retry = initRetryPolicy()): HostSession =
  ## Constructor for adopting an orphaned master (M6). Expected to be
  ## called from `daemon/orphan.adoptOrphans`. Does not run `ssh -G`; uses
  ## the already-recorded `fingerprint` as-is. Performs no verification of
  ## its own, on the assumption that the caller has already confirmed
  ## liveness via `muxclient.checkMaster` and pid liveness plus cmdline
  ## match via `platform/procinfo`.
  ##
  ## `process = none(Process)` (since this is not our own child process,
  ## `peekExitCode` / `waitForExit` are fundamentally unusable). Setting
  ## `adopted = true` makes `tick()` rely on `-O check` alone for liveness
  ## monitoring, with the interval also shortened to `checkIntervalAdopted`
  ## (5 seconds). The state starts out as `hsConnected` directly (since we
  ## are taking over a master already confirmed to be alive, there is no
  ## need to wait for `hsConnecting`'s readiness check).
  let key = HostSessionKey(host: host, fingerprint: fingerprint)
  let now = getMonoTime()
  HostSession(
    key: key,
    host: host,
    extraArgs: @[],
    ctlPath: ctlPath,
    logPath: logPath,
    process: none(Process),
    pid: pid,
    argv: argv,
    state: hsConnected,
    forwardIds: forwardIds,
    consecutiveFailures: 0,
    backoffSeconds: 0.0,
    lastConnectedAt: some(now),
    connectingSince: none(MonoTime),
    nextRetryAt: none(MonoTime),
    idleSince: (if forwardIds.len == 0: some(now) else: none(MonoTime)),
    retry: retry,
    lastError: "",
    lastErrorKind: ekUnknown,
    adopted: true,
    lastPeriodicCheckAt: some(now),
  )

# ---------------------------------------------------------------------------
# Internal state-transition helpers
# ---------------------------------------------------------------------------

proc transition(hs: HostSession; event: HostEvent) =
  ## Internal helper that applies the result of `statemachine.nextHostState`
  ## as-is. Each branch of `tick` is designed to pass only "events that make
  ## sense in that state", so getting back `none` means an implementation
  ## bug that should never actually reach here. Still, to avoid taking down
  ## the whole daemon, silently ignore it and leave the state unchanged when
  ## `none` comes back (defensive programming; not logged since there is no
  ## logger layer yet).
  let next = nextHostState(hs.state, event)
  if next.isSome:
    hs.state = next.get()

proc reapOwnProcess(hs: HostSession; forceKill = false) =
  ## Reaps a process we spawned ourselves. `forceKill=true` SIGKILLs it
  ## first if it is still alive before reaping (for cases like a readiness
  ## timeout, where there is no reason to wait politely; SIGKILL takes
  ## effect immediately, so the subsequent `waitForExit` blocks only very
  ## briefly). If it has already exited, `waitForExit` just returns the
  ## exit code cached by `peekExitCode` and triggers no extra syscall
  ## (verified against the `std/osproc` implementation).
  if hs.process.isSome:
    let p = hs.process.get()
    if forceKill and p.peekExitCode() == -1:
      try:
        p.kill()
      except OSError:
        discard
    discard p.waitForExit()
    try:
      p.close()
    except CatchableError:
      discard
  hs.process = none(Process)
  hs.pid = 0

proc ownProcessExited(hs: HostSession): bool =
  ## Non-blockingly checks whether a process we spawned ourselves has
  ## exited. When `process` is None (M6: an adopted host), it is not our own
  ## child process, so `peekExitCode` is fundamentally unusable -- there is
  ## no way to tell. Naively treating it as "dead" here would cause it to be
  ## judged dead immediately after adoption, so it returns false (i.e.
  ## assume it is alive, and leave the actual judgment to the caller's
  ## `-O check`).
  if hs.process.isNone:
    return false
  hs.process.get().peekExitCode() != -1

proc recordFailureAndTransition(hs: HostSession; event: HostEvent) =
  ## Common post-processing for master death / readiness timeout. Classifies
  ## the error from the log tail, advances the failure counter and backoff,
  ## then transitions to hsReconnecting via `event` (heMasterDied /
  ## heReadinessTimeout). If the retry limit has been reached, goes on to
  ## apply `heRetryLimitReached` and advance all the way to hsFailed (the
  ## default `RetryPolicy` has no limit, so this normally never gets this
  ## far).
  let tail = readLogTail(hs.logPath)
  let kind = classify(tail)
  hs.lastErrorKind = kind
  hs.lastError = explain(kind, langEn,
      initErrorContext(host = hs.host, rawStderr = tail)).summary

  inc hs.consecutiveFailures
  hs.backoffSeconds = nextBackoff(hs.backoffSeconds, hs.retry.backoffMaxSeconds)
  hs.nextRetryAt = some(getMonoTime() +
      initDuration(milliseconds = (hs.backoffSeconds * 1000.0).int64))
  hs.connectingSince = none(MonoTime)
  hs.lastConnectedAt = none(MonoTime)
  hs.lastPeriodicCheckAt = none(MonoTime)

  transition(hs, event)
  if shouldGiveUp(hs.consecutiveFailures, hs.retry):
    transition(hs, heRetryLimitReached)

proc handleMasterDeath(hs: HostSession) =
  ## Handling for when the death of a self-spawned master is detected while
  ## in `hsConnecting` / `hsConnected`.
  reapOwnProcess(hs)
  recordFailureAndTransition(hs, heMasterDied)

proc handleReadinessTimeout(hs: HostSession) =
  ## Handling for when the control socket fails to appear within
  ## `readinessTimeout` while in `hsConnecting`. There is no reason to
  ## politely wait for a process that still hasn't connected after all this
  ## time, so it is SIGKILLed immediately.
  reapOwnProcess(hs, forceKill = true)
  recordFailureAndTransition(hs, heReadinessTimeout)

proc spawnMaster(hs: HostSession) =
  ## Actually starts the master. The parent directories of ctlPath / logPath
  ## are prepared here for the first time (so this is safe even for a host
  ## that has never connected before). Starts it in
  ## `/bin/sh -c 'exec ssh ...'` form (assembled by `masterCommandLine`).
  ## Because of `exec`, `sh`'s PID becomes ssh's PID, so `peekExitCode` can
  ## track the real ssh process (confirmed by measurement in practice; see
  ## the doc comment on `masterCommandLine`).
  ##
  ## One would like to say `options = {}` prevents pipes from being
  ## created... but checking the `std/osproc` implementation shows that as
  ## long as `poParentStreams notin options`, pipes for stdin/stdout/stderr
  ## are actually created regardless. However, since the master redirects
  ## its own stdout/stderr to `logPath` via a shell redirect, nothing ever
  ## writes to that pipe, so the situation where the pipe fills up and
  ## blocks the parent simply never arises (exactly the same reasoning and
  ## idiom as `daemon/muxclient.runSsh`, so see that doc comment too).
  ensureRuntimeDir()
  ensureStateDirs()

  # **Always clean up any existing ControlPath socket before starting.**
  #
  # Right after the daemon is `kill -9`ed, for example, the previous master
  # can still be alive as an orphan (with PPID=1). Normally
  # `daemon/orphan.nim` adopts it, but since saving to `state.json` only
  # happens every few seconds, **if the daemon crashes before the record is
  # saved there is no clue left to adopt from**. If we then start
  # `ssh -M -S <the same path>` on the same ControlPath as-is, we end up in
  # the broken state of **two masters sharing the same ControlPath
  # existing at once**, where it becomes indeterminate which one
  # `-O check` / `-O forward` reaches, and things get stuck (hit this in
  # practice).
  #
  # So before starting, we always go through "if it's alive, explicitly end
  # it with `-O exit`; if it's a leftover socket, unlink it." The only thing
  # discarded is the previous generation's connection, so the side effect is
  # just "one re-authentication happens" -- cheap compared to the risk of
  # two masters coexisting.
  #
  # Use `paths.socketExists` (`os.fileExists` only checks `S_ISREG`, so it
  # always returns false for a socket).
  if socketExists(hs.ctlPath):
    let (aliveBefore, oldPid) = checkMaster(hs.ctlPath, hs.host)
    if aliveBefore:
      discard exitMaster(hs.ctlPath, hs.host)
      # `-O exit` only means "the exit request was sent" (measured in
      # practice). Wait briefly for the socket to disappear, and push with
      # SIGTERM if it doesn't.
      var waited = 0
      while socketExists(hs.ctlPath) and waited < 2000:
        sleep(50)
        waited += 50
      if socketExists(hs.ctlPath) and oldPid > 0:
        discard posix.kill(Pid(oldPid), SIGTERM)
        sleep(200)
    removeFile(hs.ctlPath) ## Remove the leftover (or whatever didn't finish exiting)

  let cmd = masterCommandLine(hs.ctlPath, hs.logPath, hs.host, hs.extraArgs)
  # `hs.argv` holds only `ctlPath` and `host`, not `cmd` itself (the
  # `/bin/sh -c 'exec ssh ...'`). Because `exec` replaces the real
  # process's argv from sh's to the ssh binary's own (see the doc comment
  # on the type definition), these two are the only fragments that
  # `platform/procinfo.cmdlineMatches` can actually match against what
  # shows up in `ps`.
  hs.argv = @[hs.ctlPath, hs.host]
  let process = startProcess(cmd[0], args = cmd[1 .. ^1], options = {})
  hs.process = some(process)
  hs.pid = process.processID()
  hs.connectingSince = some(getMonoTime())
  hs.adopted = false ## Now that we spawned it ourselves, it is no longer adopt-derived

proc nudgeStop(hs: HostSession) =
  ## While in `hsStopping`, prompts the process to stop if it is still alive.
  ##
  ## Do not over-trust a success report from `-O exit`: the fake ssh
  ## fixture's `-O exit` is just a simple stub that is not actually tied to
  ## the real master process's liveness, so the real process can still be
  ## alive even when success is reported (this can happen with real ssh too,
  ## depending on timing). So we do not branch on `exitMaster`'s return
  ## value; instead, after politely trying `-O exit`, we send SIGTERM on top
  ## regardless. Sending SIGTERM to an already-dead process just has its
  ## error ignored with no side effect, and `kill(2)` itself is
  ## non-blocking, so it does not stall the tick for long. The actual
  ## confirmation of termination is left to subsequent ticks'
  ## `ownProcessExited` (self-spawned) / `-O check` (adopted).
  discard exitMaster(hs.ctlPath, hs.host)
  if hs.process.isSome:
    try:
      hs.process.get().terminate()
    except OSError:
      discard
  elif hs.pid > 0:
    # An adopted master: has no `Process`, so `terminate` cannot be used.
    # Send SIGTERM via `posix.kill`, which does not require a parent-child
    # relationship (M6).
    discard posix.kill(Pid(hs.pid), SIGTERM)

proc maybeStartConnecting(hs: HostSession) =
  ## If refCount > 0, applies hePreparedToConnect and spawns the master.
  ## Since `hePreparedToConnect -> hsConnecting` is valid in
  ## `nextHostState` from both `hsIdle` and `hsStopped`, this shared logic
  ## can be reused for both branches (so a new `HostSession` does not have
  ## to be rebuilt when references increase again from `hsStopped`).
  if refCount(hs) > 0:
    transition(hs, hePreparedToConnect)
    if hs.state == hsConnecting:
      spawnMaster(hs)

# ---------------------------------------------------------------------------
# tick
# ---------------------------------------------------------------------------

proc tick*(hs: HostSession) =
  ## Called every time from the daemon's 500ms loop. Advances only the
  ## processing needed for the current state, once (even if the state
  ## changes within the same call, it does not go on to do the processing
  ## for the next state -- that happens only on the next `tick` call).
  ##
  ## **Why this is a synchronous function**: `checkMaster` / `exitMaster`
  ## launch a short-lived ssh subprocess and `waitForExit` on it, so they
  ## block for tens of milliseconds. But this only happens once, at the
  ## moment of readiness confirmation, and thereafter only at
  ## `checkIntervalSelfSpawned` (15 second) intervals. Blocking of this
  ## magnitude is small enough relative to the daemon's overall
  ## responsiveness to be acceptable. Making this async would add the
  ## complexity of mixing `osproc` (which assumes a synchronous API) with
  ## `asyncdispatch`, while the benefit gained (shaving off these rare
  ## tens-of-milliseconds blocks) would be small -- so it is deliberately
  ## left synchronous.
  case hs.state
  of hsIdle:
    maybeStartConnecting(hs)

  of hsConnecting:
    if ownProcessExited(hs):
      handleMasterDeath(hs)
      return
    if socketExists(hs.ctlPath):
      ## Don't use the pid that `checkMaster` returns: for the self-spawned
      ## case we already know the correct pid (`hs.pid`) from spawn time, so
      ## there is no need to overwrite it. In fact, measured in practice,
      ## the fake ssh fixture's `-O check` returns not the real master's pid
      ## but the (short-lived) `$$` of the `-O check` invocation itself, so
      ## overwriting here would end up monitoring the wrong pid (real ssh
      ## should return the correct pid, but for the self-spawned case there
      ## is no reason to overwrite it in the first place).
      let (alive, _) = checkMaster(hs.ctlPath, hs.host)
      if alive:
        hs.lastConnectedAt = some(getMonoTime())
        hs.lastPeriodicCheckAt = some(getMonoTime())
        hs.connectingSince = none(MonoTime)
        transition(hs, heCheckSucceeded)
        return
      # The socket exists but the check failed (a rare case). Leave it to
      # the readiness-timeout check below and keep waiting on subsequent
      # ticks.
    if hs.connectingSince.isSome and
        getMonoTime() - hs.connectingSince.get() >= readinessTimeout:
      handleReadinessTimeout(hs)

  of hsConnected:
    if ownProcessExited(hs):
      handleMasterDeath(hs)
      return
    if hs.lastConnectedAt.isSome and
        getMonoTime() - hs.lastConnectedAt.get() >= connectedStableFor:
      hs.consecutiveFailures = 0
      hs.backoffSeconds = 0.0
    # An adopted host (`process` is None) cannot use `peekExitCode`, and
    # `-O check` is the only means of liveness monitoring, so shorten the
    # interval (M6).
    let checkInterval =
      if hs.adopted: checkIntervalAdopted else: checkIntervalSelfSpawned
    if hs.lastPeriodicCheckAt.isNone or
        getMonoTime() - hs.lastPeriodicCheckAt.get() >= checkInterval:
      hs.lastPeriodicCheckAt = some(getMonoTime())
      let (alive, _) = checkMaster(hs.ctlPath, hs.host)
      if not alive:
        handleMasterDeath(hs)
        return
    if refCount(hs) == 0 and hs.idleSince.isSome and
        getMonoTime() - hs.idleSince.get() >= idleGracePeriod:
      transition(hs, heIdleGraceExpired)
      if hs.state == hsStopping:
        nudgeStop(hs)

  of hsReconnecting:
    if hs.nextRetryAt.isSome and getMonoTime() >= hs.nextRetryAt.get():
      hs.nextRetryAt = none(MonoTime)
      if refCount(hs) > 0:
        transition(hs, hePreparedToConnect)
        if hs.state == hsConnecting:
          spawnMaster(hs)
      else:
        # There is no point reconnecting once the backoff expires while
        # nothing is referencing this host. Because hsReconnecting holds no
        # live process, heStopRequested drops straight to hsStopped without
        # going through hsStopping (see the design notes in
        # statemachine.nim).
        transition(hs, heStopRequested)

  of hsStopping:
    if hs.process.isSome:
      if ownProcessExited(hs):
        reapOwnProcess(hs)
        transition(hs, heProcessReaped)
        return
    else:
      # An adopted master: `waitpid` cannot be used, so check liveness with
      # `-O check` (M6). `nudgeStop` should already have sent `-O exit` /
      # SIGTERM, so here we just need to confirm whether it has died yet.
      let (alive, _) = checkMaster(hs.ctlPath, hs.host)
      if not alive:
        hs.pid = 0
        transition(hs, heProcessReaped)
        return
    nudgeStop(hs)

  of hsStopped:
    maybeStartConnecting(hs)

  of hsFailed:
    ## The gave-up state. Unreachable with the default `RetryPolicy` (no
    ## limit). Getting out of it requires applying `heRestartRequested`, but
    ## the public API for that (e.g. an explicit retry command) is out of
    ## scope for M3, so it is not implemented here.
    discard

# ---------------------------------------------------------------------------
# Explicit stop
# ---------------------------------------------------------------------------

proc requestStop*(hs: HostSession; immediate = false) =
  ## Explicit stop.
  ##
  ## - `immediate = false` (default): while in `hsConnected`, this merely
  ##   empties `forwardIds` and sets `idleSince`, leaving it to the normal
  ##   grace-period check (the `idleGracePeriod` expiry check in `tick`). In
  ##   any other state, the notion of a grace period does not exist on the
  ##   state machine at all (`heStopRequested` is always applied
  ##   immediately), so the transition happens right away.
  ## - `immediate = true` (corresponds to `powarder down`): applies
  ##   `heStopRequested` right now without waiting for the grace period, and
  ##   if needed, also advances the stop processing once on the spot.
  hs.forwardIds = @[]
  if hs.state == hsConnected and not immediate:
    if hs.idleSince.isNone:
      hs.idleSince = some(getMonoTime())
    return
  transition(hs, heStopRequested)
  if hs.state == hsStopping:
    nudgeStop(hs)

proc waitUntilDead(p: Process; timeout: Duration): bool =
  ## Waits, via non-blocking polling, for `p` to exit within `timeout`.
  let deadline = getMonoTime() + timeout
  while p.peekExitCode() == -1:
    if getMonoTime() >= deadline:
      return false
    sleep(20)
  true

proc teardown*(hs: HostSession) =
  ## Synchronously and completely shuts it down (for the daemon's graceful
  ## shutdown).
  ##
  ## Unlike the asynchronous `hsStopping` transition driven by `tick`, this
  ## must guarantee that "no process remains once the call returns", no
  ## matter which state it is called from. So rather than applying the
  ## state machine's events one at a time, it directly executes the
  ## sequence liveness check -> `-O exit` -> grace period -> SIGTERM ->
  ## grace period -> SIGKILL -> `waitForExit`, and finally sets `hsStopped`
  ## directly (bypassing `nextHostState`. Strictly speaking, going from
  ## hsConnecting would require applying events in two stages, and the path
  ## differs per state, which gets cumbersome -- so under teardown's
  ## contract of "force it to a definite stop", setting it directly is the
  ## more straightforward choice).
  ##
  ## Always calls `waitForExit` at the end: `osproc` has no SIGCHLD handler,
  ## so merely calling `terminate`/`kill` would leave a zombie behind.
  if hs.process.isSome:
    let p = hs.process.get()
    if p.peekExitCode() == -1:
      discard exitMaster(hs.ctlPath, hs.host)
      if not waitUntilDead(p, teardownGracePeriod):
        try:
          p.terminate()
        except OSError:
          discard
        if not waitUntilDead(p, teardownGracePeriod):
          try:
            p.kill()
          except OSError:
            discard
    discard p.waitForExit()
    try:
      p.close()
    except CatchableError:
      discard
  elif hs.adopted and hs.pid > 0:
    # An adopted master: has no `Process`, so `waitForExit` cannot be used
    # (M6). Try `-O exit`, and if `-O check` still confirms it alive, just
    # send SIGTERM and leave it at that (since `waitpid` is unavailable
    # there is no way to confirm termination, but since it is not our
    # child, there is no risk of it becoming a zombie -- init/launchd reaps
    # it).
    discard exitMaster(hs.ctlPath, hs.host)
    let (alive, _) = checkMaster(hs.ctlPath, hs.host)
    if alive:
      discard posix.kill(Pid(hs.pid), SIGTERM)
  hs.process = none(Process)
  hs.pid = 0
  hs.forwardIds = @[]
  hs.state = hsStopped

# ---------------------------------------------------------------------------
# Display
# ---------------------------------------------------------------------------

proc isConnected*(hs: HostSession): bool {.inline.} =
  hs.state == hsConnected

proc describeState*(hs: HostSession): string =
  ## For `powarder hosts` display (makes state and retry count human-readable).
  case hs.state
  of hsIdle: "idle"
  of hsConnecting: "connecting"
  of hsConnected: "connected"
  of hsReconnecting:
    var s = "reconnecting (failures: " & $hs.consecutiveFailures
    if hs.nextRetryAt.isSome:
      let remain = hs.nextRetryAt.get() - getMonoTime()
      let clipped = if remain > DurationZero: remain else: DurationZero
      s.add(", retry in " & formatDuration(clipped))
    s.add(")")
    s
  of hsStopping: "stopping"
  of hsStopped: "stopped"
  of hsFailed: "failed (gave up after " & $hs.consecutiveFailures & " failures)"
