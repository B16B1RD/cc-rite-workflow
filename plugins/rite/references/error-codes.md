# Rite Workflow Error Code Reference

Standardized error codes for rite workflow operations.

---

## Error Code Format

Error codes follow the format: `[ZEN-EXXX]` where XXX is a 3-digit number.

Example: `[ZEN-E001] rite-config.yml not found`

---

## Error Code Categories

| Range | Category | Description |
|-------|----------|-------------|
| E001-E099 | Setup/Init | Configuration and initialization errors |
| E100-E199 | Issue Operations | Issue creation, start, update, close errors |
| E200-E299 | Branch/Git | Branch management and Git operation errors |
| E300-E399 | PR Operations | Pull request creation, update, merge errors |
| E400-E499 | Review | Code review and quality check errors |
| E500-E599 | Configuration | rite-config.yml and settings errors |

---

## Error Code Definitions

### Setup/Init Errors (E001-E099)

#### [ZEN-E001] Configuration File Not Found

**Message**: `rite-config.yml not found`

**Cause**: The project has not been initialized with `/rite:init`, or the configuration file was deleted.

**Recovery Steps**:
1. Run `/rite:init` to create the configuration file
2. Follow the initialization wizard
3. Verify `rite-config.yml` exists in the project root

---

#### [ZEN-E002] gh CLI Not Installed

**Message**: `gh CLI not found or not executable`

**Cause**: GitHub CLI is not installed or not in PATH.

**Recovery Steps**:
1. Install gh CLI for your platform:
   - macOS: `brew install gh`
   - Linux: https://github.com/cli/cli/blob/trunk/docs/install_linux.md
   - Windows: `winget install GitHub.cli`
2. Verify installation: `gh --version`
3. Retry the command

---

#### [ZEN-E003] gh CLI Version Too Old

**Message**: `gh CLI version must be ≥2.x (current: {version})`

**Cause**: Installed gh CLI version is older than the minimum required version (2.0.0).

**Recovery Steps**:
1. Update gh CLI:
   - macOS: `brew upgrade gh`
   - Linux/Windows: Download latest from https://github.com/cli/cli/releases
2. Verify version: `gh --version`
3. Retry the command

---

#### [ZEN-E004] GitHub Authentication Required

**Message**: `GitHub authentication not configured`

**Cause**: User has not authenticated with GitHub via gh CLI.

**Recovery Steps**:
1. Run: `gh auth login`
2. Follow the authentication prompts
3. Verify authentication: `gh auth status`
4. Retry the command

---

#### [ZEN-E005] Not a GitHub Repository

**Message**: `Current directory is not a GitHub repository`

**Cause**: The current directory is not a Git repository, or is not pushed to GitHub.

**Recovery Steps**:
1. If not a Git repository: `git init && git add . && git commit -m "Initial commit"`
2. Push to GitHub: `gh repo create --source . --push`
3. Verify: `gh repo view`
4. Retry the command

---

#### [ZEN-E010] Projects Not Found

**Message**: `GitHub Projects not found for owner {owner}`

**Cause**: No GitHub Projects exist for the repository owner, or Projects integration is misconfigured.

**Recovery Steps**:
1. Create a Project manually on GitHub
2. Or skip Projects integration during `/rite:init`
3. Or disable Projects in rite-config.yml: `projects.enabled: false`
4. Retry the command

---

#### [ZEN-E011] Hook Installation Failed

**Message**: `Failed to install workflow hooks in .claude/settings.local.json`

**Cause**: Unable to write to `.claude/settings.local.json`, or JSON merge failed.

**Recovery Steps**:
1. Check file permissions: `ls -la .claude/settings.local.json`
2. Verify JSON syntax is valid
3. Manually merge hooks configuration if needed
4. Retry `/rite:init`

---

### Issue Operation Errors (E100-E199)

#### [ZEN-E100] Issue Not Found

**Message**: `Issue #{number} not found in this repository`

**Cause**: The specified Issue number does not exist, or has been deleted.

**Recovery Steps**:
1. List all Issues: `/rite:issue:list`
2. Verify the Issue number
3. Retry with a valid Issue number

---

#### [ZEN-E101] Issue Already Started

**Message**: `Issue #{number} is already in progress (branch: {branch})`

**Cause**: A feature branch for this Issue already exists.

**Recovery Steps**:
1. Check existing branches: `git branch -a | grep issue-{number}`
2. Switch to existing branch: `git checkout {branch}`
3. Or close/delete the existing branch before restarting

---

#### [ZEN-E102] Issue Quality Score Insufficient

**Message**: `Issue #{number} has quality score {score} (D). More information required before starting`

**Cause**: The Issue lacks sufficient detail (missing description, acceptance criteria, or context).

**Recovery Steps**:
1. Edit the Issue on GitHub to add:
   - Detailed description
   - Acceptance criteria
   - Technical context or requirements
2. Re-evaluate: `/rite:issue:start {number}`
3. Or proceed with supplementary questions

---

#### [ZEN-E103] Issue Creation Failed

**Message**: `Failed to create Issue: {error_details}`

**Cause**: GitHub API error during Issue creation, or insufficient permissions.

**Recovery Steps**:
1. Check repository permissions: `gh repo view --json viewerPermission`
2. Verify network connectivity: `gh auth status`
3. Check for API rate limits: `gh api rate_limit`
4. Retry after resolving the issue

---

#### [ZEN-E104] Issue Update Failed

**Message**: `Failed to update Issue #{number}: {error_details}`

**Cause**: GitHub API error, or the Issue is locked.

**Recovery Steps**:
1. Verify Issue exists and is not locked
2. Check permissions: must have write access
3. Retry the operation
4. If persistent, update manually on GitHub

---

#### [ZEN-E110] Issue Status Update Failed

**Message**: `Failed to update Issue status in Projects`

**Cause**: Projects integration is enabled but the status field is missing or misconfigured.

**Recovery Steps**:
1. Verify Projects configuration in rite-config.yml
2. Check Status field exists: `gh project field-list {project-number} --owner {owner}`
3. Disable Projects integration if not needed: `projects.enabled: false`
4. Retry the command

---

### Branch/Git Errors (E200-E299)

#### [ZEN-E200] Branch Creation Failed

**Message**: `Failed to create branch {branch_name}: {error}`

**Cause**: Git error during branch creation, or branch name is invalid.

**Recovery Steps**:
1. Verify current branch: `git branch --show-current`
2. Ensure working directory is clean: `git status`
3. Check for branch name conflicts: `git branch -a | grep {branch_name}`
4. Retry with a different branch name

---

#### [ZEN-E201] Branch Not on Base Branch

**Message**: `Not on base branch. Current: {current}, expected: {base}`

**Cause**: Attempting to start new work while on a feature branch.

**Recovery Steps**:
1. Switch to base branch: `git checkout {base}`
2. Or finish current work before starting new Issue
3. Retry the command

---

#### [ZEN-E202] Uncommitted Changes

**Message**: `Uncommitted changes detected. Commit or stash before proceeding`

**Cause**: The working directory has uncommitted changes that would be lost.

**Recovery Steps**:
1. Commit changes: `git add . && git commit -m "WIP"`
2. Or stash changes: `git stash`
3. Or discard changes: `git checkout .` (caution!)
4. Retry the command

---

#### [ZEN-E203] Branch Extraction Failed

**Message**: `Failed to extract Issue number from branch name: {branch}`

**Cause**: Current branch does not follow the naming convention `{type}/issue-{number}-{slug}`.

**Recovery Steps**:
1. Verify branch naming convention in rite-config.yml
2. Use `/rite:workflow` to check current state
3. Manually specify Issue number if needed

---

#### [ZEN-E204] Push Failed

**Message**: `Failed to push branch {branch} to remote: {error}`

**Cause**: Network error, authentication issue, or remote rejection.

**Recovery Steps**:
1. Check network connection
2. Verify authentication: `gh auth status`
3. Pull remote changes: `git pull --rebase`
4. Retry push: `git push -u origin {branch}`

---

#### [ZEN-E210] Merge Conflict Detected

**Message**: `Merge conflicts detected. Resolve conflicts before continuing`

**Cause**: The feature branch has conflicts with the base branch.

**Recovery Steps**:
1. Pull latest changes: `git pull origin {base}`
2. Resolve conflicts in affected files
3. Stage resolved files: `git add {files}`
4. Complete merge: `git commit`
5. Retry the command

---

### PR Operation Errors (E300-E399)

#### [ZEN-E300] PR Creation Failed

**Message**: `Failed to create pull request: {error_details}`

**Cause**: GitHub API error, insufficient permissions, or PR already exists.

**Recovery Steps**:
1. Check for existing PR: `gh pr list --head {branch}`
2. Verify repository permissions
3. Ensure branch is pushed: `git push -u origin {branch}`
4. Retry the command

---

#### [ZEN-E301] PR Not Found

**Message**: `Pull request #{number} not found`

**Cause**: The specified PR number does not exist or has been deleted.

**Recovery Steps**:
1. List all PRs: `gh pr list`
2. Verify the PR number
3. Retry with a valid PR number

---

#### [ZEN-E302] No Active PR

**Message**: `No active pull request found for current branch`

**Cause**: Attempting PR operations without an associated PR.

**Recovery Steps**:
1. Create PR first: `/rite:pr:create`
2. Or switch to a branch with an active PR
3. Verify: `gh pr view`

---

#### [ZEN-E303] PR Already Ready for Review

**Message**: `PR #{number} is already marked as ready for review`

**Cause**: Attempting to mark a non-draft PR as ready.

**Recovery Steps**:
1. Check PR state: `gh pr view {number} --json isDraft`
2. This is not an error if the PR is already ready
3. Proceed with review or merge workflow

---

#### [ZEN-E304] PR Merge Blocked

**Message**: `PR #{number} cannot be merged: {blocking_reasons}`

**Cause**: PR has failing checks, unresolved reviews, or merge conflicts.

**Recovery Steps**:
1. Check PR status: `gh pr view {number}`
2. Resolve blocking issues:
   - Fix failing CI checks
   - Resolve merge conflicts
   - Address review comments
3. Retry after resolving blockers

---

#### [ZEN-E310] Draft Conversion Failed

**Message**: `Failed to mark PR #{number} as ready for review`

**Cause**: GitHub API error or insufficient permissions.

**Recovery Steps**:
1. Verify PR is in draft state
2. Check permissions: must have write access
3. Manually convert on GitHub if needed
4. Retry the command

---

### Review Errors (E400-E499)

#### [ZEN-E400] No Changes to Review

**Message**: `No changes found between {base} and {head}`

**Cause**: The feature branch has no commits compared to the base branch.

**Recovery Steps**:
1. Verify changes exist: `git log {base}..HEAD`
2. Ensure changes are committed: `git status`
3. Push commits: `git push`
4. Retry the review

---

#### [ZEN-E401] Review Agent Failed

**Message**: `Review agent {agent_name} encountered an error: {error}`

**Cause**: A specific review agent (security, test, etc.) failed to complete its analysis.

**Recovery Steps**:
1. Check agent definition file exists: `{plugin_root}/agents/{agent_name}.md` (resolve `{plugin_root}` per [Plugin Path Resolution](./plugin-path-resolution.md#resolution-script-full-version))
2. Review error details in the output
3. Retry with a subset of reviewers if needed
4. Report persistent failures as a bug

---

#### [ZEN-E402] All Review Agents Failed

**Message**: `All review agents failed to execute. Cannot complete review`

**Cause**: System-wide failure preventing any review agents from running.

**Recovery Steps**:
1. Check network connectivity
2. Verify agent definition files are present
3. Review Claude Code logs for errors
4. Retry after resolving system issues

---

#### [ZEN-E403] Reviewer Load Failed

**Message**: `Failed to load reviewer skill file: {file_path}`

**Cause**: Reviewer skill file is missing, corrupted, or has syntax errors.

**Recovery Steps**:
1. Verify file exists: `ls {plugin_root}/skills/reviewers/{name}.md` (resolve `{plugin_root}` per [Plugin Path Resolution](./plugin-path-resolution.md#resolution-script-full-version))
2. Check file syntax and frontmatter
3. Restore from git history if corrupted
4. Use fallback profile if file cannot be recovered

---

#### [ZEN-E410] Lint Command Failed

**Message**: `Lint command exited with code {exit_code}`

**Cause**: The configured lint command found errors or failed to execute.

**Recovery Steps**:
1. Review lint output for specific errors
2. Fix reported issues in the code
3. Verify lint command in rite-config.yml: `commands.lint`
4. Retry after fixing issues

---

#### [ZEN-E411] Test Command Failed

**Message**: `Test command exited with code {exit_code}`

**Cause**: Tests failed or the test command encountered an error.

**Recovery Steps**:
1. Review test output for failures
2. Fix failing tests
3. Verify test command in rite-config.yml: `commands.test`
4. Retry after fixing tests

---

### Configuration Errors (E500-E599)

#### [ZEN-E500] Invalid rite-config.yml

**Message**: `rite-config.yml has invalid syntax or structure`

**Cause**: YAML syntax errors or missing required fields.

**Recovery Steps**:
1. Validate YAML syntax: `yq eval . rite-config.yml`
2. Compare with template: `{plugin_root}/templates/config/rite-config.yml` (resolve `{plugin_root}` per [Plugin Path Resolution](./plugin-path-resolution.md#resolution-script-full-version))
3. Fix syntax errors or missing fields
4. Retry the command

---

#### [ZEN-E501] Missing Required Configuration

**Message**: `Required configuration field missing: {field_path}`

**Cause**: A mandatory field is not present in rite-config.yml.

**Recovery Steps**:
1. Add the missing field to rite-config.yml
2. Reference the configuration schema
3. Or re-run `/rite:init` to regenerate
4. Retry the command

---

#### [ZEN-E502] Invalid Branch Pattern

**Message**: `Branch pattern in rite-config.yml is invalid: {pattern}`

**Cause**: The branch naming pattern has invalid syntax or placeholders.

**Recovery Steps**:
1. Review branch pattern: `branch.pattern`
2. Use valid placeholders: `{type}`, `{number}`, `{slug}`
3. Example: `"{type}/issue-{number}-{slug}"`
4. Retry the command

---

#### [ZEN-E503] Invalid Projects Configuration

**Message**: `Projects configuration is invalid: {details}`

**Cause**: Projects settings have missing or incorrect values.

**Recovery Steps**:
1. Verify Projects settings in rite-config.yml:
   - `projects.enabled`
   - `projects.project_number`
   - `projects.owner`
2. Disable Projects if not needed: `projects.enabled: false`
3. Or re-run `/rite:init` to reconfigure
4. Retry the command

---

#### [ZEN-E510] Template Not Found

**Message**: `Template file not found: {template_path}`

**Cause**: A required template file is missing from the plugin's `templates/` directory.

**Recovery Steps**:
1. Check if template exists: `ls {template_path}`
2. Restore template: `/rite:template:reset`
3. Or manually create from examples
4. Retry the command

---

#### [ZEN-E511] Language Configuration Invalid

**Message**: `Invalid language setting in rite-config.yml: {value}`

**Cause**: The `language` field has an unsupported value.

**Recovery Steps**:
1. Use valid values: `auto`, `ja`, or `en`
2. Edit rite-config.yml: `language: auto`
3. Retry the command

---

## Error Handling Best Practices

### For Users

1. **Read the error code and message carefully** - Error codes provide specific guidance
2. **Follow recovery steps in order** - Steps are ordered by likelihood of success
3. **Check Prerequisites** - Many errors stem from missing dependencies
4. **Consult documentation** - Use `/rite:workflow` or `/rite:getting-started`

### For Developers

When adding new error conditions to commands:

1. **Assign a unique error code** in the appropriate range
2. **Include the error code in the message**: `[ZEN-EXXX] description`
3. **Document the error** in this reference file
4. **Provide actionable recovery steps** - Not just "try again"
5. **Log error details** to stderr for debugging

### Error Message Format

```bash
echo "[ZEN-EXXX] {brief_message}" >&2
echo "" >&2
echo "Cause: {explanation}" >&2
echo "Recovery: {first_step}" >&2
```

Example:

```bash
echo "[ZEN-E100] Issue #42 not found in this repository" >&2
echo "" >&2
echo "Cause: The Issue may have been deleted or the number is incorrect." >&2
echo "Recovery: Run /rite:issue:list to see available Issues." >&2
```

---

## See Also

- [Getting Started Guide](../commands/getting-started.md) - Prerequisites and common issues
- [gh CLI Patterns](./gh-cli-patterns.md) - GitHub CLI usage and error handling
- [Workflow Overview](../commands/workflow.md) - Full workflow context
