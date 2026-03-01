# gh CLI Error Catalog

Complete catalog of prohibited patterns and error categories observed in Claude Code sessions.

**Consult this file when:**
- Debugging gh CLI command errors (HTTP 422, argument overflow, etc.)
- Understanding why specific patterns are prohibited
- Learning from past error patterns across 83+ sessions

For the safe alternatives to these patterns, see [`gh-cli-patterns.md`](./gh-cli-patterns.md).

---

## Table of Contents

1. [Category 1: `nil is not an object` (HTTP 422)](#category-1-nil-is-not-an-object-http-422--27-sessions)
2. [Category 2: `-f body=` failure (HTTP 422)](#category-2--f-body-failure-http-422--20-sessions)
3. [Category 3: `accepts N arg(s)` argument overflow](#category-3-accepts-n-args-argument-overflow--14-sessions)
4. [Category 4: `body cannot be blank` (HTTP 422)](#category-4-body-cannot-be-blank-http-422--8-sessions)
5. [Category 5: GraphQL PR creation error](#category-5-graphql-pr-creation-error--10-sessions)
6. [Category 6: GraphQL variable encoding error](#category-6-graphql-variable-encoding-error--2-sessions)
7. [Category 7: JSON parse error (HTTP 400)](#category-7-json-parse-error-http-400--2-sessions)

---

## Prohibited Patterns (Error Categories 1-7)

> **This section documents 7 categories of errors observed across 83 Claude Code sessions (cumulative: 27+20+14+8+10+2+2; a single session may trigger multiple categories).** Each pattern is explicitly prohibited. The safe alternatives are provided in [gh-cli-patterns.md](./gh-cli-patterns.md).

### Category 1: `nil is not an object` (HTTP 422) — 27 sessions

**Root cause**: Markdown links (`[text](url)`) and special characters in JSON body break shell escaping when passed through `-f body=` or shell string interpolation.

```bash
# 🚫 PROHIBITED: -f body= with Markdown content containing links, brackets, pipes
gh api repos/{owner}/{repo}/issues/{number}/comments \
  -f body="## Review Result\n\n[Link](https://example.com) | Status: ✅"
# → HTTP 422: nil is not an object
# WHY: gh CLI's -f flag interprets special characters; Markdown links with () and [] break JSON encoding

# 🚫 PROHIBITED: Shell string interpolation for JSON with Markdown
body="## Summary\n[PR](https://github.com/owner/repo/pull/1)"
echo "{\"body\": \"$body\"}" | gh api repos/{owner}/{repo}/issues/comments/{id} -X PATCH --input -
# → HTTP 422: nil is not an object
# WHY: Markdown () and [] are interpreted by shell before reaching gh API, corrupting JSON
```

### Category 2: `-f body=` failure (HTTP 422) — 20 sessions

**Root cause**: `-f body=` interprets values starting with `@` as file references and fails on special characters (pipes, parentheses, emoji, etc.).

```bash
# 🚫 PROHIBITED: -f body= with @ prefix (interpreted as stdin/file reference)
gh api repos/{owner}/{repo}/issues/comments/{id} -X PATCH \
  -f body="@user mentioned this"
# → Attempts to read file "user mentioned this"
# WHY: gh api's -f flag treats values starting with @ as file paths (@- means stdin)

# 🚫 PROHIBITED: -f body= with pipes or parentheses
gh api repos/{owner}/{repo}/issues/comments/{id} -X PATCH \
  -f body="Status | Result\n---|---\nOK | ✅"
# → HTTP 422
# WHY: Pipe characters and emoji in -f value break shell processing before gh receives them

# 🚫 PROHIBITED: -f body= with Japanese text containing special characters
gh api repos/{owner}/{repo}/issues/comments/{id} -X PATCH \
  -f body="## 📜 rite 作業メモリ\n\n- **フェーズ**: 実装作業中"
# → HTTP 422
# WHY: Combination of emoji, CJK characters, and Markdown formatting exceeds -f escaping capability
```

### Category 3: `accepts N arg(s)` argument overflow — 14 sessions

**Root cause**: Shell word splitting on unquoted variables splits JSON content into multiple arguments.

```bash
# 🚫 PROHIBITED: Unquoted variable in echo pipe
body="line 1\nline 2 with spaces"
echo {\"body\": \"$body\"} | gh api ... --input -
# → "accepts 1 arg(s), received 3"
# WHY: Without quotes around the JSON, shell splits on spaces/newlines creating multiple arguments

# 🚫 PROHIBITED: Shell variable expansion without proper quoting in JSON
echo '{"body": "'$body'"}' | gh api ... --input -
# → "accepts 1 arg(s), received N"
# WHY: Single quotes break before $body, shell splits the variable content as separate words
```

### Category 4: `body cannot be blank` (HTTP 422) — 8 sessions

**Root cause**: Shell variable expansion failure produces an empty body.

```bash
# 🚫 PROHIBITED: --body with unvalidated shell variable
gh issue edit {issue_number} --body "$body_var"
# → body cannot be blank (when $body_var is unset or empty)
# WHY: Unset variables expand to empty string; gh CLI sends empty body to API

# 🚫 PROHIBITED: Pipe chain where intermediate command fails silently
gh issue view {issue_number} --json body --jq '.body' | some_transform | gh issue edit {issue_number} --body "$(cat)"
# → body cannot be blank (when some_transform fails)
# WHY: Failed pipe commands produce empty output; $(cat) captures nothing; empty body sent

# 🚫 PROHIBITED: Direct --body with empty string
gh issue edit {issue_number} --body ""
# → body cannot be blank
# WHY: Explicitly empty body is rejected by GitHub API
```

### Category 5: GraphQL PR creation error — 10 sessions

**Root cause**: Attempting to create PR before pushing commits, or when the branch doesn't exist on remote.

```bash
# 🚫 PROHIBITED: Creating PR without verifying commits exist
gh pr create --title "feat: new feature" --body "description" --base develop --draft
# → "No commits between develop and feature-branch"
# WHY: PR requires at least one commit difference between base and head branches

# 🚫 PROHIBITED: Creating PR before pushing branch to remote
git commit -m "feat: add feature"
gh pr create --title "feat: new feature" --body "description" --draft
# → "Could not resolve to a Ref"
# WHY: gh pr create looks for the branch on remote; local-only branch is invisible to GitHub
```

**Required guard pattern**: See [graphql-helpers.md - Combined Guard](./graphql-helpers.md#combined-guard-recommended) for the full pre-PR-creation validation code.

### Category 6: GraphQL variable encoding error — 2 sessions

**Root cause**: Bash's history expansion interprets `!` specially, corrupting GraphQL type annotations like `String!` and `ID!`. Additionally, special characters in `-f` variable values cause encoding errors.

```bash
# 🚫 PROHIBITED: Passing unescaped newlines or special chars in -f variable
gh api graphql -f query='mutation { ... }' -f body="line1\nline2\twith tab"
# → UNKNOWN_CHAR error
# WHY: -f passes raw string; \n and \t are literal characters, not escape sequences, causing GraphQL parse errors

# 🚫 PROHIBITED: Raw Markdown in -f variable for GraphQL
gh api graphql -f query='mutation($body: String!) { ... }' -f body="## Title\n\n- item | detail"
# → UNKNOWN_CHAR error
# WHY: Pipe and Markdown formatting characters interfere with GraphQL variable encoding

# 🚫 HISTORY EXPANSION HAZARD: ! in GraphQL type annotations
# In standard bash, ! is NOT expanded within single quotes ('...').
# However, Claude Code's internal shell processing can handle ! differently,
# causing String!, ID!, Boolean! to be corrupted even inside single quotes.
# → Expected VAR_SIGN, actual: UNKNOWN_CHAR at [line, col]
# WHY: Standard bash only expands ! in double quotes or unquoted contexts
#       (with `set -H` / `histexpand` enabled in interactive shells).
#       Claude Code's shell execution layer does not fully preserve
#       single-quote semantics, causing unexpected ! interpretation.
# PREVENTION: Use heredoc (<<'EOF') to deliver GraphQL queries containing !.
#             This is the most reliable method regardless of shell context.
#             See graphql-helpers.md "Safe GraphQL Variable Encoding" for patterns.
```

### Category 7: JSON parse error (HTTP 400) — 2 sessions

**Root cause**: Shell string manipulation produces malformed JSON.

```bash
# 🚫 PROHIBITED: Shell string concatenation for JSON body
echo "{\"body\": \"$updated_body\"}" | gh api repos/{owner}/{repo}/issues/comments/{id} -X PATCH --input -
# → HTTP 400: Problems parsing JSON
# WHY: If $updated_body contains ", \, newlines, or other JSON-special characters, the resulting JSON is malformed

# 🚫 PROHIBITED: Single-quoted JSON with embedded variables
echo '{"body": "'"$body"'"}' | gh api ... --input -
# → HTTP 400: Problems parsing JSON
# WHY: Shell quote juggling corrupts JSON structure when body contains quotes or special chars
```

---

## Summary: Root Cause → Safe Pattern Mapping

| Category | Root Cause | Safe Pattern |
|----------|-----------|--------------|
| 1-2 | `-f body=` / shell escaping with Markdown | `jq -n --rawfile` + `--input -` |
| 3 | Word splitting on unquoted variables | `jq -n --rawfile` (no shell variables in JSON) |
| 4 | Empty variable expansion | `[ ! -s file ]` validation + `--body-file` |
| 5 | Missing commits / unpushed branch | Pre-creation guard checks |
| 6 | `!` history expansion / special chars in GraphQL variables | `jq -n --rawfile` for string variables; heredoc for queries with `!` |
| 7 | Shell-constructed malformed JSON | `jq` for all JSON construction |

**The universal safe pattern**: Always construct JSON payloads with `jq`, never with shell string operations.

---

## Related Documents

- [gh CLI Patterns Reference](./gh-cli-patterns.md) - Safe patterns for all categories
- [GraphQL Helpers](./graphql-helpers.md) - GraphQL query patterns (including PR Creation Guards)
