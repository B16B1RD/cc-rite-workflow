---
type: "heuristics"
title: "marker の意味と、それを読む報告文は、発行するすべての経路で成り立つ文にする"
domain: "heuristics"
description: "marker に新しい発行元を足すと、1 つの経路に合わせて書いた marker の定義や完了報告の文言が、新しい経路では事実に反する。marker の定義と読み手の文は、発行元ごとに成り立つかを確かめてから共通の場所に置く。"
created: "2026-09-29T08:26:00Z"
generated: { by: "rite-wiki-ingest/claude-sonnet-5-5", at: "2026-09-29T08:26:00Z" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20260929T062546Z-pr-3393.md"
  - type: "reviews"
    resource: "raw/reviews/20260929T082333Z-pr-3393.md"
  - type: "fixes"
    resource: "raw/fixes/20260929T080249Z-pr-3393.md"
tags: ["marker", "review-scope", "cross-file-impact"]
confidence: medium
---

# marker の意味と、それを読む報告文は、発行するすべての経路で成り立つ文にする

## 概要

marker に新しい発行元（reason）を足すと、最初の 1 経路に合わせて書いた marker の定義や、それを読む完了報告の文言が、新しい経路では事実に反する。定義と読み手の文は、発行するすべての経路で成り立つかを確かめてから共通の場所に置く。

## 詳細

marker は複数の経路から出せるようになるほど、定義文が「そのうちの 1 経路の事実」に寄りやすい。例えば「候補を起票した」という趣旨の文を共通の定義に置くと、起票を保留した経路や位置の無い候補を処分した経路でも同じ文が読まれ、報告が実態と食い違う。

確かめる手順は 2 つある。1 つ目は、marker を足したとき、その marker を出す全経路を列挙し、定義文が各経路で真になるかを 1 つずつ読むこと。2 つ目は、その marker を読む側（完了報告の文言、後続ステップの分岐）を grep し、新しい経路でも文が成り立つかを読むこと。1 つの経路にしか成り立たない文は、共通の定義に置かず経路ごとの文に分ける。

修正側も同じ規律で書く。marker の意味と、それを読む報告文をどちらも「発行するすべての経路で成り立つ文」に直し、直した後にもう一度、全経路を読み直す。

## 関連ページ

- [新設した出力フィールドは producer と consumer の両側を pin する — consumer が表なら行単位で pin する](../patterns/new-output-field-pin-producer-and-consumer.md)

## ソース

- [レビュー結果（規則追加と marker の新しい発行元）](../../raw/reviews/20260929T062546Z-pr-3393.md)
- [レビュー結果（marker の文言が全経路で成り立つか）](../../raw/reviews/20260929T082333Z-pr-3393.md)
- [fix 結果（marker の意味と報告文の修正）](../../raw/fixes/20260929T080249Z-pr-3393.md)
