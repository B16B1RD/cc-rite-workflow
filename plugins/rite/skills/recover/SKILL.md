---
name: recover
description: |
  rite workflow の作業再開スキル: 中断した Issue/PR 作業の状態を検出し適切なステップへ復帰する。
  ユーザーが明示的に /rite:recover で起動する。auto-activate しない。
  起動: /rite:recover
argument-hint: ""
---

# /rite:recover

中断した rite ワークフローを再開する。flow-state (phase enum v3 SoT) と commit 数 / PR 状態 / work memory を cross-check して、最適な再開点を決定する。

**Use cases:**
- Claude Code クラッシュ後の再開
- セッション切断後の再開
- 手動中断後の再開
- **Context 枯渇時の継続**: セッションの context が逼迫した場合は `/clear` で会話履歴をリセットしてから `/rite:recover` を実行する。これが rite workflow における context 枯渇時の **唯一の正規経路** (詳細: [workflow-identity.md](../../skills/rite-workflow/references/workflow-identity.md))。

---

## Arguments

| Argument | Description |
|----------|-------------|
| `[issue_number]` | Issue 番号 (省略時はブランチ名から自動抽出) |

## Placeholder Legend

> 後続 Phase は別々の Bash tool 呼び出しとなりシェル変数を引き継げないため、Phase 3.1 / 3.5 / 4.2 が stdout に emit する `[CONTEXT] STATE_* / RESOLVED_PHASE / FINAL_PHASE` marker を source とし、LLM が会話コンテキストから読んで placeholder を実値置換する (詳細は Phase 5.2 の注記参照)。

| Placeholder | Source |
|-------------|--------|
| `{issue_number}` / `{issue_arg}` / `{number}` | Phase 1.1: 引数 or ブランチ名 `{type}/issue-{number}-{slug}` 抽出 (`[CONTEXT] RESUME_ISSUE` marker) |
| `{title}` | Phase 1.2: `gh issue view` の title |
| `{branch}` / `{git_branch}` | Phase 3.2: `git branch --show-current` |
| `{base_branch}` | Phase 3.2: `rite-config.yml` の `branch.base` (default `develop`) |
| `{git_commit_count}` | Phase 3.2: `git rev-list --count origin/{base_branch}..HEAD` |
| `{git_has_uncommitted}` | Phase 3.2: `git status --porcelain` の非空判定 (サマリでは「あり」/「なし」整形) |
| `{git_conflict_files}` | Phase 3.2: `[CONTEXT] GIT_CONFLICT_FILES` marker (`git status --porcelain` の unmerged マーカー UU/AA/DD 等のファイル一覧、カンマ区切り)。Phase 3.4.5 のコンフリクト優先判定に使用 |
| `{git_in_merge}` | Phase 3.2: `[CONTEXT] GIT_IN_MERGE` marker (`git rev-parse --git-path MERGE_HEAD` の存在判定 = merge 解決待ち) |
| `{git_in_rebase}` | Phase 3.2: `[CONTEXT] GIT_IN_REBASE` marker (`git rev-parse --git-path rebase-merge`/`rebase-apply` の存在判定 = rebase 中断) |
| `{state_next}` | Phase 3.1: `[CONTEXT] STATE_NEXT` marker (flow-state `next_action`) |
| `{state_stop_reason}` | Phase 3.1: `[CONTEXT] STATE_STOP_REASON` marker (flow-state `stop_reason`; empty = ordinary interruption) |
| `{state_parent}` | Phase 3.1: `[CONTEXT] STATE_PARENT` marker (flow-state `parent_issue_number`) |
| `{state_parent_display}` | Phase 3.1: `[CONTEXT] STATE_PARENT_DISPLAY` marker (`0`/空 → 「なし」、それ以外 → `#NN` 整形) |
| `{pr_number}` | Phase 3.3: `gh pr view` の `.number` (Phase 3.1 `[CONTEXT] STATE_PR` も参照可) |
| `{pr_state}` | Phase 3.3: `gh pr view` の `.state` (NONE/OPEN/MERGED/CLOSED) |
| `{pr_is_draft}` | Phase 3.3: `gh pr view` の `.isDraft` |
| `{pr_mergeable}` | Phase 3.3: `[CONTEXT] PR_MERGEABLE` marker (`gh pr view` の `.mergeable`: MERGEABLE/CONFLICTING/UNKNOWN)。Phase 3.4.5 で CONFLICTING をコンフリクト状態として扱う |
| `{wm_next}` | Phase 3.4: work memory (`.rite-work-memory/issue-{n}.md`) の `next_action:` |
| `{resolved_phase}` | Phase 3.5: cross-check 確定 phase (`[CONTEXT] RESOLVED_PHASE` marker)。Phase 4.2 で user が phase 変更を選んだ場合は `[CONTEXT] FINAL_PHASE` marker を優先 |
| `{type}` / `{slug}` | ブランチ名 `{type}/issue-{number}-{slug}` の構成要素 |
| `{plugin_root}` | [Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script-full-version) |
| `{owner_repo}` | [Owner/Repo Resolution](../../references/gh-cli-patterns.md#ownerrepo-resolution-ssh-host-alias-safe) で解決した owner/repo（slash 形式）を literal substitute |

---

## Phase 1: Issue 番号確定

### 1.1 引数優先

引数があればそれを使う。なければブランチ名 `{type}/issue-{number}-{slug}` から抽出。

```bash
# Auto-detect from branch name when argument is missing
branch=$(git branch --show-current 2>/dev/null || echo "")
issue_arg="${1:-}"
if [ -z "$issue_arg" ]; then
  issue_arg=$(echo "$branch" | sed -nE 's|^[a-z]+/issue-([0-9]+)-.*$|\1|p')
fi
if [ -z "$issue_arg" ]; then
  # multi_session fallback: クラッシュ後の新セッションは repo root (branch=base) で
  # 開始されるため branch 抽出が失敗する。登録済みセッション worktree から候補を列挙する。
  ms_section=$(sed -n '/^multi_session:/,/^[a-zA-Z]/p' rite-config.yml 2>/dev/null) || ms_section=""
  ms_base=$(printf '%s\n' "$ms_section" | awk '/^[[:space:]]+worktree_base:/ {print; exit}' \
    | sed 's/[[:space:]]#.*//' | sed 's/.*worktree_base:[[:space:]]*//' | tr -d '[:space:]"'"'"'')
  [ -n "$ms_base" ] || ms_base=".rite/worktrees"
  wt_issues=$(git worktree list --porcelain 2>/dev/null | awk '$1=="worktree"{print $2}' \
    | grep -E "/${ms_base}/issue-[0-9]+\$" | sed -nE 's|.*/issue-([0-9]+)$|\1|p' | sort -un)
  cnt=$(printf '%s' "$wt_issues" | grep -c . 2>/dev/null || echo 0)
  echo "[CONTEXT] RESUME_WT_CANDIDATES=$(printf '%s' "$wt_issues" | tr '\n' ',' | sed 's/,$//'); count=$cnt"
fi
if [ -n "$issue_arg" ]; then
  echo "[CONTEXT] RESUME_ISSUE=$issue_arg"
fi
```

`$issue_arg` が確定しなかった場合は `[CONTEXT] RESUME_WT_CANDIDATES=` marker を読んで分岐する:

- `count=0`: 候補なし → 以下を表示して終了:
  ```
  ERROR: Issue 番号が判定できません (引数 / branch 名 / セッション worktree のいずれからも抽出できません)。
    /rite:recover <number> で明示指定するか、Issue ブランチに切り替えてください。
  ```
- `count=1`: その issue 番号を `$issue_arg` として採用し、ユーザーに「#{N} を再開しますか？」を提案してから続行する。
- `count>1`: **AskUserQuestion** で候補の issue 番号を提示し 1 件選択させる。

### 1.2 Issue 存在確認

```bash
if ! gh issue view "$issue_arg" -R {owner_repo} --json number,title,state >/dev/null 2>&1; then
  echo "ERROR: Issue #$issue_arg が見つかりません" >&2
  exit 1
fi
```

---

## Phase 2: 自動 migration (v1/v2 → v3)

旧 schema の flow-state ファイルを v3 schema (新 phase enum 13 個) に自動移行する。失敗してもベストエフォートで続行 (cross-check で実態を再推定する)。

```bash
bash {plugin_root}/hooks/flow-state.sh migrate --verbose 2>&1 || \
  echo "WARNING: migrate に失敗しました — cross-check で実態を推定します" >&2
```

---

## Phase 3: 状態の cross-check (4 指標から実態 phase を推定)

### 3.1 flow-state から状態取得

```bash
state_phase=$(bash {plugin_root}/hooks/flow-state.sh get --field phase --default "")
state_branch=$(bash {plugin_root}/hooks/flow-state.sh get --field branch --default "")
state_active=$(bash {plugin_root}/hooks/flow-state.sh get --field active --default "true")
state_issue=$(bash {plugin_root}/hooks/flow-state.sh get --field issue_number --default "0")
state_pr=$(bash {plugin_root}/hooks/flow-state.sh get --field pr_number --default "0")
state_next=$(bash {plugin_root}/hooks/flow-state.sh get --field next_action --default "")
state_stop_reason=$(bash {plugin_root}/hooks/flow-state.sh get --field stop_reason --default "")
state_parent=$(bash {plugin_root}/hooks/flow-state.sh get --field parent_issue_number --default "0")

# parent_issue_number=0 は「親 Issue なし」を意味するため、サマリ表示で "#0" を見せないよう "なし" に整形する
# (Phase 4.1 サマリの `Parent Issue: #{state_parent}` 行が `#0` 誤表示するのを防ぐ)。
case "$state_parent" in
  ""|"0"|"null") parent_issue_display="なし" ;;
  *)             parent_issue_display="#$state_parent" ;;
esac

# Emit [CONTEXT] markers so Phase 5.2 (separate Bash tool invocation) can read these values.
# Claude Code Bash tool 境界でシェル状態は失われるため、Phase 5.2 で `$state_phase` を直接参照しても
# 常に空文字となり active=true 復元経路が dead になる。後続ステップは本 [CONTEXT]
# marker を読み、{resolved_phase} / {state_next} placeholder を実値に置換して bash block を出力する。
echo "[CONTEXT] STATE_PHASE=$state_phase"
echo "[CONTEXT] STATE_BRANCH=$state_branch"
echo "[CONTEXT] STATE_ACTIVE=$state_active"
echo "[CONTEXT] STATE_ISSUE=$state_issue"
echo "[CONTEXT] STATE_PR=$state_pr"
echo "[CONTEXT] STATE_NEXT=$state_next"
echo "[CONTEXT] STATE_STOP_REASON=$state_stop_reason"
echo "[CONTEXT] STATE_PARENT=$state_parent"
echo "[CONTEXT] STATE_PARENT_DISPLAY=$parent_issue_display"
```

### 3.1.5 セッション worktree への再入場（multi_session 有効時、cross-check より前）

git/PR 状態クロスチェック（Phase 3.2 / 3.3 の `git rev-list origin/{base}..HEAD` / `gh pr view`）は**カレントブランチ依存**のため、worktree への再入場は**その前に**行う必要がある（順序が本質）。session ⇄ worktree は 1:1 でない（クラッシュで session_id が変わる）ため、**issue 番号 → worktree パス導出（discovery fallback）が正規の対応関係**であり、flow-state `worktree` field は同一セッション内のヒントに留まる:

検出・再構築は共通ヘルパー `ensure_session_worktree`（[`lib/worktree-git.sh`](../../hooks/scripts/lib/worktree-git.sh)、#1676 で #1368 のロジックを SoT 化）に委譲する。ヘルパーは `multi_session` の読取・worktree パス導出（`--git-common-dir` から main checkout root を求める）・branch 解決（issue-N の local/remote ref から自動）・**再構築（`git worktree add`）まで bash 側で完結**し、唯一の `[CONTEXT] WT_ENSURE=` marker を emit する。session ⇄ worktree は 1:1 でない（クラッシュで session_id が変わる）ため、helper は issue 番号 → worktree パス導出を正規の対応とし、flow-state `worktree` field には依存しない:

```bash
bash {plugin_root}/hooks/scripts/lib/worktree-git.sh ensure-session-worktree --issue "$issue_arg"
```

> **本ブロックは WT_ENSURE 分岐表の SoT**（review / iterate / fix の入場ゲートが参照する。#1676）。EnterWorktree は LLM ツールのため helper からは呼べず、`reenter` / `reconstructed` の入場のみ下記表に従い LLM が実行する。
>
> **marker の読み取り規約は本ファイルが持たない**（#2025）。どの行が marker か（行頭アンカー）・stderr が複数行混入しても読めること・`branch=` スコープで他ブランチの値を拾わないこと・同一 KEY が複数回出たときは最新が勝つこと・キーと field 名がトークン完全一致であることは、共有関数 `marker_get`（[`lib/context-marker.sh`](../../hooks/scripts/lib/context-marker.sh)）の契約であり、SoT は `hooks/tests/context-marker.test.sh`。下表は **case 値ごとのアクション**のみを規定する。バッチ実行では同一 transcript に複数ブランチの `WT_ENSURE` が並ぶため、対象を取り違えないこと（規約の実体は上記関数、その `--branch` が対応する）。

`WT_ENSURE` で分岐する:

| `WT_ENSURE` | アクション |
|---|---|
| `disabled` / `already_in` | no-op（従来フロー / 既に worktree 内）。Phase 3.2 へ |
| `reenter` / `reconstructed` | `EnterWorktree` ツールを `path: {path}` で呼び出してから Phase 3.2 へ（`{path}` は marker の `path=` 値。`reconstructed` は helper が `git worktree add` 済み） |
| `residue` | パスは存在するが worktree 未登録（prune 後も残存）→ AskUserQuestion（削除 `rm -rf {path}` して再実行 / 中止） |
| `branch_other_worktree` | branch が**別の worktree** で checkout 中（並行セッションの可能性）→ **中止**。`other=` のパスを表示する（git が構造的に保証する二重着手ガード） |
| `branch_absent` | branch がローカル・リモートどこにも無い → **矛盾サマリ + AskUserQuestion**（新規セッション扱い / 中止）。helper は再構築しない（silent に新規扱いもしない） |
| `failed` | 再構築（`git fetch` / `git worktree add`）が失敗（helper rc=1, stderr に原因 + 復旧手順）→ **silent fallback せず明示停止**。develop 上で recover を続行しない |

> **caller-local marker `skip` について**: `review` / `fix` の入場ゲートは PR の `headRefName` が issue ブランチ（`issue-N` 命名）でないとき、helper を呼ばず caller 自身が `[CONTEXT] WT_ENSURE=skip` を emit する（session worktree の対象外＝従来どおり単一ツリーで続行する no-op）。`skip` は helper の出力 case ではなく **caller 固有拡張**であり、`disabled` / `already_in` と同じく no-op として扱う。recover は引数 / branch / 候補列挙で issue を確定してから本 helper を呼ぶため、recover 経路で `skip` は emit されない。

> **sandbox 有効環境での state 書込拒否（#1896）**: `reenter` / `reconstructed` で worktree に入場した直後、後続フェーズの `flow-state.sh set` 等 main checkout 配下への state 書込が「読み込み専用ファイルシステムです」で失敗することがある（sandbox の write 許可リストが cwd 依存の相対パスのため）。対処は [git-worktree-patterns.md](../../references/git-worktree-patterns.md#worktree-cwd-から-main-checkout-配下への書き込みが-sandbox-の-write-許可リストでブロックされる) を参照。

**EnterWorktree が失敗した場合**（`reenter` / `reconstructed` 経路の `EnterWorktree(path)` がエラー）: open Step 2.3-W と同じ切り分けを行い、**silent に新規セッション扱いしない**。

- **harness の git 誤判定**（`.git` が存在し `git -C "{path}" rev-parse` は成功するのに、起動コンテキストが `Is a git repository: false` で EnterWorktree が「not in a git repository」エラーを返す）→ **推奨**。診断とともに「**リポジトリ root から Claude Code を再起動**し、`/rite:recover {issue_number}` を再実行すれば、登録済み worktree が `WT_ENSURE=reenter` で再入場される」と案内する。worktree は保持済みのため破壊しない。
- **worktree path 消失などの別要因** → 再度本ヘルパーを実行すれば `branch_absent` 以外なら再構築される。再起動案内へ誤誘導しない。

再入場後、claim に worktree path を再記録してもよい（`issue-claim.sh claim --issue {issue_number} --worktree "{path}"`、best-effort）。

### 3.2 git 状態取得

```bash
git_branch=$(git branch --show-current 2>/dev/null || echo "")
# develop に到達できない場合は origin/develop or main を base に
base_branch="develop"
git fetch origin "$base_branch" >/dev/null 2>&1 || true
git_commit_count=$(git rev-list --count "origin/${base_branch}..HEAD" 2>/dev/null || echo "0")
git_has_uncommitted=$(bash {plugin_root}/hooks/scripts/lib/git-status-filtered.sh) || git_has_uncommitted="?? (dirty-check failed — assume uncommitted for safety)"; git_has_uncommitted="${git_has_uncommitted%%$'\n'*}"

# コンフリクト / rebase 状態検出 (#1705): Phase 3.4.5 が phase 推定より優先させる signal。
# worktree 運用でも正しい作業ツリーを判定するため .git/... を直書きせず git rev-parse --git-path で
# 解決する (worktree の MERGE_HEAD / rebase 状態は .git/worktrees/<name>/ 配下にあり、直書きは常に
# 不在扱いとなって merge/rebase 中断を取りこぼす)。
git_conflict_files=$(git status --porcelain 2>/dev/null | grep -E '^(DD|AU|UD|UA|DU|AA|UU) ' | cut -c4- | paste -sd, -)
[ -f "$(git rev-parse --git-path MERGE_HEAD 2>/dev/null)" ] && git_in_merge=yes || git_in_merge=no
if [ -d "$(git rev-parse --git-path rebase-merge 2>/dev/null)" ] || [ -d "$(git rev-parse --git-path rebase-apply 2>/dev/null)" ]; then
  git_in_rebase=yes
else
  git_in_rebase=no
fi
echo "[CONTEXT] GIT_CONFLICT_FILES=$git_conflict_files"
echo "[CONTEXT] GIT_IN_MERGE=$git_in_merge"
echo "[CONTEXT] GIT_IN_REBASE=$git_in_rebase"
```

### 3.3 PR 状態取得

```bash
# -R 指定時は selector が必須のため、現在のブランチ名を selector に渡す（従来どおり「現在ブランチの PR」を特定。PR 不在時は fallback JSON）
pr_info=$(gh pr view "$(git branch --show-current)" -R {owner_repo} --json state,number,isDraft,mergeable 2>/dev/null || echo '{"state":"NONE","number":0,"isDraft":false,"mergeable":"UNKNOWN"}')
pr_state=$(echo "$pr_info" | jq -r '.state // "NONE"')
pr_number_gh=$(echo "$pr_info" | jq -r '.number // 0')
pr_is_draft=$(echo "$pr_info" | jq -r '.isDraft // false')
# mergeable=CONFLICTING は Phase 3.4.5 のコンフリクト優先判定に使う (base ブランチとの衝突)。
pr_mergeable=$(echo "$pr_info" | jq -r '.mergeable // "UNKNOWN"')
echo "[CONTEXT] PR_MERGEABLE=$pr_mergeable"
```

### 3.4 Work Memory 状態取得

```bash
LOCAL_WM=".rite-work-memory/issue-${issue_arg}.md"
wm_phase=""
wm_next=""
if [ -f "$LOCAL_WM" ]; then
  wm_phase=$(grep "^phase:" "$LOCAL_WM" 2>/dev/null | head -1 | sed 's/phase: *//' | tr -d '"')
  wm_next=$(grep "^next_action:" "$LOCAL_WM" 2>/dev/null | head -1 | sed 's/next_action: *//' | tr -d '"')
fi
```

### 3.4.5 コンフリクト / rebase 状態の優先判定 (#1705)

Phase 3.2 の `[CONTEXT] GIT_CONFLICT_FILES` / `GIT_IN_MERGE` / `GIT_IN_REBASE` marker と Phase 3.3 の `PR_MERGEABLE` marker を読み、**いずれかがコンフリクト / rebase 中断を示す場合は、Phase 3.5 の phase 推定より本判定を優先する**。コンフリクトマーカーが残ったまま generic な「実装途中」扱いで復帰し、未解決の変更を上書きコミットへ誘導される事故を防ぐのが本判定の目的（マーカーの検出は git 実態からの読み取りで完結するため flow-state schema の変更は不要）。

**判定条件（OR、いずれか成立でコンフリクト状態）**:

| signal | 条件 | 意味 |
|---|---|---|
| `GIT_IN_MERGE` | `=yes`（`MERGE_HEAD` 存在） | merge 解決待ちの中断状態 |
| `GIT_IN_REBASE` | `=yes`（`rebase-merge` / `rebase-apply` 存在） | rebase 中断状態 |
| `GIT_CONFLICT_FILES` | 非空（`git status --porcelain` の unmerged マーカー `UU`/`AA`/`DD`/`AU`/`UA`/`DU`/`UD`） | コンフリクトファイルが残存 |
| `PR_MERGEABLE` | `=CONFLICTING` | PR がベースブランチとコンフリクト |

いずれか成立時は、Phase 3.5 の cross-check へ進む**前に**以下を提示する:

```
⚠️ コンフリクト / rebase 中断を検出しました:
  - Merge 解決待ち (MERGE_HEAD): {GIT_IN_MERGE}
  - Rebase 中断 (rebase-merge/apply): {GIT_IN_REBASE}
  - コンフリクトファイル: {GIT_CONFLICT_FILES: 一覧 or "なし"}
  - PR mergeable: {PR_MERGEABLE}

コンフリクトマーカーが残ったまま実装 phase を継続すると、未解決の変更を上書きコミットする恐れがあります。
```

続けて AskUserQuestion で以下を提示する（rite は**コンフリクトを自動解消・自動コミットしない** — 本 Issue の Non-goal）:

- **解消してから継続（推奨）** — ユーザーがコンフリクトを手動解消（`git` の merge/rebase 続行 or `--abort`）した後、`/rite:recover {issue_arg}` を再実行する旨を案内していったん終了する。解消により上記 signal が消えれば、再実行時は本判定を通過して従来の cross-check に進む
- **中止** — 何もせず終了する

非コンフリクト時（上記 4 条件すべて不成立）は本判定を skip し、Phase 3.5 の従来 4 指標クロスチェックへそのまま進む（AC-3: 非干渉）。

### 3.5 整合性判定 (cross-check)

以下の優先順で実態 phase を確定:

1. **state_phase が v3 enum (13 個) の有効値** → state_phase を採用
2. **state_phase が空 + wm_phase が有効値** → wm_phase を採用 (work memory fallback)
3. **state_phase が空 + wm_phase も空 + pr_state=OPEN** → `review` (PR がある → レビュー段階)
4. **state_phase が空 + wm_phase も空 + git_commit_count>0** → `implement` (コミットあり → 実装段階)
5. **state_phase が空 + wm_phase も空 + git_branch が refactor/feat/fix/chore/issue ブランチ** → `branch` (ブランチのみある状態)
6. **どれも該当しない** → `init` (新規スタート相当)

矛盾検出時 (例: state_phase=plan だが git_commit_count>5):

```
⚠️ flow-state と実態の不整合を検出しました:
  - flow-state phase: $state_phase
  - 実態 commit 数: $git_commit_count
  - 推定 phase: <推定値>
```

AskUserQuestion で「推定 phase で再開 / 別 phase を選ぶ / 中止」を提示。

判定結果を LLM が prose 推論で確定したら、`$resolved_phase` シェル変数を set してから以下を実行し、Phase 5.2 が読む `[CONTEXT] RESOLVED_PHASE` marker を emit する (Bash tool 境界でシェル状態は失われるため、後段 step は marker 経由でしか値を取れない):

```bash
# resolved_phase は本 Phase 3.5 の判定結果 (v3 enum 13 値のいずれか) を代入
# 例: resolved_phase="implement"
echo "[CONTEXT] RESOLVED_PHASE=$resolved_phase"
```

### 3.6 未完了事項の検出（the governing rationale、`resolved_phase` が `cleanup`/`completed` のときのみ、informational）

当該 Issue が既に cleanup 段階を終えている（= これ以上 phase を進める作業は無い）場合に限り、過去の cleanup が非ブロッキングで残した可能性のある 2 種類の signal を git 実態から直接検出する（新しい記録先は持たない — 集約記録のありか自体が git/リモートの実態であり、既存の `.rite/wiki-worktree` / ローカルブランチ / `gh pr view` 以上のものを要求しない）。Phase 3.5 のフラグ判定・Phase 5.3 のルーティング表には影響しない、純粋な追加情報。

> **重要 — Bash tool 境界での変数消失**: 本 step は Phase 3.5 とは別の Bash tool 呼び出しのため、`$resolved_phase` / `$issue_arg` をシェル変数として直接参照できない（Phase 5.2「Bash tool 境界での変数消失」の注記と同じ制約）。LLM は Phase 3.5 の `{resolved_phase}` と Phase 1.1 の `{issue_arg}` を会話コンテキストから読み、下記 bash block 内の placeholder を実値に置換してから実行すること。

```bash
if [ "{resolved_phase}" = "cleanup" ] || [ "{resolved_phase}" = "completed" ]; then
  state_root=$(bash {plugin_root}/hooks/state-path-resolve.sh 2>/dev/null) || state_root=""
  [ -n "$state_root" ] || { echo "WARNING: state-path-resolve.sh の解決に失敗。cwd をフォールバック使用します" >&2; state_root="$(pwd)"; }
  wiki_wt="$state_root/.rite/wiki-worktree"
  if [ -d "$wiki_wt" ]; then
    wiki_branch_probe=$(git -C "$wiki_wt" branch --show-current 2>/dev/null || echo "")
    if [ -n "$wiki_branch_probe" ]; then
      if ! git -C "$wiki_wt" rev-parse -q --verify "origin/$wiki_branch_probe" >/dev/null 2>&1; then
        # origin に対応 ref が無い = push が一度も成功していない（最悪ケース）。fail-safe に検出側へ倒す
        echo "[CONTEXT] RECOVER_OUTSTANDING_WIKI=1; branch=$wiki_branch_probe; reason=no_remote_ref"
      else
        unpushed=$(git -C "$wiki_wt" log "origin/$wiki_branch_probe..HEAD" --oneline 2>/dev/null)
        [ -n "$unpushed" ] && echo "[CONTEXT] RECOVER_OUTSTANDING_WIKI=1; branch=$wiki_branch_probe; reason=unpushed_commits"
      fi
    fi
  fi
  stale_branch=$(git branch --list "*/issue-{issue_arg}-*" --format='%(refname:short)' 2>/dev/null | head -1)
  if [ -n "$stale_branch" ]; then
    br_pr_state=$(gh pr view "$stale_branch" -R {owner_repo} --json state --jq '.state' 2>/dev/null || echo "NONE")
    [ "$br_pr_state" != "OPEN" ] && echo "[CONTEXT] RECOVER_OUTSTANDING_BRANCH=1; branch=$stale_branch"
  fi
fi
```

`[CONTEXT] RECOVER_OUTSTANDING_WIKI=` / `RECOVER_OUTSTANDING_BRANCH=` marker のいずれかがあれば、Phase 4.1 の状態サマリに以下を追記する（無ければ追記しない — silent、AC-3 相当の「なし」を明示するのは cleanup 自身の完了報告の責務であり、本節は検出のみ）:

```
⚠️ 未完了事項を検出しました:
  - (RECOVER_OUTSTANDING_WIKI=1 のとき) Wiki commit が origin へ未 push です。手動回復: git -C .rite/wiki-worktree push origin {branch}
  - (RECOVER_OUTSTANDING_BRANCH=1 のとき) ローカルブランチ {branch} が残っています（対応する PR は OPEN ではありません）。不要なら削除: git branch -D {branch}
```

---

## Phase 4: Resume 確認

### 4.1 状態サマリ表示

```
=== 中断状態 ===
Issue: #{issue_arg} ({title})
Branch: {git_branch}
Phase: {resolved_phase} ({cross-check 結果})
Parent Issue: {state_parent_display}
PR: #{pr_number} ({pr_state}, draft={pr_is_draft})
Commits ahead of {base_branch}: {git_commit_count}
Uncommitted changes: {git_has_uncommitted: "あり" or "なし"}
Next action (state): {state_next}
Next action (WM):    {wm_next}
Stop reason:         {state_stop_reason: empty のとき「なし（通常の中断）」}
```

### 4.2 ユーザー確認

AskUserQuestion で:
- **続行 (推定 phase で再開)** — 推定された phase に対応する Step / Skill を実行
- **別 phase を選ぶ** — phase 一覧から手動選択
- **新規セッション扱い** — flow-state をクリアして `/rite:open {issue_arg}` を最初から実行
- **中止** — 何もせず終了

ユーザーが「別 phase を選ぶ」を選択し phase を変更した場合は、新値を `$user_selected_phase` シェル変数に set した上で以下を実行し、Phase 5.2 が優先採用する `[CONTEXT] FINAL_PHASE` marker を emit する (RESOLVED_PHASE をオーバーライドする最終確定値):

```bash
# user_selected_phase は AskUserQuestion で user が選んだ v3 enum 値
# 例: user_selected_phase="lint"
echo "[CONTEXT] FINAL_PHASE=$user_selected_phase"
```

「続行」を選んだ場合 (= Phase 3.5 の RESOLVED_PHASE を採用) は FINAL_PHASE を emit せず、Phase 5.2 は RESOLVED_PHASE marker をそのまま使う。

---

## Phase 5: 再開実行

### 5.1 ブランチ切り替え（worktree モードでは検証のみ）

`WT_ENSURE=reenter` / `reconstructed`（Phase 3.1.5 で worktree へ再入場・再構築済み。`already_in` も worktree モード）では、worktree の HEAD は既に state branch を指しているはずなので **`git switch` は行わず検証のみ**にする（worktree 内から base への switch は不可かつ不要）。不一致は WARNING に留める:

```bash
if [ "$RESUME_WT_MODE" = "worktree" ]; then
  # worktree モード: 検証のみ（WT_ENSURE が already_in/reenter/reconstructed だったケース）
  cur=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || cur=""
  if [ -n "$state_branch" ] && [ "$cur" != "$state_branch" ]; then
    echo "WARNING: worktree のカレントブランチ ($cur) が state branch ($state_branch) と不一致です。手動で git switch '$state_branch' を確認してください。" >&2
  fi
elif [ -n "$state_branch" ] && [ "$git_branch" != "$state_branch" ]; then
  # 従来モード: 切り替え
  git switch "$state_branch" || {
    echo "ERROR: ブランチ切り替え失敗: $state_branch" >&2
    exit 1
  }
fi
```

> `RESUME_WT_MODE` は Phase 3.1.5 の `[CONTEXT] WT_ENSURE=` marker が `already_in` / `reenter` / `reconstructed`（= worktree に入った / 再構築した）のとき `worktree`、それ以外（`disabled`（従来分岐） / `residue` / `branch_other_worktree` / `branch_absent` / `failed`（= worktree に入っていない。停止 or 新規セッション扱いへ分岐）のとき空として LLM が置換する。

### 5.2 flow-state の active=true 復元

中断時 (例: クラッシュ / context 枯渇) で active=false になっている可能性があるため、resume では active=true に復元。merge semantics により他のフィールドは保持される。

> **重要 — Bash tool 境界での変数消失**: 本 step は Phase 3.1 とは別の Bash tool 呼び出しとなるため、`$state_phase` / `$resolved_phase` / `$state_next` 等のシェル変数を直接参照できない (Claude Code の Bash tool 境界でシェル状態は失われる)。LLM は Phase 3.1 末尾で stdout に emit された `[CONTEXT] STATE_PHASE=...` / `[CONTEXT] STATE_NEXT=...` marker と Phase 3.5 の cross-check 結果 `{resolved_phase}` を読み、下記 bash block 内の placeholder を実値に置換してから実行すること。`--if-exists` フラグにより flow state file 不在時は no-op (idempotent)、merge semantics により未指定フィールドは既存値を保持する:

```bash
# Placeholder substitution rule:
#   {resolved_phase} → 最新の [CONTEXT] FINAL_PHASE marker (Phase 4.2 で user が phase 変更を選んだ場合に emit される)、
#                      無ければ [CONTEXT] RESOLVED_PHASE marker (Phase 3.5 cross-check の確定 phase)
#   {state_next}     → Phase 3.1 [CONTEXT] STATE_NEXT marker の値 (空なら "resume from {resolved_phase}" を代入)
# {resolved_phase} が空の場合 (flow-state 不在 + WM 不在 + git/PR 推定も不可能 → Phase 3.5 で `init` 採用)
# でも `--if-exists` により file 不在なら no-op となるため、unconditional 呼び出しで安全。
bash {plugin_root}/hooks/flow-state.sh set \
  --phase "{resolved_phase}" \
  --next "{state_next}" \
  --active true --if-exists
```

### 5.3 Phase enum → Step mapping (SoT)

| phase | 再開アクション |
|-------|---------------|
| `init` | `/rite:open {issue_arg}` をステップ 1 (Issue 取得) から再実行 (idempotent) |
| `branch` | `/rite:open {issue_arg}` をステップ 2 (ブランチ作成) から再開 (既存ブランチがあれば `git switch` で復帰) |
| `plan` | `/rite:open {issue_arg}` をステップ 3 (実装計画) から再開 |
| `implement` | `/rite:open {issue_arg}` をステップ 4 (実装) を継続 — 内部で `rite:issue-implement` を invoke し Issue body の checklist 未完項目から再開 |
| `lint` | `/rite:open {issue_arg}` をステップ 5 (lint 再実行) から再開 |
| `pr` | `/rite:open {issue_arg}` をステップ 6 (PR 作成) から再開 (既に PR 番号が state にあれば検出して `[pr:created:N]` 相当を再構成) |
| `review` | `/rite:iterate {pr_number}` を起動 (review 側から再開) |
| `fix` | `/rite:iterate {pr_number}` を起動 (fix 側から再開) |
| `ready` | `/rite:ready {pr_number}` をステップ 3 から再開 (Ready 化は完了済 — Projects Status In Review → 親判定 → 完了レポート) |
| `ready_error` | `/rite:ready {pr_number}` を ready 化リトライから再開 |
| `cleanup` | `/rite:cleanup {pr_number}` を再実行 |
| `ingest` | `/rite:wiki-ingest` を再呼び出し |
| `completed` | Issue は完結済。AskUserQuestion で「新規作業として再開 / 終了」 |

### 5.4 invoke

確定した phase に応じて Skill ツール経由で対応コマンドを呼ぶ。引数として `{issue_arg}` (`open`) または `{pr_number}` (`iterate` / `ready` / `cleanup`) を渡す。

`/rite:open` は内部の Resume Dispatch (ステップ 0) で `[CONTEXT] RESUME_DISPATCH=1; phase=$resolved_phase; issue=$issue_arg` を観測し、適切な step にジャンプする。`/rite:iterate` は phase に応じて review / fix のどちら側からループを始めるかを自動判定する。

---

## Phase 5.5: Active Batch 検出 → 継続

Phase 5.4 の invoke が制御を返したら（再開先 skill が完了通知 or 終端 sentinel を emit した後）、**自セッションの** run-queue（`run-queue-{session_id}.json`）を参照し「この中断が `/rite:batch-run` 実行中の active batch 中断だったか」を判定する。stale な残骸（過去に完了/停止済みのバッチのキューが単に残っている）を誤って継続しないよう、鮮度判定を必須とする。session_id は batch-run と同じく `flow-state.sh path` の basename から導出する。recover は flow-state phase も ambient session_id で解決する（Phase 3 の `flow-state.sh get`）ため、真の active batch 中断（同一セッションでの compact / turn 跨ぎ）では recover の session_id と run-queue の session_id が一致し、自セッションのキューだけを参照する（他セッションのキューは別ファイルのため構造的に読まない、the governing rationale）。

### 5.5.1 判定

鮮度判定は既存の staleness 判定ヘルパー `parse_iso8601_to_epoch`（[`hooks/session-ownership.sh`](../../hooks/session-ownership.sh)）と同じ 2 時間 (7200 秒) 閾値を再利用する（`issue-claim.sh` / `wiki-ingest-lock.sh` と同じ閾値。新しい定数は増やさない）:

```bash
state_root=$(bash {plugin_root}/hooks/state-path-resolve.sh)
fs_path=$(bash {plugin_root}/hooks/flow-state.sh path)
session_id=$(basename "$fs_path" .flow-state)
queue_file="$state_root/.rite/state/run-queue-$session_id.json"
source {plugin_root}/hooks/session-ownership.sh

# session_id 解決不可（空）→ 自セッションのキューを特定できないため継続なし（read-only 安全側。
# fail-loud はせず通常の recover 完了へ倒す）
if [ -z "$session_id" ] || [ ! -f "$queue_file" ]; then
  echo "[CONTEXT] BATCH_CONTINUE=none; reason=no_queue_file"
else
  q_active=$(jq -r '.active // false' "$queue_file")
  q_cursor=$(jq -r '.cursor // 0' "$queue_file")
  q_total=$(jq -r '.issues | length' "$queue_file")
  q_cursor_issue=$(jq -r ".issues[$q_cursor] // 0" "$queue_file")
  q_updated_at=$(jq -r '.updated_at // ""' "$queue_file")
  q_mode=$(jq -r '.mode // "default"' "$queue_file")

  if [ "$q_active" != "true" ]; then
    echo "[CONTEXT] BATCH_CONTINUE=none; reason=inactive"
  elif [ "$q_cursor_issue" != "{issue_arg}" ]; then
    echo "[CONTEXT] BATCH_CONTINUE=none; reason=cursor_mismatch; cursor_issue=$q_cursor_issue"
  elif [ -z "$q_updated_at" ]; then
    # updated_at 欠落 (旧形式 run-queue) = 鮮度不明として安全側 stale 扱い (AC-6)
    echo "[CONTEXT] BATCH_CONTINUE=none; reason=stale_no_timestamp"
  else
    state_epoch=$(parse_iso8601_to_epoch "$q_updated_at")
    now_epoch=$(date +%s)
    diff_seconds=$((now_epoch - state_epoch))
    if [ "$state_epoch" -eq 0 ] || [ "$diff_seconds" -gt 7200 ]; then
      echo "[CONTEXT] BATCH_CONTINUE=none; reason=stale; age_seconds=$diff_seconds"
    else
      remaining=$((q_total - q_cursor - 1))
      echo "[CONTEXT] BATCH_CONTINUE=eligible; mode=$q_mode; remaining=$remaining; total=$q_total"
    fi
  fi
fi
```

`{issue_arg}` は Phase 1.1 の確定値（引数 or ブランチ名抽出）をリテラル置換する。

> 鮮度判定は `updated_at`（batch-run が cursor 前進 / active 設定を書き込んだ最終時刻）に依拠する。1 件目の Issue 処理自体が 2 時間を超えて中断した場合は stale と誤判定されうるが、これは仕様の許容範囲とする（`updated_at` の更新ポイントをこれ以上増やさない — シンプルさ優先）。

### 5.5.2 分岐

| `BATCH_CONTINUE` | アクション |
|---|---|
| `none; reason=no_queue_file` | 通常の recover として完了（Phase 6 へ）。追記なし（AC-3） |
| `none`（その他の reason） | 通常の recover として完了（Phase 6 へ）。完了レポートに「自セッションの run-queue に残存キューがあります。`/rite:batch-run` で状況を確認/再開できます」の 1 行を追記する（AC-2, AC-4, AC-6） |
| `eligible` | 「この Issue は `/rite:batch-run` 実行中の中断と判定したため、残り {remaining} 件のキュー処理を継続します」と通知した上で 5.5.3 へ進む（AC-1） |

<!-- run orchestration: after emitting the eligible notification, do NOT stop — proceed directly to 5.5.3 (resolved_phase 分岐の invoke)。batch-run 側にこの継続を担う handoff/Stop-hook は無いため、recover 自身が flat 構造 + 本 HTML hint で継続を保証する（batch-run の「エラー時の方針」節・「設計判断: handoff 不使用」節と同じ理由）。 -->

### 5.5.3 継続実行（batch-run の該当ステップへの委譲、DRY）

Phase 5.4 で resume した個別スキルの終端状態を、[`skills/batch-run/SKILL.md`](../batch-run/SKILL.md) の該当ステップの分岐表に**そのまま適用**する（recover は batch-run のこの分岐ロジックを複製しない）。`{run_mode}` は 5.5.1 の `q_mode`、`{branch_name}` は `{git_branch}`（Phase 3.2）を使う。`{pr_number}` は resolved_phase が open 系（下表）のときは Phase 5.4 の `/rite:open` invoke が返す新規 PR 番号（`[pr:created:N]` sentinel）を使う。それ以外は Phase 3.3 の既存 `{pr_number}` を使う（open 系はまだ PR が無い時点の Phase 3.3 値 = 0/NONE のため使えない）。batch-run 側の分岐表・failed 記録 bash が参照する `{current_issue}` は、本 Phase では 5.5.1 の `{issue_arg}`（= Phase 1.1 で確定した対象 Issue）と同一の値を指す。

`{resolved_phase}`（Phase 3.5 / 4.2 で確定した値）で分岐:

| `{resolved_phase}` | Phase 5.4 が invoke した内容 | Phase 5.5.3 のアクション |
|---|---|---|
| `init` / `branch` / `plan` / `implement` / `lint` / `pr` | `/rite:open {issue_arg}`（draft PR 作成まで） | Phase 5.4 の open invoke 結果を batch-run [ステップ 2](../batch-run/SKILL.md) の表と同じ基準で判定する。**成功**（`[pr:created:N]` sentinel + ブランチ行）: `{pr_number}` を取得し、続けて `/rite:iterate {pr_number}` を invoke（= batch-run [ステップ 3](../batch-run/SKILL.md) 相当）。終端 sentinel を同ステップ 3 の表で判定し、以降 `{run_mode}=merge` かつ mergeable ならステップ 4-6、`default` ならステップ 6 のカーソル前進へ直行。**失敗**（`[pr-create-failed]` / PR 番号なし / sentinel 不在）: iterate を invoke せず、下記「failed 記録 / 停止方針の委譲」の失敗停止経路（batch-run ステップ 8 相当）に直行する |
| `review` / `fix` | `/rite:iterate {pr_number}`（終端 sentinel まで） | **再 invoke しない**。Phase 5.4 で得た終端 sentinel を batch-run [ステップ 3](../batch-run/SKILL.md) の表で判定し、以降は上記と同じ分岐 |
| `ready` / `ready_error` | `/rite:ready {pr_number}` | Phase 5.4 の ready invoke 結果を batch-run [ステップ 4](../batch-run/SKILL.md) の表と同じ基準で判定する。**成功**（`[ready:returned-to-caller]`）: `{run_mode}=merge` なら続けて `/rite:merge {pr_number}` → `/rite:cleanup {branch_name}` を invoke（batch-run [ステップ 5-6](../batch-run/SKILL.md) と同じ判定）。`default` は通常到達しない（ready は batch-run の merge モードでのみ実行されるため）— 到達した場合は安全側としてそのままステップ 6 のカーソル前進へ。**失敗**（`[ready:error]` / sentinel 不在）: merge/cleanup を invoke せず、下記「failed 記録 / 停止方針の委譲」の失敗停止経路（batch-run ステップ 8 相当）に直行する |
| `cleanup` / `ingest` | `/rite:cleanup {branch_name}` または `/rite:wiki-ingest` | 当該 Issue は既に完了。追加 invoke はしないが、Phase 5.4 の `/rite:cleanup` invoke が `[cleanup:returned-to-caller]` を返した場合は batch-run [ステップ 6](../batch-run/SKILL.md) の outstanding 記録 bash（`[cleanup:outstanding:N]` sentinel を読んで `run-queue-{session_id}.json` の `outstanding[]` へ記録）を**先に実行してから**カーソル前進 bash へ進む（the governing rationale: この記録を経由しないと、recover 経由の active batch 継続で cleanup が残した非ブロッキング失敗が run-queue に記録されず、batch-run ステップ 7 の完了通知ロールアップから欠落する）。`/rite:wiki-ingest` 経由（`resolved_phase=ingest`）はこの sentinel を持たないため対象外、そのままカーソル前進へ |
| `completed` | (Phase 5.4 は既存表により AskUserQuestion のみ) | ユーザーが「終了」を選んだ場合はカーソル前進へ、「新規作業として再開」を選んだ場合は本継続を中止（通常の recover 完了とする） |

<!-- run orchestration: after invoking per the table above and observing the terminal sentinel, do NOT stop — proceed to the failed-record / stop-policy paragraph below (same routing as batch-run ステップ 3-8). -->

**failed 記録 / 停止方針の委譲**: サーキットブレーカー（`[iterate:max-cycles-reached]`）は batch-run [ステップ 6](../batch-run/SKILL.md) の failed 記録 bash と同じ操作で `run-queue-{session_id}.json` の `failed[]` に記録してからカーソル前進へ進む（即停止しない）。それ以外の失敗 sentinel（`[pr-create-failed]` / `[fix:error]` / `[ready:error]` / `[merge:error]` / `[merge:not-ready]` / sentinel 不在 等）は batch-run [ステップ 8](../batch-run/SKILL.md) と同じ「即停止して報告」方針に従う（AC-5）。停止時は `run-queue-{session_id}.json` の `active` を `false` にする（batch-run ステップ 8 と同一操作。キュー本体は削除しない）。

<!-- run orchestration: 直前の paragraph の2分岐のうち「即停止して報告」側に分岐した場合は STOP — 以降の「active 維持」「カーソル前進とループ」paragraph には進まない（cursor advance を経由しない）。同 paragraph 内でカーソル前進に進むのはサーキットブレーカー分岐のみ（batch-run ステップ 6/8 と同じ非対称性）。当該 Issue が正常完了した場合は本 STOP の対象外で、下記「カーソル前進とループ」paragraph からカーソル前進に進む（通常経路）。 -->

**active 維持**: 継続処理中は `run-queue-{session_id}.json` の `active=true` を維持する（`/rite:iterate` ステップ 6 の既存 batch 判定が `active` を参照するため — 変更禁止の非対象ファイル）。`active=false` にするのは上記の失敗停止時のみ。

**カーソル前進とループ**: サーキットブレーカーで failed 記録した場合、または当該 Issue が正常に完了した場合、batch-run [ステップ 6](../batch-run/SKILL.md) のカーソル前進 bash（`updated_at` も更新）を実行する（即停止経路はこの bash を経由しない）。`cursor < total` なら batch-run [ステップ 1](../batch-run/SKILL.md) と同じ「次の Issue を取り出す」ループに入る（以降は通常の `/rite:batch-run` 実行と同一）。`cursor >= total` なら batch-run [ステップ 7](../batch-run/SKILL.md) の全完了通知を出す。

<!-- run orchestration: after this cursor advance, do NOT stop — loop back to batch-run ステップ 1 (次の Issue) or go to batch-run ステップ 7 (全完了通知)。即停止（ステップ8）はこの cursor advance を経由しない — 上の「failed 記録 / 停止方針の委譲」paragraph で即停止と判定した時点で直接ステップ8へ遷移し、本カーソル前進 bash は実行しない。 -->

---

## Phase 6: 完了（`BATCH_CONTINUE=none` の場合）

再開後の最初のサイクルが完了するまで、再開した skill に制御を委譲する。再開先の skill は flow-state を順次更新し、最終的に `completed` または `cleanup` 状態に到達する。`BATCH_CONTINUE=eligible` だった場合は本 Phase ではなく Phase 5.5.3 の完了経路（batch-run ステップ 7 の全完了通知 or ステップ 8 の停止報告）で終了する。

---

## エラー処理

| 状況 | 対応 |
|------|------|
| Issue not found | エラー終了、`gh issue list -R {owner_repo}` で確認するよう案内 |
| Branch 不在 | `gh issue develop -R {owner_repo}` で再生成するよう案内 |
| flow-state 不在 + WM 不在 | 「新規セッション」として `/rite:open {issue_arg}` を提案 |
| 矛盾検出 (phase vs commit/PR) | AskUserQuestion で「推定 phase で再開 / 別 phase を選ぶ / 中止」 |
| migrate 失敗 | WARNING 表示後、cross-check で実態推定して続行 |

---

## Phase enum 13 個 (SoT)

新 v3 schema の phase enum (`flow-state.sh` 内 `PHASE_ENUM_V3` と同期):

```
init / branch / plan / implement / lint / pr / review / fix / ready /
ready_error / cleanup / ingest / completed
```

旧 v1/v2 schema の phase 値 (`cleanup_pre_ingest`, `ingest_pre_lint`, `create_*`, `implementing` 等) は Phase 2 の自動 migration で v3 に変換される。Migration の reduction matrix は `plugins/rite/hooks/flow-state.sh` の `_phase_migrate` 関数を参照。

なお `phase5_*` 系の legacy 名 (pre-v3 の sub-skill chain アーキテクチャが書き込んだ古い state file に残存しうる) は `_phase_migrate` の reduction matrix に **含まれず pass-through される**。これらは PHASE_ENUM_V3 (13 個) に該当しないため Phase 2 migration では変換されず、Phase 3.5 の整合性判定 (cross-check) で再開 phase が確定される (cross-check は rule 1 で v3 enum 値のみを直接採用するため、非 v3 enum の legacy 値はそのまま採用されず、cross-check の判定を経て v3 phase へ解決される)。
