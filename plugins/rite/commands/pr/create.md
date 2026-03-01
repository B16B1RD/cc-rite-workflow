---
description: ドラフト Pull Request を作成
context: fork
---

# /rite:pr:create

ドラフト PR を作成し、関連 Issue と連携する

---

Execute the following phases in order when this command is invoked.

## Caller Context and End-to-End Flow

This command can be invoked in two ways: standalone execution or from the `/rite:issue:start` end-to-end flow (via Phase 5.3).

| Caller | Subsequent Action |
|-----------|---------------|
| End-to-end flow (via `/rite:issue:start` Phase 5.3) | **Output pattern and return control to caller** |
| Standalone execution | Display "next steps" guidance |

**Determination method**: Claude determines the caller from conversation context:

| Condition | Determination |
|------|---------|
| Invoked via `Skill` tool from the `/rite:issue:start` end-to-end flow (Phase 5.3) within the same session | Within end-to-end flow |
| All other cases (user directly typed `/rite:pr:create`) | Standalone execution |

> **Important (responsibility for flow continuation)**: When executed within the end-to-end flow, this Skill outputs a machine-readable output pattern (`[pr:created:{number}]` or `[pr:create-failed]`) and **returns control to the caller** (`/rite:issue:start`). The caller determines the next action based on this output pattern.

---

## Arguments

| Argument | Description |
|------|------|
| `[title]` | PR title (auto-generated if omitted) |

---

## Phase 0: Load Work Memory (During End-to-End Flow)

When executed within the end-to-end flow, load necessary information from work memory (shared memory).

### 0.1 Determine End-to-End Flow Status

Determine the caller from conversation context:

| Condition | Determination | Action |
|------|---------|------|
| Conversation history contains rich context from the `/rite:issue:start` end-to-end flow | Within end-to-end flow | Work memory loading optional (information available in context) |
| `/rite:pr:create` was executed standalone | Standalone execution | Issue can be identified from branch name |

### 0.2 Load Work Memory

Extract Issue number from the current branch and retrieve work memory from local file (SoT):

```bash
# ブランチ名から Issue 番号を抽出
issue_number=$(git branch --show-current | grep -oE 'issue-[0-9]+' | grep -oE '[0-9]+')
```

**Local work memory (SoT)**: Read `.rite-work-memory/issue-{issue_number}.md` with the Read tool. This local file is the Source of Truth.

**Fallback (local file missing/corrupt)**: If the local file does not exist or is corrupt, fall back to the Issue comment API:

```bash
owner=$(gh repo view --json owner --jq '.owner.login')
repo=$(gh repo view --json name --jq '.name')

gh api repos/{owner}/{repo}/issues/{issue_number}/comments \
  --jq '[.[] | select(.body | contains("📜 rite 作業メモリ"))] | last | .body'
```

### 0.3 Information to Retrieve

Extract the following information from work memory and retain in context:

| Field | Extraction Pattern | Purpose |
|-----------|-------------|------|
| Issue number | `issue-(\d+)` from branch name | Generate `Closes #XX` in PR body |
| Branch name | `- **ブランチ**: (.+)` | Verify base during PR creation |
| Phase | `- **フェーズ**: (.+)` | Confirm flow position |
| lint results | `### 品質チェック履歴` section | Reflect in PR body |

**If work memory is not found:**

If Issue number cannot be retrieved, delegate to Phase 1.4 fallback processing.

---

## Phase 1: Verify Current State

### 1.1 Retrieve Base Branch

Read `rite-config.yml` at the project root using the Read tool, and get the `branch.base` value:

```
Read: rite-config.yml
```

**Retrieval logic:**
1. If `rite-config.yml` exists and `branch.base` is set -> Use that value as `{base_branch}`
2. If `rite-config.yml` does not exist (Read tool returns an error), or `branch.base` is not set -> Use `main` as default

**Definition of "not set":**
- `branch.base` key does not exist
- `branch.base` key value is `null` or empty string
- `branch` section itself does not exist

**Placeholder interpretation:**

`{base_branch}` in this document is replaced with the actual branch name obtained by the logic above. For example, if `branch.base: "develop"` is configured, the subsequent bash command `git diff --stat origin/{base_branch}...HEAD` is executed as `git diff --stat origin/develop...HEAD`.

### 1.2 Branch Verification

Verify the diff between the current branch and `{base_branch}`:

```bash
git branch --show-current
```

**If on the base branch:**

```
エラー: 現在 {branch} ブランチにいます

PR を作成するには作業ブランチに切り替えてください。
`/rite:issue:start` で作業を開始できます。
```

Terminate processing.

### 1.3 Verify Changes

```bash
git status --porcelain
git diff --stat origin/{base_branch}...HEAD
git log --oneline origin/{base_branch}...HEAD
```

**Fallback:** Try diff in order: `origin/{base_branch}` -> `{base_branch}` (try next on error). If both fail, display an error:

```
エラー: 変更の差分を取得できません

ベースブランチ '{base_branch}' が見つかりません。

対処:
1. rite-config.yml で branch.base の設定を確認
2. git fetch origin でリモート情報を更新
3. 手動で差分を確認: git diff <base_branch>...HEAD
```

Terminate processing. Do not fall back to `HEAD` diff — this would produce an inaccurate change summary.

**If no commits exist:**

```
警告: まだコミットがありません

変更をコミットしてから PR を作成してください。
```

Terminate processing.

### 1.4 Extract Issue Number

Extract the related Issue number from the branch name:

```
パターン: {type}/issue-{number}-{slug}
例: feat/issue-17-pr-create → Issue #17
```

If extraction fails, confirm with `AskUserQuestion`:

```
ブランチ名から Issue 番号を特定できません

現在のブランチ: {branch}

オプション:
- Issue 番号を手動で指定
- Issue なしで PR を作成
- キャンセル
```

### 1.5 Retrieve Issue Information

```bash
gh issue view {issue_number} --json number,title,body,state,labels
```

**If the Issue is closed:**

```
警告: Issue #{number} は既にクローズされています

PR を作成しますか？
オプション:
- はい、作成する
- キャンセル
```

### 1.6 Retrieve Work Memory

Retrieve work memory from Issue comments:

```bash
gh api repos/{owner}/{repo}/issues/{issue_number}/comments --jq '.[] | select(.body | contains("rite 作業メモリ"))'
```

If work memory is found, extract the following information:
- Progress status
- Changed files
- Decisions and notes

---

## Phase 2: Quality Checks (Optional)

### 2.1 Verify Auto-Detected Commands

Retrieve build/lint commands from `rite-config.yml`:

```yaml
commands:
  build: null  # 自動検出
  lint: null   # 自動検出
```

Auto-detection logic:
1. Detect from `scripts` in `package.json`
2. Detect from targets in `Makefile`
3. Language-specific default commands

### 2.2 Confirm Quality Check Execution

Confirm execution with `AskUserQuestion`:

```
PR 作成前に品質チェックを実行しますか？

検出されたコマンド:
- lint: {lint_command}
- build: {build_command}

オプション:
- すべて実行（推奨）
- lint のみ
- スキップ
```

### 2.3 Execute Checks

Execute the selected checks:

```bash
# lint 実行例
npm run lint
```

**If errors are found:**

```
品質チェックでエラーが検出されました

{error_output}

オプション:
- エラーを無視して PR 作成
- 修正してから再実行
- キャンセル
```

### 2.4 Verify Issue Body Checklist

If the Issue body contains a checklist, check for incomplete items and display a warning.

#### 2.4.1 Extract Checklist

Extract checklist from the Issue body obtained in Phase 1.5:

```bash
# Issue 本文を取得（既に Phase 1.5 で取得済みの場合は再利用）
gh issue view {issue_number} --json body --jq '.body'
```

**Extraction pattern:**

```
パターン: /^- \[[ xX]\] (.+)$/gm
```

**Exclusion pattern:**

Exclude Tasklists containing Issue references (used for parent-child Issue management):

```
パターン: /^- \[[ xX]\] #\d+/gm
```

#### 2.4.2 Detect Incomplete Check Items

Detect incomplete items (`- [ ]`) from the extracted checklist.

**If no incomplete items (all checklist items completed):**

If a checklist exists and all items are completed (`- [x]`), proceed to Phase 2.5.

**If incomplete items exist:**

```
警告: Issue 本文に未完了のチェック項目があります

未完了項目:
- [ ] {item_1}
- [ ] {item_2}
- [ ] {item_3}

オプション:
- 未完了のまま PR 作成（推奨）: PR 本文に未完了項目を記載します
- チェック項目を完了してから再実行: 作業を中断し、未完了項目を完了させます
- キャンセル
```

**Subsequent processing for each option:**

| Option | Subsequent Processing |
|--------|----------|
| **未完了のまま PR 作成（推奨）** | Proceed to Phase 2.5. Record incomplete items in the "Incomplete Issue Check Items" section of the PR body |
| **チェック項目を完了してから再実行** | Display guidance to complete incomplete items and re-run `/rite:pr:create`, then terminate |
| **キャンセル** | Terminate processing |

#### 2.4.3 Record Incomplete Items in PR Body

If "Create PR with incomplete items" is selected, add the following section to the PR body:

```markdown
## 未完了の Issue チェック項目

以下のチェック項目が Issue 本文で未完了です:

- [ ] {item_1}
- [ ] {item_2}
- [ ] {item_3}

これらの項目は後続の作業で対応予定です。
```

#### 2.4.4 If No Checklist Exists

If the Issue body does not contain a checklist, skip this section and proceed to Phase 2.5.

### 2.5 Verify Unresolved Issues (issue_accountability)

> **Reference**: [AI Coding Principles](../../skills/rite-workflow/references/coding-principles.md) - `issue_accountability` (Sincere response to identified issues)

Before creating the PR, verify that there are no unresolved issues or findings.

#### 2.5.1 Verification Targets

Detect unresolved issues from the following sources:

| Source | What to Verify |
|--------|----------|
| Work memory | Unresolved items in the "要確認事項" section |
| Conversation history | Warnings/errors detected by lint/test |
| Review results in conversation history | Findings judged as "out of scope" or "not applicable" (including self-review results)[^1] |

[^1]: If self-review results do not exist in the same session (e.g., when `/rite:pr:create` is executed standalone), this source is skipped.

#### 2.5.2 Verify Work Memory

Parse the "要確認事項" section of work memory.

**Note**: If work memory was already retrieved in Phase 0.2, reuse that content without making another API call. For standalone execution, use values (`{owner}`, `{repo}`, `{issue_number}`) already retrieved in Phase 1.6.

**Determination method**: If work memory has already been retrieved within this session (API call made in Phase 0.2 or Phase 1.6), the result is retained in context, so the command below is not executed; instead, the retained content is referenced.

```bash
# 作業メモリから要確認事項を抽出（Phase 0.2 または Phase 1.6 で未取得の場合のみ実行）
gh api repos/{owner}/{repo}/issues/{issue_number}/comments \
  --jq '.[] | select(.body | contains("📜 rite 作業メモリ")) | .body'
```

Claude extracts the "### 要確認事項" section from the retrieved work memory body and detects unchecked items (`- [ ]` format).

**Note**: Do not use bash text processing (`grep -A`, etc.); Claude analyzes the entire body to identify the section. This avoids line count limitation issues.

If unchecked items exist, display a warning.

#### 2.5.3 Detection from Conversation History

Claude **reviews conversations within its own context window** and checks whether there are statements matching the following **specific patterns**.

Detect the following from conversation context: "out of scope"/"not applicable" judgments, "pre-existing issue" judgments, unresolved lint/test warnings, newly added TODO/FIXME comments (detected via `git diff origin/{base_branch}...HEAD | grep -E "^\+.*(TODO:|FIXME:|XXX:)"`). Resolved determination: if any of the following exists in conversation history, consider it resolved: fix (Edit/Write), Issue creation (`gh issue create`), or explanation/reply.

#### 2.5.4 Processing When Unresolved Issues Exist

If unresolved issues are detected, confirm with `AskUserQuestion`:

```
警告: 未対応の問題・指摘があります

以下の項目が未対応です（Phase 2.5.3 で検出した未対応問題リストから表示）:
| # | 内容 | 情報源 |
|---|------|--------|
| 1 | {problem_summary} | {detection_source} |
| 2 | {problem_summary} | {detection_source} |

「対象外」「既存の問題」は対応しない理由になりません。
発見した問題には必ず対応が必要です。

オプション:
- 別 Issue を作成して PR 作成を続行（推奨）: 未対応項目を Issue として登録し、PR を作成します
- 問題を今すぐ修正する: PR 作成を中断し、問題を修正します
- PR 作成を中止する: 問題を確認してから再実行します
```

**Note**: `{problem_summary}` and `{detection_source}` are the same placeholders defined in Phase 2.5.5.

**Subsequent processing for each option:**

| Option | Subsequent Processing |
|--------|----------|
| **別 Issue を作成して PR 作成を続行（推奨）** | 2.5.5 Auto-create Issues -> Proceed to Phase 3 |
| **問題を今すぐ修正する** | Display guidance to fix unresolved issues and re-run `/rite:pr:create`, then terminate processing |
| **PR 作成を中止する** | Terminate processing |

**When there are many issues (5 or more):**

**Note**: This threshold (5) is a fixed value and cannot be changed in `rite-config.yml`. It is set to optimize user experience by recommending batch processing.

If 5 or more unresolved issues are detected, recommend batch processing:

```
警告: 未対応の問題・指摘が {count} 件あります（5件以上）

一括処理を推奨します:

オプション:
- すべて別 Issue として一括作成（推奨）: {count} 件の Issue を自動作成します
- 個別に対応を選択: 各問題について対応方法を選択します
- PR 作成を中止する: 問題を確認してから再実行します
```

| Option | Subsequent Processing |
|--------|----------|
| **すべて別 Issue として一括作成** | Auto-create Issues for all problems -> Proceed to Phase 3 |
| **個別に対応を選択** | Present Phase 2.5.4 options for each problem **one by one** (select resolution method for each, proceed to Phase 3 after all are completed) |
| **PR 作成を中止する** | Terminate processing |

#### 2.5.5 Auto-Create Issues

If "Create separate Issues and continue with PR creation" is selected, create an Issue for each unresolved problem:

Create Issues using the `--body-file` pattern (see `gh-cli-patterns.md`):

```bash
# Note: Empty check is required because {problem_summary} and {problem_details} are dynamically generated.
# Naming convention: Use descriptive names like tmpfile_issue/tmpfile_pr when multiple tmpfiles exist in short succession
tmpfile=$(mktemp)
trap 'rm -f "$tmpfile"' EXIT

cat <<'BODY_EOF' > "$tmpfile"
## 概要

{problem_summary}

## 問題の詳細

{problem_details}

## 発生元

- 元 Issue: #{original_issue_number}
- 検出日時: {timestamp}
- 検出方法: {detection_method}
BODY_EOF

if [ ! -s "$tmpfile" ]; then
  echo "ERROR: Issue body is empty" >&2
  exit 1
fi

gh issue create --title "fix: {problem_summary}" --body-file "$tmpfile"
```

Apply the `tech-debt` label only if it exists (skip if not). On Issue creation failure, choose retry/skip/abort (max 2 retries).

After creation, append to the "Related Issues" section of the PR body:

**Sequential suffix naming convention**: When creating multiple Issues, assign sequential suffixes `_1`, `_2`, ... in creation order. For example, if 3 Issues are created, they become `{created_issue_1}`, `{created_issue_2}`, `{created_issue_3}`.

```markdown
## 関連 Issue

Closes #{original_issue_number}

### 検出された問題（別 Issue として追跡）

- #{created_issue_1}: {problem_summary_1}
- #{created_issue_2}: {problem_summary_2}
```

#### 2.5.6 If No Issues Found

If no unresolved issues are detected:

```
未対応の問題は検出されませんでした。Phase 3 へ進みます。
```

Proceed to Phase 3.

#### 2.5.7 Behavior During End-to-End Flow

Behavior when invoked from `/rite:issue:start`:

| Situation | Behavior |
|------|------|
| No unresolved issues | Auto-proceed to Phase 3 |
| Unresolved issues (fewer than 5) | Proceed to Phase 3 after individual confirmation |
| Unresolved issues (5 or more) | Proceed to Phase 3 after batch confirmation |

**Important**: Even within the end-to-end flow, verification of unresolved issues is **never skipped**. This is the core of the `issue_accountability` principle and is mandatory to prevent suppression of issues.

---

## Phase 3: Create PR

### 3.1 Generate PR Title

Generate the title in Conventional Commits format:

**Language determination rules:**

Determine the PR title language according to the `language` setting in `rite-config.yml`:

| Setting | Behavior |
|--------|------|
| `auto` | Detect user's input language and generate in the same language |
| `ja` | Generate title in Japanese |
| `en` | Generate title in English |

**Note**: If the Issue title is in a different language from the configured language, translate to the configured language when generating the title.

**Title generation rules:**
1. Use the type from the branch name
2. Extract scope and description from the Issue title
3. Generate the title in the determined language

> **⚠️ CRITICAL**: The `description` part of the PR title **MUST** follow the `language` setting in `rite-config.yml`. The examples below are for reference only — always generate the description in the language determined by the setting, not by copying the example language.

```
Pattern: {type}({scope}): {description}
Example (English): feat(pr): implement /rite:pr:create command
Example (Japanese): feat(pr): /rite:pr:create コマンドを実装
```

**type mapping:**
| Branch prefix | PR type |
|----------------|---------|
| feat/ | feat |
| fix/ | fix |
| docs/ | docs |
| refactor/ | refactor |
| chore/ | chore |
| style/ | style |
| test/ | test |

### 3.2 Generate PR Body

Use a template based on the project type (`project.type` in `rite-config.yml`).

Template file: `templates/pr/{project_type}.md`

**Language consistency rules:**

Generate the PR body in **the same language determined in Phase 3.1**:

| Element | Subject to Language Unification |
|------|---------------|
| Section headings | `## Summary` / `## 概要`, etc. |
| Boilerplate text | Description for `Closes #XX`, etc. |
| Checklist items | `- [ ] Tests added` / `- [ ] テスト追加`, etc. |

Information to include in the PR body: summary, related Issue (`Closes #{number}`), changes (from work memory or git diff), checklist. Generate all in the language determined in Phase 3.1.

#### 3.2.1 Context Optimization During End-to-End Flow

When executed via the end-to-end flow (`/rite:issue:start`), apply the following optimizations to reduce context usage.

**Optimization conditions (OR evaluation):** During end-to-end flow execution / 20 or more changed files / Over 30 tool invocations. 30 invocations is lightweight optimization for PR creation alone; 50 invocations (see `issue/start.md`) is full-scale mitigation.

**Optimization content:** Changes -> file list and summary only (show top 3 files), Work memory -> progress summary only, Checklist -> mandatory items only. Applied automatically without user confirmation.

### 3.3 Push to Remote

Push the local branch to remote:

```bash
git push -u origin {branch_name}
```

### 3.4 Create Draft PR

**Sanitization**: Explicit escaping is not required here. The 3-layer defense pattern (mktemp + HEREDOC with quoted delimiter + empty check + --body-file) prevents shell variable expansion issues. Claude substitutes placeholders directly without manual escaping.

```bash
# Generate body content from Phase 3.2 template and work memory (structure is consistent regardless of optimization)
# Note: Empty check is required because {body} is dynamically generated.
tmpfile=$(mktemp)
trap 'rm -f "$tmpfile"' EXIT

cat <<'BODY_EOF' > "$tmpfile"
{body}
BODY_EOF

if [ ! -s "$tmpfile" ]; then
  echo "ERROR: PR body is empty" >&2
  exit 1
fi

gh pr create --draft --base "{base_branch}" --title "{title}" --body-file "$tmpfile"
```

### 3.5 Update Work Memory Phase

After PR creation, update the local work memory (SoT) and sync to Issue comment (backup).

**Step 1: Update local work memory**

Use the self-resolving wrapper. See [Work Memory Format - Usage in Commands](../../skills/rite-workflow/references/work-memory-format.md#usage-in-commands) for details.

```bash
WM_SOURCE="create" \
  WM_PHASE="phase5_pr" \
  WM_PHASE_DETAIL="PR作成完了" \
  WM_NEXT_ACTION="rite:pr:review を実行" \
  WM_BODY_TEXT="PR #{pr_number} created." \
  WM_ISSUE_NUMBER="{issue_number}" \
  bash plugins/rite/hooks/local-wm-update.sh 2>/dev/null || true
```

**On lock failure**: Log a warning and continue — local work memory update is best-effort.

**Step 2: Sync to Issue comment (backup)**

```bash
comment_id=$(gh api repos/{owner}/{repo}/issues/{issue_number}/comments \
  --jq '[.[] | select(.body | contains("📜 rite 作業メモリ"))] | last | .id // empty')

# Claude が本文をパースし、セッション情報セクションの該当行を更新して PATCH
# - **フェーズ**: phase5_pr
# - **フェーズ詳細**: PR作成完了
# - **最終更新**: {timestamp}
# - **PR 番号**: #{pr_number}
```

---

## Phase 4: Post-Processing

### 4.1 Auto-Update Work Memory

> **Warning**: Work memory is published as Issue comments. In public repositories, it is viewable by third parties. Do not record confidential information (credentials, personal information, internal URLs, etc.) in work memory.

Automatically update the Issue's work memory comment.

#### 4.1.1 Collect Update Information

Automatically collect the following information during PR creation:

```bash
# 変更ファイルの取得
git diff --name-status origin/{base_branch}...HEAD

# コミット履歴の取得
git log --oneline origin/{base_branch}...HEAD
```

#### 4.1.2 Retrieve and Update Work Memory Comment

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
{4.1.3 の内容を実際の値で置換して記述}
NEW_SECTION_EOF
    jq -n --rawfile body "$tmpfile" '{"body": $body}' \
      | gh api repos/{owner}/{repo}/issues/comments/"$comment_id" \
        -X PATCH --input -
  fi
fi
```

**Note for Claude**: ⚠️ このブロック全体を**1つの Bash ツール呼び出し**で実行すること。`current_body` 取得・追記内容の heredoc 定義・PATCH を別の Bash ツール呼び出しに分割すると、前の呼び出しのシェル変数（`current_body` 等）が失われてヘッダーが消失する（Issue #693）。`{4.1.3 の内容を実際の値で置換して記述}` を 4.1.3 のテンプレートから生成した実際の追記内容で置換し、**すべてを1ブロックで**実行する。

#### 4.1.3 Update Content

Automatically append the following to work memory:

```markdown
### 進捗
- [x] 実装完了
- [x] PR 作成済み

### 変更ファイル
| ファイル | 状態 |
|---------|------|
| {path} | {status} |

### 関連 PR
- **番号**: #{pr_number}
- **タイトル**: {pr_title}
- **URL**: {pr_url}
- **作成日時**: {timestamp}

### コミット履歴
{commit_log}

### 次のステップ
- **コマンド**: /rite:pr:review #{pr_number}
- **状態**: 待機中
- **備考**: PR 作成完了、レビュー準備完了
```

**Note**: `{pr_number}` is replaced with the actual PR number when recording. It must not be recorded as a placeholder.

**Status determination:**
- `A` -> Added
- `M` -> Modified
- `D` -> Deleted
- `R` -> Renamed

**Note**: If the work memory comment is not found, skip the update and display a warning.

### 4.2 Completion Report

```
ドラフト PR #{pr_number} を作成しました

タイトル: {title}
URL: {pr_url}

関連 Issue: #{issue_number}

次のステップ:
1. PR の内容を確認
2. `/rite:pr:review` でセルフレビュー
3. `/rite:pr:ready` で Ready for review に変更
```

---

## Error Handling

| Error | Resolution |
|--------|------|
| Push failure | Check network -> `gh auth status` -> `git pull --rebase` -> retry |
| PR creation failure | Check existing PRs with `gh pr list` -> verify permissions -> retry |
| Issue not found | Choose: create without Issue / specify different Issue / cancel |
## Language Support

Follow `language` in `rite-config.yml` (`auto`: detect input language, `ja`: Japanese, `en`: English). Title and body are unified in the same language. Priority for `auto` mode: user input language -> Issue body language -> Japanese.

---

## Phase 5: End-to-End Flow Continuation (Output Pattern)

> **This phase is only executed within the end-to-end flow. For standalone execution, skip Phase 5 entirely, display the Phase 4.2 completion report (including "next steps" guidance), and terminate.**

### 5.1 Output Pattern (Return Control to Caller)

Output the following pattern based on PR creation result:

| State | Output Pattern |
|-------|---------------|
| PR creation succeeded | `[pr:created:{pr_number}]` |
| PR creation failed | `[pr:create-failed]` |

**Important**:
- Do **NOT** invoke `rite:pr:review` via the Skill tool
- Return control to the caller (`/rite:issue:start`)
- The caller determines the next action based on this output pattern

**Example output:**
```
PR #123 をドラフトとして作成しました。

[pr:created:123]
```

### 5.2 Behavior During Standalone Execution

For standalone execution, skip Phase 5 entirely and display the Phase 4.2 completion report (see the blockquote at the beginning of Phase 5 for details).
