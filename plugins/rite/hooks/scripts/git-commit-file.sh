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
#   4  git commit succeeded, but Wiki evidence head update failed
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

gate="$SCRIPT_DIR/wiki-apply-gate.sh"
if [ ! -f "$gate" ]; then
  echo "ERROR: wiki apply gate が無いため commit できません" >&2
  exit 1
fi
# The record's head is moved after the commit, so a missing helper must stop
# the commit before HEAD moves, as a missing gate does.
advance="$SCRIPT_DIR/wiki-apply-advance-head.sh"
if [ ! -f "$advance" ]; then
  echo "ERROR: wiki apply の head 更新 helper が無いため commit できません" >&2
  exit 1
fi

# 引数の分類は commit-target と同じ関数。gate が検査する commit だけ、index 以外を先に止める。
_wiki_in_scope=0
_wiki_flow="${WIKI_APPLY_FLOW_STATE:-}"
if [ -z "$_wiki_flow" ]; then
  _wiki_flow=$(bash "$SCRIPT_DIR/../flow-state.sh" path 2>/dev/null) || _wiki_flow=""
fi
if [ -n "$_wiki_flow" ] && [ -f "$_wiki_flow" ] \
  && _wiki_row=$(jq -r '[.phase // "", .worktree // ""] | join("\u001f")' "$_wiki_flow" 2>/dev/null); then
  IFS=$'\x1f' read -r _wiki_phase _wiki_fswt <<<"$_wiki_row"
  case "$_wiki_phase" in
    implement|fix)
      # worktree を記録しないセッションの作業ツリーは flow-state を持つ checkout（gate と同じ導出）
      if [ -z "$_wiki_fswt" ]; then
        case "$_wiki_flow" in
          */.rite/sessions/*.flow-state) _wiki_fswt="${_wiki_flow%/.rite/sessions/*}" ;;
        esac
      fi
      if [ -n "$_wiki_fswt" ]; then
        _wiki_fswt=$(canon_abs_path "$_wiki_fswt") || _wiki_fswt=""
      fi
      if [ -n "$_wiki_fswt" ] && [ "$_wiki_fswt" = "$tree" ]; then
        _wiki_in_scope=1
      fi
      ;;
  esac
fi
_wiki_kind=$(python3 "$SCRIPT_DIR/lib/review-fix-scope.py" classify-extras -- "${EXTRA[@]}") || {
  echo "ERROR: commit 引数を判定できません" >&2
  exit 1
}
if [ "$_wiki_in_scope" -eq 1 ] && [ "$_wiki_kind" = other ]; then
  echo "ERROR: index の照合を外す引数は受け取れません" >&2
  exit 1
fi

gate_out=$(bash "$gate" --mode commit --worktree "$tree") || {
  printf '%s\n' "$gate_out" >&2
  echo "ERROR: wiki apply gate が commit を拒否しました" >&2
  exit 1
}
# skip と allow は出さない。Wiki 初期化は stdout と stderr をまとめて旧実装と
# 比較するため、通過時の表示が差分になる。拒否の理由だけを上で出している。

# The allowing record names this HEAD; head moves from it after the commit.
old_head=""
if grep -q '^WIKI_APPLY_GATE=allow$' <<<"$gate_out"; then
  old_head=$(git -C "$tree" rev-parse HEAD)
fi

if ! git "${git_c[@]}" commit -F "$FILE" "${EXTRA[@]}"; then
  echo "ERROR: git commit -F failed" >&2
  exit 3
fi

# The allowing record named the pre-commit HEAD. Leaving it there makes the
# next gate treat this commit as a stale success.
if [ -n "$old_head" ]; then
  mem=""
  while IFS= read -r line; do
    case "$line" in
      memory=*) mem=${line#memory=}; break ;;
    esac
  done <<<"$gate_out"
  if [ -z "$mem" ] || [ ! -f "$mem" ]; then
    echo "ERROR: commit 後に Wiki 適用証跡の head を更新できません" >&2
    exit 4
  fi
  # The helper's stdout stays out of this output, as the gate's allow line does.
  if ! bash "$advance" --worktree "$tree" --memory "$mem" --from "$old_head" >/dev/null; then
    echo "ERROR: commit 後に Wiki 適用証跡の head を更新できません" >&2
    exit 4
  fi
fi
exit 0
