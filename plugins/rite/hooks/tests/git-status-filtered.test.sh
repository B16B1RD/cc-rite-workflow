#!/bin/bash
# Tests for lib/git-status-filtered.sh
#
# The Bash tool sandbox blocks writes to certain paths (.bashrc,
# .claude/agents, .gitconfig, etc.) by bind-mounting /dev/null over them.
# These mounts are persistent character-device files, invisible to the
# harness's own git-status snapshot but visible from inside the Bash tool,
# so they show up as spurious `??` (untracked) entries in every
# `git status --porcelain` a sandboxed Bash command runs — even though
# nothing in the working tree actually changed. Once the sandboxed command
# exits, the mount anchors stay behind as 0-byte regular files with every
# write bit cleared (stubs), which a non-sandboxed caller such as the
# session-start reaper sees as plain `??` entries. lib/git-status-filtered.sh
# strips exactly those two shapes (untracked character device via `test -c`,
# untracked 0-byte no-write regular file via `find -perm`; never a filename
# allowlist) while passing every other status code through unchanged.
#
# mknod requires root/CAP_MKNOD and is unavailable in this (and most CI)
# environments, so tests simulate a "character device at this path" with a
# symlink to /dev/null (`ln -s /dev/null <path>`) instead of a real device
# node. `test -c` follows symlinks (like stat, not lstat), so this is
# behaviorally identical to the real sandbox mount for the one property the
# script inspects, and `git status --porcelain` reports it as an ordinary
# `??` entry exactly like the genuine ghost mount.
#
# Convention: standalone subprocess (`bash lib/git-status-filtered.sh`),
# not sourced — mirrors git-remote-resolve.test.sh's invocation style for
# the sibling lib/git-remote.sh standalone subcommand.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"

LIB="$SCRIPT_DIR/../scripts/lib/git-status-filtered.sh"

echo "=== git-status-filtered.sh (untracked character-device ghost mount + leftover stub filter) ==="

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

run_in() {
  local dir="$1"
  ( cd "$dir" && bash "$LIB" )
}

# --- T-01 (AC-1): character device untracked-only tree filters to empty --
sbx1=$(make_sandbox) && cleanup_dirs+=("$sbx1") || { echo "ERROR: make_sandbox failed, aborting" >&2; exit 1; }
( cd "$sbx1" && ln -s /dev/null ghost_devnull ) >/dev/null 2>&1
out=$(run_in "$sbx1"); rc=$?
assert "T-01: exit 0" "0" "$rc"
assert "T-01: output empty (ghost entry dropped)" "" "$out"

# --- T-02 (AC-1 + AC-2): real untracked file survives, ghost is dropped ---
sbx2=$(make_sandbox) && cleanup_dirs+=("$sbx2") || { echo "ERROR: make_sandbox failed, aborting" >&2; exit 1; }
( cd "$sbx2" && ln -s /dev/null ghost_devnull && echo new > real_untracked.txt ) >/dev/null 2>&1
out=$(run_in "$sbx2"); rc=$?
assert "T-02: exit 0" "0" "$rc"
assert "T-02: real untracked file present" "?? real_untracked.txt" "$out"
case "$out" in
  *ghost_devnull*) fail "T-02: ghost entry must not appear in output" ;;
  *) pass "T-02: ghost entry absent from output" ;;
esac

# --- T-03 (AC-3): staged / unstaged / unmerged entries pass through as-is -
sbx3=$(make_sandbox) && cleanup_dirs+=("$sbx3") || { echo "ERROR: make_sandbox failed, aborting" >&2; exit 1; }
base_branch=$( cd "$sbx3" && git branch --show-current )
(
  cd "$sbx3" || exit 1
  echo modified >> a
  echo staged > staged.txt
  git add staged.txt
) >/dev/null 2>&1
out=$(run_in "$sbx3")
case "$out" in
  *"A  staged.txt"*) pass "T-03: staged (A ) entry passes through" ;;
  *) fail "T-03: staged (A ) entry passes through (got: $out)" ;;
esac
case "$out" in
  *" M a"*) pass "T-03: unstaged ( M) entry passes through" ;;
  *) fail "T-03: unstaged ( M) entry passes through (got: $out)" ;;
esac

# unmerged (UU): diverge on a branch, then merge to force a conflict on "a"
sbx3u=$(make_sandbox) && cleanup_dirs+=("$sbx3u") || { echo "ERROR: make_sandbox failed, aborting" >&2; exit 1; }
base3u=$( cd "$sbx3u" && git branch --show-current )
(
  cd "$sbx3u" || exit 1
  git checkout -q -b conflict-side
  echo side > a
  git -c user.email=t@test.local -c user.name=test commit -q -am side
  git checkout -q "$base3u"
  echo main > a
  git -c user.email=t@test.local -c user.name=test commit -q -am main
  git -c user.email=t@test.local -c user.name=test merge conflict-side >/dev/null 2>&1
) >/dev/null 2>&1
out=$(run_in "$sbx3u")
case "$out" in
  *"UU a"*) pass "T-03: unmerged (UU) entry passes through" ;;
  *) fail "T-03: unmerged (UU) entry passes through (got: $out)" ;;
esac

# --- Rename pass-through: -z's two-field rename record reassembles as "R  old -> new"
sbx_ren=$(make_sandbox) && cleanup_dirs+=("$sbx_ren") || { echo "ERROR: make_sandbox failed, aborting" >&2; exit 1; }
( cd "$sbx_ren" && git mv a b ) >/dev/null 2>&1
out=$(run_in "$sbx_ren")
assert "rename: reassembled as 'R  a -> b'" "R  a -> b" "$out"

# --- Clean tree: no entries at all -> empty output, exit 0 ------------------
sbx_clean=$(make_sandbox) && cleanup_dirs+=("$sbx_clean") || { echo "ERROR: make_sandbox failed, aborting" >&2; exit 1; }
out=$(run_in "$sbx_clean"); rc=$?
assert "clean tree: exit 0" "0" "$rc"
assert "clean tree: empty output" "" "$out"

# --- Failure path: not a git repository -> non-zero exit, WARNING on stderr,
#     empty stdout (script must not silently report a "clean" tree) --------
plain=$(make_plain_sandbox) && cleanup_dirs+=("$plain") || { echo "ERROR: make_plain_sandbox failed, aborting" >&2; exit 1; }
err_capture=$(mktemp) || { echo "ERROR: mktemp failed, aborting" >&2; exit 1; }
out=$( cd "$plain" && bash "$LIB" 2>"$err_capture" )
rc=$?
err=$(cat "$err_capture" 2>/dev/null); rm -f "$err_capture"
assert "not-a-repo: non-zero exit" "1" "$( [ "$rc" -ne 0 ] && echo 1 || echo 0 )"
assert "not-a-repo: empty stdout" "" "$out"
case "$err" in
  *"WARNING: git-status-filtered"*) pass "not-a-repo: WARNING emitted on stderr" ;;
  *) fail "not-a-repo: WARNING emitted on stderr (got: $err)" ;;
esac

# Tracked-only output excludes arbitrary untracked paths, with escaped names.
mode_repo=$(make_sandbox) && cleanup_dirs+=("$mode_repo") || exit 1
mode_err=$(mktemp) && cleanup_dirs+=("$mode_err") || exit 1
mkdir "$mode_repo/subdir"
printf content > "$mode_repo/subdir/plain.txt"
touch "$mode_repo/.empty" "$mode_repo/"$'line\nbreak'
out=$(cd "$mode_repo" && bash "$LIB" --tracked-only 2>"$mode_err"); rc=$?
assert "tracked-only untracked tree succeeds" 0 "$rc"
assert "tracked-only untracked tree has empty stdout" "" "$out"
assert "warning counts individual paths" 1 "$(grep -c 'WARNING:.*3 untracked path(s)' "$mode_err")"
assert "warning keeps names on one escaped line" 1 "$(wc -l < "$mode_err" | tr -d ' ')"
for name in .empty subdir/plain.txt $'line\nbreak'; do
  printf -v quoted '%q' "$name"
  assert "warning includes escaped name $quoted" 1 "$(grep -Fc " $quoted" "$mode_err")"
done
for repo in "$sbx3" "$sbx3u" "$sbx_ren"; do
  expected=$(run_in "$repo")
  out=$(cd "$repo" && bash "$LIB" --tracked-only)
  assert "tracked-only preserves staged / unstaged / conflict / rename status" "$expected" "$out"
done
out=$(cd "$plain" && bash "$LIB" --tracked-only 2>"$mode_err"); rc=$?
assert "tracked-only failure remains nonzero" 1 "$rc"

# --- Leftover sandbox stubs (0-byte regular file, no write bit) ---------------
# make_mode_file <path> <octal mode> [content]: creates the fixture and stops
# the run when the filesystem did not keep the mode or size, since every stub
# assertion below would otherwise pass or fail for the wrong reason.
make_mode_file() {
  local path="$1" mode="$2" content="${3:-}"
  printf '%s' "$content" > "$path" && chmod "$mode" "$path" || { echo "ERROR: cannot create fixture $path" >&2; exit 1; }
  [ -n "$(find "$path" -prune -type f -perm "$mode" -size "${#content}c")" ] \
    || { echo "ERROR: fixture $path did not keep mode $mode / size ${#content} (filesystem does not keep modes?)" >&2; exit 1; }
}
run_with_err() {
  local dir="$1"; shift
  ( cd "$dir" && bash "$LIB" "$@" 2>"$err_file" )
}
err_file=$(mktemp) && cleanup_dirs+=("$err_file") || exit 1

stub_repo=$(make_sandbox) && cleanup_dirs+=("$stub_repo") || exit 1
make_mode_file "$stub_repo/.bashrc" 0444
make_mode_file "$stub_repo/"$'stub\nnewline' 0444
out=$(run_with_err "$stub_repo"); rc=$?
assert "stub-only tree: exit 0" 0 "$rc"
assert "stub-only tree: stdout is empty" "" "$out"
assert "stub exclusion warning is a single line" 1 "$(wc -l < "$err_file" | tr -d ' ')"
assert "stub exclusion warning counts each stub" 1 "$(grep -c 'WARNING: git-status-filtered: 2 sandbox stub file(s)' "$err_file")"
for name in .bashrc $'stub\nnewline'; do
  printf -v quoted '%q' "$name"
  assert "stub exclusion warning names $quoted" 1 "$(grep -Fc " $quoted" "$err_file")"
done

out=$(run_with_err "$sbx_clean")
assert "clean tree: stderr stays empty" "" "$(cat "$err_file")"
out=$(run_with_err "$sbx1")
assert "character-device-only tree: stdout stays empty" "" "$out"
assert "character-device-only tree: stderr stays empty" "" "$(cat "$err_file")"

mixed_repo=$(make_sandbox) && cleanup_dirs+=("$mixed_repo") || exit 1
make_mode_file "$mixed_repo/.gitconfig" 0444
make_mode_file "$mixed_repo/real_untracked.txt" 0644 content
out=$(run_with_err "$mixed_repo")
assert "stub next to a real untracked file: only the real file remains" "?? real_untracked.txt" "$out"

keep_repo=$(make_sandbox) && cleanup_dirs+=("$keep_repo") || exit 1
make_mode_file "$keep_repo/empty_writable" 0644
make_mode_file "$keep_repo/readonly_with_content" 0444 content
make_mode_file "$keep_repo/empty_group_writable" 0464
make_mode_file "$keep_repo/empty_other_writable" 0446
make_mode_file "$keep_repo/empty_owner_read_only" 0440
stub_target_dir=$(make_plain_sandbox) && cleanup_dirs+=("$stub_target_dir") || exit 1
make_mode_file "$stub_target_dir/stub" 0444
ln -s "$stub_target_dir/stub" "$keep_repo/link_to_stub"
out=$(run_with_err "$keep_repo")
for kept in empty_writable readonly_with_content empty_group_writable empty_other_writable link_to_stub; do
  case "$out" in
    *"?? $kept"*) pass "$kept stays in the output" ;;
    *) fail "$kept stays in the output (got: $out)" ;;
  esac
done
case "$out" in
  *empty_owner_read_only*) fail "0-byte file without any write bit is excluded (got: $out)" ;;
  *) pass "0-byte file without any write bit is excluded" ;;
esac

# Only untracked entries can be stubs: a tracked file emptied to the stub shape
# and a staged new file with the stub shape are real changes.
tracked_stub_repo=$(make_sandbox) && cleanup_dirs+=("$tracked_stub_repo") || exit 1
make_mode_file "$tracked_stub_repo/a" 0444
make_mode_file "$tracked_stub_repo/staged_stub" 0444
(cd "$tracked_stub_repo" && git add staged_stub) || { echo "ERROR: cannot stage staged_stub" >&2; exit 1; }
out=$(run_with_err "$tracked_stub_repo")
assert "stub-shaped tracked and staged files stay in the output" " M a"$'\n'"A  staged_stub" "$out"
assert "no stub exclusion warning for tracked or staged files" 0 "$(grep -c 'sandbox stub' "$err_file")"

# A stub whose file information cannot be read stays in the output. The
# control run proves the fixture is a stub first, so the failing-find run
# cannot pass on a fixture that was never excluded.
unreadable_repo=$(make_sandbox) && cleanup_dirs+=("$unreadable_repo") || exit 1
make_mode_file "$unreadable_repo/.profile" 0444
out=$(run_with_err "$unreadable_repo")
assert "control: the stub is excluded while find works" "" "$out"
failing_bin=$(make_plain_sandbox) && cleanup_dirs+=("$failing_bin") || exit 1
printf '#!/bin/sh\nexit 1\n' > "$failing_bin/find" && chmod +x "$failing_bin/find"
out=$(cd "$unreadable_repo" && PATH="$failing_bin:$PATH" bash "$LIB" 2>"$err_file")
assert "stub stays in the output when its file information cannot be read" "?? .profile" "$out"
assert "no stub exclusion warning when nothing was excluded" 0 "$(grep -c 'sandbox stub' "$err_file")"

# --tracked-only keeps its own contract: stubs count as untracked paths there.
out=$(cd "$mixed_repo" && bash "$LIB" --tracked-only 2>"$err_file"); rc=$?
assert "tracked-only with stubs: exit 0" 0 "$rc"
assert "tracked-only with stubs: stdout is empty" "" "$out"
assert "tracked-only with stubs: one warning line" 1 "$(wc -l < "$err_file" | tr -d ' ')"
assert "tracked-only with stubs: stub counted as untracked" 1 "$(grep -c 'WARNING:.*2 untracked path(s)' "$err_file")"
assert "tracked-only with stubs: no stub exclusion warning" 0 "$(grep -c 'sandbox stub' "$err_file")"

# Exercise the actual fix commit guard, including its failure fallback.
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"
guard=$(awk '/^### 3\.1 Verify Changes/{section=1;next} section && /^```bash$/{code=1;next} code && /^```$/{exit} code{print}' "$PLUGIN_ROOT/skills/fix/SKILL.md")
[ -n "$guard" ] || { echo "ERROR: fix guard block missing" >&2; exit 1; }
guard=${guard//\{plugin_root\}/$PLUGIN_ROOT}
out=$(cd "$mode_repo" && eval "$guard" 2>&1)
assert "fix guard skips untracked-only changes" 1 "$(printf '%s' "$out" | grep -c 'FIX_COMMIT_GUARD=skip; reason=worktree_clean')"
(cd "$mode_repo" && git add -- subdir/plain.txt)
out=$(cd "$mode_repo" && eval "$guard" 2>&1)
assert "fix guard proceeds for staged new file alongside untracked" 1 "$(printf '%s' "$out" | grep -c 'FIX_COMMIT_GUARD=proceed; reason=worktree_dirty')"
out=$(cd "$plain" && eval "$guard" 2>&1)
assert "fix guard reports status_unknown on helper failure" 1 "$(printf '%s' "$out" | grep -c 'FIX_COMMIT_GUARD=proceed; reason=status_unknown')"

print_summary "$(basename "$0")"
