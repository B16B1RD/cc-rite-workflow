#!/bin/bash
# Run all script tests
# Usage: bash plugins/rite/scripts/tests/run-all.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FAILED_FILES=()

echo "=== Script Tests ==="
echo ""

for test_file in "$SCRIPT_DIR"/*.test.sh; do
  [ -f "$test_file" ] || continue
  echo "--- Running: $(basename "$test_file") ---"
  if bash "$test_file"; then
    :
  else
    FAILED_FILES+=("$(basename "$test_file")")
  fi
  echo ""
done

if [ ${#FAILED_FILES[@]} -gt 0 ]; then
  echo "=== FAILED test files: ${FAILED_FILES[*]} ==="
  exit 1
else
  echo "=== All script tests passed ==="
  exit 0
fi
