---
type: "heuristics"
title: "共有 helper への置き換えは既定値そのものではなく既定値の成り立ち方を変える"
domain: "heuristics"
description: "個別の既定値ロジックを共有 helper へ委譲すると、値が不在のときに続行する既定値そのものは同じでも、その既定値を生成する経路（リテラル初期化 → 空値を読んで case 分岐）が変わる。既定値の中身を assert しないテストは、この変化を検出できない。"
created: "2026-09-26T14:08:00Z"
generated: { by: "rite-wiki-ingest/claude-sonnet-5", at: "2026-09-26T14:08:00Z" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20260926T135844Z-pr-3165.md"
tags: []
confidence: high
---

# 共有 helper への置き換えは既定値そのものではなく既定値の成り立ち方を変える

## 概要

個別の既定値ロジックを共有 helper へ委譲すると、値が不在のときに続行する既定値そのものは同じでも、その既定値を生成する経路（リテラル初期化 → 空値を読んで case 分岐）が変わる。既定値の中身を assert しないテストは、この変化を検出できない。

## 詳細

config 読み取りロジックを個別実装から共有 helper へ置き換えると、config 不在時に「既定値で続行する」という外から見た動作自体は保たれたが、その既定値がどう生成されるかが変わった。置き換え前は不在時に値の読み取り自体をスキップし、リテラルな初期値がそのまま残っていた。置き換え後は `/dev/null` を共有 helper で読み、返ってくる空値を case 文の `*` アームが true として扱うことで既定値へ落ち着くようになった。

mutation testing で reviewer の変異 14 種を当てたところ、既定値の中身（enabled=true、auto_query 未設定等）を見ない assert が 1 件だけ生き残った。WARNING の有無や終了コードだけを pin しても、既定値そのものの中身を assert に含めない限り、この種の変異は検出できない。

さらに、パイプを通す代入（`関数呼び出し | tr ...` のような形）は `pipefail` が宣言されていないと関数側の `return 1` が失われ、読めない config でも opt-out の既定値で静かに続行してしまう（置き換え前から潜在していた別の問題）。

教訓: 個別ロジックを共有 helper へ委譲するリファクタでは、外から見た既定動作（同じ既定値で続行する）が変わらなくても、既定値を生成する内部経路は変わりうる。テストは既定値の中身そのものを assert に含めないと、この種の変異を見逃す。

## 関連ページ

- [オプションを常に明示するテストは、既定値解決という最も壊れやすい経路を丸ごと素通りさせる](../anti-patterns/explicit-option-tests-bypass-default-resolution.md)
- [アサーションの検証強度は「該当行を壊して赤くなるか」でしか測れない](../heuristics/mutation-testing-measures-assertion-strength.md)

## ソース

- [レビュー結果](../../raw/reviews/20260926T135844Z-pr-3165.md)
