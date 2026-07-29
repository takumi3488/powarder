## `powarder/core/fmt` のテスト。

import std/unittest
import std/times
import powarder/core/fmt

suite "formatBytes":
  test "0 バイト":
    check formatBytes(0'u64) == "0B"

  test "1024 未満は単位なしバイト表示":
    check formatBytes(512'u64) == "512B"
    check formatBytes(1023'u64) == "1023B"

  test "1024 ちょうどで kB 表示に切り替わる":
    check formatBytes(1024'u64) == "1.0kB"

  test "kB 単位・小数点1桁":
    check formatBytes(1500'u64) == "1.5kB"

  test "MB 単位・小数点1桁":
    check formatBytes(1_234_567'u64) == "1.2MB"

  test "GB 単位・小数点1桁":
    check formatBytes(1_500_000_000'u64) == "1.4GB"

suite "formatDuration":
  test "45秒":
    check formatDuration(initDuration(seconds = 45)) == "45s"

  test "2分5秒":
    check formatDuration(initDuration(minutes = 2, seconds = 5)) == "2m5s"

  test "3時間12分":
    check formatDuration(initDuration(hours = 3, minutes = 12)) == "3h12m"

  test "2日5時間":
    check formatDuration(initDuration(days = 2, hours = 5)) == "2d5h"

  test "0秒":
    check formatDuration(initDuration(seconds = 0)) == "0s"

  test "1週間3日（週は日に繰り込まれる）":
    check formatDuration(initDuration(weeks = 1, days = 3)) == "10d0h"

suite "formatAgo":
  test "0 は now":
    check formatAgo(initDuration(seconds = 0)) == "now"

  test "秒だけ (最上位の単位のみ)":
    check formatAgo(initDuration(seconds = 2)) == "2s"

  test "分だけ":
    check formatAgo(initDuration(minutes = 4, seconds = 30)) == "4m"

  test "時間だけ":
    check formatAgo(initDuration(hours = 3, minutes = 10)) == "3h"

  test "日だけ":
    check formatAgo(initDuration(days = 2, hours = 5)) == "2d"

suite "alignTable":
  test "各列の最大幅に揃えて左詰め、列間は2スペース":
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

  test "列数が行によって違う場合は短い行を空文字列で埋める":
    let rows = @[
      @["a", "b", "c"],
      @["x"],
    ]
    let output = alignTable(rows)
    check output.len == 2
    check output[1] == "x"

  test "空の入力":
    check alignTable(@[]).len == 0
