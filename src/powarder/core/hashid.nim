## Stable hash for identifiers that get persisted.
##
## Both the UDS file name derived from `Forward.id` (`forwardspec.udsBasename`)
## and the fingerprint derived from the `ssh -G` resolution result
## (`sshgparse.fingerprint`) are persisted in `state.json`, and used by the
## adopt logic (`daemon/orphan.nim`) after a daemon restart to check "is this
## the same entity as before". In other words, the value must stay stable
## across process restarts, and even across Nim versions and compile flags.
##
## `std/hashes`'s `hash()` is not used, because that is an implementation
## detail of the Nim compiler/standard library: the algorithm can change with
## compile flags like `-d:nimStringHash2` or with a version upgrade. Using
## something with no stability guarantee to derive a persistence key means
## adopt could break unexpectedly one day.
##
## So FNV-1a 64-bit, whose specification is completely fixed, is implemented
## by hand instead. The purpose is only to produce a "short identifier
## unlikely to collide" -- there's no attacker with a motive to engineer a
## deliberate collision, so cryptographic strength (SHA-1-equivalent) isn't
## needed. A ~20-line FNV-1a is enough.

import std/strutils

const
  fnvOffsetBasis64: uint64 = 0xcbf29ce484222325'u64
  fnvPrime64: uint64 = 0x100000001b3'u64

proc fnv1a64*(s: string): uint64 =
  ## FNV-1a 64-bit hash.
  ##
  ## Specification (the FNV-1a algorithm at
  ## http://www.isthe.com/chongo/tech/comp/fnv/):
  ## ```
  ## hash = 0xcbf29ce484222325
  ## for each byte b in input:
  ##     hash = hash xor b
  ##     hash = hash * 0x100000001b3    (64bit wrap-around)
  ## ```
  ## `uint64` multiplication wraps around automatically in Nim, so overflow
  ## needs no special handling.
  result = fnvOffsetBasis64
  for ch in s:
    result = result xor uint64(ord(ch))
    result = result * fnvPrime64

proc hashHex*(s: string; digits: int): string =
  ## Returns `fnv1a64(s)` as lowercase hex, truncated to the first `digits`
  ## digits.
  ##
  ## `digits` must be in 1..16. A 64-bit hash value is exactly 16 hex digits
  ## long, so requesting more than 16 wouldn't carry any additional meaningful
  ## information anyway. Anything out of range is treated as a caller bug and
  ## raises a `Defect` (`AssertionDefect`).
  assert digits >= 1 and digits <= 16,
    "digits must be in the range 1..16: " & $digits
  let full = toLowerAscii(toHex(fnv1a64(s)))
  full[0 ..< digits]
