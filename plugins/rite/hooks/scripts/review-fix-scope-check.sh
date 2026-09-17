#!/usr/bin/env bash
# Check a collected review's fix plan or execute its verification plan.
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
session=$(bash "$script_dir/../session-identity.sh")
state=$(bash "$script_dir/../flow-state.sh" path)
root=$(bash "$script_dir/../state-path-resolve.sh")
exec python3 "$script_dir/lib/review-fix-scope.py" "$@" \
  --state "$state" --session "$session" --state-root "$root"
