## デーモンだけが書く実行時状態（`~/.local/state/powarder/state.json`）。
##
## 主目的は **デーモンがクラッシュした後に孤児マスター（ControlMaster / forward の
## UDS）を adopt するための記録**。ユーザーが手で編集する `configfile.nim` とは
## 別モジュールであり、スキーマも別（こちらはランタイムの事実の記録で、
## デーモンの都合が優先される。人間の可読性は二の次）。
##
## `PersistedForward.spec` (`ForwardSpec`) や各種 enum の JSON 変換は、この
## モジュールでは手書きしない。`core/types.nim` が `` `%`*(p: Port) `` を提供して
## いるので、`std/json` の汎用 `%` / `to()` が再帰的に（`ForwardSpec` や enum を
## 含めて）このモジュールの型全体をそのまま変換できる。`PersistedForward` 等は
## ここで定義する型自体が variant object を含まないため、追加の手書きコンバータは
## 不要だった。
##
## （`%`(Port) は以前 `ipc/protocol.nim` にあり、このモジュールはそれを import して
## いた。しかしそのオーバーロードは generic dispatch 経由でしか使われないため
## コンパイラが `imported and not used` と誤検知し、「警告に従って外すと
## コンパイルエラーになる」という厄介な状態だった。型と同じ場所へ移して解消した。）

import std/[json, os, times]
import powarder/core/types

type
  PersistedForward* = object
    id*: string
    tunnelName*: string
    spec*: ForwardSpec
    state*: ForwardState
    udsPath*: string

  PersistedHostSession* = object
    host*: string
    fingerprint*: string
    ctlPath*: string
    logPath*: string
    pid*: int
    argv*: seq[string] ## adopt 時に ps 出力と照合するため
    state*: HostSessionState
    forwardIds*: seq[string]

  PersistedState* = object
    version*: int
    savedAt*: string ## ISO8601 形式。デバッグ用（下記 `stampSavedAt` を参照）
    hosts*: seq[PersistedHostSession]
    forwards*: seq[PersistedForward]

const
  savedAtFormat = "yyyy-MM-dd'T'HH:mm:sszzz"
    ## `times.format` に渡す明示的なフォーマット文字列。ISO8601 相当
    ## （例: "2026-07-29T13:45:12+09:00"）。`$now()` でも同じ見た目の文字列は
    ## 得られるが、フォーマットをここに固定しておくことで将来 `times` の
    ## `$` の既定表現が変わっても壊れないようにする。

proc stampSavedAt(): string =
  now().format(savedAtFormat)

proc emptyState*(): PersistedState =
  ## 空の `PersistedState`。`hosts` / `forwards` は空配列、`version` は 1。
  PersistedState(version: 1, savedAt: "", hosts: @[], forwards: @[])

proc loadState*(path: string): PersistedState =
  ## **破損していても例外を投げない。** JSON が壊れている・スキーマが違う場合、
  ## およびファイルが無い場合は空の `PersistedState`（`emptyState()`）を返す。
  ##
  ## これは意図的な設計判断: state ファイルは「クラッシュ後の再接続を
  ## 効率化するためのヒント」に過ぎず、無くても（全ホストへ再接続すれば）
  ## 機能は成立する。一方、ここで例外を投げてしまうとデーモン自体が
  ## 起動できなくなり、それは「ヒントを1つ失って再接続する」よりずっと
  ## 有害である。そのため「状態を失って安全に再出発する」方に倒す。
  if not fileExists(path):
    return emptyState()
  try:
    let content = readFile(path)
    let node = parseJson(content)
    result = node.to(PersistedState)
  except CatchableError:
    result = emptyState()

proc saveState*(path: string; st: PersistedState) =
  ## `st` を JSON として保存する。**一時ファイルに書いてから `moveFile` で
  ## アトミックに置き換える。** クラッシュのタイミングで中途半端な JSON が
  ## 残ると adopt が壊れるため。一時ファイル名は `path` と同一ディレクトリに
  ## 作る（別ファイルシステムをまたぐと rename がアトミックでなくなるため）。
  ##
  ## `savedAt` は呼び出し側が設定した値を無視し、保存する瞬間の時刻
  ## （`now().format("yyyy-MM-dd'T'HH:mm:sszzz")`）で常に上書きする。
  ## 「最後に保存された時刻」という意味を持つフィールドなので、
  ## 「保存する」処理自体がその値の唯一の生成元であるべきという判断。
  var toWrite = st
  toWrite.savedAt = stampSavedAt()

  let dir = path.parentDir
  if dir.len > 0:
    createDir(dir)

  let tmpPath = path & ".tmp." & $getCurrentProcessId()
  writeFile(tmpPath, (%toWrite).pretty())
  # **0600 にしてから rename する。** `writeFile` は umask 依存（多くの環境で 644）で
  # 作るため、そのままだと group / other から読める。この JSON には接続先ホスト名・
  # 内部ネットワークのアドレス・UDS のパス・PID が入るので、他ユーザーに見せる理由が無い。
  # rename の**前**に権限を落とすのが重要（後にすると一瞬 644 で見える窓ができる）。
  setFilePermissions(tmpPath, {fpUserRead, fpUserWrite})
  moveFile(tmpPath, path)
