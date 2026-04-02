# Configuration Reference

This document describes all configuration options for Claude Code Rite Workflow.

## Configuration File

The configuration file should be named `rite-config.yml` and placed in:
- Project root (`./rite-config.yml`)
- Or `.claude/` directory (`./.claude/rite-config.yml`)

## Full Configuration Example

```yaml
# Claude Code Rite Workflow configuration file
schema_version: 2

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
      # Any Single Select field from your GitHub Projects can be added here
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
    # Explicit field IDs (optional, overrides auto-detection)
    # field_ids:
    #   status: "PVTSSF_..."      # Status field ID
    #   priority: "PVTSSF_..."    # Priority field ID
    #   complexity: "PVTSSF_..."  # Complexity field ID
    #   # Custom fields
    #   work_type: "PVTSSF_..."   # Custom Single Select field ID

# Branch naming rules
branch:
  base: "main"       # Base branch for feature branches (use "develop" for Git Flow)
  release: "main"    # Release branch for production releases
  pattern: "{type}/issue-{number}-{slug}"
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
  enforce: false

# Build/test/lint commands
commands:
  build: null  # Auto-detect
  test: null   # Auto-detect
  lint: null   # Auto-detect

# Issue settings
issue:
  auto_decompose_threshold: M  # XS | S | M | L | XL | none (default: M)

# Review settings
review:
  min_reviewers: 1      # Fallback when no reviewers match
  criteria:
    - file_types
    - content_analysis
  loop:
    verification_mode: true     # Enable verification mode as supplement to full review (default: true)
    allow_new_findings_in_unchanged_code: false  # Block new findings in unchanged code (default: false)
  security_reviewer:
    mandatory: false                          # Require security reviewer for all PRs (default: false)
    recommended_for_code_changes: true        # Recommend for executable code changes (default: true)
  debate:
    enabled: true            # Enable inter-reviewer debate phase (default: true)
    max_rounds: 1            # Maximum debate rounds for cost control (default: 1)

# Iteration/Sprint settings (optional)
iteration:
  enabled: false          # true to enable iteration features (default: false)
  field_name: "Sprint"    # Name of the iteration field in Projects (default: "Sprint")
  auto_assign: true       # Auto-assign to current iteration on issue:start (default: true)
  show_in_list: true      # Show iteration column in issue:list (default: true)

# Verification gate settings
verification:
  run_tests_before_pr: true          # Run tests before commit/PR (requires commands.test) (default: true)
  acceptance_criteria_check: true    # Check acceptance criteria from Issue body before PR (default: true)

# TDD Light mode settings
tdd:
  mode: "off"              # off | light (default: off)
  tag_prefix: "AC"         # Tag prefix for test skeleton markers (default: "AC")
  run_baseline: true       # Run baseline test before skeleton generation (default: true)
  max_skeletons: 20        # Maximum number of skeletons to generate per Issue (default: 20)

# Parallel implementation settings
parallel:
  enabled: true          # Enable parallel implementation (default: true)
  max_agents: 3          # Maximum concurrent agents (default: 3)
  mode: "shared"         # "shared" (default) or "worktree"
  worktree_base: ".worktrees"  # Base directory for worktrees when mode is "worktree" (default: ".worktrees")

# Team-based sprint execution settings
team:
  enabled: true              # Enable /rite:sprint:team-execute (default: true)
  max_concurrent_issues: 3   # Max Issues to process in parallel per batch (default: 3)
  teammate_model: "sonnet"   # Model for teammate agents (default: "sonnet")
  auto_review: true          # Auto-run /rite:pr:review after all PRs created (default: true)

# Safety settings (fail-closed thresholds)
safety:
  max_review_fix_loops: 7          # review-fix loop hard limit (default: 7)
  max_implementation_rounds: 20    # implementation round hard limit per Issue (default: 20)
  time_budget_minutes: 120         # time budget per Issue in minutes (advisory) (default: 120)
  auto_stop_on_repeated_failure: true   # stop when same failure class repeats (default: true)
  repeated_failure_threshold: 3         # consecutive same-class failure count to trigger stop (default: 3)

# Metrics settings
metrics:
  enabled: true            # Enable/disable metrics recording (default: true)
  baseline_issues: 3       # Number of Issues for baseline collection (default: 3)
  thresholds:
    plan_deviation_rate: 30       # Max plan vs actual step divergence in % (default: 30)
    test_pass_rate: 100           # Required test pass rate at PR creation in % (default: 100)
    review_fix_loops: 3           # Max acceptable review-fix loop count (default: 3)
    review_critical_high_improvement: 0.80  # MA5 improvement factor for CRITICAL+HIGH (default: 0.80)
    plan_deviation_improvement: 0.90        # MA5 improvement factor for plan deviation (default: 0.90)

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

# Language setting
language: auto  # auto | ja | en
```

## Configuration Sections

### project

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `type` | string | `generic` | Project type: `generic`, `webapp`, `library`, `cli`, `documentation` |
| `name` | string | Repository name | Project display name |

### github.projects

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `enabled` | boolean | `true` | Enable GitHub Projects integration |
| `project_number` | integer | `null` | Project number (auto-detected from repository if null) |
| `owner` | string | `null` | Project owner - user or organization (uses repository owner if null) |
| `fields` | object | - | Custom field definitions |
| `field_ids` | object | - | Explicit field IDs (optional, overrides auto-detection) |

### github.projects.field_ids

When specified, these field IDs are used directly instead of auto-detecting via `gh project field-list`. This is useful when:
- API auto-detection is failing (e.g., permission issues, organization policy restrictions)
- You want consistent field IDs without relying on auto-detection

**Note:** Option IDs (e.g., "In Progress", "Done") are always fetched via API regardless of this setting.

| Field | Type | Description |
|-------|------|-------------|
| `status` | string | Field ID for Status field (e.g., `PVTSSF_...`) |
| `priority` | string | Field ID for Priority field |
| `complexity` | string | Field ID for Complexity field |
| *(any custom field)* | string | Field ID for custom Single Select fields (e.g., `work_type`, `category`) |

**Example:**

```yaml
github:
  projects:
    field_ids:
      status: "PVTSSF_your-status-field-id"      # Replace with your actual ID
      priority: "PVTSSF_your-priority-field-id"  # Replace with your actual ID
      # Custom fields
      category: "PVTSSF_your-category-field-id"  # Replace with your actual ID
```

**Behavior:**
- If a field ID is specified in `field_ids`, it is used directly (no API call to detect this field ID)
- If not specified, the field ID is auto-detected via `gh project field-list`
- Partial specification is supported: if only `status` is specified, `priority` and `complexity` will be auto-detected (if enabled in `fields`)

**Finding field IDs:**

Run the following command (replace `1` with your project number and `myorg` with your owner):

```bash
gh project field-list 1 --owner myorg --format json
```

Look for the `id` field in the output for each field.

### github.projects.fields

Each field can have:

| Field | Type | Description |
|-------|------|-------------|
| `enabled` | boolean | Enable this field |
| `options` | array | List of options with `name` and optional `default: true` |

**Standard fields:**

These fields are commonly used in GitHub Projects and have built-in support:

| Field | Description |
|-------|-------------|
| `status` | Issue/PR status tracking (Todo, In Progress, etc.) |
| `priority` | Priority level (High, Medium, Low) |
| `complexity` | Estimated complexity (XS, S, M, L, XL) |

**Custom fields:**

You can add any project-specific Single Select fields by using the same field name as defined in your GitHub Projects. Common examples include `work_type`, `category`, `team`, etc.

```yaml
github:
  projects:
    fields:
      # Standard fields
      status: { enabled: true, options: [...] }
      priority: { enabled: true, options: [...] }

      # Custom fields (project-specific)
      # Field names must match your GitHub Projects field names (case-insensitive)
      work_type:
        enabled: true
        options:
          - { name: "Feature" }
          - { name: "Bug Fix" }
          - { name: "Documentation" }
          - { name: "Refactor" }
      category:
        enabled: true
        options:
          - { name: "Frontend" }
          - { name: "Backend" }
          - { name: "Infrastructure" }
          - { name: "Other" }
```

**Requirements for custom fields:**
- The field name in `rite-config.yml` must match the field name in GitHub Projects (case-insensitive)
- The field must be a Single Select type in GitHub Projects
- Options should match the available options in GitHub Projects

### branch

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `base` | string | `main` | Base branch for feature branches (PR target). Use `develop` for Git Flow. |
| `release` | string | `main` | Release branch for production releases |
| `pattern` | string | `{type}/issue-{number}-{slug}` | Branch name pattern |
| `types` | object | See example | Mapping of work types to prefixes |

**Git Flow Support:**

For Git Flow workflows, configure:

```yaml
branch:
  base: "develop"    # Feature branches are created from develop
  release: "main"    # Production releases go to main
```

This affects the following commands:
- `/rite:issue:start`: Creates branches from `branch.base`
- `/rite:pr:create`: Sets `branch.base` as the PR target
- `/rite:pr:cleanup`: Switches to `branch.base` after cleanup
- `/rite:lint`: Uses `origin/{branch.base}...HEAD` for diff detection (e.g., `origin/develop...HEAD`)

**Recognized Patterns (Non-standard branches):**

For migration projects or other scenarios where branches don't follow the standard `{type}/issue-{number}-{slug}` pattern, you can define additional patterns to recognize:

```yaml
branch:
  recognized_patterns:
    - "migration/phase{n}-{category}"
    - "i18n/{locale}"
    - "hotfix/{date}-{description}"
```

**Pattern variables for `recognized_patterns`:**

These variables are used exclusively in `recognized_patterns` to match existing non-standard branches:

| Variable | Description | Example Match |
|----------|-------------|---------------|
| `{n}` | Any number | `1`, `42`, `100` |
| `{category}` | Any string (alphanumeric + hyphen) | `admin-tutorials`, `api-docs` |
| `{locale}` | Locale code | `ja`, `zh-tw`, `en-us` |
| `{date}` | Date string (any format) | `20250109`, `2025-01-09` |
| `{description}` | Any descriptive string | `fix-login`, `update-deps` |
| `{*}` | Wildcard (any characters) | anything |

**Use cases:**

- Migration projects: `migration/phase4-admin-tutorials`
- Internationalization: `i18n/zh-tw`
- Hotfixes without Issues: `hotfix/20250109-critical-fix`

When `/rite:issue:start` detects an existing branch matching these patterns (see Phase 2.2.1), it will offer to use the branch even though it doesn't contain an Issue number.

**Pattern variables for `branch.pattern`:**

These variables are used in `branch.pattern` to generate new branch names:

| Variable | Description | Example |
|----------|-------------|---------|
| `{type}` | Work type prefix | `feat`, `fix`, `docs` |
| `{number}` | Issue number | `123` |
| `{slug}` | Slugified Issue title | `add-auth-feature` |
| `{date}` | Current date (YYYYMMDD) | `20250103` |
| `{user}` | GitHub username | `octocat` |

### commit

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `style` | string | `conventional` | Commit style: `conventional` or `free` |
| `enforce` | boolean | `false` | Warn on format violation if true |

### commands

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `build` | string | `null` | Build command (auto-detected if null) |
| `test` | string | `null` | Test command (auto-detected if null) |
| `lint` | string | `null` | Lint command (auto-detected if null) |

### issue

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `auto_decompose_threshold` | string | `M` | Complexity threshold for auto-skipping decomposition prompt |

**auto_decompose_threshold values:**

| Value | Behavior |
|-------|----------|
| `XS` | Analyze body at XS; show proposal for S and above |
| `S` | Skip XS; analyze body at S; show proposal for M and above |
| `M` | Skip XS/S; analyze body at M; show proposal for L and above (default) |
| `L` | Skip XS-M; analyze body at L; show proposal for XL |
| `XL` | Skip XS-L; analyze body at XL only (no proposal, as XL is maximum) |
| `none` | Always show decomposition prompt (legacy behavior) |

**Three-tier judgment logic:**

| Condition | Behavior |
|-----------|----------|
| Complexity < threshold | Skip decomposition (proceed directly to work) |
| Complexity == threshold | Analyze Issue body to estimate scope, then decide |
| Complexity > threshold | Show decomposition proposal |

When an Issue's complexity is below the threshold, `/rite:issue:start` will skip the decomposition confirmation and proceed directly to work. When the complexity equals the threshold, the Issue body is analyzed to estimate the scope of changes (number of files mentioned). This reduces unnecessary prompts for simple Issues while still prompting for complex ones.

**Body analysis criteria:** When complexity equals the threshold, the Issue body is analyzed. If 1-2 files are mentioned, decomposition is skipped. If 3+ files are mentioned, decomposition proposal is shown.

**Example:**

```yaml
issue:
  auto_decompose_threshold: S  # Skip for XS, analyze body at S, prompt for M and above
```

### review

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `min_reviewers` | integer | `1` | Minimum number of reviewers (fallback when no reviewers match) |
| `criteria` | array | `[file_types, content_analysis]` | Review criteria |
| `loop.verification_mode` | boolean | `true` | Enable verification mode as supplement to full review. When enabled, reviews after the first cycle perform both full review and verification of previous fixes with incremental diff regression checks |
| `loop.allow_new_findings_in_unchanged_code` | boolean | `false` | Whether new findings in unchanged code should be blocking. When `false`, new MEDIUM/LOW findings in unchanged code are reported as "stability concerns" (non-blocking) |
| `security_reviewer.mandatory` | boolean | `false` | Require security reviewer for all PRs regardless of file types |
| `security_reviewer.recommended_for_code_changes` | boolean | `true` | Include security reviewer when executable code files are changed |
| `debate.enabled` | boolean | `true` | Enable inter-reviewer debate phase |
| `debate.max_rounds` | integer | `1` | Maximum debate rounds (cost control) |

**Review-fix loop convergence:**

The review-fix loop exits only when all findings are resolved (zero blocking findings). There is no iteration limit or progressive relaxation — every finding must be addressed.

**Verification mode** (`verification_mode: true`): From cycle 2+, reviews perform both a full review and verification of previous fixes with incremental diff regression checks. New MEDIUM/LOW findings in unchanged code are classified as "stability concerns" (non-blocking). Set `verification_mode: false` to perform full review only every cycle.

**Review execution:**

`/rite:pr:review` uses Claude Code's Task tool to spawn parallel subagents for each reviewer role. This improves context efficiency and enables parallel execution.

**Available reviewers:**

The following specialized reviewers are automatically selected based on the changed files:

| Reviewer | Focus Area |
|----------|------------|
| `security-reviewer` | Security vulnerabilities, authentication, data handling |
| `performance-reviewer` | N+1 queries, memory leaks, algorithm efficiency |
| `code-quality-reviewer` | Duplication, naming, error handling, structure |
| `api-reviewer` | API design, REST conventions, interface contracts |
| `database-reviewer` | Schema design, queries, migrations, data operations |
| `devops-reviewer` | Infrastructure, CI/CD pipelines, deployment configurations |
| `frontend-reviewer` | UI components, styling, accessibility, client-side code |
| `test-reviewer` | Test quality, coverage, testing strategies |
| `dependencies-reviewer` | Package dependencies, versions, supply chain security |
| `prompt-engineer-reviewer` | Claude Code skill and command definitions |
| `tech-writer-reviewer` | Documentation clarity, accuracy, completeness |

**Reviewer selection:**

Reviewers are automatically selected based on:
1. File patterns (e.g., `*.test.*` triggers `test-reviewer`)
2. Content analysis (e.g., SQL queries trigger `database-reviewer`)
3. Change complexity and scope

**Fallback behavior:**

If a subagent fails or times out:
1. The review continues with remaining subagents
2. Failed subagent's results are marked as "incomplete"
3. User is notified of the failure in the review summary

### iteration

Settings for Sprint/Iteration integration with GitHub Projects.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `enabled` | boolean | `false` | Enable iteration features |
| `field_name` | string | `"Sprint"` | Name of the iteration field in GitHub Projects |
| `auto_assign` | boolean | `true` | Auto-assign Issues to current iteration on `/rite:issue:start` |
| `show_in_list` | boolean | `true` | Show iteration column in `/rite:issue:list` output |

**Example:**

```yaml
iteration:
  enabled: true
  field_name: "Sprint"
  auto_assign: true
  show_in_list: true
```

When enabled, `/rite:issue:start` will automatically assign the Issue to the current active iteration. Use `/rite:sprint:list` to view iterations and `/rite:sprint:current` to see the current sprint details.

### verification

Settings for quality verification gates before PR creation.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `run_tests_before_pr` | boolean | `true` | Run tests before commit/PR (requires `commands.test` to be configured) |
| `acceptance_criteria_check` | boolean | `true` | Check acceptance criteria from Issue body before PR creation |

**Example:**

```yaml
verification:
  run_tests_before_pr: true
  acceptance_criteria_check: true
```

### tdd

Settings for TDD (Test-Driven Development) Light mode. When enabled, test skeletons are generated from acceptance criteria before implementation.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `mode` | string | `"off"` | TDD mode: `"off"` (disabled) or `"light"` (generate test skeletons from acceptance criteria) |
| `tag_prefix` | string | `"AC"` | Tag prefix for test skeleton markers (e.g., `AC-1`, `AC-2`) |
| `run_baseline` | boolean | `true` | Run baseline test suite before generating skeletons to ensure existing tests pass |
| `max_skeletons` | integer | `20` | Maximum number of test skeletons to generate per Issue |

**Example:**

```yaml
tdd:
  mode: "light"
  tag_prefix: "AC"
  run_baseline: true
  max_skeletons: 20
```

**How TDD Light works:**

1. Acceptance criteria are extracted from the Issue body
2. Test skeletons are generated with markers (e.g., `// AC-1: User can log in`)
3. Implementation proceeds to make the skeleton tests pass
4. Test results are verified before PR creation

### parallel

Settings for parallel implementation using Task tool.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `enabled` | boolean | `true` | Enable parallel implementation |
| `max_agents` | integer | `3` | Maximum number of concurrent agents |
| `mode` | string | `"shared"` | Agent working mode: `"shared"` (all agents share working directory) or `"worktree"` (each agent gets independent git worktree) |
| `worktree_base` | string | `".worktrees"` | Base directory for worktrees when `mode` is `"worktree"` |

**When parallel implementation is used:**

Parallel implementation is automatically activated when ALL of the following conditions are met:
1. `parallel.enabled` is `true`
2. Issue complexity is M or higher
3. Multiple independent files/components are identified in the implementation plan

**How it works:**

1. During Phase 5.1 (Implementation), the implementation plan is analyzed
2. If independent tasks are identified (e.g., separate files that don't depend on each other), they are executed in parallel using Task tool
3. Each parallel task is assigned to a separate agent
4. Results are collected and integrated before proceeding to the next phase

**Agent modes:**

- `"shared"` (default): All agents share the same working directory. Simpler but requires careful coordination to avoid conflicts (e.g., simultaneous `git checkout` operations).
- `"worktree"`: Each agent gets an independent git worktree under the `worktree_base` directory. Provides full isolation but requires more disk space.

**Example:**

```yaml
parallel:
  enabled: true          # Enable parallel implementation (default)
  max_agents: 3          # Up to 3 agents can run concurrently
  mode: "worktree"       # Use independent worktrees for isolation
  worktree_base: ".worktrees"
```

To disable parallel implementation:

```yaml
parallel:
  enabled: false
```

**Error handling:**

- If one task fails, other tasks continue executing
- Failed task results are collected and reported at the end
- The main workflow proceeds with successful results
- Failed tasks can be retried manually or addressed in subsequent commits

### team

Settings for team-based Sprint execution using `/rite:sprint:team-execute`.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `enabled` | boolean | `true` | Enable `/rite:sprint:team-execute` command |
| `max_concurrent_issues` | integer | `3` | Maximum Issues to process in parallel per batch (falls back to `parallel.max_agents` if not set) |
| `teammate_model` | string | `"sonnet"` | Model for teammate agents: `"sonnet"`, `"opus"`, `"haiku"` |
| `auto_review` | boolean | `true` | Automatically run `/rite:pr:review` after all PRs are created |

**Example:**

```yaml
team:
  enabled: true
  max_concurrent_issues: 3
  teammate_model: "sonnet"
  auto_review: true
```

**How team execution works:**

1. `/rite:sprint:team-execute` spawns multiple teammate agents
2. Each teammate picks up an Issue from the Sprint and executes `/rite:issue:start`
3. Teammates work in parallel, each in their own worktree (if `parallel.mode` is `"worktree"`)
4. After all PRs are created, reviews are run automatically if `auto_review` is `true`

### safety

Fail-closed safety thresholds to prevent runaway workflows.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `max_review_fix_loops` | integer | `7` | Hard limit for review-fix loop iterations. Acts as a safety net to prevent runaway loops |
| `max_implementation_rounds` | integer | `20` | Hard limit for implementation rounds per Issue (re-entries from checklist failures) |
| `time_budget_minutes` | integer | `120` | Advisory time budget per Issue in minutes (not enforced by timer) |
| `auto_stop_on_repeated_failure` | boolean | `true` | Stop workflow when the same failure class repeats consecutively |
| `repeated_failure_threshold` | integer | `3` | Number of consecutive same-class failures before triggering auto-stop |

**Example:**

```yaml
safety:
  max_review_fix_loops: 7
  max_implementation_rounds: 20
  time_budget_minutes: 120
  auto_stop_on_repeated_failure: true
  repeated_failure_threshold: 3
```

**When safety limits are hit:**

When a limit is exceeded, the workflow presents options:
1. Continue (raise the limit)
2. Abort (save state to work memory for later resumption)
3. Manual intervention (user handles directly)

### metrics

Settings for workflow execution metrics recording and threshold evaluation.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `enabled` | boolean | `true` | Enable/disable metrics recording |
| `baseline_issues` | integer | `3` | Number of Issues to complete before threshold evaluation begins (measure-only period) |
| `thresholds.plan_deviation_rate` | integer | `30` | Maximum allowed plan vs actual step divergence (%) |
| `thresholds.test_pass_rate` | integer | `100` | Required test pass rate at PR creation (%) |
| `thresholds.review_fix_loops` | integer | `3` | Maximum acceptable review-fix loop count |
| `thresholds.review_critical_high_improvement` | float | `0.80` | MA5 improvement factor for CRITICAL+HIGH findings |
| `thresholds.plan_deviation_improvement` | float | `0.90` | MA5 improvement factor for plan deviation count |

**Example:**

```yaml
metrics:
  enabled: true
  baseline_issues: 3
  thresholds:
    plan_deviation_rate: 30
    test_pass_rate: 100
    review_fix_loops: 3
    review_critical_high_improvement: 0.80
    plan_deviation_improvement: 0.90
```

**How metrics work:**

1. **Baseline period**: During the first `baseline_issues` completed Issues, metrics are recorded but not evaluated against thresholds
2. **Post-baseline**: Metrics are evaluated against per-Issue thresholds and moving average (MA5) thresholds
3. **Failure classification**: When thresholds are exceeded, failures are classified (e.g., scope creep, quality regression) and corrective actions are suggested
4. **Repeated failure detection**: If `safety.auto_stop_on_repeated_failure` is enabled, consecutive same-class failures trigger auto-stop

### notifications

Each notification service (slack, discord, teams) can have:

| Field | Type | Description |
|-------|------|-------------|
| `enabled` | boolean | Enable this notification service |
| `webhook_url` | string | Webhook URL for the service |
| `events` | array | List of events to notify (slack only) |

**Available events:**

| Event | Description |
|-------|-------------|
| `issue_created` | When Issue is created |
| `issue_started` | When work is started |
| `pr_created` | When PR is created |
| `pr_ready` | When PR is marked Ready for review |
| `review_completed` | When review is completed |

### language

| Value | Description |
|-------|-------------|
| `auto` | Auto-detect from user input |
| `ja` | Japanese |
| `en` | English |

## Minimal Configuration

For most projects, a minimal configuration is sufficient:

```yaml
schema_version: 2

project:
  type: webapp
```

All other settings will use sensible defaults or auto-detection.

## Project Type Presets

### webapp

Optimized for web applications:
- Frontend/Backend/Database change tracking
- Screenshot requests in PR template
- E2E test checklist

### library

Optimized for OSS libraries:
- Breaking change tracking
- Migration guide prompts
- CHANGELOG reminders

### cli

Optimized for CLI tools:
- Command change tracking
- Backward compatibility checks
- Help/manual update reminders

### documentation

Optimized for documentation sites:
- Build verification
- Link checking
- Style guide compliance
