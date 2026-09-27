---
type: "patterns"
title: "fix diff などのファイル集合は取得コマンドごとに rename 検出を揃える"
domain: "patterns"
description: "--name-only は検出した改名の移動先しか出さないため、rename 検出が有効なまま取ったファイル集合からは元パスが落ちる。集合を比べる・積を取る・検証側と照合するなら、すべての取得に --no-renames を揃えて付ける。"
created: "2026-09-25T03:58:00Z"
generated: { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-27T03:08:04Z" }
verified: [{ by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-27T03:08:04Z" }]
sources:
  - type: "reviews"
    resource: "raw/reviews/20260924T202641Z-pr-3060.md"
  - type: "reviews"
    resource: "raw/reviews/20260927T030248Z-pr-3194.md"
tags: ["git", "rename", "diff"]
confidence: medium
---

# fix diff などのファイル集合は取得コマンドごとに rename 検出を揃える

## 概要

`git diff --name-only` / `git log --name-only` は、検出した改名について移動先のパスしか出さない。rename 検出が有効なままファイル集合を取ると元パスが落ち、集合の積や検証側との照合で食い違う。手順書のコマンドと検証する helper のどちらも、同じオプション（`--no-renames`）で列挙させる。

## 詳細

### 起きたこと

- 手順書のパス列挙コマンドが rename 検出の既定に従い、`--no-renames` で列挙する検証側と食い違った
- 差分スコープの一覧で、fix commit で改名したファイルの元パスが落ち、reviewer に新パスが新規ファイルとして渡った

### 対処

- 集合を取るすべてのコマンド（範囲の `git diff`、commit ごとの `git log`、merge の `git show --remerge-diff`）に `--no-renames` を付け、改名は元パスと新パスの 2 つとして数える
- 手順書が処方するコマンドは、検証する helper と同じオプションで書く

### merge 経路の `--no-renames` をテストで固定するときの fixture

- 改名の fixture が fix commit しか持たないと、merge 経路（`git show --remerge-diff`）を一度も通らず、そこから `--no-renames` を外しても suite は green のまま残る
- `git show --remerge-diff` は、競合したファイル自体を merge commit で改名しても改名として対にしない（削除と追加の 2 件として出る）。このため競合ファイルの改名では rename 検出の有無で出力が変わらず、フラグを外す変異を検出できない
- 検出力のある fixture は、競合を解消する同じ merge commit で、競合していない別ファイルを改名する。フラグを外すと元パスが一覧から落ち、テストが赤くなる
- 変異を一時コピーに当てて当該 assert だけが落ちることを確かめてから pin を完成とする

## 関連ページ

- [merge で解消した競合のファイルは git show --remerge-diff で求める（diff-tree --cc は clean merge も返す）](./merge-conflict-resolution-via-remerge-diff.md)
- [検出 grep と mutation (Edit old_string) は同一の文字列 strictness で実装する](./detection-mutation-strictness-symmetry.md)
- [追加した pin は、その pin が守ると主張する変異を 1 回当てて赤くなるまで完成していない](./mutation-prove-new-pin.md)

## ソース

- [レビュー結果](../../raw/reviews/20260924T202641Z-pr-3060.md)
- [レビュー結果](../../raw/reviews/20260927T030248Z-pr-3194.md)
