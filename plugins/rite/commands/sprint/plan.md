---
description: スプリント計画を実行
---

# /rite:sprint:plan

Execute sprint planning (select Issues from the backlog and assign them to a sprint)

---

When this command is executed, run the following phases in order.

## Prerequisites

- `rite-config.yml` `iteration.enabled` must be `true`
- An Iteration field must exist in GitHub Projects

**If Iteration is disabled**: Display the same message as `/rite:sprint:list` and exit

---

## Phase 1: Determine Target Sprint

### 1.1 Check Arguments

| Argument | Description |
|------|------|
| None | Target the current or next sprint |
| `current` | Target the current sprint |
| `next` | Target the next sprint |
| `"Sprint 4"` | Target the specified sprint |

### 1.2 Select Target Sprint

If no argument is provided, confirm with `AskUserQuestion`:

```
{i18n:sprint_plan_ask_target}

オプション:
- {i18n:sprint_plan_option_current}: Sprint 3 (2025-01-06 - 2025-01-19)
- {i18n:sprint_plan_option_next}: Sprint 4 (2025-01-20 - 2025-02-02)
- {i18n:sprint_plan_option_specify}
```

---

## Phase 2: Check Current Sprint Status

### 2.1 Retrieve Existing Issues for Target Sprint

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
          content {
            ... on Issue {
              number
              title
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
}' -f projectId="{project_id}" -f iterationId="{target_iteration_id}" -f fieldId="{iteration_field_id}"
```

### 2.2 Display Current Capacity

```
{i18n:sprint_plan_target_title} (variables: name=Sprint 4)

{i18n:sprint_plan_current_state}:
- {i18n:sprint_plan_assigned_issues}: 3{i18n:sprint_plan_count_unit}
- {i18n:sprint_plan_estimated_points}: 8 / 20

{i18n:sprint_plan_remaining_capacity}: 12{i18n:sprint_plan_points_unit}
```

---

## Phase 3: Display Backlog

### 3.1 Retrieve Backlog Issues

Retrieve Issues that have no Iteration assigned:

```bash
gh api graphql -f query='
query($projectId: ID!) {
  node(id: $projectId) {
    ... on ProjectV2 {
      items(first: 100) {
        nodes {
          id
          content {
            ... on Issue {
              number
              title
              state
              labels(first: 5) { nodes { name } }
            }
          }
          fieldValues(first: 10) {
            nodes {
              ... on ProjectV2ItemFieldIterationValue {
                iterationId
              }
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

### 3.2 Display Backlog List

Sort by Priority and Complexity and display:

```
{i18n:sprint_plan_backlog_title} (variables: count=10)

  # | Priority | Complexity | Title
----|----------|------------|-------------------------------
 50 | High     | M (3pt)    | ユーザー認証機能の追加
 51 | High     | S (2pt)    | ログ出力の改善
 52 | Medium   | L (5pt)    | ダッシュボード画面の実装
 53 | Medium   | M (3pt)    | API レスポンスのキャッシュ
 54 | Low      | XS (1pt)   | README の更新
 ...

{i18n:sprint_plan_backlog_total}: 10{i18n:sprint_plan_count_unit}（{i18n:sprint_plan_backlog_estimated} 25{i18n:sprint_plan_points_unit}）
```

---

## Phase 4: Select and Assign Issues

### 4.1 Confirm Selection Method

Confirm the selection method with `AskUserQuestion`:

```
{i18n:sprint_plan_ask_selection_method}:

オプション:
- {i18n:sprint_plan_option_select_individual}: Issue を1件ずつ選択
- {i18n:sprint_plan_option_select_priority}: High Priority のものをすべて選択
- {i18n:sprint_plan_option_select_auto}: Priority 順に自動で選択（{i18n:sprint_plan_recommended}）
```

### 4.2 Individual Selection

```
{i18n:sprint_plan_select_from_backlog}:

[ ] #50 ユーザー認証機能の追加 (High, M: 3pt)
[ ] #51 ログ出力の改善 (High, S: 2pt)
[ ] #52 ダッシュボード画面の実装 (Medium, L: 5pt)
[ ] #53 API レスポンスのキャッシュ (Medium, M: 3pt)
...

{i18n:sprint_plan_selected_issues}: ({i18n:sprint_plan_none})
{i18n:sprint_plan_current_total}: 8pt / 20pt
```

### 4.3 Automatic Selection

```
{i18n:sprint_plan_auto_selected}:

{i18n:sprint_plan_selected_issues}:
- #50 ユーザー認証機能の追加 (High, M: 3pt)
- #51 ログ出力の改善 (High, S: 2pt)
- #53 API レスポンスのキャッシュ (Medium, M: 3pt)

{i18n:sprint_plan_total_points}: 8pt（{i18n:sprint_plan_fits_capacity} 12pt {i18n:sprint_plan_fits_capacity_suffix}）

{i18n:sprint_plan_ask_proceed}？
- {i18n:sprint_plan_option_assign}
- {i18n:sprint_plan_option_change_selection}
- {i18n:sprint_plan_option_cancel}
```

### 4.4 Execute Assignment

Set the Iteration for each selected Issue:

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
}' -f projectId="{project_id}" -f itemId="{item_id}" -f fieldId="{iteration_field_id}" -f iterationId="{target_iteration_id}"
```

---

## Phase 5: Completion Report

```
{i18n:sprint_plan_complete}

Sprint 4 (2025-01-20 - 2025-02-02)

{i18n:sprint_plan_added_issues}:
- #50 ユーザー認証機能の追加
- #51 ログ出力の改善
- #53 API レスポンスのキャッシュ

{i18n:sprint_plan_sprint_state}:
- {i18n:sprint_plan_total_issues}: 6{i18n:sprint_plan_count_unit}
- {i18n:sprint_plan_total_points}: 16 / 20
- {i18n:sprint_plan_remaining_capacity}: 4pt

{i18n:sprint_plan_next_actions}:
- `/rite:sprint:current` {i18n:sprint_plan_action_check_details}
- `/rite:issue:start <番号>` {i18n:sprint_plan_action_start_issue}
```

---

## Complexity Point Mapping

Default mapping (customizable in `rite-config.yml`):

| Complexity | Points |
|------------|---------|
| XS | 1 |
| S | 2 |
| M | 3 |
| L | 5 |
| XL | 8 |

---

## Error Handling

See [Common Error Handling](../../references/common-error-handling.md) for shared patterns (Not Found, Permission, Network errors).

| Error | Recovery |
|-------|----------|
| When Backlog is Empty | See error output for details |
| When Selection Exceeds Capacity | {i18n:sprint_plan_option_assign_anyway}（{i18n:sprint_plan_overcommit}） / {i18n:sprint_plan_option_change_selection} |
| On API Error | See error output for details |
