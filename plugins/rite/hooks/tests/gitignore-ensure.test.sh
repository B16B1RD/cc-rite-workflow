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

print_summary "gitignore-ensure.sh"
