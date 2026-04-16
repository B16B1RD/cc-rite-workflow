---
description: 中断した作業を再開
---

# /rite:resume

Resume an interrupted rite command from where it left off after a crash or interruption.

**Use cases:**
- Resuming work after a Claude Code crash
- Resuming work after a session disconnection
- Resuming manually interrupted work

---

Execute the following phases in order when this command is invoked.

## Arguments

| Argument | Description |
|----------|-------------|
| `[issue_number]` | Issue number (auto-detected from branch name if omitted) |

---

## Phase 1: Detect Work State

### 1.1 Determine Issue Number

#### From Arguments

If an issue number is provided as an argument, use that value.

#### Extract from Branch Name

If the argument is omitted, extract the issue number from the branch name:

```bash
git branch --show-current
```

**Extraction pattern**: `{type}/issue-{number}-{slug}`

Examples:
- `feat/issue-288-checkpoint-removal` → Issue #288
- `fix/issue-42-bug-fix` → Issue #42
- `refactor/issue-123-cleanup` → Issue #123

**If extraction fails:**

```
{i18n:resume_branch_extraction_failed}

{i18n:resume_current_branch}: {branch}

オプション:
- {i18n:resume_option_manual_number}
- {i18n:resume_option_new_work}
```

Stop here.

### 1.2 Retrieve Work Memory

**Local file first (SoT)**: Check local work memory file before falling back to Issue comment.

**Placeholder legend:**
- `{issue_number}`: Issue number (from argument or branch name extraction in Phase 1.1)
- `{owner}`, `{repo}`: Repository information (obtain via `gh repo view --json owner,name --jq '{owner: .owner.login, repo: .name}'`)
- `{plugin_root}`: Plugin root directory (resolve per [Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script))
- `{parent_issue_display}`: Read from `.rite-flow-state` via `jq -r '.parent_issue_number // 0'`. Display `#{N}` if non-zero, `なし` if zero or absent

#### 1.2.1 Local Work Memory Check

```bash
LOCAL_WM=".rite-work-memory/issue-{issue_number}.md"
```

If the file exists, validate it using the parser:

```bash
python3 {plugin_root}/hooks/work-memory-parse.py "$LOCAL_WM"
```

**If valid** (`status: "valid"`): Use the local file as the work memory source. Extract phase information from the frontmatter `data` field in the JSON output. Skip 1.2.2.

**If corrupt** (`status: "corrupt"`): Display warning and proceed to 1.2.2 (fallback to Issue comment).

```
⚠️ ローカル作業メモリが破損しています。
エラー: {errors}
Issue コメントからの復元を試みます...
```

**If file does not exist**: Proceed to 1.2.2 (fallback to Issue comment).

#### 1.2.2 Issue Comment Fallback

Search for work memory in Issue comments:

```bash
gh api repos/{owner}/{repo}/issues/{issue_number}/comments \
  --jq '.[] | select(.body | contains("📜 rite 作業メモリ"))'
```

**If found**: Restore to local file by converting the Issue comment format to schema v1:

```bash
mkdir -p .rite-work-memory
chmod 700 .rite-work-memory 2>/dev/null || true
```

**Step 1**: Extract phase information from the Issue comment (see 1.3).

**Step 2**: Create a local work memory file in schema v1 format. Use the following template, substituting values extracted from the Issue comment:

```bash
LOCAL_WM=".rite-work-memory/issue-{issue_number}.md"
TMP_WM="${LOCAL_WM}.tmp.$$"
cat > "$TMP_WM" << 'WMEOF'
# 📜 rite 作業メモリ

## Summary
---
schema_version: 1
WMEOF
{
  printf 'issue_number: %s\n' "{issue_number}"
  printf 'sync_revision: 1\n'
  printf 'sync_status: synced\n'
  printf 'source: resume\n'
  printf 'last_modified_at: "%s"\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  printf 'phase: "%s"\n' "{phase}"
  printf 'phase_detail: "%s"\n' "{phase_detail}"
  printf 'next_action: "%s"\n' "{next_action}"
  printf 'branch: "%s"\n' "{branch}"
  printf 'pr_number: %s\n' "{pr_number_or_null}"
  printf 'last_commit: "%s"\n' "{last_commit_or_empty}"
  printf 'loop_count: %s\n' "{loop_count_or_0}"
  printf -- '---\n'
  printf '\nRestored from Issue comment by /rite:resume.\n'
  printf '\n## Detail\n'
  printf 'Phase: %s\n' "{phase}"
  printf 'Branch: %s\n' "{branch}"
} >> "$TMP_WM"
chmod 600 "$TMP_WM" 2>/dev/null || true
mv "$TMP_WM" "$LOCAL_WM"
```

**Placeholder mapping** (Issue comment → schema v1):

| Issue Comment Field | Schema v1 Field | Default |
|---------------------|-----------------|---------|
| `- **フェーズ**: {value}` | `phase` | `"phase5_implementation"` |
| `- **フェーズ詳細**: {value}` | `phase_detail` | `"実装作業中"` |
| `- **ブランチ**: {value}` | `branch` | `git branch --show-current` |
| `### 次のステップ` → `- **コマンド**: {value}` | `next_action` | `""` |
| `### 関連 PR` → `- **番号**: #{value}` | `pr_number` | `null` |
| `### レビュー対応履歴` → `- **現在のループ回数**: {value}` | `loop_count` | `0` |
| (not available in Issue comment format) | `last_commit` | `""` |

**If work memory is not found (neither local nor Issue comment):**

```
{i18n:resume_work_memory_not_found}

{i18n:resume_possible_causes}:
- {i18n:resume_not_started_yet}
- {i18n:resume_memory_deleted}

{i18n:resume_actions}:
1. {i18n:resume_action_start_work}
2. {i18n:resume_action_check_list}
```

Stop here.

### 1.3 Extract Phase Information

Extract phase information from the work memory comment:

**Extraction patterns:**
- コマンド: `/\*\*コマンド\*\*: (.+)/`
- フェーズ: `/\*\*フェーズ\*\*: (.+)/`
- フェーズ詳細: `/\*\*フェーズ詳細\*\*: (.+)/`
- ブランチ: `/\*\*ブランチ\*\*: (.+)/`
- 最終更新: `/\*\*最終更新\*\*: (.+)/`

**Phase detail mapping:**

| フェーズ | フェーズ詳細 |
|---------|------------|
| `phase0` | Epic/Sub-Issues 判定 |
| `phase1` | 品質検証 |
| `phase2` | ブランチ作成・準備 |
| `phase3` | 実装計画生成 |
| `phase4` | 作業開始準備 |
| `phase5_implementation` | 実装作業中 |
| `phase5_lint` | 品質チェック中 |
| `phase5_post_lint` | チェックリスト確認中 |
| `phase5_pr` | PR 作成中 |
| `phase5_review` | レビュー中 |
| `phase5_post_review` | レビュー後処理 |
| `phase5_fix` | レビュー修正中 |
| `phase5_post_fix` | レビュー修正後処理 |
| `phase5_post_ready` | Ready 処理後 |
| `completed` | 完了 |

### 1.4 Validate Phase Information

Verify the following:

1. **Timestamp**: Check whether more than 24 hours have elapsed since the last update
2. **Issue state**: Confirm the Issue is still OPEN
3. **Branch existence**: Confirm the recorded branch exists

```bash
# Issue 状態確認
gh issue view {issue_number} --json state --jq '.state'

# ブランチ確認（出力の有無で判定。終了コードは常に 0 のため使用不可）
# DO NOT use exit code (&&, ||, $?) to determine branch existence.
branch_match=$(git branch --list "{branch}")
if [ -n "$branch_match" ]; then
  echo "BRANCH_EXISTS"
else
  echo "BRANCH_NOT_FOUND"
fi
```

**Timestamp validation:**

Claude reads the `最終更新` field from the work memory and calculates the difference from the current time. Parse the ISO 8601 formatted timestamp and determine whether 24 hours (86400 seconds) or more have elapsed.

**If more than 24 hours have elapsed:**

Confirm with `AskUserQuestion`:

```
{i18n:resume_work_memory_old}

オプション:
- {i18n:resume_option_continue}
- {i18n:resume_option_restart}
- {i18n:resume_option_cancel}
```

---

## Phase 2: Resume Confirmation

### 2.1 Display Interrupted State

Display the detected information:

```
{i18n:resume_interrupted_work_found}

{i18n:resume_command_label}: {command}
Issue: #{issue_number} - {issue_title}
{i18n:resume_branch_label}: {branch}
{i18n:resume_phase_label}: {phase}
{i18n:resume_phase_detail_label}: {phase_detail}
{i18n:resume_last_updated_label}: {timestamp}
親 Issue: {parent_issue_display}

{i18n:resume_confirm_resume}
```

### 2.2 User Confirmation

Confirm with `AskUserQuestion`:

```
オプション:
- {i18n:resume_option_resume_recommended}
- {i18n:resume_option_restart_issue}
- {i18n:resume_option_cancel}
```

**Transition after selection:**

| Selection | Subsequent action |
|-----------|-------------------|
| **再開する** | → Proceed to Phase 3 |
| **最初からやり直す** | Execute the corresponding command from Phase 0 |
| **キャンセル** | Exit |

**Specific steps for "最初からやり直す":**

```
Skill ツール呼び出し:
  skill: "rite:issue:start"
  args: "{issue_number}"
```

---

## Phase 3: Resume Work

### 3.0 Clear Compact State (recovering → normal)

Transition compact state to `normal` before resuming work. PostCompact hook normally handles
this automatically (#133), but `/rite:resume` serves as a fallback when PostCompact doesn't fire.

```bash
COMPACT_STATE=".rite-compact-state"
if [ -f "$COMPACT_STATE" ]; then
  COMPACT_VAL=$(jq -r '.compact_state // "normal"' "$COMPACT_STATE" 2>/dev/null) || COMPACT_VAL="unknown"
  if [ "$COMPACT_VAL" != "normal" ]; then
    TMP_COMPACT="${COMPACT_STATE}.tmp.$$"
    jq --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
      '.compact_state = "normal" | .compact_state_set_at = $ts' \
      "$COMPACT_STATE" > "$TMP_COMPACT" && mv "$TMP_COMPACT" "$COMPACT_STATE" || rm -f "$TMP_COMPACT"
  fi
fi
```

### 3.0.1 Restore Flow State Active Flag

Ensure `.rite-flow-state` has `active: true` so that the stop-guard hook blocks premature stops during the resumed workflow. Without this, the stop-guard sees `active: false` (or missing state) and allows Claude to stop mid-flow (root cause of Issue #79's resume-session variant).

```bash
STATE_FILE=".rite-flow-state"
if [ -f "$STATE_FILE" ]; then
  TMP_STATE="${STATE_FILE}.tmp.$$"
  _sid=$(cat .rite-session-id 2>/dev/null | tr -d '[:space:]') || _sid=""
  jq --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" --arg sid "$_sid" \
    '.active = true | .updated_at = $ts | .error_count = 0 | .session_id = $sid' \
    "$STATE_FILE" > "$TMP_STATE" && mv "$TMP_STATE" "$STATE_FILE" || rm -f "$TMP_STATE"
fi
```

**If `.rite-flow-state` does not exist**: The invoked command (e.g., `rite:issue:start`) will create it via `flow-state-update.sh create` in its own phases, so no action is needed here.

### 3.1 Switch Branch

If the current branch differs from the branch in work memory:

```bash
# 未コミットの変更を確認
git status --porcelain

# 変更がなければブランチ切り替え
git checkout {branch}
```

**If there are uncommitted changes:**

```
{i18n:resume_uncommitted_changes_warning}

{i18n:resume_current_branch}: {current_branch}
{i18n:resume_target_branch}: {work_memory_branch}

オプション:
- {i18n:resume_option_stash_and_switch}
- {i18n:resume_option_discard_and_switch}
- {i18n:resume_option_cancel}
```

### 3.1.1 Context Delta Display (Post-Resume Orientation)

After switching to the correct branch, display a summary of what has changed since the last work memory save to help the user quickly re-orient. This is useful after `/clear` + `/rite:resume` (context reset) or crash/disconnect recovery where conversation context was lost.

**Steps:**

1. **Retrieve last known commit** from work memory:
   - **Schema v1 (local file)**: Use the `last_commit` field from the frontmatter
   - **Issue comment fallback**: `last_commit` is not available in the Issue comment format (the `### コミット履歴` section contains multi-line log output, not a single hash). When restoring from Issue comment, skip Step 2 and proceed directly to Step 3
   - **When `last_commit` is empty or unavailable**: Skip Step 2

2. **Show delta since last save** (only when `last_commit` is available):
   ```bash
   # last_commit が取得できた場合のみ実行
   if [ -n "{last_commit}" ]; then
     echo "=== 前回保存時点からの変更 ==="
     git log --oneline {last_commit}..HEAD 2>/dev/null || echo "差分なし（コミット変更なし）"
     echo "=== 変更ファイル ==="
     git diff --name-only {last_commit}..HEAD 2>/dev/null || echo "なし"
   fi
   ```
   The `git log` output line count serves as the commit count, and the `git diff --name-only` output serves as the file list for the display format below.

3. **Display implementation plan progress**: Read the local work memory file (`.rite-work-memory/issue-{issue_number}.md`) with the Read tool. Extract the `## Detail` section and identify step entries matching the pattern `S{n}` with `✅` (completed) or `⬜` (pending). Display the first pending step as the resume point. If the local file is unavailable, read the Issue body checklist (`- [x]`/`- [ ]` items) as a fallback indicator of progress.

**Display format:**

```
📋 前回の保存時点からの状態:

コミット差分: {git log output line count} commits since last save
変更ファイル:
{git diff --name-only output}

実装計画の進捗:
| Step | 内容 | 状態 |
|------|------|------|
| S1 | {description} | ✅ |
| S2 | {description} | ⬜ ← 再開ポイント |
```

**When `last_commit` is unavailable** (Issue comment fallback): Omit the "コミット差分" and "変更ファイル" sections. Display only the implementation plan progress.

**When no delta is detected** (no commits since last save): Display "前回の保存時点から変更はありません。中断した地点から再開します。"

### 3.2 Command-Specific Resume Processing

Execute command-specific resume processing based on the `コマンド` and `フェーズ` values from the work memory. The mapping is defined in the tables below for each command type.

#### For rite:issue:start

| Interrupted phase | Resume action |
|-------------------|---------------|
| `phase0` | Resume from Phase 1 (Quality verification) |
| `phase1` | Resume from Phase 2 (Work preparation) |
| `phase2` | Resume from Phase 3 (Implementation plan generation) |
| `phase3` | Resume from Phase 4 (Work start guidance) |
| `phase4` | Resume from Phase 5 (End-to-end execution) |
| `phase5_implementation` | Continue implementation work |
| `phase5_lint` | Resume from lint |
| `phase5_post_lint` | Resume from checklist confirmation |
| `phase5_pr` | Resume from PR creation |
| `phase5_review` | Resume from review |
| `phase5_post_review` | Execute Phase 5.4.2 review result routing, then proceed to fix or completion |
| `phase5_fix` | Continue review fix work |
| `phase5_post_fix` | Execute Phase 5.4.5 fix result routing, then proceed to re-review or completion |
| `phase5_post_ready` | Resume from Phase 5.5.1 (Issue Status update to "In Review") |
| `completed` | Issue already completed — display status and offer next actions |

#### 3.2.1 Resume Execution

`/rite:resume` detects the phase value from work memory and invokes the corresponding command via the Skill tool:

```
Skill ツール呼び出し:
  skill: "rite:issue:start"
  args: "{issue_number}"
```

Each command checks work memory at the start of its own execution, and if present, resumes processing from the recorded phase.

**phase5_* sub-phase resume details:**

| Sub-phase | Specific resume action |
|-----------|----------------------|
| `phase5_implementation` | Refer to the implementation plan in work memory and continue from incomplete tasks |
| `phase5_lint` | Invoke `/rite:lint` via the Skill tool |
| `phase5_post_lint` | Execute Phase 5.2.1 checklist confirmation, then proceed to PR creation |
| `phase5_pr` | Invoke `/rite:pr:create` via the Skill tool |
| `phase5_review` | Invoke `/rite:pr:review` via the Skill tool |
| `phase5_post_review` | Execute Phase 5.4.2 review result routing (check review pattern in work memory context) |
| `phase5_fix` | Invoke `/rite:pr:fix` via the Skill tool |
| `phase5_post_fix` | Invoke `/rite:pr:fix` via the Skill tool (will detect completion and output pattern) |
| `phase5_post_ready` | Execute Phase 5.5.1 Issue Status update to "In Review", then proceed to Phase 5.5.2 metrics and Phase 5.6 completion |

#### For rite:issue:create

| Interrupted phase | Resume action |
|-------------------|---------------|
| `phase0` | Resume from Phase 0 (Task decomposition decision) |
| `phase0_decompose` | Resume from Phase 0 decomposition processing |
| `phase1` | Resume from Phase 1 (Issue creation) |
| `phase2` | Resume from Phase 2 (Projects addition) |

#### For rite:pr:create

| Interrupted phase | Resume action |
|-------------------|---------------|
| `phase1` | Resume from Phase 1 (Current state check) |
| `phase2` | Resume from Phase 2 (Quality check) |
| `phase3` | Resume from Phase 3 (PR creation) |
| `phase4` | Resume from Phase 4 (Post-processing) |

#### For rite:pr:review

| Interrupted phase | Resume action |
|-------------------|---------------|
| `phase1` | Resume from Phase 1 (Preparation) |
| `phase2` | Resume from Phase 2 (Reviewer selection) |
| `phase3` | Resume from Phase 3 (Reviewer count decision) |
| `phase4` | Resume from Phase 4 (Parallel review execution) |
| `phase5` | Resume from Phase 5 (Result verification & integration) |
| `phase6` | Resume from Phase 6 (Result output) |

### 3.3 Resume Completion Message

```
{i18n:resume_work_resumed}

Issue: #{issue_number} - {issue_title}
{i18n:resume_branch_label}: {branch}
{i18n:resume_resumed_phase}: {phase} ({phase_detail})

{i18n:resume_continue_work}
```

---

## Error Handling

See [Common Error Handling](../references/common-error-handling.md) for shared patterns (Not Found, Permission, Network errors).

| Error | Recovery |
|-------|----------|
| When Phase Information Is Not Found | See [common patterns](../references/common-error-handling.md) |
| When Issue Is Not Found | See [common patterns](../references/common-error-handling.md) |
| When Branch Is Not Found | See [common patterns](../references/common-error-handling.md) |
| When PR Already Exists | See error output for details |
| When Work Memory Is Corrupted | See error output for details |
| When Multiple Work Branches Exist | See error output for details |
| When Merge Conflicts Occur | See error output for details |
| When Stash Restore Fails | See error output for details |
