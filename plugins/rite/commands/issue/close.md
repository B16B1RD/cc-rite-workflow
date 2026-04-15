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

> **⚠️ E2E Mandatory (Issue #524 — silent-skip 防止層 1)**: Phase 4.4.W and 4.4.W.2 are **NEVER** skipped under any output-minimization rule. Even when called from `/rite:issue:start` Phase 5.7 (parent close) or downstream automation, this section MUST execute (subject only to the configuration-based skip in Step 1 below). Skipping silently is the regression that Issue #524 explicitly fixes.

**Condition**: Execute only when `wiki.enabled: true` AND `wiki.auto_ingest: true` in `rite-config.yml`. Configuration-based skip is the **only** legitimate skip path — it MUST emit a `WIKI_INGEST_SKIPPED=1` status line and `wiki_ingest_skipped` sentinel so the caller can detect and report (see Phase 4.4.W.3 below).

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

If `wiki_enabled=false` or `auto_ingest=false`, **emit a skip status line + sentinel and proceed to Phase 4.5** (do not silently skip — the caller relies on this signal for Phase 5.6 reporting):

```bash
if [ "$wiki_enabled" = "false" ]; then
  reason="disabled"
elif [ "$auto_ingest" = "false" ]; then
  reason="auto_ingest_off"
else
  reason=""
fi
if [ -n "$reason" ]; then
  echo "[CONTEXT] WIKI_INGEST_SKIPPED=1; reason=$reason"
  emit_err=$(mktemp /tmp/rite-wiki-emit-err-XXXXXX 2>/dev/null) || emit_err=""
  trap 'rm -f "${emit_err:-}"' EXIT INT TERM HUP
  # close.md は通常 PR が確定していないため "${pr_number:-0}" で 0 にフォールバック。
  # PR 番号が shell 変数として set されている場合のみその値を採用する (template substitution は使わない)
  emit_pr_number="${pr_number:-0}"
  if sentinel_line=$(bash {plugin_root}/hooks/workflow-incident-emit.sh \
      --type wiki_ingest_skipped \
      --details "close Phase 4.4.W skipped: $reason" \
      --pr-number "$emit_pr_number" 2>"${emit_err:-/dev/null}"); then
    if [ -n "$sentinel_line" ]; then
      echo "$sentinel_line"
      echo "$sentinel_line" >&2
    fi
  else
    fallback_iter="${emit_pr_number}-$(date +%s)"
    fallback_sentinel="[CONTEXT] WORKFLOW_INCIDENT=1; type=hook_abnormal_exit; details=workflow-incident-emit.sh failed for wiki_ingest_skipped reason=$reason; iteration_id=$fallback_iter"
    echo "$fallback_sentinel"
    echo "$fallback_sentinel" >&2
    echo "WARNING: workflow-incident-emit.sh (wiki_ingest_skipped) が失敗しました — hook_abnormal_exit sentinel で fallback emit 済み" >&2
    [ -n "$emit_err" ] && [ -s "$emit_err" ] && head -3 "$emit_err" | sed 's/^/  /' >&2
  fi
  [ -n "$emit_err" ] && rm -f "$emit_err"
  trap - EXIT INT TERM HUP
fi
```

If `reason` is non-empty, skip Steps 2 and Phase 4.4.W.2 and proceed directly to Phase 4.5. Otherwise continue to Step 2.

**Step 2**: Generate a retrospective Raw Source from the Issue context:

The retrospective content includes: Issue title, key decisions made during implementation, unexpected difficulties encountered, and effective approaches used.

```bash
# {plugin_root} はリテラル値で埋め込む
# ⚠️ wiki-ingest-trigger.sh は --content-file に $PWD 配下 または /tmp/rite-* prefix のみを受容する
# (Issue #518 根本原因)。mktemp デフォルトの /tmp/tmp.* では trigger が exit 1 で silent fail する
tmpfile=$(mktemp /tmp/rite-wiki-content-XXXXXX)
trigger_stderr=$(mktemp /tmp/rite-wiki-trigger-err-XXXXXX) || trigger_stderr=/dev/null
# rm -f /dev/null は EPERM (exit 1) を返すため trap で条件分岐する (F-07 対応)
trap 'rm -f "$tmpfile"; [ "$trigger_stderr" != "/dev/null" ] && rm -f "$trigger_stderr"' EXIT

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
  2>"$trigger_stderr"
trigger_exit=$?
echo "trigger_exit=$trigger_exit"
if [ "$trigger_exit" -ne 0 ] && [ "$trigger_stderr" != "/dev/null" ] && [ -s "$trigger_stderr" ]; then
  # UTF-8 multi-byte 境界を safe にする (head -c 500 で切れた invalid sequence を drop)
  # (F-09 対応) iconv 不在環境 (Alpine 等) では LC_ALL=C tr で ASCII-only fallback
  if command -v iconv >/dev/null 2>&1; then
    _wiki_err_snippet=$(tr '\n' ' ' < "$trigger_stderr" | head -c 500 | iconv -c -f UTF-8 -t UTF-8 2>/dev/null)
  else
    _wiki_err_snippet=$(tr '\n' ' ' < "$trigger_stderr" | head -c 500 | LC_ALL=C tr -cd '\11\12\15\40-\176')
  fi
  echo "[CONTEXT] WIKI_TRIGGER_STDERR=${_wiki_err_snippet}" >&2
fi
```

**Non-blocking**: `wiki-ingest-trigger.sh` exit 2 (Wiki disabled/uninitialized) and other errors are captured in `trigger_exit` and do not halt the workflow. The LLM reads `trigger_exit` from stdout and skips Phase 4.4.W.2 when it is non-zero. Ingest failure does not block the close workflow.

**Step 3 — Failure sentinel emit (Issue #524)**: When `trigger_exit != 0` AND `trigger_exit != 2` (exit 2 = Wiki disabled/uninitialized = legitimate skip already covered by Step 1), emit the `wiki_ingest_failed` sentinel so Phase 5.4.4.1 can register the incident:

```bash
if [ "$trigger_exit" -ne 0 ] && [ "$trigger_exit" -ne 2 ]; then
  echo "[CONTEXT] WIKI_INGEST_FAILED=1; reason=trigger_exit_$trigger_exit; exit_code=$trigger_exit"
  emit_err=$(mktemp /tmp/rite-wiki-emit-err-XXXXXX 2>/dev/null) || emit_err=""
  trap 'rm -f "${emit_err:-}"' EXIT INT TERM HUP
  emit_pr_number="${pr_number:-0}"
  if sentinel_line=$(bash {plugin_root}/hooks/workflow-incident-emit.sh \
      --type wiki_ingest_failed \
      --details "wiki-ingest-trigger.sh exited $trigger_exit during issue/close.md Phase 4.4.W" \
      --pr-number "$emit_pr_number" 2>"${emit_err:-/dev/null}"); then
    if [ -n "$sentinel_line" ]; then
      echo "$sentinel_line"
      echo "$sentinel_line" >&2
    fi
  else
    fallback_iter="${emit_pr_number}-$(date +%s)"
    fallback_sentinel="[CONTEXT] WORKFLOW_INCIDENT=1; type=hook_abnormal_exit; details=workflow-incident-emit.sh failed for wiki_ingest_failed trigger_exit=$trigger_exit; iteration_id=$fallback_iter"
    echo "$fallback_sentinel"
    echo "$fallback_sentinel" >&2
    echo "WARNING: workflow-incident-emit.sh (wiki_ingest_failed) が失敗しました — hook_abnormal_exit sentinel で fallback emit 済み" >&2
    [ -n "$emit_err" ] && [ -s "$emit_err" ] && head -3 "$emit_err" | sed 's/^/  /' >&2
  fi
  [ -n "$emit_err" ] && rm -f "$emit_err"
  trap - EXIT INT TERM HUP
fi
```

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
4. **Done status emit (Issue #524)**: After `rite:wiki:ingest` returns (regardless of its internal success/failure — see step 2 swallow rule), emit a `WIKI_INGEST_DONE=1` status line so the caller can populate the Phase 5.6 "Wiki ingest 状況" section:
   ```bash
   echo "[CONTEXT] WIKI_INGEST_DONE=1; issue={issue_number}; type=retrospectives"
   ```

**Rationale**: `wiki-ingest-trigger.sh` is a pure file-writing utility (see its L40-44 doc comment) and does not perform git operations. Only `rite:wiki:ingest` has the stash/checkout/commit/push sequence that persists data to the `wiki` branch. This two-step pattern preserves the responsibility boundary (trigger writes, ingest commits) while restoring the Wiki growth path.

Proceed to Phase 4.5.

---

## Phase 4.5: Parent Issue Body Update

When a child Issue is closed, automatically update the parent Issue's body to reflect the child's completion status.

### 4.5.1 Detect Parent Issue

Detect the parent Issue via **three methods tried in order (OR combination)**. This mirrors the 3-method detection in [`projects-integration.md` 2.4.7.1](../../references/projects-integration.md#247-parent-issue-status-update-for-child-issues) — the two sites MUST stay consistent to prevent silent-skip regressions (see Issue #513 / past incidents #115, #381, #15).

**Method 1: `## 親 Issue` body meta (PRIMARY)**

Read the closing Issue body and search for the `## 親 Issue` section written by `/rite:issue:create-decompose`.

```
## 親 Issue

#{parent_number} - {parent_title}
```

```bash
issue_body=$(gh issue view {issue_number} --json body --jq '.body')
# SIGPIPE 防止 (#398): here-string で subprocess を排除
parent_number=$(grep -A2 '^## 親 Issue' <<< "$issue_body" | grep -oE '#[0-9]+' | head -1 | tr -d '#')
echo "method1_parent=${parent_number:-none}"
```

If `parent_number` is non-empty, proceed to 4.5.2.

**Method 2: Sub-Issues API (secondary)**

If Method 1 returned empty, query GitHub's native Sub-Issues feature:

```bash
parent_number=$(gh api graphql -H "GraphQL-Features: sub_issues" -f query='
query($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) {
    issue(number: $number) {
      parent { number }
    }
  }
}' -f owner="{owner}" -f repo="{repo}" -F number={issue_number} \
  --jq '.data.repository.issue.parent.number // empty')
echo "method2_parent=${parent_number:-none}"
```

If non-empty, proceed to 4.5.2.

**Method 3: Tasklist search (last resort)**

If both methods failed:

```bash
parent_number=$(gh issue list --state all --search "in:body \"- [ ] #{issue_number}\" OR \"- [x] #{issue_number}\"" --json number --limit 1 --jq '.[0].number // empty')
echo "method3_parent=${parent_number:-none}"
```

GitHub code search with `[`/`]` is unreliable, which is why this is the last resort. `--state all` (not `--state open`) because the closing Issue's parent may already be closed if someone closed it manually.

**When all three methods failed (`parent_number` empty)**:

```bash
echo "[DEBUG] parent not detected for issue #{issue_number} — processing as standalone (methods tried: body_meta, sub_issues_api, tasklist_search)"
```

Display:

```
親 Issue の参照が見つかりませんでした。親 Issue 更新をスキップします。
```

Skip the rest of Phase 4.5 and Phase 4.6 and proceed to Phase 5. This is normal behavior (AC-4), not an error — but the debug log above makes the skip visible so silent-skip regressions are detectable.

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

**On failure**: Display warning and proceed to Phase 4.6 (non-blocking, AC-4). The `--parent` flag is passed for future differentiation but currently all errors are treated as warnings by the script. The `--diff-check` flag skips the apply if no actual changes were made (idempotency). The Issue close itself (Phase 4.1) has already succeeded at this point.

Proceed to Phase 4.6.

---

## Phase 4.6: Parent Auto-Close (All Children Completed)

> **Issue #513 AC-2**: When all child Issues of the detected parent are now closed (including the just-closed one), offer to auto-close the parent. This closes the "child close → parent stays Open" silent-skip hole.

**Execution condition**: Only execute when `{parent_number}` was detected in Phase 4.5.1 (any of the three methods succeeded). If no parent was detected, skip Phase 4.6 entirely and proceed to Phase 5.

**Three-level nesting guard (AC / MUST NOT)**: This phase processes only the direct parent. It does NOT recurse into the parent's parent (grandparent). Three-level nesting is explicitly out of scope (see Issue #513 Section 2 Out of Scope).

### 4.6.0 Idempotency Check (parent-already-closed no-op)

Before enumerating children, check whether the parent Issue is already closed. If so, this is a no-op invocation (the parent was previously closed — manually, by a prior auto-close run, or externally) and we must not re-prompt the user.

> **Note on AC-6**: Issue #513's AC-6 as written addresses the **start** side ("parent already In Progress → no-op"). This Phase 4.6.0 applies the **same idempotency principle** to the close side (parent already CLOSED → no-op). AC-6 is not literally covering the close-side case, so we avoid citing AC-6 directly and instead describe this as "close-side idempotency, extending the AC-6 principle to the symmetric close path."

Design principle (Issue #517 cycle 2 review fix): this bash block follows the same silent-failure avoidance pattern as Phase 4.6.1 — stderr is captured to a tempfile and surfaced on failure, explicit sentinels (`[CONTEXT] P460_DECISION=...`) drive LLM routing, and the retrieval-failure branch is implemented in bash (not prose only).

```bash
# ============================================================================
# Phase 4.6.0: Idempotency check (parent already closed → no-op)
# ============================================================================
set -uo pipefail  # strict mode (fail on undefined vars + preserve pipeline failure code)

parent_number="{parent_number}"

# --- Placeholder substitution sanity guard ---
# Phase 4.6 is only reachable when Phase 4.5.1 detected a parent. If the LLM
# routed into Phase 4.6 without substituting `{parent_number}` (e.g., skip-logic
# bug or placeholder left literal), subsequent `gh issue view "{parent_number}"`
# would fail with an "invalid issue number" error on stderr, and the Phase 4.6.0
# else branch would classify it as "retrieval failed" — which is technically
# correct but masks the true root cause (routing bug, not API failure).
# This case statement surfaces the routing bug explicitly instead of silently
# degrading into the retrieval-failure path.
case "$parent_number" in
  ''|'{parent_number}')
    echo "[DEBUG] p460: parent_number is empty or unsubstituted literal ('$parent_number') — Phase 4.6 should not have been entered. Aborting Phase 4.6 (caller routing bug)." >&2
    echo "[CONTEXT] P460_DECISION=skip_routing_bug"
    exit 0
    ;;
  *[!0-9]*)
    echo "[DEBUG] p460: parent_number is not numeric ('$parent_number') — Phase 4.6 should not have been entered. Aborting Phase 4.6." >&2
    echo "[CONTEXT] P460_DECISION=skip_routing_bug"
    exit 0
    ;;
esac

parent_state=""
p460_err=""
_rite_close_p460_cleanup() {
  rm -f "${p460_err:-}"
}
trap 'rc=$?; _rite_close_p460_cleanup; exit $rc' EXIT
trap '_rite_close_p460_cleanup; exit 130' INT
trap '_rite_close_p460_cleanup; exit 143' TERM
trap '_rite_close_p460_cleanup; exit 129' HUP

# Capture stderr to tempfile (not /dev/null) so auth / network failures surface.
# `mktemp` with no arguments respects $TMPDIR (honoring macOS /var/folders, CI overrides, etc.)
if ! p460_err=$(mktemp 2>/dev/null); then
  echo "[DEBUG] p460: mktemp failed — stderr from gh issue view will not be captured" >&2
  p460_err=""
fi

if parent_state=$(gh issue view "$parent_number" --json state --jq '.state' 2>"${p460_err:-/dev/null}"); then
  echo "parent_state=$parent_state"
else
  p460_rc=$?
  parent_state=""
  echo "[DEBUG] p460: gh issue view failed (rc=$p460_rc)" >&2
  if [ -n "$p460_err" ] && [ -s "$p460_err" ]; then
    head -3 "$p460_err" | sed 's/^/  p460 stderr: /' >&2
  fi
fi

if [ -n "$p460_err" ]; then
  rm -f "$p460_err"
  p460_err=""
fi

# Emit branch decision sentinel (machine-readable) for LLM routing.
if [ -z "$parent_state" ]; then
  echo "警告: 親 Issue #${parent_number} の state 取得に失敗しました。親の自動クローズ判定をスキップします。" >&2
  echo "[CONTEXT] P460_DECISION=skip_retrieval_failed"
elif [ "$parent_state" = "CLOSED" ]; then
  echo "[DEBUG] parent #${parent_number} already closed — skipping Phase 4.6 (close-side idempotency, extends AC-6 principle)"
  echo "[CONTEXT] P460_DECISION=skip_already_closed"
else
  echo "[CONTEXT] P460_DECISION=proceed_to_enumeration"
fi
```

**LLM routing rule** (Claude reads the `[CONTEXT] P460_DECISION=` sentinel from the bash block's stdout):

| `P460_DECISION` value | Next action |
|----------------------|-------------|
| `skip_routing_bug` | Sanity guard fired: `parent_number` is empty, literal, or non-numeric — Phase 4.6 was entered via a routing bug. Warning emitted to stderr. Skip the rest of Phase 4.6 and proceed to Phase 5. |
| `skip_retrieval_failed` | Warning already emitted to stderr. Skip the rest of Phase 4.6 (4.6.1–4.6.3) and proceed to Phase 5 (non-blocking). |
| `skip_already_closed` | Parent is already closed — skip the rest of Phase 4.6 (4.6.1–4.6.3) and proceed to Phase 5. This is the close-side idempotency no-op. |
| `proceed_to_enumeration` | Parent is open → proceed to 4.6.1. |

### 4.6.1 Enumerate Parent's Child Issues and Determine all_closed

Retrieve the parent's child Issues via **two methods (OR combination, Method A → Method B fallback)**, then determine whether every child is closed. All of this is done in a **single Bash tool invocation** to avoid shell state loss between calls.

**Design notes** (Issue #517 review fixes — cycles 1 + 2):

- **Method A uses the `trackedIssues` field (Tasklists API), NOT the Sub-Issues API**: `trackedIssues` resolves the parent→children relationship via GitHub's Tasklists feature (which parses the body `- [ ] #N` section) — this is intentional because the repo uses `/rite:issue:create-decompose` to write body tasklists. The newer GitHub Sub-Issues API uses a separate `subIssues` field and requires the `GraphQL-Features: sub_issues` header. This block does not call `subIssues` — the header is omitted to avoid misleading the reader. See `epic-detection.md` for the `trackedIssues` vs `subIssues` distinction.
- **Method A stderr is captured, not suppressed**: Previous `2>/dev/null` silently downgraded auth / network / permission errors to "empty result", which is the silent-skip anti-pattern Issue #513 aims to eliminate. Instead, stderr is captured to a tempfile and surfaced in debug logs on failure.
- **Method A → Method B fallback is an explicit bash conditional**: branches on `jq length` of Method A's result rather than relying on prose.
- **Method B uses a per-child loop, not an LLM-generated alias query**: deterministic, fully auditable, O(N) API calls for small N.
- **`set -uo pipefail` is enabled at the block top**: strict mode (fail on undefined vars + propagate pipeline failures) adds a defense layer against silent failures introduced by future edits. `-e` is omitted to allow explicit `|| fallback` paths without unintended aborts.
- **`mktemp` respects `$TMPDIR`**: using bare `mktemp` (no hardcoded `/tmp` path) honors macOS `/var/folders`, CI `$TMPDIR` overrides, and read-only-/tmp environments.

```bash
# ============================================================================
# Phase 4.6.1: Enumerate children + determine all_closed (single bash block)
# ============================================================================
set -uo pipefail

parent_number="{parent_number}"
owner="{owner}"
repo="{repo}"

children_json=""
method_a_err=""
_rite_close_p461_cleanup() {
  rm -f "${method_a_err:-}"
}
trap 'rc=$?; _rite_close_p461_cleanup; exit $rc' EXIT
trap '_rite_close_p461_cleanup; exit 130' INT
trap '_rite_close_p461_cleanup; exit 143' TERM
trap '_rite_close_p461_cleanup; exit 129' HUP

# --- Method A: Tasklists (trackedIssues) — parent→children via body tasklist ---
# stderr is captured to tempfile (NOT suppressed) so auth / network / GraphQL errors surface.
# Note: trackedIssues is the Tasklists feature (the body `- [ ] #N` parser); the `GraphQL-Features: sub_issues`
# header is NOT used here because it targets the separate `subIssues` field. See epic-detection.md.
if ! method_a_err=$(mktemp 2>/dev/null); then
  echo "[DEBUG] p461: mktemp failed for method_a_err — method_a stderr will not be captured" >&2
  method_a_err=""
fi

method_a_rc=0
if method_a_raw=$(gh api graphql -f query='
query($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) {
    issue(number: $number) {
      trackedIssues(first: 100) {
        nodes { number state }
      }
    }
  }
}' -f owner="$owner" -f repo="$repo" -F number="$parent_number" \
  --jq '[.data.repository.issue.trackedIssues.nodes[]? | {number: .number, state: .state}]' \
  2>"${method_a_err:-/dev/null}"); then
  children_json="$method_a_raw"
  method_a_count=$(printf '%s' "$children_json" | jq 'length' 2>/dev/null || echo 0)
  echo "[DEBUG] method_a succeeded: ${method_a_count} children via trackedIssues (Tasklists API)"
else
  method_a_rc=$?
  echo "[DEBUG] method_a failed (rc=$method_a_rc) — Tasklists API unavailable, will try Method B"
  if [ -n "$method_a_err" ] && [ -s "$method_a_err" ]; then
    head -3 "$method_a_err" | sed 's/^/  method_a stderr: /' >&2
  fi
  children_json=""
fi
if [ -n "$method_a_err" ]; then
  rm -f "$method_a_err"
  method_a_err=""
fi

# --- Method B: Parent body `## Sub-Issues` section parse (fallback) ---
# Note: "Sub-Issues" here is the literal heading text that /rite:issue:create-decompose writes
# into parent bodies. It is not the GitHub Sub-Issues feature. Method B only parses body markdown.
method_a_length=$(printf '%s' "${children_json:-[]}" | jq 'length' 2>/dev/null || echo 0)
if [ -z "$children_json" ] || [ "$method_a_length" -eq 0 ]; then
  echo "[DEBUG] falling back to Method B (parent body '## Sub-Issues' section parse)"
  parent_body=$(gh issue view "$parent_number" --json body --jq '.body' 2>/dev/null || echo "")
  if [ -z "$parent_body" ]; then
    echo "[DEBUG] method_b: failed to fetch parent body"
    children_json="[]"
  else
    # Extract child numbers from `- [ ] #N` / `- [x] #N` lines under a `## Sub-Issues` (exact) heading.
    # The `/^## Sub-Issues$/` anchor prevents false matches against headings like `## Sub-Issues-Extended`.
    child_numbers=$(awk '/^## Sub-Issues$/{flag=1;next} /^## /{flag=0} flag && /^- \[[ xX]\] #[0-9]+/{print}' <<< "$parent_body" | grep -oE '#[0-9]+' | tr -d '#')
    echo "[DEBUG] method_b child_numbers=${child_numbers:-none}"

    if [ -z "$child_numbers" ]; then
      children_json="[]"
    else
      # Deterministic per-child loop (O(N) API calls, N typically small).
      # Build JSON array by iterating and appending state per child.
      children_json="["
      first=1
      for n in $child_numbers; do
        child_state=$(gh issue view "$n" --json state --jq '.state' 2>/dev/null || echo "")
        if [ -z "$child_state" ]; then
          echo "[DEBUG] method_b: failed to fetch state for #$n (treating as OPEN to block auto-close — fail-closed)" >&2
          child_state="OPEN"
        fi
        if [ "$first" -eq 1 ]; then
          first=0
        else
          children_json+=","
        fi
        children_json+="{\"number\":$n,\"state\":\"$child_state\"}"
      done
      children_json+="]"
    fi
  fi
fi

# --- all_closed determination ---
# Empty array is treated as "cannot auto-close" (safe default — no children detected).
final_length=$(printf '%s' "$children_json" | jq 'length' 2>/dev/null || echo 0)
if [ "$final_length" -eq 0 ]; then
  all_closed="false"
  open_count="0"
  echo "[DEBUG] children_json is empty after both methods — cannot determine all_closed (skipping auto-close)"
else
  if ! all_closed=$(printf '%s' "$children_json" | jq -r 'all(.[]; .state == "CLOSED") | tostring' 2>/dev/null); then
    echo "[DEBUG] jq all_closed evaluation failed — treating as false (fail-closed)" >&2
    all_closed="false"
  fi
  if ! open_count=$(printf '%s' "$children_json" | jq -r '[.[] | select(.state != "CLOSED")] | length' 2>/dev/null); then
    echo "[DEBUG] jq open_count evaluation failed — defaulting to 0" >&2
    open_count="0"
  fi
fi
echo "all_closed=$all_closed open_count=$open_count children_total=$final_length"

# --- Branch decision sentinel for LLM routing ---
if [ "$final_length" -eq 0 ]; then
  echo "[CONTEXT] P461_DECISION=skip_empty_children"
elif [ "$all_closed" = "true" ]; then
  echo "[CONTEXT] P461_DECISION=proceed_to_confirmation"
else
  echo "[CONTEXT] P461_DECISION=skip_open_children; open_count=$open_count"
fi
```

**LLM routing rule** (Claude reads the `[CONTEXT] P461_DECISION=` sentinel from the bash block's stdout). Match by **prefix** (`skip_open_children` is emitted as `skip_open_children; open_count=N` — the `N` value is extracted from the payload and used to fill the `{open_count}` placeholder in the displayed message):

| `P461_DECISION` prefix | Payload | Next action |
|----------------------|---------|-------------|
| `skip_empty_children` | (none) | Display warning `親 Issue #{parent_number} の子 Issue 一覧が取得できませんでした。親の自動クローズをスキップします。` and proceed to Phase 5 (non-blocking, AC-5 spirit) |
| `skip_open_children` | `; open_count=N` | Display `親 Issue #{parent_number} にはまだ {open_count} 件の未完了子 Issue があります。親の自動クローズはスキップします。` (substitute `N` for `{open_count}`) and proceed to Phase 5 |
| `proceed_to_confirmation` | (none) | Proceed to 4.6.2 (User Confirmation) |

### 4.6.2 User Confirmation

Confirm via `AskUserQuestion`:

```
親 Issue #{parent_number} のすべての子 Issue が完了しました。親 Issue もクローズしますか？

オプション:
- 親 Issue をクローズする（推奨）
- 親 Issue を開いたまま終了
```

| Selection | Action |
|-----------|--------|
| クローズする | Proceed to 4.6.3 |
| 開いたまま終了 | `echo "[DEBUG] user declined parent auto-close for #{parent_number}"`. Proceed to Phase 5 |

### 4.6.3 Update Parent Projects Status to "Done" and Close

Skip the Status update if `github.projects.enabled: false` in `rite-config.yml`; still execute the Issue close in Step 4.

All 4 steps run in a **single bash block** to preserve intermediate state and to guarantee the final state-inconsistency summary (Step 5) is always emitted.

**Design notes** (Issue #517 review fixes — cycles 1 + 2):

- **All `gh` calls capture stderr to a tempfile (not `2>/dev/null`)**: every `gh api graphql` / `gh project field-list` / `gh project item-edit` / `gh issue close` failure surfaces its first 5 stderr lines via `head -5 | sed` so the user can diagnose auth / network / permission / rate-limit / field-id mismatch root causes. This is the same pattern Phase 4.6.1 Method A uses and the pattern Phase 4.6.0 was extended to match.
- **`set -uo pipefail`** enables strict mode against undefined variables and pipeline failure propagation. `-e` is omitted so explicit `|| fallback` handling remains intentional.
- **`mktemp` respects `$TMPDIR`** (no `/tmp` hardcode).
- **State inconsistency summary emits targeted recovery commands per case**: `success:field_lookup_failed` prints a `gh project field-list ...` diagnostic command (not a broken `--field-id ''` one-liner), `success:update_failed` prints the executable recovery one-liner with the actually-populated IDs, and `failed:projects_disabled` / `failed:not_registered` are classified as "Issue close failed, Status update not applicable" instead of being lumped into the catch-all "両方失敗" bucket.
- **Placeholder source assumption**: `{projects_enabled}`, `{project_number}`, `{owner}` are substituted by the LLM from `rite-config.yml` before executing this block. `{parent_number}` and `{issue_number}` are substituted from Phase 4.5.1 and Phase 0 respectively. If any placeholder is missing, the LLM must read `rite-config.yml` before substituting.

```bash
# ============================================================================
# Phase 4.6.3: Parent Projects Status → Done + Issue close (unified block)
# ============================================================================
set -uo pipefail

parent_number="{parent_number}"
owner="{owner}"
repo="{repo}"
projects_enabled="{projects_enabled}"  # "true" or "false" from rite-config.yml
project_number="{project_number}"      # integer from rite-config.yml
issue_number="{issue_number}"          # the child Issue that triggered this close

status_update_result="skipped"
issue_close_result="pending"
parent_item_id=""
parent_project_id=""
status_field_id=""
done_option_id=""

# --- stderr capture tempfiles (one per gh call) ---
p463_err_s1=""
p463_err_s2=""
p463_err_s3=""
p463_err_s4=""
_rite_close_p463_cleanup() {
  rm -f "${p463_err_s1:-}" "${p463_err_s2:-}" "${p463_err_s3:-}" "${p463_err_s4:-}"
}
trap 'rc=$?; _rite_close_p463_cleanup; exit $rc' EXIT
trap '_rite_close_p463_cleanup; exit 130' INT
trap '_rite_close_p463_cleanup; exit 143' TERM
trap '_rite_close_p463_cleanup; exit 129' HUP

_mktemp_or_warn() {
  local label="$1"
  local tmp
  if tmp=$(mktemp 2>/dev/null); then
    printf '%s' "$tmp"
  else
    echo "[DEBUG] p463 ${label}: mktemp failed — stderr from gh call will not be captured" >&2
    printf ''
  fi
}

# --- Step 1: Retrieve parent's project item ID and project GraphQL id ---
if [ "$projects_enabled" = "true" ]; then
  p463_err_s1=$(_mktemp_or_warn "Step 1")
  if project_items_json=$(gh api graphql -f query='
query($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) {
    issue(number: $number) {
      projectItems(first: 10) {
        nodes { id project { id number } }
      }
    }
  }
}' -f owner="$owner" -f repo="$repo" -F number="$parent_number" 2>"${p463_err_s1:-/dev/null}"); then
    :
  else
    p463_s1_rc=$?
    echo "[DEBUG] p463 Step 1: gh api graphql failed (rc=$p463_s1_rc)" >&2
    if [ -n "$p463_err_s1" ] && [ -s "$p463_err_s1" ]; then
      head -5 "$p463_err_s1" | sed 's/^/  p463 Step 1 stderr: /' >&2
    fi
    project_items_json=""
  fi

  if [ -n "$project_items_json" ]; then
    # Extract the node whose project.number matches {project_number}
    parent_item_id=$(printf '%s' "$project_items_json" \
      | jq -r --argjson pn "$project_number" '.data.repository.issue.projectItems.nodes[] | select(.project.number == $pn) | .id' 2>/dev/null || echo "")
    parent_project_id=$(printf '%s' "$project_items_json" \
      | jq -r --argjson pn "$project_number" '.data.repository.issue.projectItems.nodes[] | select(.project.number == $pn) | .project.id' 2>/dev/null || echo "")
  fi

  if [ -z "$parent_item_id" ] || [ -z "$parent_project_id" ]; then
    echo "警告: 親 Issue #${parent_number} は Project #${project_number} に登録されていません (または GraphQL 取得失敗)。Status 更新をスキップします。" >&2
    status_update_result="not_registered"
  else
    # --- Step 2: Retrieve Status field id and "Done" option id ---
    p463_err_s2=$(_mktemp_or_warn "Step 2")
    if field_list_json=$(gh project field-list "$project_number" --owner "$owner" --format json 2>"${p463_err_s2:-/dev/null}"); then
      :
    else
      p463_s2_rc=$?
      echo "[DEBUG] p463 Step 2: gh project field-list failed (rc=$p463_s2_rc)" >&2
      if [ -n "$p463_err_s2" ] && [ -s "$p463_err_s2" ]; then
        head -5 "$p463_err_s2" | sed 's/^/  p463 Step 2 stderr: /' >&2
      fi
      field_list_json=""
    fi

    if [ -n "$field_list_json" ]; then
      status_field_id=$(printf '%s' "$field_list_json" \
        | jq -r '.fields[] | select(.name == "Status") | .id' 2>/dev/null || echo "")
      done_option_id=$(printf '%s' "$field_list_json" \
        | jq -r '.fields[] | select(.name == "Status") | .options[] | select(.name == "Done") | .id' 2>/dev/null || echo "")
    fi

    if [ -z "$status_field_id" ] || [ -z "$done_option_id" ]; then
      echo "警告: Status フィールドまたは 'Done' オプションの取得に失敗しました (field_id='$status_field_id' done_option_id='$done_option_id')" >&2
      status_update_result="field_lookup_failed"
    else
      # --- Step 3: Update the Status ---
      p463_err_s3=$(_mktemp_or_warn "Step 3")
      if gh project item-edit --project-id "$parent_project_id" --id "$parent_item_id" --field-id "$status_field_id" --single-select-option-id "$done_option_id" >/dev/null 2>"${p463_err_s3:-/dev/null}"; then
        status_update_result="success"
        echo "親 Issue #${parent_number} の Status を 'Done' に更新しました"
      else
        p463_s3_rc=$?
        status_update_result="update_failed"
        echo "警告: 親 Issue #${parent_number} の Status 更新に失敗しました (rc=$p463_s3_rc)。後続の gh issue close は続行します。" >&2
        if [ -n "$p463_err_s3" ] && [ -s "$p463_err_s3" ]; then
          head -5 "$p463_err_s3" | sed 's/^/  p463 Step 3 stderr: /' >&2
        fi
      fi
    fi
  fi
else
  status_update_result="projects_disabled"
fi

# --- Step 4: Close the parent Issue ---
p463_err_s4=$(_mktemp_or_warn "Step 4")
if gh issue close "$parent_number" --comment "子 Issue がすべて完了したため、自動クローズします。(/rite:issue:close 経由、Issue #${issue_number} の close をトリガー)" >/dev/null 2>"${p463_err_s4:-/dev/null}"; then
  issue_close_result="success"
  echo "親 Issue #${parent_number} を自動クローズしました"
else
  p463_s4_rc=$?
  issue_close_result="failed"
  echo "警告: 親 Issue #${parent_number} のクローズに失敗しました (rc=$p463_s4_rc)。手動でクローズしてください: gh issue close ${parent_number}" >&2
  if [ -n "$p463_err_s4" ] && [ -s "$p463_err_s4" ]; then
    head -5 "$p463_err_s4" | sed 's/^/  p463 Step 4 stderr: /' >&2
  fi
fi

# --- Step 5: State inconsistency summary (MUST always emit — silent data corruption prevention) ---
# Parent Issue と Projects Status が別エンティティのため、片方成功 / 片方失敗の不整合を
# 必ずユーザーに可視化する。case 分類は 4 象限 + not_applicable の 5 クラスに細分化している。
echo ""
echo "=== 親 Issue #${parent_number} 処理結果 ==="
echo "  Issue close:   $issue_close_result"
echo "  Status update: $status_update_result"

case "${issue_close_result}:${status_update_result}" in
  "success:success"|"success:projects_disabled"|"success:not_registered")
    echo "  状態: 整合性 OK"
    ;;
  "success:update_failed")
    echo ""
    echo "⚠️  state 不整合: 親 Issue は CLOSED ですが Projects Status が Done に更新されていません。"
    echo "    復旧コマンド: gh project item-edit --project-id '$parent_project_id' --id '$parent_item_id' --field-id '$status_field_id' --single-select-option-id '$done_option_id'"
    echo "    またはブラウザで https://github.com/${owner}/${repo}/issues/${parent_number} の Projects サイドバーから手動更新" >&2
    ;;
  "success:field_lookup_failed")
    echo ""
    echo "⚠️  state 不整合: 親 Issue は CLOSED ですが Project の Status フィールド / 'Done' オプション ID の解決に失敗したため Status は未更新です。"
    echo "    診断コマンド: gh project field-list ${project_number} --owner ${owner} --format json"
    echo "    (出力から 'Status' field の id と 'Done' option の id を確認し、gh project item-edit に渡してください)"
    echo "    またはブラウザで https://github.com/${owner}/${repo}/issues/${parent_number} の Projects サイドバーから手動更新" >&2
    ;;
  "failed:success")
    echo ""
    echo "⚠️  state 不整合: Projects Status は Done ですが親 Issue が OPEN のままです。"
    echo "    復旧コマンド: gh issue close ${parent_number}" >&2
    ;;
  "failed:projects_disabled"|"failed:not_registered")
    echo ""
    echo "⚠️  親 Issue のクローズに失敗しました (Status 更新は対象外)。手動でクローズしてください: gh issue close ${parent_number}" >&2
    ;;
  "failed:"*)
    echo ""
    echo "⚠️  親 Issue の処理が両方失敗しました (Issue close / Status update)。手動対応が必要です: gh issue close ${parent_number}" >&2
    ;;
esac
```

Proceed to Phase 5 regardless of the outcome (non-blocking, AC-5 applied to close side — the inconsistency summary above makes silent failure impossible).

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
