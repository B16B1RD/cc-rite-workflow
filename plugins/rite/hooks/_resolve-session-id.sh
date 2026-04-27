#!/bin/bash
# rite workflow - Session ID Validation Helper (private internal helper)
#
# Validates session_id against RFC 4122 strict pattern (8-4-4-4-12 hex with
# hyphens at fixed positions). Returns 0 with the validated UUID on stdout
# when input matches; returns 1 with empty stdout when invalid.
#
# Usage:
#   bash plugins/rite/hooks/_resolve-session-id.sh "$candidate_uuid"
#   if validated_sid=$(bash _resolve-session-id.sh "$raw"); then
#     # validated_sid contains the verified UUID
#   else
#     # validation failed; treat as missing/invalid
#   fi
#
# Why this exists (PR #688 cycle 34 fix F-01 CRITICAL):
#   The same UUID regex literal `^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`
#   was duplicated across 5 sites (state-read.sh:85, flow-state-update.sh:70/77/83,
#   resume-active-flag-restore.sh:87). DRY-ifying eliminates the drift risk where
#   a future tightening of the pattern (e.g., RFC 4122 variant bit check) is applied
#   to one site only.
#
# Exit codes:
#   0 — valid UUID (printed to stdout)
#   1 — invalid (empty stdout)
set -euo pipefail

CANDIDATE="${1:-}"

if [[ "$CANDIDATE" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
  printf '%s' "$CANDIDATE"
  exit 0
fi

exit 1
