#!/usr/bin/env bash
# tempfile-lifecycle-check.sh
#
# Flag paths derived from a tempfile handle. Non-blocking warnings, like the
# sibling checkers: this never changes [lint:success].
#
# Why a checker and not just the lib:
#   hooks/scripts/lib/tempfile.sh removes the tempfile-lifecycle defects for code
#   that uses it — the create/register/remove sequence is no longer written by
#   hand, so it cannot be written wrong. One residue is outside what a lib can
#   reach, because it is a way of writing a *path* rather than a way of calling a
#   function. That is what this scans for.
#
# Detected pattern — mktemp-derived-path:
#   A path derived from a tempfile handle, e.g. `"$tmp.part"`, `"${tmp}_bak"`,
#   `"$tmp"-1`, `"${tmp%.tmp}.log"`. mktemp's safety comes from creating a random
#   name with O_CREAT|O_EXCL; a name derived from it was never created that way
#   and is predictable once the original is observed, so a planted symlink at the
#   derived path is followed and its target truncated. Measured end to end by a
#   security reviewer on dollar-zero-check.sh. Fix: take a second handle instead
#   of deriving one.
#
#   Handles are tracked from both spellings: `x=$(mktemp ...)` and the lib form
#   `rite_tempfile_new x` / `rite_tempdir_new x`. Tracking only the raw mktemp
#   form would put the spelling that coding-principles.md mandates into this
#   checker's blind spot.
#
#   Unbraced `$tmp_suffix` is NOT a derivation: bash reads the whole run of
#   [A-Za-z0-9_] as one name, so that is the variable `tmp_suffix`. Treating it
#   as one flags every sibling variable sharing a prefix. That is the only
#   spelling carved out; dirname and basename idioms are reported like any other
#   strip expansion.
#
# Deliberately NOT detected: `x=$(mktemp 2>/dev/null) || x=""`. It reads like the
#   silencing defect, but it is the house idiom for a non-blocking stderr-capture
#   slot and appears at scale (100+ sites). A warning there would be pure noise.
#   The real defect in that family — a failure that produces no diagnostic at all
#   — is removed at the source instead: rite_tempfile_new is loud and returns
#   non-zero, so the silent-empty-path outcome has no spelling.
#
# Scanned surface: plugins/rite/hooks/**/*.sh and plugins/rite/scripts/**/*.sh,
#   excluding tests/ (fixtures embed the pattern on purpose).
#
# Exclusion: a `drift-check-ignore` marker on the finding line or on the line
#   directly above it. The same marker name is used by sh-cross-ref-check.sh and
#   number-reference-check.sh (same line only) and bash-heaviness-check.sh
#   (anywhere in the block); the line-above form is specific to this checker.
#
# Usage:
#   tempfile-lifecycle-check.sh [--all] [--target FILE]... [--repo-root DIR]
#                               [--quiet] [--skip-if-no-target]
#
# Exit codes: 0 = clean (or not-applicable skip), 1 = pattern detected,
#             2 = invocation error, or a file could not be scanned / a directory
#             enumeration failed.
#
# A file that could not be scanned is an error, not a clean bill. Folding "did
# not look" into "found nothing" inside a checker reproduces, within the guard,
# the very defect class the guard exists to catch — so an unreadable target, a
# failed enumeration, or a failed awk run is counted and surfaced, and the run
# exits 2 (findings still win the exit code when both are present). Same
# contract as dollar-zero-check.sh.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/tempfile.sh
source "$SCRIPT_DIR/lib/tempfile.sh"

REPO_ROOT=""
QUIET=0
declare -a TARGETS=()
USE_ALL=0
SKIP_IF_NO_TARGET=0

# Files the scanner could not read or parse. Declared before the enumeration so
# a failed --all walk can count itself.
# Two counters, not one: an enumeration failure hides an unknown number of
# files (find could not descend, so there is nothing to count), while the other
# two paths lose exactly one file each. Reporting both as "files" understated
# the unscanned surface by the size of the hidden subtree.
SKIPPED_FILES=0
SKIPPED_ENUM=0

# Directories walked by --all. The same list is restated in this file's header,
# in the usage text below, in docs/SPEC.md, and in
# skills/lint/references/plugin-checks-rationale.md — widening the surface means
# editing all five.
declare -a SCAN_DIRS=("plugins/rite/hooks" "plugins/rite/scripts")

usage() {
  cat <<'EOF'
Usage: tempfile-lifecycle-check.sh [options]

Options:
  --all              Scan plugins/rite/hooks/**/*.sh and plugins/rite/scripts/**/*.sh
                     (excluding tests/)
  --target FILE      Check FILE (repeatable). Path relative to repo root.
  --repo-root DIR    Repository root (default: git rev-parse --show-toplevel)
  --quiet            Suppress progress output on stderr (findings and the total
                     stay on stdout)
  --skip-if-no-target
                     With --all, exit 0 (not 2) when no scan directory exists
                     under the repo root — the consumer-repo case where rite is
                     a marketplace plugin only
  -h, --help         Show this help

Detected:
  mktemp-derived-path — a path derived from a tempfile handle (read or write)

Exclusions: tests/ ; lines carrying 'drift-check-ignore' (or with the marker on
the line directly above).

Exit codes:
  0  Clean (or not-applicable skip)
  1  Pattern detected
  2  Invocation error, or a file could not be scanned / a directory enumeration
     failed (the result is not a clean bill). When findings are also present the
     exit code is 1 and the unscanned counts are still printed.
EOF
}

log() { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*" >&2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --all) USE_ALL=1; shift ;;
    --target)
      [ $# -ge 2 ] || { echo "ERROR: --target requires a value" >&2; usage >&2; exit 2; }
      TARGETS+=("$2"); shift 2 ;;
    --repo-root)
      [ $# -ge 2 ] || { echo "ERROR: --repo-root requires a value" >&2; usage >&2; exit 2; }
      REPO_ROOT="$2"; shift 2 ;;
    --quiet) QUIET=1; shift ;;
    --skip-if-no-target) SKIP_IF_NO_TARGET=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ -z "$REPO_ROOT" ]; then
  REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
fi
if [ ! -d "$REPO_ROOT" ]; then
  echo "ERROR: repo-root not a directory: $REPO_ROOT" >&2
  exit 2
fi
cd "$REPO_ROOT" || { echo "ERROR: cannot cd to $REPO_ROOT" >&2; exit 2; }

if [ "$USE_ALL" -eq 1 ]; then
  found_dir=0
  for d in "${SCAN_DIRS[@]}"; do
    if [ ! -d "$d" ]; then
      # A missing scan dir is not counted as unscanned: a directory that does
      # not exist holds no files to miss. The case this matters for is the
      # consumer repo, where all of them are absent and --skip-if-no-target
      # turns the empty walk into a clean skip. A SCAN_DIRS typo is caught by
      # the test that plants a defect under the second dir, not here.
      continue
    fi
    found_dir=1
    # find's rc is captured, not just its stderr: an unreadable subdirectory
    # drops files from the target list, and a list that silently lost entries is
    # indistinguishable from a clean scan unless the failure reaches the exit
    # code.
    listing=$(find "$d" -type f -name '*.sh' | sort)
    find_rc=$?
    if [ "$find_rc" -ne 0 ]; then
      echo "WARNING: enumeration failed under $d (rc=$find_rc) — the target list is incomplete" >&2
      SKIPPED_ENUM=$((SKIPPED_ENUM + 1))
    fi
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      case "$f" in */tests/*) continue ;; esac
      TARGETS+=("$f")
    done <<< "$listing"
  done
  if [ "$found_dir" -eq 0 ]; then
    if [ "$SKIP_IF_NO_TARGET" -eq 1 ]; then
      echo "[tempfile-lifecycle] not applicable: none of ${SCAN_DIRS[*]} exist under $REPO_ROOT — clean skip (--skip-if-no-target)" >&2
      echo "==> Total tempfile-lifecycle findings: 0"
      exit 0
    fi
    echo "ERROR: --all requested but none of ${SCAN_DIRS[*]} exist under $REPO_ROOT" >&2
    echo "  Likely cause: invoked outside the rite plugin repo (e.g. marketplace install)" >&2
    echo "  Recovery: run from the rite plugin source tree, pass --target FILE explicitly, or pass --skip-if-no-target" >&2
    exit 2
  fi
fi

if [ "${#TARGETS[@]}" -eq 0 ]; then
  echo "ERROR: no targets specified (use --all or --target FILE)" >&2
  usage >&2
  exit 2
fi

rite_tempfile_init || exit 2
rite_tempdir_new WORKDIR "tempfile-lifecycle" || exit 2
AWK_PROG="$WORKDIR/scan.awk"
FINDINGS_FILE="$WORKDIR/findings"
: > "$FINDINGS_FILE"

# The scanner. Physical lines are buffered first so backslash continuations can
# be joined into logical lines. POSIX awk only — no 3-argument match(), no
# gensub() — because macOS ships the BSD one.
cat > "$AWK_PROG" <<'AWK'
BEGIN { nvars = 0 }
{ L[NR] = $0 }

# The tempfile handle this line creates, or "" when it creates none. Both
# spellings count: the raw `x=$(mktemp` / `x="$(mktemp` assignment, and the lib's
# out-variable form `rite_tempfile_new x` / `rite_tempdir_new x`.
function handle_target(s,   t, p) {
  if (match(s, /[A-Za-z_][A-Za-z0-9_]*="?\$\([[:space:]]*mktemp/)) {
    t = substr(s, RSTART, RLENGTH)
    p = index(t, "=")
    return substr(t, 1, p - 1)
  }
  if (match(s, /rite_temp(file|dir)_new[[:space:]]+[A-Za-z_][A-Za-z0-9_]*/)) {
    t = substr(s, RSTART, RLENGTH)
    sub(/^rite_temp(file|dir)_new[[:space:]]+/, "", t)
    return t
  }
  return ""
}

# True when `needle` occurs in `s` followed by a word character — so
# `"$tmp.part"` counts and a sentence ending in `$tmp.` does not.
function derived_use(s, needle,   pos, rest, c) {
  pos = index(s, needle)
  while (pos > 0) {
    c = substr(s, pos + length(needle), 1)
    if (c ~ /[A-Za-z0-9_]/) return 1
    rest = substr(s, pos + 1)
    pos = index(rest, needle)
    if (pos > 0) pos = pos + (length(s) - length(rest))
  }
  return 0
}

# True when the line derives a path from handle `v`. The spellings are the ones
# that occur in practice: a dot or dash suffix on `$v`; a dot, dash or word
# suffix on `${v}`, `"$v"` or `"${v}"` (the braces or the closing quote end the
# name, so a word character after them is a suffix rather than part of it); or a
# prefix/suffix-strip expansion.
#
# Unbraced `$v_suffix` is deliberately absent: bash reads the whole run of
# [A-Za-z0-9_] as one name, so `$tmp_bak` is the variable `tmp_bak`, not a
# derivation of `$tmp`. Treating it as one flags every sibling variable that
# shares a prefix (`$pr_view_err` vs `$pr_view_err_oneline`).
function derived_any(s, v,   pos) {
  # `${v:-}` is the canonical cleanup spelling in this repo (`rm -f "${tmp:-}"`),
  # so a derivation off it (`"${tmp:-}.part"`) has to read the same as `${tmp}`.
  # Rewriting the occurrences is one line; duplicating all 13 branches is not.
  pos = index(s, "${" v ":-}")
  while (pos > 0) {
    s = substr(s, 1, pos - 1) "${" v "}" substr(s, pos + length(v) + 5)
    pos = index(s, "${" v ":-}")
  }
  if (derived_use(s, "$" v ".")) return 1
  if (derived_use(s, "$" v "-")) return 1
  if (derived_use(s, "${" v "}")) return 1
  if (derived_use(s, "${" v "}.")) return 1
  if (derived_use(s, "${" v "}-")) return 1
  if (derived_use(s, "\"$" v "\"")) return 1
  if (index(s, "\"$" v "\".") > 0) return 1
  if (index(s, "\"$" v "\"-") > 0) return 1
  if (derived_use(s, "\"${" v "}\"")) return 1
  if (index(s, "\"${" v "}\".") > 0) return 1
  if (index(s, "\"${" v "}\"-") > 0) return 1
  # Prefix/suffix-strip expansions need no suffix test: rewriting a tempfile path
  # with an expansion is only ever done to derive another path. The dirname and
  # basename idioms are not carved out: an exclusion for them suppressed no
  # measured false positive in this tree, and it cost the suffixed forms
  # (`"${tmp##*/}.log"`) that are derivations by any reading.
  if (index(s, "${" v "%") > 0) return 1
  if (index(s, "${" v "#") > 0) return 1
  return 0
}

# Fold a backslash-continued logical line starting at physical line `i`, and
# report where it ended through the global `join_end`.
function join_logical(i,   line) {
  line = L[i]
  while (line ~ /\\[[:space:]]*$/ && i < NR) {
    sub(/\\[[:space:]]*$/, "", line)
    i++
    line = line L[i]
  }
  join_end = i
  return line
}

END {
  # Two passes, because a derivation is routinely written *above* the mktemp
  # that produces the handle. The canonical trap template in
  # references/bash-trap-patterns.md — declare, define cleanup, install trap,
  # then mktemp — puts the cleanup function, the likeliest place to spell a
  # derived path, before the assignment. A single pass registers handles as it
  # goes and would call that file clean.
  for (i = 1; i <= NR; i++) {
    line = join_logical(i)
    i = join_end
    # Comments seed no state: a usage example in a docstring would otherwise
    # register a handle and make every unrelated `$x.log` in the file a finding.
    if (line ~ /^[[:space:]]*#/) continue
    v = handle_target(line)
    if (v != "") { known = 0
      for (k = 1; k <= nvars; k++) if (vars[k] == v) known = 1
      if (!known) { nvars++; vars[nvars] = v }
    }
  }

  for (i = 1; i <= NR; i++) {
    start = i
    line = join_logical(i)
    i = join_end

    if (line ~ /^[[:space:]]*#/) continue

    prev = (start > 1) ? L[start - 1] : ""
    if (line ~ /drift-check-ignore/ || prev ~ /drift-check-ignore/) continue

    for (k = 1; k <= nvars; k++) {
      if (derived_any(line, vars[k])) {
        printf "[tempfile-lifecycle] %s:%d: mktemp-derived-path — a path derived from $%s loses mktemp's O_CREAT|O_EXCL guarantee; take a second handle instead of deriving one\n", fname, start, vars[k]
        break
      }
    }
  }
}
AWK

if [ ! -s "$AWK_PROG" ]; then
  echo "ERROR: failed to write the scanner program to $AWK_PROG" >&2
  exit 2
fi

log "Scanning ${#TARGETS[@]} file(s)..."
for t in "${TARGETS[@]}"; do
  if [ ! -f "$t" ]; then
    echo "WARNING: target not found: $t — file not scanned" >&2
    SKIPPED_FILES=$((SKIPPED_FILES + 1))
    continue
  fi
  awk -v fname="$t" -f "$AWK_PROG" "$t" >> "$FINDINGS_FILE"
  awk_rc=$?
  if [ "$awk_rc" -ne 0 ]; then
    echo "WARNING: awk failed on $t (rc=$awk_rc) — file not scanned" >&2
    SKIPPED_FILES=$((SKIPPED_FILES + 1))
  fi
done

if [ -s "$FINDINGS_FILE" ]; then
  cat "$FINDINGS_FILE"
  total=$(wc -l < "$FINDINGS_FILE")
else
  total=0
fi
total=$(printf '%s' "$total" | tr -d '[:space:]')
# stdout, not the --quiet-able log: the lint check table parses this line.
echo "==> Total tempfile-lifecycle findings: ${total}"

if [ "$SKIPPED_FILES" -gt 0 ] || [ "$SKIPPED_ENUM" -gt 0 ]; then
  echo "ERROR: ${SKIPPED_FILES} file(s) and ${SKIPPED_ENUM} directory enumeration(s) could not be scanned — this run is not a clean bill" >&2
fi

# Findings win the exit code: making an unscannable file force rc=2 even when
# real findings exist would turn every detection run into an "invocation error"
# in the lint table.
if [ "$total" -gt 0 ]; then
  exit 1
fi
if [ "$SKIPPED_FILES" -gt 0 ] || [ "$SKIPPED_ENUM" -gt 0 ]; then
  exit 2
fi
exit 0
