---
description: マルチレビュアー PR レビューを実行
context: fork
---

# /rite:pr:review

Analyze PR changes and dynamically load expert skills to perform a multi-reviewer review.

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

Determine the review mode based on the number of review-fix loop cycles.

**Loading configuration:**

Retrieve `review.loop.verification_mode` from `rite-config.yml` (default: `true`).

**Determination logic:**

| Condition | review_mode | Description |
|------|-------------|------|
| `loop_count <= 1` or `verification_mode == false` | `full` | Full review as usual |
| `loop_count >= 2` and `verification_mode == true` | `verification` | Verification mode (verify fixes from previous findings + regression check of incremental diff) |

**How to obtain `loop_count`:**

Retrieve in the following priority order:

| Priority | Source | Description |
|---------|--------|-------------|
| 1 | Work memory `現在のループ回数` | Reliable; no inference needed. Read from `### レビュー対応履歴` section |
| 2 | Conversation context (end-to-end flow) | Fallback when work memory field is absent |
| 3 | `1` (default) | First run or standalone execution |

**Retrieval procedure:**

1. If work memory was loaded (Phase 1.1.1 or Phase 0.1), check for `現在のループ回数` in the `### レビュー対応履歴` section
2. If found → Use that value as `loop_count`
3. If not found → Fall back to counting review-fix loop invocations from conversation context
4. If neither is available → Default to `1`

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

**Error handling**: If `git diff --numstat` fails (network error, timeout, etc.), generate the summary using only the `additions`, `deletions`, `changedFiles`, and `files` data from Phase 1.1.

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

**Note**: Only representative patterns are shown below. See the Available Reviewers table in `skills/reviewers/SKILL.md` for details. The Activation section in each skill file is the source of truth.

| File Pattern | Recommended Reviewer | Skill File |
|-----------------|----------------|----------------|
| `**/security/**`, `**/auth/**`, `auth*`, `crypto*`, `**/middleware/auth*` | Security Expert | `security.md` |
| `.github/**`, `Dockerfile*`, `docker-compose*`, `*.yml` (CI/CD determination: see `devops.md`), `Makefile` | DevOps Expert | `devops.md` |
| `**/*.test.*`, `**/*.spec.*`, `**/test/**`, `**/__tests__/**`, `jest.config.*`, `vitest.config.*`, `cypress/**`, `playwright/**` | Test Expert | `test.md` |
| `**/api/**`, `**/routes/**`, `**/handlers/**`, `**/controllers/**`, `openapi.*`, `swagger.*` | API Design Expert | `api.md` |
| `**/*.css`, `**/*.scss`, `**/styles/**`, `**/components/**`, `*.jsx`, `*.tsx`, `*.vue` | Frontend Expert | `frontend.md` |
| `**/db/**`, `**/models/**`, `**/migrations/**`, `**/*.sql`, `prisma/**`, `drizzle/**` | Database Expert | `database.md` |
| `package.json`, `*lock*`, `requirements.txt`, `Pipfile`, `go.mod`, `Cargo.toml` | Dependencies Expert | `dependencies.md` |
| `commands/**/*.md`, `skills/**/*.md` | Prompt Engineer | `prompt-engineer.md` |
| `**/*.md` (other than above), `docs/**`, `README*` | Technical Writer | `tech-writer.md` |

**Pattern priority rules:**
1. `commands/**/*.md`, `skills/**/*.md` -> Prompt Engineer (highest priority)
2. Other `**/*.md` -> Technical Writer
3. If matching multiple patterns, include all matching reviewers as candidates

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

Refer to the "Reviewer Type Identifiers" table in `skills/reviewers/SKILL.md`. The following is an excerpt for reference:

| reviewer_type | Japanese Display |
|---------------|-----------|
| security | セキュリティ専門家 |
| devops | DevOps 専門家 |
| test | テスト専門家 |
| api | API 設計専門家 |
| frontend | フロントエンド専門家 |
| database | データベース専門家 |
| dependencies | 依存関係専門家 |
| prompt-engineer | プロンプトエンジニア |
| tech-writer | テクニカルライター |

**Note**: The SKILL.md table is the source of truth. When adding new reviewers, update SKILL.md first.

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
| Prompt Engineer | `prompt-engineer-reviewer.md` | Skill/command definition quality |
| Technical Writer | `tech-writer-reviewer.md` | Document clarity, accuracy |

**Loading sub-agent definition files:**

1. Load the definition file corresponding to the reviewer selected in Phase 2:
   ```
   Read: {plugin_root}/agents/{reviewer_type}-reviewer.md
   ```
   Example: `security` -> `{plugin_root}/agents/security-reviewer.md`

2. On load failure, display a warning and skip that sub-agent

**Parallel execution using the Task tool:**

Achieve parallel execution by **invoking multiple Task tools in a single message** for all selected sub-agents.

Pass the following information to each sub-agent:
- PR diff (or related file diffs - see reference below)
- Changed file list
- Related Issue specification (obtained in Phase 1.3.1)
- Sub-agent definition (contents of agents/*.md)

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
- `prompt`: Full Phase 4.5 format (diff, spec, skill profile, checklist)

Task results are returned automatically upon completion. No explicit wait handling is needed.

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

**Placeholder embedding method:**

| Placeholder | Source | Extraction Method |
|---------------|--------|----------|
| `{relevant_files}` | Changed file list from Phase 1.2 | Extract only files matching the reviewer's Activation pattern |
| `{diff_content}` | Diff from Phase 1.2 | **Varies by scale** (see below) |
| `{skill_profile}` | Role + Expertise Areas section of skill file | Extract the relevant section from the skill file loaded via Read |
| `{checklist}` | Review Checklist section of skill file | Full text including Critical / Important / Recommendations |
| `{issue_spec}` | Issue specification obtained in Phase 1.3.1 | Content of the "仕様詳細" section (if empty, write "仕様情報なし") |
| `{change_intelligence_summary}` | Change Intelligence Summary from Phase 1.2.6 | One-paragraph summary of change type, file classification, and focus area |
| `{change_summary}` | Scale information from Phase 1.2.1 | Used only for large diffs. Change summary table |

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

## あなたの役割
{skill_profile}

## チェックリスト
{checklist}

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

| 重要度 | ファイル:行 | 内容 | 推奨対応 |
|--------|------------|------|----------|
| {CRITICAL/HIGH/MEDIUM/LOW} | {file:line} | {description} | {recommendation} |

### 推奨事項
[改善提案があれば]
```

**When `{issue_spec}` is empty:** Write "仕様情報なし" and omit spec-based checks ("仕様との整合性" and "仕様への疑問" sections).

### 4.5.1 Verification Mode Review Instruction Template

When `review_mode == "verification"` (determined in Phase 1.2.4), use the following template **instead of** the normal template from Phase 4.5.

**Template selection logic:**

| review_mode | Template Used |
|-------------|-------------------|
| `full` | Normal template from Phase 4.5 |
| `verification` | This section's (4.5.1) verification template |

**Verification mode review instruction template:**

```
PR #{number}: {title} の検証レビューを {reviewer_type} として実行してください。

## 変更概要
{change_intelligence_summary}

## Review Mode: Verification (Loop {loop_count})

これは review-fix ループの {loop_count} 回目のレビューです。前回の指摘が正しく修正されたかの検証と、修正箇所のリグレッションチェックに集中してください。

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

**重要**: 前回の Fix サイクルで変更されていないコードに対して新規の MEDIUM/LOW 指摘を生成しないこと。未変更コードの CRITICAL/HIGH 指摘のみ「見落とし」として報告可。

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
```

**Placeholder embedding method:**

| Placeholder | Source | Extraction Method |
|---------------|--------|----------|
| `{previous_findings_table}` | Previous review finding table obtained in Phase 1.2.4 | Integrate finding tables from each reviewer in the "全指摘事項" section from the previous `📜 rite レビュー結果` comment |
| `{incremental_diff}` | `git diff {last_reviewed_commit}..HEAD` obtained in Phase 1.2.4 | Full incremental diff (however, for large scale, only files relevant to the reviewer) |
| `{change_intelligence_summary}` | Change Intelligence Summary from Phase 1.2.6 | One-paragraph summary of change type, file classification, and focus area |
| `{loop_count}` | `loop_count` obtained in Phase 1.2.4 (work memory priority) | -- |

---

## Phase 5: Critic Phase (Result Verification and Integration)

### 5.1 Result Collection

**⚠️ Scope**: Collect only newly detected findings from current review. Fixed code (not in diff) is auto-excluded; unaddressed findings are re-detected.

Task results are retained in conversation context with internal format (reviewer_type, assessment, findings: severity/file_line/description/recommendation).

#### 5.1.1 Verification Mode Findings Collection

When `review_mode == "verification"`, classify: NOT_FIXED/PARTIAL/REGRESSION/MISSED_CRITICAL (all blocking). FIXED findings recorded in Fix Verification Summary only.

#### 5.1.2 Finding Stability Analysis

When verification mode AND `allow_new_findings_in_unchanged_code == false`: Check if finding is in incremental diff. Unchanged code: CRITICAL/HIGH → genuine (blocking), MEDIUM/LOW → stability_concern (non-blocking, informational).

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

#### 5.3.1 Assessment Rules (Loop Count Aware)

**Red blocking rule: If even 1 blocking finding exists, it MUST NOT be assessed as "Merge OK"**

Distinguish between "blocking findings" and "non-blocking findings" based on loop count. Determined from the `review.loop` settings in `rite-config.yml` and the review-fix loop count in conversation context. When executed standalone (outside a loop), treat as loop iteration 1.

**Gradual relaxation table:**

| Loop Count | Gate Mode | Blocking Target | Non-Blocking |
|-----------|------------|------------|--------------|
| 1 to `relax_medium_after - 1` (default: 1-2) | Strict mode | CRITICAL/HIGH/MEDIUM/LOW | None |
| `relax_medium_after` to `relax_high_after - 1` (default: 3-4) | MEDIUM/LOW relaxation | CRITICAL/HIGH | MEDIUM/LOW |
| `relax_high_after` to `max_iterations - 1` (default: 5-6) | HIGH relaxation | CRITICAL only | HIGH/MEDIUM/LOW |
| `max_iterations` (default: 7) | Forced termination | -- | All remaining findings are converted to separate Issues and the loop exits |

Load `review.loop` from `rite-config.yml` (defaults: max_iterations=7, relax_medium_after=3, relax_high_after=5). Non-blocking findings reported but not in `total_blocking_findings`; candidates for separate Issue creation.

#### 5.3.3 Assessment Logic (Loop Count Aware)

Use **only blocking findings** for determination. Priority: CRITICAL blocking → Requires fixes | HIGH/MEDIUM/LOW blocking → Cannot merge (findings exist) | 0 blocking → Merge OK.

#### 5.3.5 Output Format at Assessment Decision Time

When determining the assessment, explicitly output the finding count and loop information in the following format:

```
【ループ情報】
- 現在のループ回数: {loop_count} / {max_iterations}
- 適用中のゲート: {厳格モード / MEDIUM/LOW 緩和 / HIGH 緩和 / 強制終了}
- 非ブロック指摘: {non_blocking_count} 件（別 Issue 化対象）

【指摘件数サマリー】
- CRITICAL: {count} 件
- HIGH: {count} 件 {※非ブロック の場合は "(非ブロック)" を付記}
- MEDIUM: {count} 件 {※非ブロック の場合は "(非ブロック)" を付記}
- LOW: {count} 件 {※非ブロック の場合は "(非ブロック)" を付記}
- 合計: {total} 件（ブロック: {blocking} 件 / 非ブロック: {non_blocking} 件）

【評価判定】
- ブロック指摘件数: {blocking} 件
- 優先度 {n} に該当: {条件の説明}
- 総合評価: {マージ可 / マージ不可（指摘あり） / 修正必要}
```

**Note**: For standalone execution (outside a loop), display the loop count in the "Loop Information" section as "1 / {max_iterations} (standalone execution)".

**Additional output for verification mode:**

When `review_mode == "verification"`, output the following in addition to the above:

```
【検証モード情報】
- レビューモード: 検証 (verification)
- 前回レビュー commit: {last_reviewed_commit}
- 修正検証: FIXED {fixed} / NOT_FIXED {not_fixed} / PARTIAL {partial}
- リグレッション: {regression_count} 件
- Stability Concerns: {stability_concern_count} 件（非ブロック）
```

**⚠️ Important**: Blocking findings → cannot merge → `/rite:issue:start` loop continues. "Merge OK" = 0 blocking findings (non-blocking handled via separate Issues).

#### 5.3.6 Return Values to Caller (Important)

Return: total_findings, **total_blocking_findings** (if >0, `/rite:pr:fix` required), total_non_blocking_findings, evaluation, loop_count, gate_mode, review_mode, stability_concerns.

**Red important constraint:**

The caller (`/rite:issue:start` Phase 5.5) **mechanically** invokes `/rite:pr:fix` when `total_blocking_findings > 0` or `evaluation != "マージ可"`, **regardless of AI judgment**.

The following decisions MUST NOT be made by `/rite:pr:review`:
- "Since blocking findings are 0, non-blocking findings can also be ignored"
- "The findings are minor, so no action is needed"
- Independently modifying the gradual relaxation table configuration values

`/rite:pr:review` is responsible only for accurately reporting the assessment results. Gradual relaxation is applied mechanically according to the `rite-config.yml` settings.

---

#### 5.3.7 Prohibition of Independent Judgment After Assessment

> **It is prohibited for the AI to override the assessment logic (5.3.3) results.**

Prohibited actions: Exception handling by severity (e.g., "Only LOWs, so minor"), overriding assessment (e.g., "Effectively merge-OK"), inserting user confirmation.

**Principle:** Assessment logic result = final decision. AI's role = reporting + mechanical transition to the next phase only.

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

### 全指摘事項

#### {Reviewer Type}
- **評価**: {可 / 条件付き / 要修正}
- **所見**: {summary}

| 重要度 | ファイル:行 | 内容 | 推奨対応 |
|--------|------------|------|----------|
| {severity} | {file:line} | {description} | {recommendation} |

<!-- 各レビュアーの結果を繰り返し -->

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
- **レビューモード**: 検証 (Loop {loop_count})
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
| `verification` | Verification mode template |

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
  bash plugins/rite/hooks/local-wm-update.sh 2>/dev/null || true
```

**On lock failure**: Log a warning and continue — local work memory update is best-effort.

**Step 2: Sync to Issue comment (backup)** at phase transition (per C3 backup sync rule).

```bash
comment_id=$(gh api repos/{owner}/{repo}/issues/{issue_number}/comments \
  --jq '[.[] | select(.body | contains("📜 rite 作業メモリ"))] | last | .id // empty')

# Claude が本文をパースし、セッション情報セクションの該当行を更新して PATCH
# - **フェーズ**: phase5_review
# - **フェーズ詳細**: レビュー中
# - **最終更新**: {timestamp}
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
| Loop count | Current `loop_count` from Phase 1.2.4 (work memory priority). For standalone execution, use `1` |

**Step 2**: Include review metrics in the Phase 6.1 PR comment.

Append the metrics section (format defined in [Execution Metrics](../../references/execution-metrics.md#review-metrics)) to `{review_result_content}` **before** posting the PR comment in Phase 6.1. This avoids a separate API call — the metrics are included in the same comment as the review results.

**Note**: This step records raw data only. Threshold evaluation is performed by `/rite:issue:start` Phase 5.5.2 at workflow completion.

### 6.2 Update Issue Work Memory

> **Reference**: Update work memory per `work-memory-format.md`. Append review history, increment `現在のループ回数`, and update next steps.

**Steps:**

1. **Get comment ID**: Retrieve the work memory comment ID and body using the Issue number obtained in Phase 1.3:
   ```bash
   gh api repos/{owner}/{repo}/issues/{issue_number}/comments \
     --jq '[.[] | select(.body | contains("📜 rite 作業メモリ"))] | last | {id: .id, body: .body}'
   ```

2. **Retrieve current body**: Extract the `body` field from the result of Step 1 (no additional API call needed)

3. **Increment `現在のループ回数`**:
   - Extract the current value from the `### レビュー対応履歴` section:
     - Pattern: `- \*\*現在のループ回数\*\*: (\d+)`
   - If found: `new_loop_count = current_value + 1`. **Update only this single line** — preserve all other content in the section (e.g., history entries appended by `/rite:pr:fix`). Do NOT replace the entire section.
   - If not found (first review): `new_loop_count = 1`. Create the `### レビュー対応履歴` section with just this line (Step 4 will append the history entry below it):
     ```
     ### レビュー対応履歴
     - **現在のループ回数**: {new_loop_count}
     ```

   **Bash implementation (Python-based single-line update):**

   ```bash
   # ⚠️ 以下の処理は Steps 1-6 の単一 Bash ブロック内で実行すること（クロスプロセス変数参照を防止）
   # backup_file is intentionally excluded from trap — preserved for post-mortem investigation
   backup_file="/tmp/rite-wm-backup-${issue_number}-$(date +%s).md"
   body_tmp=$(mktemp)
   updated_tmp=$(mktemp)
   trap 'rm -f "$body_tmp" "$updated_tmp"' EXIT

   # Step 1: Backup current body
   printf '%s' "$current_body" > "$backup_file"

   current_count=$(echo "$current_body" | grep -E -- '^- \*\*現在のループ回数\*\*: [0-9]+' | grep -oE '[0-9]+$' || true)
   if [[ -n "${current_count}" ]]; then
     new_loop_count=$(( ${current_count:-0} + 1 ))  # :-0 is defensive (see references/bash-defensive-patterns.md)
     printf '%s' "$current_body" > "$body_tmp"
     # Python-based line replacement (awk-free, sed-free)
     # File-based argument passing to avoid Japanese string issues in shell expansion
     python3 -c '
import sys, re
body_path, out_path, new_count = sys.argv[1], sys.argv[2], sys.argv[3]
with open(body_path, "r") as f:
    body = f.read()
updated = re.sub(
    r"^- \*\*現在のループ回数\*\*: \d+",
    f"- **現在のループ回数**: {new_count}",
    body, count=1, flags=re.MULTILINE
)
with open(out_path, "w") as f:
    f.write(updated)
' "$body_tmp" "$updated_tmp" "$new_loop_count"
     # Step 2: Validate updated content (10 bytes = minimum plausible work memory content)
     if [ ! -s "$updated_tmp" ] || [[ "$(wc -c < "$updated_tmp")" -lt 10 ]]; then
       echo "ERROR: Updated body is empty or too short. Aborting. Backup: $backup_file" >&2
       exit 1
     fi
     if grep -q -- '📜 rite 作業メモリ' "$updated_tmp"; then
       : # Header present, proceed
     else
       echo "ERROR: Updated body missing header. Restoring backup." >&2
       cp "$backup_file" "$updated_tmp"
       exit 1
     fi
     current_body=$(cat "$updated_tmp")
   else
     new_loop_count=1
     current_body="${current_body}
### レビュー対応履歴
- **現在のループ回数**: ${new_loop_count}"
   fi
   ```

   **Note for Claude**: ⚠️ awk・sed は使用禁止。Python インラインスクリプトによる行置換を使用すること。更新前バックアップ・空body検証・ヘッダー検証を必ず実行すること。参照: [gh-cli-patterns.md の Work Memory Update Safety Patterns](../../references/gh-cli-patterns.md#work-memory-update-safety-patterns)。

4. **Append review history**: Add review result summary to the work memory body

5. **Update next steps**: Set the next command based on the review assessment

6. **Write back**: Update the comment using `jq -n --rawfile` + `gh api --input -`

**Next command determination:** Merge OK → `/rite:pr:ready` | Cannot merge/Requires fixes → `/rite:pr:fix`

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

Output a machine-readable pattern and return control to `/rite:issue:start` Phase 5.4. No user confirmation is needed.

| Overall Assessment | Output Pattern |
|---------|------------------------|
| **Merge OK** (0 blocking, 0 non-blocking) | `[review:mergeable]` |
| **Conditional merge** (0 blocking, non-blocking > 0) | `[review:conditional-merge:{non_blocking_count}]` |
| **Requires fixes** (blocking > 0) | `[review:fix-needed:{blocking_count}]` |
| **Loop limit reached** | `[review:loop-limit:{total_remaining}]` |

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

Extract findings meeting: Severity MEDIUM+ AND contains keywords (`スコープ外`, `別 Issue`, `out of scope`, `separate issue`, etc.)

### 7.2-7.3 User Confirmation

If 0 candidates: Skip Phase 7. If 1+: Confirm with `AskUserQuestion` (options: Create all / Select individually / Skip).

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

**Priority mapping**: CRITICAL→High, HIGH→Medium, MEDIUM→Low

**Complexity mapping**: XS: single-line/single-location fix. S: multi-line change within 1-2 files

```bash
tmpfile=$(mktemp)
trap 'rm -f "$tmpfile"' EXIT

cat <<'BODY_EOF' > "$tmpfile"
## 概要

{description}

## 背景

この Issue は PR #{pr_number} のレビューで検出された非ブロック指摘から作成されました。

### 元のレビュー指摘
- **ファイル**: {file}:{line}
- **レビュアー**: {reviewer_type}
- **重要度**: {severity}
- **指摘内容**: {original_comment}

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

Before outputting any result pattern (`[review:mergeable]`, `[review:fix-needed:{n}]`, `[review:conditional-merge:{n}]`, `[review:loop-limit:{n}]`), update `.rite-flow-state` to reflect the post-review phase (defense-in-depth, fixes #719). This prevents intermittent flow interruptions when the fork context returns to the caller — even if the LLM churns after fork return and the system forcibly terminates the turn (bypassing the Stop hook), the state file will already contain the correct `next_action` for resumption.

**Condition**: Execute only when `.rite-flow-state` exists (indicating e2e flow). Skip if the file does not exist (standalone execution).

**State update by result**:

| Result | Phase | Next Action |
|--------|-------|-------------|
| `[review:mergeable]` | `phase5_post_review` | `rite:pr:review completed. Result: [review:mergeable]. Proceed to Phase 5.5 (Ready for Review). Do NOT stop.` |
| `[review:fix-needed:{n}]` | `phase5_post_review` | `rite:pr:review completed. Result: [review:fix-needed:{n}]. Proceed to Phase 5.4.4 (fix). Do NOT stop.` |
| `[review:conditional-merge:{n}]` | `phase5_post_review` | `rite:pr:review completed. Result: [review:conditional-merge:{n}]. Proceed to Phase 5.4.4 (fix) then Phase 5.5. Do NOT stop.` |
| `[review:loop-limit:{n}]` | `phase5_post_review` | `rite:pr:review completed. Result: [review:loop-limit:{n}]. Proceed to Phase 5.4.4 (fix) then Phase 5.5. Do NOT stop.` |

```bash
if [ -f ".rite-flow-state" ]; then
  TMP_STATE=".rite-flow-state.tmp.$$"
  jq --arg phase "phase5_post_review" \
     --arg ts "$(date -u +'%Y-%m-%dT%H:%M:%S+00:00')" \
     --arg next "{next_action_value}" \
     '.phase = $phase | .updated_at = $ts | .next_action = $next' \
     ".rite-flow-state" > "$TMP_STATE" && mv "$TMP_STATE" ".rite-flow-state" || rm -f "$TMP_STATE"
fi
```

Replace `{next_action_value}` with the value from the table above based on the review result. Also replace `{n}` in the next_action string with the actual finding count from the review result (e.g., if the result is `[review:fix-needed:3]`, then `{n}` = `3`).

**Note on `error_count`**: This patch-style `jq` command intentionally preserves `error_count` from the existing `.rite-flow-state` (consistent with `lint.md` Phase 4.0 and `fix.md` Phase 8.1). The count is effectively reset when `/rite:issue:start` writes a new complete object via `jq -n` at the next phase transition.

### 8.1 Output Pattern (Return Control to Caller)

Based on the Phase 6 review results, output the corresponding machine-readable pattern:

| Condition | Output Pattern |
|-----------|---------------|
| 0 blocking AND 0 non-blocking findings | `[review:mergeable]` |
| 0 blocking AND non-blocking findings > 0 | `[review:conditional-merge:{non_blocking_count}]` |
| 1 or more blocking findings | `[review:fix-needed:{blocking_count}]` |
| Loop limit reached (`loop_count >= max_iterations`) | `[review:loop-limit:{total_remaining}]` |

**Important**:
- Do **NOT** invoke `rite:pr:fix` or `rite:pr:ready` via the Skill tool
- Return control to the caller (`/rite:issue:start`)
- The caller determines the next action based on this output pattern
- The prohibited actions defined in Phase 5.3.7 "Prohibition of Independent Judgment After Assessment" also apply here

**When assessed as "Merge OK" but blocking findings > 0:**
-> Correct to `[review:fix-needed:{blocking_count}]`

**Example output:**
```
📜 rite レビュー結果

総合評価: マージ可
ブロック指摘: 0件
非ブロック指摘: 0件

[review:mergeable]
```

### 8.2 Standalone Execution Behavior

For standalone execution, Phase 8 is not executed. Terminate by confirming the next action with the user via `AskUserQuestion` in Phase 6.3.
