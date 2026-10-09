#!/bin/bash
# Tests for issue-create-gate.sh
# Usage: bash plugins/rite/scripts/tests/issue-create-gate.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GATE="$SCRIPT_DIR/../issue-create-gate.sh"
TEST_DIR="$(mktemp -d)"
PASS=0
FAIL=0
trap 'rm -rf "$TEST_DIR"' EXIT

pass() { PASS=$((PASS + 1)); echo "  ✅ PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ❌ FAIL: $1"; }

# The session and state root belong to the fixture, never to the session running the tests.
unset CLAUDE_SESSION_ID CODEX_THREAD_ID GROK_SESSION_ID RITE_HOST RITE_STATE_ROOT
export CLAUDE_CODE_SESSION_ID="11111111-2222-4333-8444-555555555555"
REPO="$TEST_DIR/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
GATE_FILE="$REPO/.rite/state/issue-create-gate-$CLAUDE_CODE_SESSION_ID"

gate() { (cd "$REPO" && bash "$GATE" "$@"); }
record_all() { for s in "$@"; do gate record --step "$s"; done; }

echo "=== issue-create-gate.sh tests ==="

echo "TC-1: single Issue order (duplicate_check → confirm → fact_check) passes verify"
rm -f "$GATE_FILE"
record_all duplicate_check confirm fact_check
if gate verify 2>/dev/null; then pass "single order verified"; else fail "single order rejected"; fi

echo "TC-2: decompose order (duplicate_check → fact_check → confirm) passes verify"
rm -f "$GATE_FILE"
record_all duplicate_check fact_check confirm
if gate verify 2>/dev/null; then pass "decompose order verified"; else fail "decompose order rejected"; fi

echo "TC-3: each missing step is rejected and named on stderr"
for missing in duplicate_check confirm fact_check; do
  rm -f "$GATE_FILE"
  printf '%s\n' duplicate_check confirm fact_check | grep -vx "$missing" > "$TEST_DIR/steps" || true
  mkdir -p "$(dirname "$GATE_FILE")"
  cp "$TEST_DIR/steps" "$GATE_FILE"
  if err=$(gate verify 2>&1); then
    fail "verify passed without $missing"
  elif grep -q "不足: .*$missing" <<< "$err"; then
    pass "verify rejected and named $missing"
  else
    fail "verify did not name $missing: $err"
  fi
done

echo "TC-4: no record at all is rejected"
rm -f "$GATE_FILE"
if gate verify 2>/dev/null; then fail "verify passed with no record"; else pass "verify rejected with no record"; fi

echo "TC-5: duplicate_check resets the steps left by an earlier run"
rm -f "$GATE_FILE"
record_all duplicate_check confirm fact_check
gate record --step duplicate_check
if gate verify 2>/dev/null; then fail "stale confirm/fact_check carried over"; else pass "earlier steps reset"; fi
record_all confirm fact_check
if gate verify 2>/dev/null; then pass "verify passes after the new run records its steps"; else fail "new run rejected"; fi

echo "TC-6: recording the same step twice keeps the gate valid"
rm -f "$GATE_FILE"
record_all duplicate_check fact_check confirm fact_check
if gate verify 2>/dev/null && [ "$(grep -cx fact_check "$GATE_FILE")" -eq 1 ]; then
  pass "repeated step recorded once"
else
  fail "repeated step broke the record"
fi

echo "TC-7: consume makes the next verify fail"
gate consume
if [ ! -e "$GATE_FILE" ] && ! gate verify 2>/dev/null; then pass "consumed"; else fail "gate still open after consume"; fi

echo "TC-8: confirm / fact_check without duplicate_check is refused"
rm -f "$GATE_FILE"
if err=$(gate record --step confirm 2>&1); then
  fail "confirm recorded without duplicate_check"
elif grep -q '重複検出' <<< "$err" && [ ! -e "$GATE_FILE" ]; then
  pass "confirm refused before duplicate_check"
else
  fail "unexpected refusal: $err"
fi

echo "TC-9: unknown step is refused"
if gate record --step review 2>/dev/null; then fail "unknown step accepted"; else pass "unknown step refused"; fi

echo "TC-10: the gate belongs to one session"
rm -f "$GATE_FILE"
record_all duplicate_check confirm fact_check
if (cd "$REPO" && CLAUDE_CODE_SESSION_ID="99999999-2222-4333-8444-555555555555" bash "$GATE" verify 2>/dev/null); then
  fail "another session passed verify"
else
  pass "another session rejected"
fi

echo "TC-11: an unresolvable session fails verify instead of passing"
if (cd "$REPO" && env -u CLAUDE_CODE_SESSION_ID bash "$GATE" verify 2>/dev/null); then
  fail "verify passed without a session"
else
  pass "verify failed without a session"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
