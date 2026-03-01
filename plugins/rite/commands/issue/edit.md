---
description: 既存 Issue の内容を対話的に修正
---

# /rite:issue:edit

Interactively edit an existing Issue's title, body, and Projects fields

---

## Overview

This command is for **interactively** editing existing Issue content.

### Difference from `/rite:issue:update`

| Command | Role |
|---------|------|
| `/rite:issue:update` | Update work memory (progress, decisions) |
| `/rite:issue:edit` | Edit the Issue itself (title, body, fields) |

### Editable Targets

| Element | Description |
|---------|-------------|
| **Title** | Issue title |
| **Body** | Issue body |
| **Status** | Projects Status field |
| **Priority** | Projects Priority field |
| **Complexity** | Projects Complexity field |

---

Execute the following phases in order when this command is invoked.

## Arguments

| Argument | Description |
|----------|-------------|
| `<issue_number>` | Issue number to edit (required) |

---

## Phase 1: Retrieve and Display Issue Information

### 1.1 Retrieve Issue Information

Retrieve detailed information for the specified Issue:

```bash
gh issue view {issue_number} --json number,title,body,state,labels,projectItems
```

### 1.2 Check Issue State

**If the Issue is closed:**

```
警告: Issue #{number} は既にクローズされています

クローズされた Issue を編集しますか？

オプション:
- 編集を続行
- Issue を再オープンしてから編集
- キャンセル
```

Confirm with `AskUserQuestion`.

**When "Issue を再オープンしてから編集" is selected:**

```bash
gh issue reopen {issue_number}
```

### 1.3 Retrieve Projects Fields

If the Issue is registered in Projects, retrieve the current field values:

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
          fieldValues(first: 20) {
            nodes {
              ... on ProjectV2ItemFieldSingleSelectValue {
                field { ... on ProjectV2SingleSelectField { name } }
                name
              }
            }
          }
        }
      }
    }
  }
}' -f owner="{owner}" -f repo="{repo}" -F number={issue_number}
```

**Project Matching Logic:**

From the retrieved `projectItems.nodes`, identify the Project that matches `project_number` in `rite-config.yml`:

1. Get `github.projects.project_number` from `rite-config.yml`
2. Select the item whose `project.number` matches the configured value from the `nodes` array
3. If no matching item is found, treat as not registered in Projects (skip confirmation in Phase 3.2)

### 1.4 Display Current Issue Content

```
## Issue #{number} の現在の内容

**タイトル**: {title}

**本文**:
{body_preview}

**Projects フィールド**:
- Status: {status}
- Priority: {priority}
- Complexity: {complexity}
```

**Body Preview:**
- If the body is long, show the first 500 characters + `...（省略）`
- Preserve Markdown formatting

---

## Phase 2: Interactive Edit Loop

### 2.1 Accept Edit Instructions

Accept free-form edit instructions via `AskUserQuestion`:

```
修正したい内容を教えてください。

例:
- 「タイトルを〜に変更」
- 「本文の概要セクションを〜に修正」
- 「Priority を High に変更」
- 「チェックリストに〜を追加」

オプション:
- 修正内容を入力（Other を選択）
- 修正完了（終了）
```

### 2.2 Interpret Edit Instructions

Interpret the user's natural language instructions and identify the following:

| Interpretation Item | Example |
|--------------------|---------|
| **Edit Target** | Title / Body / Status / Priority / Complexity |
| **Edit Content** | Text to replace, new value |
| **Edit Location** | Specific section within the body (see below) |

**Editable Sections Within the Body:**

| Section | Description |
|---------|-------------|
| 概要 | Issue summary/overview |
| 背景・目的 | Background and purpose description |
| 仕様詳細 | Technical specifications and decisions |
| 変更内容 | List of expected changes |
| 影響範囲 | Affected files and features |
| 制約条件 | Technical constraints and out-of-scope items |
| チェックリスト | Task checklist |
| 複雑度 | Complexity description |

**Note**: Section names depend on the Issue template. The above are based on standard templates in `templates/issue/`.

**If interpretation is ambiguous:**

Confirm with `AskUserQuestion`:

```
修正内容を確認させてください。

「{user_input}」は以下の修正として解釈しました:
- 対象: {target}
- 内容: {interpreted_change}

この解釈で正しいですか？

オプション:
- 正しい
- 修正する（詳細を入力）
```

### 2.3 Apply Edit Content (Internal)

Apply the interpreted edit content internally:

| Edit Target | Application Method |
|-------------|-------------------|
| Title | Retain new title string |
| Body | Apply changes to existing body |
| Status/Priority/Complexity | Retain new value |

**Note**: Do not push changes to GitHub at this point. Apply after confirmation in Phase 3.

---

## Phase 3: Display Diff and Confirm

### 3.1 Display Change Diff

Display the pending changes in diff format:

**Title Change:**
```
**タイトル**:
- 変更前: {old_title}
- 変更後: {new_title}
```

**Body Change:**
```
**本文の変更箇所**:

変更前:
> {old_section}

変更後:
> {new_section}
```

**Field Changes:**
```
**Projects フィールド**:
- Status: {old_status} → {new_status}
- Priority: {old_priority} → {new_priority}
- Complexity: {old_complexity} → {new_complexity}
```

### 3.2 User Confirmation

Confirm changes with `AskUserQuestion`:

```
上記の変更を適用しますか？

オプション:
- 変更を適用
- 変更を修正（Phase 2 に戻る）
- キャンセル（変更を破棄）
```

**When "変更を修正" is selected:**
- Return to Phase 2.1 and accept additional edit instructions
- Retain already-applied changes while accepting additional changes

---

## Phase 4: Apply Changes

### 4.1 Update Title and Body

If there are changes to the title or body:

```bash
# Generate body content by applying changes to existing body (see Phase 2.3)
# Note: Empty check is required because {new_body} is dynamically generated.
tmpfile=$(mktemp)
trap 'rm -f "$tmpfile"' EXIT

cat <<'BODY_EOF' > "$tmpfile"
{new_body}
BODY_EOF

if [ ! -s "$tmpfile" ]; then
  echo "ERROR: Updated body is empty" >&2
  exit 1
fi

gh issue edit {issue_number} --title "{new_title}" --body-file "$tmpfile"
```

**Title only change:**
```bash
gh issue edit {issue_number} --title "{new_title}"
```

**Body only change:**
```bash
# Generate body content by applying changes to existing body (see Phase 2.3)
# Note: Empty check is required because {new_body} is dynamically generated.
tmpfile=$(mktemp)
trap 'rm -f "$tmpfile"' EXIT

cat <<'BODY_EOF' > "$tmpfile"
{new_body}
BODY_EOF

if [ ! -s "$tmpfile" ]; then
  echo "ERROR: Updated body is empty" >&2
  exit 1
fi

gh issue edit {issue_number} --body-file "$tmpfile"
```

### 4.2 Update Projects Fields

If there are field changes, update each field.

#### 4.2.1 Retrieve Project Information

Retrieve Projects configuration from `rite-config.yml`:

```yaml
github:
  projects:
    enabled: true
    project_number: 2
    owner: "username"
```

#### 4.2.2 Determine Owner Type

Before executing the GraphQL query, determine whether the owner is a User or Organization:

```bash
gh api users/{owner} --jq '.type'
```

| Result | Action |
|--------|--------|
| `"Organization"` | Change `user(login: $owner)` to `organization(login: $owner)` in subsequent GraphQL queries |
| `"User"` | Use the query as-is |

#### 4.2.3 Retrieve Field Information

**Important**: Option IDs must always be retrieved from the API. Only field IDs can be specified via `field_ids`; option IDs (Done, In Progress, etc.) are not included.

```bash
gh project field-list {project_number} --owner {owner} --format json
```

From the resulting JSON, find the target fields (Status/Priority/Complexity) and retrieve the following information:
- `id`: Field ID (`{field_id}`)
- `id` of the desired option from the `options` array (`{option_id}`)

**Retrieval Logic:**
1. Execute the API (always required to get option IDs)
2. Check `github.projects.field_ids.{field_name}` in `rite-config.yml`
3. Determine field ID:
   - If configured -> use configured value
   - If not configured -> use value from API result
4. Option ID: retrieve from API result

#### 4.2.4 Update Each Field

**Update Status:**
```bash
gh project item-edit --project-id {project_id} --id {item_id} --field-id {status_field_id} --single-select-option-id {new_status_option_id}
```

**Update Priority:**
```bash
gh project item-edit --project-id {project_id} --id {item_id} --field-id {priority_field_id} --single-select-option-id {new_priority_option_id}
```

**Update Complexity:**
```bash
gh project item-edit --project-id {project_id} --id {item_id} --field-id {complexity_field_id} --single-select-option-id {new_complexity_option_id}
```

---

## Phase 5: Continuation Check and Completion Report

### 5.1 Report Applied Changes

```
Issue #{number} を更新しました

適用した変更:
{change_summary}
```

**change_summary example:**
```
- タイトル: "{old_title}" → "{new_title}"
- 本文: 概要セクションを更新
- Priority: Medium → High
```

### 5.2 Continuation Check

Check for additional edits with `AskUserQuestion`:

```
他に修正したい点はありますか？

オプション:
- 追加の修正を行う（Phase 2 に戻る）
- 修正完了（終了）
```

**When "追加の修正を行う" is selected:**
- Return to Phase 2.1 and accept additional edit instructions

### 5.3 Completion Report

When "修正完了" is selected:

```
Issue #{number} の編集が完了しました

最終状態:
- タイトル: {title}
- Status: {status}
- Priority: {priority}
- Complexity: {complexity}

URL: {issue_url}
```

**Retrieve URL:**
```bash
gh issue view {issue_number} --json url --jq '.url'
```

---

## Error Handling

See [Common Error Handling](../../references/common-error-handling.md) for shared patterns (Not Found, Permission, Network errors).

| Error | Recovery |
|-------|----------|
| Issue Not Found | See [common patterns](../../references/common-error-handling.md) |
| Permission Error | See [common patterns](../../references/common-error-handling.md) |
| Not Registered in Projects | タイトル・本文のみ編集 / キャンセル |
| Invalid Field Value | See error output for details |
| Network Error | See [common patterns](../../references/common-error-handling.md) |
