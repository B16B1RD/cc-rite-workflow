# Changelog

All notable changes to Rite Workflow will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

<!--
Phase number policy: Entries describe changes at the feature-name level, not
internal `Phase X.Y.Z` implementation identifiers. Phase numbers inside
`review.md` / `fix.md` / `start.md` may be renumbered between releases, so
CHANGELOG entries must remain stable across such refactors. When a change
genuinely needs locational precision, prefer referencing the file name
(e.g. `review.md`) over internal phase numbers. See Issue #352 for the
rationale and Keep a Changelog 1.1.0 "Guiding Principles" for conventions.
-->

## [Unreleased]

## [1.0.0] - 2026-04-17

### BREAKING CHANGE

- **Cycle-count-based review-fix degradation fully abolished; replaced by 4 quality signals** — **BREAKING CHANGE** (#557)
  - **Removed configuration keys** (three keys from `rite-config.yml`; these keys were never present in `plugins/rite/templates/config/rite-config.yml`):
    - `review.loop.severity_gating_cycle_threshold`
    - `review.loop.scope_lock_cycle_threshold`
    - `safety.max_review_fix_loops`
  - **Removed logic**:
    - `plugins/rite/commands/pr/references/fix-relaxation-rules.md` convergence strategy override table (`severity_gating` / `scope_lock` / `batched` as strategies) and Loop Termination hard-limit row.
    - `plugins/rite/commands/pr/fix.md` Phase 0.4 Convergence Strategy Load (the full block loading `convergence_strategy` from `.rite-flow-state`).
    - `plugins/rite/commands/issue/start.md` Phase 5.4.6 Step 3.5 Review-Fix Loop Hard Limit Check (the `extend (+5) / retry / escalate` 3-choice dialog).
    - `plugins/rite/commands/issue/start.md` Phase 5.4.1.0 cycle-trajectory pattern analysis (Converging / Stalled / Diverging / Oscillating) and the `convergence_strategy` write to `.rite-flow-state`.
  - **New behavior**: the review-fix loop now has exactly two exit paths — (a) 0 findings → `[review:mergeable]`, or (b) any of the **four quality signals** fires → `AskUserQuestion` escalation (`本 PR 内で再試行 / 別 Issue として切り出す / PR を取り下げる / 手動レビューへエスカレーション`).
  - **Four quality signals**:
    1. Same-finding cycling — detected in `start.md` Phase 5.4.1.0 via SHA-1 fingerprints of `file + category + normalized message`. One re-occurrence escalates.
    2. Root-cause-missing fix — detected in `fix.md` Phase 3.2.1 by an LLM-semantic check of the commit body for a `root-cause(scope):` action line (new Contextual Commits action type), a `decision(scope):` line that explicitly names the root cause, or a free-form `Root cause:` / `根本原因:` paragraph. Missing → `AskUserQuestion` 3-option prompt.
    3. Cross-validation disagreement — detected in `review.md` Phase 5.2 when two reviewers report the same `file:line` with severity gap ≥ 2 and debate fails to resolve.
    4. Finding quality gate failure — new `Finding Quality Guardrail` in `_reviewer-base.md` filters bikeshedding / defensive / hypothetical / style-only findings before output; if nothing remains, reviewer self-reports as "degraded" via a `### Reviewer self-assessment` section and escalates.
  - **Finding fingerprint specification**: `sha1(normalize(file_path) + ":" + category + ":" + normalize(message))` with identifier masking and Jaccard token similarity > 0.7 for near-match detection. See `start.md` Phase 5.4.1.0 for the full spec.
  - **Major version bump**: 0.3.10 → 1.0.0 (6 version files synchronized).
  - **Deprecation warning**: `/rite:lint` (Phase 0.5) scans `rite-config.yml` for the three removed keys and emits a warning to stderr + final report when any are found. Keys are silently ignored at runtime.
  - **No cycle-count safety limit (by design)**: There is intentionally no hidden iteration guard. The 4 quality signals are the sole termination mechanism. Reintroducing an iteration counter would contradict the core goal of this release (removing cycle-count-based degradation).

### Migration guide

Existing users with any of the following in `rite-config.yml` should remove those lines:

```yaml
# Remove all three:
review:
  loop:
    severity_gating_cycle_threshold: 5
    scope_lock_cycle_threshold: 7
safety:
  max_review_fix_loops: 7
```

The keys are silently ignored at runtime in v1.0.0 but `/rite:lint` will warn until they are removed. There is no functional replacement — non-convergence is now detected automatically by the four quality signals and no cycle-count threshold needs to be configured.

If you previously relied on `max_review_fix_loops` hitting a hard limit to escape runaway loops, the same safety is now provided by Quality Signal 1 (fingerprint cycling) which fires on the **second** occurrence of any finding — typically faster than any cycle-count threshold would have tripped.

### Changed

- **Review-Fix Cycle Overhaul (Fail-Fast Response + Separate Issue user confirmation + configuration layer)** — **BREAKING CHANGE** (finalizes the #502 rollout, which began with #507 principles doc layer, #508/#504 reviewer exit layer, and #509 Fact-Check layer). Wires the `fix` response layer and configuration layer to the previously-merged principle/exit/fact-check layers.
  - `plugins/rite/commands/pr/fix.md` Phase 2 now begins with a **Fail-Fast Response Principle** section enforcing a 4-item checklist (`throw/raise` propagation / existing error boundaries / not hiding via null-checks / fix the test instead) before deciding a fix approach. Adopting a fallback requires an explicit justification in the commit message; unthinking defensive code is re-flagged at Phase 5 re-review.
  - `plugins/rite/commands/pr/fix.md` Phase 4.3.3 **removes the E2E `AskUserQuestion` skip** — separate-issue creation is now gated by user confirmation **regardless** of caller (E2E `/rite:issue:start` loop or standalone). Options are unified to `retry in current PR / create separate issue / withdraw`, all of which converge to `findings == 0` so the review-fix loop still terminates.
  - `plugins/rite/commands/pr/fix.md` and `plugins/rite/commands/issue/start.md`: the `"severity_gating"` convergence strategy has been **removed**. All PR-originating findings must be addressed within the current PR regardless of severity (本 PR 完結原則). `rite-config.yml` `fix.severity_gating.enabled` is retained as a deprecated compatibility key pinned to `false`. Non-convergence is now handled via the unified `AskUserQuestion` route in fix.md Phase 4.3.3. Use `"batched"` or `"scope_lock"` strategy for non-convergence mitigation instead.
  - `plugins/rite/templates/config/rite-config.yml` adds **config scaffolding keys** (declaration only, runtime wiring tracked as a follow-up): `review.observed_likelihood_gate.*`, `review.fail_fast_first.*`, `review.separate_issue_creation.*`, `fix.fail_fast_response`. The `fix.severity_gating.enabled: false` key is retained as a deprecated compatibility shim and is actively honored (pinned to `false`). **Known limitation**: The non-deprecation scaffolding keys (`observed_likelihood_gate`, `fail_fast_first`, `separate_issue_creation`, `fail_fast_response`) are **not yet referenced by conditional runtime logic** in `commands/` / `agents/` / `skills/` / `hooks/`. The new behavior (Fail-Fast Response Principle, always-confirm separate-issue creation) is hardcoded in `fix.md` Phase 2 / Phase 4.3.3 prose and cannot currently be disabled via config. These keys are provided so users can see the intended configuration surface; wiring them to conditional branches is tracked as a follow-up Issue.
  - `plugins/rite/i18n/{ja,en}/pr.yml` adds four i18n message keys (`review_fail_fast_first_warning`, `review_observed_likelihood_demotion_notice`, `review_separate_issue_user_confirmation_question`, `fix_fail_fast_response_checklist_prompt`) with ja/en parity. **Known limitation**: these keys are **not yet referenced** via the `{i18n:key_name}` lookup in `commands/` / `skills/` / `agents/`. The corresponding prompts in `fix.md` / `review.md` currently embed their text directly. Call-site wiring is tracked as a follow-up.
  - **Migration guide**: Existing users with `fix.severity_gating.enabled: true` in `rite-config.yml` will find the key silently pinned to `false`. Non-convergence is now resolved via the `retry in current PR / create separate issue / withdraw` `AskUserQuestion` at fix.md Phase 4.3.3. Users who relied on automatic severity-based deferral should adopt `"batched"` or `"scope_lock"` strategy. **Opt-out limitation**: the other new config keys (`observed_likelihood_gate`, `fail_fast_first`, `separate_issue_creation`) are **not yet actionable as opt-outs** — the new behavior is currently enforced unconditionally in the prose. To disable any of these, the corresponding prompt sections in `fix.md` / `review.md` must be edited directly until the wiring PR lands. (#506)

- **Named subagent invocation for `/rite:pr:review` reviewers** — **BREAKING CHANGE**. `plugins/rite/commands/pr/review.md` now invokes reviewer agents via `subagent_type: "rite:{reviewer_type}-reviewer"` (scoped named subagent) instead of `subagent_type: general-purpose`. Under named subagent invocation, each reviewer's agent file body (`plugins/rite/agents/{reviewer_type}-reviewer.md`) becomes the sub-agent's **system prompt** automatically, and YAML frontmatter (`model`, `tools`) is honored by the runtime. This gives reviewer discipline stronger system-prompt-level enforcement (rather than user-prompt injection which can be diluted) and activates per-reviewer model pins (9 reviewers pinned to `model: opus`). A reviewer_type → subagent_type mapping table was added for the 13 reviewers. Empirical verification (Issue #356) confirmed that the `rite:` prefix is mandatory in plugin distribution — bare `{reviewer_type}-reviewer` fails agent resolution with `Agent type not found` error. **User impact**: users previously running reviews on sonnet will see forced opus upgrade for 9 reviewers and a corresponding cost increase (opt-out by removing `model: opus` from individual agent frontmatters). See [`docs/migration-guides/review-named-subagent.md`](docs/migration-guides/review-named-subagent.md) for the full migration guide, opus recommendation rationale, and 3 rollback scenarios (all-reviewer resolution failure / tech-writer Bash permission / verification mode output format broken) (#358)
- **`{agent_identity}` placeholder renamed to `{shared_reviewer_principles}` in `review.md`** — **BREAKING CHANGE** (for rite plugin developers editing `review.md` templates). `review.md` now extracts only the shared reviewer principles from `_reviewer-base.md` (Reviewer Mindset / Cross-File Impact Check / Confidence Scoring). Part B (agent-specific identity) extraction was removed entirely — it is no longer needed because the named subagent system prompt delivers agent-specific discipline directly. This is a **hybrid approach**: agent body → system prompt (via named subagent), shared principles → user prompt (via `{shared_reviewer_principles}`). The alternative (inlining shared principles into 13 agent files) was rejected to preserve `_reviewer-base.md` as the single source of truth. The review template sections `## あなたのアイデンティティと検出プロセス` were renamed to `## 共通レビュー原則` to reflect the narrower scope. Preserves the #357 Part A bug fix that ensures Cross-File Impact Check reaches reviewers (#358)
- **Retry classification extended with `subagent resolution failure` in `review.md`** — Added a new retry classification entry for the case where the Task tool cannot resolve a scoped subagent name (e.g., `Agent type 'rite:code-quality-reviewer' not found. Available agents: ...`). Retry: **No**. Action: fail immediately with the scoped name used and the error message. Do NOT silently fall back to `general-purpose` — that would defeat the named subagent quality improvement. If all reviewers fail this way, the orchestrator prompts the user via `AskUserQuestion` (retry / rollback to `general-purpose` temporarily / abort review). Classification detection pattern: Task tool response contains `Agent type '{scoped_name}' not found` (#358)

### Added

- **Workflow incident auto-registration mechanism** — `/rite:issue:start` now auto-detects workflow blockers (Skill load failure, hook abnormal exit, manual fallback adoption) and registers them as Issues to prevent silent loss. New `plugins/rite/hooks/workflow-incident-emit.sh` emits sentinel patterns (`[CONTEXT] WORKFLOW_INCIDENT=1; type=...; details=...; iteration_id=...`) from skill internal failure paths and orchestrator fallback prompts. New workflow incident detection logic in `start.md` detects sentinels via context grep, presents `AskUserQuestion` for confirmation, and calls the existing `create-issue-with-projects.sh` with `Status: Todo / Priority: High / Complexity: S / source: workflow_incident`. Same-type incidents are deduplicated within a session. Failure to register is non-blocking. Default-on via new `workflow_incident:` config section (set `enabled: false` to opt out). 11 unit tests added under `plugins/rite/hooks/tests/workflow-incident-emit.test.sh`. Implements all 10 ACs from #366 (Skill load failure / hook abnormal exit / manual fallback adoption detection, dedupe, default-on, opt-out, recommendation-flow non-interference, non-blocking error handling). Driven by the meta-incident demonstrated in PR #363 cycle 1, where Skill loader bug #365 was silently bypassed via Edit-tool fallback (#366)
- **tech-writer Critical Checklist concretized** — Added 5 doc-implementation consistency items: `Implementation Coverage`, `Enumeration Completeness`, `UX Flow Accuracy`, `Order-Emphasis Consistency`, and `Screenshot Presence`. Each item carries a verification method (Grep/Read/Glob), and 3 new sample rows have been added to the Prohibited vs Required Findings table sourced from an internal documentation-centric PR case study (private repository, organization name redacted) (#349)
- **internal-consistency.md reference** — New reference file that complements `fact-check.md` (external specs) with an internal-facts verification protocol. Defines 5 Verification Protocol categories, Confidence 80+ gate, severity mapping, and a Cross-Reference section linking it to `tech-writer.md`, `review.md`, and related agent files (#349)
- **Doc-Heavy PR Detection** — Automatic detection of documentation-centric PRs in `review.md` (formula: `(doc_lines / total_diff_lines >= 0.6)` OR `(doc_files_count / total_files_count >= 0.7 AND total_diff_lines < 2000)`). Excludes rite plugin's own `commands/`, `skills/`, `agents/` `.md` files **and `.md` / `.mdx` translation documentation under `plugins/rite/i18n/**`** (prompt-engineer territory / dogfooding artifacts; non-Markdown translation resources such as `.yml` / `.json` / `.po` under `plugins/rite/i18n/` are not part of the `doc_file_patterns` numerator in the first place, so the exclusion is a no-op for them). Added optional schema `review.doc_heavy.*` (keys: `enabled`, `lines_ratio_threshold`, `count_ratio_threshold`, `max_diff_lines_for_count`) to `rite-config.yml` (#349)
- **Doc-Heavy Reviewer Override** — When `{doc_heavy_pr == true}`, promote tech-writer from recommended to mandatory and add code-quality as co-reviewer through one of three independent paths so the final state always has ≥2 reviewers:
  - **Normal path**: Add code-quality when fenced code blocks (` ```bash ` / ` ```yaml ` / ` ```python ` etc.) are detected in the diff. Pure-prose PRs do **not** trigger this path.
  - **Fail-safe path**: When the diff scan itself fails (`git diff` IO error, grep IO error, etc.), code-quality is added regardless of whether fenced blocks were detected, to preserve verification strength when the detection signal is unavailable.
  - **Fallback path**: When no fenced blocks are detected and the Doc-Heavy override produced no addition, the sole-reviewer guard adds code-quality as a fallback in the next phase.

  Passes `{doc_heavy_pr=true}` flag to tech-writer to activate the 5-category verification protocol defined in `internal-consistency.md` (Implementation Coverage / Enumeration Completeness / UX Flow Accuracy / Order-Emphasis Consistency / Screenshot Presence), makes the `Evidence:` line mandatory on each finding, and triggers the Doc-Heavy post-condition check in `review.md` (#349)
- **`/rite:pr:fix` accepts PR URL / comment URL directly** — `/rite:pr:fix` now accepts PR URL or comment URL arguments in addition to PR number, allowing findings from external review tools (e.g. `/verified-review`) to be parsed directly into the fix loop. Accepted URL formats include trailing paths (`/files`), query strings (`?tab=files`), and fragment identifiers (`#diff-...`) — all are normalized on argument ingest. Comments must contain a markdown table with at least 4 columns (with optional 5th `confidence` column). See `plugins/rite/commands/pr/fix.md` argument-parsing sections for the full argument spec, header detection keywords, and severity alias mapping (#349)
- **`[fix:pushed-wm-stale]` output pattern** — `/rite:pr:fix` now emits `[fix:pushed-wm-stale]` when the work memory update soft-failed. Firing conditions map 1:1 to the reason table in `commands/pr/fix.md` — each natural-language phrase below annotates its corresponding `reason` label. See the reason table for the complete list of `reason` values:
  - `current_body` empty → `current_body_empty`
  - `issue_number` not found → `issue_number_not_found`
  - PATCH 4xx/5xx → `patch_failed`
  - `pr_body` grep IO error → `pr_body_grep_io_error` (+ `mktemp_failed_pr_body_grep_err` for its stderr tempfile)
  - branch grep IO error → `branch_grep_io_error` (+ `mktemp_failed_branch_grep_err`)
  - `gh api comments` fetch failure → `gh_api_comments_fetch_failed` (+ `mktemp_failed_gh_api_err`)
  - Python script unexpected exit (generic) → `python_unexpected_exit_$py_exit`
  - `git diff` failure (Python sentinel detection) → `python_sentinel_detected` (reserved exclusively for `GIT_DIFF_FAILED_SENTINEL` match via `sys.exit(2)`)
  - work memory body corruption detected → `wm_body_empty_or_too_short` / `wm_header_missing` / `wm_body_too_small`
  - mktemp failure → `mktemp_failed_*` family (`mktemp_failed_pr_body_tmp`, `mktemp_failed_body_tmp`, `mktemp_failed_tmpfile`, `mktemp_failed_files_tmp`, `mktemp_failed_history_tmp`, `mktemp_failed_diff_stderr_tmp`, etc.)

  The `git diff` failure path also routes through `WM_UPDATE_FAILED=1; reason=python_sentinel_detected` (via Python `sys.exit(2)` and bash `exit 1`). The bash `exit 1` only kills the current bash invocation, but the retained `WM_UPDATE_FAILED=1` flag survives in the conversation context — the soft-failure evaluation still runs, detects the flag via row 2 of the evaluation-order table, and emits `[fix:pushed-wm-stale]` (NOT `[fix:error]`). The hard fail-fast design ensures the PATCH is silently rejected, but the `[fix:pushed-wm-stale]` output pattern is the correct caller-facing signal (see `commands/pr/fix.md` evaluation order and `reason` table for the authoritative flow). Callers (`/rite:issue:start` review-fix loop) **must not** silently treat `[fix:pushed-wm-stale]` as `[fix:pushed]`; instead, they must surface a warning via `AskUserQuestion` and let the user decide whether to continue with stale work memory or pause for manual recovery. See `commands/pr/fix.md` caller semantics for the full contract (#349)

### Fixed

- **`wiki-query-inject.sh` origin/wiki fallback** — `/rite:wiki:query` now reads Wiki content via `origin/{wiki_branch}` when the local `wiki` branch does not exist (fresh clone / separate worktree). Previously `git show "${wiki_branch}:.rite/wiki/index.md"` used the bare branch name and failed with `fatal: invalid object name 'wiki'` when only `origin/wiki` was available locally, causing `/rite:wiki:query` to silently return empty context after `/rite:pr:cleanup` on another worktree. Uses the same ref-selection pattern as `cleanup.md` Phase 4.W.1 Step 2 and `wiki-growth-check.sh`. Negative case (neither local nor origin) continues to emit the existing `WARNING: wiki branch not found` and exit 0 (non-blocking). Also adds `wiki_ingest_push_failed` sentinel emission to `cleanup.md` Phase 4.W.3 when `wiki-worktree-commit.sh` reports `push=failed` (rc=4 path inside ingest), so `origin/wiki` divergence becomes observable in the incident layer while preserving loss-safe cleanup continuation. Additionally restores the `wiki_ingest_push_failed` incident type that `plugins/rite/hooks/workflow-incident-emit.sh` was missing from its `--type` whitelist — all existing callers in `pr/review.md`, `pr/fix.md`, and `issue/close.md` that emit this type were silently falling through to the `hook_abnormal_exit` fallback branch, so the dedicated `wiki_ingest_push_failed` sentinel defined in `issue/start.md` Phase 5.4.4.1 was never actually emitted in practice since PR #529 (#555)
- **Part A extraction bug in `review.md`** — Fixed Part A section extraction from `_reviewer-base.md` that was dropping `## Cross-File Impact Check` (everything between `## Reviewer Mindset` and `## Confidence Scoring`). Extraction now covers all sections from document start to `## Input` heading (exclusive), enabling the 5 mandatory cross-file consistency checks (deleted/renamed exports, changed config keys, changed interface contracts, i18n key consistency, keyword list consistency) to actually reach reviewer agents for the first time (#357)
- **tools/model frontmatter drift in reviewer agents** — Removed `tools:` frontmatter from all 13 reviewer agents (`api`, `code-quality`, `database`, `dependencies`, `devops`, `error-handling`, `frontend`, `performance`, `prompt-engineer`, `security`, `tech-writer`, `test`, `type-design`) and `model: sonnet` from 4 reviewers (`code-quality`, `error-handling`, `performance`, `type-design`). Previously these fields were ignored at runtime (reviewers are invoked via `subagent_type: general-purpose`), but would have silently broken when the named subagent migration completes (tech-writer would lose Bash and break Doc-Heavy PR Mode; 4 reviewers would regress to sonnet for opus users). The 9 remaining reviewers retain `model: opus` as an explicit high-quality review pin (intentionally kept; opus was already the runtime-effective model and removing the pin would have regressed them to session default which may be sonnet). Related `docs/SPEC.md` / `docs/SPEC.ja.md` Agent File Format section updated to mark `tools` as optional (inherit) and the Current Agents table updated to reflect the 4 reviewers as `inherit` (#357)
- **Verification-mode post-condition check added** — `review.md` now adds a post-condition check (child of the Verification Mode Findings Collection logic) that validates each reviewer in `verification` mode emits the `### 修正検証結果` table. On initial detection, a per-reviewer retry (via the reviewer invocation Task tool) is attempted with strict verification template instructions; on persistent absence, `verification_post_condition: error` is set, the overall assessment is promoted to `修正必要` (unified with the escalation chain labels — `要修正` is a reviewer-level label and is not used for overall assessment promotion), and all findings from the non-compliant reviewer are treated as blocking. Classification vocabulary is `passed` / `warning` / `error` (unified with `doc_heavy_post_condition`). Retained flags `verification_post_condition` and `verification_post_condition_retry_count` (per-reviewer dict) are registered in the retained flags list and displayed in the verification mode template. Prevents silent pass when a reviewer skips verification output (#357)
- **`commands/pr/fix.md` reason-table drift** — Expanded the `reason` table to cover all 28 `WM_UPDATE_FAILED` reasons actually emitted in the work memory update paths (previously only 12 were listed, 16 were missing). The eval-order table row 2 now defers to "reason 表のいずれか" instead of enumerating a subset, eliminating the double-drift problem. DoD verification (manually executed): `comm -3 <(grep -oE 'WM_UPDATE_FAILED=1; reason=[a-z_][a-z_0-9]*' plugins/rite/commands/pr/fix.md | sed 's/.*reason=//' | sort -u) <(awk '/^\*\*`reason` フィールド/{in_table=1;next} in_table && /^\*\*/{in_table=0} in_table && /^\| `[a-z_]/{match($0, /`[a-z_][a-z_0-9]*[^`]*`/); print substr($0, RSTART+1, RLENGTH-2)}' plugins/rite/commands/pr/fix.md | sed 's/\$.*//' | sort -u)` returns empty (28 WM_UPDATE_FAILED reasons in emits exactly match the 28 entries in the reason table). The awk pattern is scoped to the `**\`reason\` フィールド` section to avoid false positives from other tables in `fix.md` (#357, absorbed from PR #350 C2)

## [0.3.10] - 2026-04-04

### Changed

- Review-fix loop overhaul — bash error-handling detection, existing CRITICAL visibility, first-pass rule improvements (#325)
- Sole reviewer guard + Step 6 sub-checks extension to eliminate blind spots in single-reviewer scenarios (#333)
- Reviewer co-selection expanded — code-quality reviewer now co-selected for code blocks in .md files (#330)
- prompt-engineer-reviewer detection scope expanded — Content Accuracy, List Consistency, Design Logic Review (#327)
- Stale Cross-References detection step coverage added to Step 7 (#336)
- Verification mode disabled by default + context-pressure phase condition branching (#322)
- i18n Sprint key sections merged + en/ja other.yml duplicate sections normalized (#318, #320)
- Hook scripts unified to `echo | jq` syntax (#341)

### Fixed

- Hook script jq extraction robustness — CWD fallback, pre-tool-bash-guard fallback, context-pressure.sh silent abort prevention (#334, #338, #342)
- Review quality improvements — Confidence Calibration sort order, E2E auto-create flow, recommendation-flow Source C consistency, multiple comment precision fixes (#313, #315, #317, #337)

## [0.3.9] - 2026-04-03

### Added

- Reviewer foundation — `{agent_identity}` extraction, `_reviewer-base.md` shared principles, 4 core agents (security, code-quality, prompt-engineer, tech-writer) + confidence_threshold config (#292)
- Reviewer expansion — 7 remaining agents rebuilt + 2 new reviewers (error-handling, type-design) (#293)
- `schema_version` introduction + automatic upgrade mechanism for `rite-config.yml` (#285)

### Fixed

- Removed deprecated `commit.style` code examples from all documentation and project-type templates (#300, #302, #304, #305, #306)
- Updated config examples in documentation to `schema_version: 2` format (#303)
- Enforced sub-agent invocation in verification mode re-review (#299)
- Auto-create Issues from recommendation items marked as "separate Issue" (#297)
- Reset `error_count` to 0 on `flow-state-update.sh` patch mode to prevent stale circuit breaker (#295)

## [0.3.8] - 2026-04-01

### Added

- Fact-Checking Phase for PR review — verifies external specification claims against official documentation via WebSearch/WebFetch (#275)
- context7 MCP tool integration as optional verification method for fact-checking (`review.fact_check.use_context7`, default: off) (#278)

### Fixed

- Added `.rite-initialized-version` and `.rite-settings-hooks-cleaned` to `.gitignore` (#274)

## [0.3.7] - 2026-04-01

### Changed

- Reviewer findings now include WHY + EXAMPLE structure for more actionable fix guidance (#268)

## [0.3.6] - 2026-03-27

### Added

- Sprint Contract — per-step verification criteria for implementation phases (#260)
- Evaluator calibration — few-shot examples and skeptical tone for reviewers (#261)
- Post-Step Quality Gate — self-check after each implementation step (#262)
- Context reset strategy enhancement — stronger context management across phases (#263)

## [0.3.5] - 2026-03-27

### Added

- `/rite:investigate` skill — structured code investigation with Grep→Read→Cross-check 3-phase process (#249)
- `investigation-protocol.md` reference for lightweight code investigation across all workflow phases (#249)
- `investigate.codex_review.enabled` option in `rite-config.yml` to make Codex cross-check optional (#249)

### Fixed

- Migrated legacy hooks from `settings.local.json` to native `hooks.json` management (#247)

## [0.3.4] - 2026-03-20

### Changed

- Unified plugin path resolution to a version-independent method — `session-start.sh` now writes resolved path to `.rite-plugin-root`, command files read it via `cat` (#241)

## [0.3.3] - 2026-03-19

### Fixed

- Fixed SessionStart hook error when executing `/clear` in marketplace-installed environments (#235)

## [0.3.2] - 2026-03-17

### Fixed

- `/rite:init` now detects existing hooks in `settings.json` to prevent conflicts (#229)

### Changed

- Removed unused settings and added missing settings in `rite-config.yml`

### Docs

- Added AskUserQuestion enforcement and branch deletion steps to release skill

## [0.3.1] - 2026-03-17

### Fixed

- Verification mode now triggers full review instead of partial review (#223)
- Removed `{session_id}` placeholder and unified to auto-read pattern (#221)
- Strengthened sub-skill return interruption prevention in `create.md` (#205)
- Fixed Issue comment work memory backup sync (#204)
- Fixed bash redirection error when `.rite-session-id` is absent
- Fixed `session-start.sh` not resetting other sessions' active state on startup/clear (#206)
- Removed graduated relaxation logic from review-fix loop — all findings now require fix (#202)
- Made reviewer confirmation and Ready confirmation unskippable in e2e flow (#198)
- Used patch method for flow-state deactivation (#195)
- Fixed blocking/non-blocking remnants in review template output examples
- Fixed path resolution inconsistency with `--if-exists` pattern
- Added Defense-in-Depth flow-state updates to early-phase sub-skills

### Changed

- Abolished `loop_count`/`max_iterations`/`loop-limit` parameters (#210)
- Completely removed `--loop` parameter from `flow-state-update.sh` (#211)
- Added `hooks/hooks.json` native method with double-execution guard (#194)
- Added 3 quality rules to the review template (#209)
- Abolished trap in `session-start.sh` and improved debug logging

### Docs

- Updated review-fix loop documentation (#212)

## [0.3.0] - 2026-03-16

### Added

- Session ownership system for multi-session conflict prevention (#174, #175, #176, #177, #178, #179)
  - Session ownership helper functions and flow-state overwrite protection (#175)
  - Session ownership support in `session-start.sh` (#176)
  - Session ownership support in `session-end.sh` and `stop-guard.sh` (#177)
  - Session ownership support in `wm-sync`, `pre-compact`, `context-pressure` hooks (#178)
  - `--session {session_id}` parameter added to all command files + `resume.md` ownership transfer (#179)

### Fixed

- Checklist auto-check processing added to `start.md` (#170)
- Branch existence check now uses output string instead of exit code (#172)
- Issue create output order improved — next steps moved to end (#168)
- PostToolUse hook auto-syncs Issue comment work memory on phase change (#167)
- `review.md` READ-ONLY constraint added to normalize review-fix loop (#165)
- Review → fix loop branch instructions rewritten to imperative conditional (#163)
- `session-end.sh` diagnostic log added for other session exit path
- Debug output remnants removed from hooks (#174)

### Changed

- Issue comment work memory update logic refactored to script for deterministic execution (#161)

### Docs

- Added `git branch --list` DO NOT warning to `gh-cli-commands.md` (#181)

## [0.2.5] - 2026-03-16

### Added

- Contextual Commits integration: structured action lines in commit body for decision persistence (#144)
  - Configuration and reference documentation (`commit.contextual` setting) (#145, #150)
  - Action line generation in `implement.md` commit flow (#146, #151)
  - Action line generation in `pr/fix.md` review-fix commit flow (#147, #152)
  - `/rite:issue:recall` command for searching contextual commit history (#148, #153)
  - Action line generation in `team-execute.md` parallel commit flow (#149, #156)

### Fixed

- Edge case handling in `recall.md`: base branch fallback, grep metacharacter escaping, max-count consistency (#154, #155)
- Added GitHub Projects integration and status transitions to release skill

## [0.2.4] - 2026-03-14

### Fixed

- Work memory implementation plan step states now batch-updated on commit (#138)
- Applied Defense-in-Depth pattern to create-decompose.md (#127)
- Unified legacy state name `blocked` to `recovering` in tests
- Added develop branch recovery procedure for auto-deletion after merge

### Changed

- Clarified Defense-in-Depth pattern ordering and removed redundancy (#126)
- Introduced PostCompact hook for automated auto-compact recovery (#133)

### Improved

- Enhanced prompt quality for create sub-skill (#128)

## [0.2.3] - 2026-03-13

### Fixed

- Reinforced auto-continuation after sub-skill return in create workflow (#125)

## [0.2.2] - 2026-03-12

### Added

- Marketplace hook path auto-update on version upgrade (#117)

### Fixed

- Parent Issue Projects status auto-update not executing (#115)

## [0.2.1] - 2026-03-12

### Added

- E2E flow context window overflow prevention mechanism (#80)
- Agent delegation Skill tool format in prompts (#83)
- Agent delegation AGENT_RESULT fallback handling (#84)

### Fixed

- Reinforced prompt to prevent Claude from stopping during sub-skill transitions (#79)
- Clarified work memory progress summary and changed files update logic (#75)
- Sub-skill transition instructions strengthened in create workflow (#76)
- Hardcoded bash hook paths replaced with `{plugin_root}` for marketplace compatibility (#73)
- Clarified resume counter restoration execution timing and ownership (#85)
- `context-pressure.sh` python3 startup optimization and COUNTER_VAL validation (#86)
- Ensured GitHub Projects registration when creating Issues via PR command (#100)
- Separated work memory progress summary and changed files update from checklist update (#104)
- `flow-state-update.sh` `--active` flag support in patch mode (#109)
- `flow-state-update.sh` `--` separator before jq filter in patch mode (#109)
- `fix.md` work memory trap integration for `$pr_body_tmp` (#94)
- Fixed work memory progress summary and changed files not updating during review/fix loop (#90)

### Changed

- Progress summary regex hardened for robustness (#92)
- Updated `lint.md` references and added concrete examples to `start.md` (#87)
- `resume.md` counter restoration snippet structured as formal subsection (#88)
- `review.md` session info update defense-in-depth intent documented (#93)

## [0.2.0] - 2026-03-05

### Added

- Plugin version check on session startup (#68)

### Changed

- Replaced Zen/禅 references with rite in SPEC and command docs (#67)

## [0.1.3] - 2026-03-05

### Changed

- Offloaded deterministic processing to shell scripts (`flow-state-update.sh`, `issue-body-safe-update.sh`), replacing 24 inline jq + atomic write patterns across 8 files
- Extracted completion report section from `start.md` into `completion-report.md`
- Extracted assessment rules from `review.md` into `references/assessment-rules.md`
- Extracted archive procedures from `cleanup.md` into `references/archive-procedures.md`
- Optimized SKILL.md description to active style and compressed table to pointer + summary format
- Added Why-driven rationale to MUST/CRITICAL directives across 7 major commands
- Added Input/Output Contract sections to 7 major commands

## [0.1.2] - 2026-03-04

### Fixed

- Fixed `work-memory-init` validation script missing else branch for success case (#48)
- Fixed work memory comment being overwritten by API error response (#47)
- Fixed unnecessary hooks unregistered message during rite workflow execution (#46)
- Fixed `stop-guard.sh` trap missing EXIT signal (#39, #41)
- Fixed `stop-guard.sh` compact_state stop block failure (#22)
- Fixed `session-start.sh` jq error handling issues (#18, #20)
- Fixed `/rite:issue:start` completion report not executing (#17)
- Fixed parent Issue Projects status not updating from Todo to In Progress (#15)
- Fixed `/rite:issue:start` Bash command errors (#13)
- Fixed find cleanup pattern to be mktemp suffix-length independent (#44)
- Fixed `ready.md` output pattern and defense-in-depth for Mandatory After (#32)
- Applied work memory update safety patterns consistently across all commands (#50)
- Fixed stop-guard and post-compact-guard deadlock race condition (#30)
- Fixed `/clear → /rite:resume` duplicate guidance message (#27)

### Changed

- Refactored `stop-guard.sh` grep -A20 hard-coded value to awk section extraction (#35)
- Refactored `pre-compact.sh` echo|jq pipe to here-string (#34)
- Refactored `stop-guard.sh` subshell optimization (#24)
- Unified PID-based temp file naming to mktemp with fallback (#38)

### Removed

- Removed rebrand mentions from v0.1.0 changelog entries (#52)

## [0.1.1] - 2026-03-03

### Fixed

- Fixed Implementation Contract format not applied when creating single Issue for large-scope tasks (#2)
- Fixed `/rite:issue:create` interruption after sub-skill return (#6)
- Fixed `/rite:issue:start` interruption during end-to-end flow (#7)
- Fixed work memory corruption on update with safety patterns and destruction prevention (#8)

## [0.1.0] - 2026-03-01

### Added

- Initial release of Rite Workflow
- Issue-driven development workflow for Claude Code
- Multi-reviewer PR review system with debate phase
- Sprint planning and team execution
- GitHub Projects integration
- Hook-based session management (stop-guard, pre-compact, session lifecycle)
- i18n support (Japanese, English)
- TDD Light mode
- Parallel implementation with git worktree support

[1.0.0]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.3.10...v1.0.0
[0.3.10]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.3.9...v0.3.10
[0.3.9]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.3.8...v0.3.9
[0.3.8]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.3.7...v0.3.8
[0.3.7]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.3.6...v0.3.7
[0.3.6]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.3.5...v0.3.6
[0.3.5]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.3.4...v0.3.5
[0.3.4]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.3.3...v0.3.4
[0.3.3]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.3.2...v0.3.3
[0.3.2]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.3.1...v0.3.2
[0.3.1]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.2.5...v0.3.0
[0.2.5]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.2.4...v0.2.5
[0.2.4]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.2.3...v0.2.4
[0.2.3]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.2.2...v0.2.3
[0.2.2]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.1.3...v0.2.0
[0.1.3]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/B16B1RD/cc-rite-workflow/releases/tag/v0.1.0
