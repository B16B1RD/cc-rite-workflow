---
description: GitHub Projects 連携ロジック（Status更新、Iteration割り当て）
---

# GitHub Projects Integration

This module handles GitHub Projects integration including Status updates and Iteration assignments.

## 2.4 GitHub Projects Status Update

Retrieve the Project item ID and update Status to "In Progress".
**Automatically add the Issue to the Project if it is not registered.**

### 2.4.1 Configuration Retrieval

Retrieve Projects configuration from `rite-config.yml`:

```yaml
github:
  projects:
    enabled: true
    project_number: 2
    owner: "username"  # Project のオーナー（ユーザーまたは組織）
```

### 2.4.2 Check Issue Project Registration Status

```bash
# Issue のプロジェクトアイテム情報を取得
gh api graphql -f query='
query($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) {
    issue(number: $number) {
      url
      projectItems(first: 10) {
        nodes {
          id
          project {
            id
            number
          }
        }
      }
    }
  }
}' -f owner="{owner}" -f repo="{repo}" -F number={issue_number}
```

Check `projectItems.nodes` from the result:
- `nodes` is an empty array `[]` -> **Not registered in Project**
- `nodes` has elements -> Check if the target `project.number` matches the configured value

### 2.4.3 When Not Registered in Project: Auto-Add

When not registered in a Project, add the Issue with `gh project item-add`:

```bash
# Issue を Project に追加
gh project item-add {project_number} --owner {owner} --url {issue_url}
```

After adding, re-execute the 2.4.2 query to retrieve the new item_id.

### 2.4.4 Retrieve Status Field Information

**Important**: Option IDs (`{in_progress_option_id}`) always need to be retrieved from the API. Only field IDs can be specified via `field_ids`; the IDs of each option (Done, In Progress, etc.) are not included.

**Field ID retrieval:**

If `github.projects.field_ids.status` is set in `rite-config.yml`, use that value directly as `{status_field_id}` (skip field ID extraction from API result):

Replace the configured value with your actual project's ID (see CONFIGURATION.md for how to obtain):

```yaml
github:
  projects:
    field_ids:
      status: "PVTSSF_your-status-field-id"
```

**Option ID retrieval (always required):**

```bash
gh project field-list {project_number} --owner {owner} --format json
```

From the resulting JSON, find the field with `name` "Status" and retrieve the following:
- `id`: Status field ID (`{status_field_id}`) -- only used when `field_ids` is not set
- From the `options` array, the `id` of the option with `name` "In Progress" (`{in_progress_option_id}`)

**Retrieval logic:**
1. Execute API (always needed for option ID retrieval)
2. Check `github.projects.field_ids.status` in `rite-config.yml`
3. Determine field ID:
   - If set -> Use configured value as `{status_field_id}`
   - If not set -> Retrieve `{status_field_id}` from API result
4. Option ID: Retrieve `{in_progress_option_id}` from API result

### 2.4.5 Update Status to "In Progress"

```bash
gh project item-edit --project-id {project_id} --id {item_id} --field-id {status_field_id} --single-select-option-id {in_progress_option_id}
```

### 2.4.6 Result Confirmation

| Case | Action | Result Message |
|------|--------|----------------|
| Registered in Project | Status update only | `Status を "In Progress" に更新しました` |
| Not registered in Project | Add -> Status update | `Project に追加し、Status を "In Progress" に更新しました` |
| Projects disabled | Skip | `警告: GitHub Projects が設定されていません` |

### 2.4.7 Parent Issue Status Update (for child Issues)

**Execution condition**: Execute only when the current Issue is a child Issue of another Issue

#### 2.4.7.1 Parent Issue Detection

1. **Sub-Issues API (preferred)**: Retrieve `parent` via `gh api graphql -H "GraphQL-Features: sub_issues"`
2. **Tasklist fallback**: Search for parent via `gh issue list --search "in:body \"- [ ] #{issue_number}\""`
3. If not found, process as a standalone Issue

#### 2.4.7.2 Parent Issue Status Update

Update the parent Issue's Projects Status from "Todo" to "In Progress" only if it is currently "Todo".

#### 2.4.7.5 Error Handling

Parent Issue Status update failure does not block the start of work. Display a warning and continue.

## 2.5 Iteration Assignment (Optional)

Execute only when `iteration.enabled` is `true` and `iteration.auto_assign` is `true` in `rite-config.yml`:

### 2.5.1 Retrieve Iteration Field Information

```bash
gh api graphql -f query='
query($projectId: ID!) {
  node(id: $projectId) {
    ... on ProjectV2 {
      fields(first: 20) {
        nodes {
          ... on ProjectV2IterationField {
            id
            name
            configuration {
              iterations {
                id
                title
                startDate
                duration
              }
            }
          }
        }
      }
    }
  }
}' -f projectId="{project_id}"
```

### 2.5.2 Current Iteration Determination

Identify the current iteration from the retrieved iteration list:

```
アルゴリズム:
1. 今日の日付を取得
2. 各イテレーションについて:
   - endDate = startDate + duration (days)
   - startDate <= 今日 < endDate なら「現在」
3. 該当なし → 次のイテレーション（開始日が最も近い未来のもの）を提案
```

### 2.5.3 Execute Iteration Assignment

```bash
gh api graphql -f query='
mutation($projectId: ID!, $itemId: ID!, $fieldId: ID!, $iterationId: String!) {
  updateProjectV2ItemFieldValue(
    input: {
      projectId: $projectId
      itemId: $itemId
      fieldId: $fieldId
      value: { iterationId: $iterationId }
    }
  ) {
    projectV2Item { id }
  }
}' -f projectId="{project_id}" -f itemId="{item_id}" -f fieldId="{iteration_field_id}" -f iterationId="{current_iteration_id}"
```

### 2.5.4 Result Display

```
Iteration: {iteration_title} ({start_date} - {end_date})
```

**Note**: Display a warning and skip if the Iteration field does not exist or the current iteration cannot be found:

```
警告: Iteration の割り当てをスキップしました
理由: {reason}
```
