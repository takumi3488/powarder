## macOS (launchd) 向けの OS サービス登録実装。
##
## `~/Library/LaunchAgents/dev.powarder.daemon.plist` を生成し、
## `launchctl bootstrap` / `bootout` で登録・解除する。
##
## ### ★最重要: `KeepAlive.SuccessfulExit = false`
##
## launchd の `KeepAlive` は、`true` のような単純な値だと「exit コードに
## 関わらず常に再起動する」挙動になる。これだと `powarder daemon stop`
## （= プロセスが exit 0 で終了する）が即座に launchd に再起動されてしまい、
## デーモンを止められなくなる重大なバグになる。クラッシュ（exit != 0）の
## ときだけ再起動してほしいので、`<dict><key>SuccessfulExit</key><false/></dict>`
## という辞書形式で「正常終了時は keep-alive しない」ことを明示する。
##
## launchd は対話シェルの環境（`PATH` / `SSH_AUTH_SOCK` 等）を継承しない。
## `EnvironmentVariables` に最低限の `PATH` を書いておかないと powarder が
## `ssh` を発見できない。`SSH_AUTH_SOCK` は launchd 経由では原理的に
## 解決できない（ユーザーのログインセッションの ssh-agent に依存するため）ので、
## こちらは README のトラブルシュートで案内するに留める（Keychain 統合の
## `UseKeychain yes` を使えば回避できる）。
##
## `renderUnitFile` はファイルにもソケットにも触らない **純粋関数**。
## `installService` / `uninstallService` / `serviceStatus` だけが実際に
## `launchctl` を呼ぶ（`tests/tservice.nim` はここを一切呼ばない。
## ユーザーの実環境を汚すため）。

import std/[os, osproc, strutils, posix]
import powarder/platform/service_types
import powarder/core/paths

const
  launchdPath = "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin"
    ## launchd は対話シェルの PATH を継承しないため、最低限の候補を明示する。

proc escapeXml(s: string): string =
  ## plist は XML なので `&` `<` `>` を含みうるパスをそのまま埋め込むと壊れる。
  s.multiReplace(("&", "&amp;"), ("<", "&lt;"), (">", "&gt;"))

proc unitFilePath*(): string =
  getHomeDir() / "Library" / "LaunchAgents" / (serviceLabel() & ".plist")

proc programArguments(exePath, configPath: string): seq[string] =
  ## `powarder <exePath> daemon [--config <configPath>]` に対応する
  ## `ProgramArguments` の要素列。
  result = @[exePath, "daemon"]
  if configPath.len > 0:
    result.add "--config"
    result.add configPath

proc renderUnitFile*(exePath: string; configPath = ""): string =
  ## plist の中身を組み立てる。`daemonLogPath()` は絶対パスを返す
  ## （plist の `StandardOutPath` は `~` を展開してくれないため、
  ## 呼び出し側で絶対パスを解決しておく必要がある）。
  let logPath = daemonLogPath()
  var s = ""
  s.add "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
  s.add "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" "
  s.add "\"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
  s.add "<plist version=\"1.0\">\n"
  s.add "<dict>\n"
  s.add "  <key>Label</key><string>"
  s.add escapeXml(serviceLabel())
  s.add "</string>\n"
  s.add "  <key>ProgramArguments</key>\n"
  s.add "  <array>\n"
  for a in programArguments(exePath, configPath):
    s.add "    <string>"
    s.add escapeXml(a)
    s.add "</string>\n"
  s.add "  </array>\n"
  s.add "  <key>RunAtLoad</key><true/>\n"
  s.add "  <key>KeepAlive</key>\n"
  s.add "  <dict><key>SuccessfulExit</key><false/></dict>\n"
  s.add "  <key>StandardOutPath</key><string>"
  s.add escapeXml(logPath)
  s.add "</string>\n"
  s.add "  <key>StandardErrorPath</key><string>"
  s.add escapeXml(logPath)
  s.add "</string>\n"
  s.add "  <key>EnvironmentVariables</key>\n"
  s.add "  <dict>\n"
  s.add "    <key>PATH</key><string>"
  s.add launchdPath
  s.add "</string>\n"
  s.add "  </dict>\n"
  s.add "</dict>\n"
  s.add "</plist>\n"
  s

# ---------------------------------------------------------------------------
# launchctl の実行（side effect あり。テストでは呼ばない）
# ---------------------------------------------------------------------------

proc guiDomain(): string =
  "gui/" & $getuid()

proc runLaunchctl(args: varargs[string]): tuple[output: string; exitCode: int] =
  try:
    execCmdEx("launchctl " & args.join(" "))
  except OSError as e:
    (e.msg, -1)

proc serviceStatus*(): ServiceInfo =
  ## plist ファイルの有無と `launchctl print` の成否から状態を判定する。
  let path = unitFilePath()
  if not fileExists(path):
    return ServiceInfo(label: serviceLabel(), unitPath: path,
        status: ssNotInstalled, notes: @[])
  let (_, code) = runLaunchctl("print", guiDomain() & "/" & serviceLabel())
  let status = if code == 0: ssRunning else: ssInstalled
  ServiceInfo(label: serviceLabel(), unitPath: path, status: status, notes: @[])

proc installService*(exePath: string; configPath = ""): ServiceInfo =
  ## plist を書き出し、`launchctl bootstrap` で登録する。
  ## `bootstrap`（新しい API）が失敗する環境向けに、古い `launchctl load` へ
  ## フォールバックする。
  let path = unitFilePath()
  createDir(path.parentDir)
  writeFile(path, renderUnitFile(exePath, configPath))

  let domain = guiDomain()
  var (outp, code) = runLaunchctl("bootstrap", domain, quoteShell(path))
  if code != 0:
    (outp, code) = runLaunchctl("load", quoteShell(path))

  result = serviceStatus()
  if code != 0:
    result.notes.add "launchctl での登録に失敗した可能性があります: " &
        outp.strip()

proc uninstallService*(): ServiceInfo =
  ## `launchctl bootout` で解除してから plist ファイルを削除する。
  let path = unitFilePath()
  discard runLaunchctl("bootout", guiDomain() & "/" & serviceLabel())
  if fileExists(path):
    removeFile(path)
  ServiceInfo(label: serviceLabel(), unitPath: path, status: ssNotInstalled,
      notes: @[])
