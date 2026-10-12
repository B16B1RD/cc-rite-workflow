#!/bin/bash
# test-pin-mutation-principles-contract.test.sh
#
# テストの pin・mutation 設計原則 (references/test-pin-mutation-principles.md) の配線契約を固定する。
# 実装側 (issue-implement 5.0.F) と reviewer 側 (test-reviewer Step 3) が同じ reference を読むこと、
# reference が節構造と中核規則を保つことを pin する。配線は両側とも、節を切り出して
# リテラルの行全体一致で検査し、ポインタ行の移動・コメント化・削除を負例 (negative control) として
# 落ちることを確かめる (負例は実装側・reviewer 側の両方で行う)。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"
REF="$PLUGIN_ROOT/references/test-pin-mutation-principles.md"
IMPL="$PLUGIN_ROOT/skills/issue-implement/SKILL.md"
REVIEWER="$PLUGIN_ROOT/agents/test-reviewer.md"

assert_file_exists_or_fail "reference が存在する" "$REF" || exit 1

# 見出し行 (完全一致) から次の見出し (## 以上の # を持つ行。#### も含む) 直前までを標準出力へ。見出しが無ければ空
section_of() {
  awk -v start="$2" '$0 == start { f = 1; print; next } f && /^##+ / { exit } f { print }' "$1"
}
# 節の中に行全体が一致する行があるか
section_has_line() {
  local body; body="$(section_of "$1" "$2")"
  grep -qxF -- "$3" <<<"$body"
}
# 節の抽出結果が空でないこと (見出し改名で空振りしない)
section_nonempty() {
  [ -n "$(section_of "$1" "$2")" ]
}

# --- reference: 節見出しと表 ---
H1="## 1. 基本手順（pin を書くとき）"
H2="## 2. 空振りを防ぐ（positive / negative control）"
H3="## 3. 文字列・正規表現 pin の精度"
H4="## 4. 対称・横展開・件数"
H5="## 5. fixture 設計"
H6="## 6. stub・shim・mock"
H7="## 7. 失敗経路・停止・skip"
H8="## 8. mutation の実測と報告"
H9="## 9. 散文契約・手順書の pin"
H10="## 10. 環境・移植性・移設"
n=0
for h in "$H1" "$H2" "$H3" "$H4" "$H5" "$H6" "$H7" "$H8" "$H9" "$H10"; do
  n=$((n + 1))
  assert "reference: 節 $n の見出し行が 1 つ" "1" "$(grep -cxF -- "$h" "$REF")"
  assert "reference: 節 $n に表ヘッダがある" "1" "$(section_of "$REF" "$h" | grep -cxF '| 条件 | 期待 |')"
  # 表ヘッダと区切り行を除いた規則の行が 1 行以上ある (中身を消しても通る pin にしない)
  rows="$(section_of "$REF" "$h" | grep -E '^\| ' | grep -vxF '| 条件 | 期待 |' | grep -cv '^|[-: |]*|$' || true)"
  if [ "${rows:-0}" -ge 1 ]; then pass "reference: 節 $n に規則の行がある"; else fail "reference: 節 $n に規則の行が無い"; fi
done

# --- reference: 中核規則を節ごとに行全体で pin ---
pin_row() { # label heading row
  if section_has_line "$REF" "$2" "$3"; then pass "$1"; else fail "$1 (節に該当行が無い)"; fi
}
pin_row "§1 既存実装への pin は変異で要否を確かめる" "$H1" "| 既存の実装に pin を足す | 書く前に mutation を当て、素通りしたときだけ pin を足す（要否と有効性を分離する）。実装より先にテストを書く TDD では、Red（先に落ちること）の確認がこの役を担う |"
pin_row "§2 否定 assert には positive control" "$H2" "| 「出ない／呼ばれない／作られない」を assert する | 同じ fixture・同じ経路で「出る」ことを示す positive control を先に置く。sandbox の依存不足・早期 exit・ログが書かれない走行で素通りしやすい |"
pin_row "§3 前方一致は行末まで完全一致" "$H3" "| 文言を前方一致で pin する | 接頭辞が短いほど付け足し変異を通す。行末まで完全一致（\`grep -qxF\` 等）にする。「行まるごと」を名乗る照合は行全体一致 |"
pin_row "§4 対称経路は両側に pin" "$H4" "| 対称な 2 経路（通常経路と回復経路、通常 commit と merge commit 等）を持つ実装 | pin も両側に置く。片側しか実行しない pin は退行を検出できない（片側ずつ外す mutation で生存する） |"
pin_row "§10 path 比較は pwd -P" "$H10" "| path 出力を比較する | fixture root は生成直後に \`pwd -P\` で正規化する（\`TMPDIR\` 末尾 slash も同様）。被テストが \`cd -P\` で出すなら期待値も \`cd -P\` 側で作る。片辺だけ \`resolve()\` を掛けず \`readlink\` で link 文字列を pin する |"

# --- 配線: 節限定 + 行全体一致 ---
IMPL_H="### 5.0.F テスト規律（全 Complexity 共通）"
IMPL_LINE='pin・mutation・fixture・stub を書くときは `{plugin_root}/references/test-pin-mutation-principles.md` の該当節を読み、書いた pin は対象を壊す変異で落ちることを実測する。'
REV_H="### Step 3: Edge Case and Boundary Review"
REV_LINE='- For each new pin (grep/assert on text, counts, ordering) and each stub/fixture in the diff, apply `{plugin_root}/references/test-pin-mutation-principles.md` (`{plugin_root}` is the directory above `agents/`): require a positive control for negative asserts, whole-line anchoring for text pins, sibling/both-path symmetry, and a mutation that makes the pin fail. Classify a surviving pin with the テスト網羅性 Finding Gate in `_reviewer-base.md` (`#test-coverage-finding-gate`); do not assign a fixed severity here.'

assert "issue-implement: 5.0.F 節が抽出できる" "ok" "$(section_nonempty "$IMPL" "$IMPL_H" && echo ok || echo empty)"
assert "test-reviewer: Step 3 節が抽出できる" "ok" "$(section_nonempty "$REVIEWER" "$REV_H" && echo ok || echo empty)"
if section_has_line "$IMPL" "$IMPL_H" "$IMPL_LINE"; then pass "issue-implement 5.0.F 節内に reference ポインタ行がある"; else fail "issue-implement 5.0.F 節内に reference ポインタ行が無い"; fi
if section_has_line "$REVIEWER" "$REV_H" "$REV_LINE"; then pass "test-reviewer Step 3 節内に reference ポインタ行がある"; else fail "test-reviewer Step 3 節内に reference ポインタ行が無い"; fi
for need in 'positive control' 'whole-line anchoring' 'sibling/both-path symmetry' '#test-coverage-finding-gate'; do
  if grep -qF -- "$need" <<<"$REV_LINE"; then pass "test-reviewer ポインタ行が '$need' を含む"; else fail "test-reviewer ポインタ行に '$need' が無い"; fi
done

# --- negative control: 配線を壊した入力は上の判定に一致しない ---
ctl="$(mktemp -d "${TMPDIR:-/tmp}/rite-pinmut-ctl-XXXXXX")" || exit 1
trap 'rm -rf "$ctl"' EXIT
# 前提: 元の入力に当該行が実在する (無いと負例が素通りで「検出」と表示される)
assert "前提: issue-implement に実装側ポインタ行が実在する" "1" "$(grep -cxF -- "$IMPL_LINE" "$IMPL")"
assert "前提: test-reviewer に reviewer 側ポインタ行が実在する" "1" "$(grep -cxF -- "$REV_LINE" "$REVIEWER")"
# (a) ポインタ行だけ削除
grep -vxF -- "$IMPL_LINE" "$IMPL" > "$ctl/deleted.md"
if section_has_line "$ctl/deleted.md" "$IMPL_H" "$IMPL_LINE"; then fail "control: 削除した入力で pin が通った"; else pass "control: ポインタ行の削除を検出する"; fi
# (b) ファイル末尾 (節の外) へ移動
{ grep -vxF -- "$IMPL_LINE" "$IMPL"; printf '%s\n' "$IMPL_LINE"; } > "$ctl/moved.md"
if section_has_line "$ctl/moved.md" "$IMPL_H" "$IMPL_LINE"; then fail "control: 節外へ移した入力で pin が通った"; else pass "control: 節外への移動を検出する"; fi
# (c) コメント化 (行全体が変わる)
sed "s|^${IMPL_LINE}\$|<!-- ${IMPL_LINE} -->|" "$IMPL" > "$ctl/commented.md"
if grep -qF -- "<!-- ${IMPL_LINE} -->" "$ctl/commented.md" && ! section_has_line "$ctl/commented.md" "$IMPL_H" "$IMPL_LINE"; then pass "control: コメント化を検出する"; else fail "control: コメント化を検出できない"; fi
# (d) 見出し改名で節が空になる
sed "s|^${IMPL_H}\$|### 5.0.F renamed|" "$IMPL" > "$ctl/renamed.md"
if section_nonempty "$ctl/renamed.md" "$IMPL_H"; then fail "control: 見出し改名で節が空にならない"; else pass "control: 見出し改名は空の抽出として検出する"; fi

# (e) reviewer 側: 行を削除・ファイル末尾 (節外) へ移動・語を反転した入力は通らない
grep -vxF -- "$REV_LINE" "$REVIEWER" > "$ctl/rev-deleted.md"
if section_has_line "$ctl/rev-deleted.md" "$REV_H" "$REV_LINE"; then fail "control: reviewer 行の削除で pin が通った"; else pass "control: reviewer 行の削除を検出する"; fi
{ grep -vxF -- "$REV_LINE" "$REVIEWER"; printf '%s\n' "$REV_LINE"; } > "$ctl/rev-moved.md"
if section_has_line "$ctl/rev-moved.md" "$REV_H" "$REV_LINE"; then fail "control: reviewer 行の節外移動で pin が通った"; else pass "control: reviewer 行の節外移動を検出する"; fi
REV_FLIPPED="${REV_LINE/apply /do NOT read or apply }"
awk -v old="$REV_LINE" -v new="$REV_FLIPPED" '$0 == old { print new; next } { print }' "$REVIEWER" > "$ctl/rev-flipped.md"
if [ "$REV_FLIPPED" != "$REV_LINE" ] && ! section_has_line "$ctl/rev-flipped.md" "$REV_H" "$REV_LINE"; then pass "control: reviewer 行の語の反転を検出する"; else fail "control: reviewer 行の語の反転を検出できない"; fi

# --- _reviewer-base.md の Gate アンカーが実在する (reviewer 側ポインタ行の参照先) ---
assert "_reviewer-base.md に test-coverage-finding-gate のアンカーがある" "1" "$(grep -cxF '<a id="test-coverage-finding-gate"></a>' "$PLUGIN_ROOT/agents/_reviewer-base.md")"

# --- 配布境界: 永続成果物に Issue / PR 番号を書かない (文法は正本の checker に任せる) ---
NUMCHK="$PLUGIN_ROOT/hooks/scripts/number-reference-check.sh"
num_findings() { # label file : checker の終了コード
  bash "$NUMCHK" --stdin --label "$1" < "$2" >/dev/null 2>&1
  echo $?
}
assert "reference に番号参照が無い" "0" "$(num_findings plugins/rite/references/test-pin-mutation-principles.md "$REF")"
assert "本テストに番号参照が無い" "0" "$(num_findings plugins/rite/hooks/tests/test-pin-mutation-principles-contract.test.sh "${BASH_SOURCE[0]}")"
# 陽性対照: 同じ checker は番号を含む入力を拒否する (番号は組み立てて、本ファイル自身が掛からないようにする)
printf 'see #%s%s\n' 45 67 > "$ctl/num.txt"
assert "control: checker が番号入りの入力を拒否する" "1" "$(num_findings plugins/rite/references/x.md "$ctl/num.txt")"

if ! print_summary "$(basename "$0")" "drift: test-pin-mutation-principles.md の節構成・中核規則、または issue-implement 5.0.F / test-reviewer Step 3 の参照行が変更された可能性"; then
  exit 1
fi
