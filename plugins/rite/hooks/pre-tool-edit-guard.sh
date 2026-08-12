#!/bin/bash
# rite workflow - Pre-Tool Edit Guard (PreToolUse hook)
# Blocks reviewer subagents from mutating the parent working tree via the
# Edit / Write / MultiEdit / NotebookEdit tools.
#
# Why this exists:
#   The sibling `pre-tool-bash-guard.sh` guards only the Bash tool (since Issue
#   #1879 its machine gate is the .git-write path) — it does nothing about a
#   reviewer subagent that opens `Edit`/`Write` on a source file in the parent
#   working tree (observed in production: a reviewer edited an implementation
#   file in-place to run a mutation test, then hand-restored it). The prose ban
#   in `agents/_reviewer-base.md` alone does not stop LLM agents. This hook is
#   the structural enforcement layer for the Edit/Write side.
#
# Scope (all must hold to deny):
#   1. tool_name ∈ {Edit, Write, MultiEdit, NotebookEdit}
#   2. subagent context (reviewer) — same 3-tier detection as pre-tool-bash-guard.sh
#   3. the target's OWN git worktree (resolved by walking the target path up to its
#      nearest existing ancestor, then `git -C <ancestor> rev-parse`) is a real
#      parent working tree — i.e. its toplevel is NOT a sanctioned reviewer isolation
#      worktree (root named `rite-review-mutation-*` / `rite-revert-test-*`). Deciding
#      isolation on the resolved worktree root (not the raw path string) is what closes
#      the substring / `..` re-entry forgery found in review cycle 1. A write into a
#      .git directory of a non-isolation worktree also denies (review cycle 2:
#      .git/hooks/pre-commit etc. → main-session code execution). MultiEdit is included
#      even though the original technical notes listed only {Edit, Write, NotebookEdit}:
#      MultiEdit mutates files identically and omitting it would be a trivial bypass.
#
# Fail direction (mirrors pre-tool-bash-guard.sh Pattern 4):
#   - A crash BEFORE scope is confirmed (subagent + target resolved to a non-isolation
#     worktree / its .git dir) fails OPEN (exit 0 = allow) so a main-session Edit and a
#     genuine non-repo scratch write are never false-blocked.
#   - A crash AFTER scope is confirmed fails CLOSED (deny + exit 2) so a single
#     parse crash never silently bypasses the reviewer read-only guard.
#
# Exit behavior:
#   exit 0 — allow (no output)
#   stdout JSON with permissionDecision: "deny" — block
#
# hooks.json timeout: registered as PreToolUse (matcher Edit|Write|MultiEdit|
# NotebookEdit) with a 10s timeout — a fast synchronous gate using bash built-ins
# plus a couple of jq calls, aligned with the sibling lightweight gates.
set -euo pipefail

# Double-execution guard (hooks.json + settings.local.json migration parity with
# pre-tool-bash-guard.sh's _RITE_HOOK_RUNNING_PRETOOL, but a distinct var so the
# two PreToolUse hooks never suppress each other).
[ -z "${_RITE_HOOK_RUNNING_PRETOOL_EDIT:-}" ] || exit 0
export _RITE_HOOK_RUNNING_PRETOOL_EDIT=1

# Hook version resolution preamble (before INPUT=$(cat) to preserve stdin).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/hook-preamble.sh" 2>/dev/null || true
# control-char-neutralize.sh provides neutralize_ctrl, used to sanitize the byte-oriented
# RITE_DEBUG diagnostic snippet below (parity with pre-tool-bash-guard.sh, which sources it
# for the same reason). Sourced without a guard: if the helper is missing (plugin broken) the
# resulting exit is non-blocking under PreToolUse = allow, the same fail-open the sibling relies on.
source "$SCRIPT_DIR/control-char-neutralize.sh"

# Fail-OPEN ERR trap (default): any unexpected crash before scope is confirmed
# allows the tool rather than blocking it. Swapped to fail-CLOSED once the deny
# scope is confirmed (below), mirroring pre-tool-bash-guard.sh Pattern 4.
_rite_teg_fail_open() {
  if [ -n "${RITE_DEBUG:-}" ]; then
    printf '[%s] pre-tool-edit-guard: ERR trap fired before scope confirmed — allowed via fail-open\n' \
      "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
      >> "${STATE_ROOT:-/tmp}/.rite-flow-debug.log" 2>/dev/null || true
  fi
  exit 0
}
_rite_teg_fail_closed() {
  local _rc=$?
  trap - ERR  # prevent re-entrancy while emitting the deny
  echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] pre-tool-edit-guard: WARNING deny-emit crashed (rc=$_rc) — DENIED via fail-closed" >&2
  # Kind-neutral static reason: this trap fires for BOTH deny kinds (parent-tree and git-dir),
  # so it must not hardcode either — a crashed git-dir deny (RCE vector) mislabeled as parent-tree
  # would understate the block. Kept fully static (no interpolation) per the crash-handler contract.
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED (reviewer-edit): scope confirmed but deny-emit crashed; denying fail-closed to avoid bypassing the reviewer read-only guard."}}\n'
  exit 2
}
trap '_rite_teg_fail_open' ERR

# cat failure does not abort under set -e; || guard is defensive
INPUT=$(cat) || INPUT=""

# Only inspect the mutating file tools. Non-matching tools (the harness matcher
# should already pre-filter, but this defense-in-depth check survives matcher drift).
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null) || TOOL_NAME=""
case "$TOOL_NAME" in
  Edit|Write|MultiEdit|NotebookEdit) ;;
  *) exit 0 ;;
esac

# Extract target path (Edit/Write/MultiEdit use .tool_input.file_path;
# NotebookEdit uses .tool_input.notebook_path) and cwd in a single jq spawn.
JQ_OUT=$(echo "$INPUT" | jq -r '[((.tool_input.file_path // .tool_input.notebook_path) // ""), (.cwd // "")] | @tsv' 2>/dev/null) || JQ_OUT=$'\t'
FILE_PATH=$(printf '%s' "$JQ_OUT" | cut -f1)
CWD=$(printf '%s' "$JQ_OUT" | cut -f2)
# No target path → cannot scope the write to the repo; allow (fail-open). A real
# Edit/Write always carries a path, so this only trips on a malformed envelope.
[ -n "$FILE_PATH" ] || exit 0

# --- Reviewer subagent detection (3-tier) ---
# The detection LOGIC and the jq program below are the canonical copy from
# pre-tool-bash-guard.sh (Pattern 4) and are kept in sync with it: an intentional
# defense-in-depth duplication (a shared lib used by only two hooks would force a
# risky refactor of the heavily-pinned bash-guard). The `|| JQ_SA=$'\t\t'` fallback is a
# live silent-bypass path, NOT a formality: a valid-JSON envelope with a non-scalar
# `.transcript_path` (array/object) makes jq's @tsv fail at runtime, and the fallback
# then zeroes out Tier 1/2 → IS_SUBAGENT=0 → allow. So, exactly like the sibling, capture
# this jq's stderr and surface it under RITE_DEBUG so a detection-path drop is observable.
# (Do NOT add `| strings` to `.transcript_path` to swallow the error — that would diverge
# the jq program from the canonical copy and break the "keep in sync" contract.)
#   Tier 1 (primary):  transcript_path glob `*/subagents/*` — current Claude Code
#                      convention routing subagent sessions under a subagents/ dir.
#   Tier 2 (fallback): hook input JSON `subagent_type` / `agent_type` STRING field
#                      (numeric/array/object rejected via `| strings`).
#   Tier 3 (fallback): env vars CLAUDE_SUBAGENT_TYPE / CLAUDE_AGENT_TYPE (presence-only).
# Forward-compat caveat: presence-only fires on any non-empty string; if a future
# SDK emits sentinel values like "main"/"none" on main-session hooks this would
# false-positive — upgrade to an allow-list glob (e.g. `*-reviewer`) at that point.
_jq_sa_err=$(mktemp 2>/dev/null) || _jq_sa_err=""
JQ_SA=$(echo "$INPUT" | jq -r '[(.transcript_path // ""), (.subagent_type | strings // ""), (.agent_type | strings // "")] | @tsv' 2>"${_jq_sa_err:-/dev/null}") || JQ_SA=$'\t\t'
if [ -n "${RITE_DEBUG:-}" ] && [ -n "$_jq_sa_err" ] && [ -s "$_jq_sa_err" ]; then
  printf '[%s] pre-tool-edit-guard: subagent-detection jq stderr: %s\n' \
    "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
    "$(head -c 200 "$_jq_sa_err" | tr '\n' ' ' | neutralize_ctrl --c0-only)" \
    >> "${STATE_ROOT:-/tmp}/.rite-flow-debug.log" 2>/dev/null || true
fi
[ -n "$_jq_sa_err" ] && rm -f "$_jq_sa_err"
TRANSCRIPT_PATH=$(printf '%s' "$JQ_SA" | cut -f1)
INPUT_SUBAGENT_TYPE=$(printf '%s' "$JQ_SA" | cut -f2)
INPUT_AGENT_TYPE=$(printf '%s' "$JQ_SA" | cut -f3)
IS_SUBAGENT=0
case "$TRANSCRIPT_PATH" in
  */subagents/*) IS_SUBAGENT=1 ;;
esac
if [ "$IS_SUBAGENT" = "0" ] && { [ -n "$INPUT_SUBAGENT_TYPE" ] || [ -n "$INPUT_AGENT_TYPE" ]; }; then
  IS_SUBAGENT=1
fi
if [ "$IS_SUBAGENT" = "0" ] && { [ -n "${CLAUDE_SUBAGENT_TYPE:-}" ] || [ -n "${CLAUDE_AGENT_TYPE:-}" ]; }; then
  IS_SUBAGENT=1
fi
# Main session (not a reviewer subagent) → never blocked. This is the primary
# guarantee that /rite:open → implement.md Edit/Write is unaffected (AC-4).
[ "$IS_SUBAGENT" = "1" ] || exit 0

# --- Absolute path resolution (join relative against cwd, then normalize lexically) ---
# A raw substring match would let a reviewer forge an isolation path —
# `<repo>/rite-review-mutation-x/../plugins/rite/hooks.json` re-enters a tracked file, and
# `<repo>/src/rite-review-mutation-hack.py` embeds the token in a filename — both empirically
# bypassed the old substring allowlist (review cycle 1).
case "$FILE_PATH" in
  /*) ABS_PATH="$FILE_PATH" ;;
  *)  ABS_PATH="${CWD%/}/$FILE_PATH" ;;
esac

# Match the lexical normalization performed by file-writing clients before
# they open a path. Do this byte-exactly with parameter expansion: external
# dirname/readlink-style command substitutions would strip trailing LF bytes.
# Empty and "." components disappear; ".." pops one component without ever
# consulting the filesystem. Physical ownership is still resolved below by
# `[ -d ]` and `git -C`, so symlink components are not canonicalized here.
_path_rest=${ABS_PATH#/}
_path_norm=""
while :; do
  case "$_path_rest" in
    */*) _path_component=${_path_rest%%/*}; _path_rest=${_path_rest#*/}; _path_more=1 ;;
    *)   _path_component=$_path_rest; _path_rest=""; _path_more=0 ;;
  esac
  case "$_path_component" in
    ""|.) ;;
    ..) _path_norm=${_path_norm%/*} ;;
    *)  _path_norm="$_path_norm/$_path_component" ;;
  esac
  [ "$_path_more" = "1" ] || break
done
ABS_PATH=${_path_norm:-/}

# --- Dereference a FINAL-element symlink before isolation scoping (AC-2) ---
# The _tdir walk below resolves INTERMEDIATE dirs physically (via `[ -d ]` / `git -C`), but the
# target's own final element is never dereferenced. A reviewer could drop a symlink inside its
# sanctioned isolation worktree pointing at the parent repo's .git —
# `ln -s <main>/.git/hooks/pre-commit <iso>/evil` (ln is a Bash-tool op, out of THIS hook's Edit
# path) — then `Write file_path=<iso>/evil`: _tdir resolves to the isolation root → allowed, and
# the write follows the link into the parent .git. Retarget ABS_PATH at the link's destination
# here so such a write lands on the real parent .git (→ git-dir deny below) instead.
#
# The retarget is LEXICAL on purpose (`readlink` + absolutize a relative target against the
# link's own directory); it does not canonicalize intermediate symlinks. The normalized input
# has removed `.` / `..`; a relative readlink target may introduce them again, and the _tdir
# walk immediately below performs that physical resolution: `[ -d ]` and `git -C` both chdir,
# so a directory symlink or readlink target with `..` lands on the REAL tree
# that owns it. Nothing downstream needs a canonical ABS_PATH — it is only reported; the
# decision is made on TARGET_ROOT, which `git -C` produces already-resolved.
#
# Why not `realpath`: it is the one step that would need the target to EXIST.
# GNU realpath tolerates a dangling final component, BSD/macOS realpath errors on it, so the
# old `realpath "$ABS_PATH"` returned empty for exactly the attack shape above (the target
# `.git/hooks/pre-commit` normally does not exist) and this whole block silently no-op'd on
# macOS. Resolving only the target's PARENT would still no-op when that parent is itself
# not-yet-created (`<iso>/evil → <main>/src/newdir/newfile.py`), which is precisely the
# parent-tree case the walk already handles. Handing the raw target to the walk needs no
# existence check at all and behaves identically on GNU and BSD — there is no platform branch
# left to diverge.
#
# The loop follows a MULTI-HOP chain (`evil → hop → <main>/.git/...`); stopping after one hop
# would let a two-link chain land _tdir back on the isolation root. Capped at 40 hops (Linux's
# own ELOOP limit) so a symlink cycle terminates; a cycle then falls through to the walk with
# ABS_PATH still a link inside the isolation worktree → allowed, exactly as before this fix.
#   Note (AC-3): Claude Code's own Edit/Write tools REFUSE to write through a
#   final-element symlink ("Refusing to write through symlink …"), verified empirically, so this
#   is defense-in-depth — it does not rely on that (undocumented) harness behavior.
_hop=0
while [ -L "$ABS_PATH" ] && [ "$_hop" -lt 40 ]; do
  # `readlink -n` (never `readlink -f`): the one-level form exists on both GNU and BSD, whereas
  # `-f` is a GNU extension historically absent from macOS.
  #
  # BYTE-EXACT capture is a hard requirement here, not a style choice. A plain `$(readlink …)`
  # strips EVERY trailing newline, so a link target that legitimately ends in LF comes back
  # truncated — and the hook would then scope a DIFFERENT path than the one the kernel follows
  # when the write lands. `ln -s $'y\n' <iso>/evil` with `<iso>/y<LF> -> <main>/.git/hooks/…`
  # scoped to `<iso>/y` (inside the isolation worktree → allowed) while the write itself
  # followed the real link into the parent .git. The `&& printf 'X'` sentinel makes the capture
  # end in a non-newline byte so nothing is stripped, and `%X` drops the sentinel.
  #
  # `-n` is what makes that byte-exact on BOTH platforms. Without it the capture ends in an
  # ambiguous newline — GNU readlink appends one, macOS readlink does not — and "strip exactly
  # one trailing LF" therefore either restores the target (GNU) or eats a genuine trailing LF
  # (macOS), where the deref then lands on a nonexistent path and falls back to allow. That
  # divergence is the same shape as the realpath one this Issue exists to remove, so suppress
  # the delimiter at the source rather than compensate for it afterwards.
  _lt=$(readlink -n "$ABS_PATH" 2>/dev/null && printf 'X') || _lt=""
  _lt=${_lt%X}
  [ -n "$_lt" ] || break
  case "$_lt" in
    /*) ;;
    # `${ABS_PATH%/*}` rather than `$(dirname …)` for the same byte-exactness reason: the
    # command substitution would strip a trailing LF from a directory name that ends in one.
    # ABS_PATH is always absolute here (set from `/*` or `${CWD%/}/…` above), so it always
    # contains a slash; at the root the expansion yields "" and the result is "/target",
    # which is what dirname would have meant.
    *)  _lt="${ABS_PATH%/*}/$_lt" ;;
  esac
  ABS_PATH="$_lt"
  _hop=$((_hop + 1))
done
# Both give-up arms above (readlink failed → break; hop cap reached → loop exit) leave
# ABS_PATH a link, so a link that stays inside the isolation worktree is allowed with AC-2
# effectively off. That fail-open direction is correct here — scope is not yet confirmed, and
# a legitimate isolation-internal symlink must not be false-denied — but the operator would
# otherwise have no way to tell "allowed because it was safe" from "allowed because the deref
# gave up". Record the give-up under RITE_DEBUG, same channel as the subagent-detection
# fallback above. Not a fallback of its own: the decision is unchanged either way.
if [ -n "${RITE_DEBUG:-}" ] && [ -L "$ABS_PATH" ]; then
  printf '[%s] pre-tool-edit-guard: AC-2 deref gave up after %s hop(s), target still a symlink: %s\n' \
    "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$_hop" \
    "$(printf '%s' "${ABS_PATH:0:120}" | neutralize_ctrl --c0-only)" \
    >> "${STATE_ROOT:-/tmp}/.rite-flow-debug.log" 2>/dev/null || true
fi

# --- Resolve the git worktree that OWNS the target ---
# The isolation allowance is defined by "the target lives inside a sanctioned reviewer isolation
# worktree", NOT by "the path string contains the token". Resolve the target's own worktree by
# walking up to its nearest EXISTING ancestor, then asking git. `[ -d ]` and `git -C` both chdir
# and resolve `..` physically, so a path carrying a non-existent `..` segment lands on the real
# parent repo (→ deny), not on a forged isolation dir. Walking to the nearest existing ancestor
# also covers a brand-new file in a not-yet-created dir (the ancestor still resolves to the repo).
_tdir=${ABS_PATH%/*}
[ -n "$_tdir" ] || _tdir="/"
while [ -n "$_tdir" ] && [ "$_tdir" != "/" ] && [ ! -d "$_tdir" ]; do
  _tdir=${_tdir%/*}
  [ -n "$_tdir" ] || _tdir="/"
done
[ -d "$_tdir" ] || _tdir="${CWD:-.}"
# git -C chdir's to the resolved ancestor and reports the worktree toplevel that owns it.
TARGET_ROOT=$(git -C "$_tdir" rev-parse --show-toplevel 2>/dev/null) || TARGET_ROOT=""

# `_deny_kind` stays empty for an allow; it is set to "parent-tree" or "git-dir" when the write
# must be denied. Both deny kinds share the fail-CLOSED emit at the end of this block.
_deny_kind=""
if [ -z "$TARGET_ROOT" ]; then
  # `--show-toplevel` is empty for two very different reasons, which MUST NOT be conflated:
  #   (a) the ancestor is in NO git repo (genuine /tmp scratch) → allow (fail-open), or
  #   (b) the target is INSIDE a .git directory — `rev-parse --show-toplevel` reports no work tree
  #       there, so the old blanket `|| exit 0` allowed it (review cycle 2). A reviewer
  #       writing into .git (e.g. .git/hooks/pre-commit, or .git/config core.hooksPath / alias.*=!sh)
  #       can execute arbitrary code in the non-sandboxed MAIN session on the next git operation —
  #       strictly worse than a source-file edit, and invisible to the worktree-hash post-condition
  #       axis (git status --porcelain ignores .git). This hook is the structural defense for the
  #       Edit/Write/MultiEdit/NotebookEdit path; deny git-internal writes there, allow only genuine
  #       non-repo scratch. (The sibling Bash-tool vector — `echo > .git/hooks/...`, `tee`/`cp`/`ln`
  #       into .git — is closed by pre-tool-bash-guard.sh sub-block (H), which enforces AC-1)
  if [ "$(git -C "$_tdir" rev-parse --is-inside-git-dir 2>/dev/null)" = "true" ]; then
    _deny_kind="git-dir"
  else
    exit 0   # genuine non-repo scratch → allow (fail-open; scope not confirmed)
  fi
else
  TARGET_ROOT="${TARGET_ROOT%/}"
  # --- Isolation allowance: the target's OWN worktree is a sanctioned isolation worktree ---
  # Reviewers legitimately run mutation experiments in a detached worktree created via
  # `mktemp -d -t rite-review-mutation-XXXXXX` + `git worktree add --detach` (or the
  # `rite-revert-test-*` sibling namespace — same prefixes swept by pr-cycle-cleanup.sh Step 4).
  # Matching on TARGET_ROOT (the target's resolved worktree root), not the raw path, means only a
  # genuine isolation worktree is allowed — closing the substring / `..` re-entry bypass.
  case "$TARGET_ROOT" in
    */rite-review-mutation-*|*/rite-revert-test-*) exit 0 ;;
  esac
  _deny_kind="parent-tree"
fi

# --- Scope confirmed: subagent + write into a parent working tree OR its .git dir → DENY ---
# Swap to the fail-CLOSED trap so any crash from here on denies rather than allows.
trap '_rite_teg_fail_closed' ERR

# Log block event (stderr, for effect measurement) — mirror bash-guard's format.
# ABS_PATH can carry a raw LF regardless of how the final element is resolved, so neutralize
# independently of the resolution strategy: the pre-#2014 `realpath` capture already preserved
# a MID-string LF (command substitution strips only TRAILING newlines — verified: on
# origin/develop this stderr record splits in two), and the deref loop additionally admits link
# targets that legitimately END in one. A raw LF here would split this single-line record and
# let a forged `edit-guard: BLOCKED …` line be injected, so the neutralization closes a
# pre-existing forgery vector rather than one this fix opened — do not drop it if the deref
# loop is ever reworked. Same helper the RITE_DEBUG snippet above uses.
PATH_SUMMARY=$(printf '%s' "${ABS_PATH:0:120}" | neutralize_ctrl --c0-only)
PATH_SUMMARY="${PATH_SUMMARY//\"/\\\"}"
echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] edit-guard: BLOCKED kind=$_deny_kind tool=$TOOL_NAME path=\"$PATH_SUMMARY\"" >&2

if [ "$_deny_kind" = "git-dir" ]; then
  _deny_reason="BLOCKED (reviewer-edit-git-dir): Reviewer subagents must not write into a Git internal directory. The ${TOOL_NAME} tool targeted '${ABS_PATH}', which is inside a .git directory. Writing there — .git/hooks/*, .git/config (core.hooksPath / alias / core.fsmonitor), etc. — can execute arbitrary code in the non-sandboxed main session on the next git operation. Reviewers are strictly read-only: inspect refs/blobs with 'git show', 'git cat-file', 'git rev-parse' instead. See plugins/rite/agents/_reviewer-base.md (READ-ONLY Enforcement)."
else
  _deny_reason="BLOCKED (reviewer-edit-parent-tree): Reviewer subagents must not mutate the parent working tree. The ${TOOL_NAME} tool targeted '${ABS_PATH}', which resolves inside the repository working tree (${TARGET_ROOT}). Reviewers are strictly read-only — inspect files with Read/Grep and compare historical content with 'git show <ref>:<file>'. If you need a mutation/verification experiment, do it in an isolated detached worktree under \$TMPDIR: 'git worktree add --detach \$(mktemp -d -t rite-review-mutation-XXXXXX) HEAD' and edit files THERE (a real worktree whose root is named rite-review-mutation-* / rite-revert-test-* is allowed). See plugins/rite/agents/_reviewer-base.md (READ-ONLY Enforcement / Mutation experiments)."
fi
# jq is required to emit the permission payload; an intermittent jq failure would
# silently downgrade the deny to allow, so the fail-CLOSED trap catches a crash
# here and emits a static deny + exit 2.
jq -n --arg reason "$_deny_reason" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: $reason
  }
}'
