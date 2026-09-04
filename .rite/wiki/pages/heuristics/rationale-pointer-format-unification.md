---
type: "heuristics"
title: "rationale ポインタ形式は bare `rationale:` 形式に統一する"
domain: "heuristics"
promote: rite-plugin
reference: "plugins/rite/references/wiki-promotions/heuristics/rationale-pointer-format-unification.md"
description: "実行パスの設計解説(rationale)を references へ退避する際、元位置に残すポインタの形式が 3 種類(bare `rationale: <path>#<anchor>` / markdown link `[text](path#anchor)` / hybrid `rationale: [text](path#anchor)`)に分裂しやすい。"
created: "2026-07-17T02:44:35Z"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260717T021655Z-pr-1882.md"
  - type: "reviews"
    resource: "raw/reviews/20260717T014643Z-pr-1882.md"
tags: []
confidence: medium
generated: { by: "rite-wiki-ingest/unknown", at: "2026-07-17T02:44:35Z" }
---

# rationale ポインタ形式は bare `rationale:` 形式に統一する

## 概要

実行パスの設計解説(rationale)を references へ退避する際、元位置に残すポインタの形式が 3 種類(bare `rationale: <path>#<anchor>` / markdown link `[text](path#anchor)` / hybrid `rationale: [text](path#anchor)`)に分裂しやすい。全形式が anchor 解決するため機能上は等価だが、5 レビュアー中 4 名が informational として繰り返し指摘しており、bare 形式への統一が規約明文化に値する。

## 詳細

rationale 退避 PR のレビューで観測された事実:

- 単一 PR 内で 3 形式が混在した: (1) bare `rationale: <path>#<anchor>`(CLAUDE.md スキル行数原則が例示する canonical 形式)、(2) markdown link のみ、(3) hybrid(`rationale:` prefix + markdown link の二重形式)
- `distributed-fix-drift-check.sh` Pattern 4 は bare / markdown link の両形式を first-class でサポートしており、混在しても broken-link リスクはない(hybrid は markdown-link 経路で検証される)
- 実害はないが、(a) grep ベースの保守(`rationale:` で全ポインタを列挙する等)が hybrid / bare 混在で不完全になる、(b) 将来ポインタ形式を機械 lint する場合に 3 形式対応が必要になる、という retouch コストが残る

**推奨**: 退避作業の Issue / 計画段階で「ポインタは bare `rationale: references/<file>.md#<anchor>` 形式」と明文化する。既存の markdown link 形式を一括変換する必要はない(機能等価のため)が、新規追加分は bare 形式に揃える。hybrid 形式(prefix と link の二重)は情報が重複するためどちらかに寄せる。

## 関連ページ

- [Asymmetric Fix Transcription (対称位置への伝播漏れ)](../anti-patterns/asymmetric-fix-transcription.md)

## ソース

- [レビュー結果](../../raw/reviews/20260717T021655Z-pr-1882.md)
- [レビュー結果](../../raw/reviews/20260717T014643Z-pr-1882.md)
