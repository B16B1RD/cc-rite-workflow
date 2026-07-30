---
title: "fail-fast 構造の記述は構文・検証対象・場所の 3 軸で分離する"
domain: "patterns"
created: "2026-06-09T19:55:00+00:00"
updated: "2026-06-09T19:55:00+00:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260609T195111Z-pr-1327.md"
tags: []
confidence: medium
---

# fail-fast 構造の記述は構文・検証対象・場所の 3 軸で分離する

## 概要

bash の fail-fast 構造をドキュメントで記述するときは「構文（case `*)` arm か if/elif/else の else 分岐か）」「検証対象（どの変数の fail-fast か）」「場所（どの step / block に分岐が実在するか）」の 3 軸を分離して書く。軸を混同した一括表現（例:「ステップ 5.1 / 5.2 で `*` arm の fail-fast 検証」）は複数軸で同時に不正確になり、読者が実コードと突合した瞬間に破綻する。

## 詳細

wiki-patterns.md の ingest.md branch_strategy fail-fast 記述を修正した際に実測:

- **3 軸の同時誤り**: 旧記述は (a) 構文軸 — 実体は if/elif/else の `else` 分岐なのに `case *)` arm と記述、(b) 場所軸 — ステップ 5.2 には branch_strategy の fail-fast 分岐が存在しない（`if same_branch` 単独分岐、未知値は先行する 5.1 の else が catch）のに「5.1 / 5.2 で」と記述、の二重の不正確を含んでいた。検証対象軸でも、5.1 内に実在する `case *)` fail-fast は `commit_rc` / `commit_msg` gate 用であり branch_strategy 検証ではなかった。
- **case arm の 2 種別**: bash の case arm には「bare `*)` catch-all arm」と「glob パターン arm（例: `*"{placeholder}"*|...`）」があり、「`case *)` fail-fast」と一括ラベルすると後者を誤記述する。cycle 1 で prompt-engineer / tech-writer が独立に同一の精度指摘を出し、arm 種別を分離記述（`commit_msg` gate は placeholder パターン arm、`commit_rc` は `*)` arm）して解消した。
- **検証手法**: 記述修正の正否は対象 bash block の Read による突合が決定打。「両 block が戦略に関わらず順次実行される」ことの証拠として、5.1 の `elif same_branch) :`（明示 no-op arm）の存在が実行順序の主張を裏付けた。
- **同一行 trivial 推奨の即時採用**: 記述正確性が主題の PR で既知の不正確を残さないため、reviewer 推奨を別 Issue 化せず同一 PR 内で即採用し 2 cycle で収束した。

## 関連ページ

- [Issue 対応案の番号参照を未検証のまま転記すると事実誤認が伝播する](../anti-patterns/unverified-issue-proposal-reference-transcription.md)
- [canonical reference 文書のサンプルコードは canonical 実装と一字一句同期する](./canonical-reference-sample-code-strict-sync.md)

## ソース

- [PR #1327 review results](../../raw/reviews/20260609T195111Z-pr-1327.md)
