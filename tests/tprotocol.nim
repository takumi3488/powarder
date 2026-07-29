## `powarder/ipc/protocol` のテスト。

import std/unittest
import std/json
import std/options
import std/nativesockets ## `Port` の `==` を使うために必要
import powarder/core/types
import powarder/ipc/protocol

suite "encode* は改行を含まない":
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

  test "params/result/data が nil でも改行を含まない":
    check '\n' notin encodeRequest(1, mDaemonPing)
    check '\n' notin encodeNotification(mDaemonPing)
    check '\n' notin encodeSuccess(1, nil)
    check '\n' notin encodeError(1, rpcInternalError, "boom")

suite "request の往復変換":
  test "id 付き・params 付き":
    let line = encodeRequest(42, mTunnelUp, %*{"name": "web"})
    let req = decodeRequest(line)
    check req.id == some(42)
    check req.methodName == mTunnelUp
    check req.params == %*{"name": "web"}

  test "params を省略した場合は nil":
    let line = encodeRequest(1, mDaemonPing)
    let req = decodeRequest(line)
    check req.id == some(1)
    check req.params.isNil

  test "notification は id が none":
    let line = encodeNotification(mTunnelDown, %*{"name": "web"})
    let req = decodeRequest(line)
    check req.id.isNone
    check req.methodName == mTunnelDown
    check req.params == %*{"name": "web"}

suite "response の往復変換":
  test "成功応答":
    let line = encodeSuccess(7, %*{"pid": 123})
    let res = decodeResponse(line)
    check res.id == some(7)
    check res.result == %*{"pid": 123}
    check res.error.isNone

  test "result を省略した成功応答":
    let line = encodeSuccess(7, nil)
    let res = decodeResponse(line)
    check res.id == some(7)
    check res.result.isNil
    check res.error.isNone

  test "エラー応答 (data あり)":
    let line = encodeError(7, errTunnelNotFound, "tunnel not found", %*{"name": "web"})
    let res = decodeResponse(line)
    check res.id == some(7)
    check res.result.isNil
    check res.error.isSome
    let errInfo = res.error.get
    check errInfo.code == errTunnelNotFound
    check errInfo.message == "tunnel not found"
    check errInfo.data == %*{"name": "web"}

  test "エラー応答 (data なし) は data が nil":
    let line = encodeError(7, rpcInternalError, "boom")
    let res = decodeResponse(line)
    check res.error.get.data.isNil

suite "params/result/data が nil のときフィールドが省略される":
  test "encodeRequest: params 省略時に \"params\" キーが無い":
    let j = parseJson(encodeRequest(1, mDaemonPing))
    check not j.hasKey("params")

  test "encodeNotification: params 省略時に \"params\" キーが無い":
    let j = parseJson(encodeNotification(mDaemonPing))
    check not j.hasKey("params")

  test "encodeSuccess: result 省略時に \"result\" キーが無い":
    let j = parseJson(encodeSuccess(1, nil))
    check not j.hasKey("result")

  test "encodeError: data 省略時に \"data\" キーが無い":
    let j = parseJson(encodeError(1, rpcInternalError, "boom"))
    check not j["error"].hasKey("data")

  test "encodeNotification は \"id\" キー自体を持たない":
    let j = parseJson(encodeNotification(mDaemonPing))
    check not j.hasKey("id")

suite "decode* の異常系":
  test "空文字列は RpcParseError (rpeInvalidJson)":
    expect RpcParseError:
      discard decodeRequest("")
    try:
      discard decodeRequest("")
      fail()
    except RpcParseError as e:
      check e.kind == rpeInvalidJson

  test "壊れた JSON は RpcParseError (rpeInvalidJson)":
    try:
      discard decodeRequest("{not json")
      fail()
    except RpcParseError as e:
      check e.kind == rpeInvalidJson

  test "JSON だがトップレベルが配列":
    try:
      discard decodeRequest("[1, 2, 3]")
      fail()
    except RpcParseError as e:
      check e.kind == rpeInvalidJson

  test "jsonrpc フィールドが無い":
    try:
      discard decodeRequest("""{"method": "daemon.ping"}""")
      fail()
    except RpcParseError as e:
      check e.kind == rpeInvalidVersion

  test "jsonrpc フィールドが \"1.0\"":
    try:
      discard decodeRequest("""{"jsonrpc": "1.0", "method": "daemon.ping"}""")
      fail()
    except RpcParseError as e:
      check e.kind == rpeInvalidVersion

  test "method フィールドが無い (request)":
    try:
      discard decodeRequest("""{"jsonrpc": "2.0"}""")
      fail()
    except RpcParseError as e:
      check e.kind == rpeMissingField

  test "method フィールドが文字列でない":
    try:
      discard decodeRequest("""{"jsonrpc": "2.0", "method": 1}""")
      fail()
    except RpcParseError as e:
      check e.kind == rpeInvalidField

  test "id フィールドが整数でない (request)":
    try:
      discard decodeRequest("""{"jsonrpc": "2.0", "method": "daemon.ping", "id": "1"}""")
      fail()
    except RpcParseError as e:
      check e.kind == rpeInvalidField

  test "id フィールドが無い (response)":
    try:
      discard decodeResponse("""{"jsonrpc": "2.0", "result": 1}""")
      fail()
    except RpcParseError as e:
      check e.kind == rpeMissingField

  test "error.code が無い (response)":
    try:
      discard decodeResponse("""{"jsonrpc": "2.0", "id": 1, "error": {"message": "x"}}""")
      fail()
    except RpcParseError as e:
      check e.kind == rpeMissingField

  test "error.message が文字列でない (response)":
    try:
      discard decodeResponse(
          """{"jsonrpc": "2.0", "id": 1, "error": {"code": -1, "message": 1}}""")
      fail()
    except RpcParseError as e:
      check e.kind == rpeInvalidField

  test "空文字列は decodeResponse でも RpcParseError":
    expect RpcParseError:
      discard decodeResponse("")

suite "types.nim の型の往復変換":
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

  test "RetryPolicy (既定値)":
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

  test "TunnelConfig (sshExtraArgs が空)":
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

  test "UpstreamTarget の == は kind が違えば false":
    let a = UpstreamTarget(kind: ukUnix, path: "/tmp/a.sock")
    let b = UpstreamTarget(kind: ukTcp, port: Port(1))
    check a != b

suite "TunnelConfig を RPC の params に載せて往復させる":
  test "tunnel.create の params として使える":
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
