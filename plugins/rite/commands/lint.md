---
description: 品質チェックを実行
context: fork
---

# /rite:lint

## Contract
**Input**: rite-config.yml `commands` section (lint/test/typecheck commands), `.rite-flow-state` (optional, e2e flow)
**Output**: `[lint:success]` | `[lint:skipped]` | `[lint:error]` | `[lint:aborted]`

品質チェック（lint）を実行し、結果を報告する

---

Execute the following phases in order when this command is invoked.

## Caller Context and End-to-End Flow

> **Plugin Path**: Resolve `{plugin_root}` per [Plugin Path Resolution](../references/plugin-path-resolution.md#resolution-script) before executing bash hook commands in this file.

This command has two invocation cases: standalone execution and being called from the `/rite:issue:start` end-to-end flow.

| Caller | Output Pattern | Subsequent Action |
|-----------|-------------|---------------|
| `/rite:issue:start` (end-to-end flow) | Output (required) | `/rite:issue:start` calls `rite:pr:create` after executing Phase 5.2.1 |
| Standalone execution | Output (required) | Display "next steps" guidance |

**Determination method**: Claude determines the caller from conversation context:

| Condition | Result |
|------|---------|
| `rite:lint` was called via the `Skill` tool immediately prior within the same session | Within end-to-end flow |
| Otherwise (user directly typed `/rite:lint`) | Standalone execution |

**Note**: `commands/pr/fix.md` also uses conversation context for determination in the same manner.

**Output patterns (required regardless of caller):**
- `[lint:success]` - lint completed successfully
- `[lint:skipped]` - lint skipped
- `[lint:error]` - lint errors detected
- `[lint:aborted]` - user aborted

> **Important (flow continuation responsibility)**: When executed within the end-to-end flow, **this command does NOT directly call `rite:pr:create`; it returns control to the caller `/rite:issue:start`**. `/rite:issue:start` calls `rite:pr:create` after executing Phase 5.2.1 (checklist confirmation).

---

## Arguments

| Argument | Description |
|------|------|
| `[path]` | File or directory to check (defaults to changed files if omitted) |

---

## Phase 0: Load Work Memory (End-to-End Flow)

When executed within the end-to-end flow, load necessary information from work memory (shared memory).

### 0.1 End-to-End Flow Determination

Determine the caller from conversation context:

| Condition | Result | Action |
|------|---------|------|
| Conversation history contains rich context from `/rite:issue:start` | Within end-to-end flow | Work memory loading optional (information available in context) |
| `/rite:lint` was executed standalone | Standalone execution | Can identify Issue from branch name |

### 0.2 Load Work Memory

Extract the Issue number from the current branch and retrieve work memory:

```bash
# ブランチ名から Issue 番号を抽出
issue_number=$(git branch --show-current | grep -oE 'issue-[0-9]+' | grep -oE '[0-9]+')

# リポジトリ情報を取得
owner=$(gh repo view --json owner --jq '.owner.login')
repo=$(gh repo view --json name --jq '.name')

# 作業メモリを取得
gh api repos/{owner}/{repo}/issues/{issue_number}/comments \
  --jq '.[] | select(.body | contains("📜 rite 作業メモリ")) | .body'
```

### 0.3 Information to Retrieve

Extract the following information from work memory and retain in context:

| Field | Extraction Pattern | Purpose |
|-----------|-------------|------|
| Issue number | `issue-(\d+)` from branch name | Phase 4.4 work memory update |
| Branch name | `- **ブランチ**: (.+)` | Verification |
| Phase | `- **フェーズ**: (.+)` | Flow position confirmation |
| Next steps | `### 次のステップ` section | Expected operation confirmation |

**If work memory is not found:**

If the Issue number cannot be obtained or the work memory comment does not exist:
- Display a warning and skip
- Continue with normal lint execution (proceed to Phase 1)

---

## Phase 1: Lint Command Detection

### 1.1 Check Explicit Configuration

Retrieve the lint command from `rite-config.yml`:

```yaml
commands:
  lint: "npm run lint"  # 明示的に設定されている場合
```

Read the configuration file:

```bash
# rite-config.yml を読み取り
cat rite-config.yml
```

If `commands.lint` has a configured value, use it.

### 1.2 Auto-Detection (When No Configuration Exists)

Detect project files and determine the lint command:

| File | Detection Condition | Lint Command |
|----------|----------|---------------|
| `package.json` | `scripts.lint` exists | `npm run lint` |
| `pyproject.toml` | File exists | `ruff check .` |
| `Cargo.toml` | File exists | `cargo clippy -- -D warnings` |
| `go.mod` | File exists | `golangci-lint run` |
| `Makefile` | `lint` target exists | `make lint` |

**Detection priority:**
1. `commands.lint` in `rite-config.yml` (explicit configuration)
2. `scripts.lint` in `package.json`
3. `pyproject.toml` -> `ruff check .`
4. `Cargo.toml` -> `cargo clippy -- -D warnings`
5. `go.mod` -> `golangci-lint run`
6. `lint` target in `Makefile`

```bash
# package.json の scripts を確認
cat package.json | jq -r '.scripts.lint // empty'

# または各言語のファイル存在確認
ls package.json pyproject.toml Cargo.toml go.mod Makefile 2>/dev/null
```

### 1.3 When Command Cannot Be Detected

If the lint command cannot be detected, use the `AskUserQuestion` tool to interactively confirm.

**Note**: `AskUserQuestion` is a standard Claude Code tool that presents choices to the user and retrieves their response.

```
{i18n:lint_command_not_found}

{i18n:lint_supported_detection}:
- Node.js: package.json の scripts.lint
- Python: ruff check（pyproject.toml 検出時）
- Rust: cargo clippy（Cargo.toml 検出時）
- Go: golangci-lint run（go.mod 検出時）

オプション:
- {i18n:lint_option_skip}
- {i18n:lint_option_specify}
- {i18n:lint_option_abort}
```

**Subsequent processing for each choice:**

| Choice | Subsequent Processing |
|--------|----------|
| **Skip and continue** | Record "lint skipped" in conversation context, skip Phase 2 onward, and complete normally. If called from `/rite:issue:start`, proceed to the next step (PR creation) |
| **Specify command** | Follow up with `AskUserQuestion` to prompt for command input (see below), then execute Phase 2 onward with the entered command |
| **Abort** | Abort processing and display guidance to "configure lint and run again" |

**Output and recording when skipped:**

When lint is skipped, output the completion message in the following format:

**Standalone execution:**
```
[lint:skipped]
{i18n:lint_skipped}
{i18n:lint_skip_reason}

{i18n:lint_next_steps}:
1. {i18n:lint_skip_next_step}
```

**When called from `/rite:issue:start`:**
```
[lint:skipped]
{i18n:lint_skipped}
{i18n:lint_skip_reason}

---
{i18n:lint_flow_continue}
```

> If `/rite:lint` continues to PR creation directly, it bypasses the checklist confirmation (5.2.1) in the caller, potentially creating a PR with incomplete tasks.
> **CRITICAL**: When called from `/rite:issue:start`, `/rite:lint` outputs the above message and **terminates**. The call to `rite:pr:create` is made by `/rite:issue:start` after Phase 5.2.1 is complete.

**Meaning of output patterns:**
- `[lint:skipped]`: Used by `/rite:issue:start` Phase 5.2 to detect this pattern and decide to proceed to 5.3 (PR creation)
- `[lint:success]`: When lint completed successfully (output in Phase 4.1)
- `[lint:error]`: When lint detected errors (output in Phase 4.2)
- `[lint:aborted]`: When the user selected "Abort"

**Clarification of responsibilities:**

Reflecting the lint skip in the PR body is the responsibility of `/rite:issue:start` Phase 5.3:
1. `/rite:lint` only outputs the above output patterns
2. When `/rite:issue:start` detects `[lint:skipped]`, it prepares the PR body template before calling `/rite:pr:create`
3. The "Known Issues" section of the PR body includes the following:

```markdown
## Known Issues
- lint 未実行（lint コマンドが検出されませんでした）
```

**Processing when command is specified:**

When "Specify command" is selected, use `AskUserQuestion` to prompt for command input:

```
{i18n:lint_command_prompt}

オプション:
- npm run lint
- ruff check .
- {i18n:lint_command_other}
```

**Note**: Present representative commands as choices in `AskUserQuestion` `options`. The user can also select "Other" to enter a custom command.

When the user enters/selects a command:

1. Execute Phase 2 onward using the entered command
2. Do not save to `rite-config.yml` (temporary use only)
3. If saving to configuration is needed, guide the user to `/rite:init` or manual editing

---

## Phase 2: Determine Target Files

### 2.1 When Arguments Are Specified

Use the specified path as-is:

```
{i18n:lint_target_path}: {path}
```

If the path does not exist:

```
{i18n:lint_path_not_found} (variables: path={path})

{i18n:resume_actions}:
1. {i18n:lint_check_path_correct}
2. {i18n:lint_check_path_exists}
```

### 2.2 When Arguments Are Omitted

Detect changed files (in priority order):

#### 2.2.1 Get Base Branch

Read `rite-config.yml` from the project root using the Read tool, and retrieve the `branch.base` value:

```
Read: rite-config.yml
```

**Retrieval logic:**
1. If `rite-config.yml` exists and `branch.base` is set -> Use that value as `{base_branch}`
2. If `rite-config.yml` does not exist (Read tool returns an error), or `branch.base` is not set -> Use `main` as the default

**Definition of "not set":**
- `branch.base` key does not exist
- `branch.base` key value is `null` or empty string
- `branch` section itself does not exist

**Placeholder interpretation:**

`{base_branch}` in this document is replaced with the actual branch name obtained by the above logic. For example, if `branch.base: "develop"` is configured, the subsequent bash command `git diff --name-only origin/{base_branch}...HEAD` is executed as `git diff --name-only origin/develop...HEAD`.

#### 2.2.2 Detect Changed Files

Use the `{base_branch}` value obtained above to detect diffs. Follow the fallback logic below, trying each in sequence:

**Fallback logic (sequential attempts):**

| Priority | Condition | Command to Execute |
|--------|------|-------------|
| 1 | `origin/{base_branch}` exists | `git diff --name-only origin/{base_branch}...HEAD` |
| 2 | Above fails and `{base_branch}` exists | `git diff --name-only {base_branch}...HEAD` |
| 3 | Both fail | Error with guidance |

**Execution example:**

```bash
# 優先度 1: リモートベースブランチからの差分（推奨）
git diff --name-only origin/{base_branch}...HEAD

# 優先度 2: ローカルベースブランチからの差分（優先度 1 が失敗した場合）
git diff --name-only {base_branch}...HEAD
```

**When both fail:**

```
エラー: 変更ファイルを特定できません

ベースブランチ '{base_branch}' が見つかりません。

対処:
1. 明示的にパスを指定して再実行: /rite:lint <path>
2. rite-config.yml で branch.base を確認
3. git fetch origin でリモート情報を更新
```

Terminate processing. Do not silently fall back to `HEAD` diff or targeting the entire project — this would change the lint scope without the user's knowledge.

**When there are no changed files:**

```
{i18n:lint_no_changed_files}

ベースブランチとの差分がないため、プロジェクト全体をチェックします。
特定のパスに限定するには /rite:lint <path> を指定してください。
```

Target the entire project (current directory) with a visible warning that the scope has expanded.

---

## Phase 3: Lint Execution

### 3.1 Pre-Execution Notice

```
{i18n:lint_running}

{i18n:lint_command}: {lint_command}
{i18n:lint_target_path}: {target_path または "変更ファイル ({count} files)"}
```

### 3.2 Command Execution

```bash
# 検出されたコマンドを実行
{lint_command} {target_files}
```

**Notes:**
- The method for specifying target files varies by command
- `npm run lint` follows the project configuration
- `ruff check` accepts paths as arguments
- Display output even if there are errors (determine by exit code)

### 3.3 Capture Execution Results

Record the command's exit code and output:
- Exit code 0: No issues
- Exit code 1+: Errors or warnings present

### 3.4 Test Execution (Conditional)

Execute test commands as part of quality check when configured.

**Condition**: `commands.test` is set (non-null) in `rite-config.yml` AND `verification.run_tests_before_pr` is `true` (default: `true`).

**Skip conditions** (any match → skip to Phase 4):
- `commands.test` is `null` or not set
- `verification.run_tests_before_pr` is `false`

**Note**: When the `verification` section does not exist in `rite-config.yml`, treat defaults as enabled (`run_tests_before_pr: true`). The test execution condition still requires `commands.test` to be set.

**Duplicate execution avoidance**: When called from the `/rite:issue:start` end-to-end flow and tests were already run and passed in `implement.md` Phase 5.1.0.6 (test results available in conversation context), skip duplicate test execution and reuse previous results.

When skipped, no output needed (silent skip).

**Execution:**

```
{i18n:lint_running_tests}

{i18n:lint_command}: {test_command}
```

```bash
# commands.test を実行
{test_command}
```

**Result handling:**

| Exit Code | Action |
|-----------|--------|
| 0 | Tests passed — record success, continue to Phase 4 |
| Non-zero | Tests failed — record as error, include in Phase 4 report |

**Record test results** alongside lint results for Phase 4 reporting:
- `test_status`: `success` / `error` / `skipped`
- `test_error_count`: Number of failed tests (0 if success)
- `test_output`: Test command output (truncated if >500 lines)

---

## Phase 4: Report Results

### 4.0 Defense-in-Depth: State Update Before Output (End-to-End Flow)

Before outputting any result pattern (`[lint:success]`, `[lint:skipped]`, `[lint:error]`, `[lint:aborted]`), update `.rite-flow-state` to reflect the post-lint phase (defense-in-depth, fixes #716). This prevents intermittent flow interruptions when the fork context returns to the caller — even if the LLM churns after fork return and the system forcibly terminates the turn (bypassing the Stop hook), the state file will already contain the correct `next_action` for resumption.

**Condition**: Execute only when `.rite-flow-state` exists (indicating e2e flow). Skip if the file does not exist (standalone execution).

**State update by result**:

| Result | Phase | Phase Detail | Next Action |
|--------|-------|-------------|-------------|
| `[lint:success]` / `[lint:skipped]` | `phase5_post_lint` | `品質チェック完了` | `rite:lint completed successfully. Proceed to Phase 5.2.1 (checklist confirmation). All complete->Phase 5.3 PR creation. Incomplete->return to Phase 5.1 implementation. Do NOT stop.` |
| `[lint:error]` | `phase5_lint_error` | `lint エラー検出` | `rite:lint found errors. Fix the errors and re-invoke rite:lint. Do NOT stop.` |
| `[lint:aborted]` | `phase5_aborted` | `品質チェック中断` | `rite:lint was aborted by user. Proceed to Phase 5.6 (completion report). Do NOT stop.` |

```bash
bash {plugin_root}/hooks/flow-state-update.sh patch \
  --phase "{phase_value}" \
  --next "{next_action_value}" \
  --if-exists
```

Replace `{phase_value}` and `{next_action_value}` with the values from the table above based on the lint result.

**Note on `error_count`**: `flow-state-update.sh` patch mode preserves all existing fields not explicitly set (only `phase`, `updated_at`, `next_action` are changed), so `error_count` is retained (consistent with `fix.md` Phase 8.1). The count is effectively reset when `/rite:issue:start` writes a new complete object via `jq -n` at the next phase transition.

**Also sync to local work memory** (`.rite-work-memory/issue-{n}.md`) when `.rite-flow-state` exists:

Use the self-resolving wrapper. See [Work Memory Format - Usage in Commands](../skills/rite-workflow/references/work-memory-format.md#usage-in-commands) for details and marketplace install notes.

```bash
WM_SOURCE="lint" \
  WM_PHASE="{phase_value}" \
  WM_PHASE_DETAIL="{phase_detail}" \
  WM_NEXT_ACTION="{next_action_value}" \
  WM_BODY_TEXT="Post-lint phase sync." \
  WM_REQUIRE_FLOW_STATE="true" \
  WM_READ_FROM_FLOW_STATE="true" \
  WM_ISSUE_NUMBER="{issue_number}" \
  bash {plugin_root}/hooks/local-wm-update.sh 2>/dev/null || true
```

Where `{phase_value}`, `{phase_detail}`, and `{next_action_value}` match the `.rite-flow-state` update above. Claude substitutes these with the actual values based on the lint result before executing.

**On lock failure**: Log a warning and continue — local work memory update is best-effort.

### 4.1 When No Issues Found

**Standalone execution:**
```
[lint:success]
{i18n:lint_complete}

{i18n:lint_result_success}

{i18n:lint_target_path}: {target_description}
{i18n:lint_command}: {lint_command}
```

**When called from `/rite:issue:start`:**
```
[lint:success]
{i18n:lint_complete}

{i18n:lint_result_success}

{i18n:lint_target_path}: {target_description}
{i18n:lint_command}: {lint_command}

---
{i18n:lint_flow_continue}
```

> **CRITICAL**: When called from `/rite:issue:start`, `/rite:lint` outputs the above message and **terminates**. The call to `rite:pr:create` is made by `/rite:issue:start` after Phase 5.2.1 is complete.

**Note**: `[lint:success]` is an output pattern used by `/rite:issue:start` Phase 5.2 to determine the lint result.

### 4.2 When Issues Found

```
[lint:error]
{i18n:lint_complete}

{i18n:lint_result_errors} (variables: error_count={error_count}, warning_count={warning_count})

{lint_output}

---

{i18n:lint_fix_suggestions}:
```

**Note**: `[lint:error]` is an output pattern used by `/rite:issue:start` Phase 5.2 to determine the lint result.

**Presenting fix suggestions:**

Analyze the error content and present fix suggestions when possible:

1. **When auto-fix is available:**
   ```
   {i18n:lint_ask_autofix}

   {i18n:lint_command}: {fix_command}
   {i18n:lint_autofix_examples}:
       npm run lint -- --fix
       ruff check --fix
       cargo clippy --fix

   オプション:
   - {i18n:lint_option_autofix}
   - {i18n:lint_option_manual}
   ```

2. **When manual fix is required:**
   Present specific fix suggestions for each error.

### 4.3 Summary Display

```
{i18n:lint_summary_title}

| {i18n:lint_summary_item} | {i18n:lint_summary_result} |
|------|------|
| {i18n:lint_target_path} | {target} |
| {i18n:lint_errors} | {error_count} |
| {i18n:lint_warnings} | {warning_count} |
| {i18n:lint_test} | {test_status} ({test_error_count} failures) |
| {i18n:lint_duration} | {duration} |

{i18n:lint_next_steps}:
1. {i18n:lint_next_fix_errors}
2. {i18n:lint_next_rerun}
3. {i18n:lint_next_create_pr}

> **{i18n:lint_standalone_note}**: {i18n:lint_standalone_note_detail}
```

**Note**: The `{i18n:lint_test}` row is only shown when `commands.test` is configured. When tests were skipped, omit the row entirely.

### 4.4 Automatic Work Memory Update (Conditional)

> **WARNING**: Work memory is published as Issue comments. In public repositories, it is visible to third parties. Do not record confidential information (credentials, personal information, internal URLs, etc.) in work memory.

Record the quality check results in work memory.

**Execution condition**: Automatically executed only when on a work branch linked to an Issue (branch containing the `issue-{number}` pattern). Not executed on main/master branches or branches that do not contain an Issue number.

#### 4.4.1 Identify Related Issue

Extract the Issue number from the branch name:

```bash
issue_number=$(git branch --show-current | grep -oE 'issue-[0-9]+' | grep -oE '[0-9]+')
```

If no Issue number is found, skip the work memory update.

#### 4.4.2 Retrieve and Update Work Memory Comment

```bash
# ⚠️ このブロック全体を単一の Bash ツール呼び出しで実行すること（クロスプロセス変数参照を防止）
# comment_data の取得・追記内容の heredoc 定義・PATCH を分割すると変数が失われる（Issue #693）
comment_data=$(gh api repos/{owner}/{repo}/issues/{issue_number}/comments \
  --jq '[.[] | select(.body | contains("📜 rite 作業メモリ"))] | last | {id: .id, body: .body}')
comment_id=$(echo "$comment_data" | jq -r '.id // empty')
current_body=$(echo "$comment_data" | jq -r '.body // empty')

if [ -n "$comment_id" ]; then
  if [ -z "$current_body" ]; then
    echo "ERROR: 作業メモリの本文取得に失敗。更新をスキップします。" >&2
  else
    tmpfile=$(mktemp)
    trap 'rm -f "$tmpfile"' EXIT
    printf '%s\n\n' "$current_body" > "$tmpfile"
    cat >> "$tmpfile" << 'NEW_SECTION_EOF'
{4.4.3 の内容を実際の値で置換して記述}
NEW_SECTION_EOF
    jq -n --rawfile body "$tmpfile" '{"body": $body}' \
      | gh api repos/{owner}/{repo}/issues/comments/"$comment_id" \
        -X PATCH --input -
  fi
fi
```

**Note for Claude**: ⚠️ このブロック全体を**1つの Bash ツール呼び出し**で実行すること。`current_body` 取得・追記内容の heredoc 定義・PATCH を別の Bash ツール呼び出しに分割すると、前の呼び出しのシェル変数（`current_body` 等）が失われてヘッダーが消失する（Issue #693）。`{4.4.3 の内容を実際の値で置換して記述}` を 4.4.3 のテンプレートから生成した実際の追記内容で置換し、**すべてを1ブロックで**実行する。

#### 4.4.3 Update Content

Automatically append the following to work memory:

```markdown
### 品質チェック履歴

#### {timestamp}: /rite:lint 実行
- **結果**: {status}（問題なし / エラーあり）
- **エラー**: {error_count}件
- **警告**: {warning_count}件
- **対象**: {target}
```

**Notes**:
- If the work memory comment is not found, skip the update
- If on the main/master branch, skip the update
- This update is performed automatically and does not require user confirmation

#### 4.4.4 Record "Next Steps"

After the quality check is complete, record "next steps" in work memory.

**Content to append (on lint success):**

```markdown
### 次のステップ
- **コマンド**: /rite:pr:create
- **状態**: 待機中
- **備考**: lint 完了、PR 作成準備完了
```

**Content to append (on lint skip):**

```markdown
### 次のステップ
- **コマンド**: /rite:pr:create
- **状態**: 待機中
- **備考**: lint スキップ（コマンド未検出）、PR 作成準備完了
```

**Content to append (on lint error):**

```markdown
### 次のステップ
- **コマンド**: /rite:lint
- **状態**: 待機中
- **備考**: lint エラー修正後、再度 lint を実行
```

**Notes**:
- If an existing `### 次のステップ` section exists, replace its content
- If the section does not exist, append to the end of work memory

**Specific replacement procedure:**

1. Retrieve the existing work memory body
2. Detect from `### 次のステップ` to the next `###` or EOF
3. Replace that section with the new "next steps" section
4. If the section is not found, append to the end of the body

```bash
# ⚠️ このブロック全体を単一の Bash ツール呼び出しで実行すること（クロスプロセス変数参照を防止）
# ⚠️ TOCTOU 防止: 必ず Phase 4.4.2 の PATCH 完了後に実行すること。
#    4.4.2 と 4.4.4 を別の Bash ツール呼び出しで実行する場合、4.4.2 の PATCH が GitHub API に
#    反映される前に 4.4.4 が旧バージョンの body を取得し、4.4.2 の追記を上書きする可能性がある。
#    最も安全な実装は 4.4.2 と 4.4.4 を一つの Bash ツール呼び出しに結合し、
#    一度のフェッチ → Python セクション置換 → 1回の PATCH にすること。
# lint 結果に応じて replacement の内容を上記 3 ケース（success/skip/error）から選択すること
comment_data=$(gh api repos/{owner}/{repo}/issues/{issue_number}/comments \
  --jq '[.[] | select(.body | contains("📜 rite 作業メモリ"))] | last | {id: .id, body: .body}')
comment_id=$(echo "$comment_data" | jq -r '.id // empty')
current_body=$(echo "$comment_data" | jq -r '.body // empty')

if [[ -n "$comment_id" ]] && [[ -n "$current_body" ]]; then
  repl_file=$(mktemp)
  body_tmp=$(mktemp)
  updated_tmp=$(mktemp)
  # backup_file is intentionally excluded from trap — preserved for post-mortem investigation
  backup_file="/tmp/rite-wm-backup-${issue_number}-$(date +%s).md"
  trap 'rm -f "$repl_file" "$body_tmp" "$updated_tmp"' EXIT

  # Step 1: Backup current body
  printf '%s' "$current_body" > "$backup_file"

  # lint 結果（success/skip/error）に応じて上記テンプレートの内容を repl_file に書き込む
  # 例（lint success の場合）:
  cat > "$repl_file" << 'REPL_EOF'
### 次のステップ
- **コマンド**: /rite:pr:create
- **状態**: 待機中
- **備考**: lint 完了、PR 作成準備完了
REPL_EOF

  printf '%s' "$current_body" > "$body_tmp"

  # Step 2: Python-based section replacement (awk-free)
  python3 -c '
import sys

body_path = sys.argv[1]
repl_path = sys.argv[2]
out_path = sys.argv[3]

with open(body_path, "r") as f:
    body = f.read()
with open(repl_path, "r") as f:
    replacement = f.read().rstrip("\n")

lines = body.split("\n")
result = []
in_section = False
found = False

for line in lines:
    if line.rstrip() == "### 次のステップ" and not found:
        result.append(replacement)
        in_section = True
        found = True
        continue
    if in_section:
        if line.startswith("### "):
            in_section = False
            result.append(line)
        continue
    result.append(line)

if not found:
    result.append("")
    result.append(replacement)

output = "\n".join(result)
if body.endswith("\n") and not output.endswith("\n"):
    output += "\n"
with open(out_path, "w") as f:
    f.write(output)
' "$body_tmp" "$repl_file" "$updated_tmp"

  # Step 3: Validate updated content (10 bytes = minimum plausible work memory content)
  if [ ! -s "$updated_tmp" ] || [[ "$(wc -c < "$updated_tmp")" -lt 10 ]]; then
    echo "ERROR: Updated body is empty or too short. Aborting PATCH. Backup: $backup_file" >&2
    exit 1
  fi
  if grep -q -- '📜 rite 作業メモリ' "$updated_tmp"; then
    : # Header present, proceed
  else
    echo "ERROR: Updated body missing work memory header. Aborting PATCH. Backup: $backup_file" >&2
    exit 1
  fi

  # Step 4: Apply update
  if ! jq -n --rawfile body "$updated_tmp" '{"body": $body}' \
      | gh api repos/{owner}/{repo}/issues/comments/"$comment_id" \
        -X PATCH --input -; then
    echo "ERROR: PATCH failed. Backup: $backup_file" >&2
    exit 1
  fi
fi
```

**Note for Claude**: ⚠️ このブロック全体を**1つの Bash ツール呼び出し**で実行すること。`REPL_EOF` ヒアドキュメントには lint 結果（success/skip/error）に応じて上記 3 ケースのいずれかを記述すること。awk は使用禁止 — Python インラインスクリプトでセクション置換を行うこと。更新前バックアップ、空body検証、ヘッダー検証を必ず実行すること。

---

## Error Handling

See [Common Error Handling](../references/common-error-handling.md) for shared patterns (Not Found, Permission, Network errors).

| Error | Recovery |
|-------|----------|
| When the lint command fails | See error output for details |
| When the tool is not found | See [common patterns](../references/common-error-handling.md) |

## Language-Specific Details

### Node.js (package.json)

```bash
# scripts.lint を確認
npm run lint

# 自動修正（対応している場合）
npm run lint -- --fix
```

**Common lint tools:**
- ESLint: `eslint {files}`
- Prettier: `prettier --check {files}`
- Biome: `biome check {files}`

### Python (pyproject.toml)

```bash
# ruff を使用
ruff check {files}

# 自動修正
ruff check --fix {files}
```

**Other tools:**
- flake8: `flake8 {files}`
- mypy: `mypy {files}`
- black: `black --check {files}`

### Rust (Cargo.toml)

```bash
# clippy を使用
cargo clippy -- -D warnings

# フォーマットチェック
cargo fmt --check
```

### Go (go.mod)

```bash
# golangci-lint を使用
golangci-lint run {files}

# または go vet
go vet {files}
```
## Phase 5: End-to-End Flow Continuation (Automatic)

> **This phase is only executed within the end-to-end flow. Skipped during standalone execution.**

### 5.1 Flow Continuation Decision

Continue the end-to-end flow based on the output pattern from Phase 4.

| Output Pattern | Action in End-to-End Flow |
|-------------|---------------------------|
| `[lint:success]` | `/rite:lint` execution completes, and the caller `/rite:issue:start` executes Phase 5.2.1 (checklist completion confirmation) |
| `[lint:skipped]` | `/rite:lint` execution completes, and the caller `/rite:issue:start` executes Phase 5.2.1 (checklist completion confirmation) |
| `[lint:error]` | After fixing errors, run lint again (return to Phase 3) |
| `[lint:aborted]` | Flow ends (execution of `/rite:issue:start` also ends) |

**Note**: During standalone execution (when the user directly executes `/rite:lint`), the Phase 5.2.1 checklist confirmation is **not executed**. Checklist confirmation is a feature only executed within the `/rite:issue:start` end-to-end flow; standalone lint execution ends without flow continuation.

### 5.2 Processing After `/rite:lint` Completion

When `[lint:success]` or `[lint:skipped]` is output:

**`/rite:lint` execution completes**, and Claude executes `/rite:issue:start` Phase 5.2.1 (checklist completion confirmation). After that, it calls `rite:pr:create`.

**Important**:
- `/rite:lint` does **NOT directly call** `rite:pr:create`
- The caller `/rite:issue:start` performs checklist completion confirmation in Phase 5.2.1
- After all checklist items are complete, `/rite:issue:start` calls `rite:pr:create`

**Design intent**:
- Guard function to prevent proceeding to PR creation until all Issue checklist items are complete (Issue #398)
- If there are incomplete items, return to Phase 5.1 to continue implementation

### 5.3 Standalone Execution Behavior

During standalone execution, Phase 5 is not executed; display the "next steps" guidance from Phase 4 and terminate.
