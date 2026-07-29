## `powarder/config/configfile` と `powarder/config/statefile` のテスト。

import std/[unittest, os, strutils, sequtils, nativesockets]
import powarder/core/types
import powarder/core/forwardspec
import powarder/config/configfile
import powarder/config/statefile

# ---------------------------------------------------------------------------
# ヘルパー
# ---------------------------------------------------------------------------

proc withEnv(pairs: openArray[(string, string)], body: proc()) =
  ## 環境変数を一時的に差し替える。テスト間で状態が漏れないようにする。
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

suite "configfile: loadConfig - スキーマ例":
  test "スキーマ例の3トンネルをそのままパースできる":
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
    check t2.autostart == false ## 省略時の既定値
    check t2.profile == "" ## 省略時の既定値

suite "configfile: 往復変換":
  test "saveConfig -> loadConfig で内容が保たれる":
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

suite "configfile: 省略可能フィールドの既定値":
  test "autostart / profile / sshExtraArgs / retry が既定値になる":
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

suite "configfile: type フィールドの変換":
  test "\"L\" は fkLocal、\"R\" は fkRemote になる":
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

  test "不正な type は ConfigError":
    let path = "/tmp/pw-tcfg-badtype.json"
    writeFile(path,
      """{"version":1,"tunnels":[{"name":"x","host":"h","type":"X","forward":"1:h:1"}]}""")
    defer: removeFile(path)
    expect ConfigError:
      discard loadConfig(path)

suite "configfile: 異常系":
  test "forward のパースエラーは ConfigError になりトンネル名を含む":
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

  test "壊れた JSON は ConfigError になる":
    let path = "/tmp/pw-tcfg-brokenjson.json"
    writeFile(path, "{ this is not json")
    defer: removeFile(path)
    expect ConfigError:
      discard loadConfig(path)

suite "configfile: validateConfig":
  test "1. name の重複を検出する":
    let cfg = ConfigFile(version: 1, tunnels: @[
      TunnelConfig(name: "dup", host: "h1",
        spec: parseForwardSpec("1000:a:80", fkLocal), retry: initRetryPolicy()),
      TunnelConfig(name: "dup", host: "h2",
        spec: parseForwardSpec("1001:b:80", fkLocal), retry: initRetryPolicy())
    ])
    let problems = validateConfig(cfg)
    check problems.anyIt("dup" in it and not it.startsWith("warning:"))

  test "2. forwardId の重複を検出し、衝突する両方のトンネル名を含む（最重要）":
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

  test "3. name が空、または空白のみ":
    let cfg = ConfigFile(version: 1, tunnels: @[
      TunnelConfig(name: "", host: "h",
        spec: parseForwardSpec("1:a:1", fkLocal), retry: initRetryPolicy()),
      TunnelConfig(name: "   ", host: "h",
        spec: parseForwardSpec("2:a:2", fkLocal), retry: initRetryPolicy())
    ])
    let problems = validateConfig(cfg)
    check problems.filterIt("name が空です" in it).len == 2

  test "4. host が空":
    let cfg = ConfigFile(version: 1, tunnels: @[
      TunnelConfig(name: "x", host: "",
        spec: parseForwardSpec("3:a:3", fkLocal), retry: initRetryPolicy())
    ])
    let problems = validateConfig(cfg)
    check problems.anyIt("host が空です" in it)

  test "5. version が1以外":
    let cfg = ConfigFile(version: 2, tunnels: @[])
    let problems = validateConfig(cfg)
    check problems.anyIt("version" in it)

  test "6. 外部公開は warning: 接頭辞で区別される":
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
  test "explicit が最優先される":
    check findConfigFile("/tmp/pw-tcfg-explicit.json") == "/tmp/pw-tcfg-explicit.json"

  test "./powarder.json が存在すればそれを使う":
    let oldCwd = getCurrentDir()
    let dir = "/tmp/pw-tcfg-cwd-a"
    removeDir(dir)
    createDir(dir)
    writeFile(dir / "powarder.json", sampleJson)
    setCurrentDir(dir)
    try:
      # macOS では /tmp が /private/tmp のシンボリックリンクで、getCurrentDir() は
      # 解決済みの絶対パスを返す。dir 文字列とそのまま比較すると解決前後で
      # 食い違うため、期待値も getCurrentDir() 経由で組み立てる。
      let localPath = getCurrentDir() / "powarder.json"
      withEnv({"POWARDER_CONFIG": "/tmp/pw-tcfg-should-not-be-used.json"}, proc() =
        check findConfigFile() == localPath)
    finally:
      setCurrentDir(oldCwd)
      removeDir(dir)

  test "ローカルファイルが無ければ POWARDER_CONFIG が使われる":
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

suite "configfile: 禁止キーの警告":
  test "user / identityFile が書かれていれば警告が返る（エラーにはしない）":
    let path = "/tmp/pw-tcfg-forbidden.json"
    writeFile(path, """
    {"version":1,"tunnels":[
      {"name":"x","host":"h","type":"L","forward":"1234:h:80",
       "user":"root","identityFile":"~/.ssh/id_rsa"}
    ]}
    """)
    defer: removeFile(path)

    let cfg = loadConfig(path) ## エラーにならず読み込めること自体も確認
    check cfg.tunnels.len == 1
    check cfg.forbiddenKeyWarnings.len == 2
    check cfg.forbiddenKeyWarnings.anyIt("user" in it and it.startsWith("warning:"))
    check cfg.forbiddenKeyWarnings.anyIt("identityFile" in it and it.startsWith("warning:"))

    let problems = validateConfig(cfg)
    check problems.anyIt("user" in it and it.startsWith("warning:"))

# ===========================================================================
# statefile
# ===========================================================================

suite "statefile: 往復変換":
  test "saveState -> loadState で全フィールドが保たれる（savedAt は保存時刻に上書きされる）":
    let path = "/tmp/pw-tst-roundtrip.json"
    removeFile(path)
    defer: removeFile(path)

    let st = PersistedState(
      version: 1,
      savedAt: "placeholder-should-be-overwritten",
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
    check loaded.savedAt.len > 0
    check loaded.savedAt != "placeholder-should-be-overwritten"

suite "statefile: 破損耐性":
  test "破損した JSON を読んでも例外を投げず空の state を返す":
    let path = "/tmp/pw-tst-broken.json"
    writeFile(path, "{ broken")
    defer: removeFile(path)
    let st = loadState(path)
    check st == emptyState()

  test "ファイルが存在しない場合も空の state を返す":
    let path = "/tmp/pw-tst-missing.json"
    removeFile(path)
    let st = loadState(path)
    check st == emptyState()

suite "statefile: アトミック書き込み":
  test "saveState 後に一時ファイルが残っていない":
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
