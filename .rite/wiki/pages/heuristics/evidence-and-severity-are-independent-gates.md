---
type: "heuristics"
title: "実測の有無と severity は独立した 2 軸で、両方を満たさないと修正対象にならない"
domain: "heuristics"
description: "実測必須ゲートは「測っていない指摘を blocking にしない」ためのもので、測ってあっても重要度が閾値に届かなければ fatal にならない。実行時に何かが壊れる帰結クラスでも、severity が中位なら修正ループは動かない。"
created: "2026-09-06T16:10:23Z"
generated: { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-26T09:08:27Z" }
verified:
  - { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-26T08:46:38Z" }
  - { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-26T09:08:27Z" }
sources:
  - type: "fixes"
    resource: "raw/fixes/20260906T144434Z-pr-2582.md"
  - type: "reviews"
    resource: "raw/reviews/20260926T083923Z-pr-3129.md"
  - type: "fixes"
    resource: "raw/fixes/20260926T084101Z-pr-3126.md"
  - type: "fixes"
    resource: "raw/fixes/20260926T085821Z-pr-3125.md"
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

### 同じ PR で直したい実行時帰結は severity 判定で詰める

ガード迂回や後続ゲートの停止のように実行時帰結を持つ指摘でも、実測付き MEDIUM は non-blocking へ移送され、修正コミットは作られない。その PR の中で直すべきだと考えるなら、fix 側で扱いを変えるのではなく、reviewer 側で HIGH 以上が妥当かを severity 判定の段階で詰める。移送された指摘は non-blocking 記録と follow-up Issue で追跡され、PR 自体はそのまま収束する。

### レビューの fix-needed と修正 0 件の fix 完了は矛盾しない

レビュー側の blocking 判定は実測の有無で決まり、severity に依存しない。実測付きの LOW-MEDIUM でも blocking として数えられ、総合評価は fix-needed になる。一方、fix 側の fatal 判定は severity が CRITICAL / HIGH のものに限る。そのため、レビューが fix-needed を返した直後の fix が、コードを 1 行も変えずに非 fatal 移送だけで正常終了することがある。これは想定された経路であり、どちらかのゲートの不具合ではない。

複数の reviewer の評価が割れた指摘（一方は仮説として自らの監査ログで除外し、他方は blocking として提出した）も、統合側が主観で先に握り潰さず、機械ゲート（Likelihood-Evidence と実測必須ゲート）へそのまま通す。評価の相違はゲートの判定と記録に残り、後から追える。

## 関連ページ

- [実測 likelihood ゲートは evidence アンカーとセットで運用する](./observed-likelihood-gate-with-evidence-anchors.md)
- [reviewer の 0 件は正当な収束として扱う](./reviewer-zero-finding-as-legitimate-convergence.md)

## ソース

- [fix 結果](../../raw/fixes/20260906T144434Z-pr-2582.md)
- [fix 結果](../../raw/reviews/20260926T083923Z-pr-3129.md)
- [fix 結果](../../raw/fixes/20260926T084101Z-pr-3126.md)
- [fix 結果](../../raw/fixes/20260926T085821Z-pr-3125.md)
