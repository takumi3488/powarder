## 内部エンドポイント（ssh が張った UDS、または TCP フォールバック）への接続。

import std/asyncdispatch
import std/asyncnet
import std/nativesockets
import powarder/core/types

type
  UpstreamUnhealthyError* = object of CatchableError
    ## 上流（UDS または TCP）への接続確立に失敗したことを表す。

proc dialUpstream*(target: UpstreamTarget): Future[AsyncSocket] {.async.} =
  ## `target` に接続し、確立済みの `AsyncSocket` を返す。
  ##
  ## `buffered = false` が重要: `acceptAddr` は accept した子ソケットに
  ## 親の `isBuffered` を継承するので、公開リスナー側も含めて unbuffered に
  ## 揃えておくと `recvInto`/`send` が内部バッファへの余分な `copyMem` を
  ## 経由しない。
  ##
  ## connect 失敗（`ECONNREFUSED` / `ENOENT` 等）は `std/asyncdispatch` の
  ## 実装が `retFuture.fail(newOSError(...))` するので `OSError` が飛ぶ。
  ## ここで捕まえて `UpstreamUnhealthyError` に変換し、ソケットは必ず close する。
  case target.kind
  of ukUnix:
    let sock = newAsyncSocket(AF_UNIX, SOCK_STREAM, IPPROTO_NONE,
        buffered = false)
    try:
      await sock.connectUnix(target.path)
    except CatchableError as e:
      sock.close()
      raise newException(UpstreamUnhealthyError,
          "UDS " & target.path & " への接続に失敗しました: " & e.msg)
    result = sock
  of ukTcp:
    let sock = newAsyncSocket(buffered = false)
    try:
      await sock.connect("127.0.0.1", target.port)
    except CatchableError as e:
      sock.close()
      raise newException(UpstreamUnhealthyError,
          "TCP 127.0.0.1:" & $target.port &
          " への接続に失敗しました: " & e.msg)
    result = sock

proc probeUpstream*(target: UpstreamTarget): Future[bool] {.async.} =
  ## 接続を試みて即 close し、成否を bool で返す（ヘルスチェック用）。
  ##
  ## **重要な既知の制約**: OpenSSH の `channels.c` の
  ## `channel_post_port_listener()` は `accept()` が成功した瞬間に
  ## （1バイトも送っていなくても）`port_open_helper()` を呼んでリモートへ
  ## `direct-tcpip` の `SSH_MSG_CHANNEL_OPEN` を送る。つまり
  ## **`probeUpstream` は必ず踏み台経由で宛先への実接続を発生させる**
  ## （回避不可能）。だから定期的なプローブはデフォルト無効にし、デーモン
  ## 起動時の adopt 判定など回数が限られる場面で使うこと。
  try:
    let sock = await dialUpstream(target)
    sock.close()
    result = true
  except UpstreamUnhealthyError:
    result = false
