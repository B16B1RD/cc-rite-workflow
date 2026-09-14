---
type: "anti-patterns"
title: "macOS の awk の == は UTF-8 ロケールで照合比較になり、別の日本語文字列を等しいと判定する"
domain: "anti-patterns"
description: "macOS 標準の awk は UTF-8 ロケールで文字列の == をロケール照合で比較するため、別の日本語見出しを同じ見出しと判定し、Linux の gawk / mawk では再現しない誤判定を起こす。"
created: "2026-09-14T06:55:00Z"
generated: { by: "rite-wiki-ingest/claude-opus-5", at: "2026-09-14T06:55:00Z" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20260914T064706Z-pr-2803.md"
tags: ["portability", "awk", "macos", "locale", "diagnostics"]
confidence: high
---

# macOS の awk の == は UTF-8 ロケールで照合比較になり、別の日本語文字列を等しいと判定する

## 概要

macOS 標準の awk は UTF-8 ロケールで文字列の == をロケール照合で比較するため、別の日本語見出しを同じ見出しと判定し、Linux の gawk / mawk では再現しない誤判定を起こす。

## 詳細

### 観測された症状

Markdown の特定の節（`### 却下台帳`）に属する表の行を数える awk が、`$0 == head` で見出しを判定していた。macOS の CI ランナー（`/usr/bin/awk`、`LC_ALL=en_US.UTF-8`）では、後続の別の節の見出し `### 別の節` も `$0 == head` に一致し、節に入り直して節の外の表の行まで数えた。Linux の gawk / mawk、ソースからビルドした onetrue awk、Linux 上でビルドした Apple 版 awk のいずれでも再現しなかった。日本語の文字どうしで照合順序上の重みが区別されず、等しいと扱われたと考えられる。

### 書き方

日本語を含む文字列の等値判定は、ロケール照合を通らないバイト比較で書く。

```awk
index($0, head) == 1 && length($0) == length(head) { in_sec = 1; next }
```

前方一致だけなら `index($0, prefix) == 1` で足りる。`length` を併せて見るのは、`### 却下台帳（旧）` のような前方一致するだけの別見出しを弾いて、元の `==` と同じ意味を保つためである。

### 手元で再現しないときは、実機で評価したい条件を評価される位置で出す

原因を手元で再現できず、CI の実機に一時診断を仕込んで特定した。このとき、見出し判定の規則（`$0 == head { ...; next }`）より後ろに行ごとの出力を置いたため、見出し行に対する別の条件（`/^### /`）の結果は `next` で飛ばされて一度も出力されなかった。それを「一致しなかった」と読み違え、未観測の原因が恒久コメントと follow-up Issue の要件に転記された。

- 評価したい条件は、それを飛ばしうる `next` / `exit` より前で出力する
- 移植性の修正で原因を 2 つ以上書くときは、それぞれに観測の根拠があるかを確かめ、未観測のものは書かない

## 関連ページ

- [移植性の指摘は「環境分岐を足す」より先に「その正規表現機能が本当に要るか」を疑う](../heuristics/portability-fix-questions-the-regex-feature-first.md)
- [エラーメッセージ文字列の grep assert は locale 依存で dead assertion 化する](./locale-dependent-error-message-grep-assertion.md)

## ソース

- [再レビュー結果](../../raw/reviews/20260914T064706Z-pr-2803.md)
