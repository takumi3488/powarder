## Tests for `powarder/ipc/protocol`.

import std/unittest
import std/json
import std/options
import std/nativesockets ## Needed to use `Port`'s `==`
import powarder/core/types
import powarder/ipc/protocol

suite "encode* never contains a newline":
  test "encodeRequest":
    let line = encodeRequest(1, mTunnelList, %*{"a": 1})
    check '\n' notin line
    check '\r' notin line

  test "encodeNotification":
    let line = encodeNotification(mTunnelUp, %*{"name": "web"})
    check '\n' notin line

  test "encodeSuccess":
    let line = encodeSuccess(1, %*{"ok": true})
    check '\n' notin line

  test "encodeError":
    let line = encodeError(1, errTunnelNotFound, "not found", %*{"name": "web"})
    check '\n' notin line

  test "no newline even when params/result/data are nil":
    check '\n' notin encodeRequest(1, mDaemonPing)
    check '\n' notin encodeNotification(mDaemonPing)
    check '\n' notin encodeSuccess(1, nil)
    check '\n' notin encodeError(1, rpcInternalError, "boom")

suite "request round-trip":
  test "with id and params":
    let line = encodeRequest(42, mTunnelUp, %*{"name": "web"})
    let req = decodeRequest(line)
    check req.id == some(42)
    check req.methodName == mTunnelUp
    check req.params == %*{"name": "web"}

  test "params omitted means nil":
    let line = encodeRequest(1, mDaemonPing)
    let req = decodeRequest(line)
    check req.id == some(1)
    check req.params.isNil

  test "a notification has id set to none":
    let line = encodeNotification(mTunnelDown, %*{"name": "web"})
    let req = decodeRequest(line)
    check req.id.isNone
    check req.methodName == mTunnelDown
    check req.params == %*{"name": "web"}

suite "response round-trip":
  test "success response":
    let line = encodeSuccess(7, %*{"pid": 123})
    let res = decodeResponse(line)
    check res.id == some(7)
    check res.result == %*{"pid": 123}
    check res.error.isNone

  test "success response with result omitted":
    let line = encodeSuccess(7, nil)
    let res = decodeResponse(line)
    check res.id == some(7)
    check res.result.isNil
    check res.error.isNone

  test "error response (with data)":
    let line = encodeError(7, errTunnelNotFound, "tunnel not found", %*{"name": "web"})
    let res = decodeResponse(line)
    check res.id == some(7)
    check res.result.isNil
    check res.error.isSome
    let errInfo = res.error.get
    check errInfo.code == errTunnelNotFound
    check errInfo.message == "tunnel not found"
    check errInfo.data == %*{"name": "web"}

  test "error response (without data) has data set to nil":
    let line = encodeError(7, rpcInternalError, "boom")
    let res = decodeResponse(line)
    check res.error.get.data.isNil

suite "fields are omitted when params/result/data are nil":
  test "encodeRequest: no \"params\" key when params is omitted":
    let j = parseJson(encodeRequest(1, mDaemonPing))
    check not j.hasKey("params")

  test "encodeNotification: no \"params\" key when params is omitted":
    let j = parseJson(encodeNotification(mDaemonPing))
    check not j.hasKey("params")

  test "encodeSuccess: no \"result\" key when result is omitted":
    let j = parseJson(encodeSuccess(1, nil))
    check not j.hasKey("result")

  test "encodeError: no \"data\" key when data is omitted":
    let j = parseJson(encodeError(1, rpcInternalError, "boom"))
    check not j["error"].hasKey("data")

  test "encodeNotification has no \"id\" key at all":
    let j = parseJson(encodeNotification(mDaemonPing))
    check not j.hasKey("id")

suite "decode* error cases":
  test "an empty string is RpcParseError (rpeInvalidJson)":
    expect RpcParseError:
      discard decodeRequest("")
    try:
      discard decodeRequest("")
      fail()
    except RpcParseError as e:
      check e.kind == rpeInvalidJson

  test "malformed JSON is RpcParseError (rpeInvalidJson)":
    try:
      discard decodeRequest("{not json")
      fail()
    except RpcParseError as e:
      check e.kind == rpeInvalidJson

  test "JSON whose top level is an array":
    try:
      discard decodeRequest("[1, 2, 3]")
      fail()
    except RpcParseError as e:
      check e.kind == rpeInvalidJson

  test "the jsonrpc field is missing":
    try:
      discard decodeRequest("""{"method": "daemon.ping"}""")
      fail()
    except RpcParseError as e:
      check e.kind == rpeInvalidVersion

  test "the jsonrpc field is \"1.0\"":
    try:
      discard decodeRequest("""{"jsonrpc": "1.0", "method": "daemon.ping"}""")
      fail()
    except RpcParseError as e:
      check e.kind == rpeInvalidVersion

  test "the method field is missing (request)":
    try:
      discard decodeRequest("""{"jsonrpc": "2.0"}""")
      fail()
    except RpcParseError as e:
      check e.kind == rpeMissingField

  test "the method field is not a string":
    try:
      discard decodeRequest("""{"jsonrpc": "2.0", "method": 1}""")
      fail()
    except RpcParseError as e:
      check e.kind == rpeInvalidField

  test "the id field is not an integer (request)":
    try:
      discard decodeRequest("""{"jsonrpc": "2.0", "method": "daemon.ping", "id": "1"}""")
      fail()
    except RpcParseError as e:
      check e.kind == rpeInvalidField

  test "the id field is missing (response)":
    try:
      discard decodeResponse("""{"jsonrpc": "2.0", "result": 1}""")
      fail()
    except RpcParseError as e:
      check e.kind == rpeMissingField

  test "error.code is missing (response)":
    try:
      discard decodeResponse("""{"jsonrpc": "2.0", "id": 1, "error": {"message": "x"}}""")
      fail()
    except RpcParseError as e:
      check e.kind == rpeMissingField

  test "error.message is not a string (response)":
    try:
      discard decodeResponse(
          """{"jsonrpc": "2.0", "id": 1, "error": {"code": -1, "message": 1}}""")
      fail()
    except RpcParseError as e:
      check e.kind == rpeInvalidField

  test "an empty string is also RpcParseError for decodeResponse":
    expect RpcParseError:
      discard decodeResponse("")

suite "round-tripping types.nim's types":
  test "ForwardSpec (fkLocal)":
    let spec = ForwardSpec(kind: fkLocal, bindAddr: "127.0.0.1", bindPort: Port(15432),
                            targetHost: "db.internal", targetPort: Port(5432))
    let j = toJson(spec)
    check j["kind"].getStr == "L"
    check j["bindPort"].getInt == 15432
    check forwardSpecFromJson(j) == spec

  test "ForwardSpec (fkRemote)":
    let spec = ForwardSpec(kind: fkRemote, bindAddr: "0.0.0.0", bindPort: Port(8443),
                            targetHost: "localhost", targetPort: Port(3000))
    let j = toJson(spec)
    check j["kind"].getStr == "R"
    check forwardSpecFromJson(j) == spec

  test "RetryPolicy":
    let policy = initRetryPolicy(maxConsecutiveFailures = 3,
        backoffMaxSeconds = 12.5)
    let j = toJson(policy)
    check retryPolicyFromJson(j) == policy

  test "RetryPolicy (defaults)":
    let policy = initRetryPolicy()
    check retryPolicyFromJson(toJson(policy)) == policy

  test "TunnelConfig":
    let cfg = TunnelConfig(
      name: "web",
      host: "myhost",
      spec: ForwardSpec(kind: fkLocal, bindAddr: defaultBindAddr, bindPort: Port(15432),
                         targetHost: "db.internal", targetPort: Port(5432)),
      autostart: true,
      profile: "default",
      sshExtraArgs: @["-vvv", "-o", "ExitOnForwardFailure=yes"],
      retry: initRetryPolicy(maxConsecutiveFailures = 5)
    )
    let j = toJson(cfg)
    check tunnelConfigFromJson(j) == cfg

  test "TunnelConfig (sshExtraArgs empty)":
    let cfg = TunnelConfig(
      name: "empty-args",
      host: "myhost",
      spec: ForwardSpec(kind: fkRemote, bindAddr: defaultBindAddr, bindPort: Port(9000),
                         targetHost: "127.0.0.1", targetPort: Port(80)),
      autostart: false,
      profile: "",
      sshExtraArgs: @[],
      retry: initRetryPolicy()
    )
    check tunnelConfigFromJson(toJson(cfg)) == cfg

  test "HostSessionKey":
    let key = HostSessionKey(host: "myhost", fingerprint: "abc123")
    let j = toJson(key)
    check hostSessionKeyFromJson(j) == key

  test "UpstreamTarget (ukUnix)":
    let target = UpstreamTarget(kind: ukUnix, path: "/tmp/pw/abcdef01.sock")
    let j = toJson(target)
    check j["kind"].getStr == "ukUnix"
    check j["path"].getStr == "/tmp/pw/abcdef01.sock"
    check upstreamTargetFromJson(j) == target

  test "UpstreamTarget (ukTcp)":
    let target = UpstreamTarget(kind: ukTcp, port: Port(9999))
    let j = toJson(target)
    check j["kind"].getStr == "ukTcp"
    check j["port"].getInt == 9999
    check upstreamTargetFromJson(j) == target

  test "UpstreamTarget's == is false when kind differs":
    let a = UpstreamTarget(kind: ukUnix, path: "/tmp/a.sock")
    let b = UpstreamTarget(kind: ukTcp, port: Port(1))
    check a != b

suite "carrying a TunnelConfig round-trip as RPC params":
  test "usable as tunnel.create's params":
    let cfg = TunnelConfig(
      name: "web",
      host: "myhost",
      spec: ForwardSpec(kind: fkLocal, bindAddr: defaultBindAddr, bindPort: Port(15432),
                         targetHost: "db.internal", targetPort: Port(5432)),
      autostart: true,
      profile: "default",
      sshExtraArgs: @[],
      retry: initRetryPolicy()
    )
    let line = encodeRequest(1, mTunnelCreate, toJson(cfg))
    let req = decodeRequest(line)
    check req.methodName == mTunnelCreate
    check tunnelConfigFromJson(req.params) == cfg
