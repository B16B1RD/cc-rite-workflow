#!/usr/bin/env bash
# bang-backtick-check.sh
#
# Detect bang-backtick adjacent patterns in commands/**/*.md and skills/**/*.md
# that can trigger Skill loader history expansion and break Skill loading
# (Issue #365 / PR #367 — `if !` pattern caused /rite:pr:fix Skill load failure).
#
# Detected patterns (both must be inline code, i.e. enclosed in single backticks):
#   P1: closing-backtick-preceded-by-space-bang  — regex: ` [^`]* !`
#       Example: `if !`  (the Issue #365 triggering pattern)
#   P2: opening-backtick-followed-by-bang        — regex: `![alnum/space]
#       Example: `!foo`, `! cmd`
#
# These patterns were chosen conservatively to produce zero false positives
# on the existing commands/skills tree (verified at creation time).
# Innocent patterns like `//!` (Rustdoc), `![...](...)` (Markdown image), and
# `!\[...\]` (regex literals) are NOT matched.
#
# Usage:
#   bang-backtick-check.sh [--all] [--target FILE]... [--repo-root DIR] [--quiet]
#
# Exit codes: 0 = clean, 1 = pattern detected, 2 = invocation error.

set -uo pipefail

REPO_ROOT=""
QUIET=0
declare -a TARGETS=()
USE_ALL=0

usage() {
  cat <<'EOF'
Usage: bang-backtick-check.sh [options]

Options:
  --all              Scan commands/**/*.md and skills/**/*.md under plugins/rite
  --target FILE      Check FILE (repeatable). Path relative to repo root.
  --repo-root DIR    Repository root (default: git rev-parse --show-toplevel)
  --quiet            Suppress per-finding output (still exit non-zero on detection)
  -h, --help         Show this help

Exit codes:
  0  No bang-backtick adjacency detected
  1  Pattern detected
  2  Invocation error (bad args, missing files)
EOF
}

log() { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*" >&2; }
out() { printf '%s\n' "$*"; }

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
  while IFS= read -r f; do
    TARGETS+=("$f")
  done < <(find plugins/rite/commands plugins/rite/skills -type f -name '*.md' 2>/dev/null | sort)
fi

if [ "${#TARGETS[@]}" -eq 0 ]; then
  echo "ERROR: no targets specified (use --all or --target FILE)" >&2
  usage >&2
  exit 2
fi

FINDING_COUNT_FILE="$(mktemp)" || { echo "ERROR: mktemp failed" >&2; exit 2; }
trap 'rm -f "$FINDING_COUNT_FILE"' EXIT
echo 0 > "$FINDING_COUNT_FILE"

report() {
  # report PATTERN FILE LINE MESSAGE
  local pattern="$1" file="$2" line="$3" msg="$4"
  out "[bang-backtick][P${pattern}] ${file}:${line}: ${msg}"
  local n
  n=$(<"$FINDING_COUNT_FILE")
  echo $((n + 1)) > "$FINDING_COUNT_FILE"
}

# ----- Scan one file for both patterns ---------------------------------------
check_file() {
  local file="$1"
  [ -f "$file" ] || return 0
  # P1: ` [^`]* !`  — inline code whose last char is `!` preceded by a space
  # P2: `!          — inline code whose first char after the opening backtick is `!`
  #                   followed by alnum or space (avoids `!\[` regex literals)
  awk -v F="$file" '
    {
      line_no = NR
      line = $0
      # Pattern 1: space+! immediately before closing backtick inside inline code
      # Match: `...space!`  (must be preceded by opening backtick)
      if (match(line, /`[^`]* !`/)) {
        print "P1|" line_no "|closing backtick preceded by space+!"
      }
      # Pattern 2: opening backtick immediately followed by ! (then alnum or space)
      # `!foo` / `! cmd` are matched; `!\[...\]` is NOT (next char is backslash)
      if (match(line, /`![[:alnum:] ]/)) {
        print "P2|" line_no "|opening backtick followed by ! + word/space"
      }
    }
  ' "$file" | while IFS='|' read -r pat ln msg; do
    [ -z "$pat" ] && continue
    case "$pat" in
      P1) report 1 "$file" "$ln" "$msg" ;;
      P2) report 2 "$file" "$ln" "$msg" ;;
    esac
  done
}

log "Scanning ${#TARGETS[@]} file(s)..."
for t in "${TARGETS[@]}"; do
  check_file "$t"
done

total=$(<"$FINDING_COUNT_FILE")
log "==> Total bang-backtick findings: ${total}"

if [ "$total" -gt 0 ]; then
  exit 1
fi
exit 0
