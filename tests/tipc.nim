## `powarder/ipc/server` と `powarder/ipc/client` の結合テスト。
##
## サーバは非同期（`std/asyncdispatch`）、クライアントは同期（`std/net`）という
## 組み合わせなので、同一プロセス内で `asyncCheck serve(s)` してから同期の
## `call()` を呼ぶと、`call()` の `recvLine` がブロックしている間イベント
## ループが一切回らずデッドロックする。
##
## これを回避するため、`tests/tplatform.nim` に倣い `posix.fork()` でサーバを
## 別プロセスとして起動する（他の2案 ―― サーバ側も同期の `std/net` にする /
## クライアント呼び出しを別スレッドにする ―― よりも、実物の `IpcServer` を
## そのままテストできる点を優先した）。子プロセスは `serve()` の accept
## ループに入ったまま親が `SIGKILL` するまで戻らない。子プロセスの終了に
## `quit()` を使うと Nim ランタイムの終了処理と `unittest` のグローバル状態を
## 巻き込んでしまい、子プロセスがテストスイートを二重実行してしまう
## （`tests/tplatform.nim` の注記の通り）ため、`posix.exitnow`（`_exit`）を使う。

import std/[unittest, os, posix, json, options, net, nativesockets, asyncdispatch]
import powarder/ipc/protocol
import powarder/ipc/server
import powarder/ipc/client
import powarder/core/paths

# デフォルトパス解決（`path` 省略時）に迷い込んだ場合でも実マシンで動いている
# かもしれない本物の powarder デーモンのソケットに触れないようにする安全策。
# 各テストは明示的な短いパスを使うので通常はここに依存しないが、念のため。
putEnv(envRuntimeDir, getTempDir() / "pw-ipc-test-rt")

proc pingHandler(params: JsonNode): JsonNode =
  %*{"pong": true}

proc forkTestServer(path: string;
    setup: proc(s: IpcServer) {.closure, gcsafe.}): Pid =
  ## 子プロセスとしてテスト用サーバを起動する。
  ## 子プロセスは `serve()` の accept ループに入ったまま戻らないので、
  ## 呼び出し側は必ず `stopTestServer` で `SIGKILL` して終了させること。
  let pid = fork()
  if pid == 0:
    try:
      let s = newIpcServer(path)
      setup(s)
      waitFor serve(s)
    except CatchableError:
      discard
    exitnow(0)
  pid

proc waitForSocket(path: string; maxMs = 2000) =
  ## `fork()` 直後は子プロセスがまだ bind し終えていない可能性があるので、
  ## ソケットファイルが実際に現れるまで短く待つ。
  var waited = 0
  while not socketExists(path) and waited < maxMs:
    os.sleep(10)
    waited += 10

proc stopTestServer(pid: Pid; path: string) =
  ## サーバプロセスを終了し、ソケットファイルの残骸を消す。
  ## `SIGKILL` された子は自分でソケットファイルを片付ける機会が無いため、
  ## 後始末はテスト（親プロセス）の責務にする。
  discard kill(pid, SIGKILL)
  var status: cint
  discard waitpid(pid, status, 0)
  removeFile(path)

proc newRawUnixSocket(): Socket =
  ## `std/posix` を同じファイルで import すると `AF_UNIX` 等の enum 値が
  ## posix の同名 `cint` 定数とあいまいになるため、`nativesockets` 側を
  ## 明示的に修飾する（`ipc/client.nim` と同じ回避策）。
  newSocket(nativesockets.AF_UNIX, nativesockets.SOCK_STREAM,
      nativesockets.IPPROTO_IP)

# ---------------------------------------------------------------------------
# 1. 正常な RPC 往復
# ---------------------------------------------------------------------------

suite "server/client: 正常な RPC 往復":
  test "daemon.ping を登録して call が結果を返す":
    const path = "/tmp/pw-t1.sock"
    removeFile(path)
    let pid = forkTestServer(path, proc(s: IpcServer) =
      s.register(mDaemonPing, pingHandler))
    waitForSocket(path)
    try:
      let res = call(mDaemonPing, path = path)
      check res == %*{"pong": true}
    finally:
      stopTestServer(pid, path)

# ---------------------------------------------------------------------------
# 2. ソケットのパーミッションが 0600
# ---------------------------------------------------------------------------

suite "server: ソケットのパーミッション":
  test "newIpcServer が作るソケットは 0600":
    const path = "/tmp/pw-t2.sock"
    removeFile(path)
    # **重要**: `newIpcServer` は内部で `AsyncSocket` を生成する。この
    # unittest 本体プロセス（親）で一度でも `AsyncSocket` に触れると、Nim の
    # asyncdispatch のグローバル dispatcher（kqueue fd を保持する）が親の中で
    # 初期化されてしまい、以後 `fork()` する全ての子プロセスがその
    # kqueue fd を「継承」してしまう。すると子プロセス側の `accept()` が
    # "Bad file descriptor" で失敗するようになる（実測で確認済みのバグ）。
    # そのため `newIpcServer` は必ずこの子プロセスの中だけで呼び、判定結果は
    # `unittest.check`（親の集計にしか乗らない）ではなく exit code で親に返す。
    let pid = fork()
    if pid == 0:
      let ok =
        try:
          let s = newIpcServer(path)
          let permsOk = getFilePermissions(path) == {fpUserRead, fpUserWrite}
          s.close()
          permsOk
        except CatchableError:
          false
      exitnow(if ok: 0 else: 1)
    var status: cint
    discard waitpid(pid, status, 0)
    check WEXITSTATUS(status) == 0
    removeFile(path)

# ---------------------------------------------------------------------------
# 3. 未登録メソッド
# ---------------------------------------------------------------------------

suite "server/client: 未登録メソッド":
  test "RpcRemoteError の code が rpcMethodNotFound になる":
    const path = "/tmp/pw-t3.sock"
    removeFile(path)
    let pid = forkTestServer(path, proc(s: IpcServer) =
      s.register(mDaemonPing, pingHandler))
    waitForSocket(path)
    try:
      try:
        discard call("no.such.method", path = path)
        fail()
      except RpcRemoteError as e:
        check e.code == rpcMethodNotFound
    finally:
      stopTestServer(pid, path)

# ---------------------------------------------------------------------------
# 4. ハンドラが RpcError を投げた場合
# ---------------------------------------------------------------------------

suite "server/client: ハンドラが RpcError を投げる":
  test "code がクライアント側の RpcRemoteError.code に届く":
    const path = "/tmp/pw-t4.sock"
    removeFile(path)
    let pid = forkTestServer(path, proc(s: IpcServer) =
      s.register("tunnel.boom", proc(params: JsonNode): JsonNode =
        raise newRpcError(errTunnelNotFound, "tunnel not found")))
    waitForSocket(path)
    try:
      try:
        discard call("tunnel.boom", path = path)
        fail()
      except RpcRemoteError as e:
        check e.code == errTunnelNotFound
        check e.msg == "tunnel not found"
    finally:
      stopTestServer(pid, path)

# ---------------------------------------------------------------------------
# 5. ハンドラが予期しない例外を投げてもサーバが死なない
# ---------------------------------------------------------------------------

suite "server: ハンドラの想定外の例外":
  test "rpcInternalError になり、その後も次のリクエストを処理できる":
    const path = "/tmp/pw-t5.sock"
    removeFile(path)
    let pid = forkTestServer(path, proc(s: IpcServer) =
      s.register(mDaemonPing, pingHandler)
      s.register("boom.unexpected", proc(params: JsonNode): JsonNode =
        raise newException(ValueError, "boom")))
    waitForSocket(path)
    try:
      try:
        discard call("boom.unexpected", path = path)
        fail()
      except RpcRemoteError as e:
        check e.code == rpcInternalError

      # サーバプロセスが生き延びていることを、別の接続で改めて確認する
      # （1接続=1コマンドなので同じ接続の使い回しではなく新しい call）。
      let res = call(mDaemonPing, path = path)
      check res == %*{"pong": true}
    finally:
      stopTestServer(pid, path)

# ---------------------------------------------------------------------------
# 6. 壊れた行
# ---------------------------------------------------------------------------

suite "server: 壊れた行":
  test "rpcParseError が返る":
    const path = "/tmp/pw-t6.sock"
    removeFile(path)
    let pid = forkTestServer(path, proc(s: IpcServer) =
      s.register(mDaemonPing, pingHandler))
    waitForSocket(path)
    try:
      # `client.call` は常に正しい JSON をエンコードしてしまうため、壊れた行を
      # 送るにはここだけ生のソケットを使う。
      var raw = newRawUnixSocket()
      raw.connectUnix(path)
      raw.send("not json at all\n")
      let line = raw.recvLine()
      raw.close()
      let resp = decodeResponse(line)
      check resp.error.isSome
      check resp.error.get.code == rpcParseError
    finally:
      stopTestServer(pid, path)

# ---------------------------------------------------------------------------
# 7. デーモンが起動していないとき (ENOENT)
# ---------------------------------------------------------------------------

suite "client: デーモンが起動していない (ENOENT)":
  test "ソケットファイルが無ければ DaemonNotRunningError":
    const path = "/tmp/pw-t7.sock"
    removeFile(path)
    try:
      discard call(mDaemonPing, path = path)
      fail()
    except DaemonNotRunningError:
      discard

# ---------------------------------------------------------------------------
# 8. 残骸ソケットだけがあるとき (ECONNREFUSED)
# ---------------------------------------------------------------------------

suite "client: 残骸ソケットだけがある (ECONNREFUSED)":
  test "DaemonNotRunningError になり、かつ残骸ファイルは消されない":
    const path = "/tmp/pw-t8.sock"
    removeFile(path)
    # bind はするが listen しない = クラッシュしたデーモンの残骸を再現する。
    var stale = newRawUnixSocket()
    stale.bindUnix(path)
    stale.close()
    check socketExists(path) # 前提: ここで既に「残骸ソケット」になっている

    try:
      discard call(mDaemonPing, path = path)
      fail()
    except DaemonNotRunningError:
      discard

    check socketExists(path) # クライアントは残骸を消してはいけない
    removeFile(path)

# ---------------------------------------------------------------------------
# 9. ping() は例外を投げず bool を返す
# ---------------------------------------------------------------------------

suite "client: ping":
  test "デーモンが無いとき false を返す（例外を投げない）":
    const path = "/tmp/pw-t9a.sock"
    removeFile(path)
    check ping(path = path) == false

  test "デーモンが有るとき true を返す（例外を投げない）":
    const path = "/tmp/pw-t9b.sock"
    removeFile(path)
    let pid = forkTestServer(path, proc(s: IpcServer) =
      s.register(mDaemonPing, pingHandler))
    waitForSocket(path)
    try:
      check ping(path = path) == true
    finally:
      stopTestServer(pid, path)

# ---------------------------------------------------------------------------
# 10. newIpcServer が既存の残骸ソケットを消して bind できる
# ---------------------------------------------------------------------------

suite "server: 残骸ソケットの掃除":
  test "socketExists を使って残骸を消してから bind する":
    const path = "/tmp/pw-t10.sock"
    removeFile(path)
    # 残骸を作る側は `std/net` の同期ソケットなので dispatcher には触れない
    # （問題ない）。`os.fileExists` は S_ISREG しか見ないためソケットには
    # false を返す。`newIpcServer` が `fileExists` で残骸判定していたら、
    # この既存ソケットを消さないまま `bindUnix` を呼んで `EADDRINUSE` の
    # `OSError` で失敗するはず。
    var stale = newRawUnixSocket()
    stale.bindUnix(path)
    stale.close()
    check socketExists(path)

    # `newIpcServer` 自体は（上のスイートと同じ理由で）子プロセスの中だけで
    # 呼ぶ。判定結果は exit code で親に返す。
    let pid = fork()
    if pid == 0:
      let ok =
        try:
          let s = newIpcServer(path)
          let existedAfterBind = socketExists(path)
          let permsOk = getFilePermissions(path) == {fpUserRead, fpUserWrite}
          s.close()
          let removedAfterClose = not socketExists(path)
          existedAfterBind and permsOk and removedAfterClose
        except CatchableError:
          false
      exitnow(if ok: 0 else: 1)
    var status: cint
    discard waitpid(pid, status, 0)
    check WEXITSTATUS(status) == 0
    removeFile(path) # 念のため

# ---------------------------------------------------------------------------
# 追加（必須の10件には無いが、`call` の doc comment に明記した挙動なので
# 併せて検証する）: タイムアウト
# ---------------------------------------------------------------------------

suite "client: タイムアウト":
  test "応答が timeoutMs 以内に届かないと IpcClientError":
    const path = "/tmp/pw-t11.sock"
    removeFile(path)
    # ハンドラは同期 proc なので、ここで `os.sleep` するとサーバの
    # シングルスレッドイベントループそのものを止める。応答が返らない状況を
    # 手軽に再現するのに使う（実際のハンドラでこれをやってはいけない）。
    let pid = forkTestServer(path, proc(s: IpcServer) =
      s.register("slow.method", proc(params: JsonNode): JsonNode =
        os.sleep(500)
        %*{"ok": true}))
    waitForSocket(path)
    try:
      try:
        discard call("slow.method", path = path, timeoutMs = 100)
        fail()
      except RpcRemoteError:
        fail() # ここに来たら「サーバは速く応答した」ことになり想定と違う
      except IpcClientError:
        discard # タイムアウトで IpcClientError になることを期待している
    finally:
      stopTestServer(pid, path)
