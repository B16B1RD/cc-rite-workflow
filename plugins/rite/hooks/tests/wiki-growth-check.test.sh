#!/bin/bash
# Tests for hooks/scripts/wiki-growth-check.sh
#
# The checker is a non-blocking lint that fires (exit 1) when the wiki branch
# has stalled relative to merged PRs on the base branch. Its many skip paths
# (exit 0) exist so it never blocks a flow on a misconfigured or wiki-disabled
# repo. These tests pin the invocation contract, the config/branch skip gates,
# and one gh-stubbed positive detection.
#
# Convention: mktemp sandbox, gh stubbed via PATH (no network), GNU/BSD
# portable, commit.gpgsign disabled locally so fixtures commit under a global
# signing config.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"

SCRIPT="$SCRIPT_DIR/../scripts/wiki-growth-check.sh"

echo "=== wiki-growth-check.sh tests ==="

if [ ! -f "$SCRIPT" ]; then
  echo "ERROR: $SCRIPT not found" >&2
  exit 1
fi
# The growth-stall path counts merged PRs via jq; without jq the script exits 0
# (skip) and the exit-1 assertion below would FAIL rather than skip. Guard the
# whole test the same way the sibling review-schema-version-check.test.sh does.
if ! command -v jq >/dev/null 2>&1; then
  # Floor first: jq is a prerequisite for every leg, so its absence on the blocking
  # gate means it was removed or shadowed on PATH, not that the platform lacks it.
  # Skipping there would drop this file's entire coverage while the run stays green.
  # `[ -d /proc ]` rather than `uname -s`, which resolves through the same PATH.
  if [ -d /proc ]; then
    echo "  ❌ FAIL: wiki-growth-check floor: jq unavailable on Linux (missing or shadowed on PATH?) — this file's coverage must never be skipped on the blocking gate"
    echo "Results: 0 passed, 1 failed"
    exit 1
  fi
  # Emit the counted form so the runner rolls this into its "N skipped" headline —
  # a whole file that exits 0 without running anything would otherwise be scored
  # as a pass (review I-03).
  echo "  ⏭️ SKIP: jq not available — wiki-growth-check requires jq"
  echo "SKIP: 1"
  exit 0
fi

SANDBOXES=()
cleanup() { local d; for d in "${SANDBOXES[@]:-}"; do [ -n "$d" ] && rm -rf "$d"; done; }
trap 'rc=$?; cleanup; exit $rc' EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
trap 'cleanup; exit 129' HUP

# gh stub: emit a fixed merged-PR JSON array (GH_STUB_PRS, default []). Both the
# growth-stall count query and the pr-raw correspondence query read this.
STUB_DIR="$(mktemp -d)"; SANDBOXES+=("$STUB_DIR")
cat > "$STUB_DIR/gh" <<'EOF'
#!/bin/bash
printf '%s\n' "${GH_STUB_PRS:-[]}"
exit 0
EOF
chmod +x "$STUB_DIR/gh"

# Build a git repo with rite-config.yml committed and (optionally) a wiki branch.
#   $1 = wiki enabled? (true|false)   $2 = create wiki branch? (yes|no)
# Echoes the repo path. The caller MUST register the returned path in SANDBOXES
# from the PARENT shell — this helper runs inside a $(...) command substitution,
# so a `SANDBOXES+=` here would be lost with the subshell (the pitfall
# _test-helpers.sh documents). Git steps are &&-chained and HEAD is asserted so a
# broken fixture fails loudly instead of returning an empty repo that silently
# passes the skip-path (exit 0) assertions.
make_wiki_repo() {
  local enabled="$1" with_wiki="$2" repo
  repo="$(mktemp -d)"
  git -C "$repo" init -q \
    && git -C "$repo" config user.email t@test.local \
    && git -C "$repo" config user.name test \
    && git -C "$repo" config commit.gpgsign false \
    || { echo "FAIL: make_wiki_repo git init/config failed" >&2; exit 1; }
  printf 'wiki:\n  enabled: %s\n  branch_name: wiki\nbranch:\n  base: develop\n' "$enabled" \
    > "$repo/rite-config.yml"
  git -C "$repo" add rite-config.yml \
    && git -C "$repo" commit -q -m init \
    && git -C "$repo" rev-parse HEAD >/dev/null 2>&1 \
    || { echo "FAIL: make_wiki_repo fixture commit failed" >&2; exit 1; }
  if [ "$with_wiki" = "yes" ]; then
    git -C "$repo" branch wiki || { echo "FAIL: make_wiki_repo wiki branch failed" >&2; exit 1; }
  fi
  printf '%s' "$repo"
}

# --- Invocation contract ------------------------------------------------------
assert "--help exits 0" "0" "$(bash "$SCRIPT" --help >/dev/null 2>&1; echo $?)"
assert "unknown argument exits 2" "2" "$(bash "$SCRIPT" --repo-root "$STUB_DIR" --bogus >/dev/null 2>&1; echo $?)"

# --- Skip gates (exit 0) ------------------------------------------------------
empty_dir="$(mktemp -d)"; SANDBOXES+=("$empty_dir")
assert "rite-config.yml absent → skip (exit 0)" "0" \
  "$(bash "$SCRIPT" --repo-root "$empty_dir" --quiet >/dev/null 2>&1; echo $?)"

disabled_repo="$(make_wiki_repo false yes)"; SANDBOXES+=("$disabled_repo")
assert "wiki.enabled=false → skip (exit 0)" "0" \
  "$(bash "$SCRIPT" --repo-root "$disabled_repo" --quiet >/dev/null 2>&1; echo $?)"

no_wiki_repo="$(make_wiki_repo true no)"; SANDBOXES+=("$no_wiki_repo")
assert "wiki branch absent → skip (exit 0)" "0" \
  "$(PATH="$STUB_DIR:$PATH" bash "$SCRIPT" --repo-root "$no_wiki_repo" --quiet >/dev/null 2>&1; echo $?)"

# --- Healthy: wiki branch present, zero merged PRs → exit 0 -------------------
healthy_repo="$(make_wiki_repo true yes)"; SANDBOXES+=("$healthy_repo")
assert "no merged PRs since last wiki commit → healthy (exit 0)" "0" \
  "$(PATH="$STUB_DIR:$PATH" GH_STUB_PRS='[]' bash "$SCRIPT" --repo-root "$healthy_repo" --quiet >/dev/null 2>&1; echo $?)"

# --- Growth stall detected (exit 1) ------------------------------------------
# threshold=1 with 1 merged PR trips the stall; pr-raw-threshold set high so the
# correspondence check stays healthy and only the growth-stall finding counts.
stall_repo="$(make_wiki_repo true yes)"; SANDBOXES+=("$stall_repo")
assert "merged PRs >= threshold with stalled wiki → finding (exit 1)" "1" \
  "$(PATH="$STUB_DIR:$PATH" GH_STUB_PRS='[{"number":1}]' bash "$SCRIPT" \
      --repo-root "$stall_repo" --threshold 1 --pr-raw-threshold 999 --quiet >/dev/null 2>&1; echo $?)"

# --- Findings line always emitted --------------------------------------------
findings_out="$(PATH="$STUB_DIR:$PATH" GH_STUB_PRS='[]' bash "$SCRIPT" --repo-root "$healthy_repo" --quiet 2>/dev/null || true)"
if printf '%s' "$findings_out" | grep -qE '==> Total wiki-growth-check findings: [0-9]+'; then
  pass "always prints the findings summary line"
else
  fail "findings summary line missing: $findings_out"
fi

print_summary "wiki-growth-check.sh"
