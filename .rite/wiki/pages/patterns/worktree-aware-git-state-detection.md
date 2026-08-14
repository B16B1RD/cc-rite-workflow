---
type: "patterns"
title: "worktree 運用の git 状態検出は .git 直書きせず git rev-parse --git-path で解決する"
domain: "patterns"
promote: rite-plugin
description: "worktree では merge/rebase の中断状態を示す `MERGE_HEAD` / `rebase-merge` / `rebase-apply` が `.git/worktrees/<name>/` 配下に置かれる。"
created: "2026-07-03T13:33:06+09:00"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260703T042604Z-pr-1734.md"
tags: []
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-07-03T13:33:06+09:00" }
---

# worktree 運用の git 状態検出は .git 直書きせず git rev-parse --git-path で解決する

## 概要

worktree では merge/rebase の中断状態を示す `MERGE_HEAD` / `rebase-merge` / `rebase-apply` が `.git/worktrees/<name>/` 配下に置かれる。`.git/MERGE_HEAD` のような直書きパスは worktree では常に不在扱いになり、merge/rebase 中断を silent に取りこぼす。`git rev-parse --git-path <name>` で per-worktree の実パスに解決してから `[ -f ]` / `[ -d ]` で存在判定するのが canonical。

## 詳細

`/rite:resume` のクロスチェックにマージコンフリクト / rebase 中断の検出を追加した際、以下の実装を採用した:

```bash
[ -f "$(git rev-parse --git-path MERGE_HEAD 2>/dev/null)" ] && git_in_merge=yes || git_in_merge=no
if [ -d "$(git rev-parse --git-path rebase-merge 2>/dev/null)" ] || [ -d "$(git rev-parse --git-path rebase-apply 2>/dev/null)" ]; then
  git_in_rebase=yes
else
  git_in_rebase=no
fi
```

code-quality / error-handling reviewer が worktree ルート・サブディレクトリの双方から実機検証し、いずれも per-worktree パス (`.../.git/worktrees/<name>/MERGE_HEAD`) を返すことを確認した。multi_session (worktree) 運用でも正しい作業ツリーに対して判定できることが本パターンの要点。git repo 外 / 非 git 環境では `git rev-parse --git-path` が空文字・exit 128 を返し `[ -f "" ]` が false → 安全側の「非検出」に倒れる。

関連する 2 つの補助知見:

- **conflict マーカーの網羅性**: `git status --porcelain` の unmerged status code は git porcelain v1 で 7 種 (`DD` / `AU` / `UD` / `UA` / `DU` / `AA` / `UU`)。検出 grep (`^(DD|AU|UD|UA|DU|AA|UU) `) と、状況提示に使う判定テーブルの列挙集合を必ず一致させる (drift すると検出漏れ or 表示不一致)。`cut -c4-` はファイルパス抽出として正しい (porcelain v1 は `XY<space>PATH` の先頭 3 文字固定 + 4 文字目以降がパス、unmerged は rename 矢印記法を使わないためオフセットズレなし)。
- **`[ -f ... ] && x=yes || x=no` イディオムの安全性**: 右辺が変数代入で常に exit 0 のため、`A && B || C` の古典的落とし穴 (B 失敗で C も走る) は発現しない。前段 `[ -f ]` が false のときのみ `no` に倒れる。複数条件の OR 判定 (rebase-merge OR rebase-apply) では if/else を使うのが妥当。

## 関連ページ

- [separate_branch 戦略は git worktree で dev ブランチ不動を実現する](./worktree-based-separate-branch-write.md)

## ソース

- [PR #1734 review results](../../raw/reviews/20260703T042604Z-pr-1734.md)
