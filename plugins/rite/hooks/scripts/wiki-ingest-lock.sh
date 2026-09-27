#!/bin/bash
# rite workflow - Wiki ingest session lock (multi-session design §9)
#
# Serializes the LLM Write/Edit phase of `/rite:wiki-ingest` across sessions.
# An advisory flock cannot guard an ingest that spans many separate Bash tool
# calls (each a new process), so this is a PERSISTENT mkdir lock
# (`<shared-root>/.rite/state/wiki-ingest-session.lockdir`) held for the whole
# ingest and released at the end.
#
# Liveness is not the creating PID (acquire_wm_lock's model): the lock outlives the
# PID that created it and spans minutes. It is the lock's own acquire time, recorded
# as `acquired_at` (UTC ISO8601) next to `session_id` on every acquire (fresh, own
# re-acquire, stale reclaim).
# A lock is LIVE while `acquired_at` is within 7200s (2h). The holder's flow-state
# is NOT consulted: a session may run ingest without an active flow (standalone
# `/rite:wiki-ingest`, or cleanup deactivating its own flow mid-ingest), and the
# lock must still keep other sessions out. A missing / unparsable `acquired_at`
# (including locks written before this field existed) is stale, so a crashed
# holder never pins the lock for good. `parse_iso8601_to_epoch` comes from
# `session-ownership.sh` (single source).
#
# Subcommands:
#   acquire [--session UUID]   acquire (or reclaim a stale lock)
#   release [--session UUID]   release the lock if held by this session
#   check   [--session UUID]   print: free | own | held | stale
#
# Exit codes:
#   0   acquired / reclaimed / released / check printed
#   11  NOT acquired — another LIVE session is ingesting (caller: skip + retry later)
#   1   environment error (including a failed `acquired_at` write, which removes the lockdir)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../state-path-resolve.sh
source "$HOOKS_DIR/state-path-resolve.sh"
# shellcheck source=../session-ownership.sh
source "$HOOKS_DIR/session-ownership.sh"

LOCK_STALE_SECONDS=7200

if [ -n "${RITE_STATE_ROOT:-}" ] && [ -d "$RITE_STATE_ROOT" ]; then
  STATE_ROOT="$RITE_STATE_ROOT"
else
  STATE_ROOT=$(resolve_state_root)
fi
LOCKDIR="$STATE_ROOT/.rite/state/wiki-ingest-session.lockdir"

# Runtime selection is shared with flow-state; ownership keeps strict UUID validation.
# shellcheck source=../session-identity.sh
source "$HOOKS_DIR/session-identity.sh"
_resolve_sid() { resolve_strict_session_id "$STATE_ROOT" "${1:-}"; }

# Is the lock live (holder recorded ∧ acquired_at within 2h)?
_holder_is_live() {
  local holder at epoch now
  holder=$(cat "$LOCKDIR/session_id" 2>/dev/null) || return 1
  [ -n "$holder" ] || return 1
  at=$(cat "$LOCKDIR/acquired_at" 2>/dev/null) || return 1
  epoch=$(parse_iso8601_to_epoch "$at")
  [ "$epoch" -gt 0 ] || return 1
  now=$(date +%s 2>/dev/null) || return 1
  [ $(( now - epoch )) -le "$LOCK_STALE_SECONDS" ]
}

# Record the holder and the acquire time. A lock we cannot stamp would be stale the
# moment it exists, so a failed write removes the lockdir and stops acquire.
_record_holder() {
  local at
  if at=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null) && [ -n "$at" ] \
    && printf '%s' "$1" > "$LOCKDIR/session_id" \
    && printf '%s' "$at" > "$LOCKDIR/acquired_at"; then
    return 0
  fi
  echo "ERROR: wiki-ingest-lock acquire: cannot record session_id / acquired_at in $LOCKDIR" >&2
  rm -rf "$LOCKDIR" 2>/dev/null || true
  return 1
}

cmd_acquire() {
  local sid; sid=$(_resolve_sid "${1:-}") || return 1
  [ -n "$sid" ] || { echo "ERROR: wiki-ingest-lock acquire: cannot resolve session_id" >&2; return 1; }
  mkdir -p "$STATE_ROOT/.rite/state" 2>/dev/null || { echo "ERROR: cannot create .rite/state" >&2; return 1; }
  if mkdir "$LOCKDIR" 2>/dev/null; then
    _record_holder "$sid" || return 1
    echo "acquired"
    return 0
  fi
  # Lock exists. Own it already → re-affirm and refresh acquired_at. Live other → skip.
  # Stale → reclaim.
  local holder; holder=$(cat "$LOCKDIR/session_id" 2>/dev/null || printf '')
  if [ -n "$holder" ] && [ "$holder" = "$sid" ]; then
    _record_holder "$sid" || return 1
    echo "acquired"
    return 0
  fi
  if _holder_is_live; then
    echo "concurrent_ingest"
    return 11
  fi
  # Stale → reclaim (rm + remake keeps the holder record consistent).
  rm -rf "$LOCKDIR" 2>/dev/null || true
  if mkdir "$LOCKDIR" 2>/dev/null; then
    _record_holder "$sid" || return 1
    echo "acquired_stale_reclaimed"
    return 0
  fi
  # Lost a reclaim race to another process — treat as concurrent.
  echo "concurrent_ingest"
  return 11
}

cmd_release() {
  local sid; sid=$(_resolve_sid "${1:-}") || return 1
  [ -n "$sid" ] || { echo "ERROR: wiki-ingest-lock release: cannot resolve session_id" >&2; return 1; }
  [ -d "$LOCKDIR" ] || { echo "released"; return 0; }
  local holder; holder=$(cat "$LOCKDIR/session_id" 2>/dev/null || printf '')
  # Release only our own lock; never remove another session's (a stale-reclaim
  # by a different session must not be clobbered by this one's late release).
  if [ -n "$holder" ] && [ -n "$sid" ] && [ "$holder" != "$sid" ]; then
    echo "[wiki-ingest-lock] release: lock held by another session ($holder); leaving intact" >&2
    echo "skipped"
    return 0
  fi
  rm -rf "$LOCKDIR" 2>/dev/null || { echo "ERROR: failed to remove $LOCKDIR" >&2; return 1; }
  echo "released"
  return 0
}

cmd_check() {
  local sid; sid=$(_resolve_sid "${1:-}") || return 1
  [ -d "$LOCKDIR" ] || { echo "free"; return 0; }
  local holder; holder=$(cat "$LOCKDIR/session_id" 2>/dev/null || printf '')
  if [ -n "$holder" ] && [ -n "$sid" ] && [ "$holder" = "$sid" ]; then echo "own"; return 0; fi
  if _holder_is_live; then echo "held"; else echo "stale"; fi
  return 0
}

sub="${1:-}"; shift || true
sopt=""
while [ $# -gt 0 ]; do case "$1" in
  --session) sopt="$2"; shift 2 ;;
  *) echo "ERROR: unknown option: $1" >&2; exit 1 ;;
esac; done

case "$sub" in
  acquire) cmd_acquire "$sopt" ;;
  release) cmd_release "$sopt" ;;
  check)   cmd_check "$sopt" ;;
  *)
    cat >&2 <<EOF
Usage: $0 {acquire|release|check} [--session UUID]
  acquire  acquire/reclaim the wiki-ingest session lock (rc 11 if held by a live session)
  release  release the lock if held by this session (idempotent)
  check    print: free | own | held | stale
EOF
    exit 1
    ;;
esac
