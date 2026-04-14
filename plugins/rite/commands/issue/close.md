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

Proceed to Phase 4.4.W.

### 4.4.W Wiki Ingest Trigger (Conditional)

> **Reference**: [Wiki Ingest](../wiki/ingest.md) — `wiki-ingest-trigger.sh` API

After completing the Issue close actions, trigger Wiki Ingest to capture retrospective knowledge from this Issue.

**Condition**: Execute only when `wiki.enabled: true` AND `wiki.auto_ingest: true` in `rite-config.yml`. Skip silently otherwise.

**Step 1**: Check Wiki configuration:

```bash
wiki_section=$(sed -n '/^wiki:/,/^[a-zA-Z]/p' rite-config.yml 2>/dev/null) || wiki_section=""
wiki_enabled=""
if [[ -n "$wiki_section" ]]; then
  wiki_enabled=$(printf '%s\n' "$wiki_section" | awk '/^[[:space:]]+enabled:/ { print; exit }' \
    | sed 's/[[:space:]]#.*//' | sed 's/.*enabled:[[:space:]]*//' | tr -d '[:space:]"'"'"'' | tr '[:upper:]' '[:lower:]')
fi
auto_ingest=""
if [[ -n "$wiki_section" ]]; then
  auto_ingest=$(printf '%s\n' "$wiki_section" | awk '/^[[:space:]]+auto_ingest:/ { print; exit }' \
    | sed 's/[[:space:]]#.*//' | sed 's/.*auto_ingest:[[:space:]]*//' | tr -d '[:space:]"'"'"'' | tr '[:upper:]' '[:lower:]')
fi
case "$wiki_enabled" in false|no|0) wiki_enabled="false" ;; true|yes|1) wiki_enabled="true" ;; *) wiki_enabled="true" ;; esac  # #483: opt-out default
case "$auto_ingest" in true|yes|1) auto_ingest="true" ;; *) auto_ingest="false" ;; esac
echo "wiki_enabled=$wiki_enabled auto_ingest=$auto_ingest"
```

If `wiki_enabled=false` or `auto_ingest=false`, skip this section and proceed to Phase 4.5.

**Step 2**: Generate a retrospective Raw Source from the Issue context:

The retrospective content includes: Issue title, key decisions made during implementation, unexpected difficulties encountered, and effective approaches used.

```bash
# {plugin_root} はリテラル値で埋め込む
tmpfile=$(mktemp)
trap 'rm -f "$tmpfile"' EXIT

cat <<'RETRO_EOF' > "$tmpfile"
## Issue Close Retrospective

- **Issue**: #{issue_number} — {title}
- **Type**: retrospective
- **Closed at**: {timestamp}

### Summary
{retrospective_summary — Issue の作業中に学んだこと、予想外の困難、有効だったアプローチを LLM が Issue body + work memory から要約して埋め込む}
RETRO_EOF

bash {plugin_root}/hooks/wiki-ingest-trigger.sh \
  --type retrospectives \
  --source-ref "issue-{issue_number}" \
  --content-file "$tmpfile" \
  --issue-number {issue_number} \
  --title "Issue #{issue_number} close retrospective" \
  2>/dev/null
trigger_exit=$?
echo "trigger_exit=$trigger_exit"
```

**Non-blocking**: `wiki-ingest-trigger.sh` exit 2 (Wiki disabled/uninitialized) and other errors are captured in `trigger_exit` and do not halt the workflow. The LLM reads `trigger_exit` from stdout and skips Phase 4.4.W.2 when it is non-zero. Ingest failure does not block the close workflow.

### 4.4.W.2 Wiki Ingest Invocation (Conditional)

After the trigger completes, invoke `/rite:wiki:ingest` via the Skill tool so that the Raw Source written by the trigger is committed and pushed to the `wiki` branch. Without this step, the Raw Source is abandoned in the working tree and the `wiki` branch never grows (Issue #515 root cause).

**Condition**: Execute only when **all** of the following are true (read from prior Phase 4.4.W stdout):

- `wiki_enabled=true`
- `auto_ingest=true`
- `trigger_exit=0` (the trigger ran successfully — non-zero means Wiki disabled/uninitialized, so there is nothing to ingest)

**When the condition is not satisfied**, skip this section silently and proceed to Phase 4.5.

**When the condition is satisfied**:

1. Invoke the Skill tool: `skill: "rite:wiki:ingest"` with no arguments. The ingest command auto-scans `.rite/wiki/raw/` and performs stash/checkout/commit/push to the `wiki` branch via its existing Phase 5.1 Block B implementation.
2. **Non-blocking**: Any error returned by the Skill invocation (push failure, authentication error, LLM error, etc.) is swallowed — continue to Phase 4.5 regardless. The Raw Source remains under `.rite/wiki/raw/{type}/` and will be picked up by the next successful ingest.
3. Do **not** pass PR/Issue number as arguments. `rite:wiki:ingest` is self-contained and discovers raw sources independently.

**Rationale**: `wiki-ingest-trigger.sh` is a pure file-writing utility (see its L40-44 doc comment) and does not perform git operations. Only `rite:wiki:ingest` has the stash/checkout/commit/push sequence that persists data to the `wiki` branch. This two-step pattern preserves the responsibility boundary (trigger writes, ingest commits) while restoring the Wiki growth path.

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
# SIGPIPE 防止 (#398): issue_body が大きい場合、echo | grep | head -1 で
# head の早期終了により echo に SIGPIPE が届く。here-string で subprocess を排除。
parent_number=$(grep -A2 '^## 親 Issue' <<< "$issue_body" | grep -oE '#[0-9]+' | head -1 | tr -d '#')
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

Execute the fetch script directly. The LLM reads `tmpfile_read`, `tmpfile_write`, and `original_length` from the Bash tool output:

```bash
bash {plugin_root}/hooks/issue-body-safe-update.sh fetch --issue {parent_number} --parent
```

If the output contains `tmpfile_read=`, `tmpfile_write=`, and `original_length=`, proceed to Step 2. If the script outputs only a WARNING or fails, display a warning and proceed to Phase 5 (non-blocking, AC-4).

**Step 2: Apply updates via Read tool + Write tool** (Sub-Issues checkbox + 実装フェーズ status in a single pass)

Read `$tmpfile_read` (the path from Step 1 output) using the Read tool. Then apply the following two replacements to the body text:

1. **Sub-Issues checkbox**: Find the line matching `- [ ] #{issue_number}` and replace `- [ ]` with `- [x]` (only the specific Issue number line)
2. **実装フェーズ table**: Find rows whose `内容` column contains `#{issue_number}` and replace `[ ] 未着手` with `[x] 完了` in those rows

Write the updated body to `$tmpfile_write` (the path from Step 1 output) using the Write tool.

**Note**: Only lines containing `#{issue_number}` are modified. Other sections remain untouched (R7).

**Step 3: Apply the update**

```bash
bash {plugin_root}/hooks/issue-body-safe-update.sh apply \
  --issue {parent_number} \
  --tmpfile-read "$tmpfile_read" \
  --tmpfile-write "$tmpfile_write" \
  --original-length "$original_length" \
  --parent --diff-check
```

If the script exits with 0, the update succeeded (or was skipped by `--diff-check` if no changes were needed). If non-zero, display a warning and proceed to Phase 5.

**On failure**: Display warning and proceed to Phase 5 (non-blocking, AC-4). The `--parent` flag is passed for future differentiation but currently all errors are treated as warnings by the script. The `--diff-check` flag skips the apply if no actual changes were made (idempotency). The Issue close itself (Phase 4.1) has already succeeded at this point.

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
