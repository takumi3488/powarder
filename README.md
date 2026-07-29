# powarder

`powarder` は、SSH のローカル/リモートポートフォワード（`ssh -L` / `ssh -R`）を
Docker コンテナのように「名前の付いた管理対象」として扱う CLI と、それを
裏で維持し続ける常駐デーモンです。

## これは何か

素の `ssh -N -L 8080:localhost:80 bastion` を使ったことがある人なら、次のような
不満に心当たりがあるはずです。

- 端末を閉じると（あるいは SSH セッションが切れると）フォワードも死ぬ
- ネットワークが一瞬切れただけで再接続してくれない
- いま自分が何本トンネルを張っているか、`ps` で一覧できない
- 同じ長いコマンドを毎回タイプし直す（あるいはシェルの履歴を漁る）

`powarder` はこれらを、Docker が「コンテナ」という単位でプロセスを管理するのと
同じ発想で解決します。トンネルには名前を付けて `powarder.json` に宣言し、
バックグラウンドのデーモンが `powarder up` / 自動起動時にまとめて張り、
死んだら統計情報（接続数・転送バイト数）付きの `ps` で状態を確認しながら、
自動的に張り直します。

**`autossh` との違い**: `autossh` は「1本の ssh 接続の生存監視」だけを行う
ツールで、複数のトンネルを横断した一覧性や、名前による管理、接続ごとの
統計は持ちません（`autossh` を並べて複数起動しても、それぞれが独立していて
全体像を把握する手段が無い）。`powarder` は複数のトンネル・複数のホストを
1つのデーモンが一元管理し、`ps` / `hosts` / `inspect` で全体を見渡せる点が
本質的な違いです。

## インストール

`powarder` は Nim 2.2.10 で書かれており、**外部の nimble パッケージには
一切依存しません**（`std/*` のみ）。ビルドに必要なのは Nim 本体だけです。

[mise](https://mise.jdx.dev/) を使う場合:

```bash
mise plugins install nim https://github.com/mise-plugins/mise-nim
mise install nim@2.2.10
```

ビルド:

```bash
git clone https://example.com/powarder.git
cd powarder
mise exec -- nimble build -y
```

`./powarder` バイナリができます。適当な `$PATH` の通ったディレクトリに置いて
ください（例: `mv powarder /usr/local/bin/` や `~/.local/bin/`）。

## 使い方

まず設定無しで、ad-hoc に1本張ってみます（`ssh -L` とほぼ同じ書き味です）。

```console
$ powarder run -L 8080:localhost:80 prod-bastion
✔ tunnel "web1" started (-L 127.0.0.1:8080 -> localhost:80 via prod-bastion)
```

`~/.config/powarder/config.json`（または `./powarder.json`）に宣言しておけば、
まとめて起動・停止できます。

```console
$ powarder up
✔ tunnel "web1" started
✔ tunnel "db1" started

$ powarder ps
NAME  TYPE  BIND             TARGET           HOST          CONNS  RX/TX      LAST  UPTIME  STATUS
web1  -L    127.0.0.1:18001  localhost:8001   localhost     0      83B/204B   1s    3s      active
db1   -L    127.0.0.1:15432  db.internal:5432 prod-bastion  2      1.2kB/512B 5s    3s      active

$ powarder hosts
HOST          STATE        TUNNELS  PID    UPTIME  RETRIES
prod-bastion  hsConnected  2        41213  3s      0

$ powarder logs -f web1
# ssh マスターの -v ログをそのまま tail -f する（Ctrl-C で抜ける）

$ powarder down
✔ tunnel "web1" stopped
✔ tunnel "db1" stopped
```

停止中のトンネルをまとめて片付けたいときは `prune` を使います
（`-a` の有無に関わらず、停止中のトンネルを全部見て削除します）。

```console
$ powarder prune
✔ tunnel "web1" removed
```

主なサブコマンド一覧は `powarder help` を、個別のオプションは
`powarder help <command>` を参照してください。

### 常駐サービスとして登録する

端末やログインセッションと無関係にデーモンを動かし続けたい場合は、
OS のサービス機構に登録できます。

```console
$ powarder daemon install
✔ installed "dev.powarder.daemon" -> /Users/you/Library/LaunchAgents/dev.powarder.daemon.plist (running)

$ powarder daemon uninstall
✔ uninstalled "dev.powarder.daemon"
```

- macOS: `~/Library/LaunchAgents/dev.powarder.daemon.plist` を生成し
  `launchctl bootstrap` で登録します。
- Linux: `~/.config/systemd/user/powarder.service` を生成し
  `systemctl --user enable --now` で登録します。**`loginctl enable-linger
  $USER` を実行していないと、ログアウト時に systemd の user manager ごと
  停止し、トンネルも切れます**（`daemon install` / `daemon status` の出力に
  この案内が出ます）。

## 設定ファイル

`~/.config/powarder/config.json`（`POWARDER_CONFIG` で上書き可。カレント
ディレクトリに `powarder.json` があればそちらを優先）の例:

```jsonc
{
  "version": 1,
  "tunnels": [
    {
      "name": "prod-db",
      "host": "prod-bastion",
      "type": "L",
      "forward": "15432:db.internal:5432",
      "autostart": true,
      "profile": "prod"
    },
    {
      "name": "webhook",
      "host": "dev-box",
      "type": "R",
      "forward": "8443:localhost:3000"
    }
  ]
}
```

| フィールド | 説明 |
|---|---|
| `name` | トンネルの一意な名前。`ps` / `start` / `stop` / `rm` 等で参照する |
| `host` | `~/.ssh/config` の `Host` エイリアス |
| `type` | `"L"`（ローカルフォワード）または `"R"`（リモートフォワード） |
| `forward` | ssh 完全互換の `[bind_address:]port:host:hostport` |
| `autostart` | `powarder up` で自動的に起動するか（省略時 `false`） |
| `profile` | `powarder up --profile X` で選択的に起動するためのタグ |
| `sshExtraArgs` | マスター起動時に追加する ssh オプション（省略可） |
| `retry` | 再接続のバックオフ設定（省略可） |

**`~/.ssh/config` との役割分担**: `powarder.json` には意図的に `user` /
`port` / `identityFile` / `proxyJump` に相当するフィールドを持たせて
**いません**。接続経路・認証（ユーザー名・ポート番号・鍵ファイル・踏み台
経由の `ProxyJump`）は `~/.ssh/config` の責務、「どのローカルポートを
どこへ転送するか」という転送トポロジだけが `powarder.json` の責務、という
分担をスキーマのレベルで強制しています。これらのキーを書いても致命的
エラーにはしませんが、`~/.ssh/config` へ書くよう促す警告が出ます。

## 仕組み

`powarder` は自前で SSH プロトコルを実装しているわけではありません。
`ssh` バイナリそのものを **ControlMaster** として起動し、個々のフォワードは
起動済みのマスターに `ssh -O forward` で後付けする、という構成を取ります。

- **1ホスト = 1つの長命マスター。** `~/.ssh/config` の同じ `Host` を指す
  複数のトンネルは、1つのマスター接続を共有します。「同じ host か」は
  ホスト名の文字列一致ではなく、`ssh -G <host>` の解決結果（実際に有効になる
  全設定）から作った fingerprint で判定しています。そのため `ProxyJump` や
  `IdentityFile` を `Host` ブロックの継承で変えても、実質的に同じ接続先なら
  正しく1本にまとまります。
- **認証・鍵・KEX は全部 OpenSSH に任せる。** マスターの起動は普通の
  `ssh -M -N ...` であり、`ProxyJump`、証明書認証、FIDO2/セキュリティキー、
  最新の鍵交換アルゴリズムなど、手元の `ssh` が対応しているものはそのまま
  powarder でも使えます。powarder が「認証をどう頑張るか」を作り込む必要が
  ありません。
- **`-L` は powarder が薄い TCP プロキシを挟みます。** ユーザーが指定した
  ローカルポートは powarder 自身が listen し、実際のフォワードは ssh 側に
  Unix domain socket を張らせて、そこへ powarder が中継します。理由は単純で、
  ssh の mux プロトコルには接続数・転送バイト数を取得する手段が無いためです。
  クライアントと powarder の間に自前のプロキシを挟むことで、`ps` に出る
  `CONNS` / `RX/TX` 等の統計を実測できるようにしています。
- **`-R` は統計が取れません。** リモート側が listen する構成上、powarder は
  データパスに一切介在できないため、原理的に接続数もバイト数も分かりません
  （`ps` ではこれらの列が `-` になります）。ヘルスチェックも「マスターが
  生きているか」だけが頼りです。
- **ヘルスチェックは実トラフィックの副産物が主体（Tier 3）。** 定期的な
  能動プローブ（`--probe` でオプトインできる Tier 2）は宛先への実接続を
  必ず発生させてしまい、宛先のログにノイズを撒くため既定では行いません。
  代わりに、実際のクライアント接続が上流に繋がらなかった回数を見て不健全を
  判定します。トラフィックが多いフォワードほど異常検知が速くなるのが利点です。

## トラブルシュート

- **非対話認証が前提です。** デーモンには TTY が無く、常に
  `BatchMode=yes` で接続します。パスワード認証や対話的な MFA が必須の
  ホストには使えません。事前に鍵を用意し、`ssh-agent` に解錠済みの状態で
  登録しておいてください。
- **launchd/systemd 経由だと `SSH_AUTH_SOCK` が継承されません。**
  対話シェルから起動したセッションの環境変数（`PATH` も含む）は、
  OS サービスとして起動したデーモンには引き継がれません。`PATH` は
  plist/unit ファイル側で最低限を明示していますが、`SSH_AUTH_SOCK`
  （ssh-agent のソケットパス）は原理的に解決できません。鍵がエージェント
  管理の場合、`daemon install` 経由では認証できないことがあります。
  macOS では `~/.ssh/config` に `UseKeychain yes` を設定して macOS の
  Keychain に鍵を保存する方式にすると、この問題を回避できます。
- **`powarder logs <name>` で、対応する ssh マスターの `-v` ログがそのまま
  読めます。** デバッグの最後の砦です。デーモンが停止していても、ログ
  ファイル自体は `~/.local/state/powarder/logs/` に残っているので直接
  読めます。
- **エラーメッセージは（ロケールが日本語なら）日本語に翻訳されますが、
  生の ssh 出力も必ず併記されます。** 翻訳文だけでは判断できないケースの
  ための保険です。
- **`-R` のヘルスチェックは弱いです。** リモート側が listen する構成上、
  そのリスナーが実際に生きているかを powarder 側から確認する手段が
  原理的にありません。「マスター接続が生きているか」以上の保証はできない
  点を理解した上で使ってください。

## 既知の制約

- 非特権ユーザー前提です（macOS の LaunchAgent、Linux の
  `systemctl --user`）。1024番未満の特権ポートへの bind や、複数 OS
  ユーザー間で1つのデーモンを共有する構成はスコープ外です。
- `~/.ssh/config` を書き換えたら `powarder daemon reload` を実行して
  ください（デーモンは起動時に読んだ設定をキャッシュしています）。
- macOS の `sockaddr_un.sun_path` には 104 バイトの制限があるため、
  ランタイムディレクトリ（IPC ソケットや ControlPath を置く場所）が
  深すぎると使えません。その場合は `POWARDER_RUNTIME_DIR` で短いパスを
  明示してください。
