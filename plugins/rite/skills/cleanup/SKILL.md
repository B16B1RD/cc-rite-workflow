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

PR マージ後のクリーンアップを実行する。やることは以下のシーケンシャルなタスク列:

0. flow-state を `phase=cleanup, active=true` に初期化
1. PR とブランチの状態を確認
2. 関連 Issue / 親 Issue を識別
3. 未完了タスクをチェック (あれば Issue 化を提示)
4. base ブランチを更新 (fetch + merge --ff-only)
5. ローカル / リモートブランチを削除
6. PR-specific state ファイルを削除
7. transient cycle ブランチを削除
8. Projects Status を Done に更新
9. (Wiki が有効なら) `rite:wiki-ingest` で raw source を統合
10. 関連 Issue / 親 Issue をクローズ
11. 作業メモリを最終更新 + ローカルファイル削除
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
gh pr list -R {owner_repo} --head {branch_name} --state all --json number,title,state,mergedAt,url
```

PR 未検出: `AskUserQuestion` で「ブランチを削除して続行 / キャンセル」を確認。未マージ PR: 「キャンセル (推奨) / 強制クリーンアップ」を確認。

`mergedAt` が非 null（= PR が merge 済み）なら `{pr_merged}=true` として保持する。**それ以外のすべての経路**（未マージ PR の強制クリーンアップ、PR 未検出でブランチ削除を選んで続行した経路など）は `{pr_merged}=false` を既定とする。これによりステップ 4-W / ステップ 5 のすべての分岐で `{pr_merged}` が必ず literal substitute 可能になる（未定義値参照を防ぐ）。ステップ 4-W の worktree パス manifest 記録（Issue #1945）、およびステップ 5 のブランチ削除（squash 残渣の強制削除 / 遅延ブランチの manifest 記録）で参照する。

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

Tasklist fallback では、GitHub code search の `[`/`]` が不安定（リテラルを無視しほぼ全 Issue を返す）なため、`--jq '.[0]'` で先頭を盲目採用すると standalone closing Issue が自分自身や無関係 Issue を親と誤検出する。複数候補を取得し、自己マッチ除外＋候補 body の tasklist 行再検証を経た候補のみ採用する（#1629 で close.md / projects-integration.md §2.4.7.1 に導入したループと同一方針。検証ループ本体（自己除外・再検証 regex・`--limit 10`）は close.md Phase 4.5.1 / projects-integration.md §2.4.7.1 と揃える。`--state` は cleanup が `--state open`（子マージ直後で親は通常 open）を使い、これは projects-integration.md §2.4.7.1 と一致する。差異は close.md Phase 4.5.1 が `--state all`（closing Issue の親が既に closed の可能性）を使う点のみ）:

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

Work Memory の正本を **存在ではなく内容** で選ぶ（Issue #2141）。PostToolUse hook が作る空 stub（`phase: init`・進捗セクションなし）はファイルとして存在するが、存在検査だけだと stub を正本と見なし Issue コメント側 fallback が発火しない（#2127 の「存在と成功の混同」と同族）。進捗セクション見出し（現行 `### 進捗サマリー` / v1 `### 進捗`）が実在するときだけローカル WM を正本とし、stub 判定時はコメント側へ fallback して WARNING で可視化する:

```bash
# WM 正本の選定（内容検査 — Issue #2141）
# 進捗セクション: 現行 `### 進捗サマリー` と v1 `### 進捗` の両方を認める
# （incomplete 抽出が両見出しを拾う契約との整合）
_wm_local=".rite-work-memory/issue-{issue_number}.md"
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
| `local` | 進捗セクションを持つ実 WM を正本として採用（AC-2） |
| `stub_fallback` → 後続で `comment` / `none` | stub を不採用しコメントへ fallback。切替理由は WARNING 済み（AC-1） |
| `comment` | ローカル WM 不在 or stub 後のコメント正本 |
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

汎用的な argument structure・mapping 表は [Issue Creation with Projects Integration](../../references/issue-create-with-projects.md) を参照。`source: "cleanup"` 引数は本 caller の識別子として必須 (将来 metrics 集計で起点 caller を区別するため)。`残作業` label は **step 0 で `gh label create 残作業` を冪等に事前作成する** ことが必須 (`gh issue create --label X` は X 未存在時に fail するため。`2>/dev/null || true` で既存ラベル時のエラーを無視)。

---

## ステップ 4: セッション worktree の退出・削除 + base 更新

### 4-W セッション worktree の退出・削除（multi_session 有効 + worktree 内から呼ばれた場合）

まず multi_session の有効性と、現在 cwd がこの Issue のセッション worktree かどうかを判定する:

```bash
ms_section=$(sed -n '/^multi_session:/,/^[a-zA-Z]/p' rite-config.yml 2>/dev/null) || ms_section=""
ms_enabled=$(printf '%s\n' "$ms_section" | awk '/^[[:space:]]+enabled:/ {print; exit}' \
  | sed 's/[[:space:]]#.*//' | sed 's/.*enabled:[[:space:]]*//' | tr -d '[:space:]"'"'"'' | tr '[:upper:]' '[:lower:]')
case "$ms_enabled" in true|yes|1) ms_enabled=true ;; *) ms_enabled=false ;; esac
# worktree_base も読む（物理 cwd 検出時に worktree dir の親 leaf を照合する。#1622）
ms_base=$(printf '%s\n' "$ms_section" | awk '/^[[:space:]]+worktree_base:/ {print; exit}' \
  | sed 's/[[:space:]]#.*//' | sed 's/.*worktree_base:[[:space:]]*//' | tr -d '[:space:]"'"'"'')
[ -n "$ms_base" ] || ms_base=".rite/worktrees"
flow_wt=$(bash {plugin_root}/hooks/flow-state.sh get --field worktree --default "") || flow_wt=""
cur_top=$(git rev-parse --show-toplevel 2>/dev/null) || cur_top=""
# main checkout の絶対パスを削除前に確保する（Issue #1885）。worktree 自己削除後は
# harness の cwd 追跡のみが main へ移り、この Bash 永続シェルの cwd は削除済み
# worktree に残るため、ステップ 4 の base 更新はこの main_root へ明示的に cd して
# 実行する必要がある。`git worktree list --porcelain` の先頭 worktree entry は
# 常に main checkout（git の仕様上保証）なので、削除がまだ起きていないこの時点で
# 取得すれば cwd の状態に関わらず正しい値が取れる。
main_root=$(git worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2; exit}') || main_root=""
# 検出は helper に委譲する（#1622）。flow-state 未記録（flow_wt 空）でも、物理 cwd が当該
# Issue の rite セッション worktree（<worktree_base leaf>/issue-{issue_number}）なら
# in_worktree_unrecorded を返し worktree= に cur_top を導出する。これにより「物理的に
# worktree 内にいるのに flow-state 未記録 → none で全スキップ → worktree/ブランチ残置」の
# エアポケットを塞ぐ。
detect=$(bash {plugin_root}/hooks/scripts/cleanup-worktree-detect.sh \
  --ms-enabled "$ms_enabled" --flow-wt "$flow_wt" --cur-top "$cur_top" \
  --issue "{issue_number}" --worktree-base "$ms_base") || detect="CLEANUP_WT=none; worktree=$flow_wt"
cleanup_wt=${detect#CLEANUP_WT=}; cleanup_wt=${cleanup_wt%%;*}
flow_wt=${detect##*worktree=}
case "$cleanup_wt" in
  in_worktree)
    dirty=$(bash {plugin_root}/hooks/scripts/lib/git-status-filtered.sh) || dirty="?? (dirty-check failed — assume dirty for safety)"
    echo "[CONTEXT] CLEANUP_WT=$cleanup_wt; worktree=$flow_wt; dirty=$([ -n "$dirty" ] && echo yes || echo no); main_root=$main_root"
    # dirty 一覧は marker と区別できるようデリミタで囲んで表示する（ファイル名由来の偽 marker 混入防止。Step 4 と同一パターン）
    if [ -n "$dirty" ]; then
      echo "--- dirty files begin ---"
      printf '%s\n' "$dirty"
      echo "--- dirty files end ---"
    fi
    ;;
  in_worktree_unrecorded)
    # EnterWorktree を経由しない path 入場のため ExitWorktree が no-op（#2133）。main checkout へ
    # 退出できないまま base 更新・worktree 削除・ブランチ削除・wiki ingest を試行すると、harness の
    # worktree 隔離ガードが拒否する（実測。正確な条件は下記 routing 節を参照）。試行せず委譲する。
    # dirty チェックは worktree を削除しないため不要（未コミット変更は worktree に残り、失われない）。
    echo "[CONTEXT] CLEANUP_WT=$cleanup_wt; worktree=$flow_wt; main_root=$main_root"
    echo "[CONTEXT] CLEANUP_DELEGATED=1; reason=exit_worktree_unavailable"
    ;;
  *)
    echo "[CONTEXT] CLEANUP_WT=$cleanup_wt; worktree=$flow_wt; main_root=$main_root"
    ;;
esac
```

**分岐の基準は「worktree 内か」ではなく「`ExitWorktree` で main checkout へ退出できるか」**（#2133）。`in_worktree` は EnterWorktree 管理下で退出でき、`in_worktree_unrecorded` は path 入場で `ExitWorktree` が no-op になる — 後者では main checkout 操作が harness の worktree 隔離ガードに拒否されるため、実行せず委譲する。

> **ガードが拒否する形（実測）**: harness が拒否するのは **Bash ツール呼び出しのコマンド文字列に直接 `cd {main_root}` / `git -C {main_root}` を書く形**（および worktree 外を向くか検証不能な複合ブロック）であり、helper スクリプト内部の `cd` は拒否されない（ステップ 7 の `pr-cycle-cleanup.sh` は内部で main checkout へ `cd` して `git worktree remove` / `git branch -d` を実行できている）。本 SKILL.md のステップ 4 / 4-W / 5 / 9 はいずれも前者の形を取るため委譲対象になる。helper へ閉じ込めれば自動化できる余地は残るが、それは「worktree 内から全項目を完走させる」設計変更であり Issue #2133 の Non-goal。

- `CLEANUP_WT=in_worktree_unrecorded`（EnterWorktree 非経由の path 入場 = ユーザーがセッションを worktree ディレクトリで開いた場合。`ExitWorktree` が no-op で main checkout へ戻れない）: **下記の手順 1〜4 を実行しない**（`CLEANUP_DELEGATED=1`）。main checkout 操作を要する 4 項目（base 更新 = ステップ 4 / worktree 削除 = 本 4-W / ブランチ削除 = ステップ 5 / wiki ingest = ステップ 9）は**試行せず**、ステップ 12 が未完了として列挙し委譲する。worktree 内で完結する項目（PR-specific state 削除・Projects Status 更新・Issue クローズ・作業メモリ更新・flow state リセット）は通常どおり実行する。ガードを迂回する複合コマンド（main checkout への `cd` / `git -C` リダイレクト）は**試みない** — ガードは正当に機能しており、迂回は設計違反。
  **委譲先は main checkout での `/rite:cleanup {pr_number}` 再実行**（1 系統）。再実行セッションでは flow-state に worktree 記録が無いため 4-W は `CLEANUP_WT=none` を返し、`CLEANUP_DELEGATED` を emit せずステップ 4 / 5 / 9 が通常実行される。base 更新・wiki ingest・リモートブランチ削除はそこで直接完了し、worktree 削除とローカルブランチ削除は**ステップ 5 が `branch` エントリを reap manifest に記録する**ことで次回セッション開始時の自動回収を arm する（`{pr_merged}=true`、manifest への記録を verify 済み、かつ対象 worktree が reaper と同じ filtered dirty gate を通過したときだけ `recovery=auto` になる。未マージ PR の強制 cleanup・記録漏れ・dirty または判定不能な worktree は `recovery=manual` に倒れ手動回復が必要 — 出し分けはステップ 12 の `{local_branch_check}` 判定に規定済み。既存配線で、本ステップから追加の記録は行わない）。
- `CLEANUP_WT=in_worktree`（EnterWorktree 管理下 = `/rite:batch-run` 経由の通常経路。`ExitWorktree` で退出できる）:
  1. `dirty=yes` なら **AskUserQuestion**（「`git stash push` して続行 / 中止」）。説明文は上記 `--- dirty files begin/end ---` デリミタ内に出力された生パス一覧を**引用**する（要約・創作しない）。stash は common git dir に格納されるため worktree 削除後も `git stash pop` 可能（完了報告の stash 案内は従来文面を流用）。
  2. `ExitWorktree` ツールを `action: "keep"` で呼び出し、main checkout に復帰する（path 入場した worktree は remove でも消えない仕様のため**常に keep**）。
  3. main から worktree を削除する。**削除前に self-exclusion 付き live-cwd guard（Issue #1544 / #1670）を通す**: **別の**セッションの harness cwd がまだこの worktree に立っている場合に削除すると、そのセッションの `/clear` が `Path does not exist` で失敗するため、削除せず遅延回収へ委譲する。一方、cleanup を実行している**自セッション自身**（ハーネス = この Bash の親 `$PPID` の process subtree）は除外する — これを除外しないと、ステップ 2 の `ExitWorktree(keep)` が no-op / 失敗に終わった経路で自セッションを「live」と誤検出し、cleanup 自身を理由に削除をブロックする自己ブロッキングが起きる（#1670）。判定は self-exclusion を内蔵した `worktree-foreign-cwd.sh` に委譲する（`worktree-live-cwd.sh` 自体は変更しない — #1670 Non-Target）:
     ```bash
     # rc 0 = 別の live セッションが cwd を置く → 削除を遅延 / rc 1 = 自セッションだけ or 不在
     #        → 削除 / rc 2 = 判定不能（/proc 無し）→ 削除（従来 worktree-live-cwd.sh rc=2 と同じ後方互換）。
     # --self-root "$PPID" でこの Bash の親（claude ハーネス）の process subtree を self として除外する。
     _fc_rc=0
     bash {plugin_root}/hooks/scripts/worktree-foreign-cwd.sh "{flow_wt}" --self-root "$PPID" >/dev/null 2>&1 || _fc_rc=$?
     # sandbox マスク検知（Issue #1957）: sandbox が admin dir の config.worktree に
     # /dev/null マスクマウントを張っている（= character device に見える）状態で
     # `git worktree remove`（--force 含む）を実行すると、working tree 削除失敗後の
     # admin dir 再帰削除が HEAD を unlink した直後にマスクの EBUSY で中断し、HEAD のみ
     # 欠けた半壊 admin dir（corpse）が残る。削除試行自体が半壊を作るため、busy 失敗後の
     # 対処では防げない — 検知したら remove を一切実行せず遅延 reap（corpse 回収経路を持つ
     # pr-cycle-cleanup.sh Step 5）へ委譲する。admin dir は worktree 側 .git ファイルの
     # gitdir: 行から解決する（解決不能・マスク無しなら従来どおり remove を試行 = 非 sandbox
     # 環境で挙動不変の後方互換）。
     _wt_admin=$(sed -n 's/^gitdir: //p' "{flow_wt}/.git" 2>/dev/null | head -1) || _wt_admin=""
     if [ "$_fc_rc" -eq 0 ]; then
       echo "WARNING: 別のセッションがこの作業ツリー（{flow_wt}）を使用中のため、削除を見送りました。そのセッションが終了したあと、次回のセッション開始時に作業ツリーとローカルブランチが自動で回収されます。" >&2
       echo "[CONTEXT] WORKTREE_REMOVE_SKIPPED_LIVE_CWD=1; path={flow_wt}" >&2
     elif [ -n "$_wt_admin" ] && [ -c "$_wt_admin/config.worktree" ]; then
       echo "WARNING: sandbox が作業ツリーの管理ディレクトリ（$_wt_admin/config.worktree）にマスクマウントを張っているため、削除を見送りました。この状態で git worktree remove を実行すると管理ディレクトリが半壊するため、削除自体を試行しません。次回のセッション開始時（sandbox 外）に作業ツリーとローカルブランチが自動で回収されます。実行エージェントはこの場で sandbox を無効化して remove を再試行しないこと。" >&2
       echo "[CONTEXT] WORKTREE_REMOVE_SKIPPED_SANDBOX_MASK=1; path={flow_wt}" >&2
       # Issue #1945: このマスク検知は次に control が渡る側（admin dir 半壊 = corpse）の
       # 直接の前兆であり、corpse は checkout 中 branch を git で解決できないため
       # pr-cycle-cleanup.sh Step 5 のブランチ名 manifest bypass（#1966）が構造的に効かない。パス自体を
       # 事前に記録しておけば、pr-cycle-cleanup.sh の corpse age guard がこの記録を見て
       # 24h 待ちをバイパスできる（{pr_merged}=true のときのみ — AC-4: 未マージ PR の
       # 強制 cleanup では記録しない）。record 自体は non-blocking 契約（rite-tmp-artifact.sh）。
       # `--type session_worktree`（`worktree` ではない）: `worktree` type は Step 4.5 の
       # ungated reap（dirty チェックのみ、claim/self-exclusion/live-cwd ガード無し）が
       # 消費する EPHEMERAL tmp artifact 専用の契約を持つ。session worktree のパスをそこに
       # 混ぜると、Step 4.5 が Step 5 の保護ゲートを経ずに生存中の worktree を reap しうる
       # （"session worktrees go through Step 5's gated reap, never here" 契約違反）。
       # `session_worktree` type は Step 4.5 の専用 case arm が扱うが、この arm は reap を
       # 一切行わず、パスが既に消滅している場合のみ stale 参照を drop（self-heal）し、
       # 存在する場合は verbatim 保持して Step 5 に委ねる。実 reap の消費は
       # Step 5 の gated bypass（下記）のみが行う。
       if [ "{pr_merged}" = "true" ]; then
         bash {plugin_root}/hooks/scripts/rite-tmp-artifact.sh record --type session_worktree --id "{flow_wt}" 2>/dev/null || true
       fi
     else
       # git 診断メッセージは locale 翻訳で揺れるため LC_ALL=C で固定し、busy 検出の
       # substring マッチを安定させる（repo 既存の LC_ALL=C 規約と統一）。stderr を
       # 一時ファイルに退避するのは、通常 fallback（remove → remove --force）の
       # どちらで失敗しても最後の失敗理由を busy 判定に使うため（Issue #1923 AC-5）。
       _wt_rm_err=$(mktemp 2>/dev/null) || _wt_rm_err=""
       if LC_ALL=C git worktree remove "{flow_wt}" 2>"${_wt_rm_err:-/dev/null}" \
          || LC_ALL=C git worktree remove --force "{flow_wt}" 2>"${_wt_rm_err:-/dev/null}"; then
         :
       else
         echo "[CONTEXT] WORKTREE_REMOVE_FAILED=1; path={flow_wt}" >&2
         if [ -n "$_wt_rm_err" ] && grep -qi "busy" "$_wt_rm_err" 2>/dev/null; then
           echo "WARNING: worktree 削除が「Device or resource busy」で失敗しました。Claude Code の sandbox が worktree の .git/worktrees/*/config.worktree・commondir に read-only bind mount を張っている環境では、sandbox 内からの git worktree remove（--force 含む）は構造的に失敗します。この失敗は意図的に non-blocking として遅延 reap（pr-cycle-cleanup.sh）へ委譲するため、実行エージェントはこの場で sandbox を無効化して同コマンドを再試行しないこと。復旧: ユーザーが sandbox 外のシェルで次を実行してください: git worktree remove --force '{flow_wt}' && git worktree prune" >&2
         fi
         # Issue #1945: remove --force 自体がこの busy 失敗の過程で admin dir を
         # 部分破壊し corpse 化した場合、上記マスク検知分岐と同じ理由でブランチ名
         # bypass（#1966）が効かなくなる。パスを reap manifest に記録し、
         # pr-cycle-cleanup.sh の corpse age guard バイパスに委ねる
         # （{pr_merged}=true のときのみ — AC-4）。`--type session_worktree` を使う理由は
         # 上記マスク検知分岐のコメントを参照（Step 4.5 の ungated ephemeral-worktree reap
         # と混ぜず、Step 5 の gated bypass のみに消費させるため）。
         if [ "{pr_merged}" = "true" ]; then
           bash {plugin_root}/hooks/scripts/rite-tmp-artifact.sh record --type session_worktree --id "{flow_wt}" 2>/dev/null || true
         fi
       fi
       [ -n "$_wt_rm_err" ] && rm -f "$_wt_rm_err"
       git worktree prune 2>/dev/null || true
     fi
     ```
     > 通常の `in_worktree` 経路ではステップ 2 の `ExitWorktree(keep)` で自セッションの harness cwd が main に退避済みのため、worktree には自他いずれの cwd も無く `worktree-foreign-cwd.sh` は rc=1（削除）を返す。`ExitWorktree(keep)` が no-op / 失敗に終わった経路でも、残る live cwd は自セッションのハーネス（`$PPID` subtree）だけなので self-exclusion により rc=1（削除）となり、自己ブロッキングしない。rc=0（遅延）になるのは別セッションのハーネスが実際にこの worktree 内に cwd を持つ場合のみ。`/proc` の無い環境では rc=2 となり従来どおり削除を実行する（後方互換）。
  4. 削除失敗（`WORKTREE_REMOVE_FAILED`）、live-cwd skip（`WORKTREE_REMOVE_SKIPPED_LIVE_CWD`）、または sandbox マスク skip（`WORKTREE_REMOVE_SKIPPED_SANDBOX_MASK` — Issue #1957。remove 試行自体が admin dir を半壊させるため試行せず委譲）は **WARNING を表示して続行**（non-blocking。`pr-cycle-cleanup.sh` の遅延 reap へ委譲。ステップ 12 報告に失敗/skip と手動コマンドを表示）。busy 失敗時は上記の sandbox 干渉 WARNING も追加表示される（Issue #1923 AC-5）。`WORKTREE_REMOVE_FAILED` / `WORKTREE_REMOVE_SKIPPED_SANDBOX_MASK` は `{pr_merged}=true` のときのみ reap manifest（`.rite/tmp-artifacts.tsv`）へ `session_worktree` type でパスを記録する（Issue #1945。`worktree` type ではない — Step 4.5 の ephemeral tmp artifact 専用 ungated reap と混ぜないため）。corpse 化（admin dir 半壊で git がツリーを認識できなくなる状態）した場合、checkout 中 branch が解決不能でブランチ名 bypass（#1966）が構造的に効かないため、パス自体の記録で `pr-cycle-cleanup.sh` Step 5 の corpse age guard（24h 待ち）をバイパスさせ、mount 解放後の次回セッションで即座に回収できるようにする。
- `CLEANUP_WT=in_main`（resume 等で既に main 復帰済み）: 上記 1〜2 をスキップ。worktree が残っていれば 3 を実行（既削除なら 3 もスキップ = 冪等）。in_main では所有セッションが別セッションの可能性があるため、3 の self-exclusion 付き live-cwd guard が特に重要（live-cwd guard による遅延は別セッション在席時。これに加え sandbox マスク検知時（#1957）も削除を試行せず遅延する）。
- `CLEANUP_WT=none`（multi_session 無効、または worktree 関連なし = 物理 cwd も当該 Issue の worktree でない）: 4-W 全体を no-op でスキップ。**注**: flow-state 未記録でも物理 cwd が当該 Issue の worktree なら `in_worktree_unrecorded` に分類されここには落ちない（#1622）。

> **復旧: `/clear` が `Path does not exist` で失敗する場合（Issue #1552）**
> セッション worktree（`.rite/worktrees/issue-{N}`）が遅延 reap または手動削除で消えた後、所有セッションをハーネスが resume すると cwd 復元先が無く `/clear` が `Error: Path "...worktrees/issue-{N}" does not exist` で失敗することがある。`pr-cycle-cleanup.sh` の worktree liveness guard（Issue #1524/#1544/#1552）はこれを予防するが、ハーネスの cwd レコード自体は rite から intercept できないため、万一発生した場合は次のいずれかで復旧する:
> 1. リポジトリ root（main checkout）で**新しいセッションを開始**する（cwd が有効になり `/clear` が機能する）。
> 2. 作業を続けるなら、有効なディレクトリで `/rite:recover {issue_number}` を実行する（worktree が消えていれば再構築経路に入る）。
> 3. 残骸が残っていれば `git worktree prune` で参照を整理する。
> session-start hook の挙動は 2 経路に分かれる（相互排他、同一フック実行内では片方のみ発火、いずれも非blocking）: (a) cwd 自体が消えた session worktree を指す場合は上記ガイドを stderr に表示してその場で `exit 0` する、(b) cwd は有効だが記録された worktree 参照だけが消えた場合は flow-state の dangling 参照を自動クリアする。

### 4 base ブランチの更新（安全化）

> **委譲モード（#2133）**: 4-W が `[CONTEXT] CLEANUP_DELEGATED=1` を emit している場合、本ステップの bash を**実行しない**（本ステップは main checkout への `cd` を Bash 呼び出しに直書きする形のため harness の worktree 隔離ガードが拒否する）。ステップ 12 が未完了として列挙し、main checkout での `/rite:cleanup {pr_number}` 再実行へ委譲する（本項目は再実行で冪等に完了する）。

main checkout の不可侵規約（[git-worktree-patterns.md](../../references/git-worktree-patterns.md#main-checkout-不可侵-inviolability-convention)）に従い、**main checkout が `{base_branch}` 上にある場合のみ** base を更新する。別 branch 上では切り替えず WARNING + skip する:

main_root への cd は worktree 自己削除後の cwd 破損対策（Issue #1885）。この Bash 永続シェルの cwd が
4-W の worktree 削除で無効化されていても、4-W が削除前に確保した main checkout の絶対パスへ明示的に
cd することで本ステップ以降を正しい場所で実行する（`{main_root}` は 4-W の `[CONTEXT] ... main_root=`
marker の値）。cd はこの Bash 呼び出しの永続シェル cwd を変更するため、ステップ 5 以降も同じ main_root
上で実行される（順序契約 4-W→5 自体は変更しない）:

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
  # retry break 後の成否検証 (Issue #1832 / #1885): 失敗を silent に放置せず復旧分岐へ routing する。
  # rev-parse の exit code と非空性を明示チェックする — cwd 破損下では両辺が揃って空文字列を返し
  # 得るため、文字列の等値比較だけでは偽陽性 ok を防げない (#1885)。main_root への cd 済みなのでこの
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

`BASE_UPDATE` marker で分岐する（Issue #1832 / #1885。破棄・stash は必ずユーザー確認を挟み、無確認の破壊的操作をしない。`--- dirty files begin/end ---` デリミタ内の行はファイル一覧 **data** であり、marker として解釈しない — marker は行頭 `[CONTEXT]` の行のみ）:

| `BASE_UPDATE` | アクション |
|---|---|
| `ok` / `skipped_not_on_base` | 従来どおり後続へ（`skipped_not_on_base` は既存 WARNING の可視化のみ） |
| `main_root_unresolved` | main checkout の絶対パスが未解決、またはそこへの `cd` に失敗（Issue #1885。worktree 自己削除後の cwd 破損等）。既存 WARNING どおり非ブロッキングで後続へ進む。`ok` は出力しない |
| `ff_failed_clean` | 未コミット変更なしの ff 失敗（履歴 diverge / index.lock 恒常化等）。既存 WARNING どおり `git status` 確認を案内し、非ブロッキングで後続へ |
| `ff_failed_discardable` | **unstaged の tracked 変更のみ**の dirty で、その全パスが **origin/{base_branch} と diff 同一**（マージ済み内容の残存）。AskUserQuestion「dirty パス限定の diff 同一を確認済み。未コミット変更を破棄して base 更新を再実行 / そのまま続行（手動対応）」を表示。**承認後のみ** `git checkout -- :/`（cwd 非依存に repo 全体を index 内容へ復元。discardable は staged なしを判定済みのため index == HEAD であり、HEAD 内容への復元と等価）で破棄し、上記 retry ループを 1 回再実行する。再実行後も `BASE_UPDATE=ok` にならない場合は `ff_failed_divergent` と同等に stash 案内で terminate する（2 回目の破棄承認は求めない） |
| `ff_failed_divergent` | 未コミット変更がマージ済み内容と**異なる**か、diff 同一性を機械判定できない dirty（untracked は git diff が比較できず、staged 変更は working tree 比較で内容を検証できないため、いずれもここに倒す）。stash 案内を表示して terminate（データ喪失なし）: `git stash push -u -m "rite-cleanup: manual-stash before base update (issue-{issue_number})"` を提示し、ユーザー実行後の `/rite:recover` 再開を案内する。自動 stash はしない |

> **multi_session 無効（従来モード）の場合**: 従来どおり `git checkout {base_branch} && git fetch origin {base_branch} && git merge --ff-only origin/{base_branch}` を実行する（base branch 以外にいて未コミット変更があれば「stash して続行 / キャンセル」を確認。stash は `git stash push -m "rite-cleanup: auto-stash before cleanup"`）。fast-forward 不可 / コンフリクト時は `git status` で確認・解決後の再実行を案内し terminate。

---

## ステップ 5: ローカル / リモートブランチを削除

> **順序**: branch 削除は **worktree 削除後にのみ成功する**（Git 制約: worktree で checkout 中の branch は削除不可）。multi_session 時は必ずステップ 4-W → 本ステップの順で実行する。
>
> **委譲モード（#2133）**: 4-W が `[CONTEXT] CLEANUP_DELEGATED=1` を emit している場合、本ステップの bash ブロックを**いずれも実行しない**（worktree を削除していないため checkout 中の branch は構造的に削除できない。リモート削除は本ステップ内でローカル削除と 1 ステップで扱うため同時に委譲する — `git push origin --delete` 自体はガードに抵触せず worktree 内からも実行できる）。ステップ 12 が未完了として列挙し、main checkout での `/rite:cleanup {pr_number}` 再実行へ委譲する。再実行では本ステップが通常実行され、リモート削除は直接完了し、ローカル削除は `used by worktree` で見送られた上で `branch` エントリを reap manifest に記録して次回セッション開始時の自動回収を arm する（`{pr_merged}=true`、共有 manifest のエントリを verify 済み、かつ対象 worktree が reaper と同じ filtered dirty gate を通過したときだけ `recovery=auto` になる。未マージ PR の強制 cleanup・記録漏れ・dirty または判定不能な worktree は `recovery=manual` に倒れ手動回復が必要 — 出し分けは本ステップの `recovery=` 判定が持つ）。

```bash
# worktree 削除が遅延した場合（ステップ 4-W が WORKTREE_REMOVE_SKIPPED_LIVE_CWD = 別 live
# セッションが worktree 使用中、または WORKTREE_REMOVE_SKIPPED_SANDBOX_MASK = sandbox マスク
# 検知で自セッション worktree の削除を試行しなかった（#1957）、のいずれかを残した場合）、
# branch は worktree で checkout 中のため削除できない。その場合は強制削除せず reap manifest に
# 記録し（#1670）、worktree が解放（遅延 reap の corpse 回収含む）されたあと
# pr-cycle-cleanup.sh Step 5 が次セッションで branch・worktree の双方を回収する（dead-letter 解消）。
# manifest 記録は Step 5 の free-claim 24h age guard 自体もバイパスさせる（#1966 — ハーネスが
# worktree root の mtime をセッション毎に更新するため、記録なしでは回収が永遠に始まらない）。
# 自セッションの worktree は通常 4-W の self-exclusion 後に即時削除されるが、sandbox マスク
# 検知時は削除を試行しないため自セッション由来でも本経路に入る（「別セッション在席時のみ」では
# ない）。git 診断メッセージは locale 翻訳で揺れるため LC_ALL=C で固定して
# substring マッチを安定させる（repo 既存の wiki-lint-*.sh と同規約）。
# `{pr_merged}` はステップ 1.3 の PR 状態（`mergedAt` 非 null なら `true`、それ以外すべて
# `false`。Step 1.3 と同一定義）を Claude が literal substitute する。squash merge では feature の
# コミットが base の祖先にならないため、worktree 解放後でも `git branch -d` が "not fully merged" で
# 拒否する。PR が merged 済み（{pr_merged}=true）ならこれは squash の残渣であり強制削除して安全
# （ユニークな未マージ作業は無い）。
# ブランチ名の事前検証。空値と marker のデリミタ文字（`;` `=`）はいずれも本ステップの契約を
# 満たせない: 空値は `git show-ref --verify "refs/heads/"` が rc=1（不在）を返すため
# 「既削除 = 正常系」に倒れ、**削除していないのに完了と報告**する。`;` `=` はどちらも合法な
# refname 文字で、`branch=` フィールドの右端境界を騙って別ブランチの判定ルールに一致しうる。
# エンコード規約を emitter/consumer の両側へ増やすより、契約を満たせない入力を fail-fast で弾く
# （Fail-Fast First）。sentinel は空白を含めて refname として非合法にし、実在ブランチとの衝突を
# 構造的に排除する。リモート削除ブロックも同じ検査を独立に持つ（各ブロックが単体で抽出・実行
# されうるため、ガードもブロック単位で自己完結させる）。
case "{branch_name}" in
  '')
    # 空値は処方を出さない。存在しないブランチに対する `git branch -D ""` は必ず失敗するため、
    # 本 Issue が塞いだ「必ず失敗する処方」と同じものを新設することになる。
    echo "[CONTEXT] BRANCH_CHECK_FAILED=1; branch=<unsupported branch name>; rc=empty-branch-name" >&2
    echo "WARNING: 削除対象のブランチ名が空のため、ローカルブランチの削除を試行していません。対象ブランチを特定してから再実行してください。" >&2 ;;
  *[\;=]*)
    echo "[CONTEXT] BRANCH_CHECK_FAILED=1; branch=<unsupported branch name>; rc=marker-delimiter-in-branch-name" >&2
    echo "WARNING: ブランチ名に marker のデリミタ文字 (; =) が含まれるため、ローカルブランチの削除を試行していません。手動で削除してください: git branch -D \"{branch_name}\"" >&2 ;;
  *)
# rc を捕捉して **rc=1（不在）だけ**を「既削除」に倒す。否定付き if の短絡形だと rc=128（リポジトリ外での
# 実行等）まで「不在」に丸め、ローカルブランチが残ったまま完了と報告される（リモート側が rc=0/2
# 以外を REMOTE_BRANCH_CHECK_FAILED に倒すのと同じ扱いにする — #2016）。
# ただし rc=1 は「本当に不在」だけを意味しない — refname として非合法な値（末尾空白 / `:` 混入 /
# `..` や制御文字の混入等）でも rc=1 になり、同じく「既削除 = 正常系」へ倒れて削除していないのに
# 完了と報告する。そこで **refname 構文に起因する rc=1 を分離する**ために先に合法性を検査する。
# **これは rc=1 の多義性を解消しない** — `origin/foo` のように構文的には合法だが対象と別物の値、
# および ref store 側の障害（ref ファイル不可読 / 破損）はこの検査を素通りし、依然として
# 「不在」として扱われる。塞げていない範囲を「塞いだ」と書かないための注記。
# stderr は退避して WARNING に載せる（rc=128 の原因が消えると認証失敗・リポジトリ外・破損が
# 区別できない。リモート側が $_ls_err で原因を surface するのと対称）。
LC_ALL=C git check-ref-format "refs/heads/{branch_name}" >/dev/null 2>&1; _cf_rc=$?
_sr_err=$(LC_ALL=C git show-ref --verify --quiet "refs/heads/{branch_name}" 2>&1 >/dev/null); _sr_rc=$?
if [ "$_cf_rc" -ne 0 ]; then
  echo "[CONTEXT] BRANCH_CHECK_FAILED=1; branch={branch_name}; rc=invalid-refname" >&2
  echo "WARNING: ブランチ名が refname として非合法なため、ローカルブランチの存在を判定できず削除を試行していません (git check-ref-format rc=${_cf_rc})。" >&2
elif [ "$_sr_rc" -eq 1 ]; then
  # 既に不在（cleanup の再実行 / 別セッションで削除済み）は正常系。存在確認せず `git branch -d` に
  # 渡すと "branch not found" で失敗して下の `*)` に落ち、BRANCH_DELETE_FAILED として
  # 「削除に失敗。`git branch -D` で手動削除」という**必ず失敗する処方**を出す。これはリモート側で
  # REMOTE_BRANCH_ALREADY_ABSENT として正常系に倒した症状と同型で、ローカル側だけ残っていた
  # （#2016）。git の診断メッセージ文字列に依存しないよう show-ref で判定する。
  echo "[CONTEXT] BRANCH_ALREADY_ABSENT=1; branch={branch_name}"
elif [ "$_sr_rc" -ne 0 ]; then
  # 存在有無が不明。削除を試行せず未完了として surface する（安全側）。
  echo "[CONTEXT] BRANCH_CHECK_FAILED=1; branch={branch_name}; rc=${_sr_rc}" >&2
  echo "WARNING: ローカルブランチ {branch_name} の存在確認に失敗したため削除を試行していません (git show-ref rc=${_sr_rc}):" >&2
  echo "--- show-ref stderr begin ---" >&2
  printf '%s\n' "${_sr_err}" | tr -d '\r' | sed 's/^/  /' >&2
  echo "--- show-ref stderr end ---" >&2
elif del_err=$(LC_ALL=C git branch -d {branch_name} 2>&1); then
  echo "[CONTEXT] BRANCH_DELETED=1; branch={branch_name}"
else
  case "$del_err" in
    *"used by worktree"*|*"checked out"*)
      # #1670: 遅延ブランチを次セッション回収へ配線する（dead-letter 解消）。PR が merged 済み
      # （{pr_merged}=true）のときのみ reap manifest に記録し、worktree が解放（別セッション終了
      # または遅延 reap での回収 — 原因は断定しない）されたあと pr-cycle-cleanup.sh Step 5 が
      # 安全に回収できるようにする。未マージ PR の強制
      # cleanup 時（{pr_merged}=false）は記録しない（作業損失防止 — AC-4）。
      # **recovery= の意味（AC-6）**: rite-tmp-artifact.sh は非ブロッキング契約で、append 失敗でも
      # WARNING を出して exit 0 を返す（非 0 は usage error のみ）。したがって record の exit code では
      # 記録成否を判定できない。共有 manifest を直接 verify し、エントリが実在するときだけ
      # recovery=auto を emit する（記録できていない経路で「自動で回収されます」と偽らない）。
      # {pr_merged}=false / 記録漏れ / shared-root 解決不能 / reaper dirty gate を
      # 通過できない worktree はすべて recovery=manual に倒す。
      bash {plugin_root}/hooks/scripts/cleanup-deferred-branch-recovery.sh \
        --branch "{branch_name}" --pr-merged "{pr_merged}" ;;
    *"not fully merged"*)
      if [ "{pr_merged}" = "true" ]; then
        # squash merge の残渣 — PR は merged 済みなので強制削除して安全。
        LC_ALL=C git branch -D {branch_name} >/dev/null 2>&1 \
          && echo "[CONTEXT] BRANCH_DELETED=1; branch={branch_name}; via=squash-merged" \
          || echo "[CONTEXT] BRANCH_DELETE_FAILED=1; branch={branch_name}" >&2
      else
        echo "[CONTEXT] BRANCH_DELETE_UNMERGED=1; branch={branch_name}" >&2
      fi ;;
    *)
      echo "[CONTEXT] BRANCH_DELETE_FAILED=1; branch={branch_name}" >&2
      echo "WARNING: ローカルブランチ {branch_name} の削除に失敗しました:" >&2
      echo "--- branch delete stderr begin ---" >&2
      # 外部由来テキストの CR を除去してからインデントする。`sed 's/^/  /'` は `\n` 区切りの行頭
      # にしか空白を付けないため、`\r` が残ると CR 以降が表示上は列 0 に着地し、marker を騙る
      # 経路が開く（security boundary はインデント側にあるという規約の穴になる）。
      printf '%s\n' "$del_err" | tr -d '\r' | sed 's/^/  /' >&2
      echo "--- branch delete stderr end ---" >&2 ;;
  esac
fi
    ;;
esac
# リモートブランチ削除（#2016）。`git ls-remote --heads` は ref 不在でも rc=0（空 stdout）を返すため、
# `&&` では「存在するときだけ削除する」ガードにならない。--exit-code で ref 不在を rc=2 として
# 判別する。リポジトリ設定 delete_branch_on_merge: true では merge 時にサーバサイドで head が
# 削除済みのため、この経路は通常 rc=2 に落ちる。
# rc=2（不在）だけを「既削除」とみなし、それ以外の非 0（ネットワーク断・認証失敗の 128 等）は
# 存在有無が不明なため削除を試行せず未完了として surface する（不明を「既削除」に丸めると、
# delete_branch_on_merge: false のリポジトリでリモートブランチが黙って残る）。
# ただし rc=128 は sandbox の HTTPS プロキシ断など **transient** で再現することがある
# （PR #2137 cleanup で 1 回目 128 → 2 回目 2 を実測。Issue #2140）。1 回目が 128 のときだけ
# **1 回再試行**し、2 回目の結果を採用する。2 回とも 128 なら従来どおり CHECK_FAILED で
# 削除を処方しない（確認できていない状態での偽処方は #2016 と同型）。rc=0/2 の即返しは
# 再試行せず 1 回で確定する（正常系の遅延を増やさない）。
# stderr は捨てず退避して WARNING に載せる（rc だけでは認証失敗・DNS 解決失敗・proxy 遮断がすべて
# 128 に潰れて切り分けられない。直上のローカル削除が $del_err で原因を surface するのと対称）。
# stdout は完全一致検証に使うため別ファイルへ分離する（`2>&1 >/dev/null` で捨てない）。
# pattern は full refname で渡すが、**それだけでは完全一致にならない**。`git ls-remote <pattern>` は
# ref の先頭または任意の slash 境界からの tail 一致であり、`refs/heads/` を前置しても anchor されない
# （実測: origin に `refs/heads/wip/refs/heads/X` があると pattern `refs/heads/X` が rc=0 で一致する）。
# そのため rc=0 のあとに stdout の ref 名が `refs/heads/{branch_name}` と完全一致することを検証し、
# 一致しなければ不在（rc=2 相当）に落とす。この検証がないと、対象が不在でも rc=0 で削除経路へ入り、
# 存在しないブランチに対する偽の残作業と必ず失敗する処方を報告することになる（#2016）。
# ブランチ名が marker のデリミタ文字（`;` `=`）を含む場合は、`branch=` フィールドの右端境界を騙って
# 別ブランチの判定ルールに一致しうる（`;` `=` はいずれも合法な refname 文字）。エンコード規約を
# emitter/consumer の両側に増やすより、契約を満たせない入力を fail-fast で弾く（Fail-Fast First）。
case "{branch_name}" in
  '')
    echo "[CONTEXT] REMOTE_BRANCH_CHECK_FAILED=1; branch=<unsupported branch name>; rc=empty-branch-name" >&2
    echo "WARNING: 削除対象のブランチ名が空のため、リモート削除を試行していません。対象ブランチを特定してから再実行してください。" >&2 ;;
  *[\;=]*)
    # sentinel 値を使い、実ブランチ名を marker へ載せない（載せると誤帰属そのものを再現する）。
    # 値に空白を含めて refname として非合法にし、実在ブランチとの衝突を構造的に排除する。
    # consumer 側は `branch={branch_name}` に一致しないため fallback（未確認）に落ちる。
    # 空値も弾く — 空だと完全一致検証が決して一致せず「既削除 = 正常系」に倒れ、削除していない
    # のに完了と報告する。
    echo "[CONTEXT] REMOTE_BRANCH_CHECK_FAILED=1; branch=<unsupported branch name>; rc=marker-delimiter-in-branch-name" >&2
    echo "WARNING: ブランチ名に marker のデリミタ文字 (; =) が含まれるため、リモート削除の自動判定を行いません。手動で削除してください: git push origin --delete \"refs/heads/{branch_name}\"" >&2
    ;;
  *)
# refname 非合法な値は ls-remote の完全一致検証が決して一致せず「既削除 = 正常系」へ倒れるため、
# ローカル側と対称に先に弾く（削除していないのに完了と報告するのを防ぐ）。
if ! LC_ALL=C git check-ref-format "refs/heads/{branch_name}" >/dev/null 2>&1; then
  echo "[CONTEXT] REMOTE_BRANCH_CHECK_FAILED=1; branch={branch_name}; rc=invalid-refname" >&2
  echo "WARNING: ブランチ名が refname として非合法なため、リモートブランチの存在を判定できず削除を試行していません。" >&2
else
# `_ls_out` は先行宣言 → cleanup 関数 → 4 行 trap → mktemp の順で確保する
# （rationale: ../../references/bash-trap-patterns.md#signal-specific-trap-template）。`git ls-remote` は本ブロック唯一のネットワーク
# 操作で最も長くブロックしうるため、Ctrl-C の着弾点になりやすい。
_ls_out=""
_check_reason=""
_rite_cleanup_phase5_cleanup() { [ -n "${_ls_out:-}" ] && rm -f "$_ls_out"; return 0; }
trap 'rc=$?; _rite_cleanup_phase5_cleanup; exit $rc' EXIT
trap '_rite_cleanup_phase5_cleanup; exit 130' INT
trap '_rite_cleanup_phase5_cleanup; exit 143' TERM
trap '_rite_cleanup_phase5_cleanup; exit 129' HUP
_ls_out=$(mktemp "${TMPDIR:-/tmp}/rite-cleanup-lsremote-XXXXXX") || _ls_out=""
if [ -z "$_ls_out" ]; then
  # stdout を分離できない = 完全一致検証ができない。検証なしで削除経路へ入ると tail 一致の
  # 誤ヒットで別 ref を削除しうるため、削除を試行せず未確認として surface する（安全側）。
  echo "[CONTEXT] REMOTE_BRANCH_CHECK_FAILED=1; branch={branch_name}; rc=mktemp-failed" >&2
  echo "WARNING: 一時ファイルを作成できずリモートブランチの存在確認ができないため、削除を試行していません。" >&2
else
_ls_err=$(LC_ALL=C git ls-remote --exit-code --heads origin "refs/heads/{branch_name}" 2>&1 >"$_ls_out"); _ls_rc=$?
# transient 失敗 (rc=128: ネットワーク断・proxy 遮断等) は 1 回だけ再試行する (Issue #2140)。
# 2 回目の結果を採用する。rc=0/2 の即返しは従来どおり 1 回で確定。2 回とも 128 なら
# 下の `*)` が CHECK_FAILED を emit し、削除は処方しない（確認できていない状態での偽処方を防ぐ — #2016）。
if [ "$_ls_rc" -eq 128 ]; then
  _ls_err=$(LC_ALL=C git ls-remote --exit-code --heads origin "refs/heads/{branch_name}" 2>&1 >"$_ls_out"); _ls_rc=$?
fi
# rc=0 でも完全一致でなければ不在扱いに落とす（tail 一致による誤ヒットの排除）。ls-remote の出力は
# `<sha>\t<refname>` 形式。ブランチ名は `.` 等の正規表現メタ文字を含みうるため、regex ではなく
# awk のフィールド完全一致で比較する。
# awk の rc は 0（一致）/ 1（不一致）/ その他（awk 自体の異常終了）の 3 値に分ける。否定付き awk 呼び出しの
# 短絡形だと 1 とその他を融合し、awk が異常終了しただけで「既削除 = 正常系」に倒れてリモート
# ブランチが黙って残る（直上の mktemp 失敗経路が「判定不能は削除を試行せず surface する」と
# している契約に反する — #2016）。
if [ "$_ls_rc" -eq 0 ]; then
  awk -F'\t' -v r="refs/heads/{branch_name}" '$2 == r { found = 1 } END { exit !found }' "$_ls_out"
  _match_rc=$?
  case "$_match_rc" in
    0) : ;;                       # 完全一致 = 存在
    1) _ls_rc=2 ;;                # 不一致 = 不在
    # 判定不能 → 下の `*)` が CHECK_FAILED を emit。`_ls_rc` は数値のまま保ち、原因は別変数へ
    # 分ける（文字列を代入すると後続で数値比較を足した瞬間に壊れ、診断も ls-remote に誤帰属する）。
    *) _ls_rc=3; _check_reason="ref-match-awk-${_match_rc}" ;;
  esac
fi
rm -f "$_ls_out"; _ls_out=""
case "$_ls_rc" in
  0)
    # リモート状態を実際に変更する唯一の分岐。push は protected branch / 権限不足 /
    # ls-remote 〜 push 間の race で失敗しうるため、成否の**両方**を marker で surface する。
    # 成功側も positive marker を出すのは、marker 不在を「削除成功」の符号化に使わないため
    # （#2016）。不在を成功と読むと、本ブロックがそもそも実行されなかった経路・出力が
    # compact で失われた経路と削除成功が区別できず、consumer が不在を根拠に完了と断定する。
    # 全経路が marker を持てば、marker 不在は「実行結果を確認できていない」という
    # 別の意味だけを持つ（同ファイルの {base_update_check} が採る規約と同形）。
    # 削除先も namespace 修飾する。非修飾の <dst> は remote の**全 namespace** に対して解決されるため、
    # `refs/heads/{branch_name}` が不在で `refs/tags/{branch_name}` が存在する状態では**タグを削除する**
    # （実測確認済み。共有リモートのタグ削除は不可逆でリリース/CI を壊す）。存在確認した ref 集合と
    # 削除する ref 集合を定義上一致させる（#2016）。
    if _push_err=$(LC_ALL=C git push origin --delete "refs/heads/{branch_name}" 2>&1); then
      echo "[CONTEXT] REMOTE_BRANCH_DELETED=1; branch={branch_name}"
    else
      echo "[CONTEXT] REMOTE_BRANCH_DELETE_FAILED=1; branch={branch_name}" >&2
      # 外部由来テキストはデリミタで囲む。行頭一致だけでは複数行 stderr の 2 行目以降が列 0 に
      # 着地して marker として読まれうる（ステップ 4 の dirty ファイル一覧と同じ data/marker 分離）。
      echo "WARNING: リモートブランチ {branch_name} の削除に失敗しました:" >&2
      echo "--- push stderr begin ---" >&2
      printf '%s\n' "$_push_err" | tr -d '\r' | sed 's/^/  /' >&2
      echo "--- push stderr end ---" >&2
    fi ;;
  2) echo "[CONTEXT] REMOTE_BRANCH_ALREADY_ABSENT=1; branch={branch_name}" ;;
  *)
    echo "[CONTEXT] REMOTE_BRANCH_CHECK_FAILED=1; branch={branch_name}; rc=${_ls_rc}${_check_reason:+; reason=${_check_reason}}" >&2
    # 多バイト文字に隣接する変数展開は必ず brace で閉じる。日本語文中で `$_ls_err。` と書くと
    # bash が `。` の先頭バイト (0xE3) を変数名に取り込み、非 UTF-8 ロケール (macOS CI 等) で
    # 変数が未定義化して原因テキストが消える。残った不正バイトは下流の BSD sed 等も落とす
    # （同 invariant: hooks/tests/flow-state.test.sh TC-8b-h、Issue #2008）。
    # 捕捉した stderr は文末に置く。ls-remote の stderr は空行を含む複数行が常態のため、文中に
    # 挿入すると operative な日本語（削除を試行していない旨）が英文パラグラフの末尾に孤立する。
    # 直上のローカル削除が $del_err を文末に置いているのと同じ配置。
    # 原因は ls-remote とは限らない（完全一致検証の異常終了も本分岐へ落ちる）ため、コマンドを
    # 名指しせず rc と reason で示す。
    echo "WARNING: リモートブランチ {branch_name} の存在確認に失敗したため削除を試行していません (rc=${_ls_rc}${_check_reason:+, ${_check_reason}}):" >&2
    echo "--- ls-remote stderr begin ---" >&2
    printf '%s\n' "${_ls_err}" | tr -d '\r' | sed 's/^/  /' >&2
    echo "--- ls-remote stderr end ---" >&2 ;;
esac
trap - EXIT INT TERM HUP
fi
fi ;;
esac
```

`BRANCH_DELETED=1; via=squash-merged`（PR が merged 済みで `git branch -d` が squash 残渣により拒否したケース）は通常削除と同様にステップ 12 で `x` に分岐する。`BRANCH_DELETE_UNMERGED=1`（未マージ PR の強制 cleanup で `{pr_merged}=false` のとき）は「強制削除 (`-D`) / スキップ」を確認する。**強制削除を選んだ場合**は `LC_ALL=C git branch -D {branch_name} && echo "[CONTEXT] BRANCH_DELETED=1; branch={branch_name}; via=force"` を実行し、削除完了を marker で示す（ステップ 12 が `x` に分岐する）。スキップ時は marker を追加しない（残置のまま）。`BRANCH_DELETE_DEFERRED=1`（作業ツリーが未削除のまま残り削除を遅延したケース — 別セッション使用中(#1670) または sandbox マスク skip(#1957)。原因は断定しない）のときは**強制削除しない**。marker の `recovery=` で次セッション回収の可否が決まる: `recovery=auto`（{pr_merged}=true、reap manifest の記録を verify 済み、かつ対象 worktree が reaper と同じ filtered dirty gate を通過）は worktree 解放後に `pr-cycle-cleanup.sh` Step 5 が自動回収する。`recovery=manual`（未マージ PR の強制 cleanup、記録漏れ、dirty または判定不能な worktree）は自動回収されない。実パスを解決できた場合は `BRANCH_DELETE_DEFERRED_WORKTREE` marker の shell-escaped `path_q=` を用いて status を確認し、変更を commit / stash / copy して clean にした後だけ、非 force の `git worktree remove` → prune → branch delete を実行する。解決不能時は `git worktree list --porcelain` で先に実パスを特定する。ステップ 12 はこの `recovery=` 値で残置メッセージを出し分ける。

リモート削除は **ブランチ名の事前検証 → 一時ファイル確保 → `git ls-remote --exit-code`（rc=128 なら 1 回リトライ、#2140）+ ref 名の完全一致検証** の順に進み、**どの経路も必ず marker を emit する**（marker 名は 4 種、emit 箇所は 8 — うち fail-fast 4 経路（空値 / marker デリミタ / refname 非合法 / 一時ファイル確保失敗）は `ls-remote` を実行しない。#2016）: 事前検証（空値 / marker デリミタ文字 / refname 非合法）に落ちた場合、一時ファイルを確保できなかった場合、ref 名の完全一致検証が異常終了した場合はいずれも削除を試行せず `REMOTE_BRANCH_CHECK_FAILED=1`（原因は marker の `rc=` と `reason=` で区別する）。`rc=0`（存在確認済み）は削除し、成功なら `REMOTE_BRANCH_DELETED=1`、失敗（protected branch / 権限不足 / race）なら `REMOTE_BRANCH_DELETE_FAILED=1` を emit する。`rc=2` は不在なので削除せず `REMOTE_BRANCH_ALREADY_ABSENT=1`、それ以外の非 0（リトライ後も 128 を含む）は存在有無が判定できないため削除を試行せず `REMOTE_BRANCH_CHECK_FAILED=1` を emit する。成功側も marker を出すのは、ステップ 12 が marker 不在を「削除成功」と読まないようにするため — 不在を成功の符号化に使うと、本ブロックが実行されなかった経路と削除成功が同一視され、`/rite:merge` の完了報告と同種の「実際には起きていないことを完了として報告する」嘘が判定表側から復活する。リポジトリ設定 `delete_branch_on_merge: true` の環境では merge 時にサーバサイドで head ブランチが削除されるため通常は `rc=2` に落ち、`/rite:merge` の `--delete-branch=false` はこれを抑止しない（`skills/merge/SKILL.md` の設計判断を参照）。`delete_branch_on_merge: false` のリポジトリでは従来どおり `rc=0` 経路で削除される。

---

## ステップ 6: PR-specific state ファイルを削除 <!-- AC-7 -->

マージ済み PR に紐づく state ファイルを削除する。**他 PR 誤削除防止のため glob は `{pr_number}-` prefix 固定**。

> **Acceptance Criteria anchor (AC-7)**: [review-result-schema.md](../../references/review-result-schema.md#クリーンアップ) と双方向リンク。

```bash
pr_number="{pr_number}"
case "$pr_number" in
  ''|*[!0-9]*)
    echo "ERROR: invalid pr_number: '$pr_number'" >&2
    echo "[CONTEXT] REVIEW_CLEANUP_PARTIAL_FAILURE=1; reason=invalid_pr_number" >&2
    exit 0 ;;
esac

# 削除対象はリポジトリ共通の state ルート基準 (state-path-resolve.sh)。書込側
# (review-result-save.sh / fix.md 2.1.A / fix.md 3.3.1) と同一解決のため、セッション worktree に
# 書かれて main checkout の削除が no-op になる不整合を防ぐ (解決失敗時は cwd fallback)
_state_root=$(bash {plugin_root}/hooks/state-path-resolve.sh 2>/dev/null) || _state_root=""
[ -n "$_state_root" ] || { echo "WARNING: state-path-resolve.sh の解決に失敗。cwd をフォールバック使用します" >&2; _state_root="$(pwd)"; }

rite_rm() {
  local label="$1"; shift
  local f
  for f in "$@"; do
    { [ -e "$f" ] || [ -L "$f" ]; } || continue
    if rm -f "$f"; then
      echo "✅ ${label} を削除: $f" >&2
    else
      echo "WARNING: ${label} 削除失敗 (PR #${pr_number}): $f" >&2
      echo "[CONTEXT] REVIEW_CLEANUP_PARTIAL_FAILURE=1; reason=${label}_rm_failure; pr=${pr_number}" >&2
    fi
  done
}

# レビュー結果 JSON は一律削除しない。**非実測指摘 (non_blocking_findings[]) を持つものは
# 削除せず archive/ へ退避する** — ステップ 6.1.d の PR 記録コメントはポインタ (reviewer /
# severity / file:line) しか載せないため (Issue #2039)、無条件削除すると非実測 CRITICAL の詳細が
# merge 直後にどこにも残らなくなり、Issue #2024 D-01「マージ後に人間が拾い直せる」が偽になる。
# 判定 (jq rc の値域分岐 / 判定不能は退避側へ倒す) と退避 (mkdir・mv の分離、同名衝突の検出) は
# helper へ委譲済み。契約と reason 語彙の SoT は helper docstring、挙動は
# hooks/tests/review-results-archive-or-rm.test.sh が behavioral に固定する。
# `.json.corrupt-*` も同 helper の glob (`{pr}-*.json*`) が拾う。corrupt は「中身を判定できない」
# 状態そのものなので、別経路で無条件削除すると同一ブロック内に「判定不能は保全」と「判定不能は
# 削除」の 2 ポリシーが並ぶ (corrupt rename の 3 経路のうち 2 つは構造的に valid な JSON で、
# non_blocking_findings[] の全文を保持しうる)。
#
# helper の rc は捨てない。**marker 不在を「削除成功」と読んではならない**という本ステップの規約
# (下記 ステップ 12 の判定表) は、helper が起動すらしなかった場合 ({plugin_root} の未解決置換 /
# helper 欠落で rc=127) に marker が 1 本も出ないことで破れる。rc を見て失敗を marker に変換する。
_rrar_rc=0
bash {plugin_root}/hooks/scripts/review-results-archive-or-rm.sh \
  --state-root "$_state_root" --pr "$pr_number" || _rrar_rc=$?
if [ "$_rrar_rc" -ne 0 ]; then
  echo "WARNING: review-results の退避/削除 helper が rc=${_rrar_rc} で失敗しました。レビュー結果 JSON は未処理のまま残っています" >&2
  echo "  原因候補: {plugin_root} の未解決置換 / helper 欠落・非可読 (rc=127) / 引数不正 (rc=1)" >&2
  echo "[CONTEXT] REVIEW_CLEANUP_PARTIAL_FAILURE=1; reason=review_results_helper_failed; pr=${pr_number}; rc=${_rrar_rc}" >&2
fi
rite_rm fix_retry_state "$_state_root/.rite/state/fix-fallback-retry-${pr_number}.count"
rite_rm fix_cycle_state "$_state_root/.rite/fix-cycle-state/${pr_number}.json"
rite_rm legacy_fix_cycle_state "$_state_root/.rite/fix-cycle-state.json"
rite_rm accepted_fingerprints "$_state_root/.rite/state/accepted-fingerprints-${pr_number}.txt"
rite_rm review_run_since "$_state_root/.rite/state/review-run-since-${pr_number}.txt"
```

`review-run-since-{pr}.txt` は `/rite:iterate` の収束トレンド判定が現 run の境界に使う pin (ステップ 0.6 が書き、ステップ 1 が `--since` で helper へ渡す)。直上で削除する `review-results/` と同じライフサイクルのため同列挙で掃除する。残しても次 run の開始時に上書きされるので害はないが、参照先が消えた孤児を PR ごとに積み上げない。

`.rite/wiki-worktree/` は永続 worktree のため削除しない (再作成コストが高く各 PR cycle を跨いで保持する)。手動削除が必要なら `git worktree remove .rite/wiki-worktree && git worktree prune`。

---

## ステップ 7: transient cycle ブランチを削除

Reviewer subagent が作る `pr-{N}-cycle{X}` 命名の transient ブランチを回収する (reviewer は READ-ONLY 制約で自己クリーン不可)。non-blocking:

```bash
bash {plugin_root}/hooks/scripts/pr-cycle-cleanup.sh 2>&1 || true
```

---

## ステップ 8: Projects Status を Done に更新

**Critical**: Do NOT skip this step. `rite-config.yml.github.projects.enabled: true` かつステップ 2 で関連 Issue が識別できている場合のみ実行し、結果を `projects_status_updated` (true/false) として context に保持してステップ 12 の表示で参照する（`{projects_enabled}` / `{project_number}` / `{owner}` / `{repo}` / `{issue_number}` はステップ 1.4 / 2 / Placeholder Legend で確定済みの値をそのまま使う）。無効化・Issue 未識別の場合はステップ 9 へ進む。

> **Source of truth**: `plugins/rite/scripts/projects-status-update.sh` に委譲する（`skills/open/SKILL.md` ステップ 2.4 / `skills/ready/SKILL.md` Phase 4 と共通）。過去に multi-stage inline pipeline で LLM の attention が sub-step 間で途切れ Status 更新が silent skip する事象が確認されている（`skills/ready/SKILL.md` Phase 4.2 と同一原因）ため、参照のみに留めず本ステップに直接 inline する。

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

> **委譲モード（#2133）**: 4-W が `[CONTEXT] CLEANUP_DELEGATED=1` を emit している場合、**本ステップ全体を実行しない**（config 読み取り bash・`WIKICHAIN` handoff の set・`Skill: rite:wiki-ingest` の invoke をいずれも行わない）。ガードの対象は config 読み取り bash 単体ではない — 実際に wiki-worktree へ commit するのは skill invoke であり、検出ブロックだけを skip すると `reason` が未計算のまま handoff set と invoke に到達しうる。pending raw source は wiki branch に保持されるため、ステップ 12 が未完了として列挙し、main checkout での `/rite:cleanup {pr_number}` 再実行へ委譲する（本項目は再実行で冪等に完了する）。

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

> **#1941 wiki push batch/defer**: ingest.md はページ更新のたびに push していた旧挙動を、raw source ごとに commit のみ行い ingest フロー末尾（ステップ 8.6）で 1 回だけ push する方式に変更した（AC-1）。`push=failed` 部分文字列検出はそのまま機能する — 集約 push が失敗した場合も、その 1 回の push 結果として ingest の stdout に同じ文字列が現れるため、本ステップの検出ロジック自体の変更は不要（ローカル commit は保持され、次回 ingest のステップ 8.6 が自動で flush を試みる — AC-2 / SHOULD）。

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
- **State reset セクション** (= `## Phase 4: Reset State and Delete Local Work Memory`): `cleanup-work-memory.sh` 実行による local `.rite-work-memory/issue-*.md` ファイル削除 + flow state `active: false` リセット

両方を実行しないと、Issue comment は最終化されるがローカル file は永続蓄積し `post-tool-wm-sync.sh` が次セッションで file を再生成する race 経路が開く。

あわせて Issue claim を解放する（`multi_session.enabled` に依らず常時実行。claim 取得は /rite:open Step 1.6）。`issue-claim.sh release` は flow-state を変更しないため、ステップ 9 の `WIKICHAIN:` handoff 契約（ステップ 9〜12 間で `flow-state.sh set` を挟まない）に抵触しない:

```bash
bash {plugin_root}/hooks/issue-claim.sh release --issue {issue_number} 2>&1 || echo "WARNING: issue-claim release が失敗しました（claim は stale 判定 + reap で回収されます）。" >&2
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
- [{review_cleanup_check}] PR-specific state ファイル削除
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

**委譲モード（#2133。4-W が `[CONTEXT] CLEANUP_DELEGATED=1` を emit した場合）**: **委譲した 4 項目に限り**下記の個別判定を行わず、`{base_update_check}` / `{session_worktree_check}` / `{local_branch_check}` / `{wiki_ingest_check}` を ` `（未完了）に固定し、それぞれの check 直下の付記も出力しない（委譲は 1 回の明確な案内に収め、診断の羅列に戻さない）。**委譲モードでも実行される項目**（`{review_cleanup_check}` = ステップ 6 / `{projects_check}` = ステップ 8 / 冒頭の `Status: {projects_status_result}`）は**従来どおり個別判定する** — 実行した項目の実失敗を握り潰さないため。`{outstanding_items_block}` は下記の定型ブロックを先頭に置き、個別判定で空欄になった check があればその付記を定型ブロックの後ろに続ける。`{n}` は **`4` + 個別判定で空欄になった check の件数**:

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
- `{session_worktree_check}`: multi_session 無効 or worktree 未使用なら行ごと省略。以下を**上から評価し最初に一致したもの**を採用する（`WORKTREE_REMOVE_SKIPPED_LIVE_CWD` / `WORKTREE_REMOVE_SKIPPED_SANDBOX_MASK` / `WORKTREE_REMOVE_FAILED` は Step 4-W guard の if/elif/else で排他だが、複数の `[CONTEXT]` 行が文脈に残る可能性に備えて評価順序を固定する）:
  - `WORKTREE_REMOVE_SKIPPED_LIVE_CWD=1` のとき（別のセッションが作業ツリーを使用中のため削除を見送った）: ` ` + 以下を付記
    ```
    ℹ️ この作業ツリーは別のセッションが使用中のため、削除を見送りました。そのセッションが終了したあと、次回のセッション開始時に作業ツリーとローカルブランチが自動で回収されます。
      すぐに消したい場合（別セッションを閉じたあと）: git worktree remove --force '{flow_wt}' && git worktree prune
    ```
  - `WORKTREE_REMOVE_SKIPPED_SANDBOX_MASK=1` のとき（sandbox のマスクマウント検知により削除を試行しなかった — Issue #1957）: ` ` + 以下を付記
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
  - `[CONTEXT] WORKTREE_REMOVE_*` のいずれの行も無い（削除成功）とき: `x`。**marker family でスコープすること** — 無条件の「いずれの `[CONTEXT]` 行も無いとき」はステップ 5 の `BRANCH_DELETED=1` 等が正常系でも必ず存在するため常に偽になり、本 check の判定オペランドが未定義になる（#2016）。ステップ 4-W は削除成功時に marker を出さないため、本 check に限り marker 不在は削除成功を意味してよい（ステップ 5 の全経路が marker を出す設計とは前提が異なる）
- `{local_branch_check}`: ステップ 5 の `[CONTEXT]` 行で判定する。本チェックはローカルとリモートの 2 つの削除を 1 行で表すため、**ローカル側判定とリモート側判定を独立に評価し、両方が `x` 相当のときだけ `x`** とする（どちらか一方でも未完了なら ` ` にし、未完了だった側の付記をすべて列挙する）。ローカル成功をリモート失敗より先に評価して `x` に丸めると、リモート側の残作業が silent に消える（#2016）。

  **marker 名は `[CONTEXT] ` prefix 込みで一致させる（部分文字列一致させない）**: リモート側 marker `REMOTE_BRANCH_DELETE_FAILED` はローカル側 marker `BRANCH_DELETE_FAILED` を部分文字列として含むため、非アンカーで照合すると `[CONTEXT] REMOTE_BRANCH_DELETE_FAILED=1` の行にローカル側ルールが先に一致し、リモートの残渣に対してローカル削除コマンドを案内する誤処方になる（#2016）。`[CONTEXT] ` の直後から一致させれば `REMOTE_` が間に入るため衝突しない。本規約は `{base_update_check}` の `[CONTEXT] BASE_UPDATE=` 行 と同形で、今後 `REMOTE_` 系の marker を追加しても同じ衝突を構造的に防ぐ。

  **さらに marker は `branch={branch_name}` までスコープして照合する**: `/rite:batch-run --merge` は同一セッション内で Issue ごとに `/rite:cleanup` をループ invoke するため、先行 Issue が残した `[CONTEXT] REMOTE_BRANCH_CHECK_FAILED=1; branch=A` 等が後続 Issue の判定時にも文脈へ残る。marker 名までしか一致条件に含めないと、リモート側は失敗ルールを先頭に評価する設計上、**stale な失敗が自分の成功 marker を必ず上書きする**（既削除の B に対して「削除に失敗しました。手動削除してください」と処方し、実行すれば本 Issue が消したはずの `error:` が再び出る）。評価順序の入れ替えは解にならない — 成功を先頭にすると今度は stale な成功が実失敗を握り潰し、本 Issue が塞いだ false-success そのものになる。ステップ 5 は各 marker に `; branch={branch_name}` を付けて emit している（ブランチ名が契約を満たせない fail-fast 経路のみ、実ブランチ名を載せず sentinel `branch=<unsupported branch name>` を出してどのルールにも一致させず fallback へ倒す）ので、照合側でスコープすれば **Issue 間の**衝突は消える（#2016）。**`branch=` の値は直後が `;` または行末であることまで含めて一致させる** — 前方一致だけだと `branch=fix/issue-1-a` が `branch=fix/issue-1-a-v2` の行にも一致し、左端で塞いだのと同型の包含衝突が右端に残る。ただし `branch=` は**同一ブランチに対する cleanup 再実行**を識別できない（1 回目がネットワーク断で `CHECK_FAILED` を残し、原因解消後の 2 回目が `ALREADY_ABSENT` を出す場合、両者の `branch=` は一致する）。そのため **同一 marker family で複数行が一致したときは最後の出現を採用する**（recency）。この選択は**各側の判定ルールを評価する前**に行う（下記の 2 段手順を参照）。これがないと失敗ルール先頭評価の設計上、前回実行の失敗が今回の成功を決定的に上書きし、既削除ブランチに「削除に失敗しました。手動削除してください」と誤処方する — AC-4 が禁じた症状そのものになる。recency はローカル側・リモート側の両判定に適用する。

  **さらに prefix は行頭から一致させ、デリミタ内は data として無視する**: ステップ 5 は `$_ls_err` / `$_push_err` に退避した git の stderr を WARNING に載せるため、marker と同じ出力ストリームに**外部由来の複数行テキスト**が流れる。行頭一致だけでは足りない — 複数行テキストの 2 行目以降は列 0 に着地するため、その中の `[CONTEXT] ` 行は行頭一致を突破する。そこでステップ 5 は退避 stderr を `--- {source} stderr begin ---` / `--- {source} stderr end ---` で囲んで出力する（ステップ 4 の dirty ファイル一覧が `--- dirty files begin/end ---` で data と marker を分離しているのと同形）。**照合側は `--- ... begin ---` と `--- ... end ---` に挟まれた区間を、`{source}` が何であれ一律 data として扱い、marker として解釈しない**（現在の退避サイトは branch delete / push / ls-remote の 3 箇所だが、照合規約はサイト列挙ではなくこの形で定義する — サイトを増やすたびに列挙更新を忘れて契約とコードが drift するのを構造的に防ぐ）。**退避テキストの各行は 2 スペースでインデントして出力する** — デリミタは可読性の補助であり、data 自身が終端行を騙る経路を塞ぐ security boundary はインデント（列 0 に到達しないこと）の側にある。照合側は**列 0 から始まる行だけを marker 候補とする**。以下のルールで「行があるとき」「行がいずれも無いとき」と書いた判定は、**肯定・否定とも行頭一致**で行う（fallback を非アンカーで判定すると先行ルールの否定にならず、行中に marker 断片が現れた入力でどのルールにも一致しない未定義状態が生じる）。

  **ローカル側**（**2 段で判定する**: まず `[CONTEXT] ` 行頭一致 + marker family + `branch={branch_name}` に該当する行を集め、**その中の最後の出現 1 行だけを対象に選ぶ**。次にその 1 行に対して以下のルールを上から評価し最初に一致したものを採用する。段の順序を入れ替えてはならない — ルールを先に評価すると、蓄積した stale marker のうち上位ルールに当たるものが最新の行より先に一致し、recency が働かない）:
  - `[CONTEXT] BRANCH_DELETE_DEFERRED=1; branch={branch_name}` 行があるとき（作業ツリーが未削除のまま残っていて削除を見送った — 別セッション使用中（#1670）または sandbox マスク skip（#1957）。原因は断定しない）。**marker の `recovery=` フィールドで文面を出し分ける**（記録できていない経路で「自動回収」と偽らないため — AC-6）: ` ` + 以下を付記
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
  - `[CONTEXT] BRANCH_DELETED` / `[CONTEXT] BRANCH_DELETE_*` / `[CONTEXT] BRANCH_ALREADY_ABSENT` / `[CONTEXT] BRANCH_CHECK_FAILED` かつ `branch={branch_name}` の行がいずれも無いとき: ` ` + 「ローカルブランチ {branch_name} の削除結果を確認できませんでした。`git branch --list {branch_name}` で確認し、残っていれば `git branch -D {branch_name}` で手動削除」を付記。**marker 不在を「削除成功」と読んではならない**（#2016） — ステップ 5 はローカル側 6 marker（`BRANCH_ALREADY_ABSENT` / `BRANCH_DELETED` / `BRANCH_DELETE_DEFERRED` / `BRANCH_DELETE_UNMERGED` / `BRANCH_DELETE_FAILED` / `BRANCH_CHECK_FAILED`）のいずれかを必ず emit するため、不在が意味するのは削除成功ではなく「ステップ 5 の bash block が実行されなかった」「出力が compact で失われた」等の**実行結果を確認できていない状態**である。リモート側 fallback と同一の到達条件・同一の意味に揃える（片側だけ `x` に倒すと、同じ条件に正反対の意味を割り当てる矛盾になる）。**marker family でスコープすること** — 無条件の「いずれの `[CONTEXT]` 行も無いとき」はリモート側 marker の存在で偽になり判定が破綻する

  **リモート側**（**2 段で判定する**: まず `[CONTEXT] ` 行頭一致 + marker family + `branch={branch_name}` に該当する行を集め、**その中の最後の出現 1 行だけを対象に選ぶ**。次にその 1 行に対して以下のルールを上から評価し最初に一致したものを採用する。段の順序を入れ替えてはならない — ルールを先に評価すると、蓄積した stale marker のうち上位ルールに当たるものが最新の行より先に一致し、recency が働かない。#2016）:
  - `[CONTEXT] REMOTE_BRANCH_DELETE_FAILED=1; branch={branch_name}` 行があるとき（`rc=0` 経路で `git push origin --delete` を実行したが失敗した — protected branch / 権限不足 / race。リモートブランチは残存している）: ` ` + 「リモートブランチ {branch_name} の削除に失敗しました。`git push origin --delete "refs/heads/{branch_name}"` で手動削除」を付記
  - `[CONTEXT] REMOTE_BRANCH_CHECK_FAILED=1; branch={branch_name}` 行があるとき（`git ls-remote` が rc=0/2 以外で失敗した、またはブランチ名の事前検証・一時ファイル確保・ref 名の完全一致検証のいずれかが失敗して存在確認自体を完了できなかったため、削除を試行していない）: ` ` + 「リモートブランチ {branch_name} の存在確認に失敗したため削除を試行していません。`git ls-remote --exit-code --heads origin "refs/heads/{branch_name}"` で確認し、残っていれば `git push origin --delete "refs/heads/{branch_name}"` で手動削除」を付記（案内する確認コマンドにも `--exit-code` を付ける — 本 Issue が「ガードとして機能しない」と特定した `--heads` 単体の形をユーザーに処方すると、同じ誤判定を再生産する）
  - `[CONTEXT] REMOTE_BRANCH_ALREADY_ABSENT=1; branch={branch_name}` 行があるとき（`delete_branch_on_merge: true` によるサーバサイド auto-delete などで既に不在。**正常系であり残作業ではない** — AC-4）: `x`
  - `[CONTEXT] REMOTE_BRANCH_DELETED=1; branch={branch_name}` 行があるとき（`rc=0` 経路で `git push origin --delete` を実行し成功した = 通常削除。`delete_branch_on_merge: false` のリポジトリの正常系）: `x`
  - `[CONTEXT] REMOTE_BRANCH_*` かつ `branch={branch_name}` の行がいずれも無いとき: ` ` + 「リモートブランチ {branch_name} の削除結果を確認できませんでした。`git ls-remote --exit-code --heads origin "refs/heads/{branch_name}"` で確認し、残っていれば `git push origin --delete "refs/heads/{branch_name}"` で手動削除」を付記。**marker 不在を「削除成功」と読んではならない**（#2016） — ステップ 5 はリモート側 4 marker（`REMOTE_BRANCH_DELETED` / `REMOTE_BRANCH_DELETE_FAILED` / `REMOTE_BRANCH_ALREADY_ABSENT` / `REMOTE_BRANCH_CHECK_FAILED`）のいずれかを必ず emit するため、不在が意味するのは削除成功ではなく「ステップ 5 の bash block が実行されなかった」「出力が compact で失われた」等の**実行結果を確認できていない状態**である。ここを `x` に倒すと、`{base_update_check}` が marker 不在を「実行結果が確認できませんでした」として扱う規約と正反対になり、同 Issue が塞いだ false-success を判定表側から復活させる。**marker family でスコープすること** — 無条件の「いずれの `[CONTEXT]` 行も無いとき」は正常系でもローカル側の `BRANCH_DELETED=1` が必ず存在するため常に偽になり、リモート側の判定オペランドが未定義になる
- `{projects_status_result}` / `{projects_check}`: 以下を**上から評価し最初に一致したもの**を採用する（`{wiki_ingest_check}` の legitimate-skip 区別パターンと統一。ステップ8 は `projects_enabled=false` または Issue 未識別のとき丸ごと skip され `[CONTEXT] PROJECTS_STATUS_UPDATED=` を emit しないため、この legitimate skip と本物の更新失敗を区別する）:
  - `{projects_enabled}`（Placeholder Legend の定義、`rite-config.yml` → `github.projects.enabled`）が `false` のとき: `{projects_status_result}` = `（Projects 連携無効）`、`{projects_check}` = `x`（警告ではなく informational — Wiki ingest の `reason=disabled` と同型）
  - ステップ 2 で関連 Issue が識別できなかった（`{issue_number}` 空）とき: `{projects_status_result}` = `（関連 Issue 未識別のためスキップ）`、`{projects_check}` = `x`
  - 上記 2 条件のいずれにも該当せず `[CONTEXT] PROJECTS_STATUS_UPDATED=true` が見つかったとき: `{projects_status_result}` = `Done`、`{projects_check}` = `x`
  - 上記 2 条件のいずれにも該当せず `[CONTEXT] PROJECTS_STATUS_UPDATED=false` または sentinel 自体が見つからない（= ステップ8 が実行されるべきだったのに失敗/skip された）とき: `{projects_status_result}` = `⚠️ 更新失敗（手動確認が必要）`、`{projects_check}` = ` ` + 「GitHub Projects 画面で Issue #{issue_number} の Status を Done に変更」を付記
- `{review_cleanup_check}`: `REVIEW_CLEANUP_PARTIAL_FAILURE=1` の marker を**上から評価し最初の一致**を採用する（`{wiki_ingest_check}` と同じく各行は presence 検査。marker が 1 本も無ければ `x`）。**照合は `pr={pr_number}` まで含める** — `/rite:batch-run --merge` は同一セッションで Issue ごとに `/rite:cleanup` を invoke するため、先行 Issue の marker が文脈に残る（`{local_branch_check}` が `branch=` でスコープするのと同じ理由。`invalid_pr_number` だけは `pr=` を持たないので marker 名のみで照合する）:

  | 検出 | check | 表示 |
  |---|---|---|
  | `reason=invalid_pr_number`、または `reason=` が `_rm_failure` / `_archive_mkdir_failure` / `_archive_mv_failure` / `_archive_name_collision` / `_gitignore_failure` / `_helper_failed` のいずれかで終わる marker がある | ` ` | 警告付記 |
  | `reason=review_results_undecidable; cause=jq_missing` がある | ` ` | `⚠️ jq が見つからず全レビュー結果 JSON を無判定で archive/ へ退避しました。jq を導入してください` |
  | `reason=review_results_undecidable` がある（`cause=jq_rc_<n>`） | `x` | `ℹ️ 一部のレビュー結果 JSON は中身を判定できず削除せず archive/ へ退避しました (本 cycle での対応は不要)` |

  行を presence 検査にしてあるので「上から評価し最初の一致」が実際に効く（実失敗と判定不能が同一 run で共起しても 1 行目が先に一致する）。`_gitignore_failure` は `cause=jq_rc_<n>` と同じく summary の `failed` には数えられない（ファイル自体は処理済み）が、1 行目の実失敗側に置く — 除外の欠落は退避した全文が `git add -A` で公開リポジトリへ入る経路そのもので、放置してよい informational ではない。`cause=jq_rc_<n>` を `x` に倒すのは、helper がこれを「退避自体は成功しうるので `failed` には数えない」と定義し summary も `failed=0` を返すため。`.corrupt-*` を「判定不能 → 退避」経路へ載せた以上 corrupt を持つ PR は毎回この reason を出すので、失敗扱いのままだと存在しない手動対応を促し続ける。一方 `cause=jq_missing` は環境不備で、放置すると本来削除されるべき JSON まで無判定で退避され続けるため実失敗側に置く。
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

  push 失敗警告 (`{wiki_branch}` はステップ 9 で解決済):
  ```
  ⚠️ Wiki ingest: commit は local wiki branch に landed しましたが origin への push に失敗しました。
    手動回復: git -C .rite/wiki-worktree push origin {wiki_branch}
  ```

`{outstanding_items_block}`（Issue #1946: 非ブロッキング失敗の集約 surface）: 上記チェックリストの `{base_update_check}` / `{session_worktree_check}` / `{local_branch_check}` / `{projects_check}` / `{wiki_ingest_check}` / `{review_cleanup_check}` のうち、**チェックボックスが `x` ではなく空欄（未チェック）として描画されたもの**があれば、そのチェックボックス直下の付記文をそのまま箇条書きで列挙する（各チェックボックス直下の付記と同じ文言をここにも重複表示する — チェックリストは一覧性、本節は見落とし防止のための集約であり、両立させる。AC-1 / AC-2）。

判定基準を「⚠️/ℹ️ 等の絵文字 prefix 一致」ではなく「チェックボックスの空欄/`x`」に統一する: 6 check の判定ルール（上記）はいずれも「実失敗・残作業のときのみ空欄 ` ` を割り当て、成功時および legitimate な informational skip（`{wiki_ingest_check}` の `reason=disabled`/`auto_ingest_off`/`no_pending`/`concurrent_ingest` 等）は `x` を割り当てる」という契約を既に持つ。付記文の絵文字 prefix は表示上の飾りに過ぎず（`{local_branch_check}` の `BRANCH_DELETE_FAILED`/`BRANCH_DELETE_UNMERGED` のように prefix を伴わない実失敗付記も存在する）、チェックボックス自体の空欄/`x`こそが「未完了か否か」の一次情報である。この統一により、prefix の有無に関わらず全 check の実失敗・残作業を漏れなく拾い、かつ legitimate skip（`x` 判定）は自然に除外される（追加の除外ルールは不要）。

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

> **Why `returned-to-caller` (not `completed`)**: 旧 `cleanup:completed` 形式は literal `completed` が LLM の turn-boundary heuristic と衝突し、cleanup → wiki-ingest → wiki-lint のネストで lint 直後に turn が暗黙終了する事象が複数回再発した。`returned-to-caller` で terminal vocabulary を構造的に排除する。

最後に flow state を terminal state に落とす:

```bash
bash {plugin_root}/hooks/flow-state.sh set --phase "cleanup" --next "none" --active false --if-exists \
  || echo "WARNING: flow-state deactivate failed — .active=true が残る可能性。" >&2
```

この set は `--handoff` を持たないため、ステップ 9 でセットした `WIKICHAIN:cleanup:{pr_number}` handoff を default-clear する (チェーン完走 = gate 解除)。チェーン途中で turn が閉じた場合のみ Stop hook が handoff を consume して継続を差し戻す。

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
