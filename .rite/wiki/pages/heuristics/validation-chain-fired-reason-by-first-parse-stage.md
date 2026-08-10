---
title: "Validation chain の発火 reason は最初に入力を parse する段階で決まる（暗黙 validation が後続 check を unreachable 化）"
domain: "heuristics"
description: "validation chain の error reason を doc 化する際は「どの段階が最初に入力を parse するか」が実発火 reason を決める。"
promote: rite-plugin
created: "2026-06-01T06:01:05+00:00"
updated: "2026-06-01T08:15:52+00:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260601T054111Z-pr-1226.md"
  - type: "reviews"
    ref: "raw/reviews/20260601T073303Z-pr-1228.md"
tags: []
confidence: medium
---

# Validation chain の発火 reason は最初に入力を parse する段階で決まる（暗黙 validation が後続 check を unreachable 化）

## 概要

validation chain の error reason を doc 化する際は「どの段階が最初に入力を parse するか」が実発火 reason を決める。jq による値注入 (`jq '.timestamp = $ts'`) は入力 JSON の parse を要するため暗黙の syntactic validation を兼ね、後続の明示的 `jq empty` check は syntactically invalid JSON の経路では到達不能 (effectively unreachable) な defense-in-depth backstop になる。reason 説明文を実挙動に整合させる doc 修正は、reason 文字列 / `[CONTEXT]` emit を不変に保てば非ブロッキングで安全。

## 詳細

起点事例で `review-result-save.sh` の validation chain (`cat` → `jq` timestamp 注入 → `jq empty`) を 3 reviewer (prompt-engineer / error-handling / code-quality) が独立にトレースし、`review.md` の reason 説明と実挙動の乖離を整理した (0 blocking finding)。

### 観察された制御フロー

1. `cat` で生成済み JSON を読む
2. `jq '.timestamp = $ts'` で timestamp を注入する — **この段階で入力 JSON を parse・再シリアライズする**
3. `jq empty` で syntactic validity を検査する (`json_invalid` reason の発火点)

syntactically invalid JSON（literal substitute 漏れを含む）は **step 2 の注入段階で parse に失敗し `write_failure` として fail する**。よって step 3 の `jq empty` (= `json_invalid`) には到達しない。従来の doc は `json_invalid` を「literal substitute 漏れ検出」と記述していたが、実際の発火 reason は `write_failure` であり、`json_invalid` は effectively unreachable な backstop だった。

### Observability surface の三者整合（follow-up）

同一の validation chain には実発火 reason を説明する observability surface が 3 つある: (a) runtime WARNING メッセージ、(b) 実装上部の inline コメント、(c) canonical doc (`review.md`)。起点事例で (b)(c) を実挙動 (`json_invalid` は effectively unreachable、実発火は `write_failure`) に整合させたが、(a) runtime WARNING の括弧書きは「literal substitute 漏れの可能性」のまま残り語感が drift していた。follow-up で (a) を「(注入後に外部要因で破損した稀ケース。通常の literal substitute 漏れは upstream の `write_failure` で検出済)」へ補足し、3 surface を揃えた (3 reviewer / 0 finding)。

- **実挙動を doc 化したら同概念の全 observability surface を同時に整合させる**。runtime メッセージ・inline コメント・canonical doc は同じ failure semantics を別レイヤーで説明する [Asymmetric Fix Transcription](../anti-patterns/asymmetric-fix-transcription.md) の対称セットであり、1 surface だけ旧文言が残ると観測者を誤誘導する。系譜 #1198→#1199→#1226→#1227 はこの 3 surface 整合を段階的に完成させた連鎖。
- **reason 文字列・`[CONTEXT]` emit・非ブロッキング契約 (`exit 0`) を verbatim 保持すれば surface 文言補足は安全**。文言補足 PR は WARNING の括弧書き 1 行のみ変更し、制御フロー・`jq empty` check 自体・reason 文字列は不変に保った。

### 一般化できる経験則

- **発火 reason は「最初に入力を consume/parse する段階」で決まる**。後段に明示的な検査 step があっても、前段の操作が同じ property を暗黙に検証していれば、その失敗クラスでは後段が unreachable になる。
- **値の注入・変換は暗黙の syntactic validation を兼ねる**。`jq`・`yq`・JSON/YAML parser を介した値の読み書きは、それ自体が構文検査として機能する。後続に置いた「念のための」明示 check は、同一失敗クラスに対しては defense-in-depth backstop であって実発火経路ではない。
- **error reason を doc 化する前に control flow をトレースする**。observability ドキュメント (reason 説明・`[CONTEXT]` emit の意味づけ) は「どの段階が最初に失敗を捕捉するか」を実装で裏取りしてから書く。これは [Documentation review は対応する実装側 (commands/scripts/templates) の grep verify を必須 step とする](./docs-review-implementation-grep-verification.md) の reason-documentation への適用形。
- **整合 doc 修正は reason 文字列 / sentinel emit を verbatim 保持すれば非ブロッキング**。実行順序・reason 文字列・`[CONTEXT]` emit を変えず、説明文とコメントのみを実挙動に合わせる修正は機能変更を伴わず安全。

## 関連ページ

- [Documentation review は対応する実装側 (commands/scripts/templates) の grep verify を必須 step とする](./docs-review-implementation-grep-verification.md)
- [散文で宣言した設計は対応する実装契約がなければ機能しない](../anti-patterns/prose-design-without-backing-implementation.md)

## ソース

- [PR #1226 review results](../../raw/reviews/20260601T054111Z-pr-1226.md)
