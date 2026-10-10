---
type: "patterns"
title: "fail-loud の診断文は、検出した原因の種別ごとに直し方を変えて書く"
domain: "patterns"
description: "設定値を検証して止める helper が原因の違うエラーを同じ文言で告げると、許可値を書いた利用者に「その値は不正」と矛盾した案内をする。検出の種別ごとに文言を分け、終了コードと機械向けの marker は変えずに人向けの文面だけを分ける。"
created: "2026-10-10T01:04:42Z"
generated: { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-10-10T01:04:42Z" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20261009T233431Z-pr-3735.md"
  - type: "fixes"
    resource: "raw/fixes/20261009T234120Z-pr-3735.md"
  - type: "reviews"
    resource: "raw/reviews/20261009T234815Z-pr-3735.md"
tags: ["fail-loud", "error-message", "config-validation", "mutation-test"]
confidence: high
---

# fail-loud の診断文は、検出した原因の種別ごとに直し方を変えて書く

## 概要

設定値を検証して止める helper が原因の違うエラーを同じ文言で告げると、許可値を書いた利用者に「その値は不正」と矛盾した案内をする。検出の種別ごとに文言を分け、終了コードと機械向けの marker は変えずに人向けの文面だけを分ける。

## 詳細

マージ方式を読む helper は、`merge:` の下に `method:` を書く形を想定していた。利用者が `merge: merge` のように節へ直接値を書くと、helper は値を読めず「merge.method が不正です: 'merge'（使える値: squash / merge）」と告げた。`merge` は使える値に含まれるので、案内は自己矛盾していた。

原因は、検出の種別（節に値を直接書いた形 / `method:` の値が許可値に無い）が違うのに、同じ文言で報告していたことである。直し方は種別ごとに違う。前者は「`merge:` の下の行に `method: merge` と書く」、後者は「使える値に直す」である。

修正では次を守った。

- 終了コードと stdout の機械向け marker（呼び出し側の分岐に使う）は変えず、stderr の人向けの文面だけを種別で分ける。呼び出し側の分岐表を変えずに済む
- 種別は検出時点で分かっている情報（どの行で値を見つけたか）から決め、文言から逆算しない
- テストで種別ごとの stderr の文面を固定する。修正前の文言に戻す変異と、分岐を常に片方へ倒す変異の両方をテストが落とすことを確かめる

## 関連ページ

- [bash 文字列変数の初期値は allowed values 列挙に含めるか fail-loud sentinel で defensive に倒す](./bash-initial-value-aligns-with-allowed-values.md)

## ソース

- [レビュー結果](../../raw/reviews/20261009T233431Z-pr-3735.md)
- [fix 結果](../../raw/fixes/20261009T234120Z-pr-3735.md)
- [レビュー結果](../../raw/reviews/20261009T234815Z-pr-3735.md)
