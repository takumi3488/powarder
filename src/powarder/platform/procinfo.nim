## Checking process liveness, and verifying identity against the recorded
## argv.
##
## Used when adopting (taking over) an ssh master process left behind after
## the daemon crashed, to confirm "is this PID really the ssh I launched."
## Merely checking whether the PID is alive would misidentify the case where,
## before the daemon restarts, the OS reuses the same PID for an unrelated
## process (PID reuse), so the recorded argv is cross-checked against the
## process's actual command line to verify identity.

import std/[os, osproc, posix, strutils]

proc pidAlive*(pid: int): bool =
  ## `kill(pid, 0)` only checks existence without sending a signal.
  ## - Success (0): alive.
  ## - `ESRCH`: does not exist -> false.
  ## - `EPERM`: exists but no permission (e.g. different owner) -> here it
  ##   is treated as true, since "we know it exists."
  if kill(Pid(pid), 0.cint) == 0:
    return true
  cint(osLastError()) == EPERM

when defined(linux):
  proc processCmdline*(pid: int): string =
    ## On Linux, reading `/proc/<pid>/cmdline` is more accurate than `ps`.
    ## Since arguments are separated by NUL bytes, argument boundaries are
    ## not misdetected even if an argument contains whitespace. Returns an
    ## empty string if it cannot be obtained.
    try:
      let raw = readFile("/proc" / $pid / "cmdline")
      raw.replace("\0", " ").strip()
    except CatchableError:
      ""
else:
  proc processCmdline*(pid: int): string =
    ## On macOS and similar systems there is no `/proc`, so `ps` is used
    ## instead.
    ##
    ## **Always pass `-ww`.** By default `ps` truncates the command line
    ## length to the terminal width or an internal default. Since the ssh
    ## that powarder launches has a long argument list like
    ## `-o BatchMode=yes -o ControlPersist=no -o ServerAliveInterval=15 ...`,
    ## without `-ww` (removing the output width limit) the matching done by
    ## `cmdlineMatches` gets cut off partway and fails. Returns an empty
    ## string if it cannot be obtained.
    try:
      execProcess("ps", args = ["-wwo", "command=", "-p", $pid],
                  options = {poUsePath}).strip()
    except CatchableError:
      ""

proc cmdlineMatches*(pid: int; expected: openArray[string]): bool =
  ## Determines this by checking whether **every element** of the recorded
  ## argv (`expected`) is contained as a substring in the actual process's
  ## command line string. An exact match is not required.
  ##
  ## Rationale: the output of `ps` (and of joining `/proc/pid/cmdline` with
  ## spaces) is simply a concatenation of arguments, and the original
  ## argument boundaries and quoting cannot be recovered. Therefore a
  ## "strict argv comparison" is impossible in principle, and a loose
  ## containment check is used instead.
  ##
  ## Design conscious of the asymmetry: on a mismatch, lean toward "do not
  ## adopt = do nothing."
  ## - A false negative (judging a mismatch even though it is actually a
  ##   process we launched) is acceptable. At worst it just means we fail
  ##   to adopt and relaunch ssh, which is low-impact.
  ## - A false positive (mistaking an unrelated process for our own and
  ##   adopting it) is avoided, since it could cause an accident such as
  ##   issuing `-O cancel` etc. against an unrelated process.
  ## Requiring containment of every element of `expected` (an AND
  ## condition) makes the judgment less prone to leaning toward false
  ## positives.
  let actual = processCmdline(pid)
  if actual.len == 0:
    return false
  for e in expected:
    if e notin actual:
      return false
  true
