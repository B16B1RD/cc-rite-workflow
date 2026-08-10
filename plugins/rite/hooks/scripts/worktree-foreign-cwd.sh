#!/bin/bash
# worktree-foreign-cwd.sh — self-exclusion-aware live-cwd probe for cleanup.md
# ステップ 4-W.
#
# Answers a single question: "is a FOREIGN (non-self) live process standing in
# this worktree (cwd at it or nested under it)?" — i.e. the same OS-ground-truth
# question as worktree-live-cwd.sh, but with the cleanup session's OWN process
# tree excluded.
#
# Why this exists :
#   cleanup.md ステップ 4-W removes the session worktree it just finished with. It
#   first calls ExitWorktree(keep), which retreats the harness cwd back to the
#   main checkout — after that, the plain worktree-live-cwd.sh probe reports rc=1
#   and removal proceeds. But when ExitWorktree was a no-op (the worktree was
#   path-entered WITHOUT an EnterWorktree session record — the #1622
#   in_worktree_unrecorded case — or a resume re-entry), the harness cwd stays
#   inside the worktree, so the plain probe reports rc=0 and cleanup DEFERS the
#   removal — blocking on the very session that is running cleanup (self-blocking).
#   pr-cycle-cleanup.sh Step 5 already avoids this for the lazy reaper via its
#   Gate 0 self-exclusion; this helper gives cleanup.md the same self-exclusion
#   WITHOUT modifying worktree-live-cwd.sh (its OS detection method is unchanged —
#   #1670 Non-Target §4.2). The caller passes --self-root (its harness pid); every
#   process in that pid subtree is "self" and ignored, so only a genuine OTHER
#   session standing in the tree defers the removal (the governing rationale AC-3).
#
# Usage:
#   worktree-foreign-cwd.sh <dir> --self-root <pid>
#
# Exit codes:
#   0 = a FOREIGN live process has cwd == <dir> or nested under it → caller DEFERS
#   1 = no foreign live cwd (only the self pid-subtree, or nobody) → caller REMOVES
#   2 = cannot determine (no /proc, or bad arguments) → caller decides. cleanup.md
#       removes on rc=2, matching the pre-#1670 worktree-live-cwd.sh rc=2
#       backward-compat behavior (so non-/proc hosts behave exactly as before).
#
# Portability: /proc only (Linux). Without /proc (e.g. macOS) returns 2 — the
# self-exclusion degrades to "remove" exactly as the old rc=2 path did, so there
# is no regression vs the previous behavior on those hosts. macOS bash 3.2 floor
# is preserved (no associative arrays, no GNU realpath); shared with
# pr-cycle-cleanup.sh / worktree-live-cwd.sh.
set -uo pipefail

target=""
self_root=""
while [ $# -gt 0 ]; do
  case "$1" in
    --self-root)
      # Guard the value before `shift 2`: a trailing `--self-root` with no value
      # would underflow `shift 2` (bash leaves $# unchanged when it exceeds $#),
      # re-processing the same token forever (hang). Fail fast with the documented
      # rc=2 "bad arguments" contract instead.
      [ $# -ge 2 ] || { echo "ERROR: worktree-foreign-cwd.sh: --self-root requires a value" >&2; exit 2; }
      self_root="$2"; shift 2 ;;
    --*) echo "ERROR: worktree-foreign-cwd.sh: unknown option: $1" >&2; exit 2 ;;
    *) [ -z "$target" ] && target="$1"; shift ;;
  esac
done

if [ -z "$target" ]; then
  echo "ERROR: worktree-foreign-cwd.sh: <dir> argument required" >&2
  exit 2
fi
case "$self_root" in
  ''|*[!0-9]*)
    echo "ERROR: worktree-foreign-cwd.sh: --self-root <pid> required (numeric)" >&2
    exit 2 ;;
esac

# Canonicalize target (mirror worktree-live-cwd.sh). A non-directory target
# (already-removed path) falls back to its raw string so the comparison still has
# something to match against.
if [ -d "$target" ]; then
  target_canon=$( cd -- "$target" 2>/dev/null && pwd -P ) || target_canon="$target"
else
  target_canon="$target"
fi
[ -n "$target_canon" ] || target_canon="$target"

# Without /proc we cannot read per-process cwd → undeterminable (rc 2). The caller
# removes on rc=2 (pre-#1670 backward-compat, same as worktree-live-cwd.sh).
[ -d /proc ] || exit 2

# Robust PPID read from /proc/<pid>/stat. The `comm` field is wrapped in parens and
# may itself contain spaces or parens (e.g. "(my proc)"), which would shift a naive
# `awk '{print $4}'`. Strip greedily through the LAST ')' so the remainder is
# "state ppid ..."; field 2 is then the ppid.
_ppid_of() {
  sed 's/.*) //' "/proc/$1/stat" 2>/dev/null | awk '{print $2}'
}

# rc 0 when $1 is self_root or a descendant of it (self_root appears in its
# ancestry). Walks UP the ppid chain; the guard bounds a pathological cycle.
_is_self() {
  local p="$1" guard=0 pp
  while [ -n "$p" ] && [ "$p" != "0" ] && [ "$guard" -lt 4096 ]; do
    [ "$p" = "$self_root" ] && return 0
    pp=$(_ppid_of "$p")
    [ -n "$pp" ] || return 1
    p="$pp"
    guard=$((guard + 1))
  done
  return 1
}

for _pdir in /proc/[0-9]*; do
  _pid="${_pdir#/proc/}"
  _cwd=$(readlink "$_pdir/cwd" 2>/dev/null) || continue
  [ -n "$_cwd" ] || continue
  # Is this process standing in the target worktree (cwd at it or nested under it)?
  # Trailing-slash prefix test so `issue-1` does not match `issue-12`.
  _in_tree=1
  if [ "$_cwd" = "$target_canon" ]; then
    _in_tree=0
  else
    case "$_cwd/" in
      "$target_canon"/*) _in_tree=0 ;;
    esac
  fi
  [ "$_in_tree" -eq 0 ] || continue
  # In the worktree — foreign unless it belongs to the self pid-subtree.
  _is_self "$_pid" && continue
  exit 0   # a foreign live process is standing in the worktree → caller defers
done
exit 1     # only the self pid-subtree (or nobody) stands in the worktree → remove
