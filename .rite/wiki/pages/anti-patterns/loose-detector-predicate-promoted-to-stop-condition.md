---
type: "anti-patterns"
title: "緩い検出述語の出力を停止条件へ昇格させてはならない"
domain: "anti-patterns"
description: "「false-positive の WARNING が増えることを許容して silent false-negative を潰す」という設計判断で選ばれた緩い述語は、その緩さを前提にコストが無害と評価されている。その件数を hard fail の入力に使った瞬間に前提が崩れ、誤発火と見逃しを同時に持つ機構になる。起点事例では anchor_unparseable の件数を集約 hard fail の連言に組み込んだ結果、正常系で停止し、かつ通常指摘が 1 件混ざるだけで発火しなくなった。検出層と停止層は入力を共有しない。"
created: "2026-08-01T00:21:06+09:00"
updated: "2026-08-01T00:21:06+09:00"
sources:
  - type: "fixes"
    ref: "raw/fixes/20260731T135712Z-pr-2074.md"
tags: []
confidence: high
---

# 緩い検出述語の出力を停止条件へ昇格させてはならない

## 概要

検出器の述語には「厳しく作ると見逃す」「緩く作ると誤検出する」のトレードオフがあり、可視化目的の述語はしばしば**意図的に緩く**設計される。その正当化は「誤検出のコストは無害な WARNING 1 行」である。この述語の出力件数を、あとから停止条件（hard fail）の入力に使うと、コストが無害だという前提そのものが崩れる。

## 詳細

起点事例の `anchor_unparseable` は、実測アンカーの存在を stage 1 で緩く判定した件数だった。設計文書は「false-positive の WARNING が増えることを許容して silent false-negative を潰す」と明記していた。cycle 2 でこの件数を集約 hard fail の連言（`blocking == 0 ∧ anchor_unparseable > 0 ∧ demoted == anchor_unparseable`）へ組み込んだところ、**両端が同時に壊れた**。

- **誤発火**: 説明文に散文で `Verification:` と書いただけの正常な指摘で停止する（緩い述語がそれを拾うため）。
- **見逃し**: 第 3 連言 `demoted == anchor_unparseable` により、アンカーを持たない通常指摘が 1 件でも同居すると発火せず、実測済み CRITICAL が消えて mergeable になる。

両端が同一の述語に由来するため、レビュアーの推奨も 3 案に割れた。それが**撤去**の決め手になっている（[修正案が失敗モードの交換で割れたら、その機構は測るべき量を測っていない](../heuristics/split-reviewer-recommendations-signal-removal.md)）。本筋の是正——形式崩れアンカーを `measured=false` ではなく「未判定」として blocking のまま扱う 3 値モデル化——は設計変更として別 Issue へ切り出された。

**適用条件**: 既存の検出カウンタを新しいゲート・ブレーカー・fail-closed 判定の入力にしようとするとき。その述語がどういう精度前提で選ばれたかを設計文書で確認し、緩い述語なら停止層には使わない。停止層が必要なら、停止層専用の厳密な述語を別に定義する。

## 関連ページ

- [強制層の機械化は裁量を消すが依存を消さない](../heuristics/mechanization-moves-dependency-not-removes-it.md)
- [修正案が失敗モードの交換で割れたら、その機構は測るべき量を測っていない](../heuristics/split-reviewer-recommendations-signal-removal.md)

## ソース

- [PR #2074 fix results (5 cycle 総括)](../../raw/fixes/20260731T135712Z-pr-2074.md)
