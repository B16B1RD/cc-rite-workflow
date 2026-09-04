---
type: "anti-patterns"
title: "SKILL.md 新規セクションでシェル変数を Bash 呼び出し間の値受け渡しに使うと dead code 化する"
domain: "anti-patterns"
promote: rite-plugin
reference: "plugins/rite/references/wiki-promotions/anti-patterns/skill-md-shell-var-cross-bash-call-dead-code.md"
description: "SKILL.md（プロンプト実行体）の新規セクションで、別 Bash tool 呼び出しをまたぐ値受け渡しにシェル変数（`$var`）を使うと、Bash ツール呼び出し間でシェル状態が保持されないため常に空文字になり、依存する検出ロジック全体が dead code 化する。"
created: "2026-07-23T06:38:31Z"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260723T052236Z-pr-1975.md"
  - type: "fixes"
    resource: "raw/fixes/20260723T052849Z-pr-1975.md"
  - type: "fixes"
    resource: "raw/fixes/20260829T175418Z-pr-2468.md"
tags: ["skill-md", "cross-bash-call", "shell-variable", "placeholder-convention", "dead-code", "code-review-convergence"]
confidence: high
generated: { by: "rite-wiki-ingest/claude-opus-5", at: "2026-08-30T05:20:00Z" }
verified:
  - by: "rite-wiki-ingest/claude-opus-5"
    at: "2026-08-30T05:20:00Z"
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

### 再発事例: `${var:-}` の既定化が失敗を無言化し、完了報告を誤らせる

同型の失敗が別スキルの新規節で再発した。LLM 層の判定結果（除外対象 ID の集合）を、隣接する
fenced block のシェル変数で helper へ渡す設計にしたところ、値は常に空へ解決され、除外機能が
まるごと no-op になった。悪化要因は受け渡し経路そのものではなく **`${var:-}` による既定化**
にある。空文字が既定として通ってしまうため helper は「除外なし = 全件処理」で正常終了し、
一方で完了報告は「N 件を除外済み」と述べる。**機能が死ぬだけでなく、死んだことを打ち消す
誤報告が同時に成立する。**

このときも同一ファイル内の既存 helper 呼び出しが 6 引数すべてをリテラル置換で渡し、
35 行前で解決済みの state root をわざわざ再解決していた。「各 Bash ブロックは自己完結させる」
という既存慣行の証拠が近傍にあったが、新規節はそれに倣わなかった。

受け渡しはリテラル置換のみを正規経路とし、`[CONTEXT]` marker は監査記録に留める。
値が取れないときに既定へ倒す `${var:-}` は、この経路では**誤報告を作る側**なので書かない。

### 予防

SKILL.md に新規セクションを追加する際は、同一ファイル内の類似ブロック（特に複数 Bash tool 呼び出しにまたがる値受け渡しを行っている既存セクション）を必ず grep などで確認し、その記法（シェル変数か `{placeholder}` か）に整合させる。「動く（ように見える）記述」ではなく「既存の実行モデル規約と対称な記述」を目標にする。

## 関連ページ

- [新規 helper は既存 sibling の安全規約に整合させる（trap・tree 解決・制御文字無害化）](../heuristics/new-helper-conform-to-sibling-safety-conventions.md)

## ソース

- [レビュー結果](../../raw/reviews/20260723T052236Z-pr-1975.md)
- [fix 結果](../../raw/fixes/20260723T052849Z-pr-1975.md)
- [`${var:-}` の既定化が no-op を無言化し完了報告を誤らせた再発事例](../../raw/fixes/20260829T175418Z-pr-2468.md)
