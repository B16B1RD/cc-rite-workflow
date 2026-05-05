---
title: "並列 Section 展開時の同名 heading 重複"
domain: "anti-patterns"
created: "2026-05-05T11:15:55+00:00"
updated: "2026-05-05T11:15:55+00:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260505T105152Z-pr-837.md"
  - type: "fixes"
    ref: "raw/fixes/20260505T105459Z-pr-837.md"
tags: []
confidence: high
---

# 並列 Section 展開時の同名 heading 重複

## 概要

評価レポート系ドキュメントで scope (本 PR scope 内 / scope 外) や timeline (本 PR で実施 / 次 PR 候補) が異なる候補リストを並列の独立 Section として展開すると、両 Section が同名 heading (例: `残課題と次 PR 候補`) を持ち、reader が「どちらが正?」と混乱する構造的問題。同一ファイル内の同名 heading 重複は markdown TOC や anchor リンクでも曖昧性を生む。

## 詳細

### 発生構造

1. 評価レポート / PR description で「scope 内の残課題」「scope 外の次 PR 候補」のように、性質が近いが scope/timeline が異なる候補リストを書き分けたい
2. 各リストを独立した Section heading で展開する (例: Section 8: `残課題と次 PR 候補` / Section 10: 同じ heading)
3. 同一ファイル内に同名 heading が 2 箇所存在し、reader が top-down に読むと「先のセクションが上書きされた?」と誤認する

PR #837 で評価レポート `docs/designs/issue-create-sub-skill-consolidation-evaluation.md` の Section 8 と Section 10 に `残課題と次 PR 候補` が重複し、prompt-engineer reviewer が HIGH として検出した。

### 解決パターン (PR #837 cycle 1 fix)

- **1 Section に集約**: 性質が近いリストは独立 Section に分割せず、1 つの Section 内で副見出し (`### scope 内` / `### scope 外`) や表形式で区分する
- **heading の uniqueness を保つ**: 同一ファイル内の Section heading は文字列レベルで重複しない命名規約を採用する (例: `残課題` / `次 PR 候補` で分離するか、scope 修飾子を heading に含める)

### 検出手段

- markdown lint (`markdownlint MD024 - Multiple headings with the same content`) で機械検出可能。CI / pre-commit gate に組み込むことで構造的重複の silent 流入を防ぐ
- review 時に長いドキュメントの TOC を生成し、同名 heading の重複を視認する

### 関連する failure mode

heading 重複は単独で発生せず、計画変更時の前方参照欠落 (sibling pattern) と同時に出現することが多い。両者とも「並列 Section 展開での内部矛盾」が共通する根本構造。

## 関連ページ

- [計画変更時の前方参照契約](../patterns/plan-deviation-forward-reference-contract.md)

## ソース

- [PR #837 cycle 1 review (heading 重複 HIGH 検出)](../../raw/reviews/20260505T105152Z-pr-837.md)
- [PR #837 fix (Section 集約による解消)](../../raw/fixes/20260505T105459Z-pr-837.md)
