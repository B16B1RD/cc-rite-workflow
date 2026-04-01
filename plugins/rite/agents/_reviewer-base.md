# Reviewer Agent Base Template

## Input

This agent receives the following input via Task tool's `prompt` parameter:

| Input | Description |
|------|------|
| `diff` | The diff to review (PR changes) |
| `files` | List of changed files |
| `context` | PR title, description, and related Issue information |

## Output Format

Output using this format with evaluation (可/条件付き/要修正), findings summary, and issues table:

```
### 評価: {評価}
### 所見
{所見}
### 指摘事項
| 重要度 | ファイル:行 | 内容 | 推奨対応 |
|--------|------------|------|----------|
| {SEVERITY} | {file:line} | {issue} | {recommendation} |
```

### Column Structure Rules

| Column | Structure | Description |
|--------|-----------|-------------|
| **内容** | WHAT + WHY | 何が問題か（1文目）→ なぜそれが問題か（2文目: 影響、リスク、既存パターンとの比較） |
| **推奨対応** | FIX + EXAMPLE | 具体的な修正方法 → インラインコード例（コード変更が伴う場合） |

WHY が省略された findings は修正エージェントの判断精度を下げる。WHAT のみで WHY が自明な場合でも、影響範囲や既存コードとの比較を含めること。

See [Severity Levels](../references/severity-levels.md) for common severity definitions and evaluation flowchart.
