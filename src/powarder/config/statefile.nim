## Runtime state written only by the daemon (`~/.local/state/powarder/state.json`).
##
## Its primary purpose is **recording what's needed to adopt orphaned
## masters (ControlMaster / forward UDS sockets) after the daemon crashes**.
## This is a separate module from `configfile.nim`, which the user edits by
## hand, and it has a different schema too (this one records runtime facts,
## and the daemon's convenience takes priority; human readability is
## secondary).
##
## The JSON conversion of `PersistedForward.spec` (`ForwardSpec`) and the
## various enums is not hand-written in this module. Since `core/types.nim`
## provides `` `%`*(p: Port) ``, `std/json`'s generic `%` / `to()` can
## recursively convert this module's types as-is (including `ForwardSpec`
## and the enums). The types defined here, such as `PersistedForward`,
## don't themselves contain a variant object, so no additional hand-written
## converters were needed.
##
## (`%`(Port) used to live in `ipc/protocol.nim`, and this module imported
## it from there. But since that overload is only ever used via generic
## dispatch, the compiler falsely flagged it as `imported and not used` --
## an awkward situation where following the warning's advice and removing
## the import caused a compile error. Moving it to live alongside the type
## resolved this.)

import std/[json, os, times]
import powarder/core/types

type
  PersistedForward* = object
    id*: string
    tunnelName*: string
    spec*: ForwardSpec
    state*: ForwardState
    udsPath*: string

  PersistedHostSession* = object
    host*: string
    fingerprint*: string
    ctlPath*: string
    logPath*: string
    pid*: int
    argv*: seq[string] ## used to cross-check against `ps` output when adopting
    state*: HostSessionState
    forwardIds*: seq[string]

  PersistedState* = object
    version*: int
    savedAt*: string ## ISO8601 format. For debugging (see `stampSavedAt` below)
    activeProfiles*: seq[string]
      ## The set of config-file profiles active for this daemon session, as
      ## fixed by `powarder up --profile X`. Persisted here because
      ## `reconcile.isTargeted` only targets a tunnel whose non-empty
      ## `profile` appears in `DesiredState.activeProfiles`; if this is lost
      ## on restart, every profile-tagged tunnel silently stays down even
      ## with `autostart: true`.
    hosts*: seq[PersistedHostSession]
    forwards*: seq[PersistedForward]

const
  savedAtFormat = "yyyy-MM-dd'T'HH:mm:sszzz"
    ## The explicit format string passed to `times.format`. Equivalent to
    ## ISO8601 (e.g. "2026-07-29T13:45:12+09:00"). `$now()` produces a
    ## string that looks the same, but pinning the format here keeps this
    ## from breaking in the future if `times`'s default `$` representation
    ## changes.

proc stampSavedAt(): string =
  now().format(savedAtFormat)

proc emptyState*(): PersistedState =
  ## An empty `PersistedState`. `hosts` / `forwards` / `activeProfiles` are
  ## empty sequences, `version` is 1.
  PersistedState(version: 1, savedAt: "", activeProfiles: @[], hosts: @[], forwards: @[])

proc loadState*(path: string): PersistedState =
  ## **Never raises, even if the file is corrupted.** If the JSON is
  ## broken, the schema doesn't match, or the file doesn't exist, returns
  ## an empty `PersistedState` (`emptyState()`).
  ##
  ## This is a deliberate design decision: the state file is nothing more
  ## than a "hint to make reconnecting after a crash more efficient" --
  ## the daemon still works without it (it just reconnects to every host
  ## instead). On the other hand, raising here would prevent the daemon
  ## itself from starting up, which is far more harmful than "losing one
  ## hint and reconnecting". So this errs on the side of "lose the state
  ## and safely start over".
  ##
  ## As long as a schema change is purely additive (like `activeProfiles`
  ## below), this file stays readable by both old and new powarder
  ## binaries: `loadState` backfills keys that older state files lack
  ## before converting, so a pre-`activeProfiles` file keeps its `hosts` /
  ## `forwards` instead of being discarded as "schema doesn't match".
  if not fileExists(path):
    return emptyState()
  try:
    let content = readFile(path)
    var node = parseJson(content)
    # Backfill `activeProfiles` for state files written before this field
    # existed. `std/json`'s `to()` raises `KeyError` on a missing object
    # field, and the `except CatchableError` below would turn that into
    # `emptyState()` -- silently discarding the `hosts` / `forwards`
    # records that `daemon/orphan.adoptOrphans` needs, i.e. leaking live
    # orphan ControlMasters on the very first startup after an upgrade.
    if node.kind == JObject and not node.hasKey("activeProfiles"):
      node["activeProfiles"] = newJArray()
    result = node.to(PersistedState)
  except CatchableError:
    result = emptyState()

proc saveState*(path: string; st: PersistedState) =
  ## Saves `st` as JSON. **Writes to a temporary file, then atomically
  ## replaces it with `moveFile`.** If a half-written JSON file is left
  ## behind because of a crash at the wrong moment, adoption breaks. The
  ## temp file is created in the same directory as `path` (crossing
  ## filesystems would make the rename non-atomic).
  ##
  ## `savedAt` ignores whatever value the caller set and is always
  ## overwritten with the moment of saving
  ## (`now().format("yyyy-MM-dd'T'HH:mm:sszzz")`). Since this field means
  ## "the time it was last saved", the decision here is that the "save"
  ## operation itself should be the sole source of that value.
  var toWrite = st
  toWrite.savedAt = stampSavedAt()

  let dir = path.parentDir
  if dir.len > 0:
    createDir(dir)

  let tmpPath = path & ".tmp." & $getCurrentProcessId()
  writeFile(tmpPath, (%toWrite).pretty())
  # **Set permissions to 0600 before renaming.** `writeFile` creates the
  # file with umask-dependent permissions (644 in most environments),
  # which would otherwise leave it readable by group/other. This JSON
  # contains the target hostnames, internal network addresses, UDS paths,
  # and PIDs, so there's no reason to expose it to other users. Dropping
  # permissions **before** the rename matters (doing it after would leave
  # a brief window where it's visible as 644).
  setFilePermissions(tmpPath, {fpUserRead, fpUserWrite})
  moveFile(tmpPath, path)
