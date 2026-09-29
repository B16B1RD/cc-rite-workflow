---
type: "heuristics"
title: "reviewer が実行できない受入条件の実測記録は、修正のたびに最終 HEAD で全件取り直す"
domain: "heuristics"
promote: rite-plugin
description: "reviewer の環境では実行できない受入条件は作者の実測記録だけが根拠になるため、記録が HEAD より古いと acceptance はその不一致を指摘し続ける。修正で出力が変わったら、変わった項目だけでなく全件を最終 HEAD で測り直すと記録の鮮度がそろう。"
created: "2026-09-29T16:54:00Z"
generated: { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-29T16:54:00Z" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20260929T161338Z-pr-3451.md"
tags: ["acceptance", "measurement", "review-loop"]
confidence: medium
---

# reviewer が実行できない受入条件の実測記録は、修正のたびに最終 HEAD で全件取り直す

## 概要

reviewer の環境では実行できない受入条件は作者の実測記録だけが根拠になるため、記録が HEAD より古いと acceptance はその不一致を指摘し続ける。修正で出力が変わったら、変わった項目だけでなく全件を最終 HEAD で測り直すと記録の鮮度がそろう。

## 詳細

受入条件の中には、reviewer が構造的に確かめられないものがある。起点の事例では「native に入場した session worktree で、手順の 1 行呼び出しがホストの隔離ガードに拒否されず marker を出す」ことが条件で、reviewer は READ-ONLY の制約で helper を実行できず、隔離ガード自体も観測できなかった。この種の条件では、作者が実環境で測った表（実行したコマンド・rc・出た marker）が唯一の根拠になる。

修正で helper の出力が 1 行でも変わると、表は HEAD と食い違う。acceptance は差分から「測った時点の後に出力が変わった」ことを読み取り、条件を未検証のまま残す。変わったサブコマンドだけを測り直すと、ほかの行は古い HEAD の値のまま残り、表の中で HEAD がそろわない。修正のたびに全件を最終 HEAD で測り直し、表に測った HEAD を明記する。

実測が共有の state や別ブランチへの副作用を伴うときは、実行前に対象を退避し、実行後に元へ戻して、戻したことも記録に残す。記録には、誰がどの実測表を根拠に確認済みとしたかを書く。

## 関連ページ

- [base 取り込みはレビュー済みの HEAD で行い、検証からレビュー開始までは検証の入力を変えない](./base-intake-on-reviewed-head-keep-verification-inputs-frozen.md)
- [検証手順を書くときは処方するコマンドの判別能力そのものを実測する](./prescribed-command-discriminating-power-measured.md)

## ソース

- [実測記録と HEAD の不一致を指摘したレビュー結果](../../raw/reviews/20260929T161338Z-pr-3451.md)
