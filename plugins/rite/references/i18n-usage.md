# i18n Usage Guide

This document explains how to use internationalization (i18n) in rite workflow command files.

## Overview

rite workflow supports multiple languages through an i18n key system. User-facing messages are stored in split YAML files to reduce token consumption:

### File Structure (Optimized)

```
{plugin_root}/i18n/
├── ja/
│   ├── common.yml  (~47 lines)  - Status, errors, branch, workflow
│   ├── issue.yml   (~186 lines) - Issue commands
│   ├── pr.yml      (~279 lines) - PR commands
│   └── other.yml   (~460 lines) - Sprint, init, lint, template, resume, skill
├── en/
│   ├── common.yml  (~47 lines)
│   ├── issue.yml   (~186 lines)
│   ├── pr.yml      (~279 lines)
│   └── other.yml   (~460 lines)
├── ja.yml (DEPRECATED - kept for backward compatibility)
└── en.yml (DEPRECATED - kept for backward compatibility)
```

> **Note**: Resolve `{plugin_root}` per [Plugin Path Resolution](./plugin-path-resolution.md#resolution-script-full-version).

Command files reference messages using the `{i18n:key_name}` pattern and load only the relevant i18n file(s) needed.

## How It Works

1. **Language Configuration**: The `language` field in `rite-config.yml` determines which language to use
   - `ja`: Use Japanese (ja/ directory)
   - `en`: Use English (en/ directory)
   - `auto`: Detect from user input (default: Japanese)

2. **Conditional Loading**: Command files specify which i18n file to read at the beginning:
   ```markdown
   Read {plugin_root}/i18n/{lang}/common.yml
   Read {plugin_root}/i18n/{lang}/issue.yml
   ```
   Where `{lang}` is replaced with the language code from rite-config.yml

3. **Key Resolution**: When the LLM encounters `{i18n:key_name}` in a command file, it:
   - Uses the previously loaded YAML file(s)
   - Looks up the message under `messages.key_name`
   - Replaces `{i18n:key_name}` with the localized message

3. **Variable Substitution**: Keys can contain variables using `{variable_name}` syntax
   ```
   {i18n:issue_created} (variables: number={issue_number})
   ```
   The LLM replaces `{number}` in the message with the actual value.

## Naming Convention

i18n keys follow a hierarchical naming pattern:

```
{command}_{subcommand}_{element}
```

### Examples

| Key | Pattern | Usage |
|-----|---------|-------|
| `issue_start_fetching` | `{command}_{subcommand}_{action}` | Status message during Issue start |
| `pr_review_quality_check_title` | `{command}_{subcommand}_{section}_{element}` | Section header in PR review |
| `lint_result_success` | `{command}_{type}_{state}` | Result message from lint |
| `error_no_issue` | `{category}_{context}` | Generic error message |

### Key Components

- **Command**: `issue`, `pr`, `sprint`, `lint`, `init`, etc.
- **Subcommand**: `start`, `create`, `review`, `fix`, `cleanup`, etc.
- **Element**: `fetching`, `complete`, `error`, `title`, `option`, etc.

## Usage in Command Files

### Basic Usage

```markdown
{i18n:issue_start_fetching}
```

This resolves to:
- Japanese: "Issue #{number} の情報を取得しています..."
- English: "Fetching Issue #{number} information..."

### With Variables

When the message contains variables (e.g., `{number}`, `{branch}`, `{count}`):

```markdown
{i18n:issue_start_fetching} (variables: number={issue_number})
```

The LLM will:
1. Look up the message: "Issue #{number} の情報を取得しています..."
2. Replace `{number}` with the actual issue number: "Issue #42 の情報を取得しています..."

### Multiple Variables

```markdown
{i18n:issue_start_iteration_assigned} (variables: sprint_name={sprint_name}, start_date={start_date}, end_date={end_date})
```

## What to Convert vs. What to Keep

### Convert to i18n Keys

✅ **User-facing output messages** - Text displayed to the user:
- Status messages: "作業を開始しました", "PR を作成しました"
- Error messages: "Issue が見つかりません", "権限がありません"
- Prompts: "どのアクションを実行しますか？"
- Table headers: "タイトル", "状態", "担当者"
- Section headers in user output: "次のステップ", "エラー内容"

### DO NOT Convert

❌ **Pattern-matched strings** - Used for parsing:
- `📜 rite 作業メモリ`
- `📜 rite レビュー結果`
- Field names: `セッション情報`, `フェーズ`, `コマンド`, `状態`, `備考`, `次のステップ`
- Phase values: `実装作業中`, `品質検証`, `PR作成中`, `レビュー中`
- Evaluation terms: `可`, `条件付き`, `要修正`, `マージ可`, `マージ不可（指摘あり）`, `修正必要`

❌ **LLM instruction text** - Commands to the LLM:
- Section headings: "## Phase 1: Fetch Issue Information"
- Step descriptions: "Execute the following phases in order"
- Conditional logic: "If the Issue is closed:"
- Tool usage instructions: "Use the Read tool to read rite-config.yml"

❌ **Code/data inside fenced blocks**:
- `gh` CLI commands
- Git commands
- YAML configuration examples
- JSON payloads
- Work memory templates

❌ **Frontmatter and metadata**:
- `description` field (remains in Japanese for local reference)

❌ **AskUserQuestion option labels**:
- The "オプション:" text itself and option descriptions

## Adding New Keys

When adding user-facing messages to command files:

1. **Check if a key already exists** in `ja.yml` and `en.yml`
   - Search for similar messages
   - Reuse existing keys when possible

2. **Create a new key if needed**:
   - Follow the naming convention
   - Add to **both** `ja.yml` and `en.yml`
   - Use descriptive names

3. **Key naming examples**:
   ```yaml
   # Good
   issue_start_branch_exists: "ブランチ {branch} は既に存在します"
   pr_review_asking_continue: "このままレビューを続行しますか？"

   # Avoid - too generic
   message1: "エラーが発生しました"
   error_text: "問題があります"
   ```

4. **Variable syntax**:
   - Use `{variable_name}` in the message
   - Document variables in the command file: `(variables: name=value, ...)`

## Example Conversion

### Before

```markdown
Issue #{issue_number} の情報を取得しています...
```

### After

```markdown
{i18n:issue_start_fetching} (variables: number={issue_number})
```

### YAML Entry

```yaml
# ja.yml
messages:
  issue_start_fetching: "Issue #{number} の情報を取得しています..."

# en.yml
messages:
  issue_start_fetching: "Fetching Issue #{number} information..."
```

## Common Patterns

### Status Messages

```markdown
{i18n:issue_started} (variables: number={issue_number})
{i18n:pr_created} (variables: number={pr_number})
{i18n:lint_complete}
```

### Error Messages

```markdown
{i18n:error_no_issue}
{i18n:issue_start_error_not_found} (variables: number={issue_number})
{i18n:pr_review_error_closed} (variables: number={pr_number}, state={state})
```

### User Prompts

```markdown
{i18n:issue_start_ask_proceed}

オプション:
- {i18n:issue_start_option_proceed}
- {i18n:issue_start_option_add_info}
- {i18n:issue_start_option_cancel}
```

### Tables

```markdown
| {i18n:issue_list_state} | {i18n:issue_list_labels} | {i18n:issue_list_assignees} |
|-------------------------|--------------------------|----------------------------|
| Open | bug, feature | @user1 |
```

## Verification

After converting messages to i18n keys:

1. **Check key existence**: Verify all referenced keys exist in both `ja.yml` and `en.yml`
2. **Verify variables**: Ensure variable names in YAML match those used in command files
3. **Test language switching**: Confirm messages appear correctly in both languages
4. **Pattern preservation**: Ensure pattern-matched strings remain unchanged

## Best Practices for Command Files

### Load Only What You Need

To minimize token consumption, load only the i18n files required for your command:

```markdown
<!-- For Issue commands -->
Read {plugin_root}/i18n/{lang}/common.yml
Read {plugin_root}/i18n/{lang}/issue.yml

<!-- For PR commands -->
Read {plugin_root}/i18n/{lang}/common.yml
Read {plugin_root}/i18n/{lang}/pr.yml

<!-- For Sprint/Init/Lint commands -->
Read {plugin_root}/i18n/{lang}/common.yml
Read {plugin_root}/i18n/{lang}/other.yml
```

### Determine Language

```markdown
Read rite-config.yml and extract the language setting (default: "auto" → Japanese).
Let {lang} = "ja" or "en" based on the configuration.
```

## Token Savings

The split structure reduces default session load:
- **Before**: ~945 lines per language file
- **After**: ~47 lines (common only) + on-demand loading

Commands load only what they need:
- Issue commands: common (47) + issue (186) = **233 lines** (vs 945)
- PR commands: common (47) + pr (279) = **326 lines** (vs 945)
- Sprint commands: common (47) + other (460) = **507 lines** (vs 945)

## References

- Current i18n files (under `{plugin_root}`):
  - `i18n/ja/` (split into 4 files: common, issue, pr, other)
  - `i18n/en/` (split into 4 files: common, issue, pr, other)
  - `i18n/ja.yml` (DEPRECATED - kept for backward compatibility)
  - `i18n/en.yml` (DEPRECATED - kept for backward compatibility)
- Configuration: `rite-config.yml` (`language` field)
- Command files: `{plugin_root}/commands/**/*.md`
- Plugin path resolution: [Plugin Path Resolution](./plugin-path-resolution.md)
