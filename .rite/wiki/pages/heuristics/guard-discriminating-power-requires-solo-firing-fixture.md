---
type: "heuristics"
title: "ガードの識別力は「そのガード単独で発火する形状」の fixture とガード固有文言 assert で担保する"
domain: "heuristics"
description: "エラーガードのテストが (a) rc の非ゼロ性と (b) 総称的な `grep -q 'ERROR'` しか assert していないと、**兄弟ガードが同じ rc・同じ総称文言で発火するため、対象ガードを削除してもテストは全緑で通る**。"
created: "2026-08-05T09:26:00+09:00"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260804T173728Z-pr-2111.md"
  - type: "fixes"
    resource: "raw/fixes/20260804T175004Z-pr-2111.md"
  - type: "reviews"
    resource: "raw/reviews/20260926T045233Z-pr-3112.md"
  - type: "reviews"
    resource: "raw/reviews/20260927T032308Z-pr-3204.md"
  - type: "reviews"
    resource: "raw/reviews/20260929T051504Z-pr-3434.md"
  - type: "reviews"
    resource: "raw/reviews/20260929T053524Z-pr-3431.md"
tags: ["guard", "discriminating-power", "diagnostic-literal", "fixture-design", "sibling-tc-transcription"]
confidence: high
generated: { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-29T05:45:52Z" }
verified:
  - { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-26T05:05:00Z" }
  - { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-27T03:27:52Z" }
  - { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-29T05:45:52Z" }
---

# ガードの識別力は「そのガード単独で発火する形状」の fixture とガード固有文言 assert で担保する

## 概要

エラーガードのテストが (a) rc の非ゼロ性と (b) 総称的な `grep -q 'ERROR'` しか assert していないと、**兄弟ガードが同じ rc・同じ総称文言で発火するため、対象ガードを削除してもテストは全緑で通る**。ガードの識別力（そのガードが実在し、その形状を捕捉していること）は次の 2 点で初めて立つ:

1. **そのガード単独で発火する形状の fixture** — 複数ガードが論理和で捕捉する fixture では、どのガードが発火したか判別できない
2. **ガード固有の診断文言の assert** — rc だけでは退行時の誤診断（別ガードの rc=1）と区別できない

## 詳細

### 失敗の構造（run 2 cycle 1〜2 で反復実測）

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

**失敗を注入する shim は「何も出さずに失敗」にしない**: 外部コマンドの失敗分岐を shim で踏むとき、shim が何も出力せずに失敗すると、分岐の処理（fallback の呼び出し）を消した変異でも結果が空のまま進む。そのまま別の経路で同じ fallback に落ちるため、観測は元と変わらず、変異を見分けられるのは reason の 1 本だけになる。shim に実在の値を 1 行出させてから失敗させると、rc を見落とす変異は狭い側（incremental・一覧の書き出し）へ進む。その結果、状態を見る複数の assert がこの変異を捕らえる。同じ reason を複数の分岐が共有するときは、分岐固有の WARNING 文言も assert して、別の分岐で PASS する空振りを防ぐ。

### 新設した fail-loud 分岐は、実装と同じ PR で踏むテストを用意する

受入条件をすべて満たして blocking 0 件で通った PR でも、推奨事項には同じ型が繰り返し現れる。新設した fail-loud 分岐（例: producer 側の jq 読み取り失敗で止める分岐）を踏むテストが無い。実装方式を変えた後も、テストのヘルパー名が旧方式（copy など）を名乗り続ける。新しい停止 reason に復旧手順が添えられていない。どれも「正常経路のテストが通る」ことでは検出できない。分岐を足したら、その分岐単独で発火する fixture と reason 固有の文言 assert を同じ PR で揃える。方式を変えたらテスト側の名前も追従させ、停止 reason には利用者が次に取る行動を添える。

**ガードの有無で行き先が変わらない入力はガードを固定しない**: symlink を特別扱いするガードを壊れた symlink だけで検査すると、壊れた symlink は手前の種別判定で弾かれるため、ガードを消しても同じ結果になる。指す先を実在させた symlink を置いて初めて、ガードの有無で挙動が分かれる。

**検証対象より前段のフィルタを通過する fixture を作る**: run 境界の選別を検証するつもりで前 run の結果を仕込んでも、その結果が現在の run の識別子を持たなければ、手前の識別子フィルタが先に落として選別そのものに届かない。選別を無視する変異でもテストは緑のまま残る。境界を検証する fixture は上流のフィルタをすべて通し、検証したい判定だけが結果を分ける形にする。テストが名乗る保証の真偽は「そのテストは名乗った挙動を壊す変異で落ちるか」で分ける。一部の変異でしか落ちないなら誤りではなく網羅性の問題として扱う。

## 関連ページ

- [HINT-specific 文言 pin で case arm 削除 regression を検知する](../patterns/hint-specific-assertion-pin.md)
- [アサーションの検証強度は「該当行を壊して赤くなるか」でしか測れない](./mutation-testing-measures-assertion-strength.md)

## ソース

- [レビュー結果](../../raw/reviews/20260804T173728Z-pr-2111.md)
- [fix 結果](../../raw/fixes/20260804T175004Z-pr-2111.md)
- [レビュー結果](../../raw/reviews/20260926T045233Z-pr-3112.md)
- [新設 fail-loud 分岐のテスト不足を指摘したレビュー](../../raw/reviews/20260927T032308Z-pr-3204.md)
- [symlink ガードの検査を扱ったレビュー結果](../../raw/reviews/20260929T051504Z-pr-3434.md)
- [run 境界の選別を検査したレビュー結果](../../raw/reviews/20260929T053524Z-pr-3431.md)
