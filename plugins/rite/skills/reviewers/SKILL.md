---
name: reviewers
description: |
  Coordinates parallel multi-expert PR code review. Activates with /rite:pr:review
  or when user asks for "code review", "PR feedback", "security check", "review
  my changes", "レビューして", "PRレビュー", "コードチェック", "セキュリティ確認",
  "変更を確認", "コードレビュー". Spawns specialized reviewers (Security, API,
  Database, DevOps, Frontend, Test, Dependencies, Prompt Engineer, Tech Writer,
  Code Quality, Error Handling, Type Design) based on changed file patterns.
  Produces unified findings with severity levels.
disable-model-invocation: true
---

# Reviewer Skills - Main Coordinator

**File naming convention**: `SKILL.md` is the coordinator file for the skill group. Each expert skill is named in `{type}.md` format (e.g., `security.md`, `api.md`).

## Overview

This skill coordinates the multi-reviewer PR review process using specialized expert agents.

## Auto-Activation

This skill is activated during `/rite:pr:review` command execution.

## Available Reviewers

The table below shows primary file patterns. Each skill file's Activation section defines additional detailed patterns.

| Reviewer | Skill File | File Patterns (Primary) |
|----------|------------|-------------------------|
| Security Expert | `security.md` | `**/security/**`, `**/auth/**`, `auth*`, `crypto*`, `**/middleware/auth*` |
| Performance Expert | `performance.md` | `**/*.sh`, `**/hooks/**`, `**/api/**`, `**/services/**` |
| DevOps Expert | `devops.md` | `.github/**`, `Dockerfile*`, `docker-compose*`, `*.yml` (CI), `Makefile` |
| Test Expert | `test.md` | `**/*.test.*`, `**/*.spec.*`, `**/test/**`, `**/__tests__/**`, `jest.config.*`, `vitest.config.*`, `cypress/**`, `playwright/**` |
| API Design Expert | `api.md` | `**/api/**`, `**/routes/**`, `**/handlers/**`, `**/controllers/**`, `openapi.*`, `swagger.*` |
| Frontend Expert | `frontend.md` | `**/*.css`, `**/*.scss`, `**/styles/**`, `**/components/**`, `*.jsx`, `*.tsx`, `*.vue` |
| Database Expert | `database.md` | `**/db/**`, `**/models/**`, `**/migrations/**`, `**/*.sql`, `prisma/**`, `drizzle/**` |
| Dependencies Expert | `dependencies.md` | `package.json`, `*lock*`, `requirements.txt`, `Pipfile`, `go.mod`, `Cargo.toml` |
| Prompt Engineer | `prompt-engineer.md` | `commands/**/*.md`, `skills/**/*.md`, `agents/**/*.md`, and corresponding `.mdx` (`commands/**/*.mdx`, `skills/**/*.mdx`, `agents/**/*.mdx`) |
| Technical Writer | `tech-writer.md` | `**/*.md` (excluding `commands/**/*.md`, `skills/**/*.md`, `agents/**/*.md`), `**/*.mdx` (excluding `commands/**/*.mdx`, `skills/**/*.mdx`, `agents/**/*.mdx`), `docs/**`, `documentation/**`, `**/README*`, `CHANGELOG*`, `CONTRIBUTING*`, `*.rst`, `*.adoc`, `i18n/**/*.md`, `i18n/**/*.mdx` (excluding `plugins/rite/i18n/**` — rite plugin's own translations are dogfooding artifacts) |
| Error Handling Expert | `error-handling.md` | Files containing `try`, `catch`, `throw`, `Error`, `reject`, `fallback` keywords (JS/TS); `set -e`, `pipefail`, `trap`, `|| true`, `|| :`, `2>/dev/null` keywords (Bash); `**/*.sh` |
| Type Design Expert | `type-design.md` | `**/*.ts`, `**/*.tsx`, `**/*.rs`, `**/*.go` with `interface`, `type`, `enum`, `class`, `struct` |

**Note**: The table above shows representative patterns only. Each skill file's Activation section is the source of truth. The tech-writer row is kept in sync with `plugins/rite/commands/pr/review.md` Phase 1.2.7 `doc_file_patterns` and `plugins/rite/skills/reviewers/tech-writer.md` Activation section; see [`plugins/rite/commands/pr/references/internal-consistency.md`](../../commands/pr/references/internal-consistency.md#cross-reference) Cross-Reference section for the drift-prevention invariant. Automated drift detection is implemented by `plugins/rite/hooks/scripts/doc-heavy-patterns-drift-check.sh` (Issue #353 系統 1; invoked from `/rite:lint` Phase 3.7 as a warning/non-blocking check). The tech-writer row uses **set semantics** (file matching equivalence), not pattern syntax equality — the order of patterns and exact glob syntax may differ across the 3 files (this file, `tech-writer.md`, `review.md`) as long as the matched file set is identical. See `tech-writer.md` Activation section's note for the canonical equivalence statement.

**Code Quality co-reviewer rule**: Code Quality reviewer is additionally selected as a co-reviewer in the following cases:

1. **Code block co-reviewer**: When `.md` files matching Prompt Engineer patterns contain fenced code blocks (` ```bash `, ` ```sh `, ` ```yaml `, etc.) in the diff, Code Quality is added alongside Prompt Engineer. This ensures embedded code snippets receive code quality review.
2. **Sole reviewer guard**: When exactly 1 reviewer has been selected after all Phase 2.3 detection rules, Code Quality is automatically added as a co-reviewer. This prevents single-reviewer blind spots (cross-file inconsistency, missing updates). Does not activate when 2+ reviewers are already selected, or when Code Quality is already the sole reviewer (fallback).

**Emoji usage policy**: Emojis are used only for the following visibility purposes. Individual skill file Findings output must not use emojis:
- Unified report header (`📜 rite レビュー結果`)
- Work memory identifier (`📜 rite 作業メモリ`)
- Important warning display (`⚠️ 矛盾する指摘を検出`)

**Language policy**: Section headings use English; descriptions and notes use Japanese. Pattern descriptions in tables may use Japanese for brevity.

## Finding Quality Policy

All reviewers must follow these quality standards when reporting findings. These are detailed in each skill file's "Finding Quality Guidelines" section.

> **Reference**: See [Finding Examples](./references/finding-examples.md) for concrete Few-shot examples of good findings, findings that should NOT be reported, and borderline judgment cases.

### Observed Likelihood Gate + Fail-Fast First (全 reviewer 共通)

> **Reference**: [`agents/_reviewer-base.md`](../../agents/_reviewer-base.md) の "Observed Likelihood Gate" / "Fail-Fast First" 節と [`references/severity-levels.md`](../../references/severity-levels.md#impact--observed-likelihood-matrix) の Impact × Likelihood Matrix を必ず参照すること。

**Observed Likelihood Gate**:

- 指摘事項化の必要条件は (1) Confidence ≥ 80 + (2) Likelihood ≥ Demonstrable + (3) revert test pass の **3 ゲート同時充足**
- Demonstrable の立証範囲は **diff 適用後のコードベース全体**（既存 + 本 PR 追加）
- 立証手段は 4 種 (`existing_call_site` / `new_call_site` / `entrypoint_connection` / `runtime_observation`) のいずれか。`内容` 列に `Likelihood-Evidence: <label> <location>` の literal prefix を必ず記載（詳細は `agents/_reviewer-base.md` の "Demonstrable: proof of burden" 節）
- Hypothetical は降格（**例外カテゴリ**: security / database (migration) / devops (infra) / dependencies の 4 reviewer のみ Hypothetical でも severity 維持可能）
- Grep 失敗だけで Hypothetical 扱いにしない。dynamic dispatch / hook / framework convention / 設定駆動ルーティングはエントリポイント接続で Demonstrable 立証可

**Fail-Fast First**:

- fallback (null 返却 / default 値 / catch swallow / retry-and-give-up) を推奨する **前に** `throw` / `raise` / 再 throw を必ず検討
- 既存の error boundary に到達できる経路があれば throw を選ぶ
- skill 側 (各 reviewer の `.md`) に「fallback 許容条件」が明示されている場合のみ fallback 推奨可
- project convention と衝突する可能性がある場合は `/rite:wiki:query <keyword>` で Wiki を必須参照し、Wiki に許容パターンが記録されていればそれを尊重
- reviewer 自身が fallback 追加を推奨することは silent failure の **共犯行為** とみなされる

### Skeptical Tone Calibration

Before starting your review, adopt the following investigative mindset:

**You are investigating this code under the assumption that it contains problems.** Your job is not to confirm the code works — it is to find where it breaks, where it misleads, or where it silently degrades. Approach every function, every boundary, every implicit assumption as a potential failure point.

However, skepticism is not the same as hostility:
- **Investigate thoroughly** before concluding something is a problem
- **Drop the suspicion** when investigation reveals the code is correct — do NOT manufacture findings to justify your initial assumption
- **Calibrate severity honestly** — a real LOW is better than an inflated MEDIUM

The goal is not to maximize the number of findings. The goal is to ensure that **real problems are never missed because you assumed the code was fine**.

### All Findings Are Mandatory Fixes

**Every finding reported will be treated as a mandatory fix** — there is no auto-defer or gradual relaxation mechanism. The review-fix loop continues until all findings are resolved (0 findings remaining).

This means reviewers must exercise careful judgment about what to report:

| Guideline | Description |
|-----------|-------------|
| **Report Only Substantive Issues** | Only report findings that genuinely improve code quality, correctness, or maintainability |
| **No Nitpicking** | Avoid trivial style preferences, pedantic naming suggestions, or cosmetic issues that do not affect functionality or readability |
| **No Hypothetical Concerns** | Do not report speculative issues ("this might cause problems in the future") without concrete evidence |
| **Consider Fix Cost vs Value** | If the effort to fix exceeds the value gained, do not report it as a finding |

### Principles

| Principle | Description |
|-----------|-------------|
| **No Vague Findings** | Vague findings like "needs confirmation" or "may be an issue" are prohibited |
| **Investigate First** | Investigate before reporting (use Read, Grep, WebSearch, etc.) |
| **Concrete Evidence Only** | Only report findings with concrete facts and evidence |
| **No Finding If Unconfirmed** | Do not report findings that could not be confirmed after investigation |

### Investigation Tools

Reviewers should investigate using these tools before reporting:

| Tool | Purpose |
|------|---------|
| **Read** | Check contents of related files/documents |
| **Grep** | Search patterns within the codebase |
| **Glob** | Explore related files |
| **WebSearch** | Gather information via search queries (CVEs, best practices, multi-source comparison) |
| **WebFetch** | Fetch details from specific URLs (official docs, known references) |

### Examples

**Prohibited (vague):** "May need verification", "Possible security risk", "Might affect performance"

**Required (concrete):** Cite specific evidence from investigation (Grep results, file locations, OWASP references, performance metrics)

### External Claim Awareness

When citing external specifications (library behavior, tool configuration, version compatibility, API behavior, CVE/vulnerability information) in findings, reviewers should follow these guidelines:

| Guideline | Description |
|-----------|-------------|
| **Cite specific versions** | Include the version number when claiming version-specific behavior (e.g., "npm v11.10.0 introduced..." instead of "npm supports...") |
| **Prefer observable facts** | Reference behavior observable in the codebase (package.json versions, config files) rather than general claims about external tools |
| **Flag uncertainty** | If unsure about external behavior, note "要検証" in the recommendation column to signal that fact-checking should prioritize this claim |
| **Avoid speculation** | Do not claim specific library/tool behavior without concrete evidence from investigation or documentation |

**Note**: External specification claims in findings are verified by the Fact-Checking Phase (`review.md` Phase 5 Critic Phase) using WebSearch/WebFetch against official documentation. Claims found to contradict official documentation are removed from the review report and recorded in a dedicated section. Reviewers benefit from accuracy here because contradicted findings are flagged as errors, reducing overall review quality.

## Reviewer Type Identifiers

Mapping of reviewer identifiers (`reviewer_type`) to display names. Update this table when adding new reviewers.

| reviewer_type | 日本語表示名 | Skill File |
|---------------|-------------|------------|
| security | セキュリティ専門家 | `security.md` |
| performance | パフォーマンス専門家 | `performance.md` |
| devops | DevOps 専門家 | `devops.md` |
| test | テスト専門家 | `test.md` |
| api | API 設計専門家 | `api.md` |
| frontend | フロントエンド専門家 | `frontend.md` |
| database | データベース専門家 | `database.md` |
| dependencies | 依存関係専門家 | `dependencies.md` |
| prompt-engineer | プロンプトエンジニア | `prompt-engineer.md` |
| tech-writer | テクニカルライター | `tech-writer.md` |
| code-quality | コード品質専門家 | `code-quality.md` |
| error-handling | エラーハンドリング専門家 | `error-handling.md` |
| type-design | 型設計専門家 | `type-design.md` |

**Note**: This table is the source of truth. `commands/pr/review.md` also references this table. The `code-quality` reviewer is used as a fallback when no other reviewers match (see "No Reviewers Match" section below and `review.md` Phase 3.2), as a co-reviewer for Prompt Engineer files containing fenced code blocks, and as a sole reviewer guard co-reviewer (see "Code Quality co-reviewer rule" above).

## Reviewer Selection Algorithm

### Phase 1: File Pattern Matching

```text
For each changed file:
  1. Match against all reviewer patterns
  2. Collect matching reviewers
  3. Track file count per reviewer
```

### Phase 2: Content Analysis (Optional)

```text
Analyze diff content for:
  - Security keywords (representative): password, token, secret, auth, crypto, hash, encrypt, decrypt, credential, api_key, private_key, cert
  - Performance keywords (representative): cache, async, await, promise, worker
  - Data keywords (representative): query, migration, schema, index, transaction
  - Error handling keywords (representative): try, catch, throw, Error, reject, fallback, finally (JS/TS); set -e, pipefail, trap, || true, || :, 2>/dev/null (Bash)
  - Type design keywords (representative): interface, type, enum, class, struct, readonly, generic
```

**Note**: The above are representative keyword examples. The authoritative keyword list is defined in `commands/pr/review.md` Phase 2.3 ("Security keyword detection" section). Detailed activation patterns are defined in each reviewer skill file (`security.md`, `database.md`, etc.) under the Activation section.

### Phase 3: Select All Matching Reviewers

```text
Select all reviewers that:
  1. Match file patterns from Phase 1
  2. Match content keywords from Phase 2 (if enabled)

No prioritization by file count.
All matching reviewers are selected.
```

### Phase 4: Apply Minimum Limit

```text
Apply constraints from rite-config.yml:
  - min_reviewers: Minimum reviewers to select

Special rules:
  - Security reviewer inclusion depends on rite-config.yml security_reviewer settings (see review.md Phase 3.2)
  - If no reviewers match, use code-quality reviewer as fallback (min_reviewers)
```

**Note**: For detailed mandatory selection conditions for Security Expert, see [`commands/pr/review.md` Phase 3.2 (Reviewer Selection)](../../commands/pr/review.md#32-reviewer-selection).

## Skill Loading Strategy (Progressive Disclosure)

### Metadata Only (Initial)

Return only reviewer list and file counts.

**Data retention approach:**

Claude retains selection results internally for use in subsequent phases. Specifically:

1. **At Phase 2 completion**: Remember the following information
   - List of selected reviewers (reviewer_type)
   - Files assigned to each reviewer
   - Selection rationale
   - Selection type for Security Expert (mandatory / recommended / detected), if selected

2. **Usage in Phase 4**: Embed remembered information into each Task tool's `prompt` parameter

**Note**: No explicit output as JSON or data structures. Information is retained within Claude's conversation context and referenced in the necessary phases.

**Context management strategy:**

For context management during large PR reviews, see [references/context-management.md](./references/context-management.md). Refer to that file as the source of truth for detailed thresholds and guidelines.

### Full Skill Load (On Demand)

Load complete skill file only when reviewer is activated:

```text
Read skill file: {plugin_root}/skills/reviewers/{type}.md
Extract:
  - Review checklist
  - Severity definitions
  - Output format
```

**Example behavior:**

If PR changed files are `src/api/users.ts` and `src/auth/login.ts`:

1. **Phase 1**: Pattern matching identifies API Expert and Security Expert as candidates
2. **Phase 2**: Content analysis detects `auth`, `token` keywords, boosting Security Expert priority
3. **Phase 3**: Select Security Expert and API Expert (2 reviewers)
4. **Phase 4**:
   - Read `skills/reviewers/security.md` via Read tool, embed in Task tool prompt
   - Read `skills/reviewers/api.md` via Read tool, embed in another Task tool prompt
   - Execute both Tasks in parallel

## Generator-Critic Pattern Integration

This skill implements the Generator-Critic pattern for enhanced review quality.

**Phase mapping:**
- **Generator Phase** = `commands/pr/review.md` **Phase 4** (Parallel review execution)
- **Critic Phase** = `commands/pr/review.md` **Phase 5** (Result validation & integration)

### Generator Phase

Each selected reviewer acts as a **Generator**:
1. Receives PR diff and context
2. Applies specialized checklist
3. Produces findings in structured format

### Critic Phase

After all generators complete, a **Critic** phase validates:
1. Cross-check findings across reviewers
2. Identify contradictions
3. Validate severity assessments
4. Produce unified report

### Feedback Loop

If Critic identifies issues:
1. Flag contradicting findings
2. Request clarification from specific generators
3. Produce final reconciled report

## Cross-Validation Logic

Logic to validate and integrate results from multiple reviewers.

See [references/cross-validation.md](./references/cross-validation.md) for details.

### Quick Reference

- Multiple reviewers flag same file/line → severity +1
- Contradiction between reviewers → request user judgment
- All reviewers pass → high-confidence approval

## Output Aggregation

For review result output format, see [references/output-format.md](./references/output-format.md).

### Quick Reference

**Individual Reports:** Each reviewer generates Domain-Specific Analysis + Findings table + Summary

**Unified Report:** Coordinator integrates Overall Assessment + Reviewer Consensus + Cross-Validated Findings

**Findings table format (common):**

| Severity | File:Line | Issue | Recommendation |
|----------|-----------|-------|----------------|
| {level}  | {location}| {WHAT + WHY} | {FIX + EXAMPLE} |

## Error Handling

### Skill File Not Found

```
If skill file missing:
  1. Log warning
  2. Use fallback inline profile
  3. Continue with remaining reviewers
```

### Reviewer Timeout

**Note**: Task tool timeout is managed internally by Claude Code. Users cannot directly specify a `timeout` parameter.

```
If reviewer task exceeds internal timeout:
  1. Task tool returns an error
  2. Mark the reviewer as "incomplete"
  3. Continue with other reviewers' results
  4. Note "{reviewer_type}: タイムアウト" in unified report
```

### No Reviewers Match

When no file patterns match, use code-quality reviewer as fallback. Security Expert inclusion follows `rite-config.yml` settings (see `review.md` Phase 3.2).

```text
If no file patterns match:
  1. Use code-quality reviewer as fallback (min_reviewers)
  2. Apply Security Expert selection rules from rite-config.yml (see review.md Phase 3.2)
  3. Warn user about limited review scope
  4. Suggest manual reviewer selection if needed
```
