#!/bin/bash
# sandbox-ghost-dirty-integration.test.sh (#1936, T-04 / T-06)
#
# Pins that the exact dirty-detection lines embedded in cleanup/SKILL.md
# Step 4-W and recover/SKILL.md Phase 3.2 — extracted literally from the
# SKILL.md files, not reimplemented — resolve to "not dirty" when the only
# `??` entries in the tree are sandbox write-block ghost mounts, and still
# resolve to "dirty" for a genuine untracked file (no false-negative
# regression). T-05 (cleanup Step 4 BASE_UPDATE=ok under the same ghost-only
# condition) is covered by base-update-classify.test.sh's dedicated case.
#
# mknod requires root/CAP_MKNOD (unavailable here and in most CI), so a
# symlink to /dev/null simulates the ghost mount: `test -c` follows
# symlinks (like stat, not lstat), so a symlink target of /dev/null is
# indistinguishable from the real character-device bind mount for the one
# property lib/git-status-filtered.sh inspects, and `git status --porcelain`
# reports it as an ordinary `??` entry exactly like the genuine ghost mount.
#
# Fail-safe pin (cross-validation escalation,): when
# lib/git-status-filtered.sh itself fails (e.g. mktemp exhaustion — a
# failure mode the helper introduces that plain `git status --porcelain`
# never had), both extracted lines must fall back to a non-empty "assume
# dirty/uncommitted" sentinel rather than silently reporting clean. A stub
# replacing the helper (via a fake plugin_root) simulates this failure.
# The same stub also pins that issue-update/SKILL.md Phase 3.2 Step 1
# (changed_files=) emits a visible WARNING on helper failure instead of
# silently producing an empty file list with no signal.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"

PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"
CLEANUP_MD="$PLUGIN_ROOT/skills/cleanup/SKILL.md"
RECOVER_MD="$PLUGIN_ROOT/skills/recover/SKILL.md"
ISSUE_UPDATE_MD="$PLUGIN_ROOT/skills/issue-update/SKILL.md"

echo "=== sandbox ghost-mount dirty-check integration (cleanup Step 4-W / recover) ==="

cleanup_dirs=()
cleanup() {
  local d
  for d in "${cleanup_dirs[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
}
trap cleanup EXIT

# --- Extract the exact dirty-detection line from each SKILL.md, literally,
#     so drift in the source file (not just this test) is caught -----------
CLEANUP_LINE=$(grep -m1 '^\s*dirty=\$(bash {plugin_root}' "$CLEANUP_MD")
if [ -z "$CLEANUP_LINE" ]; then
  echo "ERROR: cleanup/SKILL.md からの dirty= 行抽出に失敗しました（アンカーが変更された可能性）" >&2
  exit 1
fi
CLEANUP_LINE=${CLEANUP_LINE//\{plugin_root\}/$PLUGIN_ROOT}

RECOVER_LINE=$(grep -m1 'git_has_uncommitted=\$(bash {plugin_root}' "$RECOVER_MD")
if [ -z "$RECOVER_LINE" ]; then
  echo "ERROR: recover/SKILL.md からの git_has_uncommitted= 行抽出に失敗しました（アンカーが変更された可能性）" >&2
  exit 1
fi
RECOVER_LINE=${RECOVER_LINE//\{plugin_root\}/$PLUGIN_ROOT}

run_cleanup_dirty() {
  # Mirrors the SKILL.md line's own variable name ("dirty") so the extracted
  # text runs unmodified; echoes it out for the test to capture.
  ( cd "$1" && eval "$CLEANUP_LINE" && printf '%s' "$dirty" )
}

run_recover_uncommitted() {
  ( cd "$1" && eval "$RECOVER_LINE" && printf '%s' "$git_has_uncommitted" )
}

# --- T-04: cleanup Step 4-W dirty line, ghost-only tree -> empty (not dirty)
sbx_t04=$(make_sandbox) && cleanup_dirs+=("$sbx_t04") || { echo "ERROR: make_sandbox failed, aborting" >&2; exit 1; }
( cd "$sbx_t04" && ln -s /dev/null ghost_devnull ) >/dev/null 2>&1
out=$(run_cleanup_dirty "$sbx_t04")
assert "T-04: cleanup Step 4-W dirty= is empty with ghost-only tree" "" "$out"

# --- T-04 regression guard: a genuine untracked file must still register --
sbx_t04b=$(make_sandbox) && cleanup_dirs+=("$sbx_t04b") || { echo "ERROR: make_sandbox failed, aborting" >&2; exit 1; }
( cd "$sbx_t04b" && echo x > real.txt ) >/dev/null 2>&1
out=$(run_cleanup_dirty "$sbx_t04b")
assert "T-04 regression guard: real untracked file still reported dirty" "?? real.txt" "$out"

# --- T-06: recover git_has_uncommitted, ghost-only tree -> empty ("なし") -
sbx_t06=$(make_sandbox) && cleanup_dirs+=("$sbx_t06") || { echo "ERROR: make_sandbox failed, aborting" >&2; exit 1; }
( cd "$sbx_t06" && ln -s /dev/null ghost_devnull ) >/dev/null 2>&1
out=$(run_recover_uncommitted "$sbx_t06")
assert "T-06: recover git_has_uncommitted is empty with ghost-only tree" "" "$out"

# --- T-06 regression guard: a genuine unstaged change must still register -
sbx_t06b=$(make_sandbox) && cleanup_dirs+=("$sbx_t06b") || { echo "ERROR: make_sandbox failed, aborting" >&2; exit 1; }
( cd "$sbx_t06b" && echo modified >> a ) >/dev/null 2>&1
out=$(run_recover_uncommitted "$sbx_t06b")
assert "T-06 regression guard: real unstaged change still reported uncommitted" " M a" "$out"

# --- Fail-safe: when lib/git-status-filtered.sh itself fails, the extracted
#     lines must NOT silently report clean (cross-validation escalation,
#). A stub plugin_root replaces the real helper with one that
#     always fails, and the same production lines are re-extracted against it.
stub_root=$(mktemp -d) && cleanup_dirs+=("$stub_root") || { echo "ERROR: mktemp -d failed for stub_root, aborting" >&2; exit 1; }
mkdir -p "$stub_root/hooks/scripts/lib"
cat > "$stub_root/hooks/scripts/lib/git-status-filtered.sh" << 'STUB_EOF'
echo "WARNING: git-status-filtered: simulated failure (test stub)" >&2
exit 1
STUB_EOF

CLEANUP_LINE_FAIL=$(grep -m1 '^\s*dirty=\$(bash {plugin_root}' "$CLEANUP_MD")
CLEANUP_LINE_FAIL=${CLEANUP_LINE_FAIL//\{plugin_root\}/$stub_root}
BU_DIRTY_LINE_FAIL=$(grep -m1 '_bu_dirty=\$(bash {plugin_root}' "$CLEANUP_MD")
if [ -z "$BU_DIRTY_LINE_FAIL" ]; then
  echo "ERROR: cleanup/SKILL.md からの _bu_dirty= 行抽出に失敗しました（アンカーが変更された可能性）" >&2
  exit 1
fi
BU_DIRTY_LINE_FAIL=${BU_DIRTY_LINE_FAIL//\{plugin_root\}/$stub_root}
RECOVER_LINE_FAIL=$(grep -m1 'git_has_uncommitted=\$(bash {plugin_root}' "$RECOVER_MD")
RECOVER_LINE_FAIL=${RECOVER_LINE_FAIL//\{plugin_root\}/$stub_root}

sbx_fail=$(make_sandbox) && cleanup_dirs+=("$sbx_fail") || { echo "ERROR: make_sandbox failed, aborting" >&2; exit 1; }

out=$( cd "$sbx_fail" && eval "$CLEANUP_LINE_FAIL" && printf '%s' "$dirty" )
case "$out" in
  "") fail "fail-safe: cleanup Step 4-W dirty= must not be empty when the helper fails (got empty — silent clean masking a detection failure)" ;;
  *) pass "fail-safe: cleanup Step 4-W dirty= is non-empty when the helper fails ($out)" ;;
esac

# --- stderr visibility (cycle 2, error-handling escalation): the
#     helper's own diagnostic WARNING (e.g. "mktemp failed") must reach
#     stderr, not be discarded by a `2>/dev/null` on the call site ---------
err_out=$( cd "$sbx_fail" && eval "$CLEANUP_LINE_FAIL" 2>&1 1>/dev/null )
case "$err_out" in
  *"git-status-filtered: simulated failure"*) pass "fail-safe: cleanup Step 4-W surfaces the helper's own stderr on failure ($err_out)" ;;
  *) fail "fail-safe: cleanup Step 4-W must surface the helper's own stderr on failure (got: $err_out)" ;;
esac

# --- cleanup Step 4 (_bu_dirty, base-update classify): same fail-safe /
#     stderr-visibility pin as Step 4-W above, for the third call site that
#     had its own `2>/dev/null` removed in cycle 3 (test-reviewer escalation:
#     TC-10 in base-update-classify.test.sh only pins the classification
#     outcome, not stderr visibility for this specific line) --------------
out=$( cd "$sbx_fail" && eval "$BU_DIRTY_LINE_FAIL" && printf '%s' "$_bu_dirty" )
case "$out" in
  "") fail "fail-safe: cleanup Step 4 _bu_dirty= must not be empty when the helper fails (got empty — silent clean masking a detection failure)" ;;
  *) pass "fail-safe: cleanup Step 4 _bu_dirty= is non-empty when the helper fails ($out)" ;;
esac

err_out=$( cd "$sbx_fail" && eval "$BU_DIRTY_LINE_FAIL" 2>&1 1>/dev/null )
case "$err_out" in
  *"git-status-filtered: simulated failure"*) pass "fail-safe: cleanup Step 4 surfaces the helper's own stderr on failure ($err_out)" ;;
  *) fail "fail-safe: cleanup Step 4 must surface the helper's own stderr on failure (got: $err_out)" ;;
esac

out=$( cd "$sbx_fail" && eval "$RECOVER_LINE_FAIL" && printf '%s' "$git_has_uncommitted" )
case "$out" in
  "") fail "fail-safe: recover git_has_uncommitted must not be empty when the helper fails (got empty — silent 'なし' masking a detection failure)" ;;
  *) pass "fail-safe: recover git_has_uncommitted is non-empty when the helper fails ($out)" ;;
esac

err_out=$( cd "$sbx_fail" && eval "$RECOVER_LINE_FAIL" 2>&1 1>/dev/null )
case "$err_out" in
  *"git-status-filtered: simulated failure"*) pass "fail-safe: recover surfaces the helper's own stderr on failure ($err_out)" ;;
  *) fail "fail-safe: recover must surface the helper's own stderr on failure (got: $err_out)" ;;
esac

# --- issue-update Phase 3.2 Step 1: helper failure must emit a visible
#     WARNING (not silently produce an empty file list with no signal) ---
ISSUE_UPDATE_LINE_FAIL=$(grep -m1 '^changed_files=\$(bash {plugin_root}' "$ISSUE_UPDATE_MD")
if [ -z "$ISSUE_UPDATE_LINE_FAIL" ]; then
  echo "ERROR: issue-update/SKILL.md からの changed_files= 行抽出に失敗しました（アンカーが変更された可能性）" >&2
  exit 1
fi
ISSUE_UPDATE_LINE_FAIL=${ISSUE_UPDATE_LINE_FAIL//\{plugin_root\}/$stub_root}

err_out=$( cd "$sbx_fail" && eval "$ISSUE_UPDATE_LINE_FAIL" 2>&1 1>/dev/null )
case "$err_out" in
  *"git-status-filtered.sh failed while collecting changed files"*) pass "issue-update: WARNING emitted when the helper fails ($err_out)" ;;
  *) fail "issue-update: WARNING must be emitted when the helper fails (got: $err_out)" ;;
esac

print_summary "$(basename "$0")"
