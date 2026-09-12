---
type: "anti-patterns"
title: "jq の `[]?` は型不正を空の結果に変えて rc=0 で終わり、呼び出し側の fail-loud 分岐を迂回する"
domain: "anti-patterns"
description: "入力 JSON の配列を `.key[]?` で読むと、キーが無い・配列でない入力でも jq はエラーにならず空の結果を返すため、その直後に置いた失敗分岐へ到達しない。型を明示的に検査して error() にし、壊れた入力と型違いの fixture で分岐をテストする。"
created: "2026-09-12T15:25:00+00:00"
generated: { by: "rite-wiki-ingest/claude-opus-5", at: "2026-09-12T15:25:00+00:00" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20260912T142140Z-pr-2741.md"
  - type: "fixes"
    resource: "raw/fixes/20260912T142455Z-pr-2741.md"
tags: ["jq", "fail-loud", "silent-failure", "testing"]
confidence: high
---

# jq の `[]?` は型不正を空の結果に変えて rc=0 で終わり、呼び出し側の fail-loud 分岐を迂回する

## 概要

入力 JSON の配列を `.key[]?` で読むと、キーが無い・配列でない入力でも jq はエラーにならず空の結果を返すため、その直後に置いた失敗分岐へ到達しない。型を明示的に検査して error() にし、壊れた入力と型違いの fixture で分岐をテストする。

## 詳細

**起きること**: `if ! out=$(jq '[.items[]? | ...]' file); then 失敗分岐; fi` の形では、`.items` が欠落または文字列のとき `?` がエラーを握りつぶして `[]` を返し、rc=0 で終わる。失敗分岐（WARNING と marker を出して安全側へ倒す経路）には入らず、「照合対象が 0 件だった」という正常経路と同じ出力になる。観測された事例では、照合できなかったのに「除外 0 件」の正常結果として全件を処理し、除外不能を知らせる marker も出なかった。

**直し方**: `?` を使わず、型を明示的に検査して error() にする。

```
if (.items | type) != "array" then error("items is not an array") else . end
| [.items[] | ...]
```

これで既存の失敗分岐（WARNING・marker・stderr の原因行）にそのまま届く。フォールバックは足さない。

**テストで固定する**: 修正で失敗分岐へ届くようになっても、その分岐を通るテストが無ければ固定されない。次の 2 種の fixture を置き、失敗分岐を no-op にする変異でテストが落ちることを確認する。

- 構文として壊れた JSON（例: `{broken`）: 修正前の jq でも parse error で失敗分岐に届く。修正の回帰検出には効かない
- 型違いの JSON（例: `{"items":"x"}`）: `?` の握りつぶしを検出できるのはこちらだけ

## 関連ページ

- [`set -euo pipefail` 下の `var=$(cmd | jq ... 2>/dev/null)` は不正入力でテストを無言 abort させる](./pipefail-jq-assignment-silent-abort.md)
- [バグ修正PRが新設したエラーパス自身にも回帰テストを追加する](../patterns/bugfix-new-error-path-needs-regression-test.md)

## ソース

- [レビュー結果](../../raw/reviews/20260912T142140Z-pr-2741.md)
- [fix 結果](../../raw/fixes/20260912T142455Z-pr-2741.md)
