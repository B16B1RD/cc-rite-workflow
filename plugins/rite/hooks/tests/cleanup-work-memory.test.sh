#!/bin/bash
# cleanup-work-memory.test.sh
#
# Pin the mktemp-failure fallback path: even when the TMP_STATE mktemp fails,
# Step 2 (.rite-compact-state removal) and Step 3 (per-issue work-memory file
# removal) MUST still execute. Without this regression guard, a `set -euo
# pipefail` regression on the mktemp line could abort the script before any
# cleanup runs — leaving stale state files that would silently misroute the
# next session.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/../cleanup-work-memory.sh"
TEST_DIR="$(mktemp -d)"
PASS=0
FAIL=0

# Clean session-id env for standalone runs (same convention as flow-state.test.sh).
# cleanup-work-memory.sh now resolves its flow-state file via flow-state.sh path,
# which is env-first (CLAUDE_CODE_SESSION_ID / CLAUDE_SESSION_ID). Without this
# unset, the dogfooding session's ambient session id would leak in and override
# each test's seeded .rite-session-id, resolving to a path outside TEST_DIR and
# silently no-op'ing the Step 1 flow-state reset under test.
unset CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID

cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

# Seed a per-session flow-state file (schema_v2/v3 form) instead of the legacy
# shared .rite-flow-state, matching what flow-state.sh path actually resolves
# to at runtime. Sets .rite-session-id so the resolver picks this session
# deterministically.
seed_session_flow_state() {
  local dir="$1" sid="$2" json="$3"
  mkdir -p "$dir/.rite/sessions"
  printf '%s' "$sid" > "$dir/.rite-session-id"
  printf '%s' "$json" > "$dir/.rite/sessions/${sid}.flow-state"
}

echo "=== cleanup-work-memory.sh tests ==="
echo ""

# ─── TC-001: TMP_STATE mktemp 失敗時でも Step 2/3 が実行されること ────────
echo "TC-001: TMP_STATE mktemp failure does not abort Step 2/3 cleanup"
dir001="$TEST_DIR/tc001"
mkdir -p "$dir001/.rite/work-memory"
# Seed the per-session flow-state file (schema_v2/v3), compact-state, and a
# per-issue work memory file
seed_session_flow_state "$dir001" "tc001-sid" '{"active":true,"issue_number":42,"phase":"completed","branch":"feat/issue-42-test"}'
echo '{"compact_state":"recovering","active_issue":42}' > "$dir001/.rite-compact-state"
echo "# work memory for issue 42" > "$dir001/.rite/work-memory/issue-42.md"

# Inject a mktemp shim that fails only when the target argument matches the
# FLOW_STATE.tmp pattern (matches both the legacy .rite-flow-state.tmp.* name
# and the per-session .../sid.flow-state.tmp.* name — both end in
# "flow-state.tmp."). All other mktemp invocations (test helpers, child
# scripts) pass through to real mktemp.
mkdir -p "$dir001/bin"
cat > "$dir001/bin/mktemp" <<'EOF'
#!/bin/bash
for arg in "$@"; do
  case "$arg" in
    *flow-state.tmp.*) exit 1 ;;
  esac
done
exec /usr/bin/mktemp "$@"
EOF
chmod +x "$dir001/bin/mktemp"

# Run with the shim active and cwd at the test dir. CLOSE_MODE=false (default)
# exercises the reset path that creates TMP_STATE. state-path-resolve.sh
# resolves STATE_ROOT from $(pwd), so cd into the dir before running.
err_log="$TEST_DIR/tc001.err"
( cd "$dir001" && PATH="$dir001/bin:$PATH" bash "$HOOK" 2>"$err_log" >/dev/null ) || true

# Step 1 (flow-state reset) should have been skipped with a WARNING
if grep -q "TMP_STATE mktemp failed" "$err_log"; then
  pass "TC-001 Step 1 mktemp failure WARNING emitted"
else
  fail "TC-001 expected 'TMP_STATE mktemp failed' WARNING, got: $(head -5 "$err_log")"
fi

# Step 2 (.rite-compact-state removal) should have succeeded
if [ ! -f "$dir001/.rite-compact-state" ]; then
  pass "TC-001 Step 2: .rite-compact-state removed despite Step 1 mktemp failure"
else
  fail "TC-001 Step 2 SKIPPED: .rite-compact-state still present (cleanup aborted on Step 1 failure)"
fi

# Step 3 (per-issue work memory removal) should have succeeded
if [ ! -f "$dir001/.rite/work-memory/issue-42.md" ]; then
  pass "TC-001 Step 3: per-issue work memory removed despite Step 1 mktemp failure"
else
  fail "TC-001 Step 3 SKIPPED: issue-42.md still present (cleanup aborted on Step 1 failure)"
fi
echo ""

# ─── TC-002: 正常路 (negative control) ──────────────────────────
echo "TC-002: happy path with working mktemp removes all three"
dir002="$TEST_DIR/tc002"
mkdir -p "$dir002/.rite/work-memory"
seed_session_flow_state "$dir002" "tc002-sid" '{"active":true,"issue_number":43,"phase":"completed"}'
echo '{"compact_state":"recovering","active_issue":43}' > "$dir002/.rite-compact-state"
echo "# wm 43" > "$dir002/.rite/work-memory/issue-43.md"

( cd "$dir002" && bash "$HOOK" >/dev/null 2>&1 ) || true

# After successful run: compact-state and per-issue wm file removed.
if [ ! -f "$dir002/.rite-compact-state" ] \
   && [ ! -f "$dir002/.rite/work-memory/issue-43.md" ]; then
  pass "TC-002 happy path: Step 2/3 cleanup completed (compact-state + per-issue wm removed)"
else
  fail "TC-002 happy path partial: compact-state present=$([ -f "$dir002/.rite-compact-state" ] && echo y || echo n), wm present=$([ -f "$dir002/.rite/work-memory/issue-43.md" ] && echo y || echo n)"
fi

# Directly verify the Step 1 reset outcome (the PR's core spec): the per-session
# flow-state file must actually be reset to active:false. Without this, a
# regression that no-ops the reset (e.g. #695's bug) would still pass every
# other assertion in this file.
tc002_session_file="$dir002/.rite/sessions/tc002-sid.flow-state"
tc002_active=$(jq -r '.active' "$tc002_session_file" 2>/dev/null)
tc002_phase=$(jq -r '.phase' "$tc002_session_file" 2>/dev/null)
if [ "$tc002_active" = "false" ] && [ "$tc002_phase" = "completed" ]; then
  pass "TC-002 happy path: per-session flow-state reset to active=false, phase=completed"
else
  fail "TC-002 happy path: per-session flow-state not reset (active=$tc002_active, phase=$tc002_phase)"
fi
echo ""

# ─── TC-003: mv failure path emits rc-carrying WARNING ───────────
# The Step 1 mv site uses an if/else form with rc capture and _mv_err head -3
# dump. A regression that drops the dump line or reverts to bash-! antipattern
# would still PASS TC-001/002 because they only check side-effects, not the
# WARNING content. PATH-shim mv to force failure with a known rc.
echo "TC-003: Step 1 mv mutation emits WARNING with real rc"
dir003="$TEST_DIR/tc003"
mkdir -p "$dir003/.rite/work-memory"
seed_session_flow_state "$dir003" "tc003-sid" '{"active":true,"issue_number":44,"phase":"completed","branch":"feat/issue-44"}'
mkdir -p "$dir003/bin"
cat > "$dir003/bin/mv" <<'MV_SHIM'
#!/bin/bash
# Fail only when targeting the flow-state file (matches both the legacy
# .rite-flow-state name and the per-session .../sid.flow-state name — both
# end in "flow-state"); let other mv calls succeed
for arg in "$@"; do
  case "$arg" in
    *flow-state) exit 17 ;;
  esac
done
exec /bin/mv "$@"
MV_SHIM
chmod +x "$dir003/bin/mv"
stderr003=$(cd "$dir003" && PATH="$dir003/bin:$PATH" bash "$HOOK" 2>&1 >/dev/null || true)
if printf '%s' "$stderr003" | grep -qE 'flow-state の更新に失敗しました \(mv rc=[1-9][0-9]*\)'; then
  pass "TC-003: Step 1 mv WARNING carries real rc"
else
  fail "TC-003: Step 1 mv WARNING missing or rc collapsed (a bash-! regression would emit rc=0). stderr: $stderr003"
fi
echo ""

# ─── TC-004: close mode happy path (--issue N) ─────────────────
# /rite:issue-close 呼び出し時の標準フロー: 指定 Issue の work memory のみを削除し、
# 他 Issue の wm は残す。逆に他 Issue を巻き込んで消すと進行中作業の状態が失われる。
echo "TC-004: --issue N close mode removes only the specified issue's wm"
dir004="$TEST_DIR/tc004"
mkdir -p "$dir004/.rite/work-memory"
echo "# wm 50" > "$dir004/.rite/work-memory/issue-50.md"
echo "# wm 51" > "$dir004/.rite/work-memory/issue-51.md"
( cd "$dir004" && bash "$HOOK" --issue 50 >/dev/null 2>&1 ) || true
if [ ! -f "$dir004/.rite/work-memory/issue-50.md" ] \
   && [ -f "$dir004/.rite/work-memory/issue-51.md" ]; then
  pass "TC-004 close mode: target removed, other issue preserved"
else
  fail "TC-004 close mode side-effects wrong: target removed=$([ ! -f "$dir004/.rite/work-memory/issue-50.md" ] && echo y || echo n), other preserved=$([ -f "$dir004/.rite/work-memory/issue-51.md" ] && echo y || echo n)"
fi
echo ""

# ─── TC-005: --issue 引数が非数値なら拒否 ─────────────────────
# 数値バリデーション (cleanup-work-memory.sh L36) が抜けると、後段で --argjson に
# 非数値が流れ込み、別の Issue を巻き込むまたは jq エラーで全体が止まる。
echo "TC-005: --issue with non-numeric value exits 1 with ERROR"
dir005="$TEST_DIR/tc005"
mkdir -p "$dir005"
err005="$TEST_DIR/tc005.err"
rc005=0
( cd "$dir005" && bash "$HOOK" --issue abc 2>"$err005" >/dev/null ) || rc005=$?
if [ "$rc005" != 0 ] && grep -q "must be a positive integer" "$err005"; then
  pass "TC-005 non-numeric --issue rejected (rc=$rc005, ERROR emitted)"
else
  fail "TC-005 expected rc!=0 + 'must be a positive integer' ERROR, got rc=$rc005, stderr: $(head -3 "$err005")"
fi
echo ""

# ─── TC-006: --issue 引数欠落の検出 ───────────────────────────
# --issue を書き忘れた場合に next-token が値として読まれて誤動作するのを防ぐ。
echo "TC-006: --issue with missing value exits 1 with ERROR"
dir006="$TEST_DIR/tc006"
mkdir -p "$dir006"
err006="$TEST_DIR/tc006.err"
rc006=0
( cd "$dir006" && bash "$HOOK" --issue 2>"$err006" >/dev/null ) || rc006=$?
if [ "$rc006" != 0 ] && grep -q "requires a number" "$err006"; then
  pass "TC-006 missing --issue value rejected (rc=$rc006, ERROR emitted)"
else
  fail "TC-006 expected rc!=0 + 'requires a number' ERROR, got rc=$rc006, stderr: $(head -3 "$err006")"
fi
echo ""

# ─── TC-007: find permission-denied で「残存: unknown」を報告する ───────────
# find stderr を /dev/null に流していると WM_DIR が読めなくても「残存: 0 件」と
# 誤報告される経路があった。stderr capture pattern が後退した場合の regression を
# detect するため、find が stderr を吐く PATH shim で run し、output に "unknown" が
# 含まれることを確認する。
echo "TC-007: find permission denied surfaces as remaining=unknown"
dir007="$TEST_DIR/tc007"
mkdir -p "$dir007/.rite/work-memory"
echo "wm a" > "$dir007/.rite/work-memory/issue-1.md"
mkdir -p "$dir007/bin"
cat > "$dir007/bin/find" <<'EOF'
#!/bin/bash
echo "find: '.rite/work-memory': Permission denied" >&2
exit 1
EOF
chmod +x "$dir007/bin/find"
out007="$TEST_DIR/tc007.out"
( cd "$dir007" && PATH="$dir007/bin:$PATH" bash "$HOOK" >"$out007" 2>&1 ) || true
# stderr capture が機能していれば "残存: unknown 件" を表示し、permission denied の WARNING が出る。
# silent regression が入ると "残存: 0 件" になり、本 assertion が fail する。
if grep -q "残存: unknown 件" "$out007" && grep -q "permission denied" "$out007"; then
  pass "TC-007 find permission-denied surfaced as remaining=unknown + WARNING"
else
  fail "TC-007 expected '残存: unknown 件' + permission-denied WARNING, got: $(head -10 "$out007")"
fi
echo ""

# ─── TC-008: 破損 FLOW_STATE は jq 失敗を WARNING で報告する ──────────────
# A regression that drops the rc-check would let a corrupt FLOW_STATE silently
# route the cleanup audit to issue=0, hiding from the operator that their real
# issue number was discarded.
echo "TC-008: corrupt FLOW_STATE surfaces jq rc in WARNING"
dir008="$TEST_DIR/tc008"
mkdir -p "$dir008/.rite/work-memory"
mkdir -p "$dir008/.rite/sessions"
printf '%s' "tc008-sid" > "$dir008/.rite-session-id"
printf 'not-valid-json{{' > "$dir008/.rite/sessions/tc008-sid.flow-state"
out008="$TEST_DIR/tc008.out"
( cd "$dir008" && bash "$HOOK" >"$out008" 2>&1 ) || true
if grep -qE 'cleanup-work-memory: .*flow-state の \.issue_number 取得失敗 \(rc=[1-9]' "$out008"; then
  pass "TC-008 corrupt FLOW_STATE surfaces WARNING with real jq rc"
else
  fail "TC-008 expected WARNING with rc on corrupt FLOW_STATE; got: $(head -10 "$out008")"
fi
echo ""

# ─── TC-resolver-fallback: session resolution failure surfaces WARNING and still resets legacy file ──────────
# Regression guard for the resolver-failure branch added to fix #695: when no
# .rite-session-id / session env var is available, flow-state.sh path fails,
# and cleanup-work-memory.sh must (a) emit a WARNING (not silently swallow the
# failure) and (b) still fall back to resetting the legacy .rite-flow-state
# file. Without this guard, a regression that reverts the stderr capture +
# WARNING (or drops the fallback reset) would not be caught by any other TC —
# TC-001/002/003/008 all seed a valid .rite-session-id, so resolver always
# succeeds in those paths.
echo "TC-resolver-fallback: session resolution failure emits WARNING and resets legacy file"
dir_resolver="$TEST_DIR/tc_resolver_fallback"
mkdir -p "$dir_resolver/.rite/work-memory"
echo '{"active":true,"issue_number":77,"phase":"cleanup"}' > "$dir_resolver/.rite-flow-state"
out_resolver="$TEST_DIR/tc_resolver_fallback.out"
( cd "$dir_resolver" && bash "$HOOK" >"$out_resolver" 2>&1 ) || true
resolver_warning_seen=$(grep -c 'flow-state.sh path resolution failed' "$out_resolver" 2>/dev/null || true)
resolver_active=$(jq -r '.active' "$dir_resolver/.rite-flow-state" 2>/dev/null)
if [ "${resolver_warning_seen:-0}" -ge 1 ] && [ "$resolver_active" = "false" ]; then
  pass "TC-resolver-fallback: WARNING emitted and legacy .rite-flow-state reset to active=false"
else
  fail "TC-resolver-fallback: warning_seen=${resolver_warning_seen:-0}, active=$resolver_active; got: $(head -10 "$out_resolver")"
fi
echo ""

# ─── TC-full-cleanup-removes-per-session-compact: full cleanup removes the per-session compact-state ──────────
# full-cleanup mode must reap the current session's per-session
# compact-state (.rite/sessions/<sid>.compact-state), not just the legacy
# shared file. Non-vacuous: a regression that drops the per-session removal
# block leaves the per-session file behind and fails this assertion.
echo "TC-full-cleanup-removes-per-session-compact: full cleanup removes per-session compact-state"
dir1371="$TEST_DIR/tc1371"
sid1371="test-sid-tc1371"
seed_session_flow_state "$dir1371" "$sid1371" '{"active":true,"issue_number":1371,"phase":"completed"}'
echo '{"compact_state":"recovering","active_issue":1371}' > "$dir1371/.rite-compact-state"
cs1371_session="$dir1371/.rite/sessions/${sid1371}.compact-state"
echo '{"compact_state":"recovering","active_issue":1371}' > "$cs1371_session"
( cd "$dir1371" && bash "$HOOK" >/dev/null 2>&1 ) || true
if [ ! -f "$cs1371_session" ] && [ ! -f "$dir1371/.rite-compact-state" ]; then
  pass "TC-full-cleanup-removes-per-session-compact: per-session and legacy compact-state both removed on full cleanup"
else
  fail "TC-full-cleanup-removes-per-session-compact: cleanup incomplete: per_session_exists=$([ -f "$cs1371_session" ] && echo y || echo n), legacy_exists=$([ -f "$dir1371/.rite-compact-state" ] && echo y || echo n)"
fi
echo ""

# --- Summary ---
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
