---
name: merge
description: |
  rite workflow の PR squash merge ステップ。指定 PR を `gh pr merge --squash` でマージする
  （cleanup は走らせない → 別途 /rite:cleanup）。/rite:iterate・/rite:ready・/rite:batch-run から
  programmatic に呼ばれる sub-step、または手動 /rite:merge <pr>。汎用の「PR をマージ」
  ヘルパーではなく、その語では auto-activate しない。
  起動: /rite:merge <pr_number>
argument-hint: "[--force-ci] <pr_number>"
---

# /rite:merge

> **質問規律**: すべての質問・再判定判断は [question_resolution](../rite-workflow/references/coding-principles.md#question_resolution-resolve-recommended-reversible-decisions-autonomously) に従う。merge 自体は不可逆操作として既存の承認境界を維持する。

## Contract

**Input**: `[--force-ci]` + PR number (required)
**Output**: `[merge:returned-to-caller]` / `[merge:not-ready]` / `[merge:error]`

`gh pr merge --squash` を叩いて PR をマージするだけ。**cleanup は走らせない**。マージ後の cleanup は `/rite:cleanup` を別途実行する。

## E2E Output Minimization

**環境起因の迂回・リトライの出力姿勢**: [common-error-handling.md#environment-workaround-output-posture](../../references/common-error-handling.md#environment-workaround-output-posture) — 成功時は無言、失敗時は行動可能な 1 行のみ（規則本文はそちら。本スキルは複製しない）。

## Arguments

| Argument | Description |
|----------|-------------|
| `--force-ci` | CI が不健全でも内訳を表示した上でマージへ進む明示的 override。位置非依存。通常は指定しない |
| `{pr_number}` | 引数中の PR 番号 (required) |

> 引数は位置非依存で解析し、`--force-ci` の有無と最初の数値をそれぞれ retain する。本文中の
> `{pr_number}` placeholder はその数値に展開する。数値が無ければ `[merge:error]` で終了する。

## Placeholder Legend

| Placeholder | Source |
|-------------|--------|
| `{arguments}` | コマンドへ渡された引数文字列全体（`--force-ci` の位置非依存検出に使う） |
| `{pr_number}` | 引数 `$1` |
| `{branch_name}` | ステップ 1 の `gh pr view --json headRefName` から取得 |
| `{owner_repo}` | [Owner/Repo Resolution](../../references/gh-cli-patterns.md#ownerrepo-resolution-ssh-host-alias-safe) で解決した owner/repo（slash 形式）を literal substitute |

---

## ステップ 1: mergeable 判定

Ready/merge 可否の権威判定はここ (`gh pr view`) に一本化する。前提チェックは設けず flow-state 不在を正常系として扱う。
rationale: references/rationale.md#no-flow-state-prereq

rationale: references/rationale.md#ci-wait-bounded
本ステップ 1 の bash block は Bash ツール `timeout: 600000` で実行する（既定 120 秒だと待ち上限 540 秒に届く前に打ち切られる）。
```bash
force_ci=false
case " {arguments} " in *" --force-ci "*) force_ci=true ;; esac

# 待ち loop からも同じ取得・分類を使う（分類ロジックを複製しない）。
_rite_fetch_pr_json() {
  gh pr view {pr_number} -R {owner_repo} --json mergeable,mergeStateStatus,isDraft,headRefName,statusCheckRollup
}
# statusCheckRollup を排他的に機械分類する。既知の成功 conclusion 以外を healthy にしない。
# malformed / 未知値は unknown として fail-closed にする。
_rite_classify_checks() {
  printf '%s' "$1" | jq -r '
  if (.statusCheckRollup | type) != "array" then "unknown"
  elif (.statusCheckRollup | length) == 0 then "none"
  # 集約 precedence は unknown > pending > unhealthy > healthy。
  # mixed pending+unknown を pending に落とすと --force-ci で unknown を迂回できるため unknown を先に判定する。
  elif any(.statusCheckRollup[];
      (.__typename == "CheckRun" and
        ((.status | type) != "string" or
         (.status as $s | (["QUEUED", "IN_PROGRESS", "WAITING", "REQUESTED", "PENDING", "COMPLETED"] | index($s)) == null) or
         (.status == "COMPLETED" and (.conclusion | type) != "string"))) or
      (.__typename == "StatusContext" and
        ((.state | type) != "string" or
         (.state as $s | (["PENDING", "EXPECTED", "SUCCESS", "ERROR", "FAILURE"] | index($s)) == null))) or
      (.__typename != "CheckRun" and .__typename != "StatusContext")) then "unknown"
  elif any(.statusCheckRollup[];
      (.__typename == "CheckRun" and .status != "COMPLETED") or
      (.__typename == "StatusContext" and (.state == "PENDING" or .state == "EXPECTED"))) then "pending"
  elif any(.statusCheckRollup[];
      (.__typename == "CheckRun" and
        (.conclusion as $c | (["SUCCESS", "NEUTRAL", "SKIPPED"] | index($c)) == null)) or
      (.__typename == "StatusContext" and (.state == "ERROR" or .state == "FAILURE"))) then "unhealthy"
  elif all(.statusCheckRollup[];
      (.__typename == "CheckRun" and .status == "COMPLETED" and
        (.conclusion as $c | (["SUCCESS", "NEUTRAL", "SKIPPED"] | index($c)) != null)) or
      (.__typename == "StatusContext" and .state == "SUCCESS")) then "healthy"
  else "unknown"
  end
'
}

pr_json=$(_rite_fetch_pr_json) \
  || { echo "[merge:not-ready]"; echo "ERROR: PR/CI 状態を取得できないためマージしません" >&2; exit 1; }

checks_state=$(_rite_classify_checks "$pr_json") || checks_state=unknown
[ -n "$checks_state" ] || checks_state=unknown
echo "[CONTEXT] MERGE_CHECKS_STATE=$checks_state"

# pending + force_ci == false だけ待つ。混在 pending+FAILURE は fail-fast せず != pending まで。
if [ "$checks_state" = "pending" ] && [ "$force_ci" = "false" ]; then
  pending_n=$(printf '%s' "$pr_json" | jq '[.statusCheckRollup[] | select(
      (.__typename == "CheckRun" and .status != "COMPLETED") or
      (.__typename == "StatusContext" and (.state == "PENDING" or .state == "EXPECTED"))
    )] | length')
  echo "[CONTEXT] MERGE_CHECKS_WAIT=started pending=$pending_n"
  waited=0
  while [ "$checks_state" = "pending" ] && [ "$waited" -lt 540 ]; do
    sleep 15
    waited=$((waited + 15))
    pr_json=$(_rite_fetch_pr_json) \
      || { echo "[merge:not-ready]"; echo "ERROR: PR/CI 状態を取得できないためマージしません" >&2; exit 1; }
    checks_state=$(_rite_classify_checks "$pr_json") || checks_state=unknown
    [ -n "$checks_state" ] || checks_state=unknown
  done
  if [ "$checks_state" = "pending" ]; then
    pending_names=$(printf '%s' "$pr_json" | jq -r '[.statusCheckRollup[] | select(
        (.__typename == "CheckRun" and .status != "COMPLETED") or
        (.__typename == "StatusContext" and (.state == "PENDING" or .state == "EXPECTED"))
      ) | (.name // .context // "?")] | join(", ")')
    echo "ERROR: CI checks still pending after 540s: $pending_names" >&2
    echo "[merge:not-ready]"
  fi
  echo "[CONTEXT] MERGE_CHECKS_STATE=$checks_state"
fi
```

`headRefName` の値は完了通知 (ステップ 3) の `{branch_name}` 展開に使うため retain する (flow-state 不在でもブランチ名が空にならない)。

| 状態 | アクション |
|------|-----------|
| `isDraft == true` | `[merge:not-ready]` emit + 「先に `/rite:ready {pr_number}` を実行してください」案内 + 終了 |
| `mergeable != "MERGEABLE"` | 再判定は可逆なので、原因 (`mergeStateStatus`) を表示・既存 work memory に記録して 1 回だけ自動再判定する。再度非 MERGEABLE なら `[merge:not-ready]` を emit して終了 |
| `mergeable == "MERGEABLE"` + checks 0 件 | CI 未設定リポジトリとして従来どおりステップ 2 へ |
| `mergeable == "MERGEABLE"` + checks が pending + `force_ci == false` | 上の bash が待ち loop を実行済み。`MERGE_CHECKS_STATE` の**最終行**で既存分類へ合流する。最終行がまだ `pending`（上限到達）なら `[merge:not-ready]` emit + 「checks の完了を待って再実行」と表示して終了（未完了 check 名は bash が stderr 済み） |
| checks が pending + `force_ci == true` | 待ち loop に入らない。未完了 check の一覧を表示した後、ステップ 2 へ |
| `mergeable == "MERGEABLE"` + `mergeStateStatus == "UNSTABLE"`（checks unhealthy）+ `force_ci == false` | 下記「CI red の分類」を実行して内訳を表示し、`[merge:not-ready]` emit + `/rite:merge --force-ci {pr_number}` を案内して終了。ステップ 2 の `gh pr merge` は実行しない |
| checks unhealthy + `force_ci == true` | 下記分類と内訳表示を省略せず実行した後、ステップ 2 へ |
| `mergeable == "MERGEABLE"` + checks が全件 healthy | ステップ 2 へ |
| `checks_state == "unknown"`（malformed / 未知 status・conclusion / jq 失敗） | `[merge:not-ready]` emit + 生の `statusCheckRollup` を表示して終了。`--force-ci` でも unknown は override しない |

> **「再判定」option の挙動**: 再判定は **1 回のみ**（mergeable 再計算遅延向け。CI 待ち loop の `sleep 15` とは別）。再判定後も `MERGEABLE` でなければ `[merge:not-ready]` で確定終了する。mergeable 再判定に自動 sleep は提供しない。
> rationale: references/rationale.md#rematch-once
> rationale: references/rationale.md#ci-wait-bounded

### CI red の分類

`statusCheckRollup` の check run URL から Actions run ID を重複なく取得し、各 run に対して
`gh api repos/{owner_repo}/actions/runs/{run_id}/jobs --paginate` を実行する。`gh pr checks` の表示文字列
（`fail` 等）は分類根拠に使わない。red の各 job は観測可能な事実だけで次の 2 群へ分類する:

- **未実行**: `runner_name` が空、かつ `steps | length == 0`
- **実失敗**: 上記以外の red job（runner 割当あり、または 1 step 以上が実行済み）。`conclusion == "cancelled"` でも runner/steps が存在すればこちらに含める

出力には job 名・run ID・conclusion を群別に列挙する。未実行が 1 件以上なら
`gh run rerun {run_id} -R {owner_repo} --failed` を run ごとに案内し、全 red job が未実行なら
「CI シグナルが存在しない（テストコードは実行されていない）」と明示する。自動で rerun してはならない。

run ID を解決できない、または `gh api .../jobs` が 1 件でも失敗した場合は「分類不能」と原因を表示し、
`force_ci == false` では必ず `[merge:not-ready]` へ倒す。分類不能を checks healthy や checks 0 件として
扱ってはならない。`force_ci == true` の場合も分類不能である事実を表示してからのみステップ 2 へ進める。

`mergeStateStatus == "BLOCKED"` は required review 等も含むため、本分類へ合流させず既存の
`mergeable != "MERGEABLE"` 経路で停止する。本ゲートの対象は checks 起因の `UNSTABLE` と pending に限定する。

## ステップ 2: マージ実行

```bash
# canonical signal-specific trap pattern (../../references/bash-trap-patterns.md 参照、fix スキル ステップ 2.4 と対称)
gh_err=""
_rite_merge_cleanup() {
  rm -f "${gh_err:-}"
}
trap 'rc=$?; _rite_merge_cleanup; exit $rc' EXIT
trap '_rite_merge_cleanup; exit 130' INT
trap '_rite_merge_cleanup; exit 143' TERM
trap '_rite_merge_cleanup; exit 129' HUP

if gh_err=$(mktemp "${TMPDIR:-/tmp}/rite-merge-gh-err-XXXXXX" 2>/dev/null); then
  :
else
  mktemp_gh_err_rc=$?
  echo "WARNING: gh stderr 退避用 tempfile の mktemp に失敗しました (rc=$mktemp_gh_err_rc)。gh pr merge の stderr 詳細は失われます" >&2
  echo "  対処: /tmp の inode 枯渇 / read-only filesystem / permission 拒否のいずれかを確認してください" >&2
  echo "[CONTEXT] MERGE_MKTEMP_DEGRADED=1; reason=mktemp_failure_gh_err; rc=$mktemp_gh_err_rc" >&2
  gh_err=""
fi

if gh pr merge {pr_number} -R {owner_repo} --squash --delete-branch=false 2>"${gh_err:-/dev/null}"; then
  echo "<!-- skill return signal: caller must continue next step -->"
  echo "<!-- [merge:returned-to-caller] -->"
  # 成功時のみ stderr の warning (deprecation / rate-limit) を surface する。
  # 失敗時に同 stderr を head -5 で再表示すると、下の else block の head -10 と二重出力に
  # なるため、warning surface は then-branch 内に閉じ込める。
  if [ -n "$gh_err" ] && [ -s "$gh_err" ]; then
    echo "  WARNING (gh stderr):" >&2
    head -5 "$gh_err" | sed 's/^/    /' >&2
  fi
  : # success path を exit 0 に固定。warning surface を if…fi で書いても &&チェーンに崩して転記しても、末尾の no-op により block が成功扱いで終わり trap の exit $rc が偽の 1 を返さない
  # 完了通知は ステップ 3 で表示
else
  merge_rc=$?
  echo "[merge:error]"
  echo "ERROR: gh pr merge failed (rc=$merge_rc)" >&2
  if [ -n "$gh_err" ] && [ -s "$gh_err" ]; then
    echo "  詳細 (stderr):" >&2
    head -10 "$gh_err" | sed 's/^/    /' >&2
  fi
  # AskUserQuestion を LLM 側で起動: 「再試行 / 中止」
fi
```

| 終了 status | アクション |
|------------|-----------|
| `[merge:returned-to-caller]` emit | ステップ 3 完了通知へ |
| `[merge:error]` emit | bash block が stderr に gh error 詳細を出力済み。LLM は AskUserQuestion で「再試行 / 中止」を提示 |

## ステップ 3: 完了通知

ステップ 1 の `gh pr view --json headRefName` で取得した値を `{branch_name}` placeholder に展開して以下を表示:

```
## /rite:merge 完了

- PR: #{pr_number}
- マージ方式: squash
- ブランチ: {branch_name} (`/rite:merge` はローカルブランチを削除していません。リモートは `delete_branch_on_merge: true` のリポジトリでは既に削除済みの場合があります)

次のステップ:
- クリーンアップ: /rite:cleanup {pr_number}
  (ブランチ削除 / Projects Status → Done / Issue close / Wiki ingest 等)

<!-- skill return signal: caller must continue next step -->
<!-- [merge:returned-to-caller] -->
```

---

## 設計判断

- **`--delete-branch=false` 明示**: `gh` の default 挙動に任せてクライアント側から削除 API を呼ぶことを抑止し、ブランチ削除を `/rite:cleanup` の責務に寄せる。ただし**抑止できるのは gh クライアント側の削除だけ**で、リポジトリ設定 `delete_branch_on_merge: true` の環境では GitHub がマージ完了時にサーバサイドで head ブランチを削除する。このフラグはそれを止められないため、「マージ後もブランチが必ず残る」ことは保証されない。`/rite:cleanup` のリモート削除ステップは、この既削除を正常系として扱う（`skills/cleanup/SKILL.md` ステップ 5 の `git ls-remote --exit-code` ガード）
- その他（責務は merge のみ / flow-state は触らない / squash ハードコード / stderr 分離 / CI gate は merge 直前だけ）:
  rationale: references/rationale.md#merge-only
  rationale: references/rationale.md#squash-hardcoded
  rationale: references/rationale.md#stderr-split
  rationale: references/rationale.md#ci-gate-at-merge
  rationale: references/rationale.md#ci-wait-bounded
