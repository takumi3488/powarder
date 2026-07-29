## `ssh -G <host>` の出力（ssh_config の解決結果）をパースする純粋モジュール。
##
## powarder は ssh_config の `Host` ブロック・`Match`・`Include`・
## `%h`/`%p`/`%r` 展開・`ProxyJump` の解決を自前で再実装せず、OpenSSH 本体が
## 出す `ssh -G <host>` の結果をそのまま信頼することでこれらすべてに
## 完全互換で追従する。このモジュールは **その標準出力の文字列を受け取って
## パースするだけ** であり、`ssh -G` を実際に実行する I/O は別レイヤ
## （daemon 層）の責務。このモジュールは `std/asyncnet` / `std/osproc` /
## `std/os` を import しない。
##
## 重要な注意（呼び出し側が守るべき契約）:
## `parseSshG` に渡してよいのは **`ssh -G` の stdout のみ** である。
## OpenSSH は実行状況によって stderr に
## `Pseudo-terminal will not be allocated because stdin is not a terminal.`
## のような行を吐くことがあるが、これを混ぜて渡してはいけない。
## 万一混入しても被害を局所化できるよう、`<小文字キー> <値>` の形式に
## 合わない行は例外を投げずに黙って無視する堅牢な実装にしている。

import std/[tables, strutils, sequtils, algorithm]

import powarder/core/hashid

type
  SshConfigResolved* = object
    ## `ssh -G` の解決結果を保持する。キーは常に小文字。
    ## `identityfile` / `sendenv` のように1つの `ssh -G` 出力の中で複数行
    ## 出現しうるキーがあるため、単一値のキーも含めて一律 `seq[string]` で
    ## 保持する設計にしている（単一値がほしい場合は `getFirst` を使う）。
    values*: Table[string, seq[string]]

const
  fingerprintExcludedKeys* = ["sessiontype", "requesttty", "stdinnull",
                              "forkafterauthentication"]
    ## `fingerprint` の計算対象から除外するキー。
    ##
    ## powarder はフォワード用マスターを常に `ssh -N`
    ## （リモートコマンドを実行しない）で起動するため、これらのキーは
    ## ssh_config 側の設定値に関わらず powarder から見ると実質固定値であり、
    ## 「同じ接続を共有できるか」という同一性判定には寄与しない。
    ##
    ## 逆に言えば、ここに列挙されていないキー（`host` を含む、`ssh -G` が
    ## 返すそれ以外の全キー）は一切除外しない。除外しすぎると
    ## 「本当は別設定なのに同じ ControlMaster を共有してしまう」という
    ## 事故につながるため、含めるべきか迷うキーは常に含める側に倒す。

proc isPlausibleKey(s: string): bool =
  ## `ssh -G` が実際に出すキーはすべて英小文字のみで構成される
  ## （例: `identityfile`, `kbdinteractiveauthentication`）。
  ## 万一 stderr の警告文が紛れ込んでも、その1語目（例: `Pseudo-terminal`
  ## の `pseudo-terminal`）はハイフンを含み実在のキーとは形が異なるため、
  ## この判定で弾ける。
  s.len > 0 and s.allCharsInSet({'a'..'z'})

proc parseSshG*(stdout: string): SshConfigResolved =
  ## `ssh -G` の stdout をパースする。
  ##
  ## 各行は `<小文字キー><空白1個以上><値>` の形式（実測: OpenSSH は
  ## キーと値の間に半角スペース1個を使う）。この形式に合わない行
  ## （空行、キーだけの行、キーが英小文字のみで構成されない行など）は
  ## 黙って無視する。stderr の警告文
  ## （`Pseudo-terminal will not be allocated because ...`）が誤って
  ## 混入した場合もこの判定で無視される。
  result = SshConfigResolved(values: initTable[string, seq[string]]())
  for rawLine in stdout.splitLines():
    let line = rawLine.strip()
    if line.len == 0:
      continue
    let parts = line.splitWhitespace(maxsplit = 1)
    if parts.len != 2:
      continue
    let key = parts[0].toLowerAscii()
    if not isPlausibleKey(key):
      continue
    result.values.mgetOrPut(key, @[]).add(parts[1])

proc get*(r: SshConfigResolved; key: string): seq[string] =
  ## `key` に対応する値の seq を返す。無ければ空 seq。
  r.values.getOrDefault(key.toLowerAscii())

proc getFirst*(r: SshConfigResolved; key: string; default = ""): string =
  ## `key` の先頭の値を返す。無ければ `default`。
  let vals = r.get(key)
  if vals.len > 0: vals[0] else: default

proc has*(r: SshConfigResolved; key: string): bool =
  ## `key` が1つでも存在するか。
  key.toLowerAscii() in r.values

proc fingerprint*(r: SshConfigResolved): string =
  ## 解決済み設定から決定的なフィンガープリントを作る。
  ##
  ## powarder は「同じ ssh 接続設定なら1つの ControlMaster を共有する」
  ## ために、`host` の変更（HostSessionKey.host）と `sshExtraArgs` の変更
  ## （ssh_config には現れないが、実行時に -o 等で渡され `ssh -G` の
  ## 解決結果へ反映される）のどちらも「解決済み設定というキーの変化」
  ## として一様に扱えるよう、この関数を使う。
  ##
  ## 手順:
  ## 1. `fingerprintExcludedKeys` に載っているキーを除外する
  ## 2. 残ったキーをソートして正規化する（キー順序を固定することで、
  ##    `ssh -G` の出力上の行の並びが違っても同じ内容なら同じ結果になる）
  ## 3. 各キー内部の値の出現順は保持する（`identityfile` の優先順位のように
  ##    意味を持ちうるため、ソートしない）
  ## 4. 正規化した文字列を `hashid.hashHex` にかけ、16桁（64bit・小文字16進）
  ##    を返す。64bit なので実質衝突しない。
  var keys = toSeq(r.values.keys).filterIt(it notin fingerprintExcludedKeys)
  keys.sort()
  var normalized = ""
  for k in keys:
    normalized.add(k)
    normalized.add('=')
    normalized.add(r.values[k].join(","))
    normalized.add(';')
  result = hashHex(normalized, 16)
