---
type: "heuristics"
title: "verification-only な残作業 Issue は PR パイプラインを経由せず issue-close で直接検証する"
domain: "heuristics"
promote: rite-plugin
description: "実装対象のコードが既に別 PR でマージ済みであり、残作業 Issue の役割が実機での動作確認（例: 特定の経路が sandbox 環境で完走することの確認）に限られる場合、`/rite:open` → `/rite:iterate` の PR パイプラインを無理に通すと、コード変更を伴わない trivial な diff のため reviewer が何も指摘せず、fix サイクルも発火せず、検証として不完全になる。"
created: "2026-07-21T16:45:00+09:00"
sources:
  - type: "retrospectives"
    resource: "raw/retrospectives/20260721T045336Z-issue-1918.md"
tags: ["issue-management", "verification-only", "residual-task", "issue-close", "pr-pipeline-scope"]
confidence: medium
generated: { by: "rite-wiki-ingest/unknown", at: "2026-07-21T16:45:00+09:00" }
---

# verification-only な残作業 Issue は PR パイプラインを経由せず issue-close で直接検証する

## 概要

実装対象のコードが既に別 PR でマージ済みであり、残作業 Issue の役割が実機での動作確認（例: 特定の経路が sandbox 環境で完走することの確認）に限られる場合、`/rite:open` → `/rite:iterate` の PR パイプラインを無理に通すと、コード変更を伴わない trivial な diff のため reviewer が何も指摘せず、fix サイクルも発火せず、検証として不完全になる。このパターンでは PR を作らずコメント記録 + 該当スキル（`/rite:issue-close` 等）の直接実行で検証する方が適切。

## 詳細

起点となった Issue（「残作業: 検証: sandbox 有効環境で `/rite:pr-review` → `/rite:fix` → wiki ingest 経路が完走することを確認」）は、sandbox 非互換パターンを全域スイープした PR のマージ時点で未完了だった残作業だった。この Issue の性質は「コードは既に実装済み・マージ済みで、あとは実機で動くことを確認するだけ」という verification-only タスクであり、コード変更を伴わないため PR は作成せず、直接 `/rite:issue-close` で処理した（先行の同種 Issue に前例あり）。

検証結果は Issue コメントに以下の形で記録された:
- 6.5.W（pr-review の wiki raw source trigger）: 別 PR 2 件のマージ時に raw source (reviews/) が正常生成されたことを確認
- 4.6.W（fix の wiki raw source trigger）: 別 PR で review⇄fix 複数サイクルの raw source (fixes/) が正常生成されたことを確認
- Phase 4.4.W（issue-close の wiki raw source trigger）: 通常の open→iterate→ready→merge→cleanup パイプラインには含まれない独立スキルであり、この Issue 自体をこのスキルでクローズすることで実地検証した（この retrospective raw source 自体がその証跡）

**教訓**: 「残作業: 検証」系のタスクを見つけたら、まず「実装対象のコードは既に別 PR でマージ済みか」を確認する。マージ済みであれば、この Issue の役割は実機での動作確認に限られるため、PR 経由の open→iterate パイプラインを force-through してはならない（trivial な diff では reviewer が指摘を生成できず、確認したい経路自体が発火しないため検証として意味をなさない）。代わりに、検証対象の経路を実際に発火させる手段（別 PR のマージ時の実測、当該スキルの直接実行等）で検証し、結果を Issue コメントに記録した上で `/rite:issue-close` で直接クローズする。

## 関連ページ

- （関連ページなし）

## ソース

- [close retrospective](../../raw/retrospectives/20260721T045336Z-issue-1918.md)
