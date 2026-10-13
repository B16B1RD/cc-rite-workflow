---
type: "heuristics"
title: "散文手順のレビューでは、実測アンカーを付けられるのは手順を実行して挙動を観測できる指摘だけで、字面整合の指摘は non-blocking にする"
domain: "heuristics"
description: "散文手順（LLM が runtime で読むワークフロー定義）のレビューでは、grep / sed で文書自身のテキストを並べるだけの字面整合の指摘は実測アンカーとして不適格で non-blocking になる。アンカーが適格なのは、記述された手順を実行して出力や成果物の破損といった挙動的帰結を観測できる指摘だけ。"
created: "2026-07-30T15:40:55Z"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260730T052429Z-pr-2056.md"
  - type: "reviews"
    resource: "raw/reviews/20260730T055209Z-pr-2056.md"
  - type: "reviews"
    resource: "raw/reviews/20260730T093514Z-pr-2056.md"
  - type: "reviews"
    resource: "raw/reviews/20260730T073356Z-pr-2056.md"
  - type: "reviews"
    resource: "raw/reviews/20260730T114443Z-pr-2056.md"
tags: ["review", "measurement", "prose-procedure", "verification", "convergence"]
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-07-30T15:40:55Z" }
---

# 散文手順のレビューでは、実測アンカーを付けられるのは手順を実行して挙動を観測できる指摘だけで、字面整合の指摘は non-blocking にする

## 概要

（現行仕様では廃止: 見出し順・分岐表・文字列を grep / sed で並べて実測アンカーにし blocking にする方法は適格でない。文書自身のテキスト差分のみを観測する字面整合の指摘はアンカー不適格で non-blocking となり、アンカーが適格なのは、記述された手順を実行して成果物の破損などの挙動的帰結を観測できる指摘のみ。）

## 詳細

### 実測アンカー付与率と収束速度

実測アンカーの付与率が上がると、non-blocking として滞留する指摘が減り収束が速くなる（実測: cycle 2 で 6/9、cycle 3 で 5/5 に上がった cycle で、評価が「要修正」→「条件付き」へ、CRITICAL が消え、指摘が 6→4 件へ減った）。

### 手順書の断定は「書いた通りに走らせて観測する」と検証できる

reviewer prompt に裏取り指示を追記したところ、3 reviewer とも `gh issue view` / `git log --grep` / `gh api commits` を実際に実行し、仕様中の番号参照・stderr 文言・語境界 regex を実測で確認した。**手順書に書かれた断定は、その手順を実行して出力と突き合わせれば検証できる。**

### reviewer の仕様疑問も実測で検証してから採否を決める

reviewer が挙げる「仕様への疑問」は、実ファイルで裏取りしてから採否を決める。実例では 4 点すべてが「実装の読み替えが唯一の整合解 / pre-existing の配線ギャップ / 方針の範囲内」と確認でき、仕様変更は不要だった。

### reviewer の実測値も検算する価値がある

PR 本文が申告した数値が不正確なことがある（「行頭アンカー化で散文衝突 3 件が消える」→ 実測では 1 件しか収束せず、残り 2 件は 0 件へ落ちた）。結論の方向は申告より強く支持される場合もあるが、**数値の精度自体が主題である PR では訂正する**。

測定条件を変えたら**数値の帰属先も更新する**。別パターンの測定値を素のパターンの値として書くと、桁違いの過少申告になる（実測: 「正当な解決 4 件を失う」と書いた値が、素の行頭アンカーでは 294 件だった）。

### 収束は「指摘が減る」ではなく「指摘の種類が変わる」形で来る

cycle 1〜3 は規則の欠落、cycle 4 は規則の適用範囲、cycle 5 は宣言と実体の不一致、と抽象度が上がりながら件数が 6 → 5 → 1 → 0 と減った。**同じ層の指摘が 2 cycle 続いたらクラス単位で閉じる**（個別に潰すと反対側が次 cycle に出る）。

### 上限 cycle では判断基準を prompt 側で固定すると reviewer の判定が揃う

最終 cycle で「merge を止める欠陥だけ」を明示的に求め、必須自問の厳格適用を prompt に明記したところ、3 reviewer のうち 2 名が推奨事項へ降格させて指摘 0 件の「可」を返した。**収束判定が reviewer の裁量ぶれに左右されにくくなる。**

## 関連ページ

- [ドキュメントレビューは実装を grep で検証する](./docs-review-implementation-grep-verification.md)
- [収束しないレビューループは構造を疑う](./non-converging-review-loop-suspect-structure.md)

## ソース

- [散文でも構造的事実は実測できる](../../raw/reviews/20260730T052429Z-pr-2056.md)
- [実測アンカー付与率と収束](../../raw/reviews/20260730T055209Z-pr-2056.md)
- [reviewer 側の裏取り指示が機能した](../../raw/reviews/20260730T093514Z-pr-2056.md)
- [仕様疑問の実測検証](../../raw/reviews/20260730T073356Z-pr-2056.md)
- [収束は指摘の種類が変わる形で来る / 上限 cycle の判断基準固定](../../raw/reviews/20260730T114443Z-pr-2056.md)
