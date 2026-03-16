---
description: PR マージ後のクリーンアップを実行
---

# /rite:pr:cleanup

## Contract
**Input**: Merged PR (auto-detected from current branch or specified)
**Output**: Cleanup result summary table (branch deletion, Status update, Issue close results)

Automate post-PR-merge cleanup tasks (branch deletion, switch to main, Status update)

---

When this command is executed, run the following phases in order.

## Arguments

| Argument | Description |
|----------|-------------|
| `[branch_name]` | Branch name to clean up (defaults to the current branch if omitted) |

---

## Phase 1.0: Activate Flow State

> **Plugin Path**: Resolve `{plugin_root}` per [Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script) before executing bash hook commands in this file.

Activate `.rite-flow-state` so that `stop-guard.sh` blocks premature `end_turn` during cleanup phases.

```bash
if [ -f .rite-flow-state ]; then
  bash {plugin_root}/hooks/flow-state-update.sh patch \
    --phase "cleanup" --next "Execute cleanup phases. Do NOT stop."
else
  bash {plugin_root}/hooks/flow-state-update.sh create \
    --phase "cleanup" --issue 0 --branch "" --loop 0 --pr 0 \
    --session {session_id} \
    --next "Execute cleanup phases. Do NOT stop."
fi
```

**Purpose**: After PR merge, `.rite-flow-state` is `active: false, phase: completed`. Without re-activation, `stop-guard.sh` exits immediately (L46) and provides no protection against premature `end_turn`, causing the user to type "continue" multiple times.

---

## Phase 1: State Verification

### 1.1 Check Current Branch

```bash
git branch --show-current
```

**Retrieving the base branch:**

Use the Read tool to read `rite-config.yml` at the project root and obtain the `branch.base` value:

```
Read: rite-config.yml
```

**Retrieval logic:**
1. If `rite-config.yml` exists and `branch.base` is set -> Use that value as `{base_branch}`
2. If `rite-config.yml` does not exist (Read tool returns an error), or `branch.base` is not set -> Detect the repository's default branch with the following command:

```bash
git symbolic-ref refs/remotes/origin/HEAD | sed 's@^refs/remotes/origin/@@'
```

**When `git symbolic-ref` fails:**

The above command fails on repositories where `origin/HEAD` is not set. If it fails, display an error and terminate:

```
エラー: デフォルトブランチを自動検出できませんでした。

rite-config.yml で明示的に設定してください:
  branch:
    base: "your-default-branch"

または origin/HEAD を設定してください:
  git remote set-head origin --auto
```

Terminate processing. Do not fall back to a guessed branch name — switching to the wrong branch after cleanup could cause data loss.

From this point forward, the retrieved branch name is used as `{base_branch}`.

**When on the base branch:**

If no branch is specified as an argument:

```
現在 {branch} ブランチにいます

クリーンアップするブランチを指定してください:
/rite:pr:cleanup <branch_name>

または最近マージされたブランチを確認:
```

Display merged branches using `git branch --merged {base_branch}` and prompt for selection via `AskUserQuestion`.

### 1.2 Search for Related PR

Search for a PR associated with the current branch (or the specified branch):

```bash
gh pr list --head {branch_name} --state all --json number,title,state,mergedAt,url
```

**If no PR is found:**

```
警告: ブランチ {branch_name} に関連する PR が見つかりません

オプション:
- ブランチを削除してクリーンアップ続行
- キャンセル
```

### 1.3 Verify PR State

**If the PR has not been merged:**

```
警告: PR #{number} はまだマージされていません

状態: {state}
タイトル: {title}

マージされていない PR のブランチを削除すると、作業内容が失われる可能性があります。

オプション:
- キャンセル（推奨）
- 強制的にクリーンアップ
```

**If the PR has been merged:**

Proceed to the next phase.

### 1.4 Retrieve Repository Information

Retrieve the repository owner and repo name for use with the GitHub API in Phase 1.5 and beyond:

```bash
# owner と repo を取得（後続の API 呼び出しで使用）
gh repo view --json owner,name --jq '{owner: .owner.login, repo: .name}'
```

**Purpose of retrieved values:**
- `{owner}`: Used in GitHub API calls (e.g., `repos/{owner}/{repo}/issues/...`)
- `{repo}`: Used in GitHub API calls

**Note**: The LLM retains the retrieved values in the conversation context and uses them in subsequent phases.

### 1.5 Identify Related Issue

Identify the related Issue from the PR body or branch name:

**Extraction patterns:**
1. `Closes #XX`, `Fixes #XX`, `Resolves #XX` in the PR body
2. `issue-XX` pattern in the branch name

```bash
gh pr view {pr_number} --json body,headRefName
```

**If an Issue number is identified, retrieve detailed Issue information:**

```bash
# 関連 Issue の詳細情報を取得（Phase 1.7.3.1 で使用）
gh issue view {issue_number} --json number,title,state,body --jq '{number, title, state, body}'
```

**Note**: `gh issue view` can retrieve information regardless of whether the Issue is OPEN or CLOSED. Even if the Issue was auto-closed after the PR merge, retrieving the detailed information will succeed.

**Purpose of retrieved values:**
- `{original_issue_number}`: Used as a reference when creating Issues in Phase 1.7.3
- `{original_issue_title}`: Used in Issue body generation in Phase 1.7.3.1
- `{original_issue_body}`: Referenced during `{task_details}` generation in Phase 1.7.3.1. The LLM extracts implementation requirements and background from the body and uses them as context when inferring concrete work procedures for incomplete tasks

### 1.5.1 Detect Parent Issue

Check whether the related Issue is a child Issue (included in another Issue's Tasklist).

**Detection purpose:**
- To update the parent Issue's Tasklist checkbox when a child Issue's PR is merged (Phase 3.6.4)
- To auto-close the parent Issue when the last child Issue's PR is merged (Phase 3.7)

#### 1.5.1.1 Detection via GitHub Sub-Issues API (preferred)

```bash
gh api graphql -H "GraphQL-Features: sub_issues" -f query='
query($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) {
    issue(number: $number) {
      parent {
        number
        title
        state
      }
    }
  }
}' -f owner="{owner}" -f repo="{repo}" -F number={issue_number}
```

**Note**: The `GraphQL-Features: sub_issues` header is required (the Sub-Issues API is in beta)

#### 1.5.1.2 Tasklist Fallback

If the Sub-Issues API does not find a parent, search repository Issues to check if the Issue is included in a Tasklist:

```bash
# Issue 本文に "- [ ] #{issue_number}" または "- [x] #{issue_number}" を含む Issue を検索
gh issue list --search "in:body \"- [ ] #{issue_number}\" OR \"- [x] #{issue_number}\"" --json number,title,state --jq '.[0]'
```

#### 1.5.1.3 Handling Detection Results

| Detection Result | Action |
|-----------------|--------|
| Parent Issue found | Retain `{parent_issue_number}`, `{parent_issue_title}`, `{parent_issue_state}` in the conversation context |
| Parent Issue not found | Skip Phase 3.6.4 and Phase 3.7 |
| API error | Display a warning and skip Phase 3.6.4 and Phase 3.7 |

**Note**: Failure to detect a parent Issue does not block the entire cleanup process. Display a warning and continue.

### 1.6 Check Incomplete Tasks in Work Memory

If a related Issue has been identified, check for incomplete tasks in the work memory comment. If no related Issue was identified, skip this phase (Phase 1.6) and Phase 1.7 (automatic assessment and processing of incomplete tasks) and proceed to Phase 2.

#### 1.6.1 Retrieve Work Memory

**Local work memory (SoT)**: Read `.rite-work-memory/issue-{issue_number}.md` with the Read tool. If the file exists, use its content for incomplete task detection.

**Fallback (local file missing/corrupt)**: Fall back to the Issue comment API:

```bash
# 作業メモリコメントの ID と本文を取得
# 注: 複数コメントがマッチする可能性を考慮し、last で最新コメントを取得
comment_data=$(gh api repos/{owner}/{repo}/issues/{issue_number}/comments \
  --jq '[.[] | select(.body | contains("📜 rite 作業メモリ"))] | last')

# ID を抽出（Phase 1.7.4 の更新時に使用）
comment_id=$(echo "$comment_data" | jq -r '.id // empty')

# 本文を抽出
comment_body=$(echo "$comment_data" | jq -r '.body // empty')
```

**Note**: Using `jq`'s `last` ensures that even if multiple comments match, the most recent one is returned, preventing parse errors. `// empty` returns an empty string for null values.

**Purpose of retrieved values:**
- `{comment_id}`: Used when updating the work memory in Phase 1.7.4 and Phase 3.5
- `{comment_body}`: Used for detecting incomplete tasks

**About variable persistence:**

Bash variables (`comment_id`, `comment_body`) are only valid within the shell session. When the LLM (Claude) uses them across multiple Bash invocations, the values are lost. Therefore:

1. The LLM **remembers** the retrieved `comment_id` value **within the conversation context**
2. When updating the work memory in Phase 1.7.4, the remembered value is embedded directly into the command
3. If needed, the value can be re-retrieved in Phase 1.7.4 (by running the same command as in 1.6.1)

If no comment is found (both local file and Issue comment), skip this check and proceed to Phase 2.

#### 1.6.2 Detect Incomplete Tasks

Detect unchecked checkboxes (`- [ ]`) in the "Progress" section of the work memory:

```bash
# 進捗セクションから未完了タスクを抽出
# NOTE: この sed -n は読み取り専用（範囲抽出）目的であり、コメント本文の更新には使用していない
# sed: 「### 進捗」から次の「### 」までの範囲を抽出
# grep: 未完了チェックボックス（- [ ]）を検出
# head -10: 表示量を制限（大量のタスクがある場合の可読性確保）
incomplete_tasks=$(echo "$comment_body" | sed -n '/### 進捗/,/### /p' | grep -E '^\s*- \[ \]' | head -10)
```

**Note**: `sed -n '/### 進捗/,/### /p'` works correctly even when the progress section is at the end of the file (no subsequent `### ` section). In that case, the range from `### 進捗` to EOF is extracted.

#### 1.6.3 Warning When Incomplete Tasks Exist

If incomplete tasks are found, prompt with `AskUserQuestion`:

```
警告: 作業メモリに未完了のタスクがあります

未完了タスク:
{incomplete_tasks}

オプション:
- 未完了タスクを先に完了する（推奨）
- 未完了タスクを自動判定して処理する
- 無視してクリーンアップを続行
- キャンセル
```

**Subsequent processing for each option:**

| Option | Subsequent Processing |
|--------|----------------------|
| **未完了タスクを先に完了する（推奨）** | Interrupt cleanup and prompt user to address incomplete tasks. Guide: "Complete the incomplete tasks and run `/rite:pr:cleanup` again" |
| **未完了タスクを自動判定して処理する** | -> Proceed to Phase 1.7 (automatic assessment and processing of incomplete tasks) |
| **無視してクリーンアップを続行** | Proceed to Phase 2 |
| **キャンセル** | Terminate processing |

#### 1.6.4 When No Incomplete Tasks Exist

If there are no incomplete tasks, proceed to Phase 1.6.5.

#### 1.6.5 Check Issue Body Checklist

In addition to checking the work memory, also check the checklist in the Issue body.

**1.6.5.1 Extract Checklist**

Extract the checklist from the Issue body obtained in Phase 1.5:

```bash
# Issue 本文を取得（既に取得済みの場合は再利用）
gh issue view {issue_number} --json body --jq '.body'
```

**Extraction pattern:**

```
パターン: /^- \[[ xX]\] (.+)$/gm
```

**Exclusion pattern:**

Exclude Tasklist entries containing Issue references (used for parent-child Issue management):

```
パターン: /^- \[[ xX]\] #\d+/gm
```

**1.6.5.2 Detect Incomplete Checklist Items**

Detect incomplete items (`- [ ]`) from the extracted checklist.

**When incomplete items exist:**

```
警告: Issue 本文に未完了のチェック項目があります

未完了項目:
- [ ] {item_1}
- [ ] {item_2}
- [ ] {item_3}

オプション:
- Issue 本文のチェックリストを自動更新（推奨）: PR の変更内容を基に完了状態を判定し、Issue 本文を更新します
- チェックリストを手動で確認: クリーンアップを中断し、手動で確認します
- 無視してクリーンアップを続行: 未完了のままクリーンアップを続行します
- キャンセル
```

**Subsequent processing for each option:**

| Option | Subsequent Processing |
|--------|----------------------|
| **Issue 本文のチェックリストを自動更新（推奨）** | Proceed to Phase 1.6.5.3 |
| **チェックリストを手動で確認** | Guide: "Check the Issue body checklist and re-run `/rite:pr:cleanup`", then terminate |
| **無視してクリーンアップを続行** | Proceed to Phase 2 |
| **キャンセル** | Terminate processing |

**1.6.5.3 Automatic Checklist Update**

Based on PR changes, determine the completion status of incomplete checklist items and update the Issue body.

**Assessment logic:**

The AI assesses the relevance of each checklist item to the PR changes based on the following information:

1. **Checklist item text**: The extracted incomplete items
2. **PR changed files**: Results of `gh pr diff {pr_number} --name-only`
3. **PR change details**: Details from `gh pr diff {pr_number}`

**Assessment example:**

```
チェック項目: 「現在の CLAUDE.md の内容を評価」
PR 変更ファイル: CLAUDE.md
判定: ✅ CLAUDE.md を変更しているため、完了と判断

チェック項目: 「テストを追加」
PR 変更ファイル: src/utils.ts
判定: ⬜ テストファイルへの変更がないため、未完了と判断
```

**Updating the Issue body:**

Follow the "Checkbox Update" pattern in [gh-cli-patterns.md](../../references/gh-cli-patterns.md), executing in 3 steps (Bash -> Read+Write -> Bash).

**Step 1: Bash tool call -- retrieve and validate the body**

```bash
# 一時ファイルを作成（読み取り用・書き込み用）
tmpfile_read=$(mktemp)
tmpfile_write=$(mktemp)
trap 'rm -f "$tmpfile_read" "$tmpfile_write"' EXIT

gh issue view {issue_number} --json body --jq '.body' > "$tmpfile_read"

# 取得結果を検証
if [ ! -s "$tmpfile_read" ]; then
  echo "ERROR: Issue body の取得に失敗" >&2
  exit 1
fi

# mktemp のパスを後続の Read/Write ツールで使うため出力する
echo "tmpfile_read=$tmpfile_read"
echo "tmpfile_write=$tmpfile_write"
```

**Step 2: Read tool + Write tool -- write out the updated body with checkboxes**

1. Read the contents of `$tmpfile_read` (the path output by `mktemp` in step 1) using the Claude Code Read tool
2. Create the full text with `[ ]` -> `[x]` updates based on the read content
3. Write the updated body to `$tmpfile_write` (a separate path output by `mktemp` in step 1) using the Claude Code Write tool

**Step 3: Bash tool call -- validate and apply**

```bash
# 手順1で mktemp が出力したパスを設定（Bash tool call 間ではシェル変数は引き継がれないため、手順1の出力から取得した実際のパスを直接記述する）
tmpfile_read="/tmp/tmp.XXXXXXXXXX"   # ← 手順1の出力 tmpfile_read= の値に置換
tmpfile_write="/tmp/tmp.XXXXXXXXXX"  # ← 手順1の出力 tmpfile_write= の値に置換

# 更新内容を検証してから適用
if [ ! -s "$tmpfile_write" ]; then
  echo "ERROR: 更新内容が空" >&2
  exit 1
fi

gh issue edit {issue_number} --body-file "$tmpfile_write"

# trap は別プロセスに引き継がれないため、明示的に削除
rm -f "$tmpfile_read" "$tmpfile_write"
```

**Displaying the update results:**

```
Issue 本文のチェックリストを更新しました:

完了に更新:
- [x] {item_1}（CLAUDE.md の変更により判定）
- [x] {item_2}（src/utils.ts の変更により判定）

未完了のまま:
- [ ] {item_3}（関連する変更が見つかりませんでした）
```

**When remaining incomplete items exist:**

```
警告: 以下のチェック項目が未完了のままです:

- [ ] {item_3}

オプション:
- 未完了のまま続行: 後続の作業で対応予定として続行
- 別 Issue として登録: 未完了項目を新しい Issue として作成
- キャンセル
```

| Option | Subsequent Processing |
|--------|----------------------|
| **未完了のまま続行** | Proceed to Phase 2 |
| **別 Issue として登録** | Create an Issue by reusing the Phase 1.7.3 Issue creation flow -> Proceed to Phase 2 |
| **キャンセル** | Terminate processing |

**1.6.5.4 When No Checklist Exists**

If the Issue body has no checklist, skip this section and proceed to Phase 2.

---

## Phase 1.7: Automatic Assessment and Processing of Incomplete Tasks

**Prerequisite**: This phase is executed when "Automatically assess and process incomplete tasks" was selected in Phase 1.6.3.

### 1.7.0 Retrieve PR Diff

Before analyzing tasks, retrieve the PR diff to understand the changes:

```bash
# PR の差分を取得（変更ファイル・関数名の確認に使用）
gh pr diff {pr_number}
```

**Purpose of the retrieved diff:**
- Assessing "completed (unchecked)": Check whether changes related to the task are included in the diff
- Issue body generation: Referenced during `{task_details}` generation

### 1.7.1 Analyze Tasks

#### 1.7.1.1 Task Assessment

For each incomplete task, the LLM (Claude) analyzes the task content and assesses it from the following perspectives:

| Assessment Category | Description | Examples |
|--------------------|-------------|----------|
| **Create Issue** | Tasks that should be tracked as remaining implementation work | "Add tests", "Update documentation", "Remove debug logs", "Address TODO comments" |
| **Completed (unchecked)** | Tasks that are actually completed but were not checked off | Forgotten checkmarks in work memory |
| **Difficult to assess** | Tasks the LLM cannot confidently assess | Tasks with ambiguous descriptions ("code cleanup", "improvements", etc.) |

**Targets for Issue creation:**

Issue creation targets **remaining work that could not be completed during implementation**. The following tasks are typical:

- Adding/expanding tests (unit tests, E2E tests, etc.)
- Updating documentation (README, API documentation, etc.)
- Removing debug code (`console.log`, `print` statements added during development)
- Addressing TODO comments (implementing `// TODO:` left in the code)
- Minor refactoring (changes corresponding to XS/S in the complexity table)

**Design principle:**

Incomplete tasks are, in principle, converted to Issues (unless the user selects "ignore"). Reasons:
- Commits to a merged PR branch are not reflected in the base branch
- Changes made during cleanup are lost when the branch is deleted
- Even minor work should be converted to Issues to ensure traceability

#### 1.7.1.2 Assessment Algorithm

The following flow is used to assess each task:

```
1. タスク名を解析
   └─ タスクの作業内容を特定（例: 「テスト追加」「コメント削除」）

2. PR 差分との照合（1.7.0 で取得した差分を使用）
   ├─ タスクに関連する変更が差分に含まれているか検索
   │   ├─ キーワードマッチ: タスク名に含まれる機能・ファイル名を差分から検索
   │   └─ 意味的マッチ: タスクの意図と差分の変更内容が一致するか判断
   │
   ├─ [関連変更あり] → 完了済みの可能性を検討
   │   └─ 差分でタスクが実質的に完了しているか判断
   │       ├─ [完了している] → 「完了済み（チェック漏れ）」
   │       └─ [部分的/未完了] → 「Issue 化」
   │
   └─ [関連変更なし] → 「Issue 化」（未着手のタスク）

3. 判定困難の条件
   以下のいずれかに該当する場合は「判定困難」とする:
   - タスク名が曖昧（例: 「コード整理」「改善」「確認」）
   - 差分との関連性が不明確
   - 複数の解釈が可能
```

**Assessment confidence levels:**

| Confidence | Criteria | Processing |
|-----------|----------|------------|
| **High** | Completion clearly confirmed in the diff | Automatically classified as "completed" |
| **Medium** | Task content is clear and no changes in the diff | Automatically classified as "create Issue" |
| **Low** | All other cases | Classified as "difficult to assess" for user confirmation |

**Analysis perspectives:**

1. **Nature of the task**: Whether the specific work content is clear
2. **Completion status**: Check the PR diff to determine if it is actually completed (possible unchecked)
3. **Complexity**: Refer to the "Complexity Criteria" table below
4. **Priority**: Whether it should be addressed urgently or can be deferred

**Complexity criteria:**

| Complexity | Description | Guidelines |
|-----------|-------------|------------|
| **XS** | 1-line to a few-line changes, simple deletions/additions | Comment removal, log removal, typo fixes |
| **S** | Localized changes within a single file | Function addition, validation addition, simple tests |
| **M** | Changes spanning multiple files | Feature addition, refactoring |
| **L** | Changes involving design modifications | Architecture changes, large-scale refactoring |

**Displaying analysis results:**

```
未完了タスクを分析しました:

Issue 化:
- [ ] テスト追加 → 別途 Issue として管理（複雑度: S）
- [ ] ドキュメント更新 → 別途 Issue として管理（複雑度: XS）
- [ ] デバッグログ削除 → 別途 Issue として管理（複雑度: XS）

完了済み（チェック漏れ）:
- [ ] バリデーション追加 → PR #{pr_number} で実装済み。チェックを付けます

判定困難（確認が必要）:
- [ ] コード整理 → 内容を確認してください
```

**Note**: The confidence levels (high/medium/low) are **internal criteria** used by the LLM when determining assessment categories and are not included in the output to the user. Confidence levels are used only for automatic classification before user confirmation in 1.7.2; the analysis output displays only the assessment category and complexity.

**When assessed as "completed (unchecked)":**

Update the corresponding task in the work memory to `- [x]` and skip Issue creation.

**Update timing:**
- Tasks assessed as "completed (unchecked)" are updated collectively in Phase 1.7.4 (work memory update)
- In the analysis phase (1.7.1), only the assessment results are recorded; no actual updates are performed
- This allows room for the user to correct assessment results during confirmation (1.7.2)

### 1.7.2 User Confirmation

Display the analysis results and prompt with `AskUserQuestion`:

```
上記の分析結果で処理を進めますか？

オプション:
- この分類で Issue 作成（推奨）
- 個別に確認する
- すべて無視してクリーンアップを続行
- キャンセル
```

**Subsequent processing for each option:**

| Option | Subsequent Processing | Description |
|--------|----------------------|-------------|
| **この分類で Issue 作成（推奨）** | If there are difficult-to-assess tasks: 1.7.2.1 -> 1.7.3, otherwise: 1.7.3 | Create Issues based on the analysis results |
| **個別に確認する** | Individual confirmation flow -> 1.7.3 | Confirm each task individually |
| **すべて無視してクリーンアップを続行** | Skip to Phase 2 | Ignore incomplete tasks |
| **キャンセル** | Terminate processing | Interrupt the entire cleanup process and maintain the current state |

**Detailed flow for "Create Issues with this classification":**

If there are difficult-to-assess tasks, resolve them in 1.7.2.1 then proceed to 1.7.3. If none, proceed directly to 1.7.3.

#### 1.7.2.1 Resolving Difficult-to-Assess Tasks

If there are difficult-to-assess tasks, prompt with `AskUserQuestion` for each task **before proceeding to 1.7.3**:

```
「{task_name}」の処理を選択してください:

オプション:
- Issue 化する（推奨）
- 無視する
- キャンセル（後で対応）
```

**Processing for each option:**

| Option | Processing |
|--------|-----------|
| **Issue 化する（推奨）** | Classify the task as "create Issue" and move to the next task |
| **無視する** | Classify the task as "ignore" and move to the next task |
| **キャンセル（後で対応）** | Interrupt incomplete task processing and proceed to Phase 2. Guide: "Re-run `/rite:pr:cleanup` later" |

Repeat until all difficult-to-assess tasks are classified as "create Issue" or "ignore".

**Detailed flow for "Confirm individually":**

Confirm the processing for each task sequentially via `AskUserQuestion`.

**Note**: Tasks assessed as "completed (unchecked)" are not subject to individual confirmation. They are automatically processed as checked in the analysis phase, so individual confirmation targets only "create Issue" or "difficult to assess" tasks.

If the user wants to override a "completed" assessment, they need to manually uncheck it after the work memory update in Phase 1.7.4, or create a separate Issue.

Note that even if the Issue is already closed, editing work memory comments is still possible, so the update in Phase 1.7.4 will execute normally.

**For "create Issue" or "difficult to assess" tasks:**

```
タスク: {task_name}
分析結果: {category}（複雑度: {complexity}）

このタスクの処理を選択してください:

オプション:
- Issue 化する（推奨）
- 無視する
```

Once the processing for all tasks is finalized, proceed to 1.7.3.

### 1.7.3 Convert Tasks to Issues

Create Issues for tasks that were assessed (or confirmed) as "create Issue". Tasks classified as "ignore" are skipped and no Issue is created.

**Handling of "ignored" tasks:**
- The checkbox in the work memory remains as `- [ ]` (incomplete)
- No Issue is created and the task is excluded from tracking
- Design intent: By explicitly leaving tasks that the user deemed "unnecessary" or "will not address", room is left to revisit the decision later
- If `/rite:pr:cleanup` is run again, "ignored" tasks will be detected again

#### 1.7.3.1 Generate Issue Content

For each task, generate an Issue in the following format:

**Placeholder descriptions:**
- `{task_summary}`: A **one-line summary** of the incomplete task extracted from the work memory (e.g., "Add tests", "Remove debug logs"). Used in the overview section. **Note**: Synonymous with `{task_name}`. `{task_name}` is used for the Issue title and `{task_summary}` for the Issue body overview, but the values are identical.
- `{task_details}`: **Specific steps and detailed explanations** needed to execute the incomplete task. Used in the changes section. Generated by the LLM inferring from the following information:
  - **PR diff**: Already retrieved in Phase 1.7.0 (referencing changed files and function names)
  - **Original Issue content**: The body from `gh issue view {issue_number}` retrieved in Phase 1.5, referencing implementation requirements and background
  - **Task name**: The incomplete task text extracted from the work memory

  **Generation quality criteria:**

  The generated `{task_details}` must include **at minimum** the following information:

| Required Item | Description | Example |
|--------------|-------------|---------|
| **Target file** | File path that needs changes | `src/utils.ts` |
| **Target location** | Function name, class name, line number, etc. | `calculateTotal function` |
| **Work content** | Specifically what to do | `Add unit tests` |

  **Generation example:**

  ```markdown
  - `src/utils.ts` の `calculateTotal` 関数にユニットテストを追加する
  - テストケース: 正常系（複数アイテム）、境界値（空配列）、異常系（null 入力）
  - テストファイル: `src/utils.test.ts` に追加
  ```

  **Note**: The LLM generates this by referencing the PR diff retrieved in Phase 1.7.0 and the Issue information retrieved in Phase 1.5.
- `{pr_number}`: The merged PR number (retrieved in Phase 1.2)
- `{original_issue_number}`: The original Issue number (identified in Phase 1.5)
- `{original_issue_title}`: The original Issue title (retrieved in Phase 1.5)
- `{complexity}`: The complexity determined in Phase 1.7.1 task analysis (XS, S, etc.)

**Issue body template:**

```markdown
## 概要

{task_summary}（PR #{pr_number} のマージに伴う残作業）

## 背景・目的

Issue #{original_issue_number} の実装時に完了できなかったタスクです。

## 関連 Issue

- 元 Issue: #{original_issue_number} - {original_issue_title}
- 関連 PR: #{pr_number}

## 変更内容

{task_details}

## 複雑度

{complexity}

## チェックリスト

- [ ] 実装完了
- [ ] テスト追加/更新（必要な場合）
```

#### 1.7.3.2 Create the Issue

> **Reference**: [Issue Creation with Projects Integration](../../references/issue-create-with-projects.md)

Issue creation during cleanup uses the common script directly rather than the interactive `/rite:issue:create`. This skips the interview phase and creates the Issue quickly.

**Note**: The following code block is a template. When Claude executes it, `{generated_body}` should be replaced with the actual Issue body. `cat <<'BODY_EOF'` is a **single-quoted HEREDOC**, so bash variable expansion does not occur. Claude should replace placeholders as an LLM and then construct the command.

**About label configuration:**
- `--label "残作業"`: A label indicating that the Issue was created from an incomplete task
- To avoid errors due to a missing label, it is recommended to create the label before the first run:
  ```bash
  gh label create 残作業 --description "PR マージ後の残作業" --color "fbca04" 2>/dev/null || true
  ```

```bash
tmpfile=$(mktemp)
trap 'rm -f "$tmpfile"' EXIT

cat <<'BODY_EOF' > "$tmpfile"
{generated_body}
BODY_EOF

if [ ! -s "$tmpfile" ]; then
  echo "ERROR: Issue 本文の生成に失敗" >&2
  exit 1
fi

result=$(bash {plugin_root}/scripts/create-issue-with-projects.sh "$(jq -n \
  --arg title "{task_name}（#{original_issue_number} 残作業）" \
  --arg body_file "$tmpfile" \
  --argjson labels '["残作業"]' \
  --argjson projects_enabled {projects_enabled} \
  --argjson project_number {project_number} \
  --arg owner "{owner}" \
  --arg priority "Medium" \
  --arg complexity "{complexity}" \
  --arg iter_mode "none" \
  '{
    issue: { title: $title, body_file: $body_file, labels: $labels },
    projects: {
      enabled: $projects_enabled,
      project_number: $project_number,
      owner: $owner,
      status: "Todo",
      priority: $priority,
      complexity: $complexity,
      iteration: { mode: $iter_mode }
    },
    options: { source: "cleanup", non_blocking_projects: true }
  }'
)")

if [ -z "$result" ]; then
  echo "ERROR: create-issue-with-projects.sh returned empty result" >&2
  exit 1
fi
issue_url=$(printf '%s' "$result" | jq -r '.issue_url')
issue_number=$(printf '%s' "$result" | jq -r '.issue_number')
project_reg=$(printf '%s' "$result" | jq -r '.project_registration')
printf '%s' "$result" | jq -r '.warnings[]' 2>/dev/null | while read -r w; do echo "⚠️ $w"; done
```

**Placeholder descriptions:**
- `{task_name}`: The name of the incomplete task (extracted from the work memory)
- `{original_issue_number}`: The original Issue number (identified in Phase 1.5)
- `{generated_body}`: The Issue body generated in 1.7.3.1
- `{complexity}`: Value determined in Phase 1.7.1

**Note**: If Issue creation or field configuration fails, warnings are displayed from the script result. Since Projects registration is non-blocking, the Issue itself is still created successfully.

**When Projects is not configured:**

If `github.projects.enabled` is `false` or not set in `rite-config.yml`, skip 1.7.3.2.1 entirely.

```
警告: GitHub Projects が設定されていません
Projects への追加をスキップします
```

#### 1.7.3.3 Record Creation Results

Record the information of the created Issue:

```
Issue を作成しました:
- #{new_issue_number} - {task_name}
```

### 1.7.4 Update Work Memory

After all task processing is complete, update the work memory:

```bash
# Step 1: チェックボックス更新（完了済みだがチェック漏れのタスク）
bash {plugin_root}/hooks/issue-comment-wm-sync.sh update \
  --issue {issue_number} \
  --transform update-checkboxes \
  --tasks "{completed_unchecked_task_names_comma_separated}" \
  2>/dev/null || true

# Step 2: 未完了タスク処理結果を追記
task_result_tmp=$(mktemp)
trap 'rm -f "$task_result_tmp"' EXIT
cat > "$task_result_tmp" << 'RESULT_EOF'
{1.7.4 の内容を実際の値で置換して記述}
RESULT_EOF

bash {plugin_root}/hooks/issue-comment-wm-sync.sh update \
  --issue {issue_number} \
  --transform append-section \
  --section "未完了タスクの処理結果" --content-file "$task_result_tmp" \
  2>/dev/null || true

rm -f "$task_result_tmp"
```

**Note for Claude**: `{completed_unchecked_task_names_comma_separated}` を完了済みタスク名のカンマ区切りリストで置換すること（例: `"タスクA,タスクB"`）。`{1.7.4 の内容を実際の値で置換して記述}` を「Update content」テンプレートから生成した実際の追記内容で置換すること。

**Update content:**

While preserving the existing work memory content, **append** the following:

1. **Progress section**: Maintain the existing checklist as-is and add `- [x] 未完了タスク処理済み`
2. **Fix unchecked items**: Update tasks assessed as "completed (unchecked)" to `- [x]`
3. **New section**: Add `### 未完了タスクの処理結果` at the end

**Detailed append positions:**

| Update Target | Append Position | Method |
|--------------|-----------------|--------|
| `- [x] 未完了タスク処理済み` | End of the progress section | Add after the last item in the existing checklist |
| Fix unchecked items | The line of the corresponding task | Replace `- [ ]` with `- [x]` (identify by exact match of task name and line content) |
| `### 未完了タスクの処理結果` | End of the entire work memory | Add as a new section |

**Note**: Method for identifying tasks when the same task name exists multiple times:
1. First, search by exact match of "checkbox + task name" (e.g., `- [ ] テスト追加`)
2. If there are multiple exact matches, identify by order of appearance in the work memory (top to bottom)
3. Example: `- [ ] テスト追加` and `- [ ] テスト追加（API）` are treated as different tasks (the latter targets only lines matching up to and including the text in parentheses)

```markdown
### 進捗
- [x] 実装完了
- [x] PR マージ済み
- [x] バリデーション追加    ← チェック漏れ修正
- [x] 未完了タスク処理済み  ← 新規追加

### 未完了タスクの処理結果
| タスク | 処理 | 結果 |
|-------|------|------|
| テスト追加 | Issue 化 | → #101 |
| デバッグログ削除 | Issue 化 | → #102 |
| バリデーション追加 | チェック完了 | 差分で確認済み |
```

**Note**: `#101`, `#102` above are examples. In practice, the Issue numbers corresponding to each task will be used.

**Format for the "Result" column:**

| Processing | Result Format | Example |
|-----------|--------------|---------|
| Create Issue | `→ #{new_issue_number}` | `→ #101` |
| Check completed | `差分で確認済み` | `差分で確認済み` |
| Ignored | `スキップ` | `スキップ` |

**Note**: If other checklist items exist in the existing progress section, they are preserved and not deleted.

### 1.7.5 Transition to Phase 2

Once all task processing is complete, proceed to Phase 2 (cleanup execution).

**Aggregation method:**

Aggregate the following at the point when Phase 1.7.3 processing is complete:
- `{issue_count}`: Number of tasks for which Issues were created
- `{ignored_count}`: Number of tasks for which "ignore" was selected
- `{checked_count}`: Number of tasks assessed as "completed (unchecked)" and checked off

**Transition confirmation:**

```
未完了タスクの処理が完了しました:
- Issue 化: {issue_count} 件
- チェック完了: {checked_count} 件
- 無視: {ignored_count} 件

クリーンアップを続行します。
```

---

## Phase 2: Cleanup Execution

**Sub-phases** (execute ALL in order — do NOT skip any):

```
2.1 Switch to Default Branch
2.2 Pull Latest Default Branch
2.3 Delete Local Branch
2.4 Check and Delete Remote Branch
```

### 2.1 Switch to Default Branch

If currently on a branch other than the default branch:

```bash
git checkout {base_branch}
```

**If there are uncommitted changes:**

```
警告: 未コミットの変更があります

オプション:
- 変更をスタッシュしてクリーンアップ続行
- キャンセル
```

If stash is selected:

```bash
git stash push -m "rite-cleanup: auto-stash before cleanup"
```

### 2.2 Pull Latest Default Branch

```bash
git pull origin {base_branch}
```

**If a conflict occurs:**

```
エラー: デフォルトブランチの更新中にコンフリクトが発生しました

対処:
1. `git status` で状態を確認
2. コンフリクトを解決
3. 再度クリーンアップを実行
```

Terminate processing.

### 2.3 Delete Local Branch

```bash
git branch -d {branch_name}
```

**If deletion fails (unmerged changes exist):**

```
警告: ブランチ {branch_name} には未マージの変更があります

オプション:
- 強制削除（-D オプション）
- スキップ
```

If force delete is selected:

```bash
git branch -D {branch_name}
```

### 2.4 Check and Delete Remote Branch

Check if the remote branch exists:

```bash
git ls-remote --heads origin {branch_name}
```

**If the remote branch exists:**

```bash
git push origin --delete {branch_name}
```

**Note**: If GitHub is configured to automatically delete branches on PR merge, the branch may already be deleted.
Ignore remote branch deletion errors and proceed to Phase 3.

---

## Phase 3: Projects Status Update

> See [references/archive-procedures.md](./references/archive-procedures.md) for the full archive procedures: Projects Status Update (3.1-3.4), Work Memory final update (3.5), Issue close (3.6), Parent Issue handling (3.6.4, 3.7), and State reset (Phase 4).

---

## Phase 5: Completion Report

### 5.1 Cleanup Result Summary

```
クリーンアップが完了しました

PR: #{pr_number} - {pr_title}
関連 Issue: #{issue_number}
Status: {projects_status_result}

実行した処理:
- [x] デフォルトブランチに切り替え
- [x] 最新のデフォルトブランチを pull
- [x] ローカルブランチ {branch_name} を削除
- [x] リモートブランチを削除
- [x] .rite-flow-state をリセット
- [{projects_check}] Projects Status を Done に更新
- [x] 作業メモリを最終更新
- [x] 関連 Issue をクローズ
- [x] 親 Issue の Tasklist チェックボックスを更新（該当する場合）
- [x] 親 Issue の自動クローズ（該当する場合）
- [x] ローカル作業メモリを削除（該当する場合）
```

**Projects Status update result display rules:**

| `projects_status_updated` | `{projects_status_result}` | `{projects_check}` |
|---------------------------|---------------------------|---------------------|
| `true` | `Done` | `x` |
| `false` | `⚠️ 更新失敗（手動確認が必要）` | ` ` (space) |

When `projects_status_updated` is `false`, append the following after the checklist:

```
⚠️ Projects Status の更新に失敗しました。手動で更新してください:
GitHub Projects 画面で Issue #{issue_number} の Status を "Done" に変更
```

**Parent Issue close result (displayed only when Phase 3.7 was executed):**

```
親 Issue 処理:
- 親 Issue: #{parent_issue_number} - {parent_issue_title}
- 結果: {parent_close_result}
```

**Values for `{parent_close_result}`:**

| State | Display Value |
|-------|--------------|
| Auto-close succeeded | `✅ 自動クローズ完了（全子 Issue 完了）` |
| Remaining child Issues | `⏳ 残り {remaining_count} 件の子 Issue が未完了` |
| Already closed | `✅ 既にクローズ済み` |
| Error occurred | `⚠️ クローズ失敗（手動対応が必要）` |

**Incomplete task processing results (displayed only when Phase 1.7 was executed):**

```
未完了タスク処理:
- Issue 化: {issue_count} 件
- チェック完了: {checked_count} 件
- 無視: {ignored_count} 件

作成した Issue:
| Issue | タイトル |
|-------|----------|
| #{new_issue_number} | {task_name}（#{original_issue_number} 残作業） |
```

**Placeholder relationships:**
- `{new_issue_number}`: The number of the new Issue created in Phase 1.7.3.2
- `{task_name}`: The name of the incomplete task extracted from the work memory (base for the Issue title)
- `{original_issue_number}`: The original Issue number (identified in Phase 1.5)

**If there are stashed changes:**

```
スタッシュした変更を復元しますか？

オプション:
- 復元する（git stash pop）
- 後で手動で復元する
```

If restore is selected:

```bash
git stash pop
```

### 5.2 Guidance for Next Steps

```
次のステップ:
1. `/rite:issue:list` で次の Issue を確認
2. `/rite:issue:start <issue_number>` で新しい作業を開始
```

---

## Error Handling

See [Common Error Handling](../../references/common-error-handling.md) for shared patterns (Not Found, Permission, Network errors).

| Error | Recovery |
|-------|----------|
| PR Not Found | See [common patterns](../../references/common-error-handling.md) |
| Branch Deletion Failure | `git branch` でブランチ一覧を確認; デフォルトブランチに切り替えてから再実行 |
| Network Error | See [common patterns](../../references/common-error-handling.md) |
| Issue Not Found | See [common patterns](../../references/common-error-handling.md) |
| Issue Close Failure | `gh issue view {issue_number}` で Issue の状態を確認; 手動で `gh issue close {issue_number}` を実行 |
| Incomplete Task Issue Creation Failure | クリーンアップは続行します; 以下のタスクを手動で Issue 化してください: |
