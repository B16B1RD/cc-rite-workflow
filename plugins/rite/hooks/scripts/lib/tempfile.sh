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
# registered only for EXIT, which does fire on INT/TERM/HUP but cannot set the
# exit code, so an interrupted run reported success; and the registration was
# written *after* the mktemp, leaving a window in which a signal orphans the
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
# The four handlers below implement the canonical template in
# references/bash-trap-patterns.md; that file is the definition, this is the one
# place callers should reach it through for tempfiles.
#
# bash 3.2 compatible: no `declare -n`, no `mapfile`. `printf -v` and plain
# arrays only.

# Sourcing twice must not reset the registry. This is the first lib in the repo
# that carries state, so the no-op re-source that the stateless libs rely on
# does not hold here: a second `source` would clear the array while the handlers
# stayed installed, orphaning every already-created tempfile with no diagnostic —
# the exact leak this lib exists to remove. Two libs already source a sibling,
# so an indirect double-source is reachable, not hypothetical.
if [ -n "${_RITE_TMP_LIB_LOADED:-}" ]; then
  return 0
fi
_RITE_TMP_LIB_LOADED=1

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

  # All four, not just EXIT. Overwriting a caller's INT handler without saying so
  # is the same silent clobber the EXIT check refuses — checking one and not the
  # other three leaves the asymmetry that lets a caller lose its handler quietly.
  #
  # A signal the process inherited as ignored is not a caller handler, though.
  # `trap -p` reports it as `trap -- '' SIGINT`, which is non-empty, and bash
  # gives async children an ignored SIGINT and nohup an ignored SIGHUP — so a
  # plain length test refuses to initialise in those contexts and blames a
  # handler the caller never wrote. Such a signal also cannot kill the process,
  # so there is nothing to clean up: skip it and install the rest.
  #
  # EXIT is excluded from that exemption. It is not a signal, so it is never
  # inherited as ignored — `trap -- '' EXIT` only ever appears because the caller
  # wrote it, and unlike an ignored signal it still fires. Exempting it would
  # return success with no cleanup arranged at all, which is the silent leak this
  # lib exists to remove. Keeping EXIT strict also means install_sigs is never
  # empty: EXIT is either installed or the function has already returned 1.
  local sig existing
  local -a install_sigs=()
  for sig in EXIT INT TERM HUP; do
    existing=$(trap -p "$sig")
    case "$sig:$existing" in
      *:"") install_sigs+=("$sig") ;;
      INT:"trap -- '' "*|TERM:"trap -- '' "*|HUP:"trap -- '' "*) : ;;
      *)
        echo "ERROR: rite_tempfile_init: a $sig handler is already installed; installing over it would silently drop it" >&2
        echo "  Fix: call 'rite_tempfile_init --caller-traps' and invoke rite_tempfile_cleanup from your own handler" >&2
        return 1
        ;;
    esac
  done

  # Signal handlers before any mktemp: a signal arriving between creation and
  # registration is exactly how tempfiles were being orphaned. Exit codes follow
  # POSIX 128+signum so callers and CI see the real cause of death.
  for sig in "${install_sigs[@]}"; do
    case "$sig" in
      EXIT) trap 'rc=$?; rite_tempfile_cleanup; exit $rc' EXIT ;;
      INT)  trap 'rite_tempfile_cleanup; exit 130' INT ;;
      TERM) trap 'rite_tempfile_cleanup; exit 143' TERM ;;
      HUP)  trap 'rite_tempfile_cleanup; exit 129' HUP ;;
    esac
  done

  _RITE_TMP_TRAPS_INSTALLED=1
  _RITE_TMP_READY=1
  return 0
}

# Shared by rite_tempfile_new / rite_tempdir_new.
# $1 out-variable name, $2 tag, $3 "file" | "dir".
_rite_tempfile_create() {
  # Locals carry the _rite_ prefix so a caller passing its own variable name can
  # never collide with one of them. Without that, `rite_tempfile_new path x`
  # writes this function's local and returns success with the caller's variable
  # untouched — the silent empty-path outcome this lib exists to remove.
  local _rite_ov="$1" _rite_tag="${2:-tmp}" _rite_kind="$3"
  local _rite_path

  if [ "$_RITE_TMP_READY" -ne 1 ]; then
    echo "ERROR: rite_tempfile: call rite_tempfile_init before creating a tempfile (cleanup would not be arranged)" >&2
    return 1
  fi

  # printf -v with an attacker-chosen name is an arbitrary-assignment primitive,
  # and a name with a '[' would make it an array write. Callers pass literals,
  # so anything outside the identifier alphabet is a bug worth stopping on.
  case "$_rite_ov" in
    ''|*[!A-Za-z0-9_]*|[0-9]*)
      echo "ERROR: rite_tempfile: '$_rite_ov' is not a valid variable name" >&2
      return 1
      ;;
  esac
  # The lib's own namespace is reserved. `printf -v _RITE_TMP_PATHS` writes
  # element 0 of the live registry and `printf -v _RITE_TMP_READY` turns the init
  # guard into a path string, both while returning success. Rejecting the prefix
  # keeps that unwritable as the lib grows more internals.
  case "$_rite_ov" in
    _rite_*|_RITE_*)
      echo "ERROR: rite_tempfile: '$_rite_ov' is reserved for the lib's own namespace" >&2
      return 1
      ;;
  esac
  # The tag lands in a filesystem path; keep it to characters that cannot turn
  # the template into a different directory or a glob.
  case "$_rite_tag" in
    ''|*[!A-Za-z0-9._-]*)
      echo "ERROR: rite_tempfile: tag '$_rite_tag' contains characters outside [A-Za-z0-9._-]" >&2
      return 1
      ;;
  esac

  # Trailing X's only: BSD/macOS mktemp replaces the trailing run, so X's placed
  # mid-template yield a fixed name and collide.
  local _rite_template="${TMPDIR:-/tmp}/rite-${_rite_tag}-XXXXXX"
  # mktemp's own stderr is deliberately NOT redirected. Swallowing it is how the
  # failure became invisible in the first place.
  if [ "$_rite_kind" = "dir" ]; then
    _rite_path=$(mktemp -d "$_rite_template") || {
      echo "ERROR: rite_tempfile: mktemp -d failed for '$_rite_template' (disk full / inode exhaustion / read-only /tmp / permission denied)" >&2
      return 1
    }
  else
    _rite_path=$(mktemp "$_rite_template") || {
      echo "ERROR: rite_tempfile: mktemp failed for '$_rite_template' (disk full / inode exhaustion / read-only /tmp / permission denied)" >&2
      return 1
    }
  fi

  # Register in the statement right after creation. A signal arriving between the
  # two is still possible — bash cannot make them atomic — but the window is one
  # statement wide, and the handlers were installed before any mktemp ran, which
  # is the part that actually eliminates the orphans.
  _RITE_TMP_PATHS+=("$_rite_path")
  # Defence in depth over mktemp's own 0600 / 0700: a filesystem without POSIX
  # permissions must not fail creation, so the failure is ignored.
  if [ "$_rite_kind" = "dir" ]; then
    chmod 700 "$_rite_path" 2>/dev/null || true
  else
    chmod 600 "$_rite_path" 2>/dev/null || true
  fi
  # A failed assignment (readonly target, say) must not return success with the
  # caller's variable unset — that is the empty-path outcome again.
  printf -v "$_rite_ov" '%s' "$_rite_path" || {
    echo "ERROR: rite_tempfile: could not assign the path to '$_rite_ov'" >&2
    return 1
  }
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

# Early release is deliberately absent. Nothing in the repo needs it, and the
# version that existed took an unvalidated path straight to `rm -rf` — an
# arbitrary-delete primitive wearing a registry-scoped name, in a lib whose
# stated premise is that the API shape makes the mistake unwritable. Add it back
# when a caller actually needs it, with the membership check that implies.

# Running this file instead of sourcing it would install the handlers in a shell
# that exits immediately — the caller would get nothing. Say so rather than
# succeed silently.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  echo "ERROR: tempfile.sh must be sourced, not executed (the cleanup handler has to live in the caller's shell)" >&2
  echo "  Usage: source \"\$(dirname \"\${BASH_SOURCE[0]}\")/lib/tempfile.sh\"" >&2
  exit 2
fi
