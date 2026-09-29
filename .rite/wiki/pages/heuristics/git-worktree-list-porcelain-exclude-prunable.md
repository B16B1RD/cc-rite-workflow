---
type: "heuristics"
title: "git worktree list --porcelain はブロック単位で読み、prunable の worktree を除く"
domain: "heuristics"
description: "git worktree list は、ディレクトリや .git が消えて git が prunable と報告する worktree も一覧に返すため、存在する worktree だけを対象にする判定はブロック単位で読んで prunable を除く必要がある。"
created: "2026-09-29T22:00:05Z"
generated: { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-29T22:00:05Z" }
sources:
  - type: "fixes"
    resource: "raw/fixes/20260929T213239Z-pr-3446.md"
tags: ["git", "worktree"]
confidence: high
---

# git worktree list --porcelain はブロック単位で読み、prunable の worktree を除く

## 概要

git worktree list は、ディレクトリや .git が消えて git が prunable と報告する worktree も一覧に返すため、存在する worktree だけを対象にする判定はブロック単位で読んで prunable を除く必要がある。

## 詳細

`git worktree list --porcelain` の出力は、空行で区切られたブロックの並びである。各ブロックは `worktree <path>` 行で始まり、`HEAD` / `branch` / `detached` / `locked` / `prunable <理由>` などの属性行が続く。`worktree` 行だけを拾う読み方では、ディレクトリを消したが `git worktree prune` していない worktree も一覧に残る。そのパスに後から普通のディレクトリを作ると、そのディレクトリは「読めない worktree」と誤判定される。そこで直すべき git のエラーは存在せず、本当の直し方（`git worktree prune`、またはチェックアウトへ移る）はどこにも出ない。

- 空行でブロックに分け、`prunable` で始まる属性行を持つブロックを除く。行単位で拾わない。
- `prunable` は属性の後ろに理由が続くので、完全一致ではなく前方一致で見る。完全一致にすると除外が効かない（変異テストで確認済み）。
- ディレクトリは残っていても `.git` が消えた worktree も git は prunable と報告する。git から見て worktree でなくなったものは worktree として扱わない、と読むのが正しい。
- `locked` の worktree は、ディレクトリが消えても prunable にならない。lock を使う運用があるなら別途扱いを決める。

## 関連ページ

- [Mutation testing で test の真正性 (dead code 検出 + identification power) を empirical 検証する](../patterns/mutation-testing-test-fidelity.md)

## ソース

- [fix 結果](../../raw/fixes/20260929T213239Z-pr-3446.md)
