## The argv parser for the powarder CLI.
##
## Borrows vocabulary from docker / docker compose / systemctl / tailscale, but
## only `-L` / `-R` are accepted with a syntax fully compatible with ssh itself
## (via `parseForwardSpec`). This lets an existing `ssh -L ... host` be migrated
## by mechanically rewriting it to `powarder run -L ... host`.
##
## **`std/parseopt` is not used.** There is no subcommand mechanism, and
## managing a space-separated, value-taking short flag like `-L 8080:localhost:80`
## via a `shortNoVal` set doesn't play well with ssh-compatible syntax (it would
## need its own splitting logic that assumes the `-L` value is a single token
## containing `:`, and at that point parseopt buys us little). Instead this is
## implemented as a plain state machine that scans argv from the front.
##
## ### On the ambiguity of `-f` / `-n`
##
## We allow the same kind of overloading docker uses, where `docker logs -f`
## (follow) and `docker up -f FILE` (compose file) give the same `-f` two
## different meanings. **We resolve this by looking at the current subcommand
## before interpreting `-f`**:
##
## - When `subcommand == "logs"`, `-f` means `follow` (takes no value)
## - Otherwise, `-f` is an alias for `--config` (takes one value)
##
## Likewise, `-n` means something different under `logs` (`tailLines`, an
## integer value) than under any other subcommand (short form of `--name`, a
## string value). Since it's the same kind of ambiguity, we resolve it the same
## way: branch on the subcommand. The long forms (`--follow` / `--file` /
## `--config` / `--name`) mean the same thing under every subcommand, so
## scripts that want to avoid the `-f` / `-n` ambiguity can use those instead.
##
## This module performs no I/O.

import std/strutils
import powarder/core/types
import powarder/core/forwardspec

type
  ParsedArgs* = object
    subcommand*: string ## "run", "up", "ps", "daemon", etc. Empty means unspecified (show help)
    subsubcommand*: string ## "status" from "daemon status", "zsh" from "completion zsh"
    positional*: seq[string]          ## Tunnel names or host names
    localForwards*: seq[ForwardSpec]  ## Repeated -L (parsed with fkLocal)
    remoteForwards*: seq[ForwardSpec] ## Repeated -R (parsed with fkRemote)
    name*: string                     ## --name / -n
    configPath*: string               ## --config / -f / --file
    profiles*: seq[string]            ## Repeated --profile / -p
    tailLines*: int                   ## logs -n (default 50)
    json*: bool
    noColor*: bool
    verbose*: bool
    quiet*: bool
    all*: bool                        ## ps -a
    quietList*: bool                  ## ps -q (print names only)
    follow*: bool                     ## logs -f
    probe*: bool                      ## ps --probe (opt into Tier2 health check)
    noAutostart*: bool
    immediate*: bool                  ## down skips the grace period
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
    ## Only these subcommands consume the next token as a subsubcommand.

proc parseForwardArg(flag, value: string; kind: ForwardKind): ForwardSpec =
  ## Calls `parseForwardSpec` and, on failure, re-raises it **as the same
  ## ValueError** (so callers see it as having simply propagated through).
  ## However, it prefixes the message with which flag's value was bad (`-L` or
  ## `-R`, plus the value actually given). `parseForwardSpec`'s own message
  ## includes the original string, but only this call site knows whether it
  ## came from `-L` or `-R`.
  try:
    parseForwardSpec(value, kind)
  except ValueError as e:
    raise newException(ValueError, flag & " " & value & ": " & e.msg)

proc parseArgv*(args: openArray[string]): ParsedArgs =
  ## Parses argv (not including the program name). Invalid input raises
  ## `ArgvError` (a syntax-level error) or `ValueError` (the `-L`/`-R` value is
  ## invalid as ssh-compatible syntax; propagated as-is from
  ## `parseForwardSpec`).
  result = ParsedArgs(tailLines: defaultTailLines)

  if args.len == 0:
    result.helpRequested = true
    return

  var i = 0
  var literalOnly = false ## After `--`

  template nextValue(flagLabel: string): string =
    ## Common handling for flags that take a value. Raises `ArgvError` if no
    ## value follows.
    if i >= args.len:
      raise newException(ArgvError, flagLabel & " requires a value")
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
      # The meaning of -f depends on the subcommand (see module doc comment).
      if result.subcommand == "logs":
        result.follow = true
      else:
        result.configPath = nextValue(a)
    of "-n":
      # -n likewise changes meaning depending on the subcommand.
      if result.subcommand == "logs":
        let v = nextValue(a)
        try:
          result.tailLines = parseInt(v)
        except ValueError:
          raise newException(ArgvError, "-n value is not a number: " & v)
      else:
        result.name = nextValue(a)
    else:
      if a.len > 0 and a[0] == '-':
        raise newException(ArgvError, "unknown flag: " & a)

      # A bare token that isn't a flag. Where it should be assigned -
      # subcommand / subsubcommand / positional - depends on the state so far.
      if result.subcommand.len == 0:
        case a
        of "version":
          result.versionRequested = true
          return
        of "help":
          result.helpRequested = true
          return
        of "ls":
          result.subcommand = "ps" ## docker compose-style alias
        else:
          result.subcommand = a
      elif result.subcommand in subsubcommandHosts and
          result.subsubcommand.len == 0:
        result.subsubcommand = a
        case result.subcommand
        of "daemon":
          if a notin daemonSubcommands:
            raise newException(ArgvError,
                "unknown daemon subcommand: " & a)
        of "completion":
          if a notin completionShells:
            raise newException(ArgvError,
                "unknown completion shell: " & a)
        else:
          discard
      else:
        result.positional.add(a)

# ---------------------------------------------------------------------------
# Help strings
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
  ## The help string. If `subcommand` is empty, returns the overall help;
  ## otherwise returns details for that subcommand (falling back to the
  ## overall help if unknown).
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
