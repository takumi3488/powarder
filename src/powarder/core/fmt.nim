## Formatter for the `powarder ps` table display.
##
## This module performs no I/O whatsoever. It does not import `std/asyncnet`,
## `std/osproc`, or `std/os`.

import std/strutils
import std/times

# ---------------------------------------------------------------------------
# Byte counts
# ---------------------------------------------------------------------------

const bytesUnits = ["B", "kB", "MB", "GB", "TB", "PB", "EB"]

proc formatBytes*(n: uint64): string =
  ## Formats a byte count concisely. Below 1024, the raw byte count is printed
  ## with no unit; above that, the unit is stepped up in base 1024 and rounded
  ## to one decimal place (e.g. 1_234_567 -> `"1.2MB"`).
  ##
  ## This is implemented by hand because
  ## `std/strutils.formatSize(prefix = bpColloquial)` always uses 3 decimal
  ## places and cannot be told to round to a different width. Empirically
  ## verified: `formatSize(1_234_567, prefix = bpColloquial)` returned
  ## `"1.177MB"` (computed in base 1024, which differs from the `"1.235MB"`
  ## shown in its documentation example, apparently assuming base 1000).
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
# Time
# ---------------------------------------------------------------------------

proc formatDuration*(d: Duration): string =
  ## Docker-style short elapsed-time notation. Shows at most the top two
  ## units (e.g. `"2m5s"`, `"3h12m"`, `"2d5h"`). Weeks are folded into days.
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
  ## Displays "time since last contact". Similar to `formatDuration` but
  ## shows only the single largest unit (e.g. `"2s"` / `"4m"` / `"3h"` /
  ## `"2d"`). Zero is shown as `"now"`.
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
# Table formatting
# ---------------------------------------------------------------------------

proc alignTable*(rows: seq[seq[string]]): seq[string] =
  ## Formats the `ps` table. Each column is left-aligned to its widest cell,
  ## with 2 spaces between columns. Trailing whitespace on each line is
  ## trimmed. The first row is not treated specially as a header (that's the
  ## caller's job). If rows have differing column counts, short rows are
  ## padded with empty strings.
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
