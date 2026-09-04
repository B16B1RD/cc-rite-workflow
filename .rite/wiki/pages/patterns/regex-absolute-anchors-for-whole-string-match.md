---
type: "patterns"
title: "jq / Oniguruma の `$` は末尾改行の直前にも match する — 文字列全体一致は `\\A` / `\\z` を使う"
domain: "patterns"
description: "jq の `test()` が使う Oniguruma（および Perl / Ruby 系の正規表現エンジン）では、`$` は「文字列末尾」ではなく「文字列末尾**または末尾改行の直前**」に match する。"
created: "2026-08-07T07:59:00+09:00"
sources:
  - type: "fixes"
    resource: "raw/fixes/20260806T181047Z-pr-2126-c5.md"
tags: []
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-08-07T07:59:00+09:00" }
---

# jq / Oniguruma の `$` は末尾改行の直前にも match する

## 概要

jq の `test()` が使う Oniguruma（および Perl / Ruby 系の正規表現エンジン）では、`$` は「文字列末尾」ではなく「文字列末尾**または末尾改行の直前**」に match する。`test("^foo$")` は `"foo\n"` に対して true を返す。値を単一行の channel へ出す用途では、この 1 文字の差がそのまま欠陥になる。文字列全体の一致を要求するときは `\A` / `\z` を使う。

## 詳細

ある PR の cycle 4 で、`; ` 区切りの単一行 marker へ出す値に形の allowlist `test("^[a-z][a-z0-9-]*[a-z0-9]$")` を導入した。目的は marker 行の分断（値に改行が入ると 2 行目が column 0 に着地し、消費側が別フィールドとして読む）を防ぐことだった。cycle 5 で、その allowlist が**末尾改行 1 個を通す**ことが実測された — `"security-reviewer\n"` が valid と判定され、BAD 経路の fail-loud が発火しない。書込側は当該フィールドを一切検証しないため、この allowlist が唯一の形ゲートだった。結果、閉じたかった欠陥そのものがアンカーの選択で開いていた。

**実測（jq 1.7）**:

| 式 | `"ab-reviewer"` | `"ab-reviewer\n"` |
|---|---|---|
| `test("^[a-z][a-z0-9-]*[a-z0-9]$")` | true | **true**（意図せず通る） |
| `test("\\A[a-z][a-z0-9-]*[a-z0-9]\\z")` | true | false |

`^` 側は文字列先頭のみに match するため変更不要（`"evil\nsecurity-reviewer"` は false）。穴は `$` 側だけにある。

**shell literal での書き方**: jq プログラムを single-quote で囲む場合、`\z` は jq 文字列リテラルの中で `\\z` と 2 文字で書く（jq へ `\z` が渡り、Oniguruma が絶対末尾アンカーとして解釈する）。

**適用範囲**: この挙動は POSIX ERE の `$`（行アンカー）と同根で、Ruby の `Regexp`、Perl の `m//`、Oniguruma / Onigmo を使うすべての処理系に共通する。「文字列全体が形に一致すること」を要求する検証で `^...$` を使っているコードは、末尾改行を通す。

**判定の目安**: 検証した値の行き先が「単一行を前提とする消費者」（`key=value; key=value` 形の marker、CSV の 1 レコード、ログの 1 行）なら `\A` / `\z` を使う。行単位の grep 相当（複数行テキストから該当行を探す）なら `^...$` が正しい。

**関連する一般則**: 型検査（`type == "string"`）を足した時点で「形も見ている」と錯覚しやすい。型・非空・**形**は別の検査であり、単一行 channel へ出す値は 3 つとも要る。形の allowlist を入れる際は、改行だけを潰す対症（制御文字の中和など）では不十分で、消費側の文法で意味を持つ全文字（区切り文字、接尾辞除去後に空になる値）を同時に閉じる必要がある。

## 関連ページ

- [検査と使用は同一の式に畳む](./fold-validation-and-use-into-one-expression.md)
- [`2>&1` と `2>&1 | head -N` で sentinel/exit code が silent suppression される (self-defeating observability)](../anti-patterns/stderr-merge-silent-sentinel-suppression.md)

## ソース

- [fix 結果](../../raw/fixes/20260806T181047Z-pr-2126-c5.md)
