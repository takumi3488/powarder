## The layer that runs `ssh` as a ControlMaster, and runs `-O forward` /
## `-O cancel` / `-O check` / `-O exit` / `-G` as short-lived processes to
## obtain their results.
##
## **Judgement logic is not placed here.** The success/failure judgement
## for `ssh -O ...` (message matching, priority order) is already
## implemented as pure functions in `core/muxparse.nim`, and the parsing
## of `ssh -G` output is in `core/sshgparse.nim`. This module focuses
## solely on "start the process and obtain `(exitCode, stdout, stderr)`"
## and "pass that triple through to the modules above as-is".
##
## ## Care taken when capturing stdout / stderr separately (the core of this module)
##
## When you receive a child process's stdout and stderr as separate pipes
## with `std/osproc`, and call `waitForExit` before reading from them, the
## child process blocks once a pipe's buffer fills up, and the parent
## never returns from `waitForExit` -- a deadlock
## (https://github.com/nim-lang/Nim/issues/956).
##
## On the other hand, if we merge them into a single stream with
## `poStdErrToStdOut`, we lose the ability to distinguish stdout from
## stderr. That is not acceptable for powarder:
## - The `Master running (pid=N)` that `-O check` prints for a live
##   master comes out on **stderr** (verified empirically)
## - A dynamically-assigned port number like `-R 0:...` comes out on
##   **stdout**, because `mux.c` prints it via `fprintf(stdout, ...)`
##
## So we avoid pipes entirely and instead run via a shell redirect --
## `/bin/sh -c '... >outfile 2>errfile'` -- dropping the output into
## files, then read each file after `waitForExit` returns. Since the
## child process's output goes to files rather than pipes, the situation
## of a pipe buffer filling up never arises in the first place, so the
## #956 deadlock cannot happen by construction. (powarder also redirects
## the master's log output via a shell redirect for the same reason. See
## `masterCommandLine`. The approach is kept consistent.)
##
## All `args` are escaped with `quoteShell` / `quoteShellCommand` before
## being embedded into the shell command string, so that things don't
## break even if a host name or path contains whitespace or shell special
## characters.

import std/[os, osproc]
import powarder/core/types
import powarder/core/muxparse
import powarder/core/sshgparse
import powarder/core/forwardspec
import powarder/core/paths

export MuxOutcome, SshConfigResolved

type
  MuxResult* = object
    exitCode*: int
    stdout*: string
    stderr*: string

var callCounter = 0
  ## Monotonically increasing counter used to build a unique temp file
  ## name for each `runSsh` call. The powarder daemon is premised on
  ## running as a single-threaded async event loop, but relying on the
  ## PID alone within the same process could still collide, hence this is
  ## combined with it.

proc nextTmpId(): string =
  inc callCounter
  $getCurrentProcessId() & "-" & $callCounter

proc ensureTmpDir(): string =
  ## Prepares a place to put temp files.
  ##
  ## `core/paths.ensureRuntimeDir()` validates against the `sun_path`
  ## length limit for ControlPath / forward UDS use, but what we put here
  ## is a plain file (not a UDS), so that validation is unnecessary and
  ## irrelevant. We just create the directory.
  result = runtimeDir()
  createDir(result)

proc runSsh*(args: openArray[string]): MuxResult =
  ## Runs `ssh` as a short-lived process and returns the exit code and
  ## stdout/stderr separately. Since we drop the output into files via a
  ## shell redirect instead of using pipes, the #956 deadlock cannot occur
  ## (see the module doc comment for details).
  let dir = ensureTmpDir()
  let id = nextTmpId()
  let outPath = dir / ("mux-" & id & ".out")
  let errPath = dir / ("mux-" & id & ".err")

  let sshArgs = @["ssh"] & @args
  # There's no strict necessity here for `exec` to replace the sh process
  # itself with ssh, but we use the same idiom to keep the approach
  # consistent with masterCommandLine.
  let cmd = "exec " & quoteShellCommand(sshArgs) &
    " >" & quoteShell(outPath) & " 2>" & quoteShell(errPath)

  var exitCode: int
  try:
    let process = startProcess("/bin/sh", args = ["-c", cmd], options = {})
    try:
      exitCode = process.waitForExit()
    finally:
      process.close()

    let outData = if fileExists(outPath): readFile(outPath) else: ""
    let errData = if fileExists(errPath): readFile(errPath) else: ""
    result = MuxResult(exitCode: exitCode, stdout: outData, stderr: errData)
  finally:
    # `os.removeFile` is unlink, so it's not an error if the target
    # doesn't exist. We use try/finally to reliably remove it so no temp
    # file is left behind.
    removeFile(outPath)
    removeFile(errPath)

proc checkMaster*(ctlPath, host: string): tuple[alive: bool, pid: int] =
  ## `ssh -S <ctlPath> -O check <host>`.
  ## Judgement is delegated to `core/muxparse.parseCheckResult`.
  let r = runSsh(["-S", ctlPath, "-O", "check", host])
  parseCheckResult(r.exitCode, r.stdout, r.stderr)

proc addForward*(ctlPath, host: string; spec: ForwardSpec;
    udsPath = ""): MuxOutcome =
  ## `ssh -S <ctlPath> -O forward -L|-R <arg> <host>`.
  ## The argument string is built via `core/forwardspec.toSshForwardArg`.
  ## `spec.kind` is such that the `ForwardKind` enum value itself carries
  ## the string representation of `"L"` / `"R"`, so `$spec.kind` directly
  ## yields the `-L` / `-R` flag character. Judgement is delegated to
  ## `core/muxparse.parseForwardResult`.
  let arg = toSshForwardArg(spec, udsPath)
  let r = runSsh(["-S", ctlPath, "-O", "forward", "-" & $spec.kind, arg, host])
  parseForwardResult(r.exitCode, r.stdout, r.stderr)

proc cancelForward*(ctlPath, host: string; spec: ForwardSpec;
    udsPath = ""): MuxOutcome =
  ## `ssh -S <ctlPath> -O cancel -L|-R <arg> <host>`.
  ## **The exit code cannot be trusted at all** (measured in practice:
  ## cancel returns 0 both on success and on failure). Judgement is
  ## delegated to `core/muxparse.parseCancelResult`, which looks only at
  ## the stderr message.
  let arg = toSshForwardArg(spec, udsPath)
  let r = runSsh(["-S", ctlPath, "-O", "cancel", "-" & $spec.kind, arg, host])
  parseCancelResult(r.exitCode, r.stdout, r.stderr)

proc exitMaster*(ctlPath, host: string): MuxOutcome =
  ## `ssh -S <ctlPath> -O exit <host>`. Terminates the master.
  ##
  ## `core/muxparse.nim` has no dedicated judgement function for `-O
  ## exit`. The exit code for `-O exit` can be trusted the same way as
  ## for `-O forward` (0 on success / 255 if it can't connect to the
  ## control socket), so we delegate to `parseForwardResult` rather than
  ## `parseCancelResult` (which ignores the exit code and judges based on
  ## whether stderr is empty). This way, even if an incidental message
  ## like `Exit request sent.` appears on stderr on success, we can still
  ## correctly judge `moSuccess` by prioritizing exitCode 0, and the case
  ## where the control socket can't be reached is still correctly
  ## classified as `moNoMaster`.
  let r = runSsh(["-S", ctlPath, "-O", "exit", host])
  parseForwardResult(r.exitCode, r.stdout, r.stderr)

proc resolveSshConfig*(host: string; extraArgs: openArray[string] = []): SshConfigResolved =
  ## Runs `ssh -G <host> <extraArgs>` and parses it with
  ## `core/sshgparse.parseSshG`.
  ##
  ## **Only stdout is parsed.** stderr can have `Pseudo-terminal will not
  ## be allocated because stdin is not a terminal.` mixed into it
  ## (verified empirically). Since `runSsh` separates the two via the
  ## file-redirect approach, this is handled naturally simply by passing
  ## `r.stdout` alone here.
  let r = runSsh(@["-G", host] & @extraArgs)
  parseSshG(r.stdout)

proc masterCommandLine*(ctlPath, logPath, host: string;
                        extraArgs: openArray[string] = []): seq[string] =
  ## Builds the full command line for `/bin/sh -c 'exec ssh ...'` that
  ## starts the ControlMaster. **Does not start the process itself** (that
  ## is the responsibility of the hostsession layer). Also used to match
  ## against `ps` output during adopt (reconnecting to an existing
  ## process), so it always returns a deterministic string.
  ##
  ## Rationale for each option (confirmed via on-machine verification; do not change):
  ##
  ## - `exec`: replaces the `sh` process itself with `ssh`. This makes the
  ##   monitored PID the ssh binary itself rather than the wrapper sh
  ##   (verified empirically)
  ## - `-M -S <ctlPath>`: starts it as a ControlMaster, so forwards can be
  ##   attached afterward via `-O forward`
  ## - `-N`: don't execute a remote command
  ## - `-v`: makes ssh emit material on stderr for error classification
  ##   (used by `core/errorclass`)
  ## - `BatchMode=yes`: so a TTY-less daemon doesn't hang on an
  ##   interactive prompt
  ## - `ControlPersist=no`: **without this, the master would move to the
  ##   background just like `ssh -f`, get orphaned under PPID=1, and
  ##   become untrackable via `peekExitCode`.** Always explicitly
  ##   overridden in case the user's ssh_config has `ControlPersist` set
  ## - `StreamLocalBindUnlink=yes`: **required.** Even after `-O cancel`,
  ##   the socket file is left behind (ssh does not unlink it), so with
  ##   the default of `no`, re-attaching to the same UDS path would
  ##   **always fail** with exit 255 + `Port forwarding failed` (verified
  ##   empirically). This is a path we go through every time on re-attach
  ##   after a master reconnect, so without this, reconnection would fail
  ##   forever
  ## - `StreamLocalBindMask=0177`: makes the forward's UDS get created
  ##   with the equivalent of 0600
  ## - `ExitOnForwardFailure` is not set: since we never write `-L`/`-R`
  ##   into the master's command line and always attach everything
  ##   afterward via `-O forward`, we never go through the path where
  ##   this option would take effect (initial forward setup at startup).
  ##   Setting it would be meaningless, and the property that "a single
  ##   forward's failure doesn't take down the master" is already
  ##   guaranteed by OpenSSH's implementation regardless
  let sshArgs = @["ssh", "-M", "-S", ctlPath, "-N", "-v",
                  "-o", "BatchMode=yes",
                  "-o", "ControlPersist=no",
                  "-o", "ServerAliveInterval=15",
                  "-o", "ServerAliveCountMax=3",
                  "-o", "ConnectTimeout=10",
                  "-o", "StreamLocalBindMask=0177",
                  "-o", "StreamLocalBindUnlink=yes",
                  host] & @extraArgs
  let inner = "exec " & quoteShellCommand(sshArgs) &
    " >>" & quoteShell(logPath) & " 2>&1"
  @["/bin/sh", "-c", inner]
