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
| `{candidate_pr_number}` | Phase 2.3 の `CANCEL_PR_CANDIDATES` marker が並べた候補 PR 番号（1 件ずつ substitute する） |
| `{branch_name}` | Phase 2 で確定したブランチ名（PR の `headRefName`（`issue-{issue_number}-` を含み、かつ `^[A-Za-z0-9._/-]+$` に一致する場合のみ）、flow-state（対象 Issue 一致時）、またはローカルブランチ検索の一意候補） |
| `{branch_identity_verified}` | Phase 2 の identity 検証結果（`true` / `false`） |
| `{flow_wt}` | Phase 4.1 の `CLEANUP_WT` marker の `worktree=` 値 |
| `{cleanup_wt}` | Phase 4.1 の `CLEANUP_WT` marker の分類値（`in_worktree` / `in_main` / `in_worktree_unrecorded` / `unknown` / `none`） |
| `{issue_title}` | Phase 2.1 の `gh issue view --json title` |
| `{state_reason}` | Phase 2.1 の `gh issue view --json stateReason` |
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

確定した理由は Write ツールでファイルへ書き出し `{reason_file}` として retain する（Phase 3 / Phase 6 が変数経由で `--comment` へ渡す。特殊文字を含む理由をコマンドラインへ literal 展開しないため）。**書き出し先をセッション worktree 配下にしてはならない** — Phase 4.2 の worktree 削除が Phase 1 と Phase 6 の間でファイルごと消し、理由の無いクローズが成立する。
rationale: references/rationale.md#reason-file-outside-worktree

**書き出し先は bash が解決した実パスをリテラル置換する**。Write ツールはシェルのパラメータ展開を行わないため、`${TMPDIR:-/tmp}` を含む文字列をそのまま file_path に渡してはならない（未展開のリテラルパスへ書き、bash 側で展開される Phase 3 / Phase 6 の `cat` が別の場所を読む）。先に marker を出し、その値を使う:
rationale: references/rationale.md#write-vs-bash-path

```bash
echo "[CONTEXT] CANCEL_TMP_DIR=${TMPDIR:-/tmp}"
```

`{reason_file}` = `CANCEL_TMP_DIR` marker の値 + `/rite-issue-cancel-reason-{issue_number}.txt` のリテラル置換。素の `/tmp` を再ハードコードしない（sandbox 有効環境では書き込みが拒否される）。

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

### 2.2 作業ブランチの解決（PR 検索より先）

**ブランチの解決を PR 検索より先に行う**。`gh pr list` の `--search` / `--head` はどちらも Issue 番号でスコープできないため、実ブランチ名を確定させてから exact `--head` で引くのが唯一の確実な経路になる。
rationale: references/rationale.md#branch-first-pr-lookup

flow-state の記録は**現在のセッション**のものであり `--issue` を取らない。対象 Issue と一致するときだけ採用する（一致検証なしで採用すると、別 Issue のセッションから中止したときにそのセッションのブランチを削除対象にしてしまう）:
rationale: references/rationale.md#issue-scoped-identity

```bash
state_issue=$(bash {plugin_root}/hooks/flow-state.sh get --field issue_number --default "")
state_branch=$(bash {plugin_root}/hooks/flow-state.sh get --field branch --default "")
echo "[CONTEXT] CANCEL_STATE_ISSUE=$state_issue; CANCEL_STATE_BRANCH=$state_branch"
```

`state_issue` が `{issue_number}` と**一致しない、または空**なら flow-state 由来の値は捨て、Issue 番号でスコープされたローカルブランチ検索だけを使う:

```bash
git branch --list "*issue-{issue_number}-*" --format '%(refname:short)'
```

| 観測 | `{branch_name}` / `{branch_identity_verified}` |
|---|---|
| `state_issue == {issue_number}` かつ `state_branch` が非空 | `state_branch` / `true`（対象 Issue の作業ブランチとして flow-state が記録済み） |
| 上記に該当せず、ローカル候補が **ちょうど 1 件** | その値 / `true` |
| 上記に該当せず、候補が 0 件 | 未確定 / `false`。Phase 4.3 のブランチ削除をスキップする（削除対象が無い） |
| 上記に該当せず、候補が 2 件以上 | 未確定 / `false`。候補を表示し、ブランチ削除をスキップして残りの中止処理を続行する（identity 未確定のまま削除しない） |

### 2.3 関連 PR の検索と identity 検証

`{branch_identity_verified}=true` のときは実ブランチ名で **exact match** の `--head` を使う。`--head` はワイルドカードを解釈しないため glob を渡してはならない:

```bash
gh pr list -R {owner_repo} --head "{branch_name}" --state all --json number,state,isDraft,headRefName,mergedAt,url
```

ブランチが未確定（`{branch_identity_verified}=false`）、または上記が 0 件のときは **Issue の timeline から候補 PR を引く**。`gh pr list` には Issue でスコープする手段が無い — `--search "linked:issue:{issue_number}"` は GitHub が `linked:issue` を boolean qualifier として解釈して `:{N}` を無視するため任意の Issue で同じ集合を返し、`--state all --limit N` は最新 N 件の取得**窓**でしかない（活発なリポジトリでは常に飽和し、窓外のマージ済み PR を「PR 無し」と読ませる）:
rationale: references/rationale.md#issue-scoped-pr-lookup

`gh api` は**単体コマンドとして rc を確定させてから**整形へ渡す。パイプの末尾に置くと `$?` は最終段（`sort`）のものになり、取得失敗の rc が消えて直下の fail-loud ガードが到達不能になる。`select` は truthiness で書く — `!= null` は `hooks/pre-tool-bash-guard.sh` が実行前に deny するため、記述どおりに走らない。
rationale: references/rationale.md#timeline-rc-capture-first

```bash
_tl_rc=0
_tl_err=$(mktemp "${TMPDIR:-/tmp}/rite-cancel-timeline-err-XXXXXX") || {
  echo "ERROR: timeline 取得用の stderr 退避ファイルを作成できません。関連 PR の有無を確認できないため中止します" >&2
  exit 1
}
_tl_raw=$(gh api "repos/{owner}/{repo}/issues/{issue_number}/timeline" --paginate \
  --jq '.[] | select(.event=="cross-referenced" or .event=="connected") | .source.issue | select(.pull_request) | .number' \
  2>"$_tl_err") || _tl_rc=$?
if [ "$_tl_rc" -ne 0 ]; then
  echo "ERROR: Issue timeline を取得できません (rc=${_tl_rc})。関連 PR の有無を確認できないため中止します" >&2
  head -5 "$_tl_err" | sed 's/^/  /' >&2
  rm -f "$_tl_err"
  exit 1
fi
rm -f "$_tl_err"
pr_candidates=$(printf '%s\n' "$_tl_raw" | sort -un)
echo "[CONTEXT] CANCEL_PR_CANDIDATES=$(printf '%s' "$pr_candidates" | tr '\n' ',')"
```

timeline は Issue にスコープされ取得窓を持たないため、**絞り込み結果 0 件は「関連 PR が無い」と読んでよい**。停止するのは取得自体が失敗したときだけで、0 件と取得失敗を同じ値へ畳まない。

候補ごとに詳細を引く（候補は通常 0〜3 件）:

```bash
gh pr view {candidate_pr_number} -R {owner_repo} --json number,state,isDraft,headRefName,mergedAt,url,body
```

timeline は closing keyword を伴わない単なる言及（cross-reference）も返すため、`body` が `Closes/Fixes/Resolves #{issue_number}`（大文字小文字を問わない、`#{issue_number}` の直後が数字でない）にマッチする PR、または `headRefName` が `issue-{issue_number}-` を含む PR **だけ**を残す。**絞り込み前の集合を下記の判定表に載せてはならない** — 無関係な merged PR で第 1 行が誤発火する。

| 観測（絞り込み後） | アクション |
|---|---|
| `mergedAt` が非 null の PR がある | **中止ではなく完了済み**。`/rite:cleanup {pr_number}` を案内して**停止する**（マージ済みの作業を NOT_PLANNED で葬らない） |
| `state == "OPEN"` の PR がある | `{pr_number}` と `headRefName` を retain して Phase 3 へ。**identity 昇格は `headRefName` が `issue-{issue_number}-` を含み、かつ `headRefName` 全体が `^[A-Za-z0-9._/-]+$` に一致する場合に限る** — その場合だけ `headRefName` を `{branch_name}`、`{branch_identity_verified}=true` にする。body の closing keyword だけで一致した PR、および charset に非一致の PR は `{branch_name}` / `{branch_identity_verified}` を **2.2 で解決した値のまま据え置く**（この flag は helper のリモート ref 削除の唯一のゲートであり、無関係な PR の head をリモートごと消させないため） |
| `state == "CLOSED"` かつ `mergedAt` が null の PR がある | 既にクローズ済み（手動 close / 本スキルの再実行）。`{pr_number}` を retain し **Phase 3 はスキップ**して Phase 4 へ（4.4 の state purge を発火させる）。`{branch_name}` / `{branch_identity_verified}` の扱いは上の OPEN 行と同一 |
| 該当 PR が 1 件も無い | `{pr_number}` は未確定。2.2 で解決したブランチのまま Phase 4 へ（Phase 3 はスキップ） |

`headRefName` を経由せずにブランチ名を推測しない。charset に非一致だったときは WARNING を出し、Phase 7 に「ブランチ: 残置（head 名が `^[A-Za-z0-9._/-]+$` に非一致）」として列挙する。
rationale: references/rationale.md#identity-promotion-headref-only
rationale: references/rationale.md#headref-charset-binding

---

## Phase 3: PR クローズ（fail-loud）

> **`{pr_number}` が未確定（PR 無し）のときは本 Phase をスキップして Phase 4 へ進む。**

```bash
if ! pr_close_reason=$(cat "{reason_file}"); then
  echo "ERROR: 中止理由ファイルを読み出せません: {reason_file}" >&2
  exit 1
fi
if [ -z "$pr_close_reason" ]; then
  echo "ERROR: 中止理由が空です。理由なしで PR をクローズしません" >&2
  exit 1
fi
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

**順序制約**: `detect` → Issue 束縛ガード → `ExitWorktree` → `remove` の順に、**それぞれ独立したサブセクション**として実行する。cwd がセッション worktree 内のまま `remove` を呼ぶと自分の足元を削除することになるため 1 本の直列 helper に畳めず、また判定表の 1 セル内に手順を並べると順序が本文の書き換えだけで壊れる（序数で隣接行を参照する形も同じ理由で使わない）。
rationale: references/rationale.md#step-order-as-sections

#### 4.2.0 Issue 束縛ガード（4.2.1 / 4.2.2 へ到達する全経路の前段）

`CLEANUP_WT` の値に依らず**無条件に評価する**。detect の内側 (`cleanup-worktree-detect.sh`) は `in_worktree` を「flow-state の worktree == 現 cwd」だけで、`in_main` を「flow-state に worktree 記録があり cwd がその外」だけで判定し、いずれも `--issue` を見ない。したがって marker の `worktree=` は別 Issue のセッション worktree を指しうる。
rationale: references/rationale.md#issue-scoped-identity

```bash
wt_path="{flow_wt}"
if [ "{cleanup_wt}" = "unknown" ] || [ "{cleanup_wt}" = "in_worktree_unrecorded" ]; then
  echo "WARNING: 作業ツリーの分類が確定していません（CLEANUP_WT={cleanup_wt}）。worktree とブランチは削除しません" >&2
  echo "[CONTEXT] CANCEL_WT_BOUND=undetermined; cleanup_wt={cleanup_wt}" >&2
elif [ -z "$wt_path" ]; then
  echo "[CONTEXT] CANCEL_WT_BOUND=none; reason=no_worktree_path"
elif [ "$(basename "$wt_path")" = "issue-{issue_number}" ]; then
  echo "[CONTEXT] CANCEL_WT_BOUND=ok; path=$wt_path"
else
  echo "WARNING: detect が返した worktree は対象 Issue のものではありません: $wt_path（期待する末尾セグメント: issue-{issue_number}）" >&2
  echo "[CONTEXT] CANCEL_WT_BOUND=mismatch; path=$wt_path" >&2
fi
```

照合は**末尾セグメントの完全一致**にする（`issue-24931` を `issue-2493` に一致させる suffix 照合にしない）。

| `CANCEL_WT_BOUND` | アクション |
|---|---|
| `ok` | 4.2.1 へ |
| `none` | worktree 記録なし。4.2.1 / 4.2.2 をスキップして 4.3 へ |
| `mismatch` | 別 Issue の worktree。**4.2.1 / 4.2.2 と 4.3 のブランチ削除を試行せず**、Phase 7 に未処理として列挙する |
| `undetermined` | detect が分類できていない（`CLEANUP_WT=unknown` / `in_worktree_unrecorded`）。**4.2.1 / 4.2.2 と 4.3 のブランチ削除を試行せず**、Phase 7 に未処理として列挙し、main checkout での `/rite:issue-cancel {issue_number}` 再実行へ委譲する。worktree 内で完結する 4.4〜4.6・Phase 5・Phase 6 は通常どおり実行する |

#### 4.2.1 ExitWorktree（main checkout への復帰）

`CANCEL_WT_BOUND=ok` のときだけ実行する。

| `CLEANUP_WT` | アクション |
|---|---|
| `in_worktree` | `dirty=yes` なら生パス一覧を表示した上で**そのまま続行**（中止は破棄経路であり、破棄予定の変更に stash 確認を挟まない）。そのうえで `ExitWorktree` を `action: "keep"` で呼び main checkout へ復帰し、4.2.2 へ |
| `in_main` | 既に main checkout にいるため `ExitWorktree` は呼ばない。dirty 表示もしない。4.2.2 へ |

#### 4.2.2 remove の実行

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

helper が emit する marker で分岐する。**marker 不在は「削除成功」ではなく「実行結果を確認できていない」** を意味する（helper 契約）:

| marker | アクション |
|---|---|
| `BRANCH_DELETED=1` / `BRANCH_ALREADY_ABSENT=1` | 完了。Phase 7 へ（強制削除しない） |
| `BRANCH_DELETE_UNMERGED=1` | **確認を挟まず強制削除する**（下記）。中止は破棄すると決めた後の経路であり、破棄の再確認は AC「ブランチが残らない」に反する |
| `BRANCH_CHECK_FAILED=1` / `BRANCH_DELETE_FAILED=1` / `BRANCH_DELETE_DEFERRED*=1` | **強制削除しない**。helper が「判定できない / 削除できない」と結論した状態であり、迂回して消すと helper の fail-fast を無効化する。WARNING を出し Phase 7 に残置として列挙する |
| marker 不在 | 削除結果を確認できていない。強制削除せず Phase 7 に残置として列挙する |

`BRANCH_DELETE_UNMERGED=1` は `git branch -d` が not fully merged で失敗したときに限り出る（`--pr-merged "false"` を渡せば必ず出るわけではない）。強制削除は quote + `--` 終端子を伴う形で行う（helper と同一の安全性ではない点は rationale を参照）:
rationale: references/rationale.md#force-delete-no-ask

```bash
LC_ALL=C git branch -D -- "{branch_name}" && echo "[CONTEXT] BRANCH_DELETED=1; branch={branch_name}; via=cancel-force"
```

リモートブランチの削除は同 helper が `REMOTE_BRANCH_*` marker 群で扱う。`REMOTE_BRANCH_DELETE_FAILED` / `REMOTE_BRANCH_CHECK_FAILED` も Phase 7 に残置として列挙する。

### 4.4 PR-specific state ファイルの削除

> **`{pr_number}` が未確定（PR 無し）のときは本ステップをスキップする**（削除対象の glob が確定しない）。

helper は全運用経路で rc=0 を返し、部分失敗（rm 失敗・内側 helper 起動失敗）は `REVIEW_CLEANUP_PARTIAL_FAILURE=1` marker でのみ通知する。rc だけを見ると残置が完了として報告されるため、**marker を判定に使う**。判定は bash に持たせず `skills/cleanup/SKILL.md` の `{review_cleanup_check}` と同じく**出力に現れた marker を読んで**行う — 捕捉層を挟むと、その捕捉に失敗したときに marker ごと消えて「観測できていない」が「成功」に化ける。
rationale: references/rationale.md#helper-marker-not-rc

```bash
bash {plugin_root}/hooks/scripts/cleanup-pr-state-purge.sh --pr "{pr_number}" 2>&1 \
  || echo "WARNING: state purge helper が失敗しました。PR-specific state ファイルが残っています" >&2
```

上記の出力を読んで分岐する（marker は本呼び出しの出力に限って照合すればよく、`{review_cleanup_check}` のような `pr=` 境界一致は不要 — 他 PR 分の marker が混ざらないため）:

| 観測 | アクション |
|---|---|
| `REVIEW_CLEANUP_PARTIAL_FAILURE=1` を含む、または上記 WARNING が出た | 4.5 へ進み、Phase 7 に「PR-specific state ファイル: 残置」として列挙する |
| いずれも無い | 4.5 へ |

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

`reap-issue` には 4.4 のような**失敗専用 marker が無い**。`WARNING: reap-issue:` は「stale を見つけて非 active 化する」という成功経路の告知にも使われるため、接頭辞の有無を部分失敗の判別子にできない（着手後の中止では告知行が必ず出る）。`skills/cleanup/SKILL.md` の同じ呼び出しと同型に、出力を素通しして人間が読む形に留める:
rationale: references/rationale.md#reap-has-no-failure-marker

```bash
bash {plugin_root}/hooks/flow-state.sh reap-issue --issue {issue_number} 2>&1 \
  || echo "WARNING: reap-issue が失敗しました（stale flow-state / run-queue / lock が残る可能性）" >&2
```

`WARNING: reap-issue:` 行のうち `stale flow-state (active=true)` の告知**以外**が 1 行でもある、**または上記 WARNING が出た**（helper が起動せず接頭辞行が 1 本も出ない rc≠0 経路）ときは、Phase 7 に「cross-session state: 残置」として列挙する。告知行だけのときは残置ではない。**失敗語彙を列挙して判定しない** — helper に新しい失敗メッセージが増えたとき、列挙形は静かに「残置なし」へ倒れる。

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
if ! cancel_reason=$(cat "{reason_file}"); then
  echo "ERROR: 中止理由ファイルを読み出せません: {reason_file}。Issue をクローズしません" >&2
  exit 1
fi
if [ -z "$cancel_reason" ]; then
  echo "ERROR: 中止理由が空です。理由なしで Issue をクローズしません" >&2
  exit 1
fi
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
| `CANCEL_ISSUE_CLOSE_FAILED=1` / marker 不在 | **停止する**。board が `Cancelled` で Issue が OPEN という state 不整合を Phase 7 の報告に明示し、**理由を伴う**手動復旧コマンド `gh issue close {issue_number} -R {owner_repo} --reason "not planned" --comment "<中止理由>"` を表示する。`--comment` を省いた形を案内してはならない — 直前のガードが守った「理由なしでクローズしない」を人手で破らせることになる |

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
