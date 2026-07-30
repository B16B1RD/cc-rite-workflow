#!/bin/bash
# comment-journal-check.test.sh
#
# Tests for comment-journal-check.sh — the fast-fail layer that flags journal
# narration (P1-P4) and descriptive Issue/PR number references (P5/P6) in
# plugins/rite/**, docs/** and .rite/wiki/**.
#
# Coverage:
#   TC-1   裸の `PR #N` / `Issue #N` が P5 で hit する (拡張の本体)
#   TC-2   `## ソース` 節の provenance ラベルが hit しない
#   TC-3   TODO / FIXME 行が hit しない
#   TC-4   インラインコードスパン内の literal 引用が hit しない
#   TC-5   コードフェンス内は P5/P6 が hit しない / フェンス閉じ後は再び検出される
#   TC-6   語境界: 報告される一致が `PR #2047` で、`PR #204` に切れない
#   TC-7   旧 P5/P6 の 4 形 (See/Refs/Closes 系 / #N で対応 / 詳細は #N) が保たれる
#   TC-8   キーワードなし裸の `#N` は hit しない (意図的な非対象)
#   TC-9   1 行に複数一致があれば全件報告される (multi-match discipline)
#   TC-10  除外は P5/P6 限定 — フェンス内の P1 検出は従来どおり残る (非回帰)
#   TC-11  exit code 契約 (0 = clean / 1 = findings / 2 = invocation error)
#   TC-12  MUTATION P5 を旧 regex へ戻すと TC-1 が落ちる (拡張の識別力)
#   TC-13  MUTATION 除外 (fence/span/ソース節) を外すと TC-2/4/5 が落ちる (除外の識別力)
#   TC-14  self-exclusion (SoT 本体 / parity test / 自スクリプト) が --all で維持される (静的回帰)
#   TC-15  `## ソース` 除外が節スコープ + フェンス内の見出しで誤発火しない
#   TC-16  語彙の大小文字対称性と左語境界 (prefs / hrefs の語尾一致を弾く)
#   TC-17  「PR #N で別途対応」が P5/P6 で二重報告されない
#
# NOT covered (environment-dependent): mktemp failure on a read-only /tmp.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_test-helpers.sh
source "$SCRIPT_DIR/_test-helpers.sh"
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"
SCRIPT="$PLUGIN_ROOT/hooks/scripts/comment-journal-check.sh"

if [ ! -f "$SCRIPT" ]; then
  echo "ERROR: script not found: $SCRIPT" >&2
  exit 1
fi

cleanup_dirs=()
cleanup() {
  local p
  for p in "${cleanup_dirs[@]:-}"; do [ -n "$p" ] && rm -rf "$p"; done
}
trap cleanup EXIT

SBX=$(make_plain_sandbox)
cleanup_dirs+=("$SBX")
mkdir -p "$SBX/docs"

# scan: write $1 as docs/t.md and return the findings for it (one per line).
scan() {
  printf '%s\n' "$1" > "$SBX/docs/t.md"
  ( cd "$SBX" && bash "$SCRIPT" --target docs/t.md --repo-root "$SBX" --quiet ) 2>/dev/null
}
# count: number of findings; pat_count: findings matching a pattern
count() { scan "$1" | grep -c . ; }
pat_count() { scan "$1" | grep -cE "$2" || true ; }

echo "== comment-journal-check.sh (P5/P6 拡張と除外) =="

# ---- TC-1 拡張の本体: 裸の keyword + 番号 ----------------------------------
assert "TC-1 裸の PR #N が hit"    "1" "$(count 'PR #1300 は フォーマットを統一した')"
assert "TC-1 裸の Issue #N が hit" "1" "$(count 'Issue #1284 系譜の継続')"
assert_val=$(scan 'PR #1300 は フォーマットを統一した')
case "$assert_val" in
  *"[P5]"*) pass "TC-1 裸形は P5 として分類される" ;;
  *) fail "TC-1 裸形が P5 で報告されない (actual: $assert_val)" ;;
esac

# ---- TC-7 旧 4 形の非回帰 ---------------------------------------------------
assert "TC-7 See #N が hit"        "1" "$(count 'See #1149 も同様')"
assert "TC-7 Closes #N が hit"     "1" "$(count 'Closes #1148 で閉じた')"
assert "TC-7 refs #N が hit"       "1" "$(count '(refs #1150) の括弧形')"
assert "TC-7 詳細は #N が hit"      "1" "$(count '詳細は #1151')"
assert "TC-7 #N で別途対応 が hit"  "1" "$(count '#1152 で別途対応')"

# ---- TC-8 意図的な非対象 ----------------------------------------------------
assert "TC-8 キーワードなし裸 #N は hit しない" "0" "$(count '#1234 の単独形は対象外')"
assert "TC-8 ファイル名アンカーは hit しない"    "0" "$(count 'xxx.test.sh を参照する')"

# ---- TC-3 TODO / FIXME ------------------------------------------------------
assert "TC-3 TODO 行は hit しない"  "0" "$(count 'TODO: #9999 で対応予定')"
assert "TC-3 FIXME 行は hit しない" "0" "$(count 'FIXME PR #9998 を追う')"

# ---- TC-4 インラインコードスパン --------------------------------------------
assert "TC-4 コードスパン内は hit しない" "0" "$(count '`refs #204` が `refs #2047` に一致する')"
# span マスクは削除ではなく `_` 置換 — 削除するとキーワードと番号が隣接して偽の一致が生まれる。
assert "TC-4 span マスクがキーワードと番号を連結しない" "0" "$(count 'PR `x` #1234')"
# span 外の参照は span があっても検出される (マスクが行全体を殺していないことの確認)
assert "TC-4 span 外の参照は検出される" "1" "$(count '`code` の後に PR #1300 がある')"

# ---- TC-5 コードフェンス ----------------------------------------------------
fence_only=$(printf '```bash\ngrep -E "PR #7777" f.md\n```\n')
assert "TC-5 フェンス内は P5 が hit しない" "0" "$(pat_count "$fence_only" '\[P5\]')"
fence_then=$(printf '```bash\ngrep -E "PR #7777" f.md\n```\n\nPR #1301 フェンス後\n')
assert "TC-5 フェンス閉じ後は再び検出される" "1" "$(pat_count "$fence_then" '\[P5\]')"

# ---- TC-10 除外は P5/P6 限定 (P1-P4 は従来どおり) ---------------------------
fence_p1=$(printf '```bash\n# verified-review cycle 8 はフェンス内\n```\n')
assert "TC-10 フェンス内でも P1 は従来どおり検出される" "1" "$(pat_count "$fence_p1" '\[P1\]')"

# ---- TC-2 `## ソース` 節 ----------------------------------------------------
src=$(printf '# t\n\nPR #1300 は本文の参照\n\n## ソース\n\n- [PR #1300 review results](../../raw/reviews/a.md)\n- [Issue #1284 fix results](../../raw/fixes/b.md)\n')
assert "TC-2 ソース節より前の本文は hit する" "1" "$(pat_count "$src" '\[P5\]')"
assert "TC-2 ソース節配下の provenance ラベルは hit しない" "0" "$(scan "$src" | grep -cE ':(7|8):' || true)"

# ---- TC-6 語境界 -------------------------------------------------------------
b=$(scan 'PR #2047 の語境界')
case "$b" in
  *"reference: PR #2047"*) pass "TC-6 報告される一致は PR #2047" ;;
  *) fail "TC-6 語境界の報告文字列が想定外 (actual: $b)" ;;
esac
case "$b" in
  *"reference: PR #204 "*|*"reference: PR #204") fail "TC-6 一致が PR #204 で切れている" ;;
  *) pass "TC-6 一致が PR #204 で切れない" ;;
esac
# P6 の報告文字列は数字で終わらない — 境界文字の trim が「対応」の末尾を削らないこと。
b6=$(scan '#1152 で別途対応')
case "$b6" in
  *"(ja): #1152 で別途対応"*) pass "TC-6 P6 の報告文字列が末尾まで保たれる" ;;
  *) fail "TC-6 P6 の報告文字列が壊れている (actual: $b6)" ;;
esac

# ---- TC-9 multi-match --------------------------------------------------------
assert "TC-9 1 行に 2 件あれば 2 件報告される" "2" "$(count 'PR #1300 と Issue #1284 の両方')"

# ---- TC-11 exit code 契約 ----------------------------------------------------
printf '%s\n' 'クリーンな行' > "$SBX/docs/t.md"
( cd "$SBX" && bash "$SCRIPT" --target docs/t.md --repo-root "$SBX" --quiet ) >/dev/null 2>&1
assert "TC-11 findings なし → exit 0" "0" "$?"
printf '%s\n' 'PR #1300 は フォーマットを統一した' > "$SBX/docs/t.md"
( cd "$SBX" && bash "$SCRIPT" --target docs/t.md --repo-root "$SBX" --quiet ) >/dev/null 2>&1
assert "TC-11 findings あり → exit 1" "1" "$?"
( cd "$SBX" && bash "$SCRIPT" --repo-root "$SBX" --quiet ) >/dev/null 2>&1
assert "TC-11 target 指定なし → exit 2" "2" "$?"
( cd "$SBX" && bash "$SCRIPT" --bogus-flag --repo-root "$SBX" --quiet ) >/dev/null 2>&1
assert "TC-11 未知の引数 → exit 2" "2" "$?"

# ---- TC-12 / TC-13 MUTATION --------------------------------------------------
# mutant は `sed` で作る。パターンが一致せず no-op のまま「差が出なかった」と読むと
# mutation test が無言で vacuous になるため、実行前に必ず元との差分を確認する。
# sed は BRE のため `?` と `|` は literal 文字として扱われる (パターンを素の文字列で書ける)。
make_mutant() {
  local label="$1" out="$2" expr="$3"
  sed "$expr" "$SCRIPT" > "$out"
  if diff -q "$SCRIPT" "$out" >/dev/null 2>&1; then
    fail "$label (mutant が元と同一 — sed パターンが一致していない。この assert は無効)"
    return 1
  fi
  return 0
}

# 拡張で語彙に足した裸の Issue / PR を取り除いた mutant では、裸形が落ちる。
MUT_P5="$SBX/mutant-p5.sh"
if make_mutant "TC-12 MUTATION mutant 生成" "$MUT_P5" 's%\[Ii\]ssues?|\[Pp\]\[Rr\]s?|%%'; then
  printf '%s\n' 'PR #1300 は フォーマットを統一した' > "$SBX/docs/t.md"
  mut_p5_hits=$( ( cd "$SBX" && bash "$MUT_P5" --target docs/t.md --repo-root "$SBX" --quiet ) 2>/dev/null | grep -c . )
  if [ "${mut_p5_hits:-0}" -eq 0 ]; then
    pass "TC-12 MUTATION 語彙から裸の Issue/PR を外すと裸形が落ちる (拡張に識別力あり)"
  else
    fail "TC-12 MUTATION 語彙を戻しても裸形が検出される (${mut_p5_hits} 件) — 拡張が何も広げていない"
  fi
fi

# 除外ゲートを常時 true にした mutant では、コードスパン / フェンス / ソース節が hit に混ざる。
MUT_EXCL="$SBX/mutant-excl.sh"
if make_mutant "TC-13 MUTATION 除外ゲート mutant 生成" "$MUT_EXCL" 's%ref_scan = (!infence && !fence_marker && !insources)%ref_scan = 1%'; then
  run_mut_excl() {
    printf '%s\n' "$1" > "$SBX/docs/t.md"
    ( cd "$SBX" && bash "$MUT_EXCL" --target docs/t.md --repo-root "$SBX" --quiet ) 2>/dev/null | grep -c . || true
  }
  mut_fence=$(run_mut_excl "$fence_only")
  if [ "${mut_fence:-0}" -gt 0 ]; then
    pass "TC-13 MUTATION 除外ゲート除去でフェンス内が hit する (除外に識別力あり)"
  else
    fail "TC-13 MUTATION 除外ゲートを外してもフェンス内が hit しない — 除外が何も除外していない"
  fi
  mut_src=$(run_mut_excl "$src")
  if [ "${mut_src:-0}" -gt 1 ]; then
    pass "TC-13 MUTATION 除外ゲート除去でソース節ラベルが hit する (${mut_src} 件)"
  else
    fail "TC-13 MUTATION 除外ゲートを外してもソース節が hit しない (${mut_src} 件)"
  fi
fi
# コードスパンのマスクは ref_scan とは別経路のため、マスク自体を無効化した mutant で測る。
MUT_SPAN="$SBX/mutant-span.sh"
if make_mutant "TC-13 MUTATION span マスク mutant 生成" "$MUT_SPAN" 's%^ *gsub(.*ref_line)$%      ;%'; then
  printf '%s\n' '`refs #204` が `refs #2047` に一致する' > "$SBX/docs/t.md"
  mut_span=$( ( cd "$SBX" && bash "$MUT_SPAN" --target docs/t.md --repo-root "$SBX" --quiet ) 2>/dev/null | grep -c . )
  if [ "${mut_span:-0}" -gt 0 ]; then
    pass "TC-13 MUTATION span マスク除去でコードスパン内が hit する (${mut_span} 件)"
  else
    fail "TC-13 MUTATION span マスクを外してもコードスパン内が hit しない — マスクが何も除外していない"
  fi
fi

# ---- TC-14 self-exclusion の静的回帰 ----------------------------------------
# 禁止句を「定義・例示」する 3 ファイルを --all の走査から外す契約。裸形まで検出範囲が
# 広がったぶん、この除外が外れると定義文が丸ごと違反として立ち上がる。
assert_grep "TC-14 SoT 本体を self-exclude" "$SCRIPT" 'comment-best-practices\.md\) continue'
assert_grep "TC-14 parity test を self-exclude" "$SCRIPT" 'comment-best-practices-parity\.test\.sh\) continue'
assert_grep "TC-14 自スクリプトを self-exclude" "$SCRIPT" '"\$self_rel"\) continue'
# 検出器自身の test は fixture が禁止句そのものなので、走査対象に残ると全 fixture が違反として
# 立ち上がる (実測 35 件)。SoT / parity test と同じ理由で除外する。
assert_grep "TC-14 本 test を self-exclude" "$SCRIPT" 'comment-journal-check\.test\.sh\) continue'
assert_grep "TC-14 wiki-lint 側 test を self-exclude" "$SCRIPT" 'wiki-lint-descriptive-refs\.test\.sh\) continue'
all_out=$( ( cd "$PLUGIN_ROOT/../.." && bash "$SCRIPT" --all --quiet ) 2>/dev/null )
all_lines=$(printf '%s' "$all_out" | grep -c . || true)
# positive control: --all が 1 件も出さない状況 (scan root 不在で rc=2 等) では下の assert が
# vacuous に pass する。先に「走査自体が成立した」ことを測る。
if [ "${all_lines:-0}" -gt 0 ]; then
  pass "TC-14 --all が findings を出した (${all_lines} 行 — 除外 assert が vacuous でない)"
else
  fail "TC-14 --all が 0 件 — 除外 assert が vacuous になるため判定不能"
fi
excluded_hits=$(printf '%s' "$all_out" | grep -cE 'tests/(comment-journal-check|wiki-lint-descriptive-refs)\.test\.sh' || true)
assert "TC-14 --all で検出器 test の fixture が hit しない" "0" "$excluded_hits"

# ---- TC-15: `## ソース` 除外の節スコープ + フェンス保護 ---------------------
# 見出し以降 EOF まで打ち切ると、後続の本文節が丸ごと盲点になる。またフェンス内に引用された
# `## ソース` で走査が止まると、そのファイルの以降が無言で検出対象外になる。
post_src=$(printf '# t\n\n## ソース\n\n- [PR #1400 review results](../../raw/reviews/a.md)\n\n## 補強: 節\n\nPR #1500 はソース節の後の本文\n')
assert "TC-15 ソース節の後に続く本文は hit する (節スコープ)" "1" "$(pat_count "$post_src" '\[P5\]')"
fenced_src=$(printf '# t\n\n```markdown\n## ソース\n```\n\nPR #1300 はフェンス後の本文\n')
assert "TC-15 フェンス内の ## ソース では走査が止まらない" "1" "$(pat_count "$fenced_src" '\[P5\]')"

# ---- TC-16: 語彙の大小文字対称性と左語境界 ----------------------------------
assert "TC-16 小文字 issue #N も hit する"  "1" "$(count 'issue #55 の話')"
assert "TC-16 小文字 pr #N も hit する"     "1" "$(count 'pr #56 の話')"
assert "TC-16 prefs #N は hit しない (左語境界)" "0" "$(count 'prefs #12 を設定')"
assert "TC-16 hrefs #N は hit しない (左語境界)" "0" "$(count 'hrefs #13 を確認')"

# ---- TC-17: P5/P6 の二重報告解消 --------------------------------------------
# 「PR #N で別途対応」は両規則に当たる。P6 が 1 件だけ報告し P5 は報告しない。
dup=$(scan 'PR #1152 で別途対応')
assert "TC-17 PR #N で別途対応 は 1 件のみ報告される" "1" "$(printf '%s' "$dup" | grep -c . || true)"
assert "TC-17 報告するのは P6 (ja 構文) 側" "1" "$(printf '%s' "$dup" | grep -c '\[P6\]' || true)"
assert "TC-17 P5 は同一位置を報告しない" "0" "$(printf '%s' "$dup" | grep -c '\[P5\]' || true)"

if ! print_summary "$(basename "$0")" \
  "drift: comment-journal-check.sh の P5/P6 検出 / 除外が変わった可能性。スクリプト冒頭の P5/P6 定義・Word boundary・Descriptive-reference exclusions (X1-X3) の記述を参照。"; then
  exit 1
fi
