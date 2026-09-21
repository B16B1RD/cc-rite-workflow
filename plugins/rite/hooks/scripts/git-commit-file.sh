#!/bin/bash
# Run `git commit -F` with a message file that must sit outside the work tree.
#
# The file contents are passed to git as data. They are not expanded as a
# shell command. Callers that need a multiline or quote-heavy message write
# the file first (typically under TMPDIR) and then invoke this helper.
#
# Usage:
#   bash git-commit-file.sh --file ABS_MSG [--worktree DIR] [--] [git commit args...]
#
# Exit:
#   0  git commit succeeded
#   1  argument / path policy error
#   3  git commit failed (git's stderr is forwarded)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../control-char-neutralize.sh
source "$SCRIPT_DIR/../control-char-neutralize.sh"
# shellcheck source=lib/canon-path.sh
source "$SCRIPT_DIR/lib/canon-path.sh"

FILE=""
WORKTREE=""
EXTRA=()
while [ $# -gt 0 ]; do
  case "$1" in
    --file)
      [ $# -ge 2 ] || { echo "ERROR: --file requires a value" >&2; exit 1; }
      FILE="$2"; shift 2 ;;
    --worktree)
      [ $# -ge 2 ] || { echo "ERROR: --worktree requires a value" >&2; exit 1; }
      WORKTREE="$2"; shift 2 ;;
    --)
      shift
      EXTRA+=("$@")
      break
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      echo "Usage: git-commit-file.sh --file ABS_MSG [--worktree DIR] [--] [git commit args...]" >&2
      exit 1
      ;;
  esac
done

if [ -z "$FILE" ]; then
  echo "ERROR: --file is required" >&2
  exit 1
fi
case "$FILE" in
  /*) ;;
  *)
    echo "ERROR: --file は絶対パスである必要があります: $FILE" >&2
    exit 1
    ;;
esac
if contains_ctrl "$FILE"; then
  echo "ERROR: --file のパスに制御文字が含まれます" >&2
  exit 1
fi
if [ ! -f "$FILE" ] || [ ! -r "$FILE" ]; then
  echo "ERROR: メッセージファイルを読めません: $FILE" >&2
  exit 1
fi

git_c=()
tree=""
if [ -n "$WORKTREE" ]; then
  case "$WORKTREE" in
    /*) ;;
    *)
      echo "ERROR: --worktree は絶対パスである必要があります: $WORKTREE" >&2
      exit 1
      ;;
  esac
  git_c=(-C "$WORKTREE")
  tree=$(git "${git_c[@]}" rev-parse --show-toplevel) || {
    echo "ERROR: --worktree が git 作業ツリーではありません: $WORKTREE" >&2
    exit 1
  }
else
  tree=$(git rev-parse --show-toplevel) || {
    echo "ERROR: git 作業ツリーの外では --worktree が必要です" >&2
    exit 1
  }
fi

tree=$(canon_abs_path "$tree") || {
  echo "ERROR: 作業ツリーの物理パスを解決できません: $tree" >&2
  exit 1
}
file_abs=$(canon_abs_path "$FILE") || {
  echo "ERROR: メッセージファイルの物理パスを解決できません: $FILE" >&2
  exit 1
}
case "$file_abs" in
  "$tree"|"$tree"/*)
    echo "ERROR: メッセージファイルは作業ツリーの外に置く必要があります: $file_abs (tree=$tree)" >&2
    exit 1
    ;;
esac

if ! git "${git_c[@]}" commit -F "$FILE" "${EXTRA[@]}"; then
  echo "ERROR: git commit -F failed" >&2
  exit 3
fi
exit 0
