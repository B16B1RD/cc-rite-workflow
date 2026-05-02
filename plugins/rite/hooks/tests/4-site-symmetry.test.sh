#!/bin/bash
# Tests for 4-site bash literal symmetry across the create-interview workflow
# (Issue #771 / parent #768 P4-12)
#
# Purpose:
#   The /rite:issue:create workflow maintains symmetric bash literals
#   (`flow-state-update.sh patch --phase X --active true --next "..." --preserve-error-count`)
#   across multiple sites that must stay in lockstep. Past incidents
#   (#525 / #552 / #561 / #622 / #634 / #651 / #660) have repeatedly shown that
#   片肺更新 drift in any one site causes either:
#     - error_count reset loop (verified-review cycle 3 F-01) when --preserve-error-count
#       is dropped from one occurrence
#     - active=false residue causing stop-guard early return (Issue #660) when --active true
#       is dropped
#
#   The canonical anchor is the "DRIFT-CHECK ANCHOR (semantic, 4-site)" comment
#   in `commands/issue/create.md` which enumerates the 4 sites:
#     (1) create.md 🚨 Mandatory After Interview Step 0
#     (2) create-interview.md 🚨 MANDATORY Pre-flight
#     (3) create-interview.md Return Output re-patch
#     (4) stop-guard.sh `create_post_interview` case arm WORKFLOW_HINT
#
# Scope adjustment for current implementation (per Issue #771 R1/R2 mitigation):
#   - SCOPE: `commands/issue/create.md` and `commands/issue/create-interview.md`
#     are the 2 actual files containing the 4-arg bash literal symmetry. Each file
#     hosts 2 occurrences (Step 0 + Step 1 in create.md; Pre-flight + Return Output
#     re-patch in create-interview.md), totaling the 4 occurrences described in
#     the canonical anchor.
#   - OUT OF SCOPE — `stop-guard.sh`: file does not exist as of Issue #771 work
#     (verified 2026-05-03). The DRIFT-CHECK ANCHOR references it as a future site.
#     When the file is added, extend `SITES` below to include it.
#   - OUT OF SCOPE — `phase-transition-whitelist.sh`: this is a sourced library
#     that does NOT accept `--phase` / `--active` / `--next` / `--preserve-error-count`
#     as CLI arguments (it stores phase names in associative arrays). Including it
#     in this CLI-arg symmetry test would produce false negatives. A separate
#     test for phase-name registration (e.g., `create_post_interview` is whitelisted)
#     is a different concern handled elsewhere if needed.
#
# Test cases:
#   For each (site, arg) pair in SITES × REQUIRED_ARGS, assert that grep -cE
#   reports >= 1. Coarse drift detector (won't catch removal from one occurrence
#   if other occurrences in the same file remain) but matches the granularity
#   anticipated by Issue #771 pseudo code.
#
# When this test fails:
#   The 4-site bash literal symmetry has drifted. Locate the failing (file, arg)
#   pair, inspect the DRIFT-CHECK ANCHOR comments in create.md / create-interview.md
#   for guidance, and restore the missing argument. Do NOT relax the test to make
#   it pass — symmetry restoration is the correct fix.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

SITES=(
  "plugins/rite/commands/issue/create.md"
  "plugins/rite/commands/issue/create-interview.md"
)

REQUIRED_ARGS=(
  "--phase"
  "--active"
  "--next"
  "--preserve-error-count"
)

PASS=0
FAIL=0
FAILED_NAMES=()

assert_arg_present() {
  local site="$1" arg="$2"
  local count
  count=$(grep -cE -- "$arg" "$REPO_ROOT/$site" 2>/dev/null || true)
  count=${count:-0}
  if [ "$count" -ge 1 ]; then
    echo "  ✅ $site: $arg (count=$count)"
    PASS=$((PASS + 1))
  else
    echo "  ❌ $site: $arg (count=0, expected >= 1)"
    FAIL=$((FAIL + 1))
    FAILED_NAMES+=("$site|$arg")
  fi
}

for arg in "${REQUIRED_ARGS[@]}"; do
  echo "=== Checking: $arg present in all sites ==="
  for site in "${SITES[@]}"; do
    if [ ! -f "$REPO_ROOT/$site" ]; then
      echo "  ❌ $site: FILE NOT FOUND"
      FAIL=$((FAIL + 1))
      FAILED_NAMES+=("$site|FILE_NOT_FOUND")
      continue
    fi
    assert_arg_present "$site" "$arg"
  done
done

echo
echo "─── $(basename "$0") summary ──────────────────────"
echo "PASS: $PASS"
echo "FAIL: $FAIL"

if [ "$FAIL" -ne 0 ]; then
  echo "Failed assertions:"
  for n in "${FAILED_NAMES[@]}"; do
    echo "  - $n"
  done
  echo
  echo "⚠️ 4-site bash literal symmetry drift detected."
  echo "   Locate the failing (file, arg) pair above and inspect the"
  echo "   'DRIFT-CHECK ANCHOR (semantic, 4-site)' comments in"
  echo "   commands/issue/create.md and commands/issue/create-interview.md."
  echo "   Restore the missing --phase / --active / --next / --preserve-error-count"
  echo "   argument so the canonical bash literals stay in lockstep."
  exit 1
fi

echo "OK: 4-site symmetry verified"
exit 0
