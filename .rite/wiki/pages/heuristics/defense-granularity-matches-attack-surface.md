---
type: "heuristics"
title: "防御は攻撃面と同じ粒度で張る — 過剰防御は「安全側」ではなく別の実害"
domain: "heuristics"
promote: rite-plugin
description: "注入・詐称への防御（中和・棄却ガード）を攻撃が実際に成立する形より広い範囲へ適用すると、**正当な値を棄却・破壊する別の実害**になる。"
created: "2026-08-05T09:26:00+09:00"
updated: "2026-08-05T09:26:00+09:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260804T151916Z-pr-2111-cycle4.md"
  - type: "fixes"
    ref: "raw/fixes/20260804T152800Z-pr-2111-cycle4.md"
  - type: "reviews"
    ref: "raw/reviews/20260804T182250Z-pr-2111.md"
  - type: "fixes"
    ref: "raw/fixes/20260804T183250Z-pr-2111.md"
tags: ["sanitization", "over-neutralization", "attack-surface", "free-text", "closed-domain", "injection"]
confidence: high
---

# 防御は攻撃面と同じ粒度で張る — 過剰防御は「安全側」ではなく別の実害

## 概要

注入・詐称への防御（中和・棄却ガード）を攻撃が実際に成立する形より広い範囲へ適用すると、**正当な値を棄却・破壊する別の実害**になる。「広めに守っておけば安全側」は成立しない。攻撃ベクタが literal な連なり（`](` 等）でしか成立しないなら、中和も同じ粒度に絞る。同一 PR の review⇄fix ループで**2 回独立に再現した**強い経験則。

## 詳細

### 再現 1: 形状ヒューリスティックの free text 転用（cycle 4）

placeholder residue gate が「brace で始まり brace で終わる」形状ヒューリスティックを free text（title/description）に転用し、正当な brace 含みタイトルを棄却した。

- **修正**: residue 検出は呼び出し側が渡す literal（`{title}` 等）との **exact 突合**で必要十分。呼び出し側が未置換時に literal をそのまま渡す構造なら、形状判定は不要
- **境界**: 形状判定が許されるのは enum・ブランチ名のような**閉じた値域**のみ

### 再現 2: リンク詐称対策の全 `]` 中和(cycle 2/run 2)

title 内のリンク構文 `](pages/…)` による同定キー詐称への対策が、title 内の**すべての** `]` を `&#93;` へ中和したため、詐称ベクタと無関係な `[CONTEXT]` / `.errors[]` / コードスパン内 `[[:cntrl:]]` まで潰し、実 Wiki に実在する 3 ページで GFM のリンク範囲が壊れることを reviewer が `gh api /markdown` で実測した。

- **修正**: 詐称は `](` の literal 連なりでしか成立しないため、中和条件を `](` 限定に絞る。攻撃は閉じたまま回帰が消える
- **実測の重要性**: 「実データ（本 repo の Wiki 364 ページ）に対する回帰の有無」を rendering API で実測したことが、過剰中和を「安全側の保守的選択」ではなく「実害」として確定させた

### 判断手順

1. 攻撃・詐称が**成立する最小の字面**（literal 連なり・値域）を特定する
2. 防御の適用条件をその字面・値域に一致させる
3. 防御対象が free text なら、正当値に防御が誤発火しないかを**実データ全件**で確認する
4. 防御を広げたくなったら、「広げた分が棄却する正当値のクラス」を先に列挙する

## 関連ページ

- [過剰マッチ防止の精緻化修正は、実装が許容する全形状を再確認しないと過小マッチという別の欠陥を生む (振り子現象)](../anti-patterns/precision-tightening-pendulum-regression.md)
- [境界での無害化は下流ツールの別エスケープ意味論までは保証しない（quoted heredoc → awk -v 伝播）](../anti-patterns/sanitization-gap-downstream-tool-escape-semantics.md)

## ソース

- [Review cycle 4: residue gate over-generalization and marker contract mismatch](../../raw/reviews/20260804T151916Z-pr-2111-cycle4.md)
- [Fix cycle 4: exact-match residue gate, honest markers, precondition checks](../../raw/fixes/20260804T152800Z-pr-2111-cycle4.md)
- [PR #2111 review results (cycle 2)](../../raw/reviews/20260804T182250Z-pr-2111.md)
- [PR #2111 fix results (cycle 2)](../../raw/fixes/20260804T183250Z-pr-2111.md)
