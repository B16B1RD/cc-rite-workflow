---
title: "Issue body 内 `Scope 外指摘ハンドリングポリシー` 宣言で reviewer advisory finding を Issue 化なし recommendation に降格する"
domain: "heuristics"
promote: rite-plugin
promoted_from: "wiki:/pages/heuristics/issue-body-scope-out-policy-demotes-advisory-finding.md"
promoted_from: "wiki:/pages/heuristics/issue-body-scope-out-policy-demotes-advisory-finding.md"
created: "2026-05-07T19:32:00+09:00"
updated: "2026-08-08T13:37:28Z"
sources:
  - type: "reviews"
    ref: "raw/reviews/20260507T103117Z-pr-885.md"
tags: ["umbrella-issue", "scope-out-policy", "reviewer-finding-demotion", "advisory-finding", "issue-spec-authoring"]
confidence: medium
---

# Issue body 内 `Scope 外指摘ハンドリングポリシー` 宣言で reviewer advisory finding を Issue 化なし recommendation に降格する

## 概要

umbrella Issue (Phase A/B/C 等の段階分割で 1 PR 1 Phase を順次マージする運用) の Issue body 冒頭に明示的な「Scope 外指摘ハンドリングポリシー」セクションを宣言しておくと、その PR 作業中の reviewer による advisory finding (CRITICAL/HIGH 以外の MEDIUM/LOW で blocking しないと reviewer 自身が明記したもの) は **finding ではなく recommendation 扱い**となり、follow-up Issue を起票せず本 PR でも対応しないという `[review:mergeable]` 経路を取れる。これにより各 Phase PR を 1 焦点 1 ファイル単位で軽量にマージし続け、scope drift を構造的に遮断できる。

## 詳細

### canonical な Scope 外ポリシー宣言の文面

```markdown
### Scope 外指摘ハンドリングポリシー

本 Issue 作業中 (interview / 実装 / PR レビュー / `/rite:pr:fix` / `/rite:pr:cleanup` 等)
に発見された **Scope 外の指摘は一切対応しない** (Issue 化もしない)。

- 対象: 本 Issue の `In Scope` に明示的に含まれない全ての提案
  (別ファイルのリファクタ案 / 追加 lint 提案 / 関連する別問題の発見 等)
- 対応方法: reviewer / セルフレビューの双方に対し
  「本 Issue Scope 外につき対応見送り」と明示し、follow-up Issue も起票しない
- 理由: 本 Issue の Phase 構成・PR 単位 (1 PR 1 ファイル / 1 焦点) を厳格に守り、
  scope drift を防ぐため。将来必要になった時点で改めて別 Issue として再起票するか判断する
```

### 降格経路の具体例（Phase A）

起点事例 (charter 適用宣言、本体修正なし、11 files / +22 / -0) のレビューで prompt-engineer から 2 件の advisory finding が出た:

1. **Mislabeling (MEDIUM)**: SKILL.md の「pr/cleanup 系」というラベルが、実際には `commands/pr/references/` 9 ファイルのうち cleanup.md から参照されているのは 1 ファイルのみで、残り 8 ファイルは review.md/fix.md/start.md/wiki/* から参照されている件
2. **表現粒度の非対称性 (LOW)**: cleanup.md の Charter 行は 3 パターン列挙、references/*.md 9 ファイルは 1 パターン

両者とも reviewer 自身が「Phase A スコープ厳守のため本 PR では blocking しない」と明示。umbrella Issue の §「Scope 外指摘ハンドリングポリシー」により:

- finding テーブルから recommendations に移動
- `total_findings = 0` として `[review:mergeable]` を出力
- follow-up Issue 起票なし (Issue 化ポリシーで明示的に禁止されているため)
- PR は umbrella Issue への `Refs` trailer（Phase A）付きで merge し、umbrella Issue は OPEN 継続

### 関連する umbrella Issue spec drift サブパターン

advisory finding が umbrella Issue spec **自身の語法問題**に由来するケースがある。起点事例の MEDIUM finding (mislabeling) は SKILL.md の「pr/cleanup 系」というラベリングが umbrella Issue §4.2 自身の Non-Target Files 表記と矛盾していた件で、本 PR で fix すべき対象ではなく Issue spec の語法 alignment が必要な経路。Scope 外ポリシー宣言があれば advisory として記録され、後続の umbrella Issue 編集 PR で対応可能。

### いつ宣言すべきか

- **必須**: umbrella Issue (Phase 分割で複数 PR を順次マージする運用、本 Issue は OPEN 継続して各 Phase PR は `Closes` ではなく `Refs` で参照する)
- **推奨**: M/L/XL Issue で reviewer の cross-domain advisory が発生しやすい case
- **不要**: 単一 PR で完結する S/XS Issue (scope drift リスクが本質的に低い)

### いつ宣言すべきでないか

- reviewer の CRITICAL/HIGH finding を silent skip するために乱用する経路は禁止 (reviewer self-degradation の検出 quality signal が発火)
- 宣言は「**advisory** な指摘 (reviewer 自身が blocking しないと明記したもの)」に限定する。reviewer が blocking としているものを著者判断で scope-out にすると、`scope-creep-rejection-empirical-gate` 違反となる

## 関連ページ

- Reviewer 自身が「対応不要」と明記する LOW finding は replied-only として尊重し fix loop で再発火させない (`Wiki provenance: ../heuristics/respect-reviewer-no-action-recommendation.md`)
- `rejected(scope-creep)` judgment は cross-validation + empirical revert test で gate する (`Wiki provenance: ../heuristics/scope-creep-rejection-empirical-gate.md`)

## ソース

- PR #885 review results (`Wiki provenance: ../../raw/reviews/20260507T103117Z-pr-885.md`)
