# Change Intelligence Summary

Pre-computed change statistics provided to reviewers to improve review quality and focus.

## Purpose

Analyze `git diff` output to classify changes and generate a one-paragraph summary for reviewers. This gives reviewers immediate context about the nature of the PR before diving into specifics.

## Data Collection

### Step 1: Use Phase 1.1 File Statistics

Use the `files` array retrieved in Phase 1.1 (`gh pr view --json files`). Each entry contains `path`, `additions`, and `deletions`, providing the same per-file breakdown as `--stat` without an additional API call.

### Step 2: Retrieve Numeric Statistics

```bash
git diff {base_branch}...HEAD --numstat
```

This provides machine-readable `additions\tdeletions\tfilename` lines for programmatic analysis.

## Change Type Estimation

Estimate the primary change type from the statistics:

| Signal | Estimated Type | Description |
|--------|---------------|-------------|
| Many new files (>50% of changed files are additions-only) | New Feature | New functionality being added |
| Most changes in existing files, few new/deleted files | Refactor | Restructuring existing code |
| Deletions dominate (deletions > 2x additions) | Cleanup | Removing dead code or simplifying |
| Single file with large changes | Focused Fix | Bug fix or targeted improvement |
| Balanced additions/deletions across many files | Migration | Systematic renaming or pattern change |
| Changes concentrated in test files (>60% in test/) | Test Enhancement | Adding or improving tests |
| Changes concentrated in docs/config files | Configuration | Config or documentation update |

**Estimation rules:**
1. Classify each changed file by category (the File Classification section below)
2. Count files and line changes per category
3. Apply the signal table top-to-bottom; first match wins
4. If no signal matches clearly, default to "Mixed Changes"

## File Classification

Classify each changed file into one of four categories:

| Category | Patterns | Examples |
|----------|----------|---------|
| **source** | `*.ts`, `*.tsx`, `*.js`, `*.jsx`, `*.py`, `*.go`, `*.rs`, `*.java`, `*.rb`, `*.php`, `*.c`, `*.cpp`, `*.sh`, `*.swift`, `*.kt` | Application logic, utilities, components |
| **test** | `*.test.*`, `*.spec.*`, `**/test/**`, `**/__tests__/**`, `**/tests/**`, `*.test.ts`, `*.spec.js` | Unit tests, integration tests, e2e tests |
| **config** | `*.yml`, `*.yaml`, `*.json`, `*.toml`, `*.ini`, `*.env*`, `Dockerfile*`, `docker-compose*`, `Makefile`, `*.config.*`, `package.json`, `*lock*` | Build config, CI/CD, dependencies |
| **docs** | `*.md`, `docs/**`, `README*`, `LICENSE*`, `CHANGELOG*`, `*.txt` | Documentation, changelogs, readmes |

**Note**: For projects where `.md` files serve as executable instructions (e.g., Claude Code plugins), these are classified as **docs** by this heuristic but functionally act as source code. The classification is for reviewer context, not a judgment of file importance.

**Classification rules:**
1. Test patterns take priority (a file matching both `*.ts` and `*.test.ts` is classified as **test**)
2. For ambiguous files, use the more specific pattern
3. Files not matching any pattern are classified as **source**

## Summary Generation

Generate a one-paragraph summary in the following format:

```
Change Intelligence: {change_type} — {total_files} files changed ({source_count} source, {test_count} test, {config_count} config, {docs_count} docs). {additions}+ / {deletions}- lines. {focus_note}
```

**`{focus_note}` rules:**

Apply rules top-to-bottom; first match wins.

| Condition | Focus Note |
|-----------|-----------|
| One file has >50% of total changes | Concentrated in `{filename}` |
| One directory has >60% of files | Focused on `{directory}/` |
| Test-to-source ratio > 2:1 (by lines) | Heavy test coverage |
| No test files changed | No test changes |
| Otherwise | Changes spread across multiple areas |

## Example Output

```
Change Intelligence: Refactor — 8 files changed (5 source, 2 test, 0 config, 1 docs). 142+ / 89- lines. Focused on plugins/rite/commands/pr/.
```

```
Change Intelligence: New Feature — 3 files changed (1 source, 1 test, 0 config, 1 docs). 245+ / 0- lines. Concentrated in src/auth/oauth-handler.ts.
```

## Integration Point

The generated summary is embedded as `{change_intelligence_summary}` in the reviewer prompt template (Phase 4.5 of `review.md`). It appears before the diff content to provide upfront context.
