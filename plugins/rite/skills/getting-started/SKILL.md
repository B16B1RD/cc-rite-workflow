---
name: getting-started
description: |
  rite workflow の Getting Started ガイド: 導入手順と基本ワークフローを案内する。
  ユーザーが明示的に /rite:getting-started で起動する。auto-activate しない。
  起動: /rite:getting-started
argument-hint: ""
---

# /rite:getting-started

Getting Started guide for rite workflow

---

When this command is executed, run the following phases in order. Phase 4.5 is an **on-demand reference** — display it only when the user asks about running multiple Claude Code sessions in parallel, not during the normal onboarding sweep.

## Phase 1: Display Welcome Message

Display the following welcome message:

```
📜 rite workflow - Getting Started Guide

This guide will help you get started with rite workflow, an Issue-driven
development workflow plugin for Claude Code.

What is rite workflow?
- Issue-driven development automation
- Automated PR creation and review
- Integrated with GitHub Issues and Projects
- Context-aware workflow state management
```

---

## Phase 2: Prerequisites Check

### 2.1 Display Prerequisites

> **罫線の表示幅**: box の右罫線 `│` を揃えるには、全角（East Asian Width `W`/`F`）文字を 2 桁として内側幅を上罫線の `─` 本数に一致させる（`A` Ambiguous は 1 桁）。詳細は [`../../references/box-display-width.md`](../../references/box-display-width.md)。

Display the following checklist:

```
┌─────────────────────────────────────────────────────────────┐
│                     Prerequisites                           │
└─────────────────────────────────────────────────────────────┘

Required:
  ✓ gh CLI version ≥2.x
  ✓ git (any recent version)
  ✓ GitHub repository with Issues enabled
  ✓ GitHub authentication (`/rite:setup` guides login when needed)

Optional:
  ○ GitHub Projects (recommended for workflow visualization)
```

### 2.2 Verify gh CLI Installation

```bash
gh --version
```

Extract the version number and verify it is ≥2.0.0.

**If not installed or version is too old:**

```
⚠️ gh CLI version 2.x or higher is required

Installation instructions:
- macOS: brew install gh
- Linux: https://github.com/cli/cli/blob/trunk/docs/install_linux.md
- Windows: winget install GitHub.cli

After installation, run this guide again.
```

Stop here if the requirement is not met.

### 2.3 Verify GitHub Authentication

```bash
gh auth status
```

**If not authenticated:**

```
⚠️ GitHub authentication required

`/rite:setup` guides you through GitHub login and verifies the required
permissions before continuing. You do not need to run a separate login
command from this guide.
```

Continue the guide; Phase 3 directs the user to `/rite:setup`.

### 2.4 Verify Repository

```bash
gh repo view --json owner,name
```

> **Note (SSH host alias remote)**: origin が `git@github.com-work:owner/repo.git` のような
> SSH host alias の場合、GitHub リポジトリであってもこのコマンドは
> `none of the git remotes configured for this repository point to a known GitHub host` で失敗する。
> その場合は `git remote get-url origin` で owner/repo を確認できれば GitHub リポジトリとして扱ってよい
> （rite の各スキルは `git-remote.sh` による remote URL 直接パースで owner/repo を解決するため動作する。
> canonical: references/gh-cli-patterns.md#ownerrepo-resolution-ssh-host-alias-safe）。

**If not a GitHub repository:**

```
⚠️ This directory is not a GitHub repository

rite workflow requires a GitHub repository with Issues enabled.

`/rite:setup` detects an uninitialized local directory or a repository with no
remote and guides you through initialization, the first commit, repository
creation, and push. You do not need to duplicate those commands here.
```

Continue the guide; Phase 3 directs the user to `/rite:setup`. If a remote is
already configured but cannot be resolved as GitHub, keep the SSH host alias
note above as the troubleshooting path; setup does not propose creating a new
repository for a non-empty remote.

---

## Phase 3: Step-by-Step Walkthrough

### 3.1 Display Workflow Overview

```
Quick Start (3 steps):
  1. Setup (one-time):   /rite:setup
  2. Start an Issue:     /rite:issue-create → /rite:open <番号>
  3. Complete & submit:  /rite:iterate <pr> → /rite:ready <pr> → /rite:merge <pr> → /rite:cleanup

詳細なフロー図とコマンド一覧は /rite:workflow で表示できます。
```

### 3.2 Step 1: Initial Setup

Explain the setup process:

```
┌─────────────────────────────────────────────────────────────┐
│                  Step 1: Initial Setup                      │
└─────────────────────────────────────────────────────────────┘

Run the initialization wizard:
  /rite:setup

What /rite:setup configures:
  ✓ Creates rite-config.yml with project settings
  ✓ Configures GitHub Projects integration (optional)
  ✓ Sets up branch naming conventions
  ✓ Configures iteration settings (optional)
  ✓ Installs workflow hooks for state management

This is a one-time setup. You can reconfigure later by running /rite:setup again.
```

**Upgrading an existing project (`/rite:setup --upgrade`)**

If you have been using rite workflow on this project for a while, the bundled
configuration schema may have moved ahead of your local `rite-config.yml`. In
that case, run the upgrade variant instead of a fresh `/rite:setup`:

```
/rite:setup --upgrade
```

When to run it:

- After updating the rite workflow plugin and seeing a warning that
  `rite-config.yml` schema is outdated. The exact wording differs slightly
  by emitter: `/rite:setup` emits `rite-config.yml のスキーマが古くなっています
  (v{current} → v{latest})。/rite:setup --upgrade でアップグレードできます。`
  and the session-start hook emits a variant ending in
  `/rite:setup --upgrade を実行してください。` Both signal the same situation
- When release notes (`CHANGELOG.md`) announce new
  configuration sections (e.g., `wiki:`, `review.debate:`) that are missing from
  your local `rite-config.yml`
- When the `schema_version` value at the top of your `rite-config.yml` diverges
  from the bundled template in
  `plugins/rite/templates/config/rite-config.yml`

What `/rite:setup --upgrade` does:

  ✓ Creates a timestamped backup (`rite-config.yml.bak.YYYYMMDD-HHMMSS`)
  ✓ Compares your current `schema_version` against the latest template version
  ✓ Shows a preview of changes: deprecated keys to remove, new sections to
    add (including commented-out Advanced sections), and values that will be
    preserved (e.g., `project_number`, `owner`, `branch.base`, `language`)
  ✓ Asks for confirmation via AskUserQuestion before applying schema changes
    on the upgrade path (deprecated-key removal, `schema_version` bump, new
    sections); this single apply/cancel prompt also gates the drift back-add
    items below when a schema upgrade is pending. When the schema is already
    up to date, the short-circuit path back-adds any missing drift — the
    `multi_session` / `wiki:` sections, newly added active sections, and
    missing sub-keys — idempotently and without an additional prompt (the
    preview/confirm step is shown only on the schema-upgrade path)
  ✓ Appends the `wiki:` section if it is absent, so the Wiki
    auto-initialization step of `/rite:setup` can run for existing projects
  ✓ Back-adds the `multi_session:` section with `enabled: true` if it is
    absent, so upgraded projects get the default-on per-session worktree
    behavior; an existing explicit `enabled: false` is preserved
  ✓ Fills in sub-keys that are missing from an active section you already
    have, adding only the absent keys from the template default while
    preserving every existing sibling value you customized
  ✓ Adds any new active top-level section the template introduces, so the
    upgrade keeps pace with newly added defaults
  ✓ Updates `schema_version` to the latest value on success

The upgrade is non-destructive: user-customized values are preserved, and a
backup is created before any edits are made. If your configuration has no
missing drift (all active sections, their sub-keys, and the `multi_session` /
`wiki:` sections are already present) and Wiki is already initialized, the
command makes no changes to `rite-config.yml` itself — it still creates a
timestamped backup, reports "configuration is up to date", then runs the Wiki
auto-initialization idempotency check of `/rite:setup` and displays a final
Wiki status line before exiting.

Check if `rite-config.yml` exists:

```bash
ls rite-config.yml 2>/dev/null || ls .claude/rite-config.yml 2>/dev/null
```

**If it exists:**

```
✅ Already initialized (rite-config.yml found)

You can skip Step 1 and proceed to Step 2.

⚠ Schema may be out of date — if you see the schema-outdated warning
described in the "Upgrading an existing project" section above, or the
top-level `schema_version` in your `rite-config.yml` differs from the
bundled template in `plugins/rite/templates/config/rite-config.yml`, run
`/rite:setup --upgrade` before proceeding to Step 2 to bring the configuration
up to date.
```

**If it does not exist:**

```
⚡ Action Required: Run /rite:setup to set up rite workflow

After setup is complete, return here or proceed directly to working on Issues.
```

### 3.3 Step 2: Create or Start an Issue

```
┌─────────────────────────────────────────────────────────────┐
│              Step 2: Create or Start an Issue               │
└─────────────────────────────────────────────────────────────┘

Option A: Work on an existing Issue
  1. View all open Issues:
     /rite:issue-list

  2. Start working on a specific Issue:
     /rite:open 42
     (Replace 42 with the Issue number)

Option B: Create a new Issue
  1. (Optional) If your idea isn't fully formed yet, explore it first:
     /rite:unknowns <topic>
     (Blind-spot pass, brainstorming, throwaway prototypes, and interview —
      ends with an exploration summary you can feed into step 2)

  2. Create an Issue with a description:
     /rite:issue-create Add user authentication

  3. Then start working on the created Issue:
     /rite:open <issue number from step 2>

What happens when you start an Issue:
  ✓ Creates a feature branch (e.g., feat/issue-42-description)
  ✓ Updates Issue status to "In Progress" (if Projects is configured)
  ✓ Initializes work memory for context tracking
  ✓ Implements changes, runs quality checks (/rite:lint), and opens a draft PR
```

### 3.4 Step 3: Complete and Submit

```
┌─────────────────────────────────────────────────────────────┐
│              Step 3: Complete and Submit                    │
└─────────────────────────────────────────────────────────────┘

/rite:open runs quality checks (/rite:lint) and creates a draft PR for you.
After the draft PR is created:

1. Run the review/fix loop until the PR is mergeable:
   /rite:iterate <pr>
   (Multi-reviewer analysis — code quality, security, tests, etc. —
    with fixes applied automatically in a review ⇄ fix loop)

2. When ready for team review:
   /rite:ready <pr>
   (Marks PR as "Ready for review")

3. Merge the PR:
   /rite:merge <pr>

4. Clean up after the merge:
   /rite:cleanup
   (Deletes the branch, closes the Issue, updates Projects status)
```

> **Test-Driven Development (Canon TDD) is on by default.** During implementation
> (`/rite:open` → `/rite:issue-implement`), rite drives a Canon TDD cycle —
> write a test, confirm it fails (Red), make it pass with the minimal change
> (Green), then Refactor — seeded from the Issue's Section 6 Test Specification.
> To turn it off for doc-centric / non-software projects, set `tdd.enabled: false`
> in `rite-config.yml`. When `commands.test` is not configured, the Red/Green test
> runs are skipped automatically while the one-behavior-at-a-time discipline still
> applies.

---

## Phase 4: Common First-Time Issues and Solutions

Display the following troubleshooting guide:

```
┌─────────────────────────────────────────────────────────────┐
│                  Troubleshooting Guide                      │
└─────────────────────────────────────────────────────────────┘

Common Issues and Solutions:

1. "gh: command not found"
   Solution: Install gh CLI (see Prerequisites section above)

2. "Could not resolve to a Repository" /
   "none of the git remotes configured for this repository point to a known GitHub host"
   Solution: Ensure you're in a Git repository that's pushed to GitHub
   Check with: gh repo view
   Note: origin が SSH host alias（git@github.com-work: 等）の場合、gh repo view は
   GitHub リポジトリでも失敗する。git remote get-url origin で確認すること
   （rite の実行手順は git-remote.sh 優先の解決で alias 環境でも動作する）

3. "Projects not found" during /rite:setup
   Solution: Projects is optional. Choose "Skip Projects integration"
   or create a Project manually on GitHub first

4. Branch creation fails in /rite:open
   Solution: Ensure you're on the main/develop branch first
   Check with: git branch --show-current

5. "Context limit reached" during work
   Solution: Use /clear to compact context, then /rite:recover to continue
   The workflow state is preserved and automatically restored

6. PR creation fails
   Solution: Ensure changes are committed and pushed to the feature branch
   Check with: git status

7. Unable to update Issue status
   Solution: Verify Projects integration in rite-config.yml
   Check: projects.enabled and projects.project_number fields

8. Running multiple Claude Code sessions on the same repository
   Solution: multi_session is ON by default (rite-config.yml) — session
   worktrees are created automatically; set enabled: false to opt out
   Ask about running multiple sessions to see the on-demand FAQ with the
   operating rules (start each session from the repo root; keep the main
   checkout on the base branch)
```

---

## Phase 4.5: Multiple Sessions at Once (multi_session) (On Demand)

This phase is **not** part of the normal onboarding sweep. Display this FAQ only
when the user asks about running several Claude Code sessions on the same
repository in parallel (e.g. one terminal per Issue):

```
┌─────────────────────────────────────────────────────────────┐
│              FAQ: Multiple Sessions at Once                 │
└─────────────────────────────────────────────────────────────┘

Q: Can I work on two different Issues in two terminals at the same time?

A: Yes — Worktree Mode is ON by default. In rite-config.yml:

     multi_session:
       enabled: true                   # default true; set false to opt out
       worktree_base: ".rite/worktrees" # session worktrees: issue-{N} subdirs

   With it enabled (the default), /rite:open N creates a per-session Git
   worktree at .rite/worktrees/issue-{N} and enters it via Claude Code's
   EnterWorktree tool, so each session keeps its own working tree and current
   branch. /rite:cleanup exits and removes the worktree after merge.

Operating rules (important):

  • Start every session from the repository ROOT (not inside a worktree).
    /rite:open does the worktree creation + entry for you.

  • If EnterWorktree fails with "not in a git repository" even though .git
    exists and git works (the harness mis-detected the launch directory as
    non-git at startup): RESTART Claude Code from the repository ROOT and
    re-run the same command. The already-created worktree is preserved and
    reused (WT_CASE=reuse on /rite:open, WT_ENSURE=reenter on /rite:recover),
    so nothing is rebuilt. rite never silently falls back to git switch -c.

  • Keep the main checkout on your base branch (rite-config.yml branch.base, e.g. develop).
    rite never moves the main checkout's branch — that is a human-only action,
    and /rite:cleanup's base update (git fetch + git merge --ff-only) only
    runs when the main checkout is actually on the base branch (otherwise it
    warns and skips).

  • Disk cost: each session worktree is a FULL working-tree clone. Build
    environments (node_modules, venv, build caches, etc.) are NOT shared and
    may need rebuilding inside each worktree.

  • Same Issue, twice: an Issue claim (.rite/state/issue-claims/) prevents two
    sessions from starting the SAME Issue. The second session is asked what to
    do (it never silently steals the claim). Claims are always on, even when
    multi_session is off.

  • After a crash / restart: just run /rite:recover — it re-enters the session
    worktree (or rebuilds it from the branch if it was removed) and continues.

  • .rite/worktrees/ must be effectively ignored — a broad .rite/ rule
    suffices (/rite:setup adds an entry only when not already covered;
    /rite:lint warns if it is not ignored while multi_session is enabled).

  • Sandboxed environments: after entering a session worktree, state writes to
    the main checkout (.rite/sessions/, etc.) can be rejected as read-only.
    See ../../references/git-worktree-patterns.md, section "worktree cwd から
    main checkout 配下への書き込みが sandbox の write 許可リストでブロックされる"
    (session worktree から main checkout への書込みは sandbox の許可境界外になり得るため), for the fix (/rite:setup surfaces the same guidance when it
    detects this applies).

Note: multi_session is a SEPARATE axis from parallel.mode: "worktree".
  - parallel  → multiple sub-agents within ONE session (.worktrees/{issue}/{task})
  - multi_session → whole-session isolation across terminals (.rite/worktrees/issue-{N})

Full design: docs/designs/multi-session-worktree.md
```

---

## Phase 5: Next Steps

Display the following guidance:

```
┌─────────────────────────────────────────────────────────────┐
│                      Next Steps                             │
└─────────────────────────────────────────────────────────────┘

Now that you understand the basics:

📚 Learn more:
  /rite:workflow       View the full workflow diagram
  /rite:skill-suggest  Get contextual command suggestions

🚀 Try these workflows:
  - Start with a simple Issue to practice the flow
  - Use /rite:issue-update during work to save progress
  - Experiment with /rite:iterate to see multi-reviewer analysis

💡 Tips:
  - Work memory is automatically saved and restored
  - Use /rite:recover if interrupted by context limits
  - Check current workflow state with /rite:workflow

🔧 Advanced features:
  - Iteration tracking: enable `iteration` in rite-config.yml (auto-assign on /rite:open, --sprint / --backlog filters in /rite:issue-list)
  - Template customization: Edit template files in the plugin's templates/ directory
  - Multi-agent PR reviews: Automatic in /rite:iterate

Ready to start? Try:
  /rite:issue-list    (to view existing Issues)
  or
  /rite:issue-create <description>   (to create a new Issue)
```
