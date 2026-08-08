---
title: "Phase 7 user-escalated recommendation を fix loop に統合する canonical flow"
domain: "patterns"
promote: rite-plugin
created: "2026-05-28T03:00:00+00:00"
updated: "2026-05-28T03:00:00+00:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260527T172656Z-pr-1164.md"
  - type: "reviews"
    ref: "raw/reviews/20260527T174107Z-pr-1164.md"
  - type: "reviews"
    ref: "raw/reviews/20260527T174507Z-pr-1164.md"
  - type: "fixes"
    ref: "raw/fixes/20260527T170259Z-pr-1164.md"
  - type: "fixes"
    ref: "raw/fixes/20260527T172902Z-pr-1164.md"
  - type: "fixes"
    ref: "raw/fixes/20260527T174222Z-pr-1164.md"
tags: ["review-fix-loop", "phase-7", "escalation"]
confidence: high
---

# Phase 7 user-escalated recommendation を fix loop に統合する canonical flow

## 概要

PR review で `[review:mergeable]` 到達後も reviewer recommendation (actionable / boundary / design_confirmation) が surface することがある。Phase 7 は AskUserQuestion で user judgement を取得し、user が「本 PR で対応」を選んだ recommendation を findings に escalate して fix loop に流す経路。**Phase 7 が無いと `mergeable=完了` で stylistic / readability 改善が silent に失われる**。起点事例で 2 回の Phase 7 (cycle 4 / cycle 6) を経て 4 件の polish 改善 (F-10/F-11/F-12 + 内部 R-02) を fix loop に取り込み 8 cycle で final convergence を達成、Phase 7 の有効性を実証した。

## 詳細

### Canonical Flow

1. **review reviewer が recommendation を classification 付きで surface する** (`classification: actionable | design_confirmation | boundary`)
2. **両 reviewer の blocking findings が 0 件 = `[review:mergeable]` 到達**
3. **Phase 7 で recommendation 一覧を AskUserQuestion で user に提示** (each recommendation について「本 PR で対応 / 別 Issue 化 / 見送り」を選択)
4. **user が「本 PR で対応」を選んだ recommendation は findings に escalate** され fix loop に再投入
5. **`design_confirmation` は Phase 7 対象外で skip** (設計合意確認のため fix 対象ではない)
6. **bundled fix が有効**: 独立 recommendation でも同セクション改善であれば bundled fix で 1 commit に統合可能 (cycle count 増加を抑制)

### 起点事例の実測 evidence (8 cycle convergence)

| Cycle | State | Phase 7 escalation | Fix |
|------|-------|-------------------|-----|
| 1 | findings 4 件 (F-01〜F-04) | — | F-01/02/03 fix, F-04 nit |
| 2 | findings 2 件 (F-05/06 demoted → user-escalate F-07/08) | — | F-05〜F-08 fix |
| 3 | findings 1 件 (F-09) | — | F-09 fix (bullet 1 qualifier) |
| 4 | mergeable + recommendations 5 件 | 2 件 escalate (F-10/F-11) | — (cycle 5 で fix) |
| 5 | (cycle 4 escalation) | — | F-10/F-11 bundled fix |
| 6 | mergeable + recommendations 2 件 | 1 件 escalate (F-12 bundled R-01/R-02) | — (cycle 7 で fix) |
| 7 | (cycle 6 escalation) | — | F-12 (1-line quotation 統一) |
| 8 | **0 finding / 0 recommendation** | — | **FINAL CONVERGENCE** |

### Sub-Patterns

1. **`design_confirmation` は Phase 7 対象外**: 設計合意確認カテゴリは fix 対象ではないため skip。`actionable` / `boundary` のみが Phase 7 escalation 対象。
2. **Bundled fix**: 独立 recommendation でも同セクション改善であれば bundled fix で `cycle count` を増やさず効率化（cycle 5 で F-10/F-11 を同 commit に統合した実測)。
3. **Minimum-cost convergence after structural fix**: structural / semantic fix 完了後の polish 修正は典型的に 1-line edit で完結 (cycle 7 F-12 が引用記号 `「」 → **` の 1 行修正のみ)。
4. **Reviewer self-classification の quality signal**: reviewer 自身が「本 PR では対応不要」「stylistic preference 域」「merge 可能水準」と明示することで Phase 7 user judgement の質が上がる ([respect-reviewer-no-action-recommendation](../heuristics/respect-reviewer-no-action-recommendation.md) と sibling pattern)。
5. **Final cycle convergence pattern**: 全 cycle の経過は (structure → clarity → boundary → readability ref → stylistic → verify) の進化的 surface 順序を取りやすく、docs PR の cycle 数は内容量に比例しない（13 行の docs PR で 8 cycle、各 cycle で異なる側面が surface した実測がある）。

### Canonical 対策

- **review orchestrator は mergeable 到達時に必ず Phase 7 を発火させる** (silent mergeable=完了 経路を構造的に塞ぐ)
- **reviewer agent は recommendation を classification metadata 必須で出力する** (Phase 7 routing 判定の入力)
- **Phase 7 で user が選んだ escalation は findings に semantic 等価で promote** (severity / fingerprint 情報を保全)
- **bundled fix の判断は同セクション root cause 共通性で行う** (independent root cause を強引に bundle すると Asymmetric Fix Transcription の温床)

## 関連ページ

- [Reviewer の "本 PR では対応不要" 推奨は尊重する](../heuristics/respect-reviewer-no-action-recommendation.md)
- [Zero finding を legitimate convergence として受け入れる](../heuristics/reviewer-zero-finding-as-legitimate-convergence.md)
- [極小対称化 PR は sibling site Grep 照合で短時間・高確信レビューできる](../heuristics/small-symmetric-pr-sibling-site-grep-review.md)

## ソース

- [PR #1164 review cycle 4 (mergeable → Phase 7 escalation)](../../raw/reviews/20260527T172656Z-pr-1164.md)
- [PR #1164 review cycle 6 (mergeable + Phase 7 bundled escalation)](../../raw/reviews/20260527T174107Z-pr-1164.md)
- [PR #1164 review cycle 8 (FINAL CONVERGENCE)](../../raw/reviews/20260527T174507Z-pr-1164.md)
- [PR #1164 fix cycle 2 (user-escalated F-07/F-08)](../../raw/fixes/20260527T170259Z-pr-1164.md)
- [PR #1164 fix cycle 5 (F-10/F-11 bundled fix)](../../raw/fixes/20260527T172902Z-pr-1164.md)
- [PR #1164 fix cycle 7 (F-12 quotation symbol unification)](../../raw/fixes/20260527T174222Z-pr-1164.md)
