## Output formatting for the `powarder` CLI (tables, success/failure messages,
## error display).
##
## Whether to use color/emoji is consolidated into the single
## `Writer.useColor` flag; see `newWriter` for the exact condition. It falls
## back to plain text whenever stdout isn't a TTY (piped/redirected), when
## `NO_COLOR` is set, or when `--no-color` / `--json` is given (so scripted
## usage isn't broken).
##
## This module only **builds and returns** display strings; it never writes
## them itself (no `echo`). The caller (ultimately `cli/dispatch.nim`) decides
## where output goes (stdout/stderr).

import std/os
import std/strutils
import std/terminal
import powarder/core/fmt
import powarder/core/errorclass

type
  OutputMode* = enum
    omAuto  ## Normal table/text display
    omPlain ## Plain text forced by `--no-color`
    omJson  ## Machine-readable output via `--json`

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
  ## Whether to use color is true only when **all** of these hold: isatty(stdout),
  ## the `NO_COLOR` environment variable is not set, `--no-color` was not
  ## given, and `--json` was not given.
  ##
  ## `mode` is kept purely as metadata for `dispatch` to decide whether to
  ## print a table or JSON; it doesn't change the output format of this
  ## module's own functions (`table` / `success` etc.) — formatting as JSON is
  ## the caller's responsibility.
  let mode =
    if json: omJson
    elif noColor: omPlain
    else: omAuto
  let noColorEnv = getEnv("NO_COLOR").len > 0
  let useColor = stdout.isatty() and not noColorEnv and not noColor and not json
  Writer(useColor: useColor, mode: mode, quiet: quiet)

# ---------------------------------------------------------------------------
# Table
# ---------------------------------------------------------------------------

proc table*(w: Writer; header: seq[string]; rows: seq[seq[string]]): string =
  ## Aligns columns via `core/fmt.alignTable()`. `header` is expected to be
  ## passed in already uppercase. Bolds the header row if color is enabled.
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
# Success / warning / info messages
#
# When color/emoji is disabled, falls back to `OK:` / `FAIL:` / `WARN:`
# prefixes instead of the symbols (✔/✘/⚠). Failures and warnings are always
# shown even under `w.quiet` (the judgment call is that only success/info
# messages are safe to suppress).
# ---------------------------------------------------------------------------

proc success*(w: Writer; msg: string): string =
  ## Prefixed with ✔ (falls back to "OK:" when color is disabled). Empty
  ## string under `--quiet`.
  if w.quiet:
    return ""
  if w.useColor:
    ansiGreen & "✔" & ansiReset & " " & msg
  else:
    "OK: " & msg

proc failure*(w: Writer; msg: string): string =
  ## Prefixed with ✘ (falls back to "FAIL:" when color is disabled).
  if w.useColor:
    ansiRed & "✘" & ansiReset & " " & msg
  else:
    "FAIL: " & msg

proc warn*(w: Writer; msg: string): string =
  ## Prefixed with ⚠ (falls back to "WARN:" when color is disabled).
  if w.useColor:
    ansiYellow & "⚠" & ansiReset & " " & msg
  else:
    "WARN: " & msg

proc info*(w: Writer; msg: string): string =
  ## No symbol. Empty string under `--quiet`.
  if w.quiet:
    return ""
  msg

# ---------------------------------------------------------------------------
# Error display
# ---------------------------------------------------------------------------

const
  headlineTemplate = "Failed to set up forwarding to $1."

proc lastNonEmptyLine(s: string): string =
  ## ssh's stderr often spans multiple lines, but the one line that actually
  ## matters tends to appear last (since a banner is printed before the main
  ## message). Skips blank lines and returns the last non-empty one. If every
  ## line is empty, returns the trimmed original string.
  let lines = s.splitLines()
  for idx in countdown(lines.high, 0):
    let trimmed = lines[idx].strip()
    if trimmed.len > 0:
      return trimmed
  s.strip()

proc renderError*(w: Writer; kind: ErrorKind; ctx: ErrorContext;
                  rawStderr: string): string =
  ## The three-part structure of error display:
  ##   Line 1: ✘ <what failed> (a headline with `ctx.host` embedded)
  ##   blank line
  ##   Explanation of the cause (`explain().summary`)
  ##   Candidate remedies (`explain().hints`, each line indented)
  ##   blank line
  ##   (ssh: <the relevant line of raw stderr>)   <- the raw output is always kept
  let expl = explain(kind, ctx)
  let headline = headlineTemplate % [ctx.host]

  var lines: seq[string] = @[w.failure(headline), ""]
  lines.add("  " & expl.summary)
  for hint in expl.hints:
    lines.add("  " & hint)
  lines.add("")
  lines.add("  (ssh: " & lastNonEmptyLine(rawStderr) & ")")
  lines.join("\n")
