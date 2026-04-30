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

# Helper: run hook with an explicit transcript_path (reviewer subagent tests)
# Issue #442: Pattern 4 only activates when transcript_path contains "/subagents/".
run_guard_with_transcript() {
  local tool_name="$1"
  local cmd="$2"
  local transcript="$3"
  local rc=0
  local output
  output=$(jq -n --arg tn "$tool_name" --arg cmd "$cmd" --arg tp "$transcript" \
    '{tool_name: $tn, tool_input: {command: $cmd}, cwd: "/tmp", transcript_path: $tp}' \
    | bash "$HOOK" 2>"$STDERR_FILE") || rc=$?
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
# Pattern 4: Reviewer subagent state-mutating git denylist (Issue #442)
#
# Scope: Only when transcript_path contains "/subagents/".
# Main session git operations must continue to work.
# --------------------------------------------------------------------------

SUBAGENT_TRANSCRIPT="/home/user/.claude/projects/proj/session-id/subagents/agent-abc123.jsonl"
MAIN_TRANSCRIPT="/home/user/.claude/projects/proj/session-id/main.jsonl"

# --------------------------------------------------------------------------
# TC-022: Reviewer subagent + git checkout <ref> -- <file> → deny
# --------------------------------------------------------------------------
echo "TC-022: reviewer subagent + 'git checkout develop -- file' → deny"
rc=0
output=$(run_guard_with_transcript "Bash" "git checkout develop -- plugins/rite/hooks/pre-tool-bash-guard.sh" "$SUBAGENT_TRANSCRIPT") || rc=$?
decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
reason=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)
stderr_log=$(cat "$STDERR_FILE")
if [ "$decision" = "deny" ] && [[ "$reason" == *"reviewer-state-mutating-git"* ]]; then
  pass "reviewer subagent 'git checkout -- file' blocked"
else
  fail "Expected deny with reviewer-state-mutating-git, got decision=$decision reason=$reason"
fi
if [[ "$stderr_log" == *"reviewer-state-mutating-git"* ]]; then
  pass "stderr log recorded reviewer-state-mutating-git pattern name"
else
  fail "Expected reviewer-state-mutating-git in stderr, got: $stderr_log"
fi
echo ""

# --------------------------------------------------------------------------
# TC-023: Main session + git checkout <branch> → allow (non-regression)
# Phase 5.1 implement flow MUST NOT be blocked.
# --------------------------------------------------------------------------
echo "TC-023: main session + 'git checkout develop' → allow (non-regression)"
rc=0
output=$(run_guard_with_transcript "Bash" "git checkout develop" "$MAIN_TRANSCRIPT") || rc=$?
if [ "$rc" = "0" ] && [ -z "$output" ]; then
  pass "main session git checkout allowed (not a subagent)"
else
  fail "Expected allow for main session git checkout, got rc=$rc output=$output"
fi
echo ""

# --------------------------------------------------------------------------
# TC-024: Reviewer subagent + git diff → allow (read-only)
# --------------------------------------------------------------------------
echo "TC-024: reviewer subagent + 'git diff' → allow (read-only)"
rc=0
output=$(run_guard_with_transcript "Bash" "git diff develop..HEAD -- plugins/rite/agents/_reviewer-base.md" "$SUBAGENT_TRANSCRIPT") || rc=$?
if [ "$rc" = "0" ] && [ -z "$output" ]; then
  pass "reviewer subagent git diff allowed"
else
  fail "Expected allow for reviewer git diff, got rc=$rc output=$output"
fi
echo ""

# --------------------------------------------------------------------------
# TC-025: Reviewer subagent + git show <ref>:<file> → allow (read-only)
# This is the documented alternative to 'git checkout <ref> -- <file>'.
# --------------------------------------------------------------------------
echo "TC-025: reviewer subagent + 'git show <ref>:<file>' → allow"
rc=0
output=$(run_guard_with_transcript "Bash" "git show develop:plugins/rite/agents/_reviewer-base.md" "$SUBAGENT_TRANSCRIPT") || rc=$?
if [ "$rc" = "0" ] && [ -z "$output" ]; then
  pass "reviewer subagent git show allowed (read-only alternative)"
else
  fail "Expected allow for reviewer git show, got rc=$rc output=$output"
fi
echo ""

# --------------------------------------------------------------------------
# TC-026: Reviewer subagent + git reset → deny
# --------------------------------------------------------------------------
echo "TC-026: reviewer subagent + 'git reset' → deny"
rc=0
output=$(run_guard_with_transcript "Bash" "git reset --hard HEAD" "$SUBAGENT_TRANSCRIPT") || rc=$?
decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
reason=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)
if [ "$decision" = "deny" ] && [[ "$reason" == *"reviewer-state-mutating-git"* ]]; then
  pass "reviewer subagent git reset blocked with correct pattern name"
else
  fail "Expected deny with reviewer-state-mutating-git for git reset, got decision=$decision reason=$reason"
fi
echo ""

# --------------------------------------------------------------------------
# TC-027: Reviewer subagent + git stash → deny
# --------------------------------------------------------------------------
echo "TC-027: reviewer subagent + 'git stash push' → deny"
rc=0
output=$(run_guard_with_transcript "Bash" "git stash push -m 'wip'" "$SUBAGENT_TRANSCRIPT") || rc=$?
decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
reason=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)
if [ "$decision" = "deny" ] && [[ "$reason" == *"reviewer-state-mutating-git"* ]]; then
  pass "reviewer subagent git stash push blocked with correct pattern name"
else
  fail "Expected deny with reviewer-state-mutating-git for git stash push, got decision=$decision reason=$reason"
fi
echo ""

# --------------------------------------------------------------------------
# TC-028: Main session + git reset → allow (non-regression)
# The /rite:pr:fix flow in the main session may use git reset legitimately.
# --------------------------------------------------------------------------
echo "TC-028: main session + 'git reset' → allow (non-regression)"
rc=0
output=$(run_guard_with_transcript "Bash" "git reset HEAD~1" "$MAIN_TRANSCRIPT") || rc=$?
if [ "$rc" = "0" ] && [ -z "$output" ]; then
  pass "main session git reset allowed"
else
  fail "Expected allow for main session git reset, got rc=$rc output=$output"
fi
echo ""

# --------------------------------------------------------------------------
# TC-029: Reviewer subagent + gh pr diff → allow (workflow operation)
# --------------------------------------------------------------------------
echo "TC-029: reviewer subagent + 'gh pr diff 123' → allow"
rc=0
output=$(run_guard_with_transcript "Bash" "gh pr diff 123" "$SUBAGENT_TRANSCRIPT") || rc=$?
if [ "$rc" = "0" ] && [ -z "$output" ]; then
  pass "reviewer subagent gh pr diff allowed"
else
  fail "Expected allow for reviewer gh pr diff, got rc=$rc output=$output"
fi
echo ""

# --------------------------------------------------------------------------
# TC-030: Reviewer subagent + bash test runner → allow (workflow operation)
# --------------------------------------------------------------------------
echo "TC-030: reviewer subagent + 'bash test.sh' → allow"
rc=0
output=$(run_guard_with_transcript "Bash" "bash plugins/rite/hooks/tests/pre-tool-bash-guard.test.sh" "$SUBAGENT_TRANSCRIPT") || rc=$?
if [ "$rc" = "0" ] && [ -z "$output" ]; then
  pass "reviewer subagent bash test allowed"
else
  fail "Expected allow for reviewer bash test, got rc=$rc output=$output"
fi
echo ""

# --------------------------------------------------------------------------
# TC-031: Reviewer subagent + git worktree add → allow (isolated inspection)
# --------------------------------------------------------------------------
echo "TC-031: reviewer subagent + 'git worktree add' → allow"
rc=0
output=$(run_guard_with_transcript "Bash" "git worktree add /tmp/rite-review-wt develop" "$SUBAGENT_TRANSCRIPT") || rc=$?
if [ "$rc" = "0" ] && [ -z "$output" ]; then
  pass "reviewer subagent git worktree add allowed"
else
  fail "Expected allow for reviewer git worktree add, got rc=$rc output=$output"
fi
echo ""

# --------------------------------------------------------------------------
# TC-032: Reviewer subagent + git worktree remove → deny
# --------------------------------------------------------------------------
echo "TC-032: reviewer subagent + 'git worktree remove' → deny"
rc=0
output=$(run_guard_with_transcript "Bash" "git worktree remove /tmp/rite-review-wt" "$SUBAGENT_TRANSCRIPT") || rc=$?
decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
reason=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)
if [ "$decision" = "deny" ] && [[ "$reason" == *"reviewer-state-mutating-git"* ]]; then
  pass "reviewer subagent git worktree remove blocked with correct pattern name"
else
  fail "Expected deny with reviewer-state-mutating-git for git worktree remove, got decision=$decision reason=$reason"
fi
echo ""

# --------------------------------------------------------------------------
# TC-033: Reviewer subagent + heredoc containing 'git checkout' → allow (false positive guard)
# --------------------------------------------------------------------------
echo "TC-033: reviewer subagent + heredoc text containing 'git checkout' → allow"
rc=0
HEREDOC_CMD3='cat <<'"'"'EOF'"'"'
git checkout develop -- file.md
EOF'
output=$(run_guard_with_transcript "Bash" "$HEREDOC_CMD3" "$SUBAGENT_TRANSCRIPT") || rc=$?
if [ "$rc" = "0" ] && [ -z "$output" ]; then
  pass "heredoc text 'git checkout' allowed (no false positive)"
else
  fail "Expected allow for heredoc text, got rc=$rc output=$output"
fi
echo ""

# --------------------------------------------------------------------------
# Pattern 4 Cycle 2 additions (Issue #442 cycle 2 fixes)
#
# Coverage expansion: every always-deny verb, bypass path, and read-only
# sub-command that stays allowed.
# --------------------------------------------------------------------------

# --- Helper: deny assertion with stderr/reason validation ---
assert_subagent_deny() {
  local label="$1"
  local cmd="$2"
  local rc=0
  local output
  output=$(run_guard_with_transcript "Bash" "$cmd" "$SUBAGENT_TRANSCRIPT") || rc=$?
  local decision
  decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
  local reason
  reason=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)
  if [ "$decision" = "deny" ] && [[ "$reason" == *"reviewer-state-mutating-git"* ]]; then
    pass "$label"
  else
    fail "$label — expected deny (reviewer-state-mutating-git), got decision=$decision reason=$reason"
  fi
}

# --- Helper: allow assertion (subagent) ---
assert_subagent_allow() {
  local label="$1"
  local cmd="$2"
  local rc=0
  local output
  output=$(run_guard_with_transcript "Bash" "$cmd" "$SUBAGENT_TRANSCRIPT") || rc=$?
  if [ "$rc" = "0" ] && [ -z "$output" ]; then
    pass "$label"
  else
    fail "$label — expected allow, got rc=$rc output=$output"
  fi
}

# --- Helper: allow assertion (main session) ---
assert_main_allow() {
  local label="$1"
  local cmd="$2"
  local rc=0
  local output
  output=$(run_guard_with_transcript "Bash" "$cmd" "$MAIN_TRANSCRIPT") || rc=$?
  if [ "$rc" = "0" ] && [ -z "$output" ]; then
    pass "$label"
  else
    fail "$label — expected allow, got rc=$rc output=$output"
  fi
}

# --------------------------------------------------------------------------
# TC-034〜042: Always-deny verbs coverage (denylist 主要カテゴリを網羅)
# --------------------------------------------------------------------------
echo "TC-034: subagent + git add → deny"
assert_subagent_deny "subagent git add . blocked" "git add ."

echo "TC-035: subagent + git commit → deny"
assert_subagent_deny "subagent git commit blocked" "git commit -am 'wip'"

echo "TC-036: subagent + git push → deny"
assert_subagent_deny "subagent git push blocked" "git push origin feat/foo"

echo "TC-037: subagent + git merge → deny"
assert_subagent_deny "subagent git merge blocked" "git merge develop"

echo "TC-038: subagent + git rebase → deny"
assert_subagent_deny "subagent git rebase blocked" "git rebase -i HEAD~3"

echo "TC-039: subagent + git cherry-pick → deny"
assert_subagent_deny "subagent git cherry-pick blocked" "git cherry-pick abc1234"

echo "TC-040: subagent + git revert → deny"
assert_subagent_deny "subagent git revert blocked" "git revert abc1234"

echo "TC-041: subagent + git restore → deny"
assert_subagent_deny "subagent git restore blocked" "git restore --source=HEAD file.md"

echo "TC-042: subagent + git update-ref → deny"
assert_subagent_deny "subagent git update-ref blocked" "git update-ref refs/heads/foo abc1234"

# --------------------------------------------------------------------------
# TC-043〜047: Shell meta-char boundary bypass prevention
# --------------------------------------------------------------------------
echo "TC-043: subagent + semicolon-chained 'true;git reset' → deny"
assert_subagent_deny "shell boundary ;git reset blocked" "true;git reset --hard HEAD"

echo "TC-044: subagent + AND-chained '&&git checkout' → deny"
assert_subagent_deny "shell boundary &&git checkout blocked" "cd /tmp&&git checkout develop -- file"

echo "TC-045: subagent + command-substitution '\$(git commit)' → deny"
assert_subagent_deny "shell boundary \$(git commit) blocked" "result=\$(git commit -am wip)"

echo "TC-046: subagent + subshell '(git reset)' → deny"
assert_subagent_deny "shell boundary (git reset) blocked" "(git reset --hard HEAD)"

echo "TC-047: subagent + backtick \`git push\` → deny"
assert_subagent_deny "shell boundary backtick git push blocked" "echo \`git push origin feat/foo\`"

# --------------------------------------------------------------------------
# TC-048〜053: Read-only sub-command false positive prevention
# (git tag -l / git stash list / git reflog / git worktree list / git branch --list)
# --------------------------------------------------------------------------
echo "TC-048: subagent + 'git tag -l v1.*' → allow (read-only list)"
assert_subagent_allow "subagent git tag -l allowed" "git tag -l 'v1.*'"

echo "TC-049: subagent + 'git tag --list' → allow"
assert_subagent_allow "subagent git tag --list allowed" "git tag --list"

echo "TC-050: subagent + 'git stash list' → allow (read-only)"
assert_subagent_allow "subagent git stash list allowed" "git stash list"

echo "TC-051: subagent + 'git stash show stash@{0}' → allow (read-only)"
assert_subagent_allow "subagent git stash show allowed" "git stash show stash@{0}"

echo "TC-052: subagent + 'git reflog' (bare) → allow (read-only display)"
assert_subagent_allow "subagent bare git reflog allowed" "git reflog"

echo "TC-053: subagent + 'git worktree list' → allow (read-only)"
assert_subagent_allow "subagent git worktree list allowed" "git worktree list"

# --------------------------------------------------------------------------
# TC-054〜057: git branch coverage (display allowed, mutations denied)
# --------------------------------------------------------------------------
echo "TC-054: subagent + bare 'git branch' → allow (list display)"
assert_subagent_allow "subagent bare git branch allowed" "git branch"

echo "TC-055: subagent + 'git branch --list' → allow"
assert_subagent_allow "subagent git branch --list allowed" "git branch --list"

echo "TC-056: subagent + 'git branch -a' → allow (display all)"
assert_subagent_allow "subagent git branch -a allowed" "git branch -a"

echo "TC-057a: subagent + 'git branch feature/foo' (bare new branch) → deny"
assert_subagent_deny "subagent bare new branch creation blocked" "git branch feature/foo"

echo "TC-057b: subagent + 'git branch --delete feature/foo' (long-form) → deny"
assert_subagent_deny "subagent git branch --delete blocked" "git branch --delete feature/foo"

echo "TC-057c: subagent + 'git branch --force feat' → deny"
assert_subagent_deny "subagent git branch --force blocked" "git branch --force feat"

# --------------------------------------------------------------------------
# TC-058: git fetch (bare) allowed, --prune denied
# --------------------------------------------------------------------------
echo "TC-058a: subagent + 'git fetch origin' (bare) → allow"
assert_subagent_allow "subagent bare git fetch allowed" "git fetch origin"

echo "TC-058b: subagent + 'git fetch --prune' → deny"
assert_subagent_deny "subagent git fetch --prune blocked" "git fetch --prune origin"

# --------------------------------------------------------------------------
# TC-059: Reviewer subagent + git reflog expire → deny
# --------------------------------------------------------------------------
echo "TC-059: subagent + 'git reflog expire --all' → deny"
assert_subagent_deny "subagent git reflog expire blocked" "git reflog expire --all --expire=now"

# --------------------------------------------------------------------------
# TC-060: Reviewer subagent + git tag -a (annotated tag creation) → deny
# --------------------------------------------------------------------------
echo "TC-060: subagent + 'git tag -a v1.0 -m msg' → deny"
assert_subagent_deny "subagent git tag -a blocked" "git tag -a v1.0 -m 'release'"

# --------------------------------------------------------------------------
# TC-061: False positive guard — quoted string containing 'git checkout'
# --------------------------------------------------------------------------
# The quote character `"` before `git` breaks the word boundary expected by
# the case-glob `*" git checkout "*`, so echoed strings containing the
# denylist verbs are correctly allowed. This TC locks in that behavior as a
# non-regression guarantee.
echo "TC-061: subagent + 'echo \"git checkout develop -- f\"' → allow (false positive guard)"
assert_subagent_allow "echoed 'git checkout' string allowed (quote boundary)" 'echo "git checkout develop -- f"'

# TC-061b: grep pattern argument containing 'git reset'
echo "TC-061b: subagent + 'grep \"git reset\" log.txt' → allow"
assert_subagent_allow "grep arg 'git reset' allowed (quote boundary)" 'grep "git reset" log.txt'

# --------------------------------------------------------------------------
# TC-062〜064: Main session non-regression for additional verbs
# --------------------------------------------------------------------------
echo "TC-062: main session + 'git add .' → allow"
assert_main_allow "main session git add allowed" "git add ."

echo "TC-063: main session + 'git commit -am msg' → allow"
assert_main_allow "main session git commit allowed" "git commit -am 'fix: msg'"

echo "TC-064: main session + 'git push origin' → allow"
assert_main_allow "main session git push allowed" "git push origin feat/foo"

# --------------------------------------------------------------------------
# Pattern 4 Cycle 3 additions (Issue #442 cycle 2 review fixes)
# --------------------------------------------------------------------------

# --------------------------------------------------------------------------
# TC-065〜066: Newline (`\n`) bypass closure — cycle 2 HIGH regression
# cycle 2 で確認された「CMD_NORMALIZED に \n/\r が未正規化」経路を lock
# --------------------------------------------------------------------------
echo "TC-065: subagent + newline-separated 'true\\ngit reset' → deny"
assert_subagent_deny "newline boundary \\ngit reset blocked" $'true\ngit reset --hard HEAD'

echo "TC-066: subagent + 3-line script with 'git commit' → deny"
assert_subagent_deny "multi-line script git commit blocked" $'echo a\ngit commit -am wip\necho b'

echo "TC-066b: subagent + carriage-return '\\rgit checkout' → deny"
assert_subagent_deny "CR boundary \\rgit checkout blocked" $'true\rgit checkout develop'

# --------------------------------------------------------------------------
# TC-067〜074: Always-deny coverage expansion (cycle 2 MEDIUM - 46% → ~90%)
# 未カバー verb を array-driven loop で網羅
# --------------------------------------------------------------------------
echo "TC-067: subagent + always-deny verb coverage loop"
for verb_cmd in \
  "git pull origin main" \
  "git rm README.md" \
  "git clean -fd" \
  "git gc --aggressive" \
  "git prune --dry-run" \
  "git symbolic-ref HEAD refs/heads/foo" \
  "git am < /tmp/patch" \
  "git apply --index /tmp/patch" \
  "git mv old.md new.md" \
  "git notes add -m msg HEAD" \
  "git config user.email a@b.c" \
  "git remote add upstream https://github.com/foo/bar" \
  "git bisect start" \
  "git filter-branch --tree-filter 'rm -f foo' HEAD" \
  "git filter-repo --path foo --invert-paths" \
  "git replace old new"; do
  assert_subagent_deny "subagent '$verb_cmd' blocked" "$verb_cmd"
done

# --------------------------------------------------------------------------
# TC-068〜075: git stash sub-action coverage (8 mutating sub-actions)
# --------------------------------------------------------------------------
echo "TC-068: subagent + git stash sub-action coverage"
for stash_cmd in \
  "git stash pop" \
  "git stash drop stash@{0}" \
  "git stash apply stash@{1}" \
  "git stash clear" \
  "git stash save 'wip'" \
  "git stash create" \
  "git stash store abc123" \
  "git stash branch foo stash@{0}"; do
  assert_subagent_deny "subagent '$stash_cmd' blocked" "$stash_cmd"
done

# --------------------------------------------------------------------------
# TC-076〜080: git fetch regression guard — cycle 2 HIGH
# branch / remote 名に -p/-f を substring として含む bare fetch が
# allow されることを lock (cycle 1 で導入した Pattern 4(F) regression を閉塞)
# --------------------------------------------------------------------------
echo "TC-076: subagent + 'git fetch origin hot-fix' → allow (branch name contains -f)"
assert_subagent_allow "bare fetch hot-fix branch allowed" "git fetch origin hot-fix"

echo "TC-077: subagent + 'git fetch origin feature-patch' → allow (branch contains -p)"
assert_subagent_allow "bare fetch feature-patch branch allowed" "git fetch origin feature-patch"

echo "TC-078: subagent + 'git fetch origin release-focus' → allow"
assert_subagent_allow "bare fetch release-focus branch allowed" "git fetch origin release-focus"

echo "TC-079: subagent + 'git fetch origin v1.0-rc-final' → allow"
assert_subagent_allow "bare fetch v1.0-rc-final branch allowed" "git fetch origin v1.0-rc-final"

echo "TC-080: subagent + 'git fetch upstream main-pipeline' → allow"
assert_subagent_allow "bare fetch main-pipeline branch allowed" "git fetch upstream main-pipeline"

# --------------------------------------------------------------------------
# TC-081〜082: git fetch short-flag still denied (regression guard for fix)
# --------------------------------------------------------------------------
echo "TC-081: subagent + 'git fetch -p origin' → deny (short -p flag)"
assert_subagent_deny "short -p flag blocked" "git fetch -p origin"

echo "TC-082: subagent + 'git fetch -f origin' → deny (short -f flag)"
assert_subagent_deny "short -f flag blocked" "git fetch -f origin"

echo "TC-082b: subagent + 'git fetch --force upstream' → deny (long --force flag)"
assert_subagent_deny "long --force flag blocked" "git fetch --force upstream"

# --------------------------------------------------------------------------
# TC-083〜084: Brace/pipe/space-less bypass non-regression
# --------------------------------------------------------------------------
echo "TC-083: subagent + 'echo x|git reset' → deny (pipe boundary)"
assert_subagent_deny "pipe |git reset blocked" "echo x|git reset --hard HEAD"

echo "TC-084: subagent + '{git reset --hard HEAD;}' → deny (brace boundary)"
assert_subagent_deny "brace group git reset blocked" "{git reset --hard HEAD;}"

# --------------------------------------------------------------------------
# TC-090〜098: Pattern 5 — gh issue create during create lifecycle (#475 Mode B)
# --------------------------------------------------------------------------
echo ""
echo "=== TC-090+: Pattern 5 gh issue create lifecycle blocking (#475) ==="

# Helper: run hook with explicit cwd + pre-populated .rite-flow-state
# Args: $1=cwd_dir, $2=command, $3..=extra jq-n args (unused now)
run_guard_with_cwd() {
  local cwd_dir="$1"
  local cmd="$2"
  local rc=0
  local output
  output=$(jq -n --arg tn "Bash" --arg cmd "$cmd" --arg cwd "$cwd_dir" \
    '{tool_name: $tn, tool_input: {command: $cmd}, cwd: $cwd}' \
    | bash "$HOOK" 2>"$STDERR_FILE") || rc=$?
  echo "$output"
  return $rc
}

# Helper: create a tmp cwd with a .rite-flow-state file having the given phase/active.
make_cwd_with_state() {
  local phase="$1"
  local active="$2"
  local dir
  dir=$(mktemp -d "/tmp/rite-test-475.XXXXXX")
  cat > "$dir/.rite-flow-state" <<STATE_EOF
{
  "schema_version": 1,
  "phase": "$phase",
  "active": $active,
  "issue_number": 0,
  "branch": "",
  "pr_number": 0,
  "next_action": "test",
  "updated_at": "$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")",
  "session_id": "test-session"
}
STATE_EOF
  echo "$dir"
}

# TC-090: gh issue create during phase=create_interview (active=true) → deny
echo "TC-090: gh issue create + create_interview active → deny"
tmpdir=$(make_cwd_with_state "create_interview" "true")
rc=0
output=$(run_guard_with_cwd "$tmpdir" "gh issue create --title 'x' --body 'y'") || rc=$?
decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
reason=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)
if [ "$decision" = "deny" ] && [[ "$reason" == *"create-lifecycle-direct-gh-issue"* ]]; then
  pass "TC-090 gh issue create blocked during create_interview"
else
  fail "TC-090 expected deny (create-lifecycle-direct-gh-issue), got decision=$decision reason=$reason"
fi
rm -rf "$tmpdir"

# TC-091: gh issue create during phase=create_post_interview (active=true) → deny
echo "TC-091: gh issue create + create_post_interview active → deny"
tmpdir=$(make_cwd_with_state "create_post_interview" "true")
rc=0
output=$(run_guard_with_cwd "$tmpdir" "gh issue create --title 'x'") || rc=$?
decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
if [ "$decision" = "deny" ]; then
  pass "TC-091 blocked during create_post_interview"
else
  fail "TC-091 expected deny, got decision=$decision"
fi
rm -rf "$tmpdir"

# TC-092: gh issue create during phase=create_delegation (active=true) → deny
echo "TC-092: gh issue create + create_delegation active → deny"
tmpdir=$(make_cwd_with_state "create_delegation" "true")
rc=0
output=$(run_guard_with_cwd "$tmpdir" "gh issue create --title 'x'") || rc=$?
decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
if [ "$decision" = "deny" ]; then
  pass "TC-092 blocked during create_delegation"
else
  fail "TC-092 expected deny, got decision=$decision"
fi
rm -rf "$tmpdir"

# TC-092b: gh issue create during phase=create_post_delegation (active=true) → deny
# (fills coverage gap identified in #501 test-reviewer MEDIUM)
echo "TC-092b: gh issue create + create_post_delegation active → deny"
tmpdir=$(make_cwd_with_state "create_post_delegation" "true")
rc=0
output=$(run_guard_with_cwd "$tmpdir" "gh issue create --title 'x'") || rc=$?
decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
if [ "$decision" = "deny" ]; then
  pass "TC-092b blocked during create_post_delegation"
else
  fail "TC-092b expected deny, got decision=$decision"
fi
rm -rf "$tmpdir"

# TC-093: gh issue create with phase=create_completed → allow (lifecycle finished)
echo "TC-093: gh issue create + create_completed → allow"
tmpdir=$(make_cwd_with_state "create_completed" "true")
rc=0
output=$(run_guard_with_cwd "$tmpdir" "gh issue create --title 'x'") || rc=$?
if [ "$rc" = "0" ] && [ -z "$output" ]; then
  pass "TC-093 allowed after create_completed"
else
  fail "TC-093 expected allow, got rc=$rc output=$output"
fi
rm -rf "$tmpdir"

# TC-094: gh issue create with active=false → allow
echo "TC-094: gh issue create + active=false → allow"
tmpdir=$(make_cwd_with_state "create_interview" "false")
rc=0
output=$(run_guard_with_cwd "$tmpdir" "gh issue create --title 'x'") || rc=$?
if [ "$rc" = "0" ] && [ -z "$output" ]; then
  pass "TC-094 allowed when active=false"
else
  fail "TC-094 expected allow, got rc=$rc output=$output"
fi
rm -rf "$tmpdir"

# TC-095: gh issue create with phase=phase2_branch (different workflow) → allow
echo "TC-095: gh issue create + phase2_branch → allow (different workflow)"
tmpdir=$(make_cwd_with_state "phase2_branch" "true")
rc=0
output=$(run_guard_with_cwd "$tmpdir" "gh issue create --title 'x'") || rc=$?
if [ "$rc" = "0" ] && [ -z "$output" ]; then
  pass "TC-095 allowed during non-create workflow"
else
  fail "TC-095 expected allow, got rc=$rc output=$output"
fi
rm -rf "$tmpdir"

# TC-096: gh issue create with no .rite-flow-state → allow
echo "TC-096: gh issue create + no .rite-flow-state → allow"
tmpdir=$(mktemp -d "/tmp/rite-test-475.XXXXXX")
rc=0
output=$(run_guard_with_cwd "$tmpdir" "gh issue create --title 'x'") || rc=$?
if [ "$rc" = "0" ] && [ -z "$output" ]; then
  pass "TC-096 allowed without state file"
else
  fail "TC-096 expected allow, got rc=$rc output=$output"
fi
rm -rf "$tmpdir"

# TC-097: gh issue list (not create) during create_interview → allow
echo "TC-097: gh issue list + create_interview → allow (not 'create')"
tmpdir=$(make_cwd_with_state "create_interview" "true")
rc=0
output=$(run_guard_with_cwd "$tmpdir" "gh issue list --state open") || rc=$?
if [ "$rc" = "0" ] && [ -z "$output" ]; then
  pass "TC-097 gh issue list allowed"
else
  fail "TC-097 expected allow, got rc=$rc output=$output"
fi
rm -rf "$tmpdir"

# TC-098: gh issue view (not create) during create_interview → allow
echo "TC-098: gh issue view + create_interview → allow (not 'create')"
tmpdir=$(make_cwd_with_state "create_interview" "true")
rc=0
output=$(run_guard_with_cwd "$tmpdir" "gh issue view 123 --json body") || rc=$?
if [ "$rc" = "0" ] && [ -z "$output" ]; then
  pass "TC-098 gh issue view allowed"
else
  fail "TC-098 expected allow, got rc=$rc output=$output"
fi
rm -rf "$tmpdir"

# --------------------------------------------------------------------------
# TC-099-108: Pattern 5 bypass vector regression tests (#501 security review)
# --------------------------------------------------------------------------
echo ""
echo "=== TC-099+: Pattern 5 bypass vector blocking (#501) ==="

# Helper: assert deny (for bypass tests during create_interview)
assert_p5_deny() {
  local label="$1"
  local cmd="$2"
  local tmpdir
  tmpdir=$(make_cwd_with_state "create_interview" "true")
  local rc=0
  local out
  out=$(run_guard_with_cwd "$tmpdir" "$cmd") || rc=$?
  local decision
  decision=$(echo "$out" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
  if [ "$decision" = "deny" ]; then
    pass "$label"
  else
    fail "$label (cmd='$cmd', got decision=$decision)"
  fi
  rm -rf "$tmpdir"
}

# Helper: assert allow (for false-positive regression).
# Checks that permissionDecision is not "deny" (rather than rc=0 && empty output), so future
# hook changes that emit informational stdout on allow paths don't false-fail this assertion.
assert_p5_allow() {
  local label="$1"
  local cmd="$2"
  local tmpdir
  tmpdir=$(make_cwd_with_state "create_interview" "true")
  local rc=0
  local out
  out=$(run_guard_with_cwd "$tmpdir" "$cmd") || rc=$?
  local decision
  decision=$(echo "$out" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
  if [ "$decision" != "deny" ]; then
    pass "$label"
  else
    fail "$label (cmd='$cmd', decision=$decision out=$out)"
  fi
  rm -rf "$tmpdir"
}

# TC-099: semicolon boundary → deny
assert_p5_deny "TC-099 'gh issue create;echo x' blocked (semicolon)" "gh issue create --title x;echo done"

# TC-100: pipe boundary → deny
assert_p5_deny "TC-100 'gh issue create | tee' blocked (pipe)" "gh issue create --title x|tee out"

# TC-101: ampersand boundary → deny
assert_p5_deny "TC-101 'gh issue create &' blocked (ampersand)" "gh issue create --title x &"

# TC-102: prefix shortcut 'gh issue c' → allow (ambiguous in gh CLI itself, not a real bypass)
# gh CLI resolves `c` as ambiguous (close/comment/create) and errors out.
# Since it never actually invokes `gh issue create`, Pattern 5 does not need to match it.
# Note: if gh CLI ever resolves `c` to a single subcommand, TC-102 must flip to deny.
assert_p5_allow "TC-102 'gh issue c' allowed (ambiguous in gh CLI, not a real bypass)" "gh issue c --title x"

# TC-102b: 2-char prefix 'gh issue cr' → deny
# Among `gh issue` subcommands, only `create` starts with `cr`, so gh CLI resolves
# `gh issue cr` unambiguously to `create`. This is a real bypass vector.
assert_p5_deny "TC-102b 'gh issue cr' blocked (2-char unambiguous prefix)" "gh issue cr --title x"

# TC-103: prefix shortcut 'gh issue cre' → deny
assert_p5_deny "TC-103 'gh issue cre' blocked (prefix shortcut)" "gh issue cre --title x"

# TC-104: brace group → deny (Pattern 4 normalization)
assert_p5_deny "TC-104 '{gh issue create;}' blocked (brace group)" "{gh issue create --title x;}"

# TC-105: subshell → deny
assert_p5_deny "TC-105 '(gh issue create)' blocked (subshell)" "(gh issue create --title x)"

# TC-106: env prefix → deny (not a bypass, just verify)
assert_p5_deny "TC-106 'FOO=bar gh issue create' blocked" "FOO=bar gh issue create --title x"

# TC-107: 'gh issue close' prefix 'c' ambiguity → MUST still deny because 'c' matches both
# NOTE: This is intentional — we err on the side of blocking. 'gh issue c' is ambiguous
# in gh CLI itself (returns "ambiguous" error), so users should not rely on it.
# For 'gh issue close' (full spelling), the pattern does NOT match and it's allowed:
assert_p5_allow "TC-107 'gh issue close' allowed (full spelling, not 'create' prefix)" "gh issue close 123"

# TC-108: 'gh issue comment' allowed (full spelling)
assert_p5_allow "TC-108 'gh issue comment' allowed" "gh issue comment 123 --body x"

# TC-109: heredoc-body bypass → deny (Pattern 5 uses $COMMAND directly, not $CMD_CHECK)
# `cat <<EOF ... gh issue create ... EOF | sh` hides the command in a heredoc body.
# Pattern 1-4 strip the heredoc via CMD_CHECK="${COMMAND%%<<*}" but Pattern 5 bypasses that
# by operating on $COMMAND directly (#501 security review HIGH).
assert_p5_deny "TC-109 heredoc body bypass blocked" "cat <<EOF | sh
gh issue create --title x
EOF"

# TC-110: eval with double-quoted body → deny (quote normalization)
assert_p5_deny "TC-110 eval \"gh issue create\" blocked (quote normalization)" 'eval "gh issue create --title x"'

# TC-111: eval with single-quoted body → deny
assert_p5_deny "TC-111 eval 'gh issue create' blocked (quote normalization)" "eval 'gh issue create --title x'"

# TC-112: backslash line continuation → deny
# `gh \<newline>  issue \<newline>  create` normalized via \n→space and \→space
# Using $'...' ANSI-C quoting to preserve literal backslash-newline in the test input.
assert_p5_deny "TC-112 backslash line continuation blocked" $'gh \\\n  issue \\\n  create --title x'

# --------------------------------------------------------------------------
# TC-PER-SESSION-1+: Pattern 5 with schema_version=2 per-session state (Issue #681)
# --------------------------------------------------------------------------
echo ""
echo "=== TC-PER-SESSION-1+: Pattern 5 with per-session state file (Issue #681) ==="

# Helper: create a tmp cwd with rite-config.yml (schema 2), .rite-session-id,
# and a per-session flow-state file under .rite/sessions/<sid>.flow-state.
# This exercises the _resolve-flow-state-path.sh integration: when the resolver
# returns the per-session path, Pattern 5 must still read phase/active from it
# and apply the same Mode B AND-logic.
make_cwd_with_per_session_state() {
  local phase="$1"
  local active="$2"
  local sid="${3:-00000000-0000-4000-8000-000000000001}"
  local dir
  dir=$(mktemp -d "/tmp/rite-test-681.XXXXXX")
  cat > "$dir/rite-config.yml" <<'CFG_EOF'
flow_state:
  schema_version: 2
CFG_EOF
  printf '%s' "$sid" > "$dir/.rite-session-id"
  mkdir -p "$dir/.rite/sessions"
  cat > "$dir/.rite/sessions/${sid}.flow-state" <<STATE_EOF
{
  "schema_version": 2,
  "phase": "$phase",
  "active": $active,
  "issue_number": 0,
  "branch": "",
  "pr_number": 0,
  "next_action": "test",
  "updated_at": "$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")",
  "session_id": "$sid"
}
STATE_EOF
  echo "$dir"
}

# TC-PER-SESSION-1: gh issue create + per-session create_interview active → deny
echo "TC-PER-SESSION-1: gh issue create + per-session create_interview active → deny"
tmpdir=$(make_cwd_with_per_session_state "create_interview" "true")
rc=0
output=$(run_guard_with_cwd "$tmpdir" "gh issue create --title 'x' --body 'y'") || rc=$?
decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
reason=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)
if [ "$decision" = "deny" ] && [[ "$reason" == *"create-lifecycle-direct-gh-issue"* ]]; then
  pass "TC-PER-SESSION-1 gh issue create blocked via per-session state (schema 2)"
else
  fail "TC-PER-SESSION-1 expected deny, got decision=$decision reason=$reason"
fi
rm -rf "$tmpdir"

# TC-PER-SESSION-2: gh issue create + per-session create_completed → allow
# (verifies the per-session resolver path still respects the create_completed allow branch)
echo "TC-PER-SESSION-2: gh issue create + per-session create_completed → allow"
tmpdir=$(make_cwd_with_per_session_state "create_completed" "true")
rc=0
output=$(run_guard_with_cwd "$tmpdir" "gh issue create --title 'x'") || rc=$?
decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
if [ -z "$decision" ] || [ "$decision" != "deny" ]; then
  pass "TC-PER-SESSION-2 allowed when phase=create_completed in per-session state"
else
  fail "TC-PER-SESSION-2 expected allow, got decision=$decision"
fi
rm -rf "$tmpdir"

# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
