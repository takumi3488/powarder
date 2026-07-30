## powarder's version.
##
## If the CLI (`cli/dispatch`), the daemon (`daemon/run`), and the entry point
## (`powarder.nim`) each kept their own independent string literal, they would
## inevitably drift out of sync, so this is the single source of truth.
##
## nimble builds by passing `-d:NimblePkgVersion=<version>`, which we receive
## here via `{.strdefine.}`. That means **`version` in `powarder.nimble` is the
## true single source of truth**, and there's no need to write the version
## anywhere in Nim. A plain `nim c` that bypasses `nimble` uses the fallback
## value below.

const NimblePkgVersion {.strdefine.} = "0.1.0"

const powarderVersion* = NimblePkgVersion
