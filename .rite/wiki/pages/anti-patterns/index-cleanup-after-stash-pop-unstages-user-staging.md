---
type: "anti-patterns"
title: "失敗経路の後始末で stash pop の後に index を reset すると、ユーザーが staged にしていた変更まで外れる"
domain: "anti-patterns"
description: "git stash で作業を退避してから別ブランチを操作する処理では、失敗時に index を掃除する reset を stash pop の後に置くと、stash pop が index へ戻したユーザー自身の staged エントリまで警告なしに unstage される。reset は持ち帰ったエントリだけが index にある stash pop 前に行い、無関係な staged ファイルを置いた fixture でその順序を固定する。"
created: "2026-09-15T11:02:40Z"
generated: { by: "rite-wiki-ingest/claude-opus-5", at: "2026-09-15T11:02:40Z" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20260915T104705Z-pr-2858.md"
  - type: "fixes"
    resource: "raw/fixes/20260915T105433Z-pr-2858.md"
tags: []
confidence: high
---

# 失敗経路の後始末で stash pop の後に index を reset すると、ユーザーが staged にしていた変更まで外れる

## 概要

git stash で作業を退避してから別ブランチを操作する処理では、失敗時に index を掃除する reset を stash pop の後に置くと、stash pop が index へ戻したユーザー自身の staged エントリまで警告なしに unstage される。reset は持ち帰ったエントリだけが index にある stash pop 前に行い、無関係な staged ファイルを置いた fixture でその順序を固定する。

## 詳細

### 起きること

別ブランチで `git add` した状態から元のブランチへ checkout で戻ると、その index エントリが元のブランチへ持ち込まれる。これを掃除するために `git reset -q -- <dir>` を置くこと自体は正しい。問題は置き場所で、cleanup が次の順になっていると壊れる。

1. 元のブランチへ checkout で戻る
2. `git stash pop` で退避していた作業を戻す
3. `git reset -q -- <dir>` で持ち帰ったエントリを外す

`git stash pop` は staged だったエントリを index にも戻す（新規ファイルを `git add` → `stash push -u` → `stash pop` すると、`diff --cached` にそのファイルが残る）。そのため手順 3 の reset は、持ち帰ったエントリとユーザーが同じディレクトリで staged にしていたエントリを区別できない。ファイルの内容は untracked として残るので、失われるのは staging の状態だけである。それでも「無関係な未 commit 作業を保全する」という約束には反し、利用者は気付けない。

### 直し方

reset を stash pop の**前**に移す。checkout で戻った直後の index にあるのは持ち帰ったエントリだけなので、reset がユーザーの staging に触れない。手動復旧の手順を「1) checkout 2) reset 3) stash pop」の順で案内している場合は、自動経路もその順にそろえる。自動経路と手動手順で順序が逆になっていること自体が、この欠陥を見つける手がかりになる。

pathspec を処理対象のファイル一覧だけに絞る方法もある。ただし一覧を手動復旧コマンドへ引用付きで埋め込む必要が生じ、自動経路と手動経路の形がずれる。順序の入れ替えのほうが構造を増やさずに済む。

### テストで固定する

clean な fixture（無関係な staged ファイルが無い状態）では、この欠陥も「reset の pathspec を外して index 全体を reset する」退行も green のまま生き残る。検出するには、フックを実行する前に無関係なファイルを `git add` しておき、実行後に `git diff --cached --name-only` がそのファイルだけを返すことを assert する。

順序を直した後は、reset の時点で index に持ち帰ったエントリしか無いので、pathspec を外す変異は観測できる害を持たなくなる。このとき上の fixture が固定しているのは pathspec ではなく「reset が stash pop より前にあること」である。後の review でこの変異が生き残っても、固定漏れとして再指摘しなくてよい。

失敗後の分岐（unstage に失敗した場合など）で「後続の復元処理を続ける」ことも、その分岐専用のケースで後続の INFO 行などを assert しないと、途中で return する変異が生き残る。

### レビュー前の自己検証

失敗経路の後始末で index を触る修正を入れるときは、stash pop との前後関係を commit 前に確認する。無関係な staged ファイルを置いた fixture で一度実行するだけで分かり、review で指摘されて修正 cycle を増やすより安い。重大度が MEDIUM と判定された指摘は、自分の変更が持ち込んだ順序の欠陥でも同じ変更の中では直されず、別の課題として後回しになることがある。

## 関連ページ

- [separate_branch 戦略は git worktree で dev ブランチ不動を実現する](../patterns/worktree-based-separate-branch-write.md)
- [テスト fixture の変異は各不変量・guard を単独で kill する配置で設計する](../heuristics/fixture-mutation-isolates-invariants.md)

## ソース

- [レビュー結果](../../raw/reviews/20260915T104705Z-pr-2858.md)
- [fix 結果](../../raw/fixes/20260915T105433Z-pr-2858.md)
