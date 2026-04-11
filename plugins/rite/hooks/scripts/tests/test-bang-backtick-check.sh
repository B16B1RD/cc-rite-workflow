#!/usr/bin/env bash
# Smoke + validation tests for bang-backtick-check.sh
#
# Validates:
#   1. --help exits 0
#   2. Missing args exits 2
#   3. Repo-wide --all scan is clean (AC-3: false positive zero)
#   4. Fixture with `if !` pattern is detected (AC-4, P1)
#   5. Fixture with `!foo` pattern is detected (AC-4, P2)
#   6. Fixture with innocent patterns (`//!`, `![...](...)`, `!\[...\]`) is clean

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/plugins/rite/hooks/scripts/bang-backtick-check.sh"

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

TMPFILES=()
trap 'rm -f "${TMPFILES[@]}"' EXIT

# --- Test 1: --help exits 0 --------------------------------------------------
"$SCRIPT" --help >/dev/null 2>&1
rc=$?
assert "--help exits 0" "0" "$rc"

# --- Test 2: no args exits 2 -------------------------------------------------
"$SCRIPT" >/dev/null 2>&1
rc=$?
assert "no args exits 2" "2" "$rc"

# --- Test 3: repo --all is clean (AC-3 false positive zero) ------------------
"$SCRIPT" --all --quiet >/dev/null 2>&1
rc=$?
assert "repo-wide --all exits 0 (no false positives)" "0" "$rc"

# --- Test 4: fixture with `if !` triggers P1 detection (AC-4) ---------------
FIXTURE_P1=$(mktemp --suffix=.md)
TMPFILES+=("$FIXTURE_P1")
cat > "$FIXTURE_P1" << 'EOF'
# Fixture: P1 pattern

This line contains `if !` which is the Issue #365 triggering pattern.
Another one: check `grep !` usage.
EOF

out=$("$SCRIPT" --target "$FIXTURE_P1" 2>&1)
rc=$?
assert "P1 fixture exits 1 (detected)" "1" "$rc"
p1_count=$(grep -c '^\[bang-backtick\]\[P1\]' <<< "$out" || true)
if [ "$p1_count" -ge 2 ]; then
  echo "PASS: P1 fixture detects >=2 findings ($p1_count)"
  PASS=$((PASS + 1))
else
  echo "FAIL: P1 fixture expected >=2 findings, got $p1_count" >&2
  FAIL=$((FAIL + 1))
fi

# --- Test 5: fixture with `!foo` triggers P2 detection (AC-4) ---------------
FIXTURE_P2=$(mktemp --suffix=.md)
TMPFILES+=("$FIXTURE_P2")
cat > "$FIXTURE_P2" << 'EOF'
# Fixture: P2 pattern

Use `!foo` history expansion.
Or `! cmd` negated.
EOF

out=$("$SCRIPT" --target "$FIXTURE_P2" 2>&1)
rc=$?
assert "P2 fixture exits 1 (detected)" "1" "$rc"
p2_count=$(grep -c '^\[bang-backtick\]\[P2\]' <<< "$out" || true)
if [ "$p2_count" -ge 2 ]; then
  echo "PASS: P2 fixture detects >=2 findings ($p2_count)"
  PASS=$((PASS + 1))
else
  echo "FAIL: P2 fixture expected >=2 findings, got $p2_count" >&2
  FAIL=$((FAIL + 1))
fi

# --- Test 6: innocent patterns remain clean ----------------------------------
FIXTURE_CLEAN=$(mktemp --suffix=.md)
TMPFILES+=("$FIXTURE_CLEAN")
cat > "$FIXTURE_CLEAN" << 'EOF'
# Fixture: innocent patterns (should NOT trigger)

Rustdoc inner: `//!` comment.
Markdown image: `![alt](url)`.
Regex literal: `!\[[^\]]*\]`.
Negation in code: `x != y`.
Trailing bang with content: `if ! cmd`.
EOF

out=$("$SCRIPT" --target "$FIXTURE_CLEAN" 2>&1)
rc=$?
assert "innocent fixture exits 0 (no false positives)" "0" "$rc"

# --- Summary -----------------------------------------------------------------
echo ""
echo "==> PASS: $PASS / FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
