---
type: "anti-patterns"
title: "awk -v 代入はバックスラッシュを剥がす — escape 付きパターンを渡した範囲指定 assert は常に PASS する"
domain: "anti-patterns"
description: "`awk -v var=value` の代入では、value 内のバックスラッシュが**エスケープシーケンスとして解釈され剥がれる**。"
created: "2026-08-08T14:00:41+09:00"
updated: "2026-08-08T17:40:00+09:00"
sources:
  - type: "fixes"
    ref: "raw/fixes/20260808T010121Z-pr-2142.md"
  - type: "reviews"
    ref: "raw/reviews/20260808T013358Z-pr-2142.md"
tags: ["awk", "test", "assertion-strength", "escape", "mutation-testing"]
confidence: high
---

# awk -v 代入はバックスラッシュを剥がす — escape 付きパターンを渡した範囲指定 assert は常に PASS する

## 概要

`awk -v var=value` の代入では、value 内のバックスラッシュが**エスケープシーケンスとして解釈され剥がれる**。節スコープを切る assert helper がこの形でパターンを受け取っていると、呼び出し側が書いた `^> \*\*fail-safe` は awk 側で `^> **fail-safe` になる。これは成立しない正規表現で、**範囲の終端が一致しなくなり flip-flop が EOF まで伸びる**（実測で 677 行が抽出された）。

結果、範囲外にあるはずの行が「範囲内」で見つかり、**節にスコープを切ったつもりの assert が全文検索と同じになる**。

## 詳細

### なぜ目視で気づけないか

- 呼び出し側のパターンは正しく見える（Markdown の `**` を escape している）
- helper の実装も正しく見える（flip-flop の範囲指定は定石）
- suite は green

**mutation を当てて初めて発覚する。** pin を書いた直後に「守りたい欠陥状態を再現して落ちるか」を確かめる習慣がないと素通りする。

### 影響範囲は数えてから主張する

本件を最初に報告したときは「同 helper の caller 11 suite・42 箇所が同じ縮退を持つ」「assert が常に PASS する」と書いたが、次 cycle の実測で 2 点とも過大だと判明した。

- start が一致しなければ empty section を検出して **FAIL する**（常時 PASS ではない）
- 縮退するのは**終端**パターンに意味を変える escape を含む caller だけで、既存 28 caller 中 0 件

誤った一般化は「28 箇所の一斉修正」か「正常な assert 全体への不信」のどちらかを誘発する。**主張の範囲は grep で数え、数えた結果を主張に書く。**

### 回避策

| 手段 | 補足 |
|---|---|
| `ENVIRON` 経由で渡す | `VAR=pattern awk '... ENVIRON["VAR"] ...'` は escape 解釈を受けない |
| escape を必要としないパターンにする | 範囲の境界に正規表現メタ文字を含まない行を選ぶ |
| 節スコープをやめて単純な述語を直接書く | 隣接性の検査などは範囲指定を必要としない |

### 同じファイルに規約コメントがあっても新規 assert には適用されない

PR #2150 で同型が再現した。`assert_grep_in_section` の end パターンに `'^  \*\) '` と単一エスケープで書いた結果、`\*` が量化子 `*` へ潰れてレンジが EOF（892 行）まで伸び、pin 対象とは無関係な既存コードで assert が充足された（pin 対象の行を削除しても全 assert green）。

このファイルには既に二重エスケープの規約コメントが存在していた。**規約コメントは既存 assert の隣にあるだけで、新規に書き足す assert には届かない**。`assert_grep_in_section` に新しい範囲を渡すときは、規約コメントの有無に関わらず start / end の正規表現メタ文字（`\\)` `\\*` `\\[`）を二重エスケープで書き、**pin 対象の行を実際に削除して fail することを確認する**。

## 関連ページ

- [節スコープ assert は散文由来の false negative を防ぐ](../patterns/section-scoped-assertion-prevents-narrative-false-negative.md)
- [assert のラベルが述語より広い範囲を名乗ると「虚偽主張」クラスの欠陥になる](./assert-label-overclaims-predicate-scope.md)
- [BRE/ERE のメタ文字反転が assert を死なせる](./bre-ere-metachar-inversion-dead-assertion.md)
- [awk flip-flop の range start パターンはアンカーする](../patterns/awk-flip-flop-range-start-pattern-anchoring.md)

## ソース

- [PR #2142 fix results (cycle 2)](../../raw/fixes/20260808T010121Z-pr-2142.md)
- [PR #2142 review results (cycle 3)](../../raw/reviews/20260808T013358Z-pr-2142.md)
- [PR #2150 fix results (cycle 2: 単一エスケープでレンジが EOF まで伸びた再現)](../../raw/fixes/20260808T070139Z-pr-2150-cycle2.md)
