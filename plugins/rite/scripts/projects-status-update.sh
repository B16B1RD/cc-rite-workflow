#!/bin/bash
# rite workflow - Projects Status Update
# Common core script for updating a GitHub Issue's Status field in GitHub Projects.
#
# Extracted from (Issue #496 / PR #531):
#   - commands/issue/start.md Phase 2.4 Step 2 (Status -> In Progress;
#     the post-refactor Step 2 consolidates the pre-refactor Step 2-4 triple)
#   - commands/issue/start.md Phase 5.5.1 (Status -> In Review)
#   - commands/issue/start.md Phase 5.7.2 (parent Issue Status -> Done)
#   - references/projects-integration.md §2.4.2-2.4.5
#
# Usage:
#   bash projects-status-update.sh '<json_args>'
#
# Input JSON schema:
#   {
#     "issue_number": 496,
#     "owner": "B16B1RD",
#     "repo": "cc-rite-workflow",
#     "project_number": 6,
#     "status_name": "In Progress",           # required: Todo|In Progress|In Review|Done|...
#     "status_field_id_hint": "PVTSSF_...",   # optional: skip field ID discovery if provided
#     "auto_add": true,                        # default: true — add Issue to Project if missing
#     "non_blocking": true                     # default: true — warnings + exit 0 on API failure
#   }
#
# Output JSON (stdout):
#   {
#     "result": "updated|skipped_not_in_project|failed",
#     "item_id": "PVTI_...",
#     "project_id": "PVT_...",
#     "status_field_id": "PVTSSF_...",
#     "option_id": "...",
#     "warnings": []
#   }
#
# Exit codes:
#   0 = success OR non-blocking failure (caller must inspect .result)
#   1 = fatal (JSON parse error, missing required fields, non_blocking=false API failure)
set -euo pipefail

# --- Centralized tmpfile management ---
TMPDIR_WORK=$(mktemp -d)
trap 'rm -rf "$TMPDIR_WORK"' EXIT
GH_ERR_FILE="$TMPDIR_WORK/gh_err"

# --- Warning accumulation ---
WARNINGS_ARR=()
add_warning() {
  WARNINGS_ARR+=("$1")
}

# --- Helper: output JSON result to stdout ---
output_result() {
  local result="${1:-failed}"
  local item_id="${2:-}"
  local project_id="${3:-}"
  local status_field_id="${4:-}"
  local option_id="${5:-}"
  local warns
  if [ ${#WARNINGS_ARR[@]} -eq 0 ]; then
    warns='[]'
  else
    warns=$(printf '%s\n' "${WARNINGS_ARR[@]}" | jq -R . | jq -s .)
  fi
  jq -n \
    --arg result "$result" \
    --arg item_id "$item_id" \
    --arg project_id "$project_id" \
    --arg status_field_id "$status_field_id" \
    --arg option_id "$option_id" \
    --argjson warns "$warns" \
    '{result: $result, item_id: $item_id, project_id: $project_id, status_field_id: $status_field_id, option_id: $option_id, warnings: $warns}'
}

# --- Argument parsing ---
if [ $# -lt 1 ]; then
  add_warning "No JSON argument provided"
  output_result "failed"
  exit 1
fi

INPUT_JSON="$1"

# Validate JSON parseability before eval'ing extracted fields.
if ! printf '%s\n' "$INPUT_JSON" | jq -e . >/dev/null 2>&1; then
  add_warning "Invalid JSON argument"
  output_result "failed"
  exit 1
fi

# Extract all fields in one jq invocation.
eval "$(printf '%s\n' "$INPUT_JSON" | jq -r '
  @sh "ISSUE_NUMBER=\(.issue_number // 0)",
  @sh "OWNER=\(.owner // "")",
  @sh "REPO=\(.repo // "")",
  @sh "PROJECT_NUMBER=\(.project_number // 0)",
  @sh "STATUS_NAME=\(.status_name // "")",
  @sh "STATUS_FIELD_ID_HINT=\(.status_field_id_hint // "")",
  @sh "AUTO_ADD=\(if .auto_add == false then false else true end)",
  @sh "NON_BLOCKING=\(if .non_blocking == false then false else true end)"
')"

# --- Validation ---
if [ "$ISSUE_NUMBER" -eq 0 ]; then
  add_warning "issue_number is required"
  output_result "failed"
  exit 1
fi
if [ -z "$OWNER" ]; then
  add_warning "owner is required"
  output_result "failed"
  exit 1
fi
if [ -z "$REPO" ]; then
  add_warning "repo is required"
  output_result "failed"
  exit 1
fi
if [ "$PROJECT_NUMBER" -eq 0 ]; then
  add_warning "project_number is required"
  output_result "failed"
  exit 1
fi
if [ -z "$STATUS_NAME" ]; then
  add_warning "status_name is required"
  output_result "failed"
  exit 1
fi

# Helper: emit a terminal failure result and exit.
# NOTE: fail_nb ALWAYS exits — it never returns to the caller. This is intentional:
# all failure paths should emit exactly one JSON result and terminate. Callers rely
# on this behavior (they are not wrapped in `if fail_nb ...; then` guards).
# When NON_BLOCKING=true, exit code is 0 so orchestrators can continue the workflow
# and inspect `.result` in the stdout JSON. When false, exit code is 1 for fail-fast.
fail_nb() {
  local result="$1"
  local item_id="${2:-}"
  local project_id="${3:-}"
  local status_field_id="${4:-}"
  local option_id="${5:-}"
  output_result "$result" "$item_id" "$project_id" "$status_field_id" "$option_id"
  if [ "$NON_BLOCKING" = "true" ]; then
    exit 0
  fi
  exit 1
}

# Helper: read gh stderr file into a warning, handling the empty/missing case.
gh_err_msg() {
  if [ -s "$GH_ERR_FILE" ]; then
    cat "$GH_ERR_FILE"
  else
    printf '(no stderr captured — gh may have exited before writing)'
  fi
}

# --- Step A: Retrieve Issue's project item ID and project GraphQL id ---
query_project_items() {
  gh api graphql -f query='
query($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) {
    issue(number: $number) {
      url
      projectItems(first: 10) {
        nodes {
          id
          project {
            id
            number
          }
        }
      }
    }
  }
}' -f owner="$OWNER" -f repo="$REPO" -F number="$ISSUE_NUMBER" 2>"$GH_ERR_FILE"
}

GQL_RESULT=$(query_project_items) || {
  add_warning "GraphQL projectItems query failed: $(gh_err_msg)"
  fail_nb "failed"
}

# Check that the issue node exists (null means issue not found in repo).
ISSUE_EXISTS=$(printf '%s\n' "$GQL_RESULT" | jq -r '.data.repository.issue // empty')
if [ -z "$ISSUE_EXISTS" ]; then
  add_warning "Issue #$ISSUE_NUMBER not found in $OWNER/$REPO"
  fail_nb "failed"
fi

# Find node whose project.number matches PROJECT_NUMBER.
find_matching_node() {
  printf '%s\n' "$GQL_RESULT" | jq -r --argjson pn "$PROJECT_NUMBER" \
    '[.data.repository.issue.projectItems.nodes[] | select(.project.number == $pn)][0] | if . == null then "" else "\(.id)|\(.project.id)" end'
}

NODE_LINE=$(find_matching_node)

# --- Step B: Auto-add if not registered ---
if [ -z "$NODE_LINE" ]; then
  if [ "$AUTO_ADD" != "true" ]; then
    add_warning "Issue #$ISSUE_NUMBER is not registered in project #$PROJECT_NUMBER (auto_add disabled)"
    fail_nb "skipped_not_in_project"
  fi

  ISSUE_URL=$(printf '%s\n' "$GQL_RESULT" | jq -r '.data.repository.issue.url // empty')
  if [ -z "$ISSUE_URL" ]; then
    add_warning "Could not determine issue URL for auto-add"
    fail_nb "failed"
  fi

  # We discard item-add stdout here because the following re-query is required
  # anyway to obtain project.id (item-add --format json returns only the item id,
  # not the parent project id). See create-issue-with-projects.sh for a variant
  # that captures item-add stdout as a fallback.
  if ! gh project item-add "$PROJECT_NUMBER" --owner "$OWNER" --url "$ISSUE_URL" --format json >/dev/null 2>"$GH_ERR_FILE"; then
    add_warning "gh project item-add failed: $(gh_err_msg)"
    fail_nb "failed"
  fi

  # Re-query to obtain project.id.
  GQL_RESULT=$(query_project_items) || {
    add_warning "GraphQL re-query after auto-add failed: $(gh_err_msg)"
    fail_nb "failed"
  }
  NODE_LINE=$(find_matching_node)
  if [ -z "$NODE_LINE" ]; then
    add_warning "Auto-add succeeded but project item not found in re-query"
    fail_nb "failed"
  fi
fi

ITEM_ID="${NODE_LINE%%|*}"
PROJECT_ID="${NODE_LINE##*|}"
if [ -z "$ITEM_ID" ] || [ -z "$PROJECT_ID" ]; then
  add_warning "Failed to parse item_id / project_id from GraphQL result"
  fail_nb "failed"
fi

# --- Step C: Retrieve Status field + option id ---
# If status_field_id_hint is provided, we still need to fetch options (field_ids
# optimization only skips field ID extraction, not option ID).
FIELD_LIST_JSON=$(gh project field-list "$PROJECT_NUMBER" --owner "$OWNER" --format json 2>"$GH_ERR_FILE") || {
  add_warning "gh project field-list failed: $(gh_err_msg)"
  fail_nb "failed" "$ITEM_ID" "$PROJECT_ID"
}

# `gh project field-list` returns {fields: [...]} — find the Status field.
STATUS_NODE=$(printf '%s\n' "$FIELD_LIST_JSON" | jq -c '[.fields[] | select(.name == "Status")][0] // empty')
if [ -z "$STATUS_NODE" ]; then
  add_warning "Status field not found in project #$PROJECT_NUMBER"
  fail_nb "failed" "$ITEM_ID" "$PROJECT_ID"
fi

if [ -n "$STATUS_FIELD_ID_HINT" ]; then
  STATUS_FIELD_ID="$STATUS_FIELD_ID_HINT"
else
  STATUS_FIELD_ID=$(printf '%s\n' "$STATUS_NODE" | jq -r '.id // empty')
fi
if [ -z "$STATUS_FIELD_ID" ]; then
  add_warning "Could not determine Status field id"
  fail_nb "failed" "$ITEM_ID" "$PROJECT_ID"
fi

OPTION_ID=$(printf '%s\n' "$STATUS_NODE" | jq -r --arg sn "$STATUS_NAME" '[.options[] | select(.name == $sn)][0].id // empty')
if [ -z "$OPTION_ID" ]; then
  add_warning "Status option '$STATUS_NAME' not found in Status field"
  fail_nb "failed" "$ITEM_ID" "$PROJECT_ID" "$STATUS_FIELD_ID"
fi

# --- Step D: Update Status ---
if ! gh project item-edit \
    --project-id "$PROJECT_ID" \
    --id "$ITEM_ID" \
    --field-id "$STATUS_FIELD_ID" \
    --single-select-option-id "$OPTION_ID" >/dev/null 2>"$GH_ERR_FILE"; then
  add_warning "gh project item-edit failed: $(gh_err_msg)"
  fail_nb "failed" "$ITEM_ID" "$PROJECT_ID" "$STATUS_FIELD_ID" "$OPTION_ID"
fi

output_result "updated" "$ITEM_ID" "$PROJECT_ID" "$STATUS_FIELD_ID" "$OPTION_ID"
exit 0
