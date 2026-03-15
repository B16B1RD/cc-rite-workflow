---
description: Sprint 内の Todo Issue を並列チーム実行
---

# /rite:sprint:team-execute

Orchestrate parallel execution of Todo Issues within a Sprint using Agent Teams and Git Worktrees. Creates a team with specialized teammates, each working in an independent worktree directory.

**Flow:** Identify Sprint → Retrieve Todo Issues → Worktree creation per Issue → Teammate spawn (via Task tool) → Parallel implementation → Team Lead git operations (commit/push/PR) → Review-fix loop → Cleanup.

**Key principle**: Team Lead manages ALL git operations. Teammates use only Read/Edit/Write/Glob/Grep/Bash (non-git).

> **Background**: See MEMORY.md "Agent Teams 教訓" — shared working directory causes `git checkout` interference between agents. This command uses `git worktree` to provide independent directories per agent.

---

Execute phases sequentially.

## Arguments

| Argument | Description |
|----------|-------------|
| `[sprint]` | Target sprint identifier (optional, only when `iteration.enabled: true`). `current` (default), `next`, or sprint title. Ignored when `iteration.enabled: false` |
| `--max-parallel` | Override `team.max_concurrent_issues` (or `parallel.max_agents`) for this execution (optional) |
| `--resume` | Resume a previously interrupted team execution from `.rite-sprint-team-state` |

---

## Placeholder Legend

| Placeholder | Description | How to Obtain |
|-------------|-------------|---------------|
| `{owner}` | Repository owner | `gh repo view --json owner --jq '.owner.login'` |
| `{repo}` | Repository name | `gh repo view --json name --jq '.name'` |
| `{project_number}` | GitHub Projects project number | From `github.projects.project_number` in `rite-config.yml` |
| `{project_id}` | GitHub Projects project ID | From Phase 1.1 GraphQL query |
| `{owner_type}` | Owner type (`user` or `organization`) | From `gh api users/{owner} --jq '.type'` |
| `{max_parallel}` | Max concurrent agents | From `--max-parallel` arg > `team.max_concurrent_issues` > `parallel.max_agents` in rite-config.yml (default: 3) |
| `{worktree_base}` | Worktree base directory | From `parallel.worktree_base` in rite-config.yml (default: `.worktrees`) |
| `{teammate_model}` | Model for teammate agents | From `team.teammate_model` in rite-config.yml (default: `sonnet`) |

Retrieve `{owner}` and `{repo}` before Phase 0: `gh repo view --json owner,name --jq '{owner: .owner.login, repo: .name}'`

---

## Phase 0: Prerequisites

### 0.1 Load Configuration

Read `rite-config.yml` with Read tool. Extract:
- `team.enabled` — must be true (error if false or missing)
- `team.max_concurrent_issues` — max Issues per batch (default: 3)
- `team.teammate_model` — model for teammate agents (default: `sonnet`)
- `team.auto_review` — auto-run review after all PRs (default: true)
- `iteration.enabled` — determines Issue retrieval method
- `github.projects.enabled` — required (error if false)
- `github.projects.project_number` — project number
- `github.projects.owner` — project owner
- `parallel.max_agents` — fallback for max concurrent agents (default: 3)
- `parallel.worktree_base` — worktree base directory (default: `.worktrees`)
- `safety.max_implementation_rounds` — per-Issue safety limit
- `safety.time_budget_minutes` — per-Issue time advisory (not enforced by timer)
- `commands.test` — test command (may be null)
- `commands.lint` — lint command (may be null)

**Max parallel resolution**: `--max-parallel` argument > `team.max_concurrent_issues` > `parallel.max_agents` > 3 (hardcoded default)

**If `team.enabled: false` or missing**: Display error and exit:

```
エラー: チーム実行が無効です。
rite-config.yml の team.enabled を true に設定してください。
```

**If `projects.enabled: false`**: Display error and exit:

```
エラー: GitHub Projects が無効です。
Sprint チーム実行には Projects 連携が必要です。

対処:
1. rite-config.yml の github.projects.enabled を true に設定
2. /rite:init を再実行
```

### 0.2 Validate Worktree Support

Verify git worktree is available:

```bash
git worktree list --porcelain > /dev/null 2>&1 || echo "ERROR: git worktree not supported"
```

If not supported, display error and suggest using `/rite:sprint:execute` (sequential) instead.

---

## Phase 1: Sprint Identification

Reuse the Sprint identification logic from [sprint/execute.md](./execute.md) Phase 1. The queries and detection logic are identical; only the subsequent processing (batch planning vs sequential execution) differs.

> **Note**: Phase 1 has no team-execute specific differences from execute.md. All sub-phases (1.1, 1.2) are executed exactly as defined in execute.md. The divergence begins in Phase 2 where team-execute retrieves all Todo Issues at once for batch processing instead of picking them one at a time.

### 1.1 Retrieve Project ID

Same as execute.md Phase 1.1 (GraphQL query to get `{project_id}` from `{project_number}`).

### 1.2 Determine Issue Retrieval Method

Same as execute.md Phase 1.2 (branch by `iteration.enabled`: iteration field query vs Status "Todo" filter).

---

## Phase 2: Todo Issue Retrieval and Sorting

### 2.1 Retrieve Todo Issues

Same as [execute.md](./execute.md) Phase 2.1.

### 2.2 Priority and Complexity Sorting

Same as execute.md Phase 2.2.

### 2.3 Dependency Analysis

Same as execute.md Phase 2.3. Additionally, identify which Issues can run in parallel (no mutual dependencies) and which must run sequentially (dependency chain).

### 2.4 Parallel Batch Planning

Group Issues into parallel batches based on:

1. **Independence**: Issues with no mutual dependencies can run in the same batch
2. **Max parallel limit**: Each batch contains at most `{max_parallel}` Issues
3. **Dependency ordering**: If Issue A depends on Issue B, B must be in an earlier batch

```
Batch 1: [#101, #102, #103]  (independent, max_parallel=3)
Batch 2: [#104, #105]        (independent, #104 depends on #101)
Batch 3: [#106]              (depends on #104)
```

### 2.5 Display Execution Plan

```
## Sprint チーム実行計画

### 並列バッチ構成

| Batch | Issues | 依存 |
|-------|--------|------|
| 1 | #{n1} {title}, #{n2} {title} | - |
| 2 | #{n3} {title} | Batch 1 |

### 実行パラメータ

| 項目 | 値 |
|------|-----|
| 合計 Issue 数 | {total} |
| バッチ数 | {batch_count} |
| 最大並列数 | {max_parallel} |
| Worktree ベース | {worktree_base} |
```

### 2.6 User Confirmation

Use `AskUserQuestion`:

```
上記の構成でチーム実行を開始しますか？

オプション:
- チーム実行を開始（推奨）
- 順序変更 / バッチ構成を変更
- 逐次実行に切り替え（/rite:sprint:execute）
- キャンセル
```

---

## Phase 3: Team Execution

### 3.0 Initialize

**Resume check**: If `--resume` is specified, read `.rite-sprint-team-state` and skip to the batch indicated by `current_batch`. Validate that the state file exists and is valid JSON:

```bash
if [ -f .rite-sprint-team-state ]; then
  jq -e '.current_batch' .rite-sprint-team-state > /dev/null 2>&1 || { echo "ERROR: Invalid state file"; exit 1; }
  echo "Resuming from batch $(jq -r '.current_batch' .rite-sprint-team-state)"
else
  echo "ERROR: .rite-sprint-team-state not found" >&2
  exit 1
fi
```

On resume: Skip already-completed Issues (those in `completed` array). Start from `current_batch`.

**Stale worktree detection** (run once before batch loop):

```bash
git worktree list --porcelain
ls -d {worktree_base}/*/* 2>/dev/null
```

If stale worktrees found, offer cleanup via `AskUserQuestion`.

Verify `.worktrees/` is in `.gitignore`:

```bash
grep -q '^\\.worktrees/' .gitignore 2>/dev/null || echo '.worktrees/' >> .gitignore
```

**Initialize sprint state** (skip if resuming):

```bash
jq -n \
  --argjson total {total_count} \
  --argjson current_batch 0 \
  --arg started "$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")" \
  '{total: $total, current_batch: $current_batch, completed: [], skipped: [], failed: [], started_at: $started}' \
  > .rite-sprint-team-state
```

### 3.1 Batch Execution Loop

For each batch in the execution plan:

#### 3.1.1 Batch Progress Display

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Sprint チーム進捗: Batch {current}/{total_batches}
完了 Issue: {completed}/{total_issues}

Batch {current} の Issue:
{issue_list}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

#### 3.1.2 Create Worktrees and Branches

For each Issue in the current batch:

**Step 1**: Generate branch name (same as [issue/start.md](../issue/start.md) Phase 2.1):

```
{type}/issue-{number}-{slug}
```

**Step 2**: Create branch and worktree in a single operation:

```bash
# Create worktree with a new branch in one step
# This avoids the fatal error of adding a worktree for an already-checked-out branch
mkdir -p {worktree_base}/{issue_number}
git worktree add -b {branch_name} {worktree_base}/{issue_number}/work origin/develop
```

> **Reference**: See [git-worktree-patterns.md](../../references/git-worktree-patterns.md) Creation Command for the canonical pattern.

**Error handling**: If branch already exists (`fatal: a branch named '{branch_name}' already exists`), check if a worktree is already associated. If so, remove and recreate. If the branch exists without a worktree, use `git worktree add {path} {branch_name}` (without `-b`).

#### 3.1.3 Spawn Teammates

For each Issue in the batch, spawn a teammate using the Task tool:

```
Task tool parameters:
  subagent_type: "general-purpose"
  description: "Implement Issue #{issue_number}"
  model: "{teammate_model}"
  prompt: |
    You are a Sprint teammate implementing Issue #{issue_number}: {title}.

    ## Issue Details
    {issue_body}

    ## Working Directory
    Work ONLY in the directory: {worktree_path}
    Use ABSOLUTE paths for all file operations.
    Example: {worktree_path}/src/file.ts (correct), src/file.ts (WRONG)

    ## Constraints
    - Do NOT run any git commands (checkout, commit, push, branch, merge, stash)
    - Only use Read, Edit, Write, Glob, Grep, and Bash (for non-git commands like test/lint)
    - All file paths must be absolute paths under {worktree_path}

    ## Implementation Steps
    {checklist_items_from_issue_body}

    ## Output
    When finished, output a summary with:
    1. List of changed files (relative to worktree root)
    2. Brief summary of what was implemented
    3. Any issues or concerns
    4. Quality check results (if test/lint commands were run)

    ## On Error
    If you encounter a blocking error, output the error details and stop.
    Do NOT attempt workarounds outside the worktree directory.
```

**Important**: Spawn all teammates in a single message (parallel Task tool calls) for concurrent execution. Each Task tool call runs independently and returns its result upon completion. If batch size exceeds `{max_parallel}`, split into sub-batches.

#### 3.1.4 Wait for Teammate Completion

All teammates were spawned as parallel Task tool calls in 3.1.3. The Task tool returns results automatically when each agent completes. No explicit polling or message-based monitoring is needed.

**Timeout**: The Task tool has its own timeout handling. If a teammate exceeds the time limit, the Task tool returns an error result. Mark the Issue as failed and proceed with other results.

**Result collection**: For each returned Task result, extract:
- Changed file list
- Implementation summary
- Quality check results (if any)
- Error details (if failed)

#### 3.1.5 Quality Gate per Worktree

After all teammates complete, run quality checks in each worktree (if commands configured). All commands run in a single Bash call to preserve `cd` context:

```bash
cd {worktree_path} && {test_command} && {lint_command}
```

If only one command is configured, run that command alone. If neither is configured, skip quality gate.

| Test Result | Lint Result | Action |
|-------------|-------------|--------|
| Pass (or N/A) | Pass (or N/A) | Proceed to commit |
| Fail | Any | Mark as failed, skip commit |
| Any | Fail | Mark as failed, skip commit |

#### 3.1.6 Team Lead: Commit and Push

**Owner: Team Lead only.** For each passing worktree:

**Step 1**: Stage changes using `git -C` (no `cd` needed):

```bash
# Stage all changes in the worktree
git -C {worktree_path} add -A
```

**Step 2**: Generate commit message with Contextual Commits action lines:

> **Reference**: [Contextual Commits Reference](../../skills/rite-workflow/references/contextual-commits.md) for action line specification, mapping tables, output rules, and scope derivation.

Check `commit.contextual` in `rite-config.yml` to determine the commit body format.

**When `commit.contextual: true` (default):**

Generate structured action lines in the commit body following the Contextual Commits format. In team-execute, the Team Lead generates action lines from each teammate's work results.

- Leave a blank line between the description line and the action lines
- Can be omitted for trivial changes (typo fixes, formatting, dependency bumps, etc.)

**Generation procedure (team-execute specific):**

> **Note**: This overrides the standard source priority in [contextual-commits.md](../../skills/rite-workflow/references/contextual-commits.md#generation-source-priority) — teammate Task output replaces work memory as the highest-priority source because teammates do not commit directly and their work results are the most reliable source of implementation decisions in parallel execution.

1. **Read teammate output**: Extract changed file list, implementation summary, issues, and concerns from the teammate's Task result (Priority 1 — direct output from the implementing agent, as defined in Phase 3.1.4 Result collection)
2. **Read work memory**: If available in `{worktree_path}/.rite-work-memory/issue-{issue_number}.md`, extract from `決定事項・メモ`, `計画逸脱ログ`, `要確認事項` sections (Priority 2)
3. **Extract from Issue body**: Derive `intent` from Issue purpose/motivation, `constraint` from acceptance criteria and technical restrictions (Priority 3)
4. **Infer from diff**: When `git -C {worktree_path} diff --cached` shows clear technical choices (new dependencies, library switches, API design), infer `decision` (Priority 4 — use only when evident)
5. **Apply mapping table**: Map each extracted item to action types using the [Work Memory → Action Line Mapping](../../skills/rite-workflow/references/contextual-commits.md#work-memory--action-line-mapping) table
6. **Filter to 10-line limit**: If action lines exceed 10, trim in order: `learned` → `constraint` → `rejected` → `decision` → `intent` (intent is preserved last as the core "why")

**Output rules:**
- Action type names are always in English (`intent`, `decision`, `rejected`, `constraint`, `learned`)
- Description follows the `language` setting in `rite-config.yml`
- Do not repeat information already visible in the diff
- Do not fabricate action lines without evidence from teammate output, work memory, Issue body, or diff

**Example (language: ja):**

```
feat(#149): team-execute のコミットテンプレートに Contextual Commits を追加

intent(team-execute): 並列実行時のコミットにも意思決定の永続記録を埋め込む
decision(source): teammate の Task 結果サマリーを最優先ソースとして使用（worktree 内の作業メモリは存在しない場合がある）
```

**When `commit.contextual: false`:**

Use free-form commit body. Include the reason for the change ("why") in the commit body.

- Leave a blank line between the description line and the body
- Focus on "why" the change was needed, not "what" was changed
- Follow the `language` setting in `rite-config.yml`

**Step 3**: Commit with the generated message:

**When `commit.contextual: true`:**

```bash
git -C {worktree_path} commit -m "$(cat <<'EOF'
{commit_type}(#{issue_number}): {commit_message}

{action_lines}

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
EOF
)"
```

**When `commit.contextual: false`:**

```bash
git -C {worktree_path} commit -m "$(cat <<'EOF'
{commit_type}(#{issue_number}): {commit_message}

{free_form_body}

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
EOF
)"
```

**Step 4**: Push the branch (from main repo, not worktree):

```bash
git push origin {branch_name}
```

**Step 5**: Update GitHub Projects Status to "In Progress":

Follow [Projects Integration](../../references/projects-integration.md#24-github-projects-status-update) pattern.

#### 3.1.7 Team Lead: PR Creation

For each successfully pushed branch, create a PR:

**Step 1**: Switch to the Issue branch before creating the PR:

```bash
git checkout {branch_name}
```

**Step 2**: Create the PR:

```
Skill invocation:
  skill: "rite:pr:create"
```

**Step 3**: Return to develop after PR creation:

```bash
git checkout develop
```

**Note**: Team Lead creates PRs sequentially (one at a time) to avoid race conditions. The branch checkout is required because `rite:pr:create` identifies the PR from the current branch.

#### 3.1.8 Update Sprint State

After each batch:

```bash
TMP_STATE=".rite-sprint-team-state.tmp.$$"
jq --argjson batch {current_batch} \
   --argjson entries '[{entries_json}]' \
   '.current_batch = ($batch + 1) | .completed += [$entries[] | select(.status == "completed")] | .failed += [$entries[] | select(.status == "failed")] | .skipped += [$entries[] | select(.status == "skipped")]' \
   .rite-sprint-team-state > "$TMP_STATE" && mv "$TMP_STATE" .rite-sprint-team-state || rm -f "$TMP_STATE"
```

#### 3.1.9 Worktree Cleanup (per Batch)

After all commits/pushes for a batch:

```bash
# Remove each worktree
git worktree remove {worktree_base}/{issue_number}/work --force 2>/dev/null || true

# Remove the Issue directory
rmdir {worktree_base}/{issue_number} 2>/dev/null || true

# Prune worktree metadata
git worktree prune
```

#### 3.1.10 Batch Checkpoint

After each batch (except the last), confirm continuation:

Use `AskUserQuestion`:

```
Batch {current} が完了しました。（{completed_issues}/{total_issues} Issues 完了）

結果:
| Issue | 状態 | PR |
|-------|------|-----|
| #{n} {title} | ✅ 完了 / ❌ 失敗 | #{pr} |

残り: {remaining_batches} バッチ ({remaining_issues} Issues)

オプション:
- 次のバッチを開始（推奨）
- レビューを先に実施: 完了した PR のレビューを行ってから次のバッチへ
- 中断: 進捗を保存して後で再開
- 中止: Sprint 実行を終了
```

---

## Phase 4: Review Phase (Optional)

After all batches complete, optionally run reviews on all created PRs.

### 4.1 Review Decision

Use `AskUserQuestion`:

```
全 {total} Issue の実装が完了しました。
作成された PR: {pr_count} 件

オプション:
- 全 PR をレビュー（推奨）: 各 PR に /rite:pr:review を実行
- 個別にレビュー: PR 番号を指定して選択的にレビュー
- レビューをスキップ: 完了レポートを表示
```

### 4.2 Sequential Review

If review selected, run `rite:pr:review` for each PR sequentially:

```
Skill invocation:
  skill: "rite:pr:review"
  args: "{pr_number}"
```

**Context management**: Each review consumes significant context. After every 2 reviews, suggest `/clear` + resume.

---

## Phase 5: Cleanup and Report

### 5.1 Final Worktree Cleanup

Ensure all worktrees are removed:

```bash
# Remove any remaining worktrees
git worktree list --porcelain | grep "worktree.*{worktree_base}" | while read -r line; do
  path=$(echo "$line" | awk '{print $2}')
  git worktree remove --force "$path" 2>/dev/null || true
done

# Prune
git worktree prune

# Remove base directory if empty
rmdir {worktree_base}/*/ 2>/dev/null || true
rmdir {worktree_base} 2>/dev/null || true
```

### 5.2 Sprint Completion Report

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
## Sprint チーム実行完了レポート

### サマリー

| 項目 | 値 |
|------|-----|
| 実行 Issue 数 | {total} |
| 完了 | {completed_count} |
| スキップ | {skipped_count} |
| 失敗 | {failed_count} |
| バッチ数 | {batch_count} |
| 所要時間 | {elapsed_time} |

### 完了した Issue

| # | Issue | PR | 状態 |
|---|-------|----|------|
| 1 | #{number} {title} | #{pr_number} | ✅ |

### 失敗した Issue

| # | Issue | エラー |
|---|-------|--------|
| 1 | #{number} {title} | {error} |

### 次のアクション

- `/rite:pr:review {pr_number}` で個別 PR のレビュー
- `/rite:sprint:current` で Sprint 状況を確認
- `/rite:sprint:plan` で次の Sprint を計画
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

### 5.3 Cleanup State File

```bash
rm -f .rite-sprint-team-state
```

---

## Safety Mechanisms

### Worktree Proliferation Prevention

- Maximum worktrees = `team.max_concurrent_issues` (falls back to `parallel.max_agents`, default: 3)
- Each batch creates at most `{max_parallel}` worktrees
- Worktrees are cleaned up after each batch (not accumulated)

### Cost Control

- Total agent spawns per sprint = `total_issues` (one teammate per Issue)
- Each teammate runs at most `safety.max_implementation_rounds` rounds
- If `safety.auto_stop_on_repeated_failure` is true, stop on repeated failures

### Git Safety

- Only Team Lead performs git operations (checkout, commit, push, merge)
- Teammates cannot execute git commands (enforced by prompt constraints)
- Worktree branches are created from `origin/develop` (fresh base)
- `--no-ff` merge is not used (each Issue gets its own branch/PR)

### Failure Isolation

- Each Issue runs in an independent worktree
- Failure of one teammate does not affect others
- Failed worktrees are cleaned up without merging

---

## Error Handling

See [Common Error Handling](../../references/common-error-handling.md) for shared patterns (Not Found, Permission, Network errors).

| Error | Recovery |
|-------|----------|
| Worktree Creation Failure | 既存の worktree を確認: git worktree list |
| Teammate Timeout | See error output for details |
| API Errors | See error output for details |
