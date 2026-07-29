## デーモンが持つ「今の状態」の集合管理層。
##
## `HostSession`（マスター）と `Forward`（個々のポートフォワード）の実体を
## `Table` で保持し、それらのライフサイクル関数（`hostsession.tick` /
## `forward.tick` など）を正しい順序で呼び出す薄いコンテナ。
##
## **状態遷移の判断はここでは行わない。** それは `hostsession` / `forward` /
## `core/statemachine` の責務。ここは「どの `HostSession` / `Forward` が
## 存在するか」「それらをどの順序で駆動するか」だけを扱う。
##
## **`同じ host を指す複数のトンネルが1つのマスターを共有する」という
## powarder の設計の核心は `getOrCreateHost` で実現する。**

import std/tables

import powarder/core/types
import powarder/core/forwardspec
import powarder/daemon/hostsession
import powarder/daemon/forward

type
  Registry* = ref object
    hosts*: Table[string, HostSession] ## キーは hostKeyString(key)
    forwards*: Table[string, Forward]  ## キーは Forward.id
    enabledOverride*: Table[string, bool]
      ## トンネル名 → 有効/無効（`powarder start` / `stop` の意図）。
      ##
      ## `powarder start` / `stop` は**設定ファイルを書き換えない**。
      ## デーモン内メモリのオーバーレイ層として持つ（`systemctl` の
      ## enabled と active が別概念なのと同じ発想）。設定ファイルが指定する
      ## `autostart` の上に、実行時の start/stop 意図をこの Table で被せる。
      ## これにより「`stop` した後に無関係な設定変更で `reload` したら
      ## 勝手に再開する」事故を、reconcile 側の特別扱い無しに防げる
      ## （reconcile は `isEnabled` を見るだけで、`autostart` を直接見ない）。
    hostKeyCache: Table[string, HostSessionKey]
      ## `getOrCreateHost` が `ssh -G` の再実行を省略するための内部専用
      ## キャッシュ。公開型定義には無い（doc comment は `getOrCreateHost`
      ## 側を参照）。

# ---------------------------------------------------------------------------
# キー文字列化
# ---------------------------------------------------------------------------

proc hostKeyString*(key: HostSessionKey): string =
  ## `HostSessionKey` を `Table` のキーにするための文字列化。
  ##
  ## `HostSessionKey` はただの object で `==` は自動生成されるが、
  ## `Table[HostSessionKey, HostSession]` のキーとして直接使うには
  ## `std/hashes.hash(HostSessionKey)` の定義が別途必要になる
  ## （`core/types.nim` にはまだ無く、このモジュールはそれを変更できない
  ## 制約がある）。`hash` を自分でここに書き足すこともできるが、
  ## `HostSessionKey` は `host` と `fingerprint` という2つの文字列だけの
  ## 単純な object なので、素直に「決定的な文字列」へ落として `Table[string, _]`
  ## にする方が余計な型クラス実装を増やさずに済む。`@` は `host` にも
  ## `fingerprint`（16進文字列）にも出現しない区切り文字なので衝突しない。
  key.host & "@" & key.fingerprint

proc hostArgsCacheKey(host: string; extraArgs: seq[string]): string =
  ## `getOrCreateHost` のキャッシュキー。`host` と `extraArgs` の組をそのまま
  ## 文字列化する（`\x1F`（ASCII unit separator）区切り。ホスト名や引数に
  ## 通常出現しない制御文字なので区切りとして安全）。
  result = host
  for a in extraArgs:
    result.add('\x1F')
    result.add(a)

# ---------------------------------------------------------------------------
# 生成
# ---------------------------------------------------------------------------

proc newRegistry*(): Registry =
  Registry(
    hosts: initTable[string, HostSession](),
    forwards: initTable[string, Forward](),
    enabledOverride: initTable[string, bool](),
    hostKeyCache: initTable[string, HostSessionKey](),
  )

# ---------------------------------------------------------------------------
# ホスト
# ---------------------------------------------------------------------------

proc getOrCreateHost*(reg: Registry; host: string;
    extraArgs: seq[string] = @[]): HostSession =
  ## 「同じ host を指す複数のトンネルが1つのマスターを共有する」を実現する
  ## 箇所。`newHostSession(host, extraArgs)` で fingerprint 込みの
  ## `HostSessionKey` を計算し、既に同じ key のホストが登録済みならそれを
  ## 返す。無ければ登録して返す。
  ##
  ## **`ssh -G` の再実行を避ける工夫**: `newHostSession` は呼ばれるたびに
  ## 内部で `ssh -G` を実行して fingerprint を計算し直す。reconcile は
  ## 「同じ host を共有する複数トンネル」を1回ずつこの関数に通すため、
  ## 何もしないと同じホストに対して `ssh -G` が何度も無駄に実行されてしまう
  ## （reconcile が周期的に呼ばれる運用ではなおさら）。
  ##
  ## そこで `(host, extraArgs)` の組を `hostKeyCache` に憶えておき、
  ## 2回目以降の呼び出しはそこから直接 `HostSessionKey` を引いて
  ## `reg.hosts` を引き直すだけにし、`newHostSession`（＝`ssh -G`）を
  ## 一切呼ばない経路にした。
  ##
  ## **この最適化が「host の変更」「sshExtraArgs の変更」を Add/Remove に
  ## 落とす性質を壊さない理由**: キャッシュのキーが `(host, extraArgs)` の
  ## 組そのものなので、どちらかが変われば別のキャッシュキーになり、
  ## 素直に `ssh -G` を再実行して新しい fingerprint を得る（キャッシュヒット
  ## しない）。**唯一キャッシュが見逃すのは「host も extraArgs も変わって
  ## いないのに `~/.ssh/config` 自体がデーモン起動中に書き換わった」という
  ## 稀なケース**で、この場合はデーモンを再起動するまで反映されない。
  ## ホストは一度登録されたら `Registry` から削除されない設計
  ## （`teardownAll` を除く）なので、このケースを許容してもキャッシュと
  ## 実体がずれて壊れることはない。
  let cacheKey = hostArgsCacheKey(host, extraArgs)
  if cacheKey in reg.hostKeyCache:
    let hks = hostKeyString(reg.hostKeyCache[cacheKey])
    if hks in reg.hosts:
      return reg.hosts[hks]
    # キャッシュに残っているのに実体が無い（本来起きないはずだが、防御的に
    # 下のフォールバックへ進んで作り直す）。

  let candidate = newHostSession(host, extraArgs)
  let hks = hostKeyString(candidate.key)
  reg.hostKeyCache[cacheKey] = candidate.key
  if hks in reg.hosts:
    return reg.hosts[hks] ## 既存を優先し、作った candidate は捨てる
  reg.hosts[hks] = candidate
  candidate

proc adoptHost*(reg: Registry; hs: HostSession) =
  ## 孤児 adopt（M6。`daemon/orphan.adoptOrphans`）用。`getOrCreateHost` と
  ## 同じキー（`hostKeyString(hs.key)`）で `reg.hosts` に登録する。
  ##
  ## **`hostKeyCache` を明示的に温める必要は無い。** adopt 後に reconcile が
  ## 同じ `(host, extraArgs)` を要求すると `getOrCreateHost` はキャッシュ
  ## ミスで `newHostSession`（＝`ssh -G`）を1回実行するが、ssh_config が
  ## 変わっていなければ同じ fingerprint が得られ、`hks` 経由で `reg.hosts`
  ## からこの adopt 済みセッションをそのまま引き当てて再利用する
  ## （`getOrCreateHost` のフォールバック経路）。ssh_config が変わっていた
  ## 場合は新しいセッションが作られるが、それは「設定が変わったので繋ぎ
  ## 直す」という通常の Add/Remove ロジックが正しく機能した結果であり、
  ## 特別な後始末は不要（Add/Remove は元々そういう設計）。
  reg.hosts[hostKeyString(hs.key)] = hs

proc clearHostKeyCache*(reg: Registry) =
  ## `(host, extraArgs)` → fingerprint のキャッシュを破棄する。
  ##
  ## **`daemon.reload` から必ず呼ぶこと。** reload は「設定を読み直す」操作なので、
  ## `~/.ssh/config` の再評価もここで行うべきである。呼ばないと
  ## 「ssh_config を直して reload しても反映されない」という分かりにくい挙動になる
  ## （`getOrCreateHost` の doc comment で述べたキャッシュの唯一の穴がこれ）。
  ##
  ## 既存の `HostSession` / `Forward` は破棄しない。次回の `getOrCreateHost` が
  ## `ssh -G` を再実行し、fingerprint が変わっていれば新しい key のホストが立ち、
  ## 古いホストは参照カウントが 0 になって grace period 経過後に自分で停止する
  ## （Add/Remove の一般ロジックに乗るだけで、特別扱いは不要）。
  reg.hostKeyCache.clear()

# ---------------------------------------------------------------------------
# フォワード
# ---------------------------------------------------------------------------

proc addForward*(reg: Registry; tunnelName: string; spec: ForwardSpec;
    host: HostSession): Forward =
  ## `newForward` して registry に登録する。
  ##
  ## id の重複登録は状態を壊す（`host.addForwardRef` の二重カウントや、
  ## 既存 Forward を上書きして参照を見失う事故につながる）ため、
  ## `newForward` を呼ぶ**前**に `reg.forwards` を確認して防御する
  ## （設定の検証で同じ bind アドレス/ポートの衝突は防がれているはずだが、
  ## 万一に備える）。
  let id = forwardId(spec, host.host)
  if id in reg.forwards:
    raise newException(ValueError, "forward id はすでに登録されています: " & id)
  result = newForward(tunnelName, spec, host)
  reg.forwards[id] = result

proc adoptForward*(reg: Registry; fw: Forward) =
  ## 孤児 adopt（M6。`daemon/orphan.adoptOrphans`）用。呼び出し側が既に
  ## `daemon/forward.adoptForward` で組み立て済みの `Forward`（`fwActive`。
  ## UDS が生きていることを確認済み）をそのまま登録するだけで、`newForward`
  ## は呼ばない（呼ぶと参照カウントを二重に増やしてしまう）。
  ## `addForward` と同じ理由で id の重複を防御する。
  if fw.id in reg.forwards:
    raise newException(ValueError, "forward id はすでに登録されています: " & fw.id)
  reg.forwards[fw.id] = fw

proc removeForward*(reg: Registry; id: string) =
  ## fwDetaching を経て破棄可能になった Forward を Table から取り除く。
  ## `id` が存在しなくても（`Table.del` は無いキーに対して no-op なので）
  ## 安全に呼べる。
  reg.forwards.del(id)

proc forwardsOf*(reg: Registry; hostKey: string): seq[Forward] =
  result = @[]
  for fw in reg.forwards.values:
    if hostKeyString(fw.host.key) == hostKey:
      result.add(fw)

proc forwardsOfTunnel*(reg: Registry; tunnelName: string): seq[Forward] =
  result = @[]
  for fw in reg.forwards.values:
    if fw.tunnelName == tunnelName:
      result.add(fw)

# ---------------------------------------------------------------------------
# start/stop オーバーレイ
# ---------------------------------------------------------------------------

proc isEnabled*(reg: Registry; tunnelName: string; autostart: bool): bool =
  ## `enabledOverride` にエントリがあればそれを、無ければ `autostart`
  ## （設定ファイルの値）を返す。
  reg.enabledOverride.getOrDefault(tunnelName, autostart)

proc setEnabled*(reg: Registry; tunnelName: string; enabled: bool) =
  reg.enabledOverride[tunnelName] = enabled

proc clearEnabledOverride*(reg: Registry; tunnelName: string) =
  reg.enabledOverride.del(tunnelName)

proc pruneOverrides*(reg: Registry; knownTunnelNames: openArray[string]) =
  ## 設定ファイルから完全に消えたトンネル名の override をガベージコレクトする。
  var stale: seq[string] = @[]
  for name in reg.enabledOverride.keys:
    if name notin knownTunnelNames:
      stale.add(name)
  for name in stale:
    reg.enabledOverride.del(name)

# ---------------------------------------------------------------------------
# 駆動
# ---------------------------------------------------------------------------

proc tickAll*(reg: Registry) =
  ## デーモンの 500ms ループから呼ばれる。
  ##
  ## 順序が重要:
  ## 1. 全 `HostSession` の `tick`（マスターの状態を先に進める）
  ## 2. 全 `Forward` の `tick`（ホストの状態を前提に判断するので後）
  ## 3. `isDiscardable` な `Forward` を Table から除去する
  ##
  ## 3 を 2 のループの中で直接やらない理由: `Table` の値をイテレート中に
  ## 同じ `Table` から要素を削除すると、Nim の `Table` イテレータは
  ## 壊れる（未定義動作・要素の飛ばし）。そのため、まず削除対象の id だけを
  ## 別の `seq` に集めておき、イテレーションが終わった後にまとめて
  ## `del` する（`std/tables` の一般的な安全パターン）。
  for hs in reg.hosts.values:
    hostsession.tick(hs)

  for fw in reg.forwards.values:
    forward.tick(fw)

  var discardable: seq[string] = @[]
  for id, fw in reg.forwards:
    if forward.isDiscardable(fw):
      discardable.add(id)
  for id in discardable:
    reg.forwards.del(id)

proc teardownAll*(reg: Registry) =
  ## graceful shutdown 用。
  ##
  ## **Forward を先に、HostSession を後に** teardown する（forward が
  ## 参照カウントを減らしてからマスターを落とす順序。逆順だと
  ## `forward.teardown` が `fw.host.removeForwardRef` を呼ぶ相手の
  ## マスターが既に落ちていることになり、また `fw.host` 経由で
  ## `ctlPath` / `host` を使う `cancelForward` 呼び出しが意味を失う）。
  ##
  ## 呼び出し後は `reg.forwards` / `reg.hosts` を空にする
  ## （プロセス自体が終了する前提の完全な後始末なので、Table に残す理由が
  ## 無い。テストからは「残骸が無いこと」を Table が空であることでも
  ## 確認できるようにする）。
  for fw in reg.forwards.values:
    forward.teardown(fw)
  reg.forwards.clear()

  for hs in reg.hosts.values:
    hostsession.teardown(hs)
  reg.hosts.clear()
