---
type: "heuristics"
title: "degraded と fail の境界は「差し戻して直るか」で引く"
domain: "heuristics"
description: "gate に「縮退 (degraded、判定不能だが続行)」と「失敗 (fail、差し戻す)」の 2 出口があるとき、振り分けの基準を**状態の種類**（「存在しない」「読めない」「解決できない」）で書くと、必ずどちらかの方向に間違える。"
created: "2026-08-07T18:40:00+09:00"
sources:
  - type: "fixes"
    resource: "raw/fixes/20260807T013056Z-pr-2130.md"
  - type: "reviews"
    resource: "raw/reviews/20260807T011214Z-pr-2130.md"
tags: []
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-08-07T18:40:00+09:00" }
---

# degraded と fail の境界は「差し戻して直るか」で引く

## 概要

gate に「縮退 (degraded、判定不能だが続行)」と「失敗 (fail、差し戻す)」の 2 出口があるとき、振り分けの基準を**状態の種類**（「存在しない」「読めない」「解決できない」）で書くと、必ずどちらかの方向に間違える。正しい基準は**差し戻し先でその原因を解消できるか**である。

## 詳細

ある PR の cycle 1 で、degraded 境界の不一致を 3 reviewer が独立に検出した。

**何が起きたか**: Issue は degraded 条件を「解決できない / 読めない」と定めていたが、実装は「存在しない」を degraded に、「読めない」を fail に振っていた（`find` の rc を検査していなかった）。結果、「results dir は存在するが permission で読めない」が fail に落ちた。**fail の差し戻し先を何度実行しても permission は解消しない**ため、非収束ループになる。

しかも同じ helper の docstring 自身が「置換漏れを fail にすると非収束になるので degraded に倒す」と書いていた。**同一ファイル内で自ら宣言した論拠を、別経路に適用し忘れた**形の伝播漏れである。

**両方向に害がある**:

- 直らないものを fail にする → 非収束ループ（差し戻し → 同じ失敗 → 差し戻し）。オペレーターは同じコマンドを繰り返す
- 直るものを degraded にする → 守るべき Given で機械強制が降りる。gate があるのに通過する

**基準**: 「その原因は、差し戻された側の作業で解消できるか」

| 原因 | 差し戻しで直るか | 出口 |
|---|:--:|---|
| 検査対象そのものが未作成・内容が誤り | 直る | **fail** |
| placeholder の置換漏れ（LLM 側の substitute 失敗） | 直らない | degraded |
| permission / 環境不備 / 依存コマンド不在 | 直らない | degraded |
| 一時ファイル作成失敗などの実行環境要因 | 直らない | degraded |

**書くときの手順**:

1. 分岐を足す前に、その状態に至る**実際の原因**を列挙する（「読めない」は permission・IO error・不在の 3 つを畳んだ表現で、出口が同じとは限らない）
2. 各原因について「差し戻し先で直せるか」を 1 つずつ答える。答えが割れるなら分岐が粗い
3. 同じファイル内に既存の degraded/fail 判断があるなら、**その根拠を読んで新しい分岐へ適用する**。docstring に書いた論拠は他経路にも当てはまることが多い
4. `find` / `stat` などの rc を検査せず「出力が空 = 不在」と扱っていないか確認する。permission による空出力を不在と読むと、この振り分け自体が実行されない

**関連する落とし穴**: degraded と pass は rc が同値（どちらも 0）になる設計が多い。テストで rc だけを assert すると degraded への退行を検出できないため、**その経路が出すはずの marker の不在**を pin する必要がある。

## 関連ページ

- [消費側だけに足した allowlist は生成側の値域と食い違い「成功しているのに永久に失敗」の非収束を作る](../anti-patterns/consumer-allowlist-wedges-producer-value-range.md)
- [終端状態は「到達した事実」で記録し、可変値との境界比較で代用しない](./terminal-state-recorded-not-boundary-compared.md)

## ソース

- [PR #2130 fix results](../../raw/fixes/20260807T013056Z-pr-2130.md)
- [PR #2130 review results](../../raw/reviews/20260807T011214Z-pr-2130.md)
