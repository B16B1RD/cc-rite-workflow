---
type: "anti-patterns"
title: "大文字小文字だけが違う fixture ファイル名は macOS で同じファイルになり、後から書いた fixture が前のものを上書きする"
domain: "anti-patterns"
description: "macOS の標準ファイルシステムは大文字小文字を区別しないため、`~1a2b.json` と `~1A2B.json` のように大文字小文字だけが違う fixture は 1 つのファイルになる。Linux では緑のテストが macOS CI だけで赤になる。"
created: "2026-09-14T23:10:01Z"
generated: { by: "rite-wiki-ingest/claude-opus-5", at: "2026-09-14T23:10:01Z" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20260914T230532Z-pr-2826.md"
tags: []
confidence: high
---

# 大文字小文字だけが違う fixture ファイル名は macOS で同じファイルになり、後から書いた fixture が前のものを上書きする

## 概要

macOS の標準ファイルシステムは大文字小文字を区別しないため、`~1a2b.json` と `~1A2B.json` のように大文字小文字だけが違う fixture は 1 つのファイルになる。Linux では緑のテストが macOS CI だけで赤になる。

## 詳細

正例（受理される小文字の名前）と負例（拒否されるべき大文字の名前）を同じディレクトリに並べると、Linux の ext4 では別ファイルとして共存するが、macOS では後から書いた負例が正例の中身を上書きする。結果として、出力件数が 1 件減り、正例の key を確かめる assert と、負例が拒否されることを確かめる assert の両方が同時に落ちる。ローカルの Linux 環境では再現しないため、原因の特定には CI ログの失敗 assert 名と期待件数のずれを読むのが近道になる。

対処は次のとおり。

- 負例の名前は、正例と大文字小文字以外でも異なる文字列にする（例: 正例 `~1a2b.json` に対して負例 `~ABCD.json`）
- ファイルを作らず文字列として渡すだけの負例（引数のトークン検査など）は、この衝突の対象外なので大文字小文字違いのままでよい
- ファイル名の並び順で結果を連結して比較する assert は、`LC_ALL=C sort` を通して順序に依存しない形にする。名前を変えると glob の並び順も変わるため

## 関連ページ

- [git のパス出力を assert するテストは fixture の mktemp 値を `pwd -P` で実体パスへ正規化する](../patterns/normalize-tmpdir-symlink-in-path-asserting-tests.md)
- [検出範囲を広げる修正は「広がった」と「広がりすぎていない」を対で pin する](../patterns/detector-widening-pins-both-bounds.md)

## ソース

- [macOS CI だけで落ちた fixture の名前衝突を直した再レビュー結果](../../raw/reviews/20260914T230532Z-pr-2826.md)
