## OS サービスとしての常駐登録（共通インタフェース）。
##
## `powarder daemon install` / `uninstall` から呼ばれる。macOS (launchd) /
## Linux (systemd --user) それぞれの実際の登録処理は `platform/service_darwin` /
## `platform/service_linux` に分離してあり、このモジュール自身は
## - 共通の型（`ServiceStatus` / `ServiceInfo`）や `serviceLabel` を
##   `platform/service_types` から import して再 export する
## - OS 判定（`when defined(macosx)` / `when defined(linux)`）による振り分け
## だけを持つ。
##
## ### ★最重要の設計判断
##
## 「exit 0 では再起動せず、クラッシュ時のみ再起動する」のが正しい挙動。
## - macOS: launchd の `KeepAlive` を `SuccessfulExit = false` にする
## - Linux: systemd の `Restart=on-failure`（**`always` ではない**）
##
## これを取り違えると、`powarder daemon stop`（= プロセスが exit 0 で終了する）
## が即座に再起動されて止まらなくなる、あるいは逆にクラッシュしても
## 復旧しなくなる。`tests/tservice.nim` で明示的に検証している。
##
## `renderUnitFile` は **純粋関数** にしてある（ファイル I/O・`launchctl` /
## `systemctl` の実行を一切行わない）。テストは実環境（実際の launchd /
## systemd 登録）を汚さないよう、生成される文字列だけを検証する方針にする。
##
## ### 依存の向き（循環 import の解消）
##
## 以前は `service_darwin` / `service_linux` がこのモジュールを import して
## 型を得る一方、このモジュールも OS 判定でその2つを import しており、
## 3モジュールが相互 import する構成だった。Nim はこの手の循環を許容するが、
## `service_darwin` / `service_linux` を先に import したり単独でルート
## モジュールとしてコンパイルすると「部分的にコンパイルされた空の
## モジュール」に解決されてしまい undeclared identifier で失敗する罠がある。
##
## そこで型・定数・`serviceLabel` を `platform/service_types` に切り出した。
## 依存は `service_types` ← `service_darwin` / `service_linux` ← `service`
## という一方向になり、循環は発生しない。`export service_types` により、
## 既存の利用側（`cli/dispatch.nim` など）は
## `import powarder/platform/service` だけで `ServiceInfo` 等を
## そのまま使い続けられる。
##
## 非対応 OS（macOS でも Linux でもない）では、黙って何もしないのではなく
## `OSError` を送出して明示的に失敗する。

import powarder/platform/service_types
export service_types

when defined(macosx):
  import powarder/platform/service_darwin as impl
elif defined(linux):
  import powarder/platform/service_linux as impl

when defined(macosx) or defined(linux):
  proc unitFilePath*(): string =
    ## plist / unit ファイルのパス。
    impl.unitFilePath()

  proc renderUnitFile*(exePath: string; configPath = ""): string =
    ## plist / unit ファイルの中身を生成する。**純粋関数**（テストのため）。
    impl.renderUnitFile(exePath, configPath)

  proc installService*(exePath: string; configPath = ""): ServiceInfo =
    ## unit ファイルを書き出し、`launchctl` / `systemctl` で実際に登録する。
    impl.installService(exePath, configPath)

  proc uninstallService*(): ServiceInfo =
    ## 登録を解除し、unit ファイルを削除する。
    impl.uninstallService()

  proc serviceStatus*(): ServiceInfo =
    ## 現在の登録状態を問い合わせる。
    impl.serviceStatus()
else:
  proc unsupportedOsMsg(): string =
    "powarder daemon install/uninstall はこの OS では未対応です " &
      "(サポートしているのは macOS の launchd と Linux の systemd --user のみです)"

  proc unitFilePath*(): string =
    raise newException(OSError, unsupportedOsMsg())

  proc renderUnitFile*(exePath: string; configPath = ""): string =
    raise newException(OSError, unsupportedOsMsg())

  proc installService*(exePath: string; configPath = ""): ServiceInfo =
    raise newException(OSError, unsupportedOsMsg())

  proc uninstallService*(): ServiceInfo =
    raise newException(OSError, unsupportedOsMsg())

  proc serviceStatus*(): ServiceInfo =
    raise newException(OSError, unsupportedOsMsg())
