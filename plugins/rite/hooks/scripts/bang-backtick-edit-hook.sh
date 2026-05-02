#!/usr/bin/env bash
# bang-backtick-edit-hook.sh
#
# PostToolUse(Edit|Write|MultiEdit) wrapper for bang-backtick-check.sh.
# Filters tool_input.file_path so the static check only fires when an
# Edit/Write touches a markdown file under the rite plugin tree
# (`plugins/rite/{commands,skills,agents,references}/**/*.md`). Detection
# emits a stderr warning but always exits 0 — this hook is warn-only and
# MUST NOT block Edit/Write completion (per Issue #691 §4.5 and the
# Claude Code hooks convention that PostToolUse failures should not break
# tool execution after the fact).
#
# Issue #691 / Phase 5.1 (経路 C — immediate per-edit detection).
# Companion to /rite:pr:create and /rite:pr:ready Phase 1 pre-check
# (経路 D — pre-PR hard gate, exit 1).
#
# Exit semantics:
#   - Always exit 0 (warn-only). Detection / invocation error / scope
#     mismatch / hook plumbing failure all converge on exit 0 so
#     Edit/Write tool execution is never retroactively blocked.
#   - Diagnostic noise on stderr is gated by the underlying script's
#     own behavior — we just forward it.
set -uo pipefail

# Resolve script paths.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK_SCRIPT="$SCRIPT_DIR/bang-backtick-check.sh"

# Read PostToolUse JSON from stdin. `cat` may fail under pipe rupture; the
# `|| INPUT=""` fallback keeps us in the safe exit-0 path.
INPUT=$(cat 2>/dev/null) || INPUT=""
[ -n "$INPUT" ] || exit 0

# Extract tool_name and file_path. jq failures fall through to exit 0.
TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null) || TOOL_NAME=""
FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null) || FILE_PATH=""
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null) || CWD=""

# Filter on tool name. PostToolUse hooks.json uses matcher "Edit|Write" so
# the harness already pre-filters, but this defense-in-depth check keeps
# the wrapper safe under matcher drift / future tool additions.
case "$TOOL_NAME" in
  Edit|Write|MultiEdit) ;;
  *) exit 0 ;;
esac

# Bail if no file_path captured (defensive — should never happen for the
# tools above, but the JSON contract is upstream-controlled).
[ -n "$FILE_PATH" ] || exit 0

# Resolve repo root. Prefer the cwd reported by the harness (matches the
# user's working tree even if the hook runs from a different cwd); fall
# back to git toplevel; final fallback is current pwd.
REPO_ROOT=""
if [ -n "$CWD" ] && [ -d "$CWD" ]; then
  REPO_ROOT=$(cd "$CWD" && git rev-parse --show-toplevel 2>/dev/null) || REPO_ROOT="$CWD"
fi
if [ -z "$REPO_ROOT" ]; then
  REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
fi

# Normalize file_path to a path relative to REPO_ROOT. The check script
# accepts only repo-root-relative paths via --target.
case "$FILE_PATH" in
  /*)
    # Absolute path: strip REPO_ROOT prefix when present.
    case "$FILE_PATH" in
      "$REPO_ROOT"/*) REL_PATH="${FILE_PATH#"$REPO_ROOT"/}" ;;
      *) exit 0 ;;  # Edit outside the repo root — out of scope.
    esac
    ;;
  *)
    REL_PATH="$FILE_PATH"
    ;;
esac

# Scope filter: only rite plugin markdown under the four scan directories.
# This intentionally mirrors bang-backtick-check.sh --all (commands /
# skills / agents / references) so the per-edit guard cannot drift from
# the bulk lint scope. Matcher uses bash glob — extglob would also work
# but plain `case` keeps the script POSIX-friendly.
case "$REL_PATH" in
  plugins/rite/commands/*.md|\
  plugins/rite/commands/*/*.md|\
  plugins/rite/commands/*/*/*.md|\
  plugins/rite/skills/*.md|\
  plugins/rite/skills/*/*.md|\
  plugins/rite/skills/*/*/*.md|\
  plugins/rite/agents/*.md|\
  plugins/rite/agents/*/*.md|\
  plugins/rite/references/*.md|\
  plugins/rite/references/*/*.md|\
  plugins/rite/references/*/*/*.md)
    ;;
  *)
    exit 0
    ;;
esac

# Verify the underlying check script is present. Marketplace installs may
# strip hooks/scripts/; in that case we silently skip rather than emit a
# noisy WARNING for every edit.
[ -f "$CHECK_SCRIPT" ] || exit 0

# Verify the target file still exists (could have been deleted via Edit
# `new_string=""` followed by another tool) — bang-backtick-check.sh
# already handles missing files gracefully, but skipping early avoids
# emitting a misleading WARNING when the user explicitly removed the file.
[ -f "$REPO_ROOT/$REL_PATH" ] || exit 0

# Run the check. We always pass --quiet so the wrapper controls log
# verbosity; per-finding lines on stdout are still emitted (and we route
# them to stderr so they show up in the hook diagnostic stream rather
# than the tool output channel).
hook_output=$(bash "$CHECK_SCRIPT" \
  --repo-root "$REPO_ROOT" \
  --target "$REL_PATH" \
  --quiet 2>&1)
hook_rc=$?

case "$hook_rc" in
  0)
    # Clean — silent.
    :
    ;;
  1)
    # Pattern detected. Emit findings to stderr so the user sees them
    # without blocking Edit/Write completion.
    echo "⚠️ bang-backtick adjacency detected after Edit/Write of $REL_PATH:" >&2
    printf '%s\n' "$hook_output" >&2
    echo "  → Apply Style A (full-width 「!」) or Style B (expand 'if ! cmd') — see plugins/rite/hooks/scripts/bang-backtick-check.sh header for guidance." >&2
    ;;
  2)
    # Invocation error in the underlying script. Per Issue #691 §4.5,
    # demote to warning — the bulk gate (経路 D) will catch any escape.
    echo "⚠️ bang-backtick-check.sh invocation error during PostToolUse hook (rc=2):" >&2
    printf '%s\n' "$hook_output" >&2
    echo "  → Defense-in-depth: PR creation gate (経路 D) will re-run the check before submission." >&2
    ;;
  *)
    # Unexpected exit code — surface but do not block.
    echo "⚠️ bang-backtick-check.sh returned unexpected exit code $hook_rc:" >&2
    printf '%s\n' "$hook_output" >&2
    ;;
esac

exit 0
