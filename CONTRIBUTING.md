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
5. Create a draft PR: `/rite:pr-create`
6. Request review: `/rite:ready`

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

- Skills are written in Markdown
- Hooks are written in Bash with `set -euo pipefail`
- Keep it simple and readable

## Project Structure

```
plugins/rite/
├── skills/           # Skill definitions auto-detected by Claude Code (SKILL.md); invoked as /rite:<name>
│   │                 #   each skill = thin SKILL.md + co-located references/ (entry skills < 500 lines; procedural skills <= 4,000 lines, rationale in references/)
│   ├── (PR lifecycle)  # open, iterate, pr-review, fix, ready, merge, cleanup, run, pr-create
│   ├── (issue ops)     # issue-create, issue-list, issue-update, issue-close, issue-edit, issue-implement
│   ├── (wiki)          # wiki-init, wiki-query, wiki-ingest, wiki-lint
│   ├── (meta/top)      # setup, getting-started, workflow, investigate, learn, lint, recover, skill-suggest, template-reset
│   ├── rite-workflow/  # Orchestration context (state detection, phase routing) + references (coding principles)
│   └── reviewers/      # Reviewer coordinator (selection + tables) + references (per-reviewer profiles in agents/)
├── agents/           # Sub-agent definitions for PR review (9 reviewers + _reviewer-base)
├── hooks/            # Event handler scripts (Bash)
│   ├── scripts/      #   Internal helper scripts (drift-check, bang-backtick-check, lint scanners, etc.)
│   └── tests/        #   Shell script tests
├── templates/        # Issue/PR/completion report templates
├── references/       # gh CLI patterns, GraphQL helpers, severity-levels, etc. (shared across skills)
└── scripts/          # Utility scripts (Issue creation with Projects integration)
```

## Adding a New Reviewer

A reviewer lives in up to 4 places that must stay in sync. Sync between (1)–(3) is machine-checked by `reviewer-registry-drift-check.sh` (run from `/rite:lint` Phase 3.5) with one deliberate gap: a missing **Available Reviewers** row in (2) is indistinguishable from a logic-selected reviewer and is NOT machine-checked (invariant I2 is one-way) — verify edit location 2 against this checklist; (4) is free-form prose covered only by this checklist.

**Edit locations:**

1. **`plugins/rite/agents/{type}-reviewer.md`** (new file) — the reviewer's full profile, injected as the named subagent's system prompt. Two shapes are sanctioned: the heavyweight structure (Role / Core Principles / Detection Process / Detailed Checklist (Expertise Areas, Review Checklist, Severity Definitions, Finding Quality Guidelines) / Output Format — model an existing specialist such as `security-reviewer.md`), or the lens-based structure (persona + first-suspect lenses + output contract, no exhaustive checklist — model `application-reviewer.md`) when the reviewer's checkpoint selection should be delegated to model judgment. Shared principles live in `_reviewer-base.md` and must not be duplicated.
2. **`plugins/rite/skills/reviewers/SKILL.md` — `Available Reviewers` table** — add a row with the display name, agent filename, and activation file patterns. Skip this table only for logic-selected reviewers that have no file patterns (e.g. `code-quality`, the fallback / co-reviewer).
3. **`plugins/rite/skills/reviewers/SKILL.md` — `Reviewer Type Identifiers` table** — add a row mapping the `reviewer_type` slug to the 日本語表示名 and agent filename. The slug MUST equal the agent basename minus `-reviewer.md` (e.g. `security-reviewer.md` → `security`); the drift check verifies this per row.
4. **(Conditional) `plugins/rite/skills/pr-review/SKILL.md`** — only when the reviewer activates on diff content rather than file patterns: add a keyword-detection rule to ステップ 2.3, and extend the ステップ 3.2 selection logic if the reviewer needs special selection rules (mandatory promotion, co-reviewer conditions, etc.).

**Verification:**

```bash
# 3-way sync: agents/ files <-> Available Reviewers <-> Type Identifiers
bash plugins/rite/hooks/scripts/reviewer-registry-drift-check.sh --all

# Regression tests for the registry check itself
bash plugins/rite/hooks/tests/reviewer-registry-drift-check.test.sh
```

`/rite:lint` runs this drift check automatically (Phase 3.5 generic loop) as a non-blocking warning, so a forgotten Type Identifiers row or agent profile surfaces on the next lint (invariants I1/I3) even if you skip manual verification. A forgotten **Available Reviewers** row is the one gap the check cannot see (indistinguishable from a logic-selected reviewer) — verify edit location 2 manually. When touching the Technical Writer row's File Patterns column, note it is the SoT for `doc_file_patterns` (`plugins/rite/skills/pr-review/SKILL.md` ステップ 1.2.7 reads it directly rather than duplicating it), so there is no separate pattern-equivalence check to run.

## Hook Development Guide

Hooks are shell scripts that respond to Claude Code lifecycle events. They are registered via `plugins/rite/hooks/hooks.json` (native plugin hook management) and executed automatically by Claude Code. For legacy setups without `hooks.json`, `/rite:setup` falls back to registering hooks under the `hooks` key in `.claude/settings.local.json` — see the Hook Events and Registration section below.

### Hook Directory Structure

Representative entries (not exhaustive — see the note below):

```
plugins/rite/hooks/
├── session-start.sh / session-end.sh        # SessionStart / SessionEnd lifecycle hooks
├── pre-compact.sh / post-compact.sh          # PreCompact / PostCompact (context compaction)
├── pre-tool-bash-guard.sh                    # PreToolUse (Bash): blocks known-bad command patterns
├── post-tool-wm-sync.sh                      # PostToolUse (Bash): auto-creates local work memory
├── stop-loop-continuation.sh                 # Stop: consume one-shot handoff → re-inject next review↔fix loop / cleanup chain / finalize
├── flow-state.sh                             # Unified per-session flow-state management
├── session-ownership.sh / hook-preamble.sh   # Sourced helper libraries (not registered hooks)
├── work-memory-*.sh / local-wm-update.sh     # Local work memory read / write / lock helpers
├── issue-body-safe-update.sh                 # Safe Issue body fetch / apply with backup
├── wiki-ingest-trigger.sh / wiki-query-inject.sh  # Wiki ingest / query helpers (invoked from skills)
├── _resolve-*.sh / _validate-*.sh            # Internal session-id / state-root helpers
├── hooks.json                                # Native plugin hook registration (Claude Code reads this)
├── scripts/                                  # Internal helper scripts (drift-check, wiki commit, etc.)
└── tests/                                    # Hook test suite
```

> **Note**: This is a representative list, not a complete enumeration. The canonical full list is the `plugins/rite/hooks/` directory itself (and the Plugin Structure section of `docs/SPEC.md`). Only the seven events above — `SessionStart` / `SessionEnd` / `PreCompact` / `PostCompact` / `PreToolUse` / `PostToolUse` / `Stop` — are registered in `hooks.json` (verify with `jq '.hooks | keys[]' plugins/rite/hooks/hooks.json`); every other `.sh` is a sourced helper library or a script invoked from skills. New hooks are added to the directory and `hooks.json`, so this section does **not** need to be updated for each one.

> **Note**: The `Stop` event is registered to `stop-loop-continuation.sh`, which consumes the one-shot `handoff` marker and re-injects the next review↔fix loop command (`/rite:pr-review` ⇄ `/rite:fix`), the `/rite:cleanup` → wiki-ingest → wiki-lint chain continuation, or a terminal completion-notice (see the `handoff` field in `docs/SPEC.md`). This is **not** a stop-*prevention* hook: the legacy blocking `stop-guard.sh`, which made the LLM stall in thinking loops at phase boundaries, was removed, and general workflow halting is now prevented by the per-session flow-state structure and the orchestrator-level scaffolding contract instead. Compact recovery is handled by `pre-compact.sh` + `post-compact.sh` + `session-start.sh`.

### Hook Events and Registration

Rite Workflow uses native Claude Code plugin hook management via `plugins/rite/hooks/hooks.json`. When the plugin is installed (or developed locally), Claude Code reads this file and registers all hooks automatically — no manual edits to `.claude/settings.local.json` are required.

For legacy setups or environments where `hooks.json` is unavailable, `/rite:setup` falls back to registering hooks under the `hooks` key in `.claude/settings.local.json`. The following is a partial example of that fallback format:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [{ "type": "command", "command": "bash /path/to/hooks/session-start.sh" }]
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
| `SessionStart` | Session begins or resumes | JSON via stdin (`cwd`, `source`) |
| `SessionEnd` | Session ends | JSON via stdin |
| `PreCompact` | Before context compaction | JSON via stdin |
| `PostCompact` | After context compaction | JSON via stdin |
| `PreToolUse` | Before a tool is executed | JSON via stdin (tool name via `matcher`) |
| `PostToolUse` | After a tool is executed | JSON via stdin |
| `Stop` | The agent finishes responding (turn end) | JSON via stdin (`stop_hook_active`) |

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
3. Register it in `plugins/rite/hooks/hooks.json` (native plugin hook registration) and — for legacy fallback — in `setup.md` (Phase 4.5.2) so it also lands in `.claude/settings.local.json`
4. Write tests in `plugins/rite/hooks/tests/your-hook.test.sh`

### Hook Conventions

- Always use `set -euo pipefail` at the top
- Read JSON input from stdin using `INPUT=$(cat)` and parse with `jq`
- Use `state-path-resolve.sh` to resolve the state root directory
- For guard hooks (e.g., `pre-tool-bash-guard.sh`): exit code `0` means "allow", non-zero means "block"
- For non-guard hooks (e.g., `session-start.sh`, `session-end.sh`): exit code `0` indicates successful execution
- Use `mktemp` for temporary files with `trap 'rm -f "$tmpfile"' EXIT` for cleanup
- Keep hooks fast — they run on every matching event

## Shell Script Testing

The project uses a lightweight custom test framework (not bats) located in `plugins/rite/hooks/tests/`.

The suite runs on an `ubuntu-latest` + `macos-latest` CI matrix. `.github/workflows/ci.yml`
declares which leg is informational (`continue-on-error`) and which is the **blocking gate**;
whether a red gate actually stops a merge additionally depends on the branch's required
status checks, a repo-admin setting outside that file. Today the blocking gate is the Linux
leg, and the floors in rule 6 below encode that directly as `[ -d /proc ]`. Moving the gate
to macOS would mean revisiting those floor conditions, not just the CI file.

### Prerequisites

Beyond `jq` and bash 4+, the suite needs **either `timeout(1)` or `perl(1)`**. `_test-helpers.sh`
provides a `_timeout` shim that falls back to perl where GNU coreutils is absent (macOS), and it
aborts at source time when neither is available — every caller reads a non-124 exit code as "no
hang", so degrading instead of aborting would turn each hang assertion into a silent pass.

### Running Tests

```bash
# Run all hook tests
bash plugins/rite/hooks/tests/run-tests.sh

# Run all script tests (the second suite; CI runs it as a separate step)
bash plugins/rite/scripts/tests/run-all.sh

# Run a single test
bash plugins/rite/hooks/tests/pre-tool-bash-guard.test.sh
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
# Two steps, not `$(cd "$(mktemp -d)" && pwd -P)`: bash `cd ""` returns 0 without
# changing directory, so a failed mktemp inside that nesting yields the current
# directory — which the cleanup trap below would then delete. The second step is
# what makes path comparisons hold on macOS, where `$TMPDIR` lives under
# `/var/folders` (a symlink into `/private`) while `git rev-parse` and `realpath`
# report the resolved form.
TEST_DIR="$(mktemp -d)" || exit 1
TEST_DIR="$(cd "$TEST_DIR" && pwd -P)" || exit 1
PASS=0
FAIL=0
SKIP=0

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

# Skips are counted, never just printed: a platform-gated suite that reports only
# PASS/FAIL says nothing about how many assertions never ran.
skip() {
  SKIP=$((SKIP + 1))
  echo "  ⏭️ SKIP: $1"
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
echo "Results: $PASS passed, $FAIL failed$( [ "$SKIP" -gt 0 ] && printf ", %s skipped" "$SKIP" )"
[ "$FAIL" -eq 0 ] || exit 1
```

Sourcing `_test-helpers.sh` gives you `pass` / `fail` / `skip` / `assert*` / `print_summary` /
`make_sandbox` / `make_plain_sandbox` / `_timeout` and the `PASS` / `FAIL` / `SKIP` counters, so a
new test usually only needs the test cases themselves. See the header of that file for the full API.

### Writing a New Test

1. Create `plugins/rite/hooks/tests/your-hook.test.sh`
2. Follow the structure above: setup temporary directory, define `pass`/`fail`/`skip` helpers (or
   source `_test-helpers.sh` and get them for free), write test cases
3. Use `mktemp -d` for isolated test environments, then canonicalize the root with
   `pwd -P` as the structure above does — anything that compares the sandbox path
   against a path the code under test resolved breaks on macOS otherwise
   (`make_sandbox` / `make_plain_sandbox` from `_test-helpers.sh` already do this)
4. Clean up with `trap cleanup EXIT`
5. Exit with code 1 if any test fails
6. **Gate platform-dependent cases with `skip` — never a bare `echo`, and never `pass`.**
   A skipped case must appear in the counters so the summary states what did not run.
   `pass "… skipped"` is the worse of the two: it inflates the PASS count *and* clears the
   runner's cross-check, so the run looks fully exercised. When the gate is a capability probe
   (`command -v X`, "does this tool support flag Y") rather than a platform fact, add a floor that
   fails on the blocking gate: a shadowed or missing tool on Linux must not silently drop coverage
   (the existing floors spell this as `[ -d /proc ]` — see `issue-claim.test.sh`).

   **Adding a `skip` to an existing test means fixing its summary line in the same edit.**
   Both runners cross-check each file's `⏭️` markers against the count parsed from its summary,
   and a mismatch fails the **whole suite**, not just that file. The count is read from exactly
   two shapes: `SKIP: N` (what `print_summary` emits) or `Results: …, N skipped` (what the
   template above emits). A test with its own summary line that mentions neither will take the
   suite down the moment it gains its first `skip` — so add the counter to that line too.
7. **Prefer a discriminator over a bare success assertion** when the code under test degrades
   gracefully. If the degraded path emits the same headline result as the healthy one, assert the
   machine-readable enum that distinguishes them (see `stale_check_ok` in `wiki-lint-stale.test.sh`)
   so the case cannot pass without exercising anything.
8. **Give every negative assertion a positive control.** A case that passes when a file is *absent*
   also passes when the fixture never ran; prove the mechanism works first (see TC-5 in
   `timeout-shim.test.sh`).

There are two runners, and CI runs both as separate steps. `plugins/rite/hooks/tests/run-tests.sh`
discovers all `*.test.sh` files in `plugins/rite/hooks/tests/` plus the `test-*.sh` files in
`plugins/rite/hooks/scripts/tests/`; `plugins/rite/scripts/tests/run-all.sh` discovers the
`*.test.sh` files beside it. Both report aggregate results, and **rules 6-8 apply equally to
either** — the skip accounting is the same implementation in both.

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
