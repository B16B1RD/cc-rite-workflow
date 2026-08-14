# Claude Code Rite Workflow

> Universal Issue-Driven Development Workflow for Claude Code

[![Version](https://img.shields.io/badge/version-0.12.0-blue.svg)](https://github.com/B16B1RD/cc-rite-workflow/releases/tag/v0.12.0)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

**English** | [日本語](README.ja.md)

## Demo

From Issue to PR — see Rite Workflow turn development into a *rite*. A ~55-second intro (English).

https://github.com/user-attachments/assets/7874c4cf-f50a-4c0c-8925-295d7f37b43d

## Why "Rite"?

The name comes from the English word **rite**, meaning "ritual" or "ceremony." Issue-driven development — creating Issues, cutting branches, implementing, reviewing, and merging — is a set of practices that every team should follow as second nature. Rite Workflow embeds these practices as a repeatable ritual so they become the natural way you build software.

## Overview

**Claude Code Rite Workflow** is a Claude Code plugin that provides an Issue-driven development workflow. It works with any software development project regardless of language or framework.

### Features

- **Universal**: No dependency on specific tech stacks
- **Automated**: Auto-detection and auto-configuration
- **Customizable**: Flexible configuration via YAML
- **Integrated**: GitHub Projects
- **Smart Reviews**: Dynamic multi-reviewer code review with a Doc-Heavy PR Mode that verifies doc-implementation consistency on documentation-centric PRs. See [`plugins/rite/skills/pr-review/references/internal-consistency.md`](plugins/rite/skills/pr-review/references/internal-consistency.md) for the verification protocol
- **External Review Integration**: `/rite:fix` accepts PR URL or comment URL arguments, so output from external review tools can feed directly into the fix loop
- **Iteration Tracking**: Optional GitHub Projects Iteration field integration (auto-assign on `/rite:open`, `--sprint` / `--backlog` filters in `/rite:issue-list`)
- **Local Work Memory**: Compact-resilient work state management with lock/resuming support
- **Implementation Contract**: Structured Issue template format for clear specifications
- **Assumption Surfacing**: `/rite:issue-create` surfaces the assumptions the model implicitly filled in and resolves them before they are locked into the Implementation Contract, asking the user only what cannot be derived from the repository or Wiki. See [docs/SPEC.md](docs/SPEC.md) (Phase 1.5) for the full protocol
- **Experience Wiki**: LLM-driven project knowledge base that auto-ingests review/fix outcomes and injects relevant heuristics at the start of each Issue (opt-out). Stored as an [OKF v0.2](https://github.com/GoogleCloudPlatform/knowledge-catalog)-conformant bundle; see [`plugins/rite/references/wiki-patterns.md`](plugins/rite/references/wiki-patterns.md) for details
- **Sandbox-aware**: `/rite:setup` proactively detects known sandbox environment constraints and surfaces the supported workarounds before they cause a failure

## Installation

Rite Workflow uses a three-step installation: register the marketplace, install the plugin, then reload plugins to activate the new commands.

**Step 1**: Add the marketplace

```bash
/plugin marketplace add B16B1RD/cc-rite-workflow
```

**Step 2**: Install the plugin

```bash
/plugin install rite@rite-marketplace
```

**Step 3**: Reload plugins

```bash
/reload-plugins
```

If `/rite:` commands are still not recognized after this, restart Claude Code.

**Verify installation**: Run `/rite:setup` to confirm the plugin is working.

## Uninstallation

Remove the plugin with:

```bash
/plugin uninstall rite@rite-marketplace
```

This removes the plugin code but leaves behind the artifacts it created in your project. Most are harmless if left in place, but here's the full list with removal steps:

| Artifact | Location | Harmful if left? | Removal |
|----------|----------|-------------------|---------|
| `rite-config.yml` | Committed to your repo | No | `git rm rite-config.yml && git commit -m "chore: remove rite-config.yml"` |
| `.gitignore` entries | Committed (lines added by `/rite:setup`, e.g. `.rite-work-memory/`, `.rite/sessions/`) | No | Manually remove the added lines |
| Remote `wiki` branch | GitHub remote (created by Wiki auto-init) | No | `git push origin --delete <branch>`, where `<branch>` is `wiki.branch_name` in `rite-config.yml` (default `wiki`) |
| Local generated files (gitignored) | `.rite-work-memory/`, `.rite-flow-state*`, `.rite-compact-state*`, `.rite-flow-debug.log`, `.rite-session-id`, etc. | No (untracked) | `rm -rf .rite-work-memory .rite-flow-state* .rite-compact-state* .rite-flow-debug.log .rite-session-id .rite-guidance-shown .rite-plugin-root .rite-initialized-version .rite-settings-hooks-cleaned` |
| `.rite/` internal directories (gitignored, may hold live git worktrees) | `.rite/wiki-worktree/` (Wiki `separate_branch` strategy), `.rite/worktrees/issue-*` (per-session worktrees when `multi_session` is enabled) | Yes if removed with a plain `rm -rf` — this can orphan git worktree metadata and destroy uncommitted work | Check `git worktree list` first; if either path is registered, run `git worktree remove <path>` (confirming no uncommitted changes) then `git worktree prune`. Only after that, remove the rest of `.rite/` with `rm -rf .rite` |
| Legacy hook registration | `.claude/settings.local.json` (only from installs predating native `hooks.json` management) | No, but may error if the plugin is gone | Remove hook entries whose command path points into the rite plugin's `hooks/` directory |

None of these block reinstallation or affect other tooling — clean them up at your convenience.

## Quick Start

```bash
/rite:setup
```

This will:
1. Detect your project type
2. Set up GitHub Projects integration
3. Generate Issue/PR templates
4. Create configuration file

## Commands

| Command | Description |
|---------|-------------|
| `/rite:setup` | Initial setup wizard |
| `/rite:setup --upgrade` | Upgrade existing `rite-config.yml` to the latest schema version |
| `/rite:getting-started` | Interactive onboarding guide |
| `/rite:workflow` | Show workflow guide |
| `/rite:unknowns` | Pre-implementation exploration session (blind-spot pass, brainstorming, throwaway prototypes, interview) — optional, manual only |
| `/rite:issue-list` | List Issues |
| `/rite:issue-create` | Create new Issue |
| `/rite:issue-update` | Update work memory |
| `/rite:issue-close` | Check Issue completion |
| `/rite:issue-edit` | Edit existing Issue interactively |
| `/rite:open` | Start work end-to-end (branch → plan → implement → lint → draft PR) |
| `/rite:iterate` | Loop review ⇄ fix until mergeable |
| `/rite:merge` | Squash-merge the PR |
| `/rite:pr-create` | Create draft PR |
| `/rite:ready` | Mark as Ready for review |
| `/rite:pr-review` | Multi-reviewer review |
| `/rite:fix` | Address review feedback |
| `/rite:cleanup` | Post-merge cleanup |
| `/rite:investigate` | Structured code investigation |
| `/rite:lint` | Run quality checks |
| `/rite:template-reset` | Regenerate templates |
| `/rite:wiki-init` | Initialize Experience Wiki branch and directory layout |
| `/rite:wiki-query` | Query Wiki pages for heuristics matching keywords |
| `/rite:wiki-ingest` | Ingest raw sources (reviews, fixes, Issues) into Wiki pages |
| `/rite:wiki-lint` | Lint Wiki pages for contradictions, staleness, orphans, missing concepts, and broken cross-refs |
| `/rite:recover` | Resume interrupted work |
| `/rite:skill-suggest` | Analyze context and suggest applicable skills |

## Workflow

```
/rite:issue-create → /rite:open (branch → plan → implement → /rite:lint → draft PR)
                  → /rite:iterate (review ⇄ fix loop until mergeable)
                  → /rite:ready → /rite:merge → /rite:cleanup
```

**Note:** The end-to-end flow is split across four single-responsibility commands. `/rite:open <issue>` handles branch creation, implementation, quality checks, and draft PR creation. `/rite:iterate <pr>` loops review and fix until mergeable. `/rite:ready <pr>` flips the PR to Ready for review. `/rite:merge <pr>` performs the squash-merge. If any step is interrupted (e.g. `Context limit reached`), run `/rite:recover` to recover.

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

# Optional: Iteration (GitHub Projects Iteration field) integration
iteration:
  enabled: false  # Set true to enable
```

See [Configuration Reference](docs/CONFIGURATION.md) for all options.

## Troubleshooting

| Issue | Solution |
|-------|----------|
| `Context limit reached` during long-running commands | Run `/clear` then `/rite:recover` to continue |

## Documentation

- [Full Specification](docs/SPEC.md)
- [Configuration Reference](docs/CONFIGURATION.md)

## Requirements

Required:

- [GitHub CLI (gh)](https://cli.github.com/) - Required for GitHub operations (Issues, PRs, Projects)
- [jq](https://jqlang.github.io/jq/) - Required by the hooks and scripts for JSON parsing
- **bash 4+** - Required; hooks and scripts rely on bash 4 features such as associative arrays (`declare -A`) and `mapfile`

Recommended:

- **macOS**: [coreutils](https://formulae.brew.sh/formula/coreutils) (`brew install coreutils`) - The Wiki staleness check calls GNU `date -d`, which macOS's default BSD `date` lacks. Install coreutils and put its `gnubin` on your `PATH` (so `date` resolves to GNU `date`) to enable that check; without it, only that check is skipped

## License

MIT License - See [LICENSE](LICENSE) for details.

## Contributing

Contributions are welcome! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

---

Made with 📜 rite
