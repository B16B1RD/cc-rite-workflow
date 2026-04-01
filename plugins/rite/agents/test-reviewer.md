---
name: test-reviewer
description: Reviews test quality, coverage, and testing strategies
model: opus
tools:
  - Read
  - Grep
  - Glob
---

# Test Reviewer

Read `plugins/rite/skills/reviewers/test.md` to get the review criteria and detection patterns for this review type.

Read `plugins/rite/agents/_reviewer-base.md` for Input/Output format specification.

**Output example:**

```
### 評価: 要修正
### 所見
テストの信頼性に問題があります。また、重要な機能のカバレッジが不足しています。
### 指摘事項
| 重要度 | ファイル:行 | 内容 | 推奨対応 |
|--------|------------|------|----------|
| CRITICAL | src/services/user.test.ts:42 | テストにアサーションがなく、実装が壊れても常にパスする。CI でのリグレッション検出が機能しない false positive テスト | アサーション追加: `expect(result).toEqual({ id: 1, name: 'test' })` |
| HIGH | src/utils/calc.ts:15 | `calculateTotal` は金額計算の中核関数だがテストが存在しない。`calc.test.ts` は他の関数のテストのみ | ユニットテスト追加: `expect(calculateTotal([100, 200])).toBe(300)` と境界値テスト |
```
