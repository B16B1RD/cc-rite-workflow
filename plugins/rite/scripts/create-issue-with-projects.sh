#!/bin/bash
# rite workflow - Create Issue with Projects Integration
# Common core script for creating a GitHub Issue and registering it in GitHub Projects.
#
# Usage:
#   bash create-issue-with-projects.sh '<json_args>'
#
# Input JSON schema:
#   {
#     "issue": {
#       "title": "string",
#       "body_file": "string (path to tmpfile with body markdown)",
#       "labels": ["string"],       # optional
#       "assignees": ["string"]      # optional
#     },
#     "projects": {
#       "enabled": true|false,
#       "project_number": 2,
#       "owner": "B16B1RD",
#       "status": "Todo",            # default: "Todo"
#       "priority": "High|Medium|Low",
#       "complexity": "XS|S|M|L|XL",
#       "iteration": {
#         "mode": "none|auto",       # default: "none"
#         "field_name": "Sprint"     # default: "Sprint"
#       }
#     },
#     "options": {
#       "source": "interactive|pr_review|pr_fix|cleanup|lint|parent_routing|xl_decomposition|workflow_incident|fingerprint_split",
#       "non_blocking_projects": true  # default: true
#     }
#   }
#
# Output JSON (stdout):
#   {
#     "issue_url": "https://github.com/.../issues/123",
#     "issue_number": 123,
#     "project_id": "PVT_...",
#     "item_id": "PVTI_...",
#     "project_registration": "skipped|ok|partial|failed",
#     "warnings": ["string"]
#   }
#
# Note: All output (success and error) is written to stdout as JSON.
# The caller captures stdout via result=$(bash ...) and checks the exit code.
# Exit 0 = success or non-blocking failure. Exit 1 = fatal error.
set -euo pipefail

# --- Centralized tmpfile management ---
# All temporary files live under TMPDIR_WORK; a single EXIT trap cleans them all.
TMPDIR_WORK=$(mktemp -d)
trap 'rm -rf "$TMPDIR_WORK"' EXIT
GH_ERR_FILE="$TMPDIR_WORK/gh_err"
FIELD_ERR_FILE="$TMPDIR_WORK/field_err"
# --- Warning accumulation (bash array, single jq conversion at output) ---
WARNINGS_ARR=()
add_warning() {
  WARNINGS_ARR+=("$1")
}

# add_warning_with_stderr (#669): Projects registration failures must NOT be silent.
# Caller contract: only invoke for failures within the Projects registration phase
# (after PROJECTS_ENABLED=true gate at L171). Do NOT use for the enabled=false skip
# path or for informational Iteration-not-configured cases — those use add_warning.
add_warning_with_stderr() {
  WARNINGS_ARR+=("$1")
  printf 'ERROR: Projects registration failed: %s\n' "$1" >&2
}

RETRY_DELAY="${RETRY_DELAY:-1}"
if ! [[ "$RETRY_DELAY" =~ ^[0-9]+$ ]]; then
  add_warning "Invalid RETRY_DELAY value: '${RETRY_DELAY:0:20}'. Using default 1"
  RETRY_DELAY=1
fi

# retry_with_backoff (#669): exponential backoff retry for transient API failures.
# Usage: result=$(retry_with_backoff <max_attempts> <stderr_file> <command...>)
# Sleeps RETRY_DELAY * 2^(n-1) seconds between attempts (1s, 2s, 4s for default delay).
# Set RETRY_DELAY=0 in tests to skip sleep entirely.
# Returns stdout of last attempt; exit code is exit code of last attempt.
retry_with_backoff() {
  local max_attempts="$1"; shift
  local stderr_file="$1"; shift
  local attempt=1
  local rc=0
  local output=""
  while [ "$attempt" -le "$max_attempts" ]; do
    # Capture rc directly from command substitution (avoid `if ... fi` resetting $? to 0).
    output=$("$@" 2>"$stderr_file")
    rc=$?
    if [ "$rc" -eq 0 ]; then
      printf '%s' "$output"
      return 0
    fi
    if [ "$attempt" -lt "$max_attempts" ]; then
      sleep $(( RETRY_DELAY * (1 << (attempt - 1)) ))
    fi
    attempt=$(( attempt + 1 ))
  done
  printf '%s' "$output"
  return "$rc"
}

# --- Helper: output JSON result to stdout ---
output_result() {
  local url="${1:-}"
  local num="${2:-0}"
  local pid="${3:-}"
  local iid="${4:-}"
  local reg="${5:-failed}"
  local warns
  if [ ${#WARNINGS_ARR[@]} -eq 0 ]; then
    warns='[]'
  else
    warns=$(printf '%s\n' "${WARNINGS_ARR[@]}" | jq -R . | jq -s .)
  fi
  jq -n \
    --arg url "$url" \
    --argjson num "$num" \
    --arg pid "$pid" \
    --arg iid "$iid" \
    --arg reg "$reg" \
    --argjson warns "$warns" \
    '{issue_url: $url, issue_number: $num, project_id: $pid, item_id: $iid, project_registration: $reg, warnings: $warns}'
}

# --- Argument parsing ---
if [ $# -lt 1 ]; then
  add_warning "No JSON argument provided"
  output_result "" 0 "" "" "failed"
  exit 1
fi

INPUT_JSON="$1"

# Extract all fields in a single jq invocation (1 subprocess instead of 13)
eval "$(printf '%s\n' "$INPUT_JSON" | jq -r '
  @sh "TITLE=\(.issue.title // "")",
  @sh "BODY_FILE=\(.issue.body_file // "")",
  @sh "LABELS_JSON=\(.issue.labels // [] | @json)",
  @sh "ASSIGNEES_JSON=\(.issue.assignees // [] | @json)",
  @sh "PROJECTS_ENABLED=\(.projects.enabled // false)",
  @sh "PROJECT_NUMBER=\(.projects.project_number // 0)",
  @sh "OWNER=\(.projects.owner // "")",
  @sh "STATUS_VALUE=\(.projects.status // "Todo")",
  @sh "PRIORITY_VALUE=\(.projects.priority // "")",
  @sh "COMPLEXITY_VALUE=\(.projects.complexity // "")",
  @sh "ITERATION_MODE=\(.projects.iteration.mode // "none")",
  @sh "ITERATION_FIELD_NAME=\(.projects.iteration.field_name // "Sprint")",
  @sh "NON_BLOCKING=\(if .options.non_blocking_projects == false then false else true end)"
')"

# --- Validation ---
if [ -z "$TITLE" ]; then
  add_warning "Issue title is required"
  output_result "" 0 "" "" "failed"
  exit 1
fi

if [ -n "$BODY_FILE" ] && [ ! -f "$BODY_FILE" ]; then
  add_warning "Body file not found: $(basename "$BODY_FILE")"
  output_result "" 0 "" "" "failed"
  exit 1
fi

# --- Phase 1: Create Issue ---
GH_ARGS=("issue" "create" "--title" "$TITLE")

if [ -n "$BODY_FILE" ] && [ -s "$BODY_FILE" ]; then
  GH_ARGS+=("--body-file" "$BODY_FILE")
fi

# Add labels (single jq parse per array via mapfile)
mapfile -t LABELS < <(printf '%s\n' "$LABELS_JSON" | jq -r '.[]')
if [ ${#LABELS[@]} -gt 0 ]; then
  for label in "${LABELS[@]}"; do
    GH_ARGS+=("--label" "$label")
  done
fi

# Add assignees (single jq parse per array via mapfile)
mapfile -t ASSIGNEES < <(printf '%s\n' "$ASSIGNEES_JSON" | jq -r '.[]')
if [ ${#ASSIGNEES[@]} -gt 0 ]; then
  for assignee in "${ASSIGNEES[@]}"; do
    GH_ARGS+=("--assignee" "$assignee")
  done
fi

ISSUE_URL=$(gh "${GH_ARGS[@]}" 2>"$GH_ERR_FILE") || {
  gh_err=$(cat "$GH_ERR_FILE")
  add_warning "gh issue create failed: $gh_err"
  output_result "" 0 "" "" "failed"
  exit 1
}

# SIGPIPE 防止 (#398): printf | grep パターンを here-string に置換。
# ISSUE_URL は短い文字列だが、pipefail 下での一貫性のため統一。
ISSUE_NUMBER=$(grep -oE '[0-9]+$' <<< "$ISSUE_URL" || true)

if [ -z "$ISSUE_NUMBER" ]; then
  add_warning "Could not extract issue number from URL"
  output_result "$ISSUE_URL" 0 "" "" "failed"
  exit 1
fi

# --- Phase 2: Projects Integration ---
if [ "$PROJECTS_ENABLED" != "true" ] || [ "$PROJECT_NUMBER" -eq 0 ] || [ -z "$OWNER" ]; then
  output_result "$ISSUE_URL" "$ISSUE_NUMBER" "" "" "skipped"
  exit 0
fi

PROJECT_REG="ok"

# Step 2.1: Add Issue to Project (capture item ID directly via --format json)
# #669: 3-attempt exponential backoff for transient API failures.
ITEM_ADD_RESULT=$(retry_with_backoff 3 "$GH_ERR_FILE" gh project item-add "$PROJECT_NUMBER" --owner "$OWNER" --url "$ISSUE_URL" --format json) || {
  add_warning_with_stderr "gh project item-add failed for Issue #$ISSUE_NUMBER after 3 attempts: $(cat "$GH_ERR_FILE")"
  output_result "$ISSUE_URL" "$ISSUE_NUMBER" "" "" "failed"
  if [ "$NON_BLOCKING" = "true" ]; then
    exit 0
  fi
  exit 1
}

# Extract ITEM_ID directly from item-add response (avoids race condition with GraphQL query)
ITEM_ID=$(printf '%s\n' "$ITEM_ADD_RESULT" | jq -r '.id // empty' 2>/dev/null)

# Step 2.2: Detect owner type (User vs Organization)
OWNER_TYPE=$(gh repo view --json owner --jq '.owner.__typename' 2>"$GH_ERR_FILE" || { add_warning "Owner type detection failed: $(cat "$GH_ERR_FILE")"; printf '%s\n' "User"; })
GQL_ROOT="user"
if [ "$OWNER_TYPE" = "Organization" ]; then
  GQL_ROOT="organization"
fi

# Whitelist validation for GQL_ROOT (defense against GraphQL injection, CWE-943)
if [[ "$GQL_ROOT" != "user" && "$GQL_ROOT" != "organization" ]]; then
  add_warning_with_stderr "Invalid GQL_ROOT value: $GQL_ROOT"
  output_result "$ISSUE_URL" "$ISSUE_NUMBER" "" "" "partial"
  exit 0
fi

# Step 2.3: Retrieve project item ID and field information
# #669: 3-attempt exponential backoff for transient API failures.
GQL_FIELDS_QUERY="
query(\$owner: String!, \$projectNumber: Int!) {
  ${GQL_ROOT}(login: \$owner) {
    projectV2(number: \$projectNumber) {
      id
      items(last: 10) {
        nodes {
          id
          content {
            ... on Issue {
              number
            }
          }
        }
      }
      fields(first: 20) {
        nodes {
          ... on ProjectV2SingleSelectField {
            id
            name
            options {
              id
              name
            }
          }
          ... on ProjectV2IterationField {
            id
            name
            configuration {
              iterations {
                id
                title
                startDate
              }
            }
          }
        }
      }
    }
  }
}"
GQL_RESULT=$(retry_with_backoff 3 "$GH_ERR_FILE" gh api graphql -f query="$GQL_FIELDS_QUERY" -f owner="$OWNER" -F projectNumber="$PROJECT_NUMBER") || {
  add_warning_with_stderr "GraphQL query failed for project field retrieval after 3 attempts: $(cat "$GH_ERR_FILE")"
  output_result "$ISSUE_URL" "$ISSUE_NUMBER" "" "" "partial"
  exit 0
}

# Extract project ID (use --arg for safe variable passing to jq)
PROJECT_ID=$(printf '%s\n' "$GQL_RESULT" | jq -r --arg root "$GQL_ROOT" '.data[$root].projectV2.id // empty')
if [ -z "$PROJECT_ID" ]; then
  add_warning_with_stderr "Could not extract project ID"
  output_result "$ISSUE_URL" "$ISSUE_NUMBER" "" "" "partial"
  exit 0
fi

# Fallback: if ITEM_ID was not captured from item-add (e.g., older gh CLI without --format json),
# try to find it via GraphQL items query
if [ -z "$ITEM_ID" ]; then
  ITEM_ID=$(printf '%s\n' "$GQL_RESULT" | jq -r --arg root "$GQL_ROOT" --argjson num "$ISSUE_NUMBER" '.data[$root].projectV2.items.nodes[] | select(.content.number == $num) | .id // empty')
fi
if [ -z "$ITEM_ID" ]; then
  # Retry with larger window. #669: 3-attempt exponential backoff for transient failures.
  GQL_ITEMS_QUERY="
query(\$owner: String!, \$projectNumber: Int!) {
  ${GQL_ROOT}(login: \$owner) {
    projectV2(number: \$projectNumber) {
      items(last: 20) {
        nodes {
          id
          content {
            ... on Issue {
              number
            }
          }
        }
      }
    }
  }
}"
  GQL_RETRY=$(retry_with_backoff 3 "$GH_ERR_FILE" gh api graphql -f query="$GQL_ITEMS_QUERY" -f owner="$OWNER" -F projectNumber="$PROJECT_NUMBER") || { add_warning_with_stderr "GraphQL items lookup query failed after 3 attempts: $(cat "$GH_ERR_FILE")"; true; }

  ITEM_ID=$(printf '%s\n' "$GQL_RETRY" | jq -r --arg root "$GQL_ROOT" --argjson num "$ISSUE_NUMBER" '.data[$root].projectV2.items.nodes[] | select(.content.number == $num) | .id // empty' 2>"$FIELD_ERR_FILE")
  if [ -z "$ITEM_ID" ]; then
    add_warning_with_stderr "Could not find item ID for Issue #$ISSUE_NUMBER in project"
    output_result "$ISSUE_URL" "$ISSUE_NUMBER" "$PROJECT_ID" "" "partial"
    exit 0
  fi
fi

# Helper: find field ID and option ID from GQL result in a single jq call
find_field_option() {
  local field_name="$1"
  local option_name="$2"

  printf '%s\n' "$GQL_RESULT" | jq -r --arg root "$GQL_ROOT" --arg fn "$field_name" --arg on "$option_name" '
    .data[$root].projectV2.fields.nodes[] | select(.name == $fn) |
    (.id // "") as $fid |
    (if $fid == "" then ""
     else ((.options // [])[] | select(.name == $on) | .id // "") as $oid | "\($fid)|\($oid)"
     end)
  '
}

# Step 2.4: Set fields (reuses centralized FIELD_ERR_FILE)
set_field() {
  local field_name="$1"
  local field_value="$2"

  if [ -z "$field_value" ]; then
    return 0
  fi

  local result
  result=$(find_field_option "$field_name" "$field_value")
  local field_id="${result%%|*}"
  local option_id="${result##*|}"

  if [ -z "$field_id" ] || [ -z "$option_id" ]; then
    add_warning_with_stderr "Field '$field_name' or option '$field_value' not found in project"
    PROJECT_REG="partial"
    return 0
  fi

  # #669: Replace ad-hoc 1-retry loop with retry_with_backoff (3 attempts, exponential backoff).
  if ! retry_with_backoff 3 "$FIELD_ERR_FILE" gh project item-edit --project-id "$PROJECT_ID" --id "$ITEM_ID" --field-id "$field_id" --single-select-option-id "$option_id" >/dev/null; then
    add_warning_with_stderr "Failed to set $field_name=$field_value for Issue #$ISSUE_NUMBER after 3 attempts: $(cat "$FIELD_ERR_FILE")"
    PROJECT_REG="partial"
  fi
}

set_field "Status" "$STATUS_VALUE"
set_field "Priority" "$PRIORITY_VALUE"
set_field "Complexity" "$COMPLEXITY_VALUE"

# Step 2.5: Iteration assignment (optional)
if [ "$ITERATION_MODE" = "auto" ]; then
  ITER_FIELD_ID=$(printf '%s\n' "$GQL_RESULT" | jq -r --arg root "$GQL_ROOT" --arg fn "$ITERATION_FIELD_NAME" '.data[$root].projectV2.fields.nodes[] | select(.name == $fn) | .id // empty')
  if [ -n "$ITER_FIELD_ID" ]; then
    # Find current iteration (startDate <= today, sorted by startDate desc)
    # ISO 8601 date strings (YYYY-MM-DD) are lexicographically comparable
    TODAY=$(date -u +%Y-%m-%d)
    CURRENT_ITER_ID=$(printf '%s\n' "$GQL_RESULT" | jq -r --arg root "$GQL_ROOT" --arg fn "$ITERATION_FIELD_NAME" --arg today "$TODAY" '
      .data[$root].projectV2.fields.nodes[]
      | select(.name == $fn)
      | .configuration.iterations
      | map(select(.startDate <= $today))
      | sort_by(.startDate)
      | last
      | .id // empty
    ')
    if [ -n "$CURRENT_ITER_ID" ]; then
      # #669: 3-attempt exponential backoff for transient API failures.
      ITER_MUTATION='
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
}'
      retry_with_backoff 3 "$GH_ERR_FILE" gh api graphql -f query="$ITER_MUTATION" -f projectId="$PROJECT_ID" -f itemId="$ITEM_ID" -f fieldId="$ITER_FIELD_ID" -f iterationId="$CURRENT_ITER_ID" >/dev/null || {
        add_warning_with_stderr "Iteration assignment failed for Issue #$ISSUE_NUMBER after 3 attempts: $(cat "$GH_ERR_FILE")"
        PROJECT_REG="partial"
      }
    else
      add_warning "No current iteration found for field '$ITERATION_FIELD_NAME'"
    fi
  else
    add_warning "Iteration field '$ITERATION_FIELD_NAME' not found in project"
  fi
fi

# --- Output ---
output_result "$ISSUE_URL" "$ISSUE_NUMBER" "$PROJECT_ID" "$ITEM_ID" "$PROJECT_REG"
