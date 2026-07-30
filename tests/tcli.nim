## Tests for `powarder/cli/argv` and `powarder/cli/output`.

import std/unittest
import std/os
import std/strutils
import std/nativesockets ## needed for `Port`'s `==`
import powarder/core/types
import powarder/core/errorclass
import powarder/cli/argv
import powarder/cli/output

proc withEnv(pairs: openArray[(string, string)], body: proc()) =
  ## Temporarily overrides environment variables, restoring them afterward
  ## so state doesn't leak across tests (mirrors the helper in
  ## `tests/tpaths.nim`).
  var saved: seq[(string, bool, string)]
  for (k, v) in pairs:
    saved.add (k, existsEnv(k), getEnv(k))
    putEnv(k, v)
  try:
    body()
  finally:
    for (k, existed, old) in saved:
      if existed: putEnv(k, old) else: delEnv(k)

# ===========================================================================
# argv: happy path (covers every row of the implementation-1 requirements table)
# ===========================================================================

suite "parseArgv - run":
  test "run -L 8080:localhost:80 prod-bastion":
    let p = parseArgv(["run", "-L", "8080:localhost:80", "prod-bastion"])
    check p.subcommand == "run"
    check p.localForwards.len == 1
    check p.localForwards[0].kind == fkLocal
    check p.localForwards[0].bindAddr == defaultBindAddr
    check p.localForwards[0].bindPort == Port(8080)
    check p.localForwards[0].targetHost == "localhost"
    check p.localForwards[0].targetPort == Port(80)
    check p.positional == @["prod-bastion"]

  test "run --name web -L 15432:db:5432 -L 9090:m:9090 host":
    let p = parseArgv(["run", "--name", "web", "-L", "15432:db:5432", "-L",
                        "9090:m:9090", "host"])
    check p.name == "web"
    check p.localForwards.len == 2
    check p.positional == @["host"]

  test "run -R 8443:localhost:3000 dev-box":
    let p = parseArgv(["run", "-R", "8443:localhost:3000", "dev-box"])
    check p.remoteForwards.len == 1
    check p.remoteForwards[0].kind == fkRemote
    check p.remoteForwards[0].bindPort == Port(8443)
    check p.positional == @["dev-box"]

suite "parseArgv - up/down":
  test "up":
    let p = parseArgv(["up"])
    check p.subcommand == "up"

  test "up -f ./my.json --profile prod":
    let p = parseArgv(["up", "-f", "./my.json", "--profile", "prod"])
    check p.subcommand == "up"
    check p.configPath == "./my.json"
    check p.profiles == @["prod"]

suite "parseArgv - ps":
  test "ps -a --json":
    let p = parseArgv(["ps", "-a", "--json"])
    check p.subcommand == "ps"
    check p.all
    check p.json

  test "ps -q":
    let p = parseArgv(["ps", "-q"])
    check p.quietList

suite "parseArgv - logs":
  test "logs -f prod-db":
    let p = parseArgv(["logs", "-f", "prod-db"])
    check p.subcommand == "logs"
    check p.follow
    check p.positional == @["prod-db"]

  test "logs -n 100 prod-db":
    let p = parseArgv(["logs", "-n", "100", "prod-db"])
    check p.tailLines == 100
    check p.positional == @["prod-db"]

  test "logs alone defaults tailLines to 50":
    let p = parseArgv(["logs", "prod-db"])
    check p.tailLines == 50

suite "parseArgv - daemon / completion":
  test "daemon status":
    let p = parseArgv(["daemon", "status"])
    check p.subcommand == "daemon"
    check p.subsubcommand == "status"

  test "daemon install":
    let p = parseArgv(["daemon", "install"])
    check p.subsubcommand == "install"

  test "completion zsh":
    let p = parseArgv(["completion", "zsh"])
    check p.subcommand == "completion"
    check p.subsubcommand == "zsh"

suite "parseArgv - aliases / meta commands":
  test "ls is an alias for ps":
    let p = parseArgv(["ls"])
    check p.subcommand == "ps"

  test "--version sets versionRequested":
    check parseArgv(["--version"]).versionRequested

  test "version sets versionRequested":
    check parseArgv(["version"]).versionRequested

  test "--help sets helpRequested":
    check parseArgv(["--help"]).helpRequested

  test "help sets helpRequested":
    check parseArgv(["help"]).helpRequested

  test "no arguments sets helpRequested":
    check parseArgv([]).helpRequested

suite "parseArgv - multiple positional args":
  test "stop a b c":
    let p = parseArgv(["stop", "a", "b", "c"])
    check p.subcommand == "stop"
    check p.positional == @["a", "b", "c"]

# ===========================================================================
# argv: inputs that should error
# ===========================================================================

suite "parseArgv - errors":
  test "-L with no following value":
    expect ArgvError:
      discard parseArgv(["run", "-L"])

  test "invalid -L value (the ValueError from parseForwardSpec propagates as-is)":
    var msg = ""
    try:
      discard parseArgv(["run", "-L", "bogus", "host"])
      fail()
    except ValueError as e:
      msg = e.msg
    check "-L" in msg ## includes info about which argument was bad

  test "invalid -R value still keeps the flag name in the message":
    var msg = ""
    try:
      discard parseArgv(["run", "-R", "not-a-port:host:80", "host"])
      fail()
    except ValueError as e:
      msg = e.msg
    check "-R" in msg

  test "unknown flag (--bogus)":
    expect ArgvError:
      discard parseArgv(["run", "--bogus"])

  test "-n value is not a number":
    expect ArgvError:
      discard parseArgv(["logs", "-n", "abc", "prod-db"])

  test "unknown sub-subcommand after daemon":
    expect ArgvError:
      discard parseArgv(["daemon", "bogus"])

  test "unknown shell after completion":
    expect ArgvError:
      discard parseArgv(["completion", "powershell"])

  test "--config with no following value":
    expect ArgvError:
      discard parseArgv(["up", "--config"])

# ===========================================================================
# argv: -f is polysemous (its meaning changes by subcommand)
# ===========================================================================

suite "parseArgv - -f polysemy":
  test "logs -f means follow":
    let p = parseArgv(["logs", "-f", "x"])
    check p.follow
    check p.configPath == ""

  test "up -f means configPath":
    let p = parseArgv(["up", "-f", "x"])
    check p.configPath == "x"
    check not p.follow

  test "down -f also means configPath":
    let p = parseArgv(["down", "-f", "x"])
    check p.configPath == "x"

# ===========================================================================
# argv: everything after -- is positional
# ===========================================================================

suite "parseArgv - -- literal":
  test "everything after -- is treated as positional, not flags":
    let p = parseArgv(["run", "--", "-L", "8080:x:80", "host"])
    check p.subcommand == "run"
    check p.positional == @["-L", "8080:x:80", "host"]
    check p.localForwards.len == 0

# ===========================================================================
# argv: repeated -L preserves order
# ===========================================================================

suite "parseArgv - repeated -L order":
  test "two -L flags accumulate in input order":
    let p = parseArgv(["run", "-L", "111:a:111", "-L", "222:b:222", "-L",
                        "333:c:333", "host"])
    check p.localForwards.len == 3
    check p.localForwards[0].bindPort == Port(111)
    check p.localForwards[1].bindPort == Port(222)
    check p.localForwards[2].bindPort == Port(333)

# ===========================================================================
# output: table
# ===========================================================================

suite "output: table":
  test "columns are aligned with no trailing whitespace":
    let w = newWriter(noColor = true)
    let header = @["NAME", "TYPE", "STATUS"]
    let rows = @[@["prod-db", "-L", "healthy"], @["webhook", "-R", "up"]]
    let rendered = table(w, header, rows)
    let lines = rendered.splitLines()
    check lines.len == 3
    for line in lines:
      check line == line.strip(leading = false, trailing = true)
    # The content itself can be recovered via splitWhitespace (since column
    # padding uses only spaces)
    check lines[0].splitWhitespace() == header
    check lines[1].splitWhitespace() == rows[0]
    check lines[2].splitWhitespace() == rows[1]

  test "only the header is bold when color is enabled":
    let w = Writer(useColor: true, mode: omAuto, quiet: false)
    let rendered = table(w, @["NAME"], @[@["x"]])
    let lines = rendered.splitLines()
    check "\e[1m" in lines[0]
    check "\e[1m" notin lines[1]

# ===========================================================================
# output: --json / NO_COLOR / --no-color / --quiet disable color and emoji
# ===========================================================================

suite "output: disabling color and emoji":
  test "--json makes useColor false":
    let w = newWriter(json = true)
    check not w.useColor
    check w.mode == omJson
    check success(w, "done") == "OK: done" ## plain text instead of the ✔ emoji
    check failure(w, "bad") == "FAIL: bad"
    check warn(w, "careful") == "WARN: careful"

  test "--no-color makes useColor false":
    let w = newWriter(noColor = true)
    check not w.useColor
    check w.mode == omPlain
    check success(w, "done") == "OK: done"

  test "the mere presence of the NO_COLOR env var makes useColor false":
    withEnv({"NO_COLOR": "1"}, proc() =
      let w = newWriter()
      check not w.useColor)

  test "under quiet, success/info are empty strings but failure/warn remain":
    let w = newWriter(quiet = true)
    check success(w, "x") == ""
    check info(w, "y") == ""
    check failure(w, "z") == "FAIL: z"
    check warn(w, "w") == "WARN: w"

  test "when color is enabled, includes the ✔/✘/⚠ emoji and ANSI escapes":
    let w = Writer(useColor: true, mode: omAuto, quiet: false)
    check "✔" in success(w, "done")
    check "✘" in failure(w, "bad")
    check "⚠" in warn(w, "careful")
    check "\e[32m" in success(w, "done")

# ===========================================================================
# output: renderError
# ===========================================================================

suite "output: renderError":
  test "includes the three-part structure (headline, cause and remedy, raw stderr) and always keeps the raw stderr":
    let w = newWriter(noColor = true)
    let ctx = initErrorContext(host = "prod-bastion", bindPort = 5432)
    let rawStderr = "bind [127.0.0.1]:5432: Address already in use\n"
    let rendered = renderError(w, ekPortInUse, ctx, langJa, rawStderr)
    let lines = rendered.splitLines()

    # Part 1: headline (what failed)
    check lines[0].startsWith("FAIL:")
    check "prod-bastion" in lines[0]
    check lines[1] == ""

    # Part 2: explanation of the cause and remediation hints
    check "5432" in rendered
    check "port" in rendered

    # Part 3: the raw stderr is always included
    check "(ssh: bind [127.0.0.1]:5432: Address already in use)" in rendered

  test "the raw stderr keeps the same content under the English locale too":
    let w = newWriter(noColor = true)
    let ctx = initErrorContext(host = "prod-bastion", bindPort = 5432)
    let rawStderr = "bind [127.0.0.1]:5432: Address already in use\n"
    let rendered = renderError(w, ekPortInUse, ctx, langEn, rawStderr)
    check "(ssh: bind [127.0.0.1]:5432: Address already in use)" in rendered
    check "already in use" in rendered

# ===========================================================================
# output: detectLang
# ===========================================================================

suite "output: detectLang":
  test "LANG=ja_JP.UTF-8 gives langJa":
    withEnv({"LC_ALL": "", "LANG": "ja_JP.UTF-8"}, proc() =
      check detectLang() == langJa)

  test "LANG=en_US.UTF-8 gives langEn":
    withEnv({"LC_ALL": "", "LANG": "en_US.UTF-8"}, proc() =
      check detectLang() == langEn)

  test "LC_ALL takes priority over LANG":
    withEnv({"LC_ALL": "ja_JP.UTF-8", "LANG": "en_US.UTF-8"}, proc() =
      check detectLang() == langJa)

# ===========================================================================
# output: -R rows have "-" stat columns
# ===========================================================================

suite "output: -R row stat columns":
  test "-R can build a table row where CONNS/RX-TX/LAST are '-'":
    let w = newWriter(noColor = true)
    let header = @["NAME", "TYPE", "BIND", "TARGET", "HOST", "CONNS", "RX/TX",
                   "LAST", "UPTIME", "STATUS"]
    let localRow = @["prod-db", "-L", "127.0.0.1:15432", "db.internal:5432",
                     "prod-bastion", "3", "45.2MB/12.1MB", "2s", "3h12m",
                     "healthy"]
    let remoteRow = @["webhook", "-R", "0.0.0.0:8443", "localhost:3000",
                      "dev-box", "-", "-", "-", "1h05m", "up"]
    let rendered = table(w, header, @[localRow, remoteRow])
    let lines = rendered.splitLines()
    check lines.len == 3
    check lines[1].splitWhitespace() == localRow
    check lines[2].splitWhitespace() == remoteRow
    # stat columns that can't be obtained in principle for -R rows must be "-"
    check remoteRow[5] == "-" ## CONNS
    check remoteRow[6] == "-" ## RX/TX
    check remoteRow[7] == "-" ## LAST
