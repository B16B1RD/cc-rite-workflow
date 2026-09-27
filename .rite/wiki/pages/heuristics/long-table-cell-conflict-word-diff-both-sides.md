---
type: "heuristics"
title: "長い表セルの競合は両側の word-diff を列挙してから片側へ差分だけを載せる"
domain: "heuristics"
description: "1 行が長い表セル同士の競合は、行単位の目視では片側の変更を取りこぼしやすい。両側の変更を word-diff で列挙し、片側の行へもう片側の差分だけを適用し、解消後に両親それぞれとの word-diff が相手側の変更だけになることで確かめる。"
created: "2026-09-27T05:21:39Z"
generated: { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-27T05:21:39Z" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20260927T051531Z-pr-3215.md"
tags: []
confidence: medium
---

# 長い表セルの競合は両側の word-diff を列挙してから片側へ差分だけを載せる

## 概要

1 行が長い表セル同士の競合は、行単位の目視では片側の変更を取りこぼしやすい。両側の変更を word-diff で列挙し、片側の行へもう片側の差分だけを適用し、解消後に両親それぞれとの word-diff が相手側の変更だけになることで確かめる。

## 詳細

Markdown の表は 1 セルに長い説明を詰めるため、base と PR が同じ行の別々の語を書き換えると、競合マーカーの両側はほぼ同じ長い行になる。どちらかの行を丸ごと採ると、もう片側の変更が黙って消える。

手順:

1. merge-base から各親への word-diff（ours ↔ base、theirs ↔ base）で、両側の変更点を語単位で列挙する。
2. どちらか一方の行を土台にし、もう片側で列挙した差分だけを適用する。
3. 解消後、merge commit と各親との word-diff を取り、それぞれ「相手側の変更だけ」が現れることを確認する。自分側の変更が差分に出たら、その変更を落としている。

同じ説明を複数文書が持つ場合は、base 側の追記が片方の文書にしか入っていないことがある。自動マージで消えたのか、元から片方にしか無いのかは、base の該当 commit が触れたファイル一覧と、base 版にその文が存在するかで判別できる。元から片方にしか無い場合は、競合解消の作業ではなく文書間の同期漏れとして扱う。

## 関連ページ

- [base 取り込みの競合は base 側の正本を基準にし、PR の変更意図だけを載せ直す](./base-intake-conflict-reapply-pr-intent-on-base-canonical.md)

## ソース

- [レビュー結果](../../raw/reviews/20260927T051531Z-pr-3215.md)
