#!/bin/bash
# rite workflow - Flow-State Path Resolver (private internal helper)
#
# Resolves the active flow-state file path for lifecycle hooks
# (session-start / session-end / pre-compact / post-compact).
#
# Returns one of:
#   - per-session: <state_root>/.rite/sessions/<session_id>.flow-state
#   - legacy:      <state_root>/.rite-flow-state
#
# Resolution rules (mirrors state-read.sh / flow-state-update.sh semantics):
#   1. schema_version=2 + valid UUID SID + per-session file exists
#      -> per-session path
#   2. schema_version=2 + valid UUID SID + per-session absent + legacy exists
#      -> legacy path (lets the lifecycle hook touch the still-current legacy
#         file before migration completes)
#   3. schema_version=2 + valid UUID SID + neither file exists
#      -> per-session path (for fresh writes; writers create the file)
#   4. schema_version=1 OR missing SID OR invalid UUID
#      -> legacy path
#
# Cross-session ownership checking is the caller's responsibility. This helper
# resolves the path only. Lifecycle hooks already invoke
# `check_session_ownership` (session-ownership.sh) for the "other session"
# branch, so layering another guard here would duplicate that contract.
#
# Why this exists (Issue #680):
#   The lifecycle 4 hooks each used the same hardcoded `<state_root>/.rite-flow-state`
#   path, which forces a global single-file lock and breaks the O(1)-per-session
#   guarantee that schema_version=2 promised. Centralising the resolution here
#   keeps the four hooks consistent (Wiki #586 — state machine 2-place drift)
#   while leaving state-read.sh / flow-state-update.sh untouched (Issue #4/#5
#   handle them).
#
# Usage:
#   STATE_FILE=$(bash plugins/rite/hooks/_resolve-flow-state-path.sh "$STATE_ROOT")
#
# Arguments:
#   $1 state_root  Repository root (typically resolved via state-path-resolve.sh)
#
# Exit codes:
#   0 — success (path printed to stdout)
#   1 — argument error / helper deploy regression
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Helper deploy fail-fast (mirrors state-read.sh / flow-state-update.sh pattern).
# Validate only the helpers actually invoked below to avoid pulling in unrelated
# core helpers (e.g. _resolve-cross-session-guard.sh) that this helper does not use.
bash "$SCRIPT_DIR/_validate-helpers.sh" "$SCRIPT_DIR" \
  _resolve-session-id-from-file.sh \
  _resolve-schema-version.sh \
  _validate-state-root.sh \
  || exit $?

STATE_ROOT="${1:-}"
if [ -z "$STATE_ROOT" ]; then
  echo "ERROR: usage: $0 <state_root>" >&2
  exit 1
fi

# STATE_ROOT path validation (path traversal / shell metacharacters / control
# characters). Symmetric with _resolve-schema-version.sh / _resolve-session-id-from-file.sh.
bash "$SCRIPT_DIR/_validate-state-root.sh" "$STATE_ROOT" || exit $?

LEGACY_FILE="$STATE_ROOT/.rite-flow-state"

SCHEMA_VERSION=$(bash "$SCRIPT_DIR/_resolve-schema-version.sh" "$STATE_ROOT")
SESSION_ID=$(bash "$SCRIPT_DIR/_resolve-session-id-from-file.sh" "$STATE_ROOT")

if [ "$SCHEMA_VERSION" = "2" ] && [ -n "$SESSION_ID" ]; then
  PER_SESSION_FILE="$STATE_ROOT/.rite/sessions/${SESSION_ID}.flow-state"
  if [ -f "$PER_SESSION_FILE" ]; then
    echo "$PER_SESSION_FILE"
    exit 0
  fi
  if [ -f "$LEGACY_FILE" ]; then
    # Legacy still in place (mid-migration window). Use it; the next write
    # via flow-state-update.sh will move the content into the per-session file.
    echo "$LEGACY_FILE"
    exit 0
  fi
  # Neither file exists yet — return the per-session path so writers create
  # the file there directly.
  echo "$PER_SESSION_FILE"
  exit 0
fi

echo "$LEGACY_FILE"
