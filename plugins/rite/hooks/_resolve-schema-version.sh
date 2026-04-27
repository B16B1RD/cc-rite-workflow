#!/bin/bash
# rite workflow - Schema Version Resolution Helper (private internal helper)
#
# Resolves `flow_state.schema_version` from rite-config.yml. Returns "1"
# (legacy single-file format) or "2" (per-session file format).
#
# Default behavior (silent fallback to "1"):
#   - rite-config.yml not found → "1"
#   - flow_state: section not found → "1"
#   - schema_version: line not found → "1"
#   - schema_version: line present but value is invalid (not 1 or 2) → "1"
#
# Usage (executable invocation):
#   SCHEMA_VERSION=$(bash plugins/rite/hooks/_resolve-schema-version.sh "$STATE_ROOT")
#
# Why this exists (PR #688 cycle 5 review code-quality + error-handling 推奨):
#   The same schema_version resolution logic was duplicated in:
#     - state-read.sh (reader-side, line 80-102)
#     - flow-state-update.sh _resolve_schema_version (writer-side, line 102-110)
#   Both implementations went through cycle 1 (silent failure detection) and
#   cycle 3 (`|| v=""` pipefail guard added to both). DRY-ifying eliminates
#   the drift risk where a future micro-fix is applied to one side only.
#
# Exit codes:
#   0 — always (echoes "1" or "2" on stdout)
set -euo pipefail

STATE_ROOT="${1:-$(pwd)}"
cfg="$STATE_ROOT/rite-config.yml"

if [ ! -f "$cfg" ]; then
  echo "1"
  exit 0
fi

# Section-range extract: pipefail-safe due to `|| section=""` guard.
section=$(sed -n '/^flow_state:/,/^[a-zA-Z]/p' "$cfg" 2>/dev/null) || section=""
if [ -z "$section" ]; then
  echo "1"
  exit 0
fi

# Pipefail silent failure guard (Issue #687 AC-4 follow-up):
# `flow_state:` セクションあり + `schema_version:` 行欠落の degenerate config で
# grep が exit 1 を返した場合、`set -euo pipefail` 下では pipeline 全体 exit 1 が伝播し、
# top-level 直接代入のため `set -e` で helper が silent に exit 1 する経路があった。
# 末尾の `|| v=""` で pipefail を吸収し、後続の case "*)" 分岐で安全に default "1" に落とす。
v=$(printf '%s\n' "$section" | grep -E '^[[:space:]]+schema_version:' | head -1 \
  | sed 's/#.*//' | sed 's/.*schema_version:[[:space:]]*//' \
  | tr -d '[:space:]"'"'"'') || v=""
case "$v" in
  1|2) echo "$v" ;;
  *)   echo "1" ;;
esac
