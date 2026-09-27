---
type: "heuristics"
title: "セッション単位の state を読む案内は、同じ session_id で入る入口を基準に選ぶ — テストはホストの入力形で呼ぶ"
domain: "heuristics"
promote: rite-plugin
description: "起動時の案内がセッション単位の state ファイルを読むとき、案内を出せるのは同じ session_id で起動した入口だけである。別経路の対象 source を流用すると実際の入口が抜け、harness が session id を事前設定するテストではその欠落が見えない。"
created: "2026-09-27T10:47:38Z"
generated: { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-27T10:47:38Z" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20260927T102947Z-pr-3259.md"
  - type: "fixes"
    resource: "raw/fixes/20260927T103549Z-pr-3259.md"
tags: ["hooks", "session-id", "resume", "test-input-shape"]
confidence: high
---

# セッション単位の state を読む案内は、同じ session_id で入る入口を基準に選ぶ — テストはホストの入力形で呼ぶ

## 概要

起動時の案内がセッション単位の state ファイルを読むとき、案内を出せるのは同じ session_id で起動した入口だけである。別経路の対象 source を流用すると実際の入口が抜け、harness が session id を事前設定するテストではその欠落が見えない。

## 詳細

ホストは startup / clear では新しい session_id を渡し、同じ id を引き継ぐのは resume である。停止した run の停止理由を起動時に案内する処理が、既存のリセット経路の対象 source（startup / clear）を流用したため、案内が出るべき resume が対象から外れ、実際のどの入口でも案内が出なかった。

テストの harness は payload に session_id を渡さず、sid を事前設定して hook を呼んでいた。このため実入口では到達しない分岐が green になっていた。同じ修正を検証した reviewer のうち、harness の入力をそのまま使った者は解消と判定し、実ホストの payload 形（session_id 付き）で再現した者は未解消と判定した。判定の食い違いは、各自が使った入力の形を突き合わせると決着した。

- 案内の対象 source は「同じ session_id で起動する入口」から選ぶ。別経路（リセット等）の対象 source を流用しない
- hook のテストはホストと同じ入力の形（ホスト種別と payload の session_id）で呼ぶ
- 新しい session_id の起動では案内が出ないことも対照として固定し、案内の範囲をテストで示す
- reviewer 間で解消判定が割れたら、結論ではなく各自が使った入力の形を突き合わせる

## 関連ページ

- [hook のテストスイートは ambient な session-id 環境変数 (CLAUDE_CODE_SESSION_ID 等) に依存させない (non-hermetic test)](./test-hermeticity-ambient-session-id-env-leak.md)
- [テンプレート準拠の fixture では、生成器が実データで作る構造的逸脱を検出できない](./template-fixture-misses-generator-real-data-deviation.md)

## ソース

- [レビュー結果](../../raw/reviews/20260927T102947Z-pr-3259.md)
- [fix 結果](../../raw/fixes/20260927T103549Z-pr-3259.md)
