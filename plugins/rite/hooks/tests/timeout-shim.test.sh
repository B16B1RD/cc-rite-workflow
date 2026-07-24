#!/bin/bash
# timeout-shim.test.sh — pins the `_timeout` perl fallback's exit-code contract.
#
# Why this file exists (Issue #2008 review F-03): `_timeout` falls back to a perl
# fork/waitpid shim when GNU `timeout` is absent, but that branch runs on no
# blocking CI leg — ubuntu always has `timeout`, and the macOS leg is
# `continue-on-error` during rollout. Every caller of `_timeout` treats a non-124
# exit code as "no hang", so any defect in the fallback (a wrong signal mapping, a
# missing interpreter, a shell-interpreted argv) turns hang assertions into silent
# passes rather than failures. These TCs execute the fallback unconditionally by
# invoking the suite through a PATH that deliberately excludes `timeout`, so the
# contract is verified on every platform.
#
# Covered:
#   TC-1  fallback: exceeding the deadline exits 124 (the value callers assert on)
#   TC-2  fallback: a normal exit code is propagated verbatim (0 / 2 / 3)
#   TC-3  fallback: a signal-killed child maps to 128+N, matching timeout(1)
#   TC-4  fallback: a missing program exits 127
#   TC-5  fallback: a single argument containing shell metacharacters is NOT
#         shell-interpreted (`exec BLOCK LIST` forces execvp)
#   TC-6  fallback: stdin stays connected through the shim
#   TC-7  drift: the 6 `_timeout` copies across the suite are byte-identical
#   TC-8  drift: every file defining `_timeout` also carries the fail-closed guard
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"

TEST_DIR="$(mktemp -d)" || exit 1
TEST_DIR="$(cd "$TEST_DIR" && pwd -P)" || exit 1
cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT

PASS=0
FAIL=0
FAILED_NAMES=()
pass() { PASS=$((PASS + 1)); echo "  ✅ PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); FAILED_NAMES+=("$1"); echo "  ❌ FAIL: $1"; }

if ! command -v perl >/dev/null 2>&1; then
  echo "ERROR: perl(1) is required to exercise the _timeout fallback branch." >&2
  echo "  The fallback is the whole subject of this file, so skipping it would" >&2
  echo "  defeat the purpose. Install perl to run the suite." >&2
  exit 1
fi

# A PATH that deliberately omits `timeout` so `command -v timeout` fails and the
# perl branch runs even on a host that has GNU coreutils. Only the interpreters
# the shim and the fixtures need are linked in.
FAKE_BIN="$TEST_DIR/bin"
mkdir -p "$FAKE_BIN"
for tool in perl bash sh env sleep kill cat touch; do
  tool_path=$(command -v "$tool" 2>/dev/null) || continue
  ln -sf "$tool_path" "$FAKE_BIN/$tool"
done
if [ -e "$FAKE_BIN/timeout" ]; then
  echo "ERROR: fixture PATH unexpectedly contains timeout — the fallback would not run" >&2
  exit 1
fi

# run_fallback <seconds> <command...> — invoke _timeout with the fallback forced.
# Runs in a child bash so the restricted PATH cannot leak into later TCs, and
# echoes the exit code so callers can assert on it without `set -e` aborting.
run_fallback() {
  local secs="$1"; shift
  PATH="$FAKE_BIN" bash -c '
    source "$1"; shift
    _timeout "$@"
  ' _ "$SCRIPT_DIR/_test-helpers.sh" "$secs" "$@"
}

echo "=== TC-1: exceeding the deadline exits 124 ==="
run_fallback 1 sleep 10 >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 124 ]; then
  pass "TC-1 timeout maps to 124"
else
  fail "TC-1 expected 124 but got $rc (callers assert on 124 to detect hangs)"
fi

echo "=== TC-2: a normal exit code is propagated verbatim ==="
tc2_ok=1
for expected in 0 2 3; do
  run_fallback 5 sh -c "exit $expected" >/dev/null 2>&1
  rc=$?
  if [ "$rc" -ne "$expected" ]; then
    fail "TC-2 exit $expected was reported as $rc"
    tc2_ok=0
  fi
done
[ "$tc2_ok" = "1" ] && pass "TC-2 exit codes 0/2/3 propagate unchanged"

echo "=== TC-3: a signal-killed child maps to 128+N ==="
# `exit($? >> 8)` alone reports 0 here (WEXITSTATUS of a signalled child), which
# would make a crashed hook indistinguishable from a clean run for the strict rc
# comparisons in review-helpers-gate-behavior.test.sh.
run_fallback 5 sh -c 'kill -9 $$' >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 137 ]; then
  pass "TC-3 SIGKILL maps to 137 (128+9), matching timeout(1)"
else
  fail "TC-3 expected 137 for a SIGKILL'd child but got $rc (a 0 here would score a crash as success)"
fi

echo "=== TC-4: a missing program exits 127 ==="
run_fallback 5 "$TEST_DIR/definitely-not-a-program" >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 127 ]; then
  pass "TC-4 missing program exits 127"
else
  fail "TC-4 expected 127 for a missing program but got $rc"
fi

echo "=== TC-5: a single metacharacter-bearing argument is not shell-interpreted ==="
# perl's `exec LIST` shells out when LIST holds exactly one element containing
# metacharacters; the block form `exec { $ARGV[0] } @ARGV` forces execvp. GNU
# timeout never shells out, so the shim must not either.
canary="$TEST_DIR/shell-interpreted.canary"
rm -f "$canary"
run_fallback 5 "sh -c 'touch $canary'" >/dev/null 2>&1
if [ -e "$canary" ]; then
  fail "TC-5 the shim handed a single argument to /bin/sh (canary created) — use exec BLOCK LIST"
else
  pass "TC-5 single argument goes through execvp, never /bin/sh"
fi

echo "=== TC-6: stdin stays connected through the shim ==="
stdin_out=$(printf 'hello-stdin\n' | run_fallback 5 sh -c 'cat' 2>/dev/null)
if [ "$stdin_out" = "hello-stdin" ]; then
  pass "TC-6 stdin is passed through to the child"
else
  fail "TC-6 stdin was not forwarded (got '$stdin_out')"
fi

echo "=== TC-7: the _timeout copies are byte-identical ==="
# The shim is duplicated because five test files cannot source _test-helpers.sh.
# A fix applied to one copy (the signal mapping and the exec block form both were)
# must land in all of them, so compare the function bodies directly.
TIMEOUT_COPIES=(
  "$PLUGIN_ROOT/hooks/tests/_test-helpers.sh"
  "$PLUGIN_ROOT/hooks/tests/pre-tool-bash-guard.test.sh"
  "$PLUGIN_ROOT/hooks/tests/wiki-branch-init.test.sh"
  "$PLUGIN_ROOT/hooks/tests/wiki-query-inject.test.sh"
  "$PLUGIN_ROOT/scripts/tests/projects-items-fetch.test.sh"
  "$PLUGIN_ROOT/scripts/tests/review-findings-maps.test.sh"
)
extract_timeout_body() {
  awk '/^_timeout\(\) \{$/ { capture = 1 } capture { print } /^\}$/ { if (capture) exit }' "$1"
}
reference_body=$(extract_timeout_body "${TIMEOUT_COPIES[0]}")
if [ -z "$reference_body" ]; then
  fail "TC-7 could not extract _timeout from ${TIMEOUT_COPIES[0]} (definition renamed or reformatted?)"
else
  drifted=()
  for copy in "${TIMEOUT_COPIES[@]:1}"; do
    body=$(extract_timeout_body "$copy")
    if [ "$body" != "$reference_body" ]; then
      drifted+=("$copy")
    fi
  done
  if [ "${#drifted[@]}" -eq 0 ]; then
    pass "TC-7 all ${#TIMEOUT_COPIES[@]} _timeout copies match _test-helpers.sh"
  else
    fail "TC-7 _timeout drifted from _test-helpers.sh in: ${drifted[*]}"
  fi
fi

echo "=== TC-8: every _timeout definition carries the fail-closed guard ==="
# Without the guard a host lacking both backends falls through to rc 127, which
# every caller reads as "no hang" — the exact silent pass the shim exists to stop.
missing_guard=()
for copy in "${TIMEOUT_COPIES[@]}"; do
  if ! grep -q 'neither timeout(1) nor perl(1) is available' "$copy"; then
    missing_guard+=("$copy")
  fi
done
if [ "${#missing_guard[@]}" -eq 0 ]; then
  pass "TC-8 all _timeout definitions abort when no backend exists"
else
  fail "TC-8 fail-closed guard missing in: ${missing_guard[*]}"
fi

print_summary "timeout-shim"
