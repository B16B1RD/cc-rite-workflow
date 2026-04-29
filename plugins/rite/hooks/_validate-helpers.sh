#!/bin/bash
# _validate-helpers.sh — Common helper-existence fail-fast validator
#
# verified-review F-06 (MEDIUM): state-read.sh / flow-state-update.sh が同一の
# helper list (state-path-resolve.sh / _resolve-session-id.sh / 等) を完全に複製
# していた DRY 違反を解消。本 helper を caller から呼び出すことで、将来 helper を
# 1 つ追加する際に 1 ファイル更新のみで済む。Issue #687 root cause (caller 6 箇所が
# `.rite-flow-state` を直接 jq read する片肺更新 drift) と同型の構造的問題を別
# layer で再発させないための DRY 化。
#
# PR #688 cycle 13 F-01 (HIGH): caller の helper-list 自体の duplication を解消する。
# state-read.sh と flow-state-update.sh が同一 list を byte-for-byte 重複保持していた
# 問題に対応するため、本 helper 内に **DEFAULT_HELPERS 配列** を追加し、引数 0 個
# (script_dir のみ) で呼ばれた場合は default list を使う API 拡張を行う。これにより
# 両 caller の hardcoded list を 1 行の helper 呼び出しに置換できる。
# 履歴詳細 (entry 数の変遷) は references/state-read-evolution.md を参照。
#
# Usage:
#   # 推奨形式 (DEFAULT_HELPERS 使用):
#   bash "$SCRIPT_DIR/_validate-helpers.sh" "$SCRIPT_DIR"
#
#   # 後方互換形式 (明示 list 使用):
#   bash "$SCRIPT_DIR/_validate-helpers.sh" "$SCRIPT_DIR" \
#     state-path-resolve.sh _resolve-session-id.sh _resolve-session-id-from-file.sh \
#     _resolve-schema-version.sh _resolve-cross-session-guard.sh \
#     _emit-cross-session-incident.sh _mktemp-stderr-guard.sh
#
# Arguments:
#   $1       script_dir   : Caller の SCRIPT_DIR (helper 群が存在するディレクトリ)
#   $2..$N   helpers      : 検査対象の helper script 名 (basename のみ、複数指定可)
#                          省略時は本 helper 内の DEFAULT_HELPERS 配列を使用
#
# Exit code:
#   0 — 全 helper が存在し executable
#   1 — いずれかの helper が missing or not executable (stderr に ERROR 詳細)
#
# Output:
#   失敗時のみ stderr に ERROR 行を emit。成功時は silent。
#
# Rationale:
#   `set -euo pipefail` 下でも `if [ ! -x ...]` block は non-blocking として扱われ、
#   bash が exit 127 を silent suppression する経路が散在する。本 helper で upfront
#   fail-fast 検査することで Issue #687 同型の deploy regression を構造的に塞ぐ。
#
# DEFAULT_HELPERS scope (PR #688 cycle 13 F-01):
#   state-read.sh と flow-state-update.sh が依存する core helper set。両 caller は
#   `bash <missing>` invocation 経路でこれらを direct/transitive に依存する。
#   resume-active-flag-restore.sh は別 scope (resume layer の独自依存) のため、
#   引き続き明示的な list で呼び出す。

set -euo pipefail

# DEFAULT_HELPERS: state-read.sh / flow-state-update.sh が共有する core helper set。
# 本配列が helper-list の Single Source of Truth。helper を 1 つ追加する際は本配列に
# 1 行追加するだけで両 caller に反映される (writer/reader 対称化 doctrine の構造的実装)。
DEFAULT_HELPERS=(
  state-path-resolve.sh
  _resolve-session-id.sh
  _resolve-session-id-from-file.sh
  _resolve-schema-version.sh
  _resolve-cross-session-guard.sh
  _emit-cross-session-incident.sh
  _mktemp-stderr-guard.sh
  _validate-state-root.sh
)

if [ "$#" -lt 1 ]; then
  echo "ERROR: _validate-helpers.sh requires at least 1 argument (script_dir)" >&2
  echo "  Usage: bash _validate-helpers.sh <script_dir> [helper_1] [helper_2 ...]" >&2
  echo "  <script_dir> のみ (helpers 引数なし) で呼ぶと内部の DEFAULT_HELPERS 配列を使用します" >&2
  exit 1
fi

script_dir="$1"
shift

# Argument count branching:
#   $# == 0: caller が default helper set を要求 → DEFAULT_HELPERS 配列を使用
#   $# >= 1: caller が明示 list を渡した → 後方互換、その list を使用
if [ "$#" -eq 0 ]; then
  set -- "${DEFAULT_HELPERS[@]}"
fi

for _helper in "$@"; do
  if [ ! -x "$script_dir/$_helper" ]; then
    echo "ERROR: $_helper not found or not executable: $script_dir/$_helper" >&2
    echo "  対処: rite plugin が正しくセットアップされているか確認してください" >&2
    exit 1
  fi
done
exit 0
