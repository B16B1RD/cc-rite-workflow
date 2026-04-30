---
title: "Step 番号参照は relative (Step N + 1) ではなく absolute (heading title 名 + Step 番号) で書く"
domain: "patterns"
created: "2026-04-30T01:58:00+00:00"
updated: "2026-04-30T01:58:00+00:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260430T005759Z-pr-688.md"
tags: []
confidence: high
---

# Step 番号参照は relative (Step N + 1) ではなく absolute (heading title 名 + Step 番号) で書く

## 概要

prompt / 文書内で「Step 2/3 を skip」「次の Step」のような relative step 参照を書くと、後続の reorder / step 追加で actual heading 構造とのずれが発生し、参照が silent に間違った step を指す regression を生む。Step 番号は heading title 名 + Step 番号の absolute form (例: `Phase 5.5.2 Step 1: METRICS_SKIPPED emit`) で書き、`drift-check-anchor-semantic-name` と同型の semantic 参照で構造的に防ぐ。

## 詳細

### 失敗形態

PR #688 cycle 49 H-1 の Self-defeating defense bug の root cause: cycle 49 で導入した METRICS_SKIPPED sentinel 周辺の prose に「Step 2/3 を skip」と書いた直後、別の cycle で前段に新 Step が挿入されて Step 番号が off-by-one drift。「Step 2/3」が actual heading 構造とのずれを起こし、防衛機構を導入する fix 自体が drift を含んで防衛対象だった partial corruption が再開する経路となった。

### Canonical 形式

| 形式 | 例 | drift 耐性 |
|------|-----|-----------|
| ❌ Relative | 「次の Step」「Step 2/3 を skip」「上記 Step」 | 低 (heading reorder で silent 破綻) |
| ✅ Absolute heading + Step | 「Phase 5.5.2 Step 1: METRICS_SKIPPED emit」 | 高 (heading 名 grep で追跡可能) |
| ✅ Semantic anchor | 「DRIFT-CHECK ANCHOR: METRICS_SKIPPED routing block」 | 高 (`drift-check-anchor-semantic-name` 経由) |

### 適用範囲

- prompt 内の「次の Step」「上記 Step」「直前 Step」等の relative 表現
- review feedback の Step 参照 (例: 「F-03 で fix したように」ではなく「F-03 'XYZ 集約' で fix したように」)
- commit message / Issue body 内の Step 参照

### 検出手段

- pre-commit lint で `次の Step` / `上記 Step` / `Step [0-9]+/[0-9]+` のような relative 形式を検出して absolute 形式への書き換えを提案
- review feedback の Step 参照は heading title を併記する規約

## 関連ページ

- [DRIFT-CHECK ANCHOR は semantic name 参照で記述する（line 番号禁止）](./drift-check-anchor-semantic-name.md)

## ソース

- [PR #688 review 記録 (cycle 49 H-1 Self-defeating defense Step number off-by-one drift)](../../raw/reviews/20260430T005759Z-pr-688.md)
