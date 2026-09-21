#!/bin/bash
# Blocking write/read for required commit records that do not fit the
# project commit convention (root cause, acknowledged-finding audit).
# Callers pass an existing store path (PR body draft, local work memory,
# or review-results sidecar). This helper does not interpret conventions.
#
# Usage:
#   bash commit-overflow-record.sh write --file ABS --section NAME --body-file ABS
#   bash commit-overflow-record.sh read  --file ABS --section NAME
#
# write replaces a previous section of the same name in the store file.
# The section is a level-2 heading `## {NAME}` through the next `## ` or EOF.
#
# Exit:
#   0  write verified / section found
#   1  argument or IO failure (write never reports success on a failed store)
#   2  read: file exists but section is missing
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../control-char-neutralize.sh
source "$SCRIPT_DIR/../control-char-neutralize.sh"

CMD="${1:-}"
[ $# -gt 0 ] && shift
FILE=""
SECTION=""
BODY_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --file)
      [ $# -ge 2 ] || { echo "ERROR: --file requires a value" >&2; exit 1; }
      FILE="$2"; shift 2 ;;
    --section)
      [ $# -ge 2 ] || { echo "ERROR: --section requires a value" >&2; exit 1; }
      SECTION="$2"; shift 2 ;;
    --body-file)
      [ $# -ge 2 ] || { echo "ERROR: --body-file requires a value" >&2; exit 1; }
      BODY_FILE="$2"; shift 2 ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

case "$CMD" in write|read) ;; *)
  echo "ERROR: usage: commit-overflow-record.sh write|read --file ABS --section NAME [--body-file ABS]" >&2
  exit 1
  ;;
esac

abs_readable() {
  local path="$1" label="$2"
  case "$path" in
    /*) ;;
    *) echo "ERROR: $label は絶対パスである必要があります" >&2; exit 1 ;;
  esac
  if contains_ctrl "$path"; then
    echo "ERROR: $label のパスに制御文字が含まれます" >&2
    exit 1
  fi
}

abs_readable "$FILE" "--file"
[ -n "$SECTION" ] || { echo "ERROR: --section is required" >&2; exit 1; }
if contains_ctrl "$SECTION"; then
  echo "ERROR: --section に制御文字を含められません" >&2
  exit 1
fi
case "$SECTION" in
  *$'\n'*|*$'\r'*)
    echo "ERROR: --section に改行を含められません" >&2
    exit 1
    ;;
esac

extract_section() {
  awk -v name="$SECTION" '
    BEGIN { heading="## " name }
    $0 == heading { grab=1; next }
    grab && /^## / { exit }
    grab { print }
  ' "$1"
}

if [ "$CMD" = read ]; then
  if [ ! -f "$FILE" ] || [ ! -r "$FILE" ]; then
    echo "ERROR: 記録ファイルを読めません: $FILE" >&2
    exit 1
  fi
  body=$(extract_section "$FILE")
  if [ -z "$body" ]; then
    echo "ERROR: 必須記録セクションが見つかりません: ## $SECTION ($FILE)" >&2
    exit 2
  fi
  printf '%s' "$body"
  printf '%s' "$body" | grep -q $'\n$' || printf '\n'
  exit 0
fi

abs_readable "$BODY_FILE" "--body-file"
if [ ! -f "$BODY_FILE" ] || [ ! -r "$BODY_FILE" ]; then
  echo "ERROR: --body-file を読めません: $BODY_FILE" >&2
  exit 1
fi
dir=$(dirname "$FILE")
mkdir -p "$dir" || {
  echo "ERROR: 記録ディレクトリを作成できません: $dir" >&2
  exit 1
}

tmp=$(mktemp "${TMPDIR:-/tmp}/rite-overflow-XXXXXX") || {
  echo "ERROR: 記録用一時ファイルを作成できません" >&2
  exit 1
}
cleanup() { rm -f "$tmp"; }
trap cleanup EXIT INT TERM HUP

if [ -f "$FILE" ]; then
  awk -v name="$SECTION" '
    BEGIN { heading="## " name }
    $0 == heading { skip=1; next }
    skip && /^## / { skip=0 }
    skip { next }
    { print }
  ' "$FILE" > "$tmp" || {
    echo "ERROR: 既存の記録ファイルを処理できません: $FILE" >&2
    exit 1
  }
else
  : > "$tmp"
fi

{
  printf '\n## %s\n\n' "$SECTION"
  cat "$BODY_FILE"
  printf '\n'
} >> "$tmp" || {
  echo "ERROR: 必須記録の書き込みに失敗しました: $FILE" >&2
  exit 1
}

mv "$tmp" "$FILE" || {
  echo "ERROR: 必須記録を保存できません: $FILE" >&2
  exit 1
}
trap - EXIT INT TERM HUP

# Read-back: never report the record as stored if the body is not there.
verify=$(extract_section "$FILE")
src_norm=$(sed -e 's/[[:space:]]*$//' -e '/^$/d' "$BODY_FILE")
got_norm=$(printf '%s\n' "$verify" | sed -e 's/[[:space:]]*$//' -e '/^$/d')
if [ -z "$src_norm" ] || [ "$got_norm" != "$src_norm" ]; then
  echo "ERROR: 必須記録の読み戻しが一致しません。検証済みとして扱いません: $FILE" >&2
  exit 1
fi
exit 0
