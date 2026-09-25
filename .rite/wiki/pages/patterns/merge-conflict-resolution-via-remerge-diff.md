---
type: "patterns"
title: "merge で解消した競合のファイルは git show --remerge-diff で求める（diff-tree --cc は clean merge も返す）"
domain: "patterns"
description: "merge commit が「自分で変えた」ファイルを求めるとき、git diff-tree --cc はどの親とも異なるファイルを返すため、競合なしに自動 merge されたファイルも含んでしまう。自動 merge の結果との差を取る git show --remerge-diff を使う。"
created: "2026-09-25T03:58:00Z"
generated: { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-25T03:58:00Z" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20260925T005035Z-pr-3063.md"
  - type: "fixes"
    resource: "raw/fixes/20260925T005815Z-pr-3063.md"
tags: ["git", "merge", "diff"]
confidence: high
---

# merge で解消した競合のファイルは git show --remerge-diff で求める（diff-tree --cc は clean merge も返す）

## 概要

base ブランチを取り込んだ merge で、PR 側が行った変更（競合の解消）だけを数えたいとき、`git diff-tree --cc --name-only` は「どの親とも異なるファイル」を返すので、競合なしに自動 merge されたファイルも含む。競合の解消だけを取るには、自動 merge の結果と merge commit の差を出す `git show --remerge-diff`（git 2.36 以上）を使う。

## 詳細

### 使い分け

| 求めたいもの | コマンド |
|---|---|
| merge で手を入れたファイル（競合の解消・merge 時の追加修正） | `git show --remerge-diff --name-only --format= <merge>` |
| どの親とも異なるファイル | `git diff-tree --cc --name-only <merge>` |

PR 自身の変更を「first-parent 上の非 merge commit の変更 + first-parent 上の merge で競合を解消したファイル」と定義する場合、後者を `--cc` で取ると clean に自動 merge された base 側のファイルまで PR の変更に数えてしまう。

### テストの組み方

fixture では各ファイルが 1 経路でだけ結果に入るようにする（競合を解消したファイルを別の fix commit でも変えると、どちらの経路で入ったか区別できない）。

## 関連ページ

- [fix diff などのファイル集合は取得コマンドごとに rename 検出を揃える](./file-set-commands-align-rename-detection.md)
- [git diff の出力形状を前提にしたパーサは、git の設定と変更種別で黙って空振りする](../anti-patterns/git-diff-parser-output-shape-assumptions.md)

## ソース

- [レビュー結果](../../raw/reviews/20260925T005035Z-pr-3063.md)
- [fix 結果](../../raw/fixes/20260925T005815Z-pr-3063.md)
