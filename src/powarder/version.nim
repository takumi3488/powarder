## powarder のバージョン。
##
## CLI（`cli/dispatch`）・デーモン（`daemon/run`）・エントリポイント（`powarder.nim`）の
## 3箇所が独立に文字列リテラルを持つと必ずずれるので、ここを唯一の定義とする。
##
## nimble は `-d:NimblePkgVersion=<version>` を渡してビルドするので、
## `{.strdefine.}` でそれを受け取る。つまり **`powarder.nimble` の `version` が
## 真の唯一の情報源**になり、Nim 側にバージョンを書く必要が無い。
## `nimble` を介さない素の `nim c` では下のフォールバック値が使われる。

const NimblePkgVersion {.strdefine.} = "0.1.0"

const powarderVersion* = NimblePkgVersion
