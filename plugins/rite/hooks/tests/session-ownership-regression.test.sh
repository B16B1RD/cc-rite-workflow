#!/bin/bash
# Session Ownership 系列 (#173 / #206 / #216 / #558 / #660) regression on
# multi-state format (per-session file, schema_version=2).
#
# Issue #683 / parent #672 AC-7 を verify する。
# 過去 5 件の Issue で導入した防御層が、新形式上でも構造的に成立することを mechanical に確認する。
#
# Coverage:
#   - TC-173 (Per-session isolation)         : 2 session が異なる per-session file に独立に書き込む
#   - TC-206 (SOURCE=startup/clear reset)    : startup/clear 時に自 session の state が active=false にリセット
#   - TC-216 (.rite-session-id auto-read)    : flow-state-update.sh が --session 省略時に file 経由で読み取る
#   - TC-558 (Other-session preservation)    : 他 session の state は reset しない (核心)
#   - TC-660 (active=true gate)              : active=false / true で防御層 (AND-logic) が正しく振舞う
#
# Out of scope (#684 で扱う):
#   - migration / atomic write integrity / cleanup / crash resume
#
# Note (architecture drift since #660): stop-guard.sh は #674 で removal 済み。
# #660 の active=true 前提は現在 pre-tool-bash-guard.sh の AND-logic
# (`.active=true && phase=create_*`) に継承されており、ここを TC-660 で verify する。
#
# Usage: bash plugins/rite/hooks/tests/session-ownership-regression.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK_DIR="$SCRIPT_DIR/.."
HOOK="$HOOK_DIR/flow-state-update.sh"
SESSION_START="$HOOK_DIR/session-start.sh"
PRE_TOOL_GUARD="$HOOK_DIR/pre-tool-bash-guard.sh"
PASS=0
FAIL=0

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required but not installed" >&2
  exit 1
fi

make_test_dir() {
  local d
  d=$(mktemp -d) || { echo "ERROR: mktemp -d failed" >&2; return 1; }
  [ -n "$d" ] && [ -d "$d" ] || { echo "ERROR: test dir invalid" >&2; return 1; }
  (
    set -e
    cd "$d"
    git init -q
    echo a > a && git add a
    git -c user.email=t@test.local -c user.name=test commit -q -m init
  ) || { echo "ERROR: test fixture setup failed in $d" >&2; return 1; }
  echo "$d"
}

write_config() {
  local d="$1" sv="$2"
  cat > "$d/rite-config.yml" << EOF
flow_state:
  schema_version: $sv
EOF
}

write_session_id() {
  echo "$2" > "$1/.rite-session-id"
}

pass() { PASS=$((PASS + 1)); echo "  ✅ PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ❌ FAIL: $1"; }

cleanup_dirs=()
cleanup() {
  local d
  for d in "${cleanup_dirs[@]:-}"; do
    [ -n "$d" ] && [ -d "$d" ] && rm -rf "$d"
  done
  return 0
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
trap 'cleanup; exit 129' HUP

echo "=== session-ownership-regression tests (Issue #683 / parent #672 AC-7) ==="
echo ""

# --------------------------------------------------------------------------
# TC-173: Per-session file isolation (single-file race window が消滅)
# --------------------------------------------------------------------------
echo "TC-173 (Per-session isolation): 2 session が異なる per-session file に独立書き込み"
TD=$(make_test_dir); cleanup_dirs+=("$TD")
write_config "$TD" 2
SID_A="11111111-1111-1111-1111-111111111111"
SID_B="22222222-2222-2222-2222-222222222222"

(cd "$TD" && bash "$HOOK" create --session "$SID_A" \
  --phase "p_a" --issue 100 --branch "ba" --pr 0 --next "na" >/dev/null 2>&1)
(cd "$TD" && bash "$HOOK" create --session "$SID_B" \
  --phase "p_b" --issue 200 --branch "bb" --pr 0 --next "nb" >/dev/null 2>&1)

A="$TD/.rite/sessions/$SID_A.flow-state"
B="$TD/.rite/sessions/$SID_B.flow-state"

if [ -f "$A" ] && [ -f "$B" ] \
  && [ "$(jq -r '.session_id' "$A")" = "$SID_A" ] \
  && [ "$(jq -r '.session_id' "$B")" = "$SID_B" ]; then
  pass "TC-173: per-session file が session_id で一意にアドレスされる (race window 構造的に消滅)"
else
  fail "TC-173: per-session file の独立性が成立していない"
fi

# 単一ファイル時代の競合シナリオ (B が A を上書き) が新形式では起きないことを確認
if [ "$(jq -r '.phase' "$A")" = "p_a" ] && [ "$(jq -r '.issue_number' "$A")" = "100" ]; then
  pass "TC-173: A の state が B の create で破壊されていない"
else
  fail "TC-173: A の state が破壊されている (single-file race regression)"
fi

# --------------------------------------------------------------------------
# TC-216: .rite-session-id auto-read by flow-state-update.sh
# AC-1: session-start.sh saves UUID / AC-2: flow-state-update reads it / AC-3: fallback
# --------------------------------------------------------------------------
echo "TC-216 (.rite-session-id auto-read):"
TD=$(make_test_dir); cleanup_dirs+=("$TD")
write_config "$TD" 2
SID_AUTO="33333333-3333-3333-3333-333333333333"
write_session_id "$TD" "$SID_AUTO"

# AC-2: --session 省略時に .rite-session-id を auto-read
(cd "$TD" && bash "$HOOK" create \
  --phase "p_auto" --issue 1 --branch "b_auto" --pr 0 --next "n_auto" >/dev/null 2>&1)

AUTO="$TD/.rite/sessions/$SID_AUTO.flow-state"
if [ -f "$AUTO" ] && [ "$(jq -r '.session_id' "$AUTO")" = "$SID_AUTO" ]; then
  pass "TC-216 AC-2: --session 省略時に .rite-session-id 経由で UUID が解決される"
else
  fail "TC-216 AC-2: auto-read が機能していない (file_exists=$([ -f "$AUTO" ] && echo y || echo n))"
fi

# AC-3: --session 引数指定時は引数優先 (.rite-session-id を上書きしない)
SID_OVERRIDE="44444444-4444-4444-4444-444444444444"
(cd "$TD" && bash "$HOOK" create --session "$SID_OVERRIDE" \
  --phase "p_ov" --issue 2 --branch "b_ov" --pr 0 --next "n_ov" >/dev/null 2>&1)

OV="$TD/.rite/sessions/$SID_OVERRIDE.flow-state"
if [ -f "$OV" ] && [ "$(jq -r '.session_id' "$OV")" = "$SID_OVERRIDE" ]; then
  pass "TC-216 AC-3: --session 引数指定時は引数値が優先される"
else
  fail "TC-216 AC-3: --session 引数が無視されている"
fi

# --------------------------------------------------------------------------
# TC-206 + TC-558: SOURCE=startup/clear reset と他 session preservation
# AC-01 (own reset) / AC-02 (other not reset) / AC-03 (legacy reset)
# --------------------------------------------------------------------------
echo "TC-206 + TC-558 (SOURCE=startup reset semantics):"
TD=$(make_test_dir); cleanup_dirs+=("$TD")
write_config "$TD" 2
SID_OWN="55555555-5555-5555-5555-555555555555"
write_session_id "$TD" "$SID_OWN"

# 自セッションの state を作成 (active=true)
(cd "$TD" && bash "$HOOK" create --session "$SID_OWN" \
  --phase "phase_x" --issue 10 --branch "bx" --pr 0 --next "nx" >/dev/null 2>&1)

OWN="$TD/.rite/sessions/$SID_OWN.flow-state"
[ "$(jq -r '.active' "$OWN")" = "true" ] || fail "TC-558 setup: own state が active=true で作成されていない"

# session-start.sh を SOURCE=startup で起動 (own session)
HOOK_INPUT=$(jq -n --arg cwd "$TD" --arg sid "$SID_OWN" \
  '{cwd: $cwd, session_id: $sid, source: "startup"}')
ss_err=$(mktemp)
if ! echo "$HOOK_INPUT" | (cd "$TD" && bash "$SESSION_START" >/dev/null 2>"$ss_err"); then
  ss_rc=$?
  ss_stderr_preview=$(head -3 "$ss_err")
  echo "  WARN: session-start.sh exited non-zero (rc=$ss_rc). stderr: ${ss_stderr_preview:-<empty>}" >&2
fi
rm -f "$ss_err"

# AC-01: own session の state は reset (active=false)
if [ "$(jq -r '.active' "$OWN")" = "false" ]; then
  pass "TC-206/558 AC-01: SOURCE=startup で own session の state が active=false にリセット"
else
  fail "TC-206/558 AC-01: own state が reset されていない (active=$(jq -r '.active' "$OWN"))"
fi

# AC-02: 他 session の state は reset しない
echo "TC-558 AC-02: 他 session の per-session state は reset されない"
TD=$(make_test_dir); cleanup_dirs+=("$TD")
write_config "$TD" 2
SID_ME="77777777-7777-7777-7777-777777777777"
SID_OTHER="88888888-8888-8888-8888-888888888888"
write_session_id "$TD" "$SID_ME"

# 他 session の state を作成 (active=true)
(cd "$TD" && bash "$HOOK" create --session "$SID_OTHER" \
  --phase "phase_other" --issue 20 --branch "b_other" --pr 0 --next "n_other" >/dev/null 2>&1)
OTHER="$TD/.rite/sessions/$SID_OTHER.flow-state"
[ "$(jq -r '.active' "$OTHER")" = "true" ] || fail "TC-558 AC-02 setup: other state が active=true でない"

# session-start.sh を SOURCE=startup で起動 (own session_id = SID_ME)
# session-start.sh の resolver は own session_id 経由で per-session file を resolve するため、
# SID_OTHER の per-session file は触られない (構造的に他 session に手を出せない)
HOOK_INPUT=$(jq -n --arg cwd "$TD" --arg sid "$SID_ME" \
  '{cwd: $cwd, session_id: $sid, source: "startup"}')
ss_err=$(mktemp)
if ! echo "$HOOK_INPUT" | (cd "$TD" && bash "$SESSION_START" >/dev/null 2>"$ss_err"); then
  ss_rc=$?
  ss_stderr_preview=$(head -3 "$ss_err")
  echo "  WARN: session-start.sh exited non-zero (rc=$ss_rc). stderr: ${ss_stderr_preview:-<empty>}" >&2
fi
rm -f "$ss_err"

# 他 session の state は active=true のまま
if [ "$(jq -r '.active' "$OTHER")" = "true" ]; then
  pass "TC-558 AC-02: 他 session (SID_OTHER) の state は active=true のまま"
else
  fail "TC-558 AC-02: 他 session の state が破壊された (active=$(jq -r '.active' "$OTHER"))"
fi

# AC-03: SOURCE=clear でも同様
echo "TC-206 AC-2 (SOURCE=clear reset)"
TD=$(make_test_dir); cleanup_dirs+=("$TD")
write_config "$TD" 2
SID_CLEAR="99999999-9999-9999-9999-999999999999"
write_session_id "$TD" "$SID_CLEAR"
(cd "$TD" && bash "$HOOK" create --session "$SID_CLEAR" \
  --phase "phase_c" --issue 30 --branch "bc" --pr 0 --next "nc" >/dev/null 2>&1)
CLEAR_F="$TD/.rite/sessions/$SID_CLEAR.flow-state"

HOOK_INPUT=$(jq -n --arg cwd "$TD" --arg sid "$SID_CLEAR" \
  '{cwd: $cwd, session_id: $sid, source: "clear"}')
ss_err=$(mktemp)
if ! echo "$HOOK_INPUT" | (cd "$TD" && bash "$SESSION_START" >/dev/null 2>"$ss_err"); then
  ss_rc=$?
  ss_stderr_preview=$(head -3 "$ss_err")
  echo "  WARN: session-start.sh exited non-zero (rc=$ss_rc). stderr: ${ss_stderr_preview:-<empty>}" >&2
fi
rm -f "$ss_err"

if [ "$(jq -r '.active' "$CLEAR_F")" = "false" ]; then
  pass "TC-206 AC-2: SOURCE=clear でも own session state が active=false にリセット"
else
  fail "TC-206 AC-2: clear で reset されていない"
fi

# --------------------------------------------------------------------------
# TC-660: active=true gate (AND-logic in pre-tool-bash-guard.sh)
# AC-2 (active=false → no block) / AC-3 (active=true → block in defense scope)
# --------------------------------------------------------------------------
echo "TC-660 (active=true gate, AND-logic):"
TD=$(make_test_dir); cleanup_dirs+=("$TD")
write_config "$TD" 2
SID_GATE="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
write_session_id "$TD" "$SID_GATE"

# Setup: active=false で create_interview phase
(cd "$TD" && bash "$HOOK" create --session "$SID_GATE" \
  --phase "create_interview" --issue 40 --branch "bg" --pr 0 --next "ng" >/dev/null 2>&1)
GATE_F="$TD/.rite/sessions/$SID_GATE.flow-state"

# `jq | mv` の `&&` 連鎖は bash の "tested context" 例外で jq 失敗時に silent fall-through
# する。helper で if/else 化し、jq 失敗時は明示 exit する fail-fast パターンに統一。
patch_active() {
  local file="$1" value="$2"
  if jq ".active = $value" "$file" > "${file}.tmp"; then
    mv "${file}.tmp" "$file"
  else
    echo "ERROR: jq patch failed for $file (.active = $value)" >&2
    rm -f "${file}.tmp"
    exit 1
  fi
}
patch_active "$GATE_F" false

# AC-2: active=false → pre-tool-bash-guard は許可 (exit 0)
HOOK_INPUT=$(jq -n --arg cwd "$TD" --arg sid "$SID_GATE" \
  '{cwd: $cwd, session_id: $sid, tool_name: "Bash", tool_input: {command: "echo test"}}')
set +e
echo "$HOOK_INPUT" | (cd "$TD" && bash "$PRE_TOOL_GUARD" >/dev/null 2>&1)
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  pass "TC-660 AC-2: active=false で pre-tool-bash-guard は exit 0 (block しない)"
else
  fail "TC-660 AC-2: active=false でも pre-tool-bash-guard が block (rc=$rc)"
fi

# AC-3: active=true で `gh issue create` (phase=create_interview で block 対象) を渡し、
# stdout の `permissionDecision: "deny"` JSON 出力で AND-logic fire を verify する
# (pre-tool-bash-guard は exit 0 のまま stdout で deny を表現する仕様のため、stdout match で判定)。
HOOK_INPUT_BLOCKING=$(jq -n --arg cwd "$TD" --arg sid "$SID_GATE" \
  '{cwd: $cwd, session_id: $sid, tool_name: "Bash", tool_input: {command: "gh issue create --title test --body test"}}')

# active=false → guard は早期 silent skip (deny JSON なし)
patch_active "$GATE_F" false
set +e
out_active_false=$(echo "$HOOK_INPUT_BLOCKING" | (cd "$TD" && bash "$PRE_TOOL_GUARD" 2>/dev/null))
set -e

# active=true → guard は AND-logic 評価に進み deny JSON を出力
patch_active "$GATE_F" true
set +e
out_active_true=$(echo "$HOOK_INPUT_BLOCKING" | (cd "$TD" && bash "$PRE_TOOL_GUARD" 2>/dev/null))
set -e

# active=false: deny JSON が出力されないこと (silent skip)
if ! echo "$out_active_false" | grep -q '"permissionDecision":[[:space:]]*"deny"'; then
  pass "TC-660 AC-3 (active=false): permissionDecision: deny が出力されない (silent skip = 防御層 no-op)"
else
  fail "TC-660 AC-3 (active=false): active=false でも guard が block JSON を出力した (silent skip 契約違反)"
fi
# active=true: deny JSON が出力されること (AND-logic fire)
if echo "$out_active_true" | grep -q '"permissionDecision":[[:space:]]*"deny"'; then
  pass "TC-660 AC-3 (active=true): permissionDecision: deny が出力 (AND-logic fire verified, #660 regression なし)"
else
  fail "TC-660 AC-3 (active=true): active=true でも guard が block JSON を出力しない (silent AND-logic skip = #660 regression)"
fi

# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------
echo ""
echo "==============================="
echo "Results: $PASS passed, $FAIL failed"
echo ""
echo "Issue mapping:"
echo "  TC-173: Per-session isolation (race window 構造的消滅)"
echo "  TC-216: .rite-session-id auto-read (AC-2 / AC-3)"
echo "  TC-206 + TC-558: SOURCE=startup/clear reset semantics (AC-01 own / AC-02 other / AC-2 clear)"
echo "  TC-660: active=true gate (AND-logic in pre-tool-bash-guard.sh)"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
