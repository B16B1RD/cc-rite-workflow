---
type: "anti-patterns"
title: "番号・識別子の grep に語境界を付けないと短い番号が長い番号の prefix として衝突する"
domain: "anti-patterns"
description: "commit を番号で解決する手順に `git log --grep \"refs #N\"` のような**語境界を持たない部分一致**を書くと、短い番号が長い番号の prefix として一致する（`関連する設計記録` が `関連する設計記録` に一致する）。"
created: "2026-07-30T15:40:55Z"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260730T085655Z-pr-2056.md"
  - type: "fixes"
    resource: "raw/fixes/20260730T090005Z-pr-2056.md"
  - type: "reviews"
    resource: "raw/reviews/20260730T101445Z-pr-2056.md"
  - type: "fixes"
    resource: "raw/fixes/20260730T101445Z-pr-2056.md"
tags: ["grep", "regex", "word-boundary", "identifier", "verification"]
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-07-30T15:40:55Z" }
---

# 番号・識別子の grep に語境界を付けないと短い番号が長い番号の prefix として衝突する

## 概要

commit を番号で解決する手順に `git log --grep "refs #N"` のような**語境界を持たない部分一致**を書くと、短い番号が長い番号の prefix として一致する（`refs #204` が `refs #2047` に一致する）。「候補 0 件 / 複数件なら UNVERIFIED」という guard を置いていても、prefix 衝突は**ちょうど 1 件**を作るため guard を素通りし、誤った commit を掴んだまま突合へ進んで偽 `VERIFIED` / 偽 `CONTRADICTED` が無言で成立する。

## 詳細

### 逆説的な構造

複数 commit を持つ Issue は必ず「複数件」で guard に落ちる。つまり**判定を出せるのは「ちょうど 1 件」のときだけ**であり、その 1 件を作る主要な発生源が prefix 衝突になる。guard があること自体が安全を意味しない。

### 対策: 語境界の anchor

修正は anchor の追加だけで済む（実測: 衝突 0 件化、正常解決は不変）。ただし単一 regex に `([^0-9]|$)` を書くと Markdown テーブルセル内で raw pipe がセル境界を壊す。`git log` の複数 `--grep` が **OR 結合**である性質を使い、pipe を使わずに語境界を表現できる:

```
git log -E --grep "refs #{N}[^0-9]" --grep "refs #{N}$" --format=%H
```

「N の直後が非数字 **または** 行末」で語境界が成立する。**Markdown テーブルセル内に regex を書くときは raw pipe を避け、書いた直後にセル数を機械確認する**（`awk -F'|'`）。

### 位置ベースの分岐で散文引用を除外してはならない

一致した「位置」（subject 行 / squash された箇条書き行 / trailer 行 / 地の文）は判別材料にならない。実装 commit も自分の Issue を地の文で引くためである。

reviewer が「行頭アンカー化で散文衝突を消せる」と提案したが、develop の全番号で before/after を実測すると、素の行頭アンカーは**正当な解決 294 件**を落とした。衝突を減らすぶんだけ正当な解決も失う。**提案が具体的な regex を含むときほど、採用前に全件で測る。**

区別できないことが確定したら、その事実を規定として書き残す（「正規表現では区別できない。位置ベースの分岐を追加してはならない」）。理由を添えないと次 cycle で同じアンカー案が再提案され、再測定のコストが繰り返される。

### 機械的判別が不可能な箇所は全文読解へ委ねる

`refs #N` の散文引用と実装 commit は正規表現で区別できないが、commit message 全文を読めば「その commit 自身が #N の実装か」は判断できる。手順書では**「候補を出す機械的ステップ」と「絞り込む読解ステップ」を分け**、後者の判断基準を具体例の形（無関係であることを述べている 等）で示す。

## 関連ページ

- [パスセグメント境界を無視した部分一致は別対象へ誤爆する](./path-segment-substring-over-match.md)
- [貪欲な正規表現は Markdown テーブルのセル区切りを越える](./greedy-regex-crosses-markdown-table-cell-separator.md)

## ソース

- [PR #2056 review results (cycle 5) — 語境界欠如の逆説的構造](../../raw/reviews/20260730T085655Z-pr-2056.md)
- [PR #2056 fix results (cycle 5) — 複数 --grep の OR 結合で pipe なし語境界](../../raw/fixes/20260730T090005Z-pr-2056.md)
- [PR #2056 review results — 行頭アンカー案を全件実測で棄却](../../raw/reviews/20260730T101445Z-pr-2056.md)
- [PR #2056 fix results — 機械ステップと読解ステップの分離](../../raw/fixes/20260730T101445Z-pr-2056.md)
