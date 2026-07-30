---
type: "heuristics"
title: "散文手順のレビューでも文書内の構造的事実は実測でき、実測不能と決めつけると指摘が滞留する"
domain: "heuristics"
description: "prose-only の変更は構造的に実測不能と決めつけると、同じ欠陥が cycle を跨いで non-blocking のまま滞留する。見出しの順序・分岐表の条件・特定文字列の有無・参照先の行番号は grep -n / sed -n で観測でき、それが実測アンカーの正当な根拠になる。実測アンカー付与率が上がると収束が速くなる。"
created: "2026-07-30T15:40:55Z"
updated: "2026-07-30T15:40:55Z"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260730T052429Z-pr-2056.md"
  - type: "reviews"
    ref: "raw/reviews/20260730T055209Z-pr-2056.md"
  - type: "reviews"
    ref: "raw/reviews/20260730T093514Z-pr-2056.md"
  - type: "reviews"
    ref: "raw/reviews/20260730T073356Z-pr-2056.md"
tags: ["review", "measurement", "prose-procedure", "verification", "convergence"]
confidence: high
---

# 散文手順のレビューでも文書内の構造的事実は実測でき、実測不能と決めつけると指摘が滞留する

## 概要

散文手順（LLM が runtime で読むワークフロー定義）のレビューでは、**実測アンカーを付けられるかどうかが reviewer 側の技量差として現れる**。同一の欠陥に対し、片方の reviewer は「prose-only の変更は構造的に実測不能」としてアンカー無しで報告し、もう片方は `grep` / `sed` による構造の実測をアンカーにして blocking として報告した。

**散文でも「文書内の構造的事実」は実測できる。** 見出しの順序、分岐表の条件、特定文字列の有無、参照先の行番号は `grep -n` / `sed -n` で観測でき、それが実測の正当な根拠になる。実測不能と決めつけると、同じ欠陥が cycle を跨いで non-blocking のまま滞留する。

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

- [PR #2056 review results (cycle 2) — 散文でも構造的事実は実測できる](../../raw/reviews/20260730T052429Z-pr-2056.md)
- [PR #2056 review results (cycle 3) — 実測アンカー付与率と収束](../../raw/reviews/20260730T055209Z-pr-2056.md)
- [PR #2056 review results — reviewer 側の裏取り指示が機能した](../../raw/reviews/20260730T093514Z-pr-2056.md)
- [PR #2056 review results (cycle 1) — 仕様疑問の実測検証](../../raw/reviews/20260730T073356Z-pr-2056.md)
