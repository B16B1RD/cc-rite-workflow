---
type: "heuristics"
title: "レビュアー選定は毎 cycle 回す — 前 cycle の cap 除外を次へ持ち越さない"
domain: "heuristics"
promote: rite-plugin
description: "候補数が cap を超えたための除外は、その cycle の正当な間引きであって次 cycle の除外理由にならない。選定判定を回さないと、差分スコープの cycle で候補が cap 以内に戻っても除外が恒久化し、初回起動の reviewer が CRITICAL をまとめて検出する。"
created: "2026-09-02T00:50:00Z"
generated: { by: "rite-wiki-ingest/grok-4.6", at: "2026-09-02T00:50:00Z" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20260901T180132Z-pr-2500.md"
tags: []
confidence: high
---

# レビュアー選定は毎 cycle 回す — 前 cycle の cap 除外を次へ持ち越さない

## 概要

候補数が cap を超えたための除外は、その cycle の正当な間引きであって次 cycle の除外理由にならない。選定判定を回さないと、差分スコープの cycle で候補が cap 以内に戻っても除外が恒久化し、初回起動の reviewer が CRITICAL をまとめて検出する。

## 詳細

security reviewer は cycle 1 で候補数が cap を超えたため正当に除外された。cycle 2/3 では候補が cap 以内だったにもかかわらず選定判定を回していなかった。結果、6 名が 3 cycle にわたって見逃していた CRITICAL を cycle 4 の初回起動が即座に検出した。blocking 件数の見かけの増加は収束の反転ではなく、選定漏れの顕在化だった。

「前 cycle で除外した」は次 cycle の除外理由にならない。差分スコープは調査範囲の限定であって選定手続きの省略ではない。毎 cycle、現在の候補集合に対して選定判定をやり直す。

関連して、cycle 上限到達後にフルレビューを 1 回挟む経験則がある。選定漏れは「範囲の外」ではなく「範囲内に呼ぶべき reviewer を呼んでいない」欠落なので、フルレビューを待たず選定そのものを毎 cycle 回す方が安い。

## 関連ページ

- [差分スコープのレビューは diff の外を基準以前に見られない — cycle 上限到達後にフルレビューを 1 回挟む](./differential-scope-review-blind-outside-diff.md)
- [re-review / verification mode でも初回レビューと同等の網羅性を確保する (Anti-Degradation Guardrail)](./reviewer-scope-antidegradation.md)

## ソース

- [PR #2500 review results (cycle 4)](../../raw/reviews/20260901T180132Z-pr-2500.md)
