---
title: "Markdown 大規模圧縮 refactor 時の heading hierarchy skip"
domain: "anti-patterns"
created: "2026-05-04T06:50:00Z"
updated: "2026-05-04T06:50:00Z"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260504T062954Z-pr-808.md"
tags: ["markdown", "refactor", "heading", "compression", "review-finding"]
confidence: medium
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

## 関連ページ

- [Markdown fence balance pre-commit check](../patterns/markdown-fence-balance-precommit-check.md)

## ソース

- [PR #808 cycle 1 review findings](../../raw/reviews/20260504T062954Z-pr-808.md)
