---
type: "anti-patterns"
title: "シェル本体を別ディレクトリの helper へ移すと、相対パス・引数・出力元の記述が移設元を前提に残る"
domain: "anti-patterns"
description: "手順書のシェル処理を別ディレクトリの helper へ移すと、コメント中の相対パス、使われなくなった引数、出力元の記述が、移設元の場所を前提にしたまま残りやすい。移設時は、置き場所を基準にしたパス解決をスクリプトで全件確かめる。"
created: "2026-09-28T09:47:59Z"
generated: { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-29T03:24:18Z" }
verified:
  - { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-29T03:24:18Z" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20260928T091213Z-pr-3366.md"
  - type: "reviews"
    resource: "raw/reviews/20260929T031307Z-pr-3349.md"
tags: ["refactor", "helper-extraction", "relative-path", "comment-drift"]
confidence: medium
---

# シェル本体を別ディレクトリの helper へ移すと、相対パス・引数・出力元の記述が移設元を前提に残る

## 概要

手順書のシェル処理を別ディレクトリの helper へ移すと、コメント中の相対パス、使われなくなった引数、出力元の記述が、移設元の場所を前提にしたまま残りやすい。移設時は、置き場所を基準にしたパス解決をスクリプトで全件確かめる。

## 詳細

各ステップのシェル処理を helper にまとめて 1 行で呼ぶ形にしたとき、レビューで次の食い違いが指摘された。

- helper へ移したコメント中の rationale ポインタが、移設元を基準にした相対パスのままになっていた。
- 使われていない引数が残っていた。
- 出力（emit）元の記述が古い場所を指していた。
- 定義されていない placeholder が見出しに残っていた。

どれも、移設先の置き場所から見ると成り立たない記述である。1 件ずつ目で追うと取りこぼしやすい。置き場所を基準にしたパス解決をスクリプトで全件確かめると、修正は早く収束した。

参照記述の更新漏れは、1 箇所を直すと同じ根因の別ファイル（rationale 文書など）で次の cycle に再び見つかる。移設で呼び出し経路が変わったら、helper 名と検査対象の列挙を全文書で grep し、まとめて直す。

## 関連ページ

- [本文を helper へ移すと、fenced block をコーパスにするテストの検査数が無言で減る](./helper-relocation-silently-shrinks-corpus-tests.md)
- [保存パス基準の変更は観測面と全 caller 引数の同時スイープが必要](../heuristics/path-basis-change-observation-surface-sweep.md)

## ソース

- [移設したコメントの相対パスと残った引数を全員が解消と判定したレビュー結果](../../raw/reviews/20260928T091213Z-pr-3366.md)
- [参照記述の更新漏れが別ファイルで再発見されたレビュー結果](../../raw/reviews/20260929T031307Z-pr-3349.md)
