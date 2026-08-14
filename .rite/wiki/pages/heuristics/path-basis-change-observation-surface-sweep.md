---
title: "保存パス基準の変更は観測面と全 caller 引数の同時スイープが必要"
domain: "heuristics"
description: "状態ファイルの保存パス基準を変更する PR (例: cwd 相対 → 共有 state root) では、実装本体の 3 経路 (save / read / delete) を揃えるだけでは不十分。"
created: "2026-07-13T07:40:00Z"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260712T223319Z-pr-1839.md"
tags: []
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-07-13T07:40:00Z" }
---

# 保存パス基準の変更は観測面と全 caller 引数の同時スイープが必要

## 概要

状態ファイルの保存パス基準を変更する PR (例: cwd 相対 → 共有 state root) では、実装本体の 3 経路 (save / read / delete) を揃えるだけでは不十分。パスを「観測する」全箇所と、新しい既定を「bypass しうる」全 caller を同時に洗い出さないと、review-fix loop で同種指摘が cycle を跨いで分割出現する。

## 詳細

起点事例 (review-result / PR-state 群の state-path-resolve 統一、4 cycles で収束) の cycle 1 指摘 7 件中 5 件、cycle 2〜3 指摘 4 件中 3 件が「実装本体は正しいが周辺の追従漏れ」だった。カテゴリ別:

1. **観測面** — パス基準の変更後も旧パスを前提に動く箇所:
   - 既存テストのパス assertion (相対形式を literal pin → FAIL)
   - lint / drift check 等の「第 4 の読取者」(writer と別の root 解決で silent no-op 化)
   - 通知・エラーメッセージの表示パス (実在しないパスをユーザーに提示)
   - canonical spec / 設計 doc の Decision Log (旧設計の記述が現行決定として残存)
2. **caller の明示引数** — 新しい既定を導入しても、唯一の本番 caller が旧来の値を明示引数で渡していると既定は一度も発動しない（F-08 の実測: `--repo-root "$(git rev-parse --show-toplevel)"` の明示渡しが state-root 既定を bypass)。既定を変えたら `grep` で全 caller の引数渡しを確認する。
3. **standalone 保守ツール** — 主要フローの reader/writer を揃えても、one-off の migration / 保守スクリプトが旧解決のまま残る (F-13)。「このパスを読む・書く・消す・表示する・検査する」の 5 動詞で全域 grep する。

## 適用条件

- 状態ファイル・成果物の保存先解決ロジックを変更する PR
- 既定値 (default) の導入・変更を含む helper / script の改修

## 反例・限界

- 概念表記としての散文 (「`.rite/state/` 配下」等の説明文) は logical path が単一 checkout で一致する限り必ずしも追従不要 — 過剰伝播は [[fix-comment-self-drift]] の連鎖を招く
- 観測面のうち markdown skill 本文 (bash block テンプレート) は自動テスト困難なため、間接担保 (同一 resolver 使用) で足りる場合がある

## 関連

- [[asymmetric-fix-transcription]] — 対称位置への伝播漏れの一般形
- [[small-symmetric-pr-sibling-site-grep-review]] — sibling site Grep 照合
- [[total-resolver-delegation-defeats-fail-fast-gate]] — 同 PR で発生した委譲副作用
