---
description: 品質チェックを実行
---

# /rite:lint

## Contract
**Input**: rite-config.yml `commands` section (lint/test/typecheck commands), `.rite-flow-state` (optional, e2e flow)
**Output**: `[lint:success]` | `[lint:skipped]` | `[lint:error]` | `[lint:aborted]`

品質チェック（lint）を実行し、結果を報告する

## E2E Output Minimization

When called from the `/rite:issue:start` end-to-end flow, minimize output to reduce context window consumption:

| Phase | Standalone | E2E Flow |
|-------|-----------|----------|
| Phase 3 (Execution) | Full output | Full output (needed for error diagnosis) |
| Phase 4.1 (Success) | Full report | `[lint:success]` + 1-line summary only |
| Phase 4.2 (Error) | Full output + suggestions | `[lint:error]` + error count + first 10 lines only |
| Phase 4.3 (Summary) | Full table | **Skip entirely** |
| Phase 4.4 (Work Memory) | Full update | Full update (no change) |

**Detection**: See [Caller Context and End-to-End Flow](#caller-context-and-end-to-end-flow) determination method below.

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

## Phase 0.5: Config Deprecation Scan (v1.0.0 #557)

Before running lint, scan `rite-config.yml` for deprecated review-fix loop configuration keys and emit warnings. Legacy keys are **silently ignored** at runtime (they have no effect), but leaving them in the config file creates confusion, so warn the user to remove them.

**Deprecated keys** (removed in v1.0.0 by #557):

| Key | Path | Replaced by |
|-----|------|-------------|
| `severity_gating_cycle_threshold` | `review.loop.*` | Quality Signal 1 (fingerprint cycling) — no configuration needed |
| `scope_lock_cycle_threshold` | `review.loop.*` | Quality Signal 1 (fingerprint cycling) — no configuration needed |
| `max_review_fix_loops` | `safety.*` | Fully removed — loop now exits on 0 findings or on any of the 4 quality signals |

**Step 1**: Scan `rite-config.yml` for each deprecated key name and record which are present:

```bash
deprecated_found=""
for key in severity_gating_cycle_threshold scope_lock_cycle_threshold max_review_fix_loops; do
  # 先頭 `#` で始まるコメント行は誤検出しないが、top-level (インデント 0) の key も検出対象に含める
  if grep -qE "^[[:space:]]*${key}[[:space:]]*:" rite-config.yml 2>/dev/null; then
    deprecated_found="${deprecated_found}${key} "
  fi
done
if [ -n "$deprecated_found" ]; then
  echo "⚠️ rite-config.yml に廃止済みキーが残存しています: ${deprecated_found}" >&2
  echo "⚠️ これらのキーは v1.0.0 (#557) で廃止され、値は無視されます。rite-config.yml から削除してください。" >&2
  echo "[CONTEXT] DEPRECATED_KEYS=${deprecated_found}"
else
  echo "[CONTEXT] DEPRECATED_KEYS=none"
fi
```

**Step 2**: Continue to Phase 1 regardless of whether deprecated keys were found. The warning is informational and does not change the lint exit code.

**Step 3**: When deprecated keys are detected, include a short line in the final lint report so it is visible alongside normal lint output:

```
⚠️ Deprecated config keys detected: {keys}. See CHANGELOG v1.0.0 migration guide.
```

This is appended to the report produced by Phase 4 irrespective of lint success/error.

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

### 3.5 Plugin-specific Checks (Distributed Fix Drift Detection)

Execute the distributed fix drift check script to detect documentation drift patterns in rite-workflow procedural markdown files.

**Condition**: Always execute when `{plugin_root}/hooks/scripts/distributed-fix-drift-check.sh` exists. This check is independent of `commands.lint` configuration — it is a rite-workflow internal quality check.

**Skip condition**: Script file does not exist (e.g., marketplace install without hooks/scripts directory).

**Execution:**

```bash
if [ -f {plugin_root}/hooks/scripts/distributed-fix-drift-check.sh ]; then
  drift_output=$(bash {plugin_root}/hooks/scripts/distributed-fix-drift-check.sh --all 2>&1)
  drift_exit_code=$?
else
  drift_exit_code=-1  # script not found
fi
```

**Result handling:**

| Exit Code | `drift_status` | Action |
|-----------|----------------|--------|
| 0 | `success` | No drift detected — continue to Phase 4 |
| 1 | `warning` | Drift detected — record as **warning** (does NOT cause `[lint:error]`). Display drift findings but allow flow to continue |
| 2 | `error` | Invocation error — record as warning, display error message |
| -1 | `skipped` | Script not found — skip silently |

**Important**: Drift detection results are treated as **warnings**, not errors. A drift finding does NOT change the overall lint result pattern (`[lint:success]` remains `[lint:success]`). This design choice reflects that drift findings are documentation consistency issues, not code quality blockers.

**Record drift results** for Phase 4 reporting:
- `drift_status`: `success` / `warning` / `error` / `skipped`
- `drift_finding_count`: Extract from `drift_output` by matching the line `==> Total drift findings: N` (regex: `/Total drift findings: (\d+)/`). If no match found, default to 0
- `drift_output`: Script output (truncated if >50 lines)

### 3.6 Plugin-specific Checks (Bang-Backtick Adjacency Detection)

Execute the bang-backtick check script to detect Skill loader triggering patterns (backtick + bang adjacency) in **`plugins/rite/commands/**/*.md`** and **`plugins/rite/skills/**/*.md`** (plugin-scoped; the script walks the rite plugin tree specifically and does not scan repository-root `commands/` or `skills/` directories that may belong to other plugins). This is the static lint counterpart to Issue #365 / PR #367 where inline-code bang adjacency broke Skill loading via bash history expansion. See the script header comment at `plugins/rite/hooks/scripts/bang-backtick-check.sh` for concrete detection patterns.

**Condition**: Always execute when the script exists. This check is independent of `commands.lint` configuration — it is a rite-workflow internal quality check.

**Skip condition**: Script file does not exist (e.g., marketplace install without hooks/scripts directory).

**Execution:**

```bash
if [ -f {plugin_root}/hooks/scripts/bang-backtick-check.sh ]; then
  bang_backtick_output=$(bash {plugin_root}/hooks/scripts/bang-backtick-check.sh --all 2>&1)
  bang_backtick_exit_code=$?
else
  bang_backtick_exit_code=-1  # script not found
fi
```

**Result handling:**

| Exit Code | `bang_backtick_status` | Action |
|-----------|------------------------|--------|
| 0 | `success` | No bang-backtick adjacency — continue to Phase 4 |
| 1 | `warning` | Pattern detected — record as **warning** (does NOT cause `[lint:error]`). Display findings but allow flow to continue |
| 2 | `error` | Invocation error — record as warning, display error message |
| -1 | `skipped` | Script not found — skip silently |

**Important**: Bang-backtick detection results are treated as **warnings**, not errors — same policy as Phase 3.5 drift check. A finding does NOT change the overall lint result pattern (`[lint:success]` remains `[lint:success]`). Reason: existing checks stay non-blocking during staged rollout, and Skill loader triggering is a correctness issue that should be fixed promptly but not gate CI until coverage is validated.

**Record bang-backtick results** for Phase 4 reporting:
- `bang_backtick_status`: `success` / `warning` / `error` / `skipped`
- `bang_backtick_finding_count`: Extract from `bang_backtick_output` by matching the line `==> Total bang-backtick findings: N` (regex: `/Total bang-backtick findings: (\d+)/`). If no match found, default to 0
- `bang_backtick_output`: Script output (truncated if >50 lines)

### 3.7 Plugin-specific Checks (Doc-Heavy Patterns Drift Detection)

Execute the doc-heavy patterns drift check script to detect divergence between the `doc_file_patterns` declared in 3 files that MUST stay in sync: `plugins/rite/skills/reviewers/tech-writer.md` (Activation section), `plugins/rite/commands/pr/review.md` (Phase 1.2.7 `doc_file_patterns` pseudo-code block), and `plugins/rite/skills/reviewers/SKILL.md` (Reviewers table Technical Writer row). Drift between these files silently changes tech-writer activation and Doc-Heavy PR detection — Issue #353 系統 1. See the script header at `plugins/rite/hooks/scripts/doc-heavy-patterns-drift-check.sh` for the extraction contract.

**Condition**: Always execute when the script exists. This check is independent of `commands.lint` configuration — it is a rite-workflow internal quality check.

**Skip condition**: Script file does not exist (e.g., marketplace install without hooks/scripts directory).

**Execution:**

```bash
if [ -f {plugin_root}/hooks/scripts/doc-heavy-patterns-drift-check.sh ]; then
  doc_heavy_drift_output=$(bash {plugin_root}/hooks/scripts/doc-heavy-patterns-drift-check.sh --all 2>&1)
  doc_heavy_drift_exit_code=$?
else
  doc_heavy_drift_exit_code=-1  # script not found
fi
```

**Result handling:**

| Exit Code | `doc_heavy_drift_status` | Action |
|-----------|--------------------------|--------|
| 0 | `success` | No drift across the 3 files — continue to Phase 4 |
| 1 | `warning` | Drift detected — record as **warning** (does NOT cause `[lint:error]`). Display findings but allow flow to continue |
| 2 | `error` | Invocation error — record as warning, display error message |
| -1 | `skipped` | Script not found — skip silently |

**Important**: Drift detection results are treated as **warnings**, not errors — same policy as Phase 3.5 drift check and Phase 3.6 bang-backtick check. A finding does NOT change the overall lint result pattern (`[lint:success]` remains `[lint:success]`). Reason: existing checks stay non-blocking during staged rollout, and the 3-file invariant should be fixed promptly by the author of the diverging change but not gate CI until coverage is validated across the rite plugin's self-hosting workflow.

**Record drift results** for Phase 4 reporting:
- `doc_heavy_drift_status`: `success` / `warning` / `error` / `skipped`
- `doc_heavy_drift_finding_count`: Extract from `doc_heavy_drift_output` by matching the line `==> Total doc-heavy-patterns-drift findings: N` (regex: `/Total doc-heavy-patterns-drift findings: (\d+)/`). If no match found, default to 0
- `doc_heavy_drift_output`: Script output (truncated if >50 lines)

### 3.8 Plugin-specific Checks (Wiki Growth Check) — Issue #524 layer 3

Execute the Wiki growth check script to detect "Phase X.X.W silently skipped" regressions. The script warns (non-blocking) when the wiki branch has gone unchanged for `wiki.growth_check.threshold_prs` consecutive merged PRs on the development base branch — strong evidence that `pr/review.md` Phase 6.5.W / `pr/fix.md` Phase 4.6.W / `issue/close.md` Phase 4.4.W are being skipped silently. See `plugins/rite/hooks/scripts/wiki-growth-check.sh` header for the detection contract and Issue #524 specification for the 3-layer defense rationale.

**Condition**: Always execute when the script exists. This check is independent of `commands.lint` configuration — it is a rite-workflow internal quality check.

**Skip condition**: Only the script's own absence (e.g., marketplace install without `hooks/scripts/` directory) makes lint.md skip the entire Phase 3.8. All other no-op cases (wiki disabled / wiki branch absent / `gh` CLI missing / `rite-config.yml` absent) are handled **inside** `wiki-growth-check.sh`, which still returns exit 0 → `wiki_growth_status=success` (with `findings_count=0`). lint.md does NOT need to detect these cases — the script's exit-0 contract takes care of them and the Phase 4 summary row will simply show `success (0 findings)` for any of these legitimate no-op states.

**Execution:**

```bash
if [ -f {plugin_root}/hooks/scripts/wiki-growth-check.sh ]; then
  wiki_growth_output=$(bash {plugin_root}/hooks/scripts/wiki-growth-check.sh --quiet 2>&1)
  wiki_growth_exit_code=$?
else
  wiki_growth_exit_code=-1  # script not found
fi
```

**Result handling:**

| Exit Code | `wiki_growth_status` | Action |
|-----------|----------------------|--------|
| 0 | `success` | Wiki growing healthily, OR a legitimate no-op (wiki disabled / wiki branch absent / `gh` CLI missing / `rite-config.yml` absent — script handled internally and returned 0 with `findings: 0`) — continue to Phase 4 |
| 1 | `warning` | Growth threshold exceeded — record as **warning** (does NOT cause `[lint:error]`). Display findings but allow flow to continue |
| 2 | `error` | Invocation error (bad args, not in git repo) — record as warning, display error message |
| -1 | `skipped` | Script not found (marketplace install without `hooks/scripts/`) — skip silently |

**Important**: Wiki growth check results are treated as **warnings**, not errors — same policy as Phase 3.5 / 3.6 / 3.7 checks. A finding does NOT change the overall lint result pattern (`[lint:success]` remains `[lint:success]`). Issue #524 AC-4 explicitly mandates this contract — the check exists to surface awareness, not to block CI.

**Record growth check results** for Phase 4 reporting:
- `wiki_growth_status`: `success` / `warning` / `error` / `skipped`
- `wiki_growth_finding_count`: Extract from `wiki_growth_output` by matching the line `==> Total wiki-growth-check findings: N` (regex: `/Total wiki-growth-check findings: (\d+)/`). If no match found, default to 0
- `wiki_growth_output`: Script output (truncated if >50 lines)

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

**Note on `error_count`**: `flow-state-update.sh` patch mode resets `error_count` to 0 on every phase transition (since #294). This prevents stale circuit breaker counts from one phase from poisoning subsequent phases.

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

**When called from `/rite:issue:start` (E2E Output Minimization):**
```
[lint:success] — lint passed ({target_file_count} files)
```

**Drift check warning appendix** (both standalone and E2E): When `drift_status` is `warning`, append drift findings after the lint result output:

```
⚠️ Drift check: {drift_finding_count} findings detected (warning, non-blocking)
{drift_output}
```

**Bang-backtick warning appendix** (both standalone and E2E): When `bang_backtick_status` is `warning` **or `error`**, append findings (for `warning`) or the invocation failure detail (for `error`) after the lint result output. Both statuses use the same appendix so that invocation failures (exit code 2) are never silently dropped. **Note**: Phase 3.5 drift check has the same observability gap (appendix fires only on `warning`, not `error`), but fixing drift check is **out of scope for this PR** — it is tracked as a follow-up item. Phase 3.7 (`Doc-heavy patterns drift check`, added in this PR) follows the same warning+error appendix policy as Phase 3.6, so only Phase 3.5 retains the legacy gap. The asymmetry here is intentional for this PR's narrow scope:

```
⚠️ Bang-backtick check: {bang_backtick_finding_count} findings detected ({bang_backtick_status}, non-blocking)
{bang_backtick_output}
```

**Doc-heavy patterns drift appendix** (both standalone and E2E): When `doc_heavy_drift_status` is `warning` **or `error`**, append findings (for `warning`) or the invocation failure detail (for `error`) after the lint result output. Both statuses use the same appendix so that invocation failures (exit code 2) are never silently dropped — same policy as the bang-backtick appendix:

```
⚠️ Doc-heavy patterns drift check: {doc_heavy_drift_finding_count} findings detected ({doc_heavy_drift_status}, non-blocking)
{doc_heavy_drift_output}
```

**Wiki growth check appendix (Issue #524 layer 3)** (both standalone and E2E): When `wiki_growth_status` is `warning` **or `error`**, append findings (for `warning`) or the invocation failure detail (for `error`) after the lint result output. Same warning+error appendix policy as bang-backtick / doc-heavy:

```
⚠️ Wiki growth check: {wiki_growth_finding_count} findings detected ({wiki_growth_status}, non-blocking)
{wiki_growth_output}
```

These appendices do NOT change the result pattern — `[lint:success]` remains the pattern even with drift, bang-backtick, doc-heavy-patterns-drift, or wiki-growth warnings/invocation errors.

> **Context savings**: Omit target description, command details, and flow continuation text. The caller already knows the context.

> **CRITICAL**: When called from `/rite:issue:start`, `/rite:lint` outputs the above message and **terminates**. The call to `rite:pr:create` is made by `/rite:issue:start` after Phase 5.2.1 is complete.

**Note**: `[lint:success]` is an output pattern used by `/rite:issue:start` Phase 5.2 to determine the lint result.

### 4.2 When Issues Found

**E2E flow (minimized output):**
```
[lint:error] — {error_count} errors, {warning_count} warnings
{first 10 lines of lint_output}
```

> **Context savings**: In e2e flow, omit fix suggestions (the caller returns to Phase 5.1 for fixes). Only include first 10 lines of lint output to identify the issue category.

**Standalone execution:**
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

> **E2E flow**: Skip this phase entirely (context savings). The result pattern in 4.1/4.2 already contains sufficient information for the caller.

**Standalone execution only:**

```
{i18n:lint_summary_title}

| {i18n:lint_summary_item} | {i18n:lint_summary_result} |
|------|------|
| {i18n:lint_target_path} | {target} |
| {i18n:lint_errors} | {error_count} |
| {i18n:lint_warnings} | {warning_count} |
| {i18n:lint_test} | {test_status} ({test_error_count} failures) |
| {i18n:lint_drift_check} | {drift_status} ({drift_finding_count} findings) |
| Bang-backtick check | {bang_backtick_status} ({bang_backtick_finding_count} findings) |
| Doc-heavy patterns drift check | {doc_heavy_drift_status} ({doc_heavy_drift_finding_count} findings) |
| Wiki growth check (#524) | {wiki_growth_status} ({wiki_growth_finding_count} findings) |
| {i18n:lint_duration} | {duration} |

{i18n:lint_next_steps}:
1. {i18n:lint_next_fix_errors}
2. {i18n:lint_next_rerun}
3. {i18n:lint_next_create_pr}

> **{i18n:lint_standalone_note}**: {i18n:lint_standalone_note_detail}
```

**Note**: The `{i18n:lint_test}` row is only shown when `commands.test` is configured. When tests were skipped, omit the row entirely. The `{i18n:lint_drift_check}` row is only shown when the drift check script exists and was executed. When `drift_status` is `skipped`, omit the row. The `Bang-backtick check` row follows the same rule: omit when `bang_backtick_status` is `skipped`. When `bang_backtick_status` is `error` (exit code 2 invocation error), display the row with the `error` status so the failure is surfaced rather than silently dropped. The `Doc-heavy patterns drift check` row follows the same policy as `Bang-backtick check`: omit when `doc_heavy_drift_status` is `skipped`, and display with the `error` status when exit code 2 surfaces an invocation failure. The `Wiki growth check (#524)` row follows the same policy: omit when `wiki_growth_status` is `skipped`, display with `success` / `warning` / `error` otherwise (`success` is the healthy state showing 0 findings; `warning` indicates threshold exceeded; `error` indicates exit code 2 invocation failure). **Asymmetry note**: The `{i18n:lint_drift_check}` row does NOT have an equivalent `error`-status display rule because Phase 3.5 drift check's observability gap is out of scope for this PR (tracked as a follow-up). This asymmetry is intentional and temporary — both rows should converge when drift check receives the same fix in a follow-up PR. Phase 3.7 (`Doc-heavy patterns drift check`) and Phase 3.8 (`Wiki growth check`) were added with the fixed appendix + summary-row pattern from the start, so they match Phase 3.6 rather than Phase 3.5.

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

Write the lint result content (from 4.4.3 template) to a temp file, then append to the work memory comment:

```bash
lint_result_tmp=$(mktemp)
trap 'rm -f "$lint_result_tmp"' EXIT
cat > "$lint_result_tmp" << 'LINT_EOF'
{lint_result_content}
LINT_EOF

bash {plugin_root}/hooks/issue-comment-wm-sync.sh update \
  --issue {issue_number} \
  --transform append-section \
  --section "品質チェック履歴" --content-file "$lint_result_tmp" \
  2>/dev/null || true

rm -f "$lint_result_tmp"
```

**Note for Claude**: `{lint_result_content}` を 4.4.3 のテンプレートから生成した実際の追記内容で置換すること。

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
# lint 結果に応じて次のステップの内容を選択し、一時ファイルに書き出す
next_steps_tmp=$(mktemp)
trap 'rm -f "$next_steps_tmp"' EXIT

# 例（lint success の場合）:
cat > "$next_steps_tmp" << 'NEXT_EOF'
- **コマンド**: /rite:pr:create
- **状態**: 待機中
- **備考**: lint 完了、PR 作成準備完了
NEXT_EOF

bash {plugin_root}/hooks/issue-comment-wm-sync.sh update \
  --issue {issue_number} \
  --transform replace-section \
  --section "次のステップ" --content-file "$next_steps_tmp" \
  2>/dev/null || true

rm -f "$next_steps_tmp"
```

**Note for Claude**: lint 結果（success/skip/error）に応じて上記 3 ケースのいずれかを `NEXT_EOF` ヒアドキュメントに記述すること。

---

## Workflow Incident Emit Helper (#366)

> **Reference**: See [workflow-incident-emit-protocol.md](../references/workflow-incident-emit-protocol.md) for the emit protocol and Sentinel Visibility Rule.

This skill emits sentinels for the following failure paths:

| Failure Path | Sentinel Type | Details |
|--------------|---------------|---------|
| Lint command not detected and user chose "skip" in Phase 1.3 | `manual_fallback_adopted` | `rite:lint command not detected, user skipped` |
| Lint tool not found at execution time (Phase 3) | `hook_abnormal_exit` | `rite:lint tool not found: {tool_name}` |
| Work memory append failure in Phase 4.4 | `hook_abnormal_exit` | `rite:lint work memory append failure` |

**Note**: `{pr_number}` is `0` for lint (no PR exists yet at lint time).

## Error Handling

See [Common Error Handling](../references/common-error-handling.md) for shared patterns (Not Found, Permission, Network errors).

| Error | Recovery |
|-------|----------|
| When the lint command fails | See error output for details |
| When the tool is not found | See [common patterns](../references/common-error-handling.md) (sentinel emit via Workflow Incident Emit Helper above) |

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
