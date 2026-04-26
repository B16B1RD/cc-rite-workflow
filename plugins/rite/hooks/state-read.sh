#!/bin/bash
# rite workflow - State Read Helper
# Reads a single field from the active session's flow-state file (per-session
# or legacy). Mirrors flow-state-update.sh's path-resolution rules so reader
# bash patterns scattered across command files (e.g. start.md Phase 3 / 5.5.1 /
# 5.6 pre-condition checks) cannot accidentally read another session's stale
# residue from .rite-flow-state.
#
# Usage:
#   bash plugins/rite/hooks/state-read.sh --field <name> [--default <val>]
#
# Examples:
#   curr=$(bash plugins/rite/hooks/state-read.sh --field phase --default "")
#   parent=$(bash plugins/rite/hooks/state-read.sh --field parent_issue_number --default 0)
#   loop=$(bash plugins/rite/hooks/state-read.sh --field loop_count --default 0)
#
# Resolution order (matches flow-state-update.sh semantics):
#   1. schema_version=2 + valid .rite-session-id UUID + per-session file exists
#      -> per-session file (.rite/sessions/{sid}.flow-state)
#   2. legacy file exists (.rite-flow-state)
#      -> legacy
#   3. neither
#      -> $DEFAULT
#
# Why this exists (Issue #687 AC-4):
#   When schema_version=2 routes flow-state writes to per-session files,
#   inline `jq -r '.<field>' .rite-flow-state` patterns read stale residue
#   left by a prior session — observed in #687 reproduction where Phase 3
#   pre-condition fetched phase5_post_stop_hook from another session's legacy
#   file instead of phase2_post_work_memory from the active per-session file.
#
# Exit codes:
#   0 — success (value or default printed to stdout)
#   1 — argument error / invalid field name
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Resolve repository root via the existing helper (single SoT).
# state-path-resolve.sh は現状 `return 0` 固定のため `||` fallback は dead code だが、
# 将来 git not found / cwd 不在等で non-zero を返す変更が入った際の defensive guard として
# 維持する。`set -euo pipefail` 下で fail-safe に cwd へ落とす契約を明示する。
STATE_ROOT=$("$SCRIPT_DIR/state-path-resolve.sh" "$(pwd)" 2>/dev/null) || STATE_ROOT="$(pwd)"
LEGACY_FLOW_STATE="$STATE_ROOT/.rite-flow-state"

# --- Argument parsing ---
FIELD=""
DEFAULT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --field)   FIELD="${2:-}"; shift 2 ;;
    --default) DEFAULT="${2:-}"; shift 2 ;;
    --)        shift; break ;;
    *) echo "ERROR: Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [ -z "$FIELD" ]; then
  echo "ERROR: --field is required" >&2
  exit 1
fi

# Validate field name to keep the jq filter free of injection risk
# (we substitute FIELD as a literal accessor below).
if ! [[ "$FIELD" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
  echo "ERROR: invalid field name: $FIELD" >&2
  exit 1
fi

# --- Resolve session_id (matches flow-state-update.sh _resolve_session_id) ---
# UUID-format validation prevents path traversal via tampered .rite-session-id.
SESSION_ID=""
if [ -f "$STATE_ROOT/.rite-session-id" ]; then
  raw=$(tr -d '[:space:]' < "$STATE_ROOT/.rite-session-id" 2>/dev/null) || raw=""
  if [[ "$raw" =~ ^[0-9a-f-]{36}$ ]]; then
    SESSION_ID="$raw"
  fi
fi

# --- Resolve schema_version (matches flow-state-update.sh _resolve_schema_version) ---
SCHEMA_VERSION="1"
cfg="$STATE_ROOT/rite-config.yml"
if [ -f "$cfg" ]; then
  section=$(sed -n '/^flow_state:/,/^[a-zA-Z]/p' "$cfg" 2>/dev/null) || section=""
  if [ -n "$section" ]; then
    # Issue #687 AC-4 follow-up (pipefail silent failure 対策):
    # rite-config.yml の `flow_state:` セクションは存在するが `schema_version:` 行が欠落する
    # 設定で grep が exit 1 を返すと、`set -euo pipefail` 下では pipeline 全体 exit 1 →
    # top-level 直接代入のため set -e で helper が silent に exit 1 する。caller は curr=""
    # を受け取り .phase="" で誤った理由 ERROR exit する経路があった。
    # 末尾に `|| v=""` を追加して pipefail を吸収し、後続の case "*)" 分岐で安全に default
    # "1" に落とす。writer 側 flow-state-update.sh:87-109 (`_resolve_schema_version`) も
    # 同パターンで `|| v=""` を追加して architectural 統一を完了済み (PR #688 cycle 3 で実施)。
    v=$(printf '%s\n' "$section" | grep -E '^[[:space:]]+schema_version:' | head -1 \
      | sed 's/#.*//' | sed 's/.*schema_version:[[:space:]]*//' \
      | tr -d '[:space:]"'"'"'') || v=""
    case "$v" in
      1|2) SCHEMA_VERSION="$v" ;;
      *)   SCHEMA_VERSION="1" ;;
    esac
  fi
fi

# --- Resolve target file ---
# Mirror flow-state-update.sh _resolve_session_state_path. Additional fallback:
# when schema_version=2 routes to per-session but that file is absent, fall back
# to legacy if present. This tolerates fresh sessions that have not yet written
# their per-session file but inherit a legacy snapshot from a prior session
# (the read-side counterpart to the writer-side migration path).
if [[ "$SCHEMA_VERSION" == "2" ]] && [[ -n "$SESSION_ID" ]]; then
  STATE_FILE="$STATE_ROOT/.rite/sessions/${SESSION_ID}.flow-state"
  if [ ! -f "$STATE_FILE" ] && [ -f "$LEGACY_FLOW_STATE" ]; then
    STATE_FILE="$LEGACY_FLOW_STATE"
  fi
else
  STATE_FILE="$LEGACY_FLOW_STATE"
fi

# --- Read field ---
if [ ! -f "$STATE_FILE" ]; then
  echo "$DEFAULT"
  exit 0
fi

# Pass DEFAULT through jq's --arg so quoting/escaping is handled by jq.
# FIELD has been validated as [a-zA-Z_][a-zA-Z0-9_]* so direct interpolation
# into the filter is safe. This helper is read-only — no object construction
# (the silent-reset failure mode of writer-side jq is not applicable here).
value=$(jq -r --arg default "$DEFAULT" ".${FIELD} // \$default" "$STATE_FILE" 2>/dev/null) \
  || value="$DEFAULT"

# Normalize: when the field exists but holds JSON null, jq -r emits the literal
# string "null". Map that to the caller-supplied default (unless the caller
# explicitly passed "null" as the default).
if [ "$value" = "null" ] && [ "$DEFAULT" != "null" ]; then
  value="$DEFAULT"
fi

echo "$value"
