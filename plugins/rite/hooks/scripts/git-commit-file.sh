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

# -a / pathspec は照合した index ではなく作業ツリーを記録する。
_wiki_skip=0
_wiki_dash=0
for _wiki_arg in "${EXTRA[@]}"; do
  if [ "$_wiki_dash" -eq 1 ]; then
    echo "ERROR: pathspec は index の照合を外すため受け取れません: $_wiki_arg" >&2
    exit 1
  fi
  if [ "$_wiki_skip" -eq 1 ]; then
    _wiki_skip=0
    continue
  fi
  case "$_wiki_arg" in
    --)
      _wiki_dash=1
      ;;
    -a|--all)
      echo "ERROR: -a / --all は index の照合を外すため受け取れません" >&2
      exit 1
      ;;
    -m|--message|-F|--file|--author|--date)
      _wiki_skip=1
      ;;
    --*)
      ;;
    -*a*)
      echo "ERROR: -a / --all は index の照合を外すため受け取れません" >&2
      exit 1
      ;;
    -*)
      ;;
    *)
      echo "ERROR: pathspec は index の照合を外すため受け取れません: $_wiki_arg" >&2
      exit 1
      ;;
  esac
done

gate="$SCRIPT_DIR/wiki-apply-gate.sh"
if [ ! -f "$gate" ]; then
  echo "ERROR: wiki apply gate が無いため commit できません" >&2
  exit 1
fi
gate_out=$(bash "$gate" --mode commit --worktree "$tree") || {
  printf '%s\n' "$gate_out" >&2
  echo "ERROR: wiki apply gate が commit を拒否しました" >&2
  exit 1
}
# skip と allow は出さない。Wiki 初期化は stdout と stderr をまとめて旧実装と
# 比較するため、通過時の表示が差分になる。拒否の理由だけを上で出している。

if ! git "${git_c[@]}" commit -F "$FILE" "${EXTRA[@]}"; then
  echo "ERROR: git commit -F failed" >&2
  exit 3
fi

# The allowing record named the pre-commit HEAD. Leaving it there makes the
# next gate treat this commit as a stale success.
if grep -q '^WIKI_APPLY_GATE=allow$' <<<"$gate_out"; then
  mem=""
  while IFS= read -r line; do
    case "$line" in
      memory=*) mem=${line#memory=}; break ;;
    esac
  done <<<"$gate_out"
  new_head=$(git -C "$tree" rev-parse HEAD)
  if [ -z "$mem" ] || [ ! -f "$mem" ]; then
    echo "ERROR: commit 後に Wiki 適用証跡の head を更新できません" >&2
    exit 1
  fi
  if ! WIKI_APPLY_MEM="$mem" WIKI_APPLY_HEAD="$new_head" python3 - <<'PY'
import os, re, sys
path = os.environ["WIKI_APPLY_MEM"]
head = os.environ["WIKI_APPLY_HEAD"]
text = open(path, encoding="utf-8").read()
marker = "### Wiki 適用証跡"
start = text.find(marker)
if start < 0:
    sys.exit(1)
rest_start = start + len(marker)
next_h = len(text)
for match in re.finditer(r"^#{2,3} ", text[rest_start:], re.M):
    next_h = rest_start + match.start()
    break
section = text[start:next_h]
new_section, count = re.subn(
    r"^head: [0-9a-f]{40}$", "head: " + head, section, count=1, flags=re.M
)
if count != 1:
    sys.exit(1)
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    fh.write(text[:start] + new_section + text[next_h:])
os.replace(tmp, path)
PY
  then
    echo "ERROR: commit 後に Wiki 適用証跡の head を更新できません" >&2
    exit 1
  fi
fi
exit 0
