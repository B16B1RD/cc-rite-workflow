---
type: "heuristics"
title: "依存要件ドキュメントの「ツールを入れれば有効化」主張は実コードの呼び出し名を grep で裏取りする"
domain: "heuristics"
description: "README 等の依存要件で「ツール X（例: coreutils / gdate）を入れれば機能 Y が有効化される」と書く前に、実コードがそのツール名を literal に呼んでいるかを grep で裏取りする。"
created: "2026-07-24T17:57:51+09:00"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260724T083434Z-pr-2004.md"
  - type: "fixes"
    resource: "raw/fixes/20260724T083743Z-pr-2004.md"
  - type: "reviews"
    resource: "raw/reviews/20260724T084754Z-pr-2004.md"
tags: []
confidence: medium
generated: { by: "rite-wiki-ingest/unknown", at: "2026-07-24T17:57:51+09:00" }
---

# 依存要件ドキュメントの「ツールを入れれば有効化」主張は実コードの呼び出し名を grep で裏取りする

## 概要

README 等の依存要件で「ツール X（例: coreutils / gdate）を入れれば機能 Y が有効化される」と書く前に、実コードがそのツール名を literal に呼んでいるかを grep で裏取りする。実装が別名や別コマンド（例: `gdate` ではなく `date -d`）を呼んでいる場合、そのツールを導入しても機能は有効化されず、記述が不正確になる。

## 詳細

（→ docs-review-implementation-grep-verification に統合: gdate ではなく `date -d` を呼ぶ実装、gnubin を PATH 先頭へ追加して有効化。裏取りは実コードの呼び出し名 grep）

## 関連ページ

- [カテゴリ列挙の圧縮はブロッキング/informational の分類を SoT で確認してから削る](./enumeration-compression-verify-blocking-classification.md)

## ソース

- [レビュー結果](../../raw/reviews/20260724T083434Z-pr-2004.md)
- [fix 結果](../../raw/fixes/20260724T083743Z-pr-2004.md)
- [レビュー結果](../../raw/reviews/20260724T084754Z-pr-2004.md)
