---
name: issue-cancel
description: |
  rite workflow の Issue 中止スキル: やらないと決めた Issue を NOT_PLANNED でクローズし、
  PR / ブランチ / セッション worktree / PR-specific state / 作業メモリを残さず片付ける。
  完了確認スキル /rite:issue-close とは別経路（中止は完了の変種ではない）。
  ユーザーが明示的に /rite:issue-cancel で起動する。auto-activate しない。
  起動: /rite:issue-cancel <issue_number> [中止理由]
argument-hint: "<issue_number> [reason]"
---

# /rite:issue-cancel

Issue の**中止**（やらないと決めた作業の終了）を通す。Issue は `NOT_PLANNED` でクローズし、board Status は終端 Status の `Cancelled` にする。着手前の Issue と、既に draft PR / ブランチ / セッション worktree / 作業メモリを持つ着手後の Issue の双方を扱う。

**起動は人間の明示指示に限る**。rite のワークフローが中止相当の状況を自律判断して本スキルを呼ぶ経路は作らない。
rationale: references/rationale.md#human-initiated-only

## Contract

**Input**: Issue number (required) + 中止理由（引数の残り、または Phase 1 の対話で受け取る）
**Output**: 中止完了報告（クローズした PR 番号・削除したブランチ / worktree・board Status の遷移結果）、または fail-loud の停止報告

**自律度**: Phase 1 の理由取得だけがユーザー入力を要する。それ以降は確認を挟まない（中止は「破棄すると決めた後」の経路であり、破棄の再確認を工程に常駐させない）。
rationale: references/rationale.md#no-reconfirm

## E2E Output Minimization

**環境起因の迂回・リトライの出力姿勢**: [common-error-handling.md#environment-workaround-output-posture](../../references/common-error-handling.md#environment-workaround-output-posture) — 成功時は無言、失敗時は行動可能な 1 行のみ（規則本文はそちら。本スキルは複製しない）。

## Arguments

| Argument | Description |
|----------|-------------|
| `<issue_number>` | 中止する Issue 番号（required）。引数中の最初の数値 |
| `[reason]` | 中止理由。省略時は Phase 1 で対話取得する。理由なしでは Issue をクローズしない |

## Placeholder Legend

| Placeholder | Source |
|-------------|--------|
| `{issue_number}` | 引数中の最初の数値 |
| `{cancel_reason}` | Phase 1 で確定した中止理由 |
| `{reason_file}` | Phase 1 で理由本文を書き出した一時ファイルの path |
| `{pr_number}` | Phase 2 で検出した open PR の番号（未検出時は substitute しない） |
| `{branch_name}` | Phase 2 で確定したブランチ名（PR の `headRefName`、または flow-state / claim 由来） |
| `{branch_identity_verified}` | Phase 2 の identity 検証結果（`true` / `false`） |
| `{flow_wt}` / `{main_root}` | Phase 4.1 の `CLEANUP_WT` marker の `worktree=` / `main_root=` 値 |
| `{plugin_root}` | [Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script-full-version) |
| `{owner}` / `{repo}` / `{owner_repo}` | [Owner/Repo Resolution](../../references/gh-cli-patterns.md#ownerrepo-resolution-ssh-host-alias-safe) で解決した値を literal substitute |
| `{project_number}` | `rite-config.yml` → `github.projects.project_number` |

---

## 実行順序の不変条件

**PR クローズ → Projects Status → `Cancelled` → `gh issue close --reason "not planned"`** の相対順序は崩さない。Status を PR クローズより先に書くと、`post-compact.sh` の PR Status reconciliation（open かつ `isDraft=false` の PR に発火）が Status を `In Review` へ引き戻す窓が開く。PR クローズが失敗した状態で Status を `Cancelled` へ進めてはならない。
rationale: references/rationale.md#order-invariant

---

## Phase 1: 引数と中止理由の確定

引数中の最初の数値を `{issue_number}` とする。数値が無ければ使い方 `/rite:issue-cancel <issue_number> [中止理由]` を表示して終了する。

引数の残り（数値を除いた部分）が非空ならそれを `{cancel_reason}` とする。空のときは **AskUserQuestion で理由を尋ねる**。理由を取得できない環境（応答が得られない）では、**Issue をクローズせず停止する** — 理由の残らない中止は後から判断を追えない。

確定した理由は Write ツールで一時ファイルへ書き出し、`{reason_file}` として retain する（Phase 6 が変数経由で `gh issue close --comment` へ渡す。特殊文字を含む理由をコマンドラインへ literal 展開しないため）。

| 観測 | アクション |
|---|---|
| Issue 番号が無い | 使い方を表示して終了 |
| 理由が確定した | Phase 2 へ |
| 理由を取得できない | **停止**。Issue はクローズしない |

---

## Phase 2: 状態検出と経路分岐

### 2.1 Issue の状態

```bash
gh issue view {issue_number} -R {owner_repo} --json number,title,state,stateReason,url
```

| `state` | アクション |
|---|---|
| `CLOSED` | 既に終了済み。**Phase 3 / Phase 4 / Phase 6 をすべてスキップ**し、Phase 5（board Status の同期）だけを実行して Phase 7 へ（冪等経路） |
| `OPEN` | 2.2 へ |

### 2.2 関連 PR の検索と identity 検証

```bash
gh pr list -R {owner_repo} --state all --search "linked:issue:{issue_number}" --json number,state,isDraft,headRefName,mergedAt,url
```

見つからなければブランチ名から再検索する:

```bash
gh pr list -R {owner_repo} --state all --head "*issue-{issue_number}*" --json number,state,isDraft,headRefName,mergedAt,url
```

| 観測 | アクション |
|---|---|
| `mergedAt` が非 null の PR がある | **中止ではなく完了済み**。`/rite:cleanup {pr_number}` を案内して**停止する**（マージ済みの作業を NOT_PLANNED で葬らない） |
| `state == "OPEN"` の PR がある | `{pr_number}` と `headRefName` を retain。`headRefName` を `{branch_name}`、`{branch_identity_verified}=true` として Phase 3 へ |
| PR が無い（着手前、またはブランチのみ） | `{pr_number}` は未確定。2.3 でブランチを解決して Phase 4 へ（Phase 3 はスキップ） |

`headRefName` を経由せずにブランチ名を推測しない。PR がある経路の `{branch_identity_verified}` は `headRefName` の実値をそのまま使うため常に `true` になる。

### 2.3 PR が無い場合のブランチ解決

flow-state と claim に記録されたブランチを読む:

```bash
bash {plugin_root}/hooks/flow-state.sh get --field branch --default ""
```

空ならローカルブランチを探す:

```bash
git branch --list "*issue-{issue_number}-*" --format '%(refname:short)'
```

| 観測 | `{branch_name}` / `{branch_identity_verified}` |
|---|---|
| flow-state に記録あり | その値 / `true`（rite が作ったブランチとして記録済み） |
| ローカル候補が **ちょうど 1 件** | その値 / `true` |
| 候補が 0 件 | 未確定 / `false`。Phase 4 のブランチ削除をスキップする（削除対象が無い） |
| 候補が 2 件以上 | 未確定 / `false`。候補を表示し、ブランチ削除をスキップして残りの中止処理を続行する（identity 未確定のまま削除しない） |

---

## Phase 3: PR クローズ（fail-loud）

> **`{pr_number}` が未確定（PR 無し）のときは本 Phase をスキップして Phase 4 へ進む。**

```bash
pr_close_reason=$(cat "{reason_file}")
if gh pr close {pr_number} -R {owner_repo} --comment "Issue #{issue_number} の中止に伴いクローズします。理由: $pr_close_reason"; then
  echo "[CONTEXT] CANCEL_PR_CLOSED=1; pr={pr_number}"
else
  pr_close_rc=$?
  echo "[CONTEXT] CANCEL_PR_CLOSE_FAILED=1; pr={pr_number}; rc=$pr_close_rc" >&2
  echo "ERROR: PR #{pr_number} のクローズに失敗しました (rc=$pr_close_rc)" >&2
fi
```

`--delete-branch` は付けない（ブランチ削除は Phase 4 の helper が worktree 削除後の順序で扱う）。

| marker | アクション |
|---|---|
| `CANCEL_PR_CLOSED=1` | Phase 4 へ |
| `CANCEL_PR_CLOSE_FAILED=1` / marker 不在 | **fail-loud で停止する**。Projects Status を `Cancelled` へ進めず、Issue もクローズせず、後片付けも行わない。復旧手順（`gh pr close` の手動実行 → `/rite:issue-cancel {issue_number}` の再実行）を表示して終了 |

---

## Phase 4: 後片付け

削除処理の bash を本スキルへ複製しない。すべて既存 helper へ委譲する。
rationale: references/rationale.md#helper-delegation

### 4.1 セッション worktree の検出

```bash
_dt_rc=0
bash {plugin_root}/hooks/scripts/cleanup-session-worktree-teardown.sh detect --issue "{issue_number}" || _dt_rc=$?
if [ "$_dt_rc" -ne 0 ]; then
  echo "WARNING: worktree detect helper が rc=${_dt_rc} で失敗しました。作業ツリーの分類ができていません" >&2
  echo "[CONTEXT] CLEANUP_WT=unknown; reason=detect_helper_failed; rc=${_dt_rc}" >&2
fi
```

### 4.2 worktree の退出と削除

**順序制約**: `detect` と `remove` の間には必ず `ExitWorktree` が入る。cwd がセッション worktree 内のまま `remove` を呼ぶと自分の足元を削除することになるため、1 本の直列 helper に畳めない。

| `CLEANUP_WT` | アクション |
|---|---|
| `in_worktree` | 1. `dirty=yes` なら生パス一覧を表示した上で**そのまま続行**（中止は破棄経路であり、破棄予定の変更に stash 確認を挟まない）。2. `ExitWorktree` を `action: "keep"` で呼び main checkout へ復帰する。3. 4.2.1 の remove を実行する |
| `in_main` | 1〜2 をスキップし 4.2.1 の remove のみ実行する（既削除なら no-op = 冪等） |
| `in_worktree_unrecorded` / `unknown` | `ExitWorktree` が main checkout へ戻せない（または分類不能）。**worktree 削除とブランチ削除（4.3）を試行せず**、Phase 7 の報告で未完了として列挙し、main checkout での `/rite:issue-cancel {issue_number}` 再実行へ委譲する。worktree 内で完結する 4.4〜4.6・Phase 5・Phase 6 は通常どおり実行する |
| `none` | worktree 無し。4.3 へ |

#### 4.2.1 remove の実行

```bash
_wt_rc=0
bash {plugin_root}/hooks/scripts/cleanup-session-worktree-teardown.sh remove \
  --worktree "{flow_wt}" --pr-merged "false" --self-root "$PPID" || _wt_rc=$?
if [ "$_wt_rc" -ne 0 ]; then
  echo "WARNING: worktree teardown helper が rc=${_wt_rc} で失敗しました。作業ツリーは未処理のまま残ります" >&2
  echo "[CONTEXT] WORKTREE_REMOVE_FAILED=1; path={flow_wt}; rc=${_wt_rc}" >&2
fi
```

`--pr-merged "false"` は中止経路の常であり、reap manifest への記録は行われない（未マージの作業ツリーを自動回収の対象にしない）。`--self-root` にはこの Bash 呼び出しの `$PPID`（= claude ハーネス）を渡す。`WORKTREE_REMOVE_FAILED` / `WORKTREE_REMOVE_SKIPPED_LIVE_CWD` / `WORKTREE_REMOVE_SKIPPED_SANDBOX_MASK` は WARNING を表示して続行し、Phase 7 に残置として列挙する。

### 4.3 ブランチの削除

> **順序制約**: ブランチ削除は **worktree 削除が完了した後にのみ成功する**（Git 制約: worktree で checkout 中の branch は削除できない）。必ず 4.2 の後に実行する。`{branch_identity_verified}` が `false` のときは本ステップ全体をスキップする。

```bash
bash {plugin_root}/hooks/scripts/cleanup-branch-delete.sh \
  --branch "{branch_name}" --pr-merged "false" \
  --branch-identity-verified "{branch_identity_verified}"
```

中止経路は `--pr-merged "false"` を渡すため、helper は `BRANCH_DELETE_UNMERGED=1` を emit する。**この marker に対して確認を挟まず強制削除する** — 中止は破棄すると決めた後の経路であり、破棄の再確認は AC「ブランチが残らない」に反する:
rationale: references/rationale.md#force-delete-no-ask

```bash
LC_ALL=C git branch -D {branch_name} && echo "[CONTEXT] BRANCH_DELETED=1; branch={branch_name}; via=cancel-force"
```

`BRANCH_DELETE_DEFERRED=1`（作業ツリーが残り削除を遅延）のときは強制削除しない。Phase 7 に残置として列挙する。リモートブランチの削除は同 helper が `REMOTE_BRANCH_*` marker 群で扱う。

### 4.4 PR-specific state ファイルの削除

> **`{pr_number}` が未確定（PR 無し）のときは本ステップをスキップする**（削除対象の glob が確定しない）。

```bash
_sp_rc=0
bash {plugin_root}/hooks/scripts/cleanup-pr-state-purge.sh --pr "{pr_number}" || _sp_rc=$?
if [ "$_sp_rc" -ne 0 ]; then
  echo "WARNING: state purge helper が rc=${_sp_rc} で失敗しました。PR-specific state ファイルが残っています" >&2
fi
```

### 4.5 作業メモリの削除

```bash
bash {plugin_root}/hooks/cleanup-work-memory.sh --issue {issue_number} \
  || echo "WARNING: 作業メモリの削除に失敗しました（.rite/work-memory/issue-{issue_number}.md が残る可能性）" >&2
```

Issue コメント側の work memory replica は**削除しない**。中止した Issue の作業経緯は Issue に残るべき記録であり、中止理由コメントと同じ場所で追跡できる。
rationale: references/rationale.md#keep-wm-replica

### 4.6 claim 解放と cross-session state の回収

```bash
bash {plugin_root}/hooks/issue-claim.sh release --issue {issue_number} 2>&1 \
  || echo "WARNING: issue-claim release が失敗しました（claim は stale 判定 + reap で回収されます）" >&2
```

```bash
bash {plugin_root}/hooks/flow-state.sh reap-issue --issue {issue_number} 2>&1 \
  || echo "WARNING: reap-issue が失敗しました（stale flow-state / run-queue / lock が残る可能性）" >&2
```

### 4.7 Wiki ingest は実行しない

中止した Issue に対して Wiki ingest は走らせない。rite の Wiki はプロジェクトドメインの経験則を置く場所であり、個別 Issue を中止した理由は Issue のコメントに残れば足りる。
rationale: references/rationale.md#no-wiki-ingest

---

## Phase 5: Projects Status を Cancelled に更新

Read ツールで `rite-config.yml` の `github.projects.enabled` を確認する。`false`（または `rite-config.yml` 不在）なら本 Phase を**スキップ**して Phase 6 へ進む — Issue クローズと後片付けは Projects の有無に依存しない。

`enabled: true` のときは `projects-status-update.sh` へ委譲する（`skills/open/SKILL.md` ステップ 2.4 / `skills/issue-close/SKILL.md` Shared 節と同一の delegate パターン）。`Cancelled` は `references/projects-integration.md` の "Terminal Status Set" が定める終端 Status の一方で、`NOT_PLANNED` クローズの行き先はこちら:

```bash
status_json_args=$(jq -n \
  --argjson issue {issue_number} --arg owner "{owner}" --arg repo "{repo}" \
  --argjson project_number {project_number} --arg status "Cancelled" \
  --argjson auto_add false --argjson non_blocking true \
  '{issue_number:$issue, owner:$owner, repo:$repo, project_number:$project_number, status_name:$status, auto_add:$auto_add, non_blocking:$non_blocking}')
bash {plugin_root}/scripts/projects-status-update.sh "$status_json_args"
```

`auto_add: false` — 中止する Issue を board へ新規登録する理由は無い。

**`.result` による分岐**（全分岐 non-blocking。Status 更新の失敗は中止フローを止めない）:

| `.result` | 表示 |
|-----------|------|
| `"updated"` | `Projects Status を "Cancelled" に更新しました` |
| `"skipped_not_in_project"` | `警告: Issue #{issue_number} は Project に登録されていません。Status 更新をスキップします` |
| `"failed"` / 上記以外の未知値 | `.warnings[]` を stderr に出し、`警告: Projects Status の "Cancelled" 更新に失敗しました。手動: GitHub Projects 画面で Status を Cancelled に変更、または gh project item-edit --project-id <project_id> --id <item_id> --field-id <status_field_id> --single-select-option-id <cancelled_option_id>` を表示 |

board に `Cancelled` option が存在しないプロジェクトでは option-ID 解決に失敗し `failed` に落ちる（helper の通常の失敗経路で loud に出る）。option の provisioning は本スキルの責務ではない。

---

## Phase 6: Issue を NOT_PLANNED でクローズ

> **Phase 2.1 で `CLOSED` を観測した経路は本 Phase をスキップする**（再クローズしない）。

理由コメントとクローズを 1 コールで行い、「理由の無いクローズ」が成立する窓を作らない:

```bash
cancel_reason=$(cat "{reason_file}")
if gh issue close {issue_number} -R {owner_repo} --reason "not planned" \
     --comment "🚫 この Issue を中止しました。

理由: $cancel_reason

中止の記録は /rite:issue-cancel が残しています。board Status は Cancelled です。"; then
  echo "[CONTEXT] CANCEL_ISSUE_CLOSED=1; issue={issue_number}"
else
  issue_close_rc=$?
  echo "[CONTEXT] CANCEL_ISSUE_CLOSE_FAILED=1; issue={issue_number}; rc=$issue_close_rc" >&2
  echo "ERROR: Issue #{issue_number} のクローズに失敗しました (rc=$issue_close_rc)" >&2
fi
```

| marker | アクション |
|---|---|
| `CANCEL_ISSUE_CLOSED=1` | Phase 7 へ |
| `CANCEL_ISSUE_CLOSE_FAILED=1` / marker 不在 | **停止する**。board が `Cancelled` で Issue が OPEN という state 不整合を Phase 7 の報告に明示し、手動復旧コマンド `gh issue close {issue_number} -R {owner_repo} --reason "not planned"` を表示する |

**親 Issue には伝播しない**。子 Issue を中止しても親の Tasklist 更新・親の board Status 更新・親の auto-close を行わない。`Cancelled` の子を含む親を完了扱いにしないため、および親を中止しても子は各自の明示指示で中止するため。
rationale: references/rationale.md#no-parent-propagation

---

## Phase 7: 完了報告

```
## /rite:issue-cancel 完了

- Issue: #{issue_number} - {issue_title}（NOT_PLANNED でクローズ）
- 中止理由: {cancel_reason}
- PR: #{pr_number}（マージせずクローズ）／ なし
- ブランチ: {branch_name}（削除済み）／ 残置（理由）／ なし
- セッション worktree: 削除済み ／ 残置（理由）／ なし
- board Status: Cancelled へ更新 ／ 更新失敗（手動対応が必要）／ Projects 無効のためスキップ

（未完了項目があるときのみ）未完了:
- {項目}: {理由と手動復旧コマンド}
```

`CLOSED` な Issue に対する冪等実行では、報告を board Status の同期結果だけに絞る:

```
## /rite:issue-cancel 完了（Status 同期のみ）

Issue #{issue_number} は既にクローズ済みです（stateReason: {state_reason}）。
board Status のみ同期しました: Cancelled

PR クローズ・後片付け・再クローズは実行していません。
```

---

## エラー時の方針

- **PR クローズ失敗は fail-loud で停止**。Status も Issue クローズも後片付けも行わない（順序制約を守れないまま先へ進むと `post-compact.sh` が Status を `In Review` へ戻す窓が開く）
- **Projects Status 更新の失敗は non-blocking**。WARNING と手動更新コマンドを出して Issue クローズへ進む
- **Issue クローズ失敗は停止**。board と Issue の state 不整合を完了報告に明示する
- **後片付け helper の失敗は non-blocking**。WARNING を出して続行し、Phase 7 に未完了として列挙する
- 中止理由を取得できないときは Issue をクローズせず停止する
