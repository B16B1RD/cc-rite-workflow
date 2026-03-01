---
description: Issue の作業を開始（ブランチ作成 → 実装 → PR 作成まで一気通貫）
---

# /rite:issue:start

End-to-end Issue workflow: branch → implementation → quality check → PR → review/fix loop.

**Flow:** Branch setup → plan → implementation → `/rite:lint` → `/rite:pr:create` → `/rite:pr:review` + `/rite:pr:fix` loop. Skills output machine-readable patterns; `/rite:issue:start` orchestrates next actions. See Phase 5.

---

## Responsibility Matrix

This table clarifies responsibility boundaries between `start.md`, `create.md`, and `implementation-plan.md`.

| Responsibility | `start.md` | `create.md` | `implementation-plan.md` |
|----------------|:----------:|:-----------:|:------------------------:|
| **Issue quality validation** | ✅ Primary (Phase 1) | — | — |
| **Parent Issue detection** | ✅ Phase 0.3 | — | — |
| **Duplicate detection** | — | ✅ Phase 0.3 | — |
| **Issue specification (What/Why/Where)** | — | ✅ Primary (Phase 0-0.7) | — |
| **Specification document generation** | — | ✅ Phase 0.7 (high-level design) | — |
| **Detailed implementation plan (How)** | — | — | ✅ Phase 3 (step-by-step) |
| **Branch creation + work start** | ✅ Phase 2-5 | — | — |
| **Issue creation + Projects registration** | — | ✅ Phase 2 | — |

**Key distinction — Phase 0.3 overlap resolution:**
- `start.md` Phase 0.3: **Parent Issue Auto-Detection** — trackedIssues, body tasklist, label-based parent detection
- `create.md` Phase 0.3: **Similar Issue Search** — duplicate detection, context gathering, extension opportunity detection

---

Execute phases sequentially.

## Arguments

| Argument | Description |
|----------|-------------|
| `<issue_number>` | Issue number to start working on (required) |

---

## Placeholder Legend

How to obtain the placeholders used in this document:

| Placeholder | Description | How to Obtain |
|-------------|-------------|---------------|
| `{issue_number}` | Issue number | From the argument |
| `{owner}` | Repository owner | `gh repo view --json owner --jq '.owner.login'` |
| `{repo}` | Repository name | `gh repo view --json name --jq '.name'` |
| `{base_branch}` | Base branch name | `branch.base` in `rite-config.yml` (defaults to `main` if not set). Obtained in Phase 2.3.1 |
| `{fallback_branch}` | Fallback branch | Determined in Phase 2.3.2.3 Step 1 (`main` preferred, default branch if `main` doesn't exist). **Scope**: Phase 2.3.2.3 only |
| `{default_branch}` | Repository default branch | Obtained via `gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name'` in Phase 2.3.2.3 Step 1 when `main` doesn't exist. **Scope**: Phase 2.3.2.3 only |
| `{project_number}` | GitHub Projects project number | From `github.projects.project_number` in `rite-config.yml` (read via Read tool before Phase 1.5.4.6 Step 1 first execution, retain in context). Used from Phase 1.5.4.6 onward |
| `{project_id}` | GitHub Projects project ID (GraphQL Node ID) | From Phase 1.5.4.6 Step 2 GraphQL query (`projectV2.id`). Obtained only once, reused in subsequent steps and child Issues. Also used in Phase 2.4.2 (parent Issue Projects registration), also obtained in Phase 5.5.1 Step 1, Phase 5.2.0.1 Step 3, and Phase 5.7.2 Step 1 |
| `{sub_issue_url}` | URL of the created child Issue | From the stdout of `gh issue create` in Phase 1.5.4.5 |
| `{parent_issue_number}` | Parent Issue number | Same as `{issue_number}` of the Issue being evaluated for decomposition in Phase 1.5.4 |
| `{item_id}` | Item ID on GitHub Projects | From Phase 1.5.4.6 Step 2 GraphQL query result, the `id` of the node whose `content.number` matches the child Issue. Also obtained in Phase 5.5.1 Step 1, Phase 5.2.0.1 Step 3, and Phase 5.7.2 Step 1 |
| `{plugin_root}` | Absolute path to the plugin root directory | [Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script) (Phase 4.1, 5.0, 5.6) |
| `{status_field_id}` | Status field ID on GitHub Projects | From `github.projects.field_ids.status` in `rite-config.yml`, or from `gh project field-list` result. Used in Phase 2.4.4, 5.5.1, 5.7.2 |
| `{in_review_option_id}` | "In Review" option ID for the Status field | From `gh project field-list` result (the option with `name` "In Review"). Used in Phase 5.5.1 |
| `{done_option_id}` | "Done" option ID for the Status field | From `gh project field-list` result (the option with `name` "Done"). Used in Phase 5.7.2 Step 2 |

Retrieve `{owner}` and `{repo}` before Phase 0.1: `gh repo view --json owner,name --jq '{owner: .owner.login, repo: .name}'`

---

## Phase 0: Epic/Sub-Issues Detection

### 0.1 Fetch Issue Information

```bash
gh issue view {issue_number} --json number,title,body,state,labels,milestone,projectItems
```

### 0.2 Milestone Check

If Milestone associated, display: `この Issue は Milestone "{milestone_name}" に含まれています。Milestone には他に {count} 件の Issue があります。この Issue から作業を開始しますか？`

### 0.3 Parent Issue Auto-Detection

> **Reference**: [Epic/Parent Issue Detection](../../references/epic-detection.md) for complete logic/queries.

Determine parent Issue via: (1) trackedIssues API (GraphQL), (2) Body tasklist (`- [ ] #XX`), (3) Labels (`epic`/`parent`/`umbrella`). If **any** match, it's a parent (OR).

Follow [Complete Detection Flow](../../references/epic-detection.md#complete-detection-flow) with [Basic Query](../../references/epic-detection.md#basic-query).

**Save context**: `is_parent_issue` (true/false), `has_sub_issues`, `parent_issue_reason` (trackedIssues/tasklist/label:{name}/null). Retain `trackedIssues.nodes` for Phase 1.5/1.6.

**Display when children exist**:
```
この Issue には {count} 件の子 Issue があります:
| # | タイトル | 状態 |
| #{number} | {title} | {state} |
```

Phase 0.3 detects only; selection in Phase 1.5.

---

## Phase 1: Issue Quality Validation

> **Reference**: Apply `confusion_management` from [AI Coding Principles](../../skills/rite-workflow/references/coding-principles.md).

### 1.1 Quality Score

| Score | Conditions |
|-------|------------|
| **A** | What/Why/Where/Scope all specified |
| **B** | What/Why clear, Where/Scope inferable |
| **C** | Only What clear, details lacking |
| **D** | <20 words body OR What/Why/Where all unclear |

### 1.2 Check Items

What (required), Why/Where/Scope/Acceptance (recommended).

### 1.3 Score C/D Handling

Use `AskUserQuestion`:
```
Issue #{number} の情報を補完してください。
現在の情報: {title}, {body_preview}
不足: {missing_items}
質問: この Issue で具体的に何を達成しますか？
オプション: 既存の情報で作業開始（自分で判断）/ 情報を追加してから開始 / Issue を編集してから再度実行
```

---

## Phase 1.5: Parent Issue Routing

Execute after Phase 1.1-1.3.

**Pre-write** (before invoking `rite:issue:parent-routing`): Update `.rite-flow-state` so stop-guard can resume flow if interrupted:

```bash
TMP_STATE=".rite-flow-state.tmp.$$"
# branch is empty here — not yet created; populated after rite:issue:branch-setup completes in Phase 2.3
jq -n \
  --argjson active true \
  --argjson issue {issue_number} \
  --arg branch "" \
  --arg phase "phase1_5_parent" \
  --argjson loop 0 \
  --argjson pr 0 \
  --arg next "After rite:issue:parent-routing returns: proceed to Phase 1.6 (child issue selection) if applicable, then Phase 2. Do NOT stop." \
  --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")" \
  '{active: $active, issue_number: $issue, branch: $branch, phase: $phase, loop_count: $loop, pr_number: $pr, next_action: $next, updated_at: $ts}' \
  > "$TMP_STATE" && mv "$TMP_STATE" .rite-flow-state || rm -f "$TMP_STATE"
```

> **Module**: [Parent Issue Routing](./parent-routing.md) - Handles: detection (1.5.1), child state/Projects retrieval (1.5.2-1.5.3), decomposition (1.5.4.1-1.5.4.6), auto-close (1.5.5).

Invoke `skill: "rite:issue:parent-routing"`.

### 🚨 Mandatory After 1.5

Do **NOT** stop after `rite:issue:parent-routing` returns. Proceed to the next phase immediately after the sub-skill returns. **→ Proceed to Phase 1.6 (if child issues exist) or Phase 2 now**.

## Phase 1.6: Child Issue Selection

**Pre-write** (before invoking `rite:issue:child-issue-selection`): Update `.rite-flow-state` so stop-guard can resume flow if interrupted:

```bash
TMP_STATE=".rite-flow-state.tmp.$$"
# branch is empty here — not yet created; populated after rite:issue:branch-setup completes in Phase 2.3
jq -n \
  --argjson active true \
  --argjson issue {issue_number} \
  --arg branch "" \
  --arg phase "phase1_6_child" \
  --argjson loop 0 \
  --argjson pr 0 \
  --arg next "After rite:issue:child-issue-selection returns: proceed to Phase 2 (work preparation). Do NOT stop." \
  --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")" \
  '{active: $active, issue_number: $issue, branch: $branch, phase: $phase, loop_count: $loop, pr_number: $pr, next_action: $next, updated_at: $ts}' \
  > "$TMP_STATE" && mv "$TMP_STATE" .rite-flow-state || rm -f "$TMP_STATE"
```

> **Module**: [Child Issue Selection](./child-issue-selection.md) - Automatic child selection with priority logic, dependencies, user confirmation.

Invoke `skill: "rite:issue:child-issue-selection"`.

### 🚨 Mandatory After 1.6

Do **NOT** stop after `rite:issue:child-issue-selection` returns. Proceed to the next phase immediately after the sub-skill returns. **→ Proceed to Phase 2 now**.

---

## Phase 2: Work Preparation

### 2.1 Branch Name Generation

Follow `rite-config.yml` pattern `{type}/issue-{number}-{slug}`. Type from labels/title: `bug`/`bugfix`→`fix`, `docs`→`docs`, `refactor`→`refactor`, `chore`/`maintenance`→`chore`, else→`feat`. Slug: lowercase title, spaces→hyphens, max 30 chars.

### 2.2 Existing Branch Check

```bash
local_match=$(git branch --list "{branch_name}")
remote_match=$(git branch -r --list "origin/{branch_name}")
```

**Determination**: Check the **output** of each command (NOT the exit code). `git branch --list` always returns exit code 0 regardless of match. If `local_match` or `remote_match` is non-empty, the branch exists.

If exists: `ブランチ {branch_name} は既に存在します。オプション: 既存ブランチに切り替え / 別名でブランチを作成（サフィックス追加）/ キャンセル`

#### 2.2.1 Recognized Patterns

If `branch.recognized_patterns` in rite-config.yml, detect non-Issue-numbered branches. Execute 2.2.1 only after 2.2 finds nothing.

**Pattern→regex**: `{n}`→`[0-9]+`, `{category}`/`{description}`→`[a-z0-9-]+`, `{locale}`→`[a-z]{2}(-[a-z]{2})?`, `{date}`→`[0-9-]+`, `{*}`→`.+`. Add `^...$` anchors.

**On match**: Display `既存ブランチ {branch_name} を検出しました。（パターン: {matched_pattern}）このブランチは Issue 番号を含まないため、Issue #{issue_number} との紐付けは手動で行う必要があります。オプション: このブランチで作業を開始（Issue との紐付けなし）/ 標準パターンで新しいブランチを作成 / キャンセル`

Skip Phase 2.4/2.5/2.6 (no Issue number). User manually links. Phase 3+ normal.

### 2.3 Branch Creation

**Pre-write** (before invoking `rite:issue:branch-setup`): Update `.rite-flow-state` so stop-guard can resume flow if interrupted:

```bash
TMP_STATE=".rite-flow-state.tmp.$$"
jq -n \
  --argjson active true \
  --argjson issue {issue_number} \
  --arg branch "{branch_name}" \
  --arg phase "phase2_branch" \
  --argjson loop 0 \
  --argjson pr 0 \
  --arg next "After rite:issue:branch-setup returns: proceed to Phase 2.4 (Projects Status update to In Progress). Do NOT stop." \
  --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")" \
  '{active: $active, issue_number: $issue, branch: $branch, phase: $phase, loop_count: $loop, pr_number: $pr, next_action: $next, updated_at: $ts}' \
  > "$TMP_STATE" && mv "$TMP_STATE" .rite-flow-state || rm -f "$TMP_STATE"
```

> **Module**: [Branch Setup](./branch-setup.md) - Creates branch from `branch.base`, handles fallback when base doesn't exist.

Invoke `skill: "rite:issue:branch-setup"`.

### 🚨 Mandatory After 2.3

Do **NOT** stop after `rite:issue:branch-setup` returns. Proceed to the next phase immediately after the sub-skill returns. **→ Proceed to Phase 2.4 now**.

### 2.4 GitHub Projects Status Update

> **Module**: [Projects Integration](../../references/projects-integration.md#24-github-projects-status-update)

Skip if `projects.enabled: false` in rite-config.yml. Otherwise: get item ID, update Status to "In Progress", auto-add if not registered. Handles: config (2.4.1), registration check (2.4.2), auto-add (2.4.3), Status field with field_ids optimization (2.4.4), Status update (2.4.5), parent Status (2.4.7).

### 2.5 Iteration Assignment

> **Module**: [Projects Integration](../../references/projects-integration.md#25-iteration-assignment-optional)

Execute only if `iteration.enabled: true` and `iteration.auto_assign: true` in rite-config.yml. Skip if `projects.enabled: false`. Handles: field info (2.5.1), current determination (2.5.2), assignment (2.5.3), result/warning (2.5.4).

### 2.6 Work Memory Initialization

**Pre-write** (before invoking `rite:issue:work-memory-init`): Update `.rite-flow-state` so stop-guard can resume flow if interrupted:

```bash
TMP_STATE=".rite-flow-state.tmp.$$"
jq -n \
  --argjson active true \
  --argjson issue {issue_number} \
  --arg branch "{branch_name}" \
  --arg phase "phase2_work_memory" \
  --argjson loop 0 \
  --argjson pr 0 \
  --arg next "After rite:issue:work-memory-init returns: proceed to Phase 3 (implementation plan). Do NOT stop." \
  --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")" \
  '{active: $active, issue_number: $issue, branch: $branch, phase: $phase, loop_count: $loop, pr_number: $pr, next_action: $next, updated_at: $ts}' \
  > "$TMP_STATE" && mv "$TMP_STATE" .rite-flow-state || rm -f "$TMP_STATE"
```

> **Module**: [Work Memory Initialization](./work-memory-init.md) - Initializes Issue comment with progress summary, confirmation items, session info. Format: [Work Memory Format](../../skills/rite-workflow/references/work-memory-format.md).

Invoke `skill: "rite:issue:work-memory-init"`.

### 🚨 Mandatory After 2.6

Defense-in-depth: verify local work memory was created. If the sub-skill skipped it, create via fallback:

```bash
if [ ! -f ".rite-work-memory/issue-{issue_number}.md" ]; then
  WM_SOURCE="init" WM_PHASE="phase2" WM_PHASE_DETAIL="ブランチ作成・準備" \
    WM_NEXT_ACTION="実装計画を生成" \
    WM_BODY_TEXT="Work memory initialized (fallback). Issue #{issue_number} の作業を開始しました。" \
    WM_ISSUE_NUMBER="{issue_number}" \
    bash plugins/rite/hooks/local-wm-update.sh 2>/dev/null || true
fi
```

Do **NOT** stop after `rite:issue:work-memory-init` returns. Proceed to the next phase immediately after the sub-skill returns. **→ Proceed to Phase 3 now**.

## Phase 3: Implementation Plan

**Pre-write** (before invoking `rite:issue:implementation-plan`): Update `.rite-flow-state` so stop-guard can resume flow if interrupted:

```bash
TMP_STATE=".rite-flow-state.tmp.$$"
jq -n \
  --argjson active true \
  --argjson issue {issue_number} \
  --arg branch "{branch_name}" \
  --arg phase "phase3_plan" \
  --argjson loop 0 \
  --argjson pr 0 \
  --arg next "After rite:issue:implementation-plan returns: proceed to Phase 4 (work start guidance). Do NOT stop." \
  --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")" \
  '{active: $active, issue_number: $issue, branch: $branch, phase: $phase, loop_count: $loop, pr_number: $pr, next_action: $next, updated_at: $ts}' \
  > "$TMP_STATE" && mv "$TMP_STATE" .rite-flow-state || rm -f "$TMP_STATE"
```

> **Module**: [Implementation Plan Generation](./implementation-plan.md) - Analyzes Issue, identifies files, generates plan, gets user confirmation, records to work memory, updates Issue body checklist.

Invoke `skill: "rite:issue:implementation-plan"`.

### 🚨 Mandatory After 3

Do **NOT** stop after `rite:issue:implementation-plan` returns. Proceed to the next phase immediately after the sub-skill returns. **→ Proceed to Phase 4 now**.

---

## Phase 4: Work Start Guidance

### 4.1 Completion Report

Read `{plugin_root}/templates/completion-report.md` with Read tool. Resolve `{plugin_root}` per [Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script). Use "Work start format (for Phase 4.1)" section as-is. Fallback: inline equivalent (Issue info, branch, progress table).

### 4.2 Project-Specific Guidance

Based on `project.type` in rite-config.yml: webapp→Frontend/backend/DB areas, library→Breaking changes/API impact, cli→Command interface/compatibility, documentation→Structure/links, generic→none.

### 4.3 Continuation

Use `AskUserQuestion`: `作業の準備が整いました。どうしますか？ オプション: 実装を開始する（推奨）/ 後で作業する`

Start→Phase 5 (end-to-end). Later→terminate, resume via Phase 2.2.

---

## Phase 5: End-to-End Execution

### Context Management

> **Reference**: [Review Context Optimization](../pr/references/review-context-optimization.md)

**Pressure detection (heuristics)**:
- Tool calls >50 → diff optimization
- Read >5000 lines or >10 files → omit unnecessary info
- diff >2000 → file splitting in review
- Loop ≥2 → verification mode (if `review.loop.verification_mode: true`)
- Loop >3 → history summarization + MEDIUM/LOW relaxation

Count: Tool results in history (parallel=1). Read=sum max line numbers. Changed=additions+deletions.

**Optimizations**: Verification mode (cycle 2+, previous fix + incremental diff), per-file diff, omit error details, summarize loops ("Cycle N: X→fix"), incremental retrieval. Display "⚠️ Context optimization mode".

**Split/termination**:
- Loop limit (`review.loop.max_iterations`, default 7) → convert remaining to Issues
- >50 files → new session recommended
- Multiple features → split Issue

Resume via work memory (`/rite:resume` or `/rite:issue:start`).

### Flow

```
5.0 Stop Hook 確認 → 5.1
5.1 実装・コミット・プッシュ → 5.1.3 安全チェック → rite:lint
5.2 品質チェック → 5.2.1
5.2.1 チェックリスト完了確認 → 全完了なら 5.3 / 未完了なら 5.1
5.3 PR 作成 → 5.4
5.4 レビュー・修正ループ:
  5.4.1 rite:pr:review → [mergeable]→5.5 / [fix-needed]→fix→5.4.1 / [conditional/loop-limit]→fix(別Issue化)→5.5
  (5.4.2-5.4.3 review routing/after, 5.4.5-5.4.6 fix routing/after)
  5.4.4 rite:pr:fix → [pushed]→5.4.1 / [issues-created]→5.4.1 / [replied-only]→5.5 / [error]→処理
5.5 Ready for Review 確認 → 5.5.1 Status 更新 → 5.5.2
5.5.2 メトリクス記録 → 5.6
5.6 完了報告
5.7 親 Issue 完了処理
```

### Preflight Protocol

Each major Phase 5 sub-phase runs a preflight check before execution. The check detects compact-blocked state and prevents execution when recovery is needed:

```bash
bash {plugin_root}/hooks/preflight-check.sh --command-id "/rite:issue:start" --cwd "$(pwd)"
```

If exit code is `1` (blocked), stop execution and display the preflight output. Do NOT proceed.

**Orchestration**: `/rite:issue:start` controls all. Skills output patterns: lint (`[lint:success/skipped/error/aborted]`), create (`[pr:created:{n}/create-failed]`), review (`[review:mergeable/fix-needed/conditional-merge/loop-limit:{n}]`), fix (`[fix:pushed/issues-created/replied-only/error]`).

**Sub-skill return protocol** (defense-in-depth — intentional redundancy with stop-guard stderr):
1. After any sub-skill returns a result pattern, do **NOT** stop responding and do **NOT** re-invoke the same skill — it already completed.
2. **Stop-guard mechanism**: When stop-guard blocks a stop attempt (exit 2), its stderr message is fed back to the assistant. The message prioritizes checking recent skill result patterns before falling back to `next_action` from `.rite-flow-state`. This is normal after sub-skill completion; follow the `ACTION:` instructions in the stderr message to proceed.
3. Each 🚨 Mandatory After section below enforces this protocol at specific transition points.

Invocation: `skill: "rite:lint"` or `skill: "rite:pr:review", args: "67"`

### 5.0 Stop Hook Verification

Before entering the end-to-end flow, verify that the stop-guard hook is registered to prevent flow interruptions when sub-skills return.

**Step 1**: Resolve `{plugin_root}` (if not already resolved in Phase 4.1) per [Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script).

**Step 2**: Read `.claude/settings.local.json` with Read tool. Check if `.hooks.Stop` exists and contains a command matching `bash {plugin_root}/hooks/stop-guard.sh` (full path match to avoid stale path false positives).

**Step 3**: If stop-guard.sh is NOT registered (missing or stale path):

Register all rite hooks by merging the following into `.claude/settings.local.json` (preserve existing non-rite hooks and all other top-level keys like `permissions`):

| Hook Event | Command | Matcher |
|------------|---------|---------|
| Stop | `bash {plugin_root}/hooks/stop-guard.sh` | `""` |
| PreCompact | `bash {plugin_root}/hooks/pre-compact.sh` | `""` |
| SessionStart | `bash {plugin_root}/hooks/session-start.sh` | `""` |
| SessionEnd | `bash {plugin_root}/hooks/session-end.sh` | `""` |
| PreToolUse | `bash {plugin_root}/hooks/post-compact-guard.sh` | `""` |
| PreToolUse | `bash {plugin_root}/hooks/pre-tool-bash-guard.sh` | `"Bash"` |
| PostToolUse | `bash {plugin_root}/hooks/post-tool-wm-sync.sh` | `"Bash"` |
| PostToolUse | `bash {plugin_root}/hooks/context-pressure.sh` | `""` |

Each hook entry uses the format: `{"matcher": "", "hooks": [{"type": "command", "command": "bash {plugin_root}/hooks/{script}"}]}`. For hooks with `"Bash"` matcher, use `{"matcher": "Bash", ...}`. See [init.md Phase 4.5.2](../init.md) for full reference.

**Step 4**: Ensure scripts are executable:

```bash
chmod +x {plugin_root}/hooks/stop-guard.sh {plugin_root}/hooks/pre-compact.sh {plugin_root}/hooks/session-start.sh {plugin_root}/hooks/session-end.sh {plugin_root}/hooks/post-compact-guard.sh {plugin_root}/hooks/pre-tool-bash-guard.sh {plugin_root}/hooks/post-tool-wm-sync.sh {plugin_root}/hooks/context-pressure.sh 2>/dev/null || true
```

If `chmod` fails, display `⚠️ Hook scripts may not be executable. Flow may require manual continuation after sub-skill returns.` If hook registration fails (e.g., file permission error), display the same warning and continue — 🚨 Mandatory After instructions provide textual fallback.

### 5.1 Implementation

Run [Preflight Protocol](#preflight-protocol) before starting implementation.

> **Module**: [Implementation Guidance](./implement.md) - Follow Phase 3 plan. Handles: Read/Edit/Bash, parallel (5.1.0), commit message (5.1.1), checklist update (5.1.1.1), parent progress (5.1.2), `.rite-flow-state`, mandatory `rite:lint` invocation.

**Critical**: After 5.1.1, **immediately** invoke `rite:lint`. Do NOT stop.

#### 5.1.3 Safety Check (Implementation Rounds)

> **Reference**: [Execution Metrics](../../references/execution-metrics.md#safety-thresholds)

Read `safety.max_implementation_rounds` from rite-config.yml (default: 20). Track implementation round count in `.rite-flow-state` via the `implementation_round` field (incremented each time Phase 5.1 is re-entered from 5.2.1 checklist failure).

**Round count tracking**: When re-entering Phase 5.1, update `.rite-flow-state` atomically:

```bash
TMP_STATE=".rite-flow-state.tmp.$$"
jq '.implementation_round = ((.implementation_round // 0) + 1)' .rite-flow-state > "$TMP_STATE" && mv "$TMP_STATE" .rite-flow-state || rm -f "$TMP_STATE"
```

**When round count exceeds limit**:

```
⚠️ 安全装置が発動しました
原因: max_implementation_rounds 超過 ({current_round} > {limit})
```

Present options via `AskUserQuestion`:
- 続行（制限を引き上げ）
- 中止（作業メモリに状態保存）→ Phase 5.6
- 手動介入（ユーザーが直接対応）→ terminate

### 5.2 Quality Check

Run [Preflight Protocol](#preflight-protocol) before invoking lint.

**Pre-check** (defense-in-depth): Always update `.rite-flow-state` before invoking lint to ensure the stop-guard has correct phase and fresh timestamp. This unconditional write prevents stale state from causing intermittent flow stops (fixes #666):

```bash
TMP_STATE=".rite-flow-state.tmp.$$"
jq -n \
  --argjson active true \
  --argjson issue {issue_number} \
  --arg branch "{branch_name}" \
  --arg phase "phase5_lint" \
  --argjson loop 0 \
  --argjson pr 0 \
  --arg next "After rite:lint returns: [lint:success/skipped]->Phase 5.2.1 (checklist). [lint:error]->fix and re-invoke. [lint:aborted]->Phase 5.6. Do NOT stop." \
  --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")" \
  '{active: $active, issue_number: $issue, branch: $branch, phase: $phase, loop_count: $loop, pr_number: $pr, next_action: $next, updated_at: $ts}' \
  > "$TMP_STATE" && mv "$TMP_STATE" .rite-flow-state || rm -f "$TMP_STATE"
```

Invoke `skill: "rite:lint"` after 5.1.

**🚨 Immediate after lint returns**: When `rite:lint` outputs a result pattern and returns control, do **NOT** churn or pause — **immediately** proceed to 🚨 Mandatory After 5.2 below. The lint sub-skill has already updated `.rite-flow-state` to `phase5_post_lint` via Phase 4.0 (defense-in-depth, #716); execute the 🚨 Mandatory After 5.2 steps without delay.

**Results**: `[lint:success/skipped]`→5.2.1→5.3, `[lint:error]`→fix→5.2, `[lint:aborted]`→5.6.

#### 5.2.0.1 Out-of-Scope Warnings

> **Reference**: [Issue Creation with Projects Integration](../../references/issue-create-with-projects.md)

Auto-register lint warnings outside change scope as Issues. Determine via `git diff --unified=0 HEAD` + AI judgment. Group by file, create via the common script (Status: Todo, Priority: Medium, Complexity: S). On failure, add to PR "Known Issues".

**Per-Issue procedure** (execute for each grouped warning):

```bash
tmpfile=$(mktemp)
trap 'rm -f "$tmpfile"' EXIT

cat <<'BODY_EOF' > "$tmpfile"
{warning_body}
BODY_EOF

if [ ! -s "$tmpfile" ]; then
  echo "ERROR: Issue body is empty" >&2
  exit 1
fi

result=$(bash {plugin_root}/scripts/create-issue-with-projects.sh "$(jq -n \
  --arg title "{type}: {summary}" \
  --arg body_file "$tmpfile" \
  --argjson projects_enabled {projects_enabled} \
  --argjson project_number {project_number} \
  --arg owner "{owner}" \
  --arg priority "Medium" \
  --arg complexity "S" \
  '{
    issue: { title: $title, body_file: $body_file },
    projects: {
      enabled: $projects_enabled,
      project_number: $project_number,
      owner: $owner,
      status: "Todo",
      priority: $priority,
      complexity: $complexity,
      iteration: { mode: "none" }
    },
    options: { source: "lint", non_blocking_projects: true }
  }'
)")

if [ -z "$result" ]; then
  echo "ERROR: create-issue-with-projects.sh returned empty result" >&2
  exit 1
fi
new_issue_url=$(printf '%s' "$result" | jq -r '.issue_url')
new_issue_number=$(printf '%s' "$result" | jq -r '.issue_number')
project_reg=$(printf '%s' "$result" | jq -r '.project_registration')
printf '%s' "$result" | jq -r '.warnings[]' 2>/dev/null | while read -r w; do echo "⚠️ $w"; done
```

**On script failure** (`issue_url` is empty): Skip and add to PR "Known Issues" section.

**Embed in PR context**: Ignored errors/skip status retained before 5.3 invocation for PR body "Known Issues" section (`lint エラーが未解決（{error_count}件）...`). See `/rite:lint` "Clarification of responsibilities".

### 🚨 Mandatory After 5.2

**Ignore** `/rite:lint` "Next steps" (standalone only). **Immediately** update `.rite-flow-state` and execute 5.2.1. Follow sub-skill return protocol above.

**Step 1**: Update `.rite-flow-state` to post-lint phase (atomic). This second write (after the Phase 5.2 pre-check write) transitions from `phase5_lint` to `phase5_post_lint`, ensuring stop-guard routes to checklist confirmation rather than re-invoking lint:

```bash
TMP_STATE=".rite-flow-state.tmp.$$"
jq -n \
  --argjson active true \
  --argjson issue {issue_number} \
  --arg branch "{branch_name}" \
  --arg phase "phase5_post_lint" \
  --argjson loop 0 \
  --argjson pr 0 \
  --arg next "Phase 5.2.1: Check Issue checklist completion. All complete->Phase 5.3 PR creation (invoke rite:pr:create). Incomplete->return to Phase 5.1 implementation. Do NOT stop." \
  --arg ts "$(date -u +'%Y-%m-%dT%H:%M:%S+00:00')" \
  '{active: $active, issue_number: $issue, branch: $branch, phase: $phase, loop_count: $loop, pr_number: $pr, next_action: $next, updated_at: $ts}' \
  > "$TMP_STATE" && mv "$TMP_STATE" .rite-flow-state || rm -f "$TMP_STATE"
```

**Step 2**: **→ Proceed to 5.2.1 now**.

### 5.2.1 Checklist Confirmation

**Owner**: `/rite:issue:start` after `/rite:lint` returns. **Condition**: Execute only if checklist retained in Phase 3.6. **Purpose**: Block PR until all items complete.

Use `grep -E` (not `-P`). Pattern per [gh-cli-patterns.md](../../references/gh-cli-patterns.md#safe-checklist-operation-patterns).

```bash
issue_body=$(gh issue view {issue_number} --json body --jq '.body')
[ -z "$issue_body" ] && echo "ERROR: Issue body の取得に失敗" >&2 && exit 1
echo "$issue_body" | grep -E '^- \[[ xX]\] ' | grep -v -E '^- \[[ xX]\] #[0-9]+' || true
echo "$issue_body" | grep -E '^- \[[ xX]\] ' | grep -v -E '^- \[[ xX]\] #[0-9]+' | grep -c '^- \[ \] ' || true
```

**Determine**: `grep -c` output `0`→all complete→5.3. `≥1`→incomplete→display, return 5.1. Empty body→retry 5.1. **Mandatory**, cannot skip.

### 5.3 PR Creation

Run [Preflight Protocol](#preflight-protocol) before creating PR.

After 5.2.1, update `.rite-flow-state` (atomic, see 5.1 step 3):

```bash
TMP_STATE=".rite-flow-state.tmp.$$"
jq -n \
  --argjson active true \
  --argjson issue {issue_number} \
  --arg branch "{branch_name}" \
  --arg phase "phase5_pr" \
  --argjson loop 0 \
  --argjson pr 0 \
  --arg next "After rite:pr:create returns: [pr:created:{N}]->save pr_number, Phase 5.4 (review loop). [pr:create-failed]->Phase 5.6. Do NOT stop." \
  --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")" \
  '{active: $active, issue_number: $issue, branch: $branch, phase: $phase, loop_count: $loop, pr_number: $pr, next_action: $next, updated_at: $ts}' \
  > "$TMP_STATE" && mv "$TMP_STATE" .rite-flow-state || rm -f "$TMP_STATE"
```

> **Data Handoff**: When invoking `rite:pr:create`, include the Issue information retrieved in Phase 0.1 (`number`, `title`, `body`, `labels`) in the Skill prompt to avoid redundant `gh issue view` calls in the child command.

Invoke `skill: "rite:pr:create"`.

**Patterns**: `[pr:created:{number}]`→extract number, proceed 5.4. `[pr:create-failed]`→5.6.

### 🚨 Mandatory After 5.3

**Verify**: `[pr:created:{number}]`, number saved. Follow sub-skill return protocol above. **→ Proceed to 5.4 now**.

### 5.4 Review-Fix Loop

`/rite:issue:start` orchestrates. Read `review.loop.max_iterations` from rite-config.yml (default: 7). Init `loop_count = 0`.

**Local work memory sync rule**: At each phase transition within the review-fix loop (5.4.1, 5.4.3, 5.4.4, 5.4.6), after updating `.rite-flow-state`, also sync `loop_count` and phase to the local work memory file (`.rite-work-memory/issue-{n}.md`). Use the self-resolving wrapper `local-wm-update.sh` with appropriate `WM_*` env vars. See [Work Memory Format - Usage in Commands](../../skills/rite-workflow/references/work-memory-format.md#usage-in-commands) for the recommended pattern.

**Issue comment backup sync rule**: After each review cycle completes (at 5.4.3 and 5.4.6), sync local work memory to the Issue comment as a backup. Use the existing `gh api` PATCH pattern from `fix.md` Phase 4.5.2. This ensures the Issue comment reflects the latest `loop_count` and phase for recovery after context compaction.

#### 5.4.1 Review

Run [Preflight Protocol](#preflight-protocol) before each review cycle.

Update `.rite-flow-state` (atomic, see 5.1 step 3):

```bash
TMP_STATE=".rite-flow-state.tmp.$$"
jq -n \
  --argjson active true \
  --argjson issue {issue_number} \
  --arg branch "{branch_name}" \
  --arg phase "phase5_review" \
  --argjson loop {loop_count} \
  --argjson pr {pr_number} \
  --arg next "After rite:pr:review returns: [review:mergeable]->Phase 5.5. [review:fix-needed:{N}]->Phase 5.4.4. [review:conditional-merge/loop-limit]->Phase 5.4.4 then 5.5. Do NOT stop." \
  --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")" \
  '{active: $active, issue_number: $issue, branch: $branch, phase: $phase, loop_count: $loop, pr_number: $pr, next_action: $next, updated_at: $ts}' \
  > "$TMP_STATE" && mv "$TMP_STATE" .rite-flow-state || rm -f "$TMP_STATE"
```

> **Note**: `{pr_number}` in the `--arg next` is a document placeholder that Claude replaces with the actual PR number at execution time (same as `--argjson pr {pr_number}` above). The `{N}` in result patterns refers to a count value returned by the sub-skill.

> **Data Handoff**: When invoking `rite:pr:review`, the PR number is passed as an argument. Issue information from Phase 0.1 is available in work memory (loaded by `rite:pr:review` Phase 0), avoiding additional `gh issue view` calls.

Invoke `skill: "rite:pr:review"`. Increment `loop_count`.

**🚨 Immediate after review returns**: When `rite:pr:review` outputs a result pattern and returns control, do **NOT** churn or pause — **immediately** proceed to 5.4.3 🚨 After Review below. The review sub-skill has already updated `.rite-flow-state` to `phase5_post_review` via Phase 8.0 (defense-in-depth, #719); execute the 5.4.3 steps without delay.

#### 5.4.2 Review Patterns

`[review:mergeable]`→5.5, `[review:fix-needed:{n}]`→5.4.4, `[review:conditional-merge:{n}]`→5.4.4→5.5, `[review:loop-limit:{n}]`→5.4.4→5.5.

#### 5.4.3 🚨 After Review

**Verify**: Pattern confirmed, parsed. Follow sub-skill return protocol above.

**Step 1**: Update `.rite-flow-state` to post-review phase (atomic). This second write (after the Phase 5.4.1 pre-write) transitions from `phase5_review` to `phase5_post_review`, ensuring stop-guard routes to the correct next branch rather than repeatedly blocking and incrementing `error_count` (fixes #719):

```bash
TMP_STATE=".rite-flow-state.tmp.$$"
jq -n \
  --argjson active true \
  --argjson issue {issue_number} \
  --arg branch "{branch_name}" \
  --arg phase "phase5_post_review" \
  --argjson loop {loop_count} \
  --argjson pr {pr_number} \
  --arg next "rite:pr:review completed. Check recent result pattern in context: [review:mergeable]->Phase 5.5 (ready). [review:fix-needed:{N}]->Phase 5.4.4 (fix). [review:conditional-merge/loop-limit]->Phase 5.4.4 then 5.5. Do NOT stop." \
  --arg ts "$(date -u +'%Y-%m-%dT%H:%M:%S+00:00')" \
  '{active: $active, issue_number: $issue, branch: $branch, phase: $phase, loop_count: $loop, pr_number: $pr, next_action: $next, updated_at: $ts}' \
  > "$TMP_STATE" && mv "$TMP_STATE" .rite-flow-state || rm -f "$TMP_STATE"
```

**Step 2**: Sync to local work memory:

```bash
WM_SOURCE="review" \
  WM_PHASE="phase5_post_review" \
  WM_PHASE_DETAIL="レビュー完了" \
  WM_NEXT_ACTION="レビュー結果に基づき次アクションを実行" \
  WM_BODY_TEXT="Post-review sync." \
  WM_ISSUE_NUMBER="{issue_number}" \
  WM_READ_FROM_FLOW_STATE="true" \
  bash plugins/rite/hooks/local-wm-update.sh 2>/dev/null || true
```

**Step 3**: **→ Execute 5.4.2 branch now**.

#### 5.4.4 Fix

Update `.rite-flow-state` (atomic):

```bash
TMP_STATE=".rite-flow-state.tmp.$$"
jq -n \
  --argjson active true \
  --argjson issue {issue_number} \
  --arg branch "{branch_name}" \
  --arg phase "phase5_fix" \
  --argjson loop {loop_count} \
  --argjson pr {pr_number} \
  --arg next "After rite:pr:fix returns: [fix:pushed]+fix-needed->Phase 5.4.1. [fix:pushed]+conditional/loop-limit->Phase 5.5. [fix:issues-created]->Phase 5.4.1. [fix:replied-only]->Phase 5.5. [fix:error]->ask user. Do NOT stop." \
  --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")" \
  '{active: $active, issue_number: $issue, branch: $branch, phase: $phase, loop_count: $loop, pr_number: $pr, next_action: $next, updated_at: $ts}' \
  > "$TMP_STATE" && mv "$TMP_STATE" .rite-flow-state || rm -f "$TMP_STATE"
```

> **Data Handoff**: When invoking `rite:pr:fix`, PR number and review results are passed via work memory. Issue information from Phase 0.1 is available in work memory, avoiding redundant `gh issue view` calls.

Invoke `skill: "rite:pr:fix"`.

#### 5.4.5 Fix Patterns

`[fix:pushed]` + `[review:fix-needed]`→5.4.1. `[fix:pushed]` + `[conditional/loop-limit]`→5.5. `[fix:issues-created:{n}]`→5.4.1. `[fix:replied-only]`→5.5. `[fix:error]`→error, ask user.

#### 5.4.6 🚨 After Fix

**Verify**: Pattern confirmed, parsed. Follow sub-skill return protocol above.

**Step 1**: Update `.rite-flow-state` to post-fix phase (atomic). This second write (after the Phase 5.4.4 pre-write) transitions from `phase5_fix` to `phase5_post_fix`, ensuring stop-guard routes to the correct next branch rather than repeatedly blocking and incrementing `error_count` (fixes #709):

```bash
TMP_STATE=".rite-flow-state.tmp.$$"
jq -n \
  --argjson active true \
  --argjson issue {issue_number} \
  --arg branch "{branch_name}" \
  --arg phase "phase5_post_fix" \
  --argjson loop {loop_count} \
  --argjson pr {pr_number} \
  --arg next "rite:pr:fix completed. Check recent result pattern in context: [fix:pushed]+fix-needed->Phase 5.4.1 (re-review). [fix:pushed]+conditional/loop-limit->Phase 5.5 (ready). [fix:issues-created]->Phase 5.4.1. [fix:replied-only]->Phase 5.5. Do NOT stop." \
  --arg ts "$(date -u +'%Y-%m-%dT%H:%M:%S+00:00')" \
  '{active: $active, issue_number: $issue, branch: $branch, phase: $phase, loop_count: $loop, pr_number: $pr, next_action: $next, updated_at: $ts}' \
  > "$TMP_STATE" && mv "$TMP_STATE" .rite-flow-state || rm -f "$TMP_STATE"
```

**Step 2**: Sync to local work memory (with loop_count increment):

```bash
WM_SOURCE="fix" \
  WM_PHASE="phase5_post_fix" \
  WM_PHASE_DETAIL="修正完了" \
  WM_NEXT_ACTION="修正結果に基づき次アクションを実行" \
  WM_BODY_TEXT="Post-fix sync." \
  WM_ISSUE_NUMBER="{issue_number}" \
  WM_LOOP_INCREMENT="true" \
  bash plugins/rite/hooks/local-wm-update.sh 2>/dev/null || true
```

**Step 3**: **→ Execute 5.4.5 branch now**.

### 5.5 Ready for Review

When loop completes, confirm:

```
レビューが完了しました（一気通貫フロー）
総合評価: {assessment}
指摘件数: {total_findings}
オプション: Ready for review に変更（推奨）/ ドラフトのまま完了 / 追加の修正を行う
```

> **Data Handoff**: When invoking `rite:pr:ready`, PR number is passed as an argument. Issue information from Phase 0.1 is available in work memory (loaded by `rite:pr:ready` Phase 0), avoiding redundant `gh issue view` calls.

**Ready**→invoke `rite:pr:ready`→5.5.1. **Draft**→5.6. **More fixes**→terminate.

#### 5.5.0.1 🚨 Mandatory After 5.5

**Verify**: `rite:pr:ready` returned successfully. Follow sub-skill return protocol above.

**Step 1**: Update `.rite-flow-state` to post-ready phase (atomic). This write transitions from `phase5_post_review`/`phase5_post_fix` to `phase5_post_ready`, ensuring stop-guard routes to Status update rather than re-invoking ready (fixes #781):

```bash
TMP_STATE=".rite-flow-state.tmp.$$"
jq -n \
  --argjson active true \
  --argjson issue {issue_number} \
  --arg branch "{branch_name}" \
  --arg phase "phase5_post_ready" \
  --argjson loop {loop_count} \
  --argjson pr {pr_number} \
  --arg next "Phase 5.5.1: Update Issue Status to In Review, then Phase 5.5.2 metrics, then Phase 5.6 completion report. Do NOT stop." \
  --arg ts "$(date -u +'%Y-%m-%dT%H:%M:%S+00:00')" \
  '{active: $active, issue_number: $issue, branch: $branch, phase: $phase, loop_count: $loop, pr_number: $pr, next_action: $next, updated_at: $ts}' \
  > "$TMP_STATE" && mv "$TMP_STATE" .rite-flow-state || rm -f "$TMP_STATE"
```

**Step 2**: Sync to local work memory:

```bash
WM_SOURCE="ready" \
  WM_PHASE="phase5_post_ready" \
  WM_PHASE_DETAIL="Ready処理後" \
  WM_NEXT_ACTION="Issue Status を In Review に更新後、メトリクス記録、完了レポートを実行" \
  WM_BODY_TEXT="Post-ready sync." \
  WM_ISSUE_NUMBER="{issue_number}" \
  WM_READ_FROM_FLOW_STATE="true" \
  bash plugins/rite/hooks/local-wm-update.sh 2>/dev/null || true
```

**Step 3**: **→ Proceed to 5.5.1 now**.

#### 5.5.1 Update Issue Status to "In Review"

**Owner**: `/rite:issue:start` (defense-in-depth — `rite:pr:ready` Phase 4 also attempts this, but may not execute reliably within e2e flow).

**Note**: Uses `gh project field-list` CLI (consistent with [Projects Integration](../../references/projects-integration.md)). This differs from `ready.md` Phase 4 which uses GraphQL — an intentional design choice documented there.

Skip if `projects.enabled: false` in rite-config.yml. Otherwise:

**Step 1**: Retrieve Issue's project item ID. `{owner}` and `{repo}` are obtained before Phase 0.1 (see Placeholder Legend). Reuse `{project_number}` from rite-config.yml:

```bash
gh api graphql -f query='
query($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) {
    issue(number: $number) {
      projectItems(first: 10) {
        nodes {
          id
          project { id, number }
        }
      }
    }
  }
}' -f owner="{owner}" -f repo="{repo}" -F number={issue_number}
```

Find the node where `project.number` matches `{project_number}`. Extract `{item_id}` (node `id`) and `{project_id}` (node `project.id`).

**When `projectItems.nodes` is empty** (Issue not registered in Project):

```
警告: Issue #{issue_number} は Project に登録されていません
Status 更新をスキップします
```

Display warning and proceed to 5.6 (non-blocking).

**Step 2**: Retrieve Status field "In Review" option ID:

```bash
gh project field-list {project_number} --owner {owner} --format json
```

From the result, find the field with `name` "Status". Extract:
- `{status_field_id}`: the field's `id`
- `{in_review_option_id}`: the `id` of the option with `name` "In Review"

If `github.projects.field_ids.status` is set in rite-config.yml, use that value as `{status_field_id}` instead.

**Step 3**: Update Status:

```bash
gh project item-edit --project-id {project_id} --id {item_id} --field-id {status_field_id} --single-select-option-id {in_review_option_id}
```

On failure, display warning and continue to 5.6 (non-blocking).

**→ Proceed to 5.5.2**.

### 5.5.2 Metrics Recording

> **Reference**: [Execution Metrics](../../references/execution-metrics.md)

Skip if `metrics.enabled: false` in rite-config.yml. Otherwise:

**Step 1**: Collect metrics from the current workflow execution:

| Metric | Source | How to Obtain |
|--------|--------|---------------|
| `plan_deviation_rate` | Issue body checklist items (Phase 3.6) vs completed items | `planned_steps` = total checklist items added in Phase 3.6. `actual_steps` = checked items at completion. Formula: `abs(actual - planned) / planned * 100`. If `planned = 0`, set judgment to `skip` |
| `test_pass_rate` | From Phase 5.2 lint results | 100% if tests passed or no tests configured |
| `review_critical_high` | Phase 5.4 review results | Count of CRITICAL+HIGH findings from the last `📜 rite レビュー結果` PR comment |
| `review_fix_loops` | `.rite-flow-state` | Read `loop_count` field: `jq '.loop_count' .rite-flow-state` |
| `plan_deviation_count` | `.rite-flow-state` | Read `implementation_round` field (set by Phase 5.1.3): `jq '.implementation_round // 0' .rite-flow-state`. This counts re-entries to Phase 5.1 from checklist failures |

**Step 2**: Evaluate thresholds.

Read `metrics.baseline_issues` from rite-config.yml (default: 3).

**Step 2a**: Count completed Issues with metrics. Search the 10 most recently closed Issues for work memory comments containing `📊 メトリクス`:

```bash
# 直近の closed Issue 番号を取得（最大10件）
recent_issues=$(gh api "repos/{owner}/{repo}/issues?state=closed&per_page=10&sort=updated&direction=desc" --jq '.[].number')

# 各 Issue のメトリクスセクションを検索
for issue_num in $recent_issues; do
  metrics=$(gh api "repos/{owner}/{repo}/issues/${issue_num}/comments" \
    --jq '[.[] | select(.body | contains("📊 メトリクス"))] | last | .body' 2>/dev/null)
  if [ -n "$metrics" ] && [ "$metrics" != "null" ]; then
    echo "FOUND:${issue_num}"
  fi
done
```

**Step 2b**: Determine baseline status:

- **Baseline period** (completed Issues with metrics < `baseline_issues`): Set all judgments to `skip`. Display: `📊 Baseline 収集中 ({n}/{baseline_issues}) — 閾値判定はスキップします`
- **Post-baseline**: Proceed to Step 2c

**Step 2c**: Evaluate thresholds (post-baseline only):

1. **Per-Issue thresholds** (from Step 1 values): `plan_deviation_rate <= 30`, `test_pass_rate == 100`, `review_fix_loops <= 3`. Set `pass` or `warn`.
2. **MA thresholds**: Parse `📊 メトリクス` sections from the 5 most recent completed Issues (found in Step 2a). Extract each metric value, calculate the moving average, and compare against `baseline_ma5 * improvement_factor`. Set `pass`, `warn`, or `skip` (if fewer than `baseline_issues` completed).

**Step 3**: Determine failure classification.

If any threshold is `warn`: classify each violation per the [Metric-to-Failure-Class Mapping](../../references/execution-metrics.md#metric-to-failure-class-mapping) table. Select primary failure class (most frequent; tie-break: last occurring).

**Step 4**: Append metrics section to work memory.

Update the Issue work memory comment by appending the metrics table per [Execution Metrics recording format](../../references/execution-metrics.md#recording-format).

> **Reference**: Apply [Work Memory Update Safety Patterns](../../references/gh-cli-patterns.md#work-memory-update-safety-patterns).

```bash
# ⚠️ このブロック全体を単一の Bash ツール呼び出しで実行すること（クロスプロセス変数参照を防止）
# comment_data の取得・追記内容の heredoc 定義・PATCH を分割すると変数が失われる（Issue #693, #835）
comment_data=$(gh api repos/{owner}/{repo}/issues/{issue_number}/comments \
  --jq '[.[] | select(.body | contains("📜 rite 作業メモリ"))] | last | {id: .id, body: .body}')
comment_id=$(echo "$comment_data" | jq -r '.id // empty')
current_body=$(echo "$comment_data" | jq -r '.body // empty')

if [ -z "$comment_id" ]; then
  # comment not found: skip metrics recording entirely (non-fatal; metrics are optional)
  echo "ERROR: Work memory comment not found. Skipping metrics recording." >&2
  exit 0
fi

# 1. Backup before update
backup_file="/tmp/rite-wm-backup-${issue_number}-$(date +%s).md"
printf '%s' "$current_body" > "$backup_file"

if [[ -z "$current_body" ]]; then
  echo "ERROR: Updated body is empty or too short. Aborting PATCH." >&2
  echo "Backup saved at: $backup_file" >&2
  exit 1
fi

# 2. Append metrics section
tmpfile=$(mktemp)
trap 'rm -f "$tmpfile"' EXIT
printf '%s\n\n' "$current_body" > "$tmpfile"
# ⚠️ 以下の heredoc 内の {…} プレースホルダーを Step 1-3 の実測値で置換してから実行すること
cat >> "$tmpfile" << 'METRICS_EOF'
### 📊 メトリクス

| メトリクス | 値 | 閾値 | 判定 |
|-----------|-----|------|------|
| 計画乖離率 | {plan_deviation_rate}% | ≤30% | {judgment} |
| テスト通過率 | {test_pass_rate}% | 100% | {judgment} |
| レビュー指摘(CRITICAL+HIGH) | {review_critical_high}件 | MA5≤{threshold} | {judgment} |
| review-fixループ | {review_fix_loops}回 | ≤3 | {judgment} |
| 計画逸脱回数 | {plan_deviation_count}回 | MA5≤{threshold} | {judgment} |

**Baseline**: {baseline_status}
**失敗分類**: {primary_failure_class} ({corrective_action_pointer})
METRICS_EOF

# 3. Empty body guard
if [ ! -s "$tmpfile" ] || [[ "$(wc -c < "$tmpfile")" -lt 10 ]]; then
  echo "ERROR: Updated body is empty or too short. Aborting PATCH." >&2
  echo "Backup saved at: $backup_file" >&2
  exit 1
fi

# 4. Header validation
if grep -q -- '📜 rite 作業メモリ' "$tmpfile"; then
  : # Header present, proceed
else
  echo "ERROR: Updated body missing work memory header. Restoring from backup." >&2
  cp "$backup_file" "$tmpfile"
  exit 1
fi

# 5. PATCH
jq -n --rawfile body "$tmpfile" '{"body": $body}' \
  | gh api repos/{owner}/{repo}/issues/comments/"$comment_id" \
    -X PATCH --input -
patch_status=$?
if [[ "${patch_status:-1}" -ne 0 ]]; then
  echo "ERROR: PATCH failed (exit code: $patch_status). Backup saved at: $backup_file" >&2
  exit 1
fi
```

**Placeholder descriptions**: `{plan_deviation_rate}`, `{test_pass_rate}`, `{review_critical_high}`, `{review_fix_loops}`, `{plan_deviation_count}` are the values collected in Step 1. `{judgment}` is `pass`/`warn`/`skip` from Step 2. `{threshold}` is the MA5 threshold. `{baseline_status}`, `{primary_failure_class}`, `{corrective_action_pointer}` are from Steps 2-3. Before executing this bash block, replace all `{...}` placeholders in the heredoc body with actual values computed in Steps 1-3. The heredoc uses a single-quoted delimiter (`'METRICS_EOF'`) so shell variables are NOT expanded; Claude must substitute the placeholder text directly in the template before passing it to the Bash tool.

**Step 5**: Check repeated failure (if `safety.auto_stop_on_repeated_failure: true`).

If the same primary failure class has occurred `safety.repeated_failure_threshold` times consecutively (across recent Issues), trigger fail-closed:

```
⚠️ 安全装置が発動しました（繰り返し失敗検出）
分類: {failure_class} が {count} 回連続
是正アクション: {corrective_action_pointer}
```

Present options via `AskUserQuestion`:
- 続行（制限を引き上げ）→ Proceed to 5.6
- 中止（作業メモリに状態保存）→ Phase 5.6
- 手動介入（ユーザーが直接対応）→ terminate

**→ Proceed to 5.6**.

**Post-completion**: Update `.rite-flow-state` `active: false` (atomic):

```bash
TMP_STATE=".rite-flow-state.tmp.$$"
jq -n \
  --argjson active false \
  --argjson issue {issue_number} \
  --arg branch "{branch_name}" \
  --arg phase "completed" \
  --argjson loop {loop_count} \
  --argjson pr {pr_number} \
  --arg next "none" \
  --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")" \
  '{active: $active, issue_number: $issue, branch: $branch, phase: $phase, loop_count: $loop, pr_number: $pr, next_action: $next, updated_at: $ts}' \
  > "$TMP_STATE" && mv "$TMP_STATE" .rite-flow-state || rm -f "$TMP_STATE"
```

**After flow state update (regardless of success/failure)**: Clean up `.rite-compact-state` to prevent stale blocked state from affecting the next session (#756):

```bash
rm -f .rite-compact-state 2>/dev/null || true
rm -rf .rite-compact-state.lockdir 2>/dev/null || true
```

**Note**: This cleanup is non-blocking. Failure to delete is silently ignored.

### 5.6 Completion Report

Execute the following steps **in order**. Do NOT skip any step. Always base your output on the template file read in Step 1 (or the inline fallback below if the Read tool fails).

**Step 1 — Read template** (MANDATORY):

Use the Read tool to read `{plugin_root}/templates/completion-report.md`. Select the appropriate section:
- PR created → **"一気通貫フロー完了時のフォーマット（Phase 5.6 用）"** section
- PR not created → **"PR 未作成時のフォーマット（エッジケース）"** section

If the Read tool fails, proceed to Step 2 using the inline fallback below instead.

**Step 2 — Substitute placeholders**:

Using the template content you just read in Step 1, replace **only** `{...}` placeholders with actual values. Do NOT alter table structure, headings, row order, or add/remove any rows.

| Placeholder | Value Source |
|-------------|-------------|
| `{number}`, `{title}` | Issue info from Phase 0.1 |
| `{owner}`, `{repo}` | Repository info from pre-Phase 0.1 |
| `{pr_number}` | PR number from Phase 5.3 |
| `{pr_state}` | Draft / Ready for Review / Merged |
| `{status}` | Current Projects Status |
| `{score}` | Quality score from Phase 1.1 |
| `{branch_name}` | Branch from Phase 2.1 |
| `{changed_files_count}` | `git diff --name-only origin/{base_branch}...HEAD \| wc -l` (`{base_branch}` = PR base ref from Phase 2.1, e.g. `develop`) |
| `{review_result}` | Review assessment from Phase 5.4 |

**Step 3 — Output**:

Output the substituted template as your response. First determine which case applies, then verify the output matches **all three required sections** for that case:

**Case A — PR was created** (normal case, `{pr_number}` is set):
1. **項目テーブル** (7 rows: Issue, Issue URL, PR, PR URL, PR 状態, 関連 Issue, Status)
2. **フェーズ進捗テーブル** (6 rows: Issue 分析, ブランチ作成, 実装, 品質チェック, PR 作成, セルフレビュー — all ✅)
3. **次のステップ** (3 items, using the content from the template read in Step 1)

**Case B — PR was NOT created** (edge case, no `{pr_number}`):
1. **項目テーブル** (5 rows: Issue, Issue URL, PR, ブランチ, Status)
2. **フェーズ進捗テーブル** (6 rows: completed phases ✅, incomplete phases ⏳)
3. **次のステップ** (3 items, using the content from the template read in Step 1)

**Step 4 — Self-verification**:

After outputting, verify your output matches the case determined in Step 3:

For **Case A** (PR created):
- [ ] `## 完了報告` heading
- [ ] 項目テーブル with exactly **7** data rows
- [ ] `### フェーズ進捗` heading with exactly 6 data rows
- [ ] `### 次のステップ` heading with exactly 3 numbered items

For **Case B** (PR not created):
- [ ] `## 完了報告` heading
- [ ] 項目テーブル with exactly **5** data rows
- [ ] `### フェーズ進捗` heading with exactly 6 data rows (with ⏳ for incomplete phases)
- [ ] `### 次のステップ` heading with exactly 3 numbered items

If any check fails, re-read the template and regenerate.

**MUST NOT**: Omit any template rows, merge fields into a single line, invent fields not in the template, or change the table format (e.g., no ASCII box-drawing).

---

**Inline fallbacks** (use ONLY if Read tool fails on the template file). Select the matching case:

**Case A fallback — PR created**:

```markdown
## 完了報告

| 項目 | 値 |
|------|-----|
| Issue | #{number} - {title} |
| Issue URL | https://github.com/{owner}/{repo}/issues/{number} |
| PR | #{pr_number} |
| PR URL | https://github.com/{owner}/{repo}/pull/{pr_number} |
| PR 状態 | {pr_state} |
| 関連 Issue | #{number} |
| Status | {status} |

### フェーズ進捗

| フェーズ | 状態 | 備考 |
|---------|------|------|
| Issue 分析 | ✅ | 品質スコア: {score} |
| ブランチ作成 | ✅ | {branch_name} |
| 実装 | ✅ | {changed_files_count} ファイル変更 |
| 品質チェック | ✅ | lint 通過 |
| PR 作成 | ✅ | #{pr_number} |
| セルフレビュー | ✅ | {review_result} |

### 次のステップ

1. レビュアーに PR レビューを依頼
2. レビューコメントに対応
3. PR マージ後、Issue は自動クローズ
```

**Case B fallback — PR not created**:

```markdown
## 完了報告

| 項目 | 値 |
|------|-----|
| Issue | #{number} - {title} |
| Issue URL | https://github.com/{owner}/{repo}/issues/{number} |
| PR | 未作成 |
| ブランチ | {branch_name} |
| Status | In Progress |

### フェーズ進捗

| フェーズ | 状態 | 備考 |
|---------|------|------|
| Issue 分析 | ✅ | 品質スコア: {score} |
| ブランチ作成 | ✅ | {branch_name} |
| 実装 | ✅ | {changed_files_count} ファイル変更 |
| 品質チェック | ⏳ | 未実施 |
| PR 作成 | ⏳ | - |
| セルフレビュー | ⏳ | - |

### 次のステップ

1. `/rite:pr:create` で PR を作成
2. `/rite:pr:review` でセルフレビュー
3. レビュアーに PR レビューを依頼
```

See template "エッジケース対応表" for other edge cases.

### 5.7 Parent Issue Completion

**Condition**: Parent identified in Phase 1.6/2.4.7. Execute after 5.6.

#### 5.7.1 Child Check

Use [Basic Query](../../references/epic-detection.md#basic-query). All `CLOSED`→5.7.2. Some `OPEN`→5.7.3.

#### 5.7.2 Auto-Close

Confirm via `AskUserQuestion`. If "No", display message and proceed to 5.7.3 (no auto-close). If yes, update Projects Status to "Done" and then close the Issue.

Skip Steps 1-3 if `projects.enabled: false` in rite-config.yml. Otherwise:

**Step 1**: Retrieve parent Issue's project item ID. `{owner}` and `{repo}` are obtained before Phase 0.1 (see Placeholder Legend). Reuse `{project_number}` from rite-config.yml:

```bash
gh api graphql -f query='
query($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) {
    issue(number: $number) {
      projectItems(first: 10) {
        nodes {
          id
          project { id, number }
        }
      }
    }
  }
}' -f owner="{owner}" -f repo="{repo}" -F number={parent_issue_number}
```

Find the node where `project.number` matches `{project_number}`. Extract `{item_id}` (node `id`) and `{project_id}` (node `project.id`).

**When `projectItems.nodes` is empty** (parent Issue not registered in Project):

```
警告: Issue #{parent_issue_number} は Project に登録されていません
Status 更新をスキップします
```

Display warning and proceed to Step 4 (non-blocking).

**Step 2**: Retrieve Status field "Done" option ID:

```bash
gh project field-list {project_number} --owner {owner} --format json
```

From the result, find the field with `name` "Status". Extract:
- `{status_field_id}`: the field's `id`
- `{done_option_id}`: the `id` of the option with `name` "Done"

If `github.projects.field_ids.status` is set in rite-config.yml, use that value as `{status_field_id}` instead.

**When "Done" option is not found**: Display warning and proceed to Step 4 (non-blocking).

**Step 3**: Update Status:

```bash
gh project item-edit --project-id {project_id} --id {item_id} --field-id {status_field_id} --single-select-option-id {done_option_id}
```

On failure, display warning and continue to Step 4 (non-blocking).

**Step 4**: Close the parent Issue:

```bash
gh issue close {parent_issue_number}
```

**→ Proceed to 5.7.3** (display remaining children if any).

#### 5.7.3 Next Child

Display remaining children, guide `/rite:issue:start`. No auto-start.

## Interruption/Resumption

**Retention**: Branch (Git), work memory (Issue comment), Status (Projects), plan (work memory).

**Resume** via `/rite:issue:start {number}`: Phase 2.2 detects branch. "Switch"→skip 2.3/2.4/2.6→Phase 3 (show plan)→continue from work memory.

**If PR exists**: After 2.2, check `gh pr list --head {branch_name}`. OPEN→`rite:pr:review`, MERGED→`rite:pr:cleanup`, CLOSED→confirm (reopen/new/cancel).

## Standalone Usage

Auto-invoked in end-to-end, usable standalone:

| Command | Standalone Use |
|---------|---------------|
| `/rite:issue:update` | Progress recording, handover |
| `/rite:lint` | Quality check |
| `/rite:pr:create` | PR without Issue, from existing branch |
| `/rite:pr:review` | Existing PR, others' PRs |
| `/rite:pr:fix` | Resume feedback |

## Error Handling

Issue not found→error, prompt `gh issue list`. Closed→confirm reopen/cancel. Branch fail→check `git status`. Projects unconfigured→warn, skip. API error→retry 3x (exponential backoff), skip Projects. See [GraphQL Helpers](../../references/graphql-helpers.md#error-handling).
