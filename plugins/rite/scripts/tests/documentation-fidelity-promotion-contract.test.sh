#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)
audit="$ROOT/plugins/rite/skills/pr-review/references/promotion-audit-2166.md"
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

assert_grep 'audit routes all pages to the shared gate' "$audit" \
  'All four are mechanized by the shared Documentation Fidelity Gate'
assert_grep 'pivot page mechanized' "$audit" \
  '| `design-pivot-stale-cross-reference-comment` | mechanized here |'
assert_grep 'recovery page mechanized' "$audit" \
  '| `recovery-command-verified-in-human-execution-context` | mechanized here |'
assert_grep 'citation page mechanized' "$audit" \
  '| `references-extraction-content-fidelity` | mechanized here |'
assert_grep 'sample page mechanized' "$audit" \
  '| `canonical-reference-sample-code-strict-sync` | mechanized here |'

assert_grep 'gate is mandatory detection work' "$reviewer" \
  'This gate is mandatory detection work'
assert_grep 'pivot sweeps old vocabulary' "$reviewer" \
  '`Grep` the old vocabulary'
assert_grep 'pivot covers explanatory references' "$reviewer" \
  'complete changed files and their explanatory'
assert_grep 'recovery uses recipient context' "$reviewer" \
  'human recipient will actually run it'
assert_grep 'recovery requires canonical helpers' "$reviewer" \
  'their canonical helpers, require the intended target'
assert_grep 'recovery checks target existence' "$reviewer" \
  'require the intended target to exist before mutation'
assert_grep 'recovery checks self-deleting chains' "$reviewer" \
  'does not delete its own cwd'
assert_grep 'wrong-target rc zero is rejected' "$reviewer" \
  '`rc=0` against a different target is not success'
assert_grep 'citation reads source' "$reviewer" \
  'cited source and use an exact `Grep` anchor'
assert_grep 'citation needs exact anchor' "$reviewer" \
  'use an exact `Grep` anchor'
assert_grep 'path existence is insufficient' "$reviewer" \
  'Path existence alone is insufficient'
assert_grep 'sample comparison is verbatim' "$reviewer" \
  'compare the complete blocks verbatim'
assert_grep 'sample comparison includes caller contract' "$reviewer" \
  'prerequisites supplied by the caller'
assert_grep 'nonidentical samples narrow their claim' "$reviewer" \
  'narrow the claim instead of saying "verbatim" or "identical"'
assert_grep 'findings remain evidence gated' "$reviewer" \
  'or sample fails one of these checks'
assert_grep 'shared checklist maps the gate' "$reviewer" \
  '**Documentation fidelity (when triggered)**'

if [ "$failures" -ne 0 ]; then
  printf '%s contract assertion(s) failed\n' "$failures" >&2
  exit 1
fi

printf 'All documentation fidelity promotion contract assertions passed.\n'
