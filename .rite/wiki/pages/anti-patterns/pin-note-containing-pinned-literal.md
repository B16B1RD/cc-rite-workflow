---
type: "anti-patterns"
title: "pin の説明文に pin 対象の literal を書くと、注記自身が出現数に数えられて count pin が落ちる"
domain: "anti-patterns"
description: "「特定の文字列がファイル内にちょうど N 個ある」という count pin を導入したあと、その pin の意図を説明する注記に**対象の literal をそのまま書く**と、注記自身が N+1 個目の出現になり pin が落ちる。"
created: "2026-08-07T18:40:00+09:00"
sources:
  - type: "fixes"
    resource: "raw/fixes/20260807T082131Z-pr-2135.md"
  - type: "fixes"
    resource: "raw/fixes/20260807T085227Z-pr-2135.md"
tags: []
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-08-07T18:40:00+09:00" }
---

# pin の説明文に pin 対象の literal を書くと、注記自身が出現数に数えられて count pin が落ちる

## 概要

「特定の文字列がファイル内にちょうど N 個ある」という count pin を導入したあと、その pin の意図を説明する注記に**対象の literal をそのまま書く**と、注記自身が N+1 個目の出現になり pin が落ちる。pin の説明を書く行為が pin の測定対象を変えてしまう、自己参照の罠である。

## 詳細

ある PR で **2 度踏んだ**。

**1 度目 (cycle 2)**: `the default of 15` という表現が 4 箇所にあることを count pin で固定したあと、テストに「T-04n counts the four `the default of 15` phrasings」というコメントを書いた。**その瞬間に注記自身が 5 つ目の出現になり**、期待値 4 の pin が落ちた。対処として literal を書かず「the four spelled-out mentions of the default value」と言い換えた。

**2 度目 (cycle 3)**: 言い換えた注記に対し「識別子として機能していない（どの文字列を指すのか読者が特定できない）」と指摘され、literal を書き戻して**また踏んだ**。

**Wiki 知見として cycle 2 の時点で記録済みだったが活きなかった** — 別の指摘（可読性）が literal を書けと押し、記録した知見は「思い出させる」だけで「強制しない」ため負けた。

**恒久対処**: 言い換えでも literal でもなく、**注記自身に自己参照の事実を書き込む**。

> the assertion itself carries the exact wording, so do not repeat it here or the count will move

これは「知見をドキュメントの当該箇所へ埋める」形の対処である。次に可読性を理由に literal を書こうとした編集者が、その場で理由を読む。Wiki に置くだけでは、編集の現場に届かない。

**隣接する落とし穴（同 PR で同時に踏んだ）**:

- **`grep -c` は行数であって出現数ではない**。長い段落を 1 行で書く markdown では、同一行に同じ文字列が 2 つ同居すると count pin が黙って過小評価する。`grep -o ... | wc -l` へ変えて初めて正しい数が出る
- **pin を足した行で未 pin 面が増える**。pin を足しつつ同じ行で散文を書き足すと、書き足した側は pin 対象に入らず、pin 済みと未 pin の比率が悪化する。pin 追加と散文の書き足しを同じ commit でやるなら、書き足した側も pin 対象に入るか確認する
- **drift 注記の分類は grep ではなく assertion 側から検証する**。「この節は pin 済み」と書く前に、その節の記述数と assertion 数を突き合わせる

**判定の目安**: count pin を足したら、`grep -o <literal> <file> | wc -l` を**テストファイルと対象ファイルの両方**に対して走らせる。テストファイル側に 1 件でも出るなら自己参照している。

## 関連ページ

- [ratchet test では occurrence 単位 (`grep -oE | wc -l`) を原則とし line 単位は混在させない](../patterns/test-counting-occurrence-vs-line-unit.md)
- [Test pin protection theater: 「N site pin」claim と実 assert の gap が regression 検出を破壊する](./test-pin-protection-theater.md)

## ソース

- [fix 結果](../../raw/fixes/20260807T082131Z-pr-2135.md)
- [fix 結果](../../raw/fixes/20260807T085227Z-pr-2135.md)
