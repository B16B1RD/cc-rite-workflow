#!/bin/bash
# Shared primitive for self-contained runtime directories that must carry `*`.
# Contract: non-empty files are left untouched; missing/empty files are rewritten.
# On failure, return 1 and expose a control-character-neutralized, C-locale cause in
# `_RITE_GITIGNORE_ERROR`. Callers own their WARNING/marker policy.

_rite_gitignore_source="${BASH_SOURCE[0]}"
case "$_rite_gitignore_source" in
  */*) _rite_gitignore_dir="${_rite_gitignore_source%/*}" ;;
  *) _rite_gitignore_dir="." ;;
esac
if ! declare -F neutralize_ctrl >/dev/null 2>&1; then
  # shellcheck source=control-char-neutralize.sh
source "$_rite_gitignore_dir/control-char-neutralize.sh"
fi

_RITE_GITIGNORE_ERROR=""
_ensure_dir_gitignore() {
  local dir="$1" raw_error=""
  _RITE_GITIGNORE_ERROR=""
  [ -n "$dir" ] || { _RITE_GITIGNORE_ERROR="empty directory path"; return 1; }
  [ -s "$dir/.gitignore" ] && return 0
  if ! raw_error=$( { LC_ALL=C printf '*\n' > "$dir/.gitignore"; } 2>&1 ); then
    _RITE_GITIGNORE_ERROR=$(printf '%s' "$raw_error" | neutralize_ctrl --keep-newline)
    return 1
  fi
}
