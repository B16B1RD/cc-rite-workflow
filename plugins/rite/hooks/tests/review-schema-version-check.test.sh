#!/bin/bash
# Tests for hooks/scripts/review-schema-version-check.sh (Issue #1719)
#
# The script detects schema_version drift in review-result JSON files. Its
# accept list (1.0.0 / 1.0 / 1.1.0) is the canonical SoT from
# review-result-schema.md; any other value — including a missing key, invalid
# JSON, or a missing file — is drift (exit 1). These tests pin that contract
# so a future accept-list edit or JSON-parse change cannot silently regress it.
#
# Convention (shared with the sibling suite): mktemp sandbox, no network, no gh,
# GNU/BSD portable (jq only). --target resolves paths as-is, so a git repo is
# not required.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"

SCRIPT="$SCRIPT_DIR/../scripts/review-schema-version-check.sh"

echo "=== review-schema-version-check.sh tests ==="

if [ ! -f "$SCRIPT" ]; then
  echo "ERROR: $SCRIPT not found" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  # Emit the counted form so the runner rolls this into its "N skipped" headline —
  # a whole file that exits 0 without running anything would otherwise be scored
  # as a pass (Issue #2008 review I-03).
  echo "  ⏭️ SKIP: jq not available — review-schema-version-check requires jq"
  echo "SKIP: 1"
  exit 0
fi

SANDBOX="$(make_plain_sandbox)"
cleanup() { [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX"; }
trap 'rc=$?; cleanup; exit $rc' EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
trap 'cleanup; exit 129' HUP

# --- Fixtures -----------------------------------------------------------------
printf '{"schema_version":"1.1.0","findings":[]}\n' > "$SANDBOX/ok-110.json"
printf '{"schema_version":"1.0","findings":[]}\n'   > "$SANDBOX/ok-10.json"
printf '{"schema_version":"9.9.9","findings":[]}\n' > "$SANDBOX/drift-999.json"
printf '{"findings":[]}\n'                           > "$SANDBOX/missing-version.json"
printf 'not valid json {{{\n'                        > "$SANDBOX/invalid.json"

run() { bash "$SCRIPT" "$@" >/dev/null 2>&1; echo $?; }

# --- Invocation contract ------------------------------------------------------
assert "--help exits 0" "0" "$(run --help)"
assert "no targets exits 2 (invocation error)" "2" "$(run)"
assert "unknown argument exits 2" "2" "$(run --bogus)"
assert "--target without value exits 2" "2" "$(run --target)"

# --- Accept list (clean) ------------------------------------------------------
assert "accepted 1.1.0 exits 0" "0" "$(run --target "$SANDBOX/ok-110.json")"
assert "accepted 1.0 (legacy alias) exits 0" "0" "$(run --target "$SANDBOX/ok-10.json")"

# --- Drift (exit 1) -----------------------------------------------------------
assert "unlisted version 9.9.9 is drift (exit 1)" "1" "$(run --quiet --target "$SANDBOX/drift-999.json")"
assert "missing schema_version is drift (exit 1)" "1" "$(run --quiet --target "$SANDBOX/missing-version.json")"
assert "invalid JSON is drift (exit 1)" "1" "$(run --quiet --target "$SANDBOX/invalid.json")"
assert "missing file is drift (exit 1)" "1" "$(run --quiet --target "$SANDBOX/nonexistent.json")"

# --- Mixed batch: one drift among clean targets → exit 1 ----------------------
assert "one drift in a mixed batch fails the whole run" "1" \
  "$(run --quiet --target "$SANDBOX/ok-110.json" --target "$SANDBOX/drift-999.json")"

# --- Drift marker shape -------------------------------------------------------
drift_stderr="$(bash "$SCRIPT" --target "$SANDBOX/drift-999.json" 2>&1 >/dev/null || true)"
if printf '%s' "$drift_stderr" | grep -qE 'REVIEW_SCHEMA_VERSION_DRIFT=1; file=.*; schema_version=9\.9\.9'; then
  pass "drift marker names the offending file and version"
else
  fail "drift marker missing/malformed: $drift_stderr"
fi

print_summary "review-schema-version-check.sh"
