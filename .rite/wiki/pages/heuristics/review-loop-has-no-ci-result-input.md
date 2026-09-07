---
type: "heuristics"
title: "CI の観測をレビューへ渡し、失敗の帰属と採否を分ける"
domain: "heuristics"
description: "レビュー対象コミットの CI check を入力とレポートに含めることで、ローカルと異なる環境での失敗を早期に確認できる。赤い check だけでは原因を断定せず、変更との対応と失敗出力を確認して既存の実測基準で採否する。"
created: "2026-09-06T16:10:23Z"
generated: { by: "rite-wiki-ingest/gpt-6-astra", at: "2026-09-07T11:07:42Z" }
promote: rite-plugin
sources:
  - type: "reviews"
    resource: "raw/reviews/20260906T155431Z-pr-2582.md"
  - type: "reviews"
    resource: "raw/reviews/20260907T110021Z-pr-2606.md"
tags: ["review-loop", "ci", "blind-spot", "merge-gate"]
confidence: high
---

# CI の観測をレビューへ渡し、失敗の帰属と採否を分ける

## 概要

レビュー対象コミットの CI check を入力とレポートに含めることで、ローカルと異なる環境での失敗を早期に確認できる。赤い check だけでは原因を断定せず、変更との対応と失敗出力を確認して既存の実測基準で採否する。

## 詳細

### CI の観測をレビューの入力に含める

CI はローカルと異なるホストやツールで動くため、ローカルの成功だけでは CI 上の成功を保証できない。allowed failure があると workflow 全体の成功と個々の job の結論も一致しない。レビューで check の状態・結論・詳細 URL を確認することにより、マージ直前まで失敗の発見が遅れる経路を減らせる。

`pr-review` はレビュー対象 SHA と PR HEAD の一致を確認し、共有 helper で check を分類する。通常・verification 両モードの reviewer へ snapshot を渡し、統合レポートと E2E の終了行へ状態を表示する。取得不能・SHA 不一致は理由付き unknown、pending は未完了として扱い、レビュー中に待機や rerun を行わない。マージ時の待機・override・分類基準は merge の責務として維持する。

### 失敗の表示と blocking 判定を分ける

- 失敗 job を、集約状態が pending の場合もレポートへ表示する。
- 変更ファイルとの対応と実際の失敗出力を確認してから、既存の failing test アンカーで指摘する。
- 無関係な flaky や allowed failure を、赤い check だけを根拠に一律 blocking にしない。
- 状態の snapshot は取得時点の観測であり、CI 完了やその後のマージ可否を保証しない。

## 関連ページ

- [GNU 形式の sed に依存する fixture は BSD 環境で失敗する](../anti-patterns/gnu-sed-inplace-silently-noop-on-bsd.md)
- [差分スコープのレビューは差分の外を見ない](./differential-scope-review-blind-outside-diff.md)

## ソース

- [CI 失敗の発見が遅れるレビューの観測](../../raw/reviews/20260906T155431Z-pr-2582.md)
- [CI 入力とレポートの接続の検証](../../raw/reviews/20260907T110021Z-pr-2606.md)
