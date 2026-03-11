# Changelog

All notable changes to Rite Workflow will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.1] - 2026-03-12

### Added

- E2E flow context window overflow prevention mechanism (#80)
- Agent delegation Skill tool format in prompts (#83)
- Agent delegation AGENT_RESULT fallback handling (#84)

### Fixed

- Sub-skill transition Claude stop prevention prompt reinforcement (#79)
- Work memory progress summary and changed files update logic (#75)
- Sub-skill transition instructions strengthened in create workflow (#76)
- Hardcoded bash hook paths replaced with `{plugin_root}` for marketplace compatibility (#73)
- Resume counter restoration execution timing and ownership (#85)
- `context-pressure.sh` python3 startup optimization and COUNTER_VAL validation (#86)
- PR command Issue creation GitHub Projects registration (#100)
- Work memory progress summary and changed files update section independence from checklist update (#104)
- `flow-state-update.sh` `--active` flag support in patch mode (#109)
- `flow-state-update.sh` `--` separator before jq filter in patch mode (#109)
- `fix.md` Phase 4.5.2 trap integration for `$pr_body_tmp` (#94)
- Review/fix loop work memory progress summary and changed files update (#90)

### Changed

- Progress summary regex hardened for robustness (#92)

### Documentation

- `lint.md` inaccurate reference fix and `start.md` concrete examples (#87)
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

[0.2.0]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.1.3...v0.2.0
[0.1.3]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/B16B1RD/cc-rite-workflow/releases/tag/v0.1.0
