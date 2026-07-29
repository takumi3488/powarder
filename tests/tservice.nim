## `powarder/platform/service`（OS サービス登録）のテスト。
##
## **`launchctl` / `systemctl` を実際に呼ぶテストはしない。** ユーザーの実環境
## （`~/Library/LaunchAgents/` や `~/.config/systemd/user/`、実際のサービス登録
## 状態）を汚してしまうため。`installService` / `uninstallService` /
## `serviceStatus` はここでは一切呼ばない。
##
## `renderUnitFile` / `unitFilePath` / `lingerNote` を純粋関数にしてあるので、
## **生成される文字列だけ** を検証する方針にする。
##
## macOS/Linux 両方の出力を検証したいので、`platform/service`（現在の OS に
## 応じて振り分けるフロントエンド）だけでなく `platform/service_darwin` /
## `platform/service_linux` を **直接** import する。この2つのモジュールは
## `launchctl`/`systemctl` バイナリの実体には一切依存しない（`osproc` 越しに
## コマンド名を呼ぶだけの副作用関数を除けば、文字列組み立てのみの
## クロスプラットフォームな Nim コード）ため、開発機が macOS でも Linux でも
## 両方コンパイル・実行できる。
##
## **注意（このモジュールを読む上での罠）**: `powarder/platform/service` /
## `service_darwin` / `service_linux` は、共通の型・`serviceLabel` を
## `platform/service_types` から一方向に import する構成になっており
## （`service_types` ← `service_darwin`/`service_linux` ← `service`）、
## モジュール間の循環 import は無い。だが
## **`unitFilePath` / `renderUnitFile` / `installService` / `uninstallService` /
## `serviceStatus` は `service` / `service_darwin` / `service_linux` の
## 3モジュールすべてに同名の proc として存在する**ため、このテストファイルの
## ようにすべてを同時に import すると **必ず `service_darwin.xxx` /
## `service_linux.xxx` のように修飾して呼ぶ必要がある**（非修飾で呼ぶと
## `ambiguous call` になる。これは循環 import とは無関係な、単なる同名 proc の
## 曖昧性の問題）。`serviceLabel` / `ServiceInfo` / `ServiceStatus` は
## `service_types` にしか定義が無く、`service_darwin` / `service_linux` は
## それを import しているだけ（再定義していない）ので修飾は不要。

import std/[unittest, os, strutils]
import powarder/platform/service
import powarder/platform/service_darwin
import powarder/platform/service_linux
import powarder/core/paths

proc withEnv(pairs: openArray[(string, string)], body: proc()) =
  ## 環境変数を一時的に差し替える（`tests/tpaths.nim` のヘルパーを踏襲）。
  var saved: seq[(string, bool, string)]
  for (k, v) in pairs:
    saved.add (k, existsEnv(k), getEnv(k))
    putEnv(k, v)
  try:
    body()
  finally:
    for (k, existed, old) in saved:
      if existed: putEnv(k, old) else: delEnv(k)

proc extractPlistString(content, key: string): string =
  ## `<key>K</key><string>V</string>` の V 部分を取り出す簡易パーサ
  ## （フルの plist パーサは要らないので、テスト用にこれで十分）。
  let marker = "<key>" & key & "</key><string>"
  let idx = content.find(marker)
  if idx < 0: return ""
  let valueStart = idx + marker.len
  let valueEnd = content.find("</string>", valueStart)
  if valueEnd < 0: return ""
  content[valueStart ..< valueEnd]

# ===========================================================================
# serviceLabel / unitFilePath（`platform/service` の OS 振り分け）
# ===========================================================================

suite "service: serviceLabel / unitFilePath":
  test "serviceLabel は OS に依らず \"dev.powarder.daemon\"":
    check serviceLabel() == "dev.powarder.daemon"

  test "unitFilePath は現在の OS に応じた期待パスを返す":
    when defined(macosx):
      check service.unitFilePath() ==
          getHomeDir() / "Library" / "LaunchAgents" / "dev.powarder.daemon.plist"
    elif defined(linux):
      check service.unitFilePath() ==
          getHomeDir() / ".config" / "systemd" / "user" / "powarder.service"

# ===========================================================================
# macOS: plist の生成（service_darwin.renderUnitFile）
# ===========================================================================

suite "service_darwin: renderUnitFile":
  test "unitFilePath は ~/Library/LaunchAgents/dev.powarder.daemon.plist":
    check service_darwin.unitFilePath() ==
        getHomeDir() / "Library" / "LaunchAgents" / "dev.powarder.daemon.plist"

  test "★最重要: KeepAlive の SuccessfulExit が false になっている":
    # これが逆（true や無し）だと `powarder daemon stop`（exit 0）が
    # launchd に即座に再起動されてしまい、デーモンを止められなくなる。
    let plist = service_darwin.renderUnitFile("/usr/local/bin/powarder")
    check "<key>KeepAlive</key>" in plist
    check "<dict><key>SuccessfulExit</key><false/></dict>" in plist
    # 素朴な <true/> 一発の KeepAlive になっていないことも明示的に確認する
    check "<key>KeepAlive</key><true/>" notin plist

  test "RunAtLoad / Label / ProgramArguments（実行ファイルパスと daemon）を含む":
    let plist = service_darwin.renderUnitFile("/opt/homebrew/bin/powarder")
    check "<key>RunAtLoad</key><true/>" in plist
    check "<key>Label</key><string>dev.powarder.daemon</string>" in plist
    check "<key>ProgramArguments</key>" in plist
    check "<string>/opt/homebrew/bin/powarder</string>" in plist
    check "<string>daemon</string>" in plist

  test "configPath を渡すと ProgramArguments に --config が追加される":
    let plist = service_darwin.renderUnitFile("/usr/local/bin/powarder",
        "/home/x/.config/powarder/config.json")
    check "<string>--config</string>" in plist
    check "<string>/home/x/.config/powarder/config.json</string>" in plist

  test "configPath 省略時は --config が出てこない":
    let plist = service_darwin.renderUnitFile("/usr/local/bin/powarder")
    check "--config" notin plist

  test "EnvironmentVariables に PATH が含まれる（launchd は対話シェルの PATH を継承しないため）":
    let plist = service_darwin.renderUnitFile("/usr/local/bin/powarder")
    check "<key>EnvironmentVariables</key>" in plist
    let pathValue = extractPlistString(plist, "PATH")
    check pathValue.len > 0
    check "/usr/bin" in pathValue
    check "/opt/homebrew/bin" in pathValue

  test "StandardOutPath / StandardErrorPath は絶対パス（~ は展開されないため）":
    withEnv({envStateDir: "/tmp/pw-service-state"}, proc() =
      let plist = service_darwin.renderUnitFile("/usr/local/bin/powarder")
      let outPath = extractPlistString(plist, "StandardOutPath")
      let errPath = extractPlistString(plist, "StandardErrorPath")
      check outPath.len > 0
      check errPath.len > 0
      check outPath == daemonLogPath()
      check isAbsolute(outPath)
      check isAbsolute(errPath)
      check not outPath.startsWith("~"))

# ===========================================================================
# Linux: systemd unit の生成（service_linux.renderUnitFile）
# ===========================================================================

suite "service_linux: renderUnitFile":
  test "unitFilePath は ~/.config/systemd/user/powarder.service":
    check service_linux.unitFilePath() ==
        getHomeDir() / ".config" / "systemd" / "user" / "powarder.service"

  test "★最重要: Restart=on-failure が含まれ、Restart=always は含まれない":
    # これが `always` だと `powarder daemon stop`（exit 0）でも systemd が
    # すぐさま再起動してしまい、デーモンを止められなくなる。
    let unit = service_linux.renderUnitFile("/usr/local/bin/powarder")
    check "Restart=on-failure" in unit
    check "Restart=always" notin unit

  test "ExecStart / WantedBy=default.target を含む":
    let unit = service_linux.renderUnitFile("/usr/local/bin/powarder")
    check "ExecStart=/usr/local/bin/powarder daemon" in unit
    check "WantedBy=default.target" in unit
    check "[Unit]" in unit
    check "[Service]" in unit
    check "[Install]" in unit

  test "configPath を渡すと ExecStart に --config が追加される":
    let unit = service_linux.renderUnitFile("/usr/local/bin/powarder",
        "/home/x/.config/powarder/config.json")
    check "ExecStart=/usr/local/bin/powarder daemon --config " &
        "/home/x/.config/powarder/config.json" in unit

  test "RestartSec も設定されている":
    let unit = service_linux.renderUnitFile("/usr/local/bin/powarder")
    check "RestartSec=5" in unit

suite "service_linux: lingerNote":
  test "loginctl enable-linger の案内を含む":
    # `installService` / `serviceStatus` の `notes` に必ず含まれる文言。
    # 実際に systemctl を呼ばずにテストできるよう、純粋関数として分離してある。
    let note = lingerNote()
    check "loginctl" in note
    check "enable-linger" in note
