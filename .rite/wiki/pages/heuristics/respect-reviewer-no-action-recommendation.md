---
title: "Reviewer 自身が「対応不要」と明記する LOW finding は replied-only として尊重し fix loop で再発火させない"
domain: "heuristics"
created: "2026-05-04T03:30:00+00:00"
updated: "2026-05-04T03:30:00+00:00"
sources:
  - type: "fixes"
    ref: "raw/fixes/20260504T012717Z-pr-800.md"
  - type: "fixes"
    ref: "raw/fixes/20260504T025959Z-pr-800-cycle2.md"
  - type: "reviews"
    ref: "raw/reviews/20260504T012358Z-pr-800.md"
  - type: "reviews"
    ref: "raw/reviews/20260504T030800Z-pr-800-cycle4.md"
tags: ["reviewer-recommendation", "fix-loop-termination", "replied-only", "anti-degradation"]
confidence: high
---

# Reviewer 自身が「対応不要」と明記する LOW finding は replied-only として尊重し fix loop で再発火させない

## 概要

reviewer が finding 本文に「対応不要」「informational 寄り」「次回 PR で対応可能」など **明示的な non-blocking 推奨** を付した LOW (まれに MEDIUM) 指摘を blocking 扱いで fix すると、(a) 同じ finding が次サイクルで informational として再指摘される無限ループ、(b) reviewer 推奨に反する修正で本来不要な regression を導入する経路、の 2 つのリスクが発生する。canonical 対策は `[fix:replied-only]` 経路に振り分け、commit message に decision(scope) を明記することで「reviewer 推奨を尊重した結果」であることを後続サイクルから観測可能にすること。

## 詳細

### 失敗モード

PR #800 cycle 1 で F-03 (LOW、reviewer 自身が「対応不要」明記) を blocking 扱いで fix する経路を選択していた場合、cycle 2 以降の review で同 finding が再指摘される or 修正の副作用で別 finding が発火するリスクがあった。実際に本 PR では `[fix:replied-only]` 経路を採用したことで cycle 2 の reviewer は同 finding を再指摘せず、4 cycle で `[review:mergeable]` に収束した (累計 6 finding、healthy convergence)。

### 構造

reviewer が「対応不要」を明示する LOW finding は、以下のいずれかのカテゴリに該当することが多い:

1. **observational nitpick**: 「style として言及するが本 PR の意図と整合しているので fix 推奨ではない」
2. **forward-looking suggestion**: 「PR 7-8 で取り組む方が scope 的に整合する」
3. **informational reference**: 「読者向けの注釈として記録するが既存実装と矛盾しない」

これらを blocking 扱いで fix すると、(a) reviewer の意図 (「観察事項として記録すれば足りる」) と乖離した強制修正、(b) 修正の副作用で正しかった既存記述に regression を導入、のいずれかが発生する経路がある。

### Canonical pattern

1. **reviewer 推奨の literal extract**: finding 本文から「対応不要」「informational」「次回 PR で対応可能」「観察事項」「style nitpick」等の non-blocking キーワードを literal grep で抽出する
2. **`[fix:replied-only]` 経路への振り分け**: 上記キーワードがマッチした finding は fix を実施せず、reply のみ (commit message には含めず PR コメントで応答) で処理する
3. **commit message での decision(scope) 明示**: 同 PR 内で blocking 修正と replied-only を混在させる場合、commit body に `decision(scope): F-NN (reviewer 推奨により replied-only)` を明記し、次サイクル reviewer が「なぜ fix されていないか」を context-free で理解可能にする
4. **次サイクル reviewer prompt への hint**: review prompt 側で「前 cycle で reviewer が『対応不要』明記した finding は再指摘しない」を明示すると loop 効率が更に向上する (将来課題)

### 関連する経験則

reviewer 推奨を尊重する fix-loop ルールは、以下 2 経験則と組み合わせると更に効果が高い:

- [Anti-Degradation Guardrail](./reviewer-scope-antidegradation.md): re-review でも初回スコープを維持しつつ「対応不要」推奨は尊重する両立
- [Reviewer rule の self-application false positive](./self-applying-reviewer-rule-false-positive.md): reviewer 推奨を盲目的に採択せず actual code との cross-check を行う

### 判定基準

- finding 本文中に「対応不要」「informational」「skip 推奨」「次回 PR」「観察事項」「style nitpick」等のキーワードが含まれる場合 → `[fix:replied-only]` 経路採用
- finding severity が LOW 以下、かつ reviewer が non-blocking キーワードを明記している場合 → 同上
- ただし「actual code との不一致を指摘する MEDIUM/HIGH」は reviewer 推奨に関わらず blocking 扱い (false positive リスクは別経験則で扱う)

## 関連ページ

- [re-review でも初回レビューと同等の網羅性を確保する (Anti-Degradation Guardrail)](./reviewer-scope-antidegradation.md)
- [Reviewer rule 自身を編集する PR は self-application false positive を verify する](./self-applying-reviewer-rule-false-positive.md)

## ソース

- [PR #800 cycle 1 fix (F-03 を replied-only として処理)](../../raw/fixes/20260504T012717Z-pr-800.md)
- [PR #800 cycle 2 fix (replied-only 経路の機能確認)](../../raw/fixes/20260504T025959Z-pr-800-cycle2.md)
- [PR #800 cycle 1 review (F-03 reviewer 「対応不要」明記)](../../raw/reviews/20260504T012358Z-pr-800.md)
- [PR #800 cycle 4 review (mergeable, replied-only 経路で同 finding 再発なし)](../../raw/reviews/20260504T030800Z-pr-800-cycle4.md)
