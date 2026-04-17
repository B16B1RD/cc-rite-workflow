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

# Commit message
commit:
  contextual: true    # Contextual Commits action lines in commit body

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
    verification_mode: false    # Enable verification mode as supplement to full review (default: false)
    allow_new_findings_in_unchanged_code: false  # Block new findings in unchanged code (default: false)
    # Review-fix quality signals (#557)
    # Cycle-count-based degradation was fully removed in v1.0.0. Normal exit is 0 findings only;
    # abnormal exit is one of 4 quality signals (fingerprint cycling / root-cause missing /
    # cross-validation disagreement / reviewer self-degraded).
    convergence_monitoring: true          # Enable fingerprint-based cycling detection (default: true)
    auto_propagation_scan: true           # Run similar-pattern propagation scan after fix (default: true)
    pre_commit_drift_check: true          # Run distributed-fix-drift-check before commit (default: true)
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
  # Observed Likelihood Gate (#506): Require evidence of actual occurrence for findings.
  # See `plugins/rite/references/severity-levels.md` for the Observed / Demonstrable / Hypothetical axis.
  observed_likelihood_gate:
    enabled: true                      # Enable Observed Likelihood Gate (default: true)
    security_exception: true           # Security reviewer keeps severity even for Hypothetical findings (default: true)
    hypothetical_exception_reviewers:  # Reviewer categories allowed to report Hypothetical findings
      - security
      - database
      - devops
      - dependencies
    minimum: "demonstrable"            # Minimum likelihood for non-exception reviewers (default: "demonstrable")
  # Fail-Fast First (#506): Require throw/raise propagation to be considered before recommending fallback.
  fail_fast_first:
    enabled: true                      # Enable Fail-Fast First principle for reviewer recommendations (default: true)
    allow_skill_exceptions: true       # Respect skill-level fallback allowances (default: true)
    wiki_query_required: true          # Require Wiki check for project-specific fallback patterns before recommendation (default: true)
  # Separate Issue Creation (#506): Always require user confirmation for separate-issue creation.
  separate_issue_creation:
    require_user_confirmation: true    # Require AskUserQuestion even in E2E flow (default: true). Strongly recommended.
    report_pre_existing_issues: false  # Suppress Source C (pre-existing issue) reporting in reviewer output (default: false)

# Fix settings (#506)
fix:
  fail_fast_response: true             # Enable Fail-Fast Response Principle in fix.md Phase 2 (default: true)
  # DEPRECATED (#506): severity_gating convergence strategy has been removed.
  # The key is retained for backward compatibility only; it is always treated as false.
  # Non-convergence is now handled via fix.md Phase 4.3.3 AskUserQuestion (retry / separate issue / withdraw).
  severity_gating:
    enabled: false                     # DEPRECATED (#506): Pinned to false; not referenced by any code path

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

# PR review result recording (#443)
# The `review:` section above configures PR review **execution** (reviewer selection, debate,
# fact_check, etc.), while this `pr_review:` section configures PR review **output** (post_comment).
# By default, review results are saved to timestamped local files
# (`.rite/review-results/{pr_number}-{timestamp}.json`) instead of being posted to PR comments.
# `/rite:pr:fix` auto-reads results in the priority order: conversation > local file > PR comment.
pr_review:
  post_comment: false   # true to enable PR comment recording (equivalent to --post-comment, default: false)

# Safety settings (fail-closed thresholds)
safety:
  max_implementation_rounds: 20    # implementation round hard limit per Issue (default: 20)
  # max_review_fix_loops was removed in v1.0.0 (#557). Loop exits on 0 findings or 4-signal escalation.
  time_budget_minutes: 120         # time budget per Issue in minutes (advisory) (default: 120)
  auto_stop_on_repeated_failure: true   # stop when same failure class repeats (default: true)
  repeated_failure_threshold: 3         # consecutive same-class failure count to trigger stop (default: 3)

# Workflow incident auto-registration (#366)
# Detects workflow blockers (Skill load failure, hook abnormal exit, manual fallback adoption)
# and auto-registers them as Issues to prevent silent loss.
workflow_incident:
  enabled: true              # Enable incident detection mechanism (default: true, opt-out)

# Experience Wiki (opt-out, see wiki section below for full description)
wiki:
  enabled: true                        # Enable Wiki features (default: true, opt-out)
  branch_strategy: "separate_branch"   # "separate_branch" (recommended) or "same_branch"
  branch_name: "wiki"                  # Branch name for Wiki data (when branch_strategy is "separate_branch")
  auto_ingest: true                    # Auto-ingest on review/fix/close (default: true)
  auto_query: true                     # Auto-query on start/review/fix/implement (default: true)
  auto_lint: true                      # Auto-run /rite:wiki:lint --auto after ingest (default: true)

# Metrics settings
metrics:
  enabled: true            # Enable/disable metrics recording (default: true)
  baseline_issues: 3       # Number of Issues for baseline collection (default: 3)

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

# Language setting
language: auto  # auto | ja | en
```

## Configuration Sections

### project

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `type` | string | `generic` | Project type: `generic`, `webapp`, `library`, `cli`, `documentation` |

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
| `contextual` | boolean | `true` | Include Contextual Commits action lines in commit body |

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
| `loop.verification_mode` | boolean | `false` | Enable verification mode as supplement to full review. When enabled, reviews after the first cycle perform both full review and verification of previous fixes with incremental diff regression checks |
| `loop.allow_new_findings_in_unchanged_code` | boolean | `false` | Whether new findings in unchanged code should be blocking. When `false`, new MEDIUM/LOW findings in unchanged code are reported as "stability concerns" (non-blocking) |
| `loop.convergence_monitoring` | boolean | `true` | Enable fingerprint-based cycling detection (#557). When a finding fingerprint persists across two or more review cycles, the orchestrator fires Quality Signal 1 and escalates via `AskUserQuestion`. Replaces the prior cycle-count-based convergence strategy |
| `loop.auto_propagation_scan` | boolean | `true` | After a fix is applied, automatically scan for similar patterns elsewhere in the codebase to catch propagation gaps |
| `loop.pre_commit_drift_check` | boolean | `true` | Run `distributed-fix-drift-check` before committing fix changes to catch inconsistent partial applications |
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
| `observed_likelihood_gate.enabled` | boolean | `true` | Enable Observed Likelihood Gate (#506). Requires reviewers to evidence actual occurrence (Observed / Demonstrable) before reporting, reducing hypothetical-only findings. **⚠️ Known limitation (#506)**: config scaffolding only — not yet referenced by conditional runtime logic. The new behavior is hardcoded in `fix.md` / `review.md` / `_reviewer-base.md` prose. Setting this to `false` currently has no effect. Wiring is tracked as a follow-up |
| `observed_likelihood_gate.security_exception` | boolean | `true` | Security reviewer retains severity for Hypothetical findings (adversarial-input threat modeling is its job) |
| `observed_likelihood_gate.hypothetical_exception_reviewers` | array | `[security, database, devops, dependencies]` | Reviewer categories allowed to report Hypothetical findings — database migrations / infra / CVE are fatal on first occurrence |
| `observed_likelihood_gate.minimum` | string | `"demonstrable"` | Minimum likelihood required for non-exception reviewers (`observed` / `demonstrable` / `hypothetical`) |
| `fail_fast_first.enabled` | boolean | `true` | Enable Fail-Fast First principle (#506). Reviewers must consider throw/raise propagation before recommending fallback code. **⚠️ Known limitation (#506)**: config scaffolding only — not yet wired. Setting this to `false` currently has no effect |
| `fail_fast_first.allow_skill_exceptions` | boolean | `true` | Respect skill-level explicit fallback allowances (e.g., UI graceful degradation, stale-cache requirement) |
| `fail_fast_first.wiki_query_required` | boolean | `true` | Require Wiki query (`/rite:wiki:query`) for project-specific fallback patterns before recommendation |
| `separate_issue_creation.require_user_confirmation` | boolean | `true` | Require `AskUserQuestion` confirmation for separate-issue creation **even in E2E flow** (#506). **⚠️ Known limitation (#506)**: config scaffolding only — not yet wired. The "always confirm" behavior is hardcoded in `fix.md` Phase 4.3.3; setting this to `false` currently has no effect. Strongly recommended anyway once wired, to prevent the "escape hatch" misuse of separate issues |
| `separate_issue_creation.report_pre_existing_issues` | boolean | `false` | Suppress Source C (pre-existing issue) reporting in reviewer output. Use `/rite:investigate` for pre-existing concerns instead |

**Review-fix loop exit (v1.0.0 #557):**

The review-fix loop has two exit paths and no cycle-count-based hard limit:

| Exit | Trigger |
|------|---------|
| Normal | 0 findings remaining → `[review:mergeable]` |
| Escalate | Any of the 4 quality signals fires → `AskUserQuestion` with `本 PR 内で再試行 / 別 Issue として切り出す / PR を取り下げる / 手動レビューへエスカレーション` |

**Four quality signals** (see `commands/pr/references/fix-relaxation-rules.md#four-quality-signals-for-escalation` for full specification):

| # | Signal | Detection point |
|---|--------|-----------------|
| 1 | Same-finding cycling | `start.md` Phase 5.4.1.0 fingerprint check before every re-review |
| 2 | Root-cause-missing fix | `fix.md` Phase 3.2.1 commit body gate |
| 3 | Cross-validation disagreement | `review.md` Phase 5.2 + debate phase |
| 4 | Reviewer self-degraded | `_reviewer-base.md` Finding Quality Guardrail |

There is intentionally no cycle-count safety limit: the 4 quality signals are the sole termination mechanism. When they fire, the user chooses the next action via `AskUserQuestion`.

**Fix settings (#506):**

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `fix.fail_fast_response` | boolean | `true` | Enable Fail-Fast Response Principle in `fix.md` Phase 2. Requires a 4-item checklist (throw/raise propagation / existing error boundaries / not hiding via null-check / fix the test instead) before adopting a fix approach. Fallback adoption requires a commit message justification. **⚠️ Known limitation (#506)**: config scaffolding only — not yet wired. The principle is enforced via prose in `fix.md` Phase 2; setting this to `false` currently has no effect |
| `fix.severity_gating.enabled` | boolean | `false` | **DEPRECATED (#506 / #557)**. Retained for backward compatibility only; pinned to `false` and not referenced by any code path. Non-convergence mitigation is now handled automatically by the 4 quality signals (#557) — no strategy configuration is needed |

**Doc-Heavy PR Mode** (`doc_heavy.enabled: true` by default): A PR is classified as doc-heavy when `doc_lines / total_diff_lines >= lines_ratio_threshold`, or — for small diffs (`total_diff_lines < max_diff_lines_for_count`) — when `doc_files / total_files >= count_ratio_threshold`. In doc-heavy mode, `tech-writer-reviewer` verifies the five consistency categories (Implementation Coverage / Enumeration Completeness / UX Flow Accuracy / Order-Emphasis Consistency / Screenshot Presence) against the actual implementation using Grep/Read/Glob. See `plugins/rite/commands/pr/references/internal-consistency.md` for the full protocol.

**Verification mode** (`verification_mode: false` by default): When explicitly set to `true`, from cycle 2+, reviews perform both a full review and verification of previous fixes with incremental diff regression checks. New MEDIUM/LOW findings in unchanged code are classified as "stability concerns" (non-blocking). The default `false` performs full review only every cycle, maximizing review quality.

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
| `prompt-engineer-reviewer` | Claude Code skill, command, and agent definitions |
| `tech-writer-reviewer` | Documentation clarity, accuracy, completeness |
| `error-handling-reviewer` | Silent failures, error propagation, catch block quality |
| `type-design-reviewer` | Type encapsulation, invariant expression, enforcement |

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
| `max_implementation_rounds` | integer | `20` | Hard limit for implementation rounds per Issue (re-entries from checklist failures) |
| `time_budget_minutes` | integer | `120` | Advisory time budget per Issue in minutes (not enforced by timer) |
| `auto_stop_on_repeated_failure` | boolean | `true` | Stop workflow when the same failure class repeats consecutively |
| `repeated_failure_threshold` | integer | `3` | Number of consecutive same-class failures before triggering auto-stop |

**Example:**

```yaml
safety:
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

Settings for PR review **output** recording. This section is intentionally separated from the `review:` section (which configures review **execution**) so that future output destinations (Slack notifications, etc.) can be added without a breaking change to `review:` child keys.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `post_comment` | boolean | `false` | When `true`, review results are posted as PR comments (equivalent to `--post-comment`). When `false` (default), results are saved to `.rite/review-results/{pr_number}-{timestamp}.json` only |

`/rite:pr:fix` automatically reads review results in the priority order: **conversation > local file > PR comment**. Most users should leave `post_comment: false` to keep PR comment history clean. Enable it only if you want an auditable review trail on the PR itself. See #443 for rationale.

### workflow_incident

Settings for workflow incident auto-registration. When a workflow blocker is detected (Skill load failure, hook abnormal exit, or user adoption of a manual fallback), the orchestrator emits a sentinel via `plugins/rite/hooks/workflow-incident-emit.sh`. Detected incidents are auto-registered as Issues to prevent silent loss of actionable platform defects.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `enabled` | boolean | `true` | Enable the incident detection mechanism. Set `false` to opt out entirely |

**Non-blocking and dedupe behavior** (not configurable):

- Registration failure (network error, API error) never halts the workflow — the incident is retained in a context-local list and reported in the Phase 5.6 completion report.
- Within a single session, the same incident `type` is prompted only once (subsequent occurrences are suppressed to avoid `AskUserQuestion` spam).
- When absent from `rite-config.yml`, the section is treated as `enabled: true` (opt-out). Only the literal value `false` opts out.

See `docs/SPEC.md` "Workflow Incident Detection" (#366) for the full specification.

### wiki

Settings for the Experience Wiki — an LLM-driven project knowledge base that persists experiential heuristics extracted from review/fix/Issue outcomes. Based on the LLM Wiki pattern (Karpathy). See `docs/designs/experience-heuristics-persistence-layer.md` for the full design.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `enabled` | boolean | `true` | Enable Wiki features (opt-out). Set `false` to skip all Wiki hooks and commands |
| `branch_strategy` | string | `"separate_branch"` | Where Wiki data lives: `"separate_branch"` (dedicated orphan-like branch, recommended) or `"same_branch"` (Wiki files committed alongside code on the working branch) |
| `branch_name` | string | `"wiki"` | Name of the Wiki branch (used only when `branch_strategy` is `"separate_branch"`) |
| `auto_ingest` | boolean | `true` | Automatically run `/rite:wiki:ingest` on review/fix/close events to extract heuristics from raw sources |
| `auto_query` | boolean | `true` | Automatically run `/rite:wiki:query` at the start of Issue work and at review/fix/implement phases to inject relevant heuristics into the conversation context |
| `auto_lint` | boolean | `true` | Automatically run `/rite:wiki:lint --auto` after each ingest to detect contradictions, staleness, orphans, missing concepts, unregistered raw sources, and broken cross-refs |
| `growth_check.threshold_prs` | integer | `5` | Issue #524 layer 3 (lint growth check) — `/rite:lint` Phase 3.8 emits a non-blocking warning when this many merged PRs accumulate on the development base branch since the last commit on `branch_name` (signalling that Phase X.X.W may be silently skipped). Increase to relax the check; setting it to a very large number effectively disables the lint warning while preserving layers 1-2 |
| `growth_check.pr_raw_threshold` | integer | `3` | Issue #536 — warn when this many of the last `threshold_prs` merged PRs have no corresponding raw source on the wiki branch. Detects regressions where PRs are merged but Phase X.X.W never fires. Override at runtime with `--pr-raw-threshold N` |

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

> **Note for `same_branch` users**: The project's `.gitignore` ships with `.rite/wiki/` excluded as a silent-leak defense line for the default `separate_branch` strategy. If you switch to `same_branch`, you MUST add negation entries so that Wiki files are not ignored. See the `.gitignore` comment block near the `.rite/wiki/` line for the exact negation entries (`!.rite/wiki/` and `!.rite/wiki/**`) and the `git check-ignore -v` verification step.

**Example (loose growth-check threshold for slow-moving repos):**

```yaml
wiki:
  enabled: true
  growth_check:
    threshold_prs: 20   # warn only after 20 PRs have accumulated since the last wiki commit
    pr_raw_threshold: 5  # warn if 5+ of last 20 PRs have no raw source (Issue #536)
```

**Related commands:** `/rite:wiki:init` (one-time setup), `/rite:wiki:ingest`, `/rite:wiki:query`, `/rite:wiki:lint`.

### notifications

Each notification service (slack, discord, teams) can have:

| Field | Type | Description |
|-------|------|-------------|
| `enabled` | boolean | Enable this notification service |
| `webhook_url` | string | Webhook URL for the service |

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
