---
name: lint
description: |
  rite workflow の品質チェックステップ: プロジェクト設定に基づく lint / 整合性チェックを実行する。
  /rite:open・/rite:ready から programmatic に呼ばれる sub-step、または手動 /rite:lint。汎用の
  「lint」ヘルパーではなく、その語では auto-activate しない。
  起動: /rite:lint
argument-hint: ""
---

# /rite:lint

## Contract
**Input**: rite-config.yml `commands` section (lint/test/typecheck commands), flow state (optional, e2e flow)
**Output**: `[lint:success]` | `[lint:skipped]` | `[lint:error]` | `[lint:aborted]`

品質チェック（lint）を実行し、結果を報告する

## E2E Output Minimization

When called from the `/rite:open` end-to-end flow, minimize output to reduce context window consumption:

| Phase | Standalone | E2E Flow |
|-------|-----------|----------|
| Phase 3 (Execution) | Full output | Full output (needed for error diagnosis) |
| Phase 4.1 (Success) | Full report | `[lint:success]` + 1-line summary only |
| Phase 4.2 (Error) | Full output + suggestions | `[lint:error]` + error count + first 10 lines only |
| Phase 4.3 (Summary) | Full table | **Skip entirely** |
| Phase 4.4 (Work Memory) | Full update | Full update (no change) |

> **⚠️ "Skip entirely" は出力の話**: Phase 4.3 の "Skip entirely" は **人間向けサマリー表示を省く** ことを意味するのみで、Phase 3 の lint 実行や Phase 4.4 の work memory 更新など処理本体は常に実行する。時間・context を理由にした lint 処理そのものの省略は禁止。Identity: [workflow-identity.md](../../skills/rite-workflow/references/workflow-identity.md)。

**Detection**: See [Caller Context and End-to-End Flow](#caller-context-and-end-to-end-flow) determination method below.

---

Execute the following phases in order when this command is invoked.

## Caller Context and End-to-End Flow

> **Plugin Path**: Resolve `{plugin_root}` per [Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script-full-version) before executing bash hook commands in this file.

This command has two invocation cases: standalone execution and being called from the `/rite:open` end-to-end flow.

| Caller | Output Pattern | Subsequent Action |
|-----------|-------------|---------------|
| `/rite:open` (end-to-end flow) | Output (required) | `/rite:open` calls `rite:pr-create` at ステップ 6 after consuming the lint result at ステップ 5.1 |
| Standalone execution | Output (required) | Display "next steps" guidance |

**Determination method**: Claude determines the caller from conversation context:

| Condition | Result |
|------|---------|
| `rite:lint` was called via the `Skill` tool immediately prior within the same session | Within end-to-end flow |
| Otherwise (user directly typed `/rite:lint`) | Standalone execution |

**Note**: `skills/fix/SKILL.md` also uses conversation context for determination in the same manner.

**Output patterns (required regardless of caller):**
- `[lint:success]` - lint completed successfully
- `[lint:skipped]` - lint skipped
- `[lint:error]` - lint errors detected
- `[lint:aborted]` - user aborted

> **Important (flow continuation responsibility)**: When executed within the end-to-end flow, **this command does NOT directly call `rite:pr-create`; it returns control to the caller `/rite:open`**. `/rite:open` calls `rite:pr-create` at ステップ 6 after consuming the lint result at ステップ 5.1 (checklist completion confirmation happens earlier at ステップ 4.4).

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
| Conversation history contains rich context from `/rite:open` | Within end-to-end flow | Work memory loading optional (information available in context) |
| `/rite:lint` was executed standalone | Standalone execution | Can identify Issue from branch name |

### 0.2 Load Work Memory

Extract the Issue number from the current branch and retrieve work memory:

```bash
# ブランチ名から Issue 番号を抽出
issue_number=$(git branch --show-current | grep -oE 'issue-[0-9]+' | grep -oE '[0-9]+')

# リポジトリ情報を取得（SSH host alias 対応: git-remote.sh 優先 + gh repo view fallback。
# canonical: references/gh-cli-patterns.md#ownerrepo-resolution-ssh-host-alias-safe）
owner_repo=$(bash {plugin_root}/hooks/scripts/lib/git-remote.sh resolve-owner-repo 2>/dev/null) || owner_repo=""
owner=""; repo=""
[ -n "$owner_repo" ] && IFS=$'\t' read -r owner repo <<< "$owner_repo"
[ -n "$owner" ] && [ -n "$repo" ] || {
  owner=$(gh repo view --json owner --jq '.owner.login')
  repo=$(gh repo view --json name --jq '.name')
}

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
lint コマンドを検出できませんでした

対応している自動検出:
- Node.js: package.json の scripts.lint
- Python: ruff check（pyproject.toml 検出時）
- Rust: cargo clippy（Cargo.toml 検出時）
- Go: golangci-lint run（go.mod 検出時）

オプション:
- スキップして続行（推奨）: lint をスキップし、次のステップに進みます
- コマンドを指定: lint コマンドを手動で入力します
- 中断: 処理を中断します
```

**Subsequent processing for each choice:**

| Choice | Subsequent Processing |
|--------|----------|
| **Skip and continue** | Record "lint skipped" in conversation context, skip Phase 2 onward, and complete normally. If called from `/rite:open`, proceed to the next step (PR creation) |
| **Specify command** | Follow up with `AskUserQuestion` to prompt for command input (see below), then execute Phase 2 onward with the entered command |
| **Abort** | Abort processing and display guidance to "configure lint and run again" |

**Output and recording when skipped:**

When lint is skipped, output the completion message in the following format:

**Standalone execution:**
```
[lint:skipped]
lint をスキップしました。
理由: lint コマンド未検出

次のステップ:
1. 必要に応じて `/rite:pr-create` で PR 作成
```

**When called from `/rite:open`:**
```
[lint:skipped]
lint をスキップしました。
理由: lint コマンド未検出

---
🔄 **フロー継続**: 呼び出し元の `/rite:open` が ステップ 6（PR 作成）を実行
```

> If `/rite:lint` continues to PR creation directly, it bypasses the checklist confirmation in the caller, potentially creating a PR with incomplete tasks.
> **CRITICAL**: When called from `/rite:open`, `/rite:lint` outputs the above message and **terminates**. The call to `rite:pr-create` is made by `/rite:open` at ステップ 6 after the lint result is consumed at ステップ 5.1.

**Meaning of output patterns:**
- `[lint:skipped]`: Used by `/rite:open` ステップ 5.1 to detect this pattern and decide to proceed to ステップ 6 (PR creation)
- `[lint:success]`: When lint completed successfully (output in Phase 4.1)
- `[lint:error]`: When lint detected errors (output in Phase 4.2)
- `[lint:aborted]`: When the user selected "Abort"

**Clarification of responsibilities:**

Reflecting the lint skip in the PR body is the responsibility of `/rite:open` ステップ 5:
1. `/rite:lint` only outputs the above output patterns
2. When `/rite:open` detects `[lint:skipped]`, it prepares the PR body template before calling `/rite:pr-create`
3. The "Known Issues" section of the PR body includes the following:

```markdown
## Known Issues
- lint 未実行（lint コマンドが検出されませんでした）
```

**Processing when command is specified:**

When "Specify command" is selected, use `AskUserQuestion` to prompt for command input:

```
使用する lint コマンドを入力してください（例: npm run lint, ruff check .）

オプション:
- npm run lint
- ruff check .
- 他のコマンドを入力（Other を選択）
```

**Note**: Present representative commands as choices in `AskUserQuestion` `options`. The user can also select "Other" to enter a custom command.

When the user enters/selects a command:

1. Execute Phase 2 onward using the entered command
2. Do not save to `rite-config.yml` (temporary use only)
3. If saving to configuration is needed, guide the user to `/rite:setup` or manual editing

---

## Phase 2: Determine Target Files

### 2.1 When Arguments Are Specified

Use the specified path as-is:

```
対象: {path}
```

If the path does not exist:

```
指定されたパス '{path}' が見つかりません

対処:
1. パスが正しいか確認
2. ファイル/ディレクトリが存在するか確認
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
変更ファイルがありません。プロジェクト全体をチェックします

ベースブランチとの差分がないため、プロジェクト全体をチェックします。
特定のパスに限定するには /rite:lint <path> を指定してください。
```

Target the entire project (current directory) with a visible warning that the scope has expanded.

---

## Phase 3: Lint Execution

### 3.1 Pre-Execution Notice

```
品質チェックを実行しています...

コマンド: {lint_command}
対象: {target_path または "変更ファイル ({count} files)"}
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

**Duplicate execution avoidance**: When called from the `/rite:open` end-to-end flow and tests were already run and passed in `implement.md` Phase 5.1.0.6 (Test Verification Gate — implement.md retains its own internal phase numbering; test results available in conversation context), skip duplicate test execution and reuse previous results.

When skipped, no output needed (silent skip).

**Execution:**

```
テストを実行しています...

コマンド: {test_command}
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

### 3.5 Plugin-specific Checks (Generic Loop)

Before the informational checks, run the descriptive-number diff gate. Unlike the generic checks below, a finding or an unreadable diff is blocking: record it in `lint_output`, increment `error_count`, and route to Phase 4.2 (`[lint:error]`). The gate resolves `branch.base` with the same origin-first fallback used in Phase 2.2 and scans only added lines under `plugins/rite/`; `tests/` remains excluded.

```bash
descriptive_number_diff_output=$(bash {plugin_root}/hooks/scripts/descriptive-number-diff-gate.sh 2>&1)
descriptive_number_diff_rc=$?
case "$descriptive_number_diff_rc" in
  0) ;;
  1|2)
    lint_output="${lint_output}${lint_output:+\n}${descriptive_number_diff_output}"
    error_count=$((error_count + 1))
    ;;
  *)
    lint_output="${lint_output}${lint_output:+\n}ERROR: descriptive-number diff gate returned unexpected rc=$descriptive_number_diff_rc"
    error_count=$((error_count + 1))
    ;;
esac
```

Run every rite-workflow internal quality check listed in the check table below through one generic execution loop. These checks are **independent of `commands.lint` configuration** (they lint the rite workflow definition itself, not the user's code). Per-check background (incident origin), detection patterns, and exclusion rules live in [references/plugin-checks-rationale.md](references/plugin-checks-rationale.md); each script's header comment is the SoT for its exact regex literals and algorithm.

**Check table** (SoT for what runs and how — the loop, the Phase 4.1 appendix, and the Phase 4.3 summary rows all iterate over this table in order):

| # | Check (label) | Invocation (relative to `{plugin_root}/`) | Vars prefix | Count line (regex) |
|---|---------------|-------------------------------------------|-------------|---------------------|
| 1 | Bang-backtick check | `hooks/scripts/bang-backtick-check.sh --all` | `bang_backtick` | `Total bang-backtick findings: (\d+)` |
| 2 | Reviewer registry drift check | `hooks/scripts/reviewer-registry-drift-check.sh --all` | `reviewer_registry_drift` | `Total reviewer-registry-drift findings: (\d+)` |
| 3 | Wiki growth check | `hooks/scripts/wiki-growth-check.sh --quiet` | `wiki_growth` | `Total wiki-growth-check findings: (\d+)` |
| 4 | Gitignore health check | `hooks/scripts/gitignore-health-check.sh --quiet` | `gitignore_health` | `Total gitignore-health-check findings: (\d+)` |
| 5 | Backlink format check | `hooks/scripts/backlink-format-check.sh --all` | `backlink_format` | `Total backlink-format findings: (\d+)` |
| 6 | Hardcoded line-number check | `hooks/scripts/hardcoded-line-number-check.sh --all` | `hardcoded_line` | `Total hardcoded line-number findings: (\d+)` |
| 7 | Comment journal narration | `hooks/scripts/comment-journal-check.sh --all` | `comment_journal` | `Total comment-journal findings: (\d+)` |
| 8 | Comment line-ref check | `hooks/scripts/comment-line-ref-check.sh --all` | `comment_line_ref` | `Total comment-line-ref findings: (\d+)` |
| 9 | Direct gh issue create check | `scripts/check-no-direct-gh-issue-create.sh --all` | `direct_gh_issue` | `Total files with violations: (\d+)` |
| 10 | Orphan reference check | `hooks/scripts/orphan-reference-check.sh --all` | `orphan_check` | `orphans=(\d+)` |
| 11 | Shell-prose cross-ref check | `hooks/scripts/sh-cross-ref-check.sh --all` | `sh_cross_ref` | `Total sh-cross-ref findings: (\d+)` |
| 12 | Operational bash block heaviness check | `hooks/scripts/bash-heaviness-check.sh --all` | `bash_heaviness` | `Total bash-heaviness findings: (\d+)` |
| 13 | Projects board drift check | `hooks/scripts/projects-board-drift-check.sh --quiet` | `projects_board_drift` | `Total projects-board-drift findings: (\d+)` |
| 14 | Number reference check | `hooks/scripts/number-reference-check.sh --all` | `number_ref` | `Total number-ref findings: (\d+)` |
| 15 | Sentinel contract check | `hooks/scripts/sentinel-contract-check.sh --all` | `sentinel_contract` | `Total sentinel-contract findings: (\d+)` |
| 16 | Tmp hardcode check | `hooks/scripts/tmp-hardcode-check.sh --all --skip-if-no-target` | `tmp_hardcode` | `Total tmp-hardcode findings: (\d+)` |
| 17 | Dollar-zero check | `hooks/scripts/dollar-zero-check.sh --all --skip-if-no-target` | `dollar_zero` | `Total dollar-zero findings: (\d+)` |
| 18 | Tempfile lifecycle check | `hooks/scripts/tempfile-lifecycle-check.sh --all --skip-if-no-target` | `tempfile_lifecycle` | `Total tempfile-lifecycle findings: (\d+)` |
| 19 | Pipefail grep-q check | `hooks/scripts/pipefail-grep-q-check.sh --all --skip-if-no-target` | `pipefail_grep_q` | `Total pipefail-grep-q findings: (\d+)` |

**Execution loop** — for each table row, run (`{script}` = Invocation column path, `{args}` = Invocation column args, `{prefix}` = Vars prefix column):

```bash
if [ -f {plugin_root}/{script} ]; then
  {prefix}_output=$(bash {plugin_root}/{script} {args} 2>&1)
  {prefix}_exit_code=$?
else
  {prefix}_exit_code=-1  # script not found
fi
```

**Execution policy** (declared once — applies to every check in the table):

| Exit Code | `{prefix}_status` | Action |
|-----------|-------------------|--------|
| 0 | `success` | No findings (or a legitimate internal no-op — see the 3.8 / 3.9 supplements) — continue |
| 1 | `warning` | Findings detected — record as **warning** (does NOT cause `[lint:error]`). Display findings but allow flow to continue |
| 2 | `error` | Invocation error — record as warning, display error message |
| -1 | `skipped` | Script not found (e.g., marketplace install without the script directory) — **skip silently** |

- **Findings are warnings, not errors**: no check result changes the overall lint result pattern — `[lint:success]` remains `[lint:success]` regardless of findings. Do NOT promote a warning to an error. These checks surface awareness for progressive cleanup; they do not gate CI.
- **Recording** (for Phase 4 reporting, 3 variables per check): `{prefix}_status` (per the table above) / `{prefix}_finding_count` (extract from `{prefix}_output` by matching the Count line regex in the check table; if no match found, default to 0) / `{prefix}_output` (script output, truncated if >50 lines). Example: the `bang_backtick` prefix records `bang_backtick_status` / `bang_backtick_finding_count` / `bang_backtick_output`.
- **Out-of-contract exit codes** (anything other than 0/1/2/-1): treat as `error` — record as warning and continue.

**Per-check notes** (differences the table cannot express):

- **Number reference check**: operational rule — do not reintroduce Issue/PR number references into the scanned surface (CHANGELOG en/ja and this file); cite the rationale in prose instead. To widen the surface, append paths to `DEFAULT_TARGETS` in the script.

**Adding a new check**: add one row to the check table (script path + label + vars prefix + count-line regex), make the script follow the exit code contract above (0 = pass / 1 = findings / 2 = invocation error) and emit a count line, then add its background to [references/plugin-checks-rationale.md](references/plugin-checks-rationale.md). No new Phase section, appendix, or summary row is needed — the generic loop, appendix, and summary iterate over the table.

<!-- Heading numbers 3.8 / 3.9 / 3.15 / 3.18 below are pinned: header comments in hooks/scripts (Non-Target files) structurally reference these lint.md Phase numbers, and sh-cross-ref-check verifies those references against this file's heading numbers. Do not renumber or remove these supplement headings without updating the referencing scripts. -->

### 3.8 Wiki Growth Check supplement (internal no-op contract)

Warns when the wiki branch has gone unchanged for `wiki.growth_check.threshold_prs` consecutive merged PRs (evidence that the wiki-update phases in pr-review / fix / issue-close are being silently skipped). Wiki disabled / wiki branch absent / `gh` CLI missing / `rite-config.yml` absent are all handled inside the script → exit 0 with `findings: 0`, and the Phase 4.3 summary row simply shows `success (0 findings)` for these legitimate no-op states.

### 3.9 Gitignore Health Check supplement (internal no-op contract)

Detects regression of the `.rite/wiki/` exclusion rule in `.gitignore` (the last line of defense against wiki-ingest silent leaks). Wiki disabled / config absent are handled inside the script → exit 0 with `findings: 0`.

### 3.15 Orphan Reference Check supplement (detection inputs)

Flags a file as orphan only when inbound references (searched in `plugins/rite/`, `docs/`, `.github/`, excluding self-references) AND test pins (searched in `plugins/rite/hooks/tests/` and `plugins/rite/scripts/tests/`) are both zero. Well-known static assets (`.gitkeep`, `__init__.py`, `LICENSE`, `CHANGELOG.md`) are skipped.

### 3.18 Projects Board Drift Check supplement (detect-and-enumerate only)

Lint does NOT auto-reconcile — the `Done` transition stays the responsibility of `/rite:cleanup` / `/rite:issue-close`; on-demand reconciliation is available via the script's `--reconcile` flag. Its no-op contract (projects disabled / config absent → exit 0 inside the script) matches the 3.8 / 3.9 supplements.

---

## Phase 4: Report Results

### 4.0 Defense-in-Depth: State Update Before Output (End-to-End Flow)

Before outputting any result pattern (`[lint:success]`, `[lint:skipped]`, `[lint:error]`, `[lint:aborted]`), update flow state to reflect the post-lint phase (defense-in-depth). This prevents intermittent flow interruptions when the fork context returns to the caller — even if the LLM churns after fork return and the system forcibly terminates the turn (bypassing the Stop hook), the state file will already contain the correct `next_action` for resumption.

**Condition**: Execute only when flow state file exists (indicating e2e flow). Skip if the file does not exist (standalone execution).

**State update by result**:

| Result | Phase | Phase Detail | Next Action |
|--------|-------|-------------|-------------|
| `[lint:success]` / `[lint:skipped]` | `lint` | `品質チェック完了` | `rite:lint completed successfully. Proceed to /rite:open ステップ 6 (PR 作成). Do NOT stop.` |
| `[lint:error]` | `lint` | `lint エラー検出` | `rite:lint found errors. Fix the errors and re-invoke rite:lint, or AskUserQuestion で 修正再実行 / 強制続行 / 中止 を選択. Do NOT stop.` |
| `[lint:aborted]` | `lint` | `品質チェック中断` | `rite:lint was aborted by user. Proceed to caller 完了レポート (orchestrator 経由なら caller へ復帰 / standalone なら開発者復帰 — abort 時は PR 作成スキップ). Do NOT stop.` |

```bash
bash {plugin_root}/hooks/flow-state.sh set \
  --phase "{phase_value}" \
  --active true \
  --next "{next_action_value}" \
  --if-exists
```

Replace `{phase_value}` and `{next_action_value}` with the values from the table above based on the lint result.

**Note on `error_count`**: `flow-state.sh set` resets `error_count` to 0 by default on every phase transition, and preserves the existing value only when `--preserve-error-count` is passed. `error_count` is currently a reserved/legacy schema slot with no production reader; resetting on transition keeps the slot well-defined for future re-introduction without carrying stale counts.

**Also sync to local work memory** (`.rite-work-memory/issue-{n}.md`) when flow state file exists:

Use the self-resolving wrapper. See [Work Memory Format - Usage in Commands](../../skills/rite-workflow/references/work-memory-format.md#usage-in-commands) for details and marketplace install notes.

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

Where `{phase_value}`, `{phase_detail}`, and `{next_action_value}` match the flow state update above. Claude substitutes these with the actual values based on the lint result before executing.

**On lock failure**: Log a warning and continue — local work memory update is best-effort.

### 4.1 When No Issues Found

**Standalone execution:**
```
[lint:success]
品質チェック完了

問題は検出されませんでした

対象: {target_description}
コマンド: {lint_command}
```

**When called from `/rite:open` (E2E Output Minimization):**
```
[lint:success] — lint passed ({target_file_count} files)
```

**Plugin-specific check appendix** (both standalone and E2E): for each check in the Phase 3.5 check table (in table order), when `{prefix}_status` is `warning` **or `error`**, append the following after the lint result output. Both statuses use the same appendix so that invocation failures (exit code 2) are never silently dropped — for `warning` the `{prefix}_output` carries the findings, for `error` it carries the failure diagnostic. These appendices do NOT change the result pattern — `[lint:success]` remains the pattern regardless of how many checks report warnings or invocation errors:

```
⚠️ {check label}: {finding_count} findings detected ({status}, non-blocking)
{output}
```

> **Context savings**: Omit target description, command details, and flow continuation text. The caller already knows the context.

> **CRITICAL**: When called from `/rite:open`, `/rite:lint` outputs the above message and **terminates**. The call to `rite:pr-create` is made by `/rite:open` at ステップ 6 after the lint result is consumed at ステップ 5.1.

**Note**: `[lint:success]` is an output pattern used by `/rite:open` ステップ 5.1 to determine the lint result.

### 4.2 When Issues Found

**E2E flow (minimized output):**
```
[lint:error] — {error_count} errors, {warning_count} warnings
{first 10 lines of lint_output}
```

> **Context savings**: In e2e flow, omit fix suggestions (the caller returns to ステップ 4 implementation for fixes). Only include first 10 lines of lint output to identify the issue category.

**Standalone execution:**
```
[lint:error]
品質チェック完了

{error_count} 件のエラー、{warning_count} 件の警告が検出されました

{lint_output}

---

修正案:
```

**Note**: `[lint:error]` is an output pattern used by `/rite:open` ステップ 5.1 to determine the lint result.

**Presenting fix suggestions:**

Analyze the error content and present fix suggestions when possible:

1. **When auto-fix is available:**
   ```
   自動修正を実行しますか？

   コマンド: {fix_command}
   例:
       npm run lint -- --fix
       ruff check --fix
       cargo clippy --fix

   オプション:
   - はい、自動修正を実行
   - いいえ、手動で修正
   ```

2. **When manual fix is required:**
   Present specific fix suggestions for each error.

### 4.3 Summary Display

> **E2E flow**: Skip this phase entirely (context savings). The result pattern in 4.1/4.2 already contains sufficient information for the caller.

**Standalone execution only:**

```
品質チェック結果サマリー

| 項目 | 結果 |
|------|------|
| 対象 | {target} |
| エラー | {error_count} |
| 警告 | {warning_count} |
| テスト | {test_status} ({test_error_count} failures) |
| {check label}（Phase 3.5 の表の各チェックにつき 1 行、表の順） | {status} ({finding_count} findings) |
| 所要時間 | {duration} |

次のステップ:
1. エラーを修正
2. 再度 `/rite:lint` を実行
3. 問題がなければ `/rite:pr-create` で PR 作成

> **注**: `/rite:open` の一気通貫フローから呼び出された場合、この「次のステップ」案内は**スキップ**されます。呼び出し元が出力パターン（`[lint:success]` 等）を検出し、自動的に次のアクション（PR 作成）に進みます。**この案内は単独実行時のみ参照してください**。
```

**Note**: The `テスト` row is only shown when `commands.test` is configured. When tests were skipped, omit the row entirely. Plugin-specific check rows follow one shared rule: one row per check in the Phase 3.5 check table (table order), omit the row when `{prefix}_status` is `skipped`, and display it for `success` / `warning` / `error` (`success` = no findings or a legitimate internal no-op; `warning` = findings detected; `error` = invocation failure — displayed so the failure is surfaced rather than silently dropped).

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
- **コマンド**: /rite:pr-create
- **状態**: 待機中
- **備考**: lint 完了、PR 作成準備完了
```

**Content to append (on lint skip):**

```markdown
### 次のステップ
- **コマンド**: /rite:pr-create
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
- **コマンド**: /rite:pr-create
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

## Error Handling

See [Common Error Handling](../../references/common-error-handling.md) for shared patterns (Not Found, Permission, Network errors).

失敗パス (lint command 未検出で user skip / tool not found / work memory append 失敗) は plain `WARNING` を stderr に出力する。

| Error | Recovery |
|-------|----------|
| When the lint command fails | See error output for details |
| When the tool is not found | See [common patterns](../../references/common-error-handling.md) (WARNING を stderr に出力) |

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
| `[lint:success]` | `/rite:lint` execution completes, and the caller `/rite:open` consumes the sentinel at ステップ 5.1 then proceeds to ステップ 6 (PR creation) |
| `[lint:skipped]` | `/rite:lint` execution completes, and the caller `/rite:open` consumes the sentinel at ステップ 5.1 then proceeds to ステップ 6 (PR creation) |
| `[lint:error]` | After fixing errors, run lint again (return to Phase 3) |
| `[lint:aborted]` | Flow ends (execution of `/rite:open` also ends) |

**Note**: During standalone execution (when the user directly executes `/rite:lint`), the ステップ 5.1 sentinel consumption and ステップ 6 PR creation are **not executed**. Lint sentinel consumption and PR creation are features only executed within the `/rite:open` end-to-end flow; standalone lint execution ends without flow continuation.

### 5.2 Processing After `/rite:lint` Completion

When `[lint:success]` or `[lint:skipped]` is output:

**`/rite:lint` execution completes**, and Claude returns to `/rite:open` ステップ 5.1 to consume the lint sentinel, then proceeds to ステップ 6 to call `rite:pr-create`.

**Important**:
- `/rite:lint` does **NOT directly call** `rite:pr-create`
- The caller `/rite:open` consumes the lint sentinel at ステップ 5.1 and proceeds to ステップ 6 (PR creation)
- After all checklist items are complete, `/rite:open` calls `rite:pr-create`

**Design intent**:
- Guard function to prevent proceeding to PR creation until all Issue checklist items are complete
- If there are incomplete items, return to ステップ 4 (implementation) to continue implementation

### 5.3 Standalone Execution Behavior

During standalone execution, Phase 5 is not executed; display the "next steps" guidance from Phase 4 and terminate.
