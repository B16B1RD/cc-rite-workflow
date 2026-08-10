---
type: "heuristics"
title: "ガードの識別力は「そのガード単独で発火する形状」の fixture とガード固有文言 assert で担保する"
domain: "heuristics"
description: "エラーガードのテストが (a) rc の非ゼロ性と (b) 総称的な `grep -q 'ERROR'` しか assert していないと、**兄弟ガードが同じ rc・同じ総称文言で発火するため、対象ガードを削除してもテストは全緑で通る**。"
created: "2026-08-05T09:26:00+09:00"
updated: "2026-08-05T09:26:00+09:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260804T173728Z-pr-2111.md"
  - type: "fixes"
    ref: "raw/fixes/20260804T175004Z-pr-2111.md"
tags: ["guard", "discriminating-power", "diagnostic-literal", "fixture-design", "sibling-tc-transcription"]
confidence: high
---

# ガードの識別力は「そのガード単独で発火する形状」の fixture とガード固有文言 assert で担保する

## 概要

エラーガードのテストが (a) rc の非ゼロ性と (b) 総称的な `grep -q 'ERROR'` しか assert していないと、**兄弟ガードが同じ rc・同じ総称文言で発火するため、対象ガードを削除してもテストは全緑で通る**。ガードの識別力（そのガードが実在し、その形状を捕捉していること）は次の 2 点で初めて立つ:

1. **そのガード単独で発火する形状の fixture** — 複数ガードが論理和で捕捉する fixture では、どのガードが発火したか判別できない
2. **ガード固有の診断文言の assert** — rc だけでは退行時の誤診断（別ガードの rc=1）と区別できない

## 詳細

### 失敗の構造（PR #2111 run 2 cycle 1〜2 で反復実測）

- TC-22 は複数ガードが論理和で捕捉する fixture に「このガードを pin する」というコメント宣言を付けていたが、宣言は過剰主張で、実際の発火順は別ガードが先だった。**境界検査だけが捕捉する形状**（セル数を満たす余剰フラグメント行)を追加して初めて pin になった
- 読み取り不能ガード（`-r`）は rc だけでなくガード固有の診断文言（`not readable`）を assert しないと、awk 失敗の rc=1 と区別できない
- mutation で実測: `-f` ガード削除が 39/39 green で素通り。ガード固有文言（`not found` / `--pages-root was not given`）を assert して初めて削除が fail 化した

### 転記規律: rationale をコメントに書いた時点で同型 TC への転記が必要

cycle 1 で TC-13b（読み取り不能）にガード固有文言 assert の rationale をコメントで書きながら、**同型の TC-13（不在）へ転記せず** `grep -q 'ERROR'` のままにした。結果、cycle 2 で同じ指摘が TC-13 に対して返ってきた。さらに cycle 3 でも兄弟 TC（TC-14 / TC-22 / TC-22b）と必須引数ガード 3 本への転記漏れが再発した。

**是正の対象は「その TC」ではなく「同じ assert 形を持つ TC 群」**。rationale を 1 箇所に書いた時点で、同型の assert を持つ TC を grep で列挙し、全件へ同時適用する。

### チェックリスト

| 段階 | 確認 |
|---|---|
| fixture 設計 | 対象ガード**単独**で発火する形状か（兄弟ガードに先取りされないか） |
| assert | ガード固有の診断文言を含むか（総称 `ERROR` のみは不可） |
| コメント | 「このガードを pin する」宣言は実際の発火順と一致するか |
| 横展開 | 同じ assert 形を持つ兄弟 TC を grep で列挙し、同時に是正したか |
| 検証 | 対象ガードを削除する変異で当該 TC だけが fail するか |

## 関連ページ

- [HINT-specific 文言 pin で case arm 削除 regression を検知する](../patterns/hint-specific-assertion-pin.md)
- [アサーションの検証強度は「該当行を壊して赤くなるか」でしか測れない](./mutation-testing-measures-assertion-strength.md)

## ソース

- [PR #2111 review results](../../raw/reviews/20260804T173728Z-pr-2111.md)
- [PR #2111 fix results](../../raw/fixes/20260804T175004Z-pr-2111.md)
