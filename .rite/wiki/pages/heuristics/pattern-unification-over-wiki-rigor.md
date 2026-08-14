---
title: "Pattern 統一 follow-up PR では Wiki 経験則違反でも統一を優先する"
domain: "heuristics"
description: "過去 PR で merge 済みのパターンとの統一を目的とする follow-up PR (cycle N 推奨事項として別 PR 化された scope cleanup) では、Wiki 経験則違反 (overclaim 語彙等) であってもパターン統一を優先し、改善は別 Issue で追跡する。"
promote: rite-plugin
created: "2026-05-15T15:05:00+09:00"
sources:
  - type: "reviews"
    resource: "raw/reviews/20260515T054955Z-pr-973.md"
tags: ["wiki", "review", "follow-up", "consistency"]
confidence: medium
generated: { by: "rite-wiki-ingest/unknown", at: "2026-05-15T15:05:00+09:00" }
---

# Pattern 統一 follow-up PR では Wiki 経験則違反でも統一を優先する

## 概要

過去 PR で merge 済みのパターンとの統一を目的とする follow-up PR (cycle N 推奨事項として別 PR 化された scope cleanup) では、Wiki 経験則違反 (overclaim 語彙等) であってもパターン統一を優先し、改善は別 Issue で追跡する。

## 詳細

### 発生文脈

先行 PR で確立された scope-explicit パターンへの統一を目的とする follow-up PR の事例。修正後コメントには「create-interview workflow **専用**」「本 sub-skill は**対象外**」という、Wiki 経験則「[Scope drift fix での overclaim substitution](../anti-patterns/scope-drift-fix-overclaim-substitution.md)」が回避を求める overclaim 語彙が含まれていた。

### 判断分岐

2 reviewers (prompt-engineer + code-quality) は以下の根拠で本 PR を blocking とせず**推奨事項に降格**:

1. **Issue 本文の明示的目的**: `PR #969 と同じパターンで統一する` (Issue 本文の verbatim 引用) が宣言されている
2. **SoT との byte-level 同型**: 修正後文言が start-finalize.md（先行 PR で merge 済）と完全一致
3. **test SCOPE 自身の declaration**: `4-site-symmetry.test.sh` header に「create-interview workflow 専用」と明示されており、test 自身の scope 宣言と一致する事実記述である
4. **trade-off の scope 外性**: overclaim 一括書き換えは当該先行 PR を含む複数 PR の同期書き換えを要し、本 PR scope を超える

### 適用ルール

follow-up PR で Wiki 経験則違反を検出した場合、reviewer は以下を判定する:

| 条件 | アクション |
|------|----------|
| 元 PR (merged) の文言と byte-level 同型で、Issue がパターン統一を明示宣言 | **推奨事項に降格** + 別 Issue 化を提案 |
| 元 PR の文言と乖離していて新たに overclaim を導入 | **blocking として finding 化** |
| パターン統一目的だが、Issue 本文にその目的が明示されていない | **AskUserQuestion でユーザー確認** (どちらの優先度を取るか曖昧なため) |

### 根拠

Wiki 経験則は「将来の修正で適用する規範」として記録されたものであり、過去 merge 済みパターンを retroactive に書き換える義務までは含意しない。consistency (PR 間の文言一致) と wiki-rigor (個別 PR での経験則遵守) はトレードオフ関係にあり、follow-up PR ではユーザー意図 (Issue 本文の宣言) を decisive な判断基準とする。

### 反例

「先行 PR と同じパターンで」と Issue が宣言していない単なる cleanup PR では、本ヒューリスティックは適用されない。Wiki 経験則違反は通常通り blocking として扱う。

## 関連ページ

- [Scope drift fix での overclaim substitution](../anti-patterns/scope-drift-fix-overclaim-substitution.md)

## ソース

- [PR #973 review results](../../raw/reviews/20260515T054955Z-pr-973.md)
