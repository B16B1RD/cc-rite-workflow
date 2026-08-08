#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)
audit="$ROOT/plugins/rite/skills/pr-review/references/promotion-audit-2091.md"
review="$ROOT/plugins/rite/skills/pr-review/SKILL.md"
fix="$ROOT/plugins/rite/skills/fix/SKILL.md"
test_reviewer="$ROOT/plugins/rite/agents/test-reviewer.md"
error_reviewer="$ROOT/plugins/rite/agents/error-handling-reviewer.md"
failures=0

assert_grep() {
  local label=$1 file=$2 pattern=$3
  if grep -Fq -- "$pattern" "$file"; then
    printf 'PASS: %s\n' "$label"
  else
    printf 'FAIL: %s\n' "$label" >&2
    failures=$((failures + 1))
  fi
}

for page in \
  aggregate-recommendation-label-evasion \
  fix-induced-drift-in-cumulative-defense \
  reviewer-likelihood-evidence-omission-induces-mechanical-demotion \
  convention-escalation-has-no-terminus \
  differential-scope-review-blind-outside-diff \
  reviewer-scope-split-escalates-to-user \
  scope-creep-rejection-empirical-gate \
  bugfix-new-error-path-needs-regression-test
do
  assert_grep "audit decision: $page" "$audit" "$page"
done

assert_grep 'scope split gate wired' "$review" '5.1.2.S Scope Split Gate'
assert_grep 'follow-up semantics preserved' "$review" 'durable な follow-up Issue'
assert_grep 'rejection evidence gate wired' "$fix" '**Rejection Evidence Gate**'
assert_grep 'counterfactual evidence required' "$fix" 'empirical counterfactual/revert test'
assert_grep 'test reviewer checks new error paths' "$test_reviewer" 'non-vacuity check'
assert_grep 'error reviewer checks regression proof' "$error_reviewer" 'Regression proof for newly added paths'

if [ "$failures" -ne 0 ]; then
  printf '%s contract assertion(s) failed\n' "$failures" >&2
  exit 1
fi

printf 'All review/fix promotion contract assertions passed.\n'
