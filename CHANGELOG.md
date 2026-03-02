# Changelog

All notable changes to Rite Workflow will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.1] - 2026-03-03

### Fixed

- Fix Implementation Contract format not applied when creating single Issue for large-scope tasks (#2)
- Fix `/rite:issue:create` interruption after sub-skill return (#6)
- Fix `/rite:issue:start` interruption during end-to-end flow (#7)
- Fix work memory corruption on update — add safety patterns and destruction prevention (#8)

## [0.1.0] - 2026-03-01

### Added

- Initial release of Rite Workflow (rebranded from Zen Workflow)
- Issue-driven development workflow for Claude Code
- Multi-reviewer PR review system with debate phase
- Sprint planning and team execution
- GitHub Projects integration
- Hook-based session management (stop-guard, pre-compact, session lifecycle)
- i18n support (Japanese, English)
- TDD Light mode
- Parallel implementation with git worktree support

[0.1.1]: https://github.com/B16B1RD/cc-rite-workflow/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/B16B1RD/cc-rite-workflow/releases/tag/v0.1.0
