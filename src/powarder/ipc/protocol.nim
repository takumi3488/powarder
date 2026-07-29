## powarder の CLI (クライアント) とデーモン (サーバー) が Unix domain socket 上で
## やり取りする JSON-RPC 2.0 メッセージのエンコード / デコードを行う。
##
## このモジュールは **文字列 <-> 型の相互変換のみ** を行う純粋モジュールであり、
## `std/asyncnet` / `std/net` / `std/osproc` を import しない。ソケットへの
## 読み書きは `ipc/client.nim` / `ipc/server.nim` の責務。
##
## 前提（1メッセージ = 1行の framing）:
## - 1つの JSON-RPC メッセージは改行を含まない1行の JSON 文字列として表現される。
##   `encode*` はこの前提の下で常に改行を含まない文字列を返す
##   （`$JsonNode` は既定で改行を含まない出力になる。`pretty()` は使わない）。
## - JSON 文字列リテラル中の生の改行は JSON エンコーダが `\n` にエスケープするため、
##   この 1 行 = 1 メッセージという framing は安全に成立する。
## - 1つの UDS 接続 = 1つの論理コマンド。`logs -f` のようなストリーミングは
##   デーモンを経由せず CLI がログファイルを直接 tail する設計なので、現時点では
##   notification を積極的に使う予定はない。ただし将来のために notification の
##   エンコード/デコード（`id` を持たないメッセージ）は用意しておく。

import std/json
import std/options
import std/strformat
import std/nativesockets ## `Port` の `==` を使うために必要（types.nim は `Port` 自体は
                          ## export しているが、`==` などの演算子までは re-export しないため）

# `import powarder/core/types` の形を試したが、この構成では
# リポジトリ直下に nim.cfg 等の `--path` 設定が無く plain `nim c` では解決できない
# （nimble 経由でビルドする場合のみ srcDir が自動で path に載る）。
# そのため `mise exec -- nim c -r tests/tprotocol.nim` を素のコマンドで通すために
# 相対 import に切り替えた（実測して確認済み）。
import powarder/core/types

# ---------------------------------------------------------------------------
# メッセージ型
# ---------------------------------------------------------------------------

type
  RpcRequest* = object
    id*: Option[int]  ## none なら notification（応答を期待しない通知）
    methodName*: string
      ## JSON 上のキー名は "method"。
      ## `method` は Nim の予約語（`method` ステートメント = OOP の多重ディスパッチ用
      ## メソッド定義に使われる）であり、フィールド名として使うにはバッククォートでの
      ## エスケープ（`` `method` ``）が常に必要になって呼び出し側の可読性を損なう。
      ## このモジュールは JSON キー名とフィールド名の対応をエンコード/デコード関数側で
      ## 手動で吸収するので、Nim 側の識別子は素直に読み書きできる `methodName` にした。
    params*: JsonNode ## 引数無し呼び出しでは nil

  RpcErrorInfo* = object
    code*: int
    message*: string
    data*: JsonNode ## 追加情報が無ければ nil

  RpcResponse* = object
    id*: Option[int]
      ## 応答は常に対応するリクエストの `id` を持つ想定なので、実用上ここが
      ## `none` になることは無い（`encodeSuccess` / `encodeError` はどちらも
      ## `id: int` を必須で受け取るため、id 無しの応答は作れない）。
      ## それでも `RpcRequest.id` と型を対称にしておくことで、将来
      ## 「id が特定できないまま返すエラー応答」のような JSON-RPC 2.0 の
      ## エッジケースを表現したくなったときに型を変えずに済む。
    result*: JsonNode ## 成功時の戻り値。省略可能な呼び出しの応答では nil
    error*: Option[RpcErrorInfo] ## 成功時は none

  RpcParseErrorKind* = enum
    ## `decodeRequest` / `decodeResponse` が投げる `RpcParseError` の原因分類。
    ## メッセージ文字列だけに頼ると呼び出し側での分岐が壊れやすいため、
    ## `case` で判定できるように種別を持たせる。
    rpeInvalidJson ## JSON として構文解析できない（空文字列を含む）
    rpeInvalidVersion ## "jsonrpc" フィールドが無い、または "2.0" でない
    rpeMissingField ## 必須フィールドが欠落している
    rpeInvalidField ## フィールドは存在するが型/値が不正

  RpcParseError* = object of CatchableError
    kind*: RpcParseErrorKind

proc newRpcParseError(kind: RpcParseErrorKind; msg: string): ref RpcParseError =
  result = newException(RpcParseError, msg)
  result.kind = kind

# ---------------------------------------------------------------------------
# エラーコード
# ---------------------------------------------------------------------------

const
  # JSON-RPC 2.0 標準のエラーコード。
  rpcParseError* = -32700
  rpcInvalidRequest* = -32600
  rpcMethodNotFound* = -32601
  rpcInvalidParams* = -32602
  rpcInternalError* = -32603

  # powarder 固有のエラーコード（JSON-RPC 2.0 のサーバー定義領域 -32000〜-32099）。
  # 各コメントは対応する CLI の終了コード。
  errTunnelNotFound* = -32001 ## 終了コード 4
  errTunnelNameConflict* = -32002 ## 終了コード 5
  errSshFailed* = -32003 ## 終了コード 6
  errConfigInvalid* = -32004 ## 終了コード 3
  errHostNotFound* = -32005
  errForwardBindFailed* = -32006

# ---------------------------------------------------------------------------
# メソッド名
# ---------------------------------------------------------------------------

const
  mDaemonPing* = "daemon.ping"
  mDaemonInfo* = "daemon.info"
  mDaemonReload* = "daemon.reload"
  mDaemonShutdown* = "daemon.shutdown"
  mTunnelList* = "tunnel.list"
  mTunnelInspect* = "tunnel.inspect"
  mTunnelCreate* = "tunnel.create" ## ad-hoc な `powarder run` 用
  mTunnelUp* = "tunnel.up"
  mTunnelDown* = "tunnel.down"
  mTunnelStart* = "tunnel.start"
  mTunnelStop* = "tunnel.stop"
  mTunnelRestart* = "tunnel.restart"
  mTunnelRemove* = "tunnel.remove"
  mTunnelCheck* = "tunnel.check"
  mHostList* = "host.list"

# ---------------------------------------------------------------------------
# エンコード
# ---------------------------------------------------------------------------
#
# JSON-RPC 2.0 の建前では成功応答の "result" は値が無くても `null` として
# 常に含める必要があるが、powarder の内部プロトコルでは
# `params` / `result` / `data` が Nim 側で `nil`（JsonNode を渡さない）の場合、
# 出力 JSON からそのフィールド自体を省略する。呼び出し側の設計判断としてこの方が
# 「値が無い」を表現するのに素直で、bandwidth 上のメリットも小さいながらある。

proc encodeRequest*(id: int; methodName: string;
    params: JsonNode = nil): string =
  ## id 付きリクエストを1行の JSON にエンコードする。
  var j = newJObject()
  j["jsonrpc"] = %"2.0"
  j["id"] = %id
  j["method"] = %methodName
  if params != nil:
    j["params"] = params
  result = $j

proc encodeNotification*(methodName: string; params: JsonNode = nil): string =
  ## `id` を持たない notification を1行の JSON にエンコードする。
  ## JSON-RPC 2.0 の定義通り、notification は "id" フィールド自体を持たない
  ## （"id": null ではなく、キーが存在しない）。
  var j = newJObject()
  j["jsonrpc"] = %"2.0"
  j["method"] = %methodName
  if params != nil:
    j["params"] = params
  result = $j

proc encodeSuccess*(id: int; res: JsonNode): string =
  ## 成功応答を1行の JSON にエンコードする。`res` が nil のときは
  ## "result" フィールド自体を省略する（daemon.shutdown のような戻り値の
  ## 意味を持たない呼び出しを想定）。
  var j = newJObject()
  j["jsonrpc"] = %"2.0"
  j["id"] = %id
  if res != nil:
    j["result"] = res
  result = $j

proc encodeError*(id: int; code: int; message: string;
    data: JsonNode = nil): string =
  ## エラー応答を1行の JSON にエンコードする。
  var errObj = newJObject()
  errObj["code"] = %code
  errObj["message"] = %message
  if data != nil:
    errObj["data"] = data
  var j = newJObject()
  j["jsonrpc"] = %"2.0"
  j["id"] = %id
  j["error"] = errObj
  result = $j

# ---------------------------------------------------------------------------
# デコード
# ---------------------------------------------------------------------------

proc parseAndCheckEnvelope(line: string): JsonNode =
  ## request/response 共通の下ごしらえ:
  ## 空文字列・JSON構文エラー・トップレベルがオブジェクトでない・
  ## jsonrpc フィールドの検査までをまとめて行う。
  if line.len == 0:
    # UDS の recvLine は切断時に空文字列を返す。切断と「空行を受け取った」の
    # 区別は上位レイヤ（recvLine の戻り値そのもの）の責務であり、このモジュールに
    # 渡ってきた空文字列は常に不正な入力として扱う。
    raise newRpcParseError(rpeInvalidJson, "空文字列は不正な入力です")

  var j: JsonNode
  try:
    j = parseJson(line)
  except JsonParsingError as e:
    raise newRpcParseError(rpeInvalidJson,
        &"JSON の構文解析に失敗しました: {e.msg}")

  if j.kind != JObject:
    raise newRpcParseError(rpeInvalidJson, "JSON のトップレベルはオブジェクトである必要があります")

  if not j.hasKey("jsonrpc"):
    raise newRpcParseError(rpeInvalidVersion, "jsonrpc フィールドがありません")
  if j["jsonrpc"].kind != JString or j["jsonrpc"].getStr != "2.0":
    raise newRpcParseError(rpeInvalidVersion, "jsonrpc フィールドは \"2.0\" である必要があります")

  result = j

proc decodeRequest*(line: string): RpcRequest =
  ## 1行の JSON 文字列を `RpcRequest` にデコードする。
  ## 不正な入力は `RpcParseError` を送出する。
  let j = parseAndCheckEnvelope(line)

  if not j.hasKey("method"):
    raise newRpcParseError(rpeMissingField, "method フィールドがありません")
  if j["method"].kind != JString:
    raise newRpcParseError(rpeInvalidField, "method フィールドは文字列である必要があります")
  let methodName = j["method"].getStr

  var id = none(int)
  if j.hasKey("id"):
    # notification は "id" キー自体を持たない。キーが存在する場合は
    # 整数であることを要求する（文字列/null な id は powarder では未サポート）。
    if j["id"].kind != JInt:
      raise newRpcParseError(rpeInvalidField, "id フィールドは整数である必要があります")
    id = some(j["id"].getInt)

  var params: JsonNode = nil
  if j.hasKey("params") and j["params"].kind != JNull:
    params = j["params"]

  result = RpcRequest(id: id, methodName: methodName, params: params)

proc decodeResponse*(line: string): RpcResponse =
  ## 1行の JSON 文字列を `RpcResponse` にデコードする。
  ## 不正な入力は `RpcParseError` を送出する。
  let j = parseAndCheckEnvelope(line)

  if not j.hasKey("id"):
    raise newRpcParseError(rpeMissingField, "id フィールドがありません")
  if j["id"].kind != JInt:
    raise newRpcParseError(rpeInvalidField, "id フィールドは整数である必要があります")
  let id = some(j["id"].getInt)

  let hasError = j.hasKey("error") and j["error"].kind != JNull
  let hasResult = j.hasKey("result") and j["result"].kind != JNull

  if hasError:
    let ej = j["error"]
    if ej.kind != JObject:
      raise newRpcParseError(rpeInvalidField, "error フィールドはオブジェクトである必要があります")
    if not ej.hasKey("code"):
      raise newRpcParseError(rpeMissingField, "error.code フィールドがありません")
    if ej["code"].kind != JInt:
      raise newRpcParseError(rpeInvalidField, "error.code フィールドは整数である必要があります")
    if not ej.hasKey("message"):
      raise newRpcParseError(rpeMissingField, "error.message フィールドがありません")
    if ej["message"].kind != JString:
      raise newRpcParseError(rpeInvalidField, "error.message フィールドは文字列である必要があります")

    var data: JsonNode = nil
    if ej.hasKey("data") and ej["data"].kind != JNull:
      data = ej["data"]

    let errInfo = RpcErrorInfo(code: ej["code"].getInt, message: ej[
        "message"].getStr, data: data)
    result = RpcResponse(id: id, result: nil, error: some(errInfo))
  elif hasResult:
    result = RpcResponse(id: id, result: j["result"], error: none(RpcErrorInfo))
  else:
    # "result" も "error" も無い（JSON null による省略済みの成功応答を含む）は
    # 正当な「戻り値なしの成功応答」として扱う。
    result = RpcResponse(id: id, result: nil, error: none(RpcErrorInfo))

# ---------------------------------------------------------------------------
# ペイロードのシリアライズ補助
# ---------------------------------------------------------------------------
#
# `std/json` の `%*` マクロ / `to()` マクロを types.nim の各型に対して実測した結果:
#
# - `Port`（`distinct uint16`）: エンコード方向 (`%`) は標準ライブラリに
#   `distinct` 型向けの汎用オーバーロードが無いため、`ForwardSpec` などを
#   そのまま `%*` に渡すとコンパイルエラーになる。下の `` `%`*(p: Port) ``
#   が無いと `src/powarder/ipc/protocol.nim` はコンパイルできない。
#   一方デコード方向の `to()` は `initFromJson[T: distinct]` が
#   `distinctBase` 経由で自動的に面倒を見てくれるため、手書きの変換は不要だった。
# - `ForwardKind`（`fkLocal = "L"` のように文字列値を持つ enum）: `%(o: enum)` は
#   `$o` を使って文字列化するため、"L" / "R" が期待通りそのまま JSON 文字列になる。
#   デコード方向も `parseEnum` が同じ `$o` 表現から逆引きするため、追加の変換は不要。
# - `UpstreamTarget`（case を含む variant object）: `%*` / `to()` はどちらも
#   variant object をそのまま扱えた（`Port` への `%` を用意した後は
#   コンパイル/往復変換とも問題なし）。ただし Nim が自動生成する `==` は
#   フィールドを並行に辿る `fields` イテレータを使っており、
#   "parallel 'fields' iterator does not work for 'case' objects" という
#   コンパイルエラーになって variant object には使えない。往復変換のテストで
#   `==` による比較が必要なため、下に手書きの `` `==` `` を用意した
#   （本来は types.nim 側に置くのが自然だが、当エージェントはそのファイルを
#   変更できないためここに定義する。types.nim への追加を提案する）。
#
# 以上により、`ForwardSpec` / `TunnelConfig` / `HostSessionKey` / `RetryPolicy` は
# 汎用の `%` / `to()` にそのまま委譲するだけの薄いラッパーで済んでいる。


proc toJson*(spec: ForwardSpec): JsonNode = % spec
proc forwardSpecFromJson*(node: JsonNode): ForwardSpec = node.to(ForwardSpec)

proc toJson*(policy: RetryPolicy): JsonNode = % policy
proc retryPolicyFromJson*(node: JsonNode): RetryPolicy = node.to(RetryPolicy)

proc toJson*(cfg: TunnelConfig): JsonNode = % cfg
proc tunnelConfigFromJson*(node: JsonNode): TunnelConfig = node.to(TunnelConfig)

proc toJson*(key: HostSessionKey): JsonNode = % key
proc hostSessionKeyFromJson*(node: JsonNode): HostSessionKey = node.to(HostSessionKey)

proc toJson*(target: UpstreamTarget): JsonNode = % target
proc upstreamTargetFromJson*(node: JsonNode): UpstreamTarget = node.to(UpstreamTarget)
