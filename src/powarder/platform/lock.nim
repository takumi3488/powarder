## 多重起動防止（シングルトンロック）。
##
## PID ファイルではなく `fcntl` のアドバイザリロック（`F_SETLK` / `F_WRLCK`）を
## 多重起動判定の主機構にする。PID ファイル方式には
## - プロセスが SIGKILL で死んだ後もファイルが残る（stale ファイル）
## - PID の再利用による誤検知（別プロセスが偶然同じ PID を持ってしまう）
## という古典的な弱点があるが、`fcntl` のアドバイザリロックはロックを保持した
## プロセスが（SIGKILL であっても）終了すれば **カーネルが自動的に解放する** ため、
## stale 状態が原理的に発生しない。
##
## `flock(2)` の Nim バインディングは標準ライブラリに存在しないが、`fcntl` と
## `F_SETLK` / `F_WRLCK` / `Tflock` 構造体は `std/posix` に揃っているのでそちらを使う。
##
## **重要な注意（fcntl ロックの罠）**: POSIX の fcntl レコードロックは
## 「プロセス単位」で管理される。そのため、ロックを保持したまま同じプロセスが
## 同じファイルを別の fd で開き、**どちらか一方の fd だけを close しても、その
## プロセスが持つそのファイルへの全ロックが解放されてしまう**（close に使った fd が
## ロック取得に使ったものかどうかは関係ない）。したがって、ロックを保持している間は
## そのロックファイルに対して `readPid` のような別経路の open/close を行っては
## いけない。`readPid` は「このロックを保持していない別プロセス」から状態を
## 覗き見る用途を想定している（`writePid` は保持中の `lock.fd` をそのまま使って
## 書き込むのでこの罠を踏まない）。

import std/[options, posix, os, strutils]

type
  SingletonLock* = object
    fd*: FileHandle
    path*: string

  SingletonLockError* = object of CatchableError
    ## `acquireSingletonLock` が、既に他プロセスがロックを保持していて
    ## 取得できなかったときに投げる。

proc isHeldByOther(errCode: OSErrorCode): bool =
  ## `F_SETLK` が既存のロックと衝突したときに返す errno。
  ## POSIX はどちらを返すかを実装依存としているため両方を見る。
  cint(errCode) == EACCES or cint(errCode) == EAGAIN

proc tryAcquireSingletonLock*(path: string): Option[SingletonLock] =
  ## `path` に対してアドバイザリロック（排他・ファイル全体）の取得を試みる。
  ##
  ## - 取得できた: `Some(SingletonLock)`。
  ## - 既に他プロセスが保持している（errno が `EACCES` / `EAGAIN`）: `none`。
  ## - それ以外の失敗（open できない、fcntl がそれ以外のエラーを返す等）:
  ##   `OSError` を投げる。
  let fd = posix.open(path.cstring, O_CREAT or O_RDWR, 0o600)
  if fd < 0:
    raiseOSError(osLastError(), path)

  var fl: Tflock
  fl.l_type = F_WRLCK.cshort
  fl.l_whence = SEEK_SET.cshort
  fl.l_start = 0
  fl.l_len = 0 # 0 はファイル全体を意味する

  if fcntl(fd, F_SETLK, addr fl) == -1:
    let err = osLastError()
    discard close(fd)
    if isHeldByOther(err):
      return none(SingletonLock)
    raiseOSError(err, path)

  some(SingletonLock(fd: fd, path: path))

proc acquireSingletonLock*(path: string): SingletonLock =
  ## `tryAcquireSingletonLock` の、取得できなかった場合に
  ## `SingletonLockError` を投げるラッパー。
  let got = tryAcquireSingletonLock(path)
  if got.isNone:
    raise newException(SingletonLockError,
      "already running: another process holds the lock at " & path)
  got.get

proc release*(lock: SingletonLock) =
  ## ロックを解放して fd を閉じる。
  ##
  ## 冪等: 既に閉じられている fd（`fd < 0`、あるいは二重に `release` を呼んだ場合）
  ## に対しても例外を投げない。`close(2)` は無効な fd に対して -1 を返すだけなので
  ## 呼び捨てて問題ない。
  if lock.fd >= 0:
    discard close(lock.fd)

proc writePid*(lock: SingletonLock; pid: int) =
  ## ロックファイルに `pid` を書き込む。
  ##
  ## **これは人間・デバッグ向けの補助情報にすぎない。** 多重起動の判定はあくまで
  ## `fcntl` のアドバイザリロックが権威であり、ここに書かれた PID の値そのものが
  ## 排他制御に使われることは無い（`cat` 等で覗いたときに「今ロックを持っている
  ## のは誰か」がすぐ分かるようにするためだけの値）。
  ##
  ## 既に開いている `lock.fd` に対して `pwrite`/`ftruncate` で書き込む
  ## （新たに `open` し直さない。モジュール冒頭に書いた通り、ロックを保持した
  ## まま同じファイルを別 fd で開いて close すると、ロックごと解放されてしまう
  ## ため）。
  let payload = $pid & "\n"
  discard ftruncate(lock.fd, 0.Off)
  discard pwrite(lock.fd, payload.cstring, payload.len, 0.Off)

proc readPid*(path: string): Option[int] =
  ## ロックファイルに書かれている PID を読む。
  ##
  ## **多重起動の判定には使わない**（それは fcntl ロックの責務）。あくまで人間向け
  ## の表示・デバッグ用。ファイルが無い/中身が数値として読めない場合は `none` を
  ## 返す。
  ##
  ## 呼び出し元がこのロックを既に保持している場合、モジュール冒頭の注意の通り
  ## この呼び出し（内部で新しい fd を open → close する）はロックそのものを解放
  ## してしまう。ロックを保持していない別プロセスから使うことを想定している。
  if not fileExists(path):
    return none(int)
  try:
    let content = readFile(path).strip()
    if content.len == 0:
      return none(int)
    some(parseInt(content))
  except CatchableError:
    none(int)
