#!/bin/bash
# _validate-helpers.sh — Common helper-existence fail-fast validator
#
# verified-review F-06 (MEDIUM): state-read.sh / flow-state-update.sh が
# 同一の 6/7-entry helper list (state-path-resolve.sh / _resolve-session-id.sh / 等) を
# 完全に複製していた DRY 違反を解消。本 helper を caller から呼び出すことで、
# 将来 helper を 1 つ追加する際に 1 ファイル更新のみで済む。Issue #687 root cause
# (caller 6 箇所が `.rite-flow-state` を直接 jq read する片肺更新 drift) と同型の
# 構造的問題を別 layer で再発させないための DRY 化。
#
# Usage:
#   bash "$SCRIPT_DIR/_validate-helpers.sh" "$SCRIPT_DIR" \
#     state-path-resolve.sh _resolve-session-id.sh _resolve-session-id-from-file.sh \
#     _resolve-schema-version.sh _resolve-cross-session-guard.sh \
#     _emit-cross-session-incident.sh _mktemp-stderr-guard.sh
#
# Arguments:
#   $1       script_dir   : Caller の SCRIPT_DIR (helper 群が存在するディレクトリ)
#   $2..$N   helpers      : 検査対象の helper script 名 (basename のみ、複数指定可)
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

set -euo pipefail

if [ "$#" -lt 2 ]; then
  echo "ERROR: _validate-helpers.sh requires at least 2 arguments (script_dir + 1+ helper names)" >&2
  echo "  Usage: bash _validate-helpers.sh <script_dir> <helper_1> [helper_2 ...]" >&2
  exit 1
fi

script_dir="$1"
shift

for _helper in "$@"; do
  if [ ! -x "$script_dir/$_helper" ]; then
    echo "ERROR: $_helper not found or not executable: $script_dir/$_helper" >&2
    echo "  対処: rite plugin が正しくセットアップされているか確認してください" >&2
    exit 1
  fi
done
exit 0
