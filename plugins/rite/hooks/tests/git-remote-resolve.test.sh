#!/bin/bash
# Tests for resolve_owner_repo() in hooks/scripts/lib/git-remote.sh (#1899)
#
# `gh repo view` (used without --repo by issue-comment-wm-sync.sh,
# projects-board-drift-check.sh, watchdog-status-mismatch.sh, post-compact.sh)
# fails when `origin` is an SSH Host alias unrecognized by gh's host allowlist
# (e.g. `git@github.com-work:owner/repo.git`, configured in ~/.ssh/config).
# resolve_owner_repo() sidesteps that entirely by parsing the remote URL
# directly — the host segment is discarded regardless of what it says, so an
# unrecognized alias can never break this path. This test exercises the URL
# formats the parser must handle plus its two failure modes (no origin
# remote / not a git repository at all), since callers rely on a clean
# non-zero exit to know when to fall back to `gh repo view`.
#
# Convention: standalone subcommand (`bash lib/git-remote.sh resolve-owner-repo`),
# not sourced — mirrors ensure-session-worktree.test.sh's invocation style for
# the sibling lib/worktree-git.sh standalone subcommand.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"

LIB="$SCRIPT_DIR/../scripts/lib/git-remote.sh"

echo "=== resolve_owner_repo() (lib/git-remote.sh resolve-owner-repo) ==="

if [ ! -f "$LIB" ]; then
  echo "ERROR: $LIB not found" >&2
  exit 1
fi

cleanup_dirs=()
cleanup() {
  local d
  for d in "${cleanup_dirs[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
}
trap cleanup EXIT

resolve_in() {
  local dir="$1"
  ( cd "$dir" && bash "$LIB" resolve-owner-repo )
}

# --- Accept: URL formats resolve_owner_repo must parse (owner/repo regardless
#     of host string — this is the whole point: the alias case must parse
#     identically to the canonical github.com case). Each case asserts the
#     exact "owner<TAB>repo" value, not just "2 non-empty fields" — a parser
#     regression that leaks the host/port into the owner field (e.g. the
#     protocol-style branch stripping `:port` instead of the host) would
#     still produce 2 non-empty fields and slip past a structural-only check.
declare -A urls=(
  ["scp-like SSH Host alias (the #1899 repro case)"]="git@github.com-work:B16B1RD/cc-rite-workflow.git"
  ["scp-like SSH canonical host"]="git@github.com:B16B1RD/cc-rite-workflow.git"
  ["https with .git suffix"]="https://github.com/B16B1RD/cc-rite-workflow.git"
  ["https without .git suffix"]="https://github.com/B16B1RD/cc-rite-workflow"
  ["ssh:// with explicit user"]="ssh://git@github.com/B16B1RD/cc-rite-workflow.git"
  ["ssh:// with explicit port"]="ssh://git@github.com:22/B16B1RD/cc-rite-workflow.git"
  ["https on a GitHub Enterprise host"]="https://github.mycompany.com/org/repo.git"
)
declare -A expected=(
  ["scp-like SSH Host alias (the #1899 repro case)"]="B16B1RD/cc-rite-workflow"
  ["scp-like SSH canonical host"]="B16B1RD/cc-rite-workflow"
  ["https with .git suffix"]="B16B1RD/cc-rite-workflow"
  ["https without .git suffix"]="B16B1RD/cc-rite-workflow"
  ["ssh:// with explicit user"]="B16B1RD/cc-rite-workflow"
  ["ssh:// with explicit port"]="B16B1RD/cc-rite-workflow"
  ["https on a GitHub Enterprise host"]="org/repo"
)

sbx=$(make_sandbox) && cleanup_dirs+=("$sbx") || { echo "ERROR: make_sandbox failed, aborting" >&2; exit 1; }

for label in "${!urls[@]}"; do
  url="${urls[$label]}"
  ( cd "$sbx" && git remote remove origin >/dev/null 2>&1; git remote add origin "$url" ) >/dev/null 2>&1
  out=$(resolve_in "$sbx") ; rc=$?
  assert "$label: exit 0" "0" "$rc"
  owner_repo=$(printf '%s' "$out" | awk -F'\t' 'NF==2 {print $1 "/" $2; exit}')
  assert "$label: parses to exact ${expected[$label]}" "${expected[$label]}" "$owner_repo"
done

# Spot-check one exact value end-to-end (owner and repo both correct, not just non-empty).
( cd "$sbx" && git remote remove origin >/dev/null 2>&1; git remote add origin "git@github.com-work:B16B1RD/cc-rite-workflow.git" ) >/dev/null 2>&1
out=$(resolve_in "$sbx")
assert "alias case: exact owner<TAB>repo value" "$(printf 'B16B1RD\tcc-rite-workflow')" "$out"

# --- Reject: git repo with no origin remote configured ----------------------
sbx_noremote=$(make_sandbox) && cleanup_dirs+=("$sbx_noremote") || { echo "ERROR: make_sandbox failed, aborting" >&2; exit 1; }
( cd "$sbx_noremote" && git remote remove origin >/dev/null 2>&1 ) >/dev/null 2>&1
out=$(resolve_in "$sbx_noremote" 2>/dev/null); rc=$?
assert "no origin remote: non-zero exit" "1" "$( [ "$rc" -ne 0 ] && echo 1 || echo 0 )"
assert "no origin remote: empty stdout" "" "$out"

# --- Reject: owner or repo segment parses to empty (degenerate URL) ---------
( cd "$sbx" && git remote remove origin >/dev/null 2>&1; git remote add origin "git@github.com-work:/onlyrepo.git" ) >/dev/null 2>&1
out=$(resolve_in "$sbx" 2>/dev/null); rc=$?
assert "empty owner segment: non-zero exit" "1" "$( [ "$rc" -ne 0 ] && echo 1 || echo 0 )"
assert "empty owner segment: empty stdout" "" "$out"

( cd "$sbx" && git remote remove origin >/dev/null 2>&1; git remote add origin "https://github.com/onlyowner/" ) >/dev/null 2>&1
out=$(resolve_in "$sbx" 2>/dev/null); rc=$?
assert "empty repo segment: non-zero exit" "1" "$( [ "$rc" -ne 0 ] && echo 1 || echo 0 )"
assert "empty repo segment: empty stdout" "" "$out"

# --- Reject: 3+ segment origin path leaks an embedded `/` into $repo --------
# This is the charset check's whole reason for existing (git-remote.sh:58-63):
# callers pass the result straight into `gh ... --repo`, which re-parses
# `[HOST/]OWNER/REPO` — an unrejected extra segment here would let `gh`
# treat "a" as a HOST instead of the owner, silently redirecting the call to
# a different GitHub instance.
( cd "$sbx" && git remote remove origin >/dev/null 2>&1; git remote add origin "git@github.com-work:a/b/c.git" ) >/dev/null 2>&1
out=$(resolve_in "$sbx" 2>/dev/null); rc=$?
assert "3+ segment origin (embedded / in repo): non-zero exit" "1" "$( [ "$rc" -ne 0 ] && echo 1 || echo 0 )"
assert "3+ segment origin (embedded / in repo): empty stdout" "" "$out"

# --- Reject: disallowed character (outside [A-Za-z0-9._-]) in owner/repo ----
( cd "$sbx" && git remote remove origin >/dev/null 2>&1; git remote add origin "https://github.com/ow;ner/repo.git" ) >/dev/null 2>&1
out=$(resolve_in "$sbx" 2>/dev/null); rc=$?
assert "disallowed char in owner segment: non-zero exit" "1" "$( [ "$rc" -ne 0 ] && echo 1 || echo 0 )"
assert "disallowed char in owner segment: empty stdout" "" "$out"

# --- Reject: not a git repository at all (mirrors the bare `mkdir .git`
#     fixture pattern used by post-compact.test.sh's _setup_recon_env — the
#     4-site fallback design depends on this failing cleanly so it falls
#     through to the existing gh repo view path in those test fixtures) -----
fake_dir=$(make_plain_sandbox) && cleanup_dirs+=("$fake_dir") || { echo "ERROR: make_plain_sandbox failed, aborting" >&2; exit 1; }
mkdir -p "$fake_dir/.git"
out=$(resolve_in "$fake_dir" 2>/dev/null); rc=$?
assert "bare mkdir .git (non-repo): non-zero exit" "1" "$( [ "$rc" -ne 0 ] && echo 1 || echo 0 )"
assert "bare mkdir .git (non-repo): empty stdout" "" "$out"

# --- Unknown subcommand: exit 2, not silently ignored -----------------------
out=$(bash "$LIB" bogus-subcommand 2>&1); rc=$?
assert "unknown subcommand: exit 2" "2" "$rc"

print_summary "$(basename "$0")"
