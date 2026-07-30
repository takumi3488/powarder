## The layer that manages the daemon's collective "current state".
##
## Holds the entities of `HostSession` (masters) and `Forward` (individual
## port forwards) in `Table`s, and is a thin container that invokes their
## lifecycle functions (`hostsession.tick` / `forward.tick`, etc.) in the
## correct order.
##
## **State-transition decisions are not made here.** That is the
## responsibility of `hostsession` / `forward` / `core/statemachine`. This
## module only deals with "which `HostSession` / `Forward` exist" and "in
## what order they are driven".
##
## **The core of powarder's design -- "multiple tunnels pointing at the
## same host share a single master" -- is realized in `getOrCreateHost`.**

import std/tables

import powarder/core/types
import powarder/core/forwardspec
import powarder/daemon/hostsession
import powarder/daemon/forward

type
  Registry* = ref object
    hosts*: Table[string, HostSession] ## Keyed by hostKeyString(key)
    forwards*: Table[string, Forward]  ## Keyed by Forward.id
    enabledOverride*: Table[string, bool]
      ## Tunnel name -> enabled/disabled (the intent behind `powarder start`
      ## / `stop`).
      ##
      ## `powarder start` / `stop` **do not rewrite the config file.** They
      ## are kept as an overlay layer in the daemon's in-memory state (the
      ## same idea as `systemctl`'s enabled vs. active being separate
      ## concepts). The runtime start/stop intent is laid on top of the
      ## `autostart` specified by the config file, via this Table. This
      ## prevents the accident where "after `stop`, an unrelated config
      ## change triggers `reload` and it resumes on its own", without any
      ## special-casing on the reconcile side (reconcile only looks at
      ## `isEnabled` and never looks at `autostart` directly).
    hostKeyCache: Table[string, HostSessionKey]
      ## Internal-only cache used by `getOrCreateHost` to skip re-running
      ## `ssh -G`. Not present in the public type definition (see
      ## `getOrCreateHost`'s doc comment for details).

# ---------------------------------------------------------------------------
# Key stringification
# ---------------------------------------------------------------------------

proc hostKeyString*(key: HostSessionKey): string =
  ## Stringifies a `HostSessionKey` for use as a `Table` key.
  ##
  ## `HostSessionKey` is a plain object with an auto-generated `==`, but
  ## using it directly as a key in `Table[HostSessionKey, HostSession]`
  ## would separately require a `std/hashes.hash(HostSessionKey)`
  ## definition (not yet present in `core/types.nim`, and this module has
  ## a constraint that it cannot change that). We could add `hash`
  ## ourselves here, but since `HostSessionKey` is a simple object with
  ## just two strings, `host` and `fingerprint`, it's more straightforward
  ## to flatten it into a "deterministic string" and use `Table[string,
  ## _]`, without adding an extra type-class implementation. `@` is a
  ## separator that never appears in `host` or in `fingerprint` (a hex
  ## string), so there is no collision.
  key.host & "@" & key.fingerprint

proc hostArgsCacheKey(host: string; extraArgs: seq[string]): string =
  ## The cache key for `getOrCreateHost`. Stringifies the pair of `host`
  ## and `extraArgs` as-is (separated by `\x1F`, the ASCII unit
  ## separator). This control character normally never appears in a host
  ## name or in arguments, so it's a safe separator.
  result = host
  for a in extraArgs:
    result.add('\x1F')
    result.add(a)

# ---------------------------------------------------------------------------
# Generation
# ---------------------------------------------------------------------------

proc newRegistry*(): Registry =
  Registry(
    hosts: initTable[string, HostSession](),
    forwards: initTable[string, Forward](),
    enabledOverride: initTable[string, bool](),
    hostKeyCache: initTable[string, HostSessionKey](),
  )

# ---------------------------------------------------------------------------
# Host
# ---------------------------------------------------------------------------

proc getOrCreateHost*(reg: Registry; host: string;
    extraArgs: seq[string] = @[]): HostSession =
  ## The place where "multiple tunnels pointing at the same host share a
  ## single master" is realized. `newHostSession(host, extraArgs)`
  ## computes a `HostSessionKey` that includes the fingerprint, and if a
  ## host with the same key is already registered, returns it. Otherwise
  ## it registers and returns a new one.
  ##
  ## **The trick for avoiding re-running `ssh -G`**: `newHostSession`
  ## re-runs `ssh -G` internally to recompute the fingerprint every time
  ## it's called. reconcile passes each "group of multiple tunnels sharing
  ## the same host" through this function once per tunnel, so without
  ## countermeasures, `ssh -G` would end up running wastefully many times
  ## for the same host (all the more so when reconcile is invoked
  ## periodically).
  ##
  ## So we remember the pair `(host, extraArgs)` in `hostKeyCache`, and
  ## from the second call onward we just look up the `HostSessionKey`
  ## directly from there and re-look-up `reg.hosts`, taking a path that
  ## never calls `newHostSession` (i.e. `ssh -G`) at all.
  ##
  ## **Why this optimization doesn't break the property that "a change to
  ## `host` or to `sshExtraArgs` falls through to Add/Remove"**: since the
  ## cache key is the `(host, extraArgs)` pair itself, if either one
  ## changes it becomes a different cache key, and `ssh -G` is naturally
  ## re-run to get the new fingerprint (no cache hit). **The only case the
  ## cache misses is the rare one where neither `host` nor `extraArgs`
  ## changed, but `~/.ssh/config` itself was edited while the daemon was
  ## running** -- in that case the change is not reflected until the
  ## daemon is restarted. Since a host, once registered, is never removed
  ## from `Registry` (except by `teardownAll`), this case doesn't cause
  ## the cache and the actual state to drift apart and break.
  let cacheKey = hostArgsCacheKey(host, extraArgs)
  if cacheKey in reg.hostKeyCache:
    let hks = hostKeyString(reg.hostKeyCache[cacheKey])
    if hks in reg.hosts:
      return reg.hosts[hks]
    # The cache has an entry but the entity doesn't exist (should never
    # happen in principle, but as a defensive measure, fall through below
    # to recreate it).

  let candidate = newHostSession(host, extraArgs)
  let hks = hostKeyString(candidate.key)
  reg.hostKeyCache[cacheKey] = candidate.key
  if hks in reg.hosts:
    return reg.hosts[hks] ## Prefer the existing one; discard the constructed candidate
  reg.hosts[hks] = candidate
  candidate

proc adoptHost*(reg: Registry; hs: HostSession) =
  ## For adopting orphans (M6. `daemon/orphan.adoptOrphans`). Registers
  ## into `reg.hosts` under the same key as `getOrCreateHost`
  ## (`hostKeyString(hs.key)`).
  ##
  ## **There's no need to explicitly warm up `hostKeyCache`.** After the
  ## adopt, when reconcile requests the same `(host, extraArgs)`,
  ## `getOrCreateHost` misses the cache and runs `newHostSession` (i.e.
  ## `ssh -G`) once, but as long as ssh_config hasn't changed, it gets the
  ## same fingerprint and, via `hks`, picks up this adopted session
  ## straight from `reg.hosts` and reuses it (the fallback path in
  ## `getOrCreateHost`). If ssh_config has changed, a new session is
  ## created, but that's simply the normal Add/Remove logic of "config
  ## changed, so reconnect" working correctly, and needs no special
  ## cleanup (that's what Add/Remove was designed for in the first place).
  reg.hosts[hostKeyString(hs.key)] = hs

proc clearHostKeyCache*(reg: Registry) =
  ## Discards the `(host, extraArgs)` -> fingerprint cache.
  ##
  ## **Must always be called from `daemon.reload`.** Since reload is the
  ## "reread the config" operation, re-evaluating `~/.ssh/config` should
  ## also happen here. If it isn't called, we get the confusing behavior
  ## where "editing ssh_config and reloading doesn't take effect" (this is
  ## the one hole in the cache mentioned in `getOrCreateHost`'s doc
  ## comment).
  ##
  ## Existing `HostSession` / `Forward` instances are not discarded. The
  ## next `getOrCreateHost` re-runs `ssh -G`, and if the fingerprint has
  ## changed, a host with a new key is created; the old host's reference
  ## count drops to 0 and it stops itself once the grace period elapses
  ## (it just rides on the general Add/Remove logic; no special handling
  ## needed).
  reg.hostKeyCache.clear()

# ---------------------------------------------------------------------------
# Forward
# ---------------------------------------------------------------------------

proc addForward*(reg: Registry; tunnelName: string; spec: ForwardSpec;
    host: HostSession): Forward =
  ## Calls `newForward` and registers it into the registry.
  ##
  ## Registering a duplicate id would corrupt state (double-counting in
  ## `host.addForwardRef`, or overwriting an existing Forward and losing
  ## track of its reference), so we guard against this by checking
  ## `reg.forwards` **before** calling `newForward` (config validation
  ## should already prevent collisions on the same bind address/port, but
  ## this guards against the unexpected).
  let id = forwardId(spec, host.host)
  if id in reg.forwards:
    raise newException(ValueError, "forward id is already registered: " & id)
  result = newForward(tunnelName, spec, host)
  reg.forwards[id] = result

proc adoptForward*(reg: Registry; fw: Forward) =
  ## For adopting orphans (M6. `daemon/orphan.adoptOrphans`). The caller
  ## has already assembled a `Forward` via `daemon/forward.adoptForward`
  ## (`fwActive`, confirmed that the UDS is alive), and this just
  ## registers it as-is; it does not call `newForward` (doing so would
  ## double-increment the reference count). Guards against duplicate ids
  ## for the same reason as `addForward`.
  if fw.id in reg.forwards:
    raise newException(ValueError, "forward id is already registered: " & fw.id)
  reg.forwards[fw.id] = fw

proc removeForward*(reg: Registry; id: string) =
  ## Removes from the Table a Forward that has gone through fwDetaching
  ## and become discardable. Safe to call even if `id` doesn't exist
  ## (`Table.del` is a no-op for a missing key).
  reg.forwards.del(id)

proc forwardsOf*(reg: Registry; hostKey: string): seq[Forward] =
  result = @[]
  for fw in reg.forwards.values:
    if hostKeyString(fw.host.key) == hostKey:
      result.add(fw)

proc forwardsOfTunnel*(reg: Registry; tunnelName: string): seq[Forward] =
  result = @[]
  for fw in reg.forwards.values:
    if fw.tunnelName == tunnelName:
      result.add(fw)

# ---------------------------------------------------------------------------
# start/stop overlay
# ---------------------------------------------------------------------------

proc isEnabled*(reg: Registry; tunnelName: string; autostart: bool): bool =
  ## Returns the entry from `enabledOverride` if one exists; otherwise
  ## returns `autostart` (the config file's value).
  reg.enabledOverride.getOrDefault(tunnelName, autostart)

proc setEnabled*(reg: Registry; tunnelName: string; enabled: bool) =
  reg.enabledOverride[tunnelName] = enabled

proc clearEnabledOverride*(reg: Registry; tunnelName: string) =
  reg.enabledOverride.del(tunnelName)

proc pruneOverrides*(reg: Registry; knownTunnelNames: openArray[string]) =
  ## Garbage-collects overrides for tunnel names that have completely
  ## disappeared from the config file.
  var stale: seq[string] = @[]
  for name in reg.enabledOverride.keys:
    if name notin knownTunnelNames:
      stale.add(name)
  for name in stale:
    reg.enabledOverride.del(name)

# ---------------------------------------------------------------------------
# Driving
# ---------------------------------------------------------------------------

proc tickAll*(reg: Registry) =
  ## Called from the daemon's 500ms loop.
  ##
  ## Order matters:
  ## 1. `tick` every `HostSession` (advance the master's state first)
  ## 2. `tick` every `Forward` (this comes after, since it judges based on
  ##    the host's state)
  ## 3. Remove `Forward`s that are `isDiscardable` from the Table
  ##
  ## Why step 3 isn't done directly inside the loop of step 2: deleting
  ## elements from a `Table` while iterating over its values corrupts
  ## Nim's `Table` iterator (undefined behavior, skipped elements). So we
  ## first collect just the ids to be removed into a separate `seq`, and
  ## `del` them all together after the iteration finishes (the general
  ## safe pattern for `std/tables`).
  for hs in reg.hosts.values:
    hostsession.tick(hs)

  for fw in reg.forwards.values:
    forward.tick(fw)

  var discardable: seq[string] = @[]
  for id, fw in reg.forwards:
    if forward.isDiscardable(fw):
      discardable.add(id)
  for id in discardable:
    reg.forwards.del(id)

proc teardownAll*(reg: Registry) =
  ## For graceful shutdown.
  ##
  ## Tears down **Forwards first, then HostSessions** (the order in which
  ## a forward decrements its reference count before the master goes
  ## down. In the reverse order, the master that `forward.teardown`'s
  ## `fw.host.removeForwardRef` call targets would already be down, and
  ## the `cancelForward` call, which uses `ctlPath` / `host` via
  ## `fw.host`, would become meaningless).
  ##
  ## After the call, `reg.forwards` / `reg.hosts` are emptied (this is a
  ## complete cleanup premised on the process itself terminating, so
  ## there's no reason to keep them in the Table. This also lets tests
  ## confirm "no leftovers remain" simply by checking that the Table is
  ## empty).
  for fw in reg.forwards.values:
    forward.teardown(fw)
  reg.forwards.clear()

  for hs in reg.hosts.values:
    hostsession.teardown(hs)
  reg.hosts.clear()
