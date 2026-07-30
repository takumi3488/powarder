import std/[unittest, os, posix, options, osproc, strutils]
import powarder/platform/lock
import powarder/platform/procinfo
import powarder/platform/daemonize

suite "lock: 基本的な取得・解放":

  test "release 後に再取得できる":
    let path = "/tmp/pw-lock-basic.lock"
    removeFile(path)
    let lock1 = acquireSingletonLock(path)
    lock1.release()
    let lock2 = acquireSingletonLock(path)
    lock2.release()
    removeFile(path)

  test "release は冪等（二重に呼んでも落ちない）":
    let path = "/tmp/pw-lock-idem.lock"
    removeFile(path)
    let lock = acquireSingletonLock(path)
    lock.release()
    lock.release() # ここで例外にならないこと
    removeFile(path)

  test "writePid / readPid の往復":
    let path = "/tmp/pw-lock-pid.lock"
    removeFile(path)
    let lock = acquireSingletonLock(path)
    lock.writePid(12345)
    check readPid(path) == some(12345)
    lock.release()
    removeFile(path)

  test "readPid: ファイルが無ければ none":
    let path = "/tmp/pw-lock-nofile.lock"
    removeFile(path)
    check readPid(path).isNone

suite "lock: プロセス間の排他（fork を使う）":
  ## fcntl のアドバイザリロックはプロセス単位なので、同一プロセス内で2回
  ## 取得しても成功してしまう。多重起動防止を検証するには別プロセスが必要な
  ## ので fork() を使う。子プロセスの終了には quit() ではなく
  ## posix.exitnow（_exit）を使う。quit() は Nim ランタイムの終了処理と
  ## unittest のグローバル状態を巻き込んでしまい、子プロセスがテストスイートを
  ## 二重実行してしまう。

  test "別プロセスからは同じロックを取得できない":
    let lockFile = "/tmp/pw-lock-cross.lock"
    removeFile(lockFile)
    let lock = acquireSingletonLock(lockFile)

    let pid = fork()
    if pid == 0:
      # 子プロセス: 取得できなければ 0、できてしまったら 1 で終了する
      let got = tryAcquireSingletonLock(lockFile)
      exitnow(if got.isSome: 1 else: 0)

    var status: cint
    discard waitpid(pid, status, 0)
    check WEXITSTATUS(status) == 0

    lock.release()
    removeFile(lockFile)

  test "SIGKILL されたプロセスのロックはカーネルが解放する":
    let lockFile = "/tmp/pw-lock-sigkill.lock"
    removeFile(lockFile)

    let pid = fork()
    if pid == 0:
      # 子プロセス: ロックを取得したまま親からの SIGKILL を待つ。
      # 万一 SIGKILL が届かなくてもテストが無限に固まらないよう、上限
      # (100 * 50ms = 5秒) を設けてから抜ける。
      discard tryAcquireSingletonLock(lockFile)
      for i in 0 ..< 100:
        os.sleep(50)
      exitnow(2) # 通常はここに来る前に SIGKILL で終了しているはず

    os.sleep(200) # 子がロックを取得し終えるのを待つ
    discard kill(pid, SIGKILL)
    var status: cint
    discard waitpid(pid, status, 0)

    # 子が SIGKILL で終了した時点でカーネルがロックを解放しているはずなので、
    # 親（このプロセス）から取得できる。PID ファイル方式ならここで
    # 「stale なファイルが残る」問題が起きるが、fcntl ロックは起きない。
    let got = tryAcquireSingletonLock(lockFile)
    check got.isSome
    got.get.release()
    removeFile(lockFile)

suite "procinfo: 生存確認":

  test "pidAlive(getpid()) は true":
    check pidAlive(getpid().int)

  test "pidAlive(存在しない大きな PID) は false":
    check not pidAlive(999999)

suite "procinfo: コマンドライン取得":

  test "自分自身の cmdline が取れる":
    let cmd = processCmdline(getpid().int)
    check cmd.len > 0

suite "procinfo: 長い引数列と cmdlineMatches":

  test "-ww で長い引数列も切り詰められずに取得でき、cmdlineMatches が正しく判定する":
    # powarder が起動する ssh は `-o BatchMode=yes -o ControlPersist=no ...` の
    # ように長い引数列を持つ。ps がデフォルトで切り詰める長さを超える引数列を
    # 持つ子プロセスを起動し、-ww 付きで末尾まで取得できることを確認する。
    #
    # `sh -c "..."` 越しに起動すると、シェルが「最後の単純コマンドを exec に
    # 置き換える」最適化（tail call）を行い、sh 自身に渡した余分な引数が
    # 実行後の argv から消えてしまう（実際にこれで一度失敗した）。そのため、
    # シェルを介さず `/bin/cat -` を直接起動する。先頭の "-" で標準入力待ちに
    # なってブロックし続けるので、後続の引数を cat が処理しようとすることも
    # なく、渡した argv がそのまま cmdline に残る。
    # ダミー引数を `--` で始めてはいけない。**GNU coreutils の `cat`（Linux）は
    # `--dummy-...` を不正な長オプションと解釈して即座にエラー終了する**ため、
    # `processCmdline` を呼ぶ前にプロセスが消えてしまう（BSD `cat`（macOS）は
    # 長オプションを持たずファイル名として扱うので、この差で Linux だけ落ちた）。
    # `-` を先頭に置いてあるので `cat` は stdin を待ってブロックし続け、
    # 後続の引数をファイルとして開こうとはしない。
    var args = @["-"]
    for i in 0 ..< 20:
      args.add("dummy-argument-" & $i & "-" & "x".repeat(20))
    args.add("POWARDER_END_MARKER")

    let p = startProcess("/bin/cat", args = args)
    let pid = p.processID
    os.sleep(200) # ps に反映されるまでの猶予

    let cmd = processCmdline(pid)
    check "POWARDER_END_MARKER" in cmd

    check cmdlineMatches(pid, ["POWARDER_END_MARKER"])
    check not cmdlineMatches(pid, ["this-marker-does-not-exist-zzz"])

    p.kill()
    discard p.waitForExit()
    p.close()

suite "daemonize: spawnDetached":
  ## daemonize() 自体は呼び出し元プロセスを quit(0) させてしまうため unittest
  ## 内で直接は呼べない（テストプロセスごと落ちる）。同じ二重 fork + setsid の
  ## 機構を使う spawnDetached() の方で「呼び出し元の子ではなくなっている」ことを
  ## 検証する。daemonize() 自体の手動検証手順は報告に記載する。

  test "起動したプロセスは呼び出し元の子ではなくなる（親から独立する）":
    let markerFile = "/tmp/pw-spawn-marker"
    removeFile(markerFile)

    # $$ は exec 後の実プロセス（孫プロセス）自身の PID になる
    let scriptArgs = ["-c", "echo $$ > " & markerFile & "; sleep 3"]
    let intermediatePid = spawnDetached("/bin/sh", scriptArgs)
    check intermediatePid > 0 # 中間プロセスの PID（既に終了済み。doc 参照）

    var waited = 0
    while not fileExists(markerFile) and waited < 2000:
      os.sleep(50)
      waited += 50
    check fileExists(markerFile)

    let daemonPid = parseInt(readFile(markerFile).strip())

    # 孫プロセスが自分（テストプロセス）の子ではなくなっている
    # （= init/launchd に養子縁組されている）ことを、実際の PPID を ps で
    # 確認して検証する。
    let ppidOut = execProcess("ps", args = ["-o", "ppid=", "-p", $daemonPid],
                              options = {poUsePath}).strip()
    check ppidOut.len > 0
    let ppid = parseInt(ppidOut)
    check ppid != getpid().int

    discard kill(Pid(daemonPid), SIGKILL)
    removeFile(markerFile)
