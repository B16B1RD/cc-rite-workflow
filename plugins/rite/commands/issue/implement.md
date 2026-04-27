---
description: 実装作業・コミット・プッシュ・チェックリスト更新ロジック
---

# Implementation Guidance

This module handles the actual implementation work, commits, pushes, and checklist updates.

## 5.1 Implementation Work

Perform actual implementation work following the implementation plan approved in Phase 3.

> **Reference**: Apply the Phase 5.1 checklist from [AI Coding Principles](../../skills/rite-workflow/references/coding-principles.md).
> In particular, check `simplicity_enforcement`, `scope_discipline`, and `dead_code_hygiene`.

> **Plugin Path**: Resolve `{plugin_root}` per [Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script) before executing bash hook commands in this file.

### 5.0.W Wiki Query Injection (Conditional)

> **Reference**: [Wiki Query](../wiki/query.md) — `wiki-query-inject.sh` API

Before starting implementation, inject relevant experiential knowledge from the Wiki to inform the implementation approach.

**Condition**: Execute only when `wiki.enabled: true` AND `wiki.auto_query: true` in `rite-config.yml`. Skip silently otherwise.

**Step 1**: Check Wiki configuration:

```bash
wiki_section=$(sed -n '/^wiki:/,/^[a-zA-Z]/p' rite-config.yml 2>/dev/null) || wiki_section=""
wiki_enabled=""
if [[ -n "$wiki_section" ]]; then
  wiki_enabled=$(printf '%s\n' "$wiki_section" | awk '/^[[:space:]]+enabled:/ { print; exit }' \
    | sed 's/[[:space:]]#.*//' | sed 's/.*enabled:[[:space:]]*//' | tr -d '[:space:]"'"'"'' | tr '[:upper:]' '[:lower:]')
fi
auto_query=""
if [[ -n "$wiki_section" ]]; then
  auto_query=$(printf '%s\n' "$wiki_section" | awk '/^[[:space:]]+auto_query:/ { print; exit }' \
    | sed 's/[[:space:]]#.*//' | sed 's/.*auto_query:[[:space:]]*//' | tr -d '[:space:]"'"'"'' | tr '[:upper:]' '[:lower:]')
fi
case "$wiki_enabled" in false|no|0) wiki_enabled="false" ;; true|yes|1) wiki_enabled="true" ;; *) wiki_enabled="true" ;; esac  # #483: opt-out default
case "$auto_query" in true|yes|1) auto_query="true" ;; *) auto_query="false" ;; esac
echo "wiki_enabled=$wiki_enabled auto_query=$auto_query"
```

If `wiki_enabled=false` or `auto_query=false`, skip this section and proceed to implementation.

**Step 2**: Generate keywords from the implementation plan and invoke the query:

Keywords are derived from: implementation plan step descriptions, target file paths, and relevant domain terms from the plan.

```bash
# {plugin_root} はリテラル値で埋め込む
# {keywords} は実装計画のキーワード（ファイルパス、ドメイン用語等）をカンマ区切りで生成
wiki_context=$(bash {plugin_root}/hooks/wiki-query-inject.sh \
  --keywords "{keywords}" \
  --format compact 2>/dev/null) || wiki_context=""
if [ -n "$wiki_context" ]; then
  echo "$wiki_context"
else
  echo "(Wiki から関連経験則は見つかりませんでした)"
fi
```

**Step 3**: If `wiki_context` is non-empty, retain it in conversation context and reference it during implementation. The injected experiential knowledge may inform: common implementation patterns, known pitfalls, and effective approaches for similar changes.

**Basic implementation flow:**

1. Check current file content with Read tool
2. Apply changes with Edit tool
3. After changes, verify behavior with Bash as needed (test execution, etc.)
4. Repeat following plan order when there are multiple file changes

**Tools used:**

| Tool | Usage |
|------|-------|
| Read | Check content of files to change |
| Edit | Add/modify code |
| Bash | Verify changes with `git status`, run tests |
| Glob/Grep | Explore related files (when needed) |

**When there is an implementation plan:**
- Follow the plan's "Implementation steps (dependency graph)" — pick the next step whose `depends_on` prerequisites are all complete
- After each step completion, re-evaluate remaining steps (see 5.1.0.5 Adaptive Re-evaluation)
- Update work memory after each step completion as needed (described below)

**When the implementation plan was skipped:**
- Refer to the Issue's **What** (what to do) and **Where** (where to change) for work
- Explore related files with Glob tool (file pattern search) or Grep tool (keyword search) as needed

**Decisions during implementation:**
- Record important design decisions in work memory
- Pause and record the situation when unexpected problems occur

**Work memory update (optional):**

For large changes or work spanning multiple sessions, invoke `/rite:issue:update` via Skill tool to record progress:

```
Skill ツール呼び出し:
  skill: "rite:issue:update"
```

**Note**: Can be omitted for small changes. Recommended at session end or interruption.

### 5.1.0.T TDD Light: Test Skeleton Generation (Conditional)

> **Reference**: [TDD Light Reference](../../references/tdd-light.md) for complete specification (classification logic, hash normalization, skeleton templates, idempotency rules).

**Skip conditions** (any match → skip to 5.1.0):

- `tdd.mode` is not `"light"` (or `tdd` section undefined → `off`)
- `commands.test` is `null` or not set
- `tdd_state.skeleton_generated` is `true` AND tag strings exist in codebase (idempotency)

When skipped, display: `TDD Light: スキップ（{reason}）` — where `{reason}` is one of `tdd.mode: off`, `commands.test 未設定`, `スケルトン生成済み`.

**Execution steps** (when not skipped):

**Step 1: Baseline** (if `tdd.run_baseline: true`)

Run existing tests to capture baseline state per [Output Processing](../../references/tdd-light.md#output-processing):

```bash
baseline_output=$(mktemp)
trap 'rm -f "$baseline_output"' EXIT
set -o pipefail
TERM=dumb {test_command} 2>&1 | sed 's/\x1b\[[0-9;]*m//g' > "$baseline_output"
baseline_rc=${PIPESTATUS[0]}
```

Record baseline exit code. Existing failures are logged but do not block.

**Step 2: Extract acceptance criteria**

Extract from Issue body (use body from Phase 0.1). If context was compacted and the body is unavailable, re-fetch with `gh issue view {issue_number} --json body --jq '.body'`. If retrieval fails, display `WARNING: Issue body の取得に失敗。スケルトン生成をスキップします`, record skip stub in work memory, and skip to 5.1.0.

**Heading match rules**: Match any of the following headings (case-insensitive, level 2 `##`):

| Pattern | Examples |
|---------|---------|
| `## 受入条件` | Exact match (Japanese) |
| `## Acceptance Criteria` | Exact match (English) |
| `## 受け入れ条件` | Alternative Japanese form |

The section extends from the matched heading to the next `##` heading or end of body.

- Pattern: lines matching `^- \[[ xX]\] (.+)$` under the heading
- Exclude Issue references: `^- \[[ xX]\] #\d+`

If no acceptance criteria section found (none of the above headings found), record skip stub in work memory and skip to 5.1.0.

**Step 3: Generate skeletons**

For each criterion (up to `tdd.max_skeletons`):

1. Compute hash per [Hash Normalization](../../references/tdd-light.md#hash-normalization)
2. Sanitize summary per [Criterion Summary Sanitization](../../references/tdd-light.md#criterion-summary-sanitization)
3. Check per-criterion idempotency (tag exists in test files → skip)
4. Generate skeleton using framework-appropriate template (see [Skeleton Templates](../../references/tdd-light.md#skeleton-templates))

If framework cannot be determined, skip generation and record skip stub.

**Step 4: Red confirmation**

Run tests per [Output Processing](../../references/tdd-light.md#output-processing) and classify result per [Classification Logic](../../references/tdd-light.md#classification-logic):

| Classification | Action |
|---------------|--------|
| `TDD_RED_CONFIRMED` | Proceed to implementation (5.1.0) |
| `TDD_TRIVIALLY_PASSING` | WARNING — review skeletons, then proceed |
| `TDD_ALL_PASSING` | INFO — no skeleton tests detected, proceed |
| `TDD_NO_SKELETON_OUTPUT` | WARNING — skeletons may not be reachable, proceed |
| `TDD_RUNNER_ABORTED_OR_BLOCKED` | ERROR — display error, proceed with implementation |

**Step 5: Record and commit**

1. Update work memory `### TDD 状態` section (see [Work Memory Format - TDD State](../../skills/rite-workflow/references/work-memory-format.md#tdd-state-section))
2. Commit skeleton files: `test(tdd): add acceptance criteria skeletons for #{issue_number}`
3. Push to remote

### 5.1.0 Parallel Implementation (Conditional)

Execute parallel implementation when conditions are met if `parallel.enabled` is `true` (default) in `rite-config.yml`.

#### 5.1.0.1 Parallel Implementation Condition Check

Execute parallel implementation when **all** of the following conditions are met:

| Condition | Determination Method |
|-----------|---------------------|
| `parallel.enabled: true` | From `rite-config.yml` (default: `true`) |
| Complexity M or above | Issue's Complexity field, or `## 複雑度` section in body |
| 2 or more independent tasks | Determined from implementation plan (see below) |

**Independent task determination:**

Analyze the "files to change" from the implementation plan (Phase 3) and determine independence using the following criteria:

| Criterion | Determined as Independent | Determined as Dependent |
|-----------|--------------------------|------------------------|
| Inter-file imports | No cross-references | One imports the other |
| Shared state | No shared variables/state | Shares global state |
| Execution order | Order-independent | Requires preceding task results |

**Determination flow:**

```
parallel.enabled を確認
├─ false → 5.1.0.1-5.1.0.4 parallel implementation はスキップ、5.1.0.5 Adaptive Re-evaluation / 5.1.0.6 Test Verification Gate / 5.1.0.6.1 Acceptance Criteria Check / 5.1.0.7 Documentation Impact Investigation を経て 5.1.1 へ
└─ true → 複雑度を確認
    ├─ XS/S → 通常の順次実装
    └─ M 以上 → 独立タスクを分析
        ├─ 独立タスク 1 件以下 → 通常の順次実装
        └─ 独立タスク 2 件以上 → parallel.mode を確認
            ├─ "shared"（デフォルト）→ 5.1.0.2 共有モード実行
            └─ "worktree" → 5.1.0.2W Worktree モード実行
```

#### 5.1.0.2 Parallel Implementation Execution (Shared Mode)

**Applies when**: `parallel.mode: "shared"` (default) or `parallel.mode` is not set.

Invoke multiple Task tools (`subagent_type: "general-purpose"`) **within a single message** for parallel execution. When exceeding `max_agents` (default: 3), split into batches of `max_agents`, waiting for each batch to complete before executing the next.

#### 5.1.0.2W Parallel Implementation Execution (Worktree Mode)

**Applies when**: `parallel.mode: "worktree"` in `rite-config.yml`.

> **Reference**: [Git Worktree Patterns](../../references/git-worktree-patterns.md) for complete operation patterns, merge strategy, and safety mechanisms.

**Step 1: Stale worktree detection and `.gitignore` verification**

Check for existing worktrees from previous runs:

```bash
# List existing worktrees (more than 1 entry means worktrees exist beyond the main)
git worktree list --porcelain

# Check for stale worktrees under the worktree base directory
ls -d {worktree_base}/*/* 2>/dev/null
```

If stale worktrees are found, offer cleanup via `AskUserQuestion` (see [Safety Mechanisms](../../references/git-worktree-patterns.md#safety-mechanisms)).

Verify `.worktrees/` is in `.gitignore`:

```bash
grep -q '^\.worktrees/' .gitignore 2>/dev/null || echo '.worktrees/' >> .gitignore
```

**Step 2: Create worktrees**

For each independent task identified in 5.1.0.1:

```bash
mkdir -p {worktree_base}/{issue_number}
git worktree add {worktree_base}/{issue_number}/{task_id} -b {branch_name}/{task_id} {branch_name}
```

Where `{worktree_base}` is from `parallel.worktree_base` in rite-config.yml (default: `.worktrees`).

**Error handling**: If `git worktree add` fails (e.g., branch already exists, path conflict):

| Exit Code | Likely Cause | Action |
|-----------|-------------|--------|
| Non-zero with "already exists" | Branch from previous run | Remove stale branch with `git branch -D {branch_name}/{task_id}` and retry |
| Non-zero with "is a worktree" | Path conflict | Remove with `git worktree remove --force {path}` and retry |
| Other non-zero | Unexpected error | Skip this task and fall back to sequential implementation |

**Step 3: Spawn agents in worktrees**

Invoke multiple Task tools **within a single message**, each with a specific worktree path. When exceeding `max_agents`, split into batches.

```
Task tool parameters:
  subagent_type: "general-purpose"
  prompt: "{task_description}. Work ONLY in {worktree_path}. Use ABSOLUTE paths for all file operations (e.g., {worktree_path}/src/file.ts). Do NOT run any git commands (checkout, commit, push, branch, merge, stash). You may use Read, Edit, Write, Glob, Grep, and Bash (for non-git commands like test/lint) tools."
```

**Critical**: Agent prompts must explicitly prohibit git operations (checkout, commit, push, branch, merge, stash). Only the orchestrator performs git operations.

**Step 4: Quality gate per worktree**

After all agents complete, run quality checks in each worktree if `commands.test` or `commands.lint` is configured:

```bash
cd {worktree_path} && {test_command} && {lint_command}
```

Exclude failed worktrees from merge (see [Quality Gate per Worktree](../../references/git-worktree-patterns.md#quality-gate-per-worktree)).

**Step 5: Merge worktree branches**

Merge each passing task branch back to the Issue branch using `--no-ff`:

```bash
git checkout {branch_name}
git merge --no-ff {branch_name}/{task_id} -m "chore(parallel): integrate {task_id} ({task_description})"
```

On merge conflict, follow the [first-merge-wins convention](../../references/git-worktree-patterns.md#conflict-resolution-convention).

**Step 6: Cleanup**

Remove all worktrees and task branches:

```bash
git worktree remove {worktree_base}/{issue_number}/{task_id}
git branch -d {branch_name}/{task_id}
```

Then prune worktree metadata: `git worktree prune`.

#### 5.1.0.3 Parallel Implementation Result Integration

Display results in a table. On partial failure, retain successful results and prompt manual handling for failures. Fall back to sequential implementation when all tasks fail. After parallel implementation, check for conflicts with `git status`.

**Worktree mode additional reporting**: When `parallel.mode: "worktree"`, include merge status and any conflict resolution actions in the results table.

#### 5.1.0.4 Parallel Implementation Skip

Use sequential implementation when: `parallel.enabled: false`, complexity S or below, 1 or fewer independent tasks, or plan was skipped.

#### 5.1.0.5 Adaptive Re-evaluation Checkpoint

After completing each implementation step, re-evaluate the remaining steps before proceeding to the next one. This follows the "tackle the next most obvious problem" strategy from autonomous agent patterns.

**When to execute**: After every step completion when the plan uses the dependency graph format (Phase 3.3 table with `depends_on` column). Skip if the plan was skipped in Phase 3.4 or if the plan lacks a `depends_on` column (pre-existing numbered list format).

**Relationship with parallel implementation (5.1.0.1-5.1.0.4)**: When parallel implementation is active, execute the re-evaluation checkpoint **after each parallel batch completes** (not after each individual parallel task). The batch completion triggers dependency state update, and newly unblocked steps are candidates for the next parallel batch.

**Re-evaluation procedure**:

1. **Verify completion criteria**: If the implementation plan includes a `検証基準` column, verify the completed step's criteria using the appropriate tool before marking it complete:

   | Criteria Type | Verification Method |
   |--------------|---------------------|
   | File existence | `Glob` or `Read` tool |
   | Function/export existence | `Grep` tool (e.g., `export.*functionName`) |
   | Pattern presence | `Grep` tool |
   | Test passage | `Bash` tool (run test command) |
   | Config value | `Read` or `Grep` tool |
   | Line count / structure | `Read` tool + count |

   **When criteria is met**: Proceed to step 2 (Post-Step Quality Gate).

   **When criteria is NOT met**:
   - Re-attempt the implementation to satisfy the criteria
   - If the criteria itself is incorrect (implementation approach changed), record the deviation in work memory's "計画逸脱ログ" section and update the criteria before marking complete
   - Do NOT mark the step as complete until the (original or updated) criteria is verified
   - **Escalation**: If 2 re-attempts fail to satisfy the criteria, use `AskUserQuestion` to ask the user whether to (a) continue retrying, (b) update the criteria, or (c) skip verification and mark complete with a deviation log entry

   **When no `検証基準` column exists** (legacy plans or skipped plans): Skip this verification step and proceed to step 2 directly.

2. **Post-Step Quality Gate** (mental check — no tool calls required, complete within 10 seconds):

   After verifying completion criteria (or skipping verification), perform a lightweight self-check on the just-completed step using the immediately available work context. This gate catches scope drift, regression risks, and specification misalignment early — before they compound across subsequent steps.

   **Relationship with parallel implementation**: When a parallel batch completes multiple steps simultaneously, run the Quality Gate for each step in the batch individually, using each step's specific work context.

   **Check items**:

   | # | Check | Question | Trigger |
   |---|-------|----------|---------|
   | 1 | **Scope drift** | Did you modify files not listed in the implementation plan? | Edited files outside the plan's "変更対象ファイル" |
   | 2 | **Regression concern** | If shared/common code was changed, are you aware of the impact scope? | Modified a shared utility, configuration, or common module file that you observed being referenced by other files during this implementation session |
   | 3 | **Specification alignment** | Is the change consistent with the Issue's What/Why? | Change purpose diverges from the Issue description |

   **Evaluation**: For each check, assess pass/flag based on the work context already in memory (files edited, step description, Issue body). Do NOT invoke Read, Grep, Bash, or any other tool — this is a mental evaluation only.

   **When all checks pass**: Proceed to step 3 (mark complete). No output needed.

   **When any check is flagged**:
   - Record the flagged item(s) in work memory's "計画逸脱ログ" section using the existing table format (consistent with step 6's plan deviation recording):
     ```
     | {next_number} | S{n} | QG | {check_name}: {brief description} | — | — |
     ```
     Where `逸脱種別` is `QG` (Quality Gate). `影響範囲` and `代替ステップ` are `—` (not applicable for informational flags).
   - **Continue execution** (do NOT stop or ask the user). The Quality Gate is informational — it logs concerns for later review but does not block progress.
   - Proceed to step 3 (mark complete).

3. **Mark step complete**: Output the display format below. This serves as the record in conversation context. For persistence across `/clear`, completed step IDs are reflected in the work memory's implementation plan `状態` column (bulk-updated from `⬜` to `✅` at commit time in 5.1.1.2, not after every step)
4. **Update dependency state**: Identify newly unblocked steps (steps whose `depends_on` are all complete)
5. **Select next step**: From the unblocked steps, pick the one with highest priority using:

| Priority | Criterion | Reason |
|----------|-----------|--------|
| 1 | Steps that unblock the most downstream steps | Maximize parallelism |
| 2 | Steps with highest implementation risk | Fail fast — surface problems early |
| 3 | Steps with smallest scope | Quick wins build momentum |

6. **Check for plan deviation**: If the implementation reveals that a planned step is unnecessary, needs modification, or a new step is required:
   - Record the deviation in work memory's "計画逸脱ログ" section (see work-memory-format.md)
   - Adjust the remaining plan accordingly
   - **Minor adjustments** (no user confirmation needed): Changing implementation approach within the same step, skipping a step that became unnecessary, adding a small helper step (scope < 1 file)
   - **Significant scope changes** (ask user via `AskUserQuestion`): Adding new files not in the original plan, changing public API/interface contracts, scope expansion exceeding 50% of original estimate, changing the dependency structure of 3+ remaining steps

7. **Bottleneck detection**: After the step completes, check if it exceeded any bottleneck threshold. Metrics are counted from when the step started to when it finished. This is a guard clause — skip immediately when no threshold is exceeded (zero overhead on normal path).

   > **Reference**: [Bottleneck Detection Reference](../../references/bottleneck-detection.md) for complete thresholds, Oracle discovery protocol, and re-decomposition procedure.

   **Threshold check** (any match triggers detection):

| Threshold | Condition |
|-----------|-----------|
| Round count | > 3 rounds (Read/Edit/Bash cycles) within the step |
| File count | > 5 files modified (Edit/Write) within the step |
| Line count | > 200 lines changed (insertions + deletions) within the step |

   **When no threshold exceeded**: Return immediately — proceed to display format below. No further action.

   **When threshold exceeded**:
   1. **Discover Oracle and re-decompose**: Follow [Bottleneck Detection Reference](../../references/bottleneck-detection.md) — discover Oracle (Priority 1→2→3), then re-decompose step into sub-steps `S{n}.1`, `S{n}.2`, etc.
   2. **Update plan**: Insert sub-steps into the dependency graph, replacing the original step. Update the implementation plan in work memory per [3.5.1 Mid-Implementation Replanning](./implementation-plan.md#351-mid-implementation-replanning-triggered-by-bottleneck-detection)
   3. **Display and record**: Use the bottleneck display format (see below). Add entry to work memory "ボトルネック検出ログ" section at next bulk update (commit time)
   4. **Continue**: Execute the first sub-step (`S{n}.1`) — do NOT re-evaluate the parent step

**Display format** (after each step, normal path — no bottleneck):

```
✅ Step {completed_id} 完了: {step_description}

次のステップ候補:
| Step | 内容 | 状態 | 選出理由 |
|------|------|------|---------|
| {next_id} | {description} | 🔓 実行可能 | {reason} |
| {other_id} | {description} | 🔒 依存待ち ({pending_deps}) | - |

→ 次に実行: Step {next_id}
```

**Display format** (after step with bottleneck detected — Oracle found):

```
⚠️ ボトルネック検出: Step S{n} ({step_description})
検出理由: {threshold_exceeded} （{actual_value}/{threshold_value}）

Oracle: {oracle_source} ({oracle_file_path})

再分解:
| Step | 内容 | depends_on |
|------|------|------------|
| S{n}.1 | {sub_step_1} | — |
| S{n}.2 | {sub_step_2} | S{n}.1 |

→ 次に実行: Step S{n}.1
```

**Display format** (after step with bottleneck detected — no Oracle found):

```
⚠️ ボトルネック検出: Step S{n} ({step_description})
検出理由: {threshold_exceeded} （{actual_value}/{threshold_value}）

Oracle: なし（フォールバック分解を適用）

再分解:
| Step | 内容 | depends_on |
|------|------|------------|
| S{n}.1 | {sub_step_1} | — |
| S{n}.2 | {sub_step_2} | S{n}.1 |

→ 次に実行: Step S{n}.1
```

> **Reference**: See [Bottleneck Detection Reference - User Notification](../../references/bottleneck-detection.md#user-notification) for complete display format details.

**When all steps are complete**: Proceed to 5.1.0.6 (Test Verification Gate), then 5.1.0.7 (Documentation Impact Investigation), then 5.1.1 (Commit). The chain is **5.1.0.6 → 5.1.0.6.1 → 5.1.0.7 → 5.1.1**; never bypass 5.1.0.7 on the way to commit.

#### 5.1.0.6 Test Verification Gate (Conditional)

Execute test verification before committing when conditions are met.

##### Condition Check

Read `rite-config.yml` and check:

| Condition | Check Method |
|-----------|-------------|
| `commands.test` is set | Non-null value in `rite-config.yml` |
| `verification.run_tests_before_pr` is `true` | From `rite-config.yml` (default: `true`) |

**Skip conditions** (any match → skip to 5.1.0.7, then 5.1.1):
- `commands.test` is `null` or not set
- `verification.run_tests_before_pr` is `false`

When skipped, display the appropriate message:
- `commands.test` not set: `テスト検証: スキップ（commands.test 未設定）`
- `run_tests_before_pr: false`: `テスト検証: スキップ（verification.run_tests_before_pr: false）`

##### Test Execution

```bash
# rite-config.yml の commands.test を実行
{test_command}
```

**Result handling:**

| Exit Code | Action |
|-----------|--------|
| 0 | Tests passed → proceed to 5.1.0.6.1 (acceptance criteria check) → 5.1.0.7 (documentation impact investigation) → 5.1.1 (commit) |
| Non-zero | Tests failed → display failures, return to 5.1 implementation |

**On test failure:**

```
テスト失敗: {test_error_count} 件のテストが失敗しました

失敗したテスト:
{test_output}

実装を修正してテストを再実行してください。
```

Return to Phase 5.1 (implementation). Do NOT proceed to commit.

**Re-execution limit**: Test re-execution follows the `safety.max_implementation_rounds` limit in `rite-config.yml`. When the limit is reached, display via `AskUserQuestion`: `テスト再実行の上限に達しました（{max_implementation_rounds}回）。続行しますか？ オプション: 継続する / 中断してユーザーに確認`

**Note**: When called from the `/rite:issue:start` end-to-end flow, test results are retained in conversation context. The subsequent `/rite:lint` Phase 3.4 can skip duplicate test execution if tests were already run and passed in this phase.

##### 5.1.0.6.1 Acceptance Criteria Check (Conditional)

**Condition**: `verification.acceptance_criteria_check` is `true` (default: `true`) AND Issue body contains an acceptance criteria section.

**Heading match rules**: Match any of the following headings (case-insensitive, level 2 `##`):

| Pattern | Examples |
|---------|---------|
| `## 受入条件` | Exact match (Japanese) |
| `## Acceptance Criteria` | Exact match (English) |
| `## 受け入れ条件` | Alternative Japanese form |

The section extends from the matched heading to the next `##` heading or end of body.

**Skip conditions** (any match → skip to 5.1.0.7, then 5.1.1):
- `verification.acceptance_criteria_check` is `false`
- Issue body does not contain an acceptance criteria section (none of the above headings found)

**Issue body retrieval**: Use the Issue body already obtained in Phase 0.1 (retained in conversation context). If context was compacted and the body is unavailable, re-fetch with `gh issue view {issue_number} --json body --jq '.body'`. If retrieval fails, display `WARNING: Issue body の取得に失敗。受入条件チェックをスキップします` and skip to 5.1.0.7 (then 5.1.1).

**Check procedure:**

1. Extract acceptance criteria items from Issue body (lines matching `- [ ]` or `- [x]` under the acceptance criteria heading)
2. For each criterion, evaluate whether the current implementation satisfies it based on:
   - Changed files and their content
   - Test results (if tests were run)
   - Implementation plan completion status
3. Display verification results:

```
受入条件チェック:
- {criterion_1} — 満たされています
- {criterion_2} — 満たされています
- {criterion_3} — 確認が必要です（理由: {reason}）
```

**Result handling:**

| Result | Action |
|--------|--------|
| All criteria satisfied | Proceed to 5.1.0.7 (documentation impact investigation) → 5.1.1 (commit) |
| Some need attention | Display via `AskUserQuestion`: `受入条件の一部が未確認です。続行しますか？ オプション: コミットに進む / 実装に戻る` |

**Note**: This check is advisory — it helps catch missed requirements but does not block the flow when the user chooses to proceed.

#### 5.1.0.7 Documentation Impact Investigation

> **Reference**: Apply `documentation_consistency` from [AI Coding Principles](../../skills/rite-workflow/references/coding-principles.md).

Before committing, investigate whether the implementation introduces any user-facing specification change that requires updating related documentation (README, `docs/`, `CLAUDE.md`, `plugins/rite/**/*.md`, etc.). When stale documentation is detected, fix it immediately within the same branch — do NOT defer to a separate Issue, do NOT ask the user via `AskUserQuestion`.

This step is the implementer's responsibility and complements (does not replace) the tech-writer reviewer at PR review time. Catching documentation drift before commit avoids a review round-trip.

##### Skip Conditions

Skip this entire section (proceed directly to 5.1.1) when **any** of the following holds:

| Skip condition | Determination |
|---------------|---------------|
| No specification change | The diff only touches internals (private functions, refactor, code style, comment-only edits) with no observable change to commands, configuration keys, file layout, public API, workflow phases, or user-visible behavior |
| Auxiliary documentation-only change | The diff only modifies auxiliary documentation that does NOT define user-visible workflow, commands, config keys, or specification — e.g., `CHANGELOG*`, release notes, or pure prose updates to `README*`. **Do NOT skip** when the diff touches files that define workflow or specification (e.g., `plugins/rite/commands/**/*.md`, `plugins/rite/skills/**/*.md`, `plugins/rite/references/**/*.md`, or any `docs/` file documenting a public API) — those changes are themselves the drift source that this step is meant to detect |
| Test-only change | The diff only touches test files (`*.test.*`, `*.spec.*`, `tests/**`) |

The decision is made by the LLM based on the actual diff (`git diff --name-status origin/{base_branch}...HEAD` plus the work memory's "決定事項・メモ") — there is no explicit trigger pattern. When in doubt, do **NOT** skip.

##### Investigation Procedure

**Step 1: Extract specification keywords**

From the implementation just completed, extract user-facing identifiers that may appear in documentation. Sources:

| Source | Examples |
|--------|---------|
| Renamed / added / removed commands | `/rite:issue:start`, slash-command names |
| Renamed / added / removed config keys | `rite-config.yml` keys (`branch.base`, `wiki.enabled`) |
| Renamed / added / removed file paths | Section file paths a user copies into their project |
| Renamed / added / removed phase / workflow names | `Phase 5.4`, `review-fix loop` |
| Renamed / added / removed public function / hook names | hook script names, exported helpers |

Use the work memory's `決定事項・メモ` and the diff itself as the source. Skip identifiers that are clearly internal.

**Step 2: Project-wide search**

For each keyword, search the **entire repository** for documentation references using the Grep tool. The search scope is fixed to project-wide and is not configurable.

**Required Grep invocations (run all three per keyword)**:

1. `glob: "**/*.md"` — all Markdown files (includes `CLAUDE.md` at any depth, `docs/**/*.md`, `plugins/**/*.md`)
2. `glob: "README*"` — extension-less or alternative-extension README files (`README`, `README.rst`, `README.adoc`, etc.) that the `*.md` glob misses
3. `glob: "CHANGELOG*"` — CHANGELOG files that reference user-visible features by name

All three globs use `output_mode: "files_with_matches"` and the same `pattern: "{keyword}"`. Running all three is mandatory — skipping `README*` or `CHANGELOG*` because "they're usually `*.md`" causes silent drift in repos that use extension-less READMEs.

**Exclude the modified file set from the results**: Compute the set of currently-modified files from `git diff --name-only origin/{base_branch}...HEAD` and exclude any file in that set from the Read/Edit step (Step 3). The modified file set is typically multiple files, not one — do not assume a single "the file".

**Step 3: Read and judge**

For each candidate file returned by the search, use the Read tool to inspect the matched lines and judge whether the documentation is now stale:

| Judgment | Action |
|---------|--------|
| Stale (documentation describes the old behavior / old name / removed feature) | Edit immediately with the Edit tool |
| Still accurate (the keyword appears but the surrounding text is still correct) | Leave as-is |
| Uncertain | Treat as stale and update; over-updating documentation is cheaper than leaving drift |

**Step 4: Edit and stage**

Apply the necessary edits with the Edit tool. Do **not** prompt the user via `AskUserQuestion` — the auto-fix is mandatory per Issue #485 MUST NOT constraints. Stage the edited documentation files together with the implementation changes.

##### Result Handling

| Result | Action |
|--------|--------|
| 0 hits across all keywords | Proceed silently to 5.1.1 (no warning, no extra commit) |
| Stale docs detected and auto-fixed | Stage the edited documentation files and proceed to 5.1.1 — the documentation edits are committed in the **same** commit as the implementation. (Note: 5.1.0.7 always runs **before** 5.1.1 in the normal flow, so the implementation is never already committed at this point.) |
| Search command failed (Grep tool error, etc.) | Display warning `WARNING: ドキュメント影響調査でエラー: {error}. ステップをスキップして実装フェーズを継続します` and proceed to 5.1.1 — do NOT block the flow |

##### Constraints

- **MUST NOT** invoke `AskUserQuestion` from this step
- **MUST NOT** defer detected drift to a separate Issue (this contradicts `issue_accountability` and the Issue #485 MUST NOT constraints)
- **MUST NOT** modify files outside documentation (no code changes triggered by this step)
- **MUST NOT** modify `plugins/rite/skills/reviewers/**`, `plugins/rite/hooks/**`, or `rite-config.yml` from this step — those are out of scope for documentation impact investigation

### 5.1.1 Commit and Push Changes

After implementation is complete, push changes to remote:

**Commit procedure:**

1. Check changed files with `git status`
2. Stage changes with `git add`
3. Generate commit message in Conventional Commits format
4. Commit with `git commit`
5. Push to remote with `git push -u origin {branch_name}`

**Commit message generation:**

> **⚠️ CRITICAL**: The `description` part of the commit message **MUST** follow the `language` setting in `rite-config.yml`. The examples below are for reference only — always generate the description in the language determined by the setting, not by copying the example language.

Generated based on Issue title and implementation content:
- Format: `{type}({scope}): {description}`
- Examples:
  - English: `feat(issue): add end-to-end workflow support`
  - Japanese: `feat(issue): Issue一気通貫ワークフローを追加`

**Commit message language:**

Follow the `language` setting in `rite-config.yml` (`auto`: detect user input language, `ja`: Japanese, `en`: English). For `auto`, determine by presence of Japanese characters (hiragana, katakana, kanji). type/scope are always in English.

**Commit body:**

> **Reference**: [Contextual Commits Reference](../../skills/rite-workflow/references/contextual-commits.md) for action line specification, mapping tables, output rules, and scope derivation.

Check `commit.contextual` in `rite-config.yml` to determine the commit body format.

**When `commit.contextual: true` (default):**

Generate structured action lines in the commit body following the Contextual Commits format. This embeds decision records directly in git history.

- Leave a blank line between the description line and the action lines
- Can be omitted for trivial changes (typo fixes, formatting, dependency bumps, etc.)

**Generation procedure:**

1. **Read work memory**: Extract from `決定事項・メモ`, `計画逸脱ログ`, `要確認事項` sections (Priority 1 — highest reliability)
2. **Extract from Issue body**: Derive `intent` from Issue purpose/motivation, `constraint` from acceptance criteria and technical restrictions (Priority 2)
3. **Infer from diff**: When the diff shows clear technical choices (new dependencies, library switches, API design), infer `decision` (Priority 3 — use only when evident)
4. **Apply mapping table**: Map each extracted item to action types using the [Work Memory → Action Line Mapping](../../skills/rite-workflow/references/contextual-commits.md#work-memory--action-line-mapping) table
5. **Filter to 10-line limit**: If action lines exceed 10, trim in order: `learned` → `constraint` → `rejected` → `decision` → `intent` (intent is preserved last as the core "why")

**Output rules:**
- Action type names are always in English (`intent`, `decision`, `rejected`, `constraint`, `learned`)
- Description follows the `language` setting in `rite-config.yml`
- Do not repeat information already visible in the diff
- Do not fabricate action lines without evidence from work memory, Issue body, or diff
- Conversation context is supplementary only (Priority 4 — lowest, lost after `/clear`)

**Example (language: ja):**

```
feat(commit): implement.md のコミット body に Contextual Commits を追加

intent(commit): コミット履歴に意思決定の永続記録を埋め込み、セッション消失後も判断理由を参照可能にする
decision(format): Conventional Commits の subject line を維持し body のみ拡張（既存ツールチェーンとの互換性）
constraint(body): アクションライン最大10行（コミットメッセージの肥大化防止）
```

**When `commit.contextual: false`:**

Use free-form commit body. Include the reason for the change ("why") in the commit body.

- Leave a blank line between the description line and the body
- Write in free-form — no specific prefix or template required
- Focus on "why" the change was needed, not "what" was changed (the description line already covers "what")
- Follow the same language setting as the description line
- Can be omitted for trivial changes (typo fixes, formatting, etc.)

```bash
git add .
git commit -m "$(cat <<'EOF'
{commit_message}
EOF
)"
git push -u origin {branch_name}
```

**Note**: Commit and push must be completed before invoking `/rite:pr:create`.

#### 5.1.1.1 Issue Body Checklist Update

**Execution condition**: Execute only when Issue body checklist was extracted and retained in Phase 3.6.

**Update as each task is completed**. Immediately update the Issue body checklist as implementation, test, and documentation tasks are completed.

**Update trigger:** After `git commit` succeeds and at Phase 5.1 completion, Claude determines the relevance between changed files and checklist items, and updates `[ ]` to `[x]` for completed items.

> **⚠️ 注意**: `--body "$var"` による直接更新は body 消失のリスクがあるため禁止。必ず `--body-file` + 一時ファイルパターンを使用すること。

**Update procedure** (3-step safe update pattern):

Execute in 3 stages (Bash → Read+Write → Bash). Since `trap` is only effective within the same process, all sub-steps in Step 1 must be executed within the same Bash tool call. On any validation failure, output a WARNING and skip remaining steps (do NOT `exit 1` — subsequent phase processing must continue).

**Step 1: Bash tool call — Fetch body and validate**

```bash
bash {plugin_root}/hooks/issue-body-safe-update.sh fetch --issue {issue_number}
```

Outputs: `tmpfile_read=<path>`, `tmpfile_write=<path>`, `original_length=<n>`. If fetch fails, outputs WARNING and exits 0 (skip).

**Step 2: Read tool + Write tool — Write checkbox-updated body**

1. Read the contents of `$tmpfile_read` (path output in Step 1) using Claude Code's Read tool
2. Create the full text with `[ ]` → `[x]` updates based on the read content
3. Write the updated body to `$tmpfile_write` (path output in Step 1) using Claude Code's Write tool

> Partial content causes the entire Issue body to be replaced with a fragment, losing all other sections (description, acceptance criteria, etc.).
> **CRITICAL**: The Write tool output MUST contain the ENTIRE Issue body with only checkbox changes. Never output partial content or only the changed lines.

**Step 3: Bash tool call — Validate and apply**

```bash
bash {plugin_root}/hooks/issue-body-safe-update.sh apply --issue {issue_number} \
  --tmpfile-read "{tmpfile_read}" --tmpfile-write "{tmpfile_write}" \
  --original-length {original_length}
```

Replace `{tmpfile_read}`, `{tmpfile_write}`, `{original_length}` with the values output in Step 1. Validates body length (rejects <50% shrinkage), applies via `--body-file`, and cleans up temp files.

Also synchronize the "Issue checklist" section in the work memory.

#### 5.1.1.2 Work Memory Progress Summary and Changed Files Update

**Execution condition**: Execute after commit and push succeed, when on a work branch with an Issue number (`issue-{n}` pattern).

**Purpose**: Update the progress summary table, implementation plan step statuses (`状態` column), and changed files section in the Issue work memory comment to reflect the actual implementation state. This ensures these sections are not left in their initial "⬜ 未着手" / "_まだ変更はありません_" state after implementation completes.

**Step 1: Determine progress summary statuses**

Analyze the committed changes to determine the status of each progress item:

```bash
# ベースブランチからの変更ファイル一覧を取得
diff_files=$(git diff --name-only origin/{base_branch}...HEAD 2>/dev/null)
```

Claude determines statuses based on `diff_files`:
- **実装**: `✅ 完了` (implementation is complete since we are at the commit stage)
- **テスト**: `✅ 完了` if test files (*.test.*, *.spec.*, test_*, tests/**) exist in `diff_files`, otherwise `⬜ 未着手`
- **ドキュメント**: `✅ 完了` if documentation files (*.md in docs/, README.md, CHANGELOG.md, API.md, etc.) exist in `diff_files`, otherwise `⬜ 未着手`

**Step 2: Generate changed files list**

Format the changed files from `git diff --name-status origin/{base_branch}...HEAD`:

```markdown
- `path/to/file1.md` - 変更
- `path/to/file2.md` - 変更
```

Status mapping: `A` → 追加, `M` → 変更, `D` → 削除, `R` → 名前変更.

**Step 3: Update Issue work memory comment**

Generate a changed files list and write it to a temp file, then invoke the sync script:

```bash
# Step 3a: 変更ファイルリスト生成
changed_files_tmp=$(mktemp)
trap 'rm -f "$changed_files_tmp"' EXIT
git diff --name-status origin/{base_branch}...HEAD 2>/dev/null | while IFS=$'\t' read status file; do
  case "$status" in A) echo "- \`$file\` - 追加";; M) echo "- \`$file\` - 変更";; D) echo "- \`$file\` - 削除";; R*) echo "- \`$file\` - 名前変更";; esac
done > "$changed_files_tmp" || true

# Step 3b: 進捗サマリー + 変更ファイル更新
bash {plugin_root}/hooks/issue-comment-wm-sync.sh update \
  --issue {issue_number} \
  --transform update-progress \
  --impl-status "{impl_status}" --test-status "{test_status}" --doc-status "{doc_status}" \
  --changed-files-file "$changed_files_tmp" \
  2>/dev/null || true

# Step 3c: 実装計画ステップ ⬜ → ✅ 一括更新
bash {plugin_root}/hooks/issue-comment-wm-sync.sh update \
  --issue {issue_number} \
  --transform update-plan-status \
  2>/dev/null || true

rm -f "$changed_files_tmp"
```

**Placeholder substitution**: Claude MUST replace `{impl_status}`, `{test_status}`, `{doc_status}` with the actual status strings determined in Step 1 (e.g., `"✅ 完了"`, `"⬜ 未着手"`). All other `{...}` placeholders follow the standard placeholder legend.

**On failure**: The script outputs WARNING on stderr and exits 0 (non-blocking). The progress update is best-effort; `.rite-flow-state` is the primary state record.

#### 5.1.1.3 Local Work Memory Update

**Execution condition**: Execute when on a work branch with an Issue number (`issue-{n}` pattern).

After commit and push, update the local work memory file to record the phase transition to lint. Uses `mkdir` lock for concurrent access safety with pre-compact hook.

Use the self-resolving wrapper. See [Work Memory Format - Usage in Commands](../../skills/rite-workflow/references/work-memory-format.md#usage-in-commands) for details and marketplace install notes.

```bash
WM_SOURCE="implement" \
  WM_PHASE="phase5_lint" \
  WM_PHASE_DETAIL="品質チェック準備" \
  WM_NEXT_ACTION="rite:lint を実行" \
  WM_BODY_TEXT="Post-implementation. Proceeding to lint." \
  WM_ISSUE_NUMBER="{issue_number}" \
  bash {plugin_root}/hooks/local-wm-update.sh 2>/dev/null || true
```

**On lock failure**: Log a warning (`rite: implement: local work memory lock failed`) and continue — local work memory update is best-effort. The `.rite-flow-state` update (step 4a) is the primary state record.

#### 5.1.2 Parent Issue Progress Update (only when working on child Issue)

**Execution condition**: Execute only when `parent_issue_number` is non-zero. Read deterministically via `state-read.sh` (#497 — survives context compaction; Issue #687 AC-4 — per-session state, not legacy snapshot):

```bash
parent_issue_number=$(bash {plugin_root}/hooks/state-read.sh --field parent_issue_number --default 0)
# Type validation (PR #688 cycle 5 review security LOW followup): non-numeric injection 経路を遮断
case "$parent_issue_number" in
  ''|*[!0-9]*)
    echo "WARNING: parent_issue_number is not numeric ('$parent_issue_number'), defaulting to 0 (no parent)" >&2
    parent_issue_number=0
    ;;
esac
if [ "$parent_issue_number" -eq 0 ] 2>/dev/null; then
  echo "[CONTEXT] PARENT_ISSUE=none — skip 5.1.2"
else
  echo "[CONTEXT] PARENT_ISSUE=$parent_issue_number — execute 5.1.2"
fi
```

Skip this section when `PARENT_ISSUE=none`.

**5.1.2.1 Tasklist Update**

Update the relevant child Issue's `- [ ]` to `- [x]` in the `## Sub-Issues` section of the parent Issue body.

> **⚠️ 注意**: `--body "$var"` による直接更新は body 消失のリスクがあるため禁止。必ず `--body-file` + 一時ファイルパターンを使用すること。

Execute in 3 stages (Bash → Read+Write → Bash). On any validation failure, output a WARNING and skip remaining steps (do NOT `exit 1` — subsequent phase processing must continue).

**Step 1: Bash tool call — Fetch parent Issue body and validate**

```bash
# Create temp files (for reading and writing)
tmpfile_read=$(mktemp)
tmpfile_write=$(mktemp)
trap 'rm -f "$tmpfile_read" "$tmpfile_write"' EXIT

gh issue view {parent_issue_number} --json body --jq '.body' > "$tmpfile_read"

# Validate retrieval result
if [ ! -s "$tmpfile_read" ]; then
  echo "WARNING: Parent Issue body の取得に失敗。タスクリスト更新をスキップします" >&2
  exit 0  # Skip — do not abort workflow
fi

# Record original length for Step 3 comparison
original_length=$(wc -c < "$tmpfile_read")
echo "original_length=$original_length"

# Output mktemp paths for use in subsequent Read/Write tool calls
echo "tmpfile_read=$tmpfile_read"
echo "tmpfile_write=$tmpfile_write"
```

**Step 2: Read tool + Write tool — Write tasklist-updated body**

1. Read the contents of `$tmpfile_read` (path output by `mktemp` in Step 1) using Claude Code's Read tool
2. In the `## Sub-Issues` section only, update the relevant child Issue's `- [ ]` to `- [x]`. Do not modify other sections
3. Write the updated body to `$tmpfile_write` (another path output by `mktemp` in Step 1) using Claude Code's Write tool

> **CRITICAL**: The Write tool output MUST contain the ENTIRE parent Issue body with only the `## Sub-Issues` section checkbox change. Never output partial content or only the changed lines.

**Step 3: Bash tool call — Validate and apply**

```bash
# Set paths output by mktemp in Step 1 (shell variables do not carry over between Bash tool calls, so directly write the actual paths from Step 1 output)
tmpfile_read="/tmp/tmp.XXXXXXXXXX"   # ← Replace with the tmpfile_read= value from Step 1 output
tmpfile_write="/tmp/tmp.XXXXXXXXXX"  # ← Replace with the tmpfile_write= value from Step 1 output
original_length=XXXXX                # ← Replace with the original_length= value from Step 1 output

# Validate update content before applying
if [ ! -s "$tmpfile_write" ]; then
  echo "WARNING: 更新内容が空。タスクリスト更新をスキップします" >&2
  rm -f "$tmpfile_read" "$tmpfile_write"
  exit 0  # Skip — do not abort workflow
fi

# Body length comparison safety check (reject if updated body is less than 50% of original)
updated_length=$(wc -c < "$tmpfile_write")
if [[ "${updated_length:-0}" -lt $(( ${original_length:-1} / 2 )) ]]; then
  echo "WARNING: 更新後の body が元の50%未満 (${updated_length}/${original_length})。body 消失の可能性があるためスキップします" >&2
  rm -f "$tmpfile_read" "$tmpfile_write"
  exit 0  # Skip — do not abort workflow
fi

gh issue edit {parent_issue_number} --body-file "$tmpfile_write"

# trap does not carry over between processes (Bash tool calls), so delete explicitly
rm -f "$tmpfile_read" "$tmpfile_write"
```

**5.1.2.2 Progress Comment Addition**

Record progress in a comment on the parent Issue (completed child Issues, progress status, suggest next candidates when 1-3 remain).

**5.1.2.3 Remaining Child Issues Check**

Check the state of remaining child Issues with `trackedIssues` and calculate `remaining_count`. Full child Issue completion check is performed in Phase 5.7.

**After 5.1.1 commit/push completion:**

1. Parent Issue progress update (only when working on child Issue, see 5.1.2)
2. **Update work memory** (record phase info, changed files, next steps)
3. **Update local work memory** (`.rite-work-memory/issue-{n}.md`) — see 5.1.1.3 above
4. **CRITICAL: Initialize `.rite-flow-state` and invoke lint** (atomic pair - MUST execute both):

   > **Note**: All `.rite-flow-state` writes use `flow-state-update.sh` which handles atomic write (PID-based temp file + `mv`) internally to prevent race conditions with concurrent hook shell processes (stop-guard, pre-compact).

   **4a**: Create state file:

   ```bash
   bash {plugin_root}/hooks/flow-state-update.sh create \
     --phase "phase5_lint" --issue {issue_number} --branch "{branch_name}" \
     --pr 0 \
     --next "After rite:lint returns: [lint:success/skipped]->Phase 5.2.1 (checklist). [lint:error]->fix and re-invoke. [lint:aborted]->Phase 5.6. Do NOT stop."
   ```

   **4b**: **Immediately** invoke `rite:lint` via Skill tool (following the flow continuation principle, stopping is prohibited)

### Mandatory Action After Phase 5.1.1 Completion (Absolute Requirement)

> **Warning**: Stopping without executing the following actions is prohibited.
>
> 1. Confirm that commit and push succeeded
> 2. **Immediately** invoke `rite:lint` via Skill tool
> 3. Do NOT stop and guide the user with "Next steps"

**Flow verification check (must confirm at Phase 5.1.1 completion):**
- [ ] Commit complete
- [ ] Push complete
- [ ] **Next action**: Invoke `rite:lint` via Skill tool (**execute now**)
