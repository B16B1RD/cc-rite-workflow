#!/bin/bash
# impact-scan preserves grep results, diagnostics and temporary-file cleanup.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"
STEP="$SCRIPT_DIR/../../scripts/fix-step.sh"

fixture=$(mktemp -d) || exit 1
trap 'rm -rf "$fixture"' EXIT
git init -q "$fixture" || exit 1
mkdir -p "$fixture/tests" "$fixture/tmp"
# Keep four matching lines whether the native ERE treats \b as a word
# boundary or a literal b; this test covers output, not regex portability.
printf 'scan_target() { :; } # bscan_targetb\nscan_target # bscan_targetb\n' > "$fixture/caller.sh"
printf 'scan_target # bscan_targetb\n' > "$fixture/tests/caller.test.sh"
printf '# scan_target bscan_targetb\n' > "$fixture/usage.md"
git -C "$fixture" add caller.sh tests/caller.test.sh usage.md || exit 1
cd "$fixture" || exit 1
export TMPDIR="$fixture/tmp"

git grep -nE '\bscan_target\b' -- \
  '*.ts' '*.tsx' '*.js' '*.jsx' '*.py' '*.rb' '*.go' '*.rs' \
  '*.sh' '*.bash' '*.md' '*.yml' '*.yaml' '*.json' > expected || exit 1
assert "fixture has four matching lines" "4" "$(wc -l < expected | tr -d ' ')"
bash "$STEP" impact-scan --symbol scan_target > stdout 2> stderr
assert "matches return success" "0" "$?"
if cmp -s expected stdout; then
  pass "all path:line:content matches reach stdout unchanged"
else
  fail "all path:line:content matches reach stdout unchanged"
  diff -u expected stdout || true
fi
assert "matches have no diagnostics" "" "$(cat stderr)"
assert "matches leave no temporary files" "" "$(ls -A "$TMPDIR")"

bash "$STEP" impact-scan --symbol no_such_scan_symbol > stdout 2> stderr
assert "no match returns success" "0" "$?"
assert "no match has empty stdout" "" "$(cat stdout)"
assert "no match has empty stderr" "" "$(cat stderr)"
assert "no match leaves no temporary files" "" "$(ls -A "$TMPDIR")"

# Invalid regex exercises a real grep failure while staying in a checkout.
git grep -nE '\b[\b' -- '*.sh' > grep-stdout 2> grep-stderr
grep_rc=$?
if [ "$grep_rc" -ge 2 ]; then
  pass "invalid regex produces a grep error"
else
  fail "invalid regex produces a grep error"
fi
bash "$STEP" impact-scan --symbol '[' > stdout 2> stderr
assert "grep error remains non-blocking" "0" "$?"
assert "grep error has empty stdout" "" "$(cat stdout)"
assert_grep "grep error reports its exit code" stderr "^WARNING: git grep failed \\(rc=$grep_rc\\):"
assert_grep "grep error reports degraded context" stderr "^\\[CONTEXT\\] IMPACT_SCAN_DEGRADED=1; reason=git_grep_rc_$grep_rc$"
assert_grep "grep error requests manual verification" stderr "影響範囲を手動確認"
assert "grep error leaves no temporary files" "" "$(ls -A "$TMPDIR")"

print_summary "$(basename "$0")" || exit 1
