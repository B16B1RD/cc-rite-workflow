#!/bin/bash
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
HELPER="$ROOT/hooks/scripts/ready-pr-head-gate.sh"
SB=$(mktemp -d)
trap 'rm -rf "$SB"' EXIT
mkdir -p "$SB/bin" "$SB/plugin/hooks/scripts"
LOG="$SB/calls.log"

cat > "$SB/bin/gh" <<'EOF'
#!/bin/bash
[ "${GH_FAIL:-0}" = 1 ] && exit 1
case "$*" in *headRefName*) printf '%s\n' "${GH_WM_FIELDS:-}"; exit 0 ;; esac
printf '%s\n' "${PR_HEAD:-head}"
EOF
cat > "$SB/bin/git" <<'EOF'
#!/bin/bash
printf 'git %s\n' "$*" >> "$CALL_LOG"
case "$1 $2" in
  'rev-parse HEAD') printf '%s\n' "${CURRENT_HEAD:-head}" ;;
  'fetch origin') [ "${FETCH_FAIL:-0}" = 1 ] && exit 1; exit 0 ;;
  'worktree add')
    [ "${ADD_FAIL:-0}" = 1 ] && exit 1
    mkdir -p "$4"
    printf '%s' "$4" > "$TMP_PATH_LOG"
    ;;
  'worktree remove')
    [ "${REMOVE_FAIL:-0}" = 1 ] && exit 1
    rm -rf "$4"
    ;;
esac
EOF
cat > "$SB/plugin/hooks/scripts/bang-backtick-check.sh" <<'EOF'
#!/bin/bash
printf 'scanner %s\n' "$*" >> "$CALL_LOG"
[ "${SCAN_SLEEP:-0}" = 1 ] && sleep 30
exit "${SCAN_RC:-0}"
EOF
chmod +x "$SB/bin/gh" "$SB/bin/git" "$SB/plugin/hooks/scripts/bang-backtick-check.sh" "$HELPER"
export PATH="$SB/bin:$PATH" CALL_LOG="$LOG" TMP_PATH_LOG="$SB/tmp-path"

pass=0; fail=0
ok(){ pass=$((pass+1)); }
bad(){ echo "FAIL: $*" >&2; fail=$((fail+1)); }
run_gate(){ PATH="$SB/bin:$PATH" bash "$HELPER" --pr 42 --repo owner/repo --plugin-root "$SB/plugin"; }
reset_case(){ : > "$LOG"; rm -f "$SB/tmp-path"; unset GH_FAIL FETCH_FAIL ADD_FAIL REMOVE_FAIL SCAN_SLEEP; export SCAN_RC=0; }

# T-01: matching head scans the current checkout and creates no worktree.
reset_case; export CURRENT_HEAD=same PR_HEAD=same
run_gate >/dev/null 2>"$SB/err" && grep -q 'scanner .*--repo-root \.' "$LOG" && ! grep -q 'worktree add' "$LOG" && ok || bad T-01

# T-02/T-05: mismatched head scans the detached PR-head root, emits marker,
# removes it, and preserves a scanner finding as rc=1.
reset_case; export CURRENT_HEAD=base PR_HEAD=prhead SCAN_RC=1
rc=0; run_gate >/dev/null 2>"$SB/err" || rc=$?
tmp=$(cat "$SB/tmp-path" 2>/dev/null || true)
[ "$rc" -eq 1 ] && grep -q 'READY_GATE_PR_HEAD_RESOLVED=1; head_oid=prhead' "$SB/err" && grep -q "scanner .*--repo-root $tmp" "$LOG" && [ ! -e "$tmp" ] && ok || bad T-02-T-05

# T-03: PR head lookup fails before scanner invocation.
reset_case; export GH_FAIL=1 CURRENT_HEAD=base PR_HEAD=prhead
rc=0; run_gate >/dev/null 2>"$SB/err" || rc=$?
[ "$rc" -eq 2 ] && ! grep -q scanner "$LOG" && ok || bad T-03

# T-04: fetch and worktree-add failures never fall back to current checkout.
for mode in FETCH_FAIL ADD_FAIL; do
  reset_case; export CURRENT_HEAD=base PR_HEAD=prhead; export "$mode"=1
  rc=0; run_gate >/dev/null 2>"$SB/err" || rc=$?
  [ "$rc" -eq 2 ] && ! grep -q scanner "$LOG" && ok || bad "T-04-$mode"
done

# T-07: remove failure warns but does not change a clean gate result.
reset_case; export CURRENT_HEAD=base PR_HEAD=prhead REMOVE_FAIL=1
run_gate >/dev/null 2>"$SB/err" && grep -q 'WARNING: Ready gate の一時 worktreeを\|WARNING: Ready gate の一時 worktree' "$SB/err" && ok || bad T-07

# Signal cleanup uses canonical status and invokes worktree removal.
reset_case; export CURRENT_HEAD=base PR_HEAD=prhead SCAN_SLEEP=1
PATH="$SB/bin:$PATH" setsid bash "$HELPER" --pr 42 --repo owner/repo --plugin-root "$SB/plugin" >/dev/null 2>"$SB/err" & pid=$!
for _ in 1 2 3 4 5; do [ -s "$SB/tmp-path" ] && break; sleep 0.1; done
kill -TERM -- "-$pid"; rc=0; wait "$pid" || rc=$?
[ "$rc" -eq 143 ] && grep -q 'worktree remove --force' "$LOG" && ok || bad signal_cleanup

# T-06: work-memory overrides are sanitized and written under the helper lock.
wm_repo="$SB/wm-repo"; mkdir -p "$wm_repo"; git -C "$wm_repo" init -q
(
  cd "$wm_repo" || exit 1
  WM_SOURCE=ready WM_PHASE=ready WM_PHASE_DETAIL=done WM_NEXT_ACTION=next \
    WM_BODY_TEXT=body WM_ISSUE_NUMBER=42 WM_PLUGIN_ROOT="$ROOT" \
    WM_BRANCH_OVERRIDE='feature/"quoted"' WM_LAST_COMMIT_OVERRIDE=0123456789abcdef \
    bash "$ROOT/hooks/local-wm-update.sh"
) >/dev/null 2>"$SB/wm-err" || bad T-06-run
wm_file="$wm_repo/.rite-work-memory/issue-42.md"
grep -qF 'branch: "feature/\"quoted\""' "$wm_file" && grep -qF 'last_commit: "0123456789abcdef"' "$wm_file" && ok || bad T-06-values

# Missing option values terminate instead of looping.
rc=0; timeout 1 bash "$HELPER" --pr >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] && ok || bad missing_option_value

# PR-head lookup failure must not invoke the work-memory writer.
WM_HELPER="$ROOT/hooks/scripts/ready-work-memory-update.sh"
cat > "$SB/plugin/hooks/local-wm-update.sh" <<'EOF'
#!/bin/bash
printf 'wm branch=%s oid=%s\n' "$WM_BRANCH_OVERRIDE" "$WM_LAST_COMMIT_OVERRIDE" >> "$CALL_LOG"
EOF
chmod +x "$SB/plugin/hooks/local-wm-update.sh" "$WM_HELPER"
reset_case; export GH_FAIL=1
bash "$WM_HELPER" --pr 42 --issue 42 --repo owner/repo --plugin-root "$SB/plugin" >/dev/null 2>"$SB/wm-skip"
! grep -q '^wm ' "$LOG" && grep -q '更新をスキップ' "$SB/wm-skip" && ok || bad wm_failure_skip
reset_case; export GH_WM_FIELDS=$'feature/ok\tfeedface'
bash "$WM_HELPER" --pr 42 --issue 42 --repo owner/repo --plugin-root "$SB/plugin" >/dev/null 2>"$SB/wm-ok"
grep -q 'wm branch=feature/ok oid=feedface' "$LOG" && ok || bad wm_success

echo "$pass PASS / $fail FAIL"
[ "$fail" -eq 0 ]
