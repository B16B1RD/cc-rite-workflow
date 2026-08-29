#!/bin/bash
# Tests for gitignore-health-check.sh multi_session check.
#
# Verifies the non-blocking, opt-in `.rite/worktrees/` ignore check folded into
# gitignore-health-check.sh (multi-session design §2):
#   - multi_session.enabled=true + .rite/worktrees/ NOT ignored  → drift (exit 1)
#   - multi_session.enabled=true + .rite/worktrees/ ignored       → healthy (exit 0)
#   - multi_session.enabled=false                                 → no-op (exit 0)
#   - wiki.enabled=false + multi_session.enabled=true             → still checked
#     (the check runs BEFORE the wiki early-exits, so it is not gated on wiki).
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
# All fixtures include `.rite/sessions/` so the always-on sessions check
# passes and these cases test the `.rite/worktrees/` behavior in isolation.
# The dedicated sessions drift behavior lives in gitignore-health-check-sessions.test.sh.
GI_WIKI=$'.rite/wiki/\n.rite/sessions/\n'
GI_WIKI_WT=$'.rite/wiki/\n.rite/worktrees/\n.rite/sessions/\n'

echo "=== TC-1: ms enabled + nested missing → nested drift (exit 1) ==="
run_case "${WIKI_OK}${MS_ON}" "$GI_WIKI" NONE
assert "TC-1 exit 1" "1" "$RUN_RC"
case "$RUN_OUT" in
  *"DRIFT DETECTED (nested)"*) pass "TC-1 nested drift message emitted" ;;
  *) fail "TC-1 drift message missing: $RUN_OUT" ;;
esac

echo "=== TC-2: ms enabled + nested 3-line → healthy (exit 0) ==="
run_case "${WIKI_OK}${MS_ON}" $'\n'
assert "TC-2 exit 0" "0" "$RUN_RC"

echo "=== TC-3: ms disabled + nested 3-line → healthy (exit 0) ==="
run_case "${WIKI_OK}${MS_OFF}" $'\n'
assert "TC-3 exit 0" "0" "$RUN_RC"

echo "=== TC-4: wiki disabled + ms enabled + nested missing → still nested drift (exit 1) ==="
run_case "${WIKI_OFF}${MS_ON}" $'# no rules\n' NONE
assert "TC-4 exit 1 (check not gated on wiki.enabled)" "1" "$RUN_RC"

echo "=== TC-5: wiki disabled + ms enabled + nested 3-line → healthy (exit 0) ==="
run_case "${WIKI_OFF}${MS_ON}" $'\n'
assert "TC-5 exit 0" "0" "$RUN_RC"

echo "=== TC-6: ms enabled + nested 3-line, empty root → healthy (exit 0) ==="
run_case "${WIKI_OFF}${MS_ON}" $'\n'
assert "TC-6 exit 0 (nested covers worktrees)" "0" "$RUN_RC"

echo "=== TC-7: nested missing !wiki/** → composition drift (exit 1) ==="
run_case "${WIKI_OK}${MS_ON}" $'\n' $'*\n!wiki/\n'
assert "TC-7 exit 1 (missing !wiki/** is not healthy)" "1" "$RUN_RC"
case "$RUN_OUT" in
  *"DRIFT DETECTED (nested)"*) pass "TC-7 nested composition drift emitted" ;;
  *) fail "TC-7 nested composition drift message missing: $RUN_OUT" ;;
esac

print_summary "$(basename "$0")" \
  "Drift hint: gitignore-health-check.sh multi_session check (design §2) — runs before the wiki early-exits, opt-in via multi_session.enabled."
