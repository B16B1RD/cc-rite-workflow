---
type: "heuristics"
title: "レビュアーの結論が正面から割れたら、勝敗を決める前に語の多義性を疑う"
domain: "heuristics"
promote: rite-plugin
description: "`/rite:pr-review` の cross-validation で 2 レビュアーが同一箇所に対して逆の総合評価（修正必要 / マージ可）を出したとき、討論フェーズの既定の動きは「どちらの主張が正しいか」を決めることになりがちだが、**割れたこと自体が本文の曖昧性の兆候**であることが多い。"
created: "2026-08-02T11:59:42+09:00"
sources:
  - type: "fixes"
    resource: "raw/fixes/20260802T023626Z-pr-2084.md"
  - type: "reviews"
    resource: "raw/reviews/20260802T025011Z-pr-2084.md"
tags: [review-loop, cross-validation, debate-phase]
confidence: medium
generated: { by: "rite-wiki-ingest/unknown", at: "2026-08-02T11:59:42+09:00" }
---

# レビュアーの結論が正面から割れたら、勝敗を決める前に語の多義性を疑う

## 概要

`/rite:pr-review` の cross-validation で 2 レビュアーが同一箇所に対して逆の総合評価（修正必要 / マージ可）を出したとき、討論フェーズの既定の動きは「どちらの主張が正しいか」を決めることになりがちだが、**割れたこと自体が本文の曖昧性の兆候**であることが多い。両者が同じ語を別の意味に読んでいないかを先に確認し、多義性が原因なら語を一意にする。勝敗ではなく語の確定が解になる場合、1 回の修正で両者の懸念が同時に消える。

## 詳細

### 発生事例（Issue テンプレートの規則文言、cycle 3）

Issue テンプレート Section 9 の禁止規則 `an open work item` について:

- **tech-writer**: 「修正必要」。routing 先（作業メモリの計画逸脱ログ）が誤り。逸脱種別 `追加` は "New step discovered during implementation" = 計画に組み込んで実行する新規ステップで、やらないと決めた項目の受け皿ではない
- **code-quality**: 「マージ可」。衝突なし。`an open work item` を「引き受けたが未完了の作業」と読めば `追加` は正しい。逸脱種別に won't-do 型が存在せず、declined 項目を計画逸脱ログへ送る rite 手順も 0 件なので読みは一択

**どちらも正しかった**。code-quality の機械的検証（won't-do 型なし・送る手順 0 件）は読みを一意に確定させるが、**その確定は外部ファイルの知識に依存する**。テンプレート単体を読む生成側 LLM は tech-writer の読みに落ちうる。

### 検討の帰結

両者は「結論」では割れていたが、**求める修正では一致していた** — tech-writer は finding として、code-quality は design_confirmation として、どちらも「`an open work item` を曖昧なままにするな」と言っていた。そこで勝敗を決めず、名詞に限定句を足した:

- `an open work item` → `an open work item you have taken on`
- 許可側に `and so does the work item it declines` を明記

次 cycle で両 reviewer とも新規指摘 0 件・収束判定となった。

### 手順

1. 結論が割れた争点を特定する
2. 両者の推奨事項（`分類: actionable` / `design_confirmation` / `boundary` を含む）まで読む。**結論が割れていても推奨で一致していることがある**
3. 一致点があれば、それが求める修正。severity は高い方を採用する（`/rite:pr-review` ステップ 5.2.1 の合意規約と同じ）
4. 推奨も割れているなら、そこで初めて主張の当否を検討する

### 適用範囲の注意

本ヒューリスティックは「同一箇所への逆評価」に限る。異なる箇所への異なる指摘は単に並列の finding であり、多義性とは関係ない。また CRITICAL severity が絡む矛盾は `/rite:pr-review` ステップ 5.2.1 の CRITICAL guard により自動判断せずユーザーへエスカレーションする。

## 関連ページ

- [re-review / verification mode でも初回レビューと同等の網羅性を確保する (Anti-Degradation Guardrail)](./reviewer-scope-antidegradation.md)
- [禁止規則が自分のワークフローと衝突したら、例外条項を足す前に規則の軸を言い換える](./reframe-rule-predicate-over-carve-out.md)

## ソース

- [fix 結果](../../raw/fixes/20260802T023626Z-pr-2084.md)
- [レビュー結果](../../raw/reviews/20260802T025011Z-pr-2084.md)
