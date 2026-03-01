---
description: Sprint 内の Todo Issue を連続実行
---

# /rite:sprint:execute

Orchestrate sequential execution of Todo Issues within a Sprint. Retrieves Issues by priority, runs `/rite:issue:start` for each, and generates a Sprint completion report.

**Flow:** Identify Sprint → Retrieve Todo Issues → Priority sort + dependency analysis → Sequential `/rite:issue:start` execution → Completion report.

---

Execute phases sequentially.

## Arguments

| Argument | Description |
|----------|-------------|
| `[sprint]` | Target sprint identifier (optional, only when `iteration.enabled: true`). `current` (default), `next`, or sprint title (e.g., `"Sprint 4"`). Ignored when `iteration.enabled: false` |
| `--resume` | Resume interrupted Sprint execution from progress state |

---

## Placeholder Legend

| Placeholder | Description | How to Obtain |
|-------------|-------------|---------------|
| `{owner}` | Repository owner | `gh repo view --json owner --jq '.owner.login'` |
| `{project_number}` | GitHub Projects project number | From `github.projects.project_number` in `rite-config.yml` |
| `{project_id}` | GitHub Projects project ID (GraphQL Node ID) | From Phase 1.1 GraphQL query |
| `{owner_type}` | Owner type (`user` or `organization`) | From `gh api users/{owner} --jq '.type'` (Phase 1.1) |
| `{iteration_id}` | Current iteration ID | From Phase 1.2 via [sprint/current.md](./current.md) Phase 1 logic |
| `{iteration_field_id}` | Iteration field ID | From Phase 1.2 via [sprint/current.md](./current.md) Phase 1.1 query |

Retrieve `{owner}` before Phase 0: `gh repo view --json owner --jq '.owner.login'`

---

## Phase 0: Prerequisites

### 0.1 Load Configuration

Read `rite-config.yml` with Read tool. Extract:
- `iteration.enabled` — determines Issue retrieval method
- `github.projects.enabled` — required for Issue retrieval
- `github.projects.project_number` — project number
- `github.projects.owner` — project owner
- `safety.max_implementation_rounds` — per-Issue safety limit
- `safety.time_budget_minutes` — per-Issue time advisory

**If `projects.enabled: false`**: Display error and exit:

```
エラー: GitHub Projects が無効です。
Sprint 実行には Projects 連携が必要です。

対処:
1. rite-config.yml の github.projects.enabled を true に設定
2. /rite:init を再実行
```

### 0.2 Resume Check

If `--resume` argument is provided:

1. Read `.rite-sprint-state` file (if exists)
2. Display progress and resume from the last incomplete Issue
3. Skip to Phase 3 with the restored state

If `.rite-sprint-state` does not exist:

```
警告: Sprint 実行状態が見つかりません。
新しい Sprint 実行を開始します。
```

Proceed to Phase 1.

---

## Phase 1: Sprint Identification

### 1.1 Retrieve Project ID

**Step 1: Detect Owner Type**

Detect whether the project owner is a User or Organization:

```bash
gh api users/{owner} --jq '.type'
```

Retain the result as `{owner_type}`. Convert to GraphQL root field name: `User` → `user`, `Organization` → `organization`. Use the converted value in subsequent GraphQL queries.

**Step 2: Retrieve Project ID**

```bash
# {owner_type} が "Organization" の場合は user を organization に変更
gh api graphql -f query='
query($owner: String!, $number: Int!) {
  user(login: $owner) {
    projectV2(number: $number) {
      id
    }
  }
}' -f owner="{owner}" -F number={project_number}
```

**Note**: This uses the same `user`-only pattern as other sprint commands (`current.md`, `list.md`). For Organization-owned projects, replace `user` with `organization` in the query. See [GraphQL Helpers](../../references/graphql-helpers.md) for the Owner Type Detection pattern.

### 1.2 Determine Issue Retrieval Method

**If `iteration.enabled: true`**:

Use the current Sprint's Iteration to filter Issues. Follow [sprint/current.md](./current.md) Phase 1 logic to identify the current iteration, then retrieve Issues filtered by that iteration. Retain `{iteration_id}` and `{iteration_field_id}` from the current.md logic for use in Phase 2.1.

**Sprint argument handling** (only when `iteration.enabled: true`):

| `[sprint]` Argument | Action |
|---------------------|--------|
| `current` (default) | Use current.md Phase 1 logic to identify the current iteration |
| `next` | Use current.md Phase 1 logic, then select the iteration immediately following the current one |
| Sprint title (e.g., `"Sprint 4"`) | Search iterations by name match |

**If `iteration.enabled: false`** (fallback):

Retrieve all Issues with Status = "Todo" from the Project directly (no Iteration filter). This is the default for projects that don't use sprints/iterations. The `[sprint]` argument is ignored in this mode.

---

## Phase 2: Todo Issue Retrieval and Sorting

### 2.1 Retrieve Todo Issues

#### When Iteration is enabled

```bash
gh api graphql -f query='
query($projectId: ID!, $iterationId: String!, $fieldId: ID!) {
  node(id: $projectId) {
    ... on ProjectV2 {
      items(first: 100, filter: {
        field: { fieldId: $fieldId, iterationId: $iterationId }
      }) {
        totalCount
        nodes {
          id
          content {
            ... on Issue {
              number
              title
              state
              body
              labels(first: 5) { nodes { name } }
            }
          }
          fieldValues(first: 10) {
            nodes {
              ... on ProjectV2ItemFieldSingleSelectValue {
                name
                field { ... on ProjectV2SingleSelectField { name } }
              }
            }
          }
        }
      }
    }
  }
}' -f projectId="{project_id}" -f iterationId="{iteration_id}" -f fieldId="{iteration_field_id}"
```

Filter results: only items where Status field = "Todo" and Issue state = "OPEN".

#### When Iteration is disabled (fallback)

```bash
gh api graphql -f query='
query($projectId: ID!) {
  node(id: $projectId) {
    ... on ProjectV2 {
      items(first: 100) {
        totalCount
        nodes {
          id
          content {
            ... on Issue {
              number
              title
              state
              body
              labels(first: 5) { nodes { name } }
            }
          }
          fieldValues(first: 10) {
            nodes {
              ... on ProjectV2ItemFieldSingleSelectValue {
                name
                field { ... on ProjectV2SingleSelectField { name } }
              }
            }
          }
        }
      }
    }
  }
}' -f projectId="{project_id}"
```

Filter results: only items where Status field = "Todo" and Issue state = "OPEN".

**If no Todo Issues found** (0 items after filtering):

```
Sprint に未着手の Issue がありません。

次のアクション:
- `/rite:sprint:plan` でバックログから Issue を追加
- `/rite:issue:create` で新規 Issue を作成
- `/rite:sprint:current` で Sprint 状況を確認
```

Exit.

### 2.2 Priority and Complexity Sorting

Sort retrieved Issues by:

1. **Priority** (descending): High > Medium > Low > (unset)
2. **Complexity** (ascending): XS > S > M > L > XL > (unset)

Priority sort puts high-priority items first. Complexity sort within the same priority puts smaller items first (quick wins).

Extract Priority and Complexity from `fieldValues` nodes where field name matches "Priority" or "Complexity".

### 2.3 Dependency Analysis

For each Issue, check for dependencies:

1. **Body references**: Scan Issue body (using Grep or string matching) for patterns like `depends on #XX`, `blocked by #XX`, `after #XX`
2. **Parent-child**: Check if any Issue in the list is a parent of another. Use an additional GraphQL query to retrieve `trackedIssues` for each candidate Issue:
   ```bash
   gh api graphql -f query='
   query($owner: String!, $repo: String!, $number: Int!) {
     repository(owner: $owner, name: $repo) {
       issue(number: $number) {
         trackedIssues(first: 10) { nodes { number } }
       }
     }
   }' -f owner="{owner}" -f repo="{repo}" -F number={issue_number}
   ```
   **Note**: Retrieve `{repo}` for this query: `gh repo view --json name --jq '.name'`

Build a simple dependency graph. If Issue A depends on Issue B, ensure B appears before A in the execution order. If circular dependencies exist, warn and use the priority-based order.

### 2.4 Display Execution Plan

```
## Sprint 実行計画

| # | Issue | Priority | Complexity | 依存 |
|---|-------|----------|------------|------|
| 1 | #{number} {title} | {priority} | {complexity} | - |
| 2 | #{number} {title} | {priority} | {complexity} | #XX |
| 3 | #{number} {title} | {priority} | {complexity} | - |

合計: {count} 件の Issue を実行予定
```

### 2.5 User Confirmation

Use `AskUserQuestion`:

```
上記の順序で Sprint を実行しますか？

オプション:
- 実行を開始（推奨）
- 順序を変更
- キャンセル
```

| Option | Action |
|--------|--------|
| **Start** | Proceed to Phase 3 |
| **Change order** | User specifies new order, redisplay plan, re-confirm |
| **Cancel** | Exit |

---

## Phase 3: Sequential Execution

### 3.0 Initialize Sprint State

Create `.rite-sprint-state` to track progress:

```bash
jq -n \
  --argjson total {total_count} \
  --argjson current 0 \
  --argjson issues '{issue_numbers_json}' \
  --arg started "$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")" \
  '{total: $total, current_index: $current, issues: $issues, completed: [], skipped: [], failed: [], started_at: $started}' \
  > .rite-sprint-state
```

Where `{issue_numbers_json}` is a JSON array of Issue numbers in execution order (e.g., `[42, 45, 48]`).

**Note**: `completed`, `skipped`, and `failed` arrays store objects with Issue details: `[{"issue": 42, "pr": 67}, ...]`. The `pr` field records the PR number created by `/rite:issue:start` for use in the Phase 4 completion report.

### 3.1 Execution Loop

For each Issue in the execution order:

#### 3.1.1 Progress Bar Display

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Sprint 進捗: {completed}/{total} 完了
████████░░░░░░░░░░░░ {percentage}%

次の Issue: #{number} - {title}
Priority: {priority} | Complexity: {complexity}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

#### 3.1.2 Execute Issue

Invoke `/rite:issue:start` via the Skill tool:

```
Skill ツール呼び出し:
  skill: "rite:issue:start"
  args: "{issue_number}"
```

**Wait for completion**. The sub-skill will run the full end-to-end flow (branch → implement → lint → PR → review-fix loop). After completion, capture the PR number from the `[pr:created:{number}]` pattern in the conversation context for use in Phase 3.1.3 and Phase 4.1.

#### 3.1.3 Update Sprint State

After each Issue completes (or fails/skips), update `.rite-sprint-state`:

```bash
TMP_STATE=".rite-sprint-state.tmp.$$"
jq --argjson idx {current_index} \
   --arg status "{completed|skipped|failed}" \
   --argjson entry '{"issue": {issue_number}, "pr": {pr_number_or_null}}' \
   '.current_index = ($idx + 1) | .[$status] += [$entry]' \
   .rite-sprint-state > "$TMP_STATE" && mv "$TMP_STATE" .rite-sprint-state || rm -f "$TMP_STATE"
```

**Note**: `{pr_number_or_null}` is the PR number captured from `/rite:issue:start` output, or `null` if no PR was created (e.g., on skip/failure).

#### 3.1.4 Post-Issue Checkpoint

After each Issue (except the last), display checkpoint and confirm:

```
Issue #{number} が完了しました。（{completed}/{total}）

残り: {remaining} 件
次の Issue: #{next_number} - {next_title}
```

Use `AskUserQuestion`:

```
続行しますか？

オプション:
- 続行（/clear で再開）（推奨）: Sprint 状態を保存し、`/clear` → `/rite:sprint:execute --resume` で新鮮なコンテキストで再開します
- 続行（同セッション）: コンテキストをクリアせず次の Issue に進みます（残りが XS/S の場合のみ推奨）
- 休憩: セッションを中断し、後で /rite:sprint:execute --resume で再開できます
- 中止: Sprint 実行を終了し、完了レポートを表示します
```

| Option | Action |
|--------|--------|
| **Continue (with /clear)** | Save state, display `/clear` + `--resume` instructions, exit. User re-enters with fresh context |
| **Continue (same session)** | Proceed to next Issue directly (3.1.1). Only recommended when remaining Issues are XS/S complexity |
| **Break** | Save state, display resume instructions, exit |
| **Abort** | Proceed to Phase 4 (completion report) |

**Context management note**: `/rite:issue:start` consumes significant context per Issue (branch → implement → lint → PR → review-fix loop). For most cases, "Continue (with /clear)" is the recommended option to ensure each Issue executes with a fresh context window.

#### 3.1.5 Error Handling

If `/rite:issue:start` fails or is interrupted:

Use `AskUserQuestion`:

```
Issue #{number} の実行中にエラーが発生しました。

オプション:
- スキップして次へ: この Issue をスキップし、次の Issue に進みます
- 再試行: この Issue をもう一度実行します
- 中止: Sprint 実行を終了します
```

| Option | Action |
|--------|--------|
| **Skip** | Mark as "skipped" in state, proceed to next |
| **Retry** | Re-invoke `/rite:issue:start` for same Issue |
| **Abort** | Proceed to Phase 4 |

---

## Phase 4: Sprint Completion Report

### 4.1 Generate Report

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
## Sprint 実行完了レポート

### サマリー

| 項目 | 値 |
|------|-----|
| 実行 Issue 数 | {total} |
| 完了 | {completed_count} |
| スキップ | {skipped_count} |
| 失敗 | {failed_count} |
| 所要時間 | {elapsed_time} |

### 完了した Issue

| # | Issue | PR |
|---|-------|----|
| 1 | #{number} {title} | #{pr_number} |
| 2 | #{number} {title} | #{pr_number} |
```

If there are skipped or failed Issues:

```
### スキップした Issue

| # | Issue | 理由 |
|---|-------|------|
| 1 | #{number} {title} | {reason} |

### 失敗した Issue

| # | Issue | エラー |
|---|-------|--------|
| 1 | #{number} {title} | {error} |
```

### 4.2 Cleanup

Remove the Sprint state file:

```bash
rm -f .rite-sprint-state
```

### 4.3 Next Actions

```
### 次のアクション

- `/rite:sprint:current` で Sprint 状況を確認
- `/rite:pr:review {pr_number}` で個別 PR のレビュー状況を確認
- `/rite:sprint:plan` で次の Sprint を計画
```

---

## Break/Resume Flow

### On Break

When user selects "休憩":

1. Sprint state is already saved in `.rite-sprint-state`
2. Display resume instructions:

```
Sprint 実行を中断しました。

再開方法:
  /rite:sprint:execute --resume

進捗: {completed}/{total} 完了
残り: {remaining} 件
```

3. Exit

### On Resume

When `--resume` is provided (Phase 0.2):

1. Read `.rite-sprint-state`
2. Display restored state:

```
Sprint 実行を再開します。

進捗: {completed}/{total} 完了
次の Issue: #{next_number} - {next_title}
残り: {remaining} 件
```

3. Jump to Phase 3.1.1 with the next pending Issue

---

## Error Handling

See [Common Error Handling](../../references/common-error-handling.md) for shared patterns (Not Found, Permission, Network errors).

| Error | Recovery |
|-------|----------|
| Project Not Found | See [common patterns](../../references/common-error-handling.md) |
| API Error | See error output for details |
| Context Window Pressure | See error output for details |
