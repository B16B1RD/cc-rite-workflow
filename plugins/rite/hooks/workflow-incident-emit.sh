#!/bin/bash
# rite workflow - Workflow Incident Sentinel Emitter (#366)
#
# Generates a sentinel pattern that the orchestrator (start.md Phase 5.4.4.1)
# detects via context grep to auto-register workflow incidents as Issues.
#
# Sentinel format:
#   [CONTEXT] WORKFLOW_INCIDENT=1; type=<type>; details=<details>; root_cause_hint=<hint>; iteration_id=<pr>-<epoch>
#
# Usage:
#   bash workflow-incident-emit.sh \
#     --type skill_load_failure \
#     --details "rite:pr:fix Skill loader bash interpretation error" \
#     [--root-cause-hint "fix.md backtick + ! pattern"] \
#     [--pr-number 363]
#
# Options:
#   --type             incident type. Required. One of:
#                        skill_load_failure | hook_abnormal_exit | manual_fallback_adopted
#   --details          one-line incident description (required)
#   --root-cause-hint  optional cause hypothesis (omitted from output if empty)
#   --pr-number        PR number for iteration_id (defaults to 0 when not yet created)
#
# Output:
#   stdout: single sentinel line
#   stderr: nothing on success; error message on validation failure
#
# Exit codes:
#   0  success
#   1  argument validation error (missing --type or --details, invalid type)
#
# Notes:
#   - Output goes to stdout (not stderr) so the line is captured into the
#     orchestrator's conversation context where Phase 5.4.4.1 grep detects it.
#   - This script never calls gh / network. It is purely a string formatter.
#   - Detection itself happens in start.md, which reads the sentinel from
#     conversation context and decides whether to invoke create-issue-with-projects.sh.
set -euo pipefail

TYPE=""
DETAILS=""
ROOT_CAUSE_HINT=""
PR_NUMBER="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --type)            TYPE="$2"; shift 2 ;;
    --details)         DETAILS="$2"; shift 2 ;;
    --root-cause-hint) ROOT_CAUSE_HINT="$2"; shift 2 ;;
    --pr-number)       PR_NUMBER="$2"; shift 2 ;;
    *) echo "ERROR: Unknown option: $1" >&2; exit 1 ;;
  esac
done

# --- Validation ---
if [[ -z "$TYPE" ]]; then
  echo "ERROR: --type is required" >&2
  exit 1
fi

if [[ -z "$DETAILS" ]]; then
  echo "ERROR: --details is required" >&2
  exit 1
fi

case "$TYPE" in
  skill_load_failure|hook_abnormal_exit|manual_fallback_adopted) ;;
  *)
    echo "ERROR: Invalid --type: $TYPE (expected: skill_load_failure | hook_abnormal_exit | manual_fallback_adopted)" >&2
    exit 1
    ;;
esac

if ! [[ "$PR_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "ERROR: --pr-number must be a non-negative integer (got: $PR_NUMBER)" >&2
  exit 1
fi

# --- Sentinel construction ---
# Strip newlines and semicolons from free-text fields so the single-line
# sentinel format stays parseable by Phase 5.4.4.1's grep.
sanitize() {
  printf '%s' "$1" | tr -d '\n\r' | tr ';' ','
}

DETAILS_SANITIZED=$(sanitize "$DETAILS")
HINT_SANITIZED=$(sanitize "$ROOT_CAUSE_HINT")

EPOCH=$(date +%s)
ITERATION_ID="${PR_NUMBER}-${EPOCH}"

if [[ -n "$HINT_SANITIZED" ]]; then
  printf '[CONTEXT] WORKFLOW_INCIDENT=1; type=%s; details=%s; root_cause_hint=%s; iteration_id=%s\n' \
    "$TYPE" "$DETAILS_SANITIZED" "$HINT_SANITIZED" "$ITERATION_ID"
else
  printf '[CONTEXT] WORKFLOW_INCIDENT=1; type=%s; details=%s; iteration_id=%s\n' \
    "$TYPE" "$DETAILS_SANITIZED" "$ITERATION_ID"
fi
