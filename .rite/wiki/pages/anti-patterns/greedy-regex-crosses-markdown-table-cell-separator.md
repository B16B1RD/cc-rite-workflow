---
type: "anti-patterns"
title: "markdown テーブル行に対する greedy `.*` はセル境界を跨いでマッチし、右辺の空検出を dead 化する"
domain: "anti-patterns"
description: "テーブルのセル内容を検査する regex に greedy `.*` を使うと、`|` を跨いで隣のセルまでマッチする。「アンカーの右辺が空なら降格」のような検出が構造的に dead になり、常に false-pass する。アンカー自身の最初の区切りに束縛する negative-lookahead 形へ直し、正例・負例の両方で実測する。あわせて raw パイプを含む値はセル内で表記代替する規約が要る。"
created: "2026-07-27T10:57:51+09:00"
updated: "2026-07-27T10:57:51+09:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260726T150008Z-pr-2030-cycle5.md"
  - type: "reviews"
    ref: "raw/reviews/20260726T160331Z-pr-2030.md"
  - type: "fixes"
    ref: "raw/fixes/20260726T150940Z-pr-2030-cycle5.md"
tags: []
confidence: high
---

# markdown テーブル行に対する greedy `.*` はセル境界を跨いでマッチし、右辺の空検出を dead 化する

## 概要

reviewer が出力する markdown テーブルの `内容` 列からアンカー（`Verification: repro <cmd> => <observed>`）を抽出する検出 regex に greedy `.*` を使うと、セル区切りの `|` を跨いで隣のセル（`推奨対応` 列）までマッチする。結果、「アンカーの右辺が空なら降格する」という判定が構造的に dead になり、右辺が空でも隣のセルの内容を拾って**常に false-pass** する。

## 詳細

### 何が起きるか

```
| HIGH | current-pr | file.sh:10 | ... Verification: repro cmd => | 修正方法をここに書く |
                                                             ^^^^^^ 右辺が空
```

`Verification:\s*repro\s+.*=>\s*(.+)` のような regex は、`.*` が `=>` の手前で止まらず行末近くまで伸び、最後の `=>` を基準にマッチしてしまう。あるいは `(.+)` が次のセルの「修正方法をここに書く」を捕捉する。どちらの場合も「右辺が空」を検出できない。

### 処方: アンカー自身の最初の区切りに束縛する

`.*` を negative-lookahead 付きの形に置き換え、アンカー内の**最初の** `=>` にマッチを束縛する。PR #2030 cycle 5 では正例・負例あわせて 6 ケースで実測して確定させた。

セル境界そのものを排除する形（`[^|]*`）も有効だが、その場合は raw パイプを含む値がアンカー内に書けなくなるため、下記の表記代替規約が必要になる。

### raw パイプは表記代替する

セル内に raw `|` を書くとテーブルの列構造自体が壊れ、アンカーも機械抽出できない。canonical な再現イディオム（`printf ... | jq`）はまさにこれに該当するため、**表記代替（`¦` = U+00A6 など）を規約として authoring 側 SoT に書く**必要がある。

この制約を detection 側にだけ書くと、authoring 側は知らずに raw パイプを書き、no-match で silent 降格される（関連ページの SoT 双方向同期を参照）。

### 検出 regex を変えたら正例・負例で実測する

markdown テーブルに対する regex は、テストデータを 1 行だけ用意して「マッチした / しなかった」を見ても不十分。以下の 4 象限を用意する:

1. アンカーあり + 右辺あり → マッチすべき
2. アンカーあり + 右辺空 → マッチしないべき（これが dead 化していた）
3. アンカーあり + 右辺空 + **隣のセルに内容あり** → マッチしないべき（セル跨ぎの検出）
4. アンカーなし → マッチしないべき

## 関連ページ

- [awk negative-class + greedy + literal の組み合わせは backtracking で literal を silent miss する](./awk-regex-backtracking-trap-with-greedy-literal.md)
- [Markdown table 内に HTML コメントを挿入すると GFM table boundary が破壊される](./html-comment-breaks-gfm-table-boundary.md)
- [SoT 同期は detection 側と authoring 側の双方向に書く — 片側だけでは機構が silent に空振りする](../heuristics/sot-bidirectional-detection-and-authoring-sync.md)
- [機械的制裁を伴う規約は「何をすると」「何がどこまで」落ちるかを書く — 予約グリフ・予約文字列も導入と同時に文書化する](../heuristics/mechanical-sanction-rule-documents-blast-radius.md)

## ソース

- [PR #2030 review results (cycle 5)](../../raw/reviews/20260726T150008Z-pr-2030-cycle5.md)
