#!/usr/bin/env bash
# skill-rail-diff-check.sh
#
# Verify that a skill's "machine rail" is byte-identical between the working
# tree and a base ref. The machine rail is the part of a SKILL.md that other
# code string-matches against or that the model executes verbatim: fenced
# blocks (fence lines included) and markdown table rows, at any indentation.
# Everything else — headings, prose, blank lines — is the prose layer that a
# description diet is allowed to rewrite.
#
# The rail is NOT the whole contract. Headings, outcome statements, and short
# mandates also carry meaning that other skills depend on, and this checker
# cannot see them. plugins/rite/references/skill-diet-method.md §1 splits the
# checklist into what this script verifies and what a human must still read.
#
# Usage:
#   skill-rail-diff-check.sh --skill PATH [--base-ref REF] [--repo-root DIR]
#   skill-rail-diff-check.sh --skill PATH --extract-only
#
# Exit codes:
#   0  Rails identical, or not applicable (the file does not exist at an
#      otherwise-resolvable base ref — e.g. a newly added skill)
#   1  Rail drift detected
#   2  Invocation error (missing/empty/unreadable --skill, unresolvable
#      --base-ref, empty rail, bad args)

# `-e` intentionally omitted: `git show` on an absent path and `diff` on
# differing input both return non-zero by design, and each is routed by its own
# exit-code branch below — same rationale as sentinel-contract-check.sh.
set -uo pipefail

SKILL_PATH=""
BASE_REF="origin/develop"
REPO_ROOT=""
EXTRACT_ONLY=0

usage() {
  cat <<'EOF'
Usage: skill-rail-diff-check.sh --skill PATH [options]

Options:
  --skill PATH       Skill markdown to check (required), relative to repo root
                     or absolute.
  --base-ref REF     Ref to compare against (default: origin/develop). Must
                     resolve to a commit.
  --repo-root DIR    Repository root (default: git rev-parse --show-toplevel).
  --extract-only     Print the extracted machine rail to stdout and exit 0.
                     Useful for recording a before/after measurement.
  -h, --help         Show this help.
EOF
}

# `shift; shift` rather than `shift 2`: with `set -e` absent, a `shift 2` on a
# trailing valueless flag fails silently and the loop spins forever. The repo
# pins this shape in hooks/tests/shift2-loop-hardening.test.sh.
while [ $# -gt 0 ]; do
  case "$1" in
    --skill) SKILL_PATH="${2:-}"; shift; shift ;;
    --base-ref) BASE_REF="${2:-}"; shift; shift ;;
    --repo-root) REPO_ROOT="${2:-}"; shift; shift ;;
    --extract-only) EXTRACT_ONLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# Empty values are rejected rather than defaulted. An empty --base-ref would
# make `git show ":path"` read the index, which succeeds and compares the
# working tree against the caller's own staged copy — a proof that always
# passes. An empty --repo-root would silently fall back to the caller's cwd.
if [ -z "$SKILL_PATH" ]; then
  echo "ERROR: --skill is required and must not be empty" >&2
  usage >&2
  exit 2
fi
if [ -z "$BASE_REF" ]; then
  echo "ERROR: --base-ref must not be empty" >&2
  exit 2
fi

if [ -z "$REPO_ROOT" ]; then
  REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || REPO_ROOT=""
fi
if [ -z "$REPO_ROOT" ]; then
  echo "ERROR: could not resolve repo root; pass --repo-root" >&2
  exit 2
fi

# Normalize to a repo-relative path so `git show REF:path` works regardless of
# whether the caller passed an absolute or relative --skill.
case "$SKILL_PATH" in
  "$REPO_ROOT"/*) REL_PATH="${SKILL_PATH#"$REPO_ROOT"/}" ;;
  /*) echo "ERROR: --skill is outside --repo-root: $SKILL_PATH" >&2; exit 2 ;;
  *) REL_PATH="$SKILL_PATH" ;;
esac

ABS_PATH="$REPO_ROOT/$REL_PATH"
if [ ! -r "$ABS_PATH" ]; then
  echo "ERROR: --skill not readable: $ABS_PATH" >&2
  exit 2
fi

# Machine rail = fenced blocks (fence lines included) + markdown table rows, at
# any indentation. rite skills put both under numbered list items, so anchoring
# at column 0 would drop most of the rail in iterate / fix / pr-review. The
# fence pattern matches bash-heaviness-check.sh, which scans the same files.
#
# Line numbers are deliberately omitted: the diet removes prose lines, so every
# rail line shifts. Only the rail's content and order are the contract.
extract_rail() {
  awk '
    /^[[:space:]]*(```|~~~)/ { inb = !inb; print; next }
    inb { print; next }
    /^[[:space:]]*\|/ { print }
  '
}

# Count lines without `wc -l`, which reports 1 for an empty string and so
# cannot express "the rail is empty".
count_lines() {
  awk 'END { print NR }'
}

if [ "$EXTRACT_ONLY" -eq 1 ]; then
  extract_rail < "$ABS_PATH"
  exit 0
fi

# Resolve the base ref before reading the blob. Without this, a typo'd or
# un-fetched ref falls into the "absent at base ref" branch below and reports
# success for a comparison that never happened.
if ! git -C "$REPO_ROOT" rev-parse --verify -q "$BASE_REF^{commit}" >/dev/null 2>&1; then
  echo "ERROR: --base-ref does not resolve to a commit: $BASE_REF" >&2
  echo "  Fetch it first (git fetch origin) or pass a ref that exists." >&2
  exit 2
fi

if ! base_blob=$(git -C "$REPO_ROOT" show "$BASE_REF:$REL_PATH" 2>/dev/null); then
  echo "[skill-rail-diff] not applicable: $REL_PATH absent at $BASE_REF (new skill) — clean skip" >&2
  exit 0
fi

base_rail=$(printf '%s\n' "$base_blob" | extract_rail)
head_rail=$(extract_rail < "$ABS_PATH")
head_rail_lines=$(printf '%s' "$head_rail" | count_lines)

# An empty rail on both sides compares equal, so without this guard a broken
# extractor — or a file that has no rail at all — would report the same success
# as a real 305-line match.
if [ "$head_rail_lines" -eq 0 ]; then
  echo "ERROR: $REL_PATH yielded an empty machine rail — nothing was proven" >&2
  echo "  Either the file has no fenced blocks or table rows, or extraction broke." >&2
  exit 2
fi

if [ "$base_rail" = "$head_rail" ]; then
  echo "[skill-rail-diff] $REL_PATH: machine rail identical to $BASE_REF ($head_rail_lines rail lines)" >&2
  exit 0
fi

echo "[skill-rail-diff] DRIFT: $REL_PATH machine rail differs from $BASE_REF" >&2
echo "  A description diet must not alter fenced blocks or table rows." >&2
echo "  If the change is intentional, it belongs in its own commit with a rationale." >&2
echo "--- rail diff ($BASE_REF -> working tree) ---" >&2
diff <(printf '%s\n' "$base_rail") <(printf '%s\n' "$head_rail") >&2
exit 1
