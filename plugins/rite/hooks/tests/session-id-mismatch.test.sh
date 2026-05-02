#!/bin/bash
# Tests for session_id mismatch hook no-op — Issue #672 / #684 (T-04 / AC-4)
#
# Purpose:
#   schema_version=2 (per-session file) では `_resolve-flow-state-path.sh` が
#   resolver を経由する caller には現セッションの per-session path のみを返すため
#   ownership は構造的に保証される。しかし将来 resolver を経由しない caller が
#   foreign per-session file を直接渡した場合のために `check_session_ownership`
#   は filename SID == hook SID の defense-in-depth check を持つ (Wiki 経験則
#   「structural ownership guarantee は code-level defense-in-depth で enforce する」、
#   PR #750 cycle 1 HIGH 参照)。本テストは:
#     (a) check_session_ownership の classification 結果が正しいこと
#     (b) hook 経由 (pre-tool-bash-guard.sh / post-tool-wm-sync.sh) で foreign
#         session_id を受けた際に no-op で early exit すること
#   を verify する。
#
# Test cases:
#   TC-1: per-session file (filename SID != hook SID) → "other" (defense-in-depth)
#   TC-2: per-session file (filename SID == hook SID) → "own" (fast-path)
#   TC-3: per-session file + 空 hook SID → "own" (resolver guarantee, backward compat)
#   TC-4: legacy file + state_sid != hook_sid + updated_at 7200s 以内 → "other"
#   TC-5: legacy file + state_sid != hook_sid + updated_at 7200s 超え → "stale"
#   TC-6: legacy file + state_sid 空 → "legacy"
#   TC-7: state file 不在 + hook_sid 空 → "own" (backward compat)
#   TC-8: pre-tool-bash-guard.sh integration: foreign session_id → no-op exit 0
#   TC-9: filename SID basename extraction の canonical phrase pin (Wiki 経験則
#         「Test pin protection theater」: regression guard としての pin)
#
# Out of scope (他テストでカバー):
#   - session-ownership.sh の other/stale/legacy 各 case 詳細 → session-ownership.test.sh
#   - 並行 session の独立性 → concurrent-sessions.test.sh
#
# Usage: bash plugins/rite/hooks/tests/session-id-mismatch.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOKS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PASS=0
FAIL=0
FAILED_NAMES=()

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required but not installed" >&2
  exit 1
fi

# ---- helpers ----
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

pass() { PASS=$((PASS + 1)); echo "  ✅ PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); FAILED_NAMES+=("$1"); echo "  ❌ FAIL: $1"; }

make_test_dir() {
  local d
  d=$(mktemp -d) || { echo "ERROR: mktemp -d failed" >&2; return 1; }
  cleanup_dirs+=("$d")
  echo "$d"
}

# Source session-ownership.sh in a subshell-safe wrapper so we can call its
# functions directly. We source per-call to avoid any state leakage between TCs.
call_check_ownership() {
  local hook_json="$1"
  local state_file="$2"
  (
    source "$HOOKS_DIR/session-ownership.sh"
    check_session_ownership "$hook_json" "$state_file"
  )
}

echo "=== session-id-mismatch tests (Issue #672 / #684 T-04 AC-4) ==="
echo ""

# -------------------------------------------------------------------------
# TC-1: per-session file with filename SID != hook SID → "other" (defense)
# -------------------------------------------------------------------------
echo "TC-1: per-session filename SID != hook SID → defense returns 'other'"
TD=$(make_test_dir)
mkdir -p "$TD/.rite/sessions"
SID_OWN="aaaa1111-2222-3333-4444-555566667777"
SID_FOREIGN="bbbb1111-2222-3333-4444-555566667777"
state_file="$TD/.rite/sessions/${SID_OWN}.flow-state"
echo "{\"active\":true,\"phase\":\"phaseX\",\"session_id\":\"$SID_OWN\"}" > "$state_file"
hook_json="{\"session_id\":\"$SID_FOREIGN\"}"
result=$(call_check_ownership "$hook_json" "$state_file")
if [ "$result" = "other" ]; then
  pass "TC-1.1: classification='other' (filename SID defense-in-depth)"
else
  fail "TC-1.1: expected 'other', got '$result'"
fi

# -------------------------------------------------------------------------
# TC-2: per-session file with filename SID == hook SID → "own" (fast-path)
# -------------------------------------------------------------------------
echo "TC-2: per-session filename SID == hook SID → 'own' fast-path"
hook_json="{\"session_id\":\"$SID_OWN\"}"
result=$(call_check_ownership "$hook_json" "$state_file")
if [ "$result" = "own" ]; then
  pass "TC-2.1: classification='own' (matched filename SID)"
else
  fail "TC-2.1: expected 'own', got '$result'"
fi

# -------------------------------------------------------------------------
# TC-3: per-session file + 空 hook SID → "own" (resolver guarantee)
# -------------------------------------------------------------------------
# Backward-compat path: when the hook payload has no session_id (e.g., older
# Claude Code SDK version), trust the resolver-supplied per-session path as
# owned. This is the "fail-secure backward-compat" branch documented in
# session-ownership.sh and PR #750 cycle 1 HIGH.
echo "TC-3: per-session file + 空 hook SID → 'own' (backward compat)"
hook_json='{}'
result=$(call_check_ownership "$hook_json" "$state_file")
if [ "$result" = "own" ]; then
  pass "TC-3.1: 空 hook SID + per-session → 'own' (resolver-guaranteed ownership)"
else
  fail "TC-3.1: expected 'own', got '$result'"
fi

# -------------------------------------------------------------------------
# TC-4: legacy file + state_sid != hook_sid + updated_at 7200s 以内 → "other"
# -------------------------------------------------------------------------
echo "TC-4: legacy + state_sid != hook_sid + recent → 'other'"
TD=$(make_test_dir)
legacy_file="$TD/.rite-flow-state"
SID_STATE="cccc1111-2222-3333-4444-555566667777"
SID_HOOK="dddd1111-2222-3333-4444-555566667777"
recent_ts=$(date -u +'%Y-%m-%dT%H:%M:%S+00:00')
echo "{\"active\":true,\"phase\":\"phaseY\",\"session_id\":\"$SID_STATE\",\"updated_at\":\"$recent_ts\"}" > "$legacy_file"
hook_json="{\"session_id\":\"$SID_HOOK\"}"
result=$(call_check_ownership "$hook_json" "$legacy_file")
if [ "$result" = "other" ]; then
  pass "TC-4.1: legacy mismatch + recent → 'other'"
else
  fail "TC-4.1: expected 'other', got '$result' (state_sid=$SID_STATE hook_sid=$SID_HOOK ts=$recent_ts)"
fi

# -------------------------------------------------------------------------
# TC-5: legacy file + state_sid != hook_sid + updated_at 7200s 超え → "stale"
# -------------------------------------------------------------------------
echo "TC-5: legacy + state_sid != hook_sid + stale (>7200s) → 'stale'"
# F-07 fix (Issue #760): GNU/BSD date fallback の silent failure 検出。
# 旧実装は両 fallback が失敗した場合 `old_ts` が空になり、後続 JSON で
# `"updated_at":""` として書き込まれ、test が undefined 動作になる経路があった。
# `[ -z "$old_ts" ]` で empty check し、両環境で fallback 不能なら fail させる。
# 8000 seconds ago
old_ts=$(date -u -d "8000 seconds ago" +'%Y-%m-%dT%H:%M:%S+00:00' 2>/dev/null \
  || date -u -v-8000S +'%Y-%m-%dT%H:%M:%S+00:00' 2>/dev/null)
if [ -z "$old_ts" ]; then
  fail "TC-5.0: GNU date (-d) と BSD date (-v) の両 fallback が失敗 — test 環境の date が non-portable"
  echo "ERROR: cannot generate stale timestamp; aborting TC-5" >&2
  exit 1
fi
echo "{\"active\":true,\"phase\":\"phaseY\",\"session_id\":\"$SID_STATE\",\"updated_at\":\"$old_ts\"}" > "$legacy_file"
result=$(call_check_ownership "$hook_json" "$legacy_file")
if [ "$result" = "stale" ]; then
  pass "TC-5.1: legacy mismatch + >7200s → 'stale'"
else
  fail "TC-5.1: expected 'stale', got '$result' (ts=$old_ts)"
fi

# -------------------------------------------------------------------------
# TC-6: legacy file + state_sid 空 → "legacy"
# -------------------------------------------------------------------------
echo "TC-6: legacy + state_sid 空 → 'legacy'"
echo '{"active":true,"phase":"phaseZ"}' > "$legacy_file"
hook_json="{\"session_id\":\"$SID_HOOK\"}"
result=$(call_check_ownership "$hook_json" "$legacy_file")
if [ "$result" = "legacy" ]; then
  pass "TC-6.1: legacy with no session_id → 'legacy'"
else
  fail "TC-6.1: expected 'legacy', got '$result'"
fi

# -------------------------------------------------------------------------
# TC-7: state file 不在 + hook_sid 空 → "own" (backward compat)
# -------------------------------------------------------------------------
echo "TC-7: state file ENOENT + 空 hook SID → 'own' (backward compat)"
TD=$(make_test_dir)
hook_json='{}'
nonexistent="$TD/.rite-flow-state"
result=$(call_check_ownership "$hook_json" "$nonexistent")
if [ "$result" = "own" ]; then
  pass "TC-7.1: ENOENT + 空 hook → 'own'"
else
  fail "TC-7.1: expected 'own', got '$result'"
fi

# -------------------------------------------------------------------------
# TC-8: pre-tool-bash-guard.sh integration: foreign session_id → exit 0 (no-op)
# -------------------------------------------------------------------------
# pre-tool-bash-guard.sh は Bash tool 呼び出し前に発火する PreToolUse hook で、
# session-ownership による classification を踏まえて foreign session の干渉を
# 防ぐ。foreign session_id を hook payload で渡し、hook が non-blocking
# (exit 0) で early-return することを verify する。
echo "TC-8: pre-tool-bash-guard.sh + foreign session_id → exit 0 (no-op early-return)"
TD=$(make_test_dir)
mkdir -p "$TD/.rite/sessions"
SID_OWN="abcdef01-2345-6789-abcd-ef0123456789"
SID_HOOK_FOREIGN="00000000-0000-0000-0000-deadbeef0001"
echo "$SID_OWN" > "$TD/.rite-session-id"
cat > "$TD/rite-config.yml" <<EOF
flow_state:
  schema_version: 2
EOF
state_file="$TD/.rite/sessions/${SID_OWN}.flow-state"
echo "{\"active\":true,\"phase\":\"phase5_test\",\"session_id\":\"$SID_OWN\"}" > "$state_file"

# pre-tool-bash-guard.sh expects a JSON payload on stdin describing the tool call.
# We feed a minimal payload with the foreign session_id and a benign tool_input.
hook_input=$(jq -n \
  --arg sid "$SID_HOOK_FOREIGN" \
  --arg cwd "$TD" \
  '{"session_id": $sid, "cwd": $cwd, "tool_name": "Bash", "tool_input": {"command": "echo hi"}}')
hook_rc=0
hook_out=$(echo "$hook_input" | bash "$HOOKS_DIR/pre-tool-bash-guard.sh" 2>&1) || hook_rc=$?
# A foreign-session hook MUST NOT block the tool call (exit 0) — it has no
# authority to gate another session's tool execution.
if [ "$hook_rc" -eq 0 ]; then
  pass "TC-8.1: pre-tool-bash-guard.sh exit 0 for foreign session (no-op early-return)"
else
  fail "TC-8.1: expected exit 0, got rc=$hook_rc output: $(echo "$hook_out" | head -3)"
fi

# -------------------------------------------------------------------------
# TC-9: canonical phrase pin (Wiki 経験則「Test pin protection theater」)
# -------------------------------------------------------------------------
# `session-ownership.sh` の defense-in-depth は filename basename と hook SID を
# 比較する。実装が `basename "$state_file" .flow-state` という canonical な
# phrase を含むことを pin することで、誰かが `awk -F/` ベース等の不安定な
# 実装に置換した場合に regression を検出する。
echo "TC-9: canonical filename-extraction phrase pin"
expected_phrase='basename "$state_file" .flow-state'
if grep -qF -- "$expected_phrase" "$HOOKS_DIR/session-ownership.sh"; then
  pass "TC-9.1: defense-in-depth phrase '$expected_phrase' present in session-ownership.sh"
else
  fail "TC-9.1: canonical phrase missing — defense-in-depth implementation may have drifted"
fi

# -------------------------------------------------------------------------
# Summary
# -------------------------------------------------------------------------
echo ""
echo "==============================="
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo "Failed:"
  for n in "${FAILED_NAMES[@]}"; do
    echo "  - $n"
  done
  exit 1
fi
echo "All session-id-mismatch tests passed!"
