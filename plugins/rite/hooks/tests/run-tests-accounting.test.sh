#!/bin/bash
# Tests for the suite runners' skip accounting and terminal logic
# Usage: bash plugins/rite/hooks/tests/run-tests-accounting.test.sh
#
# Covers what decides the colour of the CI job: the two skip-summary parsers, the
# marker cross-check, the order of the failure list against the accounting bail,
# and the exit code in each of the four quadrants. `run-tests.sh` and `run-all.sh`
# carry the same ~90 lines twice, so every case runs against both.
#
# The runner under test is copied into a sandbox and pointed at synthetic test
# files. It does not recurse: with the copy as its SCRIPT_DIR, the sibling glob
# `$SCRIPT_DIR/../scripts/tests/test-*.sh` matches nothing and the existing
# `[ -f "$f" ]` guard skips it.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOKS_RUNNER="$SCRIPT_DIR/run-tests.sh"
SCRIPTS_RUNNER="$SCRIPT_DIR/../../scripts/tests/run-all.sh"
# Two steps: bash `cd ""` returns 0 without changing directory, so a failed mktemp
# inside a nested `$(cd "$(mktemp -d)" && pwd -P)` would yield the current directory —
# which the cleanup trap below would then delete.
TEST_DIR="$(mktemp -d)" || exit 1
TEST_DIR="$(cd "$TEST_DIR" && pwd -P)" || exit 1
PASS=0
FAIL=0
SKIP=0
FAILED_NAMES=()

cleanup() {
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

pass() { PASS=$((PASS + 1)); echo "  ✅ PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); FAILED_NAMES+=("$1"); echo "  ❌ FAIL: $1"; }

# Both runners must exist — a rename would otherwise make every case below
# vacuously green.
for runner in "$HOOKS_RUNNER" "$SCRIPTS_RUNNER"; do
  if [ ! -f "$runner" ]; then
    echo "ERROR: runner under test not found: $runner" >&2
    exit 1
  fi
done

# --- Fixture helpers ---

# Stage a copy of one runner in its own sandbox and echo the sandbox path. The
# scripts runner globs `$SCRIPT_DIR/*.test.sh`, the hooks runner the same plus a
# sibling directory, so a flat sandbox drives both.
stage_runner() {
  local runner="$1" name="$2" dir
  dir="$TEST_DIR/$name"
  mkdir -p "$dir"
  cp "$runner" "$dir/runner.sh"
  printf '%s' "$dir"
}

# Write a synthetic test file. Args: dir, name, exit code, then the lines to echo.
make_test_file() {
  local dir="$1" name="$2" rc="$3"
  shift 3
  {
    echo '#!/bin/bash'
    local line
    for line in "$@"; do
      printf 'echo %q\n' "$line"
    done
    echo "exit $rc"
  } > "$dir/$name"
}

# Run a staged runner, capturing stdout+stderr and the exit code.
run_staged() {
  local dir="$1"
  RUN_RC=0
  RUN_OUT=$(bash "$dir/runner.sh" 2>&1) || RUN_RC=$?
}

assert_rc() {
  local label="$1" expected="$2" actual="$3"
  if [ "$actual" -eq "$expected" ]; then
    pass "$label (rc=$actual)"
  else
    fail "$label: expected rc $expected, got $actual"
  fi
}

assert_contains() {
  local label="$1" needle="$2"
  if printf '%s\n' "$RUN_OUT" | grep -qF "$needle"; then
    pass "$label"
  else
    fail "$label: output did not contain '$needle'"
  fi
}

assert_not_contains() {
  local label="$1" needle="$2"
  if printf '%s\n' "$RUN_OUT" | grep -qF "$needle"; then
    fail "$label: output unexpectedly contained '$needle'"
  else
    pass "$label"
  fi
}

# Assert against one specific line rather than the whole output. Both runners print
# the gated-group count on their aggregate line as well as their success line, so a
# whole-output match cannot tell the two apart — dropping the suffix from the success
# line alone would stay green.
assert_line_matches() {
  local label="$1" line_needle="$2" pattern="$3" line
  line=$(printf '%s\n' "$RUN_OUT" | grep -F "$line_needle" | tail -1)
  if [ -z "$line" ]; then
    fail "$label: no line containing '$line_needle'"
  elif printf '%s' "$line" | grep -qE "$pattern"; then
    pass "$label"
  else
    fail "$label: line '$line' did not match /$pattern/"
  fi
}

# The runners differ only in how they name things; the logic under test is shared.
# Each entry: runner path, sandbox prefix, failure-list marker, success marker.
run_case_on_both() {
  local case_fn="$1"
  "$case_fn" "$HOOKS_RUNNER" "hooks" "Failed tests:" "All tests passed!"
  "$case_fn" "$SCRIPTS_RUNNER" "scripts" "FAILED test files:" "All script tests passed"
}

# --- TC-1: quadrant 1 — no failure, no drift ---

echo "=== TC-1: clean run exits 0 and reports the gated-group count ==="
tc1() {
  local runner="$1" tag="$2" _fail_marker="$3" success_marker="$4" dir
  dir=$(stage_runner "$runner" "tc1-$tag")
  # A well-formed skip: marker plus the `SKIP: N` summary form.
  make_test_file "$dir" "a.test.sh" 0 "  ⏭️ SKIP: gated group" "SKIP: 1"
  run_staged "$dir"
  assert_rc "TC-1/$tag clean run exits 0" 0 "$RUN_RC"
  assert_contains "TC-1/$tag success line is printed" "$success_marker"
  # Anchored to the success line itself: a bare "All tests passed!" under a run that
  # gated a group reads as full coverage, which is what the counting exists to stop.
  assert_line_matches "TC-1/$tag success line carries the gated-group count" \
    "$success_marker" '1 gated group\(s\) skipped'
  assert_not_contains "TC-1/$tag no drift error on a well-formed skip" "summary format drift"
}
run_case_on_both tc1

# --- TC-2: quadrant 2 — failure only ---

echo ""
echo "=== TC-2: a failing test exits 1 and names the file ==="
tc2() {
  local runner="$1" tag="$2" fail_marker="$3" success_marker="$4" dir
  dir=$(stage_runner "$runner" "tc2-$tag")
  make_test_file "$dir" "broken.test.sh" 1 "  ❌ FAIL: synthetic"
  run_staged "$dir"
  assert_rc "TC-2/$tag failing run exits 1" 1 "$RUN_RC"
  assert_contains "TC-2/$tag failure list is printed" "$fail_marker"
  assert_contains "TC-2/$tag failing file is named" "broken.test.sh"
  assert_not_contains "TC-2/$tag success line is withheld" "$success_marker"
}
run_case_on_both tc2

# --- TC-3: quadrant 3 — drift only ---

echo ""
echo "=== TC-3: a marker without a summary count fails the run ==="
tc3() {
  local runner="$1" tag="$2" _fail_marker="$3" success_marker="$4" dir
  dir=$(stage_runner "$runner" "tc3-$tag")
  # Marker printed, but no `SKIP: N` and no `, N skipped` — the undercount this
  # accounting exists to catch. The file itself passes.
  make_test_file "$dir" "drift.test.sh" 0 "  ⏭️ SKIP: uncounted" "Results: 1 passed, 0 failed"
  run_staged "$dir"
  assert_rc "TC-3/$tag drift alone fails the run" 1 "$RUN_RC"
  assert_contains "TC-3/$tag drift is diagnosed per file" "summary format drift"
  assert_contains "TC-3/$tag accounting bail is reported" "Skip accounting is unreliable"
  assert_not_contains "TC-3/$tag success line is withheld on drift" "$success_marker"
}
run_case_on_both tc3

# --- TC-4: quadrant 4 — failure AND drift ---

echo ""
echo "=== TC-4: failure list survives a simultaneous accounting bail ==="
tc4() {
  local runner="$1" tag="$2" fail_marker="$3" _success_marker="$4" dir
  dir=$(stage_runner "$runner" "tc4-$tag")
  # Both conditions at once. This is structural rather than rare: a `set -e` test
  # that aborts after a skip() call but before its summary produces exactly this.
  # Bailing on the accounting before printing the list would erase the only line
  # naming which file failed.
  make_test_file "$dir" "both.test.sh" 1 "  ⏭️ SKIP: uncounted" "  ❌ FAIL: synthetic"
  run_staged "$dir"
  assert_rc "TC-4/$tag exits 1 when both conditions hold" 1 "$RUN_RC"
  assert_contains "TC-4/$tag failure list is not swallowed by the bail" "$fail_marker"
  assert_contains "TC-4/$tag failing file is still named" "both.test.sh"
  assert_contains "TC-4/$tag accounting bail is also reported" "Skip accounting is unreliable"
}
run_case_on_both tc4

# --- TC-5: the second summary parser ---

echo ""
echo "=== TC-5: the 'Results: ..., N skipped' form is counted too ==="
tc5() {
  local runner="$1" tag="$2" _fail_marker="$3" success_marker="$4" dir
  dir=$(stage_runner "$runner" "tc5-$tag")
  # The form the CONTRIBUTING.md template emits, as opposed to print_summary's.
  make_test_file "$dir" "b.test.sh" 0 \
    "  ⏭️ SKIP: one" "  ⏭️ SKIP: two" "Results: 3 passed, 0 failed, 2 skipped"
  run_staged "$dir"
  assert_rc "TC-5/$tag alternate summary form keeps the run green" 0 "$RUN_RC"
  assert_line_matches "TC-5/$tag both markers are counted" \
    "$success_marker" '2 gated group\(s\) skipped'
  assert_not_contains "TC-5/$tag no drift on the alternate form" "summary format drift"
}
run_case_on_both tc5

# --- TC-6: over-count is caught as well as under-count ---

echo ""
echo "=== TC-6: a summary claiming more skips than it printed also fails ==="
tc6() {
  local runner="$1" tag="$2" _fail_marker="$3" _success_marker="$4" dir
  dir=$(stage_runner "$runner" "tc6-$tag")
  # The mirror of TC-3. Counting only the zero case would let a file that mixes
  # counted skip() calls with bare echoes through.
  make_test_file "$dir" "over.test.sh" 0 "  ⏭️ SKIP: only one" "SKIP: 5"
  run_staged "$dir"
  assert_rc "TC-6/$tag over-count fails the run" 1 "$RUN_RC"
  assert_contains "TC-6/$tag mismatch is diagnosed" "summary format drift"
}
run_case_on_both tc6

# --- Summary ---
echo ""
echo "Results: $PASS passed, $FAIL failed$( [ "$SKIP" -gt 0 ] && printf ", %s skipped" "$SKIP" )"
if [ "$FAIL" -ne 0 ]; then
  echo "Failed assertions:"
  for n in "${FAILED_NAMES[@]}"; do
    echo "  - $n"
  done
  exit 1
fi
