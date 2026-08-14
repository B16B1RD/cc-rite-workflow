---
type: "anti-patterns"
title: "スイープの検証 grep にスイープ対象と同一パターンを再利用する"
domain: "anti-patterns"
description: "横断スイープ（全域への機械的変更）の完了検証を、スイープ対象の抽出に使ったのと同じ grep パターンで行うと、抽出時の死角が検証にもそのまま引き継がれ、「残存ゼロ」という検証結果が構造的に偽りになる。"
created: "2026-07-20T01:15:00+09:00"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260719T154814Z-pr-1919-c3.md"
  - type: "fixes"
    resource: "raw/fixes/20260719T154952Z-pr-1919-c3.md"
tags: []
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-07-20T01:15:00+09:00" }
---

# スイープの検証 grep にスイープ対象と同一パターンを再利用する

## 概要

横断スイープ（全域への機械的変更）の完了検証を、スイープ対象の抽出に使ったのと同じ grep パターンで行うと、抽出時の死角が検証にもそのまま引き継がれ、「残存ゼロ」という検証結果が構造的に偽りになる。検証はスイープ対象の**性質**（何に依存するコマンドか）に基づいて独立に設計しなければならない。

## 詳細

SSH host alias 対応の `-R` 伝播スイープで、対象抽出も完了検証も `grep 'gh \(pr\|issue\) '` を使った結果、`gh label create`（repo コンテキスト依存だがパターン外）の実行ブロック 2 箇所が抽出からも検証からも漏れた。検証 grep が「残存ゼロ」を報告したまま 3 レビューサイクルを通過し、cycle 3 の reviewer による runtime 実測（`gh label list` が alias 環境で rc=1）で初めて発覚した。

- 検証がスイープと同一の入力集合を見る限り、検証は「スイープが自分の見えた範囲を処理したこと」しか保証しない
- 正しい検証は対象の性質から導く: この例では「コマンド名の列挙（gh pr/issue）」ではなく「repo コンテキスト依存性（remote 解決を必要とするか）」が判定基準であり、`gh label` / `gh repo` / `gh api`（path 明示は除外）等を含む集合で検証すべきだった
- 失敗が `2>/dev/null || true` などの既存 suppression に飲み込まれる箇所では、この見逃しが silent failure として長期残存する（下流の別エラーとして誤誘導的に surface する）

## 関連ページ

- [placeholder 伝播は実行主体の解決経路を確認してから適用する](../heuristics/placeholder-propagation-requires-resolver-context.md)
- [機械的スイープでは挿入先コンテキストを検証してから変更を適用する](../patterns/mechanical-sweep-insertion-context-verification.md)

## ソース

- [PR #1919 review cycle 3 results](../../raw/reviews/20260719T154814Z-pr-1919-c3.md)
- [PR #1919 fix cycle 3 results](../../raw/fixes/20260719T154952Z-pr-1919-c3.md)
