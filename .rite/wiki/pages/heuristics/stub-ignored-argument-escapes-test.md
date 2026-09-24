---
type: "heuristics"
title: "外部コマンドの stub が無視した引数は、その引数が担う処理ごとテストから外れる"
description: "引数の一部だけで分岐して固定出力を返す stub は、無視した引数（フィルタ式・クエリ・選択条件）が担う処理を丸ごとテスト対象から外す。stub は受け取った式を実物の処理系で fixture に適用し、fixture には選ばれてはいけないが選ばれると結果が変わる要素を混ぜる。"
domain: "heuristics"
created: "2026-09-24T05:40:00Z"
generated: { by: "rite-wiki-ingest/claude-opus-5-5[1m]", at: "2026-09-24T05:40:00Z" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20260924T051109Z-pr-3025.md"
  - type: "fixes"
    resource: "raw/fixes/20260924T051654Z-pr-3025.md"
  - type: "reviews"
    resource: "raw/reviews/20260924T052324Z-pr-3025.md"
tags: ["test-stub", "fixture-design", "mutation-testing", "jq", "selection-logic"]
confidence: high
promote: rite-plugin
---

# 外部コマンドの stub が無視した引数は、その引数が担う処理ごとテストから外れる

## 概要

引数の一部だけで分岐して固定出力を返す stub は、無視した引数（フィルタ式・クエリ・選択条件）が担う処理を丸ごとテスト対象から外す。stub は受け取った式を実物の処理系で fixture に適用し、fixture には選ばれてはいけないが選ばれると結果が変わる要素を混ぜる。

## 詳細

**stub が「どの引数を無視しているか」を明示的に確認する。** API 呼び出しを stub で置き換えるテストで、stub がサブコマンドとパスだけを照合して fixture をそのまま返していると、呼び出し側が渡す選択式（例えば `--jq` のフィルタ）は一度も評価されない。選択式を存在しない marker に変える変異や、先頭要素を取る変異を入れてもテストは通り、本来直した不具合（誤ったコメントから情報を取る）がそのまま再現しても green になる。フィルタ式・クエリ・選択条件のような引数は、stub の中で実物の処理系（jq 等）に通して fixture に適用する。

**fixture には「選ばれてはいけないが、選ばれると結果が変わる要素」を入れる。** 対象だけが並んだ fixture では、選択式が壊れていても結果が同じになり、テストが区別できない。対象の前に、対象と似た内容を持つ非対象の要素を置くと、先頭を取る・全件を連結する・内容の有無で選ぶ、のどの誤りも結果に現れる。

**修正の検証では、生存した変異の再適用に加えて、同じロジックを別方向に壊す変異も足す。** 前回生存した変異が落ちるようになったことに加え、全件連結・末尾要素・内容の有無で選ぶといった別方向の変異も同じ assert で落ちるなら、その assert が選択を固定していると判断できる。

**否定の assert は、その行まで到達して落ちうるかを確かめる。** 「この呼び出しが含まれない」のような否定の assert は、対象の誤りが先に別の assert（終了コード等）で落ちる場合、単独では落ちる場面がない。変異を入れて実際にその行で失敗するかを確かめ、到達しないなら検出力を持たない行として扱う。

**stub が引数の個数と順序を厳密に要求するのは意図どおりの厳格さである。** 呼び出し側が引数を足したり順序を変えたりするとテストが落ちるが、これは呼び出し形を契約として固定する効果を持つ。

## 関連ページ

- [Mutation testing で test の真正性 (dead code 検出 + identification power) を empirical 検証する](../patterns/mutation-testing-test-fidelity.md)
- [テスト fixture の変異は各不変量・guard を単独で kill する配置で設計する](./fixture-mutation-isolates-invariants.md)
- [同じ記録を読み書きする経路は、対象の同定規則を 1 か所で共有する](./record-readers-and-writers-share-identification-rule.md)

## ソース

- [レビュー結果（cycle 1）](../../raw/reviews/20260924T051109Z-pr-3025.md)
- [fix 結果](../../raw/fixes/20260924T051654Z-pr-3025.md)
- [レビュー結果（cycle 2）](../../raw/reviews/20260924T052324Z-pr-3025.md)
