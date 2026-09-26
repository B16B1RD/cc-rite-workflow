---
type: "heuristics"
title: "consumer に新しい判定入力を要求したら、表示用の表から組み立て直さず producer が保存した正本を渡す"
domain: "heuristics"
description: "consumer 側に新しい判定入力を要求すると、表示用に最小化された表から入力を組み立て直す経路ではその値が必ず失われる。既定値で補うと判定が黙って変わるため、producer が保存した正本をそのまま consumer へ渡す形で直す。"
created: "2026-09-26T10:50:02Z"
generated: { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-26T10:50:02Z" }
sources:
  - type: "fixes"
    resource: "raw/fixes/20260926T104508Z-pr-3148.md"
tags: ["producer-consumer", "canonical-artifact", "data-loss", "fallback", "regression-test"]
confidence: medium
---

# consumer に新しい判定入力を要求したら、表示用の表から組み立て直さず producer が保存した正本を渡す

## 概要

consumer 側に新しい判定入力を要求すると、表示用に最小化された表から入力を組み立て直す経路ではその値が必ず失われる。既定値で補うと判定が黙って変わるため、producer が保存した正本をそのまま consumer へ渡す形で直す。

## 詳細

producer（レビュー結果の保存）と consumer（修正の判定）の間に、人間向けに列を絞った表示経路（会話上の表や旧形式の Markdown）が並存していると、consumer がその表から入力を再構成する経路が残る。consumer に新しい判定入力（例: 帰結の分類）を足した時点で、表示経路はその列を持たないため、再構成された入力からは値が構造的に欠落する。

欠落を既定値で埋めると、保存済みの正本では別の値だったはずの判定が、経路によって黙って変わる。直し方は、再構成経路でも producer がレビュー対象 commit について保存した正本 JSON を特定して複写し、それを consumer へ渡すことである。値の出所が 1 つに揃うため、経路による判定の食い違いが消える。

既存の helper（保存済み正本の特定）を再利用するときは、その helper の診断文に別工程向けの復旧指示が含まれていないかを確認する。そのまま表示すると、利用者に誤った手順を案内する。marker 行だけを残して診断文は出さない。

回帰テストは、helper が照合に使う HEAD と同じ条件を一時 git リポジトリで作って組む。実リポジトリの別 commit の正本を借りてしまうと、HEAD の照合を素通りする誤りを検出できない。借用しないことも合わせて固定する。

## 関連ページ

- [消費側だけに足した allowlist は生成側の値域と食い違い「成功しているのに永久に失敗」の非収束を作る](../anti-patterns/consumer-allowlist-wedges-producer-value-range.md)

## ソース

- [fix 結果](../../raw/fixes/20260926T104508Z-pr-3148.md)
