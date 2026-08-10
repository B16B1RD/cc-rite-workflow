#!/bin/bash
# issue-comment-wm-update-merge-checklist.test.sh
#
# Pins the `merge-checklist` transform (archive-procedures
# §3.5.2 progress-merge delegation). Verifies:
#   - full-body exact-line dedup (idempotency / partial dedup)
#   - insertion at the end of the named section (before next `### ` / at EOF)
#   - section-absent + new items → exit 10 (SectionAbsentError; fail-loud, the governing rationale)
#   - real WM template heading `### 進捗サマリー` accepts the merge (AC-3)
#   - trailing-newline state of the input preserved
#   - missing --section → usage error (exit 1; AC-2 pin for required flag)
#
# The transform is a pure stdin→stdout text op (no gh API), so it is driven
# end-to-end here. run-tests.sh auto-discovers this file via the *.test.sh glob.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PY="$SCRIPT_DIR/../issue-comment-wm-update.py"
TEST_DIR="$(mktemp -d)"
PASS=0
FAIL=0

cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 is required but not installed" >&2
  exit 1
fi

# The standard 3 completion items the §3.5.2 caller merges into ### 進捗サマリー.
items_file="$TEST_DIR/items.txt"
printf '%s\n' "- [x] レビュー完了" "- [x] マージ完了" "- [x] クリーンアップ完了" > "$items_file"

echo "=== issue-comment-wm-update.py merge-checklist tests ==="
echo ""

# ─── TC-001: new items appended at end of section, existing preserved ────
echo "TC-001: append new items at end of 進捗 (before next ###), existing kept"
body1=$'## 📜 rite 作業メモリ\n\n### 進捗\n- [x] 実装完了\n- [x] PR マージ済み\n\n### 完了情報\n- **PR**: #1\n'
printf '%s' "$body1" | python3 "$PY" merge-checklist --section 進捗 --content-file "$items_file" > "$TEST_DIR/out1"

if grep -qxF -- "- [x] 実装完了" "$TEST_DIR/out1" && grep -qxF -- "- [x] PR マージ済み" "$TEST_DIR/out1"; then
  pass "TC-001a: existing 進捗 items preserved"
else
  fail "TC-001a: existing items lost"
fi

if grep -qxF -- "- [x] レビュー完了" "$TEST_DIR/out1" \
   && grep -qxF -- "- [x] マージ完了" "$TEST_DIR/out1" \
   && grep -qxF -- "- [x] クリーンアップ完了" "$TEST_DIR/out1"; then
  pass "TC-001b: 3 new completion items appended"
else
  fail "TC-001b: new items missing"
fi

item_ln=$(grep -nF -- "- [x] クリーンアップ完了" "$TEST_DIR/out1" | head -1 | cut -d: -f1 || true)
done_ln=$(grep -nF -- "### 完了情報" "$TEST_DIR/out1" | head -1 | cut -d: -f1 || true)
if [ -n "$item_ln" ] && [ -n "$done_ln" ] && [ "$item_ln" -lt "$done_ln" ]; then
  pass "TC-001c: new items inserted within 進捗 (before ### 完了情報)"
else
  fail "TC-001c: insertion position wrong (item=$item_ln, 完了情報=$done_ln)"
fi
echo ""

# ─── TC-002: idempotent — re-run is byte-identical ───────────────────────
echo "TC-002: idempotent re-run (byte-identical, no duplicates)"
python3 "$PY" merge-checklist --section 進捗 --content-file "$items_file" < "$TEST_DIR/out1" > "$TEST_DIR/out2"
dup_count=$(grep -cxF -- "- [x] レビュー完了" "$TEST_DIR/out2" || true)
if cmp -s "$TEST_DIR/out1" "$TEST_DIR/out2" && [ "$dup_count" = "1" ]; then
  pass "TC-002: re-run is a no-op (byte-identical, レビュー完了 count=1)"
else
  fail "TC-002: not idempotent (cmp differs or count=$dup_count)"
fi
echo ""

# ─── TC-003: partial dedup — only missing items appended ─────────────────
echo "TC-003: partial dedup (already-present item skipped)"
body3=$'## 📜 rite 作業メモリ\n\n### 進捗\n- [x] 実装完了\n- [x] レビュー完了\n\n### 次\n'
printf '%s' "$body3" | python3 "$PY" merge-checklist --section 進捗 --content-file "$items_file" > "$TEST_DIR/out3"
rev_count=$(grep -cxF -- "- [x] レビュー完了" "$TEST_DIR/out3" || true)
if [ "$rev_count" = "1" ] \
   && grep -qxF -- "- [x] マージ完了" "$TEST_DIR/out3" \
   && grep -qxF -- "- [x] クリーンアップ完了" "$TEST_DIR/out3"; then
  pass "TC-003: existing レビュー完了 not duplicated; other 2 appended"
else
  fail "TC-003: partial dedup wrong (レビュー完了 count=$rev_count)"
fi
echo ""

# ─── TC-004: section absent + new items → exit 10 (fail-loud, the governing rationale) ─
echo "TC-004: section absent → exit 10 (SectionAbsentError; items not silently dropped)"
body4=$'## 📜 rite 作業メモリ\n\n### 完了情報\n- **PR**: #1\n'
printf '%s' "$body4" > "$TEST_DIR/body4"
set +e
python3 "$PY" merge-checklist --section 進捗 --content-file "$items_file" \
  < "$TEST_DIR/body4" > "$TEST_DIR/out4" 2>"$TEST_DIR/err4"
rc4=$?
set -e
if [ "$rc4" -eq 10 ]; then
  pass "TC-004a: exit code 10 when section absent with new items"
else
  fail "TC-004a: expected exit 10, got $rc4"
fi
if grep -qF "section absent" "$TEST_DIR/err4"; then
  pass "TC-004b: stderr names section absent"
else
  fail "TC-004b: stderr missing section-absent detail ($(cat "$TEST_DIR/err4"))"
fi
# stdout must not carry a body that a caller could PATCH as "success"
if [ ! -s "$TEST_DIR/out4" ]; then
  pass "TC-004c: stdout empty (no body to PATCH)"
else
  fail "TC-004c: stdout non-empty despite section absent (would enable silent success PATCH)"
fi
echo ""

# ─── TC-005: section at EOF → items appended, trailing newline preserved ─
echo "TC-005: section at EOF → items appended, trailing newline preserved"
body5=$'## 📜 rite 作業メモリ\n\n### 進捗\n- [x] 実装完了\n'
printf '%s' "$body5" | python3 "$PY" merge-checklist --section 進捗 --content-file "$items_file" > "$TEST_DIR/out5"
if grep -qxF -- "- [x] クリーンアップ完了" "$TEST_DIR/out5"; then
  pass "TC-005a: items appended to EOF section"
else
  fail "TC-005a: items not appended at EOF"
fi
if [ -z "$(tail -c1 "$TEST_DIR/out5")" ]; then
  pass "TC-005b: trailing newline preserved"
else
  fail "TC-005b: trailing newline lost"
fi
echo ""

# ─── TC-006: empty content-file → body unchanged (no-op) ─────────────────
echo "TC-006: empty content-file → no-op"
: > "$TEST_DIR/empty.txt"
body6=$'## 📜 rite 作業メモリ\n\n### 進捗\n- [x] 実装完了\n'
printf '%s' "$body6" > "$TEST_DIR/body6"
python3 "$PY" merge-checklist --section 進捗 --content-file "$TEST_DIR/empty.txt" < "$TEST_DIR/body6" > "$TEST_DIR/out6"
if cmp -s "$TEST_DIR/body6" "$TEST_DIR/out6"; then
  pass "TC-006: body unchanged when content-file is empty"
else
  fail "TC-006: body changed despite empty content-file"
fi
echo ""

# ─── TC-007: input without trailing newline → output also lacks it ───────
echo "TC-007: no trailing newline preserved (negative branch of the newline guard)"
body7=$'## 📜 rite 作業メモリ\n\n### 進捗\n- [x] 実装完了'
printf '%s' "$body7" | python3 "$PY" merge-checklist --section 進捗 --content-file "$items_file" > "$TEST_DIR/out7"
if grep -qxF -- "- [x] クリーンアップ完了" "$TEST_DIR/out7"; then
  pass "TC-007a: items appended (EOF section, no trailing newline input)"
else
  fail "TC-007a: items not appended"
fi
if [ -n "$(tail -c1 "$TEST_DIR/out7")" ]; then
  pass "TC-007b: no trailing newline added when input had none"
else
  fail "TC-007b: a trailing newline was incorrectly added"
fi
echo ""

# ─── TC-008: multiple ### 進捗 sections → items go to the LAST block ──────
echo "TC-008: multiple 進捗 sections → insert at last block (verbatim with original)"
body8=$'## 📜 rite 作業メモリ\n\n### 進捗\n- [x] 古い進捗\n\n### 進捗\n- [x] 新しい進捗\n\n### 完了情報\n- x\n'
printf '%s' "$body8" | python3 "$PY" merge-checklist --section 進捗 --content-file "$items_file" > "$TEST_DIR/out8"
old_ln=$(grep -nF -- "- [x] 古い進捗" "$TEST_DIR/out8" | head -1 | cut -d: -f1 || true)
new_ln=$(grep -nF -- "- [x] 新しい進捗" "$TEST_DIR/out8" | head -1 | cut -d: -f1 || true)
item_ln8=$(grep -nF -- "- [x] レビュー完了" "$TEST_DIR/out8" | head -1 | cut -d: -f1 || true)
done_ln8=$(grep -nF -- "### 完了情報" "$TEST_DIR/out8" | head -1 | cut -d: -f1 || true)
# items must land after the SECOND (last) 進捗 block's content (after 新しい進捗) and before 完了情報,
# NOT immediately after the first block (古い進捗)
if [ -n "$item_ln8" ] && [ -n "$new_ln" ] && [ -n "$done_ln8" ] \
   && [ "$item_ln8" -gt "$new_ln" ] && [ "$item_ln8" -lt "$done_ln8" ]; then
  pass "TC-008: items inserted at last 進捗 block (after 新しい進捗, before 完了情報)"
else
  fail "TC-008: insertion at wrong 進捗 block (古い=$old_ln, 新しい=$new_ln, item=$item_ln8, 完了情報=$done_ln8)"
fi
echo ""

# ─── TC-009: real WM template ### 進捗サマリー → merge succeeds (AC-3) ───
echo "TC-009: real init template heading 進捗サマリー accepts merge (AC-3)"
body9=$'## 📜 rite 作業メモリ\n\n### 進捗サマリー\n\n| 項目 | 状態 | 備考 |\n|------|------|------|\n| 実装 | ✅ 完了 | - |\n| テスト | ✅ 完了 | - |\n| ドキュメント | ✅ 完了 | - |\n\n### 要確認事項\n_確認事項はありません_\n'
printf '%s' "$body9" | python3 "$PY" merge-checklist --section 進捗サマリー --content-file "$items_file" > "$TEST_DIR/out9"
if grep -qxF -- "- [x] レビュー完了" "$TEST_DIR/out9" \
   && grep -qxF -- "- [x] マージ完了" "$TEST_DIR/out9" \
   && grep -qxF -- "- [x] クリーンアップ完了" "$TEST_DIR/out9"; then
  pass "TC-009a: 3 items merged into 進捗サマリー"
else
  fail "TC-009a: items missing after 進捗サマリー merge"
fi
item_ln9=$(grep -nF -- "- [x] クリーンアップ完了" "$TEST_DIR/out9" | head -1 | cut -d: -f1 || true)
next_ln9=$(grep -nF -- "### 要確認事項" "$TEST_DIR/out9" | head -1 | cut -d: -f1 || true)
table_ln9=$(grep -nF -- "| ドキュメント |" "$TEST_DIR/out9" | head -1 | cut -d: -f1 || true)
if [ -n "$item_ln9" ] && [ -n "$next_ln9" ] && [ -n "$table_ln9" ] \
   && [ "$item_ln9" -gt "$table_ln9" ] && [ "$item_ln9" -lt "$next_ln9" ]; then
  pass "TC-009b: items after table, before next ### (within 進捗サマリー)"
else
  fail "TC-009b: insertion position wrong (table=$table_ln9, item=$item_ln9, next=$next_ln9)"
fi
echo ""

# ─── TC-010: missing --section → usage error exit 1 (AC-2 pin) ───────────
echo "TC-010: missing --section → exit 1 (usage error; example must include --section)"
body10=$'## 📜 rite 作業メモリ\n\n### 進捗サマリー\n\n| 項目 | 状態 |\n'
printf '%s' "$body10" > "$TEST_DIR/body10"
set +e
python3 "$PY" merge-checklist --content-file "$items_file" \
  < "$TEST_DIR/body10" > "$TEST_DIR/out10" 2>"$TEST_DIR/err10"
rc10=$?
set -e
if [ "$rc10" -eq 1 ]; then
  pass "TC-010a: exit 1 when --section omitted"
else
  fail "TC-010a: expected exit 1, got $rc10"
fi
if grep -qiE "section|required" "$TEST_DIR/err10"; then
  pass "TC-010b: stderr mentions --section requirement"
else
  fail "TC-010b: stderr missing section requirement ($(cat "$TEST_DIR/err10"))"
fi
echo ""

# ─── TC-011: section absent + all items already in body → exit 0 no-op ───
echo "TC-011: section absent but all items already present → idempotent exit 0"
body11=$'## 📜 rite 作業メモリ\n\n### 完了情報\n- [x] レビュー完了\n- [x] マージ完了\n- [x] クリーンアップ完了\n'
printf '%s' "$body11" > "$TEST_DIR/body11"
set +e
python3 "$PY" merge-checklist --section 進捗サマリー --content-file "$items_file" \
  < "$TEST_DIR/body11" > "$TEST_DIR/out11" 2>"$TEST_DIR/err11"
rc11=$?
set -e
if [ "$rc11" -eq 0 ] && cmp -s "$TEST_DIR/body11" "$TEST_DIR/out11"; then
  pass "TC-011: exit 0 + body unchanged when items already present (even without section)"
else
  fail "TC-011: expected exit 0 + unchanged body (rc=$rc11)"
fi
echo ""

echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
