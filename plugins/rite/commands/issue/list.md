---
description: GitHub Issue の一覧を表示
context: fork
---

# /rite:issue:list

GitHub Issue の一覧を表示

---

When this command is executed, run the following phases in order.

## Phase 1: Parse Arguments

Determine the filter conditions specified by the user:

| Input | Type | Action |
|-------|------|--------|
| None | Default | Show open Issues |
| `open` | State filter | Show open Issues |
| `closed` | State filter | Show closed Issues |
| `all` | State filter | Show all Issues |
| `#123` or `123` | Issue number | Show details for specific Issue |
| `--sprint current` | Sprint filter | Show Issues in current sprint |
| `--sprint "Sprint 3"` | Sprint filter | Show Issues in specified sprint |
| `--backlog` | Sprint filter | Show Issues not assigned to any sprint |
| Other | Label filter | Show Issues with specified label |

**Note**: `--sprint` and `--backlog` are only available when `iteration.enabled` is `true` in `rite-config.yml`

---

## Phase 2: Fetch and Display Issue List

### 2.1 When Issue Number is Specified (`#123` or `123`)

Fetch and display details for the specific Issue:

```bash
gh issue view {number} --json number,title,body,state,labels,assignees,milestone,createdAt,updatedAt
```

Display in the following format:

```
┌─────────────────────────────────────────────────────────────┐
│  Issue #{number}: {title}                                   │
└─────────────────────────────────────────────────────────────┘

【状態】{state}
【ラベル】{labels}
【担当者】{assignees}
【マイルストーン】{milestone}
【作成日】{createdAt}
【更新日】{updatedAt}

───────────────────────────────────────────────────────────────
{body}
───────────────────────────────────────────────────────────────

【次のアクション】
- /rite:issue:start {number}  この Issue の作業を開始
- /rite:issue:close {number}  完了状態を確認
```

### 2.2 When State Filter is Used (`open`, `closed`, `all`)

```bash
# open（デフォルト）
gh issue list --state open --json number,title,labels,assignees,createdAt --limit 20

# closed
gh issue list --state closed --json number,title,labels,assignees,createdAt --limit 20

# all
gh issue list --state all --json number,title,labels,assignees,createdAt --limit 20
```

### 2.3 When Label Filter is Used

```bash
gh issue list --label "{label}" --json number,title,state,labels,assignees,createdAt --limit 20
```

---

## Phase 3: Format and Display Results

### 3.0 Check Language Setting

Before displaying results, read the `language` field from `rite-config.yml` using the Read tool, and determine the output language:

| Setting | Behavior |
|---------|----------|
| `auto` | Detect the user's input language and display in the same language |
| `ja` | Display messages in Japanese |
| `en` | Display messages in English |

**Language Detection Priority** (when set to `auto`):
1. The language used by the user when executing the command
2. Default: Japanese

Display results in the following format according to the determined language.

### 3.1 List Display Format

When Issues exist:

```
┌─────────────────────────────────────────────────────────────┐
│  Issue 一覧（{filter}）                                      │
└─────────────────────────────────────────────────────────────┘

  #{number}  {title}
             ラベル: {labels}  担当: {assignees}  {createdAt}

  #{number}  {title}
             ラベル: {labels}  担当: {assignees}  {createdAt}

  ... (他 {count} 件)

───────────────────────────────────────────────────────────────
  合計: {total} 件の Issue

【操作】
- /rite:issue:list #{number}  詳細を表示
- /rite:issue:start {number}  作業を開始
- /rite:issue:create          新規 Issue を作成
```

### 3.2 When No Issues Exist

```
┌─────────────────────────────────────────────────────────────┐
│  Issue 一覧（{filter}）                                      │
└─────────────────────────────────────────────────────────────┘

  Issue が見つかりませんでした。

【操作】
- /rite:issue:create <説明>  新規 Issue を作成
- /rite:issue:list closed    クローズした Issue を表示
```

---

## Phase 4: Supplementary Display of GitHub Projects Information (Optional)

Display Projects information when `rite-config.yml` exists and Projects integration is enabled.

### 4.1 Check Configuration File

Read `rite-config.yml` using the Read tool to check if Projects integration is enabled (`github.projects.enabled: true`).
If the file does not exist, skip Phase 4 entirely.

### 4.2 Fetch Projects Data and Build Status Map

> **CRITICAL**: Execute each tool call exactly as described. Do NOT add `--jq` flags, inline comments, or any extra text to bash commands.

**Tool call 1 (Bash)**: Run this single-line command verbatim — `tmpfile=$(mktemp) && gh project item-list {project_number} --owner {owner} --format json --limit 500 > "$tmpfile" && echo "$tmpfile"`

**Tool call 2 (Read)**: Use the Read tool to open the temp file path printed by Tool call 1. The JSON contains an `items` array; each element has `.status` (string) and `.content.number` (int). Build an in-memory map of Issue number → Status. On failure, skip Projects info and show the Phase 3 list without a Status column.

Add a Status column to the list display:

```
  #{number}  {title}                                    [{Status}]
             ラベル: {labels}  担当: {assignees}  {createdAt}
```

### 4.3 Display Iteration Information (Optional)

When `iteration.enabled` is `true` and `iteration.show_in_list` is `true` in `rite-config.yml`,
also display the Iteration column:

```
  #{number}  {title}                           [{Status}] [Sprint 3]
             ラベル: {labels}  担当: {assignees}  {createdAt}
```

---

## Phase 5: Sprint Filter Processing (When Iteration is Enabled)

### 5.1 When `--sprint current` is Used

1. Identify the current iteration (same logic as `/rite:sprint:current`)
2. Fetch only Issues assigned to that iteration

```bash
gh api graphql -f query='
query($projectId: ID!, $iterationId: String!, $fieldId: ID!) {
  node(id: $projectId) {
    ... on ProjectV2 {
      items(first: 100, filter: {
        field: { fieldId: $fieldId, iterationId: $iterationId }
      }) {
        nodes {
          content {
            ... on Issue {
              number
              title
              state
              labels(first: 5) { nodes { name } }
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

Display:

```
┌─────────────────────────────────────────────────────────────┐
│  Issue 一覧（Sprint: Sprint 3）                              │
└─────────────────────────────────────────────────────────────┘

  #42  ログイン機能を追加                        [In Progress]
       ラベル: enhancement  担当: @user1  2025-01-03

  #45  API エンドポイント実装                    [Todo]
       ラベル: enhancement  担当: @user2  2025-01-05

───────────────────────────────────────────────────────────────
  合計: 5 件の Issue（Sprint 3）
```

### 5.2 When `--backlog` is Used

Fetch Issues that have no Iteration assigned:

```bash
gh api graphql -f query='
query($projectId: ID!) {
  node(id: $projectId) {
    ... on ProjectV2 {
      items(first: 100) {
        nodes {
          content {
            ... on Issue {
              number
              title
              state
            }
          }
          fieldValues(first: 10) {
            nodes {
              ... on ProjectV2ItemFieldIterationValue {
                iterationId
              }
            }
          }
        }
      }
    }
  }
}' -f projectId="{project_id}"
```

Display items where the Iteration field value is null as "backlog":

```
┌─────────────────────────────────────────────────────────────┐
│  Issue 一覧（バックログ）                                    │
└─────────────────────────────────────────────────────────────┘

  #50  将来的な機能追加                          [Todo]
       ラベル: enhancement  担当: 未割当  2025-01-06

  #51  リファクタリング案                        [Todo]
       ラベル: refactor  担当: 未割当  2025-01-07

───────────────────────────────────────────────────────────────
  合計: 2 件の Issue（バックログ）

【操作】
- /rite:sprint:plan でスプリントに割り当て
```

---

## Error Handling

### When API Error Occurs

When a GraphQL API call fails:

1. **Retry**: Retry up to 3 times on network errors (exponential backoff)
2. **Fallback**: If the API is unavailable, display only the basic Issue list (skip Projects fields)
3. **Error Reporting**: Display a specific error message and remediation steps
## Usage Examples

```
/rite:issue:list              # オープンな Issue を一覧
/rite:issue:list open         # オープンな Issue を一覧（明示的）
/rite:issue:list closed       # クローズした Issue を一覧
/rite:issue:list all          # すべての Issue を一覧
/rite:issue:list bug          # "bug" ラベルの Issue を一覧
/rite:issue:list enhancement  # "enhancement" ラベルの Issue を一覧
/rite:issue:list #42          # Issue #42 の詳細を表示
/rite:issue:list 42           # Issue #42 の詳細を表示

# Sprint フィルタ（Iteration 有効時のみ）
/rite:issue:list --sprint current     # 現在のスプリントの Issue を一覧
/rite:issue:list --sprint "Sprint 3"  # 指定スプリントの Issue を一覧
/rite:issue:list --backlog            # スプリント未割当の Issue を一覧
```
