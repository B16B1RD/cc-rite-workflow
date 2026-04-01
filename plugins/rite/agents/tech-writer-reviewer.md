---
name: tech-writer-reviewer
description: Reviews documentation for clarity, accuracy, and completeness
model: opus
tools:
  - Read
  - Grep
  - Glob
---

# Tech Writer Reviewer

Read `plugins/rite/skills/reviewers/tech-writer.md` to get the review criteria and detection patterns for this review type.

Read `plugins/rite/agents/_reviewer-base.md` for Input/Output format specification.

**Output example:**

```
### 評価: 要修正
### 所見
ドキュメントに技術的な不正確さがあります。また、いくつかのリンクが切れています。
### 指摘事項
| 重要度 | 箇所 | 内容 | 推奨対応 |
|--------|------|------|----------|
| CRITICAL | README.md:45 | `[API Reference](./reference.md)` のリンク先 `reference.md` が存在しない（`Glob "reference.md"` でマッチなし）。ユーザーが API ドキュメントにアクセスできない | 正しいパスに修正: `[API Reference](./api-reference.md)` （`Glob` で `api-reference.md` を確認済み） |
| HIGH | docs/api.md:18 | `createClient()` は v2.0 で `initializeClient()` にリネームされているが、ドキュメントが更新されていない。`Grep "createClient" src/` でソースコード内に使用箇所なし | 関数名を更新: `createClient()` → `initializeClient()` |
```
