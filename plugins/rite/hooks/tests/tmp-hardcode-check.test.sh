#!/bin/bash
# Tests for tmp-hardcode-check.sh
# Pins the P1/P2/P3 sandbox-incompatibility patterns (recurrence
# guard) including the documented match / non-match boundaries (safe
# ${TMPDIR:-/tmp} forms, `git stash push -u`, combined short flags, refspec-
# after flag form) so silent regex drift is caught mechanically.
# Usage: bash plugins/rite/hooks/tests/tmp-hardcode-check.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="$SCRIPT_DIR/../scripts/tmp-hardcode-check.sh"
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

echo "=== tmp-hardcode-check.sh tests ==="
echo ""

mkdir -p "$TEST_DIR/plugins/rite/skills"

run() { bash "$TARGET" --repo-root "$TEST_DIR" --target "$1" 2>&1; }
SAMPLE="plugins/rite/skills/sample.md"
SAMPLE_PATH="$TEST_DIR/$SAMPLE"

# --------------------------------------------------------------------------
# TC-001: No targets → exit 2 (invocation error)
# --------------------------------------------------------------------------
echo "TC-001: no targets → exit 2"
rc=0; bash "$TARGET" --repo-root "$TEST_DIR" >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 2 ]; then pass "no targets → exit 2"
else fail "expected rc=2, got rc=$rc"; fi

# --------------------------------------------------------------------------
# TC-002: P1 — unquoted mktemp /tmp template → exit 1 + [P1]
# --------------------------------------------------------------------------
echo "TC-002: P1 mktemp /tmp template detected"
cat > "$SAMPLE_PATH" <<'MD'
tmpfile=$(mktemp /tmp/rite-wiki-content-XXXXXX)
MD
rc=0; output=$(run "$SAMPLE") || rc=$?
if [ "$rc" -eq 1 ] && echo "$output" | grep -q '\[tmp-hardcode\]\[P1\]'; then
  pass "mktemp /tmp template → exit 1 + [P1]"
else fail "expected rc=1 with [P1], got rc=$rc: $output"; fi

# --------------------------------------------------------------------------
# TC-003: P1 — flag-interposed (-d) and quoted-template variants detected
# --------------------------------------------------------------------------
echo "TC-003: P1 flag / quoted variants detected"
cat > "$SAMPLE_PATH" <<'MD'
tmpdir=$(mktemp -d /tmp/rite-work-XXXXXX)
tmpfile=$(mktemp "/tmp/rite-quoted-XXXXXX")
MD
rc=0; output=$(run "$SAMPLE") || rc=$?
p1_count=$(echo "$output" | grep -c '\[tmp-hardcode\]\[P1\]' || true)
if [ "$rc" -eq 1 ] && [ "$p1_count" -eq 2 ]; then
  pass "-d flag + quoted template both detected (2 findings)"
else fail "expected rc=1 with 2 [P1] findings, got rc=$rc count=$p1_count: $output"; fi

# --------------------------------------------------------------------------
# TC-004: P1/P2 safe forms — ${TMPDIR:-/tmp} parameter expansion → exit 0
#         (the docstring claims the expansion structurally never matches)
# --------------------------------------------------------------------------
echo "TC-004: safe \${TMPDIR:-/tmp} forms → exit 0"
cat > "$SAMPLE_PATH" <<'MD'
tmpfile=$(mktemp "${TMPDIR:-/tmp}/rite-a-XXXXXX")
backup_file="${TMPDIR:-/tmp}/rite-backup.md"
: > "${TMPDIR:-/tmp}/rite-out.txt"
bash trigger.sh --content-file "${TMPDIR:-/tmp}/rite-c.md"
MD
rc=0; output=$(run "$SAMPLE") || rc=$?
if [ "$rc" -eq 0 ]; then pass "safe forms not matched → exit 0"
else fail "expected rc=0 (safe forms excluded), got rc=$rc: $output"; fi

# --------------------------------------------------------------------------
# TC-005: P2 — assignment / redirect / -file option forms → exit 1 + [P2] ×3
# --------------------------------------------------------------------------
echo "TC-005: P2 fixed /tmp path forms detected"
cat > "$SAMPLE_PATH" <<'MD'
backup_file="/tmp/rite-wm-backup.md"
echo done > /tmp/rite-status.txt
bash trigger.sh --content-file /tmp/rite-body.md
MD
rc=0; output=$(run "$SAMPLE") || rc=$?
p2_count=$(echo "$output" | grep -c '\[tmp-hardcode\]\[P2\]' || true)
if [ "$rc" -eq 1 ] && [ "$p2_count" -eq 3 ]; then
  pass "assignment / redirect / -file option all detected (3 findings)"
else fail "expected rc=1 with 3 [P2] findings, got rc=$rc count=$p2_count: $output"; fi

# --------------------------------------------------------------------------
# TC-006: P3 — -u / flag-interposed -u / --set-upstream → exit 1 + [P3] ×3
# --------------------------------------------------------------------------
echo "TC-006: P3 git push -u forms detected"
cat > "$SAMPLE_PATH" <<'MD'
git push -u origin feature-x
git push --force -u origin feature-x
git push --set-upstream origin feature-x
MD
rc=0; output=$(run "$SAMPLE") || rc=$?
p3_count=$(echo "$output" | grep -c '\[tmp-hardcode\]\[P3\]' || true)
if [ "$rc" -eq 1 ] && [ "$p3_count" -eq 3 ]; then
  pass "-u / interposed -u / --set-upstream all detected (3 findings)"
else fail "expected rc=1 with 3 [P3] findings, got rc=$rc count=$p3_count: $output"; fi

# --------------------------------------------------------------------------
# TC-007: P3 — `git stash push -u` (include-untracked stash) is NOT matched
#         (explicitly excludes it from the sweep)
# --------------------------------------------------------------------------
echo "TC-007: git stash push -u not matched"
cat > "$SAMPLE_PATH" <<'MD'
git stash push -u -m "wip"
git push origin feature-x
MD
rc=0; output=$(run "$SAMPLE") || rc=$?
if [ "$rc" -eq 0 ]; then pass "stash push -u / bare push → exit 0"
else fail "expected rc=0, got rc=$rc: $output"; fi

# --------------------------------------------------------------------------
# TC-008: P3 known boundaries pinned — combined short flags (-qu) and the
#         flag-after-refspec form are NOT detected (docstring contract)
# --------------------------------------------------------------------------
echo "TC-008: P3 known boundaries (-qu / refspec-after) not detected"
cat > "$SAMPLE_PATH" <<'MD'
git push -qu origin feature-x
git push origin -u feature-x
MD
rc=0; output=$(run "$SAMPLE") || rc=$?
if [ "$rc" -eq 0 ]; then pass "known boundaries stay undetected → exit 0"
else fail "expected rc=0 (documented boundary), got rc=$rc: $output"; fi

# --------------------------------------------------------------------------
# TC-009: --all excludes */tests/*, gh-cli-error-catalog.md, and the guard
#         script itself even when they contain violating patterns
# --------------------------------------------------------------------------
echo "TC-009: --all exclusion rules (tests / catalog / self)"
allroot="$TEST_DIR/allroot"
mkdir -p "$allroot/plugins/rite/skills" \
         "$allroot/plugins/rite/references" \
         "$allroot/plugins/rite/hooks/scripts" \
         "$allroot/plugins/rite/hooks/tests"
cat > "$allroot/plugins/rite/hooks/tests/fixture.md" <<'MD'
tmpfile=$(mktemp /tmp/rite-fixture-XXXXXX)
MD
cat > "$allroot/plugins/rite/references/gh-cli-error-catalog.md" <<'MD'
error example: mktemp /tmp/rite-error-XXXXXX
MD
cat > "$allroot/plugins/rite/hooks/scripts/tmp-hardcode-check.sh" <<'MD'
grep for mktemp /tmp/ patterns (self copy — must be excluded by SELF_REL)
MD
cat > "$allroot/plugins/rite/skills/clean.md" <<'MD'
tmpfile=$(mktemp "${TMPDIR:-/tmp}/rite-ok-XXXXXX")
MD
rc=0; output=$(bash "$TARGET" --all --repo-root "$allroot" 2>&1) || rc=$?
if [ "$rc" -eq 0 ]; then pass "tests/ + catalog + self excluded → exit 0"
else fail "expected rc=0 (exclusions honored), got rc=$rc: $output"; fi

# --------------------------------------------------------------------------
# TC-010: --all detects a violation in scan scope + exact count line format
#         (`Total tmp-hardcode findings: N` — lint row 16 regex contract)
# --------------------------------------------------------------------------
echo "TC-010: --all detects violation + count line format"
cat > "$allroot/plugins/rite/skills/bad.md" <<'MD'
git push -u origin wiki
MD
rc=0; output=$(bash "$TARGET" --all --repo-root "$allroot" 2>&1) || rc=$?
if [ "$rc" -eq 1 ] && echo "$output" | grep -q 'Total tmp-hardcode findings: 1'; then
  pass "--all finds violation, count line matches lint regex"
else fail "expected rc=1 + 'Total tmp-hardcode findings: 1', got rc=$rc: $output"; fi
rm -f "$allroot/plugins/rite/skills/bad.md"

# --------------------------------------------------------------------------
# TC-011: --all without plugins/rite → exit 2 (invocation error)
# --------------------------------------------------------------------------
echo "TC-011: --all without plugins/rite → exit 2"
noplugin="$TEST_DIR/noplugin"
mkdir -p "$noplugin"
rc=0; output=$(bash "$TARGET" --all --repo-root "$noplugin" 2>&1) || rc=$?
if [ "$rc" -eq 2 ] && echo "$output" | grep -q 'plugins/rite does not exist'; then
  pass "--all without plugins/rite → exit 2"
else fail "expected rc=2, got rc=$rc: $output"; fi

# --------------------------------------------------------------------------
# TC-012: --all --skip-if-no-target without plugins/rite → clean skip exit 0
# --------------------------------------------------------------------------
echo "TC-012: --skip-if-no-target → exit 0"
rc=0; output=$(bash "$TARGET" --all --skip-if-no-target --repo-root "$noplugin" 2>&1) || rc=$?
if [ "$rc" -eq 0 ] && echo "$output" | grep -q 'not applicable'; then
  pass "--skip-if-no-target → clean skip exit 0"
else fail "expected rc=0 with skip notice, got rc=$rc: $output"; fi

# --------------------------------------------------------------------------
# TC-013: explicit --target of a missing file → exit 2
# --------------------------------------------------------------------------
echo "TC-013: missing --target → exit 2"
rc=0; output=$(bash "$TARGET" --repo-root "$TEST_DIR" --target no/such/file.md 2>&1) || rc=$?
if [ "$rc" -eq 2 ] && echo "$output" | grep -q 'target not found'; then
  pass "missing --target → exit 2"
else fail "expected rc=2 with 'target not found', got rc=$rc: $output"; fi

# --------------------------------------------------------------------------
# TC-014: --quiet suppresses the count line but keeps findings on stdout
# --------------------------------------------------------------------------
echo "TC-014: --quiet keeps findings, drops count line"
cat > "$SAMPLE_PATH" <<'MD'
tmpfile=$(mktemp /tmp/rite-q-XXXXXX)
MD
rc=0; output=$(bash "$TARGET" --quiet --repo-root "$TEST_DIR" --target "$SAMPLE" 2>&1) || rc=$?
if [ "$rc" -eq 1 ] \
   && echo "$output" | grep -q '\[tmp-hardcode\]\[P1\]' \
   && ! echo "$output" | grep -q 'Total tmp-hardcode findings'; then
  pass "--quiet: findings kept, count line suppressed"
else fail "expected rc=1 with [P1] and no count line, got rc=$rc: $output"; fi

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
