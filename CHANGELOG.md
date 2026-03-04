# Changelog

All notable changes to Rite Workflow will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.2] - 2026-03-04

### Fixed

- Fix `work-memory-init` validation script missing else branch for success case (#48)
- Fix work memory comment being overwritten by API error response (#47)
- Fix unnecessary hooks unregistered message during rite workflow execution (#46)
- Fix `stop-guard.sh` trap missing EXIT signal (#39, #41)
- Fix `stop-guard.sh` compact_state stop block failure (#22)
- Fix `session-start.sh` jq error handling issues (#18, #20)
- Fix `/rite:issue:start` completion report (Phase 5.6) not executing (#17)
- Fix parent Issue Projects status not updating from Todo to In Progress (#15)
- Fix `/rite:issue:start` Bash command errors (#13)
- Fix find cleanup pattern to be mktemp suffix-length independent (#44)
- Fix `ready.md` output pattern and defense-in-depth for Mandatory After (#32)
- Apply work memory update safety patterns consistently across all commands (#50)
- Fix stop-guard and post-compact-guard deadlock race condition (#30)
- Fix `/clear → /rite:resume` duplicate guidance message (#27)

### Changed

- Refactor `stop-guard.sh` grep -A20 fixed value to awk section extraction (#35)
- Refactor `pre-compact.sh` echo|jq pipe to here-string (#34)
- Refactor `stop-guard.sh` subshell optimization (#24)
- Unify PID-based temp file naming to mktemp with fallback (#38)

### Removed

- Remove rebrand mentions from v0.1.0 changelog entries (#52)

## [0.1.1] - 2026-03-03

### Fixed

- Fix Implementation Contract format not applied when creating single Issue for large-scope tasks (#2)
- Fix `/rite:issue:create` interruption after sub-skill return (#6)
- Fix `/rite:issue:start` interruption during end-to-end flow (#7)
- Fix work memory corruption on update — add safety patterns and destruction prevention (#8)

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

[0.1.2]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/B16B1RD/cc-rite-workflow/releases/tag/v0.1.0
