---
type: "anti-patterns"
title: "複数の独立した制約を1つの共有前提条件に総称すると片方だけの前提差異が握り潰される"
domain: "anti-patterns"
promote: rite-plugin
promoted_from: "wiki:/pages/anti-patterns/changelog-shared-precondition-overgeneralization.md"
description: "CHANGELOG やドキュメントで、実際には異なる依存条件を持つ複数の事象を1つの前提条件（例: 特定機能の有効化）でまとめて総称すると、片方だけがその前提に依存するという粒度差が失われる。"
created: "2026-07-21T16:45:00+09:00"
updated: "2026-07-21T16:45:00+09:00"
sources:
  - type: "fixes"
    ref: "raw/fixes/20260721T063551Z-pr-1948.md"
  - type: "reviews"
    ref: "raw/reviews/20260721T063155Z-pr-1948.md"
  - type: "reviews"
    ref: "raw/reviews/20260721T064945Z-pr-1948-cycle2.md"
tags: ["changelog", "doc-heavy-review", "cross-reference", "precondition-granularity", "overgeneralization"]
confidence: medium
---

# 複数の独立した制約を1つの共有前提条件に総称すると片方だけの前提差異が握り潰される

## 概要

CHANGELOG 等のドキュメントで、複数の環境制約や事象を1つの共有前提条件（例: 特定のオプション機能が有効であること）でまとめて記述すると、実際にはそのうち一部だけがその前提に依存し、残りは独立して発生しうるという粒度の違いが読者に伝わらなくなる。Doc-Heavy PR Mode の tech-writer レビューが実装ファイルとのクロスリファレンス検証でこの種の粒度の粗さを検出した実例。

## 詳細

起点事例（CHANGELOG の `[Unreleased]` を `[0.8.4]` へ回収する PR）で、新規追加した Known Limitations エントリが「2つの sandbox 環境制約はいずれも `multi_session` 機能の有効化を前提とする」という総称で書かれていたが、実装（`setup/SKILL.md` の Phase 4.8 / 4.9）を確認すると、Phase 4.8（セッション worktree の state 書込拒否検出）は `multi_session` 有効時のみ発火するのに対し、Phase 4.9（SSH host alias 経由の git push/fetch ブロック検出）は `multi_session` の有効/無効に関わらず独立して発生する制約だった。tech-writer-reviewer が cross-reference 検証（Doc-Heavy PR Mode の Implementation Coverage カテゴリ）でこの不一致を MEDIUM として検出した。

修正は総称を解体し、各項目に前提条件の有無を括弧書きで個別に明示するパターンを採用した:
- `(1) Phase 4.8（multi_session 有効時が前提）: ...`
- `(2) Phase 4.9（multi_session の有効/無効に依存しない）: ...`

fix cycle 1 で修正を適用し、cycle 2（フルレビュー、スコープ縮退なし）で新規指摘 0 件の mergeable 判定に到達した（2 cycle 収束）。CHANGELOG の日英対訳（en/ja）整合性チェックは両言語版とも両 reviewer が実施し問題なし。

**教訓**: 複数の事象・制約をドキュメントで1つの見出しや前提条件にまとめる際は、各事象が本当にその前提を共有しているかを実装（該当機能のコード分岐条件）と個別に突き合わせる。「関連する制約だからまとめて書く」という直感的な整理が、実際の依存関係の違いを覆い隠すことがある。Doc-Heavy PR Mode の cross-reference 検証はこの種の粒度ミスマッチを機械的に検出しうる（tech-writer が実装ファイルの分岐条件を Grep/Read で確認する手順が有効に機能した）。

## 関連ページ

- Asymmetric Fix Transcription (対称位置への伝播漏れ) (`Wiki provenance: ../anti-patterns/asymmetric-fix-transcription.md`)

## ソース

- PR #1948 fix results (`Wiki provenance: ../../raw/fixes/20260721T063551Z-pr-1948.md`)
