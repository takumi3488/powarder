## powarder CLI の argv パーサ。
##
## docker / docker compose / systemctl / tailscale の語彙を借用しつつ、`-L` / `-R` だけは
## ssh 本体と完全互換の文法（`parseForwardSpec` 経由）で受け付ける。これにより
## 既存の `ssh -L ... host` を `powarder run -L ... host` に機械的に置き換えるだけで
## 移行できる。
##
## **`std/parseopt` は使わない。** サブコマンド機構が無く、`-L 8080:localhost:80` の
## ようなスペース区切りの値付き短縮フラグを `shortNoVal` のセットで管理するのは
## ssh 互換文法との相性が悪い（`-L` の値が `:` を含む1トークンであることを
## 前提にした自前の分割が別途必要になり、結局 parseopt の恩恵が薄い）。
## 代わりに argv を素朴に先頭から走査する状態機械として実装する。
##
## ### `-f` / `-n` の多義性について
##
## docker が `docker logs -f`（follow）と `docker up -f FILE`（compose ファイル指定）で
## 同じ `-f` に別の意味を与えているのと同じ運用を許容する。**「今の subcommand が
## 何か」を見てから `-f` を解釈する**ことでこの曖昧さを解消している:
##
## - `subcommand == "logs"` のとき `-f` は `follow`（値を取らない）
## - それ以外のとき `-f` は `--config` の別名（値を1つ取る）
##
## 同様に `-n` も `logs`（`tailLines`、整数値）と、それ以外の subcommand
## （`--name` の短縮形、文字列値）とで意味が変わる。曖昧さの種類としては同一なので
## 同じ「subcommand を見てから分岐する」方針で統一している。
## 長い形（`--follow` / `--file` / `--config` / `--name`）はどの subcommand でも
## 意味が変わらないため、曖昧さの回避に `-f` / `-n` を避けたいスクリプトはそちらを使える。
##
## このモジュールは I/O を一切行わない。

import std/strutils
import powarder/core/types
import powarder/core/forwardspec

type
  ParsedArgs* = object
    subcommand*: string ## "run", "up", "ps", "daemon" 等。空なら未指定（help を出す）
    subsubcommand*: string   ## "daemon status" の "status"、"completion zsh" の "zsh"
    positional*: seq[string] ## トンネル名やホスト名
    localForwards*: seq[ForwardSpec] ## -L の繰り返し（fkLocal でパース済み）
    remoteForwards*: seq[ForwardSpec] ## -R の繰り返し（fkRemote でパース済み）
    name*: string            ## --name / -n
    configPath*: string      ## --config / -f / --file
    profiles*: seq[string]   ## --profile / -p の繰り返し
    tailLines*: int          ## logs -n（既定 50）
    json*: bool
    noColor*: bool
    verbose*: bool
    quiet*: bool
    all*: bool               ## ps -a
    quietList*: bool         ## ps -q（名前のみ出力）
    follow*: bool            ## logs -f
    probe*: bool             ## ps --probe（Tier2 ヘルスチェックのオプトイン）
    noAutostart*: bool
    immediate*: bool         ## down が grace をスキップする
    helpRequested*: bool
    versionRequested*: bool

  ArgvError* = object of CatchableError

const
  defaultTailLines = 50

  daemonSubcommands = [
    "status", "start", "stop", "restart", "reload", "install", "uninstall",
    "logs",
  ]
  completionShells = ["zsh", "bash", "fish"]
  subsubcommandHosts = ["daemon", "completion"]
    ## この subcommand だけは直後のトークンを subsubcommand として消費する。

proc parseForwardArg(flag, value: string; kind: ForwardKind): ForwardSpec =
  ## `parseForwardSpec` を呼び、失敗したら **同じ ValueError のまま** 再送出する
  ## （呼び出し側からは「そのまま伝播してきた」ように見える）。
  ## ただしメッセージの先頭に「どのフラグの値が悪かったか」（`-L` か `-R` か、
  ## および実際に渡された値）を付け加える。`parseForwardSpec` 自身のメッセージには
  ## 元の文字列は含まれるが、それが `-L` 由来か `-R` 由来かはここでしか分からないため。
  try:
    parseForwardSpec(value, kind)
  except ValueError as e:
    raise newException(ValueError, flag & " " & value & ": " & e.msg)

proc parseArgv*(args: openArray[string]): ParsedArgs =
  ## argv（プログラム名を含まない）をパースする。不正な入力は `ArgvError`
  ## （構文レベルの誤り）または `ValueError`（`-L`/`-R` の値が ssh 互換文法として
  ## 不正。`parseForwardSpec` からそのまま伝播）を投げる。
  result = ParsedArgs(tailLines: defaultTailLines)

  if args.len == 0:
    result.helpRequested = true
    return

  var i = 0
  var literalOnly = false ## `--` 以降

  template nextValue(flagLabel: string): string =
    ## 値を取るフラグの共通処理。値が無ければ `ArgvError`。
    if i >= args.len:
      raise newException(ArgvError, flagLabel & " には値が必要です")
    let v = args[i]
    inc i
    v

  while i < args.len:
    let a = args[i]
    inc i

    if literalOnly:
      result.positional.add(a)
      continue

    if a == "--":
      literalOnly = true
      continue

    case a
    of "-h", "--help":
      result.helpRequested = true
      return
    of "--version":
      result.versionRequested = true
      return
    of "--json":
      result.json = true
    of "--no-color":
      result.noColor = true
    of "-v", "--verbose":
      result.verbose = true
    of "--quiet":
      result.quiet = true
    of "--no-autostart":
      result.noAutostart = true
    of "--config":
      result.configPath = nextValue(a)
    of "--file":
      result.configPath = nextValue(a)
    of "--follow":
      result.follow = true
    of "--name":
      result.name = nextValue(a)
    of "-L", "--local":
      let v = nextValue(a)
      result.localForwards.add(parseForwardArg(a, v, fkLocal))
    of "-R", "--remote":
      let v = nextValue(a)
      result.remoteForwards.add(parseForwardArg(a, v, fkRemote))
    of "-p", "--profile":
      result.profiles.add(nextValue(a))
    of "-a", "--all":
      result.all = true
    of "-q":
      result.quietList = true
    of "--probe":
      result.probe = true
    of "--immediate":
      result.immediate = true
    of "-f":
      # -f の意味は subcommand によって変わる（モジュール doc comment 参照）。
      if result.subcommand == "logs":
        result.follow = true
      else:
        result.configPath = nextValue(a)
    of "-n":
      # -n も同様に subcommand で意味が変わる。
      if result.subcommand == "logs":
        let v = nextValue(a)
        try:
          result.tailLines = parseInt(v)
        except ValueError:
          raise newException(ArgvError, "-n の値が数値ではありません: " & v)
      else:
        result.name = nextValue(a)
    else:
      if a.len > 0 and a[0] == '-':
        raise newException(ArgvError, "未知のフラグです: " & a)

      # フラグではない素のトークン。subcommand / subsubcommand / positional の
      # どこに割り当てるべきかは、ここまでの状態次第で決まる。
      if result.subcommand.len == 0:
        case a
        of "version":
          result.versionRequested = true
          return
        of "help":
          result.helpRequested = true
          return
        of "ls":
          result.subcommand = "ps" ## docker compose 風のエイリアス
        else:
          result.subcommand = a
      elif result.subcommand in subsubcommandHosts and
          result.subsubcommand.len == 0:
        result.subsubcommand = a
        case result.subcommand
        of "daemon":
          if a notin daemonSubcommands:
            raise newException(ArgvError,
                "daemon の未知のサブコマンドです: " & a)
        of "completion":
          if a notin completionShells:
            raise newException(ArgvError,
                "completion の未知のシェルです: " & a)
        else:
          discard
      else:
        result.positional.add(a)

# ---------------------------------------------------------------------------
# ヘルプ文字列
# ---------------------------------------------------------------------------

const generalUsage = """
powarder - manage SSH port forwards like containers

Usage:
  powarder <command> [options] [args...]

Tunnel commands:
  run                        Create and start a new tunnel
  up                         Start tunnels defined in the config file
  down                       Stop tunnels defined in the config file
  start <name>...            Start an existing (stopped) tunnel
  stop <name>...             Stop a running tunnel
  restart <name>...          Restart a tunnel
  ps, ls                     List tunnels
  inspect <name>...          Show detailed tunnel info
  check <name>...            Health-check a tunnel
  logs <name>                Show tunnel logs
  rm <name>...               Remove a (stopped) tunnel
  prune                      Remove all stopped tunnels

Host commands:
  hosts                      List available SSH hosts (~/.ssh/config)

Daemon commands:
  daemon status|start|stop|restart|reload|install|uninstall|logs

Other commands:
  completion zsh|bash|fish   Print a shell completion script
  version                    Print the powarder version
  help                       Show this help

Global options:
  --json           Print machine-readable JSON instead of a table
  --no-color       Disable colored output
  -v, --verbose    Verbose logging
  --quiet          Suppress non-essential output
  --config PATH    Use PATH instead of the default config file
  --no-autostart   Do not autostart the daemon if it isn't running already

Run 'powarder help <command>' for details on a specific command."""

const runUsage = """
Usage: powarder run [options] <host>

Create and immediately start a new tunnel to <host> (an entry in
~/.ssh/config). Mirrors `ssh -L`/`ssh -R` syntax exactly, so an existing
`ssh -L 8080:localhost:80 host` becomes
`powarder run -L 8080:localhost:80 host`.

Options:
  -L [bind_address:]port:host:hostport   Local forward (repeatable)
  -R [bind_address:]port:host:hostport   Remote forward (repeatable)
  --name, -n NAME                        Tunnel name (default: random)
  --profile, -p PROFILE                  Attach to a config profile (repeatable)
  --no-autostart                         Do not autostart the daemon"""

const upDownUsage = """
Usage: powarder up [options]
       powarder down [options]

Start (or stop) every tunnel defined in the config file.

Options:
  -f, --file, --config PATH   Config file to use (default: XDG config path)
  --profile, -p PROFILE       Only tunnels tagged with PROFILE (repeatable)
  --immediate                 (down only) skip the graceful shutdown delay"""

const psUsage = """
Usage: powarder ps [options]

List tunnels (alias: ls).

Options:
  -a, --all      Show stopped tunnels too (default: running only)
  -q             Only print tunnel names
  --probe        Opt into an active Tier2 health check before listing
  --json         Print machine-readable JSON instead of a table"""

const logsUsage = """
Usage: powarder logs [options] <name>

Show logs for tunnel <name>.

Options:
  -f, --follow    Follow log output (like `tail -f`)
  -n LINES        Number of lines to show from the end (default: 50)"""

const daemonUsage = """
Usage: powarder daemon <status|start|stop|restart|reload|install|uninstall|logs>

Manage the powarder background daemon."""

const completionUsage = """
Usage: powarder completion <zsh|bash|fish>

Print a shell completion script to stdout."""

proc usage*(subcommand = ""): string =
  ## ヘルプ文字列。`subcommand` が空なら全体のヘルプ、指定があればそのサブコマンドの
  ## 詳細（未知の場合は全体のヘルプにフォールバックする）。
  case subcommand
  of "":
    generalUsage
  of "run":
    runUsage
  of "up", "down":
    upDownUsage
  of "ps", "ls":
    psUsage
  of "logs":
    logsUsage
  of "daemon":
    daemonUsage
  of "completion":
    completionUsage
  else:
    generalUsage
