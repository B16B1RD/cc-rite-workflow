#!/bin/bash
# rite workflow - Work Memory Lock (shared)
# Provides mkdir-based lock/unlock functions for issue-level work memory access.
# Used by pre-compact.sh (compact state lock) and implementation commands (issue lock).
#
# Usage (source from another script):
#   source "$(dirname "${BASH_SOURCE[0]}")/work-memory-lock.sh"
#   acquire_wm_lock "/path/to/lockdir" 50    # timeout in iterations (50 * 100ms = 5s)
#   release_wm_lock "/path/to/lockdir"
#
# Exit codes (from acquire_wm_lock):
#   0: Lock acquired
#   1: Lock acquisition failed (timeout or stale removal failed)

# Stale lock threshold in seconds (default: 120s for compact, 300s for issue)
WM_LOCK_STALE_THRESHOLD="${WM_LOCK_STALE_THRESHOLD:-120}"

acquire_wm_lock() {
  local lockdir="$1"
  local timeout="${2:-50}"  # 50 iterations * 100ms = 5 seconds
  local i=0

  while ! mkdir "$lockdir" 2>/dev/null; do
    i=$((i + 1))
    if [ "$i" -ge "$timeout" ]; then
      # Stale lock detection: check mtime > threshold
      if [ -d "$lockdir" ]; then
        local lock_mtime lock_age
        lock_mtime=$(stat -c %Y "$lockdir" 2>/dev/null || stat -f %m "$lockdir" 2>/dev/null)
        if [ -z "$lock_mtime" ] || [ "$lock_mtime" = "0" ]; then
          # stat failed on both platforms — cannot determine age, skip stale detection
          return 1
        fi
        lock_age=$(( $(date +%s) - lock_mtime ))
        if [ "$lock_age" -gt "$WM_LOCK_STALE_THRESHOLD" ]; then
          # Check PID file: if process is still alive, lock is not stale.
          # No PID file means the lock holder did not record its PID
          # (e.g., older version); treat as stale since we cannot verify liveness.
          if [ -f "$lockdir/pid" ]; then
            local lock_pid
            lock_pid=$(head -c 20 "$lockdir/pid" 2>/dev/null) || lock_pid=""
            if [ -n "$lock_pid" ] && [[ "$lock_pid" =~ ^[0-9]+$ ]] && kill -0 "$lock_pid" 2>/dev/null; then
              # Process still running — lock is not stale, give up
              return 1
            fi
          fi
          # Stale lock — remove pid file and directory, then retry once
          rm -f "$lockdir/pid" 2>/dev/null || true
          rmdir "$lockdir" 2>/dev/null || rm -rf "$lockdir" 2>/dev/null || true
          if mkdir "$lockdir" 2>/dev/null; then
            echo $$ > "$lockdir/pid" 2>/dev/null || true
            return 0
          fi
        fi
      fi
      return 1
    fi
    sleep 0.1
  done
  echo $$ > "$lockdir/pid" 2>/dev/null || true
  return 0
}

release_wm_lock() {
  local lockdir="$1"
  rm -f "$lockdir/pid" 2>/dev/null || true
  rmdir "$lockdir" 2>/dev/null || rm -rf "$lockdir" 2>/dev/null || true
}

is_wm_locked() {
  local lockdir="$1"
  [ -d "$lockdir" ]
}
