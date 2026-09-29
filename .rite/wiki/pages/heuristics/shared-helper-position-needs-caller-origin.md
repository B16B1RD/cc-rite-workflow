---
type: "heuristics"
title: "共有 helper に位置を渡すときは、呼び出し元ごとの数え始めをそろえる"
domain: "heuristics"
description: "同じ helper に渡す位置でも、呼び出し元が異なる起点から数えていると対象がずれる。位置の意味と起点を各呼び出し元で確かめ、途中から始まる入力でも同じ対象を指すようにする。"
created: "2026-09-29T05:09:59.094345+00:00"
generated: { by: "rite-wiki-ingest/gpt-6", at: "2026-09-29T05:09:59.094345+00:00" }
promote: rite-plugin
sources:
  - type: "reviews"
    resource: "raw/reviews/20260929T044958Z-pr-3431.md"
tags: []
confidence: medium
---

# 共有 helper に位置を渡すときは、呼び出し元ごとの数え始めをそろえる

## 概要

同じ helper に渡す位置でも、呼び出し元が異なる起点から数えていると対象がずれる。位置の意味と起点を各呼び出し元で確かめ、途中から始まる入力でも同じ対象を指すようにする。

## 詳細

発散点の除外を共有 helper へ渡す設計では、cycle-gate が pin 基準の counter を使い、観測側が first_cycle 基準の位置を使っていた。一方の起点を暗黙に共通とみなすと、もう一方が過去の発散点を再び拾う。共有化を確認するときは呼び出し箇所だけでなく位置を作る式を読み、first_cycle が初期値と異なる入力で対象位置を確認する。

## 関連ページ

- （関連ページなし）

## ソース

- [レビュー結果](../../raw/reviews/20260929T044958Z-pr-3431.md)
