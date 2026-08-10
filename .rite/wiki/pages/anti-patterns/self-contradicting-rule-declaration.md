---
title: "Self-contradicting rule declaration: 新規ルール宣言時にルール本文自身がルール違反を含む"
domain: "anti-patterns"
description: "新規ルール (Comment Quality Gate / 禁止句リスト等) を declarative gate として宣言する際、当該 gate の本文中にルール違反パターン (line 番号参照 / cycle 番号参照 / 禁止句) が混入する anti-pattern。"
promote: rite-plugin
created: "2026-05-26T00:30:00Z"
updated: "2026-05-26T00:30:00Z"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260525T162232Z-pr-1143.md"
  - type: "fixes"
    ref: "raw/fixes/20260525T162704Z-pr-1143.md"
tags: []
confidence: high
---

# Self-contradicting rule declaration: 新規ルール宣言時にルール本文自身がルール違反を含む

## 概要

新規ルール (Comment Quality Gate / 禁止句リスト等) を declarative gate として宣言する際、当該 gate の本文中にルール違反パターン (line 番号参照 / cycle 番号参照 / 禁止句) が混入する anti-pattern。fractal pattern (累積対策 PR の review-fix loop で fix 自体が drift を導入する) の rule-declaration variant。

## 詳細

起点事例の cycle 1 で実測: `/rite:pr:fix` の Phase 2.3 に追加した Comment Quality Gate blockquote 本文に `line ~3370 周辺の Pre-Commit Drift Lint Gate` という same-file line 番号参照が含まれていた。

- 実 line は 3409 で **40 行 drift**
- 当該 gate がまさに禁止しようとしている `no_line_or_cycle_reference` 原則違反を gate 自身が踏んでいる
- 同 PR で導入された Detection Heuristics (`comment-best-practices.md:382`) も `line NNN` 形式の散文参照を捕捉しないため、本違反は機械的検出からも漏れた

### 防御策

1. **新規ルール declaration の本文に対する self-check**: gate の本文 / blockquote / 説明文を Detection Heuristics regex に対して必ず通す (commit 前 self-grep)
2. **Semantic anchor への置換**: line 番号ではなく Phase ID / section ID で参照する。Phase 3.1.1 / `## Comment Quality Gate` 等
3. **Generator-Reviewer parity**: SoT 集約 PR では生成側 (LLM 駆動 Apply gate) + reviewer 側 (regex 駆動 Detection Heuristics) 両方を SoT と parity にする。本 PR では cycle 3 で reviewer regex 拡張漏れが顕在化 (`Fixed in commit` 等が auto-flag 不可)、cycle 4 で `旧実装は` の SoT 側欠落 (bidirectional parity gap) として再発

### 関連 anti-pattern

- [[fix-comment-self-drift]] の rule-declaration variant (本 page はその specific case)
- [[asymmetric-fix-transcription]] の Generator-Reviewer parity drift sub-pattern と orthogonal (本 page は declaration 本文自体の self-violation、parity drift は別ファイル間の sync gap)

## 関連ページ

- [[fix-comment-self-drift]] ([fix-comment-self-drift.md](./fix-comment-self-drift.md))

## ソース

- [PR #1143 cycle 1 review (Self-contradicting rule declaration 初検出)](../../raw/reviews/20260525T162232Z-pr-1143.md)
- [PR #1143 cycle 1 fix (semantic anchor 置換)](../../raw/fixes/20260525T162704Z-pr-1143.md)
