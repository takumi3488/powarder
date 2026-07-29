## `powarder/cli/argv` と `powarder/cli/output` のテスト。

import std/unittest
import std/os
import std/strutils
import std/nativesockets ## `Port` の `==` を使うために必要
import powarder/core/types
import powarder/core/errorclass
import powarder/cli/argv
import powarder/cli/output

proc withEnv(pairs: openArray[(string, string)], body: proc()) =
  ## 環境変数を一時的に差し替える。テスト間で状態が漏れないようにする
  ## （`tests/tpaths.nim` のヘルパーを踏襲）。
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
# argv: 正常系（実装1の要件表を全行網羅）
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

  test "logs のみだと tailLines は既定の 50":
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

suite "parseArgv - エイリアス / メタコマンド":
  test "ls は ps のエイリアス":
    let p = parseArgv(["ls"])
    check p.subcommand == "ps"

  test "--version は versionRequested":
    check parseArgv(["--version"]).versionRequested

  test "version は versionRequested":
    check parseArgv(["version"]).versionRequested

  test "--help は helpRequested":
    check parseArgv(["--help"]).helpRequested

  test "help は helpRequested":
    check parseArgv(["help"]).helpRequested

  test "引数なしは helpRequested":
    check parseArgv([]).helpRequested

suite "parseArgv - 複数 positional":
  test "stop a b c":
    let p = parseArgv(["stop", "a", "b", "c"])
    check p.subcommand == "stop"
    check p.positional == @["a", "b", "c"]

# ===========================================================================
# argv: エラーになるべき入力
# ===========================================================================

suite "parseArgv - エラー":
  test "-L の後に値が無い":
    expect ArgvError:
      discard parseArgv(["run", "-L"])

  test "-L の値が不正 (parseForwardSpec 由来の ValueError がそのまま伝播する)":
    var msg = ""
    try:
      discard parseArgv(["run", "-L", "bogus", "host"])
      fail()
    except ValueError as e:
      msg = e.msg
    check "-L" in msg ## どの引数が悪いか分かる情報を含めている

  test "-R の値が不正でもフラグ名がメッセージに残る":
    var msg = ""
    try:
      discard parseArgv(["run", "-R", "not-a-port:host:80", "host"])
      fail()
    except ValueError as e:
      msg = e.msg
    check "-R" in msg

  test "未知のフラグ (--bogus)":
    expect ArgvError:
      discard parseArgv(["run", "--bogus"])

  test "-n の値が数値でない":
    expect ArgvError:
      discard parseArgv(["logs", "-n", "abc", "prod-db"])

  test "daemon の後に未知のサブサブコマンド":
    expect ArgvError:
      discard parseArgv(["daemon", "bogus"])

  test "completion の後に未知のシェル":
    expect ArgvError:
      discard parseArgv(["completion", "powershell"])

  test "--config の後に値が無い":
    expect ArgvError:
      discard parseArgv(["up", "--config"])

# ===========================================================================
# argv: -f の多義性（サブコマンドで意味が変わる）
# ===========================================================================

suite "parseArgv - -f の多義性":
  test "logs -f は follow":
    let p = parseArgv(["logs", "-f", "x"])
    check p.follow
    check p.configPath == ""

  test "up -f は configPath":
    let p = parseArgv(["up", "-f", "x"])
    check p.configPath == "x"
    check not p.follow

  test "down -f も configPath":
    let p = parseArgv(["down", "-f", "x"])
    check p.configPath == "x"

# ===========================================================================
# argv: -- 以降は全部 positional
# ===========================================================================

suite "parseArgv - -- リテラル":
  test "-- 以降はフラグとして解釈されず positional になる":
    let p = parseArgv(["run", "--", "-L", "8080:x:80", "host"])
    check p.subcommand == "run"
    check p.positional == @["-L", "8080:x:80", "host"]
    check p.localForwards.len == 0

# ===========================================================================
# argv: -L の繰り返しが順序を保つ
# ===========================================================================

suite "parseArgv - -L の繰り返し順序":
  test "2つの -L が入力順のまま蓄積される":
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
  test "桁揃えされ、行末に余分な空白が無い":
    let w = newWriter(noColor = true)
    let header = @["NAME", "TYPE", "STATUS"]
    let rows = @[@["prod-db", "-L", "healthy"], @["webhook", "-R", "up"]]
    let rendered = table(w, header, rows)
    let lines = rendered.splitLines()
    check lines.len == 3
    for line in lines:
      check line == line.strip(leading = false, trailing = true)
    # 内容そのものは splitWhitespace で復元できる（列パディングは空白のみのため）
    check lines[0].splitWhitespace() == header
    check lines[1].splitWhitespace() == rows[0]
    check lines[2].splitWhitespace() == rows[1]

  test "色が有効なときヘッダだけ bold になる":
    let w = Writer(useColor: true, mode: omAuto, quiet: false)
    let rendered = table(w, @["NAME"], @[@["x"]])
    let lines = rendered.splitLines()
    check "\e[1m" in lines[0]
    check "\e[1m" notin lines[1]

# ===========================================================================
# output: --json / NO_COLOR / --no-color / --quiet で色・絵文字が無効化される
# ===========================================================================

suite "output: 色と絵文字の無効化":
  test "--json のとき useColor は false":
    let w = newWriter(json = true)
    check not w.useColor
    check w.mode == omJson
    check success(w, "done") == "OK: done" ## 絵文字 ✔ の代わりにプレーンテキスト
    check failure(w, "bad") == "FAIL: bad"
    check warn(w, "careful") == "WARN: careful"

  test "--no-color のとき useColor は false":
    let w = newWriter(noColor = true)
    check not w.useColor
    check w.mode == omPlain
    check success(w, "done") == "OK: done"

  test "NO_COLOR 環境変数が存在するだけで useColor は false になる":
    withEnv({"NO_COLOR": "1"}, proc() =
      let w = newWriter()
      check not w.useColor)

  test "quiet のとき success/info は空文字列、failure/warn は残る":
    let w = newWriter(quiet = true)
    check success(w, "x") == ""
    check info(w, "y") == ""
    check failure(w, "z") == "FAIL: z"
    check warn(w, "w") == "WARN: w"

  test "色が有効なときは ✔/✘/⚠ の絵文字と ANSI エスケープを含む":
    let w = Writer(useColor: true, mode: omAuto, quiet: false)
    check "✔" in success(w, "done")
    check "✘" in failure(w, "bad")
    check "⚠" in warn(w, "careful")
    check "\e[32m" in success(w, "done")

# ===========================================================================
# output: renderError
# ===========================================================================

suite "output: renderError":
  test "3段構成（見出し・原因と対処・生の stderr）を含み、生の stderr が必ず残る":
    let w = newWriter(noColor = true)
    let ctx = initErrorContext(host = "prod-bastion", bindPort = 5432)
    let rawStderr = "bind [127.0.0.1]:5432: Address already in use\n"
    let rendered = renderError(w, ekPortInUse, ctx, langJa, rawStderr)
    let lines = rendered.splitLines()

    # 1段目: 見出し（何が失敗したか）
    check lines[0].startsWith("FAIL:")
    check "prod-bastion" in lines[0]
    check lines[1] == ""

    # 2段目: 原因の説明と対処のヒント
    check "5432" in rendered
    check "ポート" in rendered

    # 3段目: 生の stderr が必ず含まれる
    check "(ssh: bind [127.0.0.1]:5432: Address already in use)" in rendered

  test "英語ロケールでも生の stderr は同じ内容が残る":
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
  test "LANG=ja_JP.UTF-8 で langJa":
    withEnv({"LC_ALL": "", "LANG": "ja_JP.UTF-8"}, proc() =
      check detectLang() == langJa)

  test "LANG=en_US.UTF-8 で langEn":
    withEnv({"LC_ALL": "", "LANG": "en_US.UTF-8"}, proc() =
      check detectLang() == langEn)

  test "LC_ALL が LANG より優先される":
    withEnv({"LC_ALL": "ja_JP.UTF-8", "LANG": "en_US.UTF-8"}, proc() =
      check detectLang() == langJa)

# ===========================================================================
# output: -R の行は統計列が "-" になる
# ===========================================================================

suite "output: -R 行の統計列":
  test "-R は CONNS/RX-TX/LAST が '-' なテーブル行を作れる":
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
    # -R の行では原理的に取れない統計列が "-" になっていること
    check remoteRow[5] == "-" ## CONNS
    check remoteRow[6] == "-" ## RX/TX
    check remoteRow[7] == "-" ## LAST
