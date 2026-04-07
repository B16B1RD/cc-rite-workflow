---
description: マルチレビュアー PR レビューを実行
context: fork
---

# /rite:pr:review

## Contract
**Input**: PR number (or auto-detected from current branch), `.rite-flow-state` with `phase: phase5_review` (e2e flow)
**Output**: `[review:mergeable]` | `[review:fix-needed:{n}]`

Analyze PR changes and dynamically load expert skills to perform a multi-reviewer review.

> **[READ-ONLY RULE]**: このコマンドはレビュー専用です。`Edit`/`Write` ツールでプロジェクトのソースファイルを修正してはなりません。コードの問題を検出した場合は、`[review:fix-needed:{n}]` パターンを出力し、修正は `/rite:pr:fix` に委譲してください。`Bash` ツールは workflow 操作（`gh` CLI、hook scripts、`.rite-flow-state` 更新）のみ許可されます。

## E2E Output Minimization

When called from the `/rite:issue:start` end-to-end flow, Phase 4 (sub-agent execution) runs in **full** — only Phase 5-7 **output** is minimized to reduce context window consumption:

| Phase | Standalone | E2E Flow |
|-------|-----------|----------|
| Phase 4 (Sub-Agent Execution) | Full execution | **Full execution** — sub-agents MUST run in parallel for every review cycle (including verification mode). No shortcut allowed. |
| Phase 5 (Consolidation) | Full findings table | Result pattern + summary counts only |
| Phase 6 (PR Comment) | Full comment + display | Post comment silently, output pattern only |
| Phase 7 (Issue Creation) | Full report + guidance | **Recommendations + pre-existing issues** — auto-create Issues for 推奨事項 with 別 Issue keywords and 既存問題 (if any). Skip user confirmation. Only when `[review:mergeable]`. |

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
- Other `{variable}` formats: Values obtained from command execution results or previous phases

**Note**: All placeholders in this document use `{variable}` format. Unlike Bash shell variable format `${var}`, these are conceptual markers that Claude substitutes with values.

### 1.1 Identify the PR

**PR number retrieval (priority order):**

| Priority | Retrieval Method | Description |
|-------|---------|------|
| 1 | From argument | When explicitly specified |
| 2 | **From work memory** | The "番号" field in the "Related PR" section |
| 3 | Search for PR on the current branch | Fallback |

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

Record the current commit SHA at the start of the review. This SHA is embedded in the review result comment in Phase 6.1 and used in the verification mode of the next cycle.

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

**Skip conditions** (any match → **explicit set `{doc_heavy_pr} = false`** and skip to Phase 1.3):

- `review.doc_heavy.enabled: false` in `rite-config.yml`
- `changedFiles == 0` (edge case: empty diff)

> **Note**: "retain" ではなく "explicit set" とする。これにより `{doc_heavy_pr}` が Phase 2.2.1 到達時点で必ず boolean として set されていることが保証される (undefined 参照防止)。

**Configuration**: Read `review.doc_heavy` from `rite-config.yml` with the following defaults when the key is absent:

| Key | Default | Description |
|-----|---------|-------------|
| `enabled` | `true` | この Phase の有効/無効 |
| `lines_ratio_threshold` | `0.6` | `doc_lines / total_diff_lines` の閾値 (行数比率) |
| `count_ratio_threshold` | `0.7` | `doc_files / total_files` の閾値 (ファイル数比率) |
| `max_diff_lines_for_count` | `2000` | ファイル数比率判定を有効にする最大 diff 行数 |

**Calculation**:

Use the `files` array from Phase 1.2.6 (specifically the `additions` and `deletions` fields per file, already retrieved in Phase 1.1). This calculation does **not** depend on `git diff --numstat`; numstat failure in Phase 1.2.6 does not affect Doc-Heavy detection accuracy because the equivalent data is available from the `files` array.

```
# Doc file patterns — single source of truth, kept in sync with tech-writer.md Activation.
# 両ファイルが同一の集合を「ドキュメント」として扱うことを保証する。
# 等価性の具体: 両者ともに以下を含む — .md (rite plugin の commands/skills/agents 除外),
# .mdx (同除外), docs/**, documentation/**, **/README*, CHANGELOG*, CONTRIBUTING*,
# i18n/**/*.{md,mdx} (plugins/rite/i18n/** 除外), .rst, .adoc
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
# 重要: 全ての early-exit 経路で {doc_heavy_pr} = false を必ず set する
if total_diff_lines == 0:
    doc_heavy_pr = false   # explicit set (silent undefined 防止)
    skip to Phase 1.3      # Phase 1.2.7 の残り計算をスキップ

if total_files_count == 0:
    doc_heavy_pr = false   # explicit set (Defensive guard)
    skip to Phase 1.3      # skip condition (changedFiles == 0) で本来到達しない

# 命名上の注意:
# - doc_lines_ratio は「ドキュメント行数 / 全体 diff 行数」の比率 (行数ベース)
# - doc_files_count_ratio は「ドキュメントファイル数 / 全体ファイル数」の比率 (ファイル数ベース)
# config キー名は意味と一致している (lines_ratio_threshold / count_ratio_threshold)
doc_lines_ratio       = doc_lines / total_diff_lines
doc_files_count_ratio = doc_files_count / total_files_count
```

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
```

Retain `{doc_heavy_pr}` (boolean) in the conversation context for use in Phase 2.2.1.

**Note**: ゼロ除算ガード (`total_diff_lines == 0` および `total_files_count == 0`) は疑似コードブロック内にインラインで配置済みで、両方とも `doc_heavy_pr = false` を **explicit set** してから `skip to Phase 1.3` する。Skip conditions section の `changedFiles == 0` と併せて、空 PR・分母 0・undefined 参照の三方向を防ぐ多重ガードとなる。Phase 2.2.1 で `{doc_heavy_pr} == true` を判定する時点で `{doc_heavy_pr}` が必ず boolean として set されていることが保証される。

### 1.3 Identify Related Issue

Extract the Issue number from the PR branch name or body.

**Extraction priority order:**
1. Search for `Closes #XX`, `Fixes #XX`, `Resolves #XX` patterns in the **PR body** (preferred)
2. If not found in the PR body, search for the `issue-{number}` pattern in the **branch name**

**Extraction method:**
1. Search for `Closes/Fixes/Resolves #XX` (case-insensitive) in the PR body. If multiple matches, use only the first one
2. Fallback: Extract `issue-(\d+)` from the branch name

Retain the Issue number in the conversation context for use in Phase 6.2.

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

1. **tech-writer 必須昇格**: Phase 2.2 で tech-writer が候補に含まれている場合、その selection_type を `recommended → mandatory` に昇格する。含まれていない場合は mandatory として新規追加する
   - **到達可能性 note**: doc_heavy_pr = true でかつ tech-writer が候補にないケースは、tech-writer.md Activation と review.md `doc_file_patterns` の集合等価性が保たれている限り発生しない。しかし将来両者が drift する可能性に備え、新規追加経路を残す (防御的フォールバック)
   - **TODO(#353)**: 両ファイルの Activation patterns 等価性を CI/lint で自動検証する test は未整備。drift 検出 lint の追加は Issue #353 で追跡中 (発端は PR #350 の verified-review で検出された SKILL.md drift 実例)
2. **code-quality co-reviewer 追加**: doc-heavy PR でも `commands/`, `skills/`, `agents/` 以外の `.md` 内に bash/yaml/code blocks が含まれることがあり、これらを構造的に検証するため code-quality を co-reviewer として追加する。具体的な検証期待:
   - ドキュメント内 fenced code block (` ```bash `, ` ```yaml `, ` ```python ` 等) の構文・引用・エラーハンドリング
   - ドキュメントの「実装例」コードが既存の coding style / naming convention と整合しているか
   - サンプル設定ファイル (yaml/toml/json snippets) のキー名・型・必須項目が実装スキーマと一致しているか
   
   既に候補に含まれている場合は selection_type を `mandatory` に引き上げる（昇格パスは Phase 3.2 selection_type と同じ語彙: `detected → recommended → mandatory`）
3. **doc-heavy mode 指示の reviewer prompt 注入**: tech-writer のレビュー実行時に Phase 4.5 の prompt template に以下を注入する:
   - `{doc_heavy_pr}` placeholder に `true` を set
   - `{doc_heavy_mode_instructions}` placeholder に `tech-writer.md` の `## Doc-Heavy PR Mode (Conditional)` セクション全体 (Activation 行から "Cross-Reference with internal-consistency.md" セクション末尾まで) を埋め込む
   
   これにより `internal-consistency.md` の 5 カテゴリ verification protocol が reviewer に直接伝達され、各 finding に `- Evidence: tool=<Grep|Read|Glob|WebFetch>, path=<...>, line=<...>` 行を必須化する仕様が reviewer 側で有効になる (Phase 5.1.3 で post-condition check)

**Relationship to Phase 2.3 sole reviewer guard**:

本 Override は Phase 2.3 (Content Analysis) および sole reviewer guard の**前**に実行される。本 Override 実行後は tech-writer (mandatory) + code-quality (co-reviewer) の >=2 reviewers が確定しているため、sole reviewer guard は発火しない (Phase 2.3 の既存ロジックはそのまま動作する)。

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
| `mandatory` | `mandatory: true` in config | No (backward compatible) |
| `recommended` | Selected via file pattern match or `recommended_for_code_changes` | Yes (with warning) |
| `detected` | Selected via keyword detection in Phase 2.3 | Yes (with warning) |

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
| `mandatory` | `[必須]` | `mandatory: true` in config; cannot be removed |
| `recommended` | `[推奨]` | Selected via file pattern match or `recommended_for_code_changes`; can be removed with warning |
| `detected` | `[検出]` | Selected via keyword detection in Phase 2.3; can be removed with warning |
| (other reviewers) | (empty) | Normal selection; can be removed freely |

**Behavior when "Reduce reviewers" is selected:**

The behavior depends on the Security Expert's selection type:

| Selection Type | Removable | Behavior |
|---------------|-----------|----------|
| `mandatory` | **No** | Display a warning that Security Expert cannot be removed, and present options to reduce only other reviewers |
| `recommended` | **Yes** (with warning) | Display a warning recommending against removal, then allow removal if the user confirms |
| `detected` | **Yes** (with warning) | Display a warning recommending against removal, then allow removal if the user confirms |

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

> **Plugin Path**: Resolve `{plugin_root}` per [Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script) before reading plugin files.

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

3. **Extract `{agent_identity}`**: Construct the agent identity from two sources:

   **Part A — Shared reviewer principles** (from `_reviewer-base.md`):
   - Load `{plugin_root}/agents/_reviewer-base.md` with the Read tool
   - Extract the `## Reviewer Mindset` and `## Confidence Scoring` sections (everything between these headings and the next `##` heading or `## Input` section)
   - These sections define the universal principles all reviewers must follow

   **Part B — Agent-specific identity** (from the agent file):
   - From the loaded agent file, extract the body content **excluding**:
     - YAML frontmatter (between `---` delimiters)
     - `## Detailed Checklist` section and everything after it
     - `## Output Format` section and everything after it
     - `**Output example:**` line and everything after it (handles old-style agent files without `##` section markers)

   **Combine**: `{agent_identity}` = Part A (shared principles) + Part B (agent-specific identity)

   The combined content provides the agent with both universal reviewer discipline (Mindset, Confidence Scoring framework) and domain-specific guidance (Identity, Core Principles, Detection Process, Confidence Calibration).

   **Fallback**: If extraction fails or yields empty content for either part, use whatever was successfully extracted. If both fail, set `{agent_identity}` to an empty string. The review will still function using `{skill_profile}` and `{checklist}`.

**Parallel execution using the Task tool:**

Achieve parallel execution by **invoking multiple Task tools in a single message** for all selected sub-agents.

Pass the following information to each sub-agent:
- PR diff (or related file diffs - see reference below)
- Changed file list
- Related Issue specification (obtained in Phase 1.3.1)
- Sub-agent definition (contents of agents/*.md)
- Agent identity (`{agent_identity}` extracted above)

> **Diff optimization**: Apply scale-based diff passing per [Review Context Optimization](./references/review-context-optimization.md#diff-passing-optimization). Small scale: full diff. Medium/Large scale: related file diffs only + change summary for large diffs.

**Error handling:**

If the following issues occur with the sub-agent approach:
- All sub-agent definition files cannot be loaded -> Display error message and terminate
- Some Task tool calls fail -> Integrate only successful review results

**See "Task Tool Sub-Agent Invocation" below for details on the sub-agent approach.**

---

### 4.3.1 Task Tool Sub-Agent Invocation

**Parallel execution:** Invoke multiple Task tools within a single message for all selected reviewers. Each Task uses:
- `description`: "セキュリティ専門家 PR レビュー" (short description)
- `subagent_type`: `general-purpose` (access to all tools)
- `prompt`:
  - `review_mode == "full"`: Phase 4.5 format (diff, spec, skill profile, checklist)
  - `review_mode == "verification"`: Phase 4.5.1 verification template + Phase 4.5 full template, concatenated in a single prompt. Include previous findings table and incremental diff (from Phase 1.2.4) in addition to the standard inputs.

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

**Error type determination method:**

Determine the error type from the Task tool result. Claude analyzes the Task tool response content and determines the type by the following patterns:

| Error Type | Detection Pattern |
|-----------|-------------|
| Timeout | Response contains keywords like "timeout", "timed out", "exceeded" |
| Network error | Response contains "network", "connection", "ECONNREFUSED", "unreachable", etc. |
| Invalid output format | Does not match the above and does not contain expected output format (e.g., `### 評価:` section) |
| Skill file load failure | Read tool returned an error (occurs before Task execution) |

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

**Mandatory fix policy:** All reported findings will be treated as mandatory fixes. The review-fix loop continues until 0 findings remain. Reviewers must therefore exercise careful judgment — report only substantive issues that genuinely improve quality. Avoid nitpicking, trivial style preferences, or hypothetical concerns without concrete evidence.

**Thoroughness on every cycle:** Apply the same depth and rigor on every review cycle — first pass, re-review, or verification. Do not self-censor findings because "I should have caught this earlier." If you see a real problem now, report it now. Withholding a valid finding to avoid appearing inconsistent is worse than reporting it late.

**Scope judgment rule:** Only flag issues **introduced by this PR's diff** as findings (指摘事項). Apply the revert test: "If this PR were reverted, would the problem disappear?" If No, it is a pre-existing issue — do not report it in the findings table. Instead, if the pre-existing issue is CRITICAL or HIGH severity, report it in the "既存問題（PR 対象ファイル）" section for visibility and automatic Issue creation. Pre-existing code smells, tech debt, or style inconsistencies below HIGH severity are out of scope entirely.

**Placeholder embedding method:**

| Placeholder | Source | Extraction Method |
|---------------|--------|----------|
| `{relevant_files}` | Changed file list from Phase 1.2 | Extract only files matching the reviewer's Activation pattern |
| `{diff_content}` | Diff from Phase 1.2 | **Varies by scale** (see below) |
| `{skill_profile}` | Role + Expertise Areas section of skill file | Extract the relevant section from the skill file loaded via Read |
| `{checklist}` | Review Checklist section of skill file | Full text including Critical / Important / Recommendations |
| `{issue_spec}` | Issue specification obtained in Phase 1.3.1 | Content of the "仕様詳細" section (if empty, write "仕様情報なし") |
| `{change_intelligence_summary}` | Change Intelligence Summary from Phase 1.2.6 | One-paragraph summary of change type, file classification, and focus area |
| `{agent_identity}` | `_reviewer-base.md` (shared) + `agents/{type}-reviewer.md` (specific) | **Part A**: Extract `## Reviewer Mindset` + `## Confidence Scoring` from `_reviewer-base.md`. **Part B**: Extract agent file body excluding YAML frontmatter, `## Detailed Checklist`, `## Output Format`, and `**Output example:**` sections. Combine: Part A + Part B |
| `{change_summary}` | Scale information from Phase 1.2.1 | Used only for large diffs. Change summary table |
| `{doc_heavy_pr}` | Phase 1.2.7 result | Boolean flag (`true` / `false`). Inject only when reviewer is `tech-writer`. If `false` or reviewer != tech-writer, set to empty string |
| `{doc_heavy_mode_instructions}` | `skills/reviewers/tech-writer.md` `## Doc-Heavy PR Mode (Conditional)` section | **Conditional extraction**: Only populated when `reviewer_type == tech-writer` AND `{doc_heavy_pr} == true`. Extract the entire section from `## Doc-Heavy PR Mode (Conditional)` heading down to (but excluding) the next `##` heading. Otherwise set to empty string |

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

## あなたのアイデンティティと検出プロセス
{agent_identity}

## あなたの役割
{skill_profile}

## チェックリスト
{checklist}

## Doc-Heavy PR Mode (Conditional — 適用時のみ非空)
<!-- reviewer_type == tech-writer かつ doc_heavy_pr == true のときのみ内容が入る。それ以外は空文字列。 -->
{doc_heavy_mode_instructions}

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

**重要**: 指摘事項テーブルに記載する項目は全て**必須修正**として扱われます。「任意」「推奨」「必須ではないが」といった修正は指摘事項に含めず、下の「推奨事項」セクションに記載してください。指摘の判断基準: **この問題を修正しなければマージすべきでないと確信できるか？** Yes の場合のみ指摘事項に記載してください。

| 重要度 | ファイル:行 | 内容 | 推奨対応 |
|--------|------------|------|----------|
| {CRITICAL/HIGH/MEDIUM/LOW} | {file:line} | {WHAT: 何が問題か} + {WHY: なぜ問題か（影響・リスク・既存パターンとの比較）} | {FIX: 修正方法} + {EXAMPLE: コード例（該当時）} |

### 推奨事項
[改善提案があれば（任意の改善、スタイル提案、別 Issue 推奨の既存問題など）。各推奨事項を箇条書きで記載すること。別 Issue での対応を推奨する場合は `別 Issue` または `スコープ外` キーワードを含めること（Phase 7 の自動 Issue 化で検出対象となる）]

### 既存問題（PR 対象ファイル）
[PR 対象ファイルに存在する CRITICAL/HIGH レベルの既存問題（今回の変更で導入されたものではなく、変更前から存在していた問題）を検出した場合にここに記載する。検出方法: revert test（当該行を変更前の状態に戻しても問題が存在するか確認）で「変更前から存在」と判定された問題のみ。既存問題は指摘事項テーブルに含めず、このセクションに分離して記載すること。`別 Issue` キーワードを含めて Issue 化を促すこと。該当なしの場合はこのセクション自体を省略]

| 重要度 | ファイル:行 | 内容 | 推奨対応 |
|--------|------------|------|----------|
| {CRITICAL/HIGH} | {file:line} | {WHAT + WHY — 既存問題である根拠を含む} | 別 Issue で対応推奨: {具体的な修正方法} |

## 制約
[READ-ONLY RULE] このレビューは読み取り専用です。`Edit`/`Write` ツールでプロジェクトのソースファイルを修正してはなりません。問題を検出した場合は指摘事項として報告してください。修正は別プロセス（`/rite:pr:fix`）が担当します。`Bash` ツールは workflow 操作（`gh` CLI、hook scripts）のみ許可されます。
```

**When `{issue_spec}` is empty:** Write "仕様情報なし" and omit spec-based checks ("仕様との整合性" and "仕様への疑問" sections).

### 4.5.1 Verification Mode Review Instruction Template

When `review_mode == "verification"` (determined in Phase 1.2.4), use the following template **in addition to** the normal template from Phase 4.5. Both verification results and full review results are consolidated in the final assessment.

**Template selection logic:**

| review_mode | Template Used |
|-------------|-------------------|
| `full` | Normal template from Phase 4.5 only |
| `verification` | Both: this section's (4.5.1) verification template AND the normal template from Phase 4.5 |

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

## あなたのアイデンティティと検出プロセス
{agent_identity}

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
[READ-ONLY RULE] このレビューは読み取り専用です。`Edit`/`Write` ツールでプロジェクトのソースファイルを修正してはなりません。問題を検出した場合は指摘事項として報告してください。修正は別プロセス（`/rite:pr:fix`）が担当します。`Bash` ツールは workflow 操作（`gh` CLI、hook scripts）のみ許可されます。
```

**Placeholder embedding method:**

| Placeholder | Source | Extraction Method |
|---------------|--------|----------|
| `{previous_findings_table}` | Previous review finding table obtained in Phase 1.2.4 | Integrate finding tables from each reviewer in the "全指摘事項" section from the previous `📜 rite レビュー結果` comment |
| `{incremental_diff}` | `git diff {last_reviewed_commit}..HEAD` obtained in Phase 1.2.4 | Full incremental diff (however, for large scale, only files relevant to the reviewer) |
| `{change_intelligence_summary}` | Change Intelligence Summary from Phase 1.2.6 | One-paragraph summary of change type, file classification, and focus area |

---

## Phase 5: Critic Phase (Result Verification and Integration)

> **[READ-ONLY RULE]**: Critic Phase はレビュー結果の統合・評価のみを行います。`Edit`/`Write` ツールでプロジェクトのソースファイルを修正してはなりません。ブロック指摘が存在する場合は `[review:fix-needed:{n}]` を出力し、修正は `/rite:pr:fix` に委譲してください。`Bash` ツールは workflow 操作（`gh` CLI、hook scripts、`.rite-flow-state` 更新）のみ許可されます。

### 5.1 Result Collection

**⚠️ Scope**: Collect only newly detected findings from current review. Fixed code (not in diff) is auto-excluded; unaddressed findings are re-detected.

Task results are retained in conversation context with internal format (reviewer_type, assessment, findings: severity/file_line/description/recommendation).

**Recommendation collection for Issue candidates**: In addition to findings, also extract items from each reviewer's "### 推奨事項" section that contain any of the following keywords: `別 Issue`, `別Issueで対応`, `スコープ外`, `out of scope`, `separate issue`. Retain these as `recommendation_issue_candidates` in the conversation context (reviewer_type, content, file_line if mentioned). These are NOT findings — they do not affect the assessment, finding counts, or merge decision. They are collected solely for Phase 5.4 report inclusion and Phase 7 Issue candidate extraction.

**Pre-existing issues collection**: Extract items from each reviewer's "### 既存問題（PR 対象ファイル）" section. Retain these as `pre_existing_issues` in the conversation context (reviewer_type, severity, file_line, description, recommendation). These are NOT findings — they do not count toward `total_findings`, do not affect the assessment, and do not block merge. They are collected solely for Phase 5.4 report inclusion and Phase 7 Issue candidate extraction (Source C). A pre-existing issue is one that was detected via revert test as existing before the current PR's changes.

#### 5.1.1 Verification Mode Findings Collection

When `review_mode == "verification"`, classify: NOT_FIXED/PARTIAL/REGRESSION/MISSED_CRITICAL (all blocking). FIXED findings recorded in Fix Verification Summary only.

**フルレビュー由来の新規指摘**: verification mode では、検証レビューに加えてフルレビュー（Phase 4.5 の通常テンプレート）も実施される。フルレビューで検出された新規指摘は、重要度に関わらずすべて blocking 扱いとする。これは初回フルレビューと同等の基準を適用するためであり、verification mode であることを理由に指摘を非 blocking に降格してはならない。

#### 5.1.2 Finding Stability Analysis

When verification mode AND `allow_new_findings_in_unchanged_code == false`: Check if finding is in incremental diff. Unchanged code: CRITICAL/HIGH → genuine (blocking), MEDIUM/LOW → stability_concern (non-blocking, informational).

**例外**: この stability_concern 分類は、Phase 4.5.1 の verification テンプレート（Part 2: リグレッションチェック）由来の指摘にのみ適用される。Phase 4.5 の通常テンプレート（フルレビュー）由来の指摘には適用しない。フルレビュー由来の指摘は 5.1.1 に従い、重要度に関わらず blocking とする。

#### 5.1.3 Doc-Heavy PR Mode Post-Condition Check

**Execution condition**: `{doc_heavy_pr} == true` (set in Phase 1.2.7) AND tech-writer is in the reviewer set.

**Skip condition**: `{doc_heavy_pr} == false` または tech-writer がレビュアー集合にない場合は本 Phase をスキップして直接 Phase 5.2 に進む。

**Purpose**: Doc-Heavy PR Mode の 5 カテゴリ verification protocol ([`internal-consistency.md`](./references/internal-consistency.md) 参照) が **実際に実行されたか** を post-condition で検証する。これがないと、tech-writer が推測ベースの finding を返しても誰も気付かず silent non-compliance が成立してしまう (Issue #349 の根本目的)。

**Verification steps**:

1. **tech-writer finding 0 件警告** (silent non-compliance 防止):

   **判定条件** (単純化された AND 条件):
   - tech-writer の `finding_count == 0` **かつ**
   - tech-writer の出力に以下の META 行が 1 つも含まれない:
     - `META: All 5 verification categories executed, 0 inconsistencies found. Categories: [Implementation Coverage, Enumeration Completeness, UX Flow Accuracy, Order-Emphasis Consistency, Screenshot Presence]` (negative confirmation)
     - `META: Cross-Reference partially skipped` (外部参照スキップ、ステップ 3 で扱う)

   上記両方が true の場合のみ、警告を発火する:
     - **WARNING を必ず stderr に出力** (silent fall-through 禁止):
       ```
       WARNING: Doc-Heavy PR mode active, but tech-writer returned 0 findings without META confirmation.
       Expected: Either explicit "META: All 5 verification categories executed, 0 inconsistencies found" declaration, or "META: Cross-Reference partially skipped" notice for external-repo documentation.
       Action: Verify tech-writer executed the 5-category verification protocol from internal-consistency.md. Re-run with explicit Doc-Heavy mode instructions if needed.
       ```
     - レビュー結果に `doc_heavy_post_condition: warning` フラグを set
     - overall assessment を `修正必要` に変更 (silent pass 防止)

   **Note**: `finding_count >= 1` の場合はこのステップ 1 をスキップし、ステップ 2 (Evidence field 検査) に進む。ステップ 2 の Evidence 要件を満たせば post-condition は passed とみなされる。

2. **Evidence field 必須化** (厳格検査 — Markdown テーブル対応):
   - tech-writer の各 finding (CRITICAL/HIGH/MEDIUM/LOW すべて) について、**`内容` カラム本文中**に Evidence 記述が含まれているかを正規表現で検査する。
   - **重要 — Markdown テーブル構造への配慮**: Markdown テーブルのセル本文内では物理的な改行は許容されず、各 finding 行は 1 物理行として表現される (セル内改行は `<br>` または同一行内の区切り文字で表現)。そのため、Evidence 検出の正規表現は**行頭 anchor (`^`) に依存してはならない**。代わりに「行頭または直前が空白/区切り文字/`<br>`/`|`/`>`」を許容する anchor を使用する:
     - 正規表現 (multiline mode、行頭または直前が区切り文字):
       ```
       (?:(?:^|<br\s*/?>|[\s|>(])\s*)-?\s*Evidence:\s*tool=<?(Grep|Read|Glob|WebFetch)>?
       ```
     - 補助: `<br>` が使われない場合でも、セル内の `- Evidence: tool=Grep, ...` 形式はテキスト先頭 (`^`) または空白/`|`/`(` 直後に出現するためマッチする
   - **山括弧メタ記法の許容**: `tool=<?(Grep|Read|Glob|WebFetch)>?` により、reviewer が tech-writer.md の example を literal に解釈して `tool=<Grep>` と書いた場合でもマッチする。これにより example ドキュメントのメタ記法との乖離による false positive を防ぐ。
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

3. **META: Cross-Reference partially skipped 検出**:
   - tech-writer の出力に正規表現 `(?m)(?:^|<br\s*/?>|[\s|>(])\s*META:\s*Cross-Reference partially skipped` にマッチする行が含まれている場合:
     - レビュー結果に `cross_reference_partial_skip: true` と外部リポジトリ情報 (META ブロック本文) を set
     - Phase 5.4 (Integrated Report) の Doc-Heavy PR Mode 検証状態セクションに表示
     - Phase 5.3 の overall assessment 判定時、ユーザーに明示的な acknowledgement を `AskUserQuestion` で求める
     - acknowledgement なしでマージ判定を下さない (`修正必要` 扱い)

**Implementation note**: 本 Post-Condition Check は Phase 5.2 (Cross-Validation) の **前**に実行する。これにより evidence 欠落が cross-validation の対象になる前に検出され、tech-writer の再実行判断が早期に下せる。

**Retained flags** (Phase 5.4 template 表示用):
- `numstat_availability`: `"OK"` / `"unavailable"` (Phase 1.2.6 で set)
- `numstat_fallback_reason`: numstat 失敗時のエラー要約 (Phase 1.2.6 で set、通常時は未定義)
- `doc_heavy_pr_value`: `{doc_heavy_pr}` の boolean 値 (Phase 1.2.7 で set)
- `doc_heavy_pr_decision_summary`: Doc-Heavy 判定根拠の 1 行要約 (例: `"doc_lines_ratio=0.72 >= 0.6"` / `"rite plugin self-only, excluded"`)
- `doc_heavy_post_condition`: `passed` / `warning` / `error`
- `doc_heavy_finding_count`: tech-writer の finding count
- `evidence_missing_count`: evidence 欠落 finding の数
- `evidence_missing_list`: 欠落 finding の file:line 一覧
- `cross_reference_partial_skip`: boolean
- `cross_reference_skip_details`: META ブロック本文 (外部参照情報)

**Phase 5.4 表示責務の分離**: `doc_heavy_pr == false` (numstat 不在または ratio 未満) の場合、Phase 5.1.3 の post-condition check 自体はスキップされるが、Phase 5.4 Integrated Report の Doc-Heavy PR Mode 検証状態セクションでは `numstat_availability` と `doc_heavy_pr_value` を上記 retained flags から参照して表示する。これにより numstat 失敗の可視性は Phase 5.1.3 スキップとは独立に保たれる。

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
| `true` | Proceed to Phase 5.2.1 (Debate Phase) for automatic resolution attempt |
| `false` | Prompt user directly with `AskUserQuestion` (legacy behavior, see below) |

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
<!-- Phase 5.1.3 で post-condition check が実行された場合のみ表示。doc_heavy_pr == false または tech-writer が不在の場合は省略 -->
<!-- Phase 1.2.6 で numstat 失敗して Doc-Heavy 判定が skip された場合もここに表示 -->

| 項目 | 状態 | 詳細 |
|------|------|------|
| numstat 可用性 | OK / **unavailable** | {numstat_fallback_reason — 失敗時のみ記載} |
| Doc-Heavy 判定 | {doc_heavy_pr_value} | {判定根拠の 1 行 summary} |
| Post-condition | passed / **warning** / **error** | {doc_heavy_post_condition 値} |
| tech-writer finding 件数 | {doc_heavy_finding_count} | {0 件の場合は META negative confirmation の有無} |
| Evidence 欠落 finding | {evidence_missing_count} 件 | {evidence_missing_list を箇条書き} |
| Cross-Reference partial skip | なし / **あり** | {cross_reference_skip_details — external repo 情報} |
| ユーザー acknowledgement | 不要 / **取得済み** / **未取得** | {partial_skip あり時のみ記載} |

**影響**: `post-condition == warning` または `error`、もしくは `evidence_missing_count >= 1`、または `cross_reference_partial_skip == true` かつ acknowledgement 未取得の場合、総合評価は自動的に **`修正必要`** に昇格する。

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

### 既存問題（PR 対象ファイル）（該当がある場合のみ）
<!-- Phase 5.1 で収集した pre_existing_issues がある場合のみ表示。0件の場合はこのセクション自体を省略 -->

> このセクションの問題は今回の PR で導入されたものではなく、変更前から存在していた既存問題です。assessment（`total_findings`）には含まれず、マージ判定に影響しません。別 Issue での対応を推奨します。

| 重要度 | ファイル:行 | 内容 | レビュアー | 推奨対応 |
|--------|------------|------|-----------|----------|
| {severity} | {file:line} | {description} | {reviewer_type} | 別 Issue で対応推奨: {recommendation} |

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

### 既存問題（PR 対象ファイル）（該当がある場合のみ）
<!-- Phase 5.1 で収集した pre_existing_issues がある場合のみ表示。0件の場合はこのセクション自体を省略 -->

> このセクションの問題は今回の PR で導入されたものではなく、変更前から存在していた既存問題です。assessment（`total_findings`）には含まれず、マージ判定に影響しません。別 Issue での対応を推奨します。

| 重要度 | ファイル:行 | 内容 | レビュアー | 推奨対応 |
|--------|------------|------|-----------|----------|
| {severity} | {file:line} | {description} | {reviewer_type} | 別 Issue で対応推奨: {recommendation} |

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
| `full` | Full review mode template |
| `verification` | 統合テンプレート（検証サマリー + フルレビューセクション含む） |

**Note**: `📎 reviewed_commit: {current_commit_sha}` must be output in both templates. This is used for incremental diff retrieval in the verification mode of the next cycle (Phase 1.2.4).

---

## Phase 6: Result Output

### 6.1 Post PR Comment

Post the review results as a PR comment. Use `mktemp` + `--body-file` to safely handle markdown content:

```bash
tmpfile=$(mktemp)
trap 'rm -f "$tmpfile"' EXIT
cat <<'EOF' > "$tmpfile"
## 📜 rite レビュー結果

{review_result_content}

---
🤖 Generated by `/rite:pr:review`
EOF
gh pr comment {pr_number} --body-file "$tmpfile"
```

**Note**: Using `--body-file` with a temp file eliminates escaping issues and avoids shell variable expansion risks.

**Note**: `{review_result_content}` uses the integrated report generated in Phase 5.4 (template based on `review_mode`). The `📎 reviewed_commit: {current_commit_sha}` at the end of the report is used in the verification mode of the next cycle, so it must always be included.

### 6.1.1 Update Work Memory Phase

> **Reference**: Update work memory per `work-memory-format.md` (at `{plugin_root}/skills/rite-workflow/references/work-memory-format.md`). Update phase to `phase5_review`, detail to `レビュー中`.

**Step 1: Update local work memory (SoT)**

Use the self-resolving wrapper. See [Work Memory Format - Usage in Commands](../../skills/rite-workflow/references/work-memory-format.md#usage-in-commands) for details.

```bash
WM_SOURCE="review" \
  WM_PHASE="phase5_review" \
  WM_PHASE_DETAIL="レビュー中" \
  WM_NEXT_ACTION="レビュー結果に基づき次のアクションを決定" \
  WM_BODY_TEXT="Review cycle completed." \
  WM_ISSUE_NUMBER="{issue_number}" \
  bash {plugin_root}/hooks/local-wm-update.sh 2>/dev/null || true
```

**On lock failure**: Log a warning and continue — local work memory update is best-effort.

**Step 2: Sync to Issue comment (backup)** at phase transition (per C3 backup sync rule).

```bash
bash {plugin_root}/hooks/issue-comment-wm-sync.sh update \
  --issue {issue_number} \
  --transform update-phase \
  --phase "phase5_review" --phase-detail "レビュー中" \
  2>/dev/null || true
```

### 6.1.2 Review Metrics Recording

> **Reference**: [Execution Metrics - Review Metrics](../../references/execution-metrics.md#review-metrics)

Skip if `metrics.enabled: false` in rite-config.yml. Otherwise, record review metrics from the current review cycle.

**Step 1**: Collect metrics from the Phase 5 review results:

| Item | Source |
|------|--------|
| CRITICAL findings count | Count from integrated report (Phase 5.4) |
| HIGH findings count | Count from integrated report |
| MEDIUM findings count | Count from integrated report |
| LOW findings count | Count from integrated report |

**Step 2**: Include review metrics in the Phase 6.1 PR comment.

Append the metrics section (format defined in [Execution Metrics](../../references/execution-metrics.md#review-metrics)) to `{review_result_content}` **before** posting the PR comment in Phase 6.1. This avoids a separate API call — the metrics are included in the same comment as the review results.

**Note**: This step records raw data only. Threshold evaluation is performed by `/rite:issue:start` Phase 5.5.2 at workflow completion.

### 6.2 Update Issue Work Memory

> **Reference**: Update work memory per `work-memory-format.md`. Append review history and update next steps.

**Steps:**

All steps use `issue-comment-wm-sync.sh` for API operations. No direct `gh api` calls are needed — the script handles comment ID retrieval, caching, backup, safety checks, and PATCH internally.

1. **Update session info** (defense-in-depth): Phase 6.1.1 で local work memory (SoT) を更新済みだが、Issue comment (backup) のセッション情報も冗長に更新する (Issue #90, #93)。

2. **Append review history**: Add review result summary to the work memory body.

3. **Update next steps**: Set the next command based on the review assessment.

```bash
# Step 1: セッション情報更新（defense-in-depth）
bash {plugin_root}/hooks/issue-comment-wm-sync.sh update \
  --issue {issue_number} \
  --transform update-phase \
  --phase "phase5_review" --phase-detail "レビュー中" \
  2>/dev/null || true

# Step 2: レビュー対応履歴追記
review_tmp=$(mktemp)
trap 'rm -f "$review_tmp"' EXIT
cat > "$review_tmp" << 'REVIEW_EOF'
{review_history_content}
REVIEW_EOF
bash {plugin_root}/hooks/issue-comment-wm-sync.sh update \
  --issue {issue_number} \
  --transform append-section \
  --section "レビュー対応履歴" --content-file "$review_tmp" \
  2>/dev/null || true

# Step 3: 次のステップ更新
next_tmp=$(mktemp)
trap 'rm -f "$next_tmp"' EXIT
printf '%s' "{next_step_content}" > "$next_tmp"
bash {plugin_root}/hooks/issue-comment-wm-sync.sh update \
  --issue {issue_number} \
  --transform replace-section \
  --section "次のステップ" --content-file "$next_tmp" \
  2>/dev/null || true
rm -f "$review_tmp" "$next_tmp"
```

**Placeholder descriptions:**
- `{review_history_content}`: Review result summary (assessment, finding counts, commit SHA). Claude generates from Phase 5 results.
- `{next_step_content}`: Next command based on assessment. Merge OK → `/rite:pr:ready` | Requires fixes → `/rite:pr:fix`

**Consistency guarantee (Issue #90)**: Steps 1-3 collectively ensure that the Issue comment (backup) is consistent with the local work memory (SoT) updated in Phase 6.1.1. This is a **defense-in-depth** design: if either path silently fails, the other guarantees at least one source has correct state for recovery.

### 6.3 Completion Report

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

#### 6.3.1 Next Step Branching by Invocation Source

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
- Extract candidates per Phase 7.1 (Source B and Source C — Source A findings are handled by the fix loop)
- If candidates exist: auto-create Issues without user confirmation per Phase 7.2-7.3 E2E behavior
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

Extract candidates from **three sources**:

**Source A — Findings (指摘事項)**: Extract findings meeting: Severity MEDIUM+ AND contains keywords (`スコープ外`, `別 Issue`, `out of scope`, `separate issue`, etc.)

**Source B — Recommendations (推奨事項)**: Extract items from the "推奨事項" section of the integrated report (Phase 5.4) where the "別 Issue 候補" column is ✅. No severity filter is applied (recommendations lack severity).

**Source C — Pre-existing Issues (既存問題)**: Extract all items from the "既存問題（PR 対象ファイル）" section of the integrated report (Phase 5.4). All pre-existing issues are candidates for Issue creation (they are CRITICAL/HIGH by definition — only those severities are collected in Phase 5.1). Source C candidates are extracted only when the review result is `[review:mergeable]`.

Deduplicate across sources: if the same file:line appears in multiple sources, keep only the Source A entry (it has richer metadata). Source C entries for the same file:line as Source B are also deduplicated (keep Source C, which has severity).

### 7.2-7.3 User Confirmation

If 0 candidates: Skip Phase 7. If 1+: Confirm with `AskUserQuestion` (options: Create all / Select individually / Skip).

**Candidate display format:**

| # | Source | ファイル | 内容 | 重要度 | Priority |
|---|--------|---------|------|--------|----------|
| 1 | 指摘 | {file:line} | {content} | {severity} | {mapped_priority} |
| 2 | 推奨 | {file:line or "—"} | {content} | — | Medium |
| 3 | 既存問題 | {file:line} | {content} | {severity} | {mapped_priority} |

**Default values for pre-existing issue candidates** (Source C):
- **Priority**: CRITICAL→High, HIGH→Medium
- **Complexity**: `S`
- **Severity in Issue body**: Actual severity from the pre-existing issue table
- **File:line**: From the pre-existing issue table

**Default values for recommendation-based candidates** (Source B):
- **Priority**: `Medium`
- **Complexity**: `S`
- **Severity in Issue body**: `推奨事項（重要度なし）`
- **File:line**: Use mentioned path if available; otherwise `特定ファイルなし`

**E2E flow behavior**: When invoked within the `/rite:issue:start` end-to-end flow, skip the `AskUserQuestion` confirmation and auto-create Issues for all candidates (consistent with `fix.md` Phase 4.3.3 behavior in E2E). Display a brief summary:

`推奨事項・既存問題から {count} 件の別 Issue を自動作成しました。`

### 7.4 Issue Creation

Create Issues directly using `gh issue create` and register them in GitHub Projects. Do **not** use the `/rite:issue:create` Skill tool (it triggers interactive prompts that disrupt the flow).

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

**Priority mapping**: CRITICAL→High, HIGH→Medium, MEDIUM→Low, Recommendation (Source B)→Medium, Pre-existing (Source C): CRITICAL→High, HIGH→Medium

**Complexity mapping**: XS: single-line/single-location fix. S: multi-line change within 1-2 files

**Placeholder value sources** (Claude はスクリプト生成前に必ず以下のソースから値を取得し、プレースホルダーを置換すること):

| Placeholder | Source | Example |
|-------------|--------|---------|
| `{projects_enabled}` | `rite-config.yml` → `github.projects.enabled` | `true` |
| `{project_number}` | `rite-config.yml` → `github.projects.project_number` | `6` |
| `{owner}` | `rite-config.yml` → `github.projects.owner` | `B16B1RD` |
| `{iteration_mode}` | `rite-config.yml` → `iteration.enabled` が `true` かつ `iteration.auto_assign` が `true` なら `"auto"`、それ以外は `"none"` | `"none"` |
| `{plugin_root}` | [Plugin Path Resolution](../../references/plugin-path-resolution.md#resolution-script) | `/home/user/.claude/plugins/rite` |

**⚠️ Projects 登録失敗時の警告表示（必須）**: スクリプト実行後、`project_registration` の値を必ず確認し、`"partial"` または `"failed"` の場合は以下を表示すること:

```
⚠️ Projects 登録が完全に完了しませんでした（status: {project_registration}）
手動登録: gh project item-add {project_number} --owner {owner} --url {created_issue_url}
```

```bash
tmpfile=$(mktemp)
trap 'rm -f "$tmpfile"' EXIT

cat <<'BODY_EOF' > "$tmpfile"
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

if [ ! -s "$tmpfile" ]; then
  echo "ERROR: Issue 本文の生成に失敗" >&2
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
  exit 1
fi
created_issue_url=$(printf '%s' "$result" | jq -r '.issue_url')
project_reg=$(printf '%s' "$result" | jq -r '.project_registration')
printf '%s' "$result" | jq -r '.warnings[]' 2>/dev/null | while read -r w; do echo "⚠️ $w"; done
```

**Source-aware placeholder values**: The `{source_label}` placeholder in the heredoc template above must be substituted based on the candidate source. When from Source A (findings), use `指摘`. When from Source B (recommendations), use `推奨事項`. When from Source C (pre-existing issues), use `既存問題`. The `{severity}` placeholder uses the actual severity for Source A and Source C, or `推奨事項（重要度なし）` for Source B. The `{file}:{line}` placeholder uses `特定ファイルなし` for Source B when no file path is mentioned.

**Error handling**:

| Error Case | Response |
|------------|----------|
| Script returns `issue_url: ""` | Display warning with error details. If remaining candidates exist, continue creating others |
| `project_registration: "partial"` or `"failed"` | Display warnings from result. Issue creation itself succeeded |

### 7.5-7.6 Append to PR & Report

Post Issue list to PR comment (`mktemp` + `--body-file`). Output completion report.

---

## Error Handling

| Error | Action |
|--------|------|
| PR not found | Check with `gh pr list` and re-run with the correct number |
| Skill file load failure | Fallback using built-in profiles |
| Review execution error | Choose skip/retry/cancel |
| Comment post failure | Display review results as text |

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
- **[READ-ONLY RULE]**: `Edit`/`Write` ツールでプロジェクトのソースファイルを修正してはなりません。指摘がある場合は `[review:fix-needed:{n}]` を出力し、修正は `/rite:pr:fix` に委譲してください
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

For standalone execution, Phase 8 is not executed. Terminate by confirming the next action with the user via `AskUserQuestion` in Phase 6.3.
