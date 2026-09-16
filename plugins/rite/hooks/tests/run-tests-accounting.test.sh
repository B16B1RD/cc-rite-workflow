#!/bin/bash
# Tests for the suite runners' skip accounting and terminal logic
# Usage: bash plugins/rite/hooks/tests/run-tests-accounting.test.sh
#
# Covers what decides the colour of the CI job: the two skip-summary parsers, the
# marker cross-check, the order of the failure list against the accounting bail,
# and the exit code in each of the four quadrants. Accounting cases run against
# both runners; the hook runner also exercises fixed batches and interruption.
#
# The runner under test is copied into a sandbox and pointed at synthetic test
# files. Fixtures live in separate trees and never discover the real suite.
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
  dir="$TEST_DIR/$name/hooks/tests"
  mkdir -p "$dir"
  cp "$runner" "$dir/runner.sh"
  # The hooks runner sources its sibling unset list; the scripts runner has none.
  if [ "$runner" = "$HOOKS_RUNNER" ]; then
    cp "$SCRIPT_DIR/_hermetic-env.sh" "$dir/_hermetic-env.sh"
  fi
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
  shift
  RUN_RC=0
  RUN_OUT=$(bash "$dir/runner.sh" "$@" 2>&1) || RUN_RC=$?
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
  # `|| true` is scoped to grep alone: a no-match is an expected outcome here (it is
  # what the empty-line branch below reports), but under `set -o pipefail` its exit 1
  # would fail the assignment and abort the file, taking the diagnostic with it.
  # Wrapping the whole substitution instead would also swallow tail/printf failures.
  line=$(printf '%s\n' "$RUN_OUT" | { grep -F "$line_needle" || true; } | tail -1)
  if [ -z "$line" ]; then
    fail "$label: no line containing '$line_needle'"
  elif printf '%s' "$line" | grep -qE "$pattern"; then
    pass "$label"
  else
    fail "$label: line '$line' did not match /$pattern/"
  fi
}

# Assert that some whole line matches a pattern. Needed wherever a bare substring
# would also hit the runner's own `=== Running: <file> ===` progress line, which is
# printed for every file regardless of outcome — a filename assertion anchored only
# on the name can never fail.
assert_line_present() {
  local label="$1" pattern="$2"
  if printf '%s\n' "$RUN_OUT" | grep -qE "$pattern"; then
    pass "$label"
  else
    fail "$label: no line matched /$pattern/"
  fi
}

# The runners differ only in how they name things; the logic under test is shared.
# Each entry: runner path, sandbox prefix, failure-list marker, success marker,
# failure-entry line pattern (a printf format taking the escaped filename), and the
# line that carries the gated-group count on the red path. The last two exist because
# the two runners format those differently: the hooks runner gives each failure its
# own `  - <file>` line and puts the count on `Results:`, while the scripts runner
# packs both into its single `=== FAILED test files: … ===` line.
run_case_on_both() {
  local case_fn="$1"
  "$case_fn" "$HOOKS_RUNNER" "hooks" "Failed tests:" "All tests passed!" \
    '^  - %s$' "Results:"
  "$case_fn" "$SCRIPTS_RUNNER" "scripts" "FAILED test files:" "All script tests passed" \
    '^.*FAILED test files:.*%s.*$' "FAILED test files:"
}

# Build the failure-entry pattern for a given runner and filename.
failure_entry_pattern() {
  local fmt="$1" file="$2"
  # shellcheck disable=SC2059  # fmt is a trusted per-runner template, not user input
  printf "$fmt" "${file//./\\.}"
}

# --- TC-1: quadrant 1 — no failure, no drift ---

echo "=== TC-1: clean run exits 0 and reports the gated-group count ==="
tc1() {
  local runner="$1" tag="$2" _fail_marker="$3" success_marker="$4" _entry_fmt="$5" _count_line="$6" dir
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
  local runner="$1" tag="$2" fail_marker="$3" success_marker="$4" entry_fmt="$5" _count_line="$6" dir
  dir=$(stage_runner "$runner" "tc2-$tag")
  make_test_file "$dir" "broken.test.sh" 1 "  ❌ FAIL: synthetic"
  run_staged "$dir"
  assert_rc "TC-2/$tag failing run exits 1" 1 "$RUN_RC"
  assert_contains "TC-2/$tag failure list is printed" "$fail_marker"
  # Anchored to the failure-list entry, not to the name alone: every file also gets a
  # `=== Running: broken.test.sh ===` line, so a bare substring match passes even when
  # the list stops naming anything.
  assert_line_present "TC-2/$tag failing file is named in the failure list" \
    "$(failure_entry_pattern "$entry_fmt" "broken.test.sh")"
  assert_not_contains "TC-2/$tag success line is withheld" "$success_marker"
}
run_case_on_both tc2

# --- TC-3: quadrant 3 — drift only ---

echo ""
echo "=== TC-3: a marker without a summary count fails the run ==="
tc3() {
  local runner="$1" tag="$2" _fail_marker="$3" success_marker="$4" _entry_fmt="$5" _count_line="$6" dir
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
  local runner="$1" tag="$2" fail_marker="$3" _success_marker="$4" entry_fmt="$5" _count_line="$6" dir
  dir=$(stage_runner "$runner" "tc4-$tag")
  # Both conditions at once. This is structural rather than rare: a `set -e` test
  # that aborts after a skip() call but before its summary produces exactly this.
  # Bailing on the accounting before printing the list would erase the only line
  # naming which file failed.
  make_test_file "$dir" "both.test.sh" 1 "  ⏭️ SKIP: uncounted" "  ❌ FAIL: synthetic"
  run_staged "$dir"
  assert_rc "TC-4/$tag exits 1 when both conditions hold" 1 "$RUN_RC"
  assert_contains "TC-4/$tag failure list is not swallowed by the bail" "$fail_marker"
  assert_line_present "TC-4/$tag failing file is still named in the failure list" \
    "$(failure_entry_pattern "$entry_fmt" "both.test.sh")"
  assert_contains "TC-4/$tag accounting bail is also reported" "Skip accounting is unreliable"
}
run_case_on_both tc4

# --- TC-5: the second summary parser ---

echo ""
echo "=== TC-5: the 'Results: ..., N skipped' form is counted too ==="
tc5() {
  local runner="$1" tag="$2" _fail_marker="$3" success_marker="$4" _entry_fmt="$5" _count_line="$6" dir
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
  local runner="$1" tag="$2" _fail_marker="$3" _success_marker="$4" _entry_fmt="$5" _count_line="$6" dir
  dir=$(stage_runner "$runner" "tc6-$tag")
  # The mirror of TC-3. Counting only the zero case would let a file that mixes
  # counted skip() calls with bare echoes through.
  make_test_file "$dir" "over.test.sh" 0 "  ⏭️ SKIP: only one" "SKIP: 5"
  run_staged "$dir"
  assert_rc "TC-6/$tag over-count fails the run" 1 "$RUN_RC"
  assert_contains "TC-6/$tag mismatch is diagnosed" "summary format drift"
}
run_case_on_both tc6

# --- TC-7: failure alongside correctly-counted skips, across several files ---

echo ""
echo "=== TC-7: the red path reports the skip total, summed across files ==="
tc7() {
  local runner="$1" tag="$2" _fail_marker="$3" _success_marker="$4" _entry_fmt="$5" count_line="$6" dir
  dir=$(stage_runner "$runner" "tc7-$tag")
  # Three files, so the total has to be accumulated rather than taken from the last
  # file — `SKIPPED=$file_skips` would pass every single-file case above. The failure
  # puts the run on the red path, where the hooks runner carries the count on
  # `Results:` and the scripts runner on its `FAILED test files:` line; neither is
  # exercised by the green cases.
  make_test_file "$dir" "a.test.sh" 0 "  ⏭️ SKIP: one" "SKIP: 1"
  make_test_file "$dir" "b.test.sh" 0 "  ⏭️ SKIP: two" "SKIP: 1"
  make_test_file "$dir" "c.test.sh" 1 "  ❌ FAIL: synthetic"
  run_staged "$dir"
  assert_rc "TC-7/$tag failure with counted skips exits 1" 1 "$RUN_RC"
  assert_line_matches "TC-7/$tag red path carries the summed gated-group count" \
    "$count_line" '2 gated group\(s\) skipped'
  assert_not_contains "TC-7/$tag counted skips raise no drift" "summary format drift"
}
run_case_on_both tc7

# --- TC-8: the parsers only read summary lines, not diagnostics ---

echo ""
echo "=== TC-8: a diagnostic quoting 'SKIP: N' is not counted (first parser) ==="
tc8() {
  local runner="$1" tag="$2" _fail_marker="$3" _success_marker="$4" _entry_fmt="$5" _count_line="$6" dir
  dir=$(stage_runner "$runner" "tc8-$tag")
  # A failure diagnostic that embeds `SKIP: 3` mid-line. Only the whole-line anchor in
  # the first parser keeps it out of the count — without it the file would report 4
  # skips against 1 marker and take the suite down.
  make_test_file "$dir" "quoting.test.sh" 0 \
    '  ⏭️ SKIP: real' \
    '  ❌ FAIL: got: SKIP: 3' \
    "SKIP: 1"
  run_staged "$dir"
  assert_rc "TC-8/$tag quoted 'SKIP: N' keeps the run green" 0 "$RUN_RC"
  assert_not_contains "TC-8/$tag quoted 'SKIP: N' raises no drift" "summary format drift"
}
run_case_on_both tc8

# --- TC-9: the second parser ignores a quoted 'Results:' line ---

echo ""
echo "=== TC-9: a diagnostic quoting a Results line is not counted (second parser) ==="
tc9() {
  local runner="$1" tag="$2" _fail_marker="$3" _success_marker="$4" _entry_fmt="$5" _count_line="$6" dir
  dir=$(stage_runner "$runner" "tc9-$tag")
  # Reaching the second parser requires the first to find nothing, so this file uses
  # the `Results: …, N skipped` summary form rather than `SKIP: N`. The diagnostic
  # above it quotes another Results line; only the `[^❌]` guard keeps its 7 out of
  # the count. Without the guard the file reports 8 skips against 1 marker and the
  # suite fails on a drift that never happened.
  make_test_file "$dir" "quoting-results.test.sh" 0 \
    '  ⏭️ SKIP: real' \
    '  ❌ FAIL: expected "Results: 1 passed, 0 failed, 7 skipped"' \
    "Results: 2 passed, 0 failed, 1 skipped"
  run_staged "$dir"
  assert_rc "TC-9/$tag quoted Results line keeps the run green" 0 "$RUN_RC"
  assert_not_contains "TC-9/$tag quoted Results line raises no drift" "summary format drift"
}
run_case_on_both tc9

# --- TC-10: raw C1 in a passing file must not reach runner stdout ---

echo ""
echo "=== TC-10: 生 C1 (0x9b) を含むテスト出力は再印刷時に不正 UTF-8 のまま残らない ==="
tc10() {
  local runner="$1" tag="$2" _fail_marker="$3" success_marker="$4" _entry_fmt="$5" _count_line="$6" dir
  dir=$(stage_runner "$runner" "tc10-$tag")
  {
    echo '#!/bin/bash'
    echo 'echo before-c1'
    printf 'printf '"'"'\\x9b\\n'"'"'\n'
    echo 'echo after-c1'
    echo 'exit 0'
  } > "$dir/c1.test.sh"
  run_staged "$dir"
  assert_rc "TC-10/$tag raw-C1 file still exits 0" 0 "$RUN_RC"
  assert_contains "TC-10/$tag surrounding lines survive" "before-c1"
  assert_contains "TC-10/$tag trailing line survives" "after-c1"
  assert_contains "TC-10/$tag success line is printed" "$success_marker"
  if printf '%s' "$RUN_OUT" | LC_ALL=C grep -qF "$(printf '\x9b')"; then
    fail "TC-10/$tag runner reprinted raw C1 (0x9b)"
  else
    pass "TC-10/$tag runner did not reprint raw C1 (0x9b)"
  fi
}
run_case_on_both tc10

# Concurrent execution needs live process observations in addition to summaries.
if command -v python3 >/dev/null 2>&1 && command -v perl >/dev/null 2>&1; then
  parallel_rc=0
  python3 - "$HOOKS_RUNNER" "$TEST_DIR" <<'PY' || parallel_rc=$?
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import time

source, root = map(Path, sys.argv[1:])

def stage(name):
    directory = root / name / 'hooks' / 'tests'
    directory.mkdir(parents=True)
    shutil.copy(source, directory / 'runner.sh')
    shutil.copy(source.parent / '_hermetic-env.sh', directory)
    return directory

def fixture(directory, name, body, sibling=False):
    target = directory.parent / 'scripts' / 'tests' if sibling else directory
    target.mkdir(parents=True, exist_ok=True)
    path = target / name
    path.write_text('#!/bin/bash\nset -eu\n' + body + '\n')
    return path

def run(directory, jobs):
    return subprocess.run(['bash', str(directory / 'runner.sh'), '--jobs', str(jobs)],
                          capture_output=True, text=True, timeout=25)

def headline(output):
    return re.findall(r'^Results: .*', output, re.M)[-1]

def check(condition, message):
    if not condition:
        raise AssertionError(message)

# Both discovery globs, exact execution and bounded concurrency.
d = stage('parallel-bounds')
for i in range(9):
    fixture(d, f'{i}.test.sh' if i < 5 else f'test-{i}.sh', f'''
while ! mkdir '{d}/lock' 2>/dev/null; do sleep 0.01; done
echo '+ {i}' >> '{d}/events'
rmdir '{d}/lock'
sleep 0.15
while ! mkdir '{d}/lock' 2>/dev/null; do sleep 0.01; done
echo '- {i}' >> '{d}/events'
rmdir '{d}/lock'
''', sibling=i >= 5)
for jobs in (1, 4):
    (d / 'events').unlink(missing_ok=True)
    result = run(d, jobs)
    check(result.returncode == 0, result.stdout + result.stderr)
    active = peak = 0
    starts, ends = [], []
    for line in (d / 'events').read_text().splitlines():
        direction, number = line.split()
        if direction == '+':
            active += 1
            starts.append(int(number))
        else:
            active -= 1
            ends.append(int(number))
        peak = max(peak, active)
        check(0 <= active <= jobs, 'concurrency exceeds --jobs')
    check(active == 0 and sorted(starts) == sorted(ends) == list(range(9)),
          'each discovery result must run exactly once')
    check(peak == jobs, 'parallel option must actually run concurrently')
    check(headline(result.stdout) == 'Results: 9/9 passed, 0 failed', 'incorrect total')
    markers = re.findall(r'^TEST_(START|END)\s+id=(\d+)', result.stdout, re.M)
    check(len(markers) == 18, 'missing or duplicate progress marker')
    output_ids = re.findall(r'^TEST_OUTPUT_BEGIN\s+id=(\d+)', result.stdout, re.M)
    check(output_ids == [str(n) for n in range(1, 10)], 'body output order changed')
    check(re.findall(r'^TEST_OUTPUT_END\s+id=(\d+)', result.stdout, re.M) == output_ids,
          'body output delimiters are not paired')
print('parallel bounds, both globs and exact-once: passed')

# A slow first test must not hold up the next file once the second slot is free.
d = stage('parallel-refill')
fixture(d, 'a.test.sh', 'sleep 1')
fixture(d, 'b.test.sh', 'sleep 0.05')
fixture(d, 'c.test.sh', 'exit 0')
result = run(d, 2)
check(result.returncode == 0, result.stdout + result.stderr)
check(result.stdout.index('file=hooks/tests/c.test.sh rc=0') <
      result.stdout.index('file=hooks/tests/a.test.sh rc=0'), 'free slot was not refilled')
print('free slot refilled before slow peer finishes: passed')

# A slow stdout reader must not let live END markers enter captured bodies.
d = stage('parallel-output-backpressure')
payload = 'fixture output line\n' * 100000
(d / 'payload').write_text(payload)
fixture(d, 'a.test.sh', f"cat '{d}/payload'")
fixture(d, 'b.test.sh', 'sleep 0.3')
process = subprocess.Popen(['bash', str(d / 'runner.sh'), '--jobs', '2'],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
try:
    # The 2 MB body exceeds both Linux and macOS pipe buffers.
    time.sleep(1)
    output, error = process.communicate(timeout=25)
finally:
    if process.poll() is None:
        process.kill()
        process.communicate()
check(process.returncode == 0, error)
body = output.split('TEST_OUTPUT_BEGIN id=1 ', 1)[1].split('TEST_OUTPUT_END id=1', 1)[0]
check('TEST_START ' not in body and 'TEST_END ' not in body,
      'live progress marker mixed into captured body')
check(body.split('=== Running: a.test.sh ===\n', 1)[1] == payload,
      'captured body changed under backpressure')
check(headline(output) == 'Results: 2/2 passed, 0 failed', 'backpressure result changed')
print('body output stays separate under backpressure: passed')

# Reversed completion keeps rc, filenames, failure order and skip totals aligned.
d = stage('parallel-order')
fixture(d, 'a.test.sh', "sleep 0.4\necho '  ⏭️ SKIP: first'\necho 'SKIP: 1'\nexit 7")
fixture(d, 'b.test.sh', "echo '  ⏭️ SKIP: second'\necho 'SKIP: 1'\nexit 9")
fixture(d, 'test-c.sh', 'exit 0', sibling=True)
serial, parallel = run(d, 1), run(d, 4)
check(serial.returncode == parallel.returncode == 1, 'real failures must fail suite')
check(headline(serial.stdout) == headline(parallel.stdout) ==
      'Results: 1/3 passed, 2 failed, 2 gated group(s) skipped', 'skip/failure count mismatch')
check(re.findall(r'^  - .*', parallel.stdout, re.M) == ['  - a.test.sh', '  - b.test.sh'],
      'failure list must preserve discovery order')
for name, rc in [('a.test.sh', 7), ('b.test.sh', 9)]:
    check(re.search(r'^TEST_END\s+.*file=\S*' + re.escape(name) + r'\s+rc=' + str(rc) + r'\b',
                    parallel.stdout, re.M), 'END rc must match filename')
check(parallel.stdout.index('file=hooks/tests/b.test.sh rc=9') <
      parallel.stdout.index('file=hooks/tests/a.test.sh rc=7'), 'fixture must reverse completion')
print('reverse completion and aggregation: passed')

# A real failure in one file must coexist with skip drift in another.
d = stage('parallel-drift')
fixture(d, 'a.test.sh', 'exit 5')
fixture(d, 'b.test.sh', "echo '  ⏭️ SKIP: uncounted'")
result = run(d, 4)
check(result.returncode == 1 and '  - a.test.sh' in result.stdout and
      'Skip accounting is unreliable' in result.stdout and
      'summary format drift' in result.stdout + result.stderr, 'one error hides another')
print('independent failure and skip drift: passed')

# Invalid arguments must fail before any fixture starts.
d = stage('parallel-invalid')
fixture(d, 'never.test.sh', f"touch '{d}/ran'")
for arguments in (['--jobs', '0'], ['--jobs', '-1'], ['--jobs', 'abc'], ['--jobs'],
                  ['--unknown']):
    result = subprocess.run(['bash', str(d / 'runner.sh'), *arguments],
                            capture_output=True, text=True, timeout=5)
    check(result.returncode == 2 and 'usage' in result.stderr.lower() and not (d / 'ran').exists(),
          f'invalid arguments accepted: {arguments}')
print('invalid --jobs: passed')

# Exercise the tr path without depending on the machine's python installation.
d = stage('parallel-sanitize-fallback')
fixture(d, 'bytes.test.sh', "printf 'before\\233after\\n'")
fake_bin = d / 'bin'
fake_bin.mkdir()
(fake_bin / 'python3').write_text('#!/bin/bash\nexit 1\n')
(fake_bin / 'python3').chmod(0o755)
result = subprocess.run(['bash', str(d / 'runner.sh'), '--jobs', '4'],
                        env={**os.environ, 'PATH': str(fake_bin) + ':' + os.environ['PATH']},
                        capture_output=True, timeout=10)
check(result.returncode == 0 and b'\x9b' not in result.stdout and
      b'before?after' in result.stdout, 'tr fallback did not sanitize captured bytes')
print('tr sanitize fallback: passed')

def alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    # Linux may briefly retain an already terminated orphan as a zombie.
    stat = Path(f'/proc/{pid}/stat')
    return not (stat.exists() and stat.read_text().split(') ', 1)[1].startswith('Z'))

# Signals and a killed worker must not leave the fixture or its child running.
for action in ('TERM', 'INT', 'worker-kill'):
    d = stage('parallel-' + action)
    fixture(d, 'hung.test.sh', f"echo $$ > '{d}/fixture-pid'\nsleep 60 &\necho $! > '{d}/child-pid'\nwait")
    with (d / 'output').open('w') as output:
        process = subprocess.Popen(['bash', str(d / 'runner.sh'), '--jobs', '4'],
                                   stdout=output, stderr=subprocess.STDOUT)
        try:
            deadline = time.monotonic() + 8
            while not (d / 'child-pid').exists() and time.monotonic() < deadline:
                time.sleep(0.02)
            check((d / 'child-pid').exists(), 'hung fixture never started')
            text = (d / 'output').read_text()
            start = re.search(r'^TEST_START\s+id=(\d+)\s+file=(\S+)\s+pid=(\d+)', text, re.M)
            check(start is not None, 'START must be visible while test is hung')
            number, file, worker = start.groups()
            if action == 'worker-kill':
                os.kill(int(worker), signal.SIGKILL)
            else:
                process.send_signal(getattr(signal, 'SIG' + action))
            check(process.wait(timeout=8) != 0, 'interrupted runner reported success')
            text = (d / 'output').read_text()
            if action == 'worker-kill':
                check('  - hung.test.sh' in text and '1 failed' in text,
                      'missing worker result was not counted as failure')
            else:
                check(f'TEST_INCOMPLETE id={number} file={file}' in text,
                      'interrupted file is not identified')
                check(not re.search(r'^TEST_END\s+id=' + number + r'\b', text, re.M),
                      'hung file falsely emitted END')
            pids = [int((d / name).read_text()) for name in ('fixture-pid', 'child-pid')]
            deadline = time.monotonic() + 3
            while any(alive(pid) for pid in pids) and time.monotonic() < deadline:
                time.sleep(0.02)
            check(not any(alive(pid) for pid in pids), 'worker descendants survived cleanup')
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            for name in ('fixture-pid', 'child-pid'):
                if (d / name).exists():
                    try:
                        os.kill(int((d / name).read_text()), signal.SIGKILL)
                    except ProcessLookupError:
                        pass
    print(action + ' cleanup and failure accounting: passed')

# Exercise the real Perl timeout shim: its child deliberately owns another group.
for action in ('TERM', 'INT', 'worker-kill'):
    d = stage('parallel-timeout-' + action)
    fake_bin = d / 'bin'
    fake_bin.mkdir()
    for command in ('bash', 'perl', 'sleep'):
        (fake_bin / command).symlink_to(shutil.which(command))
    (d / 'child.sh').write_text(f"echo $$ > '{d}/child-pid'\nexec sleep 60\n")
    fixture(d, 'hung.test.sh', f"source '{source.parent / '_test-helpers.sh'}'\n"
            f"echo $$ > '{d}/fixture-pid'\nPATH='{fake_bin}'\n_timeout 1 bash '{d}/child.sh'")
    with (d / 'output').open('w') as output:
        process = subprocess.Popen(['bash', str(d / 'runner.sh')],
                                   stdout=output, stderr=subprocess.STDOUT)
        try:
            deadline = time.monotonic() + 8
            while not (d / 'child-pid').exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            check((d / 'child-pid').exists(), 'timeout child never started')
            text = (d / 'output').read_text()
            worker = int(re.search(r'^TEST_START .*pid=(\d+)', text, re.M)[1])
            if action == 'worker-kill':
                os.kill(worker, signal.SIGKILL)
            else:
                process.send_signal(getattr(signal, 'SIG' + action))
            check(process.wait(timeout=8) != 0, 'timeout interruption reported success')
            time.sleep(1.2)
            check(not alive(int((d / 'child-pid').read_text())),
                  'detached timeout child survived its deadline after interruption')
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            for name in ('fixture-pid', 'child-pid'):
                if (d / name).exists():
                    try:
                        os.kill(int((d / name).read_text()), signal.SIGKILL)
                    except ProcessLookupError:
                        pass
    print(action + ' detached timeout child cleanup: passed')
PY
  assert_rc "parallel runner execution contract" 0 "$parallel_rc"
else
  SKIP=$((SKIP + 1))
  echo "  ⏭️ SKIP: parallel process observations require python3 and perl"
fi

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
