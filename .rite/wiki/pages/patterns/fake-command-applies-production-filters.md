---
# Domain knowledge only; rite workflow candidates stay in raw.
type: "patterns"
title: "テスト用の偽コマンドは本番が渡す絞り込み引数を照合して適用する"
domain: "patterns"
description: "偽の gh が --jq を無視したり --json のフィールド指定に関係なく全件を返したりすると、本番の取得範囲を減らす変異がテストを通り抜ける。偽コマンドは本番の引数を照合し、フィルタを fixture に実際に適用して指定分だけ返す。"
created: "2026-10-15T02:42:28Z"
generated: { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-10-15T02:42:28Z" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20261014T234324Z-pr-3903.md"
  - type: "fixes"
    resource: "raw/fixes/20261014T235100Z-pr-3903.md"
  - type: "reviews"
    resource: "raw/reviews/20261015T005949Z-pr-3903.md"
  - type: "fixes"
    resource: "raw/fixes/20261015T011237Z-pr-3903.md"
  - type: "reviews"
    resource: "raw/reviews/20261015T013253Z-pr-3903.md"
tags: ["test", "stub", "fixture", "mutation-testing", "gh"]
confidence: high
---

# テスト用の偽コマンドは本番が渡す絞り込み引数を照合して適用する

## 概要

偽の gh が --jq を無視したり --json のフィールド指定に関係なく全件を返したりすると、本番の取得範囲を減らす変異がテストを通り抜ける。偽コマンドは本番の引数を照合し、フィルタを fixture に実際に適用して指定分だけ返す。

## 詳細

外部コマンドを偽物に差し替えて手順を実行するテストは、偽物が寛大なほど検出力を失う。どの引数でも全フィールドを返す偽物なら、本番が必要なフィールドを取らなくなっても、テストは偽物の余分な出力に救われて通る。

- `--jq` は無視せず、fixture に `jq` で実際に適用した結果を返す。フィルタ式の誤りがテストで見える。
- `--json` のフィールド、`-R` の対象リポジトリなど、本番が渡す絞り込みを照合し、指定された分だけを返す。想定外の引数は失敗させる。
- 本物のコマンドが要るときは、偽物を PATH に置く前に求めた絶対パスで呼ぶ。偽物から自分自身（`$0` や PATH 上の同名コマンド）を呼ぶと無限に増殖する。
- 「件数上限を外した」ことを固定するには、上限を超える件数の候補を fixture に置き、本物の対象を最後の位置に置く。旧構文が無いことを grep するだけでは、別の書き方で上限を戻す変更を検出できない。
- 失敗経路は、結果の値だけでなく理由の文まで照合する。値だけを見ると、別の経路が偶然同じ値を出す変異が通る。

閉じた対象も照合する側のように、取得した値を判定に使わない経路では、そのフィールドを減らす変異は挙動を変えない等価変異になる。生き残ったからといってテストの欠陥とは限らない。

## 関連ページ

- [Mutation testing で test の真正性 (dead code 検出 + identification power) を empirical 検証する](./mutation-testing-test-fidelity.md)
- [テスト fixture の変異は各不変量・guard を単独で kill する配置で設計する](../heuristics/fixture-mutation-isolates-invariants.md)

## ソース

- [手順書の bash を偽の gh で実行するテストへ替えたレビュー結果](../../raw/reviews/20261014T234324Z-pr-3903.md)
- [偽の gh がフィルタ式を実際に適用するようにした修正結果](../../raw/fixes/20261014T235100Z-pr-3903.md)
- [偽の gh の引数無視と件数上限の未固定を扱ったレビュー結果](../../raw/reviews/20261015T005949Z-pr-3903.md)
- [偽コマンドが絞り込みを照合するようにした修正結果](../../raw/fixes/20261015T011237Z-pr-3903.md)
- [等価変異になる経路を確かめた再レビュー結果](../../raw/reviews/20261015T013253Z-pr-3903.md)
