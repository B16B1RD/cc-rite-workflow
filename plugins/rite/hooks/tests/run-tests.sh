#!/bin/bash
# Run all rite hook tests
# Usage: bash plugins/rite/hooks/tests/run-tests.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Run the suite with a clean session-id env (Issue #1530). flow-state.sh now
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

# Discover test files from BOTH conventions/locations (Issue #1719):
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
for test_file in "${test_files[@]}"; do
  test_name="$(basename "$test_file")"
  TOTAL=$((TOTAL + 1))
  echo "=== Running: $test_name ==="
  test_rc=0
  # Captured rather than streamed so the skip count can be parsed per file. A
  # `| tee` pipeline was tried and rejected: under `set -euo pipefail` a failing
  # test aborts the runner before it can record the failure and continue, and the
  # pipe keeps the runner waiting on any background holder the test leaves behind.
  # The trade-off is that a hung file prints nothing until it returns — the
  # preceding `=== Running: X ===` line still identifies which file hung.
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
  # A visible ⏭️ marker with nothing parsed means a file is reporting skips in a
  # format the runner does not know about — surface it instead of undercounting.
  visible_skips=$(printf '%s\n' "$test_out" | grep -c '⏭️' || true)
  case "$visible_skips" in ''|*[!0-9]*) visible_skips=0 ;; esac
  if [ "$visible_skips" -gt 0 ] && [ "$file_skips" -eq 0 ]; then
    echo "WARNING: $test_name printed $visible_skips skip marker(s) but reported no count — summary format drift?" >&2
  fi
  SKIPPED=$((SKIPPED + file_skips))
  echo ""
done

echo "==============================="
if [ "$SKIPPED" -gt 0 ]; then
  echo "Results: $PASSED/$TOTAL passed, $FAILED failed, $SKIPPED skipped"
else
  echo "Results: $PASSED/$TOTAL passed, $FAILED failed"
fi
if [ ${#FAILED_TESTS[@]} -gt 0 ]; then
  echo "Failed tests:"
  for t in "${FAILED_TESTS[@]}"; do
    echo "  - $t"
  done
  exit 1
fi
echo "All tests passed!"
