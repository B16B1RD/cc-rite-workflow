#!/bin/bash
# Tests for state-path-resolve.sh linked-worktree awareness.
#
# Covers the multi-session design §1 contract:
#   - Non-worktree sessions: resolver output is BYTE-IDENTICAL to the legacy
#     `git rev-parse --show-toplevel` (backward-compat pin — AC-1).
#   - Linked-worktree sessions: resolver returns the MAIN checkout root so that
#     rite state / locks / wiki-worktree unify on a single inode (AC-2).
#   - git < 2.31 (no `--path-format=absolute`): the cd+pwd fallback still
#     resolves a worktree to the main root (V-6).
#   - Non-git cwd: fails without stdout or state writes.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"

RESOLVER="$SCRIPT_DIR/../state-path-resolve.sh"

cleanup_dirs=()
# `return 0` so an empty array (loop body `[ -n "" ]` → rc 1) cannot leak into the
# script exit code via the EXIT trap.
cleanup() { local d; for d in "${cleanup_dirs[@]:-}"; do [ -n "$d" ] && rm -rf "$d"; done; return 0; }
trap cleanup EXIT

# --- Build a main checkout + a linked worktree -------------------------------
MAIN=$(make_sandbox --branch develop)
cleanup_dirs+=("$MAIN")
# git worktree add needs the worktree dir to NOT pre-exist; place it as a sibling.
WT="${MAIN}-wt-issue-99"
if ! git -C "$MAIN" worktree add -q -b feat/issue-99 "$WT" >/dev/null 2>&1; then
  echo "ERROR: git worktree add failed; cannot run S1 worktree tests" >&2
  exit 1
fi
cleanup_dirs+=("$WT")

echo "=== T-1: non-worktree resolver output is byte-identical (AC-1 pin) ==="
LEGACY=$(cd "$MAIN" && git rev-parse --show-toplevel)
RESOLVED=$(bash "$RESOLVER" "$MAIN")
assert "T-1 non-worktree byte-identical to show-toplevel" "$LEGACY" "$RESOLVED"

echo "=== T-2: linked worktree resolves to main checkout root (AC-2) ==="
RESOLVED_WT=$(bash "$RESOLVER" "$WT")
assert "T-2 worktree -> main root" "$MAIN" "$RESOLVED_WT"

echo "=== T-3: subdir inside worktree also resolves to main root ==="
mkdir -p "$WT/sub/deep"
RESOLVED_SUB=$(bash "$RESOLVER" "$WT/sub/deep")
assert "T-3 worktree subdir -> main root" "$MAIN" "$RESOLVED_SUB"

echo "=== T-4: non-git cwd fails ==="
PLAIN=$(make_plain_sandbox)
cleanup_dirs+=("$PLAIN")
plain_rc=0
RESOLVED_PLAIN=$(bash "$RESOLVER" "$PLAIN" 2>"$PLAIN/resolver.err") || plain_rc=$?
assert "T-4 non-git resolver fails" "1" "$plain_rc"
assert "T-4 stdout empty" "" "$RESOLVED_PLAIN"
assert_grep "T-4 diagnostic" "$PLAIN/resolver.err" "state root unresolved"

echo "=== T-5: git < 2.31 fallback (no --path-format=absolute) still unifies (V-6) ==="
# Shim a `git` that rejects `--path-format` (simulating pre-2.31) but proxies
# every other invocation to the real git. This forces resolve_state_root onto
# its cd+pwd normalization path.
SHIM=$(make_plain_sandbox)
cleanup_dirs+=("$SHIM")
REAL_GIT=$(command -v git)
cat > "$SHIM/git" <<SHIM_EOF
#!/bin/bash
for a in "\$@"; do
  case "\$a" in
    --path-format*) echo "error: unknown option \$a (shim: simulated git<2.31)" >&2; exit 129 ;;
  esac
done
exec "$REAL_GIT" "\$@"
SHIM_EOF
chmod +x "$SHIM/git"
RESOLVED_OLDGIT=$(PATH="$SHIM:$PATH" bash "$RESOLVER" "$WT")
assert "T-5 worktree -> main root under git<2.31 fallback" "$MAIN" "$RESOLVED_OLDGIT"
# And the shim must NOT change the non-worktree byte-identical result.
RESOLVED_OLDGIT_MAIN=$(PATH="$SHIM:$PATH" bash "$RESOLVER" "$MAIN")
assert "T-5 non-worktree byte-identical under git<2.31 fallback" "$MAIN" "$RESOLVED_OLDGIT_MAIN"

echo "=== Hook and writer boundaries outside git ==="
HOOKS="$SCRIPT_DIR/.."
for hook in session-start.sh stop-loop-continuation.sh session-end.sh pre-compact.sh post-compact.sh post-tool-wm-sync.sh; do
  payload=$(jq -n --arg cwd "$PLAIN" '{cwd:$cwd,session_id:"outside-git-test",source:"startup",tool_name:"Bash",tool_input:{command:"true"}}')
  hook_rc=0
  printf '%s' "$payload" | bash "$HOOKS/$hook" >"$PLAIN/hook.out" 2>"$PLAIN/hook.err" || hook_rc=$?
  assert "$hook outside git does not block" "0" "$hook_rc"
  if [ ! -e "$PLAIN/.rite" ]; then pass "$hook creates no state"; else fail "$hook creates no state"; fi
 done

# An existing state tree must also stay unchanged, including cleanup targets.
mkdir -p "$PLAIN/.rite/state" "$PLAIN/.rite/review-results"
printf 'preserve' > "$PLAIN/.rite/state/pr-recommendations-9.json"
printf 'preserve' > "$PLAIN/.rite/review-results/9-existing.json"
printf 'legacy' > "$PLAIN/.rite-flow-state"
for hook in session-start.sh stop-loop-continuation.sh session-end.sh pre-compact.sh post-compact.sh post-tool-wm-sync.sh; do
  printf '%s' "$payload" | bash "$HOOKS/$hook" >"$PLAIN/hook.out" 2>"$PLAIN/hook.err"
 done
assert "existing state preserved" "preserve" "$(cat "$PLAIN/.rite/state/pr-recommendations-9.json")"
assert "legacy state preserved" "legacy" "$(cat "$PLAIN/.rite-flow-state")"

# Run CLI helpers in the non-git fixture; the test driver stays in its checkout.
printf '{"commit_sha":"abc"}' > "$PLAIN/review.json"
printf '{"verdicts":[]}' > "$PLAIN/verdicts.json"
printf '{"candidates":[]}' > "$PLAIN/candidates.json"
writer_rc=0
(cd "$PLAIN" && bash "$HOOKS/../scripts/review-pr-recommendations.sh" record --pr 9 --review-result "$PLAIN/review.json" --verdicts "$PLAIN/verdicts.json" --candidates "$PLAIN/candidates.json") >"$PLAIN/writer.out" 2>"$PLAIN/writer.err" || writer_rc=$?
assert "record rejects unresolved state root" "1" "$writer_rc"
assert_grep "record diagnostic identifies root failure" "$PLAIN/writer.err" "state root unresolved"
assert "record does not overwrite existing state" "preserve" "$(cat "$PLAIN/.rite/state/pr-recommendations-9.json")"
for helper in cleanup-work-memory.sh review-result-save.sh issue-comment-wm-sync.sh wiki-query-inject.sh; do
  writer_rc=0
  (cd "$PLAIN" && bash "$HOOKS/$helper") >"$PLAIN/writer.out" 2>"$PLAIN/writer.err" || writer_rc=$?
  assert "$helper rejects non-git root" "1" "$writer_rc"
 done
# Valid arguments must reach root resolution rather than fail in argument parsing.
content_file=$(mktemp "${TMPDIR:-/tmp}/rite-state-root-content-XXXXXX")
cleanup_dirs+=("$content_file")
printf 'outside-Git boundary probe\n' > "$content_file"
writer_rc=0
(cd "$PLAIN" && bash "$HOOKS/wiki-ingest-trigger.sh" --type fixes --source-ref boundary-probe --content-file "$content_file") >"$PLAIN/writer.out" 2>"$PLAIN/writer.err" || writer_rc=$?
assert "Wiki ingest rejects unresolved root with valid arguments" "1" "$writer_rc"
assert_grep "Wiki ingest diagnostic identifies root failure" "$PLAIN/writer.err" "state root unresolved"
if [ ! -d "$PLAIN/.rite/wiki" ]; then pass "Wiki ingest creates no raw state"; else fail "Wiki ingest creates no raw state"; fi
for step in fix iterate; do
  command=nb-sweep-finish
  [ "$step" != iterate ] || command=nb-sweep-record
  writer_rc=0
  (cd "$PLAIN" && bash "$HOOKS/../scripts/$step-step.sh" "$command" --pr 9) >"$PLAIN/writer.out" 2>"$PLAIN/writer.err" || writer_rc=$?
  assert "$step NB writer rejects unresolved root" "1" "$writer_rc"
  assert_grep "$step NB writer retains root diagnostic" "$PLAIN/writer.err" "state root unresolved"
done
if [ ! -e "$PLAIN/.rite/state/nb-sweep-done-9.txt" ]; then pass "NB writers create no completion state"; else fail "NB writers create no completion state"; fi
# Use the real resolver and valid CLI arguments so argument validation cannot
# hide an issue-creation side effect before the unresolved-root stop.
ISSUE_FIXTURE=$(make_plain_sandbox)
cleanup_dirs+=("$ISSUE_FIXTURE")
mkdir -p "$ISSUE_FIXTURE/scripts" "$ISSUE_FIXTURE/hooks"
cp "$HOOKS/../scripts/fix-step.sh" "$ISSUE_FIXTURE/scripts/"
cp "$RESOLVER" "$HOOKS/control-char-neutralize.sh" "$ISSUE_FIXTURE/hooks/"
cat > "$ISSUE_FIXTURE/scripts/create-issue-with-projects.sh" <<'MOCK'
#!/bin/bash
printf 'issued\n' >> "$ISSUER_LOG"
printf '{"issue_number":42,"issue_url":"https://example.invalid/issues/42"}\n'
MOCK
printf 'Boundary probe\n' > "$ISSUE_FIXTURE/title.md"
printf '**Type**: fix\n**Complexity**: S\n' > "$ISSUE_FIXTURE/body.md"
tracker="$PLAIN/.rite/state/adoption-9-sweep.json"
printf '{"adoption":{"records":[{"ids":["F-01"],"tracker":null}]}}\n' > "$tracker"
cp "$tracker" "$ISSUE_FIXTURE/tracker-before.json"
writer_rc=0
(cd "$PLAIN" && ISSUER_LOG="$ISSUE_FIXTURE/issuer.log" bash "$ISSUE_FIXTURE/scripts/fix-step.sh" nb-sweep-file-issue \
  --pr 9 --issue-title-file "$ISSUE_FIXTURE/title.md" --issue-body-file "$ISSUE_FIXTURE/body.md" \
  --record-ids '["F-01"]' --projects-enabled false --project-number 0 --project-owner test) \
  >"$PLAIN/writer.out" 2>"$PLAIN/writer.err" || writer_rc=$?
assert "file-issue rejects unresolved root with valid arguments" "1" "$writer_rc"
assert_grep "file-issue retains root diagnostic" "$PLAIN/writer.err" "state root unresolved"
if [ ! -e "$ISSUE_FIXTURE/issuer.log" ]; then pass "file-issue never invokes issuer outside Git"; else fail "file-issue never invokes issuer outside Git"; fi
if cmp -s "$tracker" "$ISSUE_FIXTURE/tracker-before.json" && [ ! -e "$tracker.tmp" ]; then pass "file-issue preserves tracker without temporary writes"; else fail "file-issue preserves tracker without temporary writes"; fi
# A denied tool request keeps its deny payload without a cwd-relative audit write.
deny_payload=$(jq -n --arg cwd "$PLAIN" '{cwd:$cwd,tool_name:"Bash",tool_input:{command:"gh pr diff 1 --stat"}}')
guard_rc=0
(cd "$PLAIN" && printf '%s' "$deny_payload" | env -u RITE_STATE_ROOT bash "$HOOKS/pre-tool-bash-guard.sh") >"$PLAIN/guard.out" 2>"$PLAIN/guard.err" || guard_rc=$?
assert "outside-Git guard retains normal hook exit" "0" "$guard_rc"
assert "outside-Git guard retains deny payload" "deny" "$(jq -r '.hookSpecificOutput.permissionDecision' "$PLAIN/guard.out")"
if [ ! -d "$PLAIN/.rite/logs" ]; then pass "outside-Git deny creates no audit state"; else fail "outside-Git deny creates no audit state"; fi
writer_rc=0
(cd "$PLAIN" && bash "$HOOKS/scripts/cleanup-pr-state-purge.sh" --pr 9) >"$PLAIN/writer.out" 2>"$PLAIN/writer.err" || writer_rc=$?
assert "purge rejects non-git root" "1" "$writer_rc"
assert "purge keeps existing review state" "preserve" "$(cat "$PLAIN/.rite/review-results/9-existing.json")"
writer_rc=0
(cd "$PLAIN" && bash "$HOOKS/scripts/run-queue-reap.sh" --session outside-git-test) >"$PLAIN/writer.out" 2>"$PLAIN/writer.err" || writer_rc=$?
assert "queue reaper rejects non-git root" "1" "$writer_rc"
writer_rc=0
(cd "$PLAIN" && bash "$HOOKS/scripts/rite-tmp-artifact.sh" record --type branch --id fix/test) >"$PLAIN/writer.out" 2>"$PLAIN/writer.err" || writer_rc=$?
assert "artifact writer rejects non-git root" "1" "$writer_rc"

# An explicit helper root remains authoritative, even outside git.
(cd "$PLAIN" && bash "$HOOKS/../scripts/review-pr-recommendations.sh" record --pr 9 --review-result "$PLAIN/review.json" --verdicts "$PLAIN/verdicts.json" --candidates "$PLAIN/candidates.json" --state-root "$MAIN") >"$PLAIN/writer.out" 2>"$PLAIN/writer.err"
assert "explicit root records recommendations" "abc" "$(jq -r '.commit_sha' "$MAIN/.rite/state/pr-recommendations-9.json")"
resolved_explicit=$(cd "$PLAIN" && RITE_STATE_ROOT="$MAIN" RITE_HOST=claude CLAUDE_CODE_SESSION_ID=explicit-root-test bash "$HOOKS/flow-state.sh" path)
case "$resolved_explicit" in "$MAIN"/*) pass "explicit runtime root stays authoritative" ;; *) fail "explicit runtime root stays authoritative" ;; esac
payload=$(jq -n --arg cwd "$WT/sub/deep" '{cwd:$cwd,session_id:"inside-git-test",source:"startup"}')
printf '%s' "$payload" | bash "$HOOKS/session-start.sh" >"$PLAIN/hook.out" 2>"$PLAIN/hook.err"
if [ -d "$MAIN/.rite/sessions" ] && [ ! -d "$WT/.rite" ]; then pass "git SessionStart writes shared main root"; else fail "git SessionStart writes shared main root"; fi

print_summary "$(basename "$0")" \
  "Drift hint: state-path-resolve.sh §1 contract — non-worktree output must stay byte-identical to git rev-parse --show-toplevel."
