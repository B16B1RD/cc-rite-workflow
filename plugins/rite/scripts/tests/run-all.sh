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
for test_file in "$SCRIPT_DIR"/*.test.sh; do
  [ -f "$test_file" ] || continue
  echo "--- Running: $(basename "$test_file") ---"
  test_rc=0
  test_out=$(bash "$test_file" 2>&1) || test_rc=$?
  printf '%s\n' "$test_out"
  if [ "$test_rc" -ne 0 ]; then
    FAILED_FILES+=("$(basename "$test_file")")
  fi
  file_skips=$(printf '%s\n' "$test_out" \
    | sed -n -E 's/^[[:space:]]*SKIP: ([0-9]+)[[:space:]]*$/\1/p; s/.*, ([0-9]+) skipped.*/\1/p' \
    | awk '{s += $1} END {print s + 0}')
  case "$file_skips" in ''|*[!0-9]*) file_skips=0 ;; esac
  SKIPPED=$((SKIPPED + file_skips))
  echo ""
done

if [ ${#FAILED_FILES[@]} -gt 0 ]; then
  echo "=== FAILED test files: ${FAILED_FILES[*]} ==="
  exit 1
elif [ "$SKIPPED" -gt 0 ]; then
  echo "=== All script tests passed ($SKIPPED skipped) ==="
  exit 0
else
  echo "=== All script tests passed ==="
  exit 0
fi
