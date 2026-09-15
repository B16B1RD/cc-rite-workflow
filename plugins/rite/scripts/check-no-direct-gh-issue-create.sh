#!/bin/bash
# check-no-direct-gh-issue-create.sh
# Static guard: ensure target files do not contain direct `gh issue create`
# invocations. All Issue creation paths (`/rite:issue-create` plus follow-up
# Issue creation in `pr/pr-review.md` / `pr/fix.md`) must go through
# `create-issue-with-projects.sh` so that Projects integration and field
# population are not silently dropped.
#
# The guard skips:
#   - Lines inside fenced code blocks (``` or ~~~)
#   - Blockquote lines (starting with `> ` or whitespace+`> `)
#   - Markdown comments (<!-- ... --> on a single line, or multi-line spans)
#   - Inline backtick spans (`...`) within otherwise-prose lines
#
# Usage:
#   check-no-direct-gh-issue-create.sh <file.md> [<file.md> ...]
#   check-no-direct-gh-issue-create.sh --all [--repo-root DIR]
#
#   --all expands to every `plugins/rite/skills/**/*.md` file under the
#   resolved repository root. Use this from /rite:lint Phase 3.5 (generic loop) to enforce
#   the guard across all command/sub-skill files in a single invocation.
#   Additional files can be appended after --all.
#
#   --repo-root DIR overrides the repository root resolution (default:
#   `git rev-parse --show-toplevel`, falling back to `pwd`). Sibling lint
#   scripts (plugins/rite/hooks/scripts/*-check.sh) use the same pattern.
#
# Exit codes:
#   0 - No violations
#   1 - One or more violations found (printed to stderr with file:line:content)
#   2 - Usage error (no arguments / file not found / --all expansion empty / invalid --repo-root)

set -euo pipefail

if [ $# -eq 0 ]; then
  echo "Usage: $0 [--all [--repo-root DIR] | <file.md> [<file.md> ...]]" >&2
  exit 2
fi

REPO_ROOT=""
if [ "$1" = "--all" ]; then
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo-root)
        shift
        if [ $# -eq 0 ]; then
          echo "ERROR: --repo-root requires a directory argument" >&2
          exit 2
        fi
        REPO_ROOT="$1"
        shift
        ;;
      *)
        break
        ;;
    esac
  done
  if [ -z "$REPO_ROOT" ]; then
    REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  fi
  if [ ! -d "$REPO_ROOT" ]; then
    echo "ERROR: --all mode: repository root not found: $REPO_ROOT" >&2
    echo "  Likely cause: invoked outside the rite plugin repo (e.g. marketplace install)" >&2
    echo "  Recovery: run from the rite plugin source tree, or pass --repo-root DIR explicitly" >&2
    exit 2
  fi
  SKILLS_DIR="$REPO_ROOT/plugins/rite/skills"
  if [ ! -d "$SKILLS_DIR" ]; then
    echo "ERROR: --all mode: skills directory not found: $SKILLS_DIR" >&2
    echo "  Likely cause: invoked outside the rite plugin repo (e.g. marketplace install)" >&2
    echo "  Recovery: run from the rite plugin source tree, or pass --repo-root DIR explicitly" >&2
    exit 2
  fi
  mapfile -t auto_files < <(find "$SKILLS_DIR" -type f -name '*.md' | sort)
  if [ ${#auto_files[@]} -eq 0 ]; then
    echo "ERROR: --all mode: no *.md files found under $SKILLS_DIR" >&2
    exit 2
  fi
  set -- "${auto_files[@]}" "$@"
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
    echo "VIOLATION: Direct 'gh issue create' invocation detected (Issue creation helper bypass):" >&2
    printf '%s\n' "$matches" >&2
    violations=$((violations + 1))
  fi
done

if [ "$violations" -gt 0 ]; then
  echo "" >&2
  echo "Total files with violations: $violations" >&2
  echo "All Issue creation must go through plugins/rite/scripts/create-issue-with-projects.sh." >&2
  echo "See 4.4 MUST NOT 1 for guidance." >&2
  exit 1
fi

exit 0
