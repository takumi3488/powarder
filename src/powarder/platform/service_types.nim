## `platform/service*` 群が共有する型・定数・純粋ヘルパのみを集めたモジュール。
##
## ### なぜこのモジュールが存在するか（循環 import の解消）
##
## 以前は `service.nim` がこれらの型を直接持ち、`service_darwin` /
## `service_linux` がその型を使うために `service.nim` を import する一方、
## `service.nim` 自身も OS 判定で `service_darwin` / `service_linux` を
## import していた（= 3モジュールの相互 import）。
##
## Nim はこの手の循環 import を許容するが、**どのモジュールを最初に
## コンパイルするか（エントリモジュール）によって結果が変わる**という
## 罠がある。`service_darwin` / `service_linux` を先に import したり、
## それらを単独でルートモジュールとしてコンパイルすると、Nim は循環を
## 「部分的にコンパイルされた空のモジュール」として解決してしまい、
## "undeclared identifier" で失敗する。
##
## そこで型・定数・純粋ヘルパをこの `service_types` に切り出し、
## 依存の向きを
##
##   service_types  ←  service_darwin / service_linux  ←  service
##
## という一方向にした。`service_types` は他の `powarder/platform/service*`
## を一切 import しない（`std/*` のみ）ので、ここを起点に何をどの順番で
## import しても循環は発生しない。
##
## ★このモジュールに手を入れる人へ: **型やヘルパを `service.nim` 側に
## 戻すと、この一方向の依存構造が壊れて循環 import が復活する。**
## 新しい型・定数・純粋ヘルパを追加する場合は、`service_darwin` /
## `service_linux` の双方から必要とされるものだけをここに置くこと。

type
  ServiceStatus* = enum
    ssNotInstalled ## unit/plist ファイルが無い
    ssInstalled    ## 登録されているが起動していない
    ssRunning      ## 登録されていて起動中
    ssUnknown      ## launchctl / systemctl の問い合わせ自体に失敗した

  ServiceInfo* = object
    label*: string    ## "dev.powarder.daemon"
    unitPath*: string ## plist / unit ファイルのパス
    status*: ServiceStatus
    notes*: seq[string] ## ユーザーへの案内（loginctl enable-linger など）

const
  commonServiceLabel = "dev.powarder.daemon"

proc serviceLabel*(): string =
  ## OS に依らず同じラベル文字列。macOS の plist `Label` キーや、案内メッセージ中の
  ## 識別子として使う（systemd 側は unit ファイル名自体は `powarder.service` に
  ## なるが、`Label` に相当する概念としてこの文字列を流用する）。
  commonServiceLabel
