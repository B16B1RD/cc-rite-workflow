#!/usr/bin/env bash
# hardcoded-line-number-check.sh
#
# Detect hardcoded line-number references in rite-workflow procedural
# markdown files (commands/**/*.md). Complements distributed-fix-drift-check.sh
# by catching prose-level references that drift when content is added or
# removed but the references are not updated in lockstep.
#
# Motivated by PR #661 cycle 2/3 incident (Issue #666):
#   Cycle 2 propagation scan was limited to the `(line N, M)` form, so
#   create-interview.md:605 prose form drifts (`本セクション直前の line 588 / 597`,
#   `create.md:580 / create-interview.md:22`) escaped detection until cycle 3.
#
# Detected patterns:
#   P-A  Parenthesized form              `(line N)` / `(line N, M)` / `(line N, M, K)`
#   P-B  Japanese prose form             qualifier (直前/直後/上記/下記/上方/下方/本セクション)
#                                        within ~40 chars of `line N`
#   P-C  Cross-file `{file}.md:N` form   markdown filename + `:N` (single line, not range)
#
# Exclusions:
#   - Lines inside fenced code blocks (```...```)
#   - Range form `:N-M` (review finding location, e.g. `docs/overview.md:12-20`)
#   - Lines starting with `Location:` (canonical review finding marker)
#   - Lines whose match lies inside a backtick-quoted span on the same line
#     (best-effort, single-line scan)
#   - Self-exclusion: this script's own header comments and regex literals
#
# Usage:
#   hardcoded-line-number-check.sh [--all] [--target FILE]... [--pattern A|B|C]
#                                  [--repo-root DIR] [--quiet]
#
# Exit codes:
#   0  No drift detected
#   1  Drift detected
#   2  Invocation error (bad args, missing files)

set -euo pipefail

REPO_ROOT=""
QUIET=0
PATTERN_FILTER=""
declare -a TARGETS=()
USE_ALL=0

usage() {
  cat <<'EOF'
Usage: hardcoded-line-number-check.sh [options]

Options:
  --all              Scan plugins/rite/commands/**/*.md
  --target FILE      Check FILE (repeatable). Path relative to repo root.
  --pattern X        Only run pattern X (A, B, or C). Default: all patterns.
  --repo-root DIR    Repository root (default: git rev-parse --show-toplevel)
  --quiet            Suppress progress/summary output on stderr
  -h, --help         Show this help

Detected patterns:
  P-A  Parenthesized: (line N) / (line N, M)
  P-B  Japanese prose: 直前/直後/上記/下記/上方/下方/本セクション near `line N`
  P-C  Cross-file: foo.md:N (single line, not range)

Exit codes:
  0  No drift detected
  1  Drift detected
  2  Invocation error
EOF
}

log() { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*" >&2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --all) USE_ALL=1; shift ;;
    --target) TARGETS+=("$2"); shift 2 ;;
    --pattern) PATTERN_FILTER="$2"; shift 2 ;;
    --repo-root) REPO_ROOT="$2"; shift 2 ;;
    --quiet) QUIET=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ -z "$REPO_ROOT" ]; then
  REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
fi
cd "$REPO_ROOT" || { echo "ERROR: cannot cd to $REPO_ROOT" >&2; exit 2; }

if [ "$USE_ALL" -eq 1 ]; then
  commands_dir="plugins/rite/commands"
  if [ ! -d "$commands_dir" ]; then
    echo "ERROR: --all requested but $commands_dir does not exist under $REPO_ROOT" >&2
    echo "  Likely cause: invoked outside the rite plugin repo (e.g. marketplace install)" >&2
    echo "  Recovery: run from the rite plugin source tree, or pass --target FILE explicitly" >&2
    exit 2
  fi
  # Self-exclusion: this script's own regex literals would match itself.
  self_abs="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")"
  self_rel=""
  case "$self_abs" in
    "$REPO_ROOT"/*) self_rel="${self_abs#"$REPO_ROOT"/}" ;;
  esac
  while IFS= read -r f; do
    if [ -n "$self_rel" ] && [ "$f" = "$self_rel" ]; then
      continue
    fi
    TARGETS+=("$f")
  done < <(find "$commands_dir" -type f -name '*.md' 2>/dev/null | sort)
fi

if [ "${#TARGETS[@]}" -eq 0 ]; then
  echo "ERROR: no targets specified (use --all or --target FILE)" >&2
  usage >&2
  exit 2
fi

# trap + cleanup pattern (signal-specific, INT/TERM/HUP coverage)
# Reference: plugins/rite/commands/pr/references/bash-trap-patterns.md#signal-specific-trap-template
FINDINGS_FILE=""
_rite_hardcoded_line_cleanup() {
  rm -f "${FINDINGS_FILE:-}"
}
trap 'rc=$?; _rite_hardcoded_line_cleanup; exit $rc' EXIT
trap '_rite_hardcoded_line_cleanup; exit 130' INT
trap '_rite_hardcoded_line_cleanup; exit 143' TERM
trap '_rite_hardcoded_line_cleanup; exit 129' HUP

FINDINGS_FILE="$(mktemp)" || { echo "ERROR: mktemp failed" >&2; exit 2; }

run_pattern() {
  local p="$1"
  [ -z "$PATTERN_FILTER" ] || [ "$PATTERN_FILTER" = "$p" ]
}

# Single awk pass that maintains a fenced-code-block state machine and emits
# findings for the requested patterns. The same awk runs for all 3 patterns
# but each emit is gated by an env var so the caller can filter.
check_file() {
  local file="$1"
  if [ ! -f "$file" ]; then
    echo "WARNING: target not found: $file" >&2
    return 0
  fi
  local run_a=0 run_b=0 run_c=0
  # `set -e` 環境下では `run_pattern A && run_a=1` 単独だと no-match (exit 1) で script が
  # 強制終了する。`|| true` で no-match を許容する (run_a=0 のままになる)
  run_pattern A && run_a=1 || true
  run_pattern B && run_b=1 || true
  run_pattern C && run_c=1 || true
  awk -v F="$file" -v RUN_A="$run_a" -v RUN_B="$run_b" -v RUN_C="$run_c" '
    BEGIN { in_code = 0 }
    # Fenced code block detection: lines starting (after optional indent) with
    # ``` (backtick fence) or ~~~ (tilde fence). Both forms are valid CommonMark
    # / GFM fence syntax. Toggling on either form lets the same in_code state
    # cover both fence styles.
    /^[[:space:]]*(```|~~~)/ { in_code = !in_code; next }
    in_code { next }

    # Helper: check whether a match span (start_pos..end_pos in current line)
    # is inside a backtick-quoted region. Counts backticks before start_pos.
    function in_backticks(line, start_pos,    i, count, c) {
      count = 0
      for (i = 1; i < start_pos; i++) {
        c = substr(line, i, 1)
        if (c == "`") count++
      }
      return (count % 2 == 1)
    }

    {
      line = $0
      # ---------- P-A: (line N) / (line N, M) parenthesized ----------
      if (RUN_A) {
        pos = 1
        while (pos <= length(line)) {
          rest = substr(line, pos)
          if (!match(rest, /\(line[[:space:]]+[0-9]+([[:space:]]*,[[:space:]]*[0-9]+)*\)/)) break
          hit = substr(rest, RSTART, RLENGTH)
          abs_start = pos + RSTART - 1
          if (!in_backticks(line, abs_start)) {
            print "[hardcoded-line-number][P-A] " F ":" NR ": parenthesized line reference: " hit
          }
          pos = abs_start + RLENGTH
        }
      }

      # ---------- P-B: Japanese prose qualifier near line N ----------
      if (RUN_B) {
        pos = 1
        while (pos <= length(line)) {
          rest = substr(line, pos)
          # qualifier (multi-byte; awk byte-level OK because we match by literal bytes)
          # 直前/直後/上記/下記/上方/下方/本セクション then up to 40 bytes of any non-newline,
          # then line + space(s) + digits
          if (!match(rest, /(直前|直後|上記|下記|上方|下方|本セクション)[^\n]{0,80}line[[:space:]]+[0-9]+/)) break
          hit = substr(rest, RSTART, RLENGTH)
          abs_start = pos + RSTART - 1
          if (!in_backticks(line, abs_start)) {
            print "[hardcoded-line-number][P-B] " F ":" NR ": prose-form line reference: " hit
          }
          pos = abs_start + RLENGTH
        }
      }

      # ---------- P-C: {file}.md:N cross-file reference ----------
      # Range form (`:N-M`) exclusion below covers Location: review-finding markers
      # (e.g. `Location: docs/overview.md:12-20`). No separate Location: prefix skip needed.
      # Character class allows mixed-case filenames so that `README.md:42` /
      # `CHANGELOG.md:10` / `CONTRIBUTING.md:5` etc. are also detected.
      if (RUN_C) {
        pos = 1
        while (pos <= length(line)) {
          rest = substr(line, pos)
          if (!match(rest, /[A-Za-z][A-Za-z0-9_.-]*\.md:[0-9]+/)) break
          hit = substr(rest, RSTART, RLENGTH)
          abs_start = pos + RSTART - 1
          # Range form exclusion: if the next char after match is "-" + digit,
          # this is a range like ":12-20" — skip.
          tail_idx = abs_start + RLENGTH  # 1-based index of char immediately after match
          tail_c1 = substr(line, tail_idx, 1)
          tail_c2 = substr(line, tail_idx + 1, 1)
          is_range = (tail_c1 == "-" && tail_c2 ~ /[0-9]/)
          # Word-boundary exclusion: if the char immediately before match start
          # is a letter/digit/underscore (e.g. `barFoo.md:42` → suffix `oo.md:42`),
          # this is a substring of a longer identifier — skip.
          prev_c = (abs_start > 1) ? substr(line, abs_start - 1, 1) : ""
          is_continuation = (prev_c ~ /[A-Za-z0-9_]/)
          if (!is_range && !is_continuation && !in_backticks(line, abs_start)) {
            print "[hardcoded-line-number][P-C] " F ":" NR ": cross-file line reference: " hit
          }
          pos = abs_start + RLENGTH
        }
      }
    }
  ' "$file" >> "$FINDINGS_FILE"
}

log "Scanning ${#TARGETS[@]} file(s)..."
for t in "${TARGETS[@]}"; do
  check_file "$t"
done

if [ -s "$FINDINGS_FILE" ]; then
  cat "$FINDINGS_FILE"
  total=$(wc -l < "$FINDINGS_FILE")
else
  total=0
fi
log "==> Total hardcoded line-number findings: ${total}"

if [ "$total" -gt 0 ]; then
  exit 1
fi
exit 0
