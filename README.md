# Claude Code Rite Workflow

[日本語版はこちら / Japanese](README.ja.md)

> Universal Issue-Driven Development Workflow for Claude Code

[![Version](https://img.shields.io/badge/version-0.4.0-blue.svg)](https://github.com/B16B1RD/cc-rite-workflow/releases/tag/v0.4.0)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

## ⚠️ Breaking Changes (v0.4.0)

**v0.4.0 — Cycle-count-based review-fix degradation removed (#557)**: Three configuration keys (`review.loop.severity_gating_cycle_threshold`, `review.loop.scope_lock_cycle_threshold`, `safety.max_review_fix_loops`) are no longer honored. The review-fix loop now terminates only on 0 findings or when one of four **quality signals** fires (fingerprint cycling / root-cause-missing fix / cross-validation disagreement / reviewer self-degraded). Existing users should remove the three keys from `rite-config.yml`; `/rite:lint` will warn until they are removed. See [CHANGELOG](CHANGELOG.md#040---2026-04-17) for the migration guide.

**v0.3 — Named subagent reviewer invocation (#358)**: `/rite:pr:review` invokes reviewer agents as **named subagents** (`rite:{reviewer_type}-reviewer`) instead of `general-purpose`. This gives reviewer discipline stronger system-prompt-level enforcement and activates per-reviewer `model` / `tools` frontmatter. Most noticeable effect: 9 reviewers are pinned to `model: opus`, so users previously running reviews on sonnet will see forced opus upgrade and a cost increase. See [`docs/migration-guides/review-named-subagent.md`](docs/migration-guides/review-named-subagent.md) for rationale, rollback scenarios, and opt-out instructions. Tracked in [#358](https://github.com/B16B1RD/cc-rite-workflow/issues/358).

## Why "Rite"?

The name comes from the English word **rite**, meaning "ritual" or "ceremony." Issue-driven development — creating Issues, cutting branches, implementing, reviewing, and merging — is a set of practices that every team should follow as second nature. Rite Workflow embeds these practices as a repeatable ritual so they become the natural way you build software.

## Overview

**Claude Code Rite Workflow** is a Claude Code plugin that provides a complete Issue-driven development workflow. It works with any software development project regardless of language or framework.

### Features

- **Universal**: No dependency on specific tech stacks
- **Automated**: Auto-detection and auto-configuration
- **Customizable**: Flexible configuration via YAML
- **Integrated**: GitHub Projects, notifications (Slack/Discord/Teams)
- **Smart Reviews**: Dynamic multi-reviewer code review with **Doc-Heavy PR Mode** for documentation-centric PRs. When a PR is detected as doc-heavy, the tech-writer reviewer verifies five doc-implementation consistency categories (Implementation Coverage / Enumeration Completeness / UX Flow Accuracy / Order-Emphasis Consistency / Screenshot Presence) using Grep/Read/Glob. See [`plugins/rite/commands/pr/references/internal-consistency.md`](plugins/rite/commands/pr/references/internal-consistency.md) for the full verification protocol
- **External Review Integration**: `/rite:pr:fix` accepts PR URL or comment URL arguments, so output from external review tools can feed directly into the fix loop
- **Sprint Management**: Optional Iteration/Sprint support with team execution
- **TDD Light Mode**: Generate test skeletons from acceptance criteria before implementation
- **Preflight Check**: Unified pre-execution verification across all commands
- **Local Work Memory**: Compact-resilient work state management with lock/resuming support
- **Implementation Contract**: Structured Issue template format for clear specifications
- **Experience Wiki**: LLM-driven project knowledge base. Auto-ingests review/fix outcomes into topical pages and injects relevant heuristics at the start of each Issue (opt-out)

## Installation

Rite Workflow uses a two-step installation: first register the marketplace, then install the plugin from it.

**Step 1**: Add the marketplace

```bash
/plugin marketplace add B16B1RD/cc-rite-workflow
```

**Step 2**: Install the plugin

```bash
/plugin install rite@rite-marketplace
```

**Verify installation**: Run `/rite:init` to confirm the plugin is working.

## Quick Start

```bash
/rite:init
```

This will:
1. Detect your project type
2. Set up GitHub Projects integration
3. Generate Issue/PR templates
4. Create configuration file

## Commands

| Command | Description |
|---------|-------------|
| `/rite:init` | Initial setup wizard |
| `/rite:init --upgrade` | Upgrade existing `rite-config.yml` to the latest schema version |
| `/rite:getting-started` | Interactive onboarding guide |
| `/rite:workflow` | Show workflow guide |
| `/rite:issue:list` | List Issues |
| `/rite:issue:create` | Create new Issue |
| `/rite:issue:start` | Start work (end-to-end: branch → implementation → PR → review) |
| `/rite:issue:update` | Update work memory |
| `/rite:issue:close` | Check Issue completion |
| `/rite:issue:edit` | Edit existing Issue interactively |
| `/rite:pr:create` | Create draft PR |
| `/rite:pr:ready` | Mark as Ready for review |
| `/rite:pr:review` | Multi-reviewer review |
| `/rite:pr:fix` | Address review feedback |
| `/rite:pr:cleanup` | Post-merge cleanup |
| `/rite:investigate` | Structured code investigation |
| `/rite:lint` | Run quality checks |
| `/rite:template:reset` | Regenerate templates |
| `/rite:sprint:list` | List Sprints (optional) |
| `/rite:sprint:current` | Current sprint details (optional) |
| `/rite:sprint:plan` | Sprint planning (optional) |
| `/rite:sprint:execute` | Execute sprint Issues sequentially (optional) |
| `/rite:sprint:team-execute` | Execute sprint Issues in parallel with worktree-based teams (optional) |
| `/rite:wiki:init` | Initialize Experience Wiki branch and directory layout |
| `/rite:wiki:query` | Query Wiki pages for heuristics matching keywords |
| `/rite:wiki:ingest` | Ingest raw sources (reviews, fixes, Issues) into Wiki pages |
| `/rite:wiki:lint` | Lint Wiki pages for contradictions, staleness, orphans, missing concepts (`missing_concept`), unregistered raw sources (`unregistered_raw`, informational — not added to `n_warnings`), and broken cross-refs |
| `/rite:resume` | Resume interrupted work |
| `/rite:skill:suggest` | Analyze context and suggest applicable skills |

## Workflow

```
/rite:issue:create → /rite:issue:start (Implementation → /rite:lint → /rite:pr:create → /rite:pr:review → /rite:pr:fix) → /rite:pr:ready → Merge → /rite:pr:cleanup
```

**Note:** `/rite:issue:start` executes the complete end-to-end flow: branch creation, implementation, quality checks, draft PR creation, self-review, and review fixes - all in one continuous process. See [Phase 5: End-to-End Execution](docs/SPEC.md#phase-5-end-to-end-execution) for details.

Status Transitions:
```
Todo → In Progress → In Review → Done
 ↑         ↑            ↑         ↑
Create   Start Work   Set Ready  Merged
```

## Configuration

Create `rite-config.yml` in your project root:

```yaml
schema_version: 2

project:
  type: webapp  # generic | webapp | library | cli | documentation

github:
  projects:
    enabled: true

branch:
  base: "main"       # Base branch for feature branches (use "develop" for Git Flow)
  pattern: "{type}/issue-{number}-{slug}"

commit:
  contextual: true

# Optional: Sprint/Iteration management
iteration:
  enabled: false  # Set true to enable
```

See [Configuration Reference](docs/CONFIGURATION.md) for all options.

## Troubleshooting

| Issue | Solution |
|-------|----------|
| `Context limit reached` during long-running commands | Run `/clear` then `/rite:resume` to continue |

## Documentation

- [Full Specification](docs/SPEC.md)
- [Configuration Reference](docs/CONFIGURATION.md)
- [Best Practices Alignment](docs/BEST_PRACTICES_ALIGNMENT.md)
- [日本語ドキュメント](README.ja.md)

## Requirements

- [GitHub CLI (gh)](https://cli.github.com/) - Required for GitHub operations

## License

MIT License - See [LICENSE](LICENSE) for details.

## Contributing

Contributions are welcome! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

---

Made with 📜 rite
