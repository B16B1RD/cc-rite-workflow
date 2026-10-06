#!/bin/bash
# label-line-colon-width.test.sh
#
# ラベル行 `- **ラベル**: 値` を、半角 `:` と全角 `：` のどちらの区切りでも読めることを pin する。
#   T-01 全角フェーズ行の更新で字形が保たれる
#   T-02 全角ループ回数を読んで加算できる
#   T-03 半角の既存データは変更前と同じ結果になる
#   T-04 skills / references の抽出パターン全行が両字形・空白の有無で固定の入力から同じ値を返す
#   T-05 句点など想定外の区切りは一致しない
#   update-progress の最終更新行も両字形で更新され字形が保たれる
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

echo "update-progress: 最終更新行が両字形で更新され字形が保たれる"
for sep in ':' "$FW"; do
  out=$(printf '%s\n' "- **最終更新**${sep} old" | python3 -I "$PY" update-progress --impl-status 完了 --test-status 完了 --doc-status 完了 --timestamp T1)
  expect_eq "update-progress: sep=$sep の最終更新" "- **最終更新**${sep} T1" "$(printf '%s\n' "$out" | sed -n '1p')"
done

# ─── 手順書の抽出パターン（T-04 pin と行動検証を同じ走査で行う）──────────────
echo "T-04: 手順書・参考資料の抽出パターン全行が半角のみでなく、両字形・空白の有無で同じ値を返す"
t04=$(python3 -I - "$PLUGIN_ROOT" <<'PYEOF'
import glob, re, sys

root = sys.argv[1]
files = (glob.glob(root + "/skills/*/SKILL.md") + glob.glob(root + "/skills/*/references/*.md")
         + glob.glob(root + "/references/*.md"))
# 抽出パターン = バッククォート内の `- **ラベル**<区切り>...(取り出し部)...`
# 検査入力は検査対象のパターンと独立に固定する（パターンから生成すると前置部の欠落を検出できない）。
# ラベル → (入力の値部, 取り出し期待値)。未定義のラベルは ng（足すまで通さない）。
VALUES = {
    "番号": ("#123", "123"), "Issue": ("#123", "123"),
    "ブランチ": ("feat/x", "feat/x"), "フェーズ": ("implement", "implement"),
    "現在のループ回数": ("3", "3"),
}
# 抽出パターン = `- **ラベル**...(取り出し部)...`（バッククォート式）と、Python の raw 文字列 r"^(- \*\*ラベル\*\*...)"。
# 区切りの表記は問わず拾い、許容形 `[:：] ?` 以外は ng に積む。
rx_span = re.compile(r"`- \*\*([^*`]+)\*\*([^`]*)`")
rx_py = re.compile(r'r"(\^?\(?- \\\*\\\*([^\\*"]+)\\\*\\\*[^"]*)"')
rows, ng = 0, []

def verify(where, label, pat, sep_ok, check_group):
    if not sep_ok:
        ng.append("半角のみ・許容形以外: %s: %s" % (where, label))
        return
    if label not in VALUES:
        ng.append("検査入力が未定義: %s: %s" % (where, label))
        return
    value, want = VALUES[label][0], VALUES[label][1]
    for colon in (":", "：") :
        for space in ("", " "):
            sample = "- **" + label + "**" + colon + space + value
            mm = re.search(pat, sample)
            if not mm or (check_group and mm.group(1) != want):
                ng.append("不一致: %s: %r" % (where, sample))

for f in sorted(files):
    where = f.replace(root + "/", "")
    for line in open(f, encoding="utf-8"):
        for m in rx_span.finditer(line):
            label, rest = m.groups()
            if "(" not in rest:
                continue
            rows += 1
            verify(where, label, "^" + re.escape("- **" + label + "**") + rest, rest.startswith("[:：] ?"), True)
        for m in rx_py.finditer(line):
            rows += 1
            content, label = m.groups()
            verify(where, label, content, "\\*\\*[:：] ?" in content, False)
print("rows=%d ng=%d" % (rows, len(ng)))
for x in ng:
    print(x)
PYEOF
)
rows=$(printf '%s\n' "$t04" | sed -n '1s/^rows=\([0-9]*\) ng=.*/\1/p')
ng=$(printf '%s\n' "$t04" | sed -n '1s/^rows=[0-9]* ng=\([0-9]*\)$/\1/p')
if [ -n "$rows" ] && [ "$rows" -ge 11 ]; then pass "T-04: 抽出パターンを ${rows} 行検出（11 行以上）"; else fail "T-04: 抽出パターンの検出行数が少ない (rows=${rows:-none})"; fi
expect_eq "T-04: 半角のみ・両字形で値を返さない抽出パターンが 0 件" "0" "${ng:-none}"
[ "${ng:-none}" = "0" ] || printf '%s\n' "$t04" | tail -n +2 | sed 's/^/    /'

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
