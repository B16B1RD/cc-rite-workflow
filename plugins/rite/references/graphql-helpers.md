# GraphQL Helpers Reference

A collection of common GraphQL query patterns used in rite workflow.

> **Note**: GraphQL samples in this document are based on the GitHub Projects V2 API. Field names, types, and mutation signatures may change as the API evolves. Verify against the [GitHub GraphQL API documentation](https://docs.github.com/en/graphql) if you encounter unexpected behavior.

---

## Table of Contents

1. [Owner Type Detection](#owner-type-detection)
2. [Project ID Retrieval](#project-id-retrieval)
3. [Iteration Field Detection](#iteration-field-detection)
4. [Project Item Retrieval](#project-item-retrieval)
5. [Iteration Assignment](#iteration-assignment)
6. [PR Creation Guards](#pr-creation-guards)
7. [Safe GraphQL Variable Encoding](#safe-graphql-variable-encoding)
8. [Error Handling](#error-handling)
9. [addSubIssue Helper](#addsubissue-helper)
10. [Related Documents](#related-documents)

---

## Owner Type Detection

The GraphQL API requires different root queries for `user` and `organization`.

### Detection Logic

```bash
# Owner type detection (user or organization)
# Note: On API error, assume Organization (most public repos are organization-owned)
OWNER_TYPE=$(gh api "users/{owner}" --jq '.type' 2>/dev/null || echo "Organization")
# → "User" or "Organization"
```

### Usage Example

> **Note**: The examples below use `-f query='...'` for brevity.
> Since these queries contain 「!」 (e.g., 「String!」, 「Int!」), prefer the heredoc pattern from [Safe GraphQL Variable Encoding](#safe-graphql-variable-encoding) in production to avoid history expansion issues.

```bash
# Switch query based on detection result
if [ "$OWNER_TYPE" = "User" ]; then
  gh api graphql -f query='
    query($owner: String!, $number: Int!) {
      user(login: $owner) {
        projectV2(number: $number) { id }
      }
    }' -f owner="$OWNER" -F number="$PROJECT_NUMBER"
else
  gh api graphql -f query='
    query($owner: String!, $number: Int!) {
      organization(login: $owner) {
        projectV2(number: $number) { id }
      }
    }' -f owner="$OWNER" -F number="$PROJECT_NUMBER"
fi
```

---

## Project ID Retrieval

Retrieve Node ID from Project number.

### Query (User)

```graphql
query($owner: String!, $number: Int!) {
  user(login: $owner) {
    projectV2(number: $number) {
      id
      title
    }
  }
}
```

### Query (Organization)

```graphql
query($owner: String!, $number: Int!) {
  organization(login: $owner) {
    projectV2(number: $number) {
      id
      title
    }
  }
}
```

---

## Iteration Field Detection

Retrieve Iteration field and its configuration from a Project.

### Query

```graphql
query($projectId: ID!) {
  node(id: $projectId) {
    ... on ProjectV2 {
      fields(first: 20) {
        nodes {
          ... on ProjectV2IterationField {
            id
            name
            configuration {
              iterations {
                id
                title
                startDate
                duration
              }
            }
          }
        }
      }
    }
  }
}
```

### Current Iteration Detection

```bash
# Today's date
TODAY=$(date +%Y-%m-%d)

# Check each Iteration
# jq processing flow:
#   1. Select fields with configuration from fields.nodes[]
#   2. For each iteration, calculate start date and end date (start date + duration days)
#   3. Check if today falls within that period
#   4. Get the matching iteration's id
CURRENT_ITERATION=$(echo "$ITERATION_FIELD" | jq -r --arg today "$TODAY" '
  .data.node.fields.nodes[]
  | select(.configuration)
  | .configuration.iterations[]
  | select(
      .startDate <= $today and
      (.startDate | strptime("%Y-%m-%d") | mktime + (.duration * 86400) | strftime("%Y-%m-%d")) > $today
    )
  | .id
' | head -1)
```

---

## Project Item Retrieval

### Items by Iteration

```graphql
query($projectId: ID!, $fieldId: ID!, $iterationId: String!) {
  node(id: $projectId) {
    ... on ProjectV2 {
      items(first: 100, filter: {
        field: { fieldId: $fieldId, iterationId: $iterationId }
      }) {
        totalCount
        nodes {
          id
          content {
            ... on Issue {
              number
              title
              state
              labels(first: 5) { nodes { name } }
              assignees(first: 3) { nodes { login } }
            }
          }
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
```

### Backlog Items

Retrieve items not assigned to any Iteration:

```graphql
query($projectId: ID!) {
  node(id: $projectId) {
    ... on ProjectV2 {
      items(first: 100) {
        nodes {
          id
          content {
            ... on Issue {
              number
              title
              state
            }
          }
          fieldValues(first: 10) {
            nodes {
              ... on ProjectV2ItemFieldIterationValue {
                iterationId
              }
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
```

---

## Iteration Assignment

Assign an Issue to a specific Iteration.

### Mutation

```graphql
mutation($projectId: ID!, $itemId: ID!, $fieldId: ID!, $iterationId: String!) {
  updateProjectV2ItemFieldValue(
    input: {
      projectId: $projectId
      itemId: $itemId
      fieldId: $fieldId
      value: { iterationId: $iterationId }
    }
  ) {
    projectV2Item { id }
  }
}
```

---

## PR Creation Guards

> **🔴 CRITICAL**: Always verify these conditions before creating a PR. See [gh-cli-patterns.md Category 5](./gh-cli-patterns.md#category-5-graphql-pr-creation-error--10-sessions) for the prohibited patterns.

PR creation fails when:
1. No commits exist between base and head branches
2. The branch has not been pushed to remote

### Pre-Creation Check Pattern

```bash
# ✅ REQUIRED: Verify commits exist before PR creation
COMMIT_COUNT=$(git rev-list --count {base_branch}..HEAD 2>/dev/null || echo "0")
if [ "$COMMIT_COUNT" = "0" ]; then
  echo "ERROR: No commits between {base_branch} and current branch" >&2
  echo "Create at least one commit before attempting PR creation" >&2
  exit 1
fi
echo "Found $COMMIT_COUNT commit(s) to include in PR"
```

### Branch Remote Existence Check

```bash
# ✅ REQUIRED: Verify branch exists on remote
BRANCH_NAME=$(git branch --show-current)
REMOTE_REF=$(git ls-remote --heads origin "$BRANCH_NAME" 2>/dev/null)
if [ -z "$REMOTE_REF" ]; then
  echo "ERROR: Branch '$BRANCH_NAME' not found on remote" >&2
  echo "Run 'git push -u origin $BRANCH_NAME' first" >&2
  exit 1
fi
```

### Combined Guard (Recommended)

Use this combined check before any `gh pr create` call:

```bash
# ✅ RECOMMENDED: Full pre-PR-creation validation
BRANCH_NAME=$(git branch --show-current)
BASE_BRANCH="{base_branch}"

# Check 1: Commits exist
COMMIT_COUNT=$(git rev-list --count "$BASE_BRANCH".."$BRANCH_NAME" 2>/dev/null || echo "0")
if [ "$COMMIT_COUNT" = "0" ]; then
  echo "ERROR: No commits between $BASE_BRANCH and $BRANCH_NAME" >&2
  exit 1
fi

# Check 2: Branch is pushed
REMOTE_REF=$(git ls-remote --heads origin "$BRANCH_NAME" 2>/dev/null)
if [ -z "$REMOTE_REF" ]; then
  echo "ERROR: Branch '$BRANCH_NAME' not found on remote. Pushing..." >&2
  git push -u origin "$BRANCH_NAME" || {
    echo "ERROR: Failed to push branch" >&2
    exit 1
  }
fi

echo "Pre-PR checks passed: $COMMIT_COUNT commit(s), branch on remote"
```

### Error Messages and Their Causes

| Error Message | Cause | Fix |
|--------------|-------|-----|
| `No commits between X and Y` | Head branch has no new commits vs base | Create and push at least one commit |
| `Could not resolve to a Ref` | Branch doesn't exist on remote | `git push -u origin {branch_name}` |
| `A pull request already exists` | PR for this branch already open | Use `gh pr view` to find existing PR |
| `Base branch is invalid` | Base branch doesn't exist | Verify `rite-config.yml` `branch.base` |

---

## Safe GraphQL Variable Encoding

> **🔴 CRITICAL**: Never pass Markdown content, multi-line strings, or special characters directly via `-f` flag to GraphQL variables. See [gh-cli-error-catalog.md Category 6](./gh-cli-error-catalog.md#category-6-graphql-variable-encoding-error--2-sessions).

### The Problem

```bash
# 🚫 PROHIBITED: -f passes raw string, special chars cause UNKNOWN_CHAR
gh api graphql -f query='
  mutation($body: String!) {
    addComment(input: {subjectId: $id, body: $body}) {
      commentEdge { node { id } }
    }
  }
' -f body="## Title\n\n- item with | pipe"
# → Error: UNKNOWN_CHAR
```

**History expansion hazard**: See [gh-cli-error-catalog.md Category 6](./gh-cli-error-catalog.md#category-6-graphql-variable-encoding-error--2-sessions) for root cause details. Always deliver queries containing 「!」 via heredoc or file input.

### Safe Pattern: jq --rawfile for GraphQL String Variables

When a GraphQL mutation requires a string variable with rich content (Markdown, multi-line, special characters):

```bash
# ✅ SAFE: Use jq --rawfile to construct the entire GraphQL request
tmpfile=$(mktemp)
queryfile=$(mktemp)
trap 'rm -f "$tmpfile" "$queryfile"' EXIT

cat <<'BODY_EOF' > "$tmpfile"
## Review Result

| Criterion | Score |
|-----------|-------|
| Code Quality | ✅ Pass |
| Performance | ⚠️ Warning |
BODY_EOF

# Deliver GraphQL query via heredoc to avoid ! history expansion
cat <<'QUERY_EOF' > "$queryfile"
mutation($id: ID!, $body: String!) {
  addComment(input: {subjectId: $id, body: $body}) {
    commentEdge { node { id } }
  }
}
QUERY_EOF

# Construct the full GraphQL request payload with jq
jq -n --rawfile body "$tmpfile" --rawfile query "$queryfile" \
  --arg id "$SUBJECT_ID" \
  '{
    query: $query,
    variables: {
      id: $id,
      body: $body
    }
  }' | gh api graphql --input -
```

**Why this works:**
1. `jq --rawfile` reads file content as raw string (handles all escaping)
2. `jq` constructs valid JSON with properly escaped GraphQL variables
3. `--input -` passes the complete payload to gh api without shell interpolation
4. Heredoc (`<<'QUERY_EOF'`) delivers the query text verbatim — no shell interpretation of 「!」

### History Expansion and Special Character Prevention

GraphQL queries containing 「!」 (e.g., 「String!」, 「ID!」) are vulnerable to bash history expansion. Additionally, queries must use ASCII quotes (`"`, U+0022) only.

```bash
# Problem 1: History expansion of !
# Bash interprets ! as history expansion trigger, corrupting String!, ID!, etc.
# → Expected VAR_SIGN, actual: UNKNOWN_CHAR at [line, col]
# PREVENTION: Deliver queries via heredoc (<<'EOF') or file input.
#             Never rely on -f query='...' for queries containing !.

# Problem 2: Smart/curly quotes (less common)
# Unicode smart quotes (" ") are not valid GraphQL syntax.
# PREVENTION: Always type quotes manually; if UNKNOWN_CHAR occurs, check for
#             invisible Unicode characters in the query string.
```

See [gh-cli-error-catalog.md Category 6](./gh-cli-error-catalog.md#category-6-graphql-variable-encoding-error--2-sessions) for root cause analysis.

### Safe `-f` Usage (Simple Values Only)

`-f` is safe for simple, predictable values without special characters:

```bash
# ✅ OK: -f for simple string values (no special characters)
gh api graphql -f query='...' -f owner="B16B1RD" -f repo="cc-rite-workflow"

# ✅ OK: -F for integer values
gh api graphql -f query='...' -F number=123

# 🚫 PROHIBITED: -f for content with Markdown, newlines, or special characters
gh api graphql -f query='...' -f body="## Title\n| col | col |"
```

### Rules Summary

| Variable Content | Safe Method | Prohibited Method |
|-----------------|-------------|-------------------|
| Simple string (owner, repo, field name) | `-f varname="value"` | — |
| Integer | `-F varname=123` | — |
| Markdown content | `jq --rawfile` + `--input -` | `-f body="..."` |
| Multi-line text | `jq --rawfile` + `--input -` | `-f body="..."` |
| Content with special chars (emoji, pipes, brackets) | `jq --rawfile` + `--input -` | `-f body="..."` |

---

## Error Handling

### Error Types and Responses

| HTTP Status | Cause | Action |
|-------------|-------|--------|
| 401 | Authentication error | Guide user to `gh auth login` |
| 403 | Rate limit | Retry after waiting |
| 404 | Resource not found | Guide user to check configuration |
| 5xx | Server error | Retry (max 2 attempts) |

### Fallback Strategy

```bash
# Fallback example when Project operation fails
PROJECT_ID=$(get_project_id "$OWNER" "$PROJECT_NUMBER") || {
  echo "WARNING: Failed to access Project API"
  echo "Issue will be created, but Projects integration will be skipped"
  SKIP_PROJECT=true
}

# Create Issue (without Projects operation)
# Use --body-file pattern for safe body delivery (see gh-cli-patterns.md "Safe Issue/PR Body Updates")
tmpfile=$(mktemp)
trap 'rm -f "$tmpfile"' EXIT
# Note: printf '%s\n' is used here because $BODY is a dynamic variable constructed
# at runtime. For static content, prefer HEREDOC (cat <<'EOF' > "$tmpfile").
# printf '%s\n' is safer than echo for preserving special characters.
printf '%s\n' "$BODY" > "$tmpfile"
if [ ! -s "$tmpfile" ]; then
  echo "ERROR: body is empty" >&2
  exit 1
fi
gh issue create --title "$TITLE" --body-file "$tmpfile"

# Projects operation (skippable)
if [ "$SKIP_PROJECT" != "true" ]; then
  gh project item-add "$PROJECT_NUMBER" --owner "$OWNER" --url "$ISSUE_URL"
fi
```

---

## addSubIssue Helper

GitHub の Sub-issues feature を使って、Issue 間の親子関係を API レベルで設定するためのヘルパーです。本文メタ（`Parent Issue: #N` や `## Sub-Issues` チェックリスト）と並行して、`subIssues` GraphQL relation を一次情報源として登録します。

### When to Use

- `/rite:issue:create-decompose` の bulk create 後に各 Sub-Issue を親に紐付ける
- `/rite:issue:start` Phase 1.5 (parent-routing) の child creation path で新規子 Issue を親に紐付ける
- 既存 Issue の body メタのみで API 未紐付けな状態を後付けで補修する（`backfill-sub-issues.sh`）

### Helper Script: `link-sub-issue.sh`

The helper script `plugins/rite/scripts/link-sub-issue.sh` encapsulates node ID resolution, the `addSubIssue` mutation call, retry-on-5xx, and idempotent handling of already-linked relations.

```bash
# Usage
bash plugins/rite/scripts/link-sub-issue.sh <owner> <repo> <parent_number> <child_number>

# Example
result=$(bash plugins/rite/scripts/link-sub-issue.sh "B16B1RD" "cc-rite-workflow" 514 600)
status=$(printf '%s' "$result" | jq -r '.status')
case "$status" in
  ok|already-linked)
    printf '%s' "$result" | jq -r '.message'
    ;;
  failed)
    printf '%s' "$result" | jq -r '.warnings[]' | while read -r w; do echo "⚠️ $w" >&2; done
    ;;
esac
```

**Output schema** (stdout JSON):

```json
{
  "status": "ok | already-linked | failed",
  "parent": 514,
  "child": 600,
  "message": "linked #600 as sub-issue of #514",
  "warnings": []
}
```

**Exit code policy**: The helper exits `0` for `ok`, `already-linked`, **and** `failed`. Callers MUST inspect the `status` field to determine success. Exit code `1` is reserved exclusively for fatal argument errors (missing/non-numeric arguments, self-reference). All other failure modes — including network errors, permission denials, GraphQL errors, and exhausted retries — are surfaced via `status: failed` with exit `0` and warnings populated in the JSON output. Callers can therefore safely use the helper in pipelines without worrying about non-fatal failures aborting `set -e` scripts.

### Underlying GraphQL

The helper internally executes the following two-step flow:

```graphql
# Step 1: Resolve node IDs
query($owner: String!, $repo: String!, $parent: Int!, $child: Int!) {
  repository(owner: $owner, name: $repo) {
    parent: issue(number: $parent) { id }
    child: issue(number: $child) { id }
  }
}

# Step 2: Establish parent-child relation
mutation($parentId: ID!, $childId: ID!) {
  addSubIssue(input: { issueId: $parentId, subIssueId: $childId }) {
    issue { id number }
    subIssue { id number }
  }
}
```

### Verification Query

After linkage, verify with the following query:

```bash
gh api graphql -f query='
query($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) {
    issue(number: $number) {
      subIssues(first: 50) { nodes { number title state } }
    }
  }
}' -f owner="{owner}" -f repo="{repo}" -F number={parent_number}
```

### Error Handling Matrix

| Condition | Helper Response | Caller Action |
|-----------|-----------------|---------------|
| Linkage succeeds | `status=ok` | Continue normally |
| Already linked (idempotent retry) | `status=already-linked` | Treat as success, continue |
| 5xx server error | Retry up to 3 times (1s -> 2s -> 4s exponential backoff), then `status=failed` | Surface warning, fall back to body meta only, do NOT block |
| 4xx (permission / API not enabled) | `status=failed` immediately | Surface warning, fall back to body meta only, do NOT block |
| Parent or child Issue not found | `status=failed` | Skip linkage for this child only |
| Network failure | Retried as 5xx | Same as 5xx |

### Decision Log: GraphQL vs REST

This helper uses **GraphQL** (`addSubIssue` mutation), not the REST `POST /repos/{owner}/{repo}/issues/{issue_number}/sub_issues` endpoint, for the following reasons:

1. **Consistency**: All other rite workflow Projects/Issue queries use GraphQL via `gh api graphql`. Mixing REST and GraphQL would fragment error handling and authentication paths.
2. **Type safety**: The introspection-verified `AddSubIssueInput` schema — the required field 「issueId: ID!」 and the optional field 「subIssueId: ID」 — provides clearer contract than the REST shape.
3. **Single round-trip after node ID resolution**: GraphQL accepts node IDs directly, matching how the rest of rite workflow already passes node IDs across Project mutations.

REST remains a documented fallback if GraphQL becomes unavailable, but no current code path uses it.

---

## Related Documents

- [gh CLI Patterns](./gh-cli-patterns.md) - Frequently used gh command patterns
  - [Prohibited Patterns (Error Categories 1-7)](./gh-cli-patterns.md#prohibited-patterns-error-categories-1-7) - All prohibited gh CLI patterns
  - [Safe Issue/PR Body Updates](./gh-cli-patterns.md#safe-issuepr-body-updates) - 3-layer defense pattern for body updates
  - [Safe Comment Updates](./gh-cli-patterns.md#safe-comment-updates-gh-api-patch) - jq --rawfile pattern for comment PATCH
- [rite-workflow SKILL.md](../skills/rite-workflow/SKILL.md) - Workflow skill definition
- [reviewers SKILL.md](../skills/reviewers/SKILL.md) - Reviewer skill definition
