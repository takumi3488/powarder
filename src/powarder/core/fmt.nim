## `powarder ps` のテーブル表示用フォーマッタ。
##
## このモジュールは I/O を一切行わない。`std/asyncnet` / `std/osproc` / `std/os` を
## import しない。

import std/strutils
import std/times

# ---------------------------------------------------------------------------
# バイト数
# ---------------------------------------------------------------------------

const bytesUnits = ["B", "kB", "MB", "GB", "TB", "PB", "EB"]

proc formatBytes*(n: uint64): string =
  ## バイト数を短く整形する。1024 未満は単位なしでバイト数をそのまま出し、
  ## それ以上は 1024 進数で単位を繰り上げつつ小数点1桁で丸める
  ## （例: 1_234_567 -> `"1.2MB"`）。
  ##
  ## `std/strutils.formatSize(prefix = bpColloquial)` は小数点以下3桁固定で
  ## 丸め幅を指定できないため自前で実装している。実測結果:
  ## `formatSize(1_234_567, prefix = bpColloquial)` は `"1.177MB"` を返した
  ## （1024 進数で計算されており、1000 進数を仮定した `"1.235MB"` という
  ## ドキュメント例とは異なった）。
  if n == 0:
    return "0B"
  if n < 1024'u64:
    return $n & "B"
  var value = n.float
  var idx = 0
  while value >= 1024.0 and idx < bytesUnits.high:
    value = value / 1024.0
    inc idx
  formatFloat(value, ffDecimal, precision = 1) & bytesUnits[idx]

# ---------------------------------------------------------------------------
# 時間
# ---------------------------------------------------------------------------

proc formatDuration*(d: Duration): string =
  ## Docker 風の短い経過時間表記。上位2つの単位までを出す
  ## （例: `"2m5s"`, `"3h12m"`, `"2d5h"`）。週は日に繰り込む。
  let parts = toParts(d)
  let days = parts[Weeks] * 7 + parts[Days]
  if days > 0:
    return $days & "d" & $parts[Hours] & "h"
  if parts[Hours] > 0:
    return $parts[Hours] & "h" & $parts[Minutes] & "m"
  if parts[Minutes] > 0:
    return $parts[Minutes] & "m" & $parts[Seconds] & "s"
  $parts[Seconds] & "s"

proc formatAgo*(d: Duration): string =
  ## 「最終通信からの経過」表示。`formatDuration` と似ているが最上位の単位
  ## だけを出す（例: `"2s"` / `"4m"` / `"3h"` / `"2d"`）。0 は `"now"`。
  let parts = toParts(d)
  let days = parts[Weeks] * 7 + parts[Days]
  if days > 0:
    return $days & "d"
  if parts[Hours] > 0:
    return $parts[Hours] & "h"
  if parts[Minutes] > 0:
    return $parts[Minutes] & "m"
  if parts[Seconds] > 0:
    return $parts[Seconds] & "s"
  "now"

# ---------------------------------------------------------------------------
# テーブル整形
# ---------------------------------------------------------------------------

proc alignTable*(rows: seq[seq[string]]): seq[string] =
  ## `ps` のテーブル整形。各列の最大幅に合わせて左詰めし、列間は2スペース。
  ## 行末の余白は trim する。1行目をヘッダとして特別扱いはしない（呼び出し
  ## 側が渡す）。列数が行によって違う場合は短い行を空文字列で埋める。
  if rows.len == 0:
    return @[]

  var colCount = 0
  for row in rows:
    colCount = max(colCount, row.len)

  var widths = newSeq[int](colCount)
  for row in rows:
    for i in 0 ..< colCount:
      let cell = if i < row.len: row[i] else: ""
      widths[i] = max(widths[i], cell.len)

  result = newSeq[string](rows.len)
  for rowIdx, row in rows:
    var cells = newSeq[string](colCount)
    for i in 0 ..< colCount:
      let cell = if i < row.len: row[i] else: ""
      cells[i] = alignLeft(cell, widths[i])
    result[rowIdx] = cells.join("  ").strip(leading = false, trailing = true)
