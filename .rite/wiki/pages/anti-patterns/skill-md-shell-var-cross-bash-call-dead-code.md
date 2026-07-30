---
type: "anti-patterns"
title: "SKILL.md 新規セクションでシェル変数を Bash 呼び出し間の値受け渡しに使うと dead code 化する"
domain: "anti-patterns"
description: "SKILL.md（プロンプト実行体）の新規セクションで、別 Bash tool 呼び出しをまたぐ値受け渡しにシェル変数（$var）を使うと、Bash ツール呼び出し間でシェル状態が保持されないため常に空文字になり、依存する検出ロジック全体が dead code 化する。同一ファイル内に既存規約が明記されていても、近傍コードを確認せず新規セクションを書くと典型的にこの非対称が発生する。"
created: "2026-07-23T06:38:31Z"
updated: "2026-07-23T06:38:31Z"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260723T052236Z-pr-1975.md"
  - type: "fixes"
    ref: "raw/fixes/20260723T052849Z-pr-1975.md"
tags: ["skill-md", "cross-bash-call", "shell-variable", "placeholder-convention", "dead-code", "code-review-convergence"]
confidence: high
---

# SKILL.md 新規セクションでシェル変数を Bash 呼び出し間の値受け渡しに使うと dead code 化する

## 概要

SKILL.md（プロンプト実行体）の新規セクションで、別 Bash tool 呼び出しをまたぐ値受け渡しにシェル変数（`$var`）を使うと、Bash ツール呼び出し間でシェル状態が保持されないため常に空文字になり、依存する検出ロジック全体が dead code 化する。同一ファイル内の他セクションが既にこの規約（LLM が会話コンテキストの `[CONTEXT]` marker を読み `{placeholder}` 形式に literal 置換する）を明記していても、近傍コードの規約を確認せず新規セクションを書くとこの非対称が発生する。

## 詳細

### 発生背景

`/rite:recover` に「未完了事項の検出」セクションを新規追加した際、検出条件のゲートを `[ "$resolved_phase" = "cleanup" ]` のようにシェル変数参照で書いてしまった。しかし `resolved_phase` は先行する別の Bash tool 呼び出しの中で確定した値であり、Claude Code の Bash ツールは呼び出しごとに独立したシェルプロセスを起動するため、次のブロックでは `$resolved_phase` は常に未定義（空文字）になる。結果として `[ "" = "cleanup" ]` は常に偽となり、検出ロジック全体が実行されない dead code になっていた。

このバグは起点事例の review cycle 1 で 3 名のレビュアーが独立に検出した（CRITICAL）。当該 `recover.md` ファイル自身が他のセクションで「Claude Code の Bash ツール間でシェル変数は保持されない。値を跨いで渡す唯一の正規経路は、LLM が前の Bash tool 出力の `[CONTEXT] KEY=value` marker を読み取り、後続の bash ブロックへ `{placeholder}` 形式で literal 置換することである」という規約を明記していたにもかかわらず、新規セクションだけがこれを踏襲していなかった。

### 根本原因

「近傍の既存コードの規約を確認せず新規コードを書く」という典型的な失敗パターン。新規セクションは論理的には正しくても、実行モデル（プロンプト実行体としての SKILL.md は Bash tool 呼び出し単位でシェル状態がリセットされる）を踏まえた記述規約に従わないと、静的には気づきにくい形で機能全体が無効化される。

### 修正方法

`$resolved_phase` のようなシェル変数参照を、`{resolved_phase}` / `{issue_arg}` のような LLM 置換 placeholder に置き換えた。あわせて、静的契約テスト（grep ベース）に `assert_not_grep` で旧来のシェル変数参照形式（`[ "$resolved_phase" = "cleanup" ]`）が再出現しないことを pin し、回帰を構造的に防止した。

### 予防

SKILL.md に新規セクションを追加する際は、同一ファイル内の類似ブロック（特に複数 Bash tool 呼び出しにまたがる値受け渡しを行っている既存セクション）を必ず grep などで確認し、その記法（シェル変数か `{placeholder}` か）に整合させる。「動く（ように見える）記述」ではなく「既存の実行モデル規約と対称な記述」を目標にする。

## 関連ページ

- [新規 helper は既存 sibling の安全規約に整合させる（trap・tree 解決・制御文字無害化）](../heuristics/new-helper-conform-to-sibling-safety-conventions.md)

## ソース

- [PR #1975 review results](../../raw/reviews/20260723T052236Z-pr-1975.md)
- [PR #1975 fix results](../../raw/fixes/20260723T052849Z-pr-1975.md)
