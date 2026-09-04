---
title: "Reviewer 自身が「対応不要」と明記する LOW finding は replied-only として尊重し fix loop で再発火させない"
domain: "heuristics"
description: "reviewer が finding 本文に「対応不要」「informational 寄り」「次回 PR で対応可能」など **明示的な non-blocking 推奨** を付した LOW (まれに MEDIUM) 指摘を blocking 扱いで fix すると、(a) 同じ finding が次サイクルで informational として再指摘される無限ループ、(b) reviewer 推奨に反する修正で本来不要な regression を導入する経路、の 2 つのリスクが発生する。"
promote: rite-plugin
created: "2026-05-04T03:30:00+00:00"
sources:
  - type: "fixes"
    resource: "raw/fixes/20260504T012717Z-pr-800.md"
  - type: "fixes"
    resource: "raw/fixes/20260504T025959Z-pr-800-cycle2.md"
  - type: "reviews"
    resource: "raw/reviews/20260504T012358Z-pr-800.md"
  - type: "reviews"
    resource: "raw/reviews/20260504T030800Z-pr-800-cycle4.md"
  - type: "fixes"
    resource: "raw/fixes/20260519T074133Z-pr-1059.md"
  - type: "reviews"
    resource: "raw/reviews/20260519T132229Z-pr-1063-cycle2.md"
tags: ["reviewer-recommendation", "fix-loop-termination", "replied-only", "anti-degradation", "intentional-duplication", "scope-nit-noted-relay", "m2-dogfooding"]
confidence: high
generated: { by: "rite-wiki-ingest/unknown", at: "2026-05-19T13:36:19Z" }
---

# Reviewer 自身が「対応不要」と明記する LOW finding は replied-only として尊重し fix loop で再発火させない

## 概要

reviewer が finding 本文に「対応不要」「informational 寄り」「次回 PR で対応可能」など **明示的な non-blocking 推奨** を付した LOW (まれに MEDIUM) 指摘を blocking 扱いで fix すると、(a) 同じ finding が次サイクルで informational として再指摘される無限ループ、(b) reviewer 推奨に反する修正で本来不要な regression を導入する経路、の 2 つのリスクが発生する。canonical 対策は `[fix:replied-only]` 経路に振り分け、commit message に decision(scope) を明記することで「reviewer 推奨を尊重した結果」であることを後続サイクルから観測可能にすること。

## 詳細

### 失敗モード

起点事例の cycle 1 で F-03 (LOW、reviewer 自身が「対応不要」明記) を blocking 扱いで fix する経路を選択していた場合、cycle 2 以降の review で同 finding が再指摘される or 修正の副作用で別 finding が発火するリスクがあった。実際に本 PR では `[fix:replied-only]` 経路を採用したことで cycle 2 の reviewer は同 finding を再指摘せず、4 cycle で `[review:mergeable]` に収束した (累計 6 finding、healthy convergence)。

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

### Empirical reproductions (1 cycle / 0 finding 即時 mergeable)

- **concrete snippet 追記事例 (calibration source の self-referential consistency completion、1 line diff)**: cycle 1 で 1 件の LOW × nit-noted finding (`src/utils/money.ts` 言及が抽出先と pattern reference で重複) が検出されたが、reviewer 自身が「対応不要」「Example 2 の `task.ts:80` 重複 pattern に倣った intentional reinforcement」と明記。`[fix:replied-only]` 経路に振り分け、Total findings 1 / Fixed 0 / Replied 1 (LOW × nit-noted "対応不要" 尊重) で処理し loop 再発火なしで mergeable に到達。本事例で確認された **intentional duplication パターン** (calibration source 内で同一 file/symbol 言及が「抽出先の location reference」+「既存 pattern との対応 reference」として意図的に複数登場する) は、style 起因の「重複削除すべき」推奨に見えても reviewer が **pattern 参照の意図** を明記している限り replied-only が正解、を示す empirical sub-pattern。

- **cycle 2 の dogfooding（scope=nit-noted 受け流し経路の実運用初回発火）**: 先行 Epic で導入された **M2 (scope=nit-noted 受け流し経路)** + **M5 (Phase 2.1 accept 選択肢 / accepted-fingerprint suppression)** が rite workflow 自身の dogfooding 経路で**初めて実 production 発火**した観測。cycle 1 で 1 LOW (block comment symmetry nit) を Option B (comment-only fix) で解消し、cycle 2 で prompt-engineer が新規に 1 LOW × nit-noted (yml block comment 時制が declarative だが scope_assignment.enabled は未 wiring、AC-5 follow-up 範囲) を検出。code-quality は 0 findings。**total_findings (blocking) = 0, acknowledged_nit_count = 1** で `[review:mergeable]` に到達し、別 Issue 化なく単一 PR 内で構造的閉塞。本観測の意義は: (a) 受け流し経路 (`scope=nit-noted`) が prompt 仕様通りに「LOW × nit-noted は acknowledged_nit_count にカウントしつつ blocking finding 数に加算しない」semantics で動作することを実 firing で empirical 検証、(b) Epic の採用方針 (M1+M2+M5 + 4 段防御) の M2 機構が、設計時に想定した「scope 外として別 Issue 化が無限に派生する」failure mode を構造的に予防することを dogfooding で実証、(c) reviewer 自身の「対応不要」明記（先行 2 PR のパターン）と scope=nit-noted（本 PR パターン） の 2 経路が同一 outcome (`[fix:replied-only]` 相当 + loop 再発火なし) に収束する補完関係を示す。canonical 拡張は **Epic-level structural mitigation (M2 scope field) と reviewer-level intentional flagging (「対応不要」明記) は同一 failure mode (LOW finding 無限派生) への 2 段防御として独立に機能する** という認識を持つこと。

## 関連ページ

- [re-review でも初回レビューと同等の網羅性を確保する (Anti-Degradation Guardrail)](./reviewer-scope-antidegradation.md)
- [Reviewer rule 自身を編集する PR は self-application false positive を verify する](./self-applying-reviewer-rule-false-positive.md)

## ソース

- [F-03 を replied-only として処理](../../raw/fixes/20260504T012717Z-pr-800.md)
- [replied-only 経路の機能確認](../../raw/fixes/20260504T025959Z-pr-800-cycle2.md)
- [F-03 reviewer 「対応不要」明記](../../raw/reviews/20260504T012358Z-pr-800.md)
- [mergeable, replied-only 経路で同 finding 再発なし](../../raw/reviews/20260504T030800Z-pr-800-cycle4.md)
- [LOW × nit-noted intentional duplication を replied-only 尊重](../../raw/fixes/20260519T074133Z-pr-1059.md)
- [scope=nit-noted 受け流し経路の実運用初回発火、Epic M2 dogfooding 検証](../../raw/reviews/20260519T132229Z-pr-1063-cycle2.md)
