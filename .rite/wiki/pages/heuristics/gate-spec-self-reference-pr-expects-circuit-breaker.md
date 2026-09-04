---
type: "heuristics"
title: "検出ゲートの仕様そのものを変える PR は自己言及で発散する — サーキットブレーカー到達を異常ではなく想定内として扱う"
domain: "heuristics"
description: "検出ゲートの規約を記述した散文を変更する PR では、**指摘の叙述そのものが規則の対象文字列を含む**。"
created: "2026-08-03T23:41:26+09:00"
sources:
  - type: "fixes"
    resource: "raw/fixes/20260803T131002Z-pr-2095.md"
  - type: "fixes"
    resource: "raw/fixes/20260803T124230Z-pr-2095.md"
  - type: "reviews"
    resource: "raw/reviews/20260803T104952Z-pr-2095.md"
  - type: "reviews"
    resource: "raw/reviews/20260803T140734Z-pr-2095.md"
tags: []
confidence: medium
generated: { by: "rite-wiki-ingest/unknown", at: "2026-08-03T23:41:26+09:00" }
---

# 検出ゲートの仕様そのものを変える PR は自己言及で発散する — サーキットブレーカー到達を異常ではなく想定内として扱う

## 概要

検出ゲートの規約を記述した散文を変更する PR では、**指摘の叙述そのものが規則の対象文字列を含む**。規則を書き換えるたびに新しい踏み抜き経路が露出するため、cycle を重ねても blocking が枯れない。この構造の PR にとって、サーキットブレーカー到達は失敗ではなく想定内の終点であり、残りを人間レビューへ委ねるのが正しい。

## 詳細

### なぜ通常の収束処方が効かないか

非収束時の標準的な処方は「点修正をやめて構造を疑う」である。しかしこのクラスの PR では、疑うべき構造 = 検出層そのものが **Non-goal として明示的に変更対象から外れている**（helper 無変更が受入条件になっている、等）。構造に触れずに散文だけを直す限り、規約文書と検出層 literal の食い違いは形を変えて再生産される。

### 見分け方

次の 2 条件が揃ったら本クラスと判定してよい。

1. 指摘の内訳が「規約文書自身の記述と検出層 literal の食い違い」で占められている
2. cycle ごとに指摘の**場所**は移動するが、**形**は同一である

このとき、cycle 数を追加投入しても期待値は上がらない。

### 実測

ある PR（純散文 5 ファイル、+84/-1）は 5 サイクルすべてで blocking 指摘が出続け、サーキットブレーカーで停止した。

同時に、**この PR が導入した帰結クラス Gate 自体は機能した** — 最終 cycle の 4 件はすべて字面整合クラスとして non-blocking へ降格し blocking=0 になった。つまり「PR が収束しなかったこと」と「PR の成果物が無効であること」は別である。自己言及クラスの発散を成果物の欠陥と読み違えないこと。

### 発散を減らす副次的な手当

サーキットブレーカー到達自体は避けられないが、cycle あたりの消耗は減らせる。

- **同じ指摘が 3 cycle 連続で non-blocking として記録され続けるなら、fix へ繰り上げる。** 推奨対応が net-negative（虚偽記述の削除・単純化）であれば、放置するより総コストが低い。放置は毎 cycle reviewer の注意と記録コメントを消費する。
- **cycle 間で reviewer の判断が逆転した項目は fix せず記録する。** 方針判断であって実装の誤りではないため、相違を明示して人間へ回す。

## 関連ページ

- [cycle が進んでも findings が減らないときは点修正をやめて構造を疑う](./non-converging-review-loop-suspect-structure.md)
- [Reviewer rule 自身を編集する PR は self-application false positive を verify する](./self-applying-reviewer-rule-false-positive.md)
- [判別述語を対象テキスト全体に広げると、その規則自体を論じる文書で自己言及的に誤発火する](../anti-patterns/predicate-scans-whole-text-in-self-describing-domain.md)
- [自身の検出を避けるために崩した書式は、読者に「こう書け」と読まれる](../anti-patterns/self-detection-evasion-format-read-as-prescription.md)

## ソース

- [サーキットブレーカー発火](../../raw/fixes/20260803T131002Z-pr-2095.md)
- [fix 結果](../../raw/fixes/20260803T124230Z-pr-2095.md)
- [レビュー結果](../../raw/reviews/20260803T104952Z-pr-2095.md)
- [final cycle, blocking=0](../../raw/reviews/20260803T140734Z-pr-2095.md)
