#!/bin/bash
# One-shot move of root `.rite-*` runtime state under `.rite/`.
# Sourced by session-start.sh and /rite:setup --upgrade. Dest already present
# means a previous run owns it — leave src so dual-read still sees it; never
# clobber dest.
#
_rite_migrate_source="${BASH_SOURCE[0]}"
case "$_rite_migrate_source" in
  */*) _rite_migrate_dir="${_rite_migrate_source%/*}" ;;
  *) _rite_migrate_dir="." ;;
esac
if ! declare -F neutralize_ctrl >/dev/null 2>&1; then
  # shellcheck source=control-char-neutralize.sh
  source "$_rite_migrate_dir/control-char-neutralize.sh"
fi

_rite_migrate_relocated() {
  local src="$1" dest="$2" dest_dir
  [ -e "$src" ] || return 0
  [ -e "$dest" ] && return 0
  dest_dir=$(dirname "$dest")
  if ! mkdir -p "$dest_dir"; then
    echo "WARNING: relocated-state-migrate: cannot create $(printf '%s' "$dest_dir" | neutralize_ctrl) to migrate $(printf '%s' "$src" | neutralize_ctrl)" >&2
    return 0
  fi
  if ! mv "$src" "$dest"; then
    echo "WARNING: relocated-state-migrate: failed to migrate $(printf '%s' "$src" | neutralize_ctrl) -> $(printf '%s' "$dest" | neutralize_ctrl)" >&2
    return 0
  fi
}

_rite_run_relocated_state_migrate() {
  local state_root="$1"
  [ -n "$state_root" ] || return 0
  _rite_migrate_relocated "$state_root/.rite-plugin-root" "$state_root/.rite/plugin-root"
  _rite_migrate_relocated "$state_root/.rite-session-id" "$state_root/.rite/session-id"
  _rite_migrate_relocated "$state_root/.rite-initialized-version" "$state_root/.rite/initialized-version"
  _rite_migrate_relocated "$state_root/.rite-settings-hooks-cleaned" "$state_root/.rite/settings-hooks-cleaned"
  _rite_migrate_relocated "$state_root/.rite-flow-debug.log" "$state_root/.rite/logs/flow-debug.log"
  _rite_migrate_relocated "$state_root/.rite-work-memory" "$state_root/.rite/work-memory"
}
