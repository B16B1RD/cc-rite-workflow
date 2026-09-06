---
type: "anti-patterns"
title: "HEREDOC は空展開でも改行を書くため、直後の空ファイル検査は常に通過する"
domain: "anti-patterns"
description: "`cat > f <<EOF` は展開結果が空でも改行 1 バイトを書き出す。その直後に置いた `[ ! -s \"$f\" ]` は決して真にならず、fail-loud のつもりのガードが到達しない検査として残る。"
created: "2026-09-06T16:10:23Z"
generated: { by: "rite-wiki-ingest/claude-opus-5[1m]", at: "2026-09-06T16:10:23Z" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20260906T141001Z-pr-2582.md"
  - type: "fixes"
    resource: "raw/fixes/20260906T141557Z-pr-2582.md"
tags: ["bash", "heredoc", "dead-guard", "fail-loud"]
confidence: high
---

# HEREDOC は空展開でも改行を書くため、直後の空ファイル検査は常に通過する

## 概要

`cat > "$f" <<EOF` は本文の展開結果が空でも改行 1 バイトを書き出す。その直後に置いた `[ ! -s "$f" ]` は決して真にならない。空ファイルを検出して止めるつもりのガードが、構造的に到達しない検査として残る。

## 詳細

### 何が起きるか

ガードは「書けていない」を捕まえるために足される。しかし HEREDOC 経路ではファイルサイズが 0 になる入力が存在しないため、この検査は永久に偽である。実際に塞ぐべきは、その値を作った側 — 生成コマンドの exit status であり、リダイレクト先を無言で truncate してから成功が返る経路のほうである。

### 直し方は削除

到達しない検査を残したまま別の検査を足すと、面積だけが増えて読み手の注意が分散する。前の cycle で自分が足した死んだ検査は、置き換えではなく削除で返す。実際に塞ぐべき箇所が既存コード側にあるなら、それは別の指摘として立てる。

### 足す前に問うこと

ガードを足す前に「この検査が偽になる入力は実在するか」を 1 度問う。実在しないなら、その検査は fail-loud ではなく飾りである。

## 関連ページ

- [リダイレクトはコマンド実行より先に評価されるため、生成失敗が出力先を truncate する](./redirect-truncates-target-before-generator-failure.md)
- [ガードを守られる側のスコープ内に置くと発火しない](./gate-placed-inside-guarded-scope.md)

## ソース

- [レビュー結果](../../raw/reviews/20260906T141001Z-pr-2582.md)
- [fix 結果](../../raw/fixes/20260906T141557Z-pr-2582.md)
