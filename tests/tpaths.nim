import std/[unittest, os, strutils, net, nativesockets]
import powarder/core/paths

proc withEnv(pairs: openArray[(string, string)], body: proc()) =
  ## Temporarily overrides environment variables, so state doesn't leak
  ## between tests.
  var saved: seq[(string, bool, string)]
  for (k, v) in pairs:
    saved.add (k, existsEnv(k), getEnv(k))
    putEnv(k, v)
  try:
    body()
  finally:
    for (k, existed, old) in saved:
      if existed: putEnv(k, old) else: delEnv(k)

suite "paths: environment variable overrides":

  test "POWARDER_CONFIG overrides configFile":
    withEnv({envConfig: "/tmp/pw-test/custom.json"}, proc() =
      check configFile() == "/tmp/pw-test/custom.json")

  test "XDG_CONFIG_HOME is reflected in configDir":
    withEnv({"XDG_CONFIG_HOME": "/tmp/pw-xdg-config", envConfig: ""}, proc() =
      delEnv(envConfig)
      check configDir() == "/tmp/pw-xdg-config/powarder"
      check configFile() == "/tmp/pw-xdg-config/powarder/config.json")

  test "XDG_STATE_HOME is reflected in stateDir":
    withEnv({"XDG_STATE_HOME": "/tmp/pw-xdg-state", envStateDir: ""}, proc() =
      delEnv(envStateDir)
      check stateDir() == "/tmp/pw-xdg-state/powarder"
      check stateFile() == "/tmp/pw-xdg-state/powarder/state.json"
      check logsDir() == "/tmp/pw-xdg-state/powarder/logs"
      check tunnelLogPath("prod-db") == "/tmp/pw-xdg-state/powarder/logs/prod-db.log")

  test "POWARDER_RUNTIME_DIR overrides runtimeDir":
    withEnv({envRuntimeDir: "/tmp/pw-rt"}, proc() =
      check runtimeDir() == "/tmp/pw-rt"
      check ipcSocketPath() == "/tmp/pw-rt/powarder.sock"
      check lockPath() == "/tmp/pw-rt/powarder.lock")

suite "paths: UDS path construction":

  test "controlPath uses only the first 8 characters of the fingerprint":
    withEnv({envRuntimeDir: "/tmp/pw-rt"}, proc() =
      check controlPath("0123456789abcdef") == "/tmp/pw-rt/c/01234567"
      # must not break when slicing a string shorter than 8 characters
      check controlPath("abc") == "/tmp/pw-rt/c/abc")

  test "forwardSocketPath is placed under f/":
    withEnv({envRuntimeDir: "/tmp/pw-rt"}, proc() =
      check forwardSocketPath("deadbeef") == "/tmp/pw-rt/f/deadbeef")

  test "the longest UDS path under the real runtimeDir fits within sun_path":
    # If this breaks, ssh's -L <uds> becomes unusable and the whole design falls apart
    let longest = runtimeDir() / "f" / repeat('0', 8)
    check longest.len < maxSunPath

suite "paths: directory creation and length validation":

  test "ensureRuntimeDir creates c/ and f/ with mode 0700":
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

  test "a runtime directory that doesn't fit within sun_path fails explicitly with IOError":
    # a deep path guaranteed to exceed 104 bytes
    let tooLong = "/tmp/" & repeat("verylongsegment/", 8) & "powarder"
    withEnv({envRuntimeDir: tooLong}, proc() =
      check runtimeDir() == tooLong
      expect IOError:
        ensureRuntimeDir())

  test "ensureStateDirs creates state and logs with mode 0700":
    let base = getTempDir() / "pw-state-test"
    removeDir(base)
    withEnv({envStateDir: base}, proc() =
      ensureStateDirs()
      check dirExists(base)
      check dirExists(base / "logs")
      check getFilePermissions(base) == {fpUserRead, fpUserWrite, fpUserExec})
    removeDir(base)

suite "paths: socketExists":

  test "socketExists returns true only for an actual socket":
    # os.fileExists only looks at S_ISREG, so it always returns false for a
    # socket. Getting this wrong in the ControlPath readiness check produces
    # the bug of waiting forever, so this test pins down the difference
    # between the two.
    # Keep the path short (sockaddr_un.sun_path's length limit).
    const sockPath = "/tmp/pw-se.sock"
    const filePath = "/tmp/pw-se.file"
    removeFile(sockPath)
    removeFile(filePath)

    check not socketExists(sockPath) ## doesn't exist

    writeFile(filePath, "x")
    check not socketExists(filePath) ## a regular file is false
    check fileExists(filePath) ## while fileExists is true

    check not socketExists(getTempDir()) ## a directory is false

    var s = newSocket(AF_UNIX, SOCK_STREAM, IPPROTO_IP)
    s.bindUnix(sockPath)
    s.listen()
    check socketExists(sockPath) ## an actual socket is true
    check not fileExists(sockPath) ## IMPORTANT: fileExists misses sockets
    s.close()

    removeFile(sockPath)
    removeFile(filePath)
