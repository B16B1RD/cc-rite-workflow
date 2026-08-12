#!/bin/bash
# Tests for parse_wiki_scalar() in hooks/scripts/lib/wiki-config.sh
#
# The sibling test in this directory covers validate_wiki_branch_name(); this one
# covers the other half of the lib, which had no direct coverage. That gap
# stopped being tolerable when four skill bodies (wiki-ingest / wiki-lint /
# cleanup / issue-close) moved their configuration reads here: what used to be
# four independently-broken inline parsers is now a single shared function every
# one of them depends on, so a regression in it changes four call sites at once.
#
# The assertions below pin the properties those callers rely on: the opt-out
# defaults key off an empty return, so "key absent" and "value is false" must
# stay distinguishable at the caller, not inside this function.
#
# Convention: source the lib and call the function in-process (it is a
# source-only helper, not a standalone script). parse_wiki_scalar reads
# rite-config.yml from the current directory, so each case cd's into a sandbox.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"

LIB="$SCRIPT_DIR/../scripts/lib/wiki-config.sh"

echo "=== parse_wiki_scalar() tests ==="

if [ ! -f "$LIB" ]; then
  echo "ERROR: $LIB not found" >&2
  exit 1
fi

# shellcheck source=../scripts/lib/wiki-config.sh
source "$LIB"

if ! type parse_wiki_scalar >/dev/null 2>&1; then
  echo "ERROR: parse_wiki_scalar not defined after sourcing $LIB" >&2
  exit 1
fi

# The helper's own hard-fail is `exit 1`, which inside `$( )` ends the subshell
# and nothing else — so a failed mktemp leaves SANDBOX empty here. `cd ""` is a
# no-op that returns 0, so the guard on the cd below would not fire either, and
# every fixture write plus the `rm -f rite-config.yml` further down would land in
# the caller's working directory — the repository root under run-tests.sh, where
# rite-config.yml is tracked. The suite would still report PASS. Check the value
# at the point it is produced.
SANDBOX="$(make_plain_sandbox)" || { echo "ERROR: make_plain_sandbox failed, aborting" >&2; exit 1; }
[ -n "$SANDBOX" ] || { echo "ERROR: make_plain_sandbox returned an empty path, aborting" >&2; exit 1; }
ORIG_PWD="$PWD"
cleanup() {
  cd "$ORIG_PWD" 2>/dev/null || true
  [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX"
}
trap 'rc=$?; cleanup; exit $rc' EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
trap 'cleanup; exit 129' HUP

cd "${SANDBOX:?sandbox path is empty}" || { echo "ERROR: cannot cd to sandbox" >&2; exit 1; }

# Writes a rite-config.yml whose `wiki:` section holds the given lines.
write_wiki_config() {
  {
    printf 'branch:\n  base: "develop"\n\n'
    printf 'wiki:\n'
    printf '%s\n' "$@"
    printf '\nother:\n  key: value\n'
  } > rite-config.yml
}

# --- Values are read back as written -----------------------------------------
write_wiki_config '  enabled: true' '  auto_ingest: true' '  branch_name: "wiki"'
assert "enabled: true reads back" "true" "$(parse_wiki_scalar enabled)"
assert "auto_ingest: true reads back" "true" "$(parse_wiki_scalar auto_ingest)"
assert "quotes are stripped from branch_name" "wiki" "$(parse_wiki_scalar branch_name)"

write_wiki_config '  enabled: false' '  auto_ingest: false'
assert "enabled: false reads back" "false" "$(parse_wiki_scalar enabled)"
assert "auto_ingest: false reads back" "false" "$(parse_wiki_scalar auto_ingest)"

# --- Comment and whitespace handling ------------------------------------------
# YAML starts an inline comment only after whitespace, which is why the strip
# pattern is `whitespace + #` rather than a bare `#`.
write_wiki_config '  enabled: true                # Wiki 機能の有効化（opt-out）'
assert "inline comment after the value is stripped" "true" "$(parse_wiki_scalar enabled)"

write_wiki_config '  branch_name: "wiki-notes"   # ブランチ名'
assert "inline comment and quotes strip together" "wiki-notes" \
  "$(parse_wiki_scalar branch_name)"

write_wiki_config "  branch_name: 'single-quoted'"
assert "single quotes are stripped" "single-quoted" "$(parse_wiki_scalar branch_name)"

# --- Empty result cases, which callers map to their own defaults --------------
# Callers distinguish "absent" from "false" themselves: cleanup treats an empty
# auto_ingest as false (opt-in) while treating an empty enabled as true
# (opt-out). Both behaviours break if this function ever invents a value.
write_wiki_config '  enabled: true'
assert "absent key returns empty" "" "$(parse_wiki_scalar auto_ingest)"

printf 'branch:\n  base: "develop"\nother:\n  key: value\n' > rite-config.yml
assert "absent wiki: section returns empty" "" "$(parse_wiki_scalar enabled)"

rm -f rite-config.yml
assert "absent rite-config.yml returns empty" "" "$(parse_wiki_scalar enabled)"
assert "absent rite-config.yml still exits 0" "0" \
  "$(parse_wiki_scalar enabled >/dev/null 2>&1; echo $?)"

# --- Section boundary ---------------------------------------------------------
# The section ends at the next top-level key, so a same-named key elsewhere in
# the file must not be picked up.
{
  printf 'wiki:\n  enabled: true\n\n'
  printf 'other:\n  enabled: false\n'
} > rite-config.yml
assert "same-named key in a later section is not read" "true" \
  "$(parse_wiki_scalar enabled)"

{
  printf 'other:\n  branch_name: "wrong"\n\n'
  printf 'wiki:\n  branch_name: "right"\n'
} > rite-config.yml
assert "same-named key in an earlier section is not read" "right" \
  "$(parse_wiki_scalar branch_name)"

# --- Key matching is anchored -------------------------------------------------
# `auto_ingest` must not satisfy a lookup for `ingest`, or a caller asking for a
# key that does not exist would silently receive another key's value.
write_wiki_config '  auto_ingest: true'
assert "a longer key does not satisfy a shorter lookup" "" \
  "$(parse_wiki_scalar ingest)"

# --- Case is preserved --------------------------------------------------------
# Callers that need a case-insensitive comparison apply `tr` themselves; folding
# case here would also fold branch_name, and git refs are case-sensitive.
write_wiki_config '  enabled: TRUE' '  branch_name: "Wiki-Notes"'
assert "value case is preserved (caller lowercases if needed)" "TRUE" \
  "$(parse_wiki_scalar enabled)"
assert "branch_name case is preserved" "Wiki-Notes" \
  "$(parse_wiki_scalar branch_name)"

print_summary "$(basename "$0")"
