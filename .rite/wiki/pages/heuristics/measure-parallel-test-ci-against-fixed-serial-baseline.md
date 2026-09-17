---
type: "heuristics"
title: "並列テストのCI性能は同一実装の複数回計測と固定直列基準で判定する"
domain: "heuristics"
description: "並列化の速度目標を判定するときは、同じ実装SHAで複数回のCI完走値を取り、最遅値と平均値を固定した直列基準に照らす。timeout は実測後に算定し、設定変更後は通常CIで別に確認する。"
created: "2026-09-17T03:15:00Z"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260917T031500Z-pr-2920-final.md"
  - type: "fixes"
    resource: "raw/fixes/20260917T000451Z-pr-2920.md"
tags: ["ci", "performance", "parallel-tests", "measurement", "timeout"]
confidence: high
generated: { by: "rite-wiki-ingest/gpt-6-astra", at: "2026-09-17T03:15:00Z" }
---

# 並列テストのCI性能は同一実装の複数回計測と固定直列基準で判定する

## 概要

並列テストの速度目標は、同じ実装の複数回CI完走値と、明示した直列基準を使って判定する。最遅 job 時間と平均 hook 時間は別の指標なので、job の平均だけで timeout を決めたり、hook の最速値だけで速度目標を主張したりしない。

## 適用

1. 比較対象の実装SHAと直列基準（OS、suite、実行条件、所要秒）を記録する。
2. 同じ実装SHAで各OSの複数回CIを完走させる。キャンセルや失敗を除外して成功扱いせず、足りない完走サンプルを補う。
3. timeout の受入れには最大 job 時間を使い、速度比には対象suite時間の算術平均を直列基準で割る。両方の指標でOS別の条件を確認する。
4. skip 内訳と suite 成功も時間と併記する。性能向上でテストが実行されなくなった状態を成功と数えない。
5. timeout は合意された余裕率を最大実測値へ適用してから設定する。timeout のみ変更した後は、通常CIでその設定を検証する。

## 事例

10回の完走測定で全173 hook testsと4 suiteが成功した。Ubuntu hook平均は152.8/416秒（36.7%）、macOSは337.6/726秒（46.5%）。macOS job最大559秒で、600秒未満の目標を満たした。最大値の2倍を分に切り上げたtimeoutは19分となり、設定変更後の通常CIも成功した。詳細は [Raw Source](../../raw/reviews/20260917T031500Z-pr-2920-final.md) を参照。

## 関連ページ

- [GNU shim の期限契約](gnu-tool-shim-full-contract-reproduction.md)
