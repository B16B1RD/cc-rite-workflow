---
type: "heuristics"
title: "CI が pending のまま閉じたレビューは失敗 job を観測できない — 完了後に担当 reviewer を CI 状態付きで reroll する"
domain: "heuristics"
description: "レビュー時点で CI が未完了だと reviewer は失敗 job のログを読めず、ローカル環境で通るテストだけを根拠に受入条件を充足と判定する。CI 完了後に失敗 job が本 PR の追加テストに対応するなら、その領域の reviewer を最新の CI 状態とログ付きで reroll し、失敗行を failing_test アンカーにして blocking へ戻す。advisory な CI leg でも降格理由にはならない。"
created: "2026-09-16T12:08:00Z"
generated: { by: "rite-wiki-ingest/claude-sonnet-5", at: "2026-09-26T06:12:43Z" }
promote: rite-plugin
sources:
  - type: "reviews"
    resource: "raw/reviews/20260916T111808Z-pr-2910.md"
  - type: "fixes"
    resource: "raw/fixes/20260916T112742Z-pr-2910-fix.md"
  - type: "reviews"
    resource: "raw/reviews/20260926T054854Z-pr-3060.md"
tags: ["review-loop", "ci", "portability", "reroll", "acceptance-criteria"]
confidence: high
verified:
  - { by: "rite-wiki-ingest/claude-sonnet-5", at: "2026-09-26T06:12:43Z" }
---

# CI が pending のまま閉じたレビューは失敗 job を観測できない — 完了後に担当 reviewer を CI 状態付きで reroll する

## 概要

レビュー時点で CI が未完了だと reviewer は失敗 job のログを読めず、ローカル環境で通るテストだけを根拠に受入条件を充足と判定する。CI 完了後に失敗 job が本 PR の追加テストに対応するなら、その領域の reviewer を最新の CI 状態とログ付きで reroll し、失敗行を failing_test アンカーにして blocking へ戻す。advisory な CI leg でも降格理由にはならない。

## 詳細

### 起きたこと

PR が新しい bash テストを追加し、Linux ではローカルでも CI でも全件 PASS していた。レビューは commit 直後に始まったため、その時点の CI 状態は `pending` で、reviewer への CI 状態節も「未完了、待たない」だった。6 名の reviewer は全員ローカル実行の PASS と mutant 実測を根拠に「受入条件充足」と判定し、統合結果は mergeable 相当（blocking 0、非実測指摘 4）に収束しかけた。

統合の途中で CI を再取得すると、macOS の leg が本 PR のテストで 4 assert FAIL していた（前 cycle の commit でも同じ 4 件が落ちており決定的）。欠陥は macOS 標準 awk にしか現れないため、Linux 上の reviewer が何度再実行しても検出できない種類だった。

### なぜ素通りするか

- 実測必須ゲートは「アンカー付きの指摘があるか」だけを見る。CI が失敗していても、それを指摘として書く reviewer がいなければ blocking は 0 のまま mergeable になる
- reviewer に渡す CI 状態はレビュー開始時点のスナップショットで、pending は「待たない」規則のため、レビュー中に完了した失敗は誰にも届かない
- 該当 leg が `continue-on-error` の advisory だと、workflow 全体は success に見える。だが check-run 単体は failure / cancelled で、merge 前の check 分類は unhealthy になり、いずれ merge が止まる。止まる場所がレビューより後ろなだけである

### やること

1. 統合（consolidation）に入る前に CI 状態を再取得する。`pending` から `unhealthy` に変わっていたら、失敗 job のログを取り、失敗が本 PR の変更ファイルに対応するかを確認する
2. 対応するなら、その領域を担当した reviewer を最新の CI 状態 JSON とログ抜粋付きで reroll する。reroll は前回レポートの内容を引き継いだうえで CI 失敗の検証を加えた形で丸ごと作り直し、manifest の同 reviewer 記録を差し替える（別名で追加しない）
3. 失敗行は `Verification: failing_test <path> => <FAIL 行>` の正規形アンカーにする。ローカルで再現できない欠陥は CI ログの失敗出力が唯一の実測であり、これで blocking に戻る
4. 受入条件表の根拠にプラットフォームを明記する（「Linux 上の PASS」）。macOS 実機で確認できるのは CI だけである
5. 修正後は同じ leg が PASS することで閉じる。`--force-ci` で merge を通す選択肢は取らない

### 判定の線引き

- job の timeout 到達（cancelled）が suite 全体の所要時間に起因し、本 PR の追加テストが数秒で完走しているなら、それは本 PR の指摘にしない。事実として記録し、別 Issue で扱う
- 失敗が本 PR のテストの中にあれば、CI leg が advisory であっても severity / scope の降格理由にならない。名乗った挙動に対して正しく落ちも通りもしないテストは、そのテストが守るはずの受入条件を無効にしている

### 再発の裏付け

reviewer 全員が FIXED / 実測 PASS で mergeable 相当に収束しかけた別 cycle でも、レビュー開始時点で CI が pending だったケースが再確認された。統合前に CI を再取得してから結論を出す運用は、cycle・PR をまたいで繰り返し必要になる。

## 関連ページ

- [macOS の awk の == は UTF-8 ロケールで照合比較になり、別の日本語文字列を等しいと判定する](../anti-patterns/macos-awk-string-equality-uses-locale-collation.md)
- [対象プラットフォーム挙動を shim して blocking gate 側で pin する](./portability-fix-needs-target-platform-shim-on-blocking-gate.md)
- [レビュアー選定は毎 cycle 回す — 前 cycle の cap 除外を次へ持ち越さない](./rerun-reviewer-selection-every-cycle.md)

## ソース

- [CI 完了後に test reviewer を reroll して macOS の失敗を blocking にしたレビュー結果](../../raw/reviews/20260916T111808Z-pr-2910.md)
- [CI ログを failing_test アンカーに使い、修正を CI の同 leg で確認した fix 結果](../../raw/fixes/20260916T112742Z-pr-2910-fix.md)
- [レビュー開始時点で CI が pending だった cycle の再確認を記録したレビュー結果](../../raw/reviews/20260926T054854Z-pr-3060.md)
