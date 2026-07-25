#!/bin/bash
# Run all script tests
# Usage: bash plugins/rite/scripts/tests/run-all.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FAILED_FILES=()

echo "=== Script Tests ==="
echo ""

# Roll per-file skip counts into the closing line so a platform-gated run does not
# read as a fully-exercised one (mirrors hooks/tests/run-tests.sh).
SKIPPED=0
SKIP_ACCOUNTING_BROKEN=0
for test_file in "$SCRIPT_DIR"/*.test.sh; do
  [ -f "$test_file" ] || continue
  echo "--- Running: $(basename "$test_file") ---"
  test_rc=0
  # Captured rather than streamed so the skip count can be parsed per file. A
  # `| tee` pipeline was tried and rejected: under `set -euo pipefail` a failing
  # test aborts the runner before it can record the failure and continue, and the
  # pipe keeps the runner waiting on any background holder the test leaves behind.
  # The trade-off is that a hung file prints nothing until it returns — the
  # preceding `=== Running: X ===` line still identifies which file hung.
  test_out=$(bash "$test_file" 2>&1) || test_rc=$?
  printf '%s\n' "$test_out"
  if [ "$test_rc" -ne 0 ]; then
    FAILED_FILES+=("$(basename "$test_file")")
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
    echo "ERROR: $(basename "$test_file") printed $visible_skips skip marker(s) but the summary reported $file_skips — summary format drift, the skip total below is wrong" >&2
    SKIP_ACCOUNTING_BROKEN=1
  fi
  SKIPPED=$((SKIPPED + file_skips))
  echo ""
done

# The skip count is reported on the red path too — "what did not run" is at least
# as important when something failed.
# The failure list comes before the accounting bail: both exit 1, and bailing
# first would leave this runner with no summary line at all, since it has no
# unconditional "Results:" equivalent (mirrors hooks/tests/run-tests.sh).
if [ ${#FAILED_FILES[@]} -gt 0 ]; then
  echo "=== FAILED test files: ${FAILED_FILES[*]}$( [ "$SKIPPED" -gt 0 ] && printf " (%s gated group(s) skipped)" "$SKIPPED" ) ==="
fi
if [ "$SKIP_ACCOUNTING_BROKEN" -eq 1 ]; then
  echo "=== Skip accounting is unreliable for this run (see the ERROR lines above) ==="
  exit 1
fi
if [ ${#FAILED_FILES[@]} -gt 0 ]; then
  exit 1
elif [ "$SKIPPED" -gt 0 ]; then
  echo "=== All script tests passed ($SKIPPED gated group(s) skipped) ==="
  exit 0
else
  echo "=== All script tests passed ==="
  exit 0
fi
