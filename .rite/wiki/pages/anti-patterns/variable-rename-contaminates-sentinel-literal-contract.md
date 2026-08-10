---
title: "Variable Rename が Sentinel Literal Contract を汚染する"
domain: "anti-patterns"
description: "bash 変数 rename refactor の際、downstream parser (cross-file aggregation) が grep する sentinel emit の literal token (`reason=...` / `details=...`) を変数名の延長として書き換えてしまい、sibling sites が legacy 形式を維持している間 aggregation contract が破綻する silent regression。変数 disambiguation は `${var}` interpolation 部分のみで達成し、emit の固定 literal は contract として保持する。過去のレビュー cycle 1 で code-quality + error-handling 2 reviewer が独立に CRITICAL × 2 + HIGH × 3 (5 site 同根) を検出、cycle 2 fix で全 FIXED → cycle 2 review で 0 findings 収束。"
promote: rite-plugin
reference: "plugins/rite/references/wiki-promotions/anti-patterns/variable-rename-contaminates-sentinel-literal-contract.md"
created: "2026-05-18T00:34:00Z"
updated: "2026-05-18T00:34:00Z"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260518T001536Z-pr-1034.md"
  - type: "reviews"
    ref: "raw/reviews/20260518T002525Z-pr-1034.md"
  - type: "fixes"
    ref: "raw/fixes/20260518T001912Z-pr-1034.md"
tags: ["refactor-scope", "sentinel-contract", "cross-file-aggregation", "silent-regression", "literal-token", "observability"]
confidence: high
---

# Variable Rename が Sentinel Literal Contract を汚染する

## 概要

bash 変数 rename refactor の際、変数名の見た目と同形だが downstream parser (cross-file aggregation) が grep 対象としている sentinel emit の literal token (`reason=...` / `details=...`) を、変数名の延長として一緒に書き換えてしまう anti-pattern。変数 rename の目的 (scope 内 disambiguation) は exit_code= の interpolation 部分のみで達成可能であり、emit の固定 literal は **別レイヤーの contract** として保持する必要がある。一方だけ書き換えると、sibling sites が legacy 形式を維持している間 cross-file aggregation pattern が崩れ、observability が silent に後退する。

## 詳細

### 発生事例（cycle 1）

起点事例は `pr/fix.md` 内の exit code capture 変数を `<command>_<context>_rc` 形式 (例: `commit_rc` → `wiki_ingest_commit_rc`) に統一する symmetric mechanical rename を目的としていた。`code-quality` と `error-handling` の 2 reviewer が独立に **CRITICAL × 2 + HIGH × 3 (5 site 同根)** を検出した:

- 変数 `commit_rc` を `wiki_ingest_commit_rc` に rename する際、同じ block 内の `workflow-incident-emit.sh` 呼び出しに渡す `--details "reason=commit_rc_${commit_rc}"` の **literal token `commit_rc`** までも `wiki_ingest_commit_rc` に書き換えていた
- この `reason=commit_rc_*` は `start-finalize.md` Phase 5.6.2 (Workflow Incident Detection) が cross-file で grep する **canonical aggregation token** であり、sibling sites (`pr/review.md` / `issue/close.md` / `pr/cleanup.md`) は legacy 形式を維持していた
- 結果として当該 PR 単体での自己整合性は保たれるが、aggregation 側の grep がその PR 経由の workflow incident だけを silent に取りこぼす

### Cycle 2 で確立した教訓

cycle 2 fix で 5 finding が全 FIXED 判定 (cycle 2 review: 全 reviewer 承認 0 finding)。確立した原則:

- **変数名と emit literal は別レイヤー**: bash 変数 rename の効果は同一 scope 内の disambiguation のみで実現すべき。emit の固定 literal は contract として保持
- **変数 disambiguation の正しいスコープ**: `--details "reason=commit_rc_${wiki_ingest_commit_rc}"` のように、変数参照部分 (`${var}`) のみが rename 対象。surrounding literal text (`commit_rc_`) は contract 文字列なので保持
- **cross-file aggregation contract**: `reason=` / `details=` の literal token は、sibling sites と grep contract で結ばれた一種の API。1 site で勝手に rename することは API の破壊的変更
- **cross-validation の発見能力**: `code-quality` (命名規約観点) と `error-handling` (sentinel observability 観点) の 2 reviewer が独立に検出することで contract drift を捕捉可能

### 兆候

- refactor PR の diff に `--details "..."` / `--message "reason=..."` 等の固定文字列引数が含まれている
- 変更対象の literal が他ファイル (sibling site) でも同形で出現している
- `grep -r 'reason=commit_rc'` 等の cross-file invariant check を refactor 前に走らせた形跡がない

### Fix の方向

1. refactor 対象変数を確定したら、`grep -rn '<old_var_name>' plugins/` で sibling sites の出現を確認
2. emit literal (`--details` 等) は contract として hands-off に保つ
3. 変数 disambiguation の効果は `${var}` interpolation のみで達成
4. PR review で `code-quality` (命名) と `error-handling` (sentinel) を独立 reviewer として両立させる

## 関連ページ

- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](./asymmetric-fix-transcription.md)

## ソース

- [PR #1034 review results (cycle 1)](../../raw/reviews/20260518T001536Z-pr-1034.md)
- [PR #1034 review results (cycle 2, mergeable)](../../raw/reviews/20260518T002525Z-pr-1034.md)
- [PR #1034 fix results (cycle 2)](../../raw/fixes/20260518T001912Z-pr-1034.md)
