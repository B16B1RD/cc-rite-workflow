---
type: "anti-patterns"
title: "assert_not_grep は「対象が fixture に存在する」ことを前提にしないと恒真になる — positive control を対で置く"
domain: "anti-patterns"
description: "「掴んではいけない対象を掴まない」型の否定 assertion は、その run の fixture に対象が存在しなければ実装が何をしても pass する。直前の run のログを読む形だと、間に別のテストを挿入した瞬間に fixture がずれて恒真化する。各 assertion 群の直前に自前 run を置き、「掴むべきものを掴む」positive control を対で置く。"
created: "2026-07-28T21:30:00+09:00"
updated: "2026-07-28T21:30:00+09:00"
sources:
  - type: "fixes"
    ref: "raw/fixes/20260728T093135Z-pr-2038.md"
  - type: "reviews"
    ref: "raw/reviews/20260728T081222Z-pr-2038.md"
tags: []
confidence: high
---

# assert_not_grep は「対象が fixture に存在する」ことを前提にしないと恒真になる — positive control を対で置く

## 概要

`assert_not_grep "$LOG" 'pattern'` 型の否定 assertion は、**その run の入力に対象が含まれていなければ、実装が何をしても pass する**。「存在しないものを掴まなかった」ことしか確認していないためで、守っているつもりの不変条件を一切固定していない。

危険なのは、この恒真化が**テストの追加・並べ替えという無関係な編集で発生する**点。assertion が直前の run のログを読む形になっていると、間に別のテストを挿入した瞬間に読む対象が変わる。

## 詳細

### 実例

「引用付き末尾 sentinel を持つ人間コメント（id=96）を PATCH しない」ことを固定する assertion があった。

```bash
# 直前の run が残した $GH_LOG を読む
assert_not_grep "id=96 を PATCH しない" "$GH_LOG" '^api repos/.*/comments/96 -X PATCH'
```

しかし直前の run は別の fixture（id=21 と id=11 のみ、**id=96 を含まない**）を使っていた。テストヘルパーは run ごとにログを truncate するため、id=96 を含む run のログは既に失われている。

**述語を退行させて helper が実際に id=96 を PATCH する状態を作っても、この assertion は pass し続けた。**

```
述語を endswith へ退行 → 388/0 が 381/7 になるが、当該 assertion は ✅ のまま
（落ちたのは別の TC のみ）
```

皮肉なことに、6 行上の別テストには「直前 run の変数に依存しないよう自前で run する（間に別 TC が挿入されても壊れない）」という規律がコメントで明記されていた。**その規律を上のテストに適用したことで、下のテストが壊れた。**

### 対処

```bash
# 1. 各 assertion 群の直前に自前 run を置く（対象を含む fixture を明示指定）
GH_LOOKUP_JSON="$FIXTURE_WITH_ID96" run_helper ...

# 2. 否定 assertion
assert_not_grep "id=96 を PATCH しない" "$GH_LOG" '^api .*/comments/96 -X PATCH'

# 3. positive control を対で置く（否定が恒真でないことを固定）
assert_grep "canonical な id=13 を PATCH する" "$GH_LOG" '^api .*/comments/13 -X PATCH'
```

positive control は「除外側が全滅して否定が恒真になる」変異を捕捉する。除外ロジックが壊れて**何も掴まなくなった**場合、否定だけなら pass するが positive control は落ちる。

### 検出方法

`assert_not_grep` を書いたら、**その run の fixture に対象が実在するか**を確認する。機械化するなら、否定 assertion の直前に「同 run の fixture に当該対象が存在する」ことを確かめる薄いラッパを用意する。

より確実なのは mutation。**否定が守っているはずの不変条件を壊す変異**を当てて、その assertion が落ちるかを実測する。落ちなければ恒真である。

### 関連する恒真化

同じ PR で、否定ではないが同型の問題が別の pin にもあった。

- **pin のラベルと検査対象がずれる**: 「生成行を pin した」と称しながら実際は**変数代入行**を検査していた。生成文を削除しても緑のまま
- **canonical 完全一致 pin が非対称を正解として固定する**: drift 検出のために置いた完全一致 pin が、片側だけ更新された文言を canonical として固定し、**非対称そのものを検出不能にしていた**

いずれも「pin が謳う保証」と「実際の検査対象」を 1 語ずつ照合すれば見つかる。

## 関連ページ

- [absence pin (assert_not_grep) は「base に存在・head に不在」の両側を単一行トークンで検証する](../patterns/absence-pin-base-present-head-absent-single-line.md)
- [pin を足す「前」に mutation を当てると、pin の要否と有効性を分離して判定できる](../patterns/mutation-before-pin-separates-necessity-from-efficacy.md)
- [テストヘルパーの awk flip-flop レンジは start pattern をコード行に一意なプレフィックスでアンカーする](../patterns/awk-flip-flop-range-start-pattern-anchoring.md)

## ソース

- [PR #2038 fix results (cycle 4)](../../raw/fixes/20260728T093135Z-pr-2038.md)
- [PR #2038 review results (cycle 2)](../../raw/reviews/20260728T081222Z-pr-2038.md)
