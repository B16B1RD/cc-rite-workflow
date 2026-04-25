---
description: PR を Ready for review に変更
---

# /rite:pr:ready

## Contract
**Input**: PR number (or auto-detected), `.rite-flow-state` (optional, e2e flow)
**Output**: `[ready:completed]` | `[ready:error]`

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

> **⚠️ MANDATORY**: This `AskUserQuestion` confirmation MUST be executed even within the `/rite:issue:start` end-to-end flow. Do NOT skip this step for context optimization or any other reason. The user must always confirm before changing the PR to Ready for review. Identity: [workflow-identity.md](../../skills/rite-workflow/references/workflow-identity.md) の `no_step_omission` / `no_context_introspection` principle 参照。

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
bash {plugin_root}/hooks/flow-state-update.sh patch \
  --phase "phase5_ready_error" \
  --active true \
  --next "rite:pr:ready failed. Ask user: retry / skip to Phase 5.6 / terminate." \
  --if-exists
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
  bash {plugin_root}/hooks/local-wm-update.sh 2>/dev/null || true
```

**On lock failure**: Log a warning and continue — local work memory update is best-effort.

**Step 2: Sync to Issue comment (backup)** at phase transition (per C3 backup sync rule).

```bash
# ⚠️ このブロック全体を単一の Bash ツール呼び出しで実行すること
# ⚠️ 置換型パターン（Python で既存行を正規表現置換）: backup sync は non-blocking のため
#    エラー時は WARNING を出力してスキップする（exit 1 しない）。
#    追記型パターン（printf + cat >> heredoc）の exit 1 方式とは意図的に異なる。
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
# lambda を使用: re.sub の置換文字列メタ文字（\1 等）の誤解釈を防止
body = re.sub(r"^(- \*\*最終更新\*\*: ).*", lambda m: m.group(1) + timestamp, body, count=1, flags=re.MULTILINE)
body = re.sub(r"^(- \*\*フェーズ\*\*: ).*", lambda m: m.group(1) + phase, body, count=1, flags=re.MULTILINE)
body = re.sub(r"^(- \*\*フェーズ詳細\*\*: ).*", lambda m: m.group(1) + phase_detail, body, count=1, flags=re.MULTILINE)
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

### 4.2 Update Status via Shared Script

> **Source of truth**: This phase delegates to `plugins/rite/scripts/projects-status-update.sh` — the same shared script used by `commands/issue/start.md` Phase 2.4 / 5.5.1 / 5.7.2 (Issue #496 / PR #531). Direct inline `gh api graphql` (Organization-aware) + `gh project item-edit` calls have been removed because the multi-stage inline pipeline produced silent skips when LLM attention was lost between substeps, leaving Issue Status at "In Progress" instead of advancing to "In Review" (Issue #658 — observed on #652 stuck at "In Progress" through subsequent cleanup).

Skip Phase 4.2 if `github.projects.enabled: false` in `rite-config.yml` or if no related Issue was identified in Phase 4.1, and proceed to Phase 4.6. Otherwise, invoke the shared script to transition the Issue Status to **In Review**:

```bash
bash {plugin_root}/scripts/projects-status-update.sh "$(jq -n \
  --argjson issue {issue_number} \
  --arg owner "{owner}" \
  --arg repo "{repo}" \
  --argjson project_number {project_number} \
  --arg status "In Review" \
  --argjson auto_add false \
  --argjson non_blocking true \
  '{issue_number:$issue, owner:$owner, repo:$repo, project_number:$project_number, status_name:$status, auto_add:$auto_add, non_blocking:$non_blocking}')"
```

`auto_add: false` because by ready time the Issue is already registered in the Project (start.md Phase 2.4 auto-added it if missing). The script internally executes the GraphQL `projectItems` query → `gh project field-list` → `gh project item-edit` triple in a single fail-fast pipeline. The query uses GraphQL の `repository(owner:)` 形式 (User / Organization どちらの owner でも透過的に解決されるため、client-side type detection は不要)。旧 ready.md inline 経路は `user(login:)` を直接 query して Organization fallback を行う実装だったが、`repository(owner:)` への delegation でこの分岐自体が不要になった。

#### 4.2.1 Result Handling

Inspect the script's stdout JSON and route by `.result`:

| `.result` | User-visible action |
|-----------|--------------------|
| `"updated"` | Display `Projects Status を "In Review" に更新しました` and proceed to Phase 4.6 |
| `"skipped_not_in_project"` | Display `警告: Issue #{issue_number} は Project に登録されていません。Status 更新をスキップします` and proceed to Phase 4.6 |
| `"failed"` | Display each `.warnings[]` entry to stderr, then display `警告: Projects Status の "In Review" への更新に失敗しました。手動で更新する場合: GitHub Projects 画面で Issue #{issue_number} の Status を "In Review" に変更するか、または gh project item-edit --project-id <project_id> --id <item_id> --field-id <status_field_id> --single-select-option-id <in_review_option_id> を実行してください。` and proceed to Phase 4.6 |

**All result branches are non-blocking** — the ready-for-review transition is already complete (Phase 3 `gh pr ready` succeeded); a Status update issue MUST NOT abort the workflow.

> **Bash 実装 minimal skeleton (delegate-only 経路の標準形)**:
>
> ```bash
> status_json=$(bash {plugin_root}/scripts/projects-status-update.sh "$status_json_args") || status_json=""
> status_result=$(printf '%s' "$status_json" | jq -r '.result // "failed"' 2>/dev/null)
> status_warning_lines=$(printf '%s' "$status_json" | jq -r '.warnings[]?' 2>/dev/null)
> case "$status_result" in
>   updated)
>     echo "Projects Status を \"In Review\" に更新しました" ;;
>   skipped_not_in_project)
>     echo "警告: Issue #{issue_number} は Project に登録されていません。Status 更新をスキップします" >&2 ;;
>   failed|*)
>     [ -n "$status_warning_lines" ] && printf '%s\n' "$status_warning_lines" | sed 's/^/  warning: /' >&2
>     echo "警告: Projects Status の \"In Review\" への更新に失敗しました。手動回復: gh project item-edit ..." >&2 ;;
> esac
> ```
>
> 上記が delegate-only 経路 (close + summary 不要) の標準パターン。`.warnings[]` の stderr surface 実装を忘れると AC-2 (失敗時 warning surface) が LLM 実行揺らぎで silent skip するため必ず含めること。
>
> **完全形 (state machine + signal-specific trap + tempfile + Step 3 inconsistency summary)** が必要な場合 (parent Issue close と Status update の片方失敗を可視化する unified block) は `commands/issue/close.md` Phase 4.6.3 を参照すること。

> **Underlying API documentation**: See [projects-integration.md §2.4](../../references/projects-integration.md#24-github-projects-status-update) for the API-level details (GraphQL query, field-list, item-edit) that the script encapsulates.

### 4.6 Defense-in-Depth: State Update Before Output (End-to-End Flow)

Before outputting the result pattern (`[ready:completed]`) or skipping output, update `.rite-flow-state` to reflect the post-ready phase (defense-in-depth, fixes #17). This prevents intermittent flow interruptions when the fork context returns to the caller — even if the LLM churns after fork return and the system forcibly terminates the turn (bypassing the Stop hook), the state file will already contain the correct `next_action` for resumption.

**Condition**: Execute only when `.rite-flow-state` exists (indicating e2e flow). Skip if the file does not exist (standalone execution).

**State update**:

| Result | Phase | Phase Detail | Next Action |
|--------|-------|-------------|-------------|
| `[ready:completed]` | `phase5_post_ready` | `Ready処理完了` | `rite:pr:ready completed. Proceed to start.md Phase 5.5.1 (Status update to In Review), then Phase 5.5.2 (metrics), then Phase 5.6 (completion report). Do NOT stop.` |

```bash
bash {plugin_root}/hooks/flow-state-update.sh patch \
  --phase "phase5_post_ready" \
  --active true \
  --next "rite:pr:ready completed. Proceed to start.md Phase 5.5.1 (Status update to In Review), then Phase 5.5.2 (metrics), then Phase 5.6 (completion report). Do NOT stop." \
  --if-exists
```

**Note on `error_count`**: `flow-state-update.sh` patch mode resets `error_count` to 0 on every phase transition (since #294). This prevents stale circuit breaker counts from one phase from poisoning subsequent phases.

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
  bash {plugin_root}/hooks/local-wm-update.sh 2>/dev/null || true
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
