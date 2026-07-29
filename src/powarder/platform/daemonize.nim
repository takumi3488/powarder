## バックグラウンド化（デーモン化）。
##
## CLI がデーモン未起動を検知したときに、自分でデーモンプロセスを起動して端末から
## 切り離すために使う。`daemonize()` は「呼び出したプロセス自身」を二重 fork で
## デーモン化する。`spawnDetached()` は「別の実行ファイル」を完全に切り離して
## 起動する（呼び出し元の CLI プロセス自身はそのまま生き続ける）。

import std/[os, posix]

proc daemonize*(keepCwd = false) =
  ## 二重 fork + `setsid()` で端末から切り離す。**親プロセス（およびセッション
  ## リーダーになった中間プロセス）は `quit(0)` して戻ってこない。** 呼び出す側は
  ## 「この呼び出しから戻ってきたら、それは二重 fork の末に残った孫プロセスである」
  ## という前提でコードを書くこと。
  ##
  ## 手順:
  ## 1. 1 回目の `fork()`。親は `quit(0)` で抜ける。子は `setsid()` を呼び、制御
  ##    端末を持たない新しいセッションのリーダーになる。
  ## 2. 2 回目の `fork()`。セッションリーダー自身も `quit(0)` で抜ける。残った孫は
  ##    「セッションリーダーではない」プロセスになるため、以後どんな経路でも新たに
  ##    制御端末を獲得できなくなる（SVr4 系 OS ではセッションリーダーが端末デバイス
  ##    を open すると自動的にそれが制御端末になってしまう。この経路を構造的に
  ##    塞ぐのが二重 fork の目的）。
  ## 3. `umask(0)`: 継承したファイル作成マスクの影響を受けないようにする。
  ## 4. `chdir("/")`（`keepCwd` が true のときは省略）: カレントディレクトリを
  ##    手放し、デーモンプロセスの存在によってファイルシステムのアンマウントが
  ##    妨げられないようにする。
  ## 5. fd 0/1/2 を `/dev/null` に向け直し、端末に対する読み書きを一切残さない。
  let pid1 = fork()
  if pid1 < 0:
    raiseOSError(osLastError(), "fork (1st)")
  if pid1 > 0:
    quit(0)

  if setsid() < 0:
    raiseOSError(osLastError(), "setsid")

  let pid2 = fork()
  if pid2 < 0:
    raiseOSError(osLastError(), "fork (2nd)")
  if pid2 > 0:
    quit(0)

  discard umask(0)
  if not keepCwd:
    discard chdir("/")

  let devNull = posix.open("/dev/null", O_RDWR)
  if devNull >= 0:
    discard dup2(devNull, 0)
    discard dup2(devNull, 1)
    discard dup2(devNull, 2)
    if devNull > 2:
      discard close(devNull)

proc spawnDetached*(exePath: string; args: openArray[string];
                    logPath = ""): int =
  ## `exePath` を `args` 付きで、呼び出し元から完全に切り離して起動する。
  ##
  ## 内部で二重 fork を行い、最終的に `exePath` を exec した「孫プロセス」は init
  ## （PID 1、あるいは macOS では launchd）に養子縁組されるため、呼び出し元
  ## プロセスが終了しても道連れにならずに動き続ける。
  ##
  ## **`logPath` を必ず渡すこと（空なら `/dev/null`）。**
  ## exec 前に fd 0/1/2 を付け替えないと、起動されたデーモンは**呼び出し元 CLI の
  ## stdout/stderr を継承したまま動き続ける**。すると `powarder up | tee log` や
  ## `$(powarder ps)` のようにパイプ／コマンド置換で受けたときに、
  ## **パイプの書き込み側が閉じないため読み手が EOF を検出できず、CLI 自体は
  ## 終了しているのにシェルが永久に待つ**という現象が起きる（実測で踏んだ）。
  ##
  ## この付け替えを `exePath` 側の `daemonize()` に任せる設計にはできない。
  ## powarder のデーモンは asyncdispatch を使うため、
  ## 「asyncdispatch を触った後に `fork()` すると子の kqueue fd が壊れる」問題を
  ## 避けて `daemonize()` を呼ばない方針になっており、**リダイレクトする主体が
  ## どこにも居なくなる**。だからここで（exec の直前・fork の後に）行う。
  ##
  ## **戻り値は「中間プロセス」の PID であり、最終的に起動されたデーモン自身の PID
  ## とは一致しない。** これは `ssh -f` や `ControlPersist` が二重 fork によって
  ## `startProcess` の追跡から外れてしまう問題（powarder が他の場所では意図的に
  ## 避けている挙動）と同じ機構を、ここでは逆に意図的に使っているために生じる制約
  ## である。中間プロセスは孫を起動した直後に終了し、このプロシージャが返る前に
  ## `waitpid` で刈り取り済みなので、戻り値の PID は**既に存在しないプロセスを
  ## 指している**。デーモン自身の実際の PID を知りたい場合は、デーモン側が
  ## `lock.writePid()` でロックファイルに書いた値を `lock.readPid()` で読むこと
  ## （この戻り値を PID として信用してはいけない）。
  let pid1 = fork()
  if pid1 < 0:
    raiseOSError(osLastError(), "fork (1st)")

  if pid1 == 0:
    # 中間プロセス。ここで quit() を使うと、呼び出し元プロセスが持っていた Nim
    # ランタイムの終了処理（GC・atexit 相当の処理）をこの fork されたコピーでも
    # 走らせてしまうため、必ず posix.exitnow（_exit(2)）で抜ける。
    if setsid() < 0:
      exitnow(1)
    let pid2 = fork()
    if pid2 < 0:
      exitnow(1)
    if pid2 == 0:
      # 孫プロセス: fd を付け替えてから exePath に exec する。
      # プロセスイメージがまるごと置き換わるので、以後は exePath 自身の
      # プロセスとして動く（開いた fd は exec をまたいで引き継がれる）。
      #
      # stdin は常に /dev/null。stdout/stderr は logPath（空なら /dev/null）へ。
      # **ここを省くと呼び出し元のパイプを掴んだままになり、シェルがハングする**
      # （この proc の doc comment を参照）。
      let inFd = posix.open("/dev/null".cstring, O_RDONLY)
      if inFd >= 0:
        discard dup2(inFd, 0)
        if inFd > 2: discard close(inFd)

      let outTarget = if logPath.len > 0: logPath else: "/dev/null"
      # 追記で開く（デーモンのログを前回分に足していく）。作成時は 0600。
      let outFd = posix.open(outTarget.cstring,
                             O_WRONLY or O_CREAT or O_APPEND, 0o600)
      if outFd >= 0:
        discard dup2(outFd, 1)
        discard dup2(outFd, 2)
        if outFd > 2: discard close(outFd)
      else:
        # ログを開けなくても標準出力を掴み続けるのは避ける（ハングの原因になる）。
        let nullFd = posix.open("/dev/null".cstring, O_WRONLY)
        if nullFd >= 0:
          discard dup2(nullFd, 1)
          discard dup2(nullFd, 2)
          if nullFd > 2: discard close(nullFd)

      var argv = @[exePath]
      for a in args:
        argv.add a
      discard execvp(exePath.cstring, allocCStringArray(argv))
      exitnow(127) # ここに来るのは exec 自体が失敗したときだけ
    else:
      exitnow(0) # 中間プロセスは孫を起動したら即座に終了する

  var status: cint
  discard waitpid(pid1, status, 0)
  pid1.int
