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

> 実行入口と工程境界は [Host Runtime Contract](../../references/host-runtime-contract.md#入口と工程境界)、native Skill / Task がない場合の実行は [Host workflow operations](../../references/host-workflow-operations.md) に従う。nested 呼出しは caller の runtime 選択を引き継ぐ。

> **質問規律**: すべての質問・disposition 判断は [question_resolution](../rite-workflow/references/coding-principles.md#question_resolution-resolve-recommended-reversible-decisions-autonomously) に従う。

PR の変更を解析し、専門 reviewer を動的選定して並列レビューする。手順は下記 0–8。途中停止時は flow-state の `phase=review` から `/rite:recover` で再開する。

0. Work Memory のロード (E2E フロー時のみ)
1. 準備 (PR cycle cleanup / argument parse / PR 情報取得 / changed files)
2. レビュアー選定 (Progressive Disclosure)
3. 動的レビュアー数決定
4. 並列レビュー実行 (Generator フェーズ)
5. 結果検証と統合 (Critic フェーズ)
6. 結果出力
7. スコープ外指摘のトリアージ
8. E2E フロー継続 (出力パターン)

本コマンドはレビュー専用 (READ-ONLY): `Edit`/`Write` でソース修正禁止。`Bash` は workflow 操作と read-only な git コマンドのみ許可 (許可・禁止一覧は [`_reviewer-base.md#read-only-enforcement`](../../agents/_reviewer-base.md#read-only-enforcement) を SoT)。問題検出時は `[review:fix-needed:{n}]` を emit し修正は `/rite:fix` に委譲する。
**cycle 1 は** 呼び出し回数・context 残量に **一切関係なく** PR 全体をフルレビューする。cycle 2+ の範囲は ステップ 1.2.4 が永続 JSON から決める (差分スコープ) が、調査**範囲**の限定であって採否**基準**の緩和ではない — 基準 (4 必須自問 / Confidence / Observed Likelihood / 実測アンカー) は cycle を通じて不変。レビュアー数の恣意的削減・Verification mode への暗黙フォールバック・品質と context 効率のトレードオフは禁止 (Identity: [workflow-identity.md](../../skills/rite-workflow/references/workflow-identity.md))。再レビューもステップ 1.2.4 が決めた範囲を全レビュアー並列で同等の深さで審査する。
rationale: references/design-rationale.md#intro-cycle-identity
Hooks registration はチェックしない (`/rite:setup` の専管)。hooks 関連 WARNING は出さない。
`{plugin_root}` は [Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script-full-version) で解決する。

## Contract

**Input**: PR number (or auto-detected from current branch), flow state with `phase: review` (written by `skills/iterate/SKILL.md` review side) or `phase: phase5_review` (legacy compat)
rationale: references/design-rationale.md#contract-legacy-phase
**Output**: `[review:mergeable]` | `[review:fix-needed:{n}]`

## Prerequisites

bash 4.0+ 必須。ステップ 1.0 の統合 bash block 冒頭 (Step 0) に [bash-compat-guard.md](../../references/bash-compat-guard.md) の canonical guard を inline embed 済み。失敗時は `[CONTEXT] REVIEW_ARG_PARSE_FAILED=1; reason=bash_version_incompatible` を emit して `[review:error]` で exit する。
rationale: references/design-rationale.md#argument-parsing-notes

## E2E Output Minimization

`/rite:iterate` E2E ではステップ 4 は **full execution**、ステップ 5-7 の **人間向け出力** のみ minimize する。sub-agent 省略 / parallel 直列化 は identity 違反。
rationale: references/design-rationale.md#e2e-minimization-scope
**AskUserQuestion の扱いは 2 種を区別する**: ステップ 7 の recommendations トリアージは E2E でも処理自体の **skip 禁止**。Decision Log への可逆な記録は自動処理し、ユーザー固有・不可逆な disposition だけ質問する。ステップ 3.3 の pre-flight レビュアー構成確認は E2E で **skip 可**（詳細はステップ 3.3）。いずれの場合も `起動 reviewer {count} 名` サマリ行・省略された reviewer 表示・ステップ 4 のフルレビュー実行は省略しない。
rationale: references/design-rationale.md#e2e-askuser-split

| Phase | Standalone | E2E Flow |
|-------|-----------|----------|
| ステップ 3.3 (Confirm Reviewers) | `AskUserQuestion` で構成確認 | **`AskUserQuestion`（オプション選択）を skip**（pre-flight 確認のみ。flow-state ベース判定はステップ 3.3 参照）。`起動 reviewer {count} 名` サマリ行・省略された reviewer 表示は両経路で必須維持 |
| ステップ 4 (Sub-Agent Execution) | Full execution | **Full execution** — sub-agents MUST run in parallel for every review cycle (including verification mode). No shortcut allowed. |
| ステップ 5 (Consolidation) | Full findings table | Result pattern + summary counts only。**例外 1: ステップ 5.4 の `### レビュー範囲（cycle 2+ 差分スコープ）` section は `REVIEW_CYCLE_SCOPE == incremental` のとき E2E でも省略禁止** (cycle 2+ は E2E からしか発生しないため、ここを minimize すると「スキップした reviewer を記録する」要求が空文になる — SoT: [cycle-scope.md](references/cycle-scope.md#選抜結果の記録を-e2e-で省略しない理由))。**例外 2: ステップ 5.4 の `### 実測なし指摘 (non-blocking)` section は `non_blocking_count > 0` のとき E2E でも省略禁止** (ステップ 7 AskUserQuestion と同じ identity 制約 — 関連 Issue 記録コメントはポインタのみで全文は載せない。既定 `post_comment: false` では統合レポートも PR に載らないため、この E2E 出力が非実測指摘の全文を人間が同期的に見る経路であり、省略は「非実測指摘を破棄しない」という記録契約の喪失に直結する)。**例外 3: ステップ 5.4 の `### レビューレーン（XS/S 軽量レーン）` section は `COMPLEXITY_LANE == light` のとき E2E でも省略禁止** (軽量レーンが動機づけられた Scenario 1「XS が 1 サイクル収束して自律マージされる」は E2E ループでしか起きず、そこを minimize すると観測性の MUST が主対象シナリオでだけ空文になる — SoT: [complexity-lane.md](references/complexity-lane.md#選抜結果の記録を-e2e-で省略しない理由))。**例外 4: ステップ 5.4 の `### Guardrail 監査ログ` section は `guardrail_audit_count > 0` のとき E2E でも省略禁止** (既定 `post_comment: false` でも Category #2 の filter 判断を人間が確認できる同期経路を維持するため)。**例外 5: ステップ 5.4 の `### 総合評価` にある `**起動の直列化**` の 1 行は `SPAWN_SPREAD` が `serialized` / `undetermined` / 欠落を伴う `parallel` のとき E2E でも省略禁止** (直列化が起きるのは長時間 E2E セッションであり、そこを minimize すると本行が到達する経路が消える。既定 `post_comment: false` では統合レポートは PR にも載らないため、省略すると本行が主対象シナリオで空文になる。`serialized` / 欠落を伴う `parallel` では helper の stderr WARNING と結果 JSON のフラグが残るが、**`undetermined` では helper がフラグをキーごと書かない**ため、計測不能の**理由** (`reason=`) は揮発する stderr WARNING にしか残らない — 省略が最も高くつくのはこの条件。`reviewer_timings[]` はステップ 4.6 の timings ファイルが present のときだけ結果 JSON へ転記される)。**例外 6: ステップ 5.4 の `### 実測阻害` section は `measurement_blocked_count > 0` のとき E2E でも省略禁止** (既定 `post_comment: false` ではこの出力が実測阻害の件数・内訳を人間が見る同期経路であり、省略は無言の measured=false 降格を再導入する) |
| ステップ 6 (PR Comment) | Full comment + display | Post comment silently, output pattern only |
| ステップ 7 (Triage) | Full report + guidance | **Recommendations only** — detect scope-irrelevant recommendations (findings/recommendations containing 別 Issue / スコープ外 keywords). Decision Log 記録の推奨は可逆なので自動処理し、ユーザー固有・不可逆な disposition だけ `AskUserQuestion` で確認する。Only when `[review:mergeable]`. |

E2E output format (ステップ 6, replaces full display):

`### CI` は E2E でも常に表示する（ステップ 5.4）。

```
[review:{result}:{n}] — {total_findings} findings ({critical} CRITICAL, {high} HIGH, {medium} MEDIUM, {low_medium} LOW-MEDIUM, {low} LOW) | non-blocking: {non_blocking_count} | measurement-blocked: {measurement_blocked_count} | fact-check: {v}✅ {c}❌ {u}⚠️ | ci: {ci_state}
```

`| non-blocking: {n}` suffix は `non_blocking_count > 0` のときのみ付与する (実測必須ゲート + 帰結クラス降格の合算。0 件なら suffix ごと省略)。`| measurement-blocked: {n}` suffix は `measurement_blocked_count > 0` のときのみ付与する (`description` に `Measurement-Blocked:` を含む finding の件数。0 件なら suffix ごと省略)。`| fact-check: ...` は external claims > 0 のときのみ。`{total_findings}` は post-fact-check カウント (CONTRADICTED と UNVERIFIED:ソース未確認 除外)。Invocation 判定は次節を再利用する。

> **Reference**: Apply `push_back_when_warranted` from [AI Coding Principles](../../skills/rite-workflow/references/coding-principles.md). 問題実装に対し代替案付きで push back する。
> **Reference**: Apply `no_unnecessary_fallback` from [AI Coding Principles](../../skills/rite-workflow/references/coding-principles.md). 失敗原因を隠したり silent に scope を変える fallback を flag する。

## Invocation Context and End-to-End Flow

standalone と `/rite:iterate` ステップ 1 からの E2E の 2 経路。

| Invocation Source | Subsequent Action |
|-----------|---------------|
| End-to-end flow (invoked from `/rite:iterate` ステップ 1) | **Output pattern and return control to caller** |
| Standalone execution | Confirm the next action with `AskUserQuestion` |

同一セッションで直前に caller が native Skill または equivalent body execution（本文実行）で `rite:pr-review` を invoke していれば E2E、それ以外は standalone。E2E は `[review:mergeable]` / `[review:fix-needed:{n}]` を emit して caller に返す。

## Arguments

| Argument | Description |
|------|------|
| `[pr_number]` | PR number (省略時は現在のブランチの PR を auto-detect) |

---

## ステップ 0: Work Memory のロード (E2E フロー時のみ)


E2E 時のみ work memory から必要情報をロードする。

### 0.1 End-to-End Flow Determination

conversation context から起動元を判定する:

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

**Placeholder legend:** `{pr_number}` / `{owner}` / `{repo}` / `{owner_repo}` / `{post_comment_mode}` ほか。`{owner_repo}` は [Owner/Repo Resolution](../../references/gh-cli-patterns.md#ownerrepo-resolution-ssh-host-alias-safe) の slash 形式を literal substitute。`{variable}` は Bash の `${var}` ではなく Claude が埋める概念マーカー。
rationale: references/design-rationale.md#placeholder-legend

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
# 本 block は Step 0 (bash 4+ compat guard) 〜 Step 4 ({post_comment_mode} 決定 + [CONTEXT] emit) を
# 単一 Bash tool invocation で実行する。各 Step の責務は下記の `# --- Step N: ... ---` 見出しを参照。

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

**ステップ 1.1 への hand-off**: `{pr_number}` 抽出は **必ず `remaining_args` に対して行う**。`$ARGUMENTS` を直接参照しない。`{post_comment_mode}` は ステップ 6.1 の SoT。

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

**Input**: `$remaining_args`（ステップ 1.0）。**`$ARGUMENTS` を直接参照してはならない**。
**PR number retrieval (priority order)**: `$remaining_args` を入力源として順に解決する:

| Priority | Retrieval Method | Description |
|-------|---------|------|
| 1 | From `$remaining_args` | When explicitly specified (空でない場合) |
| 2 | **From work memory** | `$remaining_args` が空かつ work memory に "Related PR" → "番号" がある場合 |
| 3 | Search for PR on the current branch | Fallback ($remaining_args 空 + work memory なし) |

#### 1.1.1 Retrieving PR Number from Work Memory

引数省略時は先に work memory から PR 番号を取る。

**Steps:**

1. Extract the Issue number from the current branch:
 ```bash
 issue_number=$(git branch --show-current | grep -oE 'issue-[0-9]+' | grep -oE '[0-9]+')
 ```

2. If the Issue number was obtained, load work memory from local file (SoT):
 - Read `.rite/work-memory/issue-{issue_number}.md` with the Read tool
 - If absent, Read `.rite-work-memory/issue-{issue_number}.md`
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

### 1.1.5 セッション worktree 健全性の保証（multi_session 有効時 / AC-1）

ステップ 1.2 以降は **作業ツリーから PR の変更ファイルを読む**。その前に対象 PR の作業ブランチに対応する session worktree を保証する。
rationale: references/design-rationale.md#worktree-ensure-preamble
ステップ 1.1 の `headRefName` から issue 番号を抽出し、`ensure_session_worktree`（[`lib/worktree-git.sh`](../../hooks/scripts/lib/worktree-git.sh)）で検出・再構築する（`{head_ref}` は `.headRefName`）:

```bash
issue_number=$(printf '%s' "{head_ref}" | grep -oE 'issue-[0-9]+' | grep -oE '[0-9]+')
if [ -n "$issue_number" ]; then
  claim_state=$(bash {plugin_root}/hooks/issue-claim.sh check --issue "$issue_number") || exit $?
  if [ "$claim_state" != own ]; then
    bash {plugin_root}/hooks/issue-claim.sh claim --issue "$issue_number" || exit $?
  fi
  bash {plugin_root}/hooks/scripts/lib/worktree-git.sh ensure-session-worktree --issue "$issue_number" --branch "{head_ref}"
else
  # head_ref が issue ブランチでない（session worktree の対象外）→ 従来どおり単一ツリーで続行
  echo "[CONTEXT] WT_ENSURE=skip (head_ref が issue ブランチでないため worktree 対象外: {head_ref})"
fi
```

`[CONTEXT] WT_ENSURE=` の分岐は [skills/recover/SKILL.md](../recover/SKILL.md) Phase 3.1.5 の **WT_ENSURE 分岐表（SoT）** に従う（共通 case は SoT と同一。**終端の `branch_absent` / `failed` のみ caller 固有**で、recover の AskUserQuestion に対し review は `[review:error]` 停止）:

- `disabled` / `skip` → no-op、ステップ 1.2 へ（`disabled` = `multi_session.enabled: false`。従来どおり単一ツリーで動作し挙動不変）。
共通作業先契約には `entry_phase=review` / `pr_number={pr_number}` を渡す。state 不在時は実体・claim の照合後に初回記録してから厳密検証する。既存 state の不一致は上書きせず停止する。

- `already_in` → 共通作業先契約の所有権・branch・変更前検証を通し、同じ作業先で続行する。
- `reenter` / `reconstructed` → recover Phase 3.1.5 と[共通作業先契約](../../references/git-worktree-patterns.md#host-worktree-execution) に従い、marker の `path=` へ native / 検証済み代替で入場し、所有権・branch・変更前検証を通してステップ 1.2 へ。後続の全 shell・編集・検証・委譲をこの作業先に固定する。
- `residue` → AskUserQuestion（削除 `rm -rf {path}` して再実行 / 中止）。
- `branch_other_worktree` → 中止（並行セッションの可能性。`other=` のパスを表示）。
- `branch_absent` → 対象ブランチがどこにも実在しない。誤再構築しない（AC-5）。**develop 上で review を続行せず**、`[review:error]` を emit して明示停止する。
- `failed` → 再構築失敗（helper rc=1, stderr に原因 + 復旧手順）。**silent fallback せず `[review:error]` を emit して明示停止**する（review を mergeable / completed 扱いにしない / AC-4）。

> **silent fallback 禁止**: `branch_absent` / `failed` のとき develop 上で review を継続し完了扱いにしてはならない。

### 1.2 Retrieve Changes

> **Reference**: See [Review Context Optimization](./references/review-context-optimization.md) for scale determination and diff retrieval strategies.

**Scale determination:**

ステップ 1.1 の `additions` / `deletions` / `changedFiles` で Small (<= 500 行, <= 10 files) / Medium (<= 2000 行, <= 30 files) / Large を分類する。
**Diff retrieval** (`pre-tool-bash-guard.sh` が通す形のみ): Small は `gh pr diff {pr_number} -R {owner_repo}`。Medium/Large は `gh pr view {pr_number} -R {owner_repo} --json files --jq '.files[].path'`（ステップ 4.3 で per-reviewer）。統計は同 `files` JSON。per-file は `gh pr diff` + awk。
**Incremental scope**: `REVIEW_CYCLE_SCOPE == incremental` のときは `git diff {cycle_base_sha}..HEAD`（一括）/ `git diff {cycle_base_sha}..HEAD -- {target_path}`（per-file）。`gh pr diff` は起点を指定できない。


#### 1.2.3 Retrieve Changed File List

Use the `files` array retrieved in ステップ 1.1 to extract file paths.

#### 1.2.4 Review Scope Determination (cycle 1 / cycle 2+)

**full** (cycle 1) か **incremental** (cycle 2+, 差分スコープ) を決める。判定入力は ステップ 6.1.a が書く永続レビュー JSON のみ。判定は helper へ委譲する:

```bash
bash {plugin_root}/scripts/review-cycle-scope.sh --pr {pr_number}
```

> **Reference**: 設計根拠は [cycle-scope.md](references/cycle-scope.md) が SoT。`REVIEW_CYCLE_SCOPE_FALLBACK=1; reason=` の reason 語彙（`no_prev_json` / `prev_json_unreadable` / `commit_sha_missing` / `commit_sha_unreachable` / `diff_failed` / `empty_diff` / `run_pin_unresolved` / `run_pin_unreadable` / `jq_missing`）は helper docstring が SoT。**reason は分岐を変えない** — 全 reason が下表の `full` に落ち、`no_prev_json` 以外は WARNING を伴う。**helper が非ゼロ終了した / `REVIEW_CYCLE_SCOPE=` marker を観測できない場合も `full` として扱い**、`⚠️ 差分スコープのフォールバック: reason=helper_failed。フルレビューで実行します。` を出力する。

| `REVIEW_CYCLE_SCOPE` | レビュー対象 | 適用される cycle |
|---|---|---|
| `full` | PR 全体（従来どおり） | cycle 1、および fail-safe 発火時 |
| `incremental` | `{cycle_base_sha}..HEAD` の diff + 前回 blocking の解消検証 | cycle 2+ |

`incremental` のとき marker から retain する: `{cycle_base_sha}` = `base_sha=`（差分の起点。ステップ 2.2 / 4.5 が使う）、`{prev_finders}` = `prev_finders=`（前サイクルで gated scope の指摘を出した `reviewer_type` の CSV。実測なしで non-blocking に降格した指摘の出し手も含む。helper が絞り済み。ステップ 2.2 で `mandatory` 合流）、`{previous_blocking_findings}` = `prev_json=` が指すファイルの **`findings[]` と `non_blocking_findings[]` の和**のうち **`scope ∈ {current-pr, follow-up}` かつ `demotion_reason != "non_fatal"` のもの**（helper の `prev_finders` と同一母集団。非 fatal 移送分は解消検証の対象に戻さない。5.3.0.M は `nit-noted` をゲート対象外として非実測でも `findings[]` に残す一方、非実測の gated 指摘は `non_blocking_findings[]` へ *移送* するため、片方だけ読むと nit が混じり移送分が欠ける。両方読んで gated scope で絞ると、mandatory 合流した reviewer に必ず自分の検証対象が渡る）。`{prev_finders}` に統合済みの旧 type が現れたら `skills/reviewers/SKILL.md` の Legacy Reviewer Type Aliases に従い WARNING 付きで読み替える（silent skip 禁止）。

#### 1.2.4.1 Review Mode Determination (`verification_mode`)

前回レビューコメントの有無で `review_mode` を決める。
**Composition with ステップ 1.2.4**: `REVIEW_CYCLE_SCOPE == incremental` のときは `review_mode = "full"` を強制し**本サブステップ全体を skip** する。評価するのは `full` のときのみ（[cycle-scope.md](references/cycle-scope.md#既存-reviewloopverification_mode-との合成)）。`review.loop.verification_mode` を読む (default: `false`)。
`verification_mode == true` かつ前回コメントがあるときのみ `review_mode = "verification"`。それ以外は `full`。
前回コメント: 下記が非空ならあり、空なら `full`。

```bash
gh api repos/{owner}/{repo}/issues/{pr_number}/comments \
 --jq '[.[] | select(.body | contains("📜 rite レビュー結果"))] | last | .body'
```

**Additional information retrieval for verification mode:**
When `review_mode == "verification"`, extract the following from the comment retrieved above:
1. `📎 reviewed_commit: {sha}` -> `{last_reviewed_commit}`
2. Finding tables within the "全指摘事項" section -> `{previous_findings}`
3. Incremental diff via `git diff {last_reviewed_commit}..HEAD`
**Fallback:** 前回レビューコメント不在 / `📎 reviewed_commit` 不在 / `git diff {sha}..HEAD` 失敗（force-push・rebase 等）のいずれも `review_mode = "full"` へ倒す。

On fallback, output the following:
```
⚠️ 検証モードのフォールバック: {失敗理由}。フルレビューモードで実行します。
```

#### 1.2.5 Commit SHA Tracking

レビュー開始時の commit SHA を記録する。6.1.a のローカル JSON、6.1.b の PR コメント（`post_comment_mode=true`）、6.1.d の非実測記録（`post_comment_mode` 非依存）に埋め、次 cycle の verification で使う。

```bash
git rev-parse HEAD
```

Retain the obtained SHA as `{current_commit_sha}` in the conversation context.

#### 1.2.5.C CI Check Snapshot

対象 commit の CI を取得し、merge と共有する分類 helper に渡す。待機・rerun はしない。

```bash
ci_state=unknown
ci_note=""
ci_result='{"state":"unknown","checks":[],"failed":[]}'
if ci_pr=$(gh pr view {pr_number} -R {owner_repo} --json headRefOid,statusCheckRollup); then
  if ci_head=$(printf '%s' "$ci_pr" | jq -er '.headRefOid | select(type == "string" and length > 0)'); then
    if [ "$ci_head" = "{current_commit_sha}" ]; then
      if ci_classified=$(printf '%s' "$ci_pr" | bash {plugin_root}/hooks/scripts/pr-checks-classify.sh); then
        ci_result="$ci_classified"
        ci_state=$(printf '%s' "$ci_result" | jq -er '.state') || { echo "[review:error]"; exit 1; }
        [ "$ci_state" != unknown ] || ci_note="check の形式または状態を分類できません"
      else
        ci_note="CI 分類に失敗しました（直前の診断を参照）"
      fi
    else
      ci_note="PR HEAD とレビュー対象 SHA が一致しないため CI を採用しません"
    fi
  else
    ci_note="PR HEAD を取得できません"
  fi
else
  ci_note="CI 取得に失敗しました（直前の診断を参照）"
fi
[ -z "$ci_note" ] || printf 'WARNING: %s\n' "$ci_note" >&2
printf '%s' "$ci_result" | jq -c --arg sha "{current_commit_sha}" --arg note "$ci_note" '. + {commit_sha:$sha,note:$note}' || { echo "[review:error]"; exit 1; }
ci_failed=$(printf '%s' "$ci_result" | jq -r '[.failed[] | (.name // "(unnamed)") | gsub("[\u0000-\u001f\u007f-\u009f]"; " ")] | @csv') || { echo "[review:error]"; exit 1; }
printf '[CONTEXT] REVIEW_CI_STATE=%s; failed=%s\n' "$ci_state" "$ci_failed"
```

出力 JSON を `{ci_status}`、marker の state を `{ci_state}` として保持し、ステップ 4.5・4.5.1・5.4・8.1 へ渡す。CI は観測情報であり、unknown / pending / none を mergeable の保証にしない。失敗を blocking にする条件は既存の実測ゲートに従う。

#### 1.2.6 Change Intelligence Summary

> **Reference**: See [Change Intelligence](./references/change-intelligence.md) for computation methods and format.

変更統計を先に計算し、reviewer に PR の性質を渡す。

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
`{change_intelligence_summary}` を会話コンテキストに保持し ステップ 4.5 で使う。
rationale: references/design-rationale.md#change-intelligence-reuse
**Success path retained flag** (必ず explicit set): `git diff --numstat` 成功時:

- `numstat_availability = "OK"`
- `numstat_fallback_reason = ""`
rationale: references/design-rationale.md#numstat-explicit-flags

**Error handling**: If `git diff --numstat` fails (network error, timeout, missing base branch fetch, etc.):
1. **必ず stderr に WARNING を出力** (silent fallback 禁止):
 ```
 WARNING: git diff --numstat failed. Using ステップ 1.1 `files` array (additions/deletions per file) instead.
 Reason: <error message>
 Note: ステップ 1.2.7 Doc-Heavy PR detection uses only the ステップ 1.1 `files` array fields (`additions + deletions`),
 so this numstat failure does NOT affect Doc-Heavy detection accuracy. The fallback is equivalent data.
 ```
2. ステップ 1.1 の `additions`, `deletions`, `changedFiles`, `files` で summary を生成する
3. **Retained context flags**:
 - `numstat_availability = "unavailable"`
 - `numstat_fallback_reason = <error message の 1 行要約>`
 - ステップ 1.2.7 の `{doc_heavy_pr}` は ステップ 1.1 `files` 配列で完結するため判定は通常どおり実行する

#### 1.2.7 Doc-Heavy PR Detection

**Purpose**: ユーザー向け文書が主対象の PR を tech-writer の実装整合チェック対象として flag する（[internal-consistency.md](./references/internal-consistency.md)）。
rationale: references/design-rationale.md#doc-heavy-detection-notes
**Skip conditions** (いずれか → **下記 3 retained flags を explicit set** して ステップ 1.3 へ):

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
**Exclusion rule**: rite plugin 自身の `commands/**/*.md`, `skills/**/*.md`, `agents/**/*.md`, `plugins/rite/i18n/**` は分子から除外し、分母には含める。全変更が除外に該当（self-only）なら `doc_heavy_pr = false`、要約は `"rite plugin self-only (excluded)"`。

**計算例**:
- `docs/foo.md (+50)` と `commands/bar.md (+50)`（commands/ は除外）→ doc_lines=50 / total=100 → ratio 0.5 (< 0.6) → `doc_heavy_pr = false`
- `docs/foo.md (+80)` のみ → ratio 1.0 → `doc_heavy_pr = true`

**Determination**: 上記目的文に基づき `doc_heavy_pr` (boolean) を判断し、3 retained flags を explicit set する:

| Flag | 内容 |
|------|------|
| `{doc_heavy_pr}` | 判定結果 (boolean) |
| `{doc_heavy_pr_value}` | `{doc_heavy_pr}` と同値 (ステップ 5.4 表示用) |
| `{doc_heavy_pr_decision_summary}` | 判断根拠の1行要約 (例: `"doc_lines_ratio=0.72 >= 0.6"` / `"rite plugin self-only (excluded)"` / `"doc_lines_ratio=0.3 < 0.6 かつ doc_files_count_ratio=0.4 < 0.7"`) |

3 flags を会話コンテキストに保持し ステップ 2.2.1 / 5.1.3 / 5.4 で使う。全到達経路で **explicit set**。
**Mandatory `[CONTEXT]` emission for symmetry**: skip / 正常のどちらでも対称に emit する:

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

関連 Issue の「仕様詳細」「技術的決定事項」をレビュー基準としてロードする。ステップ 1.3 で Issue 番号が取れたときだけ実行する。

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

### 1.3.2 Complexity Lane Determination (XS/S 軽量レーン)

**light** (XS / S) か **full** (M / L / XL、fail-safe) を決める。判定入力は Issue の**宣言 Complexity** のみ。判定は helper へ委譲する（ステップ 1.3 で Issue 番号を特定できなかった場合は helper を呼ばず `full` として扱い、`⚠️ Complexity レーン判定のフォールバック: reason=issue_number_missing。フル装備 (M+ 相当) で実行します。` を出力する):

```bash
bash {plugin_root}/scripts/issue-complexity-lane.sh --issue {issue_number}
```

> **Reference**: 設計根拠は [complexity-lane.md](references/complexity-lane.md) が SoT。`COMPLEXITY_LANE_FALLBACK=1; reason=` の helper 側 reason 語彙（`gh_missing` / `repo_unresolved` / `issue_fetch_failed` / `complexity_absent` / `complexity_invalid`）は helper docstring が SoT。**reason は分岐を変えない** — 全 reason が下表の `full` に落ち、全 reason が WARNING を伴う。**helper が非ゼロ終了した / `COMPLEXITY_LANE=` marker を観測できない場合も `full` として扱い**、`⚠️ Complexity レーン判定のフォールバック: reason=helper_failed。フル装備 (M+ 相当) で実行します。` を出力する。
rationale: references/design-rationale.md#complexity-lane-fallback-loud

| `COMPLEXITY_LANE` | reviewer 上限 | 検証 mandate | 適用される Complexity |
|---|---|---|---|
| `light` | `complexity_max = 3` を `effective_max` 解決へ渡す（ステップ 3.2.1） | `{complexity_lane_mandate}` を注入（ステップ 4.5） | XS / S |
| `full` | 既存 `max_reviewers`（既定 6）のまま | 注入しない（空文字列、セクションごと省略） | M / L / XL、および fail-safe 全 reason |

`light` のとき marker から retain する: `{complexity}` = `complexity=`（mandate 本文へ埋め込む宣言値）。**`light` は「常に 3 名以下」を意味しない** — cap は `effective_max` 解決に参加するだけで、`mandatory` 保護と effective floor は従来どおり優先される（[reviewers/SKILL.md](../reviewers/SKILL.md) Phase 5 が SoT）。

### 1.4 Quality Checks (Optional)

Retrieve lint/build commands from `rite-config.yml`.
Retrieve `commands.lint` / `commands.build` from `rite-config.yml`. If `null`, auto-detect from project type (package.json -> Node.js, pyproject.toml -> Python, etc.).
Confirm execution with `AskUserQuestion` (run all / skip). If errors are detected, confirm whether to continue or cancel.

---

## ステップ 2: レビュアー選定 (Progressive Disclosure)

### 2.1 Load Skill Definitions

`skills/reviewers/SKILL.md` から選定メタデータを読む:

```
Read: skills/reviewers/SKILL.md
```

**Fallback on load failure:**
If the skill file (`skills/reviewers/SKILL.md`) is not found, fall back to the built-in pattern table from ステップ 2.2 for reviewer selection. Reviewer profiles always load as each named subagent's system prompt (`agents/{reviewer_type}-reviewer.md`), so no profile fallback is needed.

### 2.2 File Pattern Analysis

変更ファイルを `skills/reviewers/SKILL.md` の Available Reviewers 表（File Patterns SoT）に照合する。
**Matching input by `REVIEW_CYCLE_SCOPE`** (ステップ 1.2.4)。パターン表は cycle で変わらない — 変わるのは表に照合させる**入力ファイル一覧**だけ:

| `REVIEW_CYCLE_SCOPE` | 照合する入力ファイル一覧 |
|---|---|
| `full` | ステップ 1.2.3 の PR 全体の変更ファイル（従来どおり） |
| `incremental` | `git diff --name-only {cycle_base_sha}..HEAD` の結果（= fix diff）に差し替える |

`incremental` のとき: (1) パターンマッチ結果に `{prev_finders}` を **`selection_type: mandatory`** で合流させる（`recommended` は不可 — Phase 5 の cap が落とさないと保証するのは `mandatory` のみで、`recommended` は `max_reviewers` 超過時に落ちて「前サイクル finder は無条件に再起動」が破れる。昇格は `detected < recommended < mandatory` の高い側へのみ）。(2) ステップ 2.3 の sole-reviewer guard / ステップ 3.2 の Security Expert 条件 / ステップ 3.2.1 の cap とフロアは**すべて従来どおり適用する**。(3) 今サイクル対象外となった reviewer 名と理由を ステップ 5.4 の「レビュー範囲」section に記録する（silent な絞り込みは禁止）。**母集合は cycle 1 で選定された reviewer 集合**とし、そこから今サイクル起動しない名前を理由付きで列挙する（全 9 名を母集合にすると PR に一度も関係しない reviewer が毎サイクル並び、今サイクルの起動集合を母集合にすると差分スコープが何名減らしたかが読めない）。ステップ 3.3 の「省略された reviewer 表示」には記録しない — 同 section は出力条件が `{dropped_count} > 0`、見出しが cap 超過を理由として固定されており、パターンマッチの候補にすら上がらない差分スコープ由来の除外を表現できない。

**Pattern priority rules:**
1. `commands/**/*.md`, `skills/**/*.md`, `agents/**/*.md` -> Prompt Engineer (highest priority)
2. Other `**/*.md` -> Technical Writer
3. If matching multiple patterns, include all matching reviewers as candidates

### 2.2.1 Doc-Heavy Reviewer Override

`{doc_heavy_pr} == true` のときだけ [Doc-Heavy Reviewer Override](references/doc-heavy-reviewers.md) を読み、候補追加・保持値の設定を実行する。false は候補を変えずスキップする。どちらもステップ 2.3 へ進む。

### 2.3 Content Analysis (Supplementary Determination)

diff 内容から追加の専門領域を判定する:

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
- **Rationale**: [design-rationale.md#reviewer-selection-notes](references/design-rationale.md#reviewer-selection-notes)。
- **Note**: Code Quality が既に単独（ステップ 3.2 fallback）なら重複追加しない。non-Code-Quality が単独のときだけ発火する

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

ステップ 2 でマッチした reviewer を初期集合とする。`max_reviewers` 超過時は ステップ 3.2.1 が関連度で絞る。

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
**Note**: Security キーワードは ステップ 2.3 のリストだけを使う。
**Selection Type** は Security Expert を入れた理由。ステップ 3.3 の削除可否に使う:

| Selection Type | Meaning | Removable in ステップ 3.3 |
|---------------|---------|-------------------|
| **`mandatory`** | `mandatory: true` in config | No (backward compatible) |
| **`recommended`** | Selected via file pattern match or `recommended_for_code_changes` | Yes (with warning) |
| **`detected`** | Selected via keyword detection in ステップ 2.3 | Yes (with warning) |

**昇格 priority**: `detected < recommended < mandatory`。override は高い側へのみ。降格しない。同じ値は no-op。

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
**Note**: `mandatory: true` のときは全 PR 必須（後方互換）。`recommended_for_code_changes` は `mandatory: false` のときだけ評価する。
**4 名以上:** `skills/reviewers/SKILL.md` の分割実行を推奨する。判定対象は **cap 後の最終人数**（ステップ 3.2.1 後）。

### 3.2.1 Apply max_reviewers Cap (Cost Control)

Security / co-reviewer / sole-reviewer-guard のあと `max_reviewers` を適用する。アルゴリズムの SoT は `skills/reviewers/SKILL.md` Phase 5。本節は配線・表示・retain のみ。食い違えば Phase 5 が勝つ。
**Config read** (`rite-config.yml` `review` section):

| Setting | Default | Meaning |
|---------|---------|---------|
| `max_reviewers` | `6` | Maximum reviewers to spawn (cost cap) |

**Complexity lane bound** (ステップ 1.3.2): `COMPLEXITY_LANE == light` のときは `complexity_max = 3` を Phase 5 の `effective_max` 解決へ渡す（新 config キーは作らない — レーン判定は Issue の既存 Complexity のみ）。`full` のときは渡さず、解決は従来と完全に同一。narrowing が発生した reviewer は **ステップ 3.3 の省略表示（`{dropped_count} > 0` で必ず出す。レーン適用時は `{effective_max}` が 3 になるためそのまま正しく描画される）に加えて**、ステップ 5.4 の `### レビューレーン（XS/S 軽量レーン）` section にも記録する（5.4 側は「その除外がレーン由来である」という帰属情報を担う）。**3.3 側を抑止してはならない** — 同 section の「Silent capping is prohibited (MUST NOT)」は spawn 前の唯一の可視化であり、レーン由来かどうかで免除されない。
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

**E2E flow detection**: `/rite:iterate` 経由の E2E では本ステップの pre-flight レビュアー構成確認 `AskUserQuestion`（末尾「オプション」の選択）を skip する。判定は `skills/ready/SKILL.md` Phase 2.1 と同型の flow-state。helper 失敗時は standalone（確認を出す）に fail-safe する:
rationale: references/design-rationale.md#e2e-confirm-skip

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

standalone は `AskUserQuestion` で確認する。E2E は「オプション」選択のみ skip し、表示ブロックは両経路で出す:

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

**Summary line (AC-2)**: `起動 reviewer {count} 名: ...` はステップ 4 前に **every** path 必須。
**Omission display (AC-1)**: `省略された reviewer` は `{dropped_count} > 0` のときだけ出す。Silent capping 禁止。
`{label}` が空ならスペースごと省略する。

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

ステップ 4 開始**前**に state を snapshot する。本 snapshot + ステップ 5.0.A が mutate 検出の正。
rationale: references/design-rationale.md#state-snapshot-notes

```bash
# 4 変数は 5.0.A 引数用に context 保持。detached HEAD は DETACHED:<hash> に置換。
# rationale: references/design-rationale.md#state-snapshot-notes
ORIG_BR=$(git branch --show-current 2>/dev/null || echo "")
if [ -z "$ORIG_BR" ]; then
 ORIG_BR="DETACHED:$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
fi
ORIG_SC=$(git stash list 2>/dev/null | wc -l | tr -d ' ')
_wth_raw=$(bash {plugin_root}/hooks/scripts/lib/git-status-filtered.sh --tracked-only)
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

出力 4 値を ステップ 5.0.A へ literal substitute する。`$ORIG_BR → {orig_br}` ほか（大文字 → 小文字 placeholder）。

### 4.0.W Wiki Query Injection (Conditional)

> **Reference**: [Wiki Query](../wiki-query/SKILL.md) — `wiki-query-inject.sh` API

reviewer ロード前に Wiki の経験知を注入する。`wiki.enabled: true` かつ `wiki.auto_query: true` のときだけ。それ以外は silent skip。

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

各 reviewer の profile は `agents/{reviewer_type}-reviewer.md`。ステップ 4.3 が `rite:{reviewer_type}-reviewer` を spawn すると **system prompt** として入る。ステップ 4.5 の user prompt は per-review 入力のみ。

### 4.3 Review Execution

**⚠️ CRITICAL — Sub-Agent Invocation is MANDATORY**: `review_mode` に関わらず ステップ 4.3 **MUST** は Task で sub-agent を呼ぶ。inline / 手動 verification 禁止。
rationale: references/design-rationale.md#verification-inline-ban

- `full`: ステップ 4.5
- `verification`: 4.5.1 + 4.5 を 1 prompt に載せる

起動前に `{count} 人のレビュアーで並列レビューを実行中です。` を出す。ステップ 2 で選んだ sub-agent を並列実行する。起動確認だけでは次へ進まない。

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
2. ロード失敗は WARNING してその sub-agent を skip
3. **Extract `{shared_reviewer_principles}`** (`_reviewer-base.md` の文書先頭〜`## Input` 直前の連続範囲)。個別見出しだけ拾わない。
rationale: references/design-rationale.md#shared-principles-hybrid
 **Fallback**: 抽出失敗 / 空なら空文字列。
**並列（MUST）**: 選択した全 reviewer の初回 Task を **1 メッセージで全件 invoke** する。reviewer ごとにメッセージを分けない（失敗した Task の retry は 4.4 に従う）。各 agent に diff / 変更ファイル / `{issue_spec}` / `{shared_reviewer_principles}` を渡す。


**Error handling:**

If the following issues occur with the sub-agent approach:
- All sub-agent definition files cannot be loaded -> Display error message and terminate
- Some completion notifications fail or are missing -> Integrate only successful review results（起動確認だけでは進めない。待ち中は 4.3.1 の列挙のみ）

**See "Task Tool Sub-Agent Invocation" below for details on the sub-agent approach.**

---

### 4.3.1 Task Tool Sub-Agent Invocation

ホストに named Agent/Task が無い場合は [Host workflow operations](../../references/host-workflow-operations.md#独立-reviewer) の絶対パスと読取義務の明示による独立子を使う。これは未登録 named agent の無条件 fallback ではない。起動前に選定名簿を固定し、実際の親/子 ID・開始/終了時刻・raw 完了出力を保持する。必要な独立性または並列性を作れなければ `[review:error]`。独立子の prompt では 4.5 の placeholder 表が定義する `{shared_reviewer_principles}`（4.5 テンプレートと 4.5.1 検証テンプレートの双方の出現箇所）は inline せず、`_reviewer-base.md` の絶対パス行（読取義務付き）に置き換える。その他の placeholder（差分・仕様・CI 状態・Wiki 等）は 4.5 のまま渡す。

**⚠️ IMPORTANT — Named Subagent Invocation**: `rite:{reviewer_type}-reviewer` で **named subagent** として呼ぶ。
rationale: references/design-rationale.md#named-subagent-and-foreground
**並列:** 1 メッセージで複数 Task。各 Task:
- `description`: "セキュリティ専門家 PR レビュー" (short description)
- `subagent_type`: `rite:{reviewer_type}-reviewer` — scoped name derived from the reviewer selected in ステップ 2 (see table below)
- `model` キーを付けない。model の SoT は agent frontmatter
- `prompt`:
 - `review_mode == "full"`: ステップ 4.5 format (diff, spec, shared reviewer principles)
 - `review_mode == "verification"`: ステップ 4.5.1 verification template + ステップ 4.5 full template, concatenated in a single prompt. Include previous findings table and incremental diff (from ステップ 1.2.4.1) in addition to the standard inputs.

Task 呼び出しに background フラグを付けない（Agent tool に当該引数が無い）。結果は completion notification で回収する。
**通知待ち中に進めてよい作業**（reviewer 結果に依存しないもののみ。5.x 以降は禁止）: `REVIEW_TMP_DIR` emit と `{spawn_timings_file}` パス組み立て。
**待ち中に禁止**: 4.6 helper（回収済み reviewer 名簿が要る）/ 5.0.A / 5.1 以降。起動確認だけでは次へ進まない。全 reviewer の completion notification が揃うまで 5.1 を開始しない。未着の結果を推測・補完しない。

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

**Formula**: `subagent_type = "rite:" + reviewer_type + "-reviewer"`（`rite:` prefix 必須）。
**Legacy type fallback**: 旧 type（`api` / `frontend` / `performance` / `database` / `type-design`）は WARNING 付きで `application` に代替（silent skip 禁止。`skills/reviewers/SKILL.md` Legacy Reviewer Type Aliases）。

**Spawn 時刻（4.6 の値源）**: Task を発行する**直前**に 1 回だけ記録する。同一メッセージの全 reviewer がこの 1 値を共有する。後続の初回 wave（別メッセージで新たに起動する reviewer 群）では再実行して新しい値を取る。4.4 / 5.1.1.1 の retry では本 block を再実行せず、初回の値を保持する。通知回収でも値源は Task 発行時刻のまま。

```bash
orchestrator_spawn_at=$(date -u +%Y-%m-%dT%H:%M:%SZ) || orchestrator_spawn_at=""
if [ -n "$orchestrator_spawn_at" ]; then
  echo "[CONTEXT] ORCHESTRATOR_SPAWN_AT=$orchestrator_spawn_at" >&2
else
  echo "[CONTEXT] ORCHESTRATOR_SPAWN_AT=null; reason=date_failed" >&2
fi
```

### 4.4 Retry Logic

Retry procedure when a completion notification fails or is missing. 4.4 と 5.1.1.1 の再 spawn も completion notification で回収する。再 spawn の起動確認だけでは 5.1 を開始しない。

**Retry criteria:**

| Error Type | Retry | Action |
|-----------|--------|------|
| Timeout | Yes (up to 1 time) | Re-execute with the same prompt |
| Network error | Yes (up to 1 time) | Re-execute with the same prompt |
| Invalid output format | Yes (up to 1 time) | Re-execute with "output in the exact format" appended to the prompt |
| Skill file load failure | No | Fall back to the built-in pattern table (ステップ 2.2) for reviewer selection |
| subagent resolution failure | No | Fail immediately. Display the scoped name used (`rite:{reviewer_type}-reviewer`) and the error message. Mark the reviewer as "incomplete", retain other results, and return `[review:error]`. Do NOT silently fall back to `general-purpose` or reduce the selected roster. |

**Error type determination method:**

Determine the error type from the completion notification (failure payload or absence). Claude analyzes the notification content and determines the type by the following patterns:

| Error Type | Detection Pattern |
|-----------|-------------|
| Timeout | Response contains keywords like "timeout", "timed out", "exceeded" |
| Network error | Response contains "network", "connection", "ECONNREFUSED", "unreachable", etc. |
| Invalid output format | Does not match the above and does not contain expected output format (e.g., `### 評価:` section) |
| Skill file load failure | Read tool returned an error (occurs before Task execution) |
| subagent resolution failure | completion notification の失敗メッセージ / 欠落が `Agent type 'rite:{reviewer_type}-reviewer' not found. Available agents: ...` を含む。This indicates the named subagent is not registered in the current Claude Code installation (plugin not installed, version mismatch, or agent file moved) |

**Retry procedure:**

1. Identify the Task that encountered an error
2. Determine if the error is retryable (see table above)
3. If retryable:
 - Keep other reviewers' results intact
 - Re-execute only the failed Task (with the same or modified prompt)
 - **Do not re-run the 4.3.1 date block** — keep the first `{orchestrator_spawn_at}`
4. If the retry limit (1 time) is reached:
 - Mark the reviewer as "incomplete"
 - Retain successful results and return `[review:error]`; do not enter ステップ 5 or issue a mergeable verdict
 - Include "{reviewer_type}: レビュー失敗" and the recovery step in the error report

**Note**: Timeout / network / invalid format は質問せず 1 回だけ自動再試行する。再失敗後は incomplete として停止する。委譲不能をユーザー承認で mergeable に変換しない。

### 4.5 Review Instruction Format

各 reviewer への指示を生成する。

**Finding quality guidelines:** 曖昧な指摘禁止。Read/Grep/WebSearch で調べてから報告。確認済みの事実だけ。
**Mandatory fix policy:** **検証済み（`Verification:` アンカー。静的検証を含む repro / failing_test）**の指摘だけが blocking。検証できない指摘は報告してよいが non-blocking（ステップ 5.4）。検証実施済みならアンカー添付は必須。環境制約で検証がブロックされた場合は `Measurement-Blocked:` を添付する（無言の降格禁止）。標準フローで既存 call path を指せる問題だけ。仮説は `security` の攻撃面以外禁止。file:line を grep できないなら報告しない。
**Thoroughness on every cycle:** 初回・再レビュー・verification で同じ深さ。後出しを避けて妥当な指摘を隠さない。
**Scope judgment rule:** **本 PR の diff が導入した問題**だけを指摘にする（revert test）。既存の smell / 負債 / スタイルは findings にしない。調査が必要なら ステップ 5 の「調査推奨」。Issue 自動作成しない。

**Placeholder embedding method:**

| Placeholder | Source | Extraction Method |
|---------------|--------|----------|
| `{relevant_files}` | Changed file list from ステップ 1.2 | Extract only files matching the reviewer's Activation pattern。`REVIEW_CYCLE_SCOPE == incremental` のときは ステップ 2.2 と同じく `git diff --name-only {cycle_base_sha}..HEAD` の一覧から抽出する。**例外**: `incremental` かつ当該 reviewer が `{prev_finders}` 由来の `mandatory` 合流で、パターン一致が 0 件のときは `{cycle_base_sha}..HEAD` の**全ファイル**を渡す（空で渡すと `{diff_content}` も空になり、mandate 4 が差分外の読み直しを禁じるため mandate 1 の解消検証すら実行できない prompt になる — 解消検証は自分の指摘箇所と fix の影響範囲の両方が読めて初めて成立する） |
| `{ci_status}` / `{ci_state}` | ステップ 1.2.5.C | 対象 SHA・分類・check 名/状態/結論/詳細 URL・failed 一覧・取得不能理由を出力 JSON から渡す。CI の分類規則を再実装しない |
| `{diff_content}` | Diff from ステップ 1.2 | **Varies by scale** (see below)。`REVIEW_CYCLE_SCOPE == incremental` のときは PR 全体の diff ではなく `{cycle_base_sha}..HEAD` の diff を使う（取得コマンドは ステップ 1.2 の incremental 系。`{relevant_files}` が上記例外で全ファイルになった場合は同区間の全 diff を渡す） |
| `{cycle_scope_mandate}` | [cycle-scope.md](references/cycle-scope.md#reviewer-mandate差分スコープ適用時に注入する本文) の Reviewer mandate 節 | **Conditional extraction**: `REVIEW_CYCLE_SCOPE == incremental` のときのみ、同節の fenced block 本文を抽出し `{previous_blocking_findings}` / `{cycle_base_sha}` を埋めて注入する。`full` のときは空文字列（セクションごと省略） |
| `{complexity_lane_mandate}` | [complexity-lane.md](references/complexity-lane.md#reviewer-mandate軽量レーン適用時に注入する本文) の Reviewer mandate 節 | **Conditional extraction**: `COMPLEXITY_LANE == light`（ステップ 1.3.2）のときのみ、同節の fenced block 本文を抽出し `{complexity}` を埋めて注入する。`full` のときは空文字列（セクションごと省略 — 空見出しが残ると M+ の prompt が変化し AC-4 に違反する）。`{cycle_scope_mandate}` とは直交し、両方が非空になりうる（cycle 2+ の XS Issue）。両者が同時に届いても矛盾しない: 差分スコープは審査**範囲**を、軽量レーンは検証の**実行コスト**を絞るもので、いずれも採否基準を変えない |
| `{issue_spec}` | Issue specification obtained in ステップ 1.3.1 | Content of the "仕様詳細" section (if empty, write "仕様情報なし") |
| `{change_intelligence_summary}` | Change Intelligence Summary from ステップ 1.2.6 | One-paragraph summary of change type, file classification, and focus area |
| `{shared_reviewer_principles}` | `_reviewer-base.md` (shared) | Extract all sections from the document start to the `## Input` heading (exclusive). This covers `## READ-ONLY Enforcement`, `## Reviewer Mindset`, `## Cross-File Impact Check`, and `## Confidence Scoring` as a contiguous block. Agent-specific identity is NOT included here — it is delivered via the named subagent's system prompt (Phase B). See ステップ 4.3 step 3 for the full extraction procedure |
| `{change_summary}` | Scale information from ステップ 1.2.1 | Used only for large diffs. Change summary table |
| `{doc_heavy_pr}` | ステップ 1.2.7 result | Boolean flag (`true` / `false`). Inject only when reviewer is `tech-writer`. If `false` or reviewer != tech-writer, set to empty string |
| `{doc_heavy_mode_instructions}` | `agents/tech-writer-reviewer.md` `## Doc-Heavy PR Mode (Conditional)` section | **Conditional extraction**: Only populated when `reviewer_type == tech-writer` AND `{doc_heavy_pr} == true`. Extract the entire section from `## Doc-Heavy PR Mode (Conditional)` heading down to (but excluding) the next `##` heading. Otherwise set to empty string |
| `{wiki_context}` | ステップ 4.0.W Wiki Query result | Non-empty when Wiki is enabled and related experiential knowledge was found. Empty string when Wiki is disabled, `auto_query` is false, or no matches found. One more non-empty shape exists: when the index carries registration rows but Pass 1 extracted no candidate, the value is a single `> ⚠️ …` notice line and carries no heuristics — treat it as "no context" for review purposes and surface the notice as-is |
| `{rejected_ledger}` | 関連 Issue の 6.1.d コメント `### 却下台帳` | `nb-sweep-ledger.sh extract`。空ならセクションごと省略。同内容の指摘を blocking / non-blocking に再報告しない |

**`{rejected_ledger}` 抽出**（空ならセクション省略。取得失敗は WARNING を placeholder に載せ、空台帳として再訴訟させない）:

```bash
source {plugin_root}/hooks/scripts/lib/context-marker.sh || true
rejected_ledger=""
ledger_status=empty
existing=$(mktemp "${TMPDIR:-/tmp}/rite-rejected-src-XXXXXX") || existing=""
if [ -z "$existing" ]; then
  ledger_status=failed
  echo "WARNING: 却下台帳取得失敗 (mktemp)。空台帳として再訴訟させない" >&2
elif [ -n "{issue_number}" ] && [ "{issue_number}" != "0" ]; then
  if ! gh api "repos/{owner_repo}/issues/{issue_number}/comments" --paginate \
    --jq '.[] | select(.body | startswith("## 📜 rite 非実測指摘の記録")) | .body' \
    > "$existing"; then
    ledger_status=failed
    echo "WARNING: 却下台帳取得失敗 (gh api)。空台帳として再訴訟させない" >&2
  elif [ -s "$existing" ]; then
    if rejected_ledger=$(bash {plugin_root}/hooks/scripts/nb-sweep-ledger.sh extract --body-file "$existing"); then
      [ -n "$rejected_ledger" ] && ledger_status=ok
    else
      ledger_status=failed
      rejected_ledger=""
      echo "WARNING: 却下台帳取得失敗 (extract)。空台帳として再訴訟させない" >&2
    fi
  fi
fi
rm -f -- "$existing"
case "$ledger_status" in
  ok)
    echo "[CONTEXT] REJECTED_LEDGER=ok" >&2
    printf '%s\n' "$rejected_ledger"
    ;;
  failed)
    echo "[CONTEXT] REJECTED_LEDGER=failed" >&2
    printf '%s\n' "（台帳取得失敗 — 却下済み指摘の再訴訟の可能性）"
    ;;
  *)
    echo "[CONTEXT] REJECTED_LEDGER=empty" >&2
    ;;
esac
```

**`{diff_content}` by scale:** Small: 全 diff | Medium: `{relevant_files}` | Large: `{change_summary}` + 該当ファイル + Read 指示
**`{relevant_files}`:** Activation パターン一致（ステップ 2.2）

> **Reference**: See [review-context-optimization.md](references/review-context-optimization.md) for change summary format and retrieval guidelines.

**Review instruction template:**

テンプレート本文は [references/reviewer-prompt-generator.md](references/reviewer-prompt-generator.md)。`{placeholder}` を埋めて渡す。
**`{issue_spec}` が空:** 「仕様情報なし」と書き、仕様整合 / 仕様への疑問を省略する。

### 4.5.1 Verification Mode Review Instruction Template

`review_mode == "verification"` のときは ステップ 4.5 に **加えて**本節のテンプレートを使う。最終評価は両方を統合する。

**Template selection logic:**

| `REVIEW_CYCLE_SCOPE` (1.2.4) | review_mode (1.2.4.1) | Template Used |
|---|-------------|-------------------|
| `incremental` | (評価しない = `full` 固定) | Normal template from ステップ 4.5 のみ（`{cycle_scope_mandate}` を注入）。**本節 4.5.1 のテンプレートは注入しない** |
| `full` | **`full`** | Normal template from ステップ 4.5 only |
| `full` | **`verification`** | Both: this section's (4.5.1) verification template AND the normal template from ステップ 4.5 |

`incremental` で 4.5.1 を注入しない理由: [cycle-scope.md](references/cycle-scope.md#既存-reviewloopverification_mode-との合成)。
Verification テンプレート本文は [references/reviewer-prompt-verification.md](references/reviewer-prompt-verification.md)。

**Placeholder embedding method:**

| Placeholder | Source | Extraction Method |
|---------------|--------|----------|
| `{previous_findings_table}` | Previous review finding table obtained in ステップ 1.2.4.1 | Integrate finding tables from each reviewer in the "全指摘事項" section from the previous `📜 rite レビュー結果` comment |
| `{fix_change_map}` | 直前の fix cycle の `findings_addressed`（fix-cycle-state 最新 cycle） | `state-path-resolve.sh` 基準の `.rite/fix-cycle-state/{pr_number}.json` の最新 cycle を読む。`diff_verified: false` の ID には `❌` を付ける。ファイル不在 / `findings_addressed` 欠落 / cycles 空は **「対応表なし」** の 1 行に置換する（reviewer 起動は従来どおり続行）。**本 placeholder は 4.5.1 専用** — `REVIEW_CYCLE_SCOPE == incremental` は 4.5.1 を注入しないため展開しない |
| `{incremental_diff}` | `git diff {last_reviewed_commit}..HEAD` obtained in ステップ 1.2.4.1 | Full incremental diff (however, for large scale, only files relevant to the reviewer) |
| `{change_intelligence_summary}` | Change Intelligence Summary from ステップ 1.2.6 | One-paragraph summary of change type, file classification, and focus area |

### 4.6 Spawn Spread Check (並列起動の直列化検出、non-blocking)

全 reviewer の completion notification が揃った後に ステップ 4.3.1 の `{orchestrator_spawn_at}` から spawn spread を機械判定する。spawn 発行直後の起動確認では 4.6 helper を走らせない。並列は強制せず観測のみ。

# rationale: references/design-rationale.md#spawn-spread-threshold-notes

**手順**:

1. Write tool で `{review_tmp_dir}/rite-reviewer-timings-{pr_number}-{current_commit_sha}.json` (以降 `{spawn_timings_file}`) へ下記の形で保存する (`{review_tmp_dir}` は下記 bash の `[CONTEXT] REVIEW_TMP_DIR=` marker 値、`{current_commit_sha}` は **ステップ 1.2.5 で記録した本 cycle の commit SHA** をリテラル置換する。Write tool は TMPDIR の shell 展開ができないため)。パスは **commit ごと**に分離し、その識別子を本ステップの外から取る。`${TMPDIR}` はセッション内不変なので固定名では別 commit のファイルまで共有する一方、識別子を本ステップ自身が鋳造すると本ステップを飛ばした cycle で 5.3.0.M が同じパスを構成できない。1.2.5 の SHA は 4.6 と 5.3.0.M の双方が独立に持つため、両者が同じ規則で同じパスを組み立てられる。HEAD 不変の再入 cycle に残る識別上の制約は 5.3.0.M step 1 の **既知の残余**を SoT とする。`started_at` には 4.3.1 の `{orchestrator_spawn_at}` を書く（同一メッセージの reviewer は同じ値。4.4 retry は初回を保持）。4.3.1 欠落 / `ORCHESTRATOR_SPAWN_AT=null` は `null` — 省略も捏造もしない (欠落は「計測不能」として表面化させる):

   ```json
   {"reviewer_timings": [{"reviewer": "security-reviewer", "started_at": "2026-04-11T03:00:00Z"}, {"reviewer": "test-reviewer", "started_at": null}]}
   ```

   `reviewer` の値は `findings[].reviewer` と同じ形 (各 `reviewer_type` に `-reviewer` を付した形、`rite:` prefix なし)。**回収できた reviewer のみ**を並べる (`reviewers[]` と同じ「実回収」基準)。**MUST**: 回収した全 reviewer の初回 spawn timing を、各 reviewer につき 1 レコードずつ全件保存する。同じ時刻でも 1 レコードにまとめず、helper 実行前に `reviewers[]` と名前・件数が一致することを確認する。

   ```bash
   echo "[CONTEXT] REVIEW_TMP_DIR=${TMPDIR:-/tmp}" >&2
   ```

2. helper を実行する。閾値 (既定 120 秒)・判定・WARNING emit・判定結果の同ファイルへの書き戻しは helper が担う (SoT は helper docstring):

```bash
bash {plugin_root}/hooks/scripts/review-spawn-spread-check.sh \
  --input {spawn_timings_file}
```

| 観測 | LLM action |
|---|---|
| 出力なし (rc=0) | 並列起動が保たれている。**何もしない** (成功時は無言) |
| `[CONTEXT] SPAWN_SPREAD=serialized; spread={n}s; threshold={t}s; reviewers={r}; measured={m}` (rc=0) | 直列化を検出。WARNING は helper が emit 済のため**会話で重複させない**。ステップ 5.4 統合レポートの `### 総合評価` に `**起動の直列化**` の 1 行を追加する。`measured < reviewers` なら helper が計測不能 WARNING も併記しているので、その 1 行にも `{measured}/{reviewers} 名のみ計測` を載せる |
| `[CONTEXT] SPAWN_SPREAD=parallel; ...` (rc=0、一部欠落時のみ emit) | 測れた分は閾値内。計測不能があった事実を ステップ 5.4 の同じ 1 行に載せる |
| `[CONTEXT] SPAWN_SPREAD=undetermined; reason={r}` (rc=0) | 計測不能。**判定を skip したことにしない** — ステップ 5.4 の同じ 1 行に `計測不能（reason={r}）` として載せる。`reason=insufficient_parseable_timing` の場合は 4.3 の全 reviewer の 1 メッセージ発行と本節 step 1 の timing 全件記録を確認する（欠落時刻は捏造しない） |
| rc=2 (引数不正 / jq 不在 / 入力不正 / 書き出し失敗) | caller 契約違反または環境不備。ERROR 行に従って step 1 の JSON を作り直し **1 回だけ**再実行する。再発したら本チェックのみ skip し、`⚠️ spawn spread チェックを skip しました（{原因}）` を 1 行表示してレビュー本体を続行する |

採否・`overall_assessment` / `verdict` / merge は変わらない。ステップ 5.3.0.M step 1 は**本ファイルを Read して**転記する（記憶から再構成しない）。

---

## ステップ 5: 結果検証と統合 (Critic フェーズ)


### 5.0.A Post-Review State Verification

ステップ 4 の reviewer が READ-ONLY を守り working tree / branch / stash を mutate しなかったことを verify する。drift は WARNING。branch drift のみ `git checkout` で回復する（worktree drift は手動）。
4.0.A の 4 値をリテラル substitute する（`$ORIG_BR → {orig_br}` ほか）。

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

WARNING は stderr、JSON line は stdout。drift は **non-blocking** で ステップ 5.4 に載せる。
**Branch drift で `recovered=false`**: 後続 `/rite:fix` が誤 branch に乗らないよう AskUserQuestion で確認する。

### 5.1 Result Collection

**回収契約**: 全 reviewer の completion notification が揃うまで 5.1 を開始しない。未着の結果を推測・補完しない。

**回収完了ゲート（全ホスト必須）**: [manifest 形式](../../references/host-workflow-operations.md#回収ゲート) に従い、起動前の選定名簿と実際の回収結果を保存する。`{reviewer_completions_file}` は `REVIEW_TMP_DIR/rite-review-{session_id}-{pr_number}-{cycle_count}-{orchestrator_spawn_at}/reviewer-completions.json` の絶対パス。失敗を観測した reviewer を名簿から除去しない。

```bash
# reviewer-completion-gate
if ! bash {plugin_root}/hooks/scripts/reviewer-completion-check.sh --input "{reviewer_completions_file}"; then
  echo "[review:error]" >&2
  exit 1
fi
```

非ゼロなら flow-state / raw 結果を保持して caller の失敗経路へ戻る。ゲート pass 後のみ以下の統合を実行する。
**⚠️ Scope**: 今回新たに検出した指摘だけを集める。diff 外の修正済みは除外。未対応は再検出。
**Recommendation classification extraction**:
「### 推奨事項」の **全** item から `分類: <actionable|design_confirmation|boundary>` を抜き、`recommendation_items` として保持する:

```json
{
 "recommendation_items": [
 { "reviewer_type": "code-quality", "content": "...", "classification": "actionable", "file_line": "src/foo.ts:42" },
 { "reviewer_type": "tech-writer", "content": "...", "classification": "design_confirmation", "file_line": null },
 { "reviewer_type": "security", "content": "...", "classification": "boundary", "file_line": "src/bar.ts:10" }
 ]
}
```

**Default classification rule**: `分類:` 欠落は `design_confirmation`。`[CONTEXT] RECOMMENDATION_CLASSIFICATION_MISSING=1; reviewer={type}; default_applied=design_confirmation` を残す。
rationale: references/design-rationale.md#recommendation-classification

**Field naming convention**:

- **`recommendation_items`**: 全推奨 + classification（Source B の元）
- **`candidate_count`**: ステップ 7.1 の Source A + Source B 合算（dedup 後）。7.7 / 8.0.2 が参照

**Non-measured findings**: 本ステップでは `Verification:` / `Measurement-Blocked:` の走査・分類を **行わない**。検出は 5.3.0.M（`Verification:` のみ）と 5.4（`Measurement-Blocked:` の件数 surface）。責務は `内容` の両アンカーを**改変せず** `description` へ引き継ぐこと。5.4 / 6.1.d の情報源はゲート後 JSON の `non_blocking_findings[]`。
**Guardrail audit collection**: 各 `### 監査ログ` の `Category #2` 全行を `guardrail_audit_log` として保持する（キー: `reviewer`, `filter_category`, `original_severity`, `file_line`, `description`, `filter_reason`, `verification`。表列: 除外した内容→`description`、除外理由→`filter_reason`。列プレースホルダ `{filtered suggestion}` / `{failed condition}` は JSON キーではない）。`なし` は `[]`。直後に **`guardrail_audit_count = guardrail_audit_log.length`** を retain する（E2E 例外 4 と 5.4 の唯一の値源）。assessment / 件数 / merge には加算しない。書き込み時のキー集合検証は ステップ 6.1.a（`reason=guardrail_audit_log_keys_violation`）。
**Investigation suggestion collection**: 「### 調査推奨」を `investigation_suggestions` として保持する。findings でも Issue 候補でもない。ステップ 7 は自動 Issue 化しない。
**Demoted findings collection**: `Likelihood-Evidence:` 欠落かつ Hypothetical 例外カテゴリ外（security/devops/dependencies。`application` は `Likelihood: Hypothetical (例外カテゴリ: database migration)` 付きに限り継承）を `demoted_findings` として 5.3.0 / 5.4 用に保持する。行先は `推奨事項` または `（削除）`（LOW）。

##### 5.1.0.L Likelihood-Evidence Producer Post-Condition

Before aggregation or the 5.3.0 safety-net demotion, write each raw reviewer output unchanged to a tempfile and invoke:

```bash
bash {plugin_root}/hooks/scripts/review-likelihood-evidence-gate.sh \
  --reviewer-type "{reviewer_type}" --input "{raw_reviewer_output_file}"
```

helper は `### 指摘事項` / `### Findings` の各行を検証する。通常指摘は canonical `Likelihood-Evidence:` 必須。security / devops / dependencies は `Likelihood: Hypothetical (例外カテゴリ: ...)` 可。application は `database migration` のみ。空表は pass。

Route the result mechanically per reviewer:

| Result | Action |
|---|---|
| rc=0 + `LIKELIHOOD_EVIDENCE_GATE=passed` | Accept the raw output and continue |
| rc=1 + `reason ∈ {anchor_missing, findings_heading_missing, table_header_missing, table_malformed}`, first occurrence | Retry that reviewer once with the original review prompt plus the reason-specific diagnostic and the strict requirement to emit the canonical five-column findings table with a canonical anchor in every realistic finding's `内容` cell; replace the original output with the retry output and rerun this helper |
| rc=1 with any producer-contract reason after the one retry | Mark the reviewer `incomplete`, set `likelihood_evidence_post_condition=error`, and stop this review with `[review:error]`; do not pass the output to aggregation or 5.3.0 |
| rc=2, or a missing success marker | Treat as producer-gate infrastructure failure and stop with `[review:error]` |

`likelihood_evidence_retry_count` は per-reviewer dict、初期 `{}`。完了した retry だけ 0→1。本ゲートは仮説降格の前に走る。
rationale: references/design-rationale.md#likelihood-evidence-before-demotion

#### 5.1.1 Verification Mode Findings Collection

`review_mode == "verification"` では NOT_FIXED/PARTIAL/REGRESSION/MISSED_CRITICAL はすべて blocking。FIXED は Fix Verification Summary のみ。
**フルレビュー由来の新規指摘**: 重要度に関わらず blocking。verification を理由に非 blocking へ降格しない。

> **実測必須ゲートとの合成**: 本セクションの「blocking 扱い」は severity / verification-mode 軸での降格禁止を意味し、ステップ 5.3.0.M の実測必須ゲートは **orthogonal に後段で適用される** (初回レビューと同一基準)。すなわち NOT_FIXED / REGRESSION / 新規指摘であっても `Verification:` アンカー (実測) を伴わなければ non-blocking に分類される。前 cycle で実測付きだった finding の NOT_FIXED 検証は、前 cycle の実測 (repro / failing_test) を引き継いで添付すればよい (再実測は失敗が再現し続けている確認を兼ねるため推奨)。

##### 5.1.1.1 Post-Condition Check: Verification Result Table Presence

**Execution condition**: `review_mode == "verification"` **または** `REVIEW_CYCLE_SCOPE == incremental`。
**Skip condition**: `review_mode == "full"` かつ `REVIEW_CYCLE_SCOPE == full`。
**Purpose**: `### 修正検証結果` 欠落は前回指摘検証の silent skip になりうる。
rationale: references/design-rationale.md#verification-post-condition-notes
各 reviewer 出力を multiline で検索する:

```
(?m)^### 修正検証結果\s*$
```

**Judgment matrix** (classification vocabulary は ステップ 5.1.3 と統一: `passed` / `warning` / `error`):

| Condition | Classification | Action |
|-----------|---------------|--------|
| すべての reviewer 出力に `### 修正検証結果` heading が含まれている | `passed` | `verification_post_condition: passed` を set、そのまま ステップ 5.1.2 へ |
| 1 人以上の reviewer 出力に `### 修正検証結果` heading が欠落（初回検出） | `warning` | `verification_post_condition: warning` を set、下記 Retry Procedure を実行 |
| retry 実行後も欠落（2 回目以降の検出） | `error` | `verification_post_condition: error` を set、下記 Failure Procedure を実行 |

**Retry counter**: `verification_post_condition_retry_count` は per-reviewer dict。各 reviewer は 0→1 を最大 1 回。
**Retry Procedure** (`warning`、該当 reviewer ごと最大 1 回)。ステップ 4.3.1 で verification テンプレートを再送する。再 spawn も completion notification で回収する。再 spawn の起動確認だけでは判定を再開しない:

- `subagent_type`: `rite:{reviewer_type}-reviewer` (ステップ 4.3.1 の mapping table を参照。Phase B 以降、reviewer は named subagent として呼び出される)
- `prompt` 内容: ステップ 4.5.1 verification テンプレート + ステップ 4.5 full テンプレート（元レビューと同じ 2 テンプレート concat）に、以下の strict 要件を追加:
 - 「`### 修正検証結果` heading と判定テーブル (`| # | 重要度 | ファイル:行 | 内容 | 判定 | 備考 |`) を **必ず**出力すること」
 - 「ステップ 4.5.1 verification テンプレートの Part 1 (前回指摘の修正検証) を skip せずに実行すること」
- 入力データ (`{previous_findings_table}` / `{fix_change_map}` / `{incremental_diff}` / `{change_intelligence_summary}`): ステップ 1.2.4.1 / 4.5.1 で取得済みのものを再供給
- **結果 merge 戦略**: retry 結果は元 reviewer の output を **置き換える** (append ではない)。元 output は破棄し、retry output のみを ステップ 5.1 結果集合に使用する
 - **Note**: retry prompt は full + verification 両 template を concat して再送している (上記 `prompt` 内容参照) ため、retry output は元 output の全指摘 (verification mode 由来 + full mode 由来) を**包含する**。元 output 内の非 verification finding が retry 置き換えで消失することはない。
- retry 実行後、`verification_post_condition_retry_count[{reviewer_type}]` を +1 し、もう一度判定条件を評価する。retry 後も欠落していれば `error` に昇格する

**ステップ 4.4 retry classification との関係** (Phase B で明示化):
この ステップ 5.1.1.1 retry 中に ステップ 4.4 の `subagent resolution failure` (`Agent type 'rite:{reviewer_type}-reviewer' not found`) が発生した場合、以下の順序で処理する:

1. **ステップ 5.1.1.1 retry counter の扱い**:
 - Task tool 経由の retry call は実行される (resolution failure は call 後に検出されるため)。しかし ステップ 4.4 の `Retry: No` 規則に従い、この call は `successful retry` としてカウントしない
 - `verification_post_condition_retry_count[{reviewer_type}]` は increment **しない** (counter は 0 のまま保持される)
 - 「次 cycle で再 retry されないこと」は counter / flag の pre-condition guard ではなく、**Step 3 で `verification_post_condition: error` を set することによって Judgment Matrix 行 3 (`error` 分類) に遷移し、Retry Procedure ではなく Failure Procedure に分岐させる flow 分岐によって保証される**。つまり terminal state は retry counter の数値ではなく、classification 状態 (`error`) によって実現される
2. **ステップ 4.4 default action への委譲**: reviewer を incomplete として記録し、成功済みの raw 結果と flow-state を保持して `[review:error]` を返す。人数を減らした統合や承認による mergeable 判定には進まない。

retry の回収結果で manifest を更新し、ステップ 5.1 の回収完了ゲートを再実行する。新しい実子 ID と raw 出力を記録し、初回 spawn 時刻は既存 spread 計測用に保持する。

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

**Owner**: ステップ 5.1 完了直後。**Condition**: 常に実行（state file 不在は skip）。accepted finding の再出現は JSON から消し Markdown に残す。
rationale: references/design-rationale.md#fingerprint-asymmetric-output

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
独立した Step 3 bash block は無い。

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

**JSON 生成への接続**: **5.3.0.M step 1** で `suppressed_findings` を `findings[]` から **除外**する。**6.1.a では適用しない**。Markdown（5.4）は和集合。
**Revocability**: `accepted-fingerprints-{pr_number}.txt` を消せば次 cycle で解除。
**Retained flag namespace** (ステップ 5.1.2.A 独立):

| Flag | Description |
|------|-------------|
| `ACCEPTED_FINGERPRINTS_LOADED=1; pr=N; count=M` | state file 読込成功 (suppression 対象 M 件) |
| `ACCEPTED_FINGERPRINTS_LOADED=0; pr=N; reason=...` | state file 不在 / pr_number 不正 (suppression skip、通常 review) |
| `FINDING_SUPPRESSED_BY_ACCEPT=1; finding_id=F-NN; original_severity=...; fingerprint=...` | 個別 finding suppression marker (per finding emit; audit log + observability) |

**ステップ 5.1.2.A failure reasons** (reason table drift prevention — `ACCEPTED_FINGERPRINTS_LOADED=0` / `FINGERPRINT_COMPUTE_FAILED` flag の reason 値):

| reason | Description |
|--------|-------------|
| `no_state_file` | `.rite/state/accepted-fingerprints-{pr}.txt` が不在 (初回 review / accept 未実施)。`ACCEPTED_FINGERPRINTS_LOADED=0` で suppression を skip し通常 review を継続 (非ブロッキング) |
| `sha1_helper_missing` | sha1sum / shasum のいずれも環境に存在せず fingerprint 計算不可 (`FINGERPRINT_COMPUTE_FAILED` flag、極稀、CI 環境異常)。当該 finding の suppression 判定を skip して通常 finding として扱う |

> **Note**: `FINGERPRINT_COMPUTE_FAILED` flag のもう 1 つの reason `pr_number_placeholder_residue` (ステップ 5.1.2.A Step 2 で `pr_number` が数値以外のとき emit) は ステップ 6 の reason 表で文書化済みのため本表には再掲しない。

#### 5.1.3 Doc-Heavy PR Mode Post-Condition Check

`{doc_heavy_pr} == true` かつ tech-writer が reviewer 集合にいる場合だけ [Doc-Heavy 検証手順](references/doc-heavy-validation.md) を読み、検証結果と retained flags を確定する。それ以外はスキップし、ステップ 5.2 へ進む。

### 5.2 Cross-Validation

**Same file/line**: `file:line` で束ね、2+ reviewer なら High Confidence + severity 昇格。
**Contradiction detection**: 同じ `file:line` で両立できない評価、**or the same root cause is assigned both `current-pr` and `follow-up` scope** → debate（有効時）または `AskUserQuestion`。
**Quality Signal 3**: 同じ `file:line` の矛盾評価。5.2.1 の帰結で発火する:

- 検討の結果、合意に至った矛盾 → Signal 3 は**発火しない**（consensus reached）
- 決着せずエスカレーションする矛盾（`debate.enabled: false` で未解決のまま残る場合を含む）→ **Signal 3 発火** — `[CONTEXT] QUALITY_SIGNAL=3_cross_validation_disagreement; file={file}:{line}; reviewers={A,B}; severity_gap={N}` を stderr に出す。orchestrator が共有 escalation `AskUserQuestion` を出す（本 PR 内で再試行 / 別 Issue として切り出す / PR を取り下げる / 手動レビューへエスカレーション; [finding-cycling.md §3](./references/finding-cycling.md)）

**Emit site**: エスカレーションを決めた同じ turn の bash block で emit する:

```bash
echo "[CONTEXT] QUALITY_SIGNAL=3_cross_validation_disagreement; file=${file_line}; reviewers=${reviewer_a},${reviewer_b}; severity_gap=${gap}" >&2
```

**Steps:**

1. If there are multiple findings for the same `file:line`, compare the assessment content
2. If matching the contradiction patterns above, flag as a contradiction
3. Collect all detected contradictions for ステップ 5.2.1 (debate) or direct user resolution
4. Scope split は severity の高い側・多数派へ機械統合しない。debate は論点整理と推奨 disposition の生成に使うが、consensus の有無にかかわらず treatment の最終決定は AskUserQuestion でユーザーへエスカレートし、選択した disposition を Decision Log に記録する。`follow-up` を選ぶ場合は durable な follow-up Issue / destination が作成または指定されるまで解決済みにしない

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

上から順に評価し、最初に一致した条件を overall assessment とする。
**Execution order** (mechanical, top to bottom):
1. **5.3.0 Observed Likelihood Gate** — `Likelihood-Evidence:` 欠落を機械降格。`推奨事項` へ移した分は `total_findings` に数えない。LOW × Hypothetical は削除。5.4 の降格結果 section に記録。
2. **5.3.0.M 実測必須ゲート** — **`scripts/review-measured-gate.sh` を実行する**。分類は helper。Claude は判定しない。SoT: [severity-levels.md §実測必須ゲート](../../references/severity-levels.md#実測必須ゲート-measured-confirmed-gate) / [assessment-rules.md §5.3.0.M](../fix/references/assessment-rules.md)。
3. **5.3.0.C 帰結クラス降格政策** — 分類 map の Write と `scripts/review-class-demotion-gate.sh`。`blocking=0` なら本ゲート全体を skip。A=0 で exclusion なし B を降格し、exclusion 付き B は blocking 維持。SoT: [severity-levels.md §帰結クラス軸](../../references/severity-levels.md#帰結クラス軸-consequence-class) / [assessment-rules.md §5.3.0.C](../fix/references/assessment-rules.md)。
4. **5.3.1-5.3.7** を降格後の `全指摘事項` に適用。件数は marker とゲート後 JSON から読む（再分類しない）。
5.3.0 / 5.3.0.M / 5.3.0.C を 5.3.1 の前に飛ばすことは **禁止**。
rationale: references/design-rationale.md#5.3-execution-order-why

#### Number-reference `--diff` (every cycle)

5.3.0.M step 1 の `findings[]` へ載せる機械レール。毎 cycle 実行。incremental / light でも skip しない。
`<base>` は lint Phase 2.2 と同じ origin-first（`origin/{base_branch}` → `{base_branch}`）。`--target` も `A...HEAD` も渡さない。

```bash
if git rev-parse --verify "origin/{base_branch}^{commit}" >/dev/null 2>&1; then
  number_ref_base="origin/{base_branch}"
else
  number_ref_base="{base_branch}"
fi
# findings は stdout。捕捉すると Bash tool 結果から消え rc=1 腕が空振りする。
bash {plugin_root}/hooks/scripts/number-reference-check.sh --diff "$number_ref_base"
number_ref_rc=$?
case "$number_ref_rc" in
  0) ;;
  1) ;; # stdout の各 file:line: matched line を 5.3.0.M step 1 の findings[] へ append
  *)
    echo "ERROR: number-reference-check.sh --diff failed rc=$number_ref_rc" >&2
    echo "[review:error]"
    exit 1
    ;;
esac
```

| rc | Action |
|----|--------|
| 0 | 指摘なし |
| 2 / その他 | 指摘を作らず `[review:error]` で停止 |
| 1 | stdout の各 `file:line: matched line` を 5.3.0.M step 1 の `findings[]` へ append |

rc=1 の finding（`findings[].verification` は書かない）:
- `reviewer: "pr-review"`（orchestrator。agents/ は追加しない）
- `severity: HIGH` / `scope: current-pr` / `category: number_reference`
- `description` は `Verification:` で始める（Number-reference finding は先頭アンカー例外。一般 reviewer の Placement へ合わせて説明文をアンカー前へ戻さない）。同一セグメント。LHS 非空。`=>` は 1 つ。marker と `=>` の間に句点・改行を入れない。`{matched line}` に生のパイプが含まれる場合は `¦` に置換する。説明文はアンカーの後:
  `Verification: repro bash {plugin_root}/hooks/scripts/number-reference-check.sh --diff $number_ref_base => exit 1; {file}:{line}: {matched line}。永続成果物に Issue/PR 番号が追加されている。番号を消し、残す背景があれば現在形の制約文で書く`

ゲート後も `findings[]` に残す（`non_blocking_findings[]` へ送らない）。5.3.0.C では `category == "number_reference"` を class A 固定とする（exclusion なし class B に倒さない）。

#### 5.3.0.M 実測必須ゲート実行手順 (helper 委譲)

# rationale: references/design-rationale.md#measured-gate-helper-notes

この step 1→step 2 とステップ 6.1.a は **full / incremental を問わない単一の連続レール**である。
incremental cycle でも途中から JSON を直接 Write して保存へ進んではならず、step 2 が JSON 本体へ
`measured_gate` receipt を書いた後にだけ 6.1.a を実行できる。receipt 欠落は保存 helper、8.0.4、
`/rite:fix` の各独立境界で hard error になる。

**step 1: レビュー結果 JSON の生成 (本 review cycle で唯一の JSON authoring site)**
[review-result-schema.md](../../references/review-result-schema.md) に従う JSON を **Write tool で `{review_tmp_dir}/rite-review-result-{pr_number}.json` に保存**する。`{review_tmp_dir}` は `[CONTEXT] REVIEW_TMP_DIR=` をリテラル置換する。
rationale: references/design-rationale.md#json-single-authoring-site

```bash
echo "[CONTEXT] REVIEW_TMP_DIR=${TMPDIR:-/tmp}" >&2
# ステップ 4.6 が本 cycle で走ったかを機械判定する。パスの識別子は 4.6 の外 (ステップ 1.2.5)
# から来るため、4.6 を飛ばした cycle でも「本 cycle のパス」を構成できる。無言で 3 キーを
# 省略すると、結果 JSON 上で「4.6 が飛んだ」「本変更以前に保存された 1.1.0 JSON」「計測不能」
# が区別できなくなる。
# **既知の残余**: 識別子は cycle ではなく commit の粒度なので、HEAD 不変で再入する cycle
# (`/rite:fix` の accept-only 経路が push なしで `[fix:pushed]` を返し re-review を発火させる
# 正規経路) では前 cycle のファイルが同一パスに残り、4.6 を飛ばしても `present` が立つ。
# 本残余は緩和されない。下の marker は解決先パスを開示するだけで、健全 cycle と stale cycle
# でバイト単位に同一となるため stale 判定には使えない。
# {spawn_timings_file} は 4.6 step 1 と**同一の規則**で組む
# ({review_tmp_dir}/rite-reviewer-timings-{pr_number}-{current_commit_sha}.json)。
if [ -e "{spawn_timings_file}" ]; then
  echo "[CONTEXT] SPAWN_TIMINGS=present; file={spawn_timings_file}" >&2
else
  echo "WARNING: ステップ 4.6 の spawn spread 計測が本 cycle で実行されていません (timings ファイル不在)。reviewer_timings 等の 3 キーは省略されます" >&2
  echo "[CONTEXT] SPAWN_TIMINGS=not_run" >&2
fi
```

生成規約 (**ステップ 6.1.a / 6.1.b は本ファイルを読むだけで再生成しない** — 生成箇所を 2 つ以上に分けると、ゲート適用後のローカル JSON が `mergeable` なのに PR コメントの Raw JSON は `fix-needed` という乖離が出る):

- `findings[]` = **post-5.3.0 の `全指摘事項`** (5.3.0 の Observed Likelihood Gate で `推奨事項` へ降格・削除した finding は含めない)。`scope == "nit-noted"` の finding も含める (本ゲートの対象外として helper が findings[] に残す)
- `non_blocking_findings[]` = `[]` (本ゲート適用前は常に空。helper が移送先として使う)
- `guardrail_audit_log[]` = ステップ 5.1 で収集した Category #2 audit rows (0 件でも `[]`)。ゲート helper は本配列を変更しない

`guardrail_audit_log[]` は canonical write の必須トップレベル field とし、`/rite:fix` は無視する additive audit data とする。cleanup は配列が非空の結果 JSON を archive してマージ後も保持する。
- `overall_assessment` = 暫定値でよい。**helper が blocking 件数から両方向で確定する**ため Claude の値は判定に影響しない
- **`verdict` は書かない** — merge ゲートが読む必須キーだが、書き手は step 2 の `review-measured-gate.sh` **のみ**で、`overall_assessment` と同一の blocking 件数式から**無条件に代入される**（step 1 で書いた値は必ず捨てられる）。step 1 時点では移送後の blocking 件数が未確定なので、書けば必ず推測値になる（`overall_assessment` を「暫定値でよい」としているのと同じ理由）。`findings[].verification` とは違い preset を尊重する経路が無いため、`--reject-preset-verification` のような強制フラグも持たない
- **`reviewers[]` = 本 cycle で ステップ 5.1 が Task 結果を回収できた reviewer の名簿**（非空・重複なし）。値は各 `reviewer_type` に `-reviewer` を付した形で書く（例: `security` → `security-reviewer`。`plugins/rite/agents/*-reviewer.md` の basename と一致させる。`rite:` prefix は付けない、日本語表示名や suffix なし slug も書かない）。**判定基準は「回収できたか」**で、ステップ 5.1 の回収完了ゲートにより本 cycle の選定名簿と一致する。未回収者がいれば本ステップには到達せず `[review:error]` で停止する。名簿の水増しや失敗者の除去は禁止。**`findings[]` から導出してもならない** — マージ直前の最終 cycle は findings 0 件が正常形で、そこから導出すると名簿が空になり sole-reviewer guard の証拠が構造的に消える。ゲート helper は本キーに触れないため、ここで書かなければ欠落のまま保存へ回り `review-result-save.sh` が `schema_required_fields_missing` で拒否する。契約の SoT は [review-result-schema.md §verdict と reviewers](../../references/review-result-schema.md#verdict-と-reviewers)
- **`findings[].verification` は書かない** — 本フィールドは helper が `description` のアンカーから算出する唯一の書き手である。Claude が先に書くと helper は既存値を正として尊重し (§4.5)、アンカー検出を経ない値がそのまま blocking 判定に入る (= 本ゲートが閉じたはずの裁量が復活する)。**step 2 の `--reject-preset-verification` による強制は部分的**で、本規約の完全な履行は依然として Claude 側の忠実性に依存する (何が弾かれ何が素通りするかの詳細は helper docstring §Why --reject-preset-verification を SoT として参照)
- **アンカーの直前の境界を保つ** — `内容` 列を `description` へ転記するとき、`Verification:` / `Likelihood-Evidence:` / `Measurement-Blocked:` 直前の行頭・`<br>`・空白を保つ。`Verification: repro <cmd> => <観測>` または `Verification: failing_test <path> => <失敗出力>` と書き、raw pipe は `¦` で代替表記する。形式崩れで実測判定不能なら `reason=anchor_undetermined` で JSON を変更せず失敗し、step 3 で該当 reviewer 出力を再生成する。
- `timestamp` は literal sentinel `"__RITE_TS_PLACEHOLDER_7f3a9b2c__"` (実値は ステップ 6.1.a の helper が注入する)
- `suppressed_findings` 除外契約 (ステップ 5.1.2.A) を本 JSON 生成時に適用する — `findings[]` から除外し、Markdown 側 (ステップ 5.4 / 6.1.b) には audit log として残す
- **`findings[].scope` を必ず明示する** (`current-pr` / `follow-up` / `nit-noted`)。scope は本ゲートの blocking 判定の入力そのもので、**値が外れてもキーが欠落しても `reason=scope_enum_violation` で hard fail し、JSON も書き換えられない**（フラグ有無に依らず発火）。未知 / 欠落 scope が blocking 集合からも移送対象からも同時に外れ、mergeable を無音で確定させるのを防ぐため
- **`findings[].pre_existing` は書かない** — canonical `schema_version: "1.1.0"` 内の additive optional field であり、現行 write path は reviewer の revert test 結果を収集しない。欠落時も read 側は default mapping を適用せず、Cross-field invariant #5 は発火しない
- **`reviewer_timings[]` / `reviewer_spawn_serialized` / `reviewer_spawn_spread_seconds`** = ステップ 4.6 の `{spawn_timings_file}` を **Read tool で読んで転記する**（会話コンテキストの記憶から再構成しない — 記憶と実測がずれると、直列化の記録が実際の計測と別のことを主張する）。`reviewer_timings[]` は同ファイルの値をそのまま写す。後 2 者は**同ファイルに存在するときだけ**書き、計測不能で helper が書かなかった場合は**キーごと省略する**（欠落 = 計測不能）。上記 bash が `SPAWN_TIMINGS=not_run` を emit した場合は 3 者とも省略する（捏造しない。無言ではなく同 bash の WARNING で表面化済み）。ゲート helper は本キー群に触れず、`review-result-save.sh` も必須フィールドとして要求しないため、欠落しても保存・merge 判定は変わらない
- 必須フィールドと各 finding のフィールド定義は ステップ 6.1.a の「Required JSON fields」節を参照する (定義の重複を避けるため本節では再掲しない)

**step 2: ゲート適用**

```bash
# ステップ 5.3.0.M: 実測必須ゲート — scripts/review-measured-gate.sh へ委譲済。
# helper 契約: 2 段アンカー判定 / measured=false かつ scope ∈ {current-pr, follow-up} の
# non_blocking_findings[] への append 移送 / blocking 件数からの overall_assessment 両方向確定 /
# 冪等 / 失敗は非ゼロ終了。SoT は helper docstring。
# --reject-preset-verification: step 1 の「verification は書かない」規約を機械的に強制する
# (散文の指示だけでは、複数 cycle にわたり LLM が verification を再生成した実測がある)。
# 本フラグは caller 契約違反だけを弾き、素の再実行 (recover 等) の冪等性は変えない。
bash {plugin_root}/scripts/review-measured-gate.sh \
  --input {review_tmp_dir}/rite-review-result-{pr_number}.json \
  --reject-preset-verification
_gate_rc=$?

# save-pending marker 設置。rationale: references/measured-gate-record.md#save-pending-marker
# 非ゼロ終了時は marker を張らない（orphan 防止）。
if [ "$_gate_rc" -eq 0 ]; then
  # rationale: references/design-rationale.md#save-pending-id-path-notes
  save_pending_id="{pr_number}-$(date +%s)"
  save_pending_marker="${TMPDIR:-/tmp}/rite-p61a-pending-${save_pending_id}"
  # rationale: references/design-rationale.md#noclobber-pending-marker-notes
  if [ -e "$save_pending_marker" ] || [ -L "$save_pending_marker" ]; then
    echo "WARNING: save-pending marker path に既存エントリがあります ($save_pending_marker)。作成せず ステップ 8.0.4 を degraded に倒します" >&2
    echo "  原因候補: 同一秒の並行 review / 共有 TMPDIR での先置き (squat)" >&2
    echo "[CONTEXT] REVIEW_SAVE_PENDING_ID=" >&2
    echo "[CONTEXT] REVIEW_SAVE_PENDING_MARKER=" >&2
  elif ( set -C; : > "$save_pending_marker" ) 2>/dev/null; then
    echo "[CONTEXT] REVIEW_SAVE_PENDING_ID=$save_pending_id" >&2
    echo "[CONTEXT] REVIEW_SAVE_PENDING_MARKER=$save_pending_marker" >&2
  else
    echo "WARNING: save-pending marker を作成できませんでした ($save_pending_marker)。ステップ 8.0.4 の機械強制は skip され Check の prose 判定のみになります" >&2
    echo "[CONTEXT] REVIEW_SAVE_PENDING_ID=" >&2
    echo "[CONTEXT] REVIEW_SAVE_PENDING_MARKER=" >&2
  fi
fi

# helper の rc を本 block の終了コードとして再送出する。**必須** — 落とすと直前の `if`/`fi` の
# rc=0 が block 全体の終了コードになり、step 3 が「rc が最終的な権威」として使う helper の
# 非ゼロ終了が観測不能になる (MEASURED_GATE_FAILED の routing が丸ごと死ぬ)。
exit "$_gate_rc"
```

**step 3: marker の読み取りと routing**

**評価規則**: 下表は**上から順に評価し、最初に一致した行のみを採用する**。`MEASURED_GATE_FAILED` は helper の非ゼロ終了と対であり、成功時の `MEASURED_GATE=applied` と同一 run に並ぶことはない。**helper の終了コードが非ゼロなら `MEASURED_GATE=applied` を観測しても無視する** (marker は helper の stderr に自由記述と同居するチャネルであり、rc が最終的な権威)。

| 観測 | LLM action |
|---|---|
| `[CONTEXT] MEASURED_GATE_FAILED=1; reason=verification_preset_by_caller` / `scope_enum_violation` / `anchor_undetermined` (helper 非ゼロ終了) | **同 cycle 内で契約違反を修復する。** preset は step 1 の JSON を作り直す。scope 違反または `anchor_undetermined` は診断の対象 finding IDs のみ **Reviewer reject + reroll** とし、当該 reviewer に再生成させる。他 finding は保持する。アンカーは `Verification: repro <cmd> => <観測>` または `Verification: failing_test <path> => <失敗出力>`、raw pipe は `¦` と案内する。回収後に step 1 の JSON を作り直し step 2 を再実行する。`measured_gate_retry_count` が `1` なら `[review:error]` で停止する。`/rite:fix` に形式修正を渡さず、review cycle を増やさない |
| `[CONTEXT] MEASURED_GATE_FAILED=1; reason=...` (上記 3 種以外。`jq_missing` / `input_missing` / `input_unreadable` / `json_invalid` / `findings_not_array` / `non_blocking_not_array` / `jq_transform_failed` / `stats_read_failed` / `mktemp_failure` / `write_failure` / `mv_failure` / `signal_aborted`) | **`[review:error]` を stdout に出力して停止する。LLM 分類へ fallback してはならない** — fallback は本ゲートが閉じた不発の再生産になる。helper が ERROR 行の直後に外部コマンドの stderr 先頭 5 行を転記するので、原因はそこを見る |
| marker が一切出ずに helper が非ゼロ終了した (exit 2 = 引数欠落 / 未知フラグ) | 同上 — `[review:error]` を stdout に出力して停止する |
| `[CONTEXT] MEASURED_GATE=applied; blocking={n}; demoted={d}; non_blocking_total={t}; assessment={a}` (helper rc=0) | ゲート適用成功。`total_findings = {n}`、`non_blocking_count = {t}`、`overall_assessment = {a}` として 5.3.1 以降へ進む (**再分類しない**)。下記 2 種の観測 marker が併記されていても分類は変えず、会話コンテキストに残して続行する |

`anchor_undetermined` の診断は `[CONTEXT] MEASURED_GATE_FAILED=1; reason=anchor_undetermined; count=N; findings=F-xx,...`。これは**失敗時のみ**の marker で、対象 ID は入力順。1 件でも該当すれば元 JSON を byte-identical に保持して非ゼロ終了する。`verification` 欠落のまま成功・保存・fix-needed へ進めない。

成功時に併記されうる観測 marker (いずれも WARNING と対。**分類を変えず、続行を妨げない**。ステップ 6 Retained flag mapping 登録済):

- `[CONTEXT] MEASURED_DEMOTED_ON_ANCHOR=1; count={n}; cause=anchor_unparseable` — `Verification:` marker はあるが第 3 の述語が偽の gate 対象 finding (marker から `=>` までの間に改行 / `<br>` / 句点が挟まる / marker から `=>` までが判別子の上限を超える)。**silent 降格の唯一の検出層**。**helper は本 marker では停止しない**。このうち実際に降格した finding は `non_blocking_findings[]` へ移送され (既存 `measured=true` 保持分は降格せず `findings[]` に残る)、ステップ 5.4 の `### 実測なし指摘 (non-blocking)` section (E2E でも省略禁止) と ステップ 6.1.d の関連 Issue 記録コメントに載るため、人間への到達は既存経路で担保される
- `[CONTEXT] MEASURED_RUNTIME_OBS_WITHOUT_ANCHOR=1; count={n}` — `runtime_observation` を主張しながら正規形の実測アンカーを欠く reviewer 契約違反。成功時は `measured=false` への降格または既存 boolean の保持となる。判定不能なら観測 marker だけで続行せず `anchor_undetermined` の失敗 routing に従う。

> `MEASURED_UNDETERMINED_ON_ANCHOR` は出力しない。判定不能は失敗 reason、形式崩れでも実測なしと算出できる finding は成功時の `MEASURED_DEMOTED_ON_ANCHOR` で可視化する。


**`measured_gate_retry_count`** (retained flag、conversation context に保持): int、初期値 `0`。step 2 再実行の直前に +1 する。上記 3 reason で共通の上限を使い、本 step 全体で再試行は **1 回まで**。再発したら `[review:error]` で停止する。
`findings[]` が元から空の場合、helper は移送 0 件・`assessment=mergeable` を返す (現行動作維持)。

#### 5.3.0.C 帰結クラス降格政策実行手順 (helper 委譲)

5.3.0.M の**後**・5.3.1 の**前**。実測付き blocking を class A / class B に分け、**A=0 のとき exclusion なしの B を non-blocking へ降格**する。exclusion 付き B（既存記述の削除/弱体化）は class B のまま blocking を維持する。gated finding の `verification.measured` が boolean でない場合は、分類と JSON 書き換えの前に `measured_undetermined` で停止する。SoT: [assessment-rules.md §5.3.0.C](../fix/references/assessment-rules.md) / [severity-levels.md §帰結クラス軸](../../references/severity-levels.md#帰結クラス軸-consequence-class)。
rationale: references/design-rationale.md#class-demotion-policy

**skip 条件**: 5.3.0.M step 3 で観測した `[CONTEXT] MEASURED_GATE=applied; blocking={n}; ...` の `{n}` が `0` なら、本ステップ全体 (step 1-3) をスキップして 5.3.1 以降へ進む (assessment は既に mergeable。分類判定も helper 実行も行わない)。

**step 1: 分類判定 (classification map の生成、本ステップで唯一の LLM 判定)**

ゲート適用後 JSON (`{review_tmp_dir}/rite-review-result-{pr_number}.json`) を Read tool で読み、`findings[]` のうち `scope ∈ {current-pr, follow-up}` の各 finding について次の判定質問に答える:

> この指摘を放置してマージしたとき、今回の成果物の**どの操作で何が壊れるか**を実行時シナリオ 1 行で書けるか。

- **書ける** → `class: "A"`。`scenario` にその実行時シナリオ 1 行を書く
- **書けない** (帰結がテスト assert の錨付け精度・コメント文言・文書同期など検出網・可読性・文書整合に留まる) → `class: "B"`。`scenario` に「なぜ実行時シナリオを書けないか」の認定文 1 行を書く (降格時の record にそのまま載る判定文。**class B で scenario を欠くと helper が判定不能 = class A に倒す**ため必須)
- **class B かつ「本 PR の diff が既存 (base 側) に存在した記述・ガード・禁止文を削除または弱体化した」** → `exclusion` にその判定文 1 行を書く (`scenario` に加えて必須。helper が降格対象外にする)。新規追加文への文言磨き・pin 精度には `exclusion` を**書かない**
- **`exclusion` キーを書くなら非空文字列**。空文字や非文字列は helper が判定不能 = class A に倒す。キーごと欠落は除外しない (従来どおり降格対象)
- **不確実な場合は class B へ倒す** (攻め側既定 — 保守既定は判定者の萎縮で現状維持に退化する。誤降格は record で可視、最終防衛線は人間のマージ判断)。ただし既存記述の削除/弱体化が観測できるなら `exclusion` を省略してはならない
- **ファイルパスで機械分類しない** — テストへの指摘でも「clean fixture のため本番バグを検出できない」類は実行時帰結を持つ class A である
- **`scenario` (判定文) は 1 行で書き、raw `|` (パイプ) と改行を含めない** (パイプを含む表記は `¦` U+00A6 で代替)。判定文は helper が `demotion.reason` へそのまま写し、5.4 の `### 実測なし指摘 (non-blocking)` section の `内容` セル先頭と 6.1.d 記録コメントの降格理由列へ verbatim で差し込まれる — raw パイプは `/rite:fix` ステップ 1.2.1 の 6 列パースを列ズレさせる (`_reviewer-base.md` の `内容` 列規約と同じ理由)
- 分類は本 consolidation コンテキストが行う (finding を発行した reviewer の自己申告は入力にしない)
- **`category == "number_reference"` は class A 固定** — Number-reference `--diff` 節の「ゲート後も findings[] に残す」を拘束する。class B に倒さない。helper も map にかかわらずこの固定を強制する

判定結果を **Write tool** で `{review_tmp_dir}/rite-review-class-{pr_number}-{current_commit_sha}.json` に保存する (`{current_commit_sha}` は ステップ 1.2.5 で記録した本 cycle の commit SHA を**リテラル置換する**。**パスに cycle 識別子を含めるのは必須** — `${TMPDIR}` はセッション内不変のため、含めないと前 cycle の map が同一パスに残り、step 1 を飛ばして step 2 だけ実行した場合に helper が stale map を well-formed 入力として受理して**別 cycle の判定を無音で適用する**。識別子があれば同じ状況は `classification_missing` の loud fail として現れる — **ただし HEAD 不変で再入する cycle では前 cycle の map が同一パスに残る。識別上の制約は 5.3.0.M step 1 の「既知の残余」を SoT とする**。4.6 の timings ファイルと同一の規約):

```json
{"classifications": [
  {"id": "F-01", "class": "A", "scenario": "<放置時にどの操作で何が壊れるかの 1 行>"},
  {"id": "F-02", "class": "B", "scenario": "<実行時シナリオを書けないことの認定文 1 行>"},
  {"id": "F-03", "class": "B", "scenario": "<実行時シナリオを書けないことの認定文 1 行>",
   "exclusion": "<base 側に存在した記述・ガード・禁止文が本 PR の diff で削除/弱体化されたことの 1 行>"}
]}
```

- 対象は gated finding **全件** (欠落エントリは helper が class A 扱い + WARNING にする — 意図的な省略を判定不能と区別できないため、全件を明示的に書く)
- **`findings[].consequence_class` を JSON に直接書いてはならない** — helper は map だけを読み、既存の `consequence_class` は算出結果で無条件に上書きされる (書いても判定は変わらないが、迂回を試みた形跡として review で疑義を生む)

**step 2: ゲート適用**

```bash
# ステップ 5.3.0.C: 帰結クラス降格政策 — scripts/review-class-demotion-gate.sh へ委譲済。
# helper 契約: classification map の機械適用 / class A=0 ∧ 除外なし class B>=1 のときのみ
# 除外なし class B を non_blocking_findings[] へ demotion (policy + 判定文) 付きで移送 /
# exclusion 付き class B は blocking 維持 / 移送後 blocking 件数からの
# overall_assessment・verdict 再確定 / class_demotion 監査フラグ / 判定不能は class A 扱い +
# WARNING / 冪等 (blocking 0 は noop) / 失敗は非ゼロ終了。SoT は helper docstring。
bash {plugin_root}/scripts/review-class-demotion-gate.sh \
  --input {review_tmp_dir}/rite-review-result-{pr_number}.json \
  --classification {review_tmp_dir}/rite-review-class-{pr_number}-{current_commit_sha}.json
```

**step 3: marker の読み取りと routing**

**評価規則**: 5.3.0.M step 3 と同じ — 上から順に評価し最初に一致した行のみを採用する。helper の終了コードが非ゼロなら成功 marker を観測しても無視する (rc が最終的な権威)。

| 観測 | LLM action |
|---|---|
| `[CONTEXT] CLASS_DEMOTION_GATE_FAILED=1; reason=classification_missing` / `classification_json_invalid` / `classifications_not_array` / `classification_entry_not_object` (helper 非ゼロ終了) | **caller (step 1) 契約違反で、map を作り直せば同 cycle 内で収束する。** helper の ERROR 行に従って step 1 の map を**作り直してから** step 2 を再実行する。**再試行は本 step 全体で 1 回まで** — `class_gate_retry_count` (下記) が `1` の状態で再発したら `[review:error]` を stdout に出力して停止する |
| `[CONTEXT] CLASS_DEMOTION_GATE_FAILED=1; reason=...` (上記 4 種以外。`jq_missing` / `input_missing` / `input_unreadable` / `json_invalid` / `findings_not_array` / `non_blocking_not_array` / `measured_undetermined` / `classification_unreadable` / `jq_transform_failed` / `stats_read_failed` / `mktemp_failure` / `write_failure` / `mv_failure` / `signal_aborted`) | **`[review:error]` を stdout に出力して停止する。LLM 適用へ fallback してはならない** (5.3.0.M と同じ fallback 禁止)。`measured_undetermined` は classification map を作り直しても解消しないため、step 1 の再 Write へ戻さない |
| marker が一切出ずに helper が非ゼロ終了した (exit 2 = 引数欠落 / 未知フラグ) | 同上 — `[review:error]` を stdout に出力して停止する |
| `[CONTEXT] CLASS_DEMOTION_GATE=noop; reason=no_blocking` (helper rc=0) | blocking 0 件 (skip 条件の取りこぼし or 再実行)。JSON は無変更。5.3.0.M の値のまま 5.3.1 以降へ進む |
| `[CONTEXT] CLASS_DEMOTION_GATE=applied; class_a=0; class_b={b}; demoted={d}; assessment=mergeable` (helper rc=0) | **降格発動 (全対象 B が降格)**。`total_findings = 0`、`overall_assessment = mergeable` として 5.3.1 以降へ進む (**再分類しない**)。`non_blocking_count` は移送後 JSON の `non_blocking_findings[]` 長で更新する (実測ゲート降格分との合算)。降格分はステップ 5.4 の `### 実測なし指摘 (non-blocking)` section と ステップ 6.1.d の関連 Issue 記録コメントに降格理由付きで載る |
| `[CONTEXT] CLASS_DEMOTION_GATE=applied; class_a=0; class_b={b}; demoted={d}; assessment=fix-needed` (helper rc=0) | **部分降格** (exclusion 付き B が blocking に残った)。`total_findings` / `overall_assessment` は移送後 JSON の gated `findings[]` 件数と `overall_assessment` を読む (**再分類しない**)。`non_blocking_count` は移送後配列長で更新する |
| `[CONTEXT] CLASS_DEMOTION_GATE=not-triggered; class_a={a}; class_b={b}; demoted=0; assessment={v}` (helper rc=0) | **非発動** (class A が 1 件以上、または降格対象の B が 0 件)。blocking 集合は不変で、`total_findings` / `overall_assessment` も 5.3.0.M の値のまま 5.3.1 以降へ進む。分類結果は JSON の `consequence_class` に記録済み (監査用)。exclusion 付き B のみの cycle はここに落ち、`assessment=fix-needed` |

成功時に併記されうる観測 marker (WARNING と対。**分類を変えず、続行を妨げない**。ステップ 6 Retained flag mapping 登録済):

- `[CONTEXT] CLASS_DEMOTION_UNCLASSIFIED=1; count={n}` — classification map のエントリ欠落・class 不正・class B の判定文欠落・class B の exclusion 不正・同 id 重複により **class A 扱い (blocking 維持)** に倒した finding が {n} 件ある。silent 降格は存在しない — 判定不能が blocking を増やす方向にしか働かない。次 cycle で map の網羅を直す材料にする
- `[CONTEXT] CLASS_DEMOTION_CATEGORY_PINNED=1; count={n}` — `category == "number_reference"` に well-formed な class B が指定されたため、helper が class A へ固定して blocking を維持した finding が {n} 件ある。map と category 固定の矛盾を WARNING と対で可視化する

**`class_gate_retry_count`** (retained flag、conversation context に保持): int、初期値 `0`。**step 2 を再実行する直前に +1 する。** 値が `1` の状態で再び caller 契約違反が出たら `[review:error]` を stdout に出力して停止する (`measured_gate_retry_count` と同じ規約・同じ理由)。


### 5.3.8 Fix-Introduced Finding Attribution

fix 後の再レビュー（verification または `loop_count >= 1`）では各指摘を 3 分類する。
**Step 1**: 適用可否:

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
attribution_state_tmp=""
_rite_pr_review_attribution_cleanup() {
 rm -f "${attribution_state_tmp:-}"
}
trap 'rc=$?; _rite_pr_review_attribution_cleanup; exit $rc' EXIT
trap '_rite_pr_review_attribution_cleanup; exit 130' INT
trap '_rite_pr_review_attribution_cleanup; exit 143' TERM
trap '_rite_pr_review_attribution_cleanup; exit 129' HUP

if [ -f "$state_file" ]; then
 if ! attribution_state_tmp=$(mktemp "${state_file}.tmp.XXXXXX"); then
  echo "WARNING: attribution state の一時ファイル作成に失敗しました" >&2
 elif jq --argjson total "$total_findings" \
  --argjson fix_introduced "$fix_introduced_count" \
  --argjson severity "{\"CRITICAL\":$critical_count,\"HIGH\":$high_count,\"MEDIUM\":$medium_count,\"LOW-MEDIUM\":$low_medium_count,\"LOW\":$low_count}" \
  '.cycles[-1].findings_total = $total | .cycles[-1].findings_new_from_fix = $fix_introduced | .cycles[-1].findings_by_severity = $severity' \
  "$state_file" > "$attribution_state_tmp" \
  && [ -s "$attribution_state_tmp" ] \
  && mv "$attribution_state_tmp" "$state_file"; then
  printf '[CONTEXT] ATTRIBUTION_WRITTEN total=%d fix_introduced=%d\n' "$total_findings" "$fix_introduced_count"
 else
  echo "WARNING: attribution state の書き込みに失敗しました" >&2
 fi
fi
```


### 5.4 Integrated Report Generation

構造と難所は reasoning で決め、本文は output で 1 回だけ書く。
下書きを reasoning で全文作ってから再出力しない。
絵文字は `skills/reviewers/SKILL.md` の方針。ヘッダと重要 WARNING のみ。
テンプレート本文は [references/integrated-report-templates.md](references/integrated-report-templates.md)。

**`### CI` は通常・verification 両モードと E2E で常に表示する**。以下の表示内容を `{ci_status_summary}` に埋める。ステップ 1.2.5.C の `{ci_status}` から対象 SHA・state を表示し、healthy は 1 行要約、pending は「未完了」、none は「check なし」、unknown は原因を併記する。failed があれば集約 state に関係なく job 名・結論・詳細 URL を列挙する。

**Template selection:**

| review_mode | Template Used |
|-------------|-------------------|
| **`full`** | Full review mode template |
| **`verification`** | 統合テンプレート（検証サマリー + フルレビューセクション含む） |

**Note**: 両テンプレートに `📎 reviewed_commit: {current_commit_sha}` を出す（次 cycle verification 用）。差分スコープの起点は 6.1.a の永続 JSON `commit_sha`。
**`### レビュー範囲（cycle 2+ 差分スコープ）` section**: `REVIEW_CYCLE_SCOPE == incremental` のときのみ描画する（`full` のときはセクションごと省略）。起動した reviewer とその選出理由（前サイクル finder の `mandatory` 合流 / fix diff の領域担当）、および**今サイクルで起動しなかった reviewer 名と理由**を列挙する。silent な絞り込みは禁止で、本 section は E2E でも省略禁止（上記 E2E Output Minimization 表の例外 1）。
**`### レビューレーン（XS/S 軽量レーン）` section**: `COMPLEXITY_LANE == light`（ステップ 1.3.2）のときのみ描画する（`full` のときはセクションごと省略）。宣言 Complexity、軽量化した検証 mandate、**軽量化していない項目**、および**レーンの上限により起動しなかった reviewer 名と理由**を列挙する。silent な絞り込みは禁止で、本 section は E2E でも省略禁止（上記 E2E Output Minimization 表の例外 3）。
**`### 総合評価` の `**起動の直列化**` 行**: ステップ 4.6 の `SPAWN_SPREAD` が `serialized` / `undetermined`、または欠落を伴う `parallel` のときに描画する（全員分が揃い閾値内だった正常系は行ごと省略する）。silent な省略は禁止で、本行は E2E でも省略禁止（上記 E2E Output Minimization 表の例外 5）。

**`### 実測なし指摘 (non-blocking)` の情報源**: ゲート適用済 JSON の `non_blocking_findings[]` を Read して描画する。記憶から再構成しない。`{non_blocking_count}` は 5.3.0.C 発動 cycle は移送後配列長、それ以外は `MEASURED_GATE` の `non_blocking_total=`。**`demotion` 付きは `内容` 先頭に `[class B 降格: {demotion.reason}]`**。**列は追加しない**（6 列固定）。
**`### 実測阻害` の情報源**: ゲート適用済 JSON の `findings[]` と `non_blocking_findings[]` の和から `description` に `Measurement-Blocked:` を含む要素を抽出し描画する。記憶から再構成しない。`{measurement_blocked_count}` はその件数。0 件ならセクションごと省略。helper は本 marker を実測アンカーとして読まないため、当該 finding は通常 `non_blocking_findings[]` に入る。**列は `実測なし指摘` 表に足さない**（6 列固定）。本 section は E2E でも省略禁止（上記 E2E Output Minimization 表の例外 6）。

---

## ステップ 6: 結果出力

### 6.1 Output Review Result (Local Save + Conditional PR Comment + Non-measured Record)

結果は 3 独立経路。PR コメントは `mktemp` + `--body-file`。
1. **Local JSON**（常時）
2. **PR comment**（`{post_comment_mode}=true` のみ）
3. **非実測記録**（常時。`{post_comment_mode}` に**依存しない**。6.1.d）
ステップ 6 / 8 の失敗・判定不能 marker または非ゼロ終了を観測したら、続行を判断する前に [出力・保存の診断表](references/output-diagnostics.md) を読む。flag namespace と reason を照合し、同表の停止・再実行規則を適用する。正常時の引数と retained flags は以下の各ステップに従う。

**Retained flag mapping**:

- **ステップ 6.1.a** は `[CONTEXT] LOCAL_SAVE_FAILED=1` flag を emit する。従来の16 reason に provenance 契約違反3 reason (`timestamp_not_injected` / `gate_not_applied` / `gate_record_mismatch`) を加える。後者3種は rc=1 でステップ 6 を停止し、それ以外は既存の非ブロッキング契約を維持する。
- **ステップ 6.1.b** は `[CONTEXT] REVIEW_OUTPUT_FAILED=1` flag を emit する。reason 値は `tmpfile_write_failure` / `gh_comment_post_failure` / `json_saved_from_p61a_unset` / `p61b_post_comment_mode_invalid` のいずれか。この flag は PR コメント投稿経路の失敗を示し、hard error として ステップ 6 を fail させる (ステップ 6.1.a の非ブロッキング契約とは対照的)。なお `post_comment_mode=false` で 6.1.b に誤呼出された場合は gate が **silent skip (exit 0)** するため、caller branch selection ミスは retained flag emit せずに吸収される (データ破壊なし、gh pr comment も実行されない)。
- **ステップ 6.1.c** は case 2 (`post_comment_mode=false` ∧ `LOCAL_SAVE_FAILED=1` の組み合わせ) で `[CONTEXT] REVIEW_OUTPUT_FAILED=1` (reason 値 `p61c_persistence_unrecoverable`) を emit し、ステップ 6 全体を `exit 2` で fail させる (silent data loss 防止)。
- **ステップ 6.1.a** は `non_blocking_findings[]` の欠陥を 2 種の observability marker で報告する (`review-result-save.sh` が emit。**いずれも非ブロッキング** — 保存は続行し `JSON_SAVED=true` のまま。`LOCAL_SAVE_FAILED` reason ではないため 16 種の reason 表 / Eval-order enumeration には登録しない): キー欠落 / 非配列 → `[CONTEXT] NON_BLOCKING_FINDINGS_KEY_MISSING=1; pr={n}` / 和集合での id 重複・書式違反 → `[CONTEXT] NON_BLOCKING_FINDINGS_ID_UNION_VIOLATION=1; pr={n}`。hard fail するのは `findings[]` 側の id 欠陥のみ (`reason=finding_id_format_or_uniqueness_violation`)。
- **ステップ 6.1.d** は terminal sentinel `[CONTEXT] NONBLOCKING_RECORD_DONE=1; pr={n}; outcome=created|updated|skipped|failed|aborted; count={k}; iteration_id={id}; comment_id={id または空}; degraded=0|1` を **1 種だけ** emit する (`review-nonblocking-record.sh` の EXIT trap)。**6.1.d step 3 / ステップ 8.0.3 の gate が pass 条件として参照するのは本 sentinel のみ**であり、成功 / skip / 失敗の区別は `outcome=` フィールドが担う (別 marker を増やさない — consumer ゼロ marker を作らないため)。失敗時は加えて `[CONTEXT] NONBLOCKING_RECORD_FAILED=1; reason=...` (上記 6.1.d reasons 表の全 reason) を emit するが、これは reason 語彙の observability 用で gate の入力ではない。**`outcome=failed` / `aborted`、および `degraded=1`（`outcome` を問わない — `updated ∧ degraded=1` は `existing_id=""` を伴うため構造的に到達不能で、実質 `skipped` / `created` の両方をカバーする）を観測したときは、6.1.d step 3 / ステップ 8.0.3 のいずれで観測した場合も、helper の WARNING / 対応する reason を completion report に転記してから次へ進む** (転記しないと記録が落ちた / stale が残った事実がどこにも残らない。`created ∧ degraded=1` は既存記録コメントを検出できないまま新規作成した縮退で、古い記録が関連 Issue 上に stale で残りうる — `skipped ∧ degraded=1` と同じ結末のため同一の転記対象とする)。**加えて `[CONTEXT] NONBLOCKING_LEGACY_ORPHAN=1` / `NONBLOCKING_DUPLICATE_RECORD=1` を観測したときも、helper の WARNING (件数と手動削除の案内) を completion report に転記してから次へ進む** — どちらも人間の手作業を要求する指示を含むため、転記しないと関連 Issue 上に孤児 / 重複が残った事実がどこにも残らない (`outcome=updated ∧ degraded=0` で発火しうるため、既存 3 条件のいずれにも該当しない)。**この 2 marker 自体は純粋な observability marker であり、gate の入力ではない — result pattern の emit 可否にも `overall_assessment` にも一切影響しない** (AC-3。直前の `outcome=failed` の帰結とは独立)。
- **ステップ 6.1.d の観測 marker (4 種)**: lookup が候補を落とした事実 (下記 2 種) と、durable な comment id による同定が使えなかった事実 (さらに下の 2 種) を可視化する。`[CONTEXT] NONBLOCKING_LEGACY_ORPHAN=1; pr={n}; count={m}` (author ∧ marker 前方一致は満たすが最終非空行が sentinel でない件数。sentinel 導入前の記録コメント、または marker で始まる手書きコメントが update-in-place の対象外になったこと) / `[CONTEXT] NONBLOCKING_DUPLICATE_RECORD=1; pr={n}; count={m}` (sentinel を持つ自分の記録コメントが 2 件以上 = 過去の degraded 縮退が生んだ重複。`last` を採るため古い方は stale で残る)。**いずれも純粋な observability marker であり、gate の入力ではない — result pattern の emit 可否にも `overall_assessment` にも一切影響しない** (AC-3)。`*_FAILED` reason ではないため reason 表 / Eval-order enumeration には登録しない (`NON_BLOCKING_FINDINGS_KEY_MISSING` と同じ扱い)。ただし**どちらも人間の手作業 (古いコメントの手動削除) を要求する**ため、下記 6.1.d step 3 / ステップ 8.0.3 の転記条件に含める。
  残る 2 種は **durable な comment id** (関連 Issue body の marker 行。形状の SoT は helper の `ID_MARKER_*` 定数) による同定の縮退を可視化する。`[CONTEXT] NONBLOCKING_ID_UNRESOLVED=1; pr={n}; reason={r}; action=fallback` (id で PATCH 先を決められず本文照合へ倒した。reason 語彙 8 種: `id_read_failed` / `id_malformed` / `id_fetch_failed` / `id_fetch_unparseable` / `id_author_mismatch` / `id_pr_mismatch` / `id_target_not_record` / `id_comment_deleted`。**帰結は理由に依らず fallback の 1 種**で `action=` は常に `fallback` — 理由ごとに帰結を分けると周辺状態との交差ごとにガードが要り、そのガード自体が次の欠陥面になる。**id が関連 Issue body に無い初回 cycle では出さない** — 永続化前は正常系であり、毎 cycle 出すと本当の異常が埋もれる。逆に `gh api user` が失敗した cycle は段 1 自体が呼ばれないため本 marker は 1 つも出ないまま `degraded=1` へ縮退する — **「id 側が外れた」と「本 marker が出る」は同値ではない**) / `[CONTEXT] NONBLOCKING_ID_PERSIST_FAILED=1; pr={n}; reason={r}` (投稿後の id 永続化に失敗。reason 語彙: `comment_id_unresolved` / `body_read_failed` / `body_write_failed` / `body_edit_failed`)。**この 2 種は上の 2 種と違い転記条件に含めない**。根拠は「人間の手作業を要求しないから」では**ない** — `reason=id_author_mismatch` の cycle は fallback も自 author 条件で空を返して新規作成へ倒れるため、旧 identity の記録コメントが孤児として残り、その削除は人手を要する。しかも lookup 述語が自 author 限定なので `NONBLOCKING_DUPLICATE_RECORD` はその孤児を数えられず、退路にならない。除外の根拠は**影響の限定**である: 残るのは関連 Issue 上の孤児 1 件で、`overall_assessment` にも記録内容にも影響せず、次 cycle 以降も同じ 1 件のまま増えない (fallback は毎 cycle 同じ 1 件を作り直すのではなく、自 identity の記録を update-in-place する)。helper の hint 側も同じ基準で書く — **関連 Issue 上の状態を人手で修復させる文言 (コメントの手動削除 / Issue body の手動編集) は置かない**。環境診断の案内 (`gh auth status` / network / jq 実行環境の確認) は復旧に必要な情報であり、本規則の対象外として許容する。永続化失敗は環境 / IO 起因のため **pending marker は残さない** (`body_check_unavailable` と同じ削除バケット)。
- **ステップ 5.3.0.M step 2 / ステップ 6.1.a / ステップ 8.0.4** は 8.0.4 の機械強制 (save-pending marker + 本 cycle 結果 JSON の実在) 用に 6 種の marker を emit する。`[CONTEXT] REVIEW_SAVE_PENDING_ID={id または空}` (5.3.0.M step 2、6.1.a の `--pending-id` へ渡す値) / `[CONTEXT] REVIEW_SAVE_PENDING_MARKER={path または空}` (同 step、8.0.4 の `[ -e ]` / `[ -L ]` 検査用 — 8.0.3 の `[ -e ]` のみとは非対称。作成失敗時は両方とも空) / `[CONTEXT] REVIEW_SAVE_DONE=1; pr={n}; marker={path}; saved={true|false}` (`review-result-save.sh` の EXIT trap、**6.1.a helper が完走した**ことの terminal sentinel。`saved=` は保存の成否で、`JSON_SAVED=` と同値) / `[CONTEXT] REVIEW_SAVE_GATE=pass; reason=save_pending_marker_absent` / `REVIEW_SAVE_GATE=degraded; reason=...` / `REVIEW_SAVE_JSON_OK=1; pr={n}; result_json={basename}` ・ `REVIEW_SAVE_GATE_FAILED=1; reason=save_pending_marker_present; marker={path}` または `reason=save_result_json_absent; expected_sha={sha}` (8.0.4、`REVIEW_SAVE_GATE_FAILED` の 2 reason は **gate 失敗として `exit 1`**。`save_result_json_*` と `REVIEW_SAVE_JSON_OK` の emit 元は `hooks/scripts/review-save-json-verify.sh` で、marker 層の 3 arm すべてから呼ばれる。marker 残存を検出した枝だけは `*)` arm 内の `exit 1` で helper に到達しない)。**marker が意味するのは「6.1.a が実行された」であって「保存に成功した」ではない** — 保存失敗 (`LOCAL_SAVE_FAILED`) でも helper は marker を削除する。そうしないと D-04 非ブロッキング契約が本 gate の **marker 層**経由で blocking gate に化ける (保存失敗の可視化は既存の `LOCAL_SAVE_FAILED` + ステップ 6.1.c ケース 2 が担う。positive 層は別で、**新規 commit を伴う cycle で**保存に失敗すれば本 cycle の JSON 不在として `save_result_json_absent` を発火させる (HEAD 不変の accept-only cycle は前 cycle の JSON が SHA 一致で pass しうる = `references/measured-gate-record.md` の既知の残余) — 保存失敗が gate 全体で非ブロッキングという意味ではない)。`overall_assessment` は変えず、変えるのは「result pattern を emit してよいか」の可否のみ (8.0.3 と同じ namespace 分離)。
- **ステップ 6.1.a step 0 / ステップ 8.0.3** は 8.0.3 の機械強制 (pending marker) 用に 3 種の marker を emit する。`[CONTEXT] NONBLOCKING_PENDING_MARKER={path または空}` (6.1.a step 0、marker のパスを 8.0.3 へ渡す。作成失敗時は空) / `[CONTEXT] NONBLOCKING_GATE=pass|degraded; reason=...` (8.0.3、`reason` は `pending_marker_absent` / `pending_marker_placeholder_residue` / `pending_marker_unavailable`) / `[CONTEXT] NONBLOCKING_GATE_FAILED=1; reason=pending_marker_present; marker={path}` (8.0.3、**gate 失敗として `exit 1`**。6.1.d へ戻さずに ステップ 8.1 へ進むことを禁じる唯一の機械的層)。`NONBLOCKING_RECORD_*` とは別 namespace で、`overall_assessment` そのものは変えない — 変えるのは「result pattern を emit してよいか」の可否のみ。**marker が残る (= 8.0.3 が差し戻す) 経路は「原因」で決まる**: 引数 gate 群 (placeholder residue 5 種 / `content_file_missing`、trap 設置前の `exit 1`) と本文検査 4 段 (`body_file_empty` / `body_marker_missing` / `body_sentinel_missing` / `count_body_mismatch`、trap 設置後の `retain_pending_marker=1`) — いずれも caller (LLM) 契約違反で、本文 / `--count` を作り直せば 1 iteration で収束する。gh / network / rate-limit / IO 起因 (`patch_failed` / `create_failed` / lookup degraded / `body_check_unavailable`) と signal 中断 (`signal_aborted`)、および **第 3 群 `related_issue_unresolved`（trap 設置後の exit 1 で表面化するが pending marker は残さない — 同 cycle 内で PR body / branch を直せないため差し戻しても収束しない）** は差し戻しても同 cycle 内で収束しないため従来どおり無条件削除する。`body_check_unavailable` は本文検査 4 段と同じ位置で起きるが、**述語を評価できなかった**環境起因の失敗であり caller が本文を作り直しても解消しないため本群に属する。境界を exit code (trap の前後) で引くと、同種の契約違反が検出位置の違いだけで機械強制から外れる。rationale: [references/measured-gate-record.md#pending-marker](references/measured-gate-record.md#pending-marker)
- **ステップ 5.3.0.M** は正規形アンカーを検出できず実測判定不能な gated finding が 1 件でもあれば `[CONTEXT] MEASURED_GATE_FAILED=1; reason=anchor_undetermined; count=N; findings=F-xx,...` を emit し、JSON を変更せず非ゼロ終了する。step 3 が対象 reviewer 出力を同 cycle 内で再生成する。実測なしと算出できる形式崩れは成功時に `MEASURED_DEMOTED_ON_ANCHOR` で報告する。検出 regex・marker・判別子の SoT は [assessment-rules.md §5.3.0.M](../fix/references/assessment-rules.md)。
- **ステップ 5.3.0.M** は成功時に `MEASURED_GATE=applied; blocking={n}; demoted={d}; non_blocking_total={t}; assessment={a}` を emit する。観測 marker は `MEASURED_DEMOTED_ON_ANCHOR` / `MEASURED_RUNTIME_OBS_WITHOUT_ANCHOR`。失敗時は `MEASURED_GATE_FAILED=1; reason=...` と非ゼロ終了で停止する。reason の SoT は helper docstring。`anchor_undetermined` / `scope_enum_violation` / `verification_preset_by_caller` は step 3 の契約修復 routing に従い、同 cycle 内で共通上限 1 回の再試行を行う。他の失敗と再発は `[review:error]` とし、LLM 分類へ fallback しない。ステップ 6 の非ブロッキング reason 群とは別 namespace である。
- **ステップ 5.3.0.C** は `scripts/review-class-demotion-gate.sh` から成功時に `[CONTEXT] CLASS_DEMOTION_GATE=noop; reason=no_blocking` / `CLASS_DEMOTION_GATE=applied; class_a=0; class_b={b}; demoted={d}; assessment={mergeable|fix-needed}` / `CLASS_DEMOTION_GATE=not-triggered; class_a={a}; class_b={b}; demoted=0; assessment={v}` のいずれか 1 つを emit する (降格発動の有無と 5.3.1 以降へ渡す値の経路。`applied` かつ `assessment=fix-needed` は exclusion 付き B が残った部分降格)。観測 marker `[CONTEXT] CLASS_DEMOTION_UNCLASSIFIED=1; count={n}` (map 由来の判定不能 → class A 扱い) は WARNING と対で条件付き emit され、blocking を増やす方向にしか働かない。失敗時は `[CONTEXT] CLASS_DEMOTION_GATE_FAILED=1; reason=...` を emit して非ゼロ終了する — reason 語彙の SoT は helper docstring。`measured_undetermined` を含む失敗は **5.3.0.M と同じく `[review:error]` 停止を伴い、LLM 適用への fallback は禁止**。ただし `classification_missing` / `classification_json_invalid` / `classifications_not_array` / `classification_entry_not_object` の 4 種は caller (step 1) が map を作り直せば同 cycle 内で収束する契約違反であり、step 1 の再 Write + step 2 の再実行 (本 step 全体で 1 回まで) を先に行う (routing の詳細は ステップ 5.3.0.C step 3 の表)。

**Eval-order enumeration** (Pattern-2 documented-union input): ステップ 6.1.a emit sequence = (`pr_number_placeholder_residue` / `date_command_failure` / `mkdir_failure` / `mktemp_failure` / `write_failure` / `timestamp_injection_mv_failure` / `json_invalid` / `schema_required_fields_missing` / `guardrail_audit_log_keys_violation` / `finding_id_format_or_uniqueness_violation` / `scope_enum_violation` / `critical_high_scope_nit_noted_invariant` / `mktemp_failure_mv_err` / `collision_resolution_exhausted` / `mv_failure`) — 15 件、bash block 内の実 emit 順 (`signal_aborted` は signal trap 由来で線形の emit 順に載らないため除外) (`scope_enum_violation` / `critical_high_scope_nit_noted_invariant` は finding_id_format_or_uniqueness_violation の直後に elif chain で配置); ステップ 6.1.b emit = (`p61b_post_comment_mode_invalid` / `p61b_pr_number_invalid` / `tmpfile_write_failure` / `iso_timestamp_from_p61a_unset` / `raw_json_timestamp_injection_failed` / `gh_comment_post_failure` / `json_saved_from_p61a_unset`) — `p61b_post_comment_mode_invalid` は post_comment_mode gate が bash block 冒頭で最初に評価されるため先頭に配置; ステップ 6.1.c emit = (`p61c_post_comment_mode_invalid` / `p61c_pr_number_invalid` / `p61c_file_timestamp_unset` / `p61c_file_timestamp_unknown_without_failure` / `p61c_local_save_failed_invalid` / `p61c_persistence_unrecoverable`) — `p61c_post_comment_mode_invalid` を先頭に配置 (6.1.b と対称); ステップ 6.1.d emit = (`unknown_option` / `pr_number_placeholder_residue` / `owner_repo_placeholder_residue` / `non_blocking_count_placeholder_residue` / `iteration_id_placeholder_residue` / `content_file_placeholder_residue` / `content_file_missing` / `related_issue_unresolved` / `body_file_empty` / `body_marker_missing` / `body_check_unavailable` / `body_sentinel_missing` / `count_body_mismatch` / `patch_failed` / `create_failed`) — 15 件、helper 内の実 emit 順 (引数解析ループ内の `unknown_option` → placeholder residue 5 種 + content_file 存在検査を引数 parse 直後にまとめて評価 → trap 設置後の関連 Issue 解決 → lookup → 本文の非空検査 → 1 行目 marker 検査 → 機械専用 sentinel 検査 (述語の評価自体が失敗した場合は `body_check_unavailable`) → 件数整合検査 → PATCH / create の分岐)。`patch_failed` と `create_failed` は排他分岐のため同一 run で両方は出ない。`signal_aborted` は signal trap 由来で線形の emit 順に載らないため本 enumeration から除外する (ステップ 6.1.a が observability marker を除外する慣行と同じ); ステップ 8.0.3 (機械強制) emit = (`pending_marker_placeholder_residue` / `pending_marker_unavailable` / `pending_marker_present` / `pending_marker_absent`) — 4 件、bash の `case` 分岐順 (placeholder 残留 → marker 未作成 → 残存 (`exit 1`) → 不在 (pass))。前 2 者は `NONBLOCKING_GATE=degraded`、`pending_marker_present` は `NONBLOCKING_GATE_FAILED=1`、`pending_marker_absent` は `NONBLOCKING_GATE=pass` に載る; ステップ 8.0.4 (機械強制) emit = (`save_pending_marker_placeholder_residue` / `save_pending_marker_unavailable` / `save_pending_marker_present` / `save_pending_marker_absent` / `save_result_json_undecidable` / `save_result_json_absent`) — 6 件、**2 層の評価順**: 前 4 件は marker 層 (`case` 分岐順。4 件とも 8.0.3 と同一順) が emit し、後 2 件は `esac` 後の `review-save-json-verify.sh` が入力検査 → 実在検査の順で評価する。`save_pending_marker_placeholder_residue` / `save_pending_marker_unavailable` / `save_result_json_undecidable` は `REVIEW_SAVE_GATE=degraded`、`save_pending_marker_present` / `save_result_json_absent` は `REVIEW_SAVE_GATE_FAILED=1`、`save_pending_marker_absent` は `REVIEW_SAVE_GATE=pass` に載る。helper の成功は reason を持たない observability marker `REVIEW_SAVE_JSON_OK=1` で、本列挙には含まれない (`MEASURED_DEMOTED_ON_ANCHOR` 等と同じ扱い)。**marker 層が degraded でも positive 層は実行される** — 層ごとに独立して評価するため、後 2 件は前 3 件 (`save_pending_marker_present` を除く — 同 reason の枝は `*)` arm 内の `exit 1` で `esac` 後の helper に到達しない) のいずれとも共起しうる。

`CLASS_DEMOTION_CATEGORY_PINNED` はステップ 5.3.0.C の条件付き観測 marker として Retained flag mapping に含める。well-formed な class B と `number_reference` 固定の矛盾件数を表し、assessment 自体は直接変更しない。

#### 6.1.a Local JSON File Save (Always Executed) <!-- AC-1 / D-01 / D-02 / D-04 -->

> **Acceptance Criteria anchor**: AC-1 (`pr_review.post_comment` 未設定時にデフォルトで PR コメント投稿せず、`.rite/review-results/{pr}-{ts}.json` のみ作成)。D-01 (ハイブリッド方式: 会話 > ローカルファイル > PR コメント)。D-02 (同一 PR の履歴を timestamp 付きで保持、best-effort、同秒衝突は `~$RANDOM` suffix で回避 — separator `~` は `.` より ASCII 大で sort -r 時に新しい collision-resolved 版が先頭に来る)。D-04 (非ブロッキング契約: ローカル保存失敗は WARNING のみで続行、`common-error-handling.md` の Non-blocking Contract 準拠 — ただし `post_comment=false` ∧ `LOCAL_SAVE_FAILED=1` 組み合わせは ステップ 6.1.c でケース 2 の ⚠️ WARNING に昇格する)。


[review-result-schema.md](../../references/review-result-schema.md) の timestamp 付き JSON を `{post_comment_mode}` に関係なく保存する。

**Claude substitution requirements**:
- **JSON 本文**: **本 phase では JSON を生成しない**。保存対象は 5.3.0.M 適用済の `{review_tmp_dir}/rite-review-result-{pr_number}.json`。「Required JSON fields」は **5.3.0.M step 1 の生成規約の SoT**。
 - **`non_blocking_findings` の扱い (実測必須ゲート)**: ステップ 5.3.0.M で `non_blocking_findings` に移動した非実測 finding は、`findings[]` 配列には **含めず**、トップレベルの独立配列 **`non_blocking_findings[]`** として出力する (要素の形は `findings[]` と同一 — [review-result-schema.md §non_blocking_findings](../../references/review-result-schema.md#non_blocking_findings-配列)。`findings[]` の契約を変えないため cross-field invariant の同期は不要、read 側は未知キーを無視するため後方互換)。`findings[]` は 5.3.0.M 通過後の `全指摘事項` (blocking 指摘 + `scope == "nit-noted"` 指摘) と一致する — nit-noted は本ゲートの対象外のため非実測でも `findings[]` に残る。`non_blocking_findings[]` へ分離されるのは `scope ∈ {current-pr, follow-up}` の非実測指摘のみ。
 - **`id` は 2 配列の和集合で一意**: 5.3.0.M で降格した finding の `id` (`F-NN`) は**振り直さず元の値を維持する**。配列ごとに独立採番すると永続 JSON 内に同一 `id` が 2 つ残り、本配列の存在意義である「マージ後に人間が拾い直せる状態」で finding を一意に指せなくなる。`review-result-save.sh` の id 検証は 2 配列の和集合に対して書式 + 一意性を評価し、違反を write 時に**非ブロッキング marker** `[CONTEXT] NON_BLOCKING_FINDINGS_ID_UNION_VIOLATION=1` で報告する (保存は続行する)。hard fail (`reason=finding_id_format_or_uniqueness_violation`) するのは `findings[]` 側の id 欠陥のみ。
 - **独立配列 / 帰結**: rationale: references/design-rationale.md#non-blocking-findings-array-notes
 - **Accepted Fingerprint Suppression 契約**: ステップ 5.1.2.A で識別された `suppressed_findings` (前 cycle で `accept (認知のみ)` 選択された finding が再出現) は、本 JSON 本文の `findings[]` 配列から **除外** する。Markdown 側 (ステップ 5.4 統合レポート / ステップ 6.1.b PR コメント本文) には audit log として残すが、JSON output (本 phase / ステップ 6.1.b Raw JSON section) には含めない。これにより `/rite:fix` が JSON を読み込んだ際、accepted finding は fix loop に entered せず、decision-replay 系の同一 finding 再出現が断たれる。除外は finding 単位 (`F-NN`) で行い、各除外について ステップ 5.1.2.A Step 3 で `[CONTEXT] FINDING_SUPPRESSED_BY_ACCEPT=1; finding_id=...; original_severity=...; fingerprint=...` を emit 済 (本 phase で重複 emit は不要)。
- `{pr_number}`: ステップ 1.0 で正規化済み。`review-result-save.sh` の `--pr {pr_number}` 引数および Write 先パス (`{review_tmp_dir}/rite-review-result-{pr_number}.json`) に literal substitute する。helper が数値 fail-fast gate (`pr_number_placeholder_residue`) を持つ。
- Required JSON fields: `schema_version: "1.1.0"`, `pr_number`, `timestamp` (literal sentinel `"__RITE_TS_PLACEHOLDER_7f3a9b2c__"` を書き、helper が ISO 8601 JST 値に注入), `commit_sha` (**ステップ 1.2.5 で記録した `{current_commit_sha}` をそのまま書く** — ステップ 8.0.4 の positive 検査がこの値との一致で「本 cycle の JSON か」を判定するため。cycle 2+ では 1.2.5 の出力が会話に複数残るので**本 cycle のもの**を採る。短縮 SHA でも helper 側が prefix 一致で受理する。**値源を取り違えても gate は落ちない — 前 cycle の JSON が SHA 一致して誤 pass する**ため、helper 側に機械検査は無く本規約の遵守だけが担保), `overall_assessment` (`mergeable` / `fix-needed`), `findings[]`, **`verdict`** (`mergeable` / `fix-needed`。**step 1 の Claude は書かず** 5.3.0.M step 2 の `review-measured-gate.sh` が `overall_assessment` と同一式で無条件代入する。merge ゲートが読む必須キーで、欠落すると `review-result-save.sh` が `schema_required_fields_missing` で拒否する), **`reviewers[]`** (本 cycle で ステップ 5.1 が Task 結果を回収できた reviewer 名簿の**非空・重複なし**配列。5.3.0.M step 1 で書く。値は各 `reviewer_type` に `-reviewer` を付した形（例: `security` → `security-reviewer`）。**`findings[]` から導出しない** — findings 0 件が正常形の最終 cycle で名簿証拠が消えるため。契約の SoT は [review-result-schema.md §verdict と reviewers](../../references/review-result-schema.md#verdict-と-reviewers)). 加えて **`non_blocking_findings[]`** (5.3.0.M で降格した非実測 finding。**0 件のときも空配列 `[]` を出力する** — キー自体を省略すると「降格ゼロ」と「本ゲート未適用の旧形式」が区別できなくなる。`review-result-save.sh` はキー欠落・非配列を `NON_BLOCKING_FINDINGS_KEY_MISSING`、和集合 id 欠陥を `NON_BLOCKING_FINDINGS_ID_UNION_VIOLATION` で報告するが**いずれも保存を続行する**ため、本配列側の欠陥で blocking findings が失われることはない). Each finding の必須フィールドは以下の通り — 完全なスキーマは [review-result-schema.md](../../references/review-result-schema.md#json-schema) を真実の源として参照すること:
 - `id`: **`F-NN` 形式、最小 2 桁ゼロパディング可変長連番** (正規表現 `^F-[0-9]{2,}$`)。99 件以下は `F-01`〜`F-99`、100 件以上は `F-100` 等に成長する。
 - `reviewer`: レビュアーエージェント名 (例: `code-quality-reviewer`, `security-reviewer`, `tech-writer-reviewer`)。実在する agent 名は `plugins/rite/agents/*-reviewer.md` の basename (拡張子を除く) と一致させる。
 - `category`: 指摘カテゴリ (例: `code_quality`, `error_handling`, `security`, `performance`)。アンダースコア区切りで統一する (schema.md の `category` フィールド定義を SoT として参照)
 - `severity`: `CRITICAL` / `HIGH` / `MEDIUM` / `LOW-MEDIUM` / `LOW` のいずれか (LOW-MEDIUM は `severity-levels.md` で正式定義された first-class severity で、`COMMENT_QUALITY` 軸の独自ジャーゴン濫用 等の bounded blast radius 違反に使う)。reviewer が `Critical`/`Important`/`Minor`/`Low-Medium`/`Nit` 等の別表記で返した場合は、write 前に本 enum へ正規化する (別名マッピングは review-result-schema.md の `severity` フィールド定義を参照)。正規化漏れの JSON は read 側 (`fix.md` ステップ 1.2.0) で MEDIUM fallback と WARNING emit が発生する。
 - `file`: 対象ファイルの相対パス
 - `line`: 正の整数 (>= 1) または `null` (行非依存指摘の sentinel)。schema.md の `line` フィールド定義が SoT。新規出力では `null` を使用し、`0` は生成しないこと (`0` は legacy sentinel として read 側で `null` と同等に扱われるが、write 側で新たに生成すべきではない)。
 - `description`: 指摘内容
 - `suggestion`: 推奨対応
 - `status`: 現行実装では常に `open` を出力する。`fixed` / `replied` / `deferred` は enum として予約されているが、`/rite:fix` 側の書き戻しは未実装 (schema は slot を持つのみ、review-result-schema.md の `status` フィールド定義を参照)。
 - `scope`: `current-pr` / `follow-up` / `nit-noted` のいずれか。**省略してはならない** — 本フィールドは ステップ 5.3.0.M の実測必須ゲートが blocking 集合を決める入力そのもので、欠落を severity ベースの default mapping で補完する互換モードは持たない (補完すれば reviewer が `current-pr` を割り当てた LOW / LOW-MEDIUM が gated から脱落するため)。**値が外れてもキーが欠落しても `reason=scope_enum_violation` で hard fail し、JSON も書き換えない**（フラグ有無に依らず発火）。判定規則の SoT は [severity-levels.md](../../references/severity-levels.md) と `agents/_reviewer-base.md` §Scope Assignment Flowchart。
 - `pre_existing`: **出力しない**。1.1.0 内の additive optional field として欠落を許容し、read 側も補完しないため invariant #5 は発火しない。完全な契約は review-result-schema.md の同フィールド定義を参照する。

**`iso_timestamp` handshake**: JSON の `timestamp` は literal sentinel `"__RITE_TS_PLACEHOLDER_7f3a9b2c__"`。実値は helper が注入する。

**ステップ 6.1.a 実行手順**:

0. **Write 先実パス解決 + 本 cycle の識別子生成**: 以下の bash を実行し、`{review_tmp_dir}` に使う実パスと `{review_cycle_id}`（本 review cycle の識別子）を emit する。`REVIEW_TMP_DIR` は ステップ 5.3.0.M step 1 が emit したものと**同一の `${TMPDIR:-/tmp}`** で、レビュー結果 JSON は既にそのパスに存在する（本ブロックは同じ値を再確認し、6.1.b / 6.1.d 用の識別子を追加で作る）。Write tool は `${TMPDIR:-/tmp}` を展開できないため、以降の Write 先 / `--content-file` 引数には `REVIEW_TMP_DIR` marker の値をリテラル置換する（sandbox 環境では `/tmp` 直下が読み込み専用のため `/tmp` ハードコード不可）:

   ```bash
   review_cycle_id="{pr_number}-$(date +%s)"
   echo "[CONTEXT] REVIEW_TMP_DIR=${TMPDIR:-/tmp}" >&2
   echo "[CONTEXT] REVIEW_CYCLE_ID=$review_cycle_id" >&2
   # 8.0.3 用 pending marker。rationale: references/measured-gate-record.md#pending-marker
   pending_marker="${TMPDIR:-/tmp}/rite-nbr-pending-$review_cycle_id"
   # rationale: references/design-rationale.md#noclobber-pending-marker-notes
   if ( set -C; : > "$pending_marker" ) 2>/dev/null; then
     echo "[CONTEXT] NONBLOCKING_PENDING_MARKER=$pending_marker" >&2
   else
     echo "WARNING: pending marker を作成できませんでした ($pending_marker)。ステップ 8.0.3 の機械強制は skip され prose 判定のみになります" >&2
     echo "[CONTEXT] NONBLOCKING_PENDING_MARKER=" >&2
   fi
   ```

   <!-- rationale: references/design-rationale.md#review-cycle-id-emit-notes -->
1. **JSON body は再生成しない**: 保存対象の `{review_tmp_dir}/rite-review-result-{pr_number}.json` は ステップ 5.3.0.M step 1 で Write 済み・step 2 でゲート適用済である。本 phase は **その内容に一切手を加えない**（JSON authoring site を一本化するため）。`suppressed_findings` 除外契約と `timestamp` sentinel の書き込みも 5.3.0.M step 1 で適用済で、`timestamp` の実値は下記 helper が `$iso_timestamp` で注入する。
2. **helper 実行**: 以下の bash を実行する。helper が `iso_timestamp` 算出・sentinel 注入・schema validation・同秒衝突回避・atomic mv・`[CONTEXT]` emit を担う。JSON body / ファイル名 / `[CONTEXT]` emit の timestamp は helper 内の単一 `date` 由来で完全同期する。

```bash
# ステップ 6.1.a: ローカルファイル保存 (JSON、非ブロッキング) — hooks/review-result-save.sh へ委譲済。
# helper 契約: 従来の永続化失敗は非ブロッキング。provenance 契約違反 3 種は exit 1。
# signal_aborted のみ rc=130/143/129 で、ステップ 6 の exit code は 6.1.c が決める) / reason 語彙 (上記
# bullet と一致) / 同秒衝突回避 / trap での FILE_TIMESTAMP= ・ISO_TIMESTAMP= ・JSON_SAVED= emit
# (normal/abnormal 両経路、ステップ 6.1.c が前提) / 同 trap での save-pending marker 削除 +
# REVIEW_SAVE_DONE= emit (ステップ 8.0.4 が前提)。SoT は helper docstring。
# --pending-id: ステップ 5.3.0.M step 2 の [CONTEXT] REVIEW_SAVE_PENDING_ID= 値をリテラル置換する
# (本 cycle のもの = 末尾 -{epoch} が最大のもの。**ただし本 cycle の 5.3.0.M step 2 が空文字で
# emit している場合に限り**空文字を渡す — 空文字は epoch を持たず最大値規則で順序付けできないため、
# 過去 cycle の空 emit を採ってはならない。8.0.4 Pre-Check の選択規則と同一)。
# marker の **path** は渡さない — helper が id から内部導出する (8.0.4 の Pre-Check だけが
# REVIEW_SAVE_PENDING_MARKER= の path を使う)。
bash {plugin_root}/hooks/review-result-save.sh \
  --pr {pr_number} \
  --content-file {review_tmp_dir}/rite-review-result-{pr_number}.json \
  --pending-id "{save_pending_id}" || {
  echo "ERROR: review-result の provenance 検証に失敗しました" >&2
  echo "[review:error]"
  exit 1
}
```

**Persistence contract** (D-04): 従来の環境・永続化失敗は `[CONTEXT] LOCAL_SAVE_FAILED=1; reason=...` を出して WARNING 継続する。ただし provenance 契約違反 (`timestamp_not_injected` / `gate_not_applied` / `gate_record_mismatch`) は helper の rc=1 を受けて直ちに `[review:error]` を出し、ステップ 6 を停止する。6.1.b / 6.1.c へ進んではならない。

**Placeholder data flow**: `file_timestamp` / `iso_timestamp` / `json_saved` は EXIT trap が stderr に emit。6.1.c が使うのは `file_timestamp` と `local_save_failed`。`iso_timestamp` は observability 専用。

#### 6.1.b PR Comment Post (Conditional on `{post_comment_mode}`) <!-- AC-2: opt-in PR comment posting -->

`{post_comment_mode}=true` のときだけ実行。`false` なら 6.1.c へ。helper 先頭の gate が誤呼出を silent skip する。

> **Acceptance Criteria anchor**: AC-2 (`--post-comment` 指定時 or `rite-config.yml pr_review.post_comment: true` 時に PR コメントに投稿、code fence JSON 形式で JSON 本文も埋め込む)。D-03 (PR コメント形式は code fence JSON を採用 — /rite:fix が正規表現でパースしやすく人間も閲覧可能)。

**ステップ 6.1.b 実行手順**:

1. **コメント本文生成 + Write**: Claude は以下の構造の PR コメント本文を生成し、**Write tool で `{review_tmp_dir}/rite-review-comment-{pr_number}.md` に保存**する (`{review_tmp_dir}` はステップ 6.1.a step-0 の `[CONTEXT] REVIEW_TMP_DIR=` marker 値をリテラル置換する。旧 `RITE_COMMENT_EOF_7f3a9b2c` heredoc 埋め込みを廃止し、巨大 inline bash + nested code fence による malform 無言停止を回避):
   - `## 📜 rite レビュー結果` + ステップ 5.4 で生成した integrated report (Markdown)。改行・バッククォート・`$` を含んでよい。`📎 reviewed_commit: {current_commit_sha}` を末尾に必ず含める (次 cycle verification mode 用)。
   - (`metrics.enabled` のとき) ステップ 6.3 で算出した metrics を integrated report の末尾 (下記 `### 📄 Raw JSON` 見出しの直前) に含める。形式は `### メトリクス` 見出し + `CRITICAL: {n} / HIGH: {n} / MEDIUM: {n} / LOW: {n}` の 1 行。これにより `post_comment_mode=true` 経路では metrics が review 結果と同一コメントに集約される (別 API 呼び出し不要、ステップ 6.3 Step 2 opt-in 行と対応)。`metrics.enabled: false` のときは省略する。
   - `### 📄 Raw JSON` 見出し + ` ```json ` code fence + JSON 本文。**本文は `{review_tmp_dir}/rite-review-result-{pr_number}.json` を Read tool で読み、その内容をそのまま fence 内へ転記する** — 会話コンテキストから再生成してはならない。再生成すると ステップ 5.3.0.M のゲート適用結果が反映されず、ローカル JSON が `mergeable` なのに PR コメント側は `fix-needed` という乖離が出る。`/rite:fix` Priority 3 は本 fence を読むため、乖離は次 cycle の分類を狂わせる。`timestamp` は sentinel のまま転記する (helper が `--iso-timestamp` 値に置換する)。`suppressed_findings` 除外と `non_blocking_findings[]` は 5.3.0.M step 1 / step 2 で反映済のため、本 phase での追加操作は不要 (Markdown 表側には audit log として残す)。
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

コメント本文は Write tool → `--content-file`。末尾に `📎 reviewed_commit: {current_commit_sha}` 必須。`### 📄 Raw JSON` は 6.1.a と同じ JSON（`/rite:fix` Priority 3 が読む）。
**6.1.d への hand-off**: 完了後は 6.1.c を **skip して** 6.1.d を評価する。

#### 6.1.c Skip Notification (when `{post_comment_mode}=false`)

`{post_comment_mode}=false` のとき投稿スキップを通知する（エラーではない）。ケース分岐は helper が `LOCAL_SAVE_FAILED` を読む。
rationale: references/design-rationale.md#6.1c-machine-gate

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

`post_comment_mode=false` ∧ `LOCAL_SAVE_FAILED=1` は必ずケース 2、`exit 2`。
**6.1.d への hand-off**: ケース 1 のあと **必ず 6.1.d を評価する**。ケース 2 は 6.1.d に進まない。
rationale: references/design-rationale.md#6.1d-always-eval

#### 6.1.d 非実測指摘の関連 Issue コメント記録 (always evaluated、非ブロッキング)

5.3.0.M / 5.3.0.C で降格した指摘を関連 Issue の記録コメントへ **update-in-place** する。`{post_comment_mode}` に **依存しない**。関連 Issue は PR body の closing keyword を第一候補、branch 命名 (`issue-{N}`) を第二候補として helper が解決する。解決できないときは `related_issue_unresolved` で fail-loud する。
**Condition**: 常に評価する。投稿しない判定は helper（本文検査 4 段通過後、0 件 ∧ 既存なし → `outcome=skipped`）。検査失敗は `outcome=failed`。0 件でも既存があれば update-in-place。lookup degraded 時は既存を見逃し `skipped; degraded=1` になりうる。

> rationale: [references/measured-gate-record.md#single-invocation](references/measured-gate-record.md#single-invocation)

**実行手順**:

1. **コメント本文生成 + Write**: Claude はコメント本文を生成し、**Write tool で `{review_tmp_dir}/rite-nonblocking-{pr_number}-{review_cycle_id}.md` に保存**する (`{review_tmp_dir}` / `{review_cycle_id}` は ステップ 6.1.a step 0 の `[CONTEXT] REVIEW_TMP_DIR=` / `REVIEW_CYCLE_ID=` marker 値をリテラル置換。**パスに cycle 識別子を含めるのは必須** — 含めないと `${TMPDIR}` がセッション内で不変なため前 cycle の本文が同一パスに残り、step 1 を飛ばして step 2 だけ実行したときに前 cycle の内容で canonical コメントを上書きしてしまう。cycle 識別子を含めれば同じ状況が `content_file_missing` の loud fail として現れる)。本文は件数で 2 variant — **どちらも 1 行目を marker 見出し `## 📜 rite 非実測指摘の記録` にし、末尾に `📎 reviewed_commit: {current_commit_sha}` と機械専用 sentinel `<!-- rite:nbr:v1 -->` を置く** (`{current_commit_sha}` は ステップ 1.2.5 で取得した実 SHA にリテラル置換する — 未置換のまま投稿しても helper の本文検査は非空 / 1 行目 marker / sentinel / `📎 non_blocking_count:` の 4 段のみで `{current_commit_sha}` 自体は検査対象外のため素通りする。1 行目 marker と sentinel は helper の lookup 述語の needle であり、どちらを落としても update-in-place が恒久破綻する。sentinel は rendered view に現れない HTML コメントで、**同一 author が marker で始まる見出しの人間コメントを書いた場合に PATCH 先を奪われるのを防ぐ**ためにある。`📎 reviewed_commit:` 行は「この記録がどの commit 時点のレビューで作られたか」を関連 Issue 上で人間が追うためのもので、機械 consumer は持たない):
   > **本文は列 0 から書き出すこと (字下げ禁止)** — 下記 variant A / B のテンプレートは本手順が番号付きリスト項目の内側にあるため、表示上は全行が 3 スペース字下げされている。**Write する本文にはこの字下げを含めてはならない**。helper の本文検査 4 段のうち 3 段は先頭空白を許容しない (1 行目 marker は `case "$(head -n 1 ...)" in "$MARKER"*)`、機械専用 sentinel は最終非空行との厳密等値、件数行は `grep -E '^📎 non_blocking_count:...'`)。字下げたまま転記すると毎 cycle `body_marker_missing` で `outcome=failed` となる (本文検査は逐次評価で最初の失敗段で終了するため、後続の `body_sentinel_missing` / `count_body_mismatch` には到達しない)。この 4 reason (`body_file_empty` / `body_marker_missing` / `body_sentinel_missing` / `count_body_mismatch`) は caller 契約違反として **pending marker を残す**ため、ステップ 8.0.3 の機械強制が `exit 1` で 6.1.d へ差し戻し、本文を作り直せば 1 iteration で収束する (result pattern の emit は止まるが `overall_assessment` は変わらない)。
   **variant A (`non_blocking_count >= 1`)**:

   ```markdown
   ## 📜 rite 非実測指摘の記録 (non-blocking)

   以下の指摘は、runtime 実測 (再現手順 / failing test) を伴わないため実測必須ゲートにより、
   または実測付きでも帰結が検出網・可読性・文書整合に留まる class B のため帰結クラス降格政策により、
   **non-blocking** に分類されました (mergeable 判定を block しません)。マージ後に人間が
   拾い直せるようここに記録します。

   | レビュアー | 重要度 | ファイル:行 | 降格理由 |
   |-----------|--------|------------|---------|
   | {reviewer_type} | {severity} | {file}:{line} | {demotion_label} |

   > 各指摘の詳細 (description / suggestion) は、**cycle 中は**このレビューを実行した環境の `<main checkout の repo root>/.rite/review-results/{pr_number}-*.json` の `non_blocking_findings[]` にあります (session worktree で実行した場合も worktree 側ではなく main checkout 側。`state-path-resolve.sh` の解決先)。PR には含まれず、checkout でも取得できません。マージ時の残存分は `/rite:cleanup` が follow-up Issue 1 件へ全文転記し、同 JSON を `.rite/review-results/archive/` へ退避します。**`.gitignore` が `.rite/review-results/` を除外していることを確認してください** (`/rite:setup` が追加します。未除外だと退避した全文が `git add -A` で公開リポジトリへ入ります)。
   📎 non_blocking_count: {non_blocking_count}
   📎 reviewed_commit: {current_commit_sha}

   <!-- rite:nbr:v1 -->
   ```

   `non_blocking_findings` 全件を列挙する。**情報源はゲート適用済 JSON の `non_blocking_findings[]`**。`{demotion_label}` は要素が `demotion` キーを持つとき `class B 降格: {demotion.reason}`、持たないとき `実測なし`。
   **本文に載せるのはポインタ (reviewer / severity / `file:line`) と降格理由 (`demotion.reason` の判定文、class B 降格分のみ — 5.3.0.C 由来) で、finding の `description` / `suggestion` を一切含めてはならない** (判定文は finding 本文の言い換えではなく降格の帰属を示す認定文であること)。**表の外に別形式で全文を再掲載することも禁止する** — 禁止しているのは列ではなく本文への全文掲載そのものであり、箇条書き・脚注・追加 fence など形式を問わない。既定構成 `post_comment: false` では経路 (1) の永続 JSON (`.rite/review-results/{pr_number}-{timestamp}.json` の `non_blocking_findings[]`。同秒衝突時は `~xxxx` suffix が付くため本文では glob 形で示す) が **cycle 中の**全文の唯一の保存先であり（マージ時の残存分は follow-up Issue へ全文転記される）、表直下の 1 行でその所在を必ず明記する (`post_comment: true` では経路 (3) の統合レポートが全文を PR へ載せるため「唯一」ではなくなる — 本 Issue の対象外)。`file:line` を持たない finding は**行ごと落とさず** `file:line` セルを `-` にする。
   rationale: [references/measured-gate-record.md#pointer-only](references/measured-gate-record.md#pointer-only)
   `{non_blocking_count}` は同配列の要素数 (5.3.0.C の降格が発動した cycle は移送後の値で、5.3.0.M の `non_blocking_total=` より大きくなる。それ以外の cycle は 5.3.0.M の `[CONTEXT] MEASURED_GATE=...; non_blocking_total=` の値と一致する)。**`📎 non_blocking_count: {non_blocking_count}` 行は必須** — helper (ステップ 6.1.d step 2) が本文が申告する件数 (`📎 non_blocking_count:` 行の値) と caller が渡す `--count` の整合を検査する唯一の手掛かりであり、欠落すると `count_body_mismatch` として `outcome=failed` になる (下記参照)。**表の行数そのものは検査対象外** — 申告値と表の行数が食い違う (例: 5 件と申告しながら 3 行しか列挙しない) ケースは caller 側の責務であり、helper は検出しない。**本行は本文中に 1 本だけ置く** — helper は複数一致時に末尾の 1 本 (`tail -1`) を採るため、複数置くと意図しない行が照合対象になる。
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

   **step 1.5 却下台帳保全**: Write 後・helper 前に、既存 6.1.d 本文の `### 却下台帳` を新本文へ splice する。空 ledger は no-op。merge-into 失敗は fail-loud（本文を helper に渡さない）。本文は列 0 から。

   ```bash
   # ステップ 6.1.d step 1.5: 却下台帳を新本文へ splice（空なら no-op）
   body_file={review_tmp_dir}/rite-nonblocking-{pr_number}-{review_cycle_id}.md
   ledger_file={review_tmp_dir}/rite-rejected-ledger-{pr_number}-{review_cycle_id}.md
   existing_file={review_tmp_dir}/rite-nb-existing-{pr_number}-{review_cycle_id}.md
   : > "$ledger_file"
   related={issue_number}
   if [ -n "$related" ] && [ "$related" != "0" ]; then
     if gh api "repos/{owner_repo}/issues/${related}/comments" --paginate \
       --jq '.[] | select(.body | startswith("## 📜 rite 非実測指摘の記録")) | .body' \
       > "$existing_file"; then
       if [ -s "$existing_file" ]; then
         bash {plugin_root}/hooks/scripts/nb-sweep-ledger.sh extract --body-file "$existing_file" > "$ledger_file" || true
       fi
     else
       echo "ERROR: 既存 6.1.d コメント取得失敗" >&2
       echo "[CONTEXT] REJECTED_LEDGER_PRESERVE=failed" >&2
       exit 1
     fi
   fi
   bash {plugin_root}/hooks/scripts/nb-sweep-ledger.sh merge-into --body-file "$body_file" --ledger-file "$ledger_file" || {
     echo "ERROR: 却下台帳 merge-into 失敗" >&2
     echo "[CONTEXT] REJECTED_LEDGER_PRESERVE=failed" >&2
     exit 1
   }
   echo "[CONTEXT] REJECTED_LEDGER_PRESERVE=ok" >&2
   ```

2. **記録 (単一 invocation、update-in-place 冪等 + 非ブロッキング契約)**: 以下の bash を **1 回だけ**実行する。`{non_blocking_count}` は `non_blocking_findings` の件数 (0 件でも `0` を明示置換)、`{owner_repo}` は Placeholder Legend の [Owner/Repo Resolution](../../references/gh-cli-patterns.md#ownerrepo-resolution-ssh-host-alias-safe) で解決した slash 形式の値、`{review_cycle_id}` は ステップ 6.1.a step 0 の `[CONTEXT] REVIEW_CYCLE_ID=` marker 値、`{review_tmp_dir}` は同 step 0 の `[CONTEXT] REVIEW_TMP_DIR=` marker 値をそれぞれリテラル置換する:

   ```bash
   # ステップ 6.1.d: review-nonblocking-record.sh へ委譲。契約 SoT は helper docstring。
   # rationale: references/measured-gate-record.md#single-invocation
   bash {plugin_root}/hooks/review-nonblocking-record.sh \
     --pr {pr_number} \
     --owner-repo {owner_repo} \
     --count {non_blocking_count} \
     --iteration-id {review_cycle_id} \
     --content-file {review_tmp_dir}/rite-nonblocking-{pr_number}-{review_cycle_id}.md
   ```

   記録の成否は `overall_assessment` を変えない (AC-3)。本文検査 4 段と caller 契約違反 7 種は pending marker が残り 8.0.3 が差し戻す。degraded は silent 縮退しない。`related_issue_unresolved` は trap 設置後の `exit 1` だが pending marker は削除済み・sentinel は `outcome=failed` — helper の非ゼロ rc を skill 全体の hard fail と読んではならない。sentinel を読んでステップ 3 / 8.0.3 へ進む（差し戻しても PR body / branch は同 cycle 内で直せず収束しない。6.1.a が `signal_aborted` の非ゼロ rc でも停止しないのと同型）。
3. **integrity check (6.1.d 内部)**: 6.1.d を丸ごと skip した場合の保証にはならない。全体 skip の防波堤は **ステップ 8.0.3**。**両者は同一の述語を異なる位置で評価する**。
   **Check**: 会話コンテキストに `[CONTEXT] NONBLOCKING_RECORD_DONE=1; ...; iteration_id={ID}` が存在し、その `iteration_id=` が **本 cycle の `REVIEW_CYCLE_ID`** と一致するか。**本 cycle の `REVIEW_CYCLE_ID` = 直近に emit された `[CONTEXT] REVIEW_CYCLE_ID=` の値** (review-fix loop の cycle 2+ では会話に複数存在するため、`{pr}-{epoch}` の epoch が最大のものを採る。ステップ 8.0.2 の iteration_id 最大採用と同型)。**同一 `iteration_id` の sentinel が複数ある場合は最後に emit されたものを採る** — 本文検査 4 段の差し戻しは同一 cycle 内での 6.1.d 再実行を強制するため、解決済みの 1 回目 (`outcome=failed`) と再実行後 (`outcome=created` 等) が並ぶ。古い方を拾うと解決済みの失敗を completion report へ誤転記する。

   | Condition | Action |
   |-----------|--------|
   | sentinel あり かつ `iteration_id` が本 cycle の `REVIEW_CYCLE_ID` と一致 (`outcome` は問わない) | Gate passes — ステップ 6.2 へ。`outcome=failed` / `aborted`、`degraded=1`（`outcome` を問わない）、または `NONBLOCKING_LEGACY_ORPHAN=1` / `NONBLOCKING_DUPLICATE_RECORD=1` を観測したときは (ステップ 8.0.3 と同一条件 — 片側だけに置かない) helper の WARNING / `NONBLOCKING_RECORD_FAILED` の reason を completion report に転記する (判定は不変、AC-3) |
   | sentinel なし、または `iteration_id` が本 cycle の `REVIEW_CYCLE_ID` と不一致 (前 cycle のもの) | **ERROR**: 6.1.d が本 cycle で未評価。下記 ACTION を実行 |

   **On ERROR**:

   ```
   ERROR: ステップ 6.1.d integrity check failed.
   No current-cycle [CONTEXT] NONBLOCKING_RECORD_DONE=1 sentinel found.
   ACTION: 本 cycle の NONBLOCKING_RECORD_FAILED を探す (step 2 より後ろの行のみ。iteration_id 無し)。
   あれば reason を直し step 1-2 再実行。iteration_id_placeholder_residue は 6.1.a step 0 まで戻る。
   無ければ 6.1.d 未実行 — step 1 から実行。Do NOT emit result pattern without current-cycle sentinel.
   ```

   本 gate は prose。ERROR を認識して 6.1.d step 1 に戻る。

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

lock 失敗は WARNING 継続（best-effort）。non-lock 失敗も WARNING + stderr 5 行で継続。
**Step 2: Issue comment へ backup sync**。

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

`metrics.enabled: false` なら skip。それ以外は本 cycle の metrics を記録する。
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

default 経路の metrics は JSON に埋め込まない。
rationale: references/design-rationale.md#metrics-no-json-embed
`post_comment_mode=true` では 6.1.b step-1 のコメント本文末尾（Raw JSON 直前）に含める。

### 6.4 Update Issue Work Memory

> **Reference**: Update work memory per `work-memory-format.md`. Append review history and update next steps.

**Steps:**

API はすべて `issue-comment-wm-sync.sh`（直接 `gh api` しない）。
1. **Update session info** (defense-in-depth)
2. **Append review history**
3. **Update next steps**
rationale: references/design-rationale.md#p64-defense-in-depth

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

Steps 1-3 は 6.2 の local WM（SoT）と Issue comment（backup）を揃える。

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

完了報告のあと Wiki Ingest を trigger する。
**Condition**: `wiki.enabled: true` かつ `wiki.auto_ingest: true`。設定 skip は正当 skip の唯一の経路で、`WIKI_INGEST_SKIPPED=1` を必ず emit する。
rationale: references/design-rationale.md#wiki-skip-emit-and-write-failed
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
Wiki 記録が有効な場合だけ [Wiki 記録・raw commit 手順](references/wiki-recording.md) を読み、残りの ingest・commit・push 再試行を実行する。未完了時の通知まで適用してからステップ 6.5.1 へ進む。

#### 6.5.1 Next Step Branching by Invocation Source

完了報告後の分岐は起動元で変わる。conversation context から判定する:

| Condition | Determination |
|------|---------|
| Conversation history has a record of `rite:pr-review` being invoked via native `Skill` or equivalent body execution by a caller | Within loop -> Automatically execute the next step |
| Otherwise (user directly entered `/rite:pr-review`) | Standalone execution -> Confirm the next action with `AskUserQuestion` |

判定方法は lint / fix と同じ。

---

**When invoked from within the `/rite:iterate` loop:**
**Step 1: Process recommendation-based Issue candidates (ステップ 7)**
result pattern の前に ステップ 7.1-7.4 を実行する:
- 7.1 で候補抽出（Source A のスコープ外 + Source B。スコープ内 findings は fix loop）
- 候補あり: 7.2-7.3。可逆な Decision Log は自動、ユーザー固有・不可逆だけ `AskUserQuestion`
- 候補なし: silent skip

**Condition**: `[review:mergeable]` のときだけ。`[review:fix-needed:N]` では ステップ 7 を skip する。
rationale: references/design-rationale.md#step7-mergeable-only

**Step 2: Output the result pattern**

| Overall Assessment | Output Pattern |
|---------|------------------------|
| **Merge OK** (`total_findings == 0` = blocking findings ゼロ) | `[review:mergeable]` |
| **Requires fixes** (`total_findings >= 1`) | `[review:fix-needed:{total_findings}]` |

> `total_findings` は blocking 集合の件数 (実測必須ゲートで降格された非実測指摘と scope=nit-noted を除く)。非実測指摘のみが残る場合は `[review:mergeable]` が正しい (AC-2、ステップ 8.1 の同注記を参照)。

loop 内では pattern だけ出す。続きは `/rite:iterate` ステップ 1-4。

---

**When `/rite:pr-review` is executed standalone:**
次アクションは `AskUserQuestion`。形式は ステップ 1.4 の AskUserQuestion invocation format。
**Merge OK**: Ready for review（推奨）→ `rite:ready` | Keep draft | Additional fixes → 終了
**要修正**: Handle findings（推奨）→ `rite:fix` | Handle later → ステップ 7
**⚠️ Important**: standalone は必ず `AskUserQuestion`。完了後に ステップ 7 へ。

---

## ステップ 7: スコープ外指摘のトリアージ

<!-- 3 バイアスと先延ばし禁止の設計原則: rationale: references/design-rationale.md#step7-triage-redesign-notes -->

### 7.1 Extract Separate Issue Candidates

候補は **2 source**:
**Source A**: MEDIUM+ かつキーワード（`スコープ外` / `別 Issue` / `out of scope` / `separate issue` 等）。
**Source B**: `recommendation_items` の `actionable` または `boundary`。`design_confirmation` は除外。

**`candidate_count` assignment**:

dedup 後の合算を `candidate_count` として保持する。7.2 sentinel の `{N}` に使い（自動 Decision Log 経路でも emit する）、7.7 / 8.0.2 の trigger になる。


同一 file:line は Source A を残す。
**元 Issue**: `{head_ref}` から issue 番号を抽出し `{source_issue_number}` とする。取れなければ空（7.2 で「Decision Log に記録」を非表示）。
Source A は `Likelihood-Evidence:` の有無を保持する。

### 7.2-7.3 推奨決定 + User Confirmation

`candidate_count == 0` なら 7.2〜7.7 をスキップする。1 件以上なら [スコープ外指摘のトリアージ手順 7.2〜7.7](references/scope-triage.md) を読み、モードに応じた確認・処分・post-condition gate まで完了する。既存の `PR_REVIEW_IN_E2E` と `source_issue_number` を引き継ぐ。失敗時は同手順の停止規則に従い、成功後だけステップ 8 へ進む。

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

result pattern の前に flow-state を更新する（defense-in-depth）。
継続は `--handoff "/rite:fix {pr_number}"`、終了は `--handoff "FINALIZE:review:mergeable:{pr_number}"`。[stop-loop-continuation-contract.md#mechanism](../../references/stop-loop-continuation-contract.md#mechanism)
rationale: references/design-rationale.md#defense-in-depth-handoff
**Condition**: flow-state があるときだけ（E2E）。standalone は skip。

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

`{next_action_value}` / `{pr_number}` / `{n}` を表どおり埋める。両 variant とも `--handoff` を付ける。
**Gate evaluation order (SoT)**: 状態更新のあと、result の前に記載順で評価する。**全 gate pass のときだけ 8.1 へ**。ERROR ならその ACTION へ戻り 8.0 から再評価。

```
8.0.1 (W Phase / Wiki ingest) → 8.0.2 (ステップ 7 disposition) → 8.0.3 (ステップ 6.1.d 非実測記録) → 8.0.4 (ステップ 6.1.a JSON 保存) → ステップ 8.1
```

各 gate の Routing 表は「次の gate へ」とだけ書く（終端は順序規定側）。8.0.5+ 追加時の pin 更新手順: rationale [references/measured-gate-record.md#gate-order](references/measured-gate-record.md#gate-order)

### 8.0.1 W Phase Completion Gate (Defense-in-Depth)

6.5.W 未実行のまま result を出すのを止める。実行済みなら `WIKI_INGEST_` が 1 つ以上残る。
**Condition**: E2E かつ `wiki.enabled: true`。wiki disabled なら無条件 pass。
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

本 gate は prose。ERROR を認識して 6.5.W に戻る。
rationale: references/design-rationale.md#w-phase-gate-sole

### 8.0.2 ステップ 7 Post-condition Gate Reference

7.7 を cross-reference する result-emit 前の defense-in-depth（sentinel 有無。7.7 実行の有無には依存しない）。
**Condition**: `candidate_count >= 1`。0 なら skip。
**Check**: 最新 `PHASE_7_ASKUSER_INVOKED`（iteration_id 最大）。`mode=` / `choice=` / `reason=` が全て非空であること。
**Routing** (8.0.1 と対称):

| Condition | Action |
|-----------|--------|
| `candidate_count == 0` (ステップ 7 skipped) | Gate passes — proceed to the next gate in the 8.0 evaluation order |
| Latest sentinel found with `candidates >= 1` AND iteration_id matches current cycle AND `mode=` / `choice=` / `reason=` が全て非空 | Gate passes — proceed to the next gate in the 8.0 evaluation order |
| Latest sentinel found with matching iteration_id but `mode=` / `choice=` / `reason=` のいずれかが欠落 | **ERROR**: sentinel が確認証跡を欠く。Execute ACTION below |
| Latest sentinel NOT found AND `candidate_count >= 1` | **ERROR**: ステップ 7 entire procedure (7.1-7.7) was skipped. Execute ACTION below |
| Latest sentinel found but iteration_id is stale (cycle N-1, not current cycle N) | **ERROR**: ステップ 7 was skipped in current cycle. Execute ACTION below |

**On ERROR** (`mode=` / `choice=` / `reason=` 欠落 = emit-before-evidence。sentinel は current-cycle に存在する):

```
ERROR: ステップ 8.0.2 ステップ 7 Post-condition Gate failed.
current-cycle [CONTEXT] PHASE_7_ASKUSER_INVOKED sentinel は存在するが確認証跡 (mode=/choice=/reason=) を欠く（emit-before-evidence）。
ACTION: Return to ステップ 7.2 only. complete confirmation (対話は回答後、E2E 自動は判定確定後), emit the sentinel with mode/choice/reason, then re-enter ステップ 8.0. Do not run 7.4 before that sentinel. Do not re-run 7.1.
⚠️ LLM MUST NOT output [review:mergeable] or [review:fix-needed:{n}] until ステップ 7 has been executed for the current cycle.
```

**On ERROR** (sentinel absent or stale, `candidate_count >= 1`):

```
ERROR: ステップ 8.0.2 ステップ 7 Post-condition Gate failed.
candidate_count = {N} (>= 1) but no current-cycle [CONTEXT] PHASE_7_ASKUSER_INVOKED sentinel found.
This means ステップ 7 (entire procedure 7.1 candidate extraction → 7.2 disposition handling → 7.7 gate) was NOT executed in the current review cycle.
ACTION: Return to ステップ 7.2, complete confirmation (対話は回答後、E2E 自動は判定確定後), emit the sentinel with mode/choice/reason, then re-enter ステップ 8.0. Do not run 7.4 before that sentinel. 7.1 からの再抽出は sentinel 不在 / stale に限定する。
⚠️ LLM MUST NOT output [review:mergeable] or [review:fix-needed:{n}] until ステップ 7 has been executed for the current cycle.
```

7.7 と 8.0.2 が catch する failure mode は異なる。
rationale: references/design-rationale.md#phase7-gate-notes

### 8.0.3 ステップ 6.1.d Post-condition Gate Reference

6.1.d 全体 skip の最終防波堤（ステップ 6 全体は 8.0.4）。[measured-gate-record.md#dual-gate](references/measured-gate-record.md#dual-gate)
**Condition**: 常時。ただし **ステップ 6 が hard fail した場合を除く**。
**Pre-Check**: `{pending_marker}` は本 cycle の `NONBLOCKING_PENDING_MARKER`（epoch 最大。空 emit なら空優先）。[measured-gate-record.md#pending-marker](references/measured-gate-record.md#pending-marker)

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
      echo "  ACTION: まず会話に [CONTEXT] NONBLOCKING_RECORD_FAILED=1; reason=body_file_empty / body_marker_missing / body_sentinel_missing / count_body_mismatch のいずれかがあるか確認してください (body_check_unavailable は対象外)。" >&2
      echo "    あれば caller 契約違反です — step 1 の**本文を作り直してから** step 2 を再実行します。" >&2
      echo "    無ければ 6.1.d 自体が未実行です — step 1 (本文 Write) と step 2 (helper 実行) を実行してください。" >&2
      echo "  そのうえで ステップ 8.0 を再評価。marker はここでは削除しません。" >&2
      echo "  ⚠️ 本 gate を pass せずに ステップ 8.1 の result pattern を emit してはなりません。" >&2
      echo "[CONTEXT] NONBLOCKING_GATE_FAILED=1; reason=pending_marker_present; marker=$pending_marker" >&2
      exit 1
    fi
    echo "[CONTEXT] NONBLOCKING_GATE=pass; reason=pending_marker_absent" >&2
    ;;
esac
```

`NONBLOCKING_GATE` marker の分岐（本節に 2 つ目の表を置かない）:

- `pass` → 機械強制を通過。下記 `**Check**` へ。
- `degraded` → marker が使えない環境。機械強制を skip し `**Check**` の prose 判定のみで続行。
- bash が `exit 1`（`NONBLOCKING_GATE_FAILED=1`）→ ステップ 6.1.d へ戻る。**ステップ 8.1 へ進んではならない**。

**Check**: `[CONTEXT] NONBLOCKING_RECORD_DONE=1; ...; iteration_id={ID}` を探し、`iteration_id=` が **本 cycle の `REVIEW_CYCLE_ID`** と一致するか。**本 cycle の `REVIEW_CYCLE_ID` = 直近の `[CONTEXT] REVIEW_CYCLE_ID=`**（epoch 最大）。**同一 `iteration_id` が複数なら最後に emit されたもの**。**6.1.d step 3 と同一の述語**。Pre-Check が `pass` でも省略しない。

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
(注: pending_marker_present 時は sentinel があっても caller 契約違反の差し戻し — body_* / count_body_mismatch reason を読む)
ACTION: 本 cycle の NONBLOCKING_RECORD_FAILED があれば reason を直して 6.1.d step 1-2 再実行。
iteration_id_placeholder_residue は 6.1.a step 0 まで戻る。無ければ 6.1.d steps 1-3 を実行し re-enter ステップ 8.0。
⚠️ MUST NOT emit result pattern until 6.1.d has been executed for the current cycle.
```

<!-- dual placement: rationale references/measured-gate-record.md#dual-gate -->

### 8.0.4 ステップ 6.1.a Post-condition Gate Reference

6.1.a / ステップ 6 全体 skip の最終防波堤。機械強制は save-pending marker + 結果 JSON 実在の二層。[measured-gate-record.md#save-pending-marker](references/measured-gate-record.md#save-pending-marker)
**Condition**: 常時。ただし **ステップ 6 が hard fail した場合を除く**。
**Pre-Check**: `{pr_number}` / `{current_commit_sha}` / `{save_pending_marker}` をリテラル置換。

```bash
save_pending_marker="{save_pending_marker}"
case "$save_pending_marker" in
  "{"*"}")
    echo "WARNING: ステップ 8.0.4 の {save_pending_marker} が literal substitute されていません (値: '$save_pending_marker')。機械強制を skip し Check の prose 判定のみで続行します" >&2
    echo "[CONTEXT] REVIEW_SAVE_GATE=degraded; reason=save_pending_marker_placeholder_residue" >&2
    ;;
  "")
    echo "[CONTEXT] REVIEW_SAVE_GATE=degraded; reason=save_pending_marker_unavailable" >&2
    ;;
  *)
    if [ -e "$save_pending_marker" ] || [ -L "$save_pending_marker" ]; then
      echo "ERROR: ステップ 8.0.4 gate failed (機械強制)。save-pending marker が残存しています: $save_pending_marker" >&2
      echo "  ACTION: ステップ 6.1.a を **step 0 から** 実行 (step 2 単独禁止 — step 0 が REVIEW_CYCLE_ID / pending marker を生成)。続けて post_comment_mode に応じ 6.1.b または 6.1.c を再実行し、ステップ 8.0 を再評価。" >&2
      echo "  --pending-id は本 cycle の REVIEW_SAVE_PENDING_ID と一致させること。marker はここでは削除しません。" >&2
      echo "  ⚠️ 本 gate を pass せずに ステップ 8.1 の result pattern を emit してはなりません。" >&2
      echo "[CONTEXT] REVIEW_SAVE_GATE_FAILED=1; reason=save_pending_marker_present; marker=$save_pending_marker" >&2
      exit 1
    fi
    echo "[CONTEXT] REVIEW_SAVE_GATE=pass; reason=save_pending_marker_absent" >&2
    ;;
esac
# positive 検査は marker 層の **3 arm すべてを通す** (marker 残存を検出した枝だけは `*)` arm 内の `exit 1` で本 helper に到達しない) — marker の不在は「6.1.a が完走した」と「5.3.0.M〜6.1.a を区間ごと skip した」を区別できず、marker 値が空文字 / 未置換になる cycle (AC-2 の Given そのもの) では marker 層が degraded に降りるため、`*)` arm の内側に置くと守るべき経路でだけ機械強制が働かない。本検査の入力 (ステップ 1.2.5 の commit SHA と disk 上の JSON) は marker に一切依存しない。失敗のときだけ非ゼロで返る。
bash {plugin_root}/hooks/scripts/review-save-json-verify.sh --pr "{pr_number}" --commit-sha "{current_commit_sha}" || exit 1
```

`REVIEW_SAVE_GATE` の分岐（表にしない）。**2 層**を順に評価する。**pass は `REVIEW_SAVE_GATE_FAILED=1` が無く rc=0 のときだけ**。**`degraded` を `pass` と読み替えてはならない**:

- `pass`（marker 層、`reason=save_pending_marker_absent`）→ 6.1.a が本 cycle で完走した証拠。`[CONTEXT] REVIEW_SAVE_JSON_OK=1; pr={n}; result_json={basename}`（positive 層、reason を持たない observability marker）→ 本 cycle の結果 JSON が現 run に実在し、どのファイルで通ったかを開示する。両方が出れば `**Check**` へ。
- `degraded` → marker が使えない環境（`..._placeholder_residue` / `..._unavailable`）、または positive 検査の入力・環境が揃わない（`save_result_json_undecidable`）。**当該層の機械強制のみ**を skip する — marker 層が degraded でも positive 層は通常どおり実行される（入力が marker に依存しないため）。
- bash が `exit 1`（`REVIEW_SAVE_GATE_FAILED=1`）→ ステップ 6.1.a へ戻る（**会話に本 cycle の `REVIEW_SAVE_PENDING_MARKER` / `REVIEW_SAVE_PENDING_ID` が 1 つも無い場合の戻り先は ステップ 5.3.0.M step 2**。helper の ACTION 行が SoT）。**ステップ 8.1 へ進んではならない**。`reason=save_pending_marker_present` は 6.1.a が本 cycle で走っていない証拠、`reason=save_result_json_absent` は「区間ごと未実行」または「本 cycle 分だけ未保存」で、後者は helper が出す JSON 一覧（期待 SHA と実在ファイルの `commit_sha`）で切り分ける。**helper が marker を 1 つも出さずに非ゼロ終了した場合**（`exit 2` = 未知オプション / rc=127 = helper 不在・版 skew）は 6.1.a へ戻さず `[review:error]` を stdout に出力して停止する（skill 定義のバグ / プラグイン破損であり 6.1.a の再実行では収束しない。ステップ 5.3.0.M step 3 の同型行と同じ扱い）。

**Check**: `[CONTEXT] REVIEW_SAVE_DONE=1; ...` の `marker=` が **本 cycle の `REVIEW_SAVE_PENDING_MARKER`** と一致するか。空 marker の degraded では 5.3.0.M step 2 より後ろの `REVIEW_SAVE_DONE` を採る。Pre-Check `pass` でも省略しない。
**Routing** (ステップ 8.0.1 / 8.0.2 / 8.0.3 と完全に対称):

| Condition | Action |
|-----------|--------|
| ステップ 6 が 6.1.b hard error / 6.1.c ケース 2 (`exit 2`) で fail している | Gate は legitimately skipped — ステップ 6 の失敗として扱う (6.1.c ケース 2 は保存失敗そのものを既に loud に報告しており、本 gate で二重に差し戻さない) |
| sentinel found AND `marker` == 本 cycle の `REVIEW_SAVE_PENDING_MARKER` | Gate passes — `saved=false` で本行に到達するのは **HEAD 不変の cycle か、positive 層が degraded に降りた cycle** (新規 commit を伴う cycle は positive 層が degraded でない限り Pre-Check が先に `exit 1` する)。その場合は **LLM が `LOCAL_SAVE_FAILED` の reason を completion report に転記してから** the next gate in the 8.0 evaluation order へ進む (非ブロッキング契約により判定は不変) |
| sentinel NOT found (ステップ 6 は正常完了している) | **ERROR**: ステップ 6.1.a was skipped in current cycle. Execute ACTION below |
| sentinel found but `marker` != 本 cycle の `REVIEW_SAVE_PENDING_MARKER` (cycle N-1 のもの) | **ERROR**: ステップ 6.1.a was skipped in current cycle. Execute ACTION below |

**On ERROR** (sentinel absent or stale):

```
ERROR: ステップ 8.0.4 ステップ 6.1.a Post-condition Gate failed.
No current-cycle [CONTEXT] REVIEW_SAVE_DONE=1 sentinel found (absent, or marker != REVIEW_SAVE_PENDING_MARKER).
ACTION: 6.1.a を **step 0 から** 実行 (step 2 単独禁止)。step 0 → step 2 → 6.1.b/c の順、then re-enter ステップ 8.0。
rm 失敗 WARNING 時は marker を手動削除してから再評価。
⚠️ MUST NOT emit result pattern until 6.1.a has been executed for the current cycle.
```

### 8.1 Output Pattern (Return Control to Caller)

Based on the ステップ 6 review results, output the corresponding machine-readable pattern:

| Condition | Output Pattern |
|-----------|---------------|
| `total_findings == 0` (blocking findings ゼロ) | `[review:mergeable]` |
| `total_findings >= 1` (blocking findings あり) | `[review:fix-needed:{total_findings}]` |

> **`total_findings` は blocking 集合の件数**。5.3.0.M で降格した指摘と scope=nit-noted は含まない（[assessment-rules.md §5.3.3](../fix/references/assessment-rules.md)）。非実測が N 件でも `total_findings == 0` なら `[review:mergeable]`（AC-2）。

**E2E suffixes**: 常に末尾へ `| ci: {ci_state}` を付ける。 `non_blocking_count > 0` なら `| non-blocking: {n}`。`measurement_blocked_count > 0` なら `| measurement-blocked: {n}`。fact-check 実行時は `| fact-check: ...`。`{total_findings}` は post-fact-check。
**⚠️ aggregate label 禁止**: result / E2E 行に **「推奨 N 件」「follow-up 候補 N 件」を含めてはならない**。
rationale: references/design-rationale.md#aggregate-label-ban

**Important**:
- **[READ-ONLY RULE]**: `Edit`/`Write` ツールでプロジェクトのソースファイルを修正してはなりません。`Bash` で working tree / index / ref を変更する git コマンド（`git checkout` / `git reset` / `git add` / `git stash` / `git restore` / `git rebase` / `git commit` / `git push` 等）も **禁止** です。許可される read-only git コマンドの完全一覧は `plugins/rite/agents/_reviewer-base.md` の `## READ-ONLY Enforcement` を single source of truth として参照してください。指摘がある場合は `[review:fix-needed:{n}]` を出力し、修正は `/rite:fix` に委譲してください
- Do **NOT** invoke `rite:fix` or `rite:ready` via the Skill tool
- Return control to the caller (`/rite:iterate`)
- The caller determines the next action based on this output pattern
- The prohibited actions defined in ステップ 5.3.7 "Prohibition of Independent Judgment After Assessment" also apply here

**"Merge OK" だが `total_findings > 0`**: `[review:fix-needed:{total_findings}]` に補正する。
**⚠️ 非実測 non-blocking のみが残る場合は correct しない**: `total_findings == 0` なら `[review:mergeable]`（AC-2）。`[review:fix-needed:0]` へ override しない。
rationale: references/design-rationale.md#mergeable-zero-findings-no-override

**Example output:**
```
📜 rite レビュー結果

総合評価: マージ可
指摘: 0件

[review:mergeable]
```

### 8.2 Standalone Execution Behavior

standalone では ステップ 8 を実行しない。ステップ 6.5 の `AskUserQuestion` で終える。
