---
type: "heuristics"
title: "セッション worktree + sandbox 環境の 3 つの罠: cwd 相対 write-allowlist・`.rite-plugin-root` のブランチ相違・`--show-toplevel` の誤解決"
domain: "heuristics"
promote: rite-plugin
description: "`multi_session` によるセッション worktree 運用と sandbox 環境を組み合わせたとき、cwd の位置とファイルの実体が乖離する 3 種類の罠が観測された（罠 1・2 は sandbox 対応 PR の作業中に、罠 3 はその後続 PR のレビューで実際に踏んだ）。"
created: "2026-07-18T23:38:52Z"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260718T194343Z-pr-1902.md"
  - type: "reviews"
    resource: "raw/reviews/20260719T011000Z-pr-1908.md"
  - type: "fixes"
    resource: "raw/fixes/20260720T070808Z-pr-1925.md"
tags: ["multi-session", "worktree", "sandbox", "plugin-root", "write-allowlist", "show-toplevel"]
confidence: medium
generated: { by: "rite-wiki-ingest/unknown", at: "2026-07-20T07:50:27Z" }
---

# セッション worktree + sandbox 環境の 3 つの罠: cwd 相対 write-allowlist・`.rite-plugin-root` のブランチ相違・`--show-toplevel` の誤解決

## 概要

`multi_session` によるセッション worktree 運用と sandbox 環境を組み合わせたとき、cwd の位置とファイルの実体が乖離する 3 種類の罠が観測された（罠 1・2 は sandbox 対応 PR の作業中に、罠 3 はその後続 PR のレビューで実際に踏んだ）。

1. worktree cwd から main checkout 配下（例: `.rite/review-results/`）への書き込みは、sandbox の write-allowlist が cwd 相対の `.` として解決されるためブロックされる。
2. `.rite-plugin-root` をセッション worktree へコピーする際、コピー元（main checkout）のブランチが worktree のブランチと異なる状態でコピーすると、コピーされた値が古い（未修正の）`plugins/rite` を指してしまう。
3. `git rev-parse --show-toplevel` は worktree cwd から実行すると main checkout root ではなくその worktree 自身の toplevel を返すため、main checkout root を得る目的には使えない。

## 詳細

### 罠 1: cwd 相対 write-allowlist によるブロック

sandbox の書き込み許可リストは cwd（`.`）を基準に解決される。セッション worktree（`.rite/worktrees/issue-{N}` 配下）から main checkout 配下のパス（例: main checkout の `.rite/review-results/{pr}.json`）へ絶対パス・相対パスいずれで書き込もうとしても、cwd が worktree 側にある限り「cwd 相対の `.`」には含まれず拒否される。既知の sandbox write 拒否 Issue と同種の事象。

**対処**: state 書き込み先は `state-path-resolve.sh` 等の共有 root 解決 helper で解決し、cwd 依存を明示的に解消してから書き込む。単純に相対パスを組み立てるだけでは worktree/main checkout どちらの cwd から呼ばれても正しく解決されない。

**正典文書化**: 本制約は helper 側では構造回避できない（sandbox の write-allowlist はプラグイン外の環境設定）ため、`git-worktree-patterns.md` に正典 subsection（症状/原因/対処。恒久対処 = sandbox write 許可リストへ main checkout root の**絶対パス**を追加、都度対処 = 拒否された当該コマンドのみ `dangerouslyDisableSandbox: true` で再実行・確認不要）として文書化され、open 2.3-W / batch-run の run-queue 書込に薄いポインタが置かれた。この「正典 subsection + 入口 skill への薄いポインタ」型（SSH host alias 対応と同型）は、アンカー整合・文体整合・配置タイミングの全レビュー観点で一発 mergeable になった実績があり、環境制約の文書化に有効。付随知見 2 点: (a) 日本語見出しの GitHub アンカーは slugger 算出値とポインタ埋め込み値の byte 一致を事前確認するとレビュー往復を防げる。(b) 密な段落末尾に追記した actionable 指示は独立 blockquote より LLM 実行時の発火確度（salience）が下がる — ポインタは blockquote 等で視覚的に分離するのが望ましい。

### 罠 2: `.rite-plugin-root` のブランチ相違による自己参照

`.rite-plugin-root` はセッション worktree セットアップ時に main checkout からコピーされる。このコピー操作の時点で main checkout 側のブランチが（同セッションの他の作業などで）worktree のブランチと異なる状態になっていると、コピーされる `.rite-plugin-root` の中身（解決済み `plugins/rite` の絶対パス）が、修正前の古いコードを指す plugin_root になり得る。結果として、worktree 内で実行するスキル・hook が意図せず未修正の旧 `plugins/rite` を参照してしまう。

**対処**: `.rite-plugin-root` を参照する前に、その値が指す `plugins/rite` が現在作業中のブランチの内容と一致しているかを疑う。特に、コピー元 main checkout のブランチを切り替える操作を挟んだ直後は要注意。

### 罠 3: `git rev-parse --show-toplevel` は worktree cwd からだと自身の toplevel を返す

`git rev-parse --show-toplevel` は「リポジトリのルート」を返すコマンドとして直感的に見えるが、worktree cwd から実行すると**その worktree 自身の toplevel** を返し、main checkout root は返さない。multi_session 環境で「main checkout root の絶対パスを取得したい」場面（sandbox write 許可リスト案内で `{repo_root}` を求める等）でこのコマンドを使うと、worktree cwd から呼ばれた場合に誤った値（worktree 自身のパス）を返してしまう。

コードベース自身の `lib/worktree-git.sh` は、この理由から `--show-toplevel` を意図的に避けている（既存コードに先例があるにもかかわらず、新規ドキュメント記述時に見落としやすい）。2 名の reviewer が実機検証（worktree cwd で実際にコマンドを実行）により独立に検出した。

**対処**: main checkout root を得たい場合は `--show-toplevel` ではなく `state-path-resolve.sh` 等の canonical resolver（linked worktree を考慮して main checkout root を正しく解決する）に委譲する。これは罠 1 の「対処」で述べた `state-path-resolve.sh` 等の共有 root 解決 helper の使用を、より具体的な NG コマンド名で補強する知見である。

## 関連ページ

- [worktree 運用の git 状態検出は .git 直書きせず git rev-parse --git-path で解決する](../patterns/worktree-aware-git-state-detection.md)

## ソース

- [レビュー結果](../../raw/reviews/20260718T194343Z-pr-1902.md)
- [fix 結果](../../raw/fixes/20260720T070808Z-pr-1925.md)
