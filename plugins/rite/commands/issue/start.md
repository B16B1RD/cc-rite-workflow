---
description: Issue の作業を開始（ブランチ作成 → 実装 → PR 作成まで一気通貫）
---

# /rite:issue:start

## Contract
**Input**: Issue number (required), optionally `.rite-flow-state` from a previous interrupted session
**Output**: `## 完了報告` (completion report with Issue/PR details and phase progress table)

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

Execute phases sequentially. **Do NOT stop between phases unless the user explicitly selects a "cancel" or "later" option.**

---

## Phase Flow Quick Reference

> Stopping between phases leaves the workflow in an inconsistent state (e.g., branch created but no PR), requiring manual recovery via `/rite:resume`.
> **CRITICAL**: After every sub-skill invocation returns, **immediately** proceed to the next phase. Do NOT stop, do NOT re-invoke the completed skill.
>
> This table lists phases with sub-skill invocations or key decision points. Phases not listed (2.4 Projects Status, 2.5 Iteration, 5.0 Stop Hook, 5.5.1 Status Update, 5.5.2 Metrics, 5.7 Parent Completion) execute inline without stopping.

| Phase | Sub-skill Invoked | Next Phase | Stop Allowed? |
|-------|-------------------|------------|---------------|
| 0 (Detection) | — | 1 | No |
| 1 (Quality) | — | 1.5 | No |
| 1.5 (Parent Routing) | `rite:issue:parent-routing` | 1.6 or 2 | **No** |
| 1.6 (Child Selection) | `rite:issue:child-issue-selection` | 2 | **No** |
| 2.3 (Branch) | `rite:issue:branch-setup` | 2.4 | **No** |
| 2.6 (Work Memory) | `rite:issue:work-memory-init` | 3 | **No** |
| 3 (Plan) | `rite:issue:implementation-plan` | 4 | **No** |
| 4 (Guidance) | — | 5 or terminate | Yes (user choice) |
| 5.1 (Implement) | — | 5.2 (lint) | **No** |
| 5.2 (Lint) | `rite:lint` | 5.2.1 | **No** |
| 5.3 (PR) | `rite:pr:create` | 5.4 | **No** |
| 5.4.1 (Review) | `rite:pr:review` | 5.4.3→5.4.4 or 5.5 | **No** |
| 5.4.4 (Fix) | `rite:pr:fix` | 5.4.6→5.4.1 or 5.5 | **No** |
| 5.5 (Ready) | `rite:pr:ready` | 5.5.0.1→5.5.1 | **No** |
| 5.6 (Report) | — | 5.7 or end | Yes |

---

## Sub-skill Return Protocol (Global)

> **CRITICAL — AUTOMATIC CONTINUATION REQUIREMENT**: This is the single most important rule in this document. When a sub-skill returns, you MUST continue responding in the same turn. Ending your response after a sub-skill returns is a **bug** that forces the user to type "continue" manually.

This protocol applies to **every** sub-skill invocation in this document. Each 🚨 Mandatory After section enforces it at specific transition points.

**When a sub-skill outputs a result pattern (e.g., `[review:mergeable]`, `[fix:pushed]`, `[pr:created:123]`) and returns control to you:**

1. **DO NOT end your response.** You are still in the middle of the e2e flow. Ending your response here is equivalent to crashing mid-workflow.
2. **DO NOT re-invoke the completed skill.** It already finished. Re-invoking wastes time and may cause errors.
3. **IMMEDIATELY** locate the 🚨 Mandatory After section for the current phase and execute its steps — starting with the `.rite-flow-state` update, then proceeding to the next phase.
4. If the stop-guard hook blocks a stop attempt (exit 2), follow the `ACTION:` instructions in its stderr message.

**Self-check**: After every sub-skill returns, ask yourself: "Have I output the completion report (Phase 5.6)?" If not, you are NOT done — keep going.

---

## Arguments

| Argument | Description |
|----------|-------------|
| `<issue_number>` | Issue number to start working on (required) |

---

## Placeholder Legend

| Placeholder | Source |
|-------------|--------|
| `{issue_number}` | From the argument |
| `{owner}`, `{repo}` | `gh repo view --json owner,name` (retrieve before Phase 0.1) |
| `{base_branch}` | `branch.base` in `rite-config.yml` (default: `main`). Phase 2.3.1 |
| `{fallback_branch}` | Phase 2.3.2.3 only (`main` preferred, else default branch) |
| `{default_branch}` | `gh repo view --json defaultBranchRef` (Phase 2.3.2.3 only) |
| `{project_number}` | `github.projects.project_number` in `rite-config.yml` |
| `{project_id}` | GraphQL query result (`projectV2.id`). Obtained once, reused |
| `{item_id}` | GraphQL query result (node matching child Issue number) |
| `{plugin_root}` | [Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script) |
| `{status_field_id}` | `github.projects.field_ids.status` in `rite-config.yml`, or `gh project field-list` |
| `{in_review_option_id}` | `gh project field-list` ("In Review" option) |
| `{done_option_id}` | `gh project field-list` ("Done" option) |
| `{session_id}` | `flow-state-update.sh create` auto-reads from `.rite-session-id` when `--session` value is empty. Claude does not need to resolve this placeholder. |

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
# branch is empty here — not yet created; populated after rite:issue:branch-setup completes in Phase 2.3
bash {plugin_root}/hooks/flow-state-update.sh create \
  --phase "phase1_5_parent" --issue {issue_number} --branch "" \
  --pr 0 \
  --session {session_id} \
  --next "After rite:issue:parent-routing returns: proceed to Phase 1.6 (child issue selection) if applicable, then Phase 2. Do NOT stop."
```

> **Module**: [Parent Issue Routing](./parent-routing.md) - Handles: detection (1.5.1), child state/Projects retrieval (1.5.2-1.5.3), decomposition (1.5.4.1-1.5.4.6), auto-close (1.5.5).

Invoke `skill: "rite:issue:parent-routing"`.

### 🚨 Mandatory After 1.5

> See [Sub-skill Return Protocol (Global)](#sub-skill-return-protocol-global).

Do **NOT** stop after `rite:issue:parent-routing` returns. The parent routing sub-skill only performs detection — branch creation and implementation have NOT started yet.

**Step 1**: Update `.rite-flow-state` to post-parent-routing phase (atomic). The sub-skill has already updated to `phase1_5_post_parent` via its Defense-in-Depth section; this second write ensures stop-guard routes to the correct next branch:

```bash
bash {plugin_root}/hooks/flow-state-update.sh create \
  --phase "phase1_5_post_parent" --issue {issue_number} --branch "" \
  --pr 0 \
  --session {session_id} \
  --next "rite:issue:parent-routing completed. Proceed to Phase 1.6 (child issue selection) if applicable, then Phase 2. Do NOT stop."
```

**Step 2**: **→ Proceed to Phase 1.6 (if child issues exist) or Phase 2 now**.

## Phase 1.6: Child Issue Selection

**Pre-write** (before invoking `rite:issue:child-issue-selection`): Update `.rite-flow-state` so stop-guard can resume flow if interrupted:

```bash
# branch is empty here — not yet created; populated after rite:issue:branch-setup completes in Phase 2.3
bash {plugin_root}/hooks/flow-state-update.sh create \
  --phase "phase1_6_child" --issue {issue_number} --branch "" \
  --pr 0 \
  --session {session_id} \
  --next "After rite:issue:child-issue-selection returns: proceed to Phase 2 (work preparation). Do NOT stop."
```

> **Module**: [Child Issue Selection](./child-issue-selection.md) - Automatic child selection with priority logic, dependencies, user confirmation.

Invoke `skill: "rite:issue:child-issue-selection"`.

### 🚨 Mandatory After 1.6

> See [Sub-skill Return Protocol (Global)](#sub-skill-return-protocol-global).

Do **NOT** stop after `rite:issue:child-issue-selection` returns. Branch creation and implementation have NOT started yet.

**Step 1**: Update `.rite-flow-state` to post-child-selection phase (atomic). The sub-skill has already updated to `phase1_6_post_child` via its Defense-in-Depth section; this second write ensures stop-guard routes to the correct next branch:

```bash
bash {plugin_root}/hooks/flow-state-update.sh create \
  --phase "phase1_6_post_child" --issue {issue_number} --branch "" \
  --pr 0 \
  --session {session_id} \
  --next "rite:issue:child-issue-selection completed. Proceed to Phase 2 (work preparation). Do NOT stop."
```

**Step 2**: **→ Proceed to Phase 2 now**.

---

## Phase 2: Work Preparation

### 2.1 Branch Name Generation

Follow `rite-config.yml` pattern `{type}/issue-{number}-{slug}`. Type from labels/title: `bug`/`bugfix`→`fix`, `docs`→`docs`, `refactor`→`refactor`, `chore`/`maintenance`→`chore`, else→`feat`. Slug: lowercase title, spaces→hyphens, max 30 chars.

### 2.2 Existing Branch Check

```bash
local_match=$(git branch --list "{branch_name}")
remote_match=$(git branch -r --list "origin/{branch_name}")
```

> **DO NOT** use exit code (`&&`, `||`, `$?`) to determine branch existence. `git branch --list` always returns exit code 0 regardless of whether a match is found.

**Determination**: If `local_match` or `remote_match` is non-empty, the branch exists.

```bash
# 判定ロジック（出力文字列の空チェック）
if [ -n "$local_match" ] || [ -n "$remote_match" ]; then
  echo "BRANCH_EXISTS"
else
  echo "BRANCH_NOT_FOUND"
fi
```

If exists: `ブランチ {branch_name} は既に存在します。オプション: 既存ブランチに切り替え / 別名でブランチを作成（サフィックス追加）/ キャンセル`

#### 2.2.1 Recognized Patterns

If `branch.recognized_patterns` in rite-config.yml, detect non-Issue-numbered branches. Execute 2.2.1 only after 2.2 finds nothing.

**Pattern→regex**: `{n}`→`[0-9]+`, `{category}`/`{description}`→`[a-z0-9-]+`, `{locale}`→`[a-z]{2}(-[a-z]{2})?`, `{date}`→`[0-9-]+`, `{*}`→`.+`. Add `^...$` anchors.

**On match**: Display `既存ブランチ {branch_name} を検出しました。（パターン: {matched_pattern}）このブランチは Issue 番号を含まないため、Issue #{issue_number} との紐付けは手動で行う必要があります。オプション: このブランチで作業を開始（Issue との紐付けなし）/ 標準パターンで新しいブランチを作成 / キャンセル`

Skip Phase 2.4/2.5/2.6 (no Issue number). User manually links. Phase 3+ normal.

### 2.3 Branch Creation

**Pre-write** (before invoking `rite:issue:branch-setup`): Update `.rite-flow-state` so stop-guard can resume flow if interrupted:

```bash
bash {plugin_root}/hooks/flow-state-update.sh create \
  --phase "phase2_branch" --issue {issue_number} --branch "{branch_name}" \
  --pr 0 \
  --session {session_id} \
  --next "After rite:issue:branch-setup returns: proceed to Phase 2.4 (Projects Status update to In Progress). Do NOT stop."
```

> **Module**: [Branch Setup](./branch-setup.md) - Creates branch from `branch.base`, handles fallback when base doesn't exist.

Invoke `skill: "rite:issue:branch-setup"`.

### 🚨 Mandatory After 2.3

> See [Sub-skill Return Protocol (Global)](#sub-skill-return-protocol-global).

Do **NOT** stop after `rite:issue:branch-setup` returns. Projects status update and work memory initialization are still pending.

**Step 1**: Update `.rite-flow-state` to post-branch phase (atomic). The sub-skill has already updated to `phase2_post_branch` via its Defense-in-Depth section; this second write ensures stop-guard routes to the correct next branch:

```bash
bash {plugin_root}/hooks/flow-state-update.sh create \
  --phase "phase2_post_branch" --issue {issue_number} --branch "{branch_name}" \
  --pr 0 \
  --session {session_id} \
  --next "rite:issue:branch-setup completed. Proceed to Phase 2.4 (Projects Status update to In Progress). Do NOT stop."
```

**Step 2**: **→ Proceed to Phase 2.4 now**.

### 2.4 GitHub Projects Status Update

> **Module**: [Projects Integration](../../references/projects-integration.md#24-github-projects-status-update)

Skip if `projects.enabled: false` in rite-config.yml. Otherwise: get item ID, update Status to "In Progress", auto-add if not registered. Execute sub-phases in order: config (2.4.1), registration check (2.4.2), auto-add (2.4.3), Status field with field_ids optimization (2.4.4), Status update (2.4.5).

**After 2.4.5 completes, always execute 2.4.7** (Parent Issue Status Update). 2.4.7.1 performs parent detection — if no parent is found, it skips silently. Do NOT skip 2.4.7 even if the current Issue was not identified as a parent in Phase 0.3 (Phase 0.3 detects children, not parents).

### 2.5 Iteration Assignment

> **Module**: [Projects Integration](../../references/projects-integration.md#25-iteration-assignment-optional)

Execute only if `iteration.enabled: true` and `iteration.auto_assign: true` in rite-config.yml. Skip if `projects.enabled: false`. Handles: field info (2.5.1), current determination (2.5.2), assignment (2.5.3), result/warning (2.5.4).

### 2.6 Work Memory Initialization

**Pre-write** (before invoking `rite:issue:work-memory-init`): Update `.rite-flow-state` so stop-guard can resume flow if interrupted:

```bash
bash {plugin_root}/hooks/flow-state-update.sh create \
  --phase "phase2_work_memory" --issue {issue_number} --branch "{branch_name}" \
  --pr 0 \
  --session {session_id} \
  --next "After rite:issue:work-memory-init returns: proceed to Phase 3 (implementation plan). Do NOT stop."
```

> **Module**: [Work Memory Initialization](./work-memory-init.md) - Initializes Issue comment with progress summary, confirmation items, session info. Format: [Work Memory Format](../../skills/rite-workflow/references/work-memory-format.md).

Invoke `skill: "rite:issue:work-memory-init"`.

### 🚨 Mandatory After 2.6

> See [Sub-skill Return Protocol (Global)](#sub-skill-return-protocol-global).

**Step 1**: Update `.rite-flow-state` to post-work-memory phase (atomic). The sub-skill has already updated to `phase2_post_work_memory` via its Defense-in-Depth section; this second write ensures stop-guard routes to the correct next branch:

```bash
bash {plugin_root}/hooks/flow-state-update.sh create \
  --phase "phase2_post_work_memory" --issue {issue_number} --branch "{branch_name}" \
  --pr 0 \
  --session {session_id} \
  --next "rite:issue:work-memory-init completed. Proceed to Phase 3 (implementation plan). Do NOT stop."
```

**Step 2**: Defense-in-depth: verify local work memory was created. If the sub-skill skipped it, create via fallback:

```bash
if [ ! -f ".rite-work-memory/issue-{issue_number}.md" ]; then
  WM_SOURCE="init" WM_PHASE="phase2" WM_PHASE_DETAIL="ブランチ作成・準備" \
    WM_NEXT_ACTION="実装計画を生成" \
    WM_BODY_TEXT="Work memory initialized (fallback). Issue #{issue_number} の作業を開始しました。" \
    WM_ISSUE_NUMBER="{issue_number}" \
    bash {plugin_root}/hooks/local-wm-update.sh 2>/dev/null || true
fi
```

> **Note**: `{plugin_root}` が未解決の場合は、[Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script) に従い事前に解決すること。このコードブロックは Phase 4.1 よりも前に実行されるため、Phase 4.1 での解決に依存できない。相対パス `plugins/rite/hooks/` は、マーケットプレイスインストール環境ではスクリプトが見つからないため使用不可。

**Step 3**: Do **NOT** stop after `rite:issue:work-memory-init` returns. **→ Proceed to Phase 3 now**.

## Phase 3: Implementation Plan

**Pre-write** (before invoking `rite:issue:implementation-plan`): Update `.rite-flow-state` so stop-guard can resume flow if interrupted:

```bash
bash {plugin_root}/hooks/flow-state-update.sh create \
  --phase "phase3_plan" --issue {issue_number} --branch "{branch_name}" \
  --pr 0 \
  --session {session_id} \
  --next "After rite:issue:implementation-plan returns: proceed to Phase 4 (work start guidance). Do NOT stop."
```

> **Module**: [Implementation Plan Generation](./implementation-plan.md) - Analyzes Issue, identifies files, generates plan, gets user confirmation, records to work memory, updates Issue body checklist.

Invoke `skill: "rite:issue:implementation-plan"`.

### 🚨 Mandatory After 3

> See [Sub-skill Return Protocol (Global)](#sub-skill-return-protocol-global).

Do **NOT** stop after `rite:issue:implementation-plan` returns. Implementation has NOT started yet — the plan is just a plan.

**Step 1**: Update `.rite-flow-state` to post-plan phase (atomic). The sub-skill has already updated to `phase3_post_plan` via its Defense-in-Depth section; this second write ensures stop-guard routes to the correct next branch:

```bash
bash {plugin_root}/hooks/flow-state-update.sh create \
  --phase "phase3_post_plan" --issue {issue_number} --branch "{branch_name}" \
  --pr 0 \
  --session {session_id} \
  --next "rite:issue:implementation-plan completed. Proceed to Phase 4 (work start guidance). Do NOT stop."
```

**Step 2**: **→ Proceed to Phase 4 now**.

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

### Context Budget & Output Minimization (#80)

The e2e flow must minimize context consumption to complete within a single session. Each sub-skill has an **E2E Output Minimization** section that reduces output when called from this flow.

**Orchestrator rules** (apply throughout Phase 5):

1. **Minimize intermediate text output**: Between tool calls, output only essential status updates (1-2 lines max). Skip explanations, summaries, and guidance text that the user doesn't need during automated flow.
2. **Trust result patterns**: When a sub-skill returns a result pattern (e.g., `[lint:success]`), do NOT re-summarize what happened. Immediately proceed to the next phase.
3. **Avoid redundant reads**: Information from Phase 0.1 (Issue details) is retained in context. Do NOT re-fetch Issue body, title, or labels in later phases.
4. **Batch bash operations**: Combine related bash commands into single tool calls where possible. Examples: `flow-state-update.sh create ... && WM_SOURCE=... bash local-wm-update.sh` (flow-state + work memory sync in one call), `gh api graphql ... && gh project item-edit ...` (Projects query + update in one call).

**Sub-skill output expectations** (e2e flow):

| Sub-skill | Expected Output | Max Lines |
|-----------|-----------------|-----------|
| `rite:lint` | `[lint:success/error]` + 1-line summary | 2 |
| `rite:pr:create` | `[pr:created:{n}]` + PR URL | 2 |
| `rite:pr:review` | `[review:mergeable]` or `[review:fix-needed:{n}]` etc. | 2 |
| `rite:pr:fix` | `[fix:{result}]` + change summary | 2 |
| `rite:pr:ready` | `[ready:completed]` | 1 | <!-- ready.md の出力は元々1行程度のため E2E Output Minimization セクション不要 -->

### Context Management

> **Reference**: [Review Context Optimization](../pr/references/review-context-optimization.md)

**Pressure detection (heuristics)** (counted via `.rite-context-counter` file, managed by `context-pressure.sh` PostToolUse hook; thresholds are configurable via `rite-config.yml` `context_optimization.pressure_thresholds`):
- Tool calls >= YELLOW threshold (default: 60) → diff optimization + output minimization hint
- Tool calls >= ORANGE threshold (default: 90) → output minimization mode (skip optional displays)
- Tool calls >= RED threshold (default: 120) → context optimization (per-file diffs, history summarization, /compact recommendation)
- Read >5000 lines or >10 files → omit unnecessary info
- diff >2000 → file splitting in review
- Previous review comment exists → verification mode (if `review.loop.verification_mode: true`)

Count: Tool results in history (parallel=1). Read=sum max line numbers. Changed=additions+deletions.

**Optimizations**: Verification mode (cycle 2+, previous fix + incremental diff), per-file diff, omit error details, summarize loops ("Cycle N: X→fix"), incremental retrieval. Display "⚠️ Context optimization mode".

**Split/termination**:
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
  5.4.1 rite:pr:review → [mergeable]→5.5 / [fix-needed]→fix→5.4.1
  (5.4.2-5.4.3 review routing/after, 5.4.5-5.4.6 fix routing/after)
  5.4.4 rite:pr:fix → [pushed]→5.4.1 / [issues-created]→5.4.1 / [replied-only]→5.5 / [error]→処理
5.5 Ready for Review 確認 → rite:pr:ready → [ready:completed]→5.5.0.1→5.5.1 Status 更新 → 5.5.2
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

**Orchestration**: `/rite:issue:start` controls all. Skills output patterns: lint (`[lint:success/skipped/error/aborted]`), create (`[pr:created:{n}/create-failed]`), review (`[review:mergeable/fix-needed:{n}]`), fix (`[fix:pushed/issues-created/replied-only/error]`), ready (`[ready:completed/error]`).

**Sub-skill return protocol**: See [Sub-skill Return Protocol (Global)](#sub-skill-return-protocol-global). Each 🚨 Mandatory After section below enforces it at specific transition points.

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
| PostCompact | `bash {plugin_root}/hooks/post-compact.sh` | `""` |
| SessionStart | `bash {plugin_root}/hooks/session-start.sh` | `""` |
| SessionEnd | `bash {plugin_root}/hooks/session-end.sh` | `""` |
| PreToolUse | `bash {plugin_root}/hooks/pre-tool-bash-guard.sh` | `"Bash"` |
| PostToolUse | `bash {plugin_root}/hooks/post-tool-wm-sync.sh` | `"Bash"` |
| PostToolUse | `bash {plugin_root}/hooks/context-pressure.sh` | `""` |

Each hook entry uses the format: `{"matcher": "", "hooks": [{"type": "command", "command": "bash {plugin_root}/hooks/{script}"}]}`. For hooks with `"Bash"` matcher, use `{"matcher": "Bash", ...}`. See [init.md Phase 4.5.2](../init.md) for full reference.

**Step 4**: Ensure scripts are executable:

```bash
chmod +x {plugin_root}/hooks/stop-guard.sh {plugin_root}/hooks/pre-compact.sh {plugin_root}/hooks/post-compact.sh {plugin_root}/hooks/session-start.sh {plugin_root}/hooks/session-end.sh {plugin_root}/hooks/pre-tool-bash-guard.sh {plugin_root}/hooks/post-tool-wm-sync.sh {plugin_root}/hooks/context-pressure.sh 2>/dev/null || true
```

If `chmod` fails, display `⚠️ Hook scripts may not be executable. Flow may require manual continuation after sub-skill returns.` If hook registration fails (e.g., file permission error), display the same warning and continue — 🚨 Mandatory After instructions provide textual fallback.

**Step 5**: Update version marker after hook registration:

```bash
VERSION=$(jq -r '.version' "{plugin_root}/.claude-plugin/plugin.json" 2>/dev/null)
if [ -n "$VERSION" ] && [ "$VERSION" != "null" ]; then
  echo "$VERSION" > "$STATE_ROOT/.rite-initialized-version"
fi
```

### 5.1 Implementation

Run [Preflight Protocol](#preflight-protocol) before starting implementation.

> **Module**: [Implementation Guidance](./implement.md) - Follow Phase 3 plan. Handles: Read/Edit/Bash, parallel (5.1.0), commit message (5.1.1), checklist update (5.1.1.1), parent progress (5.1.2), `.rite-flow-state`, mandatory `rite:lint` invocation.

Skipping lint risks merging code that violates project quality standards, creating technical debt that compounds across subsequent Issues.
**Critical**: After 5.1.1, **immediately** invoke `rite:lint`. Do NOT stop.

#### 5.1.3 Safety Check (Implementation Rounds)

> **Reference**: [Execution Metrics](../../references/execution-metrics.md#safety-thresholds)

Read `safety.max_implementation_rounds` from rite-config.yml (default: 20). Track implementation round count in `.rite-flow-state` via the `implementation_round` field (incremented each time Phase 5.1 is re-entered from 5.2.1 checklist failure).

**Round count tracking**: When re-entering Phase 5.1, update `.rite-flow-state` atomically:

```bash
bash {plugin_root}/hooks/flow-state-update.sh increment --field "implementation_round"
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
bash {plugin_root}/hooks/flow-state-update.sh create \
  --phase "phase5_lint" --issue {issue_number} --branch "{branch_name}" \
  --pr 0 \
  --session {session_id} \
  --next "After rite:lint returns: [lint:success/skipped]->Phase 5.2.1 (checklist). [lint:error]->fix and re-invoke. [lint:aborted]->Phase 5.6. Do NOT stop."
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

> See [Sub-skill Return Protocol (Global)](#sub-skill-return-protocol-global).

**Ignore** `/rite:lint` "Next steps" (standalone only). **Immediately** update `.rite-flow-state` and execute 5.2.1.

**Step 1**: Update `.rite-flow-state` to post-lint phase (atomic). This second write (after the Phase 5.2 pre-check write) transitions from `phase5_lint` to `phase5_post_lint`, ensuring stop-guard routes to checklist confirmation rather than re-invoking lint:

```bash
bash {plugin_root}/hooks/flow-state-update.sh create \
  --phase "phase5_post_lint" --issue {issue_number} --branch "{branch_name}" \
  --pr 0 \
  --session {session_id} \
  --next "Phase 5.2.1: Check Issue checklist completion. All complete->Phase 5.3 PR creation (invoke rite:pr:create). Incomplete->return to Phase 5.1 implementation. Do NOT stop."
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

**Determine**: `grep -c` output `0`→all complete→5.3. `≥1`→incomplete→proceed to 5.2.1.1 (auto-check). Empty body→retry 5.1. **Mandatory**, cannot skip.

#### 5.2.1.1 Auto-Check Evaluation

When incomplete checklist items are detected, evaluate each item's fulfillment status based on the current implementation state before returning to Phase 5.1.

**Purpose**: Prevent infinite loops where implementation is complete but Definition of Done checklist items remain unchecked because no process updates them to `- [x]`.

**Evaluation procedure**:

1. **Collect evidence**: Use `git diff origin/{base_branch}...HEAD --name-only` and `git log --oneline origin/{base_branch}...HEAD` to understand what was implemented.

2. **Evaluate each incomplete item**: For each `- [ ]` item, assess whether the item is satisfied based on the implementation evidence:

   | Assessment | Criteria | Action |
   |-----------|----------|--------|
   | **Satisfied** | Implementation evidence clearly fulfills the item | Mark as `- [x]` |
   | **Not satisfied** | No evidence of fulfillment, or clearly incomplete | Keep as `- [ ]` |
   | **Uncertain** | Cannot confidently determine | Present to user via `AskUserQuestion` |

3. **Update Issue body**: If any items are newly marked as satisfied, update the Issue body via `gh issue edit`:

   Follow the "Checkbox Update" pattern in [gh-cli-patterns.md](../../references/gh-cli-patterns.md#safe-checklist-operation-patterns). Use Python for safe `- [ ]` → `- [x]` replacement (do NOT use `sed`).

   ```bash
   # Step 1: Retrieve current body and validate
   tmpfile_read=$(mktemp)
   tmpfile_write=$(mktemp)
   trap 'rm -f "$tmpfile_read" "$tmpfile_write"' EXIT
   gh issue view {issue_number} --json body --jq '.body' > "$tmpfile_read"

   if [ ! -s "$tmpfile_read" ]; then
     echo "ERROR: Issue body の取得に失敗" >&2
     exit 1
   fi

   # Output paths for subsequent Read/Write tool calls
   echo "tmpfile_read=$tmpfile_read"
   echo "tmpfile_write=$tmpfile_write"
   ```

   Then use the Read tool to read `$tmpfile_read` (the path output above), apply `- [ ]` → `- [x]` replacements for satisfied items using the Write tool to `$tmpfile_write`, and apply:

   **Note**: Shell variables do not carry over between Bash tool calls. Use the literal paths output by `echo "tmpfile_read=..."` in Step 1 directly in the command below.

   ```bash
   # Replace with actual paths from Step 1 output (e.g., /tmp/tmp.XXXXXXXXXX)
   tmpfile_write="/tmp/tmp.XXXXXXXXXX"  # ← Step 1 の出力値に置換

   if [ ! -s "$tmpfile_write" ]; then
     echo "ERROR: Updated content is empty" >&2
     exit 1
   fi

   gh issue edit {issue_number} --body-file "$tmpfile_write"
   ```

4. **Re-check**: After updating, re-run the checklist check:

   ```bash
   issue_body=$(gh issue view {issue_number} --json body --jq '.body')
   [ -z "$issue_body" ] && echo "ERROR: Issue body の取得に失敗" >&2 && exit 1
   echo "$issue_body" | grep -E '^- \[[ xX]\] ' | grep -v -E '^- \[[ xX]\] #[0-9]+' | grep -c '^- \[ \] ' || true
   ```

   - `0` (all complete) → Proceed to Phase 5.3
   - `≥1` (still incomplete) → Display remaining incomplete items and return to Phase 5.1
   - Empty body → retry Phase 5.1

**User confirmation for uncertain items**:

When items are assessed as "Uncertain", use `AskUserQuestion`:

```
以下のチェックリスト項目の充足状態を確認してください:

- [ ] {item_text}

オプション:
- 充足済みとしてチェック（推奨）: この項目を完了とマークします
- 未充足: Phase 5.1 に戻って対応します
```

**Constraints**:
- Already checked items (`- [x]`) are never modified (AC-3 non-regression)
- Issue reference items (`- [ ] #XX`) are excluded from evaluation (parent-child tracking)
- Auto-check is executed **at most once per 5.2.1 invocation** to prevent evaluation loops

### 5.3 PR Creation

Run [Preflight Protocol](#preflight-protocol) before creating PR.

After 5.2.1, update `.rite-flow-state` (atomic, see 5.1 step 3):

```bash
bash {plugin_root}/hooks/flow-state-update.sh create \
  --phase "phase5_pr" --issue {issue_number} --branch "{branch_name}" \
  --pr 0 \
  --session {session_id} \
  --next "After rite:pr:create returns: [pr:created:{N}]->save pr_number, Phase 5.4 (review loop). [pr:create-failed]->Phase 5.6. Do NOT stop."
```

> **Data Handoff**: When invoking `rite:pr:create`, include the Issue information retrieved in Phase 0.1 (`number`, `title`, `body`, `labels`) in the Skill prompt to avoid redundant `gh issue view` calls in the child command.

Invoke `skill: "rite:pr:create"`.

**🚨 Immediate after pr:create returns**: When `rite:pr:create` outputs a result pattern (`[pr:created:{N}]` or `[pr:create-failed]`) and returns control, do **NOT** churn or pause — **immediately** proceed to 🚨 Mandatory After 5.3 below. The review-fix loop has NOT started yet — you MUST continue to Phase 5.4.

**Patterns**: `[pr:created:{number}]`→extract number, proceed 5.4. `[pr:create-failed]`→5.6.

### 🚨 Mandatory After 5.3

> See [Sub-skill Return Protocol (Global)](#sub-skill-return-protocol-global).

**Verify**: `[pr:created:{number}]`, number saved. Review has NOT started yet. **→ Proceed to 5.4 now**.

### 5.4 Review-Fix Loop

`/rite:issue:start` orchestrates the review-fix loop.

**Local work memory sync rule**: At each phase transition within the review-fix loop (5.4.1, 5.4.3, 5.4.4, 5.4.6), after updating `.rite-flow-state`, also sync phase to the local work memory file (`.rite-work-memory/issue-{n}.md`). Use the self-resolving wrapper `local-wm-update.sh` with appropriate `WM_*` env vars. See [Work Memory Format - Usage in Commands](../../skills/rite-workflow/references/work-memory-format.md#usage-in-commands) for the recommended pattern.

**Issue comment backup sync rule**: After each review cycle completes (at 5.4.3 and 5.4.6), sync local work memory to the Issue comment as a backup. Use the existing `gh api` PATCH pattern from `fix.md` Phase 4.5.2. This ensures the Issue comment reflects the latest phase for recovery after context compaction.

#### 5.4.0 Agent Delegation Option (Context Pressure Mitigation)

When context pressure is detected (tool call count > `context_optimization.agent_delegation_threshold` from rite-config.yml, default: 80), the review-fix loop can be delegated to an Agent to isolate its context consumption from the main flow.

**Note**: `agent_delegation_threshold` is independent from `pressure_thresholds` (YELLOW/ORANGE/RED). Pressure thresholds control graduated warnings via the `context-pressure.sh` hook, while `agent_delegation_threshold` controls whether the review-fix loop is offloaded to a sub-agent. Both use the same `.rite-context-counter` value but serve different purposes.

**Condition**: Check `.rite-context-counter` value. If above threshold AND `context_optimization.agent_delegation: true` in rite-config.yml (default: false):

```
⚠️ コンテキスト圧迫を検出しました（{count} tool calls）。
レビュー・修正ループをエージェントに委譲して、メインコンテキストを保護します。
```

**Agent delegation flow**:
1. Save current state to `.rite-flow-state` and local work memory
2. Spawn a general-purpose Agent with the following prompt:
   ```
   Execute the review-fix loop for PR #{pr_number} (Issue #{issue_number}).

   Use the Skill tool to invoke each skill. The exact invocation format is:

   - Review: `skill: "rite:pr:review", args: "{pr_number}"`
   - Fix: `skill: "rite:pr:fix"`

   Steps:
   1. Invoke `skill: "rite:pr:review", args: "{pr_number}"`
   2. Based on the result pattern:
      - [review:mergeable] → return "AGENT_RESULT: [review:mergeable]"
      - [review:fix-needed:{n}] → invoke `skill: "rite:pr:fix"`, then re-review (loop until 0 findings)
   3. Return final result: "AGENT_RESULT: [review:{final_result}] findings={total}"
   ```
3. Parse `AGENT_RESULT` from agent output. If the agent output does not contain a valid `AGENT_RESULT:` pattern (agent error, timeout, or unexpected output):

   **Fallback handling**:
   ```
   ⚠️ エージェント委譲の結果を取得できませんでした。
   エージェント出力に AGENT_RESULT パターンが見つかりません。
   ```

   Present options via `AskUserQuestion`:
   - **inline 実行にフォールバック（推奨）**: Execute 5.4.1-5.4.6 inline as normal (proceed to 5.4.1)
   - **完了報告に遷移**: Skip review-fix loop and proceed to Phase 5.6 (completion report with review skipped)
   - **手動介入**: Terminate and let the user handle manually

   Update `.rite-flow-state` based on the chosen option:

   | Option | `--phase` | `--next` |
   |--------|-----------|----------|
   | inline フォールバック | `phase5_review` | `Agent delegation failed. Executing 5.4.1-5.4.6 inline. Proceed to Phase 5.4.1 (review). Do NOT stop.` |
   | 完了報告に遷移 | `phase5_aborted` | `Agent delegation failed. User chose to skip review. Proceed to Phase 5.6 (completion report). Do NOT stop.` |
   | 手動介入 | `phase5_manual` | `Agent delegation failed. User chose manual intervention. Terminate.` |

   ```bash
   bash plugins/rite/hooks/flow-state-update.sh create \
     --phase "{phase_value}" --issue {issue_number} --branch "{branch_name}" \
     --pr {pr_number} \
     --session {session_id} \
     --next "{next_action_value}"
   ```

4. Update `.rite-flow-state` with agent results (pr_number)
5. Continue to Phase 5.5 (Ready) based on the result

**When agent delegation is disabled or threshold not reached**: Execute 5.4.1-5.4.6 inline as before.

#### 5.4.1 Review

Run [Preflight Protocol](#preflight-protocol) before each review cycle.

Update `.rite-flow-state` (atomic, see 5.1 step 3):

```bash
bash {plugin_root}/hooks/flow-state-update.sh create \
  --phase "phase5_review" --issue {issue_number} --branch "{branch_name}" \
  --pr {pr_number} \
  --session {session_id} \
  --next "After rite:pr:review returns: [review:mergeable]->Phase 5.5. [review:fix-needed:{N}]->Phase 5.4.4. Do NOT stop."
```

> **Note**: `{pr_number}` in the `--arg next` is a document placeholder that Claude replaces with the actual PR number at execution time (same as `--argjson pr {pr_number}` above). The `{N}` in result patterns refers to a count value returned by the sub-skill.

> **Data Handoff**: When invoking `rite:pr:review`, the PR number is passed as an argument. Issue information from Phase 0.1 is available in work memory (loaded by `rite:pr:review` Phase 0), avoiding additional `gh issue view` calls.

Invoke `skill: "rite:pr:review"`.

**🚨 Immediate after review returns**: When `rite:pr:review` outputs a result pattern and returns control, do **NOT** churn or pause — **immediately** proceed to 5.4.3 🚨 After Review below. The review sub-skill has already updated `.rite-flow-state` to `phase5_post_review` via Phase 8.0 (defense-in-depth, #719); execute the 5.4.3 steps without delay.

#### 5.4.2 Review Patterns

`[review:mergeable]`→5.5, `[review:fix-needed:{n}]`→5.4.4.

#### 5.4.3 🚨 After Review

> See [Sub-skill Return Protocol (Global)](#sub-skill-return-protocol-global).

**Verify**: Pattern confirmed, parsed.

**Step 1**: Update `.rite-flow-state` to post-review phase (atomic). This second write (after the Phase 5.4.1 pre-write) transitions from `phase5_review` to `phase5_post_review`, ensuring stop-guard routes to the correct next branch rather than repeatedly blocking and incrementing `error_count` (fixes #719):

```bash
bash {plugin_root}/hooks/flow-state-update.sh create \
  --phase "phase5_post_review" --issue {issue_number} --branch "{branch_name}" \
  --pr {pr_number} \
  --session {session_id} \
  --next "rite:pr:review completed. Check recent result pattern in context: [review:mergeable]->Phase 5.5 (ready). [review:fix-needed:{N}]->Phase 5.4.4 (fix). Do NOT stop."
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
  bash {plugin_root}/hooks/local-wm-update.sh 2>/dev/null || true
```

**Step 2.5**: Sync local work memory to Issue comment (backup):

> **Reference**: Uses `issue-comment-wm-sync.sh` which handles owner/repo resolution internally, backup creation, safety checks, and PATCH atomically (#204).

```bash
# ⚠️ このパターンは 5.4.6 (After Fix) と同一構造。変更時は両方を更新すること
bash {plugin_root}/hooks/issue-comment-wm-sync.sh update \
  --issue {issue_number} \
  --transform update-phase \
  --phase "phase5_post_review" --phase-detail "レビュー完了" \
  2>/dev/null || true
```

**Step 3**: Based on the review result pattern from `rite:pr:review`, execute the corresponding action **immediately**. Do **NOT** use the Edit tool to fix code directly — always invoke the appropriate Skill tool.

| Result Pattern | Action |
|----------------|--------|
| `[review:mergeable]` | **→ Proceed to Phase 5.5** (Ready for Review). Skip fix entirely. |
| `[review:fix-needed:{n}]` | **Invoke `skill: "rite:pr:fix"`** via the Skill tool (Phase 5.4.4). After it returns, proceed to 🚨 After Fix (5.4.6). |

> **禁止**: Edit ツールや Bash ツールでコードを直接修正してはならない。修正は必ず `skill: "rite:pr:fix"` を Skill ツールで呼び出して実行すること。

#### 5.4.4 Fix

Update `.rite-flow-state` (atomic):

```bash
bash {plugin_root}/hooks/flow-state-update.sh create \
  --phase "phase5_fix" --issue {issue_number} --branch "{branch_name}" \
  --pr {pr_number} \
  --session {session_id} \
  --next "After rite:pr:fix returns: [fix:pushed]->Phase 5.4.1 (re-review). [fix:issues-created]->Phase 5.4.1. [fix:replied-only]->Phase 5.5. [fix:error]->ask user. Do NOT stop."
```

> **Data Handoff**: When invoking `rite:pr:fix`, PR number and review results are passed via work memory. Issue information from Phase 0.1 is available in work memory, avoiding redundant `gh issue view` calls.

Invoke `skill: "rite:pr:fix"`.

**🚨 Immediate after fix returns**: When `rite:pr:fix` outputs a result pattern (`[fix:pushed]`, `[fix:issues-created:{N}]`, `[fix:replied-only]`, or `[fix:error]`) and returns control, do **NOT** churn or pause — **immediately** proceed to 5.4.6 🚨 After Fix below. The fix sub-skill has already updated `.rite-flow-state` to `phase5_post_fix` via its defense-in-depth mechanism (fixes #709); execute the 5.4.6 steps without delay.

#### 5.4.5 Fix Patterns

`[fix:pushed]`→5.4.1. `[fix:issues-created:{n}]`→5.4.1. `[fix:replied-only]`→5.5. `[fix:error]`→error, ask user.

#### 5.4.6 🚨 After Fix

> See [Sub-skill Return Protocol (Global)](#sub-skill-return-protocol-global).

**Verify**: Pattern confirmed, parsed.

**Step 1**: Update `.rite-flow-state` to post-fix phase (atomic). This second write (after the Phase 5.4.4 pre-write) transitions from `phase5_fix` to `phase5_post_fix`, ensuring stop-guard routes to the correct next branch rather than repeatedly blocking and incrementing `error_count` (fixes #709):

```bash
bash {plugin_root}/hooks/flow-state-update.sh create \
  --phase "phase5_post_fix" --issue {issue_number} --branch "{branch_name}" \
  --pr {pr_number} \
  --session {session_id} \
  --next "rite:pr:fix completed. Check recent result pattern in context: [fix:pushed]->Phase 5.4.1 (re-review). [fix:issues-created]->Phase 5.4.1. [fix:replied-only]->Phase 5.5. Do NOT stop."
```

**Step 2**: Sync to local work memory:

```bash
WM_SOURCE="fix" \
  WM_PHASE="phase5_post_fix" \
  WM_PHASE_DETAIL="修正完了" \
  WM_NEXT_ACTION="修正結果に基づき次アクションを実行" \
  WM_BODY_TEXT="Post-fix sync." \
  WM_ISSUE_NUMBER="{issue_number}" \
  bash {plugin_root}/hooks/local-wm-update.sh 2>/dev/null || true
```

**Step 2.5**: Sync local work memory to Issue comment (backup):

> **Reference**: Uses `issue-comment-wm-sync.sh` which handles owner/repo resolution internally, backup creation, safety checks, and PATCH atomically (#204).

```bash
# ⚠️ このパターンは 5.4.3 (After Review) と同一構造。変更時は両方を更新すること
bash {plugin_root}/hooks/issue-comment-wm-sync.sh update \
  --issue {issue_number} \
  --transform update-phase \
  --phase "phase5_post_fix" --phase-detail "修正完了" \
  2>/dev/null || true
```

**Step 3**: Based on the fix result pattern from `rite:pr:fix` **and** the preceding review result pattern, execute the corresponding action **immediately**. Do **NOT** use the Edit tool to fix code directly — always invoke the appropriate Skill tool.

| Fix Result Pattern | Preceding Review Pattern | Action |
|--------------------|--------------------------|--------|
| `[fix:pushed]` | _(any)_ | **Invoke `skill: "rite:pr:review", args: "{pr_number}"`** via the Skill tool (re-review, Phase 5.4.1). |
| `[fix:issues-created:{n}]` | _(any)_ | **Invoke `skill: "rite:pr:review", args: "{pr_number}"`** via the Skill tool (re-review, Phase 5.4.1). |
| `[fix:replied-only]` | _(any)_ | **→ Proceed to Phase 5.5** (Ready for Review). |
| `[fix:error]` | _(any)_ | Ask the user how to proceed via `AskUserQuestion` (retry / skip to 5.6 / terminate). |

> **禁止**: Edit ツールや Bash ツールでコードを直接修正してはならない。修正は必ず `skill: "rite:pr:fix"` を Skill ツールで呼び出して実行すること。再レビューは必ず `skill: "rite:pr:review"` を Skill ツールで呼び出すこと。

### 5.5 Ready for Review

> **⚠️ MANDATORY**: The following `AskUserQuestion` confirmation MUST be executed. Do NOT skip this step for context optimization or any other reason. The user must always confirm before changing the PR to Ready for review.

When loop completes, confirm via `AskUserQuestion`:

```
レビューが完了しました（一気通貫フロー）
総合評価: {assessment}
指摘件数: {total_findings}
オプション: Ready for review に変更（推奨）/ ドラフトのまま完了 / 追加の修正を行う
```

> **Data Handoff**: When invoking `rite:pr:ready`, PR number is passed as an argument. Issue information from Phase 0.1 is available in work memory (loaded by `rite:pr:ready` Phase 0), avoiding redundant `gh issue view` calls.

**Ready**→invoke `rite:pr:ready`→5.5.1. **Draft**→5.6. **More fixes**→terminate.

**🚨 Immediate after ready returns**: When `rite:pr:ready` outputs `[ready:completed]` and returns control, do **NOT** churn or pause — **immediately** proceed to 5.5.0.1 🚨 Mandatory After 5.5 below. The ready sub-skill has already updated `.rite-flow-state` to `phase5_post_ready` via Phase 4.6 (defense-in-depth, fixes #17); execute the 5.5.0.1 steps without delay. The completion report (Phase 5.6) has NOT been output yet — `ready.md` intentionally skips it in e2e flow. You MUST continue to Phase 5.5.1, 5.5.2, and 5.6.

**Results**: `[ready:completed]`→5.5.0.1→5.5.1→5.5.2→5.6. `[ready:error]`→ask user (retry / skip to 5.6 / terminate).

#### 5.5.0.1 🚨 Mandatory After 5.5

> See [Sub-skill Return Protocol (Global)](#sub-skill-return-protocol-global).

**Verify**: `[ready:completed]` pattern confirmed. `rite:pr:ready` returned successfully. Status update, metrics recording, and completion report are still pending — these are the **primary deliverables** of the e2e flow that the user expects to see.

**Step 1**: Update `.rite-flow-state` to post-ready phase (atomic). This write transitions from `phase5_post_review`/`phase5_post_fix` to `phase5_post_ready`, ensuring stop-guard routes to Status update rather than re-invoking ready (fixes #781):

```bash
bash {plugin_root}/hooks/flow-state-update.sh create \
  --phase "phase5_post_ready" --issue {issue_number} --branch "{branch_name}" \
  --pr {pr_number} \
  --session {session_id} \
  --next "Phase 5.5.1: Update Issue Status to In Review, then Phase 5.5.2 metrics, then Phase 5.6 completion report. Do NOT stop."
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
  bash {plugin_root}/hooks/local-wm-update.sh 2>/dev/null || true
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
| `review_fix_loops` | PR comments | Count `📜 rite レビュー結果` comments on the PR: `gh api repos/{owner}/{repo}/issues/{pr_number}/comments --jq '[.[] | select(.body | contains("📜 rite レビュー結果"))] | length'` |
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
bash {plugin_root}/hooks/flow-state-update.sh patch \
  --phase "completed" \
  --next "none" --active false
```

**After flow state update (regardless of success/failure)**: Clean up `.rite-compact-state` to prevent stale blocked state from affecting the next session (#756):

```bash
rm -f .rite-compact-state 2>/dev/null || true
rm -rf .rite-compact-state.lockdir 2>/dev/null || true
```

**Note**: This cleanup is non-blocking. Failure to delete is silently ignored.

### 5.6 Completion Report

> See [completion-report.md](./completion-report.md) for the full procedure (template read, placeholder substitution, output cases, self-verification, and inline fallbacks).

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
