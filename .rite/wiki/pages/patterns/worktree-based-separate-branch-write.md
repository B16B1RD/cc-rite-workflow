---
title: "separate_branch 戦略は git worktree で dev ブランチ不動を実現する"
domain: "patterns"
created: "2026-04-16T19:37:16Z"
updated: "2026-04-16T19:37:16Z"
sources:
  - type: "fixes"
    ref: "raw/fixes/20260416T165559Z-pr-548.md"
  - type: "fixes"
    ref: "raw/fixes/20260416T172110Z-pr-548.md"
  - type: "reviews"
    ref: "raw/reviews/20260416T171008Z-pr-548.md"
  - type: "reviews"
    ref: "raw/reviews/20260416T182704Z-pr-548-cycle6.md"
tags: ["git", "worktree", "wiki", "branch-strategy", "issue-547"]
confidence: high
---

# separate_branch 戦略は git worktree で dev ブランチ不動を実現する

## 概要

wiki のような「別ブランチに蓄積するが dev ブランチからの書き込みが主な用途」のワークフローでは、`git stash + git checkout wiki + ... + git checkout-back + git stash pop` という Block A/B パターンが構造的に脆弱（失敗経路での rollback、`plugins/` が消える、LLM への多段契約）。`.rite/wiki-worktree/` に wiki ブランチの git worktree を置き、そこへ Write/Edit することで dev ブランチの HEAD を一切動かさない設計が堅牢。

## 詳細

### 旧 Block A/B パターンの問題

| 問題 | 旧実装の挙動 | worktree 化後 |
|------|------------|--------------|
| `plugins/rite/templates/wiki/page-template.md` が読めない | `git checkout wiki` で `plugins/` 配下が消える | dev ツリーはそのまま — Read ツールで直接読める |
| `.rite/wiki/pages/` が存在せず Write 失敗 | init.md で `.gitkeep` を作っていなかった | init.md Phase 2.2 で `.gitkeep` 生成、既存 wiki ブランチは Phase 3.5.1 で自動 migration |
| Block A/B パターンが構造的に脆弱 | 3 つの bash ブロック間で変数リテラル置換 + `processed_files[]` 配列宣言が LLM の手動契約 | 実ファイルへの Write/Edit のみで差分検出、`wiki-worktree-commit.sh` が add/commit/push を単一プロセスで実行 |
| signal 中断時の rollback | `git stash pop` 無条件実行で dev ツリー破壊リスク | worktree は独立した checkout のため dev ツリーに影響しない |

### Canonical pattern

**実行モデル**:

1. **setup (冪等)**: `wiki-worktree-setup.sh` が `.rite/wiki-worktree/` を作成。既存なら no-op
2. **write**: LLM は `.rite/wiki-worktree/.rite/wiki/pages/{domain}/{slug}.md` に対して Read/Write/Edit
3. **commit (単一プロセス)**: `wiki-worktree-commit.sh` が worktree 内で `git -C ... add/commit/push` を実行
4. **exit code 契約**: `0=success`, `2=legitimate skip`, `3=real error`, `4=commit landed, push failed`

dev ブランチの HEAD は一切動かない。`.rite/wiki-worktree/` は `.gitignore` で除外されるため PR diff にも混入しない。

### cleanup における永続化原則

`.rite/wiki-worktree/` は `/rite:pr:cleanup` で削除しない。理由:

- `wiki-worktree-setup.sh` は冪等で、既存 worktree は no-op として扱われるため再作成コストが極めて高い (clone 相当の I/O)
- 各 PR cycle で wiki worktree を経由して raw source / page が wiki branch に landing するため、cycle を跨いで保持される必要がある
- `.gitignore` で除外済みのため dev ブランチ PR diff への混入もない

手動削除が必要な場合 (リポジトリ移動 / 構造変更 / debug):

```bash
git worktree remove .rite/wiki-worktree
git worktree prune
```

### prunable marker 経由の自動復旧

ユーザーが `rm -rf .rite/wiki-worktree/` を実行した場合、`git worktree list` に prunable marker が残る:

```
worktree /abs/path/.rite/wiki-worktree
HEAD <sha>
branch refs/heads/wiki
prunable: gitdir file points to non-existent location
```

`wiki-worktree-setup.sh` はこの marker を解析して自動 prune するロジックを持つ (PR #548 cycle 2 で追加)。

### YAML branch name の path traversal hardening

`wiki.branch_name` を rite-config.yml から読む場合、ref name validation regex は `[A-Za-z0-9._/-]+$` だけだと `..` や `//` を許容してしまう。`git check-ref-format` 準拠の subset として以下を明示拒否:

- `..` (parent directory traversal)
- `//` (double slash)
- 先頭 `.` (hidden ref)

ダッシュ始まりの値 (`-x`) は git option injection 経路になりうるため、コマンド呼び出しは `--` separator で区切ること。

## 関連ページ

- [Exit code semantic preservation: caller は case で語彙を保持する](patterns/exit-code-semantic-preservation.md)
- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](anti-patterns/asymmetric-fix-transcription.md)

## ソース

- [PR #548 cycle 1 fix (21 findings 解消 — plugin_root 前置、mktemp silent 禁止、wiki worktree 永続化)](raw/fixes/20260416T165559Z-pr-548.md)
- [PR #548 cycle 2 fix (worktree fast path 追加、prunable auto recovery)](raw/fixes/20260416T172110Z-pr-548.md)
- [PR #548 cycle 2 review (worktree collision CRITICAL、asymmetric transcription)](raw/reviews/20260416T171008Z-pr-548.md)
- [PR #548 cycle 6 mergeable (worktree redesign の完成レビュー)](raw/reviews/20260416T182704Z-pr-548-cycle6.md)
