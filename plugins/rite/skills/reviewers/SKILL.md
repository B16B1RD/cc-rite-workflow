---
name: reviewers
description: |
  rite workflow のレビュアー選定コーディネータ: 変更ファイルパターンから起動すべき専門 reviewer
  agent（Security / Application / DevOps / Test / Dependencies / Prompt Engineer /
  Tech Writer / Code Quality / Error Handling）の選定テーブルと横断ルールを提供する。
  /rite:pr-review から Read でのみ参照される（ユーザー直接起動も Skill ツール invoke もされない）。
  汎用の「コードレビュー」ヘルパーではなく、その語では auto-activate しない。
user-invocable: false
disable-model-invocation: true
---

# Reviewer Skills - Main Coordinator

**Structure**: `SKILL.md` is the coordinator for the reviewer group (selection logic + the cross-cutting tables below). Each expert reviewer is a named subagent defined in `agents/{reviewer_type}-reviewer.md` (e.g., `agents/security-reviewer.md`); that file is the reviewer's full profile and is injected as the sub-agent's system prompt at review time. Profiles take one of two shapes: the heavyweight structure (Role / Core Principles / Detection Process / Detailed Checklist (Expertise Areas, Review Checklist, Severity Definitions, Finding Quality Guidelines) / Output Format) used by the 8 specialist reviewers, or the lens-based structure (persona + first-suspect lenses + output contract, no exhaustive checklist) used by `application-reviewer.md` — the consolidation deliberately delegates detailed checkpoint selection to model judgment.

## Overview

This skill coordinates the multi-reviewer PR review process using specialized expert agents.

## Invocation

This skill is loaded via `Read` during `/rite:pr-review` command execution; it does not auto-activate.

## Available Reviewers

This table is the **source of truth** for reviewer file patterns (used by `skills/pr-review/SKILL.md` ステップ 2 for selection). The `Agent` column names the named subagent spawned for each reviewer. When adding a reviewer, follow CONTRIBUTING.md "Adding a New Reviewer" — rows present here and the `agents/` ⇔ Reviewer Type Identifiers sync are machine-checked by `plugins/rite/hooks/scripts/reviewer-registry-drift-check.sh` (invoked from `/rite:lint` Phase 3.5); a **missing** row in this table is the one gap the check cannot see (indistinguishable from a logic-selected reviewer), so verify it against the CONTRIBUTING.md checklist.

| Reviewer | Agent | File Patterns (Primary) |
|----------|------------|-------------------------|
| Security Expert | `security-reviewer.md` | `**/security/**`, `**/auth/**`, `auth*`, `crypto*`, `**/middleware/auth*` |
| Application Expert | `application-reviewer.md` | `**/api/**`, `**/routes/**`, `**/handlers/**`, `**/controllers/**`, `**/services/**`, `openapi.*`, `swagger.*`, `**/*.css`, `**/*.scss`, `**/styles/**`, `**/components/**`, `*.jsx`, `*.tsx`, `*.vue`, `**/*.sh`, `**/hooks/**`, `**/db/**`, `**/models/**`, `**/migrations/**`, `**/*.sql`, `prisma/**`, `drizzle/**`; `**/*.ts`, `**/*.rs`, `**/*.go` with `interface`, `type`, `enum`, `class`, `struct` |
| DevOps Expert | `devops-reviewer.md` | `.github/**`, `Dockerfile*`, `docker-compose*`, `*.yml` (CI), `Makefile` |
| Test Expert | `test-reviewer.md` | `**/*.test.*`, `**/*.spec.*`, `**/test/**`, `**/__tests__/**`, `jest.config.*`, `vitest.config.*`, `cypress/**`, `playwright/**` |
| Dependencies Expert | `dependencies-reviewer.md` | `package.json`, `*lock*`, `requirements.txt`, `Pipfile`, `go.mod`, `Cargo.toml` |
| Prompt Engineer | `prompt-engineer-reviewer.md` | `commands/**/*.md`, `skills/**/*.md`, `agents/**/*.md`, and corresponding `.mdx` (`commands/**/*.mdx`, `skills/**/*.mdx`, `agents/**/*.mdx`) |
| Technical Writer | `tech-writer-reviewer.md` | `**/*.md` (excluding `commands/**/*.md`, `skills/**/*.md`, `agents/**/*.md`), `**/*.mdx` (excluding `commands/**/*.mdx`, `skills/**/*.mdx`, `agents/**/*.mdx`), `docs/**`, `documentation/**`, `**/README*`, `CHANGELOG*`, `CONTRIBUTING*`, `*.rst`, `*.adoc`, `i18n/**/*.md`, `i18n/**/*.mdx` (excluding `plugins/rite/i18n/**` — rite plugin's own translations are dogfooding artifacts) |
| Error Handling Expert | `error-handling-reviewer.md` | Files containing `try`, `catch`, `throw`, `Error`, `reject`, `fallback` keywords (JS/TS); `set -e`, `pipefail`, `trap`, `|| true`, `|| :`, `2>/dev/null` keywords (Bash); `**/*.sh` |

**Note**: The Technical Writer row's File Patterns column is the **SoT** for `doc_file_patterns`. `plugins/rite/skills/pr-review/SKILL.md` ステップ 1.2.7 (Doc-Heavy PR Detection) reads this row rather than duplicating the pattern list, so the two can no longer drift apart by construction.

**Code Quality co-reviewer rule**: Code Quality reviewer is additionally selected as a co-reviewer in the following cases:

1. **Code block co-reviewer**: When `.md` files matching Prompt Engineer patterns contain fenced code blocks (` ```bash `, ` ```sh `, ` ```yaml `, etc.) in the diff, Code Quality is added alongside Prompt Engineer. This ensures embedded code snippets receive code quality review.
2. **Sole reviewer guard**: When exactly 1 reviewer has been selected after all Phase 2.3 detection rules, Code Quality is automatically added as a co-reviewer. This prevents single-reviewer blind spots (cross-file inconsistency, missing updates). Does not activate when 2+ reviewers are already selected, or when Code Quality is already the sole reviewer (fallback).

**Emoji usage policy**: Emojis are used only for the following visibility purposes. Individual reviewer Findings output must not use emojis:
- Unified report header (`📜 rite レビュー結果`)
- Work memory identifier (`📜 rite 作業メモリ`)
- Important warning display (`⚠️ 矛盾する指摘を検出`)

**Language policy**: Section headings use English; descriptions and notes use Japanese. Pattern descriptions in tables may use Japanese for brevity.

## Finding Quality Policy

All reviewers follow a single Finding Quality Policy enforced in [`agents/_reviewer-base.md`](../../agents/_reviewer-base.md) and injected into each reviewer's user prompt via the `{shared_reviewer_principles}` extraction (`skills/pr-review/SKILL.md` ステップ 4.5). It covers Reviewer Mindset (healthy skepticism, evidence-based reporting, thoroughness on every cycle), the Observed Likelihood Gate, Fail-Fast First, the Finding Quality Guardrail (filter bikeshedding / defensive / style-only — all findings are mandatory fixes, so reviewers must report only substantive issues), the `Verification:` anchor for recording runtime measurement alongside a finding (orthogonal to the inclusion gates — it records whether the finding is backed by a reproduction or a failing test, and does not change whether the finding may be reported), Confidence Scoring, and External Claim Awareness. Each reviewer's own checklist and Finding Quality Guidelines live in its named-subagent definition (`agents/{reviewer_type}-reviewer.md`).

> **Reference**: See [Finding Examples](./references/finding-examples.md) for concrete Few-shot examples of good findings, findings that should NOT be reported, and borderline judgment cases.

## Reviewer Type Identifiers

Mapping of reviewer identifiers (`reviewer_type`) to display names. Update this table when adding new reviewers (full procedure: CONTRIBUTING.md "Adding a New Reviewer"; row/slug consistency is machine-checked by `reviewer-registry-drift-check.sh`).

| reviewer_type | 日本語表示名 | Agent |
|---------------|-------------|------------|
| security | セキュリティ専門家 | `security-reviewer.md` |
| application | アプリケーション専門家 | `application-reviewer.md` |
| devops | DevOps 専門家 | `devops-reviewer.md` |
| test | テスト専門家 | `test-reviewer.md` |
| dependencies | 依存関係専門家 | `dependencies-reviewer.md` |
| prompt-engineer | プロンプトエンジニア | `prompt-engineer-reviewer.md` |
| tech-writer | テクニカルライター | `tech-writer-reviewer.md` |
| code-quality | コード品質専門家 | `code-quality-reviewer.md` |
| error-handling | エラーハンドリング専門家 | `error-handling-reviewer.md` |

**Note**: This table is the source of truth. `skills/pr-review/SKILL.md` also references this table. The `code-quality` reviewer is used as a fallback when no other reviewers match (see "No Reviewers Match" section below and `skills/pr-review/SKILL.md` ステップ 3.2), as a co-reviewer for Prompt Engineer files containing fenced code blocks, and as a sole reviewer guard co-reviewer (see "Code Quality co-reviewer rule" above).

## Legacy Reviewer Type Aliases

api / frontend / performance / database / type-design の 5 reviewer は `application` に統合された。旧 reviewer_type が入力として現れた場合（rite-config.yml の設定値、過去のレビュー結果 JSON の `reviewer` フィールド、ユーザーの手動指定など）は、**silent skip せず** WARNING を表示して統合先 type で代替実行する:

| Legacy reviewer_type | 統合先 |
|---------------------|--------|
| `api` | `application` |
| `frontend` | `application` |
| `performance` | `application` |
| `database` | `application` |
| `type-design` | `application` |

表示形式: `WARNING: reviewer type '{legacy_type}' は 'application' に統合されました。application-reviewer で代替実行します`（対応表は CHANGELOG の移行表を参照）。

## Reviewer Selection Algorithm

### Phase 1: File Pattern Matching

```text
For each changed file:
  1. Match against all reviewer patterns
  2. Collect matching reviewers
  3. Track file count per reviewer
```

**"changed file" の定義は review cycle で変わる**（`skills/pr-review/SKILL.md` ステップ 1.2.4 の `REVIEW_CYCLE_SCOPE` marker が決める。パターン表そのものは変わらない — 変わるのは表に照合させる入力だけ）:

| `REVIEW_CYCLE_SCOPE` | Phase 1 の "changed file" |
|---|---|
| `full`（cycle 1 / fail-safe） | PR 全体の変更ファイル |
| `incremental`（cycle 2+） | 前回レビュー起点からの fix diff (`git diff --name-only {cycle_base_sha}..HEAD`) |

`incremental` では、Phase 1 の結果に**前サイクルで blocking を出した reviewer を `selection_type: mandatory` として合流**させる（Phase 5 が落とさないことを保証しているのは `mandatory` のみのため）。設計根拠は [`skills/pr-review/references/cycle-scope.md`](../pr-review/references/cycle-scope.md)。

### Phase 2: Content Analysis (Optional)

```text
Analyze diff content for:
  - Security keywords (representative): password, token, secret, auth, crypto, hash, encrypt, decrypt, credential, api_key, private_key, cert
  - Performance keywords (representative): cache, async, await, promise, worker
  - Data keywords (representative): query, migration, schema, index, transaction
  - Error handling keywords (representative): try, catch, throw, Error, reject, fallback, finally (JS/TS); set -e, pipefail, trap, || true, || :, 2>/dev/null (Bash)
  - Type design keywords (representative): interface, type, enum, class, struct, readonly, generic
```

**Note**: The above are representative keyword examples. The authoritative keyword list is defined in `skills/pr-review/SKILL.md` ステップ 2.3 ("Security keyword detection" section), and the authoritative file patterns are the Available Reviewers table above.

### Phase 3: Select All Matching Reviewers

```text
Select all reviewers that:
  1. Match file patterns from Phase 1
  2. Match content keywords from Phase 2 (if enabled)

No prioritization by file count.
All matching reviewers are selected.
(Phase 5 narrows this set down to max_reviewers when the count exceeds the cap.)
```

### Phase 4: Apply Minimum Limit

```text
Apply constraints from rite-config.yml:
  - min_reviewers: Minimum reviewers to select

Special rules:
  - Security reviewer inclusion depends on rite-config.yml security_reviewer settings (see skills/pr-review/SKILL.md ステップ 3.2)
  - If no reviewers match, use code-quality reviewer as fallback (min_reviewers)
```

**Note**: For detailed mandatory selection conditions for Security Expert, see [`skills/pr-review/SKILL.md` ステップ 3.2 (Reviewer Selection)](../../skills/pr-review/SKILL.md#32-reviewer-selection).

### Phase 5: Apply Maximum Limit (Cost Control)

Review cost scales with reviewer count (each reviewer runs a fact_check and debate phase — see `rite-config.yml` `review.fact_check` / `review.debate`), so an upper bound caps the per-review cost. Apply this phase **after** Phase 4 so the cap never violates the minimum floor or drops a reviewer whose selection_type is `mandatory`.

```text
Apply constraints from rite-config.yml:
  - max_reviewers: Maximum reviewers to spawn (default: 6)

Relevance ordering (used only when narrowing is required):
  1. matched file count per reviewer (from Phase 1 "Track file count per reviewer") — higher is more relevant
  2. tie-break by selection_type: mandatory > recommended > detected > normal
       (`normal` = a reviewer selected purely by pattern/content match, with no mandatory/recommended/detected
        promotion; the three named types are defined in `skills/pr-review/SKILL.md` ステップ 3.2 Selection Type table)
  3. final tie-break by Available Reviewers table order (higher row = higher priority)

Cap logic:
  - selected count <= effective_max  -> keep all (no narrowing, no omission display)
  - selected count >  effective_max  -> sort by the relevance ordering above, keep the top effective_max, drop the rest
      * NEVER drop a reviewer whose selection_type is `mandatory` (Security Expert when `mandatory: true`,
        a Doc-Heavy-promoted tech-writer, or a fenced-block-triggered code-quality co-reviewer — see ステップ 2.2.1 / 3.2).
        If a mandatory reviewer would fall outside the top N, drop the next-lowest non-mandatory reviewer instead.
      * If the mandatory reviewer count alone already exceeds effective_max, keep ALL mandatory reviewers
        (intentionally exceed the cap) and drop non-mandatory reviewers down to zero. Never drop a mandatory
        reviewer to satisfy the cap — the cost cap yields to the mandatory guarantee, not the other way around.
      * NEVER reduce below the effective floor = max(min_reviewers, sole_reviewer_guard_floor). The Phase 4
        min_reviewers floor wins, AND the ステップ 2.3 sole-reviewer guard's floor wins: when that guard raised
        the set to 2 to avoid a single-reviewer blind spot, the cap keeps at least 2. A `max_reviewers` below
        that floor is clamped up to it (the guard's blind-spot protection is not overridable by the cost cap) —
        emit the ステップ 3.2.1 WARNING so the clamp is not silent.
  - MUST display each dropped reviewer's name and matched file count (silent capping is prohibited)

effective_max resolution (config validation):
  - max_reviewers unset            -> default 6
  - max_reviewers non-numeric      -> WARNING, fall back to default 6
  - max_reviewers < min_reviewers  -> WARNING, min_reviewers takes priority (effective_max = min_reviewers)
  - otherwise                      -> effective_max = max_reviewers
  - complexity lane bound          -> when COMPLEXITY_LANE == light (Issue Complexity XS / S, resolved by
        `skills/pr-review/SKILL.md` ステップ 1.3.2), take the tighter of the two:
        effective_max = min(effective_max, complexity_max) where complexity_max = 3.
        Applied BEFORE the final clamp, so the floors below still win. When COMPLEXITY_LANE is
        `full` (M / L / XL) or the lane could not be resolved, this line is a no-op and the
        resolution is byte-identical to the pre-lane behavior.
  - final clamp (all paths)        -> effective_max = max(effective_max, min_reviewers)
        (guarantees effective_max >= min_reviewers even for the unset/non-numeric paths when min_reviewers > 6)

When matched count <= effective_max (e.g. the default 6 with fewer matches), the selection is
identical to the pre-cap behavior (backward compatible).
```

**Complexity lane bound rationale**: The `light` lane narrows the *upper* bound only — it never
overrides the `mandatory` guarantee or the effective floor, both of which are evaluated after it.
A `light` review can therefore still spawn more than 3 reviewers (4 mandatory reviewers stay 4).
Placing the bound here rather than in a post-cap filter keeps `effective_max` resolution in one
place; a second narrowing step would have to re-implement the floors and the mandatory protection.
Why the bound is 3, why the lane boundary is `{XS, S}`, and why no new floor is introduced:
[complexity-lane.md](../pr-review/references/complexity-lane.md#reviewer-上限を-phase-5-に置く理由).

The dropped-reviewer list and the pre-spawn summary are rendered by `skills/pr-review/SKILL.md` ステップ 3.2.1 (cap application) / ステップ 3.3 (Confirm Reviewers).

## Selection Result Retention

Return only the reviewer list and file counts; Claude retains the selection internally for later phases (no JSON / data-structure output).

**Data retention approach:**

1. **At Phase 2 completion**: Remember the list of selected reviewers (reviewer_type), the files assigned to each, the selection rationale, and the Security Expert selection type (mandatory / recommended / detected) if selected.
2. **Usage in Phase 4**: Embed the remembered information into each Task tool's `prompt` parameter (the `skills/pr-review/SKILL.md` ステップ 4.5 review-instruction template).

**Context management strategy:** For context management during large PR reviews, see [references/context-management.md](./references/context-management.md) as the source of truth for thresholds and guidelines.

**Reviewer profile loading**: There is no separate skill-file load step. Each reviewer's full profile (heavyweight structure for the 8 specialists, or the lens-based structure for `application-reviewer.md` — see **Structure** above) is its named-subagent system prompt (`agents/{reviewer_type}-reviewer.md`), injected automatically when `skills/pr-review/SKILL.md` ステップ 4.3 spawns `rite:{reviewer_type}-reviewer`. The ステップ 4.5 user prompt carries only the per-review inputs (diff, spec, shared principles, Wiki context).

## Generator-Critic Pattern Integration

This skill implements the Generator-Critic pattern for enhanced review quality.

**Phase mapping:**
- **Generator Phase** = `skills/pr-review/SKILL.md` **ステップ 4** (Parallel review execution)
- **Critic Phase** = `skills/pr-review/SKILL.md` **ステップ 5** (Result validation & integration)

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

| Severity | Scope | File:Line | Issue | Recommendation |
|----------|-------|-----------|-------|----------------|
| {level}  | {scope} | {location}| {WHAT + WHY} | {FIX + EXAMPLE} |

The `Scope` column accepts `current-pr` / `follow-up` / `nit-noted` (schema 1.1.0+). See [_reviewer-base.md Scope Assignment Flowchart](../../agents/_reviewer-base.md#scope-assignment-flowchart) for assignment rules and the [Severity × Scope Matrix](../../references/severity-levels.md#severity--scope-matrix) for forbidden combinations.

## Error Handling

### Reviewer Subagent Resolution Failure

```
If `rite:{reviewer_type}-reviewer` cannot be resolved (named subagent missing):
  1. Log warning
  2. Skip that reviewer
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

When no file patterns match, use code-quality reviewer as fallback. Security Expert inclusion follows `rite-config.yml` settings (see `skills/pr-review/SKILL.md` ステップ 3.2).

```text
If no file patterns match:
  1. Use code-quality reviewer as fallback (min_reviewers)
  2. Apply Security Expert selection rules from rite-config.yml (see skills/pr-review/SKILL.md ステップ 3.2)
  3. Warn user about limited review scope
  4. Suggest manual reviewer selection if needed
```
