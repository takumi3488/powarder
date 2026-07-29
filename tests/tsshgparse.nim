## `powarder/core/sshgparse` のユニットテスト。
## サンプルは 2026-07-29 に OpenSSH_10.2p1 (macOS) の `ssh -G localhost` を
## 実測した出力形式に基づく（stdout のみ。stderr の警告文は含めない）。

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
  test "88行相当のサンプルを行数どおりにパースできる":
    let r = parseSshG(sampleStdout)
    check r.has("host")
    check r.has("hostname")
    check r.has("identityfile")

  test "単一値キーは getFirst で取れる":
    let r = parseSshG(sampleStdout)
    check r.getFirst("host") == "localhost"
    check r.getFirst("user") == "takumi.mori"
    check r.getFirst("port") == "22"
    check r.getFirst("pubkeyauthentication") == "true"

  test "identityfile は複数行が seq[string] に集約される":
    let r = parseSshG(sampleStdout)
    let files = r.get("identityfile")
    check files.len == 5
    check files == @["~/.ssh/id_rsa", "~/.ssh/id_ecdsa", "~/.ssh/id_ecdsa_sk",
                      "~/.ssh/id_ed25519", "~/.ssh/id_ed25519_sk"]

  test "sendenv も複数行が seq[string] に集約される":
    let r = parseSshG(sampleStdout)
    check r.get("sendenv") == @["LANG", "LC_*"]

  test "値の中に空白があっても maxsplit=1 で丸ごと保持される（globalknownhostsfile）":
    let r = parseSshG(sampleStdout)
    check r.getFirst("globalknownhostsfile") ==
      "/etc/ssh/ssh_known_hosts /etc/ssh/ssh_known_hosts2"

  test "存在しないキーは get で空 seq, getFirst で既定値":
    let r = parseSshG(sampleStdout)
    check r.get("nosuchkey").len == 0
    check r.getFirst("nosuchkey") == ""
    check r.getFirst("nosuchkey", "fallback") == "fallback"
    check not r.has("nosuchkey")

  test "キーは大文字小文字を区別せずに問い合わせできる":
    let r = parseSshG(sampleStdout)
    check r.getFirst("HOST") == "localhost"
    check r.has("Hostname")

  test "空行は無視される":
    let r = parseSshG("host localhost\n\n\nport 22\n")
    check r.getFirst("host") == "localhost"
    check r.getFirst("port") == "22"

  test "キーだけで値のない行（フォーマット不一致）は黙って無視される":
    let r = parseSshG("host localhost\nthisisabrokenline\nport 22\n")
    check r.getFirst("host") == "localhost"
    check r.getFirst("port") == "22"
    check not r.has("thisisabrokenline")

  test "stderr の警告文が誤って混入しても形式不一致として無視される":
    # 実測: `ssh -G` は stderr に
    # "Pseudo-terminal will not be allocated because stdin is not a terminal."
    # のような行を出すことがある。パース対象は stdout のみであるべきだが、
    # 万一混ざっても壊れないことを保証する。
    let contaminated = sampleStdout &
      "Pseudo-terminal will not be allocated because stdin is not a terminal.\n"
    let r = parseSshG(contaminated)
    check r.getFirst("host") == "localhost"
    # 警告文の1語目 "Pseudo-terminal" をキーとして誤登録していないこと
    check not r.has("pseudo-terminal")

  test "完全な空文字列を渡しても例外を投げない":
    let r = parseSshG("")
    check r.get("host").len == 0

suite "fingerprint":
  test "同じ内容なら行の出現順が違っても同じ fingerprint になる":
    let a = parseSshG("host x\nport 22\nuser bob\n")
    let b = parseSshG("user bob\nhost x\nport 22\n")
    check a.fingerprint() == b.fingerprint()

  test "1つでも値が違えば別の fingerprint になる":
    let a = parseSshG("host x\nport 22\nuser bob\n")
    let b = parseSshG("host x\nport 23\nuser bob\n")
    check a.fingerprint() != b.fingerprint()

  test "fingerprint は先頭16文字の小文字16進数":
    let r = parseSshG(sampleStdout)
    let fp = r.fingerprint()
    check fp.len == 16
    check fp == fp.toLowerAscii()
    check fp.allCharsInSet(HexDigits)

  test "除外キー(sessiontype/requesttty/stdinnull/forkafterauthentication)のみの" &
      "変化では fingerprint が変わらない":
    let a = parseSshG(sampleStdout)
    let modified = sampleStdout
      .replace("sessiontype default", "sessiontype none")
      .replace("requesttty auto", "requesttty yes")
      .replace("stdinnull no", "stdinnull yes")
      .replace("forkafterauthentication no", "forkafterauthentication yes")
    let b = parseSshG(modified)
    check a.fingerprint() == b.fingerprint()

  test "除外対象外のキー(hostname)が変われば fingerprint も変わる":
    let a = parseSshG(sampleStdout)
    let modified = sampleStdout.replace("hostname localhost", "hostname example.com")
    let b = parseSshG(modified)
    check a.fingerprint() != b.fingerprint()

  test "identityfile など seq 値の内容が変われば fingerprint も変わる":
    let a = parseSshG(sampleStdout)
    let modified = sampleStdout.replace("identityfile ~/.ssh/id_rsa\n", "")
    let b = parseSshG(modified)
    check a.fingerprint() != b.fingerprint()
