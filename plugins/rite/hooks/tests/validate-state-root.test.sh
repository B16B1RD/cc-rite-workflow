#!/bin/bash
# Security pin tests for hooks/_validate-state-root.sh (the governing rationale, AC-3)
#
# _validate-state-root.sh is the single source of truth for STATE_ROOT
# validation across the state-read helpers. Its rejection rules (path
# traversal `..`, shell metacharacters `$` / backtick, control characters)
# are a defence-in-depth guard against a future caller passing an untrusted
# path. Until now it only ran via the happy path of its callers; this test
# exercises the rejection branches DIRECTLY so a regex loosening cannot
# silently reopen the injection surface.
#
# Convention: no sandbox needed — the helper validates the argument string
# only (no filesystem access). GNU/BSD portable.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"

SCRIPT="$SCRIPT_DIR/../_validate-state-root.sh"

echo "=== _validate-state-root.sh security pin tests ==="

if [ ! -f "$SCRIPT" ]; then
  echo "ERROR: $SCRIPT not found" >&2
  exit 1
fi

rc() { bash "$SCRIPT" "$@" >/dev/null 2>&1; echo $?; }

# --- Accept: a normalized path with no traversal / metachar / control char ---
assert "clean absolute path accepted (exit 0)" "0" "$(rc "/home/user/project/.rite/state")"
assert "clean relative path accepted (exit 0)" "0" "$(rc "some/nested/state")"

# --- Reject: empty ------------------------------------------------------------
assert "empty STATE_ROOT rejected (exit 1)" "1" "$(rc "")"
assert "missing argument rejected (exit 1)" "1" "$(rc)"

# --- Reject: path traversal ---------------------------------------------------
assert "parent traversal '..' rejected (exit 1)" "1" "$(rc "/home/user/../etc/state")"
assert "leading '..' rejected (exit 1)" "1" "$(rc "../outside")"

# --- Reject: shell metacharacters ---------------------------------------------
assert "'\$' expansion metachar rejected (exit 1)" "1" "$(rc '/home/$USER/state')"
assert "backtick command-substitution metachar rejected (exit 1)" "1" "$(rc '/home/`whoami`/state')"

# --- Reject: control characters -----------------------------------------------
assert "embedded newline rejected (exit 1)" "1" "$(rc "$(printf '/home/a\nb/state')")"
assert "embedded tab rejected (exit 1)" "1" "$(rc "$(printf '/home/a\tb/state')")"

# --- Rejection diagnostics reach stderr ---------------------------------------
traversal_err="$(bash "$SCRIPT" "/home/user/../etc" 2>&1 >/dev/null || true)"
if printf '%s' "$traversal_err" | grep -qE 'unsafe traversal or shell metacharacter'; then
  pass "traversal rejection prints a descriptive ERROR to stderr"
else
  fail "traversal ERROR missing/malformed: $traversal_err"
fi
ctrl_err="$(bash "$SCRIPT" "$(printf '/home/a\nb')" 2>&1 >/dev/null || true)"
if printf '%s' "$ctrl_err" | grep -qE 'control characters'; then
  pass "control-char rejection prints a descriptive ERROR to stderr"
else
  fail "control-char ERROR missing/malformed: $ctrl_err"
fi

print_summary "_validate-state-root.sh"
