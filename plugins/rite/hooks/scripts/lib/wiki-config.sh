# rite workflow - Wiki config parsing / branch name validation helpers
#
# Responsibility: provide the canonical implementations of
#   - parse_wiki_scalar()        — lenient YAML reader for the `wiki:` section
#   - validate_wiki_branch_name() — defensive branch-name validation
# so that wiki-worktree-setup.sh / wiki-worktree-commit.sh /
# wiki-ingest-commit.sh can share a single definition instead of keeping
# three character-exact copies in sync manually.
#
# Design rationale (Issue #549): previous commits (PR #548 cycle 4 review
# F-05 / F-06) identified that parse_wiki_scalar had drifted across the
# three sibling scripts, creating a transcription-failure class of bugs
# every time the `wiki.branch_name` parsing contract changed. Extracting a
# shared lib makes future edits a one-file operation.
#
# Usage:
#   source "$(dirname "$0")/lib/wiki-config.sh"
#   val=$(parse_wiki_scalar enabled)
#   validate_wiki_branch_name "$wiki_branch" || exit 1
#
# Contract:
#   - No side effects at source time (function definitions only).
#   - Does NOT set `set -euo pipefail` — the caller owns that.
#   - Assumes the working directory is the repo root and rite-config.yml
#     exists. Callers that need to tolerate a missing config file should
#     guard with `[[ -f rite-config.yml ]]` before calling parse_wiki_scalar.

# -----------------------------------------------------------------------
# parse_wiki_scalar KEY
#
# Extract the value of `wiki.<KEY>` from rite-config.yml using the same
# lenient YAML approach as wiki-ingest-trigger.sh / ingest.md Phase 1.1
# (awk section extraction + inline-comment strip + quote strip).
#
# Security note (verified-review cycle 4 LOW): key value extraction uses
# `awk -v k=...` rather than `sed` with an interpolated `$key`. Current
# callers pass hardcoded literal keys only, so there is no injection path
# today, but `sed "s/.*${key}:[[:space:]]*//"` would treat sed metachars
# in `$key` as pattern metacharacters if a future caller ever passed
# user-controlled input. `awk -v` keeps the value in a variable binding
# that is never re-parsed as a regex.
# -----------------------------------------------------------------------
parse_wiki_scalar() {
  local key="$1"
  local section line val
  section=$(sed -n '/^wiki:/,/^[a-zA-Z]/p' rite-config.yml 2>/dev/null || true)
  [[ -z "$section" ]] && return 0
  line=$(printf '%s\n' "$section" | awk -v k="$key" '
    BEGIN { pat = "^[[:space:]]+" k ":" }
    $0 ~ pat { print; exit }
  ' 2>/dev/null || true)
  [[ -z "$line" ]] && return 0
  val=$(printf '%s' "$line" \
    | sed 's/[[:space:]]#.*//' \
    | awk -v k="$key" '{
        sub("^[[:space:]]*" k ":[[:space:]]*", "")
        print
      }' \
    | tr -d '[:space:]"'"'")
  printf '%s' "$val"
}

# -----------------------------------------------------------------------
# validate_wiki_branch_name BRANCH
#
# Reject branch names that would be unsafe to pass to `git` as a ref or
# as the positional argument of `git -C ... add -- "$path"`. The rules
# mirror what wiki-ingest-commit.sh MEDIUM #6 established:
#   - non-empty
#   - must not start with `-` (would be parsed as an option flag)
#   - must not start with `.` (collides with hidden refs)
#   - must not contain `..` (path traversal in `refs/heads/<name>`)
#   - must not contain `//` (empty path segment)
#   - must match the common ref-name alphabet [A-Za-z0-9._/-]+
#
# On failure emits a descriptive ERROR + allowed-syntax hint to stderr and
# returns 1. On success returns 0 with no output. Callers typically use:
#   validate_wiki_branch_name "$wiki_branch" || exit 1
# -----------------------------------------------------------------------
validate_wiki_branch_name() {
  local branch="$1"
  if [[ -z "$branch" ]] || [[ "$branch" == -* ]] || \
     [[ "$branch" == .* ]] || \
     [[ "$branch" == *..* ]] || \
     [[ "$branch" == *//* ]] || \
     [[ ! "$branch" =~ ^[A-Za-z0-9._/-]+$ ]]; then
    echo "ERROR: invalid wiki.branch_name '${branch}' in rite-config.yml" >&2
    echo "  allowed: [A-Za-z0-9._/-]+, must not start with '-' / '.', must not contain '..' or '//'" >&2
    return 1
  fi
  return 0
}
