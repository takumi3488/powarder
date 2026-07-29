## `powarder/daemon/muxclient` のテスト。
##
## 実 SSH サーバなしにテストするため、`tests/fixtures/ssh` という fake ssh を
## `PATH` の先頭に置いて powarder に `ssh` として掴ませる。fake ssh の挙動は
## `POWARDER_FAKE_SSH_MODE` で切り替える（詳細は `tests/fixtures/ssh` 参照）。

import std/[unittest, os, strutils]
import powarder/core/types
import powarder/core/muxparse
import powarder/core/sshgparse
import powarder/core/forwardspec
import powarder/daemon/muxclient

const fixturesDir = currentSourcePath().parentDir() / "fixtures"
const testRuntimeDir = "/tmp/pw-muxclient-rt"
const testLogFile = "/tmp/pw-muxclient-log"

const ctlPath = testRuntimeDir / "ctl.sock"
const host = "example-host"

proc withMode(mode: string; body: proc()) =
  ## `POWARDER_FAKE_SSH_MODE` を一時的に切り替えてテスト本体を実行する。
  let had = existsEnv("POWARDER_FAKE_SSH_MODE")
  let old = getEnv("POWARDER_FAKE_SSH_MODE")
  putEnv("POWARDER_FAKE_SSH_MODE", mode)
  try:
    body()
  finally:
    if had: putEnv("POWARDER_FAKE_SSH_MODE", old)
    else: delEnv("POWARDER_FAKE_SSH_MODE")

proc withLog(body: proc()) =
  ## `POWARDER_FAKE_SSH_LOG` を一時的に有効にしてテスト本体を実行する。
  ## 終了時にログファイルと環境変数を必ず後片付けする。
  removeFile(testLogFile)
  putEnv("POWARDER_FAKE_SSH_LOG", testLogFile)
  try:
    body()
  finally:
    delEnv("POWARDER_FAKE_SSH_LOG")
    removeFile(testLogFile)

proc setupSuite() =
  ## PATH の先頭に fake ssh を置き、一時ディレクトリを隔離する。
  removeDir(testRuntimeDir)
  createDir(testRuntimeDir)
  putEnv("POWARDER_RUNTIME_DIR", testRuntimeDir)
  let curPath = getEnv("PATH")
  if not curPath.startsWith(fixturesDir & ":"):
    putEnv("PATH", fixturesDir & ":" & curPath)
  delEnv("POWARDER_FAKE_SSH_MODE")
  delEnv("POWARDER_FAKE_SSH_LOG")

setupSuite()

# ---------------------------------------------------------------------------
# 1. masterCommandLine
# ---------------------------------------------------------------------------

suite "masterCommandLine":
  test "必須オプションを全部含み ExitOnForwardFailure は含まない":
    let logPath = testRuntimeDir / "master.log"
    let cmd = masterCommandLine(ctlPath, logPath, host)
    check cmd.len == 3
    check cmd[0] == "/bin/sh"
    check cmd[1] == "-c"

    let inner = cmd[2]
    check inner.startsWith("exec ")
    check ">>" in inner
    check logPath in inner

    for token in ["-M", "-S", "-N", "-v",
                  "BatchMode=yes", "ControlPersist=no",
                  "ServerAliveInterval=15", "ServerAliveCountMax=3",
                  "ConnectTimeout=10",
                  "StreamLocalBindMask=0177", "StreamLocalBindUnlink=yes",
                  ctlPath, host]:
      check token in inner

    check not ("ExitOnForwardFailure" in inner)

  test "extraArgs がホスト名の後ろに追加される":
    let logPath = testRuntimeDir / "master.log"
    let cmd = masterCommandLine(ctlPath, logPath, host, ["-p", "2222"])
    let inner = cmd[2]
    check inner.find(host) < inner.find("-p")
    check "2222" in inner

# ---------------------------------------------------------------------------
# 2, 3. checkMaster
# ---------------------------------------------------------------------------

suite "checkMaster":
  test "ok モードで alive:true, pid が数値":
    withMode("ok", proc() =
      let r = checkMaster(ctlPath, host)
      check r.alive
      check r.pid > 0)

  test "no-master モードで alive:false, pid:0":
    withMode("no-master", proc() =
      let r = checkMaster(ctlPath, host)
      check not r.alive
      check r.pid == 0)

# ---------------------------------------------------------------------------
# 4. addForward
# ---------------------------------------------------------------------------

suite "addForward":
  let spec = ForwardSpec(kind: fkLocal, bindAddr: defaultBindAddr,
                          bindPort: Port(15432), targetHost: "db.internal",
                          targetPort: Port(5432))

  test "ok モードで moSuccess":
    withMode("ok", proc() =
      check addForward(ctlPath, host, spec) == moSuccess)

  test "bind-failed モードで moBindFailed":
    withMode("bind-failed", proc() =
      check addForward(ctlPath, host, spec) == moBindFailed)

# ---------------------------------------------------------------------------
# 5. cancelForward — cancel の exit code は信用できないことの検証
# ---------------------------------------------------------------------------

suite "cancelForward":
  let spec = ForwardSpec(kind: fkLocal, bindAddr: defaultBindAddr,
                          bindPort: Port(15432), targetHost: "db.internal",
                          targetPort: Port(5432))

  test "ok モードで moSuccess":
    withMode("ok", proc() =
      check cancelForward(ctlPath, host, spec) == moSuccess)

  test "not-forwarded: fake ssh の exit code は 0 だが moNotForwarded と判定される":
    withMode("not-forwarded", proc() =
      # cancel の判定は exit code を信用せず stderr の文言だけで行う設計
      # (core/muxparse.parseCancelResult) を、runSsh の生の結果と突き合わせて
      # 明示的に確認する。
      let raw = runSsh(["-S", ctlPath, "-O", "cancel", "-L",
                        toSshForwardArg(spec), host])
      check raw.exitCode == 0 ## ★ exit code だけ見れば成功に見えてしまう
      check cancelForward(ctlPath, host, spec) == moNotForwarded)

# ---------------------------------------------------------------------------
# 6. resolveSshConfig — stdout のみをパースすること
# ---------------------------------------------------------------------------

suite "resolveSshConfig":
  test "-G の stdout をパースできる":
    withMode("ok", proc() =
      let cfg = resolveSshConfig(host)
      check cfg.getFirst("host") == host
      check cfg.getFirst("port") == "22")

  test "fake ssh が stderr に余計な出力をしても stdout だけがパースされる":
    withMode("ok", proc() =
      # tests/fixtures/ssh は -G モードで常に stderr へ
      # "Pseudo-terminal will not be allocated ..." を出す。
      # それでも誤って key として拾われていないことを確認する。
      let cfg = resolveSshConfig(host)
      check not cfg.has("pseudo-terminal")
      check cfg.getFirst("host") == host)

# ---------------------------------------------------------------------------
# 7. 引数の記録（POWARDER_FAKE_SSH_LOG）
# ---------------------------------------------------------------------------

suite "引数の記録":
  test "addForward が -L <uds>:<target>:<port> の形で引数を組んでいる":
    withLog(proc() =
      withMode("ok", proc() =
        let spec = ForwardSpec(kind: fkLocal, bindAddr: defaultBindAddr,
                                bindPort: Port(15432),
                                    targetHost: "db.internal",
                                targetPort: Port(5432))
        discard addForward(ctlPath, host, spec, udsPath = "/tmp/pw-fwd.sock"))

      let fields = readFile(testLogFile).strip().split("\x1F")
      check "-L" in fields
      check "/tmp/pw-fwd.sock:db.internal:5432" in fields
      check ctlPath in fields
      check host in fields)

# ---------------------------------------------------------------------------
# 8. quoteShell によるエスケープ
# ---------------------------------------------------------------------------

suite "quoteShell によるエスケープ":
  test "空白を含むホスト名でも checkMaster が壊れない":
    withMode("ok", proc() =
      let r = checkMaster(ctlPath, "my host with spaces")
      check r.alive)

  test "空白を含むホスト名・UDSパス・転送先が addForward で1引数として保持される":
    withLog(proc() =
      let weirdHost = "my host"
      let weirdUds = "/tmp/pw dir/uds sock"
      let spec = ForwardSpec(kind: fkLocal, bindAddr: defaultBindAddr,
                              bindPort: Port(1), targetHost: "db host",
                              targetPort: Port(2))
      withMode("ok", proc() =
        check addForward(ctlPath, weirdHost, spec, udsPath = weirdUds) == moSuccess)

      let fields = readFile(testLogFile).strip().split("\x1F")
      check weirdHost in fields ## 空白込みでも1つの引数として届いている
      check (weirdUds & ":db host:2") in fields)

# ---------------------------------------------------------------------------
# 後片付け
# ---------------------------------------------------------------------------

removeDir(testRuntimeDir)
removeFile(testLogFile)
delEnv("POWARDER_FAKE_SSH_MODE")
delEnv("POWARDER_FAKE_SSH_LOG")
delEnv("POWARDER_RUNTIME_DIR")
