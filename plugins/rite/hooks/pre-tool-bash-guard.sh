#!/bin/bash
# rite workflow - Pre-Tool Bash Guard (PreToolUse hook)
# Blocks known-bad Bash command patterns before execution.
# Uses only Bash built-ins for pattern matching (no external processes).
#
# Denylist patterns:
#   1. gh pr diff --stat  (unsupported flag)
#   2. gh pr diff -- <path>  (unsupported file filter)
#   3. != null in jq/awk  (history expansion breaks !)
#   4. Reviewer subagent running state-mutating git commands (Issue #442)
#      Enforced only when transcript_path contains "/subagents/".
#
# Exit behavior:
#   exit 0 — allow (no output)
#   stdout JSON with permissionDecision: "deny" — block
set -euo pipefail

# Double-execution guard (hooks.json + settings.local.json migration)
[ -z "${_RITE_HOOK_RUNNING_PRETOOL:-}" ] || exit 0
export _RITE_HOOK_RUNNING_PRETOOL=1

# Hook version resolution preamble (must be before INPUT=$(cat) to preserve stdin)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/hook-preamble.sh" 2>/dev/null || true

# cat failure does not abort under set -e; || guard is defensive
INPUT=$(cat) || INPUT=""

# Only inspect Bash tool calls
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null) || TOOL_NAME=""
if [ "$TOOL_NAME" != "Bash" ]; then
  exit 0
fi

COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null) || COMMAND=""
if [ -z "$COMMAND" ]; then
  exit 0
fi

# Reviewer subagent detection (Issue #442).
# Claude Code routes subagent sessions to jsonl files under a "subagents/"
# directory inside the project transcript root; the main session does not.
# When the PreToolUse hook runs inside a subagent, transcript_path therefore
# contains the "/subagents/" path component. Pattern 4 below uses this as a
# heuristic to scope state-mutating git denylist checks to reviewer contexts.
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null) || TRANSCRIPT_PATH=""
IS_SUBAGENT=0
case "$TRANSCRIPT_PATH" in
  */subagents/*) IS_SUBAGENT=1 ;;
esac

# --- Fail-open for pattern matching stage ---
# If heredoc extraction or pattern matching crashes (e.g., edge-case failures with
# large multiline input), allow the command rather than blocking it.
# Placed after JSON parsing (which has its own || fallbacks) to preserve
# error detection for malformed hook input (TC-016).
trap 'exit 0' ERR

# --- Heredoc-safe command extraction ---
# Strip heredoc content to avoid false positives on text inside commit messages,
# PR descriptions, etc. Only check the command prefix before the first heredoc marker.
# Known limitation: Piped heredoc patterns (e.g., `cat <<EOF | gh pr diff`) bypass
# this stripping because the command before `<<` is `cat`, not the target pattern.
# Risk is limited since such patterns are rare in practice.
CMD_CHECK="${COMMAND%%<<*}"

# --- Denylist check (Bash built-ins only) ---

BLOCKED_PATTERN=""
BLOCKED_REASON=""
BLOCKED_ALTERNATIVE=""

# Pattern 1: gh pr diff --stat
case "$CMD_CHECK" in
  *"gh pr diff"*" --stat"*)
    BLOCKED_PATTERN="gh-pr-diff-stat"
    BLOCKED_REASON="gh pr diff does not support the --stat flag."
    BLOCKED_ALTERNATIVE="Use: gh pr view {pr_number} --json files --jq '.files[] | {path, additions, deletions}'"
    ;;
esac

# Pattern 2: gh pr diff -- <path> (file filter)
if [ -z "$BLOCKED_PATTERN" ]; then
  if [[ "$CMD_CHECK" =~ gh[[:space:]]+pr[[:space:]]+diff[[:space:]]+[^|]+[[:space:]]--[[:space:]] ]]; then
    BLOCKED_PATTERN="gh-pr-diff-file-filter"
    BLOCKED_REASON="gh pr diff does not support -- <path> for per-file filtering."
    BLOCKED_ALTERNATIVE="Use: gh pr diff {pr_number} | awk '/^diff --git/ { found=0 } /^diff --git.*target_pattern/ { found=1 } found { print }'"
  fi
fi

# Pattern 3: != null in jq expressions (history expansion breaks !)
if [ -z "$BLOCKED_PATTERN" ]; then
  case "$CMD_CHECK" in
    *'!= null'*|*'!=null'*)
      BLOCKED_PATTERN="jq-not-equal-null"
      BLOCKED_REASON="!= null causes bash history expansion errors. The ! character is interpreted by bash before reaching jq."
      BLOCKED_ALTERNATIVE="Use: select(.field) for truthiness check, or select(.field == null | not) for explicit null exclusion"
      ;;
  esac
fi

# Pattern 4: Reviewer subagent running state-mutating git commands (Issue #442).
# Scope: only when IS_SUBAGENT=1 (transcript_path contains "/subagents/").
# Main-session git operations (branch switch, commit, etc. performed by
# /rite:issue:start Phase 5.1) are NOT affected because IS_SUBAGENT=0 there.
#
# Allowed read-only git commands (not matched below): git diff, git log,
# git show, git blame, git status, git ls-files, git ls-remote, git rev-parse,
# git cat-file, git worktree add, git fetch (without --prune).
#
# Denylist below targets state-mutating forms only. Pattern uses strict word
# boundaries to avoid matching unrelated tokens (e.g. "git-checkout" in a
# file name embedded in a grep command).
if [ -z "$BLOCKED_PATTERN" ] && [ "$IS_SUBAGENT" = "1" ]; then
  # Normalize whitespace sequences into a single space for robust matching.
  # Use Bash built-in parameter expansion instead of external sed.
  CMD_NORMALIZED="${CMD_CHECK//$'\t'/ }"
  while [[ "$CMD_NORMALIZED" == *"  "* ]]; do
    CMD_NORMALIZED="${CMD_NORMALIZED//  / }"
  done

  # Each element matches `git <verb>` preceded by line start or whitespace
  # and followed by whitespace/end. The wrapping space ensures word boundaries.
  PADDED=" $CMD_NORMALIZED "
  case "$PADDED" in
    *" git checkout "*|\
    *" git reset "*|\
    *" git add "*|\
    *" git rm "*|\
    *" git stash "*|\
    *" git restore "*|\
    *" git commit "*|\
    *" git push "*|\
    *" git pull "*|\
    *" git merge "*|\
    *" git rebase "*|\
    *" git cherry-pick "*|\
    *" git revert "*|\
    *" git tag "*|\
    *" git clean "*|\
    *" git gc "*|\
    *" git reflog "*|\
    *" git worktree remove "*|\
    *" git worktree prune "*|\
    *" git branch -D "*|\
    *" git branch -d "*|\
    *" git branch -f "*|\
    *" git branch -m "*|\
    *" git branch -M "*|\
    *" git update-ref "*|\
    *" git symbolic-ref "*)
      BLOCKED_PATTERN="reviewer-state-mutating-git"
      BLOCKED_REASON="Reviewer subagents must not mutate the working tree, index, or refs. State-changing git commands (checkout/reset/add/stash/restore/commit/push/merge/rebase/cherry-pick/revert/tag/clean/branch -D/update-ref/etc.) are forbidden inside reviewer contexts."
      BLOCKED_ALTERNATIVE="Use read-only alternatives: 'git show <ref>:<file>' to read a blob, 'git diff <ref> -- <file>' to compare, or 'git worktree add <path> <ref>' to inspect a different ref in an isolated directory. See plugins/rite/agents/_reviewer-base.md (READ-ONLY Enforcement) for the full list."
      ;;
  esac
fi

# --- Result ---

if [ -z "$BLOCKED_PATTERN" ]; then
  exit 0
fi

# Log block event (stderr, for effect measurement)
CMD_SUMMARY="${COMMAND:0:80}"
CMD_SUMMARY="${CMD_SUMMARY//\"/\\\"}"
echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] bash-guard: BLOCKED pattern=$BLOCKED_PATTERN cmd=\"$CMD_SUMMARY\"" >&2

# Deny with reason and alternative
jq -n \
  --arg reason "BLOCKED ($BLOCKED_PATTERN): $BLOCKED_REASON $BLOCKED_ALTERNATIVE" \
  '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
