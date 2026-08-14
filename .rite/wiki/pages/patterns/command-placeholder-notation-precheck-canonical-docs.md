---
type: "patterns"
title: "複数コマンドの引数プレースホルダ表記は既存正典ドキュメントの慣習を事前 Grep で確認する"
domain: "patterns"
promote: rite-plugin
reference: "plugins/rite/references/wiki-promotions/patterns/command-placeholder-notation-precheck-canonical-docs.md"
description: "`/rite:iterate <pr>` `/rite:ready <pr>` `/rite:cleanup [branch]` のように複数コマンドの引数プレースホルダを並記するドキュメントを新規に書く（または改修する）とき、書き手が新しい表記（例: 大文字 `<PR>`）を独自に導入すると、(1) 実際のコマンドシグネチャ（`argument-hint`）との不一致、(2) プロジェクト内で既に確立された表記慣習（小文字 `<pr>`）との不一致、の2種類の drift を同時に生む。"
created: "2026-07-02T16:55:00+09:00"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260702T065237Z-pr-1721.md"
  - type: "reviews"
    resource: "raw/reviews/20260702T070751Z-pr-1721.md"
  - type: "reviews"
    resource: "raw/reviews/20260702T074935Z-pr-1721.md"
  - type: "fixes"
    resource: "raw/fixes/20260702T065551Z-pr-1721.md"
  - type: "fixes"
    resource: "raw/fixes/20260702T071033Z-pr-1721.md"
tags: ["placeholder-notation", "argument-hint", "cross-file-consistency", "documentation-pr", "propagation-scan"]
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-07-02T16:55:00+09:00" }
---

# 複数コマンドの引数プレースホルダ表記は既存正典ドキュメントの慣習を事前 Grep で確認する

## 概要

`/rite:iterate <pr>` `/rite:ready <pr>` `/rite:cleanup [branch]` のように複数コマンドの引数プレースホルダを並記するドキュメントを新規に書く（または改修する）とき、書き手が新しい表記（例: 大文字 `<PR>`）を独自に導入すると、(1) 実際のコマンドシグネチャ（`argument-hint`）との不一致、(2) プロジェクト内で既に確立された表記慣習（小文字 `<pr>`）との不一致、の2種類の drift を同時に生む。これは複数レビューサイクルに渡って段階的にしか検出されないことがある。

## 詳細

### 背景となった起点事例

当該 Issue（`/rite:workflow` ガイド・`/rite:getting-started` を v0.7 正典フローへ追随させ、コロン誤記パス `.claude/rite:config.yml` を修正する）の対応で、新フロー（`open → iterate → ready → merge → cleanup`）の案内文言を新規に書き起こした際、複数コマンドの引数プレースホルダを大文字 `<PR>` で統一して記述した。

### 3 サイクルに渡って段階的に検出された経緯

1. **1回目レビュー（HIGH）**: `/rite:cleanup <PR>` という表記が、`cleanup` の実シグネチャ `[branch_name]`（PR番号ではなくブランチ名を取る、省略可）と不一致であることを prompt-engineer reviewer が検出。3箇所（workflow/SKILL.md:87,157、getting-started/SKILL.md:300）を修正。

2. **2回目レビュー（HIGH + MEDIUM）**: 修正漏れが1箇所残存（getting-started/SKILL.md:131 の Quick Start セクション）。加えて、`/rite:ready <PR>` が実は `[pr_number]`（省略可）を取るにもかかわらず必須引数のような `<PR>` 表記になっていること、そして `<PR>`（大文字）自体がプロジェクト内の既存確立慣習 `<pr>`（小文字、`rite-workflow/SKILL.md`・`run/SKILL.md` 等で使用）と不一致であることを code-quality reviewer が検出（計7箇所）。

3. **3回目レビュー（0件、mergeable）**: 全箇所を `<pr>`（小文字）に統一し収束。

### なぜ段階的にしか検出されなかったか

- 1回目は「実際に動かない」レベルの実害（HIGH: `/rite:cleanup <PR番号>` を実行すると存在しないブランチ名として扱われエラーになる）が最初に検出された。
- 2回目は、1回目の修正パターン（`/rite:cleanup <PR>` の削除）を基準に fix コミットが作られたため、同一ファイル内の同種箇所（getting-started:131）への伝播スキャンが不完全だった。
- 表記慣習の不一致（大文字/小文字）は実害が小さい（`/rite:ready <PR>` は動作はする、必須引数に見えるだけ）ため、severityが低く、reviewerが「気づいたときに検出する」形になりやすい。

### 予防策

1. **新規ドキュメント作成前に既存正典を Grep する**: 複数コマンドの引数プレースホルダを書く前に `grep -rn '<pr>\|<pr_number>' plugins/rite/skills/*/SKILL.md` のように、プロジェクト内の確立された表記慣習を確認する。本プロジェクトでは `rite-workflow/SKILL.md`・`run/SKILL.md` が正典的に `<pr>`（小文字）を使用している。
2. **実シグネチャの `argument-hint` を突き合わせる**: 各コマンドの `plugins/rite/skills/{name}/SKILL.md` frontmatter の `argument-hint` を確認し、必須引数（`<...>`）と省略可能引数（`[...]`）を正しく区別する。
3. **伝播スキャンを同一ファイル内の全箇所に徹底する**: 1つの指摘で1箇所を修正した際、同一パターンが同一ファイルの他セクション（例: Quick Start 要約セクションと詳細セクションの両方）に重複していないか `grep -n` で確認する。

## 関連ページ

- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](../anti-patterns/asymmetric-fix-transcription.md)
- [reviewer の regression 主張は revert test (git show / git diff) で PR 由来か pre-existing かを独立検証する](../heuristics/reviewer-regression-claim-revert-test-attribution.md)

## ソース

- [PR #1721 review results](../../raw/reviews/20260702T065237Z-pr-1721.md)
- [PR #1721 review results (cycle 2)](../../raw/reviews/20260702T070751Z-pr-1721.md)
- [PR #1721 review results (cycle 3, mergeable)](../../raw/reviews/20260702T074935Z-pr-1721.md)
- [PR #1721 fix results](../../raw/fixes/20260702T065551Z-pr-1721.md)
- [PR #1721 fix results (cycle 2)](../../raw/fixes/20260702T071033Z-pr-1721.md)
