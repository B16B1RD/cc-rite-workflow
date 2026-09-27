---
type: "patterns"
title: "スキルの後段 bash には入力の生値ではなく、選択処理が確定させた値の placeholder を使う"
domain: "patterns"
promote: rite-plugin
description: "利用者が指定したファイルを後段の bash で読むとき、フラグの生値を指す placeholder を使うと、フォールバックでパスを入力し直して再選択した経路で、実際に読んだファイルと別のファイルを読む。後段には選択処理が最後に確定させた値（選択 helper の最終 marker）の placeholder を使い、導入文にその出所を書く。"
created: "2026-09-27T08:15:44Z"
generated: { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-27T08:15:44Z" }
sources:
  - type: "fixes"
    resource: "raw/fixes/20260927T080546Z-pr-3245.md"
  - type: "reviews"
    resource: "raw/reviews/20260927T080916Z-pr-3245.md"
tags: ["skill-writing", "placeholder", "input-resolution", "fallback"]
confidence: medium
---

# スキルの後段 bash には入力の生値ではなく、選択処理が確定させた値の placeholder を使う

## 概要

利用者が指定したファイルを後段の bash で読むとき、フラグの生値を指す placeholder を使うと、フォールバックでパスを入力し直して再選択した経路で、実際に読んだファイルと別のファイルを読む。後段には選択処理が最後に確定させた値（選択 helper の最終 marker）の placeholder を使い、導入文にその出所を書く。

## 詳細

入力の選択は、引数の解析 → 候補の検証 → 失敗時のフォールバック（別の取得元や利用者への再入力）という段を踏む。引数解析の段で得た生値は、フォールバックが別の値を選んだ時点で「実際に使った入力」ではなくなる。後段の bash に生値の placeholder を置くと、通常経路では両者が一致するためテストもレビューも通り、フォールバック経路でだけ別のファイルを読む。症状は「完了記録が triage 前の内容を読む」のように、前段で書き換えた結果が後段に反映されない形で出る。

直し方は、後段が参照する値を選択処理の出力へ一本化することである。選択 helper が確定した取得元とパスを marker で出しているなら、その marker の値を placeholder の出所とし、手順の導入文に「この値は選択処理の最終 marker から取る」と書く。出所を書かないと、次に手順を編集した人が生値の placeholder へ戻しやすい。

同じ手順に複数の placeholder がある場合、入力を表すものはすべて同じ確定値から取る。1 つだけ生値のまま残ると、その 1 か所がフォールバック経路の不一致点になる。

## 関連ページ

- [同一 placeholder を識別子と resolution-target で再利用すると path-resolution drift を生む](../anti-patterns/placeholder-dual-use-resolution-drift.md)
- [placeholder 伝播は実行主体の解決経路を確認してから適用する](../heuristics/placeholder-propagation-requires-resolver-context.md)

## ソース

- [フラグの生値ではなく確定値の placeholder へ直した fix 結果](../../raw/fixes/20260927T080546Z-pr-3245.md)
- [再選択経路との食い違いを指摘したレビュー結果](../../raw/reviews/20260927T080916Z-pr-3245.md)
