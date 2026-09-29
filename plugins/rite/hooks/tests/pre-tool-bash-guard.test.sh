#!/bin/bash
# Tests for pre-tool-bash-guard.sh (PreToolUse hook)
# Usage: bash plugins/rite/hooks/tests/pre-tool-bash-guard.test.sh
set -euo pipefail

# _timeout <seconds> <command...> — portable timeout(1) for this test.
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
# shellcheck source=_hermetic-env.sh
source "$SCRIPT_DIR/_hermetic-env.sh" || { echo "ERROR: cannot source _hermetic-env.sh" >&2; exit 1; }
hermetic_leave_checkout || exit 1
HOOK="$SCRIPT_DIR/../pre-tool-bash-guard.sh"
PASS=0
FAIL=0
STDERR_FILE=$(mktemp)

cleanup() {
  rm -f "$STDERR_FILE"
  rm -rf "$HERMETIC_CWD"
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

# Hook stdout が壊れていても、個別 assertion を FAIL として記録して残りの
# suite を継続する。bare command substitution は set -e によりファイル全体を
# abort させ、どのケースで JSON が壊れたかという一次診断まで失わせる。
extract_hook_field() {
  local hook_output="$1"
  local field="$2"
  local jq_bin="${3:-jq}"
  local parsed=""
  local jq_rc=0
  case "$field" in hookEventName|permissionDecision|permissionDecisionReason) ;; *) return 2 ;; esac
  if parsed=$(printf '%s' "$hook_output" \
    | "$jq_bin" -r --arg field "$field" '.hookSpecificOutput[$field] // empty' 2>/dev/null); then
    printf '%s' "$parsed"
    return 0
  else
    jq_rc=$?
  fi
  printf '  jq hook field extraction failed (field=%s, rc=%s, output_bytes=%s)\n' \
    "$field" "$jq_rc" "$(printf '%s' "$hook_output" | wc -c | tr -d ' ')" >&2
  return 0
}

echo "TC-000: malformed hook stdout does not abort decision extraction"
tc000_after=false
decision=$(extract_hook_field 'not-json' permissionDecision)
reason=$(extract_hook_field 'not-json' permissionDecisionReason)
event=$(extract_hook_field 'not-json' hookEventName)
tc000_after=true
if [ -z "$decision" ] && [ -z "$reason" ] && [ -z "$event" ] && [ "$tc000_after" = true ]; then
  pass "TC-000 malformed JSON fields degrade to empty and suite continues"
else
  fail "TC-000 malformed JSON extraction did not preserve continuation"
fi
echo ""

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
decision=$(extract_hook_field "$output" permissionDecision)
reason=$(extract_hook_field "$output" permissionDecisionReason)
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
decision=$(extract_hook_field "$output" permissionDecision)
reason=$(extract_hook_field "$output" permissionDecisionReason)
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
decision=$(extract_hook_field "$output" permissionDecision)
reason=$(extract_hook_field "$output" permissionDecisionReason)
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
HAS_EVENT=$(extract_hook_field "$output" hookEventName)
HAS_DECISION=$(extract_hook_field "$output" permissionDecision)
HAS_REASON=$(extract_hook_field "$output" permissionDecisionReason)
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
decision=$(extract_hook_field "$output" permissionDecision)
reason=$(extract_hook_field "$output" permissionDecisionReason)
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
  decision=$(extract_hook_field "$output" permissionDecision)
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
decision=$(extract_hook_field "$output" permissionDecision)
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
decision=$(extract_hook_field "$output" permissionDecision)
reason=$(extract_hook_field "$output" permissionDecisionReason)
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
decision=$(extract_hook_field "$output" permissionDecision)
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
# Why: the working-tree verb denylist (git checkout / reset / commit /
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
# TC-201: verb-denylist removal — working-tree git verbs are NOT machine-gated.
# These commands were denied by the removed sub-blocks (A)-(G); they must pass
# the hook untouched. The READ-ONLY guarantee for them is the reviewer prompt
# (Layer 1) + post-review-state-verify (Layer 3), NOT this hook — this loop pins
# the hook's non-involvement so neither a future edit nor sub-block (S), whose
# closed set is git commit / git push / GitHub writes / flow-state writes / step drivers, can
# silently re-grow the verb denylist.
# --------------------------------------------------------------------------
echo "TC-201: subagent mutating git verbs → allow (Layer 1/3 territory, not machine-gated)"
for verb_cmd in \
  "git checkout develop" \
  "git checkout develop -- file.md" \
  "git checkout -b pr-123-test" \
  "git reset --hard HEAD" \
  "git add ." \
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
# pinned in TC-127 below. They were never working-tree verbs (removed
# working-tree verbs; .git-write is the retained gate). git commit / git push are
# not in it either: sub-block (S) denies them for reviewers (TC-203).
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
# TC-203: past false-positive commands → allow (AC-4)
# Commands that historically required bypass/false-positive patches against the
# removed verb denylist (quote-boundary echoes, grep pattern args, branch names
# embedding flag substrings, worktree-add arg-loop noglob). With the verb
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
# worktree-add arg with a bare glob from a CWD holding a `-b` file (
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
# verb 列挙撤去に伴い reviewer-shell-wrapper へ改名。
# --------------------------------------------------------------------------

# Helper: subagent deny かつ reason に wrapper guidance が含まれることを確認
assert_subagent_deny_wrapper_guidance() {
  local label="$1"
  local cmd="$2"
  local rc=0
  local output
  output=$(run_guard_with_transcript "Bash" "$cmd" "$SUBAGENT_TRANSCRIPT") || rc=$?
  local decision reason
  decision=$(extract_hook_field "$output" permissionDecision)
  reason=$(extract_hook_field "$output" permissionDecisionReason)
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
# 列挙撤去に伴い .git write (H) に変更。
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
decision=$(extract_hook_field "$output" permissionDecision)
reason=$(extract_hook_field "$output" permissionDecisionReason)
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
decision=$(extract_hook_field "$output" permissionDecision)
reason=$(extract_hook_field "$output" permissionDecisionReason)
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
decision=$(extract_hook_field "$output" permissionDecision)
reason=$(extract_hook_field "$output" permissionDecisionReason)
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
decision=$(extract_hook_field "$output" permissionDecision)
reason=$(extract_hook_field "$output" permissionDecisionReason)
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
decision=$(extract_hook_field "$output" permissionDecision "$real_jq")
reason=$(extract_hook_field "$output" permissionDecisionReason "$real_jq")
if [ "$decision" = "deny" ] && [[ "$reason" == *"gh-pr-diff-stat"* ]]; then
  pass "TC-116 deny decision and pattern name survive the fallback"
else
  fail "TC-116 expected deny with gh-pr-diff-stat via fallback, got decision=$decision reason=$reason"
fi
# raw C0 バイト (ESC 等) の非漏出 — neutralize_ctrl --c0-only の挙動 pin
if LC_ALL=C grep -q $'\x1b' <<< "$output"; then
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
decision=$(extract_hook_field "$output" permissionDecision "$real_jq")
reason=$(extract_hook_field "$output" permissionDecisionReason "$real_jq")
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
# Why: Pattern 4 shared the fail-OPEN ERR trap with the convenience
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
decision=$(extract_hook_field "$output" permissionDecision)
reason=$(extract_hook_field "$output" permissionDecisionReason)
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
# be an allow-all backdoor to the security boundary (review F-02). So
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
# actual restore statement — not just its comment (review F-04).
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
# Pin the exact value (review F-03): the .sh header comment documents
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
# over the byte ceiling is denied fail-closed BEFORE the O(n²) Pattern 2 regex
# (>2min on a few MB), which would otherwise time out the fail-open hook and let a padded
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
decision=$(extract_hook_field "$output" permissionDecision)
reason=$(extract_hook_field "$output" permissionDecisionReason)
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
decision=$(extract_hook_field "$output" permissionDecision)
if [ "$decision" = "deny" ]; then
  pass "TC-124 oversized READ-ONLY reviewer command is denied (length guard, allow→deny flip)"
else
  fail "TC-124 expected deny for oversized read-only command, got decision=$decision rc=$rc"
fi
# (c) oversized because of a huge heredoc BODY, with a READ-ONLY prefix → deny.
# The length guard checks ${#COMMAND} over the WHOLE command (heredoc body included),
# so it fires here. Non-vacuous (review F-06): the prefix `git status` is
# read-only, so WITHOUT the length guard the heredoc strip yields `git status` and the
# command is ALLOWED — WITH it the command is denied. This case pins the length
# guard's use of the full command length.
{ printf 'git status <<EOF\n'; printf 'y%.0s' $(seq 1 200000); printf '\nEOF'; } > "$tc124_dir/hd.txt"
jq -n --rawfile cmd "$tc124_dir/hd.txt" --arg tp "$SUBAGENT_TRANSCRIPT" \
  '{tool_name: "Bash", tool_input: {command: $cmd}, cwd: "/tmp", transcript_path: $tp}' > "$tc124_dir/hdin.json"
rc=0
output=$(_timeout 15 bash "$HOOK" < "$tc124_dir/hdin.json" 2>"$STDERR_FILE") || rc=$?
decision=$(extract_hook_field "$output" permissionDecision)
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
# TC-125: reviewer WRITE into a .git directory (AC-1, sub-block (H))
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
  decision=$(extract_hook_field "$output" permissionDecision)
  reason=$(extract_hook_field "$output" permissionDecisionReason)
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

# --- CRITICAL regression: repo under a `/git`-containing ancestor (fix) ---
# A removed `/git`→` git` invocation-normalization used to split these paths so `>` detached
# from the `.git` token → silent allow (RCE). The normalization is gone, but these
# pin that /git-ancestor paths keep tokenizing intact.
echo "TC-125l: subagent redirect into .git under a /srv/git ancestor → deny (path not corrupted)"
assert_subagent_deny_gitdir "redirect into /srv/git/.../.git blocked" "echo evil > /srv/git/proj/.git/config"

echo "TC-125m: subagent append into .git under a ~/github ancestor → deny (path not corrupted)"
assert_subagent_deny_gitdir "append into /home/u/github/.../.git blocked" "echo x >> /home/u/github/proj/.git/hooks/pre-commit"

# --- fileverb absolute-path / backslash invocation (fix) ---
echo "TC-125n: subagent absolute-path tee into .git → deny"
assert_subagent_deny_gitdir "/usr/bin/tee into .git blocked" "/usr/bin/tee .git/hooks/pre-commit"

echo "TC-125o: subagent backslash-escaped cp into .git → deny"
assert_subagent_deny_gitdir "\\cp into .git blocked" "\\cp /tmp/evil .git/hooks/pre-commit"

# --- dd of=<gitpath> write vector (fix) ---
echo "TC-125p: subagent dd of=.git/hooks → deny"
assert_subagent_deny_gitdir "dd of=.git blocked" "dd if=/tmp/evil of=.git/hooks/pre-commit"

# --- value-quoted dd of= (cycle-2 fix: quote-strip-after-of= ordering) ---
echo "TC-125q: subagent dd of='.git/…' (single-quoted value) → deny"
assert_subagent_deny_gitdir "dd of='.git' (single-quoted) blocked" "dd if=/tmp/evil of='.git/hooks/pre-commit'"

echo "TC-125r: subagent dd of=\".git/…\" (double-quoted value) → deny"
assert_subagent_deny_gitdir "dd of=\".git\" (double-quoted) blocked" "dd if=/tmp/evil of=\".git/hooks/pre-commit\""

# --- interior / nested quotes (cycle-3 fix: global quote removal) ---
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

# --- backslash-escaped .git path components (cycle-4 fix: backslash removal) ---
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

# --- obfuscated file-verb NAME (cycle-5 fix: dequote the verb token too) ---
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

# --- additional positional file-writers (cycle-5: sponge/patch, tee twins) ---
echo "TC-125y1: subagent sponge into .git/hooks → deny"
assert_subagent_deny_gitdir "sponge .git/hooks blocked" "echo pwned | sponge .git/hooks/pre-commit"

echo "TC-125y2: subagent patch into .git/config → deny"
assert_subagent_deny_gitdir "patch .git/config blocked" "patch .git/config"

echo "TC-125y3: subagent quoted verb 'sponge' into .git → deny (verb dequote)"
assert_subagent_deny_gitdir "'sponge' .git blocked" "echo x | 'sponge' .git/hooks/pre-commit"

# --- file-verb blocklist completeness: install / rsync / truncate are IN the case list
# (tee|cp|mv|ln|install|rsync|truncate|dd|sponge|patch) but lacked dedicated deny tests; pin them so
# a future edit that drops one literal from the case is caught (follow-up). ---
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
# (`*`/`?`/`[`) is NOT pathname-expanded against the hook CWD (follow-up). Without noglob
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
# TC-127: reviewer native.git-writing git subcommands (sub-block (N))
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
# Pattern 5: Merge-point review-result positive gate
# --------------------------------------------------------------------------
# Isolates state via RITE_STATE_ROOT so real repo review-results never leak in.
# Sole-reviewer guard floor = 2 (same constant as pr-review sole-reviewer guard; acceptance-reviewer is not counted).

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
  # run_guard under RITE_STATE_ROOT; prints stdout, returns hook rc.
  # A host runtime session outranks the fixture .rite-session-id. These cases
  # read pr_number from that fixture, so they drop the host session first.
  local root="$1" cmd="$2"
  local rc=0 output
  output=$(RITE_STATE_ROOT="$root" jq -n --arg tn "Bash" --arg cmd "$cmd" \
    '{tool_name: $tn, tool_input: {command: $cmd}, cwd: "/tmp"}' \
    | env -u GROK_SESSION_ID -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID \
        -u CODEX_THREAD_ID -u RITE_HOST \
        RITE_STATE_ROOT="$root" bash "$HOOK" 2>"$STDERR_FILE") || rc=$?
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
decision=$(extract_hook_field "$output" permissionDecision)
reason=$(extract_hook_field "$output" permissionDecisionReason)
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
decision=$(extract_hook_field "$output" permissionDecision)
reason=$(extract_hook_field "$output" permissionDecisionReason)
if [ "$decision" = "deny" ] && [[ "$reason" == *"merge-review-sole-reviewer"* ]]; then
  pass "TC-131 sole-reviewer JSON denies with merge-review-sole-reviewer"
else
  fail "TC-131 expected sole-reviewer deny, got decision=$decision reason=$reason"
fi
rm -rf "$_mrg_tmp"
echo ""

echo "TC-131b: code-quality-reviewer + acceptance-reviewer JSON → deny (acceptance-reviewer is not counted)"
_mrg_tmp=$(mktemp -d)
_mrg_setup_state "$_mrg_tmp"
_mrg_write_json "$_mrg_tmp" "56-sole-acceptance.json" \
  '{"schema_version":1,"verdict":"mergeable","reviewers":["code-quality-reviewer","acceptance-reviewer"]}'
rc=0
output=$(_mrg_run "$_mrg_tmp" "gh pr merge 56 --squash") || rc=$?
decision=$(extract_hook_field "$output" permissionDecision)
reason=$(extract_hook_field "$output" permissionDecisionReason)
if [ "$decision" = "deny" ] && [[ "$reason" == *"merge-review-sole-reviewer"* ]] \
  && [[ "$reason" == *"at least 2 reviewers other than acceptance-reviewer are recorded"* ]]; then
  pass "TC-131b acceptance-reviewer does not satisfy the sole-reviewer floor"
else
  fail "TC-131b expected sole-reviewer deny, got decision=$decision reason=$reason"
fi
rm -rf "$_mrg_tmp"
echo ""

echo "TC-132 / T-05: unparseable review JSON → deny"
_mrg_tmp=$(mktemp -d)
_mrg_setup_state "$_mrg_tmp"
_mrg_write_json "$_mrg_tmp" "57-broken.json" '{not valid json'
rc=0
output=$(_mrg_run "$_mrg_tmp" "gh pr merge 57") || rc=$?
decision=$(extract_hook_field "$output" permissionDecision)
reason=$(extract_hook_field "$output" permissionDecisionReason)
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
decision=$(extract_hook_field "$output" permissionDecision)
reason=$(extract_hook_field "$output" permissionDecisionReason)
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
decision=$(extract_hook_field "$output" permissionDecision)
if [ "$decision" = "deny" ]; then
  pass "TC-134 REST pulls/88/merge is detected and denied without JSON"
else
  fail "TC-134 expected deny for REST merge, got decision=$decision output=$output"
fi
# GraphQL mergePullRequest detected
rc=0
output=$(_mrg_run "$_mrg_tmp" "gh api graphql -f query='mutation { mergePullRequest(input:{pullRequestId:\"X\"}) { clientMutationId } }'") || rc=$?
decision=$(extract_hook_field "$output" permissionDecision)
# GraphQL has no PR number in path → pr-unresolved (or absent if number extracted)
if [ "$decision" = "deny" ]; then
  pass "TC-134 GraphQL mergePullRequest is detected and denied"
else
  fail "TC-134 expected deny for mergePullRequest, got decision=$decision output=$output"
fi
# Existing Pattern 1 still denies
rc=0
output=$(_mrg_run "$_mrg_tmp" "gh pr diff 1 --stat") || rc=$?
decision=$(extract_hook_field "$output" permissionDecision)
reason=$(extract_hook_field "$output" permissionDecisionReason)
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
decision=$(extract_hook_field "$output" permissionDecision)
reason=$(extract_hook_field "$output" permissionDecisionReason)
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
decision=$(extract_hook_field "$output" permissionDecision)
reason=$(extract_hook_field "$output" permissionDecisionReason)
if [ "$decision" = "deny" ] && [[ "$reason" == *"merge-review-json-absent"* ]]; then
  pass "TC-137 /usr/bin/gh pr merge denies (path-prefixed binary is not a bypass)"
else
  fail "TC-137 expected deny for /usr/bin/gh pr merge, got decision=$decision reason=$reason"
fi
# hyphen-prefixed path also (Homebrew-style multi-component)
rc=0
output=$(_mrg_run "$_mrg_tmp" "/opt/homebrew/bin/gh pr merge 99") || rc=$?
decision=$(extract_hook_field "$output" permissionDecision)
if [ "$decision" = "deny" ]; then
  pass "TC-137 /opt/homebrew/bin/gh pr merge denies"
else
  fail "TC-137 expected deny for homebrew gh path, got decision=$decision"
fi
rm -rf "$_mrg_tmp"
echo ""

# --------------------------------------------------------------------------
# Why: variable-form PR token must not fall back to flow-state
# --------------------------------------------------------------------------

echo "TC-138 / T-01: variable-form \"\$PR\" denies even when flow-state has qualifying other PR"
_mrg_tmp=$(mktemp -d)
_mrg_setup_state "$_mrg_tmp"
_mrg_set_flow_pr "$_mrg_tmp" 77
_mrg_write_json "$_mrg_tmp" "77-good.json" "$(_mrg_qualifying_json)"
rc=0
# Quoted variable form as it appears in tool_input.command after shell expansion
# has NOT happened (hook sees the literal command string from the tool call).
output=$(_mrg_run "$_mrg_tmp" 'gh pr merge "$PR" --squash') || rc=$?
decision=$(extract_hook_field "$output" permissionDecision)
reason=$(extract_hook_field "$output" permissionDecisionReason)
if [ "$decision" = "deny" ] && [[ "$reason" == *"merge-review-pr-unresolved"* ]] && [[ "$reason" == *"gh pr merge"* || "$reason" == *"bare integer"* || "$reason" == *"explicitly"* ]]; then
  pass "TC-138 variable-form \"\$PR\" denies with merge-review-pr-unresolved (no flow-state 77 pass-through)"
else
  fail "TC-138 expected pr-unresolved deny (not allow via flow-state 77), got decision=$decision reason=$reason rc=$rc"
fi
# Unquoted $PR form
rc=0
output=$(_mrg_run "$_mrg_tmp" 'gh pr merge $PR --squash') || rc=$?
decision=$(extract_hook_field "$output" permissionDecision)
reason=$(extract_hook_field "$output" permissionDecisionReason)
if [ "$decision" = "deny" ] && [[ "$reason" == *"merge-review-pr-unresolved"* ]]; then
  pass "TC-138 unquoted \$PR also denies with merge-review-pr-unresolved"
else
  fail "TC-138 expected pr-unresolved for unquoted \$PR, got decision=$decision reason=$reason"
fi
rm -rf "$_mrg_tmp"
echo ""

echo "TC-139 / T-02: literal numeric form still allowed (non-regression of TC-128 path)"
_mrg_tmp=$(mktemp -d)
_mrg_setup_state "$_mrg_tmp"
_mrg_write_json "$_mrg_tmp" "99-good.json" "$(_mrg_qualifying_json)"
rc=0
output=$(_mrg_run "$_mrg_tmp" "gh pr merge 99 --squash") || rc=$?
if [ "$rc" = "0" ] && [ -z "$output" ]; then
  pass "TC-139 literal gh pr merge 99 still allows with qualifying JSON"
else
  fail "TC-139 expected allow for literal 99, got rc=$rc output=$output"
fi
# Number after flags
rc=0
output=$(_mrg_run "$_mrg_tmp" "gh pr merge --squash 99") || rc=$?
if [ "$rc" = "0" ] && [ -z "$output" ]; then
  pass "TC-139 literal after flags (gh pr merge --squash 99) still allows"
else
  fail "TC-139 expected allow for --squash 99, got rc=$rc output=$output"
fi
rm -rf "$_mrg_tmp"
echo ""

echo "TC-140 / T-03: flag-only tail still uses flow-state fallback (pin limited retention)"
_mrg_tmp=$(mktemp -d)
_mrg_setup_state "$_mrg_tmp"
_mrg_set_flow_pr "$_mrg_tmp" 77
_mrg_write_json "$_mrg_tmp" "77-good.json" "$(_mrg_qualifying_json)"
rc=0
output=$(_mrg_run "$_mrg_tmp" "gh pr merge --squash") || rc=$?
if [ "$rc" = "0" ] && [ -z "$output" ]; then
  pass "TC-140 flag-only gh pr merge --squash still resolves via flow-state"
else
  fail "TC-140 expected allow via flow-state for flag-only tail, got rc=$rc output=$output"
fi
# Multiple flags only
rc=0
output=$(_mrg_run "$_mrg_tmp" "gh pr merge --squash --delete-branch") || rc=$?
if [ "$rc" = "0" ] && [ -z "$output" ]; then
  pass "TC-140 multi-flag-only tail still uses flow-state"
else
  fail "TC-140 expected allow for --squash --delete-branch via flow-state, got rc=$rc output=$output"
fi
rm -rf "$_mrg_tmp"
echo ""

echo "TC-140a / T-04: verified develop -> main promotion with pinned head is allowed"
_mrg_tmp=$(mktemp -d)
_mrg_setup_state "$_mrg_tmp"
mkdir -p "$_mrg_tmp/.rite/release-promotions"
_promotion_oid="0123456789abcdef0123456789abcdef01234567"
jq -n --arg oid "$_promotion_oid" \
  '{schema_version:"1.0.0",pr_number:88,base:"main",head:"develop",head_oid:$oid,commits:[$oid],verified_at:"2026-08-12T00:00:00Z"}' \
  > "$_mrg_tmp/.rite/release-promotions/88.json"
rc=0
output=$(_mrg_run "$_mrg_tmp" "gh pr merge 88 --merge --match-head-commit $_promotion_oid") || rc=$?
if [ "$rc" = "0" ] && [ -z "$output" ]; then
  pass "TC-140a verified promotion allows merge with exact head pin"
else
  fail "TC-140a expected verified promotion allow, got rc=$rc output=$output"
fi
rm -rf "$_mrg_tmp"
echo ""

echo "TC-140b / T-05: stale or unpinned promotion attestation denies fail-loud"
_mrg_tmp=$(mktemp -d)
_mrg_setup_state "$_mrg_tmp"
mkdir -p "$_mrg_tmp/.rite/release-promotions"
_promotion_oid="0123456789abcdef0123456789abcdef01234567"
_stale_oid="fedcba9876543210fedcba9876543210fedcba98"
jq -n --arg oid "$_promotion_oid" \
  '{schema_version:"1.0.0",pr_number:89,base:"main",head:"develop",head_oid:$oid,commits:[$oid],verified_at:"2026-08-12T00:00:00Z"}' \
  > "$_mrg_tmp/.rite/release-promotions/89.json"
rc=0
output=$(_mrg_run "$_mrg_tmp" "gh pr merge 89 --merge --match-head-commit $_stale_oid") || rc=$?
decision=$(extract_hook_field "$output" permissionDecision)
reason=$(extract_hook_field "$output" permissionDecisionReason)
if [ "$decision" = "deny" ] && [[ "$reason" == *"merge-release-promotion-unverified"* ]]; then
  pass "TC-140b stale promotion head denies with distinct failure class"
else
  fail "TC-140b expected promotion-unverified deny, got decision=$decision reason=$reason"
fi
rm -rf "$_mrg_tmp"
echo ""

echo "TC-140c / T-06: pin in a later shell command cannot authenticate the merge"
_mrg_tmp=$(mktemp -d)
_mrg_setup_state "$_mrg_tmp"
mkdir -p "$_mrg_tmp/.rite/release-promotions"
_promotion_oid="0123456789abcdef0123456789abcdef01234567"
jq -n --arg oid "$_promotion_oid" \
  '{schema_version:"1.0.0",pr_number:91,base:"main",head:"develop",head_oid:$oid,commits:[$oid],verified_at:"2026-08-12T00:00:00Z"}' \
  > "$_mrg_tmp/.rite/release-promotions/91.json"
rc=0
output=$(_mrg_run "$_mrg_tmp" "gh pr merge 91 --merge; echo --match-head-commit $_promotion_oid") || rc=$?
decision=$(extract_hook_field "$output" permissionDecision)
reason=$(extract_hook_field "$output" permissionDecisionReason)
if [ "$decision" = "deny" ] && [[ "$reason" == *"merge-release-promotion-unverified"* ]]; then
  pass "TC-140c unrelated later pin is rejected"
else
  fail "TC-140c expected promotion-unverified deny, got decision=$decision reason=$reason"
fi
rm -rf "$_mrg_tmp"
echo ""

# --------------------------------------------------------------------------
# Why: persist deny-only audit records
# --------------------------------------------------------------------------

echo "TC-141 / T-01: deny appends the stderr event to bash-guard.log"
_audit_tmp=$(mktemp -d)
rc=0
RITE_STATE_ROOT="$_audit_tmp" jq -n --arg cmd "gh pr diff 99 --stat" \
  '{tool_name:"Bash",tool_input:{command:$cmd}}' \
  | RITE_STATE_ROOT="$_audit_tmp" bash "$HOOK" >/dev/null 2>"$_audit_tmp/stderr" || rc=$?
if [ "$rc" = "0" ] \
  && [ -f "$_audit_tmp/.rite/logs/bash-guard.log" ] \
  && grep -q 'bash-guard: BLOCKED pattern=gh-pr-diff-stat' "$_audit_tmp/.rite/logs/bash-guard.log" \
  && cmp -s "$_audit_tmp/stderr" "$_audit_tmp/.rite/logs/bash-guard.log"; then
  pass "TC-141 deny audit record matches the existing stderr event"
else
  fail "TC-141 expected matching deny audit record (rc=$rc)"
fi
RITE_STATE_ROOT="$_audit_tmp" jq -n --arg cmd $'gh pr diff 99 --stat\n[2099-01-01T00:00:00Z] bash-guard: BLOCKED pattern=forged' \
  '{tool_name:"Bash",tool_input:{command:$cmd}}' \
  | RITE_STATE_ROOT="$_audit_tmp" bash "$HOOK" >/dev/null 2>/dev/null || true
if [ "$(awk 'END { print NR }' "$_audit_tmp/.rite/logs/bash-guard.log")" = "2" ] \
  && ! grep -q '^\[2099-01-01T00:00:00Z\]' "$_audit_tmp/.rite/logs/bash-guard.log"; then
  pass "TC-141 multiline commands cannot forge additional audit records"
else
  fail "TC-141 multiline command broke the one-event-per-line audit contract"
fi
RITE_STATE_ROOT="$_audit_tmp" jq -n --arg cmd $'gh pr diff 1 --stat\t\033X' \
  '{tool_name:"Bash",tool_input:{command:$cmd}}' \
  | RITE_STATE_ROOT="$_audit_tmp" bash "$HOOK" >/dev/null 2>/dev/null || true
if grep -Fq 'cmd="gh pr diff 1 --stat??X"' "$_audit_tmp/.rite/logs/bash-guard.log"; then
  pass "TC-141 remaining C0 controls are neutralized in audit records"
else
  fail "TC-141 audit record retained raw TAB/ESC controls: $(tail -1 "$_audit_tmp/.rite/logs/bash-guard.log" | cat -v)"
fi
rm -rf "$_audit_tmp"
echo ""

echo "TC-142 / T-02: audit write failure preserves deny JSON and warns"
_audit_tmp=$(mktemp -d)
mkdir -p "$_audit_tmp/.rite"
printf 'not-a-directory\n' > "$_audit_tmp/.rite/logs"
rc=0
output=$(jq -n --arg cmd "gh pr diff 99 --stat" \
  '{tool_name:"Bash",tool_input:{command:$cmd}}' \
  | RITE_STATE_ROOT="$_audit_tmp" bash "$HOOK" 2>"$_audit_tmp/stderr") || rc=$?
decision=$(extract_hook_field "$output" permissionDecision)
if [ "$decision" = "deny" ] && grep -q 'WARNING: unable to append deny audit log' "$_audit_tmp/stderr"; then
  pass "TC-142 deny contract survives audit write failure with one WARNING"
else
  fail "TC-142 expected deny + audit WARNING, got decision=$decision rc=$rc stderr=$(cat -v "$_audit_tmp/stderr")"
fi
rm -rf "$_audit_tmp"
echo ""

echo "TC-143 / T-03: allow does not create an audit log"
_audit_tmp=$(mktemp -d)
jq -n --arg cmd "printf safe" '{tool_name:"Bash",tool_input:{command:$cmd}}' \
  | RITE_STATE_ROOT="$_audit_tmp" bash "$HOOK" >/dev/null 2>"$_audit_tmp/stderr" || true
if [ ! -e "$_audit_tmp/.rite/logs/bash-guard.log" ]; then
  pass "TC-143 allow path writes no audit record"
else
  fail "TC-143 allow path unexpectedly created bash-guard.log"
fi
rm -rf "$_audit_tmp"
echo ""

# --------------------------------------------------------------------------
# Pattern 6: Direct gh issue create guard
# --------------------------------------------------------------------------

echo "TC-144 / T-01,T-05: direct gh issue create → deny with approved-path guidance"
for tc144_cmd in \
  'gh issue create -R owner/repo --title x --body-file /tmp/body.md' \
  '/usr/bin/gh issue create --title x' \
  'printf safe; gh issue create --title x' \
  "bash -c 'gh issue create --title x'" \
  'g""h issue create --title x' \
  $'gh issue \\\ncreate --title x' \
  $'cat <<EOF | gh issue create --title x\nbody\nEOF' \
  $'echo \'<<EOF\'\ngh issue create --title x\nEOF' \
  $'# <<EOF\ngh issue create --title x' \
  $': <<END-1\nbody\nEND-1\ngh issue create --title x' \
  $': <<E\\OF\nbody\nEOF\ngh issue create --title x'; do
  rc=0
  output=$(run_guard "Bash" "$tc144_cmd") || rc=$?
  decision=$(extract_hook_field "$output" permissionDecision)
  reason=$(extract_hook_field "$output" permissionDecisionReason)
  if [ "$rc" = "0" ] && [ "$decision" = "deny" ] \
    && [[ "$reason" == *"direct-gh-issue-create"* ]] \
    && [[ "$reason" == *"create-issue-with-projects.sh"* ]] \
    && [[ "$reason" == *"/rite:issue-create"* ]]; then
    pass "TC-144 direct create form denied with helper guidance: $tc144_cmd"
  else
    fail "TC-144 expected direct create deny, got rc=$rc decision=$decision reason=$reason cmd=$tc144_cmd"
  fi
done
echo ""

echo "TC-144: gh issue create text inside a heredoc body → allow"
tc144_heredoc_text=$'printf %s <<\'EOF\'\ngh issue create --title x\nEOF'
rc=0
output=$(run_guard "Bash" "$tc144_heredoc_text") || rc=$?
if [ "$rc" = "0" ] && [ -z "$output" ]; then
  pass "TC-144 heredoc body text allowed"
else
  fail "TC-144 expected heredoc body text allow, got rc=$rc output=$output"
fi
echo ""

echo "TC-145 / T-02,T-03: approved Issue helpers → allow"
for tc145_cmd in \
  'bash plugins/rite/scripts/create-issue-with-projects.sh "$args_json"' \
  'bash plugins/rite/scripts/decompose-issues.sh "$args_json"'; do
  rc=0
  output=$(run_guard "Bash" "$tc145_cmd") || rc=$?
  if [ "$rc" = "0" ] && [ -z "$output" ]; then
    pass "TC-145 approved helper allowed: $tc145_cmd"
  else
    fail "TC-145 expected helper allow, got rc=$rc output=$output cmd=$tc145_cmd"
  fi
done
echo ""

echo "TC-146 / T-04: non-create gh issue commands → allow"
for tc146_cmd in \
  'gh issue list --label follow-up --state all' \
  'gh issue view 2591 --json body' \
  'gh issue edit 2591 --title updated' \
  'gh label create follow-up --color ededed'; do
  rc=0
  output=$(run_guard "Bash" "$tc146_cmd") || rc=$?
  if [ "$rc" = "0" ] && [ -z "$output" ]; then
    pass "TC-146 non-create command allowed: $tc146_cmd"
  else
    fail "TC-146 expected non-create allow, got rc=$rc output=$output cmd=$tc146_cmd"
  fi
done
echo ""

echo "TC-147 / T-06,T-07: Pattern 6 crash → fail-closed without weakening Pattern 1"
tc147_input=$(jq -n --arg cmd 'gh issue create --title x' \
  '{tool_name:"Bash",tool_input:{command:$cmd}}')
rc=0
output=$(printf '%s' "$tc147_input" | RITE_BTG_TEST_CRASH=pattern6 bash "$HOOK" 2>"$STDERR_FILE") || rc=$?
decision=$(extract_hook_field "$output" permissionDecision)
reason=$(extract_hook_field "$output" permissionDecisionReason)
stderr_log=$(cat "$STDERR_FILE")
if [ "$rc" = "2" ] && [ "$decision" = "deny" ] \
  && [[ "$reason" == *"direct-gh-issue-create"* ]] \
  && [[ "$stderr_log" == *"Pattern 6"* ]]; then
  pass "TC-147 Pattern 6 crash denies and leaves stderr context"
else
  fail "TC-147 expected Pattern 6 fail-closed deny, got rc=$rc decision=$decision reason=$reason stderr=$stderr_log"
fi
rc=0
output=$(run_guard "Bash" 'gh pr diff 1 --stat') || rc=$?
decision=$(extract_hook_field "$output" permissionDecision)
reason=$(extract_hook_field "$output" permissionDecisionReason)
if [ "$rc" = "0" ] && [ "$decision" = "deny" ] && [[ "$reason" == *"gh-pr-diff-stat"* ]]; then
  pass "TC-147 Pattern 1 deny remains intact after Pattern 6"
else
  fail "TC-147 expected Pattern 1 non-regression, got rc=$rc decision=$decision reason=$reason"
fi
echo ""

echo "TC-148: git commit --allow-empty → deny; ordinary commit and --allow-empty-message → allow"
rc=0
output=$(run_guard "Bash" 'git commit --allow-empty -m "x"') || rc=$?
decision=$(extract_hook_field "$output" permissionDecision)
reason=$(extract_hook_field "$output" permissionDecisionReason)
if [ "$decision" = "deny" ] \
  && [[ "$reason" == *"git-commit-allow-empty"* ]] \
  && [[ "$reason" == *"Leave the changes as files"* ]]; then
  pass "git commit --allow-empty denied with pattern name and alternative"
else
  fail "Expected deny with git-commit-allow-empty and alternative, got decision=$decision reason=$reason"
fi
rc=0
output=$(run_guard "Bash" 'git commit -m "x"') || rc=$?
decision=$(extract_hook_field "$output" permissionDecision)
if [ "$rc" = "0" ] && [ -z "$output" ] && [ -z "$decision" ]; then
  pass "ordinary git commit -m is not denied"
else
  fail "Expected allow for git commit -m, got rc=$rc decision=$decision output=$output"
fi
rc=0
output=$(run_guard "Bash" 'git commit --allow-empty-message -m ""') || rc=$?
decision=$(extract_hook_field "$output" permissionDecision)
if [ "$rc" = "0" ] && [ -z "$output" ] && [ -z "$decision" ]; then
  pass "git commit --allow-empty-message is not denied"
else
  fail "Expected allow for --allow-empty-message, got rc=$rc decision=$decision output=$output"
fi
# Global options and redirections between git and commit still leave commit as the subcommand.
# Run from a repository, so the parser resolves the commit instead of failing on the target.
p7_repo=$(mktemp -d)
git -C "$p7_repo" init -q
run_guard_in_repo() {
  jq -n --arg cmd "$1" --arg cwd "$p7_repo" '{tool_name: "Bash", tool_input: {command: $cmd}, cwd: $cwd}' \
    | bash "$HOOK" 2>"$STDERR_FILE"
}
while IFS= read -r p7_cmd; do
  rc=0
  output=$(run_guard_in_repo "$p7_cmd") || rc=$?
  decision=$(extract_hook_field "$output" permissionDecision)
  reason=$(extract_hook_field "$output" permissionDecisionReason)
  if [ "$decision" = "deny" ] && [[ "$reason" == *"git-commit-allow-empty"* ]] \
     && [[ "$reason" == *"creates a commit with no file changes"* ]]; then
    pass "--allow-empty denied through words before commit: $p7_cmd"
  else
    fail "Expected git-commit-allow-empty deny for '$p7_cmd', got decision=$decision reason=$reason"
  fi
done <<'EOF'
git -c a.b=c commit --allow-empty -m x
git 2>/dev/null commit --allow-empty -m x
git 2> /dev/null commit --allow-empty -m x
git >/dev/null commit --allow-empty -m x
git &>/dev/null commit --allow-empty -m x
git <&- commit --allow-empty -m x
git -c a.b=c 2>&1 commit --allow-empty -m x
git -C . 2>/dev/null commit --allow-empty -m x
git -C 2>/dev/null . commit --allow-empty -m x
git -c 2>&1 a.b=c commit --allow-empty -m x
git --no-pager commit --allow-empty -m x
git 'commit' --allow-empty -m x
EOF
# A variable or command substitution between git and commit may expand to nothing, leaving a bare commit.
while IFS= read -r p7_cmd; do
  rc=0
  output=$(run_guard_in_repo "$p7_cmd") || rc=$?
  decision=$(extract_hook_field "$output" permissionDecision)
  reason=$(extract_hook_field "$output" permissionDecisionReason)
  if [ "$decision" = "deny" ] && [[ "$reason" == *"git-commit-allow-empty"* ]] && [[ "$reason" == *"dynamic"* ]]; then
    pass "--allow-empty denied behind a word that may expand to nothing: $p7_cmd"
  else
    fail "Expected git-commit-allow-empty deny for '$p7_cmd', got decision=$decision reason=$reason"
  fi
done <<'EOF'
git $OPTS commit --allow-empty -m x
git $(true) commit --allow-empty -m x
EOF
# git '' fails as an unknown command without committing; a commit word in another subcommand's arguments is not a commit.
while IFS= read -r p7_cmd; do
  rc=0
  output=$(run_guard_in_repo "$p7_cmd") || rc=$?
  if [ "$rc" = "0" ] && [ -z "$output" ]; then
    pass "not denied as git commit --allow-empty: $p7_cmd"
  else
    fail "Expected allow for '$p7_cmd', got rc=$rc output=$output"
  fi
done <<'EOF'
git log --allow-empty commit
git $OPTS log --allow-empty --grep commit
git '' commit --allow-empty -m x
git -c a.b=c commit --allow-empty-message -m ""
git -c a.b=c commit-tree --allow-empty
EOF
# Pattern 7 and the heredoc strip before it stay linear in the command length, so a
# command of a few hundred KB is judged well within the hook timeout.
p7_timed() {
  jq -n --rawfile cmd "$1" --arg cwd "$p7_repo" '{tool_name: "Bash", tool_input: {command: $cmd}, cwd: $cwd}' > "$p7_repo/big.json"
  rc=0
  _t0=$(date +%s%N)
  output=$(_timeout 15 bash "$HOOK" < "$p7_repo/big.json" 2>"$STDERR_FILE") || rc=$?
  _t1=$(date +%s%N)
  _ms=$(( (_t1 - _t0) / 1000000 ))
}
p7_big="$p7_repo/big.txt"
{ printf 'git '; for _i in $(seq 1 86000); do printf -- '-c git '; done; printf -- '--allow-empty'; } > "$p7_big"
p7_timed "$p7_big"
if [ "$rc" = "0" ] && [ -z "$output" ] && [ "$_ms" -lt 5000 ]; then
  pass "Pattern 7 returns for a ~600KB git -c command within 5s (${_ms}ms)"
else
  fail "Pattern 7 on a ~600KB git -c command rc=$rc ms=$_ms output=$output"
fi
# A non-adjacent commit longer than the parser's input limit is denied without parsing.
{ printf 'git -c a=b commit --allow-empty -m x a'; printf '%*s' 120000 '' | tr ' ' '>'; } > "$p7_big"
p7_timed "$p7_big"
decision=$(extract_hook_field "$output" permissionDecision)
reason=$(extract_hook_field "$output" permissionDecisionReason)
if [ "$decision" = "deny" ] && [[ "$reason" == *"too long to inspect"* ]] && [ "$_ms" -lt 5000 ]; then
  pass "Pattern 7 denies a ~120KB non-adjacent commit as too long to inspect (${_ms}ms)"
else
  fail "Pattern 7 on a ~120KB non-adjacent commit rc=$rc ms=$_ms decision=$decision reason=$reason"
fi
# At each limit the parser still finishes (the reason is its own) within 8s, under the
# 10s hook timeout. Past a parser limit, a commit that could hide there is refused, and a
# command that moves no HEAD outside an unparsed substitution is not.
p7_max=$(sed -n 's/^_RITE_BTG_P7_PARSE_MAX_CHARS=//p' "$HOOK")
p7_scope_py="$(dirname "$HOOK")/scripts/lib/review-fix-scope.py"
p7_depth=$(sed -n 's/^MAX_SUBSTITUTION_DEPTH = //p' "$p7_scope_py")
p7_changes=$(sed -n 's/^MAX_DIRECTORY_CHANGES = //p' "$p7_scope_py")
for p7_limit in "$p7_max" "$p7_depth" "$p7_changes"; do
  [[ "$p7_limit" =~ ^[0-9]+$ ]] || fail "Pattern 7 limit constants must be read as integers: '$p7_max' '$p7_depth' '$p7_changes'"
done
p7_tail='; git -ca commit --allow-empty -m x'
p7_limit_case() {  # $1 label, $2 expected reason
  p7_timed "$p7_big"
  decision=$(extract_hook_field "$output" permissionDecision)
  reason=$(extract_hook_field "$output" permissionDecisionReason)
  if [ "$decision" = "deny" ] && [[ "$reason" == *"$2"* ]] && [ "$_ms" -lt 8000 ]; then
    pass "Pattern 7 denies $1 within 8s ($(wc -c < "$p7_big") bytes, ${_ms}ms)"
  else
    fail "Pattern 7 on $1 rc=$rc ms=$_ms decision=$decision reason=$reason"
  fi
}
p7_allow_case() {  # $1 label
  p7_timed "$p7_big"
  if [ "$rc" = "0" ] && [ -z "$output" ] && [ "$_ms" -lt 8000 ]; then
    pass "Pattern 7 allows $1 within 8s (${_ms}ms)"
  else
    fail "Pattern 7 on $1 rc=$rc ms=$_ms output=$output"
  fi
}
p7_log_tail='; git log --allow-empty --grep commit'
p7_nested() {  # $1 depth, $2 length of the innermost word, $3 innermost command (default echo), $4 tail
  { printf 'echo '; printf '$(%.0s' $(seq 1 "$1"); printf '%s ' "${3:-echo}"; printf '%*s' "$2" '' | tr ' ' 'x'
    printf ')%.0s' $(seq 1 "$1"); printf '%s' "${4:-$p7_tail}"; } > "$p7_big"
}
p7_nested "$p7_depth" $(( p7_max - 3 * p7_depth - 10 - ${#p7_tail} ))
p7_limit_case "the deepest nesting of the longest command" "creates a commit with no file changes"
p7_nested $(( p7_depth + 1 )) 10 'git -ca commit -m' "$p7_log_tail"
p7_limit_case "a commit nested one level too deep" "nested more than $p7_depth deep"
p7_nested $(( p7_depth + 1 )) 10 "g''it commit -m" "$p7_log_tail"
p7_limit_case "a quoted-apart commit nested one level too deep" "nested more than $p7_depth deep"
p7_nested $(( p7_depth + 1 )) 10 true "$p7_log_tail"
p7_allow_case "a git log after nesting one level too deep"
{ for _i in $(seq 1 $(( (p7_max - ${#p7_tail}) / 10 ))); do printf 'git merge;'; done
  printf '%s' "$p7_tail"; } > "$p7_big"
p7_limit_case "the most merges that fit" "creates a commit with no file changes"
# Each directory change here is a different merge target, resolved by its own git process.
p7_dirs() {  # $1 number of merge targets besides the commit's
  { for _i in $(seq 1 "$1"); do mkdir -p "$p7_repo/d$_i"; printf 'git -C d%s merge x;' "$_i"; done
    printf '%s' "$p7_tail"; } > "$p7_big"
}
p7_dirs "$p7_changes"
p7_limit_case "the most cd / -C directory changes" "creates a commit with no file changes"
p7_moves() {  # $1 number of -C. options, $2 subcommand and arguments
  { printf 'git'; for _i in $(seq 1 "$1"); do printf ' -C.'; done; printf ' %s' "$2"; } > "$p7_big"
}
p7_moves $(( p7_changes + 1 )) 'commit --allow-empty -m x'
p7_limit_case "a commit after one cd / -C directory change too many" "target is dynamic"
p7_moves $(( p7_changes + 1 )) 'log --allow-empty --grep commit'
p7_allow_case "a git log after one cd / -C directory change too many"
# The longest path those changes can build: every change adds as many components as fit.
{ printf 'git'; for _i in $(seq 1 "$p7_changes"); do
    printf ' -C'; printf 'x/%.0s' $(seq 1 $(( (p7_max - 40) / p7_changes / 2 - 2 ))); done
  printf ' commit --allow-empty -m x'; } > "$p7_big"
p7_limit_case "the longest path built by directory changes" "cannot be resolved to a repository"
# The costliest use of those changes: the first builds the whole path and every other one
# resolves it again.
{ printf 'git -C'; printf 'x/%.0s' $(seq 1 $(( (p7_max - 40 - 4 * p7_changes) / 2 )))
  for _i in $(seq 2 "$p7_changes"); do printf ' -C.'; done
  printf ' commit --allow-empty -m x'; } > "$p7_big"
p7_limit_case "the longest path resolved again by every directory change" "cannot be resolved to a repository"
# The parser itself stays linear: a long word of > signs and a long run of wrapper options.
p7_scope_check="$(dirname "$HOOK")/scripts/review-fix-scope-check.sh"
for p7_shape in gt wrapper; do
  if [ "$p7_shape" = gt ]; then
    { printf 'git -c a=b commit --allow-empty -m x a'; printf '%*s' 120000 '' | tr ' ' '>'; } > "$p7_big"
  else
    { printf 'env '; printf -- '-i %.0s' $(seq 1 40000); printf 'git -c a=b commit --allow-empty -m x'; } > "$p7_big"
  fi
  rc=0
  _t0=$(date +%s%N)
  output=$(_timeout 15 bash "$p7_scope_check" commit-target --command "$(cat "$p7_big")" --cwd "$p7_repo" 2>&1) || rc=$?
  _t1=$(date +%s%N)
  _ms=$(( (_t1 - _t0) / 1000000 ))
  if [ "$rc" = "0" ] && [[ "$output" == index* || "$output" == other* ]] && [ "$_ms" -lt 1000 ]; then
    pass "commit-target parses a ~120KB $p7_shape command within 1s (${_ms}ms)"
  else
    fail "commit-target on a ~120KB $p7_shape command rc=$rc ms=$_ms output=$(printf '%s' "$output" | head -c 200)"
  fi
done
# The heredoc surface parser that Patterns 6, 8 and 9 run costs about the square of each
# line's length plus a fixed amount per line. A git commit / merge command past the parse
# budget is denied without parsing, so a hook killed for its timeout cannot let it run.
# The cost is quadratic only under a UTF-8 locale, so the timed cases run under one.
sb_utf8=$(locale -a 2>/dev/null | grep -ixE 'c\.utf-?8|en_us\.utf-?8' | head -1) || sb_utf8=""
[ -n "$sb_utf8" ] || fail "parse budget timings need a C.UTF-8 or en_US.UTF-8 locale"
sb_line_cost=$(sed -n 's/^_RITE_BTG_SURFACE_LINE_COST=//p' "$HOOK")
sb_max_cost=$(sed -n 's/^_RITE_BTG_SURFACE_MAX_COST=//p' "$HOOK")
# Where a case falls is fixed by the cost constants, not by the clock. The clock only has to
# show the hook is not killed: the ceiling is the timeout the harness enforces, so a slow
# runner cannot turn a correct verdict into a failure.
sb_timeout_s=$(jq -r '[.. | objects | select((.command // "") | contains("pre-tool-bash-guard.sh")) | .timeout] | if length == 1 then .[0] else empty end' "$(dirname "$HOOK")/hooks.json") || sb_timeout_s=""
if [[ "$sb_timeout_s" =~ ^[1-9][0-9]*$ ]]; then sb_timeout_ms=$(( sb_timeout_s * 1000 )); else sb_timeout_ms=""; fi
if [[ "$sb_line_cost" =~ ^[1-9][0-9]*$ && "$sb_max_cost" =~ ^[1-9][0-9]*$ && -n "$sb_timeout_ms" ]]; then
  sb_case() {  # $1 label, $2 "deny" when commit-guard-uninspectable is expected, "other" when not
    LC_ALL="$sb_utf8" p7_timed "$p7_big"
    reason=$(extract_hook_field "$output" permissionDecisionReason)
    local got=other
    [[ "$reason" == *commit-guard-uninspectable* ]] && got=deny
    if [ "$rc" = "0" ] && [ "$_ms" -lt "$sb_timeout_ms" ] && [ "$got" = "$2" ]; then
      pass "parse budget: $1 → $2 (${_ms}ms)"
    else
      fail "parse budget: $1 expected $2, rc=$rc ms=$_ms reason=$reason"
    fi
  }
  sb_x() { printf '%*s' "$1" '' | tr ' ' "${2:-x}"; }
  # One line: the longest that fits, and one byte more.
  sb_len=$(awk -v m="$sb_max_cost" -v c="$sb_line_cost" 'BEGIN { printf "%d", int(sqrt(m - c)) }')
  for sb_n in "$sb_len" $(( sb_len + 1 )); do
    { printf 'git commit -m '; sb_x $(( sb_n - 14 )); } > "$p7_big"
    if [ "$sb_n" = "$sb_len" ]; then sb_case "one line of $sb_n bytes" other; else sb_case "one line of $sb_n bytes" deny; fi
  done
  # Two lines add up: each is within a one-line budget, and together they are not.
  sb_half=$(awk -v m="$sb_max_cost" -v c="$sb_line_cost" 'BEGIN { printf "%d", int(sqrt(m / 2 - c)) }')
  for sb_n in "$sb_half" $(( sb_half + 1 )); do
    { printf 'git commit -m '; sb_x $(( sb_n - 14 )); printf '\necho '; sb_x $(( sb_n - 5 )) y; } > "$p7_big"
    if [ "$sb_n" = "$sb_half" ]; then sb_case "two lines of $sb_n bytes" other; else sb_case "two lines of $sb_n bytes" deny; fi
  done
  # Short lines cost their fixed amount: the most 15-byte lines that fit, and one more.
  sb_lines=$(( sb_max_cost / (225 + sb_line_cost) ))
  for sb_n in "$sb_lines" $(( sb_lines + 1 )); do
    { for _i in $(seq 2 "$sb_n"); do printf 'echo abcdefghij\n'; done; printf 'git commit -m y'; } > "$p7_big"
    if [ "$sb_n" = "$sb_lines" ]; then sb_case "$sb_n short lines" other; else sb_case "$sb_n short lines" deny; fi
  done
  # Lines joined by a continuation are measured joined, with carriage returns removed first.
  { printf 'git commit -m '; sb_x $(( sb_len / 2 - 4 )); printf '\\\n'; sb_x $(( sb_len / 2 + 10 )); } > "$p7_big"
  sb_case "a line joined by a continuation" deny
  { printf 'git commit -m '; sb_x $(( sb_len / 2 - 4 )); printf '\\\r\n'; sb_x $(( sb_len / 2 + 10 )); } > "$p7_big"
  sb_case "a line joined by a continuation before a carriage return" deny
  # Long commands past the budget, a merge among them; a command without git is not this denial.
  { printf 'git commit -m "'; sb_x 40960; printf '"'; } > "$p7_big"
  sb_case "a 40KB commit message" deny
  # The alternative must not lead back to the same denial: a Bash heredoc holding the
  # message is estimated the same way, so it names a file-editing tool and git commit -F.
  if [[ "$reason" == *"file-editing tool, not a Bash heredoc"* && "$reason" == *"git commit -F <message-file>"* ]]; then
    pass "parse budget: the denial names a file-editing tool and git commit -F"
  else
    fail "parse budget: the denial should name a file-editing tool and git commit -F: $reason"
  fi
  printf 'git commit -F /tmp/rite-commit-msg.txt' > "$p7_big"
  sb_case "the recovery command git commit -F <message-file>" other
  { printf 'git commit -m "'; sb_x 1048576; printf '"'; } > "$p7_big"
  sb_case "a 1MB commit message" deny
  # Past the budget Pattern 6 checks the whole command, so a heredoc of many lines must
  # not make its checks run out of time before this denial.
  { printf "git commit -F - <<'EOF'\n"; printf 'xxxxxxxxxxxxxxx\n%.0s' $(seq 1 60000); printf 'EOF'; } > "$p7_big"
  sb_case "a commit with a 60000-line heredoc" deny
  # Each character Pattern 6 replaces, crowded into a heredoc of about 1MB.
  { printf "git commit -F - <<'EOF'\r\n"; printf 'xxxxxxxxxxxxxx\r\n%.0s' $(seq 1 60000); printf 'EOF'; } > "$p7_big"
  sb_case "a commit with a 60000-line CRLF heredoc" deny
  for sb_char in '\' $'\t'; do
    sb_line="$(printf '%*s' 32 '' | tr ' ' "$sb_char")y"
    { printf "git commit -F - <<'EOF'\n"; for _i in $(seq 1 30800); do printf '%s\n' "$sb_line"; done; printf 'EOF'; } > "$p7_big"
    sb_case "a commit with a heredoc of 30800 lines of 32 $([ "$sb_char" = '\' ] && echo backslashes || echo tabs)" deny
  done
  { printf 'git merge -m '; sb_x 10240; printf ' x'; } > "$p7_big"
  sb_case "a merge with a 10KB message" deny
  { printf 'echo '; sb_x 40960; } > "$p7_big"
  sb_case "a 40KB command without git" other
  # A failed estimate denies.
  printf 'git commit -m y' > "$p7_big"
  RITE_BTG_TEST_CRASH=surface-budget sb_case "a commit whose estimate fails" deny
  # Everyday and heavy commands within the budget are judged as before.
  printf 'git commit -m "fix: x"' > "$p7_big"
  sb_case "an everyday commit" other
  { printf "git commit -F - <<'EOF'\n"; for _i in $(seq 1 420); do sb_x 71; printf '\n'; done; printf 'EOF'; } > "$p7_big"
  sb_case "a 30KB heredoc message of short lines" other
  { printf 'git commit -m '; for _i in $(seq 1 $(( (sb_len - 14) / 3 ))); do printf 'あ'; done; } > "$p7_big"
  sb_case "a Japanese message line just within the budget" other
  { printf 'git commit -m '; for _i in $(seq 1 $(( (sb_len - 14) / 3 + 1 ))); do printf 'あ'; done; } > "$p7_big"
  sb_case "a Japanese message line just past the budget" deny
  { printf 'git commit -m '; sb_x 7960; printf '\n'; for _i in $(seq 1 150); do printf 'echo abcdefghij\n'; done; } > "$p7_big"
  sb_case "one long line followed by short lines" other
  # The heaviest form: a heredoc makes Patterns 6, 8 and 9 each parse the surface, and
  # the commit line after it is as long as the budget allows.
  { printf "cat <<'EOF'\nx\nEOF\ngit commit -m "; sb_x $(( sb_len - 4 - 14 )); } > "$p7_big"
  sb_case "a heredoc before a commit line of $(( sb_len - 4 )) bytes" other
  # Pattern 6 checks a heredoc past the budget as raw text: a gh issue create after the
  # heredoc, split by a line continuation, or in its body is denied, and a command with
  # none of them is allowed.
  for sb_where in after split body none; do
    case "$sb_where" in
      after) { printf "cat <<'EOF'\n"; sb_x 10240 q; printf '\nEOF\ngh issue create -t x'; } > "$p7_big" ;;
      split) { printf "cat <<'EOF'\n"; sb_x 10240 q; printf '\nEOF\ngh issue cre\\\r\nate -t x'; } > "$p7_big" ;;
      body) { printf "cat <<'EOF'\ngh issue create "; sb_x 10240 q; printf '\nEOF'; } > "$p7_big" ;;
      none) { printf "cat <<'EOF'\n"; sb_x 10240 q; printf '\nEOF'; } > "$p7_big" ;;
    esac
    LC_ALL="$sb_utf8" p7_timed "$p7_big"
    reason=$(extract_hook_field "$output" permissionDecisionReason)
    if [ "$sb_where" = none ]; then
      if [ "$rc" = "0" ] && [ -z "$output" ] && [ "$_ms" -lt "$sb_timeout_ms" ]; then
        pass "parse budget: Pattern 6 allows a long heredoc without gh issue create (${_ms}ms)"
      else
        fail "parse budget: Pattern 6 on a long heredoc without gh issue create rc=$rc ms=$_ms output=$output"
      fi
    elif [ "$rc" = "0" ] && [[ "$reason" == *direct-gh-issue-create* && "$reason" == *"bodies were checked"* && "$reason" == *"file-editing tool, not a Bash heredoc"* ]] && [ "$_ms" -lt "$sb_timeout_ms" ]; then
      pass "parse budget: Pattern 6 denies gh issue create $sb_where a long heredoc (${_ms}ms)"
    else
      fail "parse budget: Pattern 6 on gh issue create $sb_where a long heredoc rc=$rc ms=$_ms reason=$reason"
    fi
  done
else
  fail "parse budget constants and the hook timeout must be read as positive integers: '$sb_line_cost' '$sb_max_cost' '$sb_timeout_s'"
fi
rm -rf "$p7_repo"
echo ""

# --------------------------------------------------------------------------
# TC-203: reviewer state-changing commands (sub-block (S)).
# Reviewer-typed subagents are denied push / commit / GitHub writes / gh pr checkout /
# flow-state writes / step drivers at command position; read-only commands that merely MENTION those words
# stay allowed; non-reviewer subagents and the main session are untouched.
# --------------------------------------------------------------------------
echo "TC-203: reviewer state-changing commands → deny; read-only and non-reviewer → allow"
# $1 = reported agent type ("" = main session, "-" = subagent transcript with no type)
run_guard_typed() {
  local agent_type="$1" cmd="$2" rc=0 output
  output=$(jq -n --arg cmd "$cmd" --arg t "$agent_type" \
    '{tool_name: "Bash", tool_input: {command: $cmd}, cwd: "/tmp"}
     + (if $t == "" then {} elif $t == "-" then {transcript_path: "/tmp/p/subagents/a.jsonl"} else {agent_type: $t} end)' \
    | bash "$HOOK" 2>"$STDERR_FILE") || rc=$?
  echo "$output"
  return $rc
}
for sc_cmd in \
  "git push" \
  "git -C x commit -m y" \
  "/usr/bin/git push origin HEAD" \
  "cd x && git commit -m y" \
  'x=$(git push)' \
  "FOO=1 git push" \
  "bash plugins/rite/hooks/flow-state.sh set --phase fix" \
  "plugins/rite/hooks/flow-state.sh consume-handoff" \
  "bash plugins/rite/hooks/flow-state.sh" \
  "bash plugins/rite/scripts/fix-step.sh push" \
  "bash plugins/rite/scripts/iterate-step.sh restore" \
  $'cat <<\'EOF\' >/tmp/m\nx\nEOF\ngit push' \
  "if true; then git push; fi" \
  "{ git commit -m y; }" \
  "! git push" \
  "'git' push" \
  '\git commit -m y' \
  'echo "$(git push)"' \
  "while read x; do git push; done" \
  'git -C "$(pwd)" push' \
  'cd "$(git rev-parse --show-toplevel)" && git push' \
  'bash "$(git rev-parse --show-toplevel)/plugins/rite/hooks/flow-state.sh" set --phase fix' \
  'echo "`date`" && git push' \
  'echo $(case x in *) git push;; esac)' \
  'printf %s "$(case x in a) bash plugins/rite/hooks/flow-state.sh set --phase fix;; esac)"' \
  'x="$(case y in a) echo z;; esac)"; git push origin HEAD' \
  'echo $(time -p case x in *) git push;; esac)' \
  "echo \"\$('case' x)\"; git push" \
  "echo \$(case x in a) 'esac';; *) git push;; esac)" \
  '$(true) git push' \
  "timeout 30 git push" \
  "env -u X git push" \
  "nice -n 5 git commit -m y" \
  "time -p git push" \
  "timeout -k 5 30 git push" \
  "command git push" \
  "exec git push" \
  "nohup git push" \
  "gh pr comment 1 --body x" \
  "gh pr review 1 --approve" \
  "gh pr update-branch 1" \
  "gh pr revert 1" \
  "gh pr checkout 1" \
  "gh -R o/r pr checkout 1 --force" \
  "timeout 30 gh pr checkout 1" \
  "gh -R o/r issue create --title t --body b" \
  "gh issue edit 1 --add-label x" \
  "gh pr merge 1 --squash" \
  "gh api -X POST repos/o/r/issues/1/comments -f body=x" \
  "gh api repos/o/r/issues/1/comments -f body=x" \
  "gh api repos/o/r/issues -F title=x" \
  "gh api -X DELETE repos/o/r/issues/comments/1" \
  "gh api --method=PATCH repos/o/r/pulls/1" \
  "gh api graphql -f query='mutation { x }'" \
  "git push && git log --help" \
  "git push origin --help" \
  "git push --help && git push origin HEAD" \
  "bash -n plugins/rite/hooks/flow-state.sh && bash plugins/rite/hooks/flow-state.sh set --phase fix" \
  "bash -x plugins/rite/hooks/flow-state.sh set --phase fix" \
  "git >/dev/null push" \
  "git 2>/dev/null commit -m x" \
  'git $OPTS commit -m x' \
  "git > /dev/null push" \
  "git 2>&1 push" \
  "git &>/dev/null push" \
  "timeout 30 git 2>/dev/null push" \
  "git --git-dir .git push" \
  "git --work-tree=. commit -m x" \
  "git --no-pager push" \
  "git -p push" \
  "git -C x 2>/dev/null push" \
  "git --namespace n push" \
  "git --super-prefix p/ push" \
  "git --attr-source HEAD push" \
  "git --shallow-file f push" \
  'git $(echo) push' \
  "git 2>/dev/null push origin --help" \
  "git >/dev/null push && git log --help" \
  "git push&>/dev/null" \
  "gh pr merge 1&>/dev/null" \
  "bash plugins/rite/scripts/iterate-step.sh&>/dev/null" \
  "echo '->'& git push origin HEAD" \
  "echo 'a<'& gh pr comment 1 --body x" \
  "sleep 1 & git push" \
  "true&git push" \
  'echo a\>& git push origin HEAD' \
  'echo a\<& gh pr comment 1 --body x' \
  ; do
  rc=0
  output=$(run_guard_typed "rite:test-reviewer" "$sc_cmd") || rc=$?
  decision=$(extract_hook_field "$output" permissionDecision)
  reason=$(extract_hook_field "$output" permissionDecisionReason)
  if [ "$decision" = "deny" ] && [[ "$reason" == "BLOCKED (reviewer-state-change):"* ]] \
    && [[ "$reason" == *"type=rite:test-reviewer"* ]] \
    && grep -q 'bash-guard: BLOCKED pattern=reviewer-state-change' "$STDERR_FILE"; then
    pass "reviewer '${sc_cmd//$'\n'/\\n}' denied as reviewer-state-change"
  else
    fail "Expected reviewer-state-change deny for '${sc_cmd//$'\n'/\\n}', got decision=$decision reason=$reason"
  fi
done
# Reviewer classification matrix — the same predicate as pre-tool-edit-guard.sh.
# $1 = JSON fields merged into the hook input, $2 = CLAUDE_SUBAGENT_TYPE ("" = unset)
run_guard_fields() {
  local fields="$1" env_type="$2" rc=0 output
  output=$(jq -n --arg cmd "git push" --argjson f "$fields" \
    '{tool_name: "Bash", tool_input: {command: $cmd}, cwd: "/tmp"} + $f' \
    | env -u CLAUDE_SUBAGENT_TYPE -u CLAUDE_AGENT_TYPE ${env_type:+CLAUDE_SUBAGENT_TYPE=$env_type} bash "$HOOK" 2>"$STDERR_FILE") || rc=$?
  echo "$output"
  return $rc
}
for deny_fields in \
  '{"subagent_type":"plugin:rite:code-quality-reviewer"}' \
  '{"subagent_type":"rite:_reviewer-base"}' \
  '{"subagent_type":"general-purpose","agent_type":"rite:security-reviewer"}' \
  ; do
  rc=0
  output=$(run_guard_fields "$deny_fields" "") || rc=$?
  if [[ "$(extract_hook_field "$output" permissionDecisionReason)" == "BLOCKED (reviewer-state-change):"* ]]; then
    pass "reviewer-typed $deny_fields denied git push"
  else
    fail "Expected reviewer-state-change deny for $deny_fields, got output=$output"
  fi
done
rc=0
output=$(run_guard_fields '{}' "rite:test-reviewer") || rc=$?
if [[ "$(extract_hook_field "$output" permissionDecisionReason)" == "BLOCKED (reviewer-state-change):"* ]]; then
  pass "Tier 3 env CLAUDE_SUBAGENT_TYPE=rite:test-reviewer denied git push"
else
  fail "Expected Tier 3 reviewer deny, got output=$output"
fi
for allow_case in '{"subagent_type":"general-purpose"}|' '{}|general-purpose'; do
  rc=0
  output=$(run_guard_fields "${allow_case%%|*}" "${allow_case#*|}") || rc=$?
  if [ "$rc" = "0" ] && [ -z "$output" ]; then
    pass "non-reviewer type ($allow_case) git push allowed"
  else
    fail "Expected allow for non-reviewer type ($allow_case), got rc=$rc output=$output"
  fi
done
# The .git-write gate still covers every subagent, not only reviewers.
rc=0
output=$(run_guard_typed "general-purpose" "echo x > .git/hooks/pre-commit") || rc=$?
if [[ "$(extract_hook_field "$output" permissionDecisionReason)" == "BLOCKED (reviewer-gitdir-write):"* ]]; then
  pass "non-reviewer subagent .git write still denied as reviewer-gitdir-write"
else
  fail "Expected reviewer-gitdir-write deny for general-purpose .git write, got output=$output"
fi
rc=0
output=$(run_guard_typed "-" "git push") || rc=$?
reason=$(extract_hook_field "$output" permissionDecisionReason)
if [[ "$reason" == *"reviewer-state-change"* ]] && [[ "$reason" == *"type unknown"* ]]; then
  pass "subagent with no reported type is treated as a reviewer (git push denied)"
else
  fail "Expected type-unknown subagent git push deny, got reason=$reason"
fi
for ro_sc_cmd in \
  "git diff" \
  "grep -rn 'git commit' plugins/" \
  "git log -S'git push'" \
  'echo "git push"' \
  "bash plugins/rite/hooks/tests/x.test.sh" \
  "bash plugins/rite/hooks/flow-state.sh get --field phase" \
  "bash plugins/rite/hooks/flow-state.sh path" \
  "git worktree add --detach /tmp/rite-review-mutation-x HEAD" \
  "grep -rn 'x; git push' plugins/" \
  "git log --grep='a\\|git commit'" \
  'echo "(git push)"' \
  $'cat <<\'EOF\'\ngit push\nEOF' \
  "git status # then git push" \
  'echo "$(date); git push is blocked"' \
  'x=$(case y in a) echo z;; esac); echo "$x git push"' \
  "gh pr view 1 --json body" \
  "gh pr diff 1" \
  "gh issue view 1" \
  "gh api repos/o/r/pulls/1" \
  "gh api -X GET repos/o/r/issues -f state=open" \
  "gh api graphql -f query='query { viewer { login } }'" \
  "timeout 30 git status" \
  "gh pr create --help" \
  "gh issue close -h" \
  "gh pr checkout --help" \
  "git push --help" \
  "git commit -h" \
  "bash -n plugins/rite/hooks/flow-state.sh" \
  "bash -n plugins/rite/scripts/iterate-step.sh" \
  "git log --grep push" \
  "git 2>/dev/null log --grep push" \
  "git -C push status" \
  "git --git-dir push log" \
  "git --namespace commit log" \
  "git 2>/dev/null push --help" \
  "git -C x commit -h" \
  "git log -- plugins/rite/scripts/iterate-step.sh" \
  "git show HEAD:plugins/rite/hooks/flow-state.sh" \
  "git log 2>&1 | grep commit" \
  "git log&>/dev/null" \
  "git log >&2" \
  ; do
  rc=0
  output=$(run_guard_typed "rite:test-reviewer" "$ro_sc_cmd") || rc=$?
  if [ "$rc" = "0" ] && [ -z "$output" ]; then
    pass "reviewer read-only '$ro_sc_cmd' allowed"
  else
    fail "Expected allow for reviewer '$ro_sc_cmd', got rc=$rc output=$output"
  fi
done
# A git subcommand that the parser does not report is denied: a python3 that
# fails, and one that answers no line. A git with no push / commit does not run
# the parser, so the broken python3 does not deny it.
sc_stub_dir=$(mktemp -d)
for sc_stub in "fail|exit 1|parser failed" "silent|exit 0|answered 0 of 1"; do
  sc_stub_label="${sc_stub%%|*}"; sc_stub_rest="${sc_stub#*|}"
  sc_stub_body="${sc_stub_rest%|*}"; sc_stub_want="${sc_stub_rest##*|}"
  printf '#!/bin/sh\ncat >/dev/null\n%s\n' "$sc_stub_body" > "$sc_stub_dir/python3"
  chmod +x "$sc_stub_dir/python3"
  rc=0
  output=$(jq -n --arg cmd "git >/dev/null log" '{tool_name: "Bash", tool_input: {command: ($cmd + "; git 2>/dev/null push")}, cwd: "/tmp", agent_type: "rite:test-reviewer"}' \
    | PATH="$sc_stub_dir:$PATH" bash "$HOOK" 2>"$STDERR_FILE") || rc=$?
  reason=$(extract_hook_field "$output" permissionDecisionReason)
  if [ "$(extract_hook_field "$output" permissionDecision)" = "deny" ] \
    && [[ "$reason" == "BLOCKED (reviewer-state-change):"* ]] && [[ "$reason" == *"could not be determined"*"$sc_stub_want"* ]] \
    && grep -q 'bash-guard: BLOCKED pattern=reviewer-state-change' "$STDERR_FILE"; then
    pass "reviewer git push denied when the subcommand parser is unusable ($sc_stub_label)"
  else
    fail "Expected parser-unusable deny ($sc_stub_label), got output=$output"
  fi
  for sc_ro in "git status" "git diff"; do
    rc=0
    output=$(jq -n --arg cmd "$sc_ro" '{tool_name: "Bash", tool_input: {command: $cmd}, cwd: "/tmp", agent_type: "rite:test-reviewer"}' \
      | PATH="$sc_stub_dir:$PATH" bash "$HOOK" 2>"$STDERR_FILE") || rc=$?
    if [ "$rc" = "0" ] && [ -z "$output" ]; then
      pass "reviewer '$sc_ro' allowed without the subcommand parser ($sc_stub_label)"
    else
      fail "Expected allow for reviewer '$sc_ro' with an unusable parser ($sc_stub_label), got rc=$rc output=$output"
    fi
  done
done
rm -rf "$sc_stub_dir"
# The subcommand is found in one place: the reviewer scan keeps no git
# subcommand branch, and the commit guard's parser walks global options once.
sc_match_body=$(awk '/^_rite_btg_state_change_match\(\) \{/,/^}/' "$HOOK")
if [ -n "$sc_match_body" ] && ! grep -qE 'push\|commit' <<< "$sc_match_body" \
  && [ "$(grep -c 'while index < len(words) and (words\[index\].startswith("-")' "$SCRIPT_DIR/../scripts/lib/review-fix-scope.py")" = "1" ]; then
  pass "git subcommand identification is shared with the commit guard's parser"
else
  fail "Expected no git subcommand branch in the reviewer scan and one global-option walk in review-fix-scope.py"
fi
# The scan must finish inside the hook timeout: a command just under the scan
# ceiling is scanned and denied, a longer one is denied unscanned; neither may
# time out.
sc_pad=$(printf 'a b %.0s' $(seq 1 2040))
for size_case in "scan|echo $sc_pad; git push|runs 'git push'" \
  "unscanned|echo $(printf 'aaaa bbbb %.0s' $(seq 1 6000)); git push|(ceiling 8192)"; do
  size_label="${size_case%%|*}"; size_rest="${size_case#*|}"
  size_cmd="${size_rest%|*}"; size_want="${size_rest##*|}"
  rc=0
  output=$(jq -n --arg cmd "$size_cmd" '{tool_name: "Bash", tool_input: {command: $cmd}, cwd: "/tmp", agent_type: "rite:test-reviewer"}' \
    | _timeout 10 bash "$HOOK" 2>"$STDERR_FILE") || rc=$?
  reason=$(extract_hook_field "$output" permissionDecisionReason)
  if [ "$rc" != "124" ] && [[ "$reason" == "BLOCKED (reviewer-state-change):"* ]] && [[ "$reason" == *"$size_want"* ]]; then
    pass "reviewer ${#size_cmd}-byte git push denied within the hook timeout ($size_label)"
  else
    fail "Expected in-time reviewer-state-change deny for ${#size_cmd}-byte command ($size_label), got rc=$rc reason=$reason"
  fi
done
# gh counts only as a word: a long read-only command with `through ` / `high `
# is not denied by the size ceiling.
sc_cmd="echo $(printf 'walk through high %.0s' $(seq 1 500))"
rc=0
output=$(run_guard_typed "rite:test-reviewer" "$sc_cmd") || rc=$?
if [ "${#sc_cmd}" -gt 8192 ] && [ "$rc" = "0" ] && [ -z "$output" ]; then
  pass "reviewer ${#sc_cmd}-byte command with 'through ' / 'high ' allowed"
else
  fail "Expected allow for ${#sc_cmd}-byte command with 'through ' / 'high ', got rc=$rc output=$output"
fi
# A failure inside the scan function must still reach the fail-closed ERR trap.
rc=0
output=$(jq -n --arg cmd "git push" '{tool_name: "Bash", tool_input: {command: $cmd}, cwd: "/tmp", agent_type: "rite:test-reviewer"}' \
  | RITE_BTG_TEST_CRASH=pattern4-scan bash "$HOOK" 2>"$STDERR_FILE") || rc=$?
if [ "$rc" = "2" ] && [[ "$(extract_hook_field "$output" permissionDecisionReason)" == *"reviewer-gitdir-write"* ]] \
  && grep -q 'WARNING Pattern 4' "$STDERR_FILE"; then
  pass "crash inside the (S) scan function denies fail-closed (rc=2)"
else
  fail "Expected fail-closed deny for a crash inside the (S) scan, got rc=$rc output=$output"
fi
for other_type in "general-purpose" ""; do
  for other_cmd in "git push" "git commit -m x" "gh pr checkout 1" "bash plugins/rite/hooks/flow-state.sh set --phase fix"; do
    rc=0
    output=$(run_guard_typed "$other_type" "$other_cmd") || rc=$?
    if [ "$rc" = "0" ] && [ -z "$output" ]; then
      pass "non-reviewer (${other_type:-main session}) '$other_cmd' allowed"
    else
      fail "Expected allow for non-reviewer (${other_type:-main session}) '$other_cmd', got rc=$rc output=$output"
    fi
  done
done
echo ""

# --------------------------------------------------------------------------
# Pattern 10: git / gh / script outside the checkout during a rite session
# --------------------------------------------------------------------------
echo "TC-P10: git / gh / script run outside the checkout while a rite session is active"
p10_main=$(mktemp -d "${TMPDIR:-/tmp}/rite-p10-main.XXXXXX")
p10_scratch=$(mktemp -d "${TMPDIR:-/tmp}/rite-p10-scratch.XXXXXX")
p10_plain=$(mktemp -d "${TMPDIR:-/tmp}/rite-p10-plain.XXXXXX")
p10_main=$(cd "$p10_main" && pwd -P)
p10_scratch=$(cd "$p10_scratch" && pwd -P)
p10_plain=$(cd "$p10_plain" && pwd -P)
p10_wt="$p10_main/.rite/worktrees/issue-1"
p10_sid="p10-session"
git -C "$p10_main" init -q
git -C "$p10_main" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m init
git -C "$p10_main" worktree add -q --detach "$p10_wt" 2>/dev/null
mkdir -p "$p10_main/.rite/sessions" "$p10_plain/.rite/sessions"
jq -n --arg wt "$p10_wt" '{active: true, worktree: $wt}' > "$p10_main/.rite/sessions/$p10_sid.flow-state"
jq -n '{active: false}' > "$p10_main/.rite/sessions/p10-inactive.flow-state"
printf 'not json\n' > "$p10_main/.rite/sessions/p10-broken.flow-state"
jq -n '{active: true}' > "$p10_plain/.rite/sessions/$p10_sid.flow-state"

# p10_run <cwd> <command> [session] — the hook with the fixture state root.
p10_run() {
  # The command goes through stdin: a long one does not fit in an argument.
  printf '%s' "$2" | jq -Rs --arg cwd "$1" --arg sid "${3:-$p10_sid}" \
    '{tool_name: "Bash", tool_input: {command: .}, cwd: $cwd, session_id: $sid}' \
    | RITE_STATE_ROOT="${P10_ROOT:-$p10_main}" bash "$HOOK" 2>"$STDERR_FILE"
}
# p10_deny <label> <pattern> <reason substring> <cwd> <command> [session]
p10_deny() {
  local rc=0 output reason
  output=$(p10_run "$4" "$5" "${6:-}") || rc=$?
  reason=$(extract_hook_field "$output" permissionDecisionReason)
  if [ "$(extract_hook_field "$output" permissionDecision)" = "deny" ] \
    && [[ "$reason" == "BLOCKED ($2): "* && "$reason" == *"$3"* ]]; then
    pass "$1"
  else
    fail "$1: expected BLOCKED ($2) with '$3', got rc=$rc reason=$reason"
  fi
}
# p10_allow <label> <cwd> <command> [session]
p10_allow() {
  local rc=0 output
  output=$(p10_run "$2" "$3" "${4:-}") || rc=$?
  if [ "$rc" = "0" ] && [ -z "$output" ]; then
    pass "$1"
  else
    fail "$1: expected allow, got rc=$rc output=$output"
  fi
}

p10_deny "gh after cd to a scratch dir" outside-checkout "runs 'gh' in $p10_scratch, which is outside" \
  "$p10_wt" "cd $p10_scratch && gh api repos/x/y"
p10_deny "deny names the way back into the worktree" outside-checkout "cd $p10_wt && <command>" \
  "$p10_wt" "cd $p10_scratch && gh api repos/x/y"
p10_deny "script run in a scratch dir" outside-checkout "runs 'bash' in $p10_scratch" \
  "$p10_wt" "cd $p10_scratch && bash x.sh"
p10_deny "git -C to a dir outside the checkout" outside-checkout "runs 'git' in $p10_scratch/foo" \
  "$p10_wt" "git -C $p10_scratch/foo status"
p10_deny "cd to a variable before gh" outside-checkout "cannot be determined" \
  "$p10_wt" 'cd "$D" && gh api x'
p10_deny "gh from a hook cwd left in a scratch dir" outside-checkout "runs 'gh' in $p10_scratch" \
  "$p10_scratch" "gh api repos/x/y"
p10_deny "script from a hook cwd left in a scratch dir" outside-checkout "runs 'bash' in $p10_scratch" \
  "$p10_scratch" "bash x.sh"
p10_deny "script behind timeout" outside-checkout "runs 'bash' in $p10_scratch" \
  "$p10_wt" "cd $p10_scratch && timeout 5 bash x.sh"
p10_deny "script by path behind env" outside-checkout "runs './x.sh' in $p10_scratch" \
  "$p10_wt" "cd $p10_scratch && env A=1 ./x.sh"
p10_deny "gh in a subshell after its cd" outside-checkout "runs 'gh' in $p10_scratch" \
  "$p10_wt" "(cd $p10_scratch && gh api x)"
p10_deny "git -C to a variable after cd to a scratch dir" outside-checkout "runs 'git' in $p10_scratch" \
  "$p10_wt" "cd $p10_scratch && git -C \"\$X\" status"
p10_deny "a literal variable cd to a scratch dir" outside-checkout "runs 'git' in $p10_scratch" \
  "$p10_wt" "d=$p10_scratch; if [ -z \"\$d\" ] || ! cd \"\$d\" 2>/dev/null; then echo no; else git status; fi"
p10_deny "more cd than the parser follows" outside-checkout "cannot be determined" \
  "$p10_wt" "$(printf 'cd . && %.0s' $(seq 1 17))git status"
p10_deny "unreadable flow-state is checked as active" outside-checkout "runs 'gh' in $p10_scratch" \
  "$p10_wt" "cd $p10_scratch && gh api x" p10-broken
p10_allow "script in a scratch dir run from the worktree" "$p10_wt" "cd $p10_wt && bash $p10_scratch/x.sh"
p10_allow "script in a scratch dir, hook cwd in the worktree" "$p10_wt" "bash $p10_scratch/x.sh"
p10_allow "git in the worktree" "$p10_wt" "git status"
p10_allow "cd into the worktree then git" "$p10_wt" "cd $p10_wt && git status"
p10_allow "git -C the worktree" "$p10_scratch" "git -C $p10_wt status"
p10_allow "cd into the main checkout then gh" "$p10_scratch" "cd $p10_main && gh api x"
p10_allow "git -C a variable from the worktree" "$p10_wt" 'git -C "$X" status'
p10_allow "a literal variable cd into the main checkout" "$p10_wt" \
  "d=$p10_main; if [ -z \"\$d\" ] || ! cd \"\$d\" 2>/dev/null; then echo no; else git status; fi"
p10_allow "no git, gh or script in a scratch dir" "$p10_wt" "cd $p10_scratch && ls && cat a > b"
p10_allow "a cd kept inside its subshell" "$p10_wt" "(cd $p10_scratch && ls); gh api x"
p10_allow "heredoc text is not a command" "$p10_wt" \
  "$(printf 'cat > %s/b.md <<%s\ncd /tmp && gh api x\nEOF' "$p10_scratch" "'EOF'")"
p10_allow "no flow-state for the session" "$p10_wt" "cd $p10_scratch && gh api x" p10-none
p10_allow "an inactive flow-state" "$p10_wt" "cd $p10_scratch && gh api x" p10-inactive
P10_ROOT="$p10_plain" p10_allow "a state root that is not a repository" "$p10_scratch" "gh api x"
# The state root comes from CLAUDE_PROJECT_DIR when RITE_STATE_ROOT is unset.
rc=0
output=$(jq -n --arg cmd "gh api x" --arg cwd "$p10_scratch" --arg sid "$p10_sid" \
  '{tool_name: "Bash", tool_input: {command: $cmd}, cwd: $cwd, session_id: $sid}' \
  | CLAUDE_PROJECT_DIR="$p10_wt" bash "$HOOK" 2>"$STDERR_FILE") || rc=$?
if [[ "$(extract_hook_field "$output" permissionDecisionReason)" == "BLOCKED (outside-checkout): "* ]]; then
  pass "state root resolved from CLAUDE_PROJECT_DIR"
else
  fail "state root resolved from CLAUDE_PROJECT_DIR: got rc=$rc output=$output"
fi
p10_deny "an earlier pattern keeps its reason" gh-pr-diff-stat "--stat" \
  "$p10_wt" "cd $p10_scratch && gh pr diff 1 --stat"
p10_deny "gh in a long command" outside-checkout "runs 'gh' in $p10_scratch" \
  "$p10_wt" "echo $(printf 'x%.0s' $(seq 1 9000)) && cd $p10_scratch && gh api x"
RITE_BTG_TEST_CRASH=pattern10-helper p10_deny "a failed check denies" outside-checkout-uninspectable "rc=3" \
  "$p10_wt" "cd $p10_scratch && ls"
p10_deny "gh after pushd to a scratch dir" outside-checkout "cannot be determined" \
  "$p10_wt" "pushd $p10_scratch && gh api x"
p10_deny "script after pushd to a scratch dir" outside-checkout "cannot be determined" \
  "$p10_wt" "pushd $p10_scratch >/dev/null; bash x.sh"
p10_deny "gh behind env --chdir" outside-checkout "runs 'gh' in $p10_scratch" \
  "$p10_wt" "env --chdir=$p10_scratch gh api x"
p10_deny "gh behind env -C" outside-checkout "runs 'gh' in $p10_scratch" \
  "$p10_wt" "env -C $p10_scratch gh api x"
p10_deny "gh behind timeout with a signal option" outside-checkout "runs 'gh' in $p10_scratch" \
  "$p10_wt" "cd $p10_scratch && timeout -s KILL 5 gh api x"
p10_deny "gh behind env -u" outside-checkout "runs 'gh' in $p10_scratch" \
  "$p10_wt" "cd $p10_scratch && env -u HOME gh api x"
p10_deny "git -C after another global option" outside-checkout "runs 'git' in $p10_scratch" \
  "$p10_wt" "git -P -C $p10_scratch status"
p10_deny "a variable reassigned inside if" outside-checkout "cannot be determined" \
  "$p10_wt" "d=$p10_wt; if true; then d=$p10_scratch; fi; cd \"\$d\" && gh api x"
p10_deny "a variable reassigned by export" outside-checkout "cannot be determined" \
  "$p10_wt" "d=$p10_wt; export d=$p10_scratch; cd \"\$d\" && gh api x"
p10_allow "cd into a directory made in the same command" "$p10_wt" \
  "mkdir -p $p10_wt/new && cd $p10_wt/new && git status"
p10_allow "a cd kept inside the first of two subshells" "$p10_wt" "(cd $p10_scratch && ls); (gh api x)"
p10_allow "a cd kept inside an inner subshell" "$p10_wt" "( (cd $p10_scratch); gh api x )"
p10_allow "a long command that runs no git, gh or script" "$p10_scratch" \
  "echo $(printf 'x%.0s' $(seq 1 9000)) > out.txt"
p10_deny "gh in a substitution after a cd in its subshell" outside-checkout "runs 'gh' in $p10_scratch" \
  "$p10_wt" "(cd $p10_scratch && echo \$(gh api x))"
p10_deny "script in a substitution after a cd in its subshell" outside-checkout "runs 'bash' in $p10_scratch" \
  "$p10_wt" "(cd $p10_scratch; x=\$(bash rec.sh))"
p10_allow "a substitution after a closed subshell" "$p10_wt" "(cd $p10_scratch); echo \$(gh api x)"
p10_deny "gh in an inner subshell after the outer subshell's cd" outside-checkout "runs 'gh' in $p10_scratch" \
  "$p10_wt" "(cd $p10_scratch; (gh api x))"
p10_deny "gh after a cd that may fail" outside-checkout "runs 'gh' in $p10_scratch" \
  "$p10_scratch" "cd $p10_wt/missing; gh api x"
p10_deny "a command behind env -S" outside-checkout "cannot be determined" \
  "$p10_wt" "env -S '-C $p10_scratch gh api x'"
p10_deny "gh behind sudo -D" outside-checkout "runs 'gh' in $p10_scratch" \
  "$p10_wt" "sudo -D $p10_scratch gh api x"
p10_deny "gh behind xargs -I" outside-checkout "runs 'gh' in $p10_scratch" \
  "$p10_wt" "cd $p10_scratch && xargs -I {} gh api {}"
p10_deny "gh behind a joined env -u" outside-checkout "runs 'gh' in $p10_scratch" \
  "$p10_wt" "cd $p10_scratch && env -uHOME gh api x"
p10_deny "gh after popd" outside-checkout "cannot be determined" "$p10_wt" "popd; gh api x"
p10_deny "a variable reassigned by read" outside-checkout "cannot be determined" \
  "$p10_wt" "d=$p10_wt; read d; cd \"\$d\" && gh api x"
p10_deny "a variable reassigned by for" outside-checkout "cannot be determined" \
  "$p10_wt" "d=$p10_wt; for d in $p10_scratch; do cd \"\$d\" && gh api x; done"
p10_long=$(printf 'x%.0s' $(seq 1 9000))
p10_out="in $p10_scratch, which is outside the checkout"
p10_deny "a long command that runs a script by path" outside-checkout "$p10_out" \
  "$p10_wt" "echo $p10_long > $p10_scratch/body.txt; cd $p10_scratch && $p10_scratch/record"
p10_deny "a long command that runs a script by variable" outside-checkout "$p10_out" \
  "$p10_wt" "echo $p10_long > $p10_scratch/body.txt; cd $p10_scratch && \"\$runner\""
p10_allow "a long heredoc that mentions git and gh" "$p10_scratch" \
  "$(printf 'cat > out.md <<%s\n%s\nEOF' "'EOF'" "$(printf 'Run git status then gh pr view. %.0s' $(seq 1 300))")"
p10_prose=$(printf "Don't run git status then gh pr view. %.0s" $(seq 1 300))
p10_deny "gh after a long heredoc" outside-checkout "runs 'gh' $p10_out" \
  "$p10_wt" "$(printf 'cat > %s/o.md <<%s\n%s\nEOF\ncd %s && gh api x' "$p10_scratch" "'EOF'" "$p10_prose" "$p10_scratch")"
p10_deny "a script after a heredoc with a hyphenated delimiter" outside-checkout "runs './rec.sh' $p10_out" \
  "$p10_wt" "$(printf 'cat > %s/o.md <<%s\n%s\nPR-BODY\ncd %s && ./rec.sh' "$p10_scratch" "'PR-BODY'" "$p10_prose" "$p10_scratch")"
p10_deny "gh after a tab-indented heredoc delimiter" outside-checkout "runs 'gh' $p10_out" \
  "$p10_wt" "$(printf 'cat > %s/o.md <<-%s\n\t%s\n\tEOF\ncd %s && gh api x' "$p10_scratch" "'EOF'" "$p10_prose" "$p10_scratch")"
p10_deny "gh after a << inside a string" outside-checkout "runs 'gh' $p10_out" \
  "$p10_wt" "$(printf 'printf %s > %s/a.c\ncd %s && gh api x' "'mask = 1 << bit'" "$p10_scratch" "$p10_scratch")"
p10_deny "gh between a << in a string and a heredoc it names" outside-checkout "runs 'gh' $p10_out" \
  "$p10_wt" "$(printf 'echo %s\ncd %s && gh api x\ncat > %s/o.md <<%s\n%s\nEOF' "'Use cat <<EOF for long text'" "$p10_scratch" "$p10_scratch" "'EOF'" "$p10_prose")"
p10_deny "gh after a shift in arithmetic" outside-checkout "runs 'gh' $p10_out" \
  "$p10_wt" "echo \$((1<<2)) && cd $p10_scratch && gh api x"
p10_deny "a heredoc that does not end" outside-checkout-uninspectable "does not end" \
  "$p10_scratch" "$(printf 'cat > out.md <<EOF\nhello')"
p10_deny "gh before a heredoc that does not end" outside-checkout-uninspectable "does not end" \
  "$p10_wt" "$(printf 'cd %s && gh api x && cat <<EOF\nhello' "$p10_scratch")"
p10_deny "gh in a substitution of an unquoted heredoc body" outside-checkout-uninspectable "runs a command substitution" \
  "$p10_wt" "$(printf 'cd %s && cat > n.md <<EOF\n$(gh api user)\nEOF' "$p10_scratch")"
p10_deny "gh in an unquoted heredoc body of a message substitution" outside-checkout-uninspectable "runs a command substitution" \
  "$p10_wt" "$(printf 'cd %s && echo "$(cat <<EOF\n$(gh api user)\nEOF\n)"' "$p10_scratch")"
p10_allow "a substitution in a quoted heredoc body is text" "$p10_scratch" \
  "$(printf 'cat > n.md <<%s\n$(gh api user)\nEOF' "'EOF'")"
p10_allow "a substitution after a backslash-quoted delimiter is text" "$p10_scratch" \
  "$(printf 'cat > n.md <<\\EOF\n$(gh api user)\nEOF')"
p10_allow "escaped substitutions in an unquoted heredoc body are text" "$p10_scratch" \
  "$(printf 'cat > pr.md <<EOF\nRun \\`git status\\` and \\$(gh pr view).\nEOF')"
p10_deny "a substitution after an escaped backslash in an unquoted body" outside-checkout-uninspectable "runs a command substitution" \
  "$p10_scratch" "$(printf 'cat > n.md <<EOF\n\\\\$(date)\nEOF')"
p10_deny "gh after a << inside a parameter expansion" outside-checkout "runs 'gh' $p10_out" \
  "$p10_wt" "$(printf 's=a; echo ${s//<</x}\ncd %s && gh api x' "$p10_scratch")"
p10_deny "gh after a comment right after a group" outside-checkout "runs 'gh' $p10_out" \
  "$p10_wt" "$(printf '(true)# use <<EOF\ncd %s && gh api x' "$p10_scratch")"
p10_deny "gh after a comment behind an escaped backslash" outside-checkout "runs 'gh' $p10_out" \
  "$p10_wt" "$(printf 'echo a\\\\ #note <<EOF\ncd %s && gh api x' "$p10_scratch")"
p10_allow "a comment with a quote inside a multi-line substitution" "$p10_scratch" \
  "$(printf "x=\$(\n  # don't\n  echo a\n)\nls")"
p10_allow "a # inside a word before a heredoc" "$p10_scratch" \
  "$(printf "echo a#b; cat > n.md <<'EOF'\ngh pr view\nEOF")"
p10_deny "gh after a URL fragment" outside-checkout "runs 'gh' $p10_out" \
  "$p10_wt" "echo https://e/x#frag; cd $p10_scratch && gh api x"
p10_deny "a case command inside a substitution" outside-checkout-uninspectable "case command" \
  "$p10_wt" "cd $p10_scratch && echo \"\$(case \"\$k\" in pr) gh pr view 1;; esac)\""
p10_allow "the word case inside a substitution" "$p10_scratch" "echo \$(echo a test case here)"
p10_deny "arithmetic in an unquoted heredoc body" outside-checkout-uninspectable "runs a command substitution" \
  "$p10_scratch" "$(printf 'cat > n.md <<EOF\n$((1+2)) items\nEOF')"
p10_allow "an unquoted heredoc body without a substitution" "$p10_scratch" \
  "$(printf 'cat > n.md <<EOF\nHome is $HOME, 100%%\nEOF')"
p10_deny "a backquote in an unquoted heredoc body" outside-checkout-uninspectable "runs a command substitution" \
  "$p10_scratch" "$(printf 'cat > n.md <<EOF\nnow `date`\nEOF')"
p10_deny "the denial of an unquoted body names the quoted delimiter" outside-checkout-uninspectable "<<'EOF'" \
  "$p10_scratch" "$(printf 'cat > n.md <<EOF\nnow $(date)\nEOF')"
p10_allow "an unquoted body run in the checkout without a cd" "$p10_wt" \
  "$(printf 'cat > n.md <<EOF\n$(git rev-parse HEAD)\nEOF')"
p10_deny "an unquoted body is denied with a cd into the checkout" outside-checkout-uninspectable "runs a command substitution" \
  "$p10_wt" "$(printf 'cd %s && cat > n.md <<EOF\n$(git rev-parse HEAD)\nEOF' "$p10_wt")"
p10_allow "a value assigned before the heredoc, as the denial advises" "$p10_wt" \
  "$(printf 'cd %s && v=$(date) && cat > n.md <<EOF\nnow $v\nEOF' "$p10_scratch")"
p10_deny "a case command after ; inside a substitution" outside-checkout-uninspectable "case command" \
  "$p10_wt" "cd $p10_scratch && echo \"\$(true; case \"\$k\" in pr) gh pr view 1;; esac)\""
p10_deny "a case command after then inside a substitution" outside-checkout-uninspectable "case command" \
  "$p10_wt" "cd $p10_scratch && echo \"\$(if true; then case \"\$k\" in pr) gh pr view 1;; esac; fi)\""
p10_deny "a denied body names the variable rewrite and that a cd does not help" outside-checkout-uninspectable \
  'write $v in the body. Rewrite the command' "$p10_wt" "$(printf 'cd %s && cat > n.md <<EOF\n$(date)\nEOF' "$p10_wt")"
p10_deny "the rewrite alternative says a cd is denied the same way" outside-checkout-uninspectable \
  "adding a cd into the checkout, or running it from outside" "$p10_wt" "$(printf 'cd %s && cat > n.md <<EOF\n$(date)\nEOF' "$p10_wt")"
p10_deny "a denied case names the rewrite and that a cd does not help" outside-checkout-uninspectable \
  "set the variable in its branches. Rewrite the command" \
  "$p10_wt" "cd $p10_scratch && echo \"\$(case \"\$k\" in pr) gh pr view 1;; esac)\""
p10_allow "a case moved out of the substitution, as the denial advises" "$p10_wt" \
  "cd $p10_wt && case \"\$k\" in pr) v=\$(git rev-parse HEAD);; esac; echo \"\$v\""
p10_deny "a heredoc that does not end names the fix, not a cd" outside-checkout-uninspectable \
  "end each heredoc at its delimiter line" "$p10_wt" "$(printf 'cd %s && cat > n.md <<EOF\nhello' "$p10_wt")"
p10_unfinished=$(p10_run "$p10_wt" "$(printf 'cd %s && cat > n.md <<EOF\nhello' "$p10_wt")") || true
p10_unfinished=$(extract_hook_field "$p10_unfinished" permissionDecisionReason)
if [[ "$p10_unfinished" == *"delimiter EOF. Fix the command"* && "$p10_unfinished" == *"adding a cd into the checkout is denied the same way."* \
  && "$p10_unfinished" != *"first."* ]]; then
  pass "a heredoc that does not end ends its reason and does not advise a cd first"
else
  fail "a heredoc that does not end ends its reason and does not advise a cd first: got $p10_unfinished"
fi
p10_deny "a heredoc operator at the end of the command ends its reason" outside-checkout-uninspectable \
  "delimiter EOF. Fix the command" "$p10_scratch" "cat > out.md <<EOF"
p10_deny "a heredoc without a delimiter ends its reason" outside-checkout-uninspectable \
  "a heredoc has no delimiter. Fix the command" "$p10_scratch" "cat > out.md <<"
p10_deny "a quote that does not end ends its reason" outside-checkout-uninspectable \
  "a quote or substitution does not end. Fix the command" "$p10_scratch" "cd $p10_scratch && echo \"abc"
p10_deny "gh after a # inside a word" outside-checkout "runs 'gh' $p10_out" \
  "$p10_wt" "x=abc; echo \${#x}; cd $p10_scratch && gh api x"
p10_deny "gh after a # right after a substitution" outside-checkout "runs 'gh' $p10_out" \
  "$p10_wt" "echo \$(pwd)#x; cd $p10_scratch && gh api x"
p10_deny "gh after an escaped space and #" outside-checkout "runs 'gh' $p10_out" \
  "$p10_wt" "cp notes\\ #1.md $p10_scratch/ && cd $p10_scratch && gh api x"
p10_deny "gh after a comment that mentions a heredoc" outside-checkout "runs 'gh' $p10_out" \
  "$p10_wt" "$(printf '# use cat <<EOF here\ncd %s && gh api x' "$p10_scratch")"
p10_deny "gh after a here-string" outside-checkout "runs 'gh' $p10_out" \
  "$p10_wt" "grep -q x <<< \"\$v\" && cd $p10_scratch && gh api x"
p10_deny "gh after a << in a double-quoted string" outside-checkout "runs 'gh' $p10_out" \
  "$p10_wt" "echo \"a << b\"; cd $p10_scratch && gh api x"
p10_deny "a script in a function body" outside-checkout "runs './rec.sh' $p10_out" \
  "$p10_wt" "cd $p10_scratch && f() { ./rec.sh; }; f"
p10_huge=$(printf 'Run cd into the worktree and write notes. %.0s' $(seq 1 3500))
p10_allow "a heredoc longer than one argument may be" "$p10_scratch" \
  "$(printf 'cat > big.md <<%s\n%s\nEOF' "'EOF'" "$p10_huge")"
p10_deny "gh after a heredoc longer than one argument may be" outside-checkout "runs 'gh' $p10_out" \
  "$p10_wt" "$(printf 'cat > %s/big.md <<%s\n%s\nEOF\ncd %s && gh api x' "$p10_scratch" "'EOF'" "$p10_huge" "$p10_scratch")"
p10_allow "a heredoc with a backslashed delimiter that mentions git and gh" "$p10_scratch" \
  "$(printf 'cat > out.md <<\\EOF\n%s\nEOF' "$p10_prose")"
p10_allow "a heredoc with a hyphenated delimiter that mentions git and gh" "$p10_scratch" \
  "$(printf 'cat > out.md <<%s\n%s\nPR-BODY' "'PR-BODY'" "$p10_prose")"
p10_allow "a tab-indented heredoc that mentions git and gh" "$p10_scratch" \
  "$(printf 'cat > out.md <<-%s\n\t%s\n\tEOF' "'EOF'" "$p10_prose")"
p10_deny "a script after then" outside-checkout "runs './rec.sh' $p10_out" \
  "$p10_wt" "cd $p10_scratch && if true; then ./rec.sh; fi"
p10_deny "a variable run after do" outside-checkout "$p10_out" \
  "$p10_wt" "cd $p10_scratch && for f in a; do \"\$runner\"; done"
p10_deny "a script in braces" outside-checkout "runs './rec.sh' $p10_out" \
  "$p10_wt" "cd $p10_scratch && { ./rec.sh; }"
p10_deny "a script in a case branch" outside-checkout "runs './rec.sh' $p10_out" \
  "$p10_wt" "cd $p10_scratch && case x in x) ./rec.sh;; esac"
p10_deny "a script after a quoted assignment" outside-checkout "runs './rec.sh' $p10_out" \
  "$p10_wt" "cd $p10_scratch && MSG=\"two words\" ./rec.sh"
p10_deny "a script after a redirection" outside-checkout "runs './rec.sh' $p10_out" \
  "$p10_wt" "cd $p10_scratch && 2>/dev/null ./rec.sh"
p10_deny "a variable run behind timeout" outside-checkout "$p10_out" \
  "$p10_wt" "cd $p10_scratch && timeout 5 \"\$runner\""
p10_deny "a sourced file" outside-checkout "runs '.' $p10_out" \
  "$p10_wt" "cd $p10_scratch && . rec"
p10_allow "a long prose line with wrapper words" "$p10_scratch" \
  "echo \"$p10_long the time is now; run this command with env set (time permitting)\" > out.txt"
p10_allow "a multi-line string with wrapper words at line starts" "$p10_scratch" \
  "$(printf 'echo "%s\nenv var is set\ntime to go" > out.txt' "$p10_long")"
p10_allow "backquotes in a single-quoted text" "$p10_wt" \
  "printf '%s\n' '$p10_long see \`plugins/x.md\` then cd back' > $p10_scratch/notes.md"
p10_broken=$(mktemp -d "${TMPDIR:-/tmp}/rite-p10-broken.XXXXXX")
printf 'gitdir: %s/missing\n' "$p10_broken" > "$p10_broken/.git"
mkdir -p "$p10_broken/.rite/sessions"
jq -n '{active: true}' > "$p10_broken/.rite/sessions/$p10_sid.flow-state"
# A git that fails with a command as its last line, as git does for a repository it does not trust.
p10_failgit=$(mktemp -d "${TMPDIR:-/tmp}/rite-p10-failgit.XXXXXX")
printf '#!/bin/bash\nfor a; do [ "$a" = --path-format=absolute ] && { printf "fatal: cannot read\\n\\tgit config --global --add safe.directory %%s\\n" "%s" >&2; exit 128; }; done\nexec %s "$@"\n' \
  "$p10_main" "$(command -v git)" > "$p10_failgit/git"
chmod +x "$p10_failgit/git"
PATH="$p10_failgit:$PATH" p10_deny "a git that cannot read the checkout names its own error" outside-checkout-uninspectable \
  "git cannot read the checkout at $p10_main. git reports:"$'\n'"fatal: cannot read" "$p10_scratch" "cd $p10_scratch && gh api x"
PATH="$p10_failgit:$PATH" p10_deny "a command git reports is left as is, with the fix on its own line" outside-checkout-uninspectable \
  $'\tgit config --global --add safe.directory '"$p10_main"$' \nFix why git cannot read the checkout (the error git reports above)' \
  "$p10_scratch" "cd $p10_scratch && gh api x"
rm -rf "$p10_failgit"
P10_ROOT="$p10_broken" p10_deny "a state root git cannot read names the git fix" outside-checkout-uninspectable \
  "Fix why git cannot read the checkout" "$p10_wt" "cd $p10_scratch && gh api x"
P10_ROOT="$p10_broken" p10_deny "a state root git cannot read" outside-checkout-uninspectable "git cannot read the checkout at $p10_broken. git reports:"$'\n'"fatal" \
  "$p10_wt" "cd $p10_scratch && gh api x"
rm -rf "$p10_main" "$p10_scratch" "$p10_plain" "$p10_broken"
# The skills' own bash blocks run during a session, from the checkout. Placeholders
# stand for paths in the checkout, so none of them may be denied.
p10_repo=$(cd "$SCRIPT_DIR/../../../.." && pwd -P)
rc=0
p10_corpus=$(python3 - "$SCRIPT_DIR/../scripts/lib" "$p10_repo" <<'EOF'
import importlib, re, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
cwd = importlib.import_module("checkout-cwd")
repo = Path(sys.argv[2])
checkout = cwd.common_dir(repo)
fence = re.compile(r"^(\s*)```(?:bash|sh)\s*$")
blocks = 0
for md in sorted([*repo.glob("plugins/rite/skills/**/*.md"), *repo.glob("plugins/rite/references/**/*.md")]):
    lines = md.read_text().splitlines()
    index = 0
    while index < len(lines):
        opened = fence.match(lines[index])
        index += 1
        if not opened:
            continue
        start, body = index, []
        while index < len(lines) and not re.match(r"^\s*```\s*$", lines[index]):
            body.append(lines[index][len(opened.group(1)):])
            index += 1
        blocks += 1
        command = re.sub(r"\{[a-z_0-9]+\}", str(repo), "\n".join(body))
        for kind, directories, word in cwd.each_call(command, repo):
            if directories is None or any(cwd.common_dir(d) != checkout for d in directories):
                print(f"{md.relative_to(repo)}:{start}: {word} in {directories}")
print(f"blocks={blocks}")
EOF
) || rc=$?
if [ "$rc" = "0" ] && [[ "$p10_corpus" =~ ^blocks=[1-9][0-9]*$ ]]; then
  pass "no skill or reference bash block is denied ($p10_corpus)"
else
  fail "skill or reference bash blocks denied (rc=$rc): $p10_corpus"
fi
echo ""

# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
