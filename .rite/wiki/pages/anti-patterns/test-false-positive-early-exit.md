---
title: "Test が early exit 経路で silent pass する false-positive"
domain: "anti-patterns"
created: "2026-04-20T01:10:00+00:00"
updated: "2026-04-20T01:10:00+00:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260419T230924Z-pr-608-cycle5-review.md"
  - type: "fixes"
    ref: "raw/fixes/20260419T231616Z-pr-608-cycle6.md"
  - type: "reviews"
    ref: "raw/reviews/20260419T232356Z-pr-608-cycle7.md"
  - type: "fixes"
    ref: "raw/fixes/20260419T232739Z-pr-608-cycle8.md"
tags: []
confidence: high
---

# Test が early exit 経路で silent pass する false-positive

## 概要

`active=false` / `phase mismatch` 等の guard 条件で fixture が early exit するテストは、検証対象のロジックを一切実行しないまま rc=0 で pass する silent false-positive を生む。regression を検出できない test が「green」として merge される経路になる。独立 counter (例: `diag log reason=not_active`) の assertion を追加するか、terminal acceptance 経由を強制する別 TC を active=true 版として分離するのが canonical。更に**新規 TC 追加時は同 cycle で修正された既知 false-positive TC の self-aware コメントを必ず参照する契約**を置く (same-cycle horizontal propagation)。

## 詳細

### 事象 (PR #608 cycle 5-8)

- **cycle 5**: TC-608-D が `active=false` early exit で抜ける構造のため、active 判定の regression を silent に pass させていた。core transition / fallback path 検証が抜け落ちた Test coverage gap パターン (3/9 findings)。
- **cycle 6**: TC-608-D を修正した際、新規 TC-608-E/F/G を追加したが、これらも rc assertion 不足で active 判定 regression を検出できない同型構造を silent に踏襲。
- **cycle 7**: reviewer が TC-608-E/F/G の false-positive を独立検出し、cycle 6 の fix が「同 cycle 過去 fix の self-aware コメントを参照しない」silent drift を起こしたことが判明。
- **cycle 8**: 修正パターンとして「新規 TC 追加時は同 cycle 過去 fix の self-aware コメントを必ず参照する契約」を確立。

### canonical 対策

1. **独立 counter assertion**: `active=false` early exit が発生した場合、`reason=not_active` 等の diag counter を increment し、TC 側でその counter を assert することで「early exit で抜けたこと自体」を検証する。
2. **HINT / body assertion の 2 段検証**: HINT 文言を前半 phrase + 後半 phrase の両方で grep する (例: `cleanup_pre_ingest` + `Phase 4.W.2`)。片側だけでは改変 regression を見逃す。
3. **active=true 版 TC の分離**: early exit 経路を通らない TC を別 case として作成し、terminal acceptance 経由を強制する。
4. **Same-cycle false-positive horizontal propagation 契約**: 同 cycle 内で過去 TC の false-positive が修正された場合、新規 TC 追加時に「この cycle で XXX の false-positive 修正があったので同型を避けている」と self-aware コメントで宣言する。これにより次 cycle reviewer が grep で drift を検出可能。

### 発動条件

- fixture が guard (active=false / phase mismatch / 機能 disable flag) で early exit する構造
- test の stdout / exit status だけで pass/fail を判定している
- 同 cycle に parity TC を複数追加している (sibling site 増殖 phase)

### review 側の検出手法

- TC が検証する「本体 logic」が実際に実行されるか fixture trace で確認
- 同 cycle の過去 fix コメントに「false-positive 修正」「guard で抜ける」等の self-aware 痕跡があれば parity TC も同型疑いで精査
- `rc=0` 以外の assertion (stderr content / diag counter / state file mutation) が存在するか確認

## 関連ページ

- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](pages/anti-patterns/asymmetric-fix-transcription.md)

## ソース

- [PR #608 review cycle 5 (Test coverage gap 3/9 findings)](raw/reviews/20260419T230924Z-pr-608-cycle5-review.md)
- [PR #608 fix cycle 6 (false-positive 早期露呈パターン)](raw/fixes/20260419T231616Z-pr-608-cycle6.md)
- [PR #608 review cycle 7 (TC-608-E/F/G false-positive 発見)](raw/reviews/20260419T232356Z-pr-608-cycle7.md)
- [PR #608 fix cycle 8 (same-cycle 横展開契約)](raw/fixes/20260419T232739Z-pr-608-cycle8.md)
