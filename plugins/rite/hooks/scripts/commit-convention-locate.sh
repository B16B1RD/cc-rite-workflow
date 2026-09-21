#!/bin/bash
# Locate project-root CLAUDE.md and AGENTS.md for rite commit generation.
#
# Reads the shared state root (state-path-resolve.sh) so a wiki worktree /
# orphan wiki tree without those files still sees the original project.
# Nested CLAUDE.md / AGENTS.md are ignored. Does not interpret file text.
#
# Usage:
#   bash commit-convention-locate.sh [--root DIR]
#
# stdout (one key=value per line):
#   COMMIT_CONVENTION_ROOT=<abs>
#   CLAUDE_MD=missing|<abs>
#   AGENTS_MD=missing|<abs>
#   COMMIT_CONVENTION_PRESENT=0|1
#
# Exit:
#   0  root resolved; each named file is missing or a readable regular file
#   1  root unreadable, or a present path is not a readable regular file
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../control-char-neutralize.sh
source "$SCRIPT_DIR/../control-char-neutralize.sh"

ROOT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --root)
      [ $# -ge 2 ] || { echo "ERROR: --root requires a value" >&2; exit 1; }
      ROOT="$2"
      shift 2
      ;;
    --help|-h)
      sed -n '/^# /p;/^set /q' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      echo "Usage: commit-convention-locate.sh [--root DIR]" >&2
      exit 1
      ;;
  esac
done

if [ -z "$ROOT" ]; then
  ROOT=$("$SCRIPT_DIR/../state-path-resolve.sh" 2>/dev/null) || ROOT=""
  [ -n "$ROOT" ] || ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || ROOT=""
fi

case "$ROOT" in
  /*) ;;
  "")
    echo "ERROR: commit-convention-locate: 共有ルートを解決できません" >&2
    exit 1
    ;;
  *)
    ROOT=$(cd "$ROOT" && pwd) || {
      echo "ERROR: commit-convention-locate: --root を解決できません: $ROOT" >&2
      exit 1
    }
    ;;
esac

if contains_ctrl "$ROOT"; then
  echo "ERROR: commit-convention-locate: root に制御文字が含まれます" >&2
  exit 1
fi

if [ ! -d "$ROOT" ] || [ ! -r "$ROOT" ]; then
  echo "ERROR: commit-convention-locate: ルートを読めません: $ROOT" >&2
  exit 1
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
  printf '%s' "$path"
}

claude_md=$(classify CLAUDE.md) || exit 1
agents_md=$(classify AGENTS.md) || exit 1

present=0
[ "$claude_md" != missing ] && present=1
[ "$agents_md" != missing ] && present=1

printf 'COMMIT_CONVENTION_ROOT=%s\n' "$ROOT"
printf 'CLAUDE_MD=%s\n' "$claude_md"
printf 'AGENTS_MD=%s\n' "$agents_md"
printf 'COMMIT_CONVENTION_PRESENT=%s\n' "$present"
exit 0
