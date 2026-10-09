#!/bin/bash
# rite workflow - merge method resolver for /rite:merge
#
# Reads `merge.method` from the rite-config.yml that lib/rite-config-path.sh
# resolves (the worktree's own file, else the main checkout's) and prints the
# `gh pr merge` method flag name.
#
# Usage: bash merge-method-resolve.sh [dir]   (dir defaults to the current directory)
#
# Output (stdout, exactly one line):
#   [CONTEXT] MERGE_METHOD=squash|merge
#   [CONTEXT] MERGE_METHOD=invalid; value=<raw>; config=<path>
#   [CONTEXT] MERGE_METHOD=invalid; reason=config_unreadable
#
# Exit codes:
#   0  method resolved. No config file, no `merge:` section, or no `method:` key
#      → squash (configs written before the key existed keep their behavior)
#   1  invalid value (empty, unknown, or not lower case) or unreadable config;
#      stderr names the cause and the accepted values. Never falls back to squash.
set -uo pipefail

dir="${1:-$PWD}"
lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/rite-config-path.sh"

config_rc=0
config=$(bash "$lib" "$dir" 2>/dev/null) || config_rc=$?
case "$config_rc" in
  0) ;;
  1) echo "[CONTEXT] MERGE_METHOD=squash"; exit 0 ;;
  *)
    echo "ERROR: rite-config.yml を読めないため、マージ方式を決められません (dir=$dir)" >&2
    # The first call ran with stderr discarded so that rc=1 stays quiet; rerun to show the cause.
    { bash "$lib" "$dir" 2>&1 >/dev/null || true; } | sed 's/^/  /' >&2
    echo "[CONTEXT] MERGE_METHOD=invalid; reason=config_unreadable"
    exit 1
    ;;
esac

# Only a direct child `method:` of the top-level `merge:` section counts; a
# deeper `method:` belongs to some other mapping. `merge: <scalar>` is a
# misplaced value and is reported as invalid rather than ignored.
found=$(awk '
  /^merge:[[:space:]]*(#.*)?$/ { insec = 1; ind = -1; next }
  /^merge:/ { v = $0; sub(/^merge:[[:space:]]*/, "", v); print "inline\t" v; exit }
  insec && /^[^[:space:]#]/ { exit }
  insec && /^[[:space:]]*(#.*)?$/ { next }
  insec {
    match($0, /^[[:space:]]*/); cur = RLENGTH
    if (ind < 0) ind = cur
    if (cur == ind && $0 ~ /^[[:space:]]*method:/) {
      v = $0; sub(/^[[:space:]]*method:/, "", v); print "method\t" v; exit
    }
  }' "$config") || {
  echo "ERROR: rite-config.yml を解析できません: $config" >&2
  echo "[CONTEXT] MERGE_METHOD=invalid; reason=config_unreadable"
  exit 1
}

if [ -z "$found" ]; then
  echo "[CONTEXT] MERGE_METHOD=squash"
  exit 0
fi

raw="${found#*$'\t'}"
value=$(printf '%s' "$raw" | sed 's/[[:space:]]#.*//; s/^[[:space:]]*//; s/[[:space:]]*$//')
case "$value" in
  \"*\") value="${value#\"}"; value="${value%\"}" ;;
  \'*\') value="${value#\'}"; value="${value%\'}" ;;
esac

case "${found%%$'\t'*}:$value" in
  method:squash|method:merge)
    echo "[CONTEXT] MERGE_METHOD=$value"
    exit 0
    ;;
esac

echo "ERROR: rite-config.yml の merge.method が不正です: '$value' (使える値: squash / merge)。$config を直してから再実行してください" >&2
echo "[CONTEXT] MERGE_METHOD=invalid; value=$value; config=$config"
exit 1
