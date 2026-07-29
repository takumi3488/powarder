## `powarder/core/hashid` のテスト。

import std/unittest
import std/strutils

import powarder/core/hashid
import powarder/core/forwardspec
import powarder/core/sshgparse

suite "fnv1a64 - 標準テストベクタ":
  # http://www.isthe.com/chongo/tech/comp/fnv/ が定める FNV-1a 64bit の
  # 既知の入出力。実装が仕様通りかを検証できる唯一の手段なので、
  # もしこれが落ちたら実装を直すこと（値の書き換えは不可）。
  test "空文字列 -> 0xcbf29ce484222325":
    check fnv1a64("") == 0xcbf29ce484222325'u64

  test "\"a\" -> 0xaf63dc4c8601ec8c":
    check fnv1a64("a") == 0xaf63dc4c8601ec8c'u64

  test "\"foobar\" -> 0x85944171f73967e8":
    check fnv1a64("foobar") == 0x85944171f73967e8'u64

suite "hashHex":
  test "指定桁数の小文字hexを返す":
    let h = hashHex("hello", 8)
    check h.len == 8
    check h == h.toLowerAscii()
    check h.allCharsInSet(HexDigits)

  test "digits=16 でも小文字hexを返す":
    let h = hashHex("hello", 16)
    check h.len == 16
    check h.allCharsInSet(HexDigits)

  test "digits=1 の最小ケース":
    let h = hashHex("hello", 1)
    check h.len == 1
    check h.allCharsInSet(HexDigits)

  test "同じ入力は常に同じ出力":
    check hashHex("same-input", 8) == hashHex("same-input", 8)
    check fnv1a64("same-input") == fnv1a64("same-input")

  test "異なる入力は異なる出力になる":
    check hashHex("input-a", 8) != hashHex("input-b", 8)
    check fnv1a64("input-a") != fnv1a64("input-b")

  test "既知の入力に対して fnv1a64 と一致する先頭桁を返す":
    let expectedFull = toLowerAscii(toHex(fnv1a64("foobar")))
    check hashHex("foobar", 16) == expectedFull
    check hashHex("foobar", 8) == expectedFull[0 ..< 8]

suite "udsBasename (forwardspec) - 差し替え後の性質":
  test "8桁の小文字hexを返す":
    let name = udsBasename("L:127.0.0.1:15432")
    check name.len == 8
    check name == name.toLowerAscii()
    check name.allCharsInSet(HexDigits)

  test "同じ id は常に同じ basename":
    check udsBasename("L:127.0.0.1:15432") == udsBasename("L:127.0.0.1:15432")

  test "異なる id は異なる basename":
    check udsBasename("L:127.0.0.1:15432") != udsBasename("L:127.0.0.1:15433")

suite "fingerprint (sshgparse) - 差し替え後の性質":
  test "16桁の小文字hexを返す":
    let r = parseSshG("host x\nport 22\nuser bob\n")
    let fp = r.fingerprint()
    check fp.len == 16
    check fp == fp.toLowerAscii()
    check fp.allCharsInSet(HexDigits)

  test "同じ内容なら行の出現順が違っても同じ fingerprint":
    let a = parseSshG("host x\nport 22\nuser bob\n")
    let b = parseSshG("user bob\nhost x\nport 22\n")
    check a.fingerprint() == b.fingerprint()

  test "1つでも値が違えば別の fingerprint":
    let a = parseSshG("host x\nport 22\nuser bob\n")
    let b = parseSshG("host x\nport 23\nuser bob\n")
    check a.fingerprint() != b.fingerprint()
