---
type: "heuristics"
title: "ゲートを有効化する変更は、同じ条件で動く全 hook を通した経路で既存手順を検証する"
description: "状態値を書き足してあるゲートを有効化すると、同じ状態値を条件にする別の hook も同時に有効化され、既存手順が初めてその hook の拒否経路に入ることがある。helper を直接呼ぶテストは hook を経由しないため、この退行を検出できない。"
domain: "heuristics"
promote: rite-plugin
created: "2026-09-26T03:45:00Z"
generated: { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-26T04:05:00Z" }
verified:
  - { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-26T04:05:00Z" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20260926T033819Z-pr-3099.md"
  - type: "fixes"
    resource: "raw/fixes/20260926T034712Z-pr-3099.md"
tags: []
confidence: medium
---

# ゲートを有効化する変更は、同じ条件で動く全 hook を通した経路で既存手順を検証する

## 概要

状態値を書き足してあるゲートを有効化すると、同じ状態値を条件にする別の hook も同時に有効化され、既存手順が初めてその hook の拒否経路に入ることがある。helper を直接呼ぶテストは hook を経由しないため、この退行を検出できない。

## 詳細

実装コミットで証跡ゲートを働かせるために、実装前に phase を記録する変更を入れた。ところが同じ phase を条件にする別の PreToolUse hook（commit を含む Bash 呼び出しを静的解析して拒否する規則）も同時に有効化された。既存の実装手順は「未置換ガードと commit を 1 回の Bash 呼び出しにまとめる」形だったため、この hook の拒否経路に初めて入り、CRITICAL として指摘された。

- ゲートの有効化は「そのゲート 1 つを on にする」変更ではない。同じ条件（phase・flag・state）を読む全 hook を grep で列挙し、既存手順がそれぞれの hook を通るかを確認する。
- helper を直接呼ぶテストは hook を経由しないので、全件 green のまま hook 経路の退行を見逃す。hook 経路の検証は、hook を通した呼び出しで行う。
- 設計理由を SKILL 本体に書くと行数原則の違反として指摘される。rationale は references/ へ退避し、本体には 1 行のポインタを残す。

修正では、手順ブロックを 1 回の Bash 呼び出しのまま hook の解析を通る形（commit と同じ呼び出しに case 文を置かず、未置換ガードを if grep で書く）に直した。回帰防止には、SKILL の手順ブロックを抽出して実際の guard に通す assert を足した。helper 直呼びではなく、手順そのものを hook に通すことで hook 経路の退行を捕まえる。guard を通すテストは実行中のセッションの状態ファイルを拾うため、セッション ID を隔離して走らせないと環境由来の失敗が混ざる。

## 関連ページ

- [セキュリティ境界 hook の timeout は fail-open — 評価コストは入力サイズで O(1) 上限を設けて bound する](./security-hook-timeout-is-fail-open-bound-cost-by-input-size.md)

## ソース

- [レビュー結果](../../raw/reviews/20260926T033819Z-pr-3099.md)
- [fix 結果](../../raw/fixes/20260926T034712Z-pr-3099.md)
