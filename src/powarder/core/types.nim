## powarder の全レイヤで共有する型定義。
##
## このモジュールは I/O を一切行わない。`std/asyncnet` / `std/osproc` / `std/os` を
## import しないことで、依存するロジックを副作用なしに単体テストできる状態を保つ
## （`std/json` は純粋なデータ変換なのでこの方針に反しない）。

import std/nativesockets
import std/json

export Port

proc `%`*(p: Port): JsonNode =
  ## `Port` は `distinct uint16` で、`std/json` は `distinct` 型向けの汎用 `%` を
  ## 持たない。これが無いと `ForwardSpec` のように `Port` を含むあらゆる型の
  ## `%` / `%*` がコンパイルエラーになる。
  ##
  ## **ここ（共有型の定義と同じ場所）に置くのが重要。** 以前は `ipc/protocol.nim` に
  ## 置いていたが、そうすると「JSON 化したいだけのモジュール」（例:
  ## `config/statefile.nim`）が `ipc/protocol` を import する必要が生じ、
  ## しかもこのオーバーロードは generic dispatch 経由でしか使われないため
  ## コンパイラが `imported and not used` と誤検知する（外すと実際には
  ## コンパイルエラーになるので、警告に従って外すと壊れるという厄介な状態だった）。
  ## 型と一緒に置けばその不整合が起きない。
  ##
  ## デコード方向は手当てが要らない（`std/json` の `initFromJson[T: distinct]` が
  ## `distinct` 型を自動的に処理するので `to()` はそのまま動く。実測確認済み）。
  % p.uint16.int

type
  ForwardKind* = enum ## ssh の -L / -R に対応する
    fkLocal = "L" ## powarder がローカルで listen し、ssh には UDS を張らせる
    fkRemote = "R" ## リモート側が listen する。powarder はデータパスに介在しない

  ForwardSpec* = object
    kind*: ForwardKind
    bindAddr*: string ## fkLocal: powarder が bind する / fkRemote: リモート側が bind する
    bindPort*: Port
    targetHost*: string
    targetPort*: Port

  RetryPolicy* = object
    maxConsecutiveFailures*: int ## 0 なら無制限にリトライする（既定）
    backoffMaxSeconds*: float

  TunnelConfig* = object
    name*: string
    host*: string ## ~/.ssh/config の Host エイリアス。接続経路・認証は ssh_config 側の責務
    spec*: ForwardSpec
    autostart*: bool
    profile*: string
    sshExtraArgs*: seq[string]
    retry*: RetryPolicy

  HostSessionKey* = object
    ## マスター接続の同一性。`host` 名ではなく `ssh -G` の解決結果から導出した
    ## fingerprint を含めることで、「host の変更」と「sshExtraArgs の変更」が
    ## どちらも単なる Add/Remove に落ちる。
    host*: string ## 表示用
    fingerprint*: string ## sshgparse.fingerprint() の結果

  HostSessionState* = enum
    hsIdle, hsConnecting, hsConnected, hsReconnecting, hsStopping, hsStopped, hsFailed

  ForwardState* = enum
    fwPending,   ## マスター未接続、または attach 待ち
    fwAttaching, ## -O forward 実行中
    fwActive,    ## 張れている
    fwDegraded,  ## ヘルスチェックが連続失敗している（attach 自体は維持）
    fwDetaching, ## -O cancel 実行中
    fwError      ## 自動再試行を止めた状態

  UpstreamKind* = enum
    ukUnix, ## ssh に UDS を張らせる（既定）
    ukTcp   ## UDS が使えない環境向けのフォールバック

  UpstreamTarget* = object
    case kind*: UpstreamKind
    of ukUnix:
      path*: string
    of ukTcp:
      port*: Port

const
  defaultBindAddr* = "127.0.0.1"
    ## bind_address 省略時の既定。OpenSSH の -L / -R の挙動（GatewayPorts no）と一致させ、
    ## 「powarder が ssh より緩い」という事故を構造的に防ぐ。

  defaultBackoffMaxSeconds* = 30.0
  defaultMaxConns* = 100 ## 1 フォワードあたりの同時接続数上限

func initRetryPolicy*(maxConsecutiveFailures = 0;
                      backoffMaxSeconds = defaultBackoffMaxSeconds): RetryPolicy =
  RetryPolicy(maxConsecutiveFailures: maxConsecutiveFailures,
              backoffMaxSeconds: backoffMaxSeconds)

func isLocal*(spec: ForwardSpec): bool {.inline.} = spec.kind == fkLocal
func isRemote*(spec: ForwardSpec): bool {.inline.} = spec.kind == fkRemote

func exposesExternally*(spec: ForwardSpec): bool =
  ## リスナーがループバック以外にバインドされ、外部から到達可能になるか。
  ## true のときは警告を出す。
  spec.bindAddr notin ["127.0.0.1", "localhost", "::1", "[::1]"]

func `==`*(a, b: UpstreamTarget): bool =
  ## `UpstreamTarget` は case を含む variant object で、コンパイラが自動生成する `==` は
  ## variant object に対応していない
  ## （"parallel 'fields' iterator does not work for 'case' objects"）ため手書きする。
  if a.kind != b.kind: return false
  case a.kind
  of ukUnix: a.path == b.path
  of ukTcp: a.port == b.port
