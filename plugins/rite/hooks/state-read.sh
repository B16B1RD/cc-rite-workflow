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
#   schema_version=2 routes writes to per-session files; inline
#   `jq -r '.<field>' .rite-flow-state` reads stale residue from another
#   session's legacy file — observed in #687 reproduction.
#
# Exit codes:
#   0 — success (value or default printed to stdout)
#   1 — argument error / invalid field name
#
# Evolution history:
#   See plugins/rite/references/state-read-evolution.md for verified-review
#   cycle 5〜43+ structural fixes, doctrines (writer/reader symmetry,
#   DRIFT-CHECK ANCHOR semantic naming, Form A cleanup minimality), and
#   the full list of consolidated helpers.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Helper script existence check (fail-fast on deploy regression).
# Validation logic and helper list are both centralized in _validate-helpers.sh
# (DEFAULT_HELPERS array). Add new helpers there to reflect in both
# state-read.sh / flow-state-update.sh callers via a single line.
# See: plugins/rite/references/state-read-evolution.md (Cycle 12 F-04 / 13 F-01 / 38 F-01 / 38 F-09).
if [ ! -x "$SCRIPT_DIR/_validate-helpers.sh" ]; then
  echo "ERROR: _validate-helpers.sh not found or not executable: $SCRIPT_DIR/_validate-helpers.sh" >&2
  echo "  対処: rite plugin が正しくセットアップされているか確認してください" >&2
  exit 1
fi
bash "$SCRIPT_DIR/_validate-helpers.sh" "$SCRIPT_DIR"

# Resolve repository root via the existing helper (single SoT).
# `||` fallback is a defensive guard for future non-zero return; stderr is
# pass-through so any helper-emitted WARNING/ERROR remains observable.
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

# --- Signal-specific trap (covers both _classify_err and _jq_err lifecycles) ---
# Single cleanup function rm-fs both tempfiles; trap installed at file top
# (before per-session branch) closes the race window for both lifecycles.
# See: plugins/rite/references/state-read-evolution.md (Cycle 35 F-05 / 36 F-15).
_classify_err=""
_jq_err=""
_rite_state_read_cleanup() {
  rm -f "${_classify_err:-}" "${_jq_err:-}"
}
trap 'rc=$?; _rite_state_read_cleanup; exit $rc' EXIT
trap '_rite_state_read_cleanup; exit 130' INT
trap '_rite_state_read_cleanup; exit 143' TERM
trap '_rite_state_read_cleanup; exit 129' HUP

# --- Resolve session_id (matches flow-state-update.sh _resolve_session_id) ---
# UUID-format validation prevents path traversal via tampered .rite-session-id.
# Common helper for tr+UUID-validate+fallback compound sequence shared with
# writer/resume layers (DRY across writer/reader/resume).
# See: plugins/rite/references/state-read-evolution.md (Cycle 34 F-01 / 38 F-05).
SESSION_ID=$(bash "$SCRIPT_DIR/_resolve-session-id-from-file.sh" "$STATE_ROOT")

# --- Resolve schema_version (DRY: shared helper with flow-state-update.sh) ---
# pipefail silent failure handling (Issue #687 AC-4 follow-up) absorbed in helper.
# See: plugins/rite/references/state-read-evolution.md (Cycle 5 review).
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
    # Cross-session guard: classify legacy file as same/empty/foreign/corrupt/invalid_uuid
    # via shared helper, mirrored on both writer/reader sides.
    # stderr is captured to a tempfile via `_mktemp-stderr-guard.sh`, then `^WARNING:`
    # lines are passed through to the caller chain so helper-emitted detail is not
    # silently suppressed under /tmp full / SELinux deny (cycle 41 F-01 doctrine).
    # See: plugins/rite/references/state-read-evolution.md (Cycle 34 F-02 / 35 F-01 /
    # 41 F-01 / 14 F-04 / 15 F-05 / 43 F-09).
    _classify_err=$(bash "$SCRIPT_DIR/_mktemp-stderr-guard.sh" \
      "state-read" "classify-err-reader" \
      "cross-session guard helper の WARNING (mktemp 失敗 / jq stderr) が pass-through されません")
    # Defense-in-depth: capture rc to detect helper contract violation
    # (helper design contract: `exit 0 — always`). Symmetric with writer-side
    # `_resolve-cross-session-guard.sh` invocation in flow-state-update.sh.
    if classification=$(bash "$SCRIPT_DIR/_resolve-cross-session-guard.sh" "$LEGACY_FLOW_STATE" "$SESSION_ID" 2>"${_classify_err:-/dev/null}"); then
      :
    else
      _guard_rc=$?
      echo "WARNING: _resolve-cross-session-guard.sh exited non-zero (rc=$_guard_rc) — design contract violation (helper should always exit 0)" >&2
      classification=""
    fi
    if [ -n "$_classify_err" ] && [ -s "$_classify_err" ]; then
      grep -E '^WARNING:|^  ' "$_classify_err" >&2 2>/dev/null || true
    fi
    [ -n "$_classify_err" ] && rm -f "$_classify_err"
    unset _classify_err
    # 3 classification × 2 caller の workflow-incident-emit ブロック (~84 行) を
    # `_emit-cross-session-incident.sh` に集約。
    # See: plugins/rite/references/state-read-evolution.md (PR #688 followup F-01 MEDIUM).
    case "$classification" in
      same|empty)
        STATE_FILE="$LEGACY_FLOW_STATE"
        ;;
      foreign:*)
        # 別 session の legacy file → foreign session の stale data を silent return しないよう DEFAULT に降格
        legacy_sid="${classification#foreign:}"
        bash "$SCRIPT_DIR/_emit-cross-session-incident.sh" foreign reader "$SESSION_ID" "$legacy_sid"
        echo "$DEFAULT"
        exit 0
        ;;
      corrupt:*)
        # jq 失敗 (corrupt JSON / IO error) → take over は不安全 (cross-session の可能性を否定できない)
        jq_rc="${classification#corrupt:}"
        bash "$SCRIPT_DIR/_emit-cross-session-incident.sh" corrupt reader "$SESSION_ID" "$LEGACY_FLOW_STATE" "$jq_rc"
        echo "$DEFAULT"
        exit 0
        ;;
      invalid_uuid:*)
        # legacy.session_id が JSON-parseable だが UUID validation 失敗 (tampered / legacy schema)。
        # corrupt:* と semantically 等価だが root_cause_hint で incident response 時に区別可能にする。
        invalid_uuid_rc="${classification#invalid_uuid:}"
        bash "$SCRIPT_DIR/_emit-cross-session-incident.sh" invalid_uuid reader "$SESSION_ID" "$LEGACY_FLOW_STATE" "$invalid_uuid_rc"
        echo "$DEFAULT"
        exit 0
        ;;
      *)
        # Helper の出力が想定外 (defensive) — fail-safe に DEFAULT 降格
        echo "WARNING: unexpected classification from _resolve-cross-session-guard.sh: $classification" >&2
        echo "$DEFAULT"
        exit 0
        ;;
    esac
  fi
else
  STATE_FILE="$LEGACY_FLOW_STATE"
fi

# --- Read field ---
# Empty / non-JSON file edge case: `[ -s "$STATE_FILE" ]` (size > 0) ensures
# `touch .rite-flow-state` or partial writes by another process do not silently
# return an empty string — caller-supplied $DEFAULT fires consistently with
# the corrupt-JSON code path.
# See: plugins/rite/references/state-read-evolution.md (Cycle 5 test reviewer F-C MEDIUM).
if [ ! -f "$STATE_FILE" ] || [ ! -s "$STATE_FILE" ]; then
  echo "$DEFAULT"
  exit 0
fi

# Pass DEFAULT through jq's --arg so quoting/escaping is handled by jq.
# FIELD has been validated as [a-zA-Z_][a-zA-Z0-9_]* so direct interpolation
# into the filter is safe. This helper is read-only.
#
# `.field // $default` returns $default when field is missing (null) or holds
# JSON null/false — caller default semantics are matched natively, no
# post-processing needed.
#
# ⚠️ Boolean field caveat: jq の `// $default` は null と false の両方を $default に
# 置換するため、本 helper は boolean field の読み取りには使ってはいけない
# (例: `{"active": false}` を `--default true` で読むと結果が "true"、stored false が
# silent に default に置換される)。現状の caller (`parent_issue_number` / `phase` /
# `loop_count` / `implementation_round` / `pr_number`) はすべて非 boolean。将来 boolean
# field を読む場合は `--default empty` + caller 側分岐、または inline jq を使うこと。
#
# Mechanical guard: WARNING on `--default true|false` flags erroneous boolean reads.
case "$DEFAULT" in
  true|false)
    echo "WARNING: state-read.sh: --default '$DEFAULT' は boolean リテラル値です。boolean field の読み取りには本 helper を使わないでください (jq の \`// \$default\` 演算子が JSON null と false の両方を default に置換するため、stored false が silent に true に置換される regression を起こします)。non-boolean field (parent_issue_number / phase / loop_count / pr_number 等) のみが現状サポート対象です。boolean field が必要な場合は \`--default empty\` を使い caller 側で明示分岐するか、inline jq を使ってください。" >&2
    ;;
esac

# jq stderr captured via `_mktemp-stderr-guard.sh` so parse errors surface as
# WARNING (`head -3`) instead of being suppressed by `2>/dev/null`. Symmetric
# with `_resolve-cross-session-guard.sh` jq stderr capture pattern.
# See: plugins/rite/references/state-read-evolution.md (Cycle 35 F-09 / 38 F-04).
# jq Manual — Alternative operator: https://jqlang.org/manual/#alternative-operator
_jq_err=$(bash "$SCRIPT_DIR/_mktemp-stderr-guard.sh" \
  "state-read" "state-read-jq-err" \
  "jq 失敗時の parse error 詳細が表示されません (caller は corrupt JSON を検知できますが原因 line/column が失われます)")
if value=$(jq -r --arg default "$DEFAULT" ".${FIELD} // \$default" "$STATE_FILE" 2>"${_jq_err:-/dev/null}"); then
  :
else
  value="$DEFAULT"
  [ -n "$_jq_err" ] && [ -s "$_jq_err" ] && head -3 "$_jq_err" | sed 's/^/  WARNING: jq parse: /' >&2
fi

echo "$value"
