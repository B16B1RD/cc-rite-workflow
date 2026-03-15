---
description: コンテキストコミット履歴から過去の決定事項を検索
---

# /rite:issue:recall

コンテキストコミット履歴からアクションラインを検索・表示する。

---

## Contract

**Input**: 引数なし、`{scope}`、または `{action}({scope})`
**Output**: アクションラインのグループ化された検索結果

---

## Arguments

| Pattern | Description | Example |
|---------|-------------|---------|
| (なし) | 現在ブランチの全アクションライン要約 | `/rite:issue:recall` |
| `{scope}` | 全履歴から scope でフィルタ | `/rite:issue:recall auth` |
| `{action}({scope})` | 全履歴から action+scope でフィルタ | `/rite:issue:recall decision(oauth)` |

---

When this command is executed, run the following phases in order.

## Phase 1: Configuration Check

> **Reference**: [Contextual Commits Reference](../../skills/rite-workflow/references/contextual-commits.md) for action line format, generation source priority, and queryability patterns.

### 1.1 Read Configuration

Read `rite-config.yml` with the Read tool and check `commit.contextual`:

- `true` or not set -> proceed
- `false` -> display `{i18n:issue_recall_disabled}` and terminate

### 1.2 Base Branch

Read `branch.base` from `rite-config.yml` (default: `main`). Used in Phase 2.1 for current branch range.

---

## Phase 2: Argument Parsing

Parse the user-provided argument to determine the search mode:

### 2.1 Pattern Detection

```
入力: (空)
  → mode = "branch"
  → git_range = "{base_branch}..HEAD"

入力: "{action}({scope})" にマッチ (例: "decision(oauth)")
  → mode = "action_scope"
  → action = マッチした action type
  → scope = マッチした scope
  → Validate action ∈ {intent, decision, rejected, constraint, learned}
  → Invalid action → display "{i18n:issue_recall_invalid_action}" and terminate

入力: その他の文字列 (例: "auth")
  → mode = "scope"
  → scope = 入力文字列
```

---

## Phase 3: Git Log Search

### 3.1 Execute Search

Based on the mode determined in Phase 2:

**mode = "branch" (現在ブランチ)**:

Before executing git log, verify the base branch exists:

```bash
# Step 1: Verify base branch exists
git rev-parse --verify {base_branch} 2>/dev/null
# If fails, try remote:
git rev-parse --verify origin/{base_branch} 2>/dev/null
# If both fail: display "{i18n:issue_recall_error_no_base_branch}" and terminate
```

Use `{base_branch}` if local exists, otherwise `origin/{base_branch}`:

```bash
git log {base_branch}..HEAD --format="%H%n%s%n%ai%n%b---COMMIT_END---" --max-count=200
```

**mode = "scope"**:

```bash
git log --all --fixed-strings --grep="({scope}" --format="%H%n%s%n%ai%n%b---COMMIT_END---" --max-count=100
```

**mode = "action_scope"**:

```bash
git log --all --fixed-strings --grep="{action}({scope}" --format="%H%n%s%n%ai%n%b---COMMIT_END---" --max-count=100
```

### 3.2 Empty Result Handling

If no commits are found:

```
{i18n:issue_recall_no_results}
```

Display guidance based on mode:
- **branch**: `{i18n:issue_recall_no_results_branch_hint}`
- **scope/action_scope**: `{i18n:issue_recall_no_results_scope_hint}`

Terminate.

---

## Phase 4: Action Line Extraction

### 4.1 Parse Commits

Split the git log output by `---COMMIT_END---` delimiter. For each commit block, parse by newline position:

- **Line 1**: `hash` — full commit SHA (display first 7 chars)
- **Line 2**: `subject` — commit subject line
- **Line 3**: `date` — author date (ISO-like format from `%ai`)
- **Line 4+**: `body` — commit body (all remaining lines until the delimiter)

### 4.2 Extract Action Lines

From each commit body, extract lines matching the action line pattern:

```
Pattern: /^(intent|decision|rejected|constraint|learned)\([^)]+\): .+$/gm
```

For each matched line, parse:
- `action`: action type (intent/decision/rejected/constraint/learned)
- `scope`: scope value within parentheses
- `description`: description after `: `

### 4.3 Filter by Mode

- **mode = "branch"**: Keep all extracted action lines
- **mode = "scope"**: Keep only lines where scope starts with the specified scope (prefix match)
- **mode = "action_scope"**: Keep only lines where action and scope match

---

## Phase 5: Result Formatting

### 5.1 Group by Scope

Group the extracted action lines by scope:

```markdown
## 🔍 コンテキストコミット検索結果

**検索条件**: {search_description}
**検索範囲**: {range_description}
**結果**: {total_count} 件のアクションライン（{commit_count} コミット）

### scope: {scope_1}

| Type | Description | Commit | Date |
|------|-------------|--------|------|
| `intent` | {description} | {hash} {subject} | {date} |
| `decision` | {description} | {hash} {subject} | {date} |

### scope: {scope_2}

| Type | Description | Commit | Date |
|------|-------------|--------|------|
| `rejected` | {description} | {hash} {subject} | {date} |
```

### 5.2 Search Description

| Mode | Description |
|------|-------------|
| branch | `現在ブランチ ({branch_name}) の全アクションライン` |
| scope | `全履歴から scope "{scope}" を検索` |
| action_scope | `全履歴から {action}({scope}) を検索` |

### 5.3 Summary Statistics

After the grouped results, display a summary:

```markdown
### サマリー

| Action Type | Count |
|-------------|-------|
| intent | {count} |
| decision | {count} |
| rejected | {count} |
| constraint | {count} |
| learned | {count} |
```

### 5.4 Large Result Handling

If total action lines exceed 50:

```
{i18n:issue_recall_large_result}
```

Suggest narrowing with a more specific scope or action type filter.

---

## Error Handling

| Error | Response |
|-------|----------|
| Not in a git repository | `{i18n:issue_recall_error_not_git}` |
| Base branch not found (mode=branch) | `{i18n:issue_recall_error_no_base_branch}` |
| No commits in range | Phase 3.2 empty result handling |
| Git command failure | Display error and terminate |
