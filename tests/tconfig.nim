## Tests for `powarder/config/configfile` and `powarder/config/statefile`.

import std/[unittest, os, strutils, sequtils, nativesockets, json]
import powarder/core/types
import powarder/core/forwardspec
import powarder/config/configfile
import powarder/config/statefile

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc withEnv(pairs: openArray[(string, string)], body: proc()) =
  ## Temporarily overrides environment variables, restoring them afterward
  ## so state doesn't leak across tests.
  var saved: seq[(string, bool, string)]
  for (k, v) in pairs:
    saved.add (k, existsEnv(k), getEnv(k))
    putEnv(k, v)
  try:
    body()
  finally:
    for (k, existed, old) in saved:
      if existed: putEnv(k, old) else: delEnv(k)

const sampleJson = """
{
  "version": 1,
  "tunnels": [
    { "name": "prod-db",  "host": "prod-bastion", "type": "L",
      "forward": "15432:db.internal:5432", "autostart": true, "profile": "prod" },
    { "name": "metrics",  "host": "prod-bastion", "type": "L",
      "forward": "9090:10.0.4.12:9090",   "autostart": true, "profile": "prod" },
    { "name": "webhook",  "host": "dev-box",      "type": "R",
      "forward": "8443:localhost:3000" }
  ]
}
"""

# ===========================================================================
# configfile
# ===========================================================================

suite "configfile: loadConfig - schema example":
  test "can parse the 3 tunnels from the schema example as-is":
    let path = "/tmp/pw-tcfg-sample.json"
    writeFile(path, sampleJson)
    defer: removeFile(path)

    let cfg = loadConfig(path)
    check cfg.version == 1
    check cfg.tunnels.len == 3
    check cfg.forbiddenKeyWarnings.len == 0

    let t0 = cfg.tunnels[0]
    check t0.name == "prod-db"
    check t0.host == "prod-bastion"
    check t0.spec.kind == fkLocal
    check t0.spec.bindAddr == defaultBindAddr
    check t0.spec.bindPort == Port(15432)
    check t0.spec.targetHost == "db.internal"
    check t0.spec.targetPort == Port(5432)
    check t0.autostart == true
    check t0.profile == "prod"
    check t0.sshExtraArgs == newSeq[string]()
    check t0.retry == initRetryPolicy()

    let t1 = cfg.tunnels[1]
    check t1.name == "metrics"
    check t1.spec.bindPort == Port(9090)
    check t1.spec.targetHost == "10.0.4.12"
    check t1.spec.targetPort == Port(9090)
    check t1.autostart == true
    check t1.profile == "prod"

    let t2 = cfg.tunnels[2]
    check t2.name == "webhook"
    check t2.host == "dev-box"
    check t2.spec.kind == fkRemote
    check t2.spec.bindPort == Port(8443)
    check t2.spec.targetHost == "localhost"
    check t2.spec.targetPort == Port(3000)
    check t2.autostart == false ## default value when omitted
    check t2.profile == "" ## default value when omitted

suite "configfile: round trip":
  test "saveConfig -> loadConfig preserves the content":
    let path = "/tmp/pw-tcfg-roundtrip.json"
    removeFile(path)
    defer: removeFile(path)

    let cfg = ConfigFile(version: 1, tunnels: @[
      TunnelConfig(name: "a", host: "hostA",
        spec: parseForwardSpec("15432:db.internal:5432", fkLocal),
        autostart: true, profile: "prod", sshExtraArgs: @["-vvv", "-o",
            "Foo=bar"],
        retry: initRetryPolicy(maxConsecutiveFailures = 3,
            backoffMaxSeconds = 5.0)),
      TunnelConfig(name: "b", host: "hostB",
        spec: parseForwardSpec("9000:127.0.0.1:80", fkRemote),
        autostart: false, profile: "", sshExtraArgs: @[],
            retry: initRetryPolicy())
    ], forbiddenKeyWarnings: @[])

    saveConfig(path, cfg)
    let loaded = loadConfig(path)
    check loaded == cfg

suite "configfile: defaults for optional fields":
  test "autostart / profile / sshExtraArgs / retry get their default values":
    let path = "/tmp/pw-tcfg-defaults.json"
    writeFile(path,
      """{"version":1,"tunnels":[{"name":"x","host":"h","type":"L","forward":"1234:h:80"}]}""")
    defer: removeFile(path)

    let cfg = loadConfig(path)
    let t = cfg.tunnels[0]
    check t.autostart == false
    check t.profile == ""
    check t.sshExtraArgs == newSeq[string]()
    check t.retry == initRetryPolicy()

suite "configfile: type field conversion":
  test "\"L\" becomes fkLocal, \"R\" becomes fkRemote":
    let path = "/tmp/pw-tcfg-type.json"
    writeFile(path, """
    {"version":1,"tunnels":[
      {"name":"l","host":"h","type":"L","forward":"1:h:1"},
      {"name":"r","host":"h","type":"R","forward":"2:h:2"}
    ]}
    """)
    defer: removeFile(path)

    let cfg = loadConfig(path)
    check cfg.tunnels[0].spec.kind == fkLocal
    check cfg.tunnels[1].spec.kind == fkRemote

  test "an invalid type raises ConfigError":
    let path = "/tmp/pw-tcfg-badtype.json"
    writeFile(path,
      """{"version":1,"tunnels":[{"name":"x","host":"h","type":"X","forward":"1:h:1"}]}""")
    defer: removeFile(path)
    expect ConfigError:
      discard loadConfig(path)

suite "configfile: error cases":
  test "a forward parse error raises ConfigError and includes the tunnel name":
    let path = "/tmp/pw-tcfg-badforward.json"
    writeFile(path, """
    {"version":1,"tunnels":[{"name":"broken-fwd","host":"h","type":"L","forward":"not-a-valid-forward"}]}
    """)
    defer: removeFile(path)
    try:
      discard loadConfig(path)
      fail()
    except ConfigError as e:
      check "broken-fwd" in e.msg
      check path in e.msg

  test "broken JSON raises ConfigError":
    let path = "/tmp/pw-tcfg-brokenjson.json"
    writeFile(path, "{ this is not json")
    defer: removeFile(path)
    expect ConfigError:
      discard loadConfig(path)

suite "configfile: validateConfig":
  test "1. detects duplicate names":
    let cfg = ConfigFile(version: 1, tunnels: @[
      TunnelConfig(name: "dup", host: "h1",
        spec: parseForwardSpec("1000:a:80", fkLocal), retry: initRetryPolicy()),
      TunnelConfig(name: "dup", host: "h2",
        spec: parseForwardSpec("1001:b:80", fkLocal), retry: initRetryPolicy())
    ])
    let problems = validateConfig(cfg)
    check problems.anyIt("dup" in it and not it.startsWith("warning:"))

  test "2. detects duplicate forwardId and includes both colliding tunnel names (most important)":
    let cfg = ConfigFile(version: 1, tunnels: @[
      TunnelConfig(name: "web-a", host: "h1",
        spec: parseForwardSpec("8080:x:80", fkLocal), retry: initRetryPolicy()),
      TunnelConfig(name: "web-b", host: "h2",
        spec: parseForwardSpec("8080:y:81", fkLocal), retry: initRetryPolicy())
    ])
    let problems = validateConfig(cfg)
    let hits = problems.filterIt("web-a" in it and "web-b" in it)
    check hits.len == 1
    check not hits[0].startsWith("warning:")

  test "3. name is empty, or whitespace only":
    let cfg = ConfigFile(version: 1, tunnels: @[
      TunnelConfig(name: "", host: "h",
        spec: parseForwardSpec("1:a:1", fkLocal), retry: initRetryPolicy()),
      TunnelConfig(name: "   ", host: "h",
        spec: parseForwardSpec("2:a:2", fkLocal), retry: initRetryPolicy())
    ])
    let problems = validateConfig(cfg)
    check problems.filterIt("name is empty" in it).len == 2

  test "4. host is empty":
    let cfg = ConfigFile(version: 1, tunnels: @[
      TunnelConfig(name: "x", host: "",
        spec: parseForwardSpec("3:a:3", fkLocal), retry: initRetryPolicy())
    ])
    let problems = validateConfig(cfg)
    check problems.anyIt("host is empty" in it)

  test "5. version is other than 1":
    let cfg = ConfigFile(version: 2, tunnels: @[])
    let problems = validateConfig(cfg)
    check problems.anyIt("version" in it)

  test "6. external exposure is distinguished by the warning: prefix":
    let cfg = ConfigFile(version: 1, tunnels: @[
      TunnelConfig(name: "open", host: "h",
        spec: parseForwardSpec("0.0.0.0:8443:localhost:3000", fkLocal),
        retry: initRetryPolicy())
    ])
    let problems = validateConfig(cfg)
    let warns = problems.filterIt(it.startsWith("warning:"))
    check warns.len == 1
    check "open" in warns[0]

suite "configfile: findConfigFile":
  test "explicit takes top priority":
    check findConfigFile("/tmp/pw-tcfg-explicit.json") == "/tmp/pw-tcfg-explicit.json"

  test "uses ./powarder.json if it exists":
    let oldCwd = getCurrentDir()
    let dir = "/tmp/pw-tcfg-cwd-a"
    removeDir(dir)
    createDir(dir)
    writeFile(dir / "powarder.json", sampleJson)
    setCurrentDir(dir)
    try:
      # On macOS, /tmp is a symlink to /private/tmp, and getCurrentDir()
      # returns the resolved absolute path. Comparing directly against the
      # dir string would mismatch before/after resolution, so the expected
      # value is also built via getCurrentDir().
      let localPath = getCurrentDir() / "powarder.json"
      withEnv({"POWARDER_CONFIG": "/tmp/pw-tcfg-should-not-be-used.json"}, proc() =
        check findConfigFile() == localPath)
    finally:
      setCurrentDir(oldCwd)
      removeDir(dir)

  test "uses POWARDER_CONFIG if there's no local file":
    let oldCwd = getCurrentDir()
    let dir = "/tmp/pw-tcfg-cwd-b"
    removeDir(dir)
    createDir(dir)
    setCurrentDir(dir)
    try:
      withEnv({"POWARDER_CONFIG": "/tmp/pw-tcfg-env-config.json"}, proc() =
        check findConfigFile() == "/tmp/pw-tcfg-env-config.json")
    finally:
      setCurrentDir(oldCwd)
      removeDir(dir)

suite "configfile: forbidden key warnings":
  test "returns a warning (not an error) when user / identityFile are present":
    let path = "/tmp/pw-tcfg-forbidden.json"
    writeFile(path, """
    {"version":1,"tunnels":[
      {"name":"x","host":"h","type":"L","forward":"1234:h:80",
       "user":"root","identityFile":"~/.ssh/id_rsa"}
    ]}
    """)
    defer: removeFile(path)

    let cfg = loadConfig(path) ## also confirms it loads without erroring
    check cfg.tunnels.len == 1
    check cfg.forbiddenKeyWarnings.len == 2
    check cfg.forbiddenKeyWarnings.anyIt("user" in it and it.startsWith("warning:"))
    check cfg.forbiddenKeyWarnings.anyIt("identityFile" in it and it.startsWith("warning:"))

    let problems = validateConfig(cfg)
    check problems.anyIt("user" in it and it.startsWith("warning:"))

# ===========================================================================
# statefile
# ===========================================================================

suite "statefile: round trip":
  test "saveState -> loadState preserves every field (savedAt is overwritten with the save time)":
    let path = "/tmp/pw-tst-roundtrip.json"
    removeFile(path)
    defer: removeFile(path)

    let st = PersistedState(
      version: 1,
      savedAt: "placeholder-should-be-overwritten",
      activeProfiles: @["dev", "prod"],
      hosts: @[
        PersistedHostSession(host: "prod-bastion",
          fingerprint: "abcdef0123456789",
          ctlPath: "/tmp/pw-rt/c/abcdef01",
          logPath: "/tmp/pw-state/logs/prod-bastion.log",
          pid: 4242, argv: @["ssh", "-M", "-N", "prod-bastion"],
          state: hsConnected,
          forwardIds: @["L:127.0.0.1:15432", "L:127.0.0.1:9090"])
      ],
      forwards: @[
        PersistedForward(id: "L:127.0.0.1:15432", tunnelName: "prod-db",
          spec: parseForwardSpec("15432:db.internal:5432", fkLocal),
          state: fwActive, udsPath: "/tmp/pw-rt/f/deadbeef"),
        PersistedForward(id: "R:dev-box:0.0.0.0:8443", tunnelName: "webhook",
          spec: parseForwardSpec("8443:localhost:3000", fkRemote),
          state: fwPending, udsPath: "")
      ]
    )

    saveState(path, st)
    let loaded = loadState(path)

    check loaded.version == st.version
    check loaded.hosts == st.hosts
    check loaded.forwards == st.forwards
    check loaded.activeProfiles == st.activeProfiles ## non-empty set, order preserved
    check loaded.savedAt.len > 0
    check loaded.savedAt != "placeholder-should-be-overwritten"

  test "emptyState() starts with an empty activeProfiles":
    let st = emptyState()
    check st.activeProfiles.len == 0
    check st.activeProfiles == newSeq[string]()

suite "statefile: corruption resilience":
  test "reading broken JSON doesn't raise and returns an empty state":
    let path = "/tmp/pw-tst-broken.json"
    writeFile(path, "{ broken")
    defer: removeFile(path)
    let st = loadState(path)
    check st == emptyState()

  test "also returns an empty state when the file doesn't exist":
    let path = "/tmp/pw-tst-missing.json"
    removeFile(path)
    let st = loadState(path)
    check st == emptyState()

  test "a legacy state file without the activeProfiles key keeps its hosts / forwards":
    # Guard: this is the exact on-disk shape written by powarder binaries
    # predating `activeProfiles` (version/savedAt/hosts/forwards, no
    # activeProfiles key). The literal is kept verbatim -- not generated by
    # mutating a PersistedState -- so it keeps documenting the old schema
    # even after future refactors of this module.
    #
    # Without the backfill in loadState, `std/json`'s `to()` raises
    # `KeyError` on the missing field, the `except CatchableError` branch
    # swallows it and returns `emptyState()`, and `adoptOrphans`
    # (daemon/orphan.nim) then loses every orphan ControlMaster on the very
    # first startup after an upgrade. This test pins the behavior that the
    # backfill exists for: a valid old file must load with its records
    # intact and an empty profile set, not as an empty state.
    let path = "/tmp/pw-tst-legacy.json"
    writeFile(path, """
    {
      "version": 1,
      "savedAt": "2026-07-29T13:45:12+09:00",
      "hosts": [
        {
          "host": "prod-bastion",
          "fingerprint": "abcdef0123456789",
          "ctlPath": "/tmp/pw-rt/c/abcdef01",
          "logPath": "/tmp/pw-state/logs/prod-bastion.log",
          "pid": 4242,
          "argv": ["ssh", "-M", "-N", "prod-bastion"],
          "state": "hsConnected",
          "forwardIds": ["L:127.0.0.1:15432"]
        }
      ],
      "forwards": [
        {
          "id": "L:127.0.0.1:15432",
          "tunnelName": "prod-db",
          "spec": {
            "kind": "L",
            "bindAddr": "127.0.0.1",
            "bindPort": 15432,
            "targetHost": "db.internal",
            "targetPort": 5432
          },
          "state": "fwActive",
          "udsPath": "/tmp/pw-rt/f/deadbeef"
        }
      ]
    }
    """)
    defer: removeFile(path)

    let st = loadState(path)
    check st != emptyState() ## the whole record was read, not discarded
    check st.version == 1
    check st.savedAt == "2026-07-29T13:45:12+09:00"
    check st.activeProfiles == newSeq[string]()
    check st.hosts == @[
      PersistedHostSession(host: "prod-bastion",
        fingerprint: "abcdef0123456789",
        ctlPath: "/tmp/pw-rt/c/abcdef01",
        logPath: "/tmp/pw-state/logs/prod-bastion.log",
        pid: 4242, argv: @["ssh", "-M", "-N", "prod-bastion"],
        state: hsConnected,
        forwardIds: @["L:127.0.0.1:15432"])
    ]
    check st.forwards == @[
      PersistedForward(id: "L:127.0.0.1:15432", tunnelName: "prod-db",
        spec: parseForwardSpec("15432:db.internal:5432", fkLocal),
        state: fwActive, udsPath: "/tmp/pw-rt/f/deadbeef")
    ]

  test "valid JSON that is not an object yields an empty state (array / string / null / number)":
    # The legacy-file backfill in loadState only runs for JObject roots
    # (`if node.kind == JObject and not node.hasKey("activeProfiles")`).
    # For any other valid root, `node.to(PersistedState)` must fail on its
    # own: the object unmarshaller's `getOrDefault` returns nil for a
    # non-object and `verifyJsonKind(nil, ...)` raises `KeyError`, which
    # the `except CatchableError` branch absorbs. Pins both halves of that
    # contract -- the backfill guard must skip non-object nodes (indexing
    # one would raise) and loadState must never propagate an exception.
    for (name, body) in [
      ("array",  "[1, 2, 3]"),
      ("string", "\"just a string\""),
      ("null",   "null"),
      ("number", "42")
    ]:
      let path = "/tmp/pw-tst-root-" & name & ".json"
      writeFile(path, body)
      defer: removeFile(path)
      let st = loadState(path)
      checkpoint("root kind: " & name)
      check st == emptyState()

  test "activeProfiles with the wrong JSON type yields an empty state, never raises":
    # The rest of the document is schema-valid; only `activeProfiles` has
    # the wrong kind. std/json's `to()` unmarshals `seq[string]` via
    # `verifyJsonKind(..., {JArray})` and then per element
    # `verifyJsonKind(..., {JString, JNull})`, so a bare string or an
    # array of numbers fails the conversion, and the `except CatchableError`
    # branch discards the whole document as a schema mismatch -- the same
    # contract as broken JSON: loadState never propagates an exception.
    for (name, profsJson) in [
      ("string", "\"dev\""),
      ("ints",   "[1, 2]")
    ]:
      let path = "/tmp/pw-tst-wrongtype-" & name & ".json"
      writeFile(path, """
      {
        "version": 1,
        "savedAt": "2026-07-29T13:45:12+09:00",
        "activeProfiles": """ & profsJson & """,
        "hosts": [],
        "forwards": []
      }
      """)
      defer: removeFile(path)
      let st = loadState(path)
      checkpoint("activeProfiles kind: " & name)
      check st == emptyState()

  test "an explicitly empty activeProfiles array round-trips as empty (not as missing)":
    # Distinct from the legacy shape above: here the key is present with
    # `[]`, which is a legitimate value that must unmarshal cleanly. The
    # record survives with an empty profile set -- neither the whole state
    # discarded as corruption nor the key conflated with the missing-key
    # backfill.
    let path = "/tmp/pw-tst-emptyprofs.json"
    removeFile(path)
    defer: removeFile(path)

    let st = PersistedState(
      version: 1,
      savedAt: "placeholder-should-be-overwritten",
      activeProfiles: @[],
      hosts: @[
        PersistedHostSession(host: "prod-bastion",
          fingerprint: "abcdef0123456789",
          ctlPath: "/tmp/pw-rt/c/abcdef01",
          logPath: "/tmp/pw-state/logs/prod-bastion.log",
          pid: 4242, argv: @["ssh", "-M", "-N", "prod-bastion"],
          state: hsConnected,
          forwardIds: @["L:127.0.0.1:15432"])
      ],
      forwards: @[
        PersistedForward(id: "L:127.0.0.1:15432", tunnelName: "prod-db",
          spec: parseForwardSpec("15432:db.internal:5432", fkLocal),
          state: fwActive, udsPath: "/tmp/pw-rt/f/deadbeef")
      ]
    )
    saveState(path, st)

    # saveState must write the key: an empty seq serialises as `[]`, not as
    # an omitted key, so the on-disk file is distinguishable from the
    # legacy shape.
    let raw = parseJson(readFile(path))
    check raw.hasKey("activeProfiles")
    check raw["activeProfiles"].kind == JArray
    check raw["activeProfiles"].len == 0

    let loaded = loadState(path)
    check loaded.activeProfiles == newSeq[string]()
    check loaded.hosts == st.hosts
    check loaded.forwards == st.forwards
    check loaded != emptyState() ## the record survived; only the profile set is empty

suite "statefile: atomic writes":
  test "no temp file remains after saveState":
    let dir = "/tmp/pw-tst-atomic"
    removeDir(dir)
    createDir(dir)
    defer: removeDir(dir)

    let path = dir / "state.json"
    saveState(path, emptyState())
    check fileExists(path)

    var leftover: seq[string] = @[]
    for f in walkFiles(dir / "*.tmp*"):
      leftover.add f
    check leftover.len == 0
