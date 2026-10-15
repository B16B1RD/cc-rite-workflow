---
# Domain knowledge only; rite workflow candidates stay in raw.
type: "heuristics"
title: "受理を確かめる assert は受理側の名前の試験の入力の組に置く"
domain: "heuristics"
description: "受理を確かめる assert を拒否側の名前の試験に置くと、受理側の退行が拒否側の失敗として表示され原因が試験名から読めないため、受理側の試験の入力の組に 1 件足す。"
created: "2026-10-15T20:55:00+09:00"
generated: { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-10-15T20:55:00+09:00" }
sources:
  - type: "fixes"
    resource: "raw/fixes/20261015T113451Z-pr-3909.md"
  - type: "reviews"
    resource: "raw/reviews/20261015T114600Z-pr-3909.md"
tags: [testing]
confidence: medium
---

# 受理を確かめる assert は受理側の名前の試験の入力の組に置く

## 概要

受理を確かめる assert を拒否側の名前の試験に置くと、受理側の退行が拒否側の失敗として表示され原因が試験名から読めないため、受理側の試験の入力の組に 1 件足す。

## 詳細

- 全角空白を挟む参照の受理を確かめる assert が「閉じない」側の試験の末尾にあり、受理を壊す変異はその試験の失敗として表示された。
- 独立の assert を削り、受理側の試験の入力の組に 1 件足すだけで、退行が受理側の試験名で表示されるようになった。
- 入力の組に入れた assert は試験の本来の経路（判定関数を直接呼ぶのではなく、検証処理全体）を通るため、元の直接呼び出しより検査範囲が広い。受理を壊す 2 種類の変異がどちらも受理側の試験で検出された。

## 関連ページ

- [境界付き番号照合の試験は 2 桁の対象を置き、手順書から取り出した正規表現と突き合わせる](../patterns/bounded-number-match-test-two-digit-target-and-doc-extracted-parity.md)

## ソース

- [fix 結果（assert の移動）](../../raw/fixes/20261015T113451Z-pr-3909.md)
- [レビュー結果（変異での検出の確認）](../../raw/reviews/20261015T114600Z-pr-3909.md)
