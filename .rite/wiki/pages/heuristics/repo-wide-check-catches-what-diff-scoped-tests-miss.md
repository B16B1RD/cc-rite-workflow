---
type: "heuristics"
title: "リポジトリ全体を走査する検査は変更ファイルだけの reviewer / テストには見えない — 修正後は全体検査も含めて実行する"
domain: "heuristics"
description: "変更ファイルだけを見る reviewer やテスト実行は、リポジトリ全体を走査する静的検査（番号参照検査等）が拾う drift を観測できない。修正が正しく効いたかは、変更ファイルのテストだけでなく全体検査を実行して確認する。Python の 1 要素タプル `(x,)` は末尾が `,)` になるため、削除痕を検出する検査の pattern に偶発的に一致することがある。"
created: "2026-09-26T06:12:43Z"
generated: { by: "rite-wiki-ingest/claude-sonnet-5", at: "2026-09-26T06:12:43Z" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20260926T054854Z-pr-3060.md"
  - type: "fixes"
    resource: "raw/fixes/20260926T055557Z-pr-3060.md"
tags: ["review-loop", "static-check", "test-scope", "number-reference"]
confidence: medium
---

# リポジトリ全体を走査する検査は変更ファイルだけの reviewer / テストには見えない — 修正後は全体検査も含めて実行する

## 概要

変更ファイルだけを見る reviewer やテスト実行は、リポジトリ全体を走査する静的検査（番号参照検査等）が拾う drift を観測できない。修正が正しく効いたかは、変更ファイルのテストだけでなく全体検査を実行して確認する。Python の 1 要素タプル `(x,)` は末尾が `,)` になるため、削除痕を検出する検査の pattern に偶発的に一致することがある。

## 詳細

### 起きたこと

修正の過程でテストコードに Python の 1 要素タプルリテラル `(x,)` を書いたところ、リポジトリ全体を走査して番号削除の痕跡（`,)` のような pattern）を検出する検査に誤って一致した。この検査は変更ファイルの diff だけを見る reviewer やテストスイートの実行範囲には含まれておらず、CI の全体検査 job まで進んで初めて表面化した。

### なぜ素通りするか

- reviewer は通常 PR の変更ファイル（diff）だけを読む。リポジトリ全体を走査する検査は変更ファイルの中身とは独立に発火するため、diff だけを見ていては予測できない
- 変更ファイルのテストスイートだけを実行して green を確認しても、全体検査は別のコマンド・別の CI job として走るため、ローカルで見落としやすい
- Python の 1 要素タプル記法 `(x,)` はごく一般的な書き方だが、末尾の `,)` という文字列そのものは「値を削除して括弧を残した痕跡」の pattern と区別がつかない

### やること

1. 全体走査型の静的検査（number-reference-check 等）が存在するプロジェクトでは、変更ファイルのテストと**別に**全体検査を実行してから完了とする
2. テストコードで意図せず全体検査の pattern に一致する記法（1 要素タプル `(x,)` 等）を避けるか、リストで書く（`[x]`）などして誤検出を防ぐ
3. reviewer は diff の範囲外の検査結果（CI の全体検査 job のログ）も確認対象に含める

## 関連ページ

- [差分スコープのレビューは diff の外を基準以前に見られない — cycle 上限到達後にフルレビューを 1 回挟む](./differential-scope-review-blind-outside-diff.md)
- [テストの歴史的ピン行は番号を残し行末へ drift-check-ignore を付ける](../patterns/historical-pin-line-keeps-number-and-attaches-drift-check-ignore.md)

## ソース

- [reviewer が全員 FIXED と判定した cycle でも全体検査が別途必要と指摘したレビュー結果](../../raw/reviews/20260926T054854Z-pr-3060.md)
- [1 要素タプルが番号削除痕検査に誤って一致したことを記録した fix 結果](../../raw/fixes/20260926T055557Z-pr-3060.md)
