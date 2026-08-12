#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"
source "$SCRIPT_DIR/../gitignore-ensure.sh"

SBX=$(make_plain_sandbox); trap 'rm -rf -- "$SBX"' EXIT
target="$SBX/runtime"; mkdir -p "$target"

_ensure_dir_gitignore "$target"
assert "missing exclusion is created" "*" "$(cat "$target/.gitignore")"

: > "$target/.gitignore"
_ensure_dir_gitignore "$target"
assert "empty exclusion is repaired" "*" "$(cat "$target/.gitignore")"

printf '%s\n' '!keep' > "$target/.gitignore"
_ensure_dir_gitignore "$target"
assert "non-empty caller policy is preserved" "!keep" "$(cat "$target/.gitignore")"

mkdir -p "$SBX/not-a-dir"
printf '%s' occupied > "$SBX/not-a-dir/.gitignore"
_ensure_dir_gitignore "$SBX/not-a-dir/.gitignore" >/dev/null 2>&1; rc=$?
assert "write failure is returned" "1" "$rc"
assert "write failure exposes a cause" "0" "$([ -n "$_RITE_GITIGNORE_ERROR" ]; echo $?)"

HOOKS_DIR="$SCRIPT_DIR/.."
callers=(
  "$HOOKS_DIR/session-start.sh"
  "$HOOKS_DIR/review-result-save.sh"
  "$HOOKS_DIR/scripts/review-results-archive-or-rm.sh"
  "$HOOKS_DIR/flow-state.sh"
)
for caller in "${callers[@]}"; do
  assert "$(basename "$caller") uses the shared primitive exactly once" "1" \
    "$(grep -c '_ensure_dir_gitignore ' "$caller" || true)"
done
raw_writers=$(LC_ALL=C grep -nF "printf '*\\n'" "${callers[@]}" 2>/dev/null || true)
assert "production callers contain no private star-only writer" "" "$raw_writers"

print_summary "gitignore-ensure.sh"
