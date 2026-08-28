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
if [ "${SCAN_SIGNAL_PARENT:-0}" = 1 ]; then
  helper_pid=$(ps -o ppid= -p "$PPID" | tr -d ' ')
  kill -TERM "$helper_pid"
fi
exit "${SCAN_RC:-0}"
EOF
chmod +x "$SB/bin/gh" "$SB/bin/git" "$SB/plugin/hooks/scripts/bang-backtick-check.sh" "$HELPER"
export PATH="$SB/bin:$PATH" CALL_LOG="$LOG" TMP_PATH_LOG="$SB/tmp-path"

pass=0; fail=0
ok(){ pass=$((pass+1)); }
bad(){ echo "FAIL: $*" >&2; fail=$((fail+1)); }
run_gate(){ PATH="$SB/bin:$PATH" bash "$HELPER" --pr 42 --repo owner/repo --plugin-root "$SB/plugin"; }
reset_case(){ : > "$LOG"; rm -f "$SB/tmp-path"; unset GH_FAIL FETCH_FAIL ADD_FAIL REMOVE_FAIL SCAN_SIGNAL_PARENT; export SCAN_RC=0; }

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
reset_case; export CURRENT_HEAD=base PR_HEAD=prhead SCAN_SIGNAL_PARENT=1
rc=0; run_gate >/dev/null 2>"$SB/err" || rc=$?
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
rc=0; bash "$HELPER" --pr >/dev/null 2>&1 || rc=$?
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

rc=0; bash "$WM_HELPER" --pr 42 --issue 42 --repo '' --plugin-root "$SB/plugin" >/dev/null 2>"$SB/wm-invalid" || rc=$?
[ "$rc" -eq 2 ] && grep -q 'owner/repo is required' "$SB/wm-invalid" && ok || bad wm_empty_repo
rc=0; bash "$WM_HELPER" --pr 42 --issue 42 --repo owner/repo --plugin-root "$SB/missing" >/dev/null 2>"$SB/wm-invalid" || rc=$?
[ "$rc" -eq 2 ] && grep -q 'local-wm-update.sh not found' "$SB/wm-invalid" && ok || bad wm_invalid_plugin
cat > "$SB/plugin/hooks/local-wm-update.sh" <<'EOF'
#!/bin/bash
exit 7
EOF
chmod +x "$SB/plugin/hooks/local-wm-update.sh"
reset_case; export GH_WM_FIELDS=$'feature/ok\tfeedface'
bash "$WM_HELPER" --pr 42 --issue 42 --repo owner/repo --plugin-root "$SB/plugin" >/dev/null 2>"$SB/wm-writer-fail"
grep -q 'writer failed (rc=7)' "$SB/wm-writer-fail" && ok || bad wm_writer_warning

# ----- reviewed-head gate (latest review JSON commit_sha vs HEAD) ----------
RH="$ROOT/hooks/scripts/ready-reviewed-head-gate.sh"
RH_DIR="$SB/review-results"
mkdir -p "$RH_DIR"
write_review_json() {
  local sha="$1" name="$2"
  jq -n --arg sha "$sha" --argjson pr 42 \
    '{schema_version:"1.1.0", pr_number:$pr, timestamp:"T", commit_sha:$sha, overall_assessment:"approve", findings:[]}' \
    > "$RH_DIR/$name"
}
run_rh() {
  PATH="$SB/bin:$PATH" bash "$RH" --pr 42 --plugin-root "$SB/plugin" --results-dir "$RH_DIR"
}
chmod +x "$RH"

# T-01: matching commit_sha lets Ready proceed (rc=0).
reset_case
export CURRENT_HEAD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
rm -f "$RH_DIR"/42-*.json
write_review_json "$CURRENT_HEAD" "42-20260101000000.json"
run_rh >/dev/null 2>"$SB/rh-err" && grep -q 'READY_REVIEWED_HEAD=match' "$SB/rh-err" && ok || bad RH-T-01

# T-02: commit_sha older than HEAD is a fail-loud mismatch (rc=1) with both SHAs and iterate hint.
reset_case
export CURRENT_HEAD=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
rm -f "$RH_DIR"/42-*.json
write_review_json "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "42-20260101000000.json"
rc=0; run_rh >/dev/null 2>"$SB/rh-err" || rc=$?
[ "$rc" -eq 1 ] \
  && grep -q 'READY_REVIEWED_HEAD=mismatch' "$SB/rh-err" \
  && grep -q 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' "$SB/rh-err" \
  && grep -q 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' "$SB/rh-err" \
  && grep -q '/rite:iterate 42' "$SB/rh-err" \
  && ok || bad RH-T-02

# T-03: missing review JSON (including archive-only) is fail-loud, never Ready.
reset_case
export CURRENT_HEAD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
rm -f "$RH_DIR"/42-*.json
mkdir -p "$RH_DIR/archive"
write_review_json "$CURRENT_HEAD" "archive/42-20260101000000.json"
rc=0; run_rh >/dev/null 2>"$SB/rh-err" || rc=$?
[ "$rc" -eq 1 ] \
  && grep -q 'READY_REVIEWED_HEAD=missing_json' "$SB/rh-err" \
  && grep -q 'archive 済み' "$SB/rh-err" \
  && grep -q '/rite:iterate 42' "$SB/rh-err" \
  && ok || bad RH-T-03

# git rev-parse failure is fail-loud (not a Ready permit).
reset_case
cat > "$SB/bin/git" <<'EOF'
#!/bin/bash
printf 'git %s\n' "$*" >> "$CALL_LOG"
case "$1 $2" in
  'rev-parse HEAD') exit 1 ;;
esac
exit 0
EOF
chmod +x "$SB/bin/git"
rm -f "$RH_DIR"/42-*.json
write_review_json aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa "42-20260101000000.json"
rc=0; run_rh >/dev/null 2>"$SB/rh-err" || rc=$?
[ "$rc" -eq 1 ] && grep -q 'READY_REVIEWED_HEAD=rev_parse_failed' "$SB/rh-err" && ok || bad RH-rev-parse

# Restore the PATH git stub used by RH-T-* (the rev-parse-fail stub replaced it).
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
chmod +x "$SB/bin/git"

# ----- sweep SHA exception (#2439) ----------------------------------------
ST="$SB/state"
mkdir -p "$ST/.rite/state"
write_done_lines() {
  printf '%s\n' "$@" > "$ST/.rite/state/nb-sweep-done-42.txt"
}
run_rh_st() {
  PATH="$SB/bin:$PATH" bash "$RH" --pr 42 --plugin-root "$SB/plugin" \
    --results-dir "$RH_DIR" --state-root "$ST"
}
# Production argv is --plugin-root only. JSON and done-file live under the
# stubbed state-path-resolve.sh root.
run_rh_prod() {
  PATH="$SB/bin:$PATH" bash "$RH" --pr 42 --plugin-root "$SB/plugin"
}
REV_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
REV_B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
REV_C=cccccccccccccccccccccccccccccccccccccccc

# RH-SW-T-01 / AC-1: JSON=A, line2=B, HEAD=B, JSON≠HEAD → via=sweep (not via=json).
reset_case
export CURRENT_HEAD=$REV_B
rm -f "$RH_DIR"/42-*.json
write_review_json "$REV_A" "42-20260101000000.json"
write_done_lines done "$REV_B"
run_rh_st >/dev/null 2>"$SB/rh-err" \
  && grep -q 'READY_REVIEWED_HEAD=match' "$SB/rh-err" \
  && grep -q 'via=sweep' "$SB/rh-err" \
  && ! grep -q 'via=json' "$SB/rh-err" \
  && ok || bad RH-SW-T-01

# RH-SW-T-02 / AC-2: JSON=A, line2=B, HEAD=C → rc=1, 3 SHA, not via=sweep pass.
reset_case
export CURRENT_HEAD=$REV_C
rm -f "$RH_DIR"/42-*.json
write_review_json "$REV_A" "42-20260101000000.json"
write_done_lines done "$REV_B"
rc=0; run_rh_st >/dev/null 2>"$SB/rh-err" || rc=$?
[ "$rc" -eq 1 ] \
  && grep -q 'READY_REVIEWED_HEAD=mismatch' "$SB/rh-err" \
  && grep -q "$REV_A" "$SB/rh-err" \
  && grep -q "$REV_B" "$SB/rh-err" \
  && grep -q "$REV_C" "$SB/rh-err" \
  && grep -q 'sweep=' "$SB/rh-err" \
  && ! grep -q 'via=sweep' "$SB/rh-err" \
  && ok || bad RH-SW-T-02

# RH-SW-T-03 / AC-3: done-file 不在の mismatch 文言は RH-T-02 と同一（--results-dir のみ）。
reset_case
export CURRENT_HEAD=$REV_B
rm -f "$RH_DIR"/42-*.json "$ST/.rite/state/nb-sweep-done-42.txt"
write_review_json "$REV_A" "42-20260101000000.json"
rc=0; run_rh >/dev/null 2>"$SB/rh-err" || rc=$?
[ "$rc" -eq 1 ] \
  && grep -q 'READY_REVIEWED_HEAD=mismatch' "$SB/rh-err" \
  && grep -q "$REV_A" "$SB/rh-err" \
  && grep -q "$REV_B" "$SB/rh-err" \
  && grep -q '/rite:iterate 42' "$SB/rh-err" \
  && ! grep -q 'sweep=' "$SB/rh-err" \
  && ! grep -q 'sweep_sha_invalid' "$SB/rh-err" \
  && ok || bad RH-SW-T-03

# RH-SW-T-04 / AC-3: 1 行 done / noop は既存 mismatch。sweep_sha_invalid に倒さない。
for kind in done noop; do
  reset_case
  export CURRENT_HEAD=$REV_B
  rm -f "$RH_DIR"/42-*.json
  write_review_json "$REV_A" "42-20260101000000.json"
  write_done_lines "$kind"
  rc=0; run_rh_st >/dev/null 2>"$SB/rh-err" || rc=$?
  [ "$rc" -eq 1 ] \
    && grep -q 'READY_REVIEWED_HEAD=mismatch' "$SB/rh-err" \
    && grep -q "$REV_A" "$SB/rh-err" \
    && grep -q "$REV_B" "$SB/rh-err" \
    && grep -q '/rite:iterate 42' "$SB/rh-err" \
    && ! grep -q 'sweep_sha_invalid' "$SB/rh-err" \
    && ! grep -q 'sweep=' "$SB/rh-err" \
    && ok || bad "RH-SW-T-04-$kind"
done

# RH-SW-T-05 / AC-4: 2 行目が空 / 非 hex → sweep_sha_invalid。既存判定へフォールバックしない。
reset_case
export CURRENT_HEAD=$REV_B
rm -f "$RH_DIR"/42-*.json
write_review_json "$REV_A" "42-20260101000000.json"
write_done_lines done ""
rc=0; run_rh_st >/dev/null 2>"$SB/rh-err" || rc=$?
[ "$rc" -eq 1 ] \
  && grep -q 'READY_REVIEWED_HEAD=sweep_sha_invalid' "$SB/rh-err" \
  && ! grep -q 'READY_REVIEWED_HEAD=mismatch' "$SB/rh-err" \
  && ok || bad RH-SW-T-05-empty
reset_case
export CURRENT_HEAD=$REV_B
rm -f "$RH_DIR"/42-*.json
write_review_json "$REV_A" "42-20260101000000.json"
write_done_lines done not-a-sha
rc=0; run_rh_st >/dev/null 2>"$SB/rh-err" || rc=$?
[ "$rc" -eq 1 ] \
  && grep -q 'READY_REVIEWED_HEAD=sweep_sha_invalid' "$SB/rh-err" \
  && ! grep -q 'READY_REVIEWED_HEAD=mismatch' "$SB/rh-err" \
  && ok || bad RH-SW-T-05-nonhex
reset_case
export CURRENT_HEAD=$REV_B
rm -f "$RH_DIR"/42-*.json
write_review_json "$REV_A" "42-20260101000000.json"
write_done_lines done abc
rc=0; run_rh_st >/dev/null 2>"$SB/rh-err" || rc=$?
[ "$rc" -eq 1 ] \
  && grep -q 'READY_REVIEWED_HEAD=sweep_sha_invalid' "$SB/rh-err" \
  && ! grep -q 'READY_REVIEWED_HEAD=mismatch' "$SB/rh-err" \
  && ok || bad RH-SW-T-05-short

# RH-SW-T-09 / AC-3: JSON==HEAD のとき不正 2 行 done-file があっても via=json（非読取の正対照）。
reset_case
export CURRENT_HEAD=$REV_A
rm -f "$RH_DIR"/42-*.json
write_review_json "$REV_A" "42-20260101000000.json"
write_done_lines done not-a-sha
run_rh_st >/dev/null 2>"$SB/rh-err" \
  && grep -q 'READY_REVIEWED_HEAD=match' "$SB/rh-err" \
  && grep -q 'via=json' "$SB/rh-err" \
  && ! grep -q 'sweep_sha_invalid' "$SB/rh-err" \
  && ! grep -q 'via=sweep' "$SB/rh-err" \
  && ok || bad RH-SW-T-09

# RH-SW-T-10 / AC-1 production argv: --plugin-root only (no --results-dir /
# --state-root). Pins the elif resolver that production ready actually runs.
reset_case
export CURRENT_HEAD=$REV_B
mkdir -p "$SB/plugin/hooks" "$ST/.rite/review-results"
cat > "$SB/plugin/hooks/state-path-resolve.sh" <<EOF
#!/bin/bash
printf '%s\n' "$ST"
EOF
chmod +x "$SB/plugin/hooks/state-path-resolve.sh"
rm -f "$ST/.rite/review-results"/42-*.json
jq -n --arg sha "$REV_A" --argjson pr 42 \
  '{schema_version:"1.1.0", pr_number:$pr, timestamp:"T", commit_sha:$sha, overall_assessment:"approve", findings:[]}' \
  > "$ST/.rite/review-results/42-20260101000000.json"
write_done_lines done "$REV_B"
run_rh_prod >/dev/null 2>"$SB/rh-err" \
  && grep -q 'READY_REVIEWED_HEAD=match' "$SB/rh-err" \
  && grep -q 'via=sweep' "$SB/rh-err" \
  && ! grep -q 'via=json' "$SB/rh-err" \
  && ok || bad RH-SW-T-10

echo "$pass PASS / $fail FAIL"
[ "$fail" -eq 0 ]
