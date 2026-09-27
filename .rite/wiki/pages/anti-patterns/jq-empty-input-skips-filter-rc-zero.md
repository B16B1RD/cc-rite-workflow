---
type: "anti-patterns"
title: "jq は入力が 0 ドキュメントだとフィルタを評価せず rc=0 で終わる — 形の検証は jq -n と input で 1 ドキュメントを要求する"
domain: "anti-patterns"
description: "jq はストリーム入力が空のときフィルタを一度も評価せずに成功終了するため、入力の形を検証する述語は空応答を捕捉できない。空入力を失敗として扱いたい検証は jq -n と input で 1 ドキュメントを要求して書く。"
created: "2026-09-27T03:16:22Z"
generated: { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-27T03:16:22Z" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20260927T031103Z-pr-3200.md"
tags: ["jq", "fail-loud", "gh-api", "empty-input"]
confidence: medium
---

# jq は入力が 0 ドキュメントだとフィルタを評価せず rc=0 で終わる — 形の検証は jq -n と input で 1 ドキュメントを要求する

## 概要

jq はストリーム入力が空のときフィルタを一度も評価せずに成功終了するため、入力の形を検証する述語は空応答を捕捉できない。空入力を失敗として扱いたい検証は jq -n と input で 1 ドキュメントを要求して書く。

## 詳細

### 起きたこと

- 件数上限のガードをまとめて削除したとき、同じ分岐に同居していた「空応答なら失敗」の判定まで消えた。API 呼び出しが rc=0 で空の stdout を返すと、それが「0 件」と読まれて後続の起票へ進んだ
- 代わりに jq で入力の形を検証しようとしても、`-e` を付けない `jq 'type == "array"'` のような述語は入力 0 ドキュメントでは評価されず、何も出力せず rc=0 で終わる（`-e` を付ければ出力なしで rc=4 になるが、出力文字列で判定する呼び出し側では空文字と区別されずに通過しうる）

### 対処

- 形の検証は `jq -n 'input | ...'` のように書き、1 ドキュメントを明示的に要求する。入力が空なら `input` がエラーになり非ゼロで終わる
- `gh api --paginate --slurp` は 0 件でも `[[]]`（ページの配列）を返す。検証は「空でない配列で、要素がすべて配列」という形で行い、REST の issues endpoint では `.pull_request == null` で PR を除外して、`gh issue list` と同じ対象集合を保つ
- ガード付き分岐を削除するときは、削除対象の分岐に別の失敗ケースの fail-loud が同居していないかを先に確かめる
- 失敗時に人へ案内する手動確認コマンドも、helper の同定規則（先頭行一致・PR 除外など）と揃える。規則が違うと、人が偽陽性を見て誤判断する

## 関連ページ

- [jq の `[]?` は型不正を空の結果に変えて rc=0 で終わり、呼び出し側の fail-loud 分岐を迂回する](./jq-optional-iterator-swallows-type-error-before-fail-loud-branch.md)
- [到達不能に見える分岐の削除は、その分岐が受けていた入力の行き先を確認してから決める](../heuristics/branch-deletion-traces-where-the-input-flows.md)

## ソース

- [レビュー結果](../../raw/reviews/20260927T031103Z-pr-3200.md)
