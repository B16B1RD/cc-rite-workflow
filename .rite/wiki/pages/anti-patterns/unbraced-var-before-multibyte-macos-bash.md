---
# Domain knowledge only; rite workflow candidates stay in raw.
type: "anti-patterns"
title: "多バイト文字の直前に波括弧なしの変数展開を置くと macOS の bash で変数名に取り込まれる"
domain: "anti-patterns"
description: "macOS の bash は UTF-8 の先頭バイトを英数字として扱うため、`$var（` のように多バイト文字が直後に来る展開は変数名を伸ばして空展開になり、化けたバイトが残る。Linux では再現しないので、波括弧で閉じる規約と静的検査で防ぐ。"
created: "2026-10-15T02:42:28Z"
generated: { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-10-15T02:42:28Z" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20261015T005949Z-pr-3903.md"
  - type: "fixes"
    resource: "raw/fixes/20261015T011237Z-pr-3903.md"
tags: ["bash", "macos", "multibyte", "portability", "ci"]
confidence: high
---

# 多バイト文字の直前に波括弧なしの変数展開を置くと macOS の bash で変数名に取り込まれる

## 概要

macOS の bash は UTF-8 の先頭バイトを英数字として扱うため、`$var（` のように多バイト文字が直後に来る展開は変数名を伸ばして空展開になり、化けたバイトが残る。Linux では再現しないので、波括弧で閉じる規約と静的検査で防ぐ。

## 詳細

全角括弧のような多バイト文字を、波括弧なしの変数展開の直後に置くと、macOS の bash は locale の文字分類で先頭バイトを変数名の一部と読む。存在しない変数名になるので展開は空になり、残りのバイトだけが出力に残る。Linux（glibc）の bash は同じ入力を正しく区切るため、ローカルのテストは通り、macOS の CI だけが落ちる。

- 書き方: 多バイト文字に接する展開は常に `${var}` で閉じる。
- 検出: `LC_ALL=C grep '\$[A-Za-z_][A-Za-z0-9_]*[^ -~]'` のように、波括弧なしの変数名の直後に非 ASCII バイトが来る形をバイト単位で探す。LC_ALL=C にしないと、grep 自身が文字単位で読んで一致しない。
- 走査範囲: シェルスクリプトだけを走査する検査は、Markdown に埋め込まれた bash を見ない。手順書の bash を実行するなら、抜き出したブロックにも同じ検査を当てる。
- 違反例を検査の対照に書くときは、多バイト文字を printf のバイトエスケープ（`\xef\xbc\x88` など）で実行時に作る。ソースにリテラルで書くと、同じ規約を全体で走査する検査がその行を違反として拾う（[否定アサーションには positive control を添える](../patterns/negative-assertion-positive-control.md)）。

## 関連ページ

- [cross-platform bash コマンドは fallback chain で portable 化する](../patterns/bash-portable-command-fallback.md)
- [否定アサーションには positive control を添える — `|| true` は唯一の crash signal を消す](../patterns/negative-assertion-positive-control.md)

## ソース

- [多バイト文字の直前の展開が macOS で化けたレビュー結果](../../raw/reviews/20261015T005949Z-pr-3903.md)
- [展開を波括弧で閉じて静的に固定した修正結果](../../raw/fixes/20261015T011237Z-pr-3903.md)
