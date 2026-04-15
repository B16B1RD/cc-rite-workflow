#!/bin/bash
# rite workflow - Link Sub-Issue Helper
# Establishes a parent-child relationship between two GitHub Issues
# using the Sub-issues API (GraphQL `addSubIssue` mutation).
#
# Usage:
#   bash link-sub-issue.sh <owner> <repo> <parent_number> <child_number>
#
# Output JSON (stdout):
#   {
#     "status": "ok|already-linked|failed",
#     "parent": 123,
#     "child": 456,
#     "message": "human-readable message",
#     "warnings": ["..."]
#   }
#
# Exit codes:
#   0 = success, already-linked, or non-blocking failure (caller must inspect status)
#   1 = invalid arguments (fatal)
#
# Idempotency:
#   The GraphQL mutation returns an error containing "already" or
#   "sub-issue" when the relation already exists; this is mapped to
#   status="already-linked" with exit 0.
#
# Retry policy:
#   5xx responses are retried up to 3 times with exponential backoff
#   (1s -> 2s -> 4s). 4xx responses (except idempotent cases) are
#   surfaced immediately as status="failed".
set -euo pipefail

# --- Centralized tmpfile management ---
TMPDIR_WORK=$(mktemp -d)
trap 'rm -rf "$TMPDIR_WORK"' EXIT
GH_ERR_FILE="$TMPDIR_WORK/gh_err"
GH_OUT_FILE="$TMPDIR_WORK/gh_out"

# --- Warning accumulation ---
WARNINGS_ARR=()
add_warning() {
  WARNINGS_ARR+=("$1")
}

# --- Output JSON to stdout ---
output_result() {
  local status="${1:-failed}"
  local parent="${2:-0}"
  local child="${3:-0}"
  local message="${4:-}"
  local warns
  if [ ${#WARNINGS_ARR[@]} -eq 0 ]; then
    warns='[]'
  else
    warns=$(printf '%s\n' "${WARNINGS_ARR[@]}" | jq -R . | jq -s .)
  fi
  jq -n \
    --arg status "$status" \
    --argjson parent "$parent" \
    --argjson child "$child" \
    --arg message "$message" \
    --argjson warns "$warns" \
    '{status: $status, parent: $parent, child: $child, message: $message, warnings: $warns}'
}

# --- Argument parsing ---
if [ $# -lt 4 ]; then
  add_warning "Usage: link-sub-issue.sh <owner> <repo> <parent_number> <child_number>"
  output_result "failed" 0 0 "missing arguments"
  exit 1
fi

OWNER="$1"
REPO="$2"
PARENT_NUMBER="$3"
CHILD_NUMBER="$4"

if ! [[ "$PARENT_NUMBER" =~ ^[0-9]+$ ]] || ! [[ "$CHILD_NUMBER" =~ ^[0-9]+$ ]]; then
  add_warning "parent_number and child_number must be positive integers"
  output_result "failed" 0 0 "invalid issue numbers"
  exit 1
fi

if [ "$PARENT_NUMBER" = "$CHILD_NUMBER" ]; then
  add_warning "parent and child must differ (#$PARENT_NUMBER == #$CHILD_NUMBER)"
  output_result "failed" "$PARENT_NUMBER" "$CHILD_NUMBER" "self-reference"
  exit 1
fi

# --- Step 1: Resolve node IDs for parent and child ---
NODE_QUERY='
query($owner: String!, $repo: String!, $parent: Int!, $child: Int!) {
  repository(owner: $owner, name: $repo) {
    parent: issue(number: $parent) { id }
    child: issue(number: $child) { id }
  }
}'

if ! gh api graphql \
  -f query="$NODE_QUERY" \
  -f owner="$OWNER" \
  -f repo="$REPO" \
  -F parent="$PARENT_NUMBER" \
  -F child="$CHILD_NUMBER" \
  > "$GH_OUT_FILE" 2>"$GH_ERR_FILE"; then
  err=$(cat "$GH_ERR_FILE")
  err_lc=$(printf '%s' "$err" | tr '[:upper:]' '[:lower:]')
  # Distinguish permission/auth failures from generic resolution errors
  # so operators can disambiguate "token scope" vs "wrong issue number".
  case "$err_lc" in
    *"unauthorized"*|*"forbidden"*|*"http 401"*|*"http 403"*|*"requires authentication"*|*"resource not accessible"*)
      add_warning "Permission denied resolving issue node IDs (check 'gh auth status' / token scopes): ${err:0:200}"
      output_result "failed" "$PARENT_NUMBER" "$CHILD_NUMBER" "node id resolution failed (permission denied)"
      ;;
    *)
      add_warning "Failed to resolve issue node IDs: ${err:0:200}"
      output_result "failed" "$PARENT_NUMBER" "$CHILD_NUMBER" "node id resolution failed"
      ;;
  esac
  exit 0
fi

PARENT_ID=$(jq -r '.data.repository.parent.id // empty' "$GH_OUT_FILE")
CHILD_ID=$(jq -r '.data.repository.child.id // empty' "$GH_OUT_FILE")

# Surface GraphQL-level errors from a successful HTTP response (e.g. partial
# data + errors[]), to disambiguate "not found" from "permission denied".
NODE_ERRORS=$(jq -r '.errors // [] | map(.type + ": " + .message) | join("; ")' "$GH_OUT_FILE" 2>/dev/null || echo "")

if [ -z "$PARENT_ID" ]; then
  case "$(printf '%s' "$NODE_ERRORS" | tr '[:upper:]' '[:lower:]')" in
    *"forbidden"*|*"unauthorized"*)
      add_warning "Parent Issue #$PARENT_NUMBER inaccessible (permission denied): $NODE_ERRORS"
      output_result "failed" "$PARENT_NUMBER" "$CHILD_NUMBER" "parent inaccessible (permission denied)"
      ;;
    *)
      add_warning "Parent Issue #$PARENT_NUMBER not found${NODE_ERRORS:+ ($NODE_ERRORS)}"
      output_result "failed" "$PARENT_NUMBER" "$CHILD_NUMBER" "parent not found"
      ;;
  esac
  exit 0
fi
if [ -z "$CHILD_ID" ]; then
  case "$(printf '%s' "$NODE_ERRORS" | tr '[:upper:]' '[:lower:]')" in
    *"forbidden"*|*"unauthorized"*)
      add_warning "Child Issue #$CHILD_NUMBER inaccessible (permission denied): $NODE_ERRORS"
      output_result "failed" "$PARENT_NUMBER" "$CHILD_NUMBER" "child inaccessible (permission denied)"
      ;;
    *)
      add_warning "Child Issue #$CHILD_NUMBER not found${NODE_ERRORS:+ ($NODE_ERRORS)}"
      output_result "failed" "$PARENT_NUMBER" "$CHILD_NUMBER" "child not found"
      ;;
  esac
  exit 0
fi

# --- Step 2: Call addSubIssue mutation with retry ---
LINK_MUTATION='
mutation($parentId: ID!, $childId: ID!) {
  addSubIssue(input: { issueId: $parentId, subIssueId: $childId }) {
    issue { id number }
    subIssue { id number }
  }
}'

is_idempotent_error() {
  # GitHub returns errors like "Sub-issue already exists" or
  # "issue is already a sub-issue" when the relation already exists.
  local err_lc
  err_lc=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "$err_lc" in
    *"already"*"sub"*) return 0 ;;
    *"sub"*"already"*) return 0 ;;
    *"already exists"*) return 0 ;;
  esac
  return 1
}

is_retryable_error() {
  # Transient failures that justify retry. Two classes:
  #
  # 1. Transport-layer failures (only appear via HTTP/network error strings,
  #    i.e. the gh CLI failure branch — `gh api graphql` exits non-zero):
  #      - HTTP 5xx: any "HTTP 5XX" where XX is two digits (covers 500-599)
  #      - Timeouts: connection timeouts, request deadlines
  #      - Connection-level: reset / refused / unreachable network
  #      - DNS: temporary failure in name resolution
  #
  # 2. GraphQL application-layer transient errors (appear in HTTP 200
  #    responses with `errors[]` populated, i.e. the success branch):
  #      - Rate limit / secondary rate limit (GitHub abuse detection)
  #      - "was submitted too quickly" (rate-limit phrasing variant)
  #      - "server error" / "internal error" surfaced as a GraphQL message
  #
  # Without class 2, the retry loop in the success branch (L220-227) would
  # be effectively dead code — application-layer failures like "validation
  # failed" or "sub-issue limit exceeded" are NOT retryable and break out
  # immediately, which is correct.
  local err_lc
  err_lc=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "$err_lc" in
    *"http 5"[0-9][0-9]*) return 0 ;;
    *"timeout"*|*"timed out"*) return 0 ;;
    *"connection reset"*|*"connection refused"*) return 0 ;;
    *"network is unreachable"*|*"no route to host"*) return 0 ;;
    *"temporary failure in name resolution"*) return 0 ;;
    *"rate limit"*|*"secondary rate limit"*) return 0 ;;
    *"submitted too quickly"*) return 0 ;;
    *"server error"*|*"internal error"*) return 0 ;;
  esac
  return 1
}

MAX_RETRIES=3
delay=1
attempt=0
final_err=""

while [ "$attempt" -lt "$MAX_RETRIES" ]; do
  attempt=$((attempt + 1))
  if gh api graphql \
    -f query="$LINK_MUTATION" \
    -f parentId="$PARENT_ID" \
    -f childId="$CHILD_ID" \
    > "$GH_OUT_FILE" 2>"$GH_ERR_FILE"; then
    # Check for GraphQL-level errors in the response body.
    # `jq -r 'map(.message) | join(...)'` always yields a plain string
    # (empty when errors[] is absent), so a non-empty check is sufficient —
    # no separate "null" comparison needed.
    gql_errors=$(jq -r '.errors // [] | map(.message) | join("; ")' "$GH_OUT_FILE" 2>/dev/null || echo "")
    if [ -n "$gql_errors" ]; then
      if is_idempotent_error "$gql_errors"; then
        output_result "already-linked" "$PARENT_NUMBER" "$CHILD_NUMBER" "linked #$CHILD_NUMBER as sub-issue of #$PARENT_NUMBER (already linked)"
        exit 0
      fi
      final_err="$gql_errors"
      if is_retryable_error "$final_err" && [ "$attempt" -lt "$MAX_RETRIES" ]; then
        add_warning "addSubIssue retry $attempt/$MAX_RETRIES after error: ${final_err:0:120}"
        sleep "$delay"
        delay=$((delay * 2))
        continue
      fi
      break
    fi
    # Success
    output_result "ok" "$PARENT_NUMBER" "$CHILD_NUMBER" "linked #$CHILD_NUMBER as sub-issue of #$PARENT_NUMBER"
    exit 0
  fi
  final_err=$(cat "$GH_ERR_FILE")
  if is_idempotent_error "$final_err"; then
    output_result "already-linked" "$PARENT_NUMBER" "$CHILD_NUMBER" "linked #$CHILD_NUMBER as sub-issue of #$PARENT_NUMBER (already linked)"
    exit 0
  fi
  if is_retryable_error "$final_err" && [ "$attempt" -lt "$MAX_RETRIES" ]; then
    add_warning "addSubIssue retry $attempt/$MAX_RETRIES after error: ${final_err:0:120}"
    sleep "$delay"
    delay=$((delay * 2))
    continue
  fi
  break
done

add_warning "addSubIssue failed after $attempt attempt(s): ${final_err:0:200}"
output_result "failed" "$PARENT_NUMBER" "$CHILD_NUMBER" "Sub-issues API linkage failed: #$CHILD_NUMBER -> #$PARENT_NUMBER"
exit 0
