#!/bin/bash
# test-pin-mutation-principles-contract.test.sh
#
# テストの pin・mutation 設計原則 (references/test-pin-mutation-principles.md) の配線契約を固定する。
# 実装側 (issue-implement 5.0.F) と reviewer 側 (test-reviewer Step 3) が同じ reference を読むこと、
# reference が節構造と中核規則 (§1〜§4・§6・§8〜§10 の代表行) を保つことを pin する。配線は両側とも、節を切り出して
# リテラルの行全体一致で検査し、ポインタ行の移動・コメント化・削除を負例 (negative control) として
# 落ちることを確かめる (負例: 実装側は削除・節外移動・コメント化・見出し改名、reviewer 側は削除・節外移動・語の反転、両側とも次の見出しを平文化してポインタ行を下へ移す変形)。
# あわせて、reviewer 側ポインタ行が参照する _reviewer-base.md のアンカーが実在することも検査する。
# reviewer が検証実験で守る規則 (スタブの自己再帰禁止・プロセス数の上限付きサブシェル・上限停止の報告) も
# _reviewer-base.md の節に固定し (負例: 規則の削除・節外移動で、欠けた規則のラベルだけが出る)、規則に書いた実行形を
# 抜き出して、自己再帰するスタブが上限で止まることと、再帰しない既存スイートが上限の有無で同じ結果になることを実測する。
# 既存スイートの fork 失敗の判定は C ロケールで行い、同じ判定が本物の fork 失敗に一致することを対照で確かめる。
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
pin_row "§1 assert 名・TC 名・コメントは強制範囲と同じ広さ" "$H1" "| 「X を守る」と書いた assert | X を壊す変異で落ちることを実測する。assert 名・TC 名・コメントは実際に強制する範囲と同じ広さで書き、実際の強さ（例: \`-ge 1\` で確かめているのに「3 回」と名付ける）・方向・順序を名乗り過ぎない |"
pin_row "§3 計数 pin は用語統一後の語で数える" "$H3" "| 語の出現回数を pin している手順書で用語を統一する | 統一前の語を数える計数 pin は、統一で落ちるか統一を妨げる。計数 pin は統一後の語で数える |"
pin_row "§6 mock は実際の API と同じ失敗の形で答える" "$H6" "| gh・API の失敗を mock する | 実際の API と同じ失敗の形で答える（GraphQL の NOT_FOUND は JSON 本文と exit 1 で返り、REST の 404 と違う）。成功形だけの fixture では実際の失敗分岐を通らない |"
pin_row "§8 検出範囲の主張は当てた変異の範囲だけ" "$H8" "| PR 本文・テストのコメントで検出範囲（「この変異で失敗する」）を主張する | 実際に当てた変異の範囲だけを書く。追加した pin は変異で確かめてから主張を広げる。当てていない範囲（言い換え全般など）は保証として書かない |"
pin_row "§9 1 文は直前の句点から自文の句点まで照合" "$H9" "| 段落の中の 1 文を pin する（折り返しの有無を問わない） | 直前の文末の句点から自文の句点までを照合する。文頭からの前方一致は末尾への例外の付け足しを、途中からの照合は先頭への条件の付け足しを通す。連続する文は 1 文ずつ照合する |"
pin_row "§9 参照行は拒否リストでなく行全体一致" "$H9" "| 別の段落を指すだけの行（参照行）を、現れてはならない語の列挙（拒否リスト）で守っている | 拒否リストは語を避けた部分列挙・言い換え・規則文の付け足しを通し続け、レビューのたびに語を足す往復になる。行全体の一致で固定する。文面が頻繁に変わる行は保守コストが高いので対象外にする |"
pin_row "§9 移した規則文は移設先の段落と出現回数で固定" "$H9" "| 規則を別の段落へ移す・1 か所にまとめる | 移した文を移設先の段落の切り出しに対して固定し、手順書全体での出現回数も数える。元の行への書き戻し・複製・削除をまとめて検出できる。拒否リストだけでは書き戻しと複製が残る。もともと 1 か所にしか現れない文は件数を数えない |"
pin_row "§9 固定した行の外への言い換えはレビューで確かめる" "$H9" "| 固定した行の外（別の行・別の節）へ言い換えで規則を足す変更 | 文字列の pin では原理的に検出できない。pin を増やさずレビューで確かめる。言い換えが実際に入った事例が出たら機械検出を検討する |"
pin_row "§10 path 比較は pwd -P" "$H10" "| path 出力を比較する | fixture root は生成直後に \`pwd -P\` で正規化する。\`TMPDIR\` 末尾の slash は、テスト側でパスを連結するときに二重 slash になるので取り除く。被テストが \`cd -P\` で出すなら期待値も \`cd -P\` 側で作る。比較の片辺だけに symlink 解決（\`resolve()\` 等）を掛けない。link 文字列そのものを pin したいときは \`readlink\` を使う |"

# --- 配線: 節限定 + 行全体一致 ---
IMPL_H="### 5.0.F テスト規律（全 Complexity 共通）"
IMPL_LINE='pin・mutation・fixture・stub を書くときは `{plugin_root}/references/test-pin-mutation-principles.md` を全文読み、各表の「条件」が書くテストに当たる行の「期待」に従い、書いた pin は対象を壊す変異で落ちることを実測する。'
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

# --- reviewer 共通原則: 検証実験のスタブの自己再帰禁止と、プロセス数の上限 ---
BASE="$PLUGIN_ROOT/agents/_reviewer-base.md"
BASE_RATIONALE="$PLUGIN_ROOT/skills/reviewers/references/reviewer-base-rationale.md"
EXP_H="### Mutation experiments and verification (worktree-only)"
EXP_STUB='- **スタブは自分自身を呼ばない**: 本物のコマンドの代わりに置くスタブ（偽の `gh` 等）から、`"$0"`・自分自身のパス・PATH 上で自分に解決される同名コマンドを呼ばない。本物のコマンドが要るときは、スタブを PATH の先頭に置く前に `command -v` で解決した絶対パスを控えておき、その絶対パスで呼ぶ'
EXP_LIMIT='- **実験・テスト・probe はプロセス数の上限付きサブシェルで実行する**: ここでの probe は、プロセスを起こして挙動を観測する実行（テスト・スタブ・PR が変更したスクリプトの実行など）を指し、Read / grep / `git show` などの読み取りは含まない。実行する前に、上限が効く条件をすべて単独のコマンドで確かめる。条件は、Linux であること（`uname -s` が `Linux`。数え上げに使う `ps -L` は Linux の procps の形）、root でないこと（`id -u` が `0` でない。root には `ulimit -u` が fork を止めない）、数え上げ（`ps -L -u "$(id -u)" --no-headers | wc -l`）が正の整数を返すことの 3 つ。1 つでも満たさなければ、既定値で代用せず実験・テスト・probe を実行しないで `Measurement-Blocked:` として報告する。すべて満たすときは `( ulimit -u $(( $(ps -L -u "$(id -u)" --no-headers | wc -l) + 512 )); bash <test> )` の形で実行する。上限は実行直前の自ユーザーのプロセス数（スレッドを含む）に固定の余裕 512 を足した値にする。`ulimit -u` はサブシェルの子孫ではなく自ユーザー全体のプロセス数で判定されるため、小さい固定値だけを上限にするとふだんのコマンドも fork できなくなる。複合コマンドが拒否されるときは、この形のままスクリプトに書いて `bash <script.sh>` で実行する'
EXP_BLOCKED='- **上限で止まった実験は数えない**: 上限で fork が失敗した実験（`Resource temporarily unavailable` / `Cannot fork` 等）は成功・失敗のどちらにも数えず `Measurement-Blocked:` として報告し、上限を上げて再試行しない'
EXP_ANCHOR="why-experiments-run-under-a-process-limit"
EXP_POINTER="rationale: ../skills/reviewers/references/reviewer-base-rationale.md#$EXP_ANCHOR"
# 欠けた規則のラベルを 1 行ずつ出す (全部あれば何も出さない)
missing_exp_rules() {
  section_has_line "$1" "$EXP_H" "$EXP_STUB" || echo "スタブの自己再帰禁止と絶対パス"
  section_has_line "$1" "$EXP_H" "$EXP_LIMIT" || echo "ulimit -u 付きサブシェルの実行形"
  section_has_line "$1" "$EXP_H" "$EXP_BLOCKED" || echo "上限停止は Measurement-Blocked"
}
assert "_reviewer-base.md: 検証実験の節の見出し行が 1 つ" "1" "$(grep -cxF -- "$EXP_H" "$BASE")"
missing="$(missing_exp_rules "$BASE")"
if [ -z "$missing" ]; then pass "_reviewer-base.md 検証実験の節に 3 規則がある"; else fail "_reviewer-base.md 検証実験の節に規則が無い: $(printf '%s' "$missing" | paste -sd '/' -)"; fi
if section_has_line "$BASE" "$EXP_H" "$EXP_POINTER"; then pass "_reviewer-base.md 検証実験の節に上限規則の rationale ポインタがある"; else fail "_reviewer-base.md 検証実験の節に上限規則の rationale ポインタが無い"; fi
assert "rationale: ポインタ先の見出しが 1 つある" "1" "$(grep -cxF "## $EXP_ANCHOR" "$BASE_RATIONALE")"
# negative control: 規則を 1 つずつ削除・節外 (ファイル末尾) へ移動した入力では、欠けた規則のラベルだけを出す。
# 期待ラベルは missing_exp_rules から独立に書き、規則とラベルの対応のずれも落とす
exp_rules=("$EXP_STUB" "$EXP_LIMIT" "$EXP_BLOCKED")
exp_labels=("スタブの自己再帰禁止と絶対パス" "ulimit -u 付きサブシェルの実行形" "上限停止は Measurement-Blocked")
for i in "${!exp_rules[@]}"; do
  rule="${exp_rules[$i]}"; label="${exp_labels[$i]}"
  assert "前提: 規則行が _reviewer-base.md にちょうど 1 つある (${rule:0:30})" "1" "$(grep -cxF -- "$rule" "$BASE")"
  grep -vxF -- "$rule" "$BASE" > "$ctl/base-deleted.md"
  { grep -vxF -- "$rule" "$BASE"; printf '%s\n' "$rule"; } > "$ctl/base-moved.md"
  for variant in deleted moved; do
    assert "control: 規則の${variant}で、出力が欠けた規則のラベル 1 行と完全一致する ($label)" "$label" "$(missing_exp_rules "$ctl/base-$variant.md")"
  done
done

# --- 規則の実行形の実測 ---
# 実行する式は規則の行から抜き出す (テスト側で書き直すと文書とずれても気づけない)。ps -L は Linux の procps の形
form="$(grep -oE '\( ulimit -u .* bash <test> \)' <<<"$EXP_LIMIT")"
count_procs() { ps -L -u "$(id -u)" --no-headers | wc -l | tr -d ' '; }
# 規則どおり外側の上限の中で実行されると、上限なしの対照 (深さ 300 で 600 件前後) も入れ子の上限も測れない。
# fork を止めるのは soft 上限なのでそれを読む。CI では上限の残りが足りないことを skip ではなく失敗にし、閾値の誤りで実測が消えないようにする
proc_limit="$(ulimit -u)"
if [ "$(uname -s)" != Linux ]; then
  skip "規則の実行形の実測 (Linux の ps -L を使う形のため、Linux 以外では実測しない)"
elif [ -z "$form" ]; then
  fail "規則の行から上限付きサブシェルの実行形を抜き出せない"
elif [ "$proc_limit" != unlimited ] && [ $(( proc_limit - $(count_procs) )) -lt 1000 ]; then
  limit_note="外側の上限 ulimit -u=$proc_limit の残りが 1000 件未満で、上限なしの対照と入れ子の上限を測れない"
  if [ -n "${CI:-}" ]; then fail "規則の実行形の実測が CI では測れない ($limit_note)"; else skip "規則の実行形の実測 ($limit_note)"; fi
else
  shell_limit_before="$(ulimit -u)"
  # 誤って自己再帰するスタブが上限で止まる。bash は fork の失敗を約 15 秒再試行するため、再試行しない dash で書く。
  # 深さ 300 の安全弁は上限が効かなかったときの機械の保護で、上限ありの実行で安全弁に届いたら失敗にする
  if [ "$(id -u)" -eq 0 ]; then
    skip "自己再帰のスタブが上限で止まる (root には ulimit -u が効かない)"
  elif ! dash_bin="$(command -v dash)"; then
    skip "自己再帰のスタブが上限で止まる (fork を再試行しない dash が無い)"
  else
    stub_dir="$ctl/stub-bin"; depth_file="$ctl/stub-depth"
    mkdir -p "$stub_dir"
    cat > "$stub_dir/gh" <<EOF
#!$dash_bin
d=\${STUB_DEPTH:-0}
echo "\$d" >> "$depth_file"
if [ "\$d" -ge 300 ]; then echo backstop >&2; [ -n "\${STUB_HOLD:-}" ] && sleep 2; exit 97; fi
out=\$(STUB_DEPTH=\$((d + 1)) "\$0" "\$@") || exit \$?
printf '%s\n' "\$out"
EOF
    chmod +x "$stub_dir/gh"
    max_depth() { sort -n "$depth_file" 2>/dev/null | tail -1; }
    # 対照: 上限なしでは安全弁まで再帰する。実行中はスタブのプロセスが見える (残存 0 件の数え方の positive control)
    : > "$depth_file"
    ( STUB_HOLD=1 PATH="$stub_dir:$PATH" gh issue view 7 ) >/dev/null 2>"$ctl/stub-free-err" &
    free_pid=$!
    sleep 1
    seen="$(pgrep -f "$stub_dir/gh" | wc -l | tr -d ' ')"
    wait "$free_pid"
    if [ "$seen" -ge 1 ]; then pass "対照: 実行中のスタブのプロセスを数えられる ($seen 件)"; else fail "対照: 実行中のスタブのプロセスが見えない (残存 0 件の判定が空振りする)"; fi
    if [ "$(max_depth)" = 300 ] && ! grep -q 'Cannot fork' "$ctl/stub-free-err"; then pass "対照: 上限なしでは安全弁 (深さ 300) まで再帰する"; else fail "対照: 上限なしで安全弁まで届かない (深さ $(max_depth))"; fi
    # 本体: 規則の式の余裕だけを 128 にして実行する (512 はふだんの用途の余裕で、再帰を短く止めるため小さくする)
    stub_form="${form/+ 512/+ 128}"
    stub_form="${stub_form/bash <test>/gh issue view 7}"
    if [ "$(grep -o '+ 512' <<<"$form" | wc -l | tr -d ' ')" = 1 ] && [ "$(grep -o 'bash <test>' <<<"$form" | wc -l | tr -d ' ')" = 1 ] \
       && [ "$stub_form" = "( ulimit -u \$(( \$(ps -L -u \"\$(id -u)\" --no-headers | wc -l) + 128 )); gh issue view 7 )" ]; then
      pass "規則の式の余裕と実行コマンドだけを置き換えた"
    else
      fail "規則の式の置き換えが 1 か所ずつ効いていない ($stub_form)"
    fi
    : > "$depth_file"
    procs_before="$(count_procs)"
    started=$(date +%s)
    PATH="$stub_dir:$PATH" bash -c "$stub_form" >/dev/null 2>"$ctl/stub-err"
    stub_rc=$?
    elapsed=$(( $(date +%s) - started ))
    procs_after="$(count_procs)"
    depth="$(max_depth)"
    procs_note="自ユーザーのプロセス数: 実行前 $procs_before / 実行後 $procs_after"
    if [ "$stub_rc" -ne 0 ]; then pass "自己再帰のスタブ: サブシェルが非ゼロで終了する (rc=$stub_rc)"; else fail "自己再帰のスタブ: サブシェルが 0 で終了した ($procs_note)"; fi
    if grep -q 'Cannot fork' "$ctl/stub-err" && ! grep -q backstop "$ctl/stub-err"; then pass "自己再帰のスタブ: 安全弁ではなく fork の失敗で止まる"; else fail "自己再帰のスタブ: fork の失敗で止まっていない ($(head -3 "$ctl/stub-err" | paste -sd ' ' -); $procs_note)"; fi
    # positive control: 1 段も再帰せず最初の fork で落ちた回は、上の判定を空振りで通す
    if [ "${depth:-0}" -ge 1 ] && [ "$depth" -lt 300 ]; then pass "自己再帰のスタブ: 実際に再帰してから上限で止まる (深さ $depth)"; else fail "自己再帰のスタブ: 再帰の深さが範囲外 (深さ ${depth:-なし}。0 なら上限が最初から足りない; $procs_note)"; fi
    if [ "$elapsed" -lt 5 ]; then pass "自己再帰のスタブ: 5 秒未満で終わる (${elapsed} 秒)"; else fail "自己再帰のスタブ: 終了まで ${elapsed} 秒かかった"; fi
    assert "自己再帰のスタブ: 終了後に残るスタブのプロセスは 0 件" "0" "$(pgrep -f "$stub_dir/gh" | wc -l | tr -d ' ')"
  fi
  # bash の fork 失敗の文言は strerror の翻訳に従うため、判定する実行はすべて同じ形で C ロケールに固定する
  c_locale=(env LC_ALL=C)
  fork_failed() { grep -q 'Resource temporarily unavailable' <<<"$1"; }
  # positive control: 本物の fork 失敗の出力に同じ判定が一致する。bash は fork の失敗を約 15 秒再試行するが、
  # 失敗のたびに文言を出すので 3 秒で打ち切る。再試行中のサブシェルは SIGTERM では止まらず孤児として残るため KILL で止める
  if [ "$(id -u)" -eq 0 ]; then
    skip "対照: fork 失敗の判定が本物の fork 失敗に一致する (root には ulimit -u が効かない)"
  else
    probe_out="$("${c_locale[@]}" timeout -s KILL 3 bash -c '( ulimit -u 1; /bin/true; /bin/true ); true' 2>&1)"
    if fork_failed "$probe_out"; then pass "対照: fork 失敗の判定が本物の fork 失敗に一致する"; else fail "対照: fork 失敗の判定が本物の fork 失敗に一致しない ($(head -2 <<<"$probe_out" | paste -sd ' ' -))"; fi
  fi
  # 規則どおりの上限 (+512) では、再帰しない既存のテストスイートが上限なしと同じ結果になる
  SUITE="$SCRIPT_DIR/parent-child-sync-static.test.sh"
  free_out="$("${c_locale[@]}" bash "$SUITE" 2>&1)"; free_rc=$?
  lim_out="$("${c_locale[@]}" bash -c "${form/<test>/\"$SUITE\"}" 2>&1)"; lim_rc=$?
  free_counts="$(grep -E '^(PASS|FAIL): [0-9]+$' <<<"$free_out")"
  lim_counts="$(grep -E '^(PASS|FAIL): [0-9]+$' <<<"$lim_out")"
  if [ -n "$free_counts" ]; then pass "既存スイート: 上限なしで成功・失敗件数が出る"; else fail "既存スイート: 上限なしの出力に件数が無い"; fi
  assert "既存スイート: 規則どおりの上限でも終了コードが同じ" "$free_rc" "$lim_rc"
  assert "既存スイート: 規則どおりの上限でも成功・失敗件数が同じ" "$free_counts" "$lim_counts"
  if fork_failed "$lim_out"; then fail "既存スイート: 規則どおりの上限で fork が失敗した"; else pass "既存スイート: 規則どおりの上限で fork が失敗しない"; fi
  assert "上限はサブシェルの中に閉じ、テスト自身のシェルの ulimit -u は変わらない" "$shell_limit_before" "$(ulimit -u)"
fi

if ! print_summary "$(basename "$0")" "drift: test-pin-mutation-principles.md の節構成・中核規則、issue-implement 5.0.F / test-reviewer Step 3 の参照行、または _reviewer-base.md の検証実験の節の上限規則 3 行と rationale ポインタが変更された可能性"; then
  exit 1
fi
