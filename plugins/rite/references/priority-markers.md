# Rite Workflow Priority Markers

Standard notation for indicating instruction priority levels.

---

## Overview

Priority markers help distinguish critical requirements from optional enhancements. This document defines the standard notation for four priority levels used throughout rite workflow documentation.

---

## Priority Levels

| Level | Name | Notation | Meaning | Consequence of Violation |
|-------|------|----------|---------|--------------------------|
| 1 | CRITICAL | Blockquote + ⚠️ + ALL CAPS | System will break or produce incorrect results | Data loss, corruption, or workflow failure |
| 2 | MUST | **Bold** + Imperative | Required for correctness | Incorrect behavior or unexpected results |
| 3 | SHOULD | Regular text + Imperative | Recommended practice | Suboptimal but functional |
| 4 | MAY | Regular text + Suggestive | Optional enhancement | No negative impact |

---

## Priority 1: CRITICAL

### Notation

```markdown
> ⚠️ **CRITICAL: INSTRUCTION TEXT IN ALL CAPS**
```

### When to Use

- **Security vulnerabilities**: Actions that could expose credentials or sensitive data
- **Data integrity**: Operations that could corrupt state or lose work
- **Workflow integrity**: Violations that break the entire workflow
- **Irreversible operations**: Actions that cannot be undone

### Examples

#### Example 1: Security - Preventing Public Exposure

```markdown
> ⚠️ **CRITICAL: NEVER INCLUDE API KEYS, PASSWORDS, OR CREDENTIALS IN WORK MEMORY**
>
> Work memory is posted as Issue comments and is publicly visible on public repositories.
> Including credentials exposes them to third parties and creates a security breach.
```

**Why CRITICAL**: Exposing credentials is a security incident with immediate and severe consequences.

---

#### Example 2: Data Integrity - Preventing State Corruption

```markdown
> ⚠️ **CRITICAL: DO NOT MODIFY .rite-flow-state MANUALLY DURING WORKFLOW EXECUTION**
>
> The state file is managed by hooks and workflow commands. Manual modifications during
> execution can corrupt the state and cause workflow failures that are difficult to debug.
```

**Why CRITICAL**: Corrupted state can break the entire workflow and require manual intervention to recover.

---

#### Example 3: Workflow Integrity - Preventing Infinite Loops

```markdown
> ⚠️ **CRITICAL: CHECK stop_hook_active=true BEFORE ANY STATE FILE OPERATIONS**
>
> If the check is omitted, the hook will enter an infinite loop causing Claude Code to hang.
> This check must be the first operation in the hook, before any file reads.
```

**Why CRITICAL**: Infinite loops cause system hangs and require force-termination.

---

#### Example 4: Irreversible Operations - Preventing Data Loss

```markdown
> ⚠️ **CRITICAL: NEVER USE git clean -fd OR git reset --hard WITHOUT USER CONFIRMATION**
>
> These commands permanently delete uncommitted work and cannot be undone.
> Always use AskUserQuestion to confirm destructive operations.
```

**Why CRITICAL**: Permanent data loss with no recovery mechanism.

---

## Priority 2: MUST

### Notation

```markdown
**Must perform action** - explanation
```

### When to Use

- **Correctness requirements**: Actions necessary for correct behavior
- **Required validations**: Checks that prevent errors
- **Mandatory parameters**: Fields that must be provided
- **Essential error handling**: Error cases that must be handled

### Examples

#### Example 1: Correctness - Required Validation

```markdown
**Must verify Issue exists before starting work** - Attempting to start a non-existent
Issue will fail and waste time. Check with `gh issue view {number}` before creating
the feature branch.
```

**Why MUST**: Skipping this check leads to workflow failures and wasted effort.

---

#### Example 2: Required Parameter - Preventing Invalid State

```markdown
**Must include issue_number in work memory** - The Issue number is required for state
restoration after context compaction. Work memory without issue_number cannot be resumed.
```

**Why MUST**: Without this field, the workflow cannot resume after interruption.

---

#### Example 3: Error Handling - Preventing Silent Failures

```markdown
**Must check exit code after running test command** - Test failures indicate problems
that must be addressed before creating a PR. Proceeding without checking exit codes
allows broken code to be submitted for review.
```

**Why MUST**: Unchecked failures lead to submitting broken code.

---

#### Example 4: Mandatory Process - Ensuring Quality

```markdown
**Must run /rite:lint before creating PR** - Lint checks catch common issues early.
Skipping this step results in PRs with preventable problems that waste reviewer time.
```

**Why MUST**: Essential for maintaining code quality and efficient reviews.

---

## Priority 3: SHOULD

### Notation

```markdown
Run command X - rationale for recommendation
```

or

```markdown
Follow pattern Y - explanation of benefit
```

### When to Use

- **Best practices**: Recommended approaches that improve quality
- **Optimization**: Actions that improve performance or efficiency
- **Consistency**: Patterns that maintain uniformity
- **User experience**: Improvements that make the workflow smoother

### Examples

#### Example 1: Best Practice - Improving Code Quality

```markdown
Run tests before committing changes - This catches regressions early and prevents
broken code from being pushed. While not strictly required, this practice significantly
reduces debugging time and failed CI runs.
```

**Why SHOULD**: Improves quality but the system still functions without it.

---

#### Example 2: Optimization - Improving Performance

```markdown
Use `git diff --name-only` when only filenames are needed - Retrieving full diffs is
slower and uses more memory. For operations that only need file lists, the name-only
flag provides a performance benefit.
```

**Why SHOULD**: Better performance but full diffs would still work.

---

#### Example 3: Consistency - Maintaining Standards

```markdown
Follow Conventional Commits format for commit messages - This maintains consistency
across the codebase and enables automated changelog generation. Non-conventional
commits still work but reduce automation benefits.
```

**Why SHOULD**: Improves consistency and automation, but doesn't break functionality.

---

#### Example 4: User Experience - Improving Clarity

```markdown
Include context in commit messages beyond just "fix typo" - More descriptive messages
help future developers understand changes. Minimal messages are technically sufficient
but provide less value for code archaeology.
```

**Why SHOULD**: Better UX and maintainability, but minimal messages are functional.

---

## Priority 4: MAY

### Notation

```markdown
Consider option X - description of optional benefit
```

or

```markdown
Optionally configure Y - explanation of enhancement
```

### When to Use

- **Optional features**: Enhancements that some users may want
- **Preferences**: Configurable options without right/wrong choices
- **Advanced features**: Capabilities for power users
- **Convenience**: Shortcuts or helpers that save minor effort

### Examples

#### Example 1: Optional Feature - Projects Integration

```markdown
Optionally enable GitHub Projects integration - Projects provide kanban-style workflow
visualization. The plugin works without Projects, but teams who use kanban boards may
find the integration valuable for tracking progress.
```

**Why MAY**: Useful for some users but completely optional.

---

#### Example 2: Preference - Language Settings

```markdown
Configure language preference in rite-config.yml - Set to `ja`, `en`, or `auto` to
control output language. The `auto` setting works well for most users, but explicit
settings provide more control.
```

**Why MAY**: Personal preference with no correctness implications.

---

#### Example 3: Convenience - Shell Aliases

```markdown
Consider creating shell aliases for frequently used commands - Shortcuts like
`alias zil="/rite:issue:list"` can save typing for power users who frequently use
the CLI interface.
```

**Why MAY**: Minor convenience with no functional impact.

---

#### Example 4: Advanced Feature - Custom Reviewers

```markdown
Optionally add custom reviewer agents - The default reviewers cover common scenarios.
Advanced users can create custom reviewers for domain-specific checks (e.g., compliance,
architecture patterns).
```

**Why MAY**: Advanced capability not needed by most users.

---

## Usage Guidelines

### For Documentation Writers

1. **Default to SHOULD or MAY** - Reserve CRITICAL and MUST for genuine requirements
2. **Be specific about consequences** - Explain what happens if ignored
3. **Use consistent notation** - Follow the formats exactly as specified
4. **Consider the audience** - What's MUST for beginners might be SHOULD for experts

### For Command Implementers

1. **Enforce CRITICAL with validation** - Use checks and guards for CRITICAL rules
2. **Enforce MUST with warnings** - Alert users when skipping MUST requirements
3. **Make SHOULD visible** - Display recommendations but don't block
4. **Keep MAY unobtrusive** - Mention optionally without cluttering output

### Decision Tree

```
Is violation a security risk or causes data loss?
├─ YES → CRITICAL
└─ NO → Does it break core functionality?
        ├─ YES → MUST
        └─ NO → Is it a best practice with clear benefits?
                ├─ YES → SHOULD
                └─ NO → MAY
```

---

## Anti-Patterns

### ❌ Overusing CRITICAL

**Bad**:
```markdown
> ⚠️ **CRITICAL: USE MEANINGFUL VARIABLE NAMES**
```

**Why Bad**: Poor naming is a code quality issue, not a system-breaking problem.

**Correct**:
```markdown
Use meaningful variable names - Clear names improve readability and maintainability.
Avoid single-letter variables except for loop counters.
```

---

### ❌ Underusing MUST

**Bad**:
```markdown
Verify the Issue exists before starting work - saves time
```

**Why Bad**: This is not optional; skipping it causes failures.

**Correct**:
```markdown
**Must verify Issue exists before starting work** - Attempting to start a non-existent
Issue will fail with [ZEN-E100]. Check with `gh issue view {number}` first.
```

---

### ❌ Vague Consequences

**Bad**:
```markdown
**Must commit changes** - important for workflow
```

**Why Bad**: Doesn't explain what breaks or why it matters.

**Correct**:
```markdown
**Must commit changes before switching branches** - Uncommitted changes will be lost
when switching branches. Git will block the switch if changes conflict with the target
branch.
```

---

### ❌ Missing Rationale

**Bad**:
```markdown
Run tests
```

**Why Bad**: Unclear if optional or required, and no explanation of benefit.

**Correct**:
```markdown
Run tests before pushing - Catches regressions early and prevents broken builds in CI.
Use `npm test` or the command configured in rite-config.yml.
```

---

## Enforcement Mechanisms

| Priority | Enforcement Method | Example |
|----------|-------------------|---------|
| CRITICAL | Runtime checks, early returns | `if stop_hook_active; then exit 0` |
| MUST | Validation errors, warning messages | `[ZEN-E102] Issue quality insufficient` |
| SHOULD | Informational warnings, suggestions | `💡 Tip: Run /rite:lint before creating PR` |
| MAY | Documentation only | Listed in "Optional Features" section |

---

## See Also

- [Common Principles](../skills/rite-workflow/references/common-principles.md) - General workflow principles
- [Coding Principles](../skills/rite-workflow/references/coding-principles.md) - Code-specific guidelines
- [Error Codes](./error-codes.md) - Standardized error codes and recovery steps
