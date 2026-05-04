---
title: "Markdown 大規模圧縮 refactor 時の heading hierarchy skip"
domain: "anti-patterns"
created: "2026-05-04T06:50:00Z"
updated: "2026-05-04T09:50:00Z"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260504T062954Z-pr-808.md"
  - type: "reviews"
    ref: "raw/reviews/20260504T090515Z-pr-809.md"
tags: ["markdown", "refactor", "heading", "compression", "review-finding", "self-application"]
confidence: high
---

# Markdown 大規模圧縮 refactor 時の heading hierarchy skip

## 概要

Markdown 文書を大幅圧縮 (例: 734 → 334 行、-55%) する refactor では、セクション削除・統合の過程で heading level (h2 → h3 → h4) の連続性が意図せず崩れ、`## → ####` のような skip が発生しやすい。圧縮後の heading hierarchy を機械的に検証する gate を持たないと silent regression として landed する。

## 詳細

### 観測 (PR #808 / Issue #803)

- `commands/issue/create.md` を 734 → 334 行 (-55%) に圧縮するスリム化 PR で、h2 → h4 skip が **3 箇所** 発生した
- いずれも reviewer (prompt-engineer / code-quality) の cycle 1 review で検出され、cycle 2 fix で復元
- 直接の原因は intermediate h3 セクションを「Moved (Issue #N PR M/8)」 stub に置換する過程で h3 heading 自体を削除し、配下の h4 が parent なしで残った経路

### 失敗 mode

| ステージ | 失敗 |
|---------|------|
| 計画 | 圧縮対象セクションごとの heading level 計画を立てない |
| 実装 | h3 を 1 行 stub 化する際に heading 行 (`### ...`) を本文と一緒に削除 |
| 検証 | 圧縮後 markdown の heading 構造を grep / linter で検査しない |

### 検出策

- **diff レベル**: `git diff -U0 | grep -E '^[-+]#'` で削除/追加された heading 行を一覧し、level 連続性を目視確認
- **post-state lint**: `awk '/^#+ /{print NR": "$0}' <file>` で全 heading を抽出し、level の jump (差 ≥2) を機械検出
- **review checklist**: 大規模圧縮 PR の AC に「heading hierarchy skip 0 件」を含める

### 関連する周辺観測 (PR #808 cycle 1)

1. **Inline pack vs scannability**: 行数制約 (AC-1) を満たすために critical な MUST-execute list (本 PR では Mode B Defense 6 項目) を inline pack 化すると、scannability を犠牲にする。MUST-execute list は line ceiling より scannability を優先する判断基準が必要
2. **野心目標 vs 現実着地点 gap**: AC-1 の野心目標 (≤250) と計画段階で承認された現実着地点 (280-320) の gap を、最終結果がさらに超過する経路 (本 PR では 334 行) がある。野心目標は承認時に「最終結果が現実着地点を超過した場合の handling」も同時合意する必要

### Self-application 実証 (PR #809 / Issue #805)

PR #808 で確立された本経験則の **直後の同種 refactor PR (#809: create-interview.md 511→331 行 -35% スリム化) で、自己 review が予防対象を実測した**:

- Phase 0.5 直下の `EDGE-5` および Interview Flow 直下の `EDGE-2` が h4 で記述されており、h2→h4 skip が 1 箇所発生していた (元から存在した skip だが、大規模圧縮 refactor の機を捉えて修正)
- 本 PR の Self-Review Phase で reviewer (prompt-engineer / code-quality) が PR #808 の経験則を適用し、`h4 → h3` 格上げで連続性を復元
- **大規模圧縮 PR 自身が PR #808 経験則の予防対象であること** を実証 — 経験則 wiki の self-application が次 PR cycle で再現可能な防御層として機能した最初の事例

### Implication: 経験則の累積 self-application 効果

| 段階 | 内容 |
|------|------|
| PR #808 (確立) | 圧縮 refactor で 3 箇所の h2→h4 skip を実測、経験則化 |
| PR #809 (self-apply) | 同 series の sibling refactor で 1 箇所の既存 skip を検出・修正 |
| 一般化 | 大規模 refactor を含む PR series では、後続 PR で sibling file 全体を heading hierarchy 検査の対象に含めると、既存の latent skip も併せて修正できる |

**canonical 防御 (累積)**:
- (a) 大規模圧縮 PR の AC に「heading hierarchy skip 0 件」を必ず含める (PR #808 で確立)
- (b) sibling refactor PR では、refactor scope 内で **既存の (本 PR が新規導入したのではない) skip も** 検出・修正対象に含める方針を Self-Review で明示する (PR #809 で確立)
- (c) 機械検証 gate (`awk '/^#+ /{print NR": "$0}'`) を pre-commit hook 化することで、refactor scope 外でも継続的に検出可能にする (将来 follow-up)

## 関連ページ

- [Markdown fence balance pre-commit check](../patterns/markdown-fence-balance-precommit-check.md)

## ソース

- [PR #808 cycle 1 review findings](../../raw/reviews/20260504T062954Z-pr-808.md)
- [PR #809 review findings (self-application)](../../raw/reviews/20260504T090515Z-pr-809.md)
