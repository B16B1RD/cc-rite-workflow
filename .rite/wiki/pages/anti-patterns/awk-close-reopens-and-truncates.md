---
type: "anti-patterns"
title: "awk の close() は追記のつもりだったリダイレクトを再 truncate する"
domain: "anti-patterns"
description: "`> file` は初回オープンで truncate、以降は追記だが、close() を挟むと次の `> file` が再オープン＝再 truncate する。END で二重に書いていた検出が、この 1 行で片方消える。"
created: "2026-09-04T13:54:13Z"
generated: { by: "rite-wiki-ingest/grok-4.6", at: "2026-09-04T13:54:13Z" }
sources:
  - type: "fixes"
    resource: "raw/fixes/20260904T092650Z-pr-2549.md"
tags: [awk, tempfile, truncate]
confidence: high
promote: rite-plugin
---

# awk の close() は追記のつもりだったリダイレクトを再 truncate する

## 概要

`> file` は初回オープンで truncate、以降は追記だが、close() を挟むと次の `> file` が再オープン＝再 truncate する。END で二重に書いていた検出が、この 1 行で片方消える。

## 詳細

awk が同じ出力ファイルへ `> file` で書くとき、そのファイルはスクリプト内で一度だけオープンされ、以降の `> file` は追記になる。`close(file)` を挟むと次の `> file` は再オープンであり、リダイレクトの意味は再び truncate である。

観測された事例では、END ブロックが検出結果を同じファイルへ二度書いて変異（`exit` の削除）を二重に捉えていた。その間に `close()` を置いたため、二度目の書き込みがファイルを空にしてから書き直し、片方の検出が消えた。テストは残っていたが、守るべき二重検出は 1 行で無効化されていた。

同じファイルへ段階的に書く awk では `close()` を挟まない。フラッシュや次ファイルへの切り替えが必要なら、出力先を分けるか、配列に溜めて END で一度だけ書く。

## 関連ページ

- [追加した pin は、その pin が守ると主張する変異を 1 回当てて赤くなるまで完成していない](../patterns/mutation-prove-new-pin.md)
- [Mutation testing で test の真正性 (dead code 検出 + identification power) を empirical 検証する](../patterns/mutation-testing-test-fidelity.md)

## ソース

- [fix 結果](../../raw/fixes/20260904T092650Z-pr-2549.md)
