---
type: "anti-patterns"
title: "jq の `//` は false を falsy として右辺へ倒す — boolean フィールドに既定値演算子を付けない"
domain: "anti-patterns"
description: "jq の alternative 演算子 `//` は null だけでなく false も右辺へ倒すため、boolean フィールドに `// null` のような既定値を付けると否定側の値が消える。false が正常系を表す判定（Ready かどうか等）では、正常系だけが恒常的に不成立になる。"
created: "2026-09-16T03:09:20Z"
generated: { by: "rite-wiki-ingest/claude-fable-5-1", at: "2026-09-16T03:09:20Z" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20260916T025549Z-pr-2896.md"
tags: ["jq", "bash", "gh", "boolean", "default-value"]
confidence: high
---

# jq の `//` は false を falsy として右辺へ倒す — boolean フィールドに既定値演算子を付けない

## 概要

jq の alternative 演算子 `//` は null だけでなく false も右辺へ倒すため、boolean フィールドに `// null` のような既定値を付けると否定側の値が消える。false が正常系を表す判定（Ready かどうか等）では、正常系だけが恒常的に不成立になる。

boolean を扱う `--jq` 式に `//` を付けない。キー欠落を null で受けたいだけなら素の `.field` で足りる。

## 詳細

### 症状

PR の draft 状態を `gh pr view --json isDraft --jq '.isDraft // null'` で取り、null を「判定不能」として後続の照合をスキップする hook があった。draft PR（true）とエラー時は意図どおり動くが、Ready PR では `isDraft` が false なので `//` が右辺へ倒れて null になり、**正常系だけが常に判定不能扱い**になる。Ready にした PR のボード列が compact のたびに取り残される、という形で表面化した。

誤りは 1 文字分の演算子にあり、修正も演算子を外すだけで済む。厄介なのは、true / エラーの経路は正しく動くため「動いていない」と気づきにくいことと、テストのモックが固定文字列を返していて式そのものが評価されていなかったため、退行がスイートで検出されなかったことにある。

### 原理

`a // b` は a が false または null（または empty）のとき b を返す。null-coalescing ではなく falsy-coalescing であり、boolean に対しては「false」と「欠落」を区別できない。文字列の `""` や数値の 0 は jq では truthy なので、この罠は boolean フィールドに固有である。

### 対処

- boolean フィールドの `--jq` 式に `//` を書かない。`.field` はキー欠落時に null を返すので、欠落を null で受ける目的にはそれで足りる
- 欠落と false を積極的に区別したいなら `has("field")` か `if .field == null then ... end` で明示する
- 既定値演算子が要るのは、文字列・数値・オブジェクトで欠落時の代替を与える場面に限る

### 検出

モックの gh がフィクスチャ JSON を実 jq に通していれば、`{"isDraft":false}` を与えた瞬間に退行が赤くなる。固定文字列を返すモックでは何度回しても検出できない。検出網の作り方は関連ページに委ねる。

## 関連ページ

- [テストダブルは被テスト式を実際に評価させ、helper 呼び出しの有無は記録モックの不在で pin する](../patterns/test-double-evaluates-real-expression-records-helper-calls.md)
- [gh のフィルタオプションは絞り込めていないのに成功して見える](./gh-filter-succeeds-without-filtering.md)

## ソース

- [レビュー結果](../../raw/reviews/20260916T025549Z-pr-2896.md)
