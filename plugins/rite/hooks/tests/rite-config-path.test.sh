#!/bin/bash
# Tests for hooks/scripts/lib/rite-config-path.sh.
#
# Contract: a linked session worktree reads its own rite-config.yml when it has
# one (tracked config) and otherwise the main checkout's (untracked config);
# no candidate → rc=1 with every tried path on stderr; an unreadable candidate
# → rc=2 without falling through; outside Git only the given directory counts.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"

HELPER="$SCRIPT_DIR/../scripts/lib/rite-config-path.sh"

cleanup_dirs=()
cleanup() { local d; for d in "${cleanup_dirs[@]:-}"; do [ -n "$d" ] && chmod -R u+rwx "$d" 2>/dev/null; [ -n "$d" ] && rm -rf "$d"; done; return 0; }
trap cleanup EXIT

MAIN=$(make_sandbox --branch develop)
cleanup_dirs+=("$MAIN")
WT="${MAIN}-wt"
git -C "$MAIN" worktree add -q -b feat/config "$WT" >/dev/null 2>&1 || { echo "ERROR: git worktree add failed" >&2; exit 1; }
cleanup_dirs+=("$WT")

# run <dir> → sets OUT (stdout), ERR (stderr), RC
run() {
  local errf; errf=$(mktemp)
  RC=0
  OUT=$(bash "$HELPER" "$1" 2>"$errf") || RC=$?
  ERR=$(cat "$errf"); rm -f "$errf"
}

echo "=== T-01: config only in the main checkout → worktree resolves to main's file ==="
printf 'x: 1\n' > "$MAIN/rite-config.yml"
run "$WT"
assert "T-01 rc" "0" "$RC"
assert "T-01 path" "$MAIN/rite-config.yml" "$OUT"
assert "T-01 no stderr on success" "" "$ERR"
mkdir -p "$WT/sub/deep"
run "$WT/sub/deep"
assert "T-01 subdir of worktree also resolves to main's file" "$MAIN/rite-config.yml" "$OUT"

echo "=== T-04: both have a config → the worktree's file wins ==="
printf 'x: 2\n' > "$WT/rite-config.yml"
run "$WT"
assert "T-04 path" "$WT/rite-config.yml" "$OUT"
rm -f "$WT/rite-config.yml"

echo "=== T-06: non-worktree checkout → its own toplevel ==="
run "$MAIN"
assert "T-06 rc" "0" "$RC"
assert "T-06 path" "$MAIN/rite-config.yml" "$OUT"

echo "=== T-05: no config anywhere → rc=1, stdout empty, both tried paths on stderr ==="
rm -f "$MAIN/rite-config.yml"
run "$WT"
assert "T-05 rc" "1" "$RC"
assert "T-05 stdout empty" "" "$OUT"
case "$ERR" in
  *"$WT/rite-config.yml"*"$MAIN/rite-config.yml"*) pass "T-05 stderr names worktree then main path" ;;
  *) fail "T-05 stderr names worktree then main path (got '$ERR')" ;;
esac

echo "=== T-07: unreadable main config → rc=2, no fall-through to defaults ==="
if [ "$(id -u)" -eq 0 ]; then
  skip "T-07 unreadable file (root ignores mode bits)"
else
  printf 'x: 1\n' > "$MAIN/rite-config.yml"
  chmod 000 "$MAIN/rite-config.yml"
  run "$WT"
  assert "T-07 rc" "2" "$RC"
  assert "T-07 stdout empty" "" "$OUT"
  case "$ERR" in
    *"$MAIN/rite-config.yml"*) pass "T-07 stderr names the unreadable path" ;;
    *) fail "T-07 stderr names the unreadable path (got '$ERR')" ;;
  esac
  chmod 644 "$MAIN/rite-config.yml"
  rm -f "$MAIN/rite-config.yml"
fi

echo "=== T-08: outside Git → only the given directory ==="
PLAIN=$(make_plain_sandbox)
cleanup_dirs+=("$PLAIN")
run "$PLAIN"
assert "T-08 missing rc" "1" "$RC"
printf 'x: 1\n' > "$PLAIN/rite-config.yml"
run "$PLAIN"
assert "T-08 found path" "$PLAIN/rite-config.yml" "$OUT"

echo "=== T-09: sourcing defines the function without changing shell options ==="
opts_before=$(set +o)
# shellcheck source=../scripts/lib/rite-config-path.sh
source "$HELPER"
opts_after=$(set +o)
assert "T-09 shell options unchanged by source" "$opts_before" "$opts_after"
assert "T-09 function resolves" "$PLAIN/rite-config.yml" "$(rite_config_path "$PLAIN")"

echo "=== T-11: --or-devnull turns a missing config into a WARNING + /dev/null, keeps unreadable an error ==="
rm -f "$MAIN/rite-config.yml"
errf=$(mktemp); rc=0
out=$(bash "$HELPER" --or-devnull "$WT" 2>"$errf") || rc=$?
assert "T-11 missing rc" "0" "$rc"
assert "T-11 missing stdout is /dev/null" "/dev/null" "$out"
case "$(cat "$errf")" in
  WARNING:*"$WT/rite-config.yml"*"$MAIN/rite-config.yml"*) pass "T-11 missing warns with both tried paths" ;;
  *) fail "T-11 missing warns with both tried paths (got '$(cat "$errf")')" ;;
esac
printf 'x: 1\n' > "$MAIN/rite-config.yml"
assert "T-11 found path passes through" "$MAIN/rite-config.yml" "$(bash "$HELPER" --or-devnull "$WT")"
if [ "$(id -u)" -ne 0 ]; then
  chmod 000 "$MAIN/rite-config.yml"
  rc=0; out=$(bash "$HELPER" --or-devnull "$WT" 2>"$errf") || rc=$?
  assert "T-11 unreadable rc" "2" "$rc"
  assert "T-11 unreadable stdout empty" "" "$out"
  chmod 644 "$MAIN/rite-config.yml"
fi
rm -f "$MAIN/rite-config.yml" "$errf"

echo "=== T-10: pr-review post_comment read uses the main checkout config from a worktree ==="
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PR_SKILL="$PLUGIN_ROOT/skills/pr-review/SKILL.md"
block=$(awk '/^# --- Step 3: rite-config.yml の pr_review.post_comment 読取/{f=1} /^# --- Step 4:/{f=0} f' "$PR_SKILL" \
  | sed "s|{plugin_root}|$PLUGIN_ROOT|g")
case "$block" in
  *rite-config-path.sh*) pass "T-10 block extracted and calls the resolver" ;;
  *) fail "T-10 block extracted and calls the resolver" ;;
esac
printf 'pr_review:\n  post_comment: true\n' > "$MAIN/rite-config.yml"
got=$(cd "$WT" && bash -c "$block"$'\necho "post=$config_post_comment"' 2>&1)
case "$got" in
  *"post=true"*) pass "T-10 worktree reads post_comment=true from main" ;;
  *) fail "T-10 worktree reads post_comment=true from main (got '$got')" ;;
esac
rm -f "$MAIN/rite-config.yml"
got=$(cd "$WT" && bash -c "$block"$'\necho "post=$config_post_comment"' 2>&1)
case "$got" in
  *"WARNING:"*"$MAIN/rite-config.yml"*"post=false"*) pass "T-10 missing config warns with tried path and defaults to false" ;;
  *) fail "T-10 missing config warns with tried path and defaults to false (got '$got')" ;;
esac

print_summary "$(basename "$0")" \
  "Drift hint: rite-config-path.sh — worktree toplevel first, then main checkout root; rc=1 lists tried paths, rc=2 never falls through."
