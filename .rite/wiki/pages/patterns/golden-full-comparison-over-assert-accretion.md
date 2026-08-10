---
type: "patterns"
title: "テスト検出力の回復は個別 assert の増築より golden 全文比較への置換を先に検討する"
domain: "patterns"
promote: rite-plugin
description: "mutation testing で「grep 断片照合のみで検出力が無い」と判明した TC を修理するとき、生存した変異ごとに assert を 1 本ずつ足していく増築は保守コストが上がるわりに変異耐性が伸びない。"
created: "2026-08-05T09:26:00+09:00"
updated: "2026-08-05T09:26:00+09:00"
sources:
  - type: "fixes"
    ref: "raw/fixes/20260804T135955Z-pr-2111.md"
tags: ["test", "golden-comparison", "mutation-testing", "detection-power", "diff-u"]
confidence: medium
---

# テスト検出力の回復は個別 assert の増築より golden 全文比較への置換を先に検討する

## 概要

mutation testing で「grep 断片照合のみで検出力が無い」と判明した TC を修理するとき、生存した変異ごとに assert を 1 本ずつ足していく増築は保守コストが上がるわりに変異耐性が伸びない。**TC の期待値を golden 全文（期待出力ファイル全体）との `diff -u` 比較へ置換する**のが最小手で、出力のどこが壊れても 1 本の比較が捕捉する。

## 詳細

### 起点事例

散文手順 → helper 委譲リファクタ（wiki-ingest ステップ 6 の index 操作、PR #2111 cycle 1）で、reviewer が 23 変異を投入し 8 変異が生存した。生存原因は「grep 断片照合のみで golden 全文比較なし」。fix 側は生存変異に個別対応する代わりに、代表 TC（TC-1/TC-7）を `diff -u` の golden 全文比較へ置換した。

### 効果

1 箇所の置換で 4 変異クラスを一括捕捉した:

- ヘッダ二重化
- 本文欠落
- 空行の過剰削除
- 節末端の誤検出

grep 断片照合は「その断片が存在するか」しか見ないため、断片の外側で起きる構造破壊（重複・欠落・過剰削除）をすべて素通しする。全文比較は出力の**すべてのバイトを暗黙に assert** するため、個別 assert の列挙では書き尽くせない変異クラスを構造的に覆う。

### 手順

1. mutation testing で生存変異と生存原因（断片照合の盲点）を特定する
2. TC の期待値を golden ファイル（期待される出力全文）に置き、`diff -u "$golden" "$actual"` で比較する
3. **置換後に代表変異を再投入し、TC が fail 化することを実測してから commit する**（置換しただけでは検証にならない）

### 適用境界

- 出力が決定論的である TC に適用する。タイムスタンプ等の可変部を含む出力は、可変部を正規化（sed で固定文字列化）してから比較する
- 「一部の性質だけを守りたい」場合（例: 特定行の存在のみが契約）は断片照合が適切なこともある。golden 比較は契約が「出力全体の形」であるときの最小手

## 関連ページ

- [Mutation testing で test の真正性 (dead code 検出 + identification power) を empirical 検証する](./mutation-testing-test-fidelity.md)
- [テスト fixture の変異は各不変量・guard を単独で kill する配置で設計する](../heuristics/fixture-mutation-isolates-invariants.md)

## ソース

- [PR #2111 fix results](../../raw/fixes/20260804T135955Z-pr-2111.md)
