#!/bin/bash
# Tests for review-result schema 1.1.0 scope enum / cross-field invariants
# schema 1.0 → 1.1.0 evolution.
#
# Test cases (AC-4):
#   T-1: basic — scope ∈ {current-pr, follow-up, nit-noted} valid (+MEDIUM × nit-noted negative)
#   T-2: CRITICAL × nit-noted / HIGH × nit-noted FAIL invariant (review-result-schema invariant #4)
#        + MEDIUM × nit-noted negative case (selector が CRITICAL/HIGH 限定であることを fix)
#   T-3: LOW × current-pr → migration default mapping demotes to nit-noted
#        (migrate-review-state-to-1.1.sh fills scope from severity when scope absent;
#         LOW severity yields nit-noted per default-mapping table)
#   T-4: pre_existing=false × nit-noted auto-correct (invariant #5)
# Why: schema-level contract test (canonical jq mutation の動作のみを assert する。
#         fix.md ステップ 1.2.0 の read-side integration は本 test で検証しない。
#         read-side との bit-exact 一致は別 E2E test の責務 [follow-up scope])
#
# Usage: bash plugins/rite/hooks/tests/scope-enum-check.test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"
REPO_ROOT="$(_helpers_resolve_repo_root "$SCRIPT_DIR")"
MIGRATE_SCRIPT="$REPO_ROOT/plugins/rite/scripts/migrate-review-state-to-1.1.sh"

# Sanity: required tooling
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required for scope-enum-check.test.sh" >&2
  exit 2
fi
if [ ! -x "$MIGRATE_SCRIPT" ]; then
  echo "ERROR: migrate-review-state-to-1.1.sh not found / not executable at $MIGRATE_SCRIPT" >&2
  exit 2
fi

# Sandbox + cleanup_dirs array for proper trap-based cleanup (F-06)
# Use specific path tracking instead of relying on $sandbox single rm -rf.
declare -a cleanup_dirs=()
_test_cleanup() {
  local d
  for d in "${cleanup_dirs[@]:-}"; do
    [ -n "$d" ] && [ -d "$d" ] && rm -rf "$d"
  done
}
trap '_test_cleanup' EXIT
trap '_test_cleanup; exit 130' INT
trap '_test_cleanup; exit 143' TERM
trap '_test_cleanup; exit 129' HUP

sandbox=$(mktemp -d) || { echo "ERROR: mktemp failed" >&2; exit 2; }
cleanup_dirs+=("$sandbox")

mkdir -p "$sandbox/.rite/review-results"
mkdir -p "$sandbox/.rite/state"

# ------------------------------------------------------------------
# T-1: basic scope enum check (current-pr / follow-up / nit-noted)
# ------------------------------------------------------------------
echo "=== T-1: basic scope enum ==="
T1_FILE="$sandbox/T1.json"
cat > "$T1_FILE" <<'EOF'
{
  "schema_version": "1.1.0",
  "pr_number": 1,
  "timestamp": "2026-01-01T00:00:00+09:00",
  "commit_sha": "abc",
  "overall_assessment": "fix-needed",
  "findings": [
    { "id": "F-01", "reviewer": "code-quality-reviewer", "category": "code_quality", "severity": "HIGH",   "scope": "current-pr", "pre_existing": false, "file": "a.ts", "line": 1, "description": "d", "suggestion": "s", "status": "open" },
    { "id": "F-02", "reviewer": "code-quality-reviewer", "category": "code_quality", "severity": "MEDIUM", "scope": "follow-up",  "pre_existing": false, "file": "b.ts", "line": 2, "description": "d", "suggestion": "s", "status": "deferred" },
    { "id": "F-03", "reviewer": "code-quality-reviewer", "category": "code_quality", "severity": "LOW",    "scope": "nit-noted",  "pre_existing": true,  "nit_reason": "stylistic", "file": "c.ts", "line": 3, "description": "d", "suggestion": "s", "status": "acknowledged" }
  ]
}
EOF

T1_INVALID_SCOPE_COUNT=$(jq '[.findings[] | select(.scope != "current-pr" and .scope != "follow-up" and .scope != "nit-noted")] | length' "$T1_FILE")
assert "T-1 all scope values are valid enum members" "0" "$T1_INVALID_SCOPE_COUNT"

# ------------------------------------------------------------------
# T-2: CRITICAL/HIGH × nit-noted FAIL invariant (#4)
#      + MEDIUM × nit-noted negative case (F-04 — symmetry with T-4)
# ------------------------------------------------------------------
echo "=== T-2: CRITICAL × nit-noted FAIL invariant ==="
T2_FILE="$sandbox/T2.json"
cat > "$T2_FILE" <<'EOF'
{
  "schema_version": "1.1.0",
  "pr_number": 2,
  "timestamp": "2026-01-01T00:00:00+09:00",
  "commit_sha": "abc",
  "overall_assessment": "fix-needed",
  "findings": [
    { "id": "F-01", "reviewer": "code-quality-reviewer", "category": "code_quality", "severity": "CRITICAL", "scope": "nit-noted", "pre_existing": false, "file": "a.ts", "line": 1, "description": "d", "suggestion": "s", "status": "open" }
  ]
}
EOF

# Canonical jq from schema doc invariant #4:
T2_VIOLATIONS=$(jq '[.findings[] | select((.severity == "CRITICAL" or .severity == "HIGH") and .scope == "nit-noted")] | length' "$T2_FILE")
if [ "$T2_VIOLATIONS" -ge 1 ]; then
  pass "T-2 invariant #4 detects CRITICAL × nit-noted (violations=$T2_VIOLATIONS)"
else
  fail "T-2 invariant #4 missed CRITICAL × nit-noted (violations=$T2_VIOLATIONS, expected ≥ 1)"
fi

# Negative confirm: same JSON with severity HIGH should also trigger
T2B_FILE="$sandbox/T2b.json"
jq '.findings[0].severity = "HIGH"' "$T2_FILE" > "$T2B_FILE"
T2B_VIOLATIONS=$(jq '[.findings[] | select((.severity == "CRITICAL" or .severity == "HIGH") and .scope == "nit-noted")] | length' "$T2B_FILE")
if [ "$T2B_VIOLATIONS" -ge 1 ]; then
  pass "T-2 invariant #4 detects HIGH × nit-noted (violations=$T2B_VIOLATIONS)"
else
  fail "T-2 invariant #4 missed HIGH × nit-noted (violations=$T2B_VIOLATIONS, expected ≥ 1)"
fi

# Negative case: MEDIUM × nit-noted should NOT trigger (F-04)
# selector が CRITICAL/HIGH 限定であることを verify。selector が将来 MEDIUM を含むよう
# 誤って変更されても検出できるようにする (T-4 の pre_existing=true negative pair と対称)。
T2C_FILE="$sandbox/T2c.json"
jq '.findings[0].severity = "MEDIUM"' "$T2_FILE" > "$T2C_FILE"
T2C_VIOLATIONS=$(jq '[.findings[] | select((.severity == "CRITICAL" or .severity == "HIGH") and .scope == "nit-noted")] | length' "$T2C_FILE")
assert "T-2 invariant #4 does NOT fire on MEDIUM × nit-noted" "0" "$T2C_VIOLATIONS"

# ------------------------------------------------------------------
# T-3: LOW × current-pr → migration default mapping demotes to nit-noted
#      Input is 1.0 JSON without scope field; migration fills scope from severity;
#      LOW → nit-noted per schema default-mapping table.
# ------------------------------------------------------------------
echo "=== T-3: LOW default mapping → nit-noted ==="
T3_DIR=$(mktemp -d) || { echo "ERROR: T-3 mktemp -d failed" >&2; exit 2; }
cleanup_dirs+=("$T3_DIR")
mkdir -p "$T3_DIR/.rite/review-results"

# 1.0 JSON (no scope, no pre_existing) with LOW finding
cat > "$T3_DIR/.rite/review-results/300-20260101000000.json" <<'EOF'
{
  "schema_version": "1.0.0",
  "pr_number": 300,
  "timestamp": "2026-01-01T00:00:00+09:00",
  "commit_sha": "abc",
  "overall_assessment": "fix-needed",
  "findings": [
    { "id": "F-01", "reviewer": "code-quality-reviewer", "category": "code_quality", "severity": "LOW", "file": "a.ts", "line": 1, "description": "stylistic nit", "suggestion": "ignore", "status": "open" }
  ]
}
EOF

# Capture stderr for diagnostic purposes (F-14)
T3_STDERR=$(mktemp "${TMPDIR:-/tmp}/rite-scope-enum-t3-stderr-XXXXXX") || { fail "T-3 stderr tmpfile mktemp failed"; T3_STDERR=""; }
T3_RC=0
if [ -n "$T3_STDERR" ]; then
  REPO_ROOT="$T3_DIR" bash "$MIGRATE_SCRIPT" >/dev/null 2>"$T3_STDERR"
  T3_RC=$?
else
  REPO_ROOT="$T3_DIR" bash "$MIGRATE_SCRIPT" >/dev/null 2>&1
  T3_RC=$?
fi

# F-05: migration failure 時は後続 assert を short-circuit する
if [ "$T3_RC" -ne 0 ]; then
  if [ -n "$T3_STDERR" ] && [ -s "$T3_STDERR" ]; then
    fail "T-3 migration script exit code (expected 0, got $T3_RC). stderr: $(head -5 "$T3_STDERR" | tr '\n' ' ')"
  else
    fail "T-3 migration script exit code (expected 0, got $T3_RC)"
  fi
else
  T3_SCOPE=$(jq -r '.findings[0].scope' "$T3_DIR/.rite/review-results/300-20260101000000.json" 2>/dev/null) || T3_SCOPE="<error>"
  assert "T-3 LOW finding scope after migration" "nit-noted" "$T3_SCOPE"

  T3_VER=$(jq -r '.schema_version' "$T3_DIR/.rite/review-results/300-20260101000000.json" 2>/dev/null) || T3_VER="<error>"
  assert "T-3 schema_version bumped to 1.1.0" "1.1.0" "$T3_VER"

  # F-01: migration script は pre_existing=false 初期化を行わない (schema doc canonical)。
  # field 不在 (`null`) を期待する。jq の `// "<absent>"` で field 不在を sentinel 化して assert。
  T3_PE=$(jq -r '.findings[0] | if has("pre_existing") then (.pre_existing | tostring) else "<absent>" end' \
    "$T3_DIR/.rite/review-results/300-20260101000000.json" 2>/dev/null) || T3_PE="<error>"
  assert "T-3 pre_existing field NOT added (schema doc canonical default mapping = 適用しない)" "<absent>" "$T3_PE"

  # accepted-fingerprints state file 初期化も verify (F-06 related — migration の完全性)
  T3_STATE_FILE="$T3_DIR/.rite/state/accepted-fingerprints-300.txt"
  if [ -f "$T3_STATE_FILE" ]; then
    pass "T-3 accepted-fingerprints state file initialized"
  else
    fail "T-3 accepted-fingerprints state file NOT created: $T3_STATE_FILE"
  fi
fi
[ -n "$T3_STDERR" ] && rm -f "$T3_STDERR"

# ------------------------------------------------------------------
# T-4: pre_existing=false × nit-noted auto-correct (invariant #5)
# Why: schema-level contract test for canonical jq mutation
# ------------------------------------------------------------------
echo "=== T-4: pre_existing=false × nit-noted auto-correct (schema-level contract test) ==="
# Schema-level contract test: This test verifies the canonical jq expression from
# review-result-schema.md invariant #5 in isolation. It does NOT verify the actual
# read-side integration in fix.md ステップ 1.2.0. If fix.md ever drifts from this
# canonical jq expression, T-4 alone would not catch it — that bit-exact alignment
# is the responsibility of a separate E2E test (follow-up scope, F-12).
T4_FILE="$sandbox/T4.json"
cat > "$T4_FILE" <<'EOF'
{
  "schema_version": "1.1.0",
  "pr_number": 4,
  "timestamp": "2026-01-01T00:00:00+09:00",
  "commit_sha": "abc",
  "overall_assessment": "fix-needed",
  "findings": [
    { "id": "F-01", "reviewer": "code-quality-reviewer", "category": "code_quality", "severity": "MEDIUM", "scope": "nit-noted", "pre_existing": false, "nit_reason": "should-be-current-pr", "file": "a.ts", "line": 1, "description": "d", "suggestion": "s", "status": "open" }
  ]
}
EOF

# Canonical jq mutation from schema doc invariant #5:
T4_CORRECTED=$(jq '(.findings[] | select(.pre_existing == false and .scope == "nit-noted") | .scope) |= "current-pr"' "$T4_FILE")
T4_NEW_SCOPE=$(echo "$T4_CORRECTED" | jq -r '.findings[0].scope')
assert "T-4 auto-correct rewrites scope to current-pr" "current-pr" "$T4_NEW_SCOPE"

# Verify invariant #5 detector: count violations BEFORE correction
T4_PRE_VIOLATIONS=$(jq '[.findings[] | select(.pre_existing == false and .scope == "nit-noted")] | length' "$T4_FILE")
if [ "$T4_PRE_VIOLATIONS" -ge 1 ]; then
  pass "T-4 invariant #5 detects pre_existing=false × nit-noted before auto-correct (violations=$T4_PRE_VIOLATIONS)"
else
  fail "T-4 invariant #5 missed pre_existing=false × nit-noted (violations=$T4_PRE_VIOLATIONS, expected ≥ 1)"
fi

# Verify invariant #5 NOT triggered when pre_existing=true (legitimate nit)
T4B_FILE="$sandbox/T4b.json"
jq '.findings[0].pre_existing = true' "$T4_FILE" > "$T4B_FILE"
T4B_VIOLATIONS=$(jq '[.findings[] | select(.pre_existing == false and .scope == "nit-noted")] | length' "$T4B_FILE")
assert "T-4 invariant #5 does NOT fire when pre_existing=true" "0" "$T4B_VIOLATIONS"

# ------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------
if ! print_summary "$(basename "$0")" "Hint: scope enum / invariants are defined in plugins/rite/references/review-result-schema.md"; then
  exit 1
fi
exit 0
