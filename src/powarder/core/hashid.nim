## 永続化される識別子のための安定ハッシュ。
##
## `Forward.id` から導出する UDS ファイル名（`forwardspec.udsBasename`）と、
## `ssh -G` の解決結果から導出する fingerprint（`sshgparse.fingerprint`）は
## どちらも `state.json` に永続化され、デーモン再起動後の adopt 処理
## （`daemon/orphan.nim`）で「以前と同じ実体か」を照合するために使われる。
## つまりプロセスをまたいで、さらに Nim のバージョンやコンパイルフラグを
## またいで安定した値を返す必要がある。
##
## `std/hashes` の `hash()` は使わない。あれは Nim コンパイラ・標準ライブラリの
## 実装詳細であり、`-d:nimStringHash2` のようなコンパイルフラグやバージョン
## アップでアルゴリズムが変わりうる。安定性の保証がないものを永続化キーの
## 導出に使うと、adopt がある日突然壊れる。
##
## そこで仕様が完全に固定されている FNV-1a 64bit を自前で実装する。
## 用途は「衝突しにくい短い識別子」を作ることであり、攻撃者が意図的に衝突を
## 作る動機もないため、暗号強度（SHA-1 相当）は不要。20行程度で書ける
## FNV-1a で十分。

import std/strutils

const
  fnvOffsetBasis64: uint64 = 0xcbf29ce484222325'u64
  fnvPrime64: uint64 = 0x100000001b3'u64

proc fnv1a64*(s: string): uint64 =
  ## FNV-1a 64bit ハッシュ。
  ##
  ## 仕様（http://www.isthe.com/chongo/tech/comp/fnv/ の FNV-1a）:
  ## ```
  ## hash = 0xcbf29ce484222325
  ## for each byte b in input:
  ##     hash = hash xor b
  ##     hash = hash * 0x100000001b3    (64bit wrap-around)
  ## ```
  ## `uint64` の乗算は Nim では自動的に wrap-around するため、桁あふれを
  ## 特別扱いする必要はない。
  result = fnvOffsetBasis64
  for ch in s:
    result = result xor uint64(ord(ch))
    result = result * fnvPrime64

proc hashHex*(s: string; digits: int): string =
  ## `fnv1a64(s)` を小文字16進数にして先頭 `digits` 桁を返す。
  ##
  ## `digits` は 1..16 でなければならない。64bit のハッシュ値は16進数で
  ## ちょうど16桁になるため、16を超える要求はそもそも意味のある追加の
  ## 情報を持たない。範囲外は呼び出し側の実装ミスとみなし `Defect`
  ## （`AssertionDefect`）で落とす。
  assert digits >= 1 and digits <= 16,
    "digits は 1..16 の範囲でなければなりません: " & $digits
  let full = toLowerAscii(toHex(fnv1a64(s)))
  full[0 ..< digits]
