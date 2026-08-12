#!/bin/bash
# shift2-loop-hardening.test.sh
#
# Regression tests for sibling helper の `shift 2` 無限ループ素因の横展開 hardening。
#
# wiki-lint-source-refs.sh に適用した `shift 2` → `shift; shift` 化を、同型脆弱性を
# 持つ全 sibling helper (hooks/scripts/ に留まらず hooks/ と scripts/ にも存在) へ横展開した。
#
# 脆弱性の成立条件 (3つ全て揃うと値なしフラグ末尾で無限ループ):
#   1. グローバル `set -e` がない (`shift 2` の rc=1 で exit しない)
#   2. 値代入が `"${2:-}"` (デフォルト展開 → `set -u` の nounset が発火しない)
#   3. `shift 2` 到達前に required-value ガードがない
# (1つでも欠ければ安全: set -u+bare $2 は nounset で fail-fast / set -e は即 exit / 明示ガードは exit)
#
# Coverage (hardening した脆弱だった 5 スクリプト 計 19 箇所 + 新規 helper 2 件 計 9 箇所):
#   TC-1 post-review-state-verify.sh (hooks/scripts/, 4 箇所) — 値なしフラグ末尾 → no-hang + exit 2
#   TC-2 review-comment-post.sh      (hooks/,         5 箇所) — 値なしフラグ末尾 → no-hang
#   TC-3 review-result-save.sh       (hooks/,         4 箇所) — 値なしフラグ末尾 → no-hang
#   TC-4 review-source-resolve.sh    (scripts/,       5 箇所) — 値なしフラグ末尾 → no-hang
#   TC-5 decompose-issues.sh         (scripts/,       1 箇所) — 値なしフラグ末尾 → no-hang + exit 2
#   TC-6 review-skip-notification.sh (hooks/,         4 箇所) — 値なしフラグ末尾 → no-hang (新規 helper、当初から shift; shift 採用)
#   TC-6b review-nonblocking-record.sh (hooks/,        5 箇所) — 値なしフラグ末尾 → no-hang + exit 1
#   TC-6c wiki-index-update.sh         (hooks/scripts/, 8 箇所) — 値なしフラグ末尾 → no-hang + exit 2
#   TC-6d review-cycle-scope.sh        (scripts/,       2 箇所) — 値なしフラグ末尾 → no-hang + exit 2
#   TC-6f issue-complexity-lane.sh     (scripts/,       2 箇所) — 値なしフラグ末尾 → no-hang + exit 2
#   TC-6e review-save-json-verify.sh   (hooks/scripts/, 4 箇所) — 値なしフラグ末尾 → no-hang + exit 0 (degraded)
#   TC-7 anti-pattern guard — 12 スクリプトに実 `shift 2` 文が残存しないこと (comment 参照は許容)
#        うち `lib/context-marker.sh` は source 型 lib で subprocess entry point を持たないため
#        TC-1〜TC-6b の実行ハーネス (run_no_hang) の対象外で、本静的検査のみが掛かる。
#        値なしフラグ末尾での no-hang は hooks/tests/context-marker.test.sh が直接 assert する。
#
# 各 TC は `timeout 5` で hang (exit 124) を検出する。値なしフラグはいずれも required value を
# 空にし、ループ完了後のローカル guard で exit する経路 (network/git に触れない) を選択している。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"

# 値なしフラグ末尾で no-hang を検証。expect_rc 非空ならその exit code も assert。
# 引数: <label> <plugin-relative script path> <値なしで末尾に置くフラグ> <expect_rc|"">
run_no_hang() {
  local label="$1" script="$2" flag="$3" expect_rc="$4"
  local path="$PLUGIN_ROOT/$script"
  if [ ! -f "$path" ]; then
    echo "ERROR: script not found: $path" >&2
    fail "$label (script not found)"
    return
  fi
  local rc=0
  _timeout 5 bash "$path" "$flag" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 124 ]; then
    fail "$label: 値なしフラグ '$flag' 末尾で timeout=124 (無限ループ検出 — shift 2 残存の可能性)"
  else
    pass "$label: 値なしフラグ '$flag' 末尾で no-hang (rc=$rc)"
  fi
  if [ -n "$expect_rc" ]; then
    assert "$label: exit $expect_rc (required-value guard 到達)" "$expect_rc" "$rc"
  fi
}

echo "=== TC-1〜TC-5: 値なしフラグ末尾の無限ループ耐性 ==="
run_no_hang "TC-1 post-review-state-verify" "hooks/scripts/post-review-state-verify.sh" "--original-branch" "2"
run_no_hang "TC-2 review-comment-post"      "hooks/review-comment-post.sh"             "--pr"              ""
run_no_hang "TC-3 review-result-save"       "hooks/review-result-save.sh"              "--pr"              ""
run_no_hang "TC-4 review-source-resolve"    "scripts/review-source-resolve.sh"         "--pr-number"       ""
run_no_hang "TC-5 decompose-issues"         "scripts/decompose-issues.sh"              "--spec"            "2"
run_no_hang "TC-6 review-skip-notification" "hooks/review-skip-notification.sh"         "--pr"              ""
run_no_hang "TC-6b review-nonblocking-record" "hooks/review-nonblocking-record.sh"       "--pr"              "1"
run_no_hang "TC-6c wiki-index-update"         "hooks/scripts/wiki-index-update.sh"       "--title"           "2"
run_no_hang "TC-6d review-cycle-scope"        "scripts/review-cycle-scope.sh"            "--pr"              "2"
run_no_hang "TC-6e review-save-json-verify"   "hooks/scripts/review-save-json-verify.sh" "--pr"              "0"
run_no_hang "TC-6f issue-complexity-lane"     "scripts/issue-complexity-lane.sh"         "--issue"           "2"

# === TC-7: anti-pattern guard — 実 `shift 2` 文が再混入していないこと ===
# comment 内の `shift 2` 参照 (backtick 囲み) は許容し、実際の statement だけを検出する。
# 実 statement は行頭 or `;` の直後に現れる: (^|;)<空白>*shift 2<空白/;/行末>。
echo "=== TC-7: anti-pattern guard (実 shift 2 文の不在) ==="
for script in \
  "hooks/scripts/post-review-state-verify.sh" \
  "hooks/review-comment-post.sh" \
  "hooks/review-result-save.sh" \
  "hooks/review-skip-notification.sh" \
  "hooks/review-nonblocking-record.sh" \
  "hooks/scripts/wiki-index-update.sh" \
  "scripts/review-source-resolve.sh" \
  "scripts/review-cycle-scope.sh" \
  "scripts/issue-complexity-lane.sh" \
  "hooks/scripts/review-save-json-verify.sh" \
  "hooks/scripts/lib/context-marker.sh" \
  "scripts/decompose-issues.sh"; do
  path="$PLUGIN_ROOT/$script"
  real_hits=$(grep -nE '(^|;)[[:space:]]*shift 2([[:space:]]|;|$)' "$path" || true)
  if [ -n "$real_hits" ]; then
    fail "TC-7 $(basename "$script"): 実 shift 2 文が残存"
    printf '%s\n' "$real_hits"
  else
    pass "TC-7 $(basename "$script"): 実 shift 2 文なし (comment 参照のみ)"
  fi
done

if ! print_summary "$(basename "$0")" \
  "drift: shift-2 loop hardening が後退した可能性。値付きフラグは set -e 非設定 + \${2:-} の下では \`shift; shift\` で消費しないと値なしフラグ末尾 (\$#=1) で無限ループに陥る。"; then
  exit 1
fi
