---
description: PR を Ready for review に変更
---

# /rite:pr:ready

Change PR to Ready for review and update the related Issue's Status

> **Important (responsibility for flow continuation)**: When executed within the end-to-end flow, this Skill outputs a machine-readable output pattern (`[ready:completed]` or `[ready:error]`) and **returns control to the caller** (`/rite:issue:start`). The caller determines the next action based on this output pattern.

---

When this command is executed, run the following phases in order.

## Arguments

| Argument | Description |
|------|------|
| `[pr_number]` | PR number (defaults to the PR for the current branch if omitted) |

---

## Placeholder Legend

| Placeholder | Description | How to Obtain |
|---------------|------|----------|
| `{plugin_root}` | Absolute path to the plugin root directory. Works for both local dev and marketplace installs | [Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script) |

---

## Phase 0: Load Work Memory (End-to-End Flow Only)

> **This phase is only executed within the `/rite:issue:start` end-to-end flow. Skip when running standalone.**

> **Warning**: Work memory is published as Issue comments. In public repositories, third parties can view it. Do not record sensitive information (credentials, personal data, internal URLs, etc.) in work memory.

### 0.1 End-to-End Flow Detection

| Condition | Result | Action |
|------|---------|------|
| Conversation history has rich context from `/rite:pr:review` | Within end-to-end flow | PR number can be obtained from conversation context |
| `/rite:pr:ready` was executed standalone | Standalone execution | Obtain from argument or current branch PR |

### 0.2 Retrieve Information from Work Memory

If determined to be within the end-to-end flow, extract the Issue number from the branch name and load work memory from local file (SoT):

```bash
# 1. 現在のブランチから Issue 番号を抽出
issue_number=$(git branch --show-current | grep -oE 'issue-[0-9]+' | grep -oE '[0-9]+')
```

**Local work memory (SoT)**: Read `.rite-work-memory/issue-{issue_number}.md` with the Read tool.

**Fallback (local file missing/corrupt)**:

```bash
# リポジトリ情報を取得
gh repo view --json owner,name --jq '{owner: .owner.login, repo: .name}'

# Issue comment から作業メモリを読み込む（backup）
gh api repos/{owner}/{repo}/issues/{issue_number}/comments \
  --jq '[.[] | select(.body | contains("📜 rite 作業メモリ"))] | last | .body'
```

**Fields to extract:**

| Field | Extraction Pattern | Purpose |
|-----------|-------------|------|
| Issue number | `- **Issue**: #(\d+)` | Identify the related Issue |
| PR number | `- **番号**: #(\d+)` | Identify the target PR |
| Branch name | `- **ブランチ**: (.+)` | For verification |

**When PR number exists in work memory:**

Even if the argument is omitted, retrieve and use the PR number from work memory.

---

## Phase 1: Identify the PR

### 1.1 Check Arguments

If a PR number is specified as an argument, use that PR.

### 1.2 Identify PR from Current Branch

If no argument is provided, search for a PR from the current branch:

```bash
git branch --show-current
```

**If on main/master branch:**

```
エラー: 現在 {branch} ブランチにいます

Ready for review にする PR を指定してください:
/rite:pr:ready <PR番号>
```

End processing.

### 1.3 Retrieve PR Information

Retrieve the PR associated with the current branch:

```bash
gh pr view --json number,title,state,isDraft,url,headRefName,body
```

**If PR is not found:**

```
エラー: 現在のブランチに関連する PR が見つかりません

現在のブランチ: {branch}

対処:
1. `/rite:pr:create` で PR を作成
2. または PR 番号を直接指定: `/rite:pr:ready <PR番号>`
```

End processing.

### 1.4 Check PR State

**If already Ready for review:**

```
PR #{number} は既に Ready for review です

URL: {pr_url}
```

End processing.

**If already merged or closed:**

```
エラー: PR #{number} は既に{state}されています

状態: {state}
```

End processing.

---

## Phase 2: Execution Confirmation

### 2.1 Confirm with User

Confirm using `AskUserQuestion`:

```
PR #{number} を Ready for review に変更します。

タイトル: {title}
URL: {pr_url}

よろしいですか？

オプション:
- はい、変更する（推奨）: Ready for review に変更し、Status を更新します
- キャンセル: 処理を中止します
```

**If "Cancel" is selected:**

```
処理を中止しました。
```

End processing.

---

## Phase 3: Change to Ready for Review

### 3.1 Execute gh pr ready

```bash
gh pr ready {pr_number}
```

**On success:**

Proceed to the next phase.

**On failure:**

```
エラー: PR #{number} を Ready for review に変更できませんでした

考えられる原因:
- 権限不足
- ネットワークエラー
- PR が既にクローズされている

対処:
1. `gh pr view {number}` で PR の状態を確認
2. GitHub Web UI から直接変更を試す
```

**In e2e flow**: If `.rite-flow-state` exists, update the state file and output `[ready:error]` before ending to signal the failure to the caller (`start.md` Phase 5.5):

```bash
if [ -f ".rite-flow-state" ]; then
  TMP_STATE=".rite-flow-state.tmp.$$"
  jq --arg phase "phase5_ready_error" \
     --arg ts "$(date -u +'%Y-%m-%dT%H:%M:%S+00:00')" \
     --arg next "rite:pr:ready failed. Ask user: retry / skip to Phase 5.6 / terminate." \
     '.phase = $phase | .updated_at = $ts | .next_action = $next' \
     ".rite-flow-state" > "$TMP_STATE" && mv "$TMP_STATE" ".rite-flow-state" || rm -f "$TMP_STATE"
fi
```

```
[ready:error]
```

End processing.

---

### 3.2 Update Local Work Memory

After `gh pr ready` succeeds, update local work memory (SoT):

```bash
WM_SOURCE="ready" \
  WM_PHASE="phase5_ready" \
  WM_PHASE_DETAIL="Ready for review に変更完了" \
  WM_NEXT_ACTION="レビュー待ち" \
  WM_BODY_TEXT="PR marked as ready for review." \
  WM_ISSUE_NUMBER="{issue_number}" \
  bash plugins/rite/hooks/local-wm-update.sh 2>/dev/null || true
```

**On lock failure**: Log a warning and continue — local work memory update is best-effort.

**Step 2: Sync to Issue comment (backup)** at phase transition (per C3 backup sync rule).

```bash
# ⚠️ このブロック全体を単一の Bash ツール呼び出しで実行すること
comment_data=$(gh api repos/{owner}/{repo}/issues/{issue_number}/comments \
  --jq '[.[] | select(.body | contains("📜 rite 作業メモリ"))] | last | {id: .id, body: .body}')
comment_id=$(echo "$comment_data" | jq -r '.id // empty')
current_body=$(echo "$comment_data" | jq -r '.body // empty')

if [ -z "$comment_id" ]; then
  echo "WARNING: Work memory comment not found. Skipping backup sync." >&2
else
  backup_file="/tmp/rite-wm-backup-${issue_number}-$(date +%s).md"
  printf '%s' "$current_body" > "$backup_file"
  original_length=$(printf '%s' "$current_body" | wc -c)

  tmpfile=$(mktemp)
  body_tmp=$(mktemp)
  trap 'rm -f "$tmpfile" "$body_tmp"' EXIT
  printf '%s' "$current_body" > "$body_tmp"
  python3 -c '
import sys, re
body_path, out_path = sys.argv[1], sys.argv[2]
phase, phase_detail, timestamp = sys.argv[3], sys.argv[4], sys.argv[5]
with open(body_path, "r") as f:
    body = f.read()
body = re.sub(r"^(- \*\*最終更新\*\*: ).*", rf"\g<1>{timestamp}", body, count=1, flags=re.MULTILINE)
body = re.sub(r"^(- \*\*フェーズ\*\*: ).*", rf"\g<1>{phase}", body, count=1, flags=re.MULTILINE)
body = re.sub(r"^(- \*\*フェーズ詳細\*\*: ).*", rf"\g<1>{phase_detail}", body, count=1, flags=re.MULTILINE)
with open(out_path, "w") as f:
    f.write(body)
' "$body_tmp" "$tmpfile" "phase5_ready" "Ready for review に変更完了" "$(date -u +'%Y-%m-%dT%H:%M:%S+00:00')"

  # Safety checks before PATCH
  if [ ! -s "$tmpfile" ] || [[ "$(wc -c < "$tmpfile")" -lt 10 ]]; then
    echo "WARNING: Updated body is empty. Skipping backup sync. Backup: $backup_file" >&2
  elif grep -q '📜 rite 作業メモリ' "$tmpfile"; then
    updated_length=$(wc -c < "$tmpfile")
    if [[ "${updated_length:-0}" -lt $(( ${original_length:-1} / 2 )) ]]; then
      echo "WARNING: Updated body < 50% of original. Skipping. Backup: $backup_file" >&2
    else
      jq -n --rawfile body "$tmpfile" '{"body": $body}' | \
        gh api repos/{owner}/{repo}/issues/comments/"$comment_id" -X PATCH --input - > /dev/null 2>&1 || \
        echo "WARNING: Issue comment backup sync failed (non-blocking)." >&2
    fi
  else
    echo "WARNING: Updated body missing header. Skipping. Backup: $backup_file" >&2
  fi
fi
```

---

## Phase 4: Update Issue Status

> **Note**: In the end-to-end flow (`/rite:issue:start`), `start.md` Phase 5.5.1 also performs this Status update as defense-in-depth. This Phase 4 remains essential for standalone `/rite:pr:ready` execution.

**Critical**: Do NOT skip this phase. After `gh pr ready` succeeds in Phase 3, this Status update MUST be executed before proceeding to Phase 5.

### 4.1 Identify Related Issue

Extract the related Issue from the PR body:

```bash
gh pr view {pr_number} --json body,headRefName
```

**Extraction patterns:**
1. `Closes #XX`, `Fixes #XX`, `Resolves #XX` in the PR body
2. `issue-XX` pattern in the branch name

### 4.2 Retrieve Project Configuration

Retrieve Project information from `rite-config.yml`:

```yaml
github:
  projects:
    project_number: {number}
    owner: "{owner}"
```

### 4.3 Retrieve Issue's Project Item Information

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
        }
      }
    }
  }
}' -f owner="{owner}" -f repo="{repo}" -F number={issue_number}
```

### 4.4 Retrieve the Status Field

**Important**: The option ID (`{in_review_option_id}`) must always be fetched from the API. Only field IDs can be specified via `field_ids`; option IDs for each status (Done, In Progress, In Review, etc.) are not included.

**Retrieving the field ID:**

If `github.projects.field_ids.status` is set in `rite-config.yml`, use that value directly as `{status_field_id}` (skip extracting the field ID from the API result):

Replace the configured value with your actual project ID (see CONFIGURATION.md for how to obtain it):

```yaml
github:
  projects:
    field_ids:
      status: "PVTSSF_your-status-field-id"
```

**Retrieving the option ID (always required):**

**Note**: This file (ready.md) uses GraphQL instead of `gh project field-list`.

**Differences from other command files (close.md, start.md, cleanup.md):**
- Other files: Use the `gh project field-list` CLI command (adequate when retrieving field lists only)
- This file: Uses GraphQL (an intentional design decision for the following reasons)

**Reasons for using GraphQL:**
- Both field ID and option ID can be fetched in a single query
- Provides a consistent method for fetching option IDs whether `field_ids` is configured or not
- Easier to handle complex cases including Organization/User detection

#### Organization Detection (Before Executing the GraphQL Query)

Before executing the GraphQL query, determine whether the owner is a User or Organization:

```bash
gh api users/{owner} --jq '.type'
```

| Result | Action |
|------|------|
| `"Organization"` | Change `user(login: $owner)` to `organization(login: $owner)` in the query |
| `"User"` | Use the query as-is |

#### Execute the GraphQL Query

```bash
gh api graphql -f query='
query($owner: String!, $projectNumber: Int!) {
  user(login: $owner) {
    projectV2(number: $projectNumber) {
      id
      fields(first: 20) {
        nodes {
          ... on ProjectV2SingleSelectField {
            id
            name
            options {
              id
              name
            }
          }
        }
      }
    }
  }
}' -f owner="{owner}" -F projectNumber={project_number}
```

**Note**: The above is the query for User. For Organization, replace `user` with `organization`.

**Retrieval logic:**
1. Execute the API (always required for obtaining option IDs)
2. Check `github.projects.field_ids.status` in `rite-config.yml`
3. Determine the field ID:
   - If configured: Use the configured value as `{status_field_id}`
   - If not configured: Obtain `{status_field_id}` from the GraphQL result
4. Option ID: Obtain `{in_review_option_id}` from the GraphQL result

### 4.5 Update Status to "In Review"

```bash
gh project item-edit --project-id {project_id} --id {item_id} --field-id {status_field_id} --single-select-option-id {in_review_option_id}
```

**If Project is not configured:**

```
警告: GitHub Projects が設定されていません
Status の更新をスキップします
```

### 4.6 Defense-in-Depth: State Update Before Output (End-to-End Flow)

Before outputting the result pattern (`[ready:completed]`) or skipping output, update `.rite-flow-state` to reflect the post-ready phase (defense-in-depth, fixes #17). This prevents intermittent flow interruptions when the fork context returns to the caller — even if the LLM churns after fork return and the system forcibly terminates the turn (bypassing the Stop hook), the state file will already contain the correct `next_action` for resumption.

**Condition**: Execute only when `.rite-flow-state` exists (indicating e2e flow). Skip if the file does not exist (standalone execution).

**State update**:

| Result | Phase | Phase Detail | Next Action |
|--------|-------|-------------|-------------|
| `[ready:completed]` | `phase5_post_ready` | `Ready処理完了` | `rite:pr:ready completed. Proceed to start.md Phase 5.5.1 (Status update to In Review), then Phase 5.5.2 (metrics), then Phase 5.6 (completion report). Do NOT stop.` |

```bash
if [ -f ".rite-flow-state" ]; then
  TMP_STATE=".rite-flow-state.tmp.$$"
  jq --arg phase "phase5_post_ready" \
     --arg ts "$(date -u +'%Y-%m-%dT%H:%M:%S+00:00')" \
     --arg next "rite:pr:ready completed. Proceed to start.md Phase 5.5.1 (Status update to In Review), then Phase 5.5.2 (metrics), then Phase 5.6 (completion report). Do NOT stop." \
     '.phase = $phase | .updated_at = $ts | .next_action = $next' \
     ".rite-flow-state" > "$TMP_STATE" && mv "$TMP_STATE" ".rite-flow-state" || rm -f "$TMP_STATE"
fi
```

**Note on `error_count`**: This patch-style `jq` command intentionally preserves `error_count` from the existing `.rite-flow-state` (consistent with `lint.md` Phase 4.0, `review.md` Phase 8.0, and `fix.md` Phase 8.1). The count is effectively reset when `/rite:issue:start` writes a new complete object via `jq -n` at the next phase transition.

**Also sync to local work memory** (`.rite-work-memory/issue-{n}.md`) when `.rite-flow-state` exists:

```bash
WM_SOURCE="ready" \
  WM_PHASE="phase5_post_ready" \
  WM_PHASE_DETAIL="Ready処理完了" \
  WM_NEXT_ACTION="start.md Phase 5.5.1 Status 更新 → 5.5.2 メトリクス → 5.6 完了レポートを実行" \
  WM_BODY_TEXT="Post-ready phase sync." \
  WM_REQUIRE_FLOW_STATE="true" \
  WM_READ_FROM_FLOW_STATE="true" \
  WM_ISSUE_NUMBER="{issue_number}" \
  bash plugins/rite/hooks/local-wm-update.sh 2>/dev/null || true
```

**On lock failure**: Log a warning and continue — local work memory update is best-effort.

---

## Phase 5: Completion Report

### 5.0 Determine the Caller

Determine the caller from the conversation context:

| Condition | Result | Action |
|------|---------|---------------------|
| Called via Skill chain from `/rite:issue:start` | Within end-to-end flow | **Skip completion report** — return control to `start.md` (Phase 5.6 handles the report) |
| Called from `/rite:pr:review` | Within end-to-end flow | **Skip completion report** — return control to `start.md` (Phase 5.6 handles the report) |
| `/rite:pr:ready` executed standalone | Standalone complete | Output Phase 5.1.2 format |

**Detection method:**

Check the conversation history and determine "within end-to-end flow" if any of the following apply:

1. `/rite:issue:start` was executed in the conversation
2. A `/rite:pr:review` -> `/rite:pr:ready` call chain is confirmed in the conversation
3. `rite:pr:ready` was invoked via the Skill tool (not as a standalone user command)

### 5.1 Output the Completion Report

#### 5.1.1 End-to-End Flow (Skip Completion Report, Output Signal)

When called within the end-to-end flow (detected in Phase 5.0), **do NOT output any completion report**. The completion report is the responsibility of `start.md` Phase 5.6 — outputting it here causes duplicate reports.

**Instead, output the following machine-readable signal** to indicate successful completion to the caller:

```
[ready:completed]
```

This pattern is **mandatory** in e2e flow. It allows `start.md` Phase 5.5 to detect that `rite:pr:ready` has completed successfully and immediately proceed to Phase 5.5.1 (Status update), 5.5.2 (metrics), and 5.6 (completion report). Without this signal, the caller may incorrectly interpret the lack of output as task completion and stop before Phase 5.6.

No template loading, no inline format, no completion table — only the `[ready:completed]` pattern.

#### 5.1.2 Standalone Execution

When `/rite:pr:ready` is executed standalone, use the following simple format:

```
PR #{number} を Ready for review に変更しました

タイトル: {title}
URL: {pr_url}

関連 Issue: #{issue_number}
Status: In Review

次のステップ:
1. レビュアーにレビューを依頼
2. レビューコメントに対応
3. PR マージ後、Issue は自動クローズされます
```

**If no related Issue exists:**

```
PR #{number} を Ready for review に変更しました

タイトル: {title}
URL: {pr_url}

次のステップ:
1. レビュアーにレビューを依頼
2. レビューコメントに対応
3. PR をマージ
```

---

## Error Handling

See [Common Error Handling](../../references/common-error-handling.md) for shared patterns (Not Found, Permission, Network errors).

| Error | Recovery |
|-------|----------|
| PR Not Found | See [common patterns](../../references/common-error-handling.md) |
| Permission Error | See [common patterns](../../references/common-error-handling.md) |
| Network Error | See [common patterns](../../references/common-error-handling.md) |
| Issue Not Found | See [common patterns](../../references/common-error-handling.md) |
