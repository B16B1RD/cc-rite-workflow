---
title: "Asymmetric Fix Transcription (対称位置への伝播漏れ)"
domain: "anti-patterns"
created: "2026-04-16T19:37:16Z"
updated: "2026-04-16T19:37:16Z"
sources:
  - type: "fixes"
    ref: "raw/fixes/20260416T173607Z-pr-548-cycle3.md"
  - type: "fixes"
    ref: "raw/fixes/20260416T180658Z-pr-548.md"
  - type: "fixes"
    ref: "raw/fixes/20260416T181846Z-pr-548.md"
  - type: "reviews"
    ref: "raw/reviews/20260416T173035Z-pr-548.md"
  - type: "reviews"
    ref: "raw/reviews/20260416T180001Z-pr-548.md"
  - type: "reviews"
    ref: "raw/reviews/20260416T181357Z-pr-548.md"
  - type: "reviews"
    ref: "raw/reviews/20260416T182704Z-pr-548-cycle6.md"
tags: ["fix-cycle", "review-loop", "convergence", "propagation"]
confidence: high
---

# Asymmetric Fix Transcription (対称位置への伝播漏れ)

## 概要

fix を 1 箇所に適用したとき、同じパターンを持つ「対称位置」（ペア/トリオの兄弟スクリプト、同型 idiom の別 phase、相互参照の Phase 番号等）に同じ fix を伝播させ忘れる failure mode。次サイクルの review で片割れが「新規」findings として浮上し、収束サイクル数を膨張させる。

## 詳細

### 発生条件

以下のケースで発生しやすい:

1. **同型 bash idiom が複数 phase/スクリプトに存在**: 例 — `if ! cmd; then rc=$?` が `ingest.md Phase 1.3` と `init.md Phase 3.5` の両方にある。片方だけ `set +e; cmd; rc=$?; set -e` に直しても反対側に残る
2. **ペア/トリオで対称運用する兄弟スクリプト**: `wiki-ingest-commit.sh` / `wiki-worktree-commit.sh` / `wiki-worktree-setup.sh` のように同じ防御パターン（stderr tempfile 退避、`exec 9>` subshell guard、fail-fast on git error）を共有すべき。片方だけに適用すると次 cycle で reviewer が非対称を検出
3. **Phase 番号書き換え時の相互参照**: 1 箇所の Phase 番号を変えると、他 doc の参照番号も連動して直す必要がある
4. **同一 finding を 3 箇所 literal copy で維持する契約**: 例 — `pr/review.md` Phase 6.5.W.2 / `pr/fix.md` Phase 4.6.W.2 / `issue/close.md` Phase 4.4.W.2 の sentinel emit

### PR #548 での実測収束軌跡

6 cycle の review-fix ループで観測された findings 数: `21 → 17 → 2 → 7 → 3 → 0`

- cycle 3/4/5 はいずれも「前 cycle の fix が対称位置を取りこぼした」失敗で発生
- **cycle ごとに `propagation_applied: 0`** — fix 側が自動伝播を試みていない
- cross-validation (2 人以上の reviewer が独立検出) で初めて非対称が可視化された

### Detection Heuristic

fix 直後に必ず実行する:

```bash
# 同一 anti-pattern の残存を全 *.md/*.sh でスキャン
grep -rn "{anti-pattern-regex}" --include='*.md' --include='*.sh' .

# Phase 番号を変えたら参照漏れチェック
grep -rn "Phase {old_number}" --include='*.md' .
```

### Mitigation — 契約として明示化する

1. **finding 側 metadata**: reviewer は `files_to_propagate_to` に対称ファイルを明示列挙
2. **fix 側 atomic apply**: 1 つの finding に対する Edit は、列挙された全ファイルに同 commit で適用
3. **pair annotation in code**: `# keep in sync with wiki-worktree-commit.sh L215-223` のようなコメントで対称位置を埋め込む（ただし位置ドリフト耐性のため行番号ではなく関数名/セクション名で）
4. **shared lib 抽出が根本解決**: cross-script duplication は個別修正の繰り返しではなく共通 helper 抽出で解消する（PR #548 の F-05/F-06 → Issue #549）

### Cross-validation で確度を boost

同一箇所を 2 人以上の reviewer が独立検出した場合は自動的に severity を boost（triple cross-validation で HIGH に昇格）。reviewer 単独検出より信頼性が高い。

## 関連ページ

- （関連ページなし）

## ソース

- [PR #548 cycle 3 fix: asymmetric fix transcription pattern](raw/fixes/20260416T173607Z-pr-548-cycle3.md)
- [PR #548 cycle 4 fix results](raw/fixes/20260416T180658Z-pr-548.md)
- [PR #548 cycle 5 fix results](raw/fixes/20260416T181846Z-pr-548.md)
- [PR #548 cycle 3 review (2 findings, convergence)](raw/reviews/20260416T173035Z-pr-548.md)
- [PR #548 cycle 4 review results](raw/reviews/20260416T180001Z-pr-548.md)
- [PR #548 cycle 5 review](raw/reviews/20260416T181357Z-pr-548.md)
- [PR #548 cycle 6 mergeable (final lesson)](raw/reviews/20260416T182704Z-pr-548-cycle6.md)
