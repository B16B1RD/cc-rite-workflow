---
type: "anti-patterns"
title: "リダイレクトはコマンド実行より先に評価されるため、生成失敗が出力先を truncate する"
domain: "anti-patterns"
description: "シェルは `cmd > file` の file を cmd より先に開いて truncate する。生成が失敗しても既存ファイルは既に空になっており、消費側が即死する前にデータが消える。"
created: "2026-09-06T16:10:23Z"
generated: { by: "rite-wiki-ingest/claude-opus-5[1m]", at: "2026-09-06T16:10:23Z" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20260906T142344Z-pr-2582.md"
  - type: "fixes"
    resource: "raw/fixes/20260906T142858Z-pr-2582.md"
tags: ["bash", "redirect", "truncate", "data-loss", "fail-loud"]
confidence: high
---

# リダイレクトはコマンド実行より先に評価されるため、生成失敗が出力先を truncate する

## 概要

シェルは `cmd > file` を実行するとき、`cmd` を起動する前に `file` を開いて長さ 0 に切り詰める。したがって生成が失敗しても、既存ファイルは既に空になっている。呼び出し側が「失敗したら何も書かれない」と読むと、実際には state ファイルが黙って消える。

## 詳細

### 見え方

失敗は即座には現れない。次にそのファイルを読む側が空を受け取り、そこにガードが無ければ壊れた state のまま処理が進む。読み取り側にガードがある兄弟経路と非対称なら、それは片側だけが後から強化された痕跡である。一度壊れた state は、読み取り側が無ガードだと自己回復しない。

### 直し方

同じファイルを扱う別の書き手が一時ファイルと `mv` で書いているなら、その手順に揃えるのが最小の修正になる。

1. 生成先を `mktemp` の一時ファイルにする
2. 生成コマンドの exit status を検査する（成功述語には非空性も入れる）
3. 成功したときだけ `mv` で本来の場所へ置く

### 成功 marker も同じ穴を持つ

marker の値を command substitution から取るときは、その substitution が失敗した場合の見え方を確認する。空の結果からフォーマットすると `0` が入り、壊れた状態のまま成功を名乗る出力になる。

## 関連ページ

- [成功述語は exit status と非空性の両方で書く](../patterns/cwd-corruption-success-check-exit-code-and-nonempty.md)
- [HEREDOC は空展開でも改行を書くため、直後の空ファイル検査は常に通過する](./heredoc-empty-expansion-defeats-empty-file-guard.md)

## ソース

- [レビュー結果](../../raw/reviews/20260906T142344Z-pr-2582.md)
- [fix 結果](../../raw/fixes/20260906T142858Z-pr-2582.md)
