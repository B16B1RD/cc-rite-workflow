---
type: "anti-patterns"
title: "新設要約文の「N 個の~系統」的な断定は対象外の類似構造を見落としやすい"
domain: "anti-patterns"
promote: rite-plugin
description: "ドキュメントに新しく要約セクションを書く際、「rite workflow has 3 independently-versioned schemas」のように件数を断定すると、リポジトリ内に実在する類似だが対象外の構造（本件では他にも `schema_version` を持つ work-memory ローカルファイルや issue-claim JSON）を見落として、読者に「これが全てだ」という誤読を与える。"
created: "2026-07-07T02:00:00+00:00"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260706T164658Z-pr-1770.md"
  - type: "fixes"
    resource: "raw/fixes/20260706T164946Z-pr-1770.md"
  - type: "reviews"
    resource: "raw/reviews/20260706T165606Z-pr-1770.md"
tags: []
confidence: medium
generated: { by: "rite-wiki-ingest/unknown", at: "2026-07-07T02:00:00+00:00" }
---

# 新設要約文の「N 個の~系統」的な断定は対象外の類似構造を見落としやすい

## 概要

ドキュメントに新しく要約セクションを書く際、「rite workflow has 3 independently-versioned schemas」のように件数を断定すると、リポジトリ内に実在する類似だが対象外の構造（本件では他にも `schema_version` を持つ work-memory ローカルファイルや issue-claim JSON）を見落として、読者に「これが全てだ」という誤読を与える。

## 詳細

`docs/SPEC.md` に新設した "Schema Version Overview" セクションが、severity 語彙・schema バージョンの crosswalk を 3 系統に整理する内容だったため、要約文で「rite workflow has 3 independently-versioned schemas」と無限定に断言した。tech-writer reviewer が Doc-Heavy PR Mode の Enumeration Completeness 検証で、リポジトリ全体を grep し、他にも `schema_version` フィールドを持つ構造（work-memory local file の `schema_version: 1`、issue-claim JSON の `schema_version: 1`）が存在することを検出し、MEDIUM 指摘とした。

修正は「3 independently-versioned schemas」を排他的リストと誤読されないよう、"that are commonly conflated"（取り違えやすい）という限定修飾語を追加し、さらに対象外の類似構造の存在を括弧書きで明示した:

> rite workflow has **3 independently-versioned schemas that are commonly conflated** (their version numbers look similar and drift independently). ... (Other artifacts also carry their own `schema_version` — e.g. the work-memory local file and the issue-claim JSON, both currently `1` — but their numbering is not easily confused with the 3 below, so they are out of scope for this table.)

**一般化できる教訓**:
- 新設する要約文が「対象を N 個に絞って一覧化する」ものである場合、書き手は暗黙に「これが全て」という主張をしていることに気づきにくい。
- 執筆時に対象領域を grep して、同種のフィールド/概念を持つが対象外にした項目がないか確認する。あれば「よく取り違えられる」「代表的な」等のスコープ限定修飾語を付けるか、対象外項目を明示的に注記する。
- Doc-Heavy PR Mode の Enumeration Completeness カテゴリはこの種の誤読を検出する仕組みとして機能した（[internal-consistency.md](../../../../plugins/rite/skills/review/references/internal-consistency.md) の 5 カテゴリ検証プロトコル）。

## 関連ページ

- [Documentation review は対応する実装側 (commands/scripts/templates) の grep verify を必須 step とする](../heuristics/docs-review-implementation-grep-verification.md)

## ソース

- [PR #1770 review results](../../raw/reviews/20260706T164658Z-pr-1770.md)
- [PR #1770 fix results](../../raw/fixes/20260706T164946Z-pr-1770.md)
- [PR #1770 review results (cycle 2)](../../raw/reviews/20260706T165606Z-pr-1770.md)
