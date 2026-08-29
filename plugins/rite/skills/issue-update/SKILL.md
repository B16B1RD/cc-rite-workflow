---
name: issue-update
description: |
  rite workflow の作業メモリ更新スキル: 進行中 Issue の作業メモリを更新する。
  ユーザーが明示的に /rite:issue-update で起動する。auto-activate しない。
  起動: /rite:issue-update
argument-hint: ""
---

# /rite:issue-update

作業メモリコメントを手動更新する。次の Phase を順に実行する。

> **Plugin Path**: bash hook の前に `{plugin_root}` を [Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script-full-version) で解決する。

自動更新との役割分担:
rationale: references/rationale.md#auto-vs-manual

| Command | Auto-update content |
|---------|-------------|
| `/rite:open` | 作業メモリの初期化、実装計画の記録 |
| `/rite:pr-create` | 変更ファイル、コミット履歴、PR 情報の記録 |
| `/rite:pr-review` | セッション情報更新、ループ回数の更新、レビュー結果の記録 |
| `/rite:fix` | 進捗サマリー更新、変更ファイル更新、レビュー対応履歴の記録 |
| `/rite:cleanup` | 完了情報の記録 |
| `/rite:lint` | 品質チェック結果の記録（条件付き: Issue ブランチのみ） |

## Arguments

| Argument | Description |
|------|------|
| `[memo]` | Memo to add (optional) |
| `--question` | Message to add as a pending question (optional) |

**Usage examples:**

```bash
# メモを追加
/rite:issue-update "設計方針を変更"

# 確認事項を追加
/rite:issue-update --question "APIのレスポンス形式は？"

# 両方を追加
/rite:issue-update "実装途中" --question "エラーハンドリングの方針は？"
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
2. Example: `feat/issue-13-implement-update` → issue number `13`

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

> `{owner_repo}` は [Owner/Repo Resolution](../../references/gh-cli-patterns.md#ownerrepo-resolution-ssh-host-alias-safe) で解決した owner/repo（slash 形式）を literal substitute する。

```bash
gh issue view {issue_number} -R {owner_repo} --json number,title,state
```

If the Issue is not found:

```
エラー: Issue #{number} が見つかりません

対処:
1. `gh issue list -R {owner_repo}` で Issue 一覧を確認
2. 正しい Issue 番号を指定して再実行
```

---

## Phase 1: Load Work Memory

### 1.1 Load Local Work Memory (SoT)

Read the local work memory file with the Read tool (new path first, then legacy):

```
Read: .rite/work-memory/issue-{issue_number}.md
```

不在なら `.rite-work-memory/issue-{issue_number}.md`。存在する側が valid ならそれを更新のベースにする。Retain the content in context.

### 1.2 Fallback: Issue Comment (Backup)

If neither local file exists, or the file selected in 1.1 is corrupt, fall back to the Issue comment. Do not use the legacy path when the new path exists but is invalid.

```bash
gh api repos/{owner}/{repo}/issues/{issue_number}/comments --jq '.[] | {id: .id, body: .body}'
```

Search for a comment whose body contains `## 📜 rite 作業メモリ`.

If neither local file nor Issue comment is found:

```
警告: 作業メモリが見つかりません

この Issue は `/rite:open` で開始されていない可能性があります。

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

旧形式 (v1) と新形式 (v2) が混在しうる。`### 進捗サマリー` なら v2、`### 進捗` なら v1。読取は両対応、更新は既存形式を維持、新規作成は v2。
rationale: references/rationale.md#format-compat

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

---

## Phase 2: Collect Update Information

### 2.1 Retrieve Changed Files

```bash
# ステージング状態を確認
bash {plugin_root}/hooks/scripts/lib/git-status-filtered.sh

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

> **Warning**: 作業メモリは Issue コメントとして公開される。機密情報を書かない。
> rationale: references/rationale.md#public-comment

### 3.1 Re-read Work Memory

更新直前にローカル作業メモリを再読する。
rationale: references/rationale.md#reread-before-write

```
Read: .rite/work-memory/issue-{issue_number}.md
```

不在なら `.rite-work-memory/issue-{issue_number}.md`。

**Fallback**: If neither local file is available, re-fetch the Issue comment body:

```bash
comment_body=$(gh api repos/{owner}/{repo}/issues/comments/{comment_id} --jq '.body')
```

If this fails, fall back to the content retained from Phase 1. Retain this content for use in Phase 3.2.

### 3.2 Selective Section Update

**Critical**: コメント本文全体を記憶から再構成しない。Phase 3.1 の `comment_body` をベースに、下表の対象セクションだけを変更する。

**Sections to UPDATE:**

| Section | Update Rule |
|---------|------------|
| `最終更新` (in セッション情報) | Replace with current timestamp (ISO 8601) |
| `コマンド` (in セッション情報) | Set to `rite:issue-update` |
| `フェーズ` (in セッション情報) | Set to current phase |
| `フェーズ詳細` (in セッション情報) | Set to current phase detail |
| `変更ファイル` | **Replace entire section content** with regenerated file list from `git status --porcelain` and `git diff --name-status origin/{base_branch}...HEAD` output (Phase 2.2 format). See "Changed files section update procedure" below |
| `進捗サマリー` | Update status per detection logic below |
| `決定事項・メモ` | **Append** new memo if provided (preserve all existing entries) |
| `要確認事項` | **Append** new question if `--question` provided (preserve all existing entries) |

**Sections to PRESERVE as-is (copy verbatim from existing body):**

- `Issue` / `開始` / `ブランチ` (in セッション情報)
- `実装計画` (if exists)
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
changed_files=$(bash {plugin_root}/hooks/scripts/lib/git-status-filtered.sh) || echo "WARNING: git-status-filtered.sh failed while collecting changed files; the 変更ファイル section may omit uncommitted changes" >&2
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

**Step 3: Update the progress summary table cells and changed files section**

Claude determines the progress status (Step 2) and generates the changed files list (Phase 2.2), then writes the file list to a temp file for the sync script. The script handles retrieval, Python-based transformation, safety checks, and PATCH atomically.

```bash
# 変更ファイルリストを一時ファイルに書き出す（バッククォート対策）
files_tmp=$(mktemp)
trap 'rm -f "$files_tmp"' EXIT
printf '%s' "{file_list_markdown}" > "$files_tmp"

# 進捗サマリー + 変更ファイル更新
bash {plugin_root}/hooks/issue-comment-wm-sync.sh update \
  --issue {issue_number} \
  --transform update-progress \
  --impl-status "{impl_status}" --test-status "{test_status}" --doc-status "{doc_status}" \
  --changed-files-file "$files_tmp" \
  2>/dev/null || true

rm -f "$files_tmp"
```

**Placeholder substitution**: Claude MUST replace `{impl_status}`, `{test_status}`, `{doc_status}` with the actual status strings from Step 2 (e.g., `"✅ 完了"`, `"⬜ 未着手"`). `{file_list_markdown}` is the formatted file list from Phase 2.1/2.2 output. If no changed files exist, pass `"_まだ変更はありません_"`.

**Updating pending questions:**

If `--question` is provided, write the question to a temp file and append to the `要確認事項` section:

```bash
question_tmp=$(mktemp)
trap 'rm -f "$question_tmp"' EXIT
printf '%s' "- [ ] {new_question}" > "$question_tmp"

bash {plugin_root}/hooks/issue-comment-wm-sync.sh update \
  --issue {issue_number} \
  --transform append-section \
  --section "要確認事項" --content-file "$question_tmp" \
  2>/dev/null || true

rm -f "$question_tmp"
```

### 3.3 Update Local Work Memory (SoT)

Write the updated content to the local work memory file first:

```bash
WM_SOURCE="update" \
  WM_PHASE="manual_update" \
  WM_PHASE_DETAIL="手動更新" \
  WM_NEXT_ACTION="作業を継続" \
  WM_BODY_TEXT="Manual update via rite:issue-update." \
  WM_ISSUE_NUMBER="{issue_number}" \
  bash {plugin_root}/hooks/local-wm-update.sh 2>/dev/null || true
```

**On lock failure**: Log a warning and continue — local work memory update is best-effort.

### 3.4 Sync to Issue Comment (Backup)

Phase 3.2 already handles Issue comment sync via `issue-comment-wm-sync.sh`. No additional PATCH is needed here.

If a memo was provided, append it to the `決定事項・メモ` section:

```bash
memo_tmp=$(mktemp)
trap 'rm -f "$memo_tmp"' EXIT
printf '%s' "- {memo_text}" > "$memo_tmp"

bash {plugin_root}/hooks/issue-comment-wm-sync.sh update \
  --issue {issue_number} \
  --transform append-section \
  --section "決定事項・メモ" --content-file "$memo_tmp" \
  2>/dev/null || true

rm -f "$memo_tmp"
```

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
| Comment Update Failed | `gh issue view {number} -R {owner_repo}` で Issue を確認; 再度実行 |
