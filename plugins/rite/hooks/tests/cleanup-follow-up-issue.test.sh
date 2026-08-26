#!/bin/bash
# cleanup-follow-up-issue.test.sh
#
# Behavioral tests for hooks/scripts/cleanup-follow-up-issue.sh
# (/rite:cleanup ステップ 6.0)。
#
# Coverage (Issue #2378 T-01..T-06 + D-03 lookup fail + caller coupling):
#   T-01/T-02 残存指摘ありで 1 件起票され、body に出典・finding 要点・marker が含まれる
#   T-03 起票 API 失敗で WARNING + exit 0 (cleanup を止めない)
#   T-04 0 件で起票なし
#   T-05 既存 marker があれば重複起票しない
#   T-06 JSON 不在で skip + WARNING
#   T-07 同定 API 失敗は起票せず WARNING (D-03)
#   T-08 cleanup SKILL.md が helper を archive より前に呼ぶ
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"

TARGET="$SCRIPT_DIR/../scripts/cleanup-follow-up-issue.sh"
[ -f "$TARGET" ] || { echo "FATAL: target not found: $TARGET" >&2; exit 1; }

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/rite-fu-test-XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT INT TERM HUP

OUT="$TMP_ROOT/out"; ERR="$TMP_ROOT/err"; RC=0
STUB_DIR="$TMP_ROOT/stub"
export STUB_DIR
mkdir -p "$STUB_DIR" "$TMP_ROOT/bin"
CREATE_STUB="$STUB_DIR/create-issue-with-projects.sh"
GH_BIN="$TMP_ROOT/bin/gh"

# $1=state_root remaining=extra helper args
run_target() {
  local root="$1"; shift
  PATH="$TMP_ROOT/bin:$PATH" \
    bash "$TARGET" \
      --state-root "$root" \
      --pr 9 \
      --owner acme \
      --repo demo \
      --source-issue 42 \
      --project-number 11 \
      --project-owner acme \
      --projects-enabled true \
      --create-script "$CREATE_STUB" \
      "$@" >"$OUT" 2>"$ERR"
  RC=$?
}

new_root() {
  local root="$TMP_ROOT/root-$1"
  mkdir -p "$root/.rite/review-results"
  printf '%s' "$root"
}

put_json() { printf '%s\n' "$3" > "$1/.rite/review-results/$2"; }

# gh shim: list / label create / issue comment
cat > "$GH_BIN" <<'GH'
#!/bin/bash
echo "gh $*" >> "${GH_LOG:-/dev/null}"
cmd="$*"
case "$cmd" in
  *"label create"*) exit 0 ;;
  *"issue list"*)
    if [ -n "${GH_LIST_RC:-}" ] && [ "${GH_LIST_RC}" != "0" ]; then
      echo "gh: simulated list failure" >&2
      exit "$GH_LIST_RC"
    fi
    cat "${GH_LIST_JSON:-/dev/null}"
    exit 0
    ;;
  *"issue comment"*)
    echo "gh $*" >> "${GH_COMMENT_LOG:-/dev/null}"
    exit "${GH_COMMENT_RC:-0}"
    ;;
esac
echo "unexpected gh: $*" >&2
exit 1
GH
chmod +x "$GH_BIN"

# create-issue stub: copies body, emits success JSON unless CREATE_RC set
cat > "$CREATE_STUB" <<'STUB'
#!/bin/bash
printf '%s\n' "$1" > "${STUB_DIR}/args.json"
body=$(printf '%s' "$1" | jq -r '.issue.body_file // empty')
if [ -n "$body" ] && [ -f "$body" ]; then
  cp "$body" "${STUB_DIR}/body.md"
fi
echo 1 >> "${STUB_DIR}/create_count"
if [ -n "${CREATE_RC:-}" ] && [ "$CREATE_RC" != "0" ]; then
  echo "create-issue: simulated failure" >&2
  exit "$CREATE_RC"
fi
printf '%s\n' '{"issue_url":"https://example.test/issues/99","issue_number":99,"project_id":"PVT_x","item_id":"PVTI_x","project_registration":"ok","warnings":[]}'
STUB
chmod +x "$CREATE_STUB"

reset_stubs() {
  rm -f "$STUB_DIR/args.json" "$STUB_DIR/body.md" "$STUB_DIR/create_count"
  : > "$STUB_DIR/create_count"
  export STUB_DIR
  export GH_LOG="$STUB_DIR/gh.log"
  export GH_COMMENT_LOG="$STUB_DIR/comment.log"
  export GH_LIST_JSON="$STUB_DIR/list.json"
  export GH_LIST_RC=0
  export GH_COMMENT_RC=0
  unset CREATE_RC
  printf '%s\n' '[]' > "$GH_LIST_JSON"
  : > "$GH_LOG"
  : > "$GH_COMMENT_LOG"
}

create_count() {
  if [ -f "$STUB_DIR/create_count" ]; then
    wc -l < "$STUB_DIR/create_count" | tr -d ' '
  else
    echo 0
  fi
}

FINDING_JSON='{"non_blocking_findings":[{"id":"F-01","reviewer":"code-quality-reviewer","severity":"LOW","file":"plugins/rite/skills/cleanup/SKILL.md","line":12,"description":"実測なしの指摘本文","suggestion":"別 PR で対応"}]}'

echo "--- T-01/T-02: 残存指摘ありで 1 件起票 + body 要点 ---"
reset_stubs
r=$(new_root t01)
put_json "$r" "9-20260101120000.json" "$FINDING_JSON"
run_target "$r"
assert "T-01 exit 0" "0" "$RC"
assert_grep "T-01 created marker" "$ERR" 'FOLLOW_UP_ISSUE=created; issue=99; pr=9'
assert "T-01 create 1 回" "1" "$(create_count)"
assert_grep "T-02 marker in body" "$STUB_DIR/body.md" '\[rite-follow-up-from-pr:9\]'
assert_grep "T-02 元 PR" "$STUB_DIR/body.md" '元 PR: #9'
assert_grep "T-02 元 Issue" "$STUB_DIR/body.md" '元 Issue: #42'
assert_grep "T-02 reviewer" "$STUB_DIR/body.md" 'code-quality-reviewer'
assert_grep "T-02 severity" "$STUB_DIR/body.md" 'LOW'
assert_grep "T-02 file:line" "$STUB_DIR/body.md" 'cleanup/SKILL.md:12'
assert_grep "T-02 description" "$STUB_DIR/body.md" '実測なしの指摘本文'
assert_grep "T-02 labels follow-up" "$STUB_DIR/args.json" '"follow-up"'
assert_grep "T-02 source cleanup" "$STUB_DIR/args.json" '"source": "cleanup"'
assert_grep "T-02 元 Issue へコメント" "$GH_COMMENT_LOG" 'issue comment 42'

echo "--- T-03: 起票 API 失敗は WARNING + exit 0 ---"
reset_stubs
export CREATE_RC=1
r=$(new_root t03)
put_json "$r" "9-a.json" "$FINDING_JSON"
run_target "$r"
assert "T-03 exit 0 (non-blocking)" "0" "$RC"
assert_grep "T-03 failed marker" "$ERR" 'FOLLOW_UP_ISSUE=failed; reason=create_api; pr=9'
assert_grep "T-03 WARNING" "$ERR" '起票に失敗'
unset CREATE_RC

echo "--- T-04: 0 件で起票なし ---"
reset_stubs
r=$(new_root t04)
put_json "$r" "9-empty.json" '{"non_blocking_findings":[]}'
run_target "$r"
assert "T-04 exit 0" "0" "$RC"
assert_grep "T-04 skipped no_findings" "$ERR" 'reason=no_findings; pr=9'
assert "T-04 create 0 回" "0" "$(create_count)"

echo "--- T-05: 既存 marker なら重複起票しない ---"
reset_stubs
printf '%s\n' '[{"number":50,"body":"<!-- [rite-follow-up-from-pr:9] -->\n既存"}]' > "$GH_LIST_JSON"
r=$(new_root t05)
put_json "$r" "9-a.json" "$FINDING_JSON"
run_target "$r"
assert "T-05 exit 0" "0" "$RC"
assert_grep "T-05 already_exists" "$ERR" 'reason=already_exists; issue=50; pr=9'
assert "T-05 create 0 回" "0" "$(create_count)"

echo "--- T-05b: PR 9 の marker は PR 90 と一致しない ---"
reset_stubs
printf '%s\n' '[{"number":51,"body":"<!-- [rite-follow-up-from-pr:90] -->"}]' > "$GH_LIST_JSON"
r=$(new_root t05b)
put_json "$r" "9-a.json" "$FINDING_JSON"
run_target "$r"
assert "T-05b prefix 非一致なら起票する" "1" "$(create_count)"

echo "--- T-06: JSON 不在で skip + WARNING ---"
reset_stubs
r=$(new_root t06)
run_target "$r"
assert "T-06 exit 0" "0" "$RC"
assert_grep "T-06 skipped no_json" "$ERR" 'reason=no_json; pr=9'
assert_grep "T-06 WARNING" "$ERR" 'レビュー結果 JSON が見つかりません'
assert "T-06 create 0 回" "0" "$(create_count)"

echo "--- T-07: 同定 API 失敗は起票しない ---"
reset_stubs
export GH_LIST_RC=1
r=$(new_root t07)
put_json "$r" "9-a.json" "$FINDING_JSON"
run_target "$r"
assert "T-07 exit 0" "0" "$RC"
assert_grep "T-07 lookup_api" "$ERR" 'reason=lookup_api; pr=9'
assert "T-07 create 0 回" "0" "$(create_count)"
unset GH_LIST_RC

echo "--- T-08: cleanup ステップ 6.0 が helper を archive より前に呼ぶ ---"
CLEANUP_MD="$SCRIPT_DIR/../../skills/cleanup/SKILL.md"
if [ ! -f "$CLEANUP_MD" ]; then
  fail "T-08 cleanup/SKILL.md が見つからない: $CLEANUP_MD"
else
  assert "T-08 helper 呼び出しが実行位置に 1 本" "1" \
    "$(grep -cE '^[[:space:]]*bash [^[:space:]]*hooks/scripts/cleanup-follow-up-issue\.sh' "$CLEANUP_MD" || true)"
  fu_line=$(grep -nE 'hooks/scripts/cleanup-follow-up-issue\.sh' "$CLEANUP_MD" | head -1 | cut -d: -f1)
  ar_line=$(grep -nE 'hooks/scripts/review-results-archive-or-rm\.sh' "$CLEANUP_MD" | head -1 | cut -d: -f1)
  if [ -n "$fu_line" ] && [ -n "$ar_line" ] && [ "$fu_line" -lt "$ar_line" ]; then
    pass "T-08 follow-up 呼び出しが archive より前"
  else
    fail "T-08 follow-up ($fu_line) が archive ($ar_line) より前に無い"
  fi
  assert "T-08 helper の rc を捕捉している" "1" \
    "$(grep -cF '|| _fu_rc=$?' "$CLEANUP_MD" || true)"
fi

echo "--- T-arg: 引数 gate ---"
bash "$TARGET" --pr abc --state-root "$TMP_ROOT" --owner a --repo b >"$OUT" 2>"$ERR"; RC=$?
assert "T-arg --pr 非数値は exit 1" "1" "$RC"
bash "$TARGET" --pr 9 --owner a --repo b >"$OUT" 2>"$ERR"; RC=$?
assert "T-arg --state-root 欠落は exit 1" "1" "$RC"
r=$(new_root targ)
run_target "$r" --bogus x
assert "T-arg 未知オプションは exit 1" "1" "$RC"

print_summary "cleanup-follow-up-issue.test.sh"
