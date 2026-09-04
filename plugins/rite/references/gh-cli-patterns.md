# gh CLI Patterns Reference

A collection of frequently used GitHub CLI (gh) command patterns in rite workflow.

> **🔴 CRITICAL: All gh CLI commands that send body/comment content MUST use the safe patterns defined in this document.**
>
> **Before executing ANY `gh api`, `gh issue`, or `gh pr` command that includes body content:**
> 1. Use `mktemp` + `--body-file` for Issue/PR body operations
> 2. Use `jq -n --rawfile` + `gh api --input -` for API comment operations
> 3. **NEVER** use `-f body=`, `--body "$var"`, or `echo ... | gh api --input -` with shell-constructed JSON
>
> See [gh CLI Error Catalog](./gh-cli-error-catalog.md) for the complete list of dangerous patterns and why they fail.

---

## Summary: Root Cause → Safe Pattern Mapping

| Category | Root Cause | Safe Pattern |
|----------|-----------|--------------|
| 1-2 | `-f body=` / shell escaping with Markdown | `jq -n --rawfile` + `--input -` |
| 3 | Word splitting on unquoted variables | `jq -n --rawfile` (no shell variables in JSON) |
| 4 | Empty variable expansion | `[ ! -s file ]` validation + `--body-file` |
| 5 | Missing commits / unpushed branch | Pre-creation guard checks |
| 6 | 「!」 history expansion / special chars in GraphQL variables | `jq -n --rawfile` for string variables; heredoc for queries with 「!」 |
| 7 | Shell-constructed malformed JSON | `jq` for all JSON construction |

**The universal safe pattern**: Always construct JSON payloads with `jq`, never with shell string operations.

---

## Safe Patterns Quick Reference

> 以下の実行スニペットの `-R {owner_repo}` は、[Owner/Repo Resolution (SSH Host Alias Safe)](#ownerrepo-resolution-ssh-host-alias-safe) で解決した `owner/repo`（slash 形式）をリテラル置換する（SSH host alias 環境対応。同節の Propagation 小節参照）。

### For Issue/PR body (create/edit)

```bash
tmpfile=$(mktemp)
trap 'rm -f "$tmpfile"' EXIT
cat <<'BODY_EOF' > "$tmpfile"
<body content here>
BODY_EOF
# Validate non-empty before sending
if [ ! -s "$tmpfile" ]; then
  echo "ERROR: body is empty" >&2
  exit 1
fi
gh issue edit {issue_number} -R {owner_repo} --body-file "$tmpfile"
```

### For comment creation

```bash
tmpfile=$(mktemp)
trap 'rm -f "$tmpfile"' EXIT
cat <<'BODY_EOF' > "$tmpfile"
<comment content here>
BODY_EOF
gh issue comment {issue_number} -R {owner_repo} --body-file "$tmpfile"
```

### For comment update (gh api PATCH)

```bash
# ✅ SAFE: jq --rawfile constructs valid JSON regardless of content
tmpfile=$(mktemp)
trap 'rm -f "$tmpfile"' EXIT
cat <<'BODY_EOF' > "$tmpfile"
<updated comment content here>
BODY_EOF
jq -n --rawfile body "$tmpfile" '{"body": $body}' | \
  gh api repos/{owner}/{repo}/issues/comments/{comment_id} -X PATCH --input -
```

**Why `jq --rawfile` is safe**: `jq --rawfile varname file` reads the entire file as a raw string into `$varname`, then `jq` handles all JSON escaping (quotes, newlines, backslashes, unicode) automatically. No shell escaping is involved.

---

## Safe Issue/PR Body Updates

When updating Issue or PR body, there is a risk of body loss due to:

- **Shell variable expansion failure**: Running `--body "$var"` with an undefined/empty variable sets empty string as body
- **Data loss in pipe processing**: When processing body through pipes and passing to `--body` directly, a command failure mid-pipe passes empty string
- **Write tool empty write**: If Claude Code's Write tool writes empty content to a temp file, the subsequent `--body-file` sets empty body

In all cases, gh CLI sets the empty string as body, effectively making it `null`. **The recommended pattern prevents these risks with 3 layers of defense**:

| Defense Layer | Measure | Risk Prevented |
|---------------|---------|----------------|
| (1) Pipe isolation via temp file | `mktemp` + write to file | Data loss in pipe processing |
| (2) Empty check with `[ ! -s file ]` | Validate after fetch/write | Shell variable expansion failure, Write tool empty write |
| (3) Safe delivery via `--body-file` | Pass directly from file without variable expansion | Shell variable expansion failure |

Follow the recommended patterns below.

### Dangerous Patterns (Prohibited)

> **⚠️ WARNING: The following patterns are ALL PROHIBITED for body/comment updates.**
>
> These patterns cause errors in Categories 1-4 above. Each pattern includes the specific reason for failure.

```bash
# 🚫 PROHIBITED (Category 4): Empty string passed due to shell variable expansion failure
gh issue edit {issue_number} --body "$body_var"
# WHY: Unset/empty $body_var → empty body → HTTP 422

# 🚫 PROHIBITED (Category 1-2): sed with multibyte or special characters
body=$(gh issue view {issue_number} --json body --jq '.body' | sed 's/old/new/')
gh issue edit {issue_number} --body "$body"
# WHY: sed fails on multibyte chars (日本語, emoji); result may be empty or corrupted

# 🚫 PROHIBITED (Category 1): sed for work memory comment editing
updated=$(echo "$body" | sed "s/⬜ 未着手/✅ 完了/g")
# WHY: sed: -e expression #1: multibyte character error

# 🚫 PROHIBITED (Category 4): Update without validating empty
gh issue edit {issue_number} --body ""
# WHY: Explicitly empty body → HTTP 422

# 🚫 PROHIBITED (Category 2): -f body= with special characters
gh api repos/{owner}/{repo}/issues/comments/{id} -X PATCH -f body="content with | pipes"
# WHY: -f interprets special characters; @ prefix reads as file; pipes/brackets break encoding

# 🚫 PROHIBITED (Category 7): Shell string concatenation for JSON
echo "{\"body\": \"$body\"}" | gh api ... --input -
# WHY: Quotes, newlines, backslashes in $body corrupt JSON structure
```

> **⚠️ WARNING: Do NOT use `sed` for updating Issue/PR body or work memory comments**
>
> Work memory content contains multibyte characters (Japanese, emoji) and special characters (`-`, `/`, `'`, `#`, etc.).
> Processing these with `sed` causes errors such as:
>
> ```
> sed: -e expression #1, char 186: unknown command: `-'
> ```
>
> **Always use the `jq + gh api PATCH --input -` pattern or the `--body-file` pattern instead.**

### Recommended Patterns

#### 1. Safe Body Retrieval

> **⚠️ trap note**: Re-setting `trap` for the same signal overwrites the previous trap handler. When using multiple temp files, specify trap collectively (see "Checkbox Update" below).[^1]

[^1]: `trap ... EXIT` fires on normal exit, error exit, and signal receipt, but NOT on `SIGKILL` (`kill -9`). If `SIGKILL` is received, temp files may remain in `/tmp`, but the OS temp directory cleanup typically removes them automatically.

```bash
# ✅ SAFE: Save to temp file for retrieval (prevents data loss through pipes)
# Note: Example for standalone use. When using multiple temp files, specify trap collectively (see below)
# mktemp creates files with default permissions 0600 (owner read/write only),
# preventing reads from other users, making it secure.
tmpfile=$(mktemp)
trap 'rm -f "$tmpfile"' EXIT
gh issue view {issue_number} -R {owner_repo} --json body --jq '.body' > "$tmpfile"

# Validate retrieval result (confirm non-empty)
if [ ! -s "$tmpfile" ]; then
  echo "ERROR: Failed to retrieve Issue body" >&2
  exit 1
fi
```

#### 2. Safe Body Update (`--body-file` recommended)

```bash
# ✅ SAFE: Read from temp file via --body-file
# Avoids escaping issues with special characters (", $, ` etc.)
# Note: Example for standalone use. When using multiple temp files, specify trap collectively (see below)
tmpfile=$(mktemp)
trap 'rm -f "$tmpfile"' EXIT

# ... write updated content to temp file ...

gh issue edit {issue_number} -R {owner_repo} --body-file "$tmpfile"
```

**Building body dynamically:**

```bash
# ✅ SAFE: Build body with HEREDOC, pass via --body-file
# Note: <<'BODY_EOF' (quoted) does not expand variables.
#        Use <<BODY_EOF (unquoted) when variable expansion is needed.
tmpfile=$(mktemp)
trap 'rm -f "$tmpfile"' EXIT

cat <<'BODY_EOF' > "$tmpfile"
## 概要

更新された本文の内容
BODY_EOF

gh issue edit {issue_number} -R {owner_repo} --body-file "$tmpfile"
```

#### 3. Pre-Update Validation

```bash
# ✅ SAFE: Confirm update content is non-empty before updating
# Note: Example for standalone use. When using multiple temp files, specify trap collectively (see below)
tmpfile=$(mktemp)
trap 'rm -f "$tmpfile"' EXIT

# ... write updated content to temp file ...

if [ ! -s "$tmpfile" ]; then
  echo "ERROR: Updated content is empty. Skipping body update" >&2
  exit 1
fi

gh issue edit {issue_number} -R {owner_repo} --body-file "$tmpfile"
```

### Body Update Rules

| Operation | ✅ Safe Pattern | 🚫 Prohibited Pattern | Error Category |
|-----------|----------------|----------------------|----------------|
| Body retrieval (for update) | Save to temp file and validate | Variable assignment via direct pipe (※ variable assignment is OK for read-only) | 3, 4 |
| Body update | `--body-file` + temp file | `--body "$var"` | 1, 4 |
| Comment update (gh api) | `jq -n --rawfile` + `--input -` | `-f body=` or `echo JSON \| --input -` | 1, 2, 6, 7 |
| Work memory comment update | `jq -n --rawfile` + `gh api PATCH --input -` | `sed` (multibyte error) or `-f body=` | 1, 2 |
| Empty check | `[ ! -s file ]` after write | Update without validation | 4 |
| Checklist extraction | `grep -E` | `grep -P` (environment-dependent) | - |

### `--body` vs `--body-file` Usage Policy

| Command Type | Pattern | Reason |
|-------------|---------|--------|
| `gh issue create` / `gh pr create` | `--body-file` | Create commands tend to have long bodies and are copied as references, so unified to safe pattern |
| `gh issue edit` / `gh pr edit` | `--body-file` | Existing body updates involve dynamic generation, so required |
| `gh issue comment` / `gh pr comment` | `--body` (short fixed strings only) | Comments are often short fixed strings, and `--body-file` boilerplate is verbose. Use `--body-file` for long or special character content |
| `gh issue close --comment` | `--body` (short fixed strings only) | `--comment` option has no `--body-file` equivalent, so use `--body` |

---

## Safe Comment Updates (gh api PATCH)

When updating existing comments (work memory, review results, etc.) via `gh api`, use the `jq --rawfile` pattern.

> **🔴 CRITICAL**: This is the **recommended** safe way to update comments via `gh api`, especially for body/comment content that may contain Markdown, emoji, or multi-line text. All other methods for such content (Categories 1, 2, 6, 7) are prohibited.

### The Safe Pattern

```bash
# ✅ SAFE: jq --rawfile handles ALL escaping automatically
tmpfile=$(mktemp)
trap 'rm -f "$tmpfile"' EXIT

cat <<'BODY_EOF' > "$tmpfile"
## 📜 rite 作業メモリ

### セッション情報
- **Issue**:
- **フェーズ**: 実装作業中

### 進捗サマリー
| 項目 | 状態 | 備考 |
|------|------|------|
| 実装 | ✅ 完了 | 3 files changed |
BODY_EOF

jq -n --rawfile body "$tmpfile" '{"body": $body}' | \
  gh api repos/{owner}/{repo}/issues/comments/{comment_id} -X PATCH --input -
```

**Why this works:**
1. `cat <<'BODY_EOF'` writes content to file without any shell interpretation (single-quoted HEREDOC)
2. `jq --rawfile body "$tmpfile"` reads the entire file as a raw string — no escaping needed
3. `jq '{"body": $body}'` constructs valid JSON with proper escaping of all characters (quotes, newlines, unicode, Markdown, emoji)
4. `--input -` passes the jq-constructed JSON directly to gh api via stdin — no shell variable expansion

### Finding the Comment ID

```bash
# Find work memory comment ID by marker
comment_id=$(gh api repos/{owner}/{repo}/issues/{issue_number}/comments \
  --jq '.[] | select(.body | contains("📜 rite 作業メモリ")) | .id')
```

### All Prohibited Alternatives

```bash
# 🚫 PROHIBITED (Category 2): -f body= fails with Markdown tables, links, emoji
gh api repos/{owner}/{repo}/issues/comments/{id} -X PATCH \
  -f body="## Title\n| col | col |\n|---|---|\n| ✅ | text |"

# 🚫 PROHIBITED (Category 2): -f body= fails when content starts with @
gh api repos/{owner}/{repo}/issues/comments/{id} -X PATCH \
  -f body="@user please review"

# 🚫 PROHIBITED (Category 7): Shell-constructed JSON breaks on special characters
echo "{\"body\": \"$body\"}" | gh api ... --input -

# 🚫 PROHIBITED (Category 7): Quote juggling corrupts JSON
echo '{"body": "'"$body"'"}' | gh api ... --input -

# ⚠️ NOT RECOMMENDED: jq --arg for body/comment content (long or special-char strings)
jq -n --arg body "$body" '{"body": $body}' | gh api ... --input -
# WHY: --arg receives value via shell variable expansion ($body), subject to ARG_MAX limits
# for large content. Use --rawfile instead which reads directly from file, bypassing
# shell variable expansion entirely.
# NOTE: --arg IS safe for short, predictable values (IDs, timestamps, owner names).
#        This restriction applies only to body/comment content that may contain
#        Markdown, emoji, or multi-line text.
```

---

## Safe Checklist Operation Patterns

Recommended patterns for operating Issue body checklists (`- [ ] task` / `- [x] task`).

**Note**: For checklist **extraction (read-only)**, both pipe usage (`gh ... | grep`) and variable assignment (`body=$(gh ...)`) are safe. For body **updates (writes)**, use the temp file pattern above.

### Checklist Extraction

```bash
# ✅ SAFE: Extract with grep -E (avoid -P option due to environment dependency)
# Read-only pipe operation, no body loss risk
gh issue view {issue_number} -R {owner_repo} --json body --jq '.body' | grep -E '^- \[[ xX]\] '

# Exclude Issue references (distinguish from parent-child Issue Tasklist)
gh issue view {issue_number} -R {owner_repo} --json body --jq '.body' | grep -E '^- \[[ xX]\] ' | grep -v -E '^- \[[ xX]\] #[0-9]+'

# Count incomplete check items (for automated checks, excluding Issue references)
gh issue view {issue_number} -R {owner_repo} --json body --jq '.body' | grep -E '^- \[[ xX]\] ' | grep -v -E '^- \[[ xX]\] #[0-9]+' | grep -c '^- \[ \] '
```

### Checkbox Update

Execute in 3 stages (Bash → Read+Write → Bash). Shell variables do not persist across Bash tool calls, so all of Step 1 (`mktemp` + fetch + validation) must run within a single Bash tool call, and the resulting temp file paths are passed to Step 3 as literals.

> **🔴 CRITICAL**: NEVER use `echo "$body" | sed` for checkbox updates. See [gh CLI Error Catalog - Category 1](./gh-cli-error-catalog.md#category-1-nil-is-not-an-object-http-422--27-sessions).

**Step 1: Bash tool call — Fetch body and validate**

```bash
# Create temp files (for reading and writing)
# Do NOT set an EXIT trap here: Step 1 is its own Bash tool call, so an EXIT trap
# would fire when Step 1 exits and delete the temp files before Step 2's Read tool
# can read them. The files are cleaned up explicitly instead — in Step 3 on success,
# and in the failure branch below on a Step 1 failure.
tmpfile_read=$(mktemp)
tmpfile_write=$(mktemp)

gh issue view {issue_number} -R {owner_repo} --json body --jq '.body' > "$tmpfile_read"

# Validate retrieval result
if [ ! -s "$tmpfile_read" ]; then
  echo "ERROR: Failed to retrieve Issue body" >&2
  rm -f "$tmpfile_read" "$tmpfile_write"
  exit 1  # May be overridden by the calling workflow (pr/open.md / pr/iterate.md 等)
fi

# Output mktemp paths for use in subsequent Read/Write tool calls
echo "tmpfile_read=$tmpfile_read"
echo "tmpfile_write=$tmpfile_write"
```

**Step 2: Read tool + Write tool — Write checkbox-updated body**

1. Read the contents of `$tmpfile_read` (path output by `mktemp` in Step 1) using Claude Code's Read tool
2. Create the full text with `[ ]` → `[x]` updates based on the read content
3. Write the updated body to `$tmpfile_write` (another path output by `mktemp` in Step 1) using Claude Code's Write tool

**Step 3: Bash tool call — Validate and apply**

```bash
# Set paths output by mktemp in Step 1 (shell variables do not carry over between Bash tool calls, so directly write the actual paths from Step 1 output)
tmpfile_read="${TMPDIR:-/tmp}/tmp.XXXXXXXXXX"   # ← Replace with the tmpfile_read= value from Step 1 output (literal path)
tmpfile_write="${TMPDIR:-/tmp}/tmp.XXXXXXXXXX"  # ← Replace with the tmpfile_write= value from Step 1 output (literal path)

# Validate update content before applying
if [ ! -s "$tmpfile_write" ]; then
  echo "ERROR: Updated content is empty" >&2
  rm -f "$tmpfile_read" "$tmpfile_write"
  exit 1
fi

gh issue edit {issue_number} -R {owner_repo} --body-file "$tmpfile_write"

# No EXIT trap is set in Step 1 (it would delete these before Step 2), so clean up here
rm -f "$tmpfile_read" "$tmpfile_write"
```

---

## Shell Escaping Notes

When executing jq or awk commands in a shell, bash's history expansion feature may interpret 「!」 specially, causing unexpected errors. This section covers both jq and awk patterns.

### Problematic Patterns

```bash
# 🚫 PROHIBITED: bash (or Claude Code's shell processing) interprets ! specially, != is not passed correctly to jq
gh api ... --jq '.[] | select(.field != null)'
```

```
jq: error: syntax error, unexpected INVALID_CHARACTER
[.[] | select(.field \!= null)]
```

### Recommended Patterns

```bash
# ✅ OK: Truthiness check (null and false are falsy)
gh api ... --jq '.[] | select(.field)'

# ✅ OK: Negation check using not (equivalent to == null. Alternative, not replacement for != null)
gh api ... --jq '.[] | select(.field | not)'

# ✅ OK: When null comparison is needed, use == null + not as alternative
gh api ... --jq '.[] | select(.field == null | not)'
```

### Rules

| Pattern | Alternative | Notes |
|---------|-------------|-------|
| `select(.field != null)` | `select(.field)` | Null check can be replaced with truthiness (note: `false` values are also excluded) |
| `select(.field != "value")` | `select(.field \| . != "value")` | Via pipe, 「!」 doesn't appear at expression start, making it safe |
| `!= null` in general | Truthiness check | In jq, `null` and `false` are falsy |

### Background

- Bash's history expansion (「!」 special interpretation) can be disabled with `set +H`, but since it depends on the environment when AI executes commands, eliminating jq patterns containing 「!」 from command definitions is more reliable
- Claude Code's internal quoting processing may interpret 「!」 specially even within single quotes

### awk Negation Patterns

> **🚫 MANDATORY RULE**: awk スクリプト内で 「!」 による否定を一切使用してはならない。「!found」, 「!in_section」, 「!/pattern/」 のいずれも禁止。必ず 「== 0」 形式または正論理への書き換えで代替すること。

The same 「!」 issue applies to awk commands. Additionally, 「\!」 is not valid awk syntax. Even bare 「!」 inside single-quoted awk scripts can be misinterpreted by bash or Claude Code's shell processing.

```bash
# 🚫 PROHIBITED: \! is not valid awk syntax; causes "backslash not last character on line"
gh pr diff {pr_number} | awk '/^diff --git/ && \!/pattern/{found=0}'
# → awk: backslash not last character on line

# 🚫 PROHIBITED: bare ! may be misinterpreted by bash history expansion
awk '!found { ... }'       # → DO NOT USE
awk '!in_section { ... }'  # → DO NOT USE
awk '!/pattern/ { ... }'   # → DO NOT USE

# ✅ SAFE: Use == 0 instead of ! for negation
awk 'found == 0 { ... }'
awk 'in_section == 0 { ... }'

# ✅ SAFE: Restructure to avoid negation entirely
gh pr diff {pr_number} -R {owner_repo} | awk '
  /^diff --git/ { found=0 }
  /^diff --git.*target_pattern/ { found=1 }
  found { print }
'
```

| Pattern | Problem | Safe Alternative |
|---------|---------|-----------------|
| `awk '!found'` | Bash may interpret 「!」 | `awk 'found == 0'` |
| `awk '!in_section'` | Bash may interpret 「!」 | `awk 'in_section == 0'` |
| `awk '!/pattern/'` | Bash may interpret 「!」 before awk | Restructure to positive matching |
| `awk '/pat/ && \!/other/'` | 「\!」 is invalid awk syntax | Use positive matching with reset logic |

---

## gh pr diff Constraints

`gh pr diff` が対応していないフラグ（silent failure / error になる）と、その安全な代替:

```bash
# Full diff
gh pr diff {pr_number} -R {owner_repo}

# File list only
gh pr diff {pr_number} -R {owner_repo} --name-only

# 🚫 PROHIBITED: gh pr diff does NOT support -- <files> for per-file filtering
gh pr diff {pr_number} -- path/to/file.md
# → Silently fails or returns unexpected results

# 🚫 PROHIBITED: gh pr diff does NOT support --stat
gh pr diff {pr_number} --stat
# → Error: unknown flag: --stat
# → Use gh pr view --json files to get per-file additions/deletions instead
```

Per-file の diff 抽出は上記「awk Negation Patterns」の reset ロジック（`^diff --git` ヘッダごとに `found=0`、対象パターンで `found=1`）を使う。

## git branch --list Exit-Code Gotcha

> **DO NOT** use exit code (`&&`, `||`, `$?`) to determine branch existence. `git branch --list` always returns exit code 0 regardless of whether a match is found. Check the **output** instead (non-empty = exists).

```bash
# Check local branch existence (check OUTPUT, not exit code)
local_match=$(git branch --list "{branch_name}")
if [ -n "$local_match" ]; then
  echo "BRANCH_EXISTS"
else
  echo "BRANCH_NOT_FOUND"
fi

# Check remote branch existence (check OUTPUT, not exit code)
remote_match=$(git branch -r --list "origin/{branch_name}")
if [ -n "$remote_match" ]; then
  echo "REMOTE_EXISTS"
else
  echo "REMOTE_NOT_FOUND"
fi
```

## Multi-line gh pr create (Canonical Form)

`gh pr create` の複数行形式の正典はバックスラッシュ継続。`hooks/scripts/bash-heaviness-check.sh` の literal-title check は、この形式の継続行を跨いで論理行が終わるまで検査を維持する（インライン特殊文字 title による malformed tool-call の検出のため）:

```bash
# ✅ SAFE: --body-file + backslash continuation
# Note: Fixed string HEREDOC guarantees non-empty content at write time, so empty check (defense layer 2) is omitted. Always add empty check for dynamic generation.
tmpfile=$(mktemp)
trap 'rm -f "$tmpfile"' EXIT

cat <<'BODY_EOF' > "$tmpfile"
初期実装
BODY_EOF

gh pr create \
  -R {owner_repo} \
  --title "{title}" \
  --body-file "$tmpfile" \
  --base "{base_branch}" \
  --draft
```

---

## Work Memory Update Safety Patterns

> **🚫 MANDATORY RULE**: 作業メモリ（`📜 rite 作業メモリ`）の更新時は、以下の安全パターンを必ず適用すること。

> **Note: 2種類の更新パターンについて**
>
> 作業メモリ更新には「**置換型**」と「**追記型**」の2種類がある。それぞれ目的・trap 構成・エラー処理方針が異なる:
>
> | 項目 | 置換型（Python 正規表現置換） | 追記型（printf + cat >> heredoc） |
> |------|-------------------------------|----------------------------------|
> | **用途** | 既存行の値を更新（フェーズ、タイムスタンプ等） | 末尾にセクションを追加（レビュー履歴、メトリクス等） |
> | **trap 構成** | `trap 'rm -f "$tmpfile" "$body_tmp"' EXIT`（`body_tmp` あり） | `trap 'rm -f "$tmpfile"' EXIT`（`body_tmp` なし） |
> | **エラー処理** | non-blocking: WARNING でスキップ（backup sync 用途のため） | blocking: safety check 失敗時は `exit 1` で中断、PATCH 送信失敗時は WARNING（backup 保全済みのため） |
> | **理由** | backup sync の失敗はフロー継続に影響しない | safety check（空body・ヘッダー欠落・サイズ縮小）はデータ不整合を招くため `exit 1`。PATCH ネットワーク失敗は backup が保全済みのため WARNING で継続 |
>
> `body_tmp` は置換型で Python スクリプトの入力ファイルとして使用するため追加される。追記型では `current_body` を直接 `tmpfile` に書き込むため不要。

### 禁止パターン（作業メモリ更新固有）

> 一般的な禁止パターンは [Dangerous Patterns (Prohibited)](#dangerous-patterns-prohibited) および [All Prohibited Alternatives](#all-prohibited-alternatives) を参照。以下は作業メモリ更新に特有の禁止パターンをまとめたものである。
>
> **言語方針**: 本セクションは日本語で記述されている。これは作業メモリ自体が日本語コンテンツを扱うため、禁止パターンの説明も日本語で統一した。一般的な安全パターン（上記リンク先）は英語で記述されている。

以下のパターンは**絶対に使用してはならない**:

| 禁止パターン | 理由 | 代替 |
|-------------|------|------|
| `# Claude が本文をパースし、セッション情報セクションの該当行を更新して PATCH` （コマンド .md ファイル内で自然言語指示のみで PATCH 処理を委任するパターン） | Claude への曖昧な委任。safety check なしで PATCH される危険性 | 明示的な bash コードブロックで: `current_body` 取得 → `jq -n --rawfile` + `--input -` で PATCH。正規表現置換が必要な場合は `python3 -c` で置換後、安全検証 → PATCH |
| `-f body=` | API エラーレスポンスがそのまま body として PATCH される危険性 | `jq -n --rawfile body "$tmpfile" '{"body": $body}'` + `--input -` |
| `sed` で multibyte テキスト処理 | 日本語・emoji でエラーが発生し空 body を PATCH する危険性 | `jq -n --rawfile` + `--input -` パターンによるテキスト処理。正規表現置換が必要な場合は Python インラインスクリプト（`python3 -c '...'`）を使用 |
| PATCH 前に `current_body` 未検証 | API 404 レスポンスがそのまま body として書き込まれる危険性 | 必ず `current_body` の空チェック + ヘッダー検証 + 50% サイズ検証（[Body Length Comparison](#body-length-comparison)）を実施 |

**Prerequisites**: The following shell variables must be set before using these patterns:
- `$current_body`: Current work memory content (retrieved via `gh api`)
- `$updated_tmp`: Path to the temp file containing updated content
- `$issue_number`: Related Issue number (for backup filename)
- `$comment_id`: GitHub comment ID to PATCH

#### 1. Backup Before Update

```bash
# Backup current content before any modification
# backup_file is intentionally excluded from trap — preserved for post-mortem investigation
backup_file="${TMPDIR:-/tmp}/rite-wm-backup-${issue_number}-$(date +%s).md"
printf '%s' "$current_body" > "$backup_file"
```

#### 2. Empty Body Guard

```bash
# Validate updated body is not empty before PATCH
# 10 bytes = minimum plausible work memory content (guards against near-empty corruption,
# e.g., Python script outputting only "\n" which passes -s check)
if [ ! -s "$updated_tmp" ] || [ "$(wc -c < "$updated_tmp")" -lt 10 ]; then
  echo "ERROR: Updated body is empty or too short. Aborting PATCH." >&2
  echo "Backup saved at: $backup_file" >&2
  exit 1
fi
```

#### 3. Content Validation

```bash
# Validate required header is present in updated content
if grep -q '📜 rite 作業メモリ' "$updated_tmp"; then
  : # Header present, proceed
else
  echo "ERROR: Updated body missing work memory header. Restoring from backup." >&2
  cp "$backup_file" "$updated_tmp"
  exit 1
fi
```

#### 3.5. Body Length Comparison

```bash
# Detect significant content loss by comparing original vs updated body size
# Guards against partial overwrites where header is preserved but sections are lost
updated_length=$(wc -c < "$updated_tmp")
if [ "$original_length" -gt 0 ] && [ "$updated_length" -lt $((original_length / 2)) ]; then
  echo "ERROR: Updated body is less than 50% of original size ($updated_length < $original_length/2). Aborting PATCH." >&2
  echo "Backup saved at: $backup_file" >&2
  exit 1
fi
```

> **Note**: `$original_length` は Step 1 で `printf '%s' "$current_body" | wc -c` として取得した値。50% 閾値は、セクション追記による増加は許容しつつ、大幅な内容消失を検出するためのバランス値。

#### 4. Safe Write with Error Handling

```bash
# Update via jq + gh api (backup preserved on failure for manual recovery)
# PATCH 送信失敗時は WARNING で継続（backup が保全されているため復旧可能）
# 注: 追記型・置換型ともに同じパターン。safety check（Step 2-3）の exit 1 とは役割が異なる
jq -n --rawfile body "$updated_tmp" '{"body": $body}' \
    | gh api repos/{owner}/{repo}/issues/comments/"$comment_id" \
      -X PATCH --input - || \
      echo "WARNING: PATCH failed. Backup saved at: $backup_file" >&2
```

---

## Owner/Repo Resolution (SSH Host Alias Safe)

`gh repo view` / `gh issue create` など **`--repo`/`-R` 未指定の gh コマンド**は、origin remote が
SSH host alias（例: `git@github.com-work:owner/repo.git`）のとき
`none of the git remotes configured for this repository point to a known GitHub host` で失敗する。
`{owner}` / `{repo}` プレースホルダの解決には、remote URL を直接パースする
`hooks/scripts/lib/git-remote.sh`（ で導入。host 名に依存しない）を優先し、
`gh repo view` は fallback に回すこと。

```bash
# ✅ SAFE: git-remote.sh 優先で owner/repo を解決（SSH host alias 環境でも動く）
# 出力契約: 成功時 "owner<TAB>repo" の 1 行。失敗時は空 → gh repo view に fallback
owner_repo=$(bash {plugin_root}/hooks/scripts/lib/git-remote.sh resolve-owner-repo 2>/dev/null) || owner_repo=""
owner=""; repo=""
[ -n "$owner_repo" ] && IFS=$'\t' read -r owner repo <<< "$owner_repo"
[ -n "$owner" ] && [ -n "$repo" ] || {
  owner=$(gh repo view --json owner --jq '.owner.login')
  repo=$(gh repo view --json name --jq '.name')
}

# 🚫 PROHIBITED: gh repo view 単独での owner/repo 解決（SSH host alias 環境で失敗する）
# owner=$(gh repo view --json owner --jq '.owner.login')
# WHY: gh は remote URL の host 部（github.com-work 等）を GitHub host として解決できない
```

内部スクリプトでの実装例:
`scripts/watchdog-status-mismatch.sh`（git-remote.sh → gh repo view の 2 段 fallback + 診断 stderr）。

### Propagation to Repo-Context gh Commands (`{owner_repo}`)

解決した owner/repo は「解決箇所」だけで使って終わりにせず、**すべての repo コンテキスト依存
gh コマンド**（`gh pr create/view/list/edit/merge/ready/comment/review/diff/checks` /
`gh issue view/list/edit/comment/create/close/reopen/develop` 等）へ `-R` で明示指定する。
`-R` 指定があれば gh は remote の host 解決を行わないため、SSH host alias 環境でも動く。

実行スニペットでの伝播は次の 2 形式のいずれかを使う:

1. **シェル変数が同一ブロックで解決済み** — canonical スニペット（上記）の直後で使う形式:

   ```bash
   gh issue view {issue_number} -R "$owner/$repo" --json body
   ```

2. **`{owner_repo}` プレースホルダ** — `{plugin_root}` と同じ literal substitution 方式。
   セッション内で一度 canonical スニペット（上記）を実行して `owner/repo`（slash 形式、
   例: `myorg/myrepo`）を解決し、以降の実行ブロックでは `-R {owner_repo}` をその値で
   リテラル置換してから実行する。同一ブロックへの解決スニペット複製が不要になるため、
   単発の gh コマンドにはこちらを優先する:

   ```bash
   gh pr view {pr_number} -R {owner_repo} --json state
   ```

   > **⚠️ 注意（名前衝突）**: canonical スニペット（上記）の shell 変数 `$owner_repo` は
   > **TAB 区切り**（`git-remote.sh` の出力契約 `owner<TAB>repo`）であり、`{owner_repo}`
   > プレースホルダ（**slash 形式** `owner/repo`）とは別物。`-R "$owner_repo"` と shell 変数値を
   > そのまま渡してはならない（TAB のまま渡ると gh が `expected the "[HOST/]OWNER/REPO" format`
   > で失敗する）。shell 変数から slash 形式を組むときは必ず `-R "$owner/$repo"` を使うこと。

適用除外: 🚫 PROHIBITED 例・エラーカタログの失敗再現例（失敗の再現自体が目的のコマンド）には
`-R` を付与しない（付与すると例の意味が壊れる）。**reviewer agent 定義**（`agents/*-reviewer.md`）も
適用除外 — spawn される reviewer subagent は `{plugin_root}` / `{owner_repo}` を解決する経路を持たない
（user prompt には diff / spec / shared principles のみが渡る）ため、`-R {owner_repo}` を付与すると
literal のまま実行され逆に回帰する。reviewer は repo cwd で動くため gh の remote 推論に任せる。

`gh pr view` への `-R` 伝播では selector（PR 番号または branch 名）を必ず併記する — gh は
`-R` 指定時に selector を必須とする（`argument required when using the --repo flag`）ため、
selector なしの `gh pr view` に `-R` だけを足すと必ず失敗する。現在ブランチの PR を対象に
する場合は `gh pr view "$(git branch --show-current)" -R {owner_repo}` の形を使う。

---

## Extended References

For error pattern catalog, see: [`gh-cli-error-catalog.md`](./gh-cli-error-catalog.md)

For GraphQL query patterns, see: [`graphql-helpers.md`](./graphql-helpers.md)
