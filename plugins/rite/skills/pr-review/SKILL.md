---
name: pr-review
description: |
  rite workflow のマルチレビュアー PR レビュー sub-skill: 複数の専門 reviewer agent を並列起動し、
  指摘を統合・検証して mergeable 判定を出す。/rite:iterate ループ内から programmatic に呼ばれる
  （ユーザーは直接起動せず /rite:iterate 経由）。汎用の「コードレビュー」ヘルパーではなく、その語では auto-activate しない。
argument-hint: "[pr_number]"
user-invocable: false
---

# /rite:pr-review

PR の変更内容を解析し、専門家スキルを動的にロードしてマルチレビュアー方式でレビューを行う。やることは以下のシーケンシャルなタスク列:

0. Work Memory のロード (E2E フロー時のみ)
1. 準備 (PR cycle cleanup / argument parse / PR 情報取得 / changed files)
2. レビュアー選定 (Progressive Disclosure)
3. 動的レビュアー数決定
4. 並列レビュー実行 (Generator フェーズ)
5. 結果検証と統合 (Critic フェーズ)
6. 結果出力
7. スコープ外指摘のトリアージ
8. E2E フロー継続 (出力パターン)

途中で止まったら flow-state に `phase=review` が残るので `/rite:recover` で再開する。

本コマンドはレビュー専用 (READ-ONLY): `Edit`/`Write` でソース修正禁止。`Bash` は workflow 操作と read-only な git コマンドのみ許可 (完全な許可・禁止一覧は [`_reviewer-base.md#read-only-enforcement`](../../agents/_reviewer-base.md#read-only-enforcement) を SoT として参照)。問題検出時は `[review:fix-needed:{n}]` を emit し修正は `/rite:fix` に委譲する。

呼び出し回数・context 残量・前回レビュー結果の有無に **一切関係なく** 常にフルレビューを実行する。スコープ縮退、レビュアー数削減、Verification mode への暗黙フォールバック、品質と context 効率のトレードオフは禁止 (Identity: [workflow-identity.md](../../skills/rite-workflow/references/workflow-identity.md))。再レビュー (fix 後) も初回と完全同等の品質で全レビュアー並列起動 + PR 全体差分を対象にフルレビューする。

Hooks registration (`.claude/settings.local.json`) はチェックしない (`/rite:setup` の専管)。本コマンドは hooks 関連の WARNING を出さない。

`{plugin_root}` は [Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script-full-version) で解決する。

## Contract

**Input**: PR number (or auto-detected from current branch), flow state with `phase: review` (written by `skills/iterate/SKILL.md` review side) or `phase: phase5_review` (legacy compat — sub-skill still patches the old name so resume from an interrupted earlier session keeps working until every writer migrates off the legacy name)
**Output**: `[review:mergeable]` | `[review:fix-needed:{n}]`

## Prerequisites

bash 4.0+ 必須 (`mapfile` builtin の存在を bash 4+ 判定に使用。ステップ 1.2.7 の doc-heavy 検出簡素化により本体側の `mapfile` データ利用箇所は Issue #1881 で撤去済みだが、guard 自体は他の bash 4+ 機能の baseline として維持する)。ステップ 1.0 の統合 bash block 冒頭 (Step 0) に [bash-compat-guard.md](../../references/bash-compat-guard.md) の canonical guard を inline embed 済み (C-3 対応)。失敗時は `[CONTEXT] REVIEW_ARG_PARSE_FAILED=1; reason=bash_version_incompatible` を emit して `[review:error]` で exit する。

## E2E Output Minimization

`/rite:iterate` E2E flow から呼ばれた時、ステップ 4 (sub-agent execution) は **full execution**、ステップ 5-7 の **人間向け出力** のみ minimize する。minimize されるのは出力のみで、sub-agent parallel execution / PR コメント投稿 / recommendations AskUserQuestion 等の処理本体は standalone と同等に実行する (時間・context を理由にした sub-agent 省略 / parallel 直列化 は identity 違反)。

**AskUserQuestion の扱いは 2 種を区別する（#1861）**: ステップ 7 の recommendations トリアージ（結果整合性 = 未解決指摘・スコープ外指摘の握り潰し防止）は E2E でも **skip 禁止**（省略は identity 違反）。一方 ステップ 3.3 の pre-flight レビュアー構成確認は E2E で **skip 可**（iterate の自律ループ設計に合わせ flow-state ベース判定で機械的に skip する。詳細はステップ 3.3）。いずれの場合も `起動 reviewer {count} 名` サマリ行・省略された reviewer 表示・ステップ 4 のフルレビュー実行は省略しない。

| Phase | Standalone | E2E Flow |
|-------|-----------|----------|
| ステップ 3.3 (Confirm Reviewers) | `AskUserQuestion` で構成確認 | **`AskUserQuestion`（オプション選択）を skip**（pre-flight 確認のみ。flow-state ベース判定はステップ 3.3 参照）。`起動 reviewer {count} 名` サマリ行・省略された reviewer 表示は両経路で必須維持 |
| ステップ 4 (Sub-Agent Execution) | Full execution | **Full execution** — sub-agents MUST run in parallel for every review cycle (including verification mode). No shortcut allowed. |
| ステップ 5 (Consolidation) | Full findings table | Result pattern + summary counts only。**例外: ステップ 5.4 の `### 実測なし指摘 (non-blocking)` section は `non_blocking_count > 0` のとき E2E でも省略禁止** (ステップ 7 AskUserQuestion と同じ identity 制約 — 既定 `post_comment: false` ではこの出力が非実測指摘を人間が見る唯一の同期経路であり、省略は Issue #2024 D-01「破棄しない」の喪失に直結する) |
| ステップ 6 (PR Comment) | Full comment + display | Post comment silently, output pattern only |
| ステップ 7 (Triage) | Full report + guidance | **Recommendations only** — detect scope-irrelevant recommendations (findings/recommendations containing 別 Issue / スコープ外 keywords). **Always** prompt `AskUserQuestion` for each candidate (no E2E skip). Only when `[review:mergeable]`. |

E2E output format (ステップ 6, replaces full display):

```
[review:{result}:{n}] — {total_findings} findings ({critical} CRITICAL, {high} HIGH, {medium} MEDIUM, {low_medium} LOW-MEDIUM, {low} LOW) | non-blocking: {non_blocking_count} | fact-check: {v}✅ {c}❌ {u}⚠️
```

`| non-blocking: {n}` suffix は `non_blocking_count > 0` のときのみ付与する (実測必須ゲートで降格した件数。0 件のときは suffix ごと省略し従来の出力形式と一致させる)。`| fact-check: ...` suffix は fact-check が実行された場合のみ (external claims > 0) 付与。`{total_findings}` は post-fact-check カウント (CONTRADICTED と UNVERIFIED:ソース未確認 除外)。Detection: 後述の "Invocation Context and End-to-End Flow" 節の判定ロジックを再利用する。

> **Reference**: Apply `push_back_when_warranted` from [AI Coding Principles](../../skills/rite-workflow/references/coding-principles.md). 問題実装に対し代替案付きで push back する。
> **Reference**: Apply `no_unnecessary_fallback` from [AI Coding Principles](../../skills/rite-workflow/references/coding-principles.md). 失敗原因を隠したり silent に scope を変える fallback を flag する。

## Invocation Context and End-to-End Flow

本コマンドは standalone と `/rite:iterate` ステップ 1 review-fix loop からの E2E 呼び出しの 2 経路がある。

| Invocation Source | Subsequent Action |
|-----------|---------------|
| End-to-end flow (invoked from `/rite:iterate` ステップ 1) | **Output pattern and return control to caller** |
| Standalone execution | Confirm the next action with `AskUserQuestion` |

Claude は conversation context から `rite:pr-review` が同一セッション内で直前に Skill ツール経由で invoke されたかどうかで判定する。前者は E2E、それ以外は standalone。E2E 時は machine-readable output pattern (`[review:mergeable]` / `[review:fix-needed:{n}]`) を emit し caller (`/rite:iterate`) に制御を返す。caller が output pattern を見て次のアクションを決定する。

## Arguments

| Argument | Description |
|------|------|
| `[pr_number]` | PR number (省略時は現在のブランチの PR を auto-detect) |

---

## ステップ 0: Work Memory のロード (E2E フロー時のみ)


When executed within the end-to-end flow, load necessary information from work memory (shared memory).

### 0.1 End-to-End Flow Determination

Determine the invocation source from the conversation context:

| Condition | Determination | Action |
|------|---------|------|
| Conversation history has rich context from `/rite:pr-create` | Within the end-to-end flow | PR number can be obtained from conversation context |
| `/rite:pr-review` was executed standalone | Standalone execution | Obtain from argument or current branch PR |

---

## ステップ 1: 準備

### 1.0.0 PR Cycle Branch Cleanup (Pre-Review)

Run at every review entry (both end-to-end and standalone) to recover from prior cycles that left residual `pr-{N}-cycle{X}` worktrees / branches. Reviewers run under READ-ONLY enforcement and cannot self-clean (`agents/_reviewer-base.md` § READ-ONLY Enforcement). Cleanup is non-blocking — its failure must not halt the review.

```bash
# {plugin_root} はリテラル値で埋め込む (詳細は ../../references/plugin-path-resolution.md)
bash {plugin_root}/hooks/scripts/pr-cycle-cleanup.sh 2>&1 || true
```

**Placeholder legend:**
- `{pr_number}`: PR number (obtained from argument or `gh pr view` result)
- `{owner}`, `{repo}`: Repository information (obtained via `{plugin_root}/hooks/scripts/lib/git-remote.sh resolve-owner-repo`, fallback `gh repo view --json owner,name` — SSH host alias safe; canonical: [gh-cli-patterns.md](../../references/gh-cli-patterns.md#ownerrepo-resolution-ssh-host-alias-safe))
- `{owner_repo}`: [Owner/Repo Resolution](../../references/gh-cli-patterns.md#ownerrepo-resolution-ssh-host-alias-safe) で解決した owner/repo（slash 形式）を literal substitute（SSH host alias 環境対応。同節の Propagation 小節参照）
- `{post_comment_mode}`: Final decision whether to post PR comment (`true`/`false`), computed in ステップ 1.0 from flags + config
- Other `{variable}` formats: Values obtained from command execution results or previous phases

**Note**: All placeholders in this document use `{variable}` format. Unlike Bash shell variable format `${var}`, these are conceptual markers that Claude substitutes with values.

### 1.0 Argument Parsing (Pre-flight)


**Supported arguments**:

| Argument | Effect |
|----------|--------|
| `<pr_number>` (integer) | PR number (same as existing behavior) |
| `--post-comment` | Force PR comment posting (overrides config) |
| `--no-post-comment` | Force skip PR comment posting (overrides config) |
| (no flag) | Use `rite-config.yml` `pr_review.post_comment` value (default: `false`) |

**Parsing procedure**:


```bash
# ============================================================================
# ステップ 1.0: Argument parsing + conflict check + config read (unified block)
# ============================================================================
# 本 block は以下の 5 ステップを単一 Bash tool invocation で実行する:
# Step 0: bash 4+ compat guard (inlined from ../../references/bash-compat-guard.md)
# Step 1: flag 抽出 + remaining_args 生成
# Step 2: AC-8 conflict check (--post-comment と --no-post-comment 同時指定)
# Step 3: rite-config.yml の pr_review.post_comment 読取 (SIGPIPE-safe 単一 awk)
# Step 4: {post_comment_mode} の最終決定 + [CONTEXT] emit

# --- Step 0: bash 4+ compat guard (C-3: inlined from ../../references/bash-compat-guard.md) ---
# rationale: references/design-rationale.md#argument-parsing-notes
if ! command -v mapfile >/dev/null 2>&1; then
 bash_version=$("$BASH" --version 2>/dev/null | head -1)
 echo "ERROR: bash 4.0+ が必要ですが、現在のシェルは mapfile builtin を持っていません" >&2
 echo " 検出: $bash_version" >&2
 echo " 対処: macOS では brew install bash で 4+ をインストールし、PATH の先頭に追加してください" >&2
 echo "[CONTEXT] REVIEW_ARG_PARSE_FAILED=1; reason=bash_version_incompatible" >&2
 echo "[review:error]"
 exit 1
fi

# --- Step 1: flag 抽出 + remaining_args 生成 ---
original_args="$ARGUMENTS"
flag_post="false"
flag_no_post="false"

# フラグ検出 (順序問わず、space/tab 両対応 — `[[:space:]]` を sed 側除去処理と揃える)
if [[ " $original_args " =~ [[:space:]]--no-post-comment[[:space:]] ]]; then
 flag_no_post="true"
fi
if [[ " $original_args " =~ [[:space:]]--post-comment[[:space:]] ]]; then
 flag_post="true"
fi

# フラグトークンを remaining_args から除去 (sed -E で `(^|space)--flag(space|$)` を空文字置換)
remaining_args=$(printf '%s' "$original_args" \
 | sed -E 's/(^|[[:space:]])--no-post-comment([[:space:]]|$)/\1\2/g' \
 | sed -E 's/(^|[[:space:]])--post-comment([[:space:]]|$)/\1\2/g' \
 | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')

# --- Step 2: AC-8 conflict check ---
# 単一 block 化により Claude literal substitution が不要になった (C-4 対応)。
# flag_post / flag_no_post は Step 1 の bash 変数としてそのまま参照できる。
if [ "$flag_post" = "true" ] && [ "$flag_no_post" = "true" ]; then
 echo "エラー: --post-comment と --no-post-comment を同時に指定することはできません" >&2
 echo " 受信した引数: $ARGUMENTS" >&2
 echo "" >&2
 echo "対処:" >&2
 echo " 1. どちらか一方のみを指定してください" >&2
 echo " 2. 永続化するには rite-config.yml の pr_review.post_comment を設定:" >&2
 echo " - true: 常に PR コメントを投稿 (チームレビュー向け)" >&2
 echo " - false: デフォルトで投稿しない (個人ワークフロー向け — AC-1 デフォルト)" >&2
 echo " 3. コマンドライン引数は rite-config.yml の値を常に上書きします" >&2
 echo "[CONTEXT] REVIEW_ARG_PARSE_FAILED=1; reason=post_and_no_post_conflict" >&2
 echo "[review:error]"
 exit 1
fi

# --- Step 3: rite-config.yml の pr_review.post_comment 読取 (C-2: SIGPIPE-safe) ---
# 多段 pipeline は禁止 (SIGPIPE rc=141 で config が silent false 化する)
# rationale: references/design-rationale.md#argument-parsing-notes
repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || repo_root=""
config_post_comment="false"

if [ -z "$repo_root" ]; then
 echo "WARNING: git rev-parse --show-toplevel に失敗しました (現在地が git repo 内ではない可能性)。post_comment=false (default) で続行します" >&2
elif [ ! -f "$repo_root/rite-config.yml" ]; then
 echo "WARNING: $repo_root/rite-config.yml が見つかりません。post_comment=false (default) で続行します" >&2
else
 # 抽出は helper (実ファイル) に委譲する。skill 本文の fenced bash に awk を書くと、
 # Skill loader が位置パラメータを起動引数へ展開して行参照が壊れ、値が silent に空へ倒れる
 # (静的検出: hooks/scripts/dollar-zero-check.sh)。単一 awk / SIGPIPE 禁止契約は helper 側で維持
 helper_err=$(mktemp "${TMPDIR:-/tmp}/rite-review-helper-err-XXXXXX" 2>/dev/null) || helper_err=""
 if raw=$(bash {plugin_root}/hooks/scripts/pr-review-post-comment-read.sh "$repo_root/rite-config.yml" 2>"${helper_err:-/dev/null}"); then
 config_post_comment="$raw"
 else
 helper_rc=$?
 echo "WARNING: rite-config.yml の post_comment 読取 helper が失敗しました (rc=$helper_rc)" >&2
 echo " 原因候補: helper 解決不能 (rc=127、plugin path の解決失敗 / plugin 未配置) / 引数・ファイル不正 (rc=2) / awk バイナリ異常 / IO エラー" >&2
 [ -n "$helper_err" ] && [ -s "$helper_err" ] && head -3 "$helper_err" | sed 's/^/ /' >&2
 [ -z "$helper_err" ] && echo " (stderr 退避用 tempfile の mktemp に失敗したため helper の stderr は失われています)" >&2
 echo " default の false を使用します" >&2
 config_post_comment=""
 fi
 [ -n "$helper_err" ] && rm -f "$helper_err"

 # 不正値は WARNING 表示 (silent false 化禁止)。空文字のみ legitimate fallback として silent OK
 case "$config_post_comment" in
 true|yes|1) config_post_comment="true" ;;
 false|no|0) config_post_comment="false" ;;
 "") config_post_comment="false" ;;
 *)
 echo "WARNING: rite-config.yml の pr_review.post_comment に不正な値: '$config_post_comment'" >&2
 echo " 認識可能: true / yes / 1 / false / no / 0 (大文字小文字無視)" >&2
 echo " default の false を使用します" >&2
 config_post_comment="false"
 ;;
 esac
fi

# --- Step 4: Final decision + [CONTEXT] emit ---
# Precedence: --no-post-comment > --post-comment > config > default(false)
post_comment_mode="false"
if [ "$flag_no_post" = "true" ]; then
 post_comment_mode="false"
elif [ "$flag_post" = "true" ]; then
 post_comment_mode="true"
elif [ "$config_post_comment" = "true" ]; then
 post_comment_mode="true"
fi

echo "[CONTEXT] POST_COMMENT_MODE=$post_comment_mode" >&2
echo "[CONTEXT] REMAINING_ARGS=$remaining_args" >&2
```

**ステップ 1.1 への hand-off**: ステップ 1.1 の `{pr_number}` 抽出は **必ず `remaining_args` に対して行う** こと。`$ARGUMENTS` を直接参照すると未除去のフラグトークンを PR 番号候補と誤認するリスクがある。`{post_comment_mode}` は ステップ 6.1 で参照する Single Source of Truth。

**Final decision precedence**:

| Priority | Condition | `{post_comment_mode}` |
|----------|-----------|----------------------|
| 1 | `--no-post-comment` specified | `false` (highest priority — overrides config) |
| 2 | `--post-comment` specified | `true` |
| 3 | `pr_review.post_comment: true` in config | `true` |
| 4 | Default | `false` |

**ステップ 1.0 failure reasons**: (`bash_version_incompatible` / `post_and_no_post_conflict`)

| reason | Description |
|--------|-------------|
| `bash_version_incompatible` | Step 0 の `command -v mapfile` チェックが失敗 (bash 3.2 等の旧バージョン) |
| `post_and_no_post_conflict` | `--post-comment` と `--no-post-comment` が同時指定された (Step 2、AC-8 違反、`REVIEW_ARG_PARSE_FAILED=1` retained flag を emit して `[review:error]` で exit 1) |

**Eval-order enumeration** (Pattern-2 documented-union input): ステップ 1.0 emit sequence = (`bash_version_incompatible` / `post_and_no_post_conflict`)

### 1.1 Identify the PR

**Input**: `$remaining_args` を ステップ 1.0 Step 1 から引き継いだ値として参照する。**`$ARGUMENTS` を直接参照してはならない** — `$ARGUMENTS` は `--post-comment` / `--no-post-comment` 等のフラグトークンを含むため、PR 番号と誤認するリスクがある。ステップ 1.0 Step 1 で生成された `remaining_args` は flag tokens を除去済みで、PR 番号 / PR URL / 引数なしのいずれかが入る (ステップ 1.0 Step 1 末尾の note 参照)。

**PR number retrieval (priority order)**: 以下の順序で `{pr_number}` を解決する。各 priority は `$remaining_args` を入力源として参照する:

| Priority | Retrieval Method | Description |
|-------|---------|------|
| 1 | From `$remaining_args` | When explicitly specified (空でない場合) |
| 2 | **From work memory** | `$remaining_args` が空かつ work memory に "Related PR" → "番号" がある場合 |
| 3 | Search for PR on the current branch | Fallback ($remaining_args 空 + work memory なし) |

#### 1.1.1 Retrieving PR Number from Work Memory

If the argument is omitted, first retrieve the PR number from work memory.

**Steps:**

1. Extract the Issue number from the current branch:
 ```bash
 issue_number=$(git branch --show-current | grep -oE 'issue-[0-9]+' | grep -oE '[0-9]+')
 ```

2. If the Issue number was obtained, load work memory from local file (SoT):
 - Read `.rite-work-memory/issue-{issue_number}.md` with the Read tool
 - **Fallback** (local file missing/corrupt): Use Issue comment API:
 ```bash
 gh api repos/{owner}/{repo}/issues/{issue_number}/comments \
 --jq '[.[] | select(.body | contains("📜 rite 作業メモリ"))] | last | .body'
 ```

3. Extract the "Related PR" section from work memory and obtain the PR number:
 - Pattern: `- **番号**: #(\d+)`
 - If found, use that number as `{pr_number}`
 - **If multiple matches**: Use the first matching PR number (normally only one PR is recorded in work memory)

**If retrieved from work memory:**

```bash
gh pr view {pr_number} -R {owner_repo} --json number,title,body,state,isDraft,additions,deletions,changedFiles,files,headRefName,baseRefName,url
```

#### 1.1.2 Fallback (When Not Retrieved from Work Memory)

If a PR number is specified as an argument:

```bash
gh pr view {pr_number} -R {owner_repo} --json number,title,body,state,isDraft,additions,deletions,changedFiles,files,headRefName,baseRefName,url
```

If the argument is omitted and there is no PR number in work memory, identify the PR from the current branch:

```bash
git branch --show-current
# -R 指定時は selector が必須のため、現在のブランチ名を selector に渡す（従来どおり「現在ブランチの PR」を特定する）
gh pr view "$(git branch --show-current)" -R {owner_repo} --json number,title,body,state,isDraft,additions,deletions,changedFiles,files,headRefName,baseRefName,url
```

**If no PR is found:**

```
エラー: 現在のブランチに関連する PR が見つかりません

現在のブランチ: {branch}

対処:
1. `/rite:pr-create` で PR を作成
2. PR 番号を直接指定して再実行
```

Terminate processing.

**If the PR is closed/merged:**

```
エラー: PR #{number} は既に{state}されています

レビューは実行できません。
```

Terminate processing.

### 1.1.5 セッション worktree 健全性の保証（multi_session 有効時 / AC-1 #1676）

ステップ 1.2 以降は **作業ツリーから PR の変更ファイルを読む**。その前に対象 PR の作業ブランチに対応する session worktree を保証する。これがないと、worktree 不在（resume / context 圧縮 / 別セッション跨ぎで欠落）のとき review がメインツリー（develop）上で実行され、PR 変更を作業ツリーから読めず scratchpad へ退避する **degraded 動作**になる（本 Issue の As-Is）。

ステップ 1.1 で取得した PR の `headRefName`（作業ブランチ）から issue 番号を抽出し、共通ヘルパー `ensure_session_worktree`（[`lib/worktree-git.sh`](../../hooks/scripts/lib/worktree-git.sh)、検出 + 再構築を bash 側で完結し `[CONTEXT] WT_ENSURE=` を emit）で検出・再構築する（`{head_ref}` は ステップ 1.1 の `gh pr view` が返した `.headRefName`）:

```bash
issue_number=$(printf '%s' "{head_ref}" | grep -oE 'issue-[0-9]+' | grep -oE '[0-9]+')
if [ -n "$issue_number" ]; then
  bash {plugin_root}/hooks/scripts/lib/worktree-git.sh ensure-session-worktree --issue "$issue_number" --branch "{head_ref}"
else
  # head_ref が issue ブランチでない（session worktree の対象外）→ 従来どおり単一ツリーで続行
  echo "[CONTEXT] WT_ENSURE=skip (head_ref が issue ブランチでないため worktree 対象外: {head_ref})"
fi
```

`[CONTEXT] WT_ENSURE=` marker の分岐は [skills/recover/SKILL.md](../recover/SKILL.md) Phase 3.1.5 の **WT_ENSURE 分岐表（SoT）** に従う（`disabled`〜`reconstructed` の共通 case は SoT 表と同一。**終端の `branch_absent` / `failed` のみ caller 固有**で、recover の AskUserQuestion / 停止に対し、非対話サブ起動の review は機械的に `[review:error]` 停止する — 下記）:

- `disabled` / `already_in` / `skip` → no-op、ステップ 1.2 へ（`disabled` = `multi_session.enabled: false`。従来どおり単一ツリーで動作し挙動不変）。
- `reenter` / `reconstructed` → `EnterWorktree` ツールを `path: {path}`（marker の `path=` 値）で呼び出してからステップ 1.2 へ。`reconstructed` は helper が `git worktree add` 済み。EnterWorktree 失敗時の切り分けは recover.md Phase 3.1.5 / /rite:open Step 2.3-W と同じ（silent に新規扱いしない）。
- `residue` → AskUserQuestion（削除 `rm -rf {path}` して再実行 / 中止）。
- `branch_other_worktree` → 中止（並行セッションの可能性。`other=` のパスを表示）。
- `branch_absent` → 対象ブランチがローカル・リモートどこにも実在しない。誤再構築しない（AC-5）。ただし ステップ 1.1 で `gh pr view {pr_number}` が成功している以上、PR の head ブランチは本来 remote に存在するはずで、`branch_absent` の到達は PR 状態との不整合を意味する。**develop 上で review を続行せず**、`[review:error]` を emit して明示停止する（`failed` と同じ機械的停止。silent に develop の作業ツリーを読まない）。
- `failed` → 再構築失敗（helper rc=1, stderr に原因 + 復旧手順）。**silent fallback せず `[review:error]` を emit して明示停止**する（review を mergeable / completed 扱いにしない / AC-4）。

> **silent fallback 禁止（本 Issue の核）**: `branch_absent` / `failed` のとき、worktree 不在を理由に develop 上で review を継続し PR 変更を読めないまま完了扱いにしてはならない（§4.4 MUST NOT）。

### 1.2 Retrieve Changes

> **Reference**: See [Review Context Optimization](./references/review-context-optimization.md) for scale determination and diff retrieval strategies.

**Scale determination:**

Use the `additions`, `deletions`, and `changedFiles` values retrieved in ステップ 1.1.

Classify as Small (<= 500 lines, <= 10 files), Medium (<= 2000 lines, <= 30 files), or Large (> 2000 lines or > 30 files).

**Diff retrieval (guard-validated commands only — avoids patterns blocked by `pre-tool-bash-guard.sh`):**

Small scale: `gh pr diff {pr_number} -R {owner_repo}` (bulk retrieval)
Medium/Large scale: `gh pr view {pr_number} -R {owner_repo} --json files --jq '.files[].path'` (per-reviewer extraction in ステップ 4.3)

**File statistics:** `gh pr view {pr_number} -R {owner_repo} --json files --jq '.files[] | {path, additions, deletions}'`

**Per-file diff extraction:** `gh pr diff {pr_number} -R {owner_repo} | awk '/^diff --git/ { found=0 } /^diff --git.*{target_pattern}/ { found=1 } found { print }'`


#### 1.2.3 Retrieve Changed File List

Use the `files` array retrieved in ステップ 1.1 to extract file paths.

#### 1.2.4 Review Mode Determination

Determine the review mode based on whether a previous review result comment exists.

**Loading configuration:**

Retrieve `review.loop.verification_mode` from `rite-config.yml` (default: `false`).


**Determination logic:**

| Condition | review_mode | Description |
|------|-------------|------|
| `verification_mode == false` or no previous review comment | `full` | Full review as usual |
| `verification_mode == true` and previous review comment exists | `verification` | Verification mode (verify fixes from previous findings + regression check of incremental diff). Note: Full review is also conducted alongside verification results |

**How to determine previous review existence:**

Check for the existence of a previous review result comment in PR comments:

```bash
gh api repos/{owner}/{repo}/issues/{pr_number}/comments \
 --jq '[.[] | select(.body | contains("📜 rite レビュー結果"))] | last | .body'
```

If this returns a non-empty result, a previous review exists → use `verification` mode (when `verification_mode == true`).
If empty → use `full` mode.

**Additional information retrieval for verification mode:**

When `review_mode == "verification"`, retrieve the following:

1. **Retrieve the previous review result comment** from PR comments:
 ```bash
 gh api repos/{owner}/{repo}/issues/{pr_number}/comments \
 --jq '[.[] | select(.body | contains("📜 rite レビュー結果"))] | last | .body'
 ```

2. Extract the following from the retrieved comment:
 - `📎 reviewed_commit: {sha}` -> `{last_reviewed_commit}`
 - Finding tables within the "全指摘事項" section -> `{previous_findings}`

3. **Retrieve the incremental diff**:
 ```bash
 git diff {last_reviewed_commit}..HEAD
 ```

**Fallback:**

| Failure Case | Action |
|-----------|------|
| Previous review comment not found | Fallback to `review_mode = "full"` |
| `📎 reviewed_commit` not found | Fallback to `review_mode = "full"` |
| `git diff {sha}..HEAD` fails (force-push/rebase, etc.) | Fallback to `review_mode = "full"` |

On fallback, output the following:
```
⚠️ 検証モードのフォールバック: {失敗理由}。フルレビューモードで実行します。
```

#### 1.2.5 Commit SHA Tracking

Record the current commit SHA at the start of the review. This SHA is embedded in the review result (local JSON file always in ステップ 6.1.a; the PR comment when `post_comment_mode=true` via ステップ 6.1.b; and the non-measured findings record comment always via ステップ 6.1.d, independent of `post_comment_mode`) and used in the verification mode of the next cycle.

```bash
git rev-parse HEAD
```

Retain the obtained SHA as `{current_commit_sha}` in the conversation context.

#### 1.2.6 Change Intelligence Summary

> **Reference**: See [Change Intelligence](./references/change-intelligence.md) for computation methods and format.

Pre-compute change statistics to provide reviewers with upfront context about the nature of the PR.

**Placeholders:**
- `{base_branch}`: PR base branch (the `baseRefName` value retrieved in ステップ 1.1)

**Steps:**

1. Use the `files` array from ステップ 1.1 (`path`, `additions`, `deletions`) for per-file change statistics.

2. Retrieve numeric statistics for programmatic analysis:
 ```bash
 git diff {base_branch}...HEAD --numstat
 ```

3. Classify each changed file into categories (source/test/config/docs) per [Change Intelligence](./references/change-intelligence.md#file-classification).

4. Estimate the change type (New Feature, Refactor, Cleanup, etc.) per [Change Intelligence](./references/change-intelligence.md#change-type-estimation).

5. Generate a one-paragraph summary per [Change Intelligence](./references/change-intelligence.md#summary-generation).

Retain the generated summary as `{change_intelligence_summary}` in the conversation context for use in ステップ 4.5.

**Note**: This step uses data already retrieved in ステップ 1.1 (`additions`, `deletions`, `changedFiles`, `files`). The `files` array provides per-file `path`, `additions`, and `deletions`, eliminating the need for a separate API call.

**Success path retained flag** (必ず explicit set): `git diff --numstat` が成功した場合は以下を context に保持する:

- `numstat_availability = "OK"`
- `numstat_fallback_reason = ""` (空文字列で explicit set。ステップ 5.4 template の placeholder 展開時に空欄として描画される。undefined を残すと placeholder 参照時に literal text または error になるリスクがあるため空文字列で defined にする)

**Error handling**: If `git diff --numstat` fails (network error, timeout, missing base branch fetch, etc.):

1. **必ず stderr に WARNING を出力** (silent fallback 禁止):
 ```
 WARNING: git diff --numstat failed. Using ステップ 1.1 `files` array (additions/deletions per file) instead.
 Reason: <error message>
 Note: ステップ 1.2.7 Doc-Heavy PR detection uses only the ステップ 1.1 `files` array fields (`additions + deletions`),
 so this numstat failure does NOT affect Doc-Heavy detection accuracy. The fallback is equivalent data.
 ```
2. ステップ 1.1 の `additions`, `deletions`, `changedFiles`, `files` data を使って summary を生成する
3. **Retained context flags** (ステップ 5.4 template 表示用。会話コンテキストに明示保持し、stderr WARNING の消失リスクを回避):
 - `numstat_availability = "unavailable"`
 - `numstat_fallback_reason = <error message の 1 行要約>`
 - ステップ 1.2.7 の `{doc_heavy_pr}` 計算は ステップ 1.1 `files` 配列で完結するため `doc_heavy_pr` 判定自体は通常通り実行される (ステップ 5.4 表示では「numstat unavailable だが Doc-Heavy 判定は実行済み」と表示される)

 `numstat_availability` が `"OK"` (通常時) の場合、ステップ 5.4 の numstat 可用性行はこの retained flag を参照して表示する。本項目は retained flag を**明示定義**するため、ステップ 5.4 で `{numstat_fallback_reason}` placeholder が undefined 参照にならないことを保証する。

#### 1.2.7 Doc-Heavy PR Detection

**Purpose**: Identify PRs whose primary change target is user-facing documentation, and flag them for stricter tech-writer review with implementation-consistency checks (see [internal-consistency.md](./references/internal-consistency.md)).

**Skip conditions** (any match → **explicit set the 3 retained flags below** and skip to ステップ 1.3):

- `review.doc_heavy.enabled: false` in `rite-config.yml`
- `changedFiles == 0` (edge case: empty diff)

skip 発動時に explicit set する 3 retained flags:

| Flag | Value (skip 時) |
|------|-----------------|
| `{doc_heavy_pr}` | `false` |
| `{doc_heavy_pr_value}` | `false` |
| `{doc_heavy_pr_decision_summary}` | `"doc_heavy.enabled=false (skipped)"` または `"empty diff (changedFiles=0)"` (発動した skip 条件に応じて) |

**Configuration**: Read `review.doc_heavy` from `rite-config.yml`（キー省略時は default を使う。数値として読めない値は default にフォールバックし `WARNING: review.doc_heavy.{key} が不正なため default {default} を使用します` を stderr に出力する）:

| Key | Default | Description |
|-----|---------|-------------|
| **`enabled`** | `true` | この Phase の有効/無効 |
| **`lines_ratio_threshold`** | `0.6` | 行数比率の目安閾値 |
| **`count_ratio_threshold`** | `0.7` | ファイル数比率の目安閾値 |
| **`max_diff_lines_for_count`** | `2000` | ファイル数比率判定を有効にする最大 diff 行数(この行数以上の大規模diffでは、ファイル数比率のみでdoc-heavyと判定しない) |

**目的文判断**: ステップ 1.1 で取得済みの `files` 配列（`additions`/`deletions` 付き、再取得不要）を用いて次の目的文で判定する:

> 変更行数の `lines_ratio_threshold` 以上、または(総diff行数が `max_diff_lines_for_count` 未満の場合に限り)ファイル数の `count_ratio_threshold` 以上が `doc_file_patterns` に一致するファイルなら doc-heavy と判定する。

`doc_file_patterns` の定義は [`skills/reviewers/SKILL.md`](../reviewers/SKILL.md#available-reviewers) の Technical Writer 行（File Patterns 列）が SoT。本ステップはそれを参照するのみで値を複製しない。

**Exclusion rule**: rite plugin 自身の `commands/**/*.md`, `skills/**/*.md`, `agents/**/*.md`, `plugins/rite/i18n/**` は分子（doc_lines / doc_files_count）から除外し、分母（total_diff_lines / total_files_count）には含める。これらは prompt-engineer の専管領域、または rite plugin 自身のドッグフーディング artifact であり、rite plugin 自身のメンテナンス PR で意図せず doc-heavy 判定が発火しないようにするため。全変更ファイルがこの除外規則に該当する場合（self-only）は `doc_heavy_pr = false` とし、要約に `"rite plugin self-only (excluded)"` と記す。

**計算例**:
- `docs/foo.md (+50)` と `commands/bar.md (+50)`（commands/ は除外）→ doc_lines=50 / total=100 → ratio 0.5 (< 0.6) → `doc_heavy_pr = false`
- `docs/foo.md (+80)` のみ → ratio 1.0 → `doc_heavy_pr = true`

**Determination**: 上記目的文に基づき `doc_heavy_pr` (boolean) を判断し、3 retained flags を explicit set する:

| Flag | 内容 |
|------|------|
| `{doc_heavy_pr}` | 判定結果 (boolean) |
| `{doc_heavy_pr_value}` | `{doc_heavy_pr}` と同値 (ステップ 5.4 表示用) |
| `{doc_heavy_pr_decision_summary}` | 判断根拠の1行要約 (例: `"doc_lines_ratio=0.72 >= 0.6"` / `"rite plugin self-only (excluded)"` / `"doc_lines_ratio=0.3 < 0.6 かつ doc_files_count_ratio=0.4 < 0.7"`) |

Retain `{doc_heavy_pr}`, `{doc_heavy_pr_value}`, `{doc_heavy_pr_decision_summary}` in the conversation context for use in ステップ 2.2.1, ステップ 5.1.3, and ステップ 5.4 template expansion. All 3 flags are **explicitly set** in every reachable path.

**Mandatory `[CONTEXT]` emission for symmetry**: 判定完了直後、skip 経路・正常経路のどちらでも対称に以下を emit する（非対称 emit は後続 phase の negative inference 依存を生み、前 session の行を誤拾いするリスクがあるため）:

```
[CONTEXT] doc_heavy_pr={doc_heavy_pr_value}; doc_heavy_pr_value={doc_heavy_pr_value}; doc_heavy_pr_decision_summary={doc_heavy_pr_decision_summary}
```

### 1.3 Identify Related Issue

Extract the Issue number from the PR branch name or body.

**Extraction priority order:**
1. Search for `Closes #XX`, `Fixes #XX`, `Resolves #XX` patterns in the **PR body** (preferred)
2. If not found in the PR body, search for the `issue-{number}` pattern in the **branch name**

**Extraction method:**
1. Search for `Closes/Fixes/Resolves #XX` (case-insensitive) in the PR body. If multiple matches, use only the first one
2. Fallback: Extract `issue-(\d+)` from the branch name

Retain the Issue number in the conversation context for use in ステップ 6.4.

### 1.3.1 Load Issue Specification

**Purpose**: Load the specification from the related Issue (particularly the "仕様詳細" and "技術的決定事項" sections) and use it as review criteria.

**Execution condition**: Execute only if the Issue number was identified in ステップ 1.3. Skip this phase if no Issue number was found.

**Steps:**

1. Retrieve the Issue body:
 ```bash
 gh issue view {issue_number} -R {owner_repo} --json body --jq '.body'
 ```

2. Extract the following sections from the retrieved body (if they exist):
 - The entire `## 仕様詳細` section
 - The `### 技術的決定事項` subsection
 - The `### ユーザー体験` subsection
 - The `### 考慮済みエッジケース` subsection
 - The `### スコープ外` subsection

3. Retain the extracted specification as `{issue_spec}` in the conversation context for use in the ステップ 4.5 review instructions.

**If no specification is found:**

If the "仕様詳細" section does not exist in the Issue body:
- Do not display a warning; treat `{issue_spec}` as empty
- Continue the review as normal (skip spec-based checks)

Extract subsections (技術的決定事項, スコープ外, etc.) under the "仕様詳細" section of the Issue body as `{issue_spec}`.

### 1.4 Quality Checks (Optional)

Retrieve lint/build commands from `rite-config.yml`.

Retrieve `commands.lint` / `commands.build` from `rite-config.yml`. If `null`, auto-detect from project type (package.json -> Node.js, pyproject.toml -> Python, etc.).

Confirm execution with `AskUserQuestion` (run all / skip). If errors are detected, confirm whether to continue or cancel.

---

## ステップ 2: レビュアー選定 (Progressive Disclosure)

### 2.1 Load Skill Definitions

Load reviewer selection metadata from `skills/reviewers/SKILL.md`:

```
Read: skills/reviewers/SKILL.md
```

**Fallback on load failure:**
If the skill file (`skills/reviewers/SKILL.md`) is not found, fall back to the built-in pattern table from ステップ 2.2 for reviewer selection. Reviewer profiles always load as each named subagent's system prompt (`agents/{reviewer_type}-reviewer.md`), so no profile fallback is needed.

### 2.2 File Pattern Analysis

Match changed files against the pattern table in SKILL.md.

Match changed files against the Available Reviewers table in `skills/reviewers/SKILL.md` (source of truth for file patterns). The table's `Activation` column defines the detailed patterns.

**Pattern priority rules:**
1. `commands/**/*.md`, `skills/**/*.md`, `agents/**/*.md` -> Prompt Engineer (highest priority)
2. Other `**/*.md` -> Technical Writer
3. If matching multiple patterns, include all matching reviewers as candidates

### 2.2.1 Doc-Heavy Reviewer Override

**Execution condition**: `{doc_heavy_pr} == true` (determined in ステップ 1.2.7)

**Skip condition**: `{doc_heavy_pr} == false` — proceed directly to ステップ 2.3 with no change to the reviewer candidate list.

When the PR is doc-heavy, override reviewer selection to ensure documentation quality is rigorously checked against implementation reality:

1. **tech-writer 必須昇格**: ステップ 2.2 で tech-writer が候補に含まれている場合、その selection_type を現在値 (`detected` / `recommended` のいずれか) から `mandatory` に昇格する (昇格パスは ステップ 3.2 selection_type と同じ語彙: `detected → recommended → mandatory`)。含まれていない場合は mandatory として新規追加する (防御的フォールバック — `doc_file_patterns` が `skills/reviewers/SKILL.md` の Technical Writer 行を SoT として参照する構成のため、等価性は構造的に保たれ通常到達しない)
2. **code-quality co-reviewer 条件付き追加**: doc-heavy PR でも `commands/`, `skills/`, `agents/` 以外の `.md` 内に bash/yaml/code blocks が含まれることがあり、これらを構造的に検証するため code-quality を co-reviewer として追加する。**ただし純粋散文 (README 文言修正のみ等) PR で空所見の reviewer がトリガーされノイズ化することを防ぐため、ステップ 2.3 「Code block detection in `.md` files」と同じスキャンロジックを再利用し、diff 内に fenced code block (` ```bash `, ` ```yaml `, ` ```python ` 等) が検出された場合のみ追加する**。

 **scan ロジック** (ステップ 2.3 と **同じ fenced code block 検出正規表現** (`^\+[[:space:]]*` + tagged fence `` ``` `` + 言語 tag) を使う。ただし **scope は異なる** — ステップ 2.2.1 は Doc-Heavy PR の性質上 `*.md` 全体を scan 対象とするのに対し、ステップ 2.3 の Code block detection は Prompt Engineer の Activation patterns (`commands/**/*.md`, `skills/**/*.md`, `agents/**/*.md`) のみを scan 対象とする。さらに ステップ 2.3 が untyped fence ` ``` ` も検出するのに対し、本 ステップ 2.2.1 では tagged fence のみに限定する。理由は本 phase が code-quality 追加判定の先取りであり、untyped fence は ステップ 2.3 で同じ目的を達成するため。CHANGELOG の "fenced code blocks (` ```bash ` / ` ```yaml ` / ` ```python ` etc.)" 文言とも一致):

 ```bash
 # diff 全体に fenced code block の追加 (追加行のうち ```{lang} で始まる行) が含まれるかをスキャン。
 # pipefail は将来の pipeline 追加時の防御として維持 (現行は here-string 構成で直接は不要)。
 # {base_branch} placeholder 未展開 guard も入れる (置換忘れの早期検出)。
 # rationale: references/design-rationale.md#code-block-scan-notes
 set -o pipefail

 case "{base_branch}" in
 "{base_branch}"|"")
 echo "ERROR: {base_branch} placeholder が未展開、または空です (Claude の置換忘れ)" >&2
 echo " 対処: rite-config.yml の branch.base から base branch 名を取得して置換してください" >&2
 exit 1 ;;
 esac

 # trap + cleanup パターンの canonical 説明は ../../references/bash-trap-patterns.md#signal-specific-trap-template 参照
 git_diff_err=""
 _rite_review_p221_cleanup() {
 rm -f "${git_diff_err:-}"
 }
 trap 'rc=$?; _rite_review_p221_cleanup; exit $rc' EXIT
 trap '_rite_review_p221_cleanup; exit 130' INT
 trap '_rite_review_p221_cleanup; exit 143' TERM
 trap '_rite_review_p221_cleanup; exit 129' HUP

 git_diff_err=$(mktemp "${TMPDIR:-/tmp}/rite-review-p221-diff-err-XXXXXX") || {
 echo "ERROR: git_diff_err 一時ファイルの作成に失敗" >&2
 exit 1
 }

 # git diff を独立実行し exit code を明示 check (silent failure-hunter Finding 対応)
 if ! diff_out=$(git diff "{base_branch}...HEAD" -- '*.md' 2>"$git_diff_err"); then
 echo "WARNING: ステップ 2.2.1 の git diff が失敗しました (exit != 0)" >&2
 echo " 詳細: $(cat "$git_diff_err")" >&2
 echo " 考えられる原因: shallow clone (base branch 未 fetch) / 不正な branch 名 / git リポジトリ外で実行" >&2
 echo " 対処: git fetch origin {base_branch} を実行後に再試行、または rite-config.yml の branch.base を確認" >&2
 echo " fail-safe: code-quality co-reviewer 追加判定が実行できないため、明示的に追加します (silent skip より明示的追加を選ぶ — reviewer 数が 1 増えるだけの副作用に留めて Doc-Heavy mode の検証強度を維持する)" >&2
 # fail-safe sentinel で「判定不能」を後続に伝達
 has_added_fenced_block="__FAIL_SAFE_ADD__"
 else
 # grep の exit 1 (no match) と exit 2 (IO error) を区別する (`|| true` での融合禁止)。
 # `printf | grep -m 1` ではなく here-string `<<<` を使うこと — printf が SIGPIPE を受けて
 # rc=141 になり `__FAIL_SAFE_ADD__` が誤発火する経路を塞ぐ。
 # rationale: references/design-rationale.md#code-block-scan-notes
 grep_out=$(grep -m 1 -E '^\+[[:space:]]*```[a-zA-Z]' <<< "$diff_out")
 grep_rc=$?
 case "$grep_rc" in
 0)
 has_added_fenced_block="$grep_out"
 ;;
 1)
 # マッチなし (期待動作) — 純粋散文 PR
 has_added_fenced_block=""
 ;;
 *)
 echo "WARNING: ステップ 2.2.1 の grep pipeline が IO/権限エラーで失敗しました (rc=$grep_rc)" >&2
 echo " fail-safe: 同じく __FAIL_SAFE_ADD__ sentinel で code-quality 追加に倒します" >&2
 has_added_fenced_block="__FAIL_SAFE_ADD__"
 ;;
 esac
 fi

 # 機械検証可能な形で 3 状態を stdout に明示する (後続 phase が context から読み戻す)。
 # iteration_id suffix は複数回実行時に「最大値 = 最新」の決定論的判別を可能にする。
 # rationale: references/design-rationale.md#code-block-scan-notes
 p221_iteration_id="{pr_number}-$(date +%s)"
 case "$has_added_fenced_block" in
 "__FAIL_SAFE_ADD__")
 echo "[CONTEXT] code_quality_coreviewer_add_reason=fail_safe_diff_or_grep_failure; iteration_id=$p221_iteration_id"
 ;;
 "")
 echo "[CONTEXT] code_quality_coreviewer_add_reason=none; iteration_id=$p221_iteration_id"
 ;;
 *)
 echo "[CONTEXT] code_quality_coreviewer_add_reason=fenced_block_detected; iteration_id=$p221_iteration_id"
 ;;
 esac

 # pipefail を block 終了時に解除 (後続 phase の pipeline が pipefail OFF を前提とする可能性があるため)
 set +o pipefail
 ```

 **後続 phase での読み取り**: Claude は本 bash block 終了後、stdout から `[CONTEXT] code_quality_coreviewer_add_reason=` 行を会話履歴で検索して値を取得し、以下のいずれかの操作を実行する。**M-7 修正**: 同一 session 内で複数行マッチした場合は **`iteration_id=` suffix の値が最大のもの (`pr_number-{epoch_seconds}` 形式の epoch_seconds が最大のもの) を最新値として採用** すること。後段の grep regex 例: `\[CONTEXT\] code_quality_coreviewer_add_reason=([^;]+); iteration_id=([0-9]+-[0-9]+)$`。

 | reason 値 | 操作 |
 |-----------|------|
 | `fenced_block_detected` | code-quality を co-reviewer として追加 (既に候補にあれば selection_type を mandatory に引き上げ) |
 | `fail_safe_diff_or_grep_failure` | 同上 (fail-safe で追加経路に倒す)。WARNING を表示してユーザーに git diff 失敗を通知 |
 | `none` | 純粋散文 PR — code-quality 追加なし (no-op)。ステップ 2.3 の sole reviewer guard が後段で追加可能性を再評価する |

 selection_type の昇格パスは ステップ 3.2 Selection Type テーブルに従う: `detected → recommended → mandatory`。

 具体的な検証期待 (code-quality が追加された場合):
 - ドキュメント内 fenced code block の構文・引用・エラーハンドリング
 - ドキュメントの「実装例」コードが既存の coding style / naming convention と整合しているか
 - サンプル設定ファイル (yaml/toml/json snippets) のキー名・型・必須項目が実装スキーマと一致しているか

 既に候補に含まれている場合は selection_type を `mandatory` に引き上げる (昇格パスは ステップ 3.2 Selection Type テーブルの「昇格 priority」に従う)。fenced code block が検出されなかった場合は code-quality 追加自体を skip する (ステップ 2.3 と同じ判定を二重に適用するわけではなく、ステップ 2.2.1 段階での先取り追加のみ条件付き)
3. **doc-heavy mode 指示の reviewer prompt 注入**: tech-writer のレビュー実行時に ステップ 4.5 の prompt template に以下を注入する:
 - `{doc_heavy_pr}` placeholder に `true` を set
 - `{doc_heavy_mode_instructions}` placeholder に `tech-writer-reviewer.md` の `## Doc-Heavy PR Mode (Conditional)` heading から **down to (but excluding) the next `##` heading** までを埋め込む (ステップ 4.5 placeholder 表の構造的ルールと**完全一致**。drift 防止のため両者は同じ抽出ルールに統一されている)

 **必須含有性 check** (silent drift 防止 — tech-writer-reviewer.md の章立て改修時の breaking change 早期検出):

 注入された `{doc_heavy_mode_instructions}` の本文中に以下の必須キーワード 4 つが含まれていることを確認する。1 つでも欠けていれば**ERROR** として処理し、retained flag `doc_heavy_post_condition` を `error` に set した上で **overall assessment を `修正必要` に強制昇格**する (silent non-compliance 防止):

 - `Doc-Heavy mode finding requirements` — Evidence literal 形式義務化セクション
 - `Doc-Heavy mode finding-count rules` — 件数非依存 META rules セクション (ステップ 5.1.3 Step 2 で必要)
 - `META: All 5 verification categories executed` — 必須 META 行 (variant a/b の prefix)
 - `META: Cross-Reference partially skipped` — 部分スキップ用 META 行 (variant c)

 いずれかが欠けている場合の処理 (ERROR、stderr WARNING のみでは silent non-compliance を許してしまうため processing も block する):

 1. **ERROR を stderr に出力**:
 ```
 ERROR: tech-writer-reviewer.md の `## Doc-Heavy PR Mode (Conditional)` セクションから {doc_heavy_mode_instructions} を抽出しましたが、必須キーワード {missing_keywords} が含まれていません。
 tech-writer-reviewer.md の章立てが過去のバージョンから drift しているため、ステップ 5.1.3 Step 2 (件数非依存 META check) が silent fail する恐れがあります。
 Action: tech-writer-reviewer.md の `## Doc-Heavy PR Mode (Conditional)` セクション全体を確認し、必須サブセクションが含まれているか検証してください。
 Note: 本 drift は章立て(見出し)の canonical name 一致に関するものであり、doc_file_patterns の集合等価性(SoT 参照化により構造的に drift しない)とは別種。章立て drift の自動検出は将来 Issue で追跡。
 ```
 2. **Retained flag set**: `doc_heavy_post_condition = "error"` を context に明示保持。ステップ 5.4 表示でこの値を `error: tech-writer-reviewer.md の章立て drift により protocol 未伝達 (missing: {missing_keywords})` として表示する
 3. **Overall assessment 強制昇格**: ステップ 5 で計算される overall assessment を `修正必要` に強制 set する (本来 `マージ可` だった場合でも override する)。これにより e2e flow の review-fix loop が必ず再実行される

 これにより `internal-consistency.md` の 5 カテゴリ verification protocol が reviewer に直接伝達され、各 finding に `- Evidence: tool=Grep, path=src/config/services.ts, line=5-12` の **literal 形式**の行を必須化する仕様が reviewer 側で有効になる (tool は `Grep` / `Read` / `Glob` / `WebFetch` から 1 つ選択 — 山括弧はメタ記法であり literal に書いてはならない。詳細は [`tech-writer-reviewer.md`](../../agents/tech-writer-reviewer.md) の "Doc-Heavy mode finding requirements" セクション参照)。ステップ 5.1.3 で post-condition check を実行する。

**Relationship to ステップ 2.3 sole reviewer guard**:

本 Override は ステップ 2.3 (Content Analysis) および sole reviewer guard の**前**に実行される。Override 実行後に確定する reviewer 数は **fenced code block 検出の有無により分岐**する:

| **`code_quality_coreviewer_add_reason`** | 確定 reviewer | sole reviewer guard の挙動 |
|--------------------------------------|--------------|------------------------------|
| `fenced_block_detected` | tech-writer (mandatory) + code-quality (co-reviewer) → ≥2 reviewers | guard は**発火しない** (既に >=2 のため) |
| `fail_safe_diff_or_grep_failure` | 同上 (fail-safe で code-quality を追加) → ≥2 reviewers | guard は**発火しない** |
| `none` (純粋散文 PR — fenced block なし) | tech-writer のみ 1 人 | **guard が発火**して fallback 経路で code-quality を追加 → 最終的に ≥2 reviewers が保たれる |

Possible `code_quality_coreviewer_add_reason` values: (`fenced_block_detected` / `fail_safe_diff_or_grep_failure` / `none`)

つまり「ステップ 2.2.1 で先取り追加が発生する」か「ステップ 2.3 の sole reviewer guard が後段で fallback 追加する」かのいずれかの経路で必ず ≥2 reviewers が保たれる。ステップ 2.3 の既存ロジックは破壊されず、Override は加算経路を 1 つ追加するだけである。


**Override の累積効果**: 本 Override は reviewer 候補リストに対する**加算のみ**を行い、既存候補を削除しない。ステップ 2.2 で候補に選定された他 reviewer (security, application, etc.) はそのまま保持される。

### 2.3 Content Analysis (Supplementary Determination)

Analyze the diff content to determine if additional expertise is needed:

**Security keyword detection:**
- `password`, `token`, `secret`, `auth`, `crypto`, `hash`, `encrypt`, `decrypt`, `credential`, `api_key`, `private_key`, `cert`
- On detection: Mark Security Expert as candidate (final selection determined in ステップ 3.2)

**Performance keyword detection:**
- `cache`, `async`, `await`, `promise`, `worker`, `batch`, `optimize`
- On detection: Raise the priority of the domain expert selected based on the relevant file type (e.g., performance keywords in application code -> raise Application Expert priority)

**Database keyword detection:**
- `query`, `migration`, `schema`, `index`, `transaction`, `rollback`
- On detection: Add Application Expert

**Error handling keyword detection:**
- JS/TS: `try`, `catch`, `throw`, `Error`, `reject`, `fallback`, `finally`
- Bash: `set -e`, `pipefail`, `trap`, `|| true`, `|| :`, `2>/dev/null`
- On detection: Add Error Handling Expert

**Type design keyword detection:**
- `interface`, `type`, `enum`, `class`, `struct`, `readonly`, `generic`
- On detection: Add Application Expert

**Code block detection in `.md` files:**
- When changed files include `.md` files matching Prompt Engineer patterns (`commands/**/*.md`, `skills/**/*.md`, `agents/**/*.md`), scan the diff for fenced code blocks (` ```bash `, ` ```sh `, ` ```yaml `, ` ```python `, ` ```json `, ` ```javascript `, ` ```typescript `, or untyped ` ``` `)
- On detection: Add Code Quality reviewer as **co-reviewer** alongside Prompt Engineer
- **Scope**: Only diff content is scanned (not the entire file). If the diff contains at least one fenced code block opening marker, the condition is met
- **Note**: This does not affect `.md` files outside Prompt Engineer patterns (e.g., `docs/**/*.md`). Pure documentation `.md` changes without code blocks do not trigger this rule

**Sole reviewer guard:**
- After all keyword detection and code block detection rules above have been applied, if exactly **1 reviewer** has been selected (any reviewer type, not limited to Prompt Engineer), automatically add Code Quality reviewer as a **co-reviewer**
- On detection: Add Code Quality reviewer as **co-reviewer** alongside the sole reviewer
- **Condition**: The selected reviewer count is exactly 1 after all ステップ 2.3 detection rules have been applied. If 2 or more reviewers are already selected, this guard does NOT activate
- **Rationale**: [design-rationale.md#reviewer-selection-notes](references/design-rationale.md#reviewer-selection-notes) 参照。
- **Note**: If Code Quality is already the sole reviewer (selected as fallback in ステップ 3.2), this guard does not add a duplicate. The guard only applies when a non-Code-Quality reviewer is the sole selection

### 2.4 Create Reviewer Candidate List

**`reviewer_type` format:**
- Use English slugs (e.g., `security`, `devops`, `prompt-engineer`, `tech-writer`)
- Matches the agent file basename without the `-reviewer` suffix (e.g., `security-reviewer.md` -> `security`)

```
検出された専門領域:
- {reviewer_type_1}: {files_count} ファイル
- {reviewer_type_2}: {files_count} ファイル
...
```

**Japanese conversion for display:**

Refer to the "Reviewer Type Identifiers" table in `skills/reviewers/SKILL.md` (source of truth). When adding new reviewers, update SKILL.md first.

---

## ステップ 3: 動的レビュアー数決定

### 3.1 Calculate Change Scale

```
追加行数: {additions}
削除行数: {deletions}
変更ファイル数: {changedFiles}
総変更行数: {additions + deletions}
```

### 3.2 Reviewer Selection

Select reviewers based on `rite-config.yml` settings:

```yaml
review:
 min_reviewers: 1 # フォールバック用
 criteria:
 - file_types
 - content_analysis
 security_reviewer:
 mandatory: false # 全 PR で必須選定するか
 recommended_for_code_changes: true # 実行可能コード変更時は推奨
```

**Default values when `rite-config.yml` does not exist:**

| Setting | Default Value |
|---------|-------------|
| min_reviewers | 1 |
| criteria | file_types, content_analysis |
| security_reviewer.mandatory | false |
| security_reviewer.recommended_for_code_changes | true |

**Selection logic:**

Select **all** reviewers matched in ステップ 2 as the initial set. When this set exceeds `max_reviewers`, ステップ 3.2.1 narrows it by relevance score (cost control); otherwise all matched reviewers are used.

| Condition | Selected Reviewers |
|------|---------------------|
| Matched by pattern matching or content analysis | All matched reviewers (then capped in ステップ 3.2.1) |
| No reviewers matched | code-quality reviewer (min_reviewers applied) |

**Conditional selection of Security Expert:**

Determine Security Expert selection based on the `review.security_reviewer` setting in `rite-config.yml`.

| Condition | Security Expert | Selection Type | Config-Dependent |
|------|-------------------|---------|---------|
| `security_reviewer.mandatory: true` | Include (mandatory) | `mandatory` | `security_reviewer.mandatory` |
| File pattern match in ステップ 2.2 (`**/security/**`, `**/auth/**`, etc.) | Include (recommended) | `recommended` | -- |
| Changes to executable code AND `recommended_for_code_changes: true` | Include (recommended) | `recommended` | `security_reviewer.recommended_for_code_changes` |
| Changes to executable code AND `recommended_for_code_changes: false` | Only when security keywords are detected in ステップ 2.3 | `detected` | -- |
| Non-executable files only (`.md`, `.yml`, `.yaml`, `.json`, `.toml`, `.ini`, etc.) | Only when security keywords are detected in ステップ 2.3 | `detected` | -- |

**Executable code extensions**: `.ts`, `.py`, `.go`, `.js`, `.jsx`, `.tsx`, `.rs`, `.java`, `.rb`, `.php`, `.c`, `.cpp`, `.sh`, etc.

**Note**: "Security keywords detected in ステップ 2.3" refers to the keyword list defined in ステップ 2.3 ("Security keyword detection" section). Do not maintain separate keyword lists here.

**Selection Type** indicates the reason for including the Security Expert. Claude retains the determined Selection Type value internally and uses it in ステップ 3.3 to determine removal behavior:

| Selection Type | Meaning | Removable in ステップ 3.3 |
|---------------|---------|-------------------|
| **`mandatory`** | `mandatory: true` in config | No (backward compatible) |
| **`recommended`** | Selected via file pattern match or `recommended_for_code_changes` | Yes (with warning) |
| **`detected`** | Selected via keyword detection in ステップ 2.3 | Yes (with warning) |

**昇格 priority** (ステップ 2.2.1 Doc-Heavy Reviewer Override 等で referenced): `detected < recommended < mandatory`

ステップ 2.2.1 や他の override ロジックが「reviewer の selection_type を引き上げる」場合、上記順序で**より高い側に変更する** (例: `detected → recommended` や `recommended → mandatory`)。逆方向への降格 (`mandatory → recommended` 等) は行わない。同じ selection_type への "変更" は no-op。

**Determination flow:**
1. Check `security_reviewer.mandatory` in `rite-config.yml`
2. If `mandatory: true` -> Include Security Expert with selection type `mandatory`
3. If `mandatory: false` (or unset):
 a. Check if Security Expert was already matched by file patterns in ステップ 2.2 (`**/security/**`, `**/auth/**`, etc.)
 b. If pattern matched -> Include Security Expert with selection type `recommended`
 c. If not pattern matched, analyze extensions from the changed file list
 d. If executable code changes exist AND `recommended_for_code_changes: true` -> Include Security Expert with selection type `recommended`
 e1. If executable code changes exist AND `recommended_for_code_changes: false` -> Search diff content for security keywords (ステップ 2.3)
 e2. If non-executable files only (no executable code changes) -> Search diff content for security keywords (ステップ 2.3)
 f. If keywords detected -> Include Security Expert with selection type `detected`
 g. If no keywords detected -> Do not include Security Expert

**Note**: When `security_reviewer.mandatory: true`, mandatory selection for all PRs is maintained (backward compatibility). The `recommended_for_code_changes` setting is only evaluated when `mandatory: false`.

**When the reviewer count is large (4 or more):**
When the reviewer count reaches 4 or more, recommend splitting the review execution following the "Specific procedures for split execution" in `skills/reviewers/SKILL.md`. Apply this judgment to the **final post-cap reviewer count** (after ステップ 3.2.1), not the pre-cap matched set — a set narrowed to 3 by `max_reviewers` does not trigger the split recommendation.

### 3.2.1 Apply max_reviewers Cap (Cost Control)

After the Security Expert conditional and any co-reviewer / sole-reviewer-guard additions are settled, apply the `max_reviewers` upper bound. **The algorithm (relevance ordering, `effective_max` resolution, cap logic, mandatory protection) is defined once in `skills/reviewers/SKILL.md` Phase 5, which is the SoT.** This section does NOT restate the algorithm — it only wires the config read, renders the user-facing validation messages, and retains the results for ステップ 3.3. When Phase 5 and this section disagree, Phase 5 wins.

**Config read** (`rite-config.yml` `review` section):

| Setting | Default | Meaning |
|---------|---------|---------|
| `max_reviewers` | `6` | Maximum reviewers to spawn (cost cap) |

**User-facing messages** (rendered here; the `effective_max` value for each case is resolved by Phase 5, not recomputed here):

| Phase 5 validation case | User-facing message |
|-------------------------|---------------------|
| `max_reviewers` unset / valid `>= min_reviewers` | (none) |
| `max_reviewers` non-numeric | `⚠️ max_reviewers が非数値のため既定値 6（min_reviewers > 6 の場合は min_reviewers）を使用します` |
| `max_reviewers < min_reviewers` | `⚠️ max_reviewers ({max}) < min_reviewers ({min}) のため min_reviewers を優先します` |
| `max_reviewers` below the sole-reviewer-guard floor (guard fired to reach 2) | `⚠️ max_reviewers ({max}) が sole-reviewer guard の下限 2 を下回るため 2 に引き上げます（単独レビュアーの死角回避は上限で無効化できません）` |

**Cap application:**

1. Let `selected` be the reviewer set after ステップ 3.2 (Security Expert + co-reviewers + sole-reviewer guard applied).
2. Resolve `effective_max` and apply Phase 5's cap logic to `selected` (Phase 5 owns the relevance ordering, the top-N cut, mandatory protection, and the effective floor = `max(min_reviewers, sole-reviewer-guard floor)` — the cap never undoes the ステップ 2.3 sole-reviewer guard's ≥2 blind-spot protection). Emit the matching user-facing message above when a validation case fires.
3. Retain `{selected_reviewers}`, `{dropped_reviewers}` (each with its `matched file count` and `selection_type`), and `{effective_max}` in the conversation context for the omission display in ステップ 3.3. Silent capping is prohibited (MUST NOT) — the dropped reviewers MUST be surfaced there.

### 3.3 Confirm Reviewers

**E2E flow detection（#1861）**: `/rite:iterate` の review⇄fix ループから駆動された E2E 呼び出しでは、本ステップの pre-flight レビュアー構成確認 `AskUserQuestion`（末尾「オプション」の選択）を skip する。iterate は「mergeable まで自律的に回す」設計のため、cycle ごとに構成確認で停止するのは設計意図と矛盾する。判定は `skills/ready/SKILL.md` Phase 2.1 の `in_e2e_flow` と同型の flow-state ベース機械判定を用いる（iterate はステップ 1 で pr-review 呼び出し前に `phase=review` を、ステップ 3 で fix 呼び出し前に `phase=fix` を書くため、E2E 実行中は `phase ∈ {review, fix}` + `active=true` が成立する）。helper 失敗時は standalone（確認を出す）に fail-safe する:

```bash
if phase=$(bash {plugin_root}/hooks/flow-state.sh get --field phase --default ""); then
  :
else
  rc=$?
  echo "WARNING: flow-state.sh failed (rc=$rc) for --field phase in pr-review ステップ 3.3 — falling back to standalone confirmation" >&2
  echo "[CONTEXT] STATE_READ_FAILED=1; phase=pr_review_step_3_3_phase; rc=$rc" >&2
  phase=""
fi
if active=$(bash {plugin_root}/hooks/flow-state.sh get --field active --default ""); then
  :
else
  rc=$?
  echo "WARNING: flow-state.sh failed (rc=$rc) for --field active in pr-review ステップ 3.3 — falling back to standalone confirmation" >&2
  echo "[CONTEXT] STATE_READ_FAILED=1; phase=pr_review_step_3_3_active; rc=$rc" >&2
  active=""
fi
# whitelist は ready Phase 2.1 と同一（legacy phase5_* を含む）+ pr-review の live 値 review/fix。
# --default "" が false/missing を "" に潰すため AND check は安全（NOT-style check は禁止）。
if { [ "$phase" = "phase5_post_review" ] || [ "$phase" = "phase5_post_fix" ] || [ "$phase" = "review" ] || [ "$phase" = "fix" ]; } && [ "$active" = "true" ]; then
  in_e2e_flow=true
else
  in_e2e_flow=false
fi
echo "[CONTEXT] PR_REVIEW_IN_E2E=$in_e2e_flow"
```

| `PR_REVIEW_IN_E2E` | アクション |
|---|---|
| `true` | E2E（iterate 経由）。**`AskUserQuestion`（下記「オプション」の選択）を skip** し、下記表示ブロック（`起動 reviewer {count} 名` サマリ行・選定・省略された reviewer）はそのまま出力してからステップ 4 のレビュー実行へ直行する（サマリ行は every-path 必須、省略表示の silent capping 禁止は E2E でも維持） |
| `false` | standalone。下記構成を `AskUserQuestion` で確認する（従来どおり。AC-4 回帰なし。fallback: see ステップ 1.4 note） |

standalone（`PR_REVIEW_IN_E2E=false`）ではレビュアー構成を `AskUserQuestion` で確認する。E2E（`true`）では末尾「オプション」の選択のみ skip し、以下の表示ブロックは両経路で出力する:

```
以下のレビュアー構成でレビューを実行します:

起動 reviewer {count} 名: {reviewer_type_1}, {reviewer_type_2}, ...（概算規模: {count} reviewer × fact_check + debate。reviewer 数がコストに直結します）

変更規模:
- 変更ファイル: {changedFiles} 件
- 追加: +{additions} 行 / 削除: -{deletions} 行

選定されたレビュアー ({count}人):
1. {reviewer_type_1} - {reason} {label}
2. {reviewer_type_2} - {reason} {label}
...

省略された reviewer ({dropped_count}名、有効上限 {effective_max} 超過のため関連度順で除外):
- {dropped_type_1} - {matched_files_1} ファイル一致（tie-break: {selection_type_1}）
- {dropped_type_2} - {matched_files_2} ファイル一致（tie-break: {selection_type_2}）

オプション:
- この構成でレビュー開始（推奨）
- レビュアーを追加
- レビュアーを減らす
- キャンセル
```

**Summary line (AC-2)**: The `起動 reviewer {count} 名: ...` line is a mandatory pre-spawn summary shown before ステップ 4 in **every** path (standalone and E2E). It gives the user the review cost scale (reviewer count) at a glance.

**Omission display (AC-1, cost control)**: The `省略された reviewer` section is output **only** when ステップ 3.2.1 dropped one or more reviewers (`{dropped_count} > 0`). When nothing was dropped, omit the entire section (do not print an empty "省略された reviewer (0名)" line). Silent capping is prohibited — when a cap narrows the set, the dropped reviewer names and their matched file counts MUST be shown.

**Note**: `{label}` is placed after `{reason}` to keep the reviewer name as the first visible element for quick scanning. When `{label}` is empty (other reviewers), omit both the space and `{label}` from the output.

**Examples:**
- Good: `1. セキュリティ専門家 - 実行可能コード変更 [推奨]`
- Good: `1. セキュリティ専門家 - auth/ パターン一致 [推奨]`
- Good: `1. プロンプトエンジニア - コマンド定義変更`
- Bad: `1. プロンプトエンジニア - コマンド定義変更 ` (trailing space)

**`{label}` display rules:**

| Selection Type (from ステップ 3.2) | `{label}` Display | Description |
|------|-----------|------|
| **`mandatory`** | `[必須]` | `mandatory: true` in config; cannot be removed |
| **`recommended`** | `[推奨]` | Selected via file pattern match or `recommended_for_code_changes`; can be removed with warning |
| **`detected`** | `[検出]` | Selected via keyword detection in ステップ 2.3; can be removed with warning |
| (other reviewers) | (empty) | Normal selection; can be removed freely |

**Behavior when "Reduce reviewers" is selected:**

The behavior depends on the Security Expert's selection type:

| Selection Type | Removable | Behavior |
|---------------|-----------|----------|
| **`mandatory`** | **No** | Display a warning that Security Expert cannot be removed, and present options to reduce only other reviewers |
| **`recommended`** | **Yes** (with warning) | Display a warning recommending against removal, then allow removal if the user confirms |
| **`detected`** | **Yes** (with warning) | Display a warning recommending against removal, then allow removal if the user confirms |

**Warning when removing a `recommended` Security Expert:**

```
⚠️ セキュリティレビュアーの削除は非推奨です

セキュリティ関連のファイルパターンまたは実行可能コードの変更が含まれるため、セキュリティレビューを推奨します。
セキュリティレビュアーを削除すると、潜在的な脆弱性が見落とされる可能性があります。

オプション:
- セキュリティレビュアーを維持する（推奨）
- セキュリティレビュアーを削除する
```

**Warning when removing a `detected` Security Expert:**

```
⚠️ セキュリティレビュアーの削除は非推奨です

セキュリティ関連のキーワードが差分内で検出されたため、セキュリティレビューを推奨します。
セキュリティレビュアーを削除すると、潜在的な脆弱性が見落とされる可能性があります。

オプション:
- セキュリティレビュアーを維持する（推奨）
- セキュリティレビュアーを削除する
```

**Warning when attempting to remove a `mandatory` Security Expert:**

```
⚠️ セキュリティレビュアーは必須設定（mandatory: true）のため削除できません

他のレビュアーから削除対象を選択してください。
設定を変更するには rite-config.yml の review.security_reviewer.mandatory を false に変更してください。
```

---

## ステップ 4: 並列レビュー実行 (Generator フェーズ)


### 4.0.A Pre-Review State Snapshot

Reviewer subagent が READ-ONLY 契約を破って parent session の working tree / branch を mutate した場合に ステップ 5.0.A で検出するため、ステップ 4 (parallel review execution) 開始**前**に現在の state を snapshot する。

一次防御は reviewer prompt の READ-ONLY 契約 (`plugins/rite/agents/_reviewer-base.md`, Layer 1)。working-tree 変更 verb の機械ゲートは Issue #1879 で撤去され、`pre-tool-bash-guard.sh` Pattern 4 が機械遮断するのは .git 書き込み経路のみ。本 snapshot + ステップ 5.0.A verify (Layer 3) が working-tree / branch / stash / branch-list mutate の**検出保証の正**となる post-condition gate。

```bash
# 4 変数 (ORIG_BR / ORIG_SC / ORIG_BLH / ORIG_WTH) は ステップ 5.0.A の post-review-state-verify.sh
# 引数として再利用するため会話 context に保持する (Bash tool 間で shell 変数は引き継がれない)。
# detached HEAD は `DETACHED:<short-hash>` sentinel に置換 (verifier 側で branch drift check を skip)。
# ORIG_WTH は working tree / index の drift (Edit/Write in-place mutation や state-changing git) を
# 捕捉する 4 軸目 (Issue #1860)。branch/stash/branch_list では見えない porcelain 差分を検出する。
# 生の `git status --porcelain` ではなく git-status-filtered.sh 経由で計算する (Issue #1944):
# このスナップショットとステップ 5.0.A の verify は異なる sandbox 実行コンテキストで走りうるため、
# bwrap sandbox が overlay する ghost-mount `??` エントリ (#1936) が両側で食い違い、実変更が
# 無くても hash 不一致 (false-positive drift) が起きる。フィルタを両側に適用することでその
# ghost-mount 差分を打ち消し、実際の working-tree 変更のみが hash に反映されるようにする。
# 生の `git status --porcelain` と異なりフィルタは `mktemp` に依存する (sandbox の TMPDIR 制限下では
# plain `git status` は成功してもフィルタは失敗しうる) ため、exit code を明示チェックする。
# この bash block は Bash tool の 1 回の呼び出しとして新規シェルで実行され pipefail は既定 off
# (呼び出し間でシェル状態は引き継がれない) なので、`filter | hash | awk` の `$?` は pipefail に
# 依存させず、filter 自身の出力を先に非パイプで capture してから exit code を判定する
# (capture-first)。post-review-state-verify.sh 側は単一スクリプト全体に `set -uo pipefail` が
# かかるため pipefail 経由の `$?` チェックで足りるが、この SKILL.md block はそれとは独立した
# 実行コンテキストのため同じ前提を流用できない。
# rationale: references/design-rationale.md#state-snapshot-notes
ORIG_BR=$(git branch --show-current 2>/dev/null || echo "")
if [ -z "$ORIG_BR" ]; then
 ORIG_BR="DETACHED:$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
fi
ORIG_SC=$(git stash list 2>/dev/null | wc -l | tr -d ' ')
_wth_raw=$(bash {plugin_root}/hooks/scripts/lib/git-status-filtered.sh)
_wth_rc=$?
if command -v md5sum >/dev/null 2>&1; then
 ORIG_BLH=$(git branch --list 2>/dev/null | sort | md5sum | awk '{print $1}')
 if [ "$_wth_rc" -ne 0 ]; then
   echo "WARNING: git-status-filtered.sh failed — worktree drift snapshot skipped" >&2
   ORIG_WTH=""
 else
   ORIG_WTH=$(printf '%s' "$_wth_raw" | md5sum | awk '{print $1}')
 fi
elif command -v shasum >/dev/null 2>&1; then
 ORIG_BLH=$(git branch --list 2>/dev/null | sort | shasum | awk '{print $1}')
 if [ "$_wth_rc" -ne 0 ]; then
   echo "WARNING: git-status-filtered.sh failed — worktree drift snapshot skipped" >&2
   ORIG_WTH=""
 else
   ORIG_WTH=$(printf '%s' "$_wth_raw" | shasum | awk '{print $1}')
 fi
else
 ORIG_BLH="" # hash 計算不可 — branch_list drift check は skip 扱い (verifier 側で空文字列を skip)
 ORIG_WTH="" # hash 計算不可 — worktree drift check は skip 扱い (verifier 側で空文字列を skip)
fi
echo "review_pre_state: branch=$ORIG_BR stash_count=$ORIG_SC branch_list_hash=$ORIG_BLH worktree_hash=$ORIG_WTH"
```

LLM は出力 4 値 (`ORIG_BR`, `ORIG_SC`, `ORIG_BLH`, `ORIG_WTH`) を ステップ 5.0.A の `post-review-state-verify.sh` 引数に literal substitute する。**Mapping for ステップ 5.0.A**: `$ORIG_BR → {orig_br}`, `$ORIG_SC → {orig_sc}`, `$ORIG_BLH → {orig_blh}`, `$ORIG_WTH → {orig_wth}` (大文字 shell 変数 → 小文字 placeholder)。

### 4.0.W Wiki Query Injection (Conditional)

> **Reference**: [Wiki Query](../wiki-query/SKILL.md) — `wiki-query-inject.sh` API

Before loading reviewer skills, inject relevant experiential knowledge from the Wiki to enrich reviewer context.

**Condition**: Execute only when `wiki.enabled: true` AND `wiki.auto_query: true` in `rite-config.yml`. Skip silently otherwise.

**Step 1**: Check Wiki configuration:

```bash
wiki_section=$(sed -n '/^wiki:/,/^[a-zA-Z]/p' rite-config.yml 2>/dev/null) || wiki_section=""
wiki_enabled=""
if [[ -n "$wiki_section" ]]; then
 wiki_enabled=$(printf '%s\n' "$wiki_section" | awk '/^[[:space:]]+enabled:/ { print; exit }' \
 | sed 's/[[:space:]]#.*//' | sed 's/.*enabled:[[:space:]]*//' | tr -d '[:space:]"'"'"'' | tr '[:upper:]' '[:lower:]')
fi
auto_query=""
if [[ -n "$wiki_section" ]]; then
 auto_query=$(printf '%s\n' "$wiki_section" | awk '/^[[:space:]]+auto_query:/ { print; exit }' \
 | sed 's/[[:space:]]#.*//' | sed 's/.*auto_query:[[:space:]]*//' | tr -d '[:space:]"'"'"'' | tr '[:upper:]' '[:lower:]')
fi
case "$wiki_enabled" in false|no|0) wiki_enabled="false" ;; true|yes|1) wiki_enabled="true" ;; *) wiki_enabled="true" ;; esac # opt-out default
case "$auto_query" in true|yes|1) auto_query="true" ;; *) auto_query="false" ;; esac
echo "wiki_enabled=$wiki_enabled auto_query=$auto_query"
```

If `wiki_enabled=false` or `auto_query=false`, skip this section and set `{wiki_context}` to empty string in ステップ 4.5.

**Step 2**: Generate keywords from the PR context and invoke the query:

Keywords are derived from: changed file paths (from ステップ 1.2) and file type categories (e.g., `hooks`, `commands`, `review`, `security`).

```bash
# {plugin_root} はリテラル値で埋め込む
# {keywords} は変更ファイルパス + ファイル種別をカンマ区切りで生成
# （他コーラー skills/issue-create/SKILL.md / skills/fix/SKILL.md /
#   skills/issue-implement/SKILL.md / skills/unknowns/SKILL.md と同形式）
wiki_context=$(bash {plugin_root}/hooks/wiki-query-inject.sh \
 --keywords "{keywords}" \
 --format compact 2>/dev/null) || wiki_context=""
if [ -n "$wiki_context" ]; then
 echo "$wiki_context"
fi
```

**Step 3**: If `wiki_context` is non-empty, retain it for injection into the review instruction template (ステップ 4.5) via the `{wiki_context}` placeholder. If empty, set `{wiki_context}` to empty string (the placeholder section will be omitted).

### 4.1 Reviewer Profiles (named subagent system prompt)

Each reviewer's full profile — Role / Core Principles / Detection Process / Detailed Checklist (Expertise Areas, Review Checklist, Severity Definitions, Finding Quality Guidelines) / Output Format — lives in the named subagent definition `agents/{reviewer_type}-reviewer.md`. It is injected automatically as the sub-agent's **system prompt** when ステップ 4.3 spawns `rite:{reviewer_type}-reviewer` via the Task tool. No separate skill-file load step is needed; the ステップ 4.5 user-prompt template carries only the per-review inputs (diff, spec, shared principles, Wiki context).

### 4.3 Review Execution

**⚠️ CRITICAL — Sub-Agent Invocation is MANDATORY**: Regardless of `review_mode` (`full` or `verification`), ステップ 4.3 **MUST** invoke sub-agents via the Task tool. Do NOT perform review inline or manually verify the diff without sub-agents — this applies even when the incremental diff is small or when context pressure is high.

- `review_mode == "full"`: Sub-agents execute the ステップ 4.5 template
- `review_mode == "verification"`: Sub-agents execute BOTH ステップ 4.5.1 (verification) AND ステップ 4.5 (full) templates. Pass both templates in a single Task tool prompt per reviewer. The sub-agent returns consolidated results covering both verification and full review.

Performing verification inline (without sub-agents) is a **review quality failure** — it bypasses the reviewer's Detection Process, Confidence Scoring, and Cross-File Impact Check, producing rubber-stamp approvals.

**Pre-execution message** (displayed before launching review agents):
Output a brief status message to set user expectations:
`{count} 人のレビュアーで並列レビューを実行中です。1-2分お待ちください。`

Execute parallel reviews using sub-agents (defined in the `agents/` directory) corresponding to the reviewers selected in ステップ 2.

**Available reviewer agents:**

| Agent | File | Specialty |
|-------------|---------|---------|
| Security Expert | `security-reviewer.md` | Authentication/authorization, vulnerabilities, encryption |
| Application Expert | `application-reviewer.md` | API/type contract compatibility, N+1 queries, missing indexes, XSS, accessibility, migration safety |
| Code Quality Expert | `code-quality-reviewer.md` | Duplication, naming, error handling |
| DevOps Expert | `devops-reviewer.md` | CI/CD, infrastructure configuration |
| Test Expert | `test-reviewer.md` | Test quality, coverage |
| Dependencies Expert | `dependencies-reviewer.md` | Package management, vulnerabilities |
| Prompt Engineer | `prompt-engineer-reviewer.md` | Skill/command/agent definition quality |
| Technical Writer | `tech-writer-reviewer.md` | Document clarity, accuracy |
| Error Handling Expert | `error-handling-reviewer.md` | Silent failures, error propagation, catch quality |

**Loading sub-agent definition files:**

1. Load the definition file corresponding to the reviewer selected in ステップ 2:
 ```
 Read: {plugin_root}/agents/{reviewer_type}-reviewer.md
 ```
 Example: `security` -> `{plugin_root}/agents/security-reviewer.md`

2. On load failure, display a warning and skip that sub-agent

3. **Extract `{shared_reviewer_principles}`** (from `_reviewer-base.md`):

 Under named subagent invocation (Phase B), the agent file body becomes the **system prompt** automatically — so the agent-specific identity no longer needs to be extracted or injected via the user prompt. Agent-specific discipline (Core Principles, Detection Process, Confidence Calibration, Detailed Checklist, Output Format) is delivered through the named subagent's system prompt.

 However, `_reviewer-base.md` (the shared reviewer principles) is **not** automatically injected into named subagents — it is a separate file that only a reviewer *agent* would reference. To preserve the cross-file impact checks and shared discipline across all reviewers (Phase A bug fix), this hybrid approach continues to extract `_reviewer-base.md` and pass it via the **user prompt** as `{shared_reviewer_principles}`.

 **Extraction procedure**:
 - Load `{plugin_root}/agents/_reviewer-base.md` with the Read tool
 - Extract **all sections** from `_reviewer-base.md` between the document start and the `## Input` heading (exclusive). This includes:
 - `## READ-ONLY Enforcement`
 - `## Reviewer Mindset`
 - `## Cross-File Impact Check`
 - `## Confidence Scoring`
 - **Important**: Do NOT extract only a subset of the above sections individually — doing so would drop the sections that sit between them in document order. Extracting the contiguous range from the document start to `## Input` ensures all shared principles (READ-ONLY state-level enforcement, mindset, cross-file impact checks, confidence scoring) reach the reviewer agent.
 - These sections define the universal principles all reviewers must follow (READ-ONLY state guarantee, mindset, mandatory cross-file impact checks, and confidence scoring framework)

 **Fallback**: If extraction fails or yields empty content, set `{shared_reviewer_principles}` to an empty string. The review will still function using the named subagent's system prompt, which contains the reviewer's full identity, detailed checklist, and output format.

**Parallel execution using the Task tool:**

Achieve parallel execution by **invoking multiple Task tools in a single message** for all selected sub-agents.

Pass the following information to each sub-agent:
- PR diff (or related file diffs - see reference below)
- Changed file list
- Related Issue specification (obtained in ステップ 1.3.1)
- Shared reviewer principles (`{shared_reviewer_principles}` extracted above from `_reviewer-base.md`)


**Error handling:**

If the following issues occur with the sub-agent approach:
- All sub-agent definition files cannot be loaded -> Display error message and terminate
- Some Task tool calls fail -> Integrate only successful review results

**See "Task Tool Sub-Agent Invocation" below for details on the sub-agent approach.**

---

### 4.3.1 Task Tool Sub-Agent Invocation

**⚠️ IMPORTANT — Named Subagent Invocation**: Since Phase B, reviewers are invoked as **named subagents** using the scoped format `rite:{reviewer_type}-reviewer`. This activates the agent body as the **system prompt** (rather than a user-prompt injection), giving reviewer discipline stronger enforcement.

**Parallel execution:** Invoke multiple Task tools within a single message for all selected reviewers. Each Task uses:
- `description`: "セキュリティ専門家 PR レビュー" (short description)
- `subagent_type`: `rite:{reviewer_type}-reviewer` — scoped name derived from the reviewer selected in ステップ 2 (see table below)
- `run_in_background`: `false` — foreground 起動を強制する。省略すると harness default で background 起動となり結果回収が不完全になる (下記 CRITICAL 注記参照)
- `prompt`:
 - `review_mode == "full"`: ステップ 4.5 format (diff, spec, shared reviewer principles)
 - `review_mode == "verification"`: ステップ 4.5.1 verification template + ステップ 4.5 full template, concatenated in a single prompt. Include previous findings table and incremental diff (from ステップ 1.2.4) in addition to the standard inputs.

**`reviewer_type` → `subagent_type` mapping:**

| **`reviewer_type`** (selected in ステップ 2) | `subagent_type` (used in Task call) |
|---------------------------------------|-------------------------------------|
| **`security`** | `rite:security-reviewer` |
| **`application`** | `rite:application-reviewer` |
| `code-quality` | `rite:code-quality-reviewer` |
| **`devops`** | `rite:devops-reviewer` |
| **`test`** | `rite:test-reviewer` |
| **`dependencies`** | `rite:dependencies-reviewer` |
| `prompt-engineer` | `rite:prompt-engineer-reviewer` |
| `tech-writer` | `rite:tech-writer-reviewer` |
| `error-handling` | `rite:error-handling-reviewer` |

**Formula**: `subagent_type = "rite:" + reviewer_type + "-reviewer"` (the `rite:` prefix is mandatory in plugin distribution; bare `{reviewer_type}-reviewer` fails agent resolution).

**Legacy type fallback**: 旧 reviewer_type（`api` / `frontend` / `performance` / `database` / `type-design`）が入力に現れた場合は、WARNING を表示して `application` で代替 spawn する（silent skip 禁止。対応表: `skills/reviewers/SKILL.md` Legacy Reviewer Type Aliases）。

Task results are returned automatically upon completion. No explicit wait handling is needed.

**⚠️ CRITICAL**: Every reviewer Task invocation **MUST explicitly pass `run_in_background: false`**. The current harness launches subagents in the background **by default**, so merely avoiding `run_in_background: true` is not enough — an omitted parameter still yields a background launch. Background agents return launch confirmation immediately and the calling LLM then attempts to end the turn while results are still pending — leading to incomplete review collection and inconsistent `error_count` accounting. Foreground agents (`run_in_background: false`) launched in the same message already execute concurrently; Claude blocks until all results return, enabling seamless flow continuation.

### 4.4 Retry Logic

Retry procedure when a Task tool returns an error:

**Retry criteria:**

| Error Type | Retry | Action |
|-----------|--------|------|
| Timeout | Yes (up to 1 time) | Re-execute with the same prompt |
| Network error | Yes (up to 1 time) | Re-execute with the same prompt |
| Invalid output format | Yes (up to 1 time) | Re-execute with "output in the exact format" appended to the prompt |
| Skill file load failure | No | Fall back to the built-in pattern table (ステップ 2.2) for reviewer selection |
| subagent resolution failure | No | Fail immediately. Display the scoped name used (`rite:{reviewer_type}-reviewer`) and the error message. Do NOT silently fall back to `general-purpose` — that would defeat the Phase B quality improvement. Mark the reviewer as "incomplete" and continue with other reviewers. If all reviewers fail this way, prompt the user with `AskUserQuestion` (retry / rollback to `general-purpose` temporarily / abort review) |

**Error type determination method:**

Determine the error type from the Task tool result. Claude analyzes the Task tool response content and determines the type by the following patterns:

| Error Type | Detection Pattern |
|-----------|-------------|
| Timeout | Response contains keywords like "timeout", "timed out", "exceeded" |
| Network error | Response contains "network", "connection", "ECONNREFUSED", "unreachable", etc. |
| Invalid output format | Does not match the above and does not contain expected output format (e.g., `### 評価:` section) |
| Skill file load failure | Read tool returned an error (occurs before Task execution) |
| subagent resolution failure | Task tool returns an error message like `Agent type 'rite:{reviewer_type}-reviewer' not found. Available agents: ...`. This indicates the named subagent is not registered in the current Claude Code installation (plugin not installed, version mismatch, or agent file moved) |

**Retry procedure:**

1. Identify the Task that encountered an error
2. Determine if the error is retryable (see table above)
3. If retryable:
 - Keep other reviewers' results intact
 - Re-execute only the failed Task (with the same or modified prompt)
4. If the retry limit (1 time) is reached:
 - Mark the reviewer as "incomplete"
 - Proceed to ステップ 5 and generate the integrated report with only other reviewers' results
 - Include "{reviewer_type}: レビュー失敗" in the integrated report

**Note**: Retries are not performed automatically. On error, prompt the user with AskUserQuestion to choose between retry or skip.

### 4.5 Review Instruction Format

Generate instructions for each reviewer.

**Finding quality guidelines:** No vague findings. Investigate with tools (Read/Grep/WebSearch) before reporting. Report only confirmed problems with specific facts/evidence.

**Mandatory fix policy:** Reported findings **with runtime measurement** are blocking — a finding blocks merge only when it carries a `Verification:` anchor (repro / failing_test、実測必須ゲート — `_reviewer-base.md` §Verification: runtime 実測の添付)。実測を添付できない finding も報告してよいが、non-blocking として ステップ 5.4 の「実測なし指摘」section に記録される (fix サイクルは起動しない)。Report only issues where you can point to an existing call path in the current codebase that triggers the problem under a standard user flow. Hypothetical concerns that require unusual inputs, adversarial conditions, or non-existent call sites MUST NOT be reported — unless you are the `security` reviewer reviewing an attack surface. If you cannot grep the exact triggering call site and paste its file:line, do not report the finding. "What if X happened" is not a finding; "X is already happening at file:line" is — and "X reproduces with this command / failing test" is what makes it blocking.

**Thoroughness on every cycle:** Apply the same depth and rigor on every review cycle — first pass, re-review, or verification. Do not self-censor findings because "I should have caught this earlier." If you see a real problem now, report it now. Withholding a valid finding to avoid appearing inconsistent is worse than reporting it late.

**Scope judgment rule:** Only flag issues **introduced by this PR's diff** as findings (指摘事項). Apply the revert test: "If this PR were reverted, would the problem disappear?" If No, it is a pre-existing issue — do not report it in the findings table. Pre-existing code smells, tech debt, or style inconsistencies are out of scope for findings entirely. If a pre-existing pattern warrants investigation, note it in the integrated report's "調査推奨" section instead (ステップ 5) so the user can optionally run `/rite:investigate {file}` separately. Do NOT file it as a finding and do NOT auto-create an Issue for it.

**Placeholder embedding method:**

| Placeholder | Source | Extraction Method |
|---------------|--------|----------|
| `{relevant_files}` | Changed file list from ステップ 1.2 | Extract only files matching the reviewer's Activation pattern |
| `{diff_content}` | Diff from ステップ 1.2 | **Varies by scale** (see below) |
| `{issue_spec}` | Issue specification obtained in ステップ 1.3.1 | Content of the "仕様詳細" section (if empty, write "仕様情報なし") |
| `{change_intelligence_summary}` | Change Intelligence Summary from ステップ 1.2.6 | One-paragraph summary of change type, file classification, and focus area |
| `{shared_reviewer_principles}` | `_reviewer-base.md` (shared) | Extract all sections from the document start to the `## Input` heading (exclusive). This covers `## READ-ONLY Enforcement`, `## Reviewer Mindset`, `## Cross-File Impact Check`, and `## Confidence Scoring` as a contiguous block. Agent-specific identity is NOT included here — it is delivered via the named subagent's system prompt (Phase B). See ステップ 4.3 step 3 for the full extraction procedure |
| `{change_summary}` | Scale information from ステップ 1.2.1 | Used only for large diffs. Change summary table |
| `{doc_heavy_pr}` | ステップ 1.2.7 result | Boolean flag (`true` / `false`). Inject only when reviewer is `tech-writer`. If `false` or reviewer != tech-writer, set to empty string |
| `{doc_heavy_mode_instructions}` | `agents/tech-writer-reviewer.md` `## Doc-Heavy PR Mode (Conditional)` section | **Conditional extraction**: Only populated when `reviewer_type == tech-writer` AND `{doc_heavy_pr} == true`. Extract the entire section from `## Doc-Heavy PR Mode (Conditional)` heading down to (but excluding) the next `##` heading. Otherwise set to empty string |
| `{wiki_context}` | ステップ 4.0.W Wiki Query result | Non-empty when Wiki is enabled and related experiential knowledge was found. Empty string when Wiki is disabled, `auto_query` is false, or no matches found |

**`{diff_content}` by scale:** Small: entire diff | Medium: files matching `{relevant_files}` | Large: `{change_summary}` + matching files + Read tool instruction

**`{relevant_files}`:** Files matching reviewer's Activation pattern (ステップ 2.2). Security: `**/auth/**`, Application: `**/*.tsx`

> **Reference**: See [review-context-optimization.md](references/review-context-optimization.md) for change summary format and retrieval guidelines.

**Review instruction template:**

レビュー指示テンプレート本文は [references/reviewer-prompt-generator.md](references/reviewer-prompt-generator.md) を参照（上記 Placeholder embedding method の表に従い `{placeholder}` を埋めて reviewer に渡す）。

**When `{issue_spec}` is empty:** Write "仕様情報なし" and omit spec-based checks ("仕様との整合性" and "仕様への疑問" sections).

### 4.5.1 Verification Mode Review Instruction Template

When `review_mode == "verification"` (determined in ステップ 1.2.4), use the following template **in addition to** the normal template from ステップ 4.5. Both verification results and full review results are consolidated in the final assessment.

**Template selection logic:**

| review_mode | Template Used |
|-------------|-------------------|
| **`full`** | Normal template from ステップ 4.5 only |
| **`verification`** | Both: this section's (4.5.1) verification template AND the normal template from ステップ 4.5 |

**Verification mode review instruction template:**

Verification モードのレビュー指示テンプレート本文は [references/reviewer-prompt-verification.md](references/reviewer-prompt-verification.md) を参照（下記 Placeholder embedding method の表に従い `{placeholder}` を埋めて reviewer に渡す）。

**Placeholder embedding method:**

| Placeholder | Source | Extraction Method |
|---------------|--------|----------|
| `{previous_findings_table}` | Previous review finding table obtained in ステップ 1.2.4 | Integrate finding tables from each reviewer in the "全指摘事項" section from the previous `📜 rite レビュー結果` comment |
| `{incremental_diff}` | `git diff {last_reviewed_commit}..HEAD` obtained in ステップ 1.2.4 | Full incremental diff (however, for large scale, only files relevant to the reviewer) |
| `{change_intelligence_summary}` | Change Intelligence Summary from ステップ 1.2.6 | One-paragraph summary of change type, file classification, and focus area |

---

## ステップ 5: 結果検証と統合 (Critic フェーズ)


### 5.0.A Post-Review State Verification

ステップ 4 (parallel review execution) で起動した reviewer subagent が READ-ONLY 契約 (`_reviewer-base.md`, Layer 1) を守り、parent session の working tree / branch / stash list を mutate しなかったことを post-condition で verify する。working-tree 変更 verb の機械ゲートは Issue #1879 で撤去されたため (Edit/Write 経路の `pre-tool-edit-guard.sh` と `pre-tool-bash-guard.sh` の .git 書き込みゲートは存続)、本 verify が Bash 経由 mutate の検出保証の正。drift 検出時は WARNING を stderr に emit し、branch drift のみ `git checkout` で automatic recovery を試みる (worktree drift は auto-recover せず手動 triage を案内 — Issue #1860)。

ステップ 4.0.A で記録した `ORIG_BR` / `ORIG_SC` / `ORIG_BLH` / `ORIG_WTH` をリテラル substitute する (ステップ 4.0.A の大文字 shell 変数 → ステップ 5.0.A の小文字 placeholder への mapping: `$ORIG_BR → {orig_br}`, `$ORIG_SC → {orig_sc}`, `$ORIG_BLH → {orig_blh}`, `$ORIG_WTH → {orig_wth}`)。

```bash
# {plugin_root} と {orig_br} / {orig_sc} / {orig_blh} / {orig_wth} (ステップ 4.0.A の出力値) をリテラル substitute する。
# Placeholder 残留 fail-fast gate: `{...}` 形状のまま渡ると verifier が silent false-positive cascade を
# 起こすため早期 reject する。detached HEAD は ステップ 4.0.A で sentinel 変換済みのため常に非空で到達する。
case "{orig_br}" in
 "{"*"}")
 echo "ERROR: ステップ 5.0.A の {orig_br} placeholder が literal substitute されていません (値: '{orig_br}'). ステップ 4.0.A 未実行 / Bash tool 間変数の引き継ぎ失敗の可能性。" >&2
 echo "[CONTEXT] POST_REVIEW_VERIFY_FAILED=1; reason=orig_br_placeholder_residue" >&2
 exit 1
 ;;
esac
case "{orig_sc}" in
 "{"*"}")
 echo "ERROR: ステップ 5.0.A の {orig_sc} placeholder が literal substitute されていません (値: '{orig_sc}')." >&2
 echo "[CONTEXT] POST_REVIEW_VERIFY_FAILED=1; reason=orig_sc_placeholder_residue" >&2
 exit 1
 ;;
esac
case "{orig_blh}" in
 "{"*"}")
 echo "ERROR: ステップ 5.0.A の {orig_blh} placeholder が literal substitute されていません (値: '{orig_blh}')." >&2
 echo "[CONTEXT] POST_REVIEW_VERIFY_FAILED=1; reason=orig_blh_placeholder_residue" >&2
 exit 1
 ;;
esac
case "{orig_wth}" in
 "{"*"}")
 echo "ERROR: ステップ 5.0.A の {orig_wth} placeholder が literal substitute されていません (値: '{orig_wth}')." >&2
 echo "[CONTEXT] POST_REVIEW_VERIFY_FAILED=1; reason=orig_wth_placeholder_residue" >&2
 exit 1
 ;;
esac

# stdout (JSON line) のみ result_json に収集し、stderr の WARNING は
# Bash tool 経由で会話 context に直接届く (2>&1 で混合させると JSON line を機械的に取り出せない)。
result_json=$(bash {plugin_root}/hooks/scripts/post-review-state-verify.sh \
 --original-branch "{orig_br}" \
 --original-stash-count "{orig_sc}" \
 --original-branch-list-hash "{orig_blh}" \
 --original-worktree-hash "{orig_wth}" \
 --auto-recover true) || true
printf '%s\n' "$result_json"
```

**ステップ 5.0.A placeholder 残留 gate の retained flag** (Pattern 1 retained-flag coverage との対称化 — `pr_number_placeholder_residue` 等の他 placeholder gate と同様に `exit 1` の前に `[CONTEXT] POST_REVIEW_VERIFY_FAILED=1` flag を emit し、distributed-fix drift を防ぐ):

| reason | Description |
|--------|-------------|
| `orig_br_placeholder_residue` | ステップ 5.0.A の `{orig_br}` placeholder が literal substitute されず `{...}` 形状のまま到達 (ステップ 4.0.A 未実行 / Bash tool 間変数の引き継ぎ失敗) |
| `orig_sc_placeholder_residue` | ステップ 5.0.A の `{orig_sc}` placeholder が未 substitute (同上) |
| `orig_blh_placeholder_residue` | ステップ 5.0.A の `{orig_blh}` placeholder が未 substitute (同上) |
| `orig_wth_placeholder_residue` | ステップ 5.0.A の `{orig_wth}` placeholder が未 substitute (同上) |

スクリプトは stderr に WARNING を emit (Bash tool が transcript に取り込む)、stdout に `{"drift":..., "type":..., "recovered":...}` JSON line を出力する。drift 検出時の処理は **non-blocking** (review flow は継続)、drift 結果は ステップ 5.4 完了レポートに reflect される。drift は WARNING として surface され、ユーザーが必要に応じて手動 triage する。

**Branch drift で `recovered=false` の場合**: 後続の `/rite:fix` が誤 branch 上で実行されないよう、AskUserQuestion で user に明示確認を取る (本 PR で導入される `result_json` JSON 解析は orchestrator 側責務 — 完了レポート生成時に `recovered=false` を grep し、`AskUserQuestion` 経路へ分岐する)。

### 5.1 Result Collection

**⚠️ Scope**: Collect only newly detected findings from current review. Fixed code (not in diff) is auto-excluded; unaddressed findings are re-detected.

Task results are retained in conversation context with internal format (reviewer_type, assessment, findings: severity/file_line/description/recommendation).

**Recommendation classification extraction**:

For **every** item in the "### 推奨事項" section (regardless of `別 Issue` keyword match), extract the `分類: <actionable|design_confirmation|boundary>` marker that reviewers MUST emit per ステップ 4.5 template. Retain as `recommendation_items` in the conversation context with the following schema:

```json
{
 "recommendation_items": [
 { "reviewer_type": "code-quality", "content": "...", "classification": "actionable", "file_line": "src/foo.ts:42" },
 { "reviewer_type": "tech-writer", "content": "...", "classification": "design_confirmation", "file_line": null },
 { "reviewer_type": "security", "content": "...", "classification": "boundary", "file_line": "src/bar.ts:10" }
 ]
}
```

**Default classification rule**: When a reviewer omits the `分類:` marker for an item, assign `design_confirmation` as the default (reflects the most conservative interpretation — no action required, observation only). Log a `[CONTEXT] RECOMMENDATION_CLASSIFICATION_MISSING=1; reviewer={type}; default_applied=design_confirmation` line to make the omission observable for future reviewer-template improvements.

**Field naming convention**:

- **`recommendation_items`** (本 PR で新設、canonical data): ステップ 5.1 が全 reviewer 推奨事項を classification 付きで集約した list (全 item を保持、Source B extraction の元データ)
- **`candidate_count`** (ステップ 7.1 で算出、ステップ 7.7 / ステップ 8.0.2 で参照): ステップ 7.1 が Source A (findings + scope-out keyword) と Source B (`recommendation_items` の `classification ∈ {actionable, boundary}` filter + ステップ 7.2 user approval 結果による boundary 採否決定) を **合算 + deduplication した最終件数**。ステップ 7.7 post-condition gate と ステップ 8.0.2 cross-reference はこの値を参照する

**Non-measured findings (実測必須ゲート)**: 本ステップでは `Verification:` アンカーの走査・分類を **行わない**。アンカー検出と non-blocking 分類は ステップ 5.3.0.M の `scripts/review-measured-gate.sh` が JSON 上で決定論的に行う (Issue #2072)。本ステップの責務は、reviewer が `内容` 列に書いたアンカー文字列を**改変せず** finding の `description` へ引き継ぐことに尽きる — アンカーを要約・整形・削除すると helper が検出できず、実測済みの指摘が non-blocking へ降格する。ステップ 5.4 の `### 実測なし指摘 (non-blocking)` section と ステップ 6.1.d の PR 記録コメントは、いずれもゲート適用後 JSON の `non_blocking_findings[]` を情報源とする。

**Investigation suggestion collection**: Extract items from each reviewer's "### 調査推奨" section. Retain these as `investigation_suggestions` in the conversation context (reviewer_type, file, concern_description, notes). These are NOT findings and NOT Issue candidates — they do not affect the assessment, finding counts, or merge decision, and are never auto-Issue-ified by ステップ 7. They are collected solely for ステップ 5.4 "調査推奨" section rendering so the user may optionally run `/rite:investigate {file}` afterwards. A reviewer writing nothing in this section is the common case (blocking-worthy issues should go into findings, out-of-scope recommendations with Issue keywords into 推奨事項).

**Demoted findings collection (ステップ 5.3.0 safety net)**: After collecting findings, scan each finding's `内容` column for the `Likelihood-Evidence:` anchor defined in [`_reviewer-base.md`](../../agents/_reviewer-base.md#demonstrable-proof-of-burden). Findings lacking the anchor AND whose `reviewer_type` is NOT in the Hypothetical Exception Categories (security/devops/dependencies; `application` は migration 関連 finding — `Likelihood: Hypothetical (例外カテゴリ: database migration)` 表記を伴うもの — に限り Database migration 例外カテゴリを継承する) are candidates for ステップ 5.3.0 mechanical demotion. Retain these as `demoted_findings` in the conversation context (reviewer_type, severity, file_line, description, demotion_destination) for ステップ 5.3.0 processing and ステップ 5.4 "Observed Likelihood 降格結果" section rendering. The `demotion_destination` is `推奨事項` (CRITICAL/HIGH/MEDIUM/LOW-MEDIUM) or `（削除）` (LOW).

#### 5.1.1 Verification Mode Findings Collection

When `review_mode == "verification"`, classify: NOT_FIXED/PARTIAL/REGRESSION/MISSED_CRITICAL (all blocking). FIXED findings recorded in Fix Verification Summary only.

**フルレビュー由来の新規指摘**: verification mode では、検証レビューに加えてフルレビュー（ステップ 4.5 の通常テンプレート）も実施される。フルレビューで検出された新規指摘は、重要度に関わらずすべて blocking 扱いとする。これは初回フルレビューと同等の基準を適用するためであり、verification mode であることを理由に指摘を非 blocking に降格してはならない。

> **実測必須ゲートとの合成**: 本セクションの「blocking 扱い」は severity / verification-mode 軸での降格禁止を意味し、ステップ 5.3.0.M の実測必須ゲートは **orthogonal に後段で適用される** (初回レビューと同一基準)。すなわち NOT_FIXED / REGRESSION / 新規指摘であっても `Verification:` アンカー (実測) を伴わなければ non-blocking に分類される。前 cycle で実測付きだった finding の NOT_FIXED 検証は、前 cycle の実測 (repro / failing_test) を引き継いで添付すればよい (再実測は失敗が再現し続けている確認を兼ねるため推奨)。

##### 5.1.1.1 Post-Condition Check: Verification Result Table Presence

**Execution condition**: `review_mode == "verification"` (always enforced when verification mode is active).

**Skip condition**: `review_mode == "full"` — skip this post-condition entirely.

**Purpose**: verification mode では、各 reviewer が ステップ 4.5.1 の verification テンプレートに従って `### 修正検証結果` テーブルを出力することが契約である。このテーブルが欠落している場合、reviewer は「前回指摘の修正検証」を **silent に skip している可能性が高く**、結果として `finding_count == 0` と誤判定されて silent pass する経路が成立する（本 ステップ 5.1.1.1 post-condition 設置の根本目的）。ステップ 5.1.3 の Doc-Heavy PR Mode post-condition と同じ構造で、silent non-compliance を検出する。

**Verification step**: Collect all raw review outputs for the current cycle. For each reviewer output, search for the `### 修正検証結果` heading **in multiline mode** (since reviewer output is a multi-line markdown document):

```
(?m)^### 修正検証結果\s*$
```

**Judgment matrix** (classification vocabulary は ステップ 5.1.3 と統一: `passed` / `warning` / `error`):

| Condition | Classification | Action |
|-----------|---------------|--------|
| すべての reviewer 出力に `### 修正検証結果` heading が含まれている | `passed` | `verification_post_condition: passed` を set、そのまま ステップ 5.1.2 へ |
| 1 人以上の reviewer 出力に `### 修正検証結果` heading が欠落（初回検出） | `warning` | `verification_post_condition: warning` を set、下記 Retry Procedure を実行 |
| retry 実行後も欠落（2 回目以降の検出） | `error` | `verification_post_condition: error` を set、下記 Failure Procedure を実行 |

**Retry counter semantics** (per-reviewer):

`verification_post_condition_retry_count` は **per-reviewer の dict** (`{reviewer_type: int}`) として conversation context に保持する。各 reviewer が独立して 0 → 1 への transition を最大 1 回許可する。multi-reviewer 並列時は各 reviewer 単位で判定される。

**Retry Procedure** (`warning` 検出時、該当 reviewer ごとに最大 1 回):

該当 reviewer に対して ステップ 4.3.1 Task tool 呼び出し手順を再利用して verification テンプレートを再送する:

- `subagent_type`: `rite:{reviewer_type}-reviewer` (ステップ 4.3.1 の mapping table を参照。Phase B 以降、reviewer は named subagent として呼び出される)
- `prompt` 内容: ステップ 4.5.1 verification テンプレート + ステップ 4.5 full テンプレート（元レビューと同じ 2 テンプレート concat）に、以下の strict 要件を追加:
 - 「`### 修正検証結果` heading と判定テーブル (`| # | 重要度 | ファイル:行 | 内容 | 判定 | 備考 |`) を **必ず**出力すること」
 - 「ステップ 4.5.1 verification テンプレートの Part 1 (前回指摘の修正検証) を skip せずに実行すること」
- 入力データ (`{previous_findings_table}` / `{incremental_diff}` / `{change_intelligence_summary}`): ステップ 1.2.4 で取得済みのものを再供給
- **結果 merge 戦略**: retry 結果は元 reviewer の output を **置き換える** (append ではない)。元 output は破棄し、retry output のみを ステップ 5.1 結果集合に使用する
 - **Note**: retry prompt は full + verification 両 template を concat して再送している (上記 `prompt` 内容参照) ため、retry output は元 output の全指摘 (verification mode 由来 + full mode 由来) を**包含する**。元 output 内の非 verification finding が retry 置き換えで消失することはない。
- retry 実行後、`verification_post_condition_retry_count[{reviewer_type}]` を +1 し、もう一度判定条件を評価する。retry 後も欠落していれば `error` に昇格する

**ステップ 4.4 retry classification との関係** (Phase B で明示化):

この ステップ 5.1.1.1 retry 中に ステップ 4.4 の `subagent resolution failure` (`Agent type 'rite:{reviewer_type}-reviewer' not found`) が発生した場合、以下の順序で処理する:

1. **ステップ 5.1.1.1 retry counter の扱い**:
 - Task tool 経由の retry call は実行される (resolution failure は call 後に検出されるため)。しかし ステップ 4.4 の `Retry: No` 規則に従い、この call は `successful retry` としてカウントしない
 - `verification_post_condition_retry_count[{reviewer_type}]` は increment **しない** (counter は 0 のまま保持される)
 - 「次 cycle で再 retry されないこと」は counter / flag の pre-condition guard ではなく、**Step 3 で `verification_post_condition: error` を set することによって Judgment Matrix 行 3 (`error` 分類) に遷移し、Retry Procedure ではなく Failure Procedure に分岐させる flow 分岐によって保証される**。つまり terminal state は retry counter の数値ではなく、classification 状態 (`error`) によって実現される
2. **ステップ 4.4 default action への委譲**: 当該 reviewer を ステップ 4.4 retry classification 表の `subagent resolution failure` 行に定義された 2 段階 Action に従って処理する (行番号は drift するため semantic reference を使う):
 - **(a) 個別 reviewer failure (default case)**: ステップ 4.4 retry classification 表の `subagent resolution failure` 行の Action column に記載されている「Mark the reviewer as 'incomplete' and continue with other reviewers」を適用する。当該 reviewer を `incomplete` としてマークし、他 reviewer の verification retry / verification processing を **継続する**
 - **(b) 全 reviewer failure (例外 case)**: 同じ Action column の後半に記載されている「If all reviewers fail this way, prompt the user with `AskUserQuestion`」に従い、**全 reviewer が同一 subagent resolution failure になった場合のみ**、ステップ 4.4 の all-failed 経路に進み `AskUserQuestion` で retry / rollback / abort をユーザーに確認する
3. **ステップ 5.1.1.1 Failure Procedure との合流**: 上記と並行して、当該 reviewer の verification classification を `error` に昇格する。具体的な state transition (本段落直下の Failure Procedure の 4 step に対応):
 - 元 reviewer の output (resolution failure 時は通常空、retry 試行前の初回 invocation で table 欠落状態の output が残る場合は元 output) を Failure Procedure の入力として使用
 - Failure Procedure step 1 (`verification_post_condition: error` flag set) を実行
 - Failure Procedure step 2 (overall assessment を `修正必要` に昇格) を実行
 - Failure Procedure step 3 (該当 reviewer 由来の指摘を全件 blocking 扱い) は、resolution failure 時に output が空のため「0 件 blocking 扱い」という空集合処理となり実質 no-op になる。これは意図通りの挙動で、**blocking subject が存在しなくても step 1-2 の overall 昇格は発火する** ため silent pass は起きない
 - Failure Procedure step 4 (stderr に ERROR 出力) を実行

**分離の意図**: LLM は上記 Step 1-3 の順序を必ず守り、「ステップ 4.4 Action のみ発火」「Failure Procedure のみ発火」のいずれか一方だけを実行してはならない (両方を並行実行する)。 <!-- rationale: references/design-rationale.md#verification-post-condition-notes -->

**Failure Procedure** (`error` 検出時、以下の 4 step を順に実行):

1. `verification_post_condition: error` フラグを set
2. overall assessment を `修正必要` に昇格（ステップ 5.3 / ステップ 5.4 の escalation chain と統一された label。`要修正` は reviewer 個別評価用の label で、overall 昇格には使用しない）
3. 該当 reviewer 由来の指摘を **全件 blocking 扱い**
4. stderr に下記 ERROR を出力し、silent pass 経路を完全に閉塞する

> **実測必須ゲートとの合成 / escalation の効力範囲**: step 3 の「全件 blocking 扱い」は **verification-mode / severity 軸での降格を禁止する**という意味であり、ステップ 5.3.0.M の実測必須ゲートは orthogonal に後段で適用される (`Verification:` アンカーを持たない指摘は 5.3.0.M で non-blocking に分類され `total_findings` から外れる)。したがって step 3 は `total_findings > 0` を**保証しない**。
>
> **escalation は overall assessment (`修正必要`) を昇格させるが、machine-readable sentinel の routing は確定させない** — sentinel は ステップ 8.1 の出力パターン表に従い `total_findings` のみで決まる (routing の単一 SoT)。両者が乖離するケース (escalation 発火かつ measured 指摘ゼロ) では `[review:mergeable]` が正であり、`[review:fix-needed:0]` への override は禁止される (ステップ 8.1 の同注記 / [assessment-rules.md §5.3.6](../fix/references/assessment-rules.md) を参照)。override すると fix が対象 0 件で完了し次 cycle も同状態のまま `safety.max_review_cycles` まで空転するだけで、指摘は 1 件も解消しないため。この乖離時に silent pass を防ぐのは sentinel ではなく、**step 4 の ERROR 出力と ステップ 5.4 の `### 実測なし指摘 (non-blocking)` section** — draft PR に残る人間可読な記録が escalation の効力を担う。

**WARNING (初回検出時、stderr)**:

```
WARNING: verification mode で reviewer の `### 修正検証結果` テーブルが欠落しています。
該当 reviewer: {reviewer_list}
Expected: ステップ 4.5.1 の verification テンプレートに従い、「### 修正検証結果」heading と判定テーブル
 (| # | 重要度 | ファイル:行 | 内容 | 判定 | 備考 |) を必ず出力する。
Action: 当該 reviewer(s) を ステップ 4.3.1 Task tool 経由で再実行します（verification テンプレート strict 再送、1 回まで）。
```

**ERROR (retry 後も欠落、stderr)**:

```
ERROR: verification mode で reviewer の `### 修正検証結果` テーブルが retry 後も欠落しています。
該当 reviewer: {reviewer_list}
これは reviewer が前回指摘の修正検証を silent に skip している可能性があり、
silent pass による品質劣化を防ぐため、本レビューは `修正必要` として扱います。
Action: 手動で当該 reviewer の出力を確認し、verification テンプレートへの準拠を強制してください。
```

**Post-condition の ステップ 5.1.3 との関係**: ステップ 5.1.3 (Doc-Heavy、tech-writer 限定) とは独立に動作し、同一レビューで両方発火しうる (その場合 overall assessment は最も厳しい `修正必要` に統一)。設置根拠は [design-rationale.md#verification-post-condition-notes](references/design-rationale.md#verification-post-condition-notes) 参照。

#### 5.1.2 Finding Stability Analysis

When verification mode AND `allow_new_findings_in_unchanged_code == false`: Check if finding is in incremental diff. Unchanged code: CRITICAL/HIGH → genuine (blocking), MEDIUM/LOW-MEDIUM/LOW → stability_concern (non-blocking, informational).

**例外**: この stability_concern 分類は、ステップ 4.5.1 の verification テンプレート（Part 2: リグレッションチェック）由来の指摘にのみ適用される。ステップ 4.5 の通常テンプレート（フルレビュー）由来の指摘には適用しない。フルレビュー由来の指摘は 5.1.1 に従い、重要度に関わらず blocking とする。

#### 5.1.2.A Accepted Fingerprint Suppression

**Owner**: ステップ 5.1 finding collection 完了直後。**Condition**: 常に実行 (state file 不在時は skip)。**Purpose**: 前 cycle で `/rite:fix` ステップ 2.1 で `accept (認知のみ)` を選択した finding (status: `acknowledged`) が同 PR の次 review cycle で再出現した場合、JSON output からは削除し Markdown output には audit log として残す。これにより decision-replay 系の同一 finding 再出現を断つ (M5 の核)。

**Pre-condition**:
- ステップ 1.0 で `pr_number` が確定済
- ステップ 5.1 で findings (severity / file / line / description) が `severity_map` / `scope_map` 経由で conversation context に retain 済。**`category` の取得**: ステップ 5.1 default retention map (`severity_map` / `scope_map`) には含まれないため、本 ステップ 5.1.2.A 内で **ステップ 5.1 で Task tool 結果として retain された findings 集合** (schema 1.1.0 必須フィールド `findings[].category` を含む) から per-finding に lookup する責務を持つ。ステップ 5.1 retain 直後から有効 (ステップ 5.4 統合レポート生成を待たない)。file-based path / explicit_file / local_file / pr_comment Raw JSON のいずれの review_source でも `findings[].category` は schema 1.1.0 で必須のため必ず存在する

**Step 1: Read accepted-fingerprints state file**

```bash
# ステップ 5.1.2.A: accepted-fingerprints 読込
pr_number="{pr_number}"
case "$pr_number" in
 ''|*[!0-9]*)
 echo "WARNING: ステップ 5.1.2.A の pr_number が literal substitute されていません (値: '$pr_number')。suppression を skip します" >&2
 accepted_fingerprints=""
 ;;
 *)
 # state ファイルはリポジトリ共通の state ルート基準 (state-path-resolve.sh)。セッション
 # worktree / main checkout のどちらから実行しても同一パスに解決される (解決失敗時は cwd fallback)
 _state_root=$(bash {plugin_root}/hooks/state-path-resolve.sh 2>/dev/null) || _state_root=""
 [ -n "$_state_root" ] || { echo "WARNING: state-path-resolve.sh の解決に失敗。cwd をフォールバック使用します" >&2; _state_root="$(pwd)"; }
 state_file="$_state_root/.rite/state/accepted-fingerprints-${pr_number}.txt"
 if [ -f "$state_file" ] && [ -s "$state_file" ]; then
 accepted_fingerprints=$(cat "$state_file" 2>/dev/null || echo "")
 # accept_count は fix.md ステップ 2.1.A Step 7 と bit-exact 対称: wc -l + tr -d + numeric validation
 # (grep -c は 0 行マッチで rc=1 を返し fallback `echo 0` が "0\n0" corruption を起こすため不採用)
 accept_count=$(wc -l < "$state_file" 2>/dev/null | tr -d '[:space:]')
 case "$accept_count" in ''|*[!0-9]*) accept_count=0 ;; esac
 echo "[CONTEXT] ACCEPTED_FINGERPRINTS_LOADED=1; pr=$pr_number; count=$accept_count" >&2
 else
 accepted_fingerprints=""
 echo "[CONTEXT] ACCEPTED_FINGERPRINTS_LOADED=0; pr=$pr_number; reason=no_state_file" >&2
 fi
 ;;
esac
```

**Step 2: Compute fingerprint for each finding + mark suppressed**

各 finding について **fix.md ステップ 2.1.A の simplified formula と bit-exact 一致** する SHA-1 fingerprint を計算する。SHA-1 は LLM が semantic に emulate できない算法のため、必ず下記の bash block で per-finding に計算すること (LLM 推測による hash 値の手動構築は禁止):

```
fingerprint = sha1(normalize(file_path) + ":" + category + ":" + normalize(message))
```

- `normalize(file_path)`: `./` prefix のみ collapse (`sed 's@^\./@@'`)。case-sensitive path 保護のため lowercase / 空白除去はしない
- `category`: schema の `findings[].category` 値 (例: `code_quality`)
- `normalize(message)`: trim + whitespace collapse (`tr -s '[:space:]' ' '` + 前後 space 除去)。identifier mask / 行番号除去は行わない

**per-finding fingerprint 計算 bash block** (fix.md ステップ 2.1.A Step 3 と bit-exact 対称、Claude は finding ごとに本 block を呼び出す):

```bash
# ステップ 5.1.2.A Step 2 per-finding fingerprint 計算 + 即時 emit (Step 2/3 統合)
# fix.md ステップ 2.1.A Step 3 と bit-exact 一致を保証する canonical block
# Claude は finding ごとに以下の placeholder を literal substitute する:
# - {file}: findings[].file
# - {category}: findings[].category
# - {description}: findings[].description (前後の空白は trim 対象)
# - {finding_id}: findings[].id (例: F-01)
# - {original_severity}: findings[].severity (CRITICAL/HIGH/MEDIUM/LOW-MEDIUM/LOW)
# - {pr_number}: ステップ 1.0 正規化値
#
# Step 2/3 統合の理由 (cross-call shell 変数破綻の回避): references/design-rationale.md#fingerprint-suppression-notes

# {pr_number} placeholder 残留 fail-fast (Step 1 と対称、per-finding 呼出でも安全)
pr_number="{pr_number}"
case "$pr_number" in
 ''|*[!0-9]*)
 echo "WARNING: ステップ 5.1.2.A Step 2 の pr_number が literal substitute されていません (値: '$pr_number') — fingerprint 比較を skip します" >&2
 echo "[CONTEXT] FINGERPRINT_COMPUTE_FAILED=1; reason=pr_number_placeholder_residue; file={file}" >&2
 exit 0 # non-blocking: 当該 finding は suppression なしで通常 finding として処理される
 ;;
esac

# accepted_fingerprints は本 block 内で再読込する (Step 1 と別 invocation の可能性があるため)
# state ルート解決は Step 1 と同一 (worktree / main checkout 間のパス一貫性)
_state_root=$(bash {plugin_root}/hooks/state-path-resolve.sh 2>/dev/null) || _state_root=""
[ -n "$_state_root" ] || { echo "WARNING: state-path-resolve.sh の解決に失敗。cwd をフォールバック使用します" >&2; _state_root="$(pwd)"; }
state_file="$_state_root/.rite/state/accepted-fingerprints-${pr_number}.txt"
if [ -f "$state_file" ] && [ -s "$state_file" ]; then
 accepted_fingerprints=$(cat "$state_file" 2>/dev/null || echo "")
else
 accepted_fingerprints=""
fi

# 早期 exit: accepted_fingerprints が空なら suppression 候補ゼロ確定 (明示 guard で意図を可視化)
if [ -z "$accepted_fingerprints" ]; then
 : # nothing to compare — suppression mapping は空、次 finding へ
else
 norm_file=$(printf '%s' "{file}" | sed 's@^\./@@')
 norm_cat="{category}"
 norm_msg=$(printf '%s' "{description}" | tr -s '[:space:]' ' ' | sed 's/^ *//;s/ *$//')

 # portable SHA-1 helper (fix.md ステップ 2.1.A Step 3 と同型)
 if command -v sha1sum >/dev/null 2>&1; then
 fingerprint=$(printf '%s:%s:%s' "$norm_file" "$norm_cat" "$norm_msg" | sha1sum | awk '{print $1}')
 elif command -v shasum >/dev/null 2>&1; then
 fingerprint=$(printf '%s:%s:%s' "$norm_file" "$norm_cat" "$norm_msg" | shasum -a 1 | awk '{print $1}')
 else
 echo "WARNING: sha1sum / shasum が見つかりません — fingerprint 比較を skip します" >&2
 echo "[CONTEXT] FINGERPRINT_COMPUTE_FAILED=1; reason=sha1_helper_missing; file={file}" >&2
 fingerprint=""
 fi

 # accepted_fingerprints 集合との比較 + 即時 emit (match 時のみ、1 finding につき最大 1 回)
 if [ -n "$fingerprint" ] && printf '%s\n' "$accepted_fingerprints" | grep -qFx "$fingerprint"; then
 # placeholder ({finding_id} / {original_severity}) は Claude が literal substitute する。
 # $fingerprint は bash 変数として同一 block 内で参照する。
 echo "[CONTEXT] FINDING_SUPPRESSED_BY_ACCEPT=1; finding_id={finding_id}; original_severity={original_severity}; fingerprint=$fingerprint" >&2
 # suppressed_findings リストに append (Claude が会話コンテキストで管理、ステップ 6.1.a JSON 除外時に参照)
 fi
fi
```


`accepted_fingerprints` (sorted unique fingerprint list) に含まれる fingerprint を持つ finding を「suppressed」として **`suppressed_findings` リスト** (`finding_id` / `original_severity` / `fingerprint` の 3 フィールド) に分類する。Conversation context に retain:

- `suppressed_findings`: 次 cycle suppression 対象 (JSON output から除外、Markdown output には残す)
- `non_suppressed_findings`: 通常 finding (JSON / Markdown 両方に含める)

**Step 3: Emit `FINDING_SUPPRESSED_BY_ACCEPT` (Step 2 内で実行済み)**

各 suppressed finding の retained flag emit は **Step 2 bash block 内の match branch で同一 invocation 内で実行される**。これにより `$fingerprint` の bash 変数 scope が保たれ、cross-Bash-call shell var 破綻を構造的に回避する。独立した Step 3 bash block は存在しない (cycle 4 で Step 2/3 を統合済み)。

emit 形式 (Step 2 line で実装):
```
[CONTEXT] FINDING_SUPPRESSED_BY_ACCEPT=1; finding_id={finding_id}; original_severity={original_severity}; fingerprint=$fingerprint
```

- `{finding_id}` / `{original_severity}`: Claude が finding ごとに literal substitute
- `$fingerprint`: Step 2 内で計算された bash 変数 (同一 invocation 内のため scope 保持)

**Markdown / JSON output 取扱の非対称契約**:

| Output | suppressed findings の扱い |
|--------|--------------------------|
| **Markdown** (ステップ 5.4 統合レポート / ステップ 6.1.b PR コメント) | **残す** (audit log) — finding 表に通常通り表示。`内容` 列末尾に `(acknowledged — suppressed from JSON)` 注記を付与 |
| **JSON** (ステップ 6.1.a local file / ステップ 6.1.b Raw JSON 埋込) | **削除** — `findings[]` 配列から除外。`/rite:fix` ステップ 1.2.0 が参照するのは JSON 側のため、accepted finding は次 cycle で fix loop に entered しない |

**ステップ 6.1.a JSON 生成への接続**: Claude が ステップ 6.1.a step-1 で JSON 本文 (Write tool で `{review_tmp_dir}/rite-review-result-{pr_number}.json` に書き出す body) を生成する際、`suppressed_findings` リストに含まれる finding は `findings[]` 配列から **除外** する。Markdown 側 (ステップ 5.4) は `non_suppressed_findings` + `suppressed_findings` の和集合で生成 (audit log 用)。

**Revocability**: `.rite/state/accepted-fingerprints-{pr_number}.txt` を手動削除すれば、次 review cycle で当該 fingerprint の finding が再出現した際に suppression が解除され、通常通り JSON output に含まれる。`fix.md` ステップ 2.1.A の AC-5 revocability ドキュメントを参照。

**Retained flag namespace** (ステップ 5.1.2.A 独立):

| Flag | Description |
|------|-------------|
| `ACCEPTED_FINGERPRINTS_LOADED=1; pr=N; count=M` | state file 読込成功 (suppression 対象 M 件) |
| `ACCEPTED_FINGERPRINTS_LOADED=0; pr=N; reason=...` | state file 不在 / pr_number 不正 (suppression skip、通常 review) |
| `FINDING_SUPPRESSED_BY_ACCEPT=1; finding_id=F-NN; original_severity=...; fingerprint=...` | 個別 finding suppression marker (per finding emit、audit log + observability) |

**ステップ 5.1.2.A failure reasons** (reason table drift prevention — `ACCEPTED_FINGERPRINTS_LOADED=0` / `FINGERPRINT_COMPUTE_FAILED` flag の reason 値):

| reason | Description |
|--------|-------------|
| `no_state_file` | `.rite/state/accepted-fingerprints-{pr}.txt` が不在 (初回 review / accept 未実施)。`ACCEPTED_FINGERPRINTS_LOADED=0` で suppression を skip し通常 review を継続 (非ブロッキング) |
| `sha1_helper_missing` | sha1sum / shasum のいずれも環境に存在せず fingerprint 計算不可 (`FINGERPRINT_COMPUTE_FAILED` flag、極稀、CI 環境異常)。当該 finding の suppression 判定を skip して通常 finding として扱う |

> **Note**: `FINGERPRINT_COMPUTE_FAILED` flag のもう 1 つの reason `pr_number_placeholder_residue` (ステップ 5.1.2.A Step 2 で `pr_number` が数値以外のとき emit) は ステップ 6 の reason 表で文書化済みのため本表には再掲しない。

#### 5.1.3 Doc-Heavy PR Mode Post-Condition Check

**Execution condition**: `{doc_heavy_pr} == true` (set in ステップ 1.2.7) AND tech-writer is in the reviewer set.

**Skip condition**: `{doc_heavy_pr} == false` または tech-writer がレビュアー集合にない場合は本 Phase をスキップして直接 ステップ 5.2 に進む。

**Purpose**: Doc-Heavy PR Mode の 5 カテゴリ verification protocol ([`internal-consistency.md`](./references/internal-consistency.md) 参照) が **実際に実行されたか** を post-condition で検証する。これがないと、tech-writer が推測ベースの finding を返しても誰も気付かず silent non-compliance が成立してしまう (本 Phase 設置の根本目的)。

**Verification steps**:

##### Step 1: tech-writer finding 0 件警告 (silent non-compliance 防止)

**前提条件**: 本 Step 1 は **`finding_count == 0` の場合のみ発火する** (`finding_count >= 1` の場合は Step 1 自体をスキップして Step 2 に進む)。下記の判定条件は finding 0 件のときの「META 行未含」を判定する。

**判定条件** (`finding_count == 0` 前提下での AND 条件):
- tech-writer の出力に以下の **5 種類の variant** のいずれも 1 つも含まれない:
 - **(a)** `META: All 5 verification categories executed, 0 inconsistencies found. Categories: [Implementation Coverage, Enumeration Completeness, UX Flow Accuracy, Order-Emphasis Consistency, Screenshot Presence]` (finding_count == 0 の正規 META 行)
 - **(b)** `META: All 5 verification categories executed. Findings below.` (finding_count >= 1 の正規 META 行 — 本 Step 1 の前提では `finding_count == 0` だが、tech-writer が誤って variant b を出力した場合でも「META 行は出ている」とみなして false positive を防ぐ)
 - **(c)** `META: Cross-Reference partially skipped` (外部参照スキップ、Step 4 で扱う)
 - **(a + inconclusive)** `META: All 5 verification categories executed, 0 inconsistencies found, but {N} categories were inconclusive. Inconclusive: [category_1, category_2, ...]. Categories: [Implementation Coverage, Enumeration Completeness, UX Flow Accuracy, Order-Emphasis Consistency, Screenshot Presence]` ([`internal-consistency.md`](./references/internal-consistency.md#inconclusive-集計-と-meta-行への反映) で定義された inconclusive 集計版。Step 4.5 で扱う)
 - **(b + inconclusive)** `META: All 5 verification categories executed, but {N} categories were inconclusive. Inconclusive: [category_1, category_2, ...]. Findings below.` (同上、finding_count >= 1 の inconclusive 集計版)

上記 5 種すべて非該当の場合のみ、警告を発火する。5 variant のうちどれか 1 つでも含まれていれば「META 行は存在する」とみなし、Step 1 はスキップして Step 2 (variant の正規性 check) に処理を委ねる。 <!-- variant b / inconclusive variant を判定式に含める理由: references/design-rationale.md#doc-heavy-post-condition-notes -->
- **WARNING を必ず stderr に出力** (silent fall-through 禁止):
 ```
 WARNING: Doc-Heavy PR mode active, but tech-writer returned 0 findings without META confirmation.
 Expected: Either explicit "META: All 5 verification categories executed, 0 inconsistencies found" declaration, or "META: Cross-Reference partially skipped" notice for external-repo documentation.
 Action: Verify tech-writer executed the 5-category verification protocol from internal-consistency.md. Re-run with explicit Doc-Heavy mode instructions if needed.
 ```
- レビュー結果に `doc_heavy_post_condition: warning` フラグを set
- overall assessment を `修正必要` に変更 (silent pass 防止)


##### Step 2: META 5 カテゴリ実行確認 (件数非依存、silent non-compliance 防止)

**適用条件**: `finding_count` の値に関係なく **常に実施** する (`finding_count == 0` でも `finding_count >= 1` でも同じ)。

**照合方式の厳格性宣言** (silent fall-through 防止 — variant ごとに異なる照合方式を明示):
- **variant (a) / (a + inconclusive)**: `Categories: [...]` ブロック内のカテゴリ名を **literal substring match** で検査する。「`Implementation Coverage`」「`Enumeration Completeness`」「`UX Flow Accuracy`」「`Order-Emphasis Consistency`」「`Screenshot Presence`」の **5 つすべてが literal で含まれていること**を要求する。`Order / Emphasis Consistency` (空白付きスラッシュ) や `Order/Emphasis Consistency` (空白なしスラッシュ) のような表記揺れは literal substring match で**マッチしないため Step 2 が `passed` にならず**、`doc_heavy_post_condition: warning` 強制昇格の経路に流れる。
- **variant (b)**: 「`META: All 5 verification categories executed.`」「`Findings below.`」の 2 トークンを literal substring match で検査する (Categories list は variant (b) では出現しない)。
- **variant (c)**: 「`META: Cross-Reference partially skipped`」を literal substring match で検査する。
- **variant (b + inconclusive)**: variant (b) のトークン + 「`but {N} categories were inconclusive`」「`Inconclusive: [...]`」を literal substring match で検査する (`{N}` 部分は数字 1 文字以上を許容)。

**重要**: literal substring match は「カテゴリ名の空白/記号の差異を厳格に検出する」設計選択 (canonical form からの逸脱で即発火する)。 <!-- rationale: references/design-rationale.md#doc-heavy-post-condition-notes -->

tech-writer の出力に以下のいずれかの META 行が含まれているかを検証する。**正規表現は必ず multiline mode (`(?m)`) で実行**: `(?m)(?:^|<br\s*/?>|[\s|>(])\s*META:` を行頭 anchor として検索する (`(?m)` 無効だと `^` がファイル先頭のみを指し、段落形式の `- META: ...` が検出漏れになる。Step 4 の正規表現も同様):
- (a) `META: All 5 verification categories executed, 0 inconsistencies found. Categories: [Implementation Coverage, Enumeration Completeness, UX Flow Accuracy, Order-Emphasis Consistency, Screenshot Presence]` (finding_count == 0 の場合)
- (b) `META: All 5 verification categories executed. Findings below.` (finding_count >= 1 の場合)
- (c) `META: Cross-Reference partially skipped` (外部参照スキップ、Step 4 で扱う)
- (a + inconclusive) `META: All 5 verification categories executed, 0 inconsistencies found, but {N} categories were inconclusive. Inconclusive: [...]. Categories: [...]` ([`internal-consistency.md`](./references/internal-consistency.md#inconclusive-集計-と-meta-行への反映) で定義された inconclusive 集計版、Step 4.5 で扱う)
- (b + inconclusive) `META: All 5 verification categories executed, but {N} categories were inconclusive. Inconclusive: [...]. Findings below.` (同上、finding_count >= 1 の inconclusive 集計版)

上記のいずれも含まれていない場合:
- **WARNING を必ず stderr に出力** (silent bypass 防止):
 ```
 WARNING: Doc-Heavy PR mode で tech-writer が META 5 カテゴリ実行確認行を出力していません。
 finding_count={count} ですが、以下のいずれかの META 行が見つかりません:
 (a) "META: All 5 verification categories executed, 0 inconsistencies found. Categories: [Implementation Coverage, Enumeration Completeness, UX Flow Accuracy, Order-Emphasis Consistency, Screenshot Presence]" (finding_count == 0 の場合)
 (b) "META: All 5 verification categories executed. Findings below." (finding_count >= 1 の場合)
 (c) "META: Cross-Reference partially skipped" (外部参照スキップの場合)
 (a + inconclusive) "META: All 5 verification categories executed, 0 inconsistencies found, but {N} categories were inconclusive. ..." (inconclusive 集計版)
 (b + inconclusive) "META: All 5 verification categories executed, but {N} categories were inconclusive. ..." (inconclusive 集計版)
 これは「1-4 カテゴリだけ実行して finding を捏造し post-condition check を silent bypass する」
 パターン (本 Phase の根本目的に反する) の可能性があります。
 Action: tech-writer を Doc-Heavy mode 指示を明示して再実行し、上記 5 種のいずれかを含む出力を得てください。
 ```
- レビュー結果に `doc_heavy_post_condition: warning` フラグを set
- overall assessment を `修正必要` に変更 (silent pass 防止)

**tech-writer prompt への反映**: ステップ 2.2.1 step 3 の reviewer prompt 注入時に、tech-writer に対して「finding 件数に関係なく META 行を出力せよ」を strict 要件として明示する。具体的には:
- finding_count == 0 → `META: All 5 verification categories executed, 0 inconsistencies found. Categories: [...]`
- finding_count >= 1 → `META: All 5 verification categories executed. Findings below.`
- 部分スキップ → `META: Cross-Reference partially skipped` (+ 詳細ブロック)

##### Step 3: Evidence field 必須化 (厳格検査 — Markdown テーブル対応)

- tech-writer の各 finding (CRITICAL/HIGH/MEDIUM/LOW-MEDIUM/LOW すべて) について、**`内容` カラム本文中**に Evidence 記述が含まれているかを正規表現で検査する。
- **重要 — Markdown テーブル構造への配慮**: Markdown テーブルのセル本文内では物理的な改行は許容されず、各 finding 行は 1 物理行として表現される (セル内改行は `<br>` または同一行内の区切り文字で表現)。そのため、Evidence 検出の正規表現は**行頭 anchor (`^`) に依存してはならない**。代わりに「行頭または直前が空白/区切り文字/`<br>`/`|`/`>`」を許容する anchor を使用する:
 - 正規表現 (multiline mode、行頭または直前が区切り文字、すべて non-capture group)。**`(?m)` flag は literal で必須** — Step 2 / Step 4 / Step 4.5 と syntax を統一し、デコードしない経路でも `^` anchor が各行先頭にマッチするようにする:
 ```
 (?m)(?:(?:^|<br\s*/?>|[\s|>(])\s*)-?\s*Evidence:\s*tool=<?(?:Grep|Read|Glob|WebFetch)>?
 ```
 - 補助: `<br>` が使われない場合でも、セル内の `- Evidence: tool=Grep, ...` 形式はテキスト先頭 (`^`) または空白/`|`/`(` 直後に出現するためマッチする
 - **non-capture group の理由**: 本検証ロジックは「Evidence 行が存在するか」のみを判定し、ツール名 (`Grep` / `Read` / `Glob` / `WebFetch`) の値を抽出して使う必要がない。[`internal-consistency.md`](./references/internal-consistency.md#2-enumeration-completeness) の "Enumeration Completeness" → "Grep パターン例" セクション直下の注釈「すべて non-capture group `(?:...)` を使用し、キャプチャ番号のずれを防ぐ」と一貫させるため、すべて `(?:...)` で統一する (行番号参照は drift しやすいため section anchor で参照する)。
- **山括弧メタ記法の許容**: `tool=<?(?:Grep|Read|Glob|WebFetch)>?` により、reviewer が tech-writer-reviewer.md の example を literal に解釈して `tool=<Grep>` と書いた場合でもマッチする。これにより example ドキュメントのメタ記法との乖離による false positive を防ぐ。
- **評価方法**: 各 finding テーブル行の `内容` セルを `<br>` / `\n` でデコードしてから上記正規表現を適用することを推奨する。これにより、reviewer がセル内改行を `<br>` で表現した場合・単一行にまとめた場合の両方で一貫して検出できる。
- **注意**: reviewer 標準テンプレートの `ファイル:行` カラムは指摘対象の位置情報であり、検証の evidence とは別物。位置情報の存在のみをもって evidence ありと判定してはならない。
- **Evidence が欠落している finding を発見した場合**:
 - 該当 finding を **`evidence_missing`** としてマーク
 - レビュー全体の overall assessment を `修正必要` (要修正) に変更
 - レビュー結果に `evidence_missing_count: {N}` フラグと該当 finding 一覧を set
 - stderr に以下のエラーを出力:
 ```
 ERROR: Doc-Heavy PR mode で tech-writer が evidence なしの finding を返しました。
 内訳: {N} 件の finding に evidence 欠落
 - {file:line}: {content preview}
 これらは内容の真偽を検証できないため、tech-writer の再実行 (Doc-Heavy mode 指示を明示的に再送) が必要です。
 ```

##### Step 4: META Cross-Reference partially skipped 検出

- tech-writer の出力に正規表現 `(?m)(?:^|<br\s*/?>|[\s|>(])\s*META:\s*Cross-Reference partially skipped` にマッチする行が含まれている場合:
 - レビュー結果に `cross_reference_partial_skip: true` と外部リポジトリ情報 (META ブロック本文) を set
 - ステップ 5.4 (Integrated Report) の Doc-Heavy PR Mode 検証状態セクションに表示
 - ステップ 5.3 の overall assessment 判定時、ユーザーに明示的な acknowledgement を `AskUserQuestion` で求める
 - acknowledgement なしでマージ判定を下さない (`修正必要` 扱い)

##### Step 4.5: Inconclusive variant 検出 (`internal-consistency.md` 連携)

[`internal-consistency.md`](./references/internal-consistency.md#inconclusive-verification-handling) は、Verification Protocol の各 step で `target_not_found` / `extraction_failed` / `tool_failure` のいずれかが発生した場合、reviewer が META 行を `(a + inconclusive)` / `(b + inconclusive)` 形式で出力することを義務付けている。本 Step は、これら inconclusive variant の検出と acknowledgement プロセスを発火させる責務を持つ:

- tech-writer の出力に以下の正規表現 (multiline mode) のいずれかがマッチする場合、`inconclusive_count` を抽出する:
 - `(?m)(?:^|<br\s*/?>|[\s|>(])\s*META:\s*All 5 verification categories executed,\s*0 inconsistencies found,\s*but\s*(\d+)\s*categor(?:y|ies)\s*were inconclusive` ((a + inconclusive) variant、`{N}` を group 1 で capture)
 - `(?m)(?:^|<br\s*/?>|[\s|>(])\s*META:\s*All 5 verification categories executed,\s*but\s*(\d+)\s*categor(?:y|ies)\s*were inconclusive` ((b + inconclusive) variant、同上)
- マッチした場合の処理:
 1. レビュー結果に `inconclusive_count: {N}` と inconclusive カテゴリ一覧 (`Inconclusive: [...]` の `[ ]` 内をパースして配列化) を `inconclusive_categories` flag に set
 2. **inconclusive_count >= 1 の場合**、ステップ 5.3 の overall assessment 判定時に Step 4 (Cross-Reference partial skip) と**同じ acknowledgement プロセス**を発火する: `AskUserQuestion` で「{N} 件の verification category が inconclusive ({carriers}) ですが、続行しますか?」を確認し、ユーザーが明示的に承認しない限り `修正必要` 扱いとする
 3. acknowledgement 取得後は `inconclusive_acknowledged: true` を retained flag に set し、ステップ 5.4 Integrated Report の Doc-Heavy PR Mode 検証状態セクションに inconclusive 件数とカテゴリを表示する
- マッチしない場合 (= inconclusive 報告なし) は Step 4.5 を no-op で完了する


**Implementation note**: 本 Post-Condition Check は ステップ 5.2 (Cross-Validation) の **前**に実行する。これにより evidence 欠落が cross-validation の対象になる前に検出され、tech-writer の再実行判断が早期に下せる。

**Retained flags** (ステップ 5.4 template 表示用):
- `numstat_availability`: `"OK"` (success path) / `"unavailable"` (failure path) — ステップ 1.2.6 でいずれの path でも explicit set される
- `numstat_fallback_reason`: success path では `""` (空文字列)、failure path では numstat 失敗時のエラー 1 行要約 — ステップ 1.2.6 でいずれの path でも explicit set される
- `doc_heavy_pr_value`: `{doc_heavy_pr}` の boolean 値 (ステップ 1.2.7 で set)
- `doc_heavy_pr_decision_summary`: Doc-Heavy 判定根拠の 1 行要約 (例: `"doc_lines_ratio=0.72 >= 0.6"` / `"rite plugin self-only, excluded"`)
- `doc_heavy_post_condition`: `passed` / `warning` / `error`
- `doc_heavy_finding_count`: tech-writer の finding count
- `evidence_missing_count`: evidence 欠落 finding の数
- `evidence_missing_list`: 欠落 finding の file:line 一覧
- `cross_reference_partial_skip`: boolean (内部判定用)
- `cross_reference_skip_status`: `"なし"` / `"あり"` (ステップ 5.4 表示用 — `cross_reference_partial_skip` の boolean を日本語ラベルに変換した文字列。template 列対応統一のため `{cross_reference_skip_status}` placeholder で参照される)
- `cross_reference_skip_details`: META ブロック本文 (外部参照情報)
- `acknowledgement_status`: `"不要"` / `"取得済み"` / `"未取得"` (ステップ 5.4 表示用 — `cross_reference_partial_skip == false` のとき `"不要"`、`true` のときはユーザー応答に基づき `"取得済み"` または `"未取得"`。ステップ 5.1.3 で必ず explicit set される)
- `inconclusive_count`: int (Step 4.5 で `(a + inconclusive)` / `(b + inconclusive)` variant から抽出した inconclusive カテゴリ数。デフォルト `0`)
- `inconclusive_categories`: list[str] (inconclusive となった category 名一覧。例: `["Implementation Coverage", "Screenshot Presence"]`)
- `inconclusive_acknowledged`: boolean (ステップ 5.3 の `AskUserQuestion` でユーザーが明示的に承認したか。`inconclusive_count == 0` の場合は `null` または未設定)
- `verification_post_condition`: `"passed"` / `"warning"` / `"error"` (ステップ 5.1.1.1 で set される。`review_mode == "full"` のときは `"passed"` とみなす。ステップ 5.4 template の Doc-Heavy PR Mode 検証状態セクションと同型に表示用)
- `verification_post_condition_retry_count`: dict `{reviewer_type: int}` (ステップ 5.1.1.1 の per-reviewer retry counter。初期値は空 dict `{}`、各 reviewer に対して retry 1 回まで許可)

**ステップ 5.4 表示責務の分離**: `doc_heavy_pr == false` (ratio 未満 / rite plugin self-only 除外 / 空 PR のいずれか) の場合、ステップ 5.1.3 の post-condition check 自体はスキップされるが、ステップ 5.4 Integrated Report の Doc-Heavy PR Mode 検証状態セクションでは `numstat_availability` と `doc_heavy_pr_value` を上記 retained flags から参照して表示する。これにより numstat 失敗の可視性は ステップ 5.1.3 スキップとは独立に保たれる。


### 5.2 Cross-Validation

**Same file/line check**: Group by `file:line`. 2+ reviewers → mark "High Confidence" + boost severity (LOW→MEDIUM→HIGH→CRITICAL).

**Contradiction detection**: Two or more reviewers give assessments of the same `file:line` that cannot both be followed — opposite recommendations, or severity judgments so far apart that they imply different handling (per [Trigger Conditions in cross-validation.md](../../skills/reviewers/references/cross-validation.md#trigger-conditions)) → debate phase (5.2.1) if enabled, otherwise prompt user via `AskUserQuestion`.

**Quality Signal 3 — Cross-validation disagreement**: When reviewers report contradictory assessments of the same `file:line`, the sub-skill treats this as Signal 3 of the four quality signals. The outcome of the deliberation (5.2.1) determines whether Signal 3 fires:

- 検討の結果、合意に至った矛盾 → Signal 3 は**発火しない**（consensus reached）
- 検討しても決着せずユーザーへエスカレーションする矛盾（`debate.enabled: false` で直接のユーザー解決も行われず未解決のまま残る場合を含む）→ **Signal 3 発火** — pr-review.md sub-skill emits `[CONTEXT] QUALITY_SIGNAL=3_cross_validation_disagreement; file={file}:{line}; reviewers={A,B}; severity_gap={N}` to stderr (ensures conversation-context visibility for the orchestrator, per Sentinel Visibility Rule). The orchestrator grep-s this marker after the review skill returns and presents the shared escalation `AskUserQuestion` (options: 本 PR 内で再試行 / 別 Issue として切り出す / PR を取り下げる / 手動レビューへエスカレーション; see [finding-cycling.md §3](./references/finding-cycling.md))

**Emit site**: エスカレーションを決めた同じ turn の bash block で emit する:

```bash
echo "[CONTEXT] QUALITY_SIGNAL=3_cross_validation_disagreement; file=${file_line}; reviewers=${reviewer_a},${reviewer_b}; severity_gap=${gap}" >&2
```

**Steps:**

1. If there are multiple findings for the same `file:line`, compare the assessment content
2. If matching the contradiction patterns above, flag as a contradiction
3. Collect all detected contradictions for ステップ 5.2.1 (debate) or direct user resolution

**When contradictions are detected:**

Check `review.debate.enabled` in `rite-config.yml` (see [Configuration in cross-validation.md](../../skills/reviewers/references/cross-validation.md#configuration) for defaults):

| `review.debate.enabled` | Action |
|--------------------------|--------|
| **`true`** | Proceed to ステップ 5.2.1 (Debate Phase) for automatic resolution attempt |
| **`false`** | Prompt user directly with `AskUserQuestion` (legacy behavior, see below) |

**Direct user resolution (when debate is disabled):**

Prompt the user with AskUserQuestion for confirmation (fallback: see ステップ 1.4 note):

```
⚠️ 矛盾する指摘を検出:
ファイル: {file}:{line}

 {Reviewer A} の評価: {assessment_A}
 理由: {reason_A}

 {Reviewer B} の評価: {assessment_B}
 理由: {reason_B}

どちらの評価を採用しますか？
```

### 5.2.1 Debate Phase (Contradiction Deliberation)

> **Reference**: See [Debate Protocol in cross-validation.md](../../skills/reviewers/references/cross-validation.md#debate-protocol) for the deliberation principles, escalation conditions, and escalation format.

**Execution condition**: Execute only when:
1. Contradictions were detected in ステップ 5.2
2. `review.debate.enabled: true` in `rite-config.yml`

**Skip condition**: When no contradictions are detected, skip this phase entirely and proceed to Deduplication.

**Configuration loading:**

Read `review.debate` from `rite-config.yml` (defaults defined in [cross-validation.md Configuration](../../skills/reviewers/references/cross-validation.md#configuration)):
- `enabled`: Enable/disable debate phase
- `max_rounds`: 1 矛盾あたりの検討回数の上限（決着しない検討を延々と続けないためのガード）

**Deliberation principle** — for each detected contradiction:

- **CRITICAL guard**: Either finding is CRITICAL severity → skip the deliberation for this contradiction and escalate immediately to the user per [Escalation Conditions](../../skills/reviewers/references/cross-validation.md#escalation-conditions)（CRITICAL の扱いを自動判断で下げない）
- Execute the deliberation internally within the main context (not via the Task tool): 両 reviewer の主張と証拠を実コードと突き合わせ、それぞれの立場から相手の論点の妥当な部分を認めた上で最終見解を出す
- **決着判断**: 検討の結果、両論が同じ対応（fix / accept / modify）を支持できるなら合意として採用する。対応は一致するが severity の見解が割れる場合は、乖離幅に関わらず**高い方の severity を採用**する（見逃しより過剰警告を許容）。`max_rounds` 回検討しても対応そのものが相反したままなら決着不能 — [Escalation Conditions](../../skills/reviewers/references/cross-validation.md#escalation-conditions) に従いユーザーへエスカレーションする

**Auto-resolved findings**: Replace the original contradicting findings with the agreed-upon finding. Mark in the integrated report (ステップ 5.4) as "討論で合意" (agreed through deliberation).

**Escalated findings**: Present to user via `AskUserQuestion` using the [Escalation format](../../skills/reviewers/references/cross-validation.md#escalation-conditions). The escalation format includes the deliberation history (each reviewer's final position and concessions) to give the user richer context for their decision. Map the escalation format's `オプション:` choices directly to `AskUserQuestion` options.

**Output summary** (displayed inline within ステップ 5.2.1 after all contradictions are processed, before proceeding to Deduplication):

```
討論フェーズ完了: 矛盾 {n} 件 — 合意 {m} 件 / エスカレーション {k} 件
```

#### Deduplication

**Steps:**

1. Check multiple findings for the same `file:line`
2. If the content is similar, merge into a single finding:
 - Severity: Adopt the highest
 - Description: Merge into a description integrating multiple perspectives
 - Note: Append "Flagged by multiple reviewers"

#### Fact-Checking Phase

> **Reference**: See [Fact-Checking Phase specification](./references/fact-check.md) for the full protocol (claim classification, verification execution, finding modification rules).

**Execution condition**: Execute only when:
1. `review.fact_check.enabled: true` in `rite-config.yml`
2. At least 1 external specification claim is detected among findings

**Skip condition**: When `enabled: false` OR 0 external claims detected, skip this phase entirely and proceed to Specification Consistency Verification.

**Configuration loading:**

Read `review.fact_check` from `rite-config.yml`:
- `enabled`: Enable/disable fact-checking phase (default: `true`)
- `max_claims`: Maximum claims to verify per review (default: `10`)

**Execution flow:**

1. Classify all findings into internal vs external claims per [Claim Classification](./references/fact-check.md#claim-classification). Scan `内容` and `推奨対応` columns for signal keywords (library behavior, tool configuration, version-specific behavior, API compatibility, CVE, external best practices, runtime behavior).
2. If external claims > `max_claims`: sort by severity, verify top `max_claims`, mark remainder as `UNVERIFIED:リソース超過` (blocking maintained).
3. For each external claim (up to `max_claims`): verify via WebSearch/WebFetch per [Verification Execution](./references/fact-check.md#verification-execution).
4. Modify findings based on verification results per [Finding Modification Rules](./references/fact-check.md#finding-modification-rules):
 - VERIFIED (✅): Keep in `全指摘事項`, append source URL to `推奨対応`
 - CONTRADICTED (❌): Remove from `全指摘事項` AND `高信頼度の指摘`, move to dedicated section
 - UNVERIFIED:ソース未確認 (⚠️): Remove from both sections (blocking removed), move to dedicated section
 - UNVERIFIED:リソース超過: Keep in `全指摘事項` (blocking maintained), add annotation
5. Output inline summary per [Fact-Check Metrics](./references/fact-check.md#fact-check-metrics).

**Verification mode**: When `review_mode == "verification"`, previously VERIFIED findings are not re-verified; source URLs are inherited from the previous review comment. See [Verification Mode Handling](./references/fact-check.md#verification-mode-handling).

#### Specification Consistency Verification

**Execution condition**: Execute only when `{issue_spec}` was obtained in ステップ 1.3.1. Skip if no specification information is available.

**Purpose**: Integrate each reviewer's "Specification Consistency" assessment and verify there are no specification violations.

**Steps:**

1. Collect the "### 仕様との整合性" sections from each reviewer's output
2. Extract items assessed as "不整合" or "未実装"
3. Processing when specification inconsistency is detected:

**When specification inconsistency is detected:**

```
⚠️ 仕様との不整合を検出しました

| 仕様項目 | 状態 | 指摘レビュアー | 詳細 |
|---------|------|--------------|------|
| {spec_item} | 不整合 | {reviewer} | {details} |

仕様不整合は CRITICAL として扱い、マージ前に修正が必要です。
```

**When there are "Questions about the specification":**

If reviewers have written items in the "仕様への疑問" section, prompt the user with `AskUserQuestion` for confirmation:

```
仕様に関する確認事項があります

レビュー中に、仕様自体への疑問が検出されました:

{questions_from_reviewers}

この疑問についてどう対応しますか？

オプション:
- 仕様どおりで問題ない（現在の実装を承認）
- 仕様を修正する（Issue を更新してから再レビュー）
- 実装を修正する（仕様に合わせて修正）
- 詳細を説明する
```

**When "No issues with the specification as-is" is selected:**
- Mark the question as resolved and continue the review
- Record as "Specification confirmed" in the integrated report

**When "Modify the specification" is selected:**
- Pause the review
- Prompt the user to update the Issue and recommend re-review after updating

**When "Modify the implementation" is selected:**
- Add the item as "Specification inconsistency (fix required)" to the findings
- Continue the review and output the result as requiring fixes

### 5.3 Overall Assessment Determination

Claude aggregates all reviewer assessments and findings, and **evaluates the following logic from top to bottom**. The result of the first matching condition is adopted as the overall assessment.

**Execution order** (mechanical, from top to bottom):

1. **Apply 5.3.0 Observed Likelihood Gate (Post-Reviewer Safety Net)** first — update `全指摘事項` by mechanically demoting findings that lack a `Likelihood-Evidence:` anchor (see `_reviewer-base.md#observed-likelihood-gate` for the reviewer-side primary Gate). Findings moved to `推奨事項` are NOT counted in `total_findings`. Findings removed (LOW × Hypothetical) are dropped entirely. Record demoted findings in the `### Observed Likelihood 降格結果` section of the ステップ 5.4 integrated report.
2. **Apply 5.3.0.M 実測必須ゲート (Measured CONFIRMED Gate)** second — **下記 5.3.0.M の手順で `scripts/review-measured-gate.sh` を実行する**。分類 (アンカー検出 → `verification` 設定 → `non_blocking_findings[]` への移送 → `overall_assessment` 確定) は helper が決定論的に行い、Claude は判定しない。ゲート定義の SoT は [severity-levels.md §実測必須ゲート](../../references/severity-levels.md#実測必須ゲート-measured-confirmed-gate)、集合演算の SoT は [assessment-rules.md §5.3.0.M](../fix/references/assessment-rules.md)。
3. **Apply 5.3.1-5.3.7 assessment rules** on the post-5.3.0.M `全指摘事項` (= measured=true の blocking 指摘のみが残った集合). 件数は 5.3.0.M の `[CONTEXT] MEASURED_GATE=` marker とゲート適用後 JSON から読み取る (再分類しない)。

Skipping 5.3.0 / 5.3.0.M before 5.3.1 is **prohibited**: the Red blocking rule in 5.3.1 operates on `全指摘事項` *after* both demotions, not before.

#### 5.3.0.M 実測必須ゲート実行手順 (helper 委譲)

> **Why helper 委譲 (Issue #2072)**: 旧版は本ゲートを LLM の推論ステップとして書いていた。「自分の指摘を non-blocking 化して mergeable を宣言する」判断は reviewer 群の thoroughness 指示と正面衝突するため、裁量に置く限り構造的に実行されにくい — PR #2070 では 9 サイクルすべてで一度も降格が実行されず、契約上 merge を止めてはならない散文精度指摘でループが 8 時間超継続した。分類を bash へ移し、mergeable 判定 (5.3.1) が LLM の分類を経由しない配置にする。

**step 1: レビュー結果 JSON の生成 (本 review cycle で唯一の JSON authoring site)**

Claude は [review-result-schema.md](../../references/review-result-schema.md) に従う JSON 本文を生成し、**Write tool で `{review_tmp_dir}/rite-review-result-{pr_number}.json` に保存**する。`{review_tmp_dir}` は下記 bash が emit する `[CONTEXT] REVIEW_TMP_DIR=` marker の値をリテラル置換する (Write tool は `${TMPDIR:-/tmp}` を展開できないため。sandbox 環境では `/tmp` 直下が読み込み専用 — Issue #1904)。

```bash
echo "[CONTEXT] REVIEW_TMP_DIR=${TMPDIR:-/tmp}" >&2
```

生成規約 (**ステップ 6.1.a / 6.1.b は本ファイルを読むだけで再生成しない** — 生成箇所を 2 つ以上に分けると、ゲート適用後のローカル JSON が `mergeable` なのに PR コメントの Raw JSON は `fix-needed` という乖離が出る):

- `findings[]` = **post-5.3.0 の `全指摘事項`** (5.3.0 の Observed Likelihood Gate で `推奨事項` へ降格・削除した finding は含めない)。`scope == "nit-noted"` の finding も含める (本ゲートの対象外として helper が findings[] に残す)
- `non_blocking_findings[]` = `[]` (本ゲート適用前は常に空。helper が移送先として使う)
- `overall_assessment` = 暫定値でよい。**helper が blocking 件数から両方向で確定する**ため Claude の値は判定に影響しない
- **`findings[].verification` は書かない** — 本フィールドは helper が `description` のアンカーから算出する唯一の書き手である。Claude が先に書くと helper は既存値を正として尊重し (§4.5)、アンカー検出を経ない値がそのまま blocking 判定に入る (= 本ゲートが閉じたはずの裁量が復活する)。**この規約は step 2 の `--reject-preset-verification` が機械的に強制する** — 違反すると `reason=verification_preset_by_caller` で停止し、JSON は書き換えられない (散文の禁止だけに頼らないのは、PR #2070 cycle 2-9 で LLM が指示なく verification を書いた実績があるため)
- `timestamp` は literal sentinel `"__RITE_TS_PLACEHOLDER_7f3a9b2c__"` (実値は ステップ 6.1.a の helper が注入する)
- `suppressed_findings` 除外契約 (ステップ 5.1.2.A) を本 JSON 生成時に適用する — `findings[]` から除外し、Markdown 側 (ステップ 5.4 / 6.1.b) には audit log として残す
- 必須フィールドと各 finding のフィールド定義は ステップ 6.1.a の「Required JSON fields」節を参照する (定義の重複を避けるため本節では再掲しない)

**step 2: ゲート適用**

```bash
# ステップ 5.3.0.M: 実測必須ゲート — scripts/review-measured-gate.sh へ委譲済。
# helper 契約: 2 段アンカー判定 / measured=false かつ scope ∈ {current-pr, follow-up} の
# non_blocking_findings[] への append 移送 / blocking 件数からの overall_assessment 両方向確定 /
# 冪等 / 失敗は非ゼロ終了。SoT は helper docstring。
# --reject-preset-verification: step 1 の「verification は書かない」規約を機械的に強制する
# (散文の指示だけでは、実際に PR #2070 cycle 2-9 で LLM が verification を書いた実績がある)。
# 本フラグは caller 契約違反だけを弾き、素の再実行 (recover 等) の冪等性は変えない。
bash {plugin_root}/scripts/review-measured-gate.sh \
  --input {review_tmp_dir}/rite-review-result-{pr_number}.json \
  --reject-preset-verification
```

**step 3: marker の読み取りと routing**

| 観測 | LLM action |
|---|---|
| `[CONTEXT] MEASURED_GATE=applied; blocking={n}; demoted={d}; non_blocking_total={t}; assessment={a}` | ゲート適用成功。`total_findings = {n}`、`non_blocking_count = {t}`、`overall_assessment = {a}` として 5.3.1 以降へ進む (再分類しない) |
| `[CONTEXT] MEASURED_DEMOTED_ON_ANCHOR=1; count={n}; cause=anchor_unparseable` (WARNING と対) | アンカーはあるが正規形でない finding が降格された。**silent 降格の唯一の検出層**として会話コンテキストに残す (ステップ 6 Retained flag mapping 登録済)。ゲート自体は成功しているので続行する |
| `[CONTEXT] MEASURED_GATE_FAILED=1; reason=...` (helper 非ゼロ終了) | **`[review:error]` を stdout に出力して停止する。LLM 分類へ fallback してはならない** — fallback は本ゲートが閉じた不発の再生産になる |

`findings[]` が元から空の場合、helper は移送 0 件・`assessment=mergeable` を返す (現行動作維持)。


### 5.3.8 Fix-Introduced Finding Attribution

When this is a **re-review after a fix** (verification mode or `loop_count >= 1`), attribute each finding to one of three categories to enable convergence monitoring.

**Step 1**: Determine if attribution is applicable:

```bash
# `if ! var=$(cmd); then rc=$?` は bash 仕様上 `$?` が常に 0 になるため、capture と exit code を
# 両方取る場合は if/else 形式にする。
if loop_count=$(bash {plugin_root}/hooks/flow-state.sh get --field loop_count --default 0); then
 :
else
 rc=$?
 echo "ERROR: flow-state.sh failed (rc=$rc) for --field loop_count in ステップ 5.3.8" >&2
 echo "[CONTEXT] STATE_READ_FAILED=1; phase=phase5_3_8_loop_count; rc=$rc" >&2
 echo "RESUME_HINT: flow-state.sh が異常 exit (rc=$rc) しました。ファイル不在/empty/jq parse 失敗は --default で吸収 (exit 0) されるため、本経路は helper validation 失敗 / --field 引数欠落 / invalid field name 等の caller 側引数異常で発火します。\$PLUGIN_ROOT/hooks/_validate-helpers.sh と state-path-resolve.sh の存在/実行権限を確認し、必要なら /rite:recover で再開、または STATE_ROOT 配下の sessions/ を確認してください。" >&2
 exit 1
fi
# non-numeric injection 経路 (`{"loop_count": "true"}` 等) を遮断し、後続 integer 比較が
# silent regression する経路を fail-safe で default 0 に降格する。
case "$loop_count" in
 ''|*[!0-9]*)
 echo "WARNING: loop_count is not numeric ('$loop_count'), defaulting to 0 (treat as first review)" >&2
 loop_count=0
 ;;
esac
if [ "$loop_count" -lt 1 ]; then
 echo "[CONTEXT] FINDING_ATTRIBUTION skip (first review, loop_count=$loop_count)"
 exit 0
fi
```


**Step 2**: Identify files changed by the last fix commit vs original PR files:

```bash
pr_number="{pr_number}"
base_branch="{base_branch}"

# Files in the original PR (before any fixes)
# Use the first commit on the PR branch
first_commit=$(git log --reverse --format="%H" "${base_branch}..HEAD" 2>/dev/null | head -1)
if [ -n "$first_commit" ]; then
 original_files=$(git diff --name-only "${base_branch}...${first_commit}" 2>/dev/null || echo "")
else
 original_files=$(git diff --name-only "${base_branch}...HEAD" 2>/dev/null || echo "")
fi

# Files changed by the last fix commit
fix_files=$(git diff --name-only HEAD~1..HEAD 2>/dev/null || echo "")

original_files_count=$(echo "$original_files" | grep -c . 2>/dev/null || true)
fix_files_count=$(echo "$fix_files" | grep -c . 2>/dev/null || true)
printf '[CONTEXT] ATTRIBUTION original_files=%d fix_files=%d\n' \
 "${original_files_count:-0}" "${fix_files_count:-0}"
```

**Step 3**: For each finding in the consolidated findings table, classify:

| Category | Criteria | Label |
|----------|----------|-------|
| **Original** | Finding is in a file that is in `original_files` AND the finding's code existed before the fix | `[original]` |
| **Fix-introduced** | Finding is in a file that is in `fix_files` AND the finding's code was added by the fix commit | `[fix-introduced]` |
| **Propagation-missed** | Finding matches a pattern that was already fixed in another location (same error pattern, different file/line) | `[propagation-missed]` |


**Step 4**: Write attribution summary to fix-cycle-state:

Claude substitutes `{total_findings}`, `{fix_introduced_count}`, `{critical_count}`, `{high_count}`, `{medium_count}`, `{low_medium_count}`, `{low_count}` with the actual integer values from Step 3 classification results before generating the bash block.

```bash
pr_number="{pr_number}"
# fix-cycle-state もリポジトリ共通 state ルート基準 (fix.md ステップ 3.3.1 の書込側と同一解決)
_state_root=$(bash {plugin_root}/hooks/state-path-resolve.sh 2>/dev/null) || _state_root=""
[ -n "$_state_root" ] || { echo "WARNING: state-path-resolve.sh の解決に失敗。cwd をフォールバック使用します" >&2; _state_root="$(pwd)"; }
state_file="$_state_root/.rite/fix-cycle-state/${pr_number}.json"
total_findings="{total_findings}"
fix_introduced_count="{fix_introduced_count}"
critical_count="{critical_count}"
high_count="{high_count}"
medium_count="{medium_count}"
low_medium_count="{low_medium_count}"
low_count="{low_count}"

if [ -f "$state_file" ]; then
 jq --argjson total "$total_findings" \
 --argjson fix_introduced "$fix_introduced_count" \
 --argjson severity "{\"CRITICAL\":$critical_count,\"HIGH\":$high_count,\"MEDIUM\":$medium_count,\"LOW-MEDIUM\":$low_medium_count,\"LOW\":$low_count}" \
 '.cycles[-1].findings_total = $total | .cycles[-1].findings_new_from_fix = $fix_introduced | .cycles[-1].findings_by_severity = $severity' \
 "$state_file" > "${state_file}.tmp" && mv "${state_file}.tmp" "$state_file"
 printf '[CONTEXT] ATTRIBUTION_WRITTEN total=%d fix_introduced=%d\n' "$total_findings" "$fix_introduced_count"
fi
```


### 5.4 Integrated Report Generation

**Emoji usage**: Follow the emoji policy in `skills/reviewers/SKILL.md`; use emojis only in the integrated report header (`📜 rite レビュー結果`) and important warnings. Do not use emojis in each reviewer's findings.

テンプレート本文 (full mode / verification mode の 2 種) は [references/integrated-report-templates.md](references/integrated-report-templates.md) を参照（[full mode](references/integrated-report-templates.md#full-mode-template) / [verification mode](references/integrated-report-templates.md#verification-mode-template)。placeholder は本 SKILL.md の各ステップで retain した値を展開する）。

**Template selection:**

| review_mode | Template Used |
|-------------|-------------------|
| **`full`** | Full review mode template |
| **`verification`** | 統合テンプレート（検証サマリー + フルレビューセクション含む） |

**Note**: `📎 reviewed_commit: {current_commit_sha}` must be output in both templates. This is used for incremental diff retrieval in the verification mode of the next cycle (ステップ 1.2.4).

**`### 実測なし指摘 (non-blocking)` section の情報源**: ステップ 5.3.0.M でゲート適用済の `{review_tmp_dir}/rite-review-result-{pr_number}.json` の `non_blocking_findings[]` を Read tool で読んで描画する (Issue #2072)。会話コンテキストから記憶で再構成しない — 記憶と JSON がずれると、永続 JSON・PR 記録コメント・本 section の 3 経路が別々の集合を主張する。件数 `{non_blocking_count}` は 5.3.0.M の `[CONTEXT] MEASURED_GATE=...; non_blocking_total=` の値と一致する。

---

## ステップ 6: 結果出力

### 6.1 Output Review Result (Local Save + Conditional PR Comment + Non-measured Record)

Output the review results via three independent paths. Use `mktemp` + `--body-file` to safely handle markdown content for the PR comment path.

This phase now performs **three independent outputs**:
1. **Local JSON file save** (always, even when `{post_comment_mode}=false`)
2. **PR comment post** (only when `{post_comment_mode}=true` from ステップ 1.0)
3. **非実測指摘の記録コメント** (always — `{post_comment_mode}` に**依存しない**。ステップ 6.1.d。既定設定 `post_comment: false` でも 6.1.b / 6.1.c 完了後に必ず評価する)

ステップ 6 failure reasons (reason 表の本文は `common-error-handling.md#jq-required-fields-snippet-canonical` の canonical jq snippet を参照):

| reason (ステップ 5.1.2.A、pr-review.md 本文が emit) | Description |
|--------|-------------|
| `pr_number_placeholder_residue` | ステップ 5.1.2.A (fingerprint, `FINGERPRINT_COMPUTE_FAILED`) で `pr_number` が数値以外のとき emit。ステップ 6.1.a (`review-result-save.sh`, `LOCAL_SAVE_FAILED`) も同名 reason を emit する (下記 6.1.a bullet 参照) |

> **Note**: ステップ 6.1.a / 6.1.b / 6.1.c の reason は委譲先 helper が emit する (`hooks/review-result-save.sh` / `hooks/review-comment-post.sh` / `hooks/review-skip-notification.sh`、SoT は各 helper の docstring)。委譲済 reason は「この SKILL.md 自身が emit する reason」と区別できるよう **markdown table 行にせず bullet 形式**で列挙し、本文 prose でも `reason=...` 構文を使わず bare backtick 名で参照する。helper の stderr `[CONTEXT]` emit は caller の bash 出力として LLM コンテキストに surface するため、下記 reason はレビュー flow 上で従来どおり観測される。

**ステップ 6.1.a reasons** (`review-result-save.sh` が `[CONTEXT] LOCAL_SAVE_FAILED=1; reason=...` を emit、全て **WARNING only / 非ブロッキング**):
- `pr_number_placeholder_residue`: `--pr` が数値以外 (空文字 / placeholder 残留) のまま渡された (cleanup.md ステップ 6 の numeric gate と対称化し永久 orphan 化を防ぐ)
- `date_command_failure`: `TZ='Asia/Tokyo' date` の実行が失敗 (空 timestamp による file 上書きを防止)
- `mkdir_failure`: `.rite/review-results/` directory creation failed
- `mktemp_failure`: JSON tmpfile allocation failed
- `write_failure`: JSON content の tmpfile への書き込み失敗、または jq timestamp 注入 (`jq '.timestamp = $ts'`) の失敗。後者は注入が入力 JSON を parse するため発火する経路で、**syntactically invalid JSON / literal JSON body substitute 漏れの実検出 reason はこちら** (後続 `json_invalid` の `jq empty` より先に評価される)
- `timestamp_injection_mv_failure`: timestamp 注入後 inner mv (`mv "$json_ts_injected" "$json_tmp"`) が失敗 (sentinel 残留 JSON を final path に書かないため後続処理を skip)
- `json_invalid`: timestamp 注入成功後の `jq empty` post-condition backstop。注入段階 (`write_failure`) が入力 JSON を parse・再シリアライズして valid JSON を保証するため、syntactic invalidity はこの check に到達せず実際は `write_failure` として発火する。defense-in-depth の保険として残置 (effectively unreachable)
- `schema_required_fields_missing`: JSON は parse 可能だが必須フィールド (schema_version / pr_number / findings[] 配列型) が欠落
- `finding_id_format_or_uniqueness_violation`: **`findings[]` 側**の id が `^F-[0-9]{2,}$` 書式違反または重複 (`non_blocking_findings[]` 側に閉じた id 欠陥は非ブロッキング marker `NON_BLOCKING_FINDINGS_ID_UNION_VIOLATION` に落ち、本 reason には計上されない)
- `scope_enum_violation`: schema 1.1.0 JSON で findings[].scope が enum 違反 (期待: `current-pr` / `follow-up` / `nit-noted`)
- `critical_high_scope_nit_noted_invariant`: schema 1.1.0 JSON で cross-field invariant #4 違反 (severity ∈ {CRITICAL, HIGH} × scope == nit-noted)
- `collision_resolution_exhausted`: 同一秒衝突回避 `~<4桁hex>` suffix を付与しても再衝突を検出 (同秒 3 回目以上 / `$RANDOM` fallback `0` / parallel race、後続 mv を skip して silent overwrite を防ぐ)
- `mktemp_failure_mv_err`: mv stderr 退避用 tempfile の mktemp が失敗 (mv 失敗時の stderr 詳細が失われるため explicit に通知)
- `mv_failure`: Atomic move of JSON tmpfile to final path failed

**ステップ 6.1.b reasons** (`review-comment-post.sh` が `[CONTEXT] REVIEW_OUTPUT_FAILED=1; reason=...` を emit、**hard error として ステップ 6 を fail**。例外: `post_comment_mode=false` 誤呼出は silent skip exit 0):
- `p61b_post_comment_mode_invalid`: `--post-comment-mode` が `true`/`false` 以外
- `p61b_pr_number_invalid`: `--pr` が literal substitute されていない / 数値以外 (`p61c_pr_number_invalid` と対称)
- `json_saved_from_p61a_unset`: `--json-saved` が `true`/`false` 以外 (ステップ 6.1.a の `[CONTEXT] JSON_SAVED=` 読取漏れ)
- `iso_timestamp_from_p61a_unset`: `--iso-timestamp` が ISO 8601 形状でない (sentinel 残留 / 空文字 / placeholder 形式 / 非 ISO 形状を allowlist で一括 reject — ステップ 6.1.a の `[CONTEXT] ISO_TIMESTAMP=` 読取漏れ)。ステップ 6.1.a の早期失敗 degraded 値 `unknown` も reject される (期待動作 — 再投入では解決せず、6.1.a の `LOCAL_SAVE_FAILED` reason の解消が必要。helper が専用診断を表示する)
- `tmpfile_write_failure`: PR コメント本文の中間 tmpfile (mktemp) 失敗、または `--content-file` 不在
- `raw_json_timestamp_injection_failed`: Raw JSON セクション内 sentinel の awk 置換 / post-condition (Raw JSON 内残留なし / Markdown 不変) が失敗
- `gh_comment_post_failure`: `gh pr comment` 投稿が exit != 0 で失敗 (network / auth / rate-limit / permission、rc>=128 時は signal 番号併記)

**ステップ 6.1.c reasons** (`review-skip-notification.sh` が `[CONTEXT] REVIEW_OUTPUT_FAILED=1; reason=...` を emit。ケース 2 の `p61c_persistence_unrecoverable` は **hard error として ステップ 6 を `exit 2` で fail**、その他の gate 違反は exit 1。正常経路 `post_comment_mode=false` は続行):
- `p61c_post_comment_mode_invalid`: `--post-comment-mode` が `false` 以外 (`true` 誤呼出 / 不正値、`p61b_post_comment_mode_invalid` と対称)
- `p61c_pr_number_invalid`: `--pr` が literal substitute されていない / 数値以外 (`p61b_pr_number_invalid` と対称)
- `p61c_file_timestamp_unset`: `--file-timestamp` placeholder が literal substitute されていない
- `p61c_file_timestamp_unknown_without_failure`: `file_timestamp='unknown'` だが `local_save_failed != '1'` (整合性違反、ケース 1 での `.../unknown.json` 誤提示を遮断)
- `p61c_local_save_failed_invalid`: `--local-save-failed` が不正値 (空文字/0/1 以外)
- `p61c_persistence_unrecoverable`: ケース 2 (`post_comment_mode=false` ∧ `LOCAL_SAVE_FAILED=1`) で silent data loss 防止のため ステップ 6 全体を `exit 2` で fail

**ステップ 6.1.d reasons** (`review-nonblocking-record.sh` が `[CONTEXT] NONBLOCKING_RECORD_FAILED=1; reason=...` を emit。**記録の成否は `overall_assessment` を変えない** (AC-3)。ただし **result pattern を emit してよいかの可否**は別で、本文検査 4 段 (`body_file_empty` / `body_marker_missing` / `body_sentinel_missing` / `count_body_mismatch`) と caller 契約違反 7 種では pending marker が残るため ステップ 8.0.3 が差し戻す。**caller 契約違反 7 種** (placeholder residue 5 種 + `content_file_missing` + `unknown_option`) は skill 定義のバグのため `exit 1` で loud に落とす。Non-blocking Contract の canonical 定義は [common-error-handling.md#non-blocking-contract-canonical-定義](../../references/common-error-handling.md#non-blocking-contract-canonical-定義)、reason 語彙の SoT は helper docstring、gate 集合と Issue の MUST list の差分は [references/measured-gate-record.md#placeholder-gate-mapping](references/measured-gate-record.md#placeholder-gate-mapping) を参照):
- `pr_number_placeholder_residue`: `--pr` が数値以外 (`exit 1`)。**flag namespace が異なるため 6.1.a の同名 reason (`LOCAL_SAVE_FAILED`) とは別物** — 6.1.d は `NONBLOCKING_RECORD_FAILED` で emit する
- `owner_repo_placeholder_residue`: `--owner-repo` が allowlist を満たさない (`exit 1`)。ブレース残留・空白に加え、**3 セグメント `HOST/OWNER/REPO`**・パストラバーサル・許可外文字も拒否する (`gh -R` は先頭セグメントをホスト名として解釈するため、3 セグメント値は記録を別 GitHub インスタンスへ送出する)。reason 名は placeholder 由来だが trigger は「形式不正一般」であり、`pr_number_placeholder_residue` (数値以外すべて) と同じ粒度
- `non_blocking_count_placeholder_residue`: `--count` が数値以外 (`exit 1`)。0 件時も `--count 0` を明示的に渡す (空文字は substitute 漏れと区別できない)
- `iteration_id_placeholder_residue`: `--iteration-id` が未置換 (`exit 1`)。未置換のままでは gate の cycle 一致判定が恒久的に成立しない
- `content_file_placeholder_residue`: `--content-file` のパスにブレースが残留 (`exit 1`)。`body_file_empty` と融合させない (skill 定義のバグと本文生成失敗は復旧手順が異なる)
- `content_file_missing`: `--content-file` のパスにファイルが存在しない (`exit 1`)。step 1 の Write tool 呼び出し漏れ = caller 契約違反であり IO 失敗ではないため loud に落とす (非空検査に潰すと記録ゼロのまま gate が pass する)
- `body_file_empty`: 本文ファイルは存在するが空のため投稿を中止 (非ブロッキング、`exit 0`)。空 body の PATCH は 1 行目 marker を消し以降の lookup を恒久破綻させる。caller 契約違反のため **pending marker を残す** (8.0.3 が差し戻す)
- `body_marker_missing`: 本文 1 行目が marker 見出しで始まっていないため投稿を中止 (非ブロッキング、`exit 0`)。空 body と同じ破綻 (1 行目 marker の消失) を非空本文でも起こすため、`body_file_empty` と別 reason で検査する。caller 契約違反のため **pending marker を残す** (8.0.3 が差し戻す)
- `body_sentinel_missing`: 本文の**最終非空行**が機械専用 sentinel `<!-- rite:nbr:v1 -->` と一致しないため投稿を中止 (非ブロッキング、`exit 0`)。sentinel は lookup 述語の第 3 条件 (**最終非空行の等値**) であり、欠いた本文や sentinel を本文途中にだけ持つ本文を投稿すると次 cycle の lookup が自分の投稿を検出できず記録コメントが cycle ごとに増殖する (1 行目 marker 欠落と同じ結末を別条件で起こすため別 reason)。read 側が最終非空行の等値なので write 側も**同一の jq 述語**で検査する (片側だけ緩いと人間のコメントを掴んで破壊し、片側だけ厳しいと増殖する)。caller 契約違反のため **pending marker を残す**
- `body_check_unavailable`: 本文の最終非空行を算出する jq の**評価自体が失敗**した (jq 不在 / 実行不能 等の環境起因、非ブロッキング、`exit 0`)。`body_sentinel_missing` と発生位置は同じだが**原因が違う** — 本文を作り直しても解消しないため pending marker は**残さず**、gh / IO 起因と同じ無条件削除バケットに属する (8.0.3 は差し戻さない)。**ACTION**: jq の実行環境を確認する (`jq --version`)。本文の再生成は無効。stderr に jq の診断が転記されるので原因はそこを見る。
- `count_body_mismatch`: 本文中の `📎 non_blocking_count: {n}` 行の値と `--count` が不一致 (非ブロッキング、`exit 0`)。ステップ 6.1.d step 1 の本文 variant 選択と step 2 の `--count` 置換は LLM の 2 つの独立した置換であり、片方だけずれると事実と異なる記録が投稿される (`--count 0` + variant A 本文 で 0 件のはずが記録が無音で消える、あるいは逆に `--count N>0` + variant B「0 件」本文 で虚偽の記録が残る)。投稿を中止して非ブロッキングに `outcome=failed` へ倒すことで、両 gate (6.1.d step 3 / 8.0.3) の既存の転記条件に自動的に載せ、無音喪失/虚偽記録を observable にする。**ACTION**: caller (LLM) 起因で決定論的に再現するため (gh / network とは無関係)、step 1 の本文生成と step 2 の `--count` 置換を再確認し、6.1.d step 1-2 を再実行して記録を復旧する。**6.1.d step 3 と 8.0.3 の `**Check**` (prose 層) は `outcome` を問わず pass するが、8.0.3 の Pre-Check (機械強制) は pending marker 残存により `exit 1` で差し戻す。よって step 1-2 の再実行は必須であり、転記だけで済ませてはならない。** 差し戻しを強制する集合は exit-1 の caller 契約違反 7 種**に加えて本文検査 4 段** (`body_file_empty` / `body_marker_missing` / `body_sentinel_missing` / `count_body_mismatch`) である
- `patch_failed`: 既存コメントの PATCH が失敗 (非ブロッキング、`exit 0`)。`rc=` / signal 終了時は `signal=` を併記
- `create_failed`: 新規コメント作成が失敗 (非ブロッキング、`exit 0`)。`rc=` / `signal=` は同上
- `unknown_option`: 未知のフラグが渡された (`exit 1`)。caller 契約違反であり、引数解析の途中で落ちるため `pr=` を伴わない
- `signal_aborted`: INT / TERM / HUP で中断された (`rc=` / `signal=` を併記)。terminal sentinel の `outcome=aborted` だけでは「helper が完走しなかった」ことしか読めないため、中断された事実を本 reason で loud に残す。**「未投稿」とは断定しない** — signal が `gh` の POST 実行中に届いた場合コメントは既に受理されていることがあり、helper には投稿完了状態を読む手段が無い。次 cycle の lookup + PATCH が自己修復する

**ステップ 8.0.3 reasons** (機械強制 = pending marker 検査。emit 元は helper ではなく **SKILL.md ステップ 8.0.3 の bash block 自身**。gate の可否のみを決め `overall_assessment` は変えない。本表を 8.0.3 節ではなくここに置くのは、8.0.3 節の表が TC-5e の gate 別 per-row pin の対象であり、同節に 2 つ目の表を置くと「gate 表」の同定が曖昧になるため):

| reason | flag | Description |
|--------|------|-------------|
| `pending_marker_absent` | `NONBLOCKING_GATE=pass` | marker が不在 = 6.1.d の helper が完走し EXIT trap で削除した。機械強制を通過 |
| `pending_marker_present` | `NONBLOCKING_GATE_FAILED=1` | marker が残存 = 6.1.d が本 cycle で完走していない、**または** caller 契約違反 (本文検査 4 段) で記録を拒否した。**`exit 1`** で落とし ステップ 6.1.d へ戻す (どちらかは `NONBLOCKING_RECORD_FAILED` の reason で判別する)。marker はここでは削除しない (削除すると 6.1.d を実行せず再評価だけで通せる) |
| `pending_marker_placeholder_residue` | `NONBLOCKING_GATE=degraded` | `{pending_marker}` が literal substitute されず `{...}` 形状のまま到達。機械強制を skip し `**Check**` の prose 判定のみで続行 |
| `pending_marker_unavailable` | `NONBLOCKING_GATE=degraded` | ステップ 6.1.a step 0 が marker を作成できなかった (read-only な `${TMPDIR}` 等、同 step で WARNING 済)。同上 |

**Non-blocking contract**: ステップ 6.1.a の全 14 種の reason (`pr_number_placeholder_residue` / `date_command_failure` / `mkdir_failure` / `mktemp_failure` / `write_failure` / `timestamp_injection_mv_failure` / `json_invalid` / `schema_required_fields_missing` / `finding_id_format_or_uniqueness_violation` / `scope_enum_violation` / `critical_high_scope_nit_noted_invariant` / `mktemp_failure_mv_err` / `mv_failure` / `collision_resolution_exhausted`) are all logged as WARNING and MUST NOT cause ステップ 6 to fail. Only `tmpfile_write_failure` (which affects the PR comment post path, not the local file save) causes a hard error. Canonical 定義は [common-error-handling.md#non-blocking-contract-canonical-定義](../../references/common-error-handling.md#non-blocking-contract-canonical-定義) を参照。

**Retained flag mapping**:

- **ステップ 6.1.a** は `[CONTEXT] LOCAL_SAVE_FAILED=1` flag を emit する。reason 値は以下 14 種のいずれか: `pr_number_placeholder_residue` / `date_command_failure` / `mkdir_failure` / `mktemp_failure` / `write_failure` / `timestamp_injection_mv_failure` / `json_invalid` / `schema_required_fields_missing` / `finding_id_format_or_uniqueness_violation` / `scope_enum_violation` / `critical_high_scope_nit_noted_invariant` / `mktemp_failure_mv_err` / `mv_failure` / `collision_resolution_exhausted`。この flag は ステップ 6.1.c の skip notification で「ローカル保存失敗」メッセージを表示する条件として参照される。ステップ 6 全体の exit code には影響しない (非ブロッキング契約)。
- **ステップ 6.1.b** は `[CONTEXT] REVIEW_OUTPUT_FAILED=1` flag を emit する。reason 値は `tmpfile_write_failure` / `gh_comment_post_failure` / `json_saved_from_p61a_unset` / `p61b_post_comment_mode_invalid` のいずれか。この flag は PR コメント投稿経路の失敗を示し、hard error として ステップ 6 を fail させる (ステップ 6.1.a の非ブロッキング契約とは対照的)。なお `post_comment_mode=false` で 6.1.b に誤呼出された場合は gate が **silent skip (exit 0)** するため、caller branch selection ミスは retained flag emit せずに吸収される (データ破壊なし、gh pr comment も実行されない)。
- **ステップ 6.1.c** は case 2 (`post_comment_mode=false` ∧ `LOCAL_SAVE_FAILED=1` の組み合わせ) で `[CONTEXT] REVIEW_OUTPUT_FAILED=1` (reason 値 `p61c_persistence_unrecoverable`) を emit し、ステップ 6 全体を `exit 2` で fail させる (silent data loss 防止)。
- **ステップ 6.1.a** は `non_blocking_findings[]` の欠陥を 2 種の observability marker で報告する (`review-result-save.sh` が emit。**いずれも非ブロッキング** — 保存は続行し `JSON_SAVED=true` のまま。`LOCAL_SAVE_FAILED` reason ではないため 14 種の reason 表 / Eval-order enumeration には登録しない): キー欠落 / 非配列 → `[CONTEXT] NON_BLOCKING_FINDINGS_KEY_MISSING=1; pr={n}` / 和集合での id 重複・書式違反 → `[CONTEXT] NON_BLOCKING_FINDINGS_ID_UNION_VIOLATION=1; pr={n}`。hard fail するのは `findings[]` 側の id 欠陥のみ (`reason=finding_id_format_or_uniqueness_violation`)。
- **ステップ 6.1.d** は terminal sentinel `[CONTEXT] NONBLOCKING_RECORD_DONE=1; pr={n}; outcome=created|updated|skipped|failed|aborted; count={k}; iteration_id={id}; comment_id={id または空}; degraded=0|1` を **1 種だけ** emit する (`review-nonblocking-record.sh` の EXIT trap)。**6.1.d step 3 / ステップ 8.0.3 の gate が pass 条件として参照するのは本 sentinel のみ**であり、成功 / skip / 失敗の区別は `outcome=` フィールドが担う (別 marker を増やさない — consumer ゼロ marker を作らないため)。失敗時は加えて `[CONTEXT] NONBLOCKING_RECORD_FAILED=1; reason=...` (上記 6.1.d reasons 表の全 reason) を emit するが、これは reason 語彙の observability 用で gate の入力ではない。**`outcome=failed` / `aborted`、および `degraded=1`（`outcome` を問わない — `updated ∧ degraded=1` は `existing_id=""` を伴うため構造的に到達不能で、実質 `skipped` / `created` の両方をカバーする）を観測したときは、6.1.d step 3 / ステップ 8.0.3 のいずれで観測した場合も、helper の WARNING / 対応する reason を completion report に転記してから次へ進む** (転記しないと記録が落ちた / stale が残った事実がどこにも残らない。`created ∧ degraded=1` は既存記録コメントを検出できないまま新規作成した縮退で、古い記録が PR 上に stale で残りうる — `skipped ∧ degraded=1` と同じ結末のため同一の転記対象とする)。**加えて `[CONTEXT] NONBLOCKING_LEGACY_ORPHAN=1` / `NONBLOCKING_DUPLICATE_RECORD=1` を観測したときも、helper の WARNING (件数と手動削除の案内) を completion report に転記してから次へ進む** — どちらも人間の手作業を要求する指示を含むため、転記しないと PR 上に孤児 / 重複が残った事実がどこにも残らない (`outcome=updated ∧ degraded=0` で発火しうるため、既存 3 条件のいずれにも該当しない)。**この 2 marker 自体は純粋な observability marker であり、gate の入力ではない — result pattern の emit 可否にも `overall_assessment` にも一切影響しない** (AC-3。直前の `outcome=failed` の帰結とは独立)。
- **ステップ 6.1.d の観測 marker (2 種)**: lookup が候補を落とした事実を可視化する。`[CONTEXT] NONBLOCKING_LEGACY_ORPHAN=1; pr={n}; count={m}` (author ∧ marker 前方一致は満たすが最終非空行が sentinel でない件数。sentinel 導入前の記録コメント、または marker で始まる手書きコメントが update-in-place の対象外になったこと) / `[CONTEXT] NONBLOCKING_DUPLICATE_RECORD=1; pr={n}; count={m}` (sentinel を持つ自分の記録コメントが 2 件以上 = 過去の degraded 縮退が生んだ重複。`last` を採るため古い方は stale で残る)。**いずれも純粋な observability marker であり、gate の入力ではない — result pattern の emit 可否にも `overall_assessment` にも一切影響しない** (AC-3)。`*_FAILED` reason ではないため reason 表 / Eval-order enumeration には登録しない (`NON_BLOCKING_FINDINGS_KEY_MISSING` と同じ扱い)。ただし**どちらも人間の手作業 (古いコメントの手動削除) を要求する**ため、下記 6.1.d step 3 / ステップ 8.0.3 の転記条件に含める。
- **ステップ 6.1.a step 0 / ステップ 8.0.3** は 8.0.3 の機械強制 (pending marker) 用に 3 種の marker を emit する。`[CONTEXT] NONBLOCKING_PENDING_MARKER={path または空}` (6.1.a step 0、marker のパスを 8.0.3 へ渡す。作成失敗時は空) / `[CONTEXT] NONBLOCKING_GATE=pass|degraded; reason=...` (8.0.3、`reason` は `pending_marker_absent` / `pending_marker_placeholder_residue` / `pending_marker_unavailable`) / `[CONTEXT] NONBLOCKING_GATE_FAILED=1; reason=pending_marker_present; marker={path}` (8.0.3、**gate 失敗として `exit 1`**。6.1.d へ戻さずに ステップ 8.1 へ進むことを禁じる唯一の機械的層)。`NONBLOCKING_RECORD_*` とは別 namespace で、`overall_assessment` そのものは変えない — 変えるのは「result pattern を emit してよいか」の可否のみ。**marker が残る (= 8.0.3 が差し戻す) 経路は「原因」で決まる**: 引数 gate 群 (placeholder residue 5 種 / `content_file_missing`、trap 設置前の `exit 1`) と本文検査 4 段 (`body_file_empty` / `body_marker_missing` / `body_sentinel_missing` / `count_body_mismatch`、trap 設置後の `retain_pending_marker=1`) — いずれも caller (LLM) 契約違反で、本文 / `--count` を作り直せば 1 iteration で収束する。gh / network / rate-limit / IO 起因 (`patch_failed` / `create_failed` / lookup degraded / `body_check_unavailable`) と signal 中断 (`signal_aborted`) は差し戻しても同 cycle 内で収束しないため従来どおり無条件削除する。`body_check_unavailable` は本文検査 4 段と同じ位置で起きるが、**述語を評価できなかった**環境起因の失敗であり caller が本文を作り直しても解消しないため本群に属する。境界を exit code (trap の前後) で引くと、同種の契約違反が検出位置の違いだけで機械強制から外れる。rationale: [references/measured-gate-record.md#pending-marker](references/measured-gate-record.md#pending-marker)
- **ステップ 5.3.0.M** は実測必須ゲートの anchor 検出 regex 層での降格時に `[CONTEXT] MEASURED_DEMOTED_ON_ANCHOR=1; count={n}; cause=anchor_unparseable` を emit する (**`scripts/review-measured-gate.sh` が emit**、Issue #2072 で LLM 直接 emit から委譲)。対象は **`Verification:` アンカー文字列は存在するのに full regex が no-match だったもの全て** (raw `|` を含む repro / `=>` 右辺空 / 種別ラベル誤記 / 形式崩れ) であり、アンカー文字列そのものが無い正常系 (非実測指摘) では出さない。**存在判定は正規化 marker (`(?i)verification[*_`[:space:]]*[:：]`) で行い、種別キーワードも colon 直後の空白も条件に含めず、装飾文字と全角コロンを吸収する。発火条件を「`=>` 右辺空」だけに絞ってもならない** — 定義の SoT は [assessment-rules.md §5.3.0.M](../fix/references/assessment-rules.md) の WARNING emit 節で、helper の実装はその写しとして同一語彙を保つ。observability marker であり `*_FAILED` reason ではないため、上記 ステップ 6 failure reasons 表 / 後述 Eval-order enumeration には登録しない (それらは reason 専用の列挙)。
- **ステップ 5.3.0.M** は同 helper から `[CONTEXT] MEASURED_GATE=applied; blocking={n}; demoted={d}; non_blocking_total={t}; assessment={a}` を必ず emit する (ゲート適用の成功と `total_findings` / `non_blocking_count` / `overall_assessment` の値を 5.3.1 以降へ渡す唯一の経路)。失敗時は `[CONTEXT] MEASURED_GATE_FAILED=1; reason=...` を emit して非ゼロ終了する — reason 語彙 (`input_missing` / `input_unreadable` / `json_invalid` / `findings_not_array` / `non_blocking_not_array` / `jq_transform_failed` / `mktemp_failure` / `write_failure` / `mv_failure`) の SoT は helper docstring。**本 reason は ステップ 6 の非ブロッキング reason 群とは別 namespace で、唯一 `[review:error]` 停止を伴う** (LLM 分類への fallback は禁止)。

**Eval-order enumeration** (Pattern-2 documented-union input): ステップ 6.1.a emit sequence = (`pr_number_placeholder_residue` / `date_command_failure` / `mkdir_failure` / `mktemp_failure` / `write_failure` / `timestamp_injection_mv_failure` / `json_invalid` / `schema_required_fields_missing` / `finding_id_format_or_uniqueness_violation` / `scope_enum_violation` / `critical_high_scope_nit_noted_invariant` / `mktemp_failure_mv_err` / `collision_resolution_exhausted` / `mv_failure`) — 14 件、bash block 内の実 emit 順 (`scope_enum_violation` / `critical_high_scope_nit_noted_invariant` は finding_id_format_or_uniqueness_violation の直後に elif chain で配置); ステップ 6.1.b emit = (`p61b_post_comment_mode_invalid` / `p61b_pr_number_invalid` / `tmpfile_write_failure` / `iso_timestamp_from_p61a_unset` / `raw_json_timestamp_injection_failed` / `gh_comment_post_failure` / `json_saved_from_p61a_unset`) — `p61b_post_comment_mode_invalid` は post_comment_mode gate が bash block 冒頭で最初に評価されるため先頭に配置; ステップ 6.1.c emit = (`p61c_post_comment_mode_invalid` / `p61c_pr_number_invalid` / `p61c_file_timestamp_unset` / `p61c_file_timestamp_unknown_without_failure` / `p61c_local_save_failed_invalid` / `p61c_persistence_unrecoverable`) — `p61c_post_comment_mode_invalid` を先頭に配置 (6.1.b と対称); ステップ 6.1.d emit = (`unknown_option` / `pr_number_placeholder_residue` / `owner_repo_placeholder_residue` / `non_blocking_count_placeholder_residue` / `iteration_id_placeholder_residue` / `content_file_placeholder_residue` / `content_file_missing` / `body_file_empty` / `body_marker_missing` / `body_check_unavailable` / `body_sentinel_missing` / `count_body_mismatch` / `patch_failed` / `create_failed`) — 14 件、helper 内の実 emit 順 (引数解析ループ内の `unknown_option` → placeholder residue 5 種 + content_file 存在検査を引数 parse 直後にまとめて評価 → lookup → 本文の非空検査 → 1 行目 marker 検査 → 機械専用 sentinel 検査 (述語の評価自体が失敗した場合は `body_check_unavailable`) → 件数整合検査 → PATCH / create の分岐)。`patch_failed` と `create_failed` は排他分岐のため同一 run で両方は出ない。`signal_aborted` は signal trap 由来で線形の emit 順に載らないため本 enumeration から除外する (ステップ 6.1.a が observability marker を除外する慣行と同じ); ステップ 8.0.3 (機械強制) emit = (`pending_marker_placeholder_residue` / `pending_marker_unavailable` / `pending_marker_present` / `pending_marker_absent`) — 4 件、bash の `case` 分岐順 (placeholder 残留 → marker 未作成 → 残存 (`exit 1`) → 不在 (pass))。前 2 者は `NONBLOCKING_GATE=degraded`、`pending_marker_present` は `NONBLOCKING_GATE_FAILED=1`、`pending_marker_absent` は `NONBLOCKING_GATE=pass` に載る。

#### 6.1.a Local JSON File Save (Always Executed) <!-- AC-1 / D-01 / D-02 / D-04 -->

> **Acceptance Criteria anchor**: AC-1 (`pr_review.post_comment` 未設定時にデフォルトで PR コメント投稿せず、`.rite/review-results/{pr}-{ts}.json` のみ作成)。D-01 (ハイブリッド方式: 会話 > ローカルファイル > PR コメント)。D-02 (同一 PR の履歴を timestamp 付きで保持、best-effort、同秒衝突は `~$RANDOM` suffix で回避 — separator `~` は `.` より ASCII 大で sort -r 時に新しい collision-resolved 版が先頭に来る)。D-04 (非ブロッキング契約: ローカル保存失敗は WARNING のみで続行、`common-error-handling.md` の Non-blocking Contract 準拠 — ただし `post_comment=false` ∧ `LOCAL_SAVE_FAILED=1` 組み合わせは ステップ 6.1.c でケース 2 の ⚠️ WARNING に昇格する)。


Save review results as a timestamped JSON file per [review-result-schema.md](../../references/review-result-schema.md). This is executed **regardless** of `{post_comment_mode}` so that `/rite:fix` can read results via the local-file path.

**Claude substitution requirements**:
- **JSON 本文**: **本 phase では JSON を生成しない**。保存対象は ステップ 5.3.0.M step 1 で Write 済み・step 2 で `review-measured-gate.sh` が書き換えた `{review_tmp_dir}/rite-review-result-{pr_number}.json` そのものである (Issue #2072。生成箇所を本 phase にも残すと、ゲート適用後の分類が失われた JSON が保存され、`overall_assessment` が 5.3.1 の判定と食い違う)。ファイル欠落 / 不正 JSON は `review-result-save.sh` 内の jq timestamp 注入が `write_failure` として非ブロッキングに fail-fast 検出する (後続の `jq empty` post-condition `json_invalid` は注入成功後に走る defense-in-depth backstop で、syntactic invalidity では実挙動上ここに到達しない)。以下の「Required JSON fields」節は **ステップ 5.3.0.M step 1 の生成規約の SoT** であり、本 phase の再生成指示ではない。
 - **`non_blocking_findings` の扱い (実測必須ゲート)**: ステップ 5.3.0.M で `non_blocking_findings` に移動した非実測 finding は、`findings[]` 配列には **含めず**、トップレベルの独立配列 **`non_blocking_findings[]`** として出力する (要素の形は `findings[]` と同一 — [review-result-schema.md §non_blocking_findings](../../references/review-result-schema.md#non_blocking_findings-配列)。`findings[]` の契約を変えないため cross-field invariant の同期は不要、read 側は未知キーを無視するため後方互換)。`findings[]` は 5.3.0.M 通過後の `全指摘事項` (blocking 指摘 + `scope == "nit-noted"` 指摘) と一致する — nit-noted は本ゲートの対象外のため非実測でも `findings[]` に残る。`non_blocking_findings[]` へ分離されるのは `scope ∈ {current-pr, follow-up}` の非実測指摘のみ。
 - **`id` は 2 配列の和集合で一意**: 5.3.0.M で降格した finding の `id` (`F-NN`) は**振り直さず元の値を維持する**。配列ごとに独立採番すると永続 JSON 内に同一 `id` が 2 つ残り、本配列の存在意義である「マージ後に人間が拾い直せる状態」で finding を一意に指せなくなる。`review-result-save.sh` の id 検証は 2 配列の和集合に対して書式 + 一意性を評価し、違反を write 時に**非ブロッキング marker** `[CONTEXT] NON_BLOCKING_FINDINGS_ID_UNION_VIOLATION=1` で報告する (保存は続行する)。hard fail (`reason=finding_id_format_or_uniqueness_violation`) するのは `findings[]` 側の id 欠陥のみ。
 - **なぜ独立配列に出すのか**: `findings[]` にだけ載せない設計にすると、既定 `post_comment: false` では PR コメントも投稿されないため、**永続成果物 (`.rite/review-results/*.json`) に降格の痕跡がゼロ**になり「`overall_assessment: mergeable` + `findings[]: []`」= 指摘ゼロのレビューと区別不能な記録が残る。これは `assessment-rules.md` §5.3.0.M の「破棄経路は存在しない」および Issue #2024 D-01「マージ後に人間が拾い直せる状態を保つ」を既定構成で偽にする。独立配列にすることで `findings[]` の blocking 集合としての意味を保ちながら記録を永続化する。
 - **帰結**: (a) `/rite:fix` の JSON 経路 (Priority 0/2/3) は `findings[]` のみを読むため、fix 側の `measured_map` は JSON 経路では空のままで `non_blocking_count` は 0 になる (Markdown / 会話経路の N とは一致しない — fix/SKILL.md ステップ 1.2.1 step 6 の注記参照)。(b) 非実測 finding と同一 file:line に GitHub thread がある場合、その thread は severity_map 未登録となり `/rite:fix` ステップ 1.3 step 5 で External review (blocking) に分類される — 安全側 (取りこぼしではなく過剰 blocking)。(c) **write 側が `verification` を出力するようになった後**は本契約を見直し、非実測 finding を `measured: false` 付きで `findings[]` に統合してよい (その場合は cross-field invariant #2 の 3 経路 + SoT 同期が前提)。
 - **Accepted Fingerprint Suppression 契約**: ステップ 5.1.2.A で識別された `suppressed_findings` (前 cycle で `accept (認知のみ)` 選択された finding が再出現) は、本 JSON 本文の `findings[]` 配列から **除外** する。Markdown 側 (ステップ 5.4 統合レポート / ステップ 6.1.b PR コメント本文) には audit log として残すが、JSON output (本 phase / ステップ 6.1.b Raw JSON section) には含めない。これにより `/rite:fix` が JSON を読み込んだ際、accepted finding は fix loop に entered せず、decision-replay 系の同一 finding 再出現が断たれる。除外は finding 単位 (`F-NN`) で行い、各除外について ステップ 5.1.2.A Step 3 で `[CONTEXT] FINDING_SUPPRESSED_BY_ACCEPT=1; finding_id=...; original_severity=...; fingerprint=...` を emit 済 (本 phase で重複 emit は不要)。
- `{pr_number}`: ステップ 1.0 で正規化済み。`review-result-save.sh` の `--pr {pr_number}` 引数および Write 先パス (`{review_tmp_dir}/rite-review-result-{pr_number}.json`) に literal substitute する。helper が数値 fail-fast gate (`pr_number_placeholder_residue`) を持つ。
- Required JSON fields: `schema_version: "1.0.0"`, `pr_number`, `timestamp` (literal sentinel `"__RITE_TS_PLACEHOLDER_7f3a9b2c__"` を書き、helper が ISO 8601 JST 値に注入), `commit_sha`, `overall_assessment` (`mergeable` / `fix-needed`), `findings[]`. 加えて **`non_blocking_findings[]`** (5.3.0.M で降格した非実測 finding。**0 件のときも空配列 `[]` を出力する** — キー自体を省略すると「降格ゼロ」と「本ゲート未適用の旧形式」が区別できなくなる。`review-result-save.sh` はキー欠落・非配列を `NON_BLOCKING_FINDINGS_KEY_MISSING`、和集合 id 欠陥を `NON_BLOCKING_FINDINGS_ID_UNION_VIOLATION` で報告するが**いずれも保存を続行する**ため、本配列側の欠陥で blocking findings が失われることはない). Each finding の必須フィールドは以下の通り — 完全なスキーマは [review-result-schema.md](../../references/review-result-schema.md#json-schema) を真実の源として参照すること:
 - `id`: **`F-NN` 形式、最小 2 桁ゼロパディング可変長連番** (正規表現 `^F-[0-9]{2,}$`)。99 件以下は `F-01`〜`F-99`、100 件以上は `F-100` 等に成長する。
 - `reviewer`: レビュアーエージェント名 (例: `code-quality-reviewer`, `security-reviewer`, `tech-writer-reviewer`)。実在する agent 名は `plugins/rite/agents/*-reviewer.md` の basename (拡張子を除く) と一致させる。
 - `category`: 指摘カテゴリ (例: `code_quality`, `error_handling`, `security`, `performance`)。アンダースコア区切りで統一する (schema.md の `category` フィールド定義を SoT として参照)
 - `severity`: `CRITICAL` / `HIGH` / `MEDIUM` / `LOW-MEDIUM` / `LOW` のいずれか (LOW-MEDIUM は `severity-levels.md` で正式定義された first-class severity で、`COMMENT_QUALITY` 軸の独自ジャーゴン濫用 等の bounded blast radius 違反に使う)。reviewer が `Critical`/`Important`/`Minor`/`Low-Medium`/`Nit` 等の別表記で返した場合は、write 前に本 enum へ正規化する (別名マッピングは review-result-schema.md の `severity` フィールド定義を参照)。正規化漏れの JSON は read 側 (`fix.md` ステップ 1.2.0) で MEDIUM fallback と WARNING emit が発生する。
 - `file`: 対象ファイルの相対パス
 - `line`: 正の整数 (>= 1) または `null` (行非依存指摘の sentinel)。schema.md の `line` フィールド定義が SoT。新規出力では `null` を使用し、`0` は生成しないこと (`0` は legacy sentinel として read 側で `null` と同等に扱われるが、write 側で新たに生成すべきではない)。
 - `description`: 指摘内容
 - `suggestion`: 推奨対応
 - `status`: 現行実装では常に `open` を出力する。`fixed` / `replied` / `deferred` は enum として予約されているが、`/rite:fix` 側の書き戻しは未実装 (schema は slot を持つのみ、review-result-schema.md の `status` フィールド定義を参照)。

**`iso_timestamp` Claude substitution handshake**: Claude は JSON 本文の `timestamp` フィールドに literal sentinel (`"__RITE_TS_PLACEHOLDER_7f3a9b2c__"`) を書き込むだけでよい。`review-result-save.sh` が単一 `date` 由来の `$iso_timestamp` (TZ=Asia/Tokyo の ISO 8601) を内部で算出し、`jq '.timestamp = $ts'` で sentinel を上書きする。これにより JSON body / ファイル名 / `[CONTEXT]` emit の 3 値が helper 内で完全同期する (秒跨ぎズレなし)。Claude が独立に timestamp を算出する必要はない。sentinel を含む body が invalid JSON の場合、helper の jq 注入が失敗し非ブロッキング失敗 (`write_failure`) する。

**ステップ 6.1.a 実行手順**:

0. **Write 先実パス解決 + 本 cycle の識別子生成**: 以下の bash を実行し、`{review_tmp_dir}` に使う実パスと `{review_cycle_id}`（本 review cycle の識別子）を emit する。`REVIEW_TMP_DIR` は ステップ 5.3.0.M step 1 が emit したものと**同一の `${TMPDIR:-/tmp}`** で、レビュー結果 JSON は既にそのパスに存在する（本ブロックは同じ値を再確認し、6.1.b / 6.1.d 用の識別子を追加で作る）。Write tool は `${TMPDIR:-/tmp}` を展開できないため、以降の Write 先 / `--content-file` 引数には `REVIEW_TMP_DIR` marker の値をリテラル置換する（sandbox 環境では `/tmp` 直下が読み込み専用のため `/tmp` ハードコード不可 — Issue #1904）:

   ```bash
   review_cycle_id="{pr_number}-$(date +%s)"
   echo "[CONTEXT] REVIEW_TMP_DIR=${TMPDIR:-/tmp}" >&2
   echo "[CONTEXT] REVIEW_CYCLE_ID=$review_cycle_id" >&2
   # ステップ 8.0.3 の機械強制用 pending marker。6.1.d の helper が完走 (EXIT trap 到達) すると
   # 削除する。8.0.3 到達時点で残存していれば「6.1.d が本 cycle で走っていない」ことの機械的証拠。
   pending_marker="${TMPDIR:-/tmp}/rite-nbr-pending-$review_cycle_id"
   # `set -C` (noclobber) で O_CREAT|O_EXCL 相当にする。marker のパスは予測可能で、かつ**この
   # ファイルの存在/不在そのものが 8.0.3 の判定値**であるため、素の `: >` だと (a) 事前に張られた
   # symlink を追随して任意ファイルを 0 バイトへ truncate でき、(b) 他者が作った既存ファイルを
   # 掴んでしまう。拒否された場合は rc 非 0 で下の else に落ち、既定義の
   # `pending_marker_unavailable` (degraded) へ縮退するため新規分岐は不要。
   if ( set -C; : > "$pending_marker" ) 2>/dev/null; then
     echo "[CONTEXT] NONBLOCKING_PENDING_MARKER=$pending_marker" >&2
   else
     echo "WARNING: pending marker を作成できませんでした ($pending_marker)。ステップ 8.0.3 の機械強制は skip され prose 判定のみになります" >&2
     echo "[CONTEXT] NONBLOCKING_PENDING_MARKER=" >&2
   fi
   ```

   `REVIEW_CYCLE_ID` は ステップ 6.1.d の記録経路と、その実行を保証する gate（6.1.d step 3 / ステップ 8.0.3）が「本 cycle で記録経路が走ったか」を stale marker と区別して判定するために使う。**値の生成（本ブロック）と記録動作（6.1.d）を別ブロックに分ける**ことで、gate 側に本 cycle の比較対象が独立に残る（rationale: [references/measured-gate-record.md#iteration-id](references/measured-gate-record.md#iteration-id)）。

   `NONBLOCKING_PENDING_MARKER` は ステップ 8.0.3 が prose 判定に加えて持つ**機械強制**の入力。sentinel の grep は LLM が会話を読む前提であり、読まずに result pattern へ進む経路を構造的には塞げない。marker は helper 側でしか消えないファイルなので、gate の bash が `[ -e ]` で見るだけで「6.1.d が完走したか」を LLM の認識に依存せず判定できる（rationale: [references/measured-gate-record.md#pending-marker](references/measured-gate-record.md#pending-marker)）。

1. **JSON body は再生成しない**: 保存対象の `{review_tmp_dir}/rite-review-result-{pr_number}.json` は ステップ 5.3.0.M step 1 で Write 済み・step 2 でゲート適用済である。本 phase は **その内容に一切手を加えない** (Issue #2072: JSON authoring site の一本化)。`suppressed_findings` 除外契約と `timestamp` sentinel の書き込みも 5.3.0.M step 1 で適用済で、`timestamp` の実値は下記 helper が `$iso_timestamp` で注入する。
2. **helper 実行**: 以下の bash を実行する。helper が `iso_timestamp` 算出・sentinel 注入・schema validation・同秒衝突回避・atomic mv・`[CONTEXT]` emit を担う。JSON body / ファイル名 / `[CONTEXT]` emit の timestamp は helper 内の単一 `date` 由来で完全同期する。

```bash
# ステップ 6.1.a: ローカルファイル保存 (JSON、非ブロッキング) — hooks/review-result-save.sh へ委譲済。
# helper 契約: D-04 非ブロッキング (全失敗経路で exit 0) / 14 種 LOCAL_SAVE_FAILED reason 語彙 (上記
# bullet と一致) / 同秒衝突回避 / trap での FILE_TIMESTAMP= ・ISO_TIMESTAMP= ・JSON_SAVED= emit
# (normal/abnormal 両経路、ステップ 6.1.c が前提)。SoT は helper docstring。
bash {plugin_root}/hooks/review-result-save.sh \
  --pr {pr_number} \
  --content-file {review_tmp_dir}/rite-review-result-{pr_number}.json
```

**Non-blocking contract** (ステップ 6.1.a Non-blocking Contract / D-04 compliance): when any step in this sub-phase fails (mkdir, mktemp, write, jq validation, or mv), the failure is recorded via `[CONTEXT] LOCAL_SAVE_FAILED=1; reason=...` emission but ステップ 6 is NOT failed — it logs a WARNING and proceeds. The review results remain available via conversation context for immediate `/rite:fix` invocation.

**Placeholder data flow**:
- `file_timestamp` / `iso_timestamp` / `json_saved` は **EXIT trap handler 内**で `[CONTEXT]` として stderr に emit される (normal/abnormal 両方の経路で確実に emit される)。
- ステップ 6.1.c の machine-enforced bash block は `file_timestamp` と `local_save_failed` のみを substitute に使う (ユーザー向けテンプレートに embed する値)。`iso_timestamp` は **observability ログ専用** (後追い debug / drift 検出用) であり、user-facing メッセージには含まれない (責務分離)。
- `iso_timestamp` は ステップ 6.1.a 内で算出された値であり、JSON body 生成にも使用される (Approach C bash-internal jq injection)。bash 内完全同期により Claude が独立計算した場合の秒跨ぎズレを排除している。

#### 6.1.b PR Comment Post (Conditional on `{post_comment_mode}`) <!-- AC-2: opt-in PR comment posting -->

Execute this sub-phase **only when** `{post_comment_mode}=true` from ステップ 1.0. When `{post_comment_mode}=false`, skip this entire sub-phase and proceed directly to 6.1.c.

`review-comment-post.sh` 冒頭の `--post-comment-mode` case guard は machine-enforced gate として caller (LLM) の branch selection ミスを helper レベルで遮断する。`post_comment_mode=false` の状態で誤って 6.1.b の helper を呼んでも gate が `exit 0` で silent skip し `gh pr comment` は絶対に実行されない (6.1.c の `post_comment_mode=true` gate と対称)。

> **Acceptance Criteria anchor**: AC-2 (`--post-comment` 指定時 or `rite-config.yml pr_review.post_comment: true` 時に PR コメントに投稿、code fence JSON 形式で JSON 本文も埋め込む)。D-03 (PR コメント形式は code fence JSON を採用 — /rite:fix が正規表現でパースしやすく人間も閲覧可能)。

**ステップ 6.1.b 実行手順**:

1. **コメント本文生成 + Write**: Claude は以下の構造の PR コメント本文を生成し、**Write tool で `{review_tmp_dir}/rite-review-comment-{pr_number}.md` に保存**する (`{review_tmp_dir}` はステップ 6.1.a step-0 の `[CONTEXT] REVIEW_TMP_DIR=` marker 値をリテラル置換する。旧 `RITE_COMMENT_EOF_7f3a9b2c` heredoc 埋め込みを廃止し、巨大 inline bash + nested code fence による malform 無言停止を回避):
   - `## 📜 rite レビュー結果` + ステップ 5.4 で生成した integrated report (Markdown)。改行・バッククォート・`$` を含んでよい。`📎 reviewed_commit: {current_commit_sha}` を末尾に必ず含める (次 cycle verification mode 用)。
   - (`metrics.enabled` のとき) ステップ 6.3 で算出した metrics を integrated report の末尾 (下記 `### 📄 Raw JSON` 見出しの直前) に含める。形式は `### メトリクス` 見出し + `CRITICAL: {n} / HIGH: {n} / MEDIUM: {n} / LOW: {n}` の 1 行。これにより `post_comment_mode=true` 経路では metrics が review 結果と同一コメントに集約される (別 API 呼び出し不要、ステップ 6.3 Step 2 opt-in 行と対応)。`metrics.enabled: false` のときは省略する。
   - `### 📄 Raw JSON` 見出し + ` ```json ` code fence + JSON 本文。**本文は `{review_tmp_dir}/rite-review-result-{pr_number}.json` を Read tool で読み、その内容をそのまま fence 内へ転記する** — 会話コンテキストから再生成してはならない (Issue #2072。再生成すると ステップ 5.3.0.M のゲート適用結果が反映されず、ローカル JSON が `mergeable` なのに PR コメント側は `fix-needed` という乖離が出る。`/rite:fix` Priority 3 は本 fence を読むため、乖離は次 cycle の分類を狂わせる)。`timestamp` は sentinel のまま転記する (helper が `--iso-timestamp` 値に置換する)。`suppressed_findings` 除外と `non_blocking_findings[]` は 5.3.0.M step 1 / step 2 で反映済のため、本 phase での追加操作は不要 (Markdown 表側には audit log として残す)。
2. **helper 実行**: ステップ 1.0 の `[CONTEXT] POST_COMMENT_MODE=`、ステップ 6.1.a の `[CONTEXT] JSON_SAVED=` / `ISO_TIMESTAMP=` を会話コンテキストから読み取り、以下の引数に literal substitute して実行する。helper が post_comment_mode gate / 各 sentinel gate / Raw JSON section 限定の timestamp 注入 + 2 post-condition / gh pr comment / signal 検出を担う。

```bash
# ステップ 6.1.b: PR コメント投稿 — hooks/review-comment-post.sh へ委譲済。
# helper 契約: post_comment_mode machine-enforced gate (true→続行 / false→silent skip exit 0 /
# その他→ERROR + [review:error] + exit 1) / 失敗はブロッキング (REVIEW_OUTPUT_FAILED emit + exit 1、
# reason 語彙は上記 6.1.b bullet と一致) / Raw JSON section 限定の sentinel 置換 + 2 post-condition。
# SoT は helper docstring。
bash {plugin_root}/hooks/review-comment-post.sh \
  --pr {pr_number} \
  --post-comment-mode {post_comment_mode} \
  --json-saved {json_saved_from_p61a} \
  --iso-timestamp "{iso_timestamp_from_p61a}" \
  --content-file {review_tmp_dir}/rite-review-comment-{pr_number}.md
```

**Note**: コメント本文を Write tool で tmpfile に書き出し helper に `--content-file` で渡すことで、巨大 heredoc の escaping / shell expansion / nested code fence (旧 4-backtick 包み) に起因する malform を撤廃した。helper は `gh pr comment --body-file` で投稿する。

**Note**: コメント本文の Markdown 部分は ステップ 5.4 で生成した integrated report (template は `review_mode` に依存) を使う。末尾の `📎 reviewed_commit: {current_commit_sha}` は次 cycle の verification mode で使われるため必ず含めること。

**Note on Raw JSON section**: The `### 📄 Raw JSON` section embeds the same JSON as saved to the local file (ステップ 6.1.a). This enables `/rite:fix` to extract the JSON via a parse over the `` ```json `` fence using **section-scoped awk line-state parsing** in `fix.md` ステップ 1.2.0 Priority 3 (the parser uses the `### 📄 Raw JSON` heading as a scope marker to avoid capturing sample JSON fences from findings' suggestion columns earlier in the comment). The Markdown table format above the Raw JSON section is preserved for human readability and backward compatibility with older fix-loop parsing logic.

**6.1.d への hand-off**: 本サブステップ完了後は 6.1.c を **skip して** ステップ 6.1.d を評価する (6.1.c は `post_comment_mode=false` 専用)。6.1.d は `{post_comment_mode}` に依存しない第 3 の独立出力経路であり、`post_comment_mode=true` 経路でも必ず評価する。

#### 6.1.c Skip Notification (when `{post_comment_mode}=false`)

When `{post_comment_mode}=false`, inform the user that PR comment posting was skipped (for observability — this is not an error).

下記 bash block (`hooks/review-skip-notification.sh` 呼び出し) は machine-enforced gate として `[CONTEXT] LOCAL_SAVE_FAILED=...` flag を helper 側で読み取りケース分岐する (Claude が自然言語で読み取る設計は flag 見落としで silent fallthrough する経路があり silent data loss 防止が骨抜きになるため helper 側に gate を昇格)。Claude は下記 block を実行するだけで適切なメッセージが stderr に emit される。

**Machine-enforced case selection**:

```bash
# ステップ 6.1.c: Skip Notification (post_comment_mode=false 経路専用) — hooks/review-skip-notification.sh
# へ委譲済 (契約は helper header と下記 Prose spec 参照)。
# Claude は [CONTEXT] marker から 4 値を literal substitute する (local_save_failed は空文字を渡すため
# 必ずクォートすること): post_comment_mode=ステップ 1.0 の POST_COMMENT_MODE / pr_number /
# file_timestamp=ステップ 6.1.a の FILE_TIMESTAMP / local_save_failed=ステップ 6.1.a の LOCAL_SAVE_FAILED。
bash {plugin_root}/hooks/review-skip-notification.sh \
  --post-comment-mode {post_comment_mode} \
  --pr {pr_number} \
  --file-timestamp "{file_timestamp_from_p61a}" \
  --local-save-failed "{local_save_failed_from_p61a}"
```

**Prose spec (参考)**:

- **ケース 1** (`LOCAL_SAVE_FAILED` 未 emit、通常経路): `ℹ️ PR コメント記録はスキップされました` + ローカルファイル path を表示、`exit 0`
- **ケース 2** (`LOCAL_SAVE_FAILED=1` ∧ `post_comment_mode=false`、findings が会話コンテキストにのみ存在する異常経路): `⚠️ ERROR: レビュー結果が永続化されませんでした` + 復旧方法 4 種を表示、`[CONTEXT] REVIEW_OUTPUT_FAILED=1` (reason 値 `p61c_persistence_unrecoverable`) を emit、**`exit 2` で ステップ 6 を fail させる** (silent data loss 防止のため hard fail)

**`post_comment_mode=false` と `LOCAL_SAVE_FAILED=1` が同時に成立する場合**: `review-skip-notification.sh` の machine-enforced gate により必ずケース 2 (⚠️ ERROR) が選択され、ステップ 6 は `exit 2` で終了する。Claude の自然言語判断には依存しない (silent data loss 防止)。WARNING のみの exit 0 経路はユーザー可視性と CI 検出性を両立できないため hard fail に統一する。

**6.1.d への hand-off**: 本サブステップ (ケース 1 正常終了) の完了後、`{post_comment_mode}` の値に関わらず**必ず ステップ 6.1.d を評価する** (6.1.d は本フェーズの第 3 の独立出力経路であり、6.1.c の skip 通知で ステップ 6.1 を完了扱いにしてはならない)。ケース 2 (`exit 2` hard fail) はステップ 6 全体が fail するため 6.1.d に進まない (永続化失敗時は非実測記録より復旧が優先)。

#### 6.1.d 非実測指摘の PR コメント記録 (always evaluated、非ブロッキング)

ステップ 5.3.0.M で `non_blocking_findings` に降格した非実測指摘を、PR 上の記録コメントに **update-in-place** で記録する (helper が自分の過去投稿を特定できない場合 — gh/jq の lookup 失敗による degraded、または別 identity での過去投稿 — は新規作成へ縮退するため、稀に 2 件以上並ぶ。後者は `degraded=0` のまま WARNING も出ない観測不能な縮退であることに注意 — 詳細: [measured-gate-record.md#startswith](references/measured-gate-record.md#startswith))。Issue #2024 D-01「非実測指摘は破棄せず PR コメント記録」の担保であり、`{post_comment_mode}` には **依存しない** (`pr_review.post_comment: false` の opt-out 対象外 — 設定の意味論は `templates/config/rite-config.yml` の post_comment 解説・docs/SPEC.md・docs/CONFIGURATION.md にも明記済み)。

**Condition**: 常に評価する (skip 条件を持たない)。「投稿しない」判定は helper 内部が行う — 本文検査 4 段 (非空 / 1 行目 marker / 最終非空行が機械専用 sentinel / count 整合) を通過した上で、非実測指摘 0 件 ∧ 既存の記録コメントなし のときだけ投稿せず `outcome=skipped` を返す (AC-4 非退行)。本文検査のいずれかに失敗した場合は 0 件 skip ではなく `outcome=failed` になる (count_body_mismatch 等、下記 reasons 表参照)。件数が 0 でも既存コメントがあれば収束 cycle のクリアとして update-in-place する (AC-2)。**ただし lookup が degraded した cycle では既存コメントを検出できないため、実在しても 0 件 skip に落ちる** (`outcome=skipped; degraded=1`) — 前 cycle の「N 件」記録が stale で残りうる。helper がその旨を WARNING で明示するので、転記して operator に目視確認を促す (下記 step 3 / ステップ 8.0.3 の転記対象)。

> **設計の核**: lookup / skip 判定 / 投稿を `hooks/review-nonblocking-record.sh` の**単一 invocation** に閉じる。「lookup だけ実行して記録を skip した」中間状態が構造的に存在しないため、helper の terminal sentinel の存在が「記録経路が終端まで走った」ことと同値になる。rationale: [references/measured-gate-record.md#single-invocation](references/measured-gate-record.md#single-invocation)

**実行手順**:

1. **コメント本文生成 + Write**: Claude はコメント本文を生成し、**Write tool で `{review_tmp_dir}/rite-nonblocking-{pr_number}-{review_cycle_id}.md` に保存**する (`{review_tmp_dir}` / `{review_cycle_id}` は ステップ 6.1.a step 0 の `[CONTEXT] REVIEW_TMP_DIR=` / `REVIEW_CYCLE_ID=` marker 値をリテラル置換。**パスに cycle 識別子を含めるのは必須** — 含めないと `${TMPDIR}` がセッション内で不変なため前 cycle の本文が同一パスに残り、step 1 を飛ばして step 2 だけ実行したときに前 cycle の内容で canonical コメントを上書きしてしまう。cycle 識別子を含めれば同じ状況が `content_file_missing` の loud fail として現れる)。本文は件数で 2 variant — **どちらも 1 行目を marker 見出し `## 📜 rite 非実測指摘の記録` にし、末尾に `📎 reviewed_commit: {current_commit_sha}` と機械専用 sentinel `<!-- rite:nbr:v1 -->` を置く** (`{current_commit_sha}` は ステップ 1.2.5 で取得した実 SHA にリテラル置換する — 未置換のまま投稿しても helper の本文検査は非空 / 1 行目 marker / sentinel / `📎 non_blocking_count:` の 4 段のみで `{current_commit_sha}` 自体は検査対象外のため素通りする。1 行目 marker と sentinel は helper の lookup 述語の needle であり、どちらを落としても update-in-place が恒久破綻する。sentinel は rendered view に現れない HTML コメントで、**同一 author が marker で始まる見出しの人間コメントを書いた場合に PATCH 先を奪われるのを防ぐ**ためにある。`📎 reviewed_commit:` 行は「この記録がどの commit 時点のレビューで作られたか」を PR 上で人間が追うためのもので、機械 consumer は持たない):

   > **本文は列 0 から書き出すこと (字下げ禁止)** — 下記 variant A / B のテンプレートは本手順が番号付きリスト項目の内側にあるため、表示上は全行が 3 スペース字下げされている。**Write する本文にはこの字下げを含めてはならない**。helper の本文検査 4 段のうち 3 段は先頭空白を許容しない (1 行目 marker は `case "$(head -n 1 ...)" in "$MARKER"*)`、機械専用 sentinel は最終非空行との厳密等値、件数行は `grep -E '^📎 non_blocking_count:...'`)。字下げたまま転記すると毎 cycle `body_marker_missing` で `outcome=failed` となる (本文検査は逐次評価で最初の失敗段で終了するため、後続の `body_sentinel_missing` / `count_body_mismatch` には到達しない)。この 4 reason (`body_file_empty` / `body_marker_missing` / `body_sentinel_missing` / `count_body_mismatch`) は caller 契約違反として **pending marker を残す**ため、ステップ 8.0.3 の機械強制が `exit 1` で 6.1.d へ差し戻し、本文を作り直せば 1 iteration で収束する (result pattern の emit は止まるが `overall_assessment` は変わらない)。

   **variant A (`non_blocking_count >= 1`)**:

   ```markdown
   ## 📜 rite 非実測指摘の記録 (non-blocking)

   以下の指摘は runtime 実測 (再現手順 / failing test) を伴わないため、実測必須ゲートにより
   **non-blocking** に分類されました (mergeable 判定を block しません)。マージ後に人間が
   拾い直せるようここに記録します。

   | レビュアー | 重要度 | スコープ | ファイル:行 | 内容 | 推奨対応 |
   |-----------|--------|----------|------------|------|---------|
   | {reviewer_type} | {severity} | {scope} | {file}:{line} | {description} | {suggestion} |

   📎 non_blocking_count: {non_blocking_count}
   📎 reviewed_commit: {current_commit_sha}

   <!-- rite:nbr:v1 -->
   ```

   `non_blocking_findings` の全件を表の行として列挙する (severity は明示 — 非実測 CRITICAL/HIGH も本表で人間に可視化される)。**情報源は ステップ 5.3.0.M でゲート適用済の `{review_tmp_dir}/rite-review-result-{pr_number}.json` の `non_blocking_findings[]`** であり、会話コンテキストの記憶ではない (Issue #2072)。`{non_blocking_count}` は同配列の要素数 = 5.3.0.M の `[CONTEXT] MEASURED_GATE=...; non_blocking_total=` の値。**`📎 non_blocking_count: {non_blocking_count}` 行は必須** — helper (ステップ 6.1.d step 2) が本文が申告する件数 (`📎 non_blocking_count:` 行の値) と caller が渡す `--count` の整合を検査する唯一の手掛かりであり、欠落すると `count_body_mismatch` として `outcome=failed` になる (下記参照)。**表の行数そのものは検査対象外** — 申告値と表の行数が食い違う (例: 5 件と申告しながら 3 行しか列挙しない) ケースは caller 側の責務であり、helper は検出しない。**本行は本文中に 1 本だけ置く** — helper は複数一致時に末尾の 1 本 (`tail -1`) を採るため、複数置くと意図しない行が照合対象になる。

   **variant B (`non_blocking_count == 0`)**:

   ```markdown
   ## 📜 rite 非実測指摘の記録 (non-blocking)

   本 cycle の非実測指摘: 0 件 (前 cycle の記録内容は本 cycle では再報告されていません)

   📎 non_blocking_count: 0
   📎 reviewed_commit: {current_commit_sha}

   <!-- rite:nbr:v1 -->
   ```

   0 件 ∧ 既存コメントなしの場合、本文は helper が投稿せず破棄する。ただし破棄の前に本文検査 4 段
   (非空 / 1 行目 marker / 機械専用 sentinel / count 整合) を通過する必要があり、不備があれば
   `outcome=skipped` ではなく `outcome=failed` になる (Write は「投稿されない」という意味での no-op
   であり、検査対象外という意味ではない)。

2. **記録 (単一 invocation、update-in-place 冪等 + 非ブロッキング契約)**: 以下の bash を **1 回だけ**実行する。`{non_blocking_count}` は `non_blocking_findings` の件数 (0 件でも `0` を明示置換)、`{owner_repo}` は Placeholder Legend の [Owner/Repo Resolution](../../references/gh-cli-patterns.md#ownerrepo-resolution-ssh-host-alias-safe) で解決した slash 形式の値、`{review_cycle_id}` は ステップ 6.1.a step 0 の `[CONTEXT] REVIEW_CYCLE_ID=` marker 値、`{review_tmp_dir}` は同 step 0 の `[CONTEXT] REVIEW_TMP_DIR=` marker 値をそれぞれリテラル置換する:

   ```bash
   # ステップ 6.1.d: 非実測指摘の記録 — hooks/review-nonblocking-record.sh へ委譲済。
   # helper 契約: 既存コメント lookup (--paginate --slurp + 「1 行目 marker への startswith ∧
   # author 一致 ∧ 最終非空行 == 機械専用 sentinel」の 3 条件) →
   # 本文検査 4 段 (非空 / 1 行目 marker / 最終非空行 sentinel / count 整合) → skip 判定 (0 件 ∧ 既存なし) →
   # PATCH / create を単一 invocation で実行し、EXIT trap で
   # terminal sentinel [CONTEXT] NONBLOCKING_RECORD_DONE=1; ...; outcome=... を emit する。
   # caller 契約違反 7 種 (placeholder residue 5 種 + content_file 不在 + unknown option) は exit 1 (loud)、
   # 本文不備 4 種 / gh / IO 失敗は exit 0 (非ブロッキング、AC-3)。ただし本文不備 4 種は
   # pending marker を残し ステップ 8.0.3 が result pattern の emit を差し戻す (overall_assessment は不変)。
   # SoT は helper docstring。
   bash {plugin_root}/hooks/review-nonblocking-record.sh \
     --pr {pr_number} \
     --owner-repo {owner_repo} \
     --count {non_blocking_count} \
     --iteration-id {review_cycle_id} \
     --content-file {review_tmp_dir}/rite-nonblocking-{pr_number}-{review_cycle_id}.md
   ```

   記録の成否は `overall_assessment` を変えない (AC-3)。ただし result pattern を emit してよいかの可否は別で、本文検査 4 段と caller 契約違反 7 種では pending marker が残るため ステップ 8.0.3 が差し戻す (冒頭の reason 表見出しと同一の carve-out)。検索失敗 (degraded) 時は `0 件 → skip` / `>0 件 → 新規作成に縮退` し、WARNING と `degraded=1` を terminal sentinel に残す (silent 縮退しない)。

3. **integrity check (6.1.d 内部)**: 本 step は 6.1.d サブステップ**内部**の integrity check であり、6.1.d を丸ごと skip した場合の保証にはならない (gate 自身も一緒に skip されるため)。全体 skip に対する最終防波堤は result-emit boundary の外側にある **ステップ 8.0.3** が担う (ステップ 7.7 ⇄ ステップ 8.0.2 と同型の二層構成)。**両者は同一の述語を異なる位置で評価する**。

   **Check**: 会話コンテキストに `[CONTEXT] NONBLOCKING_RECORD_DONE=1; ...; iteration_id={ID}` が存在し、その `iteration_id=` が **本 cycle の `REVIEW_CYCLE_ID`** と一致するか。**本 cycle の `REVIEW_CYCLE_ID` = 直近に emit された `[CONTEXT] REVIEW_CYCLE_ID=` の値** (review-fix loop の cycle 2+ では会話に複数存在するため、`{pr}-{epoch}` の epoch が最大のものを採る。ステップ 8.0.2 の iteration_id 最大採用と同型)。**同一 `iteration_id` の sentinel が複数ある場合は最後に emit されたものを採る** — 本文検査 4 段の差し戻しは同一 cycle 内での 6.1.d 再実行を強制するため、解決済みの 1 回目 (`outcome=failed`) と再実行後 (`outcome=created` 等) が並ぶ。古い方を拾うと解決済みの失敗を completion report へ誤転記する。

   | Condition | Action |
   |-----------|--------|
   | sentinel あり かつ `iteration_id` が本 cycle の `REVIEW_CYCLE_ID` と一致 (`outcome` は問わない) | Gate passes — ステップ 6.2 へ。`outcome=failed` / `aborted`、`degraded=1`（`outcome` を問わない）、または `NONBLOCKING_LEGACY_ORPHAN=1` / `NONBLOCKING_DUPLICATE_RECORD=1` を観測したときは (ステップ 8.0.3 と同一条件 — 片側だけに置かない) helper の WARNING / `NONBLOCKING_RECORD_FAILED` の reason を completion report に転記する (判定は不変、AC-3) |
   | sentinel なし、または `iteration_id` が本 cycle の `REVIEW_CYCLE_ID` と不一致 (前 cycle のもの) | **ERROR**: 6.1.d が本 cycle で未評価。下記 ACTION を実行 |

   **On ERROR**:

   ```
   ERROR: ステップ 6.1.d integrity check failed.
   No current-cycle [CONTEXT] NONBLOCKING_RECORD_DONE=1 sentinel found (absent, or iteration_id != REVIEW_CYCLE_ID).
(注: Pre-Check の pending_marker_present で落ちた場合は sentinel が実在することがある — その場合は
 「未実行」ではなく caller 契約違反による差し戻しなので、NONBLOCKING_RECORD_FAILED の reason (`body_file_empty` / `body_marker_missing` / `body_sentinel_missing` / `count_body_mismatch` のいずれか) を読むこと。`body_check_unavailable` は該当しない — 環境起因で marker を残さない。)
   This means ステップ 6.1.d was NOT executed in this cycle, OR the helper rejected a caller-contract violation
   with exit 1 before its trap was installed (the 7 exit-1 reasons: placeholder residue 5 + content_file_missing + unknown_option).
   ACTION: 会話コンテキストで [CONTEXT] NONBLOCKING_RECORD_FAILED=1; reason=... を探す。
     **本 marker は iteration_id を持たない** (helper が引数 gate 段階で落ちると iteration_id が
     未検証のため載せられない)。よって cycle N-1 の失敗行が context に残っていても見分けが付かない。
     **本 cycle の step 2 を実行した位置より後ろに現れた行だけを採用する** こと。
     - 本 cycle の行がある場合: 6.1.d reasons 表の当該 reason に従い、引数のリテラル置換漏れ / step 1 の
       Write 漏れを直してから step 1-2 を再実行する。**同じ引数での単純再実行は placeholder residue では
       必ず同じ失敗を再現する。**
       **例外: `iteration_id_placeholder_residue` は 6.1.a step 0 まで戻る。** 本 reason の root cause が
       step 0 の `REVIEW_CYCLE_ID` emit 側 (`{pr_number}` 未置換等) にある場合、6.1.d step 1-2 を何度
       再実行しても同じ壊れた marker 値を読み直すため収束しない。まず step 0 の emit 値を確認する。
     - 本 cycle の行が無い場合 (marker 自体が無い / 過去 cycle のものだけ): 6.1.d 全体が未実行。
       step 1 (本文生成) から実行する。
   Do NOT emit the result pattern ([review:mergeable] / [review:fix-needed:{n}]) without a current-cycle
   NONBLOCKING_RECORD_DONE sentinel.
   ```

   本 gate は prose instruction として LLM 側の認識に依存する (ステップ 7.7 / 8.0.1 / 8.0.3 と同じ性質)。LLM は ERROR text を認識して 6.1.d step 1 に戻る必要がある。

### 6.2 Update Work Memory Phase

> **Reference**: Update work memory per `work-memory-format.md` (at `{plugin_root}/skills/rite-workflow/references/work-memory-format.md`). Update phase to `review`, detail to `レビュー中`.

**Step 1: Update local work memory (SoT)**

Use the self-resolving wrapper. See [Work Memory Format - Usage in Commands](../../skills/rite-workflow/references/work-memory-format.md#usage-in-commands) for details.

```bash
# hook stderr 退避 + lock/non-lock 分岐 (fix.md ステップ 4.5 と対称。silent suppress 禁止)
# rationale: ../fix/references/design-rationale.md#output-pattern-notes と同根
hook_err=$(mktemp "${TMPDIR:-/tmp}/rite-review-p62-hook-err-XXXXXX") || hook_err=""
if [ -n "$hook_err" ]; then
 if WM_SOURCE="review" \
 WM_PHASE="review" \
 WM_PHASE_DETAIL="レビュー中" \
 WM_NEXT_ACTION="レビュー結果に基づき次のアクションを決定" \
 WM_BODY_TEXT="Review cycle completed." \
 WM_ISSUE_NUMBER="{issue_number}" \
 bash {plugin_root}/hooks/local-wm-update.sh 2>"$hook_err"; then
 : # success
 else
 hook_rc=$?
 # lock 判定は exact phrase のみ (緩い `lock|contention|busy` は他エラーを silent suppress する)
 if grep -qiE '(file is locked|lock contention|resource busy)' "$hook_err"; then
 echo "WARNING: local work memory lock contention (best-effort skip, rc=$hook_rc)" >&2
 else
 echo "WARNING: local-wm-update.sh failed (non-lock failure, rc=$hook_rc):" >&2
 head -5 "$hook_err" | sed 's/^/ /' >&2
 echo " 対処: hooks/local-wm-update.sh の存在 / 実行権限 / 内容を確認してください" >&2
 fi
 fi
 rm -f "$hook_err"
else
 # mktemp 失敗時は stderr を 2>&1 経由で stdout 統合し、失敗時に上位 5 行を表示する簡易 fallback
 echo "WARNING: hook_err mktemp 失敗により local-wm-update.sh の stderr 詳細が取得できません" >&2
 if hook_combined=$(WM_SOURCE="review" \
 WM_PHASE="review" \
 WM_PHASE_DETAIL="レビュー中" \
 WM_NEXT_ACTION="レビュー結果に基づき次のアクションを決定" \
 WM_BODY_TEXT="Review cycle completed." \
 WM_ISSUE_NUMBER="{issue_number}" \
 bash {plugin_root}/hooks/local-wm-update.sh 2>&1); then
 : # success
 else
 hook_fallback_rc=$?
 echo "WARNING: local-wm-update.sh failed (fallback no-tempfile path, rc=$hook_fallback_rc):" >&2
 printf '%s\n' "$hook_combined" | head -5 | sed 's/^/ /' >&2
 fi
fi
```

**On lock failure**: Log a warning and continue — local work memory update is best-effort. **Non-lock failure** (script 不在 / permission / syntax / internal error) は WARNING + stderr 5 行を表示してから継続する (review 全体を block しない)。fix.md ステップ 4.5 L-5 修正と対称化済み。

**Step 2: Sync to Issue comment (backup)** at phase transition (per C3 backup sync rule).

```bash
# 上記 Step 1 と同じ L-5 パターンを適用
sync_err=$(mktemp "${TMPDIR:-/tmp}/rite-review-p62-sync-err-XXXXXX") || sync_err=""
if [ -n "$sync_err" ]; then
 if bash {plugin_root}/hooks/issue-comment-wm-sync.sh update \
 --issue {issue_number} \
 --transform update-phase \
 --phase "review" --phase-detail "レビュー中" \
 2>"$sync_err"; then
 :
 else
 sync_rc=$?
 # exact phrase pattern (canonical: common-error-handling.md#hook-lock-contention-classification-canonical)
 if grep -qiE '(file is locked|lock contention|resource busy)' "$sync_err"; then
 echo "WARNING: issue-comment-wm-sync lock contention (best-effort skip, rc=$sync_rc)" >&2
 else
 echo "WARNING: issue-comment-wm-sync failed (non-lock failure, rc=$sync_rc):" >&2
 head -5 "$sync_err" | sed 's/^/ /' >&2
 fi
 fi
 rm -f "$sync_err"
else
 echo "WARNING: sync_err mktemp 失敗により issue-comment-wm-sync.sh の stderr 詳細が取得できません" >&2
 if sync_combined=$(bash {plugin_root}/hooks/issue-comment-wm-sync.sh update \
 --issue {issue_number} \
 --transform update-phase \
 --phase "review" --phase-detail "レビュー中" \
 2>&1); then
 : # success
 else
 sync_fallback_rc=$?
 echo "WARNING: issue-comment-wm-sync.sh failed (fallback no-tempfile path, rc=$sync_fallback_rc):" >&2
 printf '%s\n' "$sync_combined" | head -5 | sed 's/^/ /' >&2
 fi
fi
```

### 6.3 Review Metrics Recording

> **Reference**: [Execution Metrics - Review Metrics](../../references/execution-metrics.md#review-metrics)

Skip if `metrics.enabled: false` in rite-config.yml. Otherwise, record review metrics from the current review cycle.

**Step 1**: Collect metrics from the ステップ 5 review results:

| Item | Source |
|------|--------|
| CRITICAL findings count | Count from integrated report (ステップ 5.4) |
| HIGH findings count | Count from integrated report |
| MEDIUM findings count | Count from integrated report |
| LOW findings count | Count from integrated report |

**Step 2**: Record review metrics depending on `{post_comment_mode}`.

The target of metrics recording branches on `{post_comment_mode}` determined in ステップ 1.0. This avoids silent metrics loss in the default path (`post_comment_mode=false`).

| Mode | Recording target | Rationale |
|------|------------------|-----------|
| **opt-in** (`post_comment_mode=true`) | ステップ 6.1.b step-1 で Claude が PR コメント本文 (Write tool で `{review_tmp_dir}/rite-review-comment-{pr_number}.md` に書き出す body) を生成する際、metrics section を integrated report 末尾 (Raw JSON セクション直前) に含める。metrics は review 結果と同一コメントに集約され、別 API 呼び出しを避ける | opt-in 経路は単一の PR コメントに review 結果と metrics を集約する想定 |
| **default** (`post_comment_mode=false`) | Emit metrics as observability log only via `[CONTEXT] REVIEW_METRICS=critical={n};high={n};medium={n};low={n}` to stderr in ステップ 6.1.a or 6.1.c | default 経路で metrics の出力先を失わないための明示分岐。PR コメントには投稿せず、`[CONTEXT]` 経由で caller (`/rite:iterate`) が読み取れる形式にする |

**⚠️ Default 経路 (`post_comment_mode=false`) で metrics を JSON ファイルに埋め込まない理由**: review-result-schema.md の現行 schema には `metrics` top-level field が存在しない。schema 拡張は別 PR で実施する (本 PR は record target の明示化のみに留め、schema 変更は out-of-scope)。それまでは `[CONTEXT]` stderr emit が唯一の default 経路記録手段となる。

**`post_comment_mode=true` 時の append 実行タイミング**: metrics section は ステップ 6.1.b step-1 で Claude がコメント本文を生成し Write tool で `{review_tmp_dir}/rite-review-comment-{pr_number}.md` に書き出す際、ステップ 5.4 integrated report の末尾 (Raw JSON セクション直前) に含める (ステップ 6.1.b step-1 の metrics bullet を参照)。ステップ 6.1.a の JSON 本文 (Write tool で `{review_tmp_dir}/rite-review-result-{pr_number}.json` に書き出す body) には含めない (schema 変更 out-of-scope のため)。

**Note**: This step records raw data only as an observability log. metrics は `[CONTEXT] REVIEW_METRICS=...` (stderr, `post_comment_mode=false` path) または PR コメントの metrics section (`post_comment_mode=true` path) に記録され、ユーザーが必要に応じて参照する。

### 6.4 Update Issue Work Memory

> **Reference**: Update work memory per `work-memory-format.md`. Append review history and update next steps.

**Steps:**

All steps use `issue-comment-wm-sync.sh` for API operations. No direct `gh api` calls are needed — the script handles comment ID retrieval, caching, backup, safety checks, and PATCH internally.

1. **Update session info** (defense-in-depth): ステップ 6.2 で local work memory (SoT) を更新済みだが、Issue comment (backup) のセッション情報も冗長に更新する。

2. **Append review history**: Add review result summary to the work memory body.

3. **Update next steps**: Set the next command based on the review assessment.

```bash
# ステップ 6.4 全 hook 呼び出しに L-5 stderr 退避 + lock/non-lock
# 分岐パターンを適用 (fix.md ステップ 4.5 と対称化)。
# helper function として定義し、3 step に統一適用する (drift 防止)。
_rite_review_p64_run_sync() {
 local label="$1"
 shift
 local err_file
 err_file=$(mktemp "${TMPDIR:-/tmp}/rite-review-p64-sync-err-XXXXXX") || err_file=""
 if [ -n "$err_file" ]; then
 if "$@" 2>"$err_file"; then
 :
 else
 local rc=$?
 # exact phrase pattern (canonical: common-error-handling.md#hook-lock-contention-classification-canonical)
 if grep -qiE '(file is locked|lock contention|resource busy)' "$err_file"; then
 echo "WARNING: ${label} lock contention (best-effort skip, rc=$rc)" >&2
 else
 echo "WARNING: ${label} failed (non-lock failure, rc=$rc):" >&2
 head -5 "$err_file" | sed 's/^/ /' >&2
 fi
 fi
 rm -f "$err_file"
 else
 # mktemp 失敗時も silent suppress せず `2>&1` + `head -5` display fallback (ステップ 6.2 と同型)
 if hook_combined=$("$@" 2>&1); then
 :
 else
 local fallback_rc=$?
 echo "WARNING: ${label} failed (mktemp-unavailable fallback path, rc=$fallback_rc):" >&2
 printf '%s\n' "$hook_combined" | head -5 | sed 's/^/ /' >&2
 fi
 fi
}

# Step 1: セッション情報更新（defense-in-depth）
_rite_review_p64_run_sync "p64 update-phase" \
 bash {plugin_root}/hooks/issue-comment-wm-sync.sh update \
 --issue {issue_number} \
 --transform update-phase \
 --phase "review" --phase-detail "レビュー中"

# Step 2: レビュー対応履歴追記
review_tmp=$(mktemp) || {
 echo "WARNING: review_tmp mktemp 失敗。レビュー履歴の Issue コメント追記を skip します" >&2
 review_tmp=""
}
next_tmp=$(mktemp) || {
 echo "WARNING: next_tmp mktemp 失敗。次のステップの Issue コメント更新を skip します" >&2
 next_tmp=""
}
_rite_review_p64_cleanup() {
 rm -f "${review_tmp:-}" "${next_tmp:-}"
}
trap 'rc=$?; _rite_review_p64_cleanup; exit $rc' EXIT
trap '_rite_review_p64_cleanup; exit 130' INT
trap '_rite_review_p64_cleanup; exit 143' TERM
trap '_rite_review_p64_cleanup; exit 129' HUP
if [ -n "$review_tmp" ]; then
 cat > "$review_tmp" << 'REVIEW_EOF'
{review_history_content}
REVIEW_EOF
 _rite_review_p64_run_sync "p64 append-section" \
 bash {plugin_root}/hooks/issue-comment-wm-sync.sh update \
 --issue {issue_number} \
 --transform append-section \
 --section "レビュー対応履歴" --content-file "$review_tmp"
fi

# Step 3: 次のステップ更新
if [ -n "$next_tmp" ]; then
 printf '%s' "{next_step_content}" > "$next_tmp"
 _rite_review_p64_run_sync "p64 replace-section" \
 bash {plugin_root}/hooks/issue-comment-wm-sync.sh update \
 --issue {issue_number} \
 --transform replace-section \
 --section "次のステップ" --content-file "$next_tmp"
fi
rm -f "${review_tmp:-}" "${next_tmp:-}"
trap - EXIT
```

**Placeholder descriptions:**
- `{review_history_content}`: Review result summary (assessment, finding counts, commit SHA). Claude generates from ステップ 5 results.
- `{next_step_content}`: Next command based on assessment. Merge OK → `/rite:ready` | Requires fixes → `/rite:fix`

**Consistency guarantee**: Steps 1-3 collectively ensure that the Issue comment (backup) is consistent with the local work memory (SoT) updated in ステップ 6.2. This is a **defense-in-depth** design: if either path silently fails, the other guarantees at least one source has correct state for recovery.

### 6.5 Completion Report

```
PR #{number} のレビューを完了しました

総合評価: {recommendation}
レビュアー: {reviewer_count}人
指摘事項: {total_findings}件
 - CRITICAL: {count}件
 - HIGH: {count}件
 - MEDIUM: {count}件
 - LOW: {count}件

詳細はPRコメントを確認してください:
{pr_url}
```

#### 6.5.W Wiki Ingest Trigger (Conditional)

> **Reference**: [Wiki Ingest](../wiki-ingest/SKILL.md) — `wiki-ingest-trigger.sh` API

After outputting the completion report, trigger Wiki Ingest to capture review finding patterns as experiential knowledge.


**Condition**: Execute only when `wiki.enabled: true` AND `wiki.auto_ingest: true` in `rite-config.yml`. Configuration-based skip is the **only** legitimate skip path — it MUST emit a `WIKI_INGEST_SKIPPED=1` status line and `wiki_ingest_skipped` sentinel so the caller can detect and report (see ステップ 6.5.W.3 below).

**Step 1**: Check Wiki configuration (same pattern as ステップ 4.0.W Step 1, replacing `auto_query` with `auto_ingest`):

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
case "$wiki_enabled" in false|no|0) wiki_enabled="false" ;; true|yes|1) wiki_enabled="true" ;; *) wiki_enabled="true" ;; esac # opt-out default
case "$auto_ingest" in true|yes|1) auto_ingest="true" ;; *) auto_ingest="false" ;; esac
echo "wiki_enabled=$wiki_enabled auto_ingest=$auto_ingest"
```

If `wiki_enabled=false` or `auto_ingest=false`, **emit a skip status line + sentinel and return** (do not silently skip — the caller relies on this signal for ステップ 5.6 reporting):

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
 echo "WARNING: review ステップ 6.5.W Wiki ingest skipped: $reason" >&2
fi
```

If `reason` is non-empty, skip Steps 2 and ステップ 6.5.W.2 and proceed to ステップ 6.5.1. Otherwise continue to Step 2.

**Step 2**: Generate a review Raw Source from the review results:

The review content includes: PR number, reviewer types, finding categories, severity distribution, and key patterns detected.

```bash
# {plugin_root} はリテラル値で埋め込む
# ⚠️ wiki-ingest-trigger.sh は --content-file に $PWD 配下・/tmp/rite-*・$TMPDIR/rite-* prefix のみを受容する
# mktemp デフォルトの ${TMPDIR:-/tmp}/tmp.* では trigger が exit 1 で silent fail する
tmpfile=$(mktemp "${TMPDIR:-/tmp}/rite-wiki-content-XXXXXX")
trigger_stderr=$(mktemp "${TMPDIR:-/tmp}/rite-wiki-trigger-err-XXXXXX") || trigger_stderr=/dev/null
# rm -f /dev/null は EPERM (exit 1) を返すため trap で条件分岐する (F-07 対応)
trap 'rm -f "$tmpfile"; [ "$trigger_stderr" != "/dev/null" ] && rm -f "$trigger_stderr"' EXIT
content_write_failed=0  # heredoc write 失敗フラグ (Step 3 で genuine trigger 失敗と区別するため carry-forward)

# heredoc 書き込みの exit code を捕捉 (disk full / permission 拒否で truncated content が
# silent に ingest される regression を防ぐ。wiki ingest は非ブロッキングのため write 失敗時は ingest をスキップ)
if ! cat <<'REVIEW_EOF' > "$tmpfile"
## Review Results

- **PR**: #{pr_number} — {title}
- **Type**: review
- **Reviewed at**: {timestamp}
- **Reviewers**: {reviewer_list}

### Finding Patterns
{finding_summary — レビュー結果の指摘パターン、頻出エラー、プロジェクト固有の癖を LLM がレビュー結果から要約して埋め込む}

### Severity Distribution
- CRITICAL: {count}
- HIGH: {count}
- MEDIUM: {count}
- LOW: {count}
REVIEW_EOF
then
 echo "[CONTEXT] WIKI_CONTENT_WRITE_FAILED=1; reason=cat_redirection_failed" >&2
 echo "WARNING: review ステップ 6.5.W: tmpfile への heredoc 書き込みに失敗 (/tmp full / permission 拒否 / inode 枯渇)。wiki ingest を非ブロッキングにスキップ。" >&2
 trigger_exit=1
 content_write_failed=1
 echo "trigger_exit=$trigger_exit"
else
 bash {plugin_root}/hooks/wiki-ingest-trigger.sh \
  --type reviews \
  --source-ref "pr-{pr_number}" \
  --content-file "$tmpfile" \
  --pr-number {pr_number} \
  --title "PR #{pr_number} review results" \
  2>"$trigger_stderr"
 trigger_exit=$?
 echo "trigger_exit=$trigger_exit"
 if [ "$trigger_exit" -ne 0 ] && [ "$trigger_stderr" != "/dev/null" ] && [ -s "$trigger_stderr" ]; then
  # UTF-8 multi-byte 境界を safe にする (head -c 500 で切れた invalid sequence を drop)
  # (F-09 対応) iconv 不在環境 (Alpine 等) では LC_ALL=C tr で ASCII-only fallback
  if command -v iconv >/dev/null 2>&1; then
   _wiki_err_snippet=$(tr '\n' ' ' < "$trigger_stderr" | head -c 500 | iconv -c -f UTF-8 -t UTF-8 2>/dev/null)
  else
   _wiki_err_snippet=$(tr '\n' ' ' < "$trigger_stderr" | head -c 500 | LC_ALL=C tr -cd '\11\12\15\40-\176')
  fi
  echo "[CONTEXT] WIKI_TRIGGER_STDERR=${_wiki_err_snippet}" >&2
 fi
fi
echo "content_write_failed=$content_write_failed"
```

**ステップ 6.5.W content write failure reason** (reason table drift prevention — heredoc redirection の exit code を `WIKI_CONTENT_WRITE_FAILED` flag の reason 値として surface する):

| reason | Description |
|--------|-------------|
| `cat_redirection_failed` | tmpfile への heredoc redirection の exit code が非ゼロ (disk full / write permission denied / inode 枯渇 / IO error)。truncated content の silent ingest を防ぐため wiki ingest を非ブロッキングにスキップする |

**Non-blocking**: `wiki-ingest-trigger.sh` exit 2 (Wiki disabled/uninitialized) and other errors are captured in `trigger_exit` and do not halt the workflow. The LLM reads `trigger_exit` from stdout and skips ステップ 6.5.W.2 when it is non-zero. The LLM **also reads `content_write_failed` from the prior Step 2 stdout** (`echo "content_write_failed=$content_write_failed"`) and re-establishes it before evaluating Step 3 — a separate bash invocation does not inherit shell state, so the carry-forward of `content_write_failed` is required exactly as for `trigger_exit`. `content_write_failed=1` means the heredoc content write failed and the trigger was never invoked. Ingest failure does not block the review workflow.

**Step 3 — Failure surfacing**: 2 つの失敗経路を区別して surface する。

- **(a) content write 失敗** (`content_write_failed=1`): trigger は**起動していない**ため `trigger_exit` の値 (1) を reason にすると誤帰属になる。root cause は Step 2 の `WIKI_CONTENT_WRITE_FAILED` で既出だが、W Phase Completion Gate (ステップ 8.0.1) は `WIKI_INGEST_*` 接頭辞の sentinel しか認識しないため、gate-visible な `WIKI_INGEST_FAILED` を `reason=content_write_failed` で emit する。
- **(b) genuine trigger 失敗** (`trigger_exit != 0` AND `trigger_exit != 2`、exit 2 = Wiki disabled/uninitialized = legitimate skip は Step 1 で既出): `wiki-ingest-trigger.sh` が実際に非ゼロ終了したので `reason=trigger_exit_$trigger_exit` で emit する。

```bash
if [ "${content_write_failed:-0}" -eq 1 ]; then
 # write 失敗経路: trigger は未起動。gate (ステップ 8.0.1) は WIKI_INGEST_* のみ認識するため
 # accurate な reason を付けて WIKI_INGEST_FAILED を emit する (trigger_exit_1 への誤帰属を防ぐ)。
 echo "[CONTEXT] WIKI_INGEST_FAILED=1; reason=content_write_failed; exit_code=1"
 echo "WARNING: review ステップ 6.5.W: content write 失敗のため wiki ingest をスキップ (trigger は未起動)。" >&2
elif [ "${trigger_exit:-1}" -ne 0 ] && [ "${trigger_exit:-1}" -ne 2 ]; then
 echo "[CONTEXT] WIKI_INGEST_FAILED=1; reason=trigger_exit_$trigger_exit; exit_code=$trigger_exit"
 echo "WARNING: wiki-ingest-trigger.sh exited $trigger_exit during skills/pr-review/SKILL.md ステップ 6.5.W" >&2
fi
```

**ステップ 6.5.W Step 3 failure surfacing reason** (`WIKI_INGEST_FAILED` flag の reason 値):

| reason | Description |
|--------|-------------|
| `content_write_failed` | tmpfile への heredoc write 失敗 (`content_write_failed=1`)。trigger は未起動。root cause の `WIKI_CONTENT_WRITE_FAILED` とは別に、gate-visible な `WIKI_INGEST_FAILED` を accurate reason で surface する (`trigger_exit_*` への誤帰属を防ぐ) |
| `trigger_exit_<n>` | `wiki-ingest-trigger.sh` が exit `<n>` (≠0, ≠2) で終了した genuine trigger 失敗 |

#### 6.5.W.2 Wiki Raw Commit (Shell — deterministic path)


**Responsibility scope**: this block commits **raw sources only**. LLM-driven Wiki **page** integration (reading raw sources, deciding create/update/skip, writing `.rite/wiki/pages/*`) is **deferred** to `/rite:wiki-ingest`, which is idempotent over accumulated raw sources and can be invoked later — manually, or automatically in a separate session. The split guarantees that raw sources are never lost even when page integration is skipped or fails.

**Condition**: Execute only when **all** of the following are true (read from prior ステップ 6.5.W stdout):

- `wiki_enabled=true`
- `auto_ingest=true`
- `trigger_exit=0` (the trigger ran successfully — non-zero means Wiki disabled/uninitialized, so there is nothing to commit)

When the condition is not satisfied, skip this block and proceed to ステップ 6.5.1.

```bash
# {plugin_root} はリテラル値で埋め込む
#
# commit_err の signal trap 登録を block 冒頭で行う。
# SIGINT/SIGTERM/SIGHUP で中断された場合でも /tmp の一時ファイルが orphan として残らない。
commit_err=""
trap 'rm -f "${commit_err:-}"' EXIT INT TERM HUP

# mktemp failure must NOT silently swallow wiki-ingest-commit.sh stderr (fix / close と対称)。
# rc 捕捉は `if cmd; then :; else rc=$?; fi` 形式 (「!」否定は $? を反転するため使用禁止)
# rationale: ../fix/references/design-rationale.md#wiki-ingest-notes と同根
if commit_err=$(mktemp "${TMPDIR:-/tmp}/rite-wiki-commit-err-XXXXXX" 2>/dev/null); then
 : # mktemp 成功 — commit_err は valid path
else
 mktemp_commit_err_rc=$?
 echo "WARNING: mktemp failed for wiki-ingest-commit stderr capture (rc=$mktemp_commit_err_rc) — script stderr will be suppressed" >&2
 echo " hint: check /tmp permission / disk space / inode exhaustion" >&2
 commit_err="/dev/null"
fi
commit_rc=0
if commit_out=$(bash {plugin_root}/hooks/scripts/wiki-ingest-commit.sh 2>"${commit_err}"); then
 # Success — the script prints exactly one status line to stdout, e.g.
 # [wiki-ingest-commit] committed=1; branch=wiki; head=<sha>; push=ok
 # [wiki-ingest-commit] committed=0; branch=wiki; reason=no-pending
 echo "$commit_out"
 echo "[CONTEXT] WIKI_INGEST_DONE=1; pr={pr_number}; type=reviews"
else
 commit_rc=$?
 # exit 2 = 意図的 skip (wiki disabled / branch missing) / exit 4 = commit landed but push failed
 if [ "$commit_err" != "/dev/null" ] && [ -s "$commit_err" ]; then
 head -5 "$commit_err" | sed 's/^/ /' >&2
 fi
 case "$commit_rc" in
 2)
 echo "[CONTEXT] WIKI_INGEST_SKIPPED=1; reason=commit_branch_missing; exit_code=$commit_rc"
 echo "WARNING: wiki-ingest-commit.sh exited 2 (wiki branch missing / disabled) during skills/pr-review/SKILL.md ステップ 6.5.W.2" >&2
 ;;
 4)
 echo "[CONTEXT] WIKI_INGEST_PUSH_FAILED=1; reason=commit_rc_4; exit_code=$commit_rc"
 # script の stdout status 行 (`committed=N; ...; push=failed`) を保持して local commit を trace 可能にする
 if [ -n "${commit_out:-}" ]; then
 echo "$commit_out"
 fi
 echo "WARNING: wiki-ingest-commit.sh exited 4 (commit landed locally, push failed) during skills/pr-review/SKILL.md ステップ 6.5.W.2" >&2
 ;;
 *)
 echo "[CONTEXT] WIKI_INGEST_FAILED=1; reason=commit_rc_$commit_rc; exit_code=$commit_rc"
 echo "WARNING: wiki-ingest-commit.sh exited $commit_rc during skills/pr-review/SKILL.md ステップ 6.5.W.2" >&2
 ;;
 esac
fi
[ "$commit_err" != "/dev/null" ] && rm -f "$commit_err"
commit_err=""
trap - EXIT INT TERM HUP
```

**Non-blocking**: failures of this block do not halt the review workflow. `wiki-ingest-commit.sh` restores raw source files to the dev branch working tree on failure via its cleanup trap, so the next invocation can retry them.

**ステップ 6.5.W.2 Wiki Raw Commit failure reasons** (reason table drift prevention — `wiki-ingest-commit.sh` の exit code を `[CONTEXT] WIKI_INGEST_*` flag の reason 値として surface する):

| reason | Description |
|--------|-------------|
| `commit_branch_missing` | `wiki-ingest-commit.sh` が exit 2 (wiki branch 不在 / 無効) で終了 (`WIKI_INGEST_SKIPPED` flag、非ブロッキング) |
| `commit_rc_4` | `wiki-ingest-commit.sh` が exit 4 (commit はローカルに landed したが push 失敗) で終了 (`WIKI_INGEST_PUSH_FAILED` flag、非ブロッキング)。その他の非ゼロ exit は `commit_rc_$commit_rc` 動的 reason として `WIKI_INGEST_FAILED` flag で emit される |

**Position rationale**: [design-rationale.md#wiki-raw-source-placement-notes](references/design-rationale.md#wiki-raw-source-placement-notes) 参照。

**Responsibility boundary**: `wiki-ingest-trigger.sh` writes a raw source file into the dev branch working tree; `wiki-ingest-commit.sh` moves that file onto the `wiki` branch and commits it. Neither involves LLM work. The subsequent LLM-driven page integration is the exclusive responsibility of `/rite:wiki-ingest`, invoked at a later, independent time.

#### 6.5.1 Next Step Branching by Invocation Source

The behavior after the completion report varies by invocation source.

**Invocation source determination method:**

Claude determines the invocation source from the conversation context:

| Condition | Determination |
|------|---------|
| Conversation history has a record of `rite:pr-review` being invoked via the `Skill` tool | Within loop -> Automatically execute the next step |
| Otherwise (user directly entered `/rite:pr-review`) | Standalone execution -> Confirm the next action with `AskUserQuestion` |

**Note**: This adopts the same conversation context method as `skills/lint/SKILL.md` and `skills/fix/SKILL.md`.

---

**When invoked from within the `/rite:iterate` loop:**

**Step 1: Process recommendation-based Issue candidates (ステップ 7)**

Before outputting the result pattern, execute ステップ 7.1-7.4 to process recommendation-based Issue candidates:
- Extract candidates per ステップ 7.1 (Source A scope-irrelevant findings and Source B recommendations — Source A findings not flagged as scope-irrelevant are handled by the fix loop)
- If candidates exist: **always** invoke `AskUserQuestion` per ステップ 7.2-7.3 (E2E no longer skips user confirmation — user must approve each candidate)
- If no candidates: skip silently

**Condition**: Execute only when the review result is `[review:mergeable]`. When `[review:fix-needed:N]`, skip ステップ 7 (the fix loop will continue; ステップ 7 will run on the eventual mergeable review to avoid duplicate Issue creation).

**Step 2: Output the result pattern**

| Overall Assessment | Output Pattern |
|---------|------------------------|
| **Merge OK** (`total_findings == 0` = blocking findings ゼロ) | `[review:mergeable]` |
| **Requires fixes** (`total_findings >= 1`) | `[review:fix-needed:{total_findings}]` |

> `total_findings` は blocking 集合の件数 (実測必須ゲートで降格された非実測指摘と scope=nit-noted を除く)。非実測指摘のみが残る場合は `[review:mergeable]` が正しい (AC-2、ステップ 8.1 の同注記を参照)。

**Note**: Within the loop, `/rite:pr-review` only outputs results via patterns. Subsequent processing (invoking `/rite:fix`, confirming `/rite:ready` execution, etc.) is determined and executed by `/rite:iterate` ステップ 1-4 (レビュー/修正ループ).

---

**When `/rite:pr-review` is executed standalone:**

Confirm the next action with `AskUserQuestion`. See ステップ 1.4 for the AskUserQuestion invocation format.

**Merge OK**: Options: Ready for review (推奨) → invoke `rite:ready` | Keep draft | Additional fixes → terminate

**Cannot merge/Requires fixes**: Options: Handle findings (推奨) → invoke `rite:fix` | Handle later → proceed to ステップ 7

**⚠️ Important**: Always use `AskUserQuestion` for standalone execution. Proceed to ステップ 7 after completion.

---

## ステップ 7: スコープ外指摘のトリアージ

<!-- 3 バイアスと先延ばし禁止の設計原則: rationale: references/design-rationale.md#step7-triage-redesign-notes -->

### 7.1 Extract Separate Issue Candidates

Extract candidates from **two sources**:

**Source A — Findings (指摘事項)**: Extract findings meeting: Severity MEDIUM+ AND contains keywords (`スコープ外`, `別 Issue`, `out of scope`, `separate issue`, etc.)

**Source B — Recommendations (推奨事項)**: Extract items from `recommendation_items` (ステップ 5.1 で収集) with `classification == "actionable"` OR `classification == "boundary"`. `design_confirmation` 分類の item は **本 Source B から除外** (reviewer 自身が「対応不要」と結論しており Issue 化対象外)。なお ステップ 5.4 "推奨事項" テーブルの "トリアージ対象" 列の ✅ は本判定結果を視覚化したもの。

**`candidate_count` assignment**:

ステップ 7.1 deduplication 完了後、Source A + Source B 合算の最終 candidate 数を `candidate_count` として会話コンテキストに保持する。本値は:
- ステップ 7.2 sentinel emit (`[CONTEXT] PHASE_7_ASKUSER_INVOKED=1; candidates={N}` の `{N}`) に literal substitute される
- ステップ 7.7 post-condition gate / ステップ 8.0.2 cross-reference の trigger 条件 (`candidate_count >= 1`) で参照される


Deduplicate across sources: if the same file:line appears in both Source A and Source B, keep only the Source A entry (it has richer metadata).

**元 Issue の解決**: `{head_ref}`（ステップ 1.1 で取得済みの PR head branch）から `grep -oE 'issue-[0-9]+' | grep -oE '[0-9]+'` で issue 番号を抽出し `{source_issue_number}` として保持する（ステップ 1.1.5 と同じ抽出ロジックの再利用。1.1.5 は multi_session 有効時のみ実行されるため、本ステップで独立して再抽出し常時利用可能にする）。抽出できない場合（issue 番号を含まないブランチ名の PR）は `{source_issue_number}` を空とし、ステップ 7.2 で「Decision Log に記録」選択肢を候補から非表示にする。

各候補は Source（A/B）を保持する。Source A candidate はさらに `内容` 列に `Likelihood-Evidence:` prefix（[severity-levels.md](../../references/severity-levels.md#observed-likelihood-axis) 準拠）の有無で Observed/Demonstrable か Hypothetical かを判定できる状態を維持する（ステップ 7.2 の推奨機械決定表で参照する）。

### 7.2-7.3 推奨決定 + User Confirmation

If 0 candidates: Skip ステップ 7 (and **skip ステップ 7.7 post-condition gate** — see 7.7 below). If 1+: **Always** confirm with `AskUserQuestion` — this confirmation is mandatory in both standalone and E2E flow. User must explicitly approve each candidate.

**推奨機械決定表**（裁量禁止。エージェントは自分の作業量を減らす目的で「別 Issue 作成」を推奨してはならない — 各候補の推奨は以下の表から機械的に決まる）:

| 候補の性質 | 推奨 |
|-----------|------|
| Source B（推奨事項）由来、または Source A で `内容` に `Likelihood-Evidence:` prefix が無い（Hypothetical） | Decision Log に記録 |
| Source A かつ `内容` に `Likelihood-Evidence:` prefix がある（Observed / Demonstrable。MEDIUM+ は 7.1 の抽出条件で担保済み） | 別 Issue 作成 |

`{source_issue_number}`（ステップ 7.1 で解決）が空の候補は「Decision Log に記録」選択肢自体を非表示にする（3 択: 別 Issue 作成 / 本 PR で対応 / 無視。この場合は推奨を付与しない）。

**MANDATORY — ステップ 7.2 sentinel emit**:

Immediately before invoking `AskUserQuestion`, emit the following sentinel to the conversation context so ステップ 7.7 post-condition gate can mechanically verify that ステップ 7.2 was executed:

```bash
# LLM (Claude) は以下を Bash tool で実行する前に literal 置換すること:
# - {N} → ステップ 7.1 で抽出した candidate 総数 (Source A + Source B、dedup 後の正整数)
# - {iteration_id} → ステップ 7.1 で生成した一意 ID (例: pr_number-$(date +%s) 形式)
# Bash 変数 (${candidate_count} 等) は Bash tool 呼び出し間で継承されないため使用不可
echo "[CONTEXT] PHASE_7_ASKUSER_INVOKED=1; candidates={N}; iteration_id={iteration_id}" >&2
```

Where `{N}` is the total count of candidates extracted in ステップ 7.1 (Source A + Source B, post-deduplication). `{iteration_id}` is a unique identifier per review iteration (recommended format: `${pr_number}-$(date +%s)`) so a later iteration of a review-fix loop does NOT false-positive match an earlier iteration's sentinel. This sentinel is consumed by ステップ 7.7 (post-condition gate) and ステップ 8.0.2 (gate reference) to verify that the LLM did NOT skip ステップ 7.2 when `candidate_count >= 1`. The sentinel MUST be emitted on stderr (not stdout) and MUST be included in the response text (stderr emit は Bash tool が transcript に取り込んで会話コンテキストに自動載せるが、grep 検出は response text 内の literal を直接参照するため LLM が response 内にも verbatim で含めることが SHOULD レベルの defensive practice として推奨される)。

**AskUserQuestion prompt text**:

```
以下は PR #{N} の diff とは無関係と reviewer が判定した問題です。各候補について対応方針を選んでください: [Decision Log に記録 / 別 Issue 作成 / 本 PR で対応 / 無視]（先頭 = 推奨機械決定表による推奨。候補ごとに順序を入れ替え、推奨に "(Recommended)" を付与する）
```

**Candidate display format:**

| # | Source | ファイル | 内容 | 重要度 | Priority | 推奨 |
|---|--------|---------|------|--------|----------|------|
| 1 | 指摘 | {file:line} | {content} | {severity} | {mapped_priority} | {推奨機械決定表より: Decision Log に記録 / 別 Issue 作成} |
| 2 | 推奨 | {file:line or "—"} | {content} | — | Medium | Decision Log に記録 |

**Default values for recommendation-based candidates** (Source B):
- **Priority**: `Medium`
- **Complexity**: `S`
- **Severity in Issue body**: `推奨事項（重要度なし）`
- **File:line**: Use mentioned path if available; otherwise `特定ファイルなし`

**E2E flow behavior**: Same as standalone — **always** present `AskUserQuestion` and wait for explicit user approval per candidate. Do NOT auto-decide disposition (Issue 作成 or Decision Log 記録) without user confirmation, even in E2E. Previous behavior (auto-create under E2E) has been removed to enforce user control over scope-irrelevant disposition.

### 7.4 Disposition Execution

ステップ 7.2-7.3 で確定した候補ごとの選択に応じて分岐する:

| User selection | Action |
|-----------------|--------|
| 別 Issue 作成 | 7.4.1-7.4.2（Issue 作成）を実行 |
| Decision Log に記録 | 7.4.3（Decision Log Append）を実行 |
| 本 PR で対応 / 無視 | 追加のアクションなし（既存動作を維持） |

「別 Issue 作成」選択時（7.4.1-7.4.2）: Create Issues directly using `gh issue create` and register them in GitHub Projects. Do **not** use the `/rite:issue-create` Skill tool (it triggers interactive prompts that disrupt the flow).

Issue creation failure reasons: (`body_tmpfile_write_failure` / `empty_body_tmpfile` / `empty_script_result`)

| reason | Description |
|--------|-------------|
| `body_tmpfile_write_failure` | Issue body heredoc write to tmpfile failed |
| `empty_body_tmpfile` | Issue body tmpfile is empty after write |
| `empty_script_result` | create-issue-with-projects.sh returned empty result |

#### 7.4.1 Generate Issue Title

```
{type}: {summary}
```

| Element | Generation Method |
|---------|-------------------|
| `{type}` | Inferred from the finding content (`fix`, `feat`, `refactor`, `docs`, etc.) |
| `{summary}` | Summarize the finding's description (50 characters or less, starting with a verb) |

#### 7.4.2 Create Issue via Common Script

> **Reference**: [Issue Creation with Projects Integration](../../references/issue-create-with-projects.md)

**Note**: The heredoc below contains `{placeholder}` markers. Claude substitutes these with actual values **before** generating the bash script — they are not shell variables.

**Important**: The entire script block must be executed in a **single Bash tool invocation**.

**Priority mapping**: CRITICAL→High, HIGH→Medium, MEDIUM→Low, LOW-MEDIUM→Low, LOW→Low, Recommendation (Source B)→Medium

**Complexity mapping**: XS: single-line/single-location fix. S: multi-line change within 1-2 files

**Placeholder value sources** (Claude はスクリプト生成前に必ず以下のソースから値を取得し、プレースホルダーを置換すること):

| Placeholder | Source | Example |
|-------------|--------|---------|
| `{projects_enabled}` | `rite-config.yml` → `github.projects.enabled` | `true` |
| `{project_number}` | `rite-config.yml` → `github.projects.project_number` | `6` |
| `{owner}` | `rite-config.yml` → `github.projects.owner` | `B16B1RD` |
| `{iteration_mode}` | `rite-config.yml` → `iteration.enabled` が `true` かつ `iteration.auto_assign` が `true` なら `"auto"`、それ以外は `"none"` | `"none"` |
| `{plugin_root}` | [Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script-full-version) | `/home/user/.claude/plugins/rite` |

**⚠️ Projects 登録失敗時の警告表示（必須）**: スクリプト実行後、`project_registration` の値を必ず確認し、`"partial"` または `"failed"` の場合は以下を表示すること:

```
⚠️ Projects 登録が完全に完了しませんでした（status: {project_registration}）
手動登録: gh project item-add {project_number} --owner {owner} --url {created_issue_url}
```

```bash
tmpfile=$(mktemp)
trap 'rm -f "$tmpfile"' EXIT

if ! cat <<'BODY_EOF' > "$tmpfile"
## 概要

{description}

## 背景

この Issue は PR #{pr_number} のレビューで検出されたスコープ外の{source_label}から作成されました。

### 元のレビュー{source_label}
- **ファイル**: {file}:{line}
- **レビュアー**: {reviewer_type}
- **重要度**: {severity}
- **{source_label}内容**: {original_comment}

## 関連

- 元の PR: #{pr_number}
BODY_EOF
then
 echo "ERROR: Issue 本文テンプレートの一時ファイル書き込みに失敗" >&2
 echo "[CONTEXT] ISSUE_CREATE_FAILED=1; reason=body_tmpfile_write_failure" >&2
 exit 1
fi

if [ ! -s "$tmpfile" ]; then
 echo "ERROR: Issue 本文の生成に失敗" >&2
 echo "[CONTEXT] ISSUE_CREATE_FAILED=1; reason=empty_body_tmpfile" >&2
 exit 1
fi

# jq -n の出力を stdin で create-issue-with-projects.sh に渡す。
# 旧コードは jq 出力をコマンド置換でスクリプト引数に入れ子展開していたが、パイプ + 1 段の
# コマンド置換に削減して malform 確率を下げた (入れ子コマンド置換の literal 例は除去済)。
result=$(jq -n \
 --arg title "{type}: {summary}" \
 --arg body_file "$tmpfile" \
 --argjson projects_enabled {projects_enabled} \
 --argjson project_number {project_number} \
 --arg owner "{owner}" \
 --arg priority "{priority}" \
 --arg complexity "{complexity}" \
 --arg iter_mode "{iteration_mode}" \
 '{
 issue: { title: $title, body_file: $body_file },
 projects: {
 enabled: $projects_enabled,
 project_number: $project_number,
 owner: $owner,
 status: "Todo",
 priority: $priority,
 complexity: $complexity,
 iteration: { mode: $iter_mode }
 },
 options: { source: "pr_review", non_blocking_projects: true }
 }' | bash {plugin_root}/scripts/create-issue-with-projects.sh)

if [ -z "$result" ]; then
 echo "ERROR: create-issue-with-projects.sh returned empty result" >&2
 echo "[CONTEXT] ISSUE_CREATE_FAILED=1; reason=empty_script_result" >&2
 exit 1
fi
created_issue_url=$(printf '%s' "$result" | jq -r '.issue_url')
project_reg=$(printf '%s' "$result" | jq -r '.project_registration')
printf '%s' "$result" | jq -r '.warnings[]' 2>/dev/null | while read -r w; do echo "⚠️ $w"; done
```

**Source-aware placeholder values**: The `{source_label}` placeholder in the heredoc template above must be substituted based on the candidate source. When from Source A (findings), use `指摘`. When from Source B (recommendations), use `推奨事項`. The `{severity}` placeholder uses the actual severity for Source A, or `推奨事項（重要度なし）` for Source B. The `{file}:{line}` placeholder uses `特定ファイルなし` for Source B when no file path is mentioned.

**Error handling**:

| Error Case | Response |
|------------|----------|
| Script returns `issue_url: ""` | Display warning with error details. If remaining candidates exist, continue creating others |
| `project_registration: "partial"` or `"failed"` | Display warnings from result. Issue creation itself succeeded |

#### 7.4.3 Decision Log Append

候補ごとに「Decision Log に記録」が選択されたとき、元 Issue（`{source_issue_number}`、ステップ 7.1 で解決）の Section 9 Decision Log へ 1 行 append する。Section 9 が存在しない場合は作業メモリの「決定事項・メモ」セクションへフォールバックする。

**Placeholder value sources**: Claude はスクリプト生成前に候補の内容から `{decision}`（候補内容の要約、1 文。改行を含めないこと）、`{reason}`（推奨機械決定表の判定根拠。例: `Hypothetical 判定のためスコープ外指摘として記録` / `推奨事項（boundary 分類）のため記録`）を生成する。`{impact}` は候補の file:line、無ければ `特定ファイルなし`。`{source_issue_number}` はステップ 7.1 で解決した値、`{plugin_root}` は [Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script-full-version) で解決する。候補が複数ある場合も、本ブロックは **候補ごとに単一 Bash tool invocation** で実行する（複数候補を 1 呼び出しでループさせると `trap` が候補間で上書きされ tmpfile がリークするため）。

```bash
today=$(date +%Y-%m-%d)

# {decision}/{reason}/{impact} は reviewer/レビュー指摘由来の free-text。quoted heredoc
# (`<<'DECISION_EOF'`) でシェル展開を無害化してから読み込む（`line_content="{decision} ..."`
# のような直接代入は backtick / `$(` / `"` 混入時にコマンド置換・文字列破壊を招くため禁止）。
decision_tmp=$(mktemp)
if ! cat <<'DECISION_EOF' > "$decision_tmp"
{decision} / Reason: {reason} / Impact: {impact}
DECISION_EOF
then
  echo "ERROR: Decision Log 行テンプレートの一時ファイル書き込みに失敗" >&2
  echo "[CONTEXT] DECISION_LOG_APPEND_FAILED=1; reason=line_content_write_failure; issue={source_issue_number}" >&2
  rm -f "$decision_tmp"
  exit 1
fi
line_content=$(tr -d '\n' < "$decision_tmp")
rm -f "$decision_tmp"

body=$(gh issue view {source_issue_number} -R {owner_repo} --json body --jq '.body')

if [ -z "$body" ]; then
  echo "WARNING: 元 Issue #{source_issue_number} の body 取得に失敗。Decision Log 記録をスキップします" >&2
  echo "手動追記してください: - ${today} D-NN: ${line_content}" >&2
  echo "[CONTEXT] DECISION_LOG_APPEND_FAILED=1; reason=body_fetch_failure; issue={source_issue_number}" >&2
elif printf '%s' "$body" | grep -q '^## 9\. Decision Log'; then
  # `(^|[^A-Za-z])D-[0-9]+` で先頭境界を要求し、prose 中の `CARD-12` 等の部分文字列誤マッチを防ぐ
  max_d=$(printf '%s' "$body" | grep -oE '(^|[^A-Za-z])D-[0-9]+' | grep -oE '[0-9]+' | sort -n | tail -1)
  [ -n "$max_d" ] || max_d=0
  next_num=$((max_d + 1))
  next_d=$(printf 'D-%02d' "$next_num")
  new_line="- ${today} ${next_d}: ${line_content}"

  tmpfile=$(mktemp)
  trap 'rm -f "$tmpfile"' EXIT
  awk_rc=0
  # `awk -v` はバックスラッシュエスケープを解釈するため（`\n`→改行, `\t`→タブ, `\d`→`d` 等）、
  # $new_line に正規表現例・Windows パス等 backslash を含む free-text が入ると「1 行 append」
  # 不変条件（AC-3）を破って複数行に分割されうる。ENVIRON はエスケープ解釈しないため経由する。
  printf '%s\n' "$body" | NEW_LINE="$new_line" awk '
    /^## 9\. Decision Log/ { print; in_section=1; next }
    in_section && (/^## / || /^---[[:space:]]*$/) { print ENVIRON["NEW_LINE"]; print; in_section=0; next }
    { print }
    END { if (in_section) print ENVIRON["NEW_LINE"] }
  ' > "$tmpfile" || awk_rc=$?

  # awk 異常終了時（部分出力）で body 全体を切り詰めたまま上書きしないよう、exit code も検査する
  # （full-body PATCH のため `[ -s ]` の非空チェックだけでは途中終了の部分出力を見逃す）。
  if [ "$awk_rc" -eq 0 ] && [ -s "$tmpfile" ] && gh issue edit {source_issue_number} -R {owner_repo} --body-file "$tmpfile"; then
    echo "[CONTEXT] DECISION_LOG_APPENDED=1; issue={source_issue_number}; entry=$next_d"
    echo "記録: $new_line"
  else
    echo "WARNING: 元 Issue #{source_issue_number} への Decision Log append に失敗しました" >&2
    echo "手動追記してください: $new_line" >&2
    echo "[CONTEXT] DECISION_LOG_APPEND_FAILED=1; reason=gh_edit_failure; issue={source_issue_number}" >&2
  fi
else
  # Section 9 が無い Issue → 作業メモリ「決定事項・メモ」へフォールバック。
  # issue-comment-wm-sync.sh は non_comment/失敗時も exit 0 を返し、成否は stdout の
  # status=/reason= 行でのみ通知する契約（helper 冒頭コメント参照）。exit code のみでの成否判定は
  # false-success を招くため、fix/SKILL.md の正典 shim パターン（status=/reason= パース）に揃える。
  memo_tmp=$(mktemp)
  trap 'rm -f "$memo_tmp"' EXIT
  printf '%s' "- ${today}: ${line_content}" > "$memo_tmp"
  wm_sync_err=$(mktemp 2>/dev/null) || wm_sync_err=""
  wm_sync_out=$(bash {plugin_root}/hooks/issue-comment-wm-sync.sh update \
    --issue {source_issue_number} \
    --transform append-section \
    --section "決定事項・メモ" --content-file "$memo_tmp" 2>"${wm_sync_err:-/dev/null}")
  wm_state=$(printf '%s\n' "$wm_sync_out" | sed -n 's/^status=\([a-z]*\).*/\1/p' | head -1)

  if [ "$wm_state" = "success" ]; then
    echo "[CONTEXT] DECISION_LOG_APPENDED=1; issue={source_issue_number}; fallback=work_memory"
  else
    echo "WARNING: 元 Issue #{source_issue_number} の作業メモリ「決定事項・メモ」への記録に失敗しました (helper status: $wm_sync_out)" >&2
    if [ -n "$wm_sync_err" ] && [ -s "$wm_sync_err" ]; then
      echo "  helper stderr (root-cause、先頭 5 行):" >&2
      head -5 "$wm_sync_err" | sed 's/^/    /' >&2
    fi
    echo "手動追記してください: - ${today}: ${line_content}" >&2
    echo "[CONTEXT] DECISION_LOG_APPEND_FAILED=1; reason=wm_sync_failure; issue={source_issue_number}" >&2
  fi
  [ -n "$wm_sync_err" ] && rm -f "$wm_sync_err"
fi
```

Decision Log append failure reasons: (`line_content_write_failure` / `body_fetch_failure` / `gh_edit_failure` / `wm_sync_failure`)

| reason | Description |
|--------|-------------|
| `line_content_write_failure` | Decision Log 行テンプレートの一時ファイル書き込みに失敗 |
| `body_fetch_failure` | 元 Issue の body 取得（`gh issue view`）に失敗 |
| `gh_edit_failure` | Section 9 への行挿入（awk）の異常終了、または `gh issue edit` 適用に失敗 |
| `wm_sync_failure` | Section 9 不在時の作業メモリ「決定事項・メモ」への sync に失敗 |

**Error handling**（いずれも non-blocking。review フローは継続する）: 上記いずれの reason も WARNING を stderr に出力し、記録予定行（`body_fetch_failure` 時は D-NN 未確定）を表示して手動追記を案内する。AC-5 は stderr 表示に加えて **completion report への表示** も要求するため（2 チャネル要件）、当該記録予定行は 7.5-7.6 の completion report にも転記する。

### 7.5-7.6 Append to PR & Report

Post Issue list to PR comment (`mktemp` + `--body-file`). Decision Log に記録した候補があれば件数を completion report に表示する（`[CONTEXT] DECISION_LOG_APPENDED=1` の出現回数）。**失敗した候補があれば**（`[CONTEXT] DECISION_LOG_APPEND_FAILED=1` の出現）、件数とあわせて各候補の「手動追記してください: ...」行（7.4.3 各失敗分岐が stderr に出力済みの記録予定行）を completion report にも転記し、手動追記が必要なことをユーザーに明示する（AC-5: stderr 出力のみでは completion report 表示要件を満たさない）。Output completion report.

### 7.7 Post-condition Gate — Recommendation Disposition Enforcement

本 gate は **mechanical gate**。ステップ 7.1 で 1+ candidate 抽出時に ステップ 7.2 (`AskUserQuestion` for candidate_count) を実行せず `[review:mergeable]` / `[review:fix-needed:{n}]` (ステップ 8.1) を emit する silent skip を遮断する (prose-only enforcement の置換)。

**Execution condition**: Always execute when ステップ 7 was entered (i.e., `candidate_count >= 1` (ステップ 7.1 Source A + Source B 合算、post-deduplication) was true). Skip silently when ステップ 7.1 yielded 0 candidates (ステップ 7.2 is legitimately not invoked).

**Step 1 — Determine candidate count**:

Read **ステップ 7.1 candidate_count** (post-deduplication, Source A findings + Source B recommendation_items where classification == "actionable" OR "boundary"). If `0`, **skip ステップ 7.7 entirely** and proceed to ステップ 8.0 (Defense-in-Depth State Update)。

本 gate はステップ 7.1 で抽出した **Source A+B 合算** の `candidate_count` を参照する。ステップ 5.1 Source B 抽出 (`recommendation_items` filter) と ステップ 7.1 candidate 抽出は別概念であり、本 gate はステップ 7.1 結果に基づいて発火する。

**Step 2 — Grep sentinel from conversation context (latest iteration_id)**:

Search the conversation context (ステップ 7.2 emit site) for the following sentinel pattern:

```
[CONTEXT] PHASE_7_ASKUSER_INVOKED=1; candidates={N}; iteration_id={ID}
```

Where `{N}` MUST be a positive integer matching the candidate count from Step 1, and `{ID}` is the iteration identifier emitted in ステップ 7.2.

**Latest iteration selection**: review-fix loop の cycle 2+ で同一 conversation に複数の `PHASE_7_ASKUSER_INVOKED` sentinel が存在しうる。ステップ 7.7 grep は **最大 iteration_id (epoch_seconds が最大のもの) を持つ行を採用** すること。これにより cycle 2 が cycle 1 の stale sentinel に false-positive match して silent pass する経路を遮断する (canonical ステップ 2.2.1 `code_quality_coreviewer_add_reason` の iteration_id 規約と同型)。

**Step 3 — Routing**:

| Condition | Action |
|-----------|--------|
| Latest sentinel found with `candidates >= 1` AND iteration_id matches current cycle | Gate passes — proceed to ステップ 8.0 (Defense-in-Depth State Update) |
| Latest sentinel NOT found AND candidate_count >= 1 | **ERROR**: ステップ 7.2 was skipped in current cycle. Execute the ACTION below |
| Latest sentinel found but iteration_id is **stale** (matches cycle N-1, not current cycle N) | **ERROR**: ステップ 7.2 was skipped in current cycle (cycle N-1 sentinel false-positive avoided). Execute the ACTION below |
| Sentinel found but `candidates == 0` | Defensive observation: ステップ 7.1 / 7.2 count mismatch (e.g., dedup edge case). Display WARNING and proceed (non-blocking, gate passes); the discrepancy is observability-only. ステップ 7.2-7.3 の "If 0 candidates: Skip ステップ 7" 規約が成立しているため、本行は通常到達不能 dead branch だが defense-in-depth として残す |

**On ERROR** (sentinel not found, candidates >= 1):

```
ERROR: ステップ 7.7 post-condition gate failed.
candidate_count = {N} (>= 1) but no [CONTEXT] PHASE_7_ASKUSER_INVOKED sentinel found.
This means ステップ 7.2 (AskUserQuestion) was NOT executed — silent skip of recommendation disposition.
ACTION: Return to ステップ 7.2, emit the sentinel, invoke AskUserQuestion for each candidate, then re-enter ステップ 7.7.
⚠️ LLM MUST NOT output [review:mergeable] or [review:fix-needed:{n}] until ステップ 7.2 has been executed and the sentinel is emitted.

ANTI-PATTERN reference: This gate enforces the prohibition declared in
.rite/wiki/pages/anti-patterns/aggregate-recommendation-label-evasion.md
(if Wiki has not yet ingested this page, see the background section).
Silent skip with aggregate label "推奨 N 件 (全て scope 外)" is the specific
failure mode being blocked here.
```

本 gate は prose instruction として LLM 側の認識に依存する (`exit 1` は LLM を halt しない)。LLM は ERROR text を認識してステップ 7.2 に戻る必要がある。gate は overall_assessment に関係なく発火する。 <!-- defensive layering (a)-(f) の全体像: references/design-rationale.md#phase7-gate-notes -->

---

## Error Handling

| Error | Action |
|--------|------|
| PR not found | Check with `gh pr list -R {owner_repo}` and re-run with the correct number |
| Skill file load failure | Fall back to the built-in pattern table (ステップ 2.2) for reviewer selection (WARNING を stderr に出力) |
| Review execution error | Choose skip/retry/cancel (skip 時は WARNING を stderr に出力) |
| Comment post failure | Display review results as text (WARNING を stderr に出力) |

---

## Configuration File Reference

Reference the following settings from `rite-config.yml`:

```yaml
review:
 min_reviewers: 1 # 最小レビュアー数（フォールバック用）
 max_reviewers: 6 # 最大レビュアー数（コスト上限、既定 6）。ステップ 3.2.1 で適用
 criteria:
 - file_types # ファイル種類による判断
 - content_analysis # 内容解析による判断
 security_reviewer:
 mandatory: false # 全 PR で必須選定するか
 recommended_for_code_changes: true # 実行可能コード変更時は推奨

commands:
 lint: null # 品質チェック用
 build: null # 品質チェック用
```
## ステップ 8: E2E フロー継続 (出力パターン)


### 8.0 Defense-in-Depth: State Update Before Output (End-to-End Flow)

Before outputting any result pattern (`[review:mergeable]`, `[review:fix-needed:{n}]`), update flow state to reflect the post-review phase (defense-in-depth). これはループ継続を支える **2 層構造のうち secondary (resume 用の網)** であり、フォークコンテキストが caller に戻った後に LLM が turn を終了しても、state file に正しい `next_action` が残るため `/rite:recover` で復帰できる。

継続 (`[review:fix-needed:{n}]`) の場合はさらに `--handoff "/rite:fix {pr_number}"` で **自動継続マーカー (primary)** をセットし、終了 (`[review:mergeable]`) の場合は `--handoff "FINALIZE:review:mergeable:{pr_number}"` で **終了通知マーカー (FINALIZE handoff)** をセットする。Stop hook による consume・再注入・無限 block 防止の機構解説: [stop-loop-continuation-contract.md#mechanism](../../references/stop-loop-continuation-contract.md#mechanism)

**Condition**: Execute only when flow state file exists (indicating e2e flow). Skip if the file does not exist (standalone execution).

**State update by result**:

| Result | Phase | Handoff (`--handoff`) | Next Action |
|--------|-------|-----------------------|-------------|
| `[review:mergeable]` | `review` | `FINALIZE:review:mergeable:{pr_number}` | `rite:pr-review completed. Result: [review:mergeable]. Proceed to /rite:ready (caller の review-fix loop が ready 遷移を起動). Do NOT stop.` |
| `[review:fix-needed:{n}]` | `review` | `/rite:fix {pr_number}` | `rite:pr-review completed. Result: [review:fix-needed:{n}]. Proceed to /rite:fix (caller の review-fix loop が fix 起動). Do NOT stop.` |

```bash
# [review:mergeable] の場合 (--handoff で FINALIZE 終了通知マーカーをセット):
bash {plugin_root}/hooks/flow-state.sh set \
 --phase "review" \
 --active true \
 --next "{next_action_value}" \
 --handoff "FINALIZE:review:mergeable:{pr_number}" \
 --if-exists

# [review:fix-needed:{n}] の場合 (--handoff で fix への継続マーカーをセット):
bash {plugin_root}/hooks/flow-state.sh set \
 --phase "review" \
 --active true \
 --next "{next_action_value}" \
 --handoff "/rite:fix {pr_number}" \
 --if-exists
```

Replace `{next_action_value}` with the value from the table above based on the review result, and `{pr_number}` with the actual PR number. Choose the bash variant by result: `[review:fix-needed:{n}]` uses the continuation `--handoff "/rite:fix {pr_number}"` form; `[review:mergeable]` uses the FINALIZE `--handoff "FINALIZE:review:mergeable:{pr_number}"` form (both variants always set `--handoff`). Also replace `{n}` in the next_action string with the actual finding count from the review result (e.g., if the result is `[review:fix-needed:3]`, then `{n}` = `3`).

**Note on `error_count`**: `flow-state.sh set` resets `error_count` to 0 by default on every phase transition, and preserves the existing value only when `--preserve-error-count` is passed. `error_count` is currently a reserved/legacy schema slot with no production reader; resetting on transition keeps the slot well-defined for future re-introduction without carrying stale counts.

**Gate evaluation order (SoT)**: 状態更新の後、result pattern を emit する前に、以下の post-condition gate を **記載順に評価する**。**すべての gate が pass した場合にのみ ステップ 8.1 (result pattern emit) へ進む**。いずれかが ERROR を出した場合は、その gate の ACTION に従って該当ステップへ戻り、再度 ステップ 8.0 から評価し直す。

```
8.0.1 (W Phase / Wiki ingest) → 8.0.2 (ステップ 7 disposition) → 8.0.3 (ステップ 6.1.d 非実測記録) → ステップ 8.1
```

各 gate の Routing 表は「pass したら**次の gate へ**進む」とだけ書き、終端 (ステップ 8.1) を名指ししない。8.0.4 以降を追加する場合は、(1) 本順序規定の 1 行に新 gate を挿入し、(2) `hooks/tests/review-helpers-gate-behavior.test.sh` TC-5d の期待リテラル **2 箇所**（ファイル全体を数える `count_lit` と、8.0 区間に限定する `_section_of` + `grep -cF`）を同じ文字列へ更新し、(3) 同 TC-5e の `_g_spec` list に `'8.0.4:{データ行数}:{pass 行数}:{ERROR 行数}'` を追加する。**既存 gate の pass 行は変更不要**（順序規定が終端を持つため）。rationale: [references/measured-gate-record.md#gate-order](references/measured-gate-record.md#gate-order)

### 8.0.1 W Phase Completion Gate (Defense-in-Depth)

本 gate は ステップ 6.5.W (Wiki Ingest) を skip した状態での result pattern (`[review:mergeable]` / `[review:fix-needed:{n}]`) emit を遮断する。ステップ 6.5.W が実行されていれば conversation context に `[CONTEXT] WIKI_INGEST_` sentinel が少なくとも 1 つ残る (Step 1 skip path / Step 3 failure path / ステップ 6.5.W.2 success/failure paths のいずれかで emit)。sentinel が全く無ければ LLM が ステップ 6.5.W を完全に skip したことを意味する。

**Condition**: Execute only when flow state file exists (indicating e2e flow) AND `wiki.enabled: true` in `rite-config.yml`. When wiki is disabled, W Phase is legitimately skipped (no sentinel expected) — pass the gate unconditionally.

**Check**: Search the conversation context for any of the following sentinel patterns:

- `[CONTEXT] WIKI_INGEST_DONE=1`
- `[CONTEXT] WIKI_INGEST_SKIPPED=1`
- `[CONTEXT] WIKI_INGEST_FAILED=1`
- `[CONTEXT] WIKI_INGEST_PUSH_FAILED=1`

**Routing**:

| Condition | Action |
|-----------|--------|
| At least one `WIKI_INGEST_` sentinel found | Gate passes — proceed to the next gate in the 8.0 evaluation order |
| No sentinel found AND `wiki.enabled: true` | **ERROR**: W Phase was skipped. Execute the ACTION below |
| No sentinel found AND `wiki.enabled: false` | Gate passes — wiki disabled, no sentinel expected. Proceed to the next gate in the 8.0 evaluation order |

**On ERROR** (no sentinel found, wiki enabled):

```
ERROR: ステップ 8.0.1 W Phase completion gate failed.
No [CONTEXT] WIKI_INGEST_* sentinel found in conversation context.
This means ステップ 6.5.W (Wiki Ingest Trigger) was NOT executed.
ACTION: Return to ステップ 6.5.W and execute the Wiki Ingest Trigger before outputting the result pattern. Do NOT continue the 8.0 gate sequence without a WIKI_INGEST_* sentinel.
⚠️ LLM MUST NOT output [review:mergeable] or [review:fix-needed:{n}] until ステップ 6.5.W has been executed.
```

本 gate は prose instruction として LLM 側の認識に依存する (`exit 1` は LLM を halt しない)。LLM は ERROR text を認識して ステップ 6.5.W に戻る必要がある。`flow-state.sh` の phase enum validation (`_phase_is_valid`) は phase *names* のみ check し W Phase sentinel presence は check しないため、本 gate が W Phase skip に対する **sole** defense layer となる。

### 8.0.2 ステップ 7 Post-condition Gate Reference

本 gate は ステップ 7.7 Post-condition Gate を cross-reference し、result-emit boundary を Wiki ingest gate (8.0.1) と recommendation disposition gate (ステップ 7.7) の両方で保護する。いずれもステップ 8.1 result emit の **前** に発火する。本 section は **sentinel-presence based defense-in-depth** で、ステップ 8.0.1 と同じ「sentinel 検出方式」で routing し、ステップ 7.7 execution の有無に依存しない。

**Condition**: Execute when `candidate_count >= 1` (ステップ 7.1 で抽出した Source A + Source B 合算)。`candidate_count == 0` の場合は ステップ 7 自体が skip されており本 gate も legitimately skipped。

**Check**: Search the conversation context for the latest `[CONTEXT] PHASE_7_ASKUSER_INVOKED=1; candidates={N}; iteration_id={ID}` sentinel (iteration_id 最大の行を採用、ステップ 7.7 Step 2 と同型の selection logic)。

**Routing** (ステップ 8.0.1 と完全に対称 — sentinel presence ベース、ERROR was emitted ベースではない):

| Condition | Action |
|-----------|--------|
| `candidate_count == 0` (ステップ 7 skipped) | Gate passes — proceed to the next gate in the 8.0 evaluation order |
| Latest sentinel found with `candidates >= 1` AND iteration_id matches current cycle | Gate passes — proceed to the next gate in the 8.0 evaluation order |
| Latest sentinel NOT found AND `candidate_count >= 1` | **ERROR**: ステップ 7 entire procedure (7.1-7.7) was skipped. Execute ACTION below |
| Latest sentinel found but iteration_id is stale (cycle N-1, not current cycle N) | **ERROR**: ステップ 7 was skipped in current cycle. Execute ACTION below |

**On ERROR** (sentinel absent or stale, `candidate_count >= 1`):

```
ERROR: ステップ 8.0.2 ステップ 7 Post-condition Gate failed.
candidate_count = {N} (>= 1) but no current-cycle [CONTEXT] PHASE_7_ASKUSER_INVOKED sentinel found.
This means ステップ 7 (entire procedure 7.1 candidate extraction → 7.2 AskUserQuestion → 7.7 gate) was NOT executed in the current review cycle.
ACTION: Return to ステップ 7.1, extract candidates, invoke AskUserQuestion (ステップ 7.2), emit sentinel, then re-enter ステップ 8.0.
⚠️ LLM MUST NOT output [review:mergeable] or [review:fix-needed:{n}] until ステップ 7 has been executed for the current cycle.
```

ステップ 7.7 (ステップ 7 procedure 内部の integrity check) と ステップ 8.0.2 (ステップ 7 全体 skip の最終 fallback) は catch する failure mode が異なる。 <!-- dual placement の設計理由: references/design-rationale.md#phase7-gate-notes -->

### 8.0.3 ステップ 6.1.d Post-condition Gate Reference

本 gate は ステップ 6.1.d (非実測指摘の PR コメント記録) の **全体 skip** に対する最終防波堤で、8.0.1 (ステップ 6.5.W) / 8.0.2 (ステップ 7) と同型の sentinel-presence based defense-in-depth。6.1.d step 3 の integrity check は 6.1.d サブステップ**内部**にあるため 6.1.d を丸ごと skip すると gate 自身も skip される — その failure mode を本 gate が result-emit boundary の**外側**で catch する (ステップ 7.7 ⇄ 8.0.2 の二層構成と同型)。既定設定 `post_comment: false` では 6.1.d のコメントが非実測指摘の唯一の共有可能な durable 記録 (`.rite/review-results/` は gitignore 対象) であり、skip = D-01「マージ後に人間が拾い直せる」の完全な喪失になる。

**catch できる範囲は「ステップ 6 が本 cycle で実行された」ことを前提とする**: 鮮度判定の参照値 `REVIEW_CYCLE_ID` は 6.1.a step 0 で emit される — つまり本 gate が守る 6.1.d と同じ ステップ 6 の内側にある。ステップ 6 を丸ごと skip した cycle では、会話に残る (前 cycle の `REVIEW_CYCLE_ID`, 前 cycle の sentinel) の組が互いに整合するため本 gate は pass する。8.0.2 の anchor である `candidate_count` が ステップ 7.1 で毎 cycle 再計算されるのとはこの点で非対称であり、「6.1.d 単独の skip」は catch できるが「ステップ 6 全体の skip」は catch できない。後者を塞ぐには ステップ 6 の実行自体を検証する gate (例: `JSON_SAVED` に cycle 識別子を載せる) が別途必要で、本 PR のスコープ外。

**Condition**: Always execute (6.1.d は `{post_comment_mode}` に依存せず常に評価される) — ただし **ステップ 6 が hard fail した場合を除く** (下記 Routing の 1 行目。8.0.1 の `wiki.enabled: false` 行 / 8.0.2 の `candidate_count == 0` 行と同じ legitimate skip)。

**Pre-Check (機械強制: pending marker の残存検査)**: 下記 bash を実行する。`{pending_marker}` は ステップ 6.1.a step 0 の `[CONTEXT] NONBLOCKING_PENDING_MARKER=` marker 値をリテラル置換する。**選択規則は下記 `**Check**` の `REVIEW_CYCLE_ID` と同一** — review-fix loop の cycle 2+ では同 marker が会話に複数残るため、**本 cycle のもの (末尾 `-{epoch}` が最大のもの) を採る**。**ただし本 cycle の `REVIEW_CYCLE_ID` に対応する `NONBLOCKING_PENDING_MARKER=` が空文字で emit されている場合は、epoch を持つ過去 cycle の値より空文字を優先して採る** — 空文字は本 cycle で marker を作れなかったこと (ステップ 6.1.a step 0 の `set -C` 拒否 / read-only な `${TMPDIR}`) を示し、epoch で順序付けできない。「対応する」は、同一の 6.1.a step 0 bash ブロックの出力内で `REVIEW_CYCLE_ID=` と対で emit された `NONBLOCKING_PENDING_MARKER=` 行を指す (marker 行自体は cycle 識別子を持たないため、隣接 emit が唯一の対応付け)。過去 cycle の実パスを採ると既に helper が削除済のため `pending_marker_absent` で誤 pass する。選択規則を片側にだけ置くと、同じ「6.1.d が本 cycle で完走したか」を二層で判定しているはずが層ごとに別 cycle の値を見ることになり、前 cycle の path (既に helper が削除済) を採った機械強制層は本 cycle で 6.1.d を丸ごと skip していても `pending_marker_absent` で pass する (rationale: [references/measured-gate-record.md#pending-marker](references/measured-gate-record.md#pending-marker))。**本検査は LLM が会話を読むかどうかに依存しない** — marker は 6.1.d の helper でしか消えないファイルであり、残存 = **6.1.d が本 cycle で完走していない、または caller 契約違反 (本文検査 4 段) で記録を拒否した**ことが機械的に確定する。prose gate だけでは「ERROR text を読まずに result pattern へ進む」経路を構造的に塞げないため、下記 `**Check**` の sentinel 検査と二層で持つ。

```bash
pending_marker="{pending_marker}"
case "$pending_marker" in
  "{"*"}")
    echo "WARNING: ステップ 8.0.3 の {pending_marker} が literal substitute されていません (値: '$pending_marker')。機械強制を skip し Check の prose 判定のみで続行します" >&2
    echo "[CONTEXT] NONBLOCKING_GATE=degraded; reason=pending_marker_placeholder_residue" >&2
    ;;
  "")
    # 6.1.a step 0 が marker を作れなかった (read-only /tmp 等)。同 step で WARNING 済。
    echo "[CONTEXT] NONBLOCKING_GATE=degraded; reason=pending_marker_unavailable" >&2
    ;;
  *)
    if [ -e "$pending_marker" ]; then
      echo "ERROR: ステップ 8.0.3 gate failed (機械強制)。pending marker が残存しています: $pending_marker" >&2
      echo "  これは ステップ 6.1.d (非実測指摘の記録) が本 cycle で完走していないことの機械的証拠です" >&2
      echo "  (marker を消すのは 6.1.d の helper だけです。caller 契約違反 = 本文検査 4 段 では意図的に残します)。" >&2
      echo "  ACTION: まず会話に [CONTEXT] NONBLOCKING_RECORD_FAILED=1; reason=body_file_empty / body_marker_missing / body_sentinel_missing / count_body_mismatch のいずれかがあるか確認してください (body_check_unavailable は対象外 — 環境起因で marker を残しません)。" >&2
      echo "    あれば caller 契約違反です — step 1 の**本文を作り直してから** step 2 を再実行します (同一 content-file での step 2 単独再実行は収束しません)。" >&2
      echo "    無ければ 6.1.d 自体が未実行です — step 1 (本文 Write) と step 2 (helper 実行) を実行してください。" >&2
      echo "  そのうえで ステップ 8.0 を再評価してください。" >&2
      echo "  marker はここでは削除しません — 削除すると 6.1.d を実行せずに再評価だけで gate を通せてしまい、本検査の意味が失われます。" >&2
      echo "  ⚠️ 本 gate を pass せずに ステップ 8.1 の result pattern を emit してはなりません。" >&2
      echo "[CONTEXT] NONBLOCKING_GATE_FAILED=1; reason=pending_marker_present; marker=$pending_marker" >&2
      exit 1
    fi
    echo "[CONTEXT] NONBLOCKING_GATE=pass; reason=pending_marker_absent" >&2
    ;;
esac
```

`NONBLOCKING_GATE` marker の分岐（**表にしないのは、本節の Routing 表が TC-5e の gate 別 per-row pin の対象であり、同じ節に 2 つ目の表を置くと「gate 表」の同定が曖昧になるため**）:

- `pass` → 機械強制を通過。下記 `**Check**` へ。
- `degraded` → marker が使えない環境。機械強制を skip し `**Check**` の prose 判定のみで続行。
- bash が `exit 1`（`NONBLOCKING_GATE_FAILED=1`）→ ステップ 6.1.d へ戻る。**ステップ 8.1 へ進んではならない**。

**Check**: 会話コンテキストから `[CONTEXT] NONBLOCKING_RECORD_DONE=1; pr={N}; outcome=...; count=...; iteration_id={ID}; ...` sentinel を探し、その `iteration_id=` が **本 cycle の `REVIEW_CYCLE_ID`** と一致するかを見る。**本 cycle の `REVIEW_CYCLE_ID` = 直近に emit された `[CONTEXT] REVIEW_CYCLE_ID=` の値** (複数ある場合は epoch 最大のもの。ステップ 8.0.2 の iteration_id 最大採用と同型 — 選択規則まで含めて 6.1.d step 3 と同一の述語にする)。**同一 `iteration_id` の sentinel が複数ある場合は最後に emit されたものを採る** (6.1.d step 3 と同一文言。本文検査 4 段の差し戻しが同一 cycle 内の再実行を強制するため)。**6.1.d step 3 と同一の述語** — 位置が違うだけで判定基準は変えない (片側だけ弱い述語にするとその位置で「動作前 marker を見る」欠陥が再発する)。Pre-Check が `pass` でも本検査は省略しない (marker は「helper が完走した」ことしか示さず、`outcome` / `degraded` の転記義務は sentinel 側が持つ)。

**Routing** (ステップ 8.0.1 / 8.0.2 と完全に対称):

| Condition | Action |
|-----------|--------|
| ステップ 6 が 6.1.b hard error / 6.1.c ケース 2 (`exit 2`) で fail し 6.1.d に到達していない | Gate は legitimately skipped — 6.1.d へ戻さず **ステップ 6 の失敗として扱う** (永続化の復旧が非実測記録より優先。6.1.c ケース 2 の silent data loss 防止を無効化しないため) |
| sentinel found AND `iteration_id` == 本 cycle の `REVIEW_CYCLE_ID` (`outcome` は問わない) | Gate passes — ただし `outcome=failed` / `aborted`、`degraded=1`（`outcome` を問わない）、または `NONBLOCKING_LEGACY_ORPHAN=1` / `NONBLOCKING_DUPLICATE_RECORD=1` を観測したときは **LLM が helper の WARNING / `NONBLOCKING_RECORD_FAILED` の reason を completion report に転記してから** the next gate in the 8.0 evaluation order へ進む (6.1.d step 3 と同一条件 — 片側だけに置かない) |
| sentinel NOT found (ステップ 6 は正常完了している) | **ERROR**: ステップ 6.1.d entire procedure was skipped. Execute ACTION below |
| sentinel found but `iteration_id` != 本 cycle の `REVIEW_CYCLE_ID` (cycle N-1 のもの) | **ERROR**: ステップ 6.1.d was skipped in current cycle. Execute ACTION below |

> 転記指示を 6.1.d step 3 と同じ強さで持たせる理由: rationale は [references/measured-gate-record.md#dual-gate](references/measured-gate-record.md#dual-gate)。
>
> `outcome=failed` (gh 失敗 / jq 実行環境起因 / 本文空 / 1 行目 marker 欠落 / sentinel が末尾に無い / count 不整合) でも本 `**Check**` 層は pass する (Pre-Check の機械強制は本文検査 4 段のとき先に `exit 1` する — 上記 Pre-Check 参照)。本 gate が保証するのは「本 cycle で記録経路が評価されたか」であって記録の成功ではない — 記録失敗は非ブロッキング契約 (AC-3) により mergeable 判定を変えない。`outcome=aborted` も同様に pass 扱い (helper が完走せず結末を確定できなかった異常終了)。この経路は sentinel だけでは中断の事実が読めないため、helper が signal trap から `[CONTEXT] NONBLOCKING_RECORD_FAILED=1; reason=signal_aborted; rc=...; signal=...` を併せて emit する — 転記対象はこの reason。**投稿されたか否かは不明**として扱う (POST 中の中断ではコメントが実在しうる)。

**On ERROR** (sentinel absent or stale):

```
ERROR: ステップ 8.0.3 ステップ 6.1.d Post-condition Gate failed.
No current-cycle [CONTEXT] NONBLOCKING_RECORD_DONE=1 sentinel found (absent, or iteration_id != REVIEW_CYCLE_ID).
(注: Pre-Check の pending_marker_present で落ちた場合は sentinel が実在することがある — その場合は
 「未実行」ではなく caller 契約違反による差し戻しなので、NONBLOCKING_RECORD_FAILED の reason (`body_file_empty` / `body_marker_missing` / `body_sentinel_missing` / `count_body_mismatch` のいずれか) を読むこと。`body_check_unavailable` は該当しない — 環境起因で marker を残さない。)
This means ステップ 6.1.d was NOT evaluated in the current cycle, OR the helper rejected a caller-contract
violation with exit 1 before its trap was installed (the 7 exit-1 reasons).
既定設定 post_comment: false では 6.1.d のコメントが非実測指摘の唯一の共有可能な durable 記録であり、
skip は Issue #2024 D-01 (マージ後に人間が拾い直せる状態を保つ) の無音喪失を意味する。
ACTION: まず [CONTEXT] NONBLOCKING_RECORD_FAILED=1; reason=... の有無を確認する (**本 marker は
iteration_id を持たないため、本 cycle の 6.1.d step 2 より後ろに現れた行だけを採用する**)。
reason=iteration_id_placeholder_residue のときは 6.1.a step 0 の REVIEW_CYCLE_ID emit 値まで遡って確認する
(6.1.d の再実行だけでは収束しない)。あれば当該 reason を
直してから 6.1.d step 1-2 を再実行する (同じ引数での単純再実行は placeholder residue では収束しない)。
無ければ 6.1.d が未実行なので steps 1-3 を実行し、いずれの場合も then re-enter ステップ 8.0.
⚠️ LLM MUST NOT output [review:mergeable] or [review:fix-needed:{n}] until ステップ 6.1.d has been executed for the current cycle.
```

ステップ 6.1.d step 3 (サブステップ内部の integrity check) と ステップ 8.0.3 (全体 skip の最終 fallback) は catch する failure mode が異なる (7.7 ⇄ 8.0.2 と同じ dual placement)。rationale: [references/measured-gate-record.md#dual-gate](references/measured-gate-record.md#dual-gate)

### 8.1 Output Pattern (Return Control to Caller)

Based on the ステップ 6 review results, output the corresponding machine-readable pattern:

| Condition | Output Pattern |
|-----------|---------------|
| `total_findings == 0` (blocking findings ゼロ) | `[review:mergeable]` |
| `total_findings >= 1` (blocking findings あり) | `[review:fix-needed:{total_findings}]` |

> **`total_findings` は blocking 集合の件数**であり、報告された全指摘の件数ではない。実測必須ゲート (ステップ 5.3.0.M) で non-blocking に降格された指摘と scope=nit-noted は含まれない (定義の SoT は [assessment-rules.md §5.3.3](../fix/references/assessment-rules.md))。非実測指摘が N 件報告されていても `total_findings == 0` なら `[review:mergeable]` が正しい (AC-2)。

**E2E output line suffixes**: `non_blocking_count > 0` のとき `| non-blocking: {n}` を、fact-check が実行された場合 (external claims > 0) に `| fact-check: {v}✅ {c}❌ {u}⚠️` を、それぞれ E2E output line に付与する (前者は実測必須ゲートの記録先 4 経路の 1 本であり脱落禁止)。 `{total_findings}` is the post-fact-check count (CONTRADICTED and UNVERIFIED:ソース未確認 excluded). See [E2E Output Minimization](#e2e-output-minimization) for the full format.

**⚠️ aggregate label 禁止**: ステップ 8.1 の result line および E2E output line に **「推奨 N 件」「follow-up 候補 N 件」のような件数のみの aggregate label を含めてはならない**。推奨事項は ステップ 5.4 推奨事項テーブルで各 item の classification (actionable / design_confirmation / boundary) を明示する形でのみ表示し、result line / E2E output には件数集計を出力しない。aggregate label を含めると ステップ 7.7 post-condition gate に該当する記述として block 対象になる可能性がある。完了報告での disposition 表示は caller (`/rite:iterate` ステップ 5 完了通知) の責務。

**Important**:
- **[READ-ONLY RULE]**: `Edit`/`Write` ツールでプロジェクトのソースファイルを修正してはなりません。`Bash` で working tree / index / ref を変更する git コマンド（`git checkout` / `git reset` / `git add` / `git stash` / `git restore` / `git rebase` / `git commit` / `git push` 等）も **禁止** です。許可される read-only git コマンドの完全一覧は `plugins/rite/agents/_reviewer-base.md` の `## READ-ONLY Enforcement` を single source of truth として参照してください。指摘がある場合は `[review:fix-needed:{n}]` を出力し、修正は `/rite:fix` に委譲してください
- Do **NOT** invoke `rite:fix` or `rite:ready` via the Skill tool
- Return control to the caller (`/rite:iterate`)
- The caller determines the next action based on this output pattern
- The prohibited actions defined in ステップ 5.3.7 "Prohibition of Independent Judgment After Assessment" also apply here

**When assessed as "Merge OK" but `total_findings > 0`** (blocking = CONFIRMED ∧ §5.3.0.M のアンカー検出で measured=true ∧ scope ∈ {current-pr, follow-up}):
-> Correct to `[review:fix-needed:{total_findings}]`

**⚠️ 非実測 non-blocking 指摘のみが残る場合は correct しない**: 実測必須ゲートで降格された指摘が N 件あっても `total_findings == 0` なら **Merge OK が正** であり `[review:mergeable]` を出力する (AC-2)。ここで `[review:fix-needed:0]` に override すると、`/rite:iterate` は sentinel だけで routing するため fix が起動し、fix 側は対象 0 件で完了 → 次 cycle も同じ状態 → `safety.max_review_cycles` まで空転して AC-2 が構造的に達成不能になる。降格された指摘の可視化は ステップ 5.4 の `### 実測なし指摘 (non-blocking)` section と ステップ 6.1.d の PR 記録コメントが担う。

**Example output:**
```
📜 rite レビュー結果

総合評価: マージ可
指摘: 0件

[review:mergeable]
```

### 8.2 Standalone Execution Behavior

For standalone execution, ステップ 8 is not executed. Terminate by confirming the next action with the user via `AskUserQuestion` in ステップ 6.5.
