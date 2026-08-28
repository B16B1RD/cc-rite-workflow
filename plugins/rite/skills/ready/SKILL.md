---
name: ready
description: |
  rite workflow の Ready 化ステップ: draft PR を Ready for review にし、関連 Issue の Status を
  更新する。/rite:batch-run から呼ばれる sub-step、または手動 /rite:ready [pr]。汎用の「PR を ready に」
  ヘルパーではなく、その語では auto-activate しない。
  起動: /rite:ready [pr_number]
argument-hint: "[pr_number]"
---

# /rite:ready

> **質問規律**: すべての質問・強制続行判断は [question_resolution](../rite-workflow/references/coding-principles.md#question_resolution-resolve-recommended-reversible-decisions-autonomously) に従う。Ready 化は外部公開状態を変えるため、standalone 確認は維持する。

## Contract
**Input**: PR number (or auto-detected), flow state (optional, e2e flow)
**Output**: `[ready:returned-to-caller]` | `[ready:error]`

PR を Ready for review にし、関連 Issue の Status を更新する。

> **Important**: e2e 内では `[ready:returned-to-caller]` / `[ready:error]` を出して **caller に制御を戻す**。次アクションは caller が決める。

## E2E Output Minimization

**環境起因の迂回・リトライの出力姿勢**: [common-error-handling.md#environment-workaround-output-posture](../../references/common-error-handling.md#environment-workaround-output-posture) — 成功時は無言、失敗時は行動可能な 1 行のみ（規則本文はそちら。本スキルは複製しない）。

---

次の Phase を順に実行する。

## Arguments

| Argument | Description |
|------|------|
| `[pr_number]` | PR number (defaults to the PR for the current branch if omitted) |

---

## Placeholder Legend

| Placeholder | Description | How to Obtain |
|---------------|------|----------|
| `{plugin_root}` | Absolute path to the plugin root directory. Works for both local dev and marketplace installs | [Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script-full-version) |
| `{owner_repo}` | Repo-context gh コマンドの `-R` に literal substitute する owner/repo（slash 形式） | [Owner/Repo Resolution](../../references/gh-cli-patterns.md#ownerrepo-resolution-ssh-host-alias-safe) |

---

## Phase 0: Load Work Memory (End-to-End Flow Only)

> **This phase is only executed within an orchestrator's end-to-end flow. Skip when running standalone.**

> **Warning**: Work memory is published as Issue comments. In public repositories, third parties can view it. Do not record sensitive information (credentials, personal data, internal URLs, etc.) in work memory.

### 0.1 End-to-End Flow Detection

| Condition | Result | Action |
|------|---------|------|
| Conversation history has rich context from `/rite:pr-review` | Within end-to-end flow | PR number can be obtained from conversation context |
| `/rite:ready` was executed standalone | Standalone execution | Obtain from argument or current branch PR |

### 0.2 Retrieve Information from Work Memory

If determined to be within the end-to-end flow, extract the Issue number from the branch name and load work memory from local file (SoT):

```bash
# 1. 現在のブランチから Issue 番号を抽出
issue_number=$(git branch --show-current | grep -oE 'issue-[0-9]+' | grep -oE '[0-9]+')
```

**Local work memory (SoT)**: Read `.rite/work-memory/issue-{issue_number}.md` with the Read tool.

**Fallback (local file missing/corrupt)**:

```bash
# リポジトリ情報を取得（SSH host alias 対応: git-remote.sh 優先 + gh repo view fallback。
# canonical: references/gh-cli-patterns.md#ownerrepo-resolution-ssh-host-alias-safe）
owner_repo=$(bash {plugin_root}/hooks/scripts/lib/git-remote.sh resolve-owner-repo 2>/dev/null) || owner_repo=""
owner=""; repo=""
[ -n "$owner_repo" ] && IFS=$'\t' read -r owner repo <<< "$owner_repo"
[ -n "$owner" ] && [ -n "$repo" ] || {
  owner=$(gh repo view --json owner --jq '.owner.login')
  repo=$(gh repo view --json name --jq '.name')
}

# Issue comment から作業メモリを読み込む（backup）
gh api repos/{owner}/{repo}/issues/{issue_number}/comments \
  --jq '[.[] | select(.body | contains("📜 rite 作業メモリ"))] | last | .body'
```

**Fields to extract:**

| Field | Extraction Pattern | Purpose |
|-----------|-------------|------|
| Issue number | `- **Issue**: #(\d+)` | Identify the related Issue |
| PR number | `- **番号**: #(\d+)` | Identify the target PR |
| Branch name | `- **ブランチ**: (.+)` | For verification |

**When PR number exists in work memory:**

Even if the argument is omitted, retrieve and use the PR number from work memory.

---

## Phase 1: Identify the PR

### 1.0 Bang-Backtick Adjacency Pre-Check (Pre-PR Gate)

> **Reference**: Pre-submission hard gate for the parser-trigger pattern (backtick + bang adjacency in inline code spans of `plugins/rite/{commands,skills,agents,references}/**/*.md`). The underlying static check is `plugins/rite/hooks/scripts/bang-backtick-check.sh`.
>
> **DRIFT-CHECK ANCHOR (SHARED CORE ONLY)**: scanner の起動と rc 分岐は `skills/pr-create/SKILL.md` §1.0 と同期する。一方、PR 番号を入力に持つ ready 固有の PR head 解決は構造が非対称なため同期対象外であり、pr-create へ転記しない。
>
> **Independent of the `/rite:lint` Phase 3.5 bang-backtick check**: lint records bang-backtick findings as warnings (`[lint:success]` is preserved). This gate, in contrast, **blocks** Ready transition when the same pattern is present — lint is the early heads-up, this is the final hard gate before Ready for review.

Resolve plugin_root with the inline one-liner (per [Plugin Path Resolution](../../references/plugin-path-resolution.md#inline-one-liner-for-command-files)) and run the check:

```bash
plugin_root=$(cat .rite/plugin-root 2>/dev/null || cat .rite-plugin-root 2>/dev/null || bash -c 'if [ -d "plugins/rite" ]; then cd plugins/rite && pwd; elif command -v jq &>/dev/null && [ -f "$HOME/.claude/plugins/installed_plugins.json" ]; then jq -r "limit(1; .plugins | to_entries[] | select(.key | startswith(\"rite@\"))) | .value[0].installPath // empty" "$HOME/.claude/plugins/installed_plugins.json"; fi')

# Optional argument is resolved before the gate so `/rite:ready` without an
# argument remains deterministic. The helper then owns PR-head resolution,
# fail-loud routing, scanner rc handling, and signal-safe worktree cleanup.
ready_pr_number="{pr_number}"
case "$ready_pr_number" in
  ''|*[!0-9]*)
    ready_branch=$(git branch --show-current) || { echo "ERROR: Ready gate: current branch を解決できません" >&2; exit 1; }
    case "$ready_branch" in
      main|master)
        echo "エラー: 現在 $ready_branch ブランチにいます" >&2
        echo "Ready for review にする PR を指定してください: /rite:ready <PR番号>" >&2
        exit 1
        ;;
    esac
    ready_pr_number=$(gh pr view "$ready_branch" -R {owner_repo} --json number --jq '.number') || {
      echo "ERROR: Ready gate: branch '$ready_branch' の PR を解決できません" >&2
      exit 1
    }
    ;;
esac

bash "$plugin_root/hooks/scripts/ready-pr-head-gate.sh" \
  --pr "$ready_pr_number" --repo {owner_repo} --plugin-root "$plugin_root" || exit

# HEAD が最終レビュー済み commit と一致すること（sweep が push した 1 commit は
# nb-sweep-done 2 行目 SHA 一致で例外。JSON 不在 / 不一致 / 照合不能 / 2 行目不正は
# fail-loud）。フィールドは schema の commit_sha。
bash "$plugin_root/hooks/scripts/ready-reviewed-head-gate.sh" \
  --pr "$ready_pr_number" --plugin-root "$plugin_root" || exit
```

> **本 bash が exit 1**: `[ready:returned-to-caller]` / `[ready:error]` より前に終わる。invocation failure は orchestrator が 1 回 retry し、2 回目で `[ready:error]`。未検証の force-continue は出さない。`BANG_BACKTICK_CHECK_INVOCATION_FAILED=1` は stderr-only。finding（rc=1）では flag を立てない。reviewed-head ゲートの rc=1（不一致 / JSON 不在 / 照合不能）も同じ停止契約。ユーザーが本ターンで「未レビューのまま Ready 化を強行」と明示した場合のみ、reviewed-head helper の 1 行を除いて実行する。
> rationale: references/rationale.md#bang-backtick-hard-gate
> rationale: references/rationale.md#reviewed-head-gate

### 1.1 Check Arguments

If a PR number is specified as an argument, use that PR.

### 1.2 Identify PR from Current Branch

If no argument is provided, search for a PR from the current branch:

```bash
git branch --show-current
```

**If on main/master branch:**

```
エラー: 現在 {branch} ブランチにいます

Ready for review にする PR を指定してください:
/rite:ready <PR番号>
```

End processing.

### 1.3 Retrieve PR Information

Retrieve the PR associated with the current branch:

```bash
# -R 指定時は selector が必須のため、現在のブランチ名を selector に渡す（従来どおり「現在ブランチの PR」を特定する）
gh pr view "$(git branch --show-current)" -R {owner_repo} --json number,title,state,isDraft,url,headRefName,body
```

**If PR is not found:**

```
エラー: 現在のブランチに関連する PR が見つかりません

現在のブランチ: {branch}

対処:
1. `/rite:pr-create` で PR を作成
2. または PR 番号を直接指定: `/rite:ready <PR番号>`
```

End processing.

### 1.4 Check PR State

**If already Ready for review:**

```
PR #{number} は既に Ready for review です

URL: {pr_url}
```

End processing.

**If already merged or closed:**

```
エラー: PR #{number} は既に{state}されています

状態: {state}
```

End processing.

---

## Phase 2: Execution Confirmation

### 2.1 Confirm with User (Standalone Path)

> **e2e 本経路ではこの確認を skip する**（`.phase` が `phase5_post_review` / `phase5_post_fix` / `review` / `fix` かつ `.active` が `true`）。side path / `active=false` / 予期しない `.phase` は standalone 確認へ fail-safe。
> **Standalone**（直接 `/rite:ready`）は常に `AskUserQuestion`。
> rationale: references/rationale.md#standalone-confirm

**E2E flow detection** (canonical pattern: on helper invocation failure, emit a WARNING + sentinel and fall back fail-safe):

```bash
if phase=$(bash {plugin_root}/hooks/flow-state.sh get --field phase --default ""); then
  :
else
  rc=$?
  echo "WARNING: flow-state.sh failed (rc=$rc) for --field phase in pr/ready Phase 2.1 — falling back to standalone confirmation" >&2
  echo "[CONTEXT] STATE_READ_FAILED=1; phase=pr_ready_phase_2_1_phase; rc=$rc" >&2
  phase=""
fi
# Boolean field read via flow-state.sh: `--default ""` returns "" for both stored false
# and missing field (jq's `// $default` collapses null/false to default). The binary
# AND check below (`[ "$active" = "true" ]`) is safe — both `active=false` and missing
# route to the `else` branch (in_e2e_flow=false), which is the fail-safe behavior.
# A NOT-style check (`[ x = "false" ]`) would NOT be safe under this default and is
# explicitly forbidden by flow-state.sh's caveat block.
if active=$(bash {plugin_root}/hooks/flow-state.sh get --field active --default ""); then
  :
else
  rc=$?
  echo "WARNING: flow-state.sh failed (rc=$rc) for --field active in pr/ready Phase 2.1 — falling back to standalone confirmation" >&2
  echo "[CONTEXT] STATE_READ_FAILED=1; phase=pr_ready_phase_2_1_active; rc=$rc" >&2
  active=""
fi
# Whitelist approach with AND condition: only the main paths (review→ready / fix→ready)
# AND an active flow state skip the confirmation. Unexpected phase values OR
# active!="true" fall back fail-safe to standalone confirmation. The `active=true`
# AND condition closes the same-session interruption + standalone re-invocation gap
# left open by the cross-session guard alone (legacy file's `active=false` after
# e2e stop is the rejecting condition).
# Both legacy `phase5_post_review` / `phase5_post_fix` (no current writer — only
# residual in pre-v3 state files; accepted for resume-from-old-state compat) and
# flat `review` / `fix` (written by the orchestrator `skills/iterate/SKILL.md` review/fix sides
# before sub-skill invocation, and by the sub-skills `skills/pr-review/SKILL.md` ステップ 8.0 /
# `skills/fix/SKILL.md` ステップ 5.1) must be accepted — the legacy names are retained in the
# whitelist solely for backward-compatible resume from pre-v3 state files.
if { [ "$phase" = "phase5_post_review" ] || [ "$phase" = "phase5_post_fix" ] || [ "$phase" = "review" ] || [ "$phase" = "fix" ]; } && [ "$active" = "true" ]; then
  in_e2e_flow=true
else
  in_e2e_flow=false
fi
echo "in_e2e_flow=$in_e2e_flow"
```

The LLM reads the bash stdout (`in_e2e_flow=...`): when `in_e2e_flow=true`, skip the AskUserQuestion in this sub-section and proceed directly to Phase 3; only when `in_e2e_flow=false`, confirm via `AskUserQuestion`:

```
PR #{number} を Ready for review に変更します。

タイトル: {title}
URL: {pr_url}

よろしいですか？

オプション:
- はい、変更する（推奨）: Ready for review に変更し、Status を更新します
- キャンセル: 処理を中止します
```

**If "Cancel" is selected:**

```
処理を中止しました。
```

End processing.

---

## Phase 3: Change to Ready for Review

### 3.1 Execute gh pr ready

```bash
gh pr ready {pr_number} -R {owner_repo}
```

**On success:**

Proceed to the next phase.

**On failure:**

```
エラー: PR #{number} を Ready for review に変更できませんでした

考えられる原因:
- 権限不足
- ネットワークエラー
- PR が既にクローズされている

対処:
1. `gh pr view {number} -R {owner_repo}` で PR の状態を確認
2. GitHub Web UI から直接変更を試す
```

**e2e**: flow-state があれば `ready_error` を書いて `[ready:error]` を出す。`phase=pr` にはしない。
rationale: references/rationale.md#ready-error-phase

```bash
bash {plugin_root}/hooks/flow-state.sh set \
  --phase "ready_error" \
  --active true \
  --next "rite:ready failed during Ready transition. Ask user: retry / abort (orchestrator 経由なら caller に制御を戻す / standalone なら手動再実行)." \
  --if-exists
```

```
[ready:error]
```

End processing.

---

### 3.2 Update Local Work Memory

After `gh pr ready` succeeds, update local work memory (SoT):

```bash
bash {plugin_root}/hooks/scripts/ready-work-memory-update.sh \
  --pr {pr_number} --issue {issue_number} --repo {owner_repo} --plugin-root {plugin_root}
```

**On lock failure**: Log a warning and continue — local work memory update is best-effort.

**Step 2: Sync to Issue comment (backup)** at phase transition (per C3 backup sync rule).

`issue-comment-wm-sync.sh` の `update-phase` transform へ委譲する。comment ID 解決・backup・<50% safety check・PATCH は helper 内で完結し、backup sync が non-blocking（失敗時 WARNING + skip、exit 1 しない）である契約も helper 側で保持される（canonical pattern: `skills/pr-create/SKILL.md` "Step 2: Sync to Issue comment (backup)"）。

```bash
bash {plugin_root}/hooks/issue-comment-wm-sync.sh update \
  --issue {issue_number} \
  --transform update-phase \
  --phase "ready" --phase-detail "Ready for review に変更完了" \
  2>/dev/null || true
```

---

## Phase 4: Update Issue Status

> **Note**: 本スキルが Projects Status In Review 更新の **唯一の writer**。standalone / orchestrator 両経路で必須。

**Critical**: 本 Phase を skip しない。Phase 3 の `gh pr ready` 成功後、Phase 5 の前に Status 更新を実行する。

### 4.1 Identify Related Issue

Extract the related Issue from the PR body:

```bash
gh pr view {pr_number} -R {owner_repo} --json body,headRefName
```

**Extraction patterns:**
1. `Closes #XX`, `Fixes #XX`, `Resolves #XX` in the PR body
2. `issue-XX` pattern in the branch name

### 4.2 Update Status via Shared Script

> **SoT**: `plugins/rite/scripts/projects-status-update.sh` に委譲する（`open` ステップ 2.4 と同じ）。
> rationale: references/rationale.md#projects-delegate

Skip Phase 4.2 if `github.projects.enabled: false` in `rite-config.yml` or if no related Issue was identified in Phase 4.1, and proceed to Phase 4.6. Otherwise, invoke the shared script to transition the Issue Status to **In Review**:

```bash
status_json_args=$(jq -n \
  --argjson issue {issue_number} \
  --arg owner "{owner}" \
  --arg repo "{repo}" \
  --argjson project_number {project_number} \
  --arg status "In Review" \
  --argjson auto_add false \
  --argjson non_blocking true \
  '{issue_number:$issue, owner:$owner, repo:$repo, project_number:$project_number, status_name:$status, auto_add:$auto_add, non_blocking:$non_blocking}')
bash {plugin_root}/scripts/projects-status-update.sh "$status_json_args"
```

`auto_add: false`（ready 時点では open ステップ 2.4 が登録済み）。script は GraphQL `projectItems` → `field-list` → `item-edit` を単一 fail-fast pipeline で実行する。query は `repository(owner:)` 形式。

#### 4.2.1 Result Handling

Inspect the script's stdout JSON and route by `.result`:

| `.result` | User-visible action | 失敗時の surface |
|-----------|--------------------|------------------------|
| `"updated"` | Display `Projects Status を "In Review" に更新しました` and proceed to Phase 4.6 | — (success path) |
| `"skipped_not_in_project"` | Display `警告: Issue #{issue_number} は Project に登録されていません。Status 更新をスキップします` and proceed to Phase 4.6 | **MUST** `WARNING` を stderr に出力 (silent skip 禁止) |
| `"failed"` | Display each `.warnings[]` entry to stderr, then display `警告: Projects Status の "In Review" への更新に失敗しました。手動で更新する場合: GitHub Projects 画面で Issue #{issue_number} の Status を "In Review" に変更するか、または gh project item-edit --project-id <project_id> --id <item_id> --field-id <status_field_id> --single-select-option-id <in_review_option_id> を実行してください。` and proceed to Phase 4.6 | **MUST** `WARNING` を stderr に出力 (silent skip 禁止) |

**全 result 分岐は non-blocking**。Ready 遷移は Phase 3 で完了済み。Status 失敗で止めない。

> **失敗 surface MUST**: `skipped_not_in_project` / `failed` は必ず `WARNING` を stderr に出す（silent skip 禁止）。
> rationale: references/rationale.md#no-silent-skip-status

> **Bash 実装 minimal skeleton (delegate-only 経路の標準形)**:
>
> ```bash
> # `|| status_json=""` は付けない — command substitution は script が非ゼロ終了しても stdout
> # (script が既に出力した失敗理由入り JSON) を capture するため、fallback は診断情報を破棄する
> status_json=$(bash {plugin_root}/scripts/projects-status-update.sh "$status_json_args")
> status_result=$(printf '%s' "$status_json" | jq -r '.result // "failed"' 2>/dev/null)
> status_warning_lines=$(printf '%s' "$status_json" | jq -r '.warnings[]?' 2>/dev/null)
> case "$status_result" in
>   updated)
>     echo "Projects Status を \"In Review\" に更新しました" ;;
>   skipped_not_in_project)
>     echo "警告: Issue #{issue_number} は Project に登録されていません。Status 更新をスキップします" >&2
>     # silent skip 禁止 — WARNING を stderr に出力 (上の echo がそれを満たす) ;;
>   failed|*)
>     [ -n "$status_warning_lines" ] && printf '%s\n' "$status_warning_lines" | sed 's/^/  warning: /' >&2
>     echo "警告: Projects Status の \"In Review\" への更新に失敗しました。手動回復: gh project item-edit ..." >&2 ;;
> esac
> ```
>
> 上記が delegate-only 経路 (close + summary 不要) の標準パターン。`.warnings[]` の stderr surface 実装を忘れると失敗時 warning surface が LLM 実行揺らぎで silent skip するため必ず含めること。`skipped_not_in_project` / `failed` の両経路で `WARNING` を stderr に出力することを **MUST** とする (silent skip 禁止)。Status 更新失敗は non-blocking。
>
> **完全形 (state machine + signal-specific trap + tempfile + Step 3 inconsistency summary)** が必要な場合 (parent Issue close と Status update の片方失敗を可視化する unified block) は `skills/issue-close/SKILL.md` Phase 4.6.3 を参照すること。

> **Underlying API documentation**: See [projects-integration.md §2.4](../../references/projects-integration.md#24-github-projects-status-update) for the API-level details (GraphQL query, field-list, item-edit) that the script encapsulates.

### 4.6 Defense-in-Depth: State Update Before Output (End-to-End Flow)

`[ready:returned-to-caller]` の前に flow-state を post-ready へ更新する。handoff は**セットしない**。
rationale: references/rationale.md#no-handoff
rationale: [stop-loop-continuation-contract.md#why-ready-sets-no-handoff](../../references/stop-loop-continuation-contract.md#why-ready-sets-no-handoff)

**Condition**: Execute only when flow state file exists (indicating e2e flow). Skip if the file does not exist (standalone execution).

**State update**:

| Result | Phase | Phase Detail | Next Action |
|--------|-------|-------------|-------------|
| `[ready:returned-to-caller]` | `ready` | `Ready処理完了` | `rite:ready completed. Standalone 起動の場合は次に /rite:merge {pr_number} を実行。orchestrator 経由なら caller に制御を戻す。Do NOT stop.` |

```bash
bash {plugin_root}/hooks/flow-state.sh set \
  --phase "ready" \
  --active true \
  --next "rite:ready completed. Standalone 起動の場合は次に /rite:merge {pr_number} を実行。orchestrator 経由なら caller に制御を戻す。Do NOT stop." \
  --if-exists
```

**Note on `error_count`**: `flow-state.sh set` は transition で `error_count` を 0 に戻す（`--preserve-error-count` のときのみ保持）。
rationale: references/rationale.md#error-count-reset

**Also sync to local work memory** (`.rite/work-memory/issue-{n}.md`) when flow state file exists:

```bash
WM_SOURCE="ready" \
  WM_PHASE="ready" \
  WM_PHASE_DETAIL="Ready処理完了" \
  WM_NEXT_ACTION="Standalone なら /rite:merge {pr_number} を実行。orchestrator 経由なら caller に制御を戻す" \
  WM_BODY_TEXT="Post-ready phase sync." \
  WM_REQUIRE_FLOW_STATE="true" \
  WM_READ_FROM_FLOW_STATE="true" \
  WM_ISSUE_NUMBER="{issue_number}" \
  bash {plugin_root}/hooks/local-wm-update.sh 2>/dev/null || true
```

**On lock failure**: Log a warning and continue — local work memory update is best-effort.

---

## Phase 5: Completion Report

### 5.0 Determine the Caller

Determine the caller from the conversation context:

| Condition | Result | Action |
|------|---------|---------------------|
| Called via Skill tool from an orchestrator (caller-name agnostic) | Within end-to-end flow | **Skip completion report** — return control to caller (orchestrator handles the report) |
| `/rite:ready` executed standalone | Standalone complete | Output Phase 5.1.2 format |

> **Note**: 標準経路は user 直接 invoke。表の e2e 行は caller-name agnostic な return-to-caller 契約。

**Detection method:**

Check the conversation history and determine "within end-to-end flow" if any of the following apply:

1. `rite:ready` was invoked via the Skill tool (not as a standalone user command)
2. A caller orchestrator の Skill invocation marker が会話履歴に存在

### 5.1 Output the Completion Report

#### 5.1.1 End-to-End Flow (Skip Completion Report, Output Signal)

e2e（Phase 5.0）では **完了レポートを出さない**。代わりに次の 2 行:

```
<!-- skill return signal: caller must continue next step -->
<!-- [ready:returned-to-caller] -->
```

e2e ではこの 2 行が **必須**。
rationale: references/rationale.md#returned-to-caller

#### 5.1.2 Standalone Execution

When `/rite:ready` is executed standalone, use the following simple format:

```
PR #{number} を Ready for review に変更しました

タイトル: {title}
URL: {pr_url}

関連 Issue: #{issue_number}
Status: In Review

次のステップ:
1. レビュアーにレビューを依頼
2. レビューコメントに対応
3. PR マージ後、Issue は自動クローズされます
```

**If no related Issue exists:**

```
PR #{number} を Ready for review に変更しました

タイトル: {title}
URL: {pr_url}

次のステップ:
1. レビュアーにレビューを依頼
2. レビューコメントに対応
3. PR をマージ
```

---

## Error Handling

See [Common Error Handling](../../references/common-error-handling.md) for shared patterns (Not Found, Permission, Network errors).

| Error | Recovery |
|-------|----------|
| PR Not Found | See [common patterns](../../references/common-error-handling.md) |
| Permission Error | See [common patterns](../../references/common-error-handling.md) |
| Network Error | See [common patterns](../../references/common-error-handling.md) |
| Issue Not Found | See [common patterns](../../references/common-error-handling.md) |
