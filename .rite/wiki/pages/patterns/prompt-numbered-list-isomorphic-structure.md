---
title: "prompt 内 numbered list は同型構造で書く（全 step に動作詳細 bullet を対称配置）"
domain: "patterns"
created: "2026-04-18T17:40:00+09:00"
updated: "2026-04-18T17:40:00+09:00"
sources:
  - type: "fixes"
    ref: "raw/fixes/20260418T071459Z-pr-564.md"
  - type: "reviews"
    ref: "raw/reviews/20260418T072254Z-pr-564-rerun.md"
tags: []
confidence: high
---

# prompt 内 numbered list は同型構造で書く（全 step に動作詳細 bullet を対称配置）

## 概要

LLM が prompt / skill / command 定義を実装する際、numbered list は各 step の「動作詳細 bullet の有無・粒度」を**対称配置**する必要がある。一部 step だけ bullet が抜けると、LLM がその step の動作を推測で埋める経路が生じ、silent な解釈 drift が発生する。

## 詳細

### 発生事例 (PR #564)

`plugins/rite/commands/wiki/ingest.md` Phase 8.3 の step 1-4 は、Lint 実行結果のパース順序を表す numbered list。修正前、step 2 / step 3 / step 4 には「detection 時の処理」として 3 bullet (warning 加算 / 変数 fallback / stderr 出力) が揃っていたが、step 1 だけ bullet が欠落しており、LLM が「error 検出時に何をすべきか」を推測で埋める経路になっていた (F-01 検出)。

### 失敗の構造

1. 著者は各 step の目的を numbered list で列挙する
2. 「代表的な step」だけ詳細 bullet を書き、「自明だから省略」と判断した step の bullet を書かない
3. LLM は numbered list の prose を読んで実装するが、bullet が省略された step の動作は推測で埋める
4. 推測は元の意図と微妙にズレることがあり、silent regression が生まれる

### 対処の canonical pattern

- **対称配置原則**: numbered list 内の全 step に、同じ粒度・同じ種類の動作詳細 bullet を書く
- **「自明」判定の禁止**: 人間にとって自明でも LLM にとっては推測経路。省略せず明示的に列挙する
- **構造テンプレート**: 各 step は以下の構造に揃える:
  ```
  N. **<step 名>**: <1行の概要>
     - <動作詳細 1>
     - <動作詳細 2>
     - <動作詳細 3>
  ```
- **差分レビュー観点**: PR で numbered list を追加/変更する際、全 step の bullet 数・種類を checklist で確認する
- **検証方法**: 実装した LLM が各 step の動作を「bullet から literal に読み取った」と主張できるかを逐語確認する

### 関連パターン

- **Phase 番号は構造的対称性を保つ**: Phase 番号の階層的対称性（`8.0` がなければ `8.0.1` を書かない）と同根。構造対称性を prose・Phase 番号・bullet の 3 レベルで維持する
- **散文で宣言した設計は対応する実装契約がなければ機能しない**: prose 省略は「省略先を LLM が補完する」prose-only 契約の一種

## 関連ページ

- [Phase 番号は構造的対称性を保つ（孤立 sub-phase を生まない）](../heuristics/phase-number-structural-symmetry.md)

## ソース

- [PR #564 fix results (11th cycle)](../../raw/fixes/20260418T071459Z-pr-564.md)
- [PR #564 re-review (11th cycle)](../../raw/reviews/20260418T072254Z-pr-564-rerun.md)
