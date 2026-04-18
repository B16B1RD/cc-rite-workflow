---
title: "canonical reference 文書のサンプルコードは canonical 実装と一字一句同期する"
domain: "patterns"
created: "2026-04-18T17:40:00+09:00"
updated: "2026-04-18T17:40:00+09:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260418T072254Z-pr-564-rerun.md"
  - type: "fixes"
    ref: "raw/fixes/20260418T071459Z-pr-564.md"
tags: []
confidence: high
---

# canonical reference 文書のサンプルコードは canonical 実装と一字一句同期する

## 概要

reference 文書 (bash-trap-patterns.md / bash-cross-boundary-state-transfer.md 等) のサンプルコードはコピペ利用される前提のため、canonical 実装と一字一句揃っていなければ silent failure を下流に伝播させる。新規 reference を追加する際は、example を「canonical 実装 site から直接切り出す」「差分レビューで逐語照合する」を厳守する。

## 詳細

### 発生事例 (PR #564)

新規追加した `plugins/rite/commands/wiki/references/bash-cross-boundary-state-transfer.md` の Pattern 3 example で、canonical 実装 (lint.md Phase 6.0) が持っている `else rc=$?` を欠落させ、未定義 `$rc` を参照する模範例を残してしまった (F-07 検出)。reference 文書は後続実装者がコピペ origin として使うため、欠落したまま新しい site に複製されると silent regression が増殖する。

### 失敗の構造

1. 著者は canonical 実装 (lint.md Phase 6.0) を「脳内で抽象化」して reference 文書に書く
2. 抽象化の過程で細部 (`else rc=$?` 等) が "気づかず" 脱落する
3. reference を読んだ下流実装者は「reference が正」と信じてコピペする
4. 結果として canonical 実装と drift した sample が拡散する

### 対処の canonical pattern

- **切り出し原則**: reference 追加時は canonical 実装 site から「行コピー」する。抽象化・書き直しは禁止
- **差分 lint**: reference 文書と canonical 実装 site の両方を grep で発見できる anchor (例: `>>> DRIFT-CHECK ANCHOR: ...`) で明示契約し、将来的に `/rite:lint` で機械検証する
- **逐語照合**: PR レビュー時に「reference 文書の全 bash code block」と「canonical site の bash code block」を diff で突き合わせる手順を checklist 化する
- **reference 文書の example 粒度**: Minimal Working Example ではなく Complete Canonical Example (全 error handling / trap / cleanup を含む) を載せる。抜粋すると必ず抜け漏れが起きる

### 関連パターン

- **Asymmetric Fix Transcription**: 既存 site への fix を他 site に伝播し忘れるのと同型の失敗モード。本パターンは「reference ↔ canonical site」という異なる書式間での drift に特化した sub-pattern
- **散文で宣言した設計は対応する実装契約がなければ機能しない**: 「reference 文書は canonical 実装と同期しているはず」という prose-only 宣言だけでは drift 検出には不十分

## 関連ページ

- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](../anti-patterns/asymmetric-fix-transcription.md)

## ソース

- [PR #564 re-review (11th cycle)](../../raw/reviews/20260418T072254Z-pr-564-rerun.md)
- [PR #564 fix results (11th cycle)](../../raw/fixes/20260418T071459Z-pr-564.md)
