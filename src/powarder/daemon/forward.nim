## Lifecycle management for a single port forward.
##
## powarder maintains "1 host = 1 long-lived master" (`daemon/hostsession`),
## and each forward is attached to that master afterward via `-O forward`
## (`daemon/muxclient`). **For `fkLocal` (`-L`), ssh is made to bind a UDS,
## and powarder itself listens on the user-specified port and relays to
## that UDS** (`proxy/listener`). This module is the layer that connects
## the above two,
##
## ```
## client -> [powarder listens] -> [ssh listens: UDS] -> jump host -> destination
## ```
##
## and it manages, as a single `Forward`, both "attaching/detaching the
## forward on the ssh side" and "starting/closing the powarder-side
## listener" from the picture above.
##
## **All state-transition decisions are delegated to `core/statemachine`.**
## Here we just apply the results of `nextForwardState` / `healthVerdict` /
## `isDiscard` as-is; we never rewrite transition conditions with our own
## if statements.
##
## ## Sync / async
##
## `tick()` is made a **synchronous function**, for the same reason as
## `daemon/hostsession.tick` (the daemon calls both from its 500ms loop).
## On the other hand `proxy/listener.serve()` is an async proc, so its
## `Future[void]` is held in `proxyTask` and collected (read) after
## `close()`. Even if we need to wait for the Future's completion inside
## `tick`, we never use `waitFor` (it could end up nested inside the event
## loop). If it isn't finished yet, do nothing and carry it over to the
## next `tick` (polling).
##
## `teardown()` alone is, as an exception, a synchronous function that
## uses `waitFor`. **This is premised on being called after the daemon's
## async loop has fully stopped** (the same constraint as
## `daemon/hostsession.teardown`). Never call `teardown` while `tick` is
## still running.
##
## ## Health check: Tier 3 is the primary mechanism
##
## Periodic probing (Tier 2, the approach of running
## `proxy/upstream.probeUpstream` on a cycle) is not done by default.
## Because of how OpenSSH's `channel_post_port_listener()` is implemented,
## `probeUpstream` always causes a real connection to the destination, so
## running it periodically would keep polluting the destination's
## connection logs with noise.
##
## Instead we use **Tier 3 (a byproduct of real traffic)**: if
## `proxy/stats`'s `failedConns` has increased since the previous tick, it
## means an actual client connection failed to reach the upstream, so we
## treat it as unhealthy. The advantage of this design is that **the
## busier a forward is, the faster anomalies are detected** (detection
## happens the moment a connection comes in, without waiting for the next
## periodic probe).
##
## Since powarder does not sit on the data path for `fkRemote`, statistics
## can't be collected in principle, so Tier 3 can't be used. Health
## checking for `-R` is limited to just "is the master alive" (the
## responsibility of `hostsession`).

import std/[os, options, asyncdispatch]

import powarder/core/types
import powarder/core/statemachine
import powarder/core/forwardspec
import powarder/core/paths
import powarder/core/muxparse
import powarder/core/errorclass
import powarder/daemon/hostsession
import powarder/daemon/muxclient
import powarder/proxy/listener
import powarder/proxy/stats
import powarder/proxy/upstream

type
  Forward* = ref object
    id*: string ## Result of forwardspec.forwardId(). Deterministically derived from the entity (bind target)
    tunnelName*: string
    spec*: ForwardSpec
    host*: HostSession           ## The owning master (reference only; not owned)
    upstream*: UpstreamTarget    ## fkLocal: the UDS path for ukUnix / fkRemote: unused
    proxy*: Option[ForwardProxy] ## fkLocal only. none for fkRemote
    proxyTask*: Option[Future[void]] ## The Future from serve(). Awaited after close() so no unhandled Future is left behind
    state*: ForwardState
    consecutiveHealthFailures*: int
    lastSeenFailedConns*: int ## For Tier3 judgement. stats.failedConns as of the previous tick
    attachRetried*: bool ## Whether the "one retry only" after a bind failure has been used
    lastError*: string
    lastErrorKind*: ErrorKind
    # ---- Below: internal-only fields not in the public type definition (tests must not touch these).
    # Progress flag for advancing the fwDetaching side-effect confirmation
    # (cancel -> probe) step by step across ticks. Same idea as
    # `hostsession.HostSession.lastPeriodicCheckAt`.
    detachCancelIssued: bool ## Whether -O cancel has already been issued (only needs to happen once)
    detachProbeTask: Option[Future[bool]] ## In-flight Future from probeUpstream()
    detachConfirmed: bool ## Side effect confirmed. isDiscardable checks this
    detachStuck: bool ## Stuck waiting for host recycle because the cancel side effect could not be confirmed

# ---------------------------------------------------------------------------
# Internal helper: state transition
# ---------------------------------------------------------------------------

proc transition(fw: Forward; event: ForwardEvent) =
  ## Internal helper that applies the result of `statemachine.nextForwardState`
  ## as-is. A returned `none` means an implementation bug that should never
  ## reach here, but for the same reason as `hostsession.transition`, we
  ## avoid crashing the whole daemon over it and silently ignore it without
  ## changing the state.
  ##
  ## **Exception**: `fwDetaching` + `feDetachConfirmed` is a normal `none`
  ## that represents "discardable" (because `ForwardState` has no
  ## "discarded" value). This combination is handled separately by
  ## `finishDetach` via `isDiscard`, so it is never invoked from here.
  let next = nextForwardState(fw.state, event)
  if next.isSome:
    fw.state = next.get()

# ---------------------------------------------------------------------------
# attach
# ---------------------------------------------------------------------------

proc recordSshAttachFailure(fw: Forward; outcome: MuxOutcome) =
  ## Records an ssh-side `-O forward` failure (including the case where the
  ## bind-failure retry has also been exhausted). `core/errorclass`'s
  ## classification is designed to target the master's entire stderr log,
  ## and its vocabulary differs from a single `-O forward` result
  ## (`MuxOutcome`), so here we build dedicated wording.
  fw.lastErrorKind = ekUnknown
  fw.lastError = "ssh -O forward failed (" & $outcome & ")"

proc attach(fw: Forward) =
  ## Attempts the actual attach from fwPending. Transitions to fwActive
  ## only once both the ssh side (-O forward) and the powarder side
  ## (fkLocal only, the listener for the user-specified port) are
  ## confirmed. Everything in between proceeds while staying in
  ## fwAttaching.
  ##
  ## Steps (order matters. See each step's comment for details):
  ## 1. Remove UDS leftovers
  ## 2. Attach `-O forward`
  ## 3. If bind fails, retry once
  ## 4. On success, start the powarder-side listener (fkLocal only)
  ## 5. If the listener's bind fails, roll back the ssh side with cancel
  transition(fw, feAttachStarted) ## fwPending -> fwAttaching

  let udsPath = if fw.spec.kind == fkLocal: fw.upstream.path else: ""

  # Step 1: remove UDS leftovers.
  # **Must not use `os.fileExists`** -- it only checks `S_ISREG`, so it
  # always returns false for a socket. Use `paths.socketExists` instead.
  if fw.spec.kind == fkLocal and socketExists(udsPath):
    removeFile(udsPath)

  # Step 2: attach the forward on the ssh side
  var outcome = muxclient.addForward(fw.host.ctlPath, fw.host.host, fw.spec, udsPath)

  # Step 3: on a bind failure, retry once, only if we haven't retried yet.
  # ssh is started with `-o StreamLocalBindUnlink=yes`, so we normally
  # don't reach here, but this is a safety net for cases like permission
  # issues where the leftover can't be removed.
  if outcome == moBindFailed and not fw.attachRetried:
    fw.attachRetried = true
    if fw.spec.kind == fkLocal:
      removeFile(udsPath)
    outcome = muxclient.addForward(fw.host.ctlPath, fw.host.host, fw.spec, udsPath)

  if outcome != moSuccess:
    # If the first attempt failed with something other than a bind
    # failure, or if it still fails after the retry, this corresponds to
    # feAttachFailedOther (we deliberately don't represent a second-or-later
    # bind failure as feAttachBindFailed, per the design note in
    # statemachine.nim).
    recordSshAttachFailure(fw, outcome)
    transition(fw, feAttachFailedOther) ## fwAttaching -> fwError
    return

  # Step 4: the ssh side is attached. If fkLocal, start the powarder-side
  # listener.
  #
  # **If it's already running (a re-attach from a host reconnect), just
  # reuse it.** Both bindPort and the UDS path are deterministically
  # derived from forwardId, and a host reconnect alone doesn't change
  # them. If we recreated the listener every time, it would always fail
  # trying to double-bind the same user-specified port this process
  # already holds. Each client connection reconnects to the UDS fresh via
  # `dialUpstream` every time (see `proxy/listener.handleConnection`), so
  # even if what's behind the UDS has been swapped out by a master
  # reconnect, the powarder-side listener can keep running without
  # interruption.
  if fw.spec.kind == fkLocal and fw.proxy.isNone:
    try:
      let proxy = newForwardProxy(fw.spec.bindAddr, fw.spec.bindPort,
          UpstreamTarget(kind: ukUnix, path: udsPath))
      fw.proxy = some(proxy)
      fw.proxyTask = some(serve(proxy))
    except CatchableError:
      # Step 5: e.g. the user-specified port is already in use. This is
      # distinct from an ssh-side failure, so we record it as
      # errorclass.ekPortInUse and roll back the ssh-side forward we
      # already attached with cancelForward (leaving it attached would be
      # treated as a leftover on the next attach).
      discard muxclient.cancelForward(fw.host.ctlPath, fw.host.host, fw.spec, udsPath)
      let expl = explain(ekPortInUse,
          initErrorContext(bindPort = int(fw.spec.bindPort)))
      fw.lastErrorKind = ekPortInUse
      fw.lastError = expl.summary
      transition(fw, feAttachFailedOther) ## fwAttaching -> fwError
      return

  # fkRemote has the remote side listen, so powarder does not get
  # involved (no proxy is started).
  transition(fw, feAttachSucceeded) ## fwAttaching -> fwActive
  fw.consecutiveHealthFailures = 0
  fw.lastSeenFailedConns =
    if fw.proxy.isSome: fw.proxy.get().stats.failedConns else: 0

# ---------------------------------------------------------------------------
# Health check (Tier 3)
# ---------------------------------------------------------------------------

proc healthCheck(fw: Forward) =
  ## Called every tick in `fwActive` / `fwDegraded`. The judgement is left
  ## entirely to `statemachine.healthVerdict` (see the module doc
  ## comment's "Health check: Tier 3 is the primary mechanism" section).
  if fw.spec.kind != fkLocal or fw.proxy.isNone:
    # fkRemote can't collect statistics, so Tier3 can't be used.
    # Monitoring whether the master is alive is hostsession's
    # responsibility, so we do nothing here.
    return

  let currentFailed = fw.proxy.get().stats.failedConns
  if currentFailed > fw.lastSeenFailedConns:
    inc fw.consecutiveHealthFailures
  else:
    fw.consecutiveHealthFailures = 0
  fw.lastSeenFailedConns = currentFailed

  let verdict = healthVerdict(fw.consecutiveHealthFailures, fw.state)
  if verdict == fwPending:
    # Forced re-attach. Make the "one retry only" available again for the
    # next attach.
    fw.attachRetried = false
    fw.consecutiveHealthFailures = 0
  fw.state = verdict

# ---------------------------------------------------------------------------
# detach
# ---------------------------------------------------------------------------

proc finishDetach(fw: Forward) =
  ## The cancel + side-effect confirmation (or, for fkRemote, just the
  ## cancel) has completed. `nextForwardState(fwDetaching,
  ## feDetachConfirmed)` is designed to return `none` (because
  ## `ForwardState` has no "discarded" value), so after confirming via
  ## `isDiscard` that this is the normal signal for "OK to discard", we
  ## represent discardability with the `detachConfirmed` flag without
  ## changing `state` itself (`isDiscardable` checks this flag).
  doAssert isDiscard(fw.state, feDetachConfirmed)
  if fw.spec.kind == fkLocal:
    removeFile(fw.upstream.path)
  fw.host.removeForwardRef(fw.id)
  fw.detachConfirmed = true

proc checkDetachProgress(fw: Forward) =
  ## Called every tick in `fwDetaching`. Advances the detach steps stage
  ## by stage across ticks (`tick` is a synchronous function, and waiting
  ## for `serve()`'s Future or `probeUpstream`'s Future with `waitFor`
  ## would nest inside the event loop).
  ##
  ## Steps (correspond to `requestDetach`'s doc comment and the design at
  ## the top of the module):
  ## 1. Collect the proxy's `Future` (`close()` itself has already been
  ##    called in `requestDetach`)
  ## 2. `-O cancel` (issued only once. The exit code is not trusted)
  ## 3. Confirm the side effect empirically (check that `probeUpstream`
  ##    returns false. Limited to just once since it causes a real
  ##    connection to the destination)
  ## 4. Remove UDS leftovers
  ## 5. Decrement the reference count
  if fw.detachConfirmed or fw.detachStuck:
    return ## Already finalized (discardable, or stuck waiting for host recycle)

  # Step 1: collect the proxy's Future
  if fw.proxyTask.isSome:
    let fut = fw.proxyTask.get()
    if not fut.finished:
      return ## Carry over to the next tick
    try:
      fut.read() ## If it failed, an exception will be thrown, so swallow it
    except CatchableError:
      discard
    fw.proxyTask = none(Future[void])

  # Step 2: -O cancel (issued only once). The exit code cannot be trusted
  # at all (both success and failure return 0), so here we just fire it
  # without checking the result. The true judgement is done via the
  # side-effect confirmation in step 3.
  if not fw.detachCancelIssued:
    let udsPath = if fw.spec.kind == fkLocal: fw.upstream.path else: ""
    discard muxclient.cancelForward(fw.host.ctlPath, fw.host.host, fw.spec, udsPath)
    fw.detachCancelIssued = true
    return ## Side-effect confirmation happens from the next tick onward

  # fkRemote has no means of side-effect confirmation via "a real
  # connection to the destination" (because powarder doesn't sit on the
  # data path). We finalize based solely on the fact that cancel was
  # issued.
  if fw.spec.kind == fkRemote:
    finishDetach(fw)
    return

  # Step 3: confirm the side effect empirically.
  # **Note**: `probeUpstream` causes a real connection to the destination
  # (this is unavoidable, since OpenSSH's `channel_post_port_listener`
  # opens a `direct-tcpip` right after accept). We allow this since it's
  # only once at detach time (we don't probe repeatedly).
  if fw.detachProbeTask.isNone:
    fw.detachProbeTask = some(probeUpstream(fw.upstream))
    return ## Collect the result on the next tick

  let probeFut = fw.detachProbeTask.get()
  if not probeFut.finished:
    return ## Carry over to the next tick
  let stillReachable = probeFut.read()
  fw.detachProbeTask = none(Future[bool])

  if stillReachable:
    # cancel is lying (it reported success, but it wasn't actually
    # released). We get stuck here as a state that requires recycling
    # the whole host (no automatic recovery).
    fw.detachStuck = true
    fw.lastErrorKind = ekUnknown
    fw.lastError = "Still able to connect to UDS " & fw.upstream.path &
        " even after cancel; the whole host needs to be recycled"
    return

  finishDetach(fw)

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

proc newForward*(tunnelName: string; spec: ForwardSpec;
    host: HostSession): Forward =
  ## Determines `id` via `forwardspec.forwardId(spec, host.host)`, and if
  ## `fkLocal`, determines the UDS path via
  ## `paths.forwardSocketPath(forwardspec.udsBasename(id))`. Calls
  ## `host.addForwardRef(id)` to increment the reference count. The state
  ## is `fwPending`. Neither the process nor the proxy is started yet
  ## (the actual attach happens via `tick()`).
  let id = forwardId(spec, host.host)
  let upstream =
    if spec.kind == fkLocal:
      UpstreamTarget(kind: ukUnix, path: forwardSocketPath(udsBasename(id)))
    else:
      UpstreamTarget(kind: ukUnix, path: "") ## unused for fkRemote

  result = Forward(
    id: id,
    tunnelName: tunnelName,
    spec: spec,
    host: host,
    upstream: upstream,
    proxy: none(ForwardProxy),
    proxyTask: none(Future[void]),
    state: fwPending,
    consecutiveHealthFailures: 0,
    lastSeenFailedConns: 0,
    attachRetried: false,
    lastError: "",
    lastErrorKind: ekUnknown,
    detachCancelIssued: false,
    detachProbeTask: none(Future[bool]),
    detachConfirmed: false,
    detachStuck: false,
  )
  host.addForwardRef(id)

proc adoptForward*(tunnelName: string; spec: ForwardSpec;
    host: HostSession): Forward =
  ## Constructor for adopting orphaned Forwards (M6). The caller
  ## (`daemon/orphan.adoptOrphans`) takes an `fkLocal` Forward already
  ## confirmed "still alive" via `probeUpstream` against the UDS, and
  ## takes it over directly as `fwActive`.
  ##
  ## **Does not go through `attach()`.** Step 1 of `attach()`
  ## unconditionally does `removeFile` on the UDS leftover, but what
  ## we're handling here is not a leftover but a live UDS, so removing it
  ## would destroy the very forward we're supposed to take over.
  ##
  ## For fkLocal, the powarder-side listener is also started here (since
  ## it just takes over the `bindPort` the previous process held, a
  ## conflict right after adopt is not expected). If the bind fails, we
  ## don't raise an exception but return it as `fwError` (the same
  ## policy as `attach()`'s handling of the user-specified port already
  ## being in use, but adopt does not perform the ssh-side rollback via
  ## cancelForward. For the same reason as above -- not destroying the
  ## still-live UDS -- we avoid erring toward unintentionally losing the
  ## forward).
  let id = forwardId(spec, host.host)
  let upstream =
    if spec.kind == fkLocal:
      UpstreamTarget(kind: ukUnix, path: forwardSocketPath(udsBasename(id)))
    else:
      UpstreamTarget(kind: ukUnix, path: "") ## unused for fkRemote (this path is not normally called)

  result = Forward(
    id: id,
    tunnelName: tunnelName,
    spec: spec,
    host: host,
    upstream: upstream,
    proxy: none(ForwardProxy),
    proxyTask: none(Future[void]),
    state: fwActive,
    consecutiveHealthFailures: 0,
    lastSeenFailedConns: 0,
    attachRetried: false,
    lastError: "",
    lastErrorKind: ekUnknown,
    detachCancelIssued: false,
    detachProbeTask: none(Future[bool]),
    detachConfirmed: false,
    detachStuck: false,
  )
  host.addForwardRef(id)

  if spec.kind == fkLocal:
    try:
      let proxy = newForwardProxy(spec.bindAddr, spec.bindPort,
          UpstreamTarget(kind: ukUnix, path: upstream.path))
      result.proxy = some(proxy)
      result.proxyTask = some(serve(proxy))
      result.lastSeenFailedConns = proxy.stats.failedConns
    except CatchableError as e:
      result.state = fwError
      result.lastErrorKind = ekPortInUse
      result.lastError = "Failed to start the powarder-side listener during adopt: " & e.msg

proc tick*(fw: Forward) =
  ## Called every time from the daemon's 500ms loop. Advances whatever
  ## processing is needed for the current state, once (same design as
  ## `hostsession.tick`).
  ##
  ## If the owning host is no longer `isConnected`, revert to `fwPending`
  ## via `feHostLost` from any state (the "from any state" rule in
  ## `statemachine`). The case where this happens during `fwDetaching` is
  ## expected to be rare (see the design note in `statemachine.nim`;
  ## effectively this doesn't happen if the daemon layer removes targets
  ## that have already been `requestDetach`'d from management), but as a
  ## safeguard, `requestDetach` resets the internal detach-related flags
  ## every time, so even if detach happens again afterward, it can be
  ## redone correctly.
  if not fw.host.isConnected():
    if fw.state != fwPending:
      transition(fw, feHostLost)
    return

  case fw.state
  of fwPending:
    attach(fw)
  of fwAttaching:
    discard ## Since attach() completes synchronously, tick alone never reaches here
  of fwActive, fwDegraded:
    healthCheck(fw)
  of fwDetaching:
    checkDetachProgress(fw)
  of fwError:
    discard ## Does not recover automatically. Only via requestDetach or feHostLost

proc requestDetach*(fw: Forward) =
  ## Called when removed from the config / stopped. Transitions to
  ## `fwDetaching`.
  ##
  ## Step 1 (close the proxy first so it stops accepting new connections)
  ## is done immediately here. `close()` is a synchronous function.
  ## Collecting `proxyTask` (the equivalent of await) is left to `tick`
  ## (`checkDetachProgress`).
  ##
  ## Even if internal state remains from a previous detach cycle, we
  ## reset the side-effect-confirmation internal flags every time here so
  ## it can be redone correctly from the start.
  fw.detachCancelIssued = false
  fw.detachProbeTask = none(Future[bool])
  fw.detachConfirmed = false
  fw.detachStuck = false
  if fw.proxy.isSome:
    fw.proxy.get().close()
  transition(fw, feDetachRequested)

proc teardown*(fw: Forward) =
  ## Fully cleans up synchronously (for the daemon's graceful shutdown).
  ##
  ## **Premised on being called after the daemon's async loop has
  ## stopped.** Must not be called while `tick` is still running (calling
  ## `waitFor` nested from inside the event loop would cause a problem;
  ## same constraint as `hostsession.teardown`).
  ##
  ## Unlike the `tick`-driven staged detach (`checkDetachProgress`), this
  ## guarantees that "cleanup is finished by the time the call returns",
  ## no matter what state it's called from. It does not perform empirical
  ## side-effect confirmation (`probeUpstream`) (teardown's contract is
  ## to finish cleaning up no matter what, and there's no need to cause
  ## an extra real connection to the destination for that).
  if fw.proxy.isSome:
    let proxy = fw.proxy.get()
    proxy.close()
    if fw.proxyTask.isSome:
      let fut = fw.proxyTask.get()
      try:
        waitFor fut
      except CatchableError:
        discard
      fw.proxyTask = none(Future[void])

  let udsPath = if fw.spec.kind == fkLocal: fw.upstream.path else: ""
  discard muxclient.cancelForward(fw.host.ctlPath, fw.host.host, fw.spec, udsPath)

  if fw.spec.kind == fkLocal:
    removeFile(udsPath)

  fw.host.removeForwardRef(fw.id)
  fw.state = fwDetaching
  fw.detachCancelIssued = true
  fw.detachConfirmed = true

proc isDiscardable*(fw: Forward): bool =
  ## Whether it's `fwDetaching` and side-effect confirmation is done,
  ## i.e. OK to remove from the registry.
  fw.state == fwDetaching and fw.detachConfirmed

proc stats*(fw: Forward): Option[ForwardStats] =
  ## The proxy's statistics for `fkLocal`. none for `fkRemote` (statistics
  ## cannot be collected in principle).
  if fw.spec.kind == fkLocal and fw.proxy.isSome:
    some(fw.proxy.get().stats)
  else:
    none(ForwardStats)

proc describeState*(fw: Forward): string =
  case fw.state
  of fwPending: "pending"
  of fwAttaching: "attaching"
  of fwActive: "active"
  of fwDegraded: "degraded (health failures: " & $fw.consecutiveHealthFailures & ")"
  of fwDetaching:
    if fw.detachStuck: "detaching (stuck: " & fw.lastError & ")"
    elif fw.detachConfirmed: "detached"
    else: "detaching"
  of fwError: "error: " & fw.lastError
