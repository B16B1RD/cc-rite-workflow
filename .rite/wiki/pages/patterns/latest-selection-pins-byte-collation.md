---
type: "patterns"
title: "「最新」を選ぶ列挙は照合順を LC_ALL=C に固定する"
domain: "patterns"
description: "glob 展開と [[ < ]] は呼び出し元のロケールの照合順に従い、en_US.UTF-8 では記号を第 1 段階で無視するため、同じ秒に保存した名前の並びが C と逆になる。最新を選ぶ列挙は関数内で照合順を固定し、同じ記録を選ぶ他の処理とそろえる。"
created: "2026-09-25T09:56:20Z"
generated: { by: "rite-wiki-ingest/claude-opus-5-5[1m]", at: "2026-09-25T09:56:20Z" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20260925T094208Z-pr-3075.md"
tags: []
confidence: medium
---

# 「最新」を選ぶ列挙は照合順を LC_ALL=C に固定する

## 概要

glob 展開と [[ < ]] は呼び出し元のロケールの照合順に従い、en_US.UTF-8 では記号を第 1 段階で無視するため、同じ秒に保存した名前の並びが C と逆になる。最新を選ぶ列挙は関数内で照合順を固定し、同じ記録を選ぶ他の処理とそろえる。

## 詳細

### 観測された失敗

レビュー結果の読み元を直下と archive/ から列挙する関数が、glob 展開と `[[ "$a" < "$b" ]]` で basename を並べていた。en_US.UTF-8 では `.` と `~` が照合の第 1 段階で無視され、同秒衝突で保存された `{ts}.json` と `{ts}~{hex}.json` の順序が C と逆になる。その結果、follow-up 起票が「最新」として選ぶ JSON が、同じ台帳を作った sweep（`LC_ALL=C sort | tail -1` で選ぶ）と食い違い、sweep で Issue 化済みの指摘を再転記した。C と ja_JP では並びが一致するため、開発環境によっては再現しない。

### 対処

- 関数の先頭で `local LC_ALL=C` を宣言する。glob の並びと `[[ < ]]` の両方がバイト順になり、関数を抜けると呼び出し元のロケールは戻る
- 2 つのディレクトリの列挙は連結ではなく basename でマージする。連結すると片側がすべて後ろに並ぶ
- テストは C 以外の照合（en_US.UTF-8 が有る環境ではそれ）で、同秒衝突の組を含む全件の順序と最新の選択を assert する。`tail -1` だけの assert は、除外すべき要素が末尾以外に並ぶと検出力を持たない

### 関連する注意

GC を実行するテストは TMPDIR をテスト専用にする。しないと開発者の実 TMPDIR にある古いディレクトリを掃除する。

## 関連ページ

- [エラーメッセージ文字列の grep assert は locale 依存で dead assertion 化する](../anti-patterns/locale-dependent-error-message-grep-assertion.md)

## ソース

- [レビュー結果（読み元の列挙がロケールで並び替わる）](../../raw/reviews/20260925T094208Z-pr-3075.md)
