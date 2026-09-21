#!/usr/bin/env bash
# Check a collected review's fix plan or execute its verification plan.
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "${1:-}" = "commit-target" ]; then
  exec python3 "$script_dir/lib/review-fix-scope.py" "$@"
fi
if [ "${1:-}" = "commit-check" ]; then
  # This preflight must not create state directories merely to resolve a path.
  root=$(bash "$script_dir/../state-path-resolve.sh")
  source "$script_dir/../session-identity.sh"
  identity_rc=0
  session=$(resolve_runtime_session_id) || identity_rc=$?
  if [ "$identity_rc" = 2 ]; then
    session_file="$root/.rite/session-id"
    if [ ! -f "$session_file" ] && [ -f "$root/.rite-session-id" ]; then
      session_file="$root/.rite-session-id"
    fi
    # No runtime or stored session means there is no owned review to gate.
    [ -e "$session_file" ] || exit 0
    session=$(tr -d '[:space:]' < "$session_file")
    [ -n "$session" ] || { echo "ERROR: empty stored session identity" >&2; exit 1; }
    validate_session_id_path "$session" "stored session" || exit 1
  elif [ "$identity_rc" != 0 ]; then
    exit "$identity_rc"
  fi
  exec python3 "$script_dir/lib/review-fix-scope.py" "$@" \
    --state "$root/.rite/sessions/$session.flow-state" --session "$session" --state-root "$root"
fi
session=$(bash "$script_dir/../session-identity.sh")
state=$(bash "$script_dir/../flow-state.sh" path)
root=$(bash "$script_dir/../state-path-resolve.sh")
exec python3 "$script_dir/lib/review-fix-scope.py" "$@" \
  --state "$state" --session "$session" --state-root "$root"
