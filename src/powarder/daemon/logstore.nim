## Log rotation for tunnel logs (M6).
##
## IMPORTANT: the most critical trap: the ssh master is started via
## `/bin/sh -c 'exec ssh ... >>logPath 2>&1'` (see
## `daemon/muxclient.masterCommandLine`), and **the shell keeps holding the
## fd it opened with `>>` (`O_APPEND`)**. Since an fd points to an inode,
## **even if the log file is renamed, ssh keeps writing to the old inode,
## and nobody writes to the new `logPath`.**
##
## Therefore we adopt `logrotate`'s `copytruncate` scheme:
## 1. shift the generations (`.2` -> `.3`, `.1` -> `.2`)
## 2. **"copy" the current log to `.1`** (not a rename)
## 3. **open the current log with `open(path, fmWrite)`, close it
##    immediately, and truncate it to 0 bytes via `O_TRUNC`** (this just
##    reopens the same inode and truncates it; it does not recreate the
##    inode itself)
##
## Since ssh's fd keeps pointing at the same inode and is `O_APPEND`, the
## next write lands at the end (= byte 0, after the truncate). **If this
## is ever changed in the future to "let's rename instead of copy, since
## copying is wasteful", ssh will keep writing to the old (now unwatched)
## `.1`, turning into a hard-to-notice bug where "the log never grows
## again after rotation." Do not change this.**

import std/os

const
  maxLogBytes* = 5 * 1024 * 1024 ## 5MB
  maxLogGenerations* = 3         ## keep 3 generations: `.1` `.2` `.3`

proc shiftGenerations(path: string; generations: int) =
  ## Shifts generations by renaming, in the order `.{generations-1}` ->
  ## `.{generations}`, ..., `.1` -> `.2`. **If this is not processed in
  ## descending order (starting from the largest generation number), the
  ## overwrite order gets mixed up and multiple generations collapse into
  ## the same content** (moving `.1` to `.2` first loses the original
  ## `.2` content that was supposed to be processed afterward).
  ##
  ## If the oldest generation (`.generations`) already exists, `moveFile`'s
  ## rename overwrites it and it is naturally discarded (POSIX's
  ## `rename(2)` overwrites the destination even if it already exists.
  ## Just in case, we remove it beforehand with `removeFile`).
  for gen in countdown(generations, 2):
    let src = path & "." & $(gen - 1)
    let dst = path & "." & $gen
    if fileExists(src):
      removeFile(dst)
      moveFile(src, dst)

proc rotateIfNeeded*(path: string; maxBytes = maxLogBytes;
    generations = maxLogGenerations): bool =
  ## If `path`'s size exceeds `maxBytes`, rotates it and returns `true`.
  ## If the file doesn't exist, or its size is at or below the limit,
  ## does nothing and returns `false`.
  if not fileExists(path):
    return false
  let size =
    try: getFileSize(path)
    except OSError: return false
  if size <= maxBytes.BiggestInt:
    return false

  shiftGenerations(path, generations)

  # IMPORTANT: the core of copytruncate: copy, not rename (see the module
  # doc comment).
  removeFile(path & ".1") ## When generations == 1, shiftGenerations does
                          ## not move `.1` out of the way, so we explicitly
                          ## remove it before overwriting (`copyFile` itself
                          ## also overwrites, but this makes the intent
                          ## explicit).
  copyFile(path, path & ".1")

  # Reopen the same inode and truncate it to 0 bytes via `O_TRUNC`
  # (`fmWrite` opens an existing file by truncating it. It does not
  # recreate the file, so the inode does not change).
  var f: File
  if open(f, path, fmWrite):
    f.close()

  true

proc rotateAll*(dir: string; maxBytes = maxLogBytes;
    generations = maxLogGenerations): int =
  ## Checks every `*.log` directly under `dir` and returns the count of
  ## files that were rotated. Generation files that have already been
  ## rotated (e.g. `*.log.1`) do not match the `*.log` glob, so they are
  ## not targeted.
  result = 0
  if not dirExists(dir):
    return 0
  for path in walkFiles(dir / "*.log"):
    if rotateIfNeeded(path, maxBytes, generations):
      inc result
