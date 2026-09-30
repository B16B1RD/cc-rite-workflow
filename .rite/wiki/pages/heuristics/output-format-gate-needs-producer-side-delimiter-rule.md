---
type: "heuristics"
title: "出力形式の gate を新設したら、producer 側にも同じ区切り規則を書く"
domain: "heuristics"
description: "reviewer の出力のような形式を検査する gate を足すとき、gate 側だけで「どこまでを値とみなすか」を決めると、正しい内容の出力が付記行（時刻記録など）で落とされる。gate の範囲を狭めて誤検出を避けると、今度は fail-loud で拾うべき不備を取りこぼす。区切り規則は producer への指示と再生成の指示にも同じ形で書く。"
created: "2026-09-30T05:38:00Z"
generated: { by: "rite-wiki-ingest/claude-sonnet-5-5", at: "2026-09-30T05:38:00Z" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20260930T052103Z-pr-3521.md"
  - type: "fixes"
    resource: "raw/fixes/20260930T053339Z-pr-3521.md"
tags: []
confidence: medium
---

# 出力形式の gate を新設したら、producer 側にも同じ区切り規則を書く

## 概要

出力形式を検査する gate を新設するとき、「どこまでを値とみなすか」を gate 側だけで決めると、producer が正しい内容を出しても付記行で落とされる。gate 側で範囲を狭めて誤検出を避ければ、今度は fail-loud で拾うべき不備を取りこぼす。区切り規則は producer への出力指示と、再生成を頼むときの指示にも同じ形で書く。

## 詳細

観測された経緯は次のとおり。分類が欠けた・規定外の推奨事項を黙って候補から外さず、再生成させて不備なら止める gate を新設した。

- gate は各行の値を検査するが、reviewer の出力には値の後ろに付記行（時刻記録など）が付くことがある。区切りの規則が producer 側に書かれていないため、正しい内容の出力が付記行のせいで落とされた。
- 誤検出を避けるために gate 側の検査範囲を狭めると、本来 fail-loud で拾うべき不備（規定外の値）まで通ってしまう。狭めるのではなく、producer 側の指示を gate と同じ規則にそろえるのが正しい向きである。
- 再生成を頼む指示にも同じ区切り規則を書く。再生成の指示だけが古い規則のままだと、再生成した出力がまた落とされる。

gate を足す変更では、producer への指示・gate・再生成の指示の 3 箇所が同じ区切り規則を持つことを確認する。

## 関連ページ

- [消費側の許可リストが生産側の値域を詰まらせる](../anti-patterns/consumer-allowlist-wedges-producer-value-range.md)

## ソース

- [レビュー結果](../../raw/reviews/20260930T052103Z-pr-3521.md)
- [fix 結果](../../raw/fixes/20260930T053339Z-pr-3521.md)
