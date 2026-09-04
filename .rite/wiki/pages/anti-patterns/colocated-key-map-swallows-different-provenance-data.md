---
type: "anti-patterns"
title: "file:line を key にする map は、同じ位置にある別出自のデータを無音で巻き添えにする"
domain: "anti-patterns"
promote: rite-plugin
description: "過去のレビュー事例の cycle 2 で HIGH として検出。"
created: "2026-07-27T17:54:54+09:00"
sources:
  - type: "fixes"
    resource: "raw/fixes/20260727T053017Z-pr-2036.md"
tags: []
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-07-27T17:54:54+09:00" }
---

# file:line を key にする map は、同じ位置にある別出自のデータを無音で巻き添えにする

## 概要

起点事例の cycle 2 で HIGH として検出。自動レビューの指摘を「実測なし = 非ブロッキング」に分類する map を `file:line` で引く設計にしたため、**同一 file:line にある人間レビュアーの未解決 thread** が同じ分類に落ち、fix も reply もされないまま「対応済み」として件数に計上されていた。

## 詳細

**なぜ無音になるか**: `file:line` は「その位置に関する指摘」を一意に識別しない。同じ行に対して、

- ツールが自動生成した指摘（分類対象）
- 人間レビュアーが書いた thread（分類対象外・対応必須）

が同時に存在しうる。map の lookup は出自を区別しないので、後者が前者の分類を継承する。継承先が「非ブロッキング」だと、**対応義務が消えたうえに集計上は処理済みに見える**という二重の隠蔽になる。

**対処**:

1. **出自の確認を分岐条件に入れる**。lookup がヒットしても、その thread がツール由来だと確認できない場合は分類を適用しない。
2. **判定不能時は安全側に倒す**。本ケースでは、出自を確認できない thread は「外部レビュー（blocking）」側へ振り替えることにした。
3. **振り替えを observable にする**。`[CONTEXT] ..._RECLASSIFIED_TO_EXTERNAL=1; count={n}; cause=provenance_unconfirmed` のような marker を MUST 化し、静かに分類が変わらないようにする。
4. **減算対象を限定する**。振り替えたぶんを集計から引くとき、「振り替えた key のみ」に限定しないと、無関係な件数まで減って finalize 等式が壊れる。

**一般化**: 位置（file:line）・時刻・名前など、**衝突しうる自然キー**で map を引く設計は、衝突時に「たまたま同じキーを持つ別物」を巻き込む。キーの一意性が保証できないなら、値側に出自フィールドを持たせて突合するか、判定不能を明示的な第 3 の状態として扱う。

## 関連ページ

- [advisory データの欠陥検証を hard fail にすると primary データごと失われる](./advisory-data-validation-hard-fail-drops-primary-data.md)
- [「破棄しない」を保証する記録先は永続チャネルに置き、除外契約と保存先をセットで規定する](../patterns/durable-channel-for-no-discard-guarantee.md)

## ソース

- [fix 結果](../../raw/fixes/20260727T053017Z-pr-2036.md)
