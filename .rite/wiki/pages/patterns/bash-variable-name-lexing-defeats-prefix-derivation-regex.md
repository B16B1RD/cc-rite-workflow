---
type: "patterns"
title: "bash は `$` の後の `[A-Za-z0-9_]` 連続を 1 つの変数名として読む — 無括弧の `$v_suffix` は派生ではなく別変数"
domain: "patterns"
description: "「変数 `$v` から派生したパス」を追跡する検出器で、**変数名の接頭辞一致を派生と読むと誤検知する**。"
created: "2026-08-06T22:40:00+09:00"
sources:
  - type: "fixes"
    resource: "raw/fixes/20260806T055534Z-pr-2124.md"
tags: []
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-08-06T22:40:00+09:00" }
---

# bash は `$` の後の `[A-Za-z0-9_]` 連続を 1 つの変数名として読む — 無括弧の `$v_suffix` は派生ではなく別変数

## 概要

「変数 `$v` から派生したパス」を追跡する検出器で、**変数名の接頭辞一致を派生と読むと誤検知する**。bash は `$` の後の `[A-Za-z0-9_]` の連続を 1 つの変数名として読むため、`$v_suffix` は `$v` の派生ではなく `v_suffix` という別の変数への参照である。

## 詳細

### 実測された誤検知（PR #2124 cycle 1）

tempfile ハンドルの派生パスを追跡する検出器で、`$tmp_bak`（`$tmp` の派生を意図した綴り）を派生として扱ったところ、`$pr_view_err` に対して `$pr_view_err_oneline` が誤検知した。後者は bash にとって `pr_view_err_oneline` という独立した変数であり、`$pr_view_err` とは何の関係もない。

### 派生として成立する綴り

| 綴り | bash の解釈 | 派生か |
|---|---|---|
| `$v_suffix` | 変数 `v_suffix` への参照 | **派生ではない**（別変数） |
| `${v}_suffix` | 変数 `v` の値 + リテラル `_suffix` | 派生 |
| `$v-suffix` | 変数 `v` の値 + リテラル `-suffix`（`-` は変数名に使えないので境界になる） | 派生 |
| `$v.bak` | 変数 `v` の値 + リテラル `.bak` | 派生 |

要するに、**変数名に使える文字（`[A-Za-z0-9_]`）で続けた綴りは派生にならない**。境界を作れるのは波括弧か、変数名に使えない文字だけ。

### 一般則

検出器を書くときは「**bash がこの文字列をどう parse するか**」を先に確認する。シェルの字句規則に沿わないパターンを書くと、誤検知の形で必ず表面化する。誤検知は「検出器が信用されなくなる」という形で機能を殺すため、拾えないこと（false negative）より高くつく場面が多い。

## 関連ページ

- [検出範囲を広げる修正は「広がった」と「広がりすぎていない」を対で pin する](./detector-widening-pins-both-bounds.md)
- [検出層の表記ゆれ対応は「列挙」ではなく「正規化」で吸収する](./normalize-instead-of-enumerate-in-detection-layer.md)

## ソース

- [PR #2124 fix results](../../raw/fixes/20260806T055534Z-pr-2124.md)
