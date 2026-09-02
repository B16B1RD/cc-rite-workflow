---
name: issue-close
description: |
  rite workflow の Issue 完了確認スキル: Issue の完了状態を確認しクローズする。
  ユーザーが明示的に /rite:issue-close で起動する。auto-activate しない。
  起動: /rite:issue-close <issue_number>
argument-hint: "<issue_number>"
---

# /rite:issue-close

Check the completion status of an Issue and guide necessary actions.

> **Charter**: This command is subject to the [Simplification Charter](../../skills/rite-workflow/references/simplification-charter.md). Runtime に効かない経緯記述・cycle 番号引用・重複 confirmation は書かない。

---

## Arguments

| Argument | Description |
|------|------|
| `<issue_number>` | Issue number to check (required) |

---

## Shared: Projects Status → Done (delegate pattern)

Phase 1.3.2 / 4.2 / 4.6.3 / `skip_already_closed` + `proceed_to_confirmation`（全子 CLOSED かつ `NOT_PLANNED` なし）は Projects Status を **Done** に更新する。`projects-status-update.sh` に委譲する（`skills/open/SKILL.md` ステップ 2.4 / `skills/ready/SKILL.md` Phase 4 と同一）。冪等。API 詳細は [projects-integration.md §2.4](../../references/projects-integration.md#24-github-projects-status-update)。
rationale: references/rationale.md#projects-status-delegate

**委譲呼び出し**（`{issue}` は対象 Issue 番号、`auto_add false`・`non_blocking true`）:

```bash
status_json_args=$(jq -n \
  --argjson issue {issue} --arg owner "{owner}" --arg repo "{repo}" \
  --argjson project_number {project_number} --arg status "Done" \
  --argjson auto_add false --argjson non_blocking true \
  '{issue_number:$issue, owner:$owner, repo:$repo, project_number:$project_number, status_name:$status, auto_add:$auto_add, non_blocking:$non_blocking}')
bash {plugin_root}/scripts/projects-status-update.sh "$status_json_args"
```

**`.result` による分岐**（全分岐 non-blocking — Status 更新失敗は close フローを止めない）:

| `.result` | 表示 |
|-----------|------|
| `"updated"` | `Projects Status を "Done" に更新しました`（冪等のため既 Done も updated になる） |
| `"skipped_not_in_project"` | `警告: Issue #{issue} は Project に登録されていません` |
| `"skipped_terminal_conflict"` | `警告: Issue #{issue} は既に終端 Status (Cancelled) のため Done への上書きをスキップしました`（`.warnings[]` も stderr に出す。item-edit 復旧は案内しない） |
| `"failed"` | `.warnings[]` を stderr に出し、`警告: Projects Status の "Done" 更新に失敗。手動: GitHub Projects 画面で Status を Done に変更、または gh project item-edit ...` |

---

## Phase 1: Check Issue Status

### 1.1 Retrieve Issue Information

> `{owner_repo}` は [Owner/Repo Resolution](../../references/gh-cli-patterns.md#ownerrepo-resolution-ssh-host-alias-safe) で解決した owner/repo（slash 形式）を literal substitute する。

```bash
gh issue view {issue_number} -R {owner_repo} --json number,title,body,state,labels,closedAt
```

### 1.2 Determine Issue State

**Issue が既にクローズ済みの場合:**

```
Issue #{number} は既にクローズされています

タイトル: {title}
クローズ日時: {closed_at}

追加のアクションは不要です
```

→ Phase 1.3 へ。**Open の場合**は Phase 2 へ。

---

## Phase 1.3: Projects Status Sync for Already-Closed Issues

Issue が既にクローズ済みでも Projects Status が "Done" でない場合（rite 外でクローズされた等）に同期する。

### 1.3.1 Projects Enabled Check

Read tool で `rite-config.yml` の `github.projects.enabled` を確認。`false`（または未設定）なら本 Phase をスキップして Phase 5 へ。

### 1.3.2 Update Status

[Shared: Projects Status → Done](#shared-projects-status--done-delegate-pattern) を実行する（`{issue}` = `{issue_number}`、`auto_add false`）。結果は共通テーブル。いずれも Phase 5（non-blocking）。
rationale: references/rationale.md#auto-add-false-closed

---

## Phase 2: Search for Linked PRs

### 2.1 Search for Related PRs

```bash
gh pr list -R {owner_repo} --state all --search "linked:issue:{issue_number}" --json number,title,state,mergedAt,url
```

見つからなければ PR body の close キーワードを検索する:

```bash
gh pr list -R {owner_repo} --state all --json number,title,state,body,mergedAt,url
```

body が `Closes/Fixes/Resolves #{issue_number}`（大文字小文字とも）を含むか確認する。

### 2.2 Search PRs by Branch Name

```bash
gh pr list -R {owner_repo} --state all --head "*issue-{issue_number}*" --json number,title,state,mergedAt,url
```

### 2.3 Aggregate Search Results

| # | タイトル | 状態 | マージ日時 |
|---|---------|------|----------|
| #{pr_number} | {pr_title} | {state} | {merged_at} |

---

## Phase 3: Auto-Close Determination

### 3.1 Auto-Close Conditions

Issue が自動クローズされる条件: (1) リンク PR の body に `Closes/Fixes/Resolves #XXX` が含まれ、(2) その PR がマージ済み。

### 3.2 Determination Results by Scenario

#### Pattern A: Already Auto-Closed (or Scheduled)

リンク PR がマージ済みかつ close キーワードを含む場合:

```
Issue #{number} は自動的にクローズされます

紐づく PR:
- #{pr_number}: {pr_title} (Merged)

GitHub のキーワード連携により、PR マージ時に Issue は自動クローズされます
追加のアクションは不要です
```

#### Pattern B: PR Exists but No Auto-Close

リンク PR はあるが close キーワードが無い場合:

```
Issue #{number} に紐づく PR がありますが、自動クローズは設定されていません

紐づく PR:
- #{pr_number}: {pr_title} ({state})

推奨アクション:
1. PR 本文に "Closes #{number}" を追加してマージ
2. 手動で Issue をクローズ
```

#### Pattern C: PR Awaiting Merge

リンク PR が open の場合:

```
Issue #{number} に紐づく PR がマージ待ちです

紐づく PR:
- #{pr_number}: {pr_title} (Open)
  URL: {pr_url}

推奨アクション:
1. PR をレビュー・マージ
2. マージ後、Issue は自動的にクローズされます
```

#### Pattern D: No PR Found

関連 PR が無い場合:

```
Issue #{number} に紐づく PR が見つかりません
```

`AskUserQuestion` で次のアクションを確認する:

```
どのアクションを実行しますか？

オプション:
- PR を作成する (/rite:pr-create)
- Issue を手動でクローズする（gh issue close {number} -R {owner_repo}）
- 何もしない
```

---

## Phase 4: Execute Actions

### 4.1 Execute Manual Close

ユーザーが手動クローズを選択した場合:

```bash
gh issue close {issue_number} -R {owner_repo}
```

### 4.2 Update Projects Status

`github.projects.enabled: false` なら Phase 4.3 へ。そうでなければ [Shared: Projects Status → Done](#shared-projects-status--done-delegate-pattern)（`{issue}` = `{issue_number}`、`auto_add false`）。いずれも Phase 4.3（non-blocking）。
rationale: references/rationale.md#auto-add-false-closed

### 4.3 Update Local Work Memory

Phase 5 の削除前に完了状態をローカル作業メモリに記録する:

```bash
WM_SOURCE="close" \
  WM_PHASE="completed" \
  WM_PHASE_DETAIL="Issue クローズ完了" \
  WM_NEXT_ACTION="なし" \
  WM_BODY_TEXT="Issue closed." \
  WM_ISSUE_NUMBER="{issue_number}" \
  bash {plugin_root}/hooks/local-wm-update.sh 2>/dev/null || true
```

lock 失敗は WARNING して続行（best-effort）。Issue comment backup は不要（archival は `rite:cleanup` Phase 4.5）。

### 4.4 Completion Report

Phase 4.2 が retain した Shared `.result` で Status 行を分岐する。`projects.enabled: false` で 4.2 を skip したときは Status 行を省略する。

| 4.2 `.result` | Status 行 |
|---------------|-----------|
| `updated` | `Status: Done` |
| `skipped_terminal_conflict` | `Status: Cancelled` |
| `failed` | `Status: 更新失敗` |
| `skipped_not_in_project` | Status 行なし（Done を主張しない） |

`.result=updated`:
```
Issue #{number} をクローズしました

タイトル: {title}
Status: Done

関連 PR: #{pr_number} (Merged)
```

`.result=skipped_terminal_conflict`:
```
Issue #{number} をクローズしました

タイトル: {title}
Status: Cancelled

関連 PR: #{pr_number} (Merged)
```

`.result=failed`:
```
Issue #{number} をクローズしました

タイトル: {title}
Status: 更新失敗

関連 PR: #{pr_number} (Merged)
```

`.result=skipped_not_in_project`:
```
Issue #{number} をクローズしました

タイトル: {title}

関連 PR: #{pr_number} (Merged)
```

→ Phase 4.4.W へ。

### 4.4.W Wiki Ingest Trigger (Conditional)

> **Reference**: [Wiki Ingest](../wiki-ingest/SKILL.md) — `wiki-ingest-trigger.sh` API。本 Phase は raw の **蓄積**。page 統合は `/rite:wiki-ingest`。
> rationale: references/rationale.md#wiki-raw-page-split

> **⚠️ E2E Mandatory**: 出力最小化で skip しない。正当な skip は Step 1 の config のみ（`WIKI_INGEST_SKIPPED=1` + WARNING を必ず emit）。

**Step 1**: Wiki 設定を確認する（`wiki.enabled` opt-out default true / `wiki.auto_ingest` default false）:

```bash
# YAML 読み取りは canonical helper (実ファイル) に委譲する。skill 本文の fenced bash に
# パーサを書くと Skill loader が位置パラメータを起動引数へ展開し、行マッチが恒偽化して
# 全キーが空になる (静的検出: hooks/scripts/dollar-zero-check.sh)。
wiki_enabled="true"; auto_ingest="false"; reason=""
if . {plugin_root}/hooks/scripts/lib/wiki-config.sh 2>/dev/null; then
  wiki_enabled=$(parse_wiki_scalar enabled | tr '[:upper:]' '[:lower:]')
  auto_ingest=$(parse_wiki_scalar auto_ingest | tr '[:upper:]' '[:lower:]')
  case "$wiki_enabled" in false|no|0) wiki_enabled="false" ;; *) wiki_enabled="true" ;; esac
  case "$auto_ingest" in true|yes|1) auto_ingest="true" ;; *) auto_ingest="false" ;; esac
else
  # helper 不在は実失敗。opt-out default に吸収させると「実失敗を正常スキップと誤報告する」
  # 経路を再現するため、専用 reason で surface する。
  echo "WARNING: {plugin_root}/hooks/scripts/lib/wiki-config.sh を読み込めません。Wiki 設定を判定できないため raw source 蓄積を skip します" >&2
  reason="config_helper_unavailable"
fi

[ -z "$reason" ] && [ "$wiki_enabled" = "false" ] && reason="disabled"
[ -z "$reason" ] && [ "$auto_ingest" = "false" ] && reason="auto_ingest_off"
if [ -n "$reason" ]; then
  echo "[CONTEXT] WIKI_INGEST_SKIPPED=1; reason=$reason"
  echo "WARNING: close Phase 4.4.W Wiki ingest skipped: $reason" >&2
fi
echo "wiki_enabled=$wiki_enabled auto_ingest=$auto_ingest reason=${reason:-<run>}"
```

`reason` が非空なら Step 2 / Phase 4.4.W.2 をスキップして Phase 4.5 へ。

**Step 2**: Issue コンテキストから retrospective Raw Source を生成する。`wiki-ingest-trigger.sh` は `--content-file` に `$PWD` 配下・`/tmp/rite-*`・`$TMPDIR/rite-*` prefix のみを受容する（mktemp デフォルトの `${TMPDIR:-/tmp}/tmp.*` では silent fail する）:

```bash
tmpfile=$(mktemp "${TMPDIR:-/tmp}/rite-wiki-content-XXXXXX")
trigger_stderr=$(mktemp "${TMPDIR:-/tmp}/rite-wiki-trigger-err-XXXXXX") || trigger_stderr=/dev/null
trap 'rm -f "$tmpfile"; [ "$trigger_stderr" != "/dev/null" ] && rm -f "$trigger_stderr"' EXIT

# heredoc content write 失敗を成功扱いしないガード (pr-review.md 6.5.W / fix.md 4.6.W と対称)。
# /tmp full / permission 拒否 / inode 枯渇で tmpfile への write が truncate された場合、
# truncated content を silent に wiki ingest するのを防ぐ。
# close.md は Step 2 (heredoc) と trigger 呼び出しが単一 bash ブロックのため、
# content_write_failed を同ブロック内で参照でき cross-invocation carry-forward は不要
# (pr-review.md/fix.md は Step 2/Step 3 が別 bash 呼び出しのため carry-forward が必要 — 唯一の構造差)。
content_write_failed=0
if ! cat <<'RETRO_EOF' > "$tmpfile"
## Issue Close Retrospective

- **Issue**: #{issue_number} — {title}
- **Type**: retrospective
- **Closed at**: {timestamp}

### Summary
{retrospective_summary — Issue の作業中に学んだこと、予想外の困難、有効だったアプローチを LLM が Issue body + work memory から要約して埋め込む}
RETRO_EOF
then
  echo "[CONTEXT] WIKI_CONTENT_WRITE_FAILED=1; reason=cat_redirection_failed" >&2
  echo "WARNING: close Phase 4.4.W retrospective content の tmpfile write に失敗しました (/tmp 容量 / permission / inode 枯渇)。truncated content の wiki ingest を防ぐため trigger をスキップします" >&2
  content_write_failed=1
fi

if [ "$content_write_failed" -eq 1 ]; then
  # trigger は起動していないため trigger_exit の借用値で reason を誤帰属しない。
  # root cause は上の WIKI_CONTENT_WRITE_FAILED で既出だが、W Phase の sentinel 消費側は
  # WIKI_INGEST_* prefix のみ認識するため gate-visible な WIKI_INGEST_FAILED を
  # reason=content_write_failed で emit する (pr-review.md 6.5.W / fix.md 4.6.W と対称)。
  echo "[CONTEXT] WIKI_INGEST_FAILED=1; reason=content_write_failed; exit_code=1"
  echo "WARNING: close Phase 4.4.W: content write 失敗のため wiki ingest をスキップ (trigger は未起動)。" >&2
  trigger_exit=1  # Phase 4.4.W.2 を LLM がスキップするための非 0 値
  echo "trigger_exit=$trigger_exit"
else
  bash {plugin_root}/hooks/wiki-ingest-trigger.sh \
    --type retrospectives --source-ref "issue-{issue_number}" \
    --content-file "$tmpfile" --issue-number {issue_number} \
    --title "Issue #{issue_number} close retrospective" \
    2>"$trigger_stderr"
  trigger_exit=$?
  echo "trigger_exit=$trigger_exit"
  # trigger 失敗 (exit != 0 かつ != 2; exit 2 = Wiki disabled/uninitialized = legitimate skip) を surface
  if [ "$trigger_exit" -ne 0 ] && [ "$trigger_exit" -ne 2 ]; then
    echo "[CONTEXT] WIKI_INGEST_FAILED=1; reason=trigger_exit_$trigger_exit; exit_code=$trigger_exit"
    echo "WARNING: wiki-ingest-trigger.sh exited $trigger_exit during close Phase 4.4.W" >&2
    if [ "$trigger_stderr" != "/dev/null" ] && [ -s "$trigger_stderr" ]; then
      head -3 "$trigger_stderr" | sed 's/^/  /' >&2
    fi
  fi
fi
```

**Non-blocking**: trigger / content write 失敗で止めない。`trigger_exit` 非 0 なら Phase 4.4.W.2 を skip。`content_write_failed=1` は trigger 未起動のまま `WIKI_INGEST_FAILED reason=content_write_failed` を emit し `trigger_exit=1` で同じ skip へ合流する。
rationale: references/rationale.md#content-write-fail-loud

### 4.4.W.2 Wiki Raw Commit

> raw commit は `wiki-ingest-commit.sh` に委譲する。**本 block は raw のみ commit**（page 統合は `/rite:wiki-ingest`）。
> rationale: references/rationale.md#commit-delegate-single-process

**Condition**: `wiki_enabled=true` AND `auto_ingest=true` AND `trigger_exit=0` の場合のみ実行。満たさなければスキップして Phase 4.5 へ。

```bash
commit_err=$(mktemp "${TMPDIR:-/tmp}/rite-wiki-commit-err-XXXXXX" 2>/dev/null) || commit_err=/dev/null
trap 'rm -f "${commit_err:-}"' EXIT INT TERM HUP
commit_rc=0
wiki_push_attempt="issue-close-{issue_number}-$(date +%s)-$$-$RANDOM"
echo "[CONTEXT] WIKI_PUSH_ATTEMPT=$wiki_push_attempt; source=issue-close; issue={issue_number}"
if commit_out=$(bash {plugin_root}/hooks/scripts/wiki-ingest-commit.sh 2>"${commit_err}"); then
  echo "$commit_out"
  echo "[CONTEXT] WIKI_INGEST_DONE=1; issue={issue_number}; type=retrospectives; attempt=$wiki_push_attempt"
else
  commit_rc=$?
  [ "$commit_err" != "/dev/null" ] && [ -s "$commit_err" ] && head -5 "$commit_err" | sed 's/^/  /' >&2
  # exit 2 = legitimate skip (wiki branch missing/disabled); exit 4 = commit landed, push failed
  case "$commit_rc" in
    2) echo "[CONTEXT] WIKI_INGEST_SKIPPED=1; reason=commit_branch_missing; exit_code=$commit_rc"
       echo "WARNING: wiki-ingest-commit.sh exited 2 (wiki branch missing/disabled) during close Phase 4.4.W.2" >&2 ;;
    4) echo "[CONTEXT] WIKI_INGEST_PUSH_FAILED=1; reason=commit_rc_4; exit_code=$commit_rc; issue={issue_number}; attempt=$wiki_push_attempt"
       [ -n "${commit_out:-}" ] && echo "$commit_out"
       echo "WARNING: wiki-ingest-commit.sh exited 4 (commit landed locally, push failed) during close Phase 4.4.W.2" >&2 ;;
    *) echo "[CONTEXT] WIKI_INGEST_FAILED=1; reason=commit_rc_$commit_rc; exit_code=$commit_rc"
       echo "WARNING: wiki-ingest-commit.sh exited $commit_rc during close Phase 4.4.W.2" >&2 ;;
  esac
fi
[ "$commit_err" != "/dev/null" ] && rm -f "$commit_err"
trap - EXIT INT TERM HUP
```

`commit_rc=4` を観測した場合は、上の Bash block とは**別の Bash tool call**で次を 1 回だけ再試行する。`{wiki_push_attempt}` は直前の `WIKI_PUSH_ATTEMPT` marker の値へリテラル置換する。tool call には `dangerouslyDisableSandbox: true` を指定する（ユーザー確認不要）。通常 sandbox のまま同じ push を繰り返してはならない。
rationale: references/rationale.md#push-retry-sandbox

```bash
if retry_out=$(bash {plugin_root}/hooks/scripts/wiki-ingest-commit.sh --push-only 2>&1); then
  echo "$retry_out"
  echo "[CONTEXT] WIKI_INGEST_PUSH_RETRY=ok; source=issue-close; issue={issue_number}; attempt={wiki_push_attempt}"
else
  retry_rc=$?
  printf '%s\n' "$retry_out" | head -5 | sed 's/^/  /' >&2
  echo "[CONTEXT] WIKI_INGEST_PUSH_RETRY=failed; source=issue-close; issue={issue_number}; attempt={wiki_push_attempt}; exit_code=$retry_rc"
fi
```

close の完了報告前に、**現在の `WIKI_PUSH_ATTEMPT` と同じ `attempt=`** の `WIKI_INGEST_PUSH_FAILED=1` があり、その attempt に `WIKI_INGEST_PUSH_RETRY=ok` が無い場合だけ、次の行を**必ず**表示する（close 自体は non-blocking のまま続行する）。過去 attempt の marker は参照しない:

```
⚠️ Wiki push 未完了: local wiki commit は保持されています。手動回復: bash {plugin_root}/hooks/scripts/wiki-ingest-commit.sh --push-only
```

**Non-blocking**: 失敗は close を止めない。`wiki-ingest-commit.sh` は失敗時に cleanup trap で raw source を復元するので次回再試行できる。→ Phase 4.5 へ。

---

## Phase 4.5: Parent Issue Body Update

子 Issue がクローズされたら、親 Issue の body に完了状態を反映する。

### 4.5.1 Detect Parent Issue

親 Issue を **3 method の OR 検出**で特定する。構造は [`projects-integration.md` §2.4.7.1](../../references/projects-integration.md#247-parent-issue-status-update-for-child-issues) と一致させる（順序・OR・`[DEBUG] parent not detected`・**Method 3 検証ループ**（自己マッチ除外 `cand != {issue_number}`・候補 body の tasklist 再検証・`--limit 10`）。差異は `--state` のみ）。
rationale: references/rationale.md#three-method-parent

**Method 1: `## 親 Issue` body meta（PRIMARY）** — `/rite:issue-create`（Decompose Path）が書く section:

```bash
issue_body=$(gh issue view {issue_number} -R {owner_repo} --json body --jq '.body')
parent_number=$(grep -A2 '^## 親 Issue' <<< "$issue_body" | grep -oE '#[0-9]+' | head -1 | tr -d '#')
echo "method1_parent=${parent_number:-none}"
```

非空なら 4.5.2 へ。

**Method 2: Sub-Issues API（secondary）** — Method 1 が空の場合:

```bash
parent_number=$(gh api graphql -H "GraphQL-Features: sub_issues" -f query='
query($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) { issue(number: $number) { parent { number } } }
}' -f owner="{owner}" -f repo="{repo}" -F number={issue_number} \
  --jq '.data.repository.issue.parent.number // empty')
echo "method2_parent=${parent_number:-none}"
```

非空なら 4.5.2 へ。

**Method 3: Tasklist search（last resort）** — 両 method が失敗した場合。複数候補を取得し、自己マッチ除外＋各候補 body の tasklist 再検証してから採用する。`--state all`。
rationale: references/rationale.md#three-method-parent

```bash
# GitHub code search は `[`/`]` を無視する緩いマッチのため、複数候補を取得して検証する
candidates=$(gh issue list -R {owner_repo} --state all --search "in:body \"- [ ] #{issue_number}\" OR \"- [x] #{issue_number}\"" --json number --limit 10 --jq '.[].number')
parent_number=""
for cand in $candidates; do
  # 自己マッチ除外: standalone Issue が自分自身を親と誤検出するのを防ぐ（AC-1）
  [ "$cand" = "{issue_number}" ] && continue
  # 妥当性検証: 候補 body に当該 tasklist 行が実在するか確認（緩いマッチで拾った無関係 Issue を排除）
  cand_body=$(gh issue view "$cand" -R {owner_repo} --json body --jq '.body')
  if grep -qE "^[[:space:]]*-[[:space:]]\[[ xX]\][[:space:]]*#{issue_number}([^0-9]|$)" <<< "$cand_body"; then
    parent_number="$cand"
    break
  fi
done
echo "method3_parent=${parent_number:-none}"
```

**3 method すべて失敗（`parent_number` 空）**は standalone（AC-4。debug log は残す）:

```bash
echo "[DEBUG] parent not detected for issue #{issue_number} — processing as standalone (methods tried: body_meta, sub_issues_api, tasklist_search)"
```

`親 Issue の参照が見つかりませんでした。親 Issue 更新をスキップします。` を表示し、Phase 4.5 残り + Phase 4.6 をスキップして Phase 5 へ。

### 4.5.2 Update Parent Issue Body

`issue-body-safe-update.sh` の 3-step safe update pattern（fetch/edit/apply + body shrinkage detection + diff-check 冪等性。`implement.md` / `archive-procedures.md` と同パターン）で親の Sub-Issues checkbox と実装フェーズ status を更新する。

**Step 1: Fetch**:

```bash
bash {plugin_root}/hooks/issue-body-safe-update.sh fetch --issue {parent_number} --parent
```

出力に `tmpfile_read=` / `tmpfile_write=` / `original_length=` があれば Step 2 へ。WARNING のみ / 失敗なら警告して Phase 5 へ（non-blocking, AC-4）。

**Step 2: Read tool + Write tool で更新** — Read tool で `$tmpfile_read` を読み、以下 2 置換を適用して Write tool で `$tmpfile_write` に書く:
1. **Sub-Issues checkbox**: `- [ ] #{issue_number}` 行の `- [ ]` を `- [x]` に（該当 Issue 番号行のみ）
2. **実装フェーズ table**: `内容` 列に `#{issue_number}` を含む行の `[ ] 未着手` を `[x] 完了` に

`#{issue_number}` を含む行のみ変更（他 section は不変）。

**Step 3: Apply**:

```bash
bash {plugin_root}/hooks/issue-body-safe-update.sh apply \
  --issue {parent_number} --tmpfile-read "$tmpfile_read" --tmpfile-write "$tmpfile_write" \
  --original-length "$original_length" --parent --diff-check
```

exit 0 で成功（`--diff-check` で変更不要時は skip）。非 0 なら警告して Phase 4.6 へ（non-blocking, AC-4。close 自体は Phase 4.1 で成功済み）。→ Phase 4.6 へ。

---

## Phase 4.6: Parent Auto-Close (All Children Completed)

親の全子が CLOSED かつ `stateReason != NOT_PLANNED` なら auto-close を提案する。Cancelled（NOT_PLANNED）の子が居る、または CLOSED 子の `stateReason` が判定不能なら提案しない。

**実行条件**: Phase 4.5.1 で `{parent_number}` が検出された場合のみ。未検出なら Phase 4.6 全体をスキップして Phase 5 へ。**直接の親のみ処理**し、祖父母には再帰しない。
rationale: references/rationale.md#parent-direct-only

### 4.6.0 + 4.6.1 Idempotency Check & Child Enumeration

冪等性チェック（親が既 closed なら close は no-op。Status → Done は 4.6.1 の後）→ 子列挙 → `all_closed` を **単一 Bash block** で行う。stderr は tempfile に退避。`set -uo pipefail`（`-e` は明示 `|| fallback` のため省略）。
rationale: references/rationale.md#single-block-p460

```bash
set -uo pipefail
parent_number="{parent_number}"
owner="{owner}"
repo="{repo}"
# -R 用の repo 識別子は $owner/$repo（github.projects.owner 由来 = Project owner。repo owner と
# 乖離する設定を許容）と分離し、canonical Owner/Repo Resolution の slash 形式値を literal substitute する
# (canonical: references/gh-cli-patterns.md#ownerrepo-resolution-ssh-host-alias-safe)
owner_repo_slash="{owner_repo}"

# --- Placeholder sanity guard: Phase 4.6 は親検出時のみ到達。未置換/非数値は routing bug ---
case "$parent_number" in
  ''|'{parent_number}'|*[!0-9]*)
    echo "[DEBUG] p460: parent_number invalid ('$parent_number') — Phase 4.6 should not have been entered (routing bug)." >&2
    echo "[CONTEXT] P460_DECISION=skip_routing_bug"
    exit 0 ;;
esac

p46_err=""
trap 'rm -f "${p46_err:-}"' EXIT INT TERM HUP
p46_err=$(mktemp 2>/dev/null) || p46_err=""

# --- 4.6.0: Idempotency — 親が既に CLOSED なら close は no-op。Status → Done は 4.6.1 の後 ---
parent_state=""
if parent_state=$(gh issue view "$parent_number" -R "$owner_repo_slash" --json state --jq '.state' 2>"${p46_err:-/dev/null}"); then
  echo "parent_state=$parent_state"
else
  echo "[DEBUG] p460: gh issue view failed (rc=$?)" >&2
  [ -n "$p46_err" ] && [ -s "$p46_err" ] && head -3 "$p46_err" | sed 's/^/  p460 stderr: /' >&2
  parent_state=""
fi

if [ -z "$parent_state" ]; then
  echo "警告: 親 Issue #${parent_number} の state 取得に失敗しました。自動クローズ判定をスキップします。" >&2
  echo "[CONTEXT] P460_DECISION=skip_retrieval_failed"
  exit 0
elif [ "$parent_state" = "CLOSED" ]; then
  echo "[DEBUG] parent #${parent_number} already closed — skip close; continue for Status → Done"
  echo "[CONTEXT] P460_DECISION=skip_already_closed"
else
  echo "[CONTEXT] P460_DECISION=proceed_to_enumeration"
fi

# --- 4.6.1: Enumerate children (Method A: trackedIssues / Tasklists API → Method B: body parse) ---
# trackedIssues は Tasklists 機能 (body `- [ ] #N` parser)。GitHub Sub-Issues API (subIssues) とは別物。
children_json=""
if children_json=$(gh api graphql -f query='
query($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) {
    issue(number: $number) { trackedIssues(first: 100) { nodes { number state stateReason } } }
  }
}' -f owner="$owner" -f repo="$repo" -F number="$parent_number" \
  --jq '[.data.repository.issue.trackedIssues.nodes[]? | {number, state, stateReason}]' 2>"${p46_err:-/dev/null}"); then
  echo "[DEBUG] method_a: $(printf '%s' "$children_json" | jq 'length' 2>/dev/null || echo 0) children via trackedIssues"
else
  echo "[DEBUG] method_a failed (rc=$?) — trying Method B" >&2
  [ -n "$p46_err" ] && [ -s "$p46_err" ] && head -3 "$p46_err" | sed 's/^/  method_a stderr: /' >&2
  children_json=""
fi

# Method B: 親 body の `## Sub-Issues` section parse (literal heading text — GitHub 機能ではない)
if [ -z "$children_json" ] || [ "$(printf '%s' "$children_json" | jq 'length' 2>/dev/null || echo 0)" -eq 0 ]; then
  echo "[DEBUG] fallback to Method B (parent body '## Sub-Issues' parse)"
  parent_body=$(gh issue view "$parent_number" -R "$owner_repo_slash" --json body --jq '.body' 2>/dev/null || echo "")
  child_numbers=$(awk '/^## Sub-Issues$/{flag=1;next} /^## /{flag=0} flag && /^- \[[ xX]\] #[0-9]+/{print}' <<< "$parent_body" | grep -oE '#[0-9]+' | tr -d '#')
  if [ -z "$child_numbers" ]; then
    children_json="[]"
  else
    children_json="["; first=1
    for n in $child_numbers; do
      # state 取得失敗は fail-closed (OPEN 扱い) で auto-close を抑止する。
      # stateReason は CLOSED 子に限って fail-loud（欠落を非 NOT_PLANNED とみなさない）。
      # OPEN 子の stateReason null は正常で欠落扱いしない。
      child_view=$(gh issue view "$n" -R "$owner_repo_slash" --json state,stateReason 2>/dev/null || echo "")
      if [ -z "$child_view" ]; then
        child_state="OPEN"
        child_reason="null"
      else
        child_state=$(printf '%s' "$child_view" | jq -r '.state // "OPEN"' 2>/dev/null || echo "OPEN")
        [ -z "$child_state" ] && child_state="OPEN"
        child_reason=$(printf '%s' "$child_view" | jq -c '.stateReason' 2>/dev/null || echo "null")
        [ -n "$child_reason" ] || child_reason="null"
      fi
      [ "$first" -eq 1 ] && first=0 || children_json+=","
      children_json+="{\"number\":$n,\"state\":\"$child_state\",\"stateReason\":$child_reason}"
    done
    children_json+="]"
  fi
fi

# --- all_closed 判定 (空配列は「判定不能」= auto-close 不可の safe default) ---
# CLOSED 子の stateReason 欠落は fail-loud（非 NOT_PLANNED とみなして proceed しない）。
# OPEN 子の stateReason null は正常なので欠落カウントに入れない。
final_length=$(printf '%s' "$children_json" | jq 'length' 2>/dev/null || echo 0)
if [ "$final_length" -eq 0 ]; then
  echo "all_closed=false open_count=0 children_total=0"
  echo "[CONTEXT] P461_DECISION=skip_empty_children"
else
  all_closed=$(printf '%s' "$children_json" | jq -r 'all(.[]; .state == "CLOSED") | tostring' 2>/dev/null || echo "false")
  open_count=$(printf '%s' "$children_json" | jq -r '[.[] | select(.state != "CLOSED")] | length' 2>/dev/null || echo 0)
  cancelled_count=$(printf '%s' "$children_json" | jq -r '[.[] | select(.stateReason == "NOT_PLANNED")] | length' 2>/dev/null || echo 0)
  cancelled_nums=$(printf '%s' "$children_json" | jq -r '[.[] | select(.stateReason == "NOT_PLANNED") | .number] | map(tostring) | join(",")' 2>/dev/null || echo "")
  reason_unavailable_count=$(printf '%s' "$children_json" | jq -r '[.[] | select(.state == "CLOSED" and (.stateReason == null or .stateReason == ""))] | length' 2>/dev/null || echo 0)
  echo "all_closed=$all_closed open_count=$open_count cancelled_count=$cancelled_count reason_unavailable_count=$reason_unavailable_count children_total=$final_length"
  if [ "$all_closed" != "true" ]; then
    echo "[CONTEXT] P461_DECISION=skip_open_children; open_count=$open_count"
  elif [ "$reason_unavailable_count" -gt 0 ] 2>/dev/null; then
    echo "[CONTEXT] P461_DECISION=skip_reason_unavailable; count=$reason_unavailable_count"
  elif [ "$cancelled_count" -gt 0 ] 2>/dev/null; then
    echo "[CONTEXT] P461_DECISION=skip_cancelled_children; numbers=$cancelled_nums"
  else
    echo "[CONTEXT] P461_DECISION=proceed_to_confirmation"
  fi
fi
```

**LLM routing**（stdout の `[CONTEXT] P460_DECISION=` / `P461_DECISION=` を prefix match で読む）:

| 値 | Next action |
|----|-------------|
| `P460_DECISION=skip_routing_bug` | routing bug（empty/literal/非数値）。Phase 4.6 を抜けて Phase 5 へ |
| `P460_DECISION=skip_retrieval_failed` | 親 state 取得失敗。Phase 4.6 を抜けて Phase 5 へ（non-blocking） |
| `P460_DECISION=skip_already_closed` + `P461_DECISION=proceed_to_confirmation` | close は skip。Shared: Status → Done（`{issue}` = `{parent_number}`）。4.6.2 / 4.6.3 は実行しない。Phase 5 へ |
| `P460_DECISION=skip_already_closed` + `P461_DECISION=skip_open_children` | Phase 5 へ（Status も Done にしない） |
| `P460_DECISION=skip_already_closed` + `P461_DECISION=skip_cancelled_children` | Phase 5 へ（Status も Done にしない）。`Cancelled の子 #{numbers} を含むため親 #{parent_number} は未完了扱いです（Status → Done / auto-close しません）。親の中止は /rite:issue-cancel の明示指示。` を表示 |
| `P460_DECISION=skip_already_closed` + `P461_DECISION=skip_reason_unavailable` | Phase 5 へ（Status も Done にしない）。`親 Issue #{parent_number} は子の stateReason を判定できないため auto-close をスキップしました。` を表示 |
| `P460_DECISION=skip_already_closed` + `P461_DECISION=skip_empty_children` | 子一覧取得不可。`親 Issue #{parent_number} の子 Issue 一覧が取得できませんでした。自動クローズをスキップします。` を表示し Phase 5 へ |
| `P461_DECISION=skip_empty_children`（`P460=proceed_to_enumeration`） | 子一覧取得不可。`親 Issue #{parent_number} の子 Issue 一覧が取得できませんでした。自動クローズをスキップします。` を表示し Phase 5 へ |
| `P461_DECISION=skip_open_children; open_count=N`（`P460=proceed_to_enumeration`） | `親 Issue #{parent_number} にはまだ N 件の未完了子 Issue があります。自動クローズはスキップします。` を表示し Phase 5 へ |
| `P461_DECISION=skip_cancelled_children; numbers=...`（`P460=proceed_to_enumeration`） | `Cancelled の子 #{numbers} を含むため親 #{parent_number} は未完了扱いです（Status → Done / auto-close しません）。親の中止は /rite:issue-cancel の明示指示。` を表示し Phase 5 へ |
| `P461_DECISION=skip_reason_unavailable`（`P460=proceed_to_enumeration`） | `親 Issue #{parent_number} は子の stateReason を判定できないため auto-close をスキップしました。` を表示し Phase 5 へ |
| `P461_DECISION=proceed_to_confirmation`（`P460=proceed_to_enumeration`） | 4.6.2 へ |

### 4.6.2 User Confirmation

`AskUserQuestion`:

```
親 Issue #{parent_number} のすべての子 Issue が完了しました。親 Issue もクローズしますか？

オプション:
- 親 Issue をクローズする（推奨）
- 親 Issue を開いたまま終了
```

「クローズする」→ 4.6.3。「開いたまま終了」→ `echo "[DEBUG] user declined parent auto-close for #{parent_number}"` し Phase 5 へ。

### 4.6.3 Update Parent Status to Done & Close

親の Projects Status → Done（[共通委譲パターン](#shared-projects-status--done-delegate-pattern)、`github.projects.enabled: false` ならスキップ）と `gh issue close` を **単一 block** で実行する。Step 3 の state-inconsistency summary を**必ず** emit する。`{projects_enabled}` / `{project_number}` / `{owner}` / `{repo}` は `rite-config.yml`、`{parent_number}` / `{issue_number}` は前 Phase。`{owner_repo}` は [Owner/Repo Resolution](../../references/gh-cli-patterns.md#ownerrepo-resolution-ssh-host-alias-safe) の slash 形式（`-R` に `{owner}` は使わない）。
rationale: references/rationale.md#step3-inconsistency-summary

```bash
set -uo pipefail
# drift-check-ignore: 親 Status→Done + close + 不整合サマリ (Step 1-3) を単一 atomic block に
#   保つのは意図的な設計 (silent-corruption 可視化 / substep 間 attention 喪失回避)。
#   phase 分割は両不変条件を壊すため不可。
parent_number="{parent_number}"
owner="{owner}"
repo="{repo}"
# -R 用の repo 識別子は $owner/$repo（Projects delegate 用 = Project owner 由来）と分離する
# (canonical: references/gh-cli-patterns.md#ownerrepo-resolution-ssh-host-alias-safe)
owner_repo_slash="{owner_repo}"
projects_enabled="{projects_enabled}"
project_number="{project_number}"
issue_number="{issue_number}"

status_update_result="projects_disabled"   # success | not_registered | update_failed | projects_disabled | skipped_terminal
status_warning_lines=""
issue_close_result="pending"                # success | failed | pending
script_item_id=""; script_project_id=""; script_status_field_id=""; script_option_id=""

p463_err_close=""; p463_err_status=""
trap 'rm -f "${p463_err_close:-}" "${p463_err_status:-}"' EXIT INT TERM HUP
_mktemp_or_warn() { mktemp 2>/dev/null || { echo "[DEBUG] p463 $1: mktemp failed — gh stderr not captured" >&2; printf ''; }; }

# --- Step 1: Parent Projects Status → Done (delegate) ---
if [ "$projects_enabled" = "true" ]; then
  status_json_args=$(jq -n \
    --argjson issue "$parent_number" --arg owner "$owner" --arg repo "$repo" \
    --argjson project_number "$project_number" --arg status "Done" \
    --argjson auto_add false --argjson non_blocking true \
    '{issue_number:$issue, owner:$owner, repo:$repo, project_number:$project_number, status_name:$status, auto_add:$auto_add, non_blocking:$non_blocking}')
  p463_err_status=$(_mktemp_or_warn "Step 1")
  # `|| status_json=""` は付けない — command substitution は script が非ゼロ終了しても stdout
  # (script が既に出力した失敗理由入り JSON) を capture するため、fallback は診断情報を破棄する
  # (JSON-emit 前に死んだ空 stdout のケースは下の -z check が p463_err_status から補足する)
  status_json=$(bash {plugin_root}/scripts/projects-status-update.sh "$status_json_args" 2>"${p463_err_status:-/dev/null}")
  status_result=$(printf '%s' "$status_json" | jq -r '.result // "failed"' 2>/dev/null || echo "failed")
  status_warning_lines=$(printf '%s' "$status_json" | jq -r '.warnings[]?' 2>/dev/null)
  # 失敗時 recovery one-liner 用に script JSON から 4 ID 抽出 (script は失敗時も emit する)
  script_item_id=$(printf '%s' "$status_json" | jq -r '.item_id // empty' 2>/dev/null)
  script_project_id=$(printf '%s' "$status_json" | jq -r '.project_id // empty' 2>/dev/null)
  script_status_field_id=$(printf '%s' "$status_json" | jq -r '.status_field_id // empty' 2>/dev/null)
  script_option_id=$(printf '%s' "$status_json" | jq -r '.option_id // empty' 2>/dev/null)
  if [ -z "$status_json" ] && [ -n "$p463_err_status" ] && [ -s "$p463_err_status" ]; then
    status_warning_lines=$(printf 'script invocation died before JSON emit: %s' "$(head -5 "$p463_err_status")")
  fi
  case "$status_result" in
    updated) status_update_result="success"; echo "親 Issue #${parent_number} の Status を 'Done' に更新しました" ;;
    skipped_not_in_project) status_update_result="not_registered"; echo "警告: 親 Issue #${parent_number} は Project #${project_number} に未登録。Status 更新をスキップします。" >&2 ;;
    skipped_terminal_conflict)
      status_update_result="skipped_terminal"
      echo "警告: 親 Issue #${parent_number} は既に終端 Status (Cancelled) のため Done への上書きをスキップしました。" >&2
      [ -n "$status_warning_lines" ] && printf '%s\n' "$status_warning_lines" | sed 's/^/  p463 Step 1 warning: /' >&2 ;;
    *) status_update_result="update_failed"
       [ "$status_result" != "failed" ] && echo "[DEBUG] 未知の .result='$status_result' — update_failed 扱い" >&2
       echo "警告: 親 Issue #${parent_number} の Status 更新に失敗。後続の gh issue close は続行します。" >&2
       [ -n "$status_warning_lines" ] && printf '%s\n' "$status_warning_lines" | sed 's/^/  p463 Step 1 warning: /' >&2 ;;
  esac
fi

# --- Step 2: Close the parent Issue ---
p463_err_close=$(_mktemp_or_warn "Step 2")
if gh issue close "$parent_number" -R "$owner_repo_slash" --comment "子 Issue がすべて完了したため自動クローズします。(/rite:issue-close 経由、Issue #${issue_number} の close をトリガー)" >/dev/null 2>"${p463_err_close:-/dev/null}"; then
  issue_close_result="success"; echo "親 Issue #${parent_number} を自動クローズしました"
else
  issue_close_result="failed"
  echo "警告: 親 Issue #${parent_number} のクローズに失敗 (rc=$?)。手動: gh issue close ${parent_number} -R ${owner_repo_slash}" >&2
  [ -n "$p463_err_close" ] && [ -s "$p463_err_close" ] && head -5 "$p463_err_close" | sed 's/^/  p463 Step 2 stderr: /' >&2
fi

# --- Step 3: State inconsistency summary (MUST always emit) ---
echo ""
echo "=== 親 Issue #${parent_number} 処理結果 ==="
echo "  Issue close: $issue_close_result"
echo "  Status update: $status_update_result"
case "${issue_close_result}:${status_update_result}" in
  "success:success"|"success:projects_disabled"|"success:not_registered"|"success:skipped_terminal") echo "  状態: 整合性 OK" ;;
  "success:update_failed")
    echo ""; echo "⚠️ state 不整合: 親 Issue は CLOSED ですが Projects Status が Done に更新されていません。"
    if [ -n "${script_item_id:-}" ] && [ -n "${script_project_id:-}" ] && [ -n "${script_status_field_id:-}" ] && [ -n "${script_option_id:-}" ]; then
      echo "  復旧コマンド: gh project item-edit --project-id ${script_project_id} --id ${script_item_id} --field-id ${script_status_field_id} --single-select-option-id ${script_option_id}"
    else
      echo "  手動更新例: gh project item-edit --project-id <project_id> --id <item_id> --field-id <status_field_id> --single-select-option-id <done_option_id>"
      echo "  診断: gh project field-list ${project_number} --owner ${owner} --format json (Status field と 'Done' option の id を確認)"
    fi ;;
  "failed:success") echo ""; echo "⚠️ state 不整合: Projects Status は Done ですが親 Issue が OPEN のままです。"; echo "  復旧コマンド: gh issue close ${parent_number} -R ${owner_repo_slash}" >&2 ;;
  "failed:projects_disabled") echo ""; echo "⚠️ 親 Issue のクローズに失敗 (Projects は config で無効)。手動: gh issue close ${parent_number} -R ${owner_repo_slash}" >&2 ;;
  "failed:not_registered") echo ""; echo "⚠️ 親 Issue のクローズに失敗 (Project 未登録)。手動: gh issue close ${parent_number} -R ${owner_repo_slash}" >&2 ;;
  "failed:skipped_terminal") echo ""; echo "⚠️ 親 Issue のクローズに失敗 (board Status は Cancelled のまま Done へ上書きしていない)。手動: gh issue close ${parent_number} -R ${owner_repo_slash}" >&2 ;;
  "failed:"*) echo ""; echo "⚠️ 親 Issue の処理が両方失敗 (close / status)。手動対応: gh issue close ${parent_number} -R ${owner_repo_slash}" >&2 ;;
esac
trap - EXIT INT TERM HUP
```

いずれの結果でも Phase 5 へ（non-blocking）。

---

## Phase 5: Delete Local Work Memory Files

**実行条件**: 既クローズ（Phase 1.2）/ 新規クローズ（Phase 4）を問わず最終 Phase として常に実行。`{issue_number}` のみ必要。

指定 Issue のローカル作業メモリと lockdir を削除する（close mode。flow-state reset / stale sweep はしない）。`{plugin_root}` は [Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script-full-version):

```bash
bash {plugin_root}/hooks/cleanup-work-memory.sh --issue {issue_number}
```

`--issue` は番号を直接渡す。`.rite/work-memory/` ディレクトリ自体は残す。

**エラーハンドリング**（すべて non-blocking — 失敗時は警告して終了）:

| Error Case | Response |
|-----------|----------|
| ファイル不在 | エラーなし（スクリプトが gracefully 処理） |
| Permission / スクリプト失敗 | WARNING を表示して終了 |

失敗時の警告:

```
警告: ローカル作業メモリの削除に失敗しました
手動削除: rm -f ".rite/work-memory/issue-{issue_number}.md" && rm -rf ".rite/work-memory/issue-{issue_number}.md.lockdir"
```

### 5.1 Deletion Result Display

```
ローカル作業メモリ: {削除済み / 削除失敗（警告参照） / 該当なし}
```

| Script Output | Display Value |
|--------------|---------------|
| `削除: 1` 以上 | `削除済み` |
| `失敗: 1` 以上 | `削除失敗（警告参照）` |
| `削除: 0, 失敗: 0` | `該当なし` |

End processing.

---

## Error Handling

See [Common Error Handling](../../references/common-error-handling.md) for shared patterns (Not Found, Permission, Network errors).

| Error | Recovery |
|-------|----------|
| Issue Not Found | See [common patterns](../../references/common-error-handling.md) |
| Permission Error | See [common patterns](../../references/common-error-handling.md) |
| Network Error | See [common patterns](../../references/common-error-handling.md) |
