---
type: "heuristics"
title: "検証手順を書くときは処方するコマンドの判別能力そのものを実測する"
domain: "heuristics"
description: "検証手順を新設する変更では、**手順が処方するコマンドが、その手順の防ごうとしている失敗モードを検出できない**という自己言及的な欠陥が最上位の指摘になりやすい。"
created: "2026-07-30T15:40:55Z"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260730T045358Z-pr-2056.md"
  - type: "fixes"
    resource: "raw/fixes/20260730T050205Z-pr-2056.md"
  - type: "fixes"
    resource: "raw/fixes/20260730T084017Z-pr-2056.md"
  - type: "reviews"
    resource: "raw/reviews/20260730T083745Z-pr-2056.md"
tags: ["gh-cli", "verification", "prose-procedure", "discriminator"]
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-07-30T15:40:55Z" }
---

# 検証手順を書くときは処方するコマンドの判別能力そのものを実測する

## 概要

検証手順を新設する変更では、**手順が処方するコマンドが、その手順の防ごうとしている失敗モードを検出できない**という自己言及的な欠陥が最上位の指摘になりやすい。文面は単体では正しく読めるのに、処方コマンドを実際に走らせると意図した判別ができない。手順を書いたら、処方したコマンドを実データに対して実行し、**判別したい 2 つの入力が異なる出力になるか**を確かめる。

## 詳細

本リポジトリでは Issue 本文のファクトチェック手順を新設した PR で、2 名のレビュアーが独立に同一 file:line を検出した。

### 実測で確定した非対称

- `gh issue view {N}` は **PR 番号を渡してもエラーにせず PR を解決して成功で返す**（`url` が `.../pull/{N}` になる）。
- 対照的に `gh pr view {N}` は Issue 番号に対し `Could not resolve to a PullRequest` で正しく失敗する。**壊れているのは Issue 側だけ**という非対称がある。

この非対称のため、「`gh issue view` の title を照合して Issue/PR 混同を検出する」手順は成立しない。squash merge 運用では PR title が Issue title から派生してほぼ一致するため、誤った対象のまま `VERIFIED` に倒れる。

### 使える判別子・使えない判別子

| シグナル | 判別に使えるか |
|---|---|
| `url` のパスセグメント（`/issues/` vs `/pull/`） | **使える**（唯一の安定した判別子） |
| `title` | 使えない（squash merge で PR title が Issue title から派生し一致する） |
| `state` | 使えない（open な PR は Issue と同じ `OPEN` を返す。`MERGED` だけを見る実装は closed PR しか捕まえられない） |

判定は**同じ 1 回のコマンド出力から取る**。「値を見に行く」形の指示は `-R {owner}/{repo}` を落とした二度目の呼び出しを誘発し、SSH host alias 環境で別リポジトリを引く。

### 恒真の確認は盲点を作る

橋渡し手順に「`gh pr view` の `url` が `/pull/` であることを確認し」と書いた版があったが、`gh pr view` は非 PR を解決できず失敗するため、この確認は**常に真**だった。恒真の確認は種別判定済みであるかのような見かけを作り、入力種別の前提漏れ（Issue 番号 citation が主経路であること）を覆い隠す。**「確認せよ」という指示を書いたら、その確認が失敗しうる経路が実在するかを先に検証する。**

### 適用のしかた

- 変換・橋渡し手順を追加するときは**入力の全種別**（PR 番号 / Issue 番号 / SHA 直書き）を列挙してから分岐を設計し、種別判定には「全種別で成功する唯一のコマンド」を使う。
- worked example は必ず実行して裏取りする。reference 中の具体例の**記述の正しさ**と、その例に処方手順を走らせたときの**手順の有効性**は別軸。
- 機能の動機となった実例をテストケースとして修正のたびに end-to-end で通すと、defect が早期に出る。

## 関連ページ

- [外部コマンド (gh) 失敗時に not-found と一時障害を区別せず別経路へ落とすのは silent failure](../anti-patterns/external-command-failure-origin-distinction.md)
- [散文で引用した実装挙動は実際に動かして確認する](./prose-cited-implementation-behavioral-verification.md)

## ソース

- [処方コマンドの判別能力](../../raw/reviews/20260730T045358Z-pr-2056.md)
- [url パスセグメントが唯一の判別子](../../raw/fixes/20260730T050205Z-pr-2056.md)
- [恒真の確認が盲点を作る](../../raw/fixes/20260730T084017Z-pr-2056.md)
- [入力種別の前提漏れ](../../raw/reviews/20260730T083745Z-pr-2056.md)
