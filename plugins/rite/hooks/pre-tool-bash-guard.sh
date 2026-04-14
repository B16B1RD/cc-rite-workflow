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
# Single source of truth for create_* lifecycle phase names (#501 HIGH).
# Provides rite_phase_is_create_lifecycle_in_progress() used by Pattern 5.
source "$SCRIPT_DIR/phase-transition-whitelist.sh" 2>/dev/null || true

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

# Pattern 5: gh issue create direct invocation during /rite:issue:create lifecycle (#475 Mode B).
# The orchestrator (create.md) must delegate Issue creation to rite:issue:create-register or
# rite:issue:create-decompose sub-skills. A direct `gh issue create` call bypasses the entire
# sub-skill delegation protocol, flow-state tracking, and Projects integration.
#
# Detection: .rite-flow-state must exist AND be active AND the phase must be create_interview /
# create_post_interview / create_delegation / create_post_delegation (i.e., create lifecycle is
# in progress but not yet terminated by create_completed).
#
# Bypass prevention — CMD_CHECK normalization:
#   Pattern 4 normalizes shell meta-characters (;, &, |, parens, backticks, $) to spaces so that
#   `true; gh issue create` / `echo x | gh issue create` / `{gh issue create;}` all match the
#   same `gh issue create` pattern. Pattern 5 reuses this normalization via $PADDED_ALL so that
#   shell meta-char bypass vectors (`gh issue create;echo x`, `gh issue create|tee`,
#   `gh issue create&`) are all caught. Backslash line continuations (`gh \\\n  issue \\\n create`)
#   are also normalized because `\n` is replaced with space and `\` is stripped in the continuation
#   handling below.
#
# Scope exclusions (allow):
#   - no .rite-flow-state (manual gh invocation outside any workflow)
#   - .rite-flow-state exists but active=false or phase=create_completed (lifecycle finished)
#   - .rite-flow-state phase is not create_* (different workflow like /rite:issue:start)
#   - gh issue subcommands other than `create` / `cre` / `crea` / `creat` prefixes
#     (list/view/edit/close/comment/delete/pin/reopen/transfer/unpin/unlock/lock are allowed)
if [ -z "$BLOCKED_PATTERN" ]; then
  # Normalize CMD_CHECK: shell meta-chars → space, backslash-newline continuations → space,
  # then collapse multiple spaces. This reuses Pattern 4's normalization approach.
  CMD_P5="${CMD_CHECK//$'\t'/ }"
  CMD_P5="${CMD_P5//$'\n'/ }"
  CMD_P5="${CMD_P5//$'\r'/ }"
  CMD_P5="${CMD_P5//\\/ }"
  CMD_P5="${CMD_P5//;/ }"
  CMD_P5="${CMD_P5//&/ }"
  CMD_P5="${CMD_P5//|/ }"
  CMD_P5="${CMD_P5//(/ }"
  CMD_P5="${CMD_P5//)/ }"
  CMD_P5="${CMD_P5//\{/ }"
  CMD_P5="${CMD_P5//\}/ }"
  CMD_P5="${CMD_P5//\`/ }"
  CMD_P5="${CMD_P5//\$/ }"
  while [[ "$CMD_P5" == *"  "* ]]; do
    CMD_P5="${CMD_P5//  / }"
  done
  PADDED_P5=" $CMD_P5 "

  # gh subcommand prefix match: gh supports prefix shortcuts like `gh issue c` → create.
  # However `c` alone is ambiguous (matches close/comment too), and `gh` itself resolves
  # prefixes only when unambiguous. `create` is unambiguous from `cre` onwards (no other
  # `issue` subcommand starts with `cre`). Match `create` / `creat` / `crea` / `cre` as
  # trailing tokens to catch prefix shortcuts while leaving `close` / `comment` / other
  # subcommands untouched.
  if [[ "$PADDED_P5" =~ " gh issue "(create|creat|crea|cre)([[:space:]]|$) ]]; then
    CWD_FROM_INPUT=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null) || CWD_FROM_INPUT=""
    STATE_ROOT_PATH=""
    if [ -n "$CWD_FROM_INPUT" ] && [ -d "$CWD_FROM_INPUT" ]; then
      STATE_ROOT_PATH=$("$SCRIPT_DIR/state-path-resolve.sh" "$CWD_FROM_INPUT" 2>/dev/null) || STATE_ROOT_PATH="$CWD_FROM_INPUT"
    fi
    # State file lookup: if $STATE_ROOT_PATH is empty (e.g., CWD outside git repo and
    # state-path-resolve.sh failed), skip the check entirely — no state file means no
    # create lifecycle to enforce, which is the documented "allow" path.
    if [ -n "$STATE_ROOT_PATH" ]; then
      STATE_FILE_PATH="${STATE_ROOT_PATH}/.rite-flow-state"
      if [ -f "$STATE_FILE_PATH" ]; then
        STATE_PHASE=$(jq -r '.phase // empty' "$STATE_FILE_PATH" 2>/dev/null) || STATE_PHASE=""
        STATE_ACTIVE=$(jq -r '.active // false' "$STATE_FILE_PATH" 2>/dev/null) || STATE_ACTIVE="false"
        # Use query function from phase-transition-whitelist.sh as the single source of truth
        # for create_* lifecycle phase names. Fall back to inline glob check when the helper
        # is unavailable (e.g., bash < 4.2 where phase-transition-whitelist.sh exits early).
        if [ "$STATE_ACTIVE" = "true" ]; then
          if type rite_phase_is_create_lifecycle_in_progress >/dev/null 2>&1; then
            if rite_phase_is_create_lifecycle_in_progress "$STATE_PHASE"; then
              BLOCKED_PATTERN="create-lifecycle-direct-gh-issue"
            fi
          elif [[ "$STATE_PHASE" == create_* ]] && [ "$STATE_PHASE" != "create_completed" ]; then
            BLOCKED_PATTERN="create-lifecycle-direct-gh-issue"
          fi
          if [ "$BLOCKED_PATTERN" = "create-lifecycle-direct-gh-issue" ]; then
            BLOCKED_REASON="/rite:issue:create lifecycle 中 (phase=$STATE_PHASE) に gh issue create を直接実行することは禁止されています (#475 Mode B)."
            BLOCKED_ALTERNATIVE="rite:issue:create-register を呼ぶべき場面です。Phase 0.6 の Delegation Routing に従い skill: \"rite:issue:create-register\" または skill: \"rite:issue:create-decompose\" を invoke してください。"
          fi
        fi
      fi
    fi
  fi
fi

# Pattern 4: Reviewer subagent running state-mutating git commands (Issue #442).
# Scope: only when IS_SUBAGENT=1 (transcript_path contains "/subagents/").
# Main-session git operations (branch switch, commit, etc. performed by
# /rite:issue:start Phase 5.1) are NOT affected because IS_SUBAGENT=0 there.
#
# Allowed read-only git commands (NOT matched below):
#   - git diff / git log / git show / git blame / git status / git ls-files /
#     git ls-remote / git rev-parse / git cat-file
#   - git worktree add / git worktree list
#   - git fetch (bare — must NOT include --prune or --force)
#   - git branch with display-only flags: --list / --show-current / -a / -r / -v
#   - git tag -l / git tag --list
#   - git stash list / git stash show
#   - git reflog (bare list, no expire/delete)
#
# Denylist design:
#   (1) Shell meta-character boundary recognition: `;`, `&`, `|`, `(`, backtick,
#       `$` are also treated as word boundaries — prevents bypass via
#       `true;git reset` / `$(git commit)` / `(git checkout ...)` forms.
#   (2) Sub-action precision: `git tag -l` / `git stash list` / `git reflog` (bare)
#       / `git worktree list` must stay allowed. The denylist targets only
#       state-mutating sub-actions of these verbs.
#   (3) Bare new-branch creation: `git branch <name>` (without any flag) creates
#       a new ref and is therefore blocked. `git branch` and `git branch -a`
#       (display) remain allowed.
#   (4) Long-form flag coverage: `git branch --delete/--force/--move/--copy`
#       are treated the same as the short forms `-d/-f/-m/-c/-C`.
if [ -z "$BLOCKED_PATTERN" ] && [ "$IS_SUBAGENT" = "1" ]; then
  # Normalize whitespace AND shell meta-characters into a single space so that
  # `;git reset` / `(git checkout ...)` / `$(git commit)` / multi-line commands
  # are recognized as `git <verb>` with proper word boundaries.
  CMD_NORMALIZED="${CMD_CHECK//$'\t'/ }"
  CMD_NORMALIZED="${CMD_NORMALIZED//$'\n'/ }"
  CMD_NORMALIZED="${CMD_NORMALIZED//$'\r'/ }"
  CMD_NORMALIZED="${CMD_NORMALIZED//;/ }"
  CMD_NORMALIZED="${CMD_NORMALIZED//&/ }"
  CMD_NORMALIZED="${CMD_NORMALIZED//|/ }"
  CMD_NORMALIZED="${CMD_NORMALIZED//(/ }"
  CMD_NORMALIZED="${CMD_NORMALIZED//)/ }"
  CMD_NORMALIZED="${CMD_NORMALIZED//\{/ }"
  CMD_NORMALIZED="${CMD_NORMALIZED//\}/ }"
  CMD_NORMALIZED="${CMD_NORMALIZED//\`/ }"
  CMD_NORMALIZED="${CMD_NORMALIZED//\$/ }"
  # Collapse multiple spaces into one.
  while [[ "$CMD_NORMALIZED" == *"  "* ]]; do
    CMD_NORMALIZED="${CMD_NORMALIZED//  / }"
  done

  PADDED=" $CMD_NORMALIZED "

  # --- (A) Always-deny verbs (no read-only sub-action exists) ---
  case "$PADDED" in
    *" git checkout "*|\
    *" git reset "*|\
    *" git add "*|\
    *" git rm "*|\
    *" git restore "*|\
    *" git commit "*|\
    *" git push "*|\
    *" git pull "*|\
    *" git merge "*|\
    *" git rebase "*|\
    *" git cherry-pick "*|\
    *" git revert "*|\
    *" git clean "*|\
    *" git gc "*|\
    *" git prune "*|\
    *" git update-ref "*|\
    *" git symbolic-ref "*|\
    *" git am "*|\
    *" git apply "*|\
    *" git mv "*|\
    *" git notes "*|\
    *" git config "*|\
    *" git remote "*|\
    *" git bisect "*|\
    *" git filter-branch "*|\
    *" git filter-repo "*|\
    *" git replace "*)
      BLOCKED_PATTERN="reviewer-state-mutating-git"
      ;;
  esac

  # --- (B) Sub-action precision: git stash push/pop/drop/apply/clear only ---
  if [ -z "$BLOCKED_PATTERN" ]; then
    case "$PADDED" in
      *" git stash push"*|\
      *" git stash pop"*|\
      *" git stash drop"*|\
      *" git stash apply"*|\
      *" git stash clear"*|\
      *" git stash save"*|\
      *" git stash create"*|\
      *" git stash store"*|\
      *" git stash branch"*)
        BLOCKED_PATTERN="reviewer-state-mutating-git"
        ;;
    esac
  fi

  # --- (C) Sub-action precision: git tag (creation/deletion only) ---
  # Allowed: `git tag -l`, `git tag --list`, `git tag` (bare list)
  # Denied:  `git tag <name>`, `git tag -a`, `git tag -d`, `git tag --delete`,
  #          `git tag -f`, `git tag --force`
  if [ -z "$BLOCKED_PATTERN" ]; then
    case "$PADDED" in
      *" git tag -a"*|\
      *" git tag --annotate"*|\
      *" git tag -d"*|\
      *" git tag --delete"*|\
      *" git tag -f"*|\
      *" git tag --force"*|\
      *" git tag -s"*|\
      *" git tag -u"*|\
      *" git tag -m"*)
        BLOCKED_PATTERN="reviewer-state-mutating-git"
        ;;
    esac
  fi

  # --- (D) Sub-action precision: git reflog (only expire/delete block) ---
  # Allowed: `git reflog`, `git reflog show`
  # Denied:  `git reflog expire`, `git reflog delete`
  if [ -z "$BLOCKED_PATTERN" ]; then
    case "$PADDED" in
      *" git reflog expire"*|\
      *" git reflog delete"*)
        BLOCKED_PATTERN="reviewer-state-mutating-git"
        ;;
    esac
  fi

  # --- (E) Sub-action precision: git worktree remove/prune only ---
  if [ -z "$BLOCKED_PATTERN" ]; then
    case "$PADDED" in
      *" git worktree remove"*|\
      *" git worktree prune"*)
        BLOCKED_PATTERN="reviewer-state-mutating-git"
        ;;
    esac
  fi

  # --- (F) Sub-action precision: git fetch (bare allowed, --prune/--force denied) ---
  # CRITICAL: `-p` / `-f` must be matched as **standalone flag tokens**, not as
  # substrings inside branch names like `hot-fix` / `release-patch` /
  # `v1.0-rc-final` / `main-pipeline` (cycle 2 HIGH regression).
  #
  # Use a single bash regex with an optional "leading args" group:
  #   ([^[:space:]]+[[:space:]]+)*
  # This matches zero or more "non-space token + trailing spaces" — allowing
  # the flag to appear either directly after `git fetch ` or after any number
  # of positional args. The flag group `(--prune|--force|-p|-f)` requires an
  # exact token match, so branch names containing `-p`/`-f` as substrings are
  # NOT matched.
  if [ -z "$BLOCKED_PATTERN" ]; then
    if [[ "$PADDED" =~ " git fetch "([^[:space:]]+[[:space:]]+)*(--prune|--force|-p|-f)([[:space:]=]|$) ]]; then
      BLOCKED_PATTERN="reviewer-state-mutating-git"
    fi
  fi

  # --- (G) git branch: display-only flags allowed, everything else denied ---
  # Display-only flags: --list / --show-current / -a / --all / -r / --remotes /
  #                     -v / -vv / --verbose / -q / --quiet
  # Denied: -D / -d / -f / -m / -M / -c / -C / --delete / --force / --move /
  #         --copy, bare `git branch <name>` (new ref creation)
  if [ -z "$BLOCKED_PATTERN" ]; then
    # Short/long-form deletion and move flags
    case "$PADDED" in
      *" git branch -D "*|\
      *" git branch -d "*|\
      *" git branch -f "*|\
      *" git branch -m "*|\
      *" git branch -M "*|\
      *" git branch -c "*|\
      *" git branch -C "*|\
      *" git branch --delete"*|\
      *" git branch --force"*|\
      *" git branch --move"*|\
      *" git branch --copy"*|\
      *" git branch --set-upstream"*|\
      *" git branch --unset-upstream"*|\
      *" git branch --edit-description"*)
        BLOCKED_PATTERN="reviewer-state-mutating-git"
        ;;
    esac
  fi
  if [ -z "$BLOCKED_PATTERN" ]; then
    # Bare new-branch creation: `git branch <non-flag-token>` after the verb.
    # Use a bash regex to detect `git branch` followed by a token that does NOT
    # start with `-` (which would indicate a flag). Bare `git branch`
    # (no argument) and `git branch -<flag>` stay in the regex's non-match path.
    if [[ "$PADDED" =~ " git branch "[[:space:]]*[^[:space:]-] ]]; then
      BLOCKED_PATTERN="reviewer-state-mutating-git"
    fi
  fi

  if [ -n "$BLOCKED_PATTERN" ]; then
    BLOCKED_REASON="Reviewer subagents must not mutate the working tree, index, or refs. State-changing git commands (checkout/reset/add/stash push/restore/commit/push/merge/rebase/cherry-pick/revert/tag -a -d -f/clean/gc/branch -D --delete/update-ref/symbolic-ref/am/apply/mv/notes/config/remote/bisect/filter-branch/replace/reflog expire/worktree remove/fetch --prune/--force/etc.) are forbidden inside reviewer contexts."
    BLOCKED_ALTERNATIVE="Use read-only alternatives: 'git show <ref>:<file>' to read a blob, 'git diff <ref> -- <file>' to compare, 'git worktree add <path> <ref>' to inspect a different ref in an isolated directory, 'git tag -l' / 'git stash list' / 'git reflog' / 'git branch --list' for display-only queries, or bare 'git fetch' (without --prune/--force) for ref sync. See plugins/rite/agents/_reviewer-base.md (READ-ONLY Enforcement) for the full list."
  fi
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
