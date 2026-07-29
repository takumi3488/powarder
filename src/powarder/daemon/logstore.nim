## トンネルログのローテーション（M6）。
##
## ★最重要の罠: ssh マスターは `/bin/sh -c 'exec ssh ... >>logPath 2>&1'`
## （`daemon/muxclient.masterCommandLine` を参照）で起動され、**シェルが
## `>>`（`O_APPEND`）で開いた fd を持ち続ける**。fd は inode を指すので、
## **ログファイルをリネームしても ssh は古い inode に書き続け、新しい
## `logPath` には誰も書かない。**
##
## したがって `logrotate` の `copytruncate` 方式を採る:
## 1. 世代をずらす（`.2` -> `.3`、`.1` -> `.2`）
## 2. **現在のログを `.1` に「コピー」する**（リネームではない）
## 3. **現在のログを `open(path, fmWrite)` して即座に閉じ、`O_TRUNC` で
##    0 バイトにする**（同じ inode を開き直して truncate するだけで、
##    inode 自体を作り直すわけではない）
##
## ssh の fd は同じ inode を指し続け `O_APPEND` なので、次の write は
## （truncate 後の）末尾 = 0 バイト目から書かれる。**将来「コピーは無駄
## だからリネームにしよう」と変更すると、ssh が古い（もう誰も見ない）
## `.1` に書き続けるようになり、「ローテート後にログが一切増えない」
## という気付きにくいバグになる。変更しないこと。**

import std/os

const
  maxLogBytes* = 5 * 1024 * 1024 ## 5MB
  maxLogGenerations* = 3         ## `.1` `.2` `.3` の3世代を保持

proc shiftGenerations(path: string; generations: int) =
  ## `.{generations-1}` -> `.{generations}` 、... 、`.1` -> `.2` の順に
  ## リネームで世代をずらす。**降順（大きい世代番号から）に処理しないと、
  ## 上書きの順序を誤って複数世代が同じ内容に潰れてしまう**（`.1` を先に
  ## `.2` へ動かすと、後で処理するはずだった元の `.2` の内容を見失う）。
  ##
  ## 最古の世代（`.generations`）が既に存在する場合は `moveFile` の
  ## rename が上書きして自然に破棄される（POSIX の `rename(2)` は宛先が
  ## 既存でも上書きするため。念のため `removeFile` で先に外しておく）。
  for gen in countdown(generations, 2):
    let src = path & "." & $(gen - 1)
    let dst = path & "." & $gen
    if fileExists(src):
      removeFile(dst)
      moveFile(src, dst)

proc rotateIfNeeded*(path: string; maxBytes = maxLogBytes;
    generations = maxLogGenerations): bool =
  ## `path` のサイズが `maxBytes` を超えていればローテートして `true` を
  ## 返す。ファイルが無い、またはサイズが上限以下なら何もせず `false`。
  if not fileExists(path):
    return false
  let size =
    try: getFileSize(path)
    except OSError: return false
  if size <= maxBytes.BiggestInt:
    return false

  shiftGenerations(path, generations)

  # ★ copytruncate の核心: リネームではなくコピーする（モジュール doc
  # comment を参照）。
  removeFile(path & ".1") ## generations == 1 のときは shiftGenerations が
                          ## `.1` をどかさないので、上書き前に明示的に外す
                          ## （`copyFile` 自体も上書きするが、意図を明確にする）。
  copyFile(path, path & ".1")

  # 同じ inode を開き直して `O_TRUNC` で 0 バイトにする（`fmWrite` は
  # 既存ファイルを truncate して開く。ファイルを作り直すわけではないので
  # inode は変わらない）。
  var f: File
  if open(f, path, fmWrite):
    f.close()

  true

proc rotateAll*(dir: string; maxBytes = maxLogBytes;
    generations = maxLogGenerations): int =
  ## `dir` 直下の `*.log` を全部チェックし、ローテートした件数を返す。
  ## 既にローテート済みの世代ファイル（`*.log.1` 等）は `*.log` の glob に
  ## マッチしないので対象にならない。
  result = 0
  if not dirExists(dir):
    return 0
  for path in walkFiles(dir / "*.log"):
    if rotateIfNeeded(path, maxBytes, generations):
      inc result
