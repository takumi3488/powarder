## Tests for `powarder/daemon/logstore`.
##
## IMPORTANT: item 11 (copytruncate verification) is the design core of
## this module. The ssh master keeps holding the fd it opened with
## `>>logPath` (`O_APPEND`), so rotation has to be done as "copy + truncate"
## rather than "rename". Getting this wrong turns into the hard-to-notice
## bug of "the log never grows again after rotation" (see the module doc
## comment in `daemon/logstore.nim`). This test actually opens an fd with
## `fmAppend`, keeps it open across a call to `rotateIfNeeded`, and
## confirms that a write through that fd shows up at the original path
## (the new log), not at the renamed `.1`.

import std/[unittest, os, strutils]
import powarder/daemon/logstore

const testDir = "/tmp/pw-log-rt"

proc setupSuite() =
  removeDir(testDir)
  createDir(testDir)

setupSuite()

# ---------------------------------------------------------------------------
# 9. No rotation when under the size limit
# ---------------------------------------------------------------------------

suite "rotateIfNeeded: under the size limit":
  test "returns false and does not rotate when size is at or below the limit":
    let path = testDir / "under.log"
    writeFile(path, "x".repeat(50))

    check not rotateIfNeeded(path, maxBytes = 100)
    check not fileExists(path & ".1")
    check getFileSize(path) == 50

  test "returns false if the file doesn't exist":
    let path = testDir / "does-not-exist.log"
    removeFile(path)
    check not rotateIfNeeded(path, maxBytes = 100)

# ---------------------------------------------------------------------------
# 10. Rotates when over the size limit: `.1` is created and the original
#     file becomes 0 bytes
# ---------------------------------------------------------------------------

suite "rotateIfNeeded: over the size limit":
  test "rotates when size exceeds the limit; `.1` is created and the original file becomes 0 bytes":
    let path = testDir / "over.log"
    writeFile(path, "y".repeat(200))

    check rotateIfNeeded(path, maxBytes = 100)
    check fileExists(path & ".1")
    check readFile(path & ".1") == "y".repeat(200)
    check getFileSize(path) == 0

# ---------------------------------------------------------------------------
# 11. IMPORTANT: verifying it's copytruncate
# ---------------------------------------------------------------------------

suite "copytruncate verification":
  test "a write via an fd opened O_APPEND before rotation shows up at the original path (the new log), not the renamed .1":
    let path = testDir / "append.log"
    writeFile(path, "z".repeat(200))

    # Simulates the `>>logPath` fd the ssh master keeps holding on to.
    # Nim's `fmAppend` opens with `O_APPEND`.
    var appendFd: File
    check open(appendFd, path, fmAppend)

    check rotateIfNeeded(path, maxBytes = 100)
    check getFileSize(path) == 0
    check readFile(path & ".1") == "z".repeat(200)

    # Write through the fd that was open before rotation. If the inode is
    # the same (i.e. it was copy+truncate rather than rename), the write
    # shows up at the original path.
    appendFd.write("AFTER-ROTATE\n")
    appendFd.flushFile()
    appendFd.close()

    check "AFTER-ROTATE" in readFile(path)
    check "AFTER-ROTATE" notin readFile(path & ".1")

# ---------------------------------------------------------------------------
# 12. The oldest generation is removed once more than 3 generations exist
# ---------------------------------------------------------------------------

suite "generation management":
  test "the oldest generation is removed once more than 3 generations exist":
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
    # the oldest ("A") generation is nowhere to be found
    check "A" notin readFile(path & ".1")
    check "A" notin readFile(path & ".2")
    check "A" notin readFile(path & ".3")

# ---------------------------------------------------------------------------
# 13. rotateAll processes multiple files in a directory and returns the count
# ---------------------------------------------------------------------------

suite "rotateAll":
  test "rotates only *.log files and returns how many were rotated":
    let dir = testDir / "rotateall"
    removeDir(dir)
    createDir(dir)

    writeFile(dir / "a.log", "1".repeat(200)) ## over the limit -> gets rotated
    writeFile(dir / "b.log", "2".repeat(200)) ## over the limit -> gets rotated
    writeFile(dir / "c.log", "3".repeat(10)) ## under the limit -> not rotated
    writeFile(dir / "not-a-log.txt", "4".repeat(200)) ## doesn't match *.log

    let rotated = rotateAll(dir, maxBytes = 100)

    check rotated == 2
    check fileExists(dir / "a.log.1")
    check fileExists(dir / "b.log.1")
    check not fileExists(dir / "c.log.1")
    check not fileExists(dir / "not-a-log.txt.1")
    check getFileSize(dir / "a.log") == 0
    check getFileSize(dir / "b.log") == 0
    check getFileSize(dir / "c.log") == 10

  test "returns 0 for a directory that doesn't exist (doesn't crash)":
    check rotateAll(testDir / "no-such-dir") == 0

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

removeDir(testDir)
