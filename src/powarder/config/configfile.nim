## ユーザーが手で編集する宣言的設定ファイル（`powarder.json` / `~/.config/powarder/config.json`）。
##
## **JSON のみを使う**（`std/json`）。外部 nimble 依存は追加しない。
##
## スキーマ:
## ```jsonc
## {
##   "version": 1,
##   "tunnels": [
##     { "name": "prod-db", "host": "prod-bastion", "type": "L",
##       "forward": "15432:db.internal:5432", "autostart": true, "profile": "prod" }
##   ]
## }
## ```
## - `type` は `"L"` / `"R"`（`core/types.ForwardKind` の文字列値と 1:1 対応）。
## - `forward` は ssh 完全互換の `[bind_address:]port:host:hostport` 文字列。
##   `core/forwardspec.parseForwardSpec()` でパースする。
## - `autostart` / `profile` / `sshExtraArgs` / `retry` は省略可能（既定値あり）。
##
## **意図的に `user` / `port` / `identityFile` / `proxyJump` に相当するフィールドを
## 持たせていない。** 接続経路・認証は `~/.ssh/config` の責務、転送トポロジ
## （どのローカルポートをどこへ転送するか）は powarder の責務、という役割分担を
## スキーマのレベルで構造的に強制するための設計判断。これらのキーが JSON に
## 書かれていても致命的エラーにはせず、`~/.ssh/config` へ書くよう誘導する警告
## （`ConfigFile.forbiddenKeyWarnings`）として検出する。

import std/[json, os, strutils, tables]
import powarder/core/types
import powarder/core/forwardspec
import powarder/core/paths
import powarder/ipc/protocol ## RetryPolicy の JSON 変換 (retryPolicyFromJson/toJson) を再利用する

type
  ConfigFile* = object
    version*: int
    tunnels*: seq[TunnelConfig]
    forbiddenKeyWarnings*: seq[string]
      ## `user` / `port` / `identityFile` / `proxyJump` など、意図的にサポートしない
      ## フィールドが JSON に書かれていた場合の警告メッセージ（"warning: " 接頭辞付き）。
      ## `TunnelConfig`（core/types.nim）にはこれらのフィールド自体が存在せず、
      ## パース後には情報が失われてしまうため、生の JSON を持っている `loadConfig` の
      ## 時点で検出してここへ退避しておく。`validateConfig` はこれをそのまま
      ## 結果に含める。

  ConfigError* = object of CatchableError
    ## 設定ファイルの構文エラー・スキーマ不正を表す。メッセージには常に
    ## ファイルパスと問題のあるトンネル（インデックス・name）・フィールド名を含める。

const
  forbiddenKeys = ["user", "port", "identityFile", "proxyJump"]
    ## powarder が意図的にサポートしないフィールド一覧。上のモジュール doc comment を参照。

# ---------------------------------------------------------------------------
# 内部ヘルパー
# ---------------------------------------------------------------------------

proc tunnelLabel(idx: int; name: string): string =
  ## エラーメッセージ用にトンネルを特定する文字列。name が読めていればそれも含める。
  if name.len > 0: "tunnels[" & $idx & "] (name=\"" & name & "\")"
  else: "tunnels[" & $idx & "]"

proc configErr(path, label, field, msg: string): ref ConfigError =
  newException(ConfigError,
    path & ": " & label & " の \"" & field & "\" が不正です: " & msg)

proc parseTunnelNode(path: string; idx: int; node: JsonNode): (TunnelConfig,
    seq[string]) =
  ## `tunnels` 配列の1要素をパースする。戻り値は (TunnelConfig, 禁止キー警告)。
  if node.kind != JObject:
    raise newException(ConfigError,
      path & ": tunnels[" & $idx & "] はオブジェクトである必要があります")

  # name
  if not node.hasKey("name") or node["name"].kind != JString:
    raise configErr(path, "tunnels[" & $idx & "]", "name", "文字列の \"name\" が必要です")
  let name = node["name"].getStr
  let label = tunnelLabel(idx, name)

  # host
  if not node.hasKey("host") or node["host"].kind != JString:
    raise configErr(path, label, "host", "文字列の \"host\" が必要です")
  let host = node["host"].getStr

  # type
  if not node.hasKey("type") or node["type"].kind != JString:
    raise configErr(path, label, "type", "文字列の \"type\" (\"L\" または \"R\") が必要です")
  let typeStr = node["type"].getStr
  var kind: ForwardKind
  try:
    kind = parseEnum[ForwardKind](typeStr)
  except ValueError:
    raise configErr(path, label, "type",
      "\"L\" または \"R\" である必要があります（実際: \"" &
      typeStr & "\"）")

  # forward
  if not node.hasKey("forward") or node["forward"].kind != JString:
    raise configErr(path, label, "forward", "文字列の \"forward\" が必要です")
  let forwardStr = node["forward"].getStr
  var spec: ForwardSpec
  try:
    spec = parseForwardSpec(forwardStr, kind)
  except ValueError as e:
    raise configErr(path, label, "forward", e.msg)

  # autostart（省略可能。既定 false）
  var autostart = false
  if node.hasKey("autostart"):
    if node["autostart"].kind != JBool:
      raise configErr(path, label, "autostart", "真偽値である必要があります")
    autostart = node["autostart"].getBool

  # profile（省略可能。既定 ""）
  var profile = ""
  if node.hasKey("profile"):
    if node["profile"].kind != JString:
      raise configErr(path, label, "profile", "文字列である必要があります")
    profile = node["profile"].getStr

  # sshExtraArgs（省略可能。既定 @[]）
  var sshExtraArgs: seq[string] = @[]
  if node.hasKey("sshExtraArgs"):
    if node["sshExtraArgs"].kind != JArray:
      raise configErr(path, label, "sshExtraArgs", "文字列の配列である必要があります")
    for elemNode in node["sshExtraArgs"]:
      if elemNode.kind != JString:
        raise configErr(path, label, "sshExtraArgs", "要素は全て文字列である必要があります")
      sshExtraArgs.add elemNode.getStr

  # retry（省略可能。既定 initRetryPolicy()）
  var retry = initRetryPolicy()
  if node.hasKey("retry"):
    try:
      retry = retryPolicyFromJson(node["retry"])
    except CatchableError as e:
      raise configErr(path, label, "retry", e.msg)

  # 禁止キー（エラーではなく警告）
  var warnings: seq[string] = @[]
  for fk in forbiddenKeys:
    if node.hasKey(fk):
      warnings.add "warning: " & label & ": \"" & fk &
        "\" は powarder ではサポートしていません。~/.ssh/config の Host " &
        host & " セクションに書いてください"

  let cfg = TunnelConfig(name: name, host: host, spec: spec, autostart: autostart,
                          profile: profile, sshExtraArgs: sshExtraArgs, retry: retry)
  (cfg, warnings)

proc tunnelToJson(t: TunnelConfig): JsonNode =
  ## `TunnelConfig` をユーザー向けスキーマ（flat な "type"/"forward"）の JSON にする。
  ## `ipc/protocol.toJson(TunnelConfig)` は "spec": {...} のネストした内部表現を
  ## 作るため（デーモン間 IPC 用）、ここでは使わずファイル用に手書きする。
  ## 既定値と等しいフィールドは省略し、人間が読んだときに差分が分かりやすい
  ## 最小限の JSON にする（loadConfig 側で省略時の既定値と揃えてあるので
  ## 往復変換は保たれる）。
  result = newJObject()
  result["name"] = %t.name
  result["host"] = %t.host
  result["type"] = %t.spec.kind
  result["forward"] = %formatForwardSpec(t.spec)
  if t.autostart:
    result["autostart"] = %true
  if t.profile.len > 0:
    result["profile"] = %t.profile
  if t.sshExtraArgs.len > 0:
    result["sshExtraArgs"] = %t.sshExtraArgs
  if t.retry != initRetryPolicy():
    result["retry"] = toJson(t.retry)

# ---------------------------------------------------------------------------
# 公開 API
# ---------------------------------------------------------------------------

proc loadConfig*(path: string): ConfigFile =
  ## JSON を読んで `ConfigFile` にする。パースエラー・スキーマ不正は `ConfigError` を
  ## 投げる。例外メッセージには常にファイルパスと問題のあるトンネル
  ## （インデックス・分かっていれば name）・フィールド名を含める。
  var content: string
  try:
    content = readFile(path)
  except IOError as e:
    raise newException(ConfigError, path &
        ": 設定ファイルを読み込めません: " & e.msg)

  var root: JsonNode
  try:
    root = parseJson(content)
  except JsonParsingError as e:
    raise newException(ConfigError, path &
        ": JSON の構文解析に失敗しました: " & e.msg)

  if root.kind != JObject:
    raise newException(ConfigError, path & ": トップレベルはオブジェクトである必要があります")

  let version =
    if root.hasKey("version") and root["version"].kind == JInt: root[
        "version"].getInt
    else: 1

  var tunnels: seq[TunnelConfig] = @[]
  var warnings: seq[string] = @[]

  if root.hasKey("tunnels"):
    if root["tunnels"].kind != JArray:
      raise newException(ConfigError, path & ": \"tunnels\" は配列である必要があります")
    let arr = root["tunnels"]
    for idx in 0 ..< arr.len:
      let (cfg, w) = parseTunnelNode(path, idx, arr[idx])
      tunnels.add cfg
      warnings.add w

  ConfigFile(version: version, tunnels: tunnels, forbiddenKeyWarnings: warnings)

proc saveConfig*(path: string; cfg: ConfigFile) =
  ## 人間が読める形（インデント付き）で書く。一時ファイルへ書いてから
  ## `moveFile` でアトミックに置き換える（一時ファイルは `path` と同一ディレクトリに
  ## 作る。別ファイルシステムをまたぐと rename がアトミックでなくなるため）。
  var root = newJObject()
  root["version"] = %cfg.version
  var arr = newJArray()
  for t in cfg.tunnels:
    arr.add tunnelToJson(t)
  root["tunnels"] = arr

  let dir = path.parentDir
  if dir.len > 0:
    createDir(dir)

  let tmpPath = path & ".tmp." & $getCurrentProcessId()
  writeFile(tmpPath, root.pretty())
  # 0600 にしてから rename する（`config/statefile.saveState` と同じ理由）。
  # 設定ファイルには踏み台や内部ネットワークのホスト名・ポートが並ぶので、
  # 他ユーザーから読める必要が無い。rename の**前**に落とすことで
  # 一瞬 644 になる窓を作らない。
  setFilePermissions(tmpPath, {fpUserRead, fpUserWrite})
  moveFile(tmpPath, path)

proc validateConfig*(cfg: ConfigFile): seq[string] =
  ## 設定の意味的な問題を全部集めて返す（1つ見つけて即エラーにせず、まとめて報告する）。
  ##
  ## 戻り値の各要素はメッセージ文字列で、**"warning: " で始まるものは警告**
  ## （起動・保存を妨げない）、それ以外は致命的な問題（呼び出し側はここで
  ## 弾くべき）という規約にする。警告扱いにしているのは:
  ## - 禁止キー（`user`/`port`/`identityFile`/`proxyJump`）が書かれていた場合
  ##   （`loadConfig` が収集した `cfg.forbiddenKeyWarnings` をそのまま含める）
  ## - `bindAddr` がループバック以外（`exposesExternally`）の場合
  ##   （外部公開が意図的なこともあるため、エラーで弾くと正当な用途を壊す）
  ## それ以外（name/forwardId の重複、name/host が空、version 不正）は
  ## 設定として成立し得ないため常にエラー扱いにする。
  result = @[]

  for w in cfg.forbiddenKeyWarnings:
    result.add w

  if cfg.version != 1:
    result.add "version は 1 のみサポートしています（実際の値: " &
        $cfg.version & "）"

  var namesSeen = initTable[string, int]()
  var forwardGroups = initTable[string, seq[string]]()

  for idx, t in cfg.tunnels:
    if t.name.strip().len == 0:
      result.add "tunnels[" & $idx & "] (host=\"" & t.host & "\"): name が空です"
    else:
      namesSeen[t.name] = namesSeen.getOrDefault(t.name, 0) + 1

    if t.host.len == 0:
      result.add "tunnels[" & $idx & "] (name=\"" & t.name & "\"): host が空です"

    if exposesExternally(t.spec):
      result.add "warning: トンネル \"" & t.name &
          "\" はループバック以外 (" &
        t.spec.bindAddr & ") にバインドし、外部に公開されます。意図した設定か確認してください"

    let fid = forwardId(t.spec, t.host)
    forwardGroups[fid] = forwardGroups.getOrDefault(fid, @[]) & t.name

  for name, cnt in namesSeen:
    if cnt > 1:
      result.add "トンネル名 \"" & name &
          "\" が重複しています（" & $cnt & " 件）"

  for fid, names in forwardGroups:
    if names.len > 1:
      result.add "同じ転送先 (" & fid &
          ") を複数のトンネルが取り合っています: " &
        names.join(", ")

proc findConfigFile*(explicit = ""): string =
  ## 設定ファイルの探索。優先順位:
  ## 1. `explicit`（`--file`/`-f` で明示指定されたパス）
  ## 2. `./powarder.json`（プロジェクトローカル。存在する場合のみ。`paths.localConfigFile()`）
  ## 3. `~/.config/powarder/config.json`（`paths.configFile()`。`POWARDER_CONFIG` でも上書き可）
  ## どれも無ければ 3. のパスを返す（存在しないパスを返してよい。呼び出し側が扱う）。
  if explicit.len > 0:
    return expandTilde(explicit)

  let local = localConfigFile()
  if fileExists(local):
    return local

  configFile()

proc defaultConfig*(): ConfigFile =
  ## `version: 1, tunnels: @[]` の空設定。設定ファイルが無いときの初期値。
  ConfigFile(version: 1, tunnels: @[], forbiddenKeyWarnings: @[])
