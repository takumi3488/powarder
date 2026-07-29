## `powarder` CLI の表示整形（テーブル・成否メッセージ・エラー表示）。
##
## 色/絵文字を出すかどうかは `Writer.useColor` の1点に集約する。判定条件は
## `newWriter` 参照。TTY でない（パイプ・リダイレクト）場合や `NO_COLOR` が
## 設定されている場合、`--no-color` / `--json` が指定された場合はすべて
## プレーンテキストにフォールバックする（スクリプトからの利用を壊さないため）。
##
## このモジュールは表示文字列を**組み立てて返すだけ**で、自分では書き込まない
## （`echo` しない）。呼び出し側（後続の `cli/dispatch.nim`）が stdout/stderr への
## 出力先を決める。

import std/os
import std/strutils
import std/terminal
import powarder/core/fmt
import powarder/core/errorclass

type
  OutputMode* = enum
    omAuto  ## 通常のテーブル/テキスト表示
    omPlain ## `--no-color` によるプレーン強制
    omJson  ## `--json` による機械可読出力

  Writer* = object
    useColor*: bool
    mode*: OutputMode
    quiet*: bool

const
  ansiReset = "\e[0m"
  ansiBold = "\e[1m"
  ansiGreen = "\e[32m"
  ansiRed = "\e[31m"
  ansiYellow = "\e[33m"

proc newWriter*(json = false; noColor = false; quiet = false): Writer =
  ## 色を使うかは **isatty(stdout) かつ `NO_COLOR` 環境変数が無い かつ
  ## `--no-color` でない かつ `--json` でない** の全てが成り立つときだけ true になる。
  ##
  ## `mode` は `dispatch` 側が「テーブルで出すか JSON で出すか」を判断するための
  ## メタ情報として持たせているだけで、このモジュール自身の関数（`table` /
  ## `success` 等）の出力形式は変えない（JSON への整形は呼び出し側の責務）。
  let mode =
    if json: omJson
    elif noColor: omPlain
    else: omAuto
  let noColorEnv = getEnv("NO_COLOR").len > 0
  let useColor = stdout.isatty() and not noColorEnv and not noColor and not json
  Writer(useColor: useColor, mode: mode, quiet: quiet)

# ---------------------------------------------------------------------------
# テーブル
# ---------------------------------------------------------------------------

proc table*(w: Writer; header: seq[string]; rows: seq[seq[string]]): string =
  ## `core/fmt.alignTable()` で桁揃えする。`header` は大文字のまま渡される想定。
  ## 色が有効ならヘッダ行を bold にする。
  var allRows = newSeq[seq[string]](rows.len + 1)
  allRows[0] = header
  for idx, row in rows:
    allRows[idx + 1] = row
  let aligned = alignTable(allRows)
  if aligned.len == 0:
    return ""
  if w.useColor:
    result = ansiBold & aligned[0] & ansiReset
    for idx in 1 ..< aligned.len:
      result.add("\n" & aligned[idx])
  else:
    result = aligned.join("\n")

# ---------------------------------------------------------------------------
# 成否・警告・情報メッセージ
#
# 色/絵文字が無効なときは記号 (✔/✘/⚠) の代わりに `OK:` / `FAIL:` / `WARN:` の
# プレフィックスにフォールバックする。失敗と警告は `w.quiet` でも常に表示する
# （抑制してよいのは成功・情報系のメッセージだけ、という判断）。
# ---------------------------------------------------------------------------

proc success*(w: Writer; msg: string): string =
  ## ✔ 付き（色無効時は "OK:" にフォールバック）。`--quiet` のときは空文字列。
  if w.quiet:
    return ""
  if w.useColor:
    ansiGreen & "✔" & ansiReset & " " & msg
  else:
    "OK: " & msg

proc failure*(w: Writer; msg: string): string =
  ## ✘ 付き（色無効時は "FAIL:" にフォールバック）。
  if w.useColor:
    ansiRed & "✘" & ansiReset & " " & msg
  else:
    "FAIL: " & msg

proc warn*(w: Writer; msg: string): string =
  ## ⚠ 付き（色無効時は "WARN:" にフォールバック）。
  if w.useColor:
    ansiYellow & "⚠" & ansiReset & " " & msg
  else:
    "WARN: " & msg

proc info*(w: Writer; msg: string): string =
  ## 記号なし。`--quiet` のときは空文字列。
  if w.quiet:
    return ""
  msg

# ---------------------------------------------------------------------------
# エラー表示
# ---------------------------------------------------------------------------

const
  headlineTemplate: array[Lang, string] = [
    langEn: "Failed to set up forwarding to $1.",
    langJa: "$1 への転送のセットアップに失敗しました。",
  ]

proc lastNonEmptyLine(s: string): string =
  ## ssh の stderr は複数行にわたることが多いが、実際に刺さる1文は最後の行に
  ## 出ることが多い（バナー→本体の順で出るため）。空行を読み飛ばして最後の
  ## 非空行を返す。全行が空なら trim した元の文字列を返す。
  let lines = s.splitLines()
  for idx in countdown(lines.high, 0):
    let trimmed = lines[idx].strip()
    if trimmed.len > 0:
      return trimmed
  s.strip()

proc renderError*(w: Writer; kind: ErrorKind; ctx: ErrorContext; lang: Lang;
                  rawStderr: string): string =
  ## エラー表示の3段構成:
  ##   1行目: ✘ <何が失敗したか>（`ctx.host` を埋め込んだ見出し）
  ##   空行
  ##   原因の説明（`explain().summary`）
  ##   対処の候補（`explain().hints`、各行インデント）
  ##   空行
  ##   (ssh: <生の stderr の関連行>)   ← 生の出力は必ず残す
  let expl = explain(kind, lang, ctx)
  let headline = headlineTemplate[lang] % [ctx.host]

  var lines: seq[string] = @[w.failure(headline), ""]
  lines.add("  " & expl.summary)
  for hint in expl.hints:
    lines.add("  " & hint)
  lines.add("")
  lines.add("  (ssh: " & lastNonEmptyLine(rawStderr) & ")")
  lines.join("\n")

# ---------------------------------------------------------------------------
# ロケール判定
# ---------------------------------------------------------------------------

proc detectLang*(): Lang =
  ## `LC_ALL` / `LANG` 環境変数を見て言語を決める。POSIX のロケール優先順位
  ## （`LC_ALL` が `LANG` より優先される）に合わせ、値が "ja" で始まる
  ## （大文字小文字は無視）ロケールなら `langJa`、それ以外は `langEn`。
  let locale =
    if getEnv("LC_ALL").len > 0: getEnv("LC_ALL")
    else: getEnv("LANG")
  if locale.toLowerAscii().startsWith("ja"):
    langJa
  else:
    langEn
