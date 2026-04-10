#!/bin/bash
# Tests for pre-tool-bash-guard.sh (PreToolUse hook)
# Usage: bash plugins/rite/hooks/tests/pre-tool-bash-guard.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/../pre-tool-bash-guard.sh"
PASS=0
FAIL=0
STDERR_FILE=$(mktemp)

cleanup() {
  rm -f "$STDERR_FILE"
}
trap cleanup EXIT

# Prerequisite check: jq is required
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required but not installed" >&2
  exit 1
fi

pass() {
  PASS=$((PASS + 1))
  echo "  ✅ PASS: $1"
}

fail() {
  FAIL=$((FAIL + 1))
  echo "  ❌ FAIL: $1"
}

# Helper: run hook with given tool_name and command
# Captures stderr to $STDERR_FILE for log verification
run_guard() {
  local tool_name="$1"
  local cmd="$2"
  local rc=0
  local output
  output=$(jq -n --arg tn "$tool_name" --arg cmd "$cmd" \
    '{tool_name: $tn, tool_input: {command: $cmd}, cwd: "/tmp"}' \
    | bash "$HOOK" 2>"$STDERR_FILE") || rc=$?
  echo "$output"
  return $rc
}

# Helper: run hook with raw JSON input (for malformed input testing)
run_guard_raw() {
  local raw_input="$1"
  local rc=0
  local output
  output=$(echo "$raw_input" | bash "$HOOK" 2>"$STDERR_FILE") || rc=$?
  echo "$output"
  return $rc
}

echo "=== pre-tool-bash-guard.sh tests ==="
echo ""

# --------------------------------------------------------------------------
# TC-001: gh pr diff --stat → deny
# --------------------------------------------------------------------------
echo "TC-001: gh pr diff --stat → deny (with stderr log)"
rc=0
output=$(run_guard "Bash" "gh pr diff 123 --stat") || rc=$?
decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
reason=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)
stderr_log=$(cat "$STDERR_FILE")
if [ "$decision" = "deny" ] && [[ "$reason" == *"gh-pr-diff-stat"* ]]; then
  pass "gh pr diff --stat blocked with correct pattern name"
else
  fail "Expected deny with gh-pr-diff-stat, got decision=$decision reason=$reason"
fi
if [[ "$stderr_log" == *"bash-guard: BLOCKED"* ]] && [[ "$stderr_log" == *"gh-pr-diff-stat"* ]]; then
  pass "stderr contains block log with pattern name"
else
  fail "Expected stderr block log, got: $stderr_log"
fi
echo ""

# --------------------------------------------------------------------------
# TC-002: gh pr diff -- <path> → deny
# --------------------------------------------------------------------------
echo "TC-002: gh pr diff -- <path> → deny"
rc=0
output=$(run_guard "Bash" "gh pr diff 456 -- path/to/file.md") || rc=$?
decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
reason=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)
if [ "$decision" = "deny" ] && [[ "$reason" == *"gh-pr-diff-file-filter"* ]]; then
  pass "gh pr diff -- <path> blocked with correct pattern name"
else
  fail "Expected deny with gh-pr-diff-file-filter, got decision=$decision reason=$reason"
fi
echo ""

# --------------------------------------------------------------------------
# TC-003: != null in jq → deny
# --------------------------------------------------------------------------
echo "TC-003: != null in jq → deny"
rc=0
output=$(run_guard "Bash" "gh api repos/owner/repo/issues --jq '.[] | select(.field != null)'") || rc=$?
decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
reason=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)
if [ "$decision" = "deny" ] && [[ "$reason" == *"jq-not-equal-null"* ]]; then
  pass "!= null blocked with correct pattern name"
else
  fail "Expected deny with jq-not-equal-null, got decision=$decision reason=$reason"
fi
echo ""

# --------------------------------------------------------------------------
# TC-004: Safe gh pr diff → allow
# --------------------------------------------------------------------------
echo "TC-004: Safe gh pr diff → allow"
rc=0
output=$(run_guard "Bash" "gh pr diff 123") || rc=$?
if [ "$rc" = "0" ] && [ -z "$output" ]; then
  pass "gh pr diff (no flags) allowed"
else
  fail "Expected allow (exit 0, no output), got rc=$rc output=$output"
fi
echo ""

# --------------------------------------------------------------------------
# TC-005: Non-Bash tool → allow
# --------------------------------------------------------------------------
echo "TC-005: Non-Bash tool → allow"
rc=0
output=$(run_guard "Read" "anything") || rc=$?
if [ "$rc" = "0" ] && [ -z "$output" ]; then
  pass "Non-Bash tool allowed"
else
  fail "Expected allow, got rc=$rc output=$output"
fi
echo ""

# --------------------------------------------------------------------------
# TC-006: Safe jq with select(.field) → allow
# --------------------------------------------------------------------------
echo "TC-006: Safe jq select(.field) → allow"
rc=0
output=$(run_guard "Bash" "gh api repos/owner/repo/issues --jq '.[] | select(.field)'") || rc=$?
if [ "$rc" = "0" ] && [ -z "$output" ]; then
  pass "select(.field) allowed"
else
  fail "Expected allow, got rc=$rc output=$output"
fi
echo ""

# --------------------------------------------------------------------------
# TC-007: gh pr view --json files (safe alternative) → allow
# --------------------------------------------------------------------------
echo "TC-007: gh pr view --json files → allow"
rc=0
output=$(run_guard "Bash" "gh pr view 123 --json files --jq '.files[] | {path, additions, deletions}'") || rc=$?
if [ "$rc" = "0" ] && [ -z "$output" ]; then
  pass "gh pr view --json files allowed"
else
  fail "Expected allow, got rc=$rc output=$output"
fi
echo ""

# --------------------------------------------------------------------------
# TC-008: gh pr diff --name-only (safe) → allow
# --------------------------------------------------------------------------
echo "TC-008: gh pr diff --name-only → allow"
rc=0
output=$(run_guard "Bash" "gh pr diff 123 --name-only") || rc=$?
if [ "$rc" = "0" ] && [ -z "$output" ]; then
  pass "gh pr diff --name-only allowed"
else
  fail "Expected allow, got rc=$rc output=$output"
fi
echo ""

# --------------------------------------------------------------------------
# TC-009: gh pr diff piped to awk (safe) → allow
# --------------------------------------------------------------------------
echo "TC-009: gh pr diff | awk → allow"
rc=0
output=$(run_guard "Bash" "gh pr diff 123 | awk '/^diff --git/ { found=0 } /target/ { found=1 } found { print }'") || rc=$?
if [ "$rc" = "0" ] && [ -z "$output" ]; then
  pass "gh pr diff | awk allowed"
else
  fail "Expected allow, got rc=$rc output=$output"
fi
echo ""

# --------------------------------------------------------------------------
# TC-010: Empty command → allow
# --------------------------------------------------------------------------
echo "TC-010: Empty command → allow"
rc=0
output=$(run_guard "Bash" "") || rc=$?
if [ "$rc" = "0" ] && [ -z "$output" ]; then
  pass "Empty command allowed"
else
  fail "Expected allow, got rc=$rc output=$output"
fi
echo ""

# --------------------------------------------------------------------------
# TC-011: Deny JSON structure validation (Pattern 2: -- <path>)
# --------------------------------------------------------------------------
echo "TC-011: Deny JSON has all required fields (Pattern 2)"
rc=0
output=$(run_guard "Bash" "gh pr diff 99 -- src/file.ts") || rc=$?
HAS_EVENT=$(echo "$output" | jq -r '.hookSpecificOutput.hookEventName // empty' 2>/dev/null)
HAS_DECISION=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
HAS_REASON=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)
if [ "$HAS_EVENT" = "PreToolUse" ] && \
   [ "$HAS_DECISION" = "deny" ] && \
   [ -n "$HAS_REASON" ]; then
  pass "Deny JSON has all required fields (Pattern 2: gh-pr-diff-file-filter)"
else
  fail "Missing fields: event=$HAS_EVENT decision=$HAS_DECISION reason=$HAS_REASON"
fi
echo ""

# --------------------------------------------------------------------------
# TC-012: Heredoc content should not trigger false positive
# --------------------------------------------------------------------------
echo "TC-012: Pattern inside heredoc → allow (no false positive)"
rc=0
HEREDOC_CMD='git commit -m "$(cat <<'"'"'EOF'"'"'
gh pr diff --stat is not supported
EOF
)"'
output=$(run_guard "Bash" "$HEREDOC_CMD") || rc=$?
if [ "$rc" = "0" ] && [ -z "$output" ]; then
  pass "Pattern inside heredoc allowed (no false positive)"
else
  fail "Expected allow, got rc=$rc output=$output"
fi
echo ""

# --------------------------------------------------------------------------
# TC-013: Pattern inside heredoc with != null → allow
# --------------------------------------------------------------------------
echo "TC-013: != null inside heredoc → allow (no false positive)"
rc=0
HEREDOC_CMD2='git commit -m "$(cat <<'"'"'EOF'"'"'
select(.field != null) is prohibited
EOF
)"'
output=$(run_guard "Bash" "$HEREDOC_CMD2") || rc=$?
if [ "$rc" = "0" ] && [ -z "$output" ]; then
  pass "!= null inside heredoc allowed (no false positive)"
else
  fail "Expected allow, got rc=$rc output=$output"
fi
echo ""

# --------------------------------------------------------------------------
# TC-014: !=null (no space) in jq → deny
# --------------------------------------------------------------------------
echo "TC-014: !=null (no space) → deny"
rc=0
output=$(run_guard "Bash" "gh api repos/owner/repo/issues --jq '.[] | select(.field !=null)'") || rc=$?
decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
reason=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)
if [ "$decision" = "deny" ] && [[ "$reason" == *"jq-not-equal-null"* ]]; then
  pass "!=null (no space) blocked with correct pattern name"
else
  fail "Expected deny with jq-not-equal-null, got decision=$decision reason=$reason"
fi
echo ""

# --------------------------------------------------------------------------
# TC-015: gh pr diff --color (safe flag) → allow
# --------------------------------------------------------------------------
echo "TC-015: gh pr diff --color → allow"
rc=0
output=$(run_guard "Bash" "gh pr diff 123 --color") || rc=$?
if [ "$rc" = "0" ] && [ -z "$output" ]; then
  pass "gh pr diff --color allowed (not confused with --stat)"
else
  fail "Expected allow, got rc=$rc output=$output"
fi
echo ""

# --------------------------------------------------------------------------
# TC-016: Malformed JSON input → exit 0 (fail-open: jq fallback handles it)
# Note: Since commit 84160bd added `|| TOOL_NAME=""` fallback, malformed JSON
# results in TOOL_NAME="" → exit 0 (allow). This is correct fail-open behavior.
# --------------------------------------------------------------------------
echo "TC-016: Malformed JSON input → exit 0 (fail-open via jq fallback)"
rc=0
output=$(run_guard_raw "not valid json at all") || rc=$?
if [ "$rc" = "0" ]; then
  decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
  if [ -z "$decision" ]; then
    pass "Malformed JSON → exit 0, no deny output (fail-open via || TOOL_NAME=\"\" fallback)"
  else
    fail "Malformed JSON should not produce deny, got decision=$decision"
  fi
else
  fail "Expected exit 0 for malformed JSON (fail-open), got rc=$rc"
fi
echo ""

# --------------------------------------------------------------------------
# TC-017: JSON missing tool_input field → allow
# --------------------------------------------------------------------------
echo "TC-017: JSON missing tool_input → allow"
rc=0
output=$(run_guard_raw '{"tool_name": "Bash"}') || rc=$?
if [ "$rc" = "0" ] && [ -z "$output" ]; then
  pass "Missing tool_input allowed (empty command path)"
else
  fail "Expected allow, got rc=$rc output=$output"
fi
echo ""

# --------------------------------------------------------------------------
# TC-018: Deny stderr includes command summary (Pattern 3: != null)
# --------------------------------------------------------------------------
echo "TC-018: Deny stderr log includes command summary (Pattern 3)"
rc=0
output=$(run_guard "Bash" "gh api repos/o/r --jq '.[] | select(.x != null)'") || rc=$?
stderr_log=$(cat "$STDERR_FILE")
if [[ "$stderr_log" == *'cmd="'* ]] && [[ "$stderr_log" == *"jq-not-equal-null"* ]]; then
  pass "stderr log includes cmd= field and correct pattern name (Pattern 3)"
else
  fail "Expected cmd= and jq-not-equal-null in stderr log, got: $stderr_log"
fi
echo ""

# --------------------------------------------------------------------------
# TC-019: Pattern 2 with multiple spaces → deny
# --------------------------------------------------------------------------
echo "TC-019: gh  pr  diff  123  -- file (multi-space) → deny"
rc=0
output=$(run_guard "Bash" "gh  pr  diff  123  -- file.md") || rc=$?
decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
if [ "$decision" = "deny" ]; then
  pass "Multi-space Pattern 2 blocked"
else
  fail "Expected deny for multi-space Pattern 2, got decision=$decision"
fi
echo ""

# --------------------------------------------------------------------------
# TC-020: Overlapping patterns → first match wins (Pattern 1 priority)
# --------------------------------------------------------------------------
echo "TC-020: gh pr diff --stat -- file → deny with gh-pr-diff-stat (priority)"
rc=0
output=$(run_guard "Bash" "gh pr diff 123 --stat -- file.md") || rc=$?
decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
reason=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)
if [ "$decision" = "deny" ] && [[ "$reason" == *"gh-pr-diff-stat"* ]]; then
  pass "Overlapping patterns: Pattern 1 (--stat) takes priority"
else
  fail "Expected deny with gh-pr-diff-stat, got decision=$decision reason=$reason"
fi
echo ""

# --------------------------------------------------------------------------
# TC-021: Multiline command with blocked pattern → deny
# --------------------------------------------------------------------------
echo "TC-021: Multiline command with --stat → deny"
rc=0
MULTILINE_CMD=$(printf 'gh pr diff 123 \\\n  --stat')
output=$(run_guard "Bash" "$MULTILINE_CMD") || rc=$?
decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
# bash case glob * matches across newlines, so deny is the expected result
if [ "$decision" = "deny" ]; then
  pass "Multiline: glob * matches across newlines"
else
  fail "Expected deny for multiline command, got decision=$decision"
fi
echo ""

# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
