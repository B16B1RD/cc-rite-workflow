#!/bin/bash
# Tests for issue-complexity-lane.sh (XS/S 軽量レーンの判定)
#
# 本 helper は「儀式コストを Complexity に比例させる」判定の唯一の実行層で、判定を誤ると
# (a) M+ の Issue が軽量レーンへ落ちて検証深度が silent に下がる、または (b) XS/S が毎回
# フル装備で回りレーンが一度も発動しない、のどちらかになる。(a) は品質を無言で削るため、
# 本 suite は「情報が欠けた全経路で full へ倒れること」を reason ごとに個別に pin する
# (AC-2 / T-02)。
#
# gh は PATH shim で差し替える (hooks/tests/issue-comment-wm-sync.sh と同じ方式)。
# 実 API を叩かないため body の記法バリエーションを網羅的に固定できる。
#
# Usage: bash plugins/rite/scripts/tests/issue-complexity-lane.test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="$SCRIPT_DIR/../issue-complexity-lane.sh"
TEST_DIR="$(mktemp -d)"
TEST_REPO="$TEST_DIR/repo"
mkdir -p "$TEST_REPO"
git init -q "$TEST_REPO"
git -C "$TEST_REPO" remote add origin https://github.com/owner/repo.git
PASS=0
FAIL=0

cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT

pass() { PASS=$((PASS + 1)); echo "  ✅ PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ❌ FAIL: $1"; }

assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  case "$haystack" in
    *"$needle"*) pass "$label" ;;
    *) fail "$label"; echo "     期待する部分文字列: $needle"; echo "     実際: $haystack" ;;
  esac
}

assert_not_contains() {
  local label="$1" haystack="$2" needle="$3"
  case "$haystack" in
    *"$needle"*) fail "$label"; echo "     現れてはいけない部分文字列: $needle"; echo "     実際: $haystack" ;;
    *) pass "$label" ;;
  esac
}

# body を差し替えた gh shim を作り、その PATH で helper を実行して stderr を返す。
# 明示 repo と fixture の origin を一致させる。
LANE_STDERR=""
LANE_RC=0
run_lane_with_body() {
  local body="$1"; shift
  local bindir="$TEST_DIR/bin"
  mkdir -p "$bindir"
  printf '%s' "$body" > "$TEST_DIR/body.txt"
  cat > "$bindir/gh" <<'GH_SHIM'
#!/bin/bash
# issue view --json body --jq '.body' だけを模倣する。それ以外の呼び出しは失敗させ、
# helper が想定外の gh サブコマンドに依存し始めたらテストが落ちるようにする。
case "$1 $2" in
  "issue view")
    # helper は SSH host alias 環境で別リポジトリを引かないよう -R を必ず明示する契約。
    # shim 側で検査しないと -R を落とす回帰が素通りする。
    case "$*" in *" -R "*) ;; *) echo "gh shim: -R が指定されていません: $*" >&2; exit 1 ;; esac
    case "$*" in *" -R owner/repo "*) ;; *) echo "Could not resolve to an issue or pull request" >&2; exit 1 ;; esac
    cat "$RITE_TEST_BODY_FILE"; exit 0 ;;
  *) echo "unexpected gh invocation: $*" >&2; exit 1 ;;
esac
GH_SHIM
  chmod +x "$bindir/gh"
  LANE_STDERR=$(cd "$TEST_REPO" && RITE_TEST_BODY_FILE="$TEST_DIR/body.txt" PATH="$bindir:$PATH" \
    bash "$TARGET" --issue 42 --repo owner/repo "$@" 2>&1)
  LANE_RC=$?
}

# --repo 不在の呼出しは cwd から対象を推測せず停止する。
# 非 git ディレクトリで実行し gh repo view も失敗させることで owner/repo 解決を全滅させる。
run_lane_without_repo() {
  local bindir="$TEST_DIR/bin-norepo" cwd="$TEST_DIR/nongit"
  mkdir -p "$bindir" "$cwd"
  cat > "$bindir/gh" <<'GH_SHIM'
#!/bin/bash
case "$1 $2" in
  "repo view") echo "gh: not a repository" >&2; exit 1 ;;
  *) echo "unexpected gh invocation: $*" >&2; exit 1 ;;
esac
GH_SHIM
  chmod +x "$bindir/gh"
  LANE_STDERR=$(cd "$cwd" && PATH="$bindir:$PATH" bash "$TARGET" --issue 42 2>&1)
  LANE_RC=$?
}

# gh 自体を失敗させる shim (issue_fetch_failed 経路)。
run_lane_with_failing_gh() {
  local bindir="$TEST_DIR/bin-fail"
  mkdir -p "$bindir"
  # stderr に ESC と C1 (CSI U+009B の UTF-8 表現) を混ぜ、**複数行**にする。gh の stderr も
  # 第三者由来の外部入力なので診断へ出す前に canonical idiom を通す必要があり、その idiom が
  # `--keep-newline` を選んでいる理由は行構造の保持にある (既定モードは改行も潰すため、
  # 複数行の stderr が 1 行へ畳まれ、直後に emit する [CONTEXT] marker が行頭を失う)。
  cat > "$bindir/gh" <<'GH_SHIM'
#!/bin/bash
printf 'gh: authentication required \033[31m\ngh: second line \302\233 X\n' >&2
exit 1
GH_SHIM
  chmod +x "$bindir/gh"
  LANE_STDERR=$(cd "$TEST_REPO" && PATH="$bindir:$PATH" bash "$TARGET" --issue 42 --repo owner/repo 2>&1)
  LANE_RC=$?
}

echo "=== usage error: --issue は数値必須 (exit 2、marker を出さない) ==="

LANE_STDERR=$(bash "$TARGET" 2>&1); LANE_RC=$?
assert_contains "TC-1.1: --issue 欠落は ERROR" "$LANE_STDERR" "--issue は数値必須"
[ "$LANE_RC" -eq 2 ] && pass "TC-1.2: --issue 欠落の exit code は 2" \
  || fail "TC-1.2: --issue 欠落の exit code は 2 (実際: $LANE_RC)"
# usage error では marker を出さない。出すと caller が「判定が済んだ」と誤読し、consumer 側の
# helper_failed 既定（marker 不在時に full へ倒す）が発火しなくなる。
assert_not_contains "TC-1.3: usage error では COMPLEXITY_LANE marker を出さない" "$LANE_STDERR" "COMPLEXITY_LANE="

LANE_STDERR=$(bash "$TARGET" --issue abc 2>&1); LANE_RC=$?
assert_contains "TC-1.4: 非数値の --issue は ERROR" "$LANE_STDERR" "--issue は数値必須"
[ "$LANE_RC" -eq 2 ] && pass "TC-1.5: 非数値 --issue の exit code は 2" \
  || fail "TC-1.5: 非数値 --issue の exit code は 2 (実際: $LANE_RC)"

LANE_STDERR=$(bash "$TARGET" --issue 42 --bogus x 2>&1); LANE_RC=$?
assert_contains "TC-1.6: 未知フラグは ERROR" "$LANE_STDERR" "unknown argument"
[ "$LANE_RC" -eq 2 ] && pass "TC-1.7: 未知フラグの exit code は 2" \
  || fail "TC-1.7: 未知フラグの exit code は 2 (実際: $LANE_RC)"

echo "=== 記法 1: **Complexity**: X (Section 0 Meta) — AC-1 / AC-4 ==="

run_lane_with_body '**Type**: feat
**Complexity**: XS

## 1. Goal
なにか'
assert_contains "TC-2.1: XS は light レーン" "$LANE_STDERR" "COMPLEXITY_LANE=light; complexity=XS; source=body_meta"
assert_not_contains "TC-2.2: light では FALLBACK を出さない" "$LANE_STDERR" "COMPLEXITY_LANE_FALLBACK"
[ "$LANE_RC" -eq 0 ] && pass "TC-2.3: 正常系の exit code は 0" \
  || fail "TC-2.3: 正常系の exit code は 0 (実際: $LANE_RC)"

run_lane_with_body '**Complexity**: S'
assert_contains "TC-2.4: S も light レーン" "$LANE_STDERR" "COMPLEXITY_LANE=light; complexity=S"

# AC-4: M / L / XL は full。レーン境界がずれると M+ の検証深度が無言で落ちる。
run_lane_with_body '**Complexity**: M'
assert_contains "TC-2.5: M は full レーン" "$LANE_STDERR" "COMPLEXITY_LANE=full; complexity=M"
assert_not_contains "TC-2.6: M で light へ倒さない" "$LANE_STDERR" "COMPLEXITY_LANE=light"

run_lane_with_body '**Complexity**: L'
assert_contains "TC-2.7: L は full レーン" "$LANE_STDERR" "COMPLEXITY_LANE=full; complexity=L"

run_lane_with_body '**Complexity**: XL'
assert_contains "TC-2.8: XL は full レーン" "$LANE_STDERR" "COMPLEXITY_LANE=full; complexity=XL"

# 小文字入力の正規化。正規化を落とすと `xs` が complexity_invalid で full へ倒れ、
# 「レーンが効かない」形の silent degradation になる (fail-safe が誤りを隠す)。
run_lane_with_body '**Complexity**: xs'
assert_contains "TC-2.9: 小文字 xs は XS に正規化される" "$LANE_STDERR" "COMPLEXITY_LANE=light; complexity=XS"

# 行末コメントや余分な語があっても値だけを取る。
run_lane_with_body '**Complexity**: XS  <!-- 見積もり -->'
assert_contains "TC-2.10: 行末の付随テキストは無視される" "$LANE_STDERR" "complexity=XS"

echo "=== 記法 3: 表形式 Meta — 実運用 Issue の失敗形状 ==="

# で /rite:batch-run が open 段の fail-loud で停止した実 body の形をそのまま fixture にする
# (合成 body だけだと、行ラベル型の表・ヘッダ行・**Type** 行が混ざる実入力の形状取り違えを
#  検出できない)。この TC が修正前 red → 修正後 green に転じることが本 Issue の報告そのもの。
run_lane_with_body '## 0. Meta

| 項目 | 値 |
|---|---|
| **Type** | chore |
| **Complexity** | S |

## 1. Goal

なにか'
assert_contains "TC-3.5: 実運用の表形式 Meta から S を読む" "$LANE_STDERR" "COMPLEXITY_LANE=light; complexity=S; source=body_table"
assert_not_contains "TC-3.5b: 表形式で complexity_absent へ倒さない" "$LANE_STDERR" "complexity_absent"

# レーン境界は表形式でも同じ。M+ が light へ落ちると検証深度が無言で下がる。
run_lane_with_body '| **Complexity** | M |'
assert_contains "TC-3.6: 表形式の M は full レーン" "$LANE_STDERR" "COMPLEXITY_LANE=full; complexity=M; source=body_table"
assert_not_contains "TC-3.6b: 表形式の M で light へ倒さない" "$LANE_STDERR" "COMPLEXITY_LANE=light"

# 妥当性判定は `case` に委ねる (記法 1 と同じ規律)。needle は reason まで書き切る。
run_lane_with_body '| **Complexity** | Medium |'
assert_contains "TC-3.7: 表形式の Medium は complexity_invalid" "$LANE_STDERR" "COMPLEXITY_LANE=full; reason=complexity_invalid"

# 未展開 placeholder は記法 1 と同じ reason へ合流する (記法によって absent / invalid に分裂しない)。
run_lane_with_body '| **Complexity** | {complexity} |'
assert_contains "TC-3.8: 表形式の未展開 placeholder は complexity_absent" "$LANE_STDERR" "COMPLEXITY_LANE=full; reason=complexity_absent"

# 太字を落とした表セルは受理しない (記法 1 の「装飾の揺れは受理しない」と同じ規律)。太字を
# 要求しないと、行の途中で Complexity に言及するだけの表を宣言行と誤認する。
run_lane_with_body '| Complexity | S |'
assert_contains "TC-3.9: 太字なしの表セルは complexity_absent" "$LANE_STDERR" "COMPLEXITY_LANE=full; reason=complexity_absent"
assert_not_contains "TC-3.9b: 太字なしの表セルで light へ倒さない" "$LANE_STDERR" "COMPLEXITY_LANE=light"

echo "=== 記法 2: ## 複雑度 セクション — 3 記法併存の吸収 ==="

# 片方の記法しか読まないと、もう片方で書かれた Issue が全て complexity_absent へ落ちる。
# **body は実運用の形（複雑度節の前後を別の見出しが挟む）にする** — 先行見出しが無い body だけで
# 固めると、節境界述語から `f &&` を落とす崩れ（最初の見出しで即 exit し複雑度節へ到達しない）が
# 素通りし、Section 見出しを持つ Issue のほぼ全域で軽量レーンが発動しなくなる欠陥を検出できない。
run_lane_with_body '## 1. Goal

なにかを実装する

## 複雑度

S

## 次のセクション'
assert_contains "TC-3.1: ## 複雑度 セクションから S を読む (先行見出しあり)" "$LANE_STDERR" "COMPLEXITY_LANE=light; complexity=S; source=body_section"

run_lane_with_body '## 複雑度

- XL
'
assert_contains "TC-3.2: 箇条書き形式でも読む" "$LANE_STDERR" "COMPLEXITY_LANE=full; complexity=XL; source=body_section"

run_lane_with_body '## 複雑度

XS
'
assert_contains "TC-3.2b: 記法 2 の XS も light になる" "$LANE_STDERR" "COMPLEXITY_LANE=light; complexity=XS; source=body_section"

# 抽出は**行頭側から最初のトークン**を採る。greedy な `.*` に戻すと行内最後を拾い、
# 宣言 M が S へ解決されて M+ が silent に light へ落ちる (AC-4 / MUST NOT 違反)。
run_lane_with_body '## 複雑度

M（S ではない）
'
assert_contains "TC-3.2c: 宣言値の後ろに根拠を書いた行でも宣言値を採る" "$LANE_STDERR" "COMPLEXITY_LANE=full; complexity=M"
assert_not_contains "TC-3.2d: 行内後方のトークンを拾って light へ倒さない" "$LANE_STDERR" "COMPLEXITY_LANE=light"

# 値は英字トークン全体として切り出す。長さを 1-2 文字に制限すると `XSmall` が `XS` に
# 切り詰められ、宣言していない light レーンへ落ちる。needle は reason まで書き切る
# (`reason=complexity_` で打ち切ると absent と invalid を区別できず、docstring の宣言と
#  実挙動が食い違っても green のまま通る。同じ規範を TC-4.8 側でも明記している)。
run_lane_with_body '**Complexity**: XSmall'
assert_not_contains "TC-2.11: XSmall を XS に切り詰めて light へ倒さない" "$LANE_STDERR" "COMPLEXITY_LANE=light"
assert_contains "TC-2.12: XSmall はトークン全体で取り出され complexity_invalid になる" "$LANE_STDERR" "COMPLEXITY_LANE=full; reason=complexity_invalid"

# 抽出式が POSIX BRE だけで書かれていること (GNU 拡張の混入を authoring 時点で pin する)。
# BSD/macOS sed はこれらを無警告に不一致とするため、混入すると当該環境で全 Issue が
# complexity_absent へ倒れレーンが一度も発動しない。CI の macos leg は本経路を踏むが
# `continue-on-error: true` で PR を止めないため、**本 probe が唯一の blocking な番人**である。
#
# haystack は「コメント以外の本文全体」で取る。`sed -n` を含む行だけに絞ると、式を継続行へ
# 折り返しただけで走査対象から外れて GNU 拡張が素通りする (実測済み)。コメント行を除くのは、
# GNU 拡張を禁じている散文コメント自身が needle に一致して恒常 fail するのを避けるため。
LANE_BODY_LINES=$(grep -vn '^[[:space:]]*#' "$TARGET")
# haystack が空だと assert_not_contains は常に PASS する (無検査の vacuous pass)。
# 探し方が壊れた瞬間に番人だけが消えるので、非空を precondition として先に確かめる。
if [ -n "$LANE_BODY_LINES" ]; then
  pass "TC-2.13a: 抽出式の走査対象 (コメント以外の本文) を特定できる"
else
  fail "TC-2.13a: 抽出式の走査対象が空 — 以降の GNU 拡張 probe が無検査で PASS する"
fi
# denylist は「POSIX BRE のみ」という宣言した規範に対して網羅する。`\b` / `\|` だけを挙げると、
# 同じ GNU BRE 拡張クラスで**最も自然な書き換え形**である `[A-Za-z]\+` が素通りする (実測済み)。
for _gnu_ext in '\+' '\?' '\|' '\b' '\w' '\s' '\<' '\>'; do
  assert_not_contains "TC-2.13: 本文に GNU BRE 拡張 ($_gnu_ext) を使わない" "$LANE_BODY_LINES" "$_gnu_ext"
done

# 記法 1 が存在するときは記法 1 を優先する (source= で区別できること自体が観測性の要求)。
run_lane_with_body '**Complexity**: M

## 複雑度

XS'
assert_contains "TC-3.3: 記法 1 が記法 2 より優先される" "$LANE_STDERR" "complexity=M; source=body_meta"

# 記法 1 は記法 3 にも優先する。helper は code fence を剥がさないため、優先順が崩れると
# **表記法そのものを説明している Issue** (本文中に表形式の例を載せる) が例から値を解決する。
# 本 Issue の body がまさにこの形なので、崩れは実運用で即座に誤判定になる。
run_lane_with_body '**Complexity**: M

例として次の形が実在する:

| **Complexity** | XS |'
assert_contains "TC-3.3b: 記法 1 が記法 3 より優先される (本文中の例から解決しない)" "$LANE_STDERR" "complexity=M; source=body_meta"
assert_not_contains "TC-3.3c: 例の表を採って light へ倒さない" "$LANE_STDERR" "COMPLEXITY_LANE=light"

# 記法 2 も記法 3 に優先する (探索順 1 → 2 → 3)。表行は body のどこにでも現れうるので最後に読む。
# 順序を 2 と 3 で入れ替えると、`## 複雑度` で M を宣言した Issue が本文中の表の例から XS を採り
# **M+ が silent に light へ落ちる** (AC-4 / MUST NOT 違反)。not_contains を併記して方向を固定する。
run_lane_with_body '## 複雑度

M

## 記法の説明

| **Complexity** | XS |'
assert_contains "TC-3.3d: 記法 2 が記法 3 より優先される (本文中の例から解決しない)" "$LANE_STDERR" "complexity=M; source=body_section"
assert_not_contains "TC-3.3e: 記法 2 宣言時に例の表を採って light へ倒さない" "$LANE_STDERR" "COMPLEXITY_LANE=light"

# 記法 2 宣言 + 文書用の表ヘッダ (値セルが英語の説明語) でも宣言値を採る。順序が崩れると
# 説明語 (`Projects`) を値として捕捉し complexity_invalid へ落ちる (倒れる向きは fail-safe だが、
# 宣言済み Issue でレーンが発動しなくなる)。本形の表は issue-edit/SKILL.md に実在する。
run_lane_with_body '## 複雑度

M

## フィールド対応

| **Complexity** | Projects Complexity field |'
assert_contains "TC-3.3f: 記法 2 宣言は文書用の表ヘッダに優先する" "$LANE_STDERR" "complexity=M; source=body_section"

# 記法 3 の `head -1` を pin する。宣言の表行の後ろに例の表行が続く形 (系 Issue が
# 表記法を併記する形) で、落とすと _raw が改行込み 2 値になり complexity_invalid へ倒れる。
run_lane_with_body '## 0. Meta

| 項目 | 値 |
|---|---|
| **Complexity** | S |

## 参考

| **Complexity** | XS |'
assert_contains "TC-3.3g: 記法 3 は先頭の表行を採る (head -1)" "$LANE_STDERR" "COMPLEXITY_LANE=light; complexity=S; source=body_table"
assert_not_contains "TC-3.3h: 複数の表行を連結して complexity_invalid へ倒さない" "$LANE_STDERR" "complexity_invalid"

echo "=== fail-safe: 情報欠落は全経路で full へ倒れる (AC-2 / T-02) ==="

echo "=== repository context: 隣の repo を黙って使わない ==="
foreign_repo="$TEST_DIR/foreign"
git init -q "$foreign_repo"
git -C "$foreign_repo" remote add origin https://github.com/other/project.git
run_lane_with_body '**Complexity**: S'
LANE_STDERR=$(cd "$foreign_repo" && RITE_TEST_BODY_FILE="$TEST_DIR/body.txt" PATH="$TEST_DIR/bin:$PATH" bash "$TARGET" --issue 42 --repo owner/repo 2>&1); LANE_RC=$?
[ "$LANE_RC" -eq 1 ] && pass "repo 不一致は非ゼロで止まる" || fail "repo 不一致を正常扱いしない (rc=$LANE_RC)"
assert_contains "食い違いの原因を名指しする" "$LANE_STDERR" "repository context mismatch"
assert_not_contains "食い違いを full fallback にしない" "$LANE_STDERR" "COMPLEXITY_LANE="
LANE_STDERR=$(cd "$foreign_repo" && PATH="$TEST_DIR/bin:$PATH" bash "$TARGET" --issue 42 2>&1); LANE_RC=$?
[ "$LANE_RC" -eq 1 ] && pass "--repo 不在で cwd に推測を委ねない" || fail "--repo 不在を正常扱いしない (rc=$LANE_RC)"
assert_not_contains "--repo 不在で full fallback にしない" "$LANE_STDERR" "COMPLEXITY_LANE="
LANE_STDERR=$(cd "$TEST_DIR" && PATH="$TEST_DIR/bin:$PATH" bash "$TARGET" --issue 42 --repo owner/repo 2>&1); LANE_RC=$?
[ "$LANE_RC" -eq 1 ] && pass "cwd repo 解決不能は停止する" || fail "cwd repo 解決不能を正常扱いしない (rc=$LANE_RC)"
assert_contains "解決不能の原因を出す" "$LANE_STDERR" "cannot resolve cwd repository"

# reason 語彙は helper docstring が SoT。各 reason が確かに full へ倒れることを個別に pin する
# (まとめて 1 件だけ検証すると、特定 reason だけが light へ倒れる回帰を見逃す)。

run_lane_with_body '## 1. Goal

Complexity の記載が無い Issue'
assert_contains "TC-4.1: 記載なしは complexity_absent" "$LANE_STDERR" "COMPLEXITY_LANE=full; reason=complexity_absent"
assert_contains "TC-4.2: complexity_absent は FALLBACK marker を伴う" "$LANE_STDERR" "COMPLEXITY_LANE_FALLBACK=1; reason=complexity_absent"
assert_contains "TC-4.3: complexity_absent は人間向け WARNING を伴う" "$LANE_STDERR" "⚠️ Complexity レーン判定のフォールバック"
assert_not_contains "TC-4.4: complexity_absent で light へ倒さない" "$LANE_STDERR" "COMPLEXITY_LANE=light"
[ "$LANE_RC" -eq 0 ] && pass "TC-4.5: fail-safe でも exit code は 0 (レビュー自体を失敗させない)" \
  || fail "TC-4.5: fail-safe でも exit code は 0 (実際: $LANE_RC)"

run_lane_with_body '**Complexity**: ZZ'
assert_contains "TC-4.6: 未知の値は complexity_invalid" "$LANE_STDERR" "COMPLEXITY_LANE=full; reason=complexity_invalid"
assert_not_contains "TC-4.7: complexity_invalid で light へ倒さない" "$LANE_STDERR" "COMPLEXITY_LANE=light"

# 未展開の placeholder は「テンプレートのまま起票された」ことを示す。値として通してはならない。
# needle は reason まで書き切る。`reason=complexity_` で打ち切ると absent と invalid を
# 区別できず、docstring の宣言と実挙動が食い違っても green のまま通る。
run_lane_with_body '**Complexity**: {complexity}'
assert_contains "TC-4.8: 未展開 placeholder は complexity_absent (英字以外は抽出式が受理しない)" "$LANE_STDERR" "COMPLEXITY_LANE=full; reason=complexity_absent"
assert_not_contains "TC-4.8b: 未展開 placeholder で light へ倒さない" "$LANE_STDERR" "COMPLEXITY_LANE=light"

# 記法 2 でも同じ記入漏れが同じ reason になること。記法 2 の抽出は先頭の装飾を読み飛ばすため、
# `{` / `<` を読み飛ばし対象に含めると placeholder の中身や HTML コメントの語を値として捕捉し、
# 同一の欠陥が記法によって absent / invalid へ分裂する (reason は AC-5 の分母を数える観測値)。
run_lane_with_body '## 複雑度

{complexity}'
assert_contains "TC-4.8c: 記法 2 の未展開 placeholder も complexity_absent" "$LANE_STDERR" "COMPLEXITY_LANE=full; reason=complexity_absent"
run_lane_with_body '## 複雑度

<!-- TODO: 未記入 -->'
assert_contains "TC-4.8d: 記法 2 の HTML コメントも complexity_absent" "$LANE_STDERR" "COMPLEXITY_LANE=full; reason=complexity_absent"
# 空の複雑度節は次の見出しへ跨がない。跨ぐと英字見出しだけが値として捕捉され、同じ記入漏れが
# **見出し語の言語**で absent / invalid に分裂する (診断側の節境界と対称)。
run_lane_with_body '## 複雑度

## Impact'
assert_contains "TC-4.8e: 空の複雑度節は英字の次節見出しを値として捕捉しない" "$LANE_STDERR" "COMPLEXITY_LANE=full; reason=complexity_absent"
run_lane_with_body '## 複雑度

## 影響範囲'
assert_contains "TC-4.8f: 日本語の次節見出しでも同じ reason になる" "$LANE_STDERR" "COMPLEXITY_LANE=full; reason=complexity_absent"

echo "=== complexity_absent の行番号 WARNING (崩れた記法と宣言不在の切り分け) ==="

# 崩れた記法では対象行の**行番号**を報告する。裸のキーワード検索に戻すと lowercase key が
# 無音になるため 4 形すべてを個別に pin し、needle には固定の接頭辞ではなく**行番号**まで含める
# (接頭辞だけを needle にすると、行番号の算出をどう壊しても落ちない空振り assert になる)。
# 各 body は宣言行を 2 行目に置き、期待値 2 が偶然一致しないようにする。
for _broken in '**complexity**: XS' '**Complexity**： XS' '- **Complexity**: XS' 'Complexity: XS'; do
  run_lane_with_body "冒頭の散文行
$_broken"
  assert_contains "TC-4.16: 崩れた記法 ($_broken) は行番号を報告する" "$LANE_STDERR" "body の 2 行目から値を取り出せませんでした"
done

# 表形式 (記法 3) の崩れも同じ経路で可視化する。抽出側が太字を要求して棄却するだけだと、
# その棄却が**無音**になり本 WARNING の目的が記法 3 でだけ果たされない (reason だけを見る
# assert では、診断の述語を表行へ広げる変更を丸ごと削除しても green のまま通る)。
for _broken_row in '| Complexity | XS |' '| complexity | XS |' '| **Complexity** | {complexity} |' '| **複雑度** | XS |'; do
  run_lane_with_body "冒頭の散文行
$_broken_row"
  assert_contains "TC-4.16b: 崩れた表行 ($_broken_row) は行番号を報告する" "$LANE_STDERR" "body の 2 行目から値を取り出せませんでした"
done

# 宣言行が無い body では沈黙する。行の形を問わない検索に戻すと散文・表セルの単なる言及を
# 「宣言らしき記述」と誤って断定し、この WARNING の目的 (定常出力からの切り分け) が消える。
# 3 形目は**行中に「キー + コロン」を持つ**散文で、述語から行頭 anchor を外す mutant を落とす
# (前 2 形はキーと区切り記号が連続しないため、区切り記号の腕しか検査していなかった)。
# 4 形目は**行頭が `|` の表行だがキーが先頭セルでない** mid-row 形。抽出側 (記法 3 の sed) と
# 診断側 (awk の表行規則) はどちらも行頭 anchor でキーが先頭セルであることを要求しており、
# その anchor を外す mutant はこの形でしか落ちない (実測: anchor を `.*` に緩めると抽出側は
# reason を complexity_invalid へ分裂させ、診断側は本 WARNING を定常出力化する)。本 PR が
# 書いた issue-implement/SKILL.md の表セルがまさにこの形なので、同種の散文が Issue body に
# 貼られた時点で発火する。reason まで assert して absent/invalid の分裂も同時に pin する。
for _prose in 'この変更の複雑度は低いが影響範囲は広い。' '| A | /rite:issue-create | Complexity M。 |' '判定キーは Complexity: の有無である。' '| 判定 | helper が 3 記法 (`| **Complexity** | X |`) を受理する | Meta 節 |'; do
  run_lane_with_body "$_prose"
  assert_not_contains "TC-4.17: 宣言行の無い散文 ($_prose) では報告しない" "$LANE_STDERR" "値を取り出せませんでした"
  assert_contains "TC-4.17b: 宣言行の無い散文 ($_prose) は complexity_absent" "$LANE_STDERR" "COMPLEXITY_LANE=full; reason=complexity_absent"
done

# 記法 2 では見出しではなく**値を取り出せなかった行**を指す。見出しは解釈できているので、
# 名指しても是正先にならない。ここでは値行が 4 行目 (見出し 2 / 空行 3 / 値 4)。
run_lane_with_body "冒頭の散文行
## 複雑度

{complexity}"
assert_contains "TC-4.19: 記法 2 は見出しではなく値行の行番号を報告する" "$LANE_STDERR" "body の 4 行目から値を取り出せませんでした"

# 節に値行が 1 行も無い形では見出し自身へ退避する。退避しないと記入漏れの `## 複雑度` 節が
# 宣言不在と区別できず、さらに節境界が無いと無関係な次節見出しを是正先として提示する。
# **どちらの body も見出しを 2 行目に置く** — 見出しが 1 行目だと期待値 1 が定数化した実装とも
# 一致してしまい、退避先の算出をどう壊しても落ちない空振り assert になる (同ファイル冒頭で
# 崩れた記法の fixture に課しているのと同じ規律)。TC-4.19c は見出しの後ろに空白のみの行を置き、
# 期待値 2 が「最終行の NR」(= 3) とも異なる値になるようにする。
run_lane_with_body '冒頭の散文行
## 複雑度

## 影響範囲'
assert_contains "TC-4.19b: 空の複雑度節は次節見出しではなく見出し自身を報告する" "$LANE_STDERR" "body の 2 行目から値を取り出せませんでした"
run_lane_with_body '冒頭の散文行
## 複雑度
   '
assert_contains "TC-4.19c: 値行が空白のみでも沈黙せず見出しの行番号を報告する" "$LANE_STDERR" "body の 2 行目から値を取り出せませんでした"

# CRLF の body。awk の既定 FS は `\r` を含まないため、入力側で CR を落とさないと CR だけの行が
# 非空行と数えられ、記法 2 が値行に到達できず XS 宣言でも軽量レーンが発動しない。
run_lane_with_body "$(printf '## 複雑度\r\n\r\nXS\r')"
assert_contains "TC-4.20: CRLF の body でも記法 2 が値行に到達する" "$LANE_STDERR" "COMPLEXITY_LANE=light; complexity=XS; source=body_section"

# 診断は body の中身を一切載せない。body は第三者が書ける外部入力で、切り分けという目的は
# 行番号だけで果たせるため、外部入力が診断チャネルへ入る経路自体を持たない。
run_lane_with_body "$(printf '**Complexity**: \033[31mZZZ_SENTINEL \302\233 CR\r')"
assert_not_contains "TC-4.18: 診断に body の中身を載せない (可視文字)" "$LANE_STDERR" "ZZZ_SENTINEL"
assert_not_contains "TC-4.18b: 診断に ESC を載せない" "$LANE_STDERR" "$(printf '\033')"
assert_not_contains "TC-4.18c: 診断に C1 (CSI U+009B) を載せない" "$LANE_STDERR" "$(printf '\302\233')"
assert_contains "TC-4.18d: それでも崩れた記法として行番号は報告する" "$LANE_STDERR" "body の 1 行目から値を取り出せませんでした"

# repo_unresolved は **production の実経路**（pr-review 1.3.2 / issue-implement 5.0.C は
# --repo を渡さない）にある唯一の reason で、他 4 reason と違い --repo 明示では到達しない。
# ここを runtime で pin しないと、guard を light 固定にする mutant が素通りする。
run_lane_without_repo
assert_contains "TC-4.9a: 明示 repo 不在は repo_unresolved" "$LANE_STDERR" "repo_unresolved"
assert_not_contains "TC-4.9b: 解決不能を fallback にしない" "$LANE_STDERR" "COMPLEXITY_LANE="
[ "$LANE_RC" -eq 1 ] && pass "TC-4.9c: 解決不能で停止" || fail "TC-4.9c: rc=$LANE_RC"

run_lane_with_failing_gh
assert_contains "TC-4.10: gh 失敗は issue_fetch_failed" "$LANE_STDERR" "COMPLEXITY_LANE=full; reason=issue_fetch_failed"
# 取得失敗と「body に記載が無い」を混同すると、認証切れが Issue 側の不備として報告される。
assert_not_contains "TC-4.11: gh 失敗を complexity_absent と誤報告しない" "$LANE_STDERR" "reason=complexity_absent"
assert_contains "TC-4.12: gh の stderr を診断として surface する" "$LANE_STDERR" "authentication required"
# surface するだけでなく中和して出す。`--c0-only` へ差し替える mutant は C1 側で落ちる
# (同モードは valid UTF-8 の C1 を素通しする)。
assert_not_contains "TC-4.12b: gh stderr の ESC を素通ししない" "$LANE_STDERR" "$(printf '\033')"
assert_not_contains "TC-4.12c: gh stderr の C1 (CSI U+009B) を素通ししない" "$LANE_STDERR" "$(printf '\302\233')"
# 中和は通すが行構造は保つ。`--keep-newline` を落として既定モードにすると改行も `?` へ潰れ、
# 2 行目の行頭 2 空白 (sed が行ごとに付ける) が消えて本 assert が落ちる。
assert_contains "TC-4.12d: gh stderr の行構造を保つ" "$LANE_STDERR" "$(printf '\n  gh: second line')"
[ "$LANE_RC" -eq 0 ] && pass "TC-4.13: issue_fetch_failed でも exit code は 0" \
  || fail "TC-4.13: issue_fetch_failed でも exit code は 0 (実際: $LANE_RC)"

echo "=== Projects の Complexity フィールド (本文に次ぐ 2 番目の入力源) ==="

# rite-config.yml を toplevel に置いた別 repo。既存の TEST_REPO は設定を持たない = 連携無効のまま
# 残し、従来経路で gh の追加呼び出しが 0 回であることを既存 shim (issue view 以外は失敗) で保つ。
PJ_REPO="$TEST_DIR/pj-repo"
PJ_BIN="$TEST_DIR/bin-pj"
mkdir -p "$PJ_REPO" "$PJ_BIN"
git init -q "$PJ_REPO"
git -C "$PJ_REPO" remote add origin https://github.com/owner/repo.git
cat > "$PJ_BIN/gh" <<'GH_SHIM'
#!/bin/bash
# issue view は本文を、api graphql は fixture JSON に helper の --jq 式を適用した結果を返す。
# graphql の引数 (owner / repo / Issue 番号) を検査し、照会先の取り違えを素通りさせない。
case "$1 $2" in
  "issue view")
    case "$*" in *" -R owner/repo "*) ;; *) echo "gh shim: -R が想定外: $*" >&2; exit 1 ;; esac
    cat "$RITE_TEST_BODY_FILE"; exit 0 ;;
  "api graphql")
    case "$*" in *" owner=owner "*" repo=repo "*" number=42 "*) ;; *) echo "gh shim: graphql 引数が想定外: $*" >&2; exit 1 ;; esac
    if [ -n "${RITE_TEST_PJ_FAIL:-}" ]; then echo "gh: GraphQL: API rate limit exceeded" >&2; exit 1; fi
    jq_expr=""; prev=""
    for a in "$@"; do [ "$prev" = "--jq" ] && jq_expr="$a"; prev="$a"; done
    jq -r "$jq_expr" "$RITE_TEST_PJ_FILE"; exit $? ;;
  *) echo "unexpected gh invocation: $*" >&2; exit 1 ;;
esac
GH_SHIM
chmod +x "$PJ_BIN/gh"

# $1=enabled $2=project_number $3=fields.complexity 節の本文 (8 空白インデント)
pj_config() {
  cat > "$PJ_REPO/rite-config.yml" <<EOF
github:
  projects:
    enabled: $1
    project_number: $2  # Project 番号
    owner: "owner"
    fields:
      status:
        enabled: true
      complexity:
${3:-        enabled: true}
EOF
}
# 1 item の JSON。$1=project 番号、以降は「フィールド名=値」。先頭の {} は single-select 以外の値の形。
pj_item() {
  local num="$1" nodes="{}" kv; shift
  for kv in "$@"; do
    nodes="$nodes,$(jq -cn --arg f "${kv%%=*}" --arg v "${kv#*=}" '{field: {name: $f}, name: $v}')"
  done
  printf '{"project":{"number":%s},"fieldValues":{"nodes":[%s]}}' "$num" "$nodes"
}
pj_items() {
  local IFS=,
  printf '{"data":{"repository":{"issue":{"projectItems":{"nodes":[%s]}}}}}' "$*" > "$TEST_DIR/pj.json"
}
run_pj() {
  printf '%s' "$1" > "$TEST_DIR/body.txt"
  LANE_STDERR=$(cd "$PJ_REPO" && RITE_TEST_BODY_FILE="$TEST_DIR/body.txt" RITE_TEST_PJ_FILE="$TEST_DIR/pj.json" \
    RITE_TEST_PJ_FAIL="${PJ_FAIL:-}" PATH="$PJ_BIN:$PATH" bash "$TARGET" --issue 42 --repo owner/repo 2>&1)
  LANE_RC=$?
}
NO_DECL='## 1. Goal

Complexity の記載が無い Issue'

pj_config true 11
# 別 project の item を先に置き、食い違う値を持たせる。project_number で絞らない実装はここで M を拾う。
pj_items "$(pj_item 99 Complexity=M)" "$(pj_item 11 Status=Todo Complexity=S)"
run_pj "$NO_DECL"
assert_contains "TC-6.1: 本文に宣言が無ければ Projects の値を使う" "$LANE_STDERR" "[CONTEXT] COMPLEXITY_LANE=light; complexity=S; source=projects_field"
assert_not_contains "TC-6.1b: Projects の値で決まれば fallback ではない" "$LANE_STDERR" "COMPLEXITY_LANE_FALLBACK"
[ "$LANE_RC" -eq 0 ] && pass "TC-6.1c: Projects 由来でも exit 0" || fail "TC-6.1c: rc=$LANE_RC"

pj_items "$(pj_item 11 Complexity=M)"
run_pj '**Complexity**: M'
assert_contains "TC-6.2: 本文と Projects が一致すれば本文由来で通る" "$LANE_STDERR" "COMPLEXITY_LANE=full; complexity=M; source=body_meta"
[ "$LANE_RC" -eq 0 ] && pass "TC-6.2b: 一致は exit 0" || fail "TC-6.2b: rc=$LANE_RC"

pj_items "$(pj_item 11 Complexity=S)"
run_pj '**Complexity**: M'
[ "$LANE_RC" -eq 1 ] && pass "TC-6.3: 本文と Projects の食い違いは exit 1 で止まる" || fail "TC-6.3: rc=$LANE_RC"
assert_contains "TC-6.3b: 食い違いの reason を名指しする" "$LANE_STDERR" "complexity_mismatch"
assert_contains "TC-6.3c: 両方の値を同じ行に示す" "$LANE_STDERR" "(本文=M; Projects=S)"
assert_not_contains "TC-6.3d: 食い違いでレーンを出さない (consumer が判定済みと読まない)" "$LANE_STDERR" "COMPLEXITY_LANE="

pj_items "$(pj_item 11 Status=Todo)"
run_pj "$NO_DECL"
assert_contains "TC-6.4: どちらにも値が無ければ complexity_absent" "$LANE_STDERR" "COMPLEXITY_LANE=full; reason=complexity_absent"
assert_contains "TC-6.4b: 追記する 1 行の書式を示す" "$LANE_STDERR" "追記してください (値は XS / S / M / L / XL のいずれか): **Complexity**: M"
assert_contains "TC-6.4c: 本文の宣言を探したことを示す" "$LANE_STDERR" "探した場所: Issue 本文の宣言"
assert_contains "TC-6.4d: Projects のフィールドを探したことを候補名つきで示す" "$LANE_STDERR" "Projects #11 の Complexity フィールド (候補名: 複雑度, Complexity)"
assert_not_contains "TC-6.4e: 宣言不在の案内は崩れた記法の行番号 WARNING と別物" "$LANE_STDERR" "値を取り出せませんでした"
[ "$LANE_RC" -eq 0 ] && pass "TC-6.4f: 欠落は従来どおり exit 0 (pr-review / issue-implement は full で続行)" || fail "TC-6.4f: rc=$LANE_RC"

pj_items "$(pj_item 99 Complexity=S)"
run_pj "$NO_DECL"
assert_contains "TC-6.4g: Project 未登録は値なしとして扱う" "$LANE_STDERR" "COMPLEXITY_LANE=full; reason=complexity_absent"
assert_contains "TC-6.4h: Project 未登録であることを案内に含める" "$LANE_STDERR" "Issue は Project に未登録"

# 連携無効では Projects を探したと言わない。TEST_REPO は rite-config.yml を持たない。
run_lane_with_body "$NO_DECL"
assert_contains "TC-6.4i: 設定ファイルが無ければ Projects は未参照と示す" "$LANE_STDERR" "Projects 連携は無効のため Projects は参照していません"
assert_not_contains "TC-6.4j: 設定ファイルが無ければ候補名を出さない" "$LANE_STDERR" "候補名"
pj_config false 11
pj_items "$(pj_item 11 Complexity=S)"
run_pj "$NO_DECL"
assert_contains "TC-6.4k: enabled: false なら Projects の値を読まない" "$LANE_STDERR" "COMPLEXITY_LANE=full; reason=complexity_absent"
assert_contains "TC-6.4l: enabled: false でも未参照と示す" "$LANE_STDERR" "Projects 連携は無効のため"
pj_config true 11 '        enabled: false'
run_pj "$NO_DECL"
assert_contains "TC-6.4m: fields.complexity.enabled: false は連携無効扱い" "$LANE_STDERR" "Projects 連携は無効のため"
assert_not_contains "TC-6.4n: fields.complexity.enabled: false で Projects の値を使わない" "$LANE_STDERR" "source=projects_field"

pj_config true 11
pj_items "$(pj_item 11 "Complexity=$(printf 'Medium ZZZ_PJ \033[31m')")"
run_pj "$NO_DECL"
assert_contains "TC-6.5: Projects の値が不正な綴りなら complexity_invalid" "$LANE_STDERR" "COMPLEXITY_LANE=full; reason=complexity_invalid"
assert_not_contains "TC-6.5b: 診断に Projects の生値を載せない" "$LANE_STDERR" "ZZZ_PJ"
assert_not_contains "TC-6.5c: 診断に ESC を載せない" "$LANE_STDERR" "$(printf '\033')"

PJ_FAIL=1 run_pj "$NO_DECL"
assert_contains "TC-6.6: Projects の取得失敗は projects_fetch_failed" "$LANE_STDERR" "COMPLEXITY_LANE=full; reason=projects_fetch_failed"
assert_not_contains "TC-6.6b: 取得失敗を値なしと誤報告しない" "$LANE_STDERR" "reason=complexity_absent"
assert_contains "TC-6.6c: gh の stderr を診断として出す" "$LANE_STDERR" "API rate limit exceeded"
[ "$LANE_RC" -eq 0 ] && pass "TC-6.6d: projects_fetch_failed は exit 0" || fail "TC-6.6d: rc=$LANE_RC"

pj_items "$(pj_item 99 Complexity=M)"
run_pj '**Complexity**: S'
assert_contains "TC-6.7: 本文あり・Project 未登録は本文由来" "$LANE_STDERR" "COMPLEXITY_LANE=light; complexity=S; source=body_meta"
pj_items "$(pj_item 11 Status=Todo)"
run_pj '**Complexity**: S'
assert_contains "TC-6.7b: 本文あり・Projects 値なしは本文由来" "$LANE_STDERR" "COMPLEXITY_LANE=light; complexity=S; source=body_meta"
assert_not_contains "TC-6.7c: 本文があれば欠落の案内を出さない" "$LANE_STDERR" "Complexity が見つかりません"
pj_items "$(pj_item 11 "Complexity=ZZZ_PJ")"
run_pj '**Complexity**: S'
assert_contains "TC-6.8: 本文あり・Projects 不正綴りは本文由来" "$LANE_STDERR" "COMPLEXITY_LANE=light; complexity=S; source=body_meta"
assert_contains "TC-6.8b: Projects の不正値を WARNING で知らせる" "$LANE_STDERR" "いずれでもないため、本文の宣言 (S) だけで判定しました"
assert_not_contains "TC-6.8c: WARNING に Projects の生値を載せない" "$LANE_STDERR" "ZZZ_PJ"
PJ_FAIL=1 run_pj '**Complexity**: S'
assert_contains "TC-6.9: 本文あり・取得失敗は本文由来" "$LANE_STDERR" "COMPLEXITY_LANE=light; complexity=S; source=body_meta"
assert_contains "TC-6.9b: 一致を確かめていないことを WARNING で知らせる" "$LANE_STDERR" "本文との一致を確かめずに"
pj_items "$(pj_item 11 Complexity=S)"
run_pj '**Complexity**: ZZ'
assert_contains "TC-6.10: 本文の不正綴りを Projects の値で補わない" "$LANE_STDERR" "COMPLEXITY_LANE=full; reason=complexity_invalid"
assert_not_contains "TC-6.10b: 本文の不正綴りで Projects 由来にしない" "$LANE_STDERR" "source=projects_field"
# 崩れた宣言（値を取り出せない形）は「宣言が無い」ではない。Projects の値で補うと、本文の M が
# Projects の S で黙って上書きされて light に落ちる。宣言行は 2 行目に置き、行番号が定数と一致しないようにする。
pj_items "$(pj_item 11 Complexity=S)"
run_pj '冒頭の散文行
**complexity**: M'
assert_contains "TC-6.10d: 崩れた宣言は Projects の値で補わず complexity_absent" "$LANE_STDERR" "COMPLEXITY_LANE=full; reason=complexity_absent"
assert_contains "TC-6.10e: 崩れた宣言の行番号 WARNING を出す" "$LANE_STDERR" "body の 2 行目から値を取り出せませんでした"
assert_not_contains "TC-6.10f: 崩れた宣言で Projects 由来にしない" "$LANE_STDERR" "source=projects_field"
# Projects の値を見つけたうえで使っていないので、「探して見つからなかった」と書かず、本文の宣言を直す案内にする。
assert_contains "TC-6.10g: Projects の値を使っていない理由を示す" "$LANE_STDERR" "Projects #11 の Complexity フィールドは、本文 2 行目の宣言を読めないため使っていません"
assert_contains "TC-6.10h: 追記ではなく宣言の行を直す案内を出す" "$LANE_STDERR" "本文 2 行目の宣言を次の書式に直してください"
assert_not_contains "TC-6.10i: Projects の候補名を探した場所として出さない" "$LANE_STDERR" "候補名"
# 取得失敗でも同じく、崩れた宣言を Projects で補わない (projects_fetch_failed ではなく complexity_absent)。
PJ_FAIL=1 run_pj '冒頭の散文行
**complexity**: M'
assert_contains "TC-6.10j: 崩れた宣言 + 取得失敗も complexity_absent" "$LANE_STDERR" "COMPLEXITY_LANE=full; reason=complexity_absent"
pj_items "$(pj_item 11 Complexity=ZZZ_PJ)"
run_pj '冒頭の散文行
**complexity**: M'
assert_contains "TC-6.10k: 崩れた宣言 + Projects 不正値も complexity_absent" "$LANE_STDERR" "COMPLEXITY_LANE=full; reason=complexity_absent"
# 連携無効では、崩れた宣言があっても Projects を参照したとは言わない。
pj_config false 11
pj_items "$(pj_item 11 Complexity=S)"
run_pj '冒頭の散文行
**complexity**: M'
assert_contains "TC-6.10l: 崩れた宣言 + 連携無効は未参照と示す" "$LANE_STDERR" "Projects 連携は無効のため Projects は参照していません"
assert_not_contains "TC-6.10m: 崩れた宣言 + 連携無効で Projects の値を使っていないと言わない" "$LANE_STDERR" "使っていません"
# rite-config.yml を読めない (ディレクトリになっている) ときは Projects を確かめられない。
rm -f "$PJ_REPO/rite-config.yml"
mkdir "$PJ_REPO/rite-config.yml"
run_pj "$NO_DECL"
assert_contains "TC-6.10n: 設定を読めなければ projects_fetch_failed" "$LANE_STDERR" "COMPLEXITY_LANE=full; reason=projects_fetch_failed"
assert_contains "TC-6.10o: 設定を読めないことを WARNING で示す" "$LANE_STDERR" "rite-config.yml を読めないため Projects の Complexity を確認できません"
run_pj '冒頭の散文行
**complexity**: M'
assert_contains "TC-6.10p: 崩れた宣言 + 設定を読めないは complexity_absent" "$LANE_STDERR" "COMPLEXITY_LANE=full; reason=complexity_absent"
assert_contains "TC-6.10q: 設定を読めないときは Projects を参照していないと示す" "$LANE_STDERR" "rite-config.yml を読めないため Projects は参照していません"
assert_not_contains "TC-6.10r: 設定を読めないときに Project 番号の無い案内を出さない" "$LANE_STDERR" "Projects # の"
rmdir "$PJ_REPO/rite-config.yml"
pj_config true 11
# 応答に Issue が無いのは取得できなかった扱いで、Project 未登録 (値なし) とは区別する。
printf '%s' '{"data":{"repository":{"issue":null}}}' > "$TEST_DIR/pj.json"
run_pj "$NO_DECL"
assert_contains "TC-6.10s: 応答に Issue が無ければ projects_fetch_failed" "$LANE_STDERR" "COMPLEXITY_LANE=full; reason=projects_fetch_failed"
assert_not_contains "TC-6.10t: 応答に Issue が無いことを Project 未登録と言わない" "$LANE_STDERR" "Issue は Project に未登録"
pj_items "$(pj_item 11 Complexity=S)"
run_pj '## 複雑度

S'
assert_contains "TC-6.10c: 記法 2 でも Projects と一致すれば本文由来" "$LANE_STDERR" "COMPLEXITY_LANE=light; complexity=S; source=body_section"

# フィールド名の候補順: 設定の name → 複雑度 → Complexity。
pj_config true 11 '        enabled: true
        name: "規模"   # 任意'
pj_items "$(pj_item 11 Complexity=M 規模=S)"
run_pj "$NO_DECL"
assert_contains "TC-6.11: 設定の name を既定名より優先する" "$LANE_STDERR" "COMPLEXITY_LANE=light; complexity=S; source=projects_field"
pj_config true 11
pj_items "$(pj_item 11 Complexity=M 複雑度=XS)"
run_pj "$NO_DECL"
assert_contains "TC-6.11b: 日本語エイリアスを英語正準名より優先する" "$LANE_STDERR" "COMPLEXITY_LANE=light; complexity=XS; source=projects_field"

# 連携を有効にしたまま project_number が数値でない設定は、無効扱いにせず止める。
for _pj_body in "$NO_DECL" '**Complexity**: S'; do
  pj_config true '"abc"'
  run_pj "$_pj_body"
  [ "$LANE_RC" -eq 1 ] && pass "TC-6.12: project_number 不正は exit 1 で止まる" || fail "TC-6.12: rc=$LANE_RC"
  assert_contains "TC-6.12b: 設定不正の reason を名指しする" "$LANE_STDERR" "projects_config_invalid"
  assert_contains "TC-6.12c: 直すべき設定キーを示す" "$LANE_STDERR" "github.projects.project_number"
  assert_not_contains "TC-6.12d: 設定不正でレーンを出さない" "$LANE_STDERR" "COMPLEXITY_LANE="
done
# null / 空は配布テンプレートと setup が既定で書く「未設定」。止めずに Projects を参照しない。
for _pj_num in null '' '# Project 番号'; do
  pj_config true "$_pj_num"
  pj_items "$(pj_item 11 Complexity=M)"
  run_pj '**Complexity**: S'
  assert_contains "TC-6.13: project_number 未設定 ($_pj_num) は本文だけで判定する" "$LANE_STDERR" "COMPLEXITY_LANE=light; complexity=S; source=body_meta"
  [ "$LANE_RC" -eq 0 ] && pass "TC-6.13b: project_number 未設定 ($_pj_num) で止めない" || fail "TC-6.13b: rc=$LANE_RC"
  run_pj "$NO_DECL"
  assert_contains "TC-6.13c: project_number 未設定 ($_pj_num) は未参照と案内する" "$LANE_STDERR" "github.projects.project_number が未設定のため Projects は参照していません"
done
pj_config true '"11"'
pj_items "$(pj_item 11 Complexity=S)"
run_pj "$NO_DECL"
assert_contains "TC-6.12e: 引用符付きの project_number は数値として読む" "$LANE_STDERR" "COMPLEXITY_LANE=light; complexity=S; source=projects_field"
pj_config true 11

# 実呼出し block の終了値を測り、入口identityを保持したままforeign開始cwdを固定する。
run_lane_with_body "**Complexity**: S"
for invalid_cwd in relative "" "$TEST_DIR/absent"; do
  run_lane_with_body "**Complexity**: S" --cwd "$invalid_cwd"
  [ "$LANE_RC" -eq 1 ] && pass "不正な実行場所で停止" || fail "不正な実行場所: rc=$LANE_RC"
  assert_not_contains "不正な実行場所はレーンを出さない" "$LANE_STDERR" "COMPLEXITY_LANE="
done
ENTRY_OWNER_REPO=$(cd "$TEST_REPO" && bash "$SCRIPT_DIR/../../hooks/scripts/lib/git-remote.sh" resolve-owner-repo | tr '\t' '/')
for consumer in open pr-review issue-implement; do
  skill="$SCRIPT_DIR/../../skills/$consumer/SKILL.md"
  block=$(awk '
    /^[[:space:]]*```bash/ { body=""; inside=1; next }
    /^[[:space:]]*```/ {
      if (inside && body ~ /scripts\/issue-complexity-lane.sh --issue/) { printf "%s", body; exit }
      inside=0; next
    }
    inside { body=body $0 "\n" }
  ' "$skill")
  [ -n "$block" ] || { fail "$consumer の実呼出し block が無い"; continue; }
  for mode in mismatch pinned authentication pj_mismatch pj_absent; do
    execution_cwd="$foreign_repo"; bindir="$TEST_DIR/bin"
    printf '%s' '**Complexity**: S' > "$TEST_DIR/body.txt"
    [ "$mode" = pinned ] && execution_cwd="$TEST_REPO"
    [ "$mode" = authentication ] && execution_cwd="$TEST_REPO" && bindir="$TEST_DIR/bin-fail"
    if [ "$mode" = pj_mismatch ] || [ "$mode" = pj_absent ]; then
      execution_cwd="$PJ_REPO"; bindir="$PJ_BIN"
      if [ "$mode" = pj_mismatch ]; then
        printf '%s' '**Complexity**: M' > "$TEST_DIR/body.txt"; pj_items "$(pj_item 11 Complexity=S)"
      else
        printf '%s' "$NO_DECL" > "$TEST_DIR/body.txt"; pj_items "$(pj_item 11 Status=Todo)"
      fi
    fi
    printf '%s\n' "$block" | sed \
      -e "s|{execution_cwd}|$execution_cwd|g" \
      -e "s|{plugin_root}|$SCRIPT_DIR/../..|g" \
      -e 's|{issue_number}|42|g' -e 's|{owner_repo}|$ENTRY_OWNER_REPO|g' > "$TEST_DIR/consumer.sh"
    # A single tool block returns the helper status; only success permits the next phase.
    LANE_STDERR=$(cd "$foreign_repo" && ENTRY_OWNER_REPO="$ENTRY_OWNER_REPO" RITE_TEST_BODY_FILE="$TEST_DIR/body.txt" RITE_TEST_PJ_FILE="$TEST_DIR/pj.json" PATH="$bindir:$PATH" bash "$TEST_DIR/consumer.sh" 2>&1); LANE_RC=$?
    [ "$LANE_RC" -eq 0 ] && LANE_STDERR="$LANE_STDERR CONSUMER_CONTINUED"
    if [ "$mode" = pj_mismatch ]; then
      [ "$LANE_RC" -eq 1 ] && pass "$consumer: 本文と Projects の食い違いが停止へ伝播" || fail "$consumer: pj_mismatch rc=$LANE_RC"
      assert_contains "$consumer: 食い違いの reason が届く" "$LANE_STDERR" "complexity_mismatch"
      assert_not_contains "$consumer: 食い違い後に続行しない" "$LANE_STDERR" "CONSUMER_CONTINUED"
    elif [ "$mode" = pj_absent ]; then
      [ "$LANE_RC" -eq 0 ] && pass "$consumer: 両方に値が無くても helper は正常終了" || fail "$consumer: pj_absent rc=$LANE_RC"
      assert_contains "$consumer: 両方に値が無ければ complexity_absent の fallback" "$LANE_STDERR" "COMPLEXITY_LANE_FALLBACK=1; reason=complexity_absent"
      assert_contains "$consumer: 欠落時の案内が届く" "$LANE_STDERR" "**Complexity**: M"
      assert_contains "$consumer: fallback 後に続行できる" "$LANE_STDERR" "CONSUMER_CONTINUED"
    elif [ "$mode" = mismatch ]; then
      [ "$LANE_RC" -eq 1 ] && pass "$consumer: context 失敗が停止へ伝播" || fail "$consumer: rc=$LANE_RC"
      assert_not_contains "$consumer: context 失敗後に続行しない" "$LANE_STDERR" "CONSUMER_CONTINUED"
    elif [ "$mode" = pinned ]; then
      [ "$LANE_RC" -eq 0 ] && pass "$consumer: foreign 開始 cwd から入口の固定先で成功" || fail "$consumer: rc=$LANE_RC"
      assert_contains "$consumer: 固定先の Issue を取得" "$LANE_STDERR" "COMPLEXITY_LANE=light; complexity=S"
    else
      [ "$LANE_RC" -eq 0 ] && pass "$consumer: 認証失敗 fallback を保全" || fail "$consumer: rc=$LANE_RC"
      assert_contains "$consumer: 認証失敗は issue_fetch_failed" "$LANE_STDERR" "reason=issue_fetch_failed"
      assert_contains "$consumer: fallback 後に続行できる" "$LANE_STDERR" "CONSUMER_CONTINUED"
    fi
  done
done

# gh だけを PATH から除き、repository 照合に必要な実ツールを残す。
_empty_bin="$TEST_DIR/empty-bin"
mkdir -p "$_empty_bin"
for tool in bash dirname git tr awk; do
  ln -s "$(command -v "$tool")" "$_empty_bin/$tool"
done
LANE_STDERR=$(cd "$TEST_REPO" && PATH="$_empty_bin" "$(command -v bash)" "$TARGET" --issue 42 --repo owner/repo 2>&1); LANE_RC=$?
assert_contains "TC-4.14: 一致した context では gh_missing を保全" "$LANE_STDERR" "COMPLEXITY_LANE=full; reason=gh_missing"
[ "$LANE_RC" -eq 0 ] && pass "gh 不在・一致で full 成功" || fail "gh 不在・一致 rc=$LANE_RC"
LANE_STDERR=$(cd "$foreign_repo" && PATH="$_empty_bin" "$(command -v bash)" "$TARGET" --issue 42 --repo owner/repo 2>&1); LANE_RC=$?
assert_contains "gh 不在でも不一致を検出" "$LANE_STDERR" "repo_mismatch"
assert_not_contains "gh 不在で不一致を fallback にしない" "$LANE_STDERR" "COMPLEXITY_LANE="
[ "$LANE_RC" -eq 1 ] && pass "gh 不在・不一致で停止" || fail "gh 不在・不一致 rc=$LANE_RC"
LANE_STDERR=$(cd "$TEST_REPO" && PATH="$_empty_bin" "$(command -v bash)" "$TARGET" --issue 42 2>&1); LANE_RC=$?
assert_contains "gh 不在でも明示対象欠落を検出" "$LANE_STDERR" "repo_unresolved"
[ "$LANE_RC" -eq 1 ] && pass "gh 不在・明示対象欠落で停止" || fail "gh 不在・対象欠落 rc=$LANE_RC"

echo "=== docstring が reason 語彙の SoT であること ==="

# SKILL.md / complexity-lane.md 側のコピーとの同期は hooks/tests/complexity-lane-contract.test.sh
# が担う。ここでは「helper 自身が全 reason を宣言している」ことだけを固定する。
# consumer 側 reason (issue_number_missing / helper_failed) も docstring に載せる — helper を
# 呼べない状況を helper 自身が語れないと、reason 表がどこにも揃わなくなるため。
for _r in gh_missing repo_unresolved issue_fetch_failed complexity_absent complexity_invalid \
          projects_fetch_failed complexity_mismatch projects_config_invalid \
          issue_number_missing helper_failed; do
  if grep -q "$_r" "$TARGET"; then
    pass "TC-5: docstring が reason '$_r' を宣言している"
  else
    fail "TC-5: docstring が reason '$_r' を宣言していない"
  fi
done

echo "=== 結果: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ] || exit 1
