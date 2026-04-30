# Archive Procedures (Cleanup Phase 3-4)

> **Source**: Extracted from `cleanup.md` Phase 3-4. This file is the source of truth for Projects Status Update, Issue close, Parent Issue handling, and state reset procedures.

## Phase 3: Projects Status Update

### 3.1 Retrieve Project Configuration

Retrieve Project information from `rite-config.yml`:

```yaml
github:
  projects:
    project_number: {number}
    owner: "{owner}"
```

### 3.2 Update Status via Shared Script

> **Source of truth**: This phase delegates to `plugins/rite/scripts/projects-status-update.sh` — the same shared script used by `commands/issue/start.md` Phase 2.4 / 5.5.1 / 5.7.2 (Issue #496 / PR #531). Direct inline `gh api graphql` + `gh project field-list` + `gh project item-edit` calls have been removed because LLM attention loss / partial-failure paths through the 3-stage inline pipeline produced silent skips that left Issue Status stuck at the previous value (Issue #658 — observed on #593 stuck at "In Review" and #652 stuck at "In Progress").

Skip Phase 3.2 if `github.projects.enabled: false` in `rite-config.yml` or if no related Issue was identified in `cleanup.md` Phase 1.5, and proceed to Phase 3.5 (work memory update). Otherwise, invoke the shared script to transition the Issue Status to **Done**:

```bash
bash {plugin_root}/scripts/projects-status-update.sh "$(jq -n \
  --argjson issue {issue_number} \
  --arg owner "{owner}" \
  --arg repo "{repo}" \
  --argjson project_number {project_number} \
  --arg status "Done" \
  --argjson auto_add false \
  --argjson non_blocking true \
  '{issue_number:$issue, owner:$owner, repo:$repo, project_number:$project_number, status_name:$status, auto_add:$auto_add, non_blocking:$non_blocking}')"
```

`auto_add: false` because by cleanup time the Issue is already registered in the Project (start.md Phase 2.4 auto-added it if missing). The script internally executes the GraphQL `projectItems` query → `gh project field-list` → `gh project item-edit` triple in a single fail-fast pipeline.

#### 3.2.1 Result Handling

Inspect the script's stdout JSON and route by `.result`:

| `.result` | `projects_status_updated` | User-visible action |
|-----------|---------------------------|--------------------|
| `"updated"` | Set to `true` | Display `Projects Status を "Done" に更新しました` |
| `"skipped_not_in_project"` | Stays `false` (default) | Display `警告: Issue #{issue_number} は Project に登録されていません。Status 更新をスキップします。` and proceed |
| `"failed"` | Stays `false` (default) | Display each `.warnings[]` entry to stderr, then display `警告: Projects Status の "Done" への更新に失敗しました。手動で更新する場合: GitHub Projects 画面で Issue #{issue_number} の Status を "Done" に変更するか、または gh project item-edit --project-id <project_id> --id <item_id> --field-id <status_field_id> --single-select-option-id <done_option_id> を実行してください。` and proceed |

**All result branches are non-blocking** — display the appropriate message and proceed to Phase 3.5 (work memory update). The cleanup process MUST NOT fail due to a Projects Status update issue.

> **Underlying API documentation**: See [projects-integration.md §2.4](../../../references/projects-integration.md#24-github-projects-status-update) for the API-level details (GraphQL query, field-list, item-edit) that the script encapsulates.

#### 3.2.2 Phase 3 Result Summary

Track the final success/failure of the Projects Status update for inclusion in the Phase 5 completion report:

**Result variable:**
- `projects_status_updated` = `false` (default). Set to `true` only when Phase 3.2 returns `.result == "updated"`.

When Phase 3.2 returns `.result == "skipped_not_in_project"` or `"failed"`, `projects_status_updated` retains its default `false` value and the failure has already been surfaced via the `.warnings[]` lines + manual recovery hint above.

The LLM retains `projects_status_updated` in conversation context. Phase 5.1 uses it for conditional display of the Projects Status update result via the `{projects_check}` / `{projects_status_result}` placeholders (see `cleanup.md` Phase 5.1).

**Bash 実装パターン** (LLM 向け実装ヒント — Phase 3.2 の `bash {plugin_root}/scripts/projects-status-update.sh "$status_json_args"` 行を以下のように書き換える):

```bash
# Phase 3.2 の script delegate invocation を defensive shape で書き換える
# (sister sites: close.md Phase 1.3.2.1 / 4.2.1, ready.md Phase 4.2.1, archive-procedures.md Phase 3.7.2.1
#  と byte-for-byte 整合させる — `|| status_json=""` fallback / jq 2>/dev/null 抑制 / `failed|*)`
#  catch-all は AC-2 silent skip 復活ベクタを塞ぐために必須)
status_json=$(bash {plugin_root}/scripts/projects-status-update.sh "$status_json_args") || status_json=""
status_result=$(printf '%s' "$status_json" | jq -r '.result // "failed"' 2>/dev/null)
status_warning_lines=$(printf '%s' "$status_json" | jq -r '.warnings[]?' 2>/dev/null)
projects_status_updated="false"  # default
case "$status_result" in
  updated)
    projects_status_updated="true"
    echo "Projects Status を \"Done\" に更新しました"
    ;;
  skipped_not_in_project)
    echo "警告: Issue #{issue_number} は Project に登録されていません。Status 更新をスキップします。" >&2
    ;;
  failed|*)
    # script が JSON-emit 前に死んだ場合 (jq 不在 / mktemp 失敗 / `{plugin_root}` 置換漏れ等) は
    # status_result が空文字となり `*)` で捕捉される — silent fall-through 防止
    [ -n "$status_warning_lines" ] && printf '%s\n' "$status_warning_lines" | sed 's/^/  /' >&2
    echo "警告: Projects Status の \"Done\" への更新に失敗しました。手動で更新する場合: gh project item-edit --project-id <project_id> --id <item_id> --field-id <status_field_id> --single-select-option-id <done_option_id>" >&2
    ;;
esac
# projects_status_updated を Phase 5.1 で参照するため context-local に保持する
```

完全な bash 実装サンプルは `commands/issue/close.md` Phase 4.6.3 (parent Issue Done 更新の unified block) を参照すること (state machine + signal-specific trap + tempfile + Step 3 inconsistency summary を含む完全形)。

### 3.5 Automatic Final Update of Work Memory

If a work memory comment exists on the Issue, automatically append a completion record.

#### 3.5.1 Retrieve and Update Work Memory Comment

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
    backup_file="/tmp/rite-wm-backup-${issue_number}-$(date +%s).md"
    printf '%s' "$current_body" > "$backup_file"
    original_length=$(printf '%s' "$current_body" | wc -c)

    tmpfile=$(mktemp)
    trap 'rm -f "$tmpfile"' EXIT
    printf '%s\n\n' "$current_body" > "$tmpfile"
    cat >> "$tmpfile" << 'NEW_SECTION_EOF'
{3.5.2の内容を実際の値で置換して記述}
NEW_SECTION_EOF

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
        -X PATCH --input -
  fi
fi
```

**Note for Claude**: ⚠️ このブロック全体を**1つの Bash ツール呼び出し**で実行すること。`current_body` 取得・追記内容の heredoc 定義・PATCH を別の Bash ツール呼び出しに分割すると、前の呼び出しのシェル変数（`current_body` 等）が失われてヘッダーが消失する（Issue #693）。`{3.5.2の内容を実際の値で置換して記述}` を 3.5.2 のテンプレートから生成した実際の追記内容で置換し、**すべてを1ブロックで**実行する。

#### 3.5.2 Update Content

Automatically append the following to the work memory:

**Note**: If a `### 未完了タスクの処理結果` section was appended in Phase 1.7.4, preserve its content. The update in Phase 3.5 appends to the existing content and must not overwrite the Phase 1.7.4 records.

**Progress section merge method:**

The progress section update in Phase 3.5.2 follows this logic:

1. Retrieve the existing progress section
2. Preserve all existing checklist items
3. Append new items (`- [x] レビュー完了`, `- [x] マージ完了`, `- [x] クリーンアップ完了`) at the end (do not duplicate if already present)
4. If `- [x] 未完了タスク処理済み` added in Phase 1.7.4 exists, preserve it as well

**Example (merging from a state after Phase 1.7.4 execution):**

```markdown
### 進捗
- [x] 実装完了
- [x] PR マージ済み
- [x] 未完了タスク処理済み  ← Phase 1.7.4 で追加（保持）
- [x] レビュー完了           ← Phase 3.5.2 で追加
- [x] マージ完了             ← Phase 3.5.2 で追加
- [x] クリーンアップ完了     ← Phase 3.5.2 で追加
```

**Bash implementation (Python-based section merge):**

```bash
# ⚠️ 以下の処理は 3.5.1 の単一 Bash ブロック内に組み込むこと。
# 挿入位置: 3.5.1 の current_body=$(echo "$comment_data" | jq -r '.body // empty') の直後。
# こうすることで $current_body を再利用し、追加の API コールを回避できる。
body_tmp=$(mktemp)
filtered_items_file=$(mktemp)
updated_tmp=$(mktemp)
# backup_file is intentionally excluded from trap — preserved for post-mortem investigation
backup_file="/tmp/rite-wm-backup-${issue_number}-$(date +%s).md"
trap 'rm -f "$body_tmp" "$filtered_items_file" "$updated_tmp"' EXIT

# Step 1: Backup current body
printf '%s' "$current_body" > "$backup_file"
printf '%s' "$current_body" > "$body_tmp"

# 追加済みでない項目のみを filtered_items_file に書き込む（完全行マッチで重複防止）
for item in "- [x] レビュー完了" "- [x] マージ完了" "- [x] クリーンアップ完了"; do
  if ! grep -qxF "$item" "$body_tmp"; then
    printf '%s\n' "$item" >> "$filtered_items_file"
  fi
done

# Step 2: Python-based section append (awk-free)
python3 -c '
import sys

body_path = sys.argv[1]
items_path = sys.argv[2]
out_path = sys.argv[3]

with open(body_path, "r") as f:
    body = f.read()

try:
    with open(items_path, "r") as f:
        new_items = [l for l in f.read().strip().split("\n") if l.strip()]
except FileNotFoundError:
    new_items = []

if not new_items:
    with open(out_path, "w") as f:
        f.write(body)
    sys.exit(0)

lines = body.split("\n")
result = []
in_section = False

for i, line in enumerate(lines):
    if line.rstrip() == "### 進捗":
        in_section = True
        result.append(line)
        continue
    if in_section and line.startswith("### "):
        for item in new_items:
            result.append(item)
        in_section = False
        result.append(line)
        continue
    result.append(line)

# If section was at EOF, append items
if in_section:
    for item in new_items:
        result.append(item)

output = "\n".join(result)
if body.endswith("\n") and not output.endswith("\n"):
    output += "\n"
with open(out_path, "w") as f:
    f.write(output)
' "$body_tmp" "$filtered_items_file" "$updated_tmp"

# Step 3: Validate updated content
# On failure: restore backup and continue — section append failure is non-critical,
# the original content is still valid for subsequent PATCH
if [ ! -s "$updated_tmp" ] || [[ "$(wc -c < "$updated_tmp")" -lt 10 ]]; then
  echo "WARNING: Updated body is empty or too short. Restoring backup." >&2
  cp "$backup_file" "$updated_tmp"
fi
if grep -q -- '📜 rite 作業メモリ' "$updated_tmp"; then
  : # Header present, proceed
else
  echo "WARNING: Updated body missing header. Restoring backup." >&2
  cp "$backup_file" "$updated_tmp"
fi

current_body=$(cat "$updated_tmp")
```

**Note for Claude**: ⚠️ awk は使用禁止。Python インラインスクリプトでセクション追記を行うこと。更新前バックアップ・空body検証・ヘッダー検証を必ず実行すること。参照: [gh-cli-patterns.md の Work Memory Update Safety Patterns](../../references/gh-cli-patterns.md#work-memory-update-safety-patterns)。

**Standard update template:**

```markdown
### 進捗
- [x] 実装完了
- [x] PR 作成済み
- [x] レビュー完了
- [x] マージ完了
- [x] クリーンアップ完了

### 完了情報
- **マージ日時**: {merged_at}
- **PR**: #{pr_number} - {pr_title}
- **PR URL**: {pr_url}
- **クリーンアップ完了**: {timestamp}
- **削除したブランチ**: {branch_name}
- **最終 Status**: Done
```

**Note**: If no work memory comment is found, skip the update and display a warning.

#### 3.5.3 Completion Mark on Work Memory

When performing the final update, update the work memory title to indicate closure:

```markdown
## 📜 rite 作業メモリ ✅ 完了
```

This makes it visually clear that the Issue's work has been completed.

### 3.6 Close Related Issue

Close the related Issue identified in Phase 1.5.

#### 3.6.1 Check Issue State

If a related Issue has been identified, check its current state:

```bash
gh issue view {issue_number} --json state --jq '.state'
```

#### 3.6.2 Close the Issue

If the Issue is OPEN, execute the close:

```bash
gh issue close {issue_number} --comment "PR #{pr_number} のマージに伴いクローズしました。"
```

**Note**: `gh issue close` does not error when executed on an already-closed Issue (idempotent).

#### 3.6.3 Processing Branch by Condition

| Condition | Processing | Message |
|-----------|-----------|---------|
| Issue is OPEN | Execute close | `Issue #{issue_number} をクローズしました` |
| Issue is already CLOSED | Skip | (No message, no warning needed) |
| Related Issue was not identified | Skip | `警告: 関連 Issue が見つかりません` |

### 3.6.4 Update Parent Issue Tasklist Checkbox

**Execution condition**: Only executed when a parent Issue was detected in Phase 1.5.1.

When a child Issue's PR is merged and cleanup runs, update the parent Issue's Tasklist checkbox for this child Issue from `- [ ]` to `- [x]`.

#### 3.6.4.1 Replace Checkbox

Replace `- [ ] #{issue_number}` with `- [x] #{issue_number}` in the parent Issue body. The pattern matches any text after the Issue number on the same line (e.g., `- [ ] #661 - description text`).

**Implementation**: Use the 3-step pattern (Bash → Read+Write → Bash) per [gh-cli-patterns.md](../../references/gh-cli-patterns.md).

**Step 1: Bash tool call -- retrieve and validate the body**

```bash
bash {plugin_root}/hooks/issue-body-safe-update.sh fetch --issue {parent_issue_number} --parent
```

Outputs: `tmpfile_read=<path>`, `tmpfile_write=<path>`, `original_length=<n>`.

**Step 2: Read tool + Write tool -- replace checkbox**

1. Read the contents of `$tmpfile_read` (path output in Step 1) using the Claude Code Read tool
2. Replace `- [ ] #{issue_number}` with `- [x] #{issue_number}` (match lines containing `- [ ] #{issue_number}`, preserving any trailing text)
3. If the line already has `- [x] #{issue_number}`, leave it unchanged (idempotent)
4. Write the updated body to `$tmpfile_write` using the Claude Code Write tool

**Step 3: Bash tool call -- validate and apply**

```bash
bash {plugin_root}/hooks/issue-body-safe-update.sh apply --issue {parent_issue_number} \
  --tmpfile-read "{tmpfile_read}" --tmpfile-write "{tmpfile_write}" \
  --original-length {original_length} --parent --diff-check
```

Replace `{tmpfile_read}`, `{tmpfile_write}`, `{original_length}` with the values output in Step 1. The `--diff-check` flag skips apply if no change was made (idempotent).

#### 3.6.4.2 Edge Cases

| Condition | Processing |
|-----------|-----------|
| Checkbox already `- [x]` | No change (idempotent) |
| Child Issue number not found in parent body | No change, display: `INFO: 親 Issue #{parent_issue_number} の本文に #{issue_number} が見つかりませんでした（変更なし）` |
| Parent Issue body retrieval fails | Display warning and skip (non-blocking) |
| `gh issue edit` fails | Display warning and continue to Phase 3.7 |

**Warning message on failure:**

```
警告: 親 Issue #{parent_issue_number} の Tasklist 更新に失敗しました
理由: {reason}
手動で更新する場合: 親 Issue の本文で - [ ] #{issue_number} を - [x] #{issue_number} に変更してください
```

**Note**: Failure to update the parent Issue Tasklist does not block the cleanup process. Display a warning and proceed to Phase 3.7.

### 3.7 Auto-Close Parent Issue

**Execution condition**: Only executed when a parent Issue was detected in Phase 1.5.1.

If all child Issues are complete, automatically close the parent Issue.

#### 3.7.1 Check Completion of All Child Issues

Check the state of all child Issues of the parent Issue:

```bash
gh api graphql -f query='
query($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) {
    issue(number: $number) {
      state
      trackedIssues(first: 50) {
        nodes {
          number
          title
          state
        }
      }
    }
  }
}' -f owner="{owner}" -f repo="{repo}" -F number={parent_issue_number}
```

**Assessment logic:**

| Condition | Processing |
|-----------|-----------|
| Parent Issue is already CLOSED | Skip (no message) |
| All child Issues are CLOSED | Proceed to Phase 3.7.2 (auto-close parent Issue) |
| Some child Issues are OPEN | Proceed to Phase 3.7.3 (notify about remaining child Issues) |

#### 3.7.2 Auto-Close Parent Issue

If all child Issues are complete, auto-close the parent Issue without user confirmation.

##### 3.7.2.1 Update Parent Issue's Projects Status to "Done"

Skip this substep if `github.projects.enabled: false` in `rite-config.yml` and proceed to 3.7.2.2 (close processing). Otherwise, invoke the shared script to transition the parent Issue Status to **Done** (same delegate pattern as Phase 3.2 — see Issue #658 for rationale):

```bash
bash {plugin_root}/scripts/projects-status-update.sh "$(jq -n \
  --argjson issue {parent_issue_number} \
  --arg owner "{owner}" \
  --arg repo "{repo}" \
  --argjson project_number {project_number} \
  --arg status "Done" \
  --argjson auto_add false \
  --argjson non_blocking true \
  '{issue_number:$issue, owner:$owner, repo:$repo, project_number:$project_number, status_name:$status, auto_add:$auto_add, non_blocking:$non_blocking}')"
```

Inspect the script's stdout JSON:

| `.result` | Action |
|-----------|--------|
| `"updated"` | Display `親 Issue #{parent_issue_number} の Projects Status を "Done" に更新しました` and proceed to 3.7.2.2 |
| `"skipped_not_in_project"` | Display `警告: 親 Issue #{parent_issue_number} は Project に登録されていません。Status 更新をスキップしてクローズ処理を続行します` and proceed to 3.7.2.2 |
| `"failed"` | Display each `.warnings[]` entry to stderr, then display `警告: 親 Issue #{parent_issue_number} の Projects Status 更新に失敗しました。手動更新が必要な場合があります。クローズ処理は続行します` and proceed to 3.7.2.2 |

**All result branches are non-blocking** — the parent Issue close (3.7.2.2) MUST proceed regardless of Status update outcome.

> **Bash 実装 minimal skeleton (delegate-only 経路の標準形、parent Issue Done 更新版)**:
>
> ```bash
> status_json=$(bash {plugin_root}/scripts/projects-status-update.sh "$status_json_args") || status_json=""
> status_result=$(printf '%s' "$status_json" | jq -r '.result // "failed"' 2>/dev/null)
> status_warning_lines=$(printf '%s' "$status_json" | jq -r '.warnings[]?' 2>/dev/null)
> case "$status_result" in
>   updated) echo "親 Issue #${parent_issue_number} の Projects Status を \"Done\" に更新しました" ;;
>   skipped_not_in_project) echo "警告: 親 Issue #${parent_issue_number} は Project に登録されていません。Status 更新をスキップしてクローズ処理を続行します" >&2 ;;
>   failed|*)
>     [ -n "$status_warning_lines" ] && printf '%s\n' "$status_warning_lines" | sed 's/^/  warning: /' >&2
>     echo "警告: 親 Issue #${parent_issue_number} の Projects Status 更新に失敗しました。クローズ処理は続行します" >&2 ;;
> esac
> ```
>
> 上記が delegate-only 経路 (cleanup 経由 parent Issue auto-close では Step 3 inconsistency summary は別 phase 3.7.2.2 で扱う) の標準パターン。`.warnings[]` の stderr surface を必ず含めること。
>
> **完全形 (state machine + signal-specific trap + tempfile + 一体化された inconsistency summary)** が必要な場合は `commands/issue/close.md` Phase 4.6.3 を参照 (Issue close と Status update を unified block で扱う)。

##### 3.7.2.2 Close the Parent Issue

Close with a detailed comment and short close reason (2-step pattern per `gh-cli-patterns.md` policy):

**Note**: The following code block is a template. `cat <<'BODY_EOF'` is a **single-quoted HEREDOC**, so bash variable expansion does not occur. Claude should replace placeholders as an LLM and then construct the command.

**Step 1: Post detailed comment via `--body-file`**

```bash
tmpfile=$(mktemp)
trap 'rm -f "$tmpfile"' EXIT

cat <<'BODY_EOF' > "$tmpfile"
すべての子 Issue が完了したため、自動クローズします。

完了した子 Issue:
{sub_issue_list}

クローズ元: PR #{pr_number} のマージに伴うクリーンアップ処理
BODY_EOF

if [ ! -s "$tmpfile" ]; then
  echo "ERROR: コメント本文の生成に失敗しました" >&2
  exit 1
fi

gh issue comment {parent_issue_number} --body-file "$tmpfile"
```

**Step 2: Close with short fixed string**

```bash
gh issue close {parent_issue_number} --comment "すべての子 Issue 完了のため自動クローズ"
```

**Format of `{sub_issue_list}`:**

Generated from `trackedIssues.nodes` retrieved in Phase 3.7.1:

```markdown
- #123 子 Issue タイトル 1
- #124 子 Issue タイトル 2
- #125 子 Issue タイトル 3
```

##### 3.7.2.3 Close Completion Message

```
親 Issue #{parent_issue_number} を自動クローズしました

完了サマリ:
- 親 Issue: #{parent_issue_number} - {parent_issue_title}
- Status: Done に更新
- 完了した子 Issue: {completed_count} 件
```

#### 3.7.3 Notification When Remaining Child Issues Exist

If some child Issues are still OPEN:

```
親 Issue #{parent_issue_number} には残りの子 Issue があります:

| # | タイトル | 状態 |
|---|---------|------|
| #{remaining_sub_number_1} | {remaining_sub_title_1} | ⬜ 未完了 |
| #{remaining_sub_number_2} | {remaining_sub_title_2} | ⬜ 未完了 |
| ... | ... | ... |

残りの子 Issue が完了すると、親 Issue は自動的にクローズされます。
```

#### 3.7.4 Error Handling

| Error Case | Response |
|-----------|----------|
| Failed to retrieve parent Issue state | Display warning and skip |
| Failed to update Projects Status | Display warning and continue with close processing |
| Failed to post detailed comment (Step 1) | Display warning and continue with close processing (Step 2) |
| Failed to close | Display warning and prompt for manual close |

**Warning message example:**

```
警告: 親 Issue #{parent_issue_number} の自動クローズに失敗しました
理由: {reason}

手動でクローズする場合:
gh issue close {parent_issue_number}
```

**Note**: Failure to auto-close the parent Issue does not block the entire cleanup process. Display a warning and continue.

---

## Phase 4: Reset State and Delete Local Work Memory

### Fail-Closed Gate (Post-Condition Check)

Before resetting state, check for residual work memory files. If Phase 3 (Projects Status Update) completed but Phase 4 was skipped (due to LLM attention loss), this ensures work memory files are still cleaned up.

```bash
# Phase 4 開始前: 作業メモリファイル残存チェック
if ls .rite-work-memory/issue-*.md 1>/dev/null 2>&1; then
  echo "WARNING: 作業メモリファイルが残存しています。cleanup-work-memory.sh を実行します。"
  bash {plugin_root}/hooks/cleanup-work-memory.sh
fi
```

Resolve `{plugin_root}` per [Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script-full-version) if not already resolved.

**Note**: This is a defense-in-depth mechanism. If Phase 4 executes correctly, this check is a no-op.

After the Fail-Closed Gate, run the cleanup-work-memory script. This script performs all cleanup steps in a single deterministic invocation:

1. Resets `.rite-flow-state` to `active: false` (prevents `post-tool-wm-sync.sh` from recreating files)
2. Deletes `.rite-compact-state` and its lockdir (#756)
3. Deletes ALL `.rite-work-memory/issue-*.md` files and their lockdirs (both current Issue and stale leftovers)
4. Reports deletion results (deleted/failed/remaining counts)

Resolve `{plugin_root}` per [Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script-full-version) if not already resolved.

```bash
bash {plugin_root}/hooks/cleanup-work-memory.sh
```

**Why a script instead of inline shell**: Previous implementations (#740, #753, #776) used inline shell fragments with LLM placeholders (`{issue_number}`, `{branch_name}`, etc.). When the LLM failed to substitute these placeholders, `jq` commands failed silently and `rm` commands deleted literal filenames instead of actual files. The script reads the issue number directly from `.rite-flow-state`, eliminating placeholder dependency.

**Key design**: The script resets `.rite-flow-state` to `active: false` **before** deleting files. This ordering prevents the `post-tool-wm-sync.sh` PostToolUse hook from recreating files after deletion (the hook checks `active == true` and exits early when false).

**Error handling:**

| Error Case | Response |
|-----------|----------|
| `.rite-flow-state` reset fails | Script displays WARNING to stderr and continues with file deletion |
| File deletion fails | Script displays WARNING to stderr per file and continues |
| `.rite-work-memory/` does not exist | No error (script handles gracefully) |
| Script itself fails | Display warning and proceed to Phase 5 (non-blocking) |

**Warning message on script failure:**

```
警告: 作業メモリクリーンアップスクリプトが失敗しました
手動でリセットする場合: .rite-flow-state を削除するか active を false に変更し、.rite-work-memory/issue-*.md を手動削除してください
```

**Note**: Failure does not block the cleanup process. Display a warning and proceed to Phase 5.

**Do NOT delete** the `.rite-work-memory/` directory itself — the script preserves it.

---

