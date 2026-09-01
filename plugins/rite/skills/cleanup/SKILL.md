---
name: cleanup
description: |
  rite workflow のマージ後クリーンアップ: ブランチ削除・Projects Status→Done・Issue close・
  Wiki ingest 等を実行する。/rite:batch-run・/rite:merge の後続として呼ばれる、または手動 /rite:cleanup [branch]。
  汎用の「後片付け」ヘルパーではなく、その語では auto-activate しない。
  起動: /rite:cleanup [branch_name]
argument-hint: "[branch_name]"
---

# /rite:cleanup

> **質問規律**: すべての質問・削除判断は [question_resolution](../rite-workflow/references/coding-principles.md#question_resolution-resolve-recommended-reversible-decisions-autonomously) に従う。PR/Issue/branch の削除・close・新規 Issue 公開は不可逆操作として確認を維持する。

PR マージ後のクリーンアップを実行する。やることは以下のシーケンシャルなタスク列:

0. flow-state を `phase=cleanup, active=true` に初期化
1. PR とブランチの状態を確認
2. 関連 Issue / 親 Issue を識別
3. 未完了タスクをチェック (あれば Issue 化を提示)
4. base ブランチを更新 (fetch + merge --ff-only)
5. ローカル / リモートブランチを削除
6. 残存非実測指摘の follow-up 起票 + PR-specific state ファイルを削除
7. transient cycle ブランチを削除
8. Projects Status を Done に更新
9. (Wiki が有効なら) `rite:wiki-ingest` で raw source を統合
10. 関連 Issue / 親 Issue をクローズ
11. 作業メモリを最終更新 + ローカルファイル削除 + 対象 Issue の cross-session state 回収
12. 完了報告を出す

途中で止まったら flow-state に `phase=cleanup, active=true` が残るので `/rite:recover` で再開する。

`{plugin_root}` は [Plugin Path Resolution](../../references/plugin-path-resolution.md) で解決する。

## E2E Output Minimization

**環境起因の迂回・リトライの出力姿勢**: [common-error-handling.md#environment-workaround-output-posture](../../references/common-error-handling.md#environment-workaround-output-posture) — 成功時は無言、失敗時は行動可能な 1 行のみ（規則本文はそちら。本スキルは複製しない）。

## Arguments

| Argument | Description |
|----------|-------------|
| `[branch_name]` | クリーンアップ対象ブランチ（省略時は現在のブランチ） |

---

## ステップ 0: flow-state 初期化

```bash
bash {plugin_root}/hooks/flow-state.sh set --phase "cleanup" --active true \
  --next "Execute cleanup tasks sequentially." \
  || bash {plugin_root}/hooks/flow-state.sh set --phase "cleanup" --issue 0 --branch "" --pr 0 --active true \
       --next "Execute cleanup tasks sequentially." \
  || echo "WARNING: flow-state init failed — recovery via /rite:recover may not work." >&2
```

---

## ステップ 1: PR とブランチの状態を確認

### 1.1 現在のブランチを確認

```bash
git branch --show-current
```

### 1.2 base ブランチを取得

`rite-config.yml` の `branch.base` を読む。未設定なら `git symbolic-ref refs/remotes/origin/HEAD | sed 's@^refs/remotes/origin/@@'` で検出。検出失敗時は誤ブランチ切替を防ぐため中断 (`rite-config.yml` の `branch.base` 設定 or `git remote set-head origin --auto` を案内)。

引数省略 + base branch 上にいる場合は `git branch --merged {base_branch}` で候補を表示し `/rite:cleanup <branch_name>` の指定を案内する。

### 1.3 関連 PR の検索と状態検証

> 以降の実行スニペットの `-R {owner_repo}` は、[Owner/Repo Resolution](../../references/gh-cli-patterns.md#ownerrepo-resolution-ssh-host-alias-safe)（ステップ 1.4 と同一の canonical 手順）で解決した owner/repo（slash 形式）をリテラル置換する（SSH host alias 環境対応。値が未解決ならステップ 1.4 の解決スニペットを先に実行して確定する）。

```bash
gh pr list -R {owner_repo} --head {branch_name} --state all --json number,title,state,mergedAt,url,headRefName
```

PR 未検出: `AskUserQuestion` で「ブランチを削除して続行 / キャンセル」を確認。未マージ PR: 「キャンセル (推奨) / 強制クリーンアップ」を確認。

PR 検出時は返却された `headRefName` と `{branch_name}` の完全一致時だけ `{branch_identity_verified}=true`
とする。不一致は削除対象 identity が確定しないため中断する。PR 未検出でユーザーが「ブランチを削除して続行」
を明示選択した場合だけ承認済み入力として `true`、それ以外は `false`。prefix denylist で identity を推測しない。

`mergedAt` が非 null（= PR が merge 済み）なら `{pr_merged}=true` として保持する。**それ以外のすべての経路**（未マージ PR の強制クリーンアップ、PR 未検出でブランチ削除を選んで続行した経路など）は `{pr_merged}=false` を既定とする。ステップ 4-W / ステップ 5 の全分岐で `{pr_merged}` を literal substitute する。
rationale: references/rationale.md#pr-merged-default

### 1.4 リポジトリ情報取得

```bash
# SSH host alias 対応: git-remote.sh 優先 + gh repo view fallback
# (canonical: references/gh-cli-patterns.md#ownerrepo-resolution-ssh-host-alias-safe)
owner_repo=$(bash {plugin_root}/hooks/scripts/lib/git-remote.sh resolve-owner-repo 2>/dev/null) || owner_repo=""
owner=""; repo=""
[ -n "$owner_repo" ] && IFS=$'\t' read -r owner repo <<< "$owner_repo"
[ -n "$owner" ] && [ -n "$repo" ] || {
  owner=$(gh repo view --json owner --jq '.owner.login')
  repo=$(gh repo view --json name --jq '.name')
}
```

---

## ステップ 2: 関連 Issue / 親 Issue を識別

### 2.1 関連 Issue 識別

PR body の `Closes/Fixes/Resolves #XX` またはブランチ名の `issue-XX` から識別:

```bash
gh pr view {pr_number} -R {owner_repo} --json body,headRefName
gh issue view {issue_number} -R {owner_repo} --json number,title,state,body
```

### 2.2 親 Issue 検出

Sub-Issues API を優先し、無ければ Tasklist fallback。見つかれば `{parent_issue_number}` / `{parent_issue_title}` / `{parent_issue_state}` を保持。

```bash
gh api graphql -H "GraphQL-Features: sub_issues" -f query='
query($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) { issue(number: $number) { parent { number title state } } }
}' -f owner="{owner}" -f repo="{repo}" -F number={issue_number}
```

Tasklist fallback では、複数候補を取得し、自己マッチ除外＋候補 body の tasklist 行再検証を経た候補のみ採用する。検証ループ本体（自己除外・再検証 regex・`--limit 10`）は close.md Phase 4.5.1 / projects-integration.md §2.4.7.1 と揃える。`--state` は cleanup が `--state open`（子マージ直後で親は通常 open）を使い、これは projects-integration.md §2.4.7.1 と一致する。差異は close.md Phase 4.5.1 が `--state all`（closing Issue の親が既に closed の可能性）を使う点のみ:
rationale: references/rationale.md#tasklist-parent-verify

```bash
# GitHub code search は `[`/`]` を無視する緩いマッチのため、複数候補を取得して検証する
candidates=$(gh issue list -R {owner_repo} --state open --search "in:body \"- [ ] #{issue_number}\" OR \"- [x] #{issue_number}\"" --json number --limit 10 --jq '.[].number')
parent_issue_number=""
for cand in $candidates; do
  # 自己マッチ除外: standalone closing Issue が自分自身を親と誤検出するのを防ぐ（AC-1）
  [ "$cand" = "{issue_number}" ] && continue
  # 妥当性検証: 候補 body に当該 tasklist 行が実在するか確認（緩いマッチで拾った無関係 Issue を排除、AC-2 を非回帰で通す）
  cand_body=$(gh issue view "$cand" -R {owner_repo} --json body --jq '.body')
  if grep -qE "^[[:space:]]*-[[:space:]]\[[ xX]\][[:space:]]*#{issue_number}([^0-9]|$)" <<< "$cand_body"; then
    parent_issue_number="$cand"
    break
  fi
done
# 検証済み親が見つかれば number/title/state を取得して保持
if [ -n "$parent_issue_number" ]; then
  gh issue view "$parent_issue_number" -R {owner_repo} --json number,title,state
fi
echo "tasklist_parent=${parent_issue_number:-none}"
```

両 method とも親を検出できなければ standalone として扱い、ステップ 10 の親処理をスキップする (non-blocking)。silent skip 禁止のため debug log を残す:

```bash
echo "[DEBUG] parent not detected for issue #{issue_number} — processing as standalone (methods tried: sub_issues_api, tasklist_search)"
```

---

## ステップ 3: 未完了タスクのチェック

関連 Issue が識別できなければステップ 4 へ進む。

Work Memory の採用元を **存在ではなく内容** で選ぶ。進捗セクション見出し（現行 `### 進捗サマリー` / v1 `### 進捗`）が実在するときだけローカル WM を採用し、stub 判定時はコメント側へ fallback して WARNING で可視化する:
rationale: references/rationale.md#wm-source-content

```bash
# ⚠ 下行はテスト hooks/tests/cleanup-wm-source-select.test.sh が awk 抽出アンカーとして参照する。変更時はテスト側の awk パターンも同時更新すること
# WM 採用元の選定（候補の存在ではなく内容を検査する）
# 進捗セクション: 現行 `### 進捗サマリー` と v1 `### 進捗` の両方を認める
# （incomplete 抽出が両見出しを拾う契約との整合）
_wm_local=".rite/work-memory/issue-{issue_number}.md"
[ -f "$_wm_local" ] || [ ! -f ".rite-work-memory/issue-{issue_number}.md" ] || _wm_local=".rite-work-memory/issue-{issue_number}.md"
_wm_source=""
_wm_body=""
if [ -f "$_wm_local" ]; then
  _wm_body=$(cat "$_wm_local" 2>/dev/null) || _wm_body=""
  # 行頭の AT1-3 + 進捗 / 進捗サマリー。stub は frontmatter や phase 行だけでこの見出しを持たない
  if printf '%s\n' "$_wm_body" | grep -qE '^#{1,3}[[:space:]]*進捗(サマリー)?([[:space:]]|$)'; then
    _wm_source=local
    echo "[CONTEXT] WM_SOURCE=local; path=$_wm_local"
  else
    echo "WARNING: ローカル WM ($_wm_local) は進捗セクションを持たない stub と判定。Issue コメント側へ fallback します (#2141)" >&2
    echo "[CONTEXT] WM_SOURCE=stub_fallback; path=$_wm_local"
    _wm_body=""
  fi
fi
if [ -z "$_wm_source" ] || [ "$_wm_source" = "stub_fallback" ]; then
  comment_body=$(gh api repos/{owner}/{repo}/issues/{issue_number}/comments \
    --jq '[.[] | select(.body | contains("📜 rite 作業メモリ"))] | last | .body // empty')
  if [ -n "$comment_body" ]; then
    _wm_source=comment
    _wm_body="$comment_body"
    echo "[CONTEXT] WM_SOURCE=comment"
  elif [ "$_wm_source" != "stub_fallback" ]; then
    _wm_source=none
    echo "[CONTEXT] WM_SOURCE=none"
  else
    # stub でコメントも無い → 検出対象なし（既存の「WM なし」縮退）
    _wm_source=none
    echo "[CONTEXT] WM_SOURCE=none; after=stub_fallback"
  fi
fi
# 未完了タスク抽出（親子 Tasklist `- [ ] #XX` は除外）
incomplete=""
if [ -n "$_wm_body" ]; then
  incomplete=$(printf '%s\n' "$_wm_body" | sed -n '/### 進捗/,/### /p' \
    | grep -E '^\s*- \[ \]' | grep -v -E '^\s*- \[ \] #[0-9]+' | head -10) || incomplete=""
fi
echo "incomplete_count=$(printf '%s\n' "$incomplete" | grep -c . 2>/dev/null || echo 0)"
```

| `WM_SOURCE` | 意味 |
|---|---|
| `local` | 進捗セクションを持つ実 WM を採用（AC-2） |
| `stub_fallback` → 後続で `comment` / `none` | stub を不採用しコメントへ fallback。切替理由は WARNING 済み（AC-1） |
| `comment` | ローカル WM 不在 or stub 後のコメントを採用 |
| `none` | ローカルもコメントも無い。既存の「WM なし」経路（AC-3） |

未完了タスクがあれば `AskUserQuestion` で「未完了タスクを Issue 化 (推奨) / 無視して続行 / キャンセル」を確認。Issue 化選択時は各タスクを `残作業` label 付きで作成する。

**Placeholder Legend** (cleanup.md ステップ 3 specific、bash skeleton で使用する placeholder の source):

| Placeholder | Source | 例 |
|-------------|--------|----|
| `{plugin_root}` | [Plugin Path Resolution](../../references/plugin-path-resolution.md) | `/home/user/.claude/plugins/rite` |
| `{pr_number}` | ステップ 1 で取得した PR 番号 | `1149` |
| `{pr_title}` | `gh pr view {pr_number} -R {owner_repo} --json title --jq '.title'` | `fix(workflow): ...` |
| `{issue_number}` | ステップ 2 で識別した関連 Issue 番号 | `1144` |
| `{task_title}` | work memory 進捗セクションの未完了タスク見出し | `step-5: references/ 整理` |
| `{task_text}` | 同上の本文 (チェックボックス行のテキスト) | `step-5: references/ 整理` |
| `{projects_enabled}` | `rite-config.yml` → `github.projects.enabled` (boolean) | `true` |
| `{project_number}` | `rite-config.yml` → `github.projects.project_number` | `6` |
| `{owner}` | `rite-config.yml` → `github.projects.owner` | `{owner}` |
| `{repo}` | ステップ 1.4 で取得した `$repo`（git-remote.sh 優先 + gh repo view fallback） | `{repo}` |

**Issue 本文テンプレート** (cleanup-specific、各タスクごとに以下の形式で生成):

```markdown
## 概要

{task_title}

## 背景・目的

PR #{pr_number} ({pr_title}) のマージ時点で未完了だったタスクを残作業として切り出す。元 PR の context を維持するため、根拠を以下に保持する。

## 関連

- 元 PR: #{pr_number}
- 元 Issue: #{issue_number}
- 元の進捗チェックボックス (work memory より): `- [ ] {task_text}`

## 変更内容

{task_text}

## チェックリスト

- [ ] {task_text}
```

**bash skeleton** (タスクごとに以下を反復実行、`{plugin_root}` / `{pr_number}` / `{pr_title}` / `{issue_number}` / `{task_title}` / `{task_text}` / `{projects_enabled}` / `{project_number}` / `{owner}` は Claude が事前 substitute):

```bash
# 0. `残作業` label を冪等に事前作成 (gh issue create --label X は X 未存在時に
# `could not add label: 'X' not found` で fail し Issue creation 自体が失敗するため必須)
gh label create 残作業 -R {owner_repo} --description "PR マージ後の残作業" --color "fbca04" 2>/dev/null || true

# 1. Issue 本文を tempfile に書き出し
# trap 設置順は ../../references/bash-trap-patterns.md#signal-specific-trap-template と統一。
# HEREDOC delimiter は single-quoted ('BODY_EOF') を必須化する:
#   - peer file convention (skills/issue-create/SKILL.md L157,287,348 / commands/pr/{create,review,fix}.md) に対称
#   - {task_text} / {pr_title} は work memory / PR title 由来 (外部入力) で `$VAR` / `$(cmd)` / backtick を含み得る
#   - unquoted delimiter は shell expansion と command injection リスクを生む
tmpfile=""
_rite_cleanup_step3_cleanup() {
  rm -f "${tmpfile:-}"
}
trap 'rc=$?; _rite_cleanup_step3_cleanup; exit $rc' EXIT
trap '_rite_cleanup_step3_cleanup; exit 130' INT
trap '_rite_cleanup_step3_cleanup; exit 143' TERM
trap '_rite_cleanup_step3_cleanup; exit 129' HUP

tmpfile=$(mktemp) || {
  echo "ERROR: ステップ 3 残作業 Issue body tempfile の mktemp に失敗" >&2
  exit 1  # fail-fast (peer file skills/issue-create/SKILL.md と対称、enclosing loop 非依存)
}
cat > "$tmpfile" <<'BODY_EOF'
{Issue 本文テンプレート (上記) を実値で展開}
BODY_EOF

# mktemp 0-byte ガード: cat 成功でも空ファイルなら create-issue script が
# 空 body Issue を作成する silent regression を防ぐ
if [ ! -s "$tmpfile" ]; then
  echo "ERROR: ステップ 3 Issue 本文の生成に失敗 (tmpfile が空)" >&2
  exit 1
fi

# 2. create-issue-with-projects.sh 呼び出し (result capture + rc check)
# iter_mode は "none" hardcode (peer file skills/issue-create/SKILL.md と対称、
# 残作業 Issue を特定 iteration に紐付ける要件なし — default Todo backlog で十分)
# args_json を入れ子 $() から分離して構築する (深い入れ子 quoting の malform 源を削減。
# 単一 JSON 引数契約は不変)
args_json=$(jq -n \
  --arg title "残作業: {task_title}" \
  --arg body_file "$tmpfile" \
  --argjson projects_enabled {projects_enabled} \
  --argjson project_number {project_number} \
  --arg owner "{owner}" \
  --arg priority "Medium" \
  --arg complexity "S" \
  --arg iter_mode "none" \
  '{
    issue: { title: $title, body_file: $body_file, labels: ["残作業"] },
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
  }') || {
  echo "ERROR: ステップ 3 args_json の jq 構築に失敗しました (タスク: {task_title})" >&2
  exit 1  # fail-fast (peer file skills/issue-create/SKILL.md と対称)
}
result=$(bash {plugin_root}/scripts/create-issue-with-projects.sh "$args_json")
if [ -z "$result" ]; then
  echo "ERROR: ステップ 3 create-issue-with-projects.sh が空 result を返しました (タスク: {task_title})" >&2
  echo "  対処: スクリプト stderr / GitHub API 認証 / Projects 設定を確認してください" >&2
  exit 1  # fail-fast (continue は enclosing loop なしで fall-through するため使用しない)
fi

# 3. 作成 Issue の番号 / URL / Projects 警告を表示
new_issue_number=$(printf '%s' "$result" | jq -r '.issue_number // empty')
new_issue_url=$(printf '%s' "$result" | jq -r '.issue_url // empty')
project_reg=$(printf '%s' "$result" | jq -r '.project_registration // empty')
printf '✅ 残作業 Issue 作成: #%s %s\n' "$new_issue_number" "$new_issue_url" >&2
printf '%s' "$result" | jq -r '.warnings[]?' 2>/dev/null | while read -r w; do
  echo "  ⚠️ $w" >&2
done
case "$project_reg" in
  partial|failed)
    echo "  ⚠️ Projects 登録: $project_reg (手動登録: gh project item-add {project_number} --owner {owner} --url $new_issue_url)" >&2
    ;;
esac
```

汎用的な argument structure・mapping 表は [Issue Creation with Projects Integration](../../references/issue-create-with-projects.md) を参照。`source: "cleanup"` 引数は本 caller の識別子として必須。`残作業` label は **step 0 で `gh label create 残作業` を冪等に事前作成する** ことが必須 (`gh issue create --label X` は X 未存在時に fail するため。`2>/dev/null || true` で既存ラベル時のエラーを無視)。
rationale: references/rationale.md#cleanup-source-label

---

## ステップ 4: セッション worktree の退出・削除 + base 更新

### 4-W セッション worktree の退出・削除（multi_session 有効 + worktree 内から呼ばれた場合）

まず multi_session の有効性と、現在 cwd がこの Issue のセッション worktree かどうかを判定する:

```bash
# multi_session の有効性判定・worktree 状態の分類・main checkout の絶対パス確保・dirty チェックは
# helper に委譲する。marker の意味と分岐は helper docstring が SoT。
# `{issue_number}` は他の helper 引数と同じく quote する。unquoted のまま値が複数トークンに割れると
# helper が unknown option で exit 2 し、marker を 1 本も出さない。
# helper の rc は捨てない。rationale: references/rationale.md#helper-rc-capture
_dt_rc=0
bash {plugin_root}/hooks/scripts/cleanup-session-worktree-teardown.sh detect --issue "{issue_number}" || _dt_rc=$?
if [ "$_dt_rc" -ne 0 ]; then
  echo "WARNING: worktree detect helper が rc=${_dt_rc} で失敗しました。作業ツリーの分類ができていません" >&2
  echo "  原因候補: {plugin_root} の未解決置換・helper 欠落 (rc=127) / helper 非可読 (rc=126) / 引数不正 (rc=2)" >&2
  echo "[CONTEXT] CLEANUP_WT=unknown; reason=detect_helper_failed; rc=${_dt_rc}" >&2
fi
```

**分岐の基準は「worktree 内か」ではなく「`ExitWorktree` で main checkout へ退出できるか」**（#2133）。`in_worktree` は EnterWorktree 管理下で退出でき、`in_worktree_unrecorded` は path 入場で `ExitWorktree` が no-op になる — 後者では main checkout 操作が harness の worktree 隔離ガードに拒否されるため、実行せず委譲する。

> **ガードが拒否する形（実測）**: harness が拒否するのは **Bash ツール呼び出しのコマンド文字列に直接 `cd {main_root}` / `git -C {main_root}` を書く形**（および worktree 外を向くか検証不能な複合ブロック）であり、helper スクリプト内部の `cd` は拒否されない。
rationale: references/rationale.md#exitworktree-delegation

- `CLEANUP_WT=in_worktree_unrecorded`（EnterWorktree 非経由の path 入場 = ユーザーがセッションを worktree ディレクトリで開いた場合。`ExitWorktree` が no-op で main checkout へ戻れない）: **下記の手順 1〜4 を実行しない**（`CLEANUP_DELEGATED=1`）。main checkout 操作を要する 4 項目（base 更新 = ステップ 4 / worktree 削除 = 本 4-W / ブランチ削除 = ステップ 5 / wiki ingest = ステップ 9）は**試行せず**、ステップ 12 が未完了として列挙し委譲する。worktree 内で完結する項目（PR-specific state 削除・Projects Status 更新・Issue クローズ・作業メモリ更新・flow state リセット）は通常どおり実行する。ガードを迂回する複合コマンド（main checkout への `cd` / `git -C` リダイレクト）は**試みない** — ガードは正当に機能しており、迂回は設計違反。
  **委譲先は main checkout での `/rite:cleanup {pr_number}` 再実行**（1 系統）。再実行セッションでは flow-state に worktree 記録が無いため 4-W は `CLEANUP_WT=none` を返し、`CLEANUP_DELEGATED` を emit せずステップ 4 / 5 / 9 が通常実行される。base 更新・wiki ingest・リモートブランチ削除はそこで直接完了し、worktree 削除とローカルブランチ削除は**ステップ 5 が `branch` エントリを reap manifest に記録する**ことで次回セッション開始時の自動回収を arm する（`{pr_merged}=true`、manifest への記録を verify 済み、かつ対象 worktree が reaper と同じ filtered dirty gate を通過したときだけ `recovery=auto` になる。未マージ PR の強制 cleanup・記録漏れ・dirty または判定不能な worktree は `recovery=manual` に倒れ手動回復が必要 — 出し分けはステップ 12 の `{local_branch_check}` 判定に規定済み。既存配線で、本ステップから追加の記録は行わない）。
- `CLEANUP_WT=in_worktree`（EnterWorktree 管理下 = `/rite:batch-run` 経由の通常経路。`ExitWorktree` で退出できる）:
  1. `dirty=yes` なら **AskUserQuestion**（「`git stash push` して続行 / 中止」）。説明文は上記 `--- dirty files begin/end ---` デリミタ内に出力された生パス一覧を**引用**する（要約・創作しない）。stash は common git dir に格納されるため worktree 削除後も `git stash pop` 可能（完了報告の stash 案内は従来文面を流用）。
  2. `ExitWorktree` ツールを `action: "keep"` で呼び出し、main checkout に復帰する（path 入場した worktree は remove でも消えない仕様のため**常に keep**）。
  3. main から worktree を削除する。**削除は helper に委譲する** — helper が self-exclusion 付き live-cwd guard（**別の**セッションの harness cwd がまだこの worktree に立っている場合、削除するとそのセッションの `/clear` が `Path does not exist` で失敗するため、削除せず遅延回収へ委譲する。cleanup を実行している**自セッション自身**は `--self-root` で除外する）と sandbox マスク検知（マスク下の `git worktree remove` は admin dir を半壊させるため試行しない）を順に通し、通過したときだけ remove → prune を実行する:
     ```bash
     # 判定と削除（self-exclusion 付き live-cwd guard → sandbox マスク検知 → remove →
     # --force fallback → prune → reap manifest 記録）はすべて helper が持つ。契約と marker の
     # 意味は helper docstring が SoT。
     # `--self-root` には**この Bash 呼び出しの `$PPID`**（= claude ハーネス）を渡す。helper 内で
     # `$PPID` を取ると helper を起動したシェルを指し、self-exclusion が意味を失う。
     # helper の rc は捨てない。rationale: references/rationale.md#helper-rc-capture
     _wt_rc=0
     bash {plugin_root}/hooks/scripts/cleanup-session-worktree-teardown.sh remove \
       --worktree "{flow_wt}" --pr-merged "{pr_merged}" --self-root "$PPID" || _wt_rc=$?
     if [ "$_wt_rc" -ne 0 ]; then
       echo "WARNING: worktree teardown helper が rc=${_wt_rc} で失敗しました。作業ツリーは未処理のまま残り、reap manifest も arm されていないため自動回収は claim の stale 化と age guard を待ちます" >&2
       echo "  原因候補: {plugin_root} の未解決置換・helper 欠落 (rc=127) / helper 非可読 (rc=126) / 引数不正 (rc=2)" >&2
       echo "[CONTEXT] WORKTREE_REMOVE_FAILED=1; path={flow_wt}; rc=${_wt_rc}" >&2
     fi
     ```
     > 通常の `in_worktree` 経路ではステップ 2 の `ExitWorktree(keep)` で自セッションの harness cwd が main に退避済みのため、`worktree-foreign-cwd.sh` は rc=1（削除）を返す。`ExitWorktree(keep)` が no-op / 失敗でも、残る live cwd は自セッションだけなので self-exclusion により rc=1。rc=0（遅延）は別セッションのハーネスがこの worktree 内に cwd を持つ場合のみ。`/proc` の無い環境では rc=2 となり従来どおり削除を実行する（後方互換）。
rationale: references/rationale.md#live-cwd-self-exclusion
  4. 削除失敗（`WORKTREE_REMOVE_FAILED`）、live-cwd skip（`WORKTREE_REMOVE_SKIPPED_LIVE_CWD`）、または sandbox マスク skip（`WORKTREE_REMOVE_SKIPPED_SANDBOX_MASK` — remove 試行自体が admin dir を半壊させるため試行せず委譲）は **WARNING を表示して続行**（non-blocking。`pr-cycle-cleanup.sh` の遅延 reap へ委譲。ステップ 12 報告に失敗/skip と手動コマンドを表示）。busy 失敗時は上記の sandbox 干渉 WARNING も追加表示される（AC-5）。`WORKTREE_REMOVE_FAILED` / `WORKTREE_REMOVE_SKIPPED_SANDBOX_MASK` は `{pr_merged}=true` のときのみ reap manifest（`.rite/tmp-artifacts.tsv`）へ `session_worktree` type でパスを記録する（`worktree` type ではない）。corpse 化した場合、パス記録で `pr-cycle-cleanup.sh` Step 5 の corpse age guard（24h 待ち）をバイパスさせ、mount 解放後の次回セッションで即座に回収できるようにする。
rationale: references/rationale.md#session-worktree-reap
- `CLEANUP_WT=in_main`（resume 等で既に main 復帰済み）: 上記 1〜2 をスキップ。worktree が残っていれば 3 を実行（既削除なら 3 もスキップ = 冪等）。in_main では所有セッションが別セッションの可能性があるため、3 の self-exclusion 付き live-cwd guard が特に重要（live-cwd guard による遅延は別セッション在席時。これに加え sandbox マスク検知時（sandbox マスク）も削除を試行せず遅延する）。
- `CLEANUP_WT=none`（multi_session 無効、または worktree 関連なし = 物理 cwd も当該 Issue の worktree でない）: 4-W 全体を no-op でスキップ。**注**: flow-state 未記録でも物理 cwd が当該 Issue の worktree なら `in_worktree_unrecorded` に分類されここには落ちない（#1622）。**ただし関連 Issue が未識別（`{issue_number}` 空）のときは物理 cwd 導出が働かず `none` に落ちる** — 導出が issue 番号でパス末尾を照合するため。この場合の worktree は次回セッション開始時の遅延 reap に委ねられる。
- `CLEANUP_WT=unknown`（detect helper が起動できず分類を返せなかった）: 分類不能なので**上記の手順 1〜4 を実行しない**。`{main_root}` も `{flow_wt}` も未確定で、worktree 内にいるか判定できない以上 `in_worktree_unrecorded` と同じ扱いにする — main checkout 操作を要する 4 項目（base 更新 = ステップ 4 / worktree 削除 = 本 4-W / ブランチ削除 = ステップ 5 / wiki ingest = ステップ 9）を**試行せず**、ステップ 12 が未確認として列挙する。worktree 内で完結する項目（PR-specific state 削除・Projects Status 更新・Issue クローズ・作業メモリ更新・flow state リセット）は通常どおり実行する。`CLEANUP_DELEGATED=1` は emit しない — 委譲モードの定型案内は「main checkout で再実行すれば冪等に完了する」を前提にするが、helper が起動できない原因（`{plugin_root}` の未解決置換・helper 欠落）は再実行では解消しないため。

> **復旧: `/clear` が `Path does not exist` で失敗する場合**
> セッション worktree（`.rite/worktrees/issue-{N}`）が遅延 reap または手動削除で消えた後、所有セッションをハーネスが resume すると cwd 復元先が無く `/clear` が `Error: Path "...worktrees/issue-{N}" does not exist` で失敗することがある。ハーネスの cwd レコード自体は rite から intercept できないため、万一発生した場合は次のいずれかで復旧する:
> 1. リポジトリ root（main checkout）で**新しいセッションを開始**する（cwd が有効になり `/clear` が機能する）。
> 2. 作業を続けるなら、有効なディレクトリで `/rite:recover {issue_number}` を実行する（worktree が消えていれば再構築経路に入る）。
> 3. 残骸が残っていれば `git worktree prune` で参照を整理する。
> session-start hook は 2 経路（相互排他、いずれも非blocking）: (a) cwd 自体が消えた session worktree を指す場合は上記ガイドを stderr に表示して `exit 0` する、(b) cwd は有効だが記録された worktree 参照だけが消えた場合は flow-state の dangling 参照を自動クリアする。

### 4 base ブランチの更新（安全化）

> **委譲モード（#2133）**: 4-W が `[CONTEXT] CLEANUP_DELEGATED=1` **または `[CONTEXT] CLEANUP_WT=unknown`** を emit している場合、本ステップの bash を**実行しない**（本ステップは main checkout への `cd` を Bash 呼び出しに直書きする形のため harness の worktree 隔離ガードが拒否する。`unknown` では worktree 内にいるか判定できず、`{main_root}` も未確定）。ステップ 12 が未完了として列挙し、`CLEANUP_DELEGATED=1` なら main checkout での `/rite:cleanup {pr_number}` 再実行へ委譲する（本項目は再実行で冪等に完了する）。`unknown` の案内はステップ 12 の `{session_worktree_check}` が出す。

main checkout の不可侵規約（[git-worktree-patterns.md](../../references/git-worktree-patterns.md#main-checkout-不可侵-inviolability-convention)）に従い、**main checkout が `{base_branch}` 上にある場合のみ** base を更新する。別 branch 上では切り替えず WARNING + skip する:

main_root への cd は worktree 自己削除後の cwd 破損対策。`{main_root}` は 4-W の `[CONTEXT] ... main_root=` marker の値。cd はこの Bash 呼び出しの永続シェル cwd を変更するため、ステップ 5 以降も同じ main_root 上で実行される（順序契約 4-W→5 自体は変更しない）:
rationale: references/rationale.md#main-root-cd

```bash
main_root="{main_root}"
if [ -z "$main_root" ] || ! cd "$main_root" 2>/dev/null; then
  echo "WARNING: main checkout ルート（${main_root:-<未解決>}）が解決できないか、そこへ cd できませんでした。base 更新を skip します。" >&2
  echo "[CONTEXT] BASE_UPDATE=main_root_unresolved"
else
cur_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || cur_branch=""
if [ "$cur_branch" = "{base_branch}" ]; then
  # index.lock 競合 3 回リトライ
  n=0; until git fetch origin {base_branch} 2>/dev/null && git merge --ff-only origin/{base_branch} 2>/dev/null; do n=$((n+1)); [ "$n" -ge 3 ] && { echo "WARNING: base 更新 (git fetch + git merge --ff-only origin/{base_branch}) が失敗しました (index.lock 競合 / fast-forward 不可 / コンフリクトの可能性)。git status で確認してください。" >&2; break; }; sleep 1; done
  # retry break 後の成否検証（失敗を silent にしないため）: 失敗を silent に放置せず復旧分岐へ routing する。
  # rev-parse の exit code と非空性を明示チェックする — cwd 破損下では両辺が揃って空文字列を返し
  # 得るため、文字列の等値比較だけでは偽陽性 ok を防げない。main_root への cd 済みなのでこの
  # 経路では通常発生しないが、cd 後に main checkout 自体が壊れる等の想定外ケースへの防御線として残す。
  _head_rev=$(git rev-parse HEAD 2>/dev/null); _head_rc=$?
  _base_rev=$(git rev-parse "origin/{base_branch}" 2>/dev/null); _base_rc=$?
  if [ "$_head_rc" -eq 0 ] && [ "$_base_rc" -eq 0 ] && [ -n "$_head_rev" ] && [ "$_head_rev" = "$_base_rev" ]; then
    echo "[CONTEXT] BASE_UPDATE=ok"
  else
    _bu_dirty=$(bash {plugin_root}/hooks/scripts/lib/git-status-filtered.sh) || _bu_dirty="?? (dirty-check failed — assume dirty for safety)"
    if [ -z "$_bu_dirty" ]; then
      echo "[CONTEXT] BASE_UPDATE=ff_failed_clean"
    elif printf '%s\n' "$_bu_dirty" | grep -q '^[^ ]'; then
      # X 列 (index status、行頭 1 文字) が非空白 = staged 変更または untracked (??) を含む dirty。
      # いずれも diff 同一性を機械判定できない — 下記比較は working tree しか見ないため、untracked
      # は比較対象外、staged 内容は未検証のまま「diff 同一」を主張することになる。
      # 安全側の divergent へ倒す (stash 案内は -u で untracked も対象に含む)。
      # unstaged のみの変更 (X 列が空白: " M" / " D") だけが下の比較へ進む
      echo "[CONTEXT] BASE_UPDATE=ff_failed_divergent"
    else
      # unstaged の tracked 変更のみ: 比較を dirty パスに限定する。tree 全体比較 (pathspec なし)
      # はマージが追加/削除した無関係ファイルまで D として数え、diff 同一の残存変更を divergent に
      # 誤流出させる。pathspec は root 相対で出力されるため消費側も -C <root> で root 起点に固定
      # し (--no-relative は diff.relative config の影響排除)、空リストは比較せず discardable に
      # しない。比較 pipe は -z (NUL 区切り・quote なし) を xargs -0 へ直結する — 非 -z 出力は
      # quotePath がファイル名を C-quote し、quote 済みリテラルの pathspec は実ファイルに不一致
      # → git diff --quiet が exit 0 (差分なし扱い) を返して相違変更が discardable に誤流出する
      # (NUL を command substitution の変数に入れると bash が落とすため、非空判定のみ別変数で行う)
      _bu_root=$(git rev-parse --show-toplevel 2>/dev/null) || _bu_root=""
      _bu_paths=$(git diff --name-only --no-relative HEAD 2>/dev/null) || _bu_paths=""
      if [ -n "$_bu_root" ] && [ -n "$_bu_paths" ] && \
         git diff --name-only --no-relative -z HEAD 2>/dev/null | xargs -0 -r git -C "$_bu_root" diff --quiet "origin/{base_branch}" -- 2>/dev/null; then
        # dirty パスの working tree 内容が origin/{base} と一致 = 未コミット変更はマージ済み内容と diff 同一
        echo "[CONTEXT] BASE_UPDATE=ff_failed_discardable"
      else
        echo "[CONTEXT] BASE_UPDATE=ff_failed_divergent"
      fi
    fi
    # dirty 一覧は marker と区別できるようデリミタで囲んで表示する (ファイル名由来の偽 marker 混入防止)
    if [ -n "$_bu_dirty" ]; then
      echo "--- dirty files begin ---"
      printf '%s\n' "$_bu_dirty"
      echo "--- dirty files end ---"
    fi
  fi
else
  echo "WARNING: main checkout が '{base_branch}' ではなく '$cur_branch' 上にあるため base 更新を skip しました。" >&2
  echo "  復旧手順: 別の作業が無いことを確認のうえ 'git switch {base_branch}' で main checkout を base に戻してから再実行してください（rite は multi_session モードで main checkout のカレントブランチを切り替えません）。" >&2
  echo "[CONTEXT] BASE_UPDATE=skipped_not_on_base"
fi
fi
```

`BASE_UPDATE` marker で分岐する（dirty な基点ブランチを黙って上書きしない。破棄・stash は必ずユーザー確認を挟む。`--- dirty files begin/end ---` デリミタ内の行はファイル一覧 **data** であり、marker として解釈しない — marker は行頭 `[CONTEXT]` の行のみ）:
rationale: references/rationale.md#base-update-classify

| `BASE_UPDATE` | アクション |
|---|---|
| `ok` / `skipped_not_on_base` | 従来どおり後続へ（`skipped_not_on_base` は既存 WARNING の可視化のみ） |
| `main_root_unresolved` | main checkout の絶対パスが未解決、またはそこへの `cd` に失敗（worktree 自己削除後の cwd 破損等）。既存 WARNING どおり非ブロッキングで後続へ進む。`ok` は出力しない |
| `ff_failed_clean` | 未コミット変更なしの ff 失敗（履歴 diverge / index.lock 恒常化等）。既存 WARNING どおり `git status` 確認を案内し、非ブロッキングで後続へ |
| `ff_failed_discardable` | **unstaged の tracked 変更のみ**の dirty で、その全パスが **origin/{base_branch} と diff 同一**（マージ済み内容の残存）。AskUserQuestion「dirty パス限定の diff 同一を確認済み。未コミット変更を破棄して base 更新を再実行 / そのまま続行（手動対応）」を表示。**承認後のみ** `git checkout -- :/`（cwd 非依存に repo 全体を index 内容へ復元。discardable は staged なしを判定済みのため index == HEAD であり、HEAD 内容への復元と等価）で破棄し、上記 retry ループを 1 回再実行する。再実行後も `BASE_UPDATE=ok` にならない場合は `ff_failed_divergent` と同等に stash 案内で terminate する（2 回目の破棄承認は求めない） |
| `ff_failed_divergent` | 未コミット変更がマージ済み内容と**異なる**か、diff 同一性を機械判定できない dirty（untracked は git diff が比較できず、staged 変更は working tree 比較で内容を検証できないため、いずれもここに倒す）。stash 案内を表示して terminate（データ喪失なし）: `git stash push -u -m "rite-cleanup: manual-stash before base update (issue-{issue_number})"` を提示し、ユーザー実行後の `/rite:recover` 再開を案内する。自動 stash はしない |

> **multi_session 無効（従来モード）の場合**: 従来どおり `git checkout {base_branch} && git fetch origin {base_branch} && git merge --ff-only origin/{base_branch}` を実行する（base branch 以外にいて未コミット変更があれば「stash して続行 / キャンセル」を確認。stash は `git stash push -m "rite-cleanup: auto-stash before cleanup"`）。fast-forward 不可 / コンフリクト時は `git status` で確認・解決後の再実行を案内し terminate。

---

## ステップ 5: ローカル / リモートブランチを削除

> **順序**: branch 削除は **worktree 削除後にのみ成功する**（Git 制約: worktree で checkout 中の branch は削除不可）。multi_session 時は必ずステップ 4-W → 本ステップの順で実行する。
>
> **委譲モード（#2133）**: 4-W が `[CONTEXT] CLEANUP_DELEGATED=1` **または `[CONTEXT] CLEANUP_WT=unknown`** を emit している場合、本ステップの bash ブロックを**いずれも実行しない**（worktree を削除していないため checkout 中の branch は構造的に削除できない。`unknown` では worktree の有無すら判定できていないため同様に試行しない。リモート削除は本ステップ内でローカル削除と 1 ステップで扱うため同時に委譲する — `git push origin --delete` 自体はガードに抵触せず worktree 内からも実行できる）。ステップ 12 が未完了として列挙し、main checkout での `/rite:cleanup {pr_number}` 再実行へ委譲する。再実行では本ステップが通常実行され、リモート削除は直接完了し、ローカル削除は `used by worktree` で見送られた上で `branch` エントリを reap manifest に記録して次回セッション開始時の自動回収を arm する（`{pr_merged}=true`、共有 manifest のエントリを verify 済み、かつ対象 worktree が reaper と同じ filtered dirty gate を通過したときだけ `recovery=auto` になる。未マージ PR の強制 cleanup・記録漏れ・dirty または判定不能な worktree は `recovery=manual` に倒れ手動回復が必要 — 出し分けは本ステップの `recovery=` 判定が持つ）。

```bash
# ローカル / リモートの存在確認・削除・遅延判定と marker の emit はすべて helper が持つ
# （契約・marker 名・出力ストリーム・reason 語彙は helper docstring が SoT）。
# `{branch_identity_verified}` はステップ 1.3 の headRefName 完全一致の結果、`{pr_merged}` は
# 同ステップの PR 状態（`mergedAt` 非 null なら `true`、それ以外すべて `false`）を Claude が
# literal substitute する。どちらも bash からは導出できないため helper は既定値を持たず、
# 未指定なら usage error で落ちる（検証していないのに削除する経路を作らないため）。
bash {plugin_root}/hooks/scripts/cleanup-branch-delete.sh \
  --branch "{branch_name}" --pr-merged "{pr_merged}" \
  --branch-identity-verified "{branch_identity_verified}"
```

`BRANCH_DELETED=1; via=squash-merged`（PR が merged 済みで `git branch -d` が squash 残渣により拒否したケース）は通常削除と同様にステップ 12 で `x` に分岐する。`BRANCH_DELETE_UNMERGED=1`（未マージ PR の強制 cleanup で `{pr_merged}=false` のとき）は「強制削除 (`-D`) / スキップ」を確認する。**強制削除を選んだ場合**は `LC_ALL=C git branch -D {branch_name} && echo "[CONTEXT] BRANCH_DELETED=1; branch={branch_name}; via=force"` を実行し、削除完了を marker で示す（ステップ 12 が `x` に分岐する）。スキップ時は marker を追加しない（残置のまま）。`BRANCH_DELETE_DEFERRED=1`（作業ツリーが未削除のまま残り削除を遅延したケース — 別セッション使用中別セッション使用中 または sandbox マスク skipsandbox マスク。原因は断定しない）のときは**強制削除しない**。marker の `recovery=` で次セッション回収の可否が決まる: `recovery=auto`（{pr_merged}=true、reap manifest の記録を verify 済み、かつ対象 worktree が reaper と同じ filtered dirty gate を通過）は worktree 解放後に `pr-cycle-cleanup.sh` Step 5 が自動回収する。`recovery=manual`（未マージ PR の強制 cleanup、記録漏れ、dirty または判定不能な worktree）は自動回収されない。実パスを解決できた場合は `BRANCH_DELETE_DEFERRED_WORKTREE` marker の shell-escaped `path_q=` を用いて status を確認し、変更を commit / stash / copy して clean にした後だけ、非 force の `git worktree remove` → prune → branch delete を実行する。解決不能時は `git worktree list --porcelain` で先に実パスを特定する。ステップ 12 はこの `recovery=` 値で残置メッセージを出し分ける。

リモート削除は **ブランチ名の事前検証 → 一時ファイル確保 → `git ls-remote --exit-code`（rc=128 なら 1 回リトライ、#2140）+ ref 名の完全一致検証** の順に進み、**どの経路も必ず marker を emit する**（marker 名は 4 種、emit 箇所は 8 — うち fail-fast 4 経路（空値 / marker デリミタ / refname 非合法 / 一時ファイル確保失敗）は `ls-remote` を実行しない。#2016）: 事前検証（空値 / marker デリミタ文字 / refname 非合法）に落ちた場合、一時ファイルを確保できなかった場合、ref 名の完全一致検証が異常終了した場合はいずれも削除を試行せず `REMOTE_BRANCH_CHECK_FAILED=1`（原因は marker の `rc=` と `reason=` で区別する）。`rc=0`（存在確認済み）は削除し、成功なら `REMOTE_BRANCH_DELETED=1`、失敗（protected branch / 権限不足 / race）なら `REMOTE_BRANCH_DELETE_FAILED=1` を emit する。`rc=2` は不在なので削除せず `REMOTE_BRANCH_ALREADY_ABSENT=1`、それ以外の非 0（リトライ後も 128 を含む）は存在有無が判定できないため削除を試行せず `REMOTE_BRANCH_CHECK_FAILED=1` を emit する。成功側も marker を出す。リポジトリ設定 `delete_branch_on_merge: true` の環境では merge 時にサーバサイドで head ブランチが削除されるため通常は `rc=2` に落ち、`/rite:merge` の `--delete-branch=false` はこれを抑止しない（`skills/merge/SKILL.md` の設計判断を参照）。`delete_branch_on_merge: false` のリポジトリでは従来どおり `rc=0` 経路で削除される。
rationale: references/rationale.md#remote-delete-markers

---

## ステップ 6: PR-specific state ファイルを削除 <!-- AC-7 -->

マージ済み PR に紐づく state ファイルを削除する。**他 PR 誤削除防止のため glob は `{pr_number}-` prefix 固定**。

> **Acceptance Criteria anchor (AC-7)**: [review-result-schema.md](../../references/review-result-schema.md#クリーンアップ) と双方向リンク。

### 6.0 残存非実測指摘から follow-up Issue を起票

archive より前に実行する（JSON が元の場所にあるうちに読む）。0 件は起票しない。同定不能は起票せず WARNING。cleanup は止めない。
rationale: references/rationale.md#follow-up-before-archive

#### 6.0.V helper 呼び出し前の再検証（マージ後 HEAD）

`non_blocking_findings[]` は**指摘が出た cycle** の観測であり、その後の fix cycle で解消されても JSON は更新されない。無条件に転記すると**マージ時点で既に存在しない drift** の follow-up Issue が起票される。helper（bash）は「この指摘は既に解消済みか」という散文の意味判定を持てないため、再検証は本ステップ（LLM 層）で行う。

対象 JSON は helper と同一の選び方（`{state_root}/.rite/review-results/{pr_number}-*.json*` のうち basename 辞書順最大）で 1 本に確定する:

```bash
# reason は helper の語彙（no_json / jq_missing）に揃え、state root 解決失敗は別値にする。
# 合成すると「JSON も jq も実在するのに no_json_or_jq」という誤った原因が完了報告へ転記される。
_state_root=$(bash {plugin_root}/hooks/state-path-resolve.sh 2>/dev/null) || _state_root=""
if [ -z "$_state_root" ]; then
  # cwd へ倒しても再検証には使わない（使わない値を計算しない）。全件転記へ倒して即座に抜ける。
  echo "WARNING: state-path-resolve.sh の解決に失敗。follow-up 再検証は行わず全件を転記対象とします" >&2
  echo "[CONTEXT] FOLLOW_UP_REVERIFY=unavailable; reason=state_root_unresolved"
elif ! command -v jq >/dev/null 2>&1; then
  echo "[CONTEXT] FOLLOW_UP_REVERIFY=unavailable; reason=jq_missing"
else
  _rv_src=""; _rv_base=""
  for f in "$_state_root/.rite/review-results/{pr_number}"-*.json*; do
    { [ -e "$f" ] || [ -L "$f" ]; } || continue
    b="${f##*/}"
    if [ -z "$_rv_base" ] || [ "$b" \> "$_rv_base" ]; then _rv_src="$f"; _rv_base="$b"; fi
  done
  if [ -z "$_rv_src" ]; then
    echo "[CONTEXT] FOLLOW_UP_REVERIFY=unavailable; reason=no_json"
  else
    # 1 finding = 1 行の JSON で出す。TSV だと description / suggestion の改行で行が割れ、
    # 後続行が id を失って id と本文の対応が崩れる（誤対応が resolved 側に振れると指摘の無言 drop）。
    # `.id` は**落とさず null へ写す**。save 側は non_blocking_findings[] 側の id 書式違反を
    # 非ブロッキングで通すため書式外 id が永続化されうる。その値をそのまま提示すると、下段の
    # `{resolved_ids_csv}` がリテラル置換される二重引用符内でコマンド置換として展開される。
    # null 化なら書式外の値が LLM へ届かず、finding 自体は出力に残るので黙って消えない
    # （落とすと件数を数える第 2 の述語が要り、その述語が本体と乖離する drift 経路になる）。
    _rv_errf=$(mktemp "${TMPDIR:-/tmp}/rite-fu-reverify-err-XXXXXX") || {
      echo "WARNING: 一時ファイルを確保できません。jq の stderr 本文は出力されません" >&2
      _rv_errf=""
    }
    if _rv_out=$(jq -c '.non_blocking_findings[]?
      | {id: (if ((.id // "") | test("^F-[0-9]{2,}$")) then .id else null end),
         file, line, description, suggestion}' "$_rv_src" 2>"${_rv_errf:-/dev/null}"); then
      # 0 件のとき printf は空行を 1 行出す。空行が finding として読まれないよう非空時だけ出力する。
      # 成功時は marker を出さない（判定後の `done` が唯一の成功 marker）
      # rationale: references/rationale.md#reverify-no-extract-marker
      if [ -n "$_rv_out" ]; then printf '%s\n' "$_rv_out"; fi
    else
      echo "WARNING: 再検証用 JSON を解析できません: $_rv_src" >&2
      if [ -n "$_rv_errf" ] && [ -s "$_rv_errf" ]; then head -5 "$_rv_errf" | sed 's/^/  /' >&2; fi
      echo "[CONTEXT] FOLLOW_UP_REVERIFY=unavailable; reason=parse_failed"
    fi
    # 末尾を `&&` 単独文にすると mktemp 失敗時にブロック全体が rc=1 で終わり、抽出が成功していても
    # 呼び出し側がステップ失敗と読む
    if [ -n "$_rv_errf" ]; then rm -f "$_rv_errf"; fi
  fi
fi
```

出力の各 finding について、**マージ後 HEAD の実態**を Read / Grep で確認し 3 値で判定する:

| 判定 | 条件 | 帰結 |
|---|---|---|
| `resolved` | 指摘された drift が HEAD に**現存しないことを確認できた**。機械的に確認できる手がかりを優先する: `file:line` 周辺を Read して指摘された記述・コードが既に修正後の形になっている / `suggestion` の提案文言が既にファイルに存在する / 指摘対象の行そのものが削除されている | `--exclude-ids` へ渡す（転記しない） |
| `remains` | 指摘された drift が HEAD に現存する | 転記する |
| `undecidable` | 断定できない。`file:line` が移動した / 指摘が散文の意図に関わる / 判定材料が足りない / ファイル自体が読めない | **転記する**（`--exclude-ids` へ渡さない）。false negative を避ける安全側 |

`FOLLOW_UP_REVERIFY=unavailable` を観測した場合、および本節を実行できなかった場合は**全件を `undecidable` 扱い**とし、`--exclude-ids` は空文字列のまま helper を呼ぶ（= 除外なし＝従来挙動）。

`"id": null` の finding（書式外 id / id 欠落）は**必ず `undecidable`** とする。除外指定に載せられる id が無く、`{resolved_ids_csv}` へ入れられる値も無いため、判定の余地なく転記側へ倒れる。出力には現れるので `{n_undecidable}` には通常どおり数え上げられる。

判定を終えたら、`resolved` の id を CSV（`"F-01,F-05"`）に組み、内訳 marker を出す。**抽出が成功した経路では、抽出結果が 0 件でもこの marker を必ず出す**（`resolved=0; remains=0; undecidable=0; resolved_ids=`）— 出さないと成功 marker が 1 本も残らず、ステップ 12 が「marker が無いとき」の分岐に落ちる。**既に `unavailable` を出した経路では `done` を出さない**（出すと最後の出現が `done` になり `reason=` が完了報告から消える）:

```bash
# `{resolved_ids_csv}` / `{n_*}` は上記判定の結果をリテラル置換する（resolved が 0 件なら空文字列）。
# `{resolved_ids_csv}` に置けるのは `F-NN` トークンをカンマ連結したものだけ。
echo "[CONTEXT] FOLLOW_UP_REVERIFY=done; resolved={n_resolved}; remains={n_remains}; undecidable={n_undecidable}; resolved_ids={resolved_ids_csv}"
```

内訳はステップ 12 の完了報告に含める。

> **下段の helper 呼び出しは別 Bash 呼び出しである**。Bash tool 呼び出し間でシェル変数は保持されないため、`{resolved_ids_csv}` を実値へ**リテラル置換**してから実行する（`$_fu_exclude_ids` のようなシェル変数経由で渡さない。同型の規約: [recover Phase 5.2 (flow-state の active=true 復元)](../recover/SKILL.md)）。判定結果を運ぶ経路はリテラル置換のみで、marker の `resolved_ids=` は監査用の記録であって受け渡し経路ではない。

```bash
_state_root=$(bash {plugin_root}/hooks/state-path-resolve.sh 2>/dev/null) || _state_root=""
[ -n "$_state_root" ] || { echo "WARNING: state-path-resolve.sh の解決に失敗。cwd をフォールバック使用します" >&2; _state_root="$(pwd)"; }
_fu_rc=0
# --owner/--repo は repo identity ({owner_repo} の slash split)。--project-owner だけ Projects owner ({owner})。
IFS=/ read -r _gh_owner _gh_repo <<< "{owner_repo}"
bash {plugin_root}/hooks/scripts/cleanup-follow-up-issue.sh \
  --state-root "$_state_root" \
  --pr "{pr_number}" \
  --source-issue "{issue_number}" \
  --owner "${_gh_owner}" \
  --repo "${_gh_repo}" \
  --project-number "{project_number}" \
  --project-owner "{owner}" \
  --projects-enabled "{projects_enabled}" \
  --exclude-ids "{resolved_ids_csv}" || _fu_rc=$?
if [ "$_fu_rc" -ne 0 ]; then
  echo "WARNING: follow-up Issue 起票 helper が rc=${_fu_rc} で失敗しました。cleanup は続行します" >&2
  echo "  手動起票: 当該 PR の review-results JSON の non_blocking_findings[] を元に follow-up ラベル付き Issue を作成してください" >&2
  echo "[CONTEXT] FOLLOW_UP_ISSUE=failed; reason=helper_rc; pr={pr_number}; rc=${_fu_rc}" >&2
fi
```

```bash
# 削除対象はリポジトリ共通の state ルート基準（state-path-resolve.sh）。書込側
# （review-result-save.sh / fix.md 2.1.A / fix.md 3.3.1）と同一解決のため、セッション worktree に
# 書かれて main checkout の削除が no-op になる不整合を防ぐ（解決失敗時は cwd fallback）。
# 他 PR 誤削除防止の `{pr_number}-` prefix 固定 glob、review-results の退避/削除委譲、
# rite_rm 6 種、marker の emit はすべて helper が持つ（契約は helper docstring が SoT）。
#
# helper の rc は捨てない。rationale: references/rationale.md#helper-rc-capture
_sp_rc=0
bash {plugin_root}/hooks/scripts/cleanup-pr-state-purge.sh --pr "{pr_number}" || _sp_rc=$?
if [ "$_sp_rc" -ne 0 ]; then
  echo "WARNING: state purge helper が rc=${_sp_rc} で失敗しました。PR-specific state ファイルは未処理のまま残っています" >&2
  echo "  原因候補: {plugin_root} の未解決置換・helper 欠落 (rc=127) / helper 非可読 (rc=126) / 引数不正 (rc=2)" >&2
  echo "[CONTEXT] REVIEW_CLEANUP_PARTIAL_FAILURE=1; reason=state_purge_helper_failed; pr={pr_number}; rc=${_sp_rc}" >&2
fi
```

`review-run-since-{pr}.txt` は `/rite:iterate` の収束トレンド判定が現 run の境界に使う pin。直上で削除する `review-results/` と同じライフサイクルのため同列挙で掃除する。
rationale: references/rationale.md#review-run-since-sweep

`nb-sweep-done-{pr}.txt` は iterate 5.S の再入ガード。cleanup まで残すと再 `/rite:iterate` が skip し、未消化 0 の再保証が死ぬ。
rationale: references/rationale.md#nb-sweep-done-sweep

`.rite/wiki-worktree/` は永続 worktree のため削除しない。手動削除が必要なら `git worktree remove .rite/wiki-worktree && git worktree prune`。
rationale: references/rationale.md#wiki-worktree-persist

---

## ステップ 7: transient cycle ブランチを削除

Reviewer subagent が作る `pr-{N}-cycle{X}` 命名の transient ブランチを回収する (reviewer は READ-ONLY 制約で自己クリーン不可)。同じ helper が消費済みの `.rite/release-promotions/{N}.json`（対応 PR が MERGED/CLOSED）も回収する。`.gitignore` は削除しない。non-blocking:

```bash
bash {plugin_root}/hooks/scripts/pr-cycle-cleanup.sh 2>&1 || true
```

---

## ステップ 8: Projects Status を Done に更新

**Critical**: Do NOT skip this step. `rite-config.yml.github.projects.enabled: true` かつステップ 2 で関連 Issue が識別できている場合のみ実行し、結果を `projects_status_updated` (true/false) として context に保持してステップ 12 の表示で参照する（`{projects_enabled}` / `{project_number}` / `{owner}` / `{repo}` / `{issue_number}` はステップ 1.4 / 2 / Placeholder Legend で確定済みの値をそのまま使う）。無効化・Issue 未識別の場合はステップ 9 へ進む。

> **Source of truth**: `plugins/rite/scripts/projects-status-update.sh` に委譲する（`skills/open/SKILL.md` ステップ 2.4 / `skills/ready/SKILL.md` Phase 4 と共通）。参照のみに留めず本ステップに直接 inline する。
rationale: references/rationale.md#projects-status-inline

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
# `jq 2>/dev/null` 抑制 / `failed|*)` catch-all により script が JSON-emit 前に死んだ場合も
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
    echo "Projects Status を \"Done\" に更新しました" ;;
  skipped_not_in_project)
    echo "警告: Issue #{issue_number} は Project に登録されていません。Status 更新をスキップします。" >&2 ;;
  failed|*)
    [ -n "$status_warning_lines" ] && printf '%s\n' "$status_warning_lines" | sed 's/^/  /' >&2
    echo "警告: Projects Status の \"Done\" への更新に失敗しました。手動で更新する場合: gh project item-edit --project-id <project_id> --id <item_id> --field-id <status_field_id> --single-select-option-id <done_option_id>" >&2 ;;
esac
echo "[CONTEXT] PROJECTS_STATUS_UPDATED=$projects_status_updated"
```

**All result branches are non-blocking** — cleanup は Projects Status 更新の失敗で止めない。`auto_add: false` は cleanup 時点で Issue は既に Project 登録済みという前提（`skills/open/SKILL.md` ステップ 2.4 が未登録時に追加している）。API レベルの詳細は [projects-integration.md §2.4](../../references/projects-integration.md#24-github-projects-status-update)、親 Issue の Done 更新の完全形実装は [archive-procedures.md](./references/archive-procedures.md) Phase 3.7.2.1 / `skills/issue-close/SKILL.md` Phase 4.6.3 を参照。

---

## ステップ 9: Wiki Ingest (条件付き)

> **委譲モード（#2133）**: 4-W が `[CONTEXT] CLEANUP_DELEGATED=1` **または `[CONTEXT] CLEANUP_WT=unknown`** を emit している場合、**本ステップ全体を実行しない**（config 読み取り bash・`WIKICHAIN` handoff の set・`Skill: rite:wiki-ingest` の invoke をいずれも行わない）。ガードの対象は config 読み取り bash 単体ではない — 実際に wiki-worktree へ commit するのは skill invoke であり、検出ブロックだけを skip すると `reason` が未計算のまま handoff set と invoke に到達しうる。pending raw source は wiki branch に保持されるため、ステップ 12 が未完了として列挙し、main checkout での `/rite:cleanup {pr_number}` 再実行へ委譲する（本項目は再実行で冪等に完了する）。

`wiki.enabled` (default true) かつ `wiki.auto_ingest` (default false) で、pending raw source があれば実行。

```bash
# YAML 読み取りは canonical helper (実ファイル) に委譲する。skill 本文の fenced bash に
# パーサを書くと Skill loader が位置パラメータを起動引数へ展開し、行マッチが恒偽化して
# 全キーが空になる (静的検出: hooks/scripts/dollar-zero-check.sh)。
wiki_enabled="true"; auto_ingest="false"; wiki_branch="wiki"; reason=""
if . {plugin_root}/hooks/scripts/lib/wiki-config.sh 2>/dev/null; then
  wiki_enabled=$(parse_wiki_scalar enabled | tr '[:upper:]' '[:lower:]')
  auto_ingest=$(parse_wiki_scalar auto_ingest | tr '[:upper:]' '[:lower:]')
  wiki_branch=$(parse_wiki_scalar branch_name)
  case "$wiki_enabled" in false|no|0) wiki_enabled="false" ;; *) wiki_enabled="true" ;; esac
  case "$auto_ingest" in true|yes|1) auto_ingest="true" ;; *) auto_ingest="false" ;; esac
  [ -z "$wiki_branch" ] && wiki_branch="wiki"
else
  # helper 不在は実失敗。設定を読めないまま opt-out default へ吸収させると、この Issue が
  # 潰した「実失敗を正常スキップと誤報告する」経路を再現するため専用 reason で surface する。
  echo "WARNING: {plugin_root}/hooks/scripts/lib/wiki-config.sh を読み込めません。Wiki 設定を判定できないため ingest を skip します" >&2
  reason="config_helper_unavailable"
fi

[ -z "$reason" ] && [ "$wiki_enabled" = "false" ] && reason="disabled"
[ -z "$reason" ] && [ "$auto_ingest" = "false" ] && reason="auto_ingest_off"

pending_count=0
if [ -z "$reason" ]; then
  ref=""
  git rev-parse --verify "$wiki_branch" >/dev/null 2>&1 && ref="$wiki_branch"
  [ -z "$ref" ] && git rev-parse --verify "origin/$wiki_branch" >/dev/null 2>&1 && ref="origin/$wiki_branch"
  if [ -n "$ref" ]; then
    pending_count=$(git ls-tree -r --name-only "$ref" .rite/wiki/raw/ 2>/dev/null \
      | while read -r f; do git show "$ref":"$f" 2>/dev/null | grep -q 'ingested: false' && echo "$f"; done | wc -l)
  fi
  [ "$pending_count" -eq 0 ] && reason="no_pending"
fi

if [ -n "$reason" ]; then
  echo "[CONTEXT] WIKI_INGEST_SKIPPED=1; reason=$reason"
fi
echo "wiki_ingest_reason=${reason:-<run>} pending_count=$pending_count wiki_branch=$wiki_branch"
```

`reason` が空なら (pending raw source あり)、まず Stop-hook 継続保証のチェーン handoff をセットする:

```bash
bash {plugin_root}/hooks/flow-state.sh set --phase "cleanup" --active true \
  --handoff "WIKICHAIN:cleanup:{pr_number}" \
  --next "wiki-ingest return 後、cleanup ステップ 10-12 を継続実行" \
  || echo "WARNING: WIKICHAIN handoff set failed — turn 早期終了への構造的 gate なしで続行します。" >&2
```

> rationale: [stop-loop-continuation-contract.md#wikichain-handoff](../../references/stop-loop-continuation-contract.md#wikichain-handoff)
>
> **制約**: 本 set からステップ 12 末尾の set までの間に別の `flow-state.sh set` を挟むと handoff が default-clear されて gate が外れる。このため、ステップ 10-11 への `flow-state.sh set` の追加自体を禁止する (`--handoff` 再指定での回避は TC-1 の単一 SoT 制約と矛盾するため不可)。intervening set が必要になる設計変更では、本 note と `cleanup-wikichain-handoff-parity.test.sh` TC-1/TC-6 を含む handoff lifecycle 全体を同時に見直すこと。

handoff セット後に invoke する:

```
Skill: rite:wiki-ingest
```

skill return 後、出力から以下のいずれかの sentinel を発火させる (ステップ 12 の表示判定に使用):

- 成功: `[CONTEXT] WIKI_INGEST_DONE=1; pr={pr_number}`
- push 失敗併存 (ingest 出力に `push=failed`): 上記 + `[CONTEXT] WIKI_INGEST_PUSH_FAILED=1; source=cleanup_step9`
- 並行 ingest スキップ (ingest 出力に `WIKI_INGEST_SKIPPED reason=concurrent_ingest`): `[CONTEXT] WIKI_INGEST_SKIPPED=1; reason=concurrent_ingest`（別 live セッションが ingest 中。pending raw は wiki branch に残り次回 ingest が冪等回収する — multi-session §9）
- 失敗: `[CONTEXT] WIKI_INGEST_FAILED=1; reason=ingest_error`
rationale: references/rationale.md#wiki-push-batch

ingest の成否（skip 含む）に関わらずステップ 10 へ進む。

---

## ステップ 10: 関連 Issue / 親 Issue をクローズ

詳細は [archive-procedures.md](./references/archive-procedures.md) (Issue close / Parent Issue handling セクション)。

- 関連 Issue (`{issue_number}`) を close
- 親 Issue (`{parent_issue_number}`) の Tasklist を更新
- 親 Issue の全子 Issue が完了していれば parent も auto-close

結果を context に保持し、ステップ 12 の表示で参照する。

---

## ステップ 11: 作業メモリを最終更新 + ローカルファイル削除

詳細は [archive-procedures.md](./references/archive-procedures.md) の以下 2 セクション両方を実行する:

- **Work Memory final update セクション** (= `### 3.5`): Issue comment への完了マーク追記 (gh API PATCH)
- **State reset セクション** (= `## Phase 4: Reset State and Delete Local Work Memory`): `cleanup-work-memory.sh` 実行による local `.rite/work-memory/issue-*.md` ファイル削除 + flow state `active: false` リセット

両方実行する（片方だけではローカル file が残り `post-tool-wm-sync.sh` が再生成する）。
rationale: references/rationale.md#wm-dual-finalize

あわせて Issue claim を解放する（`multi_session.enabled` に依らず常時実行。claim 取得は /rite:open Step 1.6）。`issue-claim.sh release` は flow-state を変更しないため、ステップ 9 の `WIKICHAIN:` handoff 契約（ステップ 9〜12 間で `flow-state.sh set` を挟まない）に抵触しない:

```bash
bash {plugin_root}/hooks/issue-claim.sh release --issue {issue_number} 2>&1 || echo "WARNING: issue-claim release が失敗しました（claim は stale 判定 + reap で回収されます）。" >&2
```

続けて対象 Issue に紐づく**全セッション**の flow-state・run-queue を非 active 化し、不要 lock を回収する（`cleanup-work-memory.sh` は自セッションのみ）。`reap-issue` は `flow-state.sh set` ではないため WIKICHAIN handoff を default-clear しない。残作業のある自セッション run-queue（batch 継続中）は残 issue があると判定して触れない。失敗は WARNING（対象パス付き）で続行:

```bash
bash {plugin_root}/hooks/flow-state.sh reap-issue --issue {issue_number} 2>&1 \
  || echo "WARNING: reap-issue が失敗しました（stale flow-state / run-queue / lock が残る可能性）。" >&2
```

---

## ステップ 12: 完了報告

```
クリーンアップが完了しました

PR: #{pr_number} - {pr_title}
関連 Issue: #{issue_number}
Status: {projects_status_result}

実行した処理:
- [{base_update_check}] base ブランチを更新 (fetch + merge --ff-only)
- [{session_worktree_check}] セッション worktree 退出・削除 (multi_session)
- [{local_branch_check}] ローカル/リモートブランチ削除
- [{review_cleanup_check}] PR-specific state ファイル削除{follow_up_reverify_note}
- [{projects_check}] Projects Status を Done に更新
- [{wiki_ingest_check}] Wiki ingest (pending raw source のページ統合)
- [x] flow state リセット
- [x] 作業メモリを最終更新 + ローカルファイル削除
- [x] Issue claim 解放
- [x] 関連 Issue をクローズ
- [x] 親 Issue の Tasklist 更新・自動クローズ (該当する場合)

未完了事項:
{outstanding_items_block}
```

**委譲モード（#2133。4-W が `[CONTEXT] CLEANUP_DELEGATED=1` を emit した場合）**: **委譲した 4 項目に限り**下記の個別判定を行わず、`{base_update_check}` / `{session_worktree_check}` / `{local_branch_check}` / `{wiki_ingest_check}` を ` `（未完了）に固定し、それぞれの check 直下の付記も出力しない（委譲は 1 回の明確な案内に収め、診断の羅列に戻さない）。**`CLEANUP_WT=unknown` は本定型ブロックの対象外**（再実行で冪等に完了しないため定型の案内が当たらない）。同じ 4 項目が未実行である点は共通だが、判定は下記の個別判定に任せ、案内は `{session_worktree_check}` の未確認付記が担う。**委譲モードでも実行される項目**（`{review_cleanup_check}` = ステップ 6 / `{projects_check}` = ステップ 8 / 冒頭の `Status: {projects_status_result}`）は**従来どおり個別判定する** — 実行した項目の実失敗を握り潰さないため。`{outstanding_items_block}` は下記の定型ブロックを先頭に置き、個別判定で空欄になった check があればその付記を定型ブロックの後ろに続ける。`{n}` は **`4` + 個別判定で空欄になった check の件数**:

```
- base ブランチの更新（fetch + merge --ff-only）
- セッション worktree の削除
- ローカル/リモートブランチの削除
- Wiki ingest（pending raw source は wiki branch に保持されています）

上記 4 項目は main checkout での操作が必要なため実行していません。main checkout でセッションを開き `/rite:cleanup {pr_number}` を再実行してください（実行済みの項目は冪等にスキップされます）。再実行では base 更新・Wiki ingest・リモートブランチ削除が直接完了し、セッション worktree とローカルブランチは次回セッション開始時の自動回収の対象になります。すぐに消したい場合（main checkout でセッションを開いたあと）: git worktree remove --force '{flow_wt}' && git branch -D {branch_name}
```

以下は**委譲モード以外**（`CLEANUP_DELEGATED` marker が無い場合）の判定。各チェックボックスおよび placeholder の判定:

- `{base_update_check}`: ステップ 4 の `[CONTEXT] BASE_UPDATE=` marker で判定する（上から評価し最初に一致したものを採用）:
  - `ok` のとき: `x`
  - `skipped_not_on_base` のとき（main checkout が `{base_branch}` 以外のブランチ上にあり、rite が意図的にカレントブランチを切り替えず base 更新を skip した。ポリシー上の意図的 skip）: `x`
  - `main_root_unresolved` のとき（main checkout の絶対パスが未解決、またはそこへの `cd` に失敗）: ` ` + 「⚠️ main checkout ルートが解決できず base 更新を skip しました。`git fetch origin {base_branch} && git merge --ff-only origin/{base_branch}` を手動実行してください」を付記
  - `ff_failed_clean` / `ff_failed_divergent` / `ff_failed_discardable` のいずれかのとき（fast-forward 失敗。未コミット変更の有無・内容は marker ごとに異なるが、いずれも base 更新自体は未完了）: ` ` + 「⚠️ base ブランチの fast-forward 更新に失敗しました。`git status` で状態を確認し、`git fetch origin {base_branch} && git merge --ff-only origin/{base_branch}` を手動実行してください」を付記
  - いずれの `[CONTEXT] BASE_UPDATE=` 行も見つからないとき（ステップ 4 の bash block が実行されなかった等の想定外経路）: ` ` + 「⚠️ base 更新の実行結果が確認できませんでした。`git status` / `git log` で状態を確認してください」を付記
- `{session_worktree_check}`: まず `[CONTEXT] ` 行頭一致で `CLEANUP_WT=` family に該当する行を集め、**複数あれば最後の出現 1 行だけ**を分類の判定対象に選ぶ（recency。`/rite:batch-run --merge` は同一セッション内で Issue ごとに `/rite:cleanup` をループ invoke するため先行 Issue の marker が文脈に残る。`{local_branch_check}` が同じ理由で採る規律と同一）。選んだ 1 行が `CLEANUP_WT=unknown` のとき、または `CLEANUP_WT=` 行が 1 本も無いとき（ステップ 4-W の detect が実行されなかった／helper が起動できなかった）は**行を省略せず** ` ` + 「⚠️ 作業ツリーの検出自体が実行できませんでした。`git worktree list` で残存を確認し、あれば `git worktree remove --force <path> && git worktree prune` を手動実行してください」を付記する。**行ごと省略してよいのは `none` かつ `{issue_number}` が非空のときだけ**（= multi_session 無効、または当該 Issue の worktree でない）。`none` かつ `{issue_number}` 空のときは物理 cwd 導出が働かず worktree が実在しうるため（4-W の `none` 分岐を参照）、省略せず上記と同じ未確認の付記を出す。分類が取れている場合は以下を**上から評価し最初に一致したもの**を採用する（`WORKTREE_REMOVE_SKIPPED_LIVE_CWD` / `WORKTREE_REMOVE_SKIPPED_SANDBOX_MASK` / `WORKTREE_REMOVE_FAILED` は Step 4-W guard の if/elif/else で排他だが、複数の `[CONTEXT]` 行が文脈に残る可能性に備えて評価順序を固定する）:
  - `WORKTREE_REMOVE_SKIPPED_LIVE_CWD=1` のとき（別のセッションが作業ツリーを使用中のため削除を見送った）: ` ` + 以下を付記
    ```
    ℹ️ この作業ツリーは別のセッションが使用中のため、削除を見送りました。そのセッションが終了したあと、次回のセッション開始時に作業ツリーとローカルブランチが自動で回収されます。
      すぐに消したい場合（別セッションを閉じたあと）: git worktree remove --force '{flow_wt}' && git worktree prune
    ```
  - `WORKTREE_REMOVE_SKIPPED_SANDBOX_MASK=1` のとき（sandbox のマスクマウント検知により削除を試行しなかった — ）: ` ` + 以下を付記
    ```
    ℹ️ sandbox が作業ツリーの管理ディレクトリにマスクマウントを張っているため、削除を見送りました（この状態での削除試行は管理ディレクトリを半壊させます）。次回のセッション開始時に作業ツリーとローカルブランチが自動で回収されます。
      すぐに消したい場合: sandbox 外のシェルで git worktree remove --force '{flow_wt}' && git worktree prune
    ```
  - `WORKTREE_REMOVE_FAILED=1` のとき（削除そのものが失敗）: ` ` + 以下を付記
    ```
    ⚠️ 作業ツリーの削除に失敗しました。次回のセッション開始時に自動で再回収されます。
      すぐに消したい場合: git worktree remove --force '{flow_wt}' && git worktree prune
      （上記コマンドが「Device or resource busy」で失敗する場合、Step 4-W の sandbox 干渉 WARNING を参照し、sandbox 外のシェルで実行してください）
    ```
  - `[CONTEXT] WORKTREE_REMOVE_*` のいずれの行も無い（削除成功）とき: `x`。**marker family でスコープすること**。ステップ 4-W は削除成功時に marker を出さないため、本 check に限り marker 不在は削除成功を意味してよい。**ただしこの読み替えが許されるのは削除側（`WORKTREE_REMOVE_*`）family に限る** — 検出側（`CLEANUP_WT=`）の marker 不在は上記の先頭ルールが未確認として扱う
- `{local_branch_check}`: ステップ 5 の `[CONTEXT]` 行で判定する。本チェックはローカルとリモートの 2 つの削除を 1 行で表すため、**ローカル側判定とリモート側判定を独立に評価し、両方が `x` 相当のときだけ `x`** とする（どちらか一方でも未完了なら ` ` にし、未完了だった側の付記をすべて列挙する）。ローカル成功をリモート失敗より先に評価して `x` に丸めると、リモート側の残作業が silent に消える（#2016）。

  **marker 名は `[CONTEXT] ` prefix 込みで一致させる（部分文字列一致させない）**: リモート側 marker `REMOTE_BRANCH_DELETE_FAILED` はローカル側 marker `BRANCH_DELETE_FAILED` を部分文字列として含むため、非アンカーで照合すると `[CONTEXT] REMOTE_BRANCH_DELETE_FAILED=1` の行にローカル側ルールが先に一致し、リモートの残渣に対してローカル削除コマンドを案内する誤処方になる。`[CONTEXT] ` の直後から一致させれば `REMOTE_` が間に入るため衝突しない。

  **さらに marker は `branch={branch_name}` までスコープして照合する**: `/rite:batch-run --merge` は同一セッション内で Issue ごとに `/rite:cleanup` をループ invoke するため、先行 Issue の marker が後続の判定文脈に残る。ステップ 5 は各 marker に `; branch={branch_name}` を付けて emit する（fail-fast 経路のみ sentinel `branch=<unsupported branch name>` でどのルールにも一致させず fallback へ倒す）。**`branch=` の値は直後が `;` または行末であることまで含めて一致させる**。`branch=` は**同一ブランチに対する cleanup 再実行**を識別できないため、**同一 marker family で複数行が一致したときは最後の出現を採用する**（recency）。この選択は**各側の判定ルールを評価する前**に行う。recency はローカル側・リモート側の両判定に適用する。
rationale: references/rationale.md#marker-scope-recency

  **さらに prefix は行頭から一致させ、デリミタ内は data として無視する**: ステップ 5 は git の stderr を WARNING に載せるため、marker と同じ出力ストリームに**外部由来の複数行テキスト**が流れる。ステップ 5 は退避 stderr を `--- {source} stderr begin ---` / `--- {source} stderr end ---` で囲む。**照合側は `--- ... begin ---` と `--- ... end ---` に挟まれた区間を、`{source}` が何であれ一律 data として扱い、marker として解釈しない**。**退避テキストの各行は 2 スペースでインデントして出力する**。照合側は**列 0 から始まる行だけを marker 候補とする**。以下のルールで「行があるとき」「行がいずれも無いとき」と書いた判定は、**肯定・否定とも行頭一致**で行う。
rationale: references/rationale.md#marker-data-delimiter

  **ローカル側**（**2 段で判定する**: まず `[CONTEXT] ` 行頭一致 + marker family + `branch={branch_name}` に該当する行を集め、**その中の最後の出現 1 行だけを対象に選ぶ**。次にその 1 行に対して以下のルールを上から評価し最初に一致したものを採用する。段の順序を入れ替えてはならない — ルールを先に評価すると、蓄積した stale marker のうち上位ルールに当たるものが最新の行より先に一致し、recency が働かない）:
  - `[CONTEXT] BRANCH_DELETE_DEFERRED=1; branch={branch_name}` 行があるとき（作業ツリーが未削除のまま残っていて削除を見送った — 別セッション使用中しまたは sandbox マスク skip（sandbox マスク）。原因は断定しない）。**marker の `recovery=` フィールドで文面を出し分ける**（記録できていない経路で「自動回収」と偽らないため — AC-6）: ` ` + 以下を付記
    - `recovery=auto`（PR が merged 済み、reap manifest に記録成功、かつ filtered dirty gate が clean → 次セッションで自動回収される）:
      ```
      ℹ️ ローカルブランチ {branch_name} は、まだ削除されていない作業ツリーで参照されているため残しました。その作業ツリーが解放されたあと、次回のセッション開始時に自動で削除されます（手動操作は不要）。
      ```
    - `recovery=manual`（未マージ PR の強制 cleanup、manifest 記録失敗、または dirty / 判定不能 → 自動回収されないため手動が必要）:
      ```
      ℹ️ ローカルブランチ {branch_name} は、reaper が安全に回収できない作業ツリーで参照されているため残しました。直前の WARNING に表示された実パスで status を確認し、変更を commit / stash / copy して clean にした後だけ、案内された非 force の `git worktree remove` → prune → branch delete を実行してください。実パスが未解決なら先に `git worktree list --porcelain` で特定してください。
      ```
  - `[CONTEXT] BRANCH_DELETED=1; branch={branch_name}` 行があるとき（通常削除、squash 残渣の自動強制削除 `via=squash-merged`、または `BRANCH_DELETE_UNMERGED` をユーザーが強制削除 `-D` で解決した場合に emit される。**`BRANCH_DELETE_UNMERGED=1` より先に評価する**）: `x`
  - `[CONTEXT] BRANCH_ALREADY_ABSENT=1; branch={branch_name}` 行があるとき（cleanup 再実行 / 別セッションで削除済みなどで既に不在。**正常系であり残作業ではない** — リモート側 `REMOTE_BRANCH_ALREADY_ABSENT` と対称）: `x`
  - `[CONTEXT] BRANCH_CHECK_FAILED=1; branch={branch_name}` 行があるとき（ブランチ名の事前検証に落ちた、または `git show-ref` が rc=0/1 以外で失敗して存在を判定できなかったため削除を試行していない。原因は marker の `rc=` で区別する。リモート側 `REMOTE_BRANCH_CHECK_FAILED` と対称）: ` ` + 「ローカルブランチ {branch_name} の存在確認に失敗したため削除を試行していません。`git branch --list {branch_name}` で確認し、残っていれば `git branch -D {branch_name}` で手動削除」を付記
  - `[CONTEXT] BRANCH_DELETE_FAILED=1; branch={branch_name}` 行があるとき: ` ` + 「ローカルブランチ {branch_name} の削除に失敗。`git branch -D {branch_name}` で手動削除（作業ツリーで使用中なら解放後）」を付記
  - `[CONTEXT] BRANCH_DELETE_UNMERGED=1; branch={branch_name}` 行があるとき（= 未マージ PR の強制 cleanup でユーザーが skip 選択。強制削除で解決した場合は上位の `BRANCH_DELETED=1` 行で既に `x` 評価済みのため、ここに到達するのは skip 時のみ）: ` ` + 「ローカルブランチ {branch_name} は未マージのため保留。`git branch -D {branch_name}` で手動削除」を付記
  - `[CONTEXT] BRANCH_DELETED` / `[CONTEXT] BRANCH_DELETE_*` / `[CONTEXT] BRANCH_ALREADY_ABSENT` / `[CONTEXT] BRANCH_CHECK_FAILED` かつ `branch={branch_name}` の行がいずれも無いとき: ` ` + 「ローカルブランチ {branch_name} の削除結果を確認できませんでした。`git branch --list {branch_name}` で確認し、残っていれば `git branch -D {branch_name}` で手動削除」を付記。**marker 不在を「削除成功」と読んではならない** — 不在は「ステップ 5 の bash block が実行されなかった」「出力が compact で失われた」等の**実行結果を確認できていない状態**である。**marker family でスコープすること**

  **リモート側**（**2 段で判定する**: まず `[CONTEXT] ` 行頭一致 + marker family + `branch={branch_name}` に該当する行を集め、**その中の最後の出現 1 行だけを対象に選ぶ**。次にその 1 行に対して以下のルールを上から評価し最初に一致したものを採用する。段の順序を入れ替えてはならない — ルールを先に評価すると、蓄積した stale marker のうち上位ルールに当たるものが最新の行より先に一致し、recency が働かない。#2016）:
  - `[CONTEXT] REMOTE_BRANCH_DELETE_FAILED=1; branch={branch_name}` 行があるとき（`rc=0` 経路で `git push origin --delete` を実行したが失敗した — protected branch / 権限不足 / race。リモートブランチは残存している）: ` ` + 「リモートブランチ {branch_name} の削除に失敗しました。`git push origin --delete "refs/heads/{branch_name}"` で手動削除」を付記
  - `[CONTEXT] REMOTE_BRANCH_CHECK_FAILED=1; branch={branch_name}` 行があるとき（`git ls-remote` が rc=0/2 以外で失敗した、またはブランチ名の事前検証・一時ファイル確保・ref 名の完全一致検証のいずれかが失敗して存在確認自体を完了できなかったため、削除を試行していない）: ` ` + 「リモートブランチ {branch_name} の存在確認に失敗したため削除を試行していません。`git ls-remote --exit-code --heads origin "refs/heads/{branch_name}"` で確認し、残っていれば `git push origin --delete "refs/heads/{branch_name}"` で手動削除」を付記（案内する確認コマンドにも `--exit-code` を付ける）
  - `[CONTEXT] REMOTE_BRANCH_ALREADY_ABSENT=1; branch={branch_name}` 行があるとき（`delete_branch_on_merge: true` によるサーバサイド auto-delete などで既に不在。**正常系であり残作業ではない** — AC-4）: `x`
  - `[CONTEXT] REMOTE_BRANCH_DELETED=1; branch={branch_name}` 行があるとき（`rc=0` 経路で `git push origin --delete` を実行し成功した = 通常削除。`delete_branch_on_merge: false` のリポジトリの正常系）: `x`
  - `[CONTEXT] REMOTE_BRANCH_*` かつ `branch={branch_name}` の行がいずれも無いとき: ` ` + 「リモートブランチ {branch_name} の削除結果を確認できませんでした。`git ls-remote --exit-code --heads origin "refs/heads/{branch_name}"` で確認し、残っていれば `git push origin --delete "refs/heads/{branch_name}"` で手動削除」を付記。**marker 不在を「削除成功」と読んではならない** — 不在は「ステップ 5 の bash block が実行されなかった」「出力が compact で失われた」等の**実行結果を確認できていない状態**である。**marker family でスコープすること**
- `{projects_status_result}` / `{projects_check}`: 以下を**上から評価し最初に一致したもの**を採用する（`{wiki_ingest_check}` の legitimate-skip 区別パターンと統一。ステップ8 は `projects_enabled=false` または Issue 未識別のとき丸ごと skip され `[CONTEXT] PROJECTS_STATUS_UPDATED=` を emit しないため、この legitimate skip と本物の更新失敗を区別する）:
  - `{projects_enabled}`（Placeholder Legend の定義、`rite-config.yml` → `github.projects.enabled`）が `false` のとき: `{projects_status_result}` = `（Projects 連携無効）`、`{projects_check}` = `x`（警告ではなく informational — Wiki ingest の `reason=disabled` と同型）
  - ステップ 2 で関連 Issue が識別できなかった（`{issue_number}` 空）とき: `{projects_status_result}` = `（関連 Issue 未識別のためスキップ）`、`{projects_check}` = `x`
  - 上記 2 条件のいずれにも該当せず `[CONTEXT] PROJECTS_STATUS_UPDATED=true` が見つかったとき: `{projects_status_result}` = `Done`、`{projects_check}` = `x`
  - 上記 2 条件のいずれにも該当せず `[CONTEXT] PROJECTS_STATUS_UPDATED=false` または sentinel 自体が見つからない（= ステップ8 が実行されるべきだったのに失敗/skip された）とき: `{projects_status_result}` = `⚠️ 更新失敗（手動確認が必要）`、`{projects_check}` = ` ` + 「GitHub Projects 画面で Issue #{issue_number} の Status を Done に変更」を付記
- `{review_cleanup_check}`: **follow-up 起票（ステップ 6.0 の `FOLLOW_UP_ISSUE`）と state 削除（`REVIEW_CLEANUP_PARTIAL_FAILURE`）を独立に評価し、両方が `x` 相当のときだけ `x`**（`{local_branch_check}` と同型。どちらか一方でも未完了なら ` ` にし、未完了だった側の付記を列挙する）。照合はいずれも `pr={pr_number}` まで含める（`invalid_pr_number` だけは `pr=` を持たないので marker 名のみ）。**`pr=` の値は直後が `;` または行末であることまで含めて一致させる**（`{local_branch_check}` の `branch=` と同文。`pr=9` が `pr=90` に prefix 一致してはならない）。follow-up 側で同一 marker family の複数行が一致したときは最後の出現（recency）を採る。この選択は**follow-up 側**の判定ルールを評価する前に行う。state 削除側は presence 検査で recency を使わない。helper は API 失敗でも exit 0 のため、起票失敗の一次信号は `FOLLOW_UP_ISSUE` だけである。

  **follow-up 側**（**2 段で判定する**: まず `[CONTEXT] ` 行頭一致 + marker family `FOLLOW_UP_ISSUE` + `pr={pr_number}`（直後が `;` または行末）に該当する行を集め、**その中の最後の出現 1 行だけを対象に選ぶ**。次にその 1 行に対して以下のルールを上から評価し最初に一致したものを採用する。段の順序を入れ替えてはならない）:

  | 検出 | 側の判定 | 付記 |
  |---|---|---|
  | `FOLLOW_UP_ISSUE=failed`（reason 問わず。`helper_rc` / `lookup_api` / `create_api` / `create_script_missing` / `json_undecidable` を含む） | 未完了 | `⚠️ follow-up Issue の起票に失敗しました。review-results JSON の non_blocking_findings[] を元に follow-up ラベル付き Issue を手動作成してください` |
  | `skipped; reason=no_json` | 未完了 | 同上（レビュー結果 JSON 不在） |
  | `skipped; reason=jq_missing` | 未完了 | `⚠️ jq が見つからず follow-up 起票を skip しました。jq を導入したうえで、残存非実測指摘があれば follow-up Issue を手動作成してください` |
  | `created` / `skipped; reason=no_findings` / `skipped; reason=already_exists` / `skipped; reason=all_resolved` | x 相当 | — |
  | `[CONTEXT] FOLLOW_UP_ISSUE=` かつ `pr={pr_number}` の行が無い | 未完了 | `⚠️ follow-up 起票の実行結果が確認できませんでした。残存非実測指摘があれば follow-up ラベル付き Issue を手動作成してください` |

  **FOLLOW_UP_ISSUE marker 不在を成功と読んではならない。**

  `skipped; reason=all_resolved` を x 相当に置くのは、ステップ 6.0.V の再検証で残存 0 件が確定した**正常完了**だから（起票すべきものが無い）。`no_findings` と同じ扱いであり「起票に失敗した」ではない。

  **state 削除側**（`REVIEW_CLEANUP_PARTIAL_FAILURE=1` を上から評価し最初の一致。各行は presence 検査。こちら側に marker が 1 本も無ければ x 相当）:

  | 検出 | 側の判定 | 表示 |
  |---|---|---|
  | `reason=invalid_pr_number`、または `reason=` が `_rm_failure` / `_archive_mkdir_failure` / `_archive_mv_failure` / `_archive_name_collision` / `_gitignore_failure` / `_helper_failed` のいずれかで終わる marker がある | 未完了 | 警告付記 |
  | `reason=review_results_undecidable; cause=jq_missing` がある | 未完了 | `⚠️ jq が見つからず全レビュー結果 JSON を無判定で archive/ へ退避しました。jq を導入してください` |
  | `reason=review_results_undecidable` がある（`cause=jq_rc_<n>`） | x 相当 | `ℹ️ 一部のレビュー結果 JSON は中身を判定できず削除せず archive/ へ退避しました (本 cycle での対応は不要)` |

  行を presence 検査にしてあるので「上から評価し最初の一致」が実際に効く。`_gitignore_failure` は 1 行目の実失敗側に置く。`cause=jq_rc_<n>` を `x` に倒すのは helper が退避成功を `failed` に数えないため。`cause=jq_missing` は環境不備のため実失敗側に置く。
rationale: references/rationale.md#review-cleanup-reasons
- `{follow_up_reverify_note}`: ステップ 6.0.V の `[CONTEXT] FOLLOW_UP_REVERIFY=` marker で判定する（`pr={pr_number}` を持たない single-shot marker のため、複数行あれば最後の出現を採る）:
  - `done` のとき: ` — follow-up 再検証: 解消済み {n_resolved} / 残存 {n_remains} / 判定不能 {n_undecidable}`（`{n_*}` は marker の同名フィールドをリテラル置換）
  - `unavailable` のとき: ` — follow-up 再検証: 未実施（{reason}。全件を転記対象としました）`（`{reason}` は marker の `reason=` 値）
  - marker が無いとき: ` — follow-up 再検証: 実施結果を確認できませんでした（全件を転記対象とした可能性があります）`。本分岐は「節ごと実行されなかった」場合と「抽出は成功したが判定 marker `done` に到達しなかった」場合の 2 つに落ちる（6.0.V は成功時に marker を出さないため後者が marker 皆無になる）。**marker 不在を成功と読んではならない** — 兄弟分岐と同じ規約
- `{wiki_ingest_check}`: 以下の sentinel を上から評価し最初の一致を採用 (`WIKI_INGEST_DONE` + `WIKI_INGEST_PUSH_FAILED` が併存しうるため順序重要):

  | Sentinel | check | 表示 |
  |---|---|---|
  | `WIKI_INGEST_DONE=1` + `WIKI_INGEST_PUSH_FAILED=1` | ` ` | push 失敗警告 |
  | `WIKI_INGEST_PUSH_FAILED=1` 単独 | ` ` | push 失敗警告 |
  | `WIKI_INGEST_DONE=1` 単独 | `x` | — |
  | `WIKI_INGEST_SKIPPED=1; reason=disabled` | `x` | `ℹ️ Wiki ingest スキップ (wiki.enabled=false)` |
  | `WIKI_INGEST_SKIPPED=1; reason=auto_ingest_off` | `x` | `ℹ️ Wiki ingest スキップ (wiki.auto_ingest=false)` |
  | `WIKI_INGEST_SKIPPED=1; reason=no_pending` | `x` | `ℹ️ Wiki ingest スキップ (pending raw source なし)` |
  | `WIKI_INGEST_SKIPPED=1; reason=concurrent_ingest` | `x` | `ℹ️ Wiki ingest スキップ (別セッションが ingest 中。pending raw は次回回収)` |
  | `WIKI_INGEST_SKIPPED=1; reason=config_helper_unavailable` | ` ` | `⚠️ Wiki ingest スキップ (hooks/scripts/lib/wiki-config.sh を読み込めず設定値を判定できませんでした)。pending raw source があれば /rite:wiki-ingest を手動実行してください。` |
  | `WIKI_INGEST_FAILED=1` | ` ` | `⚠️ Wiki ingest が失敗しました。raw source は wiki branch に保持されています。` |
  | `WIKI_INGEST_*` の行がいずれも無いとき | ` ` | `⚠️ Wiki ingest の実行結果を確認できませんでした。pending raw source は wiki branch に保持されています。main checkout で /rite:wiki-ingest を手動実行してください。` |

  最終行は marker 不在一般の受け皿。`CLEANUP_WT=unknown` はステップ 9 全体を実行させず sentinel を 1 本も出さないが、ステップ 12 の委譲モード定型ブロックの対象外でもあるため、この行が無いと適用される規則が存在しない。**marker 不在を成功と読んではならない** — 不在は「ステップ 9 が実行されなかった」等、実行結果を確認できていない状態である。照合は `WIKI_INGEST_` の marker family でスコープする。

  push 失敗警告 (`{wiki_branch}` はステップ 9 で解決済):
  ```
  ⚠️ Wiki ingest: commit は local wiki branch に landed しましたが origin への push に失敗しました。
    手動回復: git -C .rite/wiki-worktree push origin {wiki_branch}
  ```

`{outstanding_items_block}`（非ブロッキング失敗の集約欄）: 上記チェックリストの `{base_update_check}` / `{session_worktree_check}` / `{local_branch_check}` / `{projects_check}` / `{wiki_ingest_check}` / `{review_cleanup_check}` のうち、**チェックボックスが `x` ではなく空欄（未チェック）として描画されたもの**があれば、そのチェックボックス直下の付記文をそのまま箇条書きで列挙する（各チェックボックス直下の付記と同じ文言をここにも重複表示する — チェックリストは一覧性、本節は見落とし防止のための集約であり、両立させる。AC-1 / AC-2）。

判定基準を「⚠️/ℹ️ 等の絵文字 prefix 一致」ではなく「チェックボックスの空欄/`x`」に統一する: 6 check の判定ルールはいずれも「実失敗・残作業のときのみ空欄 ` ` を割り当て、成功時および legitimate な informational skip は `x` を割り当てる」。付記文の絵文字 prefix は飾りに過ぎず、チェックボックス自体の空欄/`x`こそが「未完了か否か」の一次情報である。
rationale: references/rationale.md#outstanding-checkbox

いずれの check も `x`（すべて成功、または legitimate skip）の場合は次の 1 行のみを出力する:

```
- なし（非ブロッキングで継続した失敗はありませんでした）
```

上記の判定は 6 個の check が steps 4/5/8/9 の別々の Bash 呼び出しで確定するため bash 側で合算できず、本コマンド (LLM) が完了報告を組み立てる時点で件数を数える。数えた件数を、他の numbered sentinel (`[pr:created:N]` 等) と同じ表記規約で、ステップ 12 末尾の return signal 行に隣接する HTML コメントとして出力する (grep 可能・rendered view では不可視):

```
<!-- [cleanup:outstanding:{n}] -->
```

`{n}` は「なし」なら `0`、付記ありなら列挙した件数。`/rite:batch-run` ステップ 6 がこの sentinel を読み、バッチ全体のロールアップに使う。

親 Issue 処理結果 (該当する場合のみ):
```
親 Issue 処理:
- 親 Issue: #{parent_issue_number} - {parent_issue_title}
- 結果: {parent_close_result}
```

`{parent_close_result}` の値域 (ステップ 10 で決定された 4 種類のいずれか):
- `✅ 自動クローズ完了 (全 sub-issue clear)` — 親 Issue が全 sub-issue 完了で自動 close
- `🟡 sub-issue 残あり (close 保留)` — 残 sub-issue があり親は open のまま
- `⚠️ 手動確認推奨` — 親 Issue 状態が判定不能で manual triage 推奨
- `(該当なし)` — 親 Issue が識別されなかった (ステップ 2 で見つからず)

未完了タスク Issue 化結果 (該当する場合のみ):
```
未完了タスク処理 — 作成した Issue:
| Issue | タイトル |
|-------|----------|
| #{new_issue_number} | {task_title}（#{issue_number} 残作業） |
```

`{new_issue_number}` の source: ステップ 3 の `create-issue-with-projects.sh` 出力 `issue_number` フィールド (`jq -r '.issue_number'` で抽出した値)。`{task_title}` / `{issue_number}` は ステップ 3 Placeholder Legend と同一定義 (work memory 進捗セクションの未完了タスク見出し / ステップ 2 で識別した関連 Issue 番号)。

stash した変更があれば「復元する (`git stash pop`) / 後で手動で復元」を確認する。

次のステップ (通常 ordered list として出力 — fenced code block 禁止。`<!-- [cleanup:outstanding:{n}] -->` + `<!-- skill return signal: caller must continue next step -->` + `<!-- [cleanup:returned-to-caller] -->` は最終 list item 末尾に半角スペース区切りで inline 付加。`{n}` は上記「未完了事項」判定件数):

次のステップ:
1. `/rite:issue-list` で次の Issue を確認
2. `/rite:open <issue_number>` で新しい作業を開始 <!-- [cleanup:outstanding:{n}] --> <!-- skill return signal: caller must continue next step --> <!-- [cleanup:returned-to-caller] -->

rationale: references/rationale.md#returned-to-caller

最後に flow state を terminal state に落とす:

```bash
bash {plugin_root}/hooks/flow-state.sh set --phase "cleanup" --next "none" --active false --if-exists \
  || echo "WARNING: flow-state deactivate failed — .active=true が残る可能性。" >&2
```

この set は `--handoff` を持たないため、ステップ 9 でセットした `WIKICHAIN:cleanup:{pr_number}` handoff を default-clear する (チェーン完走 = gate 解除)。チェーン途中で turn が閉じた場合のみ Stop hook が handoff を consume して継続を差し戻す。
rationale: references/rationale.md#wikichain-terminal-clear

---

## Error Handling

詳細は [Common Error Handling](../../references/common-error-handling.md)。

| Error | Recovery |
|-------|----------|
| PR Not Found | [共通パターン](../../references/common-error-handling.md) |
| Branch Deletion Failure | `git branch` でブランチ一覧を確認; base ブランチに切替後再実行 |
| Network Error | [共通パターン](../../references/common-error-handling.md) |
| Issue Not Found | [共通パターン](../../references/common-error-handling.md) |
| Issue Close Failure | `gh issue view {issue_number} -R {owner_repo}` で状態確認; 手動で `gh issue close {issue_number} -R {owner_repo}` |
| Incomplete Task Issue Creation Failure | クリーンアップは続行; タスクを手動で Issue 化 |
