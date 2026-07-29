#!/usr/bin/env bash
# fix-reason-coverage-check.sh
#
# Verify that every `WM_UPDATE_FAILED=1; reason=<value>` emitted in
# skills/fix/SKILL.md also appears as a row in that file's reason table.
#
# The table is what a reader consults to interpret a `[fix:pushed-wm-stale]`
# outcome. A reason emitted by the flow but missing from the table leaves that
# outcome unexplained at exactly the moment someone is debugging it, so the
# completeness claim in fix.md needs a runnable check rather than a promise.
#
# Direction is one-way by design: emitted reasons must be a subset of the table.
# The table is a superset — it documents reasons for other flags too — so a row
# without a matching emit is not a finding.
#
# Why this lives in a real file instead of the skill body
# ------------------------------------------------------
# The Skill loader rewrites positional-parameter references in a skill body to
# the invocation argument string — inside fenced code blocks too. An awk program
# that inspects the current record therefore arrives corrupted, and the failure
# is silent. Real script files are never passed through the loader. See
# hooks/scripts/dollar-zero-check.sh for the static check that keeps skill
# bodies free of the pattern.
#
# Usage:
#   fix-reason-coverage-check.sh [--repo-root DIR] [--target FILE]
#
# Output: reasons that are emitted but absent from the table, one per line.
#         Empty output means full coverage.
# Exit codes: 0 = every emitted reason is documented, 1 = one or more missing,
#             2 = invocation error.

set -uo pipefail

REPO_ROOT=""
TARGET="plugins/rite/skills/fix/SKILL.md"

usage() {
  cat <<'EOF'
Usage: fix-reason-coverage-check.sh [options]

Options:
  --repo-root DIR    Repository root (default: git rev-parse --show-toplevel)
  --target FILE      File to check, relative to repo root
                     (default: plugins/rite/skills/fix/SKILL.md)
  -h, --help         Show this help

Exit codes:
  0  Every emitted WM_UPDATE_FAILED reason appears in the reason table
  1  One or more emitted reasons are missing from the table (listed on stdout)
  2  Invocation error (bad args, missing file)
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --repo-root) REPO_ROOT="$2"; shift 2 ;;
    --target) TARGET="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ -z "$REPO_ROOT" ]; then
  REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
fi
cd "$REPO_ROOT" || { echo "ERROR: cannot cd to $REPO_ROOT" >&2; exit 2; }

if [ ! -f "$TARGET" ]; then
  echo "ERROR: target not found: $TARGET (repo root: $REPO_ROOT)" >&2
  exit 2
fi

emitted=$(grep -oE 'WM_UPDATE_FAILED=1; reason=[a-z_][a-z_0-9]*' "$TARGET" \
  | sed 's/.*reason=//' | sort -u)

# Table rows start at the `| reason | 発生...` header and end at the first line
# that does not open with a pipe. The trailing `sed` drops shell-interpolated
# suffixes so a cell written as a variable reference still matches its literal.
documented=$(awk '
  /^\| reason \| 発生/ { in_table=1; next }
  in_table && /^[^|]/ { in_table=0 }
  in_table && /^\| `[a-z_]/ {
    match($0, /`[a-z_][a-z_0-9]*[^`]*`/)
    print substr($0, RSTART + 1, RLENGTH - 2)
  }
' "$TARGET" | sed 's/\$.*//' | sort -u)

missing=$(comm -23 <(printf '%s\n' "$emitted") <(printf '%s\n' "$documented"))

if [ -n "$missing" ]; then
  printf '%s\n' "$missing"
  exit 1
fi
exit 0
