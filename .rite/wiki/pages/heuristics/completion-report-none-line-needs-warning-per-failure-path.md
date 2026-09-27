---
type: "heuristics"
title: "完了レポートの「なし」行は、失敗経路ごとに WARNING を出して判定する"
domain: "heuristics"
description: "完了レポートの「未完了事項: なし」を「WARNING を出していない」だけで判定すると、WARNING を出さずに終了コードだけで失敗する経路が「なし」に化ける。報告したい失敗経路ごとに WARNING を出し、終了コードは保ったまま返せば、新しい失敗経路に WARNING を足すだけで「なし」の誤判定も閉じる。"
created: "2026-09-27T21:52:19Z"
generated: { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-27T21:52:19Z" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20260927T214046Z-pr-3353.md"
  - type: "fixes"
    resource: "raw/fixes/20260927T215011Z-pr-3353.md"
tags: ["completion-report", "silent-failure", "exit-code", "warning", "test"]
confidence: medium
promote: rite-plugin
---

# 完了レポートの「なし」行は、失敗経路ごとに WARNING を出して判定する

## 概要

完了レポートの「未完了事項: なし」を「WARNING を出していない」だけで判定すると、WARNING を出さずに終了コードだけで失敗する経路が「なし」に化ける。報告したい失敗経路ごとに WARNING を出し、終了コードは保ったまま返せば、新しい失敗経路に WARNING を足すだけで「なし」の誤判定も閉じる。

## 詳細

完了レポートが未完了事項の行を stderr の WARNING の文面から組み立てる設計では、「なし」行の条件を「WARNING を出していない」にしがちである。すると、WARNING を出さずに失敗する経路（例: ロールの確認は通ったのに、その後のロック解放が失敗する）が「なし」に化ける。失敗を終了コードで返していても、利用者が最後に読むレポートまで運ぶ経路が無ければ silent failure と同じになる。

対処は、報告したい失敗経路ごとに WARNING を出し、終了コードは `cmd || { rc=$?; echo "WARNING: ..." >&2; exit "$rc"; }` の形で保ったまま返すことである。「なし」行の条件を「WARNING を出していない」のまま据え置けば、新しい失敗経路に WARNING を足すだけで「なし」の誤判定も同時に閉じる。未完了事項の表を書くときは、WARNING の有無ではなく各段の失敗（rc 非 0 を含む）を列挙し、どの失敗がどの行に載るかを表で対応づける。

### テストの書き方

手順書の bash block を抽出して placeholder を置換し、実際に実行して文面・行順・rc を assert するテストは、文面の入れ替えや分岐外しの変異を確実に検出する。ただし fixture がテストファイル内の先行ケースの状態（stub や書き出した session id）に依存すると、単独実行や順序の入れ替えで壊れるので、各ケースで自前の状態を用意する。同じ文面を 2 つのテストスイートが重ねて固定すると、文面を変えるたびに両方の同期が要る。表の行があることはレポート契約のテスト、実行時の文面との照合は実行テストと、役割を分ける。

特定の外部コマンドだけを失敗させる fixture は、必要なコマンドを symlink した PATH に失敗する stub を 1 つだけ置く形にする。root でも効き、chmod で権限を落とす方法より壊れにくい。

## 関連ページ

- [Success-only Sentinel Design — sub-skill abort path sentinel 未定義](../anti-patterns/success-only-sentinel-design.md)
- [失敗経路の ERROR 文を段ごとに分けたら、分割後の各分岐に入るテストを 1 つずつ用意し、文面で照合する](./split-error-message-needs-test-per-branch.md)

## ソース

- [「なし」行の誤判定を検出したレビュー結果](../../raw/reviews/20260927T214046Z-pr-3353.md)
- [失敗経路ごとに WARNING を出した fix 結果](../../raw/fixes/20260927T215011Z-pr-3353.md)
