## ssh 本体（マスタープロセス）の stderr を分類し、初心者にも分かる説明文に翻訳する。
##
## powarder の「簡単さ」を最も強く体感させる部分。生の ssh のエラーメッセージ
## （英語・専門用語だらけで、原因を特定するのに ssh/ネットワークの知識を要求する）を、
## 「何が起きたか」「次に何をすればよいか」に変換する。
##
## このモジュールは I/O を一切行わない。`std/asyncnet` / `std/osproc` / `std/os` を
## import しない。`Lang` の決定（`LANG` 環境変数を読むなど）は I/O なので呼び出し側の
## 責務であり、ここでは「決まった `Lang` を渡されたら、決まった文言を返す」ことしかしない。

import std/strutils
import std/sequtils

# ---------------------------------------------------------------------------
# マッチ対象の文字列定数
#
# OpenSSH のバージョンアップで文言が変わった場合、まずここを確認・修正する。
# 参照元（実際に確認したソース）はそれぞれのコメントに記載。
# ---------------------------------------------------------------------------

const
  msgAddressInUse = "Address already in use"
    ## channels.c の `channel_setup_fwd_listener_tcpip()` が bind(2) 失敗時に出す
    ## `error("bind [%s]:%s: %.100s", ...)` の中身（strerror(EADDRINUSE)）。
    ## 前置き（`bind [addr]:port:` の部分）はアドレス表記次第で変わるので、
    ## strerror の文言だけをマッチ対象にする。

  msgPermDeniedPubkey = "Permission denied (publickey"
  msgPermDeniedPassword = "Permission denied (password"
    ## sshconnect2.c: `fatal("%s@%s: Permission denied (%s).", user, host, authlist)`。
    ## `%s` には残っている認証方式のカンマ区切りリストが入る（例:
    ## `Permission denied (publickey).` / `Permission denied (publickey,password).`）。

  msgTooManyAuthFailures = "Too many authentication failures"
    ## auth.c: `auth_maxtries_exceeded()` が
    ## `ssh_packet_disconnect(ssh, "Too many authentication failures")` で切断理由として
    ## 送る文字列。クライアント側では packet.c により
    ## `Received disconnect from <host> port <port>:<code>: Too many authentication failures`
    ## という形で stderr に出る。

  msgPermDeniedPubkeyKbdInteractive = "Permission denied (publickey,keyboard-interactive"
  msgPermDeniedPubkeyPassword = "Permission denied (publickey,password"
    ## 上の `msgPermDeniedPubkey` と同じ実装だが、残り認証方式リストの **先頭が
    ## publickey で、かつ他に対話系認証方式しか残っていない** 具体形。BatchMode 下では
    ## これらの対話系認証を試すためのプロンプトを一切出せない（後述）ため、
    ## 「publickey が使えず、かつ対話しないと先に進めない」ことをこの文字列だけで
    ## 特定できる。

  msgHostIdentificationChanged = "REMOTE HOST IDENTIFICATION HAS CHANGED"
    ## sshconnect.c: `warn_changed_key()` が出す警告バナーの1行
    ## （`@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @`）。
    ## known_hosts に登録済みのホストキーと実際に提示されたキーが異なる、
    ## つまり MITM の可能性がある最重要ケース。

  msgRevokedHostKey = "REVOKED HOST KEY DETECTED"
    ## sshconnect.c: `check_host_key()` の `HOST_REVOKED` 分岐が出す警告バナー
    ## （`@ WARNING: REVOKED HOST KEY DETECTED! @`）。ホストキー信頼にまつわる
    ## 重大な警告という点で `msgHostIdentificationChanged` と同格に扱う。

  msgHostKeyVerificationFailed = "Host key verification failed"
    ## sshconnect2.c: `verify_host_key_callback()` が
    ## `fatal("Host key verification failed.")` を出す。`check_host_key()` が
    ## 失敗を返す経路はすべてここに合流するため、単独ではこの1文だけで原因を
    ## 特定できない（後述の `msgStrictChecking` と合わせて判定する）。

  msgStrictChecking = "requested strict checking"
    ## sshconnect.c の `HOST_NEW` / `HOST_CHANGED` 分岐が
    ## `StrictHostKeyChecking=yes` によって拒否したときに付け加える説明文の一部
    ## （例: `Host key for <host> has changed and you have requested strict checking.`）。
    ## この文言が **ある** ということは、原因は設定（StrictHostKeyChecking）で
    ## あることが stderr 自体から分かる。逆に **無い** のに
    ## `msgHostKeyVerificationFailed` だけが単独で出ているのは、sshconnect.c の
    ## `confirm()` が `options.batch_mode` を見て何も出力せず即座に拒否した
    ## （新規ホストの鍵を確認してよいか対話で聞けなかった）ケースであると判断できる。

  msgRemoteForwardFailed = "remote port forwarding failed for listen"
    ## ssh.c: `client_global_request_reply_fwd()` が
    ## `logit("Warning: remote port forwarding failed for listen port %d", ...)` /
    ## `fatal("Error: remote port forwarding failed for listen path %s", ...)` の形で出す。
    ## Warning/Error、port/path のどの組み合わせでも同一原因（リモート側が bind を
    ## 拒否した。多くは `GatewayPorts no` によりリモートの sshd が
    ## 要求された bind_address を許可しなかったため）なので、
    ## 共通部分だけをマッチ対象にする。

  msgAdministrativelyProhibited = "administratively prohibited"
  msgOpenFailed = "open failed"
    ## channels.c: チャネル open 要求がリモートのポリシー
    ## （`AllowTcpForwanding no` / `PermitOpen` 不一致）で拒否されたときの
    ## `reason2txt()` の戻り値と、サーバが付随して送る msg 文字列。実際には
    ## `channel N: open failed: administratively prohibited: open failed` のように
    ## 両方が同時に出る（サーバ側実装の都合で msg も常に "open failed" 固定文字列に
    ## なるため一見冗長だが実測でもこの形になる）。

  msgUnknownHostResolve = "Could not resolve hostname"
    ## ssh.c: `resolve_host()` 系が
    ## `fatal("%s: Could not resolve hostname %.100s: %s", ...)` の形で出す。
    ## 末尾の `%s` には getaddrinfo(3) のエラー文字列（gai_strerror）が入り、
    ## OS のライブラリ実装によって文言が変わる
    ## （下の `msgUnknownHostGlibc` / `msgUnknownHostBsd` を参照）。

  msgUnknownHostGlibc = "Name or service not known"
    ## glibc の gai_strerror(EAI_NONAME) の文言。Linux で発生。

  msgUnknownHostBsd = "nodename nor servname provided"
    ## macOS/BSD 系 libc の gai_strerror(EAI_NONAME) の文言
    ## （"nodename nor servname provided, or not known"）。

  msgConnectionRefused = "Connection refused"
  msgTimeoutLinux = "Connection timed out"
  msgTimeoutBsd = "Operation timed out"
    ## いずれも sshconnect.c:
    ## `error("ssh: connect to host %s port %s: %s", host, strport,
    ##     errno == 0 ? "failure" : strerror(errno))` の `strerror(errno)` 部分。
    ## ECONNREFUSED は OS 間で文言が揺れないが、ETIMEDOUT は Linux glibc が
    ## "Connection timed out"、macOS/BSD 系 libc が "Operation timed out" と
    ## 異なる文言を返すため両方を定数化する。

type
  ErrorKind* = enum
    ekPortInUse, ekAuthFailed, ekGatewayPortsDisabled, ekUnknownHost,
    ekConnectionRefused, ekTimeout, ekHostKeyChanged, ekForwardingDenied,
    ekBatchModeNoAuth, ekUnknown

  Lang* = enum langEn, langJa

  ErrorContext* = object
    ## 翻訳文にホスト名・ポート番号などを埋め込むための情報。
    ## powarder は BatchMode=yes 固定で動くので `interactiveAuthUnavailable` は
    ## 常に true になる想定だが、テストや将来の拡張のためフィールドとして残す。
    host*: string ## ~/.ssh/config の Host エイリアス
    bindPort*: int ## powarder / リモートが bind しようとしたポート
    targetHost*: string ## forward 先のホスト名
    targetPort*: int ## forward 先のポート
    rawStderr*: string ## `ekUnknown` のとき、生の stderr をそのまま提示するために使う

  Explanation* = object
    summary*: string    ## 1行の原因説明
    hints*: seq[string] ## 対処の候補（コマンド例を含む）

proc initErrorContext*(host = ""; bindPort = 0; targetHost = ""; targetPort = 0;
                       rawStderr = ""): ErrorContext =
  ## 使う項目だけを指定して組み立てるためのヘルパー。
  ErrorContext(host: host, bindPort: bindPort, targetHost: targetHost,
               targetPort: targetPort, rawStderr: rawStderr)

proc classify*(stderr: string): ErrorKind =
  ## ssh マスタープロセスの stderr（複数行のログ全体が渡される想定）を分類する。
  ##
  ## **最後に出た行ではなく、最も具体的な分類を優先する。** ssh は失敗の経緯を
  ## 複数行にわたって出力することが多く（例: 認証を何度も試みた末に
  ## `Permission denied` で終わる、host key 警告バナーの後に
  ## `Host key verification failed.` が続く）、最後の1行だけを見ると
  ## 「結局失敗した」という情報しか得られず、ユーザーに一番刺さる具体的な原因を
  ## 取りこぼす。そのため以下の優先順位で「複数マッチしうる中で最も対処に
  ## 直結する分類」を選ぶ。
  ##
  ## 優先順位（上から順に判定し、最初にマッチしたものを採用）:
  ## 1. `ekHostKeyChanged`
  ##    -- `REMOTE HOST IDENTIFICATION HAS CHANGED` または `REVOKED HOST KEY DETECTED`
  ##       のバナーが出ている場合。MITM の可能性がある最重要警告であり、
  ##       他のどんな判定よりも優先し、安易に「対話認証の問題」等へ倒さない
  ##       （安全側に倒す設計判断）。
  ## 2. `ekBatchModeNoAuth`
  ##    a. `Permission denied (publickey,keyboard-interactive` /
  ##       `Permission denied (publickey,password` -- publickey 認証が使えず、
  ##       残っているのが対話系認証方式のみという具体形。powarder は
  ##       BatchMode=yes で動くためこの時点で「対話できずに失敗した」と断定できる。
  ##    b. `Host key verification failed` が出ているが、1. のバナーも
  ##       `requested strict checking`（= StrictHostKeyChecking=yes による明示的拒否）
  ##       の文言も無い場合。OpenSSH のソース（sshconnect.c の `confirm()`）を
  ##       確認した限り、BatchMode 下で「未知のホスト鍵を確認してよいか」を
  ##       対話で尋ねられないときは、確認メッセージ自体が一切出力されないまま
  ##       `confirm()` が 0 を返し、結果としてこの1文だけが残る。この
  ##       「説明を伴わない単独の Host key verification failed」を BatchMode 由来と
  ##       判定する根拠にする。
  ## 3. `ekAuthFailed` -- 通常の `Permission denied` / `Too many authentication failures`。
  ## 4. `ekPortInUse` -- ローカル側の bind 失敗。
  ## 5. `ekGatewayPortsDisabled` -- リモート側の bind 失敗（`-R` 特有）。
  ## 6. `ekForwardingDenied` -- チャネル open 自体がリモートのポリシーで拒否された。
  ## 7. `ekUnknownHost` -- 名前解決の失敗。
  ## 8. `ekConnectionRefused` -- TCP レベルで拒否された。
  ## 9. `ekTimeout` -- 到達しない。
  ## 10. どれにも当てはまらなければ `ekUnknown`。
  if msgHostIdentificationChanged in stderr or msgRevokedHostKey in stderr:
    return ekHostKeyChanged
  if msgPermDeniedPubkeyKbdInteractive in stderr or
      msgPermDeniedPubkeyPassword in stderr:
    return ekBatchModeNoAuth
  if msgHostKeyVerificationFailed in stderr and msgStrictChecking notin stderr:
    return ekBatchModeNoAuth
  if msgPermDeniedPubkey in stderr or msgPermDeniedPassword in stderr or
      msgTooManyAuthFailures in stderr:
    return ekAuthFailed
  if msgHostKeyVerificationFailed in stderr:
    # ここに到達するのは msgStrictChecking を伴う場合のみ（上の判定を参照）。
    return ekHostKeyChanged
  if msgAddressInUse in stderr:
    return ekPortInUse
  if msgRemoteForwardFailed in stderr:
    return ekGatewayPortsDisabled
  if msgAdministrativelyProhibited in stderr or msgOpenFailed in stderr:
    return ekForwardingDenied
  if msgUnknownHostResolve in stderr or msgUnknownHostGlibc in stderr or
      msgUnknownHostBsd in stderr:
    return ekUnknownHost
  if msgConnectionRefused in stderr:
    return ekConnectionRefused
  if msgTimeoutLinux in stderr or msgTimeoutBsd in stderr:
    return ekTimeout
  ekUnknown

# ---------------------------------------------------------------------------
# 分類コード → テンプレート文字列のテーブル
#
# 言語を追加したいときは `Lang` に enum 値を足し、この配列に列を1つ足すだけで
# 済む構造にしてある（`classify` / `explain` のロジックは変更不要）。
# テンプレート中の `{host}` `{bindPort}` `{targetHost}` `{targetPort}` は
# `fill()` で `ErrorContext` の値に置換される。
# ---------------------------------------------------------------------------

type
  Template = tuple[summary: string; hints: seq[string]]

const
  templates: array[ErrorKind, array[Lang, Template]] = [
    ekPortInUse: [
      langEn: (
        summary: "Local port {bindPort} is already in use by another process.",
        hints: @[
          "Find out what's using it: lsof -nP -iTCP:{bindPort} -sTCP:LISTEN",
          "Stop that process, or choose a different bindPort for this tunnel.",
    ]),
      langJa: (
        summary: "ローカルのポート {bindPort} は既に他のプロセスが使用しています。",
        hints: @[
          "何が使っているか確認する: lsof -nP -iTCP:{bindPort} -sTCP:LISTEN",
          "そのプロセスを止めるか、このトンネルの bindPort を別の番号に変更してください。",
    ]),
  ],
    ekAuthFailed: [
      langEn: (
        summary: "SSH authentication to {host} failed (publickey/password rejected).",
        hints: @[
          "Try connecting by hand to see the real prompt: ssh {host}",
          "Check that your key is loaded: ssh-add -l",
    ]),
      langJa: (
        summary: "{host} への SSH 認証に失敗しました（公開鍵/パスワードが拒否されました）。",
        hints: @[
          "単体で接続して実際のやり取りを確認する: ssh {host}",
          "鍵がエージェントに登録されているか確認する: ssh-add -l",
    ]),
  ],
    ekGatewayPortsDisabled: [
      langEn: (
        summary: "The remote side refused to bind the requested forwarding port.",
        hints: @[
          "Ask the remote admin to enable `GatewayPorts` in sshd_config if you " &
              "need it reachable from outside the remote host.",
          "Or bind to 127.0.0.1 on the remote side if only local access on " &
              "that host is needed.",
    ]),
      langJa: (
        summary: "リモート側が要求した転送ポートの bind を拒否しました。",
        hints: @[
          "リモートホストの外から到達させたい場合は、リモートの sshd_config で " &
              "`GatewayPorts` を有効にしてもらってください。",
          "そのホスト内からのアクセスだけで良いなら、リモート側の bind 先を " &
              "127.0.0.1 にしてください。",
    ]),
  ],
    ekUnknownHost: [
      langEn: (
        summary: "Could not resolve host \"{host}\".",
        hints: @[
          "Check for typos in the host name.",
          "Make sure the host is defined in ~/.ssh/config (or is a resolvable DNS name).",
    ]),
      langJa: (
        summary: "ホスト \"{host}\" を名前解決できませんでした。",
        hints: @[
          "ホスト名のタイプミスがないか確認してください。",
          "~/.ssh/config に Host が定義されているか（あるいは DNS で解決できる名前か）を確認してください。",
    ]),
  ],
    ekConnectionRefused: [
      langEn: (
        summary: "Connection to {host} was refused.",
        hints: @[
          "The sshd on the remote host may not be running.",
          "Double-check you're connecting to the right port.",
    ]),
      langJa: (
        summary: "{host} への接続が拒否されました。",
        hints: @[
          "相手ホストの sshd が起動していない可能性があります。",
          "接続先のポート番号が正しいか確認してください。",
    ]),
  ],
    ekTimeout: [
      langEn: (
        summary: "Connection to {host} timed out.",
        hints: @[
          "Check network reachability and any firewalls between here and {host}.",
    ]),
      langJa: (
        summary: "{host} への接続がタイムアウトしました。",
        hints: @[
          "ネットワークの到達性や、間にあるファイアウォールを確認してください。",
    ]),
  ],
    ekHostKeyChanged: [
      langEn: (
        summary: "The host key presented by {host} does not match the one " &
            "saved in known_hosts.",
        hints: @[
          "Do NOT simply delete the known_hosts entry. Verify the new host " &
              "key out-of-band with the server owner first (this could be a " &
              "man-in-the-middle attack).",
          "Only after verifying, remove the stale entry: ssh-keygen -R {host}",
    ]),
      langJa: (
        summary: "{host} が提示したホスト鍵が known_hosts に保存されているものと " &
            "一致しません。",
        hints: @[
          "known_hosts のエントリを安易に削除しないでください。まずサーバの" &
              "管理者に別経路で新しいホスト鍵を確認してください" &
              "（中間者攻撃の可能性があります）。",
          "確認が取れた後にのみ古いエントリを削除する: ssh-keygen -R {host}",
    ]),
  ],
    ekForwardingDenied: [
      langEn: (
        summary: "The remote sshd refused to open this forwarding channel.",
        hints: @[
          "Ask the remote admin to check `AllowTcpForwarding` (and `PermitOpen` " &
              "if set) in sshd_config for {host}.",
    ]),
      langJa: (
        summary: "リモートの sshd がこのフォワーディングのチャネル open を拒否しました。",
        hints: @[
          "{host} の sshd_config の `AllowTcpForwarding`（設定されていれば " &
              "`PermitOpen` も）を確認してもらってください。",
    ]),
  ],
    ekBatchModeNoAuth: [
      langEn: (
        summary: "{host} requires interactive authentication, which powarder " &
            "cannot provide (it always connects with BatchMode=yes).",
        hints: @[
          "Set up non-interactive publickey authentication for {host} " &
              "(ssh-copy-id, or add the key to the agent: ssh-add).",
          "If this is the first connection to {host}, connect once by hand " &
              "(plain `ssh {host}`) so the host key gets added to known_hosts, " &
              "then retry.",
    ]),
      langJa: (
        summary: "{host} は対話的な認証を要求していますが、powarder は常に " &
            "BatchMode=yes で接続するため対話できません。",
        hints: @[
          "{host} 向けに非対話の公開鍵認証を設定してください" &
              "（ssh-copy-id、または ssh-add でエージェントに鍵を追加）。",
          "{host} への初回接続の場合は、一度手動で `ssh {host}` して known_hosts " &
              "にホスト鍵を登録してから再試行してください。",
    ]),
  ],
    ekUnknown: [
      langEn: (
        summary: "ssh reported an error that powarder doesn't recognize yet.",
        hints: @[
          "Raw ssh stderr: {rawStderr}",
    ]),
      langJa: (
        summary: "powarder がまだ認識できない ssh のエラーが発生しました。",
        hints: @[
          "ssh の生の stderr: {rawStderr}",
    ]),
  ],
  ]

proc fill(t: string; ctx: ErrorContext): string =
  ## テンプレート中のプレースホルダを `ctx` の値へ置換する。
  t.multiReplace(
    ("{host}", ctx.host),
    ("{bindPort}", $ctx.bindPort),
    ("{targetHost}", ctx.targetHost),
    ("{targetPort}", $ctx.targetPort),
    ("{rawStderr}", ctx.rawStderr),
  )

proc explain*(kind: ErrorKind; lang: Lang; ctx: ErrorContext): Explanation =
  ## `kind` と `lang` に対応するテンプレートを取り出し、`ctx` の値を埋め込んで返す。
  let t = templates[kind][lang]
  Explanation(summary: t.summary.fill(ctx), hints: t.hints.mapIt(it.fill(ctx)))
