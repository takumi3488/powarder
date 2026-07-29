## `powarder/daemon/logstore` のテスト。
##
## ★項目11（copytruncate 検証）がこのモジュールの設計上の核心。
## ssh マスターは `>>logPath`（`O_APPEND`）で開いた fd を握り続けたまま
## 動くため、ローテートは「リネーム」ではなく「コピー + truncate」で
## 行わなければならない。これを間違えると「ローテート後にログが一切
## 増えない」という気付きにくいバグになる（`daemon/logstore.nim` の
## モジュール doc comment を参照）。このテストでは実際に `fmAppend` で
## fd を開いたまま `rotateIfNeeded` を呼び、その fd への書き込みが
## リネームされた `.1` ではなく元のパス（＝新しいログ）に現れることを
## 確認する。

import std/[unittest, os, strutils]
import powarder/daemon/logstore

const testDir = "/tmp/pw-log-rt"

proc setupSuite() =
  removeDir(testDir)
  createDir(testDir)

setupSuite()

# ---------------------------------------------------------------------------
# 9. サイズ未満ならローテートしない
# ---------------------------------------------------------------------------

suite "rotateIfNeeded: サイズ未満":
  test "サイズが上限以下ならローテートせず false を返す":
    let path = testDir / "under.log"
    writeFile(path, "x".repeat(50))

    check not rotateIfNeeded(path, maxBytes = 100)
    check not fileExists(path & ".1")
    check getFileSize(path) == 50

  test "ファイルが存在しなければ false を返す":
    let path = testDir / "does-not-exist.log"
    removeFile(path)
    check not rotateIfNeeded(path, maxBytes = 100)

# ---------------------------------------------------------------------------
# 10. サイズ超過でローテートし、.1 ができて元ファイルが0バイトになる
# ---------------------------------------------------------------------------

suite "rotateIfNeeded: サイズ超過":
  test "サイズが上限を超えていればローテートし、.1 ができて元ファイルが0バイトになる":
    let path = testDir / "over.log"
    writeFile(path, "y".repeat(200))

    check rotateIfNeeded(path, maxBytes = 100)
    check fileExists(path & ".1")
    check readFile(path & ".1") == "y".repeat(200)
    check getFileSize(path) == 0

# ---------------------------------------------------------------------------
# 11. ★copytruncate であることの検証
# ---------------------------------------------------------------------------

suite "copytruncate 検証":
  test "ローテート前から O_APPEND で開いていた fd への書き込みが、リネームされた.1ではなく元のパス（新しいログ）に現れる":
    let path = testDir / "append.log"
    writeFile(path, "z".repeat(200))

    # ssh マスターが持ち続ける `>>logPath` の fd を模擬する。
    # Nim の `fmAppend` は `O_APPEND` で開く。
    var appendFd: File
    check open(appendFd, path, fmAppend)

    check rotateIfNeeded(path, maxBytes = 100)
    check getFileSize(path) == 0
    check readFile(path & ".1") == "z".repeat(200)

    # ローテート前から開いていた fd で書き込む。inode が同じであれば
    # （＝リネームではなくコピー+truncate であれば）元のパスに現れる。
    appendFd.write("AFTER-ROTATE\n")
    appendFd.flushFile()
    appendFd.close()

    check "AFTER-ROTATE" in readFile(path)
    check "AFTER-ROTATE" notin readFile(path & ".1")

# ---------------------------------------------------------------------------
# 12. 世代が3つを超えると最古が消える
# ---------------------------------------------------------------------------

suite "世代管理":
  test "3世代を超えると最古の世代が消える":
    let path = testDir / "gens.log"

    writeFile(path, "A".repeat(200))
    check rotateIfNeeded(path, maxBytes = 100, generations = 3)
    check readFile(path & ".1") == "A".repeat(200)

    writeFile(path, "B".repeat(200))
    check rotateIfNeeded(path, maxBytes = 100, generations = 3)
    check readFile(path & ".1") == "B".repeat(200)
    check readFile(path & ".2") == "A".repeat(200)

    writeFile(path, "C".repeat(200))
    check rotateIfNeeded(path, maxBytes = 100, generations = 3)
    check readFile(path & ".1") == "C".repeat(200)
    check readFile(path & ".2") == "B".repeat(200)
    check readFile(path & ".3") == "A".repeat(200)

    writeFile(path, "D".repeat(200))
    check rotateIfNeeded(path, maxBytes = 100, generations = 3)
    check readFile(path & ".1") == "D".repeat(200)
    check readFile(path & ".2") == "C".repeat(200)
    check readFile(path & ".3") == "B".repeat(200)
    check not fileExists(path & ".4")
    # 最古（"A" 世代）はどこにも残っていない
    check "A" notin readFile(path & ".1")
    check "A" notin readFile(path & ".2")
    check "A" notin readFile(path & ".3")

# ---------------------------------------------------------------------------
# 13. rotateAll がディレクトリ内の複数ファイルを処理し件数を返す
# ---------------------------------------------------------------------------

suite "rotateAll":
  test "*.log だけをローテートし、ローテートした件数を返す":
    let dir = testDir / "rotateall"
    removeDir(dir)
    createDir(dir)

    writeFile(dir / "a.log", "1".repeat(200)) ## 超過 -> ローテートされる
    writeFile(dir / "b.log", "2".repeat(200)) ## 超過 -> ローテートされる
    writeFile(dir / "c.log", "3".repeat(10)) ## 未満 -> ローテートされない
    writeFile(dir / "not-a-log.txt", "4".repeat(200)) ## *.log にマッチしない

    let rotated = rotateAll(dir, maxBytes = 100)

    check rotated == 2
    check fileExists(dir / "a.log.1")
    check fileExists(dir / "b.log.1")
    check not fileExists(dir / "c.log.1")
    check not fileExists(dir / "not-a-log.txt.1")
    check getFileSize(dir / "a.log") == 0
    check getFileSize(dir / "b.log") == 0
    check getFileSize(dir / "c.log") == 10

  test "存在しないディレクトリは 0 を返す（クラッシュしない）":
    check rotateAll(testDir / "no-such-dir") == 0

# ---------------------------------------------------------------------------
# 後片付け
# ---------------------------------------------------------------------------

removeDir(testDir)
