## 設定・状態・ランタイムディレクトリの解決。
##
## UDS のパスは `sockaddr_un.sun_path` の長さ制限（macOS 104 / Linux 108 バイト）に収める
## 必要がある。powarder は ControlPath と forward の UDS を両方ランタイムディレクトリに置くので、
## ディレクトリ名を 1 文字・ファイル名を 8 桁 hex に抑え、それでも収まらない場合は
## `/tmp/powarder-<uid>` にフォールバックする。
##
## このモジュールは環境変数とファイルシステムを触るので純粋ではない。
## テスト時は `POWARDER_CONFIG` / `POWARDER_RUNTIME_DIR` / `XDG_*` を差し替えて隔離する。

import std/[os, posix, strutils]

const
  appName* = "powarder"

  maxSunPath* = 104
    ## macOS の `sockaddr_un.sun_path` は 104 バイト。Linux は 108 だが厳しい側に合わせる。

  envConfig* = "POWARDER_CONFIG"
  envRuntimeDir* = "POWARDER_RUNTIME_DIR"
  envStateDir* = "POWARDER_STATE_DIR"

  ctlSubdir* = "c" ## ControlPath 置き場。1 文字なのは sun_path 節約のため
  fwdSubdir* = "f" ## forward の UDS 置き場

func expandHome(p: string): string =
  if p.startsWith("~/"): getHomeDir() / p[2 .. ^1] else: p

# ---------------------------------------------------------------- 設定 / 状態

proc configDir*(): string =
  let xdg = getEnv("XDG_CONFIG_HOME")
  if xdg.len > 0: expandHome(xdg) / appName
  else: getHomeDir() / ".config" / appName

proc configFile*(): string =
  ## `POWARDER_CONFIG` があればそれを優先する。
  let override = getEnv(envConfig)
  if override.len > 0: expandHome(override) else: configDir() / "config.json"

proc localConfigFile*(): string =
  ## カレントディレクトリのプロジェクトローカル設定。`up` / `down` だけが探索する。
  getCurrentDir() / (appName & ".json")

proc stateDir*(): string =
  let override = getEnv(envStateDir)
  if override.len > 0: return expandHome(override)
  let xdg = getEnv("XDG_STATE_HOME")
  if xdg.len > 0: expandHome(xdg) / appName
  else: getHomeDir() / ".local" / "state" / appName

proc stateFile*(): string = stateDir() / "state.json"
proc logsDir*(): string = stateDir() / "logs"
proc tunnelLogPath*(name: string): string = logsDir() / (name & ".log")
proc daemonLogPath*(): string = logsDir() / "daemon.log"

# -------------------------------------------------------------- ランタイム

proc isUsableDir(p: string): bool =
  ## 自分が所有していて他人から書けないディレクトリか。
  ## シンボリックリンク経由の乗っ取りを防ぐため所有者とパーミッションを検証する。
  if not dirExists(p): return false
  var st: Stat
  if lstat(p.cstring, st) != 0: return false
  if not S_ISDIR(st.st_mode): return false
  if st.st_uid != getuid(): return false
  (st.st_mode.cint and 0o077) == 0

proc socketExists*(path: string): bool =
  ## パスが unix domain socket として存在するか。
  ##
  ## **`os.fileExists` を使ってはいけない。** あれは `S_ISREG`（通常ファイル）だけを true に
  ## するので、ソケットに対しては常に false を返す。ControlPath の出現待ち（readiness 判定）や
  ## forward UDS の残骸検出でここを間違えると「ソケットは在るのに無いと判定して延々待つ」
  ## という気付きにくいバグになる。
  ##
  ## 残骸の削除には `os.removeFile` がそのまま使える（内部が `unlink` で、対象が無くても
  ## エラーにならないので存在チェック無しに呼んでよい）。
  var st: Stat
  if lstat(path.cstring, st) != 0: return false
  S_ISSOCK(st.st_mode)

proc longestSocketPath(runtime: string): string =
  ## そのランタイムディレクトリで生成しうる最長の UDS パス。長さ検証に使う。
  runtime / fwdSubdir / repeat('0', 8)

proc runtimeDirCandidates(): seq[string] =
  let override = getEnv(envRuntimeDir)
  if override.len > 0:
    return @[expandHome(override)]

  when defined(linux):
    let xdgRun = getEnv("XDG_RUNTIME_DIR")
    if xdgRun.len > 0 and isUsableDir(xdgRun):
      result.add xdgRun / appName
  else:
    # macOS には XDG_RUNTIME_DIR に相当する標準が無いが、$TMPDIR がユーザー専有で
    # mode 0700 なので代替になる。
    let tmp = getEnv("TMPDIR")
    if tmp.len > 0:
      result.add tmp.strip(chars = {'/'}, leading = false) / appName

  result.add "/tmp" / (appName & "-" & $getuid())

proc runtimeDir*(): string =
  ## 実際に使うランタイムディレクトリ。候補を順に見て、
  ## **UDS パスが sun_path に収まる最初のもの**を選ぶ。
  let candidates = runtimeDirCandidates()
  for c in candidates:
    if longestSocketPath(c).len < maxSunPath:
      return c
  # どれも収まらない場合は最後の候補（/tmp ベース）を返す。呼び出し側が
  # ensureRuntimeDir() で検証して明示的に失敗させる。
  candidates[^1]

proc ipcSocketPath*(): string = runtimeDir() / (appName & ".sock")
proc lockPath*(): string = runtimeDir() / (appName & ".lock")
proc pidPath*(): string = runtimeDir() / (appName & ".pid")

proc controlPath*(fingerprint: string): string =
  ## ControlMaster の制御ソケット。fingerprint の先頭 8 文字だけ使う。
  runtimeDir() / ctlSubdir / fingerprint[0 ..< min(8, fingerprint.len)]

proc forwardSocketPath*(basename: string): string =
  ## ssh に張らせる forward の UDS。`basename` は forwardspec.udsBasename() の結果。
  runtimeDir() / fwdSubdir / basename

# ------------------------------------------------------------------ 作成

proc ensureDir0700(p: string) =
  createDir(p)
  setFilePermissions(p, {fpUserRead, fpUserWrite, fpUserExec})

proc ensureRuntimeDir*() =
  ## ランタイムディレクトリ群を 0700 で用意する。
  ## UDS パスが sun_path に収まらない場合はここで明示的に失敗させる。
  let rt = runtimeDir()
  let longest = longestSocketPath(rt)
  if longest.len >= maxSunPath:
    raise newException(IOError,
      "runtime directory path is too long for a unix socket (" & $longest.len &
      " >= " & $maxSunPath & "): " & rt &
      " — set " & envRuntimeDir & " to a shorter path")
  ensureDir0700(rt)
  ensureDir0700(rt / ctlSubdir)
  ensureDir0700(rt / fwdSubdir)

proc ensureStateDirs*() =
  ensureDir0700(stateDir())
  ensureDir0700(logsDir())

proc ensureConfigDir*() =
  ensureDir0700(configDir())
