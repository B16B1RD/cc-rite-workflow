#!/bin/bash
# Tests for review-source-resolve.sh
# Usage: bash plugins/rite/scripts/tests/review-source-resolve.test.sh
#
# Strategy: review-source-resolve.sh resolves the Hybrid Review Source Priority
# chain (extracted from skills/fix/SKILL.md ステップ 1.2.0).
# It has no gh dependency — only jq / git / find / mktemp — so tests are fully
# hermetic. We run the real script inside a throwaway git repo (so commit_sha
# stale detection has a real HEAD) and assert on:
#   - the final `[CONTEXT] REVIEW_SOURCE=...` marker (stderr, marker fidelity)
#   - the `[CONTEXT] FIX_FALLBACK_FAILED=1; reason=...` markers on fatal paths
#   - exit codes (0 resolved incl. fallback / 1 fatal / 2 usage)
#   - the [fix:error] stdout 分離 invariant: the helper NEVER writes [fix:error]
#     to stdout (the caller owns that emit).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="$(cd "$SCRIPT_DIR/.." && pwd)/review-source-resolve.sh"
TEST_DIR="$(mktemp -d)"
PASS=0
FAIL=0

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required but not installed" >&2
  exit 1
fi

cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT

pass() { PASS=$((PASS + 1)); echo "  ✅ PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ❌ FAIL: $1"; }

# --- sandbox: a throwaway git repo (real HEAD for stale detection) ---
SANDBOX="$TEST_DIR/repo"
mkdir -p "$SANDBOX"
(
  cd "$SANDBOX"
  git init -q
  git config user.email t@example.com
  git config user.name test
  git commit -q --allow-empty -m init
)
# Real HEAD of the sandbox — commit_sha stale detection compares the JSON's
# commit_sha against this. BOGUS_SHA is a valid-shaped SHA guaranteed
# to differ from HEAD so the mismatch branch fires deterministically.
HEAD_SHA=$(cd "$SANDBOX" && git rev-parse HEAD)
BOGUS_SHA="0000000000000000000000000000000000000000"
# Priority 2 の review_source_path は state-path-resolve 基準の絶対パスになった。
# macOS では /tmp が /private/tmp の symlink のため、期待値は git が返す正規化済み
# toplevel から導出する ($SANDBOX の literal 比較は Linux でしか成立しない)。
SANDBOX_ROOT=$(cd "$SANDBOX" && git rev-parse --show-toplevel)

OUT=""; ERR=""; RC=0
run() {
  # run <args...> from inside SANDBOX, capturing stdout/stderr/rc separately.
  # set +e around the substitution: the helper exits non-zero on fatal paths and
  # that must NOT abort the test under `set -e`.
  OUT=""; ERR=""; RC=0
  set +e
  OUT=$(cd "$SANDBOX" && bash "$TARGET" "$@" 2>"$TEST_DIR/err")
  RC=$?
  set -e
  ERR=$(cat "$TEST_DIR/err")
}
assert_rc()        { [ "$RC" = "$1" ] && pass "$2 (rc=$RC)" || fail "$2 (rc=$RC, want $1)"; }
assert_err_has()   { printf '%s' "$ERR" | grep -qF "$1" && pass "$2" || fail "$2 — stderr missing: $1"; }
assert_stdout_empty() { [ -z "$OUT" ] && pass "$1 (stdout empty)" || fail "$1 — stdout NOT empty: [$OUT]"; }
assert_no_fixerror_stdout() { printf '%s' "$OUT" | grep -qF "[fix:error]" && fail "$1 — [fix:error] leaked to stdout" || pass "$1 ([fix:error] not on stdout)"; }
assert_err_lacks() { printf '%s' "$ERR" | grep -qF "$1" && fail "$2 — stderr unexpectedly has: $1" || pass "$2"; }

valid_json() {
  # $1 = path, $2 = overall_assessment (default fix-needed). No commit_sha => stale skip.
  local p="$1" oa="${2:-fix-needed}"
  cat > "$p" <<JSON
{"schema_version":"1.1.0","pr_number":123,"overall_assessment":"$oa","findings":[{"file":"a.ts","line":1,"severity":"HIGH","status":"open","scope":"current-pr"}]}
JSON
}

valid_json_sha() {
  # $1 = path, $2 = commit_sha, $3 = overall_assessment (default fix-needed).
  # Same shape as valid_json but carries an explicit commit_sha so the stale
  # detection branch (verified-review C-1) is exercised.
  local p="$1" sha="$2" oa="${3:-fix-needed}"
  cat > "$p" <<JSON
{"schema_version":"1.1.0","pr_number":123,"commit_sha":"$sha","overall_assessment":"$oa","findings":[{"file":"a.ts","line":1,"severity":"HIGH","status":"open","scope":"current-pr"}]}
JSON
}

measured_json() {
  # $1 = path, $2 = overall_assessment (default fix-needed). No commit_sha => stale skip.
  # Same shape as valid_json but the finding carries verification.measured=true (blocking) —
  # cross-field invariant #2 は measured=true の finding にのみ発火する (実測必須ゲート、Issue #2024)。
  local p="$1" oa="${2:-fix-needed}"
  cat > "$p" <<JSON
{"schema_version":"1.1.0","pr_number":123,"overall_assessment":"$oa","findings":[{"file":"a.ts","line":1,"severity":"HIGH","status":"open","scope":"current-pr","verification":{"measured":true,"repro":"bash cmd => observed failure","failing_test":null}}]}
JSON
}

UNSET="__RITE_UNSET__"

# -----------------------------------------------------------------
echo "--- Test 1: input placeholder / usage fail-fast ---"
run --pr-number "{pr_number}" --review-file-path "$UNSET" --conversation-decision none --p1-scan-turns 0 --p1-scan-found false
assert_rc 1 "pr_number 非数値 -> exit 1"
assert_err_has "reason=pr_number_placeholder_residue" "pr_number placeholder reason"
assert_no_fixerror_stdout "pr_number fatal"

run --pr-number 123 --review-file-path "{review_file_path_from_phase_1_0_1}" --conversation-decision none --p1-scan-turns 0 --p1-scan-found false
assert_rc 1 "review_file_path placeholder -> exit 1"
assert_err_has "reason=review_file_path_placeholder_residue" "review_file_path placeholder reason"
assert_no_fixerror_stdout "review_file_path fatal"

run --pr-number 123 --review-file-path "$UNSET" --conversation-decision "{conversation_review_decision}" --p1-scan-turns 0 --p1-scan-found false
assert_rc 1 "conversation_decision unsubstituted -> exit 1"
assert_err_has "reason=priority1_decision_unset" "decision unset reason"
assert_no_fixerror_stdout "decision unset fatal"

run --pr-number 123 --review-file-path "$UNSET" --conversation-decision bogus --p1-scan-turns 0 --p1-scan-found false
assert_rc 1 "conversation_decision invalid -> exit 1"
assert_err_has "reason=priority1_decision_invalid" "decision invalid reason"
assert_no_fixerror_stdout "decision invalid fatal"

RC=0; { (cd "$SANDBOX" && bash "$TARGET" --bogus x) >/dev/null 2>&1; } || RC=$?
[ "$RC" = 2 ] && pass "unknown arg -> exit 2" || fail "unknown arg -> exit 2 (rc=$RC)"

# -----------------------------------------------------------------
echo "--- Test 2: Priority 1 conversation receipt ---"
# p1_scan_turns の placeholder 残留 ({p1_scan_turns}) は helper が unset sentinel にマップする
run --pr-number 123 --review-file-path "$UNSET" --conversation-decision use --p1-scan-turns "{p1_scan_turns}" --p1-scan-found true
assert_rc 1 "use + receipt missing -> exit 1"
assert_err_has "reason=priority1_receipt_missing" "receipt missing reason"
assert_no_fixerror_stdout "receipt missing fatal"

run --pr-number 123 --review-file-path "$UNSET" --conversation-decision use --p1-scan-turns abc --p1-scan-found true
assert_rc 1 "use + receipt non-numeric -> exit 1"
assert_err_has "reason=priority1_receipt_invalid" "receipt invalid reason"
assert_no_fixerror_stdout "receipt invalid fatal"

run --pr-number 123 --review-file-path "$UNSET" --conversation-decision use --p1-scan-turns 1 --p1-scan-found false
assert_rc 1 "use + found!=true -> exit 1"
assert_err_has "reason=priority1_receipt_inconsistent" "receipt inconsistent reason"
assert_no_fixerror_stdout "receipt inconsistent fatal"

run --pr-number 123 --review-file-path "$UNSET" --conversation-decision use --p1-scan-turns 2 --p1-scan-found true
assert_rc 0 "use valid -> exit 0"
assert_err_has "[CONTEXT] REVIEW_SOURCE=conversation;" "conversation marker"

# -----------------------------------------------------------------
echo "--- Test 3: Priority 0 explicit file ---"
valid_json "$SANDBOX/explicit.json"
run --pr-number 123 --review-file-path "$SANDBOX/explicit.json" --conversation-decision none --p1-scan-turns 0 --p1-scan-found false
assert_rc 0 "explicit valid -> exit 0"
assert_err_has "[CONTEXT] REVIEW_SOURCE=explicit_file; review_source_path=$SANDBOX/explicit.json" "explicit_file marker + path"
assert_stdout_empty "explicit valid"

run --pr-number 123 --review-file-path "$SANDBOX/nope.json" --conversation-decision none --p1-scan-turns 0 --p1-scan-found false
assert_rc 0 "explicit missing -> exit 0 (fallback)"
assert_err_has "[CONTEXT] REVIEW_SOURCE=fallback;" "fallback marker"
assert_err_has "reason=explicit_file_not_found" "explicit_file_not_found reason"

printf 'not json{' > "$SANDBOX/bad.json"
run --pr-number 123 --review-file-path "$SANDBOX/bad.json" --conversation-decision none --p1-scan-turns 0 --p1-scan-found false
assert_rc 0 "explicit invalid JSON -> fallback"
assert_err_has "reason=explicit_file_parse" "explicit_file_parse reason"

measured_json "$SANDBOX/mergeable.json" "mergeable"
run --pr-number 123 --review-file-path "$SANDBOX/mergeable.json" --conversation-decision none --p1-scan-turns 0 --p1-scan-found false
assert_rc 0 "explicit mergeable+open-blocker (measured=true) -> fallback"
assert_err_has "reason=mergeable_has_open_blockers" "cross-field invariant reason"

# 実測必須ゲート (Issue #2024 AC-2/AC-5): mergeable + open HIGH でも measured=false (verification 欠落
# の旧形式) なら non-blocking として invariant #2 は発火せず、正常に受理される
valid_json "$SANDBOX/mergeable-nonmeasured.json" "mergeable"
run --pr-number 123 --review-file-path "$SANDBOX/mergeable-nonmeasured.json" --conversation-decision none --p1-scan-turns 0 --p1-scan-found false
assert_rc 0 "explicit mergeable+non-measured HIGH -> accepted (non-blocking)"
assert_err_has "[CONTEXT] REVIEW_SOURCE=explicit_file; review_source_path=$SANDBOX/mergeable-nonmeasured.json" "non-measured mergeable accepted marker"
assert_err_lacks "reason=mergeable_has_open_blockers" "invariant #2 must not fire for measured=false"

# -----------------------------------------------------------------
echo "--- Test 4: Priority 2 local file ---"
mkdir -p "$SANDBOX/.rite/review-results"
valid_json "$SANDBOX/.rite/review-results/123-20260101000000.json"
run --pr-number 123 --review-file-path "$UNSET" --conversation-decision none --p1-scan-turns 1 --p1-scan-found false
assert_rc 0 "local file valid -> exit 0"
assert_err_has "[CONTEXT] REVIEW_SOURCE=local_file; review_source_path=$SANDBOX_ROOT/.rite/review-results/123-20260101000000.json" "local_file marker + path"

# corrupt local file -> renamed + pr_comment routing
printf 'not json{' > "$SANDBOX/.rite/review-results/123-20260102000000.json"
run --pr-number 123 --review-file-path "$UNSET" --conversation-decision none --p1-scan-turns 1 --p1-scan-found false
assert_rc 0 "local corrupt -> pr_comment"
assert_err_has "reason=local_file_json_parse_failure" "corrupt parse reason"
if ls "$SANDBOX"/.rite/review-results/123-20260102000000.json.corrupt-* >/dev/null 2>&1; then
  pass "corrupt local file renamed to .corrupt-*"
else
  fail "corrupt local file NOT renamed"
fi

# -----------------------------------------------------------------
echo "--- Test 5: Priority 3 fall-through ---"
EMPTY="$TEST_DIR/emptyrepo"; mkdir -p "$EMPTY"
( cd "$EMPTY"; git init -q; git config user.email t@e.com; git config user.name t; git commit -q --allow-empty -m init )
set +e
OUT=$(cd "$EMPTY" && bash "$TARGET" --pr-number 999 --review-file-path "$UNSET" --conversation-decision none --p1-scan-turns 3 --p1-scan-found false 2>"$TEST_DIR/err")
RC=$?
set -e
ERR=$(cat "$TEST_DIR/err")
assert_rc 0 "no source -> exit 0 (pr_comment)"
assert_err_has "[CONTEXT] REVIEW_SOURCE=pr_comment;" "pr_comment marker"
assert_stdout_empty "pr_comment fall-through"
assert_no_fixerror_stdout "pr_comment path"

# -----------------------------------------------------------------
echo "--- Test 6: Priority 0 commit_sha stale detection ---"
# match: commit_sha == HEAD -> explicit_file resolves, no STALE marker
valid_json_sha "$SANDBOX/sha-match.json" "$HEAD_SHA"
run --pr-number 123 --review-file-path "$SANDBOX/sha-match.json" --conversation-decision none --p1-scan-turns 0 --p1-scan-found false
assert_rc 0 "p0 commit_sha match -> exit 0"
assert_err_has "[CONTEXT] REVIEW_SOURCE=explicit_file;" "p0 match resolves explicit_file"
assert_err_lacks "REVIEW_SOURCE_STALE=1" "p0 match does NOT emit STALE"

# mismatch: commit_sha != HEAD -> fallback + STALE marker
valid_json_sha "$SANDBOX/sha-stale.json" "$BOGUS_SHA"
run --pr-number 123 --review-file-path "$SANDBOX/sha-stale.json" --conversation-decision none --p1-scan-turns 0 --p1-scan-found false
assert_rc 0 "p0 commit_sha mismatch -> exit 0 (fallback)"
assert_err_has "[CONTEXT] REVIEW_SOURCE=fallback;" "p0 mismatch -> fallback marker"
assert_err_has "REVIEW_SOURCE_STALE=1; reason=explicit_file_commit_sha_mismatch" "p0 stale reason"
assert_no_fixerror_stdout "p0 stale path"

# -----------------------------------------------------------------
echo "--- Test 7: Priority 0 invariant #4 / enum / schema_version unknown ---"
# invariant #4: severity HIGH + scope nit-noted -> fallback
cat > "$SANDBOX/p0-inv4.json" <<'JSON'
{"schema_version":"1.1.0","pr_number":123,"overall_assessment":"fix-needed","findings":[{"file":"a.ts","line":1,"severity":"HIGH","status":"open","scope":"nit-noted"}]}
JSON
run --pr-number 123 --review-file-path "$SANDBOX/p0-inv4.json" --conversation-decision none --p1-scan-turns 0 --p1-scan-found false
assert_rc 0 "p0 invariant #4 -> exit 0 (fallback)"
assert_err_has "[CONTEXT] REVIEW_SOURCE=fallback;" "p0 invariant #4 -> fallback marker"
assert_err_has "REVIEW_SOURCE_CROSS_FIELD_INVARIANT_VIOLATED=1; reason=explicit_file_critical_high_scope_nit_noted" "p0 invariant #4 reason"

# enum_unknown: overall_assessment bogus -> fallback
cat > "$SANDBOX/p0-enum.json" <<'JSON'
{"schema_version":"1.1.0","pr_number":123,"overall_assessment":"bogus","findings":[{"file":"a.ts","line":1,"severity":"HIGH","status":"open","scope":"current-pr"}]}
JSON
run --pr-number 123 --review-file-path "$SANDBOX/p0-enum.json" --conversation-decision none --p1-scan-turns 0 --p1-scan-found false
assert_rc 0 "p0 enum unknown -> exit 0 (fallback)"
assert_err_has "REVIEW_SOURCE_ENUM_UNKNOWN=1; reason=overall_assessment_unknown_value" "p0 enum unknown reason"

# schema_version unknown: 9.9.9 -> fallback
cat > "$SANDBOX/p0-sv.json" <<'JSON'
{"schema_version":"9.9.9","pr_number":123,"overall_assessment":"fix-needed","findings":[{"file":"a.ts","line":1,"severity":"HIGH","status":"open","scope":"current-pr"}]}
JSON
run --pr-number 123 --review-file-path "$SANDBOX/p0-sv.json" --conversation-decision none --p1-scan-turns 0 --p1-scan-found false
assert_rc 0 "p0 schema_version unknown -> exit 0 (fallback)"
assert_err_has "REVIEW_SOURCE_SCHEMA_UNKNOWN=1; reason=explicit_file_schema_version_unknown" "p0 schema_version unknown reason"

# -----------------------------------------------------------------
echo "--- Test 8: Priority 2 commit_sha stale detection ---"
RR="$SANDBOX/.rite/review-results"
mkdir -p "$RR"
# Distinct pr_number per case so the ${pr_number}-*.json glob isolates each file
# from Test 4's leftovers and from sibling cases.

# match: commit_sha == HEAD -> local_file resolves, no STALE
valid_json_sha "$RR/600-20260101000000.json" "$HEAD_SHA"
run --pr-number 600 --review-file-path "$UNSET" --conversation-decision none --p1-scan-turns 1 --p1-scan-found false
assert_rc 0 "p2 commit_sha match -> exit 0"
assert_err_has "[CONTEXT] REVIEW_SOURCE=local_file;" "p2 match resolves local_file"
assert_err_lacks "REVIEW_SOURCE_STALE=1" "p2 match does NOT emit STALE"

# mismatch: commit_sha != HEAD -> pr_comment + STALE
valid_json_sha "$RR/601-20260101000000.json" "$BOGUS_SHA"
run --pr-number 601 --review-file-path "$UNSET" --conversation-decision none --p1-scan-turns 1 --p1-scan-found false
assert_rc 0 "p2 commit_sha mismatch -> exit 0 (pr_comment)"
assert_err_has "[CONTEXT] REVIEW_SOURCE=pr_comment;" "p2 mismatch -> pr_comment marker"
assert_err_has "REVIEW_SOURCE_STALE=1; reason=local_file_commit_sha_mismatch" "p2 stale reason"
assert_no_fixerror_stdout "p2 stale path"

# -----------------------------------------------------------------
echo "--- Test 9: Priority 2 invariant #2/#4 / enum / schema / 型ガード / corrupt-rename Instance 2-3/3 ---"
# invariant #4: severity CRITICAL + scope nit-noted -> pr_comment
cat > "$RR/700-20260101000000.json" <<'JSON'
{"schema_version":"1.1.0","pr_number":700,"overall_assessment":"fix-needed","findings":[{"file":"a.ts","line":1,"severity":"CRITICAL","status":"open","scope":"nit-noted"}]}
JSON
run --pr-number 700 --review-file-path "$UNSET" --conversation-decision none --p1-scan-turns 1 --p1-scan-found false
assert_rc 0 "p2 invariant #4 -> exit 0 (pr_comment)"
assert_err_has "REVIEW_SOURCE_CROSS_FIELD_INVARIANT_VIOLATED=1; reason=local_file_critical_high_scope_nit_noted" "p2 invariant #4 reason"

# enum_unknown: overall_assessment bogus -> pr_comment
cat > "$RR/701-20260101000000.json" <<'JSON'
{"schema_version":"1.1.0","pr_number":701,"overall_assessment":"bogus","findings":[{"file":"a.ts","line":1,"severity":"HIGH","status":"open","scope":"current-pr"}]}
JSON
run --pr-number 701 --review-file-path "$UNSET" --conversation-decision none --p1-scan-turns 1 --p1-scan-found false
assert_rc 0 "p2 enum unknown -> exit 0 (pr_comment)"
assert_err_has "REVIEW_SOURCE_ENUM_UNKNOWN=1; reason=overall_assessment_unknown_value" "p2 enum unknown reason"

# schema_version unknown: 9.9.9 -> pr_comment
cat > "$RR/702-20260101000000.json" <<'JSON'
{"schema_version":"9.9.9","pr_number":702,"overall_assessment":"fix-needed","findings":[{"file":"a.ts","line":1,"severity":"HIGH","status":"open","scope":"current-pr"}]}
JSON
run --pr-number 702 --review-file-path "$UNSET" --conversation-decision none --p1-scan-turns 1 --p1-scan-found false
assert_rc 0 "p2 schema_version unknown -> exit 0 (pr_comment)"
assert_err_has "REVIEW_SOURCE_SCHEMA_UNKNOWN=1; reason=local_file_schema_version_unknown" "p2 schema_version unknown reason"

# corrupt-rename Instance 2/3: valid JSON but required fields missing -> rename + pr_comment
printf '{"foo":"bar"}' > "$RR/703-20260101000000.json"
run --pr-number 703 --review-file-path "$UNSET" --conversation-decision none --p1-scan-turns 1 --p1-scan-found false
assert_rc 0 "p2 schema_required_fields_missing -> exit 0 (pr_comment)"
assert_err_has "REVIEW_SOURCE_PARSE_FAILED=1; reason=local_file_schema_required_fields_missing" "p2 schema_required_fields_missing reason"
if ls "$RR"/703-20260101000000.json.corrupt-* >/dev/null 2>&1; then
  pass "schema-invalid file renamed to .corrupt-* (Instance 2/3)"
else
  fail "schema-invalid file NOT renamed (Instance 2/3)"
fi

# invariant #2 P2 mirror (positive control): mergeable + open HIGH + measured=true -> pr_comment
# (実測必須ゲート: measured=true の blocking finding のみ invariant #2 が発火する — P0 側 Test 3 の鏡像)
cat > "$RR/704-20260101000000.json" <<'JSON'
{"schema_version":"1.1.0","pr_number":704,"overall_assessment":"mergeable","findings":[{"file":"a.ts","line":1,"severity":"HIGH","status":"open","scope":"current-pr","verification":{"measured":true,"repro":"bash cmd => observed failure","failing_test":null}}]}
JSON
run --pr-number 704 --review-file-path "$UNSET" --conversation-decision none --p1-scan-turns 1 --p1-scan-found false
assert_rc 0 "p2 invariant #2 (measured=true) -> exit 0 (pr_comment)"
assert_err_has "REVIEW_SOURCE_CROSS_FIELD_INVARIANT_VIOLATED=1; reason=local_file_cross_field_invariant_violated" "p2 invariant #2 reason"

# invariant #2 P2 mirror (negative control): mergeable + open HIGH + verification 欠落 (measured=false) -> accepted
cat > "$RR/705-20260101000000.json" <<'JSON'
{"schema_version":"1.1.0","pr_number":705,"overall_assessment":"mergeable","findings":[{"file":"a.ts","line":1,"severity":"HIGH","status":"open","scope":"current-pr"}]}
JSON
run --pr-number 705 --review-file-path "$UNSET" --conversation-decision none --p1-scan-turns 1 --p1-scan-found false
assert_rc 0 "p2 mergeable+non-measured HIGH -> accepted (non-blocking)"
assert_err_has "[CONTEXT] REVIEW_SOURCE=local_file;" "p2 non-measured mergeable accepted marker"
assert_err_lacks "reason=local_file_cross_field_invariant_violated" "p2 invariant #2 must not fire for measured=false"

# verification 型ガード (P2): 非 object の verification -> 専用 reason で pr_comment routing
# (旧実装では invariant #2 の nested access が jq rc=5 になり誤診断と合流していた経路)
cat > "$RR/706-20260101000000.json" <<'JSON'
{"schema_version":"1.1.0","pr_number":706,"overall_assessment":"mergeable","findings":[{"file":"a.ts","line":1,"severity":"HIGH","status":"open","scope":"current-pr","verification":true}]}
JSON
run --pr-number 706 --review-file-path "$UNSET" --conversation-decision none --p1-scan-turns 1 --p1-scan-found false
assert_rc 0 "p2 verification type invalid -> exit 0 (pr_comment)"
assert_err_has "REVIEW_SOURCE_PARSE_FAILED=1; reason=local_file_verification_type_invalid" "p2 verification type guard reason"
assert_err_lacks "reason=local_file_cross_field_invariant_violated" "p2 type guard fires before invariant #2 (no false invariant diagnosis)"

# verification 型ガード (P0): 非 object の verification -> 専用 reason で fallback routing
verification_bool_p0="$SANDBOX/verification-bool.json"
cat > "$verification_bool_p0" <<'JSON'
{"schema_version":"1.1.0","pr_number":123,"overall_assessment":"mergeable","findings":[{"file":"a.ts","line":1,"severity":"HIGH","status":"open","scope":"current-pr","verification":false}]}
JSON
run --pr-number 123 --review-file-path "$verification_bool_p0" --conversation-decision none --p1-scan-turns 0 --p1-scan-found false
assert_rc 0 "p0 verification type invalid -> exit 0 (fallback)"
assert_err_has "REVIEW_SOURCE_PARSE_FAILED=1; reason=explicit_file_verification_type_invalid" "p0 verification type guard reason"
assert_err_has "[CONTEXT] REVIEW_SOURCE=fallback;" "p0 verification type guard -> fallback routing (no silent fall-through to P1-3)"

# measured サブフィールド型ガード (P2): measured が非 bool ("true" 文字列) -> 専用 reason で reject
# (measured:"true" は `// false` で silent に non-blocking 化し mergeable 偽装 bypass になる経路 —
#  型ガードが boolean/null 以外を前段で loud に落とすことを positive control で pin する)
cat > "$RR/707-20260101000000.json" <<'JSON'
{"schema_version":"1.1.0","pr_number":707,"overall_assessment":"mergeable","findings":[{"file":"a.ts","line":1,"severity":"HIGH","status":"open","scope":"current-pr","verification":{"measured":"true","repro":"cmd => boom","failing_test":null}}]}
JSON
run --pr-number 707 --review-file-path "$UNSET" --conversation-decision none --p1-scan-turns 1 --p1-scan-found false
assert_rc 0 "p2 measured type invalid (string) -> exit 0 (pr_comment)"
assert_err_has "REVIEW_SOURCE_PARSE_FAILED=1; reason=local_file_verification_type_invalid" "p2 measured type guard reason"
assert_err_lacks "[CONTEXT] REVIEW_SOURCE=local_file;" "p2 measured type invalid must not be accepted as local_file"
if ls "$RR"/707-20260101000000.json.corrupt-* >/dev/null 2>&1; then
  pass "type-invalid file renamed to .corrupt-* (Instance 3/3)"
else
  fail "type-invalid file NOT renamed (Instance 3/3)"
fi

# measured 欠落 (verification:{}) は default mapping 対象として受理される (型ガードは measured の存在を要求しない)
cat > "$RR/708-20260101000000.json" <<'JSON'
{"schema_version":"1.1.0","pr_number":708,"overall_assessment":"mergeable","findings":[{"file":"a.ts","line":1,"severity":"HIGH","status":"open","scope":"current-pr","verification":{}}]}
JSON
run --pr-number 708 --review-file-path "$UNSET" --conversation-decision none --p1-scan-turns 1 --p1-scan-found false
assert_rc 0 "p2 empty verification object -> accepted (measured absent = default mapping)"
assert_err_has "[CONTEXT] REVIEW_SOURCE=local_file;" "p2 empty verification object accepted marker"
assert_err_lacks "reason=local_file_verification_type_invalid" "type guard must not fire for verification:{}"

# 正準非実測形状の受理 (AC-2 主経路): pr-review ステップ 6.1.a は非実測 finding に対し **常に**
# {"measured":false,"repro":null,"failing_test":null} を出力する。この形状が受理されることを
# 直接 pin する (verification 欠落 / verification:{} は「旧形式・部分形」であって主経路ではない)。
# 型ガード述語を `(.verification.measured == true)` 等に変える 3-site 一貫 mutation は、
# Test 10 の静的 parity では anchor も同時更新されるため素通りする — 本 fixture が唯一の semantics pin。
cat > "$RR/711-20260101000000.json" <<'JSON'
{"schema_version":"1.1.0","pr_number":711,"overall_assessment":"mergeable","findings":[{"file":"a.ts","line":1,"severity":"HIGH","status":"open","scope":"current-pr","verification":{"measured":false,"repro":null,"failing_test":null}}]}
JSON
run --pr-number 711 --review-file-path "$UNSET" --conversation-decision none --p1-scan-turns 1 --p1-scan-found false
assert_rc 0 "p2 canonical non-measured shape -> accepted (AC-2 main path)"
assert_err_has "[CONTEXT] REVIEW_SOURCE=local_file;" "p2 canonical non-measured accepted marker"
assert_err_lacks "reason=local_file_verification_type_invalid" "p2 canonical non-measured: type guard must not fire"
assert_err_lacks "reason=local_file_cross_field_invariant_violated" "p2 canonical non-measured: invariant #2 must not fire (measured=false)"

# all() 普遍量化の pin (P2 型ガード): 1 件目 well-typed / 2 件目型崩れの複数 finding で、
# all→any 変異 (単一 finding fixture では観測不能) を検出する。型ガードが 2 件目を検出し、
# invariant #2 の rc=5 誤診断 (型ガード導入前の症状) が復活しないことを併せて pin する
cat > "$RR/709-20260101000000.json" <<'JSON'
{"schema_version":"1.1.0","pr_number":709,"overall_assessment":"mergeable","findings":[{"file":"a.ts","line":1,"severity":"LOW","status":"open","scope":"nit-noted","verification":{"measured":false,"repro":null,"failing_test":null}},{"file":"b.ts","line":2,"severity":"HIGH","status":"open","scope":"current-pr","verification":true}]}
JSON
run --pr-number 709 --review-file-path "$UNSET" --conversation-decision none --p1-scan-turns 1 --p1-scan-found false
assert_rc 0 "p2 multi-finding type guard (2nd finding malformed) -> exit 0 (pr_comment)"
assert_err_has "reason=local_file_verification_type_invalid" "p2 multi-finding all() quantification detects 2nd finding"
assert_err_lacks "reason=local_file_cross_field_invariant_violated" "p2 multi-finding: no rc=5 false invariant diagnosis"

# all() 普遍量化の pin (P2 invariant #2): 非実測 HIGH + 実測 HIGH の 2 件 mergeable で
# 「1 件でも measured=true の open blocker があれば発火する」ことを pin する
cat > "$RR/710-20260101000000.json" <<'JSON'
{"schema_version":"1.1.0","pr_number":710,"overall_assessment":"mergeable","findings":[{"file":"a.ts","line":1,"severity":"HIGH","status":"open","scope":"current-pr"},{"file":"b.ts","line":2,"severity":"HIGH","status":"open","scope":"current-pr","verification":{"measured":true,"repro":"cmd => boom","failing_test":null}}]}
JSON
run --pr-number 710 --review-file-path "$UNSET" --conversation-decision none --p1-scan-turns 1 --p1-scan-found false
assert_rc 0 "p2 multi-finding invariant #2 (one measured blocker among non-measured) -> exit 0 (pr_comment)"
assert_err_has "reason=local_file_cross_field_invariant_violated" "p2 multi-finding invariant #2 fires on the single measured blocker"

# P0 鏡像: verification:{} 受理 (measured 欠落 = default mapping、false rejection 防止)
verification_empty_p0="$SANDBOX/verification-empty.json"
cat > "$verification_empty_p0" <<'JSON'
{"schema_version":"1.1.0","pr_number":123,"overall_assessment":"mergeable","findings":[{"file":"a.ts","line":1,"severity":"HIGH","status":"open","scope":"current-pr","verification":{}}]}
JSON
run --pr-number 123 --review-file-path "$verification_empty_p0" --conversation-decision none --p1-scan-turns 0 --p1-scan-found false
assert_rc 0 "p0 empty verification object -> accepted"
assert_err_has "[CONTEXT] REVIEW_SOURCE=explicit_file; review_source_path=$verification_empty_p0" "p0 empty verification object accepted marker"
assert_err_lacks "reason=explicit_file_verification_type_invalid" "p0 type guard must not fire for verification:{}"

# P0 鏡像: measured:"true" (非 bool) reject -> fallback
measured_string_p0="$SANDBOX/measured-string.json"
cat > "$measured_string_p0" <<'JSON'
{"schema_version":"1.1.0","pr_number":123,"overall_assessment":"mergeable","findings":[{"file":"a.ts","line":1,"severity":"HIGH","status":"open","scope":"current-pr","verification":{"measured":"true","repro":"cmd => boom","failing_test":null}}]}
JSON
run --pr-number 123 --review-file-path "$measured_string_p0" --conversation-decision none --p1-scan-turns 0 --p1-scan-found false
assert_rc 0 "p0 measured type invalid (string) -> exit 0 (fallback)"
assert_err_has "reason=explicit_file_verification_type_invalid" "p0 measured type guard reason"
assert_err_has "[CONTEXT] REVIEW_SOURCE=fallback;" "p0 measured type invalid -> fallback routing"

# P0 鏡像: 正準非実測形状の受理 (AC-2 主経路、P2 fixture 711 の鏡像)
nonmeasured_p0="$SANDBOX/nonmeasured-canonical.json"
cat > "$nonmeasured_p0" <<'JSON'
{"schema_version":"1.1.0","pr_number":123,"overall_assessment":"mergeable","findings":[{"file":"a.ts","line":1,"severity":"HIGH","status":"open","scope":"current-pr","verification":{"measured":false,"repro":null,"failing_test":null}}]}
JSON
run --pr-number 123 --review-file-path "$nonmeasured_p0" --conversation-decision none --p1-scan-turns 0 --p1-scan-found false
assert_rc 0 "p0 canonical non-measured shape -> accepted (AC-2 main path)"
assert_err_has "[CONTEXT] REVIEW_SOURCE=explicit_file; review_source_path=$nonmeasured_p0" "p0 canonical non-measured accepted marker"
assert_err_lacks "reason=explicit_file_verification_type_invalid" "p0 canonical non-measured: type guard must not fire"
assert_err_lacks "reason=mergeable_has_open_blockers" "p0 canonical non-measured: invariant #2 must not fire (measured=false)"

# P0 鏡像: all() 普遍量化の pin (型ガード)。P2 fixture 709 と同形状。
# P0 は --review-file 明示指定経路であり、単一 finding fixture だけでは all→any 変異が
# 静的 parity のカウントでしか検出されない (semantics 非 pin) ため、複数 finding を置く。
multi_typeguard_p0="$SANDBOX/multi-typeguard.json"
cat > "$multi_typeguard_p0" <<'JSON'
{"schema_version":"1.1.0","pr_number":123,"overall_assessment":"mergeable","findings":[{"file":"a.ts","line":1,"severity":"LOW","status":"open","scope":"nit-noted","verification":{"measured":false,"repro":null,"failing_test":null}},{"file":"b.ts","line":2,"severity":"HIGH","status":"open","scope":"current-pr","verification":true}]}
JSON
run --pr-number 123 --review-file-path "$multi_typeguard_p0" --conversation-decision none --p1-scan-turns 0 --p1-scan-found false
assert_rc 0 "p0 multi-finding type guard (2nd finding malformed) -> exit 0 (fallback)"
assert_err_has "reason=explicit_file_verification_type_invalid" "p0 multi-finding all() quantification detects 2nd finding"
assert_err_lacks "reason=mergeable_has_open_blockers" "p0 multi-finding: no rc=5 false invariant diagnosis"

# P0 鏡像: all() 普遍量化の pin (invariant #2)。P2 fixture 710 と同形状。
multi_invariant_p0="$SANDBOX/multi-invariant.json"
cat > "$multi_invariant_p0" <<'JSON'
{"schema_version":"1.1.0","pr_number":123,"overall_assessment":"mergeable","findings":[{"file":"a.ts","line":1,"severity":"HIGH","status":"open","scope":"current-pr"},{"file":"b.ts","line":2,"severity":"HIGH","status":"open","scope":"current-pr","verification":{"measured":true,"repro":"cmd => boom","failing_test":null}}]}
JSON
run --pr-number 123 --review-file-path "$multi_invariant_p0" --conversation-decision none --p1-scan-turns 0 --p1-scan-found false
assert_rc 0 "p0 multi-finding invariant #2 (one measured blocker among non-measured) -> exit 0 (fallback)"
assert_err_has "reason=mergeable_has_open_blockers" "p0 multi-finding invariant #2 fires on the single measured blocker"

# -----------------------------------------------------------------
echo "--- Test 10: 3-site parity (static) — 型ガード / invariant #2 measured 節 ---"
# 同一 jq 述語が review-source-resolve.sh (P0/P2 の 2 site) と fix/SKILL.md (P3 の 1 site) に
# 同数出現することを静的に検証する (片側だけ更新される drift の検出。P3 は markdown 埋め込み
# bash のため実行テスト不能 — grep parity で pin する)。anchor は述語式**全体** (all( prefix と
# 選言構造を含む) — 部分文字列 anchor では all→any 等の意味論 drift が素通りするため
GUARD_PRED='all(.findings[]?; (.verification == null) or (((.verification | type) == "object") and ((.verification.measured == null) or ((.verification.measured | type) == "boolean"))))'
INV2_PRED='or (all(.findings[]?; (.severity != "CRITICAL" and .severity != "HIGH") or (.status != "open") or ((.verification.measured // false) != true)))'
FIX_MD="$SCRIPT_DIR/../../skills/fix/SKILL.md"
# grep の rc=1 (マッチなし = 正常な 0 件) と rc=2 (ファイル読取不能 = IO エラー) を区別する。
# `|| true` で融合すると IO エラー時に grep -c がカウントを出力せず変数が空文字になり、
# 後段の等値比較が "expected 2, got " という原因不明の parity 失敗として報告される (診断の誤誘導)。
count_pred() {  # $1=pattern $2=file $3=label
  local out rc
  out=$(grep -cF "$1" "$2"); rc=$?
  case "$rc" in
    0|1) printf '%s' "${out:-0}" ;;
    *)   fail "parity: grep IO error on $3 (rc=$rc, file=$2)"; printf '%s' "-1" ;;
  esac
}
guard_sh_count=$(count_pred "$GUARD_PRED" "$SCRIPT_DIR/../review-source-resolve.sh" "type guard/.sh")
inv2_sh_count=$(count_pred "$INV2_PRED" "$SCRIPT_DIR/../review-source-resolve.sh" "invariant #2/.sh")
guard_md_count=$(count_pred "$GUARD_PRED" "$FIX_MD" "type guard/fix.md")
inv2_md_count=$(count_pred "$INV2_PRED" "$FIX_MD" "invariant #2/fix.md")
if [ "$guard_sh_count" = "2" ]; then pass "parity: full type guard predicate x2 in review-source-resolve.sh"; else fail "parity: full type guard predicate expected 2 in .sh, got $guard_sh_count"; fi
if [ "$inv2_sh_count" = "2" ]; then pass "parity: full invariant #2 measured clause x2 in review-source-resolve.sh"; else fail "parity: full invariant #2 measured clause expected 2 in .sh, got $inv2_sh_count"; fi
if [ "$guard_md_count" = "1" ]; then pass "parity: full type guard predicate x1 in fix/SKILL.md (P3)"; else fail "parity: full type guard predicate expected 1 in fix/SKILL.md, got $guard_md_count"; fi
if [ "$inv2_md_count" = "1" ]; then pass "parity: full invariant #2 measured clause x1 in fix/SKILL.md (P3)"; else fail "parity: full invariant #2 measured clause expected 1 in fix/SKILL.md, got $inv2_md_count"; fi
# P3 の順序 drift pin: fix/SKILL.md 内で型ガード行が invariant #2 行より前に出現すること
guard_md_line=$(grep -nF "$GUARD_PRED" "$FIX_MD" | head -1 | cut -d: -f1 || true)
inv2_md_line=$(grep -nF "$INV2_PRED" "$FIX_MD" | head -1 | cut -d: -f1 || true)
if [ -n "$guard_md_line" ] && [ -n "$inv2_md_line" ] && [ "$guard_md_line" -lt "$inv2_md_line" ]; then
  pass "parity: P3 type guard precedes invariant #2 (line $guard_md_line < $inv2_md_line)"
else
  fail "parity: P3 order drift — type guard line=$guard_md_line, invariant #2 line=$inv2_md_line"
fi
# P3 到達性 pin: 述語行の直前行が生きた elif 分岐そのものであること。述語テキストと行順だけの
# parity では `elif false && ! printf` 等の死に分岐化 drift が素通りする (mutation 実測で確認済み)
guard_md_prev=$(sed -n "$(( ${guard_md_line:-0} - 1 ))p" "$FIX_MD" 2>/dev/null || true)
case "$guard_md_prev" in
  "elif ! printf '%s' \"\$raw_json\" | jq -e '")
    pass "parity: P3 type guard sits in a live elif branch"
    ;;
  *)
    fail "parity: P3 type guard reachability drift — prev line: ${guard_md_prev:-<empty>}"
    ;;
esac
# P3 emit pin: 専用 reason の stderr emit 行 (reason 文字列 + >&2 まで含む固定文字列) が 1 箇所
# 存在すること。reason 改変 / stderr → stdout 化の drift は述語 parity では検出できない
guard_emit_count=$(count_pred 'reason=pr_comment_verification_type_invalid" >&2' "$FIX_MD" "P3 emit/fix.md")
if [ "$guard_emit_count" = "1" ]; then
  pass "parity: P3 type guard emit line (reason + stderr redirect) pinned x1"
else
  fail "parity: P3 type guard emit drift — expected 1, got $guard_emit_count"
fi

# -----------------------------------------------------------------
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
