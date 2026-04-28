---
title: "結果論的弁明の論理破綻: 順序逆転で結果不変なのに『悪化する』と説明する実装ノート"
domain: "anti-patterns"
created: "2026-04-28T18:55:00+00:00"
updated: "2026-04-28T18:55:00+00:00"
sources:
  - type: "fixes"
    ref: "raw/fixes/20260428T184201Z-pr-706.md"
  - type: "reviews"
    ref: "raw/reviews/20260428T183538Z-pr-706.md"
tags: ["prose-design", "logical-fallacy", "implementation-note"]
confidence: high
---

# 結果論的弁明の論理破綻: 順序逆転で結果不変なのに『悪化する』と説明する実装ノート

## 概要

「順序を逆転すると X が悪化する」と説明する実装ノートが、実際に逆転しても X が悪化しない (結果不変) 場合、reviewer LLM が説明を信じて誤った重要性付けをするリスクが発生する。意味的階層 / substring 衝突 / 計算コスト等の **3 つの本質的意義** で順序の本質を説明することで論理整合性を担保するのが canonical 対策。

## 詳細

### 失敗モード

PR #706 cycle 1 (MEDIUM F-02) で実測。`_reviewer-base.md` の Whitelist 適用順序の実装ノートで「順序逆転で false positive 増加」と説明していた。順序は以下の 4 段階:

1. SoT Whitelist
2. rite-config.yml 拡張
3. 一般辞書
4. プロジェクト独立登場頻度

しかし順序 1 と順序 3 は **両方とも「許容」へ進む判定** のため、入れ替えても結果不変 (どちらの順序でも同じトークンが許容される)。「順序逆転で false positive 増加」という説明は **論理的に成立しない弁明** であり、reviewer LLM が説明を信じて順序の重要性を過大評価する経路が成立する。

### Anti-pattern の構造

「順序を逆転すると X が悪化する」という結果論的弁明は以下の構造で論理破綻する:

1. 各段階が同じ判定 (許容 / 拒否) へ進む場合、順序入れ替えで結果は不変
2. 結果が不変なのに「順序逆転で X が悪化」と説明すると、説明が **後付けの正当化** になる
3. reviewer LLM は説明を literal に信じるため、順序の本質的意義を誤解する経路を作る

### 検出手段

- 実装ノートで「順序逆転で X が悪化」と説明している箇所を grep
- 各段階の判定を `decision_tree` で書き出し、同じ判定へ進む段階の入れ替えで結果が変わらないことを確認
- 結果が変わらないのに「悪化」と説明されていれば結果論的弁明 anti-pattern

### Canonical 対策

「順序の本質的意義」は以下の 3 観点で説明する:

1. **意味的階層 (semantic hierarchy)**: SoT > project config > general dictionary > heuristic という認識的優先度を反映 (許容判定の根拠が強い順)
2. **Substring 衝突 (substring collision)**: 短い token が長い token に substring matching される経路を避ける (例: `cycle` が `cycle-time` に matching)
3. **計算コスト (computational cost)**: 早期 return で expensive heuristic を避ける (頻度計算等の高コスト判定を最後に置く)

これら 3 観点は **入れ替えで結果が変わる** ため、論理整合性が担保される。

## 関連ページ

- [散文で宣言した設計は対応する実装契約がなければ機能しない](./prose-design-without-backing-implementation.md)
- [SoT-reviewer 表現 drift: pos/neg 方向の差で派生記述が silent drift する](./sot-reviewer-expression-drift.md)

## ソース

- [PR #706 fix results (cycle 1)](../../raw/fixes/20260428T184201Z-pr-706.md)
- [PR #706 review results (cycle 1)](../../raw/reviews/20260428T183538Z-pr-706.md)
