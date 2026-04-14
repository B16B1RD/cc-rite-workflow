---
description: rite workflow の Getting Started ガイド
---

# /rite:getting-started

Getting Started guide for rite workflow

---

When this command is executed, run the following phases in order.

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

Display the following checklist:

```
┌─────────────────────────────────────────────────────────────┐
│                     Prerequisites                            │
└─────────────────────────────────────────────────────────────┘

Required:
  ✓ gh CLI version ≥2.x
  ✓ git (any recent version)
  ✓ GitHub repository with Issues enabled
  ✓ GitHub authentication (gh auth login)

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

Please run:
  gh auth login

Then run this guide again.
```

Stop here if not authenticated.

### 2.4 Verify Repository

```bash
gh repo view --json owner,name
```

**If not a GitHub repository:**

```
⚠️ This directory is not a GitHub repository

rite workflow requires a GitHub repository with Issues enabled.

If this is a local repository, push it to GitHub first:
  gh repo create --source . --push
```

Stop here if not a valid repository.

---

## Phase 3: Step-by-Step Walkthrough

### 3.1 Display Workflow Overview

```
┌─────────────────────────────────────────────────────────────┐
│                  Quick Start Workflow                        │
└─────────────────────────────────────────────────────────────┘

The typical workflow consists of three main steps:

1. Setup (one-time)
   └─ /rite:init

2. Start working on an Issue
   ├─ /rite:issue:list         (view existing Issues)
   ├─ /rite:issue:create       (create new Issue)
   └─ /rite:issue:start <番号>  (start working)

3. Complete and submit
   ├─ /rite:lint               (quality check)
   ├─ /rite:pr:create          (create draft PR)
   ├─ /rite:pr:review          (self-review)
   └─ /rite:pr:ready           (mark as ready for review)
```

### 3.2 Step 1: Initial Setup

Explain the setup process:

```
┌─────────────────────────────────────────────────────────────┐
│                  Step 1: Initial Setup                       │
└─────────────────────────────────────────────────────────────┘

Run the initialization wizard:
  /rite:init

What /rite:init configures:
  ✓ Creates rite-config.yml with project settings
  ✓ Configures GitHub Projects integration (optional)
  ✓ Sets up branch naming conventions
  ✓ Configures iteration/sprint settings (optional)
  ✓ Installs workflow hooks for state management

This is a one-time setup. You can reconfigure later by running /rite:init again.
```

**Upgrading an existing project (`/rite:init --upgrade`)**

If you have been using rite workflow on this project for a while, the bundled
configuration schema may have moved ahead of your local `rite-config.yml`. In
that case, run the upgrade variant instead of a fresh `/rite:init`:

```
/rite:init --upgrade
```

When to run it:

- After updating the rite workflow plugin and seeing a warning such as
  `rite-config.yml のスキーマが古くなっています (v{current} → v{latest})。
  /rite:init --upgrade でアップグレードできます。`
- When release notes (`CHANGELOG.md`, migration-guides) announce new
  configuration sections (e.g., `wiki:`, `review.debate:`) that are missing from
  your local `rite-config.yml`
- When the `schema_version` value at the top of your `rite-config.yml` diverges
  from the bundled template in
  `plugins/rite/templates/config/rite-config.yml`

What `/rite:init --upgrade` does:

  ✓ Creates a timestamped backup (`rite-config.yml.bak.YYYYMMDD-HHMMSS`)
  ✓ Compares your current `schema_version` against the latest template version
  ✓ Shows a preview of changes: deprecated keys to remove, new sections to
    add (including commented-out Advanced sections), and values that will be
    preserved (e.g., `project_number`, `owner`, `branch.base`, `language`)
  ✓ Asks for confirmation via AskUserQuestion before applying anything
  ✓ Appends the `wiki:` section if it is absent, so Wiki auto-initialization
    (Phase 4.7) can run for existing projects
  ✓ Updates `schema_version` to the latest value on success

The upgrade is non-destructive: user-customized values are preserved, and a
backup is created before any edits are made. If your configuration is already
up to date and Wiki is already initialized, the command is an idempotent no-op
that reports "configuration is up to date" and exits.

Check if `rite-config.yml` exists:

```bash
ls rite-config.yml 2>/dev/null || ls .claude/rite:config.yml 2>/dev/null
```

**If it exists:**

```
✅ Already initialized (rite-config.yml found)

You can skip Step 1 and proceed to Step 2.
```

**If it does not exist:**

```
⚡ Action Required: Run /rite:init to set up rite workflow

After setup is complete, return here or proceed directly to working on Issues.
```

### 3.3 Step 2: Create or Start an Issue

```
┌─────────────────────────────────────────────────────────────┐
│              Step 2: Create or Start an Issue                │
└─────────────────────────────────────────────────────────────┘

Option A: Work on an existing Issue
  1. View all open Issues:
     /rite:issue:list

  2. Start working on a specific Issue:
     /rite:issue:start 42
     (Replace 42 with the Issue number)

Option B: Create a new Issue
  1. Create an Issue with a description:
     /rite:issue:create Add user authentication

  2. rite will automatically create the Issue and start working on it

What happens when you start an Issue:
  ✓ Creates a feature branch (e.g., feat/issue-42-description)
  ✓ Updates Issue status to "In Progress" (if Projects is configured)
  ✓ Initializes work memory for context tracking
  ✓ Provides guidance for implementation
```

### 3.4 Step 3: Complete and Submit

```
┌─────────────────────────────────────────────────────────────┐
│              Step 3: Complete and Submit                     │
└─────────────────────────────────────────────────────────────┘

After implementing your changes:

1. Run quality checks:
   /rite:lint

2. Create a draft PR:
   /rite:pr:create

3. Review your changes:
   /rite:pr:review
   (Multi-reviewer analysis: code quality, security, tests, etc.)

4. If issues are found, fix them:
   /rite:pr:fix
   (Then run /rite:pr:review again)

5. When ready for team review:
   /rite:pr:ready
   (Marks PR as "Ready for review")

6. After PR is merged, the Issue is automatically closed
```

---

## Phase 4: Common First-Time Issues and Solutions

Display the following troubleshooting guide:

```
┌─────────────────────────────────────────────────────────────┐
│                  Troubleshooting Guide                       │
└─────────────────────────────────────────────────────────────┘

Common Issues and Solutions:

1. "gh: command not found"
   Solution: Install gh CLI (see Prerequisites section above)

2. "Could not resolve to a Repository"
   Solution: Ensure you're in a Git repository that's pushed to GitHub
   Check with: gh repo view

3. "Projects not found" during /rite:init
   Solution: Projects is optional. Choose "Skip Projects integration"
   or create a Project manually on GitHub first

4. Branch creation fails in /rite:issue:start
   Solution: Ensure you're on the main/develop branch first
   Check with: git branch --show-current

5. "Context limit reached" during work
   Solution: Use /clear to compact context, then /rite:resume to continue
   The workflow state is preserved and automatically restored

6. PR creation fails
   Solution: Ensure changes are committed and pushed to the feature branch
   Check with: git status

7. Unable to update Issue status
   Solution: Verify Projects integration in rite-config.yml
   Check: projects.enabled and projects.project_number fields
```

---

## Phase 5: Next Steps

Display the following guidance:

```
┌─────────────────────────────────────────────────────────────┐
│                      Next Steps                              │
└─────────────────────────────────────────────────────────────┘

Now that you understand the basics:

📚 Learn more:
  /rite:workflow       View the full workflow diagram
  /rite:skill:suggest  Get contextual command suggestions

🚀 Try these workflows:
  - Start with a simple Issue to practice the flow
  - Use /rite:issue:update during work to save progress
  - Experiment with /rite:pr:review to see multi-reviewer analysis

💡 Tips:
  - Work memory is automatically saved and restored
  - Use /rite:resume if interrupted by context limits
  - Check current workflow state with /rite:workflow

🔧 Advanced features:
  - Sprint planning: /rite:sprint:plan (if iterations enabled)
  - Template customization: Edit template files in the plugin's templates/ directory
  - Multi-agent PR reviews: Automatic in /rite:pr:review

Ready to start? Try:
  /rite:issue:list    (to view existing Issues)
  or
  /rite:issue:create <description>   (to create a new Issue)
```
