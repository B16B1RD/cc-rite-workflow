---
type: "heuristics"
title: "実測の有無と severity は独立した 2 軸で、両方を満たさないと修正対象にならない"
domain: "heuristics"
description: "実測必須ゲートは「測っていない指摘を blocking にしない」ためのもので、測ってあっても重要度が閾値に届かなければ fatal にならない。実行時に何かが壊れる帰結クラスでも、severity が中位なら修正ループは動かない。"
created: "2026-09-06T16:10:23Z"
generated: { by: "rite-wiki-ingest/claude-opus-5[1m]", at: "2026-09-06T16:10:23Z" }
sources:
  - type: "fixes"
    resource: "raw/fixes/20260906T144434Z-pr-2582.md"
tags: ["review-loop", "severity", "evidence-gate", "convergence"]
confidence: high
---

# 実測の有無と severity は独立した 2 軸で、両方を満たさないと修正対象にならない

## 概要

実測必須ゲートは「測っていない指摘を blocking にしない」ためのものである。測ってあることは fatal の必要条件であって十分条件ではない。帰結クラスが「実行時に何かが壊れる」であっても、severity が中位なら修正ループは動かず、指摘は記録へ送られる。

## 詳細

### 設計上のトレードオフ

この 2 軸構成は収束を保証する代わりに、実行時に壊れうる非 fatal 指摘を記録へ送り続ける。それは欠陥ではなく明示的な選択である。記録された指摘は follow-up として拾う経路が別に要る。

### 修正コミットが無い cycle の扱い

fatal 0 件は「何もしない」ではない。移送した件数と記録先を報告して通常完了へ進む。ここを「0 件だったので終了」に丸めると、記録契約が空文になり、次の cycle が「前 cycle で何が記録されたか」を読めなくなる。修正コミットの有無に関わらず state の永続化と報告は必須である。

## 関連ページ

- [実測 likelihood ゲートは evidence アンカーとセットで運用する](./observed-likelihood-gate-with-evidence-anchors.md)
- [reviewer の 0 件は正当な収束として扱う](./reviewer-zero-finding-as-legitimate-convergence.md)

## ソース

- [fix 結果](../../raw/fixes/20260906T144434Z-pr-2582.md)
