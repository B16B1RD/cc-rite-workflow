#!/bin/bash
# check-no-direct-gh-issue-create.sh (#669)
# Static guard: ensure target files do not contain direct `gh issue create`
# invocations. Enforces AC-3 — all Issue creation paths in /rite:issue:start
# (and parent-routing) must go through create-issue-with-projects.sh.
#
# The guard skips:
#   - Lines inside fenced code blocks (``` or ~~~)
#   - Blockquote lines (starting with `> ` or whitespace+`> `)
#   - Markdown comments (<!-- ... --> on a single line, or multi-line spans)
#   - Inline backtick spans (`...`) within otherwise-prose lines
#
# Usage:
#   check-no-direct-gh-issue-create.sh <file.md> [<file.md> ...]
#
# Exit codes:
#   0 - No violations
#   1 - One or more violations found (printed to stderr with file:line:content)
#   2 - Usage error (no arguments / file not found)

set -euo pipefail

if [ $# -eq 0 ]; then
  echo "Usage: $0 <file.md> [<file.md> ...]" >&2
  exit 2
fi

violations=0
for file in "$@"; do
  if [ ! -f "$file" ]; then
    echo "ERROR: File not found: $file" >&2
    exit 2
  fi
  matches=$(awk '
    BEGIN { in_code = 0; in_comment = 0 }

    # Code fence toggles
    /^```/ || /^~~~/ { in_code = !in_code; next }
    in_code { next }

    # Blockquote: skip entire line (both narrative quotes and quoted code samples)
    /^[[:space:]]*>[[:space:]]/ { next }

    # Markdown comment: handle single-line and multi-line forms
    /<!--/ {
      if (/-->/) { next }   # single-line comment
      in_comment = 1
      next
    }
    in_comment {
      if (/-->/) { in_comment = 0 }
      next
    }

    # For the remaining narrative lines, strip inline backtick spans before
    # the pattern check so that prose using backticks does not false-positive.
    #
    # Detection pattern: literal `gh issue create ` followed by one of:
    #   - dash (option flag)
    #   - dollar (shell variable expansion)
    #   - double-quote (quoted argument)
    #   - single-quote (also quoted argument, encoded as octal 047)
    # This distinguishes real shell invocations from English prose where the
    # next word is a normal noun like "invocation" or "directly".
    {
      tmp = $0
      gsub(/`[^`]*`/, "", tmp)
      if (tmp ~ /gh issue create [-$"\047]/) {
        printf "%s:%d: %s\n", FILENAME, NR, $0
      }
    }
  ' "$file")
  if [ -n "$matches" ]; then
    echo "VIOLATION: Direct 'gh issue create' invocation detected (#669 AC-3 violation):" >&2
    printf '%s\n' "$matches" >&2
    violations=$((violations + 1))
  fi
done

if [ "$violations" -gt 0 ]; then
  echo "" >&2
  echo "Total files with violations: $violations" >&2
  echo "All Issue creation must go through plugins/rite/scripts/create-issue-with-projects.sh." >&2
  echo "See Issue #669 (AC-3 / 4.4 MUST NOT 1) for guidance." >&2
  exit 1
fi

exit 0
