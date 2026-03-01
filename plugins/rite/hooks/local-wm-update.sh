#!/bin/bash
# rite workflow - Local Work Memory Update (self-resolving wrapper)
# Standalone script that auto-resolves plugin root via BASH_SOURCE.
# All WM_* environment variables must be set by the caller.
#
# Requires bash execution (not sh or source). BASH_SOURCE is used for
# path resolution, which is unavailable in POSIX sh or when sourced.
#
# Note: set -euo pipefail is intentionally omitted. update_local_work_memory
# returns 1 (skipped) or 2 (lock failed) as non-fatal conditions, and the
# callers wrap this script with `2>/dev/null || true` (best-effort).
#
# Usage (env vars as command prefix):
#   WM_SOURCE="implement" WM_PHASE="phase5_lint" \
#     WM_PHASE_DETAIL="品質チェック準備" \
#     WM_NEXT_ACTION="rite:lint を実行" \
#     WM_BODY_TEXT="Post-implementation." \
#     bash plugins/rite/hooks/local-wm-update.sh
#
# Or with explicit plugin root (for marketplace installs):
#   WM_SOURCE="lint" ... bash {plugin_root}/hooks/local-wm-update.sh
#
# Exit codes: same as update_local_work_memory (0=success, 1=skipped, 2=lock failed)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Guard: abort if SCRIPT_DIR resolution failed or points to a non-existent directory
if [ ! -d "$SCRIPT_DIR" ]; then
  echo "rite: local-wm-update: SCRIPT_DIR resolution failed (resolved: '${SCRIPT_DIR:-<empty>}')" >&2
  exit 1
fi

# Source the shared helper (also sources work-memory-lock.sh)
source "$SCRIPT_DIR/work-memory-update.sh"

# Auto-set WM_PLUGIN_ROOT if not already provided by the caller.
# Security note: WM_PLUGIN_ROOT is overridable via env var. Current callers are all
# Claude Code Bash tool invocations (sandboxed), so external injection risk is minimal.
# If external callers are added in the future, validate the path with realpath.
export WM_PLUGIN_ROOT="${WM_PLUGIN_ROOT:-$(dirname "$SCRIPT_DIR")}"

update_local_work_memory
