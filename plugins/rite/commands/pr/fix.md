---
description: レビュー指摘への対応を支援
context: fork
---

# /rite:pr:fix

## Contract
**Input**: PR number, review findings from `/rite:pr:review`, `.rite-flow-state` with `phase: phase5_fix` (e2e flow)
**Output**: `[fix:pushed]` | `[fix:issues-created:{n}]` | `[fix:replied-only]` | `[fix:error]`

Retrieve and organize PR review comments to efficiently assist with addressing review feedback

## E2E Output Minimization

When called from the `/rite:issue:start` end-to-end flow, minimize output to reduce context window consumption:

| Phase | Standalone | E2E Flow |
|-------|-----------|----------|
| Fix implementation | Full output | Full output (needed for code changes) |
| Phase 7 (Completion) | Full report | Result pattern + 1-line summary only |
| Phase 8 (Work Memory) | Full update | Full update (no change) |

**E2E output format** (Phase 7, replaces full report):
```
[fix:{result}] — {fixed_count} fixed, {deferred_count} deferred, {files_changed} files changed
```

**Detection**: Reuse Phase 0.1 end-to-end flow determination.

---

Execute the following phases in order when this command is run.

**⚠️ Integration with `/rite:issue:start`:**

This command is automatically invoked within the review-fix loop of `/rite:issue:start` when the evaluation results in "not mergeable (issues found)" or "needs fixes". Based on the graduated relaxation gate tied to loop count (`review.loop` settings in `rite-config.yml`), **only blocking issues are targeted for fixes**, while non-blocking issues are automatically deferred and converted to separate Issues. After completion, this command outputs a machine-readable output pattern and **returns control to the caller** (`/rite:issue:start`).

## Arguments

| Argument | Description |
|----------|-------------|
| `[pr_number]` | PR number (defaults to the PR for the current branch if omitted) |

---

## Phase 0: Load Work Memory (During End-to-End Flow)

When executed within the end-to-end flow, load required information from work memory (shared memory).

### 0.1 Determine End-to-End Flow

Determine the caller from the conversation context:

| Condition | Determination | Action |
|-----------|---------------|--------|
| Conversation history contains rich context from `/rite:pr:review` | Within end-to-end flow (review-fix loop) | PR number can be obtained from conversation context |
| `/rite:pr:fix` was executed standalone | Standalone execution | Obtain from argument or current branch PR |

### 0.2 Load Work Memory

Extract the Issue number from the current branch and retrieve work memory:

```bash
# ブランチ名から Issue 番号を抽出
issue_number=$(git branch --show-current | grep -oE 'issue-[0-9]+' | grep -oE '[0-9]+')

# リポジトリ情報を取得（1回で owner と repo を両方取得）
# 注: echo ... | jq -r はスタンドアロン jq コマンドに依存（GitHub CLI の --jq オプションとは別）
owner_repo=$(gh repo view --json owner,name --jq '{owner: .owner.login, repo: .name}')
owner=$(echo "$owner_repo" | jq -r '.owner')
repo=$(echo "$owner_repo" | jq -r '.repo')

# 作業メモリを取得
gh api repos/{owner}/{repo}/issues/{issue_number}/comments \
  --jq '.[] | select(.body | contains("📜 rite 作業メモリ")) | .body'
```

### 0.3 Information to Retrieve

Extract the following information from work memory and retain in context:

| Field | Extraction Pattern | Purpose |
|-------|-------------------|---------|
| Issue number | `issue-(\d+)` from branch name | Work memory update |
| PR number | `- **番号**: #(\d+)` | Retrieve review comments |
| Phase | `- **フェーズ**: (.+)` | Confirm flow position |
| Review result | `### レビュー対応履歴` section | Check previous state |

**For standalone execution:**
- If no PR number is specified as an argument, obtain from the current branch's PR
- The "related PR" section in work memory can also be referenced

---

## Phase 1: Retrieve and Organize Review Comments

### 1.1 Identify the PR

Retrieve repository information:

- **Within end-to-end flow**: `{owner}` and `{repo}` are already available from Phase 0.2. Reuse them — no additional `gh repo view` call needed.
- **Standalone execution**: Phase 0 was not executed. Retrieve them here:

```bash
# Phase 0.2 と同一パターン（スタンドアロン実行時のみ使用。e2e フローでは Phase 0.2 の値を再利用）
owner_repo=$(gh repo view --json owner,name --jq '{owner: .owner.login, repo: .name}')
owner=$(echo "$owner_repo" | jq -r '.owner')
repo=$(echo "$owner_repo" | jq -r '.repo')
```

When PR number is specified as an argument:

```bash
gh pr view {pr_number} --json number,title,state,isDraft,headRefName,baseRefName,url,body
```

When argument is omitted, identify the PR from the current branch:

```bash
git branch --show-current
gh pr view --json number,title,state,isDraft,headRefName,baseRefName,url,body
```

**When PR is not found:**

```
エラー: 現在のブランチに関連する PR が見つかりません

現在のブランチ: {branch}

対処:
1. `/rite:pr:create` で PR を作成
2. PR 番号を直接指定して再実行
```

Terminate processing.

**When PR is closed or already merged:**

```
エラー: PR #{number} は既に{state}されています

レビュー指摘への対応は実行できません。
```

Terminate processing.

### 1.2 Retrieve Review Comments

Retrieve PR review comments:

```bash
# レビューコメント（PR レビューに紐づくコメント）
# node_id はスレッド解決時の GraphQL mutation で必要
gh api repos/{owner}/{repo}/pulls/{pr_number}/comments --jq '.[] | {id, node_id, path, line, original_line, body, user: .user.login, created_at, in_reply_to_id, pull_request_review_id}'

# PR レビュー自体のコメント
gh api repos/{owner}/{repo}/pulls/{pr_number}/reviews --jq '.[] | {id, node_id, state, body, user: .user.login, submitted_at}'

# 通常のコメント（PR コメント欄）を一括取得して保存（Phase 1.2.1 で再利用）
pr_comments=$(gh pr view {pr_number} --json comments --jq '.comments')
echo "$pr_comments" | jq '.[] | {id: .id, body: .body, author: .author.login, createdAt: .createdAt}'
```

**Implementation note for Claude**: `$pr_comments` はシェル変数ではなく、**会話コンテキスト内で保持するデータ**として扱うこと。Claude Code が各 bash コードブロックを個別の Bash ツール呼び出しで実行する場合、シェル変数はブロック間で引き継がれない。Phase 1.2.1 では、この値をコンテキストから読み直すか、Phase 1.2 のコードブロックと Phase 1.2.1 のコードブロックを単一の Bash ツール呼び出しとして結合して実行すること。

```bash
# スレッド情報と解決状態を取得（GraphQL）
# 注: first: 100 の制限があるため、100件を超える大規模 PR では取得漏れの可能性あり
gh api graphql -f query='
query($owner: String!, $repo: String!, $pr: Int!) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $pr) {
      reviewThreads(first: 100) {
        nodes {
          id
          isResolved
          comments(first: 100) {
            nodes {
              id
              body
              author { login }
              path
              line
            }
          }
        }
      }
    }
  }
}' -f owner="{owner}" -f repo="{repo}" -F pr={pr_number}
```

### 1.2.1 Retrieve rite Review Results

Retrieve the `/rite:pr:review` results from PR comments and extract severity information:

1. Search PR comments for those containing `## 📜 rite レビュー結果`
2. Parse the tables for each reviewer type within the "all findings" section
3. Extract the severity (CRITICAL/HIGH/MEDIUM/LOW) for each finding
4. Map severity using file:line as the key

**Search method:**

```bash
# Phase 1.2 で取得済みの pr_comments から rite レビュー結果を検索（API 呼び出しなし）
# 注: $pr_comments はコンテキスト保持データ。Phase 1.2 と同一 Bash ツール呼び出しで実行するか、
#     コンテキストから値を再注入すること（各 bash ブロックを個別に実行する場合、シェル変数は引き継がれない）
echo "$pr_comments" | jq '[.[] | select(.body | contains("## 📜 rite レビュー結果"))] | sort_by(.createdAt) | last | {id: .id, body: .body, author: .author.login, createdAt: .createdAt}'
```

**Note**: When multiple rite review result comments exist (when review has been run multiple times), use the one with the most recent `createdAt`.

**Parsing the Markdown table:**

The rite review result comment (output format of `/rite:pr:review`) has the following structure:

```markdown
## 📜 rite レビュー結果

### 総合評価
- **推奨**: {マージ可 / 条件付きマージ可 / 修正必要}

### 全指摘事項

#### {Reviewer Type}
- **評価**: {可 / 条件付き / 要修正}

| 重要度 | ファイル:行 | 内容 | 推奨対応 |
|--------|------------|------|----------|
| CRITICAL | src/auth.ts:42 | エラーハンドリングが不足 | try-catch を追加 |
```

**Parsing algorithm:**

1. Identify the `### 全指摘事項` section from the comment body
2. Iterate through each reviewer section delimited by `#### {Reviewer Type}`
3. Parse the table rows within each section (split by `|`)
4. Extract severity (column 1), file:line (column 2), content (column 3), recommended action (column 4)
5. Retain as `severity_map` (consolidating findings from all reviewers):
   ```
   severity_map = {
     "src/auth.ts:42": "CRITICAL",
     "src/api.ts:18": "HIGH",
     "src/utils.ts:55": "MEDIUM",
     "src/config.ts:10": "LOW"
   }
   ```

**Note**: When multiple reviewers have flagged the same file:line, adopt the highest severity (CRITICAL > HIGH > MEDIUM > LOW).

**When rite review results are not found:**

When no rite review results exist in PR comments (manual review only, or `/rite:pr:review` was not run):
- Continue processing with an empty `severity_map`
- Phase 1.3 falls back to GitHub state-based classification

### 1.3 Classify Comments

Perform severity-based classification using the `severity_map` obtained in Phase 1.2.1.

**Classification table:**

| Classification | Criteria | Action |
|---------------|----------|--------|
| **Required fix** | CRITICAL/HIGH | Must fix |
| **Needs fix** | MEDIUM/LOW | Fix or separate Issue (action required) |
| **External review** | Findings from human reviewers | Action required |
| **Resolved** | Resolved threads | - |

**Classification logic:**

1. Thread is resolved (`isResolved: true`) -> Resolved (processing complete)
2. Contains only `LGTM`, `+1`, `👍`, etc. -> Informational (no action needed)
3. Check if the finding's file:line exists in `severity_map`
4. If it exists, classify based on severity:
   - `CRITICAL` or `HIGH` -> Required fix
   - `MEDIUM` or `LOW` -> Needs fix
5. Unresolved comments not in `severity_map` -> External review

**Mapping method with `severity_map`:**

Map GitHub review comments (REST API) with rite review results (Markdown table) using:

| Mapping Condition | Determination Method |
|-------------------|---------------------|
| **Exact match of file path and line number** | GitHub review comment's `path:line` matches the `severity_map` key |
| **Approximate line number match (+-3 lines)** | If no exact match, attempt approximate match within +-3 lines |

**Fallback (when `severity_map` is empty):**

When rite review results were not found, use conventional GitHub state-based classification:

| Classification | Criteria |
|---------------|----------|
| **Unaddressed (needs fix)** | `CHANGES_REQUESTED` in review or unresolved threads |
| **Unaddressed (suggestion)** | Improvement suggestions or questions without replies |
| **Resolved** | Resolved threads or replied |
| **Informational** | FYI, supplementary explanations, no action needed |

### 1.4 Display Comment List

**Behavior branching based on caller:**

| Caller | Option Selection | Target |
|--------|-----------------|--------|
| Within `/rite:issue:start` review-fix loop | **Skip** (auto-select) | Blocking issues + external reviews. Non-blocking auto-deferred |
| Manual `/rite:pr:fix` | Display | User-selected |

> **Automatic target selection**: See [Graduated Relaxation Rules](./references/fix-relaxation-rules.md) for gate mode logic and fix target classification by loop count

---

```
PR #{number} のレビューコメント

## 未対応の指摘 ({count}件)

### 必須修正（CRITICAL/HIGH）({count}件)
| # | 重要度 | ファイル | 行 | 指摘内容 | レビュアー |
|---|--------|----------|-----|----------|------------|
| 1 | {severity} | {path} | {line} | {body_preview} | @{user} |

### 要修正（MEDIUM/LOW）({count}件)
| # | 重要度 | ファイル | 行 | 指摘内容 | レビュアー |
|---|--------|----------|-----|----------|------------|
| 1 | {severity} | {path} | {line} | {body_preview} | @{user} |

### 外部レビュー({count}件)
| # | ファイル | 行 | 内容 | レビュアー |
|---|----------|-----|------|------------|
| 1 | {path} | {line} | {body_preview} | @{user} |

## 対応済み ({count}件)
{resolved_count} 件の指摘が解決済みです

---

対応を開始しますか？

オプション:
- すべての指摘に対応（推奨）
- CRITICAL/HIGH のみ対応
- 特定の指摘を選択
- キャンセル
```

**Option descriptions:**

| Option | Target | Use Case |
|--------|--------|----------|
| **すべての指摘に対応（推奨）** | All severities + external reviews | When full resolution is needed. Within `/rite:issue:start` loop, blocking issues are auto-selected based on gate mode |
| **CRITICAL/HIGH のみ対応** | CRITICAL + HIGH only | When addressing only urgent issues and deferring MEDIUM/LOW |
| **特定の指摘を選択** | Individual selection | When addressing only specific findings |
| **キャンセル** | - | Abort the process |

**When there are no comments:**

```
PR #{number} にはレビューコメントがありません

考えられる状況:
- まだレビューが実施されていない
- すべての指摘が解決済み

次のステップ:
- `/rite:pr:review` でセルフレビューを実行
- `/rite:pr:ready` でレビュー待ちに変更
```

Terminate processing.

---

## Phase 2: Assist with Fixes

### 2.1 Confirm Fix Approach

Confirm the fix approach for each finding:

```
指摘 #{n}: {file}:{line}

レビュアー: @{user}
内容:
{comment_body}

この指摘への対応方針を選択してください:

オプション:
- コードを修正する
- 説明・返信のみ（修正不要）
- スキップ（後で対応）
```

**When "スキップ（後で対応）" is selected:**

Prompt for skip reason:

```
スキップする理由を入力してください:

オプション:
- スコープ外（別 Issue 対応）
- 後日対応
- 理由を入力（Other を選択）
```

**Note**: The entered `skip_reason` is used in Phase 4.3 for determining separate Issue candidates.

### 2.2 Identify Fix Location

When "コードを修正する" is selected:

1. Read the target file using Read tool
2. Display lines around the flagged location
3. Propose a fix

```
修正対象:
ファイル: {path}
行: {line}

現在のコード:
（{lang} のコードブロックで表示）
{code_context}

指摘内容:
{comment_body}

修正案を検討しています...
```

### 2.3 Apply the Fix

Present the proposed fix and apply with Edit tool after confirmation:

```
修正案:
（{lang} のコードブロックで表示）
{suggested_fix}

この修正を適用しますか？

オプション:
- 適用する
- 修正案を変更
- スキップ
```

### 2.4 Create Reply (Optional)

After completing the fix, propose a reply to the reviewer:

```
レビュアーへの返信を作成しますか？

提案される返信:
> {original_comment_preview}

修正しました。{brief_explanation}

オプション:
- この返信を投稿
- 返信を編集
- 返信しない
```

When posting the reply:

**Note**: The following code block is a template. When Claude executes it, `{reply_body}` should be replaced with the actual reply content. `cat <<'REPLYEOF'` is a **single-quoted HEREDOC**, so bash variable expansion does not occur. Claude should replace the placeholder as an LLM and then construct the command.

```bash
# PR レビューコメントへの返信（in_reply_to で元コメントを指定）
# jq --rawfile で安全に JSON を生成し、gh api に渡す
tmpfile=$(mktemp)
trap 'rm -f "$tmpfile"' EXIT
cat <<'REPLYEOF' > "$tmpfile"
{reply_body}
REPLYEOF
jq -n --rawfile body "$tmpfile" --argjson in_reply_to "$comment_id" \
  '{"body": $body, "in_reply_to": $in_reply_to}' | gh api repos/{owner}/{repo}/pulls/{pr_number}/comments \
  -X POST \
  --input -
```

**Implementation note for Claude**: When Claude generates commands, write the reply content to a temporary file via `mktemp` + HEREDOC, then use `jq -n --rawfile body "$tmpfile"` to safely construct the JSON payload. Use the REST API numeric ID directly for `$comment_id` via `--argjson`. `jq --rawfile` reads the file as a raw string and handles all JSON escaping automatically.

---

## Phase 3: Fix Commit

### 3.1 Verify Changes

Once all findings have been addressed, verify the changes:

```bash
git status
git diff
```

```
修正内容の確認

変更ファイル:
| ファイル | 変更内容 |
|----------|----------|
| {path} | {change_summary} |

対応した指摘: {count}件
```

### 3.2 Generate Commit Message

Generate a commit message based on the addressed findings.

**Commit message language:**

Before generating the commit message, check the `language` field in `rite-config.yml` using the Read tool to determine the language:

| Setting | Behavior |
|---------|----------|
| `auto` | Detect the user's input language and generate in the same language |
| `ja` | Generate commit message in Japanese |
| `en` | Generate commit message in English |

**Language determination logic for `auto` setting:**

1. **Determination timing**: At commit message generation time, detect the most recent user input
2. **Determination method**: Determine by the following priority

| Priority | Condition | Result |
|----------|-----------|--------|
| 1 | Contains Japanese characters (hiragana, katakana, kanji) | Japanese |
| 2 | Otherwise | English |

> **⚠️ CRITICAL**: The `description` part of the commit message **MUST** follow the `language` setting in `rite-config.yml`. The examples below are for reference only — always generate the description in the language determined by the setting, not by copying the example language. The commit body and trailer also follow the same language setting.

**Examples by language:**

| Language setting | Commit message example |
|-----------------|----------------------|
| `en` or `auto` (English input) | `fix(review): address review feedback` |
| `ja` or `auto` (Japanese input) | `fix(review): レビュー指摘に対応` |

**Commit body:**

> **Reference**: [Contextual Commits Reference](../../skills/rite-workflow/references/contextual-commits.md) for action line specification, mapping tables, output rules, and scope derivation.

Check `commit.contextual` in `rite-config.yml` to determine the commit body format.

**When `commit.contextual: true` (default):**

Generate structured action lines in the commit body following the Contextual Commits format. Review-fix commits are rich in decisions, making action lines particularly valuable.

- Leave a blank line between the description line and the action lines
- Can be omitted for trivial changes (typo fixes, formatting, etc.)

**Generation procedure:**

1. **Read review findings**: Extract from the review findings being addressed — the review指摘 and chosen対応方針 are the primary source for `decision` (Priority 1 — highest reliability for review-fix commits)
2. **Read work memory**: Extract from `決定事項・メモ`, `計画逸脱ログ`, `要確認事項` sections (Priority 2)
3. **Infer from diff**: When the diff shows clear technical choices, infer `decision` (Priority 3 — use only when evident)
4. **Apply review-fix mapping table**: Map each extracted item to action types using the [Review-Fix Commit Mapping](../../skills/rite-workflow/references/contextual-commits.md#review-fix-commit-mapping-prfixmd) table:
   - レビュー指摘の対応方針 → `decision(scope)`
   - 対応しなかった指摘とその理由 → `rejected(scope)`
   - 対応中に発見した制約 → `constraint(scope)`
   - 対応中の発見事項 → `learned(scope)`
5. **Filter to 10-line limit**: If action lines exceed 10, trim in order: `learned` → `constraint` → `rejected` → `decision` → `intent` (intent is preserved last as the core "why")

**Output rules:**
- Action type names are always in English (`intent`, `decision`, `rejected`, `constraint`, `learned`)
- Description follows the `language` setting in `rite-config.yml`
- Do not repeat information already visible in the diff
- Do not fabricate action lines without evidence from review findings, work memory, or diff

**Example (language: ja):**

```
fix(review): レビュー指摘に対応

decision(validation): 入力バリデーションを追加（レビュー指摘: 未検証の入力がエラーを引き起こす可能性）
rejected(refactor): ハンドラー全体のリファクタリングは見送り — スコープ外、別 Issue で対応
learned(error-handling): エラーレスポンスのフォーマットは既存の middleware と統一する必要あり
```

**When `commit.contextual: false`:**

Use free-form commit body. Include the reason for the change ("why") in the commit body.

- Leave a blank line between the description line and the body
- Write in free-form — no specific prefix or template required
- Focus on "why" the change was needed, not "what" was changed (the description line already covers "what")
- Follow the same language setting as the description line
- Can be omitted for trivial changes (typo fixes, formatting, etc.)

**Trailer**: Generate in the configured language:
- English: `Addresses review comments from @{reviewer1}, @{reviewer2}`
- Japanese: `@{reviewer1}, @{reviewer2} のレビューコメントに対応`

```
コミットメッセージ案:

fix(review): {description}

{action_lines (when commit.contextual: true)}

{trailer}

このメッセージでコミットしますか？

オプション:
- このメッセージでコミット
- メッセージを編集
- 個別にコミット（複数コミットに分割）
```

### 3.3 Execute the Commit

```bash
git add {changed_files}
git commit -m "$(cat <<'EOF'
{commit_message}
EOF
)"
```

### 3.4 Confirm Push

```
変更をリモートにプッシュしますか？

オプション:
- プッシュする（推奨）
- 後でプッシュ
```

When pushing:

```bash
git push
```

---

## Phase 4: Report Completion

### 4.1 Resolve Threads (Optional)

Confirm whether to resolve addressed threads:

```
対応したスレッドを解決済みにしますか？

対象: {count}件のスレッド

オプション:
- すべて解決済みにする
- 個別に選択
- スキップ（レビュアーに任せる）（推奨）

**注**: 多くのチームではレビュアーがスレッドを解決する慣習があります。
```

When resolving threads (GraphQL mutation):

```bash
# 注: thread_id は GraphQL の Node ID を使用（Phase 1.2 で取得した reviewThreads.nodes[].id）
gh api graphql -f query='
mutation($threadId: ID!) {
  resolveReviewThread(input: {threadId: $threadId}) {
    thread {
      isResolved
    }
  }
}' -f threadId="{thread_id}"
```

**When thread resolution fails:**

```
警告: スレッド {thread_id} の解決に失敗しました

考えられる原因:
- スレッドが既に解決済み
- 権限不足（レビュアーまたは PR 作成者のみ解決可能な場合）
- ネットワークエラー

オプション:
- この失敗を無視して続行
- 手動で解決（GitHub UI で操作）
- キャンセル
```

### 4.2 Report via PR Comment (Optional)

Confirm whether to report completion via PR comment:

```
レビュー指摘への対応を PR コメントで報告しますか？

報告内容案:
---
## レビュー指摘対応完了

以下の指摘に対応しました:

| 指摘 | 対応内容 |
|------|----------|
| {comment_preview} | {response_summary} |

コミット: {commit_sha}

ご確認をお願いします。
---

オプション:
- 報告を投稿
- 報告を編集
- スキップ
```

When posting the report:

```bash
# ✅ SAFE: --body-file for dynamic report content
tmpfile=$(mktemp)
trap 'rm -f "$tmpfile"' EXIT
cat <<'REPORT_EOF' > "$tmpfile"
{report_body}
REPORT_EOF
gh pr comment {pr_number} --body-file "$tmpfile"
```

### 4.3 Automatic Separate Issue Creation (Required)

**⚠️ Important**: The following findings **must** be created as separate Issues. This is a required step to satisfy the loop termination condition of `/rite:issue:start`.

- Findings where "スキップ（後で対応）" was selected in Phase 2.1
- Non-blocking findings **auto-deferred** by the graduated relaxation gate in Phase 1.4

#### 4.3.1 Collect Separate Issue Candidates

Collect **all** of the following findings as separate Issue candidates:

| Condition | Description |
|-----------|-------------|
| **Manual skip** | "スキップ（後で対応）" was selected in Phase 2.1 |
| **Auto defer** | Finding was treated as non-blocking by the graduated relaxation gate in Phase 1.4 |

**Note**: Collect all skipped/deferred findings regardless of severity or skip reason. This guarantees no unaddressed findings remain.

#### 4.3.2 When No Candidates Exist

If the collection result is 0 items (all findings addressed), skip this step and proceed to 4.5.

#### 4.3.3 Confirm Separate Issue Creation

When there are 1 or more candidates, behavior differs based on the caller:

| Condition | Determination |
|-----------|---------------|
| Conversation history contains context from `/rite:issue:start` Phase 5 "review-fix loop" | Within loop -> Skip confirmation and auto-create Issues |
| Conversation history has a record of `rite:pr:fix` being called via `Skill tool` | Within loop -> Skip confirmation and auto-create Issues |
| Otherwise (user directly entered `/rite:pr:fix`) | Manual execution -> Confirm with `AskUserQuestion` |

---

**When called from within the `/rite:issue:start` loop:**

Automatically create Issues for all skipped findings without confirmation.

```
スキップされた指摘を別 Issue として自動作成します

{count} 件の指摘が別 Issue として作成されます:

| # | ファイル | 内容 | 重要度 | スキップ理由 |
|---|----------|------|--------|-------------|
| 1 | {file_line} | {content_preview} | {severity} | {skip_reason} |

Issue を作成中...
```

**Reason**: In the review-fix loop, the loop continues until all findings are "addressed" (fixed, replied to, or converted to Issues). If skipped findings are not converted to Issues, the loop termination condition cannot be met.

---

**When `/rite:pr:fix` is executed manually:**

Confirm with `AskUserQuestion`:

```
スキップされた指摘を別 Issue として管理します

{count} 件の指摘が別 Issue として作成されます:

| # | ファイル | 内容 | 重要度 | スキップ理由 |
|---|----------|------|--------|-------------|
| 1 | {file_line} | {content_preview} | {severity} | {skip_reason} |

オプション:
- すべて Issue 化する（推奨）: すべての指摘を別 Issue として作成
- キャンセル: Issue 作成を中止
```

#### 4.3.4 Create Issues

Create Issues directly using `gh issue create` and register them in GitHub Projects. Do **not** use the `/rite:issue:create` Skill tool.

**Step 1: Generate Issue title**

Generate the Issue title in the following format:

```
{type}: {summary}
```

| Element | Generation Method |
|---------|-------------------|
| `{type}` | Inferred from the original finding content (`fix`, `feat`, `refactor`, `docs`, etc.) |
| `{summary}` | Summarize the original finding's `description` (50 characters or less, starting with a verb) |

**Step 2: Create Issue via Common Script**

> **Reference**: [Issue Creation with Projects Integration](../../references/issue-create-with-projects.md)

**Note**: The heredoc below contains `{placeholder}` markers. Claude substitutes these with actual values **before** generating the bash script — they are not shell variables.

**Important**: The entire script block must be executed in a **single Bash tool invocation**.

**Priority mapping**: `緊急`/`重大`/`urgent`/`critical` in skip reason → High, all others → Medium

**Complexity mapping**: XS: single-line/single-location fix. S: multi-line change within 1-2 files

**Placeholder value sources** (Claude はスクリプト生成前に必ず以下のソースから値を取得し、プレースホルダーを置換すること):

| Placeholder | Source | Example |
|-------------|--------|---------|
| `{projects_enabled}` | `rite-config.yml` → `github.projects.enabled` | `true` |
| `{project_number}` | `rite-config.yml` → `github.projects.project_number` | `6` |
| `{owner}` | `rite-config.yml` → `github.projects.owner` | `B16B1RD` |
| `{iteration_mode}` | `rite-config.yml` → `iteration.enabled` が `true` かつ `iteration.auto_assign` が `true` なら `"auto"`、それ以外は `"none"` | `"none"` |
| `{plugin_root}` | [Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script) | `/home/user/.claude/plugins/rite` |

**⚠️ Projects 登録失敗時の警告表示（必須）**: スクリプト実行後、`project_registration` の値を必ず確認し、`"partial"` または `"failed"` の場合は以下を表示すること:

```
⚠️ Projects 登録が完全に完了しませんでした（status: {project_registration}）
手動登録: gh project item-add {project_number} --owner {owner} --url {created_issue_url}
```

```bash
tmpfile=$(mktemp)
trap 'rm -f "$tmpfile"' EXIT

cat <<'BODY_EOF' > "$tmpfile"
## 概要

{description}

## 背景

この Issue は PR #{pr_number} のレビュー指摘対応中に作成されました。

### 元のレビュー指摘
- **ファイル**: {file}:{line}
- **レビュアー**: @{reviewer}
- **指摘内容**: {original_comment}

### 別 Issue 化の理由
{skip_reason}

## 関連

- 元の PR: #{pr_number}
BODY_EOF

if [ ! -s "$tmpfile" ]; then
  echo "ERROR: Issue 本文の生成に失敗" >&2
  exit 1
fi

result=$(bash {plugin_root}/scripts/create-issue-with-projects.sh "$(jq -n \
  --arg title "{type}: {summary}" \
  --arg body_file "$tmpfile" \
  --argjson projects_enabled {projects_enabled} \
  --argjson project_number {project_number} \
  --arg owner "{owner}" \
  --arg priority "{priority}" \
  --arg complexity "{complexity}" \
  --arg iter_mode "{iteration_mode}" \
  '{
    issue: { title: $title, body_file: $body_file },
    projects: {
      enabled: $projects_enabled,
      project_number: $project_number,
      owner: $owner,
      status: "Todo",
      priority: $priority,
      complexity: $complexity,
      iteration: { mode: $iter_mode }
    },
    options: { source: "pr_fix", non_blocking_projects: true }
  }'
)")

if [ -z "$result" ]; then
  echo "ERROR: create-issue-with-projects.sh returned empty result" >&2
  exit 1
fi
created_issue_url=$(printf '%s' "$result" | jq -r '.issue_url')
project_reg=$(printf '%s' "$result" | jq -r '.project_registration')
printf '%s' "$result" | jq -r '.warnings[]' 2>/dev/null | while read -r w; do echo "⚠️ $w"; done
```

**Error handling:**

| Error Case | Response |
|------------|----------|
| Script returns `issue_url: ""` | Display warning with error details. If remaining candidates exist, continue creating others |
| `project_registration: "partial"` or `"failed"` | Display warnings from result. Issue creation itself succeeded |

**Behavior on error:**
- Even if one Issue creation fails, continue creating other candidates
- Projects registration failure does not block Issue creation or subsequent processing
- Only report successfully created Issues in 4.3.5

#### 4.3.5 Creation Report

When Issues are created:

```
別 Issue を作成しました:

| Issue | タイトル |
|-------|----------|
| #{issue_number} | {issue_title} |

合計: {count} 件
```

After Phase 4.3 is complete, proceed to Phase 4.5 (work memory update).

### 4.5 Automatic Work Memory Update

> Update work memory per `work-memory-format.md` (at `{plugin_root}/skills/rite-workflow/references/work-memory-format.md`). Resolve `{plugin_root}` per [Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script).

> **⚠️ Caution**: Work memory is published as a comment on the Issue. In public repositories, it is viewable by third parties. Do not record confidential information (credentials, personal information, internal URLs, etc.) in work memory.

If a related Issue exists, automatically update the work memory.

#### 4.5.1 Identify Related Issue

Identify the related Issue from the PR or branch name.

**Extraction priority:**
1. Search for `Closes #XX`, `Fixes #XX`, `Resolves #XX` patterns in the **PR body** (priority)
2. If not found in the PR body, search for the `issue-{number}` pattern in the **branch name**

```bash
# 1. まず PR 本文から Closes #XX パターンを抽出（優先）
# Phase 1.1 で --json に body を含めて取得済みのため、再取得不要
# 保持している body フィールドから直接パターンマッチ
pr_body_tmp=$(mktemp)
trap 'rm -f "$pr_body_tmp"' EXIT
printf '%s' "{pr_body}" > "$pr_body_tmp"
issue_number=$(grep -oE '(Closes|Fixes|Resolves) #[0-9]+' "$pr_body_tmp" | head -1 | grep -oE '[0-9]+' || true)

# 2. PR 本文で見つからない場合、ブランチ名から抽出
if [[ -z "$issue_number" ]]; then
  issue_number=$(git branch --show-current | grep -oE 'issue-[0-9]+' | grep -oE '[0-9]+' || true)
fi
```

> **Note**: `{pr_body}` is the `body` field from the Phase 1.1 result (retained in context). No additional `gh pr view` call is needed.

**Implementation note for Claude**: `{pr_body}` はドキュメントのプレースホルダ（Phase 4.3.4 の注記と同等）。Claude はスクリプト生成前に実際の PR body で置換する。body に改行・シングルクォート・`$` 記号等の特殊文字が含まれる場合は `echo "..."` への直接埋め込みを避け、`printf '%s' '{pr_body}'` または一時ファイル経由（`tmpfile=$(mktemp)` + HEREDOC）でパターンマッチを実行すること。

If no Issue number is found, display a warning and skip the work memory update:

```
⚠️ Issue 番号が特定できないため作業メモリ更新をスキップしました
PR 本文に Closes/Fixes/Resolves #XX が含まれていないか、ブランチ名に issue-{number} パターンがありません。
```

#### 4.5.2 Retrieve and Update Work Memory Comment

The work memory update performs **three operations** in a single Bash tool invocation:

1. **進捗サマリー更新**: Update the progress summary table to reflect implementation status
2. **変更ファイル更新**: Replace the changed files section with actual file changes from `git diff`
3. **レビュー対応履歴追記**: Append the review response history (4.5.3 content)

```bash
# ⚠️ このブロック全体を単一の Bash ツール呼び出しで実行すること（クロスプロセス変数参照を防止）
# comment_data の取得・更新内容の生成・PATCH を分割すると変数が失われる（Issue #693, #90）
comment_data=$(gh api repos/{owner}/{repo}/issues/{issue_number}/comments \
  --jq '[.[] | select(.body | contains("📜 rite 作業メモリ"))] | last | {id: .id, body: .body}')
comment_id=$(echo "$comment_data" | jq -r '.id // empty')
current_body=$(echo "$comment_data" | jq -r '.body // empty')

if [[ -n "$comment_id" ]]; then
  if [[ -z "$current_body" ]]; then
    echo "ERROR: 作業メモリの本文取得に失敗。更新をスキップします。" >&2
  else
    backup_file="/tmp/rite-wm-backup-${issue_number}-$(date +%s).md"
    printf '%s' "$current_body" > "$backup_file"
    original_length=$(printf '%s' "$current_body" | wc -c)

    # Step 1: 変更ファイル一覧を取得
    base_branch=$(grep -E '^\s*base:' rite-config.yml 2>/dev/null | head -1 | sed 's/.*base:\s*"\?\([^"]*\)"\?/\1/' || echo "develop")
    changed_files_md=$(git diff --name-status "origin/${base_branch}...HEAD" 2>/dev/null | while read -r status file; do
      case "$status" in
        A) echo "- \`${file}\` - 追加" ;;
        M) echo "- \`${file}\` - 変更" ;;
        D) echo "- \`${file}\` - 削除" ;;
        R*) echo "- \`${file}\` - 名前変更" ;;
        *) echo "- \`${file}\` - ${status}" ;;
      esac
    done)
    if [[ -z "$changed_files_md" ]]; then
      changed_files_md="_まだ変更はありません_"
    fi

    # Step 2: Python で進捗サマリー・変更ファイルを更新 + レビュー対応履歴を追記
    body_tmp=$(mktemp)
    tmpfile=$(mktemp)
    files_tmp=$(mktemp)
    history_tmp=$(mktemp)
    trap 'rm -f "$pr_body_tmp" "$body_tmp" "$tmpfile" "$files_tmp" "$history_tmp"' EXIT
    printf '%s' "$current_body" > "$body_tmp"
    printf '%s' "$changed_files_md" > "$files_tmp"
    cat > "$history_tmp" << 'HISTORY_EOF'
{4.5.3 の内容を実際の値で置換して記述}
HISTORY_EOF

    python3 -c '
import sys, re

body_path, out_path = sys.argv[1], sys.argv[2]
impl_status, test_status, doc_status = sys.argv[3], sys.argv[4], sys.argv[5]
files_path = sys.argv[6]
history_path = sys.argv[7]

with open(body_path, "r") as f:
    body = f.read()
with open(files_path, "r") as f:
    file_list_markdown = f.read()
with open(history_path, "r") as f:
    history_entry = f.read().strip()

# --- Progress summary update (v2 format: Markdown table) ---
v2_updated = False
for item, status in [("実装", impl_status), ("テスト", test_status), ("ドキュメント", doc_status)]:
    pattern = r"(\| " + re.escape(item) + r" \| )[^|]*( \|.*\|)"
    new_body = re.sub(pattern, lambda m: m.group(1) + status + m.group(2), body, count=1)
    if new_body != body:
        v2_updated = True
    body = new_body

# v1 format fallback: checkbox style
if not v2_updated:
    if "### 進捗" in body and "### 進捗サマリー" not in body:
        for item, status in [("実装", impl_status), ("テスト", test_status), ("ドキュメント", doc_status)]:
            if "完了" in status:
                body = re.sub(r"- \[ \] " + re.escape(item), "- [x] " + item, body, count=1)

# --- Changed files section update ---
pattern = r"(### 変更ファイル\n)(?:<!-- .*?-->\n)?.*?(?=\n### |\Z)"
body = re.sub(pattern, lambda m: m.group(1) + file_list_markdown, body, count=1, flags=re.DOTALL)

# --- Append review response history ---
# Find existing レビュー対応履歴 section and append; if not found, add before 次のステップ
if "### レビュー対応履歴" in body:
    # Append to existing section (before the next ### heading or end)
    pattern = r"(### レビュー対応履歴\n.*?)(?=\n### |\Z)"
    body = re.sub(pattern, lambda m: m.group(1).rstrip() + "\n\n" + history_entry, body, count=1, flags=re.DOTALL)
else:
    # Insert before 次のステップ
    body = re.sub(r"(### 次のステップ)", "### レビュー対応履歴\n" + history_entry + "\n\n" + r"\1", body, count=1)

with open(out_path, "w") as f:
    f.write(body)
' "$body_tmp" "$tmpfile" "{impl_status}" "{test_status}" "{doc_status}" "$files_tmp" "$history_tmp"

    # Safety checks before PATCH (see gh-cli-patterns.md)
    if [ ! -s "$tmpfile" ] || [[ "$(wc -c < "$tmpfile")" -lt 10 ]]; then
      echo "ERROR: Updated body is empty or too short. Aborting PATCH. Backup: $backup_file" >&2
      exit 1
    fi
    if ! grep -q '📜 rite 作業メモリ' "$tmpfile"; then
      echo "ERROR: Updated body missing work memory header. Backup: $backup_file" >&2
      exit 1
    fi
    updated_length=$(wc -c < "$tmpfile")
    if [[ "${updated_length:-0}" -lt $(( ${original_length:-1} / 2 )) ]]; then
      echo "ERROR: Updated body < 50% of original (${updated_length}/${original_length}). Aborting PATCH. Backup: $backup_file" >&2
      exit 1
    fi

    jq -n --rawfile body "$tmpfile" '{"body": $body}' \
      | gh api repos/{owner}/{repo}/issues/comments/"$comment_id" \
        -X PATCH --input - || \
        echo "WARNING: PATCH failed. Backup: $backup_file" >&2
  fi
fi
```

**Placeholder descriptions for Claude**:

| Placeholder | Description | Determination |
|-------------|-------------|---------------|
| `{impl_status}` | 実装ステータス | 修正コミットがあれば `✅ 完了` or `🔄 進行中` |
| `{test_status}` | テストステータス | テストファイルの変更があれば `🔄 進行中` or `✅ 完了`、なければ `⬜ 未着手` |
| `{doc_status}` | ドキュメントステータス | ドキュメントファイルの変更があれば `🔄 進行中` or `✅ 完了`、なければ `⬜ 未着手` |
| `{4.5.3 の内容}` | レビュー対応履歴エントリ | Phase 4.5.3 のテンプレートから生成 |

**Status detection logic**: Claude determines each status by analyzing `git diff --name-status` output:
- 実装: Target code files have changes → `✅ 完了` (all planned changes done) or `🔄 進行中`
- テスト: Test files (`*.test.*`, `*.spec.*`) have changes → update accordingly
- ドキュメント: Documentation files (`*.md`, `docs/*`) have changes → update accordingly

**Note for Claude**: ⚠️ このブロック全体を**1つの Bash ツール呼び出し**で実行すること。`current_body` 取得・Python 更新スクリプト実行・PATCH を別の Bash ツール呼び出しに分割すると、前の呼び出しのシェル変数（`current_body` 等）が失われてヘッダーが消失する（Issue #693）。`{4.5.3 の内容を実際の値で置換して記述}` を 4.5.3 のテンプレートから生成した実際の追記内容で置換し、**すべてを1ブロックで**実行する。

#### 4.5.3 Update Content

Automatically append the following to work memory:

```markdown
### レビュー対応履歴

#### {timestamp}: /rite:pr:fix 実行
- **対応した指摘**: {count}件
- **対応内容**:
  | 指摘 | 対応 |
  |-----|------|
  | {comment_preview} | {response_type} |
- **コミット**: {commit_sha}
- **プッシュ**: 完了 / 未実行
```

**Response types:**
- `修正` - Code was fixed
- `返信` - Explanation/reply only
- `スキップ` - Deferred for later

### 4.6 Completion Report

```
PR #{number} のレビュー指摘対応を完了しました

全指摘: {total_count}件
対応した指摘: {count}件
- 修正: {fix_count}件
- 返信: {reply_count}件
- スキップ → 別 Issue 化: {skip_count}件
コミット: {commit_sha}
プッシュ: 完了 / 未実行
別 Issue 作成: {issue_count}件

次のステップ:
- レビュアーの再レビューを待つ
- 追加の指摘があれば再度 `/rite:pr:fix` を実行
- すべて承認されたら `/rite:pr:ready` でマージ準備
```

**Field descriptions:**

| Field | Description | Calculation |
|-------|-------------|-------------|
| `全指摘: {total_count}件` | Total number of findings | Number of review comment findings retrieved in Phase 1 |
| `対応した指摘: {count}件` | Number of findings addressed | `fix_count + reply_count + skip_count` |

**Note**: The review-fix loop of `/rite:issue:start` checks the content of this completion report to determine the next action:
- `プッシュ: 完了` -> Execute re-review (verify fix content)
- `別 Issue 作成: N件` (N >= 1) -> Execute re-review (confirm skipped findings are managed)
- `プッシュ: 未実行` and `別 Issue 作成: 0件` and `全指摘 == 対応指摘` -> Proceed to completion report (all addressed via replies)

---

## Error Handling

See [Common Error Handling](../../references/common-error-handling.md) for shared patterns (Not Found, Permission, Network errors).

| Error | Recovery |
|-------|----------|
| When PR is Not Found | See [common patterns](../../references/common-error-handling.md) |
| When Comment Retrieval Fails | ネットワーク接続を確認; `gh auth status` で認証状態を確認 |
| Error During File Modification | この指摘をスキップして続行 / 手動で修正 |
| Commit Failure | `git status` で状態を確認; 問題を解決してから再度コミット |

## Phase 8: End-to-End Flow Continuation (Output Pattern)

> **This phase is executed only within the end-to-end flow (within the review-fix loop of `/rite:issue:start`). Skip for standalone execution.**

**Flow detection method:** Claude determines the caller from the conversation context using mechanical pattern matching:

| Priority | Condition | Result |
|----------|-----------|--------|
| 1 | Conversation history contains a record of `Skill tool` invoking `rite:pr:fix` (recent message) | Within loop → Execute Phase 8 |
| 2 | Work memory contains `コマンド: /rite:issue:start` AND (`フェーズ: 実装作業中` OR `フェーズ: 品質検証`) | Within loop → Execute Phase 8 |
| 3 | Otherwise (user directly input `/rite:pr:fix`) | Standalone execution → Skip Phase 8 |

### 8.1 Output Pattern (Return Control to Caller)

Before outputting the pattern, update `.rite-flow-state` to `phase5_post_fix` (defense-in-depth, fixes #709). This prevents stop-guard `error_count` from accumulating when the flow continues after this skill returns:

```bash
bash {plugin_root}/hooks/flow-state-update.sh patch \
  --phase "phase5_post_fix" \
  --next "rite:pr:fix completed. Check recent result pattern in context: [fix:pushed]+fix-needed->Phase 5.4.1 (re-review). [fix:pushed]+conditional/loop-limit->Phase 5.5 (ready). [fix:issues-created]->Phase 5.4.1. [fix:replied-only]->Phase 5.5. Do NOT stop." \
  --if-exists
```

**Note on `error_count`**: The `flow-state-update.sh` patch mode preserves all existing fields not explicitly set (`phase`, `updated_at`, `next_action`), so `error_count` is retained from the existing `.rite-flow-state` (unlike `start.md` which creates a fresh object without `error_count`). The count is effectively reset when `/rite:issue:start` Phase 5.4.1 or 5.4.4 writes a new complete object via `jq -n`.

**Also update local work memory** (`.rite-work-memory/issue-{n}.md`) with `loop_count` increment and phase transition:

Use the self-resolving wrapper. See [Work Memory Format - Usage in Commands](../../skills/rite-workflow/references/work-memory-format.md#usage-in-commands) for details and marketplace install notes.

```bash
WM_SOURCE="fix" \
  WM_PHASE="phase5_post_fix" \
  WM_PHASE_DETAIL="レビュー修正後処理" \
  WM_NEXT_ACTION="re-review or completion" \
  WM_BODY_TEXT="Post-fix. loop_count incremented." \
  WM_LOOP_INCREMENT="true" \
  WM_ISSUE_NUMBER="{issue_number}" \
  bash {plugin_root}/hooks/local-wm-update.sh 2>/dev/null || true
```

**On lock failure**: Log a warning and continue — local work memory update is best-effort.

Then, based on the Phase 4.6 completion report content, output the corresponding machine-readable pattern:

| Condition | Output Pattern |
|-----------|---------------|
| Push completed (`プッシュ: 完了`) | `[fix:pushed]` |
| Separate Issues created (N >= 1) | `[fix:issues-created:{count}]` |
| All findings replied (no push, no separate Issues) | `[fix:replied-only]` |
| Unexpected state / error | `[fix:error]` |

**Important**:
- Do **NOT** invoke `rite:pr:review` via the Skill tool
- Return control to the caller (`/rite:issue:start`)
- The caller determines the next action based on this output pattern

**Example output:**
```
PR #123 のレビュー指摘対応を完了しました

全指摘: 5件
対応した指摘: 5件
- 修正: 3件
- 返信: 1件
- スキップ → 別 Issue 化: 1件
コミット: abc1234
プッシュ: 完了
別 Issue 作成: 1件

[fix:pushed]
```

---

### 8.2 Standalone Execution Behavior

For standalone execution, Phase 8 is not executed. The completion report from Phase 4.6 will guide the user.
