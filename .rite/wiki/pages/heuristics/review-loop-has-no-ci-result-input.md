---
type: "heuristics"
title: "review ループは CI の結果を実測入力に持たない"
domain: "heuristics"
description: "allowed failure の CI ジョブは workflow を success にする一方でマージ可否を UNSTABLE に落とす。差分スコープのレビューは CI の check 結果を読まないため、初回 push から落ちているテストが複数 cycle を素通りする。"
created: "2026-09-06T16:10:23Z"
generated: { by: "rite-wiki-ingest/claude-opus-5[1m]", at: "2026-09-06T16:10:23Z" }
sources:
  - type: "reviews"
    resource: "raw/reviews/20260906T155431Z-pr-2582.md"
tags: ["review-loop", "ci", "blind-spot", "merge-gate"]
confidence: high
---

# review ループは CI の結果を実測入力に持たない

## 概要

`continue-on-error: true` を付けた CI ジョブは workflow 全体を success にするが、マージ可否の判定は UNSTABLE に落ちる。レビュー ⇄ 修正のループは差分とローカル実行だけを入力にしており、CI の check 結果を参照する経路を持たない。結果として、初回 push から落ちているテストが複数 cycle のレビューを一度も指摘されずに通過し、マージ直前のゲートで初めて露出する。

## 詳細

### 何が構造的に欠けているか

レビューの実測は「reviewer がその場で走らせたもの」に閉じている。CI は別のホスト・別の実装（macOS の bwk awk など）で走るため、ローカルで緑のものが CI で赤いという状態はレビュー側からは見えない。allowed failure はその赤を workflow の成否から切り離すので、緑の workflow バッジは何も保証しない。

### 実務上の対処

- レビューを回す前に、対象 PR の check 結果（allowed failure のジョブを含む）を 1 度読む
- allowed failure のジョブを増やすときは、その失敗を誰が読むのかを同時に決める
- マージゲートだけが最後の防波堤になっている状態は、cycle 数に比例して手戻りを増やす

## 関連ページ

- [GNU 形式の `sed -i '<expr>' file` は BSD sed で fixture を書き換えないまま失敗する](../anti-patterns/gnu-sed-inplace-silently-noop-on-bsd.md)
- [差分スコープのレビューは差分の外を見ない](./differential-scope-review-blind-outside-diff.md)

## ソース

- [レビュー結果](../../raw/reviews/20260906T155431Z-pr-2582.md)
