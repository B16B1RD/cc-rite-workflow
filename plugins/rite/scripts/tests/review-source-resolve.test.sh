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
echo "--- Test 9: Priority 2 invariant #4 / enum / schema / corrupt-rename 呼び出し元: schema-invalid path ---"
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

# corrupt-rename 呼び出し元 (schema-invalid path): valid JSON but required fields missing -> rename + pr_comment
printf '{"foo":"bar"}' > "$RR/703-20260101000000.json"
run --pr-number 703 --review-file-path "$UNSET" --conversation-decision none --p1-scan-turns 1 --p1-scan-found false
assert_rc 0 "p2 schema_required_fields_missing -> exit 0 (pr_comment)"
assert_err_has "REVIEW_SOURCE_PARSE_FAILED=1; reason=local_file_schema_required_fields_missing" "p2 schema_required_fields_missing reason"
if ls "$RR"/703-20260101000000.json.corrupt-* >/dev/null 2>&1; then
  pass "schema-invalid file renamed to .corrupt-* (_rite_rename_corrupt_file 呼び出し元)"
else
  fail "schema-invalid file NOT renamed (_rite_rename_corrupt_file 呼び出し元)"
fi

# -----------------------------------------------------------------
echo "--- Test 10: verification 型ガード / default mapping (Priority 0) ---"
# accept fixture の overall_assessment は fix-needed。mergeable + open HIGH は cross-field
# invariant #2 が先に発火して routing を奪うため、その形状では受理判定を観測できず vacuous pass に
# なる。逆に reject fixture では両分岐が発火可能なため、mergeable を使って型ガードと invariant #2 の
# precedence 自体を pin する (下記 p0-verif-order / 709 fixture)。invariant #2 の述語は無変更。

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
# fixture は valid_json helper と同一形状のため helper を使う (schema 変更時に追従漏れしない)
valid_json "$SANDBOX/p0-verif-absent.json"
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
# P0 は rename しない (schema SoT の非対称契約: P0 → fallback のみ / P2 → Priority 3 + rename)。
# ユーザーが --review-file で明示指定したファイルを破壊的に rename してはならない。
# P2 側の rename pin と対称化リファクタする際にこの非対称が壊れるのを防ぐ。
if ls "$SANDBOX"/p0-verif-bool.json.corrupt-* >/dev/null 2>&1; then
  fail "P0 は明示指定ファイルを rename してはいけない"
else
  pass "P0 型ガードは rename しない (P2 との非対称契約)"
fi

# 非 bool の measured ("true" 文字列): `// false` で silent に non-blocking へ畳まれる経路を塞ぐ
cat > "$SANDBOX/p0-measured-string.json" <<'JSON'
{"schema_version":"1.1.0","pr_number":123,"overall_assessment":"fix-needed","findings":[{"file":"a.ts","line":1,"severity":"HIGH","status":"open","scope":"current-pr","verification":{"measured":"true","repro":"cmd => boom","failing_test":null}}]}
JSON
run --pr-number 123 --review-file-path "$SANDBOX/p0-measured-string.json" --conversation-decision none --p1-scan-turns 0 --p1-scan-found false
assert_rc 0 "p0 measured type invalid (string) -> exit 0 (fallback)"
assert_err_has "REVIEW_SOURCE_PARSE_FAILED=1; reason=explicit_file_verification_type_invalid" "p0 measured type guard reason"
assert_err_lacks "[CONTEXT] REVIEW_SOURCE=explicit_file;" "p0 measured type invalid must not be accepted"
# sibling (p0-verif-bool) と同じ強さで routing を pin する。assert_err_lacks は explicit_file 以外の
# すべてを通す否定条件なので、終端値そのものを positive に固定する
assert_err_has "[CONTEXT] REVIEW_SOURCE=fallback;" "p0 measured type invalid -> fallback routing"

# all() 普遍量化: 先頭 finding が正常でも後続の型崩れを検出する
# (述語を .findings[0] だけ見る形に弱めた mutation はここで落ちる)
cat > "$SANDBOX/p0-verif-multi.json" <<'JSON'
{"schema_version":"1.1.0","pr_number":123,"overall_assessment":"fix-needed","findings":[{"file":"a.ts","line":1,"severity":"LOW","status":"open","scope":"nit-noted","verification":{"measured":false,"repro":null,"failing_test":null}},{"file":"b.ts","line":2,"severity":"HIGH","status":"open","scope":"current-pr","verification":true}]}
JSON
run --pr-number 123 --review-file-path "$SANDBOX/p0-verif-multi.json" --conversation-decision none --p1-scan-turns 0 --p1-scan-found false
assert_rc 0 "p0 multi-finding type guard -> exit 0 (fallback)"
assert_err_has "REVIEW_SOURCE_PARSE_FAILED=1; reason=explicit_file_verification_type_invalid" "p0 all() detects 2nd finding"
assert_err_has "[CONTEXT] REVIEW_SOURCE=fallback;" "p0 multi-finding type guard -> fallback routing"

# 型ガードが invariant #2 より前段にあることを pin する。accept fixture の overall_assessment が
# fix-needed なのは invariant #2 を短絡させて型ガードの受理判定を観測するためだが、その形状では
# 両者の precedence 自体が観測できない。reject fixture では mergeable + open HIGH にすることで
# 両分岐が発火可能になり、どちらの reason を取るかで配置が pin される。
cat > "$SANDBOX/p0-verif-order.json" <<'JSON'
{"schema_version":"1.1.0","pr_number":123,"overall_assessment":"mergeable","findings":[{"file":"a.ts","line":1,"severity":"HIGH","status":"open","scope":"current-pr","verification":true}]}
JSON
run --pr-number 123 --review-file-path "$SANDBOX/p0-verif-order.json" --conversation-decision none --p1-scan-turns 0 --p1-scan-found false
assert_rc 0 "p0 guard-before-invariant2 -> exit 0 (fallback)"
assert_err_has "REVIEW_SOURCE_PARSE_FAILED=1; reason=explicit_file_verification_type_invalid" "p0 型ガードが invariant #2 より先に発火する"
assert_err_lacks "reason=mergeable_has_open_blockers" "p0 invariant #2 は型ガードの後段に留まる"

# jq 自体の失敗 (findings 要素が非 object → nested access が rc=5) は型崩れと別 reason になる。
# 両者を融合すると verification を持たない JSON にも type_invalid が付き診断が事実とずれる。
cat > "$SANDBOX/p0-verif-jqfail.json" <<'JSON'
{"schema_version":"1.1.0","pr_number":123,"overall_assessment":"fix-needed","findings":[1]}
JSON
run --pr-number 123 --review-file-path "$SANDBOX/p0-verif-jqfail.json" --conversation-decision none --p1-scan-turns 0 --p1-scan-found false
assert_rc 0 "p0 guard jq runtime failure -> exit 0 (fallback)"
assert_err_has "REVIEW_SOURCE_PARSE_FAILED=1; reason=explicit_file_verification_guard_jq_failed" "p0 jq 失敗は専用 reason"
assert_err_lacks "reason=explicit_file_verification_type_invalid" "p0 jq 失敗を型崩れ reason に融合しない"

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
# P0 の fallback pin と対称。否定条件だけでは routing 先が pr_comment 以外に変わっても通るため、
# schema SoT が定める「P2 の失敗モードはすべて Priority 3 へ」を positive に固定する
# (706/707/708/709 は同一の review_source 代入を共有するので 1 箇所で全体を pin できる)
assert_err_has "[CONTEXT] REVIEW_SOURCE=pr_comment;" "p2 type guard -> pr_comment (Priority 3 routing)"
if ls "$RR"/706-20260101000000.json.corrupt-* >/dev/null 2>&1; then
  pass "type-invalid file renamed to .corrupt-* (_rite_rename_corrupt_file 呼び出し元)"
else
  fail "type-invalid file NOT renamed (_rite_rename_corrupt_file 呼び出し元)"
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
assert_err_lacks "[CONTEXT] REVIEW_SOURCE=local_file;" "p2 multi-finding type invalid must not be accepted as local_file"

# 型ガードが invariant #2 より前段にあることを pin する (P0 の鏡像)。P2 では reason だけでなく
# .corrupt-{epoch} rename の有無も変わる — invariant #2 分岐は rename しないため、
# 順序が退行すると「同一 WARNING の無限 ring」を防ぐ rename が消える。
cat > "$RR/709-20260101000000.json" <<'JSON'
{"schema_version":"1.1.0","pr_number":709,"overall_assessment":"mergeable","findings":[{"file":"a.ts","line":1,"severity":"HIGH","status":"open","scope":"current-pr","verification":true}]}
JSON
run --pr-number 709 --review-file-path "$UNSET" --conversation-decision none --p1-scan-turns 1 --p1-scan-found false
assert_rc 0 "p2 guard-before-invariant2 -> exit 0 (pr_comment)"
assert_err_has "REVIEW_SOURCE_PARSE_FAILED=1; reason=local_file_verification_type_invalid" "p2 型ガードが invariant #2 より先に発火する"
assert_err_lacks "reason=local_file_cross_field_invariant_violated" "p2 invariant #2 は型ガードの後段に留まる"
if ls "$RR"/709-20260101000000.json.corrupt-* >/dev/null 2>&1; then
  pass "p2 順序が保たれているため rename も発火する"
else
  fail "p2 rename が発火していない (型ガードより invariant #2 が先行した疑い)"
fi

# jq 自体の失敗は型崩れと別 reason になり、かつ rename しない
# (破損が未証明のため破壊的操作を conflated signal で駆動しない)
cat > "$RR/710-20260101000000.json" <<'JSON'
{"schema_version":"1.1.0","pr_number":710,"overall_assessment":"fix-needed","findings":[1]}
JSON
run --pr-number 710 --review-file-path "$UNSET" --conversation-decision none --p1-scan-turns 1 --p1-scan-found false
assert_rc 0 "p2 guard jq runtime failure -> exit 0 (pr_comment)"
assert_err_has "REVIEW_SOURCE_PARSE_FAILED=1; reason=local_file_verification_guard_jq_failed" "p2 jq 失敗は専用 reason"
assert_err_lacks "reason=local_file_verification_type_invalid" "p2 jq 失敗を型崩れ reason に融合しない"
if ls "$RR"/710-20260101000000.json.corrupt-* >/dev/null 2>&1; then
  fail "p2 jq 失敗で rename してはいけない (破損未証明)"
else
  pass "p2 jq 失敗では rename しない"
fi

# measured:true の受理 (P0 の p0-verif-measured の鏡像)。述語が P0/P2 に literal 二重化されて
# いるため、read 側が measured==true を誤 reject する over-reach mutation を両側で pin する
cat > "$RR/711-20260101000000.json" <<'JSON'
{"schema_version":"1.1.0","pr_number":711,"overall_assessment":"fix-needed","findings":[{"file":"a.ts","line":1,"severity":"HIGH","status":"open","scope":"current-pr","verification":{"measured":true,"repro":"bash cmd => observed failure","failing_test":null}}]}
JSON
run --pr-number 711 --review-file-path "$UNSET" --conversation-decision none --p1-scan-turns 1 --p1-scan-found false
assert_rc 0 "p2 measured verification -> exit 0"
assert_err_has "[CONTEXT] REVIEW_SOURCE=local_file;" "p2 measured verification accepted"
assert_err_lacks "reason=local_file_verification_type_invalid" "p2 measured=true: type guard must not fire"

# 型ガードの**上側**境界 (required-fields チェックより後段) を pin する。下側 (invariant #2) だけを
# pin しても、ガードを required-fields の前へ移す退行を検出できない。findings が非配列 object の
# fixture では、正しい順序だと required-fields が先に弾いて rename するが、退行すると
# ガードの jq が rc=5 になり rename されなくなる (無限 ring 保護が消える)。
# 既存の 703 fixture ({"foo":"bar"}) は findings キー自体が無く `.findings[]?` が空生成になるため
# この差が出ず、上側境界を pin できない。
cat > "$RR/712-20260101000000.json" <<'JSON'
{"schema_version":"1.1.0","pr_number":712,"overall_assessment":"fix-needed","findings":{"a":1}}
JSON
run --pr-number 712 --review-file-path "$UNSET" --conversation-decision none --p1-scan-turns 1 --p1-scan-found false
assert_rc 0 "p2 guard-after-required-fields -> exit 0 (pr_comment)"
assert_err_has "REVIEW_SOURCE_PARSE_FAILED=1; reason=local_file_schema_required_fields_missing" "p2 required-fields が型ガードより先に発火する"
assert_err_lacks "reason=local_file_verification_guard_jq_failed" "p2 型ガードは required-fields の後段に留まる"
if ls "$RR"/712-20260101000000.json.corrupt-* >/dev/null 2>&1; then
  pass "p2 上側境界が保たれているため rename も発火する"
else
  fail "p2 rename が発火していない (型ガードが required-fields より先行した疑い)"
fi

# tempfile hygiene: 型ガードが通過する成功経路で jq stderr 退避ファイルが残らないこと。
# mktemp は elif の条件部で実行されるため、then に入らない成功経路では inline の rm に到達しない。
# cleanup trap への登録が外れると 1 実行 1 件のペースで TMPDIR に蓄積する。
# P0 と P2 は別々の変数 (vg_err_p0 / vg_err_p2) を使うため、片方だけを実行する pin では
# もう片方の登録漏れを検出できない。両経路を同一 TMPDIR で走らせ、glob も -p0- / -p2- を
# 個別に検査してどちら側が漏れたか判別できるようにする。
# 「残っていない」は「cleanup が働いた」だけでなく「ガードに到達していない」でも成立するため、
# 各実行で REVIEW_SOURCE marker を positive に固定してから不在を判定する (vacuous pass の排除)。
hyg_dir="$TEST_DIR/hygiene"; mkdir -p "$hyg_dir"
valid_json "$SANDBOX/hygiene-ok.json"
cat > "$RR/713-20260101000000.json" <<'JSON'
{"schema_version":"1.1.0","pr_number":713,"overall_assessment":"fix-needed","findings":[{"file":"a.ts","line":1,"severity":"HIGH","status":"open","scope":"current-pr","verification":{"measured":false,"repro":null,"failing_test":null}}]}
JSON
set +e
hyg_err_p0="$hyg_dir/run-p0.err"
(cd "$SANDBOX" && TMPDIR="$hyg_dir" bash "$TARGET" --pr-number 123 \
  --review-file-path "$SANDBOX/hygiene-ok.json" --conversation-decision none \
  --p1-scan-turns 0 --p1-scan-found false) >/dev/null 2>"$hyg_err_p0"
hyg_rc_p0=$?
hyg_err_p2="$hyg_dir/run-p2.err"
(cd "$SANDBOX" && TMPDIR="$hyg_dir" bash "$TARGET" --pr-number 713 \
  --review-file-path "$UNSET" --conversation-decision none \
  --p1-scan-turns 1 --p1-scan-found false) >/dev/null 2>"$hyg_err_p2"
hyg_rc_p2=$?
set -e
# positive control: 両 run が型ガードを通過して当該 Priority で解決したことを固定する
[ "$hyg_rc_p0" = 0 ] && pass "hygiene P0 run exited 0" || fail "hygiene P0 run exited $hyg_rc_p0"
grep -qF "[CONTEXT] REVIEW_SOURCE=explicit_file;" "$hyg_err_p0" \
  && pass "hygiene P0 run が型ガードを通過して explicit_file に解決した" \
  || fail "hygiene P0 run が explicit_file に到達していない (pin が vacuous)"
[ "$hyg_rc_p2" = 0 ] && pass "hygiene P2 run exited 0" || fail "hygiene P2 run exited $hyg_rc_p2"
grep -qF "[CONTEXT] REVIEW_SOURCE=local_file;" "$hyg_err_p2" \
  && pass "hygiene P2 run が型ガードを通過して local_file に解決した" \
  || fail "hygiene P2 run が local_file に到達していない (pin が vacuous)"
# 個別 glob で漏れた側を特定する
if ls "$hyg_dir"/rite-verif-guard-err-p0-* >/dev/null 2>&1; then
  fail "P0 成功経路で jq stderr tempfile が残存している ($(ls "$hyg_dir"/rite-verif-guard-err-p0-* | wc -l) 件)"
else
  pass "P0 成功経路で jq stderr tempfile が残らない"
fi
if ls "$hyg_dir"/rite-verif-guard-err-p2-* >/dev/null 2>&1; then
  fail "P2 成功経路で jq stderr tempfile が残存している ($(ls "$hyg_dir"/rite-verif-guard-err-p2-* | wc -l) 件)"
else
  pass "P2 成功経路で jq stderr tempfile が残らない"
fi

# -----------------------------------------------------------------
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
