# Archive Procedures (Cleanup ステップ 8-11)

> **Charter**: Subject to [Simplification Charter](../../../skills/rite-workflow/references/simplification-charter.md). Runtime に効かない経緯記述は書かない。

> **Source**: Extracted from `cleanup.md` ステップ 8-11 (旧 Phase 3-4 構造から flat 化済)。This file is the source of truth for Projects Status Update, Issue close, Parent Issue handling, and state reset procedures. 本ファイル内部の `## Phase 3` / `## Phase 4` 階層 heading は本 sub-document 独自の構造で、cleanup.md 側 caller は新「ステップ N」表記で参照する (双方向リンク互換: caller=ステップ N / callee=本ファイル内部 Phase。Phase N が cleanup.md に存在しなくても本ファイル内 anchor として valid)。

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

> **Source of truth**: This phase delegates to `plugins/rite/scripts/projects-status-update.sh` — the same shared script used by `skills/open/SKILL.md` ステップ 2.4 / `skills/ready/SKILL.md` Phase 4 / `skills/issue-close/SKILL.md`。

Skip Phase 3.2 if `github.projects.enabled: false` in `rite-config.yml` or if no related Issue was identified in `cleanup.md` ステップ 2, and proceed to Phase 3.5 (work memory update). Otherwise, invoke the shared script to transition the Issue Status to **Done**:

```bash
status_json_args=$(jq -n \
  --argjson issue {issue_number} \
  --arg owner "{owner}" \
  --arg repo "{repo}" \
  --argjson project_number {project_number} \
  --arg status "Done" \
  --argjson auto_add false \
  --argjson non_blocking true \
  '{issue_number:$issue, owner:$owner, repo:$repo, project_number:$project_number, status_name:$status, auto_add:$auto_add, non_blocking:$non_blocking}')
bash {plugin_root}/scripts/projects-status-update.sh "$status_json_args"
```

`auto_add: false` because by cleanup time the Issue is already registered in the Project (`skills/open/SKILL.md` ステップ 2.4 auto-added it if missing).

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

Track the final success/failure of the Projects Status update for inclusion in the cleanup.md ステップ 12 (完了報告):

**Result variable:**
- `projects_status_updated` = `false` (default). Set to `true` only when Phase 3.2 returns `.result == "updated"`.

When Phase 3.2 returns `.result == "skipped_not_in_project"` or `"failed"`, `projects_status_updated` retains its default `false` value and the failure has already been surfaced via the `.warnings[]` lines + manual recovery hint above.

The LLM retains `projects_status_updated` in conversation context. cleanup.md ステップ 12 (完了報告) で `{projects_check}` / `{projects_status_result}` placeholder を介して Projects Status 更新結果を条件付き表示するために本値を参照する (see `cleanup.md` ステップ 12)。

**Bash 実装パターン** (LLM 向け実装ヒント — Phase 3.2 の `bash {plugin_root}/scripts/projects-status-update.sh "$status_json_args"` 行を以下のように書き換える):

```bash
# jq 2>/dev/null 抑制 / `failed|*)` catch-all により script が JSON-emit 前に死んだ場合も
# silent fall-through を防ぐ。`|| status_json=""` は付けない — このブロックに set -e はなく、
# command substitution は script が非ゼロ終了しても stdout (script が既に出力した失敗理由入り
# JSON) を正しく capture するため、fallback を付けるとその診断情報を空文字列で上書き・破棄してしまう
status_json=$(bash {plugin_root}/scripts/projects-status-update.sh "$status_json_args")
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
    [ -n "$status_warning_lines" ] && printf '%s\n' "$status_warning_lines" | sed 's/^/  /' >&2
    echo "警告: Projects Status の \"Done\" への更新に失敗しました。手動で更新する場合: gh project item-edit --project-id <project_id> --id <item_id> --field-id <status_field_id> --single-select-option-id <done_option_id>" >&2
    ;;
esac
# projects_status_updated を cleanup.md ステップ 12 (完了報告) で参照するため context-local に保持する
```

完全な bash 実装サンプルは `skills/issue-close/SKILL.md` Phase 4.6.3 (parent Issue Done 更新の unified block) を参照すること (state machine + signal-specific trap + tempfile + Step 3 inconsistency summary を含む完全形)。

### 3.5 Automatic Final Update of Work Memory

If a work memory comment exists on the Issue, automatically append a completion record.

#### 3.5.1 Retrieve and Update Work Memory Comment

完了情報の追記は `issue-comment-wm-sync.sh` の `append-eof` transform へ委譲する（canonical caller パターン: `skills/pr-create/SKILL.md` 4.1.2 / `skills/fix/SKILL.md` 4.5.2）。comment 取得・backup・空body/ヘッダー/50% safety check・PATCH は helper 内部で完結するため、cleanup 側は完了情報の content-file を生成して helper を呼び、機械可読な `status=...` 行を読むだけでよい。

`### 完了情報` は WM 初期テンプレに存在しない**新規セクション**のため、既存セクション専用の `append-section`（不在時 no-op）ではなく EOF へ raw 追記する `append-eof` を用いる（原 inline 実装の heredoc 追記挙動を再現。末尾改行は `\n\n` セパレータに正規化する意図的差異があるが、レンダリング結果は同一）。

```bash
# 完了情報セクションを content-file に生成し append-eof transform で委譲追記する。
# {merged_at} 等は cleanup.md コンテキストの実値で置換する（heredoc malform 回避のため printf を使用）。
completion_tmp=$(mktemp)
# helper stderr（auth/rate/network/safety-check 詳細 + backup path）を退避し、失敗時に surface する。
# canonical caller fix.md 4.5.2 / pr-review.md 6.2 と同じ stderr-capture 規約（2>/dev/null 破棄をしない）。
wm_sync_err=$(mktemp 2>/dev/null) || wm_sync_err=""
trap 'rm -f "$completion_tmp" "${wm_sync_err:-}"' EXIT
printf '%s\n' \
  "### 完了情報" \
  "- **マージ日時**: {merged_at}" \
  "- **PR**: #{pr_number} - {pr_title}" \
  "- **PR URL**: {pr_url}" \
  "- **クリーンアップ完了**: {timestamp}" \
  "- **削除したブランチ**: {branch_name}" \
  "- **最終 Status**: Done" > "$completion_tmp"

wm_status=$(bash {plugin_root}/hooks/issue-comment-wm-sync.sh update \
  --issue {issue_number} \
  --transform append-eof --content-file "$completion_tmp" 2>"${wm_sync_err:-/dev/null}") || true
rm -f "$completion_tmp"

# 非ブロッキング: cleanup は work memory 更新失敗で停止してはならない（§3.5 は automatic final update）。
# no_comment（作業メモリ不在 = legitimate no-op）以外の skipped/error は WARNING 表示にとどめる。
# 失敗時は helper stderr の root-cause（先頭 5 行）も surface し、backup path / API エラー詳細を operator に残す。
case "$wm_status" in
  status=success)      echo "作業メモリに完了情報を追記しました" ;;
  *reason=no_comment*) echo "作業メモリ comment が無いため完了情報の追記をスキップしました" ;;
  *)                   echo "警告: 作業メモリ更新が完了しませんでした (${wm_status:-no-status})。cleanup は続行します。" >&2
                       [ -n "$wm_sync_err" ] && [ -s "$wm_sync_err" ] && { echo "  helper stderr (root-cause、先頭 5 行):" >&2; head -5 "$wm_sync_err" | sed 's/^/    /' >&2; } ;;
esac
rm -f "${wm_sync_err:-}"
```

**Note for Claude**: comment 取得・body 変換・safety check・PATCH・backup はすべて helper 内部で完結するため、本ブロックを単一 Bash 呼び出しに収める必要はない（旧 inline 実装のクロスプロセス変数参照制約は解消済み）。`{merged_at}` / `{pr_number}` / `{pr_title}` / `{pr_url}` / `{timestamp}` / `{branch_name}` を cleanup.md コンテキストの実値で置換すること。`{plugin_root}` はリテラル値で埋め込む。

#### 3.5.2 Update Content

> **委譲状況（完了）**: §3.5.1（`### 完了情報` の `append-eof` 追記）に続き、本節の **進捗チェックリスト merge**（`### 進捗サマリー` への dedup 追記）も `issue-comment-wm-sync.sh` の `merge-checklist` transform へ委譲済み。cleanup ステップ 11 が §3.5 全体を実行する経路で wired され、§3.5.1（完了情報）とは独立した fetch→transform→PATCH として走る（touch するセクションが異なるため順序非依存）。

Automatically append the following to the work memory:

**Progress section merge method:**

The progress section update in Phase 3.5.2 follows this logic（`merge-checklist` transform 内 Python が担う）:

1. Retrieve the existing progress section (`### 進捗サマリー` — 現行 WM テンプレの見出し。SoT: `work-memory-format.md` / init テンプレ)
2. Preserve all existing content (table rows / checklist items)
3. Append new items (`- [x] レビュー完了`, `- [x] マージ完了`, `- [x] クリーンアップ完了`) at the end of the section (do not duplicate if already present anywhere in the body — full-line exact match, 冪等)
4. When the target section is absent **and** new items remain, helper returns `status=skipped; reason=section_absent` (items are **not** dropped silently, and the caller does **not** report success — Issue #2139)

**Example:**

```markdown
### 進捗サマリー

| 項目 | 状態 | 備考 |
|------|------|------|
| 実装 | ✅ 完了 | - |
| テスト | ✅ 完了 | - |
| ドキュメント | ✅ 完了 | - |
- [x] レビュー完了           ← Phase 3.5.2 で追加
- [x] マージ完了             ← Phase 3.5.2 で追加
- [x] クリーンアップ完了     ← Phase 3.5.2 で追加
```

**Bash implementation (helper 委譲):**

進捗チェックリストの完了項目を `merge-checklist` transform で委譲追記する。全文・完全行 dedup（既出項目スキップ＝冪等）・`### 進捗サマリー` セクション末尾への挿入・backup・空body/ヘッダー/safety check・PATCH はすべて helper 内部で完結する（§3.5.1 と同じ canonical caller パターン）。`--section` は必須（欠けると Python が usage error → `status=error; reason=transform_failed`）。

```bash
# 進捗セクションの完了項目を content-file に生成し merge-checklist transform で委譲追記する。
# {issue_number} は cleanup.md コンテキストの実値で置換する（heredoc malform 回避のため printf を使用）。
progress_tmp=$(mktemp)
# helper stderr（auth/rate/network/safety-check 詳細 + backup path）を退避し、失敗時に surface する。
# canonical caller §3.5.1 / fix.md 4.5.2 と同じ stderr-capture 規約（2>/dev/null 破棄をしない）。
wm_sync_err=$(mktemp 2>/dev/null) || wm_sync_err=""
trap 'rm -f "$progress_tmp" "${wm_sync_err:-}"' EXIT
printf '%s\n' \
  "- [x] レビュー完了" \
  "- [x] マージ完了" \
  "- [x] クリーンアップ完了" > "$progress_tmp"

wm_progress_status=$(bash {plugin_root}/hooks/issue-comment-wm-sync.sh update \
  --issue {issue_number} \
  --transform merge-checklist --section 進捗サマリー --content-file "$progress_tmp" 2>"${wm_sync_err:-/dev/null}") || true
rm -f "$progress_tmp"

# 非ブロッキング: cleanup は work memory 更新失敗で停止してはならない（§3.5 は automatic final update）。
# no_comment / section_absent は legitimate skip（success と区別して表示）。その他の skipped/error は WARNING。
# 失敗時は helper stderr の root-cause（先頭 5 行）も surface し、backup path / API エラー詳細を operator に残す。
case "$wm_progress_status" in
  status=success)              echo "作業メモリの進捗セクションを更新しました" ;;
  *reason=no_comment*)         echo "作業メモリ comment が無いため進捗更新をスキップしました" ;;
  *reason=section_absent*)     echo "作業メモリに対象セクション（進捗サマリー）が無いため進捗チェックリスト統合をスキップしました" ;;
  *)                           echo "警告: 作業メモリ進捗更新が完了しませんでした (${wm_progress_status:-no-status})。cleanup は続行します。" >&2
                               [ -n "$wm_sync_err" ] && [ -s "$wm_sync_err" ] && { echo "  helper stderr (root-cause、先頭 5 行):" >&2; head -5 "$wm_sync_err" | sed 's/^/    /' >&2; } ;;
esac
rm -f "${wm_sync_err:-}"
```

**Note for Claude**: comment 取得・body 変換（全文 dedup + `### 進捗サマリー` セクション末尾挿入）・safety check・PATCH・backup はすべて helper 内部で完結するため、本ブロックを単一 Bash 呼び出しに収める必要はない。`{plugin_root}` はリテラル値で埋め込み、`{issue_number}` を cleanup.md コンテキストの実値で置換すること。対象セクション不在時は items を破棄せず `status=skipped; reason=section_absent` を返す（`status=success` と報告しない — fail-loud、Issue #2139）。参照: §3.5.1 の canonical caller パターン。

> **適用範囲の注記**: 対象見出しは現行 default WM フォーマットの `### 進捗サマリー`（table + 任意の checklist 追記）である（SoT: `skills/rite-workflow/references/work-memory-format.md`、init テンプレ: `issue-comment-wm-sync.sh`）。v1 legacy の `### 進捗` のみを持つ body では `section_absent` となり skip 表示される（旧「silent no-op success」は廃止）。v1 への互換フォールバックは持たない（実運用の init 経路は常に `進捗サマリー` を生成する）。

**Standard update template:**

```markdown
### 進捗サマリー

| 項目 | 状態 | 備考 |
|------|------|------|
| 実装 | ✅ 完了 | - |
| テスト | ✅ 完了 | - |
| ドキュメント | ✅ 完了 | - |
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

Close the related Issue identified in `cleanup.md` ステップ 2.

> 以下の実行スニペットの `-R {owner_repo}` は、[Owner/Repo Resolution](../../../references/gh-cli-patterns.md#ownerrepo-resolution-ssh-host-alias-safe)（cleanup.md ステップ 1.4 と同一の canonical 手順）で解決した owner/repo（slash 形式）をリテラル置換する（SSH host alias 環境対応）。

#### 3.6.1 Check Issue State

If a related Issue has been identified, check its current state:

```bash
gh issue view {issue_number} -R {owner_repo} --json state --jq '.state'
```

#### 3.6.2 Close the Issue

If the Issue is OPEN, execute the close:

```bash
gh issue close {issue_number} -R {owner_repo} --comment "PR #{pr_number} のマージに伴いクローズしました。"
```

**Note**: `gh issue close` does not error when executed on an already-closed Issue (idempotent).

#### 3.6.3 Processing Branch by Condition

| Condition | Processing | Message |
|-----------|-----------|---------|
| Issue is OPEN | Execute close | `Issue #{issue_number} をクローズしました` |
| Issue is already CLOSED | Skip | (No message, no warning needed) |
| Related Issue was not identified | Skip | `警告: 関連 Issue が見つかりません` |

### 3.6.4 Update Parent Issue Tasklist Checkbox

**Execution condition**: Only executed when a parent Issue was detected in `cleanup.md` ステップ 2.

When a child Issue's PR is merged and cleanup runs, update the parent Issue's Tasklist checkbox for this child Issue from `- [ ]` to `- [x]`.

#### 3.6.4.1 Replace Checkbox

Replace `- [ ] #{issue_number}` with `- [x] #{issue_number}` in the parent Issue body. The pattern matches any text after the Issue number on the same line (e.g., `- [ ] #661 - description text`).

**Implementation**: Use the 3-step pattern (Bash → Read+Write → Bash) per [gh-cli-patterns.md](../../../references/gh-cli-patterns.md).

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

**Execution condition**: Only executed when a parent Issue was detected in `cleanup.md` ステップ 2.

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

Skip this substep if `github.projects.enabled: false` in `rite-config.yml` and proceed to 3.7.2.2 (close processing). Otherwise, invoke the shared script to transition the parent Issue Status to **Done** (same delegate pattern as Phase 3.2):

```bash
status_json_args=$(jq -n \
  --argjson issue {parent_issue_number} \
  --arg owner "{owner}" \
  --arg repo "{repo}" \
  --argjson project_number {project_number} \
  --arg status "Done" \
  --argjson auto_add false \
  --argjson non_blocking true \
  '{issue_number:$issue, owner:$owner, repo:$repo, project_number:$project_number, status_name:$status, auto_add:$auto_add, non_blocking:$non_blocking}')
bash {plugin_root}/scripts/projects-status-update.sh "$status_json_args"
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
> # `|| status_json=""` は付けない — command substitution は script が非ゼロ終了しても stdout
> # (script が既に出力した失敗理由入り JSON) を capture するため、fallback は診断情報を破棄する
> status_json=$(bash {plugin_root}/scripts/projects-status-update.sh "$status_json_args")
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
> **完全形 (state machine + signal-specific trap + tempfile + 一体化された inconsistency summary)** が必要な場合は `skills/issue-close/SKILL.md` Phase 4.6.3 を参照 (Issue close と Status update を unified block で扱う)。

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

gh issue comment {parent_issue_number} -R {owner_repo} --body-file "$tmpfile"
```

**Step 2: Close with short fixed string**

```bash
gh issue close {parent_issue_number} -R {owner_repo} --comment "すべての子 Issue 完了のため自動クローズ"
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
gh issue close {parent_issue_number} -R {owner_repo}
```

**Note**: Failure to auto-close the parent Issue does not block the entire cleanup process. Display a warning and continue.

---

## Phase 4: Reset State and Delete Local Work Memory

### Fail-Closed Gate (Post-Condition Check)

Before resetting state, check for residual work memory files. If Phase 3 (Projects Status Update) completed but Phase 4 was skipped, this ensures work memory files are still cleaned up.

```bash
# Phase 4 開始前: 作業メモリファイル残存チェック
if ls .rite-work-memory/issue-*.md 1>/dev/null 2>&1; then
  echo "WARNING: 作業メモリファイルが残存しています。cleanup-work-memory.sh を実行します。"
  bash {plugin_root}/hooks/cleanup-work-memory.sh
fi
```

Resolve `{plugin_root}` per [Plugin Path Resolution](../../../references/plugin-path-resolution.md#resolution-script-full-version) if not already resolved.

**Note**: This is a defense-in-depth mechanism. If Phase 4 executes correctly, this check is a no-op.

After the Fail-Closed Gate, run the cleanup-work-memory script. This script performs all cleanup steps in a single deterministic invocation:

1. Resets flow state to `active: false` (prevents `post-tool-wm-sync.sh` from recreating files)
2. Deletes the per-session compact-state (`.rite/sessions/{session_id}.compact-state`) and its lockdir, plus the legacy shared `.rite-compact-state` and lockdir (retained for migration)
3. Deletes ALL `.rite-work-memory/issue-*.md` files and their lockdirs (both current Issue and stale leftovers)
4. Reports deletion results (deleted/failed/remaining counts)

Resolve `{plugin_root}` per [Plugin Path Resolution](../../../references/plugin-path-resolution.md#resolution-script-full-version) if not already resolved.

```bash
bash {plugin_root}/hooks/cleanup-work-memory.sh
```

**Key design**: The script resets flow state to `active: false` **before** deleting files. This ordering prevents the `post-tool-wm-sync.sh` PostToolUse hook from recreating files after deletion (the hook checks `active == true` and exits early when false). The script reads the issue number directly from the flow state file, eliminating LLM placeholder substitution dependency.

**Error handling:**

| Error Case | Response |
|-----------|----------|
| flow state reset fails | Script displays WARNING to stderr and continues with file deletion |
| File deletion fails | Script displays WARNING to stderr per file and continues |
| `.rite-work-memory/` does not exist | No error (script handles gracefully) |
| Script itself fails | Display warning and proceed to cleanup.md ステップ 12 (non-blocking) |

**Warning message on script failure:**

```
警告: 作業メモリクリーンアップスクリプトが失敗しました
手動でリセットする場合: flow state file を削除するか active を false に変更し、.rite-work-memory/issue-*.md を手動削除してください
```

**Note**: Failure does not block the cleanup process. Display a warning and proceed to cleanup.md ステップ 12.

**Do NOT delete** the `.rite-work-memory/` directory itself — the script preserves it.

---

