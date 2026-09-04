---
type: "heuristics"
title: "既存の永続データを新規 consumer が読むときは、集合の意味を書込側の定義から引く"
domain: "heuristics"
promote: rite-plugin
reference: "plugins/rite/references/wiki-promotions/heuristics/persisted-collection-semantics-from-writer-not-name.md"
description: "永続化された配列を新しい consumer が読むとき、配列名から意味を推測すると書込側が定義した実際の集合とずれる。"
created: "2026-08-07T07:55:00+09:00"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260806T151643Z-pr-2126.md"
tags: []
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-08-07T07:55:00+09:00" }
---

# 既存の永続データを新規 consumer が読むときは、集合の意味を書込側の定義から引く

## 概要

永続化された配列を新しい consumer が読むとき、配列名から意味を推測すると書込側が定義した実際の集合とずれる。ずれは抽出式 1 箇所ではなく、その集合を人間向けに言い換えた散文 N 箇所へ同時に伝播するため、修正コストが「jq に 1 行足す」で済まず「記述側 5 箇所を同時に直す」になる。書込側のコメントを Source of Truth として引用し、名前からの推測を禁じる。

## 詳細

ある PR で新規 helper が既存の永続レビュー JSON の `findings[]` を読み、その値を「blocking を出した reviewer」と呼んだ。実際には書込側（実測必須ゲート）のコメントが「`scope == "nit-noted"` はゲート対象外のため非実測でも `findings[]` に残す」と明記しており、実体は blocking 集合と全 nit-noted 集合の**和**だった。cycle 1 で 6 reviewer 中 4 名がこの 1 点を独立に検出している（同 PR で最頻の指摘パターン）。

**なぜ高くつくか**: 抽出式の修正は `select(.scope == "current-pr" or .scope == "follow-up")` を足す 1 行で済む。しかし同じ集合を言い換えた記述が helper docstring・SKILL.md 2 箇所・reference 1 箇所・docs 2 箇所の計 5 箇所にあり、jq だけ直すと記述が腐る。名前からの推測は「1 箇所の誤り」ではなく「N 箇所へ複製された誤り」を作る。

**さらに悪い形**: 同じ PR の cycle 2 で、この修正自身が逆方向の欠陥を残していたことが判明した。実測必須ゲートは非実測の gated 指摘を `findings[]` から `non_blocking_findings[]` へ**移送**するため、`findings[]` だけを見ると「余分（nit）が入る」と「不足（移送済み）が抜ける」の両方が起きる。cycle 1 は余分側だけを直していた。詳細は [配列間で要素を移送するゲートの consumer は両方向を見る](../anti-patterns/transporting-gate-consumer-must-check-both-directions.md)。

**適用手順**:

1. 新規 consumer が既存の永続データを読むと決めたら、**書込側のファイルを開く**。名前・スキーマ定義だけでは足りず、「どういう条件でこの配列に入る / 出る」を書いたコメントを探す
2. 見つけた定義を、consumer 側のコメントに**引用として写す**（要約せず、条件をそのまま書く）。要約すると次の読み手がまた推測に戻る
3. その集合を人間向けに言い換えている箇所を `grep` で数え上げ、**修正時は全数を同時に直す**。1 箇所直して他が残ると、記述間の矛盾として次サイクルのレビューで再指摘される
4. 書込側が「移送」（ある配列から別の配列へ要素を動かす）を行っているなら、**入ってくる余分と出ていく不足の両方**を検討する

**判定の目安**: 配列名が意味を語っていると思った瞬間が危険信号。`findings` / `errors` / `results` のような一般名は、フィルタ・移送を経た後の実体を語らない。

## 関連ページ

- [配列間で要素を移送するゲートの consumer は入ってくる余分と出ていく不足の両方向を見る](../anti-patterns/transporting-gate-consumer-must-check-both-directions.md)
- [対称位置への伝播漏れ (Asymmetric Fix Transcription)](../anti-patterns/asymmetric-fix-transcription.md)

## ソース

- [レビュー結果](../../raw/reviews/20260806T151643Z-pr-2126.md)
