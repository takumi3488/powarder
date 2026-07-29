## powarder — SSH のローカル/リモートポートフォワードを管理する CLI + 常駐デーモン
##
## エントリポイント。引数をパースして `cli/dispatch` に渡すだけの薄い層に留める。
##
## `cli/` は `daemon/` を import しない（デーモン本体を CLI にリンクする必要が
## ないようにするため、かつ CLI 層をデーモン抜きでテストできるようにするため）。
## `powarder daemon` でデーモン本体を起動する経路だけは両者をつなぐ必要があるので、
## ここで `DaemonRunner` として関数を注入する。

import std/os
import powarder/version
import powarder/cli/argv
import powarder/cli/dispatch
import powarder/daemon/run as daemonRun

export powarderVersion

when isMainModule:
  var args: ParsedArgs
  try:
    args = parseArgv(commandLineParams())
  except ArgvError, ValueError:
    # `dispatch` はパース済みで妥当な `ParsedArgs` を前提にしているので、
    # 引数の不正はここで弾いて使用法エラー（終了コード 2）にする。
    stderr.writeLine("powarder: " & getCurrentExceptionMsg())
    stderr.writeLine("powarder: run 'powarder help' for usage")
    quit(int(ecUsage))

  # `powarder daemon`（サブサブコマンド無し）でフォアグラウンド起動される本体。
  # `--config` と `--profile` はデーモンにも渡す必要があるので引き継ぐ。
  let runDaemonImpl: DaemonRunner = proc (): int =
    daemonRun.runDaemon(daemonRun.DaemonOpts(
      configPath: args.configPath,
      activeProfiles: args.profiles))

  quit(dispatch(args, runDaemonImpl))
