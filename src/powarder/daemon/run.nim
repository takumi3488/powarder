## The powarder daemon itself. Wires up the modules built in M1-M4
## (registry / reconcile / hostsession / forward / ipc) and provides the
## RPC handlers.
##
## IMPORTANT constraint (the most critical one): **`platform/daemonize.daemonize()`
## must never be called.** `runDaemon()` is designed to run in the
## foreground.
##
## Reason (confirmed by measurement in practice on macOS; see also the
## module doc comment on `tests/tipc.nim`): if `fork()` is called *after*
## asyncdispatch has been touched even once (calling `newAsyncSocket` even
## a single time initializes a global kqueue fd within the process), the
## kqueue fd inherited by the child gets corrupted, and `accept()` inside
## the child process starts failing with "Bad file descriptor". Since the
## daemon uses `newIpcServer` (which internally calls `newAsyncSocket`)
## right from startup, if `runDaemon` itself were to follow the order of
## "start using asyncdispatch first, then `fork()` (daemonize) to go into
## the background", it would end up starting with this corrupted kqueue in
## tow.
##
## For that reason, backgrounding the daemon is designed to be done by the
## **CLI side** via `platform/daemonize.spawnDetached()` (this is
## unaffected even if the existing process has touched asyncdispatch,
## because `execvp` replaces it with a separate executable). This module
## only provides `runDaemon()`, which keeps "the current process itself" --
## whether started from that `spawnDetached()` or manually -- running in
## the foreground.

import std/[asyncdispatch, os, posix, times, monotimes, json, options, tables, strutils]
import std/nativesockets ## Needed to use `Port`'s `$` / `==`
                          ## (because `core/types.nim` re-exports `Port` via
                          ## `export Port` for the type only; same reason as
                          ## in other modules).
import std/deques ## Needed to iterate `ForwardStats.recentSources`
                   ## (a `Deque[SourceEntry]`) with `for` (`proxy/stats.nim`
                   ## exports the type only, so the `items` iterator needs
                   ## this import here to be usable).

import powarder/version
import powarder/core/types
import powarder/core/paths
import powarder/core/forwardspec
import powarder/config/configfile
import powarder/config/statefile
import powarder/platform/lock
import powarder/daemon/registry
import powarder/daemon/reconcile
import powarder/daemon/hostsession
import powarder/daemon/forward
import powarder/daemon/orphan
import powarder/daemon/logstore
import powarder/ipc/server
import powarder/ipc/protocol
import powarder/proxy/upstream

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

const
  daemonVersion* = powarderVersion
  exitAlreadyRunning* = 7
    ## Exit code for a duplicate launch attempt (the lock is already held by
    ## another process). Kept consistent with the CLI side's family of
    ## "cannot reach the daemon" exit codes.
  defaultTickIntervalMs = 500
  defaultStateSaveIntervalMs = 5000
  logRotateIntervalMs = 60_000
    ## Check interval for log rotation (M6). Calling `getFileSize` on every
    ## log file on every tick (500ms) would be wasteful, so it is throttled
    ## to 60 seconds (the same idea as the throttling of state saves in
    ## `config/statefile`).
  isoFormat = "yyyy-MM-dd'T'HH:mm:sszzz"
    ## The same format as `savedAtFormat` in `config/statefile.nim`
    ## (equivalent to ISO8601).

# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------

type
  DaemonOpts* = object
    configPath*: string  ## If empty, uses configfile.findConfigFile()
    socketPath*: string  ## If empty, uses paths.ipcSocketPath()
    activeProfiles*: seq[string]
    tickIntervalMs*: int ## Default 500
    stateSaveIntervalMs*: int ## Default 5000 (saving on every tick would waste I/O)

  Daemon* = ref object
    opts*: DaemonOpts
    reg*: Registry
    server*: IpcServer
    lock*: SingletonLock
    config*: ConfigFile
    startedAt*: MonoTime
    startedAtWall*: times.Time ## Qualified because `std/posix` also exports `Time`
    shuttingDown*: bool
    reloadRequested*: bool
    lastStateSaveAt: MonoTime
      ## Internal-only (tests should not touch it). Timestamp of the last
      ## `persistState` call.
    lastPersistedJson: string
      ## Internal-only. The JSON representation of the `PersistedState`
      ## last saved.
      ##
      ## **"Save whenever reconcile takes an action" is not enough**, so
      ## this is judged by comparing content instead. Right after reconcile
      ## creates a host, `spawnMaster` has not run yet, so it is still
      ## `pid = 0` / `argv = @[]`; saving that state would leave behind
      ## **a record missing the information adopt needs** (this actually
      ## caused adopt to end up as `aoMismatch`). The pid gets filled in
      ## during the next tick's `tickAll`, but at that point reconcile sees
      ## zero diff, so it cannot be detected via "an action was taken".
      ## Comparing against what was actually saved last time means the
      ## moment the pid or state changes is never missed.
    lastLogRotateAt: MonoTime
      ## Internal-only (M6). Timestamp of the last `logstore.rotateAll` call.
    adhocTunnels: Table[string, TunnelConfig]
      ## Internal-only. Ad-hoc tunnel definitions created via
      ## `tunnel.create` that do not exist in the config file.
      ## `desiredState()` passes `config.tunnels` combined with these to
      ## `reconcile` as the desired state.

# ---------------------------------------------------------------------------
# Signals
# ---------------------------------------------------------------------------
#
# The handler generated by `posix.onSignal` is a bare signal handler (which
# must be async-signal-safe), so here we limit ourselves to just setting a
# bool flag. The actual cleanup is done by the 500ms main loop watching that
# flag (no self-pipe trick needed). Since the singleton lock guarantees only
# one daemon runs per process, a module-level global variable is sufficient.

var
  signalShutdownRequested = false
  signalReloadRequested = false

proc installSignalHandlers() =
  ## `SIGTERM` / `SIGINT` -> shutdown, `SIGHUP` -> reload.
  onSignal(SIGTERM, SIGINT):
    signalShutdownRequested = true
  onSignal(SIGHUP):
    signalReloadRequested = true

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

proc secondsSince(t: MonoTime): int =
  int((getMonoTime() - t).inSeconds)

proc getStrArray(params: JsonNode; key: string): seq[string] =
  result = @[]
  if params != nil and params.hasKey(key) and params[key].kind == JArray:
    for item in params[key]:
      if item.kind == JString:
        result.add item.getStr

proc getBoolParam(params: JsonNode; key: string; default: bool): bool =
  if params != nil and params.hasKey(key) and params[key].kind == JBool:
    params[key].getBool
  else:
    default

proc getStrParam(params: JsonNode; key: string; default = ""): string =
  if params != nil and params.hasKey(key) and params[key].kind == JString:
    params[key].getStr
  else:
    default

# ---------------------------------------------------------------------------
# Desired state / known tunnels
# ---------------------------------------------------------------------------

proc desiredState(d: Daemon): DesiredState =
  ## Combines `config.tunnels` with ad-hoc tunnels (`tunnel.create`) into
  ## the desired state passed to reconcile.
  var tunnels = d.config.tunnels
  for tc in d.adhocTunnels.values:
    tunnels.add tc
  DesiredState(tunnels: tunnels, activeProfiles: d.opts.activeProfiles)

proc knownTunnelConfig(d: Daemon; name: string): Option[TunnelConfig] =
  for tc in d.config.tunnels:
    if tc.name == name:
      return some(tc)
  if name in d.adhocTunnels:
    return some(d.adhocTunnels[name])
  none(TunnelConfig)

proc allKnownNames(d: Daemon): seq[string] =
  var seen = initTable[string, bool]()
  result = @[]
  for tc in d.config.tunnels:
    if tc.name notin seen:
      seen[tc.name] = true
      result.add tc.name
  for name in d.adhocTunnels.keys:
    if name notin seen:
      seen[name] = true
      result.add name

proc upsertConfigTunnel(d: Daemon; tc: TunnelConfig) =
  ## Used when `tunnel.up` pulls in a tunnel definition from a separate file
  ## explicitly specified via `config_path` (an existing entry with the
  ## same name is overwritten).
  for i in 0 ..< d.config.tunnels.len:
    if d.config.tunnels[i].name == tc.name:
      d.config.tunnels[i] = tc
      return
  d.config.tunnels.add tc

# ---------------------------------------------------------------------------
# State persistence
# ---------------------------------------------------------------------------

proc buildPersistedState(d: Daemon): PersistedState =
  var hosts: seq[PersistedHostSession] = @[]
  for hs in d.reg.hosts.values:
    hosts.add PersistedHostSession(host: hs.host,
        fingerprint: hs.key.fingerprint, ctlPath: hs.ctlPath,
        logPath: hs.logPath,
        pid: hs.pid, argv: hs.argv,
        state: hs.state, forwardIds: hs.forwardIds)

  var forwards: seq[PersistedForward] = @[]
  for fw in d.reg.forwards.values:
    let udsPath = if fw.spec.kind == fkLocal: fw.upstream.path else: ""
    forwards.add PersistedForward(id: fw.id, tunnelName: fw.tunnelName,
        spec: fw.spec, state: fw.state, udsPath: udsPath)

  PersistedState(version: 1, savedAt: "", hosts: hosts, forwards: forwards)

proc persistState(d: Daemon) =
  ## Saving is ultimately nothing more than a hint to make adopt (M6) after
  ## a crash more efficient (`statefile.loadState` itself is designed to
  ## ignore a corrupted file), so the daemon keeps running even if the save
  ## fails.
  try:
    ensureStateDirs()
    saveState(stateFile(), buildPersistedState(d))
  except CatchableError:
    discard

# ---------------------------------------------------------------------------
# Adopting orphan masters (M6)
# ---------------------------------------------------------------------------

proc logAdoptReport(report: AdoptReport) =
  ## Emits the result of `adoptOrphans` to the startup log.
  ##
  ## **Build long strings with `msg.add` rather than spanning `&` across
  ## multiple lines.** There was an actual incident (a note carried over in
  ## this project) where nimpretty collapsed a trailing `&` and the next
  ## line's `"..."` together, causing `&"..."` to be parsed as a
  ## `strformat` interpolation and fail to compile.
  var adopted = 0
  var deadReclaimed = 0
  var mismatch = 0
  var noSocket = 0
  for h in report.hosts:
    case h.outcome
    of aoAdopted: inc adopted
    of aoDeadReclaimed: inc deadReclaimed
    of aoMismatch: inc mismatch
    of aoNoSocket: inc noSocket

  var msg = "powarder: orphan master adopt: "
  msg.add "hosts_adopted=" & $adopted
  msg.add " hosts_dead_reclaimed=" & $deadReclaimed
  msg.add " hosts_mismatch=" & $mismatch
  msg.add " hosts_no_socket=" & $noSocket
  msg.add " forwards_adopted=" & $report.adoptedForwards.len
  msg.add " forwards_reattach=" & $report.reattachForwards.len
  msg.add " stale_sockets_removed=" & $report.staleSocketsRemoved
  stderr.writeLine(msg)

  for note in report.notes:
    stderr.writeLine("powarder: adopt note: " & note)

# ---------------------------------------------------------------------------
# reload
# ---------------------------------------------------------------------------

proc doReload(d: Daemon): ReconcileReport =
  ## Reloads the config and reconciles. Called both from the
  ## `daemon.reload` handler and from the `reloadRequested` flag via
  ## `SIGHUP`.
  ##
  ## If loading fails, keeps the previous config and just adds a warning
  ## (the same "a config mistake must not kill the daemon" policy as at
  ## `newDaemon` startup).
  var warnings: seq[string] = @[]
  try:
    let cfg = loadConfig(d.opts.configPath)
    let vwarnings = validateConfig(cfg)
    d.config = cfg
    for w in vwarnings:
      if w.startsWith("warning: "):
        stderr.writeLine("powarder: " & w)
      else:
        stderr.writeLine("powarder: error: " & w)
      warnings.add w
  except ConfigError as e:
    let msg = "warning: failed to reload the config. Keeping the previous config: " & e.msg
    stderr.writeLine("powarder: " & msg)
    warnings.add msg

  # **Discard the `(host, extraArgs)` -> fingerprint cache.**
  # Since reload is a "re-read the config" operation, the re-evaluation of
  # `~/.ssh/config` is also done here. Without this call, editing
  # ssh_config and reloading would not take effect -- a confusing
  # behavior. Existing HostSession / Forward instances are not discarded;
  # only hosts whose fingerprint changed get swapped out via the general
  # Add/Remove logic.
  d.reg.clearHostKeyCache()

  result = reconcile(d.desiredState(), d.reg)
  for w in warnings:
    result.warnings.insert(w, 0)

# ---------------------------------------------------------------------------
# JSON assembly for tunnel.list / tunnel.inspect
# ---------------------------------------------------------------------------

proc forwardUptimeSeconds(fw: Forward): JsonNode =
  ## `fkLocal`: from the time the listener (`proxy.stats`) first started.
  ## `fkRemote` (or `fkLocal` before it has a proxy yet): uses instead the
  ## time the owning master last established a connection (an
  ## approximation, since fkRemote has no record of its own for "how long
  ## has it been active").
  let st = stats(fw)
  if st.isSome:
    %secondsSince(st.get.startedAtMono)
  elif fw.host.lastConnectedAt.isSome:
    %secondsSince(fw.host.lastConnectedAt.get())
  else:
    newJNull()

proc tunnelEntryFromForward(fw: Forward): JsonNode =
  result = newJObject()
  result["name"] = %fw.tunnelName
  result["type"] = %fw.spec.kind
  result["bind"] = %(fw.spec.bindAddr & ":" & $fw.spec.bindPort)
  result["target"] = %(fw.spec.targetHost & ":" & $fw.spec.targetPort)
  result["host"] = %fw.host.host
  result["state"] = %($fw.state)
  result["status"] = %describeState(fw)

  let st = stats(fw)
  if st.isSome:
    # IMPORTANT: -R fundamentally cannot have statistics (no proxy can be
    # interposed), so it never enters this branch; below in the else, all
    # four fields end up null. The CLI side sees that and displays "-".
    let s = st.get
    result["conns"] = %s.activeConns
    result["total_conns"] = %s.totalConns
    result["rx"] = %s.bytesRx
    result["tx"] = %s.bytesTx
    result["last_activity_seconds"] = %secondsSince(s.lastActivityMono)
  else:
    result["conns"] = newJNull()
    result["total_conns"] = newJNull()
    result["rx"] = newJNull()
    result["tx"] = newJNull()
    result["last_activity_seconds"] = newJNull()

  result["uptime_seconds"] = forwardUptimeSeconds(fw)
  result["last_error"] = (if fw.lastError.len > 0: %fw.lastError else: newJNull())

proc tunnelEntryFromConfig(tc: TunnelConfig): JsonNode =
  ## Display entry for a tunnel that has no live `Forward` in the registry
  ## (either it is disabled, or it was just enabled and reconcile hasn't
  ## caught up to it yet).
  ##
  ## **`state` must always hold only a genuine `ForwardState` string**
  ## (so that the CLI side does not break even if it parses `state` as an
  ## enum). The fact that it is "disabled" is instead expressed via the
  ## free-form `status` field ("stopped"). The underlying reason is that
  ## `ForwardState` has no value representing "disabled", so this is
  ## flagged as a suggestion to add a dedicated value to
  ## `core/types.ForwardState`.
  result = newJObject()
  result["name"] = %tc.name
  result["type"] = %tc.spec.kind
  result["bind"] = %(tc.spec.bindAddr & ":" & $tc.spec.bindPort)
  result["target"] = %(tc.spec.targetHost & ":" & $tc.spec.targetPort)
  result["host"] = %tc.host
  result["state"] = %($fwPending)
  result["status"] = %"stopped"
  result["conns"] = newJNull()
  result["total_conns"] = newJNull()
  result["rx"] = newJNull()
  result["tx"] = newJNull()
  result["last_activity_seconds"] = newJNull()
  result["uptime_seconds"] = newJNull()
  result["last_error"] = newJNull()

# ---------------------------------------------------------------------------
# RPC handlers
# ---------------------------------------------------------------------------

proc handleDaemonPing(d: Daemon; params: JsonNode): JsonNode =
  %*{"ok": true, "pid": getCurrentProcessId(), "version": daemonVersion}

proc handleDaemonInfo(d: Daemon; params: JsonNode): JsonNode =
  %*{
    "pid": getCurrentProcessId(),
    "version": daemonVersion,
    "socket": d.server.path,
    "uptime_seconds": secondsSince(d.startedAt),
    "started_at": d.startedAtWall.format(isoFormat),
    "hosts": d.reg.hosts.len,
    "forwards": d.reg.forwards.len,
    "config_path": d.opts.configPath,
  }

proc handleDaemonReload(d: Daemon; params: JsonNode): JsonNode =
  let report = d.doReload()
  var actions = newJArray()
  for a in report.actions:
    actions.add %*{"action": $a.action, "target": a.target}
  %*{"actions": actions, "warnings": report.warnings,
      "tunnels": d.config.tunnels.len}

proc handleDaemonShutdown(d: Daemon; params: JsonNode): JsonNode =
  ## Just sets a flag. The actual graceful shutdown is performed by
  ## `runDaemon` after the main loop exits.
  d.shuttingDown = true
  %*{"ok": true}

proc handleTunnelList(d: Daemon; params: JsonNode): JsonNode =
  let all = getBoolParam(params, "all", false)
  result = newJArray()
  for tc in d.desiredState().tunnels:
    let enabled = isEnabled(d.reg, tc.name, tc.autostart)
    if not enabled:
      if all:
        result.add tunnelEntryFromConfig(tc)
      continue
    let fws = forwardsOfTunnel(d.reg, tc.name)
    if fws.len > 0:
      result.add tunnelEntryFromForward(fws[0])
    else:
      # A momentary state right after being enabled, where reconcile has
      # not created the Forward yet.
      result.add tunnelEntryFromConfig(tc)

proc handleTunnelInspect(d: Daemon; params: JsonNode): JsonNode =
  let name = getStrParam(params, "name")
  if name.len == 0:
    raise newRpcError(rpcInvalidParams, "name is required")

  let fws = forwardsOfTunnel(d.reg, name)
  if fws.len > 0:
    let fw = fws[0]
    result = tunnelEntryFromForward(fw)
    result["id"] = %fw.id
    result["uds_path"] = %(if fw.spec.kind ==
        fkLocal: fw.upstream.path else: "")
    result["ctl_path"] = %fw.host.ctlPath
    result["log_path"] = %fw.host.logPath
    result["fingerprint"] = %fw.host.key.fingerprint
    result["spec"] = toJson(fw.spec)
    let st = stats(fw)
    var srcs = newJArray()
    if st.isSome:
      for s in st.get.recentSources:
        srcs.add %*{"address": s.address, "port": s.port.int}
    result["recent_sources"] = srcs
    result["consecutive_health_failures"] = %fw.consecutiveHealthFailures
    return result

  let tcOpt = d.knownTunnelConfig(name)
  if tcOpt.isSome:
    let tc = tcOpt.get
    result = tunnelEntryFromConfig(tc)
    result["id"] = %forwardId(tc.spec, tc.host)
    result["uds_path"] = %""
    result["ctl_path"] = %""
    result["log_path"] = %""
    result["fingerprint"] = %""
    result["spec"] = toJson(tc.spec)
    result["recent_sources"] = newJArray()
    result["consecutive_health_failures"] = %0
    return result

  raise newRpcError(errTunnelNotFound, "tunnel not found: " & name)

proc handleTunnelUp(d: Daemon; params: JsonNode): JsonNode =
  let names = getStrArray(params, "names")
  if params != nil and params.hasKey("profiles") and params["profiles"].kind == JArray:
    # `up` is an operation that fixes "the set of profiles active for this
    # session" (the same idea as docker compose's `--profile`), so it is
    # persisted to also take effect on subsequent reconciles (the main
    # loop and any later `reconcile` calls).
    d.opts.activeProfiles = getStrArray(params, "profiles")

  let configPathOverride = getStrParam(params, "config_path")
  if configPathOverride.len > 0:
    try:
      let loaded = loadConfig(configPathOverride)
      for tc in loaded.tunnels:
        d.upsertConfigTunnel(tc)
    except ConfigError as e:
      raise newRpcError(errConfigInvalid,
          "failed to load config_path: " & e.msg)

  var targetNames = names
  if targetNames.len == 0:
    for tc in d.config.tunnels:
      if isTargeted(tc, d.opts.activeProfiles):
        targetNames.add tc.name

  var started: seq[string] = @[]
  var failed = newJArray()
  for name in targetNames:
    if d.knownTunnelConfig(name).isNone:
      failed.add %*{"name": name, "error": "unknown tunnel: " & name}
      continue
    setEnabled(d.reg, name, true)
    started.add name

  discard reconcile(d.desiredState(), d.reg)

  %*{"started": started, "failed": failed}

proc handleTunnelDown(d: Daemon; params: JsonNode): JsonNode =
  let names = getStrArray(params, "names")
  let profiles =
    if params != nil and params.hasKey("profiles") and params[
        "profiles"].kind == JArray:
      getStrArray(params, "profiles")
    else:
      d.opts.activeProfiles
  let immediate = getBoolParam(params, "immediate", false)

  var targetNames = names
  if targetNames.len == 0:
    for tc in d.config.tunnels:
      if isTargeted(tc, profiles):
        targetNames.add tc.name

  for name in targetNames:
    setEnabled(d.reg, name, false)

  discard reconcile(d.desiredState(), d.reg)

  if immediate:
    # Tear down the master right now instead of waiting for the idle grace
    # period (default 25 seconds) on hosts whose references have dropped to
    # zero. This also applies uniformly to hosts outside this `down`
    # target that already have refCount == 0, but that causes no real harm
    # since such hosts are destined to stop naturally anyway.
    for hs in d.reg.hosts.values:
      if refCount(hs) == 0:
        requestStop(hs, immediate = true)

  %*{"stopped": targetNames}

proc checkNamesKnown(d: Daemon; names: seq[string]) =
  var unknown = newJArray()
  var anyUnknown = false
  for name in names:
    if d.knownTunnelConfig(name).isNone:
      unknown.add %name
      anyUnknown = true
  if anyUnknown:
    raise newRpcError(errTunnelNotFound, "tunnel(s) not found",
        %*{"names": unknown})

proc handleTunnelStart(d: Daemon; params: JsonNode): JsonNode =
  let names = getStrArray(params, "names")
  checkNamesKnown(d, names)
  for name in names:
    setEnabled(d.reg, name, true)
  discard reconcile(d.desiredState(), d.reg)
  %*{"started": names}

proc handleTunnelStop(d: Daemon; params: JsonNode): JsonNode =
  let names = getStrArray(params, "names")
  checkNamesKnown(d, names)
  for name in names:
    setEnabled(d.reg, name, false)
  discard reconcile(d.desiredState(), d.reg)
  %*{"stopped": names}

proc handleTunnelRestart(d: Daemon; params: JsonNode): JsonNode =
  let names = getStrArray(params, "names")
  checkNamesKnown(d, names)
  for name in names:
    setEnabled(d.reg, name, true)
    for fw in forwardsOfTunnel(d.reg, name):
      if fw.state != fwDetaching:
        requestDetach(fw) ## Rides the next reconcile's remove -> recreate cycle
  discard reconcile(d.desiredState(), d.reg)
  %*{"restarted": names}

proc handleTunnelCreate(d: Daemon; params: JsonNode): JsonNode =
  let name = getStrParam(params, "name")
  if name.len == 0:
    raise newRpcError(rpcInvalidParams, "name is required")
  if d.knownTunnelConfig(name).isSome:
    raise newRpcError(errTunnelNameConflict, "tunnel name already exists: " & name)

  let host = getStrParam(params, "host")
  let typeStr = getStrParam(params, "type", "L")
  let forwardStr = getStrParam(params, "forward")

  var kind: ForwardKind
  try:
    kind = parseEnum[ForwardKind](typeStr)
  except ValueError:
    raise newRpcError(rpcInvalidParams, "type must be \"L\" or \"R\"")

  var spec: ForwardSpec
  try:
    spec = parseForwardSpec(forwardStr, kind)
  except ValueError as e:
    raise newRpcError(rpcInvalidParams, e.msg)

  let tc = TunnelConfig(name: name, host: host, spec: spec, autostart: false,
      profile: "", sshExtraArgs: @[], retry: initRetryPolicy())
  d.adhocTunnels[name] = tc
  setEnabled(d.reg, name, true)
  discard reconcile(d.desiredState(), d.reg)

  let fws = forwardsOfTunnel(d.reg, name)
  let state = if fws.len > 0: $fws[0].state else: $fwPending
  %*{"name": name, "state": state}

proc handleTunnelRemove(d: Daemon; params: JsonNode): JsonNode =
  let names = getStrArray(params, "names")
  for name in names:
    setEnabled(d.reg, name, false)
  discard reconcile(d.desiredState(), d.reg)
  for name in names:
    clearEnabledOverride(d.reg, name)
    d.adhocTunnels.del(name)
  %*{"removed": names}

proc handleTunnelCheck(d: Daemon; params: JsonNode): JsonNode =
  var names = getStrArray(params, "names")
  if names.len == 0:
    names = d.allKnownNames()
  let probe = getBoolParam(params, "probe", false)

  result = newJArray()
  for name in names:
    let fws = forwardsOfTunnel(d.reg, name)
    var ok = false
    var detail = "not registered"
    if fws.len > 0:
      let fw = fws[0]
      ok = fw.state == fwActive
      detail =
        if ok: fw.spec.bindAddr & ":" & $fw.spec.bindPort & " is accepting connections"
        elif fw.lastError.len > 0: fw.lastError
        else: describeState(fw)

      # Only run the actual Tier2 probe when probe=true (not run by
      # default: as noted in the doc comment on
      # `proxy/upstream.probeUpstream`, OpenSSH's
      # `channel_post_port_listener` makes a real connection to the
      # destination right after accept). `fkRemote` cannot be probed since
      # powarder never sits in its data path.
      if probe and ok and fw.spec.kind == fkLocal:
        let probeFut = probeUpstream(fw.upstream)
        # RpcHandler is a synchronous proc, so this is the one place that
        # crosses the sync/async boundary via `waitFor` (unlike the
        # `tick()` family, this is not a "nested waitFor" waiting on
        # another Future while an async loop is already running, but a
        # single one-off bridge from a synchronous call into async
        # processing). A `withTimeout` caps how long we wait, so an
        # unresponsive probe cannot stall this forever.
        let completed =
          try: waitFor(withTimeout(probeFut, 3000))
          except CatchableError: false
        let reachable = completed and (try: probeFut.read() except CatchableError: false)
        ok = reachable
        if not reachable:
          detail = "Tier2 probe failed (destination unreachable)"
    result.add %*{"name": name, "ok": ok, "detail": detail}

proc handleHostList(d: Daemon; params: JsonNode): JsonNode =
  result = newJArray()
  for hs in d.reg.hosts.values:
    let uptime =
      if hs.lastConnectedAt.isSome: %secondsSince(hs.lastConnectedAt.get())
      else: newJNull()
    result.add %*{
      "host": hs.host,
      "fingerprint": hs.key.fingerprint,
      "state": $hs.state,
      "tunnels": hs.forwardIds.len,
      "pid": hs.pid,
      "uptime_seconds": uptime,
      "retries": hs.consecutiveFailures,
      "last_error": (if hs.lastError.len > 0: %hs.lastError else: newJNull()),
      "ctl_path": hs.ctlPath,
    }

proc registerHandlers(d: Daemon) =
  d.server.register(mDaemonPing, proc(p: JsonNode): JsonNode = handleDaemonPing(d, p))
  d.server.register(mDaemonInfo, proc(p: JsonNode): JsonNode = handleDaemonInfo(d, p))
  d.server.register(mDaemonReload, proc(
      p: JsonNode): JsonNode = handleDaemonReload(d, p))
  d.server.register(mDaemonShutdown, proc(
      p: JsonNode): JsonNode = handleDaemonShutdown(d, p))
  d.server.register(mTunnelList, proc(p: JsonNode): JsonNode = handleTunnelList(d, p))
  d.server.register(mTunnelInspect, proc(
      p: JsonNode): JsonNode = handleTunnelInspect(d, p))
  d.server.register(mTunnelCreate, proc(
      p: JsonNode): JsonNode = handleTunnelCreate(d, p))
  d.server.register(mTunnelUp, proc(p: JsonNode): JsonNode = handleTunnelUp(d, p))
  d.server.register(mTunnelDown, proc(p: JsonNode): JsonNode = handleTunnelDown(d, p))
  d.server.register(mTunnelRestart, proc(
      p: JsonNode): JsonNode = handleTunnelRestart(d, p))
  d.server.register(mTunnelStart, proc(
      p: JsonNode): JsonNode = handleTunnelStart(d, p))
  d.server.register(mTunnelStop, proc(
      p: JsonNode): JsonNode = handleTunnelStop(d, p))
  d.server.register(mTunnelRemove, proc(
      p: JsonNode): JsonNode = handleTunnelRemove(d, p))
  d.server.register(mTunnelCheck, proc(p: JsonNode): JsonNode = handleTunnelCheck(d, p))
  d.server.register(mHostList, proc(p: JsonNode): JsonNode = handleHostList(d, p))

# ---------------------------------------------------------------------------
# Construction
# ---------------------------------------------------------------------------

proc newDaemon*(opts: DaemonOpts): Daemon =
  ## Performs everything in the startup sequence **except acquiring the
  ## lock** (config loading, state loading, registry creation, IPC server
  ## creation, handler registration).
  ##
  ## **The lock is not acquired here.** `runDaemon` needs the branch "if the
  ## lock cannot be acquired, give up on constructing a `Daemon` at all and
  ## exit with code 7" (regardless of `newIpcServer`, `ensureRuntimeDir`,
  ## etc., we want to detect a duplicate launch and exit immediately without
  ## creating anything), so the responsibility of acquiring the lock is
  ## placed on `runDaemon`'s side. When `newDaemon` is called standalone
  ## from a test, `result.lock` becomes an unacquired dummy value
  ## (`fd: -1`) (`shutdown` sees this and does nothing).
  ensureRuntimeDir()
  ensureStateDirs()

  let configPath = if opts.configPath.len > 0: opts.configPath
                    else: findConfigFile()

  var cfg: ConfigFile
  try:
    cfg = loadConfig(configPath)
    let warnings = validateConfig(cfg)
    for w in warnings:
      if w.startsWith("warning: "):
        stderr.writeLine("powarder: " & w)
      else:
        stderr.writeLine("powarder: error: " & w)
  except ConfigError as e:
    # A policy of "better to come up with an empty config so the situation
    # is visible via `ps` etc. than to have a config mistake keep the
    # daemon from coming up at all" (the same idea as
    # `config/statefile.loadState`).
    stderr.writeLine("powarder: warning: failed to load the config file. Starting with an empty config: " & e.msg)
    cfg = defaultConfig()

  let persisted = loadState(stateFile())
  let reg = newRegistry()
  # Adopting orphan masters/forwards (M6). It does not matter whether this
  # runs before or after `newIpcServer` (asyncdispatch) -- `runDaemon` is
  # designed to never call fork() at all, so the kqueue corruption that
  # happens when forking after touching asyncdispatch cannot occur here
  # (see the "IMPORTANT constraint" in the module doc comment on
  # `daemon/run.nim`) -- but it is placed here for the semantic reason of
  # being "right after loading the previous record".
  logAdoptReport(adoptOrphans(reg, persisted))

  let sockPath = if opts.socketPath.len >
      0: opts.socketPath else: ipcSocketPath()
  let server = newIpcServer(sockPath)

  var normalizedOpts = opts
  normalizedOpts.configPath = configPath
  normalizedOpts.socketPath = sockPath
  if normalizedOpts.tickIntervalMs <= 0:
    normalizedOpts.tickIntervalMs = defaultTickIntervalMs
  if normalizedOpts.stateSaveIntervalMs <= 0:
    normalizedOpts.stateSaveIntervalMs = defaultStateSaveIntervalMs

  result = Daemon(
    opts: normalizedOpts,
    reg: reg,
    server: server,
    lock: SingletonLock(fd: -1, path: ""),
    config: cfg,
    startedAt: getMonoTime(),
    startedAtWall: getTime(),
    shuttingDown: false,
    reloadRequested: false,
    lastStateSaveAt: getMonoTime(),
    lastLogRotateAt: getMonoTime(),
    adhocTunnels: initTable[string, TunnelConfig](),
  )
  registerHandlers(result)

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

proc syncSignalFlags(d: Daemon) =
  ## Reflects the global flags set by the signal handler into `Daemon`.
  if signalShutdownRequested:
    d.shuttingDown = true
  if signalReloadRequested:
    signalReloadRequested = false
    d.reloadRequested = true

proc tickOnce*(d: Daemon): Future[ReconcileReport] {.async.} =
  ## Public proc that advances just one iteration of the main loop.
  ##
  ## Split out from `mainLoop` (the infinite loop containing
  ## `await sleepAsync`) for testability. Tests can call this directly and
  ## repeatedly to "replay just a few steps of progress without actually
  ## running the daemon's loop".
  syncSignalFlags(d)

  result = ReconcileReport(actions: @[], warnings: @[])
  if d.reloadRequested:
    d.reloadRequested = false
    result = d.doReload()

  d.reg.tickAll()
  let r2 = reconcile(d.desiredState(), d.reg)
  for a in r2.actions:
    result.actions.add(a)
  for w in r2.warnings:
    result.warnings.add(w)

  # State persistence. `state.json` is **the only clue for adopting orphan
  # masters after a crash** (since `-O` has no subcommand that returns "the
  # list of forwards currently attached"), so if the daemon crashes before
  # the record is saved, adopt cannot happen and a live orphan master gets
  # missed.
  #
  # **"Save whenever reconcile takes an action" misses cases.** Right after
  # reconcile creates a host, `spawnMaster` has not run yet, so it is still
  # `pid = 0` / `argv = @[]`, and that incomplete record would get saved.
  # The pid gets filled in during the next tick's `tickAll`, but at that
  # point reconcile sees zero diff, so it does not show up as "an action
  # was taken". This actually caused adopt to end up as `aoMismatch` (no
  # process exists for pid=0).
  #
  # So **compare against what was actually saved last time, and save only
  # if it changed**. Ticks with no change do not write, so I/O does not
  # increase. The periodic save is also kept as a safety net.
  let snapshot = buildPersistedState(d)
  let snapshotJson = $(%snapshot) ## savedAt does not affect the comparison since buildPersistedState sets it to ""
  if snapshotJson != d.lastPersistedJson or
      secondsSince(d.lastStateSaveAt) * 1000 >= d.opts.stateSaveIntervalMs:
    d.persistState()
    d.lastPersistedJson = snapshotJson
    d.lastStateSaveAt = getMonoTime()

  # Log rotation (M6). Calling `getFileSize` on every log file on every
  # tick (default 500ms) would be wasteful, so it is throttled to
  # `logRotateIntervalMs` (60 seconds) (the same throttling pattern as
  # `lastStateSaveAt`).
  if secondsSince(d.lastLogRotateAt) * 1000 >= logRotateIntervalMs:
    discard rotateAll(logsDir())
    d.lastLogRotateAt = getMonoTime()

proc mainLoop(d: Daemon) {.async.} =
  while not d.shuttingDown:
    discard await d.tickOnce()
    if d.shuttingDown:
      break
    await sleepAsync(d.opts.tickIntervalMs)

# ---------------------------------------------------------------------------
# Shutdown
# ---------------------------------------------------------------------------

proc shutdown*(d: Daemon) =
  ## Graceful shutdown.
  ##
  ## **Call this only after the async loop has fully stopped.**
  ## `reg.teardownAll()` internally uses `waitFor` (see the doc comment on
  ## `forward.teardown` / `hostsession.teardown`), so calling it while
  ## `tick` is still running (i.e. while the async loop is executing) would
  ## nest `waitFor` inside the event loop.
  ##
  ## Steps: 1. Close the IPC server (stop accepting) -> 2. `teardownAll`
  ## (clean up Forward first, then HostSession) -> 3. Save the final state
  ## -> 4. Release the lock (this also removes the lock file itself,
  ## mirroring how `server.close()` takes care of removing the socket
  ## file).
  if d.server != nil:
    try: d.server.close()
    except CatchableError: discard

  try: d.reg.teardownAll()
  except CatchableError: discard

  try: d.persistState()
  except CatchableError: discard

  if d.lock.fd >= 0:
    let lockPathToRemove = d.lock.path
    d.lock.release()
    if lockPathToRemove.len > 0:
      removeFile(lockPathToRemove)

# ---------------------------------------------------------------------------
# Public entry point
# ---------------------------------------------------------------------------

proc runDaemon*(opts = DaemonOpts()): int =
  ## Runs in the foreground. Returns an exit code. **Never call
  ## `daemonize()`** (see the "IMPORTANT constraint" in the module doc
  ## comment).
  ##
  ## Startup sequence (order matters):
  ## 1. `ensureRuntimeDir` / `ensureStateDirs`
  ## 2. Acquire the singleton lock. If it cannot be acquired, exit code
  ##    `exitAlreadyRunning` (7). If acquired, `writePid`. **`writePid` is
  ##    implemented to reuse the already-acquired fd as-is** (see the doc
  ##    comment on `platform/lock.nim`: a POSIX fcntl lock is keyed on
  ##    (process, inode), so reopening the same file under a different fd
  ##    and closing it would release every lock this process holds on that
  ##    file. That is why `writePid` is designed to reuse the fd used to
  ##    acquire the lock -- do not `open()` it anew here).
  ## 3-6. `newDaemon` (config / state / registry / IPC server)
  ## 7. Register signal handlers
  ## 8. Run the main loop as async
  ensureRuntimeDir()
  ensureStateDirs()

  let lockFilePath = lockPath()
  let gotLock = tryAcquireSingletonLock(lockFilePath)
  if gotLock.isNone:
    stderr.writeLine("powarder: the daemon is already running (lock: " &
        lockFilePath & ")")
    return exitAlreadyRunning

  let acquiredLock = gotLock.get
  acquiredLock.writePid(getCurrentProcessId())

  var d: Daemon = nil
  try:
    d = newDaemon(opts)
    d.lock = acquiredLock

    installSignalHandlers()

    # `serve()`'s accept loop and `mainLoop()` need to run at the same time.
    #
    # **Choice made**: register the accept loop as a background task with
    # `asyncCheck serve(d.server)`, then `waitFor mainLoop(d)`.
    # Reason: asyncdispatch shares a single, single-threaded cooperative
    # dispatcher across the whole process, so while `serve()` is suspended
    # on an await, both the completion of `mainLoop`'s `sleepAsync` and new
    # connections from IPC clients -- running on that same dispatcher --
    # are still processed as usual (a form that manually combines Futures,
    # like `waitFor(a and b)`, does not fit this use case: `std/asyncdispatch`
    # has no built-in `and` operator, and `serve()` is a Future that never
    # completes until `close()` is called in the first place, so "wait for
    # both to finish" is not a combination that makes sense here). If
    # `serve()` fails for a reason other than a normal close via `close()`,
    # the `asyncCheck` mechanism re-raises the exception at the next
    # `poll()` (i.e. inside `waitFor mainLoop(d)`'s internal loop), and the
    # daemon terminates abnormally along with `mainLoop`. This indicates a
    # situation where "the IPC layer is broken", and it is a deliberate
    # behavior meant to surface that rather than paper over it.
    asyncCheck serve(d.server)
    waitFor mainLoop(d)
  finally:
    if d != nil:
      shutdown(d)
    else:
      # Even if `newDaemon` itself throws, always release the lock we
      # already acquired.
      acquiredLock.release()
      removeFile(lockFilePath)

  0
