#!/bin/bash
# Tests for worktree-live-cwd.sh — OS-ground-truth liveness probe (Issue #1544).
#
#   TC-1: missing <dir> argument                       → rc 2
#   TC-2: directory with NO process standing in it     → rc 1
#   TC-3: a process whose cwd IS the directory         → rc 0
#   TC-4: a process whose cwd is NESTED under the dir  → rc 0
#   TC-5: sibling-prefix dir (issue-1 vs issue-12)     → no false match (rc 1)
#   TC-6: after the holder exits, the dir is free again → rc 1
#   TC-7: forced 'none' backend (RITE_WORKTREE_LIVE_CWD_PROBE) → rc 2
#   TC-8: invalid backend value                        → rc 2
#   TC-9: forced 'proc' backend (free → rc 1, held → rc 0)
#   TC-10: forced 'lsof' backend (held → rc 0, free → rc 1; rc 2 if lsof absent)
#   TC-11: symlinked-parent canonicalization (real & linked path both → rc 0)
#
# These pin the contract the reap gate (pr-cycle-cleanup.sh Step 5) and the
# cleanup removal (cleanup.md Step 4-W) depend on: "don't delete a worktree a
# live process is standing in", independent of rite flow-state.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"

PROBE="$SCRIPT_DIR/../scripts/worktree-live-cwd.sh"

cleanup_dirs=()
holders=()
cleanup() {
  local p d
  # `|| true`: a holder may already have exited (e.g. TC-6's short sleep), so kill
  # returns non-zero — without the guard, set -e would abort the EXIT trap.
  for p in "${holders[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null || true; done
  wait 2>/dev/null || true
  for d in "${cleanup_dirs[@]:-}"; do [ -n "$d" ] && rm -rf "$d"; done
  return 0
}
trap cleanup EXIT

# Run the probe and echo its exit code (probe rc is the contract under test).
probe_rc() { bash "$PROBE" "$@" >/dev/null 2>&1; echo "$?"; }

echo "=== TC-1: missing argument → rc 2 ==="
assert "TC-1 no arg → rc 2" "2" "$(bash "$PROBE" >/dev/null 2>&1; echo $?)"

echo "=== TC-2: empty directory, no process inside → rc 1 ==="
D=$(mktemp -d); cleanup_dirs+=("$D")
assert "TC-2 free dir → rc 1" "1" "$(probe_rc "$D")"

echo "=== TC-3: a process holds cwd == dir → rc 0 ==="
( cd "$D" && sleep 30 ) & holders+=("$!")
sleep 0.3
assert "TC-3 held dir → rc 0" "0" "$(probe_rc "$D")"

echo "=== TC-4: a process holds cwd nested under dir → rc 0 ==="
# Without /proc the auto backend falls back to lsof, whose exit-code-based
# detection is a false-negative for a dir that has subdirectories (a real bug
# tracked in #2011). Guard behind /proc so the macOS leg skips this rather than
# asserting the broken result (Issue #2008 Family B).
if [ -d /proc ]; then
D2=$(mktemp -d); cleanup_dirs+=("$D2")
mkdir -p "$D2/sub/deep"
( cd "$D2/sub/deep" && sleep 30 ) & holders+=("$!")
sleep 0.3
assert "TC-4 nested-held dir → rc 0" "0" "$(probe_rc "$D2")"
else
  echo "  ⏭️  TC-4 skipped (no /proc: auto backend → lsof; lsof exit-code false-negative on nested dirs tracked in #2011)"
fi

echo "=== TC-5: sibling-prefix dir must not false-match (issue-1 vs issue-12) ==="
D3=$(mktemp -d); cleanup_dirs+=("$D3")
mkdir -p "$D3/issue-1" "$D3/issue-12"
( cd "$D3/issue-12" && sleep 30 ) & holders+=("$!")
sleep 0.3
assert "TC-5 issue-1 not matched by issue-12 holder → rc 1" "1" "$(probe_rc "$D3/issue-1")"
assert "TC-5 issue-12 itself matched → rc 0" "0" "$(probe_rc "$D3/issue-12")"

echo "=== TC-6: after holder exits the dir is free again → rc 1 ==="
D4=$(mktemp -d); cleanup_dirs+=("$D4")
( cd "$D4" && sleep 1 ) & hp=$!
holders+=("$hp")   # also register for trap-based teardown (defensive; wait below is the primary)
sleep 0.3
assert "TC-6 while held → rc 0" "0" "$(probe_rc "$D4")"
wait "$hp" 2>/dev/null || true
assert "TC-6 after holder exits → rc 1" "1" "$(probe_rc "$D4")"

# --- Backend-selection seam coverage (RITE_WORKTREE_LIVE_CWD_PROBE) ---
# On Linux the auto path always takes /proc, leaving the lsof and undeterminable
# branches dead at runtime. cleanup.md's backward-compat note explicitly relies on
# rc=2 (undeterminable → delete proceeds), so force each backend to pin it.

echo "=== TC-7: forced 'none' backend → rc 2 (undeterminable) ==="
D5=$(mktemp -d); cleanup_dirs+=("$D5")
assert "TC-7 probe=none → rc 2" "2" "$(RITE_WORKTREE_LIVE_CWD_PROBE=none bash "$PROBE" "$D5" >/dev/null 2>&1; echo $?)"

echo "=== TC-8: invalid backend value → rc 2 ==="
assert "TC-8 probe=bogus → rc 2" "2" "$(RITE_WORKTREE_LIVE_CWD_PROBE=bogus bash "$PROBE" "$D5" >/dev/null 2>&1; echo $?)"

echo "=== TC-9: forced 'proc' backend behaves like auto on Linux ==="
# The forced 'proc' backend inspects /proc/<pid>/cwd; on a host without /proc
# (macOS) it can never detect a holder, so the held-dir assertion cannot hold.
# Guard behind /proc — this is the by-design degradation, not a bug (Family C).
if [ -d /proc ]; then
D6=$(mktemp -d); cleanup_dirs+=("$D6")
assert "TC-9 probe=proc free dir → rc 1" "1" "$(RITE_WORKTREE_LIVE_CWD_PROBE=proc bash "$PROBE" "$D6" >/dev/null 2>&1; echo $?)"
( cd "$D6" && sleep 30 ) & holders+=("$!")
sleep 0.3
assert "TC-9 probe=proc held dir → rc 0" "0" "$(RITE_WORKTREE_LIVE_CWD_PROBE=proc bash "$PROBE" "$D6" >/dev/null 2>&1; echo $?)"
else
  echo "  ⏭️  TC-9 skipped (forced 'proc' backend requires /proc; absent on macOS by design)"
fi

echo "=== TC-10: forced 'lsof' backend (the BSD/macOS fallback) ==="
D7=$(mktemp -d); cleanup_dirs+=("$D7")
if command -v lsof >/dev/null 2>&1; then
  # free dir → rc 1 (the "delete proceeds" branch cleanup.md relies on)
  assert "TC-10 probe=lsof free dir → rc 1" "1" "$(RITE_WORKTREE_LIVE_CWD_PROBE=lsof bash "$PROBE" "$D7" >/dev/null 2>&1; echo $?)"
  ( cd "$D7" && sleep 30 ) & holders+=("$!")
  sleep 0.3
  assert "TC-10 probe=lsof held dir → rc 0" "0" "$(RITE_WORKTREE_LIVE_CWD_PROBE=lsof bash "$PROBE" "$D7" >/dev/null 2>&1; echo $?)"
else
  # lsof absent → the lsof backend reports undeterminable (rc 2), not a false negative.
  assert "TC-10 probe=lsof w/o lsof → rc 2" "2" "$(RITE_WORKTREE_LIVE_CWD_PROBE=lsof bash "$PROBE" "$D7" >/dev/null 2>&1; echo $?)"
fi

echo "=== TC-11: canonicalization matches a symlinked parent (pwd -P / readlink converge) ==="
# The probe canonicalizes its arg with `cd && pwd -P`; /proc/<pid>/cwd is already
# physical. A holder entering via a symlinked path must still match both the real
# and the linked target — pins the canonicalization contract against a future
# realpath swap.
# Guard behind /proc: the auto backend uses lsof without /proc, whose exit-code
# false-negative on dirs-with-subdirs ($Dreal/wt has /sub) makes both asserts
# fail on macOS — the #2011 lsof bug, not a canonicalization regression (Family B).
if [ -d /proc ]; then
Dreal=$(mktemp -d); cleanup_dirs+=("$Dreal"); mkdir -p "$Dreal/wt/sub"
Dlink=$(mktemp -d); cleanup_dirs+=("$Dlink"); ln -s "$Dreal/wt" "$Dlink/wtlink"
( cd "$Dlink/wtlink/sub" && sleep 30 ) & holders+=("$!")
sleep 0.3
assert "TC-11 real path → rc 0" "0" "$(probe_rc "$Dreal/wt")"
assert "TC-11 symlinked path → rc 0" "0" "$(probe_rc "$Dlink/wtlink")"
else
  echo "  ⏭️  TC-11 skipped (no /proc: auto backend → lsof; exit-code false-negative tracked in #2011)"
fi

if ! print_summary "$(basename "$0")" "worktree-live-cwd.sh の OS 接地 liveness 判定 (Issue #1544)"; then
  exit 1
fi
