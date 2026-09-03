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

| Phase | Standalone | E2E Flow |
|-------|-----------|----------|
| Phase 3 (Execution) | Full output | Full output (needed for error diagnosis) |
| Phase 4.1 (Success) | Full report | `[lint:success]` + 1-line summary only |
| Phase 4.2 (Error) | Full output + suggestions | `[lint:error]` + error count + first 10 lines only |
| Phase 4.3 (Summary) | Full table | **Skip entirely** |
| Phase 4.4 (Work Memory) | Full update | Full update (no change) |

> **⚠️ "Skip entirely" は出力の話**: Phase 4.3 は **人間向けサマリー表示を省く** だけ。Phase 3 の実行と Phase 4.4 の work memory 更新は常に行う。Identity: [workflow-identity.md](../../skills/rite-workflow/references/workflow-identity.md)。
> rationale: references/rationale.md#skip-entirely-display-only

判定は下記 Caller Context 表。

## Caller Context and End-to-End Flow

> **Plugin Path**: Resolve `{plugin_root}` per [Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script-full-version) before executing bash hook commands in this file.

| Caller | Output Pattern | Subsequent Action |
|-----------|-------------|---------------|
| `/rite:open` (end-to-end flow) | Output (required) | `/rite:open` calls `rite:pr-create` at ステップ 6 after consuming the lint result at ステップ 5.1 |
| Standalone execution | Output (required) | Display "next steps" guidance |

| Condition | Result |
|------|---------|
| `rite:lint` was called via the `Skill` tool immediately prior within the same session | Within end-to-end flow |
| Otherwise (user directly typed `/rite:lint`) | Standalone execution |

必須パターン: `[lint:success]` / `[lint:skipped]` / `[lint:error]` / `[lint:aborted]`

E2E では **`rite:pr-create` を直接呼ばない**。sentinel を出して `/rite:open` に返す。
rationale: references/rationale.md#no-direct-pr-create

---

## Arguments

| Argument | Description |
|------|------|
| `[path]` | File or directory to check (defaults to changed files if omitted) |

---

## Phase 0: Load Work Memory (End-to-End Flow)

### 0.1 End-to-End Flow Determination

| Condition | Result | Action |
|------|---------|------|
| Conversation history contains rich context from `/rite:open` | Within end-to-end flow | Work memory loading optional (information available in context) |
| `/rite:lint` was executed standalone | Standalone execution | Can identify Issue from branch name |

### 0.2 Load Work Memory

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

| Field | Extraction Pattern | Purpose |
|-----------|-------------|------|
| Issue number | `issue-(\d+)` from branch name | Phase 4.4 work memory update |
| Branch name | `- **ブランチ**: (.+)` | Verification |
| Phase | `- **フェーズ**: (.+)` | Flow position confirmation |
| Next steps | `### 次のステップ` section | Expected operation confirmation |

Issue 番号または work memory が無ければ警告して skip し、Phase 1 へ。

---

## Phase 1: Lint Command Detection

### 1.1 Check Explicit Configuration

`rite-config.yml` から lint コマンドを取る:

```yaml
commands:
  lint: "npm run lint"  # 明示的に設定されている場合
```

```bash
# rite-config.yml を読み取り
cat rite-config.yml
```

`commands.lint` があればそれを使う。

### 1.2 Auto-Detection (When No Configuration Exists)

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

検出できなければ `AskUserQuestion`:

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

| Choice | Subsequent Processing |
|--------|----------|
| **Skip and continue** | Record "lint skipped" in conversation context, skip Phase 2 onward, and complete normally. If called from `/rite:open`, proceed to the next step (PR creation) |
| **Specify command** | Follow up with `AskUserQuestion` to prompt for command input (see below), then execute Phase 2 onward with the entered command |
| **Abort** | Abort processing and display guidance to "configure lint and run again" |

スキップ時:

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

> **CRITICAL**: `/rite:open` から呼ばれたときは上記を出して **終了**する。`rite:pr-create` は `/rite:open` ステップ 5.1 が sentinel を消費したあと ステップ 6 が呼ぶ。
> rationale: references/rationale.md#no-direct-pr-create

`[lint:skipped]` の PR 本文反映は `/rite:open` ステップ 5 の責務:

```markdown
## Known Issues
- lint 未実行（lint コマンドが検出されませんでした）
```

「コマンドを指定」なら:

```
使用する lint コマンドを入力してください（例: npm run lint, ruff check .）

オプション:
- npm run lint
- ruff check .
- 他のコマンドを入力（Other を選択）
```

代表コマンドを選択肢に出し、Other で任意入力可。入力後は Phase 2 以降をそのコマンドで実行する。`rite-config.yml` には書かない。永続化は `/rite:setup` または手動編集。

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

#### 2.2.1 Get Base Branch

```
Read: rite-config.yml
```

1. `branch.base` があれば `{base_branch}`
2. ファイル不在 / キー不在 / `null` / 空文字 / `branch` 節不在 → `main`

#### 2.2.2 Detect Changed Files

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

処理を中止する。`HEAD` 差分やプロジェクト全体へ黙って倒さない。
rationale: references/rationale.md#no-silent-head-fallback

**When there are no changed files:**

```
変更ファイルがありません。プロジェクト全体をチェックします

ベースブランチとの差分がないため、プロジェクト全体をチェックします。
特定のパスに限定するには /rite:lint <path> を指定してください。
```

スコープ拡大を警告したうえでプロジェクト全体を対象にする。

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

対象ファイルの指定方法はコマンド依存。エラー時も出力を表示し、判定は exit code。

### 3.3 Capture Execution Results

exit 0 = 問題なし。exit 1+ = エラーまたは警告。

### 3.4 Test Execution (Conditional)

**Condition**: `commands.test` が non-null かつ `verification.run_tests_before_pr` が `true`（既定 `true`）。`verification` 節不在は既定 enabled。`commands.test` は必須。

**Skip**（いずれか → Phase 4）: `commands.test` が `null` / 未設定、または `run_tests_before_pr: false`。

E2E で implement.md Phase 5.1.0.6 が既に成功していれば再実行せず結果を再利用する。skip 時は無出力。
rationale: references/rationale.md#no-duplicate-test-in-e2e

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

Phase 4 用: `test_status`（`success` / `error` / `skipped`）、`test_error_count`、`test_output`（500 行超は truncate）。

### 3.5 Plugin-specific Checks (Generic Loop)

情報系チェックの前に descriptive-number diff gate を実行する。finding または読めない diff は blocking: `lint_output` に記録し `error_count` を増やし Phase 4.2（`[lint:error]`）。`branch.base` は Phase 2.2 と同じ origin-first。走査は `plugins/rite/` の追加行のみ。`tests/` は除外。
rationale: references/rationale.md#descriptive-number-blocking

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

下記表の rite 内部チェックを 1 つの generic loop で回す。`commands.lint` 非依存。根拠は [plugin-checks-rationale.md](references/plugin-checks-rationale.md)。regex / アルゴリズムは各 script header が SoT。

**Check table**（loop / 4.1 appendix / 4.3 行の SoT。表順）:

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

- **Findings are warnings, not errors**: どのチェックも結果パターンを変えない。`[lint:success]` は findings があっても `[lint:success]`。warning を error に昇格しない。
- **Recording**（チェックごと 3 変数）: `{prefix}_status` / `{prefix}_finding_count`（Count line regex。無マッチは 0）/ `{prefix}_output`（50 行超は truncate）。例: `bang_backtick` → `bang_backtick_status` / `bang_backtick_finding_count` / `bang_backtick_output`。
- **Out-of-contract exit codes**（0/1/2/-1 以外）: `error` として warning 記録し続行。
rationale: references/rationale.md#findings-are-warnings

**Per-check notes**: Number reference — 走査面（本ファイル）へ Issue/PR 番号参照を戻さない。面を広げるなら script の `DEFAULT_TARGETS` へ追加。

**Adding a new check**: 表に 1 行（path / label / prefix / count regex）、exit 契約（0/1/2）と count line、根拠を [plugin-checks-rationale.md](references/plugin-checks-rationale.md) へ。新 Phase / appendix / summary 行は不要。

<!-- Heading numbers 3.8 / 3.9 / 3.15 / 3.18 below are pinned: header comments in hooks/scripts (Non-Target files) structurally reference these lint.md Phase numbers, and sh-cross-ref-check verifies those references against this file's heading numbers. Do not renumber or remove these supplement headings without updating the referencing scripts. -->

### 3.8 Wiki Growth Check supplement (internal no-op contract)

wiki 無効 / wiki branch 不在 / `gh` 不在 / config 不在は script 内で exit 0・`findings: 0`。4.3 は `success (0 findings)`。

### 3.9 Gitignore Health Check supplement (internal no-op contract)

wiki 無効 / config 不在は script 内で exit 0・`findings: 0`。検証対象は state_root（main checkout）の `.rite/.gitignore` の 3 行構成（生成は setup / hook。lint は書き換えない）。

### 3.15 Orphan Reference Check supplement (detection inputs)

orphan は inbound（`plugins/rite/` / `docs/` / `.github/`、自己参照除く）AND test pin（`hooks/tests/` / `scripts/tests/`）が両方 0 のときだけ。静的資産（`.gitkeep` / `__init__.py` / `LICENSE` / `CHANGELOG.md`）は skip。

### 3.18 Projects Board Drift Check supplement (detect-and-enumerate only)

lint は auto-reconcile しない。`Done` 遷移は `/rite:cleanup` / `/rite:issue-close`、`Cancelled` 遷移は `/rite:issue-cancel`。on-demand は `--reconcile`。no-op（projects 無効 / config 不在 → exit 0）は 3.8 / 3.9 と同じ。

---

## Phase 4: Report Results

### 4.0 Defense-in-Depth: State Update Before Output (End-to-End Flow)

結果パターンを出す**前に** flow-state を更新する。flow-state ファイルがあるときだけ（standalone は skip）。
rationale: references/rationale.md#defense-in-depth-state

| Result | Phase | Phase Detail | Next Action |
|--------|-------|-------------|-------------|
| `[lint:success]` / `[lint:skipped]` | `lint` | `品質チェック完了` | `rite:lint completed successfully. Proceed to /rite:open ステップ 6 (PR 作成). Do NOT stop.` |
| `[lint:error]` | `lint` | `lint エラー検出` | `rite:lint found errors. Caller retries rite:lint once; on second failure stop and /rite:recover. Do NOT stop on first error.` |
| `[lint:aborted]` | `lint` | `品質チェック中断` | `rite:lint was aborted by user. Proceed to caller 完了レポート (orchestrator 経由なら caller へ復帰 / standalone なら開発者復帰 — abort 時は PR 作成スキップ). Do NOT stop.` |

```bash
bash {plugin_root}/hooks/flow-state.sh set \
  --phase "{phase_value}" \
  --active true \
  --next "{next_action_value}" \
  --if-exists
```

`{phase_value}` / `{next_action_value}` は上表。`error_count` は set のたびに 0（`--preserve-error-count` 以外）。
rationale: references/rationale.md#defense-in-depth-state

flow-state があるときはローカル work memory も同期。[Work Memory Format](../../skills/rite-workflow/references/work-memory-format.md#usage-in-commands)

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

placeholder は上表の実値。lock 失敗は WARNING して続行（best-effort）。

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

**Plugin-specific check appendix**（standalone / E2E）: Phase 3.5 表の順で `{prefix}_status` が `warning` **または `error`** なら追記。exit 2 を黙って落とさない。appendix は結果パターンを変えない:

```
⚠️ {check label}: {finding_count} findings detected ({status}, non-blocking)
{output}
```

> E2E では対象・コマンド・継続文を省く。出力して **終了**。`rite:pr-create` は呼ばない。
> rationale: references/rationale.md#no-direct-pr-create

### 4.2 When Issues Found

**E2E flow (minimized output):**
```
[lint:error] — {error_count} errors, {warning_count} warnings
{first 10 lines of lint_output}
```

> E2E では修正提案を省き、lint 出力は先頭 10 行。

**Standalone execution:**
```
[lint:error]
品質チェック完了

{error_count} 件のエラー、{warning_count} 件の警告が検出されました

{lint_output}

---

修正案:
```

**Presenting fix suggestions**（standalone）:

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

`テスト` 行は `commands.test` があるときだけ。skip なら省略。プラグイン行は Phase 3.5 表順、1 チェック 1 行。`skipped` は省略。`success` / `warning` / `error` は表示（`error` = 起動失敗を落とさない）。

### 4.4 Automatic Work Memory Update (Conditional)

> **WARNING**: Work memory is published as Issue comments. In public repositories, it is visible to third parties. Do not record confidential information (credentials, personal information, internal URLs, etc.) in work memory.

`issue-{number}` ブランチのときだけ。main/master や Issue 番号無しは実行しない。

#### 4.4.1 Identify Related Issue

ブランチ名から Issue 番号:

```bash
issue_number=$(git branch --show-current | grep -oE 'issue-[0-9]+' | grep -oE '[0-9]+')
```

番号が無ければ skip。

#### 4.4.2 Retrieve and Update Work Memory Comment

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

追記テンプレート:

```markdown
### 品質チェック履歴

#### {timestamp}: /rite:lint 実行
- **結果**: {status}（問題なし / エラーあり）
- **エラー**: {error_count}件
- **警告**: {warning_count}件
- **対象**: {target}
```

comment 不在 / main・master なら skip。確認不要。

#### 4.4.4 Record "Next Steps"

**success:**

```markdown
### 次のステップ
- **コマンド**: /rite:pr-create
- **状態**: 待機中
- **備考**: lint 完了、PR 作成準備完了
```

**skip:**

```markdown
### 次のステップ
- **コマンド**: /rite:pr-create
- **状態**: 待機中
- **備考**: lint スキップ（コマンド未検出）、PR 作成準備完了
```

**error:**

```markdown
### 次のステップ
- **コマンド**: /rite:lint
- **状態**: 待機中
- **備考**: lint エラー修正後、再度 lint を実行
```

既存 `### 次のステップ` は置換、無ければ末尾追記。

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

| Output Pattern | Action in End-to-End Flow |
|-------------|---------------------------|
| `[lint:success]` | `/rite:lint` execution completes, and the caller `/rite:open` consumes the sentinel at ステップ 5.1 then proceeds to ステップ 6 (PR creation) |
| `[lint:skipped]` | `/rite:lint` execution completes, and the caller `/rite:open` consumes the sentinel at ステップ 5.1 then proceeds to ステップ 6 (PR creation) |
| `[lint:error]` | After fixing errors, run lint again (return to Phase 3) |
| `[lint:aborted]` | Flow ends (execution of `/rite:open` also ends) |

standalone では ステップ 5.1 の sentinel 消費も ステップ 6 の PR 作成も **実行しない**。

### 5.2 Processing After `/rite:lint` Completion

`[lint:success]` / `[lint:skipped]` なら実行完了。`/rite:open` ステップ 5.1 が sentinel を消費し ステップ 6 で `rite:pr-create` を呼ぶ。本スキルは **`rite:pr-create` を直接呼ばない**。
rationale: references/rationale.md#checklist-guard

### 5.3 Standalone Execution Behavior

Phase 5 は実行しない。Phase 4 の案内を出して終了する。
