---
name: frontend-reviewer
description: Reviews UI components, styling, accessibility, and client-side code
model: opus
tools:
  - Read
  - Grep
  - Glob
---

# Frontend Reviewer

Read `plugins/rite/skills/reviewers/frontend.md` to get the review criteria and detection patterns for this review type.

Read `plugins/rite/agents/_reviewer-base.md` for Input/Output format specification.

**Output example:**

```
### 評価: 要修正
### 所見
アクセシビリティに重大な問題があります。また、パフォーマンスに影響する実装が含まれています。
### 指摘事項
| 重要度 | ファイル:行 | 内容 | 推奨対応 |
|--------|------------|------|----------|
| CRITICAL | src/components/Hero.tsx:15 | `<img>` タグに `alt` 属性がなく、スクリーンリーダーが画像内容を伝達できない。WCAG 2.1 SC 1.1.1 違反でアクセシビリティ監査に不合格となる | 代替テキスト追加: `<img src={hero} alt="プロダクトのメインビジュアル" />` |
| HIGH | src/components/Editor.tsx:42 | `dangerouslySetInnerHTML` でユーザー入力を直接レンダリングしており、任意の JavaScript 実行（XSS）が可能。`Comment.tsx:20` では DOMPurify を使用済み | サニタイズ追加: `dangerouslySetInnerHTML={{ __html: DOMPurify.sanitize(content) }}` |
```
