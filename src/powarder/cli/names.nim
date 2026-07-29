## ad-hoc な `powarder run` で `--name` が省略されたときの自動命名。
##
## docker が付ける "boring_wozniak" のような「形容詞-名詞」形式に倣う。
## `randomName()` は `std/random` の**グローバル**な既定 RNG を使う。呼び出す
## たびに `randomize()`（現在時刻でグローバル状態を再シードする）を呼んでから
## 使うため、この呼び出し位置がそのまま「毎回違う名前になる」ことの根拠になる。
## CLI は 1 起動につき `run` を高々数回しか呼ばないため、毎回再シードするコストは
## 無視できる。
##
## テストで決定的な結果が必要な場合は `randomName(seed)` を使うこと。こちらは
## グローバル状態を一切触らない専用の `Rand` を都度 `initRand(seed)` で作るので、
## 他のテスト・他のモジュールが使うグローバル RNG の状態を汚さない。
##
## このモジュールは呼び出しごとに RNG の状態を進める（`randomName()` は
## グローバル状態、`randomName(seed)` はローカル変数）以外の I/O を行わない。

import std/random

const
  adjectives = [
    "brave", "calm", "clever", "cosmic", "curious", "daring", "eager", "fancy",
    "feisty", "fierce", "gentle", "giant", "happy", "hasty", "humble", "jolly",
    "keen", "kind", "lively", "lonely", "loyal", "lucky", "mellow", "merry",
    "mighty", "nimble", "noble", "patient", "plucky", "proud", "quiet", "quick",
    "rapid", "sharp", "shiny", "silent", "sly", "snappy", "solid", "sturdy",
    "sunny", "swift", "tidy", "tiny", "witty",
  ]

  nouns = [
    "otter", "falcon", "badger", "heron", "panther", "sparrow", "walrus",
    "beetle", "gopher", "jaguar", "kestrel", "lemur", "marmot", "ocelot",
    "penguin", "quokka", "raven", "serval", "tapir", "urchin", "viper",
    "weasel", "yak", "zebra", "bison", "cobra", "dingo", "eagle", "ferret",
    "gecko", "hedgehog", "ibex", "jackal", "koala", "lynx", "mongoose", "newt",
    "orca", "puffin", "quail", "rabbit", "salamander", "toucan", "vulture",
    "wombat",
  ]

proc joinName(adjIdx, nounIdx: int): string =
  adjectives[adjIdx] & "-" & nouns[nounIdx]

proc randomName*(seed: int): string =
  ## 決定的版（テスト用）。同じ `seed` からは常に同じ名前を返す。
  ## グローバルな RNG 状態には一切触れない専用の `Rand` を使う。
  var rng = initRand(seed.int64)
  joinName(rng.rand(adjectives.high), rng.rand(nouns.high))

proc randomName*(): string =
  ## 非決定的版。`std/random` のグローバル既定 RNG を現在時刻で再シードしてから
  ## 使う（モジュール doc comment 参照）。
  randomize()
  joinName(rand(adjectives.high), rand(nouns.high))
