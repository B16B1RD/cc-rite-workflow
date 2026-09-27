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

# --- Pin: snapshot side (pr-review SKILL.md ステップ 4.0.A) delegates to the
#     verifier's --snapshot mode, so both sides compute the 4 axes with the same
#     functions. An inline computation reappearing in 4.0.A would let the two
#     sides drift apart again. -------------------------------------------------
assert_grep_in_section "SKILL.md 4.0.A: snapshot delegates to post-review-state-verify.sh --snapshot" \
  "$PR_REVIEW_SKILL" \
  '^### 4\.0\.A ' '^### 4\.0\.W' 'post-review-state-verify\.sh --snapshot'

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
for inline in 'git stash list' 'git branch --list' 'git-status-filtered'; do
  case "$snapshot_block" in
    *"$inline"*) fail "SKILL.md 4.0.A: no inline '$inline' (axes are computed by the helper only)" ;;
    *) pass "SKILL.md 4.0.A: no inline '$inline' (axes are computed by the helper only)" ;;
  esac
done
# Run the production 4.0.A block and return its review_pre_state line.
snapshot_line() {
  ( cd "$1" && eval "$snapshot_block" )
}
# $1 = review_pre_state line, $2 = field name (branch / stash_count / ...)
field() {
  printf '%s\n' "$1" | sed -n "s/.* $2=\([^ ]*\).*/\1/p"
}
snapshot_hash() {
  field "$(snapshot_line "$1")" worktree_hash
}
# Verify $1 against the snapshot line $2 with all four axes; extra args pass through.
verify_all() {
  local dir="$1" line="$2"
  shift 2
  ( cd "$dir" && bash "$VERIFY" --original-branch "$(field "$line" branch)" \
      --original-stash-count "$(field "$line" stash_count)" \
      --original-branch-list-hash "$(field "$line" branch_list_hash)" \
      --original-worktree-hash "$(field "$line" worktree_hash)" "$@" )
}
new_sandbox() {
  local d
  d=$(make_sandbox) || return 1
  git -C "$d" config user.email t@test.local
  git -C "$d" config user.name test
  printf '%s\n' "$d"
}

# --- Output shape: one review_pre_state line with all four fields -------------
sbx_shape=$(new_sandbox) && cleanup_dirs+=("$sbx_shape") || { echo "ERROR: sandbox setup failed, aborting" >&2; exit 1; }
shape_out=$(snapshot_line "$sbx_shape")
assert "snapshot prints exactly one line" 1 "$(printf '%s\n' "$shape_out" | wc -l | tr -d ' ')"
if printf '%s\n' "$shape_out" | grep -qE '^review_pre_state: branch=[^ ]+ stash_count=[0-9]+ branch_list_hash=[^ ]* worktree_hash=[^ ]*$'; then
  pass "snapshot line has the review_pre_state shape"
else
  fail "snapshot line has the review_pre_state shape (got: $shape_out)"
fi

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

# refs/heads and refs/stash are shared by every worktree. A parallel session's
# branch / stash operations in another worktree must not read as reviewer drift,
# while the same operations in the reviewed worktree still must.
wt_base=$(mktemp -d) && cleanup_dirs+=("$wt_base") || exit 1
wt_base=$(cd "$wt_base" && pwd -P)

# --- Another worktree creates a branch during the review -----------------------
sbx=$(new_sandbox) && cleanup_dirs+=("$sbx") || exit 1
snap=$(snapshot_line "$sbx")
git -C "$sbx" worktree add -q -b other-created "$wt_base/created" >/dev/null 2>&1
out=$(verify_all "$sbx" "$snap"); rc=$?
assert "other worktree creating a branch reports drift=false" false "$(printf '%s' "$out" | jq -r .drift)"
assert "other worktree creating a branch exits 0" 0 "$rc"

# --- Another worktree is removed and its branch deleted during the review ------
sbx=$(new_sandbox) && cleanup_dirs+=("$sbx") || exit 1
git -C "$sbx" worktree add -q -b other-deleted "$wt_base/deleted" >/dev/null 2>&1
snap=$(snapshot_line "$sbx")
git -C "$sbx" worktree remove "$wt_base/deleted" >/dev/null 2>&1
git -C "$sbx" branch -q -D other-deleted
out=$(verify_all "$sbx" "$snap"); rc=$?
assert "other worktree deleting its branch reports drift=false" false "$(printf '%s' "$out" | jq -r .drift)"
assert "other worktree deleting its branch exits 0" 0 "$rc"

# --- The other worktree is registered through a symlinked path -----------------
sbx=$(new_sandbox) && cleanup_dirs+=("$sbx") || exit 1
ln -s "$wt_base" "$wt_base-link" && cleanup_dirs+=("$wt_base-link")
snap=$(snapshot_line "$sbx")
git -C "$sbx" worktree add -q -b other-linked "$wt_base-link/linked" >/dev/null 2>&1
out=$(verify_all "$sbx" "$snap")
assert "branch checked out via a symlinked worktree path reports drift=false" false "$(printf '%s' "$out" | jq -r .drift)"

# --- Another worktree stashes during the review ---------------------------------
sbx=$(new_sandbox) && cleanup_dirs+=("$sbx") || exit 1
git -C "$sbx" worktree add -q -b other-stash "$wt_base/stash" >/dev/null 2>&1
snap=$(snapshot_line "$sbx")
echo other >> "$wt_base/stash/a"
git -C "$wt_base/stash" stash push -q -m other-session
out=$(verify_all "$sbx" "$snap"); rc=$?
assert "other worktree stashing reports drift=false" false "$(printf '%s' "$out" | jq -r .drift)"
assert "other worktree stashing exits 0" 0 "$rc"

# --- Negative controls: the same operations in the reviewed worktree -----------
sbx=$(new_sandbox) && cleanup_dirs+=("$sbx") || exit 1
snap=$(snapshot_line "$sbx")
git -C "$sbx" branch leaked
out=$(verify_all "$sbx" "$snap")
assert "own plain branch is reported as branch_list" '["branch_list"]' "$(printf '%s' "$out" | jq -c .types)"

sbx=$(new_sandbox) && cleanup_dirs+=("$sbx") || exit 1
snap=$(snapshot_line "$sbx")
echo own >> "$sbx/a"
git -C "$sbx" stash push -q -m own
out=$(verify_all "$sbx" "$snap")
assert "own stash is reported as stash" '["stash"]' "$(printf '%s' "$out" | jq -c .types)"

# A reviewer experiment worktree is not another session: a branch it creates counts.
sbx=$(new_sandbox) && cleanup_dirs+=("$sbx") || exit 1
snap=$(snapshot_line "$sbx")
git -C "$sbx" worktree add -q -b review-exp "$wt_base/rite-review-mutation-x" >/dev/null 2>&1 \
  || fail "fixture: worktree add in the reviewer namespace"
out=$(verify_all "$sbx" "$snap")
assert "branch from a reviewer experiment worktree is reported as branch_list" '["branch_list"]' "$(printf '%s' "$out" | jq -c .types)"

# A reviewer-leak branch name is not another session's, wherever its worktree lives.
sbx=$(new_sandbox) && cleanup_dirs+=("$sbx") || exit 1
snap=$(snapshot_line "$sbx")
git -C "$sbx" worktree add -q -b pr-1-test "$wt_base/leak-outside" >/dev/null 2>&1 \
  || fail "fixture: worktree add outside the reviewer namespace"
out=$(verify_all "$sbx" "$snap")
assert "reviewer-leak branch outside the namespace is reported as branch_list" '["branch_list"]' "$(printf '%s' "$out" | jq -c .types)"

sbx=$(new_sandbox) && cleanup_dirs+=("$sbx") || exit 1
snap=$(snapshot_line "$sbx")
git -C "$sbx" worktree add -q -b pr-1-cycle2 "$wt_base/leak-cycle" >/dev/null 2>&1 \
  || fail "fixture: cycle-named worktree add outside the reviewer namespace"
out=$(verify_all "$sbx" "$snap")
assert "cycle-named leak branch outside the namespace is reported as branch_list" '["branch_list"]' "$(printf '%s' "$out" | jq -c .types)"

# The leak-name regex is pr-cycle-cleanup.sh's reap PATTERN, literal for literal.
leak_re_literal() { grep -m1 "$2='" "$1" | sed -E "s/^[^']*'([^']*)'.*/\1/"; }
cleanup_re=$(leak_re_literal "$SCRIPT_DIR/../scripts/pr-cycle-cleanup.sh" "readonly PATTERN")
verify_re=$(leak_re_literal "$VERIFY" _reviewer_leak_re)
[ -n "$cleanup_re" ] || fail "leak names: pr-cycle-cleanup.sh PATTERN not found"
assert "reviewer-leak regex matches pr-cycle-cleanup.sh reap PATTERN" "$cleanup_re" "$verify_re"

# Every place that lists the excluded leak names names each reap alternative.
leak_names=$(printf '%s' "$cleanup_re" | sed -E 's/.*-\((.*)\)\$.*/\1/' | tr '|' '\n' | sed 's/^cycle\[0-9\]+$/cycle<X>/')
for doc in "$VERIFY" \
  "$SCRIPT_DIR/../../agents/_reviewer-base.md" \
  "$SCRIPT_DIR/../../skills/pr-review/references/design-rationale.md" \
  "$SCRIPT_DIR/../../skills/reviewers/references/reviewer-base-rationale.md"; do
  missing=""
  while IFS= read -r n; do
    grep -qF -- "pr-<N>-$n" "$doc" || missing+="$n "
  done <<< "$leak_names"
  assert "leak names listed in ${doc##*/}" "" "$missing"
done

# Reproducing on the base branch stays inside the reviewer namespace, detached.
base_repro=$(grep -m1 'Runtime reproduction on the base branch' "$SCRIPT_DIR/../../agents/_reviewer-base.md")
case "$base_repro" in
  *"worktree add ../"*) base_repro_ok=no ;;
  *"--detach"*"rite-review-mutation-"*) base_repro_ok=yes ;;
  *) base_repro_ok=no ;;
esac
assert "base-branch reproduction uses a detached worktree in the reviewer namespace" yes "$base_repro_ok"

# A stash made on another branch in the reviewed worktree counts after switching back.
sbx=$(new_sandbox) && cleanup_dirs+=("$sbx") || exit 1
git -C "$sbx" branch side
snap=$(snapshot_line "$sbx")
git -C "$sbx" switch -q side
echo side >> "$sbx/a"
git -C "$sbx" stash push -q -m side
git -C "$sbx" switch -q "$(field "$snap" branch)"
out=$(verify_all "$sbx" "$snap")
assert "stash made on another branch of the reviewed worktree is reported as stash" '["stash"]' "$(printf '%s' "$out" | jq -c .types)"

# --- Every changed axis is reported, not just the first one --------------------
sbx=$(new_sandbox) && cleanup_dirs+=("$sbx") || exit 1
snap=$(snapshot_line "$sbx")
echo stashed >> "$sbx/a"
git -C "$sbx" stash push -q -m own
echo edited >> "$sbx/a"
stderr_multi=$(mktemp) && cleanup_dirs+=("$stderr_multi")
out=$(verify_all "$sbx" "$snap" 2>"$stderr_multi"); rc=$?
assert "stash + tracked edit reports both axes in priority order" '["stash","worktree"]' "$(printf '%s' "$out" | jq -c .types)"
assert "type is the first of types" "$(printf '%s' "$out" | jq -r '.types[0]')" "$(printf '%s' "$out" | jq -r .type)"
assert "one 'type:' block per reported axis" 2 "$(grep -c '^  type: ' "$stderr_multi")"
assert "advisory-only drift exits 0" 0 "$rc"

# Branch drift is recovered, and the worktree axis is still judged on the state
# before the recovery switch.
sbx=$(new_sandbox) && cleanup_dirs+=("$sbx") || exit 1
git -C "$sbx" branch side
snap=$(snapshot_line "$sbx")
git -C "$sbx" switch -q side
echo edited >> "$sbx/a"
out=$(verify_all "$sbx" "$snap" --auto-recover true); rc=$?
assert "branch drift + tracked edit reports both axes" '["branch","worktree"]' "$(printf '%s' "$out" | jq -c .types)"
assert "branch drift is recovered" true "$(printf '%s' "$out" | jq -r .recovered)"
assert "recovered branch drift exits 0" 0 "$rc"
assert "recovery leaves HEAD on the original branch, not detached" \
  "$(field "$snap" branch)" "$(git -C "$sbx" branch --show-current)"

# A switch that exits 0 without landing on the original branch is not a recovery.
sbx=$(new_sandbox) && cleanup_dirs+=("$sbx") || exit 1
git -C "$sbx" branch side
snap=$(snapshot_line "$sbx")
git -C "$sbx" switch -q side
noop_shim=$(mktemp -d) && cleanup_dirs+=("$noop_shim")
printf '#!/bin/bash\n[ "$1" = switch ] && exit 0\nexec "%s" "$@"\n' "$(command -v git)" > "$noop_shim/git"
chmod +x "$noop_shim/git"
stderr_noop=$(mktemp) && cleanup_dirs+=("$stderr_noop")
out=$(PATH="$noop_shim:$PATH" verify_all "$sbx" "$snap" --auto-recover true 2>"$stderr_noop"); rc=$?
assert "switch landing elsewhere is not recovered" false "$(printf '%s' "$out" | jq -r .recovered)"
assert "switch landing elsewhere exits 1" 1 "$rc"
assert "switch landing elsewhere reports FAILED" 1 "$(grep -c 'recovery: FAILED' "$stderr_noop")"
assert "switch landing elsewhere does not report success" 0 "$(grep -c 'recovery: succeeded' "$stderr_noop")"
assert "switch landing elsewhere keeps --no-guess in manual action" "git switch --no-guess -- $(field "$snap" branch)" \
  "$(sed -n "s/^  manual action: run '\(.*\)' to restore the working tree$/\1/p" "$stderr_noop")"

# A deleted local branch is not recreated from its remote-tracking branch.
origin_sbx=$(new_sandbox) && cleanup_dirs+=("$origin_sbx") || exit 1
git -C "$origin_sbx" branch feat
sbx=$(mktemp -d) && cleanup_dirs+=("$sbx")
git clone -q "$origin_sbx" "$sbx/clone" && sbx="$sbx/clone"
git -C "$sbx" config user.email t@test.local
git -C "$sbx" config user.name test
git -C "$sbx" switch -q feat
snap=$(snapshot_line "$sbx")
git -C "$sbx" switch -q --detach
git -C "$sbx" branch -q -D feat
stderr_remote=$(mktemp) && cleanup_dirs+=("$stderr_remote")
out=$(verify_all "$sbx" "$snap" --auto-recover true 2>"$stderr_remote"); rc=$?
assert "branch left only on the remote is not recovered" false "$(printf '%s' "$out" | jq -r .recovered)"
assert "branch left only on the remote exits 1" 1 "$rc"
assert "branch left only on the remote is not recreated locally" 1 \
  "$(git -C "$sbx" rev-parse -q --verify refs/heads/feat >/dev/null; echo $?)"
# Following the printed manual action must not recreate the branch from the remote either.
manual_cmd=$(sed -n "s/^  manual action: run '\(.*\)' to restore the working tree$/\1/p" "$stderr_remote")
assert "manual action keeps --no-guess" "git switch --no-guess -- feat" "$manual_cmd"
(cd "$sbx" && eval "$manual_cmd" >/dev/null 2>&1)
assert "following the manual action does not recreate the branch" 1 \
  "$(git -C "$sbx" rev-parse -q --verify refs/heads/feat >/dev/null; echo $?)"

# Option-like branch names stop at validation, before any git ref is touched.
for opt_branch in '--orphan=evil' '-c'; do
  sbx=$(new_sandbox) && cleanup_dirs+=("$sbx") || exit 1
  git -C "$sbx" branch side
  git -C "$sbx" switch -q side
  refs_before=$(git -C "$sbx" for-each-ref refs/heads)
  stderr_opt=$(mktemp) && cleanup_dirs+=("$stderr_opt")
  (cd "$sbx" && bash "$VERIFY" --original-branch "$opt_branch" --auto-recover true >/dev/null 2>"$stderr_opt"); rc=$?
  assert "option-like '$opt_branch' exits 2" 2 "$rc"
  assert "option-like '$opt_branch' is rejected by validation" 1 "$(grep -c 'disallowed characters' "$stderr_opt")"
  assert "option-like '$opt_branch' leaves branches unchanged" "$refs_before" "$(git -C "$sbx" for-each-ref refs/heads)"
  assert "option-like '$opt_branch' leaves HEAD on the current branch" side "$(git -C "$sbx" branch --show-current)"
done

sbx=$(new_sandbox) && cleanup_dirs+=("$sbx") || exit 1
git -C "$sbx" branch side
snap=$(snapshot_line "$sbx")
git -C "$sbx" switch -q side
echo edited >> "$sbx/a"
out=$(verify_all "$sbx" "$snap" --auto-recover false 2>/dev/null); rc=$?
assert "unrecovered branch drift + tracked edit reports both axes" '["branch","worktree"]' "$(printf '%s' "$out" | jq -c .types)"
assert "unrecovered branch drift exits 1" 1 "$rc"

# --- Detached HEAD: sentinel branch and '(no branch)' stash subjects -----------
sbx=$(new_sandbox) && cleanup_dirs+=("$sbx") || exit 1
git -C "$sbx" checkout -q --detach
snap=$(snapshot_line "$sbx")
case "$(field "$snap" branch)" in
  DETACHED:*) pass "detached snapshot uses the DETACHED: sentinel" ;;
  *) fail "detached snapshot uses the DETACHED: sentinel (got: $snap)" ;;
esac
echo detached >> "$sbx/a"
git -C "$sbx" stash push -q -m detached
out=$(verify_all "$sbx" "$snap")
assert "stash made on a detached HEAD is reported as stash" '["stash"]' "$(printf '%s' "$out" | jq -c .types)"

# --- branch_list axis failure skips the axis instead of hashing empty input ----
sbx=$(new_sandbox) && cleanup_dirs+=("$sbx") || exit 1
git_shim=$(mktemp -d) && cleanup_dirs+=("$git_shim")
real_git=$(command -v git)
printf '#!/bin/bash\n[ "$1" = for-each-ref ] && exit 128\nexec "%s" "$@"\n' "$real_git" > "$git_shim/git"
chmod +x "$git_shim/git"
stderr_fer=$(mktemp) && cleanup_dirs+=("$stderr_fer")
snap=$(cd "$sbx" && PATH="$git_shim:$PATH" bash "$VERIFY" --snapshot 2>"$stderr_fer")
assert "for-each-ref failure leaves branch_list_hash empty" "" "$(field "$snap" branch_list_hash)"
assert "for-each-ref failure surfaces a WARNING" 1 "$(grep -c 'branch_list drift axis skipped' "$stderr_fer")"
assert "for-each-ref failure leaves stash_count empty" "" "$(field "$snap" stash_count)"
assert "for-each-ref failure surfaces a stash WARNING" 1 "$(grep -c 'stash drift axis skipped' "$stderr_fer")"
git -C "$sbx" branch leaked
out=$(cd "$sbx" && PATH="$git_shim:$PATH" bash "$VERIFY" --original-branch "$(field "$snap" branch)" \
  --original-branch-list-hash "nonempty-snapshot-hash" 2>/dev/null)
assert "for-each-ref failure does not report branch_list drift" false "$(printf '%s' "$out" | jq -r .drift)"

# --- Snapshot side: filter failure leaves worktree_hash empty ------------------
stderr_snapfail=$(mktemp) && cleanup_dirs+=("$stderr_snapfail")
snap=$(cd "$sbx4" && bash "$fail_dir/post-review-state-verify.sh" --snapshot 2>"$stderr_snapfail"); rc=$?
assert "snapshot filter failure leaves worktree_hash empty" "" "$(field "$snap" worktree_hash)"
assert "snapshot filter failure surfaces a WARNING" 1 "$(grep -c 'git-status-filtered.sh failed' "$stderr_snapfail")"
assert "snapshot filter failure exits 0" 0 "$rc"

print_summary "$(basename "$0")"
