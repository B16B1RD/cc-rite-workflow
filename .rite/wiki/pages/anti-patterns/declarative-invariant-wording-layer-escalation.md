---
title: "Declarative invariant の wording 追加は self-meta-conflict trap (fractal pattern は layer を変えて再発する)"
domain: "anti-patterns"
description: "SoT 集約 PR で「両者を集合等価に保つ」等の declarative invariant note を追加すると、note の文言自体が新たな self-meta-conflict 経路を生む。"
created: "2026-05-26T00:30:00Z"
updated: "2026-05-26T00:30:00Z"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260525T164503Z-pr-1143.md"
  - type: "reviews"
    ref: "raw/reviews/20260525T182553Z-pr-1143.md"
  - type: "reviews"
    ref: "raw/reviews/20260525T221531Z-pr-1143.md"
  - type: "fixes"
    ref: "raw/fixes/20260525T164714Z-pr-1143.md"
  - type: "fixes"
    ref: "raw/fixes/20260525T191243Z-pr-1143.md"
  - type: "fixes"
    ref: "raw/fixes/20260525T221902Z-pr-1143.md"
  - type: "fixes"
    ref: "raw/fixes/20260525T233957Z-pr-1143.md"
  - type: "fixes"
    ref: "raw/fixes/20260526T000611Z-pr-1143.md"
  - type: "fixes"
    ref: "raw/fixes/20260526T001800Z-pr-1143.md"
tags: []
confidence: high
---

# Declarative invariant の wording 追加は self-meta-conflict trap (fractal pattern は layer を変えて再発する)

## 概要

SoT 集約 PR で「両者を集合等価に保つ」等の declarative invariant note を追加すると、note の文言自体が新たな self-meta-conflict 経路を生む。declarative wording を追加するほど new claim ↔ 実装 gap が増える escalation 構造。さらに「完全収束」declare は局所最適にすぎず、別 expertise の reviewer が別 layer で fact-check した瞬間に fractal pattern が再発する (Premature fractal convergence declaration)。

## 詳細

起点事例で 10 cycle にわたり実測。fractal pattern が cycle ごとに **異なる layer** で再発する mode を確立。

### Layer 1: Invariant wording 層 (cycle 4-7)

cycle 4 で導入した Maintenance Invariant note が連鎖 finding を生成:

- **cycle 4**: "bidirectional set equality" claim → 実際の状態 (forward only) と乖離 → 6 件連鎖 (HIGH ×2 / MEDIUM ×2 / LOW-MEDIUM ×1 / LOW ×1)
  - §B → §A typo
  - column schema (言語 grouping) 破壊 (旧版表現 row 追加で)
  - `Previously` 単独 regex の precision 不足
  - MVP scope 宣言と累積 addition の drift
- **cycle 5**: 6 件全件を 1 commit で fix。forward-subset semantics で reverse 方向の overreach を制御
- **cycle 6**: SoT 表に「カテゴリ」column 追加 (3 列構造で subgroup ↔ category を 1 対 1 化) + mechanical parity test 追加。declarative invariant の wording を追加すると test が何を検証しているかという新しい declarative 層が増えた
- **cycle 7**: `1 対 1 mapping` claim が SoT row 7 composite + 日本語版 exemption と矛盾 → cross-axis declarative mapping を **削除** し parity test の green を contract に置換することで構造解消

### Layer 2: 外周完全性 gap (cycle 8-9)

cycle 8 で両 reviewer が `評価=可、0 findings` に到達した直後、boundary 推奨 1 件 (Maintenance Note の `\s` portable 言及欠落) を user 判断で current-pr 化。1 行追記 fix。

### Layer 3: Portability factual claim 層 (cycle 9-10)

cycle 9 で boundary 推奨吸収のために追加した「`\s` portability 言及」が、 `\d` と `\s` を symmetric に framing する誤った記述になっており、tech-writer が独立検証で 2 件 MEDIUM/current-pr finding として検出。実測検証: GNU grep -E は `\d` を literal `d` として扱い (PCRE 拡張)、`\s` のみ GNU 拡張として whitespace match。両者は **extension layer が異なる**。symmetric framing を非対称 (PCRE vs GNU) framing に修正。

### Sub-pattern: Gate-self-misrepresentation (cycle 2)

declarative gate の "防御の最終層" や "post-hoc gate がある" 等の表現が実装と乖離していると、Claude が gate を skip する根拠に逆用される。起点事例の cycle 2 で `Phase 3.1.1 が防御の最終層` 表現が `distributed-fix-drift-check.sh` の検出範囲 (構造的 drift のみ catch) と乖離していたため、コメント原則違反は実際には Phase 3.1.1 で検出されないにも関わらず "fallback あり" の誤解を生むため MEDIUM 検出。declarative gate 文言の「backstop 存在主張」は実装と一致しているか mandatory check すべき。

### 教訓

1. **Wording 追加 ≠ 不変条件強化**: declarative invariant の wording を追加すればするほど new claim ↔ 実装 gap の機会が増える。長期安定性のためには cross-axis declarative mapping を **書かない** ことが鍵
2. **Mechanical test の green を contract に**: 文書上の宣言から実行可能な test に格上げすることで、wording 層の self-referential loop を構造的に断つ ([[mechanical-test-over-declarative-invariant]] 参照)
3. **Premature fractal convergence declaration を避ける**: 異なる expertise layer の reviewer 全員が同意するまで「完全収束」declare しない。独立検証で 1 人でも反論があれば、まだ新層が残っている可能性が高い
4. **Gate の backstop 表現は実装と一致させる**: "fallback あり" 表現は LLM agent が gate を skip する根拠に逆用される — 当該 gate を「唯一の防御層」と明示するか、backstop の検出範囲を明示する

## 関連ページ

- [[prose-design-without-backing-implementation]] ([prose-design-without-backing-implementation.md](./prose-design-without-backing-implementation.md))
- [[mechanical-test-over-declarative-invariant]] ([../patterns/mechanical-test-over-declarative-invariant.md](../patterns/mechanical-test-over-declarative-invariant.md))

## ソース

- [PR #1143 cycle 2 review (gate-self-misrepresentation 検出)](../../raw/reviews/20260525T164503Z-pr-1143.md)
- [PR #1143 cycle 2 fix](../../raw/fixes/20260525T164714Z-pr-1143.md)
- [PR #1143 cycle 5 review (fractal escalation, 6 件連鎖)](../../raw/reviews/20260525T182553Z-pr-1143.md)
- [PR #1143 cycle 5 fix](../../raw/fixes/20260525T191243Z-pr-1143.md)
- [PR #1143 cycle 6 review (mergeable + 5 件 scope 外吸収)](../../raw/reviews/20260525T221531Z-pr-1143.md)
- [PR #1143 cycle 9 fix (boundary 推奨吸収)](../../raw/fixes/20260526T000611Z-pr-1143.md)
- [PR #1143 cycle 10 fix (portability factual claim layer の fractal recurrence)](../../raw/fixes/20260526T001800Z-pr-1143.md)
