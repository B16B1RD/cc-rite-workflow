---
type: "patterns"
title: "行動指示と帰結記述を 1 文に混載しない — 帰結は SoT の表へのポインタに置き換える"
domain: "patterns"
promote: rite-plugin
reference: "plugins/rite/references/wiki-promotions/patterns/separate-directive-from-consequence-with-sot-pointer.md"
description: "authoring 面（reviewer への指示、テンプレート、規約文書）の 1 文が「こう書け」という**行動指示**と「そう書かなかったらどうなるか」という**帰結記述**を同時に担っていると、判定ロジックの帰結が変わるたびに authoring 面の書き換えが必要になる。"
created: "2026-08-01T23:12:28+09:00"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260801T131235Z-pr-2081.md"
  - type: "fixes"
    resource: "raw/fixes/20260801T131540Z-pr-2081.md"
tags: []
confidence: medium
generated: { by: "rite-wiki-ingest/unknown", at: "2026-08-01T23:12:28+09:00" }
---

# 行動指示と帰結記述を 1 文に混載しない — 帰結は SoT の表へのポインタに置き換える

## 概要

authoring 面（reviewer への指示、テンプレート、規約文書）の 1 文が「こう書け」という**行動指示**と「そう書かなかったらどうなるか」という**帰結記述**を同時に担っていると、判定ロジックの帰結が変わるたびに authoring 面の書き換えが必要になる。帰結記述を SoT の表へのポインタ 1 行へ置き換えれば、帰結の変更は SoT の 1 箇所で閉じる。

## 詳細

**観測された症状**: 起点事例では `_reviewer-base.md` の同じ 1 行（帰結記述）を **4 cycle 連続で書き換えた**。しかも 2 cycle は逆方向に振れている — cycle 4 で「意味論の語彙で言い換えていて弱すぎる」と指摘されて字句条件へ書き換え、cycle 5 で「述語の依存関係を落として強すぎる断定になった」と指摘された。往復の構造的な原因は、その 1 行が行動指示と帰結記述を混載していたこと。行動指示部分は一度も変わっていないのに、帰結が動くたびに行全体が編集対象になる。

**なぜポインタが効くか**: 帰結の SoT は判定を実装するゲート側にあり、authoring 面はその消費者にすぎない。ポインタ（`rationale: references/<file>.md#<anchor>` の形）にすれば、authoring 面が持つのは「行動指示」と「帰結は SoT を見よ」の 2 要素だけになり、帰結の変更で編集されなくなる。

**適用の判断基準**: 同じ行を 2 cycle 以上書き換えていて、書き換えの原因が毎回「帰結が変わった」であるなら、混載を疑う。行動指示そのものが変わっていないことがシグナル。

**関連する原則**: 「N 箇所で同期が必要」と指摘されたら同期する前に N を減らせないか検討するのと同じ発想で、**同期対象の面を減らすのではなく、面が持つ責務を減らす**アプローチである。

## 関連ページ

- [「N 箇所で同期が必要」と指摘されたら、同期する前に N を減らせないか検討する](../heuristics/reduce-sync-sites-before-syncing-them.md)
- [References 抽出 refactor では canonical contract の SoT を 1 reference に固定し他は anchor 参照のみとする](./single-sot-on-references-extract.md)
- [一般化した断定は、実装が特殊化されている限り必ず偽になる — 同じ契約を書く複数サイトは最も限定的な表現に揃える](../heuristics/generalized-claim-false-while-implementation-specialized.md)

## ソース

- [レビュー結果](../../raw/reviews/20260801T131235Z-pr-2081.md)
- [fix 結果](../../raw/fixes/20260801T131540Z-pr-2081.md)
