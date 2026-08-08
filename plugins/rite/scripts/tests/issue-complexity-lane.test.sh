#!/bin/bash
# Tests for issue-complexity-lane.sh (XS/S 軽量レーンの判定)
#
# 本 helper は「儀式コストを Complexity に比例させる」判定の唯一の実行層で、判定を誤ると
# (a) M+ の Issue が軽量レーンへ落ちて検証深度が silent に下がる、または (b) XS/S が毎回
# フル装備で回りレーンが一度も発動しない、のどちらかになる。(a) は品質を無言で削るため、
# 本 suite は「情報が欠けた全経路で full へ倒れること」を reason ごとに個別に pin する
# (Issue #2136 AC-2 / T-02)。
#
# gh は PATH shim で差し替える (hooks/tests/issue-comment-wm-sync.sh と同じ方式)。
# 実 API を叩かないため body の記法バリエーションを網羅的に固定できる。
#
# Usage: bash plugins/rite/scripts/tests/issue-complexity-lane.test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="$SCRIPT_DIR/../issue-complexity-lane.sh"
TEST_DIR="$(mktemp -d)"
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
# `--repo` を明示するので owner/repo 解決経路 (git remote / gh repo view) には入らない。
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
    cat "$RITE_TEST_BODY_FILE"; exit 0 ;;
  *) echo "unexpected gh invocation: $*" >&2; exit 1 ;;
esac
GH_SHIM
  chmod +x "$bindir/gh"
  LANE_STDERR=$(RITE_TEST_BODY_FILE="$TEST_DIR/body.txt" PATH="$bindir:$PATH" \
    bash "$TARGET" --issue 42 --repo owner/repo "$@" 2>&1)
  LANE_RC=$?
}

# --repo を渡さない経路 (production の pr-review 1.3.2 / issue-implement 5.0.C は渡さない)。
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
  cat > "$bindir/gh" <<'GH_SHIM'
#!/bin/bash
echo "gh: authentication required" >&2
exit 1
GH_SHIM
  chmod +x "$bindir/gh"
  LANE_STDERR=$(PATH="$bindir:$PATH" bash "$TARGET" --issue 42 --repo owner/repo 2>&1)
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

echo "=== 記法 2: ## 複雑度 セクション — 2 記法併存の吸収 ==="

# 片方の記法しか読まないと、もう片方で書かれた Issue が全て complexity_absent へ落ちる。
run_lane_with_body '## 複雑度

S

## 次のセクション'
assert_contains "TC-3.1: ## 複雑度 セクションから S を読む" "$LANE_STDERR" "COMPLEXITY_LANE=light; complexity=S; source=body_section"

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

# 抽出式が POSIX BRE だけで書かれていること (GNU 拡張 `\b` / `\|` の混入を authoring 時点で
# pin する)。BSD/macOS sed はこれらを無警告に不一致とするため、混入すると当該環境で全 Issue が
# complexity_absent へ倒れレーンが一度も発動しない (CI の macos leg が本経路を踏む)。
# haystack は `sed -n` の行だけに絞る — ファイル全体を渡すと、GNU 拡張を禁じている散文コメント
# 自身が needle に一致して恒常 fail する。
LANE_SED_LINES=$(grep -n 'sed -n' "$TARGET")
assert_not_contains "TC-2.13: 抽出式に GNU 拡張の単語境界 (\\b) を使わない" "$LANE_SED_LINES" '\b'
assert_not_contains "TC-2.14: 抽出式に GNU 拡張の BRE 交替 (\\|) を使わない" "$LANE_SED_LINES" '\|'

# 記法 1 が存在するときは記法 1 を優先する (source= で区別できること自体が観測性の要求)。
run_lane_with_body '**Complexity**: M

## 複雑度

XS'
assert_contains "TC-3.3: 記法 1 が記法 2 より優先される" "$LANE_STDERR" "complexity=M; source=body_meta"

echo "=== fail-safe: 情報欠落は全経路で full へ倒れる (AC-2 / T-02) ==="

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

# repo_unresolved は **production の実経路**（pr-review 1.3.2 / issue-implement 5.0.C は
# --repo を渡さない）にある唯一の reason で、他 4 reason と違い --repo 明示では到達しない。
# ここを runtime で pin しないと、guard を light 固定にする mutant が素通りする。
run_lane_without_repo
assert_contains "TC-4.9a: owner/repo 解決不能は repo_unresolved" "$LANE_STDERR" "COMPLEXITY_LANE=full; reason=repo_unresolved"
assert_contains "TC-4.9b: repo_unresolved は FALLBACK marker を伴う" "$LANE_STDERR" "COMPLEXITY_LANE_FALLBACK=1; reason=repo_unresolved"
assert_contains "TC-4.9c: repo_unresolved は人間向け WARNING を伴う" "$LANE_STDERR" "⚠️ Complexity レーン判定のフォールバック"
assert_not_contains "TC-4.9d: repo_unresolved で light へ倒さない" "$LANE_STDERR" "COMPLEXITY_LANE=light"
[ "$LANE_RC" -eq 0 ] && pass "TC-4.9e: repo_unresolved でも exit code は 0" \
  || fail "TC-4.9e: repo_unresolved でも exit code は 0 (実際: $LANE_RC)"

run_lane_with_failing_gh
assert_contains "TC-4.10: gh 失敗は issue_fetch_failed" "$LANE_STDERR" "COMPLEXITY_LANE=full; reason=issue_fetch_failed"
# 取得失敗と「body に記載が無い」を混同すると、認証切れが Issue 側の不備として報告される。
assert_not_contains "TC-4.11: gh 失敗を complexity_absent と誤報告しない" "$LANE_STDERR" "reason=complexity_absent"
assert_contains "TC-4.12: gh の stderr を診断として surface する" "$LANE_STDERR" "authentication required"
[ "$LANE_RC" -eq 0 ] && pass "TC-4.13: issue_fetch_failed でも exit code は 0" \
  || fail "TC-4.13: issue_fetch_failed でも exit code は 0 (実際: $LANE_RC)"

# gh 不在。PATH を空ディレクトリだけにして command -v gh を外す。bash は PATH 探索を経ずに
# 起動できるよう絶対パスで呼ぶ (PATH="/nonexistent" bash ... だと bash 自体が見つからず、
# gh_missing 経路ではなく起動失敗を測ってしまう)。
_empty_bin="$TEST_DIR/empty-bin"
mkdir -p "$_empty_bin"
LANE_STDERR=$(PATH="$_empty_bin" "$(command -v bash)" "$TARGET" --issue 42 --repo owner/repo 2>&1); LANE_RC=$?
assert_contains "TC-4.14: gh 不在は gh_missing" "$LANE_STDERR" "COMPLEXITY_LANE=full; reason=gh_missing"
assert_not_contains "TC-4.15: gh 不在で light へ倒さない" "$LANE_STDERR" "COMPLEXITY_LANE=light"

echo "=== docstring が reason 語彙の SoT であること ==="

# SKILL.md / complexity-lane.md 側のコピーとの同期は hooks/tests/complexity-lane-contract.test.sh
# が担う。ここでは「helper 自身が全 reason を宣言している」ことだけを固定する。
# consumer 側 reason (issue_number_missing / helper_failed) も docstring に載せる — helper を
# 呼べない状況を helper 自身が語れないと、reason 表がどこにも揃わなくなるため。
for _r in gh_missing repo_unresolved issue_fetch_failed complexity_absent complexity_invalid \
          issue_number_missing helper_failed; do
  if grep -q "$_r" "$TARGET"; then
    pass "TC-5: docstring が reason '$_r' を宣言している"
  else
    fail "TC-5: docstring が reason '$_r' を宣言していない"
  fi
done

echo "=== 結果: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ] || exit 1
