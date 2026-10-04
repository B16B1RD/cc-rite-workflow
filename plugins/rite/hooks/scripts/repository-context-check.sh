#!/usr/bin/env bash
# Verify repository context at Complexity helper invocation boundaries.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
exec python3 "$SCRIPT_DIR/repository-context-check.py" "$@"
