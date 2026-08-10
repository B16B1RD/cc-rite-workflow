#!/bin/bash
# rite workflow - Wiki ingest session lock (multi-session design §9)
#
# Serializes the LLM Write/Edit phase of `/rite:wiki-ingest` across sessions.
# An advisory flock cannot guard an ingest that spans many separate Bash tool
# calls (each a new process), so this is a PERSISTENT mkdir lock
# (`<shared-root>/.rite/state/wiki-ingest-session.lockdir`) held for the whole
# ingest and released at the end.
#
# Staleness reuses the §7 claim-liveness predicate (NOT acquire_wm_lock's PID /
# 120s model, which is wrong here: the lock outlives the PID that created it and
# spans minutes). A lock is LIVE only when its holder session's per-session
# flow-state has `active=true` AND `updated_at` within 7200s (2h). The threshold
# + `parse_iso8601_to_epoch` come from `session-ownership.sh` (single source).
#
# Subcommands:
#   acquire [--session UUID]   acquire (or reclaim a stale lock)
#   release [--session UUID]   release the lock if held by this session
#   check   [--session UUID]   print: free | own | held | stale
#
# Exit codes:
#   0   acquired / reclaimed / released / check printed
#   11  NOT acquired — another LIVE session is ingesting (caller: skip + retry later)
#   1   environment error
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

# Priority: override → env CLAUDE_CODE_SESSION_ID → env CLAUDE_SESSION_ID
# → `.rite-session-id` file (env-absent fallback). env-first keeps this lock helper's
# session identity coherent with flow-state.sh; a stale shared file must not key the
# lock to a foreign session. The file remains the env-absent fallback.
_resolve_sid() {
  local override="${1:-}" sid=""
  if [ -n "$override" ]; then
    bash "$HOOKS_DIR/_resolve-session-id.sh" "$override" 2>/dev/null || true
    return 0
  fi
  local cand
  for cand in "${CLAUDE_CODE_SESSION_ID:-}" "${CLAUDE_SESSION_ID:-}"; do
    [ -n "$cand" ] || continue
    sid=$(bash "$HOOKS_DIR/_resolve-session-id.sh" "$cand" 2>/dev/null) || sid=""
    [ -n "$sid" ] && break
  done
  if [ -z "$sid" ]; then
    sid=$(bash "$HOOKS_DIR/_resolve-session-id-from-file.sh" "$STATE_ROOT" 2>/dev/null) || sid=""
  fi
  printf '%s' "$sid"
}

# Is the lock holder's session live (active=true ∧ updated_at within 2h)?
_holder_is_live() {
  local holder; holder=$(cat "$LOCKDIR/session_id" 2>/dev/null) || return 1
  [ -n "$holder" ] || return 1
  local active updated epoch
  active=$(RITE_STATE_ROOT="$STATE_ROOT" bash "$HOOKS_DIR/flow-state.sh" \
            get --session "$holder" --field active --default false 2>/dev/null) || active=false
  [ "$active" = "true" ] || return 1
  updated=$(RITE_STATE_ROOT="$STATE_ROOT" bash "$HOOKS_DIR/flow-state.sh" \
            get --session "$holder" --field updated_at --default "" 2>/dev/null) || updated=""
  [ -n "$updated" ] || return 1
  epoch=$(parse_iso8601_to_epoch "$updated")
  [ "$epoch" -gt 0 ] || return 1
  [ $(( $(date +%s) - epoch )) -le "$LOCK_STALE_SECONDS" ]
}

_record_holder() { printf '%s' "$1" > "$LOCKDIR/session_id"; }

cmd_acquire() {
  local sid; sid=$(_resolve_sid "${1:-}")
  [ -n "$sid" ] || { echo "ERROR: wiki-ingest-lock acquire: cannot resolve session_id" >&2; return 1; }
  mkdir -p "$STATE_ROOT/.rite/state" 2>/dev/null || { echo "ERROR: cannot create .rite/state" >&2; return 1; }
  if mkdir "$LOCKDIR" 2>/dev/null; then
    _record_holder "$sid"
    echo "acquired"
    return 0
  fi
  # Lock exists. Own it already → re-affirm. Live other → skip. Stale → reclaim.
  local holder; holder=$(cat "$LOCKDIR/session_id" 2>/dev/null || printf '')
  if [ -n "$holder" ] && [ "$holder" = "$sid" ]; then
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
    _record_holder "$sid"
    echo "acquired_stale_reclaimed"
    return 0
  fi
  # Lost a reclaim race to another process — treat as concurrent.
  echo "concurrent_ingest"
  return 11
}

cmd_release() {
  local sid; sid=$(_resolve_sid "${1:-}")
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
  local sid; sid=$(_resolve_sid "${1:-}")
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
