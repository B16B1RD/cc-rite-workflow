#!/bin/bash
# rite workflow - Session Ownership Helper Library
# Common functions for session_id extraction and ownership checks.
# Sourced by hooks that need to verify flow state ownership.
#
# Functions:
#   extract_session_id <hook_json>  - Extract session_id from hook JSON payload
#   get_state_session_id <file>     - Get session_id from .rite-flow-state
#   is_per_session_state_file <path> - Detect per-session file structure (schema 2)
#   check_session_ownership <hook_json> <state_file> - Check if state belongs to current session
#   parse_iso8601_to_epoch <timestamp> - Convert ISO 8601 timestamp to epoch seconds
#
# Usage:
#   source "$SCRIPT_DIR/session-ownership.sh"
#   ownership=$(check_session_ownership "$INPUT" "$STATE_FILE")
#   # ownership: "own" | "legacy" | "other" | "stale"
#
# Role transition: With schema_version=2 (per-session files),
# session ownership is structurally guaranteed by the session_id encoded in
# the filename — the resolver (`flow-state.sh path`) only returns
# a per-session path that matches the current session. `check_session_ownership`
# therefore uses a fast-path "own" classification when the path matches the
# `*/.rite/sessions/*.flow-state` pattern, falling through to the legacy
# 4-state classification only for `<root>/.rite-flow-state` (schema 1).
# `is_per_session_state_file` exposes the same predicate to callers that want
# to short-circuit ownership checks (e.g., when reading a path that has just
# been resolved by `flow-state.sh path`).

# shellcheck source=control-char-neutralize.sh
source "$(dirname "${BASH_SOURCE[0]}")/control-char-neutralize.sh"

# Extract session_id from hook JSON payload
# Args: $1 = hook JSON string (from stdin of the hook)
# Output: session_id string, or empty string if not found
# Consistency: the hook-side payload `.session_id` returned here and
#   the command-side env `CLAUDE_CODE_SESSION_ID` (now flow-state.sh's primary
#   resolution source) both identify the SAME Claude session, so per-session
#   ownership stays coherent across the hook boundary: the per-session state file
#   `{sid}.flow-state` is keyed by env on the command side and matched against this
#   payload sid in the fast-path below. The shared `.rite-session-id` file is no
#   longer the authoritative source, so a stale shared file cannot mis-classify
#   ownership when env is present.
# Note: jq parse failures degrade to empty so ownership check falls through to
#   the backward-compat "own" path. The WARNING is unconditional because
#   ownership classification feeds state-overwrite decisions; suppressing it
#   under RITE_DEBUG would let a corrupt hook payload silently grant ownership.
#   The stderr snippet stays behind RITE_DEBUG to keep the WARNING one line on
#   the hot path.
extract_session_id() {
  local hook_json="$1"
  local sid jq_err
  jq_err=$(mktemp 2>/dev/null) || jq_err=""
  # if/else preserves the real jq rc; the bash `!` operator zeros $? in its
  # then-branch, so capturing rc via `if ! ...; then _rc=$?` would always show 0
  # and hide jq missing / SIGPIPE / parse error from triagers.
  if sid=$(echo "$hook_json" | jq -r '.session_id // empty' 2>"${jq_err:-/dev/null}"); then
    :
  else
    local _jq_rc=$?
    echo "[rite] WARNING: extract_session_id: jq parse failed on hook payload (rc=$_jq_rc, returning empty — ownership check falls back to backward-compat path)" >&2
    [ -n "${RITE_DEBUG:-}" ] && [ -n "$jq_err" ] && [ -s "$jq_err" ] && head -3 "$jq_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
    sid=""
  fi
  [ -n "$jq_err" ] && rm -f "$jq_err"
  echo "$sid"
}

# Get session_id from .rite-flow-state file
# Args: $1 = path to .rite-flow-state
# Output: session_id string, or empty string if not found/file missing
# Note: Surface jq parse failures unconditionally so a corrupt state file
#   doesn't silently fall through to "legacy" classification (which would
#   then allow the current session to overwrite another active session's
#   state). Stderr snippet stays behind RITE_DEBUG to keep the WARNING terse.
get_state_session_id() {
  local state_file="$1"
  local sid jq_err
  if [ ! -f "$state_file" ]; then
    echo ""
    return 0
  fi
  jq_err=$(mktemp 2>/dev/null) || jq_err=""
  if sid=$(jq -r '.session_id // empty' "$state_file" 2>"${jq_err:-/dev/null}"); then
    :
  else
    local _jq_rc=$?
    echo "[rite] WARNING: get_state_session_id: jq parse failed on $state_file (rc=$_jq_rc, returning empty — may classify a corrupt state file as legacy)" >&2
    [ -n "${RITE_DEBUG:-}" ] && [ -n "$jq_err" ] && [ -s "$jq_err" ] && head -3 "$jq_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
    sid=""
  fi
  [ -n "$jq_err" ] && rm -f "$jq_err"
  echo "$sid"
}

# Detect whether a state file path follows the per-session structure (schema 2).
# Args: $1 = state file path
# Returns: 0 (true) if path matches `*/.rite/sessions/*.flow-state`, 1 otherwise.
# Exit code: 0 or 1 (boolean — usable in `if is_per_session_state_file ...`)
#
# Why this exists: With schema_version=2 the resolver
# (`flow-state.sh path`) only returns a per-session path whose session_id
# segment matches the current session, so the file is structurally owned by
# this session and the 4-state legacy classification is unnecessary. Callers
# that already hold a resolver output can use this predicate to short-circuit
# `check_session_ownership` entirely; `check_session_ownership` itself uses
# the same predicate as a fast-path before falling through to the legacy
# logic for the schema-1 `<root>/.rite-flow-state` single-file form.
is_per_session_state_file() {
  local state_file="$1"
  case "$state_file" in
    */.rite/sessions/*.flow-state) return 0 ;;
    *) return 1 ;;
  esac
}

# Check session ownership of .rite-flow-state
# Args: $1 = hook JSON string, $2 = path to .rite-flow-state
# Output: "own" (same session), "legacy" (no session_id in state),
#         "other" (different session, within stale threshold),
#         "stale" (different session, beyond stale threshold)
# Exit code: always 0
#
# Decision matrix:
#   path is per-session file → "own" (structural guarantee, schema 2 fast-path)
#   hook session_id empty    → "own" (backward compat: can't determine, assume own)
#   state session_id empty   → "legacy" (pre-session-ownership state, treat as own)
#   hook == state            → "own"
#   hook != state:
#     updated_at > 2h ago    → "stale" (safe to overwrite)
#     updated_at <= 2h ago   → "other" (active session, do not overwrite)
#
# The per-session fast-path replaces the schema-2 portion of the
# legacy 4-state classification with a structural check. The remaining branches
# preserve schema-1 behavior unchanged so lifecycle hooks and pre-compact
# that depend on "legacy"/"other"/"stale" outputs continue to work.
check_session_ownership() {
  local hook_json="$1"
  local state_file="$2"

  local hook_sid
  hook_sid=$(extract_session_id "$hook_json")

  # Schema-2 fast-path: per-session file structure encodes ownership in the
  # filename. The resolver only returns a per-session path that matches the
  # current session by construction, so the typical caller passing such a
  # path is reading its own state. As defense-in-depth,
  # when the hook payload provides a session_id, verify that the filename's
  # session_id segment matches it. This prevents a future caller bypassing
  # the resolver and silently passing a foreign per-session file from being
  # classified as "own".
  if is_per_session_state_file "$state_file"; then
    if [ -n "$hook_sid" ]; then
      local fname_sid
      fname_sid=$(basename "$state_file" .flow-state)
      if [ "$hook_sid" != "$fname_sid" ]; then
        # Foreign per-session file passed by a non-resolver caller —
        # treat the same as legacy "other" (different session, fresh).
        echo "other"
        return 0
      fi
    fi
    echo "own"
    return 0
  fi

  # If we can't determine our own session_id, assume ownership (backward compat)
  if [ -z "$hook_sid" ]; then
    echo "own"
    return 0
  fi

  local state_sid
  state_sid=$(get_state_session_id "$state_file")

  # No session_id in state = legacy state (pre-session-ownership)
  if [ -z "$state_sid" ]; then
    echo "legacy"
    return 0
  fi

  # Same session
  if [ "$hook_sid" = "$state_sid" ]; then
    echo "own"
    return 0
  fi

  # Different session — check staleness via updated_at. Surface jq parse
  # failure unconditionally because the fallthrough is `treat as stale →
  # overwrite`, which can destroy another active session's state if the
  # corruption is transient. Stderr snippet stays behind RITE_DEBUG.
  local updated_at jq_err
  jq_err=$(mktemp 2>/dev/null) || jq_err=""
  if updated_at=$(jq -r '.updated_at // empty' "$state_file" 2>"${jq_err:-/dev/null}"); then
    :
  else
    local _jq_rc=$?
    echo "[rite] WARNING: check_session_ownership: jq parse failed on $state_file (rc=$_jq_rc, treating as stale — may overwrite another active session)" >&2
    [ -n "${RITE_DEBUG:-}" ] && [ -n "$jq_err" ] && [ -s "$jq_err" ] && head -3 "$jq_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
    updated_at=""
  fi
  [ -n "$jq_err" ] && rm -f "$jq_err"

  if [ -z "$updated_at" ]; then
    echo "stale"
    return 0
  fi

  local state_epoch now_epoch diff_seconds
  state_epoch=$(parse_iso8601_to_epoch "$updated_at")
  now_epoch=$(date +%s)
  diff_seconds=$((now_epoch - state_epoch))

  # Stale threshold: 2 hours (7200 seconds)
  if [ "$diff_seconds" -gt 7200 ]; then
    echo "stale"
  else
    echo "other"
  fi
  return 0
}

# Parse ISO 8601 timestamp to epoch seconds.
# Shared helper: every hook that needs to compare timestamps from the flow
# state must use the same parser to avoid clock-skew false-positives.
# Args: $1 = ISO 8601 timestamp (e.g., "2026-03-16T05:00:00+00:00")
# Output: epoch seconds, or 0 on parse failure
parse_iso8601_to_epoch() {
  local ts="$1"
  local epoch
  # Validate ISO 8601 format before passing to date
  # Supports both +HH:MM/-HH:MM offsets and Z suffix (UTC)
  if ! [[ "$ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(Z|[+-][0-9]{2}:[0-9]{2})$ ]]; then
    echo 0
    return 0
  fi
  # Normalize Z suffix to +00:00 for consistent parsing
  ts="${ts/%Z/+00:00}"
  # Try GNU date -d first (Linux)
  if epoch=$(date -d "$ts" +%s 2>/dev/null); then
    echo "$epoch"
    return 0
  fi
  # Try macOS date -j -f (strip colon from timezone offset: +09:00 -> +0900)
  local ts_nocolon
  ts_nocolon="${ts%:*}${ts##*:}"
  if epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S%z" "$ts_nocolon" +%s 2>/dev/null); then
    echo "$epoch"
    return 0
  fi
  # Fallback: return 0 (will be treated as stale)
  echo 0
}
