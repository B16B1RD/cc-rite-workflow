# Changelog

All notable changes to Rite Workflow will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **tech-writer Critical Checklist concretized** — Added 5 doc-implementation consistency items: `Implementation Coverage`, `Enumeration Completeness`, `UX Flow Accuracy`, `Order / Emphasis Consistency`, and `Screenshot Presence`. Each item carries a verification method (Grep/Read/Glob), and 3 new sample rows have been added to the Prohibited vs Required Findings table from blocks-documentation PR #1137 (#349)
- **internal-consistency.md reference** — New reference file that complements `fact-check.md` (external specs) with an internal-facts verification protocol. Defines 5 Verification Protocol categories, Confidence 80+ gate, severity mapping, and a Cross-Reference section linking it to `tech-writer.md`, `review.md`, and related agent files (#349)
- **Doc-Heavy PR Detection (Phase 1.2.7)** — Automatic detection of documentation-centric PRs (formula: `(doc_files_ratio >= 0.6)` OR `(doc_files_count_ratio >= 0.7 AND total_diff_lines < 2000)`). Excludes rite plugin's own `commands/`, `skills/`, `agents/` `.md` files (prompt-engineer territory). Added optional schema `review.doc_heavy.*` to `rite-config.yml` (#349)
- **Doc-Heavy Reviewer Override (Phase 2.2.1)** — When `{doc_heavy_pr == true}`, promote tech-writer from recommended to mandatory and add code-quality as co-reviewer. Passes `{doc_heavy_pr=true}` flag to tech-writer to activate the 5-category verification protocol defined in `internal-consistency.md` (Implementation Coverage / Enumeration Completeness / UX Flow Accuracy / Order-Emphasis Consistency / Screenshot Presence), makes the `Evidence:` line mandatory on each finding, and triggers the Phase 5.1.3 Doc-Heavy post-condition check in `review.md` (#349)
- **`/rite:pr:fix` accepts PR URL / comment URL directly** — Extended `fix.md` Arguments table to 3 forms (pr_number / pr_url / comment_url). Phase 1.0 Argument Parsing uses regex to route input, and Phase 1.2 gains a target_comment_id branch that parses findings directly from an external review tool's comment URL (e.g. `/verified-review`) and feeds them into the fix loop (#349)

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
- Review quality improvements — Confidence Calibration sort order, E2E auto-create flow, Phase 7 Source C consistency, multiple comment precision fixes (#313, #315, #317, #337)

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
- Added Defense-in-Depth flow-state updates to Phase 1-3 sub-skills

### Changed

- Abolished `loop_count`/`max_iterations`/`loop-limit` parameters (#210)
- Completely removed `--loop` parameter from `flow-state-update.sh` (#211)
- Added `hooks/hooks.json` native method with double-execution guard (#194)
- Added 3 quality rules to Phase 4.5 review template (#209)
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

- Phase 5.2.1 checklist auto-check processing added (#170)
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
- `fix.md` Phase 4.5.2 trap integration for `$pr_body_tmp` (#94)
- Fixed work memory progress summary and changed files not updating during review/fix loop (#90)

### Changed

- Progress summary regex hardened for robustness (#92)
- Updated `lint.md` references and added concrete examples to `start.md` (#87)
- `resume.md` counter restoration snippet structured as formal subsection (#88)
- `review.md` Phase 6.2 session info update defense-in-depth intent documented (#93)

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
- Fixed `/rite:issue:start` completion report (Phase 5.6) not executing (#17)
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

[0.3.10]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.3.9...v0.3.10
[0.3.9]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.3.8...v0.3.9
[0.3.8]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.3.7...v0.3.8
[0.3.7]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.3.6...v0.3.7
[0.3.6]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.3.5...v0.3.6
[0.3.5]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.3.4...v0.3.5
[0.3.1]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.2.5...v0.3.0
[0.3.4]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.3.3...v0.3.4
[0.3.3]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.3.2...v0.3.3
[0.3.2]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.3.1...v0.3.2
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
