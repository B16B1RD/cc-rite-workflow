---
title: "累積対策 PR の review-fix loop で fix 自体が drift を導入する"
domain: "anti-patterns"
created: "2026-04-21T10:35:00+00:00"
updated: "2026-04-21T10:35:00+00:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260421T024947Z-pr-636.md"
  - type: "reviews"
    ref: "raw/reviews/20260421T030627Z-pr-636-cycle-2.md"
  - type: "reviews"
    ref: "raw/reviews/20260421T032048Z-pr-636-cycle-3.md"
  - type: "reviews"
    ref: "raw/reviews/20260421T033906Z-pr-636-cycle-4.md"
  - type: "reviews"
    ref: "raw/reviews/20260421T045816Z-pr-636.md"
  - type: "reviews"
    ref: "raw/reviews/20260421T095348Z-pr-636.md"
  - type: "fixes"
    ref: "raw/fixes/20260421T025621Z-pr-636.md"
  - type: "fixes"
    ref: "raw/fixes/20260421T031214Z-pr-636-cycle-2.md"
  - type: "fixes"
    ref: "raw/fixes/20260421T033138Z-pr-636-cycle-3.md"
  - type: "fixes"
    ref: "raw/fixes/20260421T050914Z-pr-636.md"
tags: ["review-loop", "cumulative-defense", "convergence", "quality-signal", "architectural-surface"]
confidence: high
---

# 累積対策 PR の review-fix loop で fix 自体が drift を導入する

## 概要

同種 regression への N 回目の累積対策 PR では、review-fix loop の各 cycle で適用した fix 自体が次 cycle の新規 drift を生む fractal pattern が顕在化する。PR #636 (Issue #634 = implicit stop regression の 8 回目対策) は 13 cycle 回って収束し、cycle 2 findings の 60% が cycle 1 fix 起因、cycle 3 で cycle 1-2 review では見えなかった architectural HIGH finding (`--preserve-error-count`) が初めて surface した。cycle 数による hard limit ではなく、quality signal (同一パターン反復 / dead marker 追加 / description-impl drift / architectural bug surface) による escalate 判断が canonical。

## 詳細

### 事象 — PR #636 での 13 cycle 収束軌跡 (findings 数)

```
cycle 1 (13) → cycle 2 (10) → cycle 3 (8) → cycle 4 (8) → cycle 5 (4)
  → cycle 6-12 (14→5→7→2→5→5→2) → cycle 13 (0) mergeable
```

- **cycle 2 の 10 findings のうち 6 件が cycle 1 fix 起因** (path prefix drift / bash syntax 破綻 / dead marker 追加 / description-impl drift)
- **cycle 3 で architectural HIGH 初 surface**: `flow-state-update.sh patch` の `.error_count = 0` 無条件リセットが同一 phase self-patch で RE-ENTRY 検出層を永久 unreachable にしていた設計前提の覆し。cycle 1-2 の review では実装読解を伴わない局所的 drift 検出に留まり surface しなかった
- **cycle 9 以降は comment/doc drift に収斂**: implementation bug は cycle 3 で出尽くし、後半は DRIFT-CHECK ANCHOR / tech-writer 指摘 / sibling symmetry 中心

### fractal drift の 3 典型パターン (cycle 1 → 2 → 3 で実測)

1. **Path prefix / literal 短縮 drift**: cycle 1 で HINT bash 例を書き換えた際に path prefix を短縮して sibling site (L310 / L325 / L331) と drift。cycle 2 で HIGH 指摘として再検出
2. **`; then proceed` bash 構文破綻**: cycle 1 で `--next` 値を延長した際に接続詞として `; then proceed` を残し literal copy-paste safe でない。cycle 2 で HIGH 指摘
3. **Dead marker 追加の同型再発**: cycle 1 で削除した dead marker (`MANDATORY_AFTER_INTERVIEW_STEP_0`) と同型の新 marker (`STEP_0_PATCH_FAILED`) を cycle 1 fix で追加したが consumer 0 件で cycle 2 再検出

### canonical 対策 — cycle escalate の quality signal

**cycle 数ベースの hard limit は撤廃済み** (rite-config.yml v1.0.0 で review-fix ループの hard limit キー廃止)。escalate 判断は以下 4 quality signal で行う:

| signal | 観測 | escalate 先 |
|--------|------|------------|
| 同一パターン反復 | cycle N+1 の finding が cycle N fix 起因 drift が > 50% | 外部 reviewer / human review |
| Dead marker 追加 | `[CONTEXT]` flag emit したが consumer 0 件 (grep で確認) | 3 点セット (emit / consume / test) 契約違反 → marker 削除 or wiring 追加 |
| Description-impl drift | prose description が実装と乖離 | doc drift として個別修正 |
| Architectural bug surface | cycle N+1 で cycle N では見えなかった設計前提の覆し | design review (PR 全体の architectural correctness 再評価) |

### Fix 側の予防契約 — 3 点セット / twin site / sibling symmetry

1. **[CONTEXT] retained flag の 3 点セット契約**: 新 marker 追加時は (a) emit site、(b) consume site (stop-guard.sh / Pre-check list の grep 参照)、(c) test assertion の 3 点を **同一 PR で** 揃える。欠けた marker は dead signal として次 cycle で削除推奨
2. **Twin site contract verification**: HINT emit 側 (stop-guard.sh) と grep 参照側 (create.md retained flag emit) が対応する marker は、片側だけ test で verify する pattern が silent regression を許す。TC-634-E のような twin site 両方を同 test で check する canonical template を採用
3. **Sibling symmetry は fix 前に grep で全列挙**: 3-site 対称セット (TC-634-A/B/C、HINT L310/L325/L331 等) は 1 箇所修正時に必ず grep で他 2 箇所を列挙し **atomic に修正**。cycle 1 F-07 → cycle 2 F-06、cycle 1 F-12 → cycle 2 F-01 はこの原則違反で再検出
4. **Self-aware コメントで同 cycle horizontal propagation を明示**: 同 cycle 内で過去 fix が false-positive を修正した場合、新規 fix にも `(line-number 参照を避ける理由は cycle 8 F-05 参照)` のような self-aware コメントを残す (semantic anchor + trailer convention)

### 累積対策 PR 特有の pitfall

- **self-review のみでは収束しない可能性が高い**: 累積対策 N 回目は既存 convention の drift が溜まりやすく、self-review だけで catch できるのは local consistency 中心。architectural design の spread (3-site symmetry 等) は fresh reviewer / human 目でしか proactive に防げない
- **Step 追加時の preamble / range 記述は手動 sync 対象**: "Step X-Y を実行" / "N-line block" のような数値記述は Step 追加のたびに手動更新が必要で自動 lint 対象外。review checklist に mandatory 化するか lint rule 追加を検討
- **Drift 除去 ≠ architectural correctness**: cycle 2 fix で drift 6 件除去しても cycle 3 で HIGH architectural finding が追加検出される。「drift 除去」と「設計の正しさ」は直交軸で、前者の達成は後者を保証しない

### opt-in backward-compatible flag の設計教訓

PR #636 cycle 3 で追加された `--preserve-error-count` flag は、`.error_count = 0` 無条件リセットという従来契約を破壊せずに新 usage pattern (同一 phase への self-patch) を許容する canonical design:

- **既存 caller (phase transition) は flag なしで reset 継続** — 後方互換保証
- **新規 self-patch caller は明示的に保持を選択** — opt-in で意図を明示
- **docstring に各 mode での挙動を明示**: patch mode のみ有効、create/increment mode では silent no-op が意図的

semantics 変更を伴う修正では「新 flag + opt-in + 既存挙動保持」が最もリスクが少ない (PR 全体を書き換えるより diff scope が絞れて review しやすい)。

## 関連ページ

- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](./asymmetric-fix-transcription.md)
- [HINT-specific 文言 pin で case arm 削除 regression を検知する](../patterns/hint-specific-assertion-pin.md)
- [Test が early exit 経路で silent pass する false-positive](./test-false-positive-early-exit.md)
- [新規 exit 1 経路 / sentinel type 追加時は同一ファイル内 canonical 一覧を同期更新し、『N site 対称化』counter 宣言を drift 検出アンカーとして活用する](../heuristics/canonical-list-count-claim-drift-anchor.md)
- [散文で宣言した設計は対応する実装契約がなければ機能しない](./prose-design-without-backing-implementation.md)

## ソース

- [PR #636 cycle 1 review (13 findings, 7 pattern categories)](raw/reviews/20260421T024947Z-pr-636.md)
- [PR #636 cycle 1 fix (13 findings resolved)](raw/fixes/20260421T025621Z-pr-636.md)
- [PR #636 cycle 2 review (10 findings, 60% fix-induced drift)](raw/reviews/20260421T030627Z-pr-636-cycle-2.md)
- [PR #636 cycle 2 fix (10 findings, 6 drift removed)](raw/fixes/20260421T031214Z-pr-636-cycle-2.md)
- [PR #636 cycle 3 review (architectural HIGH surface)](raw/reviews/20260421T032048Z-pr-636-cycle-3.md)
- [PR #636 cycle 3 fix (--preserve-error-count + twin site contract)](raw/fixes/20260421T033138Z-pr-636-cycle-3.md)
- [PR #636 cycle 4 review (incomplete architectural fix detection)](raw/reviews/20260421T033906Z-pr-636-cycle-4.md)
- [PR #636 cycle 5 review (silent-false-pass + line-number reference)](raw/reviews/20260421T045816Z-pr-636.md)
- [PR #636 cycle 5 fix (silent-false-pass via PATH fault injection)](raw/fixes/20260421T050914Z-pr-636.md)
- [PR #636 cycle 13 review (0 findings, mergeable convergence)](raw/reviews/20260421T095348Z-pr-636.md)
