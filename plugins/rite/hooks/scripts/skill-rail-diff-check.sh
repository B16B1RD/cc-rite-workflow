#!/usr/bin/env bash
# skill-rail-diff-check.sh
#
# Verify that a skill's "machine rail" is byte-identical between the working
# tree and a base ref. The machine rail is the part of a SKILL.md that other
# code string-matches against or that the model executes verbatim: fenced
# blocks (fence lines included) and markdown table rows. Everything else —
# headings, prose, blank lines — is the prose layer that a description diet
# is allowed to rewrite.
#
# The diet method (plugins/rite/references/skill-diet-method.md) requires each
# diet PR to prove it changed only the prose layer. This checker is that proof:
# run it against the diet target and a non-zero exit means a bash block,
# sentinel literal, or branch-table row moved.
#
# Usage:
#   skill-rail-diff-check.sh --skill PATH [--base-ref REF] [--repo-root DIR] [--quiet]
#   skill-rail-diff-check.sh --skill PATH --extract-only
#
# Exit codes:
#   0  Rails identical, or not applicable (base ref unresolvable / file absent
#      at base ref — e.g. a newly added skill, or a marketplace checkout with
#      no remote-tracking branch)
#   1  Rail drift detected
#   2  Invocation error (missing/unreadable --skill, bad args)

# `-e` intentionally omitted: `git show` on an absent path and `diff` on
# differing input both return non-zero by design, and each is routed by its own
# exit-code branch below — same rationale as sentinel-contract-check.sh.
set -uo pipefail

SKILL_PATH=""
BASE_REF="origin/develop"
REPO_ROOT=""
QUIET=0
EXTRACT_ONLY=0

usage() {
  cat <<'EOF'
Usage: skill-rail-diff-check.sh --skill PATH [options]

Options:
  --skill PATH       Skill markdown to check (required), relative to repo root
                     or absolute.
  --base-ref REF     Ref to compare against (default: origin/develop).
  --repo-root DIR    Repository root (default: git rev-parse --show-toplevel).
  --extract-only     Print the extracted machine rail to stdout and exit 0.
                     Useful for recording a before/after measurement.
  --quiet            Suppress the per-hunk drift report; only set the exit code.
  -h, --help         Show this help.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --skill) SKILL_PATH="${2:-}"; shift 2 ;;
    --base-ref) BASE_REF="${2:-}"; shift 2 ;;
    --repo-root) REPO_ROOT="${2:-}"; shift 2 ;;
    --extract-only) EXTRACT_ONLY=1; shift ;;
    --quiet) QUIET=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ -z "$SKILL_PATH" ]; then
  echo "ERROR: --skill is required" >&2
  usage >&2
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

# Machine rail = fenced blocks (fence lines included) + markdown table rows.
# Line numbers are deliberately omitted: the diet removes prose lines, so every
# rail line shifts. Only the rail's content and order are the contract.
extract_rail() {
  awk '
    /^```/ { inb = !inb; print; next }
    inb { print; next }
    /^\|/ { print }
  '
}

if [ "$EXTRACT_ONLY" -eq 1 ]; then
  extract_rail < "$ABS_PATH"
  exit 0
fi

base_blob=$(git -C "$REPO_ROOT" show "$BASE_REF:$REL_PATH" 2>/dev/null)
base_rc=$?
if [ "$base_rc" -ne 0 ]; then
  [ "$QUIET" -eq 1 ] || echo "[skill-rail-diff] not applicable: $REL_PATH absent at $BASE_REF (new skill, or ref unavailable) — clean skip" >&2
  exit 0
fi

base_rail=$(printf '%s\n' "$base_blob" | extract_rail)
head_rail=$(extract_rail < "$ABS_PATH")

if [ "$base_rail" = "$head_rail" ]; then
  [ "$QUIET" -eq 1 ] || echo "[skill-rail-diff] $REL_PATH: machine rail identical to $BASE_REF ($(printf '%s\n' "$head_rail" | wc -l) rail lines)"
  exit 0
fi

if [ "$QUIET" -eq 0 ]; then
  echo "[skill-rail-diff] DRIFT: $REL_PATH machine rail differs from $BASE_REF" >&2
  echo "  A description diet must not alter fenced blocks or table rows." >&2
  echo "  If the change is intentional, it belongs in its own commit with a rationale." >&2
  echo "--- rail diff ($BASE_REF -> working tree) ---" >&2
  diff <(printf '%s\n' "$base_rail") <(printf '%s\n' "$head_rail") >&2
fi
exit 1
