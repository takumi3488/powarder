## `powarder/core/forwardspec` のテスト。

import std/unittest
import std/nativesockets ## `Port` の `==` を使うために必要
import powarder/core/types
import powarder/core/forwardspec

suite "parseForwardSpec - 正常系":
  test "port:host:port (bindAddr 省略)":
    let spec = parseForwardSpec("15432:db.internal:5432", fkLocal)
    check spec.bindAddr == defaultBindAddr
    check spec.bindPort == Port(15432)
    check spec.targetHost == "db.internal"
    check spec.targetPort == Port(5432)

  test "bindAddr:port:host:port (bindAddr 明示)":
    let spec = parseForwardSpec("127.0.0.1:15432:db.internal:5432", fkLocal)
    check spec.bindAddr == "127.0.0.1"
    check spec.bindPort == Port(15432)
    check spec.targetHost == "db.internal"
    check spec.targetPort == Port(5432)

  test "0.0.0.0 で外部公開になる":
    let spec = parseForwardSpec("0.0.0.0:8443:localhost:3000", fkLocal)
    check spec.bindAddr == "0.0.0.0"
    check spec.bindPort == Port(8443)
    check spec.targetHost == "localhost"
    check spec.targetPort == Port(3000)
    check spec.exposesExternally

  test "* は 0.0.0.0 に正規化される（全アドレスの意味は同じ）":
    let spec = parseForwardSpec("*:8443:localhost:3000", fkLocal)
    check spec.bindAddr == "0.0.0.0"
    check spec.exposesExternally

  test "IPv6 ブラケット記法 (bindAddr が IPv6)":
    let spec = parseForwardSpec("[::1]:15432:db.internal:5432", fkLocal)
    check spec.bindAddr == "::1"
    check spec.bindPort == Port(15432)
    check spec.targetHost == "db.internal"
    check spec.targetPort == Port(5432)

  test "IPv6 ブラケット記法 (転送先が IPv6)":
    let spec = parseForwardSpec("15432:[fd00::1]:5432", fkLocal)
    check spec.bindAddr == defaultBindAddr
    check spec.bindPort == Port(15432)
    check spec.targetHost == "fd00::1"
    check spec.targetPort == Port(5432)

  test "IPv6 の全アドレス [::]":
    let spec = parseForwardSpec("[::]:8443:localhost:3000", fkLocal)
    check spec.bindAddr == "::"
    check spec.bindPort == Port(8443)
    check spec.targetHost == "localhost"
    check spec.targetPort == Port(3000)

suite "parseForwardSpec - 異常系":
  test "フィールド数が足りない":
    expect ValueError:
      discard parseForwardSpec("5432", fkLocal)

  test "フィールド数が多すぎる":
    expect ValueError:
      discard parseForwardSpec("a:b:c:d:e", fkLocal)

  test "ポートが数値ではない":
    expect ValueError:
      discard parseForwardSpec("abc:localhost:80", fkLocal)

  test "ポートが0（範囲外）":
    expect ValueError:
      discard parseForwardSpec("0:localhost:80", fkLocal)

  test "ポートが65536（範囲外・上限超え）":
    expect ValueError:
      discard parseForwardSpec("65536:localhost:80", fkLocal)

  test "ポートが負数（範囲外）":
    expect ValueError:
      discard parseForwardSpec("-1:localhost:80", fkLocal)

  test "ブラケットが閉じていない":
    expect ValueError:
      discard parseForwardSpec("[::1:15432:host:80", fkLocal)

  test "空文字列":
    expect ValueError:
      discard parseForwardSpec("", fkLocal)

suite "formatForwardSpec":
  test "defaultBindAddr でも省略せず明示的に出力する":
    let spec = ForwardSpec(kind: fkLocal, bindAddr: defaultBindAddr,
                            bindPort: Port(15432), targetHost: "db.internal",
                            targetPort: Port(5432))
    check formatForwardSpec(spec) == "127.0.0.1:15432:db.internal:5432"

  test "IPv6 はブラケット付きで出力される（bindAddr / targetHost 両方）":
    let spec = ForwardSpec(kind: fkLocal, bindAddr: "::1", bindPort: Port(15432),
                            targetHost: "fd00::1", targetPort: Port(5432))
    check formatForwardSpec(spec) == "[::1]:15432:[fd00::1]:5432"

suite "parseForwardSpec / formatForwardSpec 往復変換":
  test "往復変換 (IPv4, 0.0.0.0)":
    let spec = parseForwardSpec("0.0.0.0:8443:localhost:3000", fkLocal)
    check parseForwardSpec(formatForwardSpec(spec), fkLocal) == spec

  test "往復変換 (IPv6 bindAddr + IPv6 targetHost)":
    let spec = parseForwardSpec("[::1]:15432:[fd00::1]:5432", fkLocal)
    check parseForwardSpec(formatForwardSpec(spec), fkLocal) == spec

  test "往復変換 (bindAddr 省略形からでも一致する)":
    let spec = parseForwardSpec("15432:db.internal:5432", fkLocal)
    check parseForwardSpec(formatForwardSpec(spec), fkLocal) == spec

  test "往復変換 (fkRemote)":
    let spec = parseForwardSpec("9000:127.0.0.1:80", fkRemote)
    check parseForwardSpec(formatForwardSpec(spec), fkRemote) == spec

suite "toSshForwardArg":
  test "fkLocal + udsPath 指定時は UDS 経路になり bindPort は含まれない":
    let spec = parseForwardSpec("15432:db.internal:5432", fkLocal)
    check toSshForwardArg(spec, "/tmp/pw/abcdef01.sock") ==
      "/tmp/pw/abcdef01.sock:db.internal:5432"

  test "fkLocal + udsPath 未指定時は TCP フォールバック":
    let spec = parseForwardSpec("15432:db.internal:5432", fkLocal)
    check toSshForwardArg(spec) == "127.0.0.1:15432:db.internal:5432"

  test "fkRemote は udsPath を渡しても無視され UDS を使わない":
    let spec = parseForwardSpec("9000:127.0.0.1:80", fkRemote)
    check toSshForwardArg(spec, "/tmp/pw/abcdef01.sock") ==
      "127.0.0.1:9000:127.0.0.1:80"

  test "IPv6 のブラケットが付与される":
    let spec = parseForwardSpec("[::1]:15432:[fd00::1]:5432", fkLocal)
    check toSshForwardArg(spec) == "[::1]:15432:[fd00::1]:5432"

suite "forwardId":
  test "fkLocal は host を含まずローカルポートのみで決まる":
    let spec = parseForwardSpec("15432:db.internal:5432", fkLocal)
    check forwardId(spec, "hostA") == "L:127.0.0.1:15432"
    check forwardId(spec, "hostB") == "L:127.0.0.1:15432"

  test "fkRemote は host ごとに異なる id になる":
    let spec = parseForwardSpec("9000:127.0.0.1:80", fkRemote)
    check forwardId(spec, "hostA") == "R:hostA:127.0.0.1:9000"
    check forwardId(spec, "hostB") == "R:hostB:127.0.0.1:9000"

suite "udsBasename":
  test "8桁の小文字16進文字列を返す":
    let name = udsBasename("L:127.0.0.1:15432")
    check name.len == 8
    for c in name:
      check c in {'0' .. '9', 'a' .. 'f'}

  test "同じ id からは常に同じ名前が出る":
    check udsBasename("L:127.0.0.1:15432") == udsBasename("L:127.0.0.1:15432")

  test "異なる id からは異なる名前が出る":
    check udsBasename("L:127.0.0.1:15432") != udsBasename("L:127.0.0.1:15433")
