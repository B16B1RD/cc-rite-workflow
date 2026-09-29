# shellcheck shell=bash
# Clears ambient runtime identity and state-root inputs so hook tests see only
# what each fixture sets. Tests also run from live Claude, Codex, and Grok
# dogfooding sessions, and an inherited session ID, RITE_HOST, or state root
# diverts sandbox operations to a foreign owner or makes identity resolution fail.
#
# run-tests.sh and _test-helpers.sh source this file; tests that read ambient
# identity without _test-helpers.sh source it themselves. The name does not end
# in `.test.sh`, so run-tests.sh never runs it as a test.
#
# Clearing the variables is not enough for a test that runs hooks from its own
# cwd: hooks derive the state root from the process cwd, so a cwd inside a real
# checkout still reaches the live session's flow-state through .rite/session-id.
# Such a test calls hermetic_leave_checkout right after sourcing this file and
# removes "$HERMETIC_CWD" in its cleanup. Sourcing alone never changes the cwd,
# because most tests resolve paths from their cwd or $0.
unset CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID CODEX_THREAD_ID GROK_SESSION_ID RITE_HOST CLAUDE_PLUGIN_ROOT
unset CLAUDE_ENV_FILE RITE_STATE_ROOT RITE_RUNTIME_EXPLICIT _RITE_HOOK_REDIRECTED

# Moves the cwd to a new empty directory outside any git repository and sets
# HERMETIC_CWD to its absolute path. Returns 1 without moving when the directory
# cannot be created or lands inside a repository (a TMPDIR under a checkout).
hermetic_leave_checkout() {
  local dir
  dir=$(mktemp -d "${TMPDIR:-/tmp}/rite-hermetic-cwd.XXXXXX") || {
    echo "ERROR: hermetic_leave_checkout: cannot create a scratch directory under ${TMPDIR:-/tmp}" >&2
    return 1
  }
  if git -C "$dir" rev-parse --git-dir >/dev/null 2>&1; then
    echo "ERROR: hermetic_leave_checkout: $dir is inside a git repository; point TMPDIR outside any checkout" >&2
    rmdir "$dir"
    return 1
  fi
  cd "$dir" || return 1
  HERMETIC_CWD=$(pwd -P)
}
