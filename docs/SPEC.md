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
12. [Error Handling](#error-handling)
13. [Migration](#migration)
14. [Internationalization](#internationalization)
15. [Dependencies](#dependencies)
16. [Distribution](#distribution)
17. [Project Types](#project-types)

---

## Command List

| Command | Description | Arguments |
|---------|-------------|-----------|
| `/rite:init` | Initial setup wizard | None |
| `/rite:workflow` | Show workflow guide | None |
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
├── commands/
│   ├── init.md              # /rite:init
│   ├── getting-started.md   # /rite:getting-started
│   ├── workflow.md          # /rite:workflow
│   ├── issue/
│   │   ├── list.md          # /rite:issue:list
│   │   ├── create.md        # /rite:issue:create
│   │   ├── start.md         # /rite:issue:start
│   │   ├── update.md        # /rite:issue:update
│   │   ├── close.md         # /rite:issue:close
│   │   └── completion-report.md  # Completion report format
│   ├── pr/
│   │   ├── create.md        # /rite:pr:create
│   │   ├── ready.md         # /rite:pr:ready
│   │   ├── review.md        # /rite:pr:review
│   │   ├── fix.md           # /rite:pr:fix
│   │   ├── cleanup.md       # /rite:pr:cleanup
│   │   └── references/
│   │       ├── assessment-rules.md        # Review assessment rules
│   │       ├── archive-procedures.md      # Archive procedures
│   │       ├── review-context-optimization.md  # Review context optimization
│   │       ├── reviewer-fallbacks.md      # Reviewer fallback profiles
│   │       ├── change-intelligence.md     # Change intelligence
│   │       └── fix-relaxation-rules.md    # Fix relaxation rules
│   ├── lint.md              # /rite:lint
│   ├── resume.md            # /rite:resume
│   ├── skill/
│   │   └── suggest.md       # /rite:skill:suggest
│   ├── sprint/
│   │   ├── list.md          # /rite:sprint:list
│   │   ├── current.md       # /rite:sprint:current
│   │   ├── plan.md          # /rite:sprint:plan
│   │   ├── execute.md       # /rite:sprint:execute
│   │   └── team-execute.md  # /rite:sprint:team-execute
│   └── template/
│       └── reset.md         # /rite:template:reset
├── agents/
│   ├── security-reviewer.md        # Security vulnerability detection
│   ├── performance-reviewer.md     # Performance issue detection
│   ├── code-quality-reviewer.md    # Code quality review
│   ├── api-reviewer.md             # API design review
│   ├── database-reviewer.md        # Database schema/query review
│   ├── devops-reviewer.md          # Infrastructure/CI-CD review
│   ├── frontend-reviewer.md        # UI/accessibility review
│   ├── test-reviewer.md            # Test quality review
│   ├── dependencies-reviewer.md    # Dependency security review
│   ├── prompt-engineer-reviewer.md # Skill/command definition review
│   ├── tech-writer-reviewer.md     # Documentation review
│   └── sprint-teammate.md          # Sprint team member
├── skills/
│   ├── rite-workflow/
│   │   ├── SKILL.md         # Auto-apply skill
│   │   └── references/      # Coding principles, context management
│   └── reviewers/
│       └── SKILL.md         # Reviewer skill + review criteria
├── hooks/
│   ├── session-start.sh
│   ├── session-end.sh
│   ├── pre-compact.sh
│   ├── stop-guard.sh
│   ├── preflight-check.sh
│   ├── post-compact-guard.sh
│   ├── pre-tool-bash-guard.sh
│   ├── post-tool-wm-sync.sh
│   ├── local-wm-update.sh
│   ├── work-memory-lock.sh
│   ├── work-memory-update.sh
│   ├── work-memory-parse.py
│   ├── cleanup-work-memory.sh
│   ├── state-path-resolve.sh
│   ├── flow-state-update.sh
│   ├── issue-body-safe-update.sh
│   ├── context-pressure.sh
│   └── notification.sh
├── templates/
│   ├── completion-report.md  # Completion report format definition
│   ├── project-types/
│   │   ├── generic.yml
│   │   ├── webapp.yml
│   │   ├── library.yml
│   │   ├── cli.yml
│   │   └── documentation.yml
│   ├── issue/
│   │   └── default.md
│   └── pr/
│       ├── generic.md
│       ├── webapp.md
│       ├── library.md
│       ├── cli.md
│       └── documentation.md
├── scripts/
│   └── create-issue-with-projects.sh  # Issue creation with Projects integration
├── references/
│   ├── gh-cli-patterns.md
│   ├── graphql-helpers.md
│   └── ...                   # Other reference documents
├── i18n/
│   ├── ja.yml
│   └── en.yml
└── README.md
```

### plugin.json

Plugin metadata file format:

```json
{
  "name": "rite",
  "version": "0.3.7",
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
model: sonnet  # opus | sonnet | haiku
tools:
  - Read
  - Grep
  - Glob
---

# Agent Name

Agent documentation...
```

| Field | Required | Description |
|-------|----------|-------------|
| `name` | Yes | Unique agent identifier |
| `description` | Yes | Short description for Task tool |
| `model` | No | Model selection (default: inherit from parent) |
| `tools` | Yes | List of available tools |

**Current Agents:**

| Agent | Model | Purpose |
|-------|-------|---------|
| `security-reviewer` | opus | Security vulnerabilities, authentication, data handling |
| `performance-reviewer` | opus | N+1 queries, memory leaks, algorithm efficiency |
| `code-quality-reviewer` | opus | Duplication, naming, error handling, structure |
| `api-reviewer` | opus | API design, REST conventions, interface contracts |
| `database-reviewer` | opus | Schema design, queries, migrations, data operations |
| `devops-reviewer` | opus | Infrastructure, CI/CD pipelines, deployment configurations |
| `frontend-reviewer` | opus | UI components, styling, accessibility, client-side code |
| `test-reviewer` | opus | Test quality, coverage, testing strategies |
| `dependencies-reviewer` | opus | Package dependencies, versions, supply chain security |
| `prompt-engineer-reviewer` | opus | Claude Code skill and command definitions |
| `tech-writer-reviewer` | opus | Documentation clarity, accuracy, completeness |

---

## Configuration File Specification

### rite-config.yml

Place in project root or `.claude/` directory.
Uses YAML format for readability and comment support.

```yaml
# rite-workflow configuration file
version: "1.0"

# Project settings
project:
  type: webapp  # generic | webapp | library | cli | documentation
  name: "My Project"

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
          - { name: "BLOCKS" }
          - { name: "Autonomous" }
          - { name: "ComPath" }
          - { name: "Migration" }
          - { name: "Other" }

# Branch naming rules (fully customizable)
branch:
  # Base branch for feature branches (default PR target)
  base: "main"      # default: main (use "develop" for Git Flow)
  # Release branch (for production releases)
  release: "main"   # default: main
  pattern: "{type}/issue-{number}-{slug}"
  # Available variables: {type}, {number}, {slug}, {date}, {user}
  types:
    feature: "feat"
    bugfix: "fix"
    documentation: "docs"
    refactor: "refactor"
    chore: "chore"
    style: "style"

# Commit message
commit:
  style: conventional  # conventional | free
  enforce: false  # If true, warn on format violation

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
    events:
      - issue_created
      - pr_created
      - pr_ready
      - review_completed
  discord:
    enabled: false
    webhook_url: null
  teams:
    enabled: false
    webhook_url: null

# Language setting (auto for auto-detection)
language: auto  # auto | ja | en
```

---

## Command Specifications

### /rite:init

**Description:** Initial setup of rite workflow for a project

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

#### Phase 5: Completion Report
1. Display settings summary
2. Guide next steps

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

#### Phase 2: Work Preparation

1. Generate branch name (per config pattern)
2. Create branch with `git checkout -b`
3. Update GitHub Projects Status to "In Progress"
4. Initialize work memory comment

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

### Changed Files
<!-- Auto-updated -->

### Decisions & Notes
<!-- Important decisions and findings -->

### Next Steps
1. ...
```

**Phase Information:**

The Session Info section of the work memory includes phase information indicating the current work state. This information is used by `/rite:resume` for resuming work.

| Phase | Phase Detail |
|-------|--------------|
| `phase0` | Epic/Sub-Issues detection |
| `phase1` | Quality verification |
| `phase2` | Branch creation & setup |
| `phase3` | Implementation planning |
| `phase4` | Work start preparation |
| `phase5_implementation` | Implementation in progress |
| `phase5_lint` | Quality check in progress |
| `phase5_pr` | PR creation in progress |
| `phase5_review` | Review in progress |
| `phase5_fix` | Review fix in progress |
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

**Verification mode** (`review.loop.verification_mode`): From cycle 2+, reviews perform both a full review and verification of previous fixes with incremental diff regression checks. New MEDIUM/LOW findings in unchanged code are reported as non-blocking "stability concerns".

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
  └─ tech-writer-reviewer: Documentation perspective
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
    events:
      - issue_created
      - pr_created
      - pr_ready
      - review_completed
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
| `issue_created` | When Issue created |
| `issue_started` | When work started |
| `pr_created` | When PR created |
| `pr_ready` | When Ready for review |
| `review_completed` | When review completed |

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

```yaml
# i18n/ja.yml
messages:
  issue_created: "Issue #{number} を作成しました"
  branch_created: "ブランチ {branch} を作成しました"
  ...

# i18n/en.yml
messages:
  issue_created: "Created Issue #{number}"
  branch_created: "Created branch {branch}"
  ...
```

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
