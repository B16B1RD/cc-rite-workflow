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

## Non-blocking Contract (canonical 定義)

「Non-blocking Contract」とは、特定の sub-phase の失敗が **upstream phase 全体を失敗扱いにしない** ことを保証する設計上の契約。`/rite:pr:review` Phase 6.1.a (ローカル JSON 保存) や `/rite:pr:cleanup` Phase 2.5 (review 結果ファイル削除) など複数 phase で参照される。両方とも本セクションの定義を SoT とすること。

**契約の構成要素**:

| 観点 | 規約 |
|------|------|
| **失敗時の戻り値** | sub-phase は WARNING を stderr に出して `exit 0` で early return する (upstream の `||` chain を発火させない)。`set -e` 環境下でも upstream を kill しない |
| **retained flag emit** | `[CONTEXT] {SCOPE}_FAILED=1; reason={reason}` を stderr に必ず emit する。reason 値は各 phase の reason 表で列挙される |
| **IO エラーの可視化** | ファイル不在は silent no-op で OK だが、`rm` / `mkdir` / `mv` 等の **真の IO 失敗** (permission denied / disk full / readonly filesystem) は WARNING + stderr 5 行以上で必ず可視化する。`2>/dev/null` 等の silent suppression は禁止 |
| **Phase 全体の exit code** | 本 sub-phase 単独の失敗では Phase 全体の exit code を変更しない。downstream phase は retained flag を見て分岐する |
| **observability emit の必須化** | 異常終了経路 (signal trap 経由含む) でも `[CONTEXT]` flag が emit されるよう、trap handler 内で flag emit を行う (skip notification phase が flag を読む前提で動作する) |

**適用箇所**:
- `/rite:pr:review` Phase 6.1.a (Local JSON File Save)
- `/rite:pr:cleanup` Phase 2.5 (Review Results File Cleanup)
- 将来追加される sub-phase で「失敗しても upstream を kill しない」契約が必要なものは本セクションを参照すること

**Soft failure との違い**: `/rite:pr:fix` Phase 4.5 で使用される「soft failure」は **致命的だが exit 1 で fix loop を kill せず retained flag で caller に通知する**パターンで、本 Non-blocking Contract と類似する。両者の違いは: Non-blocking Contract は「sub-phase 失敗 = upstream 続行」で **本来非致命的な処理** (ローカル保存、削除) に適用、soft failure は「致命的だが loop 終了させない」で **コミット済み変更を保護したい** ケースに適用する。
