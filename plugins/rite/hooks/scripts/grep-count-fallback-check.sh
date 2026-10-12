#!/usr/bin/env bash
# Detect `grep -c ... || echo 0` under plugins/rite (scripts, skills, tests).
#
# grep -c prints the count (0 included) and exits 1 on zero matches, so the
# `|| echo 0` branch fires on exactly the zero-match case and the substitution
# captures "0\n0". The doubled value breaks `[ "$n" -eq 0 ]` and any
# concatenated output. Use `|| true` and default the variable with `${n:-0}`.
# See references/bash-defensive-patterns.md (Pattern 2).
#
# Comment lines and markdown table rows are skipped (they describe the defect).
#
# Usage: grep-count-fallback-check.sh --all [--repo-root DIR] [--quiet] [--skip-if-no-target]
# Exit: 0 clean (or not-applicable skip), 1 findings, 2 invocation error.
set -uo pipefail

REPO_ROOT=""; QUIET=0; USE_ALL=0; SKIP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --all) USE_ALL=1; shift ;;
    --repo-root) REPO_ROOT="${2:-}"; shift 2 ;;
    --quiet) QUIET=1; shift ;;
    --skip-if-no-target) SKIP=1; shift ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ "$USE_ALL" -eq 1 ] || { echo "ERROR: --all is required" >&2; exit 2; }
[ -n "$REPO_ROOT" ] || REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_ROOT" || { echo "ERROR: cannot cd to $REPO_ROOT" >&2; exit 2; }

SCAN_DIR="plugins/rite"
if [ ! -d "$SCAN_DIR" ]; then
  if [ "$SKIP" -eq 1 ]; then
    [ "$QUIET" -eq 1 ] || echo "[grep-count-fallback] not applicable: no $SCAN_DIR under $REPO_ROOT" >&2
    exit 0
  fi
  echo "ERROR: $SCAN_DIR does not exist under $REPO_ROOT" >&2
  exit 2
fi

# grep with a -c style flag (-c, -cE, -nc, --count) followed on the same line by `|| echo 0`.
PATTERN='grep[[:space:]]+(-[A-Za-z]*c[A-Za-z]*|--count)([[:space:]]|$).*\|\|[[:space:]]*echo[[:space:]]+["'"'"']?0["'"'"']?'
total=0
while IFS= read -r f; do
  hits=$(grep -nE -- "$PATTERN" "$f" | grep -vE '^[0-9]+:[[:space:]]*(#|\|)') || hits=""
  [ -n "$hits" ] || continue
  while IFS= read -r line; do
    printf '[grep-count-fallback] %s:%s — echo-0 fallback after grep -c double-prints on zero matches; use an or-true fallback and ${var:-0}\n' "$f" "$line"
    total=$((total + 1))
  done <<< "$hits"
done < <(find "$SCAN_DIR" -type f \( -name '*.sh' -o -name '*.md' \) | sort)

[ "$QUIET" -eq 1 ] || echo "Total grep-count-fallback findings: ${total}" >&2
[ "$total" -eq 0 ] || exit 1
exit 0
