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
#
# verified-review cycle 33 fix (F-04 MEDIUM): `2>/dev/null` を削除して stderr を pass-through する。
# defensive guard の本来の目的は「将来 non-zero return path で何が失敗したか観測可能にする」こと。
# 現状の return 0 固定では stderr 出力なし = 非 regression。将来 stderr を出すようになった際に
# 呼び出し側でも観測可能となる (本 PR cycle 5 以降の stderr 観測性優先方針と整合)。
STATE_ROOT=$("$SCRIPT_DIR/state-path-resolve.sh" "$(pwd)") || STATE_ROOT="$(pwd)"
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
# PR #688 cycle 22 fix (F-03 MEDIUM): RFC 4122 strict pattern (8-4-4-4-12 hex with hyphens at
# fixed positions). 旧 `^[0-9a-f-]{36}$` はハイフン位置を強制せず、`aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa`
# と同等に `aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa` (ハイフン無し 36 字) など RFC 4122 非準拠の
# パターンを許容していた。本 PR の使用範囲では path traversal に到達しないが、将来 SESSION_ID を
# 別 context (ログ / sql / curl URL 等) に流用すると spec drift で脆弱性化する future-proofing。
SESSION_ID=""
if [ -f "$STATE_ROOT/.rite-session-id" ]; then
  raw=$(tr -d '[:space:]' < "$STATE_ROOT/.rite-session-id" 2>/dev/null) || raw=""
  if [[ "$raw" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
    SESSION_ID="$raw"
  fi
fi

# --- Resolve schema_version (DRY: shared helper with flow-state-update.sh) ---
# PR #688 cycle 5 review (code-quality + error-handling 推奨): writer/reader で同一の inline
# schema_version 解決 logic を持っていた drift リスクを排除するため、共通 helper に抽出済。
# pipefail silent failure 対策 (Issue #687 AC-4 follow-up) も helper 内で吸収する。
SCHEMA_VERSION=$(bash "$SCRIPT_DIR/_resolve-schema-version.sh" "$STATE_ROOT")

# --- Resolve target file ---
# Mirror flow-state-update.sh _resolve_session_state_path. Additional fallback:
# when schema_version=2 routes to per-session but that file is absent, fall back
# to legacy if present. This tolerates fresh sessions that have not yet written
# their per-session file but inherit a legacy snapshot from a prior session
# (the read-side counterpart to the writer-side migration path).
if [[ "$SCHEMA_VERSION" == "2" ]] && [[ -n "$SESSION_ID" ]]; then
  STATE_FILE="$STATE_ROOT/.rite/sessions/${SESSION_ID}.flow-state"
  if [ ! -f "$STATE_FILE" ] && [ -f "$LEGACY_FLOW_STATE" ]; then
    # verified-review cycle 33 fix (F-03 MEDIUM): reader-side cross-session legacy guard.
    # writer 側 (flow-state-update.sh:127-138) cycle 32 cross-session takeover refusal と対称化。
    # legacy file が **別 session** の遺物の場合、foreign session の stale data を silent return
    # しないよう DEFAULT に落とす。これがないと、Issue #687 root cause 「fresh session で
    # phase5_post_stop_hook from a prior session leaked into Phase 3 check」の reader 側残存経路が
    # writer-side guard をすり抜ける。
    legacy_sid=$(jq -r '.session_id // empty' "$LEGACY_FLOW_STATE" 2>/dev/null) || legacy_sid=""
    if [ -z "$legacy_sid" ] || [ "$legacy_sid" = "$SESSION_ID" ]; then
      STATE_FILE="$LEGACY_FLOW_STATE"
    else
      # 別 session の legacy file → foreign session の stale data を silent return しないよう DEFAULT に降格。
      # writer-side `cross_session_takeover_refused` (flow-state-update.sh cycle 32) と対称な sentinel
      # を stderr に emit して observability を維持する (orchestrator が reader 経路の refusal も検出可能)。
      echo "[CONTEXT] WORKFLOW_INCIDENT=1; type=cross_session_takeover_refused; layer=reader; sid=$SESSION_ID; legacy_sid=$legacy_sid" >&2
      echo "$DEFAULT"
      exit 0
    fi
  fi
else
  STATE_FILE="$LEGACY_FLOW_STATE"
fi

# --- Read field ---
# F-C MEDIUM (PR #688 cycle 5 review test reviewer 推奨): 空ファイル / 非 JSON ファイルの edge case
# 旧実装は file 存在チェックのみで、空ファイル (`touch .rite-flow-state` 等) や非 JSON ファイル
# (例: 別プロセスが書き込み中) の場合に jq が exit 0 + 空出力を返す → caller default が
# 効かず空文字列を silent return する経路があった。`[ -s "$STATE_FILE" ]` (size > 0) を追加して
# 空ファイル時も DEFAULT に落とす (corrupt JSON 経路と挙動を一致させる)。
if [ ! -f "$STATE_FILE" ] || [ ! -s "$STATE_FILE" ]; then
  echo "$DEFAULT"
  exit 0
fi

# Pass DEFAULT through jq's --arg so quoting/escaping is handled by jq.
# FIELD has been validated as [a-zA-Z_][a-zA-Z0-9_]* so direct interpolation
# into the filter is safe. This helper is read-only — no object construction
# (the silent-reset failure mode of writer-side jq is not applicable here).
#
# JSON null handling: jq's `// $default` operator returns $default when the
# left-hand side is null or false. So `.field // $default` evaluates to
# $default when:
#   - field is missing (jq returns null)
#   - field exists but holds JSON null
#   - field exists but holds JSON false
# This matches the caller-supplied default semantics natively — no
# post-processing is needed. (PR #688 cycle 3 review: previous post-processing
# `if [ "$value" = "null" ]` was demonstrated to be dead code via mutation
# testing; jq's `//` already handles null normalization.)
#
# ⚠️ Boolean field caveat (PR #688 cycle 5 review): jq の `// $default` は **null と
# false の両方** を $default に置換するため、本 helper は boolean field の読み取りには
# **使ってはいけない**。例: `{"active": false}` を `--default true` で読むと結果は "true"
# となり、stored false が silent に default に置換される。現状の caller (`parent_issue_number`
# / `phase` / `loop_count` / `implementation_round`) はすべて非 boolean のため影響なし。
# 将来 boolean field を読む caller を追加する場合は `--default empty` で明示的に取得して
# 別途分岐するか、inline jq を使うこと。
#
# Source: jq Manual — Alternative operator `//`
# https://jqlang.org/manual/#alternative-operator
value=$(jq -r --arg default "$DEFAULT" ".${FIELD} // \$default" "$STATE_FILE" 2>/dev/null) \
  || value="$DEFAULT"

echo "$value"
