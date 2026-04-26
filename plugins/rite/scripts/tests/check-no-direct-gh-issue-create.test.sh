#!/bin/bash
# Tests for check-no-direct-gh-issue-create.sh (#669 AC-3)
# Usage: bash plugins/rite/scripts/tests/check-no-direct-gh-issue-create.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="$SCRIPT_DIR/../check-no-direct-gh-issue-create.sh"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
TEST_DIR="$(mktemp -d)"
PASS=0
FAIL=0

cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT

pass() { PASS=$((PASS + 1)); echo "  ✅ PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ❌ FAIL: $1"; }

echo "=== check-no-direct-gh-issue-create.sh tests (#669 AC-3) ==="
echo ""

# --------------------------------------------------------------------------
# TC-001: No arguments → exit 2 (usage error)
# --------------------------------------------------------------------------
echo "TC-001: No arguments → exit 2"
rc=0
output=$(bash "$TARGET" 2>&1) || rc=$?
if [ "$rc" -eq 2 ]; then
  pass "No arguments → exit 2 (usage error)"
else
  fail "Expected exit 2, got $rc"
fi

# --------------------------------------------------------------------------
# TC-002: Non-existent file → exit 2
# --------------------------------------------------------------------------
echo "TC-002: Non-existent file → exit 2"
rc=0
output=$(bash "$TARGET" "$TEST_DIR/does-not-exist.md" 2>&1) || rc=$?
if [ "$rc" -eq 2 ]; then
  pass "Non-existent file → exit 2"
else
  fail "Expected exit 2, got $rc"
fi

# --------------------------------------------------------------------------
# TC-003: Clean file (no direct calls) → exit 0
# --------------------------------------------------------------------------
echo "TC-003: Clean file → exit 0"
clean_file="$TEST_DIR/clean.md"
cat > "$clean_file" <<'EOF'
# Clean File

This file has no direct gh issue create invocations.

It uses create-issue-with-projects.sh exclusively.
EOF
rc=0
output=$(bash "$TARGET" "$clean_file" 2>&1) || rc=$?
if [ "$rc" -eq 0 ]; then
  pass "Clean file → exit 0"
else
  fail "Expected exit 0, got $rc, output='$output'"
fi

# --------------------------------------------------------------------------
# TC-004: Direct invocation in narrative bash → exit 1
# --------------------------------------------------------------------------
echo "TC-004: Direct invocation in narrative bash → exit 1"
violation_file="$TEST_DIR/violation.md"
cat > "$violation_file" <<'EOF'
# Violation Example

Run the following:

bash command directly: gh issue create --title "x" --body "y"
EOF
rc=0
output=$(bash "$TARGET" "$violation_file" 2>&1) || rc=$?
if [ "$rc" -eq 1 ] && echo "$output" | grep -q "VIOLATION"; then
  pass "Direct invocation detected → exit 1 + VIOLATION message"
else
  fail "Expected exit 1 + VIOLATION, got rc=$rc, output='$output'"
fi

# --------------------------------------------------------------------------
# TC-005: Inline backtick (`gh issue create`) → no false positive (exit 0)
# --------------------------------------------------------------------------
echo "TC-005: Inline backtick prose → exit 0"
backtick_file="$TEST_DIR/backtick.md"
cat > "$backtick_file" <<'EOF'
# Documentation

The orchestrator must NOT execute `gh issue create` directly.

It also forbids `gh issue create --title "x"` — use the helper script instead.
EOF
rc=0
output=$(bash "$TARGET" "$backtick_file" 2>&1) || rc=$?
if [ "$rc" -eq 0 ]; then
  pass "Inline backtick prose → exit 0 (no false positive)"
else
  fail "Expected exit 0, got rc=$rc, output='$output'"
fi

# --------------------------------------------------------------------------
# TC-006: Code fence (```bash ... ```) → no false positive (exit 0)
# --------------------------------------------------------------------------
echo "TC-006: Code fence content → exit 0"
fence_file="$TEST_DIR/fence.md"
cat > "$fence_file" <<'EOF'
# Reference

Negative reference example below (must not trigger guard):

```bash
# DO NOT do this:
gh issue create --title "x" --body "y"
```

The script enforces the rule.
EOF
rc=0
output=$(bash "$TARGET" "$fence_file" 2>&1) || rc=$?
if [ "$rc" -eq 0 ]; then
  pass "Code fence content → exit 0 (no false positive)"
else
  fail "Expected exit 0, got rc=$rc, output='$output'"
fi

# --------------------------------------------------------------------------
# TC-006a (#669 F-03): Tilde fence (~~~) → no false positive (exit 0)
# 検証: awk pattern が ` ``` ` と `~~~` の両方を code fence として認識し、
# tilde fence 内の literal 呼び出しを誤検出しないこと。
# --------------------------------------------------------------------------
echo "TC-006a: Tilde fence (~~~) content → exit 0 (#669 F-03)"
tilde_file="$TEST_DIR/tilde-fence.md"
cat > "$tilde_file" <<'EOF'
# Reference (tilde fence)

Negative reference example using tilde fence:

~~~bash
# DO NOT do this:
gh issue create --title "x" --body "y"
~~~

The script enforces the rule.
EOF
rc=0
output=$(bash "$TARGET" "$tilde_file" 2>&1) || rc=$?
if [ "$rc" -eq 0 ]; then
  pass "Tilde fence (~~~) content → exit 0 (no false positive)"
else
  fail "Expected exit 0, got rc=$rc, output='$output'"
fi

# --------------------------------------------------------------------------
# TC-007: Blockquote (> ...) → no false positive (exit 0)
# --------------------------------------------------------------------------
echo "TC-007: Blockquote content → exit 0"
quote_file="$TEST_DIR/quote.md"
cat > "$quote_file" <<'EOF'
# Quoted reference

> Note: do not invoke gh issue create directly. Use the helper.

This is the rule.
EOF
rc=0
output=$(bash "$TARGET" "$quote_file" 2>&1) || rc=$?
if [ "$rc" -eq 0 ]; then
  pass "Blockquote content → exit 0 (no false positive)"
else
  fail "Expected exit 0, got rc=$rc, output='$output'"
fi

# --------------------------------------------------------------------------
# TC-008: Markdown comment (<!-- ... -->) → no false positive (exit 0)
# --------------------------------------------------------------------------
echo "TC-008: Markdown comment → exit 0"
comment_file="$TEST_DIR/comment.md"
cat > "$comment_file" <<'EOF'
# Comment

<!-- TODO: replace this with helper. The old code used gh issue create -->

Body content.

<!--
Multi-line note:
gh issue create was used here
in the past.
-->

End.
EOF
rc=0
output=$(bash "$TARGET" "$comment_file" 2>&1) || rc=$?
if [ "$rc" -eq 0 ]; then
  pass "Markdown comment → exit 0 (no false positive)"
else
  fail "Expected exit 0, got rc=$rc, output='$output'"
fi

# --------------------------------------------------------------------------
# TC-009: Multiple files → exit 1 if any has violation
# --------------------------------------------------------------------------
echo "TC-009: Mixed files (1 clean + 1 violation) → exit 1"
rc=0
output=$(bash "$TARGET" "$clean_file" "$violation_file" 2>&1) || rc=$?
if [ "$rc" -eq 1 ] && echo "$output" | grep -q "Total files with violations: 1"; then
  pass "Mixed files → exit 1 + violation count"
else
  fail "Expected exit 1 with violation count, got rc=$rc, output='$output'"
fi

# --------------------------------------------------------------------------
# TC-010: AC-3 baseline — production target files must pass
# Validates that the actual in-scope files of #669 currently pass the guard.
# This is the regression check: if a future change introduces a direct call,
# this TC fails immediately.
# --------------------------------------------------------------------------
echo "TC-010: AC-3 baseline — start.md and parent-routing.md must pass"
rc=0
output=$(bash "$TARGET" \
  "$REPO_ROOT/plugins/rite/commands/issue/start.md" \
  "$REPO_ROOT/plugins/rite/commands/issue/parent-routing.md" 2>&1) || rc=$?
if [ "$rc" -eq 0 ]; then
  pass "AC-3 baseline: in-scope files have 0 direct gh issue create invocations"
else
  fail "AC-3 violated in production files: rc=$rc, output='$output'"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ $FAIL -gt 0 ]; then
  exit 1
fi
