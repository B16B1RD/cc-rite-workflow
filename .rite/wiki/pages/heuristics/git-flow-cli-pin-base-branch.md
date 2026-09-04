---
title: "branch を作る gh コマンドは git-flow で --base を明示し default branch 起点の push 衝突を防ぐ"
domain: "heuristics"
description: "`branch.base` ≠ リポジトリの default branch という git-flow 構成では、remote ブランチを作成する gh CLI（`gh issue develop` 等）に `--base` を明示しないと、remote が default branch (main) 起点で作られ、local の base 派生ブランチと乖離して初回 push が non-fast-forward で必ず失敗する。"
created: "2026-05-23T11:37:40Z"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260523T112739Z-pr-1097.md"
tags: ["gh-cli", "git-flow", "branch-base", "drift-prevention"]
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-05-23T11:37:40Z" }
---

# branch を作る gh コマンドは git-flow で --base を明示し default branch 起点の push 衝突を防ぐ

## 概要

`branch.base` ≠ リポジトリの default branch という git-flow 構成では、remote ブランチを作成する gh CLI（`gh issue develop` 等）に `--base` を明示しないと、remote が default branch (main) 起点で作られ、local の base 派生ブランチと乖離して初回 push が non-fast-forward で必ず失敗する。

## 詳細

`gh issue develop {issue_number} --name "{branch_name}"` は `--base` 未指定時にリポジトリのデフォルトブランチ (main) を起点に remote ブランチを作成する。一方ローカルブランチは `branch.base` (develop) から派生するため、remote (main 起点) と local (develop 起点) の base が乖離し、初回 `git push` が `! [rejected] (non-fast-forward)` で失敗する。ある Issue の作業中に実際に発生し、force-with-lease で都度回避していた構造的欠陥を、`--base "{base_branch}"` の明示により解消した。

**canonical 対策**: remote ブランチを作成する CLI には base を明示固定する。

```bash
# git-flow で base≠default のとき push 衝突を防ぐため --base を明示する（drift 防止）
gh issue develop {issue_number} --name "{branch_name}" --base "{base_branch}"
```

**一般化**: branch を作成する CLI（`gh issue develop` / `gh pr create` / 類似ツール）は base を「リポジトリの default branch」と暗黙に仮定する。git-flow のように作業 base ≠ default branch の構成では base を必ず明示する。なお `gh issue develop --base` には `gh pr create` の base も連動させる副次効果があるが、`pr:create` 側が自前で `--base` を指定済みであれば無害。

**drift 防止（WHY コメント併記）**: 「なぜこのフラグが必要か」を bash スニペット内に WHY コメントとして併記すると、後続編集でフラグが削除される退行を防げる。非自明なフラグ選択は、その必然性をコメントで明示しておくことが drift 対策になる。

## 関連ページ

- （関連ページなし）

## ソース

- [レビュー結果](../../raw/reviews/20260523T112739Z-pr-1097.md)
