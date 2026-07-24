#!/bin/bash
# review-helpers-gate-behavior.test.sh
#
# Gate-behavior self-tests for the 3 review helpers:
#   - hooks/review-skip-notification.sh (pr-review.md ステップ 6.1.c)
#   - hooks/review-comment-post.sh      (pr-review.md ステップ 6.1.b)
#   - hooks/review-result-save.sh       (pr-review.md ステップ 6.1.a)
#
# shift2-loop-hardening.test.sh は shift-loop no-hang の 1 軸のみをカバーし、これらの helper の
# 中核 invariant である gate 分岐 (reason 語彙 / exit code / [CONTEXT] emit) には届かない。
# 本テストは各 gate を通過 / 遮断の両方向から検証してその invariant を guard する。
#
# Coverage:
#   TC-1 review-skip-notification.sh — post_comment_mode 3 分岐 / pr_number numeric gate /
#        file_timestamp 整合性 (unknown ∧ local_save_failed≠1 遮断) / local_save_failed 値検証 /
#        ケース 1 (INFO, exit 0) vs ケース 2 (p61c_persistence_unrecoverable, exit 2 hard-fail)
#   TC-2 review-comment-post.sh — post_comment_mode gate (false silent skip は gh 不実行まで検証) /
#        pr_number / json_saved / content-file / iso_timestamp の各 gate
#        (iso_timestamp は ISO 8601 allowlist — 非 ISO 形状 / awk metachar 注入形も reject) /
#        stub gh での happy path (Raw JSON 内 sentinel 置換 + Markdown 本文 sentinel 保存) /
#        gh 失敗時の gh_comment_post_failure emit
#   TC-3 review-result-save.sh — D-04 非ブロッキング契約 (gate 失敗でも exit 0 + EXIT trap が
#        FILE_TIMESTAMP / ISO_TIMESTAMP / JSON_SAVED を必ず emit) / --content-file 欠落 (exit 1) /
#        validation chain (required fields / findings id / scope enum / CRITICAL×nit-noted) /
#        happy path (JSON_SAVED=true + sentinel → ISO timestamp 置換)
#
# Network 非依存: gh は PATH 先頭の stub に差し替え、review-result-save は --results-dir で
# sandbox に隔離する (repo の .rite/ を汚さない)。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"

SENTINEL='__RITE_TS_PLACEHOLDER_7f3a9b2c__'

TMP_ROOT=$(mktemp -d) || { echo "ERROR: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP_ROOT"' EXIT

OUT="$TMP_ROOT/out"
ERR="$TMP_ROOT/err"

# --- 前提: 3 helper の存在 (rename / 削除 drift は環境エラーではなくテスト失敗として扱う) ---
for helper in \
  "hooks/review-skip-notification.sh" \
  "hooks/review-comment-post.sh" \
  "hooks/review-result-save.sh"; do
  if [ ! -f "$PLUGIN_ROOT/$helper" ]; then
    fail "precondition: $helper が存在しません (rename / 削除 drift)"
  fi
done
if [ "$FAIL" -ne 0 ]; then
  print_summary "$(basename "$0")"
  exit 1
fi

# --- stub gh (network 遮断 + 呼び出し観測) ---
# GH_STUB_LOG  : 呼び出し有無の観測 (silent skip 契約「gh pr comment を絶対に実行しない」の検証)
# GH_STUB_BODY : --body-file の内容 capture (sentinel 置換 post-condition の検証)
# GH_STUB_RC   : stub の exit code (gh_comment_post_failure 経路の再現)
STUB_DIR="$TMP_ROOT/stub-bin"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/gh" <<'EOF'
#!/bin/bash
[ -n "${GH_STUB_LOG:-}" ] && printf '%s\n' "$*" >> "$GH_STUB_LOG"
args=("$@")
i=0
while [ "$i" -lt "${#args[@]}" ]; do
  if [ "${args[$i]}" = "--body-file" ] && [ -n "${GH_STUB_BODY:-}" ]; then
    next=$((i + 1))
    [ "$next" -lt "${#args[@]}" ] && cp "${args[$next]}" "$GH_STUB_BODY"
  fi
  i=$((i + 1))
done
exit "${GH_STUB_RC:-0}"
EOF
chmod +x "$STUB_DIR/gh"
GH_LOG="$TMP_ROOT/gh-stub.log"
GH_BODY="$TMP_ROOT/gh-stub-body.md"

# --- 実行ヘルパー: rc を $RC に、stdout/stderr を $OUT/$ERR に capture ---
run_skip() {
  RC=0
  _timeout 10 bash "$PLUGIN_ROOT/hooks/review-skip-notification.sh" "$@" >"$OUT" 2>"$ERR" || RC=$?
}
run_post() {
  : > "$GH_LOG"
  RC=0
  PATH="$STUB_DIR:$PATH" GH_STUB_LOG="$GH_LOG" GH_STUB_BODY="$GH_BODY" GH_STUB_RC="${GH_STUB_RC:-0}" \
    _timeout 10 bash "$PLUGIN_ROOT/hooks/review-comment-post.sh" "$@" >"$OUT" 2>"$ERR" || RC=$?
}
run_save() {
  RC=0
  _timeout 10 bash "$PLUGIN_ROOT/hooks/review-result-save.sh" "$@" >"$OUT" 2>"$ERR" || RC=$?
}

# =====================================================================
echo "=== TC-1: review-skip-notification.sh (6.1.c) ==="
# =====================================================================

# TC-1.1 post_comment_mode=true は 6.1.b で完結すべき経路 → fail-fast
run_skip --post-comment-mode true --pr 123 --file-timestamp 20260101120000 --local-save-failed ""
assert "TC-1.1 post_comment_mode=true: exit 1" "1" "$RC"
assert_grep "TC-1.1 reason=p61c_post_comment_mode_invalid emit" "$ERR" 'REVIEW_OUTPUT_FAILED=1; reason=p61c_post_comment_mode_invalid'
assert_grep "TC-1.1 [review:error] を stdout に emit" "$OUT" '\[review:error\]'

# TC-1.2 post_comment_mode 不正値 (substitute 漏れ相当)
run_skip --post-comment-mode maybe --pr 123 --file-timestamp 20260101120000 --local-save-failed ""
assert "TC-1.2 post_comment_mode 不正値: exit 1" "1" "$RC"
assert_grep "TC-1.2 reason=p61c_post_comment_mode_invalid emit" "$ERR" 'REVIEW_OUTPUT_FAILED=1; reason=p61c_post_comment_mode_invalid'

# TC-1.3 pr_number gate: 空文字 / placeholder 残留 / 非数値
run_skip --post-comment-mode false --pr "" --file-timestamp 20260101120000 --local-save-failed ""
assert "TC-1.3a pr_number 空文字: exit 1" "1" "$RC"
assert_grep "TC-1.3a reason=p61c_pr_number_invalid emit" "$ERR" 'REVIEW_OUTPUT_FAILED=1; reason=p61c_pr_number_invalid'
run_skip --post-comment-mode false --pr "{pr_number}" --file-timestamp 20260101120000 --local-save-failed ""
assert "TC-1.3b pr_number placeholder 残留: exit 1" "1" "$RC"
assert_grep "TC-1.3b reason=p61c_pr_number_invalid emit" "$ERR" 'REVIEW_OUTPUT_FAILED=1; reason=p61c_pr_number_invalid'
run_skip --post-comment-mode false --pr "12a3" --file-timestamp 20260101120000 --local-save-failed ""
assert "TC-1.3c pr_number 非数値: exit 1" "1" "$RC"
assert_grep "TC-1.3c reason=p61c_pr_number_invalid emit" "$ERR" 'REVIEW_OUTPUT_FAILED=1; reason=p61c_pr_number_invalid'

# TC-1.4 file_timestamp placeholder 残留
run_skip --post-comment-mode false --pr 123 --file-timestamp "{file_timestamp}" --local-save-failed ""
assert "TC-1.4 file_timestamp placeholder 残留: exit 1" "1" "$RC"
assert_grep "TC-1.4 reason=p61c_file_timestamp_unset emit" "$ERR" 'REVIEW_OUTPUT_FAILED=1; reason=p61c_file_timestamp_unset'

# TC-1.5 整合性違反: unknown ∧ local_save_failed≠1 (単独 emit は観測値混線の兆候)
run_skip --post-comment-mode false --pr 123 --file-timestamp unknown --local-save-failed ""
assert "TC-1.5a unknown ∧ local_save_failed='': exit 1" "1" "$RC"
assert_grep "TC-1.5a reason=p61c_file_timestamp_unknown_without_failure emit" "$ERR" 'REVIEW_OUTPUT_FAILED=1; reason=p61c_file_timestamp_unknown_without_failure'
run_skip --post-comment-mode false --pr 123 --file-timestamp unknown --local-save-failed 0
assert "TC-1.5b unknown ∧ local_save_failed=0: exit 1" "1" "$RC"
assert_grep "TC-1.5b reason=p61c_file_timestamp_unknown_without_failure emit" "$ERR" 'REVIEW_OUTPUT_FAILED=1; reason=p61c_file_timestamp_unknown_without_failure'

# TC-1.6 local_save_failed 値検証 (許容: 空文字 / 0 / 1)
run_skip --post-comment-mode false --pr 123 --file-timestamp 20260101120000 --local-save-failed 2
assert "TC-1.6 local_save_failed=2: exit 1" "1" "$RC"
assert_grep "TC-1.6 reason=p61c_local_save_failed_invalid emit" "$ERR" 'REVIEW_OUTPUT_FAILED=1; reason=p61c_local_save_failed_invalid'

# TC-1.7 ケース 1 (通常経路): INFO + ローカルファイル path 表示 + exit 0
run_skip --post-comment-mode false --pr 123 --file-timestamp 20260101120000 --local-save-failed ""
assert "TC-1.7a ケース 1 (local_save_failed=''): exit 0" "0" "$RC"
assert_grep "TC-1.7a INFO にローカルファイル path を表示" "$ERR" '\.rite/review-results/123-20260101120000\.json'
assert_not_grep "TC-1.7a REVIEW_OUTPUT_FAILED を emit しない" "$ERR" 'REVIEW_OUTPUT_FAILED'
assert "TC-1.7a stdout は空 ([review:error] なし)" "" "$(cat "$OUT")"
run_skip --post-comment-mode false --pr 123 --file-timestamp 20260101120000 --local-save-failed 0
assert "TC-1.7b ケース 1 (local_save_failed=0): exit 0" "0" "$RC"

# TC-1.8 ケース 2 (silent data loss 防止の hard-fail): 最重要 invariant
run_skip --post-comment-mode false --pr 123 --file-timestamp unknown --local-save-failed 1
assert "TC-1.8a ケース 2 (unknown ∧ local_save_failed=1): exit 2" "2" "$RC"
assert_grep "TC-1.8a reason=p61c_persistence_unrecoverable emit" "$ERR" 'REVIEW_OUTPUT_FAILED=1; reason=p61c_persistence_unrecoverable'
assert_grep "TC-1.8a [review:error] を stdout に emit" "$OUT" '\[review:error\]'
assert_grep "TC-1.8a 復旧方法を案内 (fix 即時実行)" "$ERR" '/rite:fix'
# timestamp が正常値でも local_save_failed=1 ならケース 2 (分岐は LOCAL_SAVE_FAILED のみで決まる)
run_skip --post-comment-mode false --pr 123 --file-timestamp 20260101120000 --local-save-failed 1
assert "TC-1.8b ケース 2 (正常 timestamp ∧ local_save_failed=1): exit 2" "2" "$RC"
assert_grep "TC-1.8b reason=p61c_persistence_unrecoverable emit" "$ERR" 'REVIEW_OUTPUT_FAILED=1; reason=p61c_persistence_unrecoverable'

# =====================================================================
echo "=== TC-2: review-comment-post.sh (6.1.b) ==="
# =====================================================================

# 後続 gate 用のダミー content file (gate 順序検証で再利用)
DUMMY_CONTENT="$TMP_ROOT/dummy-content.md"
echo "dummy" > "$DUMMY_CONTENT"

# TC-2.1 post_comment_mode=false → silent skip (exit 0 + 出力なし + gh 不実行)
run_post --pr 123 --post-comment-mode false --json-saved true --iso-timestamp "2026-01-02T03:04:05+09:00" --content-file "$DUMMY_CONTENT"
assert "TC-2.1 post_comment_mode=false: exit 0" "0" "$RC"
assert "TC-2.1 stdout は空 (silent skip)" "" "$(cat "$OUT")"
assert "TC-2.1 stderr は空 (silent skip)" "" "$(cat "$ERR")"
if [ -s "$GH_LOG" ]; then
  fail "TC-2.1 gh pr comment を絶対に実行しない (stub gh が呼ばれた: $(head -1 "$GH_LOG"))"
else
  pass "TC-2.1 gh pr comment を絶対に実行しない"
fi

# TC-2.2 post_comment_mode 不正値
run_post --pr 123 --post-comment-mode maybe --json-saved true --iso-timestamp "2026-01-02T03:04:05+09:00" --content-file "$DUMMY_CONTENT"
assert "TC-2.2 post_comment_mode 不正値: exit 1" "1" "$RC"
assert_grep "TC-2.2 reason=p61b_post_comment_mode_invalid emit" "$ERR" 'REVIEW_OUTPUT_FAILED=1; reason=p61b_post_comment_mode_invalid'
assert_grep "TC-2.2 [review:error] を stdout に emit" "$OUT" '\[review:error\]'

# TC-2.3 pr_number gate: 空文字 / 非数値
run_post --pr "" --post-comment-mode true --json-saved true --iso-timestamp "2026-01-02T03:04:05+09:00" --content-file "$DUMMY_CONTENT"
assert "TC-2.3a pr_number 空文字: exit 1" "1" "$RC"
assert_grep "TC-2.3a reason=p61b_pr_number_invalid emit" "$ERR" 'REVIEW_OUTPUT_FAILED=1; reason=p61b_pr_number_invalid'
run_post --pr "{pr_number}" --post-comment-mode true --json-saved true --iso-timestamp "2026-01-02T03:04:05+09:00" --content-file "$DUMMY_CONTENT"
assert "TC-2.3b pr_number placeholder 残留: exit 1" "1" "$RC"
assert_grep "TC-2.3b reason=p61b_pr_number_invalid emit" "$ERR" 'REVIEW_OUTPUT_FAILED=1; reason=p61b_pr_number_invalid'

# TC-2.4 json_saved gate (6.1.a の JSON_SAVED emit の literal substitute 漏れ)
run_post --pr 123 --post-comment-mode true --json-saved "" --iso-timestamp "2026-01-02T03:04:05+09:00" --content-file "$DUMMY_CONTENT"
assert "TC-2.4 json_saved 空文字: exit 1" "1" "$RC"
assert_grep "TC-2.4 reason=json_saved_from_p61a_unset emit" "$ERR" 'REVIEW_OUTPUT_FAILED=1; reason=json_saved_from_p61a_unset'

# TC-2.5 content-file gate: 不在 path
run_post --pr 123 --post-comment-mode true --json-saved true --iso-timestamp "2026-01-02T03:04:05+09:00" --content-file "$TMP_ROOT/no-such-file.md"
assert "TC-2.5 content-file 不在: exit 1" "1" "$RC"
assert_grep "TC-2.5 reason=tmpfile_write_failure emit" "$ERR" 'REVIEW_OUTPUT_FAILED=1; reason=tmpfile_write_failure'

# TC-2.6 iso_timestamp gate: placeholder 残留 / 空文字 / sentinel そのもの
run_post --pr 123 --post-comment-mode true --json-saved true --iso-timestamp "{iso_timestamp}" --content-file "$DUMMY_CONTENT"
assert "TC-2.6a iso_timestamp placeholder 残留: exit 1" "1" "$RC"
assert_grep "TC-2.6a reason=iso_timestamp_from_p61a_unset emit" "$ERR" 'REVIEW_OUTPUT_FAILED=1; reason=iso_timestamp_from_p61a_unset'
run_post --pr 123 --post-comment-mode true --json-saved true --iso-timestamp "" --content-file "$DUMMY_CONTENT"
assert "TC-2.6b iso_timestamp 空文字: exit 1" "1" "$RC"
assert_grep "TC-2.6b reason=iso_timestamp_from_p61a_unset emit" "$ERR" 'REVIEW_OUTPUT_FAILED=1; reason=iso_timestamp_from_p61a_unset'
run_post --pr 123 --post-comment-mode true --json-saved true --iso-timestamp "$SENTINEL" --content-file "$DUMMY_CONTENT"
assert "TC-2.6c iso_timestamp が sentinel そのもの: exit 1" "1" "$RC"
assert_grep "TC-2.6c reason=iso_timestamp_from_p61a_unset emit" "$ERR" 'REVIEW_OUTPUT_FAILED=1; reason=iso_timestamp_from_p61a_unset'
# TC-2.6d ISO 8601 allowlist: 非 ISO 形状は旧 denylist 通過形でも reject
run_post --pr 123 --post-comment-mode true --json-saved true --iso-timestamp "not-a-timestamp" --content-file "$DUMMY_CONTENT"
assert "TC-2.6d iso_timestamp 非 ISO 形状: exit 1" "1" "$RC"
assert_grep "TC-2.6d reason=iso_timestamp_from_p61a_unset emit" "$ERR" 'REVIEW_OUTPUT_FAILED=1; reason=iso_timestamp_from_p61a_unset'
# TC-2.6e awk replacement metachar 注入形 (`&` / `\`) も allowlist が reject (gsub metachar 防御の第一層)
run_post --pr 123 --post-comment-mode true --json-saved true --iso-timestamp '2026-01-02T03:04:05+09:00&\evil' --content-file "$DUMMY_CONTENT"
assert "TC-2.6e iso_timestamp metachar 注入形: exit 1" "1" "$RC"
assert_grep "TC-2.6e reason=iso_timestamp_from_p61a_unset emit" "$ERR" 'REVIEW_OUTPUT_FAILED=1; reason=iso_timestamp_from_p61a_unset'
# TC-2.6f 複数行値 bypass 防止: grep -qE は行単位マッチのため 2 行目の valid ISO で素通りする (=~ の文字列全体 anchor を検証)
run_post --pr 123 --post-comment-mode true --json-saved true --iso-timestamp "$(printf 'garbage\n2026-01-02T03:04:05Z')" --content-file "$DUMMY_CONTENT"
assert "TC-2.6f iso_timestamp 複数行値: exit 1" "1" "$RC"
assert_grep "TC-2.6f reason=iso_timestamp_from_p61a_unset emit" "$ERR" 'REVIEW_OUTPUT_FAILED=1; reason=iso_timestamp_from_p61a_unset'
# TC-2.6g degraded 値 `unknown` (6.1.a EXIT trap の正規 emit) は専用診断で reject — 「emit 値を渡せ」の誤診断で再投入ループに誘導しない
run_post --pr 123 --post-comment-mode true --json-saved true --iso-timestamp "unknown" --content-file "$DUMMY_CONTENT"
assert "TC-2.6g iso_timestamp=unknown: exit 1" "1" "$RC"
assert_grep "TC-2.6g reason=iso_timestamp_from_p61a_unset emit" "$ERR" 'REVIEW_OUTPUT_FAILED=1; reason=iso_timestamp_from_p61a_unset'
assert_grep "TC-2.6g 専用診断 (degraded 値) を表示" "$ERR" "degraded 値 'unknown'"
assert_grep "TC-2.6g 再投入では解決しない旨を案内" "$ERR" '再投入では解決しません'

# TC-2.7 happy path: 全 gate 通過 + Raw JSON 内 sentinel のみ scope 限定置換
POST_CONTENT="$TMP_ROOT/post-content.md"
cat > "$POST_CONTENT" <<EOF
## レビュー結果

Markdown 本文の literal sentinel は保存される: $SENTINEL

### 📄 Raw JSON

\`\`\`json
{
  "schema_version": "1.1.0",
  "pr_number": 123,
  "timestamp": "$SENTINEL",
  "findings": []
}
\`\`\`
EOF
rm -f "$GH_BODY"
run_post --pr 123 --post-comment-mode true --json-saved true --iso-timestamp "2026-01-02T03:04:05+09:00" --content-file "$POST_CONTENT"
assert "TC-2.7 happy path: exit 0" "0" "$RC"
if [ -s "$GH_LOG" ]; then
  pass "TC-2.7 gh pr comment が実行された"
else
  fail "TC-2.7 gh pr comment が実行された (stub gh 未呼出)"
fi
assert_grep "TC-2.7 Raw JSON 内 sentinel が iso_timestamp に置換" "$GH_BODY" '"timestamp": "2026-01-02T03:04:05\+09:00"'
assert_not_grep "TC-2.7 Raw JSON 内に quoted sentinel が残留しない" "$GH_BODY" "\"$SENTINEL\""
assert_grep "TC-2.7 Markdown 本文の literal sentinel は保存 (post-condition b)" "$GH_BODY" "literal sentinel は保存される: $SENTINEL"

# TC-2.8 gh 失敗経路: gh_comment_post_failure emit + json_saved 併記
GH_STUB_RC=1 run_post --pr 123 --post-comment-mode true --json-saved true --iso-timestamp "2026-01-02T03:04:05+09:00" --content-file "$POST_CONTENT"
assert "TC-2.8 gh 失敗: exit 1" "1" "$RC"
assert_grep "TC-2.8 reason=gh_comment_post_failure emit" "$ERR" 'REVIEW_OUTPUT_FAILED=1; reason=gh_comment_post_failure'
assert_grep "TC-2.8 json_saved を併記 (fallback 判断材料)" "$ERR" 'json_saved=true'

# =====================================================================
echo "=== TC-3: review-result-save.sh (6.1.a, D-04 非ブロッキング契約) ==="
# =====================================================================

# TC-3.1 pr_number gate: 非ブロッキング (exit 0) + EXIT trap の必須 emit
run_save --pr "{pr_number}" --content-file "$TMP_ROOT/no-such.json" --results-dir "$TMP_ROOT/results-tc31"
assert "TC-3.1 pr_number placeholder 残留: exit 0 (非ブロッキング)" "0" "$RC"
assert_grep "TC-3.1 reason=pr_number_placeholder_residue emit" "$ERR" 'LOCAL_SAVE_FAILED=1; reason=pr_number_placeholder_residue'
assert_grep "TC-3.1 EXIT trap が FILE_TIMESTAMP=unknown を必ず emit" "$ERR" 'FILE_TIMESTAMP=unknown'
assert_grep "TC-3.1 EXIT trap が ISO_TIMESTAMP=unknown を必ず emit" "$ERR" 'ISO_TIMESTAMP=unknown'
assert_grep "TC-3.1 EXIT trap が JSON_SAVED=false を必ず emit" "$ERR" 'JSON_SAVED=false'

# TC-3.2 --content-file 引数欠落: caller bug の fail-fast (exit 1 を維持する documented 例外)
run_save --pr 123
assert "TC-3.2 --content-file 欠落: exit 1 (caller bug fail-fast)" "1" "$RC"

# TC-3.3 --content-file 不在 path: 非ブロッキング write_failure
run_save --pr 123 --content-file "$TMP_ROOT/no-such.json" --results-dir "$TMP_ROOT/results-tc33"
assert "TC-3.3 content-file 不在: exit 0 (非ブロッキング)" "0" "$RC"
assert_grep "TC-3.3 reason=write_failure emit" "$ERR" 'LOCAL_SAVE_FAILED=1; reason=write_failure'
assert_grep "TC-3.3 EXIT trap が JSON_SAVED=false を必ず emit" "$ERR" 'JSON_SAVED=false'

# TC-3.4 happy path: 保存成功 + sentinel → ISO timestamp 置換
RESULTS_TC34="$TMP_ROOT/results-tc34"
JSON_OK="$TMP_ROOT/json-ok.json"
cat > "$JSON_OK" <<EOF
{
  "schema_version": "1.1.0",
  "pr_number": 123,
  "timestamp": "$SENTINEL",
  "findings": []
}
EOF
run_save --pr 123 --content-file "$JSON_OK" --results-dir "$RESULTS_TC34"
assert "TC-3.4 happy path: exit 0" "0" "$RC"
assert_grep "TC-3.4 JSON_SAVED=true emit" "$ERR" 'JSON_SAVED=true'
assert_grep "TC-3.4 FILE_TIMESTAMP は YYYYMMDDHHMMSS 形式" "$ERR" 'FILE_TIMESTAMP=[0-9]{14}'
assert_not_grep "TC-3.4 LOCAL_SAVE_FAILED を emit しない" "$ERR" 'LOCAL_SAVE_FAILED'
saved_file=$(find "$RESULTS_TC34" -name '123-*.json' 2>/dev/null | head -1)
if [ -n "$saved_file" ] && [ -f "$saved_file" ]; then
  pass "TC-3.4 結果ファイルが results-dir に保存された"
  assert_not_grep "TC-3.4 保存 JSON に sentinel が残留しない" "$saved_file" "$SENTINEL"
  assert_grep "TC-3.4 保存 JSON の timestamp は ISO 8601 (+09:00)" "$saved_file" '"timestamp": "[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\+09:00"'
else
  fail "TC-3.4 結果ファイルが results-dir に保存された (123-*.json 不在)"
fi

# TC-3.5 必須フィールド欠落 (valid JSON だが schema_version / pr_number / findings なし)
JSON_NO_REQ="$TMP_ROOT/json-no-req.json"
printf '{"timestamp": "%s", "foo": 1}\n' "$SENTINEL" > "$JSON_NO_REQ"
run_save --pr 123 --content-file "$JSON_NO_REQ" --results-dir "$TMP_ROOT/results-tc35"
assert "TC-3.5 必須フィールド欠落: exit 0 (非ブロッキング)" "0" "$RC"
assert_grep "TC-3.5 reason=schema_required_fields_missing emit" "$ERR" 'LOCAL_SAVE_FAILED=1; reason=schema_required_fields_missing'

# TC-3.6 invalid JSON (jq timestamp 注入が parse 段階で fail → write_failure)
JSON_BROKEN="$TMP_ROOT/json-broken.json"
printf '{ broken json\n' > "$JSON_BROKEN"
run_save --pr 123 --content-file "$JSON_BROKEN" --results-dir "$TMP_ROOT/results-tc36"
assert "TC-3.6 invalid JSON: exit 0 (非ブロッキング)" "0" "$RC"
assert_grep "TC-3.6 reason=write_failure emit (注入段階で検出)" "$ERR" 'LOCAL_SAVE_FAILED=1; reason=write_failure'

# TC-3.7 findings[].id 書式違反 (F-1 は ^F-[0-9]{2,}$ に不一致)
JSON_BAD_ID="$TMP_ROOT/json-bad-id.json"
cat > "$JSON_BAD_ID" <<EOF
{
  "schema_version": "1.0.0",
  "pr_number": 123,
  "timestamp": "$SENTINEL",
  "findings": [{"id": "F-1"}]
}
EOF
run_save --pr 123 --content-file "$JSON_BAD_ID" --results-dir "$TMP_ROOT/results-tc37"
assert "TC-3.7 findings id 書式違反: exit 0 (非ブロッキング)" "0" "$RC"
assert_grep "TC-3.7 reason=finding_id_format_or_uniqueness_violation emit" "$ERR" 'LOCAL_SAVE_FAILED=1; reason=finding_id_format_or_uniqueness_violation'

# TC-3.8 findings[].id 重複 (書式は valid だが一意性違反)
JSON_DUP_ID="$TMP_ROOT/json-dup-id.json"
cat > "$JSON_DUP_ID" <<EOF
{
  "schema_version": "1.0.0",
  "pr_number": 123,
  "timestamp": "$SENTINEL",
  "findings": [{"id": "F-01"}, {"id": "F-01"}]
}
EOF
run_save --pr 123 --content-file "$JSON_DUP_ID" --results-dir "$TMP_ROOT/results-tc38"
assert "TC-3.8 findings id 重複: exit 0 (非ブロッキング)" "0" "$RC"
assert_grep "TC-3.8 reason=finding_id_format_or_uniqueness_violation emit" "$ERR" 'LOCAL_SAVE_FAILED=1; reason=finding_id_format_or_uniqueness_violation'

# TC-3.9 scope enum 違反 (schema 1.1.0 のみ検証される)
JSON_BAD_SCOPE="$TMP_ROOT/json-bad-scope.json"
cat > "$JSON_BAD_SCOPE" <<EOF
{
  "schema_version": "1.1.0",
  "pr_number": 123,
  "timestamp": "$SENTINEL",
  "findings": [{"id": "F-01", "scope": "bogus"}]
}
EOF
run_save --pr 123 --content-file "$JSON_BAD_SCOPE" --results-dir "$TMP_ROOT/results-tc39"
assert "TC-3.9 scope enum 違反: exit 0 (非ブロッキング)" "0" "$RC"
assert_grep "TC-3.9 reason=scope_enum_violation emit" "$ERR" 'LOCAL_SAVE_FAILED=1; reason=scope_enum_violation'

# TC-3.10 cross-field invariant #4: CRITICAL/HIGH × nit-noted の禁止
JSON_INV4="$TMP_ROOT/json-inv4.json"
cat > "$JSON_INV4" <<EOF
{
  "schema_version": "1.1.0",
  "pr_number": 123,
  "timestamp": "$SENTINEL",
  "findings": [{"id": "F-01", "severity": "CRITICAL", "scope": "nit-noted"}]
}
EOF
run_save --pr 123 --content-file "$JSON_INV4" --results-dir "$TMP_ROOT/results-tc310"
assert "TC-3.10 CRITICAL×nit-noted: exit 0 (非ブロッキング)" "0" "$RC"
assert_grep "TC-3.10 reason=critical_high_scope_nit_noted_invariant emit" "$ERR" 'LOCAL_SAVE_FAILED=1; reason=critical_high_scope_nit_noted_invariant'

if ! print_summary "$(basename "$0")" \
  "drift: review helper 3 件 (review-skip-notification / review-comment-post / review-result-save) の gate 分岐・reason 語彙・exit code 契約が変更された可能性。各 helper のヘッダ契約コメントと skills/pr-review/SKILL.md ステップ 6.1 を確認すること。"; then
  exit 1
fi
