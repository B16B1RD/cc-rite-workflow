---
type: "anti-patterns"
title: "gate を守る対象の内側に置くと、守るべき唯一の failure mode で gate も一緒に skip される"
domain: "anti-patterns"
promote: rite-plugin
reference: "plugins/rite/references/wiki-promotions/anti-patterns/gate-placed-inside-guarded-scope.md"
description: "LLM が読む手順書で「手順 X が実行されたこと」を保証する post-condition gate を新設するとき、gate を X のサブステップとして書くと自己参照で無力化する。"
created: "2026-07-27T10:57:51+09:00"
updated: "2026-07-27T10:57:51+09:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260726T164052Z-pr-2030.md"
  - type: "reviews"
    ref: "raw/reviews/20260726T171439Z-pr-2030.md"
  - type: "fixes"
    ref: "raw/fixes/20260726T165153Z-pr-2030.md"
tags: []
confidence: high
---

# gate を守る対象の内側に置くと、守るべき唯一の failure mode で gate も一緒に skip される

## 概要

LLM が読む手順書で「手順 X が実行されたこと」を保証する post-condition gate を新設するとき、gate を X のサブステップとして書くと自己参照で無力化する。守るべき唯一の failure mode は「X を丸ごと skip する」であり、そのとき gate も一緒に skip されるからだ。**gate は守る対象の外・result emit 境界の直前に置く**。

## 詳細

### 観測された失敗

起点事例の cycle 1 で、手順 6.1.d（PR コメント投稿）の実行保証として step 3 に post-condition gate を新設した。しかし gate 自体が 6.1.d のサブステップだったため、LLM が 6.1.d を認識せずに飛ばした場合は gate も評価されない。

同リポジトリの canonical な gate（ステップ 8.0.1 / 8.0.2）はいずれも**守る対象の外・result emit 境界の直前**に置かれており、新設 gate だけが非対称だった。

### 二層 gate の役割分担

cycle 2 の修正では二層に揃えた。この形が canonical:

| 層 | 位置 | 役割 |
|---|---|---|
| 内側 | 守る対象のサブステップ | integrity check（部分実行・途中失敗の検出） |
| 外側 | result emit 境界の直前 | 全体 skip の fallback |

内側だけだと守る対象と運命を共にする。外側だけだと部分実行を見逃す。**両方を明記して初めて機能する**。

### 同一 conversation でループする skill には iteration_id が要る

review⇄fix ループのように同じ skill が同一 conversation 内で複数回起動する場合、**presence check だけの gate は前 cycle が emit した marker で false-positive pass する**。cycle 1 の marker が cycle 2 のコンテキストに残っているためだ。

同ファイルの既存 gate（ステップ 7.7）は既にこの failure mode を認識して `iteration_id` + 「最大値を採用」規約を canonical 化していたが、新設 gate がその規約を踏襲しなかった。

**新設 gate の 3 点セット**（cycle 3 で確立）:

1. **順序規定** — gate をどの step の後に評価するか、pass したらどこへ routing するか（前段 gate の pass routing を更新し忘れると新 gate が到達不能になる）
2. **検証対象 sentinel** — 動作**後**に emit される marker を見る（動作**前**の lookup marker では step の実行を検証できない）
3. **鮮度判定の参照値** — `iteration_id` を LLM 側に残す形で emit する（bash 内で生成して比較対象が残らないと判定できない）

### 「gate を足すと gate 自体が新しい指摘源になる」

起点事例は cycle 2 で新設した gate が上記 3 点すべてを欠き、cycle 3 で 3 件の新規指摘を生んだ。gate 追加は防御コードの追加であり、**防御コード自身を守る設計が要る**。

## 関連ページ

- [Success-only Sentinel Design — sub-skill abort path sentinel 未定義](./success-only-sentinel-design.md)
- [無音失敗を可視化する防御コードには、その防御コード自体を守る失敗パステストを追加する](../heuristics/defensive-code-needs-its-own-failure-path-test.md)
- [新設した検証機構が、その機構自身の目的を局所的に打ち消す](./self-defeating-guard-local-purpose-negation.md)
- [前提条件の silent omit が AND 論理の防御層チェーンを全体無効化する](./silent-precondition-omit-disables-and-defense-chain.md)

## ソース

- [PR #2030 review results](../../raw/reviews/20260726T164052Z-pr-2030.md)
