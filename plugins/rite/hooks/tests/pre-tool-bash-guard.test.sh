#!/bin/bash
# Tests for pre-tool-bash-guard.sh (PreToolUse hook)
# Usage: bash plugins/rite/hooks/tests/pre-tool-bash-guard.test.sh
set -euo pipefail

# _timeout <seconds> <command...> — portable timeout(1) for this test (Issue #2008).
# GNU `timeout` is absent on macOS (BSD / no coreutils); fall back to a perl
# fork/waitpid shim reproducing timeout(1)'s exit-code contract: 124 on timeout,
# 128+N on signal death, the child's status otherwise (a naive
# `perl -e 'alarm; exec'` would exit 142 and defeat hang-detection assertions).
# This file does not source _test-helpers.sh, so the shim is inlined here — keep
# it byte-identical with _test-helpers.sh (timeout-shim.test.sh asserts no drift).
_timeout() {
  local _d="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$_d" "$@"
  else
    perl -e '
      my $d = shift;
      # alarm truncates to an integer, so a fractional deadline silently becomes
      # alarm 0 — no timeout at all, and waitpid blocks until the CI job limit.
      # Reject rather than degrade, and exit 125 rather than die: die exits 255,
      # which every caller reads as "not 124, so no hang" — the same silent pass
      # the rejection exists to prevent. GNU timeout accepts fractions, so this
      # shim only claims the contract for integer seconds.
      if ($d !~ /^[0-9]+$/) {
        print STDERR "_timeout: fractional seconds are not supported by the perl fallback: $d\n";
        exit 125;
      }
      my $pid = fork;
      exit 127 unless defined $pid;
      # setpgrp puts the child in its own process group so the alarm handler can
      # signal the whole tree with a negative pid. GNU timeout does the same; without
      # it the deadline only reaches the direct child, and a grandchild holding the
      # captured stdout keeps the caller blocked long past the timeout (measured 30s
      # against a 1s deadline). The runners capture output with $( ), so that stall
      # would consume the CI job limit instead of failing at 124.
      if ($pid == 0) { setpgrp(0, 0); exec { $ARGV[0] } @ARGV; exit 127; }
      $SIG{ALRM} = sub { kill "TERM", -$pid; waitpid($pid, 0); exit 124; };
      alarm $d; waitpid $pid, 0;
      my $st = $?; exit($st & 127 ? 128 + ($st & 127) : $st >> 8);
    ' "$_d" "$@"
  fi
}

# Fail closed when no backend exists. Every `_timeout` caller reads a non-124 rc
# as "no hang", so a missing backend would silently turn each hang assertion into
# a pass. Abort at source time rather than degrade.
if ! command -v timeout >/dev/null 2>&1 && ! command -v perl >/dev/null 2>&1; then
  echo "ERROR: neither timeout(1) nor perl(1) is available — _timeout cannot detect" >&2
  echo "  hangs, and every hang assertion in this suite would silently pass." >&2
  echo "  Install GNU coreutils (timeout) or perl before running the test suite." >&2
  exit 1
fi

# Tier 3 (env var) subagent detection を導入したため、host 環境に
# CLAUDE_SUBAGENT_TYPE / CLAUDE_AGENT_TYPE が export されていると既存の
# main-session allow テストが Tier 3 経路で誤って deny 判定され flake する。
# 全テストで一律遮断する。
unset CLAUDE_SUBAGENT_TYPE CLAUDE_AGENT_TYPE

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
# Pattern 4 only activates when transcript_path contains "/subagents/".
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
# Pattern 4: Reviewer subagent .git-write gate
#
# Scope: Only when transcript_path contains "/subagents/" (Tier 1) or the
# Tier 2/3 signals fire. Main session operations must continue to work.
#
# Issue #1879: the working-tree verb denylist (git checkout / reset / commit /
# branch / stash / fetch flags / worktree sub-actions / ...) was REMOVED from
# this hook. Those mutations are Layer 1 (reviewer prompt) + Layer 3
# (post-review-state-verify.sh) territory now. The machine gate keeps only:
#   (L) the oversized-command length guard (timeout-bypass prevention)
#   (Z) the shell-wrapper block (opaque quoting can hide a .git write)
#   (H) the .git-write detection (redirect / file-mutating verb)
# --------------------------------------------------------------------------

SUBAGENT_TRANSCRIPT="/home/user/.claude/projects/proj/session-id/subagents/agent-abc123.jsonl"
MAIN_TRANSCRIPT="/home/user/.claude/projects/proj/session-id/main.jsonl"

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
# TC-201: verb-denylist removal — mutating git verbs are NOT machine-gated
# (Issue #1879 AC-1/AC-4). These commands were denied by the removed sub-blocks
# (A)-(G); after the removal they must pass the hook untouched. The READ-ONLY
# guarantee for them is the reviewer prompt (Layer 1) + post-review-state-verify
# (Layer 3), NOT this hook — this loop pins the hook's non-involvement so a
# future edit cannot silently re-grow the verb denylist.
# --------------------------------------------------------------------------
echo "TC-201: subagent mutating git verbs → allow (Layer 1/3 territory, not machine-gated)"
for verb_cmd in \
  "git checkout develop" \
  "git checkout develop -- file.md" \
  "git checkout -b pr-123-test" \
  "git reset --hard HEAD" \
  "git add ." \
  "git commit -am 'wip'" \
  "git push origin feat/foo" \
  "git stash push" \
  "git branch new-branch-name" \
  "git branch -D old-branch" \
  "git worktree add -b nb /tmp/d HEAD" \
  "git worktree remove /tmp/d" \
  "git fetch --prune origin" \
  "git tag -a v1.0 -m 'release'" \
  "git reflog expire --all --expire=now" \
  ; do
  assert_subagent_allow "subagent '$verb_cmd' allowed (verb denylist removed)" "$verb_cmd"
done
# NOTE: git update-ref / symbolic-ref / config-write / mutating-remote are NOT in
# this allow set — they write .git directly and are denied by sub-block (N),
# pinned in TC-127 below. They were never working-tree verbs (Issue #1879 removed
# working-tree verbs; .git-write is the retained gate).
echo ""

# --------------------------------------------------------------------------
# TC-202: read-only git / workflow commands → allow (non-regression)
# --------------------------------------------------------------------------
echo "TC-202: subagent read-only git / workflow commands → allow"
for ro_cmd in \
  "git diff develop..HEAD -- plugins/rite/agents/_reviewer-base.md" \
  "git show develop:plugins/rite/agents/_reviewer-base.md" \
  "git status" \
  "git log --oneline -20" \
  "git worktree add --detach /tmp/rite-review-mutation-abc HEAD" \
  "gh pr diff 123" \
  "bash plugins/rite/hooks/tests/flow-state.test.sh" \
  ; do
  assert_subagent_allow "subagent '$ro_cmd' allowed" "$ro_cmd"
done
echo ""

# --------------------------------------------------------------------------
# TC-203: past false-positive commands → allow (Issue #1879 AC-4)
# Commands that historically required bypass/false-positive patches against the
# removed verb denylist (quote-boundary echoes, grep pattern args, branch names
# embedding flag substrings, worktree-add arg-loop noglob #1866). With the verb
# machinery gone these must all pass with zero mis-detection.
# --------------------------------------------------------------------------
echo "TC-203: past false-positive command set → allow (no mis-detection)"
for fp_cmd in \
  'echo "git checkout develop -- f"' \
  'grep "git reset" log.txt' \
  "git fetch origin hot-fix" \
  "git fetch origin release-patch v1.0-rc-final" \
  "git worktree add /tmp/wt develop" \
  "git branch --list" \
  "git branch --show-current" \
  "git tag -l" \
  "git stash list" \
  "git reflog" \
  ; do
  assert_subagent_allow "subagent '$fp_cmd' allowed (no false positive)" "$fp_cmd"
done
# worktree-add arg with a bare glob from a CWD holding a `-b` file (Issue #1866
# scenario): the arg-parsing loop is gone, so no CWD pathname expansion can
# mis-latch a flag — pin from the crafted CWD to keep the regression meaningful.
tc203_noglob_dir=$(mktemp -d)
: > "$tc203_noglob_dir/-b"
_tc203_prev=$(pwd)
if cd "$tc203_noglob_dir"; then
  assert_subagent_allow "worktree add with bare glob + CWD '-b' file allowed (arg loop removed)" "git worktree add /tmp/wt develop *"
  cd "$_tc203_prev" || true
else
  fail "TC-203 noglob setup: cd into temp dir failed"
fi
rm -rf "$tc203_noglob_dir"
echo ""

# --------------------------------------------------------------------------
# TC-204: main session non-regression (all patterns 4 checks are subagent-scoped)
# --------------------------------------------------------------------------
echo "TC-204: main session git / wrapper commands → allow"
for main_cmd in \
  "git checkout develop" \
  "git reset --hard HEAD" \
  "git add ." \
  "git commit -am 'fix: msg'" \
  "git push origin feat/foo" \
  'bash -c "echo readonly-probe"' \
  ; do
  assert_main_allow "main session '$main_cmd' allowed" "$main_cmd"
done
echo ""

# --------------------------------------------------------------------------
# TC-057ad〜af: shell-wrapper (Z) — deny with read-only probe guidance
# wrapper は中身が read-only でも一律 deny (緩和しない)。deny message には
# 代替ガイダンス (subshell / 直接実行 / bash <script>) が入る。pattern 名は
# verb 列挙撤去に伴い reviewer-shell-wrapper へ改名 (Issue #1879)。
# --------------------------------------------------------------------------

# Helper: subagent deny かつ reason に wrapper guidance が含まれることを確認
assert_subagent_deny_wrapper_guidance() {
  local label="$1"
  local cmd="$2"
  local rc=0
  local output
  output=$(run_guard_with_transcript "Bash" "$cmd" "$SUBAGENT_TRANSCRIPT") || rc=$?
  local decision reason
  decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
  reason=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)
  if [ "$decision" = "deny" ] \
    && [[ "$reason" == *"reviewer-shell-wrapper"* ]] \
    && [[ "$reason" == *"Shell-command wrappers"* ]] \
    && [[ "$reason" == *"subshell"* ]] \
    && [[ "$reason" == *"bash <script.sh>"* ]]; then
    pass "$label"
  else
    fail "$label — expected deny with shell-wrapper guidance, got decision=$decision reason=$reason"
  fi
}

echo "TC-057ad: subagent + 'bash -c \"echo readonly-probe\"' (no git) → deny + wrapper guidance"
assert_subagent_deny_wrapper_guidance "subagent non-git bash -c probe denied with wrapper guidance" \
  'bash -c "echo readonly-probe"'

echo "TC-057ae: subagent + 'bash -c \"git status\"' (read-only git wrapped) → deny + wrapper guidance (no relaxation)"
assert_subagent_deny_wrapper_guidance "subagent read-only-git bash -c probe still denied (policy: no relaxation)" \
  'bash -c "git status"'

echo "TC-057ag: subagent + 'eval \"echo x\"' → deny (wrapper)"
assert_subagent_deny_wrapper_guidance "subagent eval denied" 'eval "echo x"'

echo "TC-057ah: subagent + 'sh -c ...' hiding a .git write → deny (wrapper closes the (H) bypass)"
assert_subagent_deny_wrapper_guidance "subagent sh -c hiding .git write denied" \
  "sh -c 'echo pwned > .git/hooks/pre-commit'"

echo "TC-057ai: subagent + 'bash script.sh' (not -c) → allow"
assert_subagent_allow "subagent bash <script.sh> allowed (only -c forms are wrappers)" "bash /tmp/probe.sh"
echo ""

# --------------------------------------------------------------------------
# Tier 2/3 subagent detection (TC-113〜115)
# 検出そのものは (L)/(Z)/(H) のスコープ判定として存続する。deny 対象は verb
# 列挙撤去に伴い .git write (H) に変更 (Issue #1879)。
# --------------------------------------------------------------------------

# alias of MAIN_TRANSCRIPT (above) — Tier 2/3 セクションを self-contained に保つため局所定義
MAIN_TRANSCRIPT_TC113="$MAIN_TRANSCRIPT"
TIER_PROBE_CMD="echo pwned > .git/hooks/pre-commit"

# Helper: run hook with raw JSON input + clean env (Tier 3 env vars unset)
#   Optional 引数: $2 / $3 に `NAME=value` 形式を渡すと、env -u で unset した後に SET する
#   (TC-114 / TC-114b の Tier 3 env var 経路を helper 経由で表現可能にする)。
run_guard_clean_env() {
  local raw_input="$1"
  local set1="${2:-}"
  local set2="${3:-}"
  local rc=0
  local output
  # env(1) は引数順序で処理する: -u X で X を unset した直後の X=val は最終的に
  # X=val として export される。${var:+...} expansion により空引数を env に渡さない。
  output=$(env -u CLAUDE_SUBAGENT_TYPE -u CLAUDE_AGENT_TYPE ${set1:+"$set1"} ${set2:+"$set2"} bash -c 'echo "$1" | bash "$2" 2>"$3"' _ "$raw_input" "$HOOK" "$STDERR_FILE") || rc=$?
  echo "$output"
  return $rc
}

# --------------------------------------------------------------------------
# TC-113: subagent_type field set → Tier 2 deny (.git write blocked)
# --------------------------------------------------------------------------
echo "TC-113: input JSON subagent_type field → Tier 2 deny"
rc=0
tc113_input=$(jq -n --arg tp "$MAIN_TRANSCRIPT_TC113" --arg cmd "$TIER_PROBE_CMD" '{tool_name: "Bash", tool_input: {command: $cmd}, cwd: "/tmp", transcript_path: $tp, subagent_type: "code-reviewer"}')
output=$(run_guard_clean_env "$tc113_input") || rc=$?
decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
reason=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)
stderr_log=$(cat "$STDERR_FILE")
if [ "$decision" = "deny" ] && [[ "$reason" == *"reviewer-gitdir-write"* ]]; then
  pass "TC-113 subagent_type field triggers Tier 2 fallback"
else
  fail "TC-113 expected deny, got decision=$decision reason=$reason"
fi
if [[ "$stderr_log" == *"reviewer-gitdir-write"* ]]; then
  pass "TC-113 stderr block log recorded"
else
  fail "TC-113 expected stderr block log, got: $stderr_log"
fi
echo ""

# --------------------------------------------------------------------------
# TC-113b: agent_type field set (subagent_type 不在) → Tier 2 deny
#   実装が `.subagent_type // .agent_type` の OR 経路を持つことを検証 (silent breakage 防止)
# --------------------------------------------------------------------------
echo "TC-113b: agent_type field set → Tier 2 deny"
rc=0
tc113b_input=$(jq -n --arg tp "$MAIN_TRANSCRIPT_TC113" --arg cmd "$TIER_PROBE_CMD" '{tool_name: "Bash", tool_input: {command: $cmd}, cwd: "/tmp", transcript_path: $tp, agent_type: "code-reviewer"}')
output=$(run_guard_clean_env "$tc113b_input") || rc=$?
decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
reason=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)
stderr_log=$(cat "$STDERR_FILE")
if [ "$decision" = "deny" ] && [[ "$reason" == *"reviewer-gitdir-write"* ]]; then
  pass "TC-113b agent_type field triggers Tier 2 fallback (OR with subagent_type)"
else
  fail "TC-113b expected deny, got decision=$decision reason=$reason"
fi
if [[ "$stderr_log" == *"reviewer-gitdir-write"* ]]; then
  pass "TC-113b stderr block log recorded"
else
  fail "TC-113b expected stderr block log, got: $stderr_log"
fi
echo ""

# --------------------------------------------------------------------------
# TC-113c: subagent_type: "" (空文字列) → Tier 2 fires NOT (main session 扱い)
#   `| strings` filter + `[ -n "" ]` false により presence-only check が空文字を弾く挙動を検証
# --------------------------------------------------------------------------
echo "TC-113c: subagent_type=\"\" → Tier 2 does not fire (main session)"
rc=0
tc113c_input=$(jq -n --arg tp "$MAIN_TRANSCRIPT_TC113" --arg cmd "$TIER_PROBE_CMD" '{tool_name: "Bash", tool_input: {command: $cmd}, cwd: "/tmp", transcript_path: $tp, subagent_type: ""}')
output=$(run_guard_clean_env "$tc113c_input") || rc=$?
if [ "$rc" = "0" ] && [ -z "$output" ]; then
  pass "TC-113c empty subagent_type does not trigger Tier 2 (main session preserved)"
else
  fail "TC-113c expected allow, got rc=$rc output=$output"
fi
echo ""

# --------------------------------------------------------------------------
# TC-113d: subagent_type=123 (non-string numeric) → Tier 2 fires NOT
#   `(.subagent_type | strings // "")` filter が numeric 値を空文字に正規化することを検証。
#   `| strings` filter を `// empty` 等に縮退する mutation を kill する coverage。
# --------------------------------------------------------------------------
echo "TC-113d: subagent_type=123 → Tier 2 does not fire (numeric rejected by | strings)"
rc=0
tc113d_input=$(jq -n --arg tp "$MAIN_TRANSCRIPT_TC113" --arg cmd "$TIER_PROBE_CMD" '{tool_name: "Bash", tool_input: {command: $cmd}, cwd: "/tmp", transcript_path: $tp, subagent_type: 123}')
output=$(run_guard_clean_env "$tc113d_input") || rc=$?
if [ "$rc" = "0" ] && [ -z "$output" ]; then
  pass "TC-113d numeric subagent_type does not trigger Tier 2 (| strings filter rejects non-string)"
else
  fail "TC-113d expected allow, got rc=$rc output=$output"
fi
echo ""

# --------------------------------------------------------------------------
# TC-113e: subagent_type=[...] (non-string array) → Tier 2 fires NOT
#   `(.subagent_type | strings // "")` filter が array 値を空文字に正規化することを検証。
# --------------------------------------------------------------------------
echo "TC-113e: subagent_type=[...] → Tier 2 does not fire (array rejected by | strings)"
rc=0
tc113e_input=$(jq -n --arg tp "$MAIN_TRANSCRIPT_TC113" --arg cmd "$TIER_PROBE_CMD" '{tool_name: "Bash", tool_input: {command: $cmd}, cwd: "/tmp", transcript_path: $tp, subagent_type: ["code-reviewer", "security"]}')
output=$(run_guard_clean_env "$tc113e_input") || rc=$?
if [ "$rc" = "0" ] && [ -z "$output" ]; then
  pass "TC-113e array subagent_type does not trigger Tier 2 (| strings filter rejects non-string)"
else
  fail "TC-113e expected allow, got rc=$rc output=$output"
fi
echo ""

# --------------------------------------------------------------------------
# TC-113f: subagent_type={...} (non-string object) → Tier 2 fires NOT
#   `(.subagent_type | strings // "")` filter が object 値を空文字に正規化することを検証。
# --------------------------------------------------------------------------
echo "TC-113f: subagent_type={...} → Tier 2 does not fire (object rejected by | strings)"
rc=0
tc113f_input=$(jq -n --arg tp "$MAIN_TRANSCRIPT_TC113" --arg cmd "$TIER_PROBE_CMD" '{tool_name: "Bash", tool_input: {command: $cmd}, cwd: "/tmp", transcript_path: $tp, subagent_type: {name: "code-reviewer", level: 1}}')
output=$(run_guard_clean_env "$tc113f_input") || rc=$?
if [ "$rc" = "0" ] && [ -z "$output" ]; then
  pass "TC-113f object subagent_type does not trigger Tier 2 (| strings filter rejects non-string)"
else
  fail "TC-113f expected allow, got rc=$rc output=$output"
fi
echo ""

# --------------------------------------------------------------------------
# TC-114: CLAUDE_SUBAGENT_TYPE env var set → Tier 3 deny
#   run_guard_clean_env の第 2 引数で SUBAGENT 単独経路を検証 (helper 経由 = DRY)
# --------------------------------------------------------------------------
echo "TC-114: CLAUDE_SUBAGENT_TYPE env var → Tier 3 deny"
rc=0
tc114_input=$(jq -n --arg tp "$MAIN_TRANSCRIPT_TC113" --arg cmd "$TIER_PROBE_CMD" '{tool_name: "Bash", tool_input: {command: $cmd}, cwd: "/tmp", transcript_path: $tp}')
output=$(run_guard_clean_env "$tc114_input" "CLAUDE_SUBAGENT_TYPE=code-reviewer") || rc=$?
decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
reason=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)
stderr_log=$(cat "$STDERR_FILE")
if [ "$decision" = "deny" ] && [[ "$reason" == *"reviewer-gitdir-write"* ]]; then
  pass "TC-114 CLAUDE_SUBAGENT_TYPE triggers Tier 3 fallback"
else
  fail "TC-114 expected deny via env var, got decision=$decision reason=$reason"
fi
if [[ "$stderr_log" == *"reviewer-gitdir-write"* ]]; then
  pass "TC-114 stderr block log recorded"
else
  fail "TC-114 expected stderr block log, got: $stderr_log"
fi
echo ""

# --------------------------------------------------------------------------
# TC-114b: CLAUDE_AGENT_TYPE env var single (SUBAGENT unset) → Tier 3 deny
#   実装 `[ -n "${CLAUDE_SUBAGENT_TYPE:-}" ] || [ -n "${CLAUDE_AGENT_TYPE:-}" ]` の OR 経路検証
# --------------------------------------------------------------------------
echo "TC-114b: CLAUDE_AGENT_TYPE env var → Tier 3 deny"
rc=0
tc114b_input=$(jq -n --arg tp "$MAIN_TRANSCRIPT_TC113" --arg cmd "$TIER_PROBE_CMD" '{tool_name: "Bash", tool_input: {command: $cmd}, cwd: "/tmp", transcript_path: $tp}')
output=$(run_guard_clean_env "$tc114b_input" "CLAUDE_AGENT_TYPE=code-reviewer") || rc=$?
decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
reason=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)
stderr_log=$(cat "$STDERR_FILE")
if [ "$decision" = "deny" ] && [[ "$reason" == *"reviewer-gitdir-write"* ]]; then
  pass "TC-114b CLAUDE_AGENT_TYPE triggers Tier 3 fallback (OR with CLAUDE_SUBAGENT_TYPE)"
else
  fail "TC-114b expected deny via env var, got decision=$decision reason=$reason"
fi
if [[ "$stderr_log" == *"reviewer-gitdir-write"* ]]; then
  pass "TC-114b stderr block log recorded"
else
  fail "TC-114b expected stderr block log, got: $stderr_log"
fi
echo ""

# --------------------------------------------------------------------------
# TC-115: All three tiers unset → main session, .git write allowed (regression guard)
# --------------------------------------------------------------------------
echo "TC-115: 3 tiers unset → main session allowed (regression guard)"
rc=0
tc115_input=$(jq -n --arg tp "$MAIN_TRANSCRIPT_TC113" --arg cmd "$TIER_PROBE_CMD" '{tool_name: "Bash", tool_input: {command: $cmd}, cwd: "/tmp", transcript_path: $tp}')
output=$(run_guard_clean_env "$tc115_input") || rc=$?
if [ "$rc" = "0" ] && [ -z "$output" ]; then
  pass "TC-115 main session .git write allowed (Tier 2/3 no false positives)"
else
  fail "TC-115 expected allow, got rc=$rc output=$output"
fi
echo ""

# --------------------------------------------------------------------------
# TC-116: deny fallback (jq -n emit failure) → valid JSON, deny preserved
#   stop-loop-continuation.test.sh TC-16 と同じ fake jq パターン: `jq -n` のみ exit 1 させ、
#   それ以外 (hook 冒頭の payload parse 等) は real jq へ委譲する。jq 全欠落は payload parse が
#   先に失敗して fail-open するため、現実的な fallback トリガーは emit-only の jq 失敗。
#   _deny_reason の構成要素は現状ハードコード文字列だが、fallback が改行 \n エスケープ +
#   neutralize_ctrl --c0-only を経由して valid JSON を emit し deny + exit 2 を維持することを pin する。
#   エスケープ連鎖そのものの非 vacuous 検証 (改行 / raw C0 実入力) は TC-117 が担う。
# --------------------------------------------------------------------------
echo "TC-116: deny fallback (jq -n emit failure) → valid JSON, deny preserved"
rc=0
real_jq=$(command -v jq)
tc116_input=$("$real_jq" -n '{tool_name: "Bash", tool_input: {command: "gh pr diff 123 --stat"}, cwd: "/tmp"}')
fake_bin_116=$(mktemp -d)
cat > "$fake_bin_116/jq" <<EOF
#!/bin/bash
if [ "\$1" = "-n" ]; then exit 1; fi
exec "$real_jq" "\$@"
EOF
chmod +x "$fake_bin_116/jq"
output=$(echo "$tc116_input" | PATH="$fake_bin_116:$PATH" bash "$HOOK" 2>"$STDERR_FILE") || rc=$?
# Sanity pin: fallback 経路が emit した (primary jq 経路ではない)
if [ -n "$output" ]; then
  pass "TC-116 fallback emitted output despite jq -n failure"
else
  fail "TC-116 no output — fallback path not reached: $(cat -v "$STDERR_FILE")"
fi
if [ "$rc" = "2" ]; then
  pass "TC-116 fallback exits 2 (fail-closed deny contract)"
else
  fail "TC-116 expected rc=2, got rc=$rc"
fi
# RFC 8259 validity — 改行/C0 生バイトが文字列リテラルに残ると parse が失敗する
if printf '%s' "$output" | "$real_jq" -e . >/dev/null 2>&1; then
  pass "TC-116 fallback output is valid JSON"
else
  fail "TC-116 fallback output is not parseable JSON: $(printf '%s' "$output" | cat -v)"
fi
decision=$(printf '%s' "$output" | "$real_jq" -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
reason=$(printf '%s' "$output" | "$real_jq" -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)
if [ "$decision" = "deny" ] && [[ "$reason" == *"gh-pr-diff-stat"* ]]; then
  pass "TC-116 deny decision and pattern name survive the fallback"
else
  fail "TC-116 expected deny with gh-pr-diff-stat via fallback, got decision=$decision reason=$reason"
fi
# raw C0 バイト (ESC 等) の非漏出 — neutralize_ctrl --c0-only の挙動 pin
if printf '%s' "$output" | LC_ALL=C grep -q $'\x1b'; then
  fail "TC-116 fallback JSON leaked a raw ESC byte: $(printf '%s' "$output" | cat -v)"
else
  pass "TC-116 fallback JSON contains no raw ESC byte"
fi
rm -rf "$fake_bin_116"
echo ""

# --------------------------------------------------------------------------
# TC-117: _bash_guard_escape_deny_reason — 改行/C0 実入力の非 vacuous 変換 pin
#   TC-116 は fallback 経路の構造契約 (到達 / rc=2 / deny 生存) を pin するが、現行の
#   _deny_reason は静的 ASCII のみで構成されるため、エスケープ連鎖そのものは no-op の
#   まま pass する (vacuous)。本 TC は hook から関数定義を境界行
#   (`_bash_guard_escape_deny_reason() {` 〜 `}`) で抽出し、改行 + raw ESC + CR + TAB +
#   backslash + double-quote を含む入力を直接流して変換を非 vacuous に検証する。
#   エスケープ連鎖のどの 1 行を欠落させても assertion が落ちる (mutation 耐性):
#   \\ 行欠落 → (3) invalid JSON (\s は invalid escape)、\" 行欠落 → (3) 構造破壊、
#   \n 行欠落 → (1) literal \n 不在 (改行は --c0-only で ? 化されるため)、
#   neutralize 行欠落 → (2) raw ESC 残存。
# --------------------------------------------------------------------------
echo "TC-117: _bash_guard_escape_deny_reason neutralizes newline/C0 input (non-vacuous)"
real_jq=$(command -v jq)
# 依存 helper (neutralize_ctrl) を source し、関数定義を hook から抽出して取り込む
source "$SCRIPT_DIR/../control-char-neutralize.sh"
eval "$(awk '/^_bash_guard_escape_deny_reason\(\) \{$/,/^\}$/' "$HOOK")"
if declare -f _bash_guard_escape_deny_reason >/dev/null 2>&1; then
  pass "TC-117 function extracted from hook"
  tc117_input=$(printf 'line1 "quoted" back\\slash\nline2 \x1b[31mred\x1b[0m tab:\there cr:\r.')
  tc117_out=$(_bash_guard_escape_deny_reason "$tc117_input") || tc117_out=""
  # (1) raw 改行ゼロ + literal \n 保存 (改行が neutralize で ? 化される mutation も検出)
  tc117_nl_count=$(printf '%s' "$tc117_out" | LC_ALL=C wc -l | tr -d ' ')
  if [ "$tc117_nl_count" = "0" ] && [[ "$tc117_out" == *'line1'*'\n'*'line2'* ]]; then
    pass "TC-117 newline escaped to literal \\n (no raw newline)"
  else
    fail "TC-117 newline not escaped (raw_nl=$tc117_nl_count): $(printf '%s' "$tc117_out" | cat -v)"
  fi
  # (2) raw ESC/TAB/CR バイトの非漏出 (? 化)
  tc117_c0_count=$(printf '%s' "$tc117_out" | LC_ALL=C tr -cd '\033\011\015' | LC_ALL=C wc -c | tr -d ' ')
  if [ "$tc117_c0_count" = "0" ]; then
    pass "TC-117 raw C0 bytes (ESC/TAB/CR) neutralized"
  else
    fail "TC-117 $tc117_c0_count raw C0 byte(s) leaked: $(printf '%s' "$tc117_out" | cat -v)"
  fi
  # (3) JSON 文字列リテラル埋め込みで valid JSON (RFC 8259)
  tc117_json=$(printf '{"reason":"%s"}' "$tc117_out")
  if printf '%s' "$tc117_json" | "$real_jq" -e . >/dev/null 2>&1; then
    pass "TC-117 escaped output embeds as valid JSON"
  else
    fail "TC-117 invalid JSON after embedding: $(printf '%s' "$tc117_json" | cat -v)"
  fi
  # (4) decode round-trip: " と \ の構造保持 + \n の実改行復元 + ESC の ? 化
  tc117_decoded=$(printf '%s' "$tc117_json" | "$real_jq" -r '.reason // empty' 2>/dev/null) || tc117_decoded=""
  if [[ "$tc117_decoded" == *'"quoted"'* ]] && [[ "$tc117_decoded" == *'back\slash'* ]] \
     && [[ "$tc117_decoded" == *$'\n'* ]] && [[ "$tc117_decoded" == *'?[31mred?[0m'* ]]; then
    pass "TC-117 quote/backslash/newline survive round-trip, ESC degraded to ?"
  else
    fail "TC-117 round-trip mismatch: $(printf '%s' "$tc117_decoded" | cat -v)"
  fi
else
  fail "TC-117 could not extract _bash_guard_escape_deny_reason from hook (boundary lines changed?)"
fi
echo ""

# --------------------------------------------------------------------------
# TC-118: deny fallback neutralize 失敗 → static placeholder 縮退、deny + exit 2 維持
#   TC-116 は fallback 経路のエスケープ成功側 (reason に pattern 名が残る) を pin する。本 TC は
#   その先の二重障害 — fallback 内で _bash_guard_escape_deny_reason (neutralize_ctrl = 固定引数の
#   tr パイプ) まで失敗した場合 — の static placeholder 縮退を pin する。helper header が
#   「実質失敗しない」と明記する経路のため、fake tr で強制発火させる: neutralize_ctrl の
#   3 モードはいずれも第 1 引数に `\000-` レンジ文字列を持つので $1 マッチでのみ exit 1 し、
#   hook 内の他の tr 用途 (jq parse error path の `tr '\n' ' '` / flow-state contains_ctrl の
#   `tr -d ...` は $1=-d) は real tr へ委譲して巻き添えを防ぐ。
#   非 vacuous 性 (TC-116 の vacuous 教訓): neutralize 成功時は reason に pattern 名
#   (gh-pr-diff-stat) が入るため、「placeholder 文言あり + pattern 名なし」の両方向 assert で
#   縮退の発生そのものを証明する。
# --------------------------------------------------------------------------
echo "TC-118: deny fallback neutralize failure → static placeholder, deny + exit 2 preserved"
rc=0
real_jq=$(command -v jq)
real_tr=$(command -v tr)
tc118_input=$("$real_jq" -n '{tool_name: "Bash", tool_input: {command: "gh pr diff 123 --stat"}, cwd: "/tmp"}')
fake_bin_118=$(mktemp -d)
cat > "$fake_bin_118/jq" <<EOF
#!/bin/bash
if [ "\$1" = "-n" ]; then exit 1; fi
exec "$real_jq" "\$@"
EOF
cat > "$fake_bin_118/tr" <<EOF
#!/bin/bash
case "\$1" in *000-*) exit 1 ;; esac
exec "$real_tr" "\$@"
EOF
chmod +x "$fake_bin_118/jq" "$fake_bin_118/tr"
output=$(echo "$tc118_input" | PATH="$fake_bin_118:$PATH" bash "$HOOK" 2>"$STDERR_FILE") || rc=$?
# Sanity pin: placeholder 縮退経路でも JSON を emit した (silent allow へ降格していない)
if [ -n "$output" ]; then
  pass "TC-118 placeholder path emitted output despite jq -n + tr failure"
else
  fail "TC-118 no output — placeholder path not reached: $(cat -v "$STDERR_FILE")"
fi
if [ "$rc" = "2" ]; then
  pass "TC-118 placeholder path exits 2 (fail-closed deny contract)"
else
  fail "TC-118 expected rc=2, got rc=$rc"
fi
if printf '%s' "$output" | "$real_jq" -e . >/dev/null 2>&1; then
  pass "TC-118 placeholder output is valid JSON"
else
  fail "TC-118 placeholder output is not parseable JSON: $(printf '%s' "$output" | cat -v)"
fi
decision=$(printf '%s' "$output" | "$real_jq" -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
reason=$(printf '%s' "$output" | "$real_jq" -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)
if [ "$decision" = "deny" ]; then
  pass "TC-118 deny decision survives the placeholder degradation"
else
  fail "TC-118 expected deny via placeholder path, got decision=$decision"
fi
# 縮退の発生証明 (非 vacuous): placeholder 文言あり + 通常 fallback の pattern 名なし
if [[ "$reason" == *"reason neutralization failed, fail-closed"* ]] && [[ "$reason" != *"gh-pr-diff-stat"* ]]; then
  pass "TC-118 reason degraded to the static placeholder (no pattern name leak)"
else
  fail "TC-118 expected static placeholder reason, got: $reason"
fi
# placeholder が案内する stderr ログの前提を pin (pattern 名はこちらに残る)
if grep -q "BLOCKED pattern=gh-pr-diff-stat" "$STDERR_FILE"; then
  pass "TC-118 stderr BLOCKED log keeps the pattern name (placeholder's referenced log)"
else
  fail "TC-118 stderr missing BLOCKED log: $(cat -v "$STDERR_FILE")"
fi
rm -rf "$fake_bin_118"
echo ""

# --------------------------------------------------------------------------
# TC-119〜122: Pattern 4 (security boundary) fail-closed vs Pattern 1-3 fail-open
#   Issue #1717: Pattern 4 shared the fail-OPEN ERR trap with the convenience
#   patterns, so a parse crash inside Pattern 4 converged to exit 0 (allow) and
#   silently bypassed the security boundary. The fix installs a fail-CLOSED ERR
#   trap over the Pattern 4 block (deny + exit 2 + WARNING) and restores
#   fail-open afterwards. Pattern 4 uses only bash built-ins, so — unlike the
#   deny-emit path faked in TC-118 — it cannot be crashed via a fake external
#   binary; the hook exposes a test-only, fail-CLOSED-ONLY fault-injection env
#   var (RITE_BTG_TEST_CRASH=pattern4) that raises an ERR inside the trap region
#   (TC-119). A symmetric fail-OPEN injection was deliberately NOT added — an
#   env-triggered fail-open path would be an allow-all backdoor — so the
#   Patterns 1-3 fail-open invariant is pinned structurally instead (TC-120).
# --------------------------------------------------------------------------
echo "TC-119: Pattern 4 crash in reviewer subagent → deny + exit 2 + stderr WARNING"
rc=0
tc119_input=$(jq -n --arg cmd "git status" --arg tp "$SUBAGENT_TRANSCRIPT" \
  '{tool_name: "Bash", tool_input: {command: $cmd}, cwd: "/tmp", transcript_path: $tp}')
output=$(echo "$tc119_input" | RITE_BTG_TEST_CRASH=pattern4 bash "$HOOK" 2>"$STDERR_FILE") || rc=$?
decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
reason=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)
stderr_log=$(cat "$STDERR_FILE")
if [ "$rc" = "2" ]; then
  pass "TC-119 Pattern 4 crash exits 2 (fail-closed, not the old exit 0 allow)"
else
  fail "TC-119 expected rc=2, got rc=$rc"
fi
if [ "$decision" = "deny" ] && [[ "$reason" == *"reviewer-gitdir-write"* ]]; then
  pass "TC-119 emits deny JSON with reviewer-gitdir-write reason"
else
  fail "TC-119 expected deny (reviewer-gitdir-write), got decision=$decision reason=$reason"
fi
if [[ "$stderr_log" == *"WARNING"* ]] && [[ "$stderr_log" == *"Pattern 4"* ]]; then
  pass "TC-119 stderr WARNING makes the fail-closed firing visible"
else
  fail "TC-119 expected stderr WARNING for Pattern 4, got: $stderr_log"
fi
echo ""

echo "TC-120: Patterns 1-3 fail-open invariant is structurally preserved"
# A crash in the Patterns 1-3 region must still resolve to allow. This is
# guaranteed structurally: the default ERR trap is the fail-OPEN handler, and the
# fail-CLOSED trap is installed ONLY inside the reviewer-only Pattern 4 block and
# restored to fail-open at that block's exit. We deliberately do NOT ship a
# fail-open fault-injection env var to drive this behaviorally — such a var would
# be an allow-all backdoor to the security boundary (Issue #1717 review F-02). So
# we pin the invariants that guarantee it by inspecting the hook source.
tc120_src=$(cat "$HOOK")
# (a) the default (pre-Pattern-4) ERR trap is the fail-OPEN handler
if [[ "$tc120_src" == *"trap '_rite_btg_pattern13_fail_open' ERR"* ]]; then
  pass "TC-120 default ERR trap is the fail-open handler (Patterns 1-3 fail open)"
else
  fail "TC-120 default fail-open ERR trap not found in hook source"
fi
# (b) the fail-CLOSED trap is installed inside the Pattern 4 block (swap-in present)
if [[ "$tc120_src" == *"trap '_rite_btg_pattern4_fail_closed' ERR"* ]]; then
  pass "TC-120 fail-closed trap is swapped in for the Pattern 4 block"
else
  fail "TC-120 fail-closed swap line not found in hook source"
fi
# (c) the fail-OPEN trap is restored at Pattern 4 block exit. Pin the EXECUTABLE
# statement, not a comment: the fail-open trap line must appear at least TWICE — once
# as the default install (before Pattern 4) and once as the restore (block exit). This
# is the only guard for the block-exit fail-open restoration (behavioral injection
# was removed as an allow-all backdoor, F-02), so it must catch deletion of the
# actual restore statement — not just its comment (Issue #1717 review F-04).
tc120_restore_count=$(printf '%s\n' "$tc120_src" | grep -c "trap '_rite_btg_pattern13_fail_open' ERR")
if [ "${tc120_restore_count:-0}" -ge 2 ]; then
  pass "TC-120 fail-open trap statement appears >=2x (default install + block-exit restore)"
else
  fail "TC-120 expected the fail-open trap statement >=2x (install+restore), found $tc120_restore_count"
fi
# (d) no fail-open fault-injection backdoor remains (F-02): the env var must never
# trigger an allow (fail-open) path. Assert the removed pattern13 injection is gone.
if [[ "$tc120_src" != *'RITE_BTG_TEST_CRASH:-}" = "pattern13"'* ]]; then
  pass "TC-120 no fail-open (pattern13) fault-injection backdoor remains"
else
  fail "TC-120 fail-open (pattern13) injection backdoor is still present in hook source"
fi
echo ""

echo "TC-121: Pattern 4 crash injection on a MAIN session → allow (no false deny; MUST NOT)"
# The fail-closed trap must be scoped to the reviewer-only Pattern 4 block. A main
# session never enters that block, so even with the injection var set it must not be
# denied — proves the fix does not add false denies to normal (non-reviewer) Bash.
rc=0
tc121_input=$(jq -n --arg cmd "git status" --arg tp "$MAIN_TRANSCRIPT" \
  '{tool_name: "Bash", tool_input: {command: $cmd}, cwd: "/tmp", transcript_path: $tp}')
output=$(echo "$tc121_input" | RITE_BTG_TEST_CRASH=pattern4 bash "$HOOK" 2>"$STDERR_FILE") || rc=$?
if [ "$rc" = "0" ] && [ -z "$output" ]; then
  pass "TC-121 main-session Bash is not denied by the Pattern 4 fail-closed trap"
else
  fail "TC-121 expected allow (rc=0, empty) for main session, got rc=$rc output=$output"
fi
echo ""

echo "TC-122: hooks.json PreToolUse:Bash has a timeout"
HOOKS_JSON="$SCRIPT_DIR/../hooks.json"
if jq empty "$HOOKS_JSON" 2>/dev/null; then
  pass "TC-122 hooks.json is valid JSON"
else
  fail "TC-122 hooks.json is not valid JSON"
fi
tc122_timeout=$(jq -r '.hooks.PreToolUse[]?.hooks[]? | select((.command // "") | test("pre-tool-bash-guard")) | .timeout // empty' "$HOOKS_JSON" 2>/dev/null)
if [ -n "$tc122_timeout" ] && [[ "$tc122_timeout" =~ ^[0-9]+$ ]]; then
  pass "TC-122 pre-tool-bash-guard hook has a numeric timeout ($tc122_timeout)"
else
  fail "TC-122 expected a numeric timeout on the PreToolUse:Bash hook, got '$tc122_timeout'"
fi
# Pin the exact value (Issue #1717 review F-03): the .sh header comment documents
# "10s" and nothing else ties that prose to the config. Pin 10 here so that
# changing hooks.json without updating the header comment fails this test (drift
# detection). Update BOTH this literal and the .sh header if the value ever changes.
if [ "$tc122_timeout" = "10" ]; then
  pass "TC-122 timeout value is 10 (matches the value documented in the .sh header)"
else
  fail "TC-122 expected timeout=10 (as documented in pre-tool-bash-guard.sh header), got '$tc122_timeout'"
fi
echo ""

echo "TC-124: oversized command → length-guard fail-closed deny WITHOUT the O(n²) paths"
# The (L) length guard is the primary timeout-bypass bound: any reviewer command
# over the byte ceiling is denied fail-closed BEFORE the O(n²) heredoc strip
# (${COMMAND%%<<*}, ~45s on ~1.3MB) and the O(n²) Pattern 2 regex (>2min on a few
# MB) — both of which would otherwise time out the fail-open hook and let a padded
# .git write run. Build huge commands via temp file + --rawfile to avoid argv
# limits, and pin that the deny is FAST (proves the O(n²) work is skipped).
tc124_dir=$(mktemp -d)
tc124_bigval=$(printf 'x%.0s' $(seq 1 10000))
# (a) 1.28MB command padded with huge values → fast deny
{ printf 'git '; for _i in $(seq 1 128); do printf -- '-C %s ' "$tc124_bigval"; done; printf 'status'; } > "$tc124_dir/cmd.txt"
jq -n --rawfile cmd "$tc124_dir/cmd.txt" --arg tp "$SUBAGENT_TRANSCRIPT" \
  '{tool_name: "Bash", tool_input: {command: $cmd}, cwd: "/tmp", transcript_path: $tp}' > "$tc124_dir/in.json"
rc=0
_t0=$(date +%s%N)
output=$(_timeout 15 bash "$HOOK" < "$tc124_dir/in.json" 2>"$STDERR_FILE") || rc=$?
_t1=$(date +%s%N)
_ms=$(( (_t1 - _t0) / 1000000 ))
decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
reason=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)
if [ "$decision" = "deny" ] && [ "$rc" != "124" ]; then
  pass "TC-124 oversized (1.3MB) reviewer command is denied fail-closed"
else
  fail "TC-124 expected deny for oversized command, got decision=$decision rc=$rc"
fi
if [[ "$reason" == *"reviewer-oversized-command"* ]] && [[ "$reason" == *"abnormally large"* ]]; then
  pass "TC-124 deny reason names the pattern and explains the timeout-bypass rationale"
else
  fail "TC-124 expected reviewer-oversized-command explanation in reason, got: $reason"
fi
if [ "$_ms" -lt 5000 ]; then
  pass "TC-124 oversized deny completes fast (${_ms}ms < 5s — O(n²) paths skipped, no timeout→fail-open)"
else
  fail "TC-124 oversized deny too slow (${_ms}ms) — length guard is not short-circuiting the O(n²) work"
fi
# (b) oversized (~80KB) READ-ONLY command → deny (allow→deny flip; a small `git status` allows)
{ printf 'git '; for _i in $(seq 1 8); do printf -- '-C %s ' "$tc124_bigval"; done; printf 'status'; } > "$tc124_dir/ro.txt"
jq -n --rawfile cmd "$tc124_dir/ro.txt" --arg tp "$SUBAGENT_TRANSCRIPT" \
  '{tool_name: "Bash", tool_input: {command: $cmd}, cwd: "/tmp", transcript_path: $tp}' > "$tc124_dir/roin.json"
rc=0
output=$(_timeout 15 bash "$HOOK" < "$tc124_dir/roin.json" 2>"$STDERR_FILE") || rc=$?
decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
if [ "$decision" = "deny" ]; then
  pass "TC-124 oversized READ-ONLY reviewer command is denied (length guard, allow→deny flip)"
else
  fail "TC-124 expected deny for oversized read-only command, got decision=$decision rc=$rc"
fi
# (c) oversized because of a huge heredoc BODY, with a READ-ONLY prefix → deny.
# The length guard checks ${#COMMAND} over the WHOLE command (heredoc body included),
# so it fires here. Non-vacuous (Issue #1717 review F-06): the prefix `git status` is
# read-only, so WITHOUT the length guard the heredoc strip yields `git status` and the
# command is ALLOWED — WITH it the command is denied. (Note: the `<<` sits near the
# front, so `${COMMAND%%<<*}` is itself fast here regardless — this case pins the
# length guard's use of the full command length, not the O(n²) strip skip; the O(n²)
# no-heredoc path is covered by (a).)
{ printf 'git status <<EOF\n'; printf 'y%.0s' $(seq 1 200000); printf '\nEOF'; } > "$tc124_dir/hd.txt"
jq -n --rawfile cmd "$tc124_dir/hd.txt" --arg tp "$SUBAGENT_TRANSCRIPT" \
  '{tool_name: "Bash", tool_input: {command: $cmd}, cwd: "/tmp", transcript_path: $tp}' > "$tc124_dir/hdin.json"
rc=0
output=$(_timeout 15 bash "$HOOK" < "$tc124_dir/hdin.json" 2>"$STDERR_FILE") || rc=$?
decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
if [ "$decision" = "deny" ]; then
  pass "TC-124 heredoc-body-oversized READ-ONLY command is denied (length guard uses full command length)"
else
  fail "TC-124 expected deny for heredoc-body-oversized read-only command, got decision=$decision rc=$rc"
fi
# (d) oversized (~80KB) MAIN-session command → must NOT be denied (MUST NOT — reviewer-only guard)
jq -n --rawfile cmd "$tc124_dir/ro.txt" --arg tp "$MAIN_TRANSCRIPT" \
  '{tool_name: "Bash", tool_input: {command: $cmd}, cwd: "/tmp", transcript_path: $tp}' > "$tc124_dir/mainin.json"
# Positive control for the negative assertion that follows. The hook prints NOTHING
# when it permits a command — a deny JSON is the only thing it ever emits, which is
# why assert_subagent_allow spells allow as "rc 0 AND empty stdout" — so an empty
# stdout is exactly what the passing case looks like and cannot double as the liveness
# signal. Prove the fixture reaches the length guard instead: the same input with only
# transcript_path flipped to the reviewer transcript must be denied. Without that
# proof, a padding shortfall that drops ro.txt back under the byte ceiling, a corrupted
# tool_name, or a hook that allows everything early all read as "correctly permitted".
#
# Deriving the control from mainin.json is load-bearing, not a duplicate of (b): (b)
# builds roin.json independently, so a break in the jq that assembles mainin.json leaves
# (b) green while the assertion below goes vacuous. Only a control fed by the very file
# that assertion reads can catch it.
#
# Both assertions match the raw stdout instead of piping it through jq. Under
# `set -euo pipefail` a non-JSON stdout makes the extraction assignment abort before any
# assertion in this block runs, which loses the diagnosis entirely — the very failure
# mode this control exists to surface. The deny envelope carries `"deny"` exactly once
# and never inside the reason text, so the substring test is as strict as a
# `permissionDecision` parse would be, and it keeps `rc` free to distinguish a crash
# from a deny that exits non-zero. The
# fixture jq below can still abort the same way, but it builds our own input rather than
# reading the hook's output, and run-tests.sh reports that abort as a file-level failure.
jq --arg tp "$SUBAGENT_TRANSCRIPT" '.transcript_path = $tp' "$tc124_dir/mainin.json" > "$tc124_dir/mainctl.json"
rc=0
output=$(_timeout 15 bash "$HOOK" < "$tc124_dir/mainctl.json" 2>"$STDERR_FILE") || rc=$?
case "$output" in
  *'"deny"'*)
    pass "TC-124 (d) control: the fixture drives the length guard (same input, reviewer transcript → deny)"
    ;;
  *)
    fail "TC-124 (d) control: expected deny with the reviewer transcript, got rc=$rc output='$output' — the fixture or the guard regressed, so the MUST NOT assertion below would be vacuous: $(cat -v "$STDERR_FILE")"
    ;;
esac
rc=0
output=$(_timeout 15 bash "$HOOK" < "$tc124_dir/mainin.json" 2>"$STDERR_FILE") || rc=$?
# Assert the permit contract positively (no output, then rc 0). A bare `!= "deny"` test
# cannot express this contract: a crash, a timeout, and every output shape the hook never
# emits all leave the extracted decision empty, so they would all pass.
if [ -n "$output" ]; then
  case "$output" in
    *'"deny"'*)
      fail "TC-124 oversized main-session command was wrongly denied (MUST NOT violation): $output"
      ;;
    *)
      fail "TC-124 oversized main-session command: expected no output (permit), got: $output"
      ;;
  esac
elif [ "$rc" != "0" ]; then
  fail "TC-124 oversized main-session command: hook exited rc=$rc with no output instead of permitting: $(cat -v "$STDERR_FILE")"
else
  pass "TC-124 oversized MAIN-session command is not denied by the reviewer-only length guard"
fi
rm -rf "$tc124_dir"
echo ""

# --------------------------------------------------------------------------
# TC-125: reviewer WRITE into a .git directory (Issue #1864 AC-1, sub-block (H))
# The Bash-tool sibling of pre-tool-edit-guard's .git protection: a reviewer must not
# `echo pwned > .git/hooks/pre-commit` (RCE via next git op). Reading .git stays allowed.
# --------------------------------------------------------------------------
# --- Helper: deny assertion for the reviewer-gitdir-write pattern ---
assert_subagent_deny_gitdir() {
  local label="$1"
  local cmd="$2"
  local rc=0
  local output
  output=$(run_guard_with_transcript "Bash" "$cmd" "$SUBAGENT_TRANSCRIPT") || rc=$?
  local decision reason
  decision=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
  reason=$(echo "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)
  if [ "$decision" = "deny" ] && [[ "$reason" == *"reviewer-gitdir-write"* ]]; then
    pass "$label"
  else
    fail "$label — expected deny (reviewer-gitdir-write), got decision=$decision reason=$reason"
  fi
}

echo "TC-125a: subagent redirect into .git/hooks → deny"
assert_subagent_deny_gitdir "echo > .git/hooks/pre-commit blocked" "echo pwned > .git/hooks/pre-commit"

echo "TC-125b: subagent append (>>) into .git/hooks → deny"
assert_subagent_deny_gitdir "echo >> .git/hooks/pre-commit blocked" "echo pwned >> .git/hooks/pre-commit"

echo "TC-125c: subagent redirect (no space) into .git/config → deny"
assert_subagent_deny_gitdir "echo >.git/config blocked" "echo x >.git/config"

echo "TC-125d: subagent redirect into ABSOLUTE .git path → deny"
assert_subagent_deny_gitdir "abs .git redirect blocked" "echo x > /tmp/repo/.git/hooks/pre-commit"

echo "TC-125e: subagent redirect into ./.git → deny (leading ./)"
assert_subagent_deny_gitdir "./.git redirect blocked" "echo x > ./.git/config"

echo "TC-125f: subagent redirect with QUOTED .git target → deny"
assert_subagent_deny_gitdir "quoted .git target blocked" "echo x > \".git/hooks/pre-commit\""

echo "TC-125g: subagent redirect into .git after a meta-boundary (&&) → deny"
assert_subagent_deny_gitdir "compound redirect into .git blocked" "cat foo && echo x > .git/config"

echo "TC-125h: subagent tee into .git/hooks → deny"
assert_subagent_deny_gitdir "tee into .git blocked" "echo x | tee .git/hooks/pre-commit"

echo "TC-125i: subagent cp into .git/hooks → deny"
assert_subagent_deny_gitdir "cp into .git blocked" "cp /tmp/evil .git/hooks/pre-commit"

echo "TC-125j: subagent ln -s into .git/hooks → deny"
assert_subagent_deny_gitdir "ln -s into .git blocked" "ln -s /tmp/evil .git/hooks/pre-commit"

echo "TC-125k: subagent mv into .git → deny"
assert_subagent_deny_gitdir "mv into .git blocked" "mv /tmp/evil .git/hooks/pre-commit"

# --- CRITICAL regression: repo under a `/git`-containing ancestor (Issue #1864 fix) ---
# A removed `/git`→` git` invocation-normalization used to split these paths so `>` detached
# from the `.git` token → silent allow (RCE). The normalization is gone (Issue #1879), but these
# pin that /git-ancestor paths keep tokenizing intact.
echo "TC-125l: subagent redirect into .git under a /srv/git ancestor → deny (path not corrupted)"
assert_subagent_deny_gitdir "redirect into /srv/git/.../.git blocked" "echo evil > /srv/git/proj/.git/config"

echo "TC-125m: subagent append into .git under a ~/github ancestor → deny (path not corrupted)"
assert_subagent_deny_gitdir "append into /home/u/github/.../.git blocked" "echo x >> /home/u/github/proj/.git/hooks/pre-commit"

# --- fileverb absolute-path / backslash invocation (Issue #1864 fix) ---
echo "TC-125n: subagent absolute-path tee into .git → deny"
assert_subagent_deny_gitdir "/usr/bin/tee into .git blocked" "/usr/bin/tee .git/hooks/pre-commit"

echo "TC-125o: subagent backslash-escaped cp into .git → deny"
assert_subagent_deny_gitdir "\\cp into .git blocked" "\\cp /tmp/evil .git/hooks/pre-commit"

# --- dd of=<gitpath> write vector (Issue #1864 fix) ---
echo "TC-125p: subagent dd of=.git/hooks → deny"
assert_subagent_deny_gitdir "dd of=.git blocked" "dd if=/tmp/evil of=.git/hooks/pre-commit"

# --- value-quoted dd of= (Issue #1864 cycle-2 fix: quote-strip-after-of= ordering) ---
echo "TC-125q: subagent dd of='.git/…' (single-quoted value) → deny"
assert_subagent_deny_gitdir "dd of='.git' (single-quoted) blocked" "dd if=/tmp/evil of='.git/hooks/pre-commit'"

echo "TC-125r: subagent dd of=\".git/…\" (double-quoted value) → deny"
assert_subagent_deny_gitdir "dd of=\".git\" (double-quoted) blocked" "dd if=/tmp/evil of=\".git/hooks/pre-commit\""

# --- interior / nested quotes (Issue #1864 cycle-3 fix: global quote removal) ---
# A quote placed BETWEEN path components survives a fixed surrounding-strip but is removed by the
# shell before opening the path — global `${tok//[\"\']/}` closes the whole class.
echo "TC-125s: subagent dd of= with INTERIOR quote → deny"
assert_subagent_deny_gitdir "dd of=.g'i't/… (interior quote) blocked" "dd if=/tmp/evil of=.g'i't/hooks/pre-commit"

echo "TC-125t: subagent redirect into adjacent-quoted .git → deny"
assert_subagent_deny_gitdir "echo > '.git'/… (adjacent quote) blocked" "echo x > '.git'/hooks/pre-commit"

echo "TC-125u: subagent cp into interior-quoted .git → deny"
assert_subagent_deny_gitdir "cp into .g'i't/… (interior quote) blocked" "cp /tmp/evil .g'i't/hooks/pre-commit"

echo "TC-125v: subagent dd of= with NESTED quotes → deny"
assert_subagent_deny_gitdir "dd of=''.git/…'' (nested quotes) blocked" "dd if=/tmp/evil of=''.git/hooks/pre-commit''"

# --- backslash-escaped .git path components (Issue #1864 cycle-4 fix: backslash removal) ---
# POSIX quote-removal strips `\` too; the shell resolves `.g\it`→`.git`, so the gitpath check must
# strip backslashes as well as quotes to see the real target.
echo "TC-125w1: subagent redirect into backslash-in-component .git → deny"
assert_subagent_deny_gitdir "echo > .g\\it/… blocked" "echo pwned > .g\\it/hooks/pre-commit"

echo "TC-125w2: subagent redirect into leading-backslash .git → deny"
assert_subagent_deny_gitdir "echo > \\.git/… blocked" "echo pwned > \\.git/hooks/pre-commit"

echo "TC-125w3: subagent dd of= with backslash component → deny"
assert_subagent_deny_gitdir "dd of=.g\\it/… blocked" "dd if=/tmp/evil of=.g\\it/hooks/pre-commit"

echo "TC-125w4: subagent tee with backslash component → deny"
assert_subagent_deny_gitdir "tee .g\\it/… blocked" "echo x | tee .g\\it/hooks/pre-commit"

echo "TC-125w5: subagent dd with backslash-escaped of= prefix → deny"
assert_subagent_deny_gitdir "dd \\of=.git/… blocked" "dd if=/tmp/evil \\of=.git/hooks/pre-commit"

# --- obfuscated file-verb NAME (Issue #1864 cycle-5 fix: dequote the verb token too) ---
# The verb token is dequoted (quotes + backslashes) then basename'd, so a quoted/escaped verb name
# still latches the file-verb vector — the shell runs `'tee'` / `t\ee` as `tee`.
echo "TC-125x1: subagent backslash-in-verb tee into .git → deny"
assert_subagent_deny_gitdir "t\\ee .git blocked" "t\\ee .git/hooks/pre-commit"

echo "TC-125x2: subagent quoted verb 'tee' into .git → deny"
assert_subagent_deny_gitdir "'tee' .git blocked" "'tee' .git/hooks/pre-commit"

echo "TC-125x3: subagent interior-quoted verb t\"e\"e into .git → deny"
assert_subagent_deny_gitdir "t\"e\"e .git blocked" "t\"e\"e .git/hooks/pre-commit"

echo "TC-125x4: subagent backslash-in-verb cp into .git → deny"
assert_subagent_deny_gitdir "c\\p into .git blocked" "c\\p /tmp/evil .git/hooks/pre-commit"

echo "TC-125x5: subagent quoted verb 'dd' of=.git → deny"
assert_subagent_deny_gitdir "'dd' of=.git blocked" "'dd' if=/tmp/evil of=.git/hooks/pre-commit"

# --- additional positional file-writers (Issue #1864 cycle-5: sponge/patch, tee twins) ---
echo "TC-125y1: subagent sponge into .git/hooks → deny"
assert_subagent_deny_gitdir "sponge .git/hooks blocked" "echo pwned | sponge .git/hooks/pre-commit"

echo "TC-125y2: subagent patch into .git/config → deny"
assert_subagent_deny_gitdir "patch .git/config blocked" "patch .git/config"

echo "TC-125y3: subagent quoted verb 'sponge' into .git → deny (verb dequote)"
assert_subagent_deny_gitdir "'sponge' .git blocked" "echo x | 'sponge' .git/hooks/pre-commit"

# --- file-verb blocklist completeness: install / rsync / truncate are IN the case list
# (tee|cp|mv|ln|install|rsync|truncate|dd|sponge|patch) but lacked dedicated deny tests; pin them so
# a future edit that drops one literal from the case is caught (Issue #1864 follow-up). ---
echo "TC-125z1: subagent install into .git/hooks → deny"
assert_subagent_deny_gitdir "install into .git blocked" "install -m755 /tmp/evil .git/hooks/pre-commit"

echo "TC-125z2: subagent rsync into .git/hooks → deny"
assert_subagent_deny_gitdir "rsync into .git blocked" "rsync /tmp/evil .git/hooks/pre-commit"

echo "TC-125z3: subagent truncate .git/config → deny"
assert_subagent_deny_gitdir "truncate .git/config blocked" "truncate -s 0 .git/config"

# --- ALLOW cases: the false-positive gate ("read-only .git access not mis-detected") ---
echo "TC-125-ALLOW-a: subagent READS .git/config (cat) → allow"
assert_subagent_allow "cat .git/config allowed (read, not write)" "cat .git/config"

echo "TC-125-ALLOW-b: subagent LISTS .git/hooks (ls) → allow"
assert_subagent_allow "ls .git/hooks/ allowed" "ls .git/hooks/"

echo "TC-125-ALLOW-c: subagent greps .git/config → allow"
assert_subagent_allow "grep .git/config allowed" "grep hooksPath .git/config"

echo "TC-125-ALLOW-d: subagent legit isolation worktree setup → allow"
assert_subagent_allow "git worktree add --detach (isolation) allowed" \
  "git worktree add --detach /tmp/rite-review-mutation-abc HEAD"

echo "TC-125-ALLOW-e: boundary — dir literally named 'foo.git/' is NOT the .git component → allow"
assert_subagent_allow "redirect into myrepo.git/description NOT blocked" "echo x > myrepo.git/description"

echo "TC-125-ALLOW-f: redirect into a NON-.git path → allow"
assert_subagent_allow "redirect into /tmp/out.txt allowed" "echo x > /tmp/out.txt"

echo "TC-125-ALLOW-g: .git as INPUT-redirect source (read) → allow"
assert_subagent_allow "tee reading FROM .git via < allowed" "tee /tmp/x < .git/config"

echo "TC-125-ALLOW-i: dd READING .git via if= (of= writes elsewhere) → allow"
assert_subagent_allow "dd if=.git/config of=/tmp/x allowed (read source)" "dd if=.git/config of=/tmp/x"

# Over-broadening sentinel on /git-ancestor paths: a plain READ (cat/grep — no redirect, no file
# verb) must stay allowed even when the path contains a `/git` segment. (The WRITE-side regression
# guard is TC-125l/m; these pin that reads never start being blocked.)
echo "TC-125-ALLOW-j: read .git under /srv/git ancestor (cat) → allow"
assert_subagent_allow "cat /srv/git/.../.git/config allowed" "cat /srv/git/proj/.git/config"

echo "TC-125-ALLOW-k: read .git under ~/github ancestor (grep) → allow"
assert_subagent_allow "grep /home/u/github/.../.git/config allowed" "grep hooksPath /home/u/github/proj/.git/config"

echo "TC-125-ALLOW-h: MAIN session redirect into .git → allow (reviewer-only guard)"
assert_main_allow "main-session .git write not blocked by (H)" "echo x > .git/hooks/pre-commit"
echo ""

# --- noglob regression: the (H) tokenizer runs under `set -f`, so a reviewer command's bare glob
# (`*`/`?`/`[`) is NOT pathname-expanded against the hook CWD (Issue #1864 follow-up). Without noglob
# a `*` sitting BEFORE a `.git` READ path expands to CWD entries; a file named like a write-verb
# (cp/tee/…) then latches the file-verb vector and the legit `.git` READ is wrongly DENIED
# (false-positive; unbounded expansion could also time the hook out → fail-open). This pins the fix:
# with `set -f` the `*` stays literal → allow. Runs from a temp CWD holding verb-named files so the
# pre-fix (globbing) behavior would over-DENY (fail-on-revert).
tc125_noglob_dir=$(mktemp -d)
: > "$tc125_noglob_dir/cp"    # a file named like a write-verb — would latch _gd_fileverb if globbed
: > "$tc125_noglob_dir/tee"
_tc125_noglob_prev=$(pwd)
if cd "$tc125_noglob_dir"; then
  echo "TC-125-ALLOW-noglob: bare glob before a .git READ not polluted by CWD verb-files → allow (set -f)"
  assert_subagent_allow "grep with bare glob + .git READ allowed under noglob" "grep hooksPath * .git/config"
  cd "$_tc125_noglob_prev" || true
else
  fail "TC-125-ALLOW-noglob setup: cd into temp dir failed"
fi
rm -rf "$tc125_noglob_dir"
echo ""

# --------------------------------------------------------------------------
# TC-127: reviewer native .git-writing git subcommands (sub-block (N), #1879)
# `git config <key> <value>` / mutating `git remote` / `git update-ref` /
# `git symbolic-ref` write .git/config or .git refs directly — no redirect and
# no file verb, so (H) cannot see them. `git config core.hooksPath` is the exact
# RCE vector the header invariant names. These four subcommands were folded into
# the removed (A) always-deny block; sub-block (N) restores a machine gate for
# just their .git-write forms. Read forms of `git config` stay allowed.
# --------------------------------------------------------------------------
echo "TC-127a: subagent git config core.hooksPath (RCE vector) → deny"
assert_subagent_deny_gitdir "git config core.hooksPath blocked" "git config core.hooksPath /tmp/evil-hooks"

echo "TC-127b: subagent git config core.fsmonitor → deny"
assert_subagent_deny_gitdir "git config core.fsmonitor blocked" "git config core.fsmonitor /tmp/evil.sh"

echo "TC-127c: subagent git config alias.*=!cmd → deny"
assert_subagent_deny_gitdir "git config alias write blocked" "git config alias.x '!sh -c evil'"

echo "TC-127d: subagent git update-ref → deny"
assert_subagent_deny_gitdir "git update-ref blocked" "git update-ref refs/heads/foo abc1234"

echo "TC-127e: subagent git symbolic-ref → deny"
assert_subagent_deny_gitdir "git symbolic-ref blocked" "git symbolic-ref HEAD refs/heads/foo"

echo "TC-127f: subagent git remote set-url → deny"
assert_subagent_deny_gitdir "git remote set-url blocked" "git remote set-url origin https://evil.example/x"

echo "TC-127g: subagent git remote add → deny"
assert_subagent_deny_gitdir "git remote add blocked" "git remote add evil https://evil.example/x"

# Global-flag-prefix bypass: the subcommand does not sit right after `git`. These
# would slip a naive substring match (the removed (A)-(G) code normalized global
# flags for exactly this). (N) strips leading global flags so the subcommand
# surfaces, and denies inline `-c` config injection (no subcommand needed).
echo "TC-127h: subagent git -C . config core.hooksPath (flag prefix) → deny"
assert_subagent_deny_gitdir "git -C . config core.hooksPath blocked" "git -C . config core.hooksPath /tmp/evil"

echo "TC-127i: subagent git --git-dir=./.git config core.hooksPath → deny"
assert_subagent_deny_gitdir "git --git-dir config write blocked" "git --git-dir=./.git config core.hooksPath /tmp/evil"

echo "TC-127j: subagent git -c core.hooksPath=… <cmd> (inline config, no subcommand) → deny"
assert_subagent_deny_gitdir "git -c core.hooksPath inline blocked" "git -c core.hooksPath=/tmp/evil status"

echo "TC-127k: subagent git -c alias.x=!cmd log (inline alias) → deny"
assert_subagent_deny_gitdir "git -c alias inline blocked" "git -c alias.x='!sh -c evil' log"

echo "TC-127l: subagent git --work-tree=/x update-ref (flag prefix) → deny"
assert_subagent_deny_gitdir "git --work-tree update-ref blocked" "git --work-tree=/tmp update-ref refs/heads/foo abc1234"

echo "TC-127m: subagent git -C. config core.hooksPath (glued -C, self-contained) → deny"
assert_subagent_deny_gitdir "git -C. config core.hooksPath blocked" "git -C. config core.hooksPath /tmp/evil"

# Path / quoted / backslashed git-binary invocation: (N) must normalize the
# invocation token to bare `git` so the subcommand surfaces. Without this,
# `/usr/bin/git config core.hooksPath` slips the gate (bare-`git`-only check),
# and `\git` / `"git"` keep their decoration on the config-match path.
echo "TC-127n: subagent /usr/bin/git config core.hooksPath (abspath invocation) → deny"
assert_subagent_deny_gitdir "abspath git config write blocked" "/usr/bin/git config core.hooksPath /tmp/evil"

echo "TC-127o: subagent ./git config core.hooksPath (relative-path invocation) → deny"
assert_subagent_deny_gitdir "relpath git config write blocked" "./git config core.hooksPath /tmp/evil"

echo "TC-127p: subagent \\git config core.hooksPath (leading-backslash invocation) → deny"
assert_subagent_deny_gitdir "backslash git config write blocked" "\\git config core.hooksPath /tmp/evil"

echo "TC-127q: subagent /usr/bin/git update-ref (abspath) → deny"
assert_subagent_deny_gitdir "abspath git update-ref blocked" "/usr/bin/git update-ref refs/heads/foo abc1234"

# Quoted / backslashed git remote sub-action: the sub-action token must be
# dequoted before the ` git remote <action> ` match, else `git remote "add"`
# writes .git/config unblocked.
echo "TC-127r: subagent git remote \"add\" (quoted sub-action) → deny"
assert_subagent_deny_gitdir "quoted remote add blocked" "git remote \"add\" evil https://evil.example/x"

echo "TC-127s: subagent git remote se\"t-url\" (interior-quoted sub-action) → deny"
assert_subagent_deny_gitdir "interior-quoted remote set-url blocked" "git remote se\"t-url\" origin https://evil.example/x"

echo "TC-127t: subagent git remote a\\dd (backslash sub-action) → deny"
assert_subagent_deny_gitdir "backslash remote add blocked" "git remote a\\dd evil https://evil.example/x"

# Inline config injection via --config-env (sibling of -c; deny message names both).
echo "TC-127u: subagent git --config-env=core.hooksPath=EV (inline, =form) → deny"
assert_subagent_deny_gitdir "--config-env= inline blocked" "git --config-env=core.hooksPath=EVILVAR status"

echo "TC-127v: subagent git --config-env core.hooksPath=EV (inline, space form) → deny"
assert_subagent_deny_gitdir "--config-env space inline blocked" "git --config-env core.hooksPath=EVILVAR status"

# --attr-source consumes a following token (space form); it must not let the
# subcommand escape detection.
echo "TC-127w: subagent git --attr-source tree config core.hooksPath (space arg flag) → deny"
assert_subagent_deny_gitdir "--attr-source space + config write blocked" "git --attr-source tree config core.hooksPath /tmp/evil"

# Each separate-arg global flag independently pinned so a future skip_arg-list
# regression on any one of them is caught (they share the branch, but the branch
# is only exercised per-flag). --shallow-file was a real gap found in review.
echo "TC-127w2: subagent git --super-prefix x config core.hooksPath (space arg flag) → deny"
assert_subagent_deny_gitdir "--super-prefix space + config write blocked" "git --super-prefix x config core.hooksPath /tmp/evil"

echo "TC-127w3: subagent git --shallow-file /dev/null config core.hooksPath (space arg flag) → deny"
assert_subagent_deny_gitdir "--shallow-file space + config write blocked" "git --shallow-file /dev/null config core.hooksPath /tmp/evil"

echo "TC-127w4: subagent git --shallow-file /dev/null update-ref (space arg flag) → deny"
assert_subagent_deny_gitdir "--shallow-file space + update-ref blocked" "git --shallow-file /dev/null update-ref refs/heads/foo abc1234"

# --exec-path space form: covered by the removed (A)-(G) normalization, so (N)
# must deny it too (superset-of-develop, no regression) even though bare
# `git --exec-path` is a harmless print-and-exit (pinned as allow below).
echo "TC-127w5: subagent git --exec-path /x config core.hooksPath (space arg flag) → deny"
assert_subagent_deny_gitdir "--exec-path space + config write blocked" "git --exec-path /x config core.hooksPath /tmp/evil"

echo "TC-127-ALLOW-e5: subagent git --exec-path (bare, print-and-exit read) → allow"
assert_subagent_allow "git --exec-path bare allowed" "git --exec-path"

# Per-flag skip_arg regression pins: every separate-arg global flag must
# independently drop its value so a future skip_arg-list regression on any one of
# them is caught. --git-dir/--work-tree were only pinned in =form (TC-127i/l),
# which takes the -*) self-contained branch and does NOT exercise skip_arg;
# --namespace had no pin at all.
echo "TC-127w6: subagent git --namespace ns config core.hooksPath (space arg flag) → deny"
assert_subagent_deny_gitdir "--namespace space + config write blocked" "git --namespace ns config core.hooksPath /tmp/evil"

echo "TC-127w7: subagent git --git-dir ./.git config core.hooksPath (space arg flag) → deny"
assert_subagent_deny_gitdir "--git-dir space + config write blocked" "git --git-dir ./.git config core.hooksPath /tmp/evil"

echo "TC-127w8: subagent git --work-tree /tmp config core.hooksPath (space arg flag) → deny"
assert_subagent_deny_gitdir "--work-tree space + config write blocked" "git --work-tree /tmp config core.hooksPath /tmp/evil"

# Co-located read-form must NOT mask a real write in the same command line, and a
# second git invocation in a compound command must be re-recognized. These were a
# CRITICAL regression (a flattened whole-string match exempted the whole line).
echo "TC-127y1: subagent compound read;write — read must NOT mask the write → deny"
assert_subagent_deny_gitdir "co-located read does not mask write blocked" "git config --list; git config core.hooksPath /tmp/evil"

echo "TC-127y2: subagent write&&read (write first) → deny"
assert_subagent_deny_gitdir "write then read blocked" "git config core.hooksPath /tmp/evil && git config --list"

echo "TC-127y3: subagent compound read; alias write → deny"
assert_subagent_deny_gitdir "co-located read does not mask alias write blocked" "git config --list; git config alias.x '!sh -c evil'"

echo "TC-127y4: subagent second path-git invocation in compound → deny"
assert_subagent_deny_gitdir "compound second /usr/bin/git config blocked" "git; /usr/bin/git config core.hooksPath /tmp/evil"

echo "TC-127y5: subagent git remote (no sub-action); git config write → deny"
assert_subagent_deny_gitdir "compound after bare remote blocked" "git remote; git config core.hooksPath /tmp/evil"

echo "TC-127-ALLOW-y6: subagent two co-located reads (config --list; log) → allow"
assert_subagent_allow "co-located reads allowed" "git config --list; git log --oneline"

# remarg is fail-CLOSED symmetric with cfgarg: an unknown/future remote sub-action
# denies (not allow-by-default), so remote mutation is not a version-dependent
# enumeration hole. Read sub-actions stay allowed.
echo "TC-127y6: subagent git remote <unknown-sub-action> → deny (fail-closed)"
assert_subagent_deny_gitdir "unknown remote sub-action blocked" "git remote frobnicate x"

echo "TC-127-ALLOW-y7: subagent git remote show / get-url (read sub-actions) → allow"
assert_subagent_allow "git remote show allowed" "git remote show origin"
assert_subagent_allow "git remote get-url allowed" "git remote get-url origin"

# A verbose flag before a mutating sub-action must NOT be mistaken for a read:
# `git remote -v add …` still mutates (.git/config remote.<n>.url → RCE on fetch).
echo "TC-127y7: subagent git remote -v add (verbose flag before mutating sub-action) → deny"
assert_subagent_deny_gitdir "git remote -v add blocked" "git remote -v add evil https://evil.example/x"

echo "TC-127y8: subagent git remote --verbose set-url (verbose flag before mutating) → deny"
assert_subagent_deny_gitdir "git remote --verbose set-url blocked" "git remote --verbose set-url origin https://evil.example/x"

# Pin the remarg re-entry arm (bare `git remote` → fresh `git`): a legit read
# compound must stay allowed, so removing the `git|*/git` re-entry arm fails here.
echo "TC-127-ALLOW-y8: subagent git remote; git log (bare remote then fresh read) → allow"
assert_subagent_allow "bare remote then fresh read allowed" "git remote; git log --oneline"

# Accepted over-DENY (documented tradeoff, like TC-127x): a read pipe after
# `git remote -v` tokenizes as `-v grep` (separators collapse upstream) and
# denies fail-closed. Pinned so a maintainer sees it is intentional — re-allowing
# an unknown token after a flag would reopen the `git remote -v add` bypass.
echo "TC-127y9: subagent git remote -v | grep (read pipe over-DENY — accepted tradeoff) → deny"
assert_subagent_deny_gitdir "remote -v pipe over-deny accepted" "git remote -v | grep origin"

echo "TC-127-ALLOW-a: subagent git config --list (read) → allow"
assert_subagent_allow "git config --list allowed" "git config --list"

echo "TC-127-ALLOW-b: subagent git config --get (read) → allow"
assert_subagent_allow "git config --get allowed" "git config --get core.editor"

echo "TC-127-ALLOW-c: subagent git config --get-regexp (read) → allow"
assert_subagent_allow "git config --get-regexp allowed" "git config --get-regexp '^alias'"

echo "TC-127-ALLOW-d: subagent git remote -v (read) → allow"
assert_subagent_allow "git remote -v allowed" "git remote -v"

# NOTE: `git symbolic-ref HEAD` (a READ) is over-blocked by (N) — symbolic-ref
# has no read allow-list carve-out (unlike `git config`). That over-block is
# pre-existing (the removed (A) block also denied `symbolic-ref`) and accepted
# (recoverable via the deny message); the read alternative (rev-parse) is what
# stays allowed. Do NOT add a symbolic-ref read carve-out — that would change
# pre-existing behavior. TC-127x below pins the accepted read-side over-block.
echo "TC-127x: subagent git symbolic-ref HEAD (READ, over-blocked — accepted tradeoff) → deny"
assert_subagent_deny_gitdir "git symbolic-ref read over-blocked (accepted)" "git symbolic-ref HEAD"

echo "TC-127-ALLOW-e: subagent git rev-parse --symbolic-full-name (symbolic-ref read alternative) → allow"
assert_subagent_allow "git rev-parse --symbolic-full-name read allowed" "git rev-parse --symbolic-full-name HEAD"

echo "TC-127-ALLOW-e2: subagent git -C . config --list (flag prefix + read) → allow (normalization keeps reads)"
assert_subagent_allow "git -C . config --list allowed" "git -C . config --list"

echo "TC-127-ALLOW-e3: subagent git -C . status (flag prefix, non-dangerous subcommand) → allow"
assert_subagent_allow "git -C . status allowed" "git -C . status"

echo "TC-127-ALLOW-e4: subagent /usr/bin/git status (abspath invocation, non-dangerous) → allow (normalization keeps reads)"
assert_subagent_allow "/usr/bin/git status allowed" "/usr/bin/git status"

echo "TC-127-ALLOW-f: MAIN session git config core.hooksPath → allow (reviewer-only gate)"
assert_main_allow "main-session git config write not blocked by (N)" "git config core.hooksPath /tmp/x"
echo ""

# --------------------------------------------------------------------------
# Pattern 5: Merge-point review-result positive gate (Issue #2159)
# --------------------------------------------------------------------------
# Isolates state via RITE_STATE_ROOT so real repo review-results never leak in.
# Sole-reviewer guard floor = 2 (same constant as pr-review sole-reviewer guard).

_mrg_setup_state() {
  # $1 = temp root; creates sessions + review-results dirs and a session id file
  local root="$1"
  mkdir -p "$root/.rite/sessions" "$root/.rite/review-results"
  printf '%s\n' "mrg-gate-sess" > "$root/.rite-session-id"
  cat > "$root/.rite/sessions/mrg-gate-sess.flow-state" <<'EOF'
{
  "schema_version": 1,
  "active": true,
  "phase": "merge",
  "issue_number": "2159",
  "branch": "feat/test",
  "pr_number": 0,
  "session_id": "mrg-gate-sess",
  "next_action": "",
  "error_count": 0,
  "updated_at": "2026-08-08T00:00:00Z"
}
EOF
}

_mrg_set_flow_pr() {
  local root="$1" pr="$2"
  jq --argjson pr "$pr" '.pr_number = $pr' \
    "$root/.rite/sessions/mrg-gate-sess.flow-state" > "$root/.rite/sessions/mrg-gate-sess.flow-state.tmp"
  mv "$root/.rite/sessions/mrg-gate-sess.flow-state.tmp" "$root/.rite/sessions/mrg-gate-sess.flow-state"
}

_mrg_write_json() {
  # $1=root $2=filename $3=body
  printf '%s\n' "$3" > "$1/.rite/review-results/$2"
}

_mrg_qualifying_json() {
  # qualifying: schema_version + verdict keys, reviewers length >= 2
  cat <<'EOF'
{"schema_version":"1.1.0","verdict":"mergeable","reviewers":["code-quality","security"]}
EOF
}

_mrg_run() {
  # run_guard under RITE_STATE_ROOT; prints stdout, returns hook rc
  local root="$1" cmd="$2"
  local rc=0 output
  output=$(RITE_STATE_ROOT="$root" jq -n --arg tn "Bash" --arg cmd "$cmd" \
    '{tool_name: $tn, tool_input: {command: $cmd}, cwd: "/tmp"}' \
    | RITE_STATE_ROOT="$root" bash "$HOOK" 2>"$STDERR_FILE") || rc=$?
  printf '%s' "$output"
  return $rc
}

echo "TC-128 / T-01: qualifying review JSON → gh pr merge N allowed (no extra stdout noise)"
_mrg_tmp=$(mktemp -d)
_mrg_setup_state "$_mrg_tmp"
_mrg_write_json "$_mrg_tmp" "99-good.json" "$(_mrg_qualifying_json)"
rc=0
output=$(_mrg_run "$_mrg_tmp" "gh pr merge 99 --squash") || rc=$?
if [ "$rc" = "0" ] && [ -z "$output" ]; then
  pass "TC-128 qualifying JSON allows gh pr merge 99 with empty stdout"
else
  fail "TC-128 expected allow (rc=0 empty stdout), got rc=$rc output=$output"
fi
rm -rf "$_mrg_tmp"
echo ""

echo "TC-129 / T-02: number-less gh pr merge resolves PR via flow-state"
_mrg_tmp=$(mktemp -d)
_mrg_setup_state "$_mrg_tmp"
_mrg_set_flow_pr "$_mrg_tmp" 77
_mrg_write_json "$_mrg_tmp" "77-good.json" "$(_mrg_qualifying_json)"
rc=0
output=$(_mrg_run "$_mrg_tmp" "gh pr merge --squash") || rc=$?
if [ "$rc" = "0" ] && [ -z "$output" ]; then
  pass "TC-129 flow-state pr_number=77 allows number-less gh pr merge"
else
  fail "TC-129 expected allow via flow-state, got rc=$rc output=$output"
fi
rm -rf "$_mrg_tmp"
echo ""

echo "TC-130 / T-03: no review JSON → deny + /rite:pr-review guidance"
_mrg_tmp=$(mktemp -d)
_mrg_setup_state "$_mrg_tmp"
rc=0
output=$(_mrg_run "$_mrg_tmp" "gh pr merge 55 --squash") || rc=$?
decision=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
reason=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)
if [ "$decision" = "deny" ] && [[ "$reason" == *"merge-review-json-absent"* ]] && [[ "$reason" == *"/rite:pr-review"* ]]; then
  pass "TC-130 absent JSON denies with merge-review-json-absent and /rite:pr-review"
else
  fail "TC-130 expected deny absent+/rite:pr-review, got decision=$decision reason=$reason"
fi
rm -rf "$_mrg_tmp"
echo ""

echo "TC-131 / T-04: sole-reviewer (reviewers length 1) JSON → deny"
_mrg_tmp=$(mktemp -d)
_mrg_setup_state "$_mrg_tmp"
_mrg_write_json "$_mrg_tmp" "56-sole.json" \
  '{"schema_version":1,"verdict":"mergeable","reviewers":["code-quality"]}'
rc=0
output=$(_mrg_run "$_mrg_tmp" "gh pr merge 56") || rc=$?
decision=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
reason=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)
if [ "$decision" = "deny" ] && [[ "$reason" == *"merge-review-sole-reviewer"* ]]; then
  pass "TC-131 sole-reviewer JSON denies with merge-review-sole-reviewer"
else
  fail "TC-131 expected sole-reviewer deny, got decision=$decision reason=$reason"
fi
rm -rf "$_mrg_tmp"
echo ""

echo "TC-132 / T-05: unparseable review JSON → deny"
_mrg_tmp=$(mktemp -d)
_mrg_setup_state "$_mrg_tmp"
_mrg_write_json "$_mrg_tmp" "57-broken.json" '{not valid json'
rc=0
output=$(_mrg_run "$_mrg_tmp" "gh pr merge 57") || rc=$?
decision=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
reason=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)
if [ "$decision" = "deny" ] && [[ "$reason" == *"merge-review-json-parse"* ]]; then
  pass "TC-132 broken JSON denies with merge-review-json-parse"
else
  fail "TC-132 expected parse deny, got decision=$decision reason=$reason"
fi
rm -rf "$_mrg_tmp"
echo ""

echo "TC-133 / T-06: PR number unresolvable → deny (no arg, flow-state pr_number=0)"
_mrg_tmp=$(mktemp -d)
_mrg_setup_state "$_mrg_tmp"   # pr_number stays 0
rc=0
output=$(_mrg_run "$_mrg_tmp" "gh pr merge --squash") || rc=$?
decision=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
reason=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)
if [ "$decision" = "deny" ] && [[ "$reason" == *"merge-review-pr-unresolved"* ]]; then
  pass "TC-133 unresolvable PR number denies with merge-review-pr-unresolved"
else
  fail "TC-133 expected pr-unresolved deny, got decision=$decision reason=$reason"
fi
rm -rf "$_mrg_tmp"
echo ""

echo "TC-134 / T-07: non-merge gh commands still allowed (no regression on Pattern 5)"
_mrg_tmp=$(mktemp -d)
_mrg_setup_state "$_mrg_tmp"
# No qualifying JSON present — if Pattern 5 false-fired these would deny.
rc=0
output=$(_mrg_run "$_mrg_tmp" "gh pr view 1 --json title") || rc=$?
if [ "$rc" = "0" ] && [ -z "$output" ]; then
  pass "TC-134 gh pr view allowed (Pattern 5 does not false-positive)"
else
  fail "TC-134 expected allow for gh pr view, got rc=$rc output=$output"
fi
rc=0
output=$(_mrg_run "$_mrg_tmp" "gh pr diff 1") || rc=$?
if [ "$rc" = "0" ] && [ -z "$output" ]; then
  pass "TC-134 gh pr diff allowed (Pattern 5 does not false-positive)"
else
  fail "TC-134 expected allow for gh pr diff, got rc=$rc output=$output"
fi
rc=0
output=$(_mrg_run "$_mrg_tmp" "gh api repos/o/r/pulls/1") || rc=$?
if [ "$rc" = "0" ] && [ -z "$output" ]; then
  pass "TC-134 gh api non-merge REST allowed"
else
  fail "TC-134 expected allow for non-merge gh api, got rc=$rc output=$output"
fi
# REST merge endpoint is detected and denied when JSON absent
rc=0
output=$(_mrg_run "$_mrg_tmp" "gh api repos/o/r/pulls/88/merge -X PUT") || rc=$?
decision=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
if [ "$decision" = "deny" ]; then
  pass "TC-134 REST pulls/88/merge is detected and denied without JSON"
else
  fail "TC-134 expected deny for REST merge, got decision=$decision output=$output"
fi
# GraphQL mergePullRequest detected
rc=0
output=$(_mrg_run "$_mrg_tmp" "gh api graphql -f query='mutation { mergePullRequest(input:{pullRequestId:\"X\"}) { clientMutationId } }'") || rc=$?
decision=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
# GraphQL has no PR number in path → pr-unresolved (or absent if number extracted)
if [ "$decision" = "deny" ]; then
  pass "TC-134 GraphQL mergePullRequest is detected and denied"
else
  fail "TC-134 expected deny for mergePullRequest, got decision=$decision output=$output"
fi
# Existing Pattern 1 still denies
rc=0
output=$(_mrg_run "$_mrg_tmp" "gh pr diff 1 --stat") || rc=$?
decision=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
reason=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)
if [ "$decision" = "deny" ] && [[ "$reason" == *"gh-pr-diff-stat"* ]]; then
  pass "TC-134 Pattern 1 (gh pr diff --stat) still denies (non-regression)"
else
  fail "TC-134 expected Pattern 1 deny, got decision=$decision reason=$reason"
fi
rm -rf "$_mrg_tmp"
echo ""

echo "TC-135: missing required keys (no reviewers) → deny incomplete"
_mrg_tmp=$(mktemp -d)
_mrg_setup_state "$_mrg_tmp"
_mrg_write_json "$_mrg_tmp" "60-incomplete.json" \
  '{"schema_version":"1.0.0","verdict":"mergeable"}'
rc=0
output=$(_mrg_run "$_mrg_tmp" "gh pr merge 60") || rc=$?
decision=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
reason=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)
if [ "$decision" = "deny" ] && [[ "$reason" == *"merge-review-json-incomplete"* ]]; then
  pass "TC-135 incomplete keys deny with merge-review-json-incomplete"
else
  fail "TC-135 expected incomplete deny, got decision=$decision reason=$reason"
fi
rm -rf "$_mrg_tmp"
echo ""

echo "TC-136: one qualifying + one broken JSON for same PR → allow (any-pass)"
_mrg_tmp=$(mktemp -d)
_mrg_setup_state "$_mrg_tmp"
_mrg_write_json "$_mrg_tmp" "61-broken.json" '{broken'
_mrg_write_json "$_mrg_tmp" "61-good.json" "$(_mrg_qualifying_json)"
rc=0
output=$(_mrg_run "$_mrg_tmp" "gh pr merge 61") || rc=$?
if [ "$rc" = "0" ] && [ -z "$output" ]; then
  pass "TC-136 any qualifying JSON allows merge even if a sibling file is broken"
else
  fail "TC-136 expected allow when one file qualifies, got rc=$rc output=$output"
fi
rm -rf "$_mrg_tmp"
echo ""

echo "TC-137: path-prefixed /usr/bin/gh pr merge is detected (no absolute-path bypass)"
_mrg_tmp=$(mktemp -d)
_mrg_setup_state "$_mrg_tmp"
rc=0
output=$(_mrg_run "$_mrg_tmp" "/usr/bin/gh pr merge 99 --squash") || rc=$?
decision=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
reason=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)
if [ "$decision" = "deny" ] && [[ "$reason" == *"merge-review-json-absent"* ]]; then
  pass "TC-137 /usr/bin/gh pr merge denies (path-prefixed binary is not a bypass)"
else
  fail "TC-137 expected deny for /usr/bin/gh pr merge, got decision=$decision reason=$reason"
fi
# hyphen-prefixed path also (Homebrew-style multi-component)
rc=0
output=$(_mrg_run "$_mrg_tmp" "/opt/homebrew/bin/gh pr merge 99") || rc=$?
decision=$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
if [ "$decision" = "deny" ]; then
  pass "TC-137 /opt/homebrew/bin/gh pr merge denies"
else
  fail "TC-137 expected deny for homebrew gh path, got decision=$decision"
fi
rm -rf "$_mrg_tmp"
echo ""

# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
