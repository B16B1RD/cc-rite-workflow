---
description: 作業メモリを更新
---

# /rite:issue:update

Manually update the work memory comment on an Issue

---

## Overview

> **Plugin Path**: Resolve `{plugin_root}` per [Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script) before executing bash hook commands in this file.

This command is for **manually** updating the work memory.

### Automatic vs Manual Updates

In the rite workflow, the work memory is **automatically updated** when the following commands are executed:

| Command | Auto-update content |
|---------|-------------|
| `/rite:issue:start` | 作業メモリの初期化、実装計画の記録 |
| `/rite:pr:create` | 変更ファイル、コミット履歴、PR 情報の記録 |
| `/rite:pr:fix` | レビュー対応履歴の記録 |
| `/rite:pr:cleanup` | 完了情報の記録 |
| `/rite:lint` | 品質チェック結果の記録（条件付き: Issue ブランチのみ） |

### Use Cases for This Command

Use `/rite:issue:update` in the following situations:

1. **Recording decisions**: When you want to note important design decisions or policy choices
2. **Adding supplementary info**: When you want to record additional information not captured by auto-updates
3. **Manual progress updates**: When you want to record progress at a specific point in time
4. **Handoff to next session**: When you want to organize the current state before ending a session

---

Execute the following phases in order when this command is invoked.

## Arguments

| Argument | Description |
|------|------|
| `[memo]` | Memo to add (optional) |
| `--question` | Message to add as a pending question (optional) |

**Usage examples:**

```bash
# メモを追加
/rite:issue:update "設計方針を変更"

# 確認事項を追加
/rite:issue:update --question "APIのレスポンス形式は？"

# 両方を追加
/rite:issue:update "実装途中" --question "エラーハンドリングの方針は？"
```

---

## Phase 0: Identify Current Issue

### 0.1 Extract Issue Number from Branch Name

Get the current branch name and extract the Issue number:

```bash
git branch --show-current
```

Branch name pattern: `{type}/issue-{number}-{slug}`

Extraction rules:
1. Extract the digits following `issue-`
2. Example: `feat/issue-13-implement-update` → Issue #13

### 0.2 If Issue Number Cannot Be Extracted from Branch Name

```
現在のブランチから Issue 番号を特定できません。

現在のブランチ: {branch_name}

オプション:
- Issue 番号を手動で指定
- キャンセル
```

Use `AskUserQuestion` to confirm the Issue number.

### 0.3 Verify Issue Exists

```bash
gh issue view {issue_number} --json number,title,state
```

If the Issue is not found:

```
エラー: Issue #{number} が見つかりません

対処:
1. `gh issue list` で Issue 一覧を確認
2. 正しい Issue 番号を指定して再実行
```

---

## Phase 1: Load Work Memory

### 1.1 Load Local Work Memory (SoT)

Read the local work memory file with the Read tool:

```
Read: .rite-work-memory/issue-{issue_number}.md
```

If the file exists and is valid, use it as the base for updates. Retain the content in context.

### 1.2 Fallback: Issue Comment (Backup)

If the local file does not exist or is corrupt, fall back to the Issue comment:

```bash
gh api repos/{owner}/{repo}/issues/{issue_number}/comments --jq '.[] | {id: .id, body: .body}'
```

Search for a comment whose body contains `## 📜 rite 作業メモリ`.

If neither local file nor Issue comment is found:

```
警告: 作業メモリが見つかりません

この Issue は `/rite:issue:start` で開始されていない可能性があります。

オプション:
- 新規に作業メモリを作成
- キャンセル
```

Use `AskUserQuestion` to confirm, and create a new work memory if needed.

### 1.3 Retrieve Issue Comment ID

Even when using local file as SoT, retrieve the Issue comment ID for backup sync in Phase 3.4:

```bash
comment_id=$(gh api repos/{owner}/{repo}/issues/{issue_number}/comments \
  --jq '[.[] | select(.body | contains("📜 rite 作業メモリ"))] | last | .id // empty')
```

### 1.4 Compatibility with Existing Formats

The work memory may exist in one of two formats (old and new):

**Old format (v1):**
```markdown
### 進捗
- [ ] 実装開始
- [ ] テスト追加
- [ ] ドキュメント更新
```

**New format (v2):**
```markdown
### 進捗サマリー

| 項目 | 状態 | 備考 |
|------|------|------|
| 実装 | ⬜ 未着手 | - |
...

### 要確認事項
...
```

**Compatibility rules:**

1. **On read**: Both formats must be parsed correctly
2. **On update**: Preserve the existing format (do not force migration)
3. **On new creation**: Use the new format (v2)

**Format detection:**

If the content contains `### 進捗サマリー`, treat it as v2; if it contains `### 進捗`, treat it as v1.

---

## Phase 2: Collect Update Information

### 2.1 Retrieve Changed Files

```bash
# ステージング状態を確認
git status --porcelain

# 変更の統計を取得
git diff --stat HEAD
```

### 2.2 Format Changed File List

Format the changed files in the following structure:

```markdown
### 変更ファイル
- `path/to/file1.ts` - 追加
- `path/to/file2.ts` - 変更
- `path/to/file3.ts` - 削除
```

Status mapping:
- `A` / `??` → 追加
- `M` → 変更
- `D` → 削除
- `R` → 名前変更

### 2.3 Process User Memo

If a memo is provided as an argument, add it to the "決定事項・メモ" section.

---

## Phase 3: Update Work Memory

> **Warning**: The work memory is published as a comment on the Issue. On public repositories, it is visible to third parties. Do not record sensitive information (credentials, personal data, internal URLs, etc.) in the work memory.

### 3.1 Re-read Work Memory

Re-read the local work memory file immediately before updating. This defends against context compaction that may have discarded the content retrieved in Phase 1:

```
Read: .rite-work-memory/issue-{issue_number}.md
```

**Fallback**: If the local file is not available, re-fetch the Issue comment body:

```bash
comment_body=$(gh api repos/{owner}/{repo}/issues/comments/{comment_id} --jq '.body')
```

If this fails, fall back to the content retained from Phase 1. Retain this content for use in Phase 3.2.

### 3.2 Selective Section Update

**Critical**: Do NOT reconstruct the entire comment body from context or memory. Use the re-fetched `comment_body` from Phase 3.1 as the base and modify **only** the target sections listed below.

**Sections to UPDATE:**

| Section | Update Rule |
|---------|------------|
| `最終更新` (in セッション情報) | Replace with current timestamp (ISO 8601) |
| `コマンド` (in セッション情報) | Set to `rite:issue:update` |
| `フェーズ` (in セッション情報) | Set to current phase |
| `フェーズ詳細` (in セッション情報) | Set to current phase detail |
| `変更ファイル` | **Replace entire section content** with regenerated file list from `git status --porcelain` and `git diff --name-status origin/{base_branch}...HEAD` output (Phase 2.2 format). See "Changed files section update procedure" below |
| `進捗サマリー` | Update status per detection logic below |
| `決定事項・メモ` | **Append** new memo if provided (preserve all existing entries) |
| `要確認事項` | **Append** new question if `--question` provided (preserve all existing entries) |

**Sections to PRESERVE as-is (copy verbatim from existing body):**

- `Issue` / `開始` / `ブランチ` (in セッション情報)
- `実装計画` (if exists)
- `TDD 状態` (if exists — added by Phase 5.1.0.T, conditional)
- `計画逸脱ログ` (if exists)
- `ボトルネック検出ログ` (if exists)
- `レビュー対応履歴` (if exists)
- `次のステップ`
- `Issue チェックリスト` (if exists)
- Any other section not listed in the UPDATE table above

**Progress summary status detection and update procedure:**

**Step 1: Collect git state**

```bash
# 変更ファイル一覧を取得（ステージング済み + 未ステージング + 未追跡）
changed_files=$(git status --porcelain)
# ベースブランチからの差分（コミット済みの変更も含む）
diff_files=$(git diff --name-only origin/{base_branch}...HEAD 2>/dev/null || git diff --name-only HEAD)
# 両方を結合して重複排除
all_changed=$(printf '%s\n%s' "$changed_files" "$diff_files" | sed 's/^.. //' | sort -u | grep -v '^$')
```

**Step 2: Determine status for each item**

| Item | In-progress condition | Completion condition |
|------|-------------|-----------|
| 実装 | Target code files (.ts, .js, .py, .sh, .yml, etc.) have changes | All files in the implementation plan have been modified |
| テスト | Test files (*.test.*, *.spec.*, etc.) have changes | Test files have been added/modified |
| ドキュメント | Documentation files (*.md, docs/*, etc.) have changes | Required documentation has been updated |

Status notation: `⬜ 未着手` (no changes), `🔄 進行中` (incomplete), `✅ 完了` (complete).

Claude determines the status for each item by analyzing `all_changed` against the conditions above and the implementation plan (if present in work memory).

**Step 3: Update the progress summary table cells**

Use Python to replace the status cells in the existing table. This is **mandatory** — Claude MUST execute this replacement when any changed files are detected.

```python
# Python inline script for table cell replacement
# Input: body (work memory body text), statuses dict
import re

def update_progress_summary(body, statuses):
    """Update progress summary table cells in work memory body.

    Args:
        body: Full work memory body text
        statuses: dict like {"実装": "🔄 進行中", "テスト": "⬜ 未着手", "ドキュメント": "✅ 完了"}
    Returns:
        Updated body text
    """
    for item, new_status in statuses.items():
        # Match table row: | 実装 | <any status> | <any note> |
        pattern = r"(\| " + re.escape(item) + r" \| ).*?( \|.*\|)"
        replacement = r"\g<1>" + new_status + r"\2"
        body = re.sub(pattern, replacement, body, count=1)
    return body
```

**Integration**: When building the updated body in Phase 3.2, apply `update_progress_summary()` to the re-fetched body along with the other selective updates. The statuses dict is populated from the Step 2 analysis.

**Changed files section update procedure:**

Replace the entire content of the `### 変更ファイル` section (from the heading to the next `###` heading or end of body) with the regenerated file list from Phase 2.1/2.2. Use Python to perform the replacement:

```python
def update_changed_files_section(body, file_list_markdown):
    """Replace the 変更ファイル section content with updated file list.

    Args:
        body: Full work memory body text
        file_list_markdown: Formatted file list string (Phase 2.2 format),
            e.g. "- `path/to/file.ts` - 変更\\n- `path/to/other.ts` - 追加"
            When no files changed, use "_まだ変更はありません_"
    Returns:
        Updated body text
    """
    import re
    # Match from ### 変更ファイル heading to the next ### heading or end
    pattern = r"(### 変更ファイル\n)(?:<!-- .*?-->\n)?.*?(?=\n### |\Z)"
    replacement = r"\1" + file_list_markdown
    return re.sub(pattern, replacement, body, count=1, flags=re.DOTALL)
```

**Integration**: Apply `update_changed_files_section()` after `update_progress_summary()` when building the updated body. The `file_list_markdown` is generated from Phase 2.1/2.2 output. If no changed files exist, pass `"_まだ変更はありません_"`.

**Updating pending questions:**

If `--question` is provided, append to the `要確認事項` section (preserve existing items):

```markdown
### 要確認事項
{existing_items}
{n}. [ ] {new_question}
```

### 3.3 Update Local Work Memory (SoT)

Write the updated content to the local work memory file first:

```bash
WM_SOURCE="update" \
  WM_PHASE="manual_update" \
  WM_PHASE_DETAIL="手動更新" \
  WM_NEXT_ACTION="作業を継続" \
  WM_BODY_TEXT="Manual update via rite:issue:update." \
  WM_ISSUE_NUMBER="{issue_number}" \
  bash {plugin_root}/hooks/local-wm-update.sh 2>/dev/null || true
```

**On lock failure**: Log a warning and continue — local work memory update is best-effort.

**Implementation note for Claude**: `$updated_body` is the content from Phase 3.1 with **only** the target sections from Phase 3.2 modified. Parse the existing content by `### ` heading boundaries, apply updates per Phase 3.2 rules, and reassemble. All sections not listed in the UPDATE table must be copied verbatim from the re-read content. **Do NOT reconstruct the body from memory — use the re-read text as the base.**

### 3.4 Sync to Issue Comment (Backup)

After updating the local file, sync to the Issue comment as backup.

> **Reference**: Apply [Work Memory Update Safety Patterns](../../references/gh-cli-patterns.md#work-memory-update-safety-patterns) for all steps below.

```bash
tmpfile=$(mktemp)
# backup_file is intentionally excluded from trap — preserved for post-mortem investigation
backup_file="/tmp/rite-wm-backup-${issue_number}-$(date +%s).md"
trap 'rm -f "$tmpfile"' EXIT

# Step 1: Backup current content before PATCH
printf '%s' "$current_body" > "$backup_file"
original_length=$(printf '%s' "$current_body" | wc -c)

# Step 2: Write the selectively-updated body
printf '%s' "$updated_body" > "$tmpfile"

# Step 3: Validate before PATCH (10 bytes = minimum plausible work memory content)
if [ ! -s "$tmpfile" ] || [[ "$(wc -c < "$tmpfile")" -lt 10 ]]; then
  echo "ERROR: Updated body is empty or too short. Aborting PATCH. Backup: $backup_file" >&2
  exit 1
fi
if grep -q -- '📜 rite 作業メモリ' "$tmpfile"; then
  : # Header present, proceed
else
  echo "ERROR: Updated body missing work memory header. Aborting PATCH. Backup: $backup_file" >&2
  exit 1
fi

# Step 3.5: Body length comparison safety check (reject if updated body is less than 50% of original)
updated_length=$(wc -c < "$tmpfile")
if [[ "${updated_length:-0}" -lt $(( ${original_length:-1} / 2 )) ]]; then
  echo "ERROR: Updated body is less than 50% of original (${updated_length}/${original_length}). Aborting PATCH. Backup: $backup_file" >&2
  exit 1
fi

# Step 4: Apply update with error handling
jq -n --rawfile body "$tmpfile" '{"body": $body}' | gh api repos/{owner}/{repo}/issues/comments/{comment_id} \
  -X PATCH \
  --input -
patch_status=$?
if [[ "${patch_status:-1}" -ne 0 ]]; then
  echo "ERROR: PATCH failed. Backup saved at: $backup_file" >&2
  exit 1
fi
```

**Note for Claude**: ⚠️ 作業メモリ更新時は必ずバックアップ→検証→PATCH の順で実行すること。awk は使用禁止（Python インラインスクリプトを使用）。空body での PATCH は絶対に行わないこと。

**Note**: If `{comment_id}` is not available (Phase 1.3 returned empty), skip this sync and display a warning.

---

## Phase 4: Completion Report

Report the update completion:

```
Issue #{number} の作業メモリを更新しました

変更ファイル: {file_count} 件
最終更新: {timestamp}
```

If a memo was added:

```
Issue #{number} の作業メモリを更新しました

変更ファイル: {file_count} 件
追加メモ: {memo_preview}
最終更新: {timestamp}
```

---

## Update Timing Guidance

Display the following guidance as reference information when the command is executed:

| Category | Timing |
|---------|-----------|
| **Required** | After completing multi-file changes, on important decisions, on error resolution |
| **Recommended** | After 30 minutes elapsed, before complex operations, before taking a break |

---

## Error Handling

See [Common Error Handling](../../references/common-error-handling.md) for shared patterns (Not Found, Permission, Network errors).

| Error | Recovery |
|-------|----------|
| On main/master Branch | See error output for details |
| Issue Is Already Closed | See error output for details |
| Comment Update Failed | `gh issue view {number}` で Issue を確認; 再度実行 |
