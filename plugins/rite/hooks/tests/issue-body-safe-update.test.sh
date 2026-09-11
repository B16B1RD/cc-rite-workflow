#!/bin/bash
# issue-body-safe-update.test.sh
#
# Pin the apply-mode safety net (50% shrinkage guard, empty-write rejection,
# missing-args detection, diff-check short-circuit) plus the failure-surfacing
# WARNING invariants. Without these guards, a body update with a truncated
# payload could silently destroy the Issue body, and a transient gh failure
# could vanish without a diagnostic WARNING.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"
TARGET="$PLUGIN_ROOT/hooks/issue-body-safe-update.sh"

[ -f "$TARGET" ] || { echo "ERROR: $TARGET not found" >&2; exit 1; }

# Helper: assert exit code matches expectation
assert_exit() {
  local label="$1" expected="$2" actual="$3"
  if [ "$actual" -eq "$expected" ]; then
    pass "$label (exit $actual)"
  else
    fail "$label (expected exit $expected, got $actual)"
  fi
}

echo "=== Phase 1: apply mode argument errors ==="
rc=0
bash "$TARGET" apply --issue 999 >/dev/null 2>&1 || rc=$?
assert_exit "TC-01 apply without tmpfile-* + original-length → exit 1" 1 "$rc"

rc=0
bash "$TARGET" apply --issue 999 --tmpfile-read /tmp/foo >/dev/null 2>&1 || rc=$?
assert_exit "TC-02 apply with partial args → exit 1" 1 "$rc"

echo "=== Phase 2: apply mode empty write rejection ==="
tmp_read=$(mktemp)
tmp_write=$(mktemp)
printf 'original body content here\n' > "$tmp_read"
: > "$tmp_write"  # empty write file
rc=0
out=$(bash "$TARGET" apply --issue 999 --tmpfile-read "$tmp_read" --tmpfile-write "$tmp_write" --original-length 30 2>&1) || rc=$?
assert_exit "TC-03 empty tmpfile-write → exit 0 (non-blocking skip)" 0 "$rc"
if printf '%s' "$out" | grep -q '更新内容が空\|empty'; then
  pass "TC-04 empty write emits WARNING with 空 / empty message"
else
  fail "TC-04 empty write WARNING missing in output: $out"
fi
[ ! -f "$tmp_read" ] && pass "TC-05 empty write cleaned tmpfile-read" || fail "TC-05 tmpfile-read leak"
[ ! -f "$tmp_write" ] && pass "TC-06 empty write cleaned tmpfile-write" || fail "TC-06 tmpfile-write leak"

echo "=== Phase 3: apply mode 50% shrinkage guard ==="
tmp_read=$(mktemp)
tmp_write=$(mktemp)
# original=100 bytes
printf '%s' "$(head -c 100 /dev/urandom | tr -dc 'a-z' | head -c 100)" > "$tmp_read"
# write=10 bytes (10% — well under 50%)
printf 'short' > "$tmp_write"
rc=0
out=$(bash "$TARGET" apply --issue 999 --tmpfile-read "$tmp_read" --tmpfile-write "$tmp_write" --original-length 100 2>&1) || rc=$?
assert_exit "TC-07 < 50% shrinkage → exit 0 (non-blocking skip)" 0 "$rc"
if printf '%s' "$out" | grep -q 'body 消失\|50%未満\|shrinkage'; then
  pass "TC-08 shrinkage guard emits WARNING with 消失 / 50% message"
else
  fail "TC-08 shrinkage WARNING missing in output: $out"
fi
[ ! -f "$tmp_read" ] && pass "TC-09 shrinkage skip cleaned tmpfile-read" || fail "TC-09 tmpfile-read leak"

echo "=== Phase 4: apply mode diff-check short-circuit ==="
tmp_read=$(mktemp)
tmp_write=$(mktemp)
printf 'identical content\n' > "$tmp_read"
printf 'identical content\n' > "$tmp_write"
rc=0
out=$(bash "$TARGET" apply --issue 999 --diff-check --tmpfile-read "$tmp_read" --tmpfile-write "$tmp_write" --original-length 18 2>&1) || rc=$?
assert_exit "TC-10 diff-check identical → exit 0 (skip)" 0 "$rc"
if printf '%s' "$out" | grep -q 'INFO\|変更なし\|already'; then
  pass "TC-11 diff-check emits INFO on identical files"
else
  fail "TC-11 diff-check INFO missing: $out"
fi

echo "=== Phase 5: fetch mode argument errors ==="
rc=0
bash "$TARGET" fetch >/dev/null 2>&1 || rc=$?
assert_exit "TC-12 fetch without --issue → exit 1" 1 "$rc"

echo "=== Phase 6: unknown mode ==="
rc=0
bash "$TARGET" unknown_mode --issue 999 >/dev/null 2>&1 || rc=$?
assert_exit "TC-13 unknown mode → exit 1" 1 "$rc"

echo "=== Phase 7: apply mode happy-path with mock gh ==="
# Negative-path TCs above don't exercise the happy path through gh. Mock gh
# pins three invariants: --body-file argument shape, exit-0 + cleanup on
# success, and exit-0 + cleanup + WARNING on gh failure (non-blocking contract).
mock_bin=$(mktemp -d)
trap_orig=""
cat > "$mock_bin/gh" <<'MOCK_OK'
#!/bin/bash
# Inline mock: log invocation to MOCK_LOG, succeed exit 0.
echo "gh $*" >> "${MOCK_LOG:-/dev/null}"
exit 0
MOCK_OK
chmod +x "$mock_bin/gh"

tmp_read=$(mktemp)
tmp_write=$(mktemp)
mock_log=$(mktemp)
# 200/250 byte 確定で書き込む (urandom + tr -dc 'a-z' は output が短くなる risk があるので避ける)
printf 'a%.0s' $(seq 1 200) > "$tmp_read"
printf 'b%.0s' $(seq 1 250) > "$tmp_write"
rc=0
out=$(PATH="$mock_bin:$PATH" MOCK_LOG="$mock_log" bash "$TARGET" apply --issue 999 --tmpfile-read "$tmp_read" --tmpfile-write "$tmp_write" --original-length 200 2>&1) || rc=$?
assert_exit "TC-14 apply happy-path → exit 0" 0 "$rc"
# The `--repo` flag sits between the issue number and --body-file since, so
# this must not re-tighten into an adjacency match on 'issue edit 999 --body-file'.
if grep -qE 'issue edit 999 .*--body-file' "$mock_log"; then
  pass "TC-15 apply called gh issue edit with --body-file"
else
  fail "TC-15 mock gh log missing 'issue edit ... --body-file': $(cat "$mock_log")"
fi
# Without an explicit --repo, gh infers the repo from git remotes and fails when
# `origin` is an SSH Host alias it cannot expand. The test process runs
# inside this repo, so git-remote resolution succeeds and the flag must be present.
if grep -qE 'issue edit 999 --repo [^ ]+/[^ ]+ --body-file' "$mock_log"; then
  pass "TC-15b apply passes --repo owner/repo explicitly (SSH host alias safety)"
else
  fail "TC-15b mock gh log missing '--repo owner/repo' — gh would fall back to remote inference: $(cat "$mock_log")"
fi
[ ! -f "$tmp_read" ] && pass "TC-16 apply happy-path cleaned tmpfile-read" || fail "TC-16 tmpfile-read leak"
[ ! -f "$tmp_write" ] && pass "TC-17 apply happy-path cleaned tmpfile-write" || fail "TC-17 tmpfile-write leak"
rm -f "$mock_log"

# TC-18-20: gh issue edit failure path (exit !=0 + stderr captured)
cat > "$mock_bin/gh" <<'MOCK_FAIL'
#!/bin/bash
# Inline mock: fail with stderr message ("rate limit" 等を模擬)
echo "HTTP 403: API rate limit exceeded for user" >&2
exit 1
MOCK_FAIL
chmod +x "$mock_bin/gh"

tmp_read=$(mktemp)
tmp_write=$(mktemp)
printf 'a%.0s' $(seq 1 200) > "$tmp_read"
printf 'b%.0s' $(seq 1 250) > "$tmp_write"
rc=0
out=$(PATH="$mock_bin:$PATH" bash "$TARGET" apply --issue 999 --tmpfile-read "$tmp_read" --tmpfile-write "$tmp_write" --original-length 200 2>&1) || rc=$?
assert_exit "TC-18 apply gh failure → exit 0 (non-blocking)" 0 "$rc"
if printf '%s' "$out" | grep -q 'gh issue edit 失敗.*rate limit\|apply_failure_reason=gh_edit_failed'; then
  pass "TC-19 apply gh failure emits WARNING with root cause + failure reason"
else
  fail "TC-19 apply gh failure WARNING missing in output: $out"
fi
# `if ! cmd; then rc=$?` forces rc=0 inside the then-branch — regression guard
# for the canonical `if cmd; then :; else rc=$?` form. The mock gh exits 1, so
# the incident details must report rc=1, not rc=0.
if printf '%s' "$out" | grep -qE 'rc=1\b'; then
  pass "TC-19b apply gh failure reports actual gh rc (rc=1, not rc=0)"
else
  fail "TC-19b apply gh failure reported wrong rc (likely rc=0 from if-! antipattern): $out"
fi
[ ! -f "$tmp_read" ] && pass "TC-20 apply gh failure cleaned tmpfile-read" || fail "TC-20 tmpfile-read leak after gh failure"
[ ! -f "$tmp_write" ] && pass "TC-21 apply gh failure cleaned tmpfile-write" || fail "TC-21 tmpfile-write leak after gh failure"

rm -rf "$mock_bin"

# ==========================================================================
# Failure surfacing guarantees: without these assertions a refactor can drop
# the fetch_failure_reason / rc signal silently, and operators lose visibility
# into auth/network/permission failures. workflow_incident 機構廃止後、
# helper は emit script に delegate せず plain WARNING を stderr に出力する。
# ==========================================================================

echo "=== Phase 8: _emit_body_update_incident emits plain WARNING ==="
# helper は `_emit_body_update_incident` で `WARNING: ... (reason=... rc=... stderr=...)` を
# stderr に出力する。WARNING が incident_type / rc / reason を含むことを pin し、失敗が
# silent に落ちる regression を防ぐ。
mock_bin2=$(mktemp -d)
cat > "$mock_bin2/gh" <<'MOCK_FETCH_FAIL'
#!/bin/bash
echo "HTTP 404: Issue not found" >&2
exit 1
MOCK_FETCH_FAIL
chmod +x "$mock_bin2/gh"

rc=0
out=$(PATH="$mock_bin2:$PATH" bash "$TARGET" fetch --issue 999 2>&1) || rc=$?
assert_exit "TC-22 fetch failure → exit 0 (non-blocking)" 0 "$rc"
if printf '%s' "$out" | grep -q 'issue_body_fetch_failed'; then
  pass "TC-22 fetch failure emits WARNING with incident_type=issue_body_fetch_failed"
else
  fail "TC-22 WARNING missing issue_body_fetch_failed: out=$out"
fi
if printf '%s' "$out" | grep -qE 'rc=1\b'; then
  pass "TC-22b WARNING reports actual gh rc=1 (regression guard for if-! antipattern)"
else
  fail "TC-22b WARNING missing rc=1 (likely rc=0 from if-! pattern): out=$out"
fi
if printf '%s' "$out" | grep -q 'gh_view_failed'; then
  pass "TC-22c WARNING includes reason=gh_view_failed"
else
  fail "TC-22c WARNING missing gh_view_failed: out=$out"
fi
rm -rf "$mock_bin2"

echo "=== Phase 10: apply mode failure emits gh_edit_failed root cause ==="
mock_bin4=$(mktemp -d)
cat > "$mock_bin4/gh" <<'MOCK_EDIT_FAIL'
#!/bin/bash
echo "API error during edit" >&2
exit 1
MOCK_EDIT_FAIL
chmod +x "$mock_bin4/gh"

tmp_read=$(mktemp)
tmp_write=$(mktemp)
printf 'a%.0s' $(seq 1 200) > "$tmp_read"
printf 'b%.0s' $(seq 1 250) > "$tmp_write"
rc=0
out=$(PATH="$mock_bin4:$PATH" bash "$TARGET" apply --issue 999 --tmpfile-read "$tmp_read" --tmpfile-write "$tmp_write" --original-length 200 2>&1) || rc=$?
assert_exit "TC-24 apply gh failure → exit 0" 0 "$rc"
# AND-style assertion: collapsing apply_failure_reason / root_cause_hint into a
# single OR would let regressions delete either signal silently.
if printf '%s' "$out" | grep -qE 'apply_failure_reason=gh_edit_failed'; then
  pass "TC-24 apply failure emits apply_failure_reason=gh_edit_failed"
else
  fail "TC-24 apply failure missing apply_failure_reason=gh_edit_failed: $out"
fi
if printf '%s' "$out" | grep -qE 'rc=1\b'; then
  pass "TC-24b apply failure reports actual gh rc=1 (if-! antipattern regression guard)"
else
  fail "TC-24b apply failure reported wrong rc (likely rc=0): $out"
fi
rm -rf "$mock_bin4"

echo ""
echo "=== Phase 10b: apply gh edit failure → plain WARNING (incident_type + reason) ==="
# The apply-mode gh edit failure path surfaces a plain WARNING carrying
# incident_type=issue_body_fetch_failed + reason=gh_edit_failed + the actual rc.
mock_bin5=$(mktemp -d)
cat > "$mock_bin5/gh" <<'MOCK_EDIT_FAIL'
#!/bin/bash
case "$1 $2" in
  "issue edit") echo "HTTP 401: bad credentials" >&2; exit 1 ;;
esac
exit 0
MOCK_EDIT_FAIL
chmod +x "$mock_bin5/gh"
tmp_read=$(mktemp)
tmp_write=$(mktemp)
printf 'a%.0s' $(seq 1 200) > "$tmp_read"
printf 'b%.0s' $(seq 1 250) > "$tmp_write"
rc=0
out=$(PATH="$mock_bin5:$PATH" bash "$TARGET" apply --issue 999 --tmpfile-read "$tmp_read" --tmpfile-write "$tmp_write" --original-length 200 2>&1) || rc=$?
assert_exit "TC-25 apply gh edit failure → exit 0" 0 "$rc"
if printf '%s' "$out" | grep -qE 'issue_body_fetch_failed'; then
  pass "TC-25 apply gh failure emits WARNING with incident_type=issue_body_fetch_failed"
else
  fail "TC-25 apply WARNING missing incident_type — degraded deployment silently loses observability: $out"
fi
if printf '%s' "$out" | grep -qE 'reason=gh_edit_failed'; then
  pass "TC-25b apply WARNING preserves reason=gh_edit_failed"
else
  fail "TC-25b apply WARNING reason missing: $out"
fi
if printf '%s' "$out" | grep -qE 'rc=1\b'; then
  pass "TC-25c apply WARNING reports actual gh rc=1"
else
  fail "TC-25c apply WARNING rc missing: $out"
fi
rm -rf "$mock_bin5"

echo ""
echo "=== Phase 11: apply mktemp_failed surfaces incident ==="
# A regression that drops the emit on apply mktemp failure would lose the
# observability that the safety net exists at all. Shadow mktemp to fail only
# on the rite-issue-body-apply-err-* pattern so the rest of the script runs.
mock_bin6=$(mktemp -d)
cat > "$mock_bin6/mktemp" <<'EOF'
#!/bin/bash
for arg in "$@"; do
  case "$arg" in
    # 本番は ${TMPDIR:-/tmp}/rite-issue-body-apply-err-XXXXXX を渡すため、
    # sandbox (TMPDIR 設定) 環境でも intercept できるよう両形にマッチさせる
    /tmp/rite-issue-body-apply-err-*|"${TMPDIR:-/tmp}"/rite-issue-body-apply-err-*) exit 1 ;;
  esac
done
exec /usr/bin/mktemp "$@"
EOF
chmod +x "$mock_bin6/mktemp"
cat > "$mock_bin6/gh" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$mock_bin6/gh"
tmp_read=$(mktemp)
tmp_write=$(mktemp)
printf 'a%.0s' $(seq 1 200) > "$tmp_read"
printf 'b%.0s' $(seq 1 250) > "$tmp_write"
rc=0
out=$(PATH="$mock_bin6:$PATH" bash "$TARGET" apply --issue 999 --tmpfile-read "$tmp_read" --tmpfile-write "$tmp_write" --original-length 200 2>&1) || rc=$?
if printf '%s' "$out" | grep -qE 'mktemp apply_err failed'; then
  pass "TC-26 apply mktemp failure emits WARNING (regression guard for stderr capture disabled path)"
else
  fail "TC-26 apply mktemp WARNING missing: $out"
fi
if printf '%s' "$out" | grep -qE 'reason=mktemp_failed'; then
  pass "TC-26b apply mktemp failure WARNING carries reason=mktemp_failed"
else
  fail "TC-26b apply mktemp WARNING reason missing: $out"
fi
rm -rf "$mock_bin6"

echo ""
echo "=== Phase 12: diff IO error rc>=2 → skip apply with WARNING (not gh edit) ==="
# A refactor to `if ! diff ...; then` would treat rc=2 (file unreadable / IO
# error) identically to rc=1 (files differ) and proceed to gh edit, risking
# data loss. The case branch on _diff_rc must distinguish IO failure.
mock_bin7=$(mktemp -d)
# Shadow diff to always return rc=2 (IO error)
cat > "$mock_bin7/diff" <<'EOF'
#!/bin/bash
echo "diff: cannot read file" >&2
exit 2
EOF
chmod +x "$mock_bin7/diff"
# gh mock counts invocations so a regression that calls gh after IO error fails the assert
cat > "$mock_bin7/gh" <<'EOF'
#!/bin/bash
echo "GH_INVOKED" >&2
exit 0
EOF
chmod +x "$mock_bin7/gh"
tmp_read=$(mktemp)
tmp_write=$(mktemp)
printf 'a%.0s' $(seq 1 200) > "$tmp_read"
printf 'b%.0s' $(seq 1 250) > "$tmp_write"
rc=0
out=$(PATH="$mock_bin7:$PATH" bash "$TARGET" apply --issue 999 --tmpfile-read "$tmp_read" --tmpfile-write "$tmp_write" --original-length 200 --diff-check 2>&1) || rc=$?
assert_exit "TC-27 diff IO error → exit 0 (skip apply)" 0 "$rc"
if printf '%s' "$out" | grep -qE 'diff コマンドが IO エラー.*rc=2'; then
  pass "TC-27 diff IO error WARNING reports rc=2 explicitly"
else
  fail "TC-27 diff IO error WARNING missing or rc not reported: $out"
fi
if printf '%s' "$out" | grep -qE 'GH_INVOKED'; then
  fail "TC-27 critical: gh issue edit was invoked despite diff IO error (data loss risk)"
else
  pass "TC-27 gh issue edit NOT invoked after diff IO error (data loss prevented)"
fi
rm -rf "$mock_bin7"

echo ""
echo "=== Phase 13: shrinkage trip → body_shrinkage_guard_tripped WARNING ==="
# `_emit_body_update_incident` accepts the incident type as its 1st arg.
# TC-25/25b/25c pinned the `issue_body_fetch_failed` path only. Shrinkage trip
# must surface as `body_shrinkage_guard_tripped` in the WARNING — without this
# TC, a refactor that hardcodes the incident_type literal would pass all
# existing TCs.
mock_bin8=$(mktemp -d)
cat > "$mock_bin8/gh" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$mock_bin8/gh"
tmp_read=$(mktemp)
tmp_write=$(mktemp)
printf 'a%.0s' $(seq 1 200) > "$tmp_read"
# 5 bytes ≪ 200/2 — triggers shrinkage guard
printf 'aaaaa' > "$tmp_write"
rc=0
out=$(PATH="$mock_bin8:$PATH" bash "$TARGET" apply --issue 999 --tmpfile-read "$tmp_read" --tmpfile-write "$tmp_write" --original-length 200 2>&1) || rc=$?
assert_exit "TC-25d shrinkage trip → exit 0" 0 "$rc"
if printf '%s' "$out" | grep -qE 'body_shrinkage_guard_tripped'; then
  pass "TC-25d shrinkage trip emits WARNING with incident_type=body_shrinkage_guard_tripped"
else
  fail "TC-25d shrinkage WARNING missing or wrong incident_type: $out"
fi
if printf '%s' "$out" | grep -qE 'reason=shrinkage_below_50pct'; then
  pass "TC-25d WARNING carries reason=shrinkage_below_50pct"
else
  fail "TC-25d reason missing: $out"
fi
rm -rf "$mock_bin8"

echo ""
echo "=== Phase 14: empty write → body_shrinkage_guard_tripped WARNING (empty_write) ==="
mock_bin9=$(mktemp -d)
cat > "$mock_bin9/gh" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$mock_bin9/gh"
tmp_read=$(mktemp)
tmp_write=$(mktemp)
printf 'a%.0s' $(seq 1 200) > "$tmp_read"
# zero bytes — triggers empty-write guard
: > "$tmp_write"
rc=0
out=$(PATH="$mock_bin9:$PATH" bash "$TARGET" apply --issue 999 --tmpfile-read "$tmp_read" --tmpfile-write "$tmp_write" --original-length 200 2>&1) || rc=$?
assert_exit "TC-25e empty write → exit 0" 0 "$rc"
if printf '%s' "$out" | grep -qE 'body_shrinkage_guard_tripped'; then
  pass "TC-25e empty write emits WARNING with incident_type=body_shrinkage_guard_tripped"
else
  fail "TC-25e empty-write WARNING missing or wrong incident_type: $out"
fi
if printf '%s' "$out" | grep -qE 'reason=empty_write'; then
  pass "TC-25e WARNING carries reason=empty_write"
else
  fail "TC-25e empty-write reason missing: $out"
fi
rm -rf "$mock_bin9"

echo ""
echo "=== Phase 15: --original-length non-numeric → body_shrinkage_guard_tripped with original_length_invalid hint ==="
# The defensive validation against non-numeric --original-length was added
# specifically so that an upstream `wc` failure (which can return whitespace
# or empty under `set -euo pipefail`) doesn't abort apply-mode via arithmetic
# evaluation. Without this TC, dropping the regex check or mis-typing the
# hint would silently revert to the original `arithmetic syntax error` abort
# path that leaks tmpfiles and breaks the non-blocking contract.
mock_bin10=$(mktemp -d)
cat > "$mock_bin10/gh" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$mock_bin10/gh"
tmp_read=$(mktemp)
tmp_write=$(mktemp)
printf 'sample body' > "$tmp_read"
printf 'updated body' > "$tmp_write"
rc=0
out=$(PATH="$mock_bin10:$PATH" bash "$TARGET" apply --issue 999 --tmpfile-read "$tmp_read" --tmpfile-write "$tmp_write" --original-length "abc" 2>&1) || rc=$?
assert_exit "TC-25f apply with non-numeric --original-length → exit 0 (non-blocking)" 0 "$rc"
if printf '%s' "$out" | grep -qE 'body_shrinkage_guard_tripped'; then
  pass "TC-25f non-numeric --original-length emits body_shrinkage_guard_tripped WARNING"
else
  fail "TC-25f WARNING missing: $out"
fi
if printf '%s' "$out" | grep -qE 'reason=original_length_invalid'; then
  pass "TC-25f WARNING carries reason=original_length_invalid (distinct from shrinkage_below_50pct / empty_write)"
else
  fail "TC-25f original_length_invalid reason missing — caller cannot distinguish from a real shrinkage trip: $out"
fi
# Confirm tmpfiles were cleaned up (the original arithmetic abort path would leak them).
if [ ! -f "$tmp_read" ] && [ ! -f "$tmp_write" ]; then
  pass "TC-25f tmpfiles cleaned up under defensive abort"
else
  fail "TC-25f tmpfiles leaked under defensive abort (read present=$([ -f "$tmp_read" ] && echo y || echo n), write present=$([ -f "$tmp_write" ] && echo y || echo n))"
fi
rm -rf "$mock_bin10"

# TC-25g — additional boundary forms for --original-length validation. The
# numeric-prefix form `10abc` and whitespace-padded `" 5 "` share the same
# code path as the pure-alpha `"abc"` of TC-25f, but a future refactor that
# accidentally tightens the regex to `[0-9]+` matching anywhere would let
# `10abc` slip through and produce arithmetic-eval errors downstream.
for invalid_val in "10abc" " 5 " "5e3"; do
  mock_bin_25g=$(mktemp -d "${TMPDIR:-/tmp}/rite-mock-bin-25g.XXXXXX")
  cat > "$mock_bin_25g/gh" <<'GHEOF'
#!/bin/sh
exit 0
GHEOF
  chmod +x "$mock_bin_25g/gh"
  tmp_read=$(mktemp)
  tmp_write=$(mktemp)
  printf 'sample body' > "$tmp_read"
  printf 'updated body' > "$tmp_write"
  rc=0
  out=$(PATH="$mock_bin_25g:$PATH" bash "$TARGET" apply --issue 999 --tmpfile-read "$tmp_read" --tmpfile-write "$tmp_write" --original-length "$invalid_val" 2>&1) || rc=$?
  assert_exit "TC-25g (--original-length=$invalid_val) → exit 0 (non-blocking)" 0 "$rc"
  if printf '%s' "$out" | grep -qE 'reason=original_length_invalid'; then
    pass "TC-25g (--original-length=$invalid_val) emits reason=original_length_invalid"
  else
    fail "TC-25g (--original-length=$invalid_val) reason missing — regex may be accepting non-numeric content: $out"
  fi
  rm -f "$tmp_read" "$tmp_write"
  rm -rf "$mock_bin_25g"
done

echo ""
echo "=== Phase 16: owner/repo resolution → explicit --repo, with degrade fallback ==="
# fetch mode must carry the same --repo flag as apply: the SSH-host-alias failure
# hit `gh issue view` first, and fixing only one mode leaves the checklist-update
# path (implement 5.1.1.1) broken while apply looks healthy.
mock_bin7=$(mktemp -d)
mock_log7=$(mktemp)
cat > "$mock_bin7/gh" <<'MOCK_FETCH_OK'
#!/bin/bash
echo "gh $*" >> "${MOCK_LOG:-/dev/null}"
case "$1 $2" in
  "issue view") echo "body content" ;;
esac
exit 0
MOCK_FETCH_OK
chmod +x "$mock_bin7/gh"
rc=0
out=$(PATH="$mock_bin7:$PATH" MOCK_LOG="$mock_log7" bash "$TARGET" fetch --issue 999 2>&1) || rc=$?
assert_exit "TC-30 fetch with resolvable repo → exit 0" 0 "$rc"
if grep -qE 'issue view 999 --repo [^ ]+/[^ ]+ --json body' "$mock_log7"; then
  pass "TC-30b fetch passes --repo owner/repo explicitly"
else
  fail "TC-30b fetch missing '--repo owner/repo' — gh falls back to remote inference: $(cat "$mock_log7")"
fi
# fetch deliberately persists tmpfile_read / tmpfile_write for Step 2/3, so this
# test owns their cleanup.
printf '%s\n' "$out" | sed -n 's/^tmpfile_[a-z]*=//p' | xargs -r rm -f
rm -f "$mock_log7"

# The remaining two tiers both need a directory whose `git config --get
# remote.origin.url` is empty, so git-remote.sh fails and resolution falls
# through. `git init` makes that state explicit instead of relying on $TMPDIR
# happening to sit outside a repository — a precondition that silently dropped
# three assertions when it did not hold. GIT_CONFIG_* are neutralised at
# invocation time so a stray global remote.origin.url cannot leak in.
norepo_dir=$(mktemp -d)
git init -q "$norepo_dir"

# Tier 2: git-remote.sh fails but `gh repo view` resolves. Without a test here,
# deleting the entire fallback branch keeps the suite green — the flag simply
# stops appearing and no assertion notices.
cat > "$mock_bin7/gh" <<'MOCK_REPO_VIEW_OK'
#!/bin/bash
echo "gh $*" >> "${MOCK_LOG:-/dev/null}"
case "$1 $2" in
  "repo view") echo "fallbackowner/fallbackrepo" ;;
  "issue view") echo "body content" ;;
esac
exit 0
MOCK_REPO_VIEW_OK
chmod +x "$mock_bin7/gh"
mock_log7=$(mktemp)
rc=0
out=$(cd "$norepo_dir" && PATH="$mock_bin7:$PATH" MOCK_LOG="$mock_log7" \
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null bash "$TARGET" fetch --issue 999 2>&1) || rc=$?
assert_exit "TC-32 gh repo view fallback → exit 0" 0 "$rc"
if grep -qE 'issue view 999 --repo fallbackowner/fallbackrepo --json body' "$mock_log7"; then
  pass "TC-32b gh repo view fallback supplies --repo when git-remote resolution fails"
else
  fail "TC-32b fallback tier did not reach the gh call — the whole fallback branch can be deleted undetected: $(cat "$mock_log7")"
fi
printf '%s\n' "$out" | sed -n 's/^tmpfile_[a-z]*=//p' | xargs -r rm -f
rm -f "$mock_log7"

# Tier 3 (degrade): neither path yields an owner/repo. The script must fall back
# to the pre- invocation shape rather than aborting — and must say so,
# because a silent fallback is indistinguishable from the bug this fix removes.
cat > "$mock_bin7/gh" <<'MOCK_NO_REPO'
#!/bin/bash
echo "gh $*" >> "${MOCK_LOG:-/dev/null}"
case "$1 $2" in
  "repo view") echo "none of the git remotes configured for this repository point to a known GitHub host" >&2; exit 1 ;;
  "issue view") echo "body content" ;;
esac
exit 0
MOCK_NO_REPO
chmod +x "$mock_bin7/gh"
mock_log7=$(mktemp)
rc=0
out=$(cd "$norepo_dir" && PATH="$mock_bin7:$PATH" MOCK_LOG="$mock_log7" \
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null bash "$TARGET" fetch --issue 999 2>&1) || rc=$?
assert_exit "TC-31 unresolvable repo → exit 0 (non-blocking degrade)" 0 "$rc"
if grep -qE 'issue view 999 --json body' "$mock_log7"; then
  pass "TC-31b unresolvable repo degrades to a --repo-less gh invocation"
else
  fail "TC-31b expected a --repo-less 'issue view' invocation: $(cat "$mock_log7")"
fi
if printf '%s' "$out" | grep -q 'owner/repo を解決できません'; then
  pass "TC-31c unresolvable repo surfaces a WARNING instead of degrading silently"
else
  fail "TC-31c missing owner/repo resolution WARNING: $out"
fi
printf '%s\n' "$out" | sed -n 's/^tmpfile_[a-z]*=//p' | xargs -r rm -f
rm -f "$mock_log7"
rm -rf "$mock_bin7" "$norepo_dir"

print_summary "$(basename "$0")" "If you weaken or remove the 50% shrinkage guard / empty-write rejection / missing-args check / gh-edit error capture / _emit_body_update_incident fallback in issue-body-safe-update.sh, body truncation or silent auth-failure regressions become invisible. Dropping the explicit --repo flag likewise re-breaks every body update under an SSH host alias. Keep the guards intact and update the test if the guards intentionally change."
