## Tests for `powarder/core/hashid`.

import std/unittest
import std/strutils

import powarder/core/hashid
import powarder/core/forwardspec
import powarder/core/sshgparse

suite "fnv1a64 - standard test vectors":
  # Known input/output pairs for FNV-1a 64bit as defined at
  # http://www.isthe.com/chongo/tech/comp/fnv/. This is the only way to verify
  # the implementation matches the spec, so if this fails, fix the
  # implementation (the expected values must not be edited).
  test "empty string -> 0xcbf29ce484222325":
    check fnv1a64("") == 0xcbf29ce484222325'u64

  test "\"a\" -> 0xaf63dc4c8601ec8c":
    check fnv1a64("a") == 0xaf63dc4c8601ec8c'u64

  test "\"foobar\" -> 0x85944171f73967e8":
    check fnv1a64("foobar") == 0x85944171f73967e8'u64

suite "hashHex":
  test "returns lowercase hex with the requested digit count":
    let h = hashHex("hello", 8)
    check h.len == 8
    check h == h.toLowerAscii()
    check h.allCharsInSet(HexDigits)

  test "digits=16 also returns lowercase hex":
    let h = hashHex("hello", 16)
    check h.len == 16
    check h.allCharsInSet(HexDigits)

  test "digits=1 minimal case":
    let h = hashHex("hello", 1)
    check h.len == 1
    check h.allCharsInSet(HexDigits)

  test "the same input always produces the same output":
    check hashHex("same-input", 8) == hashHex("same-input", 8)
    check fnv1a64("same-input") == fnv1a64("same-input")

  test "different inputs produce different outputs":
    check hashHex("input-a", 8) != hashHex("input-b", 8)
    check fnv1a64("input-a") != fnv1a64("input-b")

  test "matches the leading digits of fnv1a64 for a known input":
    let expectedFull = toLowerAscii(toHex(fnv1a64("foobar")))
    check hashHex("foobar", 16) == expectedFull
    check hashHex("foobar", 8) == expectedFull[0 ..< 8]

suite "udsBasename (forwardspec) - properties after the swap":
  test "returns an 8-digit lowercase hex string":
    let name = udsBasename("L:127.0.0.1:15432")
    check name.len == 8
    check name == name.toLowerAscii()
    check name.allCharsInSet(HexDigits)

  test "the same id always produces the same basename":
    check udsBasename("L:127.0.0.1:15432") == udsBasename("L:127.0.0.1:15432")

  test "different ids produce different basenames":
    check udsBasename("L:127.0.0.1:15432") != udsBasename("L:127.0.0.1:15433")

suite "fingerprint (sshgparse) - properties after the swap":
  test "returns a 16-digit lowercase hex string":
    let r = parseSshG("host x\nport 22\nuser bob\n")
    let fp = r.fingerprint()
    check fp.len == 16
    check fp == fp.toLowerAscii()
    check fp.allCharsInSet(HexDigits)

  test "the same content produces the same fingerprint even if line order differs":
    let a = parseSshG("host x\nport 22\nuser bob\n")
    let b = parseSshG("user bob\nhost x\nport 22\n")
    check a.fingerprint() == b.fingerprint()

  test "a single differing value produces a different fingerprint":
    let a = parseSshG("host x\nport 22\nuser bob\n")
    let b = parseSshG("host x\nport 23\nuser bob\n")
    check a.fingerprint() != b.fingerprint()
