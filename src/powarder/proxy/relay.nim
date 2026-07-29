## クライアントソケットと上流ソケットの間の双方向バイト中継。

import std/asyncdispatch
import std/asyncnet

const
  RelayBufSize* = 16384 ## SSH チャネルの1メッセージ最大ペイロードが概ね 16KB のため

proc pump(src, dst: AsyncSocket; buf: pointer; bufLen: int;
          onBytes: proc (n: int) {.closure, gcsafe.}) {.async.} =
  ## `src` から読んで `dst` へそのまま流す片方向ループ。
  ##
  ## `recvInto` は切断されていてデータが無い場合に例外を投げず `0` を返す。
  ## さらに既定フラグ `{SocketFlag.SafeDisconn}` では `ECONNRESET` / `EPIPE` /
  ## `ENETRESET` も EOF 相当（`0`）として扱われるため、`if n <= 0: break` だけで
  ## 正常系・異常切断系の両方をカバーできる。
  while true:
    let n = await src.recvInto(buf, bufLen)
    if n <= 0: break
    await dst.send(buf, n)
    onBytes(n)

proc relay*(client, upstream: AsyncSocket;
            onRx, onTx: proc (n: int) {.closure, gcsafe.}) {.async.} =
  ## `client` <-> `upstream` を中継する。片方が EOF になったら両方閉じる
  ## （half-close は扱わない。SSH のポートフォワード越しで half-close を
  ## 活かすアプリはほぼ無く、コードが大幅に単純になるため）。
  ##
  ## `recvInto`（string を返す `recv` ではなく）+ 接続の生存期間中つかい回す
  ## 事前確保バッファを使い、毎回のアロケーションを避ける。
  var bufA = newString(RelayBufSize)
  var bufB = newString(RelayBufSize)
  let c2u = pump(client, upstream, addr bufA[0], RelayBufSize, onRx)
  let u2c = pump(upstream, client, addr bufB[0], RelayBufSize, onTx)
  await c2u or u2c
  # AsyncSocket.close() は冪等（`if socket.closed: return`）なので二重 close も安全。
  client.close()
  upstream.close()
  # 片方が終わった後、もう一方の Future を放置すると未処理 Future の警告が
  # 出るので、close() 後に明示的に await し、例外は握りつぶす。
  try: await c2u
  except CatchableError: discard
  try: await u2c
  except CatchableError: discard
