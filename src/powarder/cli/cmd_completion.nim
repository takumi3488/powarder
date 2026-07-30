## Generation of shell completion scripts.
##
## Since macOS is the primary target, zsh gets full, first-class support,
## while bash / fish are kept to a simple version that only completes
## subcommand names.
##
## Dynamic completion of tunnel names (e.g. `powarder start <TAB>`) can be
## written by calling `powarder ps -q`, but **this fails if the daemon isn't
## running**. To avoid a broken completion script taking down other completions
## with it, failures are swallowed with `2>/dev/null`; an empty result simply
## means no candidates are shown.
##
## This module only returns static strings; it doesn't write to files or
## invoke a shell itself (`echo`-ing the result is the caller's job, in
## `cli/dispatch.nim`).

const
  zshScript = """#compdef powarder

_powarder_tunnel_names() {
  local -a names
  names=("${(@f)$(powarder ps -q 2>/dev/null)}")
  if [[ -n "$names[1]" ]]; then
    _describe 'tunnel' names
  fi
}

_powarder() {
  local -a subcommands
  subcommands=(
    'run:Create and start a new tunnel'
    'up:Start tunnels defined in the config file'
    'down:Stop tunnels defined in the config file'
    'start:Start an existing (stopped) tunnel'
    'stop:Stop a running tunnel'
    'restart:Restart a tunnel'
    'ps:List tunnels'
    'ls:List tunnels (alias for ps)'
    'inspect:Show detailed tunnel info'
    'check:Health-check a tunnel'
    'logs:Show tunnel logs'
    'rm:Remove a (stopped) tunnel'
    'prune:Remove all stopped tunnels'
    'hosts:List available SSH hosts'
    'daemon:Manage the background daemon'
    'completion:Print a shell completion script'
    'version:Print the powarder version'
    'help:Show help'
  )

  local -a daemon_subcommands
  daemon_subcommands=(
    'status:Show daemon status'
    'start:Start the daemon'
    'stop:Stop the daemon'
    'restart:Restart the daemon'
    'reload:Reload the config file'
    'install:Install the daemon as a system service'
    'uninstall:Uninstall the daemon system service'
    'logs:Show daemon logs'
  )

  local curcontext="$curcontext" state line
  _arguments -C \
    '--json[Print machine-readable JSON instead of a table]' \
    '--no-color[Disable colored output]' \
    '(-v --verbose)'{-v,--verbose}'[Verbose logging]' \
    '--quiet[Suppress non-essential output]' \
    '--config[Use PATH instead of the default config file]:file:_files' \
    '--no-autostart[Do not autostart the daemon if it is not running]' \
    '1: :->cmd' \
    '*:: :->args' \
    && return 0

  case $state in
    cmd)
      _describe -t commands 'powarder command' subcommands
      ;;
    args)
      case $line[1] in
        daemon)
          _describe -t daemon_subcommands 'daemon subcommand' daemon_subcommands
          ;;
        completion)
          local -a shells
          shells=(zsh bash fish)
          _describe -t shells 'shell' shells
          ;;
        start|stop|restart|rm|inspect|check|logs)
          _powarder_tunnel_names
          ;;
      esac
      ;;
  esac
}

_powarder "$@"
"""

  bashScript = """# powarder bash completion (simple: subcommand names only)
_powarder_completions() {
  local cur
  cur="${COMP_WORDS[COMP_CWORD]}"
  local commands="run up down start stop restart ps ls inspect check logs rm prune hosts daemon completion version help"
  if [ "$COMP_CWORD" -eq 1 ]; then
    COMPREPLY=($(compgen -W "$commands" -- "$cur"))
    return 0
  fi
  if [ "$COMP_CWORD" -eq 2 ] && [ "${COMP_WORDS[1]}" = "daemon" ]; then
    COMPREPLY=($(compgen -W "status start stop restart reload install uninstall logs" -- "$cur"))
    return 0
  fi
  if [ "$COMP_CWORD" -eq 2 ] && [ "${COMP_WORDS[1]}" = "completion" ]; then
    COMPREPLY=($(compgen -W "zsh bash fish" -- "$cur"))
    return 0
  fi
}
complete -F _powarder_completions powarder
"""

  fishScript = """# powarder fish completion (simple: subcommand names only)
set -l powarder_commands run up down start stop restart ps ls inspect check logs rm prune hosts daemon completion version help

complete -c powarder -f -n '__fish_use_subcommand' -a "$powarder_commands"
complete -c powarder -f -n '__fish_seen_subcommand_from daemon' -a 'status start stop restart reload install uninstall logs'
complete -c powarder -f -n '__fish_seen_subcommand_from completion' -a 'zsh bash fish'
"""

proc completionScript*(shell: string): string =
  ## Returns the completion script for `shell` ("zsh" / "bash" / "fish").
  ## Raises `ValueError` for an unknown shell.
  case shell
  of "zsh": zshScript
  of "bash": bashScript
  of "fish": fishScript
  else: raise newException(ValueError, "unknown shell: " & shell)
