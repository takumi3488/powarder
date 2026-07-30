## Tests for `powarder/core/forwardspec`.

import std/unittest
import std/nativesockets ## needed to use `Port`'s `==`
import powarder/core/types
import powarder/core/forwardspec

suite "parseForwardSpec - happy path":
  test "port:host:port (bindAddr omitted)":
    let spec = parseForwardSpec("15432:db.internal:5432", fkLocal)
    check spec.bindAddr == defaultBindAddr
    check spec.bindPort == Port(15432)
    check spec.targetHost == "db.internal"
    check spec.targetPort == Port(5432)

  test "bindAddr:port:host:port (bindAddr explicit)":
    let spec = parseForwardSpec("127.0.0.1:15432:db.internal:5432", fkLocal)
    check spec.bindAddr == "127.0.0.1"
    check spec.bindPort == Port(15432)
    check spec.targetHost == "db.internal"
    check spec.targetPort == Port(5432)

  test "0.0.0.0 exposes it externally":
    let spec = parseForwardSpec("0.0.0.0:8443:localhost:3000", fkLocal)
    check spec.bindAddr == "0.0.0.0"
    check spec.bindPort == Port(8443)
    check spec.targetHost == "localhost"
    check spec.targetPort == Port(3000)
    check spec.exposesExternally

  test "* is normalized to 0.0.0.0 (same meaning: all addresses)":
    let spec = parseForwardSpec("*:8443:localhost:3000", fkLocal)
    check spec.bindAddr == "0.0.0.0"
    check spec.exposesExternally

  test "IPv6 bracket notation (bindAddr is IPv6)":
    let spec = parseForwardSpec("[::1]:15432:db.internal:5432", fkLocal)
    check spec.bindAddr == "::1"
    check spec.bindPort == Port(15432)
    check spec.targetHost == "db.internal"
    check spec.targetPort == Port(5432)

  test "IPv6 bracket notation (target is IPv6)":
    let spec = parseForwardSpec("15432:[fd00::1]:5432", fkLocal)
    check spec.bindAddr == defaultBindAddr
    check spec.bindPort == Port(15432)
    check spec.targetHost == "fd00::1"
    check spec.targetPort == Port(5432)

  test "IPv6 all-addresses [::]":
    let spec = parseForwardSpec("[::]:8443:localhost:3000", fkLocal)
    check spec.bindAddr == "::"
    check spec.bindPort == Port(8443)
    check spec.targetHost == "localhost"
    check spec.targetPort == Port(3000)

suite "parseForwardSpec - error path":
  test "not enough fields":
    expect ValueError:
      discard parseForwardSpec("5432", fkLocal)

  test "too many fields":
    expect ValueError:
      discard parseForwardSpec("a:b:c:d:e", fkLocal)

  test "port is not numeric":
    expect ValueError:
      discard parseForwardSpec("abc:localhost:80", fkLocal)

  test "port is 0 (out of range)":
    expect ValueError:
      discard parseForwardSpec("0:localhost:80", fkLocal)

  test "port is 65536 (out of range, above the limit)":
    expect ValueError:
      discard parseForwardSpec("65536:localhost:80", fkLocal)

  test "port is negative (out of range)":
    expect ValueError:
      discard parseForwardSpec("-1:localhost:80", fkLocal)

  test "unterminated bracket":
    expect ValueError:
      discard parseForwardSpec("[::1:15432:host:80", fkLocal)

  test "empty string":
    expect ValueError:
      discard parseForwardSpec("", fkLocal)

suite "formatForwardSpec":
  test "outputs defaultBindAddr explicitly rather than omitting it":
    let spec = ForwardSpec(kind: fkLocal, bindAddr: defaultBindAddr,
                            bindPort: Port(15432), targetHost: "db.internal",
                            targetPort: Port(5432))
    check formatForwardSpec(spec) == "127.0.0.1:15432:db.internal:5432"

  test "IPv6 is output bracketed (both bindAddr and targetHost)":
    let spec = ForwardSpec(kind: fkLocal, bindAddr: "::1", bindPort: Port(15432),
                            targetHost: "fd00::1", targetPort: Port(5432))
    check formatForwardSpec(spec) == "[::1]:15432:[fd00::1]:5432"

suite "parseForwardSpec / formatForwardSpec round trip":
  test "round trip (IPv4, 0.0.0.0)":
    let spec = parseForwardSpec("0.0.0.0:8443:localhost:3000", fkLocal)
    check parseForwardSpec(formatForwardSpec(spec), fkLocal) == spec

  test "round trip (IPv6 bindAddr + IPv6 targetHost)":
    let spec = parseForwardSpec("[::1]:15432:[fd00::1]:5432", fkLocal)
    check parseForwardSpec(formatForwardSpec(spec), fkLocal) == spec

  test "round trip (still matches even from the bindAddr-omitted form)":
    let spec = parseForwardSpec("15432:db.internal:5432", fkLocal)
    check parseForwardSpec(formatForwardSpec(spec), fkLocal) == spec

  test "round trip (fkRemote)":
    let spec = parseForwardSpec("9000:127.0.0.1:80", fkRemote)
    check parseForwardSpec(formatForwardSpec(spec), fkRemote) == spec

suite "toSshForwardArg":
  test "fkLocal + udsPath given uses the UDS route and omits bindPort":
    let spec = parseForwardSpec("15432:db.internal:5432", fkLocal)
    check toSshForwardArg(spec, "/tmp/pw/abcdef01.sock") ==
      "/tmp/pw/abcdef01.sock:db.internal:5432"

  test "fkLocal + udsPath omitted falls back to TCP":
    let spec = parseForwardSpec("15432:db.internal:5432", fkLocal)
    check toSshForwardArg(spec) == "127.0.0.1:15432:db.internal:5432"

  test "fkRemote ignores udsPath even if given, and never uses UDS":
    let spec = parseForwardSpec("9000:127.0.0.1:80", fkRemote)
    check toSshForwardArg(spec, "/tmp/pw/abcdef01.sock") ==
      "127.0.0.1:9000:127.0.0.1:80"

  test "IPv6 gets bracketed":
    let spec = parseForwardSpec("[::1]:15432:[fd00::1]:5432", fkLocal)
    check toSshForwardArg(spec) == "[::1]:15432:[fd00::1]:5432"

suite "forwardId":
  test "fkLocal is determined by the local port alone, without host":
    let spec = parseForwardSpec("15432:db.internal:5432", fkLocal)
    check forwardId(spec, "hostA") == "L:127.0.0.1:15432"
    check forwardId(spec, "hostB") == "L:127.0.0.1:15432"

  test "fkRemote gets a different id per host":
    let spec = parseForwardSpec("9000:127.0.0.1:80", fkRemote)
    check forwardId(spec, "hostA") == "R:hostA:127.0.0.1:9000"
    check forwardId(spec, "hostB") == "R:hostB:127.0.0.1:9000"

suite "udsBasename":
  test "returns an 8-digit lowercase hex string":
    let name = udsBasename("L:127.0.0.1:15432")
    check name.len == 8
    for c in name:
      check c in {'0' .. '9', 'a' .. 'f'}

  test "the same id always produces the same name":
    check udsBasename("L:127.0.0.1:15432") == udsBasename("L:127.0.0.1:15432")

  test "different ids produce different names":
    check udsBasename("L:127.0.0.1:15432") != udsBasename("L:127.0.0.1:15433")
