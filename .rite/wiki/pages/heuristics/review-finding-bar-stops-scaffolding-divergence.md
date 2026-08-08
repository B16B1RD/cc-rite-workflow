---
type: "heuristics"
title: "レビューが足場を対象に発散したら finding の基準を prompt で明示して止める"
domain: "heuristics"
promote: rite-plugin
description: "修正は新しいレビュー対象面を作るため、指摘件数だけを見ると収束しない。受入基準が満たされた後の指摘が「レビュー対応で追加したテスト pin・コメント・診断出力」を対象にし始めたら、findings を production の欠陥と blocking gate 上の未 pin に限定する基準を reviewer prompt に明示する。"
created: "2026-07-25T14:18:43Z"
updated: "2026-07-25T14:18:43Z"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260725T112757Z-pr-2017-cycle5.md"
tags: []
confidence: medium
---

# レビューが足場を対象に発散したら finding の基準を prompt で明示して止める

## 導入判断

- **使う**: review⇄fix ループで指摘件数が減らず、直近サイクルの指摘が「前サイクルの修正が追加した要素」を対象にしているとき
- **使わない**: 指摘が依然として production コードや元の受入基準を対象にしているとき（それは正常な収束途上であり、基準を絞ると本物を取りこぼす）

## 概要

修正 1 件は新しいレビュー対象面を 1 つ作る。テスト pin を足せばその pin がレビュー対象になり、pin の環境依存を直せばその floor がレビュー対象になる。この連鎖は指摘件数の推移だけでは収束と区別できない。**サイクル数ではなく「指摘が production を対象にしているか」で収束を判断し**、足場を対象にし始めたら reviewer prompt 側で基準を絞る。

## 詳細

### 発散の観測

修正件数の推移は `4, 2, 3, 4` で、件数だけ見ると収束していない。しかし内訳は明確に分かれていた:

| cycle | 指摘の対象 |
|---|---|
| 1 | production hook の実バグ（受入基準そのもの） |
| 2 | cycle 1 が追加した TC（portable shim 未使用・閾値の値が未 pin） |
| 3 | cycle 2 が追加した防御行（pin なし・根拠コメントの誤り） |
| 4 | cycle 3 が追加した pin（環境依存で vacuous 化） |

受入基準 3 項目は cycle 1 で達成され、以後 4 サイクル実測で確認され続けていた。cycle 2 以降の 9 件は **すべてレビュー対応で追加した足場** が対象だった。

### 基準を明示する

cycle 5 の reviewer prompt に次を追加した:

> **findings は以下のいずれかに限定する**:
> 1. production コードの実際の欠陥（標準的な利用フローで到達する経路があるもの）
> 2. production のセキュリティコントロールが blocking gate（Linux CI・短い `$TMPDIR`・通常の cwd）で未 pin になっているテストギャップ
>
> 以下は推奨事項へ回す: 足場の異常環境下での堅牢性、コメントの言い回し・参照先、「より良い書き方がある」類の提案

結果、4 名全員が 0 findings を返し、それまで findings として上がっていた同種の観察は推奨事項に分類された。**基準が曖昧だと reviewer は安全側に倒して everything を blocking にする** — スコープ判定ルール（revert test）は「この PR 由来か」しか問わず、「production の欠陥か足場の改善提案か」は問わないため、両者が同じ blocking finding として出てくる。

### 繰り返し挙がる推奨は早めに決着させる

同一の推奨が 3 サイクル連続で挙がっていた（診断ログの追加・fixture の cleanup・正規表現の前提のコメント化）。放置すると毎サイクル再提出され、レビューコストが線形に増える。最終サイクルの前にまとめて対応するか、Decision Log に「対応しない」と記録して打ち切る。

### 誤用への警戒

この基準は「レビューを早く終わらせる」ためではない。足場の指摘が実際に production の防御を守っていた実例が同じ PR にある — cycle 2 の「portable shim を使っていない」は、対象プラットフォームでテストが hard fail する実害を持っていた。**基準を絞るのは、受入基準が達成済みで、かつ直近の指摘が production の到達経路を示せなくなってからにする。**

## 関連ページ

- [「invariant は logic 上成立」を信頼せず empirical reproduction で verify する](./empirical-reproduction-over-invariant-reasoning.md)
- [否定形の assert は前提条件が崩れると fail-silent になる](../anti-patterns/negative-assertion-vacuous-without-precondition-floor.md)

## ソース

- [PR #2017 review results (cycle 5, mergeable)](../../raw/reviews/20260725T112757Z-pr-2017-cycle5.md)
