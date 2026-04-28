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

sid_file="$STATE_ROOT/.rite-session-id"

# File-absent path: return empty string (legitimate "no session id stored yet").
# This matches the previous inline behavior `if [ -f ... ]; then ... fi` where
# the absent branch left `sid=""` untouched.
if [ ! -f "$sid_file" ]; then
  exit 0
fi

# Whitespace-stripped read. `2>/dev/null || raw=""` keeps the previous behavior
# of treating IO errors (permission denied / inode race) as "no session id"
# rather than fail-fast — caller chains have always degraded gracefully here.
raw=$(tr -d '[:space:]' < "$sid_file" 2>/dev/null) || raw=""
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
