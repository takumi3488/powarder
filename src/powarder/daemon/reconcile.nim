## level-triggered な収束ループ。
##
## Kubernetes 的な「望ましい状態」対「今の状態」の突き合わせという発想は
## 採るが、informer / workqueue / 複数コントローラのようなフル構成には
## しない（数十ホスト・数百フォワード規模ではオーバーエンジニアリング）。
## 単一の `reconcile()` 関数が、呼ばれるたびに desired と `Registry` の
## 現状を突き合わせて必要な差分だけを適用する。
##
## **冪等性が最重要の性質。** 同じ `DesiredState` で連続して呼んでも、
## 2回目以降は何も変えない（差分が無いので `actions` が空になる）。
## これにより「デーモンが定期的に、あるいは設定変更のたびに何度
## `reconcile` を呼んでも安全」という性質が成り立つ。

import std/tables
import std/nativesockets ## `ForwardSpec` の自動生成 `==` が内部で `Port` の
                          ## `==` を使うために必要（`core/forwardspec.nim` と
                          ## 同じ理由。`types.nim` は `export Port` で型のみ
                          ## 再輸出しているため、比較演算子は別途 import が要る）。

import powarder/core/types
import powarder/core/forwardspec
import powarder/daemon/registry
import powarder/daemon/forward

type
  DesiredState* = object
    tunnels*: seq[TunnelConfig]
      ## 設定ファイルから読んだ望ましい状態。`enabledOverride`（start/stop の
      ## 意図）は `Registry` 側が持つのでここには含めない。
    activeProfiles*: seq[string]
      ## 空なら「profile を持たないトンネルのみ」を対象にする
      ## （docker compose の profiles 準拠）。指定があればそのプロファイルに
      ## 属するトンネルも対象に含める。

  ReconcileAction* = enum
    raCreateHost, raCreateForward, raDetachForward, raRemoveForward,
    raEnableForward, raDisableForward

  ReconcileReport* = object
    actions*: seq[tuple[action: ReconcileAction, target: string]]
    warnings*: seq[string]

# ---------------------------------------------------------------------------
# profile フィルタ
# ---------------------------------------------------------------------------

proc isTargeted*(tc: TunnelConfig; activeProfiles: openArray[string]): bool =
  ## `tc.profile` が空なら常に対象。空でなければ `activeProfiles` に
  ## 含まれるときだけ対象。
  if tc.profile.len == 0:
    true
  else:
    tc.profile in activeProfiles

# ---------------------------------------------------------------------------
# reconcile 本体
# ---------------------------------------------------------------------------

proc reconcile*(desired: DesiredState; reg: Registry): ReconcileReport =
  ## desired と `reg` の現状を突き合わせて差分を適用する。
  ##
  ## 手順:
  ## 0. 既に破棄可能（`isDiscardable`）な `Forward` があれば registry から
  ##    回収する。本来は `registry.tickAll` が毎ループ行う後始末だが、
  ##    `reconcile` 単独で呼ばれる状況（設定 reload 直後など）でも
  ##    取りこぼさないよう、ここでも行っておく（`removeForward` は
  ##    冪等なので二重に行っても害は無い）。
  ## 1. reconcileHosts: desired に必要なホストを `getOrCreateHost` で用意する。
  ## 2. reconcileForwards: 作成 / detach の要否を判定して適用する。
  ## 3. `pruneOverrides` で設定から消えたトンネル名の override を掃除する。
  ##
  ## **ホストの削除は明示的に行わない。** `Forward` が detach されると
  ## 参照カウントが 0 になり、`HostSession` 自身が grace period 経過後に
  ## 自分で `hsStopping` へ落ちる（`hostsession.tick` の責務）。この
  ## 「参照カウントによる自動停止」に任せる設計であり、`reconcile` /
  ## `registry` の側から能動的に `reg.hosts` から取り除く操作は無い
  ## （`teardownAll` によるプロセス全体の終了時を除く）。
  result = ReconcileReport(actions: @[], warnings: @[])

  # --- 手順0: 既に破棄可能な Forward を回収する -----------------------------
  var alreadyDiscardable: seq[string] = @[]
  for id, fw in reg.forwards:
    if forward.isDiscardable(fw):
      alreadyDiscardable.add(id)
  for id in alreadyDiscardable:
    removeForward(reg, id)
    result.actions.add((raRemoveForward, id))

  # --- 手順1: reconcileHosts -------------------------------------------------
  # desired にあるトンネルのうち、対象（profile 一致）かつ有効
  # （isEnabled）なものだけがホストを必要とする。無効化されたトンネルしか
  # 無いホストのために新規にマスターを起動する必要は無い。
  for tc in desired.tunnels:
    if not isTargeted(tc, desired.activeProfiles):
      continue
    if not isEnabled(reg, tc.name, tc.autostart):
      continue
    let before = reg.hosts.len
    discard getOrCreateHost(reg, tc.host, tc.sshExtraArgs)
    if reg.hosts.len > before:
      result.actions.add((raCreateHost, tc.host))

  # --- 手順2: reconcileForwards ----------------------------------------------
  # Pass A: desired.tunnels を基準にループし、各トンネルの id が
  # registry に存在するか・spec が一致するか・有効かを見て差分を適用する。
  var tunnelsByName = initTable[string, TunnelConfig]()
  for tc in desired.tunnels:
    tunnelsByName[tc.name] = tc

  for tc in desired.tunnels:
    let id = forwardId(tc.spec, tc.host)
    let targeted = isTargeted(tc, desired.activeProfiles)
    let enabled = isEnabled(reg, tc.name, tc.autostart)
    let shouldExist = targeted and enabled

    if id in reg.forwards:
      let existing = reg.forwards[id]
      if existing.tunnelName != tc.name:
        # 別のトンネルが既にこの id（bindAddr:bindPort など、実体からの
        # 決定的な導出）を使っている。設定ミス（ローカルポート衝突など）で
        # あり、通常は設定の検証層で防がれているはずだが、万一起きた場合に
        # どちらの持ち物として扱うべきかは決め打ちできないため、既存を
        # 尊重してこの `tc` からは手を出さず警告だけ残す。
        result.warnings.add("forward id " & id & " はすでにトンネル '" &
            existing.tunnelName & "' が使用しています。トンネル '" &
            tc.name &
            "' は同じ bind アドレス/ポートを指定できません")
        continue

      if shouldExist:
        if existing.spec != tc.spec:
          # id は同じだが転送先（targetHost/targetPort など）が変わった。
          # Forward.id は bind 側の実体だけから決まるため、転送先の変更では
          # id が変わらない。同じ Forward オブジェクトの spec を書き換える
          # 手段は無い（そのような API を forward.nim は提供しない）ので、
          # detach してから作り直す。作り直しは「id が registry から消えた」
          # 次回以降の reconcile に委ねる（isDiscardable になるまで detach の
          # 副作用確認に複数 tick かかるため、この呼び出し内では完結しない）。
          if existing.state != fwDetaching:
            requestDetach(existing)
            result.actions.add((raDetachForward, tc.name))
          # else: 既に detach 済み進行中。二重に requestDetach すると内部の
          # 進捗フラグ（detachCancelIssued 等）がリセットされてしまう
          # （forward.requestDetach の doc comment を参照）ため呼ばない。
        # else: 一致している。何もしない（これが冪等性の核心）。
      else:
        # 対象外（profile 不一致）または無効化された。存在するので detach する。
        if existing.state != fwDetaching:
          requestDetach(existing)
          let action = if targeted: raDisableForward else: raDetachForward
          result.actions.add((action, tc.name))
    else:
      if shouldExist:
        let hs = getOrCreateHost(reg, tc.host, tc.sshExtraArgs)
        discard addForward(reg, tc.name, tc.spec, hs)
        # `enabledOverride` に明示的な true が入っている（= `powarder start`
        # で再開させた）場合は raEnableForward、それ以外（設定ファイルに
        # 新規に現れた / autostart によるもの）は raCreateForward として
        # 報告を区別する。
        if tc.name in reg.enabledOverride and reg.enabledOverride[tc.name]:
          result.actions.add((raEnableForward, tc.name))
        else:
          result.actions.add((raCreateForward, tc.name))
      # else: 存在しないし必要でもない。何もしない。

    # Pass B: registry にあるが desired.tunnels に名前ごと存在しない
    # （設定ファイルから完全に削除された）Forward を detach する。
    # Pass A は desired.tunnels を基準にループするため、消えたトンネルは
    # そもそもループに現れず素通りしてしまう。ここで registry 側を基準に補う。
  for id, fw in reg.forwards:
    if fw.tunnelName notin tunnelsByName:
      if fw.state != fwDetaching:
        requestDetach(fw)
        result.actions.add((raDetachForward, fw.tunnelName))

  # --- 手順3: pruneOverrides ---------------------------------------------
  var names: seq[string] = @[]
  for tc in desired.tunnels:
    names.add(tc.name)
  pruneOverrides(reg, names)
