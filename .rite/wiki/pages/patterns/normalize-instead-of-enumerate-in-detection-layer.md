---
type: "patterns"
title: "検出層の表記ゆれ対応は「列挙」ではなく「正規化」で吸収する"
domain: "patterns"
description: "過去のレビュー事例では、マーカー検出の stage 1 regex に対する同種の指摘が **3 cycle にわたって再発した**。"
created: "2026-07-27T17:54:54+09:00"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260727T084223Z-pr-2036.md"
  - type: "fixes"
    resource: "raw/fixes/20260727T053017Z-pr-2036.md"
  - type: "reviews"
    resource: "raw/reviews/20260729T064538Z-pr-2044.md"
  - type: "fixes"
    resource: "raw/fixes/20260729T064931Z-pr-2044.md"
  - type: "fixes"
    resource: "raw/fixes/20260729T071243Z-pr-2044.md"
  - type: "fixes"
    resource: "raw/fixes/20260729T075214Z-pr-2044.md"
tags: []
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-07-29T21:32:36+09:00" }
---

# 検出層の表記ゆれ対応は「列挙」ではなく「正規化」で吸収する

## 概要

起点事例では、マーカー検出の stage 1 regex に対する同種の指摘が **3 cycle にわたって再発した**。原因は毎回「見つかった漏れを 1 つ足す」修正をしていたこと。正規化型に書き換えた cycle 4 以降、この系統の指摘は出なくなった。

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

## 補強: 散文の場合分けも「列挙」ではなく「畳み込み」で吸収する

同じ原理が、検出 regex だけでなく**散文の場合分け**にも効く。

### 「失敗」と「未到達」を別軸に分けた列挙は 2x2 になる

「A も B も失敗」「A の前に終了」の 2 件を挙げて網羅を宣言すると、**「A が走って失敗 × B に未到達」の象限が漏れる**。しかもこの漏れた象限こそ「通知が一切出ない唯一の経路」であることが多い — B に到達しないと B が emit する marker が無く、その marker を条件とする注意行も出ないため。

対策は総論を **「A も B も消せていない（失敗したか、到達しなかったか）」と 1 条件に畳む**こと。畳めば象限の数え落としが構造的に起きない。内訳を残す場合も、到達しない象限では通知自体が出ないことを併記する。

### 場合分けを増やしたら「各ケースで何が観測できるか」も同時に更新する

ケースを足したのに観測可能 signal を一括で書くと、そのブロック自体が未実行のケースで「signal は出る」と嘘になる。「WARNING を探して見つからない」ことを「この失敗モードではない」と誤読させる。**ケースを足すときは、そのケースで何が出て何が出ないかをケース単位で書く。**

### 直交する劣化軸はラベルを増やさず pre-fill で吸収する

劣化軸を 1 つずつ足して (a)/(b)/(b')/(c) とラベルを積むと条件表が肥大する。テンプレート集約事例では 5 cycle の積み上げの結果、**3 テンプレートで 4 象限を覆う**構造になり、1 テンプレートが 2 象限を兼ねる代償として片方の象限で**既に判明している情報を捨てる**欠陥が生まれた。

**判断基準は直交性** — 新しい劣化軸が既存分岐と**直交**するなら差し替え / pre-fill として吸収し、**排他**ならラベルを足す。直交する軸をラベルで表現すると組み合わせ爆発する。畳み込みの形は「1 テンプレート + 軸ごとの optional pre-fill 表」で、得られた側は必ず埋め、得られなかった側だけを解決手順へ置き換える。各象限が独立に正しく縮退し、情報を捨てる経路が構造的に消える。

## ソース（追記分）

- [PR #2044 review results (cycle 2) — 2 軸の成否の組み合わせを散文で列挙すると象限を取りこぼす](../../raw/reviews/20260729T064538Z-pr-2044.md)
- [PR #2044 fix results (cycle 2) — 「失敗」と「未到達」は 2x2 になる](../../raw/fixes/20260729T064931Z-pr-2044.md)
- [PR #2044 fix results (cycle 3) — 劣化軸が増えても分岐ラベルは増やさない](../../raw/fixes/20260729T071243Z-pr-2044.md)
- [PR #2044 fix results (cycle 5) — 1 テンプレート + 軸ごとの pre-fill への畳み込み](../../raw/fixes/20260729T075214Z-pr-2044.md)
