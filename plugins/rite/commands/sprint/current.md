---
description: 現在のスプリント詳細を表示
context: fork
---

# /rite:sprint:current

Display detailed information about the current sprint (Iteration)

---

When this command is executed, run the following phases in order.

## Prerequisites

- `rite-config.yml` must have `iteration.enabled` set to `true`
- An Iteration field must exist in GitHub Projects

**If Iteration is disabled**: Display the same message as `/rite:sprint:list` and exit

---

## Phase 1: Identify the Current Iteration

### 1.1 Retrieve the Iteration Field and All Iterations

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

### 1.2 Determine the Current Iteration

```
アルゴリズム:
1. 今日の日付を取得
2. 各イテレーションについて:
   - endDate = startDate + duration (days)
   - startDate <= 今日 < endDate → これが「現在」
3. 該当なし → 「現在アクティブなスプリントがありません」
```

---

## Phase 2: Retrieve Issues for the Current Sprint

### 2.1 Retrieve Issue List

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
              state
              assignees(first: 3) { nodes { login } }
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
}' -f projectId="{project_id}" -f iterationId="{current_iteration_id}" -f fieldId="{iteration_field_id}"
```

### 2.2 Group by Status

```
Status でグループ化:
- Todo: まだ着手していない
- In Progress: 作業中
- In Review: レビュー待ち
- Done: 完了
```

---

## Phase 3: Display Details

### 3.1 Sprint Information

```
{i18n:sprint_current_title}: Sprint 3

{i18n:sprint_current_period}: 2025-01-06 - 2025-01-19 (14{i18n:sprint_current_days})
{i18n:sprint_current_remaining}: 8{i18n:sprint_current_days}

{i18n:sprint_current_progress}: ████████░░░░░░░░ 50% (4/8 {i18n:sprint_current_completed})
```

### 3.2 Issue List (by Status)

```
## {i18n:status_in_progress} (2{i18n:sprint_plan_count_unit})

  #42  ログイン機能を追加
       {i18n:sprint_current_assignee}: @user1  {i18n:sprint_current_label}: enhancement

  #45  API エンドポイント実装
       {i18n:sprint_current_assignee}: @user2  {i18n:sprint_current_label}: enhancement

## {i18n:status_todo} (2{i18n:sprint_plan_count_unit})

  #48  テスト追加
       {i18n:sprint_current_assignee}: {i18n:sprint_current_unassigned}  {i18n:sprint_current_label}: testing

  #49  ドキュメント更新
       {i18n:sprint_current_assignee}: @user1  {i18n:sprint_current_label}: documentation

## {i18n:status_done} (4{i18n:sprint_plan_count_unit})

  #40  初期設定  ✓
  #41  DB スキーマ  ✓
  #43  認証基盤  ✓
  #44  エラーハンドリング  ✓
```

### 3.3 Summary

```
{i18n:sprint_current_summary}:
- {i18n:sprint_current_summary_done}: 4{i18n:sprint_plan_count_unit}
- {i18n:sprint_current_summary_in_progress}: 2{i18n:sprint_plan_count_unit}
- {i18n:sprint_current_summary_todo}: 2{i18n:sprint_plan_count_unit}
- {i18n:sprint_current_summary_total}: 8{i18n:sprint_plan_count_unit}
```

---

## Phase 4: Suggest Next Actions

```
{i18n:sprint_plan_next_actions}:
- `/rite:issue:start <番号>` {i18n:sprint_plan_action_start_issue}
- `/rite:sprint:plan` {i18n:sprint_current_action_plan_next}
- `/rite:issue:list --sprint current` {i18n:sprint_current_action_details}
```

---

## When No Current Iteration Exists

```
{i18n:sprint_no_current}

{i18n:sprint_suggest_next}: Sprint 4
{i18n:sprint_current_start_date}: 2025-01-20

{i18n:sprint_current_hint_title}:
- {i18n:sprint_current_hint_adjust_period}
- {i18n:sprint_current_hint_plan_next}
```

---

## Error Handling

See [Common Error Handling](../../references/common-error-handling.md) for shared patterns (Not Found, Permission, Network errors).

| Error | Recovery |
|-------|----------|
| When There Are No Issues | See error output for details |
| On API Error | See error output for details |
