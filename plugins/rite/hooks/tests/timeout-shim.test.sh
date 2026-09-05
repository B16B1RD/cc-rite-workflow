#!/bin/bash
# timeout-shim.test.sh — pins the `_timeout` perl fallback's exit-code contract.
#
# Why this file exists (review F-03): `_timeout` falls back to a perl
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
#   TC-5b fallback: a fractional deadline is rejected with rc 125 (alarm truncates
#         to an integer, so accepting it would disable the timeout entirely)
#   TC-6  fallback: stdin stays connected through the shim
#   TC-7  drift: every discovered `_timeout` copy is byte-identical
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

# The suite as a whole needs timeout(1) OR perl(1); only the fallback TCs below
# need perl specifically. Exiting 1 here would silently promote perl to a hard
# requirement for the whole suite and contradict what CONTRIBUTING.md and
# _test-helpers.sh state. Skip TC-1..TC-6 instead and still run the drift checks
# (TC-7 / TC-8), which are platform-independent.
HAS_PERL=1
if ! command -v perl >/dev/null 2>&1; then
  HAS_PERL=0
fi
# The blocking gate must exercise the fallback: it is the only leg that can fail
# the build, and the fallback runs on no other. `[ -d /proc ]` rather than
# `uname -s` because `uname` resolves through the same PATH that would be hiding
# `perl`.
if [ -d /proc ] && [ "$HAS_PERL" != 1 ]; then
  fail "perl probe: perl(1) unavailable on Linux (missing or shadowed on PATH?) — the _timeout fallback TCs must never be skipped on the blocking gate"
fi

# A PATH that deliberately omits `timeout` so `command -v timeout` fails and the
# perl branch runs even on a host that has GNU coreutils. Only the interpreters
# the shim and the fixtures need are linked in.
#
# The fixture is built fail-closed. A missing tool here is indistinguishable from
# a passing test in the negative assertions below: TC-5 passes when its canary is
# absent, so silently dropping `touch` would make it green even against the very
# `exec @ARGV` regression it exists to catch. Resolve every tool to an absolute
# path (`kill` is excluded — `command -v kill` returns the bash builtin name,
# which would produce a self-referential symlink; TC-3's `sh -c 'kill -9 $$'`
# uses the shell builtin and needs no binary).
if [ "$HAS_PERL" = 1 ]; then
  FAKE_BIN="$TEST_DIR/bin"
  mkdir -p "$FAKE_BIN"
  for tool in perl bash sh env sleep cat touch; do
    tool_path=$(command -v "$tool" 2>/dev/null) || {
      echo "ERROR: fixture tool '$tool' not found on PATH — the TCs below would pass vacuously" >&2
      exit 1
    }
    case "$tool_path" in
      /*) ;;
      *)
        echo "ERROR: '$tool' resolved to '$tool_path' (not an absolute path — builtin or alias?)" >&2
        exit 1
        ;;
    esac
    ln -sf "$tool_path" "$FAKE_BIN/$tool" || {
      echo "ERROR: failed to link fixture tool '$tool' into $FAKE_BIN" >&2
      exit 1
    }
    [ -x "$FAKE_BIN/$tool" ] || {
      echo "ERROR: fixture link $FAKE_BIN/$tool is not executable" >&2
      exit 1
    }
  done
  if [ -e "$FAKE_BIN/timeout" ]; then
    echo "ERROR: fixture PATH unexpectedly contains timeout — the fallback would not run" >&2
    exit 1
  fi

  # run_fallback <seconds> <command...> — invoke _timeout with the fallback forced.
  # Runs in a child bash so the restricted PATH cannot leak into later TCs, and
  # echoes the exit code so callers can assert on it without `set -e` aborting.
  # `declare -F` guards against the child sourcing successfully but not defining
  # `_timeout` (a rename would otherwise surface as 127 and be misread as TC-4's
  # "missing program" result). 126 is the sentinel — every other code the shim can
  # return is asserted by some TC (0/2/3 by TC-2, 124 by TC-1, 125 by TC-5b,
  # 127 by TC-4), so a fixture failure must not reuse one of them.
  run_fallback() {
    local secs="$1"; shift
    PATH="$FAKE_BIN" bash -c '
      source "$1" || exit 126
      shift
      declare -F _timeout >/dev/null || exit 126
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
  #
  # This is a negative assertion — it passes when the canary is ABSENT — so it is
  # preceded by a positive control proving the canary mechanism itself works under
  # this fixture. Without it, anything that stops the child from running at all
  # (a broken fixture, a missing `touch`) reads as "correctly not shell-interpreted".
  canary="$TEST_DIR/shell-interpreted.canary"
  rm -f "$canary"
  run_fallback 5 touch "$canary" >/dev/null 2>&1
  if [ -e "$canary" ]; then
    pass "TC-5 control: the canary mechanism works under this fixture"
  else
    fail "TC-5 control: the canary was not created even by a direct touch — fixture is broken, the negative assertion below would be vacuous"
  fi
  rm -f "$canary"
  run_fallback 5 "sh -c 'touch $canary'" >/dev/null 2>&1
  rc=$?
  if [ -e "$canary" ]; then
    fail "TC-5 the shim handed a single argument to /bin/sh (canary created) — use exec BLOCK LIST"
  elif [ "$rc" -ne 127 ]; then
    fail "TC-5 expected 127 (execvp of a nonexistent program named by the whole string) but got $rc — the child may not have run at all"
  else
    pass "TC-5 single argument goes through execvp (rc 127), never /bin/sh"
  fi

  echo "=== TC-5b: a fractional deadline is rejected with a distinguishable code ==="
  # perl's alarm truncates to an integer, so `alarm 0.5` becomes `alarm 0` — no
  # timeout at all, and waitpid then blocks until the CI job limit. The shim rejects
  # fractions instead. The exit code matters as much as the rejection: every caller
  # reads "not 124" as "no hang", so `die` (255) would be scored as a pass. 125 is
  # outside every code the shim otherwise returns.
  tc5b_err="$TEST_DIR/tc5b.err"
  run_fallback 0.5 sh -c 'exit 0' >/dev/null 2>"$tc5b_err"
  rc=$?
  if [ "$rc" -eq 125 ] && grep -q 'fractional seconds are not supported' "$tc5b_err"; then
    pass "TC-5b fractional seconds rejected with rc 125 and a matching diagnostic"
  elif [ "$rc" -eq 125 ]; then
    fail "TC-5b got rc 125 but not the rejection message — a broken fixture would look the same: $(cat "$tc5b_err")"
  else
    fail "TC-5b expected 125 for a fractional deadline but got $rc (255/die would read as 'no hang' to every caller)"
  fi
  rm -f "$tc5b_err"

  echo "=== TC-6: stdin stays connected through the shim ==="
  stdin_out=$(printf 'hello-stdin\n' | run_fallback 5 sh -c 'cat' 2>/dev/null)
  if [ "$stdin_out" = "hello-stdin" ]; then
    pass "TC-6 stdin is passed through to the child"
  else
    fail "TC-6 stdin was not forwarded (got '$stdin_out')"
  fi
else
  skip "TC-1..TC-6 (perl(1) unavailable — the _timeout fallback cannot be exercised here; TC-7/TC-8 still check drift)"
fi

echo "=== TC-7: the _timeout copies are byte-identical ==="
# The shim is duplicated because five test files cannot source _test-helpers.sh.
# A fix applied to one copy (the signal mapping and the exec block form both were)
# must land in all of them, so compare the function bodies directly.
#
# The file list is DISCOVERED, never hardcoded. This PR established the pattern of
# inlining the shim into a test file, so a seventh copy is a realistic addition —
# and a hardcoded list would leave it invisible to both this TC and TC-8, letting
# the pre-fix `exec @ARGV` form live on indefinitely.
TIMEOUT_SEARCH_ROOTS=(
  "$PLUGIN_ROOT/hooks/tests"
  "$PLUGIN_ROOT/scripts/tests"
  "$PLUGIN_ROOT/hooks/scripts/tests"   # run-tests.sh also executes test-*.sh from here
)
# A vanished root must not be absorbed by 2>/dev/null and the surviving roots' hits.
for _root in "${TIMEOUT_SEARCH_ROOTS[@]}"; do
  [ -d "$_root" ] || fail "TC-7 discovery root missing: $_root (layout changed?)"
done
# ERE rather than a literal: an additional copy written as `function _timeout {` or
# with leading whitespace would otherwise be invisible to both TC-7 and TC-8.
mapfile -t TIMEOUT_COPIES < <(grep -rlE '^[[:space:]]*(function[[:space:]]+)?_timeout[[:space:]]*(\(\))?[[:space:]]*\{' "${TIMEOUT_SEARCH_ROOTS[@]}" 2>/dev/null | sort)
REFERENCE_COPY="$PLUGIN_ROOT/hooks/tests/_test-helpers.sh"
# Floor check: discovery returning too few files is itself a failure mode (a moved
# directory, a reformatted definition line), and would otherwise make TC-7/TC-8
# vacuously green over an empty or truncated set. The floor only does that job while it
# equals the real copy count — leaving it below the count buys slack that hides exactly the
# reformatted-definition case, so a PR that ADDS a copy must raise it in the same change.
if [ "${#TIMEOUT_COPIES[@]}" -lt 6 ]; then
  fail "TC-7 discovery found only ${#TIMEOUT_COPIES[@]} _timeout definition(s) (expected >= 6) — either the grep pattern or the layout changed, or copies were deliberately consolidated, in which case lower this floor and TC-8's; conversely, raise both when you add a copy: ${TIMEOUT_COPIES[*]-<none>}"
elif ! printf '%s\n' "${TIMEOUT_COPIES[@]}" | grep -qxF "$REFERENCE_COPY"; then
  fail "TC-7 discovery did not include the reference copy $REFERENCE_COPY"
else
  extract_timeout_body() {
    awk '/^[[:space:]]*(function[[:space:]]+)?_timeout[[:space:]]*(\(\))?[[:space:]]*\{/ { capture = 1 } capture { print } /^\}$/ { if (capture) exit }' "$1"
  }
  reference_body=$(extract_timeout_body "$REFERENCE_COPY")
  if [ -z "$reference_body" ]; then
    fail "TC-7 could not extract _timeout from $REFERENCE_COPY (definition renamed or reformatted?)"
  else
    drifted=()
    for copy in "${TIMEOUT_COPIES[@]}"; do
      [ "$copy" = "$REFERENCE_COPY" ] && continue
      body=$(extract_timeout_body "$copy")
      # An empty extraction is drift too — otherwise a reformatted copy would
      # compare "nothing" against the reference and be reported as matching.
      if [ -z "$body" ] || [ "$body" != "$reference_body" ]; then
        drifted+=("$copy")
      fi
    done
    if [ "${#drifted[@]}" -eq 0 ]; then
      pass "TC-7 all ${#TIMEOUT_COPIES[@]} discovered _timeout copies match _test-helpers.sh"
    else
      fail "TC-7 _timeout drifted from _test-helpers.sh in: ${drifted[*]}"
    fi
  fi
fi

echo "=== TC-8: every _timeout definition carries the fail-closed guard ==="
# Without the guard a host lacking both backends falls through to rc 127, which
# every caller reads as "no hang" — the exact silent pass the shim exists to stop.
if [ "${#TIMEOUT_COPIES[@]}" -lt 6 ]; then
  fail "TC-8 skipped because discovery failed (see TC-7)"
else
  missing_guard=()
  for copy in "${TIMEOUT_COPIES[@]}"; do
    if ! grep -q 'neither timeout(1) nor perl(1) is available' "$copy"; then
      missing_guard+=("$copy")
    fi
  done
  if [ "${#missing_guard[@]}" -eq 0 ]; then
    pass "TC-8 all ${#TIMEOUT_COPIES[@]} _timeout definitions abort when no backend exists"
  else
    fail "TC-8 fail-closed guard missing in: ${missing_guard[*]}"
  fi
fi

# Explicit exit rather than relying on print_summary being the last command —
# a single line appended below would otherwise swallow every failure.
if ! print_summary "timeout-shim"; then
  exit 1
fi
