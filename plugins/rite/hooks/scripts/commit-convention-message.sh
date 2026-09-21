#!/bin/bash
# Resolve the commit message for automatic git helpers.
#
# Does not interpret CLAUDE.md / AGENTS.md text. A caller that already
# generated a message passes --message-file. If convention files exist at
# the locate root (cwd show-toplevel; Wiki worktree falls back to the
# shared root) and no file is passed, this fails loudly. Nested files
# also count as present. If none exist, the caller default is used.
#
# Usage (stdout = message bytes, no trailing status line):
#   bash commit-convention-message.sh --default-file D [--message-file M] [--root DIR]
#
# Exit:
#   0  message written to stdout
#   1  missing required input, unreadable file, or convention present without --message-file
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../control-char-neutralize.sh
source "$SCRIPT_DIR/../control-char-neutralize.sh"

DEFAULT_FILE=""
MESSAGE_FILE=""
ROOT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --default-file)
      [ $# -ge 2 ] || { echo "ERROR: --default-file requires a value" >&2; exit 1; }
      DEFAULT_FILE="$2"; shift 2 ;;
    --message-file)
      [ $# -ge 2 ] || { echo "ERROR: --message-file requires a value" >&2; exit 1; }
      MESSAGE_FILE="$2"; shift 2 ;;
    --root)
      [ $# -ge 2 ] || { echo "ERROR: --root requires a value" >&2; exit 1; }
      ROOT="$2"; shift 2 ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      echo "Usage: commit-convention-message.sh --default-file D [--message-file M] [--root DIR]" >&2
      exit 1
      ;;
  esac
done

read_msg_file() {
  local path="$1" label="$2"
  case "$path" in
    /*) ;;
    *)
      echo "ERROR: $label は絶対パスである必要があります: $path" >&2
      exit 1
      ;;
  esac
  if contains_ctrl "$path"; then
    echo "ERROR: $label のパスに制御文字が含まれます" >&2
    exit 1
  fi
  if [ ! -f "$path" ] || [ ! -r "$path" ]; then
    echo "ERROR: $label を読めません: $path" >&2
    exit 1
  fi
  cat "$path"
}

if [ -n "$MESSAGE_FILE" ]; then
  read_msg_file "$MESSAGE_FILE" "--message-file"
  exit 0
fi

locate_args=()
[ -n "$ROOT" ] && locate_args=(--root "$ROOT")
locate_out=$(bash "$SCRIPT_DIR/commit-convention-locate.sh" "${locate_args[@]}") || exit 1
present=$(printf '%s\n' "$locate_out" | sed -n 's/^COMMIT_CONVENTION_PRESENT=//p' | tail -1)
if [ "$present" = 1 ]; then
  echo "ERROR: 適用規約ファイルがあるため --message-file が必要です。自然言語規約を helper が解釈しません。" >&2
  printf '%s\n' "$locate_out" | sed 's/^/  /' >&2
  exit 1
fi

if [ -z "$DEFAULT_FILE" ]; then
  echo "ERROR: 規約ファイルがなく --message-file もないため --default-file が必要です" >&2
  exit 1
fi
read_msg_file "$DEFAULT_FILE" "--default-file"
exit 0
