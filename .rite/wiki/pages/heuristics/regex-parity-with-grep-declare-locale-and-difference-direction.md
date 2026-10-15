---
# Domain knowledge only; rite workflow candidates stay in raw.
type: "heuristics"
title: "bash grep と同じ規則を名乗る正規表現は、合わせるロケールを決め、残る差を向きで書く"
domain: "heuristics"
description: "grep の [[:space:]] と -i の受理範囲はロケールで変わり、Python の \\s とも集合が一致しないため、「grep と同じ」は合わせるロケールを決めたうえで、どちら向きの差が残るかまで書かないと成り立たない。"
created: "2026-10-15T20:55:00+09:00"
generated: { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-10-15T20:55:00+09:00" }
sources:
  - type: "fixes"
    resource: "raw/fixes/20261015T105901Z-pr-3909.md"
  - type: "reviews"
    resource: "raw/reviews/20261015T105136Z-pr-3909.md"
  - type: "fixes"
    resource: "raw/fixes/20261015T111510Z-pr-3909.md"
  - type: "reviews"
    resource: "raw/reviews/20261015T111210Z-pr-3909.md"
  - type: "reviews"
    resource: "raw/reviews/20261015T112612Z-pr-3909.md"
  - type: "fixes"
    resource: "raw/fixes/20261015T113451Z-pr-3909.md"
  - type: "reviews"
    resource: "raw/reviews/20261015T114600Z-pr-3909.md"
tags: [regex, grep, locale, parity]
confidence: high
---

# bash grep と同じ規則を名乗る正規表現は、合わせるロケールを決め、残る差を向きで書く

## 概要

grep の `[[:space:]]` と `-i` の受理範囲はロケールで変わり、Python の `\s` とも集合が一致しないため、「grep と同じ」は合わせるロケールを決めたうえで、どちら向きの差が残るかまで書かないと成り立たない。

## 詳細

- **ロケールで grep の受理範囲が変わる**: UTF-8 ロケールの glibc grep は `[[:space:]]` で全角空白（U+3000）などの Unicode 空白を、`-i` で U+017F の畳み込みも受理する。C ロケールでは ASCII だけを受理する。
- **re.ASCII で合わせると運用ロケールで食い違う**: Python 側に `re.ASCII` を付けると C ロケールの grep とは一致するが、運用ロケールが UTF-8 なら日本語本文の全角空白で判定が分かれる。合わせる先は実際に grep が動くロケールにする。最初に `re.ASCII` で「そろえた」修正は、後の検証で運用ロケールとの食い違いを生むと分かり、フラグを外して解消した。
- **フラグを外しても完全一致にはならない**: Python の `\s` と大文字小文字の畳み込みは、grep が拒否する文字（U+001C〜U+001F、U+0085、no-break space 類、`i` の位置の U+0130）も受理する。BMP の全コード点を 2 つのロケールで突き合わせると、grep だけが受理する入力は 0 件、Python だけが受理する入力が残った。
- **主張は差の向きで書く**: 残る差を列挙するとき、一部だけを書くと実測で見つかる別の差で再指摘される。「grep が受理するものはすべて受理し、差は受理を広げる向きだけ」のように向きで書くと、全数比較で裏付けられる形になる。
- **突き合わせ試験の入力はロケールに依存しない範囲にする**: grep を実行して結果を比べる試験に、ロケールで grep の結果が変わる文字（no-break space など）を入れると、実行環境で結果が変わる。そうした文字の期待挙動は Python 側を直接呼んで固定する。
- **試験の非 ASCII 文字はコードで書く**: `chr(0x3000)` のように書く。エスケープ表記は編集の過程で生の文字に変わることがあり、見た目で区別できなくなる。

## 関連ページ

- [エラーメッセージ文字列の grep assert は locale 依存で dead assertion 化する](../anti-patterns/locale-dependent-error-message-grep-assertion.md)
- [散文が引用する実装 (regex literal / 帰属ファイル / 挙動) は文字一致・帰属・behavioral test の 3 点で裏取りする](./prose-cited-implementation-behavioral-verification.md)

## ソース

- [fix 結果（re.ASCII でそろえた最初の修正）](../../raw/fixes/20261015T105901Z-pr-3909.md)
- [レビュー結果（ASCII 空白での一致の確認）](../../raw/reviews/20261015T105136Z-pr-3909.md)
- [fix 結果（運用ロケールに合わせ直した修正）](../../raw/fixes/20261015T111510Z-pr-3909.md)
- [レビュー結果（ロケールによる食い違いの指摘）](../../raw/reviews/20261015T111210Z-pr-3909.md)
- [レビュー結果（逆向きの差の実測）](../../raw/reviews/20261015T112612Z-pr-3909.md)
- [fix 結果（主張を差の向きに限定）](../../raw/fixes/20261015T113451Z-pr-3909.md)
- [レビュー結果（全数比較での裏付け）](../../raw/reviews/20261015T114600Z-pr-3909.md)
