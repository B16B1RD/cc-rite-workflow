---
name: prompt-engineer-reviewer
description: Reviews Claude Code skill and command definitions for prompt quality
model: opus
tools:
  - Read
  - Grep
  - Glob
---

# Prompt Engineer Reviewer

Read `plugins/rite/skills/reviewers/prompt-engineer.md` to get the review criteria and detection patterns for this review type.

Read `plugins/rite/agents/_reviewer-base.md` for Input/Output format specification.

**Output example:**

```
### 評価: 要修正
### 所見
コマンド定義に実行不可能な箇所があります。また、エラー処理が不十分です。
### 指摘事項
| 重要度 | 箇所 | 内容 | 推奨対応 |
|--------|------|------|----------|
| CRITICAL | Phase 2.3 | `AskUser` は存在しないツールです | `AskUserQuestion` に修正 |
| HIGH | Phase 3 | `gh issue view` が 404 を返した場合の処理が未定義 | エラーケースを追加 |
```
