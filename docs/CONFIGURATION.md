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
  pattern: "{type}/issue-{number}-{slug}"

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
  max_reviewers: 6      # Cost cap: max reviewers spawned per review (default 6)
  criteria:
    - file_types
    - content_analysis
  loop:
    verification_mode: false    # Enable verification mode as supplement to full review (default: false)
    allow_new_findings_in_unchanged_code: false  # Block new findings in unchanged code (default: false)
    # Review-fix loop termination
    # The loop terminates on (a) 0 blocking findings remaining → [review:mergeable] (normal exit;
    #     non-blocking findings may still remain),
    # (b) manual abort via Ctrl+C → /rite:recover (or fix.md AskUserQuestion "中止" → [fix:cancelled-by-user]), or
    # (c) the circuit breaker → [iterate:max-cycles-stopped] / [iterate:max-cycles-reached]
    #     (fires on convergence-trend divergence, or on safety.max_review_cycles as a backstop;
    #      both modes stop mechanically and record a non-convergent failure; never reaches a merge).
    # The keys below remain as config scaffolding but have no
    # runtime effect on loop termination — see skills/iterate/SKILL.md ループ仕様 and
    # skills/fix/references/fix-relaxation-rules.md "Loop Termination" for the live spec.
    convergence_monitoring: true          # (scaffolding only — see comment above)
    auto_propagation_scan: true           # Run similar-pattern propagation scan after fix (default: true)
    pre_commit_drift_check: true          # Run review-schema-version-check before commit (default: true)
  doc_heavy:
    enabled: true                   # Enable Doc-Heavy PR detection and override (default: true)
    lines_ratio_threshold: 0.6      # doc_lines / total_diff_lines threshold (default: 0.6)
    count_ratio_threshold: 0.7      # doc_files / total_files threshold (default: 0.7)
    max_diff_lines_for_count: 2000  # Max diff lines where count ratio is used (default: 2000)
  security_reviewer:
    mandatory: false                          # Require security reviewer for all PRs (default: false)
    recommended_for_code_changes: true        # Recommend for executable code changes (default: true)
  debate:
    enabled: true            # Enable inter-reviewer debate phase (default: true)
    max_rounds: 1            # Maximum debate rounds for cost control (default: 1)
  confidence_threshold: 80   # Minimum confidence score for findings table (default: 80)
  fact_check:
    enabled: true                      # Enable fact-check phase for review findings (default: true)
    max_claims: 20                     # Maximum number of External claims to verify per review (default: 20). Internal Likelihood claims are Grep-based and counted outside this cap
    use_context7: true                 # Use context7 MCP tool for verification (default: true). Auto-falls back to WebSearch when context7 is unavailable
    verify_internal_likelihood: true   # Enable Sub-Phase B (Internal Likelihood Claim Verification) via Grep (default: true)

# Iteration settings (optional)
iteration:
  enabled: false          # true to enable iteration features (default: false)
  field_name: "Sprint"    # Name of the iteration field in Projects (default: "Sprint")
  auto_assign: true       # Auto-assign to current iteration on /rite:open (default: true)
  show_in_list: true      # Show iteration column in issue-list (default: true)

# Verification gate settings
verification:
  run_tests_before_pr: true          # Run tests before commit/PR (requires commands.test) (default: true)
  acceptance_criteria_check: true    # Check acceptance criteria from Issue body before PR (default: true)

# Parallel implementation settings
parallel:
  enabled: true          # Enable parallel implementation (default: true)
  max_agents: 3          # Maximum concurrent agents (default: 3)
  mode: "shared"         # "shared" (default) or "worktree"
  worktree_base: ".worktrees"  # Base directory for worktrees when mode is "worktree" (default: ".worktrees")

# PR review result recording
# The `review:` section above configures PR review **execution** (reviewer selection, debate,
# fact_check, etc.), while this `pr_review:` section configures PR review **output** (post_comment).
# By default, review results are saved to timestamped local files
# (`.rite/review-results/{pr_number}-{timestamp}.json`) instead of being posted to PR comments.
# `/rite:fix` auto-reads results in the priority order: conversation > local file > PR comment.
# Note: the non-measured findings record comment ("📜 rite 非実測指摘の記録") is attempted
# regardless of this setting — it is the guarantee behind Issue #2024 D-01 ("record non-measured
# findings as a PR comment, never discard them") and is not opt-out-able. The PR comment is
# best-effort: a gh failure or a malformed body aborts the post with a warning and
# `outcome=failed`, so the unconditional channel is the local JSON record, not the comment.
# It is normally a single comment updated in place each cycle; when the helper cannot identify
# its own previous comment (e.g. `gh api user` fails, or the earlier comment was posted under a
# different token identity) it degrades in one of two ways depending on the count: with findings
# it creates a new one, so more than one may accumulate on a PR; with zero it skips the post
# entirely, so the previous cycle's record stays on the PR as stale.
# The record comment carries pointers only (reviewer / severity / file:line, plus one line naming
# where the full text lives); a finding's description / suggestion never appears there, so a
# non-measured CRITICAL is not disclosed in detail on a public PR before it is fixed. Under the
# default the full text lives only in the local JSON on the machine that ran the review — it is
# gitignored, so checking out the PR's branch does not produce it. `/rite:cleanup` archives that
# JSON instead of deleting it when `non_blocking_findings[]` is non-empty (Issue #2039).
pr_review:
  post_comment: false   # true to enable PR comment recording (equivalent to --post-comment, default: false; the non-measured findings record comment is independent of this setting)

# Safety settings (fail-closed thresholds)
safety:
  max_implementation_rounds: 20    # implementation round hard limit per Issue (default: 20)
  max_review_cycles: 15            # circuit breaker backstop per PR (default: 15; primary fire condition is convergence-trend divergence)
  time_budget_minutes: 120         # time budget per Issue in minutes (advisory) (default: 120)
  auto_stop_on_repeated_failure: true   # stop when same failure class repeats (default: true)
  repeated_failure_threshold: 3         # consecutive same-class failure count to trigger stop (default: 3)

# Experience Wiki (opt-out, see wiki section below for full description)
wiki:
  enabled: true                        # Enable Wiki features (default: true, opt-out)
  branch_strategy: "separate_branch"   # "separate_branch" (recommended) or "same_branch"
  branch_name: "wiki"                  # Branch name for Wiki data (when branch_strategy is "separate_branch")
  auto_ingest: true                    # Auto-ingest on review/fix/close (default: true)
  auto_query: true                     # Auto-query on start/review/fix/implement (default: true)
  auto_lint: true                      # Auto-run /rite:wiki-lint --auto after ingest (default: true)

# Metrics settings
metrics:
  enabled: true            # Enable/disable metrics recording (default: true)
  baseline_issues: 3       # Number of Issues for baseline collection (default: 3)

# Test-Driven Development (Canon TDD) settings
tdd:
  enabled: true   # true: implementation phase runs the Canon TDD cycle (default: true, opt-out)

# Language setting
language: auto  # auto | ja | en
```

## Configuration Sections

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
| `pattern` | string | `{type}/issue-{number}-{slug}` | Branch name pattern |

**Git Flow Support:**

For Git Flow workflows, configure:

```yaml
branch:
  base: "develop"    # Feature branches are created from develop
```

This affects the following commands:
- `/rite:open`: Creates the feature branch from `branch.base`
- `/rite:pr-create`: Sets `branch.base` as the PR target
- `/rite:cleanup`: Switches back to `branch.base` after cleanup
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

When `/rite:open` detects an existing branch matching these patterns (Step 2.2 existing branch check), it will offer to use the branch even though it doesn't contain an Issue number.

**Pattern variables for `branch.pattern`:**

These variables are used in `branch.pattern` to generate new branch names:

| Variable | Description | Example |
|----------|-------------|---------|
| `{type}` | Work type prefix | `feat`, `fix`, `docs` |
| `{number}` | Issue number | `123` |
| `{slug}` | Slugified Issue title | `add-auth-feature` |
| `{date}` | Current date (YYYYMMDD) | `20250103` |
| `{user}` | GitHub username | `octocat` |

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
| `none` | Always show decomposition prompt |

**Three-tier judgment logic:**

| Condition | Behavior |
|-----------|----------|
| Complexity < threshold | Skip decomposition (proceed directly to work) |
| Complexity == threshold | Analyze Issue body to estimate scope, then decide |
| Complexity > threshold | Show decomposition proposal |

When an Issue's complexity is below the threshold, `/rite:issue-create` skips the decomposition proposal and the Issue is created as-is; `/rite:open` then begins work without an intermediate confirmation. When the complexity equals the threshold, the Issue body is analyzed to estimate the scope of changes (number of files mentioned). This reduces unnecessary prompts for simple Issues while still prompting for complex ones.

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
| `max_reviewers` | integer | `6` | Maximum reviewers spawned per review (cost cap). Applied after `min_reviewers` and the security/sole-reviewer guards, so it never drops a mandatory reviewer or reduces below `min_reviewers`. When the matched set exceeds the cap, reviewers are narrowed by relevance (matched file count) and the omitted reviewers are displayed (never silently capped). Invalid values (non-numeric, or `< min_reviewers`) fall back with a WARNING (default `6` — raised to `min_reviewers` when `min_reviewers > 6` — or `min_reviewers` respectively) |
| `criteria` | array | `[file_types, content_analysis]` | Review criteria |
| `loop.verification_mode` | boolean | `false` | Enable PR-comment-driven verification mode as supplement to full review (both full review and verification of previous fixes with incremental diff regression checks). Evaluated **only when the cycle scope resolved to full** — from cycle 2+ the diff-scope mandate already covers it and this mode is skipped (see the Cycle scope note below) |
| `loop.allow_new_findings_in_unchanged_code` | boolean | `false` | Whether new findings in unchanged code should be blocking. When `false`, new MEDIUM/LOW findings in unchanged code are reported as "stability concerns" (non-blocking). Only consulted in verification mode (see `loop.verification_mode`) — it has no effect when the cycle scope resolved to `incremental`, and none at all under the default `verification_mode: false` |
| `loop.convergence_monitoring` | boolean | `true` | **Scaffolding only** — setting this key has no runtime effect. Convergence *is* monitored at runtime, but by the circuit breaker's trend check (`hooks/scripts/review-trend-divergence.sh`), which this key does not configure. The review-fix loop exits on 0 blocking findings (normal), the circuit breaker (trend divergence, or `safety.max_review_cycles` as a backstop), or manual abort (Ctrl+C → `/rite:recover`) — see `skills/iterate/SKILL.md` for the live spec |
| `loop.auto_propagation_scan` | boolean | `true` | After a fix is applied, automatically scan for similar patterns elsewhere in the codebase to catch propagation gaps |
| `loop.pre_commit_drift_check` | boolean | `true` | Run `review-schema-version-check` before committing fix changes to catch review-result schema_version drift |
| `doc_heavy.enabled` | boolean | `true` | Enable Doc-Heavy PR detection. When a PR's diff is dominated by documentation changes, the `tech-writer` reviewer is boosted and verifies five doc-implementation consistency categories via Grep/Read/Glob |
| `doc_heavy.lines_ratio_threshold` | float | `0.6` | Threshold for `doc_lines / total_diff_lines` that marks a PR as doc-heavy |
| `doc_heavy.count_ratio_threshold` | float | `0.7` | Threshold for `doc_files / total_files` (used as fallback for small diffs) |
| `doc_heavy.max_diff_lines_for_count` | integer | `2000` | Maximum diff line count below which `count_ratio_threshold` is consulted |
| `security_reviewer.mandatory` | boolean | `false` | Require security reviewer for all PRs regardless of file types |
| `security_reviewer.recommended_for_code_changes` | boolean | `true` | Include security reviewer when executable code files are changed |
| `debate.enabled` | boolean | `true` | Enable inter-reviewer debate phase |
| `debate.max_rounds` | integer | `1` | Maximum debate rounds (cost control) |
| `confidence_threshold` | integer | `80` | Minimum confidence score for findings to be included in findings table |
| `fact_check.enabled` | boolean | `true` | Enable fact-check phase for review findings |
| `fact_check.max_claims` | integer | `20` | Maximum number of **External** claims to verify per review (Sub-Phase A). Internal Likelihood claims are Grep-based and counted outside this cap |
| `fact_check.use_context7` | boolean | `true` | Use context7 MCP tool for verification. Auto-falls back to WebSearch when context7 is unavailable |
| `fact_check.verify_internal_likelihood` | boolean | `true` | Enable Sub-Phase B (Internal Likelihood Claim Verification) via Grep-based call site / entry point checks |

**Review-fix loop exit:**

The review-fix loop exits via the following paths:

| Exit | Trigger |
|------|---------|
| Normal | 0 **blocking** findings remaining → `[review:mergeable]` (non-blocking findings may still remain — see [`safety` § the review⇄fix circuit breaker](#safety)) |
| Manual abort | User aborts via `Ctrl+C` → `/rite:recover` (or selects "中止" in `fix.md` AskUserQuestion → `[fix:cancelled-by-user]`) |
| Circuit breaker | Convergence-trend divergence detected, **or** cycle count reaches `safety.max_review_cycles` (backstop) → `[iterate:max-cycles-stopped]` (interactive) / `[iterate:max-cycles-reached]` (batch). The sentinels are the same for both fire reasons; only the stop notice's reason line and its per-cycle blocking trend differ. Both modes stop mechanically without prompting and record a non-convergent **failure** that never reaches a merge — see [`safety` § the review⇄fix circuit breaker](#safety) |

**Doc-Heavy PR Mode** (`doc_heavy.enabled: true` by default): A PR is classified as doc-heavy when `doc_lines / total_diff_lines >= lines_ratio_threshold`, or — for small diffs (`total_diff_lines < max_diff_lines_for_count`) — when `doc_files / total_files >= count_ratio_threshold`. In doc-heavy mode, `tech-writer-reviewer` verifies the five consistency categories (Implementation Coverage / Enumeration Completeness / UX Flow Accuracy / Order-Emphasis Consistency / Screenshot Presence) against the actual implementation using Grep/Read/Glob. See `plugins/rite/skills/pr-review/references/internal-consistency.md` for the full protocol.

**Cycle scope** (no config key): cycle 1 reviews the whole PR, matching the reviewer set against every changed file (then bounded by `min_reviewers` / `max_reviewers` as usual); from cycle 2+ the review is diff-scoped to `commit_sha..HEAD` of the previous cycle's persisted review-result JSON, plus verification that the previous cycle's gated-scope (`current-pr` / `follow-up`) findings were resolved, with the reviewer set narrowed to those findings' reviewers (rejoined as `mandatory`) union the owners of the fix diff's file patterns. Acknowledged `nit-noted` findings are excluded from both — they stay in `findings[]` after the measured gate, so counting them would occupy cap-exempt slots and replay settled nits every cycle. Any missing input falls back to full scope; every reason except `no_prev_json` (the normal cycle-1 path) emits a warning. This is not configurable and not a progressive relaxation — cycle 3 and cycle 5 behave identically, and no finding criterion loosens. See `plugins/rite/skills/pr-review/references/cycle-scope.md`.

**Complexity lane** (no config key): the Issue's declared Complexity scales the review's ceremony cost. `XS` / `S` take a light lane — the reviewer bound tightens to 3 (subject to the usual `mandatory` protection and the `min_reviewers` / sole-reviewer-guard floor, so it is not a hard "at most 3"), and verification runs are limited to the tests the PR touched, with full-suite sandbox replication and mutation experiments reserved for `M` and above. `M` / `L` / `XL` behave exactly as before. The criteria for admitting a finding — the four mandatory self-questions, Confidence, Observed Likelihood, the measured-finding gate, the consequence class — and the Cross-File Impact Check are identical on both lanes; only the cost of verification differs. Complexity is read from the Issue body (`**Complexity**: X` or a `## 複雑度` section) and never inferred; any missing or invalid value falls back to the full lane with a warning. This is not configurable, and it is not a progressive relaxation — the lane is decided once from a declared value, not from the cycle count. See `plugins/rite/skills/pr-review/references/complexity-lane.md`.

**Verification mode** (`verification_mode: false` by default): When explicitly set to `true`, reviews detect the previous review from **PR comments** and perform both a full review and verification of previous fixes with incremental diff regression checks; new MEDIUM/LOW findings in unchanged code are classified as "stability concerns" (non-blocking). This mode is evaluated **only when the cycle scope resolved to full** (cycle 1, or a diff-scope fallback) — under diff scope its two parts are already covered by the scope mandate, so it is skipped.

**Review execution:**

`/rite:pr-review` uses Claude Code's Task tool to spawn parallel subagents for each reviewer role. This improves context efficiency and enables parallel execution.

**Available reviewers:**

The following specialized reviewers are automatically selected based on the changed files:

| Reviewer | Focus Area |
|----------|------------|
| `security-reviewer` | Security vulnerabilities, authentication, data handling |
| `application-reviewer` | Application code end-to-end: API/type contracts, performance (N+1, indexes), data operations/migrations, UI safety (XSS, accessibility) |
| `code-quality-reviewer` | Duplication, naming, error handling, structure |
| `devops-reviewer` | Infrastructure, CI/CD pipelines, deployment configurations |
| `test-reviewer` | Test quality, coverage, testing strategies |
| `dependencies-reviewer` | Package dependencies, versions, supply chain security |
| `prompt-engineer-reviewer` | Claude Code skill, command, and agent definitions |
| `tech-writer-reviewer` | Documentation clarity, accuracy, completeness |
| `error-handling-reviewer` | Silent failures, error propagation, catch block quality |

> **v0.x consolidation**: the former `api` / `frontend` / `performance` / `database` / `type-design` reviewers were consolidated into `application-reviewer`. Legacy type names appearing as input are substituted with `application` after a WARNING (see CHANGELOG for the migration table).

**Reviewer selection:**

Reviewers are automatically selected based on:
1. File patterns (e.g., `*.test.*` triggers `test-reviewer`)
2. Content analysis (e.g., SQL queries trigger `application-reviewer`)
3. Change complexity and scope

**Fallback behavior:**

If a subagent fails or times out:
1. The review continues with remaining subagents
2. Failed subagent's results are marked as "incomplete"
3. User is notified of the failure in the review summary

### iteration

Settings for GitHub Projects Iteration field integration.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `enabled` | boolean | `false` | Enable iteration features |
| `field_name` | string | `"Sprint"` | Name of the iteration field in GitHub Projects |
| `auto_assign` | boolean | `true` | Auto-assign Issues to current iteration on `/rite:open` |
| `show_in_list` | boolean | `true` | Show iteration column in `/rite:issue-list` output |

**Example:**

```yaml
iteration:
  enabled: true
  field_name: "Sprint"
  auto_assign: true
  show_in_list: true
```

When enabled, `/rite:open` will automatically assign the Issue to the current active iteration when starting work. Use `/rite:issue-list --sprint current` to list Issues in the current iteration, or `--backlog` for unassigned Issues.

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
2. Issue complexity resolves to the full lane **with a declared value** — `M` or higher. A lane fail-safe (Complexity absent / unreadable) does **not** satisfy this condition: on this gate the full lane would mean "allow parallel sub-agents", so a missing declaration falls back to sequential implementation
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

### multi_session

Settings for per-session Git worktree isolation, letting multiple Claude Code sessions work different Issues in the same repository concurrently. See [docs/designs/multi-session-worktree.md](./designs/multi-session-worktree.md) for the full design.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `enabled` | boolean | `true` | Enable per-session worktrees (on by default). Set to `false` to restore single-session behavior (identical to the previous default, zero change). New projects get `enabled: true` from the `/rite:setup` template; existing configs that predate the feature and omit the `multi_session` block fall back to `false` for backward compatibility |
| `worktree_base` | string | `".rite/worktrees"` | Base directory for session worktrees (each Issue gets an `issue-{N}` subdirectory) |

**Separate axis from `parallel`:** `parallel.*` governs per-Issue sub-agent fan-out *within a single session*; `multi_session.*` governs lifecycle isolation *across whole sessions*. The two are orthogonal and intentionally not merged — `parallel.mode: "worktree"` uses `.worktrees/{issue}/{task}`, while `multi_session` uses `.rite/worktrees/issue-{N}`.

**How it works (`enabled: true`):**

1. `/rite:open N` creates a session worktree at `.rite/worktrees/issue-{N}` and enters it via Claude Code's `EnterWorktree(path)` tool, so each session keeps its own working tree and current branch.
2. rite state / locks / wiki worktree still resolve to the shared main checkout root (`state-path-resolve.sh` is worktree-aware), so cross-session exclusion stays intact.
3. `/rite:cleanup` exits the worktree (`ExitWorktree`), removes it, and releases the Issue claim — when the worktree was `EnterWorktree`-managed. If the session entered the worktree **by path** instead, `ExitWorktree` is a no-op, so cleanup skips the four main-checkout items (base update, worktree removal, branch deletion, wiki ingest) and delegates them to a re-run of `/rite:cleanup {pr}` from the main checkout (Issue #2133). The re-run itself does not delegate — it runs Steps 4 / 5 / 9 normally, finishing base update, wiki ingest, and remote branch deletion directly, and recording a `branch` entry (only when the PR is merged) that arms the lazy reap to reclaim the worktree and its local branch at the next session start. Abnormally-orphaned worktrees are reaped lazily by `pr-cycle-cleanup.sh`.

**Example:**

```yaml
multi_session:
  enabled: true                    # on by default; set false to opt out
  worktree_base: ".rite/worktrees"
```

**`.gitignore` requirement:** `.rite/worktrees/` must be effectively ignored so session worktrees do not leak into dev-branch diffs — a broad `.rite/` rule suffices. `/rite:setup` adds an entry automatically only when the path is not already covered, and `/rite:lint` (via `gitignore-health-check.sh`) probes with `git check-ignore` and emits a non-blocking warning if the path is not ignored while `multi_session.enabled: true`.

**Disk cost:** each session worktree is a full working-tree clone. Build artifacts (`node_modules`, etc.) may need rebuilding per worktree.

### safety

Fail-closed safety thresholds to prevent runaway workflows.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `max_implementation_rounds` | integer | `20` | Hard limit for implementation rounds per Issue (re-entries from checklist failures) |
| `max_review_cycles` | integer | `15` | Backstop limit for `/rite:iterate` review⇄fix loop cycles per PR — the **second** of the circuit breaker's two fire conditions. The primary condition is convergence-trend divergence detection, which fires without regard to this limit **when `max_review_cycles` is 4 or more** (the default of 15 satisfies that lower bound with room to spare); at 3 or below the trend check can never be the reported fire reason, because it needs three completed reviews in the run and the backstop already holds at that point, so the breaker degenerates into the pure cycle-count limit this design replaced; `max_review_cycles` catches the runs that slip past it — including, at the default of 15, converging runs that need 16 or more cycles. Invalid values (≤ 0 or non-numeric) fall back to the default with a WARNING |
| `time_budget_minutes` | integer | `120` | Advisory time budget per Issue in minutes (not enforced by timer) |
| `auto_stop_on_repeated_failure` | boolean | `true` | Stop workflow when the same failure class repeats consecutively |
| `repeated_failure_threshold` | integer | `3` | Number of consecutive same-class failures before triggering auto-stop |

> **The default for `max_review_cycles` is duplicated across the repository, and that duplication is itself a drift source.** It is written out in this table, in the YAML example below, in the annotated example near the top of this file, in `plugins/rite/templates/config/rite-config.yml`, in `plugins/rite/references/execution-metrics.md`, in `docs/SPEC.md`, and at three fallback sites in `plugins/rite/skills/iterate/SKILL.md` (two in step 0.6, one in step 1 — the latter is the one that actually decides whether the breaker fires). `plugins/rite/hooks/tests/max-review-cycles-default.test.sh` pins those. Two further sites are **partly** pinned. T-04n counts four file-wide occurrences of the phrase that spells the default out in prose rather than as a bare number — two of them in the table row above, two in the circuit breaker section further down (the assertion itself carries the exact wording, so do not repeat it here or the count will move) — and T-04i/j pin two loop-head figures derived from it; the remaining restatements in that section (`raised from 5 to 15`, `15 is a provisional value`, `the heads of cycles 4 through 15`, `at the head of cycle 6`, `needs 16 or more cycles`) have no assertion and can drift silently. The same holds for `既定値を 15 へ引き上げた` in `plugins/rite/skills/iterate/SKILL.md` — the negative check does not reach across the particle and T-04o counts a different literal, so that one phrase is unpinned too. Issue #2134 added `plugins/rite/skills/fix/references/fix-relaxation-rules.md` and the header of `plugins/rite/hooks/scripts/review-trend-divergence.sh` to the T-04 sweep and pins their default and derived “16 cycle” prose. `review-trend-divergence.test.sh` is current but remains outside T-04, although its comments and assertion labels restate default 15 twice; those copies can still drift silently. (The `### Added` entries in `CHANGELOG.md` / `CHANGELOG.ja.md` still name 5; those record the value as shipped in #1728 and are intentionally frozen.)

**Example:**

```yaml
safety:
  max_implementation_rounds: 20
  max_review_cycles: 15
  time_budget_minutes: 120
  auto_stop_on_repeated_failure: true
  repeated_failure_threshold: 3
```

**When safety limits are hit:**

When a limit is exceeded, the workflow presents options (**except the review⇄fix circuit breaker — both of its fire conditions stop mechanically without prompting, and one of them is not a limit at all; see below**):
1. Continue (raise the limit)
2. Abort (save state to work memory for later resumption)
3. Manual intervention (user handles directly)

**The review⇄fix circuit breaker (two fire conditions):**

The `/rite:iterate` review⇄fix loop normally exits only on `[review:mergeable]` (0 blocking findings). Non-blocking findings may still remain at that point, by two routes: a `current-pr` / `follow-up` finding the Measured CONFIRMED Gate demoted is moved out to `non_blocking_findings[]`, while a `nit-noted` finding is outside the gate entirely and stays in `findings[]`. Both are recorded, neither drives the fix cycle — see `plugins/rite/references/severity-levels.md` §実測必須ゲート for what counts as blocking. A circuit breaker keeps a non-convergent PR from looping forever. It fires on **either** of two conditions, evaluated at each loop head:

1. **Convergence-trend divergence (primary).** `plugins/rite/hooks/scripts/review-trend-divergence.sh` reconstructs the current run's per-cycle blocking counts from the persisted review-result JSON and reports divergence when the two most recent counts both exceed the run's earlier best *and* are not still descending. The two conditions are independent, so a diverging loop is cut early instead of burning the whole budget — but the rule needs at least three results in the run before "the run's earlier best" is defined, and a loop head carries the count of *completed* reviews, so cycles 1, 2, and 3 always fall through to the backstop; the check is first armed at the head of cycle 4. With the default budget of 15 that leaves twelve loop heads — the heads of cycles 4 through 15 — at which the trend can fire, before the backstop takes over at the head of cycle 16.
2. **`max_review_cycles` reached (backstop).** Catches the runs the trend check deliberately passes over — a count that keeps shrinking but never reaches 0 (an intentional escape so that a run still descending is never cut), or one that plateaus at the run's best (an intentional boundary, because firing there would kill a loop that is a couple of findings from done). The backstop is an independent condition that never consults the trend verdict, so at the default of 15 it is what stops a *converging* run that needs 16 or more cycles. The default was raised from 5 to 15 (Issue #2129) after a run on PR #2126 whose trend check never once reported divergence at a head where a verdict came back — the earliest heads fall through undecided until three results are in — with per-cycle blocking counts of 8, 5, 4, 6, 3, and which was then cut off by the backstop at the head of cycle 6 (`cycle_count == 5`) and recorded as a non-convergent failure, so `/rite:batch-run --merge` never merged it. 15 is a provisional value, not a derived optimum: the run that motivated the change had not converged after 5 cycles, so the new default leaves headroom well past that point without any claim about where the true ceiling lies. Whether the default of 15 is right is a question for operational data; the only thing measured so far is that 5 was too small.

Splitting the conditions this way is deliberate: a cycle-count limit alone cannot tell effort from waste. It killed healthy converging loops that were down to a couple of findings when the budget ran out, and let diverging ones burn to the limit anyway; both were observed in practice. The project principle is to cut waste, not to cap quality with a budget. The judgment lives entirely in the helper — no conversational counting is involved — and its window and thresholds are calibrated constants rather than config keys. The calibration evidence is a backtest over seven trajectories — three written literally into the acceptance criteria as contract values, three recovered from real runs, and one synthetic slow-descent series that keeps the escape clause honest. The rule itself is documented in the helper's header, which is its single source of truth; the per-trajectory provenance lives in the helper's test file alongside the fixtures.

Tripping the breaker records a **failure** — a non-convergent loop — and never reaches a merge, **whichever condition fired**. The fire reason changes only the wording of the stop notice's reason line and the per-cycle blocking trend printed alongside it; the sentinels, the handoff contract, and the counter reset are all identical. Both modes stop mechanically without asking the user to decide:

- **Interactive `/rite:iterate`**: the loop stops with a notice (`[iterate:max-cycles-stopped]`), leaving the draft/open PR for review. No prompt is shown; provided **either** of the two fire-time state writes — `/rite:iterate` step 1's handoff clear or step 6's counter reset — succeeds, the loop is never auto-continued past the limit. Both writes clear the pending continuation handoff because a `flow-state.sh set` that omits `--handoff` deletes that key, and the handoff is what the Stop hook would otherwise consume to re-inject `/rite:pr-review`.
- **`/rite:batch-run` batch**: the Issue is recorded as failed (`[iterate:max-cycles-reached]`) and the batch advances to the next Issue, leaving the draft/open PR for review. This prevents one non-convergent PR from stalling the whole batch.

The only way to resume the loop is to re-run `/rite:iterate {pr}` explicitly (`/rite:recover` routes to the same command, so it takes this path too). The breaker clears the cycle counter as it records the trip, so that re-run starts from cycle 1 rather than tripping again immediately. The trend check does **not** use that counter to find the run boundary. The review-result JSON files accumulate across every run of a PR until `/rite:cleanup` removes them, so a boundary is needed — but deriving it from the counter assumes the run wrote exactly one result file per counted cycle, and that assumption breaks whenever a result fails to save or a review is interrupted after the counter advanced. `/rite:iterate` therefore pins the run start instead: when the counter is 0 it records the newest existing result file in `.rite/state/review-run-since-{pr}.txt`, and the helper treats only files newer than that pin as the current run. A missing pin falls back to reading every file as one series (runs that predate the pin) — but only while that series matches the counter: with no pin and **more** files than the counter, other runs are bleeding in, so the check is dropped as `run_boundary_unresolved` rather than risking a false fire. Once a pin is set **and the counter has advanced past 0**, the boundary is known, so neither direction suppresses the check: a **shortfall** is reported as a WARNING naming how many results were lost (and as `lost=N` on the helper's marker), an **excess** means the counter lagged behind the saved results, and either way the judgment proceeds on the files that do exist. An excess while the counter is still 0 is different: the current run has not completed a single review, so any results present belong to an earlier run whose pin was never refreshed, and the check is dropped as `run_boundary_unresolved`. If the counter reset fails, the interactive stop notice says so and points at a manual reset; in a batch run only a stderr WARNING is emitted (the batch notice is not yet symmetric). A failed reset leaves the counter and the run-start pin both unrefreshed, so the re-run trips again straight away — after a backstop trip because the counter is still at the limit, and after a divergence trip because a non-zero counter skips the re-pin and the helper reads the same series over again. Separately, if the pending continuation handoff survives, the Stop hook re-injects `/rite:pr-review`, and that chain re-arms itself at every step — `/rite:pr-review` sets a `/rite:fix` handoff, `/rite:fix` sets a `/rite:pr-review` handoff — without ever re-entering the cycle-count check in `/rite:iterate` step 1. The loop then runs outside the counter's control until the model returns to `/rite:iterate`. That is the one case in which the interactive bullet's "never auto-continued past the limit" guarantee does not hold. For the exact condition under which the handoff survives, see [`stop-loop-continuation-contract.md`](../plugins/rite/references/stop-loop-continuation-contract.md) — it is the single source of truth and is not restated here.

The cycle counter is persisted in the per-session flow-state (`cycle_count`) and continues across `/rite:recover` — an interrupted loop resumes its count rather than restarting from 0. A reset happens on a fresh entry (step 0.6), when the loop exits normally (step 5.0.1, so the next run re-pins its start), and as the trip is recorded (in the step 6 preamble that runs immediately before the trip sentinel). The trip's reset is taken at trip time rather than deferred to the next start-up. In the same atomic state update, the preamble records `stop_reason` (`circuit-breaker:max-cycles` or `circuit-breaker:divergence`), so a turn that ends between the preamble and sentinel still leaves a durable failure reason for `session-start` and `/rite:recover`. A turn that ends **before the preamble runs** leaves the counter at the limit, so the next run trips again instead of silently regaining a full budget. If the atomic update itself fails, neither the reset nor the reason is persisted and the emitted warning reports both consequences. Being at the limit (`cycle_count == max_review_cycles`) is the normal state throughout the final cycle; an interrupt there does not go through the fire branch, so its count is resumed and the breaker trips as intended.

### metrics

Settings for workflow execution metrics recording and threshold evaluation.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `enabled` | boolean | `true` | Enable/disable metrics recording |
| `baseline_issues` | integer | `3` | Number of Issues to complete before threshold evaluation begins (measure-only period) |

> **Note**: Metric thresholds (`plan_deviation_rate`, `test_pass_rate`, `review_fix_loops`, etc.) are currently hardcoded in the implementation. Configurable thresholds via `rite-config.yml` are planned for a future release.

**Example:**

```yaml
metrics:
  enabled: true
  baseline_issues: 3
```

**How metrics work:**

1. **Baseline period**: During the first `baseline_issues` completed Issues, metrics are recorded but not evaluated against thresholds
2. **Post-baseline**: Metrics are evaluated against per-Issue thresholds and moving average (MA5) thresholds
3. **Failure classification**: When thresholds are exceeded, failures are classified (e.g., scope creep, quality regression) and corrective actions are suggested
4. **Repeated failure detection**: If `safety.auto_stop_on_repeated_failure` is enabled, consecutive same-class failures trigger auto-stop

### pr_review

Settings for PR review **output** recording. This section is intentionally separated from the `review:` section (which configures review **execution**) so that future output destinations can be added without a breaking change to `review:` child keys.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `post_comment` | boolean | `false` | When `true`, the full review report is posted as a PR comment (equivalent to `--post-comment`). When `false` (default), the report is saved to `.rite/review-results/{pr_number}-{timestamp}.json` only. **Exception**: the non-measured findings record comment (`📜 rite 非実測指摘の記録`, normally one comment updated in place — the lookup degrades to creating a second one when it cannot identify its own prior comment) is **attempted** independently of this setting whenever the review produces one or more non-measured findings — and is additionally refreshed in place on a converged cycle producing zero, when a record comment from a previous cycle already exists **and the helper can identify it**. Identification runs in two stages: a durable comment id persisted on its own line in the PR body first, then a body match (author + first-line marker + machine sentinel on the last non-blank line) as the fallback. The id stage accepts the referenced comment only when it exists, is authored by the caller, belongs to this PR, **and is itself a record comment** (first-line marker + machine sentinel) — a repo-scoped id alone could otherwise point at the caller's own comment on a different PR, and a PR-scoped one at an unrelated comment such as the review report, whose body would then be overwritten in place. When **both** stages fail to resolve the prior comment, the helper falls back to creating a new record comment if the cycle has one or more non-measured findings, and skips posting entirely — leaving the previous cycle's record stale — if the cycle has zero. That double failure happens in exactly three mutually exclusive ways: (a) `gh api user` fails, which disables both stages at once since each needs the caller's own login; (b) the id stage fails on its own terms (the marker is absent, malformed, unreachable, deleted, or points at another PR or a non-record comment) **while** the body match separately finds nothing; (c) the prior comment was posted under a different token identity, which by itself defeats the author check in both stages — this is the case that emits `id_author_mismatch`. Two situations emit no `NONBLOCKING_ID_UNRESOLVED` reason at all: case (a), because the id stage never runs, and the first cycle of a PR before any id has been persisted, because falling back is the normal path there rather than a failure. A body-match lookup that fails on its own no longer degrades the cycle when the persisted id resolves the comment. The PR comment is **best-effort**: a gh failure (`create_failed` / `patch_failed`), a jq runtime failure (`body_check_unavailable`), or a malformed body (`body_file_empty` / `body_marker_missing` / `body_sentinel_missing` / `count_body_mismatch`) aborts the post with a warning and `outcome=failed`, so the **unconditional** record channel is the local JSON, not the comment (Measured CONFIRMED Gate, Issue #2024 D-01). The record comment carries **pointers only** — reviewer, severity, and `file:line` for every non-measured finding, and a line naming where the full text lives. It never contains a finding's `description` or `suggestion`, so that a non-measured CRITICAL is not disclosed in detail on a public PR before it is fixed. Under the default `post_comment: false` the local JSON is the sole store of that full text — it lives only on the machine that ran the review, is gitignored (so checking out the PR's branch does not produce it), and has no sharing channel; with `post_comment: true` the full review report comment carries the full text as well. `/rite:cleanup` moves a result JSON whose `non_blocking_findings[]` is non-empty into `.rite/review-results/archive/` instead of deleting it, so the detail survives the merge (Issue #2039) |

`/rite:fix` automatically reads review results in the priority order: **conversation > local file > PR comment**. Most users should leave `post_comment: false` to keep the full review report off the PR; note that the non-measured findings record comment is still recorded regardless — best-effort on the PR (normally one, updated in place, pointers only), unconditionally in the local JSON (full text). Enable `post_comment: true` only if you want an auditable full review trail on the PR itself.

### wiki

Settings for the Experience Wiki — an LLM-driven project knowledge base that persists experiential heuristics extracted from review/fix/Issue outcomes. Based on the LLM Wiki pattern (Karpathy). See `docs/designs/experience-heuristics-persistence-layer.md` for the full design.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `enabled` | boolean | `true` | Enable Wiki features (opt-out). Set `false` to skip all Wiki hooks and commands |
| `branch_strategy` | string | `"separate_branch"` | Where Wiki data lives: `"separate_branch"` (dedicated orphan-like branch, recommended) or `"same_branch"` (Wiki files committed alongside code on the working branch) |
| `branch_name` | string | `"wiki"` | Name of the Wiki branch (used only when `branch_strategy` is `"separate_branch"`) |
| `auto_ingest` | boolean | `true` | Automatically run `/rite:wiki-ingest` on review/fix/close events to extract heuristics from raw sources |
| `auto_query` | boolean | `true` | Automatically run `/rite:wiki-query` at the start of Issue work and at review/fix/implement phases to inject relevant heuristics into the conversation context |
| `auto_lint` | boolean | `true` | Automatically run `/rite:wiki-lint --auto` after each ingest to detect contradictions, staleness, orphans, missing concepts (`missing_concept`), unregistered raw sources (`unregistered_raw`, informational — not added to `n_warnings`), and broken cross-refs |
| `growth_check.threshold_prs` | integer | `5` | Lint growth check layer 3 — `/rite:lint` Phase 3.8 emits a non-blocking warning when this many merged PRs accumulate on the development base branch since the last commit on `branch_name` (signalling that Phase X.X.W may be silently skipped). Increase to relax the check; setting it to a very large number effectively disables the lint warning while preserving layers 1-2 |
| `growth_check.pr_raw_threshold` | integer | `3` | Warn when this many of the last `threshold_prs` merged PRs have no corresponding raw source on the wiki branch. Detects regressions where PRs are merged but Phase X.X.W never fires. Override at runtime with `--pr-raw-threshold N` |

**Example (opt out completely):**

```yaml
wiki:
  enabled: false
```

**Example (same-branch Wiki without auto-lint):**

```yaml
wiki:
  enabled: true
  branch_strategy: "same_branch"
  auto_ingest: true
  auto_query: true
  auto_lint: false
```

> **Note for `same_branch` users**: The project's `.gitignore` ships with `.rite/wiki/` excluded as a silent-leak defense line for the default `separate_branch` strategy. If you switch to `same_branch`, you MUST add negation entries so that Wiki files are not ignored. See the `.gitignore` comment block between the `# >>> gitignore-wiki-section-start` and `# <<< gitignore-wiki-section-end` anchor markers (`grep -n 'gitignore-wiki-section-start' .gitignore` to jump there) for the full verification-first setup: required negation entries (`!.rite/wiki/` and `!.rite/wiki/**`), the mandatory `mkdir -p .rite/wiki/raw && touch .rite/wiki/raw/.negation-probe && git add --dry-run .rite/wiki/raw/.negation-probe` sanity check, the idempotency note for already-tracked files, and the rationale for using `git add --dry-run` instead of `git check-ignore -v` as the canonical verification step.

**Example (loose growth-check threshold for slow-moving repos):**

```yaml
wiki:
  enabled: true
  growth_check:
    threshold_prs: 20   # warn only after 20 PRs have accumulated since the last wiki commit
    pr_raw_threshold: 5  # warn if 5+ of last 20 PRs have no raw source
```

**Related commands:** `/rite:wiki-init` (one-time setup), `/rite:wiki-ingest`, `/rite:wiki-query`, `/rite:wiki-lint`.

### tdd

Settings for Test-Driven Development (Canon TDD). This key controls whether the implementation phase (`/rite:issue-implement`) follows a Canon TDD cycle — write a test, confirm it fails (Red), make it pass with the minimal change (Green), then Refactor, one behavior at a time. This section documents the `tdd` configuration key itself.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `enabled` | boolean | `true` | Enable the Canon TDD cycle in the implementation phase (opt-out). Set `false` for doc-centric / non-software projects to restore the previous non-TDD implementation flow (behavior identical to before the feature). A config that omits the `tdd:` key is treated as `enabled: true` (opt-out convention), so configs predating the feature get the default-on behavior |

**Graceful degrade:** when `commands.test` is `null` (no test runner configured) the Red/Green auto-run is skipped with a warning, while the one-behavior-at-a-time discipline still applies. When `enabled: false`, the Canon TDD cycle is skipped entirely and the implementation phase behaves exactly as it did before this feature.

**Example (opt out — doc-centric project):**

```yaml
tdd:
  enabled: false
```

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
```

All settings use sensible defaults or auto-detection. Override specific keys (`branch.pattern`, `commands.*`, `iteration.*` etc.) as needed.
