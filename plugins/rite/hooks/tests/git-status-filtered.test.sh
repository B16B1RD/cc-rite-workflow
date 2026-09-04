#!/bin/bash
# Tests for lib/git-status-filtered.sh
#
# The Bash tool sandbox blocks writes to certain paths (.bashrc,
# .claude/agents, .gitconfig, etc.) by bind-mounting /dev/null over them.
# These mounts are persistent character-device files, invisible to the
# harness's own git-status snapshot but visible from inside the Bash tool,
# so they show up as spurious `??` (untracked) entries in every
# `git status --porcelain` a sandboxed Bash command runs — even though
# nothing in the working tree actually changed. lib/git-status-filtered.sh
# strips exactly those entries (untracked + character device, detected via
# `test -c`, never a filename allowlist) while passing every other status
# code through unchanged.
#
# mknod requires root/CAP_MKNOD and is unavailable in this (and most CI)
# environments, so tests simulate a "character device at this path" with a
# symlink to /dev/null (`ln -s /dev/null <path>`) instead of a real device
# node. `test -c` follows symlinks (like stat, not lstat), so this is
# behaviorally identical to the real sandbox mount for the one property the
# script inspects, and `git status --porcelain` reports it as an ordinary
# `??` entry exactly like the genuine ghost mount.
#
# Convention: standalone subprocess (`bash lib/git-status-filtered.sh`),
# not sourced — mirrors git-remote-resolve.test.sh's invocation style for
# the sibling lib/git-remote.sh standalone subcommand.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"

LIB="$SCRIPT_DIR/../scripts/lib/git-status-filtered.sh"

echo "=== git-status-filtered.sh (untracked character-device ghost mount filter) ==="

if [ ! -f "$LIB" ]; then
  echo "ERROR: $LIB not found" >&2
  exit 1
fi

cleanup_dirs=()
cleanup() {
  local d
  for d in "${cleanup_dirs[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
}
trap cleanup EXIT

run_in() {
  local dir="$1"
  ( cd "$dir" && bash "$LIB" )
}

# --- T-01 (AC-1): character device untracked-only tree filters to empty --
sbx1=$(make_sandbox) && cleanup_dirs+=("$sbx1") || { echo "ERROR: make_sandbox failed, aborting" >&2; exit 1; }
( cd "$sbx1" && ln -s /dev/null ghost_devnull ) >/dev/null 2>&1
out=$(run_in "$sbx1"); rc=$?
assert "T-01: exit 0" "0" "$rc"
assert "T-01: output empty (ghost entry dropped)" "" "$out"

# --- T-02 (AC-1 + AC-2): real untracked file survives, ghost is dropped ---
sbx2=$(make_sandbox) && cleanup_dirs+=("$sbx2") || { echo "ERROR: make_sandbox failed, aborting" >&2; exit 1; }
( cd "$sbx2" && ln -s /dev/null ghost_devnull && echo new > real_untracked.txt ) >/dev/null 2>&1
out=$(run_in "$sbx2"); rc=$?
assert "T-02: exit 0" "0" "$rc"
assert "T-02: real untracked file present" "?? real_untracked.txt" "$out"
case "$out" in
  *ghost_devnull*) fail "T-02: ghost entry must not appear in output" ;;
  *) pass "T-02: ghost entry absent from output" ;;
esac

# --- T-03 (AC-3): staged / unstaged / unmerged entries pass through as-is -
sbx3=$(make_sandbox) && cleanup_dirs+=("$sbx3") || { echo "ERROR: make_sandbox failed, aborting" >&2; exit 1; }
base_branch=$( cd "$sbx3" && git branch --show-current )
(
  cd "$sbx3" || exit 1
  echo modified >> a
  echo staged > staged.txt
  git add staged.txt
) >/dev/null 2>&1
out=$(run_in "$sbx3")
case "$out" in
  *"A  staged.txt"*) pass "T-03: staged (A ) entry passes through" ;;
  *) fail "T-03: staged (A ) entry passes through (got: $out)" ;;
esac
case "$out" in
  *" M a"*) pass "T-03: unstaged ( M) entry passes through" ;;
  *) fail "T-03: unstaged ( M) entry passes through (got: $out)" ;;
esac

# unmerged (UU): diverge on a branch, then merge to force a conflict on "a"
sbx3u=$(make_sandbox) && cleanup_dirs+=("$sbx3u") || { echo "ERROR: make_sandbox failed, aborting" >&2; exit 1; }
base3u=$( cd "$sbx3u" && git branch --show-current )
(
  cd "$sbx3u" || exit 1
  git checkout -q -b conflict-side
  echo side > a
  git -c user.email=t@test.local -c user.name=test commit -q -am side
  git checkout -q "$base3u"
  echo main > a
  git -c user.email=t@test.local -c user.name=test commit -q -am main
  git -c user.email=t@test.local -c user.name=test merge conflict-side >/dev/null 2>&1
) >/dev/null 2>&1
out=$(run_in "$sbx3u")
case "$out" in
  *"UU a"*) pass "T-03: unmerged (UU) entry passes through" ;;
  *) fail "T-03: unmerged (UU) entry passes through (got: $out)" ;;
esac

# --- Rename pass-through: -z's two-field rename record reassembles as "R  old -> new"
sbx_ren=$(make_sandbox) && cleanup_dirs+=("$sbx_ren") || { echo "ERROR: make_sandbox failed, aborting" >&2; exit 1; }
( cd "$sbx_ren" && git mv a b ) >/dev/null 2>&1
out=$(run_in "$sbx_ren")
assert "rename: reassembled as 'R  a -> b'" "R  a -> b" "$out"

# --- Clean tree: no entries at all -> empty output, exit 0 ------------------
sbx_clean=$(make_sandbox) && cleanup_dirs+=("$sbx_clean") || { echo "ERROR: make_sandbox failed, aborting" >&2; exit 1; }
out=$(run_in "$sbx_clean"); rc=$?
assert "clean tree: exit 0" "0" "$rc"
assert "clean tree: empty output" "" "$out"

# --- Failure path: not a git repository -> non-zero exit, WARNING on stderr,
#     empty stdout (script must not silently report a "clean" tree) --------
plain=$(make_plain_sandbox) && cleanup_dirs+=("$plain") || { echo "ERROR: make_plain_sandbox failed, aborting" >&2; exit 1; }
err_capture=$(mktemp) || { echo "ERROR: mktemp failed, aborting" >&2; exit 1; }
out=$( cd "$plain" && bash "$LIB" 2>"$err_capture" )
rc=$?
err=$(cat "$err_capture" 2>/dev/null); rm -f "$err_capture"
assert "not-a-repo: non-zero exit" "1" "$( [ "$rc" -ne 0 ] && echo 1 || echo 0 )"
assert "not-a-repo: empty stdout" "" "$out"
case "$err" in
  *"WARNING: git-status-filtered"*) pass "not-a-repo: WARNING emitted on stderr" ;;
  *) fail "not-a-repo: WARNING emitted on stderr (got: $err)" ;;
esac

print_summary "$(basename "$0")"
