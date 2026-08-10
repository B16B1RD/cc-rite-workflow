---
type: "heuristics"
title: "属性は母集団からの除外ではなく別 map で持つ — 除外は下流の全分岐を経路依存で壊す"
domain: "heuristics"
description: "既存の分類 map（severity_map など）に新しい軸（実測済みか否か）を導入するとき、「条件を満たさない要素を母集団から除外する」設計にすると、その map を参照する下流の全分岐が経路依存で壊れる。"
created: "2026-07-27T10:57:51+09:00"
updated: "2026-07-27T10:57:51+09:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260726T140529Z-pr-2030.md"
  - type: "reviews"
    ref: "raw/reviews/20260726T142820Z-pr-2030.md"
  - type: "fixes"
    ref: "raw/fixes/20260726T141238Z-pr-2030.md"
  - type: "fixes"
    ref: "raw/fixes/20260726T144002Z-pr-2030-cycle4.md"
  - type: "fixes"
    ref: "raw/fixes/20260726T150940Z-pr-2030-cycle5.md"
tags: []
confidence: high
---

# 属性は母集団からの除外ではなく別 map で持つ — 除外は下流の全分岐を経路依存で壊す

## 概要

既存の分類 map（severity_map など）に新しい軸（実測済みか否か）を導入するとき、「条件を満たさない要素を母集団から除外する」設計にすると、その map を参照する下流の全分岐が経路依存で壊れる。**母集団は統一したまま、属性を別 map（measured_map）に持たせて参照時にフィルタする**方が安全。

## 詳細

### 除外設計が壊すもの

母集団から除外すると、その map を数える／走査するすべての箇所が暗黙に影響を受ける:

- 総件数（`total_count`）が別定義になる
- 「全件が条件 X」を判定する `all()` 系の述語が、除外された要素を見なくなって vacuous に真になる
- 収束条件の counter 式が対応項を失う

起点事例では、除外された要素が下流の 3 経路で別々の意味に解釈される状態になった。

### 別 map 設計での注意点

母集団を統一しても、**既存の除外規約をフィルタとして再適用しない**と逆規則になる。起点事例の cycle 4 では `nit-noted` の二重計上防止（別カウンタ `acknowledged_nit_count` が既に数えている）が新 map で失われ、同じ finding が 2 度数えられた。

### map を LLM 手順書に書くときの 3 点セット

`severity_map` / `measured_map` のような写像を bash ではなく LLM 手順書で構築させる場合、以下を明文化しないと双方向（二重計上 / silent skip）の穴が残る:

1. **母集団からの除外規則** — どのカテゴリを登録しないか、それはなぜか（他カウンタとの二重計上防止など）
2. **key 正規化** — `{file}:{line}` の `line` が null / 0 のときどうするか。複数 map で同じ正規化を使うこと
3. **衝突 tie-break** — 同一 key が複数回現れたときどちらを採るか。fail-safe 側（blocking 優先）に倒す

### 全 map の入力源を揃える

複数の map を突き合わせる場合、**全 map の入力源（正規化前 / 正規化後）を明記して揃える**。起点事例の cycle 5 では、helper が tempfile 上でのみ scope を normalize して原ファイルへ書き戻さない構成だったため、LLM が原ファイルから独自構築した map に normalize 前の値が混入し、二重計上とゲート bypass の双方向の穴が同時に開いた。

登録条件に正規化**前**の値を使う設計自体を廃止し、「全 finding を登録 → 参照時に正規化後の map でフィルタ」に統一するのが正しい。

### `all()` の普遍量化は複数要素 fixture で pin する

母集団に対する `all()` は、テスト fixture が単一要素だと `any()` と区別不能。母集団の定義を変える PR では複数要素 fixture を必ず置く。

## 関連ページ

- [複数の異種 signal を集約するロジックは表層パターンではなく共通の構造化された状態を判定基準にする](./aggregate-heterogeneous-signals-by-structured-state-not-surface-pattern.md)
- [Config parser helper の DRY 化が key 別 subtle 差異を silent に抹消する](../anti-patterns/dry-helper-key-by-key-behavior-drift.md)
- [Severity 等級拡張は read/write/parse/measure の closed-loop 6 段階を verify する](./severity-extension-closed-loop-verification.md)

## ソース

- [PR #2030 review results](../../raw/reviews/20260726T140529Z-pr-2030.md)
