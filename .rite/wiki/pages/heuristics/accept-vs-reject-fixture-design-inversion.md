---
type: "heuristics"
title: "accept fixture と reject fixture は設計目的が逆 — 安全側の形状を両方に適用すると順序契約が pin できなくなる"
domain: "heuristics"
description: "分岐チェーンに新しいガードを挿入したとき、「そのガードが先行分岐より前にある」という順序契約は fixture の形状に依存して観測可能／不可能が決まる。"
created: "2026-07-27T10:57:51+09:00"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260727T001018Z-pr-2035.md"
  - type: "fixes"
    resource: "raw/fixes/20260727T002133Z-pr-2035.md"
  - type: "fixes"
    resource: "raw/fixes/20260727T004206Z-pr-2035.md"
tags: []
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-07-27T10:57:51+09:00" }
---

# accept fixture と reject fixture は設計目的が逆 — 安全側の形状を両方に適用すると順序契約が pin できなくなる

## 概要

分岐チェーンに新しいガードを挿入したとき、「そのガードが先行分岐より前にある」という順序契約は fixture の形状に依存して観測可能／不可能が決まる。accept 側の fixture を「先行 invariant が短絡する形状」に倒すのは正しい判断（そうしないと受理判定が観測できず vacuous pass になる）だが、**同じ判断を reject fixture にも適用すると、両分岐が発火しうる形状が 1 つも無くなり、順序退行の mutation が全テスト通過する**。

## 詳細

### 観測された失敗

起点事例は型ガードを cross-field invariant の前段に挿入した。テストは 9 fixture・107 assertion を持ち、述語軸の mutation（存在必須化 / `all()`→`any()` / 型検査の削除）はすべて KILL された。しかし**配置軸**（ガードを invariant の後段へ移動）の mutation だけが 107 passed のまま生存した。

原因は全 fixture が `overall_assessment: "fix-needed"` だったこと。この値では先行する invariant が短絡してしまい、ガードと invariant のどちらが先に発火したかが出力に現れない。

### fixture 設計目的の非対称

| fixture | 目的 | 望ましい形状 |
|---|---|---|
| accept（ガードを通過すべき入力） | ガードが**受理**したことを観測する | 先行分岐が短絡する形状に倒す。そうしないと先行分岐が先に受理して、ガードが評価されたかどうかが分からない（vacuous pass） |
| reject（ガードが弾くべき入力） | ガードが**先に**発火したことを観測する | 先行分岐も発火しうる形状にする。両方が鳴る状態で「どちらの reason が出たか」を見て precedence を判定する |

起点事例では accept 側に `"fix-needed"`（invariant を短絡させる）、reject 側と順序 fixture に `"mergeable"`（invariant も発火しうる）を割り当てることで、両側の目的が満たされた。

### 区間制約は両端を pin する

「A と B の間に挿入」という要求に対して、下側（B より前）だけを pin して上側（A より後）を pin しないと、上側へ移す mutation が生存する。起点事例では上側退行が「required-fields で弾かれるはずのファイルが型ガードで弾かれ、rename されなくなる」という**副作用の消失**として観測できたが、既存 fixture では両者の差が出ない形状（`findings` キー自体が無い）だったため検出できなかった。

**処方**: 区間制約には「下限を破る fixture」と「上限を破る fixture」を別々に用意する。

### 実施手順

1. ガードを挿入したら、まず順序退行の mutation を当てる（ガードを 1 つ下へ移す）
2. テストが全通過したら、それは fixture 形状の問題である。ガードと先行／後続分岐の**両方が発火しうる入力**を作る
3. その fixture で「どちらの reason / marker が出たか」を positive に assert する
4. 区間制約なら上下 2 つの fixture を用意する

## 関連ページ

- [テスト fixture の変異は各不変量・guard を単独で kill する配置で設計する](./fixture-mutation-isolates-invariants.md)
- [Mutation testing で test の真正性 (dead code 検出 + identification power) を empirical 検証する](../patterns/mutation-testing-test-fidelity.md)
- [否定アサーションには positive control を添える — `|| true` は唯一の crash signal を消す](../patterns/negative-assertion-positive-control.md)

## ソース

- [PR #2035 review results](../../raw/reviews/20260727T001018Z-pr-2035.md)
