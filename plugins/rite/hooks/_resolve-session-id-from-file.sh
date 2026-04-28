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
# Why this exists (verified-review cycle 38 F-05 MEDIUM):
#   The compound sequence
#     `tr -d '[:space:]' < <state_root>/.rite-session-id` + `_resolve-session-id.sh`
#     validation + `sid=""` fallback
#   was duplicated across 3 sites:
#     - state-read.sh の per-session resolver
#     - flow-state-update.sh `_resolve_session_id` 関数 (sid_file 経路)
#     - resume-active-flag-restore.sh の `.rite-session-id` 読込ブロック
#   UUID validation 自体は cycle 34 F-01 で `_resolve-session-id.sh` に DRY 化済だが、
#   その上流の compound 動作 (file read + whitespace stripping + validation + fallback)
#   は残存していた。将来「session_id を hex normalize する」「base64-encoded UUID を許容」等の
#   追加で同型片肺更新 drift リスクを抱える経路を構造的に防ぐ。
#
# Caller migration (cycle 38 F-05):
#   Before (10 lines): `if [ -f "$root/.rite-session-id" ]; then ... raw=$(tr -d ...);`
#                      `if validated=$(bash _resolve-session-id.sh "$raw"); then ...; fi; fi`
#   After  (1 line):   `sid=$(bash _resolve-session-id-from-file.sh "$STATE_ROOT")`
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# verified-review (PR #688 cycle 39 H-01) MEDIUM (silent-failure-hunter):
# `_resolve-session-id.sh` の存在 check を upfront で実施する。
# 旧実装 (cycle 39 helper check 追加前) は本ファイル末尾の `_resolve-session-id.sh` invocation
# (`if validated=$(bash "$SCRIPT_DIR/_resolve-session-id.sh" "$raw" 2>/dev/null); then ...`) で
# stderr を suppress していたため、helper missing (rc=127) / permission denied / bash 起動失敗 と
# validation 失敗 (rc=1) が区別不能 (両方とも「stdout 空文字 + exit 0」で復帰) だった。
# state-read.sh / flow-state-update.sh は upfront で `[ ! -x ]` check を実施しているため、
# それらの caller 経由では deploy regression が早期に検出されるが、本 helper を直接呼ぶ
# 新規 caller が出現した場合に Issue #687 同型の silent skip 経路を作る。
# state-read.sh の helper existence check ブロック (`for _helper in state-path-resolve.sh ... ; do
# [ ! -x ... ] ; done` loop) と同型に統一する。
# verified-review cycle 40: cycle 39 で「L77」「state-read.sh L49-57」と書いた行番号参照を
# semantic anchor (本ファイル末尾の invocation / helper existence check ブロック) に置換
# (cycle 38 F-04 DRIFT-CHECK ANCHOR 原則と整合)。
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

# F-08 (MEDIUM, security Hypothetical exception): STATE_ROOT path traversal validation.
# 旧実装は STATE_ROOT を空チェックのみで受け、`sid_file="$STATE_ROOT/.rite-session-id"` と
# path 結合していた。caller (state-read.sh / flow-state-update.sh / resume-active-flag-restore.sh) は
# すべて state-path-resolve.sh 経由で解決した値を渡しているため現状実害はないが、本 helper を
# 直接呼ぶ将来 caller (cycle 39 H-01 のコメントが言及している「新規 caller」) が
# `STATE_ROOT="../../"` 等の untrusted 値を渡した場合、`.rite-session-id` の symlink に従って
# sandbox 外の hex 文字列 (例: /etc/machine-id) を読み、_resolve-session-id.sh が UUID validation を
# 通過すれば session takeover 判定に流入する経路があった (Hypothetical / security exception)。
# 親ディレクトリ参照 `..` と shell metacharacter `$` を含む値を reject することで、helper 単体の
# defense-in-depth を確保する (caller 信頼境界が破られた場合でも sandbox を維持)。
case "$STATE_ROOT" in
  *..*|*'$'*)
    echo "ERROR: STATE_ROOT contains unsafe traversal or shell metacharacter: '$STATE_ROOT'" >&2
    echo "  本 helper は親ディレクトリ参照 (..) や shell expansion (\$) を含む path を受理しません。" >&2
    echo "  対処: caller (state-path-resolve.sh / pwd 由来 path) を経由して正規化された path を渡してください。" >&2
    exit 1
    ;;
esac

sid_file="$STATE_ROOT/.rite-session-id"

# File-absent path: return empty string (legitimate "no session id stored yet").
# This matches the previous inline behavior `if [ -f ... ]; then ... fi` where
# the absent branch left `sid=""` untouched.
if [ ! -f "$sid_file" ]; then
  exit 0
fi

# Whitespace-stripped read.
#
# PR #688 followup: cycle 41 review F-16 LOW (security Hypothetical exception) — 旧実装
# `2>/dev/null || raw=""` は permission denied / inode race / EIO 等の IO エラーを「空ファイル」と
# 区別不能化していた。攻撃者が `.rite-session-id` を chmod 000 にした状態で別 session の
# session_id を持つ legacy `.rite-flow-state` を残すと、helper が空文字を返し state-read.sh が
# legacy 経路にフォールバック → cross-session guard が空 SID で意図しない経路を通る。
# stderr を tempfile に退避し、IO error は WARNING を emit してから空文字復帰する (caller の
# graceful degradation 動作は維持しつつ、observability を確保)。
# cycle 43 F-08 (MEDIUM) 対応: mktemp 失敗 WARNING 統一 + chmod 600 + canonical 4 行 trap。
# 他 5 helper (state-read.sh:267 / _resolve-cross-session-guard.sh:93 / flow-state-update.sh:282,422 /
# resume-active-flag-restore.sh:180) で確立した canonical pattern と対称化する。
# 旧実装は (a) mktemp 失敗時に WARNING emit せず silent fallback、(b) chmod 600 path-disclosure
# defense なし、(c) trap 不在で SIGINT/SIGTERM/SIGHUP 経路で _tr_err orphan のリスク があった。
# error-handling-reviewer Likelihood-Evidence: existing_call_site で実証済み。
_tr_err=""
_rite_resolve_sid_cleanup() {
  rm -f "${_tr_err:-}"
}
trap 'rc=$?; _rite_resolve_sid_cleanup; exit $rc' EXIT
trap '_rite_resolve_sid_cleanup; exit 130' INT
trap '_rite_resolve_sid_cleanup; exit 143' TERM
trap '_rite_resolve_sid_cleanup; exit 129' HUP

# F-02 (MEDIUM) consolidation: 共通 helper `_mktemp-stderr-guard.sh` 経由で
# Stderr emit + chmod 600 + path return を集約 (PR #688 cycle 9 F-02)。
# chmod 600 (cycle 41 F-14 と対称化、multi-user 環境で session_id leak 防止) は helper 内に内蔵済。
_tr_err=$(bash "$SCRIPT_DIR/_mktemp-stderr-guard.sh" \
  "_resolve-session-id-from-file" "resolve-sid-tr-err" \
  "tr 失敗時の error 詳細が表示されません")

if raw=$(tr -d '[:space:]' < "$sid_file" 2>"${_tr_err:-/dev/null}"); then
  : # tr success (raw may be empty for empty file — legitimate)
else
  _tr_rc=$?
  echo "WARNING: _resolve-session-id-from-file.sh: tr が IO/permission エラーで失敗しました (rc=$_tr_rc)" >&2
  if [ -n "$_tr_err" ] && [ -s "$_tr_err" ]; then
    head -3 "$_tr_err" | sed 's/^/  /' >&2
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
# distinguish "file empty" from "file invalid" from "validation failed", which
# matches the prior inline semantics — all three paths previously collapsed to
# `sid=""` and downstream code treated the session as effectively missing.
if validated=$(bash "$SCRIPT_DIR/_resolve-session-id.sh" "$raw" 2>/dev/null); then
  printf '%s' "$validated"
fi
