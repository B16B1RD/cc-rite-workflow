#!/usr/bin/env bash
# Smoke + validation tests for distributed-fix-drift-check.sh
#
# Validates against PR #350 baseline commit cec0140 (which contains the
# 5 known drift categories that motivated Issue #361) and ensures the
# checker reports drift findings on that commit.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/plugins/rite/hooks/scripts/distributed-fix-drift-check.sh"
BASELINE_COMMIT="cec0140"

if [ ! -x "$SCRIPT" ]; then
  echo "FAIL: $SCRIPT not executable" >&2
  exit 1
fi

PASS=0
FAIL=0

assert() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $desc — expected=$expected actual=$actual" >&2
    FAIL=$((FAIL + 1))
  fi
}

assert_ge() {
  local desc="$1" min="$2" actual="$3"
  if [ "$actual" -ge "$min" ]; then
    echo "PASS: $desc ($actual >= $min)"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $desc — expected>=$min actual=$actual" >&2
    FAIL=$((FAIL + 1))
  fi
}

# --- Test 1: usage / help works ----------------------------------------------
"$SCRIPT" --help >/dev/null 2>&1
assert "--help exits 0" "0" "$?"

# --- Test 2: missing args returns error code 2 -------------------------------
"$SCRIPT" >/dev/null 2>&1
assert "no args exits 2" "2" "$?"

# Accumulating tempfile manager (trap is set once, list grows as tests add files)
TMPFILES=()
trap 'rm -f "${TMPFILES[@]}"' EXIT

# --- Test 3: cec0140 fix.md baseline detects drift ---------------------------
TMP_FIX=$(mktemp)
TMPFILES+=("$TMP_FIX")

# Verify baseline commit is reachable before running Test 3. On shallow clones
# (typical CI setup), silently SKIP-ing would produce a false green. Fail the
# suite instead so the problem is visible.
if ! git cat-file -e "${BASELINE_COMMIT}^{commit}" 2>/dev/null; then
  echo "FAIL: baseline commit ${BASELINE_COMMIT} is not reachable" >&2
  echo "  Hint: run 'git fetch --depth=1 origin ${BASELINE_COMMIT}' or unshallow the repo" >&2
  FAIL=$((FAIL + 1))
elif git show "${BASELINE_COMMIT}:plugins/rite/commands/pr/fix.md" > "$TMP_FIX" 2>/dev/null; then
  out=$("$SCRIPT" --target "$TMP_FIX" 2>&1)
  rc=$?
  count=$(grep -c '^\[drift\]' <<< "$out" || true)
  assert_ge "cec0140 fix.md detects drift findings" 5 "$count"
  assert "cec0140 fix.md exits 1 (drift detected)" "1" "$rc"

  # Pattern-3: at least one if-wrap drift in cec0140 fix.md
  p3_count=$(grep -c '^\[drift\]\[P3\]' <<< "$out" || true)
  assert_ge "cec0140 fix.md Pattern-3 (if-wrap drift) detects >=1" 1 "$p3_count"

  # Pattern-2: reason-table drift detected
  p2_count=$(grep -c '^\[drift\]\[P2\]' <<< "$out" || true)
  assert_ge "cec0140 fix.md Pattern-2 (reason-table drift) detects >=1" 1 "$p2_count"
else
  echo "FAIL: git show failed for ${BASELINE_COMMIT}:plugins/rite/commands/pr/fix.md" >&2
  FAIL=$((FAIL + 1))
fi

# --- Test 4: synthetic clean file produces no drift --------------------------
CLEAN=$(mktemp)
TMPFILES+=("$CLEAN")
cat > "$CLEAN" <<'EOF'
# Clean test fixture

This file contains no drift patterns.

Some prose explaining behavior.
EOF
"$SCRIPT" --target "$CLEAN" >/dev/null 2>&1
assert "synthetic clean file exits 0" "0" "$?"

# --- Summary -----------------------------------------------------------------
echo
echo "Results: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
