---
title: "責務境界外 finding は boundary 申し送り → 管轄 reviewer の follow-up 評価で確定する"
domain: "patterns"
promote: rite-plugin
created: "2026-06-06T15:31:02Z"
updated: "2026-06-06T15:31:02Z"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260606T134627Z-pr-1294.md"
tags: []
confidence: medium
---

# 責務境界外 finding は boundary 申し送り → 管轄 reviewer の follow-up 評価で確定する

## 概要

sole reviewer guard で追加された co-reviewer が、他 reviewer 管轄の checklist 項目 (例: CFIC #6 Documentation i18n parity は tech-writer 管轄) に該当する defect を検出した場合、自分で severity を確定せず **boundary 推奨として申し送り**、orchestrator が管轄 reviewer に follow-up 評価を依頼して確定ゲート (Confidence / Demonstrable / revert test) で severity を確定する。検出と確定の責務分離により、単独 reviewer の盲点防止と severity 判定の精度を両立する。

## 詳細

**実測経緯（Doc-Heavy 列挙補完 PR）**:

1. tech-writer (Doc-Heavy mandatory reviewer) が初回レビューで CFIC #6 (Documentation i18n parity) を実行漏れ — SPEC.md (en) のみ列挙補完し SPEC.ja.md が未同期のまま残る片側更新を見逃した。
2. sole reviewer guard で追加された co-reviewer (code-quality) が Cross-File Impact Check で SPEC.ja.md の drift を検出。
3. CFIC #6 は tech-writer 管轄のため、code-quality は直接 severity 確定せず **責務境界に従い boundary 推奨として申し送り**。
4. orchestrator が tech-writer に follow-up 評価を依頼 → 3 ゲート (Confidence 95 / Demonstrable / revert test PASS) 通過で HIGH × current-pr に確定。

**なぜこの分離が有効か**:

- **盲点防止 (検出側)**: sole reviewer guard は「単独 reviewer の checklist 実行漏れ」を第 2 の独立視点で補完する。本件は guard が実際に機能した実例 — co-reviewer 不在なら CFIC #6 違反は merge まで素通りしていた。
- **判定精度 (確定側)**: co-reviewer が越権で severity 確定すると、管轄外基準の誤適用 (over/under-severity) リスクがある。管轄 reviewer の専門基準 + 確定ゲートを通すことで finding quality を保つ。
- **revert test との接続**: 「PR 前は両版とも未列挙で対称だった (非対称は本 PR が新規導入)」という current-pr 帰属判定は revert test で機械的に立証され、boundary 申し送り → follow-up 評価の往復が hallucination でなく demonstrable evidence に基づくことを保証した。

**適用条件**: multi-reviewer 構成で責務境界 (reviewer criteria / CFIC 項目管轄) が定義されている場合。境界が未定義の項目は通常の cross-validation で扱う。

## 関連ページ

- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](../anti-patterns/asymmetric-fix-transcription.md)
- [re-review / verification mode でも初回レビューと同等の網羅性を確保する (Anti-Degradation Guardrail)](../heuristics/reviewer-scope-antidegradation.md)
- [reviewer の regression 主張は revert test (git show / git diff) で PR 由来か pre-existing かを独立検証する](../heuristics/reviewer-regression-claim-revert-test-attribution.md)

## ソース

- [PR #1294 review results](../../raw/reviews/20260606T134627Z-pr-1294.md)
