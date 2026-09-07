#!/bin/bash
# cleanup-follow-up-issue.test.sh
#
# Behavioral tests for hooks/scripts/cleanup-follow-up-issue.sh
# (/rite:cleanup ステップ 6.0)。
#
# Coverage (T-01..T-06 + D-03 lookup fail + caller coupling):
#   T-01/T-02 残存指摘ありで 1 件起票され、body に出典・finding 要点・marker が含まれる
#             Projects status=Todo / enabled=true を args.json に pin
#   T-03 起票 API 失敗で WARNING + exit 0 (cleanup を止めない)
#   T-03g 最新が空でも先行 cycle の指摘が和集合で転記される
#   T-03u 一部 parse 不能でも健全側の和集合で起票する
#   T-03x 全 JSON が parse 不能なら json_undecidable
#   T-04 0 件で起票なし
#   T-05 既存 marker があれば重複起票しない
#   T-05c ラベル一覧に既存が居ない場合は起票する
#   T-05d 件数=limit かつ marker 不在は lookup_api
#   T-05e 説明欄へ他 PR の marker を植えても skip しない
#   T-05f body 2 行目の完全 HTML コメント marker では already_exists に倒さない
#   T-05g body 先頭行の裸 marker では already_exists に倒さない
#   T-05h body 先頭行の完全 HTML コメント marker + 後続テキストでは already_exists に倒さない
#   T-06 JSON 不在で skip + WARNING
#   T-07 同定 API 失敗は起票せず WARNING (D-03)
#   T-08 cleanup SKILL.md が helper を archive より前に呼ぶ
#   T-09 project-number 非数値は Projects skip + WARNING
#   T-10 project_registration=skipped は WARNING
#
# Coverage (T-01..T-05 = 本ファイルの T-11..T-15):
#   T-11 --exclude-ids で指定した finding だけが body から落ち、残りは全文が載る (AC-1)
#   T-12 全件除外は all_resolved で起票せず、gh issue list も叩かない (AC-2)
#   T-13 未知 id は WARNING のうえ既知 id の除外だけ適用して起票を続行する (AC-3)
#   T-14 --exclude-ids 未指定 / 空文字列は既存挙動と完全一致 (AC-4)
#   T-15 cleanup SKILL.md が再検証手順・3 値語彙・除外引数・和集合抽出を持つ (AC-5 / AC-6)
#
# Coverage (全 cycle 和集合、Issue 2593 の T-01..T-08):
#   T-17 2 本の JSON の指摘が和集合で body に載る + 本数の stderr 1 行 (AC-1)
#   T-18 同一 id でも別 cycle の指摘は畳まず全件載る (AC-2)
#   T-19 --exclude-ids は和集合後に適用される (AC-3)
#   T-20 和集合の全件除外は all_resolved (AC-4)
#   T-21 全 JSON が 0 件なら no_findings (AC-7 非回帰)
#   T-22 id 欠落 / 書式外 id の finding を落とさない (MUST NOT)
#   T-23 parse 不能な JSON を 1 本だけ除外し、jq の原因行と union 内訳を surface する
#   T-24 和集合内で衝突する id は --exclude-ids で除外せず WARNING + marker で surface する
#   T-24b 重複 id でも --exclude-ids が指していなければ曖昧扱いしない
#   T-24c 曖昧 id の素値は neutralize_ctrl を通してから WARNING に載せる
#   T-25 曖昧判定の失敗ハンドラは安全側へ倒し marker も出す
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
reg="${CREATE_REG:-ok}"
printf '%s\n' "{\"issue_url\":\"https://example.test/issues/99\",\"issue_number\":99,\"project_id\":\"PVT_x\",\"item_id\":\"PVTI_x\",\"project_registration\":\"${reg}\",\"warnings\":[]}"
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
  unset CREATE_REG
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
assert "T-02 body 先頭行は HTML コメント marker" "<!-- [rite-follow-up-from-pr:9] -->" "$(head -1 "$STUB_DIR/body.md")"
assert "T-02 body 2 行目 Type" "**Type**: fix" "$(sed -n '2p' "$STUB_DIR/body.md")"
assert "T-02 body 3 行目 Complexity" "**Complexity**: S" "$(sed -n '3p' "$STUB_DIR/body.md")"
assert "T-02 body 4 行目 空行" "" "$(sed -n '4p' "$STUB_DIR/body.md")"
assert "T-02 body 5 行目 概要" "## 概要" "$(sed -n '5p' "$STUB_DIR/body.md")"
_t01_extracted=$(sed -n 's/^[[:space:]]*\*\*Complexity\*\*:[[:space:]]*\([A-Za-z][A-Za-z]*\).*$/\1/p' "$STUB_DIR/body.md" | head -1)
assert "T-01 記法1 sed 抽出" "S" "$_t01_extracted"
_t01_args_complexity=$(jq -r '.projects.complexity' "$STUB_DIR/args.json")
assert "T-01 args.json complexity は抽出値と同一" "$_t01_extracted" "$_t01_args_complexity"
assert_grep "T-01 --arg complexity は _fu_complexity" "$TARGET" '[[:space:]]--arg complexity "\$_fu_complexity"'
assert_grep "T-01 --arg priority は _fu_priority" "$TARGET" '[[:space:]]--arg priority "\$_fu_priority"'
assert_grep "T-02 元 PR" "$STUB_DIR/body.md" '元 PR: #9'
assert_grep "T-02 元 Issue" "$STUB_DIR/body.md" '元 Issue: #42'
assert_grep "T-02 reviewer" "$STUB_DIR/body.md" 'code-quality-reviewer'
assert_grep "T-02 severity" "$STUB_DIR/body.md" 'LOW'
assert_grep "T-02 file:line" "$STUB_DIR/body.md" 'cleanup/SKILL.md:12'
assert_grep "T-02 description" "$STUB_DIR/body.md" '実測なしの指摘本文'
assert_grep "T-02 labels follow-up" "$STUB_DIR/args.json" '"follow-up"'
assert_grep "T-02 source cleanup" "$STUB_DIR/args.json" '"source": "cleanup"'
assert_grep "T-01 status Todo" "$STUB_DIR/args.json" '"status": "Todo"'
assert_grep "T-01 projects enabled true" "$STUB_DIR/args.json" '"enabled": true'
assert_grep "T-01 gh --label follow-up" "$GH_LOG" 'label follow-up'
assert_not_grep "T-01 gh は Search API を使わない" "$GH_LOG" 'rite-follow-up-from-pr'
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

echo "--- T-03g: 最新が空でも先行 cycle の指摘は和集合で転記される (AC-1) ---"
reset_stubs
r=$(new_root t03g)
put_json "$r" "9-20260101120000.json" "$FINDING_JSON"
put_json "$r" "9-20260102120000.json" '{"non_blocking_findings":[]}'
run_target "$r"
assert "T-03g exit 0" "0" "$RC"
assert_grep "T-03g created" "$ERR" 'FOLLOW_UP_ISSUE=created; issue=99; pr=9'
assert "T-03g create 1 回" "1" "$(create_count)"
assert_grep "T-03g 先行 cycle の finding が body に載る" "$STUB_DIR/body.md" '実測なしの指摘本文'

echo "--- T-03u: 一部 parse 不能でも健全側で起票する (AC-5) ---"
reset_stubs
r=$(new_root t03u)
put_json "$r" "9-20260101120000.json" "$FINDING_JSON"
put_json "$r" "9-20260102120000.json" 'not-json{'
run_target "$r"
assert "T-03u exit 0" "0" "$RC"
assert_grep "T-03u WARNING (和集合から除外)" "$ERR" '和集合から除外します'
assert_grep "T-03u created" "$ERR" 'FOLLOW_UP_ISSUE=created; issue=99; pr=9'
assert "T-03u create 1 回" "1" "$(create_count)"
assert_grep "T-03u 健全側の finding が body に載る" "$STUB_DIR/body.md" '実測なしの指摘本文'

echo "--- T-03x: 全 JSON が parse 不能なら json_undecidable ---"
reset_stubs
r=$(new_root t03x)
put_json "$r" "9-20260101120000.json" 'not-json{'
put_json "$r" "9-20260102120000.json" '{"non_blocking_findings":"abc"}'
run_target "$r"
assert "T-03x exit 0" "0" "$RC"
assert_grep "T-03x json_undecidable" "$ERR" 'reason=json_undecidable; pr=9'
assert "T-03x create 0 回" "0" "$(create_count)"

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

echo "--- T-05c: ラベル一覧に既存 marker が居なければ起票する ---"
reset_stubs
printf '%s\n' '[{"number":60,"body":"unrelated follow-up"}]' > "$GH_LIST_JSON"
r=$(new_root t05c)
put_json "$r" "9-a.json" "$FINDING_JSON"
run_target "$r"
assert "T-05c create 1 回" "1" "$(create_count)"
assert_grep "T-05c created" "$ERR" 'FOLLOW_UP_ISSUE=created; issue=99; pr=9'

echo "--- T-05d: 件数=limit かつ marker 不在は lookup_api ---"
reset_stubs
jq -n '[range(100) | {number: (1000+.), body: "no marker"}]' > "$GH_LIST_JSON"
r=$(new_root t05d)
put_json "$r" "9-a.json" "$FINDING_JSON"
run_target "$r"
assert "T-05d exit 0" "0" "$RC"
assert_grep "T-05d lookup_api" "$ERR" 'reason=lookup_api; pr=9'
assert_grep "T-05d limit WARNING" "$ERR" 'limit 100'
assert "T-05d create 0 回" "0" "$(create_count)"

echo "--- T-05e: 説明欄の他 PR marker では already_exists に倒さない ---"
reset_stubs
printf '%s\n' '[{"number":99,"body":"<!-- [rite-follow-up-from-pr:9] -->\n説明: [rite-follow-up-from-pr:123]"}]' > "$GH_LIST_JSON"
r=$(new_root t05e)
put_json "$r" "123-a.json" "$FINDING_JSON"
PATH="$TMP_ROOT/bin:$PATH" \
  bash "$TARGET" \
    --state-root "$r" \
    --pr 123 \
    --owner acme \
    --repo demo \
    --projects-enabled false \
    --create-script "$CREATE_STUB" >"$OUT" 2>"$ERR"
RC=$?
assert "T-05e exit 0" "0" "$RC"
assert "T-05e create 1 回" "1" "$(create_count)"
assert_grep "T-05e created for pr 123" "$ERR" 'FOLLOW_UP_ISSUE=created; issue=99; pr=123'
assert_not_grep "T-05e already_exists に倒さない" "$ERR" 'already_exists'

echo "--- T-05f: body 2 行目の完全 HTML コメント marker では already_exists に倒さない ---"
reset_stubs
printf '%s\n' '[{"number":99,"body":"概要\n<!-- [rite-follow-up-from-pr:123] -->"}]' > "$GH_LIST_JSON"
r=$(new_root t05f)
put_json "$r" "123-a.json" "$FINDING_JSON"
PATH="$TMP_ROOT/bin:$PATH" \
  bash "$TARGET" \
    --state-root "$r" \
    --pr 123 \
    --owner acme \
    --repo demo \
    --projects-enabled false \
    --create-script "$CREATE_STUB" >"$OUT" 2>"$ERR"
RC=$?
assert "T-05f exit 0" "0" "$RC"
assert "T-05f create 1 回" "1" "$(create_count)"
assert_grep "T-05f created for pr 123" "$ERR" 'FOLLOW_UP_ISSUE=created; issue=99; pr=123'
assert_not_grep "T-05f already_exists に倒さない" "$ERR" 'already_exists'

echo "--- T-05g: 先頭行の裸 marker では already_exists に倒さない ---"
reset_stubs
printf '%s\n' '[{"number":99,"body":"参照: [rite-follow-up-from-pr:123] を見よ"}]' > "$GH_LIST_JSON"
r=$(new_root t05g)
put_json "$r" "123-a.json" "$FINDING_JSON"
PATH="$TMP_ROOT/bin:$PATH" \
  bash "$TARGET" \
    --state-root "$r" \
    --pr 123 \
    --owner acme \
    --repo demo \
    --projects-enabled false \
    --create-script "$CREATE_STUB" >"$OUT" 2>"$ERR"
RC=$?
assert "T-05g exit 0" "0" "$RC"
assert "T-05g create 1 回" "1" "$(create_count)"
assert_grep "T-05g created for pr 123" "$ERR" 'FOLLOW_UP_ISSUE=created; issue=99; pr=123'
assert_not_grep "T-05g already_exists に倒さない" "$ERR" 'already_exists'

echo "--- T-05h: 先頭行の完全 HTML コメント marker + 後続テキストでは already_exists に倒さない ---"
reset_stubs
printf '%s\n' '[{"number":99,"body":"<!-- [rite-follow-up-from-pr:123] --> extra"}]' > "$GH_LIST_JSON"
r=$(new_root t05h)
put_json "$r" "123-a.json" "$FINDING_JSON"
PATH="$TMP_ROOT/bin:$PATH" \
  bash "$TARGET" \
    --state-root "$r" \
    --pr 123 \
    --owner acme \
    --repo demo \
    --projects-enabled false \
    --create-script "$CREATE_STUB" >"$OUT" 2>"$ERR"
RC=$?
assert "T-05h exit 0" "0" "$RC"
assert "T-05h create 1 回" "1" "$(create_count)"
assert_grep "T-05h created for pr 123" "$ERR" 'FOLLOW_UP_ISSUE=created; issue=99; pr=123'
assert_not_grep "T-05h already_exists に倒さない" "$ERR" 'already_exists'

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
  # archive 呼び出しは cleanup-pr-state-purge.sh へ抽出済み。SKILL.md 上の順序 pin は
  # 「follow-up 起票 → state purge helper」の並びで見る（archive は purge helper の中で走る）。
  # JSON が元の場所にあるうちに読む、という 6.0 の前提はこの並びが保つ。
  fu_line=$(grep -nE 'hooks/scripts/cleanup-follow-up-issue\.sh' "$CLEANUP_MD" | head -1 | cut -d: -f1)
  ar_line=$(grep -nE 'hooks/scripts/cleanup-pr-state-purge\.sh' "$CLEANUP_MD" | head -1 | cut -d: -f1)
  if [ -n "$fu_line" ] && [ -n "$ar_line" ] && [ "$fu_line" -lt "$ar_line" ]; then
    pass "T-08 follow-up 呼び出しが state purge (archive を含む) より前"
  else
    fail "T-08 follow-up ($fu_line) が state purge ($ar_line) より前に無い"
  fi
  assert "T-08 helper の rc を捕捉している" "1" \
    "$(grep -cF '|| _fu_rc=$?' "$CLEANUP_MD" || true)"
  assert_grep "T-08 owner_repo を slash split する" "$CLEANUP_MD" 'IFS=/ read -r _gh_owner _gh_repo <<< "\{owner_repo\}"'
  assert_grep "T-08 --owner は repo owner" "$CLEANUP_MD" 'owner "\$\{_gh_owner\}"'
  assert_grep "T-08 --project-owner は Projects owner" "$CLEANUP_MD" 'project-owner "\{owner\}"'
  assert_grep "T-08 project-number を引用する" "$CLEANUP_MD" 'project-number "\{project_number\}"'
  assert_grep "T-08 projects-enabled を引用する" "$CLEANUP_MD" 'projects-enabled "\{projects_enabled\}"'
  assert_grep "T-08 pr= の値は直後が ; または行末" "$CLEANUP_MD" 'pr=` の値は直後が `;` または行末であることまで含めて一致させる'
  assert_grep "T-08 recency 適用範囲は follow-up 側に限定" "$CLEANUP_MD" 'follow-up 側で同一 marker family の複数行が一致したときは最後の出現（recency）を採る'
  assert "T-08 recency 選択は follow-up 側に限定" "1" \
    "$(grep -cF 'この選択は**follow-up 側**の判定ルールを評価する前に行う' "$CLEANUP_MD" || true)"
fi

echo "--- T-09: project-number 非数値は Projects skip + WARNING ---"
reset_stubs
r=$(new_root t09)
put_json "$r" "9-a.json" "$FINDING_JSON"
PATH="$TMP_ROOT/bin:$PATH" \
  bash "$TARGET" \
    --state-root "$r" \
    --pr 9 \
    --owner acme \
    --repo demo \
    --project-number null \
    --projects-enabled true \
    --create-script "$CREATE_STUB" >"$OUT" 2>"$ERR"
RC=$?
assert "T-09 exit 0" "0" "$RC"
assert_grep "T-09 created" "$ERR" 'FOLLOW_UP_ISSUE=created; issue=99; pr=9'
assert_grep "T-09 project-number WARNING" "$ERR" '数値ではないため Projects 登録を skip'
assert_grep "T-09 projects enabled false" "$STUB_DIR/args.json" '"enabled": false'
assert_not_grep "T-09 enabled true を残さない" "$STUB_DIR/args.json" '"enabled": true'

echo "--- T-10: project_registration=skipped は WARNING ---"
reset_stubs
export CREATE_REG=skipped
r=$(new_root t10)
put_json "$r" "9-a.json" "$FINDING_JSON"
run_target "$r"
assert "T-10 exit 0" "0" "$RC"
assert_grep "T-10 created" "$ERR" 'FOLLOW_UP_ISSUE=created; issue=99; pr=9'
assert_grep "T-10 skipped WARNING" "$ERR" 'Projects 登録: skipped'
unset CREATE_REG

TWO_FINDING_JSON='{"non_blocking_findings":[{"id":"F-01","reviewer":"code-quality-reviewer","severity":"LOW","file":"a.md","line":3,"description":"残存する指摘の本文","suggestion":"残存する提案"},{"id":"F-05","reviewer":"tech-writer-reviewer","severity":"LOW","file":"b.md","line":9,"description":"解消済みの指摘の本文","suggestion":"解消済みの提案"}]}'

echo "--- T-11: 部分除外は除外 id だけを落とし残りは全文を載せる (AC-1) ---"
reset_stubs
r=$(new_root t11)
put_json "$r" "9-20260101120000.json" "$TWO_FINDING_JSON"
run_target "$r" --exclude-ids "F-05"
assert "T-11 exit 0" "0" "$RC"
assert_grep "T-11 created" "$ERR" 'FOLLOW_UP_ISSUE=created; issue=99; pr=9'
assert "T-11 create 1 回" "1" "$(create_count)"
# 件数一致では除外 id と残存 id の入れ替わりを検出できないため id と本文の present/absent で pin
assert_grep "T-11 残存 id が body にある" "$STUB_DIR/body.md" 'F-01'
assert_grep "T-11 残存 description が body にある" "$STUB_DIR/body.md" '残存する指摘の本文'
assert_grep "T-11 残存 suggestion が body にある" "$STUB_DIR/body.md" '残存する提案'
assert_not_grep "T-11 除外 id が body に無い" "$STUB_DIR/body.md" 'F-05'
assert_not_grep "T-11 除外 description が body に無い" "$STUB_DIR/body.md" '解消済みの指摘の本文'
assert_not_grep "T-11 除外 suggestion が body に無い" "$STUB_DIR/body.md" '解消済みの提案'
assert_not_grep "T-11 未知 id WARNING は出ない" "$ERR" '一致しない id'

echo "--- T-12: 全件除外は all_resolved で起票せず lookup も叩かない (AC-2) ---"
reset_stubs
r=$(new_root t12)
put_json "$r" "9-20260101120000.json" "$TWO_FINDING_JSON"
run_target "$r" --exclude-ids "F-01,F-05"
assert "T-12 exit 0" "0" "$RC"
assert_grep "T-12 all_resolved marker" "$ERR" 'FOLLOW_UP_ISSUE=skipped; reason=all_resolved; pr=9'
assert_grep "T-12 stdout summary も all_resolved" "$OUT" 'result=skipped; reason=all_resolved; pr=9'
assert "T-12 create 0 回" "0" "$(create_count)"
# 除外判定が already_exists lookup より前に立つことの観測条件 (全件除外ケース限定)
assert_not_grep "T-12 gh issue list を叩かない" "$GH_LOG" 'issue list'
assert_not_grep "T-12 no_findings には倒さない" "$ERR" 'reason=no_findings'

echo "--- T-13: 未知 id は WARNING + 既知分だけ除外して起票継続 (AC-3) ---"
reset_stubs
r=$(new_root t13)
put_json "$r" "9-20260101120000.json" "$TWO_FINDING_JSON"
run_target "$r" --exclude-ids "F-99,F-05"
assert "T-13 exit 0 (非ブロッキング)" "0" "$RC"
assert_grep "T-13 未知 id WARNING" "$ERR" '一致しない id が含まれます: F-99'
# WARNING の有無だけでは「未知 id で起票を止める実装」も通るため起票継続まで pin する
assert_grep "T-13 起票は継続する" "$ERR" 'FOLLOW_UP_ISSUE=created; issue=99; pr=9'
assert "T-13 create 1 回" "1" "$(create_count)"
assert_grep "T-13 既知 id の除外は効く" "$STUB_DIR/body.md" 'F-01'
assert_not_grep "T-13 除外した既知 id は body に無い" "$STUB_DIR/body.md" 'F-05'

echo "--- T-14: --exclude-ids 未指定 / 空文字列は既存挙動と一致 (AC-4) ---"
reset_stubs
r=$(new_root t14a)
put_json "$r" "9-20260101120000.json" "$TWO_FINDING_JSON"
run_target "$r"
assert "T-14 未指定 exit 0" "0" "$RC"
assert_grep "T-14 未指定は created" "$ERR" 'FOLLOW_UP_ISSUE=created; issue=99; pr=9'
assert_grep "T-14 未指定は F-01 を転記" "$STUB_DIR/body.md" 'F-01'
assert_grep "T-14 未指定は F-05 も転記" "$STUB_DIR/body.md" 'F-05'
_t14_default_body=$(cat "$STUB_DIR/body.md")

reset_stubs
r=$(new_root t14b)
put_json "$r" "9-20260101120000.json" "$TWO_FINDING_JSON"
run_target "$r" --exclude-ids ""
assert "T-14 空文字列 exit 0 (引数不正にしない)" "0" "$RC"
assert_grep "T-14 空文字列は created" "$ERR" 'FOLLOW_UP_ISSUE=created; issue=99; pr=9'
assert "T-14 空文字列の body は未指定と同一" "$_t14_default_body" "$(cat "$STUB_DIR/body.md")"
assert_not_grep "T-14 空文字列は all_resolved に倒さない" "$ERR" 'reason=all_resolved'

reset_stubs
r=$(new_root t14c)
put_json "$r" "9-20260101120000.json" '{"non_blocking_findings":[]}'
run_target "$r" --exclude-ids ""
assert "T-14 除外前 0 件は no_findings のまま" "0" "$RC"
assert_grep "T-14 no_findings を維持" "$ERR" 'reason=no_findings; pr=9'
assert_not_grep "T-14 除外前 0 件を all_resolved にしない" "$ERR" 'reason=all_resolved'

echo "--- T-15: cleanup SKILL.md の再検証契約 (AC-5 / AC-6) ---"
CLEANUP_MD="$SCRIPT_DIR/../../skills/cleanup/SKILL.md"
CLEANUP_RATIONALE="$SCRIPT_DIR/../../skills/cleanup/references/rationale.md"
if [ ! -f "$CLEANUP_MD" ]; then
  fail "T-15 cleanup/SKILL.md が見つからない: $CLEANUP_MD"
else
  # rationale.md の不在は assert_grep の file-not-found 分岐が fail-loud に捕まえる。
  # ここで elif guard を足すと、rationale.md が消えたときに SKILL.md 対象の兄弟 assert まで
  # まるごと skip され、診断粒度が落ちる
  # 判定結果はリテラル置換で helper へ渡す。シェル変数経由は Bash 呼び出し境界で失われるため、
  # `$_fu_exclude_ids` が復活していないことを両方向で pin する。
  assert_grep "T-15 helper へ --exclude-ids をリテラル置換で渡す" "$CLEANUP_MD" 'exclude-ids "\{resolved_ids_csv\}"'
  # 散文は禁止理由として名前に言及するため、pin はコード形 (引数渡し / 既定初期化) に絞る
  assert_not_grep "T-15 シェル変数経由の引数渡しを残さない" "$CLEANUP_MD" 'exclude-ids "\$_fu_exclude_ids"'
  assert_not_grep "T-15 既定初期化行を残さない" "$CLEANUP_MD" '_fu_exclude_ids="\$\{_fu_exclude_ids:-\}"'
  assert_grep "T-15 別 Bash 呼び出しである旨を明記" "$CLEANUP_MD" '別 Bash 呼び出しである'
  assert_grep "T-15 再検証節の見出し" "$CLEANUP_MD" '6\.0\.V helper 呼び出し前の再検証'
  # ERE の bare `|` は alternation となり `^` 単独の枝が全行にマッチする (常に PASS する
  # false positive)。Markdown テーブル行を pin するときは `\|` でエスケープする。
  assert_grep "T-15 3 値 resolved" "$CLEANUP_MD" '^\| `resolved` \|'
  assert_grep "T-15 3 値 remains" "$CLEANUP_MD" '^\| `remains` \|'
  assert_grep "T-15 3 値 undecidable" "$CLEANUP_MD" '^\| `undecidable` \|'
  assert_grep "T-15 undecidable は転記する" "$CLEANUP_MD" '\*\*転記する\*\*（`--exclude-ids` へ渡さない）'
  assert_grep "T-15 判定内訳 marker" "$CLEANUP_MD" 'FOLLOW_UP_REVERIFY=done; resolved='
  assert_grep "T-15 marker に resolved_ids を載せる" "$CLEANUP_MD" 'resolved_ids=\{resolved_ids_csv\}'
  assert_grep "T-15 再検証不能時は除外なしへ倒す" "$CLEANUP_MD" '全件を `undecidable` 扱い'
  # AC-6 (同型: 元 PR のマージコミット自身で修正済み) を resolved に落とす判定材料
  assert_grep "T-15 resolved の機械的判定材料" "$CLEANUP_MD" '既に修正後の形になっている'
  assert_grep "T-15 all_resolved を x 相当に置く" "$CLEANUP_MD" 'skipped; reason=all_resolved` \| x 相当'
  # 抽出は id 書式で絞る (書式外 id がリテラル置換先でコマンド置換として展開されるのを防ぐ)
  assert_grep "T-15 抽出 jq が id 書式で絞る" "$CLEANUP_MD" 'test\("\^F-\[0-9\]\{2,\}\$"\)'
  # 1 finding = 1 行の JSON で出す (TSV は description の改行で行が割れ id 対応が崩れる)
  assert_grep "T-15 抽出は 1 finding = 1 行の JSON" "$CLEANUP_MD" "jq -c '\.\[\]$"
  # 再検証も helper と同じ和集合を見る (最新 1 本だと転記集合と食い違う)
  assert_grep "T-15 再検証は全 JSON の和集合" "$CLEANUP_MD" '全ファイルの `non_blocking_findings\[\]` を和集合'
  assert_not_grep "T-15 id による畳み込みを残さない" "$CLEANUP_MD" 'group_by\(\.id\)'
  # jq リテラルの pin だけでは「その挙動を指示する散文」の drift を検出できない
  assert_not_grep "T-15 畳み込みを指示する散文を残さない" "$CLEANUP_MD" '同一 id は後の JSON'
  assert_grep "T-15 重複 id は独立に判定する旨を書く" "$CLEANUP_MD" '同じ id が複数行\*\*現れることがある'
  # 射影失敗と parse 失敗は別 reason (完了報告へ誤った原因を転記しない)
  assert_grep "T-15 射影失敗を WARNING で surface" "$CLEANUP_MD" '再検証用 JSON の射影に失敗しました'
  assert_grep "T-15 射影失敗は projection_failed" "$CLEANUP_MD" 'reason=projection_failed'
  assert "T-15 parse_failed は全滅経路のみ" "1" \
    "$(grep -c 'FOLLOW_UP_REVERIFY=unavailable; reason=parse_failed' "$CLEANUP_MD" | tr -d ' ')"
  # 6.0.V の統合 jq も stderr を捨てない（helper 側の union ループと同形）。
  # パターンは**単引用符**で書く — 二重引用符だと `\$` がシェル段階で `$` へ潰れ、ERE の
  # 中間アンカーになって決して一致しない（= 空振りする negative pin になる）。
  assert_not_grep "T-15 統合 jq の stderr を捨てない" "$CLEANUP_MD" 'argjson add "\$_part" .\. \+ \$add. "\$_rv_union" 2>/dev/null'
  # read 側の id 述語も末尾改行を排除する（write 側 gate と同一述語を保つ invariant）
  assert "T-15 射影 id 述語は末尾改行も排除する" "1" \
    "$(grep -c 'test("\^F-\[0-9\]{2,}\$") and (contains("\\n") | not)' "$CLEANUP_MD" | tr -d ' ')"
  # ループ本体での原因行 emit。既出 2 箇所に一致するため区間を限って pin する
  # 件数だけでは「ループ外へ移設」を素通しするため、for 〜 done の区間に限って pin する
  assert "T-15 ループ本体で原因行を emit する" "1" \
    "$(awk '/^      for f in "\$\{_rv_srcs\[@\]\}"/,/^      done$/' "$CLEANUP_MD" | grep -c 'head -5 "\$_rv_errf"' | tr -d ' ')"
  # 追記オープンにすると過去周の残骸が混ざり、毎周トランケート前提の emit 位置が意味を失う
  assert_not_grep "T-15 errf を追記で開かない" "$CLEANUP_MD" '2>>"\$\{_rv_errf'
  # 無効な明示トランケートを残さない（2> が毎周 O_TRUNC で開くため冗長）
  assert_not_grep "T-15 冗長な明示トランケートを残さない" "$CLEANUP_MD" '\[ -n "\$_rv_errf" \] && : > "\$_rv_errf"'
  # 曖昧 id marker に完了報告側の消費規則がある
  assert_grep "T-15 曖昧 id marker の消費規則がある" "$CLEANUP_MD" 'FOLLOW_UP_EXCLUDE_AMBIGUOUS=1; count=\{n\}; pr=\{pr_number\}'
  # placeholder の presence だけだと定義側 bullet で充足し、完了報告への配線を消す変異を素通しする
  assert_grep "T-15 完了報告に曖昧 note を差し込む" "$CLEANUP_MD" '\{follow_up_reverify_note\}\{follow_up_ambiguous_note\}'
  # note のリテラルは 1 本の code span に保つ（分断すると出力すべき文字列が不定になる）
  assert_not_grep "T-15 note リテラルに別 placeholder 名を埋めない" "$CLEANUP_MD" '曖昧 id \{count\}.*`\{follow_up_reverify_note\}`'
  assert_grep "T-15 和集合は連結のみ" "$CLEANUP_MD" 'argjson add "\$_part" .\. \+ \$add.'
  assert_grep "T-15 最終射影の rc を検査する" "$CLEANUP_MD" 'if _rv_out=\$\(jq -c'
  assert_not_grep "T-15 最新 1 本を選ぶループを残さない" "$CLEANUP_MD" '_rv_src="\$f"; _rv_base="\$b"'
  # reason 語彙を helper に揃える (合成 reason は誤った原因を完了報告へ転記する)
  assert_grep "T-15 reason=state_root_unresolved" "$CLEANUP_MD" 'reason=state_root_unresolved'
  assert_grep "T-15 reason=jq_missing" "$CLEANUP_MD" 'FOLLOW_UP_REVERIFY=unavailable; reason=jq_missing'
  assert_grep "T-15 reason=no_json" "$CLEANUP_MD" 'FOLLOW_UP_REVERIFY=unavailable; reason=no_json"'
  # 合成 reason の emit を残さない (散文は禁止理由として語に言及するため emit 形で pin)
  assert_not_grep "T-15 合成 reason を emit しない" "$CLEANUP_MD" 'reason=no_json_or_jq'
  # state root 解決失敗を無言にしない。文言の後半まで pin する — 接頭辞だけだと隣接ブロックの
  # 同一文字列に一致するうえ、旧文言 (cwd をフォールバック使用します) へ revert しても通る
  assert_grep "T-15 state root 解決失敗を WARNING で surface" "$CLEANUP_MD" \
    'state-path-resolve.sh の解決に失敗。follow-up 再検証は行わず全件を転記対象とします'
  # 書式外 id は落とさず null へ写す (落とすと件数を数える第 2 の述語が要り drift 経路になる)
  assert_grep "T-15 書式外 id を null へ写す" "$CLEANUP_MD" 'then \.id else null end'
  # 極性まで pin する (キーだけだと「必ず resolved」への反転が通る)
  assert_grep "T-15 id null は undecidable 固定" "$CLEANUP_MD" '`"id": null` の finding.*\*\*必ず `undecidable`\*\*'
  assert_not_grep "T-15 件数カウント機構を残さない" "$CLEANUP_MD" 'dropped_id_format'
  # 抽出成功時は marker を出さない。判定後の done が唯一の成功 marker (0 件時に抽出 marker が
  # 最後に残ると判定表が「未完了」と誤報告し、done の前置詞として前方一致でも衝突する)
  assert_not_grep "T-15 抽出成功 marker を残さない" "$CLEANUP_MD" 'FOLLOW_UP_REVERIFY=done_extract'
  assert_grep "T-15 0 件でも done を必ず出す" "$CLEANUP_MD" '抽出結果が 0 件でもこの marker を必ず出す'
  assert_grep "T-15 unavailable 経路では done を出さない" "$CLEANUP_MD" '既に `unavailable` を出した経路では `done` を出さない'
  # 判定表の 3 行を pin する (emit 側の pin だけでは表から行を削る変異が生存する)
  # 件数内訳まで pin する (「解消済み」で切ると内訳を削る変異が生存する)
  assert_grep "T-15 判定表の done 行" "$CLEANUP_MD" '`done` のとき: .*follow-up 再検証: 解消済み \{n_resolved\} / 残存 \{n_remains\} / 判定不能 \{n_undecidable\}'
  # 廃止 marker の設計理由は rationale へ退避し 1 行ポインタを張る
  assert_grep "T-15 抽出 marker 廃止の rationale ポインタ" "$CLEANUP_MD" 'rationale: references/rationale.md#reverify-no-extract-marker'
  assert_grep "T-15 rationale 節が実在する" "$CLEANUP_RATIONALE" '^## reverify-no-extract-marker$'
  assert_grep "T-15 判定表の unavailable 行" "$CLEANUP_MD" '`unavailable` のとき: .*follow-up 再検証: 未実施'
  # marker 不在は成功と読まない (兄弟分岐と同じ fail-loud 規約。空文字列に戻す変異を検出する)
  assert_grep "T-15 marker 不在も付記する" "$CLEANUP_MD" 'marker が無いとき: .*実施結果を確認できませんでした'
  assert_grep "T-15 marker 不在を成功と読まない" "$CLEANUP_MD" '\*\*marker 不在を成功と読んではならない\*\*'
  # 新設 stderr 経路の regression proof。捕捉先と surface の両側を pin する
  # (surface 側だけだと、捕捉先を /dev/null へ切る変異が生存して本文が永久に出なくなる)
  assert_grep "T-15 jq の stderr を _rv_errf へ捕捉する" "$CLEANUP_MD" '2>"\$\{_rv_errf:-/dev/null\}"'
  assert_grep "T-15 parse_failed で jq の stderr 本文を surface" "$CLEANUP_MD" 'head -5 "\$_rv_errf"'
  assert_grep "T-15 mktemp 失敗を surface" "$CLEANUP_MD" '一時ファイルを確保できません'
  # rc を汚さない形 (`&&` 単独文だと mktemp 失敗時にブロック全体が rc=1 で終わる)
  assert_grep "T-15 cleanup は if 形で rc を汚さない" "$CLEANUP_MD" 'if \[ -n "\$_rv_errf" \]; then rm -f "\$_rv_errf"; fi'
  # `\s` は GNU 拡張で BSD の ERE では未定義に落ち negative assert が fail-open する
  assert_not_grep "T-15 rm を && 単独文にしない" "$CLEANUP_MD" '^[[:space:]]*\[ -n "\$_rv_errf" \] && rm -f'
  # 0 件時に空行を出さない (空行が finding として読まれる余地を残さない)
  assert_grep "T-15 非空時だけ出力する" "$CLEANUP_MD" 'if \[ -n "\$_rv_out" \]; then printf'
  # 射影フィルタは 1 パス。grep -c は行数しか数えないため出現回数で数える
  assert "T-15 射影フィルタは 1 パス" "1" \
    "$(grep -o 'file, line, description, suggestion}' "$CLEANUP_MD" | wc -l | tr -d ' ')"
  # id 書式 regex も 1 箇所 (射影用と否定形で分裂すると片方だけ広げた時に乖離する)
  assert "T-15 id 書式 regex は 1 箇所" "1" \
    "$(grep -o 'test("\^F-\[0-9\]{2,}\$")' "$CLEANUP_MD" | wc -l | tr -d ' ')"
fi

echo "--- T-16: 改行入り --exclude-ids でも未知 id WARNING が消えない (AC-3) ---"
reset_stubs
r=$(new_root t16)
put_json "$r" "9-20260101120000.json" "$TWO_FINDING_JSON"
# jq -R は行単位処理のため、改行入りは JSON 配列が複数連結された文字列になる。
# 非空判定だけを通すと後段の --argjson が rc=2 で落ち、AC-3 の WARNING が無言で消える。
run_target "$r" --exclude-ids "$(printf 'F-99\nF-05')"
assert "T-16 exit 0" "0" "$RC"
# 改行も区切りとして畳むため AC-3 の未知 id WARNING がそのまま成立する
assert_grep "T-16 未知 id WARNING が消えない" "$ERR" '一致しない id が含まれます: F-99'
assert_grep "T-16 起票は継続する" "$ERR" 'FOLLOW_UP_ISSUE=created; issue=99; pr=9'
# 既知 id の除外も効く (無言の全件転記にならない)
assert_grep "T-16 残存 id を転記" "$STUB_DIR/body.md" 'F-01'
assert_not_grep "T-16 除外した既知 id は body に無い" "$STUB_DIR/body.md" 'F-05'

echo "--- T-17: 2 本の JSON の指摘が和集合で body に載る (AC-1 / T-01) ---"
reset_stubs
r=$(new_root t17)
put_json "$r" "9-20260101120000.json" '{"non_blocking_findings":[{"id":"F-05","reviewer":"a","severity":"LOW","file":"a.md","line":1,"description":"先行 cycle の指摘","suggestion":"先行の提案"},{"id":"F-09","reviewer":"a","severity":"LOW","file":"a.md","line":2,"description":"先行 cycle の指摘 2","suggestion":"先行の提案 2"}]}'
put_json "$r" "9-20260102120000.json" '{"non_blocking_findings":[{"id":"F-11","reviewer":"b","severity":"LOW","file":"b.md","line":3,"description":"後続 cycle の指摘","suggestion":"後続の提案"}]}'
run_target "$r"
assert "T-17 exit 0" "0" "$RC"
assert_grep "T-17 created" "$ERR" 'FOLLOW_UP_ISSUE=created; issue=99; pr=9'
assert_grep "T-17 F-05 が載る" "$STUB_DIR/body.md" '先行 cycle の指摘'
assert_grep "T-17 F-09 が載る" "$STUB_DIR/body.md" '先行 cycle の指摘 2'
assert_grep "T-17 F-11 が載る" "$STUB_DIR/body.md" '後続 cycle の指摘'
# SHOULD: どの範囲から転記したかを 1 行で出す
assert_grep "T-17 和集合の本数を stderr へ出す" "$ERR" 'union: pr=9; json_total=2; json_parsed=2; json_unparsed=0'

echo "--- T-18: 同一 id でも別 cycle の指摘は畳まず全件載る (AC-2) ---"
# `id` は各 JSON 内の連番であり cycle を跨いだ identity を持たない (cycle 跨ぎの identity は
# cycle 間の同一性判断は semantic 判断が担い、本配列に機械的 identity キーは無い)。
# 同じ `F-05` が cycle ごとに別の指摘を指すため、
# id で畳むと別々の指摘が黙って消える。よって両方が body に載るのが正しい。
reset_stubs
r=$(new_root t18)
put_json "$r" "9-20260101120000.json" '{"non_blocking_findings":[{"id":"F-05","reviewer":"a","severity":"LOW","file":"a.md","line":1,"description":"古い cycle の本文","suggestion":"古い提案"}]}'
put_json "$r" "9-20260102120000.json" '{"non_blocking_findings":[{"id":"F-05","reviewer":"b","severity":"LOW","file":"b.md","line":7,"description":"新しい cycle の本文","suggestion":"新しい提案"}]}'
run_target "$r"
assert "T-18 exit 0" "0" "$RC"
assert "T-18 F-05 の見出しは 2 回出る (別々の指摘)" "2" \
  "$(grep -c '^### F-05 ' "$STUB_DIR/body.md" | tr -d ' ')"
assert_grep "T-18 後の JSON の本文が載る" "$STUB_DIR/body.md" '新しい cycle の本文'
assert_grep "T-18 先行 JSON の本文も落とさない" "$STUB_DIR/body.md" '古い cycle の本文'

echo "--- T-19: --exclude-ids は和集合後に適用される (AC-3) ---"
reset_stubs
r=$(new_root t19)
put_json "$r" "9-20260101120000.json" '{"non_blocking_findings":[{"id":"F-01","reviewer":"a","severity":"LOW","file":"a.md","line":1,"description":"残す指摘 1","suggestion":"s1"},{"id":"F-02","reviewer":"a","severity":"LOW","file":"a.md","line":2,"description":"消す指摘 2","suggestion":"s2"}]}'
put_json "$r" "9-20260102120000.json" '{"non_blocking_findings":[{"id":"F-03","reviewer":"b","severity":"LOW","file":"b.md","line":3,"description":"残す指摘 3","suggestion":"s3"},{"id":"F-04","reviewer":"b","severity":"LOW","file":"b.md","line":4,"description":"消す指摘 4","suggestion":"s4"},{"id":"F-05","reviewer":"b","severity":"LOW","file":"b.md","line":5,"description":"残す指摘 5","suggestion":"s5"}]}'
run_target "$r" --exclude-ids "F-02,F-04"
assert "T-19 exit 0" "0" "$RC"
assert_grep "T-19 created" "$ERR" 'FOLLOW_UP_ISSUE=created; issue=99; pr=9'
assert_grep "T-19 F-01 が残る" "$STUB_DIR/body.md" '残す指摘 1'
assert_grep "T-19 F-03 が残る" "$STUB_DIR/body.md" '残す指摘 3'
assert_grep "T-19 F-05 が残る" "$STUB_DIR/body.md" '残す指摘 5'
assert_not_grep "T-19 F-02 は落ちる" "$STUB_DIR/body.md" '消す指摘 2'
assert_not_grep "T-19 F-04 は落ちる" "$STUB_DIR/body.md" '消す指摘 4'

echo "--- T-20: 和集合の全件除外は all_resolved (AC-4) ---"
reset_stubs
r=$(new_root t20)
put_json "$r" "9-20260101120000.json" '{"non_blocking_findings":[{"id":"F-01","reviewer":"a","severity":"LOW","file":"a.md","line":1,"description":"d1","suggestion":"s1"}]}'
put_json "$r" "9-20260102120000.json" '{"non_blocking_findings":[{"id":"F-02","reviewer":"b","severity":"LOW","file":"b.md","line":2,"description":"d2","suggestion":"s2"},{"id":"F-03","reviewer":"b","severity":"LOW","file":"b.md","line":3,"description":"d3","suggestion":"s3"}]}'
run_target "$r" --exclude-ids "F-01,F-02,F-03"
assert "T-20 exit 0" "0" "$RC"
assert_grep "T-20 all_resolved" "$ERR" 'FOLLOW_UP_ISSUE=skipped; reason=all_resolved; pr=9'
assert "T-20 create 0 回" "0" "$(create_count)"

echo "--- T-21: 全 JSON が 0 件なら no_findings (AC-7 非回帰) ---"
reset_stubs
r=$(new_root t21)
put_json "$r" "9-20260101120000.json" '{"non_blocking_findings":[]}'
put_json "$r" "9-20260102120000.json" '{"non_blocking_findings":[]}'
run_target "$r"
assert "T-21 exit 0" "0" "$RC"
assert_grep "T-21 no_findings" "$ERR" 'FOLLOW_UP_ISSUE=skipped; reason=no_findings; pr=9'
assert "T-21 create 0 回" "0" "$(create_count)"

echo "--- T-22: id 欠落 / 書式外 id の finding を落とさない ---"
reset_stubs
r=$(new_root t22)
put_json "$r" "9-20260101120000.json" '{"non_blocking_findings":[{"reviewer":"a","severity":"LOW","file":"a.md","line":1,"description":"id 無しの指摘 A","suggestion":"sA"},{"reviewer":"a","severity":"LOW","file":"a.md","line":2,"description":"id 無しの指摘 B","suggestion":"sB"}]}'
put_json "$r" "9-20260102120000.json" '{"non_blocking_findings":[{"id":"H-01","reviewer":"b","severity":"LOW","file":"b.md","line":3,"description":"書式外 id の指摘","suggestion":"sC"}]}'
run_target "$r"
assert "T-22 exit 0" "0" "$RC"
assert_grep "T-22 id 無し A が残る" "$STUB_DIR/body.md" 'id 無しの指摘 A'
assert_grep "T-22 id 無し B が残る" "$STUB_DIR/body.md" 'id 無しの指摘 B'
assert_grep "T-22 書式外 id が残る" "$STUB_DIR/body.md" '書式外 id の指摘'

echo "--- T-23: parse 不能な JSON を 1 本だけ除外し、jq の原因行を surface する ---"
# 統合 jq (`. + $add`) は type gate を通った配列同士の連結なので入力由来では失敗しえない。
# 本 test が突くのは兄弟の parse 失敗分岐で、T-03u との差分は「jq の原因行 emit」と「union 内訳」。
reset_stubs
r=$(new_root t23)
put_json "$r" "9-20260101120000.json" '{"non_blocking_findings":[{"id":"F-01","reviewer":"a","severity":"LOW","file":"a.md","line":1,"description":"健全な指摘","suggestion":"s1"}]}'
put_json "$r" "9-20260102120000.json" '{ this is not json'
run_target "$r"
assert "T-23 exit 0" "0" "$RC"
assert_grep "T-23 created" "$ERR" 'FOLLOW_UP_ISSUE=created; issue=99; pr=9'
assert_grep "T-23 健全な側は載る" "$STUB_DIR/body.md" '健全な指摘'
assert_grep "T-23 除外を WARNING で surface" "$ERR" '和集合から除外します'
# 原因行が無いと「どの JSON がなぜ落ちたか」が消える (WARNING 本文だけでは退行を検出できない)
assert_grep "T-23 jq の原因行を surface" "$ERR" 'jq: parse error'
assert_grep "T-23 除外本数を stderr の内訳に出す" "$ERR" 'union: pr=9; json_total=2; json_parsed=1; json_unparsed=1'

echo "--- T-24: 和集合内で衝突する id は除外しない (曖昧 key の silent drop 防止) ---"
# `id` は cycle ごとの連番なので、2 本の JSON に同じ `F-05` が別内容で載りうる。6.0.V が
# 片方だけを resolved と判定して `--exclude-ids "F-05"` を渡すと、id 一致で両方が落ちて
# 残存している側が黙って消える。曖昧な id は除外せず過剰転記側へ倒す。
reset_stubs
r=$(new_root t24)
put_json "$r" "9-20260101120000.json" '{"non_blocking_findings":[{"id":"F-05","reviewer":"a","severity":"LOW","file":"a.md","line":1,"description":"cycle1 の F-05","suggestion":"s1"},{"id":"F-06","reviewer":"a","severity":"LOW","file":"a.md","line":2,"description":"消える F-06","suggestion":"s2"}]}'
put_json "$r" "9-20260102120000.json" '{"non_blocking_findings":[{"id":"F-05","reviewer":"b","severity":"LOW","file":"b.md","line":3,"description":"cycle2 の F-05","suggestion":"s3"}]}'
run_target "$r" --exclude-ids "F-05,F-06"
assert "T-24 exit 0" "0" "$RC"
assert_grep "T-24 created (all_resolved に倒れない)" "$ERR" 'FOLLOW_UP_ISSUE=created; issue=99; pr=9'
assert_grep "T-24 cycle1 の F-05 が残る" "$STUB_DIR/body.md" 'cycle1 の F-05'
assert_grep "T-24 cycle2 の F-05 も残る" "$STUB_DIR/body.md" 'cycle2 の F-05'
assert_grep "T-24 曖昧 id を WARNING で surface" "$ERR" '和集合内で複数の finding に一致するため除外しません: F-05 \(2 件\)'
assert_not_grep "T-24 一意な F-06 は従来どおり除外される" "$STUB_DIR/body.md" '消える F-06'
assert_grep "T-24 過剰転記を marker で surface" "$ERR" 'FOLLOW_UP_EXCLUDE_AMBIGUOUS=1; count=1; pr=9'

echo "--- T-24c: 曖昧 id の素値は neutralize_ctrl を通してから WARNING に載せる ---"
# id はレビュアーが書く信頼できない入力。生の ESC が stderr へ素通りすると端末表示を欺瞞できる。
reset_stubs
r=$(new_root t24c)
# JSON 側は \u001b で書く（生の制御文字は JSON 仕様上 string に置けず parse で落ちる）。
# --exclude-ids 側は helper が受け取る実バイト = 生 ESC を渡す。
_esc=$(printf '\033')
put_json "$r" "9-20260101120000.json" '{"non_blocking_findings":[{"id":"F-05\u001b[31m","reviewer":"a","severity":"LOW","file":"a.md","line":1,"description":"cycle1","suggestion":"s1"}]}'
put_json "$r" "9-20260102120000.json" '{"non_blocking_findings":[{"id":"F-05\u001b[31m","reviewer":"b","severity":"LOW","file":"b.md","line":2,"description":"cycle2","suggestion":"s2"}]}'
run_target "$r" --exclude-ids "F-05${_esc}[31m"
assert "T-24c exit 0" "0" "$RC"
assert "T-24c stderr に生 ESC を残さない" "0" \
  "$(LC_ALL=C grep -c "$_esc" "$ERR" | tr -d ' ')"
assert_grep "T-24c 曖昧 id の WARNING 自体は出る" "$ERR" '和集合内で複数の finding に一致するため除外しません'
assert_grep "T-24c 中和後の id と件数を WARNING に載せる" "$ERR" 'F-05\?\[31m \(2 件\)'
assert_grep "T-24c 過剰転記を marker で surface" "$ERR" 'FOLLOW_UP_EXCLUDE_AMBIGUOUS=1; count=1; pr=9'

echo "--- T-24b: 重複 id があっても --exclude-ids が指していなければ曖昧扱いしない ---"
# 曖昧判定の絞り込み (`$ex` に含まれる id だけを曖昧とする) を削る変異を捕まえる。
reset_stubs
r=$(new_root t24b)
put_json "$r" "9-20260101120000.json" '{"non_blocking_findings":[{"id":"F-05","reviewer":"a","severity":"LOW","file":"a.md","line":1,"description":"cycle1 の F-05","suggestion":"s1"},{"id":"F-01","reviewer":"a","severity":"LOW","file":"a.md","line":2,"description":"消える F-01","suggestion":"s2"}]}'
put_json "$r" "9-20260102120000.json" '{"non_blocking_findings":[{"id":"F-05","reviewer":"b","severity":"LOW","file":"b.md","line":3,"description":"cycle2 の F-05","suggestion":"s3"}]}'
run_target "$r" --exclude-ids "F-01"
assert "T-24b exit 0" "0" "$RC"
assert_not_grep "T-24b 無関係な id で曖昧 WARNING を出さない" "$ERR" '和集合内で複数の finding に一致するため除外しません'
assert_not_grep "T-24b 曖昧 marker を出さない" "$ERR" 'FOLLOW_UP_EXCLUDE_AMBIGUOUS'
assert_not_grep "T-24b F-01 は除外される" "$STUB_DIR/body.md" '消える F-01'
assert_grep "T-24b 重複 id は両方残る (cycle1)" "$STUB_DIR/body.md" 'cycle1 の F-05'
assert_grep "T-24b 重複 id は両方残る (cycle2)" "$STUB_DIR/body.md" 'cycle2 の F-05'

echo "--- T-25: 曖昧判定の失敗ハンドラは安全側へ倒し marker も出す ---"
# jq を失敗させる入力は helper 内部で生成される値のため作れない。倒れる向きと marker の
# 有無はソース pin で固定する（向きが黙って戻ると未解消の指摘が落ちる側へ回帰する）。
assert_grep "T-25 判定失敗は除外なしへ倒す" "$TARGET" "ambiguous_json=\"\[\]\"; exclude_json='\[\]'"
assert_grep "T-25 判定失敗でも marker を出す" "$TARGET" 'FOLLOW_UP_EXCLUDE_AMBIGUOUS=1; count=\$\{_amb_req\}'
assert_not_grep "T-25 除外をそのまま適用する文言を残さない" "$TARGET" '除外をそのまま適用します'

echo "--- T-arg: 引数 gate ---"
bash "$TARGET" --pr abc --state-root "$TMP_ROOT" --owner a --repo b >"$OUT" 2>"$ERR"; RC=$?
assert "T-arg --pr 非数値は exit 1" "1" "$RC"
bash "$TARGET" --pr 9 --owner a --repo b >"$OUT" 2>"$ERR"; RC=$?
assert "T-arg --state-root 欠落は exit 1" "1" "$RC"
r=$(new_root targ)
run_target "$r" --bogus x
assert "T-arg 未知オプションは exit 1" "1" "$RC"

print_summary "cleanup-follow-up-issue.test.sh"
