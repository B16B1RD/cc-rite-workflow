#!/bin/bash
# caller-html-literal-symmetry.test.sh
#
# Tests for caller HTML inline literal symmetry across the
# create-interview.md example output blocks.
#
# Issue #832 — split out from the 4-site-symmetry concern as a
# dedicated lint script (option B in the Issue's three-way decision).
# Background: PR #830 removed the prose that documented this 2-site
# symmetry; this test restores machine-verifiable drift detection.
#
# Purpose:
#   The /rite:issue:create-interview sub-skill emits a return block
#   ending in one of two HTML-commented sentinels:
#     <!-- [interview:skipped] -->   (XS / Bug Fix / Chore preset)
#     <!-- [interview:completed] --> (S / M / L / XL after deep-dive)
#
#   Both example blocks (Output format example sections in
#   create-interview.md) must contain an *identical*
#   `<!-- caller: ... -->` line that instructs the orchestrator to
#   run a Step 0 Immediate Bash Action. The bash literal embedded in
#   that comment must match across both examples so that an LLM
#   reading either example sees the same contract.
#
#   This test verifies:
#     1. There are exactly 2 occurrences of `<!-- caller:` in
#        create-interview.md (one per example block).
#     2. The 2 occurrences are byte-equal (full-line equality).
#     3. The literal contains all 6 required elements:
#          bash plugins/rite/hooks/flow-state-update.sh patch
#          --phase create_post_interview
#          --active true
#          --next 'Step 0 Immediate Bash Action fired ...'
#          --if-exists
#          --preserve-error-count
#
# When this test fails:
#   The 2 example blocks have drifted, typically because someone
#   updated one block but missed the symmetric update in the other.
#   Restore symmetry by replicating the change across both blocks.
#   Do NOT relax this test — symmetry restoration is the correct fix.
#
# Relationship with `4-site-symmetry.test.sh`:
#   That test guards CLI-arg PRESENCE (--phase / --active / --next /
#   --preserve-error-count) at file-level grep granularity for the 2
#   files commands/issue/create.md and commands/issue/create-interview.md.
#   This test is narrower and stricter: full-line byte equality of the
#   2 caller HTML inline literals within create-interview.md alone.
#   The two are complementary; neither subsumes the other.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

TARGET="$REPO_ROOT/plugins/rite/commands/issue/create-interview.md"

PASS=0
FAIL=0
FAILED_NAMES=()

pass() { PASS=$((PASS + 1)); echo "  ✅ $1"; }
fail() { FAIL=$((FAIL + 1)); FAILED_NAMES+=("$1"); echo "  ❌ $1"; }

if [ ! -f "$TARGET" ]; then
  echo "  ❌ FILE NOT FOUND: $TARGET"
  exit 1
fi

echo "=== caller HTML inline literal occurrence count ==="
caller_count=$(grep -cF '<!-- caller:' "$TARGET" 2>/dev/null || true)
caller_count=${caller_count:-0}
if [ "$caller_count" -eq 2 ]; then
  pass "expected 2 caller-comment lines, found 2"
else
  fail "expected exactly 2 caller-comment lines, found $caller_count"
fi

echo
echo "=== caller HTML inline literal byte equality ==="
mapfile -t caller_lines < <(grep -F '<!-- caller:' "$TARGET")
if [ "${#caller_lines[@]}" -ge 2 ]; then
  if [ "${caller_lines[0]}" = "${caller_lines[1]}" ]; then
    pass "caller HTML inline literals are byte-identical across the 2 example blocks"
  else
    fail "caller HTML inline literals diverge between [interview:skipped] and [interview:completed] example blocks"
    echo "  --- skipped block caller literal ---" >&2
    echo "    ${caller_lines[0]}" >&2
    echo "  --- completed block caller literal ---" >&2
    echo "    ${caller_lines[1]}" >&2
  fi
else
  fail "fewer than 2 caller-comment lines extracted; cannot compare"
fi

echo
echo "=== required-element presence within the caller literal ==="
REQUIRED_ELEMENTS=(
  "bash plugins/rite/hooks/flow-state-update.sh patch"
  "--phase create_post_interview"
  "--active true"
  "--next 'Step 0 Immediate Bash Action fired"
  "--if-exists"
  "--preserve-error-count"
)
if [ "${#caller_lines[@]}" -ge 1 ]; then
  for needle in "${REQUIRED_ELEMENTS[@]}"; do
    if [[ "${caller_lines[0]}" == *"$needle"* ]]; then
      pass "caller literal contains: $needle"
    else
      fail "caller literal missing required element: $needle"
    fi
  done
else
  fail "no caller-comment line extracted; cannot verify required elements"
fi

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
  echo "⚠️ caller HTML inline literal symmetry drift detected."
  echo "   The 2 example output blocks in create-interview.md"
  echo "   ([interview:skipped] and [interview:completed]) must contain"
  echo "   an identical <!-- caller: ... --> line. Restore symmetry by"
  echo "   replicating the change across both example blocks."
  echo "   Do NOT relax this test."
  exit 1
fi

echo "OK: caller HTML inline literal symmetry verified"
exit 0
