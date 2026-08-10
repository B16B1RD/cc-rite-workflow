---
type: "anti-patterns"
title: "配列間で要素を移送するゲートの consumer は、入ってくる余分と出ていく不足の両方向を見る"
domain: "anti-patterns"
promote: rite-plugin
description: "ゲートが要素を配列 A から配列 B へ*移送*する設計では、A だけを読む consumer に 2 方向の欠陥が同時に成立する — 「A に残るべきでない余分が入る」と「B へ出ていった分が抜ける」。"
created: "2026-08-07T07:57:00+09:00"
updated: "2026-08-07T07:57:00+09:00"
sources:
  - type: "fixes"
    ref: "raw/fixes/20260806T160550Z-pr-2126.md"
tags: []
confidence: high
---

# 配列間で要素を移送するゲートの consumer は、入ってくる余分と出ていく不足の両方向を見る

## 概要

ゲートが要素を配列 A から配列 B へ*移送*する設計では、A だけを読む consumer に 2 方向の欠陥が同時に成立する — 「A に残るべきでない余分が入る」と「B へ出ていった分が抜ける」。片方だけを直すと、直した側の対称位置にもう片方が残り、次サイクルで再指摘される。

## 詳細

PR #2126 の実測必須ゲートは、非実測と判定した gated 指摘を `findings[]` から `non_blocking_findings[]` へ**移送**し、同時に `scope == "nit-noted"` の指摘は非実測でも `findings[]` に残す。したがって `findings[]` の実体は「blocking 集合 − 移送された分 + 全 nit-noted 集合」になる。

cycle 1 でこの配列を読む新規 consumer が「blocking 集合」と誤解し、**余分が入る方向**（nit が混じる）だけを修正した。cycle 2 で security reviewer が**不足する方向**を指摘: その cycle の gated 指摘が全件非実測だった reviewer は `findings[]` に 1 件も残らず、次サイクルの mandatory 再起動対象から構造的に脱落する。さらに非実測指摘の記録コメントは update-in-place で毎 cycle 本文を置換するため、再導出されないと成果物からも消える。

**cycle 3 でさらに半分が残っていた**: cycle 2 は「finder を選ぶ側」の母集団を 2 配列の和へ広げたが、「同じ指摘を下流へ渡す側」を旧定義のまま残した。結果、reviewer は再起動されるが検証対象を渡されず、しかも差分外の再導出は別のルールが禁じているため、直そうとした喪失が半分残った。この非対称は 5 reviewer が独立に報告している。

**構造**: 移送ゲートを挟むと、同一データを読む箇所が最低 2 つできる（「選ぶ側」と「渡す側」）。両方を同時に直さないと、片側だけが正しい定義を持つ状態が生まれる。

**対処**:

1. ゲートが要素を*動かす*と分かったら、consumer 側で **2 方向を明示的に列挙する**: この配列に残る余分は何か、この配列から出ていく不足は何か
2. 同一データを読む箇所を `grep` で**数え上げてから**直す。「選ぶ」と「渡す」は別の consumer であり、片方だけ直すともう片方が silent に契約を破る
3. 母集団を和に広げるなら、**和に含めない要素の理由を書く**。PR #2126 では nit-noted を和に含めない理由（「修正不要と決着済みで再検証の価値が無く、含めれば免除枠を占有する」）を記述に残した。理由が無いと次の変更で誤って含められる
4. 移送の下流に「update-in-place で置換される成果物」があるなら、**再導出されない要素はそこからも消える**ことを設計時に見積もる

**判定の目安**: 書込側のコードに「ある配列から要素を取り除いて別の配列へ append する」形（`.a = $kept | .b += $moved` 等）があれば、その両配列を読む consumer が必要と考えてよい。

## 関連ページ

- [既存の永続データを新規 consumer が読むときは、集合の意味を書込側の定義から引く](../heuristics/persisted-collection-semantics-from-writer-not-name.md)
- [対称位置への伝播漏れ (Asymmetric Fix Transcription)](./asymmetric-fix-transcription.md)

## ソース

- [PR #2126 fix results (cycle 2)](../../raw/fixes/20260806T160550Z-pr-2126.md)
