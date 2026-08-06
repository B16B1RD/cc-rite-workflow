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
#   (1) mktemp-derived-path — a path derived from a mktemp result, e.g.
#       `"$tmp.part"`, `"${tmp}.bak"`, `"${tmp%.tmp}.log"`. mktemp's safety comes
#       from creating a random name with O_CREAT|O_EXCL; a name derived from it
#       was never created that way and is predictable once the original is
#       observed, so a planted symlink at the derived path is followed and its
#       target truncated. Measured end to end by a security reviewer on #2051.
#       Fix: call mktemp again (or rite_tempdir_new) for the second handle.
#
#   (2) pipefail-grep-q-stream — under `set -o pipefail`, a pipeline whose
#       consumer is `grep -q`. grep -q exits at the first match, so a producer
#       still writing takes SIGPIPE and the whole pipeline reports 141. It fires
#       only when the match happens to come early, which is why it surfaces as a
#       flaky skip: on #2094 it silently dropped one file per ~200 runs and the
#       floor guard was too loose to notice. Fix: drop the pipeline
#       (`grep -q PAT file`) or count instead (`grep -c`, which reads to EOF).
#
#       Pipelines headed by `printf` or `echo` are NOT flagged. Those write a
#       short in-memory string that fits the pipe buffer, so the producer
#       finishes before the consumer can exit and no SIGPIPE is possible — 15 of
#       the 16 call sites in this repo are that shape, and flagging them would
#       bury the one real finding.
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
#             2 = invocation error.

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
  mktemp-derived-path     — a write target derived from a mktemp result
  pipefail-grep-q-stream  — `grep -q` consuming a pipeline under pipefail
                            (printf/echo-headed pipelines are exempt)

Exclusions: tests/ ; lines carrying 'drift-check-ignore' (or with the marker on
the line directly above).

Exit codes:
  0  Clean (or not-applicable skip)
  1  Pattern detected
  2  Invocation error
EOF
}

log() { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*" >&2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --all) USE_ALL=1; shift ;;
    --target) TARGETS+=("${2:-}"); shift; shift ;;
    --repo-root) REPO_ROOT="${2:-}"; shift; shift ;;
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
    while IFS= read -r f; do
      case "$f" in */tests/*) continue ;; esac
      TARGETS+=("$f")
    done < <(find "$d" -type f -name '*.sh' 2>/dev/null | sort)
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

# The variable on the left of `=$(mktemp` / `="$(mktemp`, or "" when the line is
# not such an assignment.
function mktemp_target(s,   t, p) {
  if (!match(s, /[A-Za-z_][A-Za-z0-9_]*=\"?\$\(mktemp/)) return ""
  t = substr(s, RSTART, RLENGTH)
  p = index(t, "=")
  return substr(t, 1, p - 1)
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

# First word of the command that heads the pipeline feeding `grep -q`.
# `prefix` is everything left of that pipe, with `||` already masked to \001.
function pipeline_head(prefix,   cut, i, seg, head, n, parts) {
  # Keep only the text after the last control operator: `a && b | grep -q` is a
  # pipeline headed by b, not by a.
  cut = 0
  for (i = length(prefix); i > 0; i--) {
    if (substr(prefix, i, 1) == "\001" || substr(prefix, i, 1) == ";") { cut = i; break }
    if (substr(prefix, i, 2) == "&&") { cut = i + 1; break }
  }
  if (cut > 0) prefix = substr(prefix, cut + 1)
  n = split(prefix, parts, "|")
  seg = parts[1]
  # Strip leading shell keywords and grouping so the first word is the command.
  while (match(seg, /^[[:space:]]*(if|elif|while|until|then|do|!|\(|\{)[[:space:]]*/)) {
    head = substr(seg, RSTART + RLENGTH)
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
      # The `.suffix` forms need the suffix character to distinguish a derived
      # path from a sentence that happens to end in `$tmp.`. The strip forms
      # (`${tmp%...}` / `${tmp#...}`) need no such test — rewriting a mktemp
      # path with an expansion is only ever done to derive another path.
      if (derived_use(line, "$" vars[k] ".") ||
          derived_use(line, "${" vars[k] "}.") ||
          index(line, "${" vars[k] "%") > 0 ||
          index(line, "${" vars[k] "#") > 0) {
        printf "[tempfile-lifecycle] %s:%d: mktemp-derived-path — a path derived from $%s loses mktemp's O_CREAT|O_EXCL guarantee; call mktemp again for the second handle\n", fname, start, vars[k]
        break
      }
    }

    # --- (2) pipefail-grep-q-stream ---
    if (pipefail != "1") continue
    masked = line
    gsub(/\|\|/, "\001", masked)
    if (!match(masked, /\|[[:space:]]*grep[[:space:]]+-[A-Za-z]*q/)) continue
    head = pipeline_head(substr(masked, 1, RSTART - 1))
    if (head == "" || head == "printf" || head == "echo") continue
    printf "[tempfile-lifecycle] %s:%d: pipefail-grep-q-stream — `grep -q` exits at the first match and `%s` then takes SIGPIPE, failing the pipeline under pipefail; use `grep -q PAT file` or count with `grep -c`\n", fname, start, head
  }
}
AWK

log "Scanning ${#TARGETS[@]} file(s)..."
for t in "${TARGETS[@]}"; do
  if [ ! -f "$t" ]; then
    echo "WARNING: target not found: $t" >&2
    continue
  fi
  # Pattern (2) is only a defect where pipefail turns the SIGPIPE into a failure.
  if grep -qE '^[[:space:]]*set[[:space:]]+-[a-zA-Z]*o[[:space:]]+pipefail|^[[:space:]]*set[[:space:]]+-o[[:space:]]+pipefail' "$t"; then
    pipefail_flag=1
  else
    pipefail_flag=0
  fi
  awk -v fname="$t" -v pipefail="$pipefail_flag" -f "$AWK_PROG" "$t" >> "$FINDINGS_FILE" 2>/dev/null || true
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

if [ "$total" -gt 0 ]; then
  exit 1
fi
exit 0
