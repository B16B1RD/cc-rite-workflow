#!/bin/bash
# Tests for orphan-reference-check.sh
# Usage: bash plugins/rite/hooks/tests/orphan-reference-check.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="$SCRIPT_DIR/../scripts/orphan-reference-check.sh"
TEST_DIR="$(mktemp -d)"
PASS=0
FAIL=0

cleanup() { rm -rf "$TEST_DIR"; }
trap 'rc=$?; cleanup; exit $rc' EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
trap 'cleanup; exit 129' HUP

pass() { PASS=$((PASS + 1)); echo "  ✅ PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ❌ FAIL: $1"; }

echo "=== orphan-reference-check.sh tests ==="
echo ""

# Setup: minimal repo-like structure under TEST_DIR
mkdir -p "$TEST_DIR/plugins/rite/skills/issue/references"
mkdir -p "$TEST_DIR/plugins/rite/skills/rite-workflow"
mkdir -p "$TEST_DIR/plugins/rite/hooks/tests"
mkdir -p "$TEST_DIR/docs/designs"
# Mark as git repo to make rev-parse work; tests use --repo-root explicitly anyway.
(cd "$TEST_DIR" && git init -q 2>/dev/null || true)

# --------------------------------------------------------------------------
# TC-001: No arguments → exit 2 (usage error)
# --------------------------------------------------------------------------
echo "TC-001: No arguments → exit 2"
rc=0
output=$(bash "$TARGET" 2>&1) || rc=$?
if [ "$rc" -eq 2 ]; then
  pass "No arguments → exit 2"
else
  fail "expected rc=2, got rc=$rc, output: $output"
fi

# --------------------------------------------------------------------------
# TC-002: file not found → exit 2
# --------------------------------------------------------------------------
echo "TC-002: nonexistent file → exit 2"
rc=0
output=$(bash "$TARGET" "$TEST_DIR/nonexistent.md" 2>&1) || rc=$?
if [ "$rc" -eq 2 ] && grep -q "file not found" <<< "$output"; then
  pass "nonexistent file → exit 2"
else
  fail "expected rc=2 + 'file not found', got rc=$rc, output: $output"
fi

# --------------------------------------------------------------------------
# TC-003: orphan file (no inbound, no test pin) → exit 1
# --------------------------------------------------------------------------
echo "TC-003: orphan file → exit 1"
echo "# Orphan" > "$TEST_DIR/plugins/rite/skills/issue/references/orphan-doc.md"
rc=0
output=$(bash "$TARGET" --repo-root "$TEST_DIR" "$TEST_DIR/plugins/rite/skills/issue/references/orphan-doc.md" 2>&1) || rc=$?
if [ "$rc" -eq 1 ] && grep -q "ORPHAN: plugins/rite/skills/issue/references/orphan-doc.md" <<< "$output"; then
  pass "orphan file detected → exit 1"
else
  fail "expected rc=1 + ORPHAN line, got rc=$rc, output: $output"
fi

# --------------------------------------------------------------------------
# TC-004: file with inbound reference → exit 0
# --------------------------------------------------------------------------
echo "TC-004: file with inbound reference → exit 0"
echo "# Referenced" > "$TEST_DIR/plugins/rite/skills/issue/references/active-doc.md"
echo "See [active-doc.md](references/active-doc.md) for details." > "$TEST_DIR/plugins/rite/skills/rite-workflow/SKILL.md"
rc=0
output=$(bash "$TARGET" --repo-root "$TEST_DIR" "$TEST_DIR/plugins/rite/skills/issue/references/active-doc.md" 2>&1) || rc=$?
if [ "$rc" -eq 0 ]; then
  pass "active file → exit 0"
else
  fail "expected rc=0, got rc=$rc, output: $output"
fi

# --------------------------------------------------------------------------
# TC-005: file with test pin (no inbound but assert_grep in tests/) → exit 0
# --------------------------------------------------------------------------
echo "TC-005: file with test pin → exit 0"
echo "# Pinned by test" > "$TEST_DIR/plugins/rite/skills/issue/references/test-pinned-doc.md"
cat > "$TEST_DIR/plugins/rite/hooks/tests/some.test.sh" <<EOF
#!/bin/bash
assert_grep "test-pinned-doc.md exists" "\$TARGET" "test-pinned-doc.md"
EOF
rc=0
output=$(bash "$TARGET" --repo-root "$TEST_DIR" "$TEST_DIR/plugins/rite/skills/issue/references/test-pinned-doc.md" 2>&1) || rc=$?
if [ "$rc" -eq 0 ]; then
  pass "test-pinned file → exit 0"
else
  fail "expected rc=0 (test pin protects), got rc=$rc, output: $output"
fi

# --------------------------------------------------------------------------
# TC-006: self-reference does not count (file mentions itself) → exit 1
# --------------------------------------------------------------------------
echo "TC-006: self-reference only → exit 1"
cat > "$TEST_DIR/plugins/rite/skills/issue/references/self-only-doc.md" <<EOF
# Self-referencing doc

This file is at \`plugins/rite/skills/issue/references/self-only-doc.md\`.
See self-only-doc.md for the spec (this is a self-reference and must not count).
EOF
rc=0
output=$(bash "$TARGET" --repo-root "$TEST_DIR" "$TEST_DIR/plugins/rite/skills/issue/references/self-only-doc.md" 2>&1) || rc=$?
if [ "$rc" -eq 1 ] && grep -q "ORPHAN: plugins/rite/skills/issue/references/self-only-doc.md" <<< "$output"; then
  pass "self-reference excluded, orphan detected → exit 1"
else
  fail "expected rc=1 + ORPHAN (self-ref should not count), got rc=$rc, output: $output"
fi

# --------------------------------------------------------------------------
# TC-007: --all expansion with multiple files
# --------------------------------------------------------------------------
echo "TC-007: --all mode expands to multiple files"
# At this point we have:
#   - orphan-doc.md (TC-003): orphan
#   - active-doc.md (TC-004): has inbound (referenced by SKILL.md)
#   - test-pinned-doc.md (TC-005): has test pin
#   - self-only-doc.md (TC-006): orphan (self-ref excluded)
#   - SKILL.md (TC-004 setup): orphan (no inbound, no test pin) — correctly detected
# Expected: --all should detect 3 orphans (orphan-doc.md + self-only-doc.md + SKILL.md)
rc=0
output=$(bash "$TARGET" --all --repo-root "$TEST_DIR" 2>&1) || rc=$?
orphan_lines=$(echo "$output" | grep -c "^ORPHAN:" || true)
case "$orphan_lines" in ''|*[!0-9]*) orphan_lines=0 ;; esac
if [ "$rc" -eq 1 ] && [ "$orphan_lines" -eq 3 ]; then
  pass "--all detected 3 orphans → exit 1"
else
  fail "expected rc=1 + 3 ORPHAN lines, got rc=$rc + $orphan_lines orphan lines, output: $output"
fi

# --------------------------------------------------------------------------
# TC-008: static asset skip (.gitkeep)
# --------------------------------------------------------------------------
echo "TC-008: .gitkeep is skipped"
touch "$TEST_DIR/plugins/rite/skills/issue/references/.gitkeep"
rc=0
output=$(bash "$TARGET" --repo-root "$TEST_DIR" "$TEST_DIR/plugins/rite/skills/issue/references/.gitkeep" 2>&1) || rc=$?
if [ "$rc" -eq 0 ]; then
  pass ".gitkeep skipped → exit 0"
else
  fail "expected rc=0 (.gitkeep skipped), got rc=$rc, output: $output"
fi

# --------------------------------------------------------------------------
# TC-009: --all with --repo-root using non-existent dir → exit 2
# --------------------------------------------------------------------------
echo "TC-009: --all with non-existent repo-root → exit 2"
rc=0
output=$(bash "$TARGET" --all --repo-root "$TEST_DIR/nonexistent" 2>&1) || rc=$?
if [ "$rc" -eq 2 ] && grep -q "repo-root not a directory" <<< "$output"; then
  pass "non-existent repo-root → exit 2"
else
  fail "expected rc=2 + 'repo-root not a directory', got rc=$rc, output: $output"
fi

# --------------------------------------------------------------------------
# TC-010: --all from a worktree-like REPO_ROOT (path contains /.rite/) → scan succeeds
# Regression guard for the bug where a session worktree path
# (.rite/worktrees/issue-N) made every file's absolute path match the
# `*/.rite/*` exclusion, emptying the --all expansion and forcing exit 2.
# --------------------------------------------------------------------------
echo "TC-010: --all from worktree-like REPO_ROOT (.rite/ in path) → scan succeeds"
WT_ROOT="$TEST_DIR/.rite/worktrees/issue-999"
mkdir -p "$WT_ROOT/plugins/rite/skills/issue/references"
mkdir -p "$WT_ROOT/plugins/rite/hooks/tests"
echo "# Orphan in worktree" > "$WT_ROOT/plugins/rite/skills/issue/references/wt-orphan-doc.md"
rc=0
output=$(bash "$TARGET" --all --repo-root "$WT_ROOT" 2>&1) || rc=$?
# Must NOT be the empty-expansion usage error (exit 2). The orphan should be
# detected (exit 1), proving the find walked the worktree subtree.
if [ "$rc" -eq 1 ] && grep -q "ORPHAN: plugins/rite/skills/issue/references/wt-orphan-doc.md" <<< "$output"; then
  pass "worktree-like REPO_ROOT scanned, orphan detected → exit 1"
elif [ "$rc" -eq 2 ] && grep -q "expansion empty" <<< "$output"; then
  fail "regression: --all expansion empty under worktree-like REPO_ROOT (the bug), output: $output"
else
  fail "expected rc=1 + wt-orphan-doc ORPHAN, got rc=$rc, output: $output"
fi

# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------
echo ""
echo "=== Test Summary ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
echo "TOTAL: $((PASS + FAIL))"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
