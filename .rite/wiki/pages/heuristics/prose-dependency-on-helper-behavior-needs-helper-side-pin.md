---
type: "heuristics"
title: "散文が helper の挙動に新たに依存し始めたら、helper 側にも pin を置く"
domain: "heuristics"
description: "手順書が「helper が値を保持するので書き込みは 1 箇所でよい」のような設計上の依存を新設したとき、散文側の pin だけでは受入基準の半分しか守られない。helper の当該挙動を変異させても既存スイートが全件 green なら、単一書き込み設計を成り立たせている側が無防備になっている。"
created: "2026-08-29T15:42:53Z"
generated: { by: "rite-wiki-ingest/claude-opus-5[1m]", at: "2026-08-29T15:42:53Z" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20260829T152045Z-pr-2466.md"
tags: ["static-contract-test", "pin-coverage", "layer-crossing-dependency", "merge-preserve"]
confidence: high
---

# 散文が helper の挙動に新たに依存し始めたら、helper 側にも pin を置く

## 概要

手順書が「helper が値を保持するので書き込みは 1 箇所でよい」のような設計上の依存を新設したとき、散文側の pin だけでは受入基準の半分しか守られない。helper の当該挙動を変異させても既存スイートが全件 green なら、単一書き込み設計を成り立たせている側が無防備になっている。

## 詳細

### 依存が層をまたぐと pin も層をまたぐ必要がある

散文（手順書）が「ここで 1 回書けば、以降の呼び出しでは保持される」と書くとき、その受入基準は 2 つの独立した事実に依存する。

1. 散文が指定した箇所で実際に書き込むこと（散文側の契約）
2. 後続の呼び出しがその値を保持すること（helper 側の挙動）

散文の pin は 1 しか固定しない。2 を破る変更（helper の merge-preserve を既定値代入に変えるなど）は、散文を一切触らずに受入基準を壊す。実測では helper の該当行を「保持」から「既定値で上書き」へ変異させても、既存スイート 240 件が全件 green だった。

### 見分け方

散文に次の形の文が新しく入ったら、helper 側の pin の有無を確認する。

- 「以降も維持されるため、書き込みは本ステップの 1 箇所でよい」
- 「未指定のときは既存値が保たれる」
- 「helper 側が正規化するのでここでは検証しない」

いずれも **helper の特定の挙動を load-bearing にする宣言**であり、その挙動が変われば散文の記述は未変更のまま偽になる。

### pin の置き方

helper のテストスイートに、その挙動そのものを固定する短いケースを足す。散文が依存している往復をそのまま書けばよい。

```
set --field N を指定して書く → フラグ無しで別の set を打つ → get が N を返す
```

`0` や既定値に戻っていれば FAIL する。既存のサンドボックスパターンで数行に収まる。

### 帰結クラスとの関係

この種の指摘は「テストの穴」であり帰結は検出網に留まるため、実測付き（変異で既存スイートが green のまま通ることを確認済み）でも class B として non-blocking に降格されうる。降格されても消えるわけではなく、非実測指摘の記録として残り、マージ時に follow-up として拾える形にしておく。blocking にしないことと、記録しないことは別である。

## 関連ページ

- [契約を N 箇所に追記したら pin も N 箇所あるかを数え合わせる](../patterns/contract-additions-and-pins-one-to-one.md)
- [Mutation testing で test の真正性 (dead code 検出 + identification power) を empirical 検証する](../patterns/mutation-testing-test-fidelity.md)

## ソース

- [レビュー結果](../../raw/reviews/20260829T152045Z-pr-2466.md)
