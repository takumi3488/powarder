## Integration tests for `powarder/ipc/server` and `powarder/ipc/client`.
##
## The server is async (`std/asyncdispatch`) while the client is
## synchronous (`std/net`). With that combination, if you `asyncCheck
## serve(s)` and then call the synchronous `call()` within the same
## process, the event loop never gets a chance to run while `call()`'s
## `recvLine` is blocking, which deadlocks.
##
## To avoid this, following the pattern in `tests/tplatform.nim`, the
## server is started as a separate process via `posix.fork()` (this was
## preferred over the other two options -- making the server side
## synchronous `std/net` too, or running the client call on a separate
## thread -- because it lets the real `IpcServer` be tested as-is). The
## child process stays inside `serve()`'s accept loop and never returns
## until the parent sends `SIGKILL`. Using `quit()` to end the child
## process would drag in the Nim runtime's shutdown handling and
## `unittest`'s global state, causing the child process to run the whole
## test suite a second time (as noted in `tests/tplatform.nim`), so
## `posix.exitnow` (`_exit`) is used instead.

import std/[unittest, os, posix, json, options, net, nativesockets, asyncdispatch]
import powarder/ipc/protocol
import powarder/ipc/server
import powarder/ipc/client
import powarder/core/paths

# A safeguard in case default path resolution (when `path` is omitted) is
# accidentally exercised, so it doesn't touch a real powarder daemon's
# socket that might be running on the actual machine. Each test uses an
# explicit short path, so this shouldn't normally matter, but it's kept
# just in case.
putEnv(envRuntimeDir, getTempDir() / "pw-ipc-test-rt")

proc pingHandler(params: JsonNode): JsonNode =
  %*{"pong": true}

proc forkTestServer(path: string;
    setup: proc(s: IpcServer) {.closure, gcsafe.}): Pid =
  ## Starts a test server as a child process.
  ## The child process stays inside `serve()`'s accept loop and never
  ## returns, so the caller must always call `stopTestServer` to
  ## `SIGKILL` and end it.
  let pid = fork()
  if pid == 0:
    try:
      let s = newIpcServer(path)
      setup(s)
      waitFor serve(s)
    except CatchableError:
      discard
    exitnow(0)
  pid

proc waitForSocket(path: string; maxMs = 2000) =
  ## Right after `fork()`, the child process may not have finished
  ## binding yet, so wait briefly until the socket file actually shows up.
  var waited = 0
  while not socketExists(path) and waited < maxMs:
    os.sleep(10)
    waited += 10

proc stopTestServer(pid: Pid; path: string) =
  ## Terminates the server process and removes any leftover socket file.
  ## A child killed with `SIGKILL` never gets a chance to clean up its own
  ## socket file, so that cleanup is left to the test (the parent process).
  discard kill(pid, SIGKILL)
  var status: cint
  discard waitpid(pid, status, 0)
  removeFile(path)

proc newRawUnixSocket(): Socket =
  ## Importing `std/posix` in the same file makes enum values such as
  ## `AF_UNIX` ambiguous with posix's identically named `cint` constants,
  ## so the `nativesockets` side is qualified explicitly (the same
  ## workaround used in `ipc/client.nim`).
  newSocket(nativesockets.AF_UNIX, nativesockets.SOCK_STREAM,
      nativesockets.IPPROTO_IP)

# ---------------------------------------------------------------------------
# 1. A normal RPC round trip
# ---------------------------------------------------------------------------

suite "server/client: a normal RPC round trip":
  test "registering daemon.ping lets call return its result":
    const path = "/tmp/pw-t1.sock"
    removeFile(path)
    let pid = forkTestServer(path, proc(s: IpcServer) =
      s.register(mDaemonPing, pingHandler))
    waitForSocket(path)
    try:
      let res = call(mDaemonPing, path = path)
      check res == %*{"pong": true}
    finally:
      stopTestServer(pid, path)

# ---------------------------------------------------------------------------
# 2. The socket's permissions are 0600
# ---------------------------------------------------------------------------

suite "server: socket permissions":
  test "the socket newIpcServer creates is 0600":
    const path = "/tmp/pw-t2.sock"
    removeFile(path)
    # **Important**: `newIpcServer` internally creates an `AsyncSocket`. If
    # this unittest main (parent) process ever touches an `AsyncSocket`
    # even once, Nim's asyncdispatch global dispatcher (which holds a
    # kqueue fd) gets initialized inside the parent, and every child
    # process `fork()`ed afterward "inherits" that kqueue fd. The child's
    # own `accept()` then starts failing with "Bad file descriptor" (this
    # bug was confirmed empirically). So `newIpcServer` must only ever be
    # called inside this child process, and the verdict is reported back
    # to the parent via exit code rather than `unittest.check` (which only
    # rolls up into the parent's own tally).
    let pid = fork()
    if pid == 0:
      let ok =
        try:
          let s = newIpcServer(path)
          let permsOk = getFilePermissions(path) == {fpUserRead, fpUserWrite}
          s.close()
          permsOk
        except CatchableError:
          false
      exitnow(if ok: 0 else: 1)
    var status: cint
    discard waitpid(pid, status, 0)
    check WEXITSTATUS(status) == 0
    removeFile(path)

# ---------------------------------------------------------------------------
# 3. An unregistered method
# ---------------------------------------------------------------------------

suite "server/client: an unregistered method":
  test "RpcRemoteError's code becomes rpcMethodNotFound":
    const path = "/tmp/pw-t3.sock"
    removeFile(path)
    let pid = forkTestServer(path, proc(s: IpcServer) =
      s.register(mDaemonPing, pingHandler))
    waitForSocket(path)
    try:
      try:
        discard call("no.such.method", path = path)
        fail()
      except RpcRemoteError as e:
        check e.code == rpcMethodNotFound
    finally:
      stopTestServer(pid, path)

# ---------------------------------------------------------------------------
# 4. When a handler raises RpcError
# ---------------------------------------------------------------------------

suite "server/client: a handler raises RpcError":
  test "the code reaches the client's RpcRemoteError.code":
    const path = "/tmp/pw-t4.sock"
    removeFile(path)
    let pid = forkTestServer(path, proc(s: IpcServer) =
      s.register("tunnel.boom", proc(params: JsonNode): JsonNode =
        raise newRpcError(errTunnelNotFound, "tunnel not found")))
    waitForSocket(path)
    try:
      try:
        discard call("tunnel.boom", path = path)
        fail()
      except RpcRemoteError as e:
        check e.code == errTunnelNotFound
        check e.msg == "tunnel not found"
    finally:
      stopTestServer(pid, path)

# ---------------------------------------------------------------------------
# 5. The server doesn't die even if a handler raises an unexpected exception
# ---------------------------------------------------------------------------

suite "server: an unexpected exception from a handler":
  test "becomes rpcInternalError, and later requests still get processed":
    const path = "/tmp/pw-t5.sock"
    removeFile(path)
    let pid = forkTestServer(path, proc(s: IpcServer) =
      s.register(mDaemonPing, pingHandler)
      s.register("boom.unexpected", proc(params: JsonNode): JsonNode =
        raise newException(ValueError, "boom")))
    waitForSocket(path)
    try:
      try:
        discard call("boom.unexpected", path = path)
        fail()
      except RpcRemoteError as e:
        check e.code == rpcInternalError

      # Re-confirm, over a separate connection, that the server process is
      # still alive (since 1 connection = 1 command, this is a fresh
      # `call` rather than reusing the same connection).
      let res = call(mDaemonPing, path = path)
      check res == %*{"pong": true}
    finally:
      stopTestServer(pid, path)

# ---------------------------------------------------------------------------
# 6. A malformed line
# ---------------------------------------------------------------------------

suite "server: a malformed line":
  test "rpcParseError is returned":
    const path = "/tmp/pw-t6.sock"
    removeFile(path)
    let pid = forkTestServer(path, proc(s: IpcServer) =
      s.register(mDaemonPing, pingHandler))
    waitForSocket(path)
    try:
      # `client.call` always encodes valid JSON, so sending a malformed
      # line requires using a raw socket here instead.
      var raw = newRawUnixSocket()
      raw.connectUnix(path)
      raw.send("not json at all\n")
      let line = raw.recvLine()
      raw.close()
      let resp = decodeResponse(line)
      check resp.error.isSome
      check resp.error.get.code == rpcParseError
    finally:
      stopTestServer(pid, path)

# ---------------------------------------------------------------------------
# 7. When the daemon isn't running (ENOENT)
# ---------------------------------------------------------------------------

suite "client: the daemon isn't running (ENOENT)":
  test "a missing socket file raises DaemonNotRunningError":
    const path = "/tmp/pw-t7.sock"
    removeFile(path)
    try:
      discard call(mDaemonPing, path = path)
      fail()
    except DaemonNotRunningError:
      discard

# ---------------------------------------------------------------------------
# 8. When only a stale socket remains (ECONNREFUSED)
# ---------------------------------------------------------------------------

suite "client: only a stale socket remains (ECONNREFUSED)":
  test "raises DaemonNotRunningError, and the stale file is not removed":
    const path = "/tmp/pw-t8.sock"
    removeFile(path)
    # Bind but don't listen -- reproduces the remnant left behind by a
    # crashed daemon.
    var stale = newRawUnixSocket()
    stale.bindUnix(path)
    stale.close()
    check socketExists(path) # precondition: this is now a "stale socket"

    try:
      discard call(mDaemonPing, path = path)
      fail()
    except DaemonNotRunningError:
      discard

    check socketExists(path) # the client must not remove the stale file
    removeFile(path)

# ---------------------------------------------------------------------------
# 9. ping() returns a bool instead of raising
# ---------------------------------------------------------------------------

suite "client: ping":
  test "returns false when there's no daemon (raises nothing)":
    const path = "/tmp/pw-t9a.sock"
    removeFile(path)
    check ping(path = path) == false

  test "returns true when the daemon is present (raises nothing)":
    const path = "/tmp/pw-t9b.sock"
    removeFile(path)
    let pid = forkTestServer(path, proc(s: IpcServer) =
      s.register(mDaemonPing, pingHandler))
    waitForSocket(path)
    try:
      check ping(path = path) == true
    finally:
      stopTestServer(pid, path)

# ---------------------------------------------------------------------------
# 10. newIpcServer removes an existing stale socket before binding
# ---------------------------------------------------------------------------

suite "server: cleaning up a stale socket":
  test "uses socketExists to remove the stale file before binding":
    const path = "/tmp/pw-t10.sock"
    removeFile(path)
    # The side that creates the stale socket uses `std/net`'s synchronous
    # socket, so it never touches the dispatcher (no problem there).
    # `os.fileExists` only checks S_ISREG, so it returns false for a
    # socket. If `newIpcServer` were checking for a stale file with
    # `fileExists`, it would fail to remove this existing socket and then
    # fail with an `OSError` of `EADDRINUSE` when calling `bindUnix`.
    var stale = newRawUnixSocket()
    stale.bindUnix(path)
    stale.close()
    check socketExists(path)

    # `newIpcServer` itself is (for the same reason as the suite above)
    # called only inside the child process. The verdict is reported back
    # to the parent via exit code.
    let pid = fork()
    if pid == 0:
      let ok =
        try:
          let s = newIpcServer(path)
          let existedAfterBind = socketExists(path)
          let permsOk = getFilePermissions(path) == {fpUserRead, fpUserWrite}
          s.close()
          let removedAfterClose = not socketExists(path)
          existedAfterBind and permsOk and removedAfterClose
        except CatchableError:
          false
      exitnow(if ok: 0 else: 1)
    var status: cint
    discard waitpid(pid, status, 0)
    check WEXITSTATUS(status) == 0
    removeFile(path) # just in case

# ---------------------------------------------------------------------------
# Extra (not among the required 10, but it's a behavior documented in
# `call`'s doc comment, so it's covered too): timeout
# ---------------------------------------------------------------------------

suite "client: timeout":
  test "no response within timeoutMs raises IpcClientError":
    const path = "/tmp/pw-t11.sock"
    removeFile(path)
    # The handler is a synchronous proc, so `os.sleep` here stalls the
    # server's single-threaded event loop itself. This is used as an easy
    # way to reproduce a situation where no response ever comes back (a
    # real handler must never do this).
    let pid = forkTestServer(path, proc(s: IpcServer) =
      s.register("slow.method", proc(params: JsonNode): JsonNode =
        os.sleep(500)
        %*{"ok": true}))
    waitForSocket(path)
    try:
      try:
        discard call("slow.method", path = path, timeoutMs = 100)
        fail()
      except RpcRemoteError:
        fail() # reaching here would mean "the server responded quickly", which is wrong
      except IpcClientError:
        discard # expecting a timeout to become an IpcClientError
    finally:
      stopTestServer(pid, path)
