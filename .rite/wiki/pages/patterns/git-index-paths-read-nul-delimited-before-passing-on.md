---
type: "patterns"
title: "git の index から読んだ path を別のコマンドへ渡すときは -z の NUL 区切りで読む"
domain: "patterns"
description: "git の行出力は引用符・バックスラッシュ・制御文字を含む path を C 形式で引用して出すため、行単位で読んだ値を後続コマンドへ渡すと実在しない path を指す。core.quotePath=false が外すのは非 ASCII の引用だけなので、引用を外す処理を書くより -z で引用を経由させない。"
created: "2026-09-30T09:18:44Z"
generated: { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-30T09:18:44Z" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20260930T080508Z-pr-3523.md"
  - type: "fixes"
    resource: "raw/fixes/20260930T081802Z-pr-3523.md"
tags: ["git", "quoting", "shell", "path"]
confidence: high
---

# git の index から読んだ path を別のコマンドへ渡すときは -z の NUL 区切りで読む

## 概要

git の行出力は引用符・バックスラッシュ・制御文字を含む path を C 形式で引用して出すため、行単位で読んだ値を後続コマンドへ渡すと実在しない path を指す。core.quotePath=false が外すのは非 ASCII の引用だけなので、引用を外す処理を書くより -z で引用を経由させない。

## 詳細

### 起きること

`git ls-files -s` のような一覧を行単位で読み、取り出した path を `git update-index` や `git rm` に渡す処理は、普通のファイル名では正しく動く。path に `"`・`\`・制御文字が入ると、git はその path を二重引用符で囲み、中身をエスケープして出力する。読み取った側はその引用付きの文字列をそのまま path として渡すので、後続コマンドは別の（存在しない）path を操作する。

`core.quotePath=false` を付けても直らない。この設定が外すのは非 ASCII 文字の 8 進エスケープだけで、引用符やバックスラッシュを含む path の引用は残る。

### 書き方

- 一覧は `-z` を付けて NUL 区切りで出させ、`while IFS= read -r -d ''` で読む。NUL 区切りの出力は引用されない
- 受け取る側のコマンドにも NUL 区切りの入力口があればそれを使う（`xargs -0`、`--stdin -z` など）
- 行出力の引用を自前で外す処理は書かない。エスケープの規則を再実装することになり、`-z` より長く、漏れやすい

### 確かめ方

引用符を含むファイル名を fixture に 1 つ置き、処理後にその path が意図どおり操作されたことを検査する。行読み取りへ戻す変異でこのテストが落ちることを確かめておくと、あとで `-z` が外れたときに気付ける。

## 関連ページ

- [pathspec 不一致の git diff --quiet は exit 0 を返し「差分なし」ガードを無効化する](../anti-patterns/pathspec-miss-exit-zero-defeats-diff-guard.md)
- [git update-index --force-remove は対象が無くても成功を返す — 破壊的な次の手の前に index を読み直す](../anti-patterns/git-update-index-force-remove-succeeds-when-entry-absent.md)

## ソース

- [行単位の読み取りで引用付き path が渡ると指摘したレビュー結果](../../raw/reviews/20260930T080508Z-pr-3523.md)
- [NUL 区切りの読み取りへ替えた fix 結果](../../raw/fixes/20260930T081802Z-pr-3523.md)
