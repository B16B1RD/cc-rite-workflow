---
name: rite-workflow
description: |
  Coordinates rite Issue-driven development workflow including branch creation,
  PR management, and GitHub Projects integration. Activates when user mentions
  "start issue", "create PR", "next steps", "workflow", "rite", "branch naming",
  "commit format", "Issue作業", "ブランチ", "コミット規約", "PR作成",
  "作業開始", "ワークフロー", "次のステップ", "ブランチ命名", or asks about
  development workflow. Use for workflow state detection, phase transitions,
  and command suggestions.
---

# Rite Workflow Skill

This skill provides context for rite workflow operations.

## Auto-Activation Keywords

- Issue, PR, Pull Request
- workflow, rite
- branch, commit
- GitHub Projects
- review, lint

## Context

When activated, this skill provides:

1. **Workflow Awareness**
   - Current branch and associated Issue
   - Work memory state
   - Status in GitHub Projects

2. **Command Guidance**
   - Suggest appropriate commands
   - Remind about work memory updates
   - Guide through workflow steps

3. **Best Practices**
   - Conventional Commits format
   - Branch naming conventions
   - PR template usage

4. **Coding Principles**
   - Avoid common AI coding failure patterns
   - See [references/coding-principles.md](./references/coding-principles.md) for details

5. **Common Principles**
   - Reduce excessive AskUserQuestion usage
   - See [references/common-principles.md](./references/common-principles.md) for details

## Workflow State Detection

Detect current state from:
- Branch name pattern: `{type}/issue-{number}-*`
  - `{type}` values: `feat`, `fix`, `docs`, `refactor`, `chore`, `style`, `test`
  - `style` is used for code style/formatting changes (no logic changes)
- Git status
- Open PRs

## Suggested Actions

| State | Suggestion |
|-------|------------|
| On main/develop, no Issue | `/rite:issue:create` or `/rite:issue:list` |
| On feature branch, no PR | `/rite:pr:create` after work |
| PR open, draft | `/rite:pr:review` then `/rite:pr:ready` |
| Long session (30+ minutes elapsed) | `/rite:issue:update` |
| Sprint with Todo Issues available | `/rite:sprint:execute` to run Issues sequentially |
| Sprint with multiple independent Issues | `/rite:sprint:team-execute` to run Issues in parallel with worktrees |

## Question Management

> **Key Principle**: Always apply `question_self_check` (see [references/common-principles.md](./references/common-principles.md)) before asking questions. Most questions can be avoided through context inference and using sensible defaults.

### When Questions Are Necessary

Ask immediately (do not defer) when:
- **Blockers**: Issues that prevent further progress
- **Security-related**: Decisions affecting security
- **Destructive operations**: Actions that cannot be undone
- **External impacts**: Changes affecting users or external systems

### Work Memory Integration

If questions arise during work, record them in the work memory comment under "要確認事項" (Items to Confirm):

```markdown
### 要確認事項

1. [ ] {confirmation_item_1}
2. [ ] {confirmation_item_2}
```

### Expected Question Frequency by Phase

| Phase | Typical Questions | Notes |
|-------|------------------|-------|
| **Issue Start** (Phase 1.3) | 0-1 questions | Only for score C/D Issues with insufficient information |
| **Implementation** (Phase 5) | 0 questions | Use defaults and infer from context; record ambiguities in work memory |
| **PR Review** (review/fix loop) | 0-1 questions | Only for critical architectural decisions |

**Target**: Minimize questions through context inference and sensible defaults. Record non-blocking questions in work memory for batch review.

## Session Start Auto-Detection

Automatically detect work state at session start and notify if interrupted work exists.

See [references/session-detection.md](./references/session-detection.md) for details.

### Quick Reference

1. Extract Issue number from branch name (`{type}/issue-{number}-*` pattern)
2. Fetch work memory comment from the Issue
3. Extract and display phase information

See [references/phase-mapping.md](./references/phase-mapping.md) for phase list.

See [references/work-memory-format.md](./references/work-memory-format.md) for work memory format.

## AI Coding Principles (Summary)

Principles to avoid common failure patterns in AI coding agents.

| Principle | Summary | When to Apply |
|-----------|---------|---------------|
| assumption_surfacing | Surface assumptions explicitly and confirm before proceeding | Implementation planning & coding |
| confusion_management | Stop and confirm when contradictions or unknowns are detected | Issue quality check & planning |
| push_back_when_warranted | Push back when problems are found | PR review |
| simplicity_enforcement | Avoid excessive complexity | Implementation |
| scope_discipline | Only change what was requested | Implementation |
| dead_code_hygiene | Identify and confirm removal of dead code | Implementation |
| inline_planning | Present plan before implementing | Implementation planning |
| issue_accountability | Always address discovered issues; never dismiss as "out of scope" | All phases |

See [references/coding-principles.md](./references/coding-principles.md) for details.

**Note**: The `question_self_check` principle has been consolidated into Common Principles. See the section below.

## Common Principles (AskUserQuestion Reduction)

Principles to reduce excessive AskUserQuestion usage.

| Principle | Summary | When to Apply |
|-----------|---------|---------------|
| question_self_check | Self-check whether the question is truly necessary | All phases |
| default_value_usage | Use defaults when clearly available instead of confirming | Configuration lookup |
| context_inference | Infer from context instead of asking | All phases |

See [references/common-principles.md](./references/common-principles.md) for details.

## Preflight Guard (All Commands)

Before executing any `/rite:*` command, run the preflight guard. Resolve `{plugin_root}` per [references/plugin-path-resolution.md](../../references/plugin-path-resolution.md#resolution-script).

```bash
bash {plugin_root}/hooks/preflight-check.sh --command-id "{current_command_id}" --cwd "$(pwd)"
```

Replace `{current_command_id}` with the slash command being executed (e.g., `/rite:lint`, `/rite:pr:review`).

If exit code is `1` (blocked), stop execution and display the preflight output. Do NOT proceed.

## gh CLI Safety Rules

All `gh` commands that accept `--body` or `--comment` parameters **MUST** use safe patterns to avoid shell injection:

- Use `--body-file` with `mktemp` for multi-line content
- Reference: See `references/gh-cli-patterns.md` for detailed safe patterns

**Never** pass user-generated content directly via `--body` or `--comment` flags.

## Integration

This skill works with:
- All `/rite:*` commands
- GitHub CLI operations
- Git operations
