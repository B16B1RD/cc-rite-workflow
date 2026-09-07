#!/bin/bash
# rite workflow - Session ID Resolution from .rite-session-id File (private internal helper)
#
# Reads `<state_root>/.rite-session-id`, strips whitespace, and runs the result
# through `_resolve-session-id.sh` for RFC 4122 UUID validation. Returns the
# validated UUID on stdout, or empty string on any failure path (file absent /
# read failed / validation failed). Exit 0 in all cases (caller distinguishes
# present-and-valid vs absent/invalid via empty-string check).
#
# Usage:
#   sid=$(bash plugins/rite/hooks/_resolve-session-id-from-file.sh "$STATE_ROOT")
#
# Arguments:
#   $1 state_root  Directory containing `.rite-session-id` (typically the repo root
#                  resolved via `state-path-resolve.sh`)
#
# Output:
#   stdout: validated UUID, or empty string when:
#     - <state_root>/.rite-session-id is absent
#     - file is empty after whitespace stripping
#     - content fails UUID validation
#
# Exit codes:
#   0 — always (output empty string on any failure path so callers can rely on
#       a single command-substitution capture pattern: `sid=$(... )`)
#   1 — argument error (missing state_root)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=control-char-neutralize.sh
source "$SCRIPT_DIR/control-char-neutralize.sh"

# UUID validation は stderr を抑制するため、helper 不在や権限不足を
# 不正 UUID による空文字復帰と区別できるよう、依存 helper を先に検査する。
if [ ! -x "$SCRIPT_DIR/_resolve-session-id.sh" ]; then
  echo "ERROR: required helper not found or not executable: $SCRIPT_DIR/_resolve-session-id.sh" >&2
  echo "  本 helper (_resolve-session-id-from-file.sh) は _resolve-session-id.sh に UUID validation を委譲しています。" >&2
  echo "  対処: rite plugin が完全にデプロイされているか確認してください (部分配置 / chmod -x / git mv 漏れの可能性)" >&2
  exit 1
fi

STATE_ROOT="${1:-}"
if [ -z "$STATE_ROOT" ]; then
  echo "ERROR: usage: $0 <state_root>" >&2
  exit 1
fi

# STATE_ROOT path traversal / shell metacharacter / control character validation
# は `_validate-state-root.sh` に集約。詳細な threat model と検証ルールは helper
# 内コメントを参照。本 helper を直接呼ぶ untrusted 経路 (`STATE_ROOT="../../"` 等)
# に対する defence-in-depth として実行する。
# `_validate-helpers.sh` 経由で存在確認すると ERROR 文言の SoT が同 helper の
# ERROR 出力ブロック (`echo "ERROR: $_helper not found or not executable: ..."`) に集約され、
# 片肺更新型 drift を構造的に防げる。
bash "$SCRIPT_DIR/_validate-helpers.sh" "$SCRIPT_DIR" _validate-state-root.sh || exit $?
bash "$SCRIPT_DIR/_validate-state-root.sh" "$STATE_ROOT" || exit $?

# New path first. If the new file exists it is the sole source — an invalid
# UUID there must NOT fall through to a valid legacy file.
if [ -f "$STATE_ROOT/.rite/session-id" ]; then
  sid_file="$STATE_ROOT/.rite/session-id"
elif [ -f "$STATE_ROOT/.rite-session-id" ]; then
  sid_file="$STATE_ROOT/.rite-session-id"
else
  # File-absent path: return empty string (legitimate "no session id stored yet").
  exit 0
fi

# Whitespace-stripped read.
#
# `2>/dev/null || raw=""` の素朴な実装は permission denied / inode race / EIO 等の IO エラーを「空ファイル」と
# 区別不能にする。攻撃者が `.rite-session-id` を chmod 000 にした状態で別 session の
# session_id を持つ legacy `.rite-flow-state` を残すと、helper が空文字を返し state-read.sh が
# legacy 経路にフォールバック → cross-session guard が空 SID で意図しない経路を通る。
# そのため stderr を tempfile に退避し、IO error は WARNING を emit してから空文字復帰する (caller の
# graceful degradation 動作は維持しつつ、observability を確保)。
# `_mktemp-stderr-guard.sh` が作成失敗時の WARNING と chmod 600 を担い、
# trap が SIGINT/SIGTERM/SIGHUP を含む終了経路で一時ファイルを削除する。
_tr_err=""
_rite_resolve_sid_cleanup() {
  rm -f "${_tr_err:-}"
}
trap 'rc=$?; _rite_resolve_sid_cleanup; exit $rc' EXIT
trap '_rite_resolve_sid_cleanup; exit 130' INT
trap '_rite_resolve_sid_cleanup; exit 143' TERM
trap '_rite_resolve_sid_cleanup; exit 129' HUP

_tr_err=$(bash "$SCRIPT_DIR/_mktemp-stderr-guard.sh" \
  "_resolve-session-id-from-file" "resolve-sid-tr-err" \
  "tr 失敗時の error 詳細が表示されません")

if raw=$(tr -d '[:space:]' < "$sid_file" 2>"${_tr_err:-/dev/null}"); then
  : # tr success (raw may be empty for empty file — legitimate)
else
  _tr_rc=$?
  echo "WARNING: _resolve-session-id-from-file.sh: tr が IO/permission エラーで失敗しました (rc=$_tr_rc)" >&2
  if [ -n "$_tr_err" ] && [ -s "$_tr_err" ]; then
    head -3 "$_tr_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
  fi
  echo "  対処: $sid_file の permission / inode 健全性を確認してください" >&2
  echo "  影響: graceful degradation で空文字復帰しますが、cross-session guard が空 SID で経路判定する可能性があります" >&2
  raw=""
fi
# trap が EXIT 経路で _tr_err を削除するため、ここでは明示 rm + unset で trap の二重実行を回避
[ -n "$_tr_err" ] && rm -f "$_tr_err"
_tr_err=""
if [ -z "$raw" ]; then
  exit 0
fi

# Run through the canonical UUID validator. On validation failure, fall through
# to the implicit empty-string output (exit 0 with no stdout). Callers cannot
# distinguish "file empty" from "file invalid" from "validation failed": all three
# paths collapse to `sid=""` and downstream code treats the session as effectively
# missing. This is the contract the inline caller logic relies on.
if validated=$(bash "$SCRIPT_DIR/_resolve-session-id.sh" "$raw" 2>/dev/null); then
  printf '%s' "$validated"
fi
