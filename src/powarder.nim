## powarder — a CLI + background daemon that manages SSH local/remote port forwards
##
## Entry point. Keep this a thin layer that only parses arguments and hands them
## off to `cli/dispatch`.
##
## `cli/` does not import `daemon/` (so the daemon itself doesn't need to be
## linked into the CLI, and so the CLI layer can be tested without the daemon).
## The only path that needs to connect the two is `powarder daemon` starting the
## daemon itself, so here we inject a function as `DaemonRunner`.

import std/os
import powarder/version
import powarder/cli/argv
import powarder/cli/dispatch
import powarder/daemon/run as daemonRun

export powarderVersion

when isMainModule:
  var args: ParsedArgs
  try:
    args = parseArgv(commandLineParams())
  except ArgvError, ValueError:
    # `dispatch` assumes it receives an already-parsed, valid `ParsedArgs`, so
    # reject invalid arguments here with a usage error (exit code 2).
    stderr.writeLine("powarder: " & getCurrentExceptionMsg())
    stderr.writeLine("powarder: run 'powarder help' for usage")
    quit(int(ecUsage))

  # The daemon itself, started in the foreground by `powarder daemon` (with no
  # subsubcommand). `--config` and `--profile` need to be passed through to the
  # daemon as well, so forward them.
  let runDaemonImpl: DaemonRunner = proc (): int =
    daemonRun.runDaemon(daemonRun.DaemonOpts(
      configPath: args.configPath,
      activeProfiles: args.profiles))

  quit(dispatch(args, runDaemonImpl))
