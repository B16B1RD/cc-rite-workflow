---
type: "anti-patterns"
title: "ERE の ? を多バイト文字に直接掛けると LC_ALL=C でバイト単位評価になり検出が失効する"
domain: "anti-patterns"
promote: rite-plugin
description: "ERE の `?`（直前の 1 要素を optional にする）を多バイト文字へ直接掛けると、`LC_ALL=C` ではロケールが文字境界を知らないため**バイト単位で評価**される。"
created: "2026-08-07T18:40:00+09:00"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260807T073304Z-pr-2135.md"
  - type: "fixes"
    resource: "raw/fixes/20260807T074604Z-pr-2135.md"
tags: []
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-08-07T18:40:00+09:00" }
---

# ERE の ? を多バイト文字に直接掛けると LC_ALL=C でバイト単位評価になり検出が失効する

## 概要

ERE の `?`（直前の 1 要素を optional にする）を多バイト文字へ直接掛けると、`LC_ALL=C` ではロケールが文字境界を知らないため**バイト単位で評価**される。`?` は多バイト文字の**最終バイトだけ**に掛かり、意図した「その文字ごと optional」にならない。結果、検出したいはずの文字列にマッチせず、検査が黙って失効する。

## 詳細

ある PR の lint パターンで実測。既定値の drift を検出する検査に `既定値? 5` と書いた。意図は「`既定値 5` と `既定 5` の両方を拾う」こと。

**何が起きるか**: `値` は UTF-8 で 3 バイト（`E5 80 A4`）。`LC_ALL=C` 下では grep はこれを 3 つの独立したバイトとして扱い、`?` は最後の 1 バイト `A4` にだけ掛かる。したがってパターンは実質 `既定<E5><80><A4>?<space>5` となり、**`既定 5` にはマッチしない**（`E5 80` が残っているため）。

**発現条件**: 現行の開発環境（`ja_JP.UTF-8` / `C.UTF-8`）ではロケールが文字境界を認識するため**発現しない**。`LC_ALL=C` を明示するスクリプト、あるいは CI runner のロケール設定変更で初めて失効する。つまり **silent に壊れる**。

**解決**: グループ化して `?` をグループに掛ける。

```
# NG: ? が「値」の最終バイトにだけ掛かる
grep -E '既定値? 5'

# OK: ? がグループ全体に掛かる
grep -E '既定(値)? 5'
```

**この repo での発見経路**: この欠陥は 3 名の reviewer が独立に mutation testing を投入した過程で見つかった（31 mutant 中 27 撃墜 / 4 生存）。**mutation testing なしでは「テストが green」と「テストが drift を検出できる」を区別できない** — 現行ロケールで発現しない以上、通常の実行では永久に緑のままである。

**あわせて踏みやすい隣接パターン**:

- **シェル変数の直後に多バイト文字が来る箇所はブレースで囲む**。`"（既定 $DEFAULT_CYCLES）"` は非 UTF-8 ロケールで後続バイトが変数名に畳み込まれ `set -u` を踏む。`${DEFAULT_CYCLES}` と書く（本 repo では `flow-state.test.sh` TC-8b-h の lint が検出する）
- 検出パターンで**半角スペースを必須にしない**。`（既定 5）` と `（既定5）` の両方が実在するため、スペース必須のパターンは表記揺れの分だけ穴が残る

**判定の目安**: `grep -E` のパターンに多バイト文字と `?` / `*` / `+` / `{n}` が隣接していたら疑う。`LC_ALL=C grep -E` で実際に走らせ、拾うべき文字列を拾うか確認する（UTF-8 ロケールでのテストは通ってしまうので判別能力がない）。

## 関連ページ

- [エラーメッセージ文字列の grep assert は locale 依存で dead assertion 化する](./locale-dependent-error-message-grep-assertion.md)
- [grep (BRE) と grep -E (ERE) のメタ文字反転で assert ヘルパーが常時緑の dead assertion になる](./bre-ere-metachar-inversion-dead-assertion.md)

## ソース

- [レビュー結果](../../raw/reviews/20260807T073304Z-pr-2135.md)
- [fix 結果](../../raw/fixes/20260807T074604Z-pr-2135.md)
