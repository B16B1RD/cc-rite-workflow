---
title: "Step 番号参照は relative (Step N + 1) ではなく absolute (heading title 名 + Step 番号) で書く"
domain: "patterns"
description: "prompt / 文書内で「Step 2/3 を skip」「次の Step」のような relative step 参照を書くと、後続の reorder / step 追加で actual heading 構造とのずれが発生し、参照が silent に間違った step を指す regression を生む。"
created: "2026-04-30T01:58:00+00:00"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260430T005759Z-pr-688.md"
  - type: "reviews"
    resource: "raw/reviews/20260712T133608Z-pr-1835.md"
  - type: "fixes"
    resource: "raw/fixes/20260712T133936Z-pr-1835.md"
  - type: "reviews"
    resource: "raw/reviews/20260901T140807Z-pr-2500.md"
tags: []
confidence: high
generated: { by: "rite-wiki-ingest/grok-4.6", at: "2026-09-02T00:50:00Z" }
verified:
  - { by: "rite-wiki-ingest/grok-4.6", at: "2026-09-02T00:50:00Z" }
---

# Step 番号参照は relative (Step N + 1) ではなく absolute (heading title 名 + Step 番号) で書く

## 概要

prompt / 文書内で「Step 2/3 を skip」「次の Step」のような relative step 参照を書くと、後続の reorder / step 追加で actual heading 構造とのずれが発生し、参照が silent に間違った step を指す regression を生む。Step 番号は heading title 名 + Step 番号の absolute form (例: `Phase 5.5.2 Step 1: METRICS_SKIPPED emit`) で書き、`drift-check-anchor-semantic-name` と同型の semantic 参照で構造的に防ぐ。

## 詳細

### 失敗形態

累積 14 回目の cycle 49 H-1 の Self-defeating defense bug の root cause: cycle 49 で導入した METRICS_SKIPPED sentinel 周辺の prose に「Step 2/3 を skip」と書いた直後、別の cycle で前段に新 Step が挿入されて Step 番号が off-by-one drift。「Step 2/3」が actual heading 構造とのずれを起こし、防衛機構を導入する fix 自体が drift を含んで防衛対象だった partial corruption が再開する経路となった。

### Canonical 形式

| 形式 | 例 | drift 耐性 |
|------|-----|-----------|
| ❌ Relative | 「次の Step」「Step 2/3 を skip」「上記 Step」 | 低 (heading reorder で silent 破綻) |
| ✅ Absolute heading + Step | 「Phase 5.5.2 Step 1: METRICS_SKIPPED emit」 | 高 (heading 名 grep で追跡可能) |
| ✅ Semantic anchor | 「DRIFT-CHECK ANCHOR: METRICS_SKIPPED routing block」 | 高 (`drift-check-anchor-semantic-name` 経由) |

### 適用範囲

- prompt 内の「次の Step」「上記 Step」「直前 Step」等の relative 表現
- 判定表の行に序数で隣接行を参照する形（`in_worktree` 行にステップを 1 つ挿入したら、それを「1〜2 をスキップ」と参照していた `in_main` 行の意味が黙って変わる）。ステップ参照は序数ではなく手順名で書く。全経路が通るべきガードは判定表の行に置かず、表の外の無条件前段に置く
- review feedback の Step 参照 (例: 「F-03 で fix したように」ではなく「F-03 'XYZ 集約' で fix したように」)
- commit message / Issue body 内の Step 参照

### 検出手段

- pre-commit lint で `次の Step` / `上記 Step` / `Step [0-9]+/[0-9]+` のような relative 形式を検出して absolute 形式への書き換えを提案
- review feedback の Step 参照は heading title を併記する規約

### Cross-file 次元への拡張

同一ドキュメント内の relative 参照だけでなく、**別ドキュメントの内部 step 番号への cross-file 参照**も同じ drift class に属する。cross-file 参照事例では新設 prose が Issue 作成 helper の内部処理を「Step 2.3 フィールド取得」と番号参照したが、参照先ドキュメントのステップは flat な Step 1/2/3 で「Step 2.3」は実在せず、読者を誤誘導する stale 参照として MEDIUM 検出された（参照先の実在を grep で確認しないまま番号アンカーを書き込んだのが根本原因）。

canonical fix と検証手順:

1. **番号アンカーを削除**し、参照先の実体（クエリルート等）+ SoT ドキュメントへの**相対リンク**に置換する（番号は参照先の再編で陳腐化するが、パス + 見出し名は grep で追跡できる）
2. 置換時は **(a) 参照先ファイルの実在を ls/grep で確認**し、**(b) 同一ファイル内の既存相対パス慣例**（例: `../../references/` 形式）**に追従**する — 初回置換でパス形式の不整合を作り込みやすい
3. 修正前に同一 stale 参照が PR diff 内の他箇所に存在しないか `git grep` で影響範囲スキャンし、pre-existing の類似参照への過剰修正（scope 逸脱）を避ける

## 関連ページ

- [DRIFT-CHECK ANCHOR は semantic name 参照で記述する（line 番号禁止）](./drift-check-anchor-semantic-name.md)

## ソース

- [H-1 Self-defeating defense Step number off-by-one drift](../../raw/reviews/20260430T005759Z-pr-688.md)
- [レビュー結果](../../raw/reviews/20260901T140807Z-pr-2500.md)
