#!/usr/bin/env bash
# Decide one exit per root cause for review candidates that are not fixed as blocking.
# Record format, exits, reasons and exit codes: lib/review-adoption.py docstring.
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$script_dir/lib/review-adoption.py" "$@"
