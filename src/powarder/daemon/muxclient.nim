## `ssh` を ControlMaster として起動し、`-O forward` / `-O cancel` / `-O check` /
## `-O exit` / `-G` を短命プロセスとして起動して結果を取得する層。
##
## **判定ロジックはここには置かない。** `ssh -O ...` の成否判定
## （文言マッチ・優先順位）は `core/muxparse.nim` に、`ssh -G` の出力パースは
## `core/sshgparse.nim` に、それぞれ純粋関数として既に実装済みなので、この
## モジュールは「プロセスを起動して `(exitCode, stdout, stderr)` を得る」ことと
## 「その3つ組を上記モジュールへそのまま渡す」ことだけに専念する。
##
## ## stdout / stderr を分離して取る際の注意（このモジュールの核心）
##
## `std/osproc` で子プロセスの標準出力・標準エラーをそれぞれ別の pipe として
## 受け取り、`waitForExit` を先に呼んでから読もうとすると、パイプの
## バッファが埋まった時点で子プロセスがブロックし、親はいつまでも
## `waitForExit` から返ってこないというデッドロックが起きる
## (https://github.com/nim-lang/Nim/issues/956)。
##
## かといって `poStdErrToStdOut` で1本のストリームにまとめてしまうと、
## stdout と stderr を区別できなくなる。これは powarder にとって許容できない:
## - `-O check` が生存中のマスターについて出す `Master running (pid=N)` は
##   **stderr** に出る（実測確認済み）
## - `-R 0:...` のような動的割り当てポート番号は `mux.c` が
##   `fprintf(stdout, ...)` で出すため **stdout** に出る
##
## そこで pipe を一切使わず、`/bin/sh -c '... >outfile 2>errfile'` という
## シェルリダイレクトでファイルに落として実行し、`waitForExit` の後にそれぞれの
## ファイルを読む方式を採る。子プロセスの出力は pipe ではなくファイルに向かうため、
## pipe バッファが埋まるという状況そのものが発生せず、#956 のデッドロックは
## 原理的に起こらない。（powarder はマスターのログ出力も同じ理由でシェル
## リダイレクトにしている。`masterCommandLine` を参照。方式を揃えている。）
##
## `args` はすべて `quoteShell` / `quoteShellCommand` でエスケープしてから
## シェルコマンド文字列に埋め込む。ホスト名やパスに空白・シェル特殊文字が
## 含まれていても壊れないようにするため。

import std/[os, osproc]
import powarder/core/types
import powarder/core/muxparse
import powarder/core/sshgparse
import powarder/core/forwardspec
import powarder/core/paths

export MuxOutcome, SshConfigResolved

type
  MuxResult* = object
    exitCode*: int
    stdout*: string
    stderr*: string

var callCounter = 0
  ## `runSsh` の呼び出しごとに一意な一時ファイル名を作るための単調増加カウンタ。
  ## powarder デーモンはシングルスレッドの非同期イベントループで動く前提だが、
  ## 同一プロセス内で PID だけに頼ると衝突しうるためこれと組み合わせる。

proc nextTmpId(): string =
  inc callCounter
  $getCurrentProcessId() & "-" & $callCounter

proc ensureTmpDir(): string =
  ## 一時ファイルの置き場を用意する。
  ##
  ## `core/paths.ensureRuntimeDir()` は ControlPath / forward UDS 用に
  ## `sun_path` の長さまで検証するが、ここに置くのは普通のファイル（UDS ではない）
  ## なのでその検証は不要かつ無関係。ディレクトリを作るだけにとどめる。
  result = runtimeDir()
  createDir(result)

proc runSsh*(args: openArray[string]): MuxResult =
  ## `ssh` を短命プロセスとして実行し、終了コードと stdout/stderr を分離して返す。
  ## pipe を使わずシェルリダイレクト経由でファイルに落とすので #956 の
  ## デッドロックが起きない（詳細はモジュール doc comment を参照）。
  let dir = ensureTmpDir()
  let id = nextTmpId()
  let outPath = dir / ("mux-" & id & ".out")
  let errPath = dir / ("mux-" & id & ".err")

  let sshArgs = @["ssh"] & @args
  # `exec` を付けて sh 自身を ssh に置き換える必然性はここでは無いが、
  # masterCommandLine と方式を揃えるため同じイディオムを使う。
  let cmd = "exec " & quoteShellCommand(sshArgs) &
    " >" & quoteShell(outPath) & " 2>" & quoteShell(errPath)

  var exitCode: int
  try:
    let process = startProcess("/bin/sh", args = ["-c", cmd], options = {})
    try:
      exitCode = process.waitForExit()
    finally:
      process.close()

    let outData = if fileExists(outPath): readFile(outPath) else: ""
    let errData = if fileExists(errPath): readFile(errPath) else: ""
    result = MuxResult(exitCode: exitCode, stdout: outData, stderr: errData)
  finally:
    # `os.removeFile` は unlink なので対象が無くてもエラーにならない。
    # try/finally で確実に消し、一時ファイルが残留しないようにする。
    removeFile(outPath)
    removeFile(errPath)

proc checkMaster*(ctlPath, host: string): tuple[alive: bool, pid: int] =
  ## `ssh -S <ctlPath> -O check <host>`。
  ## 判定は `core/muxparse.parseCheckResult` に委譲する。
  let r = runSsh(["-S", ctlPath, "-O", "check", host])
  parseCheckResult(r.exitCode, r.stdout, r.stderr)

proc addForward*(ctlPath, host: string; spec: ForwardSpec;
    udsPath = ""): MuxOutcome =
  ## `ssh -S <ctlPath> -O forward -L|-R <arg> <host>`。
  ## 引数文字列は `core/forwardspec.toSshForwardArg` で組む。`spec.kind` は
  ## `ForwardKind` の enum 値そのものが `"L"` / `"R"` の文字列表現を持つため
  ## `$spec.kind` でそのまま `-L` / `-R` のフラグ文字が得られる。
  ## 判定は `core/muxparse.parseForwardResult` に委譲する。
  let arg = toSshForwardArg(spec, udsPath)
  let r = runSsh(["-S", ctlPath, "-O", "forward", "-" & $spec.kind, arg, host])
  parseForwardResult(r.exitCode, r.stdout, r.stderr)

proc cancelForward*(ctlPath, host: string; spec: ForwardSpec;
    udsPath = ""): MuxOutcome =
  ## `ssh -S <ctlPath> -O cancel -L|-R <arg> <host>`。
  ## **exit code は一切信用できない**（実測: cancel は正常系・失敗系のいずれも
  ## 0 を返す）。判定は stderr の文言だけを見る
  ## `core/muxparse.parseCancelResult` に委譲する。
  let arg = toSshForwardArg(spec, udsPath)
  let r = runSsh(["-S", ctlPath, "-O", "cancel", "-" & $spec.kind, arg, host])
  parseCancelResult(r.exitCode, r.stdout, r.stderr)

proc exitMaster*(ctlPath, host: string): MuxOutcome =
  ## `ssh -S <ctlPath> -O exit <host>`。マスターを終了させる。
  ##
  ## `core/muxparse.nim` に `-O exit` 専用の判定関数は無い。`-O exit` の
  ## 終了コードは `-O forward` と同様に信用できる（成功 0 / 制御ソケットに
  ## 繋がらなければ 255）ため、`parseCancelResult`（exit code を無視し stderr が
  ## 空かどうかで判定する）ではなく `parseForwardResult` に委譲する。こうすると
  ## 成功時に stderr へ出る `Exit request sent.` のような付随メッセージが
  ## あっても exitCode 0 を優先して `moSuccess` と判定でき、かつ制御ソケットに
  ## 繋がらない場合は `moNoMaster` に正しく分類される。
  let r = runSsh(["-S", ctlPath, "-O", "exit", host])
  parseForwardResult(r.exitCode, r.stdout, r.stderr)

proc resolveSshConfig*(host: string; extraArgs: openArray[string] = []): SshConfigResolved =
  ## `ssh -G <host> <extraArgs>` を実行し `core/sshgparse.parseSshG` でパースする。
  ##
  ## **stdout のみをパースする。** stderr には
  ## `Pseudo-terminal will not be allocated because stdin is not a terminal.` が
  ## 混ざることがある（実測確認済み）。`runSsh` がファイルリダイレクト方式で
  ## 両者を分離しているので、ここで `r.stdout` だけを渡せば自然に対処できる。
  let r = runSsh(@["-G", host] & @extraArgs)
  parseSshG(r.stdout)

proc masterCommandLine*(ctlPath, logPath, host: string;
                        extraArgs: openArray[string] = []): seq[string] =
  ## ControlMaster を起動する `/bin/sh -c 'exec ssh ...'` のコマンドライン全体を
  ## 組み立てる。**プロセスの起動自体はしない**（それは hostsession 層の責務）。
  ## adopt 時（既存プロセスへの再接続）の `ps` 出力との照合にも使うので、
  ## 常に決定的な文字列を返す。
  ##
  ## 各オプションの理由（実機検証で確定済み。変更しないこと）:
  ##
  ## - `exec`: `sh` プロセス自身を `ssh` で置き換える。これにより監視対象の
  ##   PID がラッパーの sh ではなく ssh 本体になる（実測確認済み）
  ## - `-M -S <ctlPath>`: ControlMaster として起動し、以後 `-O forward` で
  ##   フォワードを後付けできるようにする
  ## - `-N`: リモートコマンドを実行しない
  ## - `-v`: stderr にエラー分類の材料（`core/errorclass` が使う）を出させる
  ## - `BatchMode=yes`: TTY の無いデーモンで対話プロンプトにハングしない
  ## - `ControlPersist=no`: **これが無いとマスターがバックグラウンドに移行して
  ##   `ssh -f` と同じく PPID=1 に孤児化し、`peekExitCode` で追跡できなくなる。**
  ##   ユーザーの ssh_config に `ControlPersist` が書かれている場合に備えて
  ##   常に明示的に上書きする
  ## - `StreamLocalBindUnlink=yes`: **必須。** `-O cancel` してもソケット
  ##   ファイルは残る（ssh は unlink しない）ため、デフォルトの `no` では
  ##   同じ UDS パスへの再 attach が exit 255 + `Port forwarding failed` で
  ##   **必ず失敗する**（実測確認済み）。マスター再接続後の再 attach で毎回
  ##   通る経路なので、無いと再接続が永久に失敗する
  ## - `StreamLocalBindMask=0177`: forward の UDS を 0600 相当で作らせる
  ## - `ExitOnForwardFailure` は付けない: マスターのコマンドラインに
  ##   `-L`/`-R` を書かず全て `-O forward` で後付けする設計なので、このオプ
  ##   ションが効く経路（起動時の初期フォワード設定）を通らない。付けても
  ##   無意味であり、「1本の forward 失敗がマスターを巻き込まない」性質は
  ##   OpenSSH の実装として既に保証されている
  let sshArgs = @["ssh", "-M", "-S", ctlPath, "-N", "-v",
                  "-o", "BatchMode=yes",
                  "-o", "ControlPersist=no",
                  "-o", "ServerAliveInterval=15",
                  "-o", "ServerAliveCountMax=3",
                  "-o", "ConnectTimeout=10",
                  "-o", "StreamLocalBindMask=0177",
                  "-o", "StreamLocalBindUnlink=yes",
                  host] & @extraArgs
  let inner = "exec " & quoteShellCommand(sshArgs) &
    " >>" & quoteShell(logPath) & " 2>&1"
  @["/bin/sh", "-c", inner]
