# Complexity Gate — Tentative Complexity Estimation + Heuristics Scoring

> **Source of Truth**: 本ファイルは `/rite:issue:create` workflow における **複雑度判定 (XS/S/M/L/XL)** の正規定義 SoT である。Tentative Complexity Estimation (interview 中の暫定推定) と Complexity Heuristics Scoring (Issue 化時の最終決定) の 2 段階を集約する。`create-interview.md` Phase 0.4.1 / `create-register.md` Phase 1.1 からは本 reference へ semantic 参照する。
>
> **抽出経緯**: Issue #773 (#768 P1-3 PR 4/8) で `create-interview.md` Phase 0.4.1 内 "Tentative Complexity Estimation" subsection と `create-register.md` Phase 1.1 全体を本 reference に集約。元ファイルには見出しと redirect notice のみ stub 残置 (歴史的アンカー保持 + caller 内ナビゲーション維持)。caller の機能リンクは本ファイルのアンカー (`#tentative-complexity-estimation` / `#complexity-heuristics-scoring` / `#final-complexity-decision-rules`) へ書き換え済み。

## Tentative Complexity Estimation

`create-interview.md` Phase 0.4.1 で Phase 0.1-0.4 の情報から暫定推定する。用途:

1. **Adaptive Interview Depth** (Phase 0.5 の interview perspective filtering) — どの interview perspective を適用するか決定
2. **Task Decomposition Decision** (Phase 0.6) — XL は decomposition trigger

| Tentative Complexity | Criteria | Example |
|---------------------|----------|---------|
| **XS** | Change location is clear, 1 to a few lines of modification | typo fix, constant value change |
| **S** | Content update in a single file, implementation method is uniquely determined | function fix, style adjustment |
| **M** | Multiple files (approx. 2-5 files) or involves one design decision | small feature addition |
| **L** | Multiple files (approx. 6-10 files), requires multiple design decisions | medium-scale feature, design change |
| **XL** | Large-scale change (10+ files) or spans multiple domains, architecture-level design decisions | new system construction, architecture change |

**Notes**:

- Phase 0.6 decomposition decision では **XL のみ** decomposition trigger (L は対象外)
- 最終 complexity (XS/S/M/L/XL) は Phase 1.1 で決定し Issue Meta section に記録される
- Tentative は Phase 1.1 Heuristics Scoring の **baseline** として使われる ([Final Complexity Decision Rules](#final-complexity-decision-rules) 参照、Heuristics 優先)

---

## Complexity Heuristics Scoring

`create-register.md` Phase 1.1 で **最終 complexity** を確定する。[Tentative Complexity Estimation](#tentative-complexity-estimation) を baseline として、Heuristics Scoring を **primary method** で使用する。Tentative テーブルは直感的な quick reference として、Heuristics Scoring は精度のある最終決定として使い分ける。両者が **不一致** の場合は Heuristics Score が優先される。

Score を +1 する条件:

| Condition | Score |
|-----------|-------|
| Changed files > 3 | +1 |
| Spans multiple modules/services | +1 |
| Public API/interface changes | +1 |
| Migration/backward compatibility needed | +1 |
| Strict non-functional requirements | +1 |
| 2+ unresolved design decisions | +1 |

Score → complexity mapping:

| Score | Complexity |
|-------|------------|
| 0-1 | XS |
| 2 | S |
| 3-4 | M |
| 5 | L |
| 6+ | XL |

Phase 0.1-0.5 の情報を使って各条件を評価する。最終 complexity は Issue Meta section に記録される。

---

## Final Complexity Decision Rules

Tentative Complexity Estimation と Heuristics Scoring が **不一致** の場合、Heuristics Score が優先される。両者の関係性:

| 状況 | Behavior |
|------|----------|
| Tentative と Heuristics が一致 | その値を最終 complexity として採用 |
| Tentative と Heuristics が不一致 | **Heuristics Score 優先** (Tentative は quick reference のみ) |
| Phase 0.4.1 が実行されなかった (Phase 0.1.5 early decomposition path) | Tentative baseline として **XL** を採用 (Phase 0.1.5 で large-scope と検出済み) — Heuristics Scoring 優先のため scoring 条件が低 complexity を示せば downward に調整される |
