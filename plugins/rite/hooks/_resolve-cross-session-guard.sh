#!/bin/bash
# rite workflow - Cross-Session Legacy Guard Helper (private internal helper)
#
# Inspects a legacy `.rite-flow-state` file relative to a current session_id
# and classifies the cross-session takeover/fallback decision. Both writer
# (flow-state-update.sh) and reader (state-read.sh) layers share this
# classification so the decision logic can never drift.
#
# Usage:
#   bash plugins/rite/hooks/_resolve-cross-session-guard.sh \
#     <legacy_path> <current_sid>
#
# Outputs (single token to stdout):
#   "same"                  legacy.session_id == current_sid → safe to take over
#   "empty"                 legacy.session_id is null/missing → safe (sessionless legacy)
#   "foreign:<other_sid>"   legacy.session_id != current_sid → refuse take-over
#   "corrupt:<jq_rc>"       legacy file jq parse failed → refuse take-over (cannot verify)
#
# Why this exists (verified-review cycle 34 fix F-02 HIGH):
#   The same `legacy.session_id` extraction + comparison logic was duplicated
#   between writer-side `_resolve_session_state_path` and reader-side state-read.sh
#   per-session resolver. DRY-ifying eliminates the drift risk where a future
#   tightening of the comparison (e.g., variant-bit equivalence, normalization)
#   is applied to one side only — Issue #687 root cause was a writer-side guard
#   that the reader-side did not yet mirror (cycle 32 added writer, cycle 33
#   added reader).
#
# Caller responsibility:
#   The caller decides what to do with each classification:
#   - "same" / "empty" → adopt legacy as the resolved STATE_FILE
#   - "foreign:<sid>" → emit cross_session_takeover_refused via workflow-incident-emit.sh
#                       and route to per-session path (writer) or DEFAULT (reader)
#   - "corrupt:<rc>" → emit legacy_state_corrupt via workflow-incident-emit.sh
#                       and route to per-session path (writer) or DEFAULT (reader)
#
# Exit codes:
#   0 — always (classification printed to stdout)
set -euo pipefail

LEGACY_PATH="${1:-}"
CURRENT_SID="${2:-}"

if [ -z "$LEGACY_PATH" ] || [ -z "$CURRENT_SID" ]; then
  echo "ERROR: usage: $0 <legacy_path> <current_sid>" >&2
  exit 1
fi

if [ ! -f "$LEGACY_PATH" ] || [ ! -s "$LEGACY_PATH" ]; then
  # Caller should not invoke this helper unless the legacy file is non-empty —
  # but defensive: treat empty/missing as "empty" so the caller path doesn't
  # need additional guard logic.
  printf 'empty'
  exit 0
fi

# Capture jq stderr separately so the caller can surface real IO errors.
jq_err=$(mktemp /tmp/rite-cross-session-jq-err-XXXXXX 2>/dev/null) || jq_err=""
trap 'rm -f "${jq_err:-}"' EXIT INT TERM HUP

if legacy_sid=$(jq -r '.session_id // empty' "$LEGACY_PATH" 2>"${jq_err:-/dev/null}"); then
  if [ -z "$legacy_sid" ]; then
    printf 'empty'
  elif [ "$legacy_sid" = "$CURRENT_SID" ]; then
    printf 'same'
  else
    printf 'foreign:%s' "$legacy_sid"
  fi
  exit 0
fi

# jq parse failed — cannot verify session ownership; caller must refuse take-over.
jq_rc=$?
[ -n "$jq_err" ] && [ -s "$jq_err" ] && cat "$jq_err" >&2
printf 'corrupt:%d' "$jq_rc"
exit 0
