---
name: open
description: |
  rite workflow の Issue→draft PR ステップ: 指定 Issue を起点に準備→ブランチ→計画→実装→
  lint→draft PR まで一気通貫で実行する。/rite:batch-run・/rite:cleanup から呼ばれる sub-step、
  または手動 /rite:open <issue>。汎用の「Issue に着手」ヘルパーではなく、その語では auto-activate しない。
  起動: /rite:open <issue_number>
argument-hint: "<issue_number>"
---

# /rite:open

## Contract

**Input**: Issue number (required)
**Output**: 完了通知（draft PR の番号と URL）

Issue を起点に「準備 → ブランチ → 計画 → 実装 → lint → PR」までを一気通貫で実行する。レビュー/修正は `/rite:iterate`、Ready 化は `/rite:ready`、マージは `/rite:merge` で実施する。

**途中で止まったら**: `/rite:recover` が flow-state ファイル (`.rite/sessions/{session_id}.flow-state`) の phase から復帰する。本コマンドの Step 0 が Resume Dispatch を担う。

## E2E Output Minimization

**環境起因の迂回・リトライの出力姿勢**: [common-error-handling.md#environment-workaround-output-posture](../../references/common-error-handling.md#environment-workaround-output-posture) — 成功時は無言、失敗時は行動可能な 1 行のみ（規則本文はそちら。本スキルは複製しない）。

## Arguments

| Argument | Description |
|----------|-------------|
| `<issue_number>` | Issue number to start working on (required) |

## Placeholder Legend

| Placeholder | Source |
|-------------|--------|
| `{issue_number}` | 引数 |
| `{base_branch}` | `branch.base` in `rite-config.yml`（default: `main`） |
| `{branch_name}` | ステップ 2 で生成 |
| `{pr_number}` | ステップ 6 の `[pr:created:N]` から抽出 |
| `{plugin_root}` | [Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script-full-version) |
| `{owner}` / `{repo}` | ステップ 2.4(A) 専用: `{plugin_root}/hooks/scripts/lib/git-remote.sh resolve-owner-repo`（SSH host alias 対応。fallback: `gh repo view --json owner,name`。canonical: [gh-cli-patterns.md](../../references/gh-cli-patterns.md#ownerrepo-resolution-ssh-host-alias-safe)） |
| `{owner_repo}` | [Owner/Repo Resolution](../../references/gh-cli-patterns.md#ownerrepo-resolution-ssh-host-alias-safe) で解決した owner/repo（slash 形式）を literal substitute |
| `{project_number}` | ステップ 2.4(A) 専用: `rite-config.yml` → `github.projects.project_number` |

> **Note**: 「ステップ 2.4(A) 専用」と注記した 2 行を除き、`{owner}` / `{repo}` / `{project_number}` / `{parent_issue_number}` は本コマンド body で substitute しない — 下流 sub-skill が `rite-config.yml` / `gh` から個別に取得する。

---

## ステップ 0: Resume Dispatch（`/rite:recover` から呼ばれた場合のジャンプ）

セッション開始時に flow-state を読み、再開かどうかを判定する。新規セッション (state file 不在 or `active=false` or `issue_number` 不一致) の場合は何もせずステップ 1 に進む:

```bash
resume_phase=$(bash {plugin_root}/hooks/flow-state.sh get --field phase --default "") || resume_phase=""
resume_issue=$(bash {plugin_root}/hooks/flow-state.sh get --field issue_number --default "") || resume_issue=""
resume_active=$(bash {plugin_root}/hooks/flow-state.sh get --field active --default "") || resume_active=""
resume_pr=$(bash {plugin_root}/hooks/flow-state.sh get --field pr_number --default "0") || resume_pr="0"

if [ -n "$resume_phase" ] && [ "$resume_active" = "true" ] && [ "$resume_issue" = "{issue_number}" ]; then
  echo "[CONTEXT] RESUME_DISPATCH=1; phase=$resume_phase; issue=$resume_issue; pr=$resume_pr"
else
  echo "[CONTEXT] RESUME_DISPATCH=0; reason=fresh_or_mismatched_session (phase='$resume_phase' active='$resume_active' issue='$resume_issue' arg='{issue_number}')"
fi
```

stderr は `2>/dev/null` で握りつぶさない。rationale: references/rationale.md#defensive-fallback

**LLM routing rule**: `[CONTEXT] RESUME_DISPATCH=` marker を会話コンテキストから読む（Bash shell state は次の呼び出しでリセットされる）。本表は本コマンド内部の Step jump 用で、外部スキルへの routing 全体は [skills/recover/SKILL.md](../recover/SKILL.md) Phase 5.3 が SoT:

| `RESUME_DISPATCH` value + `phase` | LLM action |
|---|---|
| `0` | 新規セッション or 別 Issue。ステップ 1 から通常開始 |
| `1` + `phase=init` | ステップ 1 (準備) から再実行 (idempotent) |
| `1` + `phase=branch` | ステップ 2 (ブランチ作成) から再開。既存ブランチがあれば `git switch` で復帰 |
| `1` + `phase=plan` | ステップ 3 (実装計画) から再開。既存の Issue body 実装ステップを再読込 |
| `1` + `phase=implement` | ステップ 4 (実装) を継続。`/rite:issue-implement` の checklist 未完項目から続行 (autonomous lint まで進む内蔵動作あり) |
| `1` + `phase=lint` | ステップ 5 (Step 4 内 autonomous lint の sentinel 検証) から再開。implement が既に lint まで完了している場合は sentinel を context から読み Step 6 へ |
| `1` + `phase=pr` | ステップ 6 (PR 作成) から再開。既存 draft PR があれば検出して `[pr:created:N]` 相当を再構成 |
| `1` + `phase=review` / `fix` | 本コマンドは扱わない。ユーザーに `/rite:iterate <pr={resume_pr}>` を案内 (PR 番号は `[CONTEXT] RESUME_DISPATCH=...; pr=$resume_pr` marker から literal substitute) |
| `1` + `phase=ready` / `ready_error` | 本コマンドは扱わない。`/rite:ready <pr={resume_pr}>` を案内 |
| `1` + `phase=cleanup` / `ingest` / `completed` | 既に PR 段階を超えている。ユーザーに状態を案内して `/rite:cleanup <pr={resume_pr}>` 等を提案 |

`active=false` または `issue_number` が引数と異なる場合は別 Issue の state なので新規セッション扱い (ステップ 1 から開始)。

### 0.5 Worktree Re-entry（multi_session 有効時の Resume Dispatch）

`RESUME_DISPATCH=1` かつ flow-state に `worktree` がある場合、復帰先ステップへジャンプする**前に**そのセッション worktree へ再入場する（Bash 呼び出しと EnterWorktree の cwd を一致させる）:

```bash
resume_wt=$(bash {plugin_root}/hooks/flow-state.sh get --field worktree --default "") || resume_wt=""
cur_top=$(git rev-parse --show-toplevel 2>/dev/null) || cur_top=""
echo "[CONTEXT] WORKTREE_REENTRY=$([ -n "$resume_wt" ] && [ "$resume_wt" != "$cur_top" ] && echo needed || echo none); worktree=$resume_wt"
```

- `needed` → `EnterWorktree` を `path: {worktree}` で呼び、その後ステップ 0 の routing 表で決まった復帰先へジャンプする。
- `none` → そのまま復帰先へ。
- `EnterWorktree` 失敗（worktree 消失等）→ 新規 worktree は作らず `/rite:recover {issue_number}` を案内する（再構築は recover.md Phase 3.1.5 の責務）。

`MULTI_SESSION_ENABLED=false` または `worktree` 不在なら no-op。

---

## ステップ 1: 準備（Issue 取得・親判定・品質評価）

### 1.1 Issue 情報取得

```bash
gh issue view {issue_number} -R {owner_repo} --json number,title,body,state,labels,milestone,projectItems
```

State が `closed` の場合は AskUserQuestion で「再オープンして作業 / 中止」を選択。

### 1.2 親 Issue 検出

以下のいずれかに該当すれば親 Issue として扱う:

1. `trackedIssues.nodes` が空でない（GraphQL）
2. Body に `- [ ] #NN` 形式のタスクリストがある
3. ラベルに `epic` / `parent` / `umbrella` のいずれか

親 Issue の場合は AskUserQuestion で「子 Issue を選んで作業 / この親 Issue 自体に対して作業 / 中止」を提示。子 Issue 選択時は trackedIssues から open かつ未着手のものを priority + complexity 順で並べて 1 件選択させ、選択後は `{issue_number}` を子の番号に置換してステップ 1.1 から再実行する。

### 1.3 Issue 品質評価

What / Why / Where / Scope の充足度で A-D 評価。C/D の場合は AskUserQuestion で「既存情報で開始 / Issue を編集してから再実行 / 中止」を選択。

### 1.4 設定読込 (language / multi_session)

`rite-config.yml` の `language` field を取得し `[CONTEXT] WORKFLOW_LANGUAGE=` marker として emit。ステップ 4 の commit message テンプレで参照される。

あわせて `multi_session` を読み、ステップ 2.2-W / 2.3-W の分岐判定に使う marker を emit する:

```bash
ms_section=$(sed -n '/^multi_session:/,/^[a-zA-Z]/p' rite-config.yml 2>/dev/null) || ms_section=""
ms_enabled=$(printf '%s\n' "$ms_section" | awk '/^[[:space:]]+enabled:/ {print; exit}' \
  | sed 's/[[:space:]]#.*//' | sed 's/.*enabled:[[:space:]]*//' | tr -d '[:space:]"'"'"'' | tr '[:upper:]' '[:lower:]')
case "$ms_enabled" in true|yes|1) ms_enabled=true ;; *) ms_enabled=false ;; esac
ms_base=$(printf '%s\n' "$ms_section" | awk '/^[[:space:]]+worktree_base:/ {print; exit}' \
  | sed 's/[[:space:]]#.*//' | sed 's/.*worktree_base:[[:space:]]*//' | tr -d '[:space:]"'"'"'')
[ -n "$ms_base" ] || ms_base=".rite/worktrees"
echo "[CONTEXT] MULTI_SESSION_ENABLED=$ms_enabled; WORKTREE_BASE=$ms_base"
```

`multi_session:` キー欠落時に `false` へ倒すのは既存プロジェクトの後方互換のため（デフォルト ON が効くのは新規 `/rite:setup` 生成時のみ）。分岐そのものはステップ 2.1-G が再確定した値で行う。

### 1.5 Iteration 自動 assign

`iteration.enabled: true` かつ `iteration.auto_assign: true` の場合、現在の active iteration を取得して Issue を assign する。手順: Projects の Iteration フィールド (`iteration.field_name`、既定 `Sprint`) の `configuration.iterations` を取得し、`startDate <= today < startDate + duration` を満たす iteration を「現在」とみなす。該当 iteration の `id` を `updateProjectV2ItemFieldValue` mutation で対象 Issue の Iteration フィールドに設定する。該当なしの場合は assign をスキップする。

### 1.6 flow-state 初期化 + Issue claim 取得

```bash
bash {plugin_root}/hooks/flow-state.sh set \
  --phase init --issue {issue_number} --branch "" --pr 0 \
  --next "ブランチ作成へ進む"
```

続けて Issue claim を取得する（branch / worktree 作成の前の fail-fast。`multi_session.enabled` に依らず常時有効）:

```bash
claim_out=$(bash {plugin_root}/hooks/issue-claim.sh claim --issue {issue_number} 2>&1); claim_rc=$?
echo "[CONTEXT] ISSUE_CLAIM=$claim_out; rc=$claim_rc"
```

- `rc=0`（`claimed` / `own` / stale 奪取）→ ステップ 2 へ。
- `rc=10`（`other` = 他の live セッションが作業中）→ **AskUserQuestion**（無人での奪取はしない）。「中止（推奨）」= 終了。「強制取得して続行」= 衝突リスクを表示し、`issue-claim.sh claim --issue {issue_number}` の**再実行ではなく**、ユーザーが当該セッションを停止済みであることを確認してから続行する（最終ガードはステップ 2.2-W の branch 衝突検出）。
- その他の非 0 rc（環境エラー）→ stderr を表示して中止する。

---

## ステップ 2: ブランチと Projects

### 2.1 ブランチ名生成

`rite-config.yml` の `branch.pattern`（default: `{type}/issue-{number}-{slug}`）に従う。

- **type**: labels / title から推定（`bug`/`bugfix` → `fix`、`docs` → `docs`、`refactor` → `refactor`、`chore`/`maintenance` → `chore`、それ以外 → `feat`）
- **slug**: Issue title を kebab-case 化 (英数字 + ハイフン、50 文字上限)

### 2.1-G ブランチ作成前の multi_session hard 再確定（marker 非依存ゲート）

ブランチ作成へ分岐する**前に**、`multi_session` 状態を rite-config.yml から Bash で再取得する（記憶・context 残存に頼らない）。パースはステップ 1.4 と同一。rationale: references/rationale.md#branch-gate

```bash
ms_section=$(sed -n '/^multi_session:/,/^[a-zA-Z]/p' rite-config.yml 2>/dev/null) || ms_section=""
ms_enabled=$(printf '%s\n' "$ms_section" | awk '/^[[:space:]]+enabled:/ {print; exit}' \
  | sed 's/[[:space:]]#.*//' | sed 's/.*enabled:[[:space:]]*//' | tr -d '[:space:]"'"'"'' | tr '[:upper:]' '[:lower:]')
case "$ms_enabled" in true|yes|1) ms_enabled=true ;; *) ms_enabled=false ;; esac
ms_base=$(printf '%s\n' "$ms_section" | awk '/^[[:space:]]+worktree_base:/ {print; exit}' \
  | sed 's/[[:space:]]#.*//' | sed 's/.*worktree_base:[[:space:]]*//' | tr -d '[:space:]"'"'"'')
[ -n "$ms_base" ] || ms_base=".rite/worktrees"
echo "[CONTEXT] MULTI_SESSION_ENABLED=$ms_enabled; WORKTREE_BASE=$ms_base; SOURCE=branch-gate"
```

`SOURCE=branch-gate` の marker が最新の真実であり、分岐は必ずこの値で行う:

| 本ゲートの `MULTI_SESSION_ENABLED` | 経路 |
|---|---|
| `true`（新規プロジェクトのデフォルト） | **2.2-W / 2.3-W**（セッション worktree）を実行し、従来の 2.2 / 2.3 は **置換**してスキップする |
| `false`（`enabled: false` 明示設定 / `multi_session:` ブロック欠落の旧 config） | **2.2 / 2.3**（従来動作、単一セッション時と完全一致）を実行する |

**hard invariant**: 本ゲートを経ずにブランチ作成段へ到達した場合は `git switch -c`（2.3）を実行せず本ゲートへ戻る。`true` のとき 2.2-W/2.3-W 以外でブランチを checkout してはならない。

### 2.2 既存ブランチチェック（multi_session 無効時）

`git rev-parse --verify {branch_name}` で既存確認。存在する場合は `git switch {branch_name}` で復帰、なければ次へ。

### 2.3 ブランチ作成（multi_session 無効時）

> **Hard gate**: 2.1-G で再確定した `MULTI_SESSION_ENABLED=false` のときのみ実行する。`true` のときは実行禁止（cwd を main checkout に置いたままブランチを切るため）— 2.2-W へ戻る。rationale: references/rationale.md#branch-gate

```bash
# GUARD (#1595): multi_session 有効時に本経路へ来てはならない。
# 2.1-G で false を再確定済の場合のみ実行する（true なら 2.2-W/2.3-W が正路）。
git switch {base_branch} && git fetch origin {base_branch} && git merge --ff-only origin/{base_branch} && git switch -c {branch_name}
```

### 2.2-W セッション worktree の冪等準備（multi_session 有効時、2.2/2.3 を置換）

worktree path は `{repo_root}/{worktree_base}/issue-{issue_number}`（`{worktree_base}` は 2.1-G の `WORKTREE_BASE` marker 値）。base ref は **`origin/{base_branch}` を直接指定**する — checkout 中の branch は fetch で更新できないため local を経由しない:

```bash
worktree_base="{worktree_base}"
wt_rel="$worktree_base/issue-{issue_number}"
repo_root=$(git rev-parse --show-toplevel)
wt_path="$repo_root/$wt_rel"
branch="{branch_name}"
base="{base_branch}"

# dirty main checkout 検出: worktree は origin/{base} 起点で作られ、未commit変更を継承しないため、
# main checkout の未コミット変更は構造的に引き継がれない。作業対象と重なる変更が警告なく
# worktree から欠落するのを防ぐ (git status 失敗時はガード skip = 従来挙動で続行)
if _dirty_files=$(git -C "$repo_root" status --porcelain 2>/dev/null); then
  if [ -n "$_dirty_files" ]; then
    echo "[CONTEXT] MAIN_DIRTY=yes"
    echo "[CONTEXT] MAIN_CHECKOUT_ROOT=$repo_root"
    # dirty 一覧は marker と区別できるようデリミタで囲んで表示する (ファイル名由来の偽 marker 混入防止)
    echo "--- dirty files begin ---"
    printf '%s\n' "$_dirty_files"
    echo "--- dirty files end ---"
  else
    echo "[CONTEXT] MAIN_DIRTY=no"
  fi
else
  echo "WARNING: git status の実行に失敗したため dirty main checkout ガードを skip します (従来挙動で続行)" >&2
  echo "[CONTEXT] MAIN_DIRTY=unknown"
fi

# ref lock 競合対策の 3 回リトライ (references/git-worktree-patterns.md 参照)
n=0; until git fetch origin "$base" 2>/dev/null; do n=$((n+1)); [ "$n" -ge 3 ] && break; sleep 1; done

# 冪等 5 ケースを判定して [CONTEXT] marker で LLM に分岐させる
wt_registered=$(git worktree list --porcelain | awk -v p="$wt_path" '$1=="worktree" && $2==p {print "yes"}')
branch_exists=$(git rev-parse --verify "$branch" >/dev/null 2>&1 && echo yes || echo no)
branch_wt=$(git worktree list --porcelain | awk -v b="refs/heads/$branch" '
  $1=="worktree"{wt=$2} $1=="branch" && $2==b {print wt}')

if [ "$wt_registered" = "yes" ] && [ "$branch_wt" = "$wt_path" ]; then
  echo "[CONTEXT] WT_CASE=reuse; path=$wt_path"
elif [ -e "$wt_path" ] && [ "$wt_registered" != "yes" ]; then
  git worktree prune
  if [ -e "$wt_path" ]; then echo "[CONTEXT] WT_CASE=stale_residue; path=$wt_path"; else echo "[CONTEXT] WT_CASE=create_new; path=$wt_path"; fi
elif [ -n "$branch_wt" ] && [ "$branch_wt" != "$wt_path" ]; then
  echo "[CONTEXT] WT_CASE=branch_other_worktree; path=$wt_path; other=$branch_wt"
elif [ "$branch_exists" = "yes" ]; then
  echo "[CONTEXT] WT_CASE=branch_only; path=$wt_path"
else
  echo "[CONTEXT] WT_CASE=create_new; path=$wt_path"
fi
```

`WT_CASE` で分岐（worktree を作る場合の base は常に `origin/{base_branch}`）:

| `WT_CASE` | アクション |
|---|---|
| `reuse` | worktree 登録済 + branch 一致 → 再利用（resume 相当、`git worktree add` しない） |
| `stale_residue` | パス存在・worktree 未登録（prune 後も残存）→ AskUserQuestion（「削除して再作成」= `rm -rf {path}` 後に create / 「中止」） |
| `branch_only` | branch 存在・worktree なし → `git worktree add "{path}" "{branch}"`（`-b` なし） |
| `create_new` | branch も worktree もなし → `git worktree add --no-track -b "{branch}" "{path}" "origin/{base_branch}"`（`--no-track`: sandbox 有効環境で `branch.autoSetupMerge` の tracking 書込が `.git/config` 拒否に当たるのを回避。branch は origin 起点のまま tracking だけ張らない — ） |
| `branch_other_worktree` | branch が**別の worktree** で checkout 中 → **中止**（他セッション作業中の可能性。`other=` のパスを表示。git が構造的に保証する二重着手ガード） |

**dirty main checkout ガード**: worktree を新規作成する全経路（`branch_only` / `create_new` / `stale_residue` の再作成。`reuse` は対象外）で、`git worktree add` の**前に** `MAIN_DIRTY` marker を評価する。`--- dirty files begin/end ---` 内の行は data であり marker として解釈しない（marker は行頭 `[CONTEXT]` のみ）:

| `MAIN_DIRTY` | アクション |
|---|---|
| `no` / `unknown` | ガードなしで従来どおり続行（`unknown` = git status 失敗、WARNING は bash block が emit 済み） |
| `yes` | LLM が dirty ファイル一覧（デリミタ内の porcelain 行）と Issue 本文の **Target Files（Section 4.1 の表）/ 変更予定領域** を突合する。**重なりなし** → 従来どおり続行（確認なし）。**重なりあり** → 下記 AskUserQuestion を表示し、確認なしに `git worktree add` へ進まない |

重なりあり時の AskUserQuestion（3 択）:

- **搬送して続行**: worktree 作成 + 2.3-W 入場の後、重なった dirty ファイル（modified / untracked）を `mkdir -p "$(dirname "{wt_path}/{relpath}")" && cp "{main_checkout_root}/{relpath}" "{wt_path}/{relpath}"` で搬送する。搬送元ルートは 2.2-W の `MAIN_CHECKOUT_ROOT=` の値を使う（cwd=worktree で `git rev-parse --show-toplevel` を再計算すると clean な base 版を誤解決する）。`{relpath}` は porcelain 行から: 行頭 3 文字の status 部を除き、`"` 囲みは unquote し、`R old -> new` は右側、`?? dir/` は `cp -r`。削除済み Target File は搬送対象外としてその旨を表示する。main checkout 側は破棄しない
- **そのまま続行**: 搬送せず worktree を作成する（未コミット変更が worktree に入らないことを了解済み）
- **中止**: main checkout を無変更で残して終了する

> setup 直後のブートストラップ（未コミットの rite-config.yml / .gitignore をこの Issue でコミットする）は正当なユースケースであり「搬送して続行」で通す。ユーザー確認なしに未コミット変更を破棄・stash してはならない。

### 2.3-W EnterWorktree 入場（multi_session 有効時）

worktree を作成・再利用したら、`.rite-plugin-root` と（存在する場合のみ）`.claude/settings.local.json` を worktree root へコピーしてから入場する。`.claude/` は gitignore 対象で `git worktree add` が複製しないため、コピーしないとドッグフーディング上書き（`enabledPlugins["rite@rite-marketplace"]: false`）が失われ、古い marketplace 版スキルがロードされる。複製は worktree 作成時点のスナップショットであり、以後の main checkout 側の更新は反映されない:

```bash
[ -f "$repo_root/.rite-plugin-root" ] && cp "$repo_root/.rite-plugin-root" "$wt_path/.rite-plugin-root" 2>/dev/null || true
if [ -f "$repo_root/.claude/settings.local.json" ] && ! { mkdir -p "$wt_path/.claude" && cp "$repo_root/.claude/settings.local.json" "$wt_path/.claude/settings.local.json"; } 2>/dev/null; then
  echo "WARNING: .claude/settings.local.json のコピーに失敗しました — ドッグフーディング上書きが worktree に反映されません" >&2
fi
```

その後 `EnterWorktree` ツールを `path: {wt_path}`（2.2-W の `WT_CASE` marker の `path=` 値）で呼び出す。EnterWorktree のツール側ガード「ユーザー / プロジェクト指示で明示された場合のみ」は、`rite-config.yml` の `multi_session.enabled: true`（コミット済みのプロジェクト指示）+ 本コマンド定義の明示指示で満たす。

**EnterWorktree が不在 / 失敗の場合は silent fallback しない**。原因を切り分けて対処する（補助情報として `git -C "{wt_path}" rev-parse --is-inside-work-tree` を提示してよい）:

- **(A) harness の git 誤判定**（`git -C {wt_path} rev-parse` は成功するのに「not in a git repository」）→ **推奨**。worktree は破壊せず、リポジトリ root から Claude Code を再起動して `/rite:open {issue_number}` を再実行すれば 2.2-W が `WT_CASE=reuse` で継続する、と案内する。
- **(B) worktree path 消失などの別要因** → 新規 worktree を作らず `/rite:recover {issue_number}` へ委譲する（再起動案内へ誤誘導しない）。
- **(C) 従来 `git switch -c` で続行** → ユーザーが明示選択した場合のみ。recommended にしない。他セッション併走中は作業ツリーを破壊し合う旨を警告してステップ 2.3 へフォールバックする。

rationale: references/rationale.md#worktree-entry-failure

> 入場以降、sandbox 有効環境では main checkout 配下への state 書込（`flow-state.sh set` / `issue-claim.sh` / `issue-comment-wm-sync.sh` 等）が「読み込み専用ファイルシステムです」で拒否されることがある。拒否された当該コマンドのみ `dangerouslyDisableSandbox: true` で再実行してよい（ユーザー確認は不要。詳細: [git-worktree-patterns.md](../../references/git-worktree-patterns.md#worktree-cwd-から-main-checkout-配下への書き込みが-sandbox-の-write-許可リストでブロックされる)）。

入場後、claim に worktree path を記録する（reap / resume の discovery 用）:

```bash
bash {plugin_root}/hooks/issue-claim.sh claim --issue {issue_number} --worktree "{wt_path}" >/dev/null 2>&1 || true
```

続けて、セッション worktree 上にいることを invariant として検証する（EnterWorktree の失敗に気付かず main ツリーで implement/commit する silent fallback を遮断する最終ガード）:

```bash
cur_top=$(git rev-parse --show-toplevel 2>/dev/null) || cur_top=""
if [ "$cur_top" = "{wt_path}" ]; then
  echo "[CONTEXT] WORKTREE_INVARIANT=ok; toplevel=$cur_top"
else
  # violated 経路は prose 指示だけに頼らず bash の hard stop で機械的に遮断する。
  # echo の exit code は ok/violated とも 0 で bash 上は区別不能なため、marker を stderr に出し
  # 非ゼロ exit することで「main ツリーで implement/commit を続行する」silent fallback を構造的に止める
  # (2.1-G が branch 分岐を Bash で hard 化したのと対称。git-worktree-patterns.md の "stops the flow" 保証を実装で満たす)。
  echo "[CONTEXT] WORKTREE_INVARIANT=violated; expected={wt_path}; actual=${cur_top:-<none>}" >&2
  exit 1
fi
```

- `WORKTREE_INVARIANT=ok` → ステップ 2.4 へ進む。
- `WORKTREE_INVARIANT=violated` → 本ブロックが `exit 1` で停止する。main ツリー上で implement / commit を行わず、上記 (A) / (B) / (C) の切り分けへ戻る。`violated` のままブランチ実装へ進むことは禁止。

rationale: references/rationale.md#worktree-invariant

ステップ 3〜6 は cwd 相対で完結するため無変更で、`WORKTREE_INVARIANT=ok` を前提条件とする。

### 2.4 GitHub Projects Status 更新

`rite-config.yml.github.projects.enabled: true` の場合、(A) と (B) の 2 種類を実行する。**(A) は skip 禁止**（inline してある理由は rationale: references/rationale.md#projects-status-inline）。

**(A) 着手 Issue 自身の Status を `In Progress` にする**:

```bash
status_json_args=$(jq -n \
  --argjson issue {issue_number} \
  --arg owner "{owner}" \
  --arg repo "{repo}" \
  --argjson project_number {project_number} \
  --arg status "In Progress" \
  --argjson auto_add true \
  --argjson non_blocking true \
  '{issue_number:$issue, owner:$owner, repo:$repo, project_number:$project_number, status_name:$status, auto_add:$auto_add, non_blocking:$non_blocking}')
# `|| status_json=""` は付けない — このブロックに set -e はなく、command substitution は
# script が非ゼロ終了しても stdout (script が既に出力した失敗理由入り JSON) を正しく capture
# するため、fallback を付けるとその診断情報を空文字列で上書き・破棄してしまう
status_json=$(bash {plugin_root}/scripts/projects-status-update.sh "$status_json_args")
status_result=$(printf '%s' "$status_json" | jq -r '.result // "failed"' 2>/dev/null)
status_warning_lines=$(printf '%s' "$status_json" | jq -r '.warnings[]?' 2>/dev/null)
case "$status_result" in
  updated)
    echo "Projects Status を \"In Progress\" に更新しました" ;;
  skipped_not_in_project)
    echo "警告: Issue #{issue_number} は Project に登録されていません。Status 更新をスキップします" >&2 ;;
  failed|*)
    [ -n "$status_warning_lines" ] && printf '%s\n' "$status_warning_lines" | sed 's/^/  /' >&2
    echo "警告: Projects Status の \"In Progress\" への更新に失敗しました。手動更新: gh project item-edit --project-id <project_id> --id <item_id> --field-id <status_field_id> --single-select-option-id <in_progress_option_id>" >&2 ;;
esac
```

`auto_add: true` は未登録 Issue を helper 内部で Project へ自動登録する。全 result 分岐は non-blocking で、Status 更新の失敗が open をブロックすることはない。API レベルの詳細は [projects-integration.md §2.4.1–2.4.6](../../references/projects-integration.md#24-github-projects-status-update)。

**(B) 親 Issue の Status 更新（Sub-Issue 着手時）** — (A) と独立に必ず実行する。ロジックの SoT は `projects-integration.md` §2.4.7:

1. **§2.4.7.1 親検出（3-method OR）**: `## 親 Issue` body meta（PRIMARY）→ Sub-Issues API → tasklist search。この 3-method 構造は `../skills/issue-close/SKILL.md` Phase 4.5.1 と同一に保つ（Method 3 の `--state open` は start 側固有の意図的差異）。
2. 親を検出したら **§2.4.7.2–2.4.7.4**: Status が **Todo または null のときのみ** In Progress にする。既に In Progress / In Review / Done なら上書きしない（sibling child の進捗を保持する）。
3. 親が無い standalone Issue は `[DEBUG] parent not detected for issue #{issue_number} — processing as standalone (methods tried: body_meta, sub_issues_api, tasklist_search)` を emit して skip する（silent skip 禁止）。

(B) はすべて non-blocking。

### 2.5 Work Memory 初期化

Issue の comment として work memory の backup replica を初期投稿する（ローカルファイルが SoT、Issue コメントは replica。形式: `../../skills/rite-workflow/references/work-memory-format.md`）。投稿は `issue-comment-wm-sync.sh` の init mode に委譲する。rationale: references/rationale.md#wm-replica-init

```bash
# init は non-blocking 契約: gh 失敗 (auth / rate limit / network) でも helper は WARNING を出して
# exit 0 を返すため、失敗時も open は後続ステップへ続行する。status 行の有無は投稿・検証段が決める:
# 投稿・検証段まで到達すれば status 行あり (success / unverified)、投稿本体 gh issue comment の
# 失敗では status 行なし (下表 4 行目参照)。pre-check gh api 失敗は non-blocking で続行のみで、
# status 行は後続の投稿結果に従う。
# replica が既に存在する場合は helper が冪等に skip する (status=skipped; reason=already_exists)。
init_out=$(bash {plugin_root}/hooks/issue-comment-wm-sync.sh init \
  --issue {issue_number} --branch "{branch_name}" 2>&1) || true
printf '%s\n' "$init_out" | tail -3
echo "[CONTEXT] WM_REPLICA_INIT=$(printf '%s\n' "$init_out" | sed -n 's/^status=//p' | tail -1)"
```

`status=` 行による分岐 (いずれも続行 — replica 作成失敗で open を止めない):

| status | 意味 | アクション |
|--------|------|-----------|
| `success` | replica 作成 + 検証済み | 続行 |
| `skipped; reason=already_exists` | replica 既存 (冪等 skip) | 続行 |
| `unverified` | 投稿は実行されたが検証 (3 回 retry) で発見できず | WARNING として続行 (以降の update が `no_comment` skip になる可能性を認識) |
| (status 行なし = gh 失敗等) | 投稿失敗 | WARNING として続行 (non-blocking) |

### 2.6 flow-state 更新

```bash
bash {plugin_root}/hooks/flow-state.sh set \
  --phase branch --issue {issue_number} --branch {branch_name} --pr 0 \
  --next "実装計画策定へ進む"
```

2.1-G の `MULTI_SESSION_ENABLED=true` のときは末尾に `--worktree "{wt_path}" --require-worktree` を追加する（`{wt_path}` は 2.2-W の `path=` 値）。`--require-worktree` は worktree path 不在のまま branch phase を記録した場合に `[CONTEXT] WORKTREE_INVARIANT=missing` を emit する（書き込み自体は完了するため work は失われない）。`missing` を観測したら worktree 化が漏れているので 2.2-W へ戻る。

---

## ステップ 3: 実装計画

### 3.1 Issue 内容分析

Issue body から「What / Why / Where / Acceptance Criteria」を抽出。

### 3.2 変更対象ファイルの特定

`git grep` / `find` / Read で関連ファイルを特定。Acceptance Criteria に対する責務ファイルを列挙する。

### 3.3 実装計画生成

以下のテンプレートで実装計画を出力:

```
## 実装計画

### 変更対象ファイル
- {file_path_1}: {responsibility}

### 参考実装
| 参考ファイル | 参考理由 |
|-------------|---------|
| {reference_file_1} | {reason_1} |

### 実装ステップ
1. {step_1}
2. {step_2}

### 受入基準マッピング
- AC1 → step {N}

### 注意点
- {note_1}
```

**volatile-first**: `## 実装計画` の直後・`### 変更対象ファイル` の前に、ユーザーの判断で変わりやすい項目（データモデル・型/インターフェース・ユーザー可視挙動）を「要判断ポイント」として列挙する。該当なしの計画では出力しない。**「実装ステップ」の並び順（= 実行順）は変更しない**。rationale: references/rationale.md#plan-volatile-first

**参考実装**: ステップ 3.2 で見つけた既存の参考実装（同ディレクトリの類似ファイル、命名パターン一致）を記録する（`reference_discovery` 原則 — [coding-principles.md](../rite-workflow/references/coding-principles.md)）。見つからない場合はテーブルの代わりに `参考実装: なし（新規ディレクトリまたは初めてのファイルパターン）` の 1 行を出力する。

### 3.4 計画承認（batch 時は自動承認 / standalone は AskUserQuestion）

batch 実行中（run-queue `active=true` かつ cursor が本 Issue を指す）は計画を**自動承認**して停止しない。standalone は AskUserQuestion で確認する。判定は read-only で、helper 失敗 / session_id 解決不可 / キュー不在のときは interactive へ fail-safe する。rationale: references/rationale.md#plan-auto-approval

```bash
state_root=$(bash {plugin_root}/hooks/state-path-resolve.sh)
fs_path=$(bash {plugin_root}/hooks/flow-state.sh path)
session_id=$(basename "$fs_path" .flow-state)
queue_file="$state_root/.rite/state/run-queue-$session_id.json"
plan_mode=interactive
# session_id 解決不可（空）/ キュー不在 → 自セッションの batch キューを特定できないため
# 安全側 interactive のまま（read-only なので fail-loud はせず確認を出す方に倒す）
if [ -n "$session_id" ] && [ -f "$queue_file" ]; then
  q_active=$(jq -r '.active // false' "$queue_file" 2>/dev/null)   # active 欠落の旧形式は false（安全側 = interactive）
  q_cursor=$(jq -r '.cursor // 0' "$queue_file" 2>/dev/null)
  q_total=$(jq -r '.issues | length' "$queue_file" 2>/dev/null)
  q_issue=$(jq -r ".issues[$q_cursor] // empty" "$queue_file" 2>/dev/null)
  if [ "$q_active" = "true" ] && [ "$q_cursor" -lt "${q_total:-0}" ] 2>/dev/null && [ "$q_issue" = "{issue_number}" ]; then
    plan_mode=batch
  fi
fi
echo "[CONTEXT] OPEN_PLAN_MODE=$plan_mode; issue={issue_number}"
```

| `OPEN_PLAN_MODE` | アクション |
|---|---|
| `batch` | 計画を**自動承認**（AskUserQuestion を出さない）。3.3 の計画（要判断ポイント含む）は記録として表示済みのまま、ステップ 3.5 へ直行する |
| `interactive` | AskUserQuestion で「この計画で実装開始 / 計画を修正 / 中止」を選択（standalone。従来どおり。AC-4 回帰なし） |

### 3.5 Issue Body Checklist 更新

実装ステップを Issue body の `- [ ]` チェックリストとして追記。詳細は `../../references/gh-cli-patterns.md#safe-checklist-operation-patterns` 参照。

### 3.6 Work Memory 更新

実装計画を work memory comment に記録。

### 3.7 flow-state 更新

```bash
bash {plugin_root}/hooks/flow-state.sh set \
  --phase plan --issue {issue_number} --branch {branch_name} --pr 0 \
  --next "実装作業へ進む"
```

---

## ステップ 4: 実装

```text
skill: rite:issue-implement
args: "{issue_number}"
```

`/rite:issue-implement` はチェックリスト駆動の実装・conventional commits でのコミット・Work Memory 更新を担い、全 step 完了後に `rite:lint` を自身で invoke する。`tdd.enabled: true`（デフォルト, opt-out）のときは Canon TDD サイクルで進む（詳細は `skills/issue-implement/SKILL.md` § 5.0.T）。

本ステップ完了時点で `phase=lint` と `[lint:*]` sentinel が揃っているのが正常であり、判定は Step 5 に委譲する。本ステップ単体の sentinel routing table は持たない。rationale: references/rationale.md#autonomous-lint

---

## ステップ 5: 品質チェック (Step 4 の autonomous lint 結果検証)

Step 4 の autonomous lint が emit した sentinel を会話 context から読む。**`rite:lint` を再 invoke しない**（二重実行防止）:

| Sentinel | 次のアクション |
|---------|--------------|
| `[lint:success]` | ステップ 6 へ進む |
| `[lint:skipped]` | ステップ 6 へ進む (lint 未設定) |
| `[lint:error]` | AskUserQuestion で「修正再実行 / 強制続行 / 中止」を提示 |
| `[lint:aborted]` | エラー終了。ユーザーに復旧手順を案内 |
| sentinel 不在 | Step 4 で `/rite:issue-implement` が autonomous lint まで到達できなかった可能性。AskUserQuestion で「手動で `/rite:lint` 実行 / 中止」を提示 |

`phase=lint` は Step 4 が既に書いているため上書きしない（二重 write を避ける契約）。

---

## ステップ 6: PR 作成

### 6.1 push

```bash
git push origin {branch_name}
```

> `-u` は付けない（sandbox 環境で upstream tracking の `.git/config` 書込が拒否されるため）。SSH host alias 経由の `origin` では push が sandbox のネットワーク許可リストでブロックされることがあり、その場合は当該コマンドのみ `dangerouslyDisableSandbox: true` で再実行してよい（ユーザー確認は不要）。rationale: references/rationale.md#push-no-upstream

### 6.2 PR 作成

```text
skill: rite:pr-create
```

`rite:pr-create` の出力 sentinel を会話 context から検証する:

| Sentinel | 次のアクション |
|---------|--------------|
| `[pr:created:N]` | PR 番号 `N` を `{pr_number}` として retain → ステップ 6.3 へ |
| `[pr-create-failed]` | AskUserQuestion で「再試行 / 中止」を提示 |
| **sentinel 不在 (missing-sentinel)** | `[pr:created:N]` / `[pr-create-failed]` のいずれも context に無い。Phase 3.4 の `gh pr create` が malformed tool-call で無言終了した可能性 (Cause A: harness/transport 側ゆらぎ、rite では除去不能 — 詳細は下記「malformed tool-call 回復契約」)。下記手順で回復する |

**malformed tool-call 回復契約** — sub-skill が sentinel を 1 つも emit せず無言終了した場合:

1. **既存 draft PR の検出**: `gh pr list -R {owner_repo} --head {branch_name} --json number,url,isDraft`。存在すれば `[pr:created:N]` 相当として `{pr_number}` を再構成し、ステップ 6.3 へ進む（push/PR は冪等に再開可能）
2. **未作成の場合**: AskUserQuestion で「PR 作成を再試行 / 中止」。中止時は `/rite:recover` で本ステップから再開できる旨を案内する

rationale: references/rationale.md#missing-sentinel-recovery

### 6.3 flow-state 更新

```bash
bash {plugin_root}/hooks/flow-state.sh set \
  --phase pr --issue {issue_number} --branch {branch_name} --pr {pr_number} \
  --next "レビュー/修正ループへ進む (/rite:iterate {pr_number})"
```

`MULTI_SESSION_ENABLED=true` のときは末尾に `--worktree "{wt_path}" --require-worktree` を追加する（merge-preserve のため省略しても保持されるが、明示して他経路の set との順序非依存を担保する）。検知の意味は 2.6 と同じ。

---

## 完了通知

draft PR の作成が完了したら、ユーザーに以下を案内する:

```
## /rite:open 完了

- Issue: #{issue_number} - {issue_title}
- ブランチ: {branch_name}
- Draft PR: #{pr_number} - {pr_url}

次のステップ:
- レビュー/修正ループ: /rite:iterate {pr_number}
- Ready 化: /rite:ready {pr_number}
- マージ: /rite:merge {pr_number}
- クリーンアップ (merge 後): /rite:cleanup {pr_number}

途中で止まったら /rite:recover で復帰します。
```

---

## エラー時の方針

- どこで止まっても flow-state に phase が残るため、`/rite:recover` が該当ステップから再開する
- sub-skill invoke 後は必ず sentinel の有無を確認する。不在なら AskUserQuestion で「再試行 / 中止」
- 無言終了（sentinel を 1 つも emit せずターン終了）も missing-sentinel として同じ扱い。PR 作成段の回復手順はステップ 6.2 の「malformed tool-call 回復契約」
