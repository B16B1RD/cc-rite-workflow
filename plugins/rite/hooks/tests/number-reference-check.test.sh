#!/bin/bash
# Tests for number-reference-check.sh
# Guards the Issue/PR number-free surface (CHANGELOG, lint.md) against recurrence.
# Usage: bash plugins/rite/hooks/tests/number-reference-check.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
TARGET="$SCRIPT_DIR/../scripts/number-reference-check.sh"
TEST_DIR="$(mktemp -d)"
PASS=0
FAIL=0

cleanup() { rm -rf "$TEST_DIR"; }
trap 'rc=$?; cleanup; exit $rc' EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
trap 'cleanup; exit 129' HUP

pass() { PASS=$((PASS + 1)); echo "  ✅ PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ❌ FAIL: $1"; }

echo "=== number-reference-check.sh tests ==="
echo ""

mkdir -p "$TEST_DIR/plugins/rite/skills"
mkdir -p "$TEST_DIR/plugins/rite/hooks/tests"
(cd "$TEST_DIR" && git init -q 2>/dev/null || true)

run() { bash "$TARGET" --repo-root "$TEST_DIR" --target "$1" 2>&1; }
SAMPLE="plugins/rite/skills/sample.md"
SAMPLE_PATH="$TEST_DIR/$SAMPLE"

# --------------------------------------------------------------------------
# TC-001: No targets → exit 2 (usage error)
# --------------------------------------------------------------------------
echo "TC-001: no targets → exit 2"
rc=0; bash "$TARGET" --repo-root "$TEST_DIR" >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 2 ]; then pass "no targets → exit 2"
else fail "expected rc=2, got rc=$rc"; fi

# --------------------------------------------------------------------------
# TC-002 (T-02): a comment containing #1234 → warning (exit 1, reported)
# --------------------------------------------------------------------------
echo "TC-002 (T-02): #1234 in a comment → finding"
cat > "$SAMPLE_PATH" <<'MD'
# Fix the loader (#1234)
plain text
MD
rc=0; output=$(run "$SAMPLE") || rc=$?
if [ "$rc" -eq 1 ] && echo "$output" | grep -q '#1234'; then
  pass "#1234 detected as finding → exit 1"
else fail "expected rc=1 with #1234, got rc=$rc: $output"; fi

# --------------------------------------------------------------------------
# TC-003 (T-03): functional code / headings → no finding
# --------------------------------------------------------------------------
echo "TC-003 (T-03): functional code not detected"
cat > "$SAMPLE_PATH" <<'MD'
The {issue_number} placeholder is substituted at runtime.
Branch slug from grep -oE 'issue-[0-9]+' extraction.
API path /issues/123/comments stays intact.
## 3.19 Plugin-specific Checks (Number Reference Detection)
A short task-list pointer without a number stays below the threshold.
MD
rc=0; output=$(run "$SAMPLE") || rc=$?
if [ "$rc" -eq 0 ]; then pass "functional code / heading → exit 0"
else fail "expected rc=0 (no false positive), got rc=$rc: $output"; fi

# --------------------------------------------------------------------------
# TC-004 (T-04): drift-check-ignore line excluded
# --------------------------------------------------------------------------
echo "TC-004 (T-04): drift-check-ignore excluded"
cat > "$SAMPLE_PATH" <<'MD'
historical note (#999 silent-corruption visualization) drift-check-ignore
MD
rc=0; output=$(run "$SAMPLE") || rc=$?
if [ "$rc" -eq 0 ]; then pass "drift-check-ignore line excluded → exit 0"
else fail "expected rc=0, got rc=$rc: $output"; fi

# --------------------------------------------------------------------------
# TC-005: 5-digit and 2-digit numbers are outside the 3-4 digit band
# --------------------------------------------------------------------------
echo "TC-005: 5-digit / 2-digit boundary → no finding"
cat > "$SAMPLE_PATH" <<'MD'
A five-digit token #12345 is not an Issue ref.
A two-digit token #42 is not matched either.
MD
rc=0; output=$(run "$SAMPLE") || rc=$?
if [ "$rc" -eq 0 ]; then pass "boundary digit-counts → exit 0"
else fail "expected rc=0, got rc=$rc: $output"; fi

# --------------------------------------------------------------------------
# TC-006 (T-05): a finding reports a summary line and exits 1 (warning, not
#                a hard abort) so the lint wiring can treat it as non-blocking.
# --------------------------------------------------------------------------
echo "TC-006 (T-05): finding → exit 1 + summary (non-aborting)"
cat > "$SAMPLE_PATH" <<'MD'
note (#1500)
MD
rc=0; output=$(run "$SAMPLE") || rc=$?
if [ "$rc" -eq 1 ] && echo "$output" | grep -q 'Total number-ref findings: 1'; then
  pass "finding reported with summary, exit 1 (warning)"
else fail "expected rc=1 + summary, got rc=$rc: $output"; fi

# --------------------------------------------------------------------------
# TC-007: hooks/tests/ fixtures are never reported (they embed bad refs by
#         design) even when targeted explicitly.
# --------------------------------------------------------------------------
echo "TC-007: hooks/tests/ fixture excluded"
cat > "$TEST_DIR/plugins/rite/hooks/tests/bad-fixture.md" <<'MD'
fixture line (#1700)
MD
rc=0; output=$(run "plugins/rite/hooks/tests/bad-fixture.md") || rc=$?
if [ "$rc" -eq 0 ] && ! echo "$output" | grep -q '#1700'; then
  pass "tests/ fixture excluded → exit 0"
else fail "expected rc=0 with no finding, got rc=$rc: $output"; fi

# --------------------------------------------------------------------------
# TC-008: --all scans the number-free surface (CHANGELOG present here) and
#         reports a re-introduced number.
# --------------------------------------------------------------------------
echo "TC-008: --all scans CHANGELOG surface"
cat > "$TEST_DIR/CHANGELOG.md" <<'MD'
## [0.6.0]
- A re-introduced PR number (#1600) sneaks in here.
MD
rc=0; output=$(bash "$TARGET" --all --repo-root "$TEST_DIR" 2>&1) || rc=$?
if [ "$rc" -eq 1 ] && echo "$output" | grep -q '#1600'; then
  pass "--all detects re-introduced number in CHANGELOG"
else fail "expected rc=1 with #1600, got rc=$rc: $output"; fi

# --------------------------------------------------------------------------
# TC-009 (T-06): a clean surface file → 0 findings
# --------------------------------------------------------------------------
echo "TC-009 (T-06): clean file → exit 0"
cat > "$TEST_DIR/CHANGELOG.ja.md" <<'MD'
## [0.6.0]
- 番号のないクリーンなエントリ。
MD
rc=0; output=$(run "CHANGELOG.ja.md") || rc=$?
if [ "$rc" -eq 0 ]; then pass "clean file → exit 0"
else fail "expected rc=0, got rc=$rc: $output"; fi

# --------------------------------------------------------------------------
# TC-010: the `Issue #NNN` / `PR #NNN` prose forms are subsumed by the bare
#         `#NNN` pattern (regression guard for the headline feature — the
#         script header claims these forms are detected).
# --------------------------------------------------------------------------
echo "TC-010: Issue #NNN / PR #NNN prose forms detected"
issue_label=Issue
pr_label=PR
number_mark='#'
cat > "$SAMPLE_PATH" <<MD
See ${issue_label} ${number_mark}1234 for the rationale.
Per ${pr_label} ${number_mark}367, the loader was fixed.
MD
rc=0; output=$(run "$SAMPLE") || rc=$?
if [ "$rc" -eq 1 ] && echo "$output" | grep -q '#1234' && echo "$output" | grep -q '#367'; then
  pass "Issue #NNN / PR #NNN prose forms detected → exit 1"
else fail "expected rc=1 with #1234 and #367, got rc=$rc: $output"; fi

# --------------------------------------------------------------------------
# TC-011: exact 3-4 digit band boundaries (#100 / #9999 detected, #99 not).
# --------------------------------------------------------------------------
echo "TC-011: band boundary #100 / #9999 / #99"
cat > "$SAMPLE_PATH" <<'MD'
Lower bound (#100) is detected.
Upper bound (#9999) is detected.
Below band #99 is not detected.
MD
rc=0; output=$(run "$SAMPLE") || rc=$?
if [ "$rc" -eq 1 ] \
   && echo "$output" | grep -q '#100' \
   && echo "$output" | grep -q '#9999' \
   && ! echo "$output" | grep -q '#99\b'; then
  pass "band boundaries: #100/#9999 detected, #99 excluded"
else fail "expected #100 and #9999 detected without #99, got rc=$rc: $output"; fi

# --------------------------------------------------------------------------
# TC-012: a non-existent repo-root is an invocation error (exit 2), not a
#         finding — keeps the exit-2 contract distinct from the exit-1 warning.
# --------------------------------------------------------------------------
echo "TC-012: bad --repo-root → exit 2"
rc=0; output=$(bash "$TARGET" --repo-root /nonexistent/rite-xyz --target foo.md 2>&1) || rc=$?
if [ "$rc" -eq 2 ] && echo "$output" | grep -q 'repo-root not a directory'; then
  pass "bad --repo-root → exit 2 (invocation error)"
else fail "expected rc=2 with repo-root error, got rc=$rc: $output"; fi

# --------------------------------------------------------------------------
# TC-013: rationale rewrites must not replace numbered journals with another
#         undefined placeholder. These tokens previously produced broken prose
#         such as malformed possessives and unnamed review runs.
# --------------------------------------------------------------------------
echo "TC-013: generic rationale placeholders are absent"
placeholder_pattern='the governing'' rationale|The observed'' review run|the contract''[.]s'
if ! rg -n "$placeholder_pattern" \
  "$REPO_ROOT/plugins/rite" "$REPO_ROOT/docs" >/dev/null; then
  pass "generic rationale placeholders are absent"
else
  fail "generic rationale placeholder residue found under plugins/rite or docs"
fi

echo "TC-014: deletion-damage residue is absent"
deletion_residue_patterns=(
  '[(（]で '
  '[(（]の '
  'machine-gated since[)]'
  'stdout emit、[)）:]'
  'tracked by[[:space:]]*[.]'
  'approved by[[:space:]]*[.]'
  "of 's"
  'pattern[.]POSIX'
  '、）'
  ',[)]'
  '[[:lower:]][.][(][[:upper:]]'
  '構築。[^|]*と対称[)][[:space:]]*[|]'
  'emit、[[:space:]]+で'
  '。[[:space:]]+以降'
  '[(（]の[^[:space:]]'
  'emit[*]*、[[:space:]]+で'
  '[.] D-[0-9]+'
  'frozen[.][)]'
  'AC-[0-9]+[.][)]'
  '[[:alpha:]][,][[:space:]]*[;]'
  'Static contract( tests)? for[[:space:]]*:'
  '。[[:space:]]+D-[0-9]+'
  '。[[:space:]]+で(は|本体|log)'
  '（で(機械|配線|skip)'
)
deletion_residue_samples=(
  'context (で rationale'
  'context (の rationale'
  'machine-gated since)'
  'stdout emit、):'
  'tracked by .'
  'approved by .'
  "half of 's contract"
  'pattern.POSIX'
  '理由、）'
  'reason,)'
  'silently.(The next sentence)'
  '集合を構築。helper と対称) |'
  'helper が emit、 で LLM'
  '完了。 以降'
  '(の実測必須ゲート'
  'helper が emit**、 で LLM'
  '. D-01 requirement'
  'intentionally frozen.)'
  'AC-1.)'
  'other, ; next'
  'Static contract tests for : workflow'
  '。 D-01 requirement'
  '。 で本体'
  '（で機械比率計算'
)
deletion_residue_pattern=$(IFS='|'; printf '%s' "${deletion_residue_patterns[*]}")
for i in "${!deletion_residue_patterns[@]}"; do
  if printf '%s\n' "${deletion_residue_samples[$i]}" | rg -q "${deletion_residue_patterns[$i]}"; then
    pass "deletion-damage matcher arm $((i + 1)) has a positive control"
  else
    fail "deletion-damage matcher arm $((i + 1)) missed its positive control"
  fi
done
if ! printf '%s\n' 'context with durable rationale' | rg -q "$deletion_residue_pattern"; then
  pass "deletion-damage matcher accepts valid prose"
else
  fail "deletion-damage matcher rejected valid prose"
fi
if ! rg -n -g '!**/number-reference-check.test.sh' "$deletion_residue_pattern" \
  "$REPO_ROOT/plugins/rite" "$REPO_ROOT/docs" >/dev/null; then
  pass "deletion-damage residue is absent"
else
  fail "deletion-damage residue found under plugins/rite or docs"
fi

# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------
echo ""
echo "=== Test Summary ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
echo "TOTAL: $((PASS + FAIL))"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
