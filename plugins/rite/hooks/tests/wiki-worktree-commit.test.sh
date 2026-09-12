#!/bin/bash
# Tests for hooks/scripts/wiki-worktree-commit.sh
#
# The script stages + commits + pushes pending changes in the .rite/wiki-worktree
# worktree. It has a git push side effect, so the happy-path test wires `origin`
# to a LOCAL bare repo (AC-4): the push lands in that bare repo, never touching a
# real remote or the network. The remaining cases pin the invocation contract and
# the early-exit reasons (wiki-disabled / worktree-missing / no-pending / dry-run).
#
# Convention: mktemp sandbox, no gh, no network, GNU/BSD portable, commit.gpgsign
# disabled locally so fixtures commit under a global signing config.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"

SCRIPT="$SCRIPT_DIR/../scripts/wiki-worktree-commit.sh"

echo "=== wiki-worktree-commit.sh tests ==="

if [ ! -f "$SCRIPT" ]; then
  echo "ERROR: $SCRIPT not found" >&2
  exit 1
fi

SANDBOXES=()
cleanup() {
  local d
  for d in "${SANDBOXES[@]:-}"; do
    # Restore write permission first: an admin dir left read-only by an
    # interrupted sandbox-mask case would make both prune and rm fail.
    [ -n "$d" ] && chmod -R u+w "$d" 2>/dev/null
    # Detach any worktrees before rm so no stale admin entries leak into $HOME.
    [ -n "$d" ] && [ -d "$d" ] && git -C "$d" worktree prune 2>/dev/null || true
    [ -n "$d" ] && rm -rf "$d"
  done
}
trap 'rc=$?; cleanup; exit $rc' EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
trap 'cleanup; exit 129' HUP

# Build a git repo with rite-config.yml (wiki enabled|disabled). Echoes the path.
# The caller MUST register the returned path in SANDBOXES from the PARENT shell —
# this helper runs inside a $(...) command substitution, so a `SANDBOXES+=` here
# would be lost with the subshell (the pitfall _test-helpers.sh documents for
# make_sandbox). Git steps are &&-chained and HEAD is asserted so a broken fixture
# fails loudly instead of returning a half-built repo that silently passes the
# skip-path tests.
new_repo() {
  local enabled="$1" repo
  repo="$(mktemp -d)"
  git -C "$repo" init -q \
    && git -C "$repo" config user.email t@test.local \
    && git -C "$repo" config user.name test \
    && git -C "$repo" config commit.gpgsign false \
    || { echo "FAIL: new_repo git init/config failed" >&2; exit 1; }
  printf 'wiki:\n  enabled: %s\n  branch_name: wiki\n' "$enabled" > "$repo/rite-config.yml"
  git -C "$repo" add rite-config.yml \
    && git -C "$repo" commit -q -m init \
    && git -C "$repo" rev-parse HEAD >/dev/null 2>&1 \
    || { echo "FAIL: new_repo fixture commit failed" >&2; exit 1; }
  printf '%s' "$repo"
}

# Add a `wiki` branch, a local bare "origin", and a wiki-worktree on it.
# Called directly (not in $(...)) so `SANDBOXES+=` reaches the parent and `exit 1`
# aborts the whole run. Git steps are &&-chained and origin/wiki is asserted so a
# failed push cannot degrade the happy-path "advanced" check into an empty-string
# comparison that passes without a real push.
setup_wiki_worktree() {
  local repo="$1" bare
  bare="$(mktemp -d)"; SANDBOXES+=("$bare")
  git -C "$repo" branch wiki \
    && git -C "$bare" init -q --bare \
    && git -C "$repo" remote add origin "$bare" \
    && git -C "$repo" push -q origin wiki \
    && git -C "$repo" worktree add -q "$repo/.rite/wiki-worktree" wiki \
    && git -C "$repo" rev-parse origin/wiki >/dev/null 2>&1 \
    || { echo "FAIL: setup_wiki_worktree failed (branch/bare/remote/push/worktree)" >&2; exit 1; }
}

# Drop an untracked page under the worktree's .rite/wiki tree. NAME defaults
# to test.md (existing single-page callers); pass a distinct NAME per call to
# simulate multiple raw-source pages landing in one ingest run.
add_pending() {
  local repo="$1" name="${2:-test.md}"
  mkdir -p "$repo/.rite/wiki-worktree/.rite/wiki/pages"
  printf '# test page (%s)\n' "$name" > "$repo/.rite/wiki-worktree/.rite/wiki/pages/$name"
}

run_in() { local repo="$1"; shift; ( cd "$repo" && bash "$SCRIPT" "$@" ) 2>/dev/null; }
rc_in()  { local repo="$1"; shift; ( cd "$repo" && bash "$SCRIPT" "$@" >/dev/null 2>&1 ); echo $?; }

# --- Invocation contract (no repo needed) ------------------------------------
# Reuse rc_in() rather than a raw `$(( cd ... ))` — the latter reads as an
# arithmetic-expansion opener (shellcheck SC1102) and errors under POSIX sh.
assert "--help exits 0" "0" "$(bash "$SCRIPT" --help >/dev/null 2>&1; echo $?)"
plain="$(mktemp -d)"; SANDBOXES+=("$plain")
assert "unknown option exits 1" "1" "$(rc_in "$plain" --bogus)"
assert "outside a git repo exits 1" "1" "$(rc_in "$plain")"

# --- Config / worktree preconditions -----------------------------------------
norc_repo="$(mktemp -d)"; SANDBOXES+=("$norc_repo")
git -C "$norc_repo" init -q
assert "rite-config.yml absent exits 1" "1" "$(rc_in "$norc_repo")"

disabled_repo="$(new_repo false)"; SANDBOXES+=("$disabled_repo")
assert "wiki disabled exits 2" "2" "$(rc_in "$disabled_repo")"
# Capture stdout to a variable first: run_in exits 2 here, and `set -o pipefail`
# would make `run_in | grep` report the pipeline as failed even on a grep match.
disabled_out="$(run_in "$disabled_repo")"
if printf '%s' "$disabled_out" | grep -q 'reason=wiki-disabled'; then
  pass "wiki disabled reports reason=wiki-disabled"
else
  fail "wiki-disabled reason line missing: $disabled_out"
fi

missing_wt_repo="$(new_repo true)"; SANDBOXES+=("$missing_wt_repo")
assert "worktree missing exits 1" "1" "$(rc_in "$missing_wt_repo")"

# --- No pending changes → no-op commit=0 -------------------------------------
nopending_repo="$(new_repo true)"; SANDBOXES+=("$nopending_repo")
setup_wiki_worktree "$nopending_repo"
assert "no pending changes exits 0" "0" "$(rc_in "$nopending_repo")"
nopending_out="$(run_in "$nopending_repo")"
if printf '%s' "$nopending_out" | grep -q 'committed=0; branch=wiki; reason=no-pending'; then
  pass "no pending reports committed=0; reason=no-pending"
else
  fail "no-pending status line missing: $nopending_out"
fi

# --- newline --message guard, isolated -----------------------------------
# The header-smuggling guard fires BEFORE the git/worktree checks. Run against a
# fully-built repo where a benign message reaches the no-pending exit 0, so the
# benign=0 / newline=1 differential pins the guard specifically — a bare non-git
# dir would give exit 1 on both (from the not-a-git-repo check) and not isolate it.
assert "benign --message reaches no-pending (exit 0)" "0" "$(rc_in "$nopending_repo" --message "safe message")"
assert "--message with newline is rejected by the guard (exit 1)" "1" \
  "$(rc_in "$nopending_repo" --message "$(printf 'a\nb')")"

# --- Dry-run: reports pending, performs no commit ----------------------------
dryrun_repo="$(new_repo true)"; SANDBOXES+=("$dryrun_repo")
setup_wiki_worktree "$dryrun_repo"
add_pending "$dryrun_repo"
wiki_before_dry="$(git -C "$dryrun_repo" rev-parse wiki)"
dry_out="$(run_in "$dryrun_repo" --dry-run)"
wiki_after_dry="$(git -C "$dryrun_repo" rev-parse wiki)"
assert "dry-run does not advance the wiki branch" "$wiki_before_dry" "$wiki_after_dry"
if printf '%s' "$dry_out" | grep -qE 'dry-run; branch=wiki'; then
  pass "dry-run reports the dry-run status line"
else
  fail "dry-run status line missing: $dry_out"
fi

# --- Happy path: commit + push to LOCAL bare origin (AC-4) --------------------
commit_repo="$(new_repo true)"; SANDBOXES+=("$commit_repo")
setup_wiki_worktree "$commit_repo"
add_pending "$commit_repo"
origin_before="$(git -C "$commit_repo" rev-parse origin/wiki)"
commit_out="$(run_in "$commit_repo")"
if printf '%s' "$commit_out" | grep -qE 'committed=1; branch=wiki;.*push=ok'; then
  pass "pending change is committed and pushed to the local bare origin (push=ok)"
else
  fail "expected committed=1 + push=ok; got: $commit_out"
fi
origin_after="$(git -C "$commit_repo" rev-parse origin/wiki)"
assert "local bare origin/wiki advanced (push landed, no network)" \
  "advanced" \
  "$([ "$origin_before" != "$origin_after" ] && echo advanced || echo unchanged)"
# The committed page is now tracked on the wiki branch.
if git -C "$commit_repo" ls-tree -r --name-only wiki | grep -q '.rite/wiki/pages/test.md'; then
  pass "committed page is tracked on the wiki branch"
else
  fail "committed page not found on wiki branch"
fi

# --- --commit-only / --push-only: batch/defer push -------------------
# AC-1: a caller processing several raw sources commits each one locally
# (--commit-only) and pushes ONCE (--push-only) instead of once per commit.

# --commit-only lands the commit locally but does NOT push (origin/wiki stays put).
commitonly_repo="$(new_repo true)"; SANDBOXES+=("$commitonly_repo")
setup_wiki_worktree "$commitonly_repo"
add_pending "$commitonly_repo" page1.md
origin_before_co="$(git -C "$commitonly_repo" rev-parse origin/wiki)"
co_out="$(run_in "$commitonly_repo" --commit-only)"
if printf '%s' "$co_out" | grep -qE 'committed=1; branch=wiki;.*push=deferred'; then
  pass "--commit-only reports committed=1 + push=deferred"
else
  fail "expected committed=1 + push=deferred; got: $co_out"
fi
origin_after_co="$(git -C "$commitonly_repo" rev-parse origin/wiki)"
assert "--commit-only does not advance origin/wiki (push deferred, 0 pushes)" \
  "$origin_before_co" "$origin_after_co"
wiki_after_co="$(git -C "$commitonly_repo" rev-parse wiki)"
assert "--commit-only advances the local wiki branch" \
  "advanced" \
  "$([ "$origin_before_co" != "$wiki_after_co" ] && echo advanced || echo unchanged)"

# --push-only then pushes what --commit-only landed locally.
po_out="$(run_in "$commitonly_repo" --push-only)"
if printf '%s' "$po_out" | grep -qE 'branch=wiki;.*push=ok'; then
  pass "--push-only reports push=ok"
else
  fail "expected push=ok; got: $po_out"
fi
origin_after_po="$(git -C "$commitonly_repo" rev-parse origin/wiki)"
assert "--push-only advances origin/wiki to match local wiki HEAD" \
  "$wiki_after_co" "$origin_after_po"

# A second --push-only with nothing new to send self-gates to no-op (no network call).
noop_out="$(run_in "$commitonly_repo" --push-only)"
if printf '%s' "$noop_out" | grep -qE 'push=no-op'; then
  pass "--push-only self-gates to push=no-op when nothing is ahead of origin"
else
  fail "expected push=no-op on a second --push-only call; got: $noop_out"
fi

# --- commit-only x N then push-only x 1 -> exactly one push lands all N commits ---
# (AC-1 proxy: count actual `git push` invocations landing on the bare
# origin via a post-receive hook, rather than inferring it from script output.)
countpush_repo="$(new_repo true)"; SANDBOXES+=("$countpush_repo")
setup_wiki_worktree "$countpush_repo"
bare_dir="$(git -C "$countpush_repo" remote get-url origin)"
push_count_file="$(mktemp)"; SANDBOXES+=("$push_count_file")
cat > "$bare_dir/hooks/post-receive" <<HOOK
#!/bin/sh
echo push >> "$push_count_file"
HOOK
chmod +x "$bare_dir/hooks/post-receive"

for i in 1 2 3; do
  add_pending "$countpush_repo" "page-$i.md"
  run_in "$countpush_repo" --commit-only --message "chore(wiki): page $i" >/dev/null
done
run_in "$countpush_repo" --push-only >/dev/null

push_events="$(wc -l < "$push_count_file" | tr -d '[:space:]')"
assert "3 commit-only commits + 1 push-only call -> exactly 1 push lands (AC-1)" \
  "1" "$push_events"
pages_on_wiki="$(git -C "$countpush_repo" ls-tree -r --name-only wiki | grep -c '\.rite/wiki/pages/page-' || true)"
assert "all 3 commit-only commits are present on the wiki branch" "3" "$pages_on_wiki"
assert "origin/wiki matches local wiki HEAD after the single push" \
  "$(git -C "$countpush_repo" rev-parse wiki)" "$(git -C "$countpush_repo" rev-parse origin/wiki)"

# --- --push-only failure (non-NFF): local commit survives, exit 4, no retry ---
# (AC-2/AC-3: a failed deferred push does not lose the local commit and
# is not auto-retried within the same call. The "no retry on non-NFF" internal
# behavior itself is already pinned at the lib level by
# worktree-git-nff-retry.test.sh TC-3; this test pins the wiki-worktree-commit.sh
# integration contract: push=failed + local commit preserved.)
pushfail_repo="$(new_repo true)"; SANDBOXES+=("$pushfail_repo")
setup_wiki_worktree "$pushfail_repo"
bogus_origin="$(mktemp -d)"; SANDBOXES+=("$bogus_origin")
git -C "$pushfail_repo" remote set-url origin "$bogus_origin"
add_pending "$pushfail_repo" pageX.md
run_in "$pushfail_repo" --commit-only >/dev/null
wiki_head_before_push="$(git -C "$pushfail_repo" rev-parse wiki)"
pf_out="$(run_in "$pushfail_repo" --push-only)"; pf_rc=$?
assert "--push-only against an unreachable origin exits 4" "4" "$pf_rc"
if printf '%s' "$pf_out" | grep -qE 'push=failed'; then
  pass "--push-only reports push=failed for a non-NFF failure"
else
  fail "expected push=failed; got: $pf_out"
fi
wiki_head_after_push="$(git -C "$pushfail_repo" rev-parse wiki)"
assert "local wiki commit survives a failed deferred push" \
  "$wiki_head_before_push" "$wiki_head_after_push"

# --- --commit-only / --push-only mutual exclusivity + --dry-run guard --------
assert "--commit-only and --push-only together exits 1" "1" \
  "$(rc_in "$nopending_repo" --commit-only --push-only)"
assert "--push-only with --dry-run exits 1" "1" \
  "$(rc_in "$nopending_repo" --push-only --dry-run)"

# --- numref pre-commit gate -------------------------------------------------
add_pending_numref() {
  local repo="$1" name="${2:-numref.md}"
  mkdir -p "$repo/.rite/wiki-worktree/.rite/wiki/pages"
  printf 'PR #1300 in wiki page\n' > "$repo/.rite/wiki-worktree/.rite/wiki/pages/$name"
}

numref_repo="$(new_repo true)"; SANDBOXES+=("$numref_repo")
setup_wiki_worktree "$numref_repo"
add_pending_numref "$numref_repo"
wiki_before_nr="$(git -C "$numref_repo" rev-parse wiki)"
nr_out="$(run_in "$numref_repo")"
nr_rc="$(rc_in "$numref_repo")"
assert "numref pending default invoke exits 1" "1" "$nr_rc"
if printf '%s' "$nr_out" | grep -qE '\[wiki-worktree-commit\] committed=0; branch=wiki; reason=numref-hit'; then
  pass "numref pending default invoke reports committed=0 reason=numref-hit on stdout"
else
  fail "expected stdout committed=0; reason=numref-hit; got: $nr_out"
fi
wiki_after_nr="$(git -C "$numref_repo" rev-parse wiki)"
assert "numref pending does not advance wiki HEAD" "$wiki_before_nr" "$wiki_after_nr"
if git -C "$numref_repo" ls-tree -r --name-only wiki | grep -q 'numref.md'; then
  fail "numref page must not be tracked on wiki after a refused commit"
else
  pass "numref page is not tracked on wiki after a refused commit"
fi

numref_co_repo="$(new_repo true)"; SANDBOXES+=("$numref_co_repo")
setup_wiki_worktree "$numref_co_repo"
add_pending_numref "$numref_co_repo" page-co.md
wiki_before_co_nr="$(git -C "$numref_co_repo" rev-parse wiki)"
co_nr_out="$(run_in "$numref_co_repo" --commit-only)"
co_nr_rc="$(rc_in "$numref_co_repo" --commit-only)"
assert "numref pending --commit-only exits 1" "1" "$co_nr_rc"
if printf '%s' "$co_nr_out" | grep -qE '\[wiki-worktree-commit\] committed=0; branch=wiki; reason=numref-hit'; then
  pass "numref --commit-only reports committed=0 reason=numref-hit on stdout"
else
  fail "expected --commit-only committed=0; reason=numref-hit; got: $co_nr_out"
fi
assert "numref --commit-only does not advance wiki HEAD" \
  "$wiki_before_co_nr" "$(git -C "$numref_co_repo" rev-parse wiki)"
if git -C "$numref_co_repo" ls-tree -r --name-only wiki | grep -q 'page-co.md'; then
  fail "numref --commit-only must not land the page on wiki"
else
  pass "numref --commit-only does not land the page on wiki"
fi

# helper rc=2 (ignored_paths): a tracked wiki edit makes has_changes=true, while
# a nested .rite/.gitignore (`*` / `!wiki/` without `!wiki/**`) leaves an
# untracked wiki file ignored. Pending detection still sees the tracked edit;
# the helper then fail-louds on the ignored residue.
numref_err_repo="$(new_repo true)"; SANDBOXES+=("$numref_err_repo")
setup_wiki_worktree "$numref_err_repo"
add_pending "$numref_err_repo" tracked.md
run_in "$numref_err_repo" --commit-only >/dev/null
mkdir -p "$numref_err_repo/.rite/wiki-worktree/.rite"
printf '*\n!wiki/\n' > "$numref_err_repo/.rite/wiki-worktree/.rite/.gitignore"
printf 'PR #1300 ignored residue\n' > "$numref_err_repo/.rite/wiki-worktree/.rite/wiki/pages/ignored.md"
printf 'tracked edit\n' >> "$numref_err_repo/.rite/wiki-worktree/.rite/wiki/pages/tracked.md"
wiki_before_err="$(git -C "$numref_err_repo" rev-parse wiki)"
err_out="$(run_in "$numref_err_repo" --commit-only)"
err_rc="$(rc_in "$numref_err_repo" --commit-only)"
assert "numref-error --commit-only exits 1" "1" "$err_rc"
if printf '%s' "$err_out" | grep -qE '\[wiki-worktree-commit\] committed=0; branch=wiki; reason=numref-error'; then
  pass "helper error reports committed=0 reason=numref-error on stdout"
else
  fail "expected reason=numref-error; got: $err_out"
fi
assert "numref-error does not advance wiki HEAD" \
  "$wiki_before_err" "$(git -C "$numref_err_repo" rev-parse wiki)"

# --dry-run with numbered pending must not call the helper (no intent-to-add)
dry_nr_repo="$(new_repo true)"; SANDBOXES+=("$dry_nr_repo")
setup_wiki_worktree "$dry_nr_repo"
add_pending_numref "$dry_nr_repo" dry.md
wiki_before_dry_nr="$(git -C "$dry_nr_repo" rev-parse wiki)"
others_before=$(git -C "$dry_nr_repo/.rite/wiki-worktree" ls-files --others --exclude-standard -- .rite/wiki)
dry_nr_out="$(run_in "$dry_nr_repo" --dry-run)"
dry_nr_rc="$(rc_in "$dry_nr_repo" --dry-run)"
assert "dry-run with numref pending exits 0" "0" "$dry_nr_rc"
assert "dry-run with numref pending does not advance wiki" \
  "$wiki_before_dry_nr" "$(git -C "$dry_nr_repo" rev-parse wiki)"
others_after=$(git -C "$dry_nr_repo/.rite/wiki-worktree" ls-files --others --exclude-standard -- .rite/wiki)
assert "dry-run does not intent-to-add (helper not called)" "$others_before" "$others_after"
if printf '%s' "$dry_nr_out" | grep -qE 'dry-run; branch=wiki'; then
  pass "dry-run with numref pending still reports dry-run status"
else
  fail "dry-run status missing with numref pending: $dry_nr_out"
fi

# --- admin dir read-only (sandbox mask) ---------------------------------------
# A sandbox can mount the worktree's admin dir read-only while the working tree
# stays writable. Paths that write nothing there (no-pending / --push-only /
# --dry-run) keep their results; the commit path stops with reason=sandbox-mask
# / exit 6 before the numref gate stages anything.
if [ "$(id -u)" = "0" ]; then
  skip "admin dir read-only cases (root ignores directory write permission)"
else
  mask_repo="$(new_repo true)"; SANDBOXES+=("$mask_repo")
  setup_wiki_worktree "$mask_repo"
  mask_wt="$mask_repo/.rite/wiki-worktree"
  mask_admin="$(git -C "$mask_wt" rev-parse --absolute-git-dir)"
  mask_io="$(mktemp -d)"; SANDBOXES+=("$mask_io")
  run_masked() {
    local rc=0
    chmod a-w "$mask_admin"
    ( cd "$mask_repo" && bash "$SCRIPT" "$@" ) >"$mask_io/out" 2>"$mask_io/err" || rc=$?
    chmod u+w "$mask_admin"
    return "$rc"
  }

  mask_rc=0; run_masked --commit-only || mask_rc=$?
  assert "read-only admin dir + no pending exits 0" "0" "$mask_rc"
  assert_grep "read-only admin dir + no pending still reports reason=no-pending" "$mask_io/out" 'reason=no-pending'

  mask_rc=0; run_masked --push-only || mask_rc=$?
  assert "read-only admin dir + --push-only (nothing ahead) exits 0" "0" "$mask_rc"
  assert_grep "--push-only does not probe the admin dir (push=no-op)" "$mask_io/out" 'push=no-op'
  assert_not_grep "--push-only never reports sandbox-mask" "$mask_io/out" 'sandbox-mask'

  add_pending_numref "$mask_repo" mask.md
  mask_rc=0; run_masked --dry-run || mask_rc=$?
  assert "read-only admin dir + --dry-run exits 0" "0" "$mask_rc"
  assert_grep "--dry-run still reports the dry-run status line" "$mask_io/out" 'dry-run; branch=wiki'

  others_before_mask=$(git -C "$mask_wt" ls-files --others --exclude-standard -- .rite/wiki)
  wiki_before_mask="$(git -C "$mask_repo" rev-parse wiki)"
  mask_rc=0; run_masked --commit-only || mask_rc=$?
  assert "read-only admin dir + pending exits 6" "6" "$mask_rc"
  assert_grep "pending with read-only admin dir reports reason=sandbox-mask" "$mask_io/out" \
    '^\[wiki-worktree-commit\] committed=0; branch=wiki; reason=sandbox-mask$'
  assert_not_grep "sandbox-mask is reported before the numref gate" "$mask_io/out" 'numref-'
  assert_grep "stderr names the unwritable admin dir" "$mask_io/err" "管理ディレクトリ（${mask_admin}）に書き込めません"
  assert "sandbox-mask stages nothing (numref helper not called)" "$others_before_mask" \
    "$(git -C "$mask_wt" ls-files --others --exclude-standard -- .rite/wiki)"
  assert "sandbox-mask does not advance the wiki branch" "$wiki_before_mask" "$(git -C "$mask_repo" rev-parse wiki)"
  assert "the write probe leaves no file in the admin dir" "0" \
    "$(find "$mask_admin" -maxdepth 1 -name 'rite-write-probe.*' | wc -l | tr -d '[:space:]')"
fi

print_summary "wiki-worktree-commit.sh"
