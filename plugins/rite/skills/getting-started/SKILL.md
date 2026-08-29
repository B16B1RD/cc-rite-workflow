---
name: getting-started
description: |
  rite workflow の Getting Started ガイド: 導入手順と基本ワークフローを案内する。
  ユーザーが明示的に /rite:getting-started で起動する。auto-activate しない。
  起動: /rite:getting-started
argument-hint: ""
---

# /rite:getting-started

rite workflow の Getting Started ガイド。次の Phase を順に実行する。Phase 4.5 は **on-demand** — 複数セッションを聞かれたときだけ表示する。
rationale: references/rationale.md#on-demand-multisession

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

> **Note (SSH host alias remote)**: origin が SSH host alias だと `gh repo view` が
> `none of the git remotes configured...` で失敗する。`git remote get-url origin` で
> owner/repo が取れれば GitHub リポジトリとして扱う。
> rationale: references/rationale.md#ssh-alias-gh-repo-view

**If not a GitHub repository:**

```
⚠️ This directory is not a GitHub repository

rite workflow requires a GitHub repository with Issues enabled.

`/rite:setup` detects an uninitialized local directory or a repository with no
remote and guides you through initialization, the first commit, repository
creation, and push. You do not need to duplicate those commands here.
```

Phase 3 で `/rite:setup` へ案内する。非空 remote が GitHub として解決できないときは上記
SSH host alias 注記を troubleshooting とする。

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

schema が古いときは fresh setup ではなく upgrade を案内する。手順の SoT は `/rite:setup`。

```
/rite:setup --upgrade
```

いつ走らせるか: schema outdated 警告（`rite-config.yml のスキーマが古くなっています
(v{current} → v{latest})。/rite:setup --upgrade でアップグレードできます。` / session-start
は `を実行してください。`）、CHANGELOG の新セクション欠落、`schema_version` の乖離。
rationale: references/rationale.md#upgrade-delegate

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

> **Canon TDD is on by default**（`/rite:open` → `/rite:issue-implement`）。無効化は
> `tdd.enabled: false`。`commands.test` 未設定なら Red/Green は skip、one-behavior-at-a-time
> は残る。

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

通常の onboarding には出さない。複数セッションを聞かれたときだけ表示する:

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

  • .rite/worktrees/ must be effectively ignored — /rite:setup writes
    .rite/.gitignore (* / !wiki/ / !wiki/**) and does not add runtime-state
    lines to the consumer root .gitignore; /rite:lint verifies that nested file.

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
