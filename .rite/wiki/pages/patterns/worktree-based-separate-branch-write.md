---
title: "separate_branch 戦略は git worktree で dev ブランチ不動を実現する"
domain: "patterns"
description: "wiki 別ブランチへの書き込みを `stash + checkout + stash pop` で行う Block A/B パターンは構造的に脆弱。`.rite/wiki-worktree/` worktree へ Write/Edit、`wiki-worktree-commit.sh` で単一プロセス commit/push することで dev ブランチ不動を実現する (関連する課題)。過去のレビューで corrupt/orphaned worktree (stale gitdir、リポジトリ移動由来) からの自己回復を追加 — fast-path 検証の rc-aware 化 + setup.sh 委譲 + legacy fallthrough、silent exit 1 廃止と WARNING surface、fallthrough コメントの実 rc 遷移正確化。"
promote: rite-plugin
created: "2026-04-16T19:37:16Z"
updated: "2026-06-26T03:18:14+00:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260626T031814Z-pr-1663.md"
  - type: "fixes"
    ref: "raw/fixes/20260416T165559Z-pr-548.md"
  - type: "fixes"
    ref: "raw/fixes/20260416T172110Z-pr-548.md"
  - type: "reviews"
    ref: "raw/reviews/20260416T171008Z-pr-548.md"
  - type: "reviews"
    ref: "raw/reviews/20260416T182704Z-pr-548-cycle6.md"
tags: ["git", "worktree", "wiki", "branch-strategy", "issue-547", "self-healing", "stale-gitdir", "rc-aware"]
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

`wiki-worktree-setup.sh` はこの marker を解析して自動 prune するロジックを持つ（cycle 2 で追加）。

### corrupt/orphaned worktree (stale gitdir) からの自己回復

prunable marker 経由の自動復旧 (上節) は `git worktree list` に登録されたまま gitdir が壊れたケースを扱う。一方 **リポジトリ自体の移動 (アカウント移管 / clone のコピー)** では、`.rite/wiki-worktree/.git` ポインタが旧パスを指したまま残り、かつ `git worktree list` にも未登録の**孤児ディレクトリ**になる。この corrupt/orphaned 状態は prunable marker を残さないため上節のロジックでは検出できない。

実機回帰では、この孤児 worktree により raw source が約 2 週間 silent に蓄積停止していた。破断連鎖:

1. `wiki-ingest-commit.sh` の worktree fast-path が `[ -d .rite/wiki-worktree ]` を true 判定 (ディスク上には存在する)
2. `verify_worktree_branch` の `git -C .rite/wiki-worktree rev-parse` が stale gitdir で失敗 (rc≠0)
3. commit script が `|| exit 1` で **silent に exit 1**
4. caller (close/review/fix) では non-blocking WARNING 扱いのため誰も気付かず stall

canonical 対策 (commit / setup 両経路の自己回復):

1. **fast-path 検証を rc-aware 化する**: worktree 存在チェック (`[ -d ]`) を「健全な registered worktree である」保証と混同しない。`verify_worktree_branch` の rc を 3 値に分離し、`rc=2` (corrupt/orphaned) は `wiki-worktree-setup.sh` に自己回復を委譲して再検証、回復不能なら legacy stash/checkout path へフォールバック、`rc=3` (wrong branch) のみ従来どおり exit する。
2. **setup 側で stale gitdir 残留ディレクトリを除去してから再作成する**: ディスク上に存在するが registered worktree でない残留ディレクトリを `rm -rf` + `git worktree prune` で除去してから worktree を再作成する。「ディレクトリが存在する = 健全」の仮定を捨てる。
3. **silent `exit 1` を廃止し WARNING を surface する**: 自己回復経路は必ず observable な WARNING を出す (= silent stall の構造的廃止)。anti-silent-failure 化する修正自身が局所的に `2>/dev/null || true` の silent 抑制を残さないよう、同ファイル内の既存防御パターン (stderr 退避 + WARNING surface + scope-limited trap) と**対称化**する。
4. **fallthrough コメントは実 rc 遷移に正確化する**: rc-aware case の fallthrough コメントは実際の rc 遷移 (recreate 成功は rc=0 で case-0、case-star 到達は setup exit 2/3 / 稀な reverify-still-2 のみ) を正確に記述する。状態変化後に旧前提のコメントを残置しない ([[stale-historical-comment-after-state-change]])。

リポジトリ移動・コピーは現実的なシナリオであり、「ディスク上に worktree ディレクトリが存在するが registered worktree ではない」ケースを setup / commit 両経路で想定するのが堅牢性の必須要件。

### YAML branch name の path traversal hardening

`wiki.branch_name` を rite-config.yml から読む場合、ref name validation regex は `[A-Za-z0-9._/-]+$` だけだと `..` や `//` を許容してしまう。`git check-ref-format` 準拠の subset として以下を明示拒否:

- `..` (parent directory traversal)
- `//` (double slash)
- 先頭 `.` (hidden ref)

ダッシュ始まりの値 (`-x`) は git option injection 経路になりうるため、コマンド呼び出しは `--` separator で区切ること。

## 関連ページ

- [Exit code semantic preservation: caller は case で語彙を保持する](./exit-code-semantic-preservation.md)
- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](../anti-patterns/asymmetric-fix-transcription.md)
- [mktemp 失敗は silent 握り潰さず WARNING を可視化する](./mktemp-failure-surface-warning.md)
- [状態変化後も未来形 / 旧値前提のインラインコメントが残置する (stale historical comment drift)](../anti-patterns/stale-historical-comment-after-state-change.md)

## ソース

- [PR #548 cycle 1 fix (21 findings 解消 — plugin_root 前置、mktemp silent 禁止、wiki worktree 永続化)](../../raw/fixes/20260416T165559Z-pr-548.md)
- [PR #548 cycle 2 fix (worktree fast path 追加、prunable auto recovery)](../../raw/fixes/20260416T172110Z-pr-548.md)
- [PR #548 cycle 2 review (worktree collision CRITICAL、asymmetric transcription)](../../raw/reviews/20260416T171008Z-pr-548.md)
- [PR #548 cycle 6 mergeable (worktree redesign の完成レビュー)](../../raw/reviews/20260416T182704Z-pr-548-cycle6.md)
- [PR #1663 review results — corrupt/orphaned worktree (stale gitdir、リポジトリ移動由来) からの自己回復: rc-aware fast-path 検証 + setup.sh 委譲 + legacy fallthrough、silent exit 1 廃止と WARNING surface、fallthrough コメントの実 rc 遷移正確化](../../raw/reviews/20260626T031814Z-pr-1663.md)
