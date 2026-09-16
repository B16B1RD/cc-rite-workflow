---
type: "heuristics"
title: "再開の振り分け先は phase 名の対応ではなく、遷移先スキルの入口契約（前提 phase と完了 sentinel）で決める"
domain: "heuristics"
promote: rite-plugin
description: "phase → スキルの対応表だけで再開先を決めると、遷移先スキルの入口ゲート（E2E 判定の whitelist）や終了契約（既に完了済みの入力では sentinel を出さない）に阻まれて、再開しても同じ段で再停止する。phase が「その段の完了」を意味するなら次段へ振る。"
created: "2026-09-15T00:45:00Z"
sources:
  - type: "fixes"
    resource: "raw/fixes/20260916T092034Z-pr-2909.md"
  - type: "fixes"
    resource: "raw/fixes/20260916T095520Z-pr-2909.md"
  - type: "reviews"
    resource: "raw/reviews/20260916T090121Z-pr-2909.md"
  - type: "reviews"
    resource: "raw/reviews/20260916T094235Z-pr-2909.md"
  - type: "reviews"
    resource: "raw/reviews/20260914T151507Z-pr-2822.md"
tags: ["skill-authoring", "phase-routing", "resume", "sentinel", "orchestration"]
confidence: high
generated: { by: "rite-wiki-ingest/gpt-6-astra", at: "2026-09-16T10:24:00Z" }
verified:
  - { by: "rite-wiki-ingest/gpt-6-astra", at: "2026-09-16T10:24:00Z" }
---

# 再開の振り分け先は phase 名の対応ではなく、遷移先スキルの入口契約（前提 phase と完了 sentinel）で決める

## 概要

orchestrator が flow-state の phase から再開先ステップを決めるとき、「phase=ready なら ready ステップへ」という名前の対応だけでは足りない。遷移先スキルには入口ゲート（どの phase を E2E として無確認で通すか）と終了契約（どの入力で完了 sentinel を出すか）があり、両方を満たさない振り分けは再開しても同じ段で止まる。

phase が「その段の処理が完了した」ことを意味する値なら、再開先はその段ではなく次段である。

## 詳細

### 実測された症状

batch-run に再開段階の振り分けを追加し、`ready|ready_error) stage=ready` と書いた。2 名の reviewer が独立に同じ経路を実測した。

- `/rite:ready` の E2E 判定 whitelist は phase が `review` / `fix` のときだけ無確認で通す。`ready` / `ready_error` は standalone 扱いで AskUserQuestion に落ち、batch-run の「完全自律」契約が破れる
- `phase=ready` は ready 化が完了した状態で、その PR は既に `isDraft=false`。`/rite:ready` は「既に Ready for review です」と表示して終了し、`[ready:returned-to-caller]` を出さない。batch-run の表は sentinel 不在を失敗と読み、同じ Issue で再停止する

修正は `ready) stage=merge`（次段へ）、`ready_error) stage=ready`（再試行のみ）。`ready_error` 経路が確認を求めうる点は分岐表に注記して残した。

### 確認手順

再開先を 1 行足すごとに、遷移先スキルで次の 2 点を grep で確かめる。

1. **入口ゲート**: 遷移先が flow-state の phase を読んで分岐する箇所（E2E 判定・standalone 確認）に、その phase 値が含まれているか
2. **終了契約**: 遷移先が「既に完了済み」の入力を受けたときに、orchestrator が成功と読む sentinel を出すか。出さないなら、その phase は次段へ振る

phase → スキルの SoT（recover の Phase enum 表）が `/rite:ready をステップ 3 から再開` と書いていても、ready 側に resume 機構がなければその行は実行できない。SoT の行を写す前に、遷移先が実際にその再開を実装しているかを見る。

### 品質完了と次の作業への移管を分ける

反復処理を終える条件と、その処理の品質が合格する条件は一致しない。draft を残して返信のみで終える経路でも、batch は次の Issue へ進む。品質完了の記録だけを移管条件にすると、queue の cursor は進んでも flow-state が前の Issue に固定され、次の入口で拒否される。

合格済み context と保留終了の context を別に保存する。保留終了にも観測・証跡・停止状態・見直し未了の検査を適用し、未解決 receipt と品質判定は保持する。履歴の退避は次の Issue への切替時に行う。helper 単体に加え、実際の iterate 終了、cursor 前進、次の open という接続全体を検証すると、入口と出口の契約のずれを捉えられる。


## 関連ページ

- [明示的 Phase 遷移で駆動する SKILL.md に新規 Phase を挿入する際、既存の終端ルーティング更新漏れで到達不能になる](../anti-patterns/unrouted-phase-insertion-in-explicit-transition-skill.md)
- [散文で宣言した設計は対応する実装契約がなければ機能しない](../anti-patterns/prose-design-without-backing-implementation.md)

## ソース

- [今回の修正結果](../../raw/fixes/20260916T092034Z-pr-2909.md)
- [今回の修正結果](../../raw/fixes/20260916T095520Z-pr-2909.md)
- [今回のレビュー結果](../../raw/reviews/20260916T090121Z-pr-2909.md)
- [今回のレビュー結果](../../raw/reviews/20260916T094235Z-pr-2909.md)

- [レビュー結果](../../raw/reviews/20260914T151507Z-pr-2822.md)
