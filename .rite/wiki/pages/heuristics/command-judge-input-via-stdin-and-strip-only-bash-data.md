---
type: "heuristics"
title: "コマンド文字列の判定器には入力を stdin で渡し、前処理は bash がデータとして扱う部分だけを除く"
domain: "heuristics"
description: "判定器へ任意長のコマンド文字列を argv で渡すと 1 引数の上限で大きな入力が落ちる。前処理で後段のパーサが正しく扱える要素まで削ると後段の正しさを壊し、引用符なし区切り語の heredoc 本文をデータとみなすと実行される置換を見逃す。"
created: "2026-09-29T16:54:00Z"
generated: { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-29T16:54:00Z" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20260929T135408Z-pr-3446.md"
  - type: "fixes"
    resource: "raw/fixes/20260929T140715Z-pr-3446.md"
tags: ["shell", "guard", "heredoc", "argv"]
confidence: medium
---

# コマンド文字列の判定器には入力を stdin で渡し、前処理は bash がデータとして扱う部分だけを除く

## 概要

判定器へ任意長のコマンド文字列を argv で渡すと 1 引数の上限で大きな入力が落ちる。前処理で後段のパーサが正しく扱える要素まで削ると後段の正しさを壊し、引用符なし区切り語の heredoc 本文をデータとみなすと実行される置換を見逃す。

## 詳細

hook が Bash tool のコマンド文字列を受け取り、別の判定器（パーサ）に渡して許否を決める構成で、次の 3 点が同時に問題になった。

**入力の渡し方**: bash の前処理をやめて生のテキストを判定器の argv に渡す形へ変えると、Linux の 1 引数の上限（128KiB）を新しく持ち込む。長い heredoc を含むコマンドはこの上限を越えうる。任意長のテキストは stdin で渡す。テスト harness 側（`jq --arg` で入力を組み立てる等）も同じ上限を持つので、境界を越える入力のテストでは harness も stdin にする。

**前処理の範囲**: heredoc やコメントを前処理で一律に削ると、後段のパーサがすでに正しく扱える要素まで消え、後段の判定が崩れる。前処理は bash が本当にデータとして扱う部分（引用符付き区切り語の heredoc 本文）だけを除き、コメントの判定などは後段に任せる。

**heredoc 本文の扱い**: 引用符なし区切り語の heredoc 本文は bash が展開し、その中のコマンド置換を実行する。本文を一律にデータとみなすと、本文の中に置いた置換を見逃す。置換を含む本文は後段に読ませる形で残す。

## 関連ページ

- [検査用のシェル字句解析は判定対象を標準形に絞り、それ以外を fail-closed にする](./inspection-parser-narrow-to-standard-form-fail-closed.md)
- [シェル字句の判定器は bash を実際に実行する差分検証で規則を合わせ、字句器を 1 つに集める](../patterns/shell-lexer-bash-oracle-differential-validation.md)

## ソース

- [argv 渡しと前処理の範囲を指摘したレビュー結果](../../raw/reviews/20260929T135408Z-pr-3446.md)
- [stdin 渡しと前処理の縮小を行った fix 結果](../../raw/fixes/20260929T140715Z-pr-3446.md)
