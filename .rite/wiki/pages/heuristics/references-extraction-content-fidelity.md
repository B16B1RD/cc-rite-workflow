---
title: "References 抽出時は引用先 SoT の内容を Read tool で verify する"
domain: "heuristics"
created: "2026-05-04T05:30:00+00:00"
updated: "2026-05-04T05:30:00+00:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260504T050342Z-pr-802.md"
  - type: "fixes"
    ref: "raw/fixes/20260504T050654Z-pr-802.md"
tags: []
confidence: high
---

# References 抽出時は引用先 SoT の内容を Read tool で verify する

## 概要

Refactor 系 PR で `commands/issue/references/` に新規ファイルを抽出する際、引用先 references ファイルに書かれている Issue 番号や AC phrase を **推測ベースで関連付けると silent factual divergence を生む**。引用前に Read tool で引用先 SoT の該当箇所を verify することで、読者が末尾誘導された SoT で乖離内容を見つける UX 問題を回避する。

## 詳細

PR #802 (Issue #773 PR 8/8) で 2 つの failure mode が cycle 1 で同時に検出され、いずれも root cause は「**引用先 SoT の内容を verify せず推測で関連付けた**」こと:

1. **factual divergence**: 新規 `bulk-create-pattern.md` で他 references (`regression-history.md` / `sub-skill-handoff-contract.md`) の Issue 番号を引用したが、引用先 references の実際の content と乖離していた。読者が末尾誘導された SoT 先で「言及されているはずの内容が見つからない」UX 障害を起こす。

2. **context-bleeding (理由付け文)**: NFR-2 (本体保持) の根拠として `create.md` 本体由来の **AC-3 grep 4 phrase** を `create-decompose.md` の references 抽出文で引用したが、対象ファイル (`create-decompose.md`) には該当 phrase が存在しない。理由付けは **対象ファイルの実 invariant** に基づくべき (本 PR 例: `create-decompose.md` の AC-1 enforcement boundary)。

### 適用ルール

- **新規 references ファイルで Issue 番号 / AC phrase を引用する場合**、引用先 SoT (regression-history.md / sub-skill-handoff-contract.md 等) の該当箇所を Read tool で verify してから引用する
- **理由付け文を書く場合**、引用元 (`create.md` 等の他ファイル) 由来の invariant を引用しない。対象ファイルの実 invariant のみ参照する
- 推測ベースの関連付けは silent factual divergence を生むため、Read tool による verify を必須化する

### 関連 failure mode

- 引用先 SoT の path 存在のみ check する `sot-path-reference-existence-check.md` heuristic は **存在チェックのみ** で content fidelity は保証しない。本 heuristic は content の verify まで踏み込む補完的な原則。

## 関連ページ

- [SoT Path Reference Existence Check](../heuristics/sot-path-reference-existence-check.md)

## ソース

- [PR #802 review (cycle 1)](../../raw/reviews/20260504T050342Z-pr-802.md)
- [PR #802 fix (cycle 1)](../../raw/fixes/20260504T050654Z-pr-802.md)
