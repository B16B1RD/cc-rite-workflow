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

assert_grep 'aggregate recommendation shelved' "$audit" '| `aggregate-recommendation-label-evasion` | shelve — already mechanized | recommendation classification and disposition gate |'
assert_grep 'fix drift shelved' "$audit" '| `fix-induced-drift-in-cumulative-defense` | shelve — already mechanized | `review-trend-divergence.sh` and the `iterate` circuit breaker |'
assert_grep 'likelihood evidence routed to follow-up' "$audit" '| `reviewer-likelihood-evidence-omission-induces-mechanical-demotion` | follow-up — producer enforcement incomplete |'
assert_grep 'convention escalation shelved' "$audit" '| `convention-escalation-has-no-terminus` | shelve — already mechanized | structured review JSON, helper gates, and fail-loud enum validation |'
assert_grep 'differential scope routed to follow-up' "$audit" '| `differential-scope-review-blind-outside-diff` | follow-up — post-breaker full pass not enforced |'
assert_grep 'scope split mechanized' "$audit" '| `reviewer-scope-split-escalates-to-user` | mechanized here | Scope Split Gate below and `pr-review/SKILL.md` |'
assert_grep 'scope rejection mechanized' "$audit" '| `scope-creep-rejection-empirical-gate` | mechanized here | Rejection Evidence Gate below and `fix/SKILL.md` |'
assert_grep 'error-path regression mechanized' "$audit" '| `bugfix-new-error-path-needs-regression-test` | mechanized here | New Error-Path Regression Gate in reviewer prompts |'

assert_grep 'scope split detects both scopes' "$review" 'same root cause is assigned both `current-pr` and `follow-up` scope'
assert_grep 'scope split forbids mechanical collapse' "$review" 'severity の高い側・多数派へ機械統合しない'
assert_grep 'scope split uses debate first' "$review" 'debate で consensus に至らなければ treatment をユーザーへエスカレート'
assert_grep 'scope split records decision' "$review" '選択した disposition を Decision Log に記録する'
assert_grep 'follow-up semantics preserved' "$review" 'durable な follow-up Issue / destination が作成または指定されるまで解決済みにしない'
assert_grep 'rejection evidence gate wired' "$fix" 'Rejection Evidence Gate (state mutation 前)'
assert_grep 'rejection reasons pinned' "$fix" '`scope-creep` / `out-of-scope` / `minor` / `user-override`'
assert_grep 'rejection classification required' "$fix" '構造化 enum から必ず選択'
assert_grep 'cross-validation required' "$fix" '別 reviewer の cross-validation'
assert_grep 'counterfactual evidence required' "$fix" 'empirical counterfactual/revert test'
assert_grep 'both rejection artifacts required' "$fix" '両方の artifact を Decision Log に記録する'
assert_grep 'invalid rejection cannot mutate' "$fix" '`status = acknowledged` override・reply・fingerprint block・commit trailer の**いずれにも到達せず**'
assert_grep 'user override is not bypass' "$fix" '`user-override` も evidence gate の例外ではない'
assert_grep 'test reviewer checks new error paths' "$test_reviewer" 'non-vacuity check'
assert_grep 'test reviewer requires exact branch' "$test_reviewer" 'enters that exact new branch'
assert_grep 'test reviewer requires observable outcome' "$test_reviewer" 'asserts the observable outcome'
assert_grep 'test reviewer requires mutation failure' "$test_reviewer" 'equivalent mutation) must make the new test fail'
assert_grep 'error reviewer checks regression proof' "$error_reviewer" 'Regression proof for newly added paths'
assert_grep 'error reviewer reports missing proof' "$error_reviewer" 'Report missing proof as a current-PR finding'

gate_line=$(grep -n 'Rejection Evidence Gate (state mutation 前)' "$fix" | head -1 | cut -d: -f1)
mutation_line=$(grep -n 'finding state の override' "$fix" | head -1 | cut -d: -f1)
persist_line=$(grep -n 'accept fingerprint 永続化' "$fix" | head -1 | cut -d: -f1)
if [ -n "$gate_line" ] && [ -n "$mutation_line" ] && [ -n "$persist_line" ] \
  && [ "$gate_line" -lt "$mutation_line" ] && [ "$gate_line" -lt "$persist_line" ]; then
  printf 'PASS: rejection gate precedes mutation and persistence\n'
else
  printf 'FAIL: rejection gate must precede mutation and persistence\n' >&2
  failures=$((failures + 1))
fi

if [ "$failures" -ne 0 ]; then
  printf '%s contract assertion(s) failed\n' "$failures" >&2
  exit 1
fi

printf 'All review/fix promotion contract assertions passed.\n'
