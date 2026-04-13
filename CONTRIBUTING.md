# Contributing to Claude Code Rite Workflow

Thank you for your interest in contributing to Claude Code Rite Workflow!

## Development Setup

1. Clone the repository
2. Install dependencies: `jq` (required by hook scripts)
3. The plugin uses Rite Workflow itself for development (self-hosting)
4. Set `rite@rite-marketplace: false` in `~/.claude/settings.json` to avoid plugin dual-load collision when developing locally

## How to Contribute

### Reporting Issues

- Use GitHub Issues to report bugs or request features
- Check existing issues before creating a new one
- Provide clear reproduction steps for bugs

### Pull Requests

1. Fork the repository
2. Create a feature branch from `develop`: `feat/issue-XXX-description`
3. Make your changes
4. Run quality checks: `/rite:lint`
5. Create a draft PR: `/rite:pr:create`
6. Request review: `/rite:pr:ready`

### Commit Messages

We follow [Conventional Commits](https://www.conventionalcommits.org/):

```
feat: add new feature
fix: fix a bug
docs: update documentation
style: format code
refactor: refactor code
test: add tests
chore: maintenance
```

### Code Style

- Commands are written in Markdown
- Hooks are written in Bash with `set -euo pipefail`
- Keep it simple and readable

## Project Structure

```
plugins/rite/
├── commands/         # Slash command execution procedures (Markdown)
│   ├── issue/        #   Issue operations (start, create, list, edit, close, update, implement, ...)
│   │   └── completion-report.md  # Completion report format (extracted from start.md)
│   ├── pr/           #   PR operations (create, review, fix, ready, cleanup)
│   │   └── references/  # Assessment rules, archive procedures
│   ├── sprint/       #   Sprint operations (plan, list, current, execute, team-execute)
│   ├── wiki/         #   Experience Wiki operations (init, query, ingest, lint)
│   ├── skill/        #   Skill operations (suggest)
│   ├── template/     #   Template operations (reset)
│   └── ...           #   Other commands (init, lint, resume, workflow, getting-started, investigate)
├── skills/           # Skill definitions auto-detected by Claude Code (SKILL.md)
│   ├── rite-workflow/ #   Main skill + references (coding principles, context management)
│   ├── reviewers/    #   Reviewer skills + review criteria
│   ├── investigate/  #   Code investigation skill
│   └── wiki/         #   Experience Wiki skill (ingest/query/lint heuristics)
├── agents/           # Sub-agent definitions for PR review
├── hooks/            # Event handler scripts (Bash)
│   └── tests/        #   Shell script tests
├── templates/        # Issue/PR/completion report templates
├── references/       # gh CLI patterns, GraphQL helpers
├── scripts/          # Utility scripts (Issue creation with Projects integration)
└── i18n/             # Internationalization (ja.yml, en.yml)
```

## Hook Development Guide

Hooks are shell scripts that respond to Claude Code lifecycle events. They are registered in `.claude/settings.local.json` and executed automatically.

### Hook Directory Structure

```
plugins/rite/hooks/
├── stop-guard.sh             # Stop hook: prevents Claude from stopping during active workflow
├── session-start.sh          # SessionStart hook: re-injects flow state after compact or resume
├── session-end.sh            # SessionEnd hook: saves final state when session ends
├── session-ownership.sh      # Helper: session ownership guard for .rite-flow-state writes
├── pre-compact.sh            # PreCompact hook: saves work memory snapshot before context compaction
├── post-compact.sh           # PostCompact hook: restores state after context compaction
├── pre-tool-bash-guard.sh    # PreToolUse hook (Bash): blocks known-bad Bash command patterns
├── post-tool-wm-sync.sh      # PostToolUse hook (Bash): auto-creates local work memory when missing
├── preflight-check.sh        # Guard script called by commands before execution
├── notification.sh           # Sends notifications to configured channels (Slack, Discord, Teams)
├── hook-preamble.sh          # Shared preamble sourced by hooks (env, logging, state path)
├── local-wm-update.sh        # Self-resolving wrapper for local work memory file updates
├── work-memory-update.sh     # Shared helper for local work memory atomic writes
├── work-memory-lock.sh       # mkdir-based lock/unlock for issue-level work memory access
├── issue-comment-wm-sync.sh  # Sync local work memory to Issue comment backup
├── state-path-resolve.sh     # Resolves root directory for rite state files
├── cleanup-work-memory.sh    # Deterministic cleanup of local work memory files
├── flow-state-update.sh      # Atomic .rite-flow-state create/patch/increment operations
├── issue-body-safe-update.sh # Safe Issue body fetch/apply with backup and validation
├── wiki-ingest-trigger.sh    # Hook: trigger Wiki ingest on review/fix/close events
├── wiki-query-inject.sh      # Hook: inject Wiki heuristics at start/review/fix/implement
├── workflow-incident-emit.sh # Emit workflow incident sentinel for auto Issue registration (#366)
├── work-memory-parse.py      # YAML frontmatter parser for work memory files
├── hooks.json                # Native plugin hook registration (managed by Claude Code plugin system)
└── tests/                    # Test scripts
```

> **Note**: Context pressure monitoring hooks (previously `context-pressure.sh`, `post-compact-guard.sh`) were retired in PR #481 / commit 77f0c49. Stop/compact recovery is now handled by `stop-guard.sh` + `pre-compact.sh` + `post-compact.sh` + `session-start.sh` exclusively.

### Hook Events and Registration

Rite Workflow uses native Claude Code plugin hook management via `plugins/rite/hooks/hooks.json`. When the plugin is installed (or developed locally), Claude Code reads this file and registers all hooks automatically — no manual edits to `.claude/settings.local.json` are required.

For legacy setups or environments where `hooks.json` is unavailable, `/rite:init` falls back to registering hooks under the `hooks` key in `.claude/settings.local.json`. The following is a partial example of that fallback format:

```json
{
  "hooks": {
    "Stop": [
      {
        "matcher": "",
        "hooks": [{ "type": "command", "command": "bash /path/to/hooks/stop-guard.sh" }]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [{ "type": "command", "command": "bash /path/to/hooks/pre-tool-bash-guard.sh" }]
      }
    ]
  }
}
```

Available hook events:

| Event | Trigger | Input |
|-------|---------|-------|
| `Stop` | Claude attempts to stop responding | JSON via stdin (`cwd`, etc.) |
| `SessionStart` | Session begins or resumes | JSON via stdin (`cwd`, `source`) |
| `SessionEnd` | Session ends | JSON via stdin |
| `PreCompact` | Before context compaction | JSON via stdin |
| `PostCompact` | After context compaction | JSON via stdin |
| `PreToolUse` | Before a tool is executed | JSON via stdin (tool name via `matcher`) |
| `PostToolUse` | After a tool is executed | JSON via stdin |

### Writing a New Hook

1. Create a new script in `plugins/rite/hooks/`:

```bash
#!/bin/bash
# rite workflow - Your Hook Name
# Brief description of what it does
set -euo pipefail

INPUT=$(cat)

CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
if [ -z "$CWD" ] || [ ! -d "$CWD" ]; then
  exit 0
fi

# Your hook logic here
```

2. Make it executable: `chmod +x plugins/rite/hooks/your-hook.sh`
3. Register it in `plugins/rite/hooks/hooks.json` (native plugin hook registration) and — for legacy fallback — in `init.md` (Phase 4.5.2) so it also lands in `.claude/settings.local.json`
4. Write tests in `plugins/rite/hooks/tests/your-hook.test.sh`

### Hook Conventions

- Always use `set -euo pipefail` at the top
- Read JSON input from stdin using `INPUT=$(cat)` and parse with `jq`
- Use `state-path-resolve.sh` to resolve the state root directory
- For guard hooks (e.g., `stop-guard.sh`, `post-compact-guard.sh`): exit code `0` means "allow", non-zero means "block"
- For non-guard hooks (e.g., `session-start.sh`, `notification.sh`): exit code `0` indicates successful execution
- Use `mktemp` for temporary files with `trap 'rm -f "$tmpfile"' EXIT` for cleanup
- Keep hooks fast — they run on every matching event

## Shell Script Testing

The project uses a lightweight custom test framework (not bats) located in `plugins/rite/hooks/tests/`.

### Running Tests

```bash
# Run all tests
bash plugins/rite/hooks/tests/run-tests.sh

# Run a single test
bash plugins/rite/hooks/tests/stop-guard.test.sh
```

### Test File Structure

Test files follow the `*.test.sh` naming convention. Each test file has this structure:

```bash
#!/bin/bash
# Tests for your-hook.sh
# Usage: bash plugins/rite/hooks/tests/your-hook.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/../your-hook.sh"
TEST_DIR="$(mktemp -d)"
PASS=0
FAIL=0

# Prerequisite check
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required but not installed" >&2
  exit 1
fi

cleanup() {
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

pass() {
  PASS=$((PASS + 1))
  echo "  ✅ PASS: $1"
}

fail() {
  FAIL=$((FAIL + 1))
  echo "  ❌ FAIL: $1"
}

# --- Test cases ---

echo "TC-001: Description of test case"
# Setup, execute, assert
if [ "$result" = "expected" ]; then
  pass "TC-001"
else
  fail "TC-001: got $result"
fi

# --- Summary ---
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
```

### Writing a New Test

1. Create `plugins/rite/hooks/tests/your-hook.test.sh`
2. Follow the structure above: setup temporary directory, define `pass`/`fail` helpers, write test cases
3. Use `mktemp -d` for isolated test environments
4. Clean up with `trap cleanup EXIT`
5. Exit with code 1 if any test fails

The test runner (`run-tests.sh`) automatically discovers all `*.test.sh` files and reports aggregate results.

## Worktree Workflow

When working on parallel implementations, Rite Workflow supports `git worktree` to give each agent an independent working directory.

### Configuration

In `rite-config.yml`:

```yaml
parallel:
  enabled: true
  max_agents: 3
  mode: "worktree"           # "shared" (default) or "worktree"
  worktree_base: ".worktrees" # Base directory for worktrees
```

### How It Works

1. The orchestrator creates a branch for the Issue
2. For each parallel task, a worktree is created:
   ```bash
   git worktree add .worktrees/{issue}/{task} -b {branch}/{task} {branch}
   ```
3. Each agent works in its own worktree directory (Read/Edit/Write only, no git operations)
4. The orchestrator validates each worktree (tests + lint)
5. The orchestrator merges results: `git merge --no-ff {task-branch}`
6. Worktrees are cleaned up: `git worktree remove {path}`

### Important Constraints

- Only the orchestrator performs git operations (checkout, commit, merge, push)
- Agents use only file tools (Read, Edit, Write, Glob, Grep) within their worktree
- Add `.worktrees/` to `.gitignore` to prevent tracking worktree directories
- Check for stale worktrees from previous runs before creating new ones

### When to Use Worktree Mode

| Scenario | Recommended Mode |
|----------|-----------------|
| Tasks modify different files | `worktree` (safe parallel) |
| Tasks modify the same files | `shared` (sequential) |
| Single-task implementation | Either (no difference) |

For detailed patterns, see `plugins/rite/references/git-worktree-patterns.md`.

## Questions?

Feel free to open an issue for any questions.
