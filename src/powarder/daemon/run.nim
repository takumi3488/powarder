## powarder デーモン本体。M1〜M4 で作られた各モジュール（registry / reconcile /
## hostsession / forward / ipc）を配線し、RPC ハンドラを提供する。
##
## ★最重要の制約: **`platform/daemonize.daemonize()` を呼んではいけない。**
## `runDaemon()` はフォアグラウンドで動作する設計にする。
##
## 理由（macOS で実測判明。`tests/tipc.nim` のモジュール doc comment も参照）:
## asyncdispatch（`newAsyncSocket` を1回でも呼ぶとグローバル kqueue fd が
## プロセス内に初期化される）に一度でも触れた**後**に `fork()` すると、子が
## 継承した kqueue fd が壊れて、子プロセス内での `accept()` が
## "Bad file descriptor" で失敗するようになる。デーモンは起動直後から
## `newIpcServer`（内部で `newAsyncSocket`）を使うため、もし `runDaemon` 自身が
## 「まず asyncdispatch を使い始めてから、バックグラウンド化のために
## `fork()`（daemonize）する」という順序を踏むと、この壊れた kqueue を抱えた
## まま起動してしまう。
##
## そのため、デーモンのバックグラウンド化は **CLI 側**が
## `platform/daemonize.spawnDetached()`（`execvp` で別の実行ファイルに置き換わる
## ため、既存プロセスが asyncdispatch に触れていても影響を受けない）で行う設計に
## なっている。このモジュールは、その `spawnDetached()` から（あるいは手動で）
## 起動された「今のプロセスそのもの」がフォアグラウンドのまま動き続ける
## `runDaemon()` だけを提供する。

import std/[asyncdispatch, os, posix, times, monotimes, json, options, tables, strutils]
import std/nativesockets ## `Port` の `$` / `==` を使うために必要
                          ## （`core/types.nim` は `export Port` で型のみ
                          ## 再輸出しているため。他モジュールと同じ理由）。
import std/deques ## `ForwardStats.recentSources`（`Deque[SourceEntry]`）を
                   ## `for` で回すために必要（`proxy/stats.nim` は型のみ export
                   ## するため、`items` イテレータを使うにはここでの import が要る）。

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
# 定数
# ---------------------------------------------------------------------------

const
  daemonVersion* = powarderVersion
  exitAlreadyRunning* = 7
    ## 多重起動時（ロックが既に他プロセスに保持されている）の終了コード。
    ## CLI 側の「デーモンに到達できない」系の終了コードと合わせてある。
  defaultTickIntervalMs = 500
  defaultStateSaveIntervalMs = 5000
  logRotateIntervalMs = 60_000
    ## ログローテーションのチェック間隔（M6）。毎 tick（500ms）ごとに全ログ
    ## ファイルの `getFileSize` を呼ぶのは無駄なので、60秒に間引く
    ## （`config/statefile` の状態保存の間引きと同じ考え方）。
  isoFormat = "yyyy-MM-dd'T'HH:mm:sszzz"
    ## `config/statefile.nim` の `savedAtFormat` と同じ書式（ISO8601 相当）。

# ---------------------------------------------------------------------------
# 型
# ---------------------------------------------------------------------------

type
  DaemonOpts* = object
    configPath*: string  ## 空なら configfile.findConfigFile()
    socketPath*: string  ## 空なら paths.ipcSocketPath()
    activeProfiles*: seq[string]
    tickIntervalMs*: int ## 既定 500
    stateSaveIntervalMs*: int ## 既定 5000（毎 tick 保存すると I/O が無駄）

  Daemon* = ref object
    opts*: DaemonOpts
    reg*: Registry
    server*: IpcServer
    lock*: SingletonLock
    config*: ConfigFile
    startedAt*: MonoTime
    startedAtWall*: times.Time ## `std/posix` も `Time` を export するため修飾する
    shuttingDown*: bool
    reloadRequested*: bool
    lastStateSaveAt: MonoTime
      ## 内部専用（テストからは触らない）。前回 `persistState` した時刻。
    lastPersistedJson: string
      ## 内部専用。前回保存した `PersistedState` の JSON 表現。
      ##
      ## **「reconcile が行動したら保存」では不十分**なので内容比較で判定する。
      ## reconcile がホストを作った直後はまだ `spawnMaster` が走っていないため
      ## `pid = 0` / `argv = @[]` であり、その状態を保存してしまうと
      ## **adopt に必要な情報が欠けた記録**が残る（実際にこれで adopt が
      ## `aoMismatch` になった）。pid が埋まるのは次の tick の `tickAll` の中だが、
      ## そのとき reconcile は差分ゼロなので「行動あり」では検出できない。
      ## 前回保存内容と実際に比べれば、pid や状態が変わった瞬間を取りこぼさない。
    lastLogRotateAt: MonoTime
      ## 内部専用（M6）。前回 `logstore.rotateAll` を呼んだ時刻。
    adhocTunnels: Table[string, TunnelConfig]
      ## 内部専用。`tunnel.create` で作られた、設定ファイルには存在しない
      ## ad-hoc なトンネル定義。`desiredState()` は `config.tunnels` と
      ## これを合わせたものを望ましい状態として `reconcile` に渡す。

# ---------------------------------------------------------------------------
# シグナル
# ---------------------------------------------------------------------------
#
# `posix.onSignal` が生成するハンドラは素の signal handler（async-signal-safe
# である必要がある）なので、ここでは bool フラグを立てるだけに留める。実際の
# 後始末は 500ms のメインループがフラグを見て行う（self-pipe trick は不要）。
# シングルトンロックによりプロセス内でデーモンは1つしか動かない前提なので、
# モジュールレベルのグローバル変数で十分。

var
  signalShutdownRequested = false
  signalReloadRequested = false

proc installSignalHandlers() =
  ## `SIGTERM` / `SIGINT` → shutdown、`SIGHUP` → reload。
  onSignal(SIGTERM, SIGINT):
    signalShutdownRequested = true
  onSignal(SIGHUP):
    signalReloadRequested = true

# ---------------------------------------------------------------------------
# 小さなヘルパー
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
# 望ましい状態 / 既知のトンネル
# ---------------------------------------------------------------------------

proc desiredState(d: Daemon): DesiredState =
  ## `config.tunnels` と ad-hoc トンネル（`tunnel.create`）を合わせたものを
  ## reconcile に渡す望ましい状態にする。
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
  ## `tunnel.up` が `config_path` で明示的に指定された別ファイルのトンネル定義を
  ## 取り込むときに使う（同名は上書き）。
  for i in 0 ..< d.config.tunnels.len:
    if d.config.tunnels[i].name == tc.name:
      d.config.tunnels[i] = tc
      return
  d.config.tunnels.add tc

# ---------------------------------------------------------------------------
# 状態の永続化
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
  ## 保存はあくまでクラッシュ後の adopt（M6）を効率化するためのヒントに過ぎない
  ## （`statefile.loadState` 自身が壊れたファイルを無視する設計）ので、保存に
  ## 失敗してもデーモンは継続する。
  try:
    ensureStateDirs()
    saveState(stateFile(), buildPersistedState(d))
  except CatchableError:
    discard

# ---------------------------------------------------------------------------
# 孤児マスターの adopt（M6）
# ---------------------------------------------------------------------------

proc logAdoptReport(report: AdoptReport) =
  ## `adoptOrphans` の結果を起動時ログに出す。
  ##
  ## **長い文字列は `&` を複数行にまたがず `msg.add` で組む。** nimpretty が
  ## 行末の `&` を詰めて次行の `"..."` と地続きにすると、`&"..."` が
  ## `strformat` の補間と解釈されてコンパイルエラーになることが実際にあった
  ## （プロジェクトの申し送り事項）。
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

  var msg = "powarder: 孤児マスターの adopt: "
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
  ## 設定を再読込して reconcile する。`daemon.reload` ハンドラと、
  ## `SIGHUP` 経由の `reloadRequested` フラグの両方から呼ばれる。
  ##
  ## 読み込みに失敗した場合は直前の設定を維持したまま warning だけ追加する
  ## （`newDaemon` の起動時と同じ「設定ミスでデーモンが死なない」方針）。
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
    let msg = "warning: 設定の再読込に失敗しました。直前の設定を維持します: " & e.msg
    stderr.writeLine("powarder: " & msg)
    warnings.add msg

  # **`(host, extraArgs)` → fingerprint のキャッシュを破棄する。**
  # reload は「設定を読み直す」操作なので、`~/.ssh/config` の再評価もここで行う。
  # これを呼ばないと「ssh_config を直して reload しても反映されない」という
  # 分かりにくい挙動になる。既存の HostSession / Forward は破棄されず、
  # fingerprint が変わったホストだけが Add/Remove の一般ロジックで入れ替わる。
  d.reg.clearHostKeyCache()

  result = reconcile(d.desiredState(), d.reg)
  for w in warnings:
    result.warnings.insert(w, 0)

# ---------------------------------------------------------------------------
# tunnel.list / tunnel.inspect 用の JSON 組み立て
# ---------------------------------------------------------------------------

proc forwardUptimeSeconds(fw: Forward): JsonNode =
  ## `fkLocal`: リスナー（`proxy.stats`）が最初に起動した時刻から。
  ## `fkRemote`（や、まだプロキシが無い `fkLocal`）: 所属マスターが最後に
  ## 接続確立した時刻を代わりに使う（fkRemote は powarder 自身の
  ## 「いつから active か」の記録を持たないための近似）。
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
    # ★ -R は統計が原理的に取れない（プロキシを挟めないため）ので、この分岐に
    # 入らず下の else で4項目すべて null になる。CLI 側はそれを見て "-" と表示する。
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
  ## live な `Forward` が registry に無いトンネル（無効化されている、または
  ## enable されたばかりで reconcile がまだ追いついていない）の表示用エントリ。
  ##
  ## **`state` には常に本物の `ForwardState` の文字列だけを入れる**
  ## （CLI 側が `state` を enum としてパースしても壊れないようにするため）。
  ##「無効化されている」という情報は自由記述の `status`（"stopped"）側で表現する。
  ## `ForwardState` に「無効化済み」を表す値が無いのが本質的な理由なので、
  ## `core/types.ForwardState` へ専用の値を足すことを報告で提案する。
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
# RPC ハンドラ
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
  ## フラグを立てるだけ。実際の graceful shutdown はメインループが抜けた後、
  ## `runDaemon` が行う。
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
      # enabled になった直後で reconcile がまだ Forward を作っていない一瞬の状態。
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
    # `up` は「このセッションで有効にするプロファイル集合」を確定させる操作
    # （docker compose の `--profile` と同じ発想）なので、以後の reconcile
    # （メインループやこの後の `reconcile` 呼び出し）にも効くよう永続化する。
    d.opts.activeProfiles = getStrArray(params, "profiles")

  let configPathOverride = getStrParam(params, "config_path")
  if configPathOverride.len > 0:
    try:
      let loaded = loadConfig(configPathOverride)
      for tc in loaded.tunnels:
        d.upsertConfigTunnel(tc)
    except ConfigError as e:
      raise newRpcError(errConfigInvalid,
          "config_path の読み込みに失敗しました: " & e.msg)

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
    # 参照が無くなったホストの idle grace period（既定25秒）を待たず、今すぐ
    # マスターを畳む。他の `down` 対象外のホストで既に refCount == 0 のものにも
    # 一律に効くが、そのようなホストはどのみち自然に停止する定めなので実害は無い。
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
        requestDetach(fw) ## 次の reconcile で除去 -> 作り直しのサイクルに乗る
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
    var detail = "登録されていません"
    if fws.len > 0:
      let fw = fws[0]
      ok = fw.state == fwActive
      detail =
        if ok: fw.spec.bindAddr & ":" & $fw.spec.bindPort & " で接続を受け付けています"
        elif fw.lastError.len > 0: fw.lastError
        else: describeState(fw)

      # probe=true のときだけ Tier2 の実プローブを行う（既定では行わない。
      # `proxy/upstream.probeUpstream` の doc comment の通り、OpenSSH の
      # `channel_post_port_listener` が accept 直後に宛先へ実接続してしまうため）。
      # `fkRemote` は powarder がデータパスに介在しないためプローブできない。
      if probe and ok and fw.spec.kind == fkLocal:
        let probeFut = probeUpstream(fw.upstream)
        # RpcHandler は同期 proc なので、ここだけは `waitFor` で同期・非同期の
        # 境界を跨ぐ（`tick()` 系とは異なり、これは async ループの実行中に別の
        # Future の完了を待つ「ネストした waitFor」ではなく、単発の同期呼び出しから
        # 一度だけ async 処理へ橋渡しする使い方）。無応答で無限に止まらないよう
        # `withTimeout` で上限を設ける。
        let completed =
          try: waitFor(withTimeout(probeFut, 3000))
          except CatchableError: false
        let reachable = completed and (try: probeFut.read() except CatchableError: false)
        ok = reachable
        if not reachable:
          detail = "Tier2 プローブに失敗しました（宛先に到達できません）"
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
# 構築
# ---------------------------------------------------------------------------

proc newDaemon*(opts: DaemonOpts): Daemon =
  ## 起動シーケンスのうち**ロック取得を除く**全て（設定読み込み・状態読み込み・
  ## registry 生成・IPC サーバ生成・ハンドラ登録）を行う。
  ##
  ## **ロックはここでは取得しない。** `runDaemon` は「ロックが取れなければ
  ## `Daemon` を構築すること自体を諦めて終了コード7で抜ける」という分岐が
  ## 必要（`newIpcServer` や `ensureRuntimeDir` などは無関係に、多重起動を
  ## 検出したら即座に何も作らず抜けたい）ため、ロック取得の責務は `runDaemon`
  ## 側に置く。テストから `newDaemon` を単体で呼ぶ場合、`result.lock` は
  ## 未取得のダミー値（`fd: -1`）になる（`shutdown` はこれを見て何もしない）。
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
    # 設定ミスでデーモンが上がらないより、空設定で上がって `ps` 等で状況が
    # 見える方が良い、という方針（`config/statefile.loadState` と同じ発想）。
    stderr.writeLine("powarder: warning: 設定ファイルの読み込みに失敗しました。空の設定で起動します: " & e.msg)
    cfg = defaultConfig()

  let persisted = loadState(stateFile())
  let reg = newRegistry()
  # 孤児マスター/forward の adopt（M6）。`newIpcServer`（asyncdispatch）より
  # 前でも後でも問題は無い（`runDaemon` は fork() を一切しない設計なので、
  # asyncdispatch に触れた後に fork するケースの kqueue 破損は起こらない。
  # `daemon/run.nim` モジュール doc comment の「★最重要の制約」を参照）が、
  # 「前回の記録を読み込んだ直後」という意味的な位置としてここに置く。
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
# メインループ
# ---------------------------------------------------------------------------

proc syncSignalFlags(d: Daemon) =
  ## シグナルハンドラがセットしたグローバルフラグを `Daemon` へ反映する。
  if signalShutdownRequested:
    d.shuttingDown = true
  if signalReloadRequested:
    signalReloadRequested = false
    d.reloadRequested = true

proc tickOnce*(d: Daemon): Future[ReconcileReport] {.async.} =
  ## メインループの1イテレーション分だけを進める公開 proc。
  ##
  ## テスタビリティのために `mainLoop`（`await sleepAsync` を含む無限ループ）
  ## から本体を切り出した。テストはこれを直接・繰り返し呼ぶことで
  ## 「デーモンのループを実際に回さずに、進行だけを数回分再現する」ことができる。
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

  # 状態の永続化。`state.json` は **クラッシュ後に孤児マスターを adopt する
  # ための唯一の手がかり**（`-O` には「現在張られている forward の一覧」を
  # 返すサブコマンドが無いため）なので、記録が残る前にクラッシュすると
  # adopt できず、生きている孤児マスターを見逃してしまう。
  #
  # **「reconcile が行動したら保存」では取りこぼす。** reconcile がホストを
  # 作った直後はまだ `spawnMaster` が走っておらず `pid = 0` / `argv = @[]` で、
  # その欠けた記録を保存してしまう。pid が埋まるのは次の tick の `tickAll` の
  # 中だが、そのとき reconcile は差分ゼロなので行動として現れない。
  # 実際にこれで adopt が `aoMismatch` になった（pid=0 のプロセスは存在しない）。
  #
  # よって**前回保存した内容と実際に比較して、変わっていれば保存する**。
  # 変化が無い tick では書かないので I/O は増えない。定期保存も保険として残す。
  let snapshot = buildPersistedState(d)
  let snapshotJson = $(%snapshot) ## savedAt は buildPersistedState が "" にするので比較に影響しない
  if snapshotJson != d.lastPersistedJson or
      secondsSince(d.lastStateSaveAt) * 1000 >= d.opts.stateSaveIntervalMs:
    d.persistState()
    d.lastPersistedJson = snapshotJson
    d.lastStateSaveAt = getMonoTime()

  # ログローテーション（M6）。毎 tick（既定 500ms）ごとに全ログファイルの
  # `getFileSize` を呼ぶのは無駄なので、`logRotateIntervalMs`（60秒）に
  # 間引く（`lastStateSaveAt` と同じ間引きパターン）。
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
# 終了
# ---------------------------------------------------------------------------

proc shutdown*(d: Daemon) =
  ## graceful shutdown。
  ##
  ## **async ループが完全に停止した後に呼ぶこと。** `reg.teardownAll()` は
  ## 内部で `waitFor` を使う（`forward.teardown` / `hostsession.teardown` の
  ## doc comment を参照）ため、`tick` が回っている最中（async ループの実行中）
  ## に呼ぶとイベントループ内で `waitFor` がネストしてしまう。
  ##
  ## 手順: 1. IPC サーバを閉じる（accept を止める）→ 2. `teardownAll`
  ## （Forward を先に、HostSession を後に片付ける） → 3. 最終状態の保存 →
  ## 4. ロック解放（ロックファイル自体の削除も行う。`server.close()` が
  ## ソケットファイルの削除まで面倒を見てくれるのと対にしている）。
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
# 公開エントリポイント
# ---------------------------------------------------------------------------

proc runDaemon*(opts = DaemonOpts()): int =
  ## フォアグラウンドで動く。終了コードを返す。**`daemonize()` は絶対に
  ## 呼ばない**（モジュール doc comment の「★最重要の制約」を参照）。
  ##
  ## 起動シーケンス（順序が重要）:
  ## 1. `ensureRuntimeDir` / `ensureStateDirs`
  ## 2. シングルトンロックの取得。取れなければ終了コード `exitAlreadyRunning`(7)。
  ##    取れたら `writePid`。**`writePid` は取得済みの fd をそのまま使う実装**
  ##    （`platform/lock.nim` の doc comment 参照: POSIX の fcntl ロックは
  ##    (プロセス, inode) 単位なので、同じファイルを別 fd で開き直して close
  ##    すると、そのプロセスが持つ当該ファイルへの全ロックが解放されてしまう。
  ##    そのため `writePid` はロック取得に使った fd を再利用する設計になっている
  ##    ―― ここで新たに `open()` し直してはいけない）。
  ## 3〜6. `newDaemon`（設定 / 状態 / registry / IPC サーバ）
  ## 7. シグナルハンドラ登録
  ## 8. メインループを async で回す
  ensureRuntimeDir()
  ensureStateDirs()

  let lockFilePath = lockPath()
  let gotLock = tryAcquireSingletonLock(lockFilePath)
  if gotLock.isNone:
    stderr.writeLine("powarder: すでにデーモンが起動しています（ロック: " &
        lockFilePath & "）")
    return exitAlreadyRunning

  let acquiredLock = gotLock.get
  acquiredLock.writePid(getCurrentProcessId())

  var d: Daemon = nil
  try:
    d = newDaemon(opts)
    d.lock = acquiredLock

    installSignalHandlers()

    # `serve()` の accept ループと `mainLoop()` を同時に走らせる必要がある。
    #
    # **選択**: `asyncCheck serve(d.server)` で accept ループをバックグラウンド
    # タスクとして登録してから `waitFor mainLoop(d)` する形にした。
    # 理由: asyncdispatch はシングルスレッドの協調的ディスパッチャ1つを
    # プロセス全体で共有するので、`serve()` が await で止まっている間も、
    # 同じディスパッチャ上で動く `mainLoop` 側の `sleepAsync` の完了や、IPC
    # クライアントからの新規接続はどちらも通常どおり処理される（Future 同士を
    # 手で組み合わせる `waitFor(a and b)` のような形は、`std/asyncdispatch` に
    # 標準の `and` 演算子が無く、`serve()` がそもそも `close()` されるまで
    # 完了しない Future であるため「両方が終わるのを待つ」という組み合わせ方
    # 自体がこの用途に合わない）。`serve()` が `close()` 経由の正常終了以外の
    # 理由で失敗したときは `asyncCheck` の仕組みにより次の `poll()`（＝
    # `waitFor mainLoop(d)` の内部ループ）で例外が再送出され、デーモンは
    # `mainLoop` ごと異常終了する。これは「IPC 層が壊れた」ことを示す状況で
    # あり、揉み消さずに気付けるようにするための意図的な挙動。
    asyncCheck serve(d.server)
    waitFor mainLoop(d)
  finally:
    if d != nil:
      shutdown(d)
    else:
      # `newDaemon` 自体が例外を投げた場合でも、取得済みのロックは必ず解放する。
      acquiredLock.release()
      removeFile(lockFilePath)

  0
