# Claude Code Rite Workflow

[日本語版はこちら / Japanese](README.ja.md)

> Universal Issue-Driven Development Workflow for Claude Code

[![Version](https://img.shields.io/badge/version-0.3.10-blue.svg)](https://github.com/B16B1RD/cc-rite-workflow/releases/tag/v0.3.10)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

## Why "Rite"?

The name comes from the English word **rite**, meaning "ritual" or "ceremony." Issue-driven development — creating Issues, cutting branches, implementing, reviewing, and merging — is a set of practices that every team should follow as second nature. Rite Workflow embeds these practices as a repeatable ritual so they become the natural way you build software.

## Overview

**Claude Code Rite Workflow** is a Claude Code plugin that provides a complete Issue-driven development workflow. It works with any software development project regardless of language or framework.

### Features

- **Universal**: No dependency on specific tech stacks
- **Automated**: Auto-detection and auto-configuration
- **Customizable**: Flexible configuration via YAML
- **Integrated**: GitHub Projects, notifications (Slack/Discord/Teams)
- **Smart Reviews**: Dynamic multi-reviewer code review with **Doc-Heavy PR Mode** for documentation-centric PRs — see CHANGELOG for the verification protocol details
- **External Review Integration**: `/rite:pr:fix` accepts PR URL or comment URL arguments, so output from external review tools can feed directly into the fix loop
- **Sprint Management**: Optional Iteration/Sprint support with team execution
- **TDD Light Mode**: Generate test skeletons from acceptance criteria before implementation
- **Preflight Check**: Unified pre-execution verification across all commands
- **Local Work Memory**: Compact-resilient work state management with lock/resuming support
- **Implementation Contract**: Structured Issue template format for clear specifications

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
