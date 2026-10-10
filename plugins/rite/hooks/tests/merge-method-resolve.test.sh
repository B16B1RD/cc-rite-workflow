#!/bin/bash
# Tests for hooks/scripts/merge-method-resolve.sh.
#
# Contract: stdout is exactly one `[CONTEXT] MERGE_METHOD=` line. A missing
# config / section / key resolves to squash; squash and merge pass through; an
# empty, unknown, or non-lower-case value and an unreadable config exit 1 with
# `invalid` and never fall back to squash. Only a direct child `method:` of the
# top-level `merge:` section is read, and a linked worktree without its own
# config reads the main checkout's.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"

HELPER="$SCRIPT_DIR/../scripts/merge-method-resolve.sh"

cleanup_dirs=()
cleanup() { local d; for d in "${cleanup_dirs[@]:-}"; do [ -n "$d" ] && chmod -R u+rwx "$d" 2>/dev/null; [ -n "$d" ] && rm -rf "$d"; done; return 0; }
trap cleanup EXIT

MAIN=$(make_sandbox --branch develop)
cleanup_dirs+=("$MAIN")
WT="${MAIN}-wt"
git -C "$MAIN" worktree add -q -b feat/merge-method "$WT" >/dev/null 2>&1 || { echo "ERROR: git worktree add failed" >&2; exit 1; }
cleanup_dirs+=("$WT")

# run <dir> → sets OUT (stdout), ERR (stderr), RC
run() {
  local errf; errf=$(mktemp)
  RC=0
  OUT=$(bash "$HELPER" "$1" 2>"$errf") || RC=$?
  ERR=$(cat "$errf"); rm -f "$errf"
}

# config <text> writes the main checkout's rite-config.yml
config() { printf '%s\n' "$1" > "$MAIN/rite-config.yml"; }

echo "=== T-01: no config file → squash ==="
rm -f "$MAIN/rite-config.yml"
run "$MAIN"
assert "T-01 rc" "0" "$RC"
assert "T-01 stdout" "[CONTEXT] MERGE_METHOD=squash" "$OUT"
assert "T-01 quiet stderr" "" "$ERR"

echo "=== T-02: no merge section / section without method → squash ==="
config $'branch:\n  base: develop'
run "$MAIN"
assert "T-02 no section" "[CONTEXT] MERGE_METHOD=squash" "$OUT"
config $'merge:\n  # method: merge\nbranch:\n  method: merge'
run "$MAIN"
assert "T-02 section without method (sibling section key is not read)" "[CONTEXT] MERGE_METHOD=squash" "$OUT"
assert "T-02 rc" "0" "$RC"

echo "=== T-03: squash and merge pass through, quotes and comments stripped ==="
config $'merge:\n  method: squash'
run "$MAIN"
assert "T-03 squash" "[CONTEXT] MERGE_METHOD=squash" "$OUT"
config $'merge:\n  method: "merge"   # keep branch SHAs'
run "$MAIN"
assert "T-03 quoted merge with comment" "[CONTEXT] MERGE_METHOD=merge" "$OUT"
assert "T-03 rc" "0" "$RC"
config $'merge:   # how PRs are merged\n\n  method: \'merge\''
run "$MAIN"
assert "T-03 section comment, blank line, single quotes" "[CONTEXT] MERGE_METHOD=merge" "$OUT"

echo "=== T-04: invalid values exit 1 with invalid, never squash ==="
for v in rebase squahs Squash '""' '# none' ''; do
  config "merge:
  method: $v"
  run "$MAIN"
  assert "T-04 rc for '$v'" "1" "$RC"
  case "$OUT" in
    "[CONTEXT] MERGE_METHOD=invalid; value="*"; config=$MAIN/rite-config.yml") pass "T-04 stdout is the invalid line for '$v'" ;;
    *) fail "T-04 stdout is the invalid line for '$v' (got '$OUT')" ;;
  esac
  case "$ERR" in
    *"squash / merge"*) pass "T-04 stderr names accepted values for '$v'" ;;
    *) fail "T-04 stderr names accepted values for '$v' (got '$ERR')" ;;
  esac
done
config 'merge: merge'
run "$MAIN"
assert "T-04 inline scalar section rc" "1" "$RC"
assert "T-04 inline scalar section stdout" "[CONTEXT] MERGE_METHOD=invalid; value=merge; config=$MAIN/rite-config.yml" "$OUT"
case "$ERR" in
  *"merge: に値 'merge' が直接書かれています"*"merge: の下の行に method: squash または method: merge"*) pass "T-04 inline scalar stderr points at the misplaced value" ;;
  *) fail "T-04 inline scalar stderr points at the misplaced value (got '$ERR')" ;;
esac
case "$ERR" in
  *"使える値"*) fail "T-04 inline scalar stderr must not call an accepted value invalid (got '$ERR')" ;;
  *) pass "T-04 inline scalar stderr does not call an accepted value invalid" ;;
esac

echo "=== T-05: a nested method: under merge is not the method key ==="
config $'merge:\n  options:\n    method: merge'
run "$MAIN"
assert "T-05 nested ignored" "[CONTEXT] MERGE_METHOD=squash" "$OUT"
config $'merge:\n  options:\n    method: rebase\n  method: merge'
run "$MAIN"
assert "T-05 direct child after nested" "[CONTEXT] MERGE_METHOD=merge" "$OUT"

echo "=== T-06: linked worktree without its own config reads the main checkout's ==="
config $'merge:\n  method: merge'
run "$WT"
assert "T-06 rc" "0" "$RC"
assert "T-06 main checkout config" "[CONTEXT] MERGE_METHOD=merge" "$OUT"
printf 'merge:\n  method: squash\n' > "$WT/rite-config.yml"
run "$WT"
assert "T-06 worktree config wins" "[CONTEXT] MERGE_METHOD=squash" "$OUT"
rm -f "$WT/rite-config.yml"

echo "=== T-07: unreadable config → rc=1, invalid, not squash ==="
if [ "$(id -u)" -eq 0 ]; then
  skip "T-07 unreadable file (root ignores mode bits)"
else
  config $'merge:\n  method: merge'
  chmod 000 "$MAIN/rite-config.yml"
  run "$WT"
  assert "T-07 rc" "1" "$RC"
  assert "T-07 stdout" "[CONTEXT] MERGE_METHOD=invalid; reason=config_unreadable" "$OUT"
  case "$ERR" in
    *"$MAIN/rite-config.yml"*) pass "T-07 stderr names the unreadable path" ;;
    *) fail "T-07 stderr names the unreadable path (got '$ERR')" ;;
  esac
  chmod 644 "$MAIN/rite-config.yml"
fi

print_summary "$(basename "$0")" \
  "Drift hint: merge-method-resolve.sh — missing config/section/key → squash; only squash|merge; invalid and unreadable exit 1."
