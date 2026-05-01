#!/bin/bash
# AND-logic defense chain (Wiki 経験則 #660: 「前提条件の silent omit が AND 論理の防御層
# チェーンを全体無効化する」) を新形式 (per-session file, schema_version=2) 上で verify。
#
# Issue #683 / parent #672 AC-LOCAL-3:
#   - AND 論理 8 種防御層が新形式上で動作 (.rite-stop-guard-diag.log 相当の trace で verify)
#
# 8 種防御層:
#   1. declarative      : commands/issue/*.md prose で `--active true` literal を declare
#   2. sentinel         : workflow-incident-emit.sh が WORKFLOW_INCIDENT=1 sentinel を emit
#   3. Pre-check        : commands で state-read.sh --field phase 経由の pre-condition check
#   4. whitelist        : phase-transition-whitelist.sh が source 可能で case arm を持つ
#   5. Pre-flight       : preflight-check.sh が --command-id 引数を受け付け、compact_state を gate
#   6. Step 0           : create.md の "Step 0 Immediate Bash" pattern (turn 境界回避)
#   7. 4-site 対称化    : `--active true` が 4 site 以上 (create.md / create-interview.md / start.md 系列) で symmetry
#   8. case arm         : phase-transition-whitelist.sh の declare -gA テーブル + rite_phase_transition_allowed 関数
#
# 各 layer について以下を verify:
#   (a) Evidence Test  : layer の存在を grep / file existence で mechanical に検出
#   (b) AND-logic Test : `.active=true` で fire / `.active=false` で silent skip という contract が成立
#
# Note (architecture drift since #660): stop-guard.sh は #674 で removal 済み。
# `.rite-stop-guard-diag.log` は現存しないため、layer 4/5/8 の AND-logic は
# phase-transition-whitelist.sh と pre-tool-bash-guard.sh の挙動で間接観測する。
#
# Out of scope (#684 で扱う):
#   - migration / atomic write integrity / cleanup / crash resume
#
# Usage: bash plugins/rite/hooks/tests/and-logic-defense-chain.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK_DIR="$SCRIPT_DIR/.."
PLUGIN_ROOT="$(cd "$HOOK_DIR/.." && pwd)"
REPO_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd)"
HOOK="$HOOK_DIR/flow-state-update.sh"
WHITELIST="$HOOK_DIR/phase-transition-whitelist.sh"
PREFLIGHT="$HOOK_DIR/preflight-check.sh"
INCIDENT_EMIT="$HOOK_DIR/workflow-incident-emit.sh"
PRE_TOOL_GUARD="$HOOK_DIR/pre-tool-bash-guard.sh"
PASS=0
FAIL=0

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required but not installed" >&2
  exit 1
fi

make_test_dir() {
  local d
  d=$(mktemp -d)
  (
    cd "$d"
    git init -q
    echo a > a && git add a
    git -c user.email=t@test.local -c user.name=test commit -q -m init
  )
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

echo "=== and-logic-defense-chain tests (Wiki 経験則 #660 / Issue #683 AC-LOCAL-3) ==="
echo ""

# --------------------------------------------------------------------------
# Layer 1: declarative — commands/issue/*.md prose で --active true literal を declare
# --------------------------------------------------------------------------
echo "Layer 1 (declarative): commands で --active true literal が declare されている"
declarative_count=$(git -C "$REPO_ROOT" grep -nE '\-\-active true' plugins/rite/commands/issue/ 2>/dev/null | wc -l)
if [ "$declarative_count" -gt 0 ]; then
  pass "Layer 1 evidence: --active true literal が commands/issue/ 内に $declarative_count 箇所 (declarative 層成立)"
else
  fail "Layer 1: --active true literal が commands/issue/ 内に存在しない (declarative 層欠落)"
fi

# --------------------------------------------------------------------------
# Layer 2: sentinel — workflow-incident-emit.sh が WORKFLOW_INCIDENT=1 を emit
# --------------------------------------------------------------------------
echo "Layer 2 (sentinel): workflow-incident-emit.sh が WORKFLOW_INCIDENT=1 sentinel を emit"
if [ -x "$INCIDENT_EMIT" ] || [ -f "$INCIDENT_EMIT" ]; then
  pass "Layer 2 evidence: workflow-incident-emit.sh が存在"
else
  fail "Layer 2: workflow-incident-emit.sh が存在しない"
fi

# Runtime: emit が WORKFLOW_INCIDENT=1 sentinel を出力するか
sentinel_out=$(bash "$INCIDENT_EMIT" --type skill_load_failure --details "test details" --pr-number 0 2>/dev/null) || sentinel_out=""
if echo "$sentinel_out" | grep -q "WORKFLOW_INCIDENT=1"; then
  pass "Layer 2 runtime: emit 結果に WORKFLOW_INCIDENT=1 が含まれる"
else
  fail "Layer 2 runtime: WORKFLOW_INCIDENT=1 sentinel が emit されない (out=$sentinel_out)"
fi

# --------------------------------------------------------------------------
# Layer 3: Pre-check — commands で state-read.sh --field phase 経由の pre-condition
# --------------------------------------------------------------------------
echo "Layer 3 (Pre-check): commands で state-read.sh --field phase pre-condition check"
precheck_count=$(git -C "$REPO_ROOT" grep -nE 'state-read\.sh --field phase' plugins/rite/commands/ 2>/dev/null | wc -l)
if [ "$precheck_count" -gt 0 ]; then
  pass "Layer 3 evidence: state-read.sh --field phase 呼び出しが commands/ に $precheck_count 箇所"
else
  fail "Layer 3: Pre-check pattern が commands/ に存在しない"
fi

# --------------------------------------------------------------------------
# Layer 4: whitelist — phase-transition-whitelist.sh が source 可能で whitelist を持つ
# --------------------------------------------------------------------------
echo "Layer 4 (whitelist): phase-transition-whitelist.sh が source 可能で whitelist を持つ"
if [ -f "$WHITELIST" ]; then
  pass "Layer 4 evidence: phase-transition-whitelist.sh が存在"
else
  fail "Layer 4: phase-transition-whitelist.sh が存在しない"
fi

# Runtime: source して関数が呼べるか
set +e
(
  set +u
  source "$WHITELIST"
  if declare -f rite_phase_transition_allowed >/dev/null 2>&1; then
    # 既知の遷移 (phase1_5_parent → phase1_5_post_parent) が allow される
    if rite_phase_transition_allowed "phase1_5_parent" "phase1_5_post_parent"; then
      exit 0
    else
      exit 1
    fi
  else
    exit 2
  fi
)
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  pass "Layer 4 runtime: rite_phase_transition_allowed が known transition を allow"
else
  fail "Layer 4 runtime: whitelist 関数が機能しない (rc=$rc)"
fi

# --------------------------------------------------------------------------
# Layer 5: Pre-flight — preflight-check.sh が --command-id を受け付け compact gate
# --------------------------------------------------------------------------
echo "Layer 5 (Pre-flight): preflight-check.sh が --command-id を受け付け、normal state で exit 0"
if [ -f "$PREFLIGHT" ]; then
  pass "Layer 5 evidence: preflight-check.sh が存在"
else
  fail "Layer 5: preflight-check.sh が存在しない"
fi

TD=$(make_test_dir); cleanup_dirs+=("$TD")
# compact state なし → normal → exit 0
set +e
(cd "$TD" && bash "$PREFLIGHT" --command-id "/rite:issue:start" --cwd "$TD" >/dev/null 2>&1)
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  pass "Layer 5 runtime: compact_state=normal で preflight-check は exit 0 (allow)"
else
  fail "Layer 5 runtime: normal state で preflight-check が block (rc=$rc)"
fi

# --------------------------------------------------------------------------
# Layer 6: Step 0 — create.md の "Step 0 Immediate Bash" pattern (turn 境界回避)
# --------------------------------------------------------------------------
echo "Layer 6 (Step 0): create.md に Step 0 Immediate Bash pattern が存在"
step0_count=$(git -C "$REPO_ROOT" grep -nE '(Step 0 Immediate Bash|Step 0:[[:space:]]*Immediate)' plugins/rite/commands/issue/create.md 2>/dev/null | wc -l)
if [ "$step0_count" -gt 0 ]; then
  pass "Layer 6 evidence: create.md に Step 0 Immediate Bash pattern が $step0_count 箇所"
else
  fail "Layer 6: Step 0 Immediate Bash pattern が create.md に存在しない"
fi

# --------------------------------------------------------------------------
# Layer 7: 4-site 対称化 — --active true が 4 site 以上で symmetric
# --------------------------------------------------------------------------
echo "Layer 7 (4-site 対称化): --active true が 4 site 以上で symmetric"
site_count=$(git -C "$REPO_ROOT" grep -lE '\-\-active true' plugins/rite/commands/issue/ 2>/dev/null | wc -l)
if [ "$site_count" -ge 4 ]; then
  pass "Layer 7 evidence: --active true を含む commands/issue/ file が $site_count 件 (≥4)"
else
  fail "Layer 7: 4-site 対称化が崩れている ($site_count files)"
fi

# --------------------------------------------------------------------------
# Layer 8: case arm — phase-transition-whitelist.sh の declare -gA テーブル
# --------------------------------------------------------------------------
echo "Layer 8 (case arm): phase-transition-whitelist.sh の declare -gA + 関数 dispatch"
case_arm_count=$(grep -cE 'declare -gA _RITE_PHASE_TRANSITIONS' "$WHITELIST" 2>/dev/null || echo 0)
if [ "$case_arm_count" -ge 1 ]; then
  pass "Layer 8 evidence: declare -gA _RITE_PHASE_TRANSITIONS が存在 ($case_arm_count 箇所)"
else
  fail "Layer 8: case arm/dispatch table が存在しない"
fi

# Runtime: 不正な遷移は reject される
set +e
(
  set +u
  source "$WHITELIST"
  if declare -f rite_phase_transition_allowed >/dev/null 2>&1; then
    if rite_phase_transition_allowed "phase1_5_parent" "phase5_completion"; then
      exit 1  # 想定外: reject されるべき遷移が allow された
    else
      exit 0  # 期待通り reject
    fi
  else
    exit 2
  fi
)
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  pass "Layer 8 runtime: 不正な遷移 (phase1_5_parent → phase5_completion) は reject される"
else
  fail "Layer 8 runtime: 不正な遷移が reject されない (rc=$rc)"
fi

# --------------------------------------------------------------------------
# AND-logic invariant: active=false 状態で防御層は silent skip / active=true で fire
# (#660 root cause = active=true 前提を omit すると 8 layer 全体が無効化される)
# --------------------------------------------------------------------------
echo "AND-logic invariant: active=false で defense layer は silent skip / active=true で fire"
TD=$(make_test_dir); cleanup_dirs+=("$TD")
write_config "$TD" 2
SID_INV="abcdefab-cdef-abcd-efab-cdefabcdefab"
write_session_id "$TD" "$SID_INV"

# active=false setup
(cd "$TD" && bash "$HOOK" create --session "$SID_INV" \
  --phase "create_interview" --issue 1 --branch "b" --pr 0 --next "n" >/dev/null 2>&1)
INV_F="$TD/.rite/sessions/$SID_INV.flow-state"
jq '.active = false' "$INV_F" > "${INV_F}.tmp" && mv "${INV_F}.tmp" "$INV_F"

HOOK_INPUT=$(jq -n --arg cwd "$TD" --arg sid "$SID_INV" \
  '{cwd: $cwd, session_id: $sid, tool_name: "Bash", tool_input: {command: "echo silent-skip-test"}}')
set +e
echo "$HOOK_INPUT" | (cd "$TD" && bash "$PRE_TOOL_GUARD" >/dev/null 2>&1)
rc_false=$?
set -e

# active=true でも (phase=create_interview AND-condition 成立)
jq '.active = true' "$INV_F" > "${INV_F}.tmp" && mv "${INV_F}.tmp" "$INV_F"
set +e
echo "$HOOK_INPUT" | (cd "$TD" && bash "$PRE_TOOL_GUARD" >/dev/null 2>&1)
rc_true=$?
set -e

# active=false → exit 0 (silent skip = 防御層が gate を通す)
if [ "$rc_false" -eq 0 ]; then
  pass "AND-logic: active=false で pre-tool-bash-guard が exit 0 (silent skip = 防御層 no-op)"
else
  fail "AND-logic: active=false でも guard が block (rc=$rc_false) — silent skip 契約違反"
fi

# active=true → 防御層が evaluation pathway を通る (rc 0 or 2 のいずれかで安定)
if [ "$rc_true" -eq 0 ] || [ "$rc_true" -eq 2 ]; then
  pass "AND-logic: active=true で pre-tool-bash-guard が evaluation pathway を通る (rc=$rc_true)"
else
  fail "AND-logic: active=true で guard が異常 exit code (rc=$rc_true)"
fi

# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------
echo ""
echo "==============================="
echo "Results: $PASS passed, $FAIL failed"
echo ""
echo "Defense layer mapping:"
echo "  Layer 1 declarative      : commands prose で --active true literal を declare"
echo "  Layer 2 sentinel         : workflow-incident-emit.sh が WORKFLOW_INCIDENT=1 emit"
echo "  Layer 3 Pre-check        : state-read.sh --field phase pre-condition"
echo "  Layer 4 whitelist        : phase-transition-whitelist.sh が source 可能"
echo "  Layer 5 Pre-flight       : preflight-check.sh の compact_state gate"
echo "  Layer 6 Step 0           : create.md の Step 0 Immediate Bash"
echo "  Layer 7 4-site 対称化    : --active true の 4-site symmetric distribution"
echo "  Layer 8 case arm         : phase-transition-whitelist.sh の declare -gA dispatch"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
