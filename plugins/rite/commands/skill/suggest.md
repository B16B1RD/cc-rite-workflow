---
description: 現在のコンテキストを分析し、適用可能なスキルを提案
context: fork
---

# /rite:skill:suggest

Analyze the current context (Issue, changed files, work state) and suggest applicable skills.

---

When this command is executed, run the following phases in order.

## Phase 1: Context Collection

### 1.1 Identify Current Branch and Issue

```bash
# 現在のブランチ名を取得
git branch --show-current

# ブランチ名から Issue 番号を抽出（パターン: **/issue-{number}-*）
# 例: feat/issue-278-skill-suggest → 278
```

If an Issue number can be extracted from the branch name, retrieve Issue information:

```bash
gh issue view {issue_number} --json number,title,body,labels
```

### 1.2 Collect Changed Files

```bash
# ステージ済み・未ステージの変更ファイル
git status --porcelain

# 最近のコミット（直近 5 件）の変更ファイル
git log --oneline -5 --name-only
```

### 1.3 Working Directory Structure

Collect information to determine the project type:

```bash
# プロジェクト設定ファイルの存在確認
ls -la package.json pyproject.toml Cargo.toml go.mod pom.xml build.gradle 2>/dev/null
```

### 1.4 Read rite-config.yml

Use the Read tool to read `rite-config.yml` and check the following:

- `project.type`: Project type (generic, webapp, library, cli, documentation)
- `language`: Language setting (used to determine output language)

---

## Phase 2: Retrieve Available Skills List

### 2.1 Search for Skill Files

Use the Glob tool to search for skill files:

```
Glob: plugins/**/SKILL.md
Glob: plugins/**/*.skill.md
```

**Note**: The reason for using the Glob tool instead of the Bash `find` command:
- The Glob tool is optimized for file searches
- Pattern matching is simple and fast
- It is the standard file exploration method in Claude Code

### 2.2 Collect Information for Each Skill

Extract the following from each discovered skill file:

| Field | Source | Extraction Method |
|-------|--------|-------------------|
| Skill name | Directory or file name | Extract the `{name}` part from path `skills/{name}/SKILL.md` |
| Description | Beginning of file | The paragraph text immediately after the first `#` heading |
| Keywords | `## Auto-Activation Keywords` section | Collect list items (lines starting with `-`) as an array |
| Applicability conditions | `## Context` section | Get the description text within the section (including condition statements like "When activated") |

**Extraction example (for rite-workflow/SKILL.md):**

```
スキル名: rite-workflow
説明: "This skill provides context for rite workflow operations."
キーワード: ["Issue", "PR", "Pull Request", "workflow", "rite", "branch", "commit", ...]
適用条件: "When activated, this skill provides: Workflow Awareness, Command Guidance, ..."
```

---

## Phase 3: Skill Matching

### 3.1 Calculate Matching Score

For each skill, calculate a score based on the following factors:

| Factor | Weight | Description | Source |
|--------|--------|-------------|--------|
| Issue title/body keyword match | 3 | Match between Issue content and skill keywords | `## Auto-Activation Keywords` |
| Changed file types | 2 | File extensions and directory placement | `## File Patterns` or inference (see below) |
| Label match | 2 | Relevance between Issue labels and skill | Inferred from keywords (see below) |
| Project type | 1 | project.type from rite-config.yml | Inferred from skill directory structure |

**Retrieving file patterns:**

1. If the skill file has a `## File Patterns` section -> use that list
2. If the section does not exist -> infer from keywords:
   - `workflow`, `Issue`, `PR` -> `commands/**/*.md`, `*.yml`
   - `review`, `lint` -> all files
   - Reviewer skills (`skills/reviewers/`) -> refer to each skill file's `Activation` section

**Inferring related labels:**

Infer from skill keywords using the following mapping:
| Keywords | Related Labels |
|----------|---------------|
| `workflow`, `Issue`, `PR` | `enhancement`, `feature` |
| `review`, `lint` | `review`, `quality` |
| `documentation` | `documentation`, `docs` |

### 3.2 Matching Decision Logic

```
各スキルについて:
  score = 0

  # Issue キーワードマッチ（Auto-Activation Keywords から取得）
  for keyword in skill.keywords:
    if keyword in issue.title or keyword in issue.body:
      score += 3

  # 変更ファイルマッチ（File Patterns セクションまたは推論）
  for pattern in skill.file_patterns:
    if any(file matches pattern for file in changed_files):
      score += 2

  # ラベルマッチ（キーワードから推論した関連ラベル）
  for label in issue.labels:
    if label in skill.related_labels:
      score += 2

  # プロジェクト種別マッチ
  if project.type in skill.applicable_types:
    score += 1

  if score >= threshold:
    suggested_skills.append(skill)
```

### 3.3 Threshold Settings

| Threshold | Decision |
|-----------|----------|
| 5 or above | Strongly recommended (high relevance) |
| 3-4 | Recommended (possibly relevant) |
| 1-2 | Reference (weak relevance) |
| 0 | Hidden |

---

## Phase 4: Display Suggestions

### 4.1 Check Language Setting

Determine the output language according to the `language` setting read in Phase 1.4:

| Setting | Behavior |
|---------|----------|
| `auto` | Detect the user's input language and display in the same language |
| `ja` | Display messages in Japanese |
| `en` | Display messages in English |

### 4.2 When Recommended Skills Exist

```
┌─────────────────────────────────────────────────────────────┐
│  {i18n:skill_suggest_title}                                  │
└─────────────────────────────────────────────────────────────┘

{i18n:skill_suggest_current_context}:
  Issue: #{number} {title}
  {i18n:skill_suggest_branch}: {branch_name}
  {i18n:skill_suggest_changed_files}: {changed_files_count} {i18n:sprint_plan_count_unit}

───────────────────────────────────────────────────────────────

【{i18n:skill_suggest_strongly_recommended}】

  📌 {skill_name}
     {skill_description}

     {i18n:skill_suggest_reason}:
     - {reason_1}
     - {reason_2}

     {i18n:skill_suggest_how_to_apply}: {i18n:skill_suggest_auto_apply}

【{i18n:skill_suggest_recommended}】

  📎 {skill_name}
     {skill_description}

     {i18n:skill_suggest_reason}:
     - {reason_1}

───────────────────────────────────────────────────────────────

【{i18n:skill_suggest_reference_info}】
- {i18n:skill_suggest_info_based_on_context}
- {i18n:skill_suggest_info_defined_in}
```

### 4.3 When No Recommended Skills Exist

```
┌─────────────────────────────────────────────────────────────┐
│  {i18n:skill_suggest_title}                                  │
└─────────────────────────────────────────────────────────────┘

{i18n:skill_suggest_current_context}:
  Issue: #{number} {title}
  {i18n:skill_suggest_branch}: {branch_name}
  {i18n:skill_suggest_changed_files}: {changed_files_count} {i18n:sprint_plan_count_unit}

───────────────────────────────────────────────────────────────

{i18n:skill_suggest_no_recommended}

{i18n:skill_suggest_available_skills}:
- {skill_name}: {skill_description}
- {skill_name}: {skill_description}

{i18n:skill_suggest_auto_apply_note}
```

### 4.4 When Context Information Is Missing or Incomplete

When the Issue number cannot be determined (no `issue-{number}` pattern in branch name) or there are no changed files (empty git diff):

```
┌─────────────────────────────────────────────────────────────┐
│  {i18n:skill_suggest_title}                                  │
└─────────────────────────────────────────────────────────────┘

{i18n:skill_suggest_insufficient_context}:

{missing_info_list}

【{i18n:skill_suggest_resolution}】
- {i18n:skill_suggest_resolution_work_on_branch}
- {i18n:skill_suggest_resolution_use_start}

{i18n:skill_suggest_available_skills}:
- {skill_name}: {skill_description}
```

---

## Phase 5: Optional Features

### 5.1 Verbose Mode (`--verbose`)

When `--verbose` or `-v` is specified as an argument, display matching score details:

```
【{i18n:skill_suggest_matching_details}】

{skill_name}:
  {i18n:skill_suggest_total_score}: 7
  - {i18n:skill_suggest_keyword_match}: +3 (workflow, Issue)
  - {i18n:skill_suggest_file_match}: +2 (*.md)
  - {i18n:skill_suggest_label_match}: +2 (enhancement)
  - {i18n:skill_suggest_project_type}: +0
```

### 5.2 Filter Mode (`--filter {category}`)

Display only skills in a specific category:

```bash
/rite:skill:suggest --filter review    # レビュー関連のスキルのみ
/rite:skill:suggest --filter workflow  # ワークフロー関連のスキルのみ
```

**Available categories:**

| Category | Description | Target Skills |
|----------|-------------|---------------|
| `workflow` | Workflow-related | rite-workflow |
| `review` | Review-related | reviewers/* |

**Dynamic category retrieval:**

Categories are dynamically retrieved from the directory structure of `{plugin_root}/skills/` (resolve `{plugin_root}` per [Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script)):
- `skills/{category}/SKILL.md` -> category name is `{category}`
- `skills/reviewers/*.md` -> included in category `review`

**Note**: When a skill is not assigned to a category or a non-existent category is specified:

```
{i18n:skill_suggest_warning_category} (variables: category={category})

{i18n:skill_suggest_available_categories}:
- workflow
- review

{i18n:skill_suggest_show_all_hint}
```

---

## Error Handling

See [Common Error Handling](../../references/common-error-handling.md) for shared patterns (Not Found, Permission, Network errors).

| Error | Recovery |
|-------|----------|
| When Outside a Git Repository | See error output for details |
| When No Skill Files Are Found | See error output for details |

## Usage Examples

```
/rite:skill:suggest                    # 現在のコンテキストに基づいてスキルを提案
/rite:skill:suggest --verbose          # 詳細なマッチング情報を表示
/rite:skill:suggest -v                 # --verbose の短縮形
/rite:skill:suggest --filter review    # レビュー関連スキルのみ表示
```
