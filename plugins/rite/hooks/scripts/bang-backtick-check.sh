#!/usr/bin/env bash
# bang-backtick-check.sh
#
# Detect bang-backtick adjacent patterns in plugins/rite/commands/**/*.md and
# plugins/rite/skills/**/*.md that can trigger Skill loader history expansion and
# break Skill loading (Issue #365 / PR #367 — backtick+bang adjacency in inline
# code caused /rite:pr:fix Skill load failure).
#
# Detected patterns (both are matched within a single Markdown inline code span,
# i.e. text enclosed by paired single backticks). **All occurrences on a single
# line are reported** — the scanner uses a while-match loop, so multiple triggers
# on the same line never silently collapse to one finding.
#
#   P1: closing-backtick-preceded-by-space-bang
#       regex: ` [^`]* !`
#       semantics: inline code where the character right before the closing
#                  backtick is literal "space + bang" (tab and other whitespace
#                  are NOT matched — this is the exact shape that broke fix.md
#                  in Issue #365).
#       Example that matches:    backtick-if-space-bang-backtick   (the #365 pattern)
#       Example that does NOT:   backtick-if-space-bang-space-cmd-backtick
#                                  (bang is not adjacent to closing backtick)
#
#   P2: opening-backtick-followed-by-bang
#       regex: `![alnum or single ASCII space]
#       semantics: inline code where the character right after the opening
#                  backtick is literal bang, followed by an alphanumeric or a
#                  single ASCII space (captures bash history-expansion shapes
#                  like "bang+word" while intentionally excluding the Markdown
#                  image-reference shape "bang+backslash-bracket").
#
# These patterns were chosen conservatively to produce zero false positives on
# the existing commands/skills tree (verified at creation time on 70 files).
# Innocent patterns such as Rustdoc inner doc `slash-slash-bang`, Markdown image
# `bang-bracket-alt-paren-url`, regex literal `bang-backslash-bracket`, and
# bash negation `if-space-bang-space-cmd` are intentionally NOT matched.
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
  --all              Scan plugins/rite/commands/**/*.md and plugins/rite/skills/**/*.md
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

# Resolve --all target list. Explicitly check that at least one of the scan
# directories exists so marketplace-install environments (where hooks/scripts
# lives in a different tree than the plugin commands/) get a clear diagnostic
# instead of the generic "no targets specified" fallback.
if [ "$USE_ALL" -eq 1 ]; then
  commands_dir="plugins/rite/commands"
  skills_dir="plugins/rite/skills"
  found_any_dir=0
  if [ -d "$commands_dir" ]; then
    found_any_dir=1
  else
    echo "WARNING: $commands_dir not found under $REPO_ROOT (skipped)" >&2
  fi
  if [ -d "$skills_dir" ]; then
    found_any_dir=1
  else
    echo "WARNING: $skills_dir not found under $REPO_ROOT (skipped)" >&2
  fi
  if [ "$found_any_dir" -eq 0 ]; then
    echo "ERROR: --all requested but neither $commands_dir nor $skills_dir exist under $REPO_ROOT" >&2
    echo "  Likely cause: this script was invoked outside the rite plugin repo (e.g. marketplace install)" >&2
    echo "  Recovery: run from the rite plugin source tree, or pass --target FILE explicitly" >&2
    exit 2
  fi
  while IFS= read -r f; do
    TARGETS+=("$f")
  done < <(find "$commands_dir" "$skills_dir" -type f -name '*.md' 2>/dev/null | sort)
fi

if [ "${#TARGETS[@]}" -eq 0 ]; then
  echo "ERROR: no targets specified (use --all or --target FILE)" >&2
  usage >&2
  exit 2
fi

FINDINGS_FILE="$(mktemp)" || { echo "ERROR: mktemp failed" >&2; exit 2; }
trap 'rm -f "$FINDINGS_FILE"' EXIT

# ----- Scan one file for both patterns ---------------------------------------
#
# Uses awk's `while (match(...))` idiom so that multiple triggers on a single
# line are all reported (fixes per-line undercounting bug — Issue #369 code-quality
# H-1). Each P1/P2 occurrence emits a dedicated finding line, eliminating the
# post-processing case dispatch the previous revision needed. Append directly
# to FINDINGS_FILE so the outer loop can count and print at the end.
check_file() {
  local file="$1"
  [ -f "$file" ] || return 0
  awk -v F="$file" '
    {
      line = $0
      # P1: space+! immediately before a closing backtick inside inline code.
      # Loop with substr/match to capture every occurrence on the same line.
      pos = 1
      while (pos <= length(line)) {
        sub_s = substr(line, pos)
        if (!match(sub_s, /`[^`]* !`/)) break
        print "[bang-backtick][P1] " F ":" NR ": closing backtick preceded by space+!"
        pos = pos + RSTART + RLENGTH - 1
      }
      # P2: opening backtick immediately followed by ! + alnum/space.
      # Same multi-match loop.
      pos = 1
      while (pos <= length(line)) {
        sub_s = substr(line, pos)
        if (!match(sub_s, /`![[:alnum:] ]/)) break
        print "[bang-backtick][P2] " F ":" NR ": opening backtick followed by ! + word/space"
        pos = pos + RSTART + RLENGTH - 1
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
log "==> Total bang-backtick findings: ${total}"

if [ "$total" -gt 0 ]; then
  exit 1
fi
exit 0
