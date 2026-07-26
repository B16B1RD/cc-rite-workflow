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

valid_json "$SANDBOX/mergeable.json" "mergeable"
run --pr-number 123 --review-file-path "$SANDBOX/mergeable.json" --conversation-decision none --p1-scan-turns 0 --p1-scan-found false
assert_rc 0 "explicit mergeable+open-blocker -> fallback"
assert_err_has "reason=mergeable_has_open_blockers" "cross-field invariant reason"

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
echo "--- Test 9: Priority 2 invariant #4 / enum / schema / corrupt-rename Instance 2/3 ---"
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

# -----------------------------------------------------------------
echo "--- Test 10: verification 型ガード / default mapping (Priority 0) ---"
# 全 fixture の overall_assessment は fix-needed。mergeable + open HIGH は cross-field
# invariant #2 が先に発火して routing を奪うため、それでは verification の受理/reject を
# 観測できず vacuous pass になる (invariant #2 自体は本 Issue の範囲外で無変更)。

# 正準非実測形状 (review-result-schema.md §verification サブフィールド が write 側に課す形) の受理。
# verification 欠落 / {} は「旧形式・部分形」であって主経路ではないため、この形状を直接 pin する。
cat > "$SANDBOX/p0-verif-canonical.json" <<'JSON'
{"schema_version":"1.1.0","pr_number":123,"overall_assessment":"fix-needed","findings":[{"file":"a.ts","line":1,"severity":"HIGH","status":"open","scope":"current-pr","verification":{"measured":false,"repro":null,"failing_test":null}}]}
JSON
run --pr-number 123 --review-file-path "$SANDBOX/p0-verif-canonical.json" --conversation-decision none --p1-scan-turns 0 --p1-scan-found false
assert_rc 0 "p0 canonical non-measured verification -> exit 0"
assert_err_has "[CONTEXT] REVIEW_SOURCE=explicit_file; review_source_path=$SANDBOX/p0-verif-canonical.json" "p0 canonical verification accepted"
assert_err_lacks "reason=explicit_file_verification_type_invalid" "p0 canonical: type guard must not fire"

# 実測あり形状 (measured=true + repro) も型ガードを通過する
cat > "$SANDBOX/p0-verif-measured.json" <<'JSON'
{"schema_version":"1.1.0","pr_number":123,"overall_assessment":"fix-needed","findings":[{"file":"a.ts","line":1,"severity":"HIGH","status":"open","scope":"current-pr","verification":{"measured":true,"repro":"bash cmd => observed failure","failing_test":null}}]}
JSON
run --pr-number 123 --review-file-path "$SANDBOX/p0-verif-measured.json" --conversation-decision none --p1-scan-turns 0 --p1-scan-found false
assert_rc 0 "p0 measured verification -> exit 0"
assert_err_has "[CONTEXT] REVIEW_SOURCE=explicit_file; review_source_path=$SANDBOX/p0-verif-measured.json" "p0 measured verification accepted"

# verification 欠落の旧形式が受理される (後方互換 — 型ガードは verification の存在を要求しない)
cat > "$SANDBOX/p0-verif-absent.json" <<'JSON'
{"schema_version":"1.1.0","pr_number":123,"overall_assessment":"fix-needed","findings":[{"file":"a.ts","line":1,"severity":"HIGH","status":"open","scope":"current-pr"}]}
JSON
run --pr-number 123 --review-file-path "$SANDBOX/p0-verif-absent.json" --conversation-decision none --p1-scan-turns 0 --p1-scan-found false
assert_rc 0 "p0 verification absent (legacy shape) -> exit 0"
assert_err_has "[CONTEXT] REVIEW_SOURCE=explicit_file; review_source_path=$SANDBOX/p0-verif-absent.json" "p0 verification absent accepted"
assert_err_lacks "reason=explicit_file_verification_type_invalid" "p0 verification absent: type guard must not fire"

# verification:{} (measured 欠落) は default mapping 対象として受理される。
# 型ガード述語を「measured の存在を要求する」形に強めた mutation はここで落ちる。
cat > "$SANDBOX/p0-verif-empty.json" <<'JSON'
{"schema_version":"1.1.0","pr_number":123,"overall_assessment":"fix-needed","findings":[{"file":"a.ts","line":1,"severity":"HIGH","status":"open","scope":"current-pr","verification":{}}]}
JSON
run --pr-number 123 --review-file-path "$SANDBOX/p0-verif-empty.json" --conversation-decision none --p1-scan-turns 0 --p1-scan-found false
assert_rc 0 "p0 empty verification object -> exit 0"
assert_err_has "[CONTEXT] REVIEW_SOURCE=explicit_file; review_source_path=$SANDBOX/p0-verif-empty.json" "p0 empty verification accepted (measured absent = default mapping)"
assert_err_lacks "reason=explicit_file_verification_type_invalid" "p0 verification:{}: type guard must not fire"

# 非 object の verification: nested access が jq rc=5 になり後段 invariant と誤合流するため、
# 前段で専用 reason により fallback へ routing する (Priority 1-3 に silent fall-through しない)。
cat > "$SANDBOX/p0-verif-bool.json" <<'JSON'
{"schema_version":"1.1.0","pr_number":123,"overall_assessment":"fix-needed","findings":[{"file":"a.ts","line":1,"severity":"HIGH","status":"open","scope":"current-pr","verification":true}]}
JSON
run --pr-number 123 --review-file-path "$SANDBOX/p0-verif-bool.json" --conversation-decision none --p1-scan-turns 0 --p1-scan-found false
assert_rc 0 "p0 verification type invalid (bool) -> exit 0 (fallback)"
assert_err_has "REVIEW_SOURCE_PARSE_FAILED=1; reason=explicit_file_verification_type_invalid" "p0 verification type guard reason"
assert_err_has "[CONTEXT] REVIEW_SOURCE=fallback;" "p0 type guard -> fallback (no silent fall-through)"

# 非 bool の measured ("true" 文字列): `// false` で silent に non-blocking へ畳まれる経路を塞ぐ
cat > "$SANDBOX/p0-measured-string.json" <<'JSON'
{"schema_version":"1.1.0","pr_number":123,"overall_assessment":"fix-needed","findings":[{"file":"a.ts","line":1,"severity":"HIGH","status":"open","scope":"current-pr","verification":{"measured":"true","repro":"cmd => boom","failing_test":null}}]}
JSON
run --pr-number 123 --review-file-path "$SANDBOX/p0-measured-string.json" --conversation-decision none --p1-scan-turns 0 --p1-scan-found false
assert_rc 0 "p0 measured type invalid (string) -> exit 0 (fallback)"
assert_err_has "REVIEW_SOURCE_PARSE_FAILED=1; reason=explicit_file_verification_type_invalid" "p0 measured type guard reason"
assert_err_lacks "[CONTEXT] REVIEW_SOURCE=explicit_file;" "p0 measured type invalid must not be accepted"

# all() 普遍量化: 先頭 finding が正常でも後続の型崩れを検出する
# (述語を .findings[0] だけ見る形に弱めた mutation はここで落ちる)
cat > "$SANDBOX/p0-verif-multi.json" <<'JSON'
{"schema_version":"1.1.0","pr_number":123,"overall_assessment":"fix-needed","findings":[{"file":"a.ts","line":1,"severity":"LOW","status":"open","scope":"nit-noted","verification":{"measured":false,"repro":null,"failing_test":null}},{"file":"b.ts","line":2,"severity":"HIGH","status":"open","scope":"current-pr","verification":true}]}
JSON
run --pr-number 123 --review-file-path "$SANDBOX/p0-verif-multi.json" --conversation-decision none --p1-scan-turns 0 --p1-scan-found false
assert_rc 0 "p0 multi-finding type guard -> exit 0 (fallback)"
assert_err_has "REVIEW_SOURCE_PARSE_FAILED=1; reason=explicit_file_verification_type_invalid" "p0 all() detects 2nd finding"

# -----------------------------------------------------------------
echo "--- Test 11: verification 型ガード / default mapping (Priority 2) ---"
# P0 の鏡像。P2 は型崩れを .corrupt-{epoch} に rename して Priority 3 へ routing する
# (sibling の parse failure / required-fields missing と同じ扱い — 型崩れは自己修復しないため)。

cat > "$RR/704-20260101000000.json" <<'JSON'
{"schema_version":"1.1.0","pr_number":704,"overall_assessment":"fix-needed","findings":[{"file":"a.ts","line":1,"severity":"HIGH","status":"open","scope":"current-pr","verification":{"measured":false,"repro":null,"failing_test":null}}]}
JSON
run --pr-number 704 --review-file-path "$UNSET" --conversation-decision none --p1-scan-turns 1 --p1-scan-found false
assert_rc 0 "p2 canonical non-measured verification -> exit 0"
assert_err_has "[CONTEXT] REVIEW_SOURCE=local_file;" "p2 canonical verification accepted"
assert_err_lacks "reason=local_file_verification_type_invalid" "p2 canonical: type guard must not fire"

cat > "$RR/705-20260101000000.json" <<'JSON'
{"schema_version":"1.1.0","pr_number":705,"overall_assessment":"fix-needed","findings":[{"file":"a.ts","line":1,"severity":"HIGH","status":"open","scope":"current-pr","verification":{}}]}
JSON
run --pr-number 705 --review-file-path "$UNSET" --conversation-decision none --p1-scan-turns 1 --p1-scan-found false
assert_rc 0 "p2 empty verification object -> exit 0"
assert_err_has "[CONTEXT] REVIEW_SOURCE=local_file;" "p2 empty verification accepted (measured absent = default mapping)"
assert_err_lacks "reason=local_file_verification_type_invalid" "p2 verification:{}: type guard must not fire"

cat > "$RR/706-20260101000000.json" <<'JSON'
{"schema_version":"1.1.0","pr_number":706,"overall_assessment":"fix-needed","findings":[{"file":"a.ts","line":1,"severity":"HIGH","status":"open","scope":"current-pr","verification":true}]}
JSON
run --pr-number 706 --review-file-path "$UNSET" --conversation-decision none --p1-scan-turns 1 --p1-scan-found false
assert_rc 0 "p2 verification type invalid (bool) -> exit 0 (pr_comment)"
assert_err_has "REVIEW_SOURCE_PARSE_FAILED=1; reason=local_file_verification_type_invalid" "p2 verification type guard reason"
assert_err_lacks "[CONTEXT] REVIEW_SOURCE=local_file;" "p2 type invalid must not be accepted as local_file"
if ls "$RR"/706-20260101000000.json.corrupt-* >/dev/null 2>&1; then
  pass "type-invalid file renamed to .corrupt-* (Instance 3/3)"
else
  fail "type-invalid file NOT renamed (Instance 3/3)"
fi

cat > "$RR/707-20260101000000.json" <<'JSON'
{"schema_version":"1.1.0","pr_number":707,"overall_assessment":"fix-needed","findings":[{"file":"a.ts","line":1,"severity":"HIGH","status":"open","scope":"current-pr","verification":{"measured":"true","repro":"cmd => boom","failing_test":null}}]}
JSON
run --pr-number 707 --review-file-path "$UNSET" --conversation-decision none --p1-scan-turns 1 --p1-scan-found false
assert_rc 0 "p2 measured type invalid (string) -> exit 0 (pr_comment)"
assert_err_has "REVIEW_SOURCE_PARSE_FAILED=1; reason=local_file_verification_type_invalid" "p2 measured type guard reason"
assert_err_lacks "[CONTEXT] REVIEW_SOURCE=local_file;" "p2 measured type invalid must not be accepted as local_file"

cat > "$RR/708-20260101000000.json" <<'JSON'
{"schema_version":"1.1.0","pr_number":708,"overall_assessment":"fix-needed","findings":[{"file":"a.ts","line":1,"severity":"LOW","status":"open","scope":"nit-noted","verification":{"measured":false,"repro":null,"failing_test":null}},{"file":"b.ts","line":2,"severity":"HIGH","status":"open","scope":"current-pr","verification":true}]}
JSON
run --pr-number 708 --review-file-path "$UNSET" --conversation-decision none --p1-scan-turns 1 --p1-scan-found false
assert_rc 0 "p2 multi-finding type guard -> exit 0 (pr_comment)"
assert_err_has "REVIEW_SOURCE_PARSE_FAILED=1; reason=local_file_verification_type_invalid" "p2 all() detects 2nd finding"

# -----------------------------------------------------------------
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
