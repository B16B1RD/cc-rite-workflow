---
type: "heuristics"
title: "判定表の行に条件を足したら、否定側の行・言い換えた要約・その行を固定するテストを同じ変更で揃える"
domain: "heuristics"
promote: rite-plugin
description: "判定表の 1 行に条件を足すと、その否定を書き下した後続の行、表を言い換えた散文や sentinel の要約、行を固定するテストの pattern が同時に追随を要する。追随を計画に含めずに残すと、字面の食い違いとして次の cycle で繰り返し指摘される。"
created: "2026-10-09T19:10:23Z"
generated: { by: "manual/claude-opus-5-5", at: "2026-10-10T02:51:06Z" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20261009T175021Z-pr-3728.md"
  - type: "fixes"
    resource: "raw/fixes/20261009T180350Z-pr-3728.md"
  - type: "reviews"
    resource: "raw/reviews/20261009T181334Z-pr-3728.md"
  - type: "fixes"
    resource: "raw/fixes/20261009T182623Z-pr-3728.md"
  - type: "reviews"
    resource: "raw/reviews/20261009T183642Z-pr-3728.md"
  - type: "fixes"
    resource: "raw/fixes/20261009T184749Z-pr-3728.md"
  - type: "reviews"
    resource: "raw/reviews/20261009T185346Z-pr-3728.md"
tags: ["decision-table", "pin", "summary-drift", "review-loop"]
confidence: high
---

# 判定表の行に条件を足したら、否定側の行・言い換えた要約・その行を固定するテストを同じ変更で揃える

## 概要

判定表の 1 行に条件を足すと、その否定を書き下した後続の行、表を言い換えた散文や sentinel の要約、行を固定するテストの pattern が同時に追随を要する。追随を計画に含めずに残すと、字面の食い違いとして次の cycle で繰り返し指摘される。

## 詳細

### 起きたこと

ひとつの機能の判定表へ条件を足す修正が、5 cycle にわたって同じ種類の指摘を受け続けた。

- 継続条件を足した行に対し、その否定を書いた終了側の行は既存テストが文言を固定していたため、計画外の変更を避けて残した。残った行は複数のレビュアーから字面の整合として繰り返し指摘された
- 会話中の marker を条件に足した行に、同じ行の既存の句が持つ「本 cycle 内で」の限定を付けなかった。同じ会話で繰り返すループでは、前の cycle の marker を拾う読み方が残った
- 行を固定するテストが、足した条件を `.*` でつないで飛ばしていた。条件を消す・限定を外す・否定を反転する変異を 4 本とも見逃した。条件を逐語で含めた pin は同じ変異をすべて検出した
- 条件の集合を名指す周辺の記述（helper のコメント、SoT の見出し、SoT への参照文、sentinel-contract や SPEC の要約）は、指摘された箇所だけを直したため、次の cycle で残りの層が指摘された

### 書き方

- 条件を足す行と、その否定側の行と、両者の文言を固定しているテストを、最初から計画のパスに入れる
- marker を条件にするときは、同じ行の既存の句と同じ有効範囲を付け、判定方法は定義文 1 か所で定める
- pin には足した条件を逐語で含め、条件を消す変異で落ちることを確かめてから commit する
- 条件の集合を名指す記述は grep で網羅して同じ commit で揃え、揃えた後に旧文言の残りが 0 件かを grep で確かめる。この形にした修正は、3 名とも解消と判定し指摘 0 件で収束した。ただし同じ grep で確かめられるのは旧文言が消えたことだけで、言い換えた要約の取りこぼしは分からない。網羅は条件の性質から導いた別の検索（足した条件の語や marker 名、条件の集合を列挙する箇所）で確かめる（[スイープの検証 grep にスイープ対象と同一パターンを再利用する](../anti-patterns/sweep-verification-grep-shares-blind-spot.md)）
- 要約で OR 条件を並べるときは「・」でつながず「いずれか」と書く。「・」は AND とも読める
- 既存の契約自体が満たしていない粒度の pin を、PR が足した限定にだけ求める推奨は却下し、却下台帳へ送って再報告を止める

## 関連ページ

- [全称主張の散文（排他性・網羅性）は経路追加で偽化する — 旧文面 grep 全数洗い + 原因中立化 + not_grep pin](./universal-claim-prose-invalidated-by-path-addition.md)
- [新規 exit 1 経路 / sentinel type 追加時は同一ファイル内 canonical 一覧を同期更新し、『N site 対称化』counter 宣言を drift 検出アンカーとして活用する](./canonical-list-count-claim-drift-anchor.md)
- [スイープの検証 grep にスイープ対象と同一パターンを再利用する](../anti-patterns/sweep-verification-grep-shares-blind-spot.md)

## ソース

- [レビュー結果（否定側の行が追随しない）](../../raw/reviews/20261009T175021Z-pr-3728.md)
- [fix 結果（否定側の行と pin を計画に含める）](../../raw/fixes/20261009T180350Z-pr-3728.md)
- [レビュー結果（marker 条件の有効範囲と `.*` の pin）](../../raw/reviews/20261009T181334Z-pr-3728.md)
- [fix 結果（有効範囲を揃え、pin を逐語にする）](../../raw/fixes/20261009T182623Z-pr-3728.md)
- [レビュー結果（逐語の pin が変異を検出）](../../raw/reviews/20261009T183642Z-pr-3728.md)
- [fix 結果（条件の集合を名指す記述を揃える）](../../raw/fixes/20261009T184749Z-pr-3728.md)
- [レビュー結果（周辺の記述を揃えて収束）](../../raw/reviews/20261009T185346Z-pr-3728.md)
