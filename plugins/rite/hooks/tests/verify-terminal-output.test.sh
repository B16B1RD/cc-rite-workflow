#!/bin/bash
# Tests for verify-terminal-output.sh (Issue #561 regression guard)
# Usage: bash plugins/rite/hooks/tests/verify-terminal-output.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/../verify-terminal-output.sh"
TEST_DIR="$(mktemp -d)"
PASS=0
FAIL=0

cleanup() {
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

pass() {
  PASS=$((PASS + 1))
  echo "  ✅ PASS: $1"
}

fail() {
  FAIL=$((FAIL + 1))
  echo "  ❌ FAIL: $1"
}

# Helper: create a minimal valid plugin tree at a given root
# Layout: {root}/commands/issue/create-{register,decompose,interview}.md
#         {root}/skills/rite-workflow/SKILL.md
#         {root}/skills/rite-workflow/references/workflow-identity.md
setup_plugin_tree() {
  local repo_root="$1"
  local html_comment="${2:-true}"  # when "false", use bare sentinel form (for regression test)
  # When invoked with --repo-root, the script looks under {repo_root}/plugins/rite/
  local root="$repo_root/plugins/rite"

  mkdir -p "$root/commands/issue" "$root/skills/rite-workflow/references"

  if [ "$html_comment" = "true" ]; then
    local sentinel_create='<!-- [create:completed:{N}] -->'
    local sentinel_interview='<!-- [interview:completed] --> / <!-- [interview:skipped] -->'
  else
    local sentinel_create='[create:completed:{N}]'
    local sentinel_interview='[interview:completed] / [interview:skipped]'
  fi

  cat > "$root/commands/issue/create-register.md" <<EOF
# create-register
Test fixture. Sentinel form: $sentinel_create
EOF
  cat > "$root/commands/issue/create-decompose.md" <<EOF
# create-decompose
Test fixture. Sentinel form: $sentinel_create
EOF
  cat > "$root/commands/issue/create-interview.md" <<EOF
# create-interview
Test fixture. Sentinel form: $sentinel_interview
EOF
  cat > "$root/skills/rite-workflow/SKILL.md" <<'EOF'
# rite-workflow SKILL
workflow は途中で止まらない
meaningful_terminal_output
EOF
  cat > "$root/skills/rite-workflow/references/workflow-identity.md" <<'EOF'
# workflow-identity
no_mid_workflow_stop
meaningful_terminal_output
EOF
}

# Test 1: happy path — HTML-commented sentinel in all 3 files
echo "Test 1: Happy path (all HTML-commented)"
setup_plugin_tree "$TEST_DIR/test1"
if bash "$HOOK" --quiet --repo-root "$TEST_DIR/test1" >/dev/null 2>&1; then
  pass "exit 0 on valid HTML-commented sentinels"
else
  fail "expected exit 0, got $?"
fi

# Test 2: regression — bare sentinel form in all 3 files (should FAIL)
echo "Test 2: Regression — bare sentinel form"
setup_plugin_tree "$TEST_DIR/test2" "false"
if bash "$HOOK" --quiet --repo-root "$TEST_DIR/test2" >/dev/null 2>&1; then
  fail "expected exit 1 on bare sentinel form, got exit 0"
else
  rc=$?
  if [ "$rc" = "1" ]; then
    pass "exit 1 on bare sentinel form"
  else
    fail "expected exit 1, got $rc"
  fi
fi

# Test 3: AC-3 non-regression — missing [create:completed:] string entirely
echo "Test 3: AC-3 regression — sentinel string missing"
setup_plugin_tree "$TEST_DIR/test3"
# Overwrite create-register.md with no sentinel at all
cat > "$TEST_DIR/test3/plugins/rite/commands/issue/create-register.md" <<'EOF'
# create-register
No sentinel whatsoever. Pure prose.
EOF
if bash "$HOOK" --quiet --repo-root "$TEST_DIR/test3" >/dev/null 2>&1; then
  fail "expected exit 1 when sentinel string is missing, got exit 0"
else
  rc=$?
  if [ "$rc" = "1" ]; then
    pass "exit 1 on missing sentinel string (AC-3 regression detection)"
  else
    fail "expected exit 1, got $rc"
  fi
fi

# Test 4: --help exits 0 (UNIX convention, Issue #582 F-08)
echo "Test 4: --help returns exit 0"
if bash "$HOOK" --help >/dev/null 2>&1; then
  pass "--help exits 0 (UNIX convention)"
else
  fail "--help should exit 0, got $?"
fi

# Test 5: unknown argument exits 2 (usage error)
echo "Test 5: Unknown argument returns exit 2"
if bash "$HOOK" --nonexistent-flag >/dev/null 2>&1; then
  fail "expected exit 2 on unknown flag, got exit 0"
else
  rc=$?
  if [ "$rc" = "2" ]; then
    pass "exit 2 on unknown flag (usage error)"
  else
    fail "expected exit 2, got $rc"
  fi
fi

# Test 6: --repo-root with missing directory exits 2
echo "Test 6: --repo-root with non-existent directory"
if bash "$HOOK" --repo-root "/nonexistent/path/xyz123" >/dev/null 2>&1; then
  fail "expected exit 2 on missing --repo-root path, got exit 0"
else
  rc=$?
  if [ "$rc" = "2" ]; then
    pass "exit 2 on missing --repo-root directory"
  else
    fail "expected exit 2, got $rc"
  fi
fi

# Test 7: marketplace layout — plugin root without {repo}/plugins/rite/ prefix
echo "Test 7: Marketplace layout (no plugins/rite/ prefix, Issue #582 F-05)"
# Marketplace layout: hooks/ sits directly under plugin_root (not under plugins/rite/)
# Simulate by copying hook to a nested location and invoking without --repo-root
# (triggers SCRIPT_DIR/.. fallback → plugin root = test7 directory itself)
mkdir -p "$TEST_DIR/test7/hooks" "$TEST_DIR/test7/commands/issue" "$TEST_DIR/test7/skills/rite-workflow/references"
cp "$HOOK" "$TEST_DIR/test7/hooks/verify-terminal-output.sh"
chmod +x "$TEST_DIR/test7/hooks/verify-terminal-output.sh"
# Write fixtures at plugin root (no plugins/rite/ prefix)
cat > "$TEST_DIR/test7/commands/issue/create-register.md" <<'EOF'
# register
<!-- [create:completed:{N}] -->
EOF
cat > "$TEST_DIR/test7/commands/issue/create-decompose.md" <<'EOF'
# decompose
<!-- [create:completed:{N}] -->
EOF
cat > "$TEST_DIR/test7/commands/issue/create-interview.md" <<'EOF'
# interview
<!-- [interview:completed] --> <!-- [interview:skipped] -->
EOF
cat > "$TEST_DIR/test7/skills/rite-workflow/SKILL.md" <<'EOF'
workflow は途中で止まらない
meaningful_terminal_output
EOF
cat > "$TEST_DIR/test7/skills/rite-workflow/references/workflow-identity.md" <<'EOF'
no_mid_workflow_stop
meaningful_terminal_output
EOF
# Invoke from inside test7 (non-git directory, so git rev-parse fails, forcing SCRIPT_DIR/.. fallback)
# Run in sub-shell so our own git detection doesn't leak cwd
# IMPORTANT: `if ...; then ... else ...` form to bypass `set -e` abort when subshell exits non-zero
# (Test 1-6 と同じ形式に揃えることで、回帰発生時も fail カウントが正しく記録される)
if (cd "$TEST_DIR/test7" && bash "$TEST_DIR/test7/hooks/verify-terminal-output.sh" --quiet >/dev/null 2>&1); then
  pass "marketplace layout passes when fixtures present at plugin root"
else
  rc=$?
  fail "expected exit 0 on marketplace layout with valid fixtures, got $rc"
fi

# Summary
echo ""
echo "Results: PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
