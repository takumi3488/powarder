## CLI 側の IPC トランスポート: Unix domain socket 上での1回限りの同期 RPC 呼び出し。
##
## CLI は短命プロセス（起動 → 1つのコマンドを実行 → 終了）なので、デーモン側
## （`ipc/server`）と違って `std/asyncdispatch` のイベントループを回す必要が無い。
## `std/net` の同期 API だけで完結させる。
##
## メッセージの JSON エンコード/デコードは一切ここでは行わない
## （`ipc/protocol` に完全委譲する）。

import std/[net, nativesockets, posix, json, options]
import powarder/ipc/protocol
import powarder/core/paths

type
  IpcClientError* = object of CatchableError

  DaemonNotRunningError* = object of IpcClientError
    ## ソケットが無い（`ENOENT`）か、残骸だけあって誰も listen していない
    ## （`ECONNREFUSED`）。CLI 側はこれを見てデーモンの自動起動を試みるので、
    ## 他のエラー（権限エラーや壊れた応答など）と必ず区別できるようにしてある。

  RpcRemoteError* = object of IpcClientError
    code*: int
    data*: JsonNode
    ## デーモンがエラー応答を返した。CLI の終了コードに対応させるため
    ## `code` を保持する（例: `errTunnelNotFound` → 終了コード 4）。

var callIdCounter = 0
  ## リクエスト id 用の単調増加カウンタ。CLI プロセスは通常 1 回の起動につき
  ## `call` を 1 回しか呼ばないが、複数回呼ばれても id が衝突しないようにする。

proc nextCallId(): int =
  inc callIdCounter
  callIdCounter

proc classifyConnectFailure(e: ref OSError): ref DaemonNotRunningError =
  ## `connectUnix` が投げた `OSError` の errno を見て、
  ## 「デーモンが動いていない」ケースかどうかを判定する。
  ##
  ## - `ENOENT`（ソケットファイルが無い）
  ## - `ECONNREFUSED`（ファイルはあるが誰も listen していない
  ##   = デーモンがクラッシュした残骸）
  ## のどちらでもなければ `nil` を返す（呼び出し側が汎用の `IpcClientError` に
  ## する）。
  ##
  ## errno は `(ref OSError).errorCode`（`int32`）から取る。`osLastError()` を
  ## 呼び出し側で改めて読む方式だと、例外が飛んでから catch するまでの間に
  ## （たとえ何もしていなくても）errno が上書きされるリスクがあるため、
  ## 例外オブジェクトが `raiseOSError` の時点で保持しているこのフィールドの方が
  ## 確実。
  if e.errorCode == ENOENT.int32 or e.errorCode == ECONNREFUSED.int32:
    result = newException(DaemonNotRunningError,
        "daemon is not running (" & e.msg & ")")

proc call*(methodName: string; params: JsonNode = nil; path = "";
    timeoutMs = 5000): JsonNode =
  ## 1回の RPC を実行する: 接続 → リクエスト送信 → 1行受信 → 切断。
  ##
  ## - `path` が空なら `paths.ipcSocketPath()` を使う
  ## - ソケットが無い／繋がらない場合は `DaemonNotRunningError`
  ## - デーモンがエラー応答を返したら `RpcRemoteError`（`code` 付き）
  ## - `timeoutMs` 以内に応答が届かなければ `IpcClientError`
  ##
  ## **`connectUnix` にはタイムアウト引数が無い。** UDS はローカルホスト内の
  ## 接続でありネットワーク遅延が存在しないため、connect 自体がハングする
  ## リスクは低いと判断してここでは対処しない（send / recvLine には
  ## `std/net` がタイムアウトを提供しているのでそちらは効かせる）。
  let p = if path.len > 0: path else: ipcSocketPath()

  var sock: Socket
  try:
    # `AF_UNIX` / `SOCK_STREAM` / `IPPROTO_IP` は `std/posix` にも同名の
    # （`cint` の）定数があり、`std/posix` を errno 定数のために import している
    # 都合上あいまい呼び出しになる。`nativesockets` の enum 版だと明示する。
    sock = newSocket(nativesockets.AF_UNIX, nativesockets.SOCK_STREAM,
        nativesockets.IPPROTO_IP)
  except OSError as e:
    raise newException(IpcClientError, "failed to create socket: " & e.msg)

  try:
    try:
      sock.connectUnix(p)
    except OSError as e:
      let daemonErr = classifyConnectFailure(e)
      if daemonErr != nil:
        raise daemonErr
      raise newException(IpcClientError,
          "failed to connect to " & p & ": " & e.msg)

    let id = nextCallId()
    let requestLine = encodeRequest(id, methodName, params)
    try:
      sock.send(requestLine & "\n")
    except OSError as e:
      raise newException(IpcClientError, "failed to send request: " & e.msg)

    var responseLine: string
    try:
      responseLine = sock.recvLine(timeout = timeoutMs)
    except TimeoutError as e:
      raise newException(IpcClientError,
          "timed out waiting for a response: " & e.msg)
    except OSError as e:
      raise newException(IpcClientError, "failed to receive response: " & e.msg)

    if responseLine.len == 0:
      # `recvLine` は切断時に空文字列を返す（`protocol.decodeResponse` に渡すと
      # 空文字列は常に `RpcParseError` になるため、ここで先に区別しておく）。
      raise newException(IpcClientError,
          "daemon closed the connection before sending a response")

    let response =
      try:
        decodeResponse(responseLine)
      except RpcParseError as e:
        raise newException(IpcClientError,
            "received an invalid response from the daemon: " & e.msg)

    if response.error.isSome:
      let errInfo = response.error.get
      var remoteErr = newException(RpcRemoteError, errInfo.message)
      remoteErr.code = errInfo.code
      remoteErr.data = errInfo.data
      raise remoteErr

    result = response.result
  finally:
    sock.close()

proc ping*(path = ""): bool =
  ## `daemon.ping` を投げてデーモンが生きているか確認する。
  ##
  ## **これだけは例外を投げない。** CLI の自動起動判定（「デーモンが居なければ
  ## 起動してからリトライする」）に使うため、`DaemonNotRunningError` を捕まえて
  ## 単に `false` を返す。
  try:
    discard call(mDaemonPing, path = path)
    true
  except DaemonNotRunningError:
    false
