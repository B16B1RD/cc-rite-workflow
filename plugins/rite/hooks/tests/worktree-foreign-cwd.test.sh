#!/bin/bash
# Tests for worktree-foreign-cwd.sh — self-exclusion-aware live-cwd probe used by
# cleanup.md ステップ 4-W (Issue #1670).
#
# The contract: "is a FOREIGN (non-self) live process standing in this worktree?"
#   rc 0 = a foreign process (NOT in the --self-root pid subtree) stands in the dir
#          → cleanup DEFERS removal
#   rc 1 = only the self pid-subtree (or nobody) stands in the dir → cleanup REMOVES
#   rc 2 = bad arguments / no /proc → caller decides (cleanup removes)
#
#   TC-1:  missing <dir>                                   → rc 2
#   TC-2:  missing --self-root                             → rc 2
#   TC-3:  non-numeric --self-root                         → rc 2
#   TC-4:  free dir (nobody inside)                        → rc 1
#   TC-5:  FOREIGN holder (self-root is not its ancestor)  → rc 0  (defer)
#   TC-6:  SELF holder (self-root IS its ancestor)         → rc 1  (self-exclusion)
#   TC-7:  foreign holder NESTED under the dir             → rc 0
#   TC-8:  sibling-prefix dir (issue-1 vs issue-12)        → no false match (rc 1)
#   TC-9:  self + foreign coexist → rc 0; kill foreign → rc 1 (surgical)
#   TC-10: after the foreign holder exits, dir is free     → rc 1
#
# This is the self-exclusion layer cleanup.md needs WITHOUT modifying
# worktree-live-cwd.sh (#1670 Non-Target): the cleanup session's own harness
# (--self-root = the cleanup Bash's $PPID) must never block removal of the very
# worktree it just finished, while a genuine OTHER session standing in the tree
# still defers it (AC-1/AC-2/AC-3).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"

PROBE="$SCRIPT_DIR/../scripts/worktree-foreign-cwd.sh"

cleanup_dirs=()
holders=()
cleanup() {
  local p d
  for p in "${holders[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null || true; done
  wait 2>/dev/null || true
  for d in "${cleanup_dirs[@]:-}"; do [ -n "$d" ] && rm -rf "$d"; done
  return 0
}
trap cleanup EXIT

# Run the probe and echo its exit code (the rc is the contract under test).
probe_rc() { bash "$PROBE" "$@" >/dev/null 2>&1; echo "$?"; }

echo "=== TC-1: missing <dir> → rc 2 ==="
assert "TC-1 no dir → rc 2" "2" "$(bash "$PROBE" --self-root 1 >/dev/null 2>&1; echo $?)"

echo "=== TC-2: missing --self-root → rc 2 ==="
D=$(mktemp -d); cleanup_dirs+=("$D")
assert "TC-2 no --self-root → rc 2" "2" "$(probe_rc "$D")"

echo "=== TC-3: non-numeric --self-root → rc 2 ==="
assert "TC-3 bad --self-root → rc 2" "2" "$(probe_rc "$D" --self-root notapid)"

echo "=== TC-3b: trailing --self-root with NO value → rc 2, no hang ==="
# A `--self-root` token with no following value must fail-fast (rc 2), not underflow
# `shift 2` and re-process the same token forever. `timeout` bounds the would-be hang;
# rc 124 (timeout-killed) would mean the guard regressed.
assert "TC-3b dangling --self-root → rc 2 (no hang)" "2" "$(_timeout 5 bash "$PROBE" "$D" --self-root >/dev/null 2>&1; echo $?)"

# TC-4..TC-10 assert the /proc-backed liveness rc values (0 = defer, 1 = remove).
# worktree-foreign-cwd.sh is /proc-only by design and returns rc 2 (undeterminable)
# without /proc — e.g. on macOS, where the caller then removes the tree (documented
# safe degradation). Guard these behind /proc so the macOS leg skips them instead of
# asserting Linux-only rc values (Issue #2008 Family C).
if [ -d /proc ]; then
echo "=== TC-4: free dir, nobody inside → rc 1 ==="
assert "TC-4 free dir → rc 1" "1" "$(probe_rc "$D" --self-root 99999)"

echo "=== TC-5: FOREIGN holder (self-root not its ancestor) → rc 0 (defer) ==="
# Holder is a child of THIS test shell; --self-root=99999 (a bogus pid that is NOT
# in the holder's ancestry) models "a different session is standing in the tree".
( cd "$D" && sleep 30 ) & holders+=("$!")
sleep 0.3
assert "TC-5 foreign holder → rc 0" "0" "$(probe_rc "$D" --self-root 99999)"

echo "=== TC-6: SELF holder (self-root IS its ancestor) → rc 1 (self-exclusion) ==="
# Same holder, but now --self-root=$$ (this test shell), which IS the holder's
# ancestor → the holder is part of the self subtree → excluded → removal proceeds.
# This is the core self-block fix: cleanup's own harness must not block its removal.
assert "TC-6 self holder excluded → rc 1" "1" "$(probe_rc "$D" --self-root "$$")"

echo "=== TC-7: foreign holder nested UNDER the dir → rc 0 ==="
D2=$(mktemp -d); cleanup_dirs+=("$D2"); mkdir -p "$D2/sub/deep"
( cd "$D2/sub/deep" && sleep 30 ) & holders+=("$!")
sleep 0.3
assert "TC-7 nested foreign holder → rc 0" "0" "$(probe_rc "$D2" --self-root 99999)"

echo "=== TC-8: sibling-prefix dir must not false-match (issue-1 vs issue-12) ==="
D3=$(mktemp -d); cleanup_dirs+=("$D3"); mkdir -p "$D3/issue-1" "$D3/issue-12"
( cd "$D3/issue-12" && sleep 30 ) & holders+=("$!")
sleep 0.3
assert "TC-8 issue-1 not matched by issue-12 holder → rc 1" "1" "$(probe_rc "$D3/issue-1" --self-root 99999)"
assert "TC-8 issue-12 itself (foreign) → rc 0" "0" "$(probe_rc "$D3/issue-12" --self-root 99999)"

echo "=== TC-9: self + foreign coexist → rc 0; kill foreign → rc 1 (surgical) ==="
D4=$(mktemp -d); cleanup_dirs+=("$D4")
( cd "$D4" && sleep 30 ) & SELF_PID=$!; holders+=("$SELF_PID")     # this pid IS --self-root → self
( cd "$D4" && sleep 30 ) & FOREIGN_PID=$!; holders+=("$FOREIGN_PID")  # sibling → foreign vs SELF_PID
sleep 0.3
assert "TC-9 self+foreign in dir → rc 0 (foreign defers)" "0" "$(probe_rc "$D4" --self-root "$SELF_PID")"
kill "$FOREIGN_PID" 2>/dev/null || true; wait "$FOREIGN_PID" 2>/dev/null || true
assert "TC-9 only self remains → rc 1 (remove)" "1" "$(probe_rc "$D4" --self-root "$SELF_PID")"

echo "=== TC-10: after the foreign holder exits, dir is free → rc 1 ==="
D5=$(mktemp -d); cleanup_dirs+=("$D5")
( cd "$D5" && sleep 1 ) & hp=$!; holders+=("$hp")
sleep 0.3
assert "TC-10 while foreign held → rc 0" "0" "$(probe_rc "$D5" --self-root 99999)"
wait "$hp" 2>/dev/null || true
assert "TC-10 after holder exits → rc 1" "1" "$(probe_rc "$D5" --self-root 99999)"
else
  skip "TC-4..TC-10 skipped (no /proc: worktree-foreign-cwd.sh returns rc 2 by design; caller removes — safe degradation)"
fi

if ! print_summary "$(basename "$0")" "worktree-foreign-cwd.sh の self-exclusion 付き live-cwd 判定 (Issue #1670): self の harness subtree を除外し、別 live セッションのみ削除を遅延させる"; then
  exit 1
fi
