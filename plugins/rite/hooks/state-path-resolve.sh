#!/bin/bash
# rite workflow - State Path Resolver
# Resolves the root directory for rite state files (.rite-compact-state, .rite/work-memory/)
# Usage: source this script or call resolve_state_root [cwd]
# Output: Prints the resolved root path to stdout
set -euo pipefail

resolve_state_root() {
  local cwd="${1:-$(pwd)}"

  # Walk up to find git root (rite state files live at repository root)
  local root
  root=$(cd "$cwd" && git rev-parse --show-toplevel 2>/dev/null) || true

  if [ -n "$root" ] && [ -d "$root" ]; then
    # Linked-worktree unification (multi-session, design §1): when cwd is inside
    # a linked git worktree (`git worktree add`), rite state / locks / wiki
    # worktree MUST resolve to the SAME shared root (the main checkout) across
    # all sessions — otherwise per-inode flock-based exclusion silently splits
    # one lock into one-per-checkout and stops excluding anything.
    #
    # The main checkout's common git dir is "<main_root>/.git"; a linked
    # worktree's --show-toplevel returns the worktree root, but its
    # --git-common-dir still points at the main checkout's .git. So when
    # --git-common-dir != "$root/.git" we are in a linked worktree and return
    # dirname(common) (= the main checkout root).
    #
    # Non-worktree sessions hit `common == "$root/.git"` and fall through to the
    # unchanged `echo "$root"` below → byte-identical output (pinned by test).
    local common
    common=$(cd "$cwd" && git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || common=""
    if [ -z "$common" ]; then
      # git < 2.31 lacks --path-format=absolute. Normalize the (possibly
      # relative) --git-common-dir by cd-ing into it and printing pwd.
      local common_rel
      common_rel=$(cd "$cwd" && git rev-parse --git-common-dir 2>/dev/null) || common_rel=""
      if [ -n "$common_rel" ]; then
        common=$(cd "$cwd" && cd "$common_rel" 2>/dev/null && pwd) || common=""
      fi
    fi
    if [ -n "$common" ] && [ "$common" != "$root/.git" ]; then
      local main_root
      main_root=$(dirname "$common")
      # Guard: only redirect when the derived main root carries a `.git` entry.
      # bare repos / submodules (where common does not sit directly under the
      # main checkout) keep the current behavior of returning $root.
      if [ -e "$main_root/.git" ]; then
        echo "$main_root"
        return 0
      fi
    fi

    echo "$root"
    return 0
  fi

  # Fallback: use cwd if not in a git repo
  echo "$cwd"
  return 0
}

# When invoked directly (not sourced), resolve and print
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  resolve_state_root "${1:-$(pwd)}"
fi
