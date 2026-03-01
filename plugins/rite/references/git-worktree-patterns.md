# Git Worktree Patterns

Operation patterns for `git worktree` to provide independent working directories for parallel agents, solving the shared working directory problem.

## Overview

When `parallel.mode: "worktree"` is set in `rite-config.yml`, each parallel agent receives its own worktree directory instead of sharing the repository's main working directory. This eliminates the critical problem where `git checkout` by one agent interferes with another.

> **Background**: When all agents share the same git working directory, `git checkout` by one agent interferes with another — commits land on wrong branches, and parallel work becomes unreliable. The worktree mode solves this by giving each agent an independent directory.

### Table of Contents

- [Worktree Lifecycle](#worktree-lifecycle) - Creation, usage, and removal flow
- [Worktree Creation](#worktree-creation) - `git worktree add` patterns
- [Agent Execution in Worktree](#agent-execution-in-worktree) - Agent working directory specification via prompt
- [Quality Gate per Worktree](#quality-gate-per-worktree) - Test and lint execution in each worktree
- [Merge Strategy](#merge-strategy) - `--no-ff` merge and integration flow
- [Conflict Resolution Convention](#conflict-resolution-convention) - Multi-agent edit conflict handling
- [Worktree Cleanup](#worktree-cleanup) - Removal and safety mechanisms
- [Safety Mechanisms](#safety-mechanisms) - Preventing forgotten worktree removal
- [Configuration Reference](#configuration-reference) - rite-config.yml settings

---

## Worktree Lifecycle

```
1. Orchestrator creates branch for Issue
2. For each parallel task:
   a. git worktree add <path> -b <task-branch> <base-branch>
   b. Spawn agent with prompt specifying worktree path as working directory
   c. Agent works (Read/Edit/Write only, NO git operations)
   d. Agent reports completion
3. Orchestrator validates each worktree:
   a. Run quality gate (test + lint) in each worktree
   b. Exclude failed worktrees from merge
4. Orchestrator merges each worktree branch:
   a. git merge --no-ff <task-branch>
   b. Handle conflicts (first-merge-wins convention)
5. Cleanup:
   a. git worktree remove <path>
   b. git branch -d <task-branch>
```

**Critical constraint**: Only the orchestrator performs git operations. Agents spawned via Task tool use only Read/Edit/Write/Glob/Grep/Bash (non-git) tools within their assigned worktree directory.

---

## Worktree Creation

Create a worktree for each independent parallel task identified in the implementation plan (Phase 5.1.0.1).

### Naming Convention

```
{worktree_base}/{issue_number}/{task_id}
```

- `{worktree_base}`: From `parallel.worktree_base` in rite-config.yml (default: `.worktrees`)
- `{issue_number}`: Current Issue number
- `{task_id}`: Task identifier from the implementation plan (e.g., `task-1`, `task-2`)

### Creation Command

```bash
# Ensure worktree base directory exists
mkdir -p {worktree_base}/{issue_number}

# Create worktree with a task-specific branch
git worktree add {worktree_base}/{issue_number}/{task_id} -b {issue_branch}/{task_id} {issue_branch}
```

Where `{issue_branch}` is the Issue's feature branch (e.g., `feat/issue-123-feature-name`).

### Example

```bash
mkdir -p .worktrees/651
git worktree add .worktrees/651/task-1 -b feat/issue-651-git-worktree-integration/task-1 feat/issue-651-git-worktree-integration
git worktree add .worktrees/651/task-2 -b feat/issue-651-git-worktree-integration/task-2 feat/issue-651-git-worktree-integration
```

---

## Agent Execution in Worktree

Agents are spawned using the Task tool with the worktree path specified in the prompt. The Task tool does not have a `cwd` parameter — instead, the prompt explicitly instructs the agent to use absolute paths within the worktree directory.

### Task Tool Invocation

```
Task tool parameters:
  subagent_type: "general-purpose"
  prompt: "{task_description}. Work ONLY in the directory {worktree_path}. Use ABSOLUTE paths for all file operations (e.g., {worktree_path}/src/file.ts). Do NOT run any git commands (checkout, commit, push, branch, merge, stash). You may use Read, Edit, Write, Glob, Grep, and Bash (for non-git commands like test/lint) tools."
```

**Enforcement rules for agents in worktree mode:**

| Allowed | Prohibited |
|---------|------------|
| Read (files in worktree) | git checkout |
| Edit (files in worktree) | git commit |
| Write (files in worktree) | git push |
| Glob (files in worktree) | git branch |
| Grep (files in worktree) | git merge |
| Bash (non-git commands: test, lint) | git stash |

### Path Scoping

Agents must only modify files within their assigned worktree path. The prompt should explicitly state the absolute worktree path and instruct the agent to use it for all file operations.

---

## Quality Gate per Worktree

Before merging, run quality checks in each worktree to ensure independent validation.

### Execution Flow

```bash
# For each worktree that completed successfully:
cd {worktree_path}

# Run tests (if configured)
if [ -n "{test_command}" ]; then
  {test_command}
  test_exit=$?
fi

# Run lint (if configured)
if [ -n "{lint_command}" ]; then
  {lint_command}
  lint_exit=$?
fi
```

### Result Handling

| Test Result | Lint Result | Action |
|-------------|-------------|--------|
| Pass (or N/A) | Pass (or N/A) | Include in merge |
| Fail | Any | Exclude from merge, report failure |
| Any | Fail | Exclude from merge, report failure |

**On partial failure**: Report which worktrees passed and which failed. Merge only passing worktrees. Failed tasks fall back to sequential implementation after merge.

---

## Merge Strategy

All worktree branches are merged back to the Issue branch using `--no-ff` (no fast-forward) to preserve merge commit history.

### Merge Flow

```bash
# Switch to the Issue's feature branch
git checkout {issue_branch}

# Merge each task branch (in dependency order if applicable)
git merge --no-ff {issue_branch}/task-1 -m "chore(parallel): integrate task-1 ({task_description})"
git merge --no-ff {issue_branch}/task-2 -m "chore(parallel): integrate task-2 ({task_description})"
```

### Why `--no-ff`

- Preserves the fact that work was done in parallel
- Creates a merge commit that serves as a documentation point
- Makes it easy to revert an entire parallel task if needed
- `git log --first-parent` shows clean integration history

---

## Conflict Resolution Convention

When multiple agents edit the same file (which should be avoided by proper task decomposition, but may happen):

### First-Merge-Wins Rule

1. The first worktree branch merged into the Issue branch takes precedence
2. Subsequent merges that conflict must rebase onto the updated Issue branch
3. After rebase, re-run quality gate before attempting merge again

### Resolution Flow

```bash
# If merge conflicts occur on task-2 after task-1 was merged:
git merge --abort

# Rebase task-2 onto updated Issue branch
# Note: Cannot use `git checkout` for a branch checked out in a worktree.
# Use `git -C` to run rebase within the worktree directory instead.
git -C {worktree_path_task_2} rebase {issue_branch}

# Resolve conflicts manually (orchestrator responsibility)
# ... edit conflicting files in {worktree_path_task_2} ...
git -C {worktree_path_task_2} add {resolved_files}
git -C {worktree_path_task_2} rebase --continue

# Re-run quality gate in the rebased worktree
cd {worktree_path_task_2}
{test_command}
{lint_command}

# Retry merge from the Issue branch
git checkout {issue_branch}
git merge --no-ff {issue_branch}/task-2
```

### Prevention

To minimize conflicts, the implementation plan should assign independent files to each parallel task (Phase 5.1.0.1 independence criteria). When file overlap is unavoidable, tasks should be executed sequentially instead of in parallel.

---

## Worktree Cleanup

After all merges are complete, remove worktrees and their associated branches.

### Cleanup Commands

```bash
# Remove each worktree
git worktree remove {worktree_base}/{issue_number}/task-1
git worktree remove {worktree_base}/{issue_number}/task-2

# Delete task branches (merged, no longer needed)
git branch -d {issue_branch}/task-1
git branch -d {issue_branch}/task-2

# Remove the Issue-specific worktree directory
rmdir {worktree_base}/{issue_number} 2>/dev/null || true

# Prune worktree metadata
git worktree prune
```

### Force Removal

If a worktree is in a dirty state (uncommitted changes from a failed agent):

```bash
# Force remove (discards uncommitted changes in the worktree)
git worktree remove --force {worktree_base}/{issue_number}/task-N
```

---

## Safety Mechanisms

Prevent worktree accumulation from forgotten cleanups.

### 1. Post-Merge Automatic Cleanup

After all merge operations complete in Phase 5.1.0.3 (Result Integration), the orchestrator **must** execute the cleanup commands above. This is enforced by including cleanup as the final step of the parallel implementation flow.

### 2. Stale Worktree Detection

At the start of worktree creation (Phase 5.1.0.2), check for existing worktrees from previous runs:

```bash
# List existing worktrees
git worktree list --porcelain

# Check for stale worktrees under the worktree base
ls -d {worktree_base}/*/* 2>/dev/null
```

If stale worktrees are found, display a warning and offer cleanup:

```
⚠️ 既存の worktree が検出されました:
{stale_worktree_paths}

オプション:
- クリーンアップして続行（推奨）: 古い worktree を削除して新規作成
- そのまま続行: 既存の worktree を無視して新規作成
- 中断: 手動で状況を確認
```

### 3. `.gitignore` Entry

The worktree base directory should be added to `.gitignore` to prevent accidental commits:

```
# Git worktrees for parallel agents
.worktrees/
```

### 4. Session End Cleanup Hook

The `pre-compact.sh` hook can check for leftover worktrees and include a warning in the compaction summary:

```bash
# In pre-compact.sh (optional enhancement)
worktree_count=$(git worktree list | wc -l)
if [ "$worktree_count" -gt 1 ]; then
  echo "WARNING: $((worktree_count - 1)) worktree(s) still exist" >&2
fi
```

---

## Configuration Reference

Settings in `rite-config.yml` that control worktree behavior:

```yaml
parallel:
  enabled: true          # Enable parallel implementation (default: true)
  max_agents: 3          # Maximum concurrent agents (default: 3)
  mode: "shared"         # "shared" (default) or "worktree"
  worktree_base: ".worktrees"  # Base directory for worktrees (default: ".worktrees")
```

| Setting | Values | Description |
|---------|--------|-------------|
| `parallel.mode` | `"shared"` (default) | Agents share the main working directory (current behavior) |
| | `"worktree"` | Each agent gets an independent worktree directory |
| `parallel.worktree_base` | Path string | Base directory for worktree creation (default: `.worktrees`) |

**When `mode: "shared"`**: The existing parallel implementation behavior (Phase 5.1.0.2) is used. No worktree operations are performed.

**When `mode: "worktree"`**: The orchestrator creates worktrees per this document's patterns. Agents are constrained to their worktree directories.
