## Tests for `powarder/core/fmt`.

import std/unittest
import std/times
import powarder/core/fmt

suite "formatBytes":
  test "0 bytes":
    check formatBytes(0'u64) == "0B"

  test "below 1024 shows the raw byte count with no unit":
    check formatBytes(512'u64) == "512B"
    check formatBytes(1023'u64) == "1023B"

  test "switches to kB display at exactly 1024":
    check formatBytes(1024'u64) == "1.0kB"

  test "kB unit, one decimal place":
    check formatBytes(1500'u64) == "1.5kB"

  test "MB unit, one decimal place":
    check formatBytes(1_234_567'u64) == "1.2MB"

  test "GB unit, one decimal place":
    check formatBytes(1_500_000_000'u64) == "1.4GB"

suite "formatDuration":
  test "45 seconds":
    check formatDuration(initDuration(seconds = 45)) == "45s"

  test "2 minutes 5 seconds":
    check formatDuration(initDuration(minutes = 2, seconds = 5)) == "2m5s"

  test "3 hours 12 minutes":
    check formatDuration(initDuration(hours = 3, minutes = 12)) == "3h12m"

  test "2 days 5 hours":
    check formatDuration(initDuration(days = 2, hours = 5)) == "2d5h"

  test "0 seconds":
    check formatDuration(initDuration(seconds = 0)) == "0s"

  test "1 week 3 days (weeks are folded into days)":
    check formatDuration(initDuration(weeks = 1, days = 3)) == "10d0h"

suite "formatAgo":
  test "0 is now":
    check formatAgo(initDuration(seconds = 0)) == "now"

  test "seconds only (top unit only)":
    check formatAgo(initDuration(seconds = 2)) == "2s"

  test "minutes only":
    check formatAgo(initDuration(minutes = 4, seconds = 30)) == "4m"

  test "hours only":
    check formatAgo(initDuration(hours = 3, minutes = 10)) == "3h"

  test "days only":
    check formatAgo(initDuration(days = 2, hours = 5)) == "2d"

suite "alignTable":
  test "left-aligned to each column's widest cell, 2 spaces between columns":
    let rows = @[
      @["NAME", "PORT", "STATUS"],
      @["db", "15432", "active"],
      @["web", "8443", "degraded"],
    ]
    let output = alignTable(rows)
    check output.len == 3
    check output[0] == "NAME  PORT   STATUS"
    check output[1] == "db    15432  active"
    check output[2] == "web   8443   degraded"

  test "when rows have differing column counts, short rows are padded with empty strings":
    let rows = @[
      @["a", "b", "c"],
      @["x"],
    ]
    let output = alignTable(rows)
    check output.len == 2
    check output[1] == "x"

  test "empty input":
    check alignTable(@[]).len == 0
