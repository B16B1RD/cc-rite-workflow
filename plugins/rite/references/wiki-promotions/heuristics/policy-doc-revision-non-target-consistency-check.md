---
type: "heuristics"
title: "ポリシー分類ドキュメント改訂では、意図的に対象外とした既存要素が新記述と矛盾しないか確認する"
domain: "heuristics"
promote: rite-plugin
promoted_from: "wiki:/pages/heuristics/policy-doc-revision-non-target-consistency-check.md"
description: "frontmatter ポリシー表のような分類ルールを新設・改訂する際、変更対象のスキルだけでなく、意図的に変更しなかった既存要素（Non-Target）が新しい分類ルールの記述内容と実際に矛盾しないかを確認するチェックが有効。"
created: "2026-07-01T15:35:00+09:00"
updated: "2026-07-02T18:21:39+09:00"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260701T051115Z-pr-1694.md"
  - type: "reviews"
    ref: "raw/reviews/20260701T052256Z-pr-1694-cycle2.md"
  - type: "reviews"
    ref: "raw/reviews/20260701T060811Z-pr-1694.md"
  - type: "fixes"
    ref: "raw/fixes/20260701T051428Z-pr-1694.md"
  - type: "fixes"
    ref: "raw/fixes/20260701T060350Z-pr-1694.md"
  - type: "reviews"
    ref: "raw/reviews/20260702T091438Z-pr-1724.md"
tags: []
confidence: medium
---

# ポリシー分類ドキュメント改訂では、意図的に対象外とした既存要素が新記述と矛盾しないか確認する

## 概要

frontmatter ポリシー表のような分類ルールを新設・改訂する PR では、変更対象のファイルだけでなく、意図的に変更しなかった既存要素（Non-Target）が新しい分類ルールの記述内容と矛盾しないかを確認するチェックが有効。

## 詳細

`disable-model-invocation` frontmatter を 14 スキルから削除した PR で、`docs/SPEC.md` の frontmatter ポリシー表を「user-invocable」「純 sub-skill」の 2 区分から、Read 経由のみ到達する `reviewers` を説明する第 3 区分を加えた 3 区分に拡張した。

- cycle 1: tech-writer と prompt-engineer の 2 名が独立に「新しい 2 区分表が `reviewers/SKILL.md`（Read 経由でのみ到達する non-user-invocable knowledge スキル）という既存のエッジケースをカバーできていない」ことを指摘し、cross-validation で High Confidence となった（HIGH 1件）。
- cycle 1 fix: 第 3 区分をポリシー表に追記することで解消。Non-Target File（`reviewers/SKILL.md`）自体には手を触れず、ドキュメント側でギャップを埋めるアプローチを採用。
- cycle 2: 新設した第 3 区分の記述自体に対する再検証で、レビュアーが「upstream issue の状態」「Required 列のセマンティクス」等の周辺懸念を最初は指摘しかけたが、深掘り検証の結果、実装上の欠陥ではなく `design_confirmation`（対応不要）に分類し直した。
- cycle 3: 表面的には「指摘 0 件・mergeable」と判定されたが、実際には prompt-engineer から MEDIUM 指摘（`docs/SPEC.md:326` の第 3 区分が主張する「`reviewers` は `/rite:<name>` を持たない」という前提が、`reviewers/SKILL.md` に実際には `user-invocable: false` が設定されていないため frontmatter 上の裏付けを欠く、という論理矛盾）が出ていたが、エージェント応答の受け渡し不具合により見落とされたまま PR がマージされた（follow-up Issue を起票）。

**教訓**: 新しい分類ルールを文書化するとき、ルールが「対象外」とする既存要素についても、その要素の実際の設定値（本件では frontmatter フィールド）を Grep/Read で確認し、ルールの前提となる主張（「〜は `/rite:<name>` を持たない」等）が実態と一致しているか検証する必要がある。ドキュメント修正 PR では、この種の「ルールの記述と対象外要素の実態との整合性」チェックが、通常の「変更箇所の正確性」チェックとは独立した観点として抜けやすい。

### 先行 PR の defect を修正した PR で追加された 2 次元

先行 PR で follow-up 化された欠陥を修正する PR で、同じ「frontmatter ポリシー整合性」テーマの別次元 2 つを 3 cycle 収束で実測した:

- **frontmatter-body scope 不一致**: `reviewers` の frontmatter `description` をトリガー語列挙（broad）から否定形規約（narrow）へ書き換えたが、本文の見出し `## Auto-Activation` +「This skill is activated during /rite:review」を残したため frontmatter と本文が矛盾した（prompt-engineer Sub-check 6c 抵触、cycle 1 MEDIUM）。frontmatter description を編集する PR は、その broad/narrow 性に依存する **本文見出し** の整合も同時に確認する。→ 本文を `## Invocation`「loaded via Read ... does not auto-activate」へ改めて解消。
- **同 PR 内 SPEC 自己矛盾**: 同 PR の別コミットで書いた SPEC ポリシー記述が「reviewers は **broad description** のため disable-model-invocation を併用」と説明したが、その broad description は同一 PR の cycle 1 で narrow 化済みだった。「自分が同 PR 内で変更した状態」を織り込まずにポリシー文を書くと、SPEC が実態を誤記述する（cycle 2 LOW）。ポリシー文は過去の状態でなく **同 PR 適用後の状態** を前提に書く。
- **Non-Target 実態確認の再実証**: #1694 で見落とされた「`reviewers` の frontmatter に `user-invocable: false` があるか」の確認漏れと同型の欠陥が、#1713 では `rite-workflow`（`user-invocable: false` を持たず default true = 実際は user-invocable）で再発。「default が off」の思い込みを避け、`user-invocable` 未指定時 default true を踏まえて frontmatter 実値 + スキル一覧の `/rite:<name>` 存在を実機確認する。

## 関連ページ

- Asymmetric Fix Transcription (対称位置への伝播漏れ) (`Wiki provenance: ../anti-patterns/asymmetric-fix-transcription.md`)

## ソース

- Review results (`Wiki provenance: ../../raw/reviews/20260701T051115Z-pr-1694.md`)
- Fix results (`Wiki provenance: ../../raw/fixes/20260701T060350Z-pr-1694.md`)
- Review results (`Wiki provenance: ../../raw/reviews/20260702T091438Z-pr-1724.md`)
