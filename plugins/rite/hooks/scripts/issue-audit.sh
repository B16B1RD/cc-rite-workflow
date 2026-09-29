#!/usr/bin/env bash
# Collect the cross-Issue view and dispose only what the rules decide.
# Snapshot shape, rules, markers and exit codes: lib/issue-audit.py docstring.
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$script_dir/lib/issue-audit.py" "$@"
