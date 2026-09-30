---
type: "heuristics"
title: "回復手順は実際のエラー出力だけで実行できるかを確かめ、直す対象の識別子を ERROR に添える"
domain: "heuristics"
promote: rite-plugin
description: "回復手順に「エラーが示す X を直す」と書くなら、実際にそのエラーを出して X が出力に含まれるかを確かめる。含まれないなら文面を直すのではなく、helper が持つ識別子（出典パス・id）を ERROR に添える。"
created: "2026-09-30T04:20:00Z"
generated: { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-30T04:20:00Z" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20260930T030451Z-pr-3468.md"
  - type: "fixes"
    resource: "raw/fixes/20260930T031623Z-pr-3468.md"
  - type: "reviews"
    resource: "raw/reviews/20260930T022509Z-pr-3468.md"
tags: []
confidence: high
---

# 回復手順は実際のエラー出力だけで実行できるかを確かめ、直す対象の識別子を ERROR に添える

## 概要

回復手順に「エラーが示す X を直す」と書くなら、実際にそのエラーを出して X が出力に含まれるかを確かめる。含まれないなら文面を直すのではなく、helper が持つ識別子（出典パス・id）を ERROR に添える。

## 詳細

### 起きたこと

照合の jq が失敗したときの回復手順を「続く jq のエラーが示すレビュー結果 JSON の壊れた指摘を直す」と書いた。実際に失敗させると、jq のエラーは型の食い違いを 1 行示すだけで、JSON のファイル名も指摘の id も出なかった。jq に stdin と `--slurpfile` で別々の入力を渡すと、エラーの位置表示は stdin 側（ここでは台帳コメントの本文）の行を指し、壊れた要素の所在は示さない。

### 対処

- 照合キーを作れない要素は helper 自身が出典パスと id を持っているので、ERROR の直後に `source=<出典 JSON> id=<id>` で列挙する。停止と reason は変えない。
- 回復手順はその出力に合わせて書き、エラーの位置表示が何を指すかも明記する。
- 表示を固定するテストは、表示を消す変異で落ちることを確かめてから採る。

「分岐を足さない」ことを理由に表示の追加を避け、文面だけを直すと、手順は実行できないまま同じ指摘が再発する。

### reason ごとに回復手順を分ける

新しい失敗 reason を既存 reason の表の行に束ねると、その行の回復手順が新しい reason では実行できないことがある（「ERROR が示す行を直す」と案内しているのに、新しい reason の ERROR は行を示さない等）。reason を足したら、分岐表の行ごとに回復手順がその reason の ERROR の内容で実行できるかを確かめ、実行できなければ行を分ける。

## 関連ページ

- [失敗の原因を列挙する条件は失敗する式と同じ述語で書き、「特定できません」の既定文言で覆わない](../anti-patterns/failure-enumeration-predicate-diverges-from-failing-expression.md)

## ソース

- [レビュー結果](../../raw/reviews/20260930T030451Z-pr-3468.md)
- [fix 結果](../../raw/fixes/20260930T031623Z-pr-3468.md)
- [レビュー結果](../../raw/reviews/20260930T022509Z-pr-3468.md)
