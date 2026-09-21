#!/bin/bash
# Physical absolute path for helper comparisons.
# macOS mktemp / git may mix /var/folders and /private/var/folders.
# Callers source this file; no side effects at source time.
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/canon-path.sh"
#   canon_abs_path /var/folders/.../tmp.XXX
# stdout: /private/var/folders/.../tmp.XXX  (pwd -P of the directory)
# rc 1 if the directory (or the parent of a non-directory path) cannot be entered.

canon_abs_path() {
  local target="${1:-}"
  local dir base resolved dest hops
  if [ -z "$target" ]; then
    return 1
  fi
  case "$target" in
    /*) ;;
    *)
      target="$(pwd)/$target" || return 1
      ;;
  esac
  hops=0
  while [ "$hops" -lt 32 ]; do
    hops=$((hops + 1))
    if [ -d "$target" ]; then
      (cd "$target" && pwd -P) || return 1
      return 0
    fi
    dir=$(dirname -- "$target") || return 1
    base=$(basename -- "$target") || return 1
    resolved=$(cd "$dir" && pwd -P) || return 1
    target="$resolved/$base"
    if [ -L "$target" ]; then
      dest=$(readlink "$target") || return 1
      case "$dest" in
        /*) target=$dest ;;
        *) target="$resolved/$dest" ;;
      esac
      continue
    fi
    printf '%s/%s\n' "$resolved" "$base"
    return 0
  done
  return 1
}
