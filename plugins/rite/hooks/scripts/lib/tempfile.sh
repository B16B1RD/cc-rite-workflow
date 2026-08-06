# shellcheck shell=bash
# rite workflow - tempfile lifecycle
#
# Responsibility: own the whole life of a tempfile — creation, cleanup
# registration, signal handling, removal — so that callers never hand-write the
# `mktemp` + `trap` + `rm` sequence again.
#
# Why this exists: the same three defects kept coming back because the sequence
# is written from scratch in every new helper and each writing is an
# independent chance to get it wrong. mktemp failures were silenced into an
# empty path (`x=$(mktemp 2>/dev/null) || x=""`) with no diagnostic; cleanup was
# registered only for EXIT so Ctrl-C left the file behind; and the registration
# was written *after* the mktemp, leaving a window in which a signal orphans the
# file. Prose conventions did not stop the recurrence — the convention is not
# in front of the author at the moment they type `mktemp`. A function is.
#
# The canonical order the Wiki records (empty declaration → signal-specific
# handler → mktemp, with POSIX exit codes 130/143/129) is not something the
# caller can now get wrong: `rite_tempfile_init` installs the handlers, and
# `rite_tempfile_new` refuses to create anything until it has.
#
# Usage (source it — this cannot be a subprocess helper, because the cleanup
# handler has to live in the caller's own shell):
#
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/tempfile.sh"
#   rite_tempfile_init
#   rite_tempfile_new err_file "gh-err" || exit 1
#   gh api ... 2>"$err_file"
#
# The out-variable form is deliberate. `f=$(rite_tempfile_new)` would run the
# function in a subshell, so the path would come back but the registration
# would die with the subshell and the file would leak — the exact failure this
# lib exists to prevent. Taking the variable name as an argument makes that
# mistake unwritable.
#
# Composing with a caller that already owns its traps (a script whose EXIT
# handler also emits a terminal sentinel, say): pass --caller-traps to
# `rite_tempfile_init` and call `rite_tempfile_cleanup` from your own handler.
# Installing over an existing EXIT handler would silently drop it, so
# `rite_tempfile_init` refuses to do that rather than guess.
#
# bash 3.2 compatible: no `declare -n`, no `mapfile`. `printf -v` and plain
# arrays only.

# Registered paths, cleaned up in reverse order of creation (a tempdir created
# before a file inside it must be removed last).
_RITE_TMP_PATHS=()
# 0 until rite_tempfile_init runs. rite_tempfile_new checks it so that "create a
# tempfile without arranging for its removal" has no spelling.
_RITE_TMP_READY=0
# 1 only when this lib installed the handlers itself (--caller-traps leaves it 0).
_RITE_TMP_TRAPS_INSTALLED=0

# Remove every registered path and empty the registry. Safe to call more than
# once; safe to call from a caller-owned handler.
rite_tempfile_cleanup() {
  local i
  if [ "${#_RITE_TMP_PATHS[@]}" -gt 0 ]; then
    for (( i = ${#_RITE_TMP_PATHS[@]} - 1; i >= 0; i-- )); do
      [ -n "${_RITE_TMP_PATHS[$i]}" ] || continue
      rm -rf -- "${_RITE_TMP_PATHS[$i]}"
    done
  fi
  _RITE_TMP_PATHS=()
}

# Arm the registry and, unless --caller-traps is given, install the four
# handlers. Idempotent. Returns 1 (loudly) when an EXIT handler that is not ours
# already exists — clobbering it would drop whatever the caller does at exit.
rite_tempfile_init() {
  local caller_traps=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --caller-traps) caller_traps=1; shift ;;
      *)
        echo "ERROR: rite_tempfile_init: unknown argument '$1' (expected: --caller-traps)" >&2
        return 1
        ;;
    esac
  done

  if [ "$caller_traps" -eq 1 ]; then
    _RITE_TMP_READY=1
    return 0
  fi

  if [ "$_RITE_TMP_TRAPS_INSTALLED" -eq 1 ]; then
    _RITE_TMP_READY=1
    return 0
  fi

  local existing
  existing=$(trap -p EXIT)
  if [ -n "$existing" ]; then
    echo "ERROR: rite_tempfile_init: an EXIT handler is already installed; installing over it would silently drop it" >&2
    echo "  Fix: call 'rite_tempfile_init --caller-traps' and invoke rite_tempfile_cleanup from your own handler" >&2
    return 1
  fi

  # Signal handlers before any mktemp: a signal arriving between creation and
  # registration is exactly how tempfiles were being orphaned. Exit codes follow
  # POSIX 128+signum so callers and CI see the real cause of death.
  trap 'rc=$?; rite_tempfile_cleanup; exit $rc' EXIT
  trap 'rite_tempfile_cleanup; exit 130' INT
  trap 'rite_tempfile_cleanup; exit 143' TERM
  trap 'rite_tempfile_cleanup; exit 129' HUP

  _RITE_TMP_TRAPS_INSTALLED=1
  _RITE_TMP_READY=1
  return 0
}

# Shared by rite_tempfile_new / rite_tempdir_new.
# $1 out-variable name, $2 tag, $3 "file" | "dir".
_rite_tempfile_create() {
  local outvar="$1" tag="${2:-tmp}" kind="$3"
  local path

  if [ "$_RITE_TMP_READY" -ne 1 ]; then
    echo "ERROR: rite_tempfile: call rite_tempfile_init before creating a tempfile (cleanup would not be arranged)" >&2
    return 1
  fi

  # printf -v with an attacker-chosen name is an arbitrary-assignment primitive,
  # and a name with a '[' would make it an array write. Callers pass literals,
  # so anything outside the identifier alphabet is a bug worth stopping on.
  case "$outvar" in
    ''|*[!A-Za-z0-9_]*|[0-9]*)
      echo "ERROR: rite_tempfile: '$outvar' is not a valid variable name" >&2
      return 1
      ;;
  esac
  # The tag lands in a filesystem path; keep it to characters that cannot turn
  # the template into a different directory or a glob.
  case "$tag" in
    ''|*[!A-Za-z0-9._-]*)
      echo "ERROR: rite_tempfile: tag '$tag' contains characters outside [A-Za-z0-9._-]" >&2
      return 1
      ;;
  esac

  # Trailing X's only: BSD/macOS mktemp replaces the trailing run, so X's placed
  # mid-template yield a fixed name and collide (#2080).
  local template="${TMPDIR:-/tmp}/rite-${tag}-XXXXXX"
  # mktemp's own stderr is deliberately NOT redirected. Swallowing it is how the
  # failure became invisible in the first place.
  if [ "$kind" = "dir" ]; then
    path=$(mktemp -d "$template") || {
      echo "ERROR: rite_tempfile: mktemp -d failed for '$template' (disk full / inode exhaustion / read-only /tmp / permission denied)" >&2
      return 1
    }
  else
    path=$(mktemp "$template") || {
      echo "ERROR: rite_tempfile: mktemp failed for '$template' (disk full / inode exhaustion / read-only /tmp / permission denied)" >&2
      return 1
    }
  fi

  # Register before returning, so there is no window in which the path exists
  # but nothing would remove it.
  _RITE_TMP_PATHS+=("$path")
  # Owner-only, to keep the path out of reach on a shared /tmp. A directory
  # needs the execute bit or nothing can be created inside it — 600 on a
  # tempdir makes it unusable.
  # Best-effort: a filesystem without POSIX permissions must not fail creation.
  if [ "$kind" = "dir" ]; then
    chmod 700 "$path" 2>/dev/null || true
  else
    chmod 600 "$path" 2>/dev/null || true
  fi
  printf -v "$outvar" '%s' "$path"
  return 0
}

# rite_tempfile_new <outvar> [tag] — create a tempfile, register it, assign its
# path to <outvar> in the caller's scope. Returns 1 with an ERROR line on
# failure; there is no silent empty-path outcome.
rite_tempfile_new() {
  _rite_tempfile_create "${1:-}" "${2:-tmp}" file
}

# rite_tempdir_new <outvar> [tag] — same contract, for a directory.
rite_tempdir_new() {
  _rite_tempfile_create "${1:-}" "${2:-tmp}" dir
}

# Remove one path early and drop it from the registry, so the exit handler does
# not try to remove it again and a reused variable never points at a stale path.
rite_tempfile_release() {
  local target="${1:-}" i
  local -a kept=()
  [ -n "$target" ] || return 0
  rm -rf -- "$target"
  if [ "${#_RITE_TMP_PATHS[@]}" -gt 0 ]; then
    for (( i = 0; i < ${#_RITE_TMP_PATHS[@]}; i++ )); do
      [ "${_RITE_TMP_PATHS[$i]}" = "$target" ] && continue
      kept+=("${_RITE_TMP_PATHS[$i]}")
    done
  fi
  _RITE_TMP_PATHS=()
  if [ "${#kept[@]}" -gt 0 ]; then
    _RITE_TMP_PATHS=("${kept[@]}")
  fi
  return 0
}

# Running this file instead of sourcing it would install the handlers in a shell
# that exits immediately — the caller would get nothing. Say so rather than
# succeed silently.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  echo "ERROR: tempfile.sh must be sourced, not executed (the cleanup handler has to live in the caller's shell)" >&2
  echo "  Usage: source \"\$(dirname \"\${BASH_SOURCE[0]}\")/lib/tempfile.sh\"" >&2
  exit 2
fi
