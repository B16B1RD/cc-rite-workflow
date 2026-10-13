#!/bin/bash
# test-pin-mutation-principles-contract.test.sh
#
# テストの pin・mutation 設計原則 (references/test-pin-mutation-principles.md) の配線契約を固定する。
# 実装側 (issue-implement 5.0.F) と reviewer 側 (test-reviewer Step 3) が同じ reference を読むこと、
# reference が節構造と中核規則 (§1〜§4・§8・§10 の代表行) を保つことを pin する。配線は両側とも、節を切り出して
# リテラルの行全体一致で検査し、ポインタ行の移動・コメント化・削除を負例 (negative control) として
# 落ちることを確かめる (負例: 実装側は削除・節外移動・コメント化・見出し改名、reviewer 側は削除・節外移動・語の反転、両側とも次の見出しを平文化してポインタ行を下へ移す変形)。
# あわせて、reviewer 側ポインタ行が参照する _reviewer-base.md のアンカーが実在することも検査する。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"
PLUGIN_ROOT="$(_helpers_resolve_plugin_root "$SCRIPT_DIR")"
REF="$PLUGIN_ROOT/references/test-pin-mutation-principles.md"
IMPL="$PLUGIN_ROOT/skills/issue-implement/SKILL.md"
REVIEWER="$PLUGIN_ROOT/agents/test-reviewer.md"

assert_file_exists_or_fail "reference が存在する" "$REF" || exit 1

# 見出し行 (完全一致) から次の見出し (# が 2 個以上続く見出し。#### も含む) 直前までを標準出力へ。見出しが無ければ空
section_of() {
  START="$2" awk '$0 == ENVIRON["START"] { f = 1; print; next } f && /^##+ / { exit } f { print }' "$1"
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
  assert "reference: 節 $n に表の区切り行がある" "1" "$(section_of "$REF" "$h" | grep -cE '^\|[-: |]+\|$')"
  assert "reference: 節 $n に表ヘッダがある" "1" "$(section_of "$REF" "$h" | grep -cxF '| 条件 | 期待 |')"
  # 表ヘッダと区切り行を除いた規則の行が 1 行以上ある (表だけ残して中身が空になる事故を防ぐ。
  # 個々の規則の増減は許し、中核規則だけを下の pin_row で行全体一致で固定する)
  rows="$(section_of "$REF" "$h" | grep -E '^\| ' | grep -vxF '| 条件 | 期待 |' | grep -cv '^|[-: |]*|$' || true)"
  if [ "$rows" -ge 1 ]; then pass "reference: 節 $n に規則の行がある"; else fail "reference: 節 $n に規則の行が無い"; fi
done

# --- reference: 中核規則を節ごとに行全体で pin ---
pin_row() { # label heading row
  if section_has_line "$REF" "$2" "$3"; then pass "$1"; else fail "$1 (節に該当行が無い)"; fi
}
pin_row "§1 既存実装への pin は変異で要否を確かめる" "$H1" "| 既存の実装に pin を足す | 書く前に mutation を当て、素通りしたときだけ pin を足す（要否と有効性を分離する）。実装より先にテストを書く TDD では、Red（先に落ちること）の確認がこの役を担う |"
pin_row "§2 否定 assert には positive control" "$H2" "| 「出ない／呼ばれない／作られない」を assert する | 同じ fixture・同じ経路で「出る」ことを示す positive control を先に置く。sandbox の依存不足・早期 exit・ログが書かれない走行で空振りしやすい |"
pin_row "§3 前方一致は行末まで完全一致" "$H3" "| 文言を前方一致で pin する | 接頭辞が短いほど付け足し変異を通す。行末まで完全一致（\`grep -qxF\` 等）にする。「行まるごと」を名乗る照合は行全体一致 |"
pin_row "§4 対称経路は両側に pin" "$H4" "| 対称な 2 経路（通常経路と回復経路、通常 commit と merge commit 等）を持つ実装 | pin も両側に置く。片側しか実行しない pin は退行を検出できない（片側ずつ外す mutation で生存する） |"
pin_row "§8 赤にならないときは変異の効きを疑う" "$H8" "| 赤にならない | pin の不備より先に mutation が効いたか（一致件数・構文・到達）を疑う。「到達して落ちうるか」を実証してから結論にする |"
pin_row "§10 path 比較は pwd -P" "$H10" "| path 出力を比較する | fixture root は生成直後に \`pwd -P\` で正規化する。\`TMPDIR\` 末尾の slash は、テスト側でパスを連結するときに二重 slash になるので取り除く。被テストが \`cd -P\` で出すなら期待値も \`cd -P\` 側で作る。比較の片辺だけに symlink 解決（\`resolve()\` 等）を掛けない。link 文字列そのものを pin したいときは \`readlink\` を使う |"

# --- 配線: 節限定 + 行全体一致 ---
IMPL_H="### 5.0.F テスト規律（全 Complexity 共通）"
IMPL_LINE='pin・mutation・fixture・stub を書くときは `{plugin_root}/references/test-pin-mutation-principles.md` の §1・§2・§8 と該当節（文字列 pin は §3、fixture は §5、stub は §6、失敗経路は §7）を読み、書いた pin は対象を壊す変異で落ちることを実測する。'
REV_H="### Step 3: Edge Case and Boundary Review"
REV_LINE='- For each new pin (grep/assert on text, counts, ordering) and each stub/fixture in the diff, apply the pin and mutation principles that the prompt supplies under 追加で読む規則 (read in full before starting the review; if the section is missing or any supplied file cannot be read, report that and stop instead of judging from memory). Require a positive control for negative asserts, whole-line (whole-sentence for wrapped prose) anchoring for text pins, sibling/both-path symmetry, and a mutation that makes the pin fail. Classify a surviving pin with the テスト網羅性 Finding Gate in `_reviewer-base.md` (`#test-coverage-finding-gate`); do not assign a fixed severity here.'

assert "issue-implement: 5.0.F の見出し行が 1 つ" "1" "$(grep -cxF -- "$IMPL_H" "$IMPL")"
assert "test-reviewer: Step 3 の見出し行が 1 つ" "1" "$(grep -cxF -- "$REV_H" "$REVIEWER")"
assert "issue-implement: 5.0.F 節が抽出できる" "ok" "$(section_nonempty "$IMPL" "$IMPL_H" && echo ok || echo empty)"
assert "test-reviewer: Step 3 節が抽出できる" "ok" "$(section_nonempty "$REVIEWER" "$REV_H" && echo ok || echo empty)"
if section_has_line "$IMPL" "$IMPL_H" "$IMPL_LINE"; then pass "issue-implement 5.0.F 節内に reference ポインタ行がある"; else fail "issue-implement 5.0.F 節内に reference ポインタ行が無い"; fi
if section_has_line "$REVIEWER" "$REV_H" "$REV_LINE"; then pass "test-reviewer Step 3 節内に reference ポインタ行がある"; else fail "test-reviewer Step 3 節内に reference ポインタ行が無い"; fi

# --- 閉じ側の位置: ポインタ行が節の中で規定の位置にある (次の見出しを平文化してその下へ移す変形を検出する) ---
# issue-implement はポインタ行が後続の固定行より前、test-reviewer はポインタ行が節の最終の非空行
IMPL_NEXT='既存 suite が無い種別は新規テストファイルを認め、規模は隣接テストファイルに合わせる。**XS/S では 5.1.0.8 の新規テストファイル禁止が優先**し、既存 suite が無くても新規ファイルは作らない。'
line_no() { section_of "$1" "$2" | grep -nxF -- "$3" | head -1 | cut -d: -f1; }
impl_order_ok() {
  local p q
  p="$(line_no "$1" "$IMPL_H" "$IMPL_LINE")"; q="$(line_no "$1" "$IMPL_H" "$IMPL_NEXT")"
  [ -n "$p" ] && [ -n "$q" ] && [ "$p" -lt "$q" ]
}
rev_last_ok() { [ "$(section_of "$1" "$REV_H" | grep -v '^[[:space:]]*$' | tail -1)" = "$REV_LINE" ]; }
if impl_order_ok "$IMPL"; then pass "issue-implement: ポインタ行が節内の後続固定行より前にある"; else fail "issue-implement: ポインタ行の位置が規定と違う"; fi
if rev_last_ok "$REVIEWER"; then pass "test-reviewer: ポインタ行が節の最終行にある"; else fail "test-reviewer: ポインタ行が節の最終行でない"; fi

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
OLD="$IMPL_LINE" NEW="<!-- ${IMPL_LINE} -->" awk '$0 == ENVIRON["OLD"] { print ENVIRON["NEW"]; next } { print }' "$IMPL" > "$ctl/commented.md"
if grep -qF -- "<!-- ${IMPL_LINE} -->" "$ctl/commented.md" && ! section_has_line "$ctl/commented.md" "$IMPL_H" "$IMPL_LINE"; then pass "control: コメント化を検出する"; else fail "control: コメント化を検出できない"; fi
# (d) 見出し改名で節が空になる
OLD="$IMPL_H" NEW="### 5.0.F renamed" awk '$0 == ENVIRON["OLD"] { print ENVIRON["NEW"]; next } { print }' "$IMPL" > "$ctl/renamed.md"
if grep -qxF -- "$IMPL_H" "$ctl/renamed.md"; then fail "control: 見出し改名が適用されていない"
elif section_nonempty "$ctl/renamed.md" "$IMPL_H"; then fail "control: 見出し改名で節が空にならない"
else pass "control: 見出し改名は空の抽出として検出する"; fi

# (e) reviewer 側: 行を削除・ファイル末尾 (節外) へ移動・語を反転した入力は通らない
grep -vxF -- "$REV_LINE" "$REVIEWER" > "$ctl/rev-deleted.md"
if section_has_line "$ctl/rev-deleted.md" "$REV_H" "$REV_LINE"; then fail "control: reviewer 行の削除で pin が通った"; else pass "control: reviewer 行の削除を検出する"; fi
{ grep -vxF -- "$REV_LINE" "$REVIEWER"; printf '%s\n' "$REV_LINE"; } > "$ctl/rev-moved.md"
if section_has_line "$ctl/rev-moved.md" "$REV_H" "$REV_LINE"; then fail "control: reviewer 行の節外移動で pin が通った"; else pass "control: reviewer 行の節外移動を検出する"; fi
REV_FLIPPED="${REV_LINE/apply /do NOT read or apply }"
OLD="$REV_LINE" NEW="$REV_FLIPPED" awk '$0 == ENVIRON["OLD"] { print ENVIRON["NEW"]; next } { print }' "$REVIEWER" > "$ctl/rev-flipped.md"
if [ "$REV_FLIPPED" != "$REV_LINE" ] && ! section_has_line "$ctl/rev-flipped.md" "$REV_H" "$REV_LINE"; then pass "control: reviewer 行の語の反転を検出する"; else fail "control: reviewer 行の語の反転を検出できない"; fi

# (f) 次の見出しを平文化し、ポインタ行をその下へ移した入力は、位置の検査で落ちる
demote_move() { # file heading line
  OLD="$2" PTR="$3" awk '
    $0 == ENVIRON["OLD"] { print; f = 1; next }
    f && /^##+ / { sub(/^#+ /, ""); print; print ENVIRON["PTR"]; f = 0; next }
    $0 == ENVIRON["PTR"] { next }
    { print }' "$1"
}
demote_move "$IMPL" "$IMPL_H" "$IMPL_LINE" > "$ctl/impl-demoted.md"
if section_has_line "$ctl/impl-demoted.md" "$IMPL_H" "$IMPL_LINE" && ! impl_order_ok "$ctl/impl-demoted.md"; then pass "control: issue-implement の見出し平文化 + 移動を位置検査が検出する"; else fail "control: issue-implement の見出し平文化 + 移動を検出できない"; fi
demote_move "$REVIEWER" "$REV_H" "$REV_LINE" > "$ctl/rev-demoted.md"
if section_has_line "$ctl/rev-demoted.md" "$REV_H" "$REV_LINE" && ! rev_last_ok "$ctl/rev-demoted.md"; then pass "control: test-reviewer の見出し平文化 + 移動を位置検査が検出する"; else fail "control: test-reviewer の見出し平文化 + 移動を検出できない"; fi

# --- _reviewer-base.md の Gate アンカーが実在する (reviewer 側ポインタ行の参照先) ---
assert "_reviewer-base.md に test-coverage-finding-gate のアンカーがある" "1" "$(grep -cxF '<a id="test-coverage-finding-gate"></a>' "$PLUGIN_ROOT/agents/_reviewer-base.md")"

if ! print_summary "$(basename "$0")" "drift: test-pin-mutation-principles.md の節構成・中核規則、または issue-implement 5.0.F / test-reviewer Step 3 の参照行が変更された可能性"; then
  exit 1
fi
