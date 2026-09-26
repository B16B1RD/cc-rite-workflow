---
type: "anti-patterns"
title: "差分の帰属を「どの diff に行が現れるか」で決めると、PR 自身の変更を base 由来と誤分類する"
domain: "anti-patterns"
description: "レビュー指摘の帰属（PR の変更か base 由来か）を行の位置、つまり 3 点 diff に現れるかどうかで決める規則は、context 行を含む読みと、PR 自身が前サイクルで足した行を後の修正で消すケースの両方で誤分類する。帰属は行の位置ではなく原因（どの commit が変えたか、revert で直るか）に置く。"
promote: rite-plugin
created: "2026-09-26T03:45:00Z"
generated: { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-26T03:45:00Z" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20260926T033118Z-pr-3100.md"
tags: []
confidence: medium
---

# 差分の帰属を「どの diff に行が現れるか」で決めると、PR 自身の変更を base 由来と誤分類する

## 概要

レビュー指摘の帰属（PR の変更か base 由来か）を行の位置、つまり 3 点 diff に現れるかどうかで決める規則は、context 行を含む読みと、PR 自身が前サイクルで足した行を後の修正で消すケースの両方で誤分類する。帰属は行の位置ではなく原因（どの commit が変えたか、revert で直るか）に置く。

## 詳細

差分スコープのレビューでは、起点の後に取り込んだ base の行も「追加行」として差分に現れる。これを PR の指摘から外すために「`base...HEAD` の差分に現れる行の問題に限る」という位置ベースの規則を reviewer 指示文へ足したところ、3 名のレビュアーが独立に次の欠陥を示した。

1. **判定語が context 行を含む**: `git diff` の既定出力は変更箇所の前後 3 行を未変更の context 行として出す。「差分に現れる行」と書くと、字義どおりの reviewer は context 行まで「現れる」と読み、PR の変更の近くに取り込まれた base の行を PR の指摘として出してしまう。判定語は追加・削除行に限定しないと、塞ごうとした誤帰属が残る。
2. **削除は 3 点 diff に現れない**: 前サイクルで PR 自身が足したガード行を後の修正コミットが消した場合、その削除は修正の差分には `-` 行として出るが、`base...HEAD` には現れない（最初から無かったことになる）。位置ベースの規則はこれを「base 由来の pre-existing」と誤って分類する。base の取り込みが一度もなくても起きる。
3. **行の出所と問題の出所は別物**: PR が改名した symbol を、取り込んだ base の新しい行が旧名で呼ぶ場合、その行は base 由来だが、壊れた原因は PR の変更にある（revert すれば直る）。位置で帰属を決めると revert test と矛盾する。

審査範囲を変えない規則でも、報告対象を「〜に限る」と限定する文を足すと実効範囲は狭まる。限定を足すときは、限定の外に落ちる正当な指摘の経路（削除・波及・意味的衝突）を列挙してから書く。

## 関連ページ

- [re-review / verification mode でも初回レビューと同等の網羅性を確保する (Anti-Degradation Guardrail)](../heuristics/reviewer-scope-antidegradation.md)

## ソース

- [レビュー結果](../../raw/reviews/20260926T033118Z-pr-3100.md)
