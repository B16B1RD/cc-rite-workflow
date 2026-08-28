---
type: "heuristics"
title: "hook の失敗枝はソース grep ではなく実行で検証する"
domain: "heuristics"
description: "WARNING 文字列がソースに存在するだけでは、mkdir 失敗などの else 枝が実行時に辿られることは保証できない。対象パスをファイルにして hook を走らせ、stderr と終了コードを assert する。"
created: "2026-08-29T08:20:00Z"
generated: { by: "rite-wiki-ingest/grok-4.6", at: "2026-08-29T08:20:00Z" }
sources:
  - type: "fixes"
    resource: "raw/fixes/20260828T170214Z-pr-2446.md"
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

## 関連ページ

- [mkdir 成功のみの判定漏れと brace group 未使用によるリダイレクト診断メッセージ漏洩](../anti-patterns/mkdir-success-only-check-and-redirect-diagnostic-leak.md)

## ソース

- [PR #2446 fix results](../../raw/fixes/20260828T170214Z-pr-2446.md)
