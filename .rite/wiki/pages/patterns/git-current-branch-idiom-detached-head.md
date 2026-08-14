---
title: "現在ブランチ取得は git branch --show-current で統一する (rev-parse --abbrev-ref HEAD は detached HEAD で挙動分岐)"
domain: "patterns"
description: "「現在のブランチ名を取得する」という同一目的を実現する 2 つの git idiom は、detached HEAD 状態で**挙動が分岐する**: `git rev-parse --abbrev-ref HEAD` は文字列 `HEAD` を出力し、`git branch --show-current` は**空文字**を出力する。"
promote: rite-plugin
created: "2026-06-02T03:50:58Z"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260602T032246Z-pr-1244.md"
  - type: "fixes"
    resource: "raw/fixes/20260602T032513Z-pr-1244.md"
tags: ["git", "bash", "error-handling"]
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-06-02T03:50:58Z" }
---

# 現在ブランチ取得は git branch --show-current で統一する (rev-parse --abbrev-ref HEAD は detached HEAD で挙動分岐)

## 概要

「現在のブランチ名を取得する」という同一目的を実現する 2 つの git idiom は、detached HEAD 状態で**挙動が分岐する**: `git rev-parse --abbrev-ref HEAD` は文字列 `HEAD` を出力し、`git branch --show-current` は**空文字**を出力する。downstream で「空文字 = ブランチ未取得」を前提にしたフォールバック (AskUserQuestion 等) を設計している場合、`--abbrev-ref HEAD` を使うとフォールバックが silent に機能不全になる。新規コードは codebase の支配的 idiom (この repo では production path 24 箇所が `git branch --show-current`) に揃える。

## 詳細

起点事例 (`/rite:learn` spec) の cycle 4 で code-quality reviewer が「house pattern 逸脱」を LOW-MEDIUM 検出した。`learn.md:55` の現在ブランチ取得が `git rev-parse --abbrev-ref HEAD` を使っており、codebase の 24 箇所は `git branch --show-current` で統一されていた。

これは単なる表記揺れではなく、具体的な副作用を持つ:

| idiom | 通常時 | detached HEAD 時 |
|-------|--------|------------------|
| `git rev-parse --abbrev-ref HEAD` | ブランチ名 | 文字列 `HEAD` を出力 |
| `git branch --show-current` | ブランチ名 | **空文字**を出力 |

`learn.md` の `(なし)` 経路は「ブランチ取得が空 → AskUserQuestion で番号を尋ねる」フォールバックを設計していた。`--abbrev-ref HEAD` だと detached HEAD で空文字ではなく `HEAD` が返るため、フォールバックが発火せず `HEAD` という偽のブランチ名で後続処理に進む silent な機能不全になる。`git branch --show-current` に揃えることで、downstream の空文字前提フォールバックが意図通り機能する。

### 教訓と scope discipline

- 「同じことをする 2 つの git idiom」でも edge case (detached HEAD) で挙動が分岐しうる。新規ファイルは codebase の支配的 idiom に揃えて挙動の一貫性を保つ。
- cycle 1-3 で見落とされた既存行が cycle 4 で初検出された = re-review でも毎回全 diff をフルレビューする価値の実例 ([re-review / verification mode でも初回レビューと同等の網羅性を確保する](../heuristics/reviewer-scope-antidegradation.md))。
- 同 idiom を使う pre-existing な test helper / template README は本 PR と無関係のため伝播せず、別途切り出し対象として `rejected(scope)` で commit に記録した (scope 規律)。

## 関連ページ

- [re-review / verification mode でも初回レビューと同等の網羅性を確保する (Anti-Degradation Guardrail)](../heuristics/reviewer-scope-antidegradation.md)
- [cross-platform bash コマンドは fallback chain で portable 化する](./bash-portable-command-fallback.md)

## ソース

- [PR #1244 review results (cycle 4)](../../raw/reviews/20260602T032246Z-pr-1244.md)
- [PR #1244 fix results (cycle 4)](../../raw/fixes/20260602T032513Z-pr-1244.md)
