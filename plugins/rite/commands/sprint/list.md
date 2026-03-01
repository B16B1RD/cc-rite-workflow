---
description: Sprint/Iteration 一覧を表示
context: fork
---

# /rite:sprint:list

Display a list of Sprint/Iterations

---

When this command is executed, run the following phases in order.

## Prerequisites

- `rite-config.yml` must have `iteration.enabled` set to `true`
- An Iteration field must exist in GitHub Projects

**If Iteration is disabled**:

```
{i18n:sprint_disabled}

{i18n:sprint_list_enable_howto}:
1. {i18n:sprint_list_enable_step1}
2. {i18n:sprint_list_enable_step2}
3. {i18n:sprint_list_enable_step3}

{i18n:sprint_list_see_workflow}
```

---

## Phase 1: Retrieve Configuration and Field Information

### 1.1 Load rite-config.yml

```bash
# rite-config.yml から iteration 設定を読み込み
# iteration.enabled が false の場合は上記のメッセージを表示して終了
```

### 1.2 Get Project ID

```bash
gh api graphql -f query='
query($owner: String!, $number: Int!) {
  user(login: $owner) {
    projectV2(number: $number) {
      id
    }
  }
}' -f owner="{owner}" -F number={project_number}
```

### 1.3 Retrieve Iteration Field and All Iterations

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

---

## Phase 2: Determine Iteration Status

### 2.1 Compare with Current Date

Determine the status of each iteration:

```
アルゴリズム:
1. 今日の日付を取得
2. 各イテレーションについて:
   - endDate = startDate + duration (days)
   - 今日 < startDate → "future" (予定)
   - startDate <= 今日 < endDate → "current" (現在)
   - endDate <= 今日 → "past" (過去)
```

### 2.2 Get Issue Count for Each Iteration

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

---

## Phase 3: Display List

### 3.1 Default Display (Current + Next + Most Recent Past)

```
{i18n:sprint_list_title}

  [{i18n:sprint_list_current}] Sprint 3 (2025-01-06 - 2025-01-19)
         {i18n:sprint_issues_count}: 5{i18n:sprint_plan_count_unit} ({i18n:sprint_issues_done}: 2, {i18n:sprint_issues_in_progress}: 2, {i18n:sprint_issues_todo}: 1)

  [{i18n:sprint_list_next}] Sprint 4 (2025-01-20 - 2025-02-02)
         {i18n:sprint_issues_count}: 3{i18n:sprint_plan_count_unit} ({i18n:sprint_list_all_todo})

  [{i18n:sprint_list_past}] Sprint 2 (2024-12-23 - 2025-01-05)
         {i18n:sprint_issues_count}: 8{i18n:sprint_plan_count_unit} ({i18n:sprint_list_all_done})

{i18n:sprint_list_displayed_total}: 3 {i18n:sprint_list_sprints} ({i18n:sprint_list_total_sprints} 5 {i18n:sprint_list_sprints})
```

### 3.2 Filter Options

| Option | Description |
|-----------|------|
| `--all` | Display all iterations |
| `--current` | Current iteration only |
| `--past` | Past iterations only |
| `--upcoming` | Upcoming iterations only |

### 3.3 When No Current Iteration Exists

```
{i18n:sprint_list_title}

{i18n:sprint_no_current}

  [{i18n:sprint_list_next}] Sprint 4 (2025-01-20 - 2025-02-02)
         {i18n:sprint_issues_count}: 3{i18n:sprint_plan_count_unit} ({i18n:sprint_list_all_todo})

  [{i18n:sprint_list_past}] Sprint 3 (2025-01-06 - 2025-01-19)
         {i18n:sprint_issues_count}: 5{i18n:sprint_plan_count_unit} ({i18n:sprint_list_all_done})

{i18n:sprint_list_hint_check_period}
```

---

## Phase 4: Present Next Actions

```
{i18n:sprint_plan_next_actions}:
- `/rite:sprint:current` {i18n:sprint_list_action_show_current}
- `/rite:sprint:plan` {i18n:sprint_list_action_execute_plan}
- `/rite:issue:list --sprint current` {i18n:sprint_list_action_list_issues}
```

---

## Error Handling

See [Common Error Handling](../../references/common-error-handling.md) for shared patterns (Not Found, Permission, Network errors).

| Error | Recovery |
|-------|----------|
| When Iteration Field Is Not Found | See [common patterns](../../references/common-error-handling.md) |
| When No Iterations Are Configured | See error output for details |
| On API Errors | See error output for details |
