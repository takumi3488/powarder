## プロセスの生存確認と、記録済み argv との同一性検証。
##
## デーモンがクラッシュした後に残った ssh マスタープロセスを adopt（引き継ぎ）する際に、
## 「その PID が本当に自分が起動した ssh か」を確認するために使う。単に PID の生存だけを
## 見ると、デーモン再起動までの間に OS が同じ PID を無関係なプロセスに再利用してしまう
## （PID reuse）ケースを誤認識してしまうため、記録済みの argv とプロセスの実際の
## コマンドラインを突き合わせて同一性を検証する。

import std/[os, osproc, posix, strutils]

proc pidAlive*(pid: int): bool =
  ## `kill(pid, 0)` はシグナルを送らずに存在確認だけを行う。
  ## - 成功（0）: 生きている。
  ## - `ESRCH`: 存在しない → false。
  ## - `EPERM`: 存在するが所有者が違う等で権限が無い → ここでは
  ##   「存在することは分かった」ので true として扱う。
  if kill(Pid(pid), 0.cint) == 0:
    return true
  cint(osLastError()) == EPERM

when defined(linux):
  proc processCmdline*(pid: int): string =
    ## Linux では `/proc/<pid>/cmdline` を読む方が `ps` より正確。引数が NUL 区切り
    ## で分離されているため、引数中に空白を含んでいても引数境界を誤認識しない。
    ## 取得できなければ空文字列を返す。
    try:
      let raw = readFile("/proc" / $pid / "cmdline")
      raw.replace("\0", " ").strip()
    except CatchableError:
      ""
else:
  proc processCmdline*(pid: int): string =
    ## macOS などでは `/proc` が無いため `ps` を使う。
    ##
    ## **`-ww` を必ず付けること。** `ps` は既定でコマンドライン長を端末幅や内部の
    ## 既定値で切り詰める。powarder が起動する ssh は
    ## `-o BatchMode=yes -o ControlPersist=no -o ServerAliveInterval=15 ...` のように
    ## 長い引数列を持つため、`-ww`（出力幅の制限を外す）が無いと `cmdlineMatches`
    ## による照合が途中で切れて失敗する。取得できなければ空文字列を返す。
    try:
      execProcess("ps", args = ["-wwo", "command=", "-p", $pid],
                  options = {poUsePath}).strip()
    except CatchableError:
      ""

proc cmdlineMatches*(pid: int; expected: openArray[string]): bool =
  ## 記録済み argv（`expected`）の**全要素**が、実際のプロセスのコマンドライン
  ## 文字列に部分文字列として含まれているかで判定する。完全一致は要求しない。
  ##
  ## 判定方針: `ps`（および `/proc/pid/cmdline` を空白連結した場合）の出力は
  ## 引数を単純に連結したものであり、元の引数境界やクォートを復元できない。
  ## そのため「厳密な argv 比較」は原理的に不可能で、代わりに緩い包含判定を採る。
  ##
  ## 非対称性を意識した設計: 不一致のときは「adopt しない＝何もしない」方向に倒す。
  ## - 偽陰性（本当は自分が起動したプロセスなのに不一致と判定してしまう）は許容する。
  ##   最悪、adopt できずに ssh を起動し直すだけで実害が小さい。
  ## - 偽陽性（無関係なプロセスを自分のものだと誤認して adopt してしまう）は避ける。
  ##   無関係なプロセスに `-O cancel` 等を打ち込む事故になりうるため。
  ## `expected` の全要素の包含を要求する（AND 条件）ことで、偽陽性側に倒れにくい
  ## 判定にしている。
  let actual = processCmdline(pid)
  if actual.len == 0:
    return false
  for e in expected:
    if e notin actual:
      return false
  true
