# Epic/Parent Issue Detection Reference

A comprehensive guide for detecting Epic/Parent Issues using multiple methods.

> **Note**: This document serves as the single source of truth for Epic/Parent Issue detection logic. All commands should reference this document instead of duplicating detection logic.

---

## Table of Contents

1. [Detection Criteria](#detection-criteria)
2. [trackedIssues API (Primary Method)](#trackedissues-api-primary-method)
3. [Body Tasklist Parsing (Fallback)](#body-tasklist-parsing-fallback)
4. [Label-Based Detection (Explicit Marking)](#label-based-detection-explicit-marking)
5. [Context Variables](#context-variables)
6. [Complete Detection Flow](#complete-detection-flow)
7. [Pagination and Limits](#pagination-and-limits)
8. [Related Documents](#related-documents)

---

## Detection Criteria

**Comprehensively determine** whether an Issue is a "parent Issue" using the following criteria:

| Condition | Detection Method | Reliability | Notes |
|-----------|------------------|-------------|-------|
| Has trackedIssues | GraphQL API | Highest | Most reliable method |
| Has Tasklist in body | Body parsing (`- [ ] #XX` pattern) | Medium | Complement when trackedIssues is absent |
| Has epic/parent label | Check labels field | Low | Explicit marking |

**Detection logic**: If **any one** of the above conditions is met, the Issue is determined to be a parent Issue (OR condition).

**Execution order**: All three detection methods should be executed, and results are combined with OR. The Issue is determined to be a parent Issue as soon as any one condition is detected.

---

## trackedIssues API (Primary Method)

### Basic Query

Fetch child Issues using the trackedIssues API:

```bash
gh api graphql -f query='
query($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) {
    issue(number: $number) {
      trackedIssues(first: 20) {
        nodes {
          number
          title
          state
          labels(first: 5) {
            nodes {
              name
            }
          }
        }
      }
    }
  }
}' -f owner="{owner}" -f repo="{repo}" -F number={issue_number}
```

### Extended Query (With Body and Projects)

For dependency analysis and Projects integration:

```bash
gh api graphql -f query='
query($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) {
    issue(number: $number) {
      trackedIssues(first: 20) {
        nodes {
          number
          title
          body
          state
          createdAt
          labels(first: 10) {
            nodes { name }
          }
          projectItems(first: 5) {
            nodes {
              fieldValues(first: 10) {
                nodes {
                  ... on ProjectV2ItemFieldSingleSelectValue {
                    name
                    field { ... on ProjectV2SingleSelectField { name } }
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}' -f owner="{owner}" -f repo="{repo}" -F number={issue_number}
```

**Note**: The `body` field is used for dependency checking (`depends on #XX` pattern search in child Issues).

### API Notes

#### trackedIssues vs subIssues

GitHub has two mechanisms for managing child Issues:

| API Field | Associated Feature | Usage Conditions |
|-----------|-------------------|------------------|
| `trackedIssues` | **Tasklists feature** (described in Tasklist format `- [ ] #123` in Issue body) | Available via standard GraphQL API |
| `subIssues` | **Sub-Issues feature** (new GitHub Projects feature) | May require `GraphQL-Features: sub_issues` header |

This implementation uses **`trackedIssues` (Tasklists feature)**. Reasons:
- No additional headers required with standard API
- Parent-child relationships are visually confirmable in Issue body
- Compatibility with existing Tasklist workflows

**Note**: Consider migration when the `subIssues` API becomes stable in the future.

---

## Body Tasklist Parsing (Fallback)

The Issue is also determined to be a parent Issue if the body contains Tasklist format (`- [ ] #XX`):

### Pattern

```regex
/- \[[ xX]\] #(\d+)/g
```

### Detection Notes

**Checkbox state independence**: The checkbox state (`[ ]` incomplete / `[x]` complete) does not affect parent Issue detection. The mere existence of Issue references in Tasklist format is an indicator of a parent Issue.

**Unsupported format**: URL-format Issue references (`- [ ] https://github.com/owner/repo/issues/XX`) are currently not matched by the pattern. Cross-repository references depend on the trackedIssues API.

### Relationship with trackedIssues

The `trackedIssues` API returns the result of GitHub internally parsing the Issue body's Tasklist. Therefore, trackedIssues API and Body Tasklist parsing are based on the same data source (Tasklist). Reasons for also using Body Tasklist parsing:

| Situation | trackedIssues API | Body Parse |
|-----------|------------------|------------|
| Normal | Detectable | Detectable (redundant but confirmatory) |
| Immediately after Issue creation | Possible API reflection delay | Immediately detectable |
| API error | Not detectable | Functions as fallback |

---

## Label-Based Detection (Explicit Marking)

The Issue is also determined to be a parent Issue if it has any of the following labels:

| Label Name | Description |
|------------|-------------|
| `epic` | Epic Issue |
| `parent` | Parent Issue |
| `umbrella` | Umbrella Issue |

### Label Comparison Rules

**Note**: GitHub label comparison is case-insensitive. While the Web UI preserves label name casing, search and filtering treat `Epic`, `EPIC`, `epic` as identical. The `gh` CLI `--jq` filter should also compare case-insensitively (e.g., `select(.name | ascii_downcase == "epic")`).

---

## Context Variables

### Detection Result Variables

Retain detection results in conversation context:

| Variable | Type | Description |
|----------|------|-------------|
| `is_parent_issue` | boolean | Whether the Issue is determined to be a parent Issue |
| `has_sub_issues` | boolean | Whether child Issues (trackedIssues) actually exist |
| `parent_issue_reason` | string \| null | Detection method used (see priority table below) |

### Detection Reason Priority

When multiple conditions match, record the one with the highest priority as `parent_issue_reason`:

| Value | Meaning | Priority |
|-------|---------|----------|
| `trackedIssues` | Detected child Issues via GraphQL API | 1 (highest) |
| `tasklist` | Detected Tasklist pattern in body | 2 |
| `label:{name}` | Detected parent Issue label (e.g., `label:epic`) | 3 |
| `null` | Not a parent Issue | - |

**Example**: If both trackedIssues and epic label are present, record `trackedIssues`.

### Child Issue Information Retention

The `trackedIssues.nodes` array (child Issue number, title, state, labels) obtained during detection is **retained in Claude's conversation context**. Commands that need child Issue information should reference this in-context data.

**Additional information retrieval**: The basic detection query only retrieves essential fields (number, title, state, labels). Commands that need additional fields (body, projectItems, etc.) should use the Extended Query to retrieve them as needed.

---

## Complete Detection Flow

### Step 1: Fetch Issue Information

```bash
gh issue view {issue_number} --json number,title,body,state,labels,milestone,projectItems
```

### Step 2: Execute All Detection Methods

**2.1 trackedIssues API Check**

Execute the Basic Query. If `trackedIssues.nodes` is not empty:
- Set `is_parent_issue = true`
- Set `has_sub_issues = true`
- Set `parent_issue_reason = "trackedIssues"`

**2.2 Body Tasklist Check**

Search for Tasklist pattern in the `body` field. If pattern matches:
- Set `is_parent_issue = true`
- If not already set by 2.1, set `parent_issue_reason = "tasklist"`

**2.3 Label Check**

Search for epic/parent/umbrella labels (case-insensitive). If found:
- Set `is_parent_issue = true`
- If not already set by 2.1 or 2.2, set `parent_issue_reason = "label:{name}"` (e.g., `label:epic`)

### Step 3: Finalize Detection

If any detection method succeeded:
- `is_parent_issue = true`
- Proceed to parent Issue handling logic

If all detection methods failed:
- `is_parent_issue = false`
- Proceed to normal Issue handling logic

---

## Pagination and Limits

### Default Limit

The default `trackedIssues(first: 20)` limit handles most use cases, as GitHub's Tasklists feature rarely exceeds 20 items.

### When Child Issues Exceed 20

Use the following approach:

1. If workable candidates exist in the first 20, use them
2. Only use pagination (`after` cursor) for additional retrieval when no workable candidates are found

### Pagination Query

```bash
gh api graphql -f query='
query($owner: String!, $repo: String!, $number: Int!, $cursor: String) {
  repository(owner: $owner, name: $repo) {
    issue(number: $number) {
      trackedIssues(first: 20, after: $cursor) {
        pageInfo {
          hasNextPage
          endCursor
        }
        nodes {
          number
          title
          state
          labels(first: 5) {
            nodes { name }
          }
        }
      }
    }
  }
}' -f owner="{owner}" -f repo="{repo}" -F number={issue_number} -f cursor="{end_cursor}"
```

### Pagination Logic

```bash
# Pseudocode
CURSOR=""
CANDIDATES=[]

while true; do
  RESULT=$(query_with_cursor "$CURSOR")
  NEW_CANDIDATES=$(filter_workable_issues "$RESULT")
  CANDIDATES+=("$NEW_CANDIDATES")

  if [ ${#CANDIDATES[@]} -gt 0 ]; then
    # Found workable candidates, stop pagination
    break
  fi

  HAS_NEXT=$(echo "$RESULT" | jq -r '.data.repository.issue.trackedIssues.pageInfo.hasNextPage')
  if [ "$HAS_NEXT" = "false" ]; then
    # No more pages, stop
    break
  fi

  CURSOR=$(echo "$RESULT" | jq -r '.data.repository.issue.trackedIssues.pageInfo.endCursor')
done
```

---

## Related Documents

- [GraphQL Helpers](./graphql-helpers.md) - Common GraphQL query patterns
- [gh CLI Patterns](./gh-cli-patterns.md) - Frequently used gh command patterns
- [rite-workflow SKILL.md](../skills/rite-workflow/SKILL.md) - Workflow skill definition
