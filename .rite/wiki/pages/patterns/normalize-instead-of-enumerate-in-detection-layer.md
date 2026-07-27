---
type: "patterns"
title: "検出層の表記ゆれ対応は「列挙」ではなく「正規化」で吸収する"
domain: "patterns"
description: "検出 regex が拾えない装飾・表記ゆれを見つけるたびにパターンを 1 つずつ足す設計は、列挙を足すたびに同じレビュー指摘が再発する。文字クラスと全角記号の吸収で正規化する形に書き換えると打ち止めになる。あわせて、2 段判定の stage 1（存在判定）に値の検証まで含めると、値を取り違えたケースが両段から外れて無音で脱落する。"
created: "2026-07-27T17:54:54+09:00"
updated: "2026-07-27T17:54:54+09:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260727T084223Z-pr-2036.md"
  - type: "fixes"
    ref: "raw/fixes/20260727T053017Z-pr-2036.md"
tags: []
confidence: high
---

# 検出層の表記ゆれ対応は「列挙」ではなく「正規化」で吸収する

## 概要

PR #2036 では、マーカー検出の stage 1 regex に対する同種の指摘が **3 cycle にわたって再発した**。原因は毎回「見つかった漏れを 1 つ足す」修正をしていたこと。正規化型に書き換えた cycle 4 以降、この系統の指摘は出なくなった。

## 詳細

**再発の経過**:

| cycle | 実装 | 漏れたもの |
|---|---|---|
| 初版 | `Verification:[[:space:]]` | bold 装飾 `**Verification:**`（コロン直後の空白が必須だった） |
| cycle 3 | `\*{0,2}Verification\*{0,2}[[:space:]]*:` | バッククォート `` `Verification`: ``、全角コロン `Verification：`、三重アスタリスク、underscore |
| cycle 4 | ``(?i)verification[*_`[:space:]]*[:：]`` | （9 形式 HIT / negative control 3 件 miss を実測。以降 0 件） |

**教訓**: 「特定の形を列挙して拾う」設計は、列挙を 1 つ足すたびに同じレビューが再発する。装飾文字を**文字クラス**で吸収し、全角記号を選択肢に含める形（正規化）にすると打ち止めになる。列挙が 2 個を超えたら、それは列挙ではなく文字クラスで書くべき合図である。

**副次の規則 — 存在判定に「値」を含めない**: 同 PR cycle 2 では、2 段判定の stage 1（マーカーの存在判定）に種別キーワード（`repro|failing_test`）まで一致を要求していたため、**ラベルを取り違えたケースが両段から外れて無音で脱落**した。stage 1 は bare marker の存在だけを見て、値の妥当性検証は stage 2 に任せる。false-positive の WARNING が増えるコストより、silent false-negative のほうが高い。

**authoring 側との非対称を明記する**: 検出側で装飾を吸収するようにしたら、authoring 側 SoT には逆に「装飾を付けるな」というルールを書く。「検出は吸収するが authoring では禁止」という非対称は、読者に伝わるよう明示しないと片側だけが更新される。

## 関連ページ

- [検出 grep と mutation (Edit old_string) は同一の文字列 strictness で実装する](./detection-mutation-strictness-symmetry.md)
- [SoT 同期は detection 側と authoring 側の双方向に書く — 片側だけでは機構が silent に空振りする](../heuristics/sot-bidirectional-detection-and-authoring-sync.md)

## ソース

- [PR #2036 review results (cycle 5, mergeable)](../../raw/reviews/20260727T084223Z-pr-2036.md)
