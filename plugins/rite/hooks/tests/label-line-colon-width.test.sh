#!/bin/bash
# label-line-colon-width.test.sh
#
# ラベル行 `- **ラベル**: 値` を、半角 `:` と全角 `：` のどちらの区切りでも読めることを pin する。
#   T-01 全角フェーズ行の更新で字形が保たれる
#   T-02 全角ループ回数を読んで加算できる
#   T-03 半角の既存データは変更前と同じ結果になる
#   T-04 skills 本文に書かれた抽出パターンが全角の番号行から PR 番号を取り出す
#   T-05 句点など想定外の区切りは一致しない
# 加えて issue-comment-wm-sync.sh の Issue 行抽出と wiki-apply-capture.sh の awk を、
# 実ファイルから照合式を取り出して両字形で検証する（照合式のコピーを持たない）。
# run-tests.sh は *.test.sh の glob で本ファイルを自動検出する。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PY="$SCRIPT_DIR/../issue-comment-wm-update.py"
SYNC="$SCRIPT_DIR/../issue-comment-wm-sync.sh"
CAPTURE="$SCRIPT_DIR/../scripts/wiki-apply-capture.sh"
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }
expect_eq() { # name expected actual
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected=[$2] actual=[$3])"; fi
}

for f in "$PY" "$SYNC" "$CAPTURE"; do
  [ -f "$f" ] || { echo "ERROR: missing target: $f" >&2; exit 1; }
done
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 is required" >&2; exit 1; }

FW=$'：'

echo "=== label-line colon width tests ==="

# ─── wm-update.py ────────────────────────────────────────────────────
echo "T-01: 全角フェーズ行の更新で字形が保たれる"
body_fw="- **フェーズ**${FW}implement
- **フェーズ詳細**${FW}実装中
- **最終更新**${FW}old"
out=$(printf '%s\n' "$body_fw" | python3 -I "$PY" update-phase --phase lint --phase-detail 検証 --timestamp T1)
expect_eq "T-01a: フェーズ" "- **フェーズ**${FW}lint" "$(printf '%s\n' "$out" | sed -n '1p')"
expect_eq "T-01b: フェーズ詳細" "- **フェーズ詳細**${FW}検証" "$(printf '%s\n' "$out" | sed -n '2p')"
expect_eq "T-01c: 最終更新" "- **最終更新**${FW}T1" "$(printf '%s\n' "$out" | sed -n '3p')"

echo "T-02: 全角ループ回数を読んで加算できる"
out=$(printf '%s\n' "- **現在のループ回数**${FW}3" | python3 -I "$PY" increment-loop-count)
expect_eq "T-02: 3 → 4（全角のまま）" "- **現在のループ回数**${FW}4" "$(printf '%s\n' "$out" | sed -n '1p')"

echo "T-03: 半角の既存データは従来どおり"
body_hw=$'- **フェーズ**: implement\n- **フェーズ詳細**: 実装中\n- **最終更新**: old'
out=$(printf '%s\n' "$body_hw" | python3 -I "$PY" update-phase --phase lint --phase-detail 検証 --timestamp T1)
expect_eq "T-03a: 半角フェーズ" "- **フェーズ**: lint" "$(printf '%s\n' "$out" | sed -n '1p')"
expect_eq "T-03b: 半角最終更新" "- **最終更新**: T1" "$(printf '%s\n' "$out" | sed -n '3p')"
out=$(printf '%s\n' "- **現在のループ回数**: 3" | python3 -I "$PY" increment-loop-count)
expect_eq "T-03c: 半角ループ回数 3 → 4" "- **現在のループ回数**: 4" "$(printf '%s\n' "$out" | sed -n '1p')"

echo "T-05: 句点区切りは一致せず既存の不一致挙動（無変更）"
body_bad="- **フェーズ**。implement"
out=$(printf '%s\n' "$body_bad" | python3 -I "$PY" update-phase --phase lint --phase-detail 検証 --timestamp T1)
expect_eq "T-05: 句点区切りの行は書き換わらない" "$body_bad" "$(printf '%s\n' "$out" | sed -n '1p')"


echo "追加: 出力全体のバイト一致・先頭のみ置換・節の二重生成なし"
dup=$'- **フェーズ**：a\n- **フェーズ**: b\n'
out=$(printf '%s' "$dup" | python3 -I "$PY" update-phase --phase lint --phase-detail d --timestamp T1)
expect_eq "同じラベルが 2 行あるときは先頭だけ変わる" $'- **フェーズ**：lint\n- **フェーズ**: b' "$(printf '%s\n' "$out" | sed -n '1,2p')"
nospace=$'- **フェーズ**：implement'
out=$(printf '%s\n' "$nospace" | python3 -I "$PY" update-phase --phase lint --phase-detail d --timestamp T1)
expect_eq "コロン直後の空白なしでも字形と空白なしが保たれる" "- **フェーズ**：lint" "$(printf '%s\n' "$out" | sed -n '1p')"
loop_fw=$'### レビュー対応履歴\n- **現在のループ回数**：2\n'
out=$(printf '%s' "$loop_fw" | python3 -I "$PY" increment-loop-count)
expect_eq "全角ループ回数があるとき節を二重に作らない" "1" "$(printf '%s\n' "$out" | grep -c '^### レビュー対応履歴$')"
expect_eq "全角ループ回数 2 → 3" "- **現在のループ回数**：3" "$(printf '%s\n' "$out" | grep '現在のループ回数')"
expect_eq "半角入力のバイト一致（全行）" $'- **フェーズ**: lint\n- **フェーズ詳細**: 検証\n- **最終更新**: T1' \
  "$(printf '%s\n' $'- **フェーズ**: implement\n- **フェーズ詳細**: 実装中\n- **最終更新**: old' | python3 -I "$PY" update-phase --phase lint --phase-detail 検証 --timestamp T1)"

echo "T-04 pin: 手順書の抽出パターン行に半角のみの表記が残っていない"
for rel in skills/fix/SKILL.md skills/ready/SKILL.md skills/pr-review/SKILL.md references/bash-defensive-patterns.md; do
  n=$(grep -cE '`- \*\*(番号|Issue|ブランチ)\*\*: [^`]*(\(|#)' "$PLUGIN_ROOT/$rel" || true)
  expect_eq "T-04 pin: $rel に半角のみの抽出パターンが 0 件" "0" "$n"
done

# ─── skills 本文の抽出パターン ──────────────────────────────────────
echo "T-04: skills 本文の抽出パターンが両字形の番号行に一致する"
for rel in skills/fix/SKILL.md skills/ready/SKILL.md skills/pr-review/SKILL.md; do
  pat=$(grep -oE '`- \*\*番号\*\*[^`]*#\(\\d\+\)`' "$PLUGIN_ROOT/$rel" | head -1 | sed 's/^`//; s/`$//')
  if [ -z "$pat" ]; then fail "T-04: $rel に番号行の抽出パターンが無い"; continue; fi
  # 手順書の表記（`**` は文字どおり）を Python の正規表現へ変換して適用する
  for sep in ':' "$FW"; do
    got=$(PAT="$pat" LINE="- **番号**${sep} #123" python3 -I -c '
import os, re
pat = re.escape("- **番号**") + os.environ["PAT"].split("**番号**", 1)[1]
m = re.search("^" + pat, os.environ["LINE"], re.M)
print(m.group(1) if m else "")')
    expect_eq "T-04: $rel [sep=$sep]" "123" "$got"
  done
done

# ─── wm-sync.sh の Issue 行抽出（実ファイルの sed 式を取り出して適用）─────
echo "wm-sync: Issue 行の抽出が両字形で #N を返す（BSD sed でも動く 2 式構成）"
# 実ファイルから Issue 行抽出の s/// 式を全て取り出して適用する（BSD sed の BRE は `\|` を持たない）
sed_args=()
while IFS= read -r expr; do
  sed_args+=(-e "$expr")
done < <(grep -F -- "s/^- \\*\\*Issue" "$SYNC" | sed -E "s/.*-e '([^']*)'.*|.*sed -n '([^']*)'.*/\1\2/")
if [ "${#sed_args[@]}" -lt 4 ]; then
  fail "wm-sync: Issue 行抽出の sed 式を実ファイルから取り出せない（${#sed_args[@]} 引数）"
else
  for sep in ':' "$FW"; do
    got=$(printf -- '- **Issue**%s #45\n' "$sep" | sed -n "${sed_args[@]}" | head -1)
    expect_eq "wm-sync: sep=$sep" "45" "$got"
    got=$(printf -- '- **Issue**%s #4\n' "$sep" | sed -n "${sed_args[@]}" | head -1)
    expect_eq "wm-sync: sep=$sep 接頭辞 #4 を #45 と取り違えない" "4" "$got"
  done
  got=$(printf -- '- **Issue**。#45\n' | sed -n "${sed_args[@]}" | head -1)
  expect_eq "wm-sync: 句点区切りは不一致" "" "$got"
  got=$(printf -- '- **Issue**：#7\n- **Issue**: #8\n' | sed -n "${sed_args[@]}" | head -1)
  expect_eq "wm-sync: 両字形が並ぶときは先頭の一致を採る" "7" "$got"
fi

# ─── wiki-apply-capture.sh の awk（パス / 版）─────────────────────────
echo "wiki-apply-capture: パス / 版の抽出が両字形で同じ結果"
awk_prog=$(sed -n "/PAGE_BLOCK=\$(printf/,/^  ')/p" "$CAPTURE" | sed '1d;$d')
if [ -z "$awk_prog" ]; then
  fail "wiki-apply-capture: awk プログラムを実ファイルから取り出せない"
else
  hw=$(printf -- '#### T\n- **パス**: a.md\n- **版**: 3\n' | awk "$awk_prog")
  fw=$(printf -- '#### T\n- **パス**%s a.md\n- **版**%s3\n' "$FW" "$FW" | awk "$awk_prog")
  expect_eq "wiki-apply-capture: 全角 == 半角" "$hw" "$fw"
  case "$hw" in
    *"page: a.md"*"rev: 3"*) pass "wiki-apply-capture: 半角で page/rev を抽出" ;;
    *) fail "wiki-apply-capture: 半角で page/rev を抽出できない ($hw)" ;;
  esac
fi

echo ""
echo "PASS: $PASS / FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
