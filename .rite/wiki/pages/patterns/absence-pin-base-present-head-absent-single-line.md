---
type: "patterns"
title: "absence pin (assert_not_grep) は「base に存在・head に不在」の両側を単一行トークンで検証する"
domain: "patterns"
description: "旧文面の除去を固定する assert_not_grep pin は、(1) 複数語を .* で橋渡しすると行指向 grep が複数行に跨る旧文面に構造的にマッチせず常に pass する空虚 pin になる、(2) ERE の literal { } は未エスケープだと strict ERE 実装 (BSD grep / ugrep) で regcomp エラーになる。pin は base に単一行で存在し post-PR に不在の識別トークンで書き、両側を grep で確認してから commit する。"
created: "2026-07-21T18:30:00Z"
updated: "2026-07-28T21:30:00+09:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260721T175725Z-pr-1959.md"
  - type: "fixes"
    ref: "raw/fixes/20260721T175931Z-pr-1959.md"
  - type: "fixes"
    ref: "raw/fixes/20260728T093135Z-pr-2038.md"
tags: ["assert-not-grep", "vacuous-pin", "ere-portability", "test-pin", "fixture-scope"]
confidence: high
---

# absence pin (assert_not_grep) は「base に存在・head に不在」の両側を単一行トークンで検証する

## 概要

旧文面の除去を drift ガードとして固定する `assert_not_grep` pin には 2 つの構造的な罠がある。(1) **空虚 pin**: 2 語を `.*` で橋渡しするパターンは、旧文面が複数行に跨っていた場合、行指向 grep が一度もマッチせず「常に pass する幻のガード」になる（狙った regression を検出できない）。(2) **ERE 可搬性**: パターン内の literal `{...}` を未エスケープで書くと、GNU grep は不正 interval を literal 扱いするが、strict ERE 実装（macOS/BSD grep・ugrep）は regcomp エラー（rc=2）で拒否し suite を偽 FAIL させる。起点事例の cycle 3 で両方が runtime 実証つきで検出された。

## 詳細

### absence pin の正しい revert-test セマンティクス

absence pin が実効であるための条件は 2 つで、**両側を grep で確認してから commit する**:

1. **base に単一行トークンとして存在する** — revert（旧文面の復活）で pin が落ちることの保証。base に存在しないパターンは何も守っていない
2. **post-PR に不在である** — pin が現状で pass することの保証（新文面への誤マッチがないこと）

確認コマンド例:

```bash
git show develop:path/to/file.md | grep -E '<token>'   # base 存在 → 非空であること
grep -E '<token>' path/to/file.md                       # head 不在 → 空であること
```

### トークンの選び方

- 複数行に跨る旧文面には、**行を跨がない単一の識別トークン**（旧文面の先頭句など）を使う。「二行形・一行形いずれの regression も検出できる」トークンが理想
- `{placeholder}` literal を含む pin は `\{placeholder\}` とエスケープする（ERE で `\{` はリテラル中括弧。GNU / BSD / ugrep すべてで well-defined）

### 検証は mutation で

pin の非空虚性は「守っている行をストリーム上で削除（または旧文面を復活）して pin が落ちるか」の mutation で実証できる。pass し続ける pin は theater。

## 関連ページ

- [Test pin protection theater: 「N site pin」claim と実 assert の gap が regression 検出を破壊する](../anti-patterns/test-pin-protection-theater.md)
- [HINT-specific 文言 pin で case arm 削除 regression を検知する](../patterns/hint-specific-assertion-pin.md)
- [全称主張の散文（排他性・網羅性）は経路追加で偽化する — 旧文面 grep 全数洗い + 原因中立化 + not_grep pin](../heuristics/universal-claim-prose-invalidated-by-path-addition.md)

> **補強**: 空虚 pin には**第 3 の軸**がある — 本ページが扱う「複数行に跨る旧文面」「ERE 未エスケープ」に加え、**その run の fixture に対象が存在しない**ケース。直前の run のログを読む形の `assert_not_grep` は、間に別のテストを挿入した瞬間に fixture がずれて恒真化する。対処（自前 run + positive control）は [assert_not_grep は「対象が fixture に存在する」ことを前提にしないと恒真になる](../anti-patterns/assert-not-grep-vacuous-without-fixture-scope.md) を参照。

## ソース

- [PR #1959 review cycle 3 (空虚 pin + ERE 未エスケープの runtime 実証)](../../raw/reviews/20260721T175725Z-pr-1959.md)
- [PR #1959 fix cycle 3 (単一行トークン化 + エスケープ統一)](../../raw/fixes/20260721T175931Z-pr-1959.md)
- [PR #2038 fix results (cycle 4) — fixture スコープ由来の恒真化](../../raw/fixes/20260728T093135Z-pr-2038.md)
