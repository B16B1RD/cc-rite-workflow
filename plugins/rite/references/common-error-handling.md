# Common Error Handling Patterns

Shared error patterns referenced by command files. When an error occurs, display the appropriate message, apply the recovery action, and decide whether to continue or abort.

## Standard Error Response Format

```
エラー: {summary}

考えられる原因:
- {cause_1}
- {cause_2}

対処:
1. {action_1}
2. {action_2}
```

## Common Patterns

### Entity Not Found (Issue / PR / Branch)

| Entity | Message | Recovery |
|--------|---------|----------|
| Issue | `エラー: Issue #{number} が見つかりません` | Verify with `gh issue list`, retry with correct number |
| PR | `エラー: PR #{number} が見つかりません` | Verify with `gh pr list`, retry with correct number |
| Branch | `エラー: ブランチ {name} が見つかりません` | Verify with `git branch -a`, check spelling |

Common causes: wrong number/name, entity deleted, different repository.

### Permission Error

```
エラー: {entity} を変更する権限がありません

対処:
1. リポジトリへの書き込み権限を確認
2. `gh auth status` で認証状態を確認
3. 必要に応じて `gh auth login` で再認証
```

### Network / API Error

```
エラー: GitHub API への接続に失敗しました

対処:
1. ネットワーク接続を確認
2. `gh auth status` で認証状態を確認
3. しばらく待ってから再実行
```

For GraphQL API errors, retry up to 3 times with exponential backoff. See [GraphQL Helpers](./graphql-helpers.md#error-handling) for details.

### Projects API Error (Non-Blocking)

When Projects-related API calls fail, display a warning and continue. Projects operations are non-blocking.

```
警告: Projects API の呼び出しに失敗しました
{operation} をスキップします
```
