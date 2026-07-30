## Unit tests for `powarder/core/sshgparse`.
## The sample is based on the output format empirically captured on
## 2026-07-29 from `ssh -G localhost` on OpenSSH_10.2p1 (macOS) (stdout only;
## stderr warning lines are not included).

import std/unittest
import std/strutils

import powarder/core/sshgparse

const sampleStdout = """
host localhost
user takumi.mori
hostname localhost
port 22
addressfamily any
batchmode no
canonicalizefallbacklocal yes
canonicalizehostname false
checkhostip no
compression no
controlmaster false
enablesshkeysign no
clearallforwardings no
exitonforwardfailure no
fingerprinthash SHA256
forwardx11 no
forwardx11trusted no
gatewayports no
gssapiauthentication no
gssapidelegatecredentials no
hashknownhosts no
hostbasedauthentication no
identitiesonly no
kbdinteractiveauthentication yes
nohostauthenticationforlocalhost no
nohostauthenticationforproxycommand no
passwordauthentication yes
permitlocalcommand no
proxyusefdpass no
pubkeyauthentication true
requesttty auto
sessiontype default
stdinnull no
forkafterauthentication no
streamlocalbindunlink no
stricthostkeychecking ask
tcpkeepalive yes
tunnel false
verifyhostkeydns false
canonicaldomains none
globalknownhostsfile /etc/ssh/ssh_known_hosts /etc/ssh/ssh_known_hosts2
userknownhostsfile ~/.ssh/known_hosts ~/.ssh/known_hosts2
identityfile ~/.ssh/id_rsa
identityfile ~/.ssh/id_ecdsa
identityfile ~/.ssh/id_ecdsa_sk
identityfile ~/.ssh/id_ed25519
identityfile ~/.ssh/id_ed25519_sk
sendenv LANG
sendenv LC_*
"""

suite "parseSshG":
  test "can parse a sample equivalent to 88 lines, with the correct line count":
    let r = parseSshG(sampleStdout)
    check r.has("host")
    check r.has("hostname")
    check r.has("identityfile")

  test "single-value keys can be read with getFirst":
    let r = parseSshG(sampleStdout)
    check r.getFirst("host") == "localhost"
    check r.getFirst("user") == "takumi.mori"
    check r.getFirst("port") == "22"
    check r.getFirst("pubkeyauthentication") == "true"

  test "identityfile's multiple lines are collected into a seq[string]":
    let r = parseSshG(sampleStdout)
    let files = r.get("identityfile")
    check files.len == 5
    check files == @["~/.ssh/id_rsa", "~/.ssh/id_ecdsa", "~/.ssh/id_ecdsa_sk",
                      "~/.ssh/id_ed25519", "~/.ssh/id_ed25519_sk"]

  test "sendenv's multiple lines are also collected into a seq[string]":
    let r = parseSshG(sampleStdout)
    check r.get("sendenv") == @["LANG", "LC_*"]

  test "a value containing whitespace is kept whole via maxsplit=1 (globalknownhostsfile)":
    let r = parseSshG(sampleStdout)
    check r.getFirst("globalknownhostsfile") ==
      "/etc/ssh/ssh_known_hosts /etc/ssh/ssh_known_hosts2"

  test "a missing key returns an empty seq from get, and the default from getFirst":
    let r = parseSshG(sampleStdout)
    check r.get("nosuchkey").len == 0
    check r.getFirst("nosuchkey") == ""
    check r.getFirst("nosuchkey", "fallback") == "fallback"
    check not r.has("nosuchkey")

  test "keys can be queried case-insensitively":
    let r = parseSshG(sampleStdout)
    check r.getFirst("HOST") == "localhost"
    check r.has("Hostname")

  test "blank lines are ignored":
    let r = parseSshG("host localhost\n\n\nport 22\n")
    check r.getFirst("host") == "localhost"
    check r.getFirst("port") == "22"

  test "a key-only line with no value (format mismatch) is silently ignored":
    let r = parseSshG("host localhost\nthisisabrokenline\nport 22\n")
    check r.getFirst("host") == "localhost"
    check r.getFirst("port") == "22"
    check not r.has("thisisabrokenline")

  test "a stray stderr warning line mixed in is ignored as a format mismatch":
    # Empirically, `ssh -G` can emit a line like
    # "Pseudo-terminal will not be allocated because stdin is not a terminal."
    # on stderr. Only stdout should be parsed, but this guarantees nothing
    # breaks even if such a line accidentally gets mixed in.
    let contaminated = sampleStdout &
      "Pseudo-terminal will not be allocated because stdin is not a terminal.\n"
    let r = parseSshG(contaminated)
    check r.getFirst("host") == "localhost"
    # Confirms the warning line's first word "Pseudo-terminal" was not
    # mistakenly registered as a key.
    check not r.has("pseudo-terminal")

  test "passing a completely empty string does not raise":
    let r = parseSshG("")
    check r.get("host").len == 0

suite "fingerprint":
  test "the same content produces the same fingerprint even if line order differs":
    let a = parseSshG("host x\nport 22\nuser bob\n")
    let b = parseSshG("user bob\nhost x\nport 22\n")
    check a.fingerprint() == b.fingerprint()

  test "a single differing value produces a different fingerprint":
    let a = parseSshG("host x\nport 22\nuser bob\n")
    let b = parseSshG("host x\nport 23\nuser bob\n")
    check a.fingerprint() != b.fingerprint()

  test "fingerprint is the first 16 characters, lowercase hex":
    let r = parseSshG(sampleStdout)
    let fp = r.fingerprint()
    check fp.len == 16
    check fp == fp.toLowerAscii()
    check fp.allCharsInSet(HexDigits)

  test "a change touching only excluded keys " &
      "(sessiontype/requesttty/stdinnull/forkafterauthentication) " &
      "does not change the fingerprint":
    let a = parseSshG(sampleStdout)
    let modified = sampleStdout
      .replace("sessiontype default", "sessiontype none")
      .replace("requesttty auto", "requesttty yes")
      .replace("stdinnull no", "stdinnull yes")
      .replace("forkafterauthentication no", "forkafterauthentication yes")
    let b = parseSshG(modified)
    check a.fingerprint() == b.fingerprint()

  test "a change to a non-excluded key (hostname) does change the fingerprint":
    let a = parseSshG(sampleStdout)
    let modified = sampleStdout.replace("hostname localhost", "hostname example.com")
    let b = parseSshG(modified)
    check a.fingerprint() != b.fingerprint()

  test "a change to a seq-valued key's content (e.g. identityfile) changes the fingerprint":
    let a = parseSshG(sampleStdout)
    let modified = sampleStdout.replace("identityfile ~/.ssh/id_rsa\n", "")
    let b = parseSshG(modified)
    check a.fingerprint() != b.fingerprint()
