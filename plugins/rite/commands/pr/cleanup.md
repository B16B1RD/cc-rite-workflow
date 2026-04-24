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

## Sub-skill Return Protocol

> **Reference**: See `start.md` [Sub-skill Return Protocol (Global)](../issue/start.md#sub-skill-return-protocol-global) and `create.md` [Sub-skill Return Protocol](../issue/create.md#sub-skill-return-protocol) for the canonical contract. The same rules apply here — DO NOT end your response after a sub-skill (`rite:wiki:ingest`) returns, DO NOT re-invoke the completed skill, and IMMEDIATELY proceed to the 🚨 Mandatory After Wiki Ingest section in the **same response turn**.

### Pre-check list (Issue #604 — mandatory before ending any response turn)

**Enforcement coupling**: protocol violation 時は `stop-guard.sh` が `cleanup_pre_ingest` / `cleanup_post_ingest` phase を block し、`manual_fallback_adopted` workflow_incident sentinel が stderr に echo されて Phase 5.4.4.1 (start.md 配下) で post-hoc 検出される (AC-7)。つまり「turn を閉じたつもりが stop-guard に止められる」という体験で強制される。

**Evaluation context** (2 場面で同じチェックリストを使う):

| 場面 (a): sub-skill return 直後 | 場面 (b): turn 終了直前 |
|---|---|
| まだワークフロー中途。`NO` は「次の継続ステップを実行すべき」を意味する | 終端到達確認。`NO` は **protocol violation** (工程を飛ばして停止しようとしている) |

場面 (a) では Item 1-3 が `NO` でも正常 (Phase 5 完了レポート未出力段階)。場面 (b) では 3 項目すべて `YES` が turn 終了の必要条件 (Item 0 は routing dispatcher で集計対象外)。

**Procedure**: Item 0 は **routing dispatcher** (YES/NO ではなく tag に応じて経路を選ぶ前段処理)。Item 0 を最優先で evaluate し、該当する経路に進んだ後、場面 (b) では **Item 1-3 が YES/NO で評価される状態チェック**。turn 終了の可否は Item 1-3 のみを集計する。

| # | Check (種別) | If YES/NO / routing, do |
|---|-------------|------------------------|
| 0 | **Routing dispatcher (MUST execute step-by-step, skip 禁止 — Issue #621)**: 直前の sub-skill return tag は何か? | 本 Item は routing dispatcher (YES/NO 集計から除外)。手順 (1)(2)(3) は下記 **Item 0 — Routing dispatcher 手順** サブセクションで定義する。evidence 出力の義務化により LLM の silent skip を検出可能にする。 |
| 1 | **State check**: `[cleanup:completed]` が HTML コメント形式で最終行 (あるいは末尾近傍) に出力済みか? | 推奨形式: `grep -F '[cleanup:completed]'` (fixed string で HTML コメント内の string も matchable)。場面 (a) では `NO` でも legitimate — 次の Mandatory After Wiki Ingest / Phase 5 出力に進む。場面 (b) では `NO` は terminal sub-skill (Phase 5) が未完了 — Phase 5 完了メッセージ + 次のステップ + HTML コメント sentinel を出力する。 |
| 2 | **State check**: ユーザー向け完了メッセージ (`クリーンアップが完了しました` 行を含むブロック) が表示済みか? | 場面 (a) では `NO` でも legitimate。場面 (b) では `NO` は Phase 5 完了レポートが欠落 — Phase 5.1 / 5.2 を実行する。 |
| 3 | **State check**: `.rite-flow-state` が deactivate 済みか? (`active: false`, `phase: cleanup_completed`) | 場面 (a) では `NO` でも legitimate。場面 (b) では `NO` は terminal state 未到達 — Phase 5 末尾の flow-state deactivate を実行する。 |

**Rule**: **Item 1-3 すべて `YES`** が turn 終了の必要条件 **ただし場面 (b) においてのみ**。Item 0 は routing dispatcher で YES/NO 集計には含まれない。場面 (a) では Item 1-3 の `NO` は「次のステップに進め」を意味する正常シグナル。

#### Item 0 — Routing dispatcher 手順 (MUST execute step-by-step, skip 禁止 — Issue #621)

全 step を同等の粒度で対称配置する (同型性ルール)。どの step も skip すると Issue #621 regression (H1+H3 複合症状) を再発させる。

1. **`ingest` 関連 marker を検索して evidence を出力する (Issue #650 — 4 種 matcher 集約)**:
   - 直前応答の text body に対し **以下の 4 種 marker** を grep -F で検索する (ingest sub-skill return / Phase 4.W.3 success 経路の両方を defense-in-depth で網羅):
     - `[ingest:completed]` (現行 sentinel。bare bracket 文字列、HTML-comment 内でも matchable)
     - `[ingest:completed:` (AC-2 literal / future-proof defensive matcher: sentinel 形式が `[ingest:completed:{run_id}]` へ進化した場合に備える。現状 sub-skill は bare `[ingest:completed]` を emit するが、いずれかが matched すれば continuation trigger として扱う)
     - `[CONTEXT] WIKI_INGEST_DONE=` (Phase 4.W.3 On success 経路で caller 自身が emit する実 marker、`pr=`・`type=cleanup_ingest` を含む — ingest が成功完了したことの直接シグナル)
     - `[CONTEXT] INGEST_DONE=` (AC-2 literal defensive matcher: 将来 sub-skill が WIKI_ prefix なしで emit するよう変更された場合に備える)
   - **いずれかが matched** した時点で `ingest=matched`、すべて unmatched なら `ingest=unmatched` と判定する (OR 集約)
   - 判定結果を response text に 1 行含める: **HTML コメント形式のみ許容** (`<!-- [routing-check] ingest=matched -->` または `<!-- [routing-check] ingest=unmatched -->`)。bare bracket 形式 (`[routing-check] ingest=matched`) は禁止 — 同ファイル内の bare sentinel 禁止規約 (#604, mirrors #561) と衝突し、Mode B implicit stop を誘発するため
   - 本 evidence 行は response の最終行に置いてはならない (最終行は `<!-- [cleanup:completed] -->` sentinel 専用)
2. **`[cleanup:completed]` を検索して evidence を出力する**:
   - 直前応答の text body に対し `[cleanup:completed]` を grep -F で検索する
   - 判定結果を response text に 1 行含める: `<!-- [routing-check] cleanup=matched -->` または `<!-- [routing-check] cleanup=unmatched -->` (HTML コメント形式のみ許容)
   - 本 evidence 行も response の最終行に置いてはならない (最終行は `<!-- [cleanup:completed] -->` sentinel 専用)
3. **上記 2 行の判定に従って routing する** (両 tag matched 時の優先順位を明示):
   - **優先ルール**: 両方 matched が発生しうるのは同一 session 内で過去 cleanup 完了済み後に次 PR cleanup で ingest を呼んだ直後等の混在ケース。このとき **`ingest=matched` を優先採択**し `cleanup=matched` は無視する (直前 sub-skill return は ingest なので continuation trigger が真の意図)
   - `ingest=matched` → **continuation trigger** として即座に 🚨 Mandatory After Wiki Ingest (`cleanup_post_ingest` patch → Phase 5 Completion Report) を同 turn 内で実行
   - `cleanup=matched` (かつ `ingest=unmatched`) → terminal 到達、場面 (b) Item 1-3 評価へ進む
   - どちらも unmatched → 通常の Phase 進行中 (場面 (a) 継続、Item 1-3 の `NO` は legitimate)

> **評価範囲の scope**: 「直前応答」は現在の turn 直前の assistant response 1 件のみを指す (会話履歴全体ではない)。過去の session で残存する sentinel を誤拾いしない。

> **⚠️ 検出 hook の scope** (Issue #621 root cause fix の限界): 本 Item 0 は **prompt 表面での形式義務化のみ** を実装する。evidence の出力を machine-enforced で検査する hook (`stop-guard.sh` / `workflow-incident-emit.sh` への `[routing-check]` パターン検査追加) は**本 PR の scope 外**で、follow-up Issue として追跡する (Issue #621 MUST「機械的強制」の完全達成には hook 側の検証 logic 追加が必要だが、prompt 側の義務化と hook 側の検証を分離して PR ごとにレビューするための意図的な scope 分割)。現状は prompt が evidence 出力を LLM に強制 → LLM が HTML コメント形式で出力 → `cleanup_pre_ingest` / `cleanup_post_ingest` phase の stop-guard block (既存 5 層) が combined で H1+H3 regression を防ぐ構成。

### Anti-pattern (what NOT to do)

When `rite:wiki:ingest` returns (typically with a recap message such as "Wiki ingest と auto-lint まで完了しました"):

```
[WRONG]
<Skill rite:wiki:ingest returns>
<LLM output: "※ recap: Wiki ingest と auto-lint まで完了しました">
<LLM ends turn. User sees "Cooked for Xm Ys" and must type `continue` manually.>
```

This is a **bug**. The sub-skill return is NOT a turn boundary — it is a hand-off signal. Ending the turn here abandons the cleanup workflow mid-flight, leaving Phase 5 (Completion Report) unexecuted and `.rite-flow-state` in a non-terminal state. The recap message belongs at the **start** of the same response turn (informational), not at the end (turn boundary).

### Correct-pattern (what to do)

```
[CORRECT]
<Skill rite:wiki:ingest returns>
<LLM output: brief recap (optional)>
<In the same response turn, LLM IMMEDIATELY:>
  1. Runs 🚨 Mandatory After Wiki Ingest Pre-write (writes cleanup_post_ingest)
  2. Outputs Phase 5.1 Cleanup Result Summary + Phase 5.2 Guidance for Next Steps (user-visible)
  3. Phase 5.3 Step 1: Deactivates flow state (cleanup_completed, active: false)
  4. Phase 5.3 Step 2: Outputs <!-- [cleanup:completed] --> as the absolute last line
```

**Rule**: Treat `rite:wiki:ingest` return as a **continuation trigger**, not a stopping point. The **only** valid stop is after the user-visible completion message (`クリーンアップが完了しました`) + next-steps block have been displayed AND `<!-- [cleanup:completed] -->` is output as the absolute last line. The HTML-commented sentinel is invisible in rendered views but grep-matchable for hooks/scripts.

> **Contract phrases (AC-6 / Issue #604)**: The anti-pattern / correct-pattern contract above uses these exact phrases: `anti-pattern`, `correct-pattern`, `same response turn`, `DO NOT stop`. These phrases are grep-verified as part of the AC-6 static check — do not rewrite them away. Manual verification command:
>
> ```bash
> for p in "anti-pattern" "correct-pattern" "same response turn" "DO NOT stop"; do
>   grep -c "$p" plugins/rite/commands/pr/cleanup.md
> done
> # Expected: all 4 counts >= 1
> ```

**Completion marker convention** (Issue #604, mirrors create.md Issue #561 D-01): The unified completion marker for `/rite:pr:cleanup` is `[cleanup:completed]`, emitted as an HTML comment (`<!-- [cleanup:completed] -->`) on the absolute last line of Phase 5's output. The HTML comment form keeps the string grep-matchable (`grep -F '[cleanup:completed]'`) while ensuring the user-visible final content is the `クリーンアップが完了しました` checklist + guidance block. Phase 5 handles flow-state deactivation (`cleanup_completed`, `active: false`) and the HTML-commented sentinel internally (Terminal Completion pattern).

**Defense-in-depth**: Phase 1.0 activates `.rite-flow-state` to `cleanup` (Phase 1-4 区間の保護)。Phase 4.W.2 writes `.rite-flow-state` to `cleanup_pre_ingest` before invoking `rite:wiki:ingest`, then 🚨 Mandatory After Wiki Ingest Step 1 (Phase 4.W sub-section: `### 🚨 Mandatory After Wiki Ingest` at h3, inside `## Phase 4.W`) writes `cleanup_post_ingest` after the sub-skill returns. Phase 5.3 writes `cleanup_completed` with `active: false` and outputs the completion marker directly. This ensures the workflow completes even if the orchestrator fails to continue after sub-skill return — `stop-guard.sh` will block premature `end_turn` during `cleanup` / `cleanup_pre_ingest` / `cleanup_post_ingest` and emit the `manual_fallback_adopted` sentinel for Phase 5.4.4.1 (start.md 配下) detection.

---

## Phase 1.0: Activate Flow State

> **Plugin Path**: Resolve `{plugin_root}` using the inline one-liner in **Step 0** below before executing bash hook commands in this file. Do NOT improvise a different resolution script.

**Step 0: Resolve plugin root** (execute once, reuse throughout):

```bash
plugin_root=$(cat .rite-plugin-root 2>/dev/null || bash -c 'if [ -d "plugins/rite" ]; then cd plugins/rite && pwd; elif command -v jq &>/dev/null && [ -f "$HOME/.claude/plugins/installed_plugins.json" ]; then jq -r "limit(1; .plugins | to_entries[] | select(.key | startswith(\"rite@\"))) | .value[0].installPath // empty" "$HOME/.claude/plugins/installed_plugins.json"; fi')
if [ -z "$plugin_root" ] || [ ! -d "$plugin_root/hooks" ]; then
  echo "ERROR: plugin_root resolution failed (resolved: '${plugin_root:-<empty>}')" >&2
  exit 1
fi
echo "plugin_root=$plugin_root"
```

Retain the `plugin_root` value output above and use it for all subsequent `{plugin_root}` references in this command.

Activate `.rite-flow-state` so that `stop-guard.sh` blocks premature `end_turn` during cleanup phases.

> **Convention note (#608 follow-up, create.md との非対称)**: 本ファイルの `flow-state-update.sh` 呼び出しは **`if ! ... ; then echo "WARNING..." >&2; fi`** で包み、失敗時にユーザー可視 WARNING を表示する defense-in-depth パターンを採用している。一方 `commands/issue/create.md` 系は bare `bash flow-state-update.sh` のみ (defense-in-depth なし)。本ファイル先行採用した意図的乖離で、stop-guard 保護がない場合のユーザー影響が cleanup (PR merge 直後の長い workflow) で特に大きいため。create.md 側の convention 揃えは別 Issue で追跡予定。
>
> **Fail-safe**: hook 失敗時も WARNING のみで続行し cleanup 本体は中断しない。stop-guard 保護が一時的に無効になっても、ユーザーは "continue" を入力することで recovery できる。

```bash
if [ -f .rite-flow-state ]; then
  # --active true を明示指定する理由 (#608 cycle 9 F-01 HIGH):
  # 前回セッション終了時に .rite-flow-state が {phase: cleanup_completed, active: false} で残存
  # している場合、patch モードは --active 省略時に .active を更新しないため、patch 後も
  # active=false のままとなる。stop-guard.sh の ACTIVE!=true early exit で cleanup Phase 1-4
  # の protection が silent 無効化されるのを防ぐため、ここで明示的に re-activate する。
  if ! bash {plugin_root}/hooks/flow-state-update.sh patch \
      --phase "cleanup" --active true --next "Execute cleanup phases. Do NOT stop."; then
    echo "WARNING: flow-state-update.sh patch (cleanup activate) failed — stop-guard will not block premature end_turn during Phase 1-4. Investigate the helper exit reason in stderr above. Cleanup will still proceed, but the user may need to type 'continue' to resume." >&2
  fi
else
  if ! bash {plugin_root}/hooks/flow-state-update.sh create \
      --phase "cleanup" --issue 0 --branch "" --pr 0 \
      --next "Execute cleanup phases. Do NOT stop."; then
    echo "WARNING: flow-state-update.sh create (cleanup activate) failed — .rite-flow-state was not created. stop-guard will exit immediately on every stop attempt with no protection. Investigate the helper exit reason in stderr above." >&2
  fi
fi
```

**Purpose**: After PR merge, `.rite-flow-state` is `active: false, phase: completed`. Without re-activation, `stop-guard.sh` exits immediately (`.active != true` 時の early exit branch) and provides no protection against premature `end_turn`, causing the user to type "continue" multiple times. (line-number 参照を避ける理由は cycle 8 F-05 参照)

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
#
# SIGPIPE 防止 (#398): `echo "$comment_body" | sed | grep | head -10` の pipeline では
# comment_body が pipe buffer (64KB) を超えると head -10 の早期終了で echo に SIGPIPE が届く。
# here-string `<<<` で echo subprocess を排除し、sed が一時ファイルから読むため SIGPIPE 経路がない。
progress_section=$(sed -n '/### 進捗/,/### /p' <<< "$comment_body")
incomplete_tasks=$(grep -E '^\s*- \[ \]' <<< "$progress_section" | head -10)
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
2.5 Delete Review Result Local Files and Fix State Files (#443, #450)
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
Ignore remote branch deletion errors and proceed to Phase 2.5.

### 2.5 Delete Review Result Local Files and Fix State Files (#443, #450) <!-- AC-7 -->

> **Acceptance Criteria anchor**: AC-7 (PR マージ時に以下 5 カテゴリの PR-specific local artifacts を削除する: (1) `.rite/review-results/{pr_number}-*.json` wildcard 固定 prefix、(2) `.rite/review-results/{pr_number}-*.json.corrupt-*` corrupt 検出 rename ファイル、(3) `.rite/state/fix-fallback-retry-{pr_number}.count` specific path、(4) `.rite/fix-cycle-state/{pr_number}.json` specific path (Issue #453)、(5) `.rite/fix-cycle-state.json` legacy 単一ファイル specific path (Issue #551)。他 PR ファイルを誤削除しない)。

Delete five categories of PR-specific local artifacts associated with the merged PR:

1. **Review result files**: `.rite/review-results/{pr_number}-*.json` (Issue #443 で導入された opt-in PR コメント記録機能の補完 — see [review-result-schema.md](../../references/review-result-schema.md#クリーンアップ) for the contract)
2. **Corrupted review result files**: `.rite/review-results/{pr_number}-*.json.corrupt-*` (fix.md Phase 1.2.0 Priority 2 が corrupt 検出時に `.corrupt-{epoch}` suffix で rename したファイル。長期運用で累積する `.gitignore` 対象 orphan を防ぐ)
3. **Fix retry state file**: `.rite/state/fix-fallback-retry-{pr_number}.count`
4. **Fix-cycle state file**: `.rite/fix-cycle-state/{pr_number}.json` (Issue #453 収束エンジンが fix サイクルごとに記録する状態ファイル。specific path で削除、wildcard 禁止)
5. **Legacy fix-cycle state file**: `.rite/fix-cycle-state.json` (旧実装または外因性要因によりワークツリー直下に生成される単一ファイル形式の残骸。Issue #551 で対応。specific path 完全一致で削除、PR 番号に依存しない・wildcard 禁止。`.gitignore` の `.rite/fix-cycle-state.json` エントリと併置で defense-in-depth)

> **scope note**: 本 bash block は単一 Bash tool invocation 内で閉じる前提で設計されており、trap は block 外に伝播しない。block 末尾で trap を restore する必要はない。

**Safety constraints**:

- **PR 番号 prefix 固定**: wildcard は必ず `{pr_number}-` で始まるパターンのみを許容する。`*.json` 単独や `.rite/review-results/*`、`.rite/state/*` など、他 PR のファイルを巻き込む形式は**絶対に使わない**。state file は specific path (`{pr_number}.count` 完全一致) で削除する
- **Non-blocking**: ファイルが存在しない場合は warning なしで continue。`rm` 失敗 (permission denied / IO error) は WARNING + `[CONTEXT]` 表示して可視化 (silent 抑制しない)。canonical 定義は [common-error-handling.md#non-blocking-contract-canonical-定義](../../references/common-error-handling.md#non-blocking-contract-canonical-定義) を参照
- **Idempotent**: すでに削除済み / 存在しない場合は WARNING / ERROR なしで続行する (情報用 INFO メッセージ `ℹ️  削除対象のレビュー結果ファイルはありません` は dir 存在 + マッチ 0 件経路で出力される場合がある。dir 不在経路では完全 silent)

**Phase 2.5 failure reasons** (reason table drift prevention — see [distributed-fix-drift-check](../../hooks/scripts/distributed-fix-drift-check.sh) Pattern-2 / Pattern-5):

| reason | Description |
|--------|-------------|
| `invalid_pr_number` | Phase 2.5 進入時の `pr_number` が空 or 非数値 (`[CONTEXT] REVIEW_CLEANUP_PARTIAL_FAILURE=1` flag を併設、Phase は non-blocking exit 0 で終了、cleanup 全体は失敗扱いにしない) |
| `rm_failure` | review result `rm -f` コマンドが permission denied / read-only filesystem / disk I/O エラー等で失敗 (`[CONTEXT] REVIEW_CLEANUP_PARTIAL_FAILURE=1` flag を併設、Phase は WARNING 後に継続) |
| `state_file_rm_failure` | fix retry state file の `rm -f` が permission denied / read-only filesystem / disk I/O エラー等で失敗 (`[CONTEXT] REVIEW_CLEANUP_PARTIAL_FAILURE=1` flag を併設、Phase は WARNING 後に継続) |
| `mktemp_failure_rm_err` | matched_files 側 (`rm` の stderr 退避用 tempfile) の mktemp が失敗 (`[CONTEXT] REVIEW_CLEANUP_PARTIAL_FAILURE=1` flag を併設、Phase は WARNING 後に継続して rm を `/dev/null` 経由で実行) |
| `mktemp_failure_rm_err_state_file` | state_file 側 (`rm` の stderr 退避用 tempfile) の mktemp が失敗 (verified-review cycle 9 I-3 対応、`[CONTEXT] REVIEW_CLEANUP_PARTIAL_FAILURE=1` flag を併設、Phase は WARNING 後に継続して rm を `/dev/null` 経由で実行。matched_files 側 `mktemp_failure_rm_err` との対称化) |
| `cycle_state_file_rm_failure` | fix-cycle state file (`#453`) の `rm -f` が permission denied 等で失敗 (`[CONTEXT] REVIEW_CLEANUP_PARTIAL_FAILURE=1` flag を併設、Phase は WARNING 後に継続) |
| `mktemp_failure_rm_err_cycle_state` | cycle state file 側 (`rm` の stderr 退避用 tempfile) の mktemp が失敗 (`[CONTEXT] REVIEW_CLEANUP_PARTIAL_FAILURE=1` flag を併設、Phase は WARNING 後に継続して rm を `/dev/null` 経由で実行。matched_files 側 `mktemp_failure_rm_err` との対称化) |
| `legacy_cycle_state_file_rm_failure` | legacy 単一ファイル `.rite/fix-cycle-state.json` (`#551`) の `rm -f` が permission denied 等で失敗 (`[CONTEXT] REVIEW_CLEANUP_PARTIAL_FAILURE=1` flag を併設、Phase は WARNING 後に継続) |
| `mktemp_failure_rm_err_legacy_cycle` | legacy cycle state file 側 (`rm` の stderr 退避用 tempfile) の mktemp が失敗 (`[CONTEXT] REVIEW_CLEANUP_PARTIAL_FAILURE=1` flag を併設、Phase は WARNING 後に継続して rm を `/dev/null` 経由で実行。cycle_state 側 `mktemp_failure_rm_err_cycle_state` との対称化) |

**Eval-order enumeration** (for Pattern-5 drift check): Phase 2.5 emit sequence = (`invalid_pr_number` / `mktemp_failure_rm_err` / `rm_failure` / `mktemp_failure_rm_err_state_file` / `state_file_rm_failure` / `mktemp_failure_rm_err_cycle_state` / `cycle_state_file_rm_failure` / `mktemp_failure_rm_err_legacy_cycle` / `legacy_cycle_state_file_rm_failure`)

```bash
# signal-specific trap: 4 ブロック (matched_files rm / state_file rm / cycle_state rm /
# legacy_cycle_state rm) のそれぞれに独立した stderr 退避 tempfile を持たせ、非対称な再利用に
# よるコード/コメント乖離と詳細ログ喪失を防ぐ。
matched_files_rm_err=""
state_file_rm_err=""
cycle_state_rm_err=""
legacy_cycle_state_rm_err=""
_rite_cleanup_p25_cleanup() {
  rm -f "${matched_files_rm_err:-}" "${state_file_rm_err:-}" "${cycle_state_rm_err:-}" "${legacy_cycle_state_rm_err:-}"
}
trap 'rc=$?; _rite_cleanup_p25_cleanup; exit $rc' EXIT
trap '_rite_cleanup_p25_cleanup; exit 130' INT
trap '_rite_cleanup_p25_cleanup; exit 143' TERM
trap '_rite_cleanup_p25_cleanup; exit 129' HUP

pr_number="{pr_number}"

# pr_number の早期 guard (silent misclassification 防止)。
# 空 or 非数値の場合、glob path が変性して他 PR のファイルを誤削除する経路がある
# (現状は `-*.json` として no-match 挙動になるため被害は限定的だが、将来の path 合成変更で
#  regression する可能性がある)。ここで早期検証して non-blocking で exit する。
case "$pr_number" in
  ''|*[!0-9]*)
    echo "ERROR: Phase 2.5 invoked with invalid pr_number: '$pr_number' (expected: numeric only, non-empty)" >&2
    echo "  対処: 呼び出し元 (cleanup.md Phase 1 で抽出される pr_number) を確認してください" >&2
    echo "[CONTEXT] REVIEW_CLEANUP_PARTIAL_FAILURE=1; reason=invalid_pr_number" >&2
    exit 0  # non-blocking (cleanup 全体を失敗させない)
    ;;
esac

review_results_dir=".rite/review-results"
if [ -d "$review_results_dir" ]; then
  # 削除前にマッチ数をカウント (bash glob は no-match でリテラル文字列を返すため、明示的 nullglob 相当の処理)。
  # 通常の `*.json` に加えて、fix.md Priority 2 が corrupt 検出時に rename した `*.json.corrupt-*`
  # ファイルも同じ pr_number prefix に限定して削除対象に含める。
  # broken symlink も削除対象に含めるため、`[ -e ]` (dereferenced) に加えて `[ -L ]` (lstat) を併用する。
  # Known limitation: glob → rm 間に TOCTOU window があるが、pr_number prefix 固定 + .gitignore
  # 対象 + single-session 運用のため実害リスクは極小。削除件数メッセージが不正確になる可能性のみ。
  matched_files=()
  for f in "$review_results_dir"/"${pr_number}"-*.json; do
    { [ -e "$f" ] || [ -L "$f" ]; } && matched_files+=("$f")
  done
  for f in "$review_results_dir"/"${pr_number}"-*.json.corrupt-*; do
    { [ -e "$f" ] || [ -L "$f" ]; } && matched_files+=("$f")
  done
  if [ ${#matched_files[@]} -gt 0 ]; then
    # rm の stderr を独立 tempfile に退避し、失敗時に可視化する (silent failure 禁止)
    # mktemp 構文は Phase 2.5 内 4 ブロック (matched_files / state_file / cycle_state / legacy) で
    # `mktemp ... 2>/dev/null) || { ... }` 構文に統一 (PR #553 review feedback、Issue #551)
    matched_files_rm_err=$(mktemp /tmp/rite-cleanup-matched-rm-err-XXXXXX 2>/dev/null) || {
      echo "WARNING: matched_files rm stderr 退避用 tempfile の mktemp に失敗しました。rm の stderr 詳細は失われます" >&2
      echo "[CONTEXT] REVIEW_CLEANUP_PARTIAL_FAILURE=1; reason=mktemp_failure_rm_err; pr=${pr_number}" >&2
      echo "  対処: /tmp の inode 枯渇 / read-only filesystem / permission 拒否のいずれかを確認してください" >&2
      matched_files_rm_err=""
    }
    if rm -f "${matched_files[@]}" 2>"${matched_files_rm_err:-/dev/null}"; then
      echo "✅ レビュー結果ファイルを削除しました: ${#matched_files[@]} 件 (PR #${pr_number})" >&2
    else
      rm_rc=$?
      echo "WARNING: 一部のレビュー結果ファイル削除に失敗 (PR #${pr_number}, rc=$rm_rc)" >&2
      if [ -n "$matched_files_rm_err" ] && [ -s "$matched_files_rm_err" ]; then
        head -5 "$matched_files_rm_err" | sed 's/^/  /' >&2
      fi
      echo "[CONTEXT] REVIEW_CLEANUP_PARTIAL_FAILURE=1; reason=rm_failure; pr=${pr_number}" >&2
      echo "  対処: permission denied / read-only filesystem / disk I/O エラーのいずれかを確認してください" >&2
    fi
  else
    echo "ℹ️  削除対象のレビュー結果ファイルはありません (PR #${pr_number})" >&2
  fi
else
  # Directory absent → nothing to clean up; silent no-op
  :
fi

# fix retry state file の削除
# specific path 必須 ({pr_number} 完全一致、wildcard glob 禁止)。
# fix.md Phase 1.2.0.1 Interactive Fallback の retry hard gate state file は
# PR がマージされた時点で不要になるため、Phase 2.5 で同時に削除する。
state_file=".rite/state/fix-fallback-retry-${pr_number}.count"
# state_file rm は独立した stderr 退避 tempfile を持つ。matched_files rm 側と変数を分離することで、
# 両経路の失敗詳細が二重障害時にも混線せず個別に保全される。
# mktemp 構文は Phase 2.5 内 4 ブロックで `mktemp ... 2>/dev/null) || { ... }` 構文に統一 (PR #553 review feedback)
state_file_rm_err=$(mktemp /tmp/rite-cleanup-state-rm-err-XXXXXX 2>/dev/null) || {
  echo "WARNING: state file rm stderr 退避用 tempfile の mktemp に失敗しました。rm の stderr 詳細は失われます" >&2
  echo "[CONTEXT] REVIEW_CLEANUP_PARTIAL_FAILURE=1; reason=mktemp_failure_rm_err_state_file; pr=${pr_number}" >&2
  echo "  対処: /tmp の inode 枯渇 / read-only filesystem / permission 拒否のいずれかを確認してください" >&2
  state_file_rm_err=""
}
# state file の存在を事前チェックし、実削除と no-op でメッセージを分岐する
state_file_existed=0
[ -f "$state_file" ] && state_file_existed=1
if rm -f "$state_file" 2>"${state_file_rm_err:-/dev/null}"; then
  if [ "$state_file_existed" = "1" ]; then
    echo "✅ fix retry state file を削除しました: $state_file" >&2
  fi
else
  rm_state_rc=$?
  echo "WARNING: fix retry state file の削除に失敗 (PR #${pr_number}, rc=$rm_state_rc): $state_file" >&2
  if [ -n "$state_file_rm_err" ] && [ -s "$state_file_rm_err" ]; then
    head -5 "$state_file_rm_err" | sed 's/^/  /' >&2
  fi
  echo "[CONTEXT] REVIEW_CLEANUP_PARTIAL_FAILURE=1; reason=state_file_rm_failure; pr=${pr_number}" >&2
  echo "  対処: permission denied / read-only filesystem / disk I/O エラーのいずれかを確認してください" >&2
fi

# fix-cycle state file の削除 (#453 収束エンジン)
# specific path 必須 ({pr_number}.json 完全一致、wildcard glob 禁止)。
# 既存の state_file 削除パターン (stderr tempfile + 詳細ログ) に合わせた error handling。
cycle_state_file=".rite/fix-cycle-state/${pr_number}.json"
cycle_state_rm_err=""
if [ -f "$cycle_state_file" ]; then
  cycle_state_rm_err=$(mktemp /tmp/rite-cleanup-cycle-state-rm-err-XXXXXX 2>/dev/null) || {
    echo "WARNING: cycle state file rm stderr 退避用 tempfile の mktemp に失敗しました。rm の stderr 詳細は失われます" >&2
    echo "[CONTEXT] REVIEW_CLEANUP_PARTIAL_FAILURE=1; reason=mktemp_failure_rm_err_cycle_state; pr=${pr_number}" >&2
    cycle_state_rm_err=""
  }
  if rm -f "$cycle_state_file" 2>"${cycle_state_rm_err:-/dev/null}"; then
    echo "✅ fix-cycle state file を削除しました: $cycle_state_file" >&2
  else
    rm_cycle_rc=$?
    echo "WARNING: fix-cycle state file の削除に失敗 (PR #${pr_number}, rc=$rm_cycle_rc): $cycle_state_file" >&2
    if [ -n "$cycle_state_rm_err" ] && [ -s "$cycle_state_rm_err" ]; then
      head -5 "$cycle_state_rm_err" | sed 's/^/  /' >&2
    fi
    echo "[CONTEXT] REVIEW_CLEANUP_PARTIAL_FAILURE=1; reason=cycle_state_file_rm_failure; pr=${pr_number}" >&2
    echo "  対処: permission denied / read-only filesystem / disk I/O エラーのいずれかを確認してください" >&2
  fi
  [ -n "$cycle_state_rm_err" ] && rm -f "$cycle_state_rm_err"
fi

# legacy fix-cycle state file の削除 (#551)
# specific path 必須 (`.rite/fix-cycle-state.json` 完全一致、PR 番号に依存しない・wildcard 禁止)。
# 旧実装または外因性要因によりワークツリー直下に生成された単一ファイル形式の残骸を除去する。
# ファイル未存在時は no-op (silent skip、warning なし)。既存 cycle_state_file 削除パターンと
# 対称化された error handling (mktemp + stderr 退避 + non-blocking warning)。
legacy_cycle_state_file=".rite/fix-cycle-state.json"
if [ -f "$legacy_cycle_state_file" ]; then
  # incident response 用に mtime を捕捉してログ出力 (生成元トレース手段、PR #553 review feedback)
  # GNU stat (Linux) と BSD stat (macOS) の両対応。失敗時は "unknown" を出力して non-blocking に続行
  legacy_cycle_mtime=$(stat -c '%y' "$legacy_cycle_state_file" 2>/dev/null \
    || stat -f '%Sm' "$legacy_cycle_state_file" 2>/dev/null \
    || echo "unknown")
  echo "ℹ️  legacy fix-cycle state file の mtime: $legacy_cycle_mtime ($legacy_cycle_state_file)" >&2
  echo "[CONTEXT] LEGACY_CYCLE_STATE_MTIME=$legacy_cycle_mtime; pr=${pr_number}" >&2
  legacy_cycle_state_rm_err=$(mktemp /tmp/rite-cleanup-legacy-cycle-rm-err-XXXXXX 2>/dev/null) || {
    echo "WARNING: legacy cycle state file rm stderr 退避用 tempfile の mktemp に失敗しました。rm の stderr 詳細は失われます" >&2
    echo "[CONTEXT] REVIEW_CLEANUP_PARTIAL_FAILURE=1; reason=mktemp_failure_rm_err_legacy_cycle; pr=${pr_number}" >&2
    legacy_cycle_state_rm_err=""
  }
  if rm -f "$legacy_cycle_state_file" 2>"${legacy_cycle_state_rm_err:-/dev/null}"; then
    echo "✅ legacy fix-cycle state file を削除しました: $legacy_cycle_state_file" >&2
  else
    rm_legacy_rc=$?
    echo "WARNING: legacy fix-cycle state file の削除に失敗 (PR #${pr_number}, rc=$rm_legacy_rc): $legacy_cycle_state_file" >&2
    if [ -n "$legacy_cycle_state_rm_err" ] && [ -s "$legacy_cycle_state_rm_err" ]; then
      head -5 "$legacy_cycle_state_rm_err" | sed 's/^/  /' >&2
    fi
    echo "[CONTEXT] REVIEW_CLEANUP_PARTIAL_FAILURE=1; reason=legacy_cycle_state_file_rm_failure; pr=${pr_number}" >&2
    echo "  対処: permission denied / read-only filesystem / disk I/O エラーのいずれかを確認してください" >&2
  fi
  [ -n "$legacy_cycle_state_rm_err" ] && rm -f "$legacy_cycle_state_rm_err"
fi

# trap cleanup 関数が EXIT で matched_files_rm_err / state_file_rm_err / cycle_state_rm_err /
# legacy_cycle_state_rm_err を削除する。block 末尾で cleanup を先に実行し、その後 trap を
# リセットして block 外への伝播を遮断する (defense-in-depth)。
# 順序が重要: trap 解除→cleanup だと解除〜cleanup 間のシグナルでクリーンアップ未実行になる。
_rite_cleanup_p25_cleanup
trap - EXIT INT TERM HUP
```

**Placeholder**: `{pr_number}` はマージされた PR の番号。Phase 1.2 で取得済みの値を再利用する。

**Why this is Phase 2.5 and not Phase 3**: ローカルファイル削除はブランチ削除と同じ「ローカル artifact のクリーンアップ」カテゴリに属するため、Phase 2 (Cleanup Execution) の一部として配置する。Phase 3 (Projects Status Update) はリモート状態の更新であり責務が異なる。

### 2.6 Wiki Worktree Lifecycle (設計原則 — 削除しない)

**Issue #547 の設計原則**: `.rite/wiki-worktree/` は **永続化された worktree** であり、`/rite:pr:cleanup` では削除しません。理由:

- `wiki-worktree-setup.sh` は冪等で、既存 worktree は no-op として扱われるため再作成コストが極めて高い (clone 相当の I/O)
- 各 PR cycle で `wiki-ingest-trigger.sh` → `wiki-ingest-commit.sh` (review/fix/close Phase X.X.W.2) および `wiki-worktree-commit.sh` (ingest.md Phase 5.1 page 統合 / init.md Phase 3.5.1 .gitkeep migration / lint.md Phase 8.3 log.md 追記) がここを経由して wiki branch に raw source / page を landing させるため、cycle を跨いで保持される必要がある
- 通常の `git branch -d` は worktree が checkout している branch を削除できないため、wiki branch 自体への副作用もない

**手動削除が必要な場合** (リポジトリ移動 / 構造変更 / debug):

```bash
# 1. worktree を解除（git の internal 管理から外す）
git worktree remove .rite/wiki-worktree
# 2. dangling な worktree metadata を整理
git worktree prune
```

`git worktree remove` が `worktree contains modified or untracked files` で失敗する場合、`--force` を付けるか、worktree 内で先に commit / push を完了させてから再試行してください。

---

## Phase 3: Projects Status Update

> See [references/archive-procedures.md](./references/archive-procedures.md) for the full archive procedures: Projects Status Update (3.1-3.4), Work Memory final update (3.5), Issue close (3.6), Parent Issue handling (3.6.4, 3.7), and State reset (Phase 4).

---

## Phase 4.W: Wiki Auto-Ingest (Conditional)

> **Reference**: [Wiki Ingest](../wiki/ingest.md) — `/rite:wiki:ingest` Skill API
>
> **Responsibility scope**: This phase invokes `/rite:wiki:ingest` (LLM-driven page integration) to process pending raw sources accumulated on the wiki branch during the PR lifecycle. Raw source **accumulation** is handled by `wiki-ingest-trigger.sh` + `wiki-ingest-commit.sh` in `review.md` Phase 6.5.W.2 / `fix.md` Phase 4.6.W.2 / `close.md` Phase 4.4.W.2. This phase is the **page integration** counterpart.
>
> **Loss-safe guarantee (FR-5, NFR-2)**: Ingest failure does NOT affect cleanup success. Raw sources remain on the wiki branch and can be processed by a subsequent `/rite:wiki:ingest` invocation.

### 4.W.1 Pre-condition Check

**Step 1**: Check Wiki configuration:

```bash
wiki_section=$(sed -n '/^wiki:/,/^[a-zA-Z]/p' rite-config.yml 2>/dev/null) || wiki_section=""
wiki_enabled=""
if [[ -n "$wiki_section" ]]; then
  wiki_enabled=$(printf '%s\n' "$wiki_section" | awk '/^[[:space:]]+enabled:/ { print; exit }' \
    | sed 's/[[:space:]]#.*//' | sed 's/.*enabled:[[:space:]]*//' | tr -d '[:space:]"'"'"'' | tr '[:upper:]' '[:lower:]')
fi
auto_ingest=""
if [[ -n "$wiki_section" ]]; then
  auto_ingest=$(printf '%s\n' "$wiki_section" | awk '/^[[:space:]]+auto_ingest:/ { print; exit }' \
    | sed 's/[[:space:]]#.*//' | sed 's/.*auto_ingest:[[:space:]]*//' | tr -d '[:space:]"'"'"'' | tr '[:upper:]' '[:lower:]')
fi
case "$wiki_enabled" in false|no|0) wiki_enabled="false" ;; true|yes|1) wiki_enabled="true" ;; *) wiki_enabled="true" ;; esac  # #483: opt-out default
case "$auto_ingest" in true|yes|1) auto_ingest="true" ;; *) auto_ingest="false" ;; esac
echo "wiki_enabled=$wiki_enabled auto_ingest=$auto_ingest"
```

If `wiki_enabled=false` or `auto_ingest=false`, **emit a skip status line + sentinel and skip to Phase 5** (do not silently skip — the completion report relies on this signal):

```bash
if [ "$wiki_enabled" = "false" ]; then
  reason="disabled"
elif [ "$auto_ingest" = "false" ]; then
  reason="auto_ingest_off"
else
  reason=""
fi
if [ -n "$reason" ]; then
  echo "[CONTEXT] WIKI_INGEST_SKIPPED=1; reason=$reason"
  emit_err=$(mktemp /tmp/rite-wiki-emit-err-XXXXXX 2>/dev/null) || emit_err=""
  trap 'rm -f "${emit_err:-}"' EXIT INT TERM HUP
  if sentinel_line=$(bash {plugin_root}/hooks/workflow-incident-emit.sh \
      --type wiki_ingest_skipped \
      --details "cleanup Phase 4.W skipped: $reason" \
      --pr-number {pr_number} 2>"${emit_err:-/dev/null}"); then
    [ -n "$sentinel_line" ] && echo "$sentinel_line" && echo "$sentinel_line" >&2
  else
    fallback_iter="{pr_number}-$(date +%s)"
    fallback_sentinel="[CONTEXT] WORKFLOW_INCIDENT=1; type=hook_abnormal_exit; details=workflow-incident-emit.sh failed for wiki_ingest_skipped reason=$reason; iteration_id=$fallback_iter"
    echo "$fallback_sentinel"
    echo "$fallback_sentinel" >&2
    echo "WARNING: workflow-incident-emit.sh (wiki_ingest_skipped) が失敗しました — hook_abnormal_exit sentinel で fallback emit 済み" >&2
    [ -n "$emit_err" ] && [ -s "$emit_err" ] && head -3 "$emit_err" | sed 's/^/  /' >&2
  fi
  [ -n "$emit_err" ] && rm -f "$emit_err"
  trap - EXIT INT TERM HUP
fi
```

If `reason` is non-empty, skip Steps 2-3 and Phase 4.W.2-4.W.3 and proceed to Phase 5. Otherwise continue to Step 2.

**Step 2**: Check for pending raw sources on the wiki branch:

```bash
wiki_branch=$(awk '/^wiki:/{h=1;next} h && /^[[:space:]]+branch_name:/{print;exit}' rite-config.yml 2>/dev/null \
  | sed 's/[[:space:]]#.*//' | sed 's/.*branch_name:[[:space:]]*//' | tr -d '[:space:]"'"'"'')
[ -z "$wiki_branch" ] && wiki_branch="wiki"

# Check if wiki branch exists (local or remote)
# Use git ls-tree -r for flat file listing (avoids git show directory header/subdirectory issues)
pending_count=0
ref=""
if git rev-parse --verify "$wiki_branch" >/dev/null 2>&1; then
  ref="$wiki_branch"
elif git rev-parse --verify "origin/$wiki_branch" >/dev/null 2>&1; then
  ref="origin/$wiki_branch"
fi

if [ -n "$ref" ]; then
  # git ls-tree -r --name-only lists all files recursively under .rite/wiki/raw/
  # (e.g., .rite/wiki/raw/reviews/20260416T075144Z-pr-542.md)
  pending_count=$(git ls-tree -r --name-only "$ref" .rite/wiki/raw/ 2>/dev/null \
    | while read -r filepath; do
        content=$(git show "$ref":"$filepath" 2>/dev/null)
        if echo "$content" | grep -q 'ingested: false'; then
          echo "$filepath"
        fi
      done | wc -l)
fi
echo "pending_count=$pending_count wiki_branch=$wiki_branch ref=$ref"
```

If `pending_count == 0`, **emit a skip sentinel and display message**, then proceed to Phase 5:

```bash
if [ "$pending_count" -eq 0 ]; then
  echo "[CONTEXT] WIKI_INGEST_SKIPPED=1; reason=no_pending"
  echo "ℹ️ pending raw source はありません。Wiki ingest をスキップします。"
fi
```

If `pending_count == 0`, skip Phase 4.W.2-4.W.3 and proceed to Phase 5. Otherwise continue to Phase 4.W.2.

### 4.W.2 Invoke Wiki Ingest

**MUST**: `/rite:wiki:ingest` の invoke は本 step の必須処理であり、**時間的制約・context 残量・セッション経過を理由にした skip は禁止**。skip が許される唯一の条件は Phase 4.W.1 で判定済みの「設定値による disable」「pending raw source が 0 件」などの機械的 Skip condition のみ。LLM の自己判断による省略は identity 違反である。

> **Anti-pattern**: 「cleanup がすでに長いので wiki ingest は次回にしよう」「context が圧迫しているので wiki 起動を飛ばそう」と判断すること。これらは品質を犠牲にした expediency であり、Wiki 経路が silent skip される主要な原因である（Issue #560）。
>
> **Correct pattern**: Phase 4.W.1 で `pending_count >= 1` が確定したら、例外なく下記の Skill invocation を実行する。継続困難な場合は `/clear` + `/rite:resume` をユーザーに案内してセッションを継続させる。
>
> **Identity reference**: [workflow-identity.md](../../skills/rite-workflow/references/workflow-identity.md) の `no_step_omission` / `no_context_introspection` / `clear_resume_is_canonical` / `quality_over_expediency` principle を参照。

**Pre-write** (before invoking `rite:wiki:ingest`, Issue #604): Update `.rite-flow-state` to `cleanup_pre_ingest` so `stop-guard.sh` blocks premature `end_turn` during sub-skill execution and surfaces the phase-specific HINT (sub-skill in-flight, output `<!-- [cleanup:completed] -->` after Phase 5 in the SAME response turn). The `if ! cmd; then` rc capture is mandatory — silent patch failure here disables the stop-guard defence-in-depth that exists specifically to keep this turn from ending mid-sub-skill (#608 follow-up):

```bash
if ! bash {plugin_root}/hooks/flow-state-update.sh patch \
    --phase "cleanup_pre_ingest" --active true \
    --next "After rite:wiki:ingest returns: run 🚨 Mandatory After Wiki Ingest (Pre-write cleanup_post_ingest) → Phase 5 Completion Report (cleanup_completed + <!-- [cleanup:completed] --> sentinel) in the SAME response turn. Do NOT stop." \
    --if-exists; then
  echo "WARNING: flow-state-update.sh patch (cleanup_pre_ingest) failed — stop-guard defence-in-depth is disabled for this Phase 4.W.2 invocation. Sub-skill rite:wiki:ingest will still be invoked, but premature end_turn will not be blocked. Investigate the helper exit reason in stderr above before relying on this protection again." >&2
fi
# cycle 10 F-03: --active true を明示する理由は Phase 1.0 F-01 と同じ。Phase 1.0 patch が
# WARNING で続行した fail-safe path を経由した場合、active=false 残存状態のまま Phase 4.W.2 まで
# 到達する可能性があるため、各 patch で active=true を明示的に pin する (defense-in-depth 完全化)。
```

Invoke the `/rite:wiki:ingest` Skill to process pending raw sources into Wiki pages:

```
Skill: rite:wiki:ingest
```

> **⚠️ NFR-3 (Issue #525 再発防止)**: `/rite:wiki:ingest` は同セッション内で Skill ツール経由で invoke される。ingest.md の結果パターン（成功/失敗）を確認し、Phase 4.W.3 に進むこと。ingest の成功/失敗に関わらず cleanup は続行する（loss-safe continuation）。

> **🚨 Immediate after rite:wiki:ingest returns** (Issue #604): When the sub-skill outputs `<!-- [ingest:completed] -->` and returns control, do **NOT** end the turn. The sub-skill return is a CONTINUATION TRIGGER (see [Anti-pattern / Correct-pattern](#anti-pattern-what-not-to-do) above). **Immediately** proceed to Phase 4.W.3 result handling, then to 🚨 Mandatory After Wiki Ingest below, in the **same response turn**.

### 4.W.3 Result Handling

**On success** (ingest completed):

```
✅ Wiki ingest 完了: {pages_created} ページ生成、{raw_processed} raw source 統合済み
[CONTEXT] WIKI_INGEST_DONE=1; pr={pr_number}; type=cleanup_ingest
```

**Push failure detection** (Issue #555): after the `rite:wiki:ingest` Skill invocation returns, inspect the ingest Skill's stdout lines emitted in this conversation context for the marker `push=failed` (written by `wiki-worktree-commit.sh` via ingest.md Phase 5.1 when `wiki-worktree-commit.sh` returns rc=4). When detected, the commit has landed on the local wiki branch but the origin push failed — AC-3 requires an observable sentinel so cleanup continues (loss-safe) while the incident layer can register the divergence.

**LLM detection and substitution rule**: Claude must inspect the ingest Skill's output (which appears in the conversation context between Phase 4.W.2 invocation and this block) for a line matching the `push=failed` pattern. Typical positive match: `[wiki-worktree-commit] committed=1; branch=wiki; head=<sha>; push=failed`. Typical negatives: `push=ok`, `reason=no-pending`, or no `[wiki-worktree-commit]` status line at all (ingest skipped). Based on the detection result, substitute `{wiki_push_failed}` with either `"true"` (detected) or `"false"` (not detected). Do NOT rely on shell env vars — Claude Code's Bash tool does not persist state across tool calls.

```bash
# Claude substitutes {wiki_push_failed} with "true" or "false" based on ingest output inspection.
# {pr_number} is substituted with the PR number from Phase 1. {plugin_root} is substituted per
# plugin-path-resolution.md.
wiki_push_failed="{wiki_push_failed}"

# Resolve wiki_branch from rite-config.yml (this bash block is a separate invocation from
# Phase 4.W.1 Step 2, so the shell variable from that step is out of scope). Same parser as
# Phase 4.W.1 Step 2.
wiki_branch=$(awk '/^wiki:/{h=1;next} h && /^[[:space:]]+branch_name:/{print;exit}' rite-config.yml 2>/dev/null \
  | sed 's/[[:space:]]#.*//' | sed 's/.*branch_name:[[:space:]]*//' | tr -d '[:space:]"'"'"'')
[ -z "$wiki_branch" ] && wiki_branch="wiki"

if [ "$wiki_push_failed" = "true" ]; then
  # reason=commit_rc_4 で start.md Phase 5.6.2 の aggregation pattern と統一する (cleanup 固有情報は
  # source= key で併記)。旧 `reason=commit_ok_push_failed` は aggregation table と drift していた
  echo "[CONTEXT] WIKI_INGEST_PUSH_FAILED=1; reason=commit_rc_4; source=cleanup_4W"
  emit_err=$(mktemp /tmp/rite-wiki-pushfail-emit-err-XXXXXX 2>/dev/null) || emit_err=""
  trap 'rm -f "${emit_err:-}"' EXIT INT TERM HUP
  if sentinel_line=$(bash {plugin_root}/hooks/workflow-incident-emit.sh \
      --type wiki_ingest_push_failed \
      --details "wiki-worktree-commit.sh exited 4 (commit landed, push failed) during cleanup Phase 4.W" \
      --pr-number {pr_number} 2>"${emit_err:-/dev/null}"); then
    [ -n "$sentinel_line" ] && echo "$sentinel_line" && echo "$sentinel_line" >&2
  else
    fallback_iter="{pr_number}-$(date +%s)"
    fallback_sentinel="[CONTEXT] WORKFLOW_INCIDENT=1; type=hook_abnormal_exit; details=workflow-incident-emit.sh failed for wiki_ingest_push_failed; iteration_id=$fallback_iter"
    echo "$fallback_sentinel"
    echo "$fallback_sentinel" >&2
    echo "WARNING: workflow-incident-emit.sh (wiki_ingest_push_failed) が失敗しました — hook_abnormal_exit sentinel で fallback emit 済み" >&2
    [ -n "$emit_err" ] && [ -s "$emit_err" ] && head -3 "$emit_err" | sed 's/^/  /' >&2
  fi
  [ -n "$emit_err" ] && rm -f "$emit_err"
  trap - EXIT INT TERM HUP
  # ユーザー可視の push 失敗警告は Phase 5.1 Completion Report display rules に一元化した。
  # ここでは sentinel emit のみを行い、重複メッセージを避ける (review.md / fix.md / close.md と同じ pattern)。
fi
```

**Non-blocking guarantee**: push failure does NOT fail cleanup; the commit is preserved on the local wiki branch. The next cleanup / manual push retry can recover the origin state.

**On failure** (ingest error or partial failure):

Emit failure sentinel and continue to Phase 5 (loss-safe continuation):

```bash
echo "[CONTEXT] WIKI_INGEST_FAILED=1; reason=ingest_error; phase=cleanup_4W"
emit_err=$(mktemp /tmp/rite-wiki-emit-err-XXXXXX 2>/dev/null) || emit_err=""
trap 'rm -f "${emit_err:-}"' EXIT INT TERM HUP
if sentinel_line=$(bash {plugin_root}/hooks/workflow-incident-emit.sh \
    --type wiki_ingest_failed \
    --details "rite:wiki:ingest failed during cleanup Phase 4.W" \
    --pr-number {pr_number} 2>"${emit_err:-/dev/null}"); then
  [ -n "$sentinel_line" ] && echo "$sentinel_line" && echo "$sentinel_line" >&2
else
  fallback_iter="{pr_number}-$(date +%s)"
  fallback_sentinel="[CONTEXT] WORKFLOW_INCIDENT=1; type=hook_abnormal_exit; details=workflow-incident-emit.sh failed for wiki_ingest_failed; iteration_id=$fallback_iter"
  echo "$fallback_sentinel"
  echo "$fallback_sentinel" >&2
  echo "WARNING: workflow-incident-emit.sh (wiki_ingest_failed) が失敗しました — hook_abnormal_exit sentinel で fallback emit 済み" >&2
  [ -n "$emit_err" ] && [ -s "$emit_err" ] && head -3 "$emit_err" | sed 's/^/  /' >&2
fi
[ -n "$emit_err" ] && rm -f "$emit_err"
trap - EXIT INT TERM HUP
```

```
⚠️ Wiki ingest が失敗しました。raw source は wiki branch に保持されています。
手動で `/rite:wiki:ingest` を実行してページ統合を再試行できます。
```

**Non-blocking guarantee**: Regardless of success or failure, proceed to Phase 5 (Completion Report).

### 🚨 Mandatory After Wiki Ingest (Issue #604 / #650 — Defense-in-Depth)

> **⚠️ 同 turn 内で必ず実行すること (MUST execute in the SAME response turn)**: `rite:wiki:ingest` の return 直後、**応答を終了せずに** 以下の Step 0 → Step 1 → Step 2 を順に即座に実行する。Phase 5 (Completion Report) は本セクションを経由してのみ実行される唯一の経路である。

> **Enforcement**: `stop-guard.sh` は `cleanup_pre_ingest` / `cleanup_post_ingest` phase で `end_turn` を block し、`manual_fallback_adopted` workflow_incident sentinel を stderr に echo する。protocol violation は次回 turn の Phase 5.4.4.1 (start.md 配下) で post-hoc 検出される。

> **⚠️ Known tracking item (cycle 10 F-04 = cycle 9 F-14 defer 継続)**: 下記 Self-check は LLM の自己 introspection に依存しており、silent corruption の risk を trace 可能な形で記録する目的で本注記を残している。誤 Yes 判定で Step 0/1 skip → stale HINT、誤 No 判定で cleanup_completed phase を cleanup_post_ingest に巻き戻し (Step 0/1 の spec 参照)、双方向で silent inconsistency が起きうる。多重故障時の safety net は session-end.sh cleanup lifecycle WARN (次セッション起動時に観測可能) であるため単発完全 silent ではないが、Self-check を `.rite-flow-state` 直読の機械判定 (`current_phase=cleanup_completed && current_active=false` なら skip) に置換する refactor を別 Issue で tracking 予定。現状は defense-in-depth として機能している範疇。

**Self-check and branching**:

1. **Has `<!-- [cleanup:completed] -->` been output as the absolute last line of the response?** (grep the recent response text — `grep -F '[cleanup:completed]'` matches HTML-comment form)
   - **Yes** — terminal state reached. `.rite-flow-state.phase` is already `cleanup_completed` and `active: false`. **本 Yes 分岐は terminal 到達後の重複呼び出し防止のための例外経路**であり、non-terminal (phase=cleanup_pre_ingest) 時点の Step 0/1 正規路 (Correct-pattern の Step 1「Runs 🚨 Mandatory After Wiki Ingest Pre-write (writes cleanup_post_ingest)」) と矛盾しないことに留意する。Step 0 / Step 1 below MUST be skipped. 理由: `cleanup_completed` は terminal state であり、Step 0/1 の `flow-state-update.sh patch --if-exists` は active=false でも file が存在すれば patch するため、phase を `cleanup_post_ingest` に巻き戻して flow-state を破壊する。phase-transition-whitelist.sh の terminal acceptance は next phase のみを判定し、prev が terminal でも accept するため whitelist 保護には依存できない — 実行しないことで確実に防ぐ。
   - **No** — Phase 5 has NOT been output yet (phase=cleanup_pre_ingest など non-terminal 状態)。Steps 0-2 below are **critical** — execute immediately to force the workflow into the terminal state (Step 0/1 が正規 handoff パス)。

**Step 0: Immediate Bash Action (Issue #650)**: Execute this bash block as the **very first tool call** after `rite:wiki:ingest` returns (Self-check No branch), **before any other tool use or narrative text**. This step replaces the natural turn-boundary point ("the sub-skill finished") with a concrete, non-optional next tool call — the LLM is invoking a bash command, not ending a task. The bash block re-affirms the flow-state phase (idempotent with Step 1) and, on failure only, emits a `[CONTEXT] STEP_0_PATCH_FAILED=1` retained flag to stderr that the LLM can observe in subsequent context (the actual continuation marker `[CONTEXT] WIKI_INGEST_DONE=1` is produced by Phase 4.W.3 on success path *before* Step 0 runs, and `<!-- [ingest:completed] -->` / `[ingest:completed:` HTML comment sentinels are produced by the sub-skill itself). **stderr observability 前提**: 本 flag は Claude Code の `ToolUseResult.stderr` として後続 turn の context に流入する — これは `pr/review.md` の `[CONTEXT] LOCAL_SAVE_FAILED=1` / `pr/fix.md` の `[CONTEXT] WM_UPDATE_FAILED=1` 他 40+ 箇所で採用されている repo-wide convention に依拠している (create.md #636 cycle 8 F-07 と同一 convention、40+ 箇所同時改修契約)。

```bash
# Idempotent patch + retained flag on failure (aligned with create.md Step 0 canonical pattern, Issue #650).
# --preserve-error-count for same-phase self-patch (RE-ENTRY escalation integrity — verified-review
# cycle 3 F-01 / #636 で実測確認済み: 未指定時は patch mode JQ_FILTER が .error_count = 0 でリセットし
# stop-guard.sh の RE-ENTRY DETECTED escalation + THRESHOLD=3 bail-out が永久に unreachable になる)。
# --if-exists で .rite-flow-state 不在時は silent skip (Phase 1.0 Activate 未経由で本セクション到達する
# 経路は本来存在しないが defense-in-depth として付与)。
if ! bash {plugin_root}/hooks/flow-state-update.sh patch \
    --phase "cleanup_post_ingest" --active true \
    --next "Step 0 Immediate Bash Action fired; proceeding to Phase 5 Completion Report. Do NOT stop." \
    --if-exists \
    --preserve-error-count; then
  echo "[CONTEXT] STEP_0_PATCH_FAILED=1" >&2
  # 非 blocking: Step 1 が idempotent patch として再試行する。ここで exit 1 すると
  # 既に進捗している workflow を kill してしまうため、warning のみで continue する。
  # 本 flag は stop-guard.sh cleanup_post_ingest case arm の HINT で grep 参照される
  # (create.md #636 verified-review cycle 2 F-05 と同一 pattern): dead marker ではなく
  # LLM post-hoc 観察用の retained flag。検出時は Step 1 の redundant patch が primary 防御層になる。
fi
```

> **Rationale (Issue #650)**: ユーザー報告症状 (`rite:wiki:ingest` return 直後に caller が implicit stop し、`continue` 介入が必要) の根本原因は、LLM が sub-skill return tag (`<!-- [ingest:completed] -->`) を turn 境界として誤認する turn-boundary heuristic の発火。これは #634/#636 で create→interview 境界に対して解決した regression pattern と同型で、本 Issue は cleanup→ingest 境界に canonical pattern を適用する。Step 0 は **具体的な bash tool 呼び出し** を sub-skill return 直後の必須アクションとして挿入することで、turn 境界シグナルを消去する — LLM は「終わった」ではなく「この bash を実行する必要がある」と認識する。Step 0 は Step 1 と idempotent (patch mode は重複実行耐性あり) — この冗長性こそが防御機構である。
>
> **DRIFT-CHECK ANCHOR (semantic — Issue #650)**: 本 Step 0 bash block は `wiki/ingest.md` Phase 9.1 Step 3 (terminal patch `ingest_completed, active=false`) と `hooks/stop-guard.sh` `cleanup_post_ingest` case arm WORKFLOW_HINT (`bash plugins/rite/hooks/flow-state-update.sh patch --phase cleanup_post_ingest ... --preserve-error-count` を含む) と **3 site 対称**。いずれか 1 site を更新する際は他 2 site も同時更新する必要がある。特に bash 引数 (`--phase`, `--next`, `--preserve-error-count`) の symmetry が崩れると error_count reset loop (create.md verified-review cycle 3 F-01) が再発する。`--if-exists` は本 Step 0 / Step 1 (cleanup.md 側) および stop-guard.sh の WORKFLOW_HINT の 2 箇所に存在し、wiki/ingest.md 側では `--if-exists` の存在/非存在は責務の違いで非対称 (create.md の `--if-exists` 非対称性と同一理由、#636 cycle 9 F-01 / cycle 10 F-04 参照)。

**Step 1**: Update `.rite-flow-state` to post-ingest phase (atomic — idempotent re-patch). The Step 0 bash block (above) already wrote `cleanup_post_ingest` via idempotent patch; this second write refreshes the timestamp and `next_action`. The 2 重 patch design ensures at least one of Step 0 / Step 1 succeeds even under transient failures. 同時失敗のみ `[CONTEXT] STEP_1_PATCH_FAILED=1` として retained flag を残す (`[CONTEXT] STEP_0_PATCH_FAILED=1` と併せて LLM が post-hoc で観察可能)。`--preserve-error-count` も Step 0 と対称に付与 — これがないと RE-ENTRY DETECTED escalation + THRESHOLD bail-out が永久に unreachable になる (create.md #636 verified-review cycle 3 F-01 と同一リスク):

```bash
if ! bash {plugin_root}/hooks/flow-state-update.sh patch \
    --phase "cleanup_post_ingest" --active true \
    --next "rite:wiki:ingest completed/skipped/failed. Proceed to Phase 5 (Completion Report) and emit <!-- [cleanup:completed] --> as absolute last line in the SAME response turn. Do NOT stop." \
    --if-exists \
    --preserve-error-count; then
  echo "[CONTEXT] STEP_1_PATCH_FAILED=1" >&2
  # 非 blocking: Step 0 / Step 1 同時失敗の persistent 障害シグナルを LLM が post-hoc で
  # 観察可能にする。stop-guard.sh cleanup_post_ingest case arm の HINT で grep 参照される。
fi
# cycle 10 F-03: --active true 明示 (Phase 1.0 F-01 と同じ理由)。Phase 1.0 patch 失敗時の
# fail-safe path 経由で到達した場合に備え、defense-in-depth を各 patch 箇所で完全化する。
```

**Step 2**: **→ Proceed to Phase 5 now**. The Phase 5 procedure handles the user-visible completion message, the `<!-- [cleanup:completed] -->` HTML comment sentinel (absolute last line), and the final flow-state deactivate (`cleanup_completed`, `active: false`) in a single contiguous block.

> **Anti-pattern reminder**: Do NOT output a recap line such as "※ wiki ingest 完了。次は Phase 5 完了レポート" as the **last** content of the response — that would create a turn-boundary heuristic trigger (the LLM may end the turn after a "looks final" recap line). Recap lines are acceptable as **leading** informational content only; the absolute last line MUST be the HTML-commented sentinel.

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
- [{review_cleanup_check}] レビュー結果ファイル・fix state ファイルを削除
- [x] .rite-flow-state をリセット
- [{projects_check}] Projects Status を Done に更新
- [{wiki_ingest_check}] Wiki ingest（pending raw source のページ統合）
- [x] 作業メモリを最終更新
- [x] 関連 Issue をクローズ
- [x] 親 Issue の Tasklist チェックボックスを更新（該当する場合）
- [x] 親 Issue の自動クローズ（該当する場合）
- [x] ローカル作業メモリを削除（該当する場合）
```

**Review cleanup result display rules:**

| `REVIEW_CLEANUP_PARTIAL_FAILURE` | `{review_cleanup_check}` |
|----------------------------------|--------------------------|
| not set (正常) | `x` |
| `1` (部分失敗) | ` ` (space) + 下記の警告を表示 |

When `REVIEW_CLEANUP_PARTIAL_FAILURE` is `1`, append the following after the checklist:

```
⚠️ レビュー結果ファイルの削除が完了しませんでした (reason: {reason})。
手動で確認してください: ls -la .rite/review-results/{pr_number}-* .rite/state/fix-fallback-retry-{pr_number}.count
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

**Wiki ingest result display rules:**

| Sentinel | `{wiki_ingest_check}` | 表示内容 |
|----------|----------------------|----------|
| `WIKI_INGEST_DONE=1` 単独 | `x` | (追加表示なし) |
| `WIKI_INGEST_DONE=1` + `WIKI_INGEST_PUSH_FAILED=1` 併存 | ` ` (space) | **PUSH_FAILED 優先**: 下記の push 失敗警告を表示 (AC-3: commit は local wiki branch に保持、origin 側のみ divergence) |
| `WIKI_INGEST_PUSH_FAILED=1` 単独 (DONE なし) | ` ` (space) | 下記の push 失敗警告を表示 |
| `WIKI_INGEST_SKIPPED=1; reason=disabled` | `x` | `ℹ️ Wiki ingest スキップ (wiki.enabled=false)` |
| `WIKI_INGEST_SKIPPED=1; reason=auto_ingest_off` | `x` | `ℹ️ Wiki ingest スキップ (wiki.auto_ingest=false)` |
| `WIKI_INGEST_SKIPPED=1; reason=no_pending` | `x` | `ℹ️ Wiki ingest スキップ (pending raw source なし)` |
| `WIKI_INGEST_FAILED=1` | ` ` (space) | 下記の ingest 失敗警告を表示 |
| sentinel なし (Phase 4.W 未実行) | ` ` (space) | `⚠️ Wiki ingest Phase が実行されませんでした` |

**Sentinel 評価優先順位** (silent misclassification 防止): Phase 4.W.3 の push failure detection は ingest 自身の成功 (`WIKI_INGEST_DONE=1`) と併存可能な経路のため、両 sentinel が同時に emit された場合は `WIKI_INGEST_PUSH_FAILED=1` 行を優先して評価し push 失敗警告を表示する。上記テーブルは上から順に評価し最初にマッチした行を採用すること。

`{wiki_branch}` の解決: 下記 `WIKI_INGEST_PUSH_FAILED` メッセージの `{wiki_branch}` は、Phase 4.W.1 Step 2 と同じ parser (`awk '/^wiki:/{h=1;next} h && /^[[:space:]]+branch_name:/{print;exit}' rite-config.yml ...`) で `rite-config.yml` の `wiki.branch_name` を解決する。未設定時のデフォルトは `wiki`。

`WIKI_INGEST_PUSH_FAILED` が検出された場合 (`WIKI_INGEST_DONE` との併存有無を問わず)、チェックリストの後に以下を付記する:

```
⚠️ Wiki ingest: commit は local wiki branch に landed しましたが origin への push に失敗しました。
  手動回復: git -C .rite/wiki-worktree push origin {wiki_branch}
```

`WIKI_INGEST_FAILED` が検出された場合、チェックリストの後に以下を付記する:

```
⚠️ Wiki ingest が失敗しました。raw source は wiki branch に保持されています。
手動で `/rite:wiki:ingest` を実行してページ統合を再試行できます。
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

> **⚠️ MUST NOT (#633, Phase 9.2 三点セット規約整合)**: 「次のステップ:」ブロック最終項目 (`2. /rite:issue:start ...`) の直後に余計な空行を出力してはならない。Phase 5.3 Step 1 bash 実行は最終項目直後に連続して行い、Phase 5.3 Step 2 HTML コメント sentinel は bash 実行直後に連続して出力する (下記 Phase 5.3 Output ordering 参照)。末尾空行は LLM turn-boundary heuristic を誤発火させうる fragile 要因であり、Phase 9.2 三点セット規約 (完了メッセージ → 次のステップ → HTML コメント sentinel の連続出力、`wiki/lint.md` Phase 9.2 canonical pattern 参照) と整合させること。

### 5.3 Terminal Completion (Issue #604)

> **⚠️ MUST NOT (#604, mirrors #561)**: 「ユーザー可視最終行 = `[cleanup:completed]` の bare bracket 形式」で turn を終わらせてはならない。bare sentinel は LLM の turn-boundary heuristic を誤発火させ、Mode B 症状 (recap 出力後の implicit stop) を再発させる既知リスク (Issue #561 解消条件)。**HTML コメント形式 (`<!-- [cleanup:completed] -->`) のみ許容**。
>
> **Output ordering** (絶対遵守 — **各ブロック間に余計な空行を挿入しない** (#633)。Phase 5.1 / 5.2 は前段 sub-phase として Phase 5.3 進入前に既に出力済み、下記 Phase 5.3 Step 1/2 の番号と直接対応):
> 1. Phase 5.1 Cleanup Result Summary — 前段で出力済み (ユーザー可視メッセージ + チェックリスト + 警告群)
> 2. Phase 5.2 Guidance for Next Steps — 前段で出力済み (ユーザー可視 next-steps ブロック、**最終項目 (`2. /rite:issue:start ...`) の直後に余計な空行を入れない** — Phase 9.2 三点セット規約整合、#633)
> 3. Phase 5.3 Step 1: flow-state deactivate (下記 Step 1) — Phase 5.2 最終項目直後に連続実行する (中間に空行を挟まない、#633)。bash 出力はユーザー可視だが、`(Bash completed with no output)` のため最終行にならない
> 4. Phase 5.3 Step 2: `<!-- [cleanup:completed] -->` HTML コメント (下記 Step 2、Step 1 bash 実行直後に連続出力、絶対最終行 — rendered view では不可視、grep 可能)

**Step 1**: Deactivate flow state to terminal `cleanup_completed` (idempotent — safe to re-execute). The `if ! cmd; then` rc capture is mandatory — silent failure here leaves `.rite-flow-state.active = true`, which causes the **next** session-end / stop-guard evaluation to surface a stale HINT for the already-completed cleanup workflow (#608 follow-up):

```bash
if ! bash {plugin_root}/hooks/flow-state-update.sh patch \
    --phase "cleanup_completed" \
    --next "none" --active false \
    --if-exists; then
  echo "WARNING: flow-state-update.sh patch (cleanup_completed) failed — .rite-flow-state may still report active=true. Pre-check Item 3 (.phase = cleanup_completed AND .active = false) will then fail. Manually run: bash {plugin_root}/hooks/flow-state-update.sh patch --phase cleanup_completed --next none --active false --if-exists" >&2
fi
```

**Step 2**: Output the HTML-commented completion sentinel as the **absolute last line** of the response. The sentinel must appear **after** Phase 5.1 + 5.2 user-visible content and the Step 1 bash invocation:

```
<!-- [cleanup:completed] -->
```

**Self-verification** (Pre-check Item 1-3 evaluation, 場面 (b) mode):
- Item 1: `grep -F '[cleanup:completed]'` against the response output finds the HTML-commented sentinel? → MUST be YES
- Item 2: User-visible `クリーンアップが完了しました` checklist + `次のステップ:` block displayed? → MUST be YES
- Item 3: `.rite-flow-state.phase = cleanup_completed` and `.active = false`? → MUST be YES

If all three are YES, stop is allowed. If any is NO, return to the missing step and re-output before ending the turn.

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
