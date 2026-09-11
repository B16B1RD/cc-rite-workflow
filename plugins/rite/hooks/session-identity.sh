#!/bin/bash
# Runtime session selection, shared by lifecycle adapters and state consumers.
# Executable: stdout=real host ID; rc 0=selected, 2=no runtime context (legacy
# file/payload fallback permitted), 1=invalid/missing/ambiguous runtime identity.
# RITE_HOST selects identity only; it does not advertise lifecycle capabilities.
RITE_IDENTITY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=control-char-neutralize.sh
source "$RITE_IDENTITY_DIR/control-char-neutralize.sh"

# Layer 1 security boundary: reject traversal/control bytes, accept opaque IDs.
# Kept separate from _resolve-session-id.sh's Layer 2 strict UUID contract.
validate_session_id_path() {
  # `origin` (引数 2) は session_id の出所 (override / SESSION_ID_FILE / env var) を識別する
  # エラーメッセージ用ラベル。bash builtin `source` の shadow を避けるため `origin` を採用。
  local sid="$1" origin="$2"
  case "$sid" in
    *..*|*/*)
      echo "ERROR: invalid session_id from $origin: contains path-traversal characters ('..' or '/')" >&2
      return 1
      ;;
  esac
  # contains_ctrl (control-char-neutralize.sh) は C0 + DEL + C1 8-bit (0x80-0x9f)
  # をバイト単位で検出する。旧 `=~ [[:cntrl:]]` は glibc が C1 を cntrl と分類しない
  # ため 0x9b (8-bit CSI) 入り session_id を素通ししていた。
  if contains_ctrl "$sid"; then
    echo "ERROR: invalid session_id from $origin: contains control characters (newline / tab / C1 8-bit bytes / etc.)" >&2
    return 1
  fi
  return 0
}

resolve_runtime_session_id() {
  local host="${RITE_HOST:-}" sid="" count=0
  if [ -z "$host" ]; then
    if [ -n "${CLAUDE_CODE_SESSION_ID:-}${CLAUDE_SESSION_ID:-}" ]; then host=claude; count=$((count + 1)); fi
    if [ "${CODEX_THREAD_ID+x}" = x ]; then host=codex; count=$((count + 1)); fi
    if [ "${GROK_SESSION_ID+x}" = x ]; then host=grok; count=$((count + 1)); fi
    [ "$count" -gt 0 ] || return 2
    if [ "$count" -gt 1 ]; then
      echo "ERROR: ambiguous runtime session identity; set RITE_HOST to claude, codex, or grok" >&2
      return 1
    fi
  fi
  case "$host" in
    claude) sid="${CLAUDE_CODE_SESSION_ID:-${CLAUDE_SESSION_ID:-}}" ;;
    codex) sid="${CODEX_THREAD_ID:-}" ;;
    grok) sid="${GROK_SESSION_ID:-}" ;;
    *) echo "ERROR: unsupported RITE_HOST; expected claude, codex, or grok" >&2; return 1 ;;
  esac
  if [ -z "$sid" ]; then
    echo "ERROR: cannot resolve session_id for RITE_HOST=$host; its runtime session ID is required" >&2
    return 1
  fi
  validate_session_id_path "$sid" "$host runtime env" || return 1
  # UUID readers share Layer 2's lowercase spelling; opaque IDs remain opaque.
  if [[ "$sid" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
    sid=$(printf '%s' "$sid" | tr 'A-F' 'a-f')
  fi
  printf '%s\n' "$sid"
}

# Layer 2 consumer entry: explicit override first, selected runtime second,
# stored UUID only when no runtime was selected. Invalid runtime/override never
# borrows an unrelated shared session-id file.
resolve_strict_session_id() {
  local state_root="$1" candidate="${2:-}" rc=0 sid=""
  if [ -z "$candidate" ]; then
    candidate=$(resolve_runtime_session_id) || rc=$?
    case "$rc" in
      0) ;;
      2) bash "$RITE_IDENTITY_DIR/_resolve-session-id-from-file.sh" "$state_root"; return $? ;;
      *) return 1 ;;
    esac
  fi
  if sid=$(bash "$RITE_IDENTITY_DIR/_resolve-session-id.sh" "$candidate"); then
    printf '%s\n' "$sid"
  else
    echo "ERROR: invalid session_id: claim/lock ownership requires a canonical UUID" >&2
    return 1
  fi
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  resolve_runtime_session_id
fi
