#!/bin/bash
# Locate CLAUDE.md and AGENTS.md for rite commit generation.
#
# Default root is the current git worktree (`git rev-parse --show-toplevel`).
# Shared-root fallback is only when that worktree is the existing Wiki
# worktree (state-root `.rite/wiki-worktree`) and has no convention files.
# Nested files are collected by walking parent directories of --path (or of
# cwd when it is under the root). There is no full-tree find.
# The helper does not interpret file text.
#
# Usage:
#   bash commit-convention-locate.sh [--root DIR] [--path REL]...
#
# stdout (one key=value per line):
#   COMMIT_CONVENTION_ROOT=<abs>
#   CLAUDE_MD=missing|<abs>
#   AGENTS_MD=missing|<abs>
#   NESTED_CLAUDE_MD=<colon-separated abs paths or empty>
#   NESTED_AGENTS_MD=<colon-separated abs paths or empty>
#   COMMIT_CONVENTION_PRESENT=0|1
#
# Exit:
#   0  root resolved; each named file is missing or a readable regular file
#   1  root unreadable, or a present path is not a readable regular file
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../control-char-neutralize.sh
source "$SCRIPT_DIR/../control-char-neutralize.sh"
# shellcheck source=lib/canon-path.sh
source "$SCRIPT_DIR/lib/canon-path.sh"

ROOT=""
PATHS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --root)
      [ $# -ge 2 ] || { echo "ERROR: --root requires a value" >&2; exit 1; }
      ROOT="$2"
      shift 2
      ;;
    --path)
      [ $# -ge 2 ] || { echo "ERROR: --path requires a value" >&2; exit 1; }
      PATHS+=("$2")
      shift 2
      ;;
    --help|-h)
      sed -n '/^# /p;/^set /q' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      echo "Usage: commit-convention-locate.sh [--root DIR] [--path REL]..." >&2
      exit 1
      ;;
  esac
done

if contains_ctrl "$ROOT"; then
  echo "ERROR: commit-convention-locate: root に制御文字が含まれます" >&2
  exit 1
fi

worktree=""
worktree=$(git rev-parse --show-toplevel 2>/dev/null) || worktree=""
if [ -n "$worktree" ]; then
  worktree=$(canon_abs_path "$worktree") || worktree=""
fi

if [ -n "$ROOT" ]; then
  case "$ROOT" in
    /*) ;;
    *)
      ROOT=$(cd "$ROOT" && pwd) || {
        echo "ERROR: commit-convention-locate: --root を解決できません: $ROOT" >&2
        exit 1
      }
      ;;
  esac
  ROOT=$(canon_abs_path "$ROOT") || {
    echo "ERROR: commit-convention-locate: --root を解決できません: $ROOT" >&2
    exit 1
  }
else
  if [ -z "$worktree" ]; then
    echo "ERROR: commit-convention-locate: 作業ツリーを解決できません" >&2
    exit 1
  fi
  ROOT="$worktree"
fi

if [ ! -d "$ROOT" ] || [ ! -r "$ROOT" ]; then
  echo "ERROR: commit-convention-locate: ルートを読めません: $ROOT" >&2
  exit 1
fi

root_has_convention() {
  local tree="$1"
  [ -f "$tree/CLAUDE.md" ] || [ -f "$tree/AGENTS.md" ]
}

# Wiki worktree path is owned by wiki-worktree-setup.sh (always
# `{state_root}/.rite/wiki-worktree`). Caller --root of that tree, or cwd
# there, falls back to the shared project root when the wiki tree has no
# convention files.
shared=$("$SCRIPT_DIR/../state-path-resolve.sh" 2>/dev/null) || shared=""
if [ -n "$shared" ]; then
  shared=$(canon_abs_path "$shared") || shared=""
fi
if [ -n "$shared" ] && [ -d "$shared/.rite/wiki-worktree" ]; then
  wiki_wt=$(canon_abs_path "$shared/.rite/wiki-worktree") || wiki_wt=""
  if [ -n "$wiki_wt" ] && [ "$ROOT" = "$wiki_wt" ] && ! root_has_convention "$ROOT"; then
    ROOT="$shared"
  fi
fi

classify() {
  local name="$1"
  local path="$ROOT/$name"
  if [ ! -e "$path" ]; then
    printf 'missing'
    return 0
  fi
  if [ -d "$path" ]; then
    echo "ERROR: commit-convention-locate: $name が通常ファイルではありません: $path" >&2
    return 1
  fi
  if [ ! -f "$path" ]; then
    echo "ERROR: commit-convention-locate: $name が通常ファイルではありません: $path" >&2
    return 1
  fi
  if [ ! -r "$path" ]; then
    echo "ERROR: commit-convention-locate: $name を読めません: $path" >&2
    return 1
  fi
  canon_abs_path "$path"
}

append_unique() {
  local current="$1"
  local add="$2"
  case ":$current:" in
    *":$add:"*) printf '%s' "$current" ;;
    *)
      if [ -z "$current" ]; then
        printf '%s' "$add"
      else
        printf '%s:%s' "$current" "$add"
      fi
      ;;
  esac
}

consider_nested_file() {
  local path="$1"
  [ -e "$path" ] || return 0
  if [ -d "$path" ] || [ ! -f "$path" ]; then
    echo "ERROR: commit-convention-locate: ネストした規約ファイルが通常ファイルではありません: $path" >&2
    return 1
  fi
  if [ ! -r "$path" ]; then
    echo "ERROR: commit-convention-locate: ネストした規約ファイルを読めません: $path" >&2
    return 1
  fi
  phys=$(canon_abs_path "$path") || return 1
  case "$path" in
    */CLAUDE.md) nested_claude=$(append_unique "$nested_claude" "$phys") ;;
    */AGENTS.md) nested_agents=$(append_unique "$nested_agents" "$phys") ;;
  esac
}

walk_parents() {
  local rel_dir="$1"
  local next cand phys parent
  while [ -n "$rel_dir" ] && [ "$rel_dir" != "." ] && [ "$rel_dir" != "/" ]; do
    cand="$ROOT/$rel_dir"
    if [ -d "$cand" ]; then
      phys=$(canon_abs_path "$cand") || {
        echo "ERROR: commit-convention-locate: --path の親を解決できません: $rel_dir" >&2
        return 1
      }
    elif [ -e "$(dirname -- "$cand")" ]; then
      parent=$(canon_abs_path "$(dirname -- "$cand")") || {
        echo "ERROR: commit-convention-locate: --path の親を解決できません: $rel_dir" >&2
        return 1
      }
      phys="$parent/$(basename -- "$rel_dir")"
    else
      phys=$cand
    fi
    case "$phys" in
      "$ROOT"|"$ROOT"/*) ;;
      *)
        echo "ERROR: commit-convention-locate: --path が作業ツリーの外です: $rel_dir" >&2
        return 1
        ;;
    esac
    consider_nested_file "$ROOT/$rel_dir/CLAUDE.md" || return 1
    consider_nested_file "$ROOT/$rel_dir/AGENTS.md" || return 1
    next=$(dirname -- "$rel_dir")
    [ "$next" = "$rel_dir" ] && break
    rel_dir=$next
  done
}

claude_md=$(classify CLAUDE.md) || exit 1
agents_md=$(classify AGENTS.md) || exit 1

nested_claude=""
nested_agents=""

if [ "${#PATHS[@]}" -gt 0 ]; then
  for p in "${PATHS[@]}"; do
    case "$p" in
      /*)
        echo "ERROR: commit-convention-locate: --path は作業ツリー相対です: $p" >&2
        exit 1
        ;;
    esac
    if contains_ctrl "$p"; then
      echo "ERROR: commit-convention-locate: --path に制御文字が含まれます" >&2
      exit 1
    fi
    walk_parents "$(dirname -- "$p")" || exit 1
  done
else
  cwd_phys=$(canon_abs_path "$(pwd)") || cwd_phys=""
  case "$cwd_phys" in
    "$ROOT") ;;
    "$ROOT"/*)
      walk_parents "${cwd_phys#"$ROOT"/}" || exit 1
      ;;
  esac
fi

present=0
[ "$claude_md" != missing ] && present=1
[ "$agents_md" != missing ] && present=1
[ -n "$nested_claude" ] && present=1
[ -n "$nested_agents" ] && present=1

printf 'COMMIT_CONVENTION_ROOT=%s\n' "$ROOT"
printf 'CLAUDE_MD=%s\n' "$claude_md"
printf 'AGENTS_MD=%s\n' "$agents_md"
printf 'NESTED_CLAUDE_MD=%s\n' "$nested_claude"
printf 'NESTED_AGENTS_MD=%s\n' "$nested_agents"
printf 'COMMIT_CONVENTION_PRESENT=%s\n' "$present"
exit 0
