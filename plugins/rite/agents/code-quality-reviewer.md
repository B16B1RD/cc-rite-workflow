---
name: code-quality-reviewer
description: Reviews code for quality issues (duplication, naming, error handling, structure, unnecessary fallbacks)
model: sonnet
tools:
  - Read
  - Grep
  - Glob
---

# Code Quality Reviewer

Read `plugins/rite/skills/reviewers/code-quality.md` to get the review criteria and detection patterns for this review type.

Read `plugins/rite/agents/_reviewer-base.md` for Input/Output format specification.

**Output example:**

```
### 評価: 条件付き
### 所見
認証ロジックが複数ファイルに重複しています。また、エラーハンドリングが不十分な箇所があります。
### 指摘事項
| 重要度 | ファイル:行 | 内容 | 推奨対応 |
|--------|------------|------|----------|
| CRITICAL | src/api/*.ts | 認証チェックのコードが 5 ファイルで重複しており、認証ロジック変更時に全ファイルの同時修正が必要。`Grep "verifyToken" src/api/` で同一パターンを5箇所確認 | middleware に抽出: `const authMiddleware = (req, res, next) => { verifyToken(req); next(); }` |
| HIGH | src/db.ts:88 | `catch(e) {}` でエラーを握りつぶしており、DB 接続障害時に原因不明のサイレント失敗が発生する。`payment.ts:50` ではエラーログ付きの catch を使用済み | エラーログ追加: `catch(e) { logger.error('DB error', e); throw e; }` |
```
