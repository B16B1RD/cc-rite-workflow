# Best Practices for Claude Code Alignment

This document describes how rite workflow aligns with [Best Practices for Claude Code](https://code.claude.com/docs/en/best-practices).

## Overview

rite workflow has been reviewed and updated to follow Claude Code's official best practices, focusing on:

1. **Context Efficiency** - Minimize token usage, maximize effective context
2. **Verifiability** - Provide clear success/failure indicators
3. **Clear Instructions** - Use structured formats (tables, flowcharts, checklists)
4. **Separation of Concerns** - Reference content vs Task content

---

## Alignment Summary

| Best Practice | rite workflow Implementation | Related Files |
|--------------|----------------------------|---------------|
| **Keep CLAUDE.md concise** | Minimal CLAUDE.md with essential info only | `CLAUDE.md` |
| **Provide verification methods** | Each command has output patterns (success, error, skip) | `commands/*.md` |
| **Use subagents for research** | Review subagents for parallel code review | `agents/*.md` |
| **Extend knowledge with Skills** | Reference/Task content separation | `skills/*.md` |
| **Use context: fork** | Applied to info-display commands | `commands/issue/list.md`, `commands/sprint/*.md` |

---

## 1. CLAUDE.md Best Practices

### Recommendations Applied

| Recommendation | Implementation |
|----------------|----------------|
| Keep it concise | 20 lines, human-readable format |
| Only non-inferrable info | Workflow rules, commit conventions |
| Use emphasis | IMPORTANT markers for critical rules |
| Regular pruning | Removed directory structure (inferrable via `ls`) |

### Current Structure

```markdown
# CLAUDE.md

## Development Workflow
IMPORTANT: Follow Issue → Branch → PR order

## Commit Conventions
Conventional Commits format

## Key Commands
gh, git command patterns
```

---

## 2. Command Design Best Practices

### context: fork Application

Commands that display information without state changes use `context: fork`:

| Category | Commands | context: fork | Reason |
|----------|----------|---------------|--------|
| Information Display | `/rite:issue:list`, `/rite:sprint:list`, `/rite:sprint:current` | ✅ Applied | Results only, no state needed |
| Analysis | `/rite:skill:suggest`, `/rite:investigate` | ✅ Applied | Independent analysis |
| Read-only Display | `/rite:workflow` | ✅ Applied | Information display only |
| Interactive | `/rite:issue:create`, `/rite:issue:start` | ❌ Not Applied | User interaction required |
| State-changing | `/rite:pr:create`, `/rite:pr:cleanup`, `/rite:pr:ready` | ❌ Not Applied | Modifies repository state |
| Interactive + State-changing | `/rite:pr:review`, `/rite:pr:fix`, `/rite:lint` | ❌ Not Applied | `AskUserQuestion` required in e2e flow (#436) |

> **Note**: `context: fork` と `AskUserQuestion` は非互換です。`context: fork` 環境では `AskUserQuestion` がユーザーとの対話を完了できず、skill が accumulated output を返して終了します（#436）。Interactive なコマンドには `context: fork` を適用しないでください。

### Output Pattern Standardization

All commands follow consistent output patterns:

| Pattern | Format | Example |
|---------|--------|---------|
| Success | `[command:success]` | `[lint:success]` |
| Error | `[command:error]` | `[lint:error]` |
| Skipped | `[command:skipped]` | `[lint:skipped]` |

---

## 3. Skill Design Best Practices

### Frontmatter Compliance

All skills have proper frontmatter with:

```yaml
---
name: skill-name
description: |
  Multi-line description of skill purpose
  and auto-activation conditions.
---
```

### Reference vs Task Classification

| Skill | Classification | Reason |
|-------|---------------|--------|
| `rite-workflow` | Reference | Always-available workflow knowledge |
| `reviewers/*` | Reference | Review criteria, read-only knowledge |

### Auto-activation Keywords

Skills specify keywords for automatic activation:

```markdown
## Auto-Activation Keywords

- Issue, PR, Pull Request
- workflow, rite
- branch, commit
- GitHub Projects
- review, lint
```

---

## 4. Subagent Design Best Practices

### Agent Configuration

Each agent specifies:

| Field | Purpose | Example |
|-------|---------|---------|
| `name` | Unique identifier | `security-reviewer` |
| `description` | Short purpose description | Reviews for security vulnerabilities |
| `model` | Appropriate model selection | `opus` for security (high accuracy), `sonnet` for others |
| `tools` | Minimal required tools | `Read`, `Grep`, `Glob` |

### Current Agents

| Agent | Model | Tools | Focus |
|-------|-------|-------|-------|
| `security-reviewer` | opus | Read, Grep, Glob | Security vulnerabilities |
| `performance-reviewer` | sonnet | Read, Grep, Glob | Performance issues |
| `code-quality-reviewer` | sonnet | Read, Grep, Glob | Code quality |

### Why Different Models

- **opus for security**: High accuracy for vulnerability detection (cost vs. risk trade-off)
- **sonnet for others**: Pattern matching tasks, cost-efficient

---

## 5. Context Management Best Practices

### /clear Recommendations

rite workflow recommends `/clear` at these points:

| Timing | Reason |
|--------|--------|
| After Issue completion | Clear context before moving to new Issue |
| After PR merge | Clear context before next task |
| After prolonged error resolution | Remove accumulated failed approaches |
| After 2+ corrections | Reset to try fresh approach |

### Session Management

- `/rite:resume` for resuming interrupted work
- Work memory stored in Issue comments
- Phase information tracked for recovery

---

## 6. Verification Methods

### Command Output Verification

| Command | Verification Method |
|---------|---------------------|
| `/rite:init` | Configuration file generated, Projects linked |
| `/rite:issue:create` | Issue URL returned |
| `/rite:issue:start` | Branch created, Status updated |
| `/rite:lint` | Lint results (success/error/skip) |
| `/rite:pr:create` | PR URL returned |
| `/rite:pr:review` | Review summary with severity counts |
| `/rite:pr:cleanup` | Branch deleted, Status = Done |

### End-to-End Flow Verification

`/rite:issue:start` provides completion report:

```markdown
## Issue #123 の作業が完了しました

| 項目 | 内容 |
|------|------|
| Issue | #123 - Feature title |
| PR | #456 |
| PR 状態 | Draft / Ready |
```

---

## Related Issues

This alignment was implemented through:

- #315 - Best Practices gap analysis document
- #316 - CLAUDE.md improvements
- #317 - Command design review (context: fork)
- #318 - Skill design review
- #319 - Subagent design review
- #320 - Documentation update (this document)

---

## References

- [Best Practices for Claude Code](https://code.claude.com/docs/en/best-practices)
- [Rite Workflow Specification](SPEC.md)
- [Configuration Reference](CONFIGURATION.md)
