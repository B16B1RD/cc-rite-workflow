#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)
audit="$ROOT/plugins/rite/skills/pr-review/references/promotion-audit-2167.md"
reviewer="$ROOT/plugins/rite/agents/_reviewer-base.md"
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

assert_section_equals() {
  local label=$1 file=$2 start=$3 end=$4 expected=$5 actual
  actual=$(awk -v start="$start" -v end="$end" \
    'index($0, start) == 1 { capture=1 }
     capture && index($0, end) == 1 { exit }
     capture' "$file")
  if [ "$actual" = "$expected" ]; then
    printf 'PASS: %s\n' "$label"
  else
    printf 'FAIL: %s\n' "$label" >&2
    failures=$((failures + 1))
  fi
}

assert_grep 'audit records six promotions' "$audit" \
  'Six pages add missing detection work'
assert_grep 'audit records two shelves' "$audit" \
  'Two pages are shelved'
assert_grep 'anchor portability is promoted' "$audit" \
  '| `dogfooding-anchor-hardcode` | mechanized here |'
assert_grep 'helper aggregation is promoted' "$audit" \
  '| `dry-helper-aggregation-effect-overstate` | mechanized here |'
assert_grep 'provenance is promoted' "$audit" \
  '| `multi-pr-provenance-aggregation-error` | mechanized here |'
assert_grep 'prose-only design is shelved with enforcement' "$audit" \
  '| `prose-design-without-backing-implementation` | shelved as already mechanized |'
assert_grep 'counterfactual justification is promoted' "$audit" \
  '| `result-based-justification-logical-fallacy` | mechanized here |'
assert_grep 'gh query semantics is promoted' "$audit" \
  '| `gh-pr-list-related-pr-resolution` | mechanized here |'
assert_grep 'success predicate is promoted' "$audit" \
  '| `cwd-corruption-success-check-exit-code-and-nonempty` | mechanized here |'
assert_grep 'mechanical contracts are shelved with enforcement' "$audit" \
  '| `mechanical-test-over-declarative-invariant` | shelved as already mechanized |'

assert_grep 'consumer mutation checks distribution' "$reviewer" \
  'prove that the anchor is distributed or'
assert_grep 'consumer mutation has portable fallback' "$reviewer" \
  'anchor-independent, user-visible fallback'
assert_grep 'aggregation names residual distribution' "$reviewer" \
  'schemas, defaults, or callers remain distributed'
assert_grep 'aggregation sweeps old callers' "$reviewer" \
  'implementation to verify migration completeness'
assert_grep 'provenance uses pickaxe per literal' "$reviewer" \
  'use `git log -S` for each'
assert_grep 'counterfactual compares branch outcomes' "$reviewer" \
  'branch outcome and verify that swapping the stages'
mechanical_contract=$(printf '%s\n' \
  '7. **Counterfactual and executable backing**: Trace every changed claim that an' \
  '   ordering, guard, marker, or invariant changes behavior to its executable' \
  '   producer and consumer. For an ordering justification, write down each' \
  '   branch outcome and verify that swapping the stages really changes the stated' \
  '   result; shared accept or reject outcomes do not prove deterioration. When an' \
  '   invariant is mechanically expressible, require a test that fails when the' \
  "   invariant is broken and treat the test's green result as the contract instead" \
  '   of adding another cross-axis prose mapping.')
assert_section_equals 'counterfactual and mechanical contract is exact' "$reviewer" \
  '7. **Counterfactual and executable backing**:' \
  '8. **Command and query semantics**:' "$mechanical_contract"
assert_grep 'query semantics rejects wildcard exact match' "$reviewer" \
  'exact-match option; fetch the required state range'
assert_grep 'query semantics filters structured output' "$reviewer" \
  'structured field client-side'
assert_grep 'success preserves producer status' "$reviewer" \
  "preserve each producer's exit status"
assert_grep 'success rejects empty required values' "$reviewer" \
  'values before comparing them. Equality of two empty strings'
assert_grep 'empty equality is not success' "$reviewer" \
  'of success. When cwd or another prerequisite can disappear'
assert_grep 'shared checklist maps all promoted checks' "$reviewer" \
  'consumer portability, aggregation/provenance claims, counterfactual and'
assert_grep 'audit keeps measured classification boundary' "$audit" \
  'classification remains the responsibility of the measured-confirmed gate'

if [ "$failures" -ne 0 ]; then
  printf '%s contract assertion(s) failed\n' "$failures" >&2
  exit 1
fi

printf 'All contract and provenance promotion assertions passed.\n'
