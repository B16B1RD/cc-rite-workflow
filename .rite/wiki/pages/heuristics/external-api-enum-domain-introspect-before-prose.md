---
type: "heuristics"
title: "外部 API の enum を散文へ写す前に値域を introspection で実測する"
domain: "heuristics"
description: "外部 API が返す enum（GitHub の `IssueStateReason` 等）の値域を記憶や文脈から書き起こすと、SoT 散文・`case` の明示アーム・catch-all の 3 者が同時に誤った値域の上に建ち、実在する値が黙って別の終端へ配られる。"
created: "2026-08-31T14:09:34Z"
generated: { by: "rite-wiki-ingest/claude-opus-5", at: "2026-08-31T14:09:34Z" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20260831T071720Z-pr-2494.md"
  - type: "fixes"
    resource: "raw/fixes/20260831T072532Z-pr-2494.md"
tags: ["external-api", "enum", "graphql", "sot-prose", "case-dispatch", "introspection"]
confidence: high
---

# 外部 API の enum を散文へ写す前に値域を introspection で実測する

## 概要

外部 API が返す enum（GitHub の `IssueStateReason` 等）の値域を記憶や文脈から書き起こすと、SoT 散文・`case` の明示アーム・catch-all の 3 者が同時に誤った値域の上に建ち、実在する値が黙って別の終端へ配られる。値域は書く前に introspection で実測する。

## 詳細

起点事例では、Issue 本文が「`stateReason` は `COMPLETED` と `NOT_PLANNED` の 2 値を返す」と宣言し、その前提の上に SoT 節・reconcile の `case`・派生 rationale の 3 者が同時に建てられた。実際の `IssueStateReason` は `REOPENED` / `NOT_PLANNED` / `COMPLETED` / `DUPLICATE` の 4 値で、`DUPLICATE` は明示アームに一致せず catch-all へ落ちて別の終端 Status へ配られていた。**6 reviewer 中 5 人が独立に同じ根因へ到達**した。

### なぜ 3 箇所が同時に壊れるのか

誤った値域は 1 箇所の誤記ではなく、**設計の前提**として複数の成果物へ同時に伝播する:

| 成果物 | 誤った値域が生む結果 |
|--------|---------------------|
| SoT 散文 | 「`wontfix` / `duplicate` / `superseded` を含む」のような、実装が実現していない意味を読者へ約束する |
| `case` の明示アーム | 実在する値が一致せず、意図しないアームへ落ちる |
| catch-all | 「未知の値」用に書いたつもりの枝が、**既知で正しい値**を沈黙で吸収する |

3 者が同じ前提を共有しているため、どれか 1 つを読んでも矛盾に見えない。**発見は外部から値域を持ち込んだときにしか起きない**。

### 実測の作法

- GraphQL なら `__type(name: "IssueStateReason") { enumValues { name } }` を introspection で引く。REST なら該当フィールドの公式スキーマ／OpenAPI を当たる。「よく見る値」を数え上げても値域にはならない
- 実測した値域を、**散文と dispatch の両方に同じ語彙で**反映する。散文だけ直して `case` を放置すると、次の読者が散文を根拠に分岐を読み違える
- 値域のうち**宛先を決めていない値**があるなら、決めていないことを WARNING と Decision Log で可視化する。黙って catch-all へ流すと「未決」が「決定済み」に見える（[契約が誤った前提の上にあるときは dispatch を保ちつつ前提を訂正する](../patterns/contract-literalism-false-premise-third-exit.md)）

### 派生文書は SoT の限定句ごと写す

同じ事例で、SoT 側が「その option を持たない board では option-ID lookup が失敗する」と限定していたのに、派生 rationale の言い換えが「両方の終端値に到達可能」と**限定句を落として無条件化**していた。派生側だけを読む人間には到達不能な保証が約束される。SoT を言い換えるときは限定句を核として残し、限定を落とした要約を作らない。

### 参照先は grep で実在を確認してから書く

同じレビューで「§2.4.4 の alias 表と違って」という対比が指摘された。§2.4.4 に alias 表は無く、該当語はその新規行にしか現れなかった。節番号・表名・ファイルパスを引く対比を書くときは、書いた直後に grep して実在を確認する。

## 関連ページ

- [prefix 分岐 case の `*)` catch-all は未知の将来 prefix を silent に default 動作へ吸収する](../anti-patterns/catch-all-case-arm-absorbs-future-prefix.md)
- [Enum 拡張時は few-shot example で全 enum 値の使用例を網羅する (calibration coverage gap 防止)](./enum-extension-few-shot-coverage-completeness.md)
- [SoT 文書の path 参照は本 PR マージ時点の origin/develop で existence check する](./sot-path-reference-existence-check.md)

## ソース

- [5 reviewer が独立に enum 値域の誤りへ到達](../../raw/reviews/20260831T071720Z-pr-2494.md)
- [値域の誤りを認めて散文を正し、catch-all を沈黙させない](../../raw/fixes/20260831T072532Z-pr-2494.md)
