## `ssh -O forward` / `-O cancel` / `-O check` の実行結果を判定する。
##
## powarder の中で最も壊れやすい部分をここに閉じ込める。ssh マルチプレックス制御
## コマンドの成否は「終了コード」と「stderr の文言」の組み合わせでしか判定できず、
## しかもその組み合わせ方はサブコマンドごとに異なる（詳細は各 proc の doc comment）。
## OpenSSH のバージョンが上がって文言が変わったときに、この一致判定が古いままだと
## powarder は「成功したのに失敗扱い」「失敗したのに成功扱い」を起こしうる。
## そのためテスト（`tests/tmuxparse.nim`）で実測データを固定し、この文言が変わった
## 瞬間にテストが落ちて気付けるようにしてある。
##
## このモジュールは I/O を一切行わない。`std/asyncnet` / `std/osproc` / `std/os` を
## import しない。「ssh -O ... を実際に起動して (exitCode, stdout, stderr) を得る」のは
## 呼び出し側（`daemon/muxclient.nim` の想定）の責務であり、ここではそれを受け取って
## 判定するだけの純粋関数だけを提供する。

import std/strutils

# ---------------------------------------------------------------------------
# マッチ対象の文字列定数
#
# OpenSSH のバージョンアップで mux.c / ssh.c の出力文言が変わった場合、
# まずここを確認・修正する。実際に確認する手順は `mux_client_forward()` /
# `mux_client_request_forwards()` / `control_client()` (mux.c) 周辺。
# ---------------------------------------------------------------------------

const
  msgControlSocketConnect = "Control socket connect("
    ## 制御ソケットに繋がらない場合の前半部分だけを見る。
    ## 実際のメッセージはパスとエラー文言込みで
    ## `Control socket connect(/tmp/x.sock): No such file or directory` (ENOENT) や
    ## `Control socket connect(/tmp/x.sock): Connection refused` (ECONNREFUSED) になり、
    ## パスやエラー文言は可変なので前半の固定部分だけをマッチ対象にする。

  msgMasterRefused = "Master refused forwarding request:"
    ## マスターがポリシー（`PermitLocalCommand` 等ではなく mux 自体の許可設定）で
    ## forward/cancel 要求を拒否した場合。mux.c の `mux_client_forward()` は
    ## forward・cancel の両方でこの同じ文言を使う。

  msgBindFailed = "Port forwarding failed"
    ## `-O forward` で実際に bind できなかった場合。実測では
    ## `mux_client_forward: forwarding request failed: Port forwarding failed` の
    ## 形で出るが、判定には後半の固有部分だけを使う。

  msgNotForwarded = "port not forwarded"
    ## `-O cancel` の対象が forward 表に存在しない場合。実測では
    ## `mux_client_forward: forwarding request failed: port not forwarded` の形。

  msgBadSpecLocal = "Bad local forwarding specification"
  msgBadSpecRemote = "Bad remote forwarding specification"
    ## `-L` / `-R` の構文エラー。ssh.c の引数パース段階（mux 層より手前）で
    ## 弾かれるため、通常は `moNoMaster` 等と同時に出ることはない。

  msgMasterRunningPrefix = "Master running (pid="
    ## `-O check` でマスターが生存している場合に **stderr** に出る
    ## （stdout ではない。実測確認済み）。この直後に pid の数字が続き `)` で閉じる。

type
  MuxOutcome* = enum
    moSuccess ## 成功（新規 bind した場合と、既存エントリへの冪等成功の両方を含む）
    moBindFailed     ## bind に失敗した（Port forwarding failed）
    moNotForwarded   ## cancel 対象が forward 表に無い（port not forwarded）
    moRefused        ## マスターがポリシーで拒否した
    moNoMaster       ## 制御ソケットに繋がらない
    moBadSpec        ## forward 指定の構文エラー
    moUnknownFailure ## 上記に当てはまらない失敗

proc parseForwardResult*(exitCode: int; stdout, stderr: string): MuxOutcome =
  ## `ssh -O forward` の結果を判定する。
  ##
  ## **exitCode は判定に使える**（実測: 成功 0 / 失敗 255）。ただし exitCode が 0 で
  ## あることは「新規に bind した」ことを意味しない。既存と全く同じ forward 指定を
  ## 再送した場合も ssh は同じく 0 を返す（冪等成功）。呼び出し側は「新規に張れたか」
  ## を知りたい場合、この結果だけでなく事前に自分の状態（`ForwardState`）を見て判断する
  ## 必要がある。
  ##
  ## stdout は実測で常に空であり、判定には使わない（引数として受け取るのは API 形状を
  ## `parseCancelResult` / `parseCheckResult` と揃えるため）。
  ##
  ## 優先順位（複数パターンが同時にマッチしうる場合、上から順に判定する）:
  ## 1. `moNoMaster`   -- 制御ソケットに繋がっていない。これが真なら ssh は forward 要求
  ##                      自体を送れていないので、以降のどの判定よりも根本的な原因であり
  ##                      最優先とする。
  ## 2. `moBadSpec`    -- `-L`/`-R` の構文エラー。理論上は mux 層に届く前に弾かれるため
  ##                      `moNoMaster` と同時に出ることはないはずだが、フェイルセーフとして
  ##                      2番目に置く。
  ## 3. `moRefused`    -- マスターのポリシー拒否。
  ## 4. `moBindFailed` -- 実際の bind 失敗。
  ## 5. どれにも当てはまらない失敗は `moUnknownFailure`。
  discard stdout
  if exitCode == 0:
    return moSuccess
  if msgControlSocketConnect in stderr:
    return moNoMaster
  if msgBadSpecLocal in stderr or msgBadSpecRemote in stderr:
    return moBadSpec
  if msgMasterRefused in stderr:
    return moRefused
  if msgBindFailed in stderr:
    return moBindFailed
  moUnknownFailure

proc parseCancelResult*(exitCode: int; stdout, stderr: string): MuxOutcome =
  ## `ssh -O cancel` の結果を判定する。
  ##
  ## **exitCode は一切信用できない**（実測: 成功・失敗どちらも 0 を返す）。
  ## 判定は stderr の文言だけで行う。stderr が空（空白文字だけの場合も含む）なら
  ## `moSuccess`。
  ##
  ## 優先順位（上から順に判定する）:
  ## 1. `moNoMaster`     -- 制御ソケット自体に繋がっていない。
  ## 2. `moRefused`      -- マスターのポリシー拒否（forward と cancel で同じ文言を共有する）。
  ## 3. `moNotForwarded` -- cancel 対象が forward 表に無い。
  ## 4. 上記のどれにも当てはまらず stderr が非空なら `moUnknownFailure`。
  discard stdout
  discard exitCode
  if stderr.strip().len == 0:
    return moSuccess
  if msgControlSocketConnect in stderr:
    return moNoMaster
  if msgMasterRefused in stderr:
    return moRefused
  if msgNotForwarded in stderr:
    return moNotForwarded
  moUnknownFailure

proc parseCheckResult*(exitCode: int; stdout, stderr: string): tuple[
    alive: bool; pid: int] =
  ## `ssh -O check` の結果を判定する。
  ##
  ## マスター生存時のメッセージ `Master running (pid=N)` は **stderr** に出る
  ## （stdout ではない。実測確認済み）。pid の数字部分を取り出せない場合は
  ## `(alive: false, pid: 0)` を返す。
  discard stdout
  discard exitCode
  let idx = stderr.find(msgMasterRunningPrefix)
  if idx < 0:
    return (alive: false, pid: 0)
  var i = idx + msgMasterRunningPrefix.len
  var pidStr = ""
  while i < stderr.len and stderr[i] in Digits:
    pidStr.add stderr[i]
    inc i
  if pidStr.len == 0:
    return (alive: false, pid: 0)
  (alive: true, pid: parseInt(pidStr))
