---
description: Issue の完了状態を確認
---

# /rite:issue:close

Check the completion status of an Issue and guide necessary actions

---

When this command is executed, run the following phases in order.

## Arguments

| Argument | Description |
|------|------|
| `<issue_number>` | Issue number to check (required) |

---

## Phase 1: Check Issue Status

### 1.1 Retrieve Issue Information

Retrieve detailed information for the specified Issue:

```bash
gh issue view {issue_number} --json number,title,body,state,labels,closedAt
```

### 1.2 Determine Issue State

Branch based on the Issue state:

**If the Issue is already closed:**

```
{i18n:issue_close_already_closed} (variables: number={number})

{i18n:workflow_title}: {title}
{i18n:issue_close_closed_at}: {closed_at}

{i18n:issue_close_no_action_needed}
```

Proceed to Phase 1.3 (Projects Status Sync for Already-Closed Issues).

**If the Issue is open:**

Proceed to Phase 2.

---

## Phase 1.3: Projects Status Sync for Already-Closed Issues

When an Issue is already closed but its Projects Status may not be "Done" (e.g., closed outside the rite workflow), check and update the status.

### 1.3.1 Projects Enabled Check

Read `rite-config.yml` with the Read tool and check `github.projects.enabled`.

If `projects.enabled: false` (or not configured): skip this phase and proceed to Phase 5.

### 1.3.2 Retrieve Current Projects Status

Retrieve the Issue's project item and current status:

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
          fieldValueByName(name: "Status") {
            ... on ProjectV2ItemFieldSingleSelectValue {
              name
              optionId
            }
          }
        }
      }
    }
  }
}' -f owner="{owner}" -f repo="{repo}" -F number={issue_number}
```

Find the node where `project.number` matches the `project_number` from `rite-config.yml`. Extract `{item_id}` (node `id`) and `{project_id}` (node `project.id`).

**Error handling for Phase 1.3.2:**

| Condition | Action |
|-----------|--------|
| GraphQL API error (network error, auth failure, etc.) | Display `警告: Projects API の呼び出しに失敗しました` → Proceed to Phase 5 (non-blocking) |
| `projectItems.nodes` is empty (Issue not registered in Project) | Display `警告: Issue #{issue_number} は Project に登録されていません` → Proceed to Phase 5 (non-blocking) |
| No node matches configured `project_number` | Display `警告: Issue #{issue_number} は対象の Project (#{project_number}) に登録されていません` → Proceed to Phase 5 (non-blocking) |

### 1.3.3 Check and Update Status

Determine the current status from `fieldValueByName`. If `fieldValueByName` is `null` (status not set on the item), treat as NOT "Done" and proceed to the update flow.

**If current status is already "Done":**

```
Projects Status は既に "Done" です
```

Display message and proceed to Phase 5.

**If current status is NOT "Done" (or null/unset):**

Retrieve the "Done" option ID and update.

#### 1.3.3.1 Retrieve Status Field Information

**Retrieval Logic:**
1. Execute the API (always required to get the option ID):
   ```bash
   gh project field-list {project_number} --owner {owner} --format json
   ```
2. Check `rite-config.yml`'s `github.projects.field_ids.status`
3. Determine the field ID:
   - If configured → use the configured value as `{status_field_id}`
   - If not configured → retrieve `{status_field_id}` from API results (the `id` of the field where `name` is `"Status"`)
4. Option ID: retrieve `{done_option_id}` from API results (the `id` of the option where `name` is `"Done"`)

**Error handling for Phase 1.3.3.1:**

| Condition | Action |
|-----------|--------|
| `gh project field-list` command fails (permission error, network error, etc.) | Display `警告: Projects フィールド情報の取得に失敗しました` → Proceed to Phase 5 (non-blocking) |
| Status field not found in API results | Display `警告: Status フィールドが見つかりません` → Proceed to Phase 5 (non-blocking) |
| "Done" option not found in Status field options | Display `警告: Status フィールドに "Done" オプションが見つかりません` → Proceed to Phase 5 (non-blocking) |

#### 1.3.3.2 Update Status to "Done"

```bash
gh project item-edit --project-id {project_id} --id {item_id} --field-id {status_field_id} --single-select-option-id {done_option_id}
```

On success:

```
Projects Status を "Done" に更新しました
```

On failure:

```
警告: Projects Status の更新に失敗しました
```

Display warning and proceed to Phase 5 (non-blocking).

Proceed to Phase 5.

---

## Phase 2: Search for Linked PRs

### 2.1 Search for Related PRs

Search for PRs linked to the Issue:

```bash
gh pr list --state all --search "linked:issue:{issue_number}" --json number,title,state,mergedAt,url
```

Or search for PRs that reference the Issue number:

```bash
gh pr list --state all --json number,title,state,body,mergedAt,url
```

Check whether the body of the found PRs contains the following patterns:
- `Closes #{issue_number}`
- `closes #{issue_number}`
- `Fixes #{issue_number}`
- `fixes #{issue_number}`
- `Resolves #{issue_number}`
- `resolves #{issue_number}`

### 2.2 Search PRs by Branch Name

Also search for PRs from branches containing the Issue number:

```bash
gh pr list --state all --head "*issue-{issue_number}*" --json number,title,state,mergedAt,url
```

### 2.3 Aggregate Search Results

List all related PRs found:

| # | タイトル | 状態 | マージ日時 |
|---|---------|------|----------|
| #{pr_number} | {pr_title} | {state} | {merged_at} |

---

## Phase 3: Auto-Close Determination

### 3.1 Auto-Close Conditions

Conditions under which an Issue is automatically closed:

1. The PR body contains `Closes #XXX`, `Fixes #XXX`, or `Resolves #XXX`
2. That PR has been merged

### 3.2 Determination Results by Scenario

#### Pattern A: Already Auto-Closed (or Scheduled)

If a linked PR is merged and contains a close keyword:

```
{i18n:issue_close_auto_close_will_happen} (variables: number={number})

{i18n:issue_close_linked_prs}:
- #{pr_number}: {pr_title} (Merged)

{i18n:issue_close_auto_close_note}
{i18n:issue_close_no_action_needed}
```

#### Pattern B: PR Exists but No Auto-Close

If a linked PR exists but does not contain a close keyword:

```
{i18n:issue_close_no_auto_close} (variables: number={number})

{i18n:issue_close_linked_prs}:
- #{pr_number}: {pr_title} ({state})

{i18n:issue_close_recommended_action}:
1. {i18n:issue_close_add_closes_keyword} (variables: number={number})
2. {i18n:issue_close_manual_close}
```

#### Pattern C: PR Awaiting Merge

If a linked PR is in open state:

```
{i18n:issue_close_pr_pending} (variables: number={number})

{i18n:issue_close_linked_prs}:
- #{pr_number}: {pr_title} (Open)
  URL: {pr_url}

{i18n:issue_close_recommended_action}:
1. PR をレビュー・マージ
2. マージ後、Issue は自動的にクローズされます
```

#### Pattern D: No PR Found

If no related PR is found:

```
{i18n:issue_close_no_prs_found} (variables: number={number})

オプション:
- PR を作成してから Issue をクローズ: /rite:pr:create
- 手動で Issue をクローズ: gh issue close {number}
- Issue を開いたままにする
```

Use `AskUserQuestion` to confirm the next action:

```
{i18n:issue_close_ask_action}

オプション:
- {i18n:issue_close_option_create_pr}
- {i18n:issue_close_option_close_manual}
- {i18n:issue_close_option_do_nothing}
```

---

## Phase 4: Execute Actions

### 4.1 Execute Manual Close

If the user selected manual close:

```bash
gh issue close {issue_number}
```

### 4.2 Update Projects Status

When the Issue is closed, update the Projects Status to "Done":

```bash
# プロジェクトアイテム情報を取得
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
        }
      }
    }
  }
}' -f owner="{owner}" -f repo="{repo}" -F number={issue_number}
```

#### 4.2.1 Retrieve Status Field Information

**Important**: The option ID (`{done_option_id}`) must always be retrieved from the API. Only field IDs can be specified in `field_ids`; the IDs for each option (Done, In Progress, etc.) are not included.

**Retrieving the Field ID:**

If `rite-config.yml`'s `github.projects.field_ids.status` is configured, use that value directly as `{status_field_id}` (skip extracting the field ID from API results):

Replace the configured value with the actual project ID (see CONFIGURATION.md for how to obtain it):

```yaml
github:
  projects:
    field_ids:
      status: "PVTSSF_your-status-field-id"
```

**Retrieving the Option ID (always required):**

```bash
gh project field-list {project_number} --owner {owner} --format json
```

From the resulting JSON, find the field where `name` is `"Status"` and retrieve the following information:
- `id`: The Status field ID (`{status_field_id}`) -- used only when `field_ids` is not configured
- From the `options` array, the `id` of the option where `name` is `"Done"` (`{done_option_id}`)

**Retrieval Logic:**
1. Execute the API (always required to get the option ID)
2. Check `rite-config.yml`'s `github.projects.field_ids.status`
3. Determine the field ID:
   - If configured -> use the configured value as `{status_field_id}`
   - If not configured -> retrieve `{status_field_id}` from API results
4. Option ID: retrieve `{done_option_id}` from API results

**Update Status to "Done":**

```bash
gh project item-edit --project-id {project_id} --id {item_id} --field-id {status_field_id} --single-select-option-id {done_option_id}
```

### 4.3 Update Local Work Memory

Before deletion in Phase 5, record the completion state in local work memory:

```bash
WM_SOURCE="close" \
  WM_PHASE="completed" \
  WM_PHASE_DETAIL="Issue クローズ完了" \
  WM_NEXT_ACTION="なし" \
  WM_BODY_TEXT="Issue closed." \
  WM_ISSUE_NUMBER="{issue_number}" \
  bash {plugin_root}/hooks/local-wm-update.sh 2>/dev/null || true
```

**On lock failure**: Log a warning and continue — local work memory update is best-effort. The file will be deleted in Phase 5 regardless.

**Step 2: Sync to Issue comment (backup)** — Skipped. Phase 5 deletes the local work memory file, and the Issue comment serves as the final archival record (updated by `rite:pr:cleanup` Phase 4.5). No separate backup sync is needed here.

### 4.4 Completion Report

```
{i18n:issue_close_complete} (variables: number={number})

{i18n:workflow_title}: {title}
Status: Done

関連 PR: #{pr_number} (Merged)
```

Proceed to Phase 4.5.

---

## Phase 4.5: Parent Issue Body Update

When a child Issue is closed, automatically update the parent Issue's body to reflect the child's completion status.

### 4.5.1 Detect Parent Issue

Extract the parent Issue number from the closing Issue's body. The `## 親 Issue` section is added by `/rite:issue:create-decompose` when creating child Issues.

**Detection pattern**: Search the Issue body for the `## 親 Issue` section header, then extract the Issue number from the line below it:

```
## 親 Issue

#{parent_number} - {parent_title}
```

**Extraction**: Retrieve the Issue body and extract the parent Issue number in a single bash block:

```bash
issue_body=$(gh issue view {issue_number} --json body --jq '.body')
parent_number=$(echo "$issue_body" | grep -A1 '^## 親 Issue' | grep -oE '#[0-9]+' | head -1 | tr -d '#')
echo "parent_number=${parent_number:-none}"
```

**When no parent Issue is found** (`parent_number` is empty):

```
親 Issue の参照が見つかりませんでした。親 Issue 更新をスキップします。
```

Skip the rest of Phase 4.5 and proceed to Phase 5. This is normal behavior (AC-3), not an error.

### 4.5.2 Update Parent Issue Body

Update the parent Issue's Sub-Issues checkbox and 実装フェーズ status using the 3-step safe update pattern via `issue-body-safe-update.sh`.

> **Reference**: Uses the same safe update pattern as `implement.md` and `archive-procedures.md` — fetch/edit/apply with body shrinkage detection and diff-check idempotency.

**Step 1: Fetch parent Issue body**

```bash
fetch_result=$(bash {plugin_root}/hooks/issue-body-safe-update.sh fetch --issue {parent_number} --parent)
if [ $? -ne 0 ]; then
  echo "警告: 親 Issue #{parent_number} の本文を取得できませんでした" >&2
  # Non-blocking: proceed to Phase 5 (AC-4)
else
  eval "$fetch_result"
  echo "tmpfile_read=$tmpfile_read"
  echo "tmpfile_write=$tmpfile_write"
  echo "original_length=$original_length"
fi
```

**On failure**: Display warning and proceed to Phase 5 (non-blocking, AC-4).

**Step 2: Apply updates via Python** (Sub-Issues checkbox + 実装フェーズ status in a single pass)

Use the Read tool to read `$tmpfile_read` (the path from Step 1), then apply updates via Python and write to `$tmpfile_write`:

```bash
python3 -c "
import re

tmpfile_read = '{tmpfile_read}'
tmpfile_write = '{tmpfile_write}'
issue_number = '{issue_number}'

with open(tmpfile_read, 'r') as f:
    body = f.read()

# 1. Update Sub-Issues checkbox: - [ ] #{issue_number} -> - [x] #{issue_number}
body = re.sub(
    r'^(- \[) (\] #' + issue_number + r'(?:\s|$))',
    r'\g<1>x\g<2>',
    body,
    flags=re.MULTILINE
)

# 2. Update 実装フェーズ table: find rows referencing #{issue_number} and replace status
lines = body.split('\n')
updated_lines = []
for line in lines:
    if '#' + issue_number in line:
        line = line.replace('[ ] 未着手', '[x] 完了')
    updated_lines.append(line)
body = '\n'.join(updated_lines)

with open(tmpfile_write, 'w') as f:
    f.write(body)
"
```

**Note**: Only lines containing `#{issue_number}` are modified. Other sections remain untouched (R7). The `import sys` is omitted as it is not used.

**Step 3: Apply the update**

```bash
bash {plugin_root}/hooks/issue-body-safe-update.sh apply \
  --issue {parent_number} \
  --tmpfile-read "$tmpfile_read" \
  --tmpfile-write "$tmpfile_write" \
  --original-length "$original_length" \
  --parent --diff-check

apply_exit=$?
if [ "$apply_exit" -eq 0 ]; then
  echo "親 Issue #{parent_number} の本文を更新しました（Sub-Issues / 実装フェーズ）"
else
  echo "警告: 親 Issue #{parent_number} の本文更新に失敗しました" >&2
fi
```

**On failure**: Display warning and proceed to Phase 5 (non-blocking, AC-4). The `--parent` flag ensures errors are treated as warnings, not fatal errors. The `--diff-check` flag skips the apply if no actual changes were made (idempotency). The Issue close itself (Phase 4.1) has already succeeded at this point.

Proceed to Phase 5.

---

## Phase 5: Delete Local Work Memory Files

**Execution condition**: Always executed as the final phase, regardless of whether the Issue was already closed (Phase 1.2) or just closed (Phase 4). Only requires `{issue_number}` to be available.

Delete the local work memory file and its lock directory for the specified Issue using the cleanup-work-memory script with `--issue` flag (close mode: deletes only the specified Issue's files, does NOT reset `.rite-flow-state` or sweep stale files).

Resolve `{plugin_root}` per [Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script) if not already resolved.

```bash
bash {plugin_root}/hooks/cleanup-work-memory.sh --issue {issue_number}
```

**Note**: The `--issue` flag passes the Issue number directly to the script, bypassing LLM placeholder substitution for file paths. The script constructs the exact file path internally. Unlike the full cleanup mode in `cleanup.md`, `{issue_number}` here is the user-provided argument to `/rite:issue:close`, not derived from state files.

**Do NOT delete** the `.rite-work-memory/` directory itself — the script preserves it.

**Error handling:**

| Error Case | Response |
|-----------|----------|
| Files do not exist | No error (script handles gracefully) |
| Permission error | Script displays WARNING to stderr; display warning and end processing (non-blocking) |
| Script itself fails | Display warning and end processing (non-blocking) |

**Warning message on failure:**

```
警告: ローカル作業メモリの削除に失敗しました
手動で削除する場合: rm -f ".rite-work-memory/issue-{issue_number}.md" && rm -rf ".rite-work-memory/issue-{issue_number}.md.lockdir"
```

**Note**: Failure to delete local work memory files does not block the process. Display a warning and end processing.

### 5.1 Deletion Result Display

After executing the deletion commands, display the result:

```
ローカル作業メモリ: {削除済み / 削除失敗（警告参照） / 該当なし}
```

**Script output to display value mapping:**

| Script Output | Display Value |
|--------------|---------------|
| `削除: 1` or more | `削除済み` |
| `失敗: 1` or more | `削除失敗（警告参照）` |
| `削除: 0, 失敗: 0` | `該当なし` |

End processing.

---

## Error Handling

See [Common Error Handling](../../references/common-error-handling.md) for shared patterns (Not Found, Permission, Network errors).

| Error | Recovery |
|-------|----------|
| If the Issue Is Not Found | See [common patterns](../../references/common-error-handling.md) |
| If a Permission Error Occurs | See [common patterns](../../references/common-error-handling.md) |
| If a Network Error Occurs | See [common patterns](../../references/common-error-handling.md) |
