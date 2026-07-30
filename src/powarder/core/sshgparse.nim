## A pure module that parses `ssh -G <host>` output (the resolved ssh_config).
##
## Rather than reimplementing ssh_config's `Host` block, `Match`, `Include`,
## `%h`/`%p`/`%r` expansion, and `ProxyJump` resolution itself, powarder stays
## fully compatible with all of these by trusting the result that OpenSSH
## itself produces via `ssh -G <host>`. This module **only receives that
## stdout string and parses it**; the I/O of actually running `ssh -G` is the
## responsibility of a different layer (the daemon layer). This module does
## not import `std/asyncnet` / `std/osproc` / `std/os`.
##
## Important note (a contract the caller must honor):
## the only thing that may be passed to `parseSshG` is **the stdout of
## `ssh -G`**. Depending on how it's run, OpenSSH may emit a line like
## `Pseudo-terminal will not be allocated because stdin is not a terminal.`
## on stderr, but this must not be mixed in. To contain the damage even if it
## does get mixed in, this is implemented robustly so that any line not
## matching the `<lowercase key> <value>` format is silently ignored instead
## of raising an exception.

import std/[tables, strutils, sequtils, algorithm]

import powarder/core/hashid

type
  SshConfigResolved* = object
    ## Holds the resolved result of `ssh -G`. Keys are always lowercase.
    ## Because some keys, like `identityfile` / `sendenv`, can appear on
    ## multiple lines within a single `ssh -G` output, this is uniformly
    ## designed to hold even single-value keys as `seq[string]`
    ## (use `getFirst` when you want a single value).
    values*: Table[string, seq[string]]

const
  fingerprintExcludedKeys* = ["sessiontype", "requesttty", "stdinnull",
                              "forkafterauthentication"]
    ## Keys excluded from the `fingerprint` computation.
    ##
    ## Since powarder always starts the forwarding master with `ssh -N` (no
    ## remote command execution), these keys are effectively constant from
    ## powarder's point of view regardless of the ssh_config setting, and
    ## don't contribute to the "can this share the same connection?" identity
    ## judgment.
    ##
    ## Conversely, any key not listed here (including `host`, and every other
    ## key `ssh -G` returns) is never excluded. Excluding too much risks the
    ## accident of "sharing the same ControlMaster even though the settings
    ## actually differ", so when in doubt about whether to include a key,
    ## always err on the side of including it.

proc isPlausibleKey(s: string): bool =
  ## Every key `ssh -G` actually emits is made up of lowercase ASCII letters
  ## only (e.g. `identityfile`, `kbdinteractiveauthentication`).
  ## Even if a stderr warning line slips in, its first word (e.g.
  ## `pseudo-terminal` from `Pseudo-terminal`) contains a hyphen and so
  ## differs in shape from a real key, letting this check filter it out.
  s.len > 0 and s.allCharsInSet({'a'..'z'})

proc parseSshG*(stdout: string): SshConfigResolved =
  ## Parses `ssh -G`'s stdout.
  ##
  ## Each line has the form `<lowercase key><1+ whitespace><value>`
  ## (empirically, OpenSSH uses a single half-width space between key and
  ## value). Lines that don't match this format (blank lines, key-only lines,
  ## lines where the key isn't made up of lowercase ASCII letters only, etc.)
  ## are silently ignored. If a stderr warning line
  ## (`Pseudo-terminal will not be allocated because ...`) accidentally gets
  ## mixed in, it too is ignored by this same check.
  result = SshConfigResolved(values: initTable[string, seq[string]]())
  for rawLine in stdout.splitLines():
    let line = rawLine.strip()
    if line.len == 0:
      continue
    let parts = line.splitWhitespace(maxsplit = 1)
    if parts.len != 2:
      continue
    let key = parts[0].toLowerAscii()
    if not isPlausibleKey(key):
      continue
    result.values.mgetOrPut(key, @[]).add(parts[1])

proc get*(r: SshConfigResolved; key: string): seq[string] =
  ## Returns the seq of values corresponding to `key`. Empty seq if absent.
  r.values.getOrDefault(key.toLowerAscii())

proc getFirst*(r: SshConfigResolved; key: string; default = ""): string =
  ## Returns the first value for `key`. `default` if absent.
  let vals = r.get(key)
  if vals.len > 0: vals[0] else: default

proc has*(r: SshConfigResolved; key: string): bool =
  ## Whether `key` exists at all.
  key.toLowerAscii() in r.values

proc fingerprint*(r: SshConfigResolved): string =
  ## Builds a deterministic fingerprint from the resolved config.
  ##
  ## To make powarder "share a single ControlMaster for the same ssh
  ## connection settings", this function is used so that both a change in
  ## `host` (HostSessionKey.host) and a change in `sshExtraArgs` (which
  ## doesn't appear in ssh_config but is passed at runtime via `-o` etc. and
  ## reflected into `ssh -G`'s resolved result) can be treated uniformly as
  ## "a change in the resolved-config key".
  ##
  ## Steps:
  ## 1. Exclude the keys listed in `fingerprintExcludedKeys`
  ## 2. Sort the remaining keys and normalize them (fixing the key order
  ##    means the same content produces the same result regardless of the
  ##    line order in `ssh -G`'s output)
  ## 3. Preserve the order in which values appear within each key (not
  ##    sorted, since it can carry meaning, e.g. `identityfile`'s priority
  ##    order)
  ## 4. Run the normalized string through `hashid.hashHex` and return 16
  ##    digits (64 bits, lowercase hex). At 64 bits, collisions are
  ##    effectively impossible.
  var keys = toSeq(r.values.keys).filterIt(it notin fingerprintExcludedKeys)
  keys.sort()
  var normalized = ""
  for k in keys:
    normalized.add(k)
    normalized.add('=')
    normalized.add(r.values[k].join(","))
    normalized.add(';')
  result = hashHex(normalized, 16)
