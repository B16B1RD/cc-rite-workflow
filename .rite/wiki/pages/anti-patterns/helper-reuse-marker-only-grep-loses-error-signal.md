---
type: "anti-patterns"
title: "既存 helper を別工程から再利用するとき marker 行だけの grep で呼ぶと helper 障害を「該当なし」と誤認する"
domain: "anti-patterns"
description: "既存 helper を別の呼び出し工程から再利用する際、`|| true` と marker 行だけの grep で結果を判定すると、helper 自体の不在・異常終了と正規の「該当なし」を区別できなくなる。再利用側は元の呼び出し側と同じ「marker なしの非ゼロ終了は停止」という規約を引き継ぐ必要がある。"
created: "2026-09-26T11:20:00Z"
generated: { by: "rite-wiki-ingest/claude-sonnet-5", at: "2026-09-26T11:20:00Z" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20260926T110024Z-pr-3148.md"
tags: []
confidence: medium
---

# 既存 helper を別工程から再利用するとき marker 行だけの grep で呼ぶと helper 障害を「該当なし」と誤認する

## 概要

既存 helper を別の呼び出し工程から再利用する際、`|| true` と marker 行だけの grep で結果を判定すると、helper 自体の不在・異常終了と正規の「該当なし」を区別できなくなる。再利用側は元の呼び出し側と同じ「marker なしの非ゼロ終了は停止」という規約を引き継ぐ必要がある。

## 詳細

既存 helper（正規の呼び出し工程では marker 行の有無で分岐し、marker が無い非ゼロ終了は fail-loud として扱っている）を、別の工程から手軽に再利用したくなる場面がある。その際、呼び出しを `helper.sh ... | grep -q 'MARKER=' || true` のように書くと、以下がすべて同じ「該当なし」として扱われてしまう:

- helper が正規に「該当なし」と判定して marker を出さなかった場合
- helper 自体が存在しない、または実行権限がない場合
- helper が異常終了し、marker を出す前に落ちた場合

正規の呼び出し工程が持っていた「marker が無い非ゼロ終了は停止して原因を報告する」という規約を、再利用側が `|| true` で握りつぶすと、helper の障害が silent に「該当なし」へ縮退する。これは実測必須ゲート・非実測記録・その他の判定 helper を新しい呼び出し元から再利用するときに繰り返し起こりうる欠陥クラスである。

対処は、再利用側でも元の呼び出し側と同じ分岐（marker 行の有無 → ある場合の値の妥当性 → marker が無い非ゼロ終了は停止）を実装し、`|| true` で一律に握りつぶさないことである。

## 関連ページ

- [守るべき失敗モードを「検証対象なし」へ分類する後条件ゲートは、その失敗モードを最初から素通しする](./postcondition-gate-classifies-target-failure-as-not-applicable.md)

## ソース

- [レビュー結果](../../raw/reviews/20260926T110024Z-pr-3148.md)
