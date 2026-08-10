#!/bin/bash
# Run all rite hook tests
# Usage: bash plugins/rite/hooks/tests/run-tests.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Run the suite with a clean session-id env. flow-state.sh now
# resolves session_id env-first (CLAUDE_CODE_SESSION_ID / CLAUDE_SESSION_ID) and
# only falls back to each sandbox's `.rite-session-id` file when env is absent.
# Most tests simulate a session by writing that file, so the dogfooding session's
# own ambient CLAUDE_CODE_SESSION_ID must not leak into the sandboxes (it would
# point every hook at a foreign per-session state file). Tests that exercise env
# resolution set the vars explicitly per-command, overriding this unset.
unset CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID

TOTAL=0
PASSED=0
FAILED=0
FAILED_TESTS=()

# Discover test files from BOTH conventions/locations:
#   1. this dir's `*.test.sh` — the hook/entry-point suite
#   2. the sibling `hooks/scripts/tests/test-*.sh` — the checker suite for
#      hooks/scripts/ scripts. It uses a `test-*.sh` name in a separate
#      directory, so the `*.test.sh` glob never reached it and those tests
#      ran nowhere despite existing. Collecting both into one list keeps a
#      single runner as the single source of test execution.
test_files=()
for f in "$SCRIPT_DIR"/*.test.sh; do
  [ -f "$f" ] && test_files+=("$f")
done
for f in "$SCRIPT_DIR"/../scripts/tests/test-*.sh; do
  [ -f "$f" ] && test_files+=("$f")
done

# Roll the per-file skip counts up into the headline. Without this, a platform-gated
# run prints a headline byte-identical to a fully-exercised one, and the reader has
# to scroll the whole log to learn that (for example) 10 groups of assertions never
# ran on macOS. The count is parsed from what the files already print — `SKIP: N`
# from print_summary, or `, N skipped` from the three files with their own summary.
SKIPPED=0
SKIP_ACCOUNTING_BROKEN=0
for test_file in "${test_files[@]}"; do
  test_name="$(basename "$test_file")"
  TOTAL=$((TOTAL + 1))
  echo "=== Running: $test_name ==="
  test_rc=0
  # Captured rather than streamed so the skip count can be parsed per file. A
  # `| tee` pipeline was tried and rejected because under `set -euo pipefail` a
  # failing test aborts the runner before it can record the failure and continue.
  # Capturing shares tee's other hazard rather than avoiding it: both wait for pipe
  # EOF, so a background writer outliving its test file stalls the runner (measured
  # 6s vs 0s), which direct fd inheritance did not. Two things bound that: every test
  # reaps its own background jobs in a cleanup trap, and `_timeout` puts its child in
  # a process group so a hung command's grandchildren die with it. The other trade-off
  # is that a hung file prints nothing until it returns — the preceding
  # `=== Running: X ===` line still identifies which file hung, but its output is
  # lost if the CI job times out.
  test_out=$(bash "$test_file" 2>&1) || test_rc=$?
  printf '%s\n' "$test_out"
  if [ "$test_rc" -eq 0 ]; then
    PASSED=$((PASSED + 1))
  else
    FAILED=$((FAILED + 1))
    FAILED_TESTS+=("$test_name")
  fi
  # Anchor both forms to a summary line rather than matching anywhere: a failure
  # diagnostic quoting ", 7 skipped" would otherwise be counted as seven skips.
  # A file emits one form or the other, so take whichever appears and stop —
  # summing both would double-count a file that ever printed both.
  file_skips=$(printf '%s\n' "$test_out" \
    | sed -n -E 's/^[[:space:]]*SKIP: ([0-9]+)[[:space:]]*$/\1/p' \
    | awk '{s += $1} END {print s + 0}')
  case "$file_skips" in ''|*[!0-9]*) file_skips=0 ;; esac
  if [ "$file_skips" -eq 0 ]; then
    file_skips=$(printf '%s\n' "$test_out" \
      | sed -n -E 's/^[^❌]*Results:[^❌]*, ([0-9]+) skipped.*$/\1/p' \
      | awk '{s += $1} END {print s + 0}')
    case "$file_skips" in ''|*[!0-9]*) file_skips=0 ;; esac
  fi
  # Cross-check the parsed count against the visible markers. A mismatch in either
  # direction means the file reports skips in a shape the runner does not know
  # about, and the undercount is exactly what this accounting exists to prevent —
  # so it FAILS the run rather than only warning. Counting only the zero case
  # would miss a file that mixes counted skip() calls with bare echoes.
  visible_skips=$(printf '%s\n' "$test_out" | grep -c '⏭️' || true)
  case "$visible_skips" in ''|*[!0-9]*) visible_skips=0 ;; esac
  if [ "$visible_skips" -ne "$file_skips" ]; then
    echo "ERROR: $test_name printed $visible_skips skip marker(s) but the summary reported $file_skips — summary format drift, the skip total below is wrong" >&2
    SKIP_ACCOUNTING_BROKEN=1
  fi
  SKIPPED=$((SKIPPED + file_skips))
  echo ""
done

echo "==============================="
if [ "$SKIPPED" -gt 0 ]; then
  # "gated group(s)", not "skipped": the unit is a skip call, and one call can gate
  # anywhere from one to eleven assertions. Naming it precisely stops the number
  # from being read as an assertion count it is not.
  echo "Results: $PASSED/$TOTAL passed, $FAILED failed, $SKIPPED gated group(s) skipped"
else
  echo "Results: $PASSED/$TOTAL passed, $FAILED failed"
fi
# The failure list comes before the accounting bail: both exit 1, and bailing
# first would swallow the only line that names which files failed. Drift and a
# real failure land together whenever a set -e test aborts after a skip() call
# but before its summary, so the two diagnostics have to coexist.
if [ ${#FAILED_TESTS[@]} -gt 0 ]; then
  echo "Failed tests:"
  for t in "${FAILED_TESTS[@]}"; do
    echo "  - $t"
  done
fi
if [ "$SKIP_ACCOUNTING_BROKEN" -eq 1 ]; then
  echo "Skip accounting is unreliable for this run (see the ERROR lines above)."
  exit 1
fi
if [ ${#FAILED_TESTS[@]} -gt 0 ]; then
  exit 1
fi
# The gated-group count rides on the success line too (mirrors run-all.sh): a bare
# "All tests passed!" under a run that skipped ten groups reads as full coverage,
# which is the exact misreading the counting exists to prevent.
echo "All tests passed!$( [ "$SKIPPED" -gt 0 ] && printf ' (%s gated group(s) skipped)' "$SKIPPED" )"
