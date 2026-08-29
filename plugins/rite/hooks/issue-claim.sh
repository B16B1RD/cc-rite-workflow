#!/bin/bash
# rite workflow - Issue Claim mechanism (multi-session design §7)
#
# Prevents two sessions from starting work on the SAME Issue concurrently
# ("double-commit"). Always active regardless of `multi_session.enabled`
# (Decision D-3): multiple sessions in one checkout are already supported via
# per-session flow-state, so the double-commit risk exists independent of the
# worktree feature. Silent when there is no conflict → backward-compatible.
#
# Subcommands:
#   claim   --issue N [--worktree PATH] [--session UUID]   acquire the claim
#   release --issue N [--session UUID]                      release own claim
#   check   --issue N [--session UUID]                      classify: own|free|other|stale
#
# Data contract (`<shared-root>/.rite/state/issue-claims/issue-{N}.json`):
#   {"schema_version":1,"issue_number":N,"session_id":"...","worktree":"<abs|''>","claimed_at":"ISO8601Z"}
#   Claims live under `.rite/state/`, which the nested `.rite/.gitignore` (`*` plus
#   wiki negations, written by gitignore-ensure.sh from session-start.sh /
#   flow-state.sh / work-memory-update.sh / `/rite:setup`) keeps untracked. No root
#   `.gitignore` entry is added for them — the exclusion travels with the directory
#   rather than with the host repository's configuration.
#
# Liveness (NO new heartbeat — reuses flow-state `updated_at`): a claim is LIVE
# when the holder's per-session flow-state has `active=true` AND `updated_at`
# within 7200s (2h). The 2h threshold + `parse_iso8601_to_epoch` are sourced
# from `session-ownership.sh` (single source of truth). `flow-state.sh set`
# refreshes `updated_at` on every phase transition, so that IS the heartbeat.
#
# Atomicity: a FREE issue is claimed via `noclobber` (`set -C`) file creation —
# only one of N racing processes wins the create. The stale-steal, own-refresh,
# and release paths serialize through an atomic mkdir lock, which is available on
# stock macOS and other POSIX systems without util-linux. A LIVE other-session claim is NEVER stolen
# unattended (AC-5) — `claim` returns rc=10 so the caller (open Step 1.6)
# raises an AskUserQuestion.
#
# KNOWN LIMITATION: an `implement` phase that runs >2h without any phase
# transition can be misclassified as stale (its flow-state `updated_at` ages
# out). The claim's stale-steal only overwrites the lock record; the physical
# session worktree is only auto-removed by the §8 reap, and only when clean.
#
# Exit codes:
#   0   success (claim acquired / refreshed / released / check printed)
#   1   usage / argument / environment error (cannot resolve session_id, etc.)
#   10  claim refused — another LIVE session holds the claim (caller: AskUserQuestion)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=state-path-resolve.sh
source "$SCRIPT_DIR/state-path-resolve.sh"
# shellcheck source=control-char-neutralize.sh
source "$SCRIPT_DIR/control-char-neutralize.sh"
# session-ownership.sh: parse_iso8601_to_epoch + 2h threshold
# shellcheck source=session-ownership.sh
source "$SCRIPT_DIR/session-ownership.sh"

export GIT_TERMINAL_PROMPT=0

# Stale threshold (seconds). Mirrors session-ownership.sh check_session_ownership
# (2h). Kept as a named constant so the parity with that file is explicit.
CLAIM_STALE_SECONDS=7200

# Shared state root (main checkout under multi-session — state-path-resolve.sh is
# worktree-aware). Callers may pre-resolve and pass RITE_STATE_ROOT.
if [ -n "${RITE_STATE_ROOT:-}" ] && [ -d "$RITE_STATE_ROOT" ]; then
  STATE_ROOT="$RITE_STATE_ROOT"
else
  STATE_ROOT=$(resolve_state_root)
fi
CLAIMS_DIR="$STATE_ROOT/.rite/state/issue-claims"
CLAIMS_LOCKDIR="$CLAIMS_DIR/.lock.d"
CLAIMS_LOCK_RETRIES=50

# Resolve the CURRENT session_id. Reuses the canonical helpers:
#   - `_resolve-session-id.sh` UUID-validates a runtime env candidate
#   - `_resolve-session-id-from-file.sh` reads + UUID-validates `.rite-session-id`
# Priority: override → env CLAUDE_CODE_SESSION_ID → env
# CLAUDE_SESSION_ID → `.rite-session-id` file (env-absent fallback). The per-session
# env var must outrank the shared file so this helper stays coherent with
# flow-state.sh (also env-first). Preferring the shared file let a stale value
# resolve a foreign session — claim ownership / _holder_is_live then keyed off the
# wrong sid, and the worktree reap that calls `issue-claim.sh check` could
# mis-protect / mis-reap an in-use tree.
# Returns empty when no valid session_id can be resolved (caller decides).
_resolve_current_session_id() {
  local override="${1:-}" sid=""
  if [ -n "$override" ]; then
    sid=$(bash "$SCRIPT_DIR/_resolve-session-id.sh" "$override" 2>/dev/null) || sid=""
    printf '%s' "$sid"
    return 0
  fi
  local cand
  for cand in "${CLAUDE_CODE_SESSION_ID:-}" "${CLAUDE_SESSION_ID:-}"; do
    [ -n "$cand" ] || continue
    sid=$(bash "$SCRIPT_DIR/_resolve-session-id.sh" "$cand" 2>/dev/null) || sid=""
    [ -n "$sid" ] && break
  done
  if [ -z "$sid" ]; then
    sid=$(bash "$SCRIPT_DIR/_resolve-session-id-from-file.sh" "$STATE_ROOT" 2>/dev/null) || sid=""
  fi
  printf '%s' "$sid"
}

# Is the holding session live? claim is LIVE when the holder's flow-state has
# active=true AND updated_at within CLAIM_STALE_SECONDS. Reads the holder's
# per-session state via flow-state.sh (passing the shared STATE_ROOT). rc 0=live.
_holder_is_live() {
  local holder="$1"
  [ -n "$holder" ] || return 1
  local active updated epoch now
  active=$(RITE_STATE_ROOT="$STATE_ROOT" bash "$SCRIPT_DIR/flow-state.sh" \
            get --session "$holder" --field active --default "false" 2>/dev/null) || active="false"
  [ "$active" = "true" ] || return 1
  updated=$(RITE_STATE_ROOT="$STATE_ROOT" bash "$SCRIPT_DIR/flow-state.sh" \
            get --session "$holder" --field updated_at --default "" 2>/dev/null) || updated=""
  [ -n "$updated" ] || return 1
  epoch=$(parse_iso8601_to_epoch "$updated")
  [ "$epoch" -gt 0 ] || return 1
  now=$(date +%s)
  [ $((now - epoch)) -le "$CLAIM_STALE_SECONDS" ]
}

# Read the holder session_id from a claim file ('' on missing/corrupt).
_claim_holder() {
  local file="$1"
  [ -f "$file" ] || { printf ''; return 0; }
  jq -r '.session_id // ""' "$file" 2>/dev/null || printf ''
}

# Classify a claim: own | free | other | stale. $1=claim file, $2=current sid.
_classify() {
  local file="$1" current="$2" holder
  [ -f "$file" ] || { printf 'free'; return 0; }
  holder=$(_claim_holder "$file")
  # Empty/corrupt holder → reclaimable (treat as stale).
  [ -n "$holder" ] || { printf 'stale'; return 0; }
  if [ -n "$current" ] && [ "$holder" = "$current" ]; then printf 'own'; return 0; fi
  if _holder_is_live "$holder"; then printf 'other'; else printf 'stale'; fi
}

# Build the claim JSON for the current session.
_build_json() {
  local issue="$1" sid="$2" worktree="$3" now
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  jq -nc --argjson sv 1 --argjson issue "$issue" --arg sid "$sid" \
         --arg wt "$worktree" --arg ts "$now" \
    '{schema_version:$sv, issue_number:$issue, session_id:$sid, worktree:$wt, claimed_at:$ts}'
}

# Acquire the short-lived claims critical section with portable atomic mkdir.
# A process killed after mkdir can leave residue; after the normal wait window,
# a contender reclaims it only when its recorded process is gone or its PID has
# been reused by a process with a different start identity.
_process_identity() {
  local pid="$1"
  ps -p "$pid" -o lstart= 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

_claims_lock_record_owner() {
  local identity
  identity=$(_process_identity "$$")
  [ -n "$identity" ] || return 1
  printf '%s\n' "$$" > "$CLAIMS_LOCKDIR/pid" &&
    printf '%s\n' "$identity" > "$CLAIMS_LOCKDIR/process_start"
}

_claims_lock_acquire() {
  local tries=0 owner="" tomb=""
  while [ "$tries" -lt "$CLAIMS_LOCK_RETRIES" ]; do
    if mkdir "$CLAIMS_LOCKDIR" 2>/dev/null; then
      _claims_lock_record_owner || {
        rm -rf "$CLAIMS_LOCKDIR" 2>/dev/null || true
        return 1
      }
      return 0
    fi
    tries=$((tries + 1))
    sleep 0.1
  done

  local recorded_identity="" current_identity="" reclaim=false
  owner=$(cat "$CLAIMS_LOCKDIR/pid" 2>/dev/null || printf '')
  recorded_identity=$(cat "$CLAIMS_LOCKDIR/process_start" 2>/dev/null || printf '')
  case "$owner" in
    ''|0|*[!0-9]*) reclaim=true ;;
    *)
      if ! kill -0 "$owner" 2>/dev/null; then
        reclaim=true
      else
        current_identity=$(_process_identity "$owner")
        [ -n "$recorded_identity" ] && [ -n "$current_identity" ] &&
          [ "$recorded_identity" != "$current_identity" ] && reclaim=true
      fi
      ;;
  esac
  if [ "$reclaim" = true ]; then
    tomb="${CLAIMS_LOCKDIR}.reap.$$"
    if mv "$CLAIMS_LOCKDIR" "$tomb" 2>/dev/null; then
      rm -rf "$tomb" 2>/dev/null || true
      if mkdir "$CLAIMS_LOCKDIR" 2>/dev/null; then
        _claims_lock_record_owner || {
          rm -rf "$CLAIMS_LOCKDIR" 2>/dev/null || true
          return 1
        }
        return 0
      fi
    fi
  fi
  return 1
}

_claims_lock_release() {
  local owner
  owner=$(cat "$CLAIMS_LOCKDIR/pid" 2>/dev/null || printf '')
  [ "$owner" = "$$" ] || return 1
  rm -rf "$CLAIMS_LOCKDIR"
}

# Atomic write of the claim file under the portable claims lock (own-refresh).
_atomic_claim_write() {
  local file="$1" json="$2" tmp rc=0
  tmp=$(mktemp "${file}.XXXXXX" 2>/dev/null) || return 1
  printf '%s\n' "$json" > "$tmp" || { rm -f "$tmp"; return 1; }
  _claims_lock_acquire || rc=$?
  if [ "$rc" -eq 0 ]; then
    mv -f "$tmp" "$file" || rc=$?
    _claims_lock_release || [ "$rc" -ne 0 ] || rc=1
  fi
  [ "$rc" -eq 0 ] || rm -f "$tmp" 2>/dev/null || true
  return "$rc"
}

# Compare-and-swap steal of a stale claim. The out-of-lock `_classify` (cmd_claim)
# only tells us the claim WAS stale a moment ago; two sessions can both see the
# same stale holder and both reach here. Serializing the mv alone does not make
# the decision exclusive, so a plain _atomic_claim_write lets BOTH win (double
# steal). This function re-verifies UNDER the lock before overwriting: it steals
# only when the on-disk holder is still `expected` (the stale holder we classified)
# AND that holder has not revived to live. A concurrent stealer that already swapped
# the record (holder changed) or a holder that came back to life aborts the steal.
# Returns: 0 stole, 10 CAS mismatch / holder revived (caller reports "other"),
#          1 environment/IO error.
_atomic_claim_steal() {
  local file="$1" json="$2" expected="$3" tmp rc=0 cur
  tmp=$(mktemp "${file}.XXXXXX" 2>/dev/null) || return 1
  printf '%s\n' "$json" > "$tmp" || { rm -f "$tmp"; return 1; }
  _claims_lock_acquire || rc=$?
  if [ "$rc" -eq 0 ]; then
    cur=$(_claim_holder "$file")
    if [ "$cur" != "$expected" ]; then rc=10
    elif _holder_is_live "$cur"; then rc=10
    else mv -f "$tmp" "$file" || rc=$?
    fi
    _claims_lock_release || [ "$rc" -ne 0 ] || rc=1
  fi
  [ "$rc" -eq 0 ] || rm -f "$tmp" 2>/dev/null || true
  return "$rc"
}

_validate_issue() {
  case "$1" in
    ''|*[!0-9]*) echo "ERROR: --issue must be a positive integer (got: '${1:-}')" >&2; return 1 ;;
  esac
  [ "$1" -gt 0 ] || { echo "ERROR: --issue must be > 0" >&2; return 1; }
  return 0
}

cmd_claim() {
  local issue="" worktree="" session=""
  while [ $# -gt 0 ]; do case "$1" in
    --issue) issue="$2"; shift 2 ;;
    --worktree) worktree="$2"; shift 2 ;;
    --session) session="$2"; shift 2 ;;
    *) echo "ERROR: unknown option: $1" >&2; return 1 ;;
  esac; done
  _validate_issue "$issue" || return 1
  local sid; sid=$(_resolve_current_session_id "$session")
  [ -n "$sid" ] || { echo "ERROR: issue-claim.sh claim: cannot resolve session_id" >&2; return 1; }
  mkdir -p "$CLAIMS_DIR" 2>/dev/null || { echo "ERROR: cannot create $CLAIMS_DIR" >&2; return 1; }
  local file="$CLAIMS_DIR/issue-${issue}.json" json
  json=$(_build_json "$issue" "$sid" "$worktree") || { echo "ERROR: failed to build claim JSON" >&2; return 1; }

  # Fast path: claim a FREE issue via noclobber. Only one racing process wins.
  if ( set -C; printf '%s\n' "$json" > "$file" ) 2>/dev/null; then
    echo "claimed"
    return 0
  fi

  # File already exists — classify and act.
  local state; state=$(_classify "$file" "$sid")
  case "$state" in
    own)
      _atomic_claim_write "$file" "$json" || { echo "ERROR: failed to refresh own claim" >&2; return 1; }
      echo "own"
      return 0
      ;;
    stale)
      local prev src=0; prev=$(_claim_holder "$file")
      _atomic_claim_steal "$file" "$json" "$prev" || src=$?
      if [ "$src" -eq 10 ]; then
        # CAS aborted under the lock: a concurrent stealer already won, or the
        # holder revived. Report "other" (rc 10) so the caller (open Step 1.6)
        # raises an AskUserQuestion instead of double-stealing (AC-1).
        echo "[issue-claim] issue #${issue} steal aborted under lock (concurrent stealer or holder revived); not stealing" >&2
        echo "other"
        return 10
      elif [ "$src" -ne 0 ]; then
        echo "ERROR: failed to steal stale claim" >&2
        return 1
      fi
      echo "[issue-claim] stole stale claim for issue #${issue} (previous holder: ${prev:-<corrupt>})" >&2
      echo "claimed"
      return 0
      ;;
    other)
      local holder; holder=$(_claim_holder "$file")
      echo "[issue-claim] issue #${issue} is claimed by another LIVE session (${holder}); not stealing unattended" >&2
      echo "other"
      return 10
      ;;
  esac
}

cmd_release() {
  local issue="" session=""
  while [ $# -gt 0 ]; do case "$1" in
    --issue) issue="$2"; shift 2 ;;
    --session) session="$2"; shift 2 ;;
    *) echo "ERROR: unknown option: $1" >&2; return 1 ;;
  esac; done
  _validate_issue "$issue" || return 1
  local sid; sid=$(_resolve_current_session_id "$session")
  [ -n "$sid" ] || { echo "ERROR: issue-claim.sh release: cannot resolve session_id" >&2; return 1; }
  local file="$CLAIMS_DIR/issue-${issue}.json"
  # Idempotent: releasing an absent claim is a success (AC-4).
  [ -f "$file" ] || { echo "released"; return 0; }
  local holder; holder=$(_claim_holder "$file")
  if [ "$holder" != "$sid" ]; then
    # Only the owner releases its own claim — never touch another session's (AC-3).
    echo "[issue-claim] release: issue #${issue} is held by another session (${holder:-<corrupt>}); leaving it intact" >&2
    echo "skipped"
    return 0
  fi
  _claims_lock_acquire || { echo "ERROR: failed to acquire claims lock" >&2; return 1; }
  holder=$(_claim_holder "$file")
  if [ -f "$file" ] && [ "$holder" = "$sid" ]; then
    rm -f "$file" || { _claims_lock_release || true; echo "ERROR: failed to remove claim" >&2; return 1; }
  fi
  _claims_lock_release || { echo "ERROR: failed to release claims lock" >&2; return 1; }
  echo "released"
  return 0
}

cmd_check() {
  local issue="" session=""
  while [ $# -gt 0 ]; do case "$1" in
    --issue) issue="$2"; shift 2 ;;
    --session) session="$2"; shift 2 ;;
    *) echo "ERROR: unknown option: $1" >&2; return 1 ;;
  esac; done
  _validate_issue "$issue" || return 1
  local sid; sid=$(_resolve_current_session_id "$session")
  local file="$CLAIMS_DIR/issue-${issue}.json"
  _classify "$file" "$sid"
  echo ""
  return 0
}

case "${1:-}" in
  claim)   shift; cmd_claim "$@" ;;
  release) shift; cmd_release "$@" ;;
  check)   shift; cmd_check "$@" ;;
  *)
    cat >&2 <<EOF
Usage: $0 {claim|release|check} --issue N [--worktree PATH] [--session UUID]
  claim   --issue N [--worktree PATH] [--session UUID]   acquire (rc 10 if held by live session)
  release --issue N [--session UUID]                      release own claim (idempotent)
  check   --issue N [--session UUID]                      print: own|free|other|stale
EOF
    exit 1
    ;;
esac
