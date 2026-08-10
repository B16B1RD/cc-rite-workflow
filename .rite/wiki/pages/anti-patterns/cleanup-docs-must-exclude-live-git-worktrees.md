---
type: "anti-patterns"
title: "アンインストール/クリーンアップ手順の rm -rf 推奨は git worktree 等の live 状態管理対象を見落としやすい"
domain: "anti-patterns"
promote: rite-plugin
description: "アンインストール手順やクリーンアップ手順のドキュメントで、gitignore 済みディレクトリを「安全に削除してよい」と単純化すると、その配下に git worktree のような live な状態管理対象が含まれるケースを見落とす。"
created: "2026-07-07T22:03:17+00:00"
updated: "2026-07-07T22:03:17+00:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260706T213530Z-pr-1773.md"
  - type: "fixes"
    ref: "raw/fixes/20260706T213921Z-pr-1773.md"
tags: ["docs-safety", "git-worktree", "cleanup-instructions", "destructive-command"]
confidence: high
---

# アンインストール/クリーンアップ手順の rm -rf 推奨は git worktree 等の live 状態管理対象を見落としやすい

## 概要

アンインストール手順やクリーンアップ手順のドキュメントで、gitignore 済みディレクトリを「安全に削除してよい」と単純化すると、その配下に git worktree のような live な状態管理対象が含まれるケースを見落とす。「gitignore されている = 未追跡 = 削除しても無害」という推論は、worktree の administrative metadata や未コミット差分の破壊を考慮しておらず、プロジェクト自身がそれらを慎重に扱っている実装 (例: cleanup skill の `git worktree remove` + dirty-check 手順) と矛盾する危険なコマンド例をドキュメントに書いてしまう。

## 詳細

### 発見経緯

プラグインのアンインストール手順ドキュメント (README の Uninstallation 節) の初稿は、`.rite/` 配下の gitignore 済みディレクトリをまとめて `rm -rf .rite` で削除するよう推奨していた。tech-writer / code-quality の両レビュアーが独立に、この対象範囲に `.rite/wiki-worktree/` (Wiki `separate_branch` 戦略の永続 worktree) と `.rite/worktrees/issue-*` (multi_session 有効時のセッション worktree) が含まれることを検出し、HIGH として指摘した。

問題の核心は、これらのディレクトリが単なる「未追跡ファイル置き場」ではなく **git worktree の administrative metadata の実体** であること。生の `rm -rf` は:

1. worktree のワークツリー自体を破壊するだけでなく、main checkout 側の `.git/worktrees/<name>` 管理領域を dangling 参照として残す (`git worktree prune` なしでは孤立管理領域が蓄積する)
2. worktree 内に未コミットの作業がある場合、それを一切の確認なく完全消失させる

一方、プロジェクト自身の cleanup 実装 (`skills/cleanup/SKILL.md` ステップ 4-W) は、同じ worktree を削除する際に (a) dirty check → 未コミット変更があれば stash を提案、(b) `ExitWorktree`/`git worktree remove` の正規経路、(c) `git worktree prune` によるメタデータ整理、という多段の安全策を踏んでいる。ドキュメントの `rm -rf .rite` はこの安全策を全て迂回するコマンドを、しかもユーザー向けの「気軽に実行してよい」体裁で提示していた。

### 修正内容

1. `.rite/` 配下の内部ディレクトリを独立した行として切り出し、「生の `rm -rf` で削除すると git worktree メタデータが孤立し未コミット差分を失う可能性があり、害あり」と明示
2. 削除手順を 2 段階化: まず `git worktree list` で登録パスを確認 → 該当すれば `git worktree remove <path>` (未コミット変更がないか確認の上) → `git worktree prune` → その後にようやく残りの `.rite/` を `rm -rf .rite` で削除してよい、という順序を明記

### 一般化した教訓

アンインストール手順・クリーンアップ手順・環境リセット手順などの「まとめて削除してよい」的な文書を書く際は:

- 対象ディレクトリ配下に **git worktree、submodule、ロックファイルディレクトリなど「gitignore されているが live な状態を持つ」ものが含まれないか** を、プロジェクト自身の cleanup / teardown 実装 (存在する場合) と照合してから rm -rf コマンドを提示する
- 「gitignore済み」は「安全に一括削除可能」の十分条件ではない。判定基準は「実際に unmanaged な単純ファイルか、それとも別の管理機構 (git worktree 等) の実体か」であるべき
- 該当する場合は、正規の解除手順 (worktree なら `remove` → `prune`) を rm -rf の**前**に踏む 2 段階構成にする

副次的な教訓として、同 PR では config 可変値 (`wiki.branch_name` のデフォルト `wiki`) に依存するコマンド例において、値がデフォルトであることを明記する必要性も指摘された。ハードコードされたコマンド例は、設定変更済み環境のユーザーを誤誘導する。

## 関連ページ

- [Documentation review は対応する実装側 (commands/scripts/templates) の grep verify を必須 step とする](../heuristics/docs-review-implementation-grep-verification.md)
- [separate_branch 戦略は git worktree で dev ブランチ不動を実現する](../patterns/worktree-based-separate-branch-write.md)

## ソース

- [PR #1773 review cycle 1 (rm -rf .rite が live worktree を破壊する HIGH finding を tech-writer/code-quality 両者が独立検出)](../../raw/reviews/20260706T213530Z-pr-1773.md)
- [PR #1773 fix cycle 1 (2段階削除手順への修正: git worktree remove/prune → rm -rf .rite)](../../raw/fixes/20260706T213921Z-pr-1773.md)
