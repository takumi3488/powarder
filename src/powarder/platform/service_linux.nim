## Linux (systemd --user) 向けの OS サービス登録実装。
##
## `~/.config/systemd/user/powarder.service` を生成し、
## `systemctl --user enable --now` / `disable --now` で登録・解除する。
##
## ### ★最重要: `Restart=on-failure`（`Restart=always` ではない）
##
## `Restart=always` にすると、`powarder daemon stop`（= プロセスが exit 0 で
## 終了する）でも systemd がすぐさま再起動してしまい、デーモンを止められなくなる
## 重大なバグになる。クラッシュ（exit != 0）のときだけ再起動してほしいので
## `on-failure` を使う。
##
## ### loginctl enable-linger
##
## `systemctl --user` はユーザーのログインセッションに紐付く user manager が
## 動いている間しか有効ではない。`loginctl enable-linger $USER` を実行して
## いないと、ログアウト時に user manager 自体が終了し、デーモンごとトンネルが
## 切れてしまう。これは致命的に気付きにくい落とし穴なので、`installService` /
## `serviceStatus` が返す `ServiceInfo.notes` に必ず案内を含める
## （`lingerNote()` で文言を組み立てる。テストはこの純粋関数を直接呼んで検証する）。
##
## `renderUnitFile` はファイルにもソケットにも触らない **純粋関数**。
## `installService` / `uninstallService` / `serviceStatus` だけが実際に
## `systemctl` を呼ぶ（`tests/tservice.nim` はここを一切呼ばない。
## ユーザーの実環境を汚すため）。

import std/[os, osproc, strutils]
import powarder/platform/service_types

const
  unitBasename = "powarder.service"

proc unitFilePath*(): string =
  getHomeDir() / ".config" / "systemd" / "user" / unitBasename

proc execStartLine(exePath, configPath: string): string =
  ## `ExecStart=` の値。systemd の単純なコマンドライン展開（空白区切り）を
  ## 前提にしている点は plist の `ProgramArguments`（配列）ほど厳密ではないが、
  ## 仕様で示された形式（1行の `ExecStart=`）に合わせる。
  var s = exePath
  s.add " daemon"
  if configPath.len > 0:
    s.add " --config "
    s.add configPath
  s

proc renderUnitFile*(exePath: string; configPath = ""): string =
  var s = ""
  s.add "[Unit]\n"
  s.add "Description=powarder — SSH port forward manager\n"
  s.add "After=network-online.target\n"
  s.add "\n"
  s.add "[Service]\n"
  s.add "Type=simple\n"
  s.add "ExecStart="
  s.add execStartLine(exePath, configPath)
  s.add "\n"
  s.add "Restart=on-failure\n"
  s.add "RestartSec=5\n"
  s.add "\n"
  s.add "[Install]\n"
  s.add "WantedBy=default.target\n"
  s

proc lingerNote*(): string =
  ## `loginctl enable-linger` の案内。純粋関数にして、実際に `systemctl` を
  ## 呼ばずにテストできるようにしてある。
  "ログアウト後もデーモンを動かし続けるには " &
    "`loginctl enable-linger $USER` を実行してください " &
    "（実行していないとログアウト時に systemd user manager ごと停止し、" &
    "トンネルが切れます）"

# ---------------------------------------------------------------------------
# systemctl の実行（side effect あり。テストでは呼ばない）
# ---------------------------------------------------------------------------

proc runSystemctl(args: varargs[string]): tuple[output: string; exitCode: int] =
  try:
    execCmdEx("systemctl --user " & args.join(" "))
  except OSError as e:
    (e.msg, -1)

proc serviceStatus*(): ServiceInfo =
  ## unit ファイルの有無と `systemctl --user is-active` の結果から状態を判定する。
  let path = unitFilePath()
  if not fileExists(path):
    return ServiceInfo(label: serviceLabel(), unitPath: path,
        status: ssNotInstalled, notes: @[lingerNote()])
  let (outp, code) = runSystemctl("is-active", unitBasename)
  let status =
    if code == 0 and outp.strip() == "active": ssRunning
    else: ssInstalled
  ServiceInfo(label: serviceLabel(), unitPath: path, status: status,
      notes: @[lingerNote()])

proc installService*(exePath: string; configPath = ""): ServiceInfo =
  ## unit ファイルを書き出し、`daemon-reload` してから `enable --now` する。
  let path = unitFilePath()
  createDir(path.parentDir)
  writeFile(path, renderUnitFile(exePath, configPath))

  discard runSystemctl("daemon-reload")
  let (outp, code) = runSystemctl("enable", "--now", unitBasename)

  result = serviceStatus()
  if code != 0:
    result.notes.add "systemctl での登録に失敗した可能性があります: " &
        outp.strip()

proc uninstallService*(): ServiceInfo =
  ## `disable --now` してから unit ファイルを削除し、`daemon-reload` する。
  discard runSystemctl("disable", "--now", unitBasename)
  let path = unitFilePath()
  if fileExists(path):
    removeFile(path)
  discard runSystemctl("daemon-reload")
  ServiceInfo(label: serviceLabel(), unitPath: path, status: ssNotInstalled,
      notes: @[lingerNote()])
