#!/bin/bash
# worktree-live-cwd.sh — OS-ground-truth liveness probe for a worktree directory.
#
# Answers a single question: "is any live process standing in this directory
# (cwd at it or nested under it)?" — independent of rite's own flow-state
# bookkeeping.
#
# Why this exists (the governing rationale, regression of #1524):
#   When a session enters a session worktree via `EnterWorktree`, the harness
#   records that worktree as the session's cwd and restores it on `/clear`. If the
#   worktree is removed (cross-session lazy reap in pr-cycle-cleanup.sh Step 5, or
#   a cleanup from a different cwd in cleanup.md Step 4-W) while the owning
#   session's harness cwd still points there, `/clear` fails with
#   `Error: Path "..." does not exist`. #1524's guards key off flow-state
#   (`active` flag + `worktree` field); those can DRIFT from where harness cwds
#   actually are (active=false but still standing in it, empty/nulled `worktree`
#   field, stale session-id). This probe does not depend on that bookkeeping — it
#   reads the OS's own record of each process's cwd, so "don't delete a tree
#   someone is standing in" holds even when flow-state is wrong.
#
# Usage:
#   worktree-live-cwd.sh <dir>
#
# Exit codes:
#   0 = a live process has cwd == <dir> or nested under it  → DO NOT remove
#   1 = no live process is standing in <dir>                → safe (per other gates)
#   2 = cannot determine (no /proc and no lsof)             → caller decides
#
# Portability: avoids GNU `realpath` (canonicalizes via `cd && pwd -P`) to keep
# the macOS bash 3.2 floor shared with pr-cycle-cleanup.sh. `/proc` is the
# primary source (Linux); `lsof` is the fallback (BSD/macOS). Same-user processes
# are readable, and Claude Code sessions run as the same user.
set -uo pipefail

target="${1:-}"
if [ -z "$target" ]; then
  echo "ERROR: worktree-live-cwd.sh: <dir> argument required" >&2
  exit 2
fi

# Canonicalize. A non-directory target (already-removed path) falls back to its
# raw string so a string comparison still has something to match against.
if [ -d "$target" ]; then
  target_canon=$( cd -- "$target" 2>/dev/null && pwd -P ) || target_canon="$target"
else
  target_canon="$target"
fi
[ -n "$target_canon" ] || target_canon="$target"

# Detection backend selection. Default auto-detects (/proc → lsof → undeterminable).
# RITE_WORKTREE_LIVE_CWD_PROBE forces a specific backend so the lsof and
# undeterminable branches — unreachable on Linux where /proc always exists — stay
# test-covered, and so a Linux operator can exercise the fallback if /proc is
# unexpectedly unusable. Values: proc | lsof | none | auto (default).
probe="${RITE_WORKTREE_LIVE_CWD_PROBE:-auto}"

# /proc backend: readlink of /proc/<pid>/cwd is the OS ground truth for a process's
# working directory. This script's own cwd is the caller's (repo root for the reaper,
# main checkout for cleanup), never the candidate worktree, so it does not false-match
# itself — and the reaper's own active worktree is already excluded upstream (Gate 0
# self-exclusion) before this probe is consulted.
_rite_probe_proc() {
  local _pdir _cwd
  for _pdir in /proc/[0-9]*; do
    _cwd=$(readlink "$_pdir/cwd" 2>/dev/null) || continue
    [ -n "$_cwd" ] || continue
    [ "$_cwd" = "$target_canon" ] && return 0
    # Trailing-slash prefix test: `issue-1` must not match `issue-12`.
    case "$_cwd/" in
      "$target_canon"/*) return 0 ;;
    esac
  done
  return 1
}

# lsof backend (where /proc is absent, e.g. BSD/macOS). `-a -d cwd +D <dir>` lists
# processes whose working directory is at or under <dir>; any hit means a live cwd.
# Returns 2 (undeterminable) when lsof itself is unavailable.
_rite_probe_lsof() {
  local out
  command -v lsof >/dev/null 2>&1 || return 2
  out=$(lsof -a -d cwd +D "$target_canon" 2>/dev/null) || true
  [ -n "$out" ]
}

case "$probe" in
  proc) _rite_probe_proc; exit $? ;;
  lsof) _rite_probe_lsof; exit $? ;;
  none) exit 2 ;;  # forced undeterminable (neither /proc nor lsof)
  auto)
    if [ -d /proc ]; then _rite_probe_proc; exit $?; fi
    if command -v lsof >/dev/null 2>&1; then _rite_probe_lsof; exit $?; fi
    exit 2  # neither /proc nor lsof — undeterminable
    ;;
  *)
    echo "ERROR: worktree-live-cwd.sh: invalid RITE_WORKTREE_LIVE_CWD_PROBE='$probe' (expected proc|lsof|none|auto)" >&2
    exit 2
    ;;
esac
