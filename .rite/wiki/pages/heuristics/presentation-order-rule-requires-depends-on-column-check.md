---
type: "heuristics"
title: "提示順ルールを計画テンプレートに追加する際は depends_on 列の有無を確認する"
domain: "heuristics"
promote: rite-plugin
description: "実装計画テンプレートに「ユーザーの判断で変わりやすい項目を先頭に提示する」ような提示順ルールを追加する際、対象テンプレートが `depends_on` 列を持つ依存グラフ形式か、`depends_on` 列を持たないプレーン番号リスト形式かで、そのルールが「実行順」にまで波及するかどうかが変わる。"
created: "2026-07-06T02:34:59Z"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260706T020946Z-pr-1752.md"
  - type: "fixes"
    resource: "raw/fixes/20260706T021735Z-pr-1752.md"
tags: []
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-07-06T02:34:59Z" }
---

# 提示順ルールを計画テンプレートに追加する際は depends_on 列の有無を確認する

## 概要

実装計画テンプレートに「ユーザーの判断で変わりやすい項目を先頭に提示する」ような提示順ルールを追加する際、対象テンプレートが `depends_on` 列を持つ依存グラフ形式か、`depends_on` 列を持たないプレーン番号リスト形式かで、そのルールが「実行順」にまで波及するかどうかが変わる。

## 詳細

`/rite:open` の実装計画テンプレートに volatile-first 提示順ルールを追加する変更だった。

cycle 1 レビューで、code-quality-reviewer が以下の構造的な結合を検出した: 対象テンプレート（`plugins/rite/skills/open/SKILL.md` ステップ3.3 の「実装ステップ」リスト）は `depends_on` 列を持たないプレーン番号リスト形式であり、そのリストはステップ3.5で Issue body のチェックリストへそのまま転写される。`issue-implement.md` の Basic implementation flow (`Repeat following plan order`) はプレーン番号リスト形式ではその順序をそのまま実行順として辿り、`depends_on` 列を持つ計画にのみ適用される Adaptive Re-evaluation は明示的にスキップされる。

つまり「提示順」と「実行順」を分離する仕組みは、`depends_on` 列を持たないテンプレートには存在しない。この結果、当初「実装ステップ自体を並べ替える」設計で実装した提示順ルールは、Issue 自身の Non-goal（実行順序の変更禁止）と実質的に矛盾する CRITICAL 欠陥になった。

修正では、Issue の Open Question が提示していたもう一つの選択肢（「実装ステップ」自体の並びには触れず、計画冒頭に独立した「要判断ポイント」ブロックを置く）を採用し、実行順への影響を回避した。

**教訓**: 計画・タスクリストの「提示順」を変える変更を行う際は、対象テンプレートが (a) `depends_on` 列等の依存グラフ形式か、(b) プレーン番号リスト形式かを最初に確認する。(b) の場合、リストの並び替えは実行順の変更と等価になりうるため、提示順の強調は「独立したブロックの追加」のような、リストの並び自体に触れない方式を優先する。

## 関連ページ

- （関連ページなし）

## ソース

- [PR #1752 review results](../../raw/reviews/20260706T020946Z-pr-1752.md)
- [PR #1752 fix results](../../raw/fixes/20260706T021735Z-pr-1752.md)
