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
# Case handling (verified-review cycle 44 F-10 MEDIUM):
#   RFC 4122 §4 mandates that UUID readers MUST be lenient about case ("readers
#   should be liberal in what they accept"; only generators are required to emit
#   lowercase). The previous lowercase-only pattern would reject uppercase /
#   mixed-case session_ids if Claude Code SDK or upstream Anthropic API ever emit
#   them, breaking AC-4 multi-state API integrity. We now accept [A-Fa-f] in the
#   regex AND normalize the validated output to lowercase so downstream
#   `.rite/sessions/{sid}.flow-state` paths are always lowercase (preventing
#   case-sensitive filesystem from creating two files for "AAA..." vs "aaa...").
#
# Exit codes:
#   0 — valid UUID (lowercase-normalized form printed to stdout)
#   1 — invalid (empty stdout)
set -euo pipefail

CANDIDATE="${1:-}"

if [[ "$CANDIDATE" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
  # Normalize to lowercase for canonical filesystem path (RFC 4122 §4 lenient reader contract).
  printf '%s' "$CANDIDATE" | tr 'A-F' 'a-f'
  exit 0
fi

exit 1
