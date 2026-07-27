---
type: "patterns"
title: "「破棄しない」を保証する記録先は永続チャネルに置き、除外契約と保存先をセットで規定する"
domain: "patterns"
description: "「この指摘は破棄されない」と宣言するなら、記録先は表示専用チャネル（統合レポートの section・PR コメント）ではなく唯一の永続成果物に置く。既定設定でコメントが投稿されない・E2E で出力が minimize される・永続 JSON からは除外契約で落ちる、が重なると記録がゼロになり、成果物は「指摘ゼロ」と区別不能な誤記録になる。除外契約を書くときは代替の保存先を必ず同時に書く。"
created: "2026-07-27T17:54:54+09:00"
updated: "2026-07-27T17:54:54+09:00"
sources:
  - type: "fixes"
    ref: "raw/fixes/20260727T053017Z-pr-2036.md"
tags: []
confidence: high
---

# 「破棄しない」を保証する記録先は永続チャネルに置き、除外契約と保存先をセットで規定する

## 概要

PR #2036 cycle 2 で 3 reviewer が独立に CRITICAL として検出した欠陥。「非実測の指摘は blocking から降格するが破棄はしない」という MUST を書きながら、その記録先を統合レポートの section 1 本に置いたため、既定構成では記録が**どこにも残らなかった**。

## 詳細

記録が消えた経路は 3 つの重なりだった:

1. 既定 `post_comment: false` のため PR コメントが投稿されない
2. E2E フローで統合レポート出力が minimize される
3. 永続 JSON からは「除外契約」により落ちる

結果、唯一残る成果物（永続 JSON）は `overall_assessment: mergeable` + `findings: []` となり、**本当に指摘ゼロだった場合と区別できない誤記録**になる。「破棄経路は存在しない」という宣言が偽になっていた。

**修正の型**: 記録先を 3 経路に確保した。

- **(1) 永続チャネルへの additive 追加**: 唯一の永続成果物であるローカル JSON にトップレベル `non_blocking_findings[]` を additive に足す。既存 `findings[]` の契約は不変なので invariant の同期が不要で、read 側は未知キー無視で後方互換。0 件でも空配列を出す（キー省略との区別のため）。
- **(2) 出力最小化の carve-out**: E2E Output Minimization に「該当 section は件数 > 0 のとき省略禁止」の例外を明記する。
- **(3) 出力行の suffix**: サマリ行に `| non-blocking: {n}` を付け、件数が 0 でないことを 1 行で surface する。

**一般化できる規則**:

- **表示専用チャネルは「記録した」の根拠にならない**。既定設定・出力最適化・呼び出し経路のいずれかで消えるなら、それは記録ではなく表示である。
- **除外契約を書くときは「どこに残るか」を同時に書く**。`findings[]` から除外する契約だけを明記して代替の記録先を書かなかったことが、この穴の直接原因だった。除外と保存はセットで規定する。
- **書いた記録先には write 側の検証を置く**。新設した配列にキー省略の検証がないと、無音でキーが脱落し元の状態に戻れる。ただしその検証は非ブロッキングにすること（[advisory データの欠陥検証を hard fail にすると primary データごと失われる](../anti-patterns/advisory-data-validation-hard-fail-drops-primary-data.md)）。

## 関連ページ

- [advisory データの欠陥検証を hard fail にすると primary データごと失われる](../anti-patterns/advisory-data-validation-hard-fail-drops-primary-data.md)
- [共有パスに置く進捗/status 表示は到達する全経路で真な文言にする（成功含意を避ける）](../heuristics/status-display-truthful-for-all-reachable-paths.md)

## ソース

- [PR #2036 fix results (cycle 2)](../../raw/fixes/20260727T053017Z-pr-2036.md)
