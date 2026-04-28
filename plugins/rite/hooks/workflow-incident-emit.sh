#!/bin/bash
# rite workflow - Workflow Incident Sentinel Emitter (#366)
#
# Generates a sentinel pattern that the orchestrator (start.md Phase 5.4.4.1)
# detects via context grep to auto-register workflow incidents as Issues.
#
# Sentinel format (root_cause_hint is optional and entirely omitted when empty):
#   [CONTEXT] WORKFLOW_INCIDENT=1; type=<type>; details=<details>; (root_cause_hint=<hint>; )?iteration_id=<pr>-<epoch>
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
#                        | wiki_ingest_skipped | wiki_ingest_failed | wiki_ingest_push_failed
#                        | gitignore_drift | cross_session_takeover_refused | legacy_state_corrupt
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
#   - Output goes to stdout by default so the line is captured into the
#     orchestrator's conversation context where Phase 5.4.4.1 grep detects it.
#     **Caller-side stderr redirect is permitted** (verified-review cycle 38 F-07 fix):
#     hooks like `_emit-cross-session-incident.sh` route the sentinel via stderr
#     (`bash workflow-incident-emit.sh ... >&2`) when the caller chain prefers
#     stderr separation (e.g., to keep stdout reserved for classification tokens).
#     Both stdout and stderr are captured into the Bash tool result and reach the
#     orchestrator context, so detection works either way. Future callers may
#     redirect freely; this script does not enforce a particular stream choice.
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
  wiki_ingest_skipped|wiki_ingest_failed|wiki_ingest_push_failed) ;;
  gitignore_drift) ;;
  cross_session_takeover_refused|legacy_state_corrupt) ;;
  *)
    echo "ERROR: Invalid --type: $TYPE (expected: skill_load_failure | hook_abnormal_exit | manual_fallback_adopted | wiki_ingest_skipped | wiki_ingest_failed | wiki_ingest_push_failed | gitignore_drift | cross_session_takeover_refused | legacy_state_corrupt)" >&2
    exit 1
    ;;
esac

if ! [[ "$PR_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "ERROR: --pr-number must be a non-negative integer (got: $PR_NUMBER)" >&2
  exit 1
fi

# --- Sentinel construction ---
# Strip control characters and semicolons from free-text fields so the single-line
# sentinel format stays parseable by Phase 5.4.4.1's grep.
#
# `tr -d '[:cntrl:]'` strips all control characters (newline / CR / tab / BEL / DEL etc.)
# to match `_emit-cross-session-incident.sh` fallback path's superset behavior
# (cycle 12 F-07). Earlier `tr -d '\n\r'` only stripped newlines, allowing tab/BEL/DEL
# to pass through and corrupt downstream tooling's grep on the sentinel.
sanitize() {
  printf '%s' "$1" | tr -d '[:cntrl:]' | tr ';' ','
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
