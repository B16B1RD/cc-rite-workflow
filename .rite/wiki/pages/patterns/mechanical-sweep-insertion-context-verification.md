---
type: "patterns"
title: "機械的スイープでは挿入先コンテキストを検証してから変更を適用する"
domain: "patterns"
description: "横断スイープ（多数ファイルへの同型変更の一括適用）は、変更そのものは機械的でも、挿入先のコンテキストは機械的ではない。"
created: "2026-07-20T01:15:00+09:00"
updated: "2026-07-20T01:15:00+09:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260719T151010Z-pr-1919.md"
  - type: "fixes"
    ref: "raw/fixes/20260719T151513Z-pr-1919.md"
  - type: "reviews"
    ref: "raw/reviews/20260719T153208Z-pr-1919-c2.md"
  - type: "fixes"
    ref: "raw/fixes/20260719T153443Z-pr-1919-c2.md"
tags: []
confidence: high
---

# 機械的スイープでは挿入先コンテキストを検証してから変更を適用する

## 概要

横断スイープ（多数ファイルへの同型変更の一括適用）は、変更そのものは機械的でも、挿入先のコンテキストは機械的ではない。`-R` フラグ伝播スイープの 3 レビューサイクルで検出された指摘は、すべて「挿入先コンテキストの検証不足」に還元された。適用前に以下の 4 点を挿入先ごとに確認する。

## 詳細

1. **挿入するフラグが要求する追加引数**: `gh pr view` は `-R` 指定時に selector（PR 番号または branch 名）が必須になる（`argument required when using the --repo flag`）。selector なしの既存コマンドに `-R` だけ足すと、伝播前は動いていたコマンドが無条件失敗する回帰になる。外部 CLI の仕様 claim は runtime 実測（実環境での rc 確認）が最も強い fact-check。
2. **流用する既存変数の意味論**: 挿入先 block に「同じ名前らしき」変数があってもそのまま使わない。`issue-close` の `$owner` は `github.projects.owner`（Project owner）由来で、repo owner と乖離しうる設定だった。`-R` に流用すると乖離構成で誤リポジトリ参照になる。意味論が違う場合は別変数（`owner_repo_slash`）を導入して分離する。
3. **新設識別子と既存識別子の名前空間衝突**: 新設 placeholder `{owner_repo}`（slash 形式）が canonical スニペットの shell 変数 `$owner_repo`（TAB 区切り）と同名衝突し、10 行以内に別形式の同名識別子が並ぶ状態になった。リネームのコストが高い場合は区別注記の追加で足りるかを先に検討する（注記 + 別変数導入は diff 最小）。
4. **同一 block 内の失敗時案内との同期**: 実行コマンドだけ更新して、その失敗時に表示される recovery hint（手動復旧コマンド）を据え置くと、エラー経路の復旧手順自体が同じ理由で失敗する非対称を生む。除外基準は「実行契約の有無」ではなく「実行者（LLM またはユーザー）がそのまま実行するか」で引き、実行系と案内系を同一コミットで同期する。

## 関連ページ

- [スイープの検証 grep にスイープ対象と同一パターンを再利用する](../anti-patterns/sweep-verification-grep-shares-blind-spot.md)
- [placeholder 伝播は実行主体の解決経路を確認してから適用する](../heuristics/placeholder-propagation-requires-resolver-context.md)

## ソース

- [PR #1919 review results](../../raw/reviews/20260719T151010Z-pr-1919.md)
- [PR #1919 fix results](../../raw/fixes/20260719T151513Z-pr-1919.md)
- [PR #1919 review cycle 2 results](../../raw/reviews/20260719T153208Z-pr-1919-c2.md)
- [PR #1919 fix cycle 2 results](../../raw/fixes/20260719T153443Z-pr-1919-c2.md)
