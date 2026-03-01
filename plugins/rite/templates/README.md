# Template Variables Reference

This document catalogs all template variables used across rite workflow templates and commands.

## Variable Format

Variables use the following formats:
- `{variable_name}` — Standard placeholder
- `#{number}` — Issue/PR number with hash prefix
- Pattern strings — Used in branch names like `{type}/issue-{number}-{slug}`

## Variable Categories

### Repository Information

| Variable | Description | Source | Example |
|----------|-------------|--------|---------|
| `{owner}` | Repository owner (user or organization) | `gh repo view --json owner --jq '.owner.login'` | `B16B1RD` |
| `{repo}` | Repository name | `gh repo view --json name --jq '.name'` | `cc-rite-workflow` |
| `{default_branch}` | Repository default branch | `gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name'` | `main` or `develop` |

### Issue Information

| Variable | Description | Source | Example |
|----------|-------------|--------|---------|
| `{number}` | Issue number | Command argument or branch detection | `531` |
| `#{number}` | Issue number with `#` prefix | Same as `{number}` with formatting | `#531` |
| `{issue_number}` | Issue number (alias) | Same as `{number}` | `531` |
| `#{issue_number}` | Issue number with `#` prefix | Same as `#{number}` | `#531` |
| `{title}` | Issue title | `gh issue view --json title --jq '.title'` | `Fix workflow diagram` |
| `{issue_title}` | Issue title (alias) | Same as `{title}` | `Fix workflow diagram` |
| `{state}` | Issue state | `gh issue view --json state --jq '.state'` | `OPEN`, `CLOSED` |

### Pull Request Information

| Variable | Description | Source | Example |
|----------|-------------|--------|---------|
| `{pr_number}` | PR number | `gh pr create` output or `gh pr view` | `536` |
| `#{pr_number}` | PR number with `#` prefix | Same as `{pr_number}` with formatting | `#536` |
| `{pr_state}` | PR state | `gh pr view --json state --jq '.state'` | `OPEN`, `MERGED`, `CLOSED` |
| `{pr_url}` | PR URL | `gh pr view --json url --jq '.url'` | `https://github.com/owner/repo/pull/536` |
| `{isDraft}` | Whether PR is draft | `gh pr view --json isDraft --jq '.isDraft'` | `true`, `false` |

### Branch Information

| Variable | Description | Source | Example |
|----------|-------------|--------|---------|
| `{branch}` | Branch name | `git branch --show-current` or `git rev-parse --abbrev-ref HEAD` | `fix/issue-531-workflow-diagram` |
| `{branch_name}` | Branch name (alias) | Same as `{branch}` | `fix/issue-531-workflow-diagram` |
| `{current_branch}` | Current branch name | Same as `{branch}` | `fix/issue-531-workflow-diagram` |
| `{base_branch}` | Base branch for PR | `rite-config.yml` `branch.base` or repo default | `develop` or `main` |
| `{type}` | Branch type prefix | Extracted from branch pattern | `fix`, `feat`, `docs` |
| `{slug}` | Branch slug suffix | Extracted from branch pattern | `workflow-diagram` |

### Project Management (GitHub Projects)

| Variable | Description | Source | Example |
|----------|-------------|--------|---------|
| `{status}` | GitHub Projects status | Projects API | `Todo`, `In Progress`, `In Review`, `Done` |
| `{project_number}` | GitHub Projects project number | `rite-config.yml` or Projects API | `1` |
| `{project_url}` | GitHub Projects URL | Projects API | `https://github.com/users/owner/projects/1` |
| `{iteration_title}` | Iteration/Sprint title | Projects API iteration field | `Sprint 2026-02` |
| `{field_name}` | Custom field name | Projects API | `Priority`, `Complexity` |

### Work Memory & Session

| Variable | Description | Source | Example |
|----------|-------------|--------|---------|
| `{command}` | Command being executed | Work memory `コマンド` field | `/rite:issue:start` |
| `{phase}` | Work phase | Work memory `フェーズ` field | `実装作業中`, `品質検証` |
| `{phase_detail}` | Phase detail | Work memory or command context | `PR 作成中` |
| `{timestamp}` | Timestamp | ISO 8601 format | `2026-02-10T07:00:00Z` |
| `{hours}` | Time in hours | Calculated from timestamp | `2` |

### Code & Quality Metrics

| Variable | Description | Source | Example |
|----------|-------------|--------|---------|
| `{score}` | Quality score | Issue analysis result | `A`, `B`, `C`, `D` |
| `{changed_files_count}` | Number of changed files | `git diff --stat` | `3` |
| `{review_result}` | Review result | Review command output | `マージ可`, `要修正` |

### Configuration

| Variable | Description | Source | Example |
|----------|-------------|--------|---------|
| `{project_type}` | Project type | `rite-config.yml` `project.type` | `webapp`, `library`, `cli` |
| `{language}` | Configured language | `rite-config.yml` `language` | `ja`, `en`, `auto` |

---

## Template Files Using Variables

### Issue Templates

- **`templates/issue/default.md`**
  - `{owner}` — Repository owner in footer link
- **`templates/issue/template-structure.md`**
  - `{owner}` — Repository owner in footer link
  - Extracted from `default.md` — contains Section 0-9 template structure

### PR Templates

All PR templates use these common variables:

- **`templates/pr/generic.md`**
- **`templates/pr/webapp.md`**
- **`templates/pr/library.md`**
- **`templates/pr/cli.md`**
- **`templates/pr/documentation.md`**

Common variables:
- `{issue_number}` or `#{issue_number}` — Related issue reference
- `{owner}` — Repository owner in footer link

### Report Templates

- **`templates/completion-report.md`**
  - `{number}`, `{title}`, `{owner}`, `{repo}`, `{branch_name}`, `{iteration_title}`, `{score}`, `{pr_number}`, `{pr_state}`, `{status}`, `{changed_files_count}`, `{review_result}`

---

## Variable Replacement Rules

### When Variables Are Replaced

Variables are replaced at runtime by the command that reads the template:

1. **Issue creation** (`/rite:issue:create`)
   - Reads: `templates/issue/{type}.md`
   - Replaces: `{owner}`

2. **PR creation** (`/rite:pr:create`)
   - Reads: `templates/pr/{project_type}.md`
   - Replaces: `{issue_number}`, `{owner}`

3. **Work memory updates** (`/rite:issue:update`, `/rite:issue:start`)
   - Reads: `templates/completion-report.md`
   - Replaces: All work-related variables

4. **Error messages** (all commands)
   - Inline replacement in command Markdown

### Replacement Implementation

Commands use these methods to replace variables:

```bash
# Example: Replace {owner} and {repo}
owner=$(gh repo view --json owner --jq '.owner.login')
repo=$(gh repo view --json name --jq '.name')

# Read template and replace
sed -e "s/{owner}/$owner/g" \
    -e "s/{repo}/$repo/g" \
    templates/pr/generic.md
```

Or in command instructions:

```markdown
Read the template file, then replace the following placeholders:
- `{owner}` → repository owner
- `{issue_number}` → issue number
```

---

## Adding New Variables

When adding new variables:

1. **Choose a descriptive name** following existing patterns:
   - Repository info: `{repo}`, `{owner}`, `{default_branch}`
   - Issue/PR info: `{number}`, `{title}`, `{state}`
   - Metrics: `{score}`, `{count}`, `{hours}`

2. **Document in this file**:
   - Add to appropriate category table
   - Specify source command
   - Provide example value

3. **Update related templates**:
   - Add variable to template files
   - Update command that reads the template
   - Add replacement logic

4. **Test replacement**:
   - Verify variable is replaced correctly
   - Check edge cases (missing data, special characters)

---

## Special Cases

### Pattern-Matched Strings (DO NOT USE AS VARIABLES)

These are **fixed strings** used in work memory format and must NOT be used as template variables:

- `📜 rite 作業メモリ`, `📜 rite レビュー結果`
- Field names: `セッション情報`, `フェーズ`, `コマンド`, `状態`, `備考`, `次のステップ`
- Phase values: `実装作業中`, `品質検証`, `PR作成中`, `レビュー中`
- Evaluation: `可`, `条件付き`, `要修正`, `マージ可`, `マージ不可（指摘あり）`, `修正必要`

### Optional Variables

Some variables are conditionally included:

- `{iteration_title}` — Only when iteration is enabled in config
- `{pr_number}` — Only after PR is created
- `{review_result}` — Only after review is completed

Commands should check for these variables and handle their absence gracefully.

---

## References

- [Completion Report Template](completion-report.md) — Full format specification
- [Work Memory Format](../references/work-memory-format.md) — Work memory structure
- [gh CLI Patterns](../references/gh-cli-patterns.md) — GitHub CLI command patterns

---

📜 Generated with rite workflow
