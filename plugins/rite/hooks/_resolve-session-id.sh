#!/bin/bash
# rite workflow - Session ID Validation Helper (private internal helper)
#
# Validates session_id against RFC 4122 strict pattern (8-4-4-4-12 hex with
# hyphens at fixed positions). Returns 0 with the validated UUID on stdout
# when input matches; returns 1 with empty stdout when invalid.
#
# Contract (SoT: references/session-id-validation-contract.md): this is the Layer 2
# format/identity validator. It answers "is this a canonical UUID?" so a caller can
# choose between the per-session state file and the legacy single-file fallback (see
# _resolve-session-id-from-file.sh). It is intentionally distinct from flow-state.sh's
# Layer 1 `_validate_session_id` (security-boundary, format-agnostic). Do NOT unify the
# two: flow-state.sh's path must keep accepting non-UUID opaque sids.
#
# Usage:
#   bash plugins/rite/hooks/_resolve-session-id.sh "$candidate_uuid"
#   if validated_sid=$(bash _resolve-session-id.sh "$raw"); then
#     # validated_sid contains the verified UUID
#   else
#     # validation failed; treat as missing/invalid
#   fi
#
# Case handling:
#   RFC 4122 §4 mandates that UUID readers MUST be lenient about case ("readers
#   should be liberal in what they accept"; only generators are required to emit
#   lowercase). Accept [A-Fa-f] in the regex and normalize output so downstream
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
