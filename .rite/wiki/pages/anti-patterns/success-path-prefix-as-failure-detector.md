---
type: "anti-patterns"
title: "成功経路にも出る prefix を失敗の判別子にしてはならない"
domain: "anti-patterns"
description: "ある helper で成立した「失敗専用 marker で判定する」形を、出力語彙を確認せずに別 helper へ複製すると、その prefix が成功側の告知にも使われていた場合、主経路で常時誤報告する機構になる。"
created: "2026-09-02T00:50:00Z"
generated: { by: "rite-wiki-ingest/grok-4.6", at: "2026-09-02T00:50:00Z" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20260901T165319Z-pr-2500.md"
  - type: "fixes"
    resource: "raw/fixes/20260901T170748Z-pr-2500.md"
tags: []
confidence: high
---

# 成功経路にも出る prefix を失敗の判別子にしてはならない

## 概要

ある helper で成立した「失敗専用 marker で判定する」形を、出力語彙を確認せずに別 helper へ複製すると、その prefix が成功側の告知にも使われていた場合、主経路で常時誤報告する機構になる。

## 詳細

`flow-state.sh reap-issue` の `WARNING: reap-issue:` は「stale を見つけて非 active 化する」という**成功側の告知**にも使われており、失敗専用ではない。`cleanup-pr-state-purge.sh` の `REVIEW_CLEANUP_PARTIAL_FAILURE=1` で成立した「marker で判定する」形を語彙未確認のまま写した結果、主経路で常時 `partial` を誤報告する機構になった。5 名の reviewer が独立に同じ結論へ到達した。

判別子として使えるかの検算は、helper 実装で当該文字列を grep し、成功経路の分岐にも現れないかを見ること。現れるなら bash 述語にはできない。hardened sibling が同じ helper に対して出力判定を採っていない場合、それは手抜きではなく同じ非対称を踏まえた選択である可能性を先に疑う。確認できない場合は判定を bash に持たせず、stderr を素通しして読み手の読解に委ねる。

失敗語彙を列挙して一致させる形も静かに壊れる。helper に新しい失敗メッセージが増えた時点で一致しなくなり「失敗なし」へ倒れる。既知の成功通知だけを除外し、残りをすべて失敗として扱えば、未知の語彙で fail-loud 側に倒れる。

## 関連ページ

- [インライン処理の helper 抽出は「helper が起動しない」経路を新設し、marker 不在＝成功の消費規則を破る](./helper-extraction-creates-unstarted-path.md)
- [helper を新しく消費するコードは、診断がどのチャネルに載るかを先に確認して既存消費者と同じ転記をする](../heuristics/helper-diagnostic-channel-checked-before-consuming.md)

## ソース

- [PR #2500 review results (cycle 2)](../../raw/reviews/20260901T165319Z-pr-2500.md)
- [PR #2500 fix results (cycle 2)](../../raw/fixes/20260901T170748Z-pr-2500.md)
