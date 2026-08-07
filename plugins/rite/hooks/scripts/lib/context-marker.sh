# shellcheck shell=bash
# rite workflow - [CONTEXT] marker emit / lookup (shared)
#
# Responsibility: own the whole `[CONTEXT] KEY=value; field=value; ...` wire
# format — how a marker is written and how one is found again in captured
# output — so that neither side is hand-written per call site again.
#
# Why this exists: the marker format is a contract between a bash block and
# whoever reads its output, but until now only the *format* was shared; the
# rules that make a lookup correct lived in SKILL.md prose. Prose cannot be
# executed, so every rule was re-derived (or missed) at each new call site, and
# every re-derivation was an independent chance to get it wrong. The four rules
# below are the ones that were actually being re-argued in review:
#
#   1. Line anchor. `sed -n 's/.*KEY=\(...\).*/\1/p'` matches `KEY=` anywhere on
#      a line, so a WARNING quoting a marker, or a diagnostic that embeds one,
#      is read as the marker itself. A marker is only a marker when the line
#      *starts* with `[CONTEXT] `.
#   2. Multi-line tolerance. Helper stdout and stderr interleave; the marker is
#      one line among many and its neighbours carry no information about it.
#   3. Branch scope. In a batch run the same KEY is emitted for several
#      branches into one transcript. Asking for a branch means the answer must
#      come from that branch or be empty — never from whichever branch happened
#      to be emitted last.
#   4. Recency. The same KEY is re-emitted every cycle. The newest wins — and
#      "newest" is evaluated *after* the branch filter, not before, or rule 3
#      collapses into rule 4 whenever another branch emitted more recently.
#
# Exact-token matching (both key and field name) is not a fifth rule so much as
# the reason the first four are implementable at all: `RESET` is a substring of
# `FIRE_RESET`, `ITERATE_CB` of `ITERATE_CB_MODE`, and `failed` of both
# `failed-refire` and `failed-stale`. Every one of those pairs is live in
# skills/iterate/SKILL.md. Matching is therefore by whole token, never by
# substring — `case "$line" in "[CONTEXT] $key="*)` gets the anchor and the
# token boundary in one comparison.
#
# Why `case` globs and not sed/grep: the parse must behave identically on the
# GNU and BSD toolchains the CI matrix runs, and every regex dialect difference
# that has cost this repo a red macOS build lives in those two commands. A
# `while IFS= read -r` loop over `case` patterns has no dialect.
#
# Usage (source it — the functions are called from bash blocks that already
# source sibling helpers, so there is no subprocess entry point):
#
#   # from hooks/scripts/:  source "$(dirname "${BASH_SOURCE[0]}")/lib/context-marker.sh"
#   # from hooks/:          source "$(dirname "${BASH_SOURCE[0]}")/scripts/lib/context-marker.sh"
#   # from a SKILL.md bash block: source {plugin_root}/hooks/scripts/lib/context-marker.sh
#
#   marker_emit ITERATE_CB fire "cycle=$cc" "max=$max_cycles"
#   # → [CONTEXT] ITERATE_CB=fire; cycle=3; max=15
#
#   verdict=$(printf '%s\n' "$trend_out" | marker_get TREND_DIVERGENCE)
#   trend=$(printf '%s\n' "$trend_out" | marker_get TREND_DIVERGENCE --field trend)
#   wt=$(printf '%s\n' "$wt_out" | marker_get WT_ENSURE --branch "$branch")
#
# Contract:
#   marker_emit <KEY> <VALUE> [<FIELD>=<VALUE> ...]
#     - writes exactly one line to stdout: `[CONTEXT] KEY=VALUE` followed by
#       `; FIELD=VALUE` per extra argument, separator exactly `"; "`.
#     - VALUE and every FIELD value may be empty (`path=` is a real emission).
#     - rejects, with an ERROR on stderr and rc 1, anything that would produce a
#       line the reader cannot parse back: an empty or non-token KEY / FIELD
#       name, an extra argument without `=`, and a newline or `;` anywhere in a
#       value. Those are the two characters the format spends — a newline forges
#       a second marker line, a `;` forges a field — so emitting them would be a
#       silent contract break at the reader, which is the failure this file
#       exists to remove. Nothing is written to stdout on rejection.
#
#   marker_get <KEY> [--field <NAME>] [--branch <BRANCH>]
#     - reads the text to search from stdin.
#     - writes the matched value to stdout and returns 0.
#     - no match → writes nothing, still returns 0. Absence is the caller's
#       `--default ""` case (same convention as flow-state.sh get), not an
#       error: callers branch on the empty string.
#     - --field NAME returns that field's value from the selected line, empty
#       when the line carries no such field.
#     - --branch BRANCH keeps only lines whose `branch=` field equals BRANCH
#       exactly; a line with no `branch=` field never matches.
#     - --field and --branch require a value: passed as the last token they are
#       rejected with an ERROR and rc 1, the same way emit rejects what it
#       cannot write. Reading a missing value as the empty string would be
#       silent — an empty --field returns the primary value and an empty
#       --branch matches `branch=` only.
#     - among the lines that survive the filters, the last one in input order
#       wins.
#     - lines emitted by a plain `echo "[CONTEXT] ..."` parse identically —
#       there is one format, and this file did not invent it.

# Strip control characters from a value before it is echoed back in a
# diagnostic. **Defined ahead of every check that quotes its input** — the
# rejection messages below echo the value that failed validation, i.e. the one
# value known to contain a newline, so quoting it unscrubbed forges a second
# line at column 0 inside the very output that says the input was rejected.
# That is the forgery this file exists to prevent, arriving through its own
# error path. Implemented with a builtin substitution (no `tr`) for the same
# reason review-save-json-verify.sh does: a diagnostic must not depend on PATH
# being intact. Same shape as that file's `_scrub`.
_marker_scrub() { local _s="$1"; printf '%s' "${_s//[[:cntrl:]]/}"; }

# Reject values that would forge structure in the emitted line. Kept as one
# helper so emit's key/value/field checks cannot drift apart.
_marker_reject_chars() {
  local what="$1" value="$2"
  case "$value" in
    *$'\n'*)
      echo "ERROR: marker_emit: $what に改行を含められません (marker は 1 行 = 1 marker)" >&2
      return 1 ;;
    *';'*)
      echo "ERROR: marker_emit: $what に ';' を含められません (';' は field 区切り)" >&2
      return 1 ;;
  esac
  return 0
}

# Token shape for a KEY or a field name: what can be compared as a whole token
# on the read side. Anything else would need quoting rules the format has none of.
_marker_valid_name() {
  case "$1" in
    ''|*[!A-Za-z0-9_]*) return 1 ;;
    *) return 0 ;;
  esac
}

marker_emit() {
  local key="$1"
  if ! _marker_valid_name "$key"; then
    echo "ERROR: marker_emit: KEY が不正です ('$(_marker_scrub "$key")')。英数字とアンダースコアのみ使用できます" >&2
    return 1
  fi
  shift
  if [ "$#" -lt 1 ]; then
    echo "ERROR: marker_emit: VALUE が必要です (marker_emit KEY VALUE [FIELD=VALUE ...])" >&2
    return 1
  fi
  local value="$1"; shift
  _marker_reject_chars "KEY=$key の値" "$value" || return 1

  local line="[CONTEXT] $key=$value"
  local arg name fval
  for arg in "$@"; do
    case "$arg" in
      *=*) ;;
      *)
        echo "ERROR: marker_emit: 追加フィールドは FIELD=VALUE 形式である必要があります ('$(_marker_scrub "$arg")')" >&2
        return 1 ;;
    esac
    name="${arg%%=*}"
    fval="${arg#*=}"
    if ! _marker_valid_name "$name"; then
      echo "ERROR: marker_emit: フィールド名が不正です ('$(_marker_scrub "$name")')。英数字とアンダースコアのみ使用できます" >&2
      return 1
    fi
    _marker_reject_chars "フィールド $name の値" "$fval" || return 1
    line="$line; $name=$fval"
  done
  printf '%s\n' "$line"
}

# Read one `; `-separated field out of an already-anchored marker body.
# Prints the value; returns 1 when the field is absent so callers can tell an
# absent field from a present-but-empty one.
_marker_field_of() {
  local body="$1" want="$2" seg rest name
  rest="$body"
  while [ -n "$rest" ]; do
    case "$rest" in
      *"; "*) seg="${rest%%"; "*}"; rest="${rest#*"; "}" ;;
      *)      seg="$rest"; rest="" ;;
    esac
    case "$seg" in
      *=*) name="${seg%%=*}" ;;
      *)   continue ;;
    esac
    if [ "$name" = "$want" ]; then
      printf '%s' "${seg#*=}"
      return 0
    fi
  done
  return 1
}

marker_get() {
  local key="$1"; shift
  local field="" branch="" have_branch=0
  while [ "$#" -gt 0 ]; do
    # Consumption is `shift; shift`, never `shift 2`: with $#=1 the latter is a
    # no-op non-zero return, so the loop would re-read the same lone flag
    # forever (the caller sees a Bash tool timeout, not an error). The guard in
    # front rejects the lone flag outright rather than letting it through as an
    # empty value, which emit's rejection path already treats as a contract
    # break the reader cannot detect.
    case "$1" in
      --field)
        [ "$#" -ge 2 ] || {
          echo "ERROR: marker_get: --field には値が必要です (marker_get KEY [--field NAME] [--branch BRANCH])" >&2
          return 1
        }
        field="$2"; shift; shift ;;
      --branch)
        [ "$#" -ge 2 ] || {
          echo "ERROR: marker_get: --branch には値が必要です (marker_get KEY [--field NAME] [--branch BRANCH])" >&2
          return 1
        }
        branch="$2"; have_branch=1; shift; shift ;;
      *)
        echo "ERROR: marker_get: 不明な引数 '$(_marker_scrub "$1")' (marker_get KEY [--field NAME] [--branch BRANCH])" >&2
        return 1 ;;
    esac
  done
  if ! _marker_valid_name "$key"; then
    echo "ERROR: marker_get: KEY が不正です ('$(_marker_scrub "$key")')。英数字とアンダースコアのみ使用できます" >&2
    return 1
  fi

  local prefix="[CONTEXT] $key=" line="" body found="" line_branch
  # `|| [ -n "$line" ]` keeps the final line when the input has no trailing
  # newline (a truncated log). The next `read` hits EOF with nothing to read and
  # assigns the empty string, so the guard is false on the following pass and the
  # loop ends — no manual reset is needed to stop EOF re-serving the same line.
  while IFS= read -r line || [ -n "$line" ]; do
    # Line anchor + whole-token key: the pattern ends at `=`, so `ITERATE_CB`
    # cannot match an `ITERATE_CB_MODE=` line.
    case "$line" in
      "$prefix"*) body="${line#"[CONTEXT] "}" ;;
      *) continue ;;
    esac
    # Branch filter runs before recency. Reversing them would return the newest
    # line of *any* branch whenever the newest happens to be a different one.
    if [ "$have_branch" = 1 ]; then
      line_branch=$(_marker_field_of "$body" branch) || continue
      [ "$line_branch" = "$branch" ] || continue
    fi
    found="$body"   # last surviving line wins
  done

  [ -n "$found" ] || return 0
  if [ -n "$field" ]; then
    local fval
    fval=$(_marker_field_of "$found" "$field") || return 0
    printf '%s\n' "$fval"
    return 0
  fi
  # The primary value is the first segment, minus the `KEY=` it is anchored on.
  local first="${found%%"; "*}"
  printf '%s\n' "${first#*=}"
}
