#!/usr/bin/env bash
# comment-line-ref-check.sh
#
# Detect hardcoded `<file>.<ext>:<NN>` line-number references that live
# **inside shell comments** under plugins/rite/**/*.sh. Companion to
# hardcoded-line-number-check.sh (which targets prose in plugins/rite/
# commands/**/*.md).
#
# Why a separate hook (Issue #702):
#   hardcoded-line-number-check.sh's P-C pattern catches `foo.md:N` in
#   markdown prose only. Code-tree comments (`# wiki-config.sh:42` inside a
#   .sh file) drift the same way but are out of that hook's scope. This
#   script closes the gap for shell scripts and supports a wider extension
#   set so cross-language comment references are also caught.
#
# Detected pattern:
#   regex:    [A-Za-z][A-Za-z0-9_.-]*\.(sh|md|ts|py|js|tsx):[0-9]+
#   semantics: a filename + extension + ":N" reference inside a shell
#              comment line (line starts with optional whitespace then `#`,
#              and the `#` is NOT a shebang).
#
# Why "comment lines only":
#   Code lines reference filenames legitimately (e.g. `source ./foo.sh`,
#   `cat lib.sh:test`-like patterns). Restricting the scan to lines whose
#   first non-whitespace character is `#` (and not a shebang) avoids those
#   false positives. The state machine also skips fenced code blocks when
#   the heredoc-bearing comment block looks markdown-ish — see in_code below.
#
# Exclusions:
#   - Shebang lines (`^#!`)
#   - Lines inside a heredoc-style fenced code block (` ``` ` or `~~~` toggle)
#   - Range form `:N-M` (review-finding location, e.g. `Location: foo.sh:12-20`)
#   - Backtick-quoted spans on the same line (best-effort, single-line scan;
#     mirrors hardcoded-line-number-check.sh's in_backticks helper)
#   - Whitelist markers: `# example:`, `<!-- example: ... -->`, `// example:`
#   - Self-exclusion: this script's own header comments and regex literal
#
# Usage:
#   comment-line-ref-check.sh [--all] [--target FILE]... [--repo-root DIR] [--quiet]
#
# Exit codes: 0 = clean, 1 = pattern detected, 2 = invocation error.

set -euo pipefail

REPO_ROOT=""
QUIET=0
declare -a TARGETS=()
USE_ALL=0

usage() {
  cat <<'EOF'
Usage: comment-line-ref-check.sh [options]

Options:
  --all              Scan plugins/rite/**/*.sh
  --target FILE      Check FILE (repeatable). Path relative to repo root.
  --repo-root DIR    Repository root (default: git rev-parse --show-toplevel)
  --quiet            Suppress progress/summary output on stderr
  -h, --help         Show this help

Detected pattern (in shell comments only):
  [A-Za-z][A-Za-z0-9_.-]*\.(sh|md|ts|py|js|tsx):[0-9]+

Exclusions:
  Shebang / fenced code blocks / range :N-M / backtick-quoted spans /
  whitelist markers (# example:, <!-- example: -->, // example:) / self.

Exit codes:
  0  No comment line-number references detected
  1  Pattern detected
  2  Invocation error
EOF
}

log() { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*" >&2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --all) USE_ALL=1; shift ;;
    --target) TARGETS+=("$2"); shift 2 ;;
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
  base="plugins/rite"
  if [ ! -d "$base" ]; then
    echo "ERROR: --all requested but $base does not exist under $REPO_ROOT" >&2
    echo "  Likely cause: invoked outside the rite plugin repo (e.g. marketplace install)" >&2
    echo "  Recovery: run from the rite plugin source tree, or pass --target FILE explicitly" >&2
    exit 2
  fi
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
  done < <(find "$base" -type f -name '*.sh' 2>/dev/null | sort)
fi

if [ "${#TARGETS[@]}" -eq 0 ]; then
  echo "ERROR: no targets specified (use --all or --target FILE)" >&2
  usage >&2
  exit 2
fi

FINDINGS_FILE=""
_rite_comment_lineref_cleanup() {
  rm -f "${FINDINGS_FILE:-}"
}
trap 'rc=$?; _rite_comment_lineref_cleanup; exit $rc' EXIT
trap '_rite_comment_lineref_cleanup; exit 130' INT
trap '_rite_comment_lineref_cleanup; exit 143' TERM
trap '_rite_comment_lineref_cleanup; exit 129' HUP

FINDINGS_FILE="$(mktemp)" || { echo "ERROR: mktemp failed" >&2; exit 2; }

# State-machine awk: tracks fenced-code-block context and identifies whether
# the current line is a shell comment (first non-space char is `#`, but not a
# shebang `#!`). Pattern matches inside backticks are skipped via the same
# in_backticks helper used by hardcoded-line-number-check.sh.
check_file() {
  local file="$1"
  if [ ! -f "$file" ]; then
    echo "WARNING: target not found: $file" >&2
    return 0
  fi
  awk -v F="$file" '
    BEGIN { in_code = 0 }

    # Toggle fenced-code-block state for embedded markdown-style heredocs.
    /^[[:space:]]*(```|~~~)/ { in_code = !in_code; next }
    in_code { next }

    # Whitelist: skip lines carrying any "example:" marker outright.
    /(<!--[[:space:]]*example:|#[[:space:]]+example:|\/\/[[:space:]]+example:)/ { next }

    function in_backticks(line, start_pos,    i, count, c) {
      count = 0
      for (i = 1; i < start_pos; i++) {
        c = substr(line, i, 1)
        if (c == "`") count++
      }
      return (count % 2 == 1)
    }

    # Determine "is this a shell comment line?". A comment line:
    #   1. Optional leading whitespace, then `#`.
    #   2. The `#` is NOT followed by `!` (shebang exclusion on the very
    #      first significant char).
    function is_comment_line(line,    s) {
      # Strip leading whitespace.
      sub(/^[[:space:]]+/, "", line)
      if (substr(line, 1, 1) != "#") return 0
      if (substr(line, 1, 2) == "#!") return 0
      return 1
    }

    {
      line = $0
      if (!is_comment_line(line)) next

      pos = 1
      while (pos <= length(line)) {
        rest = substr(line, pos)
        if (!match(rest, /[A-Za-z][A-Za-z0-9_.-]*\.(sh|md|ts|py|js|tsx):[0-9]+/)) break
        hit = substr(rest, RSTART, RLENGTH)
        abs_start = pos + RSTART - 1

        tail_idx = abs_start + RLENGTH
        tail_c1 = substr(line, tail_idx, 1)
        tail_c2 = substr(line, tail_idx + 1, 1)
        is_range = (tail_c1 == "-" && tail_c2 ~ /[0-9]/)

        prev_c = (abs_start > 1) ? substr(line, abs_start - 1, 1) : ""
        is_continuation = (prev_c ~ /[A-Za-z0-9_]/)

        if (!is_range && !is_continuation && !in_backticks(line, abs_start)) {
          print "[comment-line-ref] " F ":" NR ": comment line-number reference: " hit
        }
        pos = abs_start + RLENGTH
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
log "==> Total comment-line-ref findings: ${total}"

if [ "$total" -gt 0 ]; then
  exit 1
fi
exit 0
