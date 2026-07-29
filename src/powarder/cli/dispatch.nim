## `powarder` CLI 本体: サブコマンドをデーモンへの RPC / ファイル読み込みに配線し、
## 標準出力への書き込みと終了コードの決定を行う。
##
## テストしやすさのため、「文字列を組み立てる関数」（`renderPsTable` /
## `renderHostsTable` / `tailLines` / `readIncrement` 等、すべて `*` で公開）と
## 「実際に `echo` して RPC を呼ぶ関数」（`cmdXxx` 群、`dispatch*` から呼ばれる）を
## 分離してある。前者は純粋関数としてデーモン無しでテストできる。
##
## デーモン本体（`daemon/run.nim`）へは依存しない。`daemon --foreground` の実行は
## `DaemonRunner` 型の関数を `dispatch*` の引数として受け取ることで注入する
## （呼び出し元の `src/powarder.nim` が実体を渡す）。

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
import std/nativesockets ## `Port` の `$` を使うために必要（core/types は型のみ export する）

type
  ExitCode* = enum
    ecOk = 0, ecGeneral = 1, ecUsage = 2, ecConfig = 3, ecNotFound = 4,
    ecConflict = 5, ecSshFailed = 6, ecDaemonUnreachable = 7

  DaemonRunner* = proc (): int {.closure.}
    ## `powarder daemon`（サブサブコマンド無し = フォアグラウンド起動）のときに
    ## デーモン本体を起動する関数。`src/powarder.nim` から注入される
    ## （`daemon/run.nim` への直接依存を避けるための依存性注入）。
    ## `nil` の場合は「デーモン本体が組み込まれていません」と表示して
    ## `ecGeneral` を返す。

const
  cliVersion* = powarderVersion
    ## `src/powarder.nim` の `powarderVersion` は import すると循環参照になる
    ## （`powarder.nim` が最終的に `cli/dispatch` を import する構成のため）ため、
    ## ここに独立した定数として持つ。`src/powarder.nim` 側で両者を同じ値に
    ## 保つ責務を負う（このモジュールの担当エージェントが `powarder.nim` を
    ## 変更できないため）。

  daemonUnreachableMsg =
    "could not reach the powarder daemon " &
    "(try 'powarder daemon start', or drop --no-autostart)"

  # `tunnel.start` / `tunnel.stop` は `protocol.nim` の `mTunnelStart` /
  # `mTunnelStop` を使う（デーモン側と同じ定数を参照することで、
  # 片方だけ文字列を変えても気付けないという事故を防ぐ）。

# ---------------------------------------------------------------------------
# RpcRemoteError.code -> 終了コードのマッピング（唯一の箇所）
# ---------------------------------------------------------------------------

proc exitCodeForRpcError*(code: int): ExitCode =
  ## `RpcRemoteError.code` から CLI の終了コードへのマッピングテーブル。
  ## デーモンから返るエラーコードの定義自体は `ipc/protocol` を参照。
  ##
  ## `DaemonNotRunningError` はこのテーブルの対象外（`RpcRemoteError` ではない
  ## 別の例外型）。呼び出し側は捕まえたら常に `ecDaemonUnreachable`（7）にする。
  case code
  of errTunnelNotFound: ecNotFound
  of errTunnelNameConflict: ecConflict
  of errSshFailed: ecSshFailed
  of errConfigInvalid: ecConfig
  else: ecGeneral

# ---------------------------------------------------------------------------
# テーブル整形（純粋関数。デーモン無しでテスト可能）
# ---------------------------------------------------------------------------

const
  psHeader = @["NAME", "TYPE", "BIND", "TARGET", "HOST", "CONNS", "RX/TX",
               "LAST", "UPTIME", "STATUS"]
  hostsHeader = @["HOST", "STATE", "TUNNELS", "PID", "UPTIME", "RETRIES"]

proc renderPsTable*(rows: JsonNode; w: Writer): string =
  ## `tunnel.list` の結果（JsonNode の配列）をテーブル文字列に整形する。
  ##
  ## `-R` のフォワードは統計（`conns` / `total_conns` / `rx` / `tx` /
  ## `last_activity_seconds`）が原理的に取れず、デーモンは常に `null` を返す
  ## （M5 の RPC スキーマの契約）。ここではそれを見て該当列を `"-"` にする。
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
  ## `host.list` の結果をテーブル文字列に整形する。
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
  ## `tunnel.inspect` の結果を `key: value` の羅列に整形する。
  ## ネストしたオブジェクト・配列は `pretty()` してインデントして埋め込む。
  var lines: seq[string] = @[]
  for k, v in node.pairs:
    case v.kind
    of JString: lines.add(k & ": " & v.getStr)
    of JNull: lines.add(k & ": -")
    of JObject, JArray: lines.add(k & ":\n" & indent(v.pretty(), 2))
    else: lines.add(k & ": " & $v)
  lines.join("\n")

# ---------------------------------------------------------------------------
# ログの tail（純粋関数。デーモン無しでテスト可能）
# ---------------------------------------------------------------------------

proc tailLines*(path: string; n: int): seq[string] =
  ## ファイル全体を読んで末尾 `n` 行を返す。ファイルが無ければ空 seq。
  ## powarder のトンネルログはトンネルごとに分かれ既定でさほど大きくならない
  ## ため、末尾からシークして読む最適化はせず素直に全読みする。
  if not fileExists(path):
    return @[]
  var lines = readFile(path).splitLines()
  # `splitLines` は末尾に改行がある入力だと最後に空文字列の要素を1つ足す。
  # 表示上はノイズなので、末尾が空文字列なら取り除く。
  if lines.len > 0 and lines[^1].len == 0:
    lines.setLen(lines.len - 1)
  if lines.len <= n:
    return lines
  lines[lines.len - n .. ^1]

proc readIncrement*(path: string; offset: int64): tuple[data: string;
    newOffset: int64] =
  ## `logs -f` のポーリングループが使う純粋な増分読み取り関数。
  ##
  ## - ファイルが存在しない: 増分無し。`offset` はそのまま返す
  ##   （ファイルがまだ生まれていない/一時的に消えているだけかもしれないので
  ##   0 にリセットしない。復活したときに続きから読める）。
  ## - 現在のファイルサイズが `offset` より小さい: **ローテーション（truncate）**
  ##   と判断し、先頭 (0) から読み直す。
  ## - それ以外: `offset` から末尾までを読んで返す。
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
  ## `followFile` の Ctrl-C 検出フラグ。`setControlCHook` が要求する
  ## `proc () {.noconv.}` はクロージャ（ローカル変数のキャプチャ）を作れない
  ## （呼び出し規約 `noconv` に環境ポインタが無いため）ので、モジュールレベルの
  ## 変数を介す必要がある。`logs -f` は1プロセスにつき高々1回しか流れないので
  ## これで問題ない。

proc followFile(path: string): int =
  ## ファイルサイズを覚えて 200ms 間隔でポーリングし、増分を出力し続ける。
  ## Ctrl-C（SIGINT）を受けたらループを抜けて 130 を返す。
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
# RPC エラー表示の共通ヘルパー
# ---------------------------------------------------------------------------

proc extractRawStderr(e: ref RpcRemoteError): string =
  ## `data` フィールドに ssh の生 stderr が入っていればそれを取り出す。
  ## 文字列そのもの・`{"stderr": "..."}` の両方の形を受け付ける
  ## （デーモン側の実装がどちらの形にするか厳密には決め切れていないため）。
  ## 何も見つからなければ `RpcRemoteError.msg` にフォールバックする。
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
  ## `output.renderError` は3段構成の1段目に汎用的な見出し
  ## （"Failed to set up forwarding to X."）を含めてしまうが、呼び出し側
  ## （`cmdXxx`）はそれぞれの文脈に応じた具体的な見出しを既に `output.failure()`
  ## で別に出している。ここでは `renderError` の出力から先頭の見出し行と直後の
  ## 空行を取り除き、原因・対処・生ログの部分だけを返す。
  let rawStderr = extractRawStderr(e)
  let kind = classify(rawStderr)
  let ctx = initErrorContext(host = host, rawStderr = rawStderr)
  let full = renderError(w, kind, ctx, lang, rawStderr)
  let lines = full.splitLines()
  if lines.len > 2: lines[2 .. ^1].join("\n") else: full

proc jarr(node: JsonNode; key: string): JsonNode =
  ## `node[key]` を安全に取り出す。キーが無ければ空配列。
  if node != nil and node.hasKey(key): node[key] else: newJArray()

proc prunableNames*(rows: JsonNode): seq[string] =
  ## `tunnel.list` の結果（`JsonNode` の配列）から、`prune` の削除対象となる
  ## 名前だけを集める。
  ##
  ## 「停止中」の判定は `status == "stopped"` で行う。デーモンは無効化中の
  ## トンネルを `state: "fwPending"` + `status: "stopped"` で返す契約になって
  ## いる（`daemon/run.nim` の `tunnelEntryFromConfig` 参照。このモジュールは
  ## `daemon/` に依存しないため、契約を JSON の文字列値として直接見る）。
  ## `state` 側は実行中の `ForwardState` の値をそのまま使う設計上「無効化済み」
  ## を表す専用の値を持たないため、`state` では判定できない点に注意。
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

  # `-L` を先にすべて処理してから `-R` を処理する。argv.parseArgv は `-L` /
  # `-R` を別々の seq に蓄積するため、実際の入力上の混在順序（例:
  # `-L a -R b -L c`）は失われている（argv.nim は変更できない制約）。
  let allSpecs = args.localForwards & args.remoteForwards
  if allSpecs.len == 0:
    stderr.writeLine("powarder run: at least one -L or -R is required")
    return ecUsage.int

  let baseName = if args.name.len > 0: args.name else: randomName()
  ## **複数フォワードの命名規則**: 1トンネル = 1フォワードという設計なので、
  ## `-L`/`-R` が複数あれば `tunnel.create` を複数回呼ぶ。1本目は `baseName`
  ## そのまま、2本目以降は `"<baseName>-2"`, `"<baseName>-3"`, ... と連番を振る
  ## （それぞれ独立したランダム名にする案もあったが、同じ `run` 呼び出しで
  ## 作られたトンネル群だと `ps` の一覧で見て分かる方が実用上勝ると判断した）。

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
# start / stop / restart / rm （共通のRPC呼び出しパターン）
# ---------------------------------------------------------------------------

proc cmdSimpleNamesAction(args: ParsedArgs; w: Writer; lang: Lang;
    methodName, verb, pastVerb, resultKey: string): int =
  ## `{"names": [...]}` を渡して1回 RPC を呼び、結果配列を `success()` で
  ## 1行ずつ出す、という `start` / `stop` / `restart` / `rm` に共通の処理。
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
      # `tunnel.list` 自体には probe パラメータが無い。`--probe`
      # （能動的な Tier2 ヘルスチェックへのオプトイン）は、一覧を取る前に
      # `tunnel.check` を probe 付きで呼んでデーモン側の status を更新させる
      # ことで実現する。結果自体は使わず、単にトリガーとして呼ぶ。
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
  ## 停止中のトンネルをまとめて削除する。
  ##
  ## **`-a`/`--all` の指定有無に関わらず、常に `{"all": true}` で
  ## `tunnel.list` を問い合わせる。** `prune` の意味そのものが「停止中を
  ## 掃除する」ことなので、`ps` の既定フィルタ（実行中のみ表示。`-a` で
  ## 停止中も表示）とは無関係に全件を見る必要がある。
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
        echo w.info(if lang == langJa: "削除対象がありません"
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
# logs（★デーモンを経由しない）
# ---------------------------------------------------------------------------

proc cmdLogs(args: ParsedArgs): int =
  ## ログの実体は **ホスト単位**（1 ControlMaster = 1 ログファイル）に書かれる。
  ## powarder は同じ `host` を指す複数トンネルで1つのマスターを共有するので、
  ## ログもトンネル単位ではなくマスター単位になり、ファイル名には
  ## ホストの fingerprint が入る（例 `logs/localhost-5f675d2b.log`）。
  ## つまり**トンネル名だけからパスを決定できない**ので、`tunnel.inspect` で
  ## `log_path` を問い合わせる。
  ##
  ## **デーモンが死んでいてもログが読めること**はこのコマンドの重要な価値
  ## （デバッグの最後の砦）なので、問い合わせに失敗した場合は
  ## `logs/` 配下のファイル一覧を提示して直接読むよう誘導する。
  ## ログファイル自体はデーモンの生死に関係なく残っている。
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
    # 連結を1つずつ `add` で組む。複数行にまたがる `&` は nimpretty の整形で
    # `name &"..."` のように詰められ、`&"..."` が strformat の補間として
    # 解釈されてコンパイルエラーになることがあるため（実際に踏んだ）。
    var msg = "powarder: デーモンが停止しているため \""
    msg.add name
    msg.add "\" のログファイルを特定できません"
    msg.add "（ログは ControlMaster 単位で、ファイル名にホストの fingerprint が入るため）。"
    stderr.writeLine(msg)
    var found = false
    if dirExists(dir):
      for f in walkFiles(dir / "*.log"):
        if not found:
          stderr.writeLine("powarder: 以下のファイルを直接読んでください:")
          found = true
        stderr.writeLine("  " & f)
    if not found:
      stderr.writeLine("powarder: ログはまだありません: " & dir)
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
    discard # 元々止まっていたなら、そのまま起動を試みればよい

  # shutdown の応答が返っても実プロセスの終了は非同期かもしれないので、
  # 実際に ping が通らなくなるまで少し待ってから起動を試みる。
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
  ## デーモン自身のログ（`paths.daemonLogPath()`）を tail する。トンネルの
  ## `logs` と同じ考え方（IPC を経由しない直接ファイル読み込み）を流用する。
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
  ## OS サービス（macOS の launchd LaunchAgent / Linux の systemd `--user` unit）
  ## として常駐登録する。
  ##
  ## `getAppFilename()` は `nimble build` 直後の `./powarder` のような相対パスを
  ## 返しうるが、サービス登録には絶対パスが必要（launchd/systemd はカレント
  ## ディレクトリを引き継がない）ので `expandFilename()` で絶対化する。
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
    # `argv.nim` は `--foreground` というフラグ自体を持たないため、実際に
    # ここへ到達するのは `subsubcommand == ""`（`powarder daemon` を
    # サブサブコマンド無しで叩いた）場合のみ。`"--foreground"` の分岐は
    # 将来 argv.nim にそのフラグが追加された場合や、テストが `ParsedArgs` を
    # 手で組み立てて呼ぶ場合のために残してある（`autostart.ensureDaemon` は
    # `["daemon"]` だけを渡してこの経路に乗せる。`cli/autostart.nim` 参照）。
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
  ## サブコマンドを実行して終了コードを返す。標準出力への書き込みはここ
  ## （と、ここから呼ばれる `cmdXxx` 群）で行う。
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
