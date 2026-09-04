---
title: "関連 PR 探索は gh pr list --head (exact-match) ではなく --state all + client-side headRefName filter で行う"
domain: "heuristics"
description: "ブランチ名や Issue 番号から関連 PR を解決するとき、`gh pr list --head \"*issue-N*\"` のような glob/wildcard 指定は**機能しない**。"
promote: rite-plugin
created: "2026-06-02T03:50:58Z"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260602T030609Z-pr-1244.md"
  - type: "fixes"
    resource: "raw/fixes/20260602T030809Z-pr-1244.md"
  - type: "reviews"
    resource: "raw/reviews/20260602T031333Z-pr-1244.md"
  - type: "fixes"
    resource: "raw/fixes/20260602T031509Z-pr-1244.md"
tags: ["gh-cli", "error-handling"]
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-06-02T03:50:58Z" }
---

# 関連 PR 探索は gh pr list --head (exact-match) ではなく --state all + client-side headRefName filter で行う

## 概要

ブランチ名や Issue 番号から関連 PR を解決するとき、`gh pr list --head "*issue-N*"` のような glob/wildcard 指定は**機能しない**。`gh pr list --head` は head ブランチ名の**完全一致 (exact-match) フィルタ**であり glob を解釈しないため、wildcard を渡すと常に空配列を返す。さらに `gh pr list` の `--state` は既定 `open` のため、完了済み (merged) PR を対象にする用途では `--state all` を明示しないと取り逃す。canonical は `gh pr list --state all --json number,headRefName,title,body` で全 PR を取得し、`headRefName` を client-side で substring filter すること。

## 詳細

起点事例 (新コマンド `/rite:learn` の spec) の review-fix loop で、`#N`→Issue 解決ロジックがこの 2 つの gh CLI 仕様の落とし穴を連続で踏んだ (cycle 2 / cycle 3)。両者とも「LLM が house pattern の形だけ真似たが実際には機能しない」失敗である。

### 落とし穴 1: `--head` は exact-match のみ (glob 非対応)

cycle 1 fix が `gh pr list --state all --head "*issue-N*"` を導入したが、`--head` は head ブランチ名の完全一致フィルタで `*` を wildcard として解釈しないため、`*issue-N*` は文字通りそのブランチ名を探し、結果は常に空配列になる (= 関連 PR が永久に見つからない非機能コード)。

**canonical 対策** (全 PR 取得 + client-side substring filter):

- `gh pr list --state all --json number,headRefName,title,body` で全 PR を取得
- LLM 側 (または client) で `headRefName` に `issue-N` が含まれるものを substring filter

`gh pr list` の table セルに複雑な jq パイプ (`.headRefName | test(...)`) を埋め込むのは避ける — `|` が Markdown table のセル区切りと衝突するため、フィルタは散文指示で記述するほうが fragile な escaping を回避できる。

### 落とし穴 2: `--state` の既定は `open` (merged PR を取り逃す)

cycle 2 fix が落とし穴 1 を解消したが、`--state all` を `#N` 経路 (line 54) にだけ付与し、対称な `(なし)` 経路 (line 55) への伝播を忘れた (Asymmetric Fix Transcription)。`gh pr list --head <branch>` は既定 `--state open` のため、`/rite:learn` のように**完了セッション (merged PR)** を主用途にするコマンドでは、無引数経路で PR を取り逃す機能ギャップになる。house pattern (`cleanup.md` / `close.md`) は一貫して `--state all` を使っており、同ファイル内の全 `gh pr list` 経路に揃える必要がある。

### 教訓: 「既存パターンとの形状一致」は「機能する」ことを保証しない

cycle 2 で code-quality reviewer は問題の glob を `close.md:103` の house pattern と「flag 順・glob 形状が一致」として OK 判定し、functional bug を見落とした。一方 prompt-engineer / error-handling は同一 file:line を独立検出した (cross-validation 合意)。**既存パターンと形が一致していても、そのパターンが実際に機能するかは別問題**。新規に gh コマンドを書く際は形状模倣ではなく仕様 (exact-match / 既定 state) を確認する。なお同型 pre-existing バグが `close.md:103` にも残存しており、横展開 follow-up 候補として切り出された。

## 関連ページ

- [gh api graphql は HTTP 200 + .errors[] で partial failure を返す (exit code では検知できない)](../anti-patterns/gh-api-graphql-http200-partial-errors.md)
- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](../anti-patterns/asymmetric-fix-transcription.md)

## ソース

- [レビュー結果](../../raw/reviews/20260602T030609Z-pr-1244.md)
- [fix 結果](../../raw/fixes/20260602T030809Z-pr-1244.md)
- [レビュー結果](../../raw/reviews/20260602T031333Z-pr-1244.md)
- [fix 結果](../../raw/fixes/20260602T031509Z-pr-1244.md)
