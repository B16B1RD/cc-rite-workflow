#!/usr/bin/env bash
# tempfile-lifecycle-check.sh
#
# Flag two shell defects that keep coming back in hooks/ and scripts/ and that a
# grep can actually see. Non-blocking warnings, like the sibling checkers: this
# never changes [lint:success].
#
# Why a checker and not just the lib:
#   hooks/scripts/lib/tempfile.sh removes the tempfile-lifecycle defects for code
#   that uses it — the sequence is no longer written by hand, so it cannot be
#   written wrong. Two residues are outside what a lib can reach, because they
#   are ways of writing a path or a pipeline rather than ways of calling a
#   function. Those are what this scans for.
#
# Detected patterns:
#   (1) mktemp-derived-path — a path derived from a tempfile handle, e.g.
#       `"$tmp.part"`, `"${tmp}_bak"`, `"$tmp-1"`, `"${tmp%.tmp}.log"`. mktemp's
#       safety comes from creating a random name with O_CREAT|O_EXCL; a name
#       derived from it was never created that way and is predictable once the
#       original is observed, so a planted symlink at the derived path is
#       followed and its target truncated. Measured end to end by a security
#       reviewer on #2051. Fix: take a second handle instead of deriving one.
#
#       Handles are tracked from both spellings: `x=$(mktemp ...)` and the lib
#       form `rite_tempfile_new x` / `rite_tempdir_new x`. Tracking only the raw
#       mktemp form would put the spelling that coding-principles.md now
#       *mandates* into this checker's blind spot.
#
#   (2) pipefail-grep-q-stream — under `set -o pipefail`, a pipeline whose
#       consumer is `grep -q`. grep -q exits at the first match, so a producer
#       still writing takes SIGPIPE and the whole pipeline reports 141. It fires
#       only when the match happens to come early, which is why it surfaces as a
#       flaky skip: on #2094 it silently dropped one file per ~200 runs and the
#       floor guard was too loose to notice. Fix: drop the pipeline
#       (`grep -q PAT file`) or count instead (`grep -c`, which reads to EOF).
#
#       The producer examined is the stage *immediately* feeding `grep -q`, not
#       the head of the whole pipeline. Exempting on the pipeline head would let
#       a three-stage `printf | jq | grep -q` through on the strength of the
#       printf, while the stage that actually takes the SIGPIPE is jq.
#
#       That immediate producer is exempt when it is `printf` or `echo`: a short
#       in-memory string fits the pipe buffer, so the producer finishes before
#       the consumer can exit. The exemption is keyed on the command name, which
#       is a proxy — a `printf` whose payload scales with repository content
#       (`wiki-lint-orphans.sh`, `wiki-lint-broken-refs.sh`) can exceed the 64 KiB
#       buffer and is knowingly not covered. Most `grep -q` pipelines in this
#       repo are the short-string shape, and flagging them would bury the real
#       findings.
#
# Deliberately NOT detected: `x=$(mktemp 2>/dev/null) || x=""`. It reads like the
#   silencing defect, but it is the house idiom for a non-blocking stderr-capture
#   slot and appears at 88 sites. A warning there would be pure noise. The real
#   defect in that family — a failure that produces no diagnostic at all — is
#   removed at the source instead: rite_tempfile_new is loud and returns
#   non-zero, so the silent-empty-path outcome has no spelling.
#
# Scanned surface: plugins/rite/hooks/**/*.sh and plugins/rite/scripts/**/*.sh,
#   excluding tests/ (fixtures embed the patterns on purpose).
#
# Exclusion: a `drift-check-ignore` marker on the finding line or on the line
#   directly above it, mirroring sh-cross-ref-check.sh / bash-heaviness-check.sh.
#
# Usage:
#   tempfile-lifecycle-check.sh [--all] [--target FILE]... [--repo-root DIR]
#                               [--quiet] [--skip-if-no-target]
#
# Exit codes: 0 = clean (or not-applicable skip), 1 = pattern detected,
#             2 = invocation error, or one or more files could not be scanned.
#
# A file that could not be scanned is an error, not a clean bill. Folding "did
# not look" into "found nothing" inside a checker reproduces, within the guard,
# the very defect class the guard exists to catch — so an unreadable target or a
# failed awk run is counted and surfaced, and the run exits 2 (findings still win
# the exit code when both are present). Same contract as dollar-zero-check.sh.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/tempfile.sh
source "$SCRIPT_DIR/lib/tempfile.sh"

REPO_ROOT=""
QUIET=0
declare -a TARGETS=()
USE_ALL=0
SKIP_IF_NO_TARGET=0

# Directories walked by --all. Kept here so widening the surface is one edit.
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
  mktemp-derived-path     — a path derived from a tempfile handle (read or write)
  pipefail-grep-q-stream  — `grep -q` consuming a pipeline under pipefail
                            (exempt when the immediate producer is printf/echo)

Exclusions: tests/ ; lines carrying 'drift-check-ignore' (or with the marker on
the line directly above).

Exit codes:
  0  Clean (or not-applicable skip)
  1  Pattern detected
  2  Invocation error, or one or more files could not be scanned (the result is
     not a clean bill). When findings are also present the exit code is 1 and
     the unscannable count is still printed.
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
    [ -d "$d" ] || continue
    found_dir=1
    # find's stderr is not discarded: an unreadable subdirectory silently
    # dropping files from the target list is the same "did not look" outcome the
    # exit-2 contract above exists to surface.
    while IFS= read -r f; do
      case "$f" in */tests/*) continue ;; esac
      TARGETS+=("$f")
    done < <(find "$d" -type f -name '*.sh' | sort)
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

# The scanner. Two passes' worth of work in one END block: physical lines are
# buffered first so backslash continuations can be joined into logical lines
# (the canonical multi-line pipeline form would otherwise hide the consumer from
# the producer). POSIX awk only — no 3-argument match(), no gensub() — because
# macOS ships the BSD one.
#
# `pipefail` is passed in from the shell: pattern (2) only means anything in a
# file that actually enables it.
cat > "$AWK_PROG" <<'AWK'
BEGIN { nvars = 0 }
{ L[NR] = $0 }

# The tempfile handle this line creates, or "" when it creates none. Both
# spellings count: the raw `x=$(mktemp` / `x="$(mktemp` assignment, and the lib's
# out-variable form `rite_tempfile_new x` / `rite_tempdir_new x`.
function mktemp_target(s,   t, p) {
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

# True when `needle` occurs in `s` followed by a suffix character — so
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

# True when the line derives a path from handle `v` in any of the spellings that
# occur in practice. Checking only `$v.` would leave `${v}_bak`, `$v-1` and
# `"$v".part` — the most natural of the set — unseen.
function derived_any(s, v) {
  # Unbraced `$v_suffix` is deliberately absent: bash reads the whole run of
  # [A-Za-z0-9_] as one name, so `$tmp_bak` is the variable `tmp_bak`, not a
  # derivation of `$tmp`. Treating it as one flags every sibling variable that
  # shares a prefix (`$pr_view_err` vs `$pr_view_err_oneline`).
  if (derived_use(s, "$" v ".")) return 1
  if (derived_use(s, "$" v "-")) return 1
  if (derived_use(s, "${" v "}.")) return 1
  if (derived_use(s, "${" v "}_")) return 1
  if (derived_use(s, "${" v "}-")) return 1
  if (index(s, "\"$" v "\".") > 0) return 1
  if (index(s, "\"${" v "}\".") > 0) return 1
  # Prefix/suffix-strip expansions need no suffix test: rewriting a tempfile path
  # with an expansion is only ever done to derive another path.
  if (index(s, "${" v "%") > 0) return 1
  if (index(s, "${" v "#") > 0) return 1
  return 0
}

# First word of the stage immediately feeding `grep -q` — the process that would
# actually take the SIGPIPE. `prefix` is everything left of that pipe, with `||`
# already masked to \001.
function pipeline_producer(prefix,   cut, i, seg, head, n, parts) {
  # Keep only the text after the last control operator: `a && b | grep -q` is a
  # pipeline headed by b, not by a.
  cut = 0
  for (i = length(prefix); i > 0; i--) {
    if (substr(prefix, i, 1) == "\001" || substr(prefix, i, 1) == ";") { cut = i; break }
    if (substr(prefix, i, 2) == "&&") { cut = i + 1; break }
  }
  if (cut > 0) prefix = substr(prefix, cut + 1)
  # The LAST segment, not the first: in `printf ... | jq ... | grep -q` the stage
  # that dies is jq, and exempting on the printf at the head would let it pass.
  n = split(prefix, parts, "|")
  seg = parts[n]
  # Strip leading shell keywords and grouping so the first word is the command.
  # Word keywords need at least one space after them, or `docker ps` reports its
  # producer as `cker` (the zero-width match eats the `do`).
  while (1) {
    if (match(seg, /^[[:space:]]*(if|elif|while|until|then|do|!)[[:space:]]+/)) {
      head = substr(seg, RSTART + RLENGTH)
    } else if (match(seg, /^[[:space:]]*[({][[:space:]]*/)) {
      head = substr(seg, RSTART + RLENGTH)
    } else {
      break
    }
    if (head == seg) break
    seg = head
  }
  sub(/^[[:space:]]+/, "", seg)
  if (!match(seg, /^[A-Za-z0-9_.\/-]+/)) return ""
  return substr(seg, RSTART, RLENGTH)
}

END {
  for (i = 1; i <= NR; i++) {
    start = i
    line = L[i]
    while (line ~ /\\[[:space:]]*$/ && i < NR) {
      sub(/\\[[:space:]]*$/, "", line)
      i++
      line = line L[i]
    }

    v = mktemp_target(line)
    if (v != "") { known = 0
      for (k = 1; k <= nvars; k++) if (vars[k] == v) known = 1
      if (!known) { nvars++; vars[nvars] = v }
    }

    if (line ~ /^[[:space:]]*#/) continue
    prev = (start > 1) ? L[start - 1] : ""
    if (line ~ /drift-check-ignore/ || prev ~ /drift-check-ignore/) continue

    # --- (1) mktemp-derived-path ---
    for (k = 1; k <= nvars; k++) {
      if (derived_any(line, vars[k])) {
        printf "[tempfile-lifecycle] %s:%d: mktemp-derived-path — a path derived from $%s loses mktemp's O_CREAT|O_EXCL guarantee; take a second handle instead of deriving one\n", fname, start, vars[k]
        break
      }
    }

    # --- (2) pipefail-grep-q-stream ---
    if (pipefail != "1") continue
    masked = line
    gsub(/\|\|/, "\001", masked)
    if (!match(masked, /\|&?[[:space:]]*grep[[:space:]]+-[A-Za-z]*q/)) continue
    producer = pipeline_producer(substr(masked, 1, RSTART - 1))
    if (producer == "printf" || producer == "echo") continue
    # An unidentifiable producer is reported, not skipped: a silent exemption
    # that no prose describes is exactly the blind spot this checker is for.
    if (producer == "") producer = "(producer unidentified)"
    printf "[tempfile-lifecycle] %s:%d: pipefail-grep-q-stream — `grep -q` exits at the first match and `%s` then takes SIGPIPE, failing the pipeline under pipefail; use `grep -q PAT file` or count with `grep -c`\n", fname, start, producer
  }
}
AWK

# Files the scanner could not read or parse. Kept separate from findings so the
# exit code can distinguish "nothing to report" from "did not look".
SKIPPED=0

log "Scanning ${#TARGETS[@]} file(s)..."
for t in "${TARGETS[@]}"; do
  if [ ! -f "$t" ]; then
    echo "WARNING: target not found: $t — file not scanned" >&2
    SKIPPED=$((SKIPPED + 1))
    continue
  fi
  # Pattern (2) is only a defect where pipefail turns the SIGPIPE into a failure.
  # grep's three exit codes are kept apart: 1 is "no pipefail" but 2 is "could
  # not read", and folding the latter into the former would silently disable
  # pattern (2) for that file.
  grep -qE '^[[:space:]]*set[[:space:]]+-[a-zA-Z]*o[[:space:]]+pipefail|^[[:space:]]*set[[:space:]]+-o[[:space:]]+pipefail' "$t"
  grep_rc=$?
  case "$grep_rc" in
    0) pipefail_flag=1 ;;
    1) pipefail_flag=0 ;;
    *)
      echo "WARNING: pipefail probe failed on $t (grep rc=$grep_rc) — file not scanned" >&2
      SKIPPED=$((SKIPPED + 1))
      continue
      ;;
  esac
  awk -v fname="$t" -v pipefail="$pipefail_flag" -f "$AWK_PROG" "$t" >> "$FINDINGS_FILE"
  awk_rc=$?
  if [ "$awk_rc" -ne 0 ]; then
    echo "WARNING: awk failed on $t (rc=$awk_rc) — file not scanned" >&2
    SKIPPED=$((SKIPPED + 1))
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

if [ "$SKIPPED" -gt 0 ]; then
  echo "ERROR: ${SKIPPED} file(s) could not be scanned — this run is not a clean bill" >&2
fi

# Findings win the exit code: making an unscannable file force rc=2 even when
# real findings exist would turn every detection run into an "invocation error"
# in the lint table.
if [ "$total" -gt 0 ]; then
  exit 1
fi
if [ "$SKIPPED" -gt 0 ]; then
  exit 2
fi
exit 0
