## The core of the `powarder` CLI: wires subcommands up to RPC calls to the
## daemon / file reads, writes to stdout, and determines the exit code.
##
## For testability, this separates "functions that build strings"
## (`renderPsTable` / `renderHostsTable` / `tailLines` / `readIncrement`, etc.,
## all exported with `*`) from "functions that actually `echo` and call RPCs"
## (the `cmdXxx` group, called from `dispatch*`). The former are pure functions
## that can be tested without the daemon.
##
## Does not depend on the daemon itself (`daemon/run.nim`). Running `daemon
## --foreground` is injected by receiving a function of type `DaemonRunner` as
## an argument to `dispatch*` (the caller, `src/powarder.nim`, supplies the
## real implementation).

import std/[json, os, times, strutils, options]
import powarder/version
import powarder/cli/argv
import powarder/cli/output
import powarder/cli/names
import powarder/cli/autostart
import powarder/cli/cmd_completion
import powarder/ipc/client
import powarder/ipc/protocol
import powarder/core/paths
import powarder/core/fmt
import powarder/core/forwardspec
import powarder/core/errorclass
import powarder/core/types
import powarder/platform/lock
import powarder/platform/service
import powarder/config/configfile
import std/nativesockets ## needed for `Port`'s `$` (core/types only exports the type)

type
  ExitCode* = enum
    ecOk = 0, ecGeneral = 1, ecUsage = 2, ecConfig = 3, ecNotFound = 4,
    ecConflict = 5, ecSshFailed = 6, ecDaemonUnreachable = 7

  DaemonRunner* = proc (): int {.closure.}
    ## The function that starts the daemon itself when `powarder daemon` is
    ## invoked with no subsubcommand (= foreground startup). Injected from
    ## `src/powarder.nim` (dependency injection to avoid a direct dependency on
    ## `daemon/run.nim`). If `nil`, prints a message saying the daemon isn't
    ## built into this binary and returns `ecGeneral`.

const
  cliVersion* = powarderVersion
    ## Importing `powarderVersion` from `src/powarder.nim` here would create a
    ## circular import (since `powarder.nim` ultimately imports
    ## `cli/dispatch`), so this holds its own independent constant instead.
    ## `src/powarder.nim` is responsible for keeping the two values in sync
    ## (since the agent responsible for this module cannot modify
    ## `powarder.nim`).

  daemonUnreachableMsg =
    "could not reach the powarder daemon " &
    "(try 'powarder daemon start', or drop --no-autostart)"

  # `tunnel.start` / `tunnel.stop` use `mTunnelStart` / `mTunnelStop` from
  # `protocol.nim` (referencing the same constants the daemon side uses
  # prevents the accident of changing the string on only one side without
  # noticing).

# ---------------------------------------------------------------------------
# RpcRemoteError.code -> exit code mapping (the single source of truth)
# ---------------------------------------------------------------------------

proc exitCodeForRpcError*(code: int): ExitCode =
  ## The mapping table from `RpcRemoteError.code` to the CLI's exit code. See
  ## `ipc/protocol` for the definitions of the error codes returned by the
  ## daemon itself.
  ##
  ## `DaemonNotRunningError` is not covered by this table (it's a different
  ## exception type, not `RpcRemoteError`). Callers that catch it should always
  ## use `ecDaemonUnreachable` (7).
  case code
  of errTunnelNotFound: ecNotFound
  of errTunnelNameConflict: ecConflict
  of errSshFailed: ecSshFailed
  of errConfigInvalid: ecConfig
  else: ecGeneral

# ---------------------------------------------------------------------------
# Table formatting (pure functions; testable without the daemon)
# ---------------------------------------------------------------------------

const
  psHeader = @["NAME", "TYPE", "BIND", "TARGET", "HOST", "CONNS", "RX/TX",
               "LAST", "UPTIME", "STATUS"]
  hostsHeader = @["HOST", "STATE", "TUNNELS", "PID", "UPTIME", "RETRIES"]

proc renderPsTable*(rows: JsonNode; w: Writer): string =
  ## Formats the result of `tunnel.list` (an array of JsonNode) into a table
  ## string.
  ##
  ## Statistics (`conns` / `total_conns` / `rx` / `tx` /
  ## `last_activity_seconds`) can't in principle be collected for `-R`
  ## forwards, so the daemon always returns `null` for them (a contract of the
  ## M5 RPC schema). Here we detect that and render `"-"` in the relevant
  ## columns.
  var body: seq[seq[string]] = @[]
  for row in rows:
    let typeCol = "-" & row["type"].getStr
    let connsCol =
      if row["conns"].kind == JNull: "-"
      else: $row["conns"].getBiggestInt
    let rxTxCol =
      if row["rx"].kind == JNull or row["tx"].kind == JNull: "-"
      else:
        formatBytes(row["rx"].getBiggestInt.uint64) & "/" &
        formatBytes(row["tx"].getBiggestInt.uint64)
    let lastCol =
      if row["last_activity_seconds"].kind == JNull: "-"
      else: formatAgo(initDuration(seconds = row[
          "last_activity_seconds"].getBiggestInt))
    let uptimeCol = formatDuration(initDuration(seconds = row[
        "uptime_seconds"].getBiggestInt))
    body.add @[
      row["name"].getStr,
      typeCol,
      row["bind"].getStr,
      row["target"].getStr,
      row["host"].getStr,
      connsCol,
      rxTxCol,
      lastCol,
      uptimeCol,
      row["status"].getStr,
    ]
  table(w, psHeader, body)

proc renderHostsTable*(rows: JsonNode; w: Writer): string =
  ## Formats the result of `host.list` into a table string.
  var body: seq[seq[string]] = @[]
  for row in rows:
    let pidCol =
      if row["pid"].kind == JNull: "-"
      else: $row["pid"].getBiggestInt
    body.add @[
      row["host"].getStr,
      row["state"].getStr,
      $row["tunnels"].getBiggestInt,
      pidCol,
      formatDuration(initDuration(seconds = row[
          "uptime_seconds"].getBiggestInt)),
      $row["retries"].getBiggestInt,
    ]
  table(w, hostsHeader, body)

proc renderInspect*(node: JsonNode): string =
  ## Formats the result of `tunnel.inspect` as a list of `key: value` lines.
  ## Nested objects/arrays are pretty-printed with `pretty()` and embedded with
  ## indentation.
  var lines: seq[string] = @[]
  for k, v in node.pairs:
    case v.kind
    of JString: lines.add(k & ": " & v.getStr)
    of JNull: lines.add(k & ": -")
    of JObject, JArray: lines.add(k & ":\n" & indent(v.pretty(), 2))
    else: lines.add(k & ": " & $v)
  lines.join("\n")

# ---------------------------------------------------------------------------
# Log tailing (pure functions; testable without the daemon)
# ---------------------------------------------------------------------------

proc tailLines*(path: string; n: int): seq[string] =
  ## Reads the whole file and returns the last `n` lines. Returns an empty seq
  ## if the file doesn't exist. powarder's tunnel logs are split per tunnel and
  ## typically stay small by default, so we skip the optimization of seeking
  ## from the end and just read the whole file.
  if not fileExists(path):
    return @[]
  var lines = readFile(path).splitLines()
  # `splitLines` appends one extra empty-string element at the end if the
  # input ends with a newline. That's just visual noise, so strip it if the
  # last element is empty.
  if lines.len > 0 and lines[^1].len == 0:
    lines.setLen(lines.len - 1)
  if lines.len <= n:
    return lines
  lines[lines.len - n .. ^1]

proc readIncrement*(path: string; offset: int64): tuple[data: string;
    newOffset: int64] =
  ## The pure incremental-read function used by the `logs -f` polling loop.
  ##
  ## - File doesn't exist: no increment. Returns `offset` unchanged (the file
  ##   might just not have been created yet, or might be temporarily gone, so
  ##   we don't reset to 0; this lets us pick up where we left off if it
  ##   reappears).
  ## - Current file size is smaller than `offset`: treated as a **rotation
  ##   (truncate)**, so we re-read from the start (0).
  ## - Otherwise: reads from `offset` to the end and returns it.
  if not fileExists(path):
    return ("", offset)
  let size = getFileSize(path)
  let startOffset = if size < offset: 0'i64 else: offset
  if startOffset >= size:
    return ("", size)
  var f: File
  if not open(f, path, fmRead):
    return ("", offset)
  defer: f.close()
  f.setFilePos(startOffset)
  let toRead = (size - startOffset).int
  var buf = newString(toRead)
  let bytesRead = f.readBuffer(addr buf[0], toRead)
  buf.setLen(bytesRead)
  (buf, startOffset + bytesRead.int64)

var followInterrupted = false
  ## `followFile`'s Ctrl-C detection flag. The `proc () {.noconv.}` required by
  ## `setControlCHook` can't be a closure (can't capture local variables),
  ## since the `noconv` calling convention has no environment pointer, so this
  ## has to go through a module-level variable instead. `logs -f` runs at most
  ## once per process, so this is fine.

proc followFile(path: string): int =
  ## Remembers the file size, polls every 200ms, and keeps printing the
  ## increment. Exits the loop and returns 130 on Ctrl-C (SIGINT).
  var offset = if fileExists(path): getFileSize(path) else: 0'i64
  followInterrupted = false
  setControlCHook(proc () {.noconv.} = followInterrupted = true)
  while not followInterrupted:
    os.sleep(200)
    let (data, newOffset) = readIncrement(path, offset)
    offset = newOffset
    if data.len > 0:
      stdout.write(data)
      stdout.flushFile()
  130

proc printTailAndMaybeFollow(path: string; n: int; follow: bool): int =
  for line in tailLines(path, n):
    echo line
  if follow:
    followFile(path)
  else:
    ecOk.int

# ---------------------------------------------------------------------------
# Common helper for rendering RPC errors
# ---------------------------------------------------------------------------

proc extractRawStderr(e: ref RpcRemoteError): string =
  ## Extracts ssh's raw stderr from the `data` field, if present. Accepts
  ## either a bare string or a `{"stderr": "..."}` object (since it isn't
  ## strictly settled which form the daemon side will use). Falls back to
  ## `RpcRemoteError.msg` if nothing is found.
  if e.data == nil:
    return e.msg
  case e.data.kind
  of JString: e.data.getStr
  of JObject:
    if e.data.hasKey("stderr") and e.data["stderr"].kind == JString:
      e.data["stderr"].getStr
    else:
      e.msg
  else: e.msg

proc renderRpcErrorBody(w: Writer; e: ref RpcRemoteError; lang: Lang;
    host = ""): string =
  ## `output.renderError` includes a generic headline ("Failed to set up
  ## forwarding to X.") as the first of its three sections, but callers
  ## (`cmdXxx`) already print their own context-specific headline separately
  ## via `output.failure()`. Here we strip the leading headline line and the
  ## blank line right after it from `renderError`'s output, and return only
  ## the cause / remedy / raw-log parts.
  let rawStderr = extractRawStderr(e)
  let kind = classify(rawStderr)
  let ctx = initErrorContext(host = host, rawStderr = rawStderr)
  let full = renderError(w, kind, ctx, lang, rawStderr)
  let lines = full.splitLines()
  if lines.len > 2: lines[2 .. ^1].join("\n") else: full

proc jarr(node: JsonNode; key: string): JsonNode =
  ## Safely extracts `node[key]`. Returns an empty array if the key is absent.
  if node != nil and node.hasKey(key): node[key] else: newJArray()

proc prunableNames*(rows: JsonNode): seq[string] =
  ## Collects only the names that are targets for removal by `prune` from the
  ## result of `tunnel.list` (an array of `JsonNode`).
  ##
  ## "Stopped" is determined via `status == "stopped"`. The daemon has a
  ## contract of returning disabled tunnels as `state: "fwPending"` + `status:
  ## "stopped"` (see `tunnelEntryFromConfig` in `daemon/run.nim`; since this
  ## module doesn't depend on `daemon/`, we look at the contract directly as
  ## JSON string values). Note that `state` cannot be used for this check,
  ## since by design it reuses the live `ForwardState` values directly and has
  ## no dedicated value meaning "disabled".
  result = @[]
  if rows == nil: return
  for row in rows:
    if row.hasKey("status") and row["status"].kind == JString and
        row["status"].getStr == "stopped" and row.hasKey("name"):
      result.add row["name"].getStr

# ---------------------------------------------------------------------------
# run
# ---------------------------------------------------------------------------

proc formatForwardSummary(spec: ForwardSpec): string =
  "-" & $spec.kind & " " & spec.bindAddr & ":" & $spec.bindPort & " -> " &
    spec.targetHost & ":" & $spec.targetPort

proc cmdRun(args: ParsedArgs; w: Writer; lang: Lang): int =
  if args.positional.len == 0:
    stderr.writeLine("powarder run: a host is required")
    return ecUsage.int
  let host = args.positional[0]

  # All `-L` flags are processed before any `-R` flags. argv.parseArgv
  # accumulates `-L` / `-R` into separate seqs, so the actual interleaved
  # order on the input (e.g. `-L a -R b -L c`) is lost (a constraint we can't
  # change, since argv.nim is off-limits here).
  let allSpecs = args.localForwards & args.remoteForwards
  if allSpecs.len == 0:
    stderr.writeLine("powarder run: at least one -L or -R is required")
    return ecUsage.int

  let baseName = if args.name.len > 0: args.name else: randomName()
  ## **Naming rule for multiple forwards**: since the design is one tunnel =
  ## one forward, if there are multiple `-L`/`-R` flags, `tunnel.create` is
  ## called multiple times. The first uses `baseName` as-is; subsequent ones
  ## get a sequence number appended: `"<baseName>-2"`, `"<baseName>-3"`, etc.
  ## (Giving each an independent random name was considered, but being able to
  ## tell at a glance in the `ps` listing that a group of tunnels came from the
  ## same `run` call was judged more practically useful.)

  if not ensureDaemon(args.noAutostart):
    echo w.failure(daemonUnreachableMsg)
    return ecDaemonUnreachable.int

  var exitCode = ecOk.int
  for idx, spec in allSpecs:
    let name = if idx == 0: baseName else: baseName & "-" & $(idx + 1)
    let params = %*{
      "name": name,
      "host": host,
      "type": $spec.kind,
      "forward": formatForwardSpec(spec),
    }
    try:
      let res = call(mTunnelCreate, params)
      let createdName =
        if res != nil and res.hasKey("name"): res["name"].getStr else: name
      echo w.success(
        "tunnel \"" & createdName & "\" started (" &
        formatForwardSummary(spec) & " via " & host & ")")
    except RpcRemoteError as e:
      echo w.failure("tunnel \"" & name & "\" failed to start")
      echo renderRpcErrorBody(w, e, lang, host = host)
      exitCode = exitCodeForRpcError(e.code).int
    except DaemonNotRunningError:
      echo w.failure("tunnel \"" & name & "\" failed to start: daemon is not reachable")
      exitCode = ecDaemonUnreachable.int
  exitCode

# ---------------------------------------------------------------------------
# up / down
# ---------------------------------------------------------------------------

proc cmdUp(args: ParsedArgs; w: Writer; lang: Lang): int =
  if not ensureDaemon(args.noAutostart):
    echo w.failure(daemonUnreachableMsg)
    return ecDaemonUnreachable.int
  let configPath = findConfigFile(args.configPath)
  let params = %*{
    "names": args.positional,
    "profiles": args.profiles,
    "config_path": configPath,
  }
  try:
    let res = call(mTunnelUp, params)
    if w.mode == omJson:
      echo res.pretty()
      return (if jarr(res, "failed").len > 0: ecGeneral.int else: ecOk.int)
    for n in jarr(res, "started"):
      echo w.success("tunnel \"" & n.getStr & "\" started")
    var exitCode = ecOk.int
    for f in jarr(res, "failed"):
      let errMsg = if f.hasKey("error"): f["error"].getStr else: ""
      echo w.failure("tunnel \"" & f["name"].getStr & "\" failed to start: " & errMsg)
      exitCode = ecGeneral.int
    exitCode
  except RpcRemoteError as e:
    echo w.failure("up failed")
    echo renderRpcErrorBody(w, e, lang)
    exitCodeForRpcError(e.code).int
  except DaemonNotRunningError:
    echo w.failure("daemon is not reachable")
    ecDaemonUnreachable.int

proc cmdDown(args: ParsedArgs; w: Writer; lang: Lang): int =
  if not ensureDaemon(args.noAutostart):
    echo w.failure(daemonUnreachableMsg)
    return ecDaemonUnreachable.int
  let params = %*{
    "names": args.positional,
    "profiles": args.profiles,
    "immediate": args.immediate,
  }
  try:
    let res = call(mTunnelDown, params)
    if w.mode == omJson:
      echo res.pretty()
      return ecOk.int
    for n in jarr(res, "stopped"):
      echo w.success("tunnel \"" & n.getStr & "\" stopped")
    ecOk.int
  except RpcRemoteError as e:
    echo w.failure("down failed")
    echo renderRpcErrorBody(w, e, lang)
    exitCodeForRpcError(e.code).int
  except DaemonNotRunningError:
    echo w.failure("daemon is not reachable")
    ecDaemonUnreachable.int

# ---------------------------------------------------------------------------
# start / stop / restart / rm (common RPC-calling pattern)
# ---------------------------------------------------------------------------

proc cmdSimpleNamesAction(args: ParsedArgs; w: Writer; lang: Lang;
    methodName, verb, pastVerb, resultKey: string): int =
  ## The processing common to `start` / `stop` / `restart` / `rm`: call an RPC
  ## once with `{"names": [...]}`, then print each item in the result array on
  ## its own line via `success()`.
  if args.positional.len == 0:
    stderr.writeLine("powarder " & verb & ": at least one tunnel name is required")
    return ecUsage.int
  if not ensureDaemon(args.noAutostart):
    echo w.failure(daemonUnreachableMsg)
    return ecDaemonUnreachable.int
  try:
    let res = call(methodName, %*{"names": args.positional})
    if w.mode == omJson:
      echo res.pretty()
      return ecOk.int
    for n in jarr(res, resultKey):
      echo w.success("tunnel \"" & n.getStr & "\" " & pastVerb)
    ecOk.int
  except RpcRemoteError as e:
    echo w.failure(verb & " failed")
    echo renderRpcErrorBody(w, e, lang, host = args.positional.join(", "))
    exitCodeForRpcError(e.code).int
  except DaemonNotRunningError:
    echo w.failure("daemon is not reachable")
    ecDaemonUnreachable.int

# ---------------------------------------------------------------------------
# ps
# ---------------------------------------------------------------------------

proc cmdPs(args: ParsedArgs; w: Writer; lang: Lang): int =
  if not ensureDaemon(args.noAutostart):
    echo w.failure(daemonUnreachableMsg)
    return ecDaemonUnreachable.int
  try:
    if args.probe:
      # `tunnel.list` itself has no probe parameter. `--probe` (opting into an
      # active Tier2 health check) is implemented by calling `tunnel.check`
      # with probe before fetching the list, which updates the daemon's status
      # as a side effect. The result itself is discarded; this call is purely
      # a trigger.
      discard call(mTunnelCheck, %*{"names": newJArray(), "probe": true})
    let res = call(mTunnelList, %*{"all": args.all})
    if w.mode == omJson:
      echo res.pretty()
    elif args.quietList:
      for row in res:
        echo row["name"].getStr
    else:
      echo renderPsTable(res, w)
    ecOk.int
  except RpcRemoteError as e:
    echo w.failure("ps failed")
    echo renderRpcErrorBody(w, e, lang)
    exitCodeForRpcError(e.code).int
  except DaemonNotRunningError:
    echo w.failure("daemon is not reachable")
    ecDaemonUnreachable.int

# ---------------------------------------------------------------------------
# inspect
# ---------------------------------------------------------------------------

proc cmdInspect(args: ParsedArgs; w: Writer; lang: Lang): int =
  if args.positional.len == 0:
    stderr.writeLine("powarder inspect: at least one tunnel name is required")
    return ecUsage.int
  if not ensureDaemon(args.noAutostart):
    echo w.failure(daemonUnreachableMsg)
    return ecDaemonUnreachable.int
  var exitCode = ecOk.int
  for name in args.positional:
    try:
      let res = call(mTunnelInspect, %*{"name": name})
      if w.mode == omJson:
        echo res.pretty()
      else:
        echo renderInspect(res)
    except RpcRemoteError as e:
      echo w.failure("tunnel \"" & name & "\" inspect failed")
      echo renderRpcErrorBody(w, e, lang, host = name)
      exitCode = exitCodeForRpcError(e.code).int
    except DaemonNotRunningError:
      echo w.failure("daemon is not reachable")
      return ecDaemonUnreachable.int
  exitCode

# ---------------------------------------------------------------------------
# check
# ---------------------------------------------------------------------------

proc cmdCheck(args: ParsedArgs; w: Writer; lang: Lang): int =
  if not ensureDaemon(args.noAutostart):
    echo w.failure(daemonUnreachableMsg)
    return ecDaemonUnreachable.int
  try:
    let res = call(mTunnelCheck, %*{"names": args.positional,
        "probe": args.probe})
    if w.mode == omJson:
      var anyBad = false
      for item in res:
        if not item["ok"].getBool: anyBad = true
      echo res.pretty()
      return (if anyBad: ecGeneral.int else: ecOk.int)
    var exitCode = ecOk.int
    for item in res:
      let name = item["name"].getStr
      let detail =
        if item.hasKey("detail") and item["detail"].kind == JString:
          " (" & item["detail"].getStr & ")"
        else: ""
      if item["ok"].getBool:
        echo w.success("tunnel \"" & name & "\" is healthy" & detail)
      else:
        echo w.failure("tunnel \"" & name & "\" is unhealthy" & detail)
        exitCode = ecGeneral.int
    exitCode
  except RpcRemoteError as e:
    echo w.failure("check failed")
    echo renderRpcErrorBody(w, e, lang)
    exitCodeForRpcError(e.code).int
  except DaemonNotRunningError:
    echo w.failure("daemon is not reachable")
    ecDaemonUnreachable.int

# ---------------------------------------------------------------------------
# hosts
# ---------------------------------------------------------------------------

proc cmdHosts(args: ParsedArgs; w: Writer; lang: Lang): int =
  if not ensureDaemon(args.noAutostart):
    echo w.failure(daemonUnreachableMsg)
    return ecDaemonUnreachable.int
  try:
    let res = call(mHostList)
    if w.mode == omJson:
      echo res.pretty()
    else:
      echo renderHostsTable(res, w)
      for row in res:
        if row.hasKey("last_error") and row["last_error"].kind == JString:
          echo w.warn("host \"" & row["host"].getStr & "\": " & row[
              "last_error"].getStr)
    ecOk.int
  except RpcRemoteError as e:
    echo w.failure("hosts failed")
    echo renderRpcErrorBody(w, e, lang)
    exitCodeForRpcError(e.code).int
  except DaemonNotRunningError:
    echo w.failure("daemon is not reachable")
    ecDaemonUnreachable.int

# ---------------------------------------------------------------------------
# prune
# ---------------------------------------------------------------------------

proc cmdPrune(args: ParsedArgs; w: Writer; lang: Lang): int =
  ## Removes all stopped tunnels in one go.
  ##
  ## **Regardless of whether `-a`/`--all` is given, this always queries
  ## `tunnel.list` with `{"all": true}`.** Since the whole point of `prune` is
  ## "clean up what's stopped", it needs to see every tunnel regardless of
  ## `ps`'s default filter (running only, or also stopped with `-a`).
  if not ensureDaemon(args.noAutostart):
    echo w.failure(daemonUnreachableMsg)
    return ecDaemonUnreachable.int
  try:
    let listRes = call(mTunnelList, %*{"all": true})
    let names = prunableNames(listRes)
    if names.len == 0:
      if w.mode == omJson:
        echo (%*{"removed": newJArray()}).pretty()
      else:
        echo w.info(if lang == langJa: "nothing to prune"
                     else: "nothing to prune")
      return ecOk.int

    discard call(mTunnelRemove, %*{"names": names})
    if w.mode == omJson:
      echo (%*{"removed": names}).pretty()
    else:
      for n in names:
        echo w.success("tunnel \"" & n & "\" removed")
    ecOk.int
  except RpcRemoteError as e:
    echo w.failure("prune failed")
    echo renderRpcErrorBody(w, e, lang)
    exitCodeForRpcError(e.code).int
  except DaemonNotRunningError:
    echo w.failure("daemon is not reachable")
    ecDaemonUnreachable.int

# ---------------------------------------------------------------------------
# logs (IMPORTANT: does not go through the daemon)
# ---------------------------------------------------------------------------

proc cmdLogs(args: ParsedArgs): int =
  ## Logs are actually written **per host** (1 ControlMaster = 1 log file).
  ## Since powarder shares a single master across multiple tunnels pointing at
  ## the same `host`, logs are keyed by master rather than by tunnel, and the
  ## filename includes the host's fingerprint (e.g.
  ## `logs/localhost-5f675d2b.log`). In other words, **the path can't be
  ## determined from the tunnel name alone**, so we query `log_path` via
  ## `tunnel.inspect`.
  ##
  ## **Being able to read logs even when the daemon is dead** is an important
  ## value of this command (the last resort for debugging), so if the query
  ## fails, we point the user at the list of files under `logs/` to read
  ## directly. The log files themselves persist regardless of whether the
  ## daemon is alive.
  if args.positional.len == 0:
    stderr.writeLine("powarder logs: a tunnel name is required")
    return ecUsage.int
  let name = args.positional[0]

  var path = ""
  try:
    let res = call(mTunnelInspect, %*{"name": name})
    path = res{"log_path"}.getStr("")
  except DaemonNotRunningError:
    let dir = logsDir()
    # Build the concatenation one `add` at a time. A multi-line `&` chain can
    # get squeezed by nimpretty's formatting into something like
    # `name &"..."`, where `&"..."` then gets parsed as strformat
    # interpolation and fails to compile (hit this in practice).
    var msg = "powarder: cannot determine the log file for \""
    msg.add name
    msg.add "\" because the daemon is not running"
    msg.add " (logs are keyed by ControlMaster, and the filename includes the host's fingerprint)."
    stderr.writeLine(msg)
    var found = false
    if dirExists(dir):
      for f in walkFiles(dir / "*.log"):
        if not found:
          stderr.writeLine("powarder: read one of the following files directly:")
          found = true
        stderr.writeLine("  " & f)
    if not found:
      stderr.writeLine("powarder: no logs yet: " & dir)
    return ecDaemonUnreachable.int
  except RpcRemoteError as e:
    stderr.writeLine("powarder: " & e.msg)
    return exitCodeForRpcError(e.code).int

  if path.len == 0 or not fileExists(path):
    echo "no logs yet for \"" & name & "\""
    return ecOk.int
  printTailAndMaybeFollow(path, args.tailLines, args.follow)

# ---------------------------------------------------------------------------
# daemon
# ---------------------------------------------------------------------------

proc cmdDaemonStatus(w: Writer): int =
  try:
    let res = call(mDaemonInfo)
    if w.mode == omJson:
      echo res.pretty()
    else:
      echo "pid: ", res["pid"].getBiggestInt
      echo "version: ", res["version"].getStr
      echo "socket: ", res["socket"].getStr
      echo "uptime: ", formatDuration(initDuration(seconds = res[
          "uptime_seconds"].getBiggestInt))
      echo "started_at: ", res["started_at"].getStr
      echo "hosts: ", res["hosts"].getBiggestInt
      echo "forwards: ", res["forwards"].getBiggestInt
      echo "config: ", res["config_path"].getStr
    ecOk.int
  except DaemonNotRunningError:
    echo "daemon is not running"
    ecDaemonUnreachable.int

proc cmdDaemonStart(w: Writer): int =
  if ping():
    let pid = readPid(lockPath())
    echo w.info("daemon is already running" &
      (if pid.isSome: " (pid=" & $pid.get & ")" else: ""))
    return ecOk.int
  if ensureDaemon(noAutostart = false):
    let pid = readPid(lockPath())
    echo w.success("daemon started" &
      (if pid.isSome: " (pid=" & $pid.get & ")" else: ""))
    ecOk.int
  else:
    echo w.failure("failed to start the daemon")
    ecDaemonUnreachable.int

proc cmdDaemonStop(w: Writer): int =
  try:
    discard call(mDaemonShutdown)
    echo w.success("daemon stopped")
    ecOk.int
  except DaemonNotRunningError:
    echo w.info("daemon is already stopped")
    ecDaemonUnreachable.int

proc cmdDaemonRestart(w: Writer): int =
  try:
    discard call(mDaemonShutdown)
  except DaemonNotRunningError:
    discard # If it was already stopped, just go ahead and try to start it

  # Even after the shutdown response comes back, the actual process exit might
  # be asynchronous, so wait briefly until ping actually stops succeeding
  # before trying to start it.
  var waited = 0
  while ping() and waited < 5000:
    os.sleep(100)
    waited += 100

  if ensureDaemon(noAutostart = false):
    let pid = readPid(lockPath())
    echo w.success("daemon restarted" &
      (if pid.isSome: " (pid=" & $pid.get & ")" else: ""))
    ecOk.int
  else:
    echo w.failure("failed to restart the daemon")
    ecDaemonUnreachable.int

proc cmdDaemonReload(w: Writer; lang: Lang): int =
  try:
    let res = call(mDaemonReload)
    if w.mode == omJson:
      echo res.pretty()
      return ecOk.int
    for action in jarr(res, "actions"):
      echo w.info("- " & action["action"].getStr & " " & action[
          "target"].getStr)
    for warning in jarr(res, "warnings"):
      echo w.warn(warning.getStr)
    echo w.success("reloaded (" & $res["tunnels"].getBiggestInt & " tunnels)")
    ecOk.int
  except RpcRemoteError as e:
    echo w.failure("reload failed")
    echo renderRpcErrorBody(w, e, lang)
    exitCodeForRpcError(e.code).int
  except DaemonNotRunningError:
    echo w.failure("daemon is not reachable")
    ecDaemonUnreachable.int

proc cmdDaemonLogs(args: ParsedArgs): int =
  ## Tails the daemon's own log (`paths.daemonLogPath()`). Reuses the same
  ## approach as the tunnel `logs` command (reading the file directly, without
  ## going through IPC).
  let path = daemonLogPath()
  if not fileExists(path):
    echo "no logs yet"
    return ecOk.int
  printTailAndMaybeFollow(path, args.tailLines, args.follow)

proc statusLabel(status: ServiceStatus): string =
  case status
  of ssNotInstalled: "not installed"
  of ssInstalled: "installed (not running)"
  of ssRunning: "running"
  of ssUnknown: "unknown"

proc serviceInfoJson(info: ServiceInfo): JsonNode =
  %*{
    "label": info.label,
    "unit_path": info.unitPath,
    "status": $info.status,
    "notes": info.notes,
  }

proc cmdDaemonInstall(args: ParsedArgs; w: Writer): int =
  ## Registers the daemon as a persistent OS service (a macOS launchd
  ## LaunchAgent / a Linux systemd `--user` unit).
  ##
  ## `getAppFilename()` can return a relative path like `./powarder` right
  ## after `nimble build`, but service registration needs an absolute path
  ## (launchd/systemd don't inherit the current directory), so we make it
  ## absolute with `expandFilename()`.
  let exe = expandFilename(getAppFilename())
  try:
    let info = installService(exe, args.configPath)
    if w.mode == omJson:
      echo serviceInfoJson(info).pretty()
    else:
      echo w.success("installed \"" & info.label & "\" -> " & info.unitPath &
          " (" & statusLabel(info.status) & ")")
      for n in info.notes:
        echo w.info(n)
    ecOk.int
  except OSError as e:
    echo w.failure(e.msg)
    ecGeneral.int

proc cmdDaemonUninstall(w: Writer): int =
  try:
    let info = uninstallService()
    if w.mode == omJson:
      echo serviceInfoJson(info).pretty()
    else:
      echo w.success("uninstalled \"" & info.label & "\"")
      for n in info.notes:
        echo w.info(n)
    ecOk.int
  except OSError as e:
    echo w.failure(e.msg)
    ecGeneral.int

proc cmdDaemon(args: ParsedArgs; w: Writer; lang: Lang;
    runDaemon: DaemonRunner): int =
  case args.subsubcommand
  of "", "--foreground":
    # `argv.nim` doesn't have a `--foreground` flag at all, so in practice the
    # only way to reach here is `subsubcommand == ""` (running `powarder
    # daemon` with no subsubcommand). The `"--foreground"` branch is kept
    # around in case that flag gets added to argv.nim in the future, or for
    # tests that build a `ParsedArgs` by hand and call this directly
    # (`autostart.ensureDaemon` takes this path by passing just `["daemon"]`;
    # see `cli/autostart.nim`).
    if runDaemon == nil:
      echo w.failure("the daemon is not built into this binary")
      return ecGeneral.int
    runDaemon()
  of "status": cmdDaemonStatus(w)
  of "start": cmdDaemonStart(w)
  of "stop": cmdDaemonStop(w)
  of "restart": cmdDaemonRestart(w)
  of "reload": cmdDaemonReload(w, lang)
  of "logs": cmdDaemonLogs(args)
  of "install": cmdDaemonInstall(args, w)
  of "uninstall": cmdDaemonUninstall(w)
  else:
    echo w.failure("unknown daemon subcommand: " & args.subsubcommand)
    ecUsage.int

# ---------------------------------------------------------------------------
# completion
# ---------------------------------------------------------------------------

proc cmdCompletion(args: ParsedArgs): int =
  if args.subsubcommand.len == 0:
    stderr.writeLine("powarder completion: a shell name is required (zsh|bash|fish)")
    return ecUsage.int
  try:
    echo completionScript(args.subsubcommand)
    ecOk.int
  except ValueError as e:
    stderr.writeLine("powarder completion: " & e.msg)
    ecUsage.int

# ---------------------------------------------------------------------------
# dispatch*
# ---------------------------------------------------------------------------

proc dispatch*(args: ParsedArgs; runDaemon: DaemonRunner = nil): int =
  ## Runs the subcommand and returns the exit code. Writing to stdout happens
  ## here (and in the `cmdXxx` functions called from here).
  if args.versionRequested:
    echo "powarder ", cliVersion
    return ecOk.int
  if args.helpRequested:
    echo usage(args.subcommand)
    return ecOk.int

  let w = newWriter(json = args.json, noColor = args.noColor,
      quiet = args.quiet)
  let lang = detectLang()

  case args.subcommand
  of "run": cmdRun(args, w, lang)
  of "up": cmdUp(args, w, lang)
  of "down": cmdDown(args, w, lang)
  of "start":
    cmdSimpleNamesAction(args, w, lang, mTunnelStart, "start", "started", "started")
  of "stop":
    cmdSimpleNamesAction(args, w, lang, mTunnelStop, "stop", "stopped", "stopped")
  of "restart":
    cmdSimpleNamesAction(args, w, lang, mTunnelRestart, "restart", "restarted", "restarted")
  of "rm":
    cmdSimpleNamesAction(args, w, lang, mTunnelRemove, "remove", "removed", "removed")
  of "ps": cmdPs(args, w, lang)
  of "inspect": cmdInspect(args, w, lang)
  of "check": cmdCheck(args, w, lang)
  of "hosts": cmdHosts(args, w, lang)
  of "logs": cmdLogs(args)
  of "daemon": cmdDaemon(args, w, lang, runDaemon)
  of "completion": cmdCompletion(args)
  of "prune": cmdPrune(args, w, lang)
  of "":
    echo usage()
    ecUsage.int
  else:
    stderr.writeLine("powarder: unknown command \"" & args.subcommand & "\"")
    ecUsage.int
