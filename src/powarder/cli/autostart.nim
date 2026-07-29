## デーモンを「空気」にする自動起動ロジック。
##
## Docker が `docker run` の裏で `dockerd` を自動起動しないのは、`dockerd` が
## root 権限で動く特権マルチユーザーデーモンであり、うっかり起動させて良いもの
## ではないからである。powarder のデーモンは単一ユーザー・単一マシン内で完結する
## ローカルプロセスに過ぎず、この制約は当てはまらない。目指すのは tailscale の
## 体験（`tailscale up` を叩くだけで、裏で `tailscaled` が生きているかどうかを
## ユーザーがほぼ意識しない）であり、`ensureDaemon` はその心臓部になる。

import std/os
import powarder/ipc/client
import powarder/platform/daemonize
import powarder/core/paths

proc ensureDaemon*(noAutostart = false; timeoutMs = 5000): bool =
  ## デーモンが動いていなければ起動してポーリングで待つ。
  ##
  ## 手順:
  ## 1. `ipc/client.ping()` で生きているか確認する。生きていれば即 `true`。
  ## 2. `noAutostart` が true なら、ここで諦めて `false` を返す
  ##    （`--no-autostart` フラグの実体）。
  ## 3. 自分自身の実行ファイルパス（`os.getAppFilename()`）を使って
  ##    `platform/daemonize.spawnDetached(exe, ["daemon"])` でデーモンを起動する。
  ##    引数は `["daemon"]` のみで `"--foreground"` は付けない。
  ##    **理由**: `argv.nim` には `--foreground` というフラグ自体が定義されて
  ##    いない（未知のフラグとして `ArgvError` になり、起動直後の子プロセスが
  ##    即座に終了してしまう）。一方 `argv.parseArgv(["daemon"])` は
  ##    `subcommand == "daemon"`, `subsubcommand == ""` になり、`dispatch` 側は
  ##    「daemon のサブサブコマンドが空 = フォアグラウンドでデーモン本体を起動する」
  ##    という意味に解釈する（`cli/dispatch.nim` 参照）。つまり `["daemon"]` だけで
  ##    意図した起動経路に乗る。
  ## 4. 100ms 間隔で `ping()` をポーリングし、`timeoutMs` に達するまで待つ。
  ## 5. 起動を確認できたら `true`、タイムアウトしたら `false`。
  ##
  ## **`spawnDetached` の戻り値（中間プロセスの PID）をデーモンの PID だと
  ## 思ってはいけない。** 二重 fork の中間プロセスの PID であり、
  ## `spawnDetached` が返ってきた時点で既に `waitpid` 済み・実体は存在しない。
  ## デーモン自身の実際の PID を知りたい場合は
  ## `platform/lock.readPid(paths.lockPath())` を（このロックを保持していない
  ## 別プロセスから）読むこと。
  ##
  ## **なぜ `daemonize()` ではなく `spawnDetached()` を使うのか**: デーモンは
  ## `std/asyncdispatch`（`newAsyncSocket` 経由で IPC サーバーを listen する）を
  ## 使う。asyncdispatch が一度でも kqueue/epoll のようなイベント通知機構に
  ## 触れた**後**に `fork()` すると、子プロセスが継承した kqueue の fd は
  ## （macOS で実測した限り）壊れてしまい、以後の `accept()` が
  ## "Bad file descriptor" で失敗する。`daemonize()` は「呼び出したプロセス
  ## 自身」を二重 fork でデーモン化するため、この問題を踏む。一方
  ## `spawnDetached()` は二重 fork の末に `execvp()` でプロセスイメージを
  ## まるごと入れ替えるため、孫プロセスは asyncdispatch に一切触れていない
  ## まっさらな状態から起動する。したがって CLI プロセス自身をデーモン化する
  ## のではなく、**新しいプロセスとして** デーモンを起動する必要がある。
  if ping():
    return true
  if noAutostart:
    return false

  let exe = getAppFilename()

  # **デーモンの stdout/stderr は必ずログファイルへ向ける。**
  # 付け替えないと、起動したデーモンが CLI の stdout/stderr を継承したまま
  # 動き続け、`powarder up | tee log` や `$(powarder ps)` のようにパイプ／
  # コマンド置換で受けたときに**パイプの書き込み側が閉じず、CLI 自体は
  # 終了しているのにシェルが永久に待つ**（実測で踏んだ）。
  # ディレクトリが無いと open に失敗するので先に用意する。
  try:
    ensureStateDirs()
  except CatchableError:
    discard ## 作れなくても spawnDetached 側が /dev/null にフォールバックする
  discard spawnDetached(exe, ["daemon"], daemonLogPath())

  let pollIntervalMs = 100
  var waited = 0
  while waited < timeoutMs:
    os.sleep(pollIntervalMs)
    waited += pollIntervalMs
    if ping():
      return true
  false
