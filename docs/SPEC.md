# Claude Code Rite Workflow Specification

> Universal Issue-Driven Development Workflow Claude Code Plugin

## Overview

**Claude Code Rite Workflow** is a universal Claude Code plugin that provides an Issue-driven development workflow.
It works with any software development project regardless of language or framework.

### Design Principles

- **Rite**: Structured process that ensures consistent, repeatable workflows
- **Universality**: No dependency on specific tech stacks
- **Automation**: Auto-detection and auto-configuration where possible
- **Customizability**: Flexible adjustment via configuration files

### Naming Origin

The command prefix `rite` was chosen for:

1. **Meaning**: A rite is a structured ceremony or process - representing consistent, repeatable workflows
2. **Practicality**: Short (4 characters), easy to type, and distinctive as a command prefix
3. **Trademark**: Low trademark risk as it's a common English word

---

## Table of Contents

1. [Command List](#command-list)
2. [Workflow Overview](#workflow-overview)
3. [Plugin Structure](#plugin-structure)
4. [Configuration File Specification](#configuration-file-specification)
5. [Command Specifications](#command-specifications)
6. [Iteration/Sprint Management (Optional)](#iterationsprint-management-optional)
7. [Hook Specification](#hook-specification)
8. [Features](#features)
9. [Notification Integration](#notification-integration)
10. [Build/Test/Lint Auto-Detection](#buildtestlint-auto-detection)
11. [Dynamic Reviewer Generation](#dynamic-reviewer-generation)
12. [Workflow Incident Detection](#workflow-incident-detection)
13. [Sub-skill Return Auto-Continuation Contract](#sub-skill-return-auto-continuation-contract)
14. [Error Handling](#error-handling)
15. [Migration](#migration)
16. [Internationalization](#internationalization)
17. [Dependencies](#dependencies)
18. [Distribution](#distribution)
19. [Project Types](#project-types)

---

## Command List

| Command | Description | Arguments |
|---------|-------------|-----------|
| `/rite:init` | Initial setup wizard | `[--upgrade]` (upgrade existing `rite-config.yml` schema to the latest version) |
| `/rite:getting-started` | Interactive onboarding guide | None |
| `/rite:workflow` | Show workflow guide | None |
| `/rite:investigate` | Structured code investigation | `<topic or question>` |
| `/rite:issue:list` | List Issues | `[filter]` |
| `/rite:issue:create` | Create new Issue | `<title or description>` |
| `/rite:issue:start` | Start work (end-to-end: branch → implementation → PR) | `<Issue number>` |
| `/rite:issue:update` | Update work memory | `[memo]` |
| `/rite:issue:close` | Check Issue completion | `<Issue number>` |
| `/rite:issue:edit` | Interactively edit existing Issue | `<Issue number>` |
| `/rite:pr:create` | Create draft PR | `[PR title]` |
| `/rite:pr:ready` | Mark as Ready for review | `[PR number]` |
| `/rite:pr:review` | Multi-reviewer review | `[PR number]` |
| `/rite:pr:fix` | Address review feedback | `[PR number]` |
| `/rite:pr:cleanup` | Post-merge cleanup | `[branch name]` |
| `/rite:lint` | Run quality checks | `[file path]` |
| `/rite:template:reset` | Regenerate templates | `[--force]` |
| `/rite:sprint:list` | List Sprints/Iterations | `[--all\|--current\|--past]` |
| `/rite:sprint:current` | Show current sprint details | None |
| `/rite:sprint:plan` | Execute sprint planning | `[current\|next\|"Sprint name"]` |
| `/rite:sprint:execute` | Sequentially execute Todo Issues in Sprint | `[Sprint name]` |
| `/rite:sprint:team-execute` | Parallel team execution of Todo Issues in Sprint | `[Sprint name]` |
| `/rite:wiki:init` | Initialize Experience Wiki (branch, directories, templates) | None |
| `/rite:wiki:query` | Search Wiki pages for heuristics by keyword and inject into context | `<keywords>` |
| `/rite:wiki:ingest` | Extract heuristics from raw sources and update Wiki pages | `[source]` |
| `/rite:wiki:lint` | Lint Wiki pages for contradictions, staleness, orphans, missing concepts (`missing_concept`), unregistered raw sources (`unregistered_raw`, informational — not added to `n_warnings`), and broken cross-refs | `[--auto] [--stale-days <N>]` |
| `/rite:resume` | Resume interrupted work | `[issue_number]` |
| `/rite:skill:suggest` | Analyze context and suggest applicable skills | `[--verbose\|--filter]` |

---

## Workflow Overview

```
/rite:init (Initial Setup)
    │
    ▼
/rite:issue:list (Check Issues)
    │
    ▼
/rite:issue:create (Create New Issue)
    │                         Status: Todo
    ▼
/rite:issue:start (Start Work)
    │                         Status: In Progress
    │
    ├── Branch Creation
    ├── Implementation Planning
    ├── Implementation Work
    ├── /rite:lint (Quality Check)
    ├── /rite:pr:create (Create Draft PR)
    ├── /rite:pr:review (Self Review)
    ▼
/rite:pr:fix (Address Review Feedback) ←─┐
    │                                    │
    ▼                                    │
/rite:pr:ready (Ready for Review)         │
    │                         Status: In Review
    │                                    │
    └── (if changes requested) ──────────┘
    ▼
PR Merge
    │
    ▼
/rite:pr:cleanup (Post-Merge Cleanup)
    │                         Status: Done
    ▼
Issue Auto-Close
```

**Note:** `/rite:issue:start` handles the entire flow from branch creation to review fixes in one continuous process. When "Start implementation" is selected, the workflow proceeds through implementation, quality checks, draft PR creation, self-review, and review fixes automatically. See [Phase 5: End-to-End Execution](#phase-5-end-to-end-execution) for details.

**Status Transitions:**
```
Todo → In Progress → In Review → Done
```

---

## Plugin Structure

```
rite-workflow/
├── .claude-plugin/
│   └── plugin.json          # Plugin metadata
├── commands/                # Skill-invoked command files (Markdown)
│   ├── init.md              # /rite:init (+ --upgrade)
│   ├── getting-started.md   # /rite:getting-started
│   ├── workflow.md          # /rite:workflow
│   ├── investigate.md       # /rite:investigate
│   ├── lint.md              # /rite:lint
│   ├── resume.md            # /rite:resume
│   ├── issue/
│   │   ├── list.md          # /rite:issue:list
│   │   ├── create.md        # /rite:issue:create
│   │   ├── create-interview.md       # Sub-skill: interview phase
│   │   ├── create-decompose.md       # Sub-skill: Issue decomposition
│   │   ├── create-register.md        # Sub-skill: single-Issue registration
│   │   ├── start.md         # /rite:issue:start (end-to-end)
│   │   ├── update.md        # /rite:issue:update
│   │   ├── close.md         # /rite:issue:close
│   │   ├── edit.md          # /rite:issue:edit
│   │   ├── recall.md        # /rite:issue:recall
│   │   ├── implement.md              # Sub-skill: implementation phase
│   │   ├── implementation-plan.md    # Sub-skill: plan generation
│   │   ├── completion-report.md      # Sub-skill: completion report format
│   │   ├── branch-setup.md           # Sub-skill: branch creation
│   │   ├── child-issue-selection.md  # Sub-skill: parent-child routing
│   │   ├── parent-routing.md         # Sub-skill: parent Issue detection
│   │   └── work-memory-init.md       # Sub-skill: work memory initialization
│   ├── pr/
│   │   ├── create.md        # /rite:pr:create
│   │   ├── ready.md         # /rite:pr:ready
│   │   ├── review.md        # /rite:pr:review
│   │   ├── fix.md           # /rite:pr:fix
│   │   ├── cleanup.md       # /rite:pr:cleanup
│   │   └── references/      # Protocol documents referenced by pr/ commands
│   │       ├── assessment-rules.md         # Review assessment rules
│   │       ├── archive-procedures.md       # Archive procedures
│   │       ├── bash-trap-patterns.md       # Bash trap patterns for review/fix
│   │       ├── change-intelligence.md      # Change intelligence
│   │       ├── fact-check.md               # External fact-checking protocol
│   │       ├── fix-relaxation-rules.md     # Fix relaxation / 4 quality signals
│   │       ├── internal-consistency.md     # Doc-implementation consistency protocol
│   │       ├── review-context-optimization.md  # Review context optimization
│   │       └── reviewer-fallbacks.md       # Reviewer fallback profiles
│   ├── sprint/
│   │   ├── list.md          # /rite:sprint:list
│   │   ├── current.md       # /rite:sprint:current
│   │   ├── plan.md          # /rite:sprint:plan
│   │   ├── execute.md       # /rite:sprint:execute
│   │   └── team-execute.md  # /rite:sprint:team-execute
│   ├── wiki/
│   │   ├── init.md          # /rite:wiki:init
│   │   ├── query.md         # /rite:wiki:query
│   │   ├── ingest.md        # /rite:wiki:ingest
│   │   ├── lint.md          # /rite:wiki:lint
│   │   └── references/
│   │       └── bash-cross-boundary-state-transfer.md
│   ├── skill/
│   │   └── suggest.md       # /rite:skill:suggest
│   └── template/
│       └── reset.md         # /rite:template:reset
├── agents/                  # Subagent definitions for /rite:pr:review
│   ├── _reviewer-base.md             # Shared reviewer principles (not a subagent)
│   ├── security-reviewer.md
│   ├── performance-reviewer.md
│   ├── code-quality-reviewer.md
│   ├── api-reviewer.md
│   ├── database-reviewer.md
│   ├── devops-reviewer.md
│   ├── frontend-reviewer.md
│   ├── test-reviewer.md
│   ├── dependencies-reviewer.md
│   ├── prompt-engineer-reviewer.md
│   ├── tech-writer-reviewer.md
│   ├── error-handling-reviewer.md
│   ├── type-design-reviewer.md
│   └── sprint-teammate.md   # /rite:sprint:team-execute teammate agent
├── skills/                  # Claude Code auto-discovered skills
│   ├── rite-workflow/
│   │   ├── SKILL.md         # Main workflow skill (auto-activated)
│   │   └── references/      # Coding principles, context management, etc.
│   ├── reviewers/
│   │   ├── SKILL.md         # Reviewer skill (auto-activated)
│   │   ├── {api,code-quality,database,dependencies,devops,error-handling,
│   │   │   frontend,performance,prompt-engineer,security,tech-writer,
│   │   │   test,type-design}.md      # Per-reviewer criteria
│   │   └── references/                # Shared reviewer references
│   ├── investigate/
│   │   └── SKILL.md         # Structured code investigation skill
│   └── wiki/
│       └── SKILL.md         # Experience Wiki skill (opt-out)
├── hooks/                   # Claude Code lifecycle hooks + helpers
│   ├── hooks.json           # Hook registration manifest
│   ├── session-start.sh / session-end.sh / session-ownership.sh
│   ├── pre-compact.sh / post-compact.sh                  # #133
│   ├── stop-guard.sh / preflight-check.sh
│   ├── pre-tool-bash-guard.sh / post-tool-wm-sync.sh
│   ├── phase-transition-whitelist.sh                     # Phase transition guard
│   ├── verify-terminal-output.sh
│   ├── hook-preamble.sh / state-path-resolve.sh          # Shared helpers
│   ├── flow-state-update.sh / local-wm-update.sh
│   ├── work-memory-lock.sh / work-memory-update.sh / work-memory-parse.py
│   ├── cleanup-work-memory.sh
│   ├── issue-body-safe-update.sh / issue-comment-wm-sync.sh / issue-comment-wm-update.py
│   ├── notification.sh      # External notification dispatcher (not a Claude hook)
│   ├── wiki-ingest-trigger.sh / wiki-query-inject.sh     # Wiki auto-integration
│   ├── workflow-incident-emit.sh                         # #366 / #524 / #555 / #567
│   ├── scripts/             # Helper scripts invoked by hooks
│   │   ├── wiki-ingest-commit.sh / wiki-worktree-commit.sh / wiki-worktree-setup.sh
│   │   ├── wiki-growth-check.sh                          # #524 lint layer-3
│   │   ├── backlink-format-check.sh / bang-backtick-check.sh
│   │   ├── distributed-fix-drift-check.sh / doc-heavy-patterns-drift-check.sh
│   │   └── gitignore-health-check.sh                     # #567
│   └── tests/               # Hook-level test suite (shell-based)
├── templates/
│   ├── README.md / completion-report.md
│   ├── config/
│   │   └── rite-config.yml           # Minimal default distributed by /rite:init
│   ├── project-types/
│   │   ├── generic.yml / webapp.yml / library.yml / cli.yml / documentation.yml
│   ├── issue/
│   │   ├── default.md / decomposition-spec.md
│   │   ├── interview-perspectives.md / template-structure.md
│   ├── pr/
│   │   ├── generic.md / webapp.md / library.md / cli.md / documentation.md
│   │   └── fix-report.md              # Fix loop summary format
│   ├── review/
│   │   └── comment.md                 # PR review comment format
│   └── wiki/
│       ├── index-template.md / log-template.md
│       ├── page-template.md / schema-template.md
├── scripts/                 # Projects integration / Sub-Issue / review metrics
│   ├── create-issue-with-projects.sh
│   ├── backfill-sub-issues.sh / link-sub-issue.sh
│   ├── extract-verified-review-findings.sh / measure-review-findings.sh
│   ├── projects-status-update.sh
│   └── tests/               # Script-level test suite
├── references/              # Cross-cutting references used by commands/skills
│   ├── gh-cli-patterns.md / gh-cli-commands.md / gh-cli-error-catalog.md
│   ├── graphql-helpers.md / projects-integration.md
│   ├── priority-markers.md / severity-levels.md / epic-detection.md
│   ├── review-result-schema.md / investigation-protocol.md
│   ├── wiki-patterns.md / workflow-incident-emit-protocol.md
│   ├── bash-compat-guard.md / bash-defensive-patterns.md
│   ├── sub-issue-link-handler.md / issue-create-with-projects.md
│   ├── output-patterns.md / execution-metrics.md
│   ├── plugin-path-resolution.md / git-worktree-patterns.md
│   ├── common-error-handling.md / error-codes.md
│   ├── i18n-usage.md / tdd-light.md
│   └── bottleneck-detection.md
├── i18n/
│   ├── ja.yml / en.yml      # Legacy monolithic files (kept for back-compat)
│   ├── ja/                  # Japanese split files
│   │   └── {common,issue,pr,other}.yml
│   └── en/                  # English split files
│       └── {common,issue,pr,other}.yml
└── README.md
```

### plugin.json

Plugin metadata file format:

```json
{
  "name": "rite",
  "version": "1.0.0",
  "description": "Universal Issue-driven development workflow for Claude Code",
  "author": { "name": "B16B1RD" },
  "license": "MIT"
}
```

| Field | Required | Description |
|-------|----------|-------------|
| `name` | Yes | Plugin name (used as command prefix) |
| `version` | Yes | Semantic version |
| `description` | Yes | Short description |
| `author` | Yes | Author object with `name` field |
| `license` | No | License identifier |

### Command File Format

Each command file in `commands/` must include YAML frontmatter:

```markdown
---
description: Short description of the command
context: fork  # Optional: run in isolated context
---

# /rite:command-name

Command documentation...
```

| Field | Required | Description |
|-------|----------|-------------|
| `description` | Yes | Short description used for command discovery |
| `context` | No | Set to `fork` for commands that don't need main conversation context |

**context: fork Usage:**

Commands that display information without modifying state use `context: fork` for better context efficiency:

| Command | context: fork | Reason |
|---------|---------------|--------|
| `/rite:issue:list` | ✅ | Information display only |
| `/rite:sprint:list` | ✅ | Information display only |
| `/rite:sprint:current` | ✅ | Information display only |
| `/rite:skill:suggest` | ✅ | Independent analysis |
| Others | ❌ | Require user interaction or state changes |

### Skill File Format

Skill files (`skills/*/SKILL.md`) use YAML frontmatter for auto-activation:

```markdown
---
name: skill-name
description: |
  Multi-line description of the skill's purpose.
  Include auto-activation conditions.
---

# Skill Name

Skill documentation...
```

| Field | Required | Description |
|-------|----------|-------------|
| `name` | Yes | Unique skill identifier |
| `description` | Yes | Detailed description with activation conditions |

**Skill Classification:**

| Classification | Purpose | Example |
|----------------|---------|---------|
| Reference Contents | Always-available knowledge | `rite-workflow` (workflow rules) |
| Task Contents | Active execution tasks | `reviewers` (review criteria) |

### Agent File Format

Agent files (`agents/*.md`) define subagents for specialized tasks:

```markdown
---
name: agent-name
description: Short purpose description
model: opus  # opus | sonnet | haiku (optional; omit to inherit from parent session)
---

# Agent Name

Agent documentation...
```

| Field | Required | Description |
|-------|----------|-------------|
| `name` | Yes | Unique agent identifier |
| `description` | Yes | Short description for Task tool |
| `model` | No | Model selection (default: inherit from parent session) |
| `tools` | No | List of available tools (default: inherit all tools from parent; omit to enable all tools) |

**Note on `tools`**: Reviewer agents in the rite plugin are currently invoked via `subagent_type: general-purpose`, which gives them access to all tools from the parent session regardless of the `tools` frontmatter. The `tools` field is therefore optional and is omitted from all reviewer agents to prevent accidental silent tool restrictions when named subagent invocation is introduced in a future phase.

**Current Agents:**

| Agent | Model | Purpose |
|-------|-------|---------|
| `security-reviewer` | opus | Security vulnerabilities, authentication, data handling |
| `performance-reviewer` | inherit | N+1 queries, memory leaks, algorithm efficiency |
| `code-quality-reviewer` | inherit | Duplication, naming, error handling, structure |
| `api-reviewer` | opus | API design, REST conventions, interface contracts |
| `database-reviewer` | opus | Schema design, queries, migrations, data operations |
| `devops-reviewer` | opus | Infrastructure, CI/CD pipelines, deployment configurations |
| `frontend-reviewer` | opus | UI components, styling, accessibility, client-side code |
| `test-reviewer` | opus | Test quality, coverage, testing strategies |
| `dependencies-reviewer` | opus | Package dependencies, versions, supply chain security |
| `prompt-engineer-reviewer` | opus | Claude Code skill, command, and agent definitions |
| `tech-writer-reviewer` | opus | Documentation clarity, accuracy, completeness |
| `error-handling-reviewer` | inherit | Error handling patterns, silent failures, recovery logic |
| `type-design-reviewer` | inherit | Type design, encapsulation, invariant expression |

---

## Configuration File Specification

### rite-config.yml

Place in project root or `.claude/` directory.
Uses YAML format for readability and comment support.

```yaml
# rite-workflow configuration file
schema_version: 2

# Project settings
project:
  type: webapp  # generic | webapp | library | cli | documentation

# GitHub Projects integration
github:
  projects:
    enabled: true
    project_number: null  # Project number (null = auto-detect from repository)
    owner: null           # Project owner (null = use repository owner)
    # Field configuration (fully customizable)
    fields:
      status:
        enabled: true
        options:
          - { name: "Todo", default: true }
          - { name: "In Progress" }
          - { name: "In Review" }
          - { name: "Done" }
      priority:
        enabled: true
        options:
          - { name: "High" }
          - { name: "Medium", default: true }
          - { name: "Low" }
      complexity:
        enabled: true
        options:
          - { name: "XS" }
          - { name: "S" }
          - { name: "M", default: true }
          - { name: "L" }
          - { name: "XL" }
      # Custom fields (project-specific)
      # Any Single Select field name from your GitHub Projects can be used
      # Field name matching is case-insensitive
      work_type:
        enabled: true
        options:
          - { name: "Feature" }
          - { name: "Bug Fix" }
          - { name: "Documentation" }
          - { name: "Refactor" }
          - { name: "Chore" }
      category:
        enabled: true
        options:
          - { name: "Frontend" }
          - { name: "Backend" }
          - { name: "Infrastructure" }
          - { name: "Other" }

# Branch naming rules (fully customizable)
branch:
  # Base branch for feature branches (default PR target)
  base: "main"      # default: main (use "develop" for Git Flow)
  pattern: "{type}/issue-{number}-{slug}"
  # Available variables: {type}, {number}, {slug}, {date}, {user}

# Commit message
commit:
  contextual: true    # Contextual Commits action lines in commit body

# Build/test/lint (auto-detect or manual specification)
commands:
  build: null  # Auto-detect
  test: null   # Auto-detect
  lint: null   # Auto-detect

# Review settings
review:
  # Minimum reviewers (fallback when no reviewers match)
  min_reviewers: 1
  # Review criteria (used for automatic reviewer selection)
  criteria:
    - file_types       # Judgment by file types
    - content_analysis # Judgment by content analysis
  # Note: Reviews always use parallel subagents for each reviewer role

# Notification settings
notifications:
  slack:
    enabled: false
    webhook_url: null
  discord:
    enabled: false
    webhook_url: null
  teams:
    enabled: false
    webhook_url: null

# Workflow incident auto-registration (#366)
# Detects workflow blockers (Skill load failure / hook abnormal exit / manual fallback adoption)
# and auto-registers them as Issues to prevent silent loss.
# See "Workflow Incident Detection" section for details.
workflow_incident:
  enabled: true              # default-on; set false to opt out (AC-8)

# Language setting (auto for auto-detection)
language: auto  # auto | ja | en
```

---

## Command Specifications

### /rite:init

**Description:** Initial setup of rite workflow for a project

**Arguments:** `[--upgrade]` (optional)

| Argument | Description |
|----------|-------------|
| (none) | Run fresh setup (executes Phases 1–5 sequentially) |
| `--upgrade` | Upgrade the schema of an existing `rite-config.yml` to the latest version (skips Phases 1–3 and 5, and executes Phase 4.1.3; Phase 4.1.3 invokes Phase 4.7 (Wiki initialization) at its Step 7, so the effective execution is Phase 4.1.3 + Phase 4.7) |

**Process Flow:**

#### Phase 1: Environment Check
1. Verify gh CLI installation
2. Check GitHub authentication status
3. Get repository information

#### Phase 2: Project Type Detection
1. Auto-detect from file structure
   - `package.json` + frontend framework → webapp
   - `package.json` + `main`/`exports` → library
   - `pyproject.toml` + `[project.scripts]` → cli
   - SSG config file → documentation
   - Other → generic
2. Confirm/select with user (AskUserQuestion)

#### Phase 3: GitHub Projects Setup
1. Detect existing Projects
2. Present options:
   - Link to existing Projects
   - Create new Projects
3. Auto-configure fields

#### Phase 4: Template Generation
1. Check `.github/ISSUE_TEMPLATE/`
   - Recognize if exists
   - Auto-generate if not
2. Generate `rite-config.yml`
3. If an existing `rite-config.yml` is present, check its `schema_version`; if out of date, display guidance to run `/rite:init --upgrade`

#### Phase 5: Completion Report
1. Display settings summary
2. Guide next steps

---

#### --upgrade Option (Existing Configuration Schema Upgrade)

**Purpose:** Bring an existing project's `rite-config.yml` up to the latest schema while preserving user-customized values (`project_number`, `owner`, `branch.base`, `language`, and so on). The upgrade applies the additions (new sections), removals (deprecated keys), and `schema_version` bump in a single confirmed batch.

**When to use:**

- When a warning that `rite-config.yml` schema is outdated appears after upgrading the rite workflow plugin and running `/rite:init` or starting a session. The exact Japanese message emitted by `/rite:init` is: `rite-config.yml のスキーマが古くなっています (v{current} → v{latest})。/rite:init --upgrade でアップグレードできます。` The session-start hook emits a slightly different variant ending in `/rite:init --upgrade を実行してください。` ("run `/rite:init --upgrade`")
- When release notes (`CHANGELOG.md`, or migration notes referenced from the release notes — e.g., `docs/migration-guides/` when present) announce new configuration sections (e.g., `wiki:`, `review.debate:`) that are missing from your local `rite-config.yml`
- When the `schema_version` at the top of your `rite-config.yml` diverges from the `schema_version` in the bundled template (`plugins/rite/templates/config/rite-config.yml`)

**Example:**

```bash
/rite:init --upgrade
```

**Phase 4.1.3 Behavior (runs only with `--upgrade`):**

1. **Read current config and compare versions**
   Read `schema_version` from both the existing `rite-config.yml` and the bundled template. Missing values are treated as v1.
2. **Create a backup**
   Copy the existing file to `rite-config.yml.bak.YYYYMMDD-HHMMSS` for rollback.
3. **Branching**
   - `current < latest`: Run Step 4–6 (identify changes → preview → apply after approval), then Step 7 (Phase 4.7 Wiki initialization).
   - `current == latest` and `wiki:` section absent: After backup, append the `wiki:` block from the template and run Phase 4.7.
   - `current == latest` and `wiki:` section present: No-op; display "configuration is up to date" and run Phase 4.7 (idempotent — no-op if Wiki is already initialized).
4. **Identify and classify changes** (Step 4, only on the `current < latest` path)
   Each key is classified as one of:
   - **User-customized value** (preserve): `project_number`, `owner`, `iteration` settings, `branch.base`, `language`, etc.
   - **Deprecated key** (remove): `project.name`, `commit.style`, `commit.enforce`, `branch.release`, `branch.types`, `version`
   - **Missing section** (add with template defaults): `review.debate`, `review.fact_check`, `verification`, etc.
   - **Advanced section** (add as commented-out block): `tdd`, `parallel`, `team`, `metrics`, `safety`, `investigate`
   - **Unknown key** (preserve with warning): user-added keys not present in the template
5. **Preview and confirm** (Step 5)
   Display deprecated keys to be removed, sections to be added, and preserved existing settings; ask via `AskUserQuestion` to either apply or cancel.
6. **Apply** (Step 6)
   On approval, update `schema_version` to the latest value, remove deprecated keys, add missing sections (including commented-out Advanced sections), and append the `wiki:` section if it was absent. All user-customized values are preserved.
7. **Run Phase 4.7 (Wiki initialization)** (Step 7)
   Invoke Phase 4.7 to bring existing users up to the Wiki-initialized state. If Wiki is already initialized, the phase is an idempotent no-op. Phase 4.7 is non-blocking: its failure does not affect `--upgrade` success. A final Wiki status line is displayed before the command exits.

**Relationship with `schema_version`:**

- The `schema_version` key at the top of `rite-config.yml` is an integer that identifies the configuration schema version (e.g., `schema_version: 2`). It is incremented whenever the rite workflow introduces a backward-incompatible schema change.
- `--upgrade` compares the `schema_version` in the current file against the one in the bundled template and runs the Phase 4.1.3 flow above when the current file is behind.
- Configuration files without a `schema_version` key are implicitly treated as v1 and can be brought up to date via `--upgrade`.

**Relationship with Phase 5 (new-install completion report):**

- `--upgrade` skips Phases 1–3 and the Phase 5 new-install completion report; only the Wiki status line is displayed at the end.
- It does not merge with the fresh-install completion report (`--upgrade` is a dedicated path for updating existing configurations).

---

### /rite:issue:create

**Description:** Create new Issue and add to GitHub Projects

**Arguments:** `<Issue title or work description>` (required)

#### Phase 0: Input Analysis

1. Extract from user input:
   - **What:** What to do
   - **Why:** Why it's needed
   - **Where:** What to change
   - **Scope:** Impact range
   - **Constraints:** Limitations

2. Detect ambiguous expressions

3. Search similar Issues for context

4. Clarify with `AskUserQuestion` if needed

5. Deep-dive interview (Phase 0.5) for implementation details

#### Phase 0.6-0.9: Task Decomposition (Conditional)

**Trigger Conditions:**
- Preliminary complexity is XL
- AND contains inclusive expressions like "build ~ system", "create ~ platform", "implement ~ infrastructure"
  - Simple expressions like "add ~ feature", "fix ~" are excluded

**Decomposition Flow:**

1. **Phase 0.6**: Decomposition trigger detection
   - If conditions are met, propose decomposition to user

2. **Phase 0.7**: Specification document generation
   - Generate design document based on deep-dive interview results
   - Save to `docs/designs/{slug}.md`

3. **Phase 0.8**: Sub-Issue decomposition
   - Extract Sub-Issue candidates from specification
   - Analyze dependencies and propose implementation order

4. **Phase 0.9**: Bulk Sub-Issue creation
   - Create parent Issue and Sub-Issues
   - Set parent-child relationship via Tasklist format
   - Use GitHub Sub-Issues API (beta) if available

**Sub-Issue Granularity:**
- Each Sub-Issue should be 1 Issue = 1 PR in size
- Estimated complexity: S-L (split to avoid XL)
- Can be completed independently

#### Phase 1: Classification

**Complexity Estimation:**

| Complexity | Criteria |
|------------|----------|
| XS | Single line change, typo fix |
| S | Single file content update |
| M | Multiple files (up to 5) |
| L | Multiple files (10+), requires judgment |
| XL | Large-scale changes, design decisions |

#### Phase 2: Confirmation & Creation

1. Create Issue with `gh issue create`
2. Add to Projects with `gh project item-add`
3. Set fields (Status/Priority/Complexity/Work Type)

---

### /rite:issue:start

**Description:** Start work on Issue with end-to-end flow (branch creation → implementation → PR creation)

**Arguments:** `<Issue number>` (required)

**Workflow:** This command handles the complete development flow:
1. Branch creation and preparation
2. Implementation planning
3. Implementation work
4. Quality checks (`/rite:lint`)
5. Draft PR creation (`/rite:pr:create`)
6. Self review (`/rite:pr:review`)

**What "automatic" means:** In this command, "automatic" refers to sequential execution via the Skill tool in Phase 5 without requiring manual command input from the user.

#### Phase 0: Epic/Sub-issues Detection

Uses GitHub standard features:
- Recognize Milestone feature
- Recognize Sub-issues (beta) if available
- List child Issues and prompt user selection

**Parent Issue Status Synchronization:**

When working on a child Issue, the parent Issue's status is automatically synchronized:

| Trigger | Parent Issue Status Update |
|---------|---------------------------|
| First child Issue becomes In Progress | Parent Issue → In Progress |
| All child Issues become Done | Parent Issue → Done |
| Some completed, some pending | Parent Issue stays In Progress |

This ensures the parent Issue accurately reflects the overall progress of its child Issues.

#### Phase 1: Issue Quality Verification

**Quality Score:**

| Score | Criteria |
|-------|----------|
| A | All items clear |
| B | Main items clear, some inferable |
| C | Basic info only, needs completion |
| D | Insufficient info, must complete before starting |

For C/D scores:
1. Attempt auto-completion
2. Ask user with `AskUserQuestion` if unable

#### Phase 1.5: Parent Issue Routing

Detects whether the target Issue is a parent (epic) Issue via:
1. `trackedIssues` API (GraphQL)
2. Body tasklist (`- [ ] #XX`)
3. Labels (`epic`/`parent`/`umbrella`)

If the Issue is a parent, routing logic determines the appropriate action: work on the parent directly, select a child Issue, or decompose into sub-Issues.

#### Phase 1.6: Child Issue Selection

When a parent Issue is detected, automatically selects the most appropriate child Issue to work on based on:
- Priority and dependency ordering
- Current status (skip completed/in-progress children)
- User confirmation before proceeding

#### Phase 2: Work Preparation

1. Generate branch name (per config pattern)
2. Check for existing branch (including recognized patterns from `branch.recognized_patterns` config)
3. Create branch with `git checkout -b`
4. Update GitHub Projects Status to "In Progress"
5. Assign to current Iteration (if `iteration.enabled: true` and `iteration.auto_assign: true`)
6. Initialize work memory comment

##### Phase 2.2.1: Recognized Branch Patterns

If `branch.recognized_patterns` is configured in rite-config.yml, detect existing non-Issue-numbered branches matching those patterns. When matched, the user can choose to use the existing branch or create a standard-pattern branch.

##### Phase 2.5: Iteration Assignment (Optional)

When `iteration.enabled: true` and `iteration.auto_assign: true` in rite-config.yml, automatically assigns the Issue to the current active Iteration/Sprint in GitHub Projects.

**Work Memory Comment Format:**

Add a dedicated comment to Issue, update that same comment thereafter:

```markdown
## 📜 rite Work Memory

### Session Info
- **Started**: 2025-01-03T10:00:00+09:00
- **Branch**: feat/issue-123-add-feature
- **Last Updated**: 2025-01-03T10:00:00+09:00
- **Command**: rite:issue:start
- **Phase**: phase2
- **Phase Detail**: Branch creation & setup

### Progress
- [ ] Task 1
- [ ] Task 2

### Confirmation Items
<!-- Accumulate pending questions during work. Confirm collectively at session end -->
_No confirmation items_

### Changed Files
<!-- Auto-updated -->

### Decisions & Notes
<!-- Important decisions and findings -->

### Plan Deviation Log
<!-- Record when deviating from the implementation plan -->
_No plan deviations_

### Bottleneck Detection Log
<!-- Bottleneck detection → Oracle discovery → Re-decomposition history -->
_No bottlenecks detected_

### Review Response History
<!-- Auto-recorded during review response -->
_No review responses_

### Next Steps
1. ...
```

**Phase Information:**

The Session Info section of the work memory includes phase information indicating the current work state. This information is used by `/rite:resume` for resuming work.

| Phase | Phase Detail |
|-------|--------------|
| `phase0` | Epic/Sub-Issues detection |
| `phase1` | Quality verification |
| `phase1_5_parent` | Parent Issue routing |
| `phase1_6_child` | Child Issue selection |
| `phase2` | Branch creation & setup |
| `phase2_branch` | Branch creation in progress |
| `phase2_work_memory` | Work memory initialization |
| `phase3` | Implementation planning |
| `phase4` | Work start preparation |
| `phase5_implementation` | Implementation in progress |
| `phase5_lint` | Quality check in progress |
| `phase5_pr` | PR creation in progress |
| `phase5_review` | Review in progress |
| `phase5_fix` | Review fix in progress |
| `phase5_post_ready` | Post-ready processing |
| `completed` | Completed |

#### Phase 3: Implementation Planning

1. Analyze Issue content and identify target files
2. Generate implementation plan
3. User confirmation: Approve / Modify / Skip

#### Phase 4: Guidance and Continuation

After preparation, user selects:
- **Start implementation (Recommended)**: Proceed to Phase 5 for end-to-end execution from implementation to PR creation and review
- **Work later**: Pause here and resume later with `/rite:issue:start`

#### Phase 5: End-to-End Execution

Starts when "Start implementation" is selected. The following steps are executed **continuously without interruption**:

**Flow Continuation Principle:** After each step completes, proceed to the next step without waiting for user confirmation (except where confirmation is explicitly required).

| Step | Content | Called Command |
|------|---------|----------------|
| 5.1 | Implementation work (including commit & push) | - |
| 5.2 | Quality checks | `/rite:lint` |
| 5.3 | Draft PR creation | `/rite:pr:create` |
| 5.4 | Self review | `/rite:pr:review` |
| 5.5 | Continuation based on review results | `/rite:pr:fix` (if needed) |
| 5.6 | Completion report | - |

**5.2 Quality Check Result Branching:**

| Result | Next Action |
|--------|-------------|
| Success | → Proceed to 5.3 |
| Warnings only | → Proceed to 5.3 |
| Errors found | Fix errors → Re-run 5.2 |
| Skipped | → Proceed to 5.3 (recorded in PR) |

**5.5 Review Result Branching:**

| Result | Next Action |
|--------|-------------|
| Approve | Confirm `/rite:pr:ready` execution → Proceed to 5.6 |
| Approve with conditions | Fix with `/rite:pr:fix` → Return to 5.4 |
| Request changes | Fix with `/rite:pr:fix` → Return to 5.4 |

**Review-Fix Cycle Continuation:** The `/rite:pr:review` → `/rite:pr:fix` → `/rite:pr:review` cycle continues automatically until the overall assessment is "Approve" (zero blocking findings). The loop exits only when all findings are resolved — there is no iteration limit or progressive relaxation.

**Verification mode** (`review.loop.verification_mode`, default: `false`): When explicitly enabled, from cycle 2+, reviews perform both a full review and verification of previous fixes with incremental diff regression checks. New MEDIUM/LOW findings in unchanged code are reported as non-blocking "stability concerns". The default `false` performs full review every cycle, maximizing review quality.

**Definition of "Approve":** Zero blocking findings.

### Automatic Work Memory Updates

Work memory is automatically updated when executing the following commands:

| Command | Auto-Update Content |
|---------|---------------------|
| `/rite:issue:start` | Initialize work memory, record implementation plan |
| `/rite:pr:create` | Record changed files, commit history, PR info |
| `/rite:pr:fix` | Record review response history |
| `/rite:pr:cleanup` | Record completion info |
| `/rite:lint` | Record quality check results (conditional: only on issue branches) |

**Manual Update:**

`/rite:issue:update` remains available for manual updates when:
- Recording important design decisions
- Adding supplementary information
- Manually updating progress at specific timing
- Preparing handoff for next session

### Interruption and Resumption

If "Work later" is selected or work is interrupted:
- Branch and work memory are preserved
- Phase information (`Command`, `Phase`, `Phase Detail`) is recorded in work memory
- Use `/rite:resume` to resume work from the interrupted phase

**How to Resume:**

```
/rite:resume
```

Or specify Issue number:

```
/rite:resume <issue_number>
```

**Session Start Auto-Detection:**

When starting a session on a feature branch, the system automatically detects phase information from work memory and notifies if there is interrupted work.

**If PR Already Exists:**
- After detecting existing branch, check for PR existence
- If PR exists, option to continue review response with `/rite:pr:fix`

**Note:** `/rite:pr:create` can also be used independently for:
- Resuming after interruption
- Creating PR from existing branch
- Creating PR without linked Issue

---

### /rite:pr:review

**Description:** Dynamic multi-reviewer PR review

**Arguments:** `[PR number or branch name]` (optional, defaults to current branch)

#### Parallel Subagent Review

`/rite:pr:review` uses Claude Code's Task tool to spawn parallel subagents for each reviewer role:

```
/rite:pr:review start
  ↓
Get changed files list
  ↓
Analyze files and select appropriate reviewers
  ↓
Spawn subagents in parallel (Task tool)
  ├─ security-reviewer: Security perspective
  ├─ performance-reviewer: Performance perspective
  ├─ code-quality-reviewer: Code quality perspective
  ├─ api-reviewer: API design perspective
  ├─ database-reviewer: Database perspective
  ├─ devops-reviewer: DevOps perspective
  ├─ frontend-reviewer: Frontend perspective
  ├─ test-reviewer: Test quality perspective
  ├─ dependencies-reviewer: Dependencies perspective
  ├─ prompt-engineer-reviewer: Prompt quality perspective
  ├─ tech-writer-reviewer: Documentation perspective
  ├─ error-handling-reviewer: Error handling perspective
  └─ type-design-reviewer: Type design perspective
  ↓
Collect results from each subagent
  ↓
Integrate results for overall assessment
  ↓
Output review results
```

**Benefits:**
- Improved context efficiency (each subagent has focused context)
- Parallel execution for faster reviews
- Specialized expertise per review area
- Automatic reviewer selection based on changed files

**Reviewer Selection:**

Reviewers are automatically selected based on file patterns and content analysis. Not all reviewers are invoked for every PR - only relevant ones are selected.

**Fallback:** If a subagent fails or times out, the review continues with remaining subagents, and the failure is noted in the summary.

See "[Dynamic Reviewer Generation](#dynamic-reviewer-generation)" section for additional details.

---

### /rite:pr:fix

**Description:** Address review feedback on PR

**Arguments:** `[PR number]` (optional, defaults to current branch's PR)

#### Phase 1: Review Comment Retrieval

1. Identify PR (from argument or current branch)
2. Fetch review comments using GitHub API
3. Classify comments:
   - **Changes Requested**: From `CHANGES_REQUESTED` reviews or unresolved threads
   - **Suggestions/Questions**: Improvement proposals or unanswered questions
   - **Resolved**: Already resolved threads
4. Display organized list of unresolved comments

#### Phase 2: Response Support

For each unresolved comment:

1. Show comment details (file, line, content, reviewer)
2. Prompt user for response type:
   - Fix the code
   - Reply only (no changes needed)
   - Skip (address later)
3. If fixing code:
   - Read affected file
   - Suggest fix based on comment
   - Apply fix with Edit tool
4. Optionally create reply to reviewer

#### Phase 3: Fix Commit

1. Review all changes made
2. Generate commit message based on addressed comments
3. Commit changes with appropriate message
4. Optionally push to remote

#### Phase 4: Completion Report

1. Optionally resolve addressed threads (GraphQL mutation)
2. Optionally post summary comment on PR
3. Update work memory with fix history
4. Display completion summary with next steps

---

### /rite:pr:cleanup

**Description:** Automate post-PR-merge cleanup tasks

**Arguments:** `[branch name]` (optional, defaults to current branch)

#### Phase 1: State Verification

1. Check current branch
2. Find related PR and verify merge status
3. Identify related Issue from PR body or branch name

**If PR is not merged:**
- Warn user about potential data loss
- Offer options: Cancel (recommended) or Force cleanup

#### Phase 2: Cleanup Execution

1. Switch to main branch
2. Pull latest main
3. Delete local branch (`git branch -d`)
4. Delete remote branch if exists (`git push origin --delete`)

**On uncommitted changes:**
- Offer to stash changes before cleanup

#### Phase 3: Projects Status Update

1. Get Project configuration from `rite-config.yml`
2. Find Issue's Project item
3. Update Status to "Done"
4. Add completion record to work memory comment

#### Phase 4: Completion Report

```
Cleanup completed

PR: #{pr_number} - {pr_title}
Related Issue: #{issue_number}
Status: Done

Completed tasks:
- [x] Switched to main branch
- [x] Pulled latest main
- [x] Deleted local branch {branch_name}
- [x] Deleted remote branch
- [x] Updated Projects Status to Done
- [x] Finalized work memory

Next steps:
1. `/rite:issue:list` to check next Issue
2. `/rite:issue:start <issue_number>` to start new work
```

---

## Iteration/Sprint Management (Optional)

Sprint management feature using GitHub Projects Iteration field.

### Overview

- **Optional Feature**: Disabled by default (`iteration.enabled: false`)
- **Manual Setup**: Iteration field must be created manually in GitHub Web UI (gh CLI not supported)
- **Graceful Degradation**: Other features work normally when Iteration is disabled

### Feature Comparison

| Aspect | Iteration Disabled | Iteration Enabled |
|--------|-------------------|-------------------|
| Issue Creation | Status/Priority/Complexity fields | + Sprint assignment option |
| Issue Start | Branch creation, Status update | + Auto-assign to current Sprint |
| Issue List | Filter by Status/Priority | + Sprint/Backlog filters |
| Available Commands | 12 core commands | + 3 Sprint commands |
| Planning Style | Ad-hoc | Sprint-based planning |
| Progress Visibility | By Status only | + By Sprint progress |

### Configuration

```yaml
# rite-config.yml
iteration:
  enabled: false          # Set true to enable
  field_name: "Sprint"    # Iteration field name
  auto_assign: true       # Auto-assign on issue:start
  show_in_list: true      # Show Iteration column in issue:list
```

### Sprint Commands

| Command | Description |
|---------|-------------|
| `/rite:sprint:list` | List all Iterations |
| `/rite:sprint:current` | Current sprint details |
| `/rite:sprint:plan` | Sprint planning (assign Issues from backlog) |

### Iteration Support in Existing Commands

| Command | Iteration Feature |
|---------|-------------------|
| `/rite:init` | Iteration field detection & setup guide |
| `/rite:issue:start` | Auto-assign to current iteration |
| `/rite:issue:create` | Iteration assignment option on creation |
| `/rite:issue:list` | `--sprint current`, `--backlog` filters |

### Current Iteration Detection

```
1. Get today's date
2. For each iteration:
   - endDate = startDate + duration (days)
   - startDate <= today < endDate → "current"
3. No match → next iteration (or null)
```

### Technical Constraints

- **Iteration field auto-creation**: Not possible (gh CLI doesn't support ITERATION data type)
- **Iteration field operations**: Available via GraphQL API

---

## Hook Specification

### Supported Hook Types

| Type | Timing | Purpose |
|------|--------|---------|
| SessionStart | Session start | Load work memory, detect interrupted work |
| PreCompact | Before compact | Save work memory, record compact state |
| PostCompact | After compact | Restore work memory, clean compact state |
| SessionEnd | Session end | Save final state |
| Stop | On stop attempt (event-driven) | Prevent premature workflow stops |
| PreToolUse | Before tool execution | Block tool usage after compact, detect dangerous command patterns |
| PostToolUse | After tool execution | Auto-recover local work memory |

> **Note:** `notification.sh` is not a Claude Code hook type but a utility script called directly from within commands. It is invoked by command scripts during events such as PR creation, Ready status change, and Issue close to send external notifications. See the [Notification Integration](#notification-integration) section for details.

### Hook Execution Order

```
SessionStart
    ↓
PreToolUse → Tool Execution → PostToolUse
    ↓
PreCompact (on compact)
    ↓
SessionEnd
```

> **Note:** Stop hook is event-driven and may trigger at any point during the flow above. Blocks if rite workflow is active.
>
> **Note:** PreToolUse and PostToolUse fire on every Claude Code tool invocation. PreCommand/PostCommand have been deprecated and replaced by the Preflight check system integrated into command execution.

### Stop Guard (`stop-guard.sh`)

Prevents Claude from stopping during an active rite workflow session.

**Behavior:**

1. Reads `.rite-flow-state` from the working directory (if absent, allows the stop)
2. If `active` is not `true`, allows the stop
3. If the workflow was updated within the last hour, blocks the stop
4. If the workflow is stale (over 1 hour since last update), allows the stop (assumes abandoned)

**Timestamp Parsing (Cross-Platform):**

The script parses `updated_at` (ISO 8601 format) using a fallback chain for cross-platform compatibility:

| Priority | Method | Platform | Notes |
|----------|--------|----------|-------|
| 1 | `date -d` (GNU) | Linux | Parses `+09:00` timezone directly |
| 2 | `date -j -f` (BSD) | macOS | Requires `sed` to convert `+09:00` → `+0900` first |
| 3 | `echo 0` (fallback) | Any | Sets `STATE_TS=0`, resulting in `AGE ≈ current epoch` (>> 3600), allowing the stop |

**Block Response:**

When blocking, exits with code 2 and writes the continuation message to stderr. Claude Code interprets exit 2 as "prevent stop + feed stderr to assistant":

```
rite workflow active (phase: <phase>). CONTINUE: <next_action>. If context limit reached, use /clear then /rite:resume to recover.
```

**Error Count Auto-Release:**

Stop Guard increments `error_count` in `.rite-flow-state` each time it blocks a stop. When `error_count` reaches the threshold (default: 5), it determines that the workflow is stuck in an error loop and allows the stop. `error_count` is reset when the next workflow starts (`.rite-flow-state` is regenerated).

**Debug Logging:**

Set `RITE_DEBUG=1` environment variable to enable debug logging to `.rite-flow-debug.log`. Zero overhead when disabled.

### Preflight Check (`preflight-check.sh`)

Pre-validation script called before every `/rite:*` command execution. Detects blocked state after compact and controls command execution.

**Behavior:**

1. Reads `.rite-compact-state` (if file doesn't exist, allows execution)
2. If `compact_state` is `normal` or `resuming`, allows execution
3. If the command is `/rite:resume`, always allows execution
4. All other commands are blocked (exit 1)

**Exit Codes:**

| Code | Meaning |
|------|---------|
| 0 | Allowed (continue command execution) |
| 1 | Blocked (do not execute command) |

**Usage:**

```bash
bash plugins/rite/hooks/preflight-check.sh --command-id "/rite:issue:start" --cwd "$PWD"
```

### Post-Compact Guard (`post-compact-guard.sh`)

Registered as a PreToolUse hook. After compact occurs, **blocks all tool usage** until the user runs `/clear` → `/rite:resume`.

**Behavior:**

1. Reads `.rite-compact-state`
2. Checks if workflow is active via `.rite-flow-state`
3. If workflow is inactive, cleans up `.rite-compact-state` (self-healing)
4. If `compact_state` is `blocked`, denies tool usage and instructs the LLM to stop

**Self-Healing Mechanism:**

If the workflow has ended but `.rite-compact-state` remains (e.g., due to crash), automatically cleans up and resumes normal operation.

### Pre-Tool Bash Guard (`pre-tool-bash-guard.sh`)

Registered as a PreToolUse hook. Blocks known incorrect Bash command patterns that the LLM repeatedly generates before execution.

**Blocked Patterns:**

| Pattern | Reason | Alternative |
|---------|--------|-------------|
| `gh pr diff --stat` | `--stat` flag is unsupported | `gh pr view {n} --json files --jq '.files[]'` |
| `gh pr diff -- <path>` | File filter is unsupported | `gh pr diff {n} \| awk` for filtering |
| `!= null` (in jq/awk) | Bash history expansion interprets `!` | `select(.field)` or `select(.field == null \| not)` |

**Heredoc Safety:**

To prevent false positives from text in heredocs (commit messages, PR descriptions, etc.), only the command portion before `<<` is inspected.

### Post-Tool WM Sync (`post-tool-wm-sync.sh`)

Registered as a PostToolUse hook. Automatically creates local work memory files when they are missing during an active workflow.

**Behavior:**

1. Fires after Bash tool usage (with recursion guard)
2. Retrieves active workflow and Issue number from `.rite-flow-state`
3. Only creates `.rite-work-memory/issue-{n}.md` if it doesn't exist

**Purpose:** Guarantees auto-recovery of local work memory during `/rite:resume` after compact or session restart.

### Local WM Update (`local-wm-update.sh`)

Standalone wrapper script for updating local work memory files. Automatically resolves the plugin root via `BASH_SOURCE`.

**Usage:**

```bash
WM_SOURCE="implement" WM_PHASE="phase5_lint" \
  WM_PHASE_DETAIL="Quality check prep" \
  WM_NEXT_ACTION="Run rite:lint" \
  WM_BODY_TEXT="Post-implementation." \
  WM_ISSUE_NUMBER="866" \
  bash plugins/rite/hooks/local-wm-update.sh
```

**Environment Variables:**

| Variable | Required | Description |
|----------|----------|-------------|
| `WM_SOURCE` | Yes | Update source identifier (`init`, `implement`, `lint`, etc.) |
| `WM_PHASE` | Yes | Current phase (`phase2`, `phase5_lint`, etc.) |
| `WM_PHASE_DETAIL` | Yes | Detailed phase description |
| `WM_NEXT_ACTION` | Yes | Next action |
| `WM_BODY_TEXT` | Yes | Update content text |
| `WM_ISSUE_NUMBER` | Yes | Issue number |

### Work Memory Lock (`work-memory-lock.sh`)

Shared library script providing `mkdir`-based lock/unlock functionality. Used by sourcing from other scripts.

**Provided Functions:**

| Function | Description |
|----------|-------------|
| `acquire_wm_lock <lockdir> [timeout]` | Acquire lock (with timeout, default: 50 iterations × 100ms = 5 seconds) |
| `release_wm_lock <lockdir>` | Release lock |
| `is_wm_locked <lockdir>` | Check lock status |

**Stale Lock Detection:**

If a lock's `mtime` exceeds the threshold (default: 120 seconds), the PID file is checked to verify process liveness. If the process has terminated, the lock is automatically released.

---

## Features

### TDD Light Mode

A lightweight TDD mode that auto-generates test skeletons from acceptance criteria, preparing test structure before implementation.

**Configuration:**

```yaml
# rite-config.yml
tdd:
  mode: "off"        # off | light (default: off)
  tag_prefix: "AC"   # Tag prefix for test markers
  run_baseline: true  # Run baseline tests before skeleton generation
  max_skeletons: 20   # Maximum skeletons per Issue
```

**Workflow:**

1. Analyze Issue acceptance criteria
2. Assign hashtags (`AC[a1b2c3d4]`) to each criterion
3. Generate test skeletons (with `skip` / `pending` / `todo` markers)
4. Fill in skeletons sequentially during implementation

### Preflight Check System

A system that performs unified pre-validation before every `/rite:*` command execution. Prevents command execution in invalid states after compact.

**How It Works:**

- Each command calls `preflight-check.sh` at its start
- Compact state is managed via the `.rite-compact-state` file
- In `blocked` state, all commands except `/rite:resume` are blocked
- Normal state is restored via `/clear` → `/rite:resume`

### Local Work Memory + Compact Resilience

In addition to Issue comment backups, work memory is maintained on the local filesystem. This ensures resilience against context compaction.

**Architecture:**

| Component | Role | Location |
|-----------|------|----------|
| Local work memory (SoT) | Source of truth | `.rite-work-memory/issue-{n}.md` |
| Issue comment (backup) | Cross-session backup | GitHub Issue comment |
| Flow state | Workflow control | `.rite-flow-state` |
| Compact state | Post-compact state management | `.rite-compact-state` |

**Local Work Memory Features:**

- Exclusive access control via `mkdir`-based locking
- Auto-recovery through PostToolUse hook
- State restoration from `.rite-flow-state` possible even after compact

### Implementation Contract Issue Format

A format that includes an Implementation Contract section in Issues generated by `/rite:issue:create`. Separates high-level design from specification and detailed implementation steps.

**Structure:**

- **Phase 0.7 (Specification generation)**: Generates high-level What/Why/Where design in `docs/designs/`
- **Phase 3 (Implementation plan)**: Generates detailed How steps as a dependency graph
- Issue body checklist tracks progress

### Complexity-Based Question Filtering

A mechanism that dynamically adjusts the number of questions based on Issue complexity during `/rite:issue:create`'s deep-dive interview (Phase 0.5).

**Filtering Rules:**

| Complexity | Questions | Scope |
|------------|-----------|-------|
| XS-S | Minimal (1-2) | What/Why only |
| M | Standard (3-4) | What/Why/Where/Scope |
| L-XL | Detailed (5+) | All items + decomposition proposal |

### Shell Script Test Framework

A test framework for ensuring Hook script quality. Located in `plugins/rite/hooks/tests/`.

**Test Targets:**

| Script | Test Content |
|--------|-------------|
| `stop-guard.sh` | Stop block/allow decisions per phase |
| `preflight-check.sh` | Command blocking by compact state |
| `post-compact-guard.sh` | Tool usage blocking, self-healing |
| `pre-tool-bash-guard.sh` | Dangerous pattern detection, heredoc safety |

**Execution:**

```bash
bash plugins/rite/hooks/tests/run-tests.sh
```

---

## Notification Integration

### Slack

```yaml
notifications:
  slack:
    enabled: true
    webhook_url: "https://hooks.slack.com/services/..."
```

### Discord

```yaml
notifications:
  discord:
    enabled: true
    webhook_url: "https://discord.com/api/webhooks/..."
```

### Microsoft Teams

```yaml
notifications:
  teams:
    enabled: true
    webhook_url: "https://outlook.office.com/webhook/..."
```

### Notification Events

| Event | Description |
|-------|-------------|
| `pr_created` | When PR created |
| `pr_ready` | When Ready for review |
| `issue_closed` | When Issue closed |

---

## Build/Test/Lint Auto-Detection

### Detection Priority

1. **Explicit specification in rite-config.yml**
2. **package.json scripts**
   - Detect `build`, `test`, `lint`
3. **Makefile targets**
4. **Standard file structure inference**

### Language/Framework Detection

| File | Language/FW | Build | Test | Lint |
|------|-------------|-------|------|------|
| `package.json` | Node.js | `npm run build` | `npm test` | `npm run lint` |
| `pyproject.toml` | Python | `python -m build` | `pytest` | `ruff check` |
| `Cargo.toml` | Rust | `cargo build` | `cargo test` | `cargo clippy` |
| `go.mod` | Go | `go build` | `go test` | `golangci-lint` |
| `pom.xml` | Java | `mvn package` | `mvn test` | `mvn checkstyle:check` |

### Fallback Behavior When Commands Not Detected

When build/test/lint commands cannot be detected, the workflow provides interactive options instead of terminating:

**Options presented via `AskUserQuestion`:**

| Option | Description |
|--------|-------------|
| **Skip and continue (Recommended)** | Skip the command and proceed to the next step. Record the skip in PR body under "Known Issues" |
| **Specify command** | User manually enters the command to execute |
| **Abort** | Terminate the process and guide user to configure settings |

**Skip behavior:**
- The skip is recorded in the conversation context
- When `/rite:pr:create` is called, the "Known Issues" section includes the skipped command
- The end-to-end flow (`/rite:issue:start`) continues without interruption

**Command specification behavior:**
- The specified command is used for the current execution only
- Configuration is not automatically saved to `rite-config.yml`
- User is guided to use `/rite:init` or manual editing for permanent configuration

---

## Dynamic Reviewer Generation

### Overview

Analyze PR changes and dynamically generate appropriate reviewers.

### Reviewer Selection Logic

#### Step 1: File Type Analysis

| File Pattern | Recommended Reviewer |
|--------------|---------------------|
| `**/security/**`, `auth*`, `crypto*` | Security Expert |
| `.github/**`, `Dockerfile`, `*.yml` (CI) | DevOps Expert |
| `**/*.md`, `docs/**` | Technical Writer |
| `**/*.test.*`, `**/*.spec.*` | Test Expert |
| `**/api/**`, `**/routes/**` | API Design Expert |

#### Step 2: Content Analysis

LLM analyzes diff content to determine:
- Change complexity
- Required expertise
- Potential risk areas

#### Step 3: Dynamic Reviewer Count

| Condition | Reviewers |
|-----------|-----------|
| Single file, <10 lines | 1 |
| Multiple files, <100 lines | 2-3 |
| Large changes, security-related | 4-5 |

### Dynamically Generated Reviewer Profiles

- **Security Expert**: Vulnerabilities, authentication, encryption
- **Performance Expert**: Optimization, memory usage
- **Accessibility Expert**: WCAG compliance, screen reader support
- **Technical Writer**: Documentation quality, consistency
- **Architect**: Design patterns, dependencies
- **DevOps Expert**: CI/CD, infrastructure, deployment

### Review Result Format

```markdown
## 📜 rite Review Results

### Overall Assessment
- **Recommendation**: Approve / Approve with conditions / Request changes

### Individual Reviewer Assessments

#### Security Expert
- **Assessment**: Approve
- **Comments**: No issues with authentication logic

#### Performance Expert
- **Assessment**: Approve with conditions
- **Comments**: Potential N+1 query (L45-52)

...
```

---

## Workflow Incident Detection

### Overview (#366)

The rite workflow auto-detects **workflow blockers** during `/rite:issue:start` end-to-end execution and registers them as Issues to prevent silent loss. This was implemented after PR #363 demonstrated that Skill loader bugs (#365) could be silently bypassed via manual Edit-tool fallback, leaving incidents undocumented.

### Detection Scope

| Type | Trigger | Source |
|------|---------|--------|
| `skill_load_failure` | Skill tool fails to load (e.g., Markdown parser bash interpretation error) | Orchestrator post-condition check (expected result pattern missing) |
| `hook_abnormal_exit` | A hook script returns non-zero exit code or stderr ERROR message | Skill internal failure paths (file modification error, work memory PATCH failure, etc.) |
| `manual_fallback_adopted` | User selects "manual Edit fallback" option in any orchestrator `AskUserQuestion` | Orchestrator fallback prompts (Phase 5.2 lint:aborted, Phase 5.3 pr:create-failed, Phase 5.4.4 fix:error, Phase 5.5 ready:error) |
| `wiki_ingest_skipped` (#524) | `wiki.enabled=false` or `wiki.auto_ingest=false` causes Phase X.X.W (`pr/review.md` 6.5.W / `pr/fix.md` 4.6.W / `issue/close.md` 4.4.W) to skip the Wiki ingest pipeline | Sub-skill emits sentinel from Phase X.X.W Step 1 along with `[CONTEXT] WIKI_INGEST_SKIPPED=1; reason=...` status line |
| `wiki_ingest_failed` (#524) | `wiki-ingest-trigger.sh` exits with a non-zero code other than 2 (exit 2 = Wiki disabled/uninitialized = legitimate skip) during Phase X.X.W | Sub-skill emits sentinel from Phase X.X.W Step 3 along with `[CONTEXT] WIKI_INGEST_FAILED=1; reason=trigger_exit_{n}` status line |
| `wiki_ingest_push_failed` (#555) | `wiki-ingest-commit.sh` exits 4 — commit landed locally on the wiki branch but origin push failed during Phase X.X.W.2 | Sub-skill emits sentinel along with `[CONTEXT] WIKI_INGEST_PUSH_FAILED=1; reason=commit_rc_4` status line |
| `gitignore_drift` (#567) | `/rite:lint` Phase 3.9 detects that the `.rite/wiki/` rule (PR #564 last-line-of-defense) is missing from `.gitignore`, OR `same_branch` strategy lacks the required negation entry | `gitignore-health-check.sh` emits sentinel via `workflow-incident-emit.sh` when drift is detected |

### Sentinel Format

The `root_cause_hint` field is **optional** and entirely omitted from the sentinel line when empty:

```
[CONTEXT] WORKFLOW_INCIDENT=1; type=<type>; details=<details>; (root_cause_hint=<hint>; )?iteration_id=<pr>-<epoch>
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `type` | enum | yes | One of `skill_load_failure` / `hook_abnormal_exit` / `manual_fallback_adopted` / `wiki_ingest_skipped` / `wiki_ingest_failed` (#524) / `wiki_ingest_push_failed` (#555) / `gitignore_drift` (#567) |
| `details` | string | yes | One-line incident description (semicolons replaced by commas, newlines stripped) |
| `root_cause_hint` | string | no | Optional cause hypothesis (omitted from sentinel if empty) |
| `iteration_id` | string | yes | `{pr_number}-{epoch_seconds}` for traceability |

Sentinels are emitted by `plugins/rite/hooks/workflow-incident-emit.sh`. Detection happens in `/rite:issue:start` Phase 5.4.4.1 via context grep.

### Detection Logic

1. **Sentinel detection**: Phase 5.4.4.1 grep the recent conversation context for `[CONTEXT] WORKFLOW_INCIDENT=1` lines after each Skill invocation in Phase 5.
2. **Parse fields**: Extract `type`, `details`, `root_cause_hint`, `iteration_id`.
3. **Duplicate suppression**: A context-local `workflow_incident_processed_types` set tracks types already handled in the current session. Re-occurrences of the same type are silently logged but not re-prompted.
4. **User confirmation**: `AskUserQuestion` presents the incident details with options "register as Issue (recommended) / skip".
5. **Issue creation**: On user approval, calls `plugins/rite/scripts/create-issue-with-projects.sh` with `Status: Todo / Priority: High / Complexity: S / source: workflow_incident`.
6. **Non-blocking error handling**: Failure to create Issue does not abort the workflow. The incident is retained in `workflow_incident_skipped` for Phase 5.6 reporting.

### Configuration

```yaml
workflow_incident:
  enabled: true              # default-on; set false to opt out entirely
```

When the `workflow_incident:` section is absent, defaults are used (effective `enabled: true`).

The current implementation always behaves as non-blocking (registration failure does not halt the workflow) and deduplicates incidents per session (same type is only prompted once).

### Acceptance Criteria Mapping

| AC | Behavior | Implementation |
|----|----------|---------------|
| AC-1 | Skill load failure detection | `start.md` Phase 5.4.4.1 context grep + skill internal sentinel emit |
| AC-2 | User-approved Issue creation | `create-issue-with-projects.sh` call with `Priority: High / Complexity: S` |
| AC-3 | Skip path retention | `workflow_incident_skipped` list + Phase 5.6 reporting section |
| AC-4 | Same-type dedupe | `workflow_incident_processed_types` context-local set |
| AC-5 | Hook abnormal exit detection | `workflow-incident-emit.sh --type hook_abnormal_exit` from skill failure paths |
| AC-6 | Manual fallback detection | Orchestrator fallback prompt options emit `--type manual_fallback_adopted` |
| AC-7 | Default-on | Phase 5.0 Step 6 reads config with default `true` when absent |
| AC-8 | Opt-out | `workflow_incident.enabled: false` skips Phase 5.4.4.1 entirely |
| AC-9 | Phase 7 non-interference | Independent codepath; only `create-issue-with-projects.sh` shared |
| AC-10 | Non-blocking on registration failure | `non_blocking_projects: true` + warning to stderr + workflow continues |

### Phase 7 Relationship

Phase 7 (Automatic Issue Creation from review recommendations) and Phase 5.4.4.1 (Workflow Incident Detection) are **independent codepaths** that share only `create-issue-with-projects.sh` as a common helper. Both may run in the same `/rite:issue:start` flow and create separate Issues. There is no logic merging.

| Phase | Purpose | Source field |
|-------|---------|--------------|
| Phase 7 | Issues from reviewer "別 Issue として作成" recommendations | `pr_review` |
| Phase 5.4.4.1 | Issues from workflow blockers (sentinel-detected) | `workflow_incident` |

## Experience Wiki

### Overview

The Experience Wiki is an LLM-driven project knowledge base that persists **experiential heuristics** — the "what we learned the hard way" lessons that usually live only in reviewer heads or scattered across Issue/PR comments. It is based on the LLM Wiki pattern (Karpathy). The full design rationale lives in `docs/designs/experience-heuristics-persistence-layer.md`.

Wiki is **opt-out** by default (`wiki.enabled: true`). Configuration lives under the `wiki:` section of `rite-config.yml` — see [Configuration Reference → wiki](CONFIGURATION.md#wiki).

### Architecture

Wiki data is stored in a dedicated branch (default: `wiki`) or inline on the working branch, controlled by `wiki.branch_strategy`. Each Wiki page is a Markdown file keyed by topic (e.g., `review-quality.md`, `fix-cycle-convergence.md`). Pages are built up incrementally from raw sources (review comments, fix outcomes, Issue discussions) through an ingest pipeline that deduplicates and merges overlapping heuristics.

### Commands

| Command | Purpose |
|---------|---------|
| `/rite:wiki:init` | One-time setup: create the Wiki branch (if `branch_strategy: "separate_branch"`), scaffold directory structure, and install page templates |
| `/rite:wiki:ingest` | Parse raw sources (review results, fix outcomes, closed Issues) and update or create Wiki pages. Invoked manually or automatically by the `wiki-ingest-trigger.sh` hook |
| `/rite:wiki:query` | Search Wiki pages by keyword and inject matching heuristics into the conversation context. Invoked manually or automatically by the `wiki-query-inject.sh` hook at Issue start / review / fix / implement phases |
| `/rite:wiki:lint` | Check Wiki pages for contradictions, staleness, orphans (pages with no cross-refs), missing concepts (`missing_concept`), unregistered raw sources (`unregistered_raw`, informational — not added to `n_warnings`), and broken cross-refs. Supports `--auto` mode for CI-style batch runs |

### Automatic Hook Integration

When `wiki.auto_ingest`, `wiki.auto_query`, or `wiki.auto_lint` are enabled, the following hooks fire without user action:

| Hook | Trigger | Action |
|------|---------|--------|
| `wiki-query-inject.sh` | Phase 2.6 (work memory init), Phase 5.1 (implement), Phase 5.4.1 (review), Phase 5.4.4 (fix) | Run `/rite:wiki:query` against the current Issue title/body and inject matching heuristics |
| `wiki-ingest-trigger.sh` | Phase 5.4.3 (after review), Phase 5.4.6 (after fix), Issue close | Write a raw source file into `.rite/wiki/raw/{type}/` on the dev branch working tree (pure file writer, no git operations) |
| `wiki-ingest-commit.sh` | Phase 6.5.W.2 (review), Phase 4.6.W.2 (fix), Phase 4.4.W.2 (close) — immediately after the trigger | Move pending raw sources onto the `wiki` branch and commit + push them **in a single shell process** with no dependency on Claude multi-step orchestration |
| `/rite:wiki:ingest` | Manual or optional post-commit invocation | LLM-driven page integration: read accumulated raw sources, produce/update wiki pages, refresh `index.md` / `log.md` |
| `/rite:wiki:lint --auto` | After each successful page integration (when `auto_lint: true`) | Validate Wiki consistency; surface warnings without blocking the workflow |

### Phase X.X.W Mandatory Execution (#524 + shell commit refactor)

`pr/review.md` Phase 6.5.W / 6.5.W.2, `pr/fix.md` Phase 4.6.W / 4.6.W.2, and `issue/close.md` Phase 4.4.W / 4.4.W.2 collectively form the **Wiki growth path**. Issue #524 hardened this path against silent skip with a 3-layer defense; the subsequent shell-commit refactor added a deterministic foundation underneath layers 1-3.

| Layer | Mechanism | Files |
|-------|-----------|-------|
| **0. Deterministic raw-commit path** | Phase X.X.W.2 invokes `wiki-ingest-commit.sh` directly as a single shell process. The script stashes raw sources into `/tmp`, removes them from the dev working tree, stashes any remaining unrelated changes, checks out the wiki branch, replays the staged raw sources, commits, pushes, checks out the original branch again, and pops the stash — all within one `bash` invocation. This eliminates dependency on Claude multi-step orchestration (the root cause of the pre-refactor regression where the `wiki` branch never grew despite multiple rounds of layer 1-3 defence — Issues #515, #518, #524). | `hooks/scripts/wiki-ingest-commit.sh`, `pr/review.md`, `pr/fix.md`, `issue/close.md` |
| **1. Mandatory execution** | Each Phase X.X.W explicitly states "**NEVER** skipped under E2E Output Minimization" and emits an observable `[CONTEXT] WIKI_INGEST_DONE=1` / `WIKI_INGEST_SKIPPED=1; reason=...` / `WIKI_INGEST_FAILED=1; reason=...` line at completion (success / config-skip / commit-failure) | `pr/review.md`, `pr/fix.md`, `issue/close.md` |
| **2. Sentinel-based observability** | Both legitimate skip (`wiki_ingest_skipped`) and commit failure (`wiki_ingest_failed`) emit workflow-incident sentinels via `workflow-incident-emit.sh`, which `start.md` Phase 5.4.4.1 detects via context grep and surfaces to the user via `AskUserQuestion` | `workflow-incident-emit.sh`, `start.md` Phase 5.4.4.1 |
| **3. Lint growth check** | `lint.md` Phase 3.8 runs `wiki-growth-check.sh` which warns (non-blocking, `[lint:success]` retained) when `wiki.growth_check.threshold_prs` consecutive merged PRs land without a corresponding wiki branch commit. With layer 0 in place, a growth stall is a genuine regression signal (no longer confounded by fragile orchestration), and the warning is worth investigating promptly even though the contract remains non-blocking. | `wiki-growth-check.sh`, `lint.md` Phase 3.8 |

**Responsibility split after the refactor**: `wiki-ingest-commit.sh` commits **raw sources only**. LLM-driven Wiki **page** integration (reading raw sources, deciding create/update/skip, writing `.rite/wiki/pages/*`) is **deferred** to `/rite:wiki:ingest`, which is idempotent over accumulated raw sources and can be invoked at a later, independent time (manually or in a separate session). This separation guarantees that raw sources are never lost even when page integration is skipped or fails.

Layer 3's threshold is configurable via `wiki.growth_check.threshold_prs` (default: 5). Setting it to a very large number effectively disables the lint check while preserving layers 0-2.

The completion report (`start.md` Phase 5.6.2) **always** includes a "Wiki ingest 状況" section that aggregates these signals so the user has a definitive answer about whether the Wiki branch grew during each `/rite:issue:start` invocation. AC-5 of #524 explicitly requires this section to render even when all counters are zero (the absence is itself the regression signal).

### Relationship to Workflow Incident Detection

Both features persist operational learnings, but their scopes are distinct:

| Concern | Destination |
|---------|-------------|
| **Recurring quality/process heuristics** (e.g., "review-fix loops should not skip LOW findings", "use dotenvx not dotenv") | Wiki pages via `/rite:wiki:ingest` |
| **One-time platform defects** (e.g., "hook X exited abnormally in iteration Y") | Issues via `workflow_incident` auto-registration (#366) |

They share no code paths.

## Sub-skill Return Auto-Continuation Contract

### Overview (#525)

When an orchestrator command (e.g., `/rite:issue:start`, `/rite:issue:create`) invokes a sub-skill via the Skill tool and the sub-skill outputs its result pattern (e.g., `[interview:skipped]`, `[review:mergeable]`, `[create:completed:{N}]`), control returns to the orchestrator LLM. The orchestrator **MUST** continue executing the next phase in the **same response turn** — the sub-skill return is a continuation trigger, not a turn boundary.

Violating this contract leaves the workflow partially executed: no Issue created, `.rite-flow-state` stuck in `active: true`, stale timestamps, and the user forced to type `continue` manually to recover. Issue #525 was filed after multiple instances of this failure in `/rite:issue:create` with the Bug Fix preset.

### The defense-in-depth layers

| Layer | Mechanism | Enforced by |
|-------|-----------|------------|
| **1. Prompt contract** | Anti-pattern / correct-pattern examples + "same response turn" / "DO NOT stop" phrases in orchestrator documentation | `commands/issue/start.md` Sub-skill Return Protocol (Global), `commands/issue/create.md` Sub-skill Return Protocol, `plugins/rite/skills/rite-workflow/references/sub-skill-return-protocol.md` |
| **2. Flow state** | Sub-skills write `*_post_*` phase markers with `active: true` before return; `stop-guard.sh` blocks every stop attempt until the orchestrator reaches the terminal phase (`create_completed` with `active: false` for `/rite:issue:create`) | `hooks/flow-state-update.sh`, `hooks/stop-guard.sh` |
| **3. Caller-continuation hints** | Plain-text reminder + HTML comment immediately before the sub-skill's result pattern. The plain-text line renders in user-facing output; the HTML comment is visible to the LLM via conversation context but does NOT render in Markdown. Dual form ensures robustness against rendering modes that strip comments (#552). | Defense-in-Depth sections in `commands/issue/create-interview.md`, `commands/issue/create-register.md`, `commands/issue/create-decompose.md` |
| **4. Pre-check list (#552)** | 4-item self-check the orchestrator runs before ending any response turn: (a) `[create:completed:{N}]` output? (b) `✅ Issue #{N} を作成しました` shown? (c) `.rite-flow-state` deactivated? (d) last sub-skill tag handled as continuation trigger? A single `NO` means the workflow is mid-flight. | `commands/issue/create.md` "Pre-check list" section |
| **5. Completion message (#552)** | Terminal sub-skills emit an explicit `✅ Issue #{N} を作成しました: {url}` line **before** the `[create:completed:{N}]` sentinel. The sentinel remains the absolute last line for grep-based tooling (AC-4 backward compat). | `commands/issue/create-register.md` Phase 4.2, `commands/issue/create-decompose.md` Phase 1.0.2 |
| **6. stop-guard incident emit (#552)** | When `stop-guard.sh` blocks an implicit stop during `create_post_interview` / `create_delegation` / `create_post_delegation`, it captures a `manual_fallback_adopted` workflow_incident sentinel from `workflow-incident-emit.sh` and echoes it to stderr. stop-hook stderr is fed back to the assistant via the exit-2 contract, so Phase 5.4.4.1 grep-detects it in the next context cycle for post-hoc visibility. | `hooks/stop-guard.sh` (best-effort, non-blocking — helper missing / failure is recorded to diag log but does not alter the stop-block decision) |

All six layers are complementary. Removing any one weakens the contract — e.g., weakening Layer 1 (prompt) without adding Layer 4 (Pre-check list) re-opens the original #525 failure mode. #552 added Layers 4-6 after re-occurrence under dogfooding (Bug Fix preset with Phase 0.5 skipped).

### Contract specification

For every Skill tool invocation within an orchestrator:

1. When the sub-skill returns control (outputs its result pattern), the orchestrator LLM **MUST NOT** end its response.
2. The orchestrator **MUST NOT** re-invoke the completed sub-skill.
3. The orchestrator **MUST** execute its 🚨 Mandatory After section for the current phase, beginning with the `.rite-flow-state` update, then proceeding to the next phase — all in the same response turn.
4. If `stop-guard.sh` blocks a stop attempt (exit 2), the orchestrator **MUST** follow the `ACTION:` instructions in the hook's stderr message, not retry the stop.

The contract ends only when the orchestrator's terminal completion marker has been output:

| Orchestrator | Terminal marker |
|-------------|----------------|
| `/rite:issue:start` | Phase 5.6 completion report + Workflow Termination block |
| `/rite:issue:create` | `[create:completed:{N}]` as the absolute last line |

### Phase-aware stop-guard hints (#525)

When `stop-guard.sh` blocks a stop attempt with an active `.rite-flow-state`, the blocking message now includes phase-specific continuation hints for `/rite:issue:create` paths:

| Active phase | Hint content |
|-------------|-------------|
| `create_post_interview` | "Sub-skill rite:issue:create-interview returned. The return tag is a CONTINUATION TRIGGER, not a turn boundary. Immediately run Phase 0.6 → Delegation Routing Pre-write → invoke rite:issue:create-register (or create-decompose) in the SAME response turn." |
| `create_delegation` | "Delegation sub-skill is in-flight. When it returns `[create:completed:{N}]`, run Mandatory After Delegation self-check in the SAME response turn. DO NOT stop before the completion marker is output." |
| `create_post_delegation` | "Terminal sub-skill returned without `[create:completed:{N}]` (defense-in-depth path). Run Mandatory After Delegation Step 2 (deactivate flow state) and Step 3 (output next-steps) in the SAME response turn to force the workflow into the terminal state." |

These hints are **best-effort**: they only fire when a stop attempt is actually blocked, so they act as a backstop for the prompt contract rather than a primary enforcement mechanism. The primary path is the prompt contract (Layer 1).

### Optional sentinel: `auto_continuation_failed` (MAY)

When the contract is violated in practice — i.e., the user types `continue` to recover — the orchestrator **MAY** emit the `auto_continuation_failed` sentinel via `plugins/rite/hooks/workflow-incident-emit.sh` so the incident is auto-registered as an Issue via Phase 5.4.4.1 (Workflow Incident Detection).

This sentinel is classified as **MAY** rather than **MUST** because:

1. The detection heuristic (recognising a `continue`-recovery as a contract violation) has false-positive risk — users may type `continue` for reasons unrelated to auto-continuation (e.g., resuming after a legitimate user-initiated pause).
2. Implementation is scoped to a follow-up PR (#525 Decision Log D-02) to avoid bloating the main fix.

Sentinel format (when implemented):

```
[CONTEXT] WORKFLOW_INCIDENT=1; type=auto_continuation_failed; details=<details>; iteration_id=<pr>-<epoch>
```

The sentinel would integrate with the existing Phase 5.4.4.1 detection flow (same as the existing five sentinel types: `skill_load_failure`, `hook_abnormal_exit`, `manual_fallback_adopted`, `wiki_ingest_skipped`, `wiki_ingest_failed`) — no new dispatch code is required in the orchestrator. Note: the `type` enum in the "Workflow Incident Detection" section above remains five-valued until `auto_continuation_failed` is implemented.

### Acceptance criteria

| AC | Description |
|----|-------------|
| AC-1 | bug fix preset で `/rite:issue:create` が end-to-end で `[create:completed:{N}]` まで自動完了する（利用者の `continue` 介入なし） |
| AC-2 | M complexity 以上で interview 完了後に同 turn 内で `create-register` が発火する |
| AC-3 | `create.md` の Sub-skill Return Protocol セクションに "anti-pattern" / "correct-pattern" / "same response turn" / "DO NOT stop" の 4 phrase が全て含まれる |
| AC-4 | `auto_continuation_failed` sentinel 実装時、Phase 5.4.4.1 detection で観測可能（MAY — 本 Issue スコープ外） |
| AC-5 | Terminal Completion pattern (`[create:completed:{N}]` + `.rite-flow-state active: false`) が引き続き動作する (non-regression) |
| AC-6 (#552) | Terminal sub-skill の最終出力に `✅` で始まるユーザー向け完了メッセージが含まれる。Register 経路: `✅ Issue #{N} を作成しました: {url}`、Decompose 経路: `✅ Issue #{N} を分解して {count} 件の Sub-Issue を作成しました: {url}`。いずれの形式も `[create:completed:{N}]` は最終行として維持される |
| AC-7 (#552) | `stop-guard.sh` が `create_post_interview` / `create_delegation` / `create_post_delegation` phase で implicit stop を block した際、`manual_fallback_adopted` workflow_incident sentinel を `workflow-incident-emit.sh` から capture し、stderr に echo する (stop-hook stderr は exit-2 契約で assistant にフィードされる)。helper 不在 / 失敗時は diag log に記録されるが block 決定には影響しない |
| AC-8 (#552) | `create.md` に "Pre-check list" セクションが存在し、4 項目全て `YES` が turn 終了の必要条件として文書化されている |

### Relationship to Workflow Incident Detection

Phase 5.4.4.1 (Workflow Incident Detection) currently treats five sentinel types as contract violations (`skill_load_failure`, `hook_abnormal_exit`, `manual_fallback_adopted`, `wiki_ingest_skipped`, `wiki_ingest_failed`). The optional `auto_continuation_failed` sentinel (MAY, scoped to a follow-up PR — see Decision Log D-02 in Issue #525) would integrate via the same flow when implemented; until then, the `type` enum remains five-valued. All sentinel types share the same detection → AskUserQuestion → Issue registration flow via `create-issue-with-projects.sh`.

## Error Handling

### Auto-Retry

| Error Type | Retry Count | Interval |
|------------|-------------|----------|
| GitHub API temporary error (5xx) | 3 | Exponential backoff |
| Network error | 3 | 5 seconds |
| Rate limit (429) | 1 after wait | API-specified time |

### Manual Recovery Guidance

For persistent errors, provide:

1. **Detailed error explanation**
2. **Possible causes** (list if multiple)
3. **Recovery steps** (step-by-step)
4. **Links to related documentation**

### Common Errors and Solutions

| Error | Cause | Solution |
|-------|-------|----------|
| `gh: command not found` | gh CLI not installed | Guide in `/rite:init` |
| `authentication required` | GitHub not authenticated | Guide `gh auth login` |
| `branch already exists` | Branch conflict | Suggest alternative name |
| `Context limit reached` | Long-running flow exceeded context window | `/clear` then `/rite:resume` |

### Context Limit Recovery

Long-running commands such as `/rite:issue:start` (end-to-end flow: branch creation → implementation → PR creation → review) may exceed Claude Code's context window and get interrupted with `Context limit reached`.

**Recovery steps:**

1. Run `/clear` to reset the context
2. Run `/rite:resume` to continue from where it left off

**Why this works:**

- Work memory (Issue comments) and `.rite-flow-state` persist workflow state across sessions
- All git artifacts (branches, commits, PRs) are preserved — nothing is lost
- `/rite:resume` reads the persisted state and resumes the appropriate phase

**What is preserved:**

| Artifact | Storage | Survives context limit |
|----------|---------|------------------------|
| Branch | Git | Yes |
| Commits | Git | Yes |
| Draft PR | GitHub | Yes |
| Work memory | Issue comment | Yes |
| Flow state | `.rite-flow-state` | Yes |

### API Error Handling

#### Retry Strategy

| Error Type | Response |
|-----------|----------|
| Network error | Max 3 retries (exponential backoff: 2s, 4s, 8s) |
| Rate limit (403/429) | Wait per `Retry-After` header, then retry |
| Auth error (401) | Display error, guide `gh auth login` |
| Not Found (404) | Display error, guide configuration check |
| Server error (5xx) | Max 2 retries (3s interval) |

#### Fallback Strategy

| Situation | Fallback Behavior |
|-----------|-------------------|
| Project API failure | Execute Issue creation only, skip Projects operations |
| Iteration API failure | Display warning, skip Iteration operations |
| Field update failure | Display warning, continue to next operation |
| Status update failure | Guide manual update method |

#### Error Message Format

```
Error: {error summary}

Cause: {possible cause}

Solution:
1. {step 1}
2. {step 2}

Details: {technical details for debugging}
```

---

## Migration

### Introducing to Existing Projects

**Hybrid Approach:**

- Existing Issues are read-only (viewable via `/rite:issue:list`)
- Edit/update only newly created Issues
- Auto-link if existing Projects found

### Version Upgrade

**Auto-Migration:**

1. Auto-convert configuration file format
2. Update Projects field structure
3. Create backup on breaking changes

---

## Internationalization

### Language Auto-Detection

1. Detect user input language (from recent input)
2. Reference system locale
3. Check `language` setting in config file

### Supported Languages

- Japanese (ja)
- English (en)

### Language File Structure

Language files use a split directory structure organized by language and domain:

```
plugins/rite/i18n/
├── en.yml              # English (deprecated, kept for backward compatibility)
├── ja.yml              # Japanese (deprecated, kept for backward compatibility)
├── en/
│   ├── common.yml      # Common messages (shared across commands)
│   ├── issue.yml       # Issue-related messages
│   ├── pr.yml          # PR-related messages
│   └── other.yml       # Other messages (init, resume, lint, etc.)
└── ja/
    ├── common.yml      # 共通メッセージ
    ├── issue.yml       # Issue 関連メッセージ
    ├── pr.yml          # PR 関連メッセージ
    └── other.yml       # その他メッセージ（init, resume, lint 等）
```

Each domain file contains keys grouped by command context (e.g., `# rite:init`, `# rite:resume`). Messages are referenced in commands using `{i18n:key_name}` placeholder syntax.

---

## Dependencies

### Required

| Tool | Purpose | Installation Check |
|------|---------|-------------------|
| gh CLI | GitHub API operations | `gh --version` |

### Optional

| Tool | Purpose |
|------|---------|
| Project-specific build tools | Build/Test/Lint |

---

## Distribution

Distributed via Claude Code plugin system:

```bash
# Add the marketplace
/plugin marketplace add B16B1RD/cc-rite-workflow

# Install the plugin
/plugin install rite@rite-marketplace
```

---

## Project Types

### Supported Types

| Type | Description | Characteristics |
|------|-------------|-----------------|
| `generic` | Universal | Basic field configuration |
| `webapp` | Web Application | Front/Back/DB separation |
| `library` | OSS Library | Breaking changes, CHANGELOG focus |
| `cli` | CLI Tool | Command changes, compatibility focus |
| `documentation` | Documentation | Build, link verification focus |

### Type-Specific PR Templates

#### generic

```markdown
## Summary
<!-- 1-2 sentence description -->

## Changes
- Change description

## Checklist
- [ ] Tested
- [ ] Documentation updated

Closes #XXX
```

#### webapp

```markdown
## Summary

## Changes
- [ ] Frontend
- [ ] Backend
- [ ] Database

## Screenshots
<!-- If applicable -->

## Test Plan
- [ ] Unit tests
- [ ] E2E tests
- [ ] Manual testing

## Performance Impact
<!-- If applicable -->

Closes #XXX
```

#### library

```markdown
## Summary

## Changes

## Breaking Changes
- [ ] None
- [ ] Yes (details: )

## Migration Guide
<!-- If breaking changes exist -->

## Tests
- [ ] Unit tests
- [ ] Integration tests

## Documentation
- [ ] API docs updated
- [ ] README updated
- [ ] CHANGELOG updated

Closes #XXX
```

#### cli

```markdown
## Summary

## Changes

## Command Changes
- [ ] New command added
- [ ] Existing command modified
- [ ] Options added/changed

## Compatibility
- [ ] Backward compatible
- [ ] Breaking changes

## Help/Manual
- [ ] --help updated
- [ ] man page updated

Closes #XXX
```

#### documentation

```markdown
## Summary

## Changes
- [ ] New documentation
- [ ] Existing documentation update
- [ ] Structure changes

## Checklist
- [ ] Build successful
- [ ] Links verified
- [ ] Spell checked
- [ ] Style guide compliant

## Preview
<!-- Preview URL, etc. -->

Closes #XXX
```

---

## Future Extensions

1. **Enhanced AI Code Review**
   - More detailed security analysis
   - Performance optimization suggestions

2. **CI/CD Integration**
   - GitHub Actions integration
   - Auto-deploy triggers

3. **Metrics & Dashboard**
   - Development velocity visualization
   - Issue resolution time analysis

---

## References

- [Best Practices for Claude Code](https://code.claude.com/docs/en/best-practices)
- [Best Practices Alignment](BEST_PRACTICES_ALIGNMENT.md) - How rite workflow aligns with best practices
- [Claude Code Plugins Reference](https://code.claude.com/docs/en/plugins-reference)
- [GitHub CLI Documentation](https://cli.github.com/manual/)
- [Conventional Commits](https://www.conventionalcommits.org/)
