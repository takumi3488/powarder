## 公開リスナー（ユーザーが指定した bind アドレス:ポート）の accept ループ。

import std/asyncdispatch
import std/asyncnet
import std/nativesockets
import powarder/core/types
import powarder/proxy/stats
import powarder/proxy/upstream
import powarder/proxy/relay

type
  ForwardProxy* = ref object
    listener*: AsyncSocket
    target*: UpstreamTarget
    stats*: ForwardStats
    maxConns*: int
    closing*: bool

proc newForwardProxy*(bindAddr: string; bindPort: Port; target: UpstreamTarget;
                      maxConns = defaultMaxConns): ForwardProxy =
  ## 公開リスナーを bind & listen する。**bind に失敗したら例外をそのまま
  ## 投げる**（「ローカルポートが既に使われている」をここで検出するのが
  ## 正しい層。ssh 側ではなく powarder 側がユーザー指定ポートを bind する
  ## ため）。
  let domain = if bindAddr.contains(':'): AF_INET6 else: AF_INET
  let listener = newAsyncSocket(domain, buffered = false)
  listener.setSockOpt(OptReuseAddr, true)
  listener.bindAddr(bindPort, bindAddr)
  listener.listen()
  ForwardProxy(listener: listener, target: target, stats: newForwardStats(),
               maxConns: maxConns, closing: false)

proc handleConnection(p: ForwardProxy; client: AsyncSocket) {.async.} =
  ## 1接続分のハンドラ。同時接続数の上限を超えていれば即 close、
  ## 上流への接続に失敗してもクライアントを即 close する
  ## （生 TCP 中継なのでクライアントにエラーを意味的に伝える手段は無く、
  ## 即 close が唯一の選択）。
  if p.stats.activeConns >= p.maxConns:
    p.stats.recordRejected()
    client.close()
    return

  let (peerAddr, peerPort) = client.getPeerAddr()
  p.stats.recordConnect(peerAddr, peerPort)

  var upstream: AsyncSocket
  try:
    upstream = await dialUpstream(p.target)
  except UpstreamUnhealthyError:
    p.stats.recordFailed()
    p.stats.recordDisconnect()
    client.close()
    return

  let stats = p.stats
  proc onRx(n: int) {.closure, gcsafe.} = stats.recordRx(n)
  proc onTx(n: int) {.closure, gcsafe.} = stats.recordTx(n)

  await relay(client, upstream, onRx, onTx)
  p.stats.recordDisconnect()

proc serve*(p: ForwardProxy) {.async.} =
  ## accept ループ。1接続ごとに `asyncCheck` でハンドラを起動する。
  ##
  ## `close()` がリスナーを閉じると保留中の `acceptAddr` は例外を投げるので、
  ## `closing` フラグを見て正常終了（ループを抜ける）と本物の accept 失敗を
  ## 区別する。
  while not p.closing:
    try:
      let conn = await p.listener.acceptAddr()
      asyncCheck handleConnection(p, conn.client)
    except CatchableError:
      if p.closing:
        break
      else:
        raise

proc close*(p: ForwardProxy) =
  ## `closing = true` にしてリスナーを閉じる。accept ループは `closing` を
  ## 見て抜ける。
  p.closing = true
  p.listener.close()

proc retarget*(p: ForwardProxy; target: UpstreamTarget) =
  ## フォワードの宛先が変わったとき、新しい上流に切り替える。
  ## 既存の接続は旧 target のまま流し続け（すでに `dialUpstream` 済みの
  ## ソケットを握っているため）、新規接続だけが新 target に向く。
  ## ほぼ無停止で切り替えられる。
  p.target = target
