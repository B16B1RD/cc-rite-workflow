#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)
audit="$ROOT/plugins/rite/skills/pr-review/references/promotion-audit-2165.md"
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

assert_grep 'all pages use the shared gate' "$audit" 'The shared enforcement point is the Defense Mechanism Integrity Gate'
assert_grep 'precondition page mechanized' "$audit" '| `silent-precondition-omit-disables-and-defense-chain` | mechanized here |'
assert_grep 'latest sibling page mechanized' "$audit" '| `new-script-inherits-latest-sibling-defenses` | mechanized here |'
assert_grep 'defect class page mechanized' "$audit" '| `single-condition-defense-vs-defect-class` | mechanized here |'
assert_grep 'fallback visibility page mechanized' "$audit" '| `silent-fallback-observability-via-debug-log` | mechanized here |'
assert_grep 'structural enforcement page mechanized' "$audit" '| `structural-guarantee-code-level-enforcement` | mechanized here |'

assert_grep 'gate is mandatory detection work' "$reviewer" 'This gate is part of the Detection Process'
assert_grep 'producer sites must be enumerated' "$reviewer" 'the producer and patch sites'
assert_grep 'natural entrypoint is statically traced' "$reviewer" 'Statically trace at least one natural'
assert_grep 'PR-controlled code execution is forbidden' "$reviewer" 'Do not execute PR-controlled code'
assert_grep 'runtime execution requires isolation' "$reviewer" 'removes secrets, network access, and write access outside a disposable tree'
assert_grep 'latest sibling history is inspected' "$reviewer" '`git log -S` or `git log -p`'
assert_grep 'hardening target omission is detected' "$reviewer" 'A filename allowlist that omits the new sibling is a finding'
assert_grep 'defect class must be abstracted' "$reviewer" 'to its defect class and test representative adjacent members'
assert_grep 'class predicate preferred' "$reviewer" 'Prefer a class predicate'
assert_grep 'fail fast precedes fallback' "$reviewer" 'First apply [Fail-Fast First](#fail-fast-first)'
assert_grep 'fallback preserves bounded diagnostics' "$reviewer" 'preserve the exit code and a bounded diagnostic'
assert_grep 'resource-changing fallback is always visible' "$reviewer" 'or state file requires an always-visible'
assert_grep 'fallback policy covers every caller' "$reviewer" 'policy to every matching caller found by `Grep`'
assert_grep 'structural invariant has explicit check' "$reviewer" 'explicit check at the trust or'
assert_grep 'structural test covers three outcomes' "$reviewer" 'Pin expected accept, expected reject, and documented'
assert_grep 'finding remains evidence gated' "$reviewer" 'do not report speculative family-wide hardening without such evidence'
assert_grep 'shared checklist maps the detection gate' "$reviewer" '**Defense mechanism integrity (when triggered)**'

if [ "$failures" -ne 0 ]; then
  printf '%s contract assertion(s) failed\n' "$failures" >&2
  exit 1
fi

printf 'All defense mechanism promotion contract assertions passed.\n'
