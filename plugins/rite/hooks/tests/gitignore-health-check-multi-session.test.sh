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

# F-02: nested comparison is $state_root/.rite/.gitignore (main checkout), not
# the linked worktree's show-toplevel. Invoke without --repo-root (lint Phase 3.5
# argv). Root .gitignore isolates sessions/worktrees so those later checks do
# not mix with nested findings. worktree must carry rite-config.yml (config
# missing skips before nested compare).
HOOKS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
GI_SESS_WT=$'.rite/sessions/\n.rite/worktrees/\n'

setup_linked_worktree_case() {
  local wt_nested="$1"
  d=$(make_sandbox)
  cleanup_dirs+=("$d")
  printf '%s' "${WIKI_OK}${MS_ON}" > "$d/rite-config.yml"
  printf '%s' "$GI_SESS_WT" > "$d/.gitignore"
  mkdir -p "$d/.rite"
  printf '%s' "$NESTED_OK" > "$d/.rite/.gitignore"
  wt=$(mktemp -d)
  cleanup_dirs+=("$wt")
  git -C "$d" worktree add --detach "$wt" HEAD >/dev/null
  printf '%s' "${WIKI_OK}${MS_ON}" > "$wt/rite-config.yml"
  printf '%s' "$GI_SESS_WT" > "$wt/.gitignore"
  mkdir -p "$wt/.rite"
  if [ "$wt_nested" = "NONE" ]; then
    rm -f "$wt/.rite/.gitignore"
  else
    printf '%s' "$wt_nested" > "$wt/.rite/.gitignore"
  fi
}

echo "=== TC-8: linked worktree missing nested, main 3-line → findings 0 ==="
setup_linked_worktree_case NONE
RUN_RC=0
RUN_OUT=$(cd "$wt" && bash "$GHC" --quiet 2>&1) || RUN_RC=$?
assert "TC-8 exit 0" "0" "$RUN_RC"
case "$RUN_OUT" in
  *"Total gitignore-health-check findings: 0"*) pass "TC-8 findings 0" ;;
  *) fail "TC-8 expected findings 0, got: $RUN_OUT" ;;
esac
case "$RUN_OUT" in
  *"DRIFT DETECTED (nested)"*) fail "TC-8 must not nested-drift: $RUN_OUT" ;;
  *"rite-config.yml not found"*) fail "TC-8 skipped on missing config: $RUN_OUT" ;;
  *) pass "TC-8 no nested drift / no config skip" ;;
esac
git -C "$d" worktree remove --force "$wt" >/dev/null 2>&1 || true

echo "=== TC-9: linked worktree wrong nested, main 3-line → findings 0 ==="
setup_linked_worktree_case $'*\n'
RUN_RC=0
RUN_OUT=$(cd "$wt" && bash "$GHC" --quiet 2>&1) || RUN_RC=$?
assert "TC-9 exit 0 (does not read worktree nested file)" "0" "$RUN_RC"
case "$RUN_OUT" in
  *"Total gitignore-health-check findings: 0"*) pass "TC-9 findings 0" ;;
  *) fail "TC-9 expected findings 0, got: $RUN_OUT" ;;
esac
case "$RUN_OUT" in
  *"DRIFT DETECTED (nested)"*) fail "TC-9 must not nested-drift on worktree file: $RUN_OUT" ;;
  *) pass "TC-9 ignores worktree nested composition" ;;
esac
git -C "$d" worktree remove --force "$wt" >/dev/null 2>&1 || true

echo "=== TC-10: state-path-resolve failure is rc=2 findings unknown ==="
stub=$(mktemp -d)
cleanup_dirs+=("$stub")
mkdir -p "$stub/scripts"
cp "$GHC" "$stub/scripts/gitignore-health-check.sh"
ln -s "$HOOKS_DIR/control-char-neutralize.sh" "$stub/control-char-neutralize.sh"
ln -s "$HOOKS_DIR/gitignore-ensure.sh" "$stub/gitignore-ensure.sh"
printf '%s\n' '#!/bin/bash' 'exit 1' > "$stub/state-path-resolve.sh"
d10=$(make_sandbox)
cleanup_dirs+=("$d10")
printf '%s' "${WIKI_OK}${MS_ON}" > "$d10/rite-config.yml"
printf '%s' "$GI_SESS_WT" > "$d10/.gitignore"
mkdir -p "$d10/.rite"
printf '%s' "$NESTED_OK" > "$d10/.rite/.gitignore"
T10_RC=0
T10_OUT=$(cd "$d10" && bash "$stub/scripts/gitignore-health-check.sh" --quiet 2>&1) || T10_RC=$?
assert "TC-10 resolve failure exit 2" "2" "$T10_RC"
case "$T10_OUT" in
  *"state-path-resolve.sh failed"*) pass "TC-10 WARNING on resolve failure" ;;
  *) fail "TC-10 expected resolve WARNING, got: $T10_OUT" ;;
esac
case "$T10_OUT" in
  *"findings: unknown"*) pass "TC-10 findings unknown" ;;
  *) fail "TC-10 expected findings unknown, got: $T10_OUT" ;;
esac

echo "=== TC-11: worktree cwd, main nested broken → nested drift ==="
setup_linked_worktree_case "$NESTED_OK"
printf '%s' $'*\n' > "$d/.rite/.gitignore"
RUN_RC=0
RUN_OUT=$(cd "$wt" && bash "$GHC" --quiet 2>&1) || RUN_RC=$?
assert "TC-11 exit 1 (detects main nested drift from worktree cwd)" "1" "$RUN_RC"
case "$RUN_OUT" in
  *"DRIFT DETECTED (nested)"*) pass "TC-11 nested drift from state_root" ;;
  *) fail "TC-11 expected nested drift, got: $RUN_OUT" ;;
esac
git -C "$d" worktree remove --force "$wt" >/dev/null 2>&1 || true

print_summary "$(basename "$0")" \
  "Drift hint: gitignore-health-check.sh multi_session check (design §2) — runs before the wiki early-exits, opt-in via multi_session.enabled."
