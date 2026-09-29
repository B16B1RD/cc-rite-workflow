---
type: "heuristics"
title: "契約の主張を絞る修正は、同じ主張を述べる全箇所を grep で洗い出してからまとめて直す"
domain: "heuristics"
description: "契約の主張を絞る修正で、主要な箇所（SPEC や関数冒頭のコメント）だけを直すと、別の言語のコード中コメントやテストのコメントに残った同じ主張が次のレビューで指摘として戻ってくる。同じ主張を述べる箇所を先に grep で一覧にし、まとめて直してから、その一覧を reviewer に示す。"
created: "2026-09-29T01:07:27Z"
generated: { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-29T01:07:27Z" }
sources:
  - type: "fixes"
    resource: "raw/fixes/20260929T004539Z-pr-3397.md"
  - type: "reviews"
    resource: "raw/reviews/20260929T003742Z-pr-3397.md"
  - type: "reviews"
    resource: "raw/reviews/20260929T005026Z-pr-3397.md"
tags: ["documentation", "contract", "review", "grep"]
confidence: medium
promote: rite-plugin
---

# 契約の主張を絞る修正は、同じ主張を述べる全箇所を grep で洗い出してからまとめて直す

## 概要

契約の主張を絞る修正で、主要な箇所（SPEC や関数冒頭のコメント）だけを直すと、別の言語のコード中コメントやテストのコメントに残った同じ主張が次のレビューで指摘として戻ってくる。同じ主張を述べる箇所を先に grep で一覧にし、まとめて直してから、その一覧を reviewer に示す。

## 詳細

主張は SPEC、関数冒頭、呼び出し側のコメント、テストのコメント、別言語で書かれた注記に散らばる。主要な箇所だけを直すと、残った 1 箇所が PR 内推奨や新しい指摘として戻り、レビューの cycle が増える。修正の前に同じ主張の言い回しで grep し、表現をそろえる全箇所を一覧にしてから直す。コメントだけの修正 cycle では、挙動が変わらないことと同じ主張の残存が 0 件であることを grep と実行で確かめれば、指摘 0 件で収束しやすい。

## 関連ページ

- [終了コードの契約は、その形を作る経路をすべて数え上げてから書く](./exit-contract-enumerate-producing-paths.md)

## ソース

- [主張を絞った箇所の残りを直した fix 結果](../../raw/fixes/20260929T004539Z-pr-3397.md)
- [別言語のコメントに主張が残ったレビュー結果](../../raw/reviews/20260929T003742Z-pr-3397.md)
- [コメントだけの修正で指摘 0 件に収束したレビュー結果](../../raw/reviews/20260929T005026Z-pr-3397.md)
