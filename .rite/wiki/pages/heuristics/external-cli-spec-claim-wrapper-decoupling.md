---
type: "heuristics"
title: "外部 CLI の仕様主張（冪等性等）は wrapper 構造で spec 要求から分離し、実行検証なしでは blocking にしない"
domain: "heuristics"
promote: rite-plugin
description: "外部 CLI の挙動に関する主張（例: 「`gh project link` は既にリンク済みでも成功する」）は、reviewer が read-only で実行検証できない場合 Demonstrable ゲートを越えないため、blocking finding ではなく調査推奨（要検証マーカー付き）に分離する。"
created: "2026-07-12T22:55:00+09:00"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260712T134842Z-pr-1835.md"
tags: []
confidence: medium
generated: { by: "rite-wiki-ingest/unknown", at: "2026-07-12T22:55:00+09:00" }
---

# 外部 CLI の仕様主張（冪等性等）は wrapper 構造で spec 要求から分離し、実行検証なしでは blocking にしない

## 概要

外部 CLI の挙動に関する主張（例: 「`gh project link` は既にリンク済みでも成功する」）は、reviewer が read-only で実行検証できない場合 Demonstrable ゲートを越えないため、blocking finding ではなく調査推奨（要検証マーカー付き）に分離する。同時に、spec の「冪等であること（already-done でもエラー停止しない）」という MUST には 2 つの読み（Reading A: 外部コマンド自身が冪等 / Reading B: step が冪等）があり、load-bearing なのは Reading B — `if ! cmd; then WARNING; fi` の non-blocking wrapper は外部コマンドの冪等性に**依存せず**無条件に Reading B を満たす。

## 詳細

### 背景（cycle 2）

setup スキルに `gh project link` の冪等実行を追加した PR で、コメント「冪等: 既にリンク済みでも成功する」が gh CLI の外部仕様主張であることを 2 reviewer が独立に特定した。gh manual は re-link 時挙動を記載しておらず、reviewer は READ-ONLY 制約下で実行検証できない。

- 「非 0 で失敗するかもしれない」と断定する Confidence は 80 未満 → 指摘事項に載せると仮説的懸念（禁止）になる
- 仮に外部コマンドが非冪等でも、`if !` ラッパーが吸収して「再実行時に spurious WARNING が出る」だけの bounded / cosmetic な劣化に留まる
- したがって blocking にせず、観測的な exit code 確認（実環境での再実行）を調査推奨として残す判定が正しい

### Reading A/B 分離

| Reading | 主張 | 検証可能性 | spec 充足への寄与 |
|---------|------|-----------|------------------|
| A: 外部コマンド自身が冪等 | `gh project link` が re-link で exit 0 | 実行検証が必要（read-only レビューでは不可） | 不要（コメントの正確性のみに影響） |
| B: step が冪等 | wrapper が already-done でもエラー停止しない | 構造検証で完結（`if !` + 非 exit を読めばよい） | これが load-bearing |

spec の「冪等」MUST を実装するときは Reading B を wrapper 構造で保証し、Reading A への依存をコメント上の non-load-bearing な主張に格下げしておくと、外部仕様の不確実性が仕様適合を脅かさない。

### 適用範囲

- 外部 CLI / API の再実行時挙動・エラーコード・バージョン依存挙動への主張全般
- reviewer 側: 実行検証できない外部仕様主張は Fact-Checking Phase での公式ドキュメント照合か調査推奨への分離で扱う
- 実装側: spec の already-done 系要求（冪等・再入可能）は外部挙動非依存の wrapper（non-blocking if-guard）で構造的に満たす

## 関連ページ

- [Observed Likelihood Gate — evidence anchor 未提示は推奨事項に降格](../heuristics/observed-likelihood-gate-with-evidence-anchors.md)

## ソース

- [レビュー結果](../../raw/reviews/20260712T134842Z-pr-1835.md)
