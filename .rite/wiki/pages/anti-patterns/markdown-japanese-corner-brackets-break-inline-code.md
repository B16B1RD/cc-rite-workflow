---
title: "Markdown inline code を Japanese corner brackets 「!」 に置換すると LLM 提示時 semantic interpretation が劣化する"
domain: "anti-patterns"
created: "2026-04-30T01:58:00+00:00"
updated: "2026-04-30T01:58:00+00:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260430T013507Z-pr-688.md"
tags: []
confidence: medium
---

# Markdown inline code を Japanese corner brackets 「!」 に置換すると LLM 提示時 semantic interpretation が劣化する

## 概要

Markdown 文書内で本来 backtick inline code (`` `!` ``) で囲うべき記号や演算子を、Japanese corner brackets (`「!」` / `「//!」`) に置換する pattern は、(a) Markdown renderer で inline code の monospace / 灰背景表示が消失して可読性が劣化、(b) LLM が prompt として読む際に「コード片」としての semantic boundary が失われて解釈が劣化、という 2 段の failure mode を引き起こす。tech-writer / wiki/lint reviewer が cycle 13 で 2 ファイル同時に検出した新 anti-pattern クラス。

## 詳細

### 失敗形態

PR #688 cycle 13 self-dogfood レビューで F-01 (`tech-writer.md:43`) と F-02 (`wiki/lint.md:1294`) として検出: 本来 `` `!` `` / `` `//!` `` と書くべき記号が `「!」` / `「//!」` に置換されていた。Markdown としては valid だが、(1) 表示 layer で inline code の monospace 表示が消失、(2) LLM が prompt token 上で「これはコード片」という semantic 境界を認識できない。

### Canonical 表記

| 場面 | 推奨 | 非推奨 |
|------|------|--------|
| 演算子・記号 | `` `!` `` `` `//!` `` | 「!」 「//!」 |
| 短いコード片 | `` `set -e` `` | 「set -e」 |
| ファイル拡張子 / glob | `` `*.md` `` | 「*.md」 |
| キーワード / 予約語 | `` `null` `` `` `false` `` | 「null」 「false」 |

### 検出手段

- 文書内で全角 corner brackets `「` / `」` を grep し、その内部が記号 / 演算子 / 短いコード片であれば backtick への置換を提案する pre-commit lint rule として実装可能
- 累積対策 PR では tech-writer / wiki:lint reviewer の cycle scope に「inline code 表記揺れ」を明示的に組み込む

### 修正パターン

```
# Before
`「//!」` rule
# After
`` `//!` `` rule
```

embedded backtick を含む inline code は double-backtick で囲むのが canonical Markdown 仕様。

## 関連ページ

- [Identity / reference document の用語統一は『単語 X』ではなく『文脈類義語群全体』を対象にする](../heuristics/identity-reference-documentation-unification.md)

## ソース

- [PR #688 review 記録 (cycle 13 F-01 / F-02 検出)](../../raw/reviews/20260430T013507Z-pr-688.md)
