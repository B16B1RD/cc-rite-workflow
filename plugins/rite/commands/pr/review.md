---
description: マルチレビュアー PR レビューを実行
---

# /rite:pr:review

## Contract
**Input**: PR number (or auto-detected from current branch), `.rite-flow-state` with `phase: phase5_review` (e2e flow)
**Output**: `[review:mergeable]` | `[review:fix-needed:{n}]`

Analyze PR changes and dynamically load expert skills to perform a multi-reviewer review.

> **[READ-ONLY RULE]**: このコマンドはレビュー専用です。`Edit`/`Write` ツールでプロジェクトのソースファイルを修正してはなりません。コードの問題を検出した場合は、`[review:fix-needed:{n}]` パターンを出力し、修正は `/rite:pr:fix` に委譲してください。`Bash` ツールは workflow 操作（`gh` CLI、hook scripts、`.rite-flow-state` 更新）と **read-only な git コマンド**（`git diff` / `git log` / `git show` / `git worktree add` などを含む — 完全な許可・禁止一覧は [`_reviewer-base.md#read-only-enforcement`](../../agents/_reviewer-base.md#read-only-enforcement) を single source of truth として参照）のみ許可されます。working tree / index / ref を変更する git コマンド（`git checkout` / `git reset` / `git add` / `git stash` / `git restore` / `git rebase` / `git commit` / `git push` 等）は **禁止** です。

## Prerequisites

**bash 4.0+ 必須**: 本コマンドは Phase 1.2.7 の `all_files_excluded` bash impl で `mapfile -t changed_file_paths < "$gh_files_stdout"` builtin を使用する。Phase 1.0 の統合 bash block 冒頭 (Step 0) に [bash-compat-guard.md](../../references/bash-compat-guard.md) の canonical guard を **inline embed 済み** (C-3 対応)。prose 参照ではなく実行可能な bash コードとして配置されており、Claude は Phase 1.0 bash block を実行するだけで guard が発火する。失敗時は `[CONTEXT] REVIEW_ARG_PARSE_FAILED=1; reason=bash_version_incompatible` を emit して `[review:error]` で exit する。

## E2E Output Minimization

When called from the `/rite:issue:start` end-to-end flow, Phase 4 (sub-agent execution) runs in **full** — only Phase 5-7 **output** is minimized to reduce context window consumption:

| Phase | Standalone | E2E Flow |
|-------|-----------|----------|
| Phase 4 (Sub-Agent Execution) | Full execution | **Full execution** — sub-agents MUST run in parallel for every review cycle (including verification mode). No shortcut allowed. |
| Phase 5 (Consolidation) | Full findings table | Result pattern + summary counts only |
| Phase 6 (PR Comment) | Full comment + display | Post comment silently, output pattern only |
| Phase 7 (Issue Creation) | Full report + guidance | **Recommendations only** — detect scope-irrelevant recommendations (findings/recommendations containing 別 Issue / スコープ外 keywords). **Always** prompt `AskUserQuestion` for each candidate (no E2E skip). Only when `[review:mergeable]`. |

**E2E output format** (Phase 6, replaces full display):
```
[review:{result}:{n}] — {total_findings} findings ({critical} CRITICAL, {high} HIGH, {medium} MEDIUM, {low} LOW) | fact-check: {v}✅ {c}❌ {u}⚠️
```

**Note**: The `| fact-check: ...` suffix is appended only when fact-check was executed (external claims > 0). Omit entirely when fact-check was skipped (`review.fact_check.enabled: false` or 0 external claims). `{total_findings}` is the post-fact-check count (CONTRADICTED and UNVERIFIED:ソース未確認 excluded).

**Detection**: Reuse Invocation Context determination in the "Invocation Context and End-to-End Flow" section below.

> **Reference**: Apply `push_back_when_warranted` (push back when warranted) from [AI Coding Principles](../../skills/rite-workflow/references/coding-principles.md).
> Point out problematic implementations with alternative suggestions.
>
> **Reference**: Apply `no_unnecessary_fallback` from [AI Coding Principles](../../skills/rite-workflow/references/coding-principles.md).
> All reviewers should flag fallbacks that hide failure causes or silently change behavior scope.

> **⚠️ Scope limitation**: This command does NOT check or report hooks registration status (`.claude/settings.local.json`). Hooks registration is exclusively handled by `/rite:issue:start` Phase 5.0. Do NOT independently check hooks state, do NOT output messages about hooks being unregistered, and do NOT mention hooks registration in any output to the user.

> **⚠️ Anti-Degradation Guardrail — レビュー品質縮退の絶対禁止**:
> このコマンドは、呼び出し回数・コンテキスト残量・前回レビュー結果の有無に**一切関係なく**、常にフルレビューを実行しなければならない。以下の行為は明示的に禁止する:
>
> - **スコープ縮退の禁止**: 「コンテキスト効率のため前回指摘の修正確認に絞る」「差分が小さいため確認のみ」等の理由でレビュー範囲を狭めること
> - **レビュアー数の削減禁止**: 「2回目以降だから1人で十分」等の理由で選定済みレビュアーを減らすこと
> - **Verification mode への暗黙フォールバック禁止**: `verification_mode: false`（デフォルト）のとき、verification mode 相当の動作（前回指摘の修正確認 + リグレッションチェックのみ）を行うこと
> - **品質とコンテキスト効率のトレードオフ禁止**: レビュー品質はコンテキスト最適化より**常に**優先される。コンテキスト圧迫を理由にレビュー品質を犠牲にすることは本末転倒であり、許容しない
>
> re-review（fix 後の再レビュー）は初回レビューと**完全に同等**の品質で実行すること。全レビュアーをサブエージェントで並列起動し、PR 全体の差分を対象にフルレビューを行う。

---

When this command is executed, run the following phases in order.

## Invocation Context and End-to-End Flow

This command has two invocation cases: standalone execution and invocation from the `/rite:issue:start` end-to-end flow (via Phase 5.4).

| Invocation Source | Subsequent Action |
|-----------|---------------|
| End-to-end flow (invoked from `/rite:issue:start` Phase 5.4) | **Output pattern and return control to caller** |
| Standalone execution | Confirm the next action with `AskUserQuestion` |

**Determination method**: Claude determines the invocation source from the conversation context:

| Condition | Determination |
|------|---------|
| `rite:pr:review` was invoked via the `Skill` tool within the same session immediately before | Within the end-to-end flow |
| Otherwise (user directly entered `/rite:pr:review`) | Standalone execution |

> **Important (Responsibility for flow continuation)**: When executed within the end-to-end flow, this Skill outputs a machine-readable output pattern (e.g. `[review:mergeable]`, `[review:fix-needed:{n}]`) and **returns control to the caller** (`/rite:issue:start`). The caller determines the next action based on this output pattern.

---

## Arguments

| Argument | Description |
|------|------|
| `[pr_number]` | PR number (defaults to the PR for the current branch if omitted) |

---

## Phase 0: Load Work Memory (End-to-End Flow)

> **⚠️ Note**: Work memory is posted as Issue comments and is publicly visible. On public repositories, it can be viewed by third parties. Do not record confidential information (credentials, personal data, internal URLs, etc.) in work memory.

When executed within the end-to-end flow, load necessary information from work memory (shared memory).

### 0.1 End-to-End Flow Determination

Determine the invocation source from the conversation context:

| Condition | Determination | Action |
|------|---------|------|
| Conversation history has rich context from `/rite:pr:create` | Within the end-to-end flow | PR number can be obtained from conversation context |
| `/rite:pr:review` was executed standalone | Standalone execution | Obtain from argument or current branch PR |

---

## Phase 1: Preparation

**Placeholder legend:**
- `{pr_number}`: PR number (obtained from argument or `gh pr view` result)
- `{owner}`, `{repo}`: Repository information (obtained via `gh repo view --json owner,name`)
- `{post_comment_mode}`: Final decision whether to post PR comment (`true`/`false`), computed in Phase 1.0 from flags + config
- Other `{variable}` formats: Values obtained from command execution results or previous phases

**Note**: All placeholders in this document use `{variable}` format. Unlike Bash shell variable format `${var}`, these are conceptual markers that Claude substitutes with values.

### 1.0 Argument Parsing (Pre-flight) — #443

> **⚠️ MANDATORY**: This sub-phase runs **before** Phase 1.1 `gh pr view` invocation. It parses the command-line flags `--post-comment` / `--no-post-comment` and determines the final `{post_comment_mode}` value that Phase 6.1 will consume. Silent fallthrough is prohibited.

> **Schema reference**: See [review-result-schema.md](../../references/review-result-schema.md) for the full JSON schema and PR comment format contract that Phase 6.1 will produce.

**Supported arguments**:

| Argument | Effect |
|----------|--------|
| `<pr_number>` (integer) | PR number (same as existing behavior) |
| `--post-comment` | Force PR comment posting (overrides config) |
| `--no-post-comment` | Force skip PR comment posting (overrides config) |
| (no flag) | Use `rite-config.yml` `pr_review.post_comment` value (default: `false`) |

**Parsing procedure**:

> **⚠️ 重要 — 単一 Bash tool invocation での実行**: Phase 1.0 の bash block は **1 つの Bash tool 呼び出しで完結させる** こと。旧実装は Step 1 (flag 抽出) と Step 2 (conflict check) を別 invocation に分割し、Step 1 の `[CONTEXT] FLAG_POST=...` emit 値を Claude が literal substitute する方式だった。しかし substitute 漏れが silent regression (AC-8 conflict check の常時 false) を起こすリスクがあり、分割の合理的理由が薄いため本 PR (verified-review C-4) で単一 block に統合した。
>
> Claude は下記 bash block **全体**を 1 回の Bash tool 呼び出しで実行し、内部のシェル変数 (`flag_post`, `flag_no_post`, `remaining_args`, `config_post_comment`, `post_comment_mode`) は bash 内で完結させる。literal substitution は bash-compat-guard placeholder 以外一切不要。

```bash
# ============================================================================
# Phase 1.0: Argument parsing + conflict check + config read (unified block)
# ============================================================================
# 本 block は以下の 5 ステップを単一 Bash tool invocation で実行する:
#   Step 0: bash 4+ compat guard (inlined from references/bash-compat-guard.md)
#   Step 1: flag 抽出 + remaining_args 生成
#   Step 2: AC-8 conflict check (--post-comment と --no-post-comment 同時指定)
#   Step 3: rite-config.yml の pr_review.post_comment 読取 (SIGPIPE-safe 単一 awk)
#   Step 4: {post_comment_mode} の最終決定 + [CONTEXT] emit

# --- Step 0: bash 4+ compat guard (C-3: inlined from references/bash-compat-guard.md) ---
# mapfile builtin は bash 4.0 で導入されたため、bash 3.2 (macOS default) では
# 後段の Phase 1.2.7 で `mapfile -t changed_file_paths < "$gh_files_stdout"` が
# `command not found` で silent 失敗する。本 guard で fail-fast させる。
# Source: GNU Bash 4.0 NEWS (https://tiswww.case.edu/php/chet/bash/NEWS)
if ! command -v mapfile >/dev/null 2>&1; then
  bash_version=$("$BASH" --version 2>/dev/null | head -1)
  echo "ERROR: bash 4.0+ が必要ですが、現在のシェルは mapfile builtin を持っていません" >&2
  echo "  検出: $bash_version" >&2
  echo "  対処: macOS では brew install bash で 4+ をインストールし、PATH の先頭に追加してください" >&2
  echo "[CONTEXT] REVIEW_ARG_PARSE_FAILED=1; reason=bash_version_incompatible" >&2
  echo "[review:error]"
  exit 1
fi

# --- Step 1: flag 抽出 + remaining_args 生成 ---
original_args="$ARGUMENTS"
flag_post="false"
flag_no_post="false"

# フラグ検出 (順序問わず、space/tab 両対応)
# bash の extended pattern matching ではなく regex match を使用して `[[:space:]]` 文字クラスを
# 適用し、space / tab の両方で区切られたフラグトークンを検出する。sed 側除去処理 (下記) と
# 文字クラスを揃えることで非対称を解消する。
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
  echo "  受信した引数: $ARGUMENTS" >&2
  echo "" >&2
  echo "対処:" >&2
  echo "  1. どちらか一方のみを指定してください" >&2
  echo "  2. 永続化するには rite-config.yml の pr_review.post_comment を設定:" >&2
  echo "     - true: 常に PR コメントを投稿 (チームレビュー向け)" >&2
  echo "     - false: デフォルトで投稿しない (個人ワークフロー向け — AC-1 デフォルト)" >&2
  echo "  3. コマンドライン引数は rite-config.yml の値を常に上書きします" >&2
  echo "[CONTEXT] REVIEW_ARG_PARSE_FAILED=1; reason=post_and_no_post_conflict" >&2
  echo "[review:error]"
  exit 1
fi

# --- Step 3: rite-config.yml の pr_review.post_comment 読取 (C-2: SIGPIPE-safe) ---
# 旧実装は `sed | awk | sed | sed | tr | tr` の 6 段 pipeline で pipefail 下で SIGPIPE
# rc=141 が発生し、fallback branch が config 値を silent に false へ上書きする latent
# regression を抱えていた。本実装は **単一 awk 呼び出し** に統合し pipeline を排除する
# ことで SIGPIPE 経路自体を消す。awk は file を直接読むため上流コマンドが存在しない。
# Source: GNU bash manual — Pipelines / POSIX awk exit semantics
repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || repo_root=""
config_post_comment="false"

if [ -z "$repo_root" ]; then
  echo "WARNING: git rev-parse --show-toplevel に失敗しました (現在地が git repo 内ではない可能性)。post_comment=false (default) で続行します" >&2
elif [ ! -f "$repo_root/rite-config.yml" ]; then
  echo "WARNING: $repo_root/rite-config.yml が見つかりません。post_comment=false (default) で続行します" >&2
else
  # 単一 awk でファイルを直接読み、pr_review セクション内の post_comment 値を抽出する。
  # - `/^pr_review:/` でセクション start を検出
  # - `in_section && /^[a-zA-Z]/` で次の top-level key に到達したら exit
  # - `post_comment[[:space:]]*:` マッチ行で値を抽出 (prefix 拡張 `post_comment_mode:` 等との衝突防止)
  # - YAML inline comment は「空白 + #」で始まるため `[[:space:]]#` をコメント boundary とする
  #   (YAML 仕様: `#` が inline comment になるのはスペースまたはタブの直後のみ)
  # awk 終了コードは file IO / binary error 以外で 0 を返すため、`if ! ...` で捕捉可能。
  awk_err=$(mktemp /tmp/rite-review-awk-err-XXXXXX 2>/dev/null) || awk_err=""
  if raw=$(awk '
    /^pr_review:/ { in_section=1; next }
    in_section && /^[a-zA-Z]/ { exit }
    in_section && /^[[:space:]]+post_comment[[:space:]]*:/ {
      line=$0
      sub(/[[:space:]]#.*/, "", line)
      sub(/.*post_comment[[:space:]]*:[[:space:]]*/, "", line)
      gsub(/[[:space:]]/, "", line)
      gsub(/"/, "", line)
      print tolower(line)
      exit
    }
  ' "$repo_root/rite-config.yml" 2>"${awk_err:-/dev/null}"); then
    config_post_comment="$raw"
  else
    echo "WARNING: rite-config.yml の awk による読取が失敗しました (IO/binary error)" >&2
    [ -n "$awk_err" ] && [ -s "$awk_err" ] && head -3 "$awk_err" | sed 's/^/  /' >&2
    echo "  default の false を使用します" >&2
    config_post_comment=""
  fi
  [ -n "$awk_err" ] && rm -f "$awk_err"

  # 不正値 (typo: `ture`, 全角文字等) は silent に false へ畳み込まず WARNING を表示。
  # 空文字 (key 未設定 / awk IO error fallback) は legitimate fallback として silent OK。
  case "$config_post_comment" in
    true|yes|1)  config_post_comment="true" ;;
    false|no|0)  config_post_comment="false" ;;
    "")          config_post_comment="false" ;;
    *)
      echo "WARNING: rite-config.yml の pr_review.post_comment に不正な値: '$config_post_comment'" >&2
      echo "  認識可能: true / yes / 1 / false / no / 0 (大文字小文字無視)" >&2
      echo "  default の false を使用します" >&2
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

**Phase 1.1 への hand-off**: Phase 1.1 の `{pr_number}` 抽出は **必ず `remaining_args` に対して行う** こと。`$ARGUMENTS` を直接参照すると未除去のフラグトークンを PR 番号候補と誤認するリスクがある。`{post_comment_mode}` は Phase 6.1 で参照する Single Source of Truth。

**Final decision precedence**:

| Priority | Condition | `{post_comment_mode}` |
|----------|-----------|----------------------|
| 1 | `--no-post-comment` specified | `false` (highest priority — overrides config) |
| 2 | `--post-comment` specified | `true` |
| 3 | `pr_review.post_comment: true` in config | `true` |
| 4 | Default | `false` |

**Phase 1.0 failure reasons**: (`bash_version_incompatible` / `post_and_no_post_conflict`)

| reason | Description |
|--------|-------------|
| `bash_version_incompatible` | Step 0 の `command -v mapfile` チェックが失敗 (bash 3.2 等の旧バージョン) |
| `post_and_no_post_conflict` | `--post-comment` と `--no-post-comment` が同時指定された (Step 2、AC-8 違反、`REVIEW_ARG_PARSE_FAILED=1` retained flag を emit して `[review:error]` で exit 1) |

**Eval-order enumeration** (for Pattern-5 drift check): Phase 1.0 emit sequence = (`bash_version_incompatible` / `post_and_no_post_conflict`)

### 1.1 Identify the PR

**Input**: `$remaining_args` を Phase 1.0 Step 1 から引き継いだ値として参照する。**`$ARGUMENTS` を直接参照してはならない** — `$ARGUMENTS` は `--post-comment` / `--no-post-comment` 等のフラグトークンを含むため、PR 番号と誤認するリスクがある。Phase 1.0 Step 1 で生成された `remaining_args` は flag tokens を除去済みで、PR 番号 / PR URL / 引数なし のいずれかが入る (Phase 1.0 Step 1 末尾の note 参照)。

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
gh pr view {pr_number} --json number,title,body,state,isDraft,additions,deletions,changedFiles,files,headRefName,baseRefName,url
```

#### 1.1.2 Fallback (When Not Retrieved from Work Memory)

If a PR number is specified as an argument:

```bash
gh pr view {pr_number} --json number,title,body,state,isDraft,additions,deletions,changedFiles,files,headRefName,baseRefName,url
```

If the argument is omitted and there is no PR number in work memory, identify the PR from the current branch:

```bash
git branch --show-current
gh pr view --json number,title,body,state,isDraft,additions,deletions,changedFiles,files,headRefName,baseRefName,url
```

**If no PR is found:**

```
エラー: 現在のブランチに関連する PR が見つかりません

現在のブランチ: {branch}

対処:
1. `/rite:pr:create` で PR を作成
2. PR 番号を直接指定して再実行
```

Terminate processing.

**If the PR is closed/merged:**

```
エラー: PR #{number} は既に{state}されています

レビューは実行できません。
```

Terminate processing.

### 1.2 Retrieve Changes

> **Reference**: See [Review Context Optimization](./references/review-context-optimization.md) for scale determination and diff retrieval strategies.

**Scale determination:**

Use the `additions`, `deletions`, and `changedFiles` values retrieved in Phase 1.1.

Classify as Small (<= 500 lines, <= 10 files), Medium (<= 2000 lines, <= 30 files), or Large (> 2000 lines or > 30 files).

**Diff retrieval (guard-validated commands only — avoids patterns blocked by `pre-tool-bash-guard.sh`):**

Small scale: `gh pr diff {pr_number}` (bulk retrieval)
Medium/Large scale: `gh pr view {pr_number} --json files --jq '.files[].path'` (per-reviewer extraction in Phase 4.3)

**File statistics:** `gh pr view {pr_number} --json files --jq '.files[] | {path, additions, deletions}'`

**Per-file diff extraction:** `gh pr diff {pr_number} | awk '/^diff --git/ { found=0 } /^diff --git.*{target_pattern}/ { found=1 } found { print }'`

> `{target_pattern}` is an inline replacement marker (NOT a `{}` shell placeholder) — replace it directly with the literal file path to extract. Example: to extract the diff for `src/auth.ts`, use `awk '/^diff --git/ { found=0 } /^diff --git.*src\/auth.ts/ { found=1 } found { print }'`.

#### 1.2.3 Retrieve Changed File List

Use the `files` array retrieved in Phase 1.1 to extract file paths.

#### 1.2.4 Review Mode Determination

Determine the review mode based on whether a previous review result comment exists.

**Loading configuration:**

Retrieve `review.loop.verification_mode` from `rite-config.yml` (default: `false`).

> **推奨**: レビュー品質を最大化するため、デフォルトの `false`（毎回フルレビュー）を維持することを推奨します。`true` に設定すると 2 回目以降で verification mode が有効になりますが、レビューの網羅性が低下する可能性があります。

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

Record the current commit SHA at the start of the review. This SHA is embedded in the review result (local JSON file always in Phase 6.1.a, and additionally in the PR comment when `post_comment_mode=true` via Phase 6.1.b) and used in the verification mode of the next cycle.

```bash
git rev-parse HEAD
```

Retain the obtained SHA as `{current_commit_sha}` in the conversation context.

#### 1.2.6 Change Intelligence Summary

> **Reference**: See [Change Intelligence](./references/change-intelligence.md) for computation methods and format.

Pre-compute change statistics to provide reviewers with upfront context about the nature of the PR.

**Placeholders:**
- `{base_branch}`: PR base branch (the `baseRefName` value retrieved in Phase 1.1)

**Steps:**

1. Use the `files` array from Phase 1.1 (`path`, `additions`, `deletions`) for per-file change statistics.

2. Retrieve numeric statistics for programmatic analysis:
   ```bash
   git diff {base_branch}...HEAD --numstat
   ```

3. Classify each changed file into categories (source/test/config/docs) per [Change Intelligence](./references/change-intelligence.md#file-classification).

4. Estimate the change type (New Feature, Refactor, Cleanup, etc.) per [Change Intelligence](./references/change-intelligence.md#change-type-estimation).

5. Generate a one-paragraph summary per [Change Intelligence](./references/change-intelligence.md#summary-generation).

Retain the generated summary as `{change_intelligence_summary}` in the conversation context for use in Phase 4.5.

**Note**: This step uses data already retrieved in Phase 1.1 (`additions`, `deletions`, `changedFiles`, `files`). The `files` array provides per-file `path`, `additions`, and `deletions`, eliminating the need for a separate API call.

**Success path retained flag** (必ず explicit set): `git diff --numstat` が成功した場合は以下を context に保持する:

- `numstat_availability = "OK"`
- `numstat_fallback_reason = ""` (空文字列で explicit set。Phase 5.4 template の placeholder 展開時に空欄として描画される。undefined を残すと placeholder 参照時に literal text または error になるリスクがあるため空文字列で defined にする)

**Error handling**: If `git diff --numstat` fails (network error, timeout, missing base branch fetch, etc.):

1. **必ず stderr に WARNING を出力** (silent fallback 禁止):
   ```
   WARNING: git diff --numstat failed. Using Phase 1.1 `files` array (additions/deletions per file) instead.
   Reason: <error message>
   Note: Phase 1.2.7 Doc-Heavy PR detection uses only the Phase 1.1 `files` array fields (`additions + deletions`),
         so this numstat failure does NOT affect Doc-Heavy detection accuracy. The fallback is equivalent data.
   ```
2. Phase 1.1 の `additions`, `deletions`, `changedFiles`, `files` data を使って summary を生成する
3. **Retained context flags** (Phase 5.4 template 表示用。会話コンテキストに明示保持し、stderr WARNING の消失リスクを回避):
   - `numstat_availability = "unavailable"`
   - `numstat_fallback_reason = <error message の 1 行要約>`
   - Phase 1.2.7 の `{doc_heavy_pr}` 計算は Phase 1.1 `files` 配列で完結するため `doc_heavy_pr` 判定自体は通常通り実行される (Phase 5.4 表示では「numstat unavailable だが Doc-Heavy 判定は実行済み」と表示される)

   `numstat_availability` が `"OK"` (通常時) の場合、Phase 5.4 の numstat 可用性行はこの retained flag を参照して表示する。本項目は retained flag を**明示定義**するため、Phase 5.4 で `{numstat_fallback_reason}` placeholder が undefined 参照にならないことを保証する。

#### 1.2.7 Doc-Heavy PR Detection

**Purpose**: Identify PRs whose primary change target is user-facing documentation, and flag them for stricter tech-writer review with implementation-consistency checks (see [internal-consistency.md](./references/internal-consistency.md)).

**Skip conditions** (any match → **explicit set the 3 retained flags below** and skip to Phase 1.3):

- `review.doc_heavy.enabled: false` in `rite-config.yml`
- `changedFiles == 0` (edge case: empty diff)

skip 発動時に explicit set する 3 retained flags:

| Flag | Value (skip 時) |
|------|-----------------|
| `{doc_heavy_pr}` | `false` |
| `{doc_heavy_pr_value}` | `false` |
| `{doc_heavy_pr_decision_summary}` | `"doc_heavy.enabled=false (skipped)"` または `"empty diff (changedFiles=0)"` (発動した skip 条件に応じて) |

> **Note**: "retain" ではなく "explicit set" とする。これにより `{doc_heavy_pr}` / `{doc_heavy_pr_value}` / `{doc_heavy_pr_decision_summary}` の 3 つが Phase 2.2.1 / Phase 5.1.3 / Phase 5.4 到達時点で必ず set されていることが保証される (undefined 参照防止)。

**Configuration**: Read `review.doc_heavy` from `rite-config.yml` with the following defaults when the key is absent:

| Key | Type | 値域 | Default | Description |
|-----|------|------|---------|-------------|
| **`enabled`** | boolean | `true` / `false` | `true` | この Phase の有効/無効 |
| **`lines_ratio_threshold`** | number | `(0.0, 1.0]` | `0.6` | `doc_lines / total_diff_lines` の閾値 (行数比率) |
| **`count_ratio_threshold`** | number | `(0.0, 1.0]` | `0.7` | `doc_files / total_files` の閾値 (ファイル数比率) |
| **`max_diff_lines_for_count`** | positive integer | `>= 1` | `2000` | ファイル数比率判定を有効にする最大 diff 行数 |

**型 validation 必須** (silent type-coercion 防止):

YAML パーサーの仕様により `count_ratio_threshold: "0.7"` (quoted string) や `count_ratio_threshold: 1.5` (値域外) が rite-config.yml に書かれた場合、bash/Python 実装次第で `0.7 (number) >= "0.7" (string)` の比較が **type error** または **silent false** になり、Doc-Heavy 判定が黙って失敗する。これを防ぐため、各 config 値の読み込み時に必ず以下を実行する:

1. **型チェック**: number 型でなければ default 値に fallback し、`WARNING: review.doc_heavy.{key} の型が number でないため default 値 {default} を使用します` を **stderr に必ず出力** する
2. **値域チェック**: `(0.0, 1.0]` の範囲外 (例: `0`, `-0.3`, `1.5`) なら default 値に fallback し、`WARNING: review.doc_heavy.{key} の値 {value} が値域外 (0 < x <= 1) のため default 値 {default} を使用します` を stderr に出力
3. **`max_diff_lines_for_count`**: positive integer (`>= 1`) でなければ default 値に fallback し WARNING を出力

**Calculation**:

本 Phase 1.2.7 は **2 つの異なる情報源** を使い分けて計算する。両者は責務が異なり、混同してはならない:

| 計算対象 | 情報源 | 取得方法 | 理由 |
|---------|--------|----------|------|
| **`doc_lines`** / `doc_files_count` / `total_diff_lines` / `total_files_count` (ratio 計算) | **Phase 1.1 の `files` 配列** (context 保持データ、`additions`/`deletions` フィールド付き) | コンテキストから直接参照 (新規 API call なし) | numstat 失敗の影響を避けるため。同じデータが Phase 1.1 で取得済み |
| **`all_files_excluded`** 判定で使う **changed file path 一覧** | **`gh pr view --json files` を再呼び出し** | 下記 bash impl で独立に gh API を呼び出す | bash 配列として retain する仕組みがコンテキスト変数では fragile なため。重複 API call (1 往復) のコストで silent failure リスクを排除 |

**重要 — 2 情報源の責務分離 (二重定義 drift 防止)**: ratio 計算 (`doc_lines` 等) は **Phase 1.1 の `files` 配列を再利用**し、`gh pr view --json files` を再呼び出ししない。下記 bash 実装が再呼び出すのは `all_files_excluded` 判定で必要な「changed file path 一覧」のみ (path 抽出を bash 配列として安全に retain するため)。Phase 1.2.6 Note の「separate API call は不要」原則は ratio 計算側に対する宣言であり、本 Phase の bash impl による再呼び出しはこの原則と矛盾しない (ratio は Phase 1.1 データを使い、再呼び出しは path 抽出専用)。

**Why this split?**: ratio 計算は数値演算のみで Phase 1.1 の context 値で完結するが、`all_files_excluded` の case 文判定にはファイル path の bash 配列が必要で、コンテキスト保持データから bash 配列に再 hydration する仕組みは fragile (改行/特殊文字エスケープのリスク) なため、bash 内で gh API を独立に呼ぶほうが安全。

> **Numstat 失敗との関係**: Phase 1.2.6 で `git diff --numstat` が失敗しても、本 Phase の ratio 計算は Phase 1.1 の `files` 配列で完結するため `doc_heavy_pr` 判定精度には影響しない。`numstat_availability = "unavailable"` は Phase 5.4 表示で別途可視化される。

```
# Doc file patterns — kept in sync across 3 files (tech-writer.md Activation / this file Phase 1.2.7 /
# SKILL.md Reviewers table tech-writer row). 等価性の **invariant 定義と drift 検出ルール**は
# `commands/pr/references/internal-consistency.md` Cross-Reference セクション「drift 検出の invariant
# (3 ファイル等価性)」に集約されている。drift 検出 lint は
# `plugins/rite/hooks/scripts/doc-heavy-patterns-drift-check.sh` として実装済み
# (Issue #353 系統 1; /rite:lint Phase 3.7 から呼び出される)。
# Do not duplicate the invariant rules here — update internal-consistency.md instead.
doc_file_patterns = [
  **/*.md   (excluding commands/**/*.md, skills/**/*.md, agents/**/*.md),
  **/*.mdx  (excluding commands/**/*.mdx, skills/**/*.mdx, agents/**/*.mdx),
  docs/**, documentation/**,
  **/README*, CHANGELOG*, CONTRIBUTING*,
  i18n/**/*.md, i18n/**/*.mdx  (excluding plugins/rite/i18n/**),
  *.rst, *.adoc
]

doc_lines          = sum(additions + deletions of files matching doc_file_patterns)
total_diff_lines   = sum(additions + deletions of all changed files)
doc_files_count    = count(files matching doc_file_patterns)
total_files_count  = changedFiles

# Zero-division guards (inline — both divisors must be checked before division)
# Defensive: skip condition (changedFiles == 0) は通常 total_files_count > 0 を保証するが、
# skip section が将来変更された場合に備えて inline ガードも残す (二重防御)
# 重要: 全ての early-exit 経路で {doc_heavy_pr} / {doc_heavy_pr_value} / {doc_heavy_pr_decision_summary} の 3 つを必ず set する
if total_diff_lines == 0:
    doc_heavy_pr                  = false                              # explicit set (silent undefined 防止)
    doc_heavy_pr_value            = false
    doc_heavy_pr_decision_summary = "empty diff (total_diff_lines=0)"
    skip to Phase 1.3              # Phase 1.2.7 の残り計算をスキップ

if total_files_count == 0:
    doc_heavy_pr                  = false                              # explicit set (Defensive guard)
    doc_heavy_pr_value            = false
    doc_heavy_pr_decision_summary = "empty diff (total_files_count=0)"
    skip to Phase 1.3              # skip condition (changedFiles == 0) で本来到達しない

# 命名上の注意:
# - doc_lines_ratio は「ドキュメント行数 / 全体 diff 行数」の比率 (行数ベース)
# - doc_files_count_ratio は「ドキュメントファイル数 / 全体ファイル数」の比率 (ファイル数ベース)
# config キー名は意味と一致している (lines_ratio_threshold / count_ratio_threshold)
#
# 変数名と config キー名の prefix 非対称について:
#   - lines 方式: 変数 `doc_lines_ratio` / config `lines_ratio_threshold` (prefix 統一: "lines")
#   - count 方式: 変数 `doc_files_count_ratio` / config `count_ratio_threshold` (prefix 異なる)
# 後者で config 側に "files_" を含めなかった理由は、代替案 `files_count_ratio_threshold` (4 語) より
# 短い 3 語 (`count_ratio_threshold`) を優先したため。変数名 `doc_files_count_ratio` 側は計算対象
# (file 数 vs 行数) を明示するため "files_count" を保持している。
# 計算対象はどちらもこの疑似コードで明示されているので drift リスクは低い。
doc_lines_ratio       = doc_lines / total_diff_lines
doc_files_count_ratio = doc_files_count / total_files_count

# Self-only judgment (Exclusion rule の semantic 補完):
# 全ての変更ファイルが exclusion patterns (plugins/rite/commands/**, plugins/rite/skills/**,
# plugins/rite/agents/**, plugins/rite/i18n/**) に該当する場合、doc_lines_ratio == 0 とは別に
# "self-only" として記録する。
# 注: 上記コメントの prefix `plugins/rite/` は意図的。汎用 repo (rite plugin 以外) で同名の
# commands/skills/agents/i18n ディレクトリを持つ場合の silent misclassification 防止のため、
# 下記 bash 実装 (anchor: `# === all_files_excluded bash impl ===` 配下の `[[ "$f" == plugins/rite/* ]]`)
# と同じ prefix で書く必要がある。anchor 参照は drift しやすいハードコード行番号を避けるための措置
# 「分子から除外、分母には含める」方式では rite plugin self-only PR でも数学的には
# doc_lines == 0 (= ratio 0) になり、「ratio 未満」と区別不能になるため、明示的なフラグで補完する
all_files_excluded = (doc_lines == 0
                      AND total_diff_lines > 0
                      AND 全変更ファイルが exclusion patterns に該当する)
```

**`all_files_excluded` の bash 実装パターン** (Claude が任意実装する際の標準テンプレート):

> **Anchor for cross-reference**: 上記 pseudo-code コメント (Self-only judgment) から本ブロックを参照する場合は、以下の `# === all_files_excluded bash impl ===` anchor を grep の起点として使う。ハードコードされた行番号は drift しやすいため使用しない。

Doc-Heavy bash impl failure reasons: (`gh_files_stderr_mktemp_failure` / `gh_files_stdout_mktemp_failure` / `gh_pr_view_files_failure` / `mapfile_io_error`)

| reason | Description |
|--------|-------------|
| `gh_files_stderr_mktemp_failure` | gh_files_stderr temp file creation failed |
| `gh_files_stdout_mktemp_failure` | gh_files_stdout temp file creation failed |
| `gh_pr_view_files_failure` | gh pr view --json files API call failed |
| `mapfile_io_error` | mapfile read from gh_files_stdout failed |

```bash
# === all_files_excluded bash impl ===
#
# 前提変数 (caller 側で必ず set すること、未 set の場合は下記の default 確保で fall back する):
# - doc_lines       : Phase 1.2.7 pseudo-code で計算されるドキュメント変更行数 (整数)
# - total_diff_lines: Phase 1.2.7 pseudo-code で計算される全変更行数 (整数)
#
# Default 値確保 (silent regression 防止):
# 上記 2 変数が未定義の場合、bash の `[ "" -eq 0 ]` は "integer expression expected" で
# 非 0 を返し AND 条件が常に false になる silent regression を引き起こす。
# `${var:-0}` で必ず integer リテラルとして展開する。
doc_lines="${doc_lines:-0}"
total_diff_lines="${total_diff_lines:-0}"

# Step 1: 変更ファイル一覧 (path 抽出専用) を bash 配列として取得
#
# 責務分離 (上記 Calculation 表の「2 情報源」と一致):
# - ratio 計算 (doc_lines / doc_files_count / total_diff_lines / total_files_count) は
#   **Phase 1.1 の files 配列 (context 保持データ)** を再利用 (Phase 1.2.6 Note 「separate API call 不要」原則に従う)
# - all_files_excluded 判定で必要な「path の bash 配列」のみ、ここで gh pr view --json files を再呼び出す
#
# なぜ再呼び出すのか: コンテキスト保持データを bash 配列に再 hydration する仕組みは fragile
# (改行/特殊文字エスケープのリスク + Claude の context 変数が bash session に直接渡らない構造)。
# bash 内で gh API を独立に呼ぶことで silent failure リスク (未定義変数 → 空配列 → false positive) を排除する。
# 重複 API call のコストはネットワーク 1 往復のみで許容範囲内。
# gh pr view --json files が返すパスは repository root 相対形式 (例: "plugins/rite/commands/pr/fix.md")
#
# 重要 — exit code 捕捉: `mapfile -t < <(...)` の process substitution は subshell を生成するため、
# 内側のコマンド (gh pr view) の exit code を直接受け取れない (silent failure リスク)。
# これを防ぐため、(1) gh pr view の stderr を一時ファイルに退避、(2) stdout を一時ファイルに保存、
# (3) gh pr view の exit code を if で明示的に check し、(4) 成功時のみ mapfile で読み込む。
#
# trap + cleanup パターンの canonical 説明は references/bash-trap-patterns.md#signal-specific-trap-template 参照
# (rationale: 「パス先行宣言 → trap 先行設定 → mktemp」の順序、signal 別 exit code 130/143/129、${var:-} safety)
gh_files_stderr=""
gh_files_stdout=""
_rite_review_p127_cleanup() {
  rm -f "${gh_files_stderr:-}" "${gh_files_stdout:-}"
}
trap 'rc=$?; _rite_review_p127_cleanup; exit $rc' EXIT
trap '_rite_review_p127_cleanup; exit 130' INT
trap '_rite_review_p127_cleanup; exit 143' TERM
trap '_rite_review_p127_cleanup; exit 129' HUP

gh_files_stderr=$(mktemp /tmp/rite-review-gh-files-err-XXXXXX) || {
  echo "ERROR: gh_files_stderr 一時ファイルの作成に失敗" >&2
  echo "[CONTEXT] DOC_HEAVY_TMPFILE_FAILED=1; reason=gh_files_stderr_mktemp_failure" >&2
  exit 1
}
gh_files_stdout=$(mktemp /tmp/rite-review-gh-files-out-XXXXXX) || {
  echo "ERROR: gh_files_stdout 一時ファイルの作成に失敗" >&2
  echo "[CONTEXT] DOC_HEAVY_TMPFILE_FAILED=1; reason=gh_files_stdout_mktemp_failure" >&2
  exit 1
}

if ! gh pr view "{pr_number}" --json files --jq '.files[].path' > "$gh_files_stdout" 2>"$gh_files_stderr"; then
  echo "ERROR: gh pr view --json files が失敗しました (exit != 0)" >&2
  echo "[CONTEXT] DOC_HEAVY_GH_API_FAILED=1; reason=gh_pr_view_files_failure" >&2
  echo "  詳細: $(cat "$gh_files_stderr")" >&2
  echo "  考えられる原因: 認証エラー (gh auth status を確認) / network timeout / PR #{pr_number} の存在を確認" >&2
  echo "  対処: 上記詳細を確認の上、必要に応じて再実行してください。Doc-Heavy 判定の根拠データが取得できないため処理を中止します。" >&2
  exit 1
fi

# mapfile の exit code を明示的に check (silent-failure-hunter MEDIUM-2 対応):
# read permission denied / IO error / 破損ファイルで失敗した場合、`changed_file_paths` は空配列のまま
# 後続の `if [ ${#changed_file_paths[@]} -eq 0 ]` 分岐で「gh pr view が exit 0 で 0 ファイルを返しました」の
# 誤診断メッセージに流れる silent regression を防ぐ。本当の失敗原因 (mapfile IO エラー) を fail-fast で検出する。
if ! mapfile -t changed_file_paths < "$gh_files_stdout"; then
  echo "ERROR: mapfile が gh_files_stdout からの読み込みに失敗しました: $gh_files_stdout" >&2
  echo "[CONTEXT] DOC_HEAVY_MAPFILE_FAILED=1; reason=mapfile_io_error" >&2
  echo "  考えられる原因: read permission denied / IO error / ファイル破損 / inode 枯渇" >&2
  exit 1
fi

# 空配列 guard: gh pr view が exit 0 で空 stdout を返したコーナーケース (PR が完全に空など)
# exit code が成功しているため fatal error ではないが、Phase 1.1 の `files` 配列とこの再呼び出し
# 結果が不整合 (前者 > 0 / 後者 == 0) になる race の兆候のため、3 retained flag を **explicit set**
# して early exit する。
#
# Phase 1.1 と Phase 1.2.7 の files 配列の不整合 race (PR が削除される / PR が空になる /
# files 配列が shrink) のエッジケースで、retained flag が undefined のまま Determination block へ
# 流れると `doc_heavy_pr_decision_summary` が意味不明な値 (NaN / undefined) になる silent regression
# を起こす。3 flag を明示的に set してから skip すれば、Phase 5.4 の表示で「inconsistency 発生」
# として可視化される。
if [ ${#changed_file_paths[@]} -eq 0 ]; then
  echo "WARNING: gh pr view --json files が exit 0 で 0 ファイルを返しました。Phase 1.1 files 配列との不整合 race の可能性。" >&2
  echo "  3 retained flag を doc_heavy_pr=false で explicit set し、Phase 1.3 へ skip します。" >&2
  all_files_excluded=false
  # 3 retained flag を explicit set (silent undefined 防止) — Determination block には進入しない
  echo "[CONTEXT] doc_heavy_pr=false; doc_heavy_pr_value=false; doc_heavy_pr_decision_summary=inconsistent_files_count_between_phase_1_1_and_1_2_7"
  # 後続 Determination block を skip するため、Claude は本 bash block 終了後に [CONTEXT] 行を
  # 検出した場合 Phase 1.3 へ直接進む (prose 指示 — Determination block は skip 経路)
else
  # Step 2: exclusion patterns に該当する変更ファイル数をカウント
  excluded_count=0
  total_count=0
  for f in "${changed_file_paths[@]}"; do
    total_count=$((total_count + 1))
    # rite plugin 配下か判定: prefix が一致する場合のみ exclusion 候補
    # 非 rite-plugin repo (汎用プロジェクト) で同名 commands/skills/agents/i18n ディレクトリを持つ場合の
    # silent misclassification 防止 (これがないと commands/foo.md 等が勝手に exclusion されてしまう)
    if [[ "$f" == plugins/rite/* ]]; then
      f_rel="${f#plugins/rite/}"
      case "$f_rel" in
        # rite plugin の commands/skills/agents/i18n 配下 (.md / .mdx / 任意拡張子 for i18n)
        # bash の `case` 文の glob `*` は POSIX 仕様上 `/` を含む任意文字列にマッチするため
        # (filename glob の挙動とは異なる)、`commands/*.md` 1 行で `commands/foo.md` も
        # `commands/sub/foo.md` も `commands/a/b/c/foo.md` もすべてカバーする。
        # 実機検証: `case "skills/sub/sub2/foo.md" in skills/*.md) echo MATCH ;; esac` → MATCH
        # Source: POSIX shell pattern matching (IEEE Std 1003.1)
        commands/*.md|commands/*.mdx| \
        skills/*.md|skills/*.mdx| \
        agents/*.md|agents/*.mdx| \
        i18n/*)
          excluded_count=$((excluded_count + 1))
          ;;
      esac
    fi
    # 非 rite-plugin path (例: src/auth.ts, commands/foo.md (汎用 repo)) は excluded にカウントしない
  done

  # Step 3: Self-only 判定: 全ての変更ファイルが rite plugin 配下の exclusion patterns に該当する
  # 注: 上で `doc_lines="${doc_lines:-0}"` / `total_diff_lines="${total_diff_lines:-0}"` を実行済みのため、
  # 未定義の場合でも integer 0 として正しく評価される (silent regression 防止)
  if [ "$excluded_count" -eq "$total_count" ] && [ "$doc_lines" -eq 0 ] && [ "$total_diff_lines" -gt 0 ]; then
    all_files_excluded=true
  else
    all_files_excluded=false
  fi
fi
```

**実装上の注意**:
- **2 情報源の責務分離 (path 抽出のみ再呼び出し)**: 上記 Calculation 表に従い、ratio 計算 (`doc_lines` / `doc_files_count` 等) は **Phase 1.1 の `files` 配列** を再利用し、`gh pr view --json files` の再呼び出しは **`all_files_excluded` 判定で必要な「path の bash 配列」抽出専用** とする。Phase 1.2.6 Note の「separate API call は不要」原則は ratio 計算に対する宣言であり、本 bash impl の path 専用再呼び出しと矛盾しない。再呼び出しの正当化はコンテキスト変数を bash 配列に再 hydration する仕組みが fragile なため (改行/特殊文字エスケープ + Claude context 変数が bash session に直接渡らない構造)
- **Path 正規化と rite-plugin scope check**: `if [[ "$f" == plugins/rite/* ]]; then ... fi` で rite plugin 配下か判定したうえで `f_rel="${f#plugins/rite/}"` を実行する。**この check がないと非 rite-plugin repo の `commands/foo.md` 等が誤 exclusion される silent misclassification が発生**するため必須
- **`case` パターンの glob**: bash の **filename expansion ではなく case statement の pattern matching** で評価される。POSIX shell pattern matching 仕様では `case` 文の `*` は **`/` を含む任意文字列にマッチ**するため (filename glob の挙動とは異なる)、`commands/*.md` 1 行で `commands/foo.md` も `commands/sub/foo.md` も `commands/a/b/c/foo.md` もすべてカバーする (実機検証: `case "skills/sub/sub2/foo.md" in skills/*.md) MATCH ;; esac` → MATCH)
- **`doc_file_patterns` 疑似コード (`i18n/**/*.md, i18n/**/*.mdx`) と bash impl `case` (`i18n/*`) の意図的範囲差**: 両者は **目的が異なるため意図的に範囲が違う**。drift ではない:
  - **`doc_file_patterns` 疑似コード** (上記 Calculation で使用): tech-writer Activation patterns との等価性を表現するため `.md` / `.mdx` 拡張子に限定する (3 ファイル等価性の系統 1 — internal-consistency.md の Cross-Reference 参照)
  - **bash impl `case` 文** (`all_files_excluded` 判定で使用): rite plugin self-only 判定が目的のため、翻訳ファイル (`i18n/ja.yml`, `i18n/en.json`, `i18n/messages.po` 等) も含めた**全拡張子**を excluded に含める。`i18n/*` パターンは POSIX shell pattern matching の仕様により `i18n/sub/foo.yml` 等の任意階層・任意拡張子をすべてカバーする
  - **整合性の検証**: ratio 計算 (`doc_lines` / `doc_files_count`) は前者の `doc_file_patterns` を、`all_files_excluded` 判定 (rite plugin self-only 判定) は後者の bash case を使うため、両者は別の計算経路で使われており drift しない
- **fail-fast guard**: `gh pr view` 失敗 / 空配列のときは `all_files_excluded=false` を explicit set し、WARNING を stderr に出力する。silent false positive (空配列 → 全条件成立 → all_files_excluded=true) を防ぐ
- bash 4+ では `shopt -s globstar` 後に `**/*.md` glob が利用可能だが、互換性のため case 文形式を採用
- alternative 実装: Python script で `pathlib.PurePath` の `match()` を使う方が pattern 処理は簡潔。bash 実装と Python 実装のどちらを採用するかは Claude が呼び出し環境で判断する

**Exclusion rule**: rite plugin 自身の `commands/**/*.md`, `skills/**/*.md`, `agents/**/*.md`, および `plugins/rite/i18n/**` は doc-heavy 判定対象から**除外**する。これらのファイルは prompt-engineer の専管領域 (commands/skills/agents) もしくは rite plugin 自身のドッグフーディング artifact (i18n) であり、Phase 2.2 の priority rule で prompt-engineer に振り分けられる、または rite plugin の自己記述として扱われる。

**除外の計算上の扱い**: `doc_lines` と `doc_files_count` の計算から分子として除外するが、`total_diff_lines` と `total_files_count` は除外せず全体を維持する。つまり **「分子からは除外、分母には含める」** 方式。これにより rite plugin 自身のメンテナンス PR (dogfooding 時) では意図的に doc-heavy 判定が起きにくくなる (ratio の分子が削られて分母が変わらないため)。

**計算例**:

- 例 1: `docs/foo.md (+50)` と `commands/bar.md (+50)` の PR
  - `doc_lines` = 50 (docs/ のみ、commands/ は除外)
  - `total_diff_lines` = 100 (両方含む)
  - `doc_lines_ratio` = 50/100 = 0.5 (< 0.6) → `doc_heavy_pr = false`
- 例 2: `docs/foo.md (+80)` のみの PR
  - `doc_lines` = 80, `total_diff_lines` = 80, ratio = 1.0 → `doc_heavy_pr = true`

**Determination**:

```
doc_heavy_pr = (doc_lines_ratio >= lines_ratio_threshold)
            OR (doc_files_count_ratio >= count_ratio_threshold AND total_diff_lines < max_diff_lines_for_count)

# Phase 5.4 Integrated Report 表示用 retained flags の explicit set (Phase 5.1.3 Retained flags 節で参照される)
doc_heavy_pr_value            = doc_heavy_pr   # boolean 表示用 (Phase 5.4 template から参照される)
doc_heavy_pr_decision_summary = <1 行要約文字列>
    # 要約の生成ルール (Claude は以下のテンプレートから実データを埋めて set する。
    # 評価順序は以下の上から下へ、最初にマッチしたケースの文字列を採用する):
    #   - doc_heavy_pr == true の場合:
    #       lines 方式が発火した (doc_lines_ratio >= lines_ratio_threshold) →
    #         "doc_lines_ratio={value} >= {lines_ratio_threshold}"
    #       count 方式が発火した (doc_files_count_ratio >= count_ratio_threshold AND total_diff_lines < max_diff_lines_for_count) →
    #         "doc_files_count_ratio={value} >= {count_ratio_threshold} AND total_diff_lines={N} < {max_diff_lines_for_count}"
    #   - doc_heavy_pr == false の場合 (上から評価して最初にマッチしたケースを採用):
    #       (1) all_files_excluded == true (上記で計算済み) →
    #             "rite plugin self-only (excluded): all changed files match exclusion patterns"
    #       (2) total_diff_lines == 0 or total_files_count == 0 (空 PR) →
    #             "empty diff (no changed files)"
    #             ※実際にはゼロ除算ガードで早期 exit するためここには到達しないが、防御的に記載
    #       (3) それ以外 (ratio 未満) →
    #             "doc_lines_ratio={value} < {lines_ratio_threshold} AND doc_files_count_ratio={value} < {count_ratio_threshold}"
```

Retain `{doc_heavy_pr}`, `{doc_heavy_pr_value}`, `{doc_heavy_pr_decision_summary}` in the conversation context for use in Phase 2.2.1, Phase 5.1.3, and Phase 5.4 template expansion. All 3 flags are **explicitly set** in every reachable path (including `total_diff_lines == 0` / `total_files_count == 0` early exits above, where `doc_heavy_pr = false` / `doc_heavy_pr_value = false` / `doc_heavy_pr_decision_summary = "empty diff (no changed files)"` must be set before `skip to Phase 1.3`).

**Mandatory `[CONTEXT]` emission for symmetry**:

Determination block の計算が完了した直後 (上記 3 flag を explicit set した直後)、**正常経路でも skip 経路と対称に必ず以下の `[CONTEXT]` 行を bash block の stdout に echo する**。これは Phase 2.2.1 / Phase 5.1.3 / Phase 5.4 で会話履歴 grep により `{doc_heavy_pr}` 等を読み戻す際の決定論性を保証するための非対称性解消修正である:

```bash
# 全経路 (正常 / 空 PR / inconsistent files race / 全ファイル excluded) で必ず実行
# 値は上記 Determination の計算結果 (boolean / string) を embed する
echo "[CONTEXT] doc_heavy_pr=${doc_heavy_pr_value}; doc_heavy_pr_value=${doc_heavy_pr_value}; doc_heavy_pr_decision_summary=${doc_heavy_pr_decision_summary}"
```

**理由**: 旧実装では skip 経路 (例: `inconsistent_files_count_between_phase_1_1_and_1_2_7`) のみ `[CONTEXT]` 行を emit し、正常経路は emit しない**非対称設計**だった。後続 phase (Phase 2.2.1 / 5.1.3 / 5.4) は「`[CONTEXT]` 行が会話履歴に存在しない = 正常」という negative inference に依存していたが、これは Claude の context grep が前 session の `[CONTEXT] doc_heavy_pr=true` を誤拾いするリスクを生む。全経路で対称に emit することで、後続 phase の grep は常に最新の `[CONTEXT]` 行を decisive に拾える。

**Note**: ゼロ除算ガード (`total_diff_lines == 0` および `total_files_count == 0`) は疑似コードブロック内にインラインで配置済みで、両方とも `doc_heavy_pr = false` を **explicit set** してから `skip to Phase 1.3` する。Skip conditions section の `changedFiles == 0` と併せて、空 PR・分母 0・undefined 参照の三方向を防ぐ多重ガードとなる。Phase 2.2.1 で `{doc_heavy_pr} == true` を判定する時点で `{doc_heavy_pr}` が必ず boolean として set されていることが保証される。

### 1.3 Identify Related Issue

Extract the Issue number from the PR branch name or body.

**Extraction priority order:**
1. Search for `Closes #XX`, `Fixes #XX`, `Resolves #XX` patterns in the **PR body** (preferred)
2. If not found in the PR body, search for the `issue-{number}` pattern in the **branch name**

**Extraction method:**
1. Search for `Closes/Fixes/Resolves #XX` (case-insensitive) in the PR body. If multiple matches, use only the first one
2. Fallback: Extract `issue-(\d+)` from the branch name

Retain the Issue number in the conversation context for use in Phase 6.4.

### 1.3.1 Load Issue Specification

**Purpose**: Load the specification from the related Issue (particularly the "仕様詳細" and "技術的決定事項" sections) and use it as review criteria.

**Execution condition**: Execute only if the Issue number was identified in Phase 1.3. Skip this phase if no Issue number was found.

**Steps:**

1. Retrieve the Issue body:
   ```bash
   gh issue view {issue_number} --json body --jq '.body'
   ```

2. Extract the following sections from the retrieved body (if they exist):
   - The entire `## 仕様詳細` section
   - The `### 技術的決定事項` subsection
   - The `### ユーザー体験` subsection
   - The `### 考慮済みエッジケース` subsection
   - The `### スコープ外` subsection

3. Retain the extracted specification as `{issue_spec}` in the conversation context for use in the Phase 4.5 review instructions.

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

## Phase 2: Reviewer Selection (Progressive Disclosure)

### 2.1 Load Skill Definitions

Load reviewer selection metadata from `skills/reviewers/SKILL.md`:

```
Read: skills/reviewers/SKILL.md
```

**Fallback on load failure:**
If the skill file is not found, use the built-in pattern table from Phase 2.2 and the fallback profiles from Phase 4.2.

### 2.2 File Pattern Analysis

Match changed files against the pattern table in SKILL.md.

Match changed files against the Available Reviewers table in `skills/reviewers/SKILL.md` (source of truth for file patterns). Each skill file's Activation section defines detailed patterns.

**Pattern priority rules:**
1. `commands/**/*.md`, `skills/**/*.md`, `agents/**/*.md` -> Prompt Engineer (highest priority)
2. Other `**/*.md` -> Technical Writer
3. If matching multiple patterns, include all matching reviewers as candidates

### 2.2.1 Doc-Heavy Reviewer Override

**Execution condition**: `{doc_heavy_pr} == true` (determined in Phase 1.2.7)

**Skip condition**: `{doc_heavy_pr} == false` — proceed directly to Phase 2.3 with no change to the reviewer candidate list.

When the PR is doc-heavy, override reviewer selection to ensure documentation quality is rigorously checked against implementation reality:

1. **tech-writer 必須昇格**: Phase 2.2 で tech-writer が候補に含まれている場合、その selection_type を現在値 (`detected` / `recommended` のいずれか) から `mandatory` に昇格する (昇格パスは Phase 3.2 selection_type と同じ語彙: `detected → recommended → mandatory`)。含まれていない場合は mandatory として新規追加する
   - **到達可能性 note**: doc_heavy_pr = true でかつ tech-writer が候補にないケースは、tech-writer.md Activation と review.md `doc_file_patterns` の集合等価性が保たれている限り発生しない。しかし将来両者が drift する可能性に備え、新規追加経路を残す (防御的フォールバック)
   - **自動検証 (Issue #353 系統 1)**: 両ファイルの Activation patterns 等価性は `plugins/rite/hooks/scripts/doc-heavy-patterns-drift-check.sh` で自動検証される (/rite:lint Phase 3.7 から呼び出し)。SKILL.md Reviewers テーブルの tech-writer 行も同検証対象に含まれる (3 ファイル集合等価性)。過去に SKILL.md と review.md / tech-writer.md の drift が発生した実例に基づき実装
2. **code-quality co-reviewer 条件付き追加**: doc-heavy PR でも `commands/`, `skills/`, `agents/` 以外の `.md` 内に bash/yaml/code blocks が含まれることがあり、これらを構造的に検証するため code-quality を co-reviewer として追加する。**ただし純粋散文 (README 文言修正のみ等) PR で空所見の reviewer がトリガーされノイズ化することを防ぐため、Phase 2.3 「Code block detection in `.md` files」と同じスキャンロジックを再利用し、diff 内に fenced code block (` ```bash `, ` ```yaml `, ` ```python ` 等) が検出された場合のみ追加する**。

   **scan ロジック** (Phase 2.3 と **同じ fenced code block 検出正規表現** (`^\+[[:space:]]*` + tagged fence `` ``` `` + 言語 tag) を使う。ただし **scope は異なる** — Phase 2.2.1 は Doc-Heavy PR の性質上 `*.md` 全体を scan 対象とするのに対し、Phase 2.3 の Code block detection は Prompt Engineer の Activation patterns (`commands/**/*.md`, `skills/**/*.md`, `agents/**/*.md`) のみを scan 対象とする。さらに Phase 2.3 が untyped fence ` ``` ` も検出するのに対し、本 Phase 2.2.1 では tagged fence のみに限定する。理由は本 phase が code-quality 追加判定の先取りであり、untyped fence は Phase 2.3 で同じ目的を達成するため。CHANGELOG の "fenced code blocks (` ```bash ` / ` ```yaml ` / ` ```python ` etc.)" 文言とも一致):

   ```bash
   # diff 全体に fenced code block の追加が含まれるかをスキャン
   # `^+` で始まる行 (追加行) のうち ```{lang} で始まる行を grep
   #
   # 歴史的背景 — pipefail の経緯:
   # 旧実装では `git diff | grep | head` の pipeline を使用しており、`set -o pipefail`
   # がないと git diff が exit != 0 で失敗しても後段の grep / head が exit 0 + 空文字列を
   # 返し、silent failure が発生していた (Issue #350 検証付きレビューで指摘)。
   # 現行実装 (PR #396) では pipeline を廃止し、`diff_out=$(git diff ...)` で独立実行 +
   # exit code 明示 check (下記 `if ! diff_out=` 行) → `grep ... <<< "$diff_out"` の here-string 構成に
   # 移行したため、pipefail が直接必要な pipeline は存在しない。ただし将来の pipeline
   # 追加時の防御として `set -o pipefail` を維持している。
   #
   # 加えて {base_branch} placeholder が未展開だった場合の guard も入れる (Claude が
   # スクリプト生成時に置換を忘れた場合の早期検出)。
   set -o pipefail

   case "{base_branch}" in
     "{base_branch}"|"")
       echo "ERROR: {base_branch} placeholder が未展開、または空です (Claude の置換忘れ)" >&2
       echo "  対処: rite-config.yml の branch.base から base branch 名を取得して置換してください" >&2
       exit 1 ;;
   esac

   # trap + cleanup パターンの canonical 説明は references/bash-trap-patterns.md#signal-specific-trap-template 参照
   # (rationale: 「パス先行宣言 → trap 先行設定 → mktemp」の順序、signal 別 exit code、${var:-} safety)
   git_diff_err=""
   _rite_review_p221_cleanup() {
     rm -f "${git_diff_err:-}"
   }
   trap 'rc=$?; _rite_review_p221_cleanup; exit $rc' EXIT
   trap '_rite_review_p221_cleanup; exit 130' INT
   trap '_rite_review_p221_cleanup; exit 143' TERM
   trap '_rite_review_p221_cleanup; exit 129' HUP

   git_diff_err=$(mktemp /tmp/rite-review-p221-diff-err-XXXXXX) || {
     echo "ERROR: git_diff_err 一時ファイルの作成に失敗" >&2
     exit 1
   }

   # git diff を独立実行し exit code を明示 check (silent failure-hunter Finding 対応)
   if ! diff_out=$(git diff "{base_branch}...HEAD" -- '*.md' 2>"$git_diff_err"); then
     echo "WARNING: Phase 2.2.1 の git diff が失敗しました (exit != 0)" >&2
     echo "  詳細: $(cat "$git_diff_err")" >&2
     echo "  考えられる原因: shallow clone (base branch 未 fetch) / 不正な branch 名 / git リポジトリ外で実行" >&2
     echo "  対処: git fetch origin {base_branch} を実行後に再試行、または rite-config.yml の branch.base を確認" >&2
     echo "  fail-safe: code-quality co-reviewer 追加判定が実行できないため、明示的に追加します (silent skip より明示的追加を選ぶ — reviewer 数が 1 増えるだけの副作用に留めて Doc-Heavy mode の検証強度を維持する)" >&2
     # fail-safe sentinel で「判定不能」を後続に伝達
     has_added_fenced_block="__FAIL_SAFE_ADD__"
   else
     # grep の exit 1 (no match) と exit 2 (IO error) を区別 (IO エラーを silent に握りつぶさない):
     # `|| true` で吸収すると IO error と「マッチなし」が silent に融合する。pipefail 下で
     # rc=$? を捕捉し、exit 1 のみ no-op として扱う。
     #
     # 重要 — `printf | grep -m 1` ではなく here-string `<<<` を使う (本 Issue #389):
     # pipeline `printf '%s\n' "$diff_out" | grep -m 1 ...` では **printf が上流 (writer)**、
     # **grep が下流 (reader)** となる。`grep -m 1` が 1 件マッチで早期終了すると、下流の
     # reader が閉じるため、**上流の printf に SIGPIPE が届く経路** が存在する。pipefail
     # 有効時、`$diff_out` が pipe buffer (Linux デフォルト 64KB) を超えるサイズだと printf
     # が書き込み途中で SIGPIPE を受けて rc=141 を返し、pipeline 全体の rc が 141 になる。
     # この場合 case 文の `*)` (IO error 扱い) で `__FAIL_SAFE_ADD__` sentinel が誤発火する
     # (Doc-Heavy PR で大きな diff のときに silent false positive が起こる経路)。
     #
     # `<<< "$diff_out"` は bash が入力を一時ファイル経由で grep に渡すため、書き込み中の
     # subprocess (printf) が存在せず、grep -m 1 の早期終了で SIGPIPE を受ける相手がいない。
     # これにより pipefail 下でも grep の exit 0 (マッチあり) / 1 (なし) / 2 (IO error) を
     # そのまま捕捉できる。
     #
     # (旧実装では「`grep -m 1` に変更すれば下流に SIGPIPE が届かない」と記述していたが、
     # これは pipeline 方向を誤解していた。printf が上流なので SIGPIPE は上流 printf に
     # 届く。Issue #389 で修正。)
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
         echo "WARNING: Phase 2.2.1 の grep pipeline が IO/権限エラーで失敗しました (rc=$grep_rc)" >&2
         echo "  fail-safe: 同じく __FAIL_SAFE_ADD__ sentinel で code-quality 追加に倒します" >&2
         has_added_fenced_block="__FAIL_SAFE_ADD__"
         ;;
     esac
   fi

   # 機械検証可能な形で 3 状態を stdout に明示:
   # bash block 内で `:` no-op だけだと、Claude の後続 phase が本 block の判定結果を機械的に
   # 読み取れない (会話文脈に何も残らない)。`[CONTEXT] code_quality_coreviewer_add_reason=...`
   # の形式で 3 状態を stdout に出力することで、後続 phase が context から値を読み戻して
   # candidate list 操作 (selection_type 昇格 / 新規追加 / no-op) を実行できる。
   #
   # iteration_id を付与
   # 同一 session 内で同じ review が複数回実行されると、`[CONTEXT] code_quality_coreviewer_add_reason=`
   # 行が会話履歴に複数残り、後続 phase の Claude が「最新値」を決定論的に判別できない問題があった。
   # iteration_id (`pr_number-{epoch_seconds}` 形式) を suffix に付与することで、後続 phase は
   # 「最大の iteration_id を持つ行が最新」と決定論的に判定できる (Phase 4.5.2 の confidence_override
   # tempfile path 命名規約と同型のアプローチ)。
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
   | `none` | 純粋散文 PR — code-quality 追加なし (no-op)。Phase 2.3 の sole reviewer guard が後段で追加可能性を再評価する |

   selection_type の昇格パスは Phase 3.2 Selection Type テーブルに従う: `detected → recommended → mandatory`。

   具体的な検証期待 (code-quality が追加された場合):
   - ドキュメント内 fenced code block の構文・引用・エラーハンドリング
   - ドキュメントの「実装例」コードが既存の coding style / naming convention と整合しているか
   - サンプル設定ファイル (yaml/toml/json snippets) のキー名・型・必須項目が実装スキーマと一致しているか

   既に候補に含まれている場合は selection_type を `mandatory` に引き上げる (昇格パスは Phase 3.2 Selection Type テーブルの「昇格 priority」に従う)。fenced code block が検出されなかった場合は code-quality 追加自体を skip する (Phase 2.3 と同じ判定を二重に適用するわけではなく、Phase 2.2.1 段階での先取り追加のみ条件付き)
3. **doc-heavy mode 指示の reviewer prompt 注入**: tech-writer のレビュー実行時に Phase 4.5 の prompt template に以下を注入する:
   - `{doc_heavy_pr}` placeholder に `true` を set
   - `{doc_heavy_mode_instructions}` placeholder に `tech-writer.md` の `## Doc-Heavy PR Mode (Conditional)` heading から **down to (but excluding) the next `##` heading** までを埋め込む (Phase 4.5 placeholder 表の構造的ルールと**完全一致**。drift 防止のため両者は同じ抽出ルールに統一されている)

   **必須含有性 check** (silent drift 防止 — tech-writer.md の章立て改修時の breaking change 早期検出):

   注入された `{doc_heavy_mode_instructions}` の本文中に以下の必須キーワード 4 つが含まれていることを確認する。1 つでも欠けていれば**ERROR** として処理し、retained flag `doc_heavy_post_condition` を `error` に set した上で **overall assessment を `修正必要` に強制昇格**する (silent non-compliance 防止):

   - `Doc-Heavy mode finding requirements` — Evidence literal 形式義務化セクション
   - `Doc-Heavy mode finding-count rules` — 件数非依存 META rules セクション (Phase 5.1.3 Step 2 で必要)
   - `META: All 5 verification categories executed` — 必須 META 行 (variant a/b の prefix)
   - `META: Cross-Reference partially skipped` — 部分スキップ用 META 行 (variant c)

   いずれかが欠けている場合の処理 (ERROR、stderr WARNING のみでは silent non-compliance を許してしまうため processing も block する):

   1. **ERROR を stderr に出力**:
      ```
      ERROR: tech-writer.md の `## Doc-Heavy PR Mode (Conditional)` セクションから {doc_heavy_mode_instructions} を抽出しましたが、必須キーワード {missing_keywords} が含まれていません。
      tech-writer.md の章立てが過去のバージョンから drift しているため、Phase 5.1.3 Step 2 (件数非依存 META check) が silent fail する恐れがあります。
      Action: tech-writer.md の `## Doc-Heavy PR Mode (Conditional)` セクション全体を確認し、必須サブセクションが含まれているか検証してください。
      Note: 本 drift は Issue #353 系統 2 (canonical category name literal match) に分類される。Issue #353 系統 1 (doc_file_patterns 集合等価性) の drift lint `plugins/rite/hooks/scripts/doc-heavy-patterns-drift-check.sh` はこの章立て drift は検出しない。章立て drift の自動検出は将来 Issue で追跡。
      ```
   2. **Retained flag set**: `doc_heavy_post_condition = "error"` を context に明示保持。Phase 5.4 表示でこの値を `error: tech-writer.md の章立て drift により protocol 未伝達 (missing: {missing_keywords})` として表示する
   3. **Overall assessment 強制昇格**: Phase 5 で計算される overall assessment を `修正必要` に強制 set する (本来 `マージ可` だった場合でも override する)。これにより e2e flow の review-fix loop が必ず再実行される

   これにより `internal-consistency.md` の 5 カテゴリ verification protocol が reviewer に直接伝達され、各 finding に `- Evidence: tool=Grep, path=src/config/services.ts, line=5-12` の **literal 形式**の行を必須化する仕様が reviewer 側で有効になる (tool は `Grep` / `Read` / `Glob` / `WebFetch` から 1 つ選択 — 山括弧はメタ記法であり literal に書いてはならない。詳細は [`tech-writer.md`](../../skills/reviewers/tech-writer.md) の "Doc-Heavy mode finding requirements" セクション参照)。Phase 5.1.3 で post-condition check を実行する。

**Relationship to Phase 2.3 sole reviewer guard**:

本 Override は Phase 2.3 (Content Analysis) および sole reviewer guard の**前**に実行される。Override 実行後に確定する reviewer 数は **fenced code block 検出の有無により分岐**する:

| **`code_quality_coreviewer_add_reason`** | 確定 reviewer | sole reviewer guard の挙動 |
|--------------------------------------|--------------|------------------------------|
| `fenced_block_detected` | tech-writer (mandatory) + code-quality (co-reviewer) → ≥2 reviewers | guard は**発火しない** (既に >=2 のため) |
| `fail_safe_diff_or_grep_failure` | 同上 (fail-safe で code-quality を追加) → ≥2 reviewers | guard は**発火しない** |
| `none` (純粋散文 PR — fenced block なし) | tech-writer のみ 1 人 | **guard が発火**して fallback 経路で code-quality を追加 → 最終的に ≥2 reviewers が保たれる |

Possible `code_quality_coreviewer_add_reason` values: (`fenced_block_detected` / `fail_safe_diff_or_grep_failure` / `none`)

つまり「Phase 2.2.1 で先取り追加が発生する」か「Phase 2.3 の sole reviewer guard が後段で fallback 追加する」かのいずれかの経路で必ず ≥2 reviewers が保たれる。Phase 2.3 の既存ロジックは破壊されず、Override は加算経路を 1 つ追加するだけである。

> **設計補足**: 純粋散文 PR で Phase 2.2.1 の先取り追加が skip されても、最終結果として code-quality は追加される。Phase 2.2.1 の意義は「先取り追加によって sole reviewer guard が走らない fast path を提供する」ことであり、guard 経由の fallback も同等の最終状態 (≥2 reviewers) に到達することを保証している。

**Override の累積効果**: 本 Override は reviewer 候補リストに対する**加算のみ**を行い、既存候補を削除しない。Phase 2.2 で候補に選定された他 reviewer (security, api, frontend, etc.) はそのまま保持される。

### 2.3 Content Analysis (Supplementary Determination)

Analyze the diff content to determine if additional expertise is needed:

**Security keyword detection:**
- `password`, `token`, `secret`, `auth`, `crypto`, `hash`, `encrypt`, `decrypt`, `credential`, `api_key`, `private_key`, `cert`
- On detection: Mark Security Expert as candidate (final selection determined in Phase 3.2)

**Performance keyword detection:**
- `cache`, `async`, `await`, `promise`, `worker`, `batch`, `optimize`
- On detection: Raise the priority of the domain expert selected based on the relevant file type (e.g., performance keywords in API files -> raise API Design Expert priority)

**Database keyword detection:**
- `query`, `migration`, `schema`, `index`, `transaction`, `rollback`
- On detection: Add Database Expert

**Error handling keyword detection:**
- JS/TS: `try`, `catch`, `throw`, `Error`, `reject`, `fallback`, `finally`
- Bash: `set -e`, `pipefail`, `trap`, `|| true`, `|| :`, `2>/dev/null`
- On detection: Add Error Handling Expert

**Type design keyword detection:**
- `interface`, `type`, `enum`, `class`, `struct`, `readonly`, `generic`
- On detection: Add Type Design Expert

**Code block detection in `.md` files:**
- When changed files include `.md` files matching Prompt Engineer patterns (`commands/**/*.md`, `skills/**/*.md`, `agents/**/*.md`), scan the diff for fenced code blocks (` ```bash `, ` ```sh `, ` ```yaml `, ` ```python `, ` ```json `, ` ```javascript `, ` ```typescript `, or untyped ` ``` `)
- On detection: Add Code Quality reviewer as **co-reviewer** alongside Prompt Engineer
- **Scope**: Only diff content is scanned (not the entire file). If the diff contains at least one fenced code block opening marker, the condition is met
- **Note**: This does not affect `.md` files outside Prompt Engineer patterns (e.g., `docs/**/*.md`). Pure documentation `.md` changes without code blocks do not trigger this rule

**Sole reviewer guard:**
- After all keyword detection and code block detection rules above have been applied, if exactly **1 reviewer** has been selected (any reviewer type, not limited to Prompt Engineer), automatically add Code Quality reviewer as a **co-reviewer**
- On detection: Add Code Quality reviewer as **co-reviewer** alongside the sole reviewer
- **Condition**: The selected reviewer count is exactly 1 after all Phase 2.3 detection rules have been applied. If 2 or more reviewers are already selected, this guard does NOT activate
- **Rationale**: A single reviewer has blind spots that cross-file consistency checks can miss. Adding a second perspective (Code Quality as baseline reviewer) mitigates this risk, following the same pattern as `pr-review-toolkit`'s always-on `code-reviewer`
- **Note**: If Code Quality is already the sole reviewer (selected as fallback in Phase 3.2), this guard does not add a duplicate. The guard only applies when a non-Code-Quality reviewer is the sole selection

### 2.4 Create Reviewer Candidate List

**`reviewer_type` format:**
- Use English slugs (e.g., `security`, `devops`, `prompt-engineer`, `tech-writer`)
- Matches the skill file name without extension (e.g., `security.md` -> `security`)

```
検出された専門領域:
- {reviewer_type_1}: {files_count} ファイル
- {reviewer_type_2}: {files_count} ファイル
...
```

**Japanese conversion for display:**

Refer to the "Reviewer Type Identifiers" table in `skills/reviewers/SKILL.md` (source of truth). When adding new reviewers, update SKILL.md first.

---

## Phase 3: Dynamic Reviewer Count Determination

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
  min_reviewers: 1      # フォールバック用
  criteria:
    - file_types
    - content_analysis
  security_reviewer:
    mandatory: false                       # 全 PR で必須選定するか
    recommended_for_code_changes: true     # 実行可能コード変更時は推奨
```

**Default values when `rite-config.yml` does not exist:**

| Setting | Default Value |
|---------|-------------|
| min_reviewers | 1 |
| criteria | file_types, content_analysis |
| security_reviewer.mandatory | false |
| security_reviewer.recommended_for_code_changes | true |

**Selection logic:**

Select **all** reviewers matched in Phase 2. No prioritization by scale (file count) is applied.

| Condition | Selected Reviewers |
|------|---------------------|
| Matched by pattern matching or content analysis | All matched reviewers |
| No reviewers matched | code-quality reviewer (min_reviewers applied) |

**Conditional selection of Security Expert:**

Determine Security Expert selection based on the `review.security_reviewer` setting in `rite-config.yml`.

| Condition | Security Expert | Selection Type | Config-Dependent |
|------|-------------------|---------|---------|
| `security_reviewer.mandatory: true` | Include (mandatory) | `mandatory` | `security_reviewer.mandatory` |
| File pattern match in Phase 2.2 (`**/security/**`, `**/auth/**`, etc.) | Include (recommended) | `recommended` | -- |
| Changes to executable code AND `recommended_for_code_changes: true` | Include (recommended) | `recommended` | `security_reviewer.recommended_for_code_changes` |
| Changes to executable code AND `recommended_for_code_changes: false` | Only when security keywords are detected in Phase 2.3 | `detected` | -- |
| Non-executable files only (`.md`, `.yml`, `.yaml`, `.json`, `.toml`, `.ini`, etc.) | Only when security keywords are detected in Phase 2.3 | `detected` | -- |

**Executable code extensions**: `.ts`, `.py`, `.go`, `.js`, `.jsx`, `.tsx`, `.rs`, `.java`, `.rb`, `.php`, `.c`, `.cpp`, `.sh`, etc.

**Note**: "Security keywords detected in Phase 2.3" refers to the keyword list defined in Phase 2.3 ("Security keyword detection" section). Do not maintain separate keyword lists here.

**Selection Type** indicates the reason for including the Security Expert. Claude retains the determined Selection Type value internally and uses it in Phase 3.3 to determine removal behavior:

| Selection Type | Meaning | Removable in Phase 3.3 |
|---------------|---------|-------------------|
| **`mandatory`** | `mandatory: true` in config | No (backward compatible) |
| **`recommended`** | Selected via file pattern match or `recommended_for_code_changes` | Yes (with warning) |
| **`detected`** | Selected via keyword detection in Phase 2.3 | Yes (with warning) |

**昇格 priority** (Phase 2.2.1 Doc-Heavy Reviewer Override 等で referenced): `detected < recommended < mandatory`

Phase 2.2.1 や他の override ロジックが「reviewer の selection_type を引き上げる」場合、上記順序で**より高い側に変更する** (例: `detected → recommended` や `recommended → mandatory`)。逆方向への降格 (`mandatory → recommended` 等) は行わない。同じ selection_type への "変更" は no-op。

**Determination flow:**
1. Check `security_reviewer.mandatory` in `rite-config.yml`
2. If `mandatory: true` -> Include Security Expert with selection type `mandatory`
3. If `mandatory: false` (or unset):
   a. Check if Security Expert was already matched by file patterns in Phase 2.2 (`**/security/**`, `**/auth/**`, etc.)
   b. If pattern matched -> Include Security Expert with selection type `recommended`
   c. If not pattern matched, analyze extensions from the changed file list
   d. If executable code changes exist AND `recommended_for_code_changes: true` -> Include Security Expert with selection type `recommended`
   e1. If executable code changes exist AND `recommended_for_code_changes: false` -> Search diff content for security keywords (Phase 2.3)
   e2. If non-executable files only (no executable code changes) -> Search diff content for security keywords (Phase 2.3)
   f. If keywords detected -> Include Security Expert with selection type `detected`
   g. If no keywords detected -> Do not include Security Expert

**Note**: When `security_reviewer.mandatory: true`, mandatory selection for all PRs is maintained (backward compatibility). The `recommended_for_code_changes` setting is only evaluated when `mandatory: false`.

**When the reviewer count is large (4 or more):**
When the reviewer count reaches 4 or more, recommend splitting the review execution following the "Specific procedures for split execution" in `skills/reviewers/SKILL.md`.

### 3.3 Confirm Reviewers

> **⚠️ MANDATORY**: This `AskUserQuestion` confirmation MUST be executed even within the `/rite:issue:start` end-to-end flow. Do NOT skip this step for context optimization or any other reason. The user must always confirm the reviewer configuration before review execution begins.

Confirm the reviewer configuration with `AskUserQuestion` (fallback: see Phase 1.4 note):

```
以下のレビュアー構成でレビューを実行します:

変更規模:
- 変更ファイル: {changedFiles} 件
- 追加: +{additions} 行 / 削除: -{deletions} 行

選定されたレビュアー ({count}人):
1. {reviewer_type_1} - {reason} {label}
2. {reviewer_type_2} - {reason} {label}
...

オプション:
- この構成でレビュー開始（推奨）
- レビュアーを追加
- レビュアーを減らす
- キャンセル
```

**Note**: `{label}` is placed after `{reason}` to keep the reviewer name as the first visible element for quick scanning. When `{label}` is empty (other reviewers), omit both the space and `{label}` from the output.

**Examples:**
- Good: `1. セキュリティ専門家 - 実行可能コード変更 [推奨]`
- Good: `1. セキュリティ専門家 - auth/ パターン一致 [推奨]`
- Good: `1. プロンプトエンジニア - コマンド定義変更`
- Bad: `1. プロンプトエンジニア - コマンド定義変更 ` (trailing space)

**`{label}` display rules:**

| Selection Type (from Phase 3.2) | `{label}` Display | Description |
|------|-----------|------|
| **`mandatory`** | `[必須]` | `mandatory: true` in config; cannot be removed |
| **`recommended`** | `[推奨]` | Selected via file pattern match or `recommended_for_code_changes`; can be removed with warning |
| **`detected`** | `[検出]` | Selected via keyword detection in Phase 2.3; can be removed with warning |
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

## Phase 4: Generator Phase (Parallel Review Execution)

> **Plugin Path**: Resolve `{plugin_root}` per [Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script-full-version) before reading plugin files.

### 4.0.W Wiki Query Injection (Conditional)

> **Reference**: [Wiki Query](../wiki/query.md) — `wiki-query-inject.sh` API

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
case "$wiki_enabled" in false|no|0) wiki_enabled="false" ;; true|yes|1) wiki_enabled="true" ;; *) wiki_enabled="true" ;; esac  # #483: opt-out default
case "$auto_query" in true|yes|1) auto_query="true" ;; *) auto_query="false" ;; esac
echo "wiki_enabled=$wiki_enabled auto_query=$auto_query"
```

If `wiki_enabled=false` or `auto_query=false`, skip this section and set `{wiki_context}` to empty string in Phase 4.5.

**Step 2**: Generate keywords from the PR context and invoke the query:

Keywords are derived from: changed file paths (from Phase 1.2) and file type categories (e.g., `hooks`, `commands`, `review`, `security`).

```bash
# {plugin_root} はリテラル値で埋め込む
# {keywords} は変更ファイルパス + ファイル種別をカンマ区切りで生成
wiki_context=$(bash {plugin_root}/hooks/wiki-query-inject.sh \
  --keywords "{keywords}" \
  --format compact 2>/dev/null) || wiki_context=""
if [ -n "$wiki_context" ]; then
  echo "$wiki_context"
fi
```

**Step 3**: If `wiki_context` is non-empty, retain it for injection into the review instruction template (Phase 4.5) via the `{wiki_context}` placeholder. If empty, set `{wiki_context}` to empty string (the placeholder section will be omitted).

### 4.1 Dynamic Loading of Expert Skills

Load each selected reviewer's skill file using the Read tool.

**Loading procedure:**

For each selected reviewer, load the corresponding skill file:

```
Read tool で以下のファイルを読み込み:
  {plugin_root}/skills/reviewers/{reviewer_type}.md
  （例: {plugin_root}/skills/reviewers/security.md）

読み込み後、以下の情報を抽出:
  - Role: レビュアーの役割定義
  - Review Checklist: チェック項目（Critical/Important/Recommendations）
  - Severity Definitions: 重要度の定義
  - Output Format: 出力形式のテンプレート
```

**Example: When Security Expert and Prompt Engineer are selected:**

1st Read: `{plugin_root}/skills/reviewers/security.md`
2nd Read: `{plugin_root}/skills/reviewers/prompt-engineer.md`

**On skill file load failure:**
If the file is not found, continue using the built-in fallback profile from Phase 4.2.

### 4.2 Fallback Profiles

**When Phase 4.1 skill file loading fails**, load the fallback profiles:

```
Read: {plugin_root}/commands/pr/references/reviewer-fallbacks.md
```

Use the fallback profile for the reviewer whose skill file failed to load.

### 4.3 Review Execution

**⚠️ CRITICAL — Sub-Agent Invocation is MANDATORY**: Regardless of `review_mode` (`full` or `verification`), Phase 4.3 **MUST** invoke sub-agents via the Task tool. Do NOT perform review inline or manually verify the diff without sub-agents — this applies even when the incremental diff is small or when context pressure is high.

- `review_mode == "full"`: Sub-agents execute the Phase 4.5 template
- `review_mode == "verification"`: Sub-agents execute BOTH Phase 4.5.1 (verification) AND Phase 4.5 (full) templates. Pass both templates in a single Task tool prompt per reviewer. The sub-agent returns consolidated results covering both verification and full review.

Performing verification inline (without sub-agents) is a **review quality failure** — it bypasses the reviewer's Detection Process, Confidence Scoring, and Cross-File Impact Check, producing rubber-stamp approvals.

**Pre-execution message** (displayed before launching review agents):
Output a brief status message to set user expectations:
`{count} 人のレビュアーで並列レビューを実行中です。1-2分お待ちください。`

Execute parallel reviews using sub-agents (defined in the `agents/` directory) corresponding to the reviewers selected in Phase 2.

**Available reviewer agents:**

| Agent | File | Specialty |
|-------------|---------|---------|
| Security Expert | `security-reviewer.md` | Authentication/authorization, vulnerabilities, encryption |
| Performance Expert | `performance-reviewer.md` | N+1 queries, memory leaks, algorithm efficiency |
| Code Quality Expert | `code-quality-reviewer.md` | Duplication, naming, error handling |
| API Design Expert | `api-reviewer.md` | REST conventions, interface design |
| Database Expert | `database-reviewer.md` | Schema design, query optimization |
| DevOps Expert | `devops-reviewer.md` | CI/CD, infrastructure configuration |
| Frontend Expert | `frontend-reviewer.md` | UI components, accessibility |
| Test Expert | `test-reviewer.md` | Test quality, coverage |
| Dependencies Expert | `dependencies-reviewer.md` | Package management, vulnerabilities |
| Prompt Engineer | `prompt-engineer-reviewer.md` | Skill/command/agent definition quality |
| Technical Writer | `tech-writer-reviewer.md` | Document clarity, accuracy |
| Error Handling Expert | `error-handling-reviewer.md` | Silent failures, error propagation, catch quality |
| Type Design Expert | `type-design-reviewer.md` | Type encapsulation, invariant expression, enforcement |

**Loading sub-agent definition files:**

1. Load the definition file corresponding to the reviewer selected in Phase 2:
   ```
   Read: {plugin_root}/agents/{reviewer_type}-reviewer.md
   ```
   Example: `security` -> `{plugin_root}/agents/security-reviewer.md`

2. On load failure, display a warning and skip that sub-agent

3. **Extract `{shared_reviewer_principles}`** (from `_reviewer-base.md`):

   Under named subagent invocation (Phase B / #358), the agent file body becomes the **system prompt** automatically — so the agent-specific identity no longer needs to be extracted or injected via the user prompt. Agent-specific discipline (Core Principles, Detection Process, Confidence Calibration, Detailed Checklist, Output Format) is delivered through the named subagent's system prompt.

   However, `_reviewer-base.md` (the shared reviewer principles) is **not** automatically injected into named subagents — it is a separate file that only a reviewer *agent* would reference. To preserve the cross-file impact checks and shared discipline across all reviewers (Phase A / #357 bug fix), this hybrid approach continues to extract `_reviewer-base.md` and pass it via the **user prompt** as `{shared_reviewer_principles}`.

   **Extraction procedure**:
   - Load `{plugin_root}/agents/_reviewer-base.md` with the Read tool
   - Extract **all sections** from `_reviewer-base.md` between the document start and the `## Input` heading (exclusive). This includes:
     - `## READ-ONLY Enforcement`
     - `## Reviewer Mindset`
     - `## Cross-File Impact Check`
     - `## Confidence Scoring`
   - **Important**: Do NOT extract only a subset of the above sections individually — doing so would drop the sections that sit between them in document order. Extracting the contiguous range from the document start to `## Input` ensures all shared principles (READ-ONLY state-level enforcement, mindset, cross-file impact checks, confidence scoring) reach the reviewer agent.
   - These sections define the universal principles all reviewers must follow (READ-ONLY state guarantee, mindset, mandatory cross-file impact checks, and confidence scoring framework)

   **Fallback**: If extraction fails or yields empty content, set `{shared_reviewer_principles}` to an empty string. The review will still function using the named subagent's system prompt (which contains the reviewer-specific identity) plus `{skill_profile}` and `{checklist}` from the user prompt.

**Parallel execution using the Task tool:**

Achieve parallel execution by **invoking multiple Task tools in a single message** for all selected sub-agents.

Pass the following information to each sub-agent:
- PR diff (or related file diffs - see reference below)
- Changed file list
- Related Issue specification (obtained in Phase 1.3.1)
- Shared reviewer principles (`{shared_reviewer_principles}` extracted above from `_reviewer-base.md`)

> **Note**: Agent-specific identity (Core Principles, Detection Process, Detailed Checklist, Output Format) is delivered automatically as the named subagent's **system prompt** when invoked via `subagent_type: rite:{reviewer_type}-reviewer`. Do NOT re-inject the agent file body via the user prompt — this would duplicate the agent body and may confuse the reviewer about which set of instructions is authoritative.

> **Diff optimization**: Apply scale-based diff passing per [Review Context Optimization](./references/review-context-optimization.md#diff-passing-optimization). Small scale: full diff. Medium/Large scale: related file diffs only + change summary for large diffs.

**Error handling:**

If the following issues occur with the sub-agent approach:
- All sub-agent definition files cannot be loaded -> Display error message and terminate
- Some Task tool calls fail -> Integrate only successful review results

**See "Task Tool Sub-Agent Invocation" below for details on the sub-agent approach.**

---

### 4.3.1 Task Tool Sub-Agent Invocation

**⚠️ IMPORTANT — Named Subagent Invocation**: Since Phase B (#358), reviewers are invoked as **named subagents** using the scoped format `rite:{reviewer_type}-reviewer`. This activates the agent body as the **system prompt** (rather than a user-prompt injection), giving reviewer discipline stronger enforcement. See [Migration Guide: Named Subagent Switch](../../../../docs/migration-guides/review-named-subagent.md) for rationale and rollback.

**Parallel execution:** Invoke multiple Task tools within a single message for all selected reviewers. Each Task uses:
- `description`: "セキュリティ専門家 PR レビュー" (short description)
- `subagent_type`: `rite:{reviewer_type}-reviewer` — scoped name derived from the reviewer selected in Phase 2 (see table below)
- `prompt`:
  - `review_mode == "full"`: Phase 4.5 format (diff, spec, shared reviewer principles, skill profile, checklist)
  - `review_mode == "verification"`: Phase 4.5.1 verification template + Phase 4.5 full template, concatenated in a single prompt. Include previous findings table and incremental diff (from Phase 1.2.4) in addition to the standard inputs.

**`reviewer_type` → `subagent_type` mapping:**

| **`reviewer_type`** (selected in Phase 2) | `subagent_type` (used in Task call) |
|---------------------------------------|-------------------------------------|
| **`security`** | `rite:security-reviewer` |
| **`performance`** | `rite:performance-reviewer` |
| `code-quality` | `rite:code-quality-reviewer` |
| **`api`** | `rite:api-reviewer` |
| **`database`** | `rite:database-reviewer` |
| **`devops`** | `rite:devops-reviewer` |
| **`frontend`** | `rite:frontend-reviewer` |
| **`test`** | `rite:test-reviewer` |
| **`dependencies`** | `rite:dependencies-reviewer` |
| `prompt-engineer` | `rite:prompt-engineer-reviewer` |
| `tech-writer` | `rite:tech-writer-reviewer` |
| `error-handling` | `rite:error-handling-reviewer` |
| `type-design` | `rite:type-design-reviewer` |

**Formula**: `subagent_type = "rite:" + reviewer_type + "-reviewer"` (the `rite:` prefix is mandatory in plugin distribution; bare `{reviewer_type}-reviewer` fails agent resolution — verified empirically in Phase 0 Item 2, see `docs/investigations/review-quality-gap-baseline.md` Section 2).

Task results are returned automatically upon completion. No explicit wait handling is needed.

**⚠️ CRITICAL**: Do NOT use `run_in_background: true` for review agents. Background agents cause the calling LLM to receive launch confirmation immediately and then repeatedly attempt to stop while waiting — triggering stop-guard blocks that inflate `error_count` and poison the circuit breaker for subsequent phases. Foreground agents launched in the same message already execute concurrently; Claude blocks until all results return, enabling seamless flow continuation.

### 4.4 Retry Logic

Retry procedure when a Task tool returns an error:

**Retry criteria:**

| Error Type | Retry | Action |
|-----------|--------|------|
| Timeout | Yes (up to 1 time) | Re-execute with the same prompt |
| Network error | Yes (up to 1 time) | Re-execute with the same prompt |
| Invalid output format | Yes (up to 1 time) | Re-execute with "output in the exact format" appended to the prompt |
| Skill file load failure | No | Substitute with fallback profile |
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
   - Proceed to Phase 5 and generate the integrated report with only other reviewers' results
   - Include "{reviewer_type}: レビュー失敗" in the integrated report

**Note**: Retries are not performed automatically. On error, prompt the user with AskUserQuestion to choose between retry or skip.

### 4.5 Review Instruction Format

Generate instructions for each reviewer.

**Finding quality guidelines:** No vague findings. Investigate with tools (Read/Grep/WebSearch) before reporting. Report only confirmed problems with specific facts/evidence.

**Mandatory fix policy:** All reported findings are blocking. Report only issues where you can point to an existing call path in the current codebase that triggers the problem under a standard user flow. Hypothetical concerns that require unusual inputs, adversarial conditions, or non-existent call sites MUST NOT be reported — unless you are the `security` reviewer reviewing an attack surface. If you cannot grep the exact triggering call site and paste its file:line, do not report the finding. "What if X happened" is not a finding; "X is already happening at file:line" is.

**Thoroughness on every cycle:** Apply the same depth and rigor on every review cycle — first pass, re-review, or verification. Do not self-censor findings because "I should have caught this earlier." If you see a real problem now, report it now. Withholding a valid finding to avoid appearing inconsistent is worse than reporting it late.

**Scope judgment rule:** Only flag issues **introduced by this PR's diff** as findings (指摘事項). Apply the revert test: "If this PR were reverted, would the problem disappear?" If No, it is a pre-existing issue — do not report it in the findings table. Pre-existing code smells, tech debt, or style inconsistencies are out of scope for findings entirely. If a pre-existing pattern warrants investigation, note it in the integrated report's "調査推奨" section instead (Phase 5) so the user can optionally run `/rite:investigate {file}` separately. Do NOT file it as a finding and do NOT auto-create an Issue for it.

**Placeholder embedding method:**

| Placeholder | Source | Extraction Method |
|---------------|--------|----------|
| `{relevant_files}` | Changed file list from Phase 1.2 | Extract only files matching the reviewer's Activation pattern |
| `{diff_content}` | Diff from Phase 1.2 | **Varies by scale** (see below) |
| `{skill_profile}` | Role + Expertise Areas section of skill file | Extract the relevant section from the skill file loaded via Read |
| `{checklist}` | Review Checklist section of skill file | Full text including Critical / Important / Recommendations |
| `{issue_spec}` | Issue specification obtained in Phase 1.3.1 | Content of the "仕様詳細" section (if empty, write "仕様情報なし") |
| `{change_intelligence_summary}` | Change Intelligence Summary from Phase 1.2.6 | One-paragraph summary of change type, file classification, and focus area |
| `{shared_reviewer_principles}` | `_reviewer-base.md` (shared) | Extract all sections from the document start to the `## Input` heading (exclusive). This covers `## READ-ONLY Enforcement`, `## Reviewer Mindset`, `## Cross-File Impact Check`, and `## Confidence Scoring` as a contiguous block. Agent-specific identity is NOT included here — it is delivered via the named subagent's system prompt (Phase B / #358). See Phase 4.3 step 3 for the full extraction procedure |
| `{change_summary}` | Scale information from Phase 1.2.1 | Used only for large diffs. Change summary table |
| `{doc_heavy_pr}` | Phase 1.2.7 result | Boolean flag (`true` / `false`). Inject only when reviewer is `tech-writer`. If `false` or reviewer != tech-writer, set to empty string |
| `{doc_heavy_mode_instructions}` | `skills/reviewers/tech-writer.md` `## Doc-Heavy PR Mode (Conditional)` section | **Conditional extraction**: Only populated when `reviewer_type == tech-writer` AND `{doc_heavy_pr} == true`. Extract the entire section from `## Doc-Heavy PR Mode (Conditional)` heading down to (but excluding) the next `##` heading. Otherwise set to empty string |
| `{wiki_context}` | Phase 4.0.W Wiki Query result | Non-empty when Wiki is enabled and related experiential knowledge was found. Empty string when Wiki is disabled, `auto_query` is false, or no matches found |

**`{diff_content}` by scale:** Small: entire diff | Medium: files matching `{relevant_files}` | Large: `{change_summary}` + matching files + Read tool instruction

**`{relevant_files}`:** Files matching reviewer's Activation pattern (Phase 2.2). Security: `**/auth/**`, Frontend: `**/*.tsx`

> **Reference**: See [review-context-optimization.md](references/review-context-optimization.md) for change summary format and retrieval guidelines.

**Review instruction template:**

```
PR #{number}: {title} のレビューを {reviewer_type} として実行してください。

## 変更概要
{change_intelligence_summary}

## レビュー対象ファイル
{relevant_files}

## 差分
{diff_content}

## 関連 Issue の仕様
{issue_spec}

**重要**: 上記の仕様は Issue で合意された要件です。実装が仕様と異なる場合は、以下のルールに従ってください:
1. **仕様どおりに実装されていない場合** → 「仕様不整合」として CRITICAL で指摘
2. **仕様自体に問題がある（矛盾、曖昧さ、技術的に不可能）と判断した場合** → 指摘として挙げず、「仕様への疑問」セクションに記載し、ユーザー確認を促す
3. **仕様に記載がない実装判断** → 通常のレビュー基準で評価

## 共通レビュー原則
<!-- `_reviewer-base.md` から抽出される全 reviewer 共通の原則。READ-ONLY Enforcement / Mindset / Cross-File Impact Check / Confidence Scoring が含まれる。reviewer 固有の identity (Core Principles / Detection Process / Detailed Checklist / Output Format) は named subagent の system prompt として自動注入されるためここには含めない -->
{shared_reviewer_principles}

## あなたの役割
{skill_profile}

## チェックリスト
{checklist}

## Doc-Heavy PR Mode (Conditional — 適用時のみ非空)
<!-- reviewer_type == tech-writer かつ doc_heavy_pr == true のときのみ内容が入る。それ以外は空文字列。 -->
{doc_heavy_mode_instructions}

## プロジェクト経験則（Wiki — 該当時のみ非空）
<!-- wiki.enabled && wiki.auto_query のとき、Phase 4.0.W で取得した経験則。空の場合はこのセクション自体を省略 -->
{wiki_context}

## 出力フォーマット
以下の形式で評価を出力してください:

### 評価: [可 / 条件付き / 要修正]

### 所見
[レビュー結果のサマリー]

### 仕様との整合性
| 仕様項目 | 実装状態 | 備考 |
|---------|---------|------|
| {spec_item} | 準拠 / 不整合 / 未実装 | {notes} |

### 仕様への疑問（該当がある場合のみ）
[仕様自体に問題があると判断した点。これらは指摘ではなく、ユーザーへの確認事項として扱う]

### 指摘事項

**重要**: 指摘事項テーブルに記載する項目は全て**必須修正**として扱われます。「任意」「推奨」「必須ではないが」といった修正は指摘事項に含めず、下の「推奨事項」セクションに記載してください。

指摘を挙げる前に、以下の **4 必須自問** に全て Yes で答えられるかを確認してください。いずれかが No の場合、推奨事項 欄に落とすか、報告しないでください:

1. **マージブロック基準**: この問題を修正しなければマージすべきでないと確信できるか？
2. **Confidence 基準**: 確信度 (Confidence) が 80 以上か？
3. **Observed Likelihood 基準**: この問題が発生する call site を今のコードから Grep で示せるか？（ハイポセティカル禁止）
4. **立証責任基準**: 指摘の内容欄に「{file}:{line} でこの入力が渡される」と書けるか？（証拠提示必須）

| 重要度 | ファイル:行 | 内容 | 推奨対応 |
|--------|------------|------|----------|
| {CRITICAL/HIGH/MEDIUM/LOW} | {file:line} | {WHAT: 何が問題か} + {WHY: なぜ問題か（影響・リスク・既存パターンとの比較）} | {FIX: 修正方法} + {EXAMPLE: コード例（該当時）} |

### 推奨事項
[改善提案があれば（任意の改善、スタイル提案、本 PR の diff と無関係な気になる点など）。各推奨事項を箇条書きで記載すること。本 PR の diff と無関係で別 Issue 化が妥当な場合は `別 Issue` または `スコープ外` キーワードを含めること（Phase 7 でユーザー確認のうえ Issue 化される）]

## 制約
[READ-ONLY RULE] このレビューは読み取り専用です。`Edit`/`Write` ツールでプロジェクトのソースファイルを修正してはなりません。問題を検出した場合は指摘事項として報告してください。修正は別プロセス（`/rite:pr:fix`）が担当します。`Bash` ツールは workflow 操作（`gh` CLI、hook scripts）と **read-only な git コマンド**（`git diff` / `git log` / `git show` / `git worktree add` などを含む — 完全な許可・禁止一覧は `plugins/rite/agents/_reviewer-base.md` の `## READ-ONLY Enforcement` を single source of truth として参照）のみ許可されます。working tree / index / ref を変更する git コマンド（`git checkout` / `git reset` / `git add` / `git stash` / `git restore` / `git rebase` / `git commit` / `git push` 等）は **禁止** です。
```

**When `{issue_spec}` is empty:** Write "仕様情報なし" and omit spec-based checks ("仕様との整合性" and "仕様への疑問" sections).

### 4.5.1 Verification Mode Review Instruction Template

When `review_mode == "verification"` (determined in Phase 1.2.4), use the following template **in addition to** the normal template from Phase 4.5. Both verification results and full review results are consolidated in the final assessment.

**Template selection logic:**

| review_mode | Template Used |
|-------------|-------------------|
| **`full`** | Normal template from Phase 4.5 only |
| **`verification`** | Both: this section's (4.5.1) verification template AND the normal template from Phase 4.5 |

**Verification mode review instruction template:**

```
PR #{number}: {title} の検証レビューを {reviewer_type} として実行してください。

## 変更概要
{change_intelligence_summary}

## Review Mode: Verification

前回の指摘が正しく修正されたかの検証と、修正箇所のリグレッションチェックに集中してください。なお、この検証レビューに加えて、フルレビューも別途実施されます。

### Part 1: 前回指摘の修正検証

前回のレビューで以下の指摘がありました。各指摘が正しく修正されたか検証してください:

{previous_findings_table}

各指摘について以下のいずれかで判定:
- **FIXED**: 推奨対応（または同等の修正）が正しく適用された
- **NOT_FIXED**: 指摘が対応されていない、または修正が不正確
- **PARTIAL**: 一部対応済み、残りの問題を具体的に記載

### Part 2: リグレッションチェック（修正差分のみ）

前回レビュー以降に変更されたファイルの差分（incremental diff）:
{incremental_diff}

これらの変更されたファイルのみを対象に、以下をチェック:
1. Fix による明らかなリグレッション（既存機能の破壊、新たなバグの導入）
2. 新たな CRITICAL/HIGH のセキュリティ脆弱性

**重要（Part 2 スコープのみに適用）**: 前回の Fix サイクルで変更されていないコードに対して新規の MEDIUM/LOW 指摘を生成しないこと。未変更コードの CRITICAL/HIGH 指摘のみ「見落とし」として報告可。この制約は Part 2（リグレッションチェック）にのみ適用されます。フルレビュー（Phase 4.5 の通常テンプレート）では、すべてのコードを対象にレビューを行ってください。

## 共通レビュー原則
<!-- `_reviewer-base.md` から抽出される全 reviewer 共通の原則。READ-ONLY Enforcement / Mindset / Cross-File Impact Check / Confidence Scoring が含まれる。reviewer 固有の identity は named subagent の system prompt として自動注入される -->
{shared_reviewer_principles}

## あなたの役割
{skill_profile}

## 出力フォーマット
以下の形式で評価を出力してください:

### 評価: [可 / 条件付き / 要修正]

### 修正検証結果

| # | 重要度 | ファイル:行 | 内容 | 判定 | 備考 |
|---|--------|------------|------|------|------|
| {n} | {severity} | {file:line} | {description} | FIXED / NOT_FIXED / PARTIAL | {notes} |

### リグレッション（修正差分で検出された問題）

| 重要度 | ファイル:行 | 内容 | 推奨対応 |
|--------|------------|------|----------|
| {severity} | {file:line} | {description} | {recommendation} |

### 未変更コードの重大指摘（該当がある場合のみ）
<!-- CRITICAL/HIGH のみ。MEDIUM/LOW は記載しない -->

| 重要度 | ファイル:行 | 内容 | 推奨対応 |
|--------|------------|------|----------|
| {severity} | {file:line} | {description} | {recommendation} |

## 制約
[READ-ONLY RULE] このレビューは読み取り専用です。`Edit`/`Write` ツールでプロジェクトのソースファイルを修正してはなりません。問題を検出した場合は指摘事項として報告してください。修正は別プロセス（`/rite:pr:fix`）が担当します。`Bash` ツールは workflow 操作（`gh` CLI、hook scripts）と **read-only な git コマンド**（`git diff` / `git log` / `git show` / `git worktree add` などを含む — 完全な許可・禁止一覧は `plugins/rite/agents/_reviewer-base.md` の `## READ-ONLY Enforcement` を single source of truth として参照）のみ許可されます。working tree / index / ref を変更する git コマンド（`git checkout` / `git reset` / `git add` / `git stash` / `git restore` / `git rebase` / `git commit` / `git push` 等）は **禁止** です。
```

**Placeholder embedding method:**

| Placeholder | Source | Extraction Method |
|---------------|--------|----------|
| `{previous_findings_table}` | Previous review finding table obtained in Phase 1.2.4 | Integrate finding tables from each reviewer in the "全指摘事項" section from the previous `📜 rite レビュー結果` comment |
| `{incremental_diff}` | `git diff {last_reviewed_commit}..HEAD` obtained in Phase 1.2.4 | Full incremental diff (however, for large scale, only files relevant to the reviewer) |
| `{change_intelligence_summary}` | Change Intelligence Summary from Phase 1.2.6 | One-paragraph summary of change type, file classification, and focus area |

---

## Phase 5: Critic Phase (Result Verification and Integration)

> **[READ-ONLY RULE]**: Critic Phase はレビュー結果の統合・評価のみを行います。`Edit`/`Write` ツールでプロジェクトのソースファイルを修正してはなりません。ブロック指摘が存在する場合は `[review:fix-needed:{n}]` を出力し、修正は `/rite:pr:fix` に委譲してください。`Bash` ツールは workflow 操作（`gh` CLI、hook scripts、`.rite-flow-state` 更新）と **read-only な git コマンド**（完全な許可・禁止一覧は `plugins/rite/agents/_reviewer-base.md` の `## READ-ONLY Enforcement` を single source of truth として参照）のみ許可されます。working tree / index / ref を変更する git コマンドは **禁止** です。

### 5.1 Result Collection

**⚠️ Scope**: Collect only newly detected findings from current review. Fixed code (not in diff) is auto-excluded; unaddressed findings are re-detected.

Task results are retained in conversation context with internal format (reviewer_type, assessment, findings: severity/file_line/description/recommendation).

**Recommendation collection for Issue candidates**: In addition to findings, also extract items from each reviewer's "### 推奨事項" section that contain any of the following keywords: `別 Issue`, `別Issueで対応`, `スコープ外`, `out of scope`, `separate issue`. Retain these as `recommendation_issue_candidates` in the conversation context (reviewer_type, content, file_line if mentioned). These are NOT findings — they do not affect the assessment, finding counts, or merge decision. They are collected solely for Phase 5.4 report inclusion and Phase 7 Issue candidate extraction.

#### 5.1.1 Verification Mode Findings Collection

When `review_mode == "verification"`, classify: NOT_FIXED/PARTIAL/REGRESSION/MISSED_CRITICAL (all blocking). FIXED findings recorded in Fix Verification Summary only.

**フルレビュー由来の新規指摘**: verification mode では、検証レビューに加えてフルレビュー（Phase 4.5 の通常テンプレート）も実施される。フルレビューで検出された新規指摘は、重要度に関わらずすべて blocking 扱いとする。これは初回フルレビューと同等の基準を適用するためであり、verification mode であることを理由に指摘を非 blocking に降格してはならない。

##### 5.1.1.1 Post-Condition Check: Verification Result Table Presence

**Execution condition**: `review_mode == "verification"` (always enforced when verification mode is active).

**Skip condition**: `review_mode == "full"` — skip this post-condition entirely.

**Purpose**: verification mode では、各 reviewer が Phase 4.5.1 の verification テンプレートに従って `### 修正検証結果` テーブルを出力することが契約である。このテーブルが欠落している場合、reviewer は「前回指摘の修正検証」を **silent に skip している可能性が高く**、結果として `finding_count == 0` と誤判定されて silent pass する経路が成立する（本 Phase 5.1.1.1 post-condition 設置の根本目的）。Phase 5.1.3 の Doc-Heavy PR Mode post-condition と同じ構造で、silent non-compliance を検出する。

**Verification step**: Collect all raw review outputs for the current cycle. For each reviewer output, search for the `### 修正検証結果` heading **in multiline mode** (since reviewer output is a multi-line markdown document):

```
(?m)^### 修正検証結果\s*$
```

**Judgment matrix** (classification vocabulary は Phase 5.1.3 と統一: `passed` / `warning` / `error`):

| Condition | Classification | Action |
|-----------|---------------|--------|
| すべての reviewer 出力に `### 修正検証結果` heading が含まれている | `passed` | `verification_post_condition: passed` を set、そのまま Phase 5.1.2 へ |
| 1 人以上の reviewer 出力に `### 修正検証結果` heading が欠落（初回検出） | `warning` | `verification_post_condition: warning` を set、下記 Retry Procedure を実行 |
| retry 実行後も欠落（2 回目以降の検出） | `error` | `verification_post_condition: error` を set、下記 Failure Procedure を実行 |

**Retry counter semantics** (per-reviewer):

`verification_post_condition_retry_count` は **per-reviewer の dict** (`{reviewer_type: int}`) として conversation context に保持する。各 reviewer が独立して 0 → 1 への transition を最大 1 回許可する。multi-reviewer 並列時は各 reviewer 単位で判定される。

**Retry Procedure** (`warning` 検出時、該当 reviewer ごとに最大 1 回):

該当 reviewer に対して Phase 4.3.1 Task tool 呼び出し手順を再利用して verification テンプレートを再送する:

- `subagent_type`: `rite:{reviewer_type}-reviewer` (Phase 4.3.1 の mapping table を参照。Phase B / #358 以降、reviewer は named subagent として呼び出される)
- `prompt` 内容: Phase 4.5.1 verification テンプレート + Phase 4.5 full テンプレート（元レビューと同じ 2 テンプレート concat）に、以下の strict 要件を追加:
  - 「`### 修正検証結果` heading と判定テーブル (`| # | 重要度 | ファイル:行 | 内容 | 判定 | 備考 |`) を **必ず**出力すること」
  - 「Phase 4.5.1 verification テンプレートの Part 1 (前回指摘の修正検証) を skip せずに実行すること」
- 入力データ (`{previous_findings_table}` / `{incremental_diff}` / `{change_intelligence_summary}`): Phase 1.2.4 で取得済みのものを再供給
- **結果 merge 戦略**: retry 結果は元 reviewer の output を **置き換える** (append ではない)。元 output は破棄し、retry output のみを Phase 5.1 結果集合に使用する
  - **Note**: retry prompt は full + verification 両 template を concat して再送している (上記 `prompt` 内容参照) ため、retry output は元 output の全指摘 (verification mode 由来 + full mode 由来) を**包含する**。元 output 内の非 verification finding が retry 置き換えで消失することはない。
- retry 実行後、`verification_post_condition_retry_count[{reviewer_type}]` を +1 し、もう一度判定条件を評価する。retry 後も欠落していれば `error` に昇格する

**Phase 4.4 retry classification との関係** (#358 Phase B で明示化):

この Phase 5.1.1.1 retry 中に Phase 4.4 の `subagent resolution failure` (`Agent type 'rite:{reviewer_type}-reviewer' not found`) が発生した場合、以下の順序で処理する:

1. **Phase 5.1.1.1 retry counter の扱い**:
   - Task tool 経由の retry call は実行される (resolution failure は call 後に検出されるため)。しかし Phase 4.4 の `Retry: No` 規則に従い、この call は `successful retry` としてカウントしない
   - `verification_post_condition_retry_count[{reviewer_type}]` は increment **しない** (counter は 0 のまま保持される)
   - 「次 cycle で再 retry されないこと」は counter / flag の pre-condition guard ではなく、**Step 3 で `verification_post_condition: error` を set することによって Judgment Matrix 行 3 (`error` 分類) に遷移し、Retry Procedure ではなく Failure Procedure に分岐させる flow 分岐によって保証される**。つまり terminal state は retry counter の数値ではなく、classification 状態 (`error`) によって実現される
2. **Phase 4.4 default action への委譲**: 当該 reviewer を Phase 4.4 retry classification 表の `subagent resolution failure` 行に定義された 2 段階 Action に従って処理する (行番号は drift するため semantic reference を使う):
   - **(a) 個別 reviewer failure (default case)**: Phase 4.4 retry classification 表の `subagent resolution failure` 行の Action column に記載されている「Mark the reviewer as 'incomplete' and continue with other reviewers」を適用する。当該 reviewer を `incomplete` としてマークし、他 reviewer の verification retry / verification processing を **継続する**
   - **(b) 全 reviewer failure (例外 case)**: 同じ Action column の後半に記載されている「If all reviewers fail this way, prompt the user with `AskUserQuestion`」に従い、**全 reviewer が同一 subagent resolution failure になった場合のみ**、Phase 4.4 の all-failed 経路に進み `AskUserQuestion` で retry / rollback / abort をユーザーに確認する
3. **Phase 5.1.1.1 Failure Procedure との合流**: 上記と並行して、当該 reviewer の verification classification を `error` に昇格する。具体的な state transition (本段落直下の Failure Procedure の 4 step に対応):
   - 元 reviewer の output (resolution failure 時は通常空、retry 試行前の初回 invocation で table 欠落状態の output が残る場合は元 output) を Failure Procedure の入力として使用
   - Failure Procedure step 1 (`verification_post_condition: error` flag set) を実行
   - Failure Procedure step 2 (overall assessment を `修正必要` に昇格) を実行
   - Failure Procedure step 3 (該当 reviewer 由来の指摘を全件 blocking 扱い) は、resolution failure 時に output が空のため「0 件 blocking 扱い」という空集合処理となり実質 no-op になる。これは意図通りの挙動で、**blocking subject が存在しなくても step 1-2 の overall 昇格は発火する** ため silent pass は起きない
   - Failure Procedure step 4 (stderr に ERROR 出力) を実行

**分離の意図**: Phase 5.1.1.1 の retry 機構は **output format 異常** (verification table 欠落) のみを対象とし、`subagent resolution failure` とは独立した経路である。この分離により、scoped subagent の解決不能という "インフラレベル" の障害と、output format の契約違反という "semantic レベル" の障害が混線することを防ぐ。LLM は上記 Step 1-3 の順序を必ず守り、「Phase 4.4 Action のみ発火」「Failure Procedure のみ発火」のいずれか一方だけを実行してはならない (両方を並行実行する)。

**Failure Procedure** (`error` 検出時、以下の 4 step を順に実行):

1. `verification_post_condition: error` フラグを set
2. overall assessment を `修正必要` に昇格（Phase 5.3 / Phase 5.4 の escalation chain と統一された label。`要修正` は reviewer 個別評価用の label で、overall 昇格には使用しない）
3. 該当 reviewer 由来の指摘を **全件 blocking 扱い**
4. stderr に下記 ERROR を出力し、silent pass 経路を完全に閉塞する

**WARNING (初回検出時、stderr)**:

```
WARNING: verification mode で reviewer の `### 修正検証結果` テーブルが欠落しています。
該当 reviewer: {reviewer_list}
Expected: Phase 4.5.1 の verification テンプレートに従い、「### 修正検証結果」heading と判定テーブル
  (| # | 重要度 | ファイル:行 | 内容 | 判定 | 備考 |) を必ず出力する。
Action: 当該 reviewer(s) を Phase 4.3.1 Task tool 経由で再実行します（verification テンプレート strict 再送、1 回まで）。
```

**ERROR (retry 後も欠落、stderr)**:

```
ERROR: verification mode で reviewer の `### 修正検証結果` テーブルが retry 後も欠落しています。
該当 reviewer: {reviewer_list}
これは reviewer が前回指摘の修正検証を silent に skip している可能性があり、
silent pass による品質劣化を防ぐため、本レビューは `修正必要` として扱います。
Action: 手動で当該 reviewer の出力を確認し、verification テンプレートへの準拠を強制してください。
```

**Post-condition の Phase 5.1.3 との関係**: Phase 5.1.3 は Doc-Heavy PR Mode（tech-writer 限定、カテゴリ別 META 行を対象）、Phase 5.1.1.1 は verification mode 全 reviewer（`### 修正検証結果` テーブル構造を対象）。両者は独立に動作し、同一レビューで両方発火する可能性がある（その場合は overall assessment は最も厳しい状態 = `修正必要` に統一される。どちらの post-condition が発火しても同一の昇格ラベルを使用する）。

**この post-condition 設置の根拠**: Phase 4.5.1 の verification テンプレートは `### 修正検証結果` の出力を義務付けているが、reviewer agent body が system prompt として与えられている現状では、reviewer が Phase 4.5 (full) の出力のみに集中して Phase 4.5.1 (verification) の出力を silent skip する経路が実証されている。Phase 5.1.1.1 は **契約違反を検出する post-condition** として、この silent skip 経路を閉塞する。

#### 5.1.2 Finding Stability Analysis

When verification mode AND `allow_new_findings_in_unchanged_code == false`: Check if finding is in incremental diff. Unchanged code: CRITICAL/HIGH → genuine (blocking), MEDIUM/LOW → stability_concern (non-blocking, informational).

**例外**: この stability_concern 分類は、Phase 4.5.1 の verification テンプレート（Part 2: リグレッションチェック）由来の指摘にのみ適用される。Phase 4.5 の通常テンプレート（フルレビュー）由来の指摘には適用しない。フルレビュー由来の指摘は 5.1.1 に従い、重要度に関わらず blocking とする。

#### 5.1.3 Doc-Heavy PR Mode Post-Condition Check

**Execution condition**: `{doc_heavy_pr} == true` (set in Phase 1.2.7) AND tech-writer is in the reviewer set.

**Skip condition**: `{doc_heavy_pr} == false` または tech-writer がレビュアー集合にない場合は本 Phase をスキップして直接 Phase 5.2 に進む。

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

上記 5 種すべて非該当の場合のみ、警告を発火する。**variant b を判定式に含める理由**: tech-writer が `finding_count == 0` でも誤って variant b 文言を出力することがあり、その場合に Step 1 の判定を厳格に variant a / c のみで行うと「META 行が 1 つもない」と誤判定して false positive で `修正必要` 降格するため。5 variant のうちどれか 1 つでも含まれていれば「META 行は存在する」とみなし、Step 1 はスキップして Step 2 (variant a/b/c/(a+inconclusive)/(b+inconclusive) の正規性 check) に処理を委ねる。

**inconclusive variant を判定式に含める理由**: `internal-consistency.md` の "Inconclusive 集計 と META 行への反映" セクションは、「Verification protocol の各 step で `target_not_found` / `extraction_failed` / `tool_failure` のいずれかが発生した場合、reviewer は META 行の variant を a/b から (a + inconclusive) / (b + inconclusive) に切り替えて出力する」と要求している。これらの inconclusive variant を Step 1 の判定式に含めないと、tech-writer が正しく inconclusive を報告しても「META 行が 1 つもない」と誤判定して二重 penalty (silent skip 検出 + inconclusive 検出) が起き silent fall-through する。新規 variant を Step 1 (および Step 2) の判定式に含めることで、protocol の inconclusive 報告を正しく受け入れ、Step 4.5 で別途 acknowledgement プロセスを発火させる。
- **WARNING を必ず stderr に出力** (silent fall-through 禁止):
  ```
  WARNING: Doc-Heavy PR mode active, but tech-writer returned 0 findings without META confirmation.
  Expected: Either explicit "META: All 5 verification categories executed, 0 inconsistencies found" declaration, or "META: Cross-Reference partially skipped" notice for external-repo documentation.
  Action: Verify tech-writer executed the 5-category verification protocol from internal-consistency.md. Re-run with explicit Doc-Heavy mode instructions if needed.
  ```
- レビュー結果に `doc_heavy_post_condition: warning` フラグを set
- overall assessment を `修正必要` に変更 (silent pass 防止)

> **Note**: `finding_count >= 1` の場合はこの Step 1 の「finding 0 件警告」をスキップするが、下記の Step 2 (META 5 カテゴリ実行確認) は**件数に関係なく必ず実施する**。post-condition が `passed` とみなされるのは、**Step 1 (finding 0 件警告) で発火せず**、かつ Step 2 (META 確認) + Step 3 (Evidence field 必須化) + Step 4 (Cross-Reference partial skip 検出) のすべてを満たした場合のみ。Step 1 自身も発火時 (`doc_heavy_post_condition: warning` フラグ set) は post-condition の評価対象である。

##### Step 2: META 5 カテゴリ実行確認 (件数非依存、silent non-compliance 防止)

**適用条件**: `finding_count` の値に関係なく **常に実施** する (`finding_count == 0` でも `finding_count >= 1` でも同じ)。

**照合方式の厳格性宣言** (silent fall-through 防止 — variant ごとに異なる照合方式を明示):
- **variant (a) / (a + inconclusive)**: `Categories: [...]` ブロック内のカテゴリ名を **literal substring match** で検査する。「`Implementation Coverage`」「`Enumeration Completeness`」「`UX Flow Accuracy`」「`Order-Emphasis Consistency`」「`Screenshot Presence`」の **5 つすべてが literal で含まれていること**を要求する。`Order / Emphasis Consistency` (空白付きスラッシュ) や `Order/Emphasis Consistency` (空白なしスラッシュ) のような表記揺れは literal substring match で**マッチしないため Step 2 が `passed` にならず**、`doc_heavy_post_condition: warning` 強制昇格の経路に流れる。
- **variant (b)**: 「`META: All 5 verification categories executed.`」「`Findings below.`」の 2 トークンを literal substring match で検査する (Categories list は variant (b) では出現しない)。
- **variant (c)**: 「`META: Cross-Reference partially skipped`」を literal substring match で検査する。
- **variant (b + inconclusive)**: variant (b) のトークン + 「`but {N} categories were inconclusive`」「`Inconclusive: [...]`」を literal substring match で検査する (`{N}` 部分は数字 1 文字以上を許容)。

**重要**: literal substring match は「カテゴリ名の空白/記号の差異を厳格に検出する」設計選択であり、reviewer が `internal-consistency.md` / `tech-writer.md` の canonical form (`Order-Emphasis Consistency`) から逸脱した瞬間に発火する。これは「文書-実装整合性 mode の自己整合性」を Phase 5.1.3 自身が監視するための仕組みである。

tech-writer の出力に以下のいずれかの META 行が含まれているかを検証する。**正規表現は必ず multiline mode (`(?m)`) で実行**: `(?m)(?:^|<br\s*/?>|[\s|>(])\s*META:` を行頭 anchor として検索する。`(?m)` を明示する理由は、tech-writer が META 行をテーブルセル内ではなくテーブル直後の段落 `- META: ...` 形式で書いた場合、行頭 `^` が multiline mode 無効ではファイル先頭のみを指して検出漏れになるため。Step 4 の正規表現も同じ理由で `(?m)` を明示している (drift 防止):
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

**tech-writer prompt への反映**: Phase 2.2.1 step 3 の reviewer prompt 注入時に、tech-writer に対して「finding 件数に関係なく META 行を出力せよ」を strict 要件として明示する。具体的には:
- finding_count == 0 → `META: All 5 verification categories executed, 0 inconsistencies found. Categories: [...]`
- finding_count >= 1 → `META: All 5 verification categories executed. Findings below.`
- 部分スキップ → `META: Cross-Reference partially skipped` (+ 詳細ブロック)

##### Step 3: Evidence field 必須化 (厳格検査 — Markdown テーブル対応)

- tech-writer の各 finding (CRITICAL/HIGH/MEDIUM/LOW すべて) について、**`内容` カラム本文中**に Evidence 記述が含まれているかを正規表現で検査する。
- **重要 — Markdown テーブル構造への配慮**: Markdown テーブルのセル本文内では物理的な改行は許容されず、各 finding 行は 1 物理行として表現される (セル内改行は `<br>` または同一行内の区切り文字で表現)。そのため、Evidence 検出の正規表現は**行頭 anchor (`^`) に依存してはならない**。代わりに「行頭または直前が空白/区切り文字/`<br>`/`|`/`>`」を許容する anchor を使用する:
  - 正規表現 (multiline mode、行頭または直前が区切り文字、すべて non-capture group)。**`(?m)` flag は literal で必須** — Step 2 / Step 4 / Step 4.5 と syntax を統一し、デコードしない経路でも `^` anchor が各行先頭にマッチするようにする:
    ```
    (?m)(?:(?:^|<br\s*/?>|[\s|>(])\s*)-?\s*Evidence:\s*tool=<?(?:Grep|Read|Glob|WebFetch)>?
    ```
  - 補助: `<br>` が使われない場合でも、セル内の `- Evidence: tool=Grep, ...` 形式はテキスト先頭 (`^`) または空白/`|`/`(` 直後に出現するためマッチする
  - **non-capture group の理由**: 本検証ロジックは「Evidence 行が存在するか」のみを判定し、ツール名 (`Grep` / `Read` / `Glob` / `WebFetch`) の値を抽出して使う必要がない。[`internal-consistency.md`](./references/internal-consistency.md#2-enumeration-completeness) の "Enumeration Completeness" → "Grep パターン例" セクション直下の注釈「すべて non-capture group `(?:...)` を使用し、キャプチャ番号のずれを防ぐ」と一貫させるため、すべて `(?:...)` で統一する (行番号参照は drift しやすいため section anchor で参照する)。
- **山括弧メタ記法の許容**: `tool=<?(?:Grep|Read|Glob|WebFetch)>?` により、reviewer が tech-writer.md の example を literal に解釈して `tool=<Grep>` と書いた場合でもマッチする。これにより example ドキュメントのメタ記法との乖離による false positive を防ぐ。
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
  - Phase 5.4 (Integrated Report) の Doc-Heavy PR Mode 検証状態セクションに表示
  - Phase 5.3 の overall assessment 判定時、ユーザーに明示的な acknowledgement を `AskUserQuestion` で求める
  - acknowledgement なしでマージ判定を下さない (`修正必要` 扱い)

##### Step 4.5: Inconclusive variant 検出 (`internal-consistency.md` 連携)

[`internal-consistency.md`](./references/internal-consistency.md#inconclusive-verification-handling) は、Verification Protocol の各 step で `target_not_found` / `extraction_failed` / `tool_failure` のいずれかが発生した場合、reviewer が META 行を `(a + inconclusive)` / `(b + inconclusive)` 形式で出力することを義務付けている。本 Step は、これら inconclusive variant の検出と acknowledgement プロセスを発火させる責務を持つ:

- tech-writer の出力に以下の正規表現 (multiline mode) のいずれかがマッチする場合、`inconclusive_count` を抽出する:
  - `(?m)(?:^|<br\s*/?>|[\s|>(])\s*META:\s*All 5 verification categories executed,\s*0 inconsistencies found,\s*but\s*(\d+)\s*categor(?:y|ies)\s*were inconclusive` ((a + inconclusive) variant、`{N}` を group 1 で capture)
  - `(?m)(?:^|<br\s*/?>|[\s|>(])\s*META:\s*All 5 verification categories executed,\s*but\s*(\d+)\s*categor(?:y|ies)\s*were inconclusive` ((b + inconclusive) variant、同上)
- マッチした場合の処理:
  1. レビュー結果に `inconclusive_count: {N}` と inconclusive カテゴリ一覧 (`Inconclusive: [...]` の `[ ]` 内をパースして配列化) を `inconclusive_categories` flag に set
  2. **inconclusive_count >= 1 の場合**、Phase 5.3 の overall assessment 判定時に Step 4 (Cross-Reference partial skip) と**同じ acknowledgement プロセス**を発火する: `AskUserQuestion` で「{N} 件の verification category が inconclusive ({carriers}) ですが、続行しますか?」を確認し、ユーザーが明示的に承認しない限り `修正必要` 扱いとする
  3. acknowledgement 取得後は `inconclusive_acknowledged: true` を retained flag に set し、Phase 5.4 Integrated Report の Doc-Heavy PR Mode 検証状態セクションに inconclusive 件数とカテゴリを表示する
- マッチしない場合 (= inconclusive 報告なし) は Step 4.5 を no-op で完了する

> **Step 4 との関係**: Step 4 (Cross-Reference partial skip) は外部リポジトリへのアクセス不能による部分スキップを扱い、Step 4.5 (Inconclusive variant) はリポジトリ内の verification ツール失敗 (`target_not_found` / `extraction_failed` / `tool_failure`) を扱う。両者は失敗の発生場所が異なる (外部 vs 内部) が、acknowledgement プロセスは同型 (Phase 5.3 で AskUserQuestion を発火し、未取得なら `修正必要` 強制)。同一 review 内で両方が同時に発火することもある (両方とも acknowledgement 必要)。

**Implementation note**: 本 Post-Condition Check は Phase 5.2 (Cross-Validation) の **前**に実行する。これにより evidence 欠落が cross-validation の対象になる前に検出され、tech-writer の再実行判断が早期に下せる。

**Retained flags** (Phase 5.4 template 表示用):
- `numstat_availability`: `"OK"` (success path) / `"unavailable"` (failure path) — Phase 1.2.6 でいずれの path でも explicit set される
- `numstat_fallback_reason`: success path では `""` (空文字列)、failure path では numstat 失敗時のエラー 1 行要約 — Phase 1.2.6 でいずれの path でも explicit set される
- `doc_heavy_pr_value`: `{doc_heavy_pr}` の boolean 値 (Phase 1.2.7 で set)
- `doc_heavy_pr_decision_summary`: Doc-Heavy 判定根拠の 1 行要約 (例: `"doc_lines_ratio=0.72 >= 0.6"` / `"rite plugin self-only, excluded"`)
- `doc_heavy_post_condition`: `passed` / `warning` / `error`
- `doc_heavy_finding_count`: tech-writer の finding count
- `evidence_missing_count`: evidence 欠落 finding の数
- `evidence_missing_list`: 欠落 finding の file:line 一覧
- `cross_reference_partial_skip`: boolean (内部判定用)
- `cross_reference_skip_status`: `"なし"` / `"あり"` (Phase 5.4 表示用 — `cross_reference_partial_skip` の boolean を日本語ラベルに変換した文字列。template 列対応統一のため `{cross_reference_skip_status}` placeholder で参照される)
- `cross_reference_skip_details`: META ブロック本文 (外部参照情報)
- `acknowledgement_status`: `"不要"` / `"取得済み"` / `"未取得"` (Phase 5.4 表示用 — `cross_reference_partial_skip == false` のとき `"不要"`、`true` のときはユーザー応答に基づき `"取得済み"` または `"未取得"`。Phase 5.1.3 で必ず explicit set される)
- `inconclusive_count`: int (Step 4.5 で `(a + inconclusive)` / `(b + inconclusive)` variant から抽出した inconclusive カテゴリ数。デフォルト `0`)
- `inconclusive_categories`: list[str] (inconclusive となった category 名一覧。例: `["Implementation Coverage", "Screenshot Presence"]`)
- `inconclusive_acknowledged`: boolean (Phase 5.3 の `AskUserQuestion` でユーザーが明示的に承認したか。`inconclusive_count == 0` の場合は `null` または未設定)
- `verification_post_condition`: `"passed"` / `"warning"` / `"error"` (Phase 5.1.1.1 で set される。`review_mode == "full"` のときは `"passed"` とみなす。Phase 5.4 template の Doc-Heavy PR Mode 検証状態セクションと同型に表示用)
- `verification_post_condition_retry_count`: dict `{reviewer_type: int}` (Phase 5.1.1.1 の per-reviewer retry counter。初期値は空 dict `{}`、各 reviewer に対して retry 1 回まで許可)

**Phase 5.4 表示責務の分離**: `doc_heavy_pr == false` (ratio 未満 / rite plugin self-only 除外 / 空 PR のいずれか) の場合、Phase 5.1.3 の post-condition check 自体はスキップされるが、Phase 5.4 Integrated Report の Doc-Heavy PR Mode 検証状態セクションでは `numstat_availability` と `doc_heavy_pr_value` を上記 retained flags から参照して表示する。これにより numstat 失敗の可視性は Phase 5.1.3 スキップとは独立に保たれる。

> **Note**: Phase 1.2.7 の Doc-Heavy 判定は Phase 1.1 の `files` 配列のみで完結し `git diff --numstat` に依存しない。したがって numstat 失敗は `doc_heavy_pr` の値には影響せず、`numstat_availability = "unavailable"` は**独立した情報提示**として Phase 5.4 に表示される (Doc-Heavy 判定の skip 原因とは無関係)。

### 5.2 Cross-Validation

**Same file/line check**: Group by `file:line`. 2+ reviewers → mark "High Confidence" + boost severity (LOW→MEDIUM→HIGH→CRITICAL).

**Contradiction detection**: Opposite assessments or severity gap ≥ 2 levels (per [Trigger Conditions in cross-validation.md](../../skills/reviewers/references/cross-validation.md#trigger-conditions)) → debate phase (5.2.1) if enabled, otherwise prompt user via `AskUserQuestion`.

**Steps:**

1. If there are multiple findings for the same `file:line`, compare the assessment content
2. If matching the contradiction patterns above, flag as a contradiction
3. Collect all detected contradictions for Phase 5.2.1 (debate) or direct user resolution

**When contradictions are detected:**

Check `review.debate.enabled` in `rite-config.yml` (see [Configuration in cross-validation.md](../../skills/reviewers/references/cross-validation.md#configuration) for defaults):

| `review.debate.enabled` | Action |
|--------------------------|--------|
| **`true`** | Proceed to Phase 5.2.1 (Debate Phase) for automatic resolution attempt |
| **`false`** | Prompt user directly with `AskUserQuestion` (legacy behavior, see below) |

**Direct user resolution (when debate is disabled):**

Prompt the user with AskUserQuestion for confirmation (fallback: see Phase 1.4 note):

```
⚠️ 矛盾する指摘を検出:
ファイル: {file}:{line}

     {Reviewer A} の評価: {assessment_A}
       理由: {reason_A}

     {Reviewer B} の評価: {assessment_B}
       理由: {reason_B}

どちらの評価を採用しますか？
```

### 5.2.1 Debate Phase (Evaluator-Optimizer Pattern)

> **Reference**: See [Debate Protocol in cross-validation.md](../../skills/reviewers/references/cross-validation.md#debate-protocol-evaluator-optimizer-pattern) for the full protocol specification.

**Execution condition**: Execute only when:
1. Contradictions were detected in Phase 5.2
2. `review.debate.enabled: true` in `rite-config.yml`

**Skip condition**: When no contradictions are detected, skip this phase entirely and proceed to Deduplication.

**Configuration loading:**

Read `review.debate` from `rite-config.yml` (defaults defined in [cross-validation.md Configuration](../../skills/reviewers/references/cross-validation.md#configuration)):
- `enabled`: Enable/disable debate phase
- `max_rounds`: Maximum debate rounds per contradiction

**Execution flow:**

For each detected contradiction:

**Pre-debate guard**: Check if either reviewer's finding is CRITICAL severity. If so, skip the debate for this contradiction and escalate immediately to the user per [Escalation Conditions](../../skills/reviewers/references/cross-validation.md#escalation-conditions). Record as `debate_escalated`.

**Step 1**: Generate a debate prompt using the [Debate Template](../../skills/reviewers/references/cross-validation.md#debate-template). Include:
- The contradicting findings from both reviewers
- The specific `file:line` and code context
- Each reviewer's original evidence and reasoning

**Step 2**: Execute the debate internally within the main context (not via the Task tool). Claude simulates both reviewer perspectives, generating arguments for each side following the structured template (Claim → Evidence → Concession → Revised position).

**Step 3**: Evaluate resolution per [Resolution Criteria](../../skills/reviewers/references/cross-validation.md#resolution-criteria):

| Outcome | Detection | Action |
|---------|-----------|--------|
| **Agreement** | Both revised positions recommend the same action with severity within 0 levels | Auto-resolve: adopt the agreed finding, record as `debate_resolved` |
| **Partial agreement** | Both revised positions recommend the same action with severity within 1 level | Auto-resolve: adopt the higher severity, record as `debate_resolved` |
| **No agreement** | Revised positions still contradict after `max_rounds` | Escalate per [Escalation Conditions](../../skills/reviewers/references/cross-validation.md#escalation-conditions), record as `debate_escalated` |

**Step 4**: Record debate metrics (see [Debate Metrics](../../skills/reviewers/references/cross-validation.md#debate-metrics)):
- Increment `debate_triggered` for each contradiction processed (including those escalated by the pre-debate guard in Step 0)
- Pre-debate guard escalations: increment both `debate_triggered` and `debate_escalated`
- Debate outcomes: increment `debate_resolved` (agreement/partial) or `debate_escalated` (no agreement)
- Calculate `debate_resolution_rate` = `debate_resolved / debate_triggered` after all contradictions are processed

**Auto-resolved findings**: Replace the original contradicting findings with the agreed-upon finding. Mark in the integrated report (Phase 5.4) as "討論で合意" (agreed through debate).

**Escalated findings**: Present to user via `AskUserQuestion` using the [Escalation format](../../skills/reviewers/references/cross-validation.md#escalation-conditions). The escalation format includes the debate history (concessions and revised positions) to give the user richer context for their decision. Map the escalation format's `オプション:` choices directly to `AskUserQuestion` options.

**Output summary** (displayed inline within Phase 5.2.1 after all contradictions are processed, before proceeding to Deduplication):

```
討論フェーズ完了:
- 矛盾検出: {debate_triggered} 件
- 自動解決: {debate_resolved} 件（討論で合意）
- エスカレーション: {debate_escalated} 件（ユーザー判断が必要）
- 解決率: {debate_resolution_rate}%
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

**Execution condition**: Execute only when `{issue_spec}` was obtained in Phase 1.3.1. Skip if no specification information is available.

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

> See [references/assessment-rules.md](./references/assessment-rules.md) for the full assessment rules (5.3.1-5.3.7): assessment logic, output format, return values, and prohibition of independent judgment. All findings are blocking regardless of severity or loop count.

### 5.3.8 Fix-Introduced Finding Attribution (#453 Component F)

When this is a **re-review after a fix** (verification mode or `loop_count >= 1`), attribute each finding to one of three categories to enable convergence monitoring.

**Step 1**: Determine if attribution is applicable:

```bash
loop_count=$(jq -r '.loop_count // 0' .rite-flow-state 2>/dev/null) || loop_count=0
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

> **Note**: Attribution is best-effort. When it's ambiguous whether code existed before the fix, default to `[original]`. The primary purpose is diagnostic, not blocking.

**Step 4**: Write attribution summary to fix-cycle-state:

Claude substitutes `{total_findings}`, `{fix_introduced_count}`, `{critical_count}`, `{high_count}`, `{medium_count}`, `{low_count}` with the actual integer values from Step 3 classification results before generating the bash block.

```bash
pr_number="{pr_number}"
state_file=".rite/fix-cycle-state/${pr_number}.json"
total_findings="{total_findings}"
fix_introduced_count="{fix_introduced_count}"
critical_count="{critical_count}"
high_count="{high_count}"
medium_count="{medium_count}"
low_count="{low_count}"

if [ -f "$state_file" ]; then
  jq --argjson total "$total_findings" \
     --argjson fix_introduced "$fix_introduced_count" \
     --argjson severity "{\"CRITICAL\":$critical_count,\"HIGH\":$high_count,\"MEDIUM\":$medium_count,\"LOW\":$low_count}" \
     '.cycles[-1].findings_total = $total | .cycles[-1].findings_new_from_fix = $fix_introduced | .cycles[-1].findings_by_severity = $severity' \
     "$state_file" > "${state_file}.tmp" && mv "${state_file}.tmp" "$state_file"
  printf '[CONTEXT] ATTRIBUTION_WRITTEN total=%d fix_introduced=%d\n' "$total_findings" "$fix_introduced_count"
fi
```

> **Placeholder resolution**: `{total_findings}` is the count of all findings from the current review. `{fix_introduced_count}` is the count of findings classified as `[fix-introduced]` in Step 3. `{critical_count}` / `{high_count}` / `{medium_count}` / `{low_count}` are the severity breakdown from the current review results. All values are integers.
>
> **Timing note**: Phase 5.3.8 writes `findings_total` to the **previous** cycle entry (`.cycles[-1]`), which was created by the previous fix's Phase 3.3.1. The convergence monitor (start.md Phase 5.4.1.0) reads `.cycles[-2:]` completed data (entries where `findings_total` has been populated by a completed review). The **latest** cycle entry created by the most recent fix may not yet have `findings_total` if the current review hasn't completed Phase 5.3.8 yet — the convergence monitor accounts for this by reading only entries with non-null `findings_total`.

### 5.4 Integrated Report Generation

**Emoji usage**: Follow the emoji policy in `skills/reviewers/SKILL.md`; use emojis only in the integrated report header (`📜 rite レビュー結果`) and important warnings. Do not use emojis in each reviewer's findings.

**Full review mode (`review_mode == "full"`) template:**

```markdown
## 📜 rite レビュー結果

### 総合評価
- **推奨**: {マージ可 / マージ不可（指摘あり） / 修正必要}
- **レビュアー数**: {count}人
- **変更規模**: {additions}+ / {deletions}- ({changedFiles} files)

### レビュアー合意状況

| レビュアー | 評価 | CRITICAL | HIGH | MEDIUM | LOW |
|-----------|------|----------|------|--------|-----|
| {type} | {assessment} | {count} | {count} | {count} | {count} |

### 仕様との整合性（該当がある場合のみ）
<!-- Phase 1.3.1 で Issue 仕様が取得できた場合のみ表示 -->

| 仕様項目 | 状態 | 備考 |
|---------|------|------|
| {spec_item} | 準拠 / 不整合 / 未実装 | {notes} |

### 討論結果（該当がある場合のみ）
<!-- Phase 5.2.1 で討論が実行された場合のみ表示。矛盾が0件の場合はこのセクション自体を省略 -->

| ファイル:行 | レビュアー | 結果 | 合意内容 |
|------------|-----------|------|---------|
| {file:line} | {reviewer_a} vs {reviewer_b} | 合意 / エスカレーション | {resolution_summary} |

**討論メトリクス**: 矛盾 {debate_triggered} 件 → 自動解決 {debate_resolved} 件 / エスカレーション {debate_escalated} 件（解決率: {debate_resolution_rate}%）

### 高信頼度の指摘（複数レビュアー合意）
<!-- 2人以上のレビュアーが同じ問題を指摘 -->

| 重要度 | ファイル:行 | 内容 | 指摘者 |
|--------|------------|------|--------|
| {severity} | {file:line} | {description} | {reviewers} |

### 外部仕様の検証結果（該当がある場合のみ）
<!-- Fact-Checking Phase で外部仕様の検証が実行された場合のみ表示。外部仕様の主張が0件の場合はこのセクション自体を省略 -->

| 指摘 | 主張 | 検証結果 | ソース |
|------|------|---------|--------|
| {file:line} ({reviewer}) | {claim_summary} | ✅ 検証済み / ⚠️ 未検証 | [source](URL) |

**ファクトチェック**: {verified}✅ {contradicted}❌ {unverified}⚠️

### 矛盾により除外された指摘（該当がある場合のみ）
<!-- CONTRADICTED 指摘がある場合のみ表示。0件の場合はこのセクション自体を省略 -->

> このセクションの指摘は、公式ドキュメントと矛盾しているため指摘事項から除外されました。

| 重要度 | ファイル:行 | 当初の主張 | 公式ドキュメントの記述 | ソース |
|--------|------------|-----------|----------------------|--------|
| {severity} | {file:line} | {original_claim} | {correct_info} | [source](URL) |

### Doc-Heavy PR Mode 検証状態（該当がある場合のみ）
<!-- 表示条件 (決定論的、OR で評価):
     本セクションは以下の (a) または (b) のいずれかが成立する場合に表示する。両方とも成立しない場合は省略する:
       (a) doc_heavy_pr == true で Phase 5.1.3 post-condition check が実行された場合
       (b) numstat_availability == "unavailable" の場合 (numstat 失敗の可視性のため、doc_heavy_pr の値に関係なく表示)

     非表示条件: 上記 (a) も (b) も成立しない場合 (= doc_heavy_pr == false かつ numstat_availability == "OK")
     → tech-writer が reviewer に存在するかどうかに関係なく省略する。tech-writer の存否は本セクションの
        表示判定に影響しない (本セクションは Doc-Heavy 機構と numstat 可用性の状態を可視化するためのものであり、
        tech-writer 単独のレビュー結果を表示するセクションではないため)。

     詳細: Phase 5.1.3 末尾の「Phase 5.4 表示責務の分離」段落を参照
     numstat 失敗時は numstat 可用性行に unavailable が表示される (Doc-Heavy 判定自体は Phase 1.1 files 配列で完結するため skip されず通常通り実行される)

     placeholder 展開ルール (undefined 参照防止):
     - {numstat_availability}: "OK" or "unavailable" (Phase 1.2.6 で必ず explicit set される)
     - {numstat_fallback_reason}: success path では空文字列 ""、failure path では 1 行要約 (Phase 1.2.6 で必ず explicit set される)
     - {doc_heavy_pr_value}: true / false (Phase 1.2.7 Determination ブロックで explicit set される)
     - {doc_heavy_pr_decision_summary}: Phase 1.2.7 の生成ルール (Determination ブロック直下のコメント) に従って生成された文字列
     - {doc_heavy_post_condition}: passed / warning / error (Phase 5.1.3 で set される)
     - {cross_reference_skip_status}: "なし" or "あり" (Phase 5.1.3 / Cross-Reference 検証で set される)
     - {acknowledgement_status}: "不要" / "取得済み" / "未取得" (Phase 5.1.3 で partial_skip 発生時のみ set、それ以外は "不要") -->

| 項目 | 状態 | 詳細 |
|------|------|------|
| numstat 可用性 | {numstat_availability} | {numstat_fallback_reason} |
| Doc-Heavy 判定 | {doc_heavy_pr_value} | {doc_heavy_pr_decision_summary} |
| Post-condition | {doc_heavy_post_condition} | passed / **warning** / **error** のいずれか |
| tech-writer finding 件数 | {doc_heavy_finding_count} | {0 件の場合は META negative confirmation の有無} |
| Evidence 欠落 finding | {evidence_missing_count} 件 | {evidence_missing_list を箇条書き} |
| Cross-Reference partial skip | {cross_reference_skip_status} | なし / **あり** ({cross_reference_skip_details — external repo 情報}) |
| ユーザー acknowledgement | {acknowledgement_status} | 不要 / **取得済み** / **未取得** (partial_skip あり時のみ記載) |

**影響**: `post-condition == warning` または `error`、もしくは `evidence_missing_count >= 1`、または `cross_reference_partial_skip == true` かつ acknowledgement 未取得の場合、総合評価は自動的に **`修正必要`** に昇格する。

### Verification Mode Post-Condition 検証状態（該当がある場合のみ）
<!-- 表示条件: review_mode == "verification" のときのみ表示。full mode では Phase 5.1.1.1 がスキップされるため省略する。

     placeholder 展開ルール (undefined 参照防止):
     - {verification_post_condition}: "passed" / "warning" / "error" (Phase 5.1.1.1 で set される。review_mode == "full" では "passed" 固定)
     - {verification_post_condition_retry_summary}: per-reviewer retry counter の 1 行要約 (例: "tech-writer: 1 retry, others: 0")

     両 template (full mode / verification mode) で同一内容の drift 防止コメントは Phase 5.1.3 後の "Doc-Heavy PR Mode セクションの drift 防止" note を参照 -->

| 項目 | 状態 | 詳細 |
|------|------|------|
| Verification post-condition | {verification_post_condition} | passed / **warning** / **error** (Phase 5.1.1.1 の `### 修正検証結果` テーブル出力チェック結果) |
| Retry 回数サマリー | {verification_post_condition_retry_summary} | per-reviewer retry counter の集計 |

**影響**: `verification_post_condition == warning` または `error` の場合、該当 reviewer の指摘は全件 blocking 扱いとなり、総合評価は **`修正必要`** に昇格する。

> **Doc-Heavy PR Mode セクションの drift 防止**: 上記 markdown ブロックは verification mode template (本ファイル内の後続セクション) でも完全に同一内容で重複定義されている。**両 template (full mode / verification mode) のいずれかを更新する際は、必ずもう一方も同一内容で同期更新すること**。drift が発生すると Phase 5.4 表示が template 切り替え時に異なる挙動を示し silent failure の原因になる。将来は共通 partial への切り出しが望ましい (現状は実装複雑性を避けるため重複定義のまま維持)。詳細・自動 lint 化計画は [`./references/internal-consistency.md`](./references/internal-consistency.md) の「系統 3」を参照。

### 全指摘事項

#### {Reviewer Type}
- **評価**: {可 / 条件付き / 要修正}
- **所見**: {summary}

| 重要度 | ファイル:行 | 内容 | 推奨対応 |
|--------|------------|------|----------|
| {severity} | {file:line} | {description} | {recommendation} |

<!-- 各レビュアーの結果を繰り返し -->

### 推奨事項（該当がある場合のみ）
<!-- Phase 5.1 で収集した recommendation_issue_candidates がある場合のみ表示。0件の場合はこのセクション自体を省略 -->

| レビュアー | 内容 | 別 Issue 候補 |
|-----------|------|:------------:|
| {reviewer_type} | {recommendation_content} | {✅ if 別 Issue keyword detected, — otherwise} |

### 調査推奨（該当がある場合のみ）
<!-- reviewer が PR 対象ファイルで気になる既存パターンを検出した場合のみ表示。blocking ではない。0件の場合はこのセクション自体を省略 -->

> 以下のファイルで、本 PR の diff とは無関係な気になる既存パターンを検出しました。必要に応じて `/rite:investigate {file}` で別途調査してください（blocking ではありません）。

| ファイル | 気になる点 | レビュアー |
|---------|-----------|-----------|
| {file} | {concern_description} | {reviewer_type} |

---

### 次のステップ
{recommendation に応じた具体的アクション}

📎 reviewed_commit: {current_commit_sha}
```

**Verification mode (`review_mode == "verification"`) template:**

```markdown
## 📜 rite レビュー結果

### 総合評価
- **推奨**: {マージ可 / マージ不可（指摘あり） / 修正必要}
- **レビューモード**: 検証 + フル
- **レビュアー数**: {count}人
- **変更規模**: {additions}+ / {deletions}- ({changedFiles} files)

### 修正検証サマリー

| 項目 | 件数 |
|------|------|
| 前回の指摘総数 | {total_previous} |
| FIXED（修正済み） | {fixed_count} |
| NOT_FIXED（未修正） | {not_fixed_count} |
| PARTIAL（部分修正） | {partial_count} |
| リグレッション（新規） | {regression_count} |

### レビュアー合意状況

| レビュアー | 評価 | NOT_FIXED | PARTIAL | REGRESSION |
|-----------|------|-----------|---------|------------|
| {type} | {assessment} | {count} | {count} | {count} |

### 未修正の指摘（NOT_FIXED / PARTIAL）

| # | 重要度 | ファイル:行 | 内容 | 判定 | 備考 |
|---|--------|------------|------|------|------|
| {n} | {severity} | {file:line} | {description} | {NOT_FIXED/PARTIAL} | {notes} |

### リグレッション（修正差分で検出）

| 重要度 | ファイル:行 | 内容 | 推奨対応 |
|--------|------------|------|----------|
| {severity} | {file:line} | {description} | {recommendation} |

### 討論結果（該当がある場合のみ）
<!-- Phase 5.2.1 で討論が実行された場合のみ表示。矛盾が0件の場合はこのセクション自体を省略 -->

| ファイル:行 | レビュアー | 結果 | 合意内容 |
|------------|-----------|------|---------|
| {file:line} | {reviewer_a} vs {reviewer_b} | 合意 / エスカレーション | {resolution_summary} |

**討論メトリクス**: 矛盾 {debate_triggered} 件 → 自動解決 {debate_resolved} 件 / エスカレーション {debate_escalated} 件（解決率: {debate_resolution_rate}%）

### 仕様との整合性（該当がある場合のみ）
<!-- Phase 1.3.1 で Issue 仕様が取得できた場合のみ表示 -->

| 仕様項目 | 状態 | 備考 |
|---------|------|------|
| {spec_item} | 準拠 / 不整合 / 未実装 | {notes} |

### 高信頼度の指摘（複数レビュアー合意）
<!-- 2人以上のレビュアーが同じ問題を指摘 -->

| 重要度 | ファイル:行 | 内容 | 指摘者 |
|--------|------------|------|--------|
| {severity} | {file:line} | {description} | {reviewers} |

### 外部仕様の検証結果（該当がある場合のみ）
<!-- Fact-Checking Phase で外部仕様の検証が実行された場合のみ表示。外部仕様の主張が0件の場合はこのセクション自体を省略 -->

| 指摘 | 主張 | 検証結果 | ソース |
|------|------|---------|--------|
| {file:line} ({reviewer}) | {claim_summary} | ✅ 検証済み / ⚠️ 未検証 | [source](URL) |

**ファクトチェック**: {verified}✅ {contradicted}❌ {unverified}⚠️

### 矛盾により除外された指摘（該当がある場合のみ）
<!-- CONTRADICTED 指摘がある場合のみ表示。0件の場合はこのセクション自体を省略 -->

> このセクションの指摘は、公式ドキュメントと矛盾しているため指摘事項から除外されました。

| 重要度 | ファイル:行 | 当初の主張 | 公式ドキュメントの記述 | ソース |
|--------|------------|-----------|----------------------|--------|
| {severity} | {file:line} | {original_claim} | {correct_info} | [source](URL) |

### Doc-Heavy PR Mode 検証状態（該当がある場合のみ）
<!-- 表示条件 (決定論的、OR で評価) — full mode template と同一内容:
     本セクションは以下の (a) または (b) のいずれかが成立する場合に表示する。両方とも成立しない場合は省略する:
       (a) doc_heavy_pr == true で Phase 5.1.3 post-condition check が実行された場合
       (b) numstat_availability == "unavailable" の場合 (numstat 失敗の可視性のため、doc_heavy_pr の値に関係なく表示)

     非表示条件: 上記 (a) も (b) も成立しない場合 (= doc_heavy_pr == false かつ numstat_availability == "OK")
     → tech-writer が reviewer に存在するかどうかに関係なく省略する。tech-writer の存否は本セクションの
        表示判定に影響しない (本セクションは Doc-Heavy 機構と numstat 可用性の状態を可視化するためのものであり、
        tech-writer 単独のレビュー結果を表示するセクションではないため)。

     詳細: Phase 5.1.3 末尾の「Phase 5.4 表示責務の分離」段落を参照
     numstat 失敗時は numstat 可用性行に unavailable が表示される (Doc-Heavy 判定自体は Phase 1.1 files 配列で完結するため skip されず通常通り実行される)
     verification mode template にも本セクションを含める (Phase 5.1.3 は review_mode に依存しないため、
     verification mode + Doc-Heavy PR の組み合わせでも post-condition check は実行される)

     placeholder 展開ルール (undefined 参照防止、full mode template と同一):
     - {numstat_availability}: "OK" or "unavailable" (Phase 1.2.6 で必ず explicit set される)
     - {numstat_fallback_reason}: success path では空文字列 ""、failure path では 1 行要約 (Phase 1.2.6 で必ず explicit set される)
     - {doc_heavy_pr_value}: true / false (Phase 1.2.7 Determination ブロックで explicit set される)
     - {doc_heavy_pr_decision_summary}: Phase 1.2.7 の生成ルール (Determination ブロック直下のコメント) に従って生成された文字列
     - {doc_heavy_post_condition}: passed / warning / error (Phase 5.1.3 で set される)
     - {cross_reference_skip_status}: "なし" or "あり" (Phase 5.1.3 / Cross-Reference 検証で set される)
     - {acknowledgement_status}: "不要" / "取得済み" / "未取得" (Phase 5.1.3 で partial_skip 発生時のみ set、それ以外は "不要") -->

| 項目 | 状態 | 詳細 |
|------|------|------|
| numstat 可用性 | {numstat_availability} | {numstat_fallback_reason} |
| Doc-Heavy 判定 | {doc_heavy_pr_value} | {doc_heavy_pr_decision_summary} |
| Post-condition | {doc_heavy_post_condition} | passed / **warning** / **error** のいずれか |
| tech-writer finding 件数 | {doc_heavy_finding_count} | {0 件の場合は META negative confirmation の有無} |
| Evidence 欠落 finding | {evidence_missing_count} 件 | {evidence_missing_list を箇条書き} |
| Cross-Reference partial skip | {cross_reference_skip_status} | なし / **あり** ({cross_reference_skip_details — external repo 情報}) |
| ユーザー acknowledgement | {acknowledgement_status} | 不要 / **取得済み** / **未取得** (partial_skip あり時のみ記載) |

**影響**: `post-condition == warning` または `error`、もしくは `evidence_missing_count >= 1`、または `cross_reference_partial_skip == true` かつ acknowledgement 未取得の場合、総合評価は自動的に **`修正必要`** に昇格する。

### Verification Mode Post-Condition 検証状態（該当がある場合のみ）
<!-- 表示条件: review_mode == "verification" のときのみ表示。本 template は verification mode template なので常に表示対象。
     full mode template 側にも同一セクションが重複定義されている (drift 防止のため) -->

| 項目 | 状態 | 詳細 |
|------|------|------|
| Verification post-condition | {verification_post_condition} | passed / **warning** / **error** (Phase 5.1.1.1 の `### 修正検証結果` テーブル出力チェック結果) |
| Retry 回数サマリー | {verification_post_condition_retry_summary} | per-reviewer retry counter の集計 |

**影響**: `verification_post_condition == warning` または `error` の場合、該当 reviewer の指摘は全件 blocking 扱いとなり、総合評価は **`修正必要`** に昇格する。

> **Doc-Heavy PR Mode セクションの drift 防止**: 上記 markdown ブロックは full mode template (本ファイル前段) でも完全に同一内容で重複定義されている。**両 template (full mode / verification mode) のいずれかを更新する際は、必ずもう一方も同一内容で同期更新すること**。drift が発生すると Phase 5.4 表示が template 切り替え時に異なる挙動を示し silent failure の原因になる。将来は共通 partial への切り出しが望ましい (現状は実装複雑性を避けるため重複定義のまま維持)。詳細・自動 lint 化計画は [`./references/internal-consistency.md`](./references/internal-consistency.md) の「系統 3」を参照。

### 全指摘事項

#### {Reviewer Type}
- **評価**: {可 / 条件付き / 要修正}
- **所見**: {summary}

| 重要度 | ファイル:行 | 内容 | 推奨対応 |
|--------|------------|------|----------|
| {severity} | {file:line} | {description} | {recommendation} |

<!-- 各レビュアーの結果を繰り返し -->

### 推奨事項（該当がある場合のみ）
<!-- Phase 5.1 で収集した recommendation_issue_candidates がある場合のみ表示。0件の場合はこのセクション自体を省略 -->

| レビュアー | 内容 | 別 Issue 候補 |
|-----------|------|:------------:|
| {reviewer_type} | {recommendation_content} | {✅ if 別 Issue keyword detected, — otherwise} |

### 調査推奨（該当がある場合のみ）
<!-- reviewer が PR 対象ファイルで気になる既存パターンを検出した場合のみ表示。blocking ではない。0件の場合はこのセクション自体を省略 -->

> 以下のファイルで、本 PR の diff とは無関係な気になる既存パターンを検出しました。必要に応じて `/rite:investigate {file}` で別途調査してください（blocking ではありません）。

| ファイル | 気になる点 | レビュアー |
|---------|-----------|-----------|
| {file} | {concern_description} | {reviewer_type} |

### Stability Concerns ({count} 件)
<!-- 未変更コードに対する新規 MEDIUM/LOW 指摘。AI の非決定性による可能性あり。 -->
<!-- stability_concern が 0 件の場合はこのセクション自体を省略 -->

*未変更コードに対する新規指摘。AI の非決定性による可能性があります。対応は任意です。*

| 重要度 | ファイル:行 | 内容 | 備考 |
|--------|------------|------|------|
| {severity} | {file:line} | {description} | 前回未検出；コード未変更 |

---

### 次のステップ
{recommendation に応じた具体的アクション}

📎 reviewed_commit: {current_commit_sha}
```

**Template selection:**

| review_mode | Template Used |
|-------------|-------------------|
| **`full`** | Full review mode template |
| **`verification`** | 統合テンプレート（検証サマリー + フルレビューセクション含む） |

**Note**: `📎 reviewed_commit: {current_commit_sha}` must be output in both templates. This is used for incremental diff retrieval in the verification mode of the next cycle (Phase 1.2.4).

---

## Phase 6: Result Output

### 6.1 Output Review Result (Local Save + Conditional PR Comment)

Output the review results via two independent paths. Use `mktemp` + `--body-file` to safely handle markdown content for the PR comment path.

**Issue #443 changes**: This phase now performs **two independent outputs**:
1. **Local JSON file save** (always, even when `{post_comment_mode}=false`)
2. **PR comment post** (only when `{post_comment_mode}=true` from Phase 1.0)

Phase 6 failure reasons (reason 表の本文は `common-error-handling.md#jq-required-fields-snippet-canonical` の canonical jq snippet を参照):

| reason | Description |
|--------|-------------|
| `tmpfile_write_failure` | Review result heredoc write to tmpfile failed (Phase 6.1.b PR comment post) |
| `gh_comment_post_failure` | `gh pr comment` 投稿が exit != 0 で失敗 (Phase 6.1.b、network / auth / rate-limit / permission) |
| `json_saved_from_p61a_unset` | Phase 6.1.b で `json_saved_from_p61a` が literal substitute されていない (cycle 8 H-5 対応) |
| `iso_timestamp_from_p61a_unset` | Phase 6.1.b で `iso_timestamp_from_p61a` が literal substitute されていない (cycle 10 I-A 対応、sentinel 残留 / 空文字 / placeholder 形式で発火) |
| `raw_json_timestamp_injection_failed` | Phase 6.1.b で Raw JSON セクション内 sentinel の sed 置換または mv が失敗 (cycle 10 I-A 対応) |
| `p61b_pr_number_invalid` | Phase 6.1.b の `pr_number` が literal substitute されていない / 数値以外 (cycle 10 I-B 対応、`p61c_pr_number_invalid` と対称) |
| `p61c_pr_number_invalid` | Phase 6.1.c の `pr_number` が literal substitute されていない / 数値以外 (cycle 10 I-B 対応) |
| `p61c_persistence_unrecoverable` | Phase 6.1.c ケース 2 (`post_comment_mode=false` ∧ `LOCAL_SAVE_FAILED=1`) で silent data loss 防止のため Phase 6 全体を `exit 2` で fail させる (cycle 10 C-1 対応) |
| `p61c_file_timestamp_unset` | Phase 6.1.c で `file_timestamp` placeholder が literal substitute されていない (cycle 8 M-9 対応) |
| `p61c_local_save_failed_invalid` | Phase 6.1.c で `local_save_failed` が不正値 (空文字/0/1 以外、cycle 8 M-9 対応) |
| `mkdir_failure` | `.rite/review-results/` directory creation failed (Phase 6.1.a, **WARNING only, do NOT fail Phase 6**) |
| `date_command_failure` | `TZ='Asia/Tokyo' date` の実行が失敗 (Phase 6.1.a、**WARNING only**、空 timestamp による file 上書きを防止) |
| `mktemp_failure` | JSON tmpfile allocation failed (Phase 6.1.a, **WARNING only**) |
| `write_failure` | JSON content write to tmpfile failed (Phase 6.1.a, **WARNING only**) |
| `json_invalid` | JSON tmpfile written but `jq empty` post-condition check failed (Phase 6.1.a, literal `{review_result_json_heredoc_body}` substitute 漏れの可能性、**WARNING only**) |
| `schema_required_fields_missing` | JSON は parse 可能だが必須フィールド (schema_version / pr_number / findings[] 配列型) が欠落 (Phase 6.1.a、**WARNING only**) |
| `finding_id_format_or_uniqueness_violation` | findings[].id が `^F-[0-9]{2,}$` 書式違反または重複 (Phase 6.1.a、**WARNING only**、verified-review cycle 8 H-7 対応) |
| `mv_failure` | Atomic move of JSON tmpfile to final path failed (Phase 6.1.a, **WARNING only**) |
| `mktemp_failure_mv_err` | Phase 6.1.a の mv stderr 退避用 tempfile の mktemp が失敗 (I-3 対応、**WARNING only**、mv 失敗時の stderr 詳細が失われるため explicit に通知) |
| `timestamp_injection_mv_failure` | Phase 6.1.a の timestamp 注入後 inner mv (`mv "$json_ts_injected" "$json_tmp"`) が失敗 (verified-review cycle 9 C-1 対応、**WARNING only**、sentinel 残留 JSON を final path に書かないため後続処理を skip) |
| `pr_number_placeholder_residue` | Phase 6.1.a 冒頭の `pr_number="{pr_number}"` literal substitute が忘れられ、数値以外 (空文字 / placeholder 残留) のまま bash block に入った (cycle 10 I-B 対応、**WARNING only**、cleanup.md Phase 2.5 の numeric gate と対称化し永久 orphan 化を防ぐ) |
| `collision_resolution_exhausted` | Phase 6.1.a の同一秒衝突回避 `~<4桁hex>` suffix を付与しても再衝突を検出 (cycle 12 M-2 対応、**WARNING only**、同秒 3 回目以上の連続実行 / `$RANDOM` fallback `0` / parallel race の兆候で発火、後続の mv を skip して silent overwrite を防ぐ) |
| `p61c_file_timestamp_unknown_without_failure` | Phase 6.1.c で `file_timestamp='unknown'` だが `local_save_failed != '1'` (整合性違反、cycle 12 I-3 対応、ケース 1 での `.../unknown.json` 誤提示を遮断) |

**Non-blocking contract**: Phase 6.1.a の全 12 種の reason (`pr_number_placeholder_residue` / `date_command_failure` / `mkdir_failure` / `mktemp_failure` / `write_failure` / `timestamp_injection_mv_failure` / `json_invalid` / `schema_required_fields_missing` / `finding_id_format_or_uniqueness_violation` / `mktemp_failure_mv_err` / `mv_failure` / `collision_resolution_exhausted`) are all logged as WARNING and MUST NOT cause Phase 6 to fail. Only `tmpfile_write_failure` (which affects the PR comment post path, not the local file save) causes a hard error. Canonical 定義は [common-error-handling.md#non-blocking-contract-canonical-定義](../../references/common-error-handling.md#non-blocking-contract-canonical-定義) を参照。

**Retained flag mapping**:

- **Phase 6.1.a** は `[CONTEXT] LOCAL_SAVE_FAILED=1` flag を emit する。reason 値は以下 12 種のいずれか (cycle 12 M-2 修正で `collision_resolution_exhausted` 追加、cycle 10 I-B 修正で `pr_number_placeholder_residue` 追加、cycle 9 C-1 修正で `timestamp_injection_mv_failure` 追加、I-3 修正で `mktemp_failure_mv_err` 追加、cycle 8 H-7 修正で `finding_id_format_or_uniqueness_violation` 追加): `pr_number_placeholder_residue` / `date_command_failure` / `mkdir_failure` / `mktemp_failure` / `write_failure` / `timestamp_injection_mv_failure` / `json_invalid` / `schema_required_fields_missing` / `finding_id_format_or_uniqueness_violation` / `mktemp_failure_mv_err` / `mv_failure` / `collision_resolution_exhausted`。この flag は Phase 6.1.c の skip notification で「ローカル保存失敗」メッセージを表示する条件として参照される。Phase 6 全体の exit code には影響しない (非ブロッキング契約)。
- **Phase 6.1.b** は `[CONTEXT] REVIEW_OUTPUT_FAILED=1` flag を emit する。reason 値は `tmpfile_write_failure` / `gh_comment_post_failure` / `json_saved_from_p61a_unset` のいずれか (cycle 8 H-5 修正で `json_saved_from_p61a_unset` 追加)。この flag は PR コメント投稿経路の失敗を示し、hard error として Phase 6 を fail させる (Phase 6.1.a の非ブロッキング契約とは対照的)。
- **Phase 6.1.c** は case 2 (`post_comment_mode=false` ∧ `LOCAL_SAVE_FAILED=1` の組み合わせ) で `[CONTEXT] REVIEW_OUTPUT_FAILED=1; reason=p61c_persistence_unrecoverable` を emit し、Phase 6 全体を `exit 2` で fail させる (cycle 10 C-1 対応、silent data loss 防止)。

**Eval-order enumeration** (for Pattern-5 drift check): Phase 6.1.a emit sequence = (`pr_number_placeholder_residue` / `date_command_failure` / `mkdir_failure` / `mktemp_failure` / `write_failure` / `timestamp_injection_mv_failure` / `json_invalid` / `schema_required_fields_missing` / `finding_id_format_or_uniqueness_violation` / `mktemp_failure_mv_err` / `collision_resolution_exhausted` / `mv_failure`) — 12 件、bash block 内の実 emit 順 (cycle 10 I-D 対応で列挙順序を実装順に揃え、`timestamp_injection_mv_failure` 漏れを修正、cycle 10 I-B 対応で `pr_number_placeholder_residue` を追加、cycle 12 M-2 対応で `collision_resolution_exhausted` を追加); Phase 6.1.b emit = (`p61b_pr_number_invalid` / `tmpfile_write_failure` / `iso_timestamp_from_p61a_unset` / `raw_json_timestamp_injection_failed` / `gh_comment_post_failure` / `json_saved_from_p61a_unset`); Phase 6.1.c emit = (`p61c_pr_number_invalid` / `p61c_file_timestamp_unset` / `p61c_file_timestamp_unknown_without_failure` / `p61c_local_save_failed_invalid` / `p61c_persistence_unrecoverable`).

#### 6.1.a Local JSON File Save (Always Executed — #443) <!-- AC-1 / D-01 / D-02 / D-04 -->

> **Acceptance Criteria anchor**: AC-1 (`pr_review.post_comment` 未設定時にデフォルトで PR コメント投稿せず、`.rite/review-results/{pr}-{ts}.json` のみ作成)。D-01 (ハイブリッド方式: 会話 > ローカルファイル > PR コメント)。D-02 (同一 PR の履歴を timestamp 付きで保持、best-effort、同秒衝突は `~$RANDOM` suffix で回避 — separator `~` は `.` より ASCII 大で sort -r 時に新しい collision-resolved 版が先頭に来る)。D-04 (非ブロッキング契約: ローカル保存失敗は WARNING のみで続行、`common-error-handling.md` の Non-blocking Contract 準拠 — ただし `post_comment=false` ∧ `LOCAL_SAVE_FAILED=1` 組み合わせは Phase 6.1.c でケース 2 の ⚠️ WARNING に昇格する)。

> **Phase 6.1 分岐ロジック**: Phase 6.1 は `{post_comment_mode}` の値に応じて以下のいずれかに分岐する: (a) `true` → 6.1.a (ローカル保存) → 6.1.b (PR コメント投稿)、(b) `false` → 6.1.a (ローカル保存) → 6.1.c (skip notification 出力)。6.1.a は常に実行され、6.1.b と 6.1.c は `{post_comment_mode}` で排他的に分岐する。**6.1.c は `{post_comment_mode}=false` 経路のみで実行される** (`true` 経路では 6.1.b の成功/失敗ログで完結し、skip notification は出力しない — verified-review cycle 8 M-1 対応)。

Save review results as a timestamped JSON file per [review-result-schema.md](../../references/review-result-schema.md). This is executed **regardless** of `{post_comment_mode}` so that `/rite:pr:fix` can read results via the local-file path.

**Claude substitution requirements**:
- `{review_result_json_heredoc_body}`: Claude が review-result-schema.md に従って JSON 本文を生成し、下記 `RITE_JSON_EOF` heredoc に literal substitute する。**⚠️ Heredoc quoting note**: `<<'RITE_JSON_EOF'` は single-quoted delimiter のため shell expansion (変数展開・command substitution) は完全抑制される。`{review_result_json_heredoc_body}` placeholder は **bash 実行時の動的展開ではなく Claude が bash block 生成時に literal 文字列として置換**する必要がある。literal 置換忘れは bash 実行時に literal `{review_result_json_heredoc_body}` がそのまま JSON ファイルに書き込まれ、Phase 6.1.a 内の `jq empty` post-condition check で fail-fast 検出される (defense-in-depth)。
- `{pr_number}`: Phase 1.0 で正規化済み。bash block 冒頭で `pr_number="{pr_number}"` の literal substitution を行い、以後は bash 変数 `${pr_number}` として参照する (Claude placeholder と bash 変数展開の混在を避ける)。
- Required JSON fields: `schema_version: "1.0.0"`, `pr_number`, `timestamp` (`$iso_timestamp` で生成された ISO 8601 JST 値を使用), `commit_sha`, `overall_assessment` (`mergeable` / `fix-needed`), `findings[]`. Each finding の必須フィールドは以下の通り — 完全なスキーマは [review-result-schema.md](../../references/review-result-schema.md#json-schema) を真実の源として参照すること:
  - `id`: **`F-NN` 形式、最小 2 桁ゼロパディング可変長連番** (正規表現 `^F-[0-9]{2,}$`)。99 件以下は `F-01`〜`F-99`、100 件以上は `F-100` 等に成長する。
  - `reviewer`: レビュアーエージェント名 (例: `code-quality-reviewer`, `security-reviewer`, `tech-writer-reviewer`)。実在する agent 名は `plugins/rite/agents/*-reviewer.md` の basename (拡張子を除く) と一致させる。
  - `category`: 指摘カテゴリ (例: `code_quality`, `error_handling`, `security`, `performance`)。アンダースコア区切りで統一する (schema.md の `category` フィールド定義を SoT として参照)
  - `severity`: `CRITICAL` / `HIGH` / `MEDIUM` / `LOW` のいずれか。reviewer が `Critical`/`Important`/`Minor`/`Nit` 等の別表記で返した場合は、write 前に本 enum へ正規化する (別名マッピングは review-result-schema.md の `severity` フィールド定義を参照)。正規化漏れの JSON は read 側 (`fix.md` Phase 1.2.0) で MEDIUM fallback と WARNING emit が発生する。
  - `file`: 対象ファイルの相対パス
  - `line`: 正の整数 (>= 1) または `null` (行非依存指摘の sentinel)。schema.md の `line` フィールド定義が SoT。新規出力では `null` を使用し、`0` は生成しないこと (`0` は legacy sentinel として read 側で `null` と同等に扱われるが、write 側で新たに生成すべきではない)。
  - `description`: 指摘内容
  - `suggestion`: 推奨対応
  - `status`: 現行実装では常に `open` を出力する。`fixed` / `replied` / `deferred` は enum として予約されているが、`/rite:pr:fix` 側の書き戻しは未実装 (schema は slot を持つのみ、review-result-schema.md の `status` フィールド定義を参照)。

**`iso_timestamp` Claude substitution handshake**:

`{review_result_json_heredoc_body}` 内の `timestamp` フィールドは Phase 6.1.a の bash block 内で算出される `$iso_timestamp` (TZ=Asia/Tokyo の ISO 8601 文字列) と **必ず一致** させる必要がある。

**Approach — bash-internal jq injection**: Claude は JSON heredoc body の `timestamp` フィールドに literal sentinel (`"__RITE_TS_PLACEHOLDER_7f3a9b2c__"`) を書き込む。bash block 内で `cat` heredoc 直後に `jq '.timestamp = $ts' --arg ts "$iso_timestamp"` を実行して sentinel を bash 計算値で上書きする。これにより JSON body / ファイル名 / `[CONTEXT]` emit の 3 値が bash 内で完全に同期する (秒跨ぎズレなし)。sentinel が残っていれば jq 置換前の jq 呼び出しが失敗し `json_invalid` reason で non-blocking 失敗する。

**採用しない代替案**: (a) heredoc 内で `$iso_timestamp` を bash 変数として直接参照する方式は `<<'RITE_JSON_EOF'` の single-quoted delimiter が shell expansion を抑制するため動作せず、unquoted delimiter に変更すると JSON 内の `$` 含有文字列が誤展開される副作用があり禁止。(b) JSON 生成を別 phase に分離する方式は trap / cleanup の複雑度が上がるため採用しない。

**Approach C の具体的手順**: Claude は以下の 2 ステップで Phase 6.1.a を実行する:

1. **JSON body 生成**: `{review_result_json_heredoc_body}` の `"timestamp"` フィールドに literal sentinel `"__RITE_TS_PLACEHOLDER_7f3a9b2c__"` を書き込む (`TZ=...date` は bash block 内で実行されるため Claude は値を知る必要がない)
2. **本番 invocation**: Phase 6.1.a の bash block を実行。bash block 内では (a) `iso_timestamp` を算出、(b) heredoc で sentinel を含む JSON を tmpfile に書き出し、(c) jq で sentinel を `$iso_timestamp` に置換、(d) schema validation、(e) atomic mv

この方式なら準備 invocation 不要で、Claude は bash block を 1 回実行するだけで済む。JSON body / ファイル名 / [CONTEXT] emit の 3 値は全て bash 内で算出された同一 `$iso_timestamp` / `$file_timestamp` に由来するため完全同期する。

```bash
# Phase 6.1.a: ローカルファイル保存 (JSON、非ブロッキング、signal-specific trap 保護)
# canonical trap pattern は references/bash-trap-patterns.md#signal-specific-trap-template 参照

# {pr_number} placeholder の literal substitution を冒頭で行い、以後は bash 変数として統一参照する
# (Claude placeholder と bash 変数展開の混在を避けて substitute 忘れによる literal ファイル名生成を防ぐ)
pr_number="{pr_number}"

# pr_number の数値 fail-fast gate。cleanup.md Phase 2.5 の pr_number guard と対称化。
# Claude が literal substitute を忘れた場合、json_path が `.rite/review-results/{pr_number}-...json`
# (literal) となり、cleanup.md Phase 2.5 の numeric glob (`${pr_number}-*.json`) と不一致で
# 永久 orphan 化する。数値以外 (空文字 / placeholder 残留 / 異常値) を early-exit で reject。
case "$pr_number" in
  ''|*[!0-9]*)
    echo "ERROR: Phase 6.1.a の pr_number が literal substitute されていません (値: '$pr_number', 期待: 数値のみ非空)" >&2
    echo "  Claude は Phase 1.0 で正規化された pr_number を本 bash block 冒頭で literal substitute する必要があります" >&2
    echo "[CONTEXT] LOCAL_SAVE_FAILED=1; reason=pr_number_placeholder_residue" >&2
    exit 0  # non-blocking: Phase 6 全体を失敗扱いにせず D-04 契約に従う
    ;;
esac

# json_tmp / mktemp_err は trap 保護対象 (orphan 防止)。
# date 計算は trap setup 後に実行する (失敗時に trap EXIT が `[CONTEXT] FILE_TIMESTAMP=unknown` を
# emit できるようにするため)。json_saved も trap handler が `${json_saved:-false}` で参照するため、
# 他の変数と同じく冒頭ブロックで初期化する (`set -u` 導入時の `${var:-default}` 偶然依存を排除)。
json_tmp=""
mktemp_err=""
iso_timestamp=""
file_timestamp=""
file_timestamp_emitted="false"
json_saved="false"
jq_val_err_r=""
_rite_review_p61a_cleanup() {
  rm -f "${json_tmp:-}" "${mktemp_err:-}" "${jq_val_err_r:-}"
  # file_timestamp / json_saved emit を trap EXIT handler 内に移動し、
  # normal/abnormal 両方で必ず emit されるようにする (Phase 6.1.c が emit 前提で動くため)
  if [ "$file_timestamp_emitted" = "false" ]; then
    echo "[CONTEXT] FILE_TIMESTAMP=${file_timestamp:-unknown}" >&2
    echo "[CONTEXT] ISO_TIMESTAMP=${iso_timestamp:-unknown}" >&2
    echo "[CONTEXT] JSON_SAVED=${json_saved:-false}" >&2
    file_timestamp_emitted="true"
  fi
}
trap 'rc=$?; _rite_review_p61a_cleanup; exit $rc' EXIT
trap '_rite_review_p61a_cleanup; exit 130' INT
trap '_rite_review_p61a_cleanup; exit 143' TERM
trap '_rite_review_p61a_cleanup; exit 129' HUP

# Generate ISO 8601 timestamp (TZ=Asia/Tokyo で BSD/GNU date 両対応、JST 固定)
# `date -Iseconds` は GNU 拡張で macOS/BSD では未サポートのため、portable な明示フォーマットを使用
# Source: https://www.jbmurphy.com/2011/02/17/gnu-date-vs-bsd-date/
#
# date 失敗時に file_timestamp が空文字となり
# json_path が `.rite/review-results/123-.json` 形式で生成され同一 PR の過去レビューを
# 上書きする silent regression を防ぐ。trap setup 後に date を実行することで、失敗時も
# `_rite_review_p61a_cleanup` が `[CONTEXT] FILE_TIMESTAMP=unknown` を emit できる。
# verified-review cycle 15 F-8 対応: 単一 date 呼出から両 timestamp を導出する。
# 旧実装は 2 回の date 呼出で秒跨ぎ時に iso_timestamp と file_timestamp が 1 秒ズレる可能性があった。
# Approach C の「秒跨ぎズレ消失」コメントと実装の乖離を解消する。
_ts_raw=$(TZ='Asia/Tokyo' date +'%Y-%m-%dT%H:%M:%S+09:00|%Y%m%d%H%M%S') || _ts_raw=""
iso_timestamp="${_ts_raw%%|*}"
file_timestamp="${_ts_raw##*|}"

if [ -z "$iso_timestamp" ] || [ -z "$file_timestamp" ]; then
  echo "WARNING: date コマンドの実行に失敗しました。ローカル保存をスキップします" >&2
  echo "  対処: TZ=Asia/Tokyo / date バイナリの存在を確認してください" >&2
  echo "[CONTEXT] LOCAL_SAVE_FAILED=1; reason=date_command_failure" >&2
  # 非ブロッキング契約 (Phase 6.1.a Non-blocking Contract / D-04 compliance): Phase 6 全体を失敗扱いにせず exit 0 で early return
  # trap EXIT が `[CONTEXT] FILE_TIMESTAMP=unknown` を emit する (Phase 6.1.c が emit 前提で動作)
  exit 0
fi

review_results_dir=".rite/review-results"
json_path="${review_results_dir}/${pr_number}-${file_timestamp}.json"

# 注: json_saved の初期化は本 bash block 冒頭の変数宣言ブロックに移動済み
#

# Create directory (MUST NOT fail Phase 6 if creation fails)
mkdir_err=$(mktemp /tmp/rite-review-p61a-mkdir-err-XXXXXX 2>/dev/null) || mkdir_err=""
if ! mkdir -p "$review_results_dir" 2>"${mkdir_err:-/dev/null}"; then
  echo "WARNING: .rite/review-results/ ディレクトリの作成に失敗しました。会話コンテキストのみで続行します。" >&2
  if [ -n "$mkdir_err" ] && [ -s "$mkdir_err" ]; then
    head -5 "$mkdir_err" | sed 's/^/  /' >&2
  fi
  echo "  対処: 親ディレクトリの permission / disk space / read-only filesystem を確認してください" >&2
  echo "[CONTEXT] LOCAL_SAVE_FAILED=1; reason=mkdir_failure" >&2
  [ -n "$mkdir_err" ] && rm -f "$mkdir_err"
else
  [ -n "$mkdir_err" ] && rm -f "$mkdir_err"
  # mktemp の stderr を tempfile に退避して、失敗時に原因 (disk full / permission / readonly) を可視化
  # mktemp の stderr 退避 tempfile を作る mktemp 自体の失敗経路でも WARNING を emit
  # (cleanup.md Phase 2.5 と Phase 6.1.a C-5 修正と対称化、meta silent 化を防ぐ)
  if ! mktemp_err=$(mktemp /tmp/rite-review-p61a-mktemp-err-XXXXXX 2>/dev/null); then
    echo "WARNING: mktemp stderr 退避用 tempfile の mktemp に失敗しました (meta エラー)。json_tmp 失敗時の stderr 詳細は失われます" >&2
    mktemp_err=""
  fi

  if ! json_tmp=$(mktemp /tmp/rite-review-p61a-json-XXXXXX.json 2>"${mktemp_err:-/dev/null}"); then
    echo "WARNING: JSON 一時ファイルの作成に失敗しました" >&2
    if [ -n "$mktemp_err" ] && [ -s "$mktemp_err" ]; then
      echo "  詳細 (mktemp stderr):" >&2
      head -5 "$mktemp_err" | sed 's/^/  /' >&2
    fi
    echo "  対処: /tmp の容量 / permission / readonly filesystem を確認してください" >&2
    echo "[CONTEXT] LOCAL_SAVE_FAILED=1; reason=mktemp_failure" >&2
    json_tmp=""
  fi

  if [ -n "$json_tmp" ]; then
    if ! cat > "$json_tmp" <<'RITE_JSON_EOF'
{review_result_json_heredoc_body}
RITE_JSON_EOF
    then
      echo "WARNING: JSON 一時ファイルへの書き込みに失敗しました" >&2
      echo "[CONTEXT] LOCAL_SAVE_FAILED=1; reason=write_failure" >&2
    elif [ ! -s "$json_tmp" ]; then
      echo "WARNING: JSON 一時ファイルが空です (cat 成功だが post-condition 違反)" >&2
      echo "[CONTEXT] LOCAL_SAVE_FAILED=1; reason=write_failure" >&2
    else
      # Approach C bash-internal jq injection
      # Claude が `"timestamp": "__RITE_TS_PLACEHOLDER_7f3a9b2c__"` を literal に書き込み、
      # bash 内で jq --arg ts "$iso_timestamp" で正しい値に置換する。これにより
      # JSON body / ファイル名 / [CONTEXT] emit の 3 値が bash 内で完全同期する (秒跨ぎズレ消失)。
      # 失敗時は write_failure reason emit + json_tmp="" で後続処理を skip (non-blocking 失敗)。
      json_ts_injected=$(mktemp /tmp/rite-review-p61a-json-ts-XXXXXX.json 2>/dev/null) || json_ts_injected=""
      jq_ts_err=$(mktemp /tmp/rite-review-p61a-jq-ts-err-XXXXXX 2>/dev/null) || jq_ts_err=""
      if [ -z "$json_ts_injected" ]; then
        echo "WARNING: timestamp 注入用 tempfile の mktemp に失敗しました" >&2
        echo "[CONTEXT] LOCAL_SAVE_FAILED=1; reason=write_failure" >&2
        json_tmp=""  # 後続処理を skip
      elif jq --arg ts "$iso_timestamp" '.timestamp = $ts' "$json_tmp" > "$json_ts_injected" 2>"${jq_ts_err:-/dev/null}"; then
        # C-1 対応 (verified-review cycle 9): inner mv の exit code を明示 check する。
        # 未 check だと mv 失敗 (cross-fs / TOCTOU / permission / disk full) 時に $json_tmp は
        # sentinel "__RITE_TS_PLACEHOLDER_7f3a9b2c__" のまま残留し、sentinel は valid JSON string の
        # ため後続の jq empty / schema_required_fields / finding id 検証を全て通過して最終 mv で
        # 永続ファイルに sentinel 混入 → JSON_SAVED=true emit → pr:fix Priority 2 で読取 (commit_sha
        # stale detection は通るため検知不能) という silent corruption になる。外側 mv と対称化する。
        if ! mv "$json_ts_injected" "$json_tmp" 2>/dev/null; then
          echo "WARNING: timestamp 注入済み tmpfile の mv に失敗しました (cross-fs / permission / TOCTOU)" >&2
          echo "[CONTEXT] LOCAL_SAVE_FAILED=1; reason=timestamp_injection_mv_failure" >&2
          rm -f "$json_ts_injected"
          json_tmp=""  # 後続の schema validation / final mv を skip (sentinel 残留を final path に書かない)
        fi
      else
        echo "WARNING: jq による timestamp 注入に失敗しました (sentinel 置換不可)" >&2
        if [ -n "$jq_ts_err" ] && [ -s "$jq_ts_err" ]; then
          head -3 "$jq_ts_err" | sed 's/^/  /' >&2
        fi
        echo "  対処: review_result_json_heredoc_body が valid JSON で、.timestamp フィールドを持つか確認してください" >&2
        echo "[CONTEXT] LOCAL_SAVE_FAILED=1; reason=write_failure" >&2
        rm -f "$json_ts_injected"
        json_tmp=""  # 後続の schema validation / mv をスキップ (sentinel 残留を final path に書かない)
      fi
      [ -n "$jq_ts_err" ] && rm -f "$jq_ts_err"
    fi

    if [ -z "$json_tmp" ] || [ ! -s "$json_tmp" ]; then
      # Injection 失敗または tmpfile empty → 上流で既に LOCAL_SAVE_FAILED emit 済み、後続 validation/mv skip
      :
    elif jq_val_err_r=$(mktemp /tmp/rite-jq-val-err-r-XXXXXX 2>/dev/null) || true; ! jq empty "$json_tmp" 2>"${jq_val_err_r:-/dev/null}"; then
      # cat 成功 + non-empty でも JSON syntactically invalid (Claude substitute ミス) を検出
      # literal `{review_result_json_heredoc_body}` がそのまま書き込まれた場合もここで catch される
      echo "WARNING: JSON 一時ファイルが syntactically invalid です (literal substitute 漏れの可能性)" >&2
      [ -n "${jq_val_err_r:-}" ] && [ -s "$jq_val_err_r" ] && head -3 "$jq_val_err_r" | sed 's/^/  jq: /' >&2
      # 不正 JSON の先頭 5 行を表示して debug を可能にする
      # trap EXIT が $json_tmp を削除する前に内容を surface する
      echo "  内容 preview (先頭 5 行):" >&2
      head -5 "$json_tmp" 2>/dev/null | sed 's/^/    /' >&2
      echo "  対処: review-result-schema.md に従った正しい JSON が Claude によって生成されているか確認してください" >&2
      echo "[CONTEXT] LOCAL_SAVE_FAILED=1; reason=json_invalid" >&2
      rm -f "${jq_val_err_r:-}"
    elif ! jq -e '
      (.schema_version | type == "string" and length > 0)
      and (.pr_number | type == "number")
      and (.findings | type == "array")
    ' "$json_tmp" >/dev/null 2>&1; then
      # canonical jq validation (see common-error-handling.md#jq-required-fields-snippet-canonical)
      echo "WARNING: JSON が必須フィールド (schema_version 非空文字列 / pr_number 数値型 / findings[] 配列型) を欠いています" >&2
      echo "  対処: Claude が review-result-schema.md に従った完全な JSON を生成しているか確認してください" >&2
      echo "[CONTEXT] LOCAL_SAVE_FAILED=1; reason=schema_required_fields_missing" >&2
    elif ! jq -e '
      (.findings | length == 0)
      or (
        (.findings | all(.id? // "" | test("^F-[0-9]{2,}$")))
        and ([.findings[].id] | unique | length == (.findings | length))
      )
    ' "$json_tmp" >/dev/null 2>&1; then
      # finding id の書式と一意性の machine-enforced validation。
      # review-result-schema.md の findings[] id 仕様 (`^F-[0-9]{2,}$`、一意性) に従う。
      # jq の test() で正規表現 check し、unique の長さで重複を検出する。findings が 0 件の
      # 場合は validation を skip する (空配列 all() は true を返すが明示的に短絡する)。
      # 非ブロッキング契約 (D-04) に従い、違反時は WARNING + retained flag emit のみで
      # Phase 6 全体は fail させない。
      echo "WARNING: JSON の findings[].id が書式 (F-NN) または一意性の要件を満たしていません" >&2
      echo "  期待: 全 finding が ^F-[0-9]{2,}\$ に match し、かつ全 id が一意" >&2
      echo "  対処: review-result-schema.md の findings[] id 仕様を確認してください" >&2
      echo "[CONTEXT] LOCAL_SAVE_FAILED=1; reason=finding_id_format_or_uniqueness_violation" >&2
    else
      # 同一秒連続 review 実行時の file path 衝突を回避する。
      # Phase 6.1.a は JST 1 秒解像度で file_timestamp を生成するため、同一 PR に対し
      # 同一秒以内に 2 回 /rite:pr:review が呼ばれると既存ファイルを silent 上書きする (schema doc
      # L15 の「履歴保持」契約違反)。collision 検出時は `~$RANDOM` suffix を追加して衝突回避する。
      # best-effort (完全保証ではない — schema doc M-2 tradeoff 注記と整合)。
      #
      # separator を `-` から `~` に変更。
      # ASCII 上 `-` (0x2D) < `.` (0x2E) のため、旧 `${ts}-${rand}.json` は `sort -r` で
      # `${ts}.json` より **後ろ** に並び、Priority 2 fallback が古い非 collision 版を
      # 先に選んでしまう silent regression を抱えていた。`~` (0x7E) > `.` (0x2E) を使うことで、
      # `${ts}~${rand}.json` が `${ts}.json` より lex 大となり、sort -r で collision-resolved
      # な新しい方が先頭に来る。cleanup glob `${pr_number}-*.json` は引き続き両形式に match する
      # (prefix が `${pr_number}-` で始まるため)。
      if [ -e "$json_path" ]; then
        # 2 段目 check を追加。旧実装は collision 検出時に `~$RANDOM` suffix を 1 度だけ
        # 付与し、再衝突 (同秒 3 回目以降 / `$RANDOM` が fallback `0` に落ちたケース) を silent に
        # 上書きする経路があった (履歴保持契約違反 — schema.md L15 の best-effort tradeoff 注記は
        # 「完全保証ではない」としつつも silent overwrite は想定外)。再衝突を明示検出し、
        # `collision_resolution_exhausted` reason で LOCAL_SAVE_FAILED を emit して skip する。
        # 参考: bash manual の `RANDOM` 仕様 — special 変数は unset 可能で、unset すると special 性を
        # 失うため `${RANDOM:-0}` fallback 経路は reviewer 想定より発火しやすい
        # ([Bash Variables](https://www.gnu.org/software/bash/manual/html_node/Bash-Variables.html))。
        json_path_alt="${review_results_dir}/${pr_number}-${file_timestamp}~$(printf '%04x' "${RANDOM:-0}").json"
        if [ -e "$json_path_alt" ]; then
          echo "WARNING: collision suffix 付与後も再衝突を検出しました ($json_path_alt)。保存を skip します" >&2
          echo "  原因候補: 同秒 3 回目以降の連続実行 / \$RANDOM が fallback '0' に落ちた / parallel race" >&2
          echo "  対処: 1 秒待機してから /rite:pr:review を再実行してください" >&2
          echo "[CONTEXT] LOCAL_SAVE_FAILED=1; reason=collision_resolution_exhausted; original=$json_path; resolved_attempt=$json_path_alt" >&2
          json_saved="false"
          # Phase 6.1.a は non-blocking contract のため exit 0 で return する (trap cleanup が
          # json_tmp 等を削除する)。Phase 6.1.c は LOCAL_SAVE_FAILED=1 を retained flag で検出し
          # post_comment_mode=false のとき case 2 (hard fail `exit 2`) に入る (cycle 10 C-1 と整合)。
          exit 0
        fi
        echo "WARNING: 同一秒衝突を検出しました ($json_path)。collision suffix を追加します: $json_path_alt" >&2
        echo "[CONTEXT] LOCAL_SAVE_COLLISION=1; original=$json_path; resolved=$json_path_alt" >&2
        json_path="$json_path_alt"
      fi
      # mv stderr を tempfile に退避して失敗時に原因を可視化する。
      # 旧実装 `mv ... 2>/dev/null` は cross-FS / perm / TOCTOU / path-too-long のどれか区別できず
      # debug 不能だった。Phase 6.1.b の gh pr comment 失敗 branch と同じパターンに揃える。
      # mv_err の mktemp 失敗を silent 化しない。
      # 旧実装は `2>/dev/null || mv_err=""` で二重 silent 化し、mktemp 失敗時に mv の stderr も
      # 失われていた。mktemp 失敗時は WARNING を出し retained flag も emit する。
      if ! mv_err=$(mktemp /tmp/rite-review-p61a-mv-err-XXXXXX); then
        echo "WARNING: mv stderr 退避用 tempfile の mktemp に失敗しました。mv 失敗時の stderr は失われます" >&2
        echo "[CONTEXT] LOCAL_SAVE_FAILED=1; reason=mktemp_failure_mv_err" >&2
        mv_err=""
      fi
      if mv "$json_tmp" "$json_path" 2>"${mv_err:-/dev/null}"; then
        # 成功メッセージも stderr に統一する。
        # 本 bash block の他の WARNING / [CONTEXT] emit はすべて `>&2` で stderr に出力されており、
        # 「[CONTEXT] emit は stderr 統一」原則を打ち出している。成功メッセージだけ stdout という
        # 非対称は、将来 Claude が bash 出力を parse する際に observability ログとデータの境界を曖昧化させ、
        # silent regression のリスクを生む。stdout は「データ専用」、stderr は「観測値専用」に揃える。
        echo "✅ レビュー結果を保存しました: $json_path" >&2
        json_saved="true"
        json_tmp=""  # mv 成功後は trap による削除対象から外す
        [ -n "$mv_err" ] && rm -f "$mv_err"
      else
        echo "WARNING: JSON ファイルの配置に失敗しました" >&2
        echo "  from: $json_tmp" >&2
        echo "  to:   $json_path" >&2
        if [ -n "$mv_err" ] && [ -s "$mv_err" ]; then
          echo "  詳細 (mv stderr 先頭 5 行):" >&2
          head -5 "$mv_err" | sed 's/^/    /' >&2
        fi
        echo "  対処: cross-filesystem / permission denied / read-only FS / path-too-long / TOCTOU のいずれかを確認してください" >&2
        echo "[CONTEXT] LOCAL_SAVE_FAILED=1; reason=mv_failure" >&2
        [ -n "$mv_err" ] && rm -f "$mv_err"
      fi
    fi
  fi
fi
# [CONTEXT] FILE_TIMESTAMP / ISO_TIMESTAMP / JSON_SAVED の emit は EXIT trap 内 (_rite_review_p61a_cleanup) で行う
# (L-4 対応: abnormal exit 経路でも必ず emit されるよう trap handler に移動)
```

**Non-blocking contract** (Phase 6.1.a Non-blocking Contract / D-04 compliance): when any step in this sub-phase fails (mkdir, mktemp, write, jq validation, or mv), the failure is recorded via `[CONTEXT] LOCAL_SAVE_FAILED=1; reason=...` emission but Phase 6 is NOT failed — it logs a WARNING and proceeds. The review results remain available via conversation context for immediate `/rite:pr:fix` invocation.

**Placeholder data flow**:
- `file_timestamp` / `iso_timestamp` / `json_saved` は **EXIT trap handler 内**で `[CONTEXT]` として stderr に emit される (normal/abnormal 両方の経路で確実に emit される)。
- Phase 6.1.c の machine-enforced bash block は `file_timestamp` と `local_save_failed` のみを substitute に使う (ユーザー向けテンプレートに embed する値)。`iso_timestamp` は **observability ログ専用** (後追い debug / drift 検出用) であり、user-facing メッセージには含まれない — cycle 8 L-1 対応で責務分離を明記。
- `iso_timestamp` は Phase 6.1.a 内で算出された値であり、JSON body 生成にも使用される (Approach C bash-internal jq injection)。Claude が独立計算すると秒跨ぎでズレるリスクがあったが、cycle 8 M-6 で bash 内完全同期に修正済み。

#### 6.1.b PR Comment Post (Conditional on `{post_comment_mode}` — #443) <!-- AC-2: opt-in PR comment posting -->

Execute this sub-phase **only when** `{post_comment_mode}=true` from Phase 1.0. When `{post_comment_mode}=false`, skip this entire sub-phase.

> **Acceptance Criteria anchor**: AC-2 (`--post-comment` 指定時 or `rite-config.yml pr_review.post_comment: true` 時に PR コメントに投稿、code fence JSON 形式で JSON 本文も埋め込む)。D-03 (PR コメント形式は code fence JSON を採用 — pr:fix が正規表現でパースしやすく人間も閲覧可能)。

**Nested code fence 対策**: 投稿する PR コメント本文は Markdown テーブル + code fence JSON を含む。外側 bash fenced code block (本ドキュメント中) を **4-backtick** で包むことで、内側 3-backtick の code fence を透過的に含められる。

**Claude substitution requirements**:
- `{review_result_content_heredoc_body}`: Phase 5.4 で生成した integrated report 全体 (Markdown)。改行・バッククォート・シングルクォート・`$` を含んでもよい。
- `{review_result_json_heredoc_body}`: Phase 6.1.a と構造的に**同一**の JSON 本文 (Raw JSON セクション埋込用)。**⚠️ 重要** (cycle 10 I-A 対応): Phase 6.1.a で使用する sentinel `"__RITE_TS_PLACEHOLDER_7f3a9b2c__"` を Phase 6.1.b でも literal に書き込み、**本 bash block 内で jq 注入ステップを再実行** して bash 算出の `$iso_timestamp_from_p61a` に置換する。これは Phase 6.1.a と 6.1.b がそれぞれ独立した bash invocation のため、bash 変数 `$iso_timestamp` が継承されないためである。旧実装 (cycle 9 以前) は「Phase 6.1.a と同一の JSON 本文」を literal に再利用する設計だったが、sentinel が Raw JSON セクションに残留し Phase 1.2.0 Priority 3 が sentinel 付き timestamp で findings を解釈する silent regression を持っていた。
- `{iso_timestamp_from_p61a}`: Phase 6.1.a の `[CONTEXT] ISO_TIMESTAMP=` の emit 値を Claude が会話コンテキストから読み取り、literal 置換する。sentinel 残留は下記 bash block 内の `case` gate で fail-fast する。
- `{pr_number}`: Phase 1.0 の値。

````bash
# Phase 6.1.b: PR コメント投稿 (signal-specific trap 保護)。
# tmpfile / gh_err / tmpfile_patched (sentinel 置換用中間ファイル) を trap cleanup 対象に含める
# (canonical signal-specific trap pattern 準拠)。tmpfile_patched は mktemp から mv 成功までの区間で
# signal を受けても orphan にならないよう trap 登録し、mv 成功後に tmpfile_patched="" で空文字 reset
# して trap による二重 rm を回避する。

# pr_number の束縛 + numeric gate (Phase 6.1.a / 6.1.c と対称化)
pr_number="{pr_number}"
case "$pr_number" in
  ''|*[!0-9]*)
    echo "ERROR: Phase 6.1.b の pr_number が literal substitute されていません (値: '$pr_number', 期待: 数値のみ非空)" >&2
    echo "[CONTEXT] REVIEW_OUTPUT_FAILED=1; reason=p61b_pr_number_invalid" >&2
    echo "[review:error]"
    exit 1
    ;;
esac

# json_saved_from_p61a sentinel check を bash block 冒頭で実行する (success/failure 両経路で検証)。
# Claude は Phase 6.1.a の [CONTEXT] JSON_SAVED=true|false emit 値を会話コンテキストから読み取り、
# `"true"` または `"false"` に literal substitute する。placeholder 残留は fail-fast。
json_saved_from_p61a="{json_saved_from_p61a}"
case "$json_saved_from_p61a" in
  true|false)
    ;;
  *)
    echo "ERROR: Phase 6.1.b の json_saved_from_p61a が literal substitute されていません (値: '$json_saved_from_p61a')" >&2
    echo "  Claude は Phase 6.1.a の [CONTEXT] JSON_SAVED=true|false emit 値を会話コンテキストから読み取り、" >&2
    echo "  この bash block 冒頭の json_saved_from_p61a=... 行を実際の値で置換する必要があります。" >&2
    echo "  許容値: true / false" >&2
    echo "[CONTEXT] REVIEW_OUTPUT_FAILED=1; reason=json_saved_from_p61a_unset" >&2
    exit 1
    ;;
esac

tmpfile=""
gh_err=""
tmpfile_patched=""
_rite_review_p61b_cleanup() {
  rm -f "${tmpfile:-}" "${gh_err:-}" "${tmpfile_patched:-}"
}
trap 'rc=$?; _rite_review_p61b_cleanup; exit $rc' EXIT
trap '_rite_review_p61b_cleanup; exit 130' INT
trap '_rite_review_p61b_cleanup; exit 143' TERM
trap '_rite_review_p61b_cleanup; exit 129' HUP

tmpfile=$(mktemp /tmp/rite-review-p61b-comment-XXXXXX.md) || {
  echo "ERROR: tmpfile 作成失敗" >&2
  echo "[CONTEXT] REVIEW_OUTPUT_FAILED=1; reason=tmpfile_write_failure" >&2
  exit 1
}

# cycle 10 I-A 対応: iso_timestamp_from_p61a sentinel fail-fast gate
# Phase 6.1.a の [CONTEXT] ISO_TIMESTAMP=... を Claude が読み取って literal substitute する責務を機械的に強制。
# 旧実装 (cycle 9 以前) は Phase 6.1.a と同一 JSON body を literal に再利用する設計だったため、
# sentinel "__RITE_TS_PLACEHOLDER_7f3a9b2c__" が Raw JSON セクションに残留し、Phase 1.2.0 Priority 3 が
# sentinel 付き timestamp で findings を解釈する silent regression を持っていた。
iso_timestamp_from_p61a="{iso_timestamp_from_p61a}"
case "$iso_timestamp_from_p61a" in
  "{"*|*"}"|""|"__RITE_TS_PLACEHOLDER_7f3a9b2c__")
    echo "ERROR: Phase 6.1.b の iso_timestamp_from_p61a が literal substitute されていません (値: '$iso_timestamp_from_p61a')" >&2
    echo "  Claude は Phase 6.1.a の [CONTEXT] ISO_TIMESTAMP=... emit 値を会話コンテキストから読み取り、" >&2
    echo "  この bash block 冒頭の iso_timestamp_from_p61a=... 行を ISO 8601 文字列 (例: 2026-04-11T12:34:56+09:00) で置換する必要があります" >&2
    echo "[CONTEXT] REVIEW_OUTPUT_FAILED=1; reason=iso_timestamp_from_p61a_unset" >&2
    exit 1
    ;;
esac

# RITE_COMMENT_EOF_7f3a9b2c: 衝突可能性の極めて低い sentinel
# JSON 本文は Phase 6.1.a と構造的に同一で timestamp フィールドには sentinel を書き込む。
# 直後の jq 注入ステップで sentinel を $iso_timestamp_from_p61a に置換する (6.1.a と対称化)。
if ! cat > "$tmpfile" <<'RITE_COMMENT_EOF_7f3a9b2c'
## 📜 rite レビュー結果

{review_result_content_heredoc_body}

---

### 📄 Raw JSON

```json
{review_result_json_heredoc_body}
```

---
🤖 Generated by `/rite:pr:review`
RITE_COMMENT_EOF_7f3a9b2c
then
  echo "ERROR: レビュー結果の一時ファイル書き込みに失敗" >&2
  echo "[CONTEXT] REVIEW_OUTPUT_FAILED=1; reason=tmpfile_write_failure" >&2
  exit 1
fi

# Raw JSON セクション内の sentinel を $iso_timestamp_from_p61a に置換する。
#
# Scope 限定の必要性: tmpfile は Markdown 本文 + Raw JSON section を含み、reviewer が finding の
# description / suggestion 列に literal `__RITE_TS_PLACEHOLDER_7f3a9b2c__` を書いた場合 (本 PR 自身が
# dogfooding で該当する)、ファイル全体に対する sed 置換は Markdown 側の literal も silent に書き換える
# overreach を起こす。awk で「`### 📄 Raw JSON` 見出し以降の ```json ~ ``` コードフェンス内」のみを
# scope として置換することで、Markdown 本文の literal sentinel には一切触れない。
#
# invariant: Phase 6.1.a が生成する Raw JSON は timestamp フィールドを 1 箇所だけ持つ。置換後の
# post-condition check で (a) Raw JSON section 内に sentinel が残留しないこと、(b) Markdown 本文内の
# literal sentinel は保存されていることの 2 点を検証する。
tmpfile_patched=$(mktemp /tmp/rite-review-p61b-comment-patched-XXXXXX.md) || {
  echo "ERROR: timestamp 置換用 tmpfile 作成失敗" >&2
  echo "[CONTEXT] REVIEW_OUTPUT_FAILED=1; reason=tmpfile_write_failure" >&2
  exit 1
}
# awk で Raw JSON section 内の sentinel のみを置換する。
# State machine (END block 内で last_heading 以降を処理):
#   - past=0 (未設定) → 最後の `### 📄 Raw JSON` 見出し以前、sentinel 置換しない
#   - past=1, in_fence=0 → 最後の見出し後だがコードフェンス外、sentinel 置換しない
#   - past=1, in_fence=1 → Raw JSON コードフェンス内、sentinel を置換対象にする
#
# NOTE (verified-review cycle 18 F-3 対応): fix.md Priority 3 awk の「最後の `### 📄 Raw JSON`」
# 方式に統一する。Phase 6.1.b の PR コメント構造では同見出しが 1 回のみ出現するため
# first/last の差異は実害ないが、defense-in-depth として fix.md と同じ「last」パターンに
# 合わせることで、finding 列に literal `### 📄 Raw JSON` が含まれる将来の反例に備える。
# 実装: 1-pass で全行を buffer に蓄え、END block で最後の heading 位置以降の fence 内のみ置換。
awk -v ts="$iso_timestamp_from_p61a" '
  { lines[NR] = $0 }
  /^### 📄 Raw JSON/ { last_heading = NR }
  END {
    in_fence = 0
    for (i = 1; i <= NR; i++) {
      if (i == last_heading) { past = 1; print lines[i]; continue }
      if (past && lines[i] ~ /^```json$/) { in_fence = 1; print lines[i]; continue }
      if (past && in_fence && lines[i] ~ /^```$/) { in_fence = 0; print lines[i]; continue }
      if (in_fence) {
        gsub(/"__RITE_TS_PLACEHOLDER_7f3a9b2c__"/, "\"" ts "\"", lines[i])
      }
      print lines[i]
    }
  }
' "$tmpfile" > "$tmpfile_patched"
awk_rc=$?
if [ "$awk_rc" -ne 0 ]; then
  echo "ERROR: Raw JSON 内 sentinel の awk 置換に失敗しました (rc=$awk_rc)" >&2
  echo "[CONTEXT] REVIEW_OUTPUT_FAILED=1; reason=raw_json_timestamp_injection_failed" >&2
  rm -f "$tmpfile_patched"
  exit 1
fi

# Post-condition (a): Raw JSON section 内に sentinel が残留していないこと。
# main awk と同じ「last heading」パターンで Raw JSON section 内のみを抽出し、sentinel を検索する。
remaining_in_raw_json=$(awk '
  { lines[NR] = $0 }
  /^### 📄 Raw JSON/ { last_heading = NR }
  END {
    in_fence = 0
    for (i = 1; i <= NR; i++) {
      if (i == last_heading) { past = 1; continue }
      if (past && lines[i] ~ /^```json$/) { in_fence = 1; continue }
      if (past && in_fence && lines[i] ~ /^```$/) { in_fence = 0; continue }
      if (in_fence && lines[i] ~ /"__RITE_TS_PLACEHOLDER_7f3a9b2c__"/) { print lines[i] }
    }
  }
' "$tmpfile_patched")
if [ -n "$remaining_in_raw_json" ]; then
  echo "ERROR: 置換後も Raw JSON section 内に sentinel が残留しています" >&2
  echo "  Phase 6.1.a が生成する JSON は timestamp フィールドを 1 箇所のみ持つ invariant が破られた可能性" >&2
  echo "[CONTEXT] REVIEW_OUTPUT_FAILED=1; reason=raw_json_timestamp_injection_failed" >&2
  rm -f "$tmpfile_patched"
  exit 1
fi

# Post-condition (b): Markdown 本文 (Raw JSON section 外) の literal sentinel が保存されていること。
# 元の tmpfile と patched tmpfile の Markdown section (最後の Raw JSON heading より前) を比較し、
# 違いがないことを確認する。scope 外の副作用を静的に遮断する defense-in-depth。
# main awk と同じ「last heading」パターンで、最後の heading 直前までを抽出する。
original_markdown=$(awk '
  /^### 📄 Raw JSON/ { last_heading = NR }
  { lines[NR] = $0 }
  END { for (i = 1; i < (last_heading ? last_heading : NR+1); i++) print lines[i] }
' "$tmpfile")
patched_markdown=$(awk '
  /^### 📄 Raw JSON/ { last_heading = NR }
  { lines[NR] = $0 }
  END { for (i = 1; i < (last_heading ? last_heading : NR+1); i++) print lines[i] }
' "$tmpfile_patched")
if [ "$original_markdown" != "$patched_markdown" ]; then
  echo "ERROR: sentinel 置換が Markdown 本文 (Raw JSON section 外) まで波及しました" >&2
  echo "  scope 限定 awk が Raw JSON section を正しく特定できなかった可能性" >&2
  echo "[CONTEXT] REVIEW_OUTPUT_FAILED=1; reason=raw_json_timestamp_injection_failed" >&2
  rm -f "$tmpfile_patched"
  exit 1
fi
# 置換済みファイルを本 tmpfile に mv (atomic replace)。trap cleanup の対象のまま維持。
if ! mv "$tmpfile_patched" "$tmpfile"; then
  echo "ERROR: sentinel 置換済み tmpfile の mv に失敗しました" >&2
  echo "[CONTEXT] REVIEW_OUTPUT_FAILED=1; reason=raw_json_timestamp_injection_failed" >&2
  rm -f "$tmpfile_patched"
  exit 1
fi
# mv 成功後に tmpfile_patched を trap cleanup 対象から外す (二重 rm 回避)。
# Phase 6.1.a の json_ts_injected → json_tmp="" と同じ canonical 2-state commit pattern。
tmpfile_patched=""

# gh pr comment の exit code を明示捕捉 (silent failure 防止)
# `if ! cmd; then rc=$?` パターンは bash 仕様上 $? が
# 常に 0 になる (`!` パイプライン否定の結果が then 節に伝播)。`if cmd; then :; else rc=$?` の
# else 節形式に切り替えることで gh pr comment 自身の exit code を正しく捕捉する。
# 実証: `bash -c 'if ! (exit 42); then echo $?; fi'` → `0`
gh_err=$(mktemp /tmp/rite-review-p61b-gh-err-XXXXXX) || gh_err=""
if gh pr comment "$pr_number" --body-file "$tmpfile" 2>"${gh_err:-/dev/null}"; then
  # PR コメント投稿成功。ローカルファイル保存が失敗していた場合はユーザーに通知する。
  # json_saved_from_p61a は bash block 冒頭の case guard (line ~2975) で "true"|"false" に検証済み
  if [ "$json_saved_from_p61a" = "false" ]; then
    echo "ℹ️  ローカルファイル保存は失敗しましたが、PR コメントへの投稿は成功しました。" >&2
    echo "    次回 /rite:pr:fix は Priority 3 (PR コメント) から読取ります" >&2
  fi
else
  gh_rc=$?
  echo "ERROR: PR コメント投稿に失敗しました (gh rc=$gh_rc)" >&2
  if [ -n "$gh_err" ] && [ -s "$gh_err" ]; then
    echo "  詳細 (gh stderr 先頭 5 行):" >&2
    head -5 "$gh_err" | sed 's/^/  /' >&2
  fi
  echo "  対処: gh auth status / network 接続 / PR #${pr_number} の権限を確認してください" >&2
  # json_saved_from_p61a は bash block 冒頭で検証済み (success/failure 両経路で sentinel check 実行)
  if [ "$json_saved_from_p61a" = "true" ]; then
    echo "ℹ️  ただし、レビュー結果はローカルファイルに保存済みです" >&2
    echo "    [CONTEXT] FILE_TIMESTAMP / JSON_SAVED 参照: Phase 6.1.a の emit 値" >&2
    echo "    そのまま /rite:pr:fix を実行できます (Priority 2 で自動読取)" >&2
  fi
  # SIGPIPE 等の signal 終了を retained flag に併記する
  # (`gh pr comment` が rc >= 128 で死んだ場合、rc - 128 が signal number を示す。
  # signal 終了 (data 破損なし) と通常の write error を retained flag レベルで区別できるようにする)。
  # caller 側の意味論単純化のため `exit 1` に正規化 (実 rc は retained flag の `rc=` で retain 済み)
  if [ "${gh_rc:-1}" -ge 128 ]; then
    gh_signal=$((gh_rc - 128))
    echo "[CONTEXT] REVIEW_OUTPUT_FAILED=1; reason=gh_comment_post_failure; rc=$gh_rc; signal=$gh_signal; json_saved=$json_saved_from_p61a" >&2
  else
    echo "[CONTEXT] REVIEW_OUTPUT_FAILED=1; reason=gh_comment_post_failure; rc=$gh_rc; json_saved=$json_saved_from_p61a" >&2
  fi
  [ -n "$gh_err" ] && rm -f "$gh_err"
  exit 1
fi
[ -n "$gh_err" ] && rm -f "$gh_err"
````

**Note**: Using `--body-file` with a temp file eliminates escaping issues and avoids shell variable expansion risks. The outer 4-backtick fence in this doc (` ```` `) contains the inner 3-backtick `` ```json `` / `` ``` `` inside the heredoc without breaking Markdown rendering.

**Note**: `{review_result_content_heredoc_body}` uses the integrated report generated in Phase 5.4 (template based on `review_mode`). The `📎 reviewed_commit: {current_commit_sha}` at the end of the report is used in the verification mode of the next cycle, so it must always be included.

**Note on Raw JSON section** (#443): The `### 📄 Raw JSON` section embeds the same JSON as saved to the local file (Phase 6.1.a). This enables `/rite:pr:fix` to extract the JSON via a parse over the `` ```json `` fence using **section-scoped awk line-state parsing** in `fix.md` Phase 1.2.0 Priority 3 (the parser uses the `### 📄 Raw JSON` heading as a scope marker to avoid capturing sample JSON fences from findings' suggestion columns earlier in the comment). The Markdown table format above the Raw JSON section is preserved for human readability and backward compatibility with older fix-loop parsing logic.

#### 6.1.c Skip Notification (when `{post_comment_mode}=false`)

When `{post_comment_mode}=false`, inform the user that PR comment posting was skipped (for observability — this is not an error).

> **verified-review (cycle 8) M-9 対応**: 旧実装は Claude が `[CONTEXT] LOCAL_SAVE_FAILED=...` を自然言語で読み取ってケース分岐する方式だった。Claude が flag 見落としでケース 1 に silent fallthrough する経路があり、silent data loss 防止の H-1 修正が骨抜きになるリスクがあった。本 cycle で bash block による **machine-enforced gate** を追加し、Claude は下記 bash block を実行するだけで適切なメッセージが stderr に emit される (prose 記述は実装の参考情報として残す)。

**Machine-enforced case selection** (verified-review cycle 8 M-9):

```bash
# Phase 6.1.c: Skip Notification (machine-enforced case split)
#
# 実行条件: {post_comment_mode}=false の経路のみ (true 経路では Phase 6.1.b の成功/失敗ログで完結する)
# 依存: Phase 6.1.a が [CONTEXT] FILE_TIMESTAMP=... / LOCAL_SAVE_FAILED=... を emit 済み
#
# Claude は以下 3 変数を Phase 6.1.a の emit 値で literal substitute する:
#   - pr_number: {pr_number}
#   - file_timestamp: [CONTEXT] FILE_TIMESTAMP= の値 (成功時: YYYYMMDDHHMMSS、失敗時: "unknown")
#   - local_save_failed: [CONTEXT] LOCAL_SAVE_FAILED= の値 ("1" または未 emit=空)
pr_number="{pr_number}"
file_timestamp="{file_timestamp_from_p61a}"
local_save_failed="{local_save_failed_from_p61a}"

# pr_number の数値 fail-fast gate (Phase 6.1.a の pr_number guard と対称化)。
# Claude が substitute を忘れると、ケース 1 のローカルファイル path が
# `.rite/review-results/{pr_number}-...json` (literal) となり、ユーザー向けメッセージに placeholder
# がそのまま出力される silent UX regression を防ぐ。file_timestamp / local_save_failed は下記の
# sentinel check で保護される。
#
# reason drift 対策: Phase 6.1.a が pr_number 不正を検出した場合は `LOCAL_SAVE_FAILED=1;
# reason=pr_number_placeholder_residue` を emit して exit 0 (non-blocking) するが、Phase 6.1.c
# は別 bash invocation のため Phase 6.1.a の retained flag を参照できない。pr_number が不正なまま
# Phase 6.1.c まで到達した場合、真因は Phase 6.1.a の Claude substitution 忘れなので、エラー
# メッセージで 6.1.a の再実行を明示的に促す (真因が 6.1.c の bug ではないことを root cause
# 伝達する)。
case "$pr_number" in
  ''|*[!0-9]*)
    echo "ERROR: Phase 6.1.c の pr_number が literal substitute されていません (値: '$pr_number', 期待: 数値のみ非空)" >&2
    echo "  真因: Phase 6.1.a の bash block で Claude が pr_number を literal substitute せず、同じ placeholder が" >&2
    echo "        本 block まで連鎖している可能性が高いです。" >&2
    echo "  対処: Phase 1.0 で正規化された pr_number を Phase 6.1.a の bash block 冒頭で literal substitute" >&2
    echo "        してから再実行してください (Phase 6.1.a が exit 0 non-blocking で完了すると Phase 6.1.c に" >&2
    echo "        substitution 忘れが連鎖します)" >&2
    echo "[CONTEXT] REVIEW_OUTPUT_FAILED=1; reason=p61c_pr_number_invalid; upstream_hint=phase_6_1_a_substitution_missing" >&2
    exit 1
    ;;
esac

# sentinel check: placeholder 残留は silent fallthrough せず fail-fast (H-5 と同パターン)
case "$file_timestamp" in
  "{"*|*"}")
    echo "ERROR: Phase 6.1.c の file_timestamp が literal substitute されていません (値: '$file_timestamp')" >&2
    echo "  Claude は Phase 6.1.a の [CONTEXT] FILE_TIMESTAMP=... を読み取って substitute する必要があります" >&2
    echo "[CONTEXT] REVIEW_OUTPUT_FAILED=1; reason=p61c_file_timestamp_unset" >&2
    exit 1
    ;;
  "unknown")
    # Phase 6.1.a の trap handler は date 失敗時に `[CONTEXT] FILE_TIMESTAMP=unknown` を emit する。
    # その経路では LOCAL_SAVE_FAILED=1 も併設される設計だが、万一片方だけが set された不整合状態
    # (観測値混線 / race) では、ケース 1 に流れると
    # `.rite/review-results/${pr_number}-unknown.json` という実在しないファイルパスをユーザーに
    # 誤提示する UX regression が起きる。整合性違反として明示的に ERROR 化する。
    if [ "$local_save_failed" != "1" ]; then
      echo "ERROR: Phase 6.1.c の file_timestamp='unknown' だが local_save_failed が '1' ではありません (整合性違反)" >&2
      echo "  Phase 6.1.a の trap handler は date 失敗時に FILE_TIMESTAMP=unknown と LOCAL_SAVE_FAILED=1 を同時に emit するはずです" >&2
      echo "  単独 emit 経路は観測値混線 / race の兆候であり、ユーザーに誤ったファイルパスを提示する経路を遮断します" >&2
      echo "[CONTEXT] REVIEW_OUTPUT_FAILED=1; reason=p61c_file_timestamp_unknown_without_failure" >&2
      exit 1
    fi
    # local_save_failed=1 が併設されている場合は legitimate な失敗経路のため、下流のケース 2 分岐
    # (LOCAL_SAVE_FAILED=1 hard fail) に流す。case 文は何もせず pass する。
    ;;
esac
case "$local_save_failed" in
  ""|0|1) ;;
  *)
    echo "ERROR: Phase 6.1.c の local_save_failed が不正 (許容: 空文字 / 0 / 1、値: '$local_save_failed')" >&2
    echo "[CONTEXT] REVIEW_OUTPUT_FAILED=1; reason=p61c_local_save_failed_invalid" >&2
    exit 1
    ;;
esac

# ケース分岐: LOCAL_SAVE_FAILED=1 が set されていればケース 2 (WARNING 昇格 + hard fail)、それ以外はケース 1 (INFO)
if [ "$local_save_failed" = "1" ]; then
  # ケース 2: local save 失敗 (findings が会話コンテキストにのみ存在する異常経路)
  #
  # cycle 10 C-1 対応 (silent data loss 防止): 旧実装は WARNING のみで exit 0 に落ちていたため、
  # ユーザーが WARNING を見落とす / 会話 compaction / terminal close で 30 分のレビューが silent に
  # 消失する単一障害点だった。本 cycle で以下の 2 段階に昇格する:
  #   1. WARNING + 復旧方法 4 種を引き続き表示 (ユーザー可視性の維持)
  #   2. `[CONTEXT] REVIEW_OUTPUT_FAILED=1; reason=p61c_persistence_unrecoverable` を retained flag
  #      として emit し、Phase 6.1 全体を `exit 2` で fail させる (CI / caller が silent pass しない)
  #
  # 「review 成功 = findings が観測可能な場所に届いた」という従来 invariant を復元する。
  # `exit 2` は retained flag mapping table で documented された新しい hard fail 経路。
  cat >&2 <<EOF
⚠️  ERROR: レビュー結果が永続化されませんでした (silent data loss 防止のため Phase 6 を fail させます)
  PR コメント: スキップ (pr_review.post_comment=false)
  ローカルファイル: 保存失敗 ([CONTEXT] LOCAL_SAVE_FAILED の reason を確認してください)

  影響: 本レビュー結果は現在の会話コンテキストのみに存在します。
        次のセッション開始時 (会話 compaction / terminal close / session restart) に完全に失われます。
        この経路を silent pass にしないため、Phase 6 全体を exit 2 で fail させます (cycle 10 C-1 対応)。

  復旧方法 (いずれかを選択):
    1. このセッション内で即座に /rite:pr:fix を実行する (Priority 1: 会話コンテキストから直接読取)
    2. /rite:pr:review --post-comment で PR コメントに投稿して永続化する
    3. rite-config.yml で pr_review.post_comment: true を設定して全 review を永続化する
    4. LOCAL_SAVE_FAILED の reason を解決してから /rite:pr:review を再実行する
EOF
  echo "[CONTEXT] REVIEW_OUTPUT_FAILED=1; reason=p61c_persistence_unrecoverable; local_save_failed=1; post_comment_mode=false" >&2
  echo "[review:error]"
  exit 2
else
  # ケース 1: local save 成功 (通常経路)
  cat >&2 <<EOF
ℹ️  PR コメント記録はスキップされました (pr_review.post_comment=false)
  ローカルファイル: .rite/review-results/${pr_number}-${file_timestamp}.json
  コメント記録を有効化するには --post-comment フラグまたは rite-config.yml で pr_review.post_comment: true を設定してください
EOF
fi
```

**Prose spec (参考)**:

- **ケース 1** (`LOCAL_SAVE_FAILED` 未 emit、通常経路): `ℹ️ PR コメント記録はスキップされました` + ローカルファイル path を表示、`exit 0`
- **ケース 2** (`LOCAL_SAVE_FAILED=1` ∧ `post_comment_mode=false`、findings が会話コンテキストにのみ存在する異常経路): `⚠️ ERROR: レビュー結果が永続化されませんでした` + 復旧方法 4 種を表示、`[CONTEXT] REVIEW_OUTPUT_FAILED=1; reason=p61c_persistence_unrecoverable` を emit、**`exit 2` で Phase 6 を fail させる** (cycle 10 C-1 対応で silent data loss 防止のため hard fail へ昇格)

**`post_comment_mode=false` と `LOCAL_SAVE_FAILED=1` が同時に成立する場合**: 上記 bash block の machine-enforced gate により必ずケース 2 (⚠️ ERROR) が選択され、Phase 6 は `exit 2` で終了する。Claude の自然言語判断には依存しない (silent data loss 防止)。cycle 9 以前は WARNING のみで `exit 0` に落ちていたが、cycle 10 C-1 でユーザー可視性と CI 検出性を両立させるため hard fail に昇格した。

### 6.2 Update Work Memory Phase

> **Reference**: Update work memory per `work-memory-format.md` (at `{plugin_root}/skills/rite-workflow/references/work-memory-format.md`). Update phase to `phase5_review`, detail to `レビュー中`.

**Step 1: Update local work memory (SoT)**

Use the self-resolving wrapper. See [Work Memory Format - Usage in Commands](../../skills/rite-workflow/references/work-memory-format.md#usage-in-commands) for details.

```bash
# hook stderr 退避 + lock/non-lock 分岐パターンを
# fix.md Phase 4.5 (L-5 修正) と対称化。旧 `2>/dev/null || true` は hook の lock contention
# だけでなく permission denied / script 不在 / bash syntax error / 内部致命的エラーまで
# silent suppress していた。stderr を tempfile に退避し失敗時に分岐する。
hook_err=$(mktemp /tmp/rite-review-p62-hook-err-XXXXXX) || hook_err=""
if [ -n "$hook_err" ]; then
  if WM_SOURCE="review" \
      WM_PHASE="phase5_review" \
      WM_PHASE_DETAIL="レビュー中" \
      WM_NEXT_ACTION="レビュー結果に基づき次のアクションを決定" \
      WM_BODY_TEXT="Review cycle completed." \
      WM_ISSUE_NUMBER="{issue_number}" \
      bash {plugin_root}/hooks/local-wm-update.sh 2>"$hook_err"; then
    : # success
  else
    hook_rc=$?
    # 旧 `lock|contention|busy` は permission denied / resource busy (EBUSY) 等も
    # silent suppress していた。lock contention を明示する exact phrase のみにマッチする正規表現に変更。
    # 厳密化: (a) "file is locked" / "lock contention" / "resource busy" の 3 句を exact に match、
    # (b) それ以外の "busy" / "lock" 単独 (permission / directory locked 等) は non-lock failure 経路に流す
    if grep -qiE '(file is locked|lock contention|resource busy)' "$hook_err"; then
      echo "WARNING: local work memory lock contention (best-effort skip, rc=$hook_rc)" >&2
    else
      echo "WARNING: local-wm-update.sh failed (non-lock failure, rc=$hook_rc):" >&2
      head -5 "$hook_err" | sed 's/^/  /' >&2
      echo "  対処: hooks/local-wm-update.sh の存在 / 実行権限 / 内容を確認してください" >&2
    fi
  fi
  rm -f "$hook_err"
else
  # mktemp 失敗時は stderr を 2>&1 経由で stdout 統合し、失敗時に上位 5 行を表示する簡易 fallback
  echo "WARNING: hook_err mktemp 失敗により local-wm-update.sh の stderr 詳細が取得できません" >&2
  if hook_combined=$(WM_SOURCE="review" \
    WM_PHASE="phase5_review" \
    WM_PHASE_DETAIL="レビュー中" \
    WM_NEXT_ACTION="レビュー結果に基づき次のアクションを決定" \
    WM_BODY_TEXT="Review cycle completed." \
    WM_ISSUE_NUMBER="{issue_number}" \
    bash {plugin_root}/hooks/local-wm-update.sh 2>&1); then
    : # success
  else
    hook_fallback_rc=$?
    echo "WARNING: local-wm-update.sh failed (fallback no-tempfile path, rc=$hook_fallback_rc):" >&2
    printf '%s\n' "$hook_combined" | head -5 | sed 's/^/  /' >&2
  fi
fi
```

**On lock failure**: Log a warning and continue — local work memory update is best-effort. **Non-lock failure** (script 不在 / permission / syntax / internal error) は WARNING + stderr 5 行を表示してから継続する (review 全体を block しない)。fix.md Phase 4.5 L-5 修正と対称化済み。

**Step 2: Sync to Issue comment (backup)** at phase transition (per C3 backup sync rule).

```bash
# 上記 Step 1 と同じ L-5 パターンを適用
sync_err=$(mktemp /tmp/rite-review-p62-sync-err-XXXXXX) || sync_err=""
if [ -n "$sync_err" ]; then
  if bash {plugin_root}/hooks/issue-comment-wm-sync.sh update \
      --issue {issue_number} \
      --transform update-phase \
      --phase "phase5_review" --phase-detail "レビュー中" \
      2>"$sync_err"; then
    :
  else
    sync_rc=$?
    # cycle 10 S-1 の exact phrase pattern に統一 (旧 `lock|contention|busy` は
    # permission denied / device busy / resource busy 等を silent suppress する欠陥パターン。
    # canonical helper を common-error-handling.md#hook-lock-contention-classification-canonical で定義)
    if grep -qiE '(file is locked|lock contention|resource busy)' "$sync_err"; then
      echo "WARNING: issue-comment-wm-sync lock contention (best-effort skip, rc=$sync_rc)" >&2
    else
      echo "WARNING: issue-comment-wm-sync failed (non-lock failure, rc=$sync_rc):" >&2
      head -5 "$sync_err" | sed 's/^/  /' >&2
    fi
  fi
  rm -f "$sync_err"
else
  echo "WARNING: sync_err mktemp 失敗により issue-comment-wm-sync.sh の stderr 詳細が取得できません" >&2
  if sync_combined=$(bash {plugin_root}/hooks/issue-comment-wm-sync.sh update \
    --issue {issue_number} \
    --transform update-phase \
    --phase "phase5_review" --phase-detail "レビュー中" \
    2>&1); then
    : # success
  else
    sync_fallback_rc=$?
    echo "WARNING: issue-comment-wm-sync.sh failed (fallback no-tempfile path, rc=$sync_fallback_rc):" >&2
    printf '%s\n' "$sync_combined" | head -5 | sed 's/^/  /' >&2
  fi
fi
```

### 6.3 Review Metrics Recording

> **Reference**: [Execution Metrics - Review Metrics](../../references/execution-metrics.md#review-metrics)

Skip if `metrics.enabled: false` in rite-config.yml. Otherwise, record review metrics from the current review cycle.

**Step 1**: Collect metrics from the Phase 5 review results:

| Item | Source |
|------|--------|
| CRITICAL findings count | Count from integrated report (Phase 5.4) |
| HIGH findings count | Count from integrated report |
| MEDIUM findings count | Count from integrated report |
| LOW findings count | Count from integrated report |

**Step 2**: Record review metrics depending on `{post_comment_mode}`.

The target of metrics recording branches on `{post_comment_mode}` determined in Phase 1.0. This avoids silent metrics loss in the default path (`post_comment_mode=false`).

| Mode | Recording target | Rationale |
|------|------------------|-----------|
| **opt-in** (`post_comment_mode=true`) | Append metrics section to `{review_result_content}` **before** posting the PR comment in Phase 6.1.b. The metrics are included in the same comment as the review results, avoiding a separate API call | 旧実装 (cycle 11 以前) はこの経路を想定した記述のみを持っていた |
| **default** (`post_comment_mode=false`) | Emit metrics as observability log only via `[CONTEXT] REVIEW_METRICS=critical={n};high={n};medium={n};low={n}` to stderr in Phase 6.1.a or 6.1.c | default 経路で metrics の出力先を失わないための明示分岐 (verified-review cycle 12 C-1 対応)。PR コメントには投稿せず、`[CONTEXT]` 経由で caller (`/rite:issue:start` Phase 5.5.2) が読み取れる形式にする |

**⚠️ Default 経路 (`post_comment_mode=false`) で metrics を JSON ファイルに埋め込まない理由**: review-result-schema.md の現行 schema には `metrics` top-level field が存在しない。schema 拡張は別 PR で実施する (本 PR は record target の明示化のみに留め、schema 変更は out-of-scope)。それまでは `[CONTEXT]` stderr emit が唯一の default 経路記録手段となる。

**`post_comment_mode=true` 時の append 実行タイミング**: metrics section は Phase 6.1.b の PR コメント投稿 **前** に `{review_result_content_heredoc_body}` の末尾 (Raw JSON セクション直前) に Claude が literal substitute する。Phase 6.1.a の JSON 本文 (`{review_result_json_heredoc_body}`) には含めない (schema 変更 out-of-scope のため)。

**Note**: This step records raw data only. Threshold evaluation is performed by `/rite:issue:start` Phase 5.5.2 at workflow completion, which reads `[CONTEXT] REVIEW_METRICS=...` from stderr in `post_comment_mode=false` path, or parses the metrics section from the PR comment in `post_comment_mode=true` path.

### 6.4 Update Issue Work Memory

> **Reference**: Update work memory per `work-memory-format.md`. Append review history and update next steps.

**Steps:**

All steps use `issue-comment-wm-sync.sh` for API operations. No direct `gh api` calls are needed — the script handles comment ID retrieval, caching, backup, safety checks, and PATCH internally.

1. **Update session info** (defense-in-depth): Phase 6.2 で local work memory (SoT) を更新済みだが、Issue comment (backup) のセッション情報も冗長に更新する (Issue #90, #93)。

2. **Append review history**: Add review result summary to the work memory body.

3. **Update next steps**: Set the next command based on the review assessment.

```bash
# Phase 6.4 全 hook 呼び出しに L-5 stderr 退避 + lock/non-lock
# 分岐パターンを適用 (fix.md Phase 4.5 と対称化)。
# helper function として定義し、3 step に統一適用する (drift 防止)。
_rite_review_p64_run_sync() {
  local label="$1"
  shift
  local err_file
  err_file=$(mktemp /tmp/rite-review-p64-sync-err-XXXXXX) || err_file=""
  if [ -n "$err_file" ]; then
    if "$@" 2>"$err_file"; then
      :
    else
      local rc=$?
      # cycle 10 S-1 の exact phrase pattern に統一 (canonical helper を
      # common-error-handling.md#hook-lock-contention-classification-canonical で定義)
      if grep -qiE '(file is locked|lock contention|resource busy)' "$err_file"; then
        echo "WARNING: ${label} lock contention (best-effort skip, rc=$rc)" >&2
      else
        echo "WARNING: ${label} failed (non-lock failure, rc=$rc):" >&2
        head -5 "$err_file" | sed 's/^/  /' >&2
      fi
    fi
    rm -f "$err_file"
  else
    # verified-review cycle 15 F-7 対応: mktemp 失敗時の `2>/dev/null || true` anti-pattern を修正。
    # Phase 6.2 / fix.md Phase 5 と同じ `2>&1` + `head -5` display fallback に統一する。
    # 旧実装は permission denied / script not found / bash syntax error も silent suppress していた。
    if hook_combined=$("$@" 2>&1); then
      :
    else
      local fallback_rc=$?
      echo "WARNING: ${label} failed (mktemp-unavailable fallback path, rc=$fallback_rc):" >&2
      printf '%s\n' "$hook_combined" | head -5 | sed 's/^/  /' >&2
    fi
  fi
}

# Step 1: セッション情報更新（defense-in-depth）
_rite_review_p64_run_sync "p64 update-phase" \
  bash {plugin_root}/hooks/issue-comment-wm-sync.sh update \
    --issue {issue_number} \
    --transform update-phase \
    --phase "phase5_review" --phase-detail "レビュー中"

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
- `{review_history_content}`: Review result summary (assessment, finding counts, commit SHA). Claude generates from Phase 5 results.
- `{next_step_content}`: Next command based on assessment. Merge OK → `/rite:pr:ready` | Requires fixes → `/rite:pr:fix`

**Consistency guarantee (Issue #90)**: Steps 1-3 collectively ensure that the Issue comment (backup) is consistent with the local work memory (SoT) updated in Phase 6.2. This is a **defense-in-depth** design: if either path silently fails, the other guarantees at least one source has correct state for recovery.

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

> **Reference**: [Wiki Ingest](../wiki/ingest.md) — `wiki-ingest-trigger.sh` API

After outputting the completion report, trigger Wiki Ingest to capture review finding patterns as experiential knowledge.

**Condition**: Execute only when `wiki.enabled: true` AND `wiki.auto_ingest: true` in `rite-config.yml`. Skip silently otherwise.

**Step 1**: Check Wiki configuration (same pattern as Phase 4.0.W Step 1, replacing `auto_query` with `auto_ingest`):

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

If `wiki_enabled=false` or `auto_ingest=false`, skip this section.

**Step 2**: Generate a review Raw Source from the review results:

The review content includes: PR number, reviewer types, finding categories, severity distribution, and key patterns detected.

```bash
# {plugin_root} はリテラル値で埋め込む
tmpfile=$(mktemp)
trap 'rm -f "$tmpfile"' EXIT

cat <<'REVIEW_EOF' > "$tmpfile"
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

bash {plugin_root}/hooks/wiki-ingest-trigger.sh \
  --type reviews \
  --source-ref "pr-{pr_number}" \
  --content-file "$tmpfile" \
  --pr-number {pr_number} \
  --title "PR #{pr_number} review results" \
  2>/dev/null || true
```

**Non-blocking**: `wiki-ingest-trigger.sh` exit 2 (Wiki disabled/uninitialized) and other errors are silenced by `|| true`. Ingest failure does not block the review workflow.

#### 6.5.1 Next Step Branching by Invocation Source

The behavior after the completion report varies by invocation source.

**Invocation source determination method:**

Claude determines the invocation source from the conversation context:

| Condition | Determination |
|------|---------|
| Conversation history has a record of `rite:pr:review` being invoked via the `Skill` tool | Within loop -> Automatically execute the next step |
| Otherwise (user directly entered `/rite:pr:review`) | Standalone execution -> Confirm the next action with `AskUserQuestion` |

**Note**: This adopts the same conversation context method as `commands/lint.md` and `commands/pr/fix.md`.

---

**When invoked from within the `/rite:issue:start` loop:**

**Step 1: Process recommendation-based Issue candidates (Phase 7)**

Before outputting the result pattern, execute Phase 7.1-7.4 to process recommendation-based Issue candidates:
- Extract candidates per Phase 7.1 (Source A scope-irrelevant findings and Source B recommendations — Source A findings not flagged as scope-irrelevant are handled by the fix loop)
- If candidates exist: **always** invoke `AskUserQuestion` per Phase 7.2-7.3 (E2E no longer skips user confirmation — user must approve each candidate)
- If no candidates: skip silently

**Condition**: Execute only when the review result is `[review:mergeable]`. When `[review:fix-needed:N]`, skip Phase 7 (the fix loop will continue; Phase 7 will run on the eventual mergeable review to avoid duplicate Issue creation).

**Step 2: Output the result pattern**

| Overall Assessment | Output Pattern |
|---------|------------------------|
| **Merge OK** (0 findings) | `[review:mergeable]` |
| **Requires fixes** (findings > 0) | `[review:fix-needed:{total_findings}]` |

**Note**: Within the loop, `/rite:pr:review` only outputs results via patterns. Subsequent processing (invoking `/rite:pr:fix`, confirming `/rite:pr:ready` execution, etc.) is determined and executed by `/rite:issue:start` Phase 5.4.

---

**When `/rite:pr:review` is executed standalone:**

Confirm the next action with `AskUserQuestion`. See Phase 1.4 for the AskUserQuestion invocation format.

**Merge OK**: Options: Ready for review (推奨) → invoke `rite:pr:ready` | Keep draft | Additional fixes → terminate

**Cannot merge/Requires fixes**: Options: Handle findings (推奨) → invoke `rite:pr:fix` | Handle later → proceed to Phase 7

**⚠️ Important**: Always use `AskUserQuestion` for standalone execution. Proceed to Phase 7 after completion.

---

## Phase 7: Automatic Issue Creation

### 7.1 Extract Separate Issue Candidates

Extract candidates from **two sources**:

**Source A — Findings (指摘事項)**: Extract findings meeting: Severity MEDIUM+ AND contains keywords (`スコープ外`, `別 Issue`, `out of scope`, `separate issue`, etc.)

**Source B — Recommendations (推奨事項)**: Extract items from the "推奨事項" section of the integrated report (Phase 5.4) where the "別 Issue 候補" column is ✅. No severity filter is applied (recommendations lack severity).

> **Note on pre-existing issues**: Pre-existing issues (problems that existed before this PR's diff) are NOT collected as Phase 7 Issue candidates. The reviewer's scope judgment rule excludes them from findings entirely. If a reviewer noted them in the "調査推奨" section of the integrated report (Phase 5), the user may optionally run `/rite:investigate {file}` separately — this is not auto-Issue-ified.

Deduplicate across sources: if the same file:line appears in both Source A and Source B, keep only the Source A entry (it has richer metadata).

### 7.2-7.3 User Confirmation

If 0 candidates: Skip Phase 7. If 1+: **Always** confirm with `AskUserQuestion` — this confirmation is mandatory in both standalone and E2E flow. User must explicitly approve each candidate.

**AskUserQuestion prompt text**:

```
以下は PR #{N} の diff とは無関係と reviewer が判定した問題です。各候補について対応方針を選んでください: [別 Issue 作成 / 本 PR で対応 / 無視]
```

**Candidate display format:**

| # | Source | ファイル | 内容 | 重要度 | Priority |
|---|--------|---------|------|--------|----------|
| 1 | 指摘 | {file:line} | {content} | {severity} | {mapped_priority} |
| 2 | 推奨 | {file:line or "—"} | {content} | — | Medium |

**Default values for recommendation-based candidates** (Source B):
- **Priority**: `Medium`
- **Complexity**: `S`
- **Severity in Issue body**: `推奨事項（重要度なし）`
- **File:line**: Use mentioned path if available; otherwise `特定ファイルなし`

**E2E flow behavior**: Same as standalone — **always** present `AskUserQuestion` and wait for explicit user approval per candidate. Do NOT auto-create Issues without user confirmation, even in E2E. Previous behavior (auto-create under E2E) has been removed to enforce user control over scope-irrelevant Issue creation.

### 7.4 Issue Creation

Create Issues directly using `gh issue create` and register them in GitHub Projects. Do **not** use the `/rite:issue:create` Skill tool (it triggers interactive prompts that disrupt the flow).

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

**Priority mapping**: CRITICAL→High, HIGH→Medium, MEDIUM→Low, Recommendation (Source B)→Medium

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

result=$(bash {plugin_root}/scripts/create-issue-with-projects.sh "$(jq -n \
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
  }'
)")

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

### 7.5-7.6 Append to PR & Report

Post Issue list to PR comment (`mktemp` + `--body-file`). Output completion report.

---

## Workflow Incident Emit Helper (#366)

> **Reference**: See [workflow-incident-emit-protocol.md](../../references/workflow-incident-emit-protocol.md) for the emit protocol and Sentinel Visibility Rule.

This skill emits sentinels for the following failure paths:

| Failure Path | Sentinel Type | Details |
|--------------|---------------|---------|
| Reviewer sub-agent skill load failure (fallback to built-in profile in Phase 2) | `skill_load_failure` | `rite reviewer skill load failure: {reviewer_type}` |
| Comment post failure in Phase 6 (gh api PATCH/POST returns error) | `hook_abnormal_exit` | `rite:pr:review comment post failure` |
| Review execution error that user chose to skip | `manual_fallback_adopted` | `rite:pr:review execution error skipped by user` |

## Error Handling

| Error | Action |
|--------|------|
| PR not found | Check with `gh pr list` and re-run with the correct number |
| Skill file load failure | Fallback using built-in profiles (sentinel emit via Workflow Incident Emit Helper above) |
| Review execution error | Choose skip/retry/cancel (sentinel emit on skip via Workflow Incident Emit Helper above) |
| Comment post failure | Display review results as text (sentinel emit via Workflow Incident Emit Helper above) |

---

## Configuration File Reference

Reference the following settings from `rite-config.yml`:

```yaml
review:
  min_reviewers: 1      # 最小レビュアー数（フォールバック用）
  criteria:
    - file_types        # ファイル種類による判断
    - content_analysis  # 内容解析による判断
  security_reviewer:
    mandatory: false                       # 全 PR で必須選定するか
    recommended_for_code_changes: true     # 実行可能コード変更時は推奨

commands:
  lint: null   # 品質チェック用
  build: null  # 品質チェック用
```
## Phase 8: End-to-End Flow Continuation (Output Pattern)

> **This phase is executed only within the end-to-end flow. Skip for standalone execution.**

### 8.0 Defense-in-Depth: State Update Before Output (End-to-End Flow)

Before outputting any result pattern (`[review:mergeable]`, `[review:fix-needed:{n}]`), update `.rite-flow-state` to reflect the post-review phase (defense-in-depth, fixes #719). This prevents intermittent flow interruptions when the fork context returns to the caller — even if the LLM churns after fork return and the system forcibly terminates the turn (bypassing the Stop hook), the state file will already contain the correct `next_action` for resumption.

**Condition**: Execute only when `.rite-flow-state` exists (indicating e2e flow). Skip if the file does not exist (standalone execution).

**State update by result**:

| Result | Phase | Next Action |
|--------|-------|-------------|
| `[review:mergeable]` | `phase5_post_review` | `rite:pr:review completed. Result: [review:mergeable]. Proceed to Phase 5.5 (Ready for Review). Do NOT stop.` |
| `[review:fix-needed:{n}]` | `phase5_post_review` | `rite:pr:review completed. Result: [review:fix-needed:{n}]. Proceed to Phase 5.4.4 (fix). Do NOT stop.` |

```bash
bash {plugin_root}/hooks/flow-state-update.sh patch \
  --phase "phase5_post_review" \
  --next "{next_action_value}" \
  --if-exists
```

Replace `{next_action_value}` with the value from the table above based on the review result. Also replace `{n}` in the next_action string with the actual finding count from the review result (e.g., if the result is `[review:fix-needed:3]`, then `{n}` = `3`).

**Note on `error_count`**: `flow-state-update.sh` patch mode preserves all existing fields not explicitly set — only `phase`, `updated_at`, and `next_action` are changed (consistent with `lint.md` Phase 4.0 and `fix.md` Phase 8.1). The count is effectively reset when `/rite:issue:start` writes a new complete object via `jq -n` at the next phase transition.

### 8.1 Output Pattern (Return Control to Caller)

Based on the Phase 6 review results, output the corresponding machine-readable pattern:

| Condition | Output Pattern |
|-----------|---------------|
| 0 findings | `[review:mergeable]` |
| 1 or more findings | `[review:fix-needed:{total_findings}]` |

**Fact-check suffix**: When fact-check was executed (external claims > 0), append the fact-check summary to the E2E output line: `| fact-check: {v}✅ {c}❌ {u}⚠️`. `{total_findings}` is the post-fact-check count (CONTRADICTED and UNVERIFIED:ソース未確認 excluded). See [E2E Output Minimization](#e2e-output-minimization) for the full format.

**Important**:
- **[READ-ONLY RULE]**: `Edit`/`Write` ツールでプロジェクトのソースファイルを修正してはなりません。`Bash` で working tree / index / ref を変更する git コマンド（`git checkout` / `git reset` / `git add` / `git stash` / `git restore` / `git rebase` / `git commit` / `git push` 等）も **禁止** です。許可される read-only git コマンドの完全一覧は `plugins/rite/agents/_reviewer-base.md` の `## READ-ONLY Enforcement` を single source of truth として参照してください。指摘がある場合は `[review:fix-needed:{n}]` を出力し、修正は `/rite:pr:fix` に委譲してください
- Do **NOT** invoke `rite:pr:fix` or `rite:pr:ready` via the Skill tool
- Return control to the caller (`/rite:issue:start`)
- The caller determines the next action based on this output pattern
- The prohibited actions defined in Phase 5.3.7 "Prohibition of Independent Judgment After Assessment" also apply here

**When assessed as "Merge OK" but findings > 0:**
-> Correct to `[review:fix-needed:{total_findings}]`

**Example output:**
```
📜 rite レビュー結果

総合評価: マージ可
指摘: 0件

[review:mergeable]
```

### 8.2 Standalone Execution Behavior

For standalone execution, Phase 8 is not executed. Terminate by confirming the next action with the user via `AskUserQuestion` in Phase 6.5.
