---
type: "patterns"
title: "同型テンプレートが N 本ある欄は「本数の literal pin」と「欄とプレースホルダの隣接 pin」の 2 本立てで守る"
domain: "patterns"
description: "同じ報告欄を複数のテンプレートへ横展開したとき、presence-only の grep pin は 1 本でも残っていれば通るため N-1 本からの欠落を検出できない。本数を literal で固定する pin と、欄行の直下にプレースホルダが並ぶことを数える pin の 2 本立てにする。期待値を実測から作ると 0 == 0 の真空パスで通るので、期待値は必ず literal で書く。"
created: "2026-09-07T10:00:00Z"
generated: { by: "rite-wiki-ingest/claude-opus-5[1m]", at: "2026-09-07T10:00:00Z" }
sources:
  - type: "fixes"
    resource: "raw/fixes/20260907T001315Z-pr-2590.md"
tags: []
confidence: high
---

# 同型テンプレートが N 本ある欄は「本数の literal pin」と「欄とプレースホルダの隣接 pin」の 2 本立てで守る

## 概要

同じ報告欄を複数のテンプレートへ横展開したとき、presence-only の grep pin は 1 本でも残っていれば通るため N-1 本からの欠落を検出できない。本数を literal で固定する pin と、欄行の直下にプレースホルダが並ぶことを数える pin の 2 本立てにする。期待値を実測から作ると 0 == 0 の真空パスで通るので、期待値は必ず literal で書く。

## 詳細

### 観測

ユーザーの操作が必要な警告を完了報告へ転記する欄を、3 つの orchestrator skill（欄の総数はそれぞれ 1 本 / 6 本 / 3 本）へ横展開した。契約テストは `assert_grep '^欄名:$'` の presence-only で書かれていたため、6 本のうち 1 本から欄が消えても、3 本のうち 1 本から消えても green のままだった。

さらに、プレースホルダ名は「Placeholder Legend の定義行」「規則を述べる散文」「テンプレート本体」の 3 か所に出現する。`assert_grep '\{placeholder\}'` はテンプレート本体から消えても残り 2 か所で充足するため、欄とプレースホルダの対応そのものが無検査だった。

### 塞ぎ方

2 本立てにする。

1. **本数の pin**: `assert "<label>" "<N>" "$(grep -c '^欄名:$' "$f")"`。ファイルごとに N を literal で書く。
2. **隣接の pin**: `assert "<label>" "<N>" "$(grep -A1 '^欄名:$' "$f" | grep -c '^{placeholder}$')"`。欄行の直後にプレースホルダ行が来る対応を数える。

### 期待値を実測から作らない（真空パス）

隣接 pin を最初に書いたとき、期待値を測定値から作っていた:

```bash
paired=$(grep -A1 '^欄名:$' "$f" | grep -c '^{placeholder}$')
section_count=$(grep -c '^欄名:$' "$f")
assert "..." "$section_count" "$paired"
```

この形は欄が 1 本も無いファイルでも `0 == 0` で通る。「対応している」ことは検査できても「そもそも存在する」ことを検査しないため、欄が全滅した変異を素通しする。期待値を literal（1 / 6 / 3）にすれば、本数 pin と隣接 pin が同じ literal を共有し、真空パスは構造的に消える。

### 検出網は変異で実測してから確定する

pin を足したあと、次の 2 種の変異を実際に作って走らせる。

- **削除変異**: N 本のうち 1 本から欄とプレースホルダを消す。本数 pin と隣接 pin の両方が落ちること。
- **置換変異**: 欄は残しプレースホルダだけ別の行に差し替える。隣接 pin だけが落ちること。

修正前は green、修正後は fail することを確認するまで完了にしない。

### 残る非対称は人手ゲートへ倒す

本数 pin が検出できるのは「削除」だけで、「欄を持たない新しい報告経路が増える」方向は素通りする。この非対称は静的契約の限界なので、`assert` の直上に「経路を増減させたときは期待値も更新する」とコメントで明示し、人手ゲートに委ねる。機構を足して塞ごうとすると、次サイクル以降の審査面が増える割に検出力は上がらない。

## 関連ページ

- [規範文を新設したら、その規範文が支配する範囲すべてに適用し直すか、適用範囲を明示的に狭める](../heuristics/new-normative-clause-must-be-applied-to-its-own-scope.md)
- [散文契約の静的 pin には weakened probe による positive control を課す（見出しラベルで充足する pin を構造的に排除する）](./prose-pin-requires-positive-control.md)
- [pin を足す「前」に mutation を当てると、pin の要否と有効性を分離して判定できる](./mutation-before-pin-separates-necessity-from-efficacy.md)

## ソース

- [fix 結果](../../raw/fixes/20260907T001315Z-pr-2590.md)
