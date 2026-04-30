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
#   The same schema_version resolution logic was previously inlined in:
#     - state-read.sh (reader-side, in the SCHEMA_VERSION resolution block before _resolve-schema-version.sh extraction)
#     - flow-state-update.sh _resolve_schema_version (writer-side, in the inline cfg/section/grep/case block before extraction)
#   Both implementations went through cycle 1 (silent failure detection) and
#   cycle 3 (`|| v=""` pipefail guard added to both). DRY-ifying eliminates
#   the drift risk where a future micro-fix is applied to one side only.
#   (verified-review cycle 29 F-05 MEDIUM: cycle 28 で確立した semantic anchor 規範を本箇所
#   にも適用。旧 "line 80-102" / "line 102-110" は抽出後に意味的に不可能な参照だった)
#
# Exit codes:
#   0 — always (echoes "1" or "2" on stdout)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_ROOT="${1:-$(pwd)}"

# STATE_ROOT path traversal / shell metacharacter / control character validation
# は `_validate-state-root.sh` に集約。writer/reader/schema 3 layer の validation
# 対称化 doctrine を 1 つの helper で表現する。詳細な threat model と検証ルールは
# helper 内コメントを参照。
# `_validate-helpers.sh` 経由で存在確認すると ERROR 文言の SoT が同 helper の
# ERROR 出力ブロック (`echo "ERROR: $_helper not found or not executable: ..."`) に集約され、
# 片肺更新型 drift を構造的に防げる。
# (`_resolve-session-id-from-file.sh` 内の同型 _validate-helpers 呼び出しブロック直前のコメントと同形式に統一)
bash "$SCRIPT_DIR/_validate-helpers.sh" "$SCRIPT_DIR" _validate-state-root.sh || exit $?
bash "$SCRIPT_DIR/_validate-state-root.sh" "$STATE_ROOT" || exit $?

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
