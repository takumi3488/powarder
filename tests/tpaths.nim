import std/[unittest, os, strutils, net, nativesockets]
import powarder/core/paths

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

suite "paths: 環境変数のオーバーライド":

  test "POWARDER_CONFIG が configFile を上書きする":
    withEnv({envConfig: "/tmp/pw-test/custom.json"}, proc() =
      check configFile() == "/tmp/pw-test/custom.json")

  test "XDG_CONFIG_HOME が configDir に反映される":
    withEnv({"XDG_CONFIG_HOME": "/tmp/pw-xdg-config", envConfig: ""}, proc() =
      delEnv(envConfig)
      check configDir() == "/tmp/pw-xdg-config/powarder"
      check configFile() == "/tmp/pw-xdg-config/powarder/config.json")

  test "XDG_STATE_HOME が stateDir に反映される":
    withEnv({"XDG_STATE_HOME": "/tmp/pw-xdg-state", envStateDir: ""}, proc() =
      delEnv(envStateDir)
      check stateDir() == "/tmp/pw-xdg-state/powarder"
      check stateFile() == "/tmp/pw-xdg-state/powarder/state.json"
      check logsDir() == "/tmp/pw-xdg-state/powarder/logs"
      check tunnelLogPath("prod-db") == "/tmp/pw-xdg-state/powarder/logs/prod-db.log")

  test "POWARDER_RUNTIME_DIR が runtimeDir を上書きする":
    withEnv({envRuntimeDir: "/tmp/pw-rt"}, proc() =
      check runtimeDir() == "/tmp/pw-rt"
      check ipcSocketPath() == "/tmp/pw-rt/powarder.sock"
      check lockPath() == "/tmp/pw-rt/powarder.lock")

suite "paths: UDS パスの構成":

  test "controlPath は fingerprint の先頭 8 文字だけを使う":
    withEnv({envRuntimeDir: "/tmp/pw-rt"}, proc() =
      check controlPath("0123456789abcdef") == "/tmp/pw-rt/c/01234567"
      # 8 文字未満でも切り出しで落ちないこと
      check controlPath("abc") == "/tmp/pw-rt/c/abc")

  test "forwardSocketPath は f/ 配下に置かれる":
    withEnv({envRuntimeDir: "/tmp/pw-rt"}, proc() =
      check forwardSocketPath("deadbeef") == "/tmp/pw-rt/f/deadbeef")

  test "実環境の runtimeDir で最長 UDS パスが sun_path に収まる":
    # ここが破れると ssh の -L <uds> が使えなくなり設計が成立しない
    let longest = runtimeDir() / "f" / repeat('0', 8)
    check longest.len < maxSunPath

suite "paths: ディレクトリ作成と長さ検証":

  test "ensureRuntimeDir が c/ と f/ を 0700 で作る":
    let base = getTempDir() / "pw-ensure-test"
    removeDir(base)
    withEnv({envRuntimeDir: base}, proc() =
      ensureRuntimeDir()
      check dirExists(base)
      check dirExists(base / "c")
      check dirExists(base / "f")
      for d in [base, base / "c", base / "f"]:
        check getFilePermissions(d) == {fpUserRead, fpUserWrite, fpUserExec})
    removeDir(base)

  test "sun_path に収まらないランタイムディレクトリは IOError で明示的に失敗する":
    # 104 バイトを確実に超える深いパス
    let tooLong = "/tmp/" & repeat("verylongsegment/", 8) & "powarder"
    withEnv({envRuntimeDir: tooLong}, proc() =
      check runtimeDir() == tooLong
      expect IOError:
        ensureRuntimeDir())

  test "ensureStateDirs が state と logs を 0700 で作る":
    let base = getTempDir() / "pw-state-test"
    removeDir(base)
    withEnv({envStateDir: base}, proc() =
      ensureStateDirs()
      check dirExists(base)
      check dirExists(base / "logs")
      check getFilePermissions(base) == {fpUserRead, fpUserWrite, fpUserExec})
    removeDir(base)

suite "paths: socketExists":

  test "socketExists は実ソケットにだけ true を返す":
    # os.fileExists は S_ISREG しか見ないのでソケットには常に false を返す。
    # ControlPath の readiness 判定でこれを踏むと延々待ち続けるバグになるため、
    # 両者の違いをテストで固定しておく。
    # パスは短く保つ（sockaddr_un.sun_path の制限）
    const sockPath = "/tmp/pw-se.sock"
    const filePath = "/tmp/pw-se.file"
    removeFile(sockPath)
    removeFile(filePath)

    check not socketExists(sockPath) ## 存在しない

    writeFile(filePath, "x")
    check not socketExists(filePath) ## 通常ファイルは false
    check fileExists(filePath) ## 一方 fileExists は true

    check not socketExists(getTempDir()) ## ディレクトリは false

    var s = newSocket(AF_UNIX, SOCK_STREAM, IPPROTO_IP)
    s.bindUnix(sockPath)
    s.listen()
    check socketExists(sockPath) ## 実ソケットは true
    check not fileExists(sockPath) ## ★ fileExists はソケットを見落とす
    s.close()

    removeFile(sockPath)
    removeFile(filePath)
