---
type: "patterns"
title: "fail し得る解決と本文の抽出を別関数に分け、fail はコマンド置換の外で呼ぶ"
domain: "patterns"
description: "bash テストの helper が `$(...)` の中で `fail` を呼ぶと、失敗カウンタの加算はサブシェルで消え、呼び出し側には空文字だけが返る。位置の解決（fail し得る）と本文の抽出（fail しない）を別関数に分け、前者をトップレベルで実行してグローバル変数で受け渡すと、失敗はカウンタに残り、下流の assert が別の原因を名乗ることもなくなる。"
created: "2026-09-16T12:09:00Z"
generated: { by: "rite-wiki-ingest/claude-opus-5[1m]", at: "2026-09-16T12:09:00Z" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20260916T114658Z-pr-2910.md"
  - type: "fixes"
    resource: "raw/fixes/20260916T112742Z-pr-2910-fix.md"
tags: ["bash", "test-helpers", "subshell", "fail-loud"]
confidence: high
---

# fail し得る解決と本文の抽出を別関数に分け、fail はコマンド置換の外で呼ぶ

## 概要

bash テストの helper が `$(...)` の中で `fail` を呼ぶと、失敗カウンタの加算はサブシェルで消え、呼び出し側には空文字だけが返る。位置の解決（fail し得る）と本文の抽出（fail しない）を別関数に分け、前者をトップレベルで実行してグローバル変数で受け渡すと、失敗はカウンタに残り、下流の assert が別の原因を名乗ることもなくなる。

## 詳細

### 問題の形

Markdown の見出し直後の fence を切り出す helper は `fence=$(fence_after "$file" "$heading")` の形で呼ばれる。見出しが見つからないとき helper の中で `fail "heading not found"` と書きたくなるが、その `fail` は `$(...)` のサブシェルで実行され、親シェルの `FAIL` カウンタと `FAILED_NAMES` には何も残らない。呼び出し側に届くのは空文字で、次の `[ "$en" = "$ja" ]` が「fence が違う」、トークン検査が「段落に語が無い」と、本当の原因（見出し未検出）とは別の名前で落ちる。旧実装はそもそも未検出を検査せず空文字を返していたので、この二重の隠蔽が起きていた。

### 分け方

fail し得る部分は「見出し行がちょうど 1 回あるか」の判定だけである。これをトップレベルで呼ぶ関数に切り出し、結果はグローバル変数で受け渡す。本文抽出はその整数を受け取るだけで fail 条件を持たないので、従来どおり `$(...)` の中で呼んでよい。

```bash
heading_line() {
  HEADING_LINE=$(grep -nxF -- "$2" "$1" | cut -d: -f1)
  case "$HEADING_LINE" in
    ''|*$'\n'*) fail "heading '$2' is not found exactly once in ${1##*/}"; HEADING_LINE=0 ;;
  esac
}
fence_after() { awk -v n="$1" 'NR == n {f=1; next} …' "$2"; }

heading_line "$file" 'ステータス遷移:'
fence=$(fence_after "$HEADING_LINE" "$file")
```

- `heading_line` はトップレベル（`$(...)` の外）で呼ぶので `fail` のカウンタ加算が親シェルに残る
- 番兵 `HEADING_LINE=0` は `NR == 0` が決して真にならないため、下流が別の場所の fence を拾う経路を作らない。下流の assert も落ちるが、それは count-and-continue 規約どおりで、最初の fail が原因を名指ししている
- グローバル変数で受け渡す形は同じテストファイルの既存 helper（`DRIFT_RC` 等）と同じ流儀で、`$(...)` を避ける目的に適う

### 確認の仕方

見出しを消した複製と、見出し・fence・段落を末尾に複製して 2 回一致にした複製の 2 つの mutant を作り、`heading_line` が `fail` を出力して `HEADING_LINE=0` になること、親シェルの `FAIL` が 0 → 1 → 2 と増えて `FAILED_NAMES` に 2 件残ること、下流の抽出が 0 バイトを返すことを実測する。`grep` の rc（不一致 1 / ファイル不在 2）はどちらも出力が空になって同じ `fail` 経路に落ちるため、rc の分岐を足す必要はない。

## 関連ページ

- [PIPESTATUS はコマンド置換 `$(...)` のサブシェル境界を越えない](../heuristics/pipestatus-subshell-scoping-command-substitution.md)
- [macOS の awk の == は UTF-8 ロケールで照合比較になり、別の日本語文字列を等しいと判定する](../anti-patterns/macos-awk-string-equality-uses-locale-collation.md)

## ソース

- [fail の呼び出し位置とカウンタ保持を mutant で実測したレビュー結果](../../raw/reviews/20260916T114658Z-pr-2910.md)
- [見出し解決と本文抽出を分けた fix 結果](../../raw/fixes/20260916T112742Z-pr-2910-fix.md)
