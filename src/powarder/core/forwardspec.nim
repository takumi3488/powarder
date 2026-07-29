## ssh の `-L` / `-R` 引数と完全互換な文字列と `ForwardSpec` の相互変換。
##
## CLI 引数とファイル設定ファイルの両方の入口になるため、ssh 本体のフォーマットに
## 厳密に追従する。IPv6 アドレスは `[addr]` のブラケット記法で扱う。
##
## このモジュールは I/O を一切行わない。`std/asyncnet` / `std/osproc` / `std/os` を
## import しない。

import std/strutils
import std/nativesockets ## `Port` の `$` / `==` を使うために必要
                          ## （types.nim は `export Port` で型のみ再輸出しているため）
import powarder/core/types
import powarder/core/hashid

# ---------------------------------------------------------------------------
# 内部ヘルパー
# ---------------------------------------------------------------------------

proc bracketize(host: string): string =
  ## IPv6 リテラル（`:` を含む）だけブラケットで包む。IPv4 やホスト名は
  ## `:` を含まないため素通りする。
  if host.contains(':'):
    "[" & host & "]"
  else:
    host

proc tokenizeFields(s: string): seq[string] =
  ## `[bind_address:]port:host:hostport` を `:` で分割する。
  ## `[...]` で囲まれた IPv6 リテラル内部の `:` はトップレベルの区切りとして
  ## 扱わない。
  result = @[]
  var i = 0
  let n = s.len
  while true:
    if i < n and s[i] == '[':
      let closeIdx = s.find(']', i + 1)
      if closeIdx < 0:
        raise newException(ValueError, "閉じていない '[' があります: " & s)
      result.add(s[i + 1 ..< closeIdx])
      i = closeIdx + 1
      if i >= n:
        break
      if s[i] != ':':
        raise newException(ValueError,
            "IPv6 リテラル ']' の直後は ':' である必要があります: " & s)
      inc i
      if i == n:
        result.add("")
        break
    else:
      let colonIdx = s.find(':', i)
      if colonIdx < 0:
        result.add(s[i ..< n])
        break
      else:
        result.add(s[i ..< colonIdx])
        i = colonIdx + 1
        if i == n:
          result.add("")
          break

proc parsePortStrict(token, input: string): Port =
  ## ポート番号として妥当（1-65535の整数）かを検証しつつ `Port` へ変換する。
  var value: int
  try:
    value = parseInt(token)
  except ValueError:
    raise newException(ValueError,
        "ポート番号が数値ではありません (\"" & token & "\"): " & input)
  if value < 1 or value > 65535:
    raise newException(ValueError,
        "ポート番号が範囲外です (1-65535 の範囲で指定してください、実際は " &
        $value & "): " & input)
  Port(value)

# ---------------------------------------------------------------------------
# 公開 API
# ---------------------------------------------------------------------------

proc parseForwardSpec*(s: string, kind: ForwardKind): ForwardSpec =
  ## ssh 互換の `[bind_address:]port:host:hostport` をパースする。
  ##
  ## - フィールドが3個なら `bind_address` は省略されたとみなし
  ##   `defaultBindAddr` を使う。4個なら先頭が `bind_address`。
  ## - `*` は ssh が「全アドレス」として受け付ける慣習に合わせて `0.0.0.0` に
  ##   正規化する（内部表現・比較を単純にするための判断。往復変換では
  ##   `0.0.0.0` として出力される）。
  ## - IPv6 は `[addr]` のブラケット記法のみ受け付ける。
  ## - port は 1-65535 の整数でなければならない（0 は ssh 本体も
  ##   `-O forward` 経由では `Bad local forwarding specification` として
  ##   拒否するため、powarder でも同様に拒否する）。
  if s.len == 0:
    raise newException(ValueError, "空文字列は指定できません")

  let fields = tokenizeFields(s)

  var bindAddr: string
  var bindPortTok: string
  var targetHost: string
  var targetPortTok: string

  case fields.len
  of 3:
    bindAddr = defaultBindAddr
    bindPortTok = fields[0]
    targetHost = fields[1]
    targetPortTok = fields[2]
  of 4:
    bindAddr = fields[0]
    bindPortTok = fields[1]
    targetHost = fields[2]
    targetPortTok = fields[3]
  else:
    raise newException(ValueError,
        "フィールド数が不正です ([bind_address:]port:host:hostport の3または" &
        "4フィールドである必要があります、実際は " &
        $fields.len & "個): " & s)

  if bindAddr == "*":
    bindAddr = "0.0.0.0"

  if bindAddr.len == 0:
    raise newException(ValueError, "bind_address が空です: " & s)
  if targetHost.len == 0:
    raise newException(ValueError, "転送先ホストが空です: " & s)

  let bindPort = parsePortStrict(bindPortTok, s)
  let targetPort = parsePortStrict(targetPortTok, s)

  ForwardSpec(kind: kind, bindAddr: bindAddr, bindPort: bindPort,
              targetHost: targetHost, targetPort: targetPort)

proc formatForwardSpec*(spec: ForwardSpec): string =
  ## `parseForwardSpec` の逆変換。`bindAddr` が `defaultBindAddr` と等しい
  ## 場合でも省略せず明示的に出力する（往復変換で情報が落ちないように）。
  ## IPv6 リテラルにはブラケットを付ける。
  bracketize(spec.bindAddr) & ":" & $spec.bindPort & ":" &
    bracketize(spec.targetHost) & ":" & $spec.targetPort

proc toSshForwardArg*(spec: ForwardSpec, udsPath = ""): string =
  ## `ssh -O forward -L` / `-R` に渡す引数文字列を組み立てる。
  ##
  ## - `fkLocal` かつ `udsPath` が非空: powarder は ssh に UDS を張らせ、
  ##   自身が listen する `bindPort` は ssh には渡さない。
  ##   -> `<udsPath>:<targetHost>:<targetPort>`
  ## - `fkLocal` かつ `udsPath` が空: TCP フォールバック。
  ##   -> `<bindAddr>:<bindPort>:<targetHost>:<targetPort>`
  ## - `fkRemote`: UDS は使わない（リモート側が listen するため）。
  ##   -> `<bindAddr>:<bindPort>:<targetHost>:<targetPort>`
  let targetHostStr = bracketize(spec.targetHost)
  if spec.kind == fkLocal and udsPath.len > 0:
    udsPath & ":" & targetHostStr & ":" & $spec.targetPort
  else:
    bracketize(spec.bindAddr) & ":" & $spec.bindPort & ":" &
      targetHostStr & ":" & $spec.targetPort

proc forwardId*(spec: ForwardSpec, host: string): string =
  ## Forward の一意な識別子。bind する実体から決定的に導出する。
  ##
  ## - `fkLocal`: ローカルポートはマシン全体でグローバルに一意でなければ
  ##   ならないため `host` を含めない。これにより「2つのトンネルが同じ
  ##   ローカルポートを取り合っている」設定ミスを検出できる。
  ## - `fkRemote`: リモート側の bind はホストごとに一意でよいため `host`
  ##   を含める。
  case spec.kind
  of fkLocal:
    "L:" & spec.bindAddr & ":" & $spec.bindPort
  of fkRemote:
    "R:" & host & ":" & spec.bindAddr & ":" & $spec.bindPort

proc udsBasename*(id: string): string =
  ## `forwardId` の結果から UDS ファイル名を導出する。`sun_path` の長さ
  ## 制限のため、`hashid.hashHex` で8桁（32bit・小文字16進）に短縮する。
  ##
  ## 8桁hex = 32bit なので理論上は衝突しうるが、同時に存在するフォワードは
  ## 数十本程度であり誕生日問題を踏まえても衝突確率は無視できる。万一衝突
  ## しても `-O forward` が `Port forwarding failed` を返すため沈黙して
  ## 壊れることはなく、`daemon/forward.nim` 側で残骸を unlink して1回
  ## 再試行する経路に乗る。
  hashHex(id, 8)
