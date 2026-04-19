---
title: "state machine を 2 箇所で記述する場合は動作の文字列レベルで同期する"
domain: "patterns"
created: "2026-04-19T03:30:00+00:00"
updated: "2026-04-19T03:30:00+00:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260419T034237Z-pr-586-cycle5.md"
tags: []
confidence: high
---

# state machine を 2 箇所で記述する場合は動作の文字列レベルで同期する

## 概要

同一 state の動作を「実装ロジックの Skip 条件記述」と「LLM 分岐テーブル」のように 2 箇所に分けて記述する場合、両者で動作の文字列 (silent / verbose / 表示メッセージ内容) が食い違うと **LLM 実行時の動作が不定** になる。文字単位で同期し、UX-positive 側 (通常は ✅ 表示付きのフィードバック経路) に統一するのが canonical。

## 詳細

### 発生事例 (PR #586 cycle 5)

`/rite:wiki:init` Phase 1.3.1 の `already_negated` state について:

- Skip 条件記述 (L119): 「silent skip」と明記
- LLM 分岐テーブル (L173): 「✅ メッセージを表示して Phase 2 へ」と指定

同じ state に対して実装ロジックは「無言」、LLM 側テーブルは「有言」を指示しており、LLM が指示書を読む際どちらに従うか不定 (F-03 として cycle 5 review で MEDIUM 検出)。

### 失敗の構造

1. 実装ロジック設計時に「無駄な出力は silent に」と書く
2. 後から LLM UX 改善で分岐テーブルを追加し「✅ 表示」を追記する
3. 2 箇所を別タイミングで編集した結果、動作記述の文字列が drift する
4. LLM は指示書の両方を参照し、どちらを採用するか run ごとにブレる
5. 「動作が変動する」silent regression として下流で検出される

### Canonical pattern

1. **動作文字列を 1 箇所で canonical 定義する**: 例えば「`state="already_negated"` → `✅ 既に negation が有効です` を表示して Phase 2 へ進む」を canonical 宣言として冒頭に書く
2. **分岐テーブル / Skip 条件記述は canonical 文字列を参照する**: `上記 canonical の通り動作する` 等、重複定義を避ける
3. **どうしても複数箇所に書く必要がある場合は DRIFT-CHECK ANCHOR で機械検証可能にする**: 同一 semantic を 2-3 site に展開する場合は anchor コメントで 3 者 explicit sync 契約を結ぶ (詳細は [drift-check-anchor-semantic-name](./drift-check-anchor-semantic-name.md) 参照)
4. **UX-positive 側に統一**: silent skip vs verbose skip の選択では、原則として verbose (✅ / ℹ️ メッセージ付き) に倒す。「何も起きない」は debug 困難で silent failure と区別できない

### 検出手段

- PR レビュー時に同一 state name (`already_negated` / `skip` 等) で `grep` し、全 hit で動作記述の文字列を diff で比較する
- 分岐テーブルがあるドキュメントでは、テーブル内の「メッセージ / アクション」列を canonical 宣言と突き合わせる lint を将来的に追加する

## 関連ページ

- [DRIFT-CHECK ANCHOR は semantic name 参照で記述する（line 番号禁止）](./drift-check-anchor-semantic-name.md)
- [canonical reference 文書のサンプルコードは canonical 実装と一字一句同期する](./canonical-reference-sample-code-strict-sync.md)
- [散文で宣言した設計は対応する実装契約がなければ機能しない](../anti-patterns/prose-design-without-backing-implementation.md)

## ソース

- [PR #586 cycle 5 review (state 動作矛盾 F-03 検出)](../../raw/reviews/20260419T034237Z-pr-586-cycle5.md)
