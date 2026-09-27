---
type: "heuristics"
title: "hook の失敗枝はソース grep ではなく実行で検証する"
domain: "heuristics"
description: "WARNING 文字列がソースに存在するだけでは、mkdir 失敗などの else 枝が実行時に辿られることは保証できない。対象パスをファイルにして hook を走らせ、stderr と終了コードを assert する。"
created: "2026-08-29T08:20:00Z"
generated: { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-27T04:21:02Z" }
verified:
  - { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-09-27T04:21:02Z" }
sources:
  - type: "fixes"
    resource: "raw/fixes/20260828T170214Z-pr-2446.md"
  - type: "reviews"
    resource: "raw/reviews/20260927T040057Z-pr-3210.md"
tags: []
confidence: high
promote: rite-plugin
---

# hook の失敗枝はソース grep ではなく実行で検証する

## 概要

WARNING 文字列がソースに存在するだけでは、mkdir 失敗などの else 枝が実行時に辿られることは保証できない。対象パスをファイルにして hook を走らせ、stderr と終了コードを assert する。

## 詳細

session-start が `STATE_ROOT/.rite` の mkdir に失敗したとき、nested gitignore を書かずに WARNING を出して session start を止めない。この else 枝を `grep -c 'nested gitignore not written'` だけでピンすると、文字列の存在は保証されるが、hook がその枝に入ることと rc=0 で戻ることは保証されない。

実行テストは TC-1968-03 と同型の衝突 fixture を使う。`.rite` をファイルにして `mkdir -p` を失敗させ、stderr に当該 WARNING があり、パスがファイルのまま残り、hook が rc=0 で終わることを assert する。read-only filesystem や chmod に依存しない。

静的 grep は文字列退行の防御として残してよい。失敗枝の契約そのものは実行テストが担う。

### 行の形に依存する否定 pin は arm の改行で空振りする

「特定の終了コードの arm でだけ後始末を省く」ことを、「同じ行に arm のラベルと `exit 1` が並んでいないか」を見る静的な否定 grep で固定していた。この pin は arm を複数行に書き分けただけで一致しなくなり、違反があっても通る。helper を stub と組み合わせて実際に走らせ、終了コードと後に残るファイルの有無を assert する挙動テストへ置き換えると、ソースの行の形に関係なく検出できる。

### 全称の契約は arm ごとの値で固定する

「この終了コード以外ではすべて削除する」のような全称の契約を、代表の 1 値だけで確かめると、他の arm へ入れた変異が生き残る。契約が「以外すべて」を名乗るなら、helper が持つ arm の値をループで 1 つずつ流し、各値で期待どおりに振る舞うことを固定する。

## 関連ページ

- [mkdir 成功のみの判定漏れと brace group 未使用によるリダイレクト診断メッセージ漏洩](../anti-patterns/mkdir-success-only-check-and-redirect-diagnostic-leak.md)

## ソース

- [fix 結果](../../raw/fixes/20260828T170214Z-pr-2446.md)
- [静的な否定 pin を挙動テストへ置き換えたレビュー結果](../../raw/reviews/20260927T040057Z-pr-3210.md)
