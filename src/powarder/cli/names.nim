## Automatic naming for ad-hoc `powarder run` invocations that omit `--name`.
##
## Follows the "adjective-noun" style docker uses for names like
## "boring_wozniak". `randomName()` uses `std/random`'s **global** default RNG.
## It calls `randomize()` (which reseeds the global state from the current
## time) before every use, and that call is exactly what guarantees "a
## different name every time." The CLI calls `run` at most a handful of times
## per invocation, so the cost of reseeding every time is negligible.
##
## Use `randomName(seed)` when a test needs a deterministic result. It creates
## its own dedicated `Rand` via `initRand(seed)` each time, touching no global
## state at all, so it never pollutes the global RNG state used by other tests
## or other modules.
##
## This module performs no I/O beyond advancing RNG state on each call
## (`randomName()` advances global state, `randomName(seed)` advances a local
## variable).

import std/random

const
  adjectives = [
    "brave", "calm", "clever", "cosmic", "curious", "daring", "eager", "fancy",
    "feisty", "fierce", "gentle", "giant", "happy", "hasty", "humble", "jolly",
    "keen", "kind", "lively", "lonely", "loyal", "lucky", "mellow", "merry",
    "mighty", "nimble", "noble", "patient", "plucky", "proud", "quiet", "quick",
    "rapid", "sharp", "shiny", "silent", "sly", "snappy", "solid", "sturdy",
    "sunny", "swift", "tidy", "tiny", "witty",
  ]

  nouns = [
    "otter", "falcon", "badger", "heron", "panther", "sparrow", "walrus",
    "beetle", "gopher", "jaguar", "kestrel", "lemur", "marmot", "ocelot",
    "penguin", "quokka", "raven", "serval", "tapir", "urchin", "viper",
    "weasel", "yak", "zebra", "bison", "cobra", "dingo", "eagle", "ferret",
    "gecko", "hedgehog", "ibex", "jackal", "koala", "lynx", "mongoose", "newt",
    "orca", "puffin", "quail", "rabbit", "salamander", "toucan", "vulture",
    "wombat",
  ]

proc joinName(adjIdx, nounIdx: int): string =
  adjectives[adjIdx] & "-" & nouns[nounIdx]

proc randomName*(seed: int): string =
  ## Deterministic variant (for tests). Always returns the same name for the
  ## same `seed`. Uses a dedicated `Rand` that never touches global RNG state.
  var rng = initRand(seed.int64)
  joinName(rng.rand(adjectives.high), rng.rand(nouns.high))

proc randomName*(): string =
  ## Non-deterministic variant. Reseeds `std/random`'s global default RNG from
  ## the current time before use (see the module doc comment).
  randomize()
  joinName(rand(adjectives.high), rand(nouns.high))
