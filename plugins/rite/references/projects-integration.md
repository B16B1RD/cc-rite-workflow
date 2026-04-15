---
description: GitHub Projects 連携ロジック（Status更新、Iteration割り当て）
---

# GitHub Projects Integration

This module handles GitHub Projects integration including Status updates and Iteration assignments.

## 2.4 GitHub Projects Status Update

Retrieve the Project item ID and update Status to "In Progress".
**Automatically add the Issue to the Project if it is not registered.**

> **Runtime execution**: Callers (`commands/issue/start.md` Phase 2.4 / 5.5.1 / 5.7.2) invoke `plugins/rite/scripts/projects-status-update.sh`, which is the single source of truth for Projects Status updates. The bash examples in §2.4.2 – §2.4.5 below document the underlying API calls for reference and debugging. Do NOT reproduce them inline in new commands — delegate to the script instead (see Issue #496 for the refactor rationale).

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

**Execution condition**: Always execute 2.4.7.1 (parent detection). If a parent is found, proceed to 2.4.7.2–2.4.7.4. If no parent is found, skip silently (this is normal for standalone Issues).

**Non-blocking**: All steps in 2.4.7 are non-blocking. Any failure displays a warning and continues the workflow.

#### 2.4.7.1 Parent Issue Detection

Detect the parent Issue of the current (child) Issue. **Three methods are tried in order (OR combination); the first successful result wins.** This ordering is critical: `## 親 Issue` body meta is placed PRIMARY because it is the most reliable source in repositories that use `/rite:issue:create-decompose` (which writes this section to every child), and it requires no dependency on GitHub's native Sub-Issues feature.

> **Consistency requirement (Issue #513)**: The same 3-method OR detection **structure** MUST be used in `close.md` Phase 4.5.1 — i.e., the same three method ordering (body meta → Sub-Issues API → tasklist search), the same OR combination semantics, and the same `[DEBUG] parent not detected` emission on total failure. **Context-dependent parameters MAY differ** between the two sites where the surrounding workflow demands it; specifically, Method 3's `--state` filter is `open` here (start side — closed parents do not need In Progress promotion) and `all` in close.md Phase 4.5.1 (close side — the closing Issue's parent may itself already be closed). These differences are intentional and are not drift. If the detection method ordering or OR semantics diverge between start and close, silent-skip regressions (e.g., the #115/#381/#15 incidents) reappear.

**Method 1: `## 親 Issue` body meta (PRIMARY)**

Read the current (child) Issue body and search for the `## 親 Issue` section. This section is written by `/rite:issue:create-decompose` when child Issues are created from a parent. Format:

```
## 親 Issue

#{parent_number} - {parent_title}
```

```bash
child_body=$(gh issue view {issue_number} --json body --jq '.body')
# SIGPIPE 防止 (#398 参照): here-string で subprocess を排除
parent_number=$(grep -A2 '^## 親 Issue' <<< "$child_body" | grep -oE '#[0-9]+' | head -1 | tr -d '#')
echo "method1_parent=${parent_number:-none}"
```

If `parent_number` is non-empty, extract it as `{parent_issue_number}` and proceed to 2.4.7.2.

**Method 2: Sub-Issues API (secondary)**

If Method 1 found no parent, query GitHub's native Sub-Issues feature:

```bash
gh api graphql -H "GraphQL-Features: sub_issues" -f query='
query($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) {
    issue(number: $number) {
      parent { number }
    }
  }
}' -f owner="{owner}" -f repo="{repo}" -F number={issue_number}
```

If `parent` is not null, extract `parent.number` as `{parent_issue_number}` and proceed to 2.4.7.2. (Only `number` is requested because 2.4.7.2 re-queries the parent by number for project data, so `title`/`state` are unused here and would only create drift with `close.md` Phase 4.5.1 Method 2.)

**Method 3: Tasklist search (last resort)**

If Methods 1 and 2 both failed:

```bash
gh issue list --state open --search "in:body \"- [ ] #{issue_number}\" OR \"- [x] #{issue_number}\"" --json number,title,state --limit 5
```

**Note**: `--state open` is intentional — closed parent Issues do not need Status updates. The search matches both unchecked (`- [ ]`) and checked (`- [x]`) tasklist items to ensure checkbox state independence (consistent with [epic-detection.md](./epic-detection.md)). GitHub code search with `[`/`]` characters is known to be unreliable, which is why this method is the last resort.

If results are non-empty, use the first result's `number` as `{parent_issue_number}` and proceed to 2.4.7.2.

**When all three methods failed (no parent found)**: This is the normal path for standalone Issues (AC-4). Emit an explicit **debug log** (not a warning) so that the skip is visible in execution traces — silent skips are prohibited by Issue #513's MUST requirement ("同期失敗時は silent skip せず、明示的にログまたは warning を出力する") and the preceding incidents #115 / #381 / #15 which all stemmed from silent skips in parent-child sync:

```bash
echo "[DEBUG] parent not detected for issue #{issue_number} — processing as standalone (methods tried: body_meta, sub_issues_api, tasklist_search)"
```

Then skip 2.4.7.2–2.4.7.4.

#### 2.4.7.2 Retrieve Parent Issue Project Item and Current Status

Retrieve the parent Issue's (identified in 2.4.7.1 as `{parent_issue_number}`) project item ID and current Status in a single query:

```bash
gh api graphql -f query='
query($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) {
    issue(number: $number) {
      projectItems(first: 10) {
        nodes {
          id
          project {
            id
            number
          }
          fieldValues(first: 10) {
            nodes {
              ... on ProjectV2ItemFieldSingleSelectValue {
                name
                field {
                  ... on ProjectV2SingleSelectField {
                    name
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}' -f owner="{owner}" -f repo="{repo}" -F number={parent_issue_number}
```

From the result:

1. Find the node where `project.number` matches `{project_number}` from `rite-config.yml`
2. Extract `{parent_item_id}` (node `id`) and `{parent_project_id}` (node `project.id`)
3. From `fieldValues.nodes`, find the entry where `field.name` is `"Status"` and extract the current `name` value as `{current_status}`. If no Status entry exists in `fieldValues.nodes` (Status field value is unset/null), treat `{current_status}` as `null` and proceed to 2.4.7.3 (handled as equivalent to "Todo")

**When `projectItems.nodes` is empty** (parent Issue not registered in Project):

```
警告: 親 Issue #{parent_issue_number} は Project に登録されていません
親 Issue の Status 更新をスキップします
```

Display warning and skip 2.4.7.3–2.4.7.4 (non-blocking).

#### 2.4.7.3 Status Condition Check

Only update the parent Issue's Status if it is currently "Todo". This prevents overwriting a more advanced Status (e.g., "In Progress" set by a sibling child Issue).

| Current Status | Action |
|---------------|--------|
| **Todo** | Proceed to 2.4.7.4 (update to "In Progress") |
| **null (unset)** | Proceed to 2.4.7.4 — treat as equivalent to "Todo" (Status field value not yet selected) |
| **In Progress** | Skip — already at target status. Display: `警告: 親 Issue #{parent_issue_number} は既に In Progress です` |
| **In Review** / **Done** | Skip — more advanced status. Display: `警告: 親 Issue #{parent_issue_number} は既に {current_status} です（更新スキップ）` |

#### 2.4.7.4 Update Parent Issue Status to "In Progress"

**Step 1**: Retrieve the "In Progress" option ID.

If 2.4.4 was already executed in this workflow run, reuse the `{status_field_id}` and `{in_progress_option_id}` values obtained there (no additional API call needed). Otherwise (e.g., 2.4.7 is referenced standalone), retrieve them as follows. See [2.4.4](#244-retrieve-status-field-information) for the full retrieval logic including `field_ids` optimization.

```bash
gh project field-list {project_number} --owner {owner} --format json
```

From the result, find the field with `name` "Status". Extract:
- `{status_field_id}`: the field's `id` (skip if `github.projects.field_ids.status` is set in `rite-config.yml`)
- `{in_progress_option_id}`: the `id` of the option with `name` "In Progress"

**Important**: Option IDs always need to be retrieved from the API (consistent with 2.4.4). Only field IDs can be specified via `field_ids`.

**Step 2**: Update the Status:

```bash
gh project item-edit --project-id {parent_project_id} --id {parent_item_id} --field-id {status_field_id} --single-select-option-id {in_progress_option_id}
```

**Step 3**: Display result:

```
親 Issue #{parent_issue_number} の Status を "In Progress" に更新しました
```

#### 2.4.7.5 Error Handling

Parent Issue Status update failure does **not** block the start of work. Each step handles errors independently:

| Step | Error Case | Response |
|------|-----------|----------|
| 2.4.7.1 | Sub-Issues API fails | Try Tasklist fallback. If both fail, skip silently |
| 2.4.7.1 | Tasklist search returns no results | Skip silently (standalone Issue) |
| 2.4.7.2 | GraphQL query fails | Display `警告: 親 Issue の Projects 情報取得に失敗しました。Status 更新をスキップします` |
| 2.4.7.2 | Parent not registered in Project | Display warning and skip (see 2.4.7.2) |
| 2.4.7.4 | field-list fails | Display `警告: Status フィールド情報の取得に失敗しました` and skip |
| 2.4.7.4 | item-edit fails | Display `警告: 親 Issue #{parent_issue_number} の Status 更新に失敗しました` and continue |

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
