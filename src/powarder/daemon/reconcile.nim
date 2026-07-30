## Level-triggered convergence loop.
##
## We adopt the Kubernetes-style idea of reconciling "desired state" against
## "actual state", but we do not build a full setup like informers /
## workqueues / multiple controllers (that would be over-engineering at the
## scale of a few dozen hosts and a few hundred forwards). A single
## `reconcile()` function compares desired against the current state of
## `Registry` each time it is called and applies only the necessary diff.
##
## **Idempotency is the most important property.** Calling this repeatedly
## with the same `DesiredState` changes nothing from the second call
## onward (there is no diff, so `actions` ends up empty). This gives the
## guarantee that "it is safe for the daemon to call `reconcile` on every
## tick, or every time the config changes, no matter how many times."

import std/tables
import std/nativesockets ## Needed because the auto-generated `==` for
                          ## `ForwardSpec` internally uses `Port`'s `==`
                          ## (same reason as in `core/forwardspec.nim`.
                          ## `types.nim` re-exports only the type via
                          ## `export Port`, so the comparison operator needs
                          ## a separate import).

import powarder/core/types
import powarder/core/forwardspec
import powarder/daemon/registry
import powarder/daemon/forward

type
  DesiredState* = object
    tunnels*: seq[TunnelConfig]
      ## Desired state read from the config file. `enabledOverride` (the
      ## start/stop intent) is held on the `Registry` side, so it is not
      ## included here.
    activeProfiles*: seq[string]
      ## If empty, only tunnels with no profile are targeted (following
      ## docker compose's profiles semantics). If given, tunnels belonging
      ## to that profile are also included as targets.

  ReconcileAction* = enum
    raCreateHost, raCreateForward, raDetachForward, raRemoveForward,
    raEnableForward, raDisableForward

  ReconcileReport* = object
    actions*: seq[tuple[action: ReconcileAction, target: string]]
    warnings*: seq[string]

# ---------------------------------------------------------------------------
# profile filter
# ---------------------------------------------------------------------------

proc isTargeted*(tc: TunnelConfig; activeProfiles: openArray[string]): bool =
  ## Always targeted if `tc.profile` is empty. If not empty, targeted only
  ## when it is contained in `activeProfiles`.
  if tc.profile.len == 0:
    true
  else:
    tc.profile in activeProfiles

# ---------------------------------------------------------------------------
# reconcile body
# ---------------------------------------------------------------------------

proc reconcile*(desired: DesiredState; reg: Registry): ReconcileReport =
  ## Compares desired against the current state of `reg` and applies the
  ## diff.
  ##
  ## Steps:
  ## 0. Reclaim any `Forward` from the registry that is already discardable
  ##    (`isDiscardable`). This cleanup is normally done by `registry.tickAll`
  ##    on every loop iteration, but we do it here too so nothing is missed
  ##    even when `reconcile` is called on its own (e.g. right after a config
  ##    reload). (`removeForward` is idempotent, so doing it twice is
  ##    harmless.)
  ## 1. reconcileHosts: prepare the hosts that desired needs, via
  ##    `getOrCreateHost`.
  ## 2. reconcileForwards: decide whether create / detach is needed and
  ##    apply it.
  ## 3. `pruneOverrides` cleans up overrides for tunnel names that have
  ##    disappeared from the config.
  ##
  ## **Hosts are never removed explicitly.** When a `Forward` is detached,
  ## its reference count drops to 0, and the `HostSession` itself falls to
  ## `hsStopping` on its own once the grace period elapses (the
  ## responsibility of `hostsession.tick`). The design relies on this
  ## "automatic stop driven by reference count", and there is no operation
  ## on the `reconcile` / `registry` side that actively removes it from
  ## `reg.hosts` (except when the whole process shuts down via
  ## `teardownAll`).
  result = ReconcileReport(actions: @[], warnings: @[])

  # --- Step 0: reclaim already-discardable Forwards -------------------------
  var alreadyDiscardable: seq[string] = @[]
  for id, fw in reg.forwards:
    if forward.isDiscardable(fw):
      alreadyDiscardable.add(id)
  for id in alreadyDiscardable:
    removeForward(reg, id)
    result.actions.add((raRemoveForward, id))

  # --- Step 1: reconcileHosts -------------------------------------------------
  # Among the tunnels in desired, only ones that are targeted (profile
  # matches) and enabled (isEnabled) need a host. There is no need to start
  # a new master for a host that only has disabled tunnels.
  for tc in desired.tunnels:
    if not isTargeted(tc, desired.activeProfiles):
      continue
    if not isEnabled(reg, tc.name, tc.autostart):
      continue
    let before = reg.hosts.len
    discard getOrCreateHost(reg, tc.host, tc.sshExtraArgs)
    if reg.hosts.len > before:
      result.actions.add((raCreateHost, tc.host))

  # --- Step 2: reconcileForwards -----------------------------------------
  # Pass A: loop over desired.tunnels as the basis, and apply the diff by
  # checking whether each tunnel's id exists in the registry, whether the
  # spec matches, and whether it is enabled.
  var tunnelsByName = initTable[string, TunnelConfig]()
  for tc in desired.tunnels:
    tunnelsByName[tc.name] = tc

  for tc in desired.tunnels:
    let id = forwardId(tc.spec, tc.host)
    let targeted = isTargeted(tc, desired.activeProfiles)
    let enabled = isEnabled(reg, tc.name, tc.autostart)
    let shouldExist = targeted and enabled

    if id in reg.forwards:
      let existing = reg.forwards[id]
      if existing.tunnelName != tc.name:
        # Another tunnel is already using this id (a deterministic
        # derivation from the entity, e.g. bindAddr:bindPort). This is a
        # config mistake (e.g. local port collision) that should normally
        # be prevented by the config validation layer, but if it happens
        # anyway we cannot decide which one should own it, so we respect
        # the existing one, leave this `tc` untouched, and just leave a
        # warning.
        let existingName = existing.tunnelName
        result.warnings.add("forward id " & id &
            " is already used by tunnel '" & existingName &
            "'. Tunnel '" & tc.name &
            "' cannot use the same bind address/port")
        continue

      if shouldExist:
        if existing.spec != tc.spec:
          # Same id, but the forwarding destination (targetHost/targetPort,
          # etc.) changed. `Forward.id` is determined only from the bind
          # side entity, so a change to the destination does not change the
          # id. There is no way to rewrite the spec of the same Forward
          # object (forward.nim does not provide such an API), so we detach
          # and rebuild. The rebuild is left to a later reconcile call, once
          # the id has disappeared from the registry (confirming the
          # side-effects of detach up to isDiscardable takes multiple ticks,
          # so this does not complete within this single call).
          if existing.state != fwDetaching:
            requestDetach(existing)
            result.actions.add((raDetachForward, tc.name))
          # else: detach is already in progress. Calling requestDetach twice
          # would reset internal progress flags (detachCancelIssued, etc.)
          # (see forward.requestDetach's doc comment), so we do not call it.
        # else: they match. Do nothing (this is the core of idempotency).
      else:
        # Not targeted (profile mismatch) or disabled. It exists, so detach it.
        if existing.state != fwDetaching:
          requestDetach(existing)
          let action = if targeted: raDisableForward else: raDetachForward
          result.actions.add((action, tc.name))
    else:
      if shouldExist:
        let hs = getOrCreateHost(reg, tc.host, tc.sshExtraArgs)
        discard addForward(reg, tc.name, tc.spec, hs)
        # Distinguish the report: raEnableForward when `enabledOverride`
        # explicitly holds true (i.e. resumed via `powarder start`);
        # otherwise (newly appeared in the config file / driven by
        # autostart) report raCreateForward.
        if tc.name in reg.enabledOverride and reg.enabledOverride[tc.name]:
          result.actions.add((raEnableForward, tc.name))
        else:
          result.actions.add((raCreateForward, tc.name))
      # else: it doesn't exist and isn't needed either. Do nothing.

    # Pass B: detach Forwards that exist in the registry but whose name
    # does not exist in desired.tunnels (i.e. completely removed from the
    # config file). Pass A loops with desired.tunnels as the basis, so a
    # removed tunnel never appears in the loop and slips through. Here we
    # cover that gap by using the registry side as the basis instead.
  for id, fw in reg.forwards:
    if fw.tunnelName notin tunnelsByName:
      if fw.state != fwDetaching:
        requestDetach(fw)
        result.actions.add((raDetachForward, fw.tunnelName))

  # --- Step 3: pruneOverrides ----------------------------------------------
  var names: seq[string] = @[]
  for tc in desired.tunnels:
    names.add(tc.name)
  pruneOverrides(reg, names)
