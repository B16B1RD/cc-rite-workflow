---
type: "heuristics"
title: "ローカル検証では CI が回すすべてのテストスイートを回す"
domain: "heuristics"
description: "ローカルで一部のテストスイートだけを回すと、CI だけが回すスイートの失敗がレビュー後の CI で初めて見つかり、修正サイクルを 1 回余計に回す。fix の全体検証には CI と同じスイートをすべて登録する。"
created: "2026-10-10T01:04:42Z"
generated: { by: "rite-wiki-ingest/claude-opus-5-5", at: "2026-10-10T01:04:42Z" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20261010T000858Z-pr-3735.md"
  - type: "fixes"
    resource: "raw/fixes/20261010T001835Z-pr-3735.md"
tags: ["verification", "ci", "test-suite", "fix-plan"]
confidence: high
promote: rite-plugin
---

# ローカル検証では CI が回すすべてのテストスイートを回す

## 概要

ローカルで一部のテストスイートだけを回すと、CI だけが回すスイートの失敗がレビュー後の CI で初めて見つかり、修正サイクルを 1 回余計に回す。fix の全体検証には CI と同じスイートをすべて登録する。

## 詳細

このリポジトリの CI はテストを 2 系統回す。hook 側のスイートと、scripts 側のスイート（棚卸しテストなどの契約テストを含む）である。実装時と fix の全体検証で hook 側のスイートだけを回していたため、skill の文言変更が scripts 側の棚卸しテストを落としたことに気づかず、レビューが mergeable と判定した後の CI で初めて失敗が出た。

fix の計画では、全体検証（`kind: full`）に CI のワークフローが実行するスイートをすべて登録する。1 本のコマンドに `&&` でつなぐのではなく、スイートごとに別の検証として登録すると、どちらが落ちたかが記録に残る。PR 本文の検証欄にも、実際に回したスイートとその HEAD を書く。

CI の構成が変わったら、ローカル検証の登録も同じ変更で見直す。

## 関連ページ

- [否定文でもツール名を書くと、語の出現数で数える棚卸しテストに 1 件と数えられる](../anti-patterns/negated-tool-name-counted-by-inventory-test.md)

## ソース

- [レビュー結果](../../raw/reviews/20261010T000858Z-pr-3735.md)
- [fix 結果](../../raw/fixes/20261010T001835Z-pr-3735.md)
