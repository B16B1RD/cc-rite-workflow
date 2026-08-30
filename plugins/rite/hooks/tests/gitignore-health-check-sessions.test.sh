#!/bin/bash
# Tests for gitignore-health-check.sh always-on .rite/sessions/ check.
#
# Verifies the non-blocking, ALWAYS-ON `.rite/sessions/` ignore check folded into
# gitignore-health-check.sh. Unlike the `.rite/worktrees/` check (gated on
# multi_session.enabled), per-session state files (.rite/sessions/{session_id}.flow-state)
# are written on every rite session, so this check is NOT gated:
#   - .rite/sessions/ NOT ignored                       → drift (exit 1)
#   - .rite/sessions/ ignored                            → healthy (exit 0)
#   - multi_session.enabled=false + sessions NOT ignored → still drift (NOT gated on multi_session)
#   - wiki.enabled=false + sessions NOT ignored          → still drift (runs BEFORE wiki early-exits)
#   - sessions check fires before the .rite/worktrees/ check (independent leak surface)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"

GHC="$SCRIPT_DIR/../scripts/gitignore-health-check.sh"

cleanup_dirs=()
# `return 0` so an empty array (loop body `[ -n "" ]` → rc 1) does not become the
# script exit code via the EXIT trap (bash propagates the trap's last rc).
cleanup() { local d; for d in "${cleanup_dirs[@]:-}"; do [ -n "$d" ] && rm -rf "$d"; done; return 0; }
trap cleanup EXIT

# Build a sandbox repo with a given rite-config.yml + .gitignore, run the check,
# and publish the result via globals RUN_RC / RUN_OUT. Called WITHOUT command
# substitution so `cleanup_dirs+=` lands in the parent shell (a `$(run_case ...)`
# wrapper would lose the push in the subshell and leak sandboxes).
NESTED_OK=$'*\n!wiki/\n!wiki/**\n'
run_case() {
  local config="$1" gitignore="$2" nested="${3-$NESTED_OK}" d
  d=$(make_sandbox)
  cleanup_dirs+=("$d")
  printf '%s' "$config" > "$d/rite-config.yml"
  printf '%s' "$gitignore" > "$d/.gitignore"
  if [ "$nested" != "NONE" ]; then
    mkdir -p "$d/.rite"
    printf '%s' "$nested" > "$d/.rite/.gitignore"
  fi
  RUN_RC=0
  RUN_OUT=$(cd "$d" && bash "$GHC" --quiet 2>&1) || RUN_RC=$?
}

WIKI_OK=$'wiki:\n  enabled: true\n  branch_strategy: separate_branch\n'
WIKI_OFF=$'wiki:\n  enabled: false\n'
MS_ON=$'multi_session:\n  enabled: true\n  worktree_base: ".rite/worktrees"\n'
MS_OFF=$'multi_session:\n  enabled: false\n'
GI_WIKI=$'.rite/wiki/\n'
GI_WIKI_SESS=$'.rite/wiki/\n.rite/sessions/\n'

echo "=== TC-1: nested .rite/.gitignore missing → nested drift (exit 1) ==="
run_case "${WIKI_OK}${MS_OFF}" "$GI_WIKI" NONE
assert "TC-1 exit 1" "1" "$RUN_RC"
case "$RUN_OUT" in
  *"DRIFT DETECTED (nested)"*) pass "TC-1 nested missing drift emitted" ;;
  *) fail "TC-1 nested drift message missing: $RUN_OUT" ;;
esac

echo "=== TC-2: nested 3-line (ms off) → healthy (exit 0) ==="
run_case "${WIKI_OK}${MS_OFF}" $'# no root rite runtime rules\n'
assert "TC-2 exit 0" "0" "$RUN_RC"

echo "=== TC-3: nested star-only → composition drift (exit 1) ==="
run_case "${WIKI_OK}${MS_OFF}" $'# none\n' $'*\n'
assert "TC-3 exit 1" "1" "$RUN_RC"
case "$RUN_OUT" in
  *"DRIFT DETECTED (nested)"*) pass "TC-3 star-only composition drift emitted" ;;
  *) fail "TC-3 composition drift message missing: $RUN_OUT" ;;
esac

echo "=== TC-4: wiki disabled + nested missing → still nested drift (exit 1) ==="
run_case "${WIKI_OFF}${MS_OFF}" $'# no rules\n' NONE
assert "TC-4 exit 1 (check not gated on wiki.enabled)" "1" "$RUN_RC"

echo "=== TC-5: wiki disabled + nested 3-line → healthy (exit 0) ==="
run_case "${WIKI_OFF}${MS_OFF}" $'# none\n'
assert "TC-5 exit 0" "0" "$RUN_RC"

echo "=== TC-7: nested 3-line, empty root gitignore → healthy (exit 0) ==="
run_case "${WIKI_OFF}${MS_OFF}" $'\n'
assert "TC-7 exit 0 (nested covers sessions)" "0" "$RUN_RC"

echo "=== TC-8: ms enabled + nested 3-line → sessions/worktrees healthy (exit 0) ==="
run_case "${WIKI_OFF}${MS_ON}" $'\n'
assert "TC-8 exit 0 (nested covers both probes)" "0" "$RUN_RC"

echo "=== TC-9: nested line order swapped → composition drift (exit 1) ==="
run_case "${WIKI_OK}${MS_OFF}" $'\n' $'!wiki/\n*\n!wiki/**\n'
assert "TC-9 exit 1 (order is part of composition)" "1" "$RUN_RC"
case "$RUN_OUT" in
  *"DRIFT DETECTED (nested)"*) pass "TC-9 nested order drift emitted" ;;
  *) fail "TC-9 nested order drift message missing: $RUN_OUT" ;;
esac

echo "=== TC-6: nested missing fires before sessions/worktrees ==="
run_case "${WIKI_OK}${MS_ON}" "$GI_WIKI" NONE
assert "TC-6 exit 1" "1" "$RUN_RC"
case "$RUN_OUT" in
  *"DRIFT DETECTED (nested)"*) pass "TC-6 nested drift fires first" ;;
  *) fail "TC-6 expected nested drift first, got: $RUN_OUT" ;;
esac

print_summary "$(basename "$0")" \
  "Drift hint: gitignore-health-check.sh always-on .rite/sessions/ check — runs before the wiki early-exits and is NOT gated on multi_session.enabled."
