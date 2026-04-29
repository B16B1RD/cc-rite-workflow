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

STATE_ROOT="${1:-$(pwd)}"

# Defense-in-depth: STATE_ROOT を直接 caller (state-path-resolve.sh / pwd 由来) からのみ受理する想定だが、
# helper API 単体の sandbox として `_resolve-session-id-from-file.sh:90-107` と同型の validation を実施する。
# 攻撃面: 多重テナント環境で攻撃者が rite plugin を install したコマンドを driving できる場合、
# `bash _resolve-schema-version.sh "/etc"` で `/etc/rite-config.yml` 存在性を probe したり、
# command substitution / path traversal で sandbox 外ファイルを読み出す経路を遮断する。
# writer/reader/schema 3 layer の validation 対称化 doctrine の完成。
case "$STATE_ROOT" in
  *..*|*'$'*|*'`'*)
    echo "ERROR: STATE_ROOT contains unsafe traversal or shell metacharacter: '$STATE_ROOT'" >&2
    echo "  本 helper は親ディレクトリ参照 (..) / shell expansion (\$) / command substitution (\`) を含む path を受理しません。" >&2
    echo "  対処: caller (state-path-resolve.sh / pwd 由来 path) を経由して正規化された path を渡してください。" >&2
    exit 1
    ;;
esac
# 制御文字 (newline / carriage return / 0x00-0x1F / 0x7F) も独立 check で reject する。
# bash の case glob では `\n` / `\r` を含む pattern が portable に書けないため、`tr -d '[:cntrl:]'` で
# 制御文字を除去した結果と元 STATE_ROOT を比較する方式で検出する。
state_root_sanitized=$(printf '%s' "$STATE_ROOT" | tr -d '[:cntrl:]')
if [ "$state_root_sanitized" != "$STATE_ROOT" ]; then
  echo "ERROR: STATE_ROOT contains control characters (newline / NUL / 0x00-0x1F / 0x7F)" >&2
  echo "  対処: caller (state-path-resolve.sh / pwd 由来 path) を経由して正規化された path を渡してください。" >&2
  exit 1
fi
unset state_root_sanitized

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
