---
description: テンプレートを再生成
---

# /rite:template:reset

Regenerate templates

---

Execute the following phases in order when this command is run.

## Arguments

| Argument | Description |
|------|------|
| `--force` | Skip template overwrite confirmation (does not apply to rite-config.yml regeneration confirmation) |

---

## Phase 1: Configuration Check

### 1.1 Read rite-config.yml

Read configuration from the project root or `.claude/` directory:

```bash
# 設定ファイルの存在確認
ls rite-config.yml .claude/rite-config.yml 2>/dev/null
```

If the configuration file does not exist:

```
{i18n:template_reset_config_not_found}

{i18n:template_reset_config_not_found_hint}

オプション:
- {i18n:template_reset_option_run_init}
- {i18n:template_reset_option_cancel}
```

### 1.2 Confirm Project Type

Get `project.type` from the configuration file:

- `generic` - General purpose project
- `webapp` - Web application
- `library` - OSS library
- `cli` - CLI tool
- `documentation` - Documentation site

---

## Phase 2: Check Existing Templates

### 2.1 Detect Existing Files

Check the following files and directories:

```bash
# Issue テンプレート
ls -la .github/ISSUE_TEMPLATE/ 2>/dev/null

# PR テンプレート
ls -la .github/PULL_REQUEST_TEMPLATE.md 2>/dev/null

# 設定ファイル
ls -la rite-config.yml 2>/dev/null
```

### 2.2 Overwrite Confirmation (skipped when --force is specified)

If existing files are found, confirm with `AskUserQuestion`:

```
{i18n:template_reset_existing_found}:

| {i18n:template_reset_file} | {i18n:template_reset_last_modified} |
|---------|---------|
| .github/ISSUE_TEMPLATE/bug_report.md | 2025-01-01 |
| .github/PULL_REQUEST_TEMPLATE.md | 2025-01-01 |

{i18n:template_reset_ask_overwrite}？

オプション:
- {i18n:template_reset_option_all}
- {i18n:template_reset_option_issue_only}
- {i18n:template_reset_option_pr_only}
- {i18n:template_reset_option_cancel}
```

If `--force` is specified, skip the confirmation and overwrite all.

---

## Phase 3: Template Generation

### 3.0 Directory Preparation

Create necessary directories before generating templates:

```bash
# .github ディレクトリを作成（存在しない場合）
mkdir -p .github

# Issue テンプレート用ディレクトリを作成
mkdir -p .github/ISSUE_TEMPLATE
```

**Note:** `mkdir -p` automatically creates parent directories so order does not matter, but listing explicitly makes the intent clear.

---

### 3.1 Generate Issue Templates

Generate the following template files:

#### Default Issue Template

Reference `templates/issue/default.md` to generate `.github/ISSUE_TEMPLATE/task.md`:

```markdown
---
name: Task
about: General task or feature request
title: ''
labels: ''
assignees: ''
---

## Overview

<!-- Brief description of the task -->

## Background

<!-- Why is this needed? What problem does it solve? -->

## Acceptance Criteria

- [ ]

## Technical Notes

<!-- Any technical considerations, constraints, or implementation hints -->

## Related

<!-- Links to related issues, PRs, or documentation -->

---
🤖 Generated with [rite workflow](https://github.com/B16B1RD/cc-rite-workflow)
```

#### Bug Report Template

Generate `.github/ISSUE_TEMPLATE/bug_report.md`:

```markdown
---
name: Bug Report
about: Report a bug or unexpected behavior
title: '[Bug] '
labels: bug
assignees: ''
---

## Description

<!-- Clear description of the bug -->

## Steps to Reproduce

1.
2.
3.

## Expected Behavior

<!-- What should happen -->

## Actual Behavior

<!-- What actually happens -->

## Environment

- OS:
- Version:

## Additional Context

<!-- Screenshots, logs, or other relevant information -->

---
🤖 Generated with [rite workflow](https://github.com/B16B1RD/cc-rite-workflow)
```

### 3.2 Generate PR Template

Generate a PR template based on the project type.

| Project Type | Template Source |
|-----------------|-------------------|
| `generic` | `templates/pr/generic.md` |
| `webapp` | `templates/pr/webapp.md` |
| `library` | `templates/pr/library.md` |
| `cli` | `templates/pr/cli.md` |
| `documentation` | `templates/pr/documentation.md` |

**Steps:**

1. Read `project.type` from `rite-config.yml`
2. Load the corresponding template file:
   - `templates/pr/{project_type}.md`
3. Write as `.github/PULL_REQUEST_TEMPLATE.md`

```bash
# Read ツールでテンプレートを読み込み
# Write ツールで .github/PULL_REQUEST_TEMPLATE.md を生成
```

**If existing file exists:** Overwrite only if selected in Phase 2.

### 3.3 Regenerate Configuration File (optional)

Regenerate `rite-config.yml` only if the user selects to do so:

```
{i18n:template_reset_ask_config}？

{i18n:template_reset_config_warning}
{i18n:template_reset_backup_note}

オプション:
- {i18n:template_reset_option_regenerate}
- {i18n:template_reset_option_skip}（{i18n:sprint_plan_recommended}）
```

**Steps for regeneration:**

1. Back up the existing `rite-config.yml`:
   ```bash
   # バックアップファイル名: rite-config.yml.backup.{timestamp}
   # 例: rite-config.yml.backup.2026-01-04T12-00-00
   cp rite-config.yml "rite-config.yml.backup.$(date +%Y-%m-%dT%H-%M-%S)"
   ```

2. Reference `templates/config/rite-config.yml` to generate the default configuration

3. Include the backup file path in the completion report

---

## Phase 4: Completion Report

### 4.1 Display Generation Results

```
{i18n:template_reset_complete}

## {i18n:template_reset_generated_files}

| {i18n:template_reset_file} | {i18n:template_reset_status_label} |
|---------|------|
| .github/ISSUE_TEMPLATE/task.md | {i18n:template_reset_status_created} |
| .github/ISSUE_TEMPLATE/bug_report.md | {i18n:template_reset_status_created} |
| .github/PULL_REQUEST_TEMPLATE.md | {i18n:template_reset_status_updated} |

## {i18n:template_reset_backup_section}

| {i18n:template_reset_original_file} | {i18n:template_reset_backup_file} |
|-----------|-------------|
| rite-config.yml | rite-config.yml.backup.{timestamp} |

## {i18n:template_reset_project_type}

{project_type}

## {i18n:template_reset_next_steps}

1. {i18n:template_reset_next_step1}
2. {i18n:template_reset_next_step2}
3. {i18n:template_reset_next_step3}
```

**Note:** The backup section is only displayed when rite-config.yml was regenerated.

---

## Error Handling

See [Common Error Handling](../../references/common-error-handling.md) for shared patterns (Not Found, Permission, Network errors).

| Error | Recovery |
|-------|----------|
| When Write Permission Is Missing | See [common patterns](../../references/common-error-handling.md) |
| When Template Source Is Not Found | See [common patterns](../../references/common-error-handling.md) |
