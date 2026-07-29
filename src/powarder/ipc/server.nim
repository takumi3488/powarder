## デーモン側の IPC トランスポート: Unix domain socket 上の accept ループと
## リクエストディスパッチ。
##
## メッセージの JSON エンコード/デコードは一切ここでは行わない
## （`ipc/protocol` の `decodeRequest` / `encodeSuccess` / `encodeError` に完全委譲する）。
## このモジュールの責務は
## - ソケットの bind / listen / accept
## - 1行読んで1行書く（改行がフレーミング）
## - 登録されたハンドラへのディスパッチとエラーの JSON-RPC への変換
## - ハンドラが何を投げてもデーモンプロセスを道連れにしない
## の4点だけに絞る。デーモンはシングルスレッドの非同期イベントループ
## （`std/asyncdispatch`）上で動く前提。

import std/[asyncdispatch, asyncnet, nativesockets, json, options, os, tables]
import powarder/ipc/protocol
import powarder/core/paths

type
  RpcHandler* = proc (params: JsonNode): JsonNode {.closure, gcsafe.}
    ## 成功時は response の `result` になる `JsonNode` を返す。
    ## 失敗時は `RpcError` を投げる（コードを指定したいエラー）か、
    ## それ以外の例外を投げる（`rpcInternalError` に丸められる）。

  RpcError* = object of CatchableError
    code*: int
    data*: JsonNode
    ## ハンドラが「JSON-RPC のエラー応答として返したい」ときに投げる例外。
    ## `code` には `ipc/protocol` のエラーコード定数
    ## （`errTunnelNotFound` 等）を入れる。`msg`（`CatchableError` 由来）が
    ## そのままエラー応答の `message` になる。

  IpcServer* = ref object
    socket*: AsyncSocket
    path*: string
    handlers*: Table[string, RpcHandler]
    closing*: bool
    conns: seq[Future[void]]
      ## 実行中の `handleClient` の Future。`serve()` の accept ループの先頭で
      ## 完了済みのものを間引く（`asyncCheck` ではなくこちらを使う理由は
      ## `serve()` の doc comment を参照）。

proc newRpcError*(code: int; message: string;
    data: JsonNode = nil): ref RpcError =
  ## ハンドラ側で `raise newRpcError(errTunnelNotFound, "...")` のように使う
  ## 補助コンストラクタ（`ipc/protocol` の `newRpcParseError` と同じ形）。
  result = (ref RpcError)(msg: message, code: code, data: data)

proc newIpcServer*(path = ""): IpcServer =
  ## `path` が空なら `paths.ipcSocketPath()` を使う。
  ##
  ## **セキュリティ境界に関する注記**: このバージョンの powarder の IPC は
  ## 認証機構を一切持たない。ソケットファイルのパーミッションを 0600 にし、
  ## 所有者本人だけが接続できることだけを認証の代わりにしている
  ## （UDS はファイルシステムのパーミッションで到達可否が決まるため、これは
  ## Docker の `/var/run/docker.sock` と同じ設計判断である）。したがって
  ## ランタイムディレクトリ自体のパーミッションも重要になる
  ## （`core/paths.ensureRuntimeDir` が 0700 で作る前提に依存している）。
  let p = if path.len > 0: path else: ipcSocketPath()

  if path.len == 0:
    # 既定のソケットパスを使う場合のみ、ランタイムディレクトリの存在を保証する。
    # 呼び出し側が明示的な `path`（テスト用の短いパス等）を渡した場合は
    # そのパスの親ディレクトリの用意は呼び出し側の責務とみなし、ここでは
    # `runtimeDir()` とは無関係なディレクトリ作成を行わない。
    ensureRuntimeDir()

  # 既存ソケットの残骸を消す。`os.fileExists` は S_ISREG だけを見るので
  # ソケットには常に false を返す ―― 必ず `socketExists` を使うこと
  # （`core/paths.nim` の doc comment 参照）。
  if socketExists(p):
    removeFile(p)

  let sock = newAsyncSocket(AF_UNIX, SOCK_STREAM, IPPROTO_IP)
  sock.bindUnix(p)
  # bind 直後にパーミッションを絞る。bind から setFilePermissions までの間は
  # 理論上 window があるが、ランタイムディレクトリ自体が 0700
  # （所有者以外は辿れない）である前提なので実害は無い。
  setFilePermissions(p, {fpUserRead, fpUserWrite})
  sock.listen()

  result = IpcServer(socket: sock, path: p,
      handlers: initTable[string, RpcHandler](), closing: false)

proc register*(s: IpcServer; methodName: string; handler: RpcHandler) =
  s.handlers[methodName] = handler

proc handleClient(s: IpcServer; client: AsyncSocket) {.async.} =
  ## 1つの接続を処理する。
  ##
  ## **設計選択**: 「1 UDS 接続 = 1 論理コマンド」が基本設計だが、将来の拡張
  ## （同一接続での複数リクエスト）に備え、ここでは「接続が閉じられるまで
  ## 複数のリクエストを処理できるループ」として実装した。現状の CLI 側
  ## `client.call()` は毎回新しい接続を張って1リクエスト後に切断するので、
  ## 実際の通信パターンは変わらず「1接続=1コマンド」のまま動作する。
  try:
    while not s.closing:
      let line = await client.recvLine()
      if line.len == 0:
        break # 切断（`recvLine` は切断時に空文字列を返す）

      var req: RpcRequest
      var parseFailed = false
      try:
        req = decodeRequest(line)
      except RpcParseError as e:
        # id が分からない（壊れた行なので request の中身自体を復元できない）ため
        # 0 を使う。JSON-RPC 2.0 の仕様では null が正だが、`ipc/protocol` の
        # `encodeError` が `id: int` を必須にしているためこの妥協をする。
        parseFailed = true
        await client.send(encodeError(0, rpcParseError, e.msg) & "\n")

      if parseFailed:
        continue

      if req.methodName notin s.handlers:
        if req.id.isSome:
          await client.send(encodeError(req.id.get, rpcMethodNotFound,
              "method not found: " & req.methodName) & "\n")
        continue # notification なら応答自体を返さない

      var resJson: JsonNode = nil
      var errCode = 0
      var errMsg = ""
      var errData: JsonNode = nil
      var handlerFailed = false
      try:
        resJson = s.handlers[req.methodName](req.params)
      except RpcError as e:
        handlerFailed = true
        errCode = e.code
        errMsg = e.msg
        errData = e.data
      except CatchableError as e:
        # ハンドラが想定外の例外を投げてもデーモンを落とさない。
        # 1リクエストの失敗で常駐プロセスが死ぬのは論外なので、ここで確実に
        # 握り潰して `rpcInternalError` に変換する。
        handlerFailed = true
        errCode = rpcInternalError
        errMsg = e.msg
        errData = nil

      if req.id.isNone:
        continue # notification には応答を返さない

      if handlerFailed:
        await client.send(encodeError(req.id.get, errCode, errMsg, errData) & "\n")
      else:
        await client.send(encodeSuccess(req.id.get, resJson) & "\n")
  except CatchableError:
    # 送受信そのものが失敗した（クライアントが読み取り前に接続を切った等）。
    # この接続だけを諦めてサーバは動き続ける。
    discard
  finally:
    client.close()

proc pruneFinished(s: IpcServer) =
  ## 完了済みの `handleClient` Future を `s.conns` から取り除く。
  ## `handleClient` は自分自身で全ての例外を握り潰す設計だが、念のため
  ## 失敗した Future があればここで `readError` を読んで
  ## 「Future の例外が回収されなかった」という追加の警告を防ぐ。
  var alive: seq[Future[void]] = @[]
  for f in s.conns:
    if f.finished:
      if f.failed:
        discard f.readError
    else:
      alive.add f
  s.conns = alive

proc serve*(s: IpcServer) {.async.} =
  ## accept ループ。
  ##
  ## 1接続ごとに `handleClient` を `asyncCheck` ではなくこの `Future` 自体を
  ## `s.conns` に保持する形で起動する。`asyncCheck` だと Future への参照を
  ## 持たないため、`close()` 後に残っている接続を待ちたくなったときに手が
  ## 出せない。接続数は不定なので、ループの先頭で完了済みの Future を
  ## 間引く方式にした（`pruneFinished`）。
  ##
  ## `close()` でリスナーソケットを閉じると、待機中の `accept()` は
  ## OSError で失敗する。これを `s.closing` フラグで「意図した shutdown」と
  ## 区別し、shutdown ならループを正常に抜ける。
  while true:
    pruneFinished(s)
    var client: AsyncSocket
    try:
      client = await s.socket.accept()
    except CatchableError:
      if s.closing:
        break
      else:
        # リスナー自体が壊れた（想定外）。呼び出し元に伝播させる。
        raise
    s.conns.add handleClient(s, client)

proc close*(s: IpcServer) =
  ## `closing` を立ててからソケットを閉じ、ソケットファイルを削除する。
  ## 順序が重要: 先に `closing = true` にしないと、`socket.close()` が
  ## 引き起こす `accept()` の失敗を `serve()` が「異常」と誤判定してしまう。
  s.closing = true
  s.socket.close()
  if socketExists(s.path):
    removeFile(s.path)
