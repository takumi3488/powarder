## Adopting orphaned masters at daemon startup (M6).
##
## Even if the daemon dies from `kill -9` or a crash, the child `ssh -M ...
## -N` master process is picked up by init/launchd and **survives** (the
## tunnel itself is kept alive, so this is desirable behavior in itself).
## If we leave it alone as "an unknown process" when the daemon restarts,
## ports end up used twice or debris piles up. The role of this module is
## to **adopt it if it can be adopted**.
##
## ## Design of the alive/dead check (settled by empirical measurement.
## ## Do not change it.)
##
## 1. **The judgment "if resending the same forward with `-O forward`
##    returns `bind: Address already in use`, that proves it's alive" does
##    not hold.** Resending to an existing identical forward succeeds
##    idempotently with exit 0 / empty stderr (empirically verified on real
##    hardware). So it cannot be used for the alive/dead check.
## 2. **Instead, judge it by connecting directly to the UDS**
##    (`proxy/upstream.probeUpstream`). Behavior confirmed by measurement:
##    - forward is alive: connection succeeds and an SSH banner comes back
##    - already cancelled / master dead (socket file still remains):
##      `ECONNREFUSED`
##    - socket file doesn't even exist: `ENOENT`
##    This probe causes a real connection to the destination (unavoidable,
##    because OpenSSH's `channel_post_port_listener` opens a `direct-tcpip`
##    right after accept), but it is acceptable because adopt only happens
##    once at startup.
## 3. **An adopted master is not our own child process, so `peekExitCode` /
##    `waitForExit` cannot be used in principle** (`waitpid` can only reap
##    one's own children). `daemon/hostsession.adoptHostSession` sets
##    `adopted = true` and makes liveness monitoring depend solely on
##    `-O check` (see `hostsession.nim`).
## 4. **`ps` requires `-ww`.** `platform/procinfo.processCmdline` already
##    handles this.
##
## ## Mapping between host and forward
##
## `PersistedForward` itself does not hold its owning host (by design,
## `fkLocal` treats the local port as unique machine-wide, so `forwardId`
## does not include the host; see `core/forwardspec.forwardId`'s doc
## comment). Because of that, the mapping is done by walking each
## `PersistedHostSession.forwardIds` (the "list of forward ids belonging to
## me" held on the host side). If a host could not be adopted
## (`aoNoSocket` / `aoDeadReclaimed` / `aoMismatch`), any forward that
## belonged to it is not processed at all (its persisted record is quietly
## discarded). If the tunnel still exists in the config, the subsequent
## normal `reconcile` will simply recreate a new host and a new forward.

import std/[os, tables, asyncdispatch]

import powarder/core/types
import powarder/core/paths
import powarder/config/statefile
import powarder/daemon/muxclient
import powarder/daemon/hostsession
import powarder/daemon/forward
import powarder/daemon/registry
import powarder/proxy/upstream
import powarder/platform/procinfo

type
  AdoptOutcome* = enum
    aoAdopted       ## Was alive, so we adopted it
    aoDeadReclaimed ## Was dead, so we discarded the record and cleaned up debris
    aoMismatch      ## PID is alive but cmdline doesn't match (PID reused by another process)
    aoNoSocket      ## No control socket

  AdoptReport* = object
    hosts*: seq[tuple[host: string, outcome: AdoptOutcome]]
    adoptedForwards*: seq[string] ## ids of Forwards that were successfully adopted
    reattachForwards*: seq[string] ## ids that were dead, or optimistically routed to re-attach
    staleSocketsRemoved*: int
    notes*: seq[string]

# ---------------------------------------------------------------------------
# internal helpers
# ---------------------------------------------------------------------------

proc probeAlive(target: UpstreamTarget): bool =
  ## Synchronously bridges to `probeUpstream`. `adoptOrphans` is a
  ## synchronous function called exactly once at daemon startup (inside
  ## `newDaemon`, before `mainLoop`/`serve` starts), and this is the only
  ## `waitFor` here, so there is no concern about nesting (the same idea as
  ## the single `waitFor` in `daemon/run.handleTunnelCheck`).
  ## Set an upper bound with `withTimeout` in case a response never comes
  ## back.
  let fut = probeUpstream(target)
  let completed =
    try: waitFor(withTimeout(fut, 3000))
    except CatchableError: false
  completed and (try: fut.read() except CatchableError: false)

# ---------------------------------------------------------------------------
# public API
# ---------------------------------------------------------------------------

proc adoptOrphans*(reg: Registry; st: PersistedState): AdoptReport =
  ## Called exactly once from the daemon startup sequence. Based on `st`
  ## (the previously saved `PersistedState`), adopts any orphaned masters /
  ## forwards that are still alive into `reg`. See the module doc comment
  ## for the steps.
  result = AdoptReport(hosts: @[], adoptedForwards: @[],
      reattachForwards: @[], staleSocketsRemoved: 0, notes: @[])

  # --- Step 1: adopting hosts -------------------------------------------------
  # Remember only the hosts that were successfully adopted, as pairs of
  # (persisted record, the created HostSession). The forward-side
  # processing (step 2) only walks these pairs.
  var adopted: seq[tuple[phs: PersistedHostSession, hs: HostSession]] = @[]

  for phs in st.hosts:
    if not socketExists(phs.ctlPath):
      result.hosts.add (host: phs.host, outcome: aoNoSocket)
      continue

    let (alive, _) = checkMaster(phs.ctlPath, phs.host)
    if not alive:
      # The socket file still remains (the `ECONNREFUSED` case; its
      # existence was already confirmed above), so remove it. Master is
      # dead + clean up debris.
      removeFile(phs.ctlPath)
      inc result.staleSocketsRemoved
      result.hosts.add (host: phs.host, outcome: aoDeadReclaimed)
      continue

    if not (pidAlive(phs.pid) and cmdlineMatches(phs.pid, phs.argv)):
      # Alive, but does not match the recorded argv (i.e. suspected PID
      # reuse by another process). Do nothing to avoid a false positive.
      result.hosts.add (host: phs.host, outcome: aoMismatch)
      continue

    let hs = adoptHostSession(phs.host, phs.fingerprint, phs.ctlPath,
        phs.logPath, phs.pid, phs.argv, phs.forwardIds)
    adoptHost(reg, hs)
    result.hosts.add (host: phs.host, outcome: aoAdopted)
    adopted.add (phs: phs, hs: hs)

  # --- Step 2: adopting / re-attaching forwards -------------------------------
  var forwardById = initTable[string, PersistedForward]()
  for pfw in st.forwards:
    forwardById[pfw.id] = pfw

  for pair in adopted:
    for fid in pair.phs.forwardIds:
      if fid notin forwardById:
        var note = "adopt: host " & pair.phs.host
        note.add " has no forward record (id=" & fid & ")"
        result.notes.add note
        continue
      let pfw = forwardById[fid]

      case pfw.spec.kind
      of fkLocal:
        let alive = probeAlive(UpstreamTarget(kind: ukUnix, path: pfw.udsPath))
        if alive:
          let fw = forward.adoptForward(pfw.tunnelName, pfw.spec, pair.hs)
          registry.adoptForward(reg, fw)
          result.adoptedForwards.add fw.id
        else:
          if socketExists(pfw.udsPath):
            removeFile(pfw.udsPath)
          discard registry.addForward(reg, pfw.tunnelName, pfw.spec, pair.hs)
          result.reattachForwards.add pfw.id
      of fkRemote:
        # There is no way to probe `fkRemote` (because powarder does not
        # sit in the data path). Optimistically set it to `fwPending` and
        # have it re-attach. `-O forward -R` succeeds idempotently, so
        # there is no concern about it being set up twice.
        discard registry.addForward(reg, pfw.tunnelName, pfw.spec, pair.hs)
        result.reattachForwards.add pfw.id
