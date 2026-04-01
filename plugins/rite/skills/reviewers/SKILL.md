---
name: reviewers
description: |
  Coordinates parallel multi-expert PR code review. Activates with /rite:pr:review
  or when user asks for "code review", "PR feedback", "security check", "review
  my changes", "レビューして", "PRレビュー", "コードチェック", "セキュリティ確認",
  "変更を確認", "コードレビュー". Spawns specialized reviewers (Security, API,
  Database, DevOps, Frontend, Test, Dependencies, Prompt Engineer, Tech Writer)
  based on changed file patterns. Produces unified findings with severity levels.
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
| Prompt Engineer | `prompt-engineer.md` | `commands/**/*.md`, `skills/**/*.md` |
| Technical Writer | `tech-writer.md` | `**/*.md` (excluding commands/skills), `docs/**`, `README*` |

**Note**: The table above shows representative patterns only. Each skill file's Activation section is the source of truth.

**Emoji usage policy**: Emojis are used only for the following visibility purposes. Individual skill file Findings output must not use emojis:
- Unified report header (`📜 rite レビュー結果`)
- Work memory identifier (`📜 rite 作業メモリ`)
- Important warning display (`⚠️ 矛盾する指摘を検出`)

**Language policy**: Section headings use English; descriptions and notes use Japanese. Pattern descriptions in tables may use Japanese for brevity.

## Finding Quality Policy

All reviewers must follow these quality standards when reporting findings. These are detailed in each skill file's "Finding Quality Guidelines" section.

> **Reference**: See [Finding Examples](./references/finding-examples.md) for concrete Few-shot examples of good findings, findings that should NOT be reported, and borderline judgment cases.

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

**Note**: This table is the source of truth. `commands/pr/review.md` also references this table. The `code-quality` reviewer is used exclusively as a fallback when no other reviewers match (see "No Reviewers Match" section below and `review.md` Phase 3.2).

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
