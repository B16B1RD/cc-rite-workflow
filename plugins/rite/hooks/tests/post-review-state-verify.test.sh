#!/bin/bash
# Tests for hooks/scripts/post-review-state-verify.sh worktree drift axis
#
# The production snapshot block and verifier compare tracked status hashes.
# Untracked paths are advisory; tracked edits still cause worktree drift.
# Character-device mounts are simulated with symlinks to /dev/null.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"

VERIFY="$SCRIPT_DIR/../scripts/post-review-state-verify.sh"
FILTER="$SCRIPT_DIR/../scripts/lib/git-status-filtered.sh"
PR_REVIEW_SKILL="$SCRIPT_DIR/../../skills/pr-review/SKILL.md"

echo "=== post-review-state-verify.sh (worktree drift axis, ghost-mount consistency) ==="

if [ ! -f "$VERIFY" ]; then
  echo "ERROR: $VERIFY not found" >&2
  exit 1
fi

# --- Pin: snapshot side (pr-review SKILL.md ステップ 4.0.A) must route ORIG_WTH
#     through git-status-filtered.sh -------------------------------------------
# snapshot_hash() below reimplements the SKILL.md command rather than reading it,
# so nothing else in this suite would catch a regression where the SKILL.md side
# reverts to raw `git status --porcelain`. Pin the source text directly.
# The capture-first pattern (filter output captured into _wth_raw before hashing,
# so the exit-code check does not depend on pipefail — each Bash tool invocation
# starts a fresh shell with pipefail off) puts the git-status-filtered.sh call on
# its own line rather than inline in the ORIG_WTH assignment.
assert_grep_in_section "SKILL.md 4.0.A: ORIG_WTH routed through git-status-filtered.sh" \
  "$PR_REVIEW_SKILL" \
  '^### 4\.0\.A ' '^### 4\.0\.W' '_wth_raw=.*git-status-filtered'

# --- Pin: snapshot side must also guard the filter's exit code -----------------
# SKILL.md is markdown (not directly executable), so a partial revert that keeps
# the `_wth_raw=...git-status-filtered.sh` routing line but drops the exit-code
# check (`_wth_rc` + the "snapshot skipped" WARNING) would go undetected by the
# routing pin alone. Pin the guard's presence too.
assert_grep_in_section "SKILL.md 4.0.A: filter failure guard present (WARNING + skip on non-zero exit)" \
  "$PR_REVIEW_SKILL" \
  '^### 4\.0\.A ' '^### 4\.0\.W' '_wth_rc.*-ne 0'

cleanup_dirs=()
cleanup() {
  local d
  for d in "${cleanup_dirs[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
}
trap cleanup EXIT

# Execute the production snapshot block so both sides use the same status mode.
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"
snapshot_block=$(awk '/^### 4\.0\.A /{section=1;next} section && /^```bash$/{code=1;next} code && /^```$/{exit} code{print}' "$PR_REVIEW_SKILL")
snapshot_block=${snapshot_block//\{plugin_root\}/$PLUGIN_ROOT}
[ -n "$snapshot_block" ] || { echo "ERROR: snapshot block missing" >&2; exit 1; }
snapshot_hash() {
  ( cd "$1" && eval "$snapshot_block" >/dev/null && printf '%s' "$ORIG_WTH" )
}

# --- Baseline: clean tree, no drift at all -----------------------------------
sbx0=$(make_sandbox) && cleanup_dirs+=("$sbx0") || { echo "ERROR: make_sandbox failed, aborting" >&2; exit 1; }
branch0=$(cd "$sbx0" && git branch --show-current)
wth0=$(snapshot_hash "$sbx0")
out0=$(cd "$sbx0" && bash "$VERIFY" --original-branch "$branch0" --original-worktree-hash "$wth0" --auto-recover true)
drift0=$(printf '%s' "$out0" | jq -r '.drift' 2>/dev/null)
assert "baseline: clean tree reports drift=false" "false" "$drift0"

# --- T-01 (AC-1): ghost-mount-only difference between snapshot and verify time
#     must NOT be reported as drift -------------------------------------------
sbx1=$(make_sandbox) && cleanup_dirs+=("$sbx1") || { echo "ERROR: make_sandbox failed, aborting" >&2; exit 1; }
branch1=$(cd "$sbx1" && git branch --show-current)
wth1=$(snapshot_hash "$sbx1")
# Simulate a ghost mount appearing between snapshot and verify (e.g. a
# different sandbox context at verify time overlaying a write-block mount).
( cd "$sbx1" && ln -s /dev/null ghost_devnull ) >/dev/null 2>&1
out1=$(cd "$sbx1" && bash "$VERIFY" --original-branch "$branch1" --original-worktree-hash "$wth1" --auto-recover true)
drift1=$(printf '%s' "$out1" | jq -r '.drift' 2>/dev/null)
assert "T-01: ghost-mount-only diff reports drift=false" "false" "$drift1"

# --- T-02 (AC-2): a real tracked-file edit between snapshot and verify time
#     MUST still be reported as worktree drift --------------------------------
sbx2=$(make_sandbox) && cleanup_dirs+=("$sbx2") || { echo "ERROR: make_sandbox failed, aborting" >&2; exit 1; }
branch2=$(cd "$sbx2" && git branch --show-current)
wth2=$(snapshot_hash "$sbx2")
( cd "$sbx2" && echo changed >> a ) >/dev/null 2>&1
stderr2=$(mktemp) && cleanup_dirs+=("$stderr2")
out2=$(cd "$sbx2" && bash "$VERIFY" --original-branch "$branch2" --original-worktree-hash "$wth2" --auto-recover true 2>"$stderr2")
drift2=$(printf '%s' "$out2" | jq -r '.drift' 2>/dev/null)
type2=$(printf '%s' "$out2" | jq -r '.type' 2>/dev/null)
recovered2=$(printf '%s' "$out2" | jq -r '.recovered' 2>/dev/null)
assert "T-02: real tracked-file edit reports drift=true" "true" "$drift2"
assert "T-02: drift type is worktree" "worktree" "$type2"
assert "T-02: worktree drift is not auto-recovered" "false" "$recovered2"
if grep -qF 'working-tree git verbs are not pre-blocked because exhaustive command matching is unsafe' "$stderr2"; then
  pass "T-02: drift diagnostic explains why post-condition detection is required"
else
  fail "T-02: drift diagnostic omitted the durable post-condition rationale"
fi

# --- T-02b: ghost mount + real edit together still detects the real drift ---
sbx3=$(make_sandbox) && cleanup_dirs+=("$sbx3") || { echo "ERROR: make_sandbox failed, aborting" >&2; exit 1; }
branch3=$(cd "$sbx3" && git branch --show-current)
wth3=$(snapshot_hash "$sbx3")
( cd "$sbx3" && ln -s /dev/null ghost_devnull && echo changed >> a ) >/dev/null 2>&1
out3=$(cd "$sbx3" && bash "$VERIFY" --original-branch "$branch3" --original-worktree-hash "$wth3" --auto-recover true)
drift3=$(printf '%s' "$out3" | jq -r '.drift' 2>/dev/null)
type3=$(printf '%s' "$out3" | jq -r '.type' 2>/dev/null)
assert "T-02b: real edit alongside ghost mount still reports drift=true" "true" "$drift3"
assert "T-02b: drift type is worktree" "worktree" "$type3"

# --- T-03: git-status-filtered.sh failure (e.g. mktemp failing under a
#     write-restricted TMPDIR) must surface a WARNING and skip the worktree
#     axis rather than silently treating an empty hash as a valid one -------
# A copy of VERIFY is run from a scratch dir whose lib/git-status-filtered.sh
# is a stub that always fails, so SCRIPT_DIR (derived from the copy's own
# path) resolves to the failing stub regardless of cwd. This exercises the
# capture-first exit-code check independent of pipefail state.
fail_dir=$(mktemp -d) && cleanup_dirs+=("$fail_dir") || { echo "ERROR: mktemp -d failed, aborting" >&2; exit 1; }
mkdir -p "$fail_dir/lib"
cp "$VERIFY" "$fail_dir/post-review-state-verify.sh"
cat > "$fail_dir/lib/git-status-filtered.sh" << 'STUB_EOF'
#!/bin/bash
echo "WARNING: git-status-filtered: mktemp failed" >&2
exit 1
STUB_EOF
chmod +x "$fail_dir/lib/git-status-filtered.sh"

sbx4=$(make_sandbox) && cleanup_dirs+=("$sbx4") || { echo "ERROR: make_sandbox failed, aborting" >&2; exit 1; }
branch4=$(cd "$sbx4" && git branch --show-current)
stderr4=$(mktemp) && cleanup_dirs+=("$stderr4")
out4=$(cd "$sbx4" && bash "$fail_dir/post-review-state-verify.sh" --original-branch "$branch4" --original-worktree-hash "nonempty-snapshot-hash" --auto-recover true 2>"$stderr4")
drift4=$(printf '%s' "$out4" | jq -r '.drift' 2>/dev/null)
assert "T-03: filter failure does not report drift (axis skipped, not silently matched)" "false" "$drift4"
case "$(cat "$stderr4")" in
  *"git-status-filtered.sh failed"*) pass "T-03: filter failure surfaces a WARNING" ;;
  *) fail "T-03: filter failure surfaces a WARNING (stderr: $(cat "$stderr4"))" ;;
esac

# --- T-04: snapshot taken on an already-dirty tree, unchanged before verify,
#     must NOT report drift ----------------------------------------------------
# baseline/T-01/T-02/T-02b all snapshot a clean tree (empty filter output), so
# they cannot distinguish the capture-first hash computation from a naive
# direct-pipe one — both produce the same empty-input hash. This case snapshots
# a tree that already has an uncommitted change, then verifies with no further
# change, exercising the capture-first path on non-empty filter output (where
# a direct pipe's retained trailing newline would diverge from `$(...)`'s
# stripped one and falsely report drift).
sbx5=$(make_sandbox) && cleanup_dirs+=("$sbx5") || { echo "ERROR: make_sandbox failed, aborting" >&2; exit 1; }
branch5=$(cd "$sbx5" && git branch --show-current)
( cd "$sbx5" && echo already-dirty >> a ) >/dev/null 2>&1
wth5=$(snapshot_hash "$sbx5")
out5=$(cd "$sbx5" && bash "$VERIFY" --original-branch "$branch5" --original-worktree-hash "$wth5" --auto-recover true)
drift5=$(printf '%s' "$out5" | jq -r '.drift' 2>/dev/null)
assert "T-04: dirty-at-snapshot tree, unchanged at verify, reports drift=false" "false" "$drift5"

# Ordinary untracked files at snapshot time and newly appearing stubs are advisory.
sbx_untracked=$(make_sandbox) && cleanup_dirs+=("$sbx_untracked") || exit 1
branch_untracked=$(cd "$sbx_untracked" && git branch --show-current)
printf 'reviewer output' > "$sbx_untracked/new.txt"
wth_untracked=$(snapshot_hash "$sbx_untracked")
assert "untracked before snapshot leaves tracked hash unchanged" "$wth0" "$wth_untracked"
rm "$sbx_untracked/new.txt"
stubs=(.bashrc .zshrc .profile .bash_profile .zprofile .gitconfig .gitmodules .ripgreprc .idea .vscode)
for name in "${stubs[@]}"; do touch "$sbx_untracked/$name"; done
stderr_untracked=$(mktemp) && cleanup_dirs+=("$stderr_untracked")
out=$(cd "$sbx_untracked" && bash "$VERIFY" --original-branch "$branch_untracked" --original-worktree-hash "$wth_untracked" 2>"$stderr_untracked")
assert "ten untracked stubs do not cause drift" false "$(printf '%s' "$out" | jq -r .drift)"
assert "untracked warning reports ten paths" 1 "$(grep -c 'WARNING:.*10 untracked path(s)' "$stderr_untracked")"
for name in "${stubs[@]}"; do
  assert "untracked warning includes $name" 1 "$(grep -Fc " $name" "$stderr_untracked")"
done
printf 'tracked edit' >> "$sbx_untracked/a"
out=$(cd "$sbx_untracked" && bash "$VERIFY" --original-branch "$branch_untracked" --original-worktree-hash "$wth_untracked" 2>"$stderr_untracked")
assert "tracked edit with ten untracked files remains drift" worktree "$(printf '%s' "$out" | jq -r '.type')"

print_summary "$(basename "$0")"
