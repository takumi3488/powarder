## A declarative config file the user edits by hand (`powarder.json` /
## `~/.config/powarder/config.json`).
##
## **Uses JSON only** (`std/json`). No external nimble dependencies are added.
##
## Schema:
## ```jsonc
## {
##   "version": 1,
##   "tunnels": [
##     { "name": "prod-db", "host": "prod-bastion", "type": "L",
##       "forward": "15432:db.internal:5432", "autostart": true, "profile": "prod" }
##   ]
## }
## ```
## - `type` is `"L"` / `"R"` (corresponds 1:1 to `core/types.ForwardKind`'s string values).
## - `forward` is an ssh-fully-compatible `[bind_address:]port:host:hostport` string.
##   Parsed by `core/forwardspec.parseForwardSpec()`.
## - `autostart` / `profile` / `sshExtraArgs` / `retry` are optional (they have defaults).
##
## **Deliberately does not have fields corresponding to `user` / `port` /
## `identityFile` / `proxyJump`.** This is a design decision to structurally
## enforce, at the schema level, a division of responsibility: connection
## routing and authentication are the responsibility of `~/.ssh/config`,
## while forwarding topology (which local port forwards to where) is the
## responsibility of powarder. If these keys do appear in the JSON, it is
## not treated as a fatal error; instead it is detected as a warning
## (`ConfigFile.forbiddenKeyWarnings`) that steers the user toward writing
## them into `~/.ssh/config`.

import std/[json, os, strutils, tables]
import powarder/core/types
import powarder/core/forwardspec
import powarder/core/paths
import powarder/ipc/protocol ## Reuses RetryPolicy's JSON conversion (retryPolicyFromJson/toJson).

type
  ConfigFile* = object
    version*: int
    tunnels*: seq[TunnelConfig]
    forbiddenKeyWarnings*: seq[string]
      ## Warning messages (prefixed with "warning: ") for cases where a
      ## deliberately unsupported field -- `user` / `port` / `identityFile` /
      ## `proxyJump`, etc. -- was written in the JSON. `TunnelConfig`
      ## (core/types.nim) has no such fields at all, so the information
      ## would otherwise be lost after parsing; it is therefore detected at
      ## the point where `loadConfig` still holds the raw JSON and stashed
      ## here. `validateConfig` includes these as-is in its result.

  ConfigError* = object of CatchableError
    ## Represents a config file syntax error or schema violation. The
    ## message always includes the file path, the offending tunnel
    ## (index/name), and the field name.

const
  forbiddenKeys = ["user", "port", "identityFile", "proxyJump"]
    ## The list of fields powarder deliberately does not support. See the
    ## module doc comment above.

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

proc tunnelLabel(idx: int; name: string): string =
  ## A string identifying a tunnel for use in error messages. Includes the
  ## name too if it could be read.
  if name.len > 0: "tunnels[" & $idx & "] (name=\"" & name & "\")"
  else: "tunnels[" & $idx & "]"

proc configErr(path, label, field, msg: string): ref ConfigError =
  newException(ConfigError,
    path & ": " & label & ": \"" & field & "\" is invalid: " & msg)

proc parseTunnelNode(path: string; idx: int; node: JsonNode): (TunnelConfig,
    seq[string]) =
  ## Parses one element of the `tunnels` array. Returns (TunnelConfig, forbidden-key warnings).
  if node.kind != JObject:
    raise newException(ConfigError,
      path & ": tunnels[" & $idx & "] must be an object")

  # name
  if not node.hasKey("name") or node["name"].kind != JString:
    raise configErr(path, "tunnels[" & $idx & "]", "name", "must be a string")
  let name = node["name"].getStr
  let label = tunnelLabel(idx, name)

  # host
  if not node.hasKey("host") or node["host"].kind != JString:
    raise configErr(path, label, "host", "must be a string")
  let host = node["host"].getStr

  # type
  if not node.hasKey("type") or node["type"].kind != JString:
    raise configErr(path, label, "type", "must be a string (\"L\" or \"R\")")
  let typeStr = node["type"].getStr
  var kind: ForwardKind
  try:
    kind = parseEnum[ForwardKind](typeStr)
  except ValueError:
    raise configErr(path, label, "type",
      "must be \"L\" or \"R\" (got: \"" &
      typeStr & "\")")

  # forward
  if not node.hasKey("forward") or node["forward"].kind != JString:
    raise configErr(path, label, "forward", "must be a string")
  let forwardStr = node["forward"].getStr
  var spec: ForwardSpec
  try:
    spec = parseForwardSpec(forwardStr, kind)
  except ValueError as e:
    raise configErr(path, label, "forward", e.msg)

  # autostart (optional, defaults to false)
  var autostart = false
  if node.hasKey("autostart"):
    if node["autostart"].kind != JBool:
      raise configErr(path, label, "autostart", "must be a boolean")
    autostart = node["autostart"].getBool

  # profile (optional, defaults to "")
  var profile = ""
  if node.hasKey("profile"):
    if node["profile"].kind != JString:
      raise configErr(path, label, "profile", "must be a string")
    profile = node["profile"].getStr

  # sshExtraArgs (optional, defaults to @[])
  var sshExtraArgs: seq[string] = @[]
  if node.hasKey("sshExtraArgs"):
    if node["sshExtraArgs"].kind != JArray:
      raise configErr(path, label, "sshExtraArgs", "must be an array of strings")
    for elemNode in node["sshExtraArgs"]:
      if elemNode.kind != JString:
        raise configErr(path, label, "sshExtraArgs", "all elements must be strings")
      sshExtraArgs.add elemNode.getStr

  # retry (optional, defaults to initRetryPolicy())
  var retry = initRetryPolicy()
  if node.hasKey("retry"):
    try:
      retry = retryPolicyFromJson(node["retry"])
    except CatchableError as e:
      raise configErr(path, label, "retry", e.msg)

  # Forbidden keys (warnings, not errors)
  var warnings: seq[string] = @[]
  for fk in forbiddenKeys:
    if node.hasKey(fk):
      warnings.add "warning: " & label & ": \"" & fk &
        "\" is not supported by powarder. Please put it in the Host " &
        host & " section of ~/.ssh/config instead"

  let cfg = TunnelConfig(name: name, host: host, spec: spec, autostart: autostart,
                          profile: profile, sshExtraArgs: sshExtraArgs, retry: retry)
  (cfg, warnings)

proc tunnelToJson(t: TunnelConfig): JsonNode =
  ## Converts a `TunnelConfig` to JSON in the user-facing schema (a flat
  ## "type"/"forward"). `ipc/protocol.toJson(TunnelConfig)` produces a
  ## nested internal representation with a "spec": {...} field (for
  ## daemon-to-daemon IPC), so it isn't used here; this is hand-written for
  ## the file format instead. Fields equal to their default value are
  ## omitted, keeping the JSON minimal so a human reading it can easily spot
  ## the differences (round-tripping is preserved because `loadConfig` uses
  ## the same defaults for omitted fields).
  result = newJObject()
  result["name"] = %t.name
  result["host"] = %t.host
  result["type"] = %t.spec.kind
  result["forward"] = %formatForwardSpec(t.spec)
  if t.autostart:
    result["autostart"] = %true
  if t.profile.len > 0:
    result["profile"] = %t.profile
  if t.sshExtraArgs.len > 0:
    result["sshExtraArgs"] = %t.sshExtraArgs
  if t.retry != initRetryPolicy():
    result["retry"] = toJson(t.retry)

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

proc loadConfig*(path: string): ConfigFile =
  ## Reads JSON and builds a `ConfigFile`. Parse errors and schema
  ## violations raise `ConfigError`. The exception message always includes
  ## the file path, the offending tunnel (index, and name if known), and
  ## the field name.
  var content: string
  try:
    content = readFile(path)
  except IOError as e:
    raise newException(ConfigError, path &
        ": failed to read the config file: " & e.msg)

  var root: JsonNode
  try:
    root = parseJson(content)
  except JsonParsingError as e:
    raise newException(ConfigError, path &
        ": failed to parse JSON: " & e.msg)

  if root.kind != JObject:
    raise newException(ConfigError, path & ": the top level must be an object")

  let version =
    if root.hasKey("version") and root["version"].kind == JInt: root[
        "version"].getInt
    else: 1

  var tunnels: seq[TunnelConfig] = @[]
  var warnings: seq[string] = @[]

  if root.hasKey("tunnels"):
    if root["tunnels"].kind != JArray:
      raise newException(ConfigError, path & ": \"tunnels\" must be an array")
    let arr = root["tunnels"]
    for idx in 0 ..< arr.len:
      let (cfg, w) = parseTunnelNode(path, idx, arr[idx])
      tunnels.add cfg
      warnings.add w

  ConfigFile(version: version, tunnels: tunnels, forbiddenKeyWarnings: warnings)

proc saveConfig*(path: string; cfg: ConfigFile) =
  ## Writes the config in a human-readable form (with indentation). Writes
  ## to a temporary file first, then atomically replaces it with
  ## `moveFile` (the temp file is created in the same directory as `path`,
  ## because crossing filesystems would make rename non-atomic).
  var root = newJObject()
  root["version"] = %cfg.version
  var arr = newJArray()
  for t in cfg.tunnels:
    arr.add tunnelToJson(t)
  root["tunnels"] = arr

  let dir = path.parentDir
  if dir.len > 0:
    createDir(dir)

  let tmpPath = path & ".tmp." & $getCurrentProcessId()
  writeFile(tmpPath, root.pretty())
  # Set permissions to 0600 before renaming (same reason as
  # `config/statefile.saveState`). The config file lists bastion hosts and
  # internal network hostnames/ports, so there's no reason for it to be
  # readable by other users. Dropping permissions **before** the rename
  # avoids a brief window where the file would be world-readable (644).
  setFilePermissions(tmpPath, {fpUserRead, fpUserWrite})
  moveFile(tmpPath, path)

proc validateConfig*(cfg: ConfigFile): seq[string] =
  ## Collects and returns every semantic problem with the config, rather
  ## than stopping at the first one found -- everything is reported
  ## together.
  ##
  ## Each element of the returned sequence is a message string, under the
  ## following contract: **anything starting with "warning: " is a
  ## warning** (it doesn't block startup or saving); everything else is a
  ## fatal problem that the caller should reject here. The following are
  ## treated as warnings:
  ## - A forbidden key (`user`/`port`/`identityFile`/`proxyJump`) was
  ##   present (`cfg.forbiddenKeyWarnings`, collected by `loadConfig`, is
  ##   included as-is)
  ## - `bindAddr` is anything other than loopback (`exposesExternally`)
  ##   (since exposing externally can be intentional, rejecting it as an
  ##   error would break legitimate use cases)
  ## Everything else (duplicate name/forwardId, empty name/host, invalid
  ## version) can never be a valid config, so it is always treated as an
  ## error.
  result = @[]

  for w in cfg.forbiddenKeyWarnings:
    result.add w

  if cfg.version != 1:
    result.add "only version 1 is supported (got: " &
        $cfg.version & ")"

  var namesSeen = initTable[string, int]()
  var forwardGroups = initTable[string, seq[string]]()

  for idx, t in cfg.tunnels:
    if t.name.strip().len == 0:
      result.add "tunnels[" & $idx & "] (host=\"" & t.host & "\"): name is empty"
    else:
      namesSeen[t.name] = namesSeen.getOrDefault(t.name, 0) + 1

    if t.host.len == 0:
      result.add "tunnels[" & $idx & "] (name=\"" & t.name & "\"): host is empty"

    if exposesExternally(t.spec):
      result.add "warning: tunnel \"" & t.name &
          "\" binds to a non-loopback address (" &
        t.spec.bindAddr & ") and will be exposed externally. Please confirm this is intentional"

    let fid = forwardId(t.spec, t.host)
    forwardGroups[fid] = forwardGroups.getOrDefault(fid, @[]) & t.name

  for name, cnt in namesSeen:
    if cnt > 1:
      result.add "tunnel name \"" & name &
          "\" is duplicated (" & $cnt & " occurrences)"

  for fid, names in forwardGroups:
    if names.len > 1:
      result.add "multiple tunnels are competing for the same forward target (" &
          fid & "): " & names.join(", ")

proc findConfigFile*(explicit = ""): string =
  ## Searches for the config file. Priority order:
  ## 1. `explicit` (path explicitly given via `--file`/`-f`)
  ## 2. `./powarder.json` (project-local; only if it exists. `paths.localConfigFile()`)
  ## 3. `~/.config/powarder/config.json` (`paths.configFile()`; can also be
  ##    overridden via `POWARDER_CONFIG`)
  ## If none of these exist, returns the path from 3 (it's fine to return a
  ## non-existent path -- the caller handles that).
  if explicit.len > 0:
    return expandTilde(explicit)

  let local = localConfigFile()
  if fileExists(local):
    return local

  configFile()

proc defaultConfig*(): ConfigFile =
  ## An empty config with `version: 1, tunnels: @[]`. The initial value used
  ## when there is no config file.
  ConfigFile(version: 1, tunnels: @[], forbiddenKeyWarnings: @[])
