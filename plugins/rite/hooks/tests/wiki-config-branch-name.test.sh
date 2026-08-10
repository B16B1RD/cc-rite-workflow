#!/bin/bash
# Security pin tests for validate_wiki_branch_name() in
# hooks/scripts/lib/wiki-config.sh (the governing rationale, AC-3)
#
# validate_wiki_branch_name rejects branch names that would be unsafe as a git
# ref or as the positional argument of `git -C ... add -- "$path"` (leading `-`
# parsed as a flag, leading `.` colliding with hidden refs, `..` traversal, `//`
# empty segment, out-of-alphabet chars). Its callers only ever reach it on the
# happy path with `wiki` (or a valid custom name), so the rejection branches
# were never exercised directly. This test sources the lib and calls the
# function against malicious inputs so a validation regression is caught.
#
# Convention: source the lib and call the function in-process (it is a
# source-only helper, not a standalone script). No sandbox / network.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"

LIB="$SCRIPT_DIR/../scripts/lib/wiki-config.sh"

echo "=== validate_wiki_branch_name() security pin tests ==="

if [ ! -f "$LIB" ]; then
  echo "ERROR: $LIB not found" >&2
  exit 1
fi

# shellcheck source=../scripts/lib/wiki-config.sh
source "$LIB"

if ! type validate_wiki_branch_name >/dev/null 2>&1; then
  echo "ERROR: validate_wiki_branch_name not defined after sourcing $LIB" >&2
  exit 1
fi

check() { validate_wiki_branch_name "$1" >/dev/null 2>&1; echo $?; }

# --- Accept: valid ref names --------------------------------------------------
assert "'wiki' (default) accepted" "0" "$(check "wiki")"
assert "namespaced 'feature/wiki-notes' accepted" "0" "$(check "feature/wiki-notes")"
assert "dot-in-middle 'wiki.backup' accepted" "0" "$(check "wiki.backup")"
assert "underscore/dash/slash 'a_b-c/d' accepted" "0" "$(check "a_b-c/d")"

# --- Reject: empty ------------------------------------------------------------
assert "empty name rejected" "1" "$(check "")"

# --- Reject: leading '-' (parsed as an option flag) ---------------------------
assert "leading '-' rejected" "1" "$(check "-wiki")"

# --- Reject: leading '.' (hidden-ref collision) -------------------------------
assert "leading '.' rejected" "1" "$(check ".wiki")"

# --- Reject: '..' traversal in refs/heads/<name> ------------------------------
assert "'..' traversal rejected" "1" "$(check "wiki/../evil")"

# --- Reject: '//' empty path segment ------------------------------------------
assert "'//' empty segment rejected" "1" "$(check "wiki//branch")"

# --- Reject: out-of-alphabet characters ---------------------------------------
assert "space rejected" "1" "$(check "wiki branch")"
assert "shell metachar '\$' rejected" "1" "$(check 'wiki$x')"
assert "semicolon rejected" "1" "$(check "wiki;rm")"

# --- Rejection diagnostics reach stderr ---------------------------------------
reject_err="$(validate_wiki_branch_name "-wiki" 2>&1 >/dev/null || true)"
if printf '%s' "$reject_err" | grep -qE "invalid wiki.branch_name"; then
  pass "rejection prints a descriptive ERROR to stderr"
else
  fail "rejection ERROR missing/malformed: $reject_err"
fi

print_summary "validate_wiki_branch_name"
