---
type: "anti-patterns"
title: "同一主張を複数言語で持つ記述は grep の盲点になる"
domain: "anti-patterns"
description: "実装が前提を falsify したとき、その前提を述べている記述をすべて更新する必要がある。"
created: "2026-08-01T00:21:06+09:00"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260731T111118Z-pr-2074.md"
  - type: "fixes"
    resource: "raw/fixes/20260731T114035Z-pr-2074.md"
tags: []
confidence: medium
generated: { by: "rite-wiki-ingest/unknown", at: "2026-08-01T00:21:06+09:00" }
---

# 同一主張を複数言語で持つ記述は grep の盲点になる

## 概要

実装が前提を falsify したとき、その前提を述べている記述をすべて更新する必要がある。掃き出しに grep を使うのは正しいが、**同じ主張が別言語で書かれた箇所は検索語を共有しない**ため構造的に漏れる。英日の文書ペア（README.md / README.ja.md、docs/SPEC.md と日本語 skill 群など）を持つリポジトリでは常に起こりうる。

## 詳細

起点事例は「レビュー結果 JSON への配線は後続スコープ」という注記を実体へ書き換える作業を含んでいた。日本語で書かれた注記は全消ししたが、**同じ主張を英語で持つ `docs/SPEC.md`** が検出から漏れ、上位仕様書に陳腐化した主張が残った。上位文書ほど読み手が多く、そこだけを読んだ人は「まだ配線されていない」と誤読する。

対処は掃き出し語を言語ごとに用意することだが、より確実なのは[主張した概念で走査する逆引き検査](../heuristics/reverse-lookup-concept-sweep-for-prose-fixes.md)と組み合わせることである。概念で `git grep -l` してヒットしたファイルを**読む**なら、その中に別言語の表現があっても目視で捕まる。

関連パターンとして、**規範文と既知の非適合は同じ文書に隣接させる**ことがある。別の PR では最上位仕様書に「consumers must accept both forms」という規範文を追加しつつ、同じ PR の rationale には「現行形式では consumer が候補を抽出しない」という既知の例外を書いた。上位文書だけを読む読み手には「既に満たされている」と読める。**上位文書ほど例外の併記が要る。**

**適用条件**: 実装変更で前提が変わり、それを述べている散文を更新するとき。英日ペア文書・多言語 README・上位仕様書を持つリポジトリでは、掃き出しの完了判定に片方の言語の grep だけを使わない。

## 関連ページ

- [散文修正の完了検査は「主張した概念」で走査する（逆引き検査）](../heuristics/reverse-lookup-concept-sweep-for-prose-fixes.md)
- [強制層の機械化は裁量を消すが依存を消さない](../heuristics/mechanization-moves-dependency-not-removes-it.md)

## ソース

- [PR #2074 review results](../../raw/reviews/20260731T111118Z-pr-2074.md)
- [PR #2074 fix results (cycle 1)](../../raw/fixes/20260731T114035Z-pr-2074.md)
