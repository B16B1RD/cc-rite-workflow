#!/bin/bash
# remote-branch-delete-guard.test.sh
#
# cleanup/SKILL.md ステップ 5 のリモートブランチ削除ガードを SKILL.md から literal 抽出して
# sandbox で実行し、`git ls-remote --exit-code` の exit code 3 分岐を pin する。
# あわせて merge/SKILL.md の設計判断が `--delete-branch=false` の効果を過大に主張していない
# ことを静的検査する。
#
# 抽出実行方式の理由: ガードは SKILL.md 内の bash block テンプレートで、テストへコピーすると
# SKILL.md 側の修正がテストに反映されず drift する (base-update-classify.test.sh と同方式)。
# 抽出アンカーが壊れた場合はテスト自体が fail するため、アンカー変更もテストが検出する。
#
# 修正前の欠陥 (#2016): `git ls-remote --heads origin BR && git push origin --delete BR` は、
# `git ls-remote --heads` が ref 不在でも rc=0 (空 stdout) を返すため `&&` が常に成立し、
# delete_branch_on_merge: true の環境 (merge 時にサーバサイドで head が削除済み) では
# cleanup が完全に成功しているのに `error: unable to delete ...` を 2 行出していた。
#
# TC coverage。実行順は TC-0 → 1 → 2 → 2b → 3 → 3b → 7 → 7b → 7c →
# 8 → 9 → 4 → 6 → 5。TC-5 は precondition が前段 TC の後始末に依存するため最後に置く。
# - TC-0              : git ls-remote --heads が ref 不在でも rc=0 を返す前提の pin
#                      (修正前の && ガードが常に成立していたことの根拠)
# - TC-1 = T-01 (AC-1): ref 不在 → push --delete を呼ばず REMOTE_BRANCH_ALREADY_ABSENT を emit
# - TC-2 = T-02 (AC-2): ref 存在 → 従来どおり削除経路へ入り、リモートから実際に消える。
#                      成功 marker REMOTE_BRANCH_DELETED が出て失敗系 marker は出ない
# - TC-2b      (AC-1/AC-4): rc=0 経路で push --delete 自体が失敗したとき
#                      REMOTE_BRANCH_DELETE_FAILED を emit する (削除失敗が完了として
#                      報告される false-success を防ぐ)
# - TC-3       (AC-1): ls-remote 自体の失敗 (rc=0/2 以外) は「既削除」に丸めず
#                      REMOTE_BRANCH_CHECK_FAILED を emit し、削除も試行しない
# - TC-4 = T-03 (AC-3): merge/SKILL.md の設計判断が全称的な保証を主張せず、
#                      抑止できないものを否定表現で明示して区別している
# - TC-6       (AC-4): ステップ 12 リモート側の判定 4 ルール + fallback の判定値と禁止文 +
#                      marker family スコープ + アンカー/行頭規約 + ローカル/リモート独立評価の
#                      AND ルール文を静的に pin する
#                      (emitter だけ検証して consumer が無防備になる穴を塞ぐ)
# - TC-7       (#2016 cycle 3): marker のデリミタ文字 (`;` `=`) や空値を含むブランチ名は
#                      fail-fast で弾き、削除を試行せず sentinel marker で fallback へ倒す
# - TC-7b/7c   (#2027): remote の非 canonical/非合法名、mktemp 失敗、awk 異常終了を実行時に pin
# - TC-8/9     (#2027): local の削除未試行、非 canonical 名、存在判定不能を実行時に pin
# - TC-5 = T-04       : 抽出した実物のガードから完全一致検証を弱めた mutant で TC-1 相当が
#                      落ちる (完全一致検証が load-bearing であることの実証)
#
# marker 照合の規約: 正の assertion (marker が出ていること) は consumer 側と同形の
# 「行頭 + `[CONTEXT] ` 込み」で照合する。負の assertion (marker が出ていないこと) は
# 非アンカーのままにする — マッチ面が広いほど検出が厳しくなるため、アンカーするとテストが弱まる。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLEANUP_MD="$SCRIPT_DIR/../../skills/cleanup/SKILL.md"
MERGE_MD="$SCRIPT_DIR/../../skills/merge/SKILL.md"
# cleanup/trap を mktemp より前に設置する (直後の cd / command -v の exit 1 経路で temp dir が
# leak しないようにする)。TEST_DIR は先行宣言して set -u 下でも参照可能にする。
TEST_DIR=""
cleanup() { [ -n "$TEST_DIR" ] && rm -rf "$TEST_DIR"; return 0; }
trap cleanup EXIT
TEST_DIR="$(mktemp -d)" || exit 1
# canonical 化は別変数へ受けてから代入する。`TEST_DIR="$(cd ... )" || exit 1` は cd/pwd が
# 失敗したとき `|| exit 1` が走る前に TEST_DIR を空文字で上書きするため、EXIT trap の cleanup()
# が no-op になり直前に作った temp dir が leak する (直前の cleanup 契約と正面から矛盾する)。
_canon="$(cd "$TEST_DIR" && pwd -P)" || exit 1
TEST_DIR="$_canon"
REAL_GIT="$(command -v git)" || { echo "FATAL: git が見つかりません"; exit 1; }
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

BRANCH="fix/issue-2016-sample"

# --- SKILL.md からリモート削除ガードを抽出 ({branch_name} はテスト用ブランチ名に置換) ---
# アンカー: 導入コメント行 `# リモートブランチ削除` 〜 bash fence の終端。
# 閉じアンカーに `^esac$` を使わないこと — ガードは case を入れ子にしており (ブランチ名の
# デリミタ検査 → 存在確認 → rc 分岐)、最初の `^esac$` で切ると内側の case までしか取れず
# `fi ;; esac` が落ちて構文エラーになる。fence 終端なら入れ子の深さに依存しない。
extract_guard_as() {
  local _replacement
  _replacement=$(printf '%s' "$1" | sed 's/[&|\\]/\\&/g')
  awk '/^# リモートブランチ削除/{f=1} f && /^```$/{exit} f{print}' "$CLEANUP_MD" \
    | sed -e "s|{branch_name}|$_replacement|g" -e 's|{branch_identity_verified}|true|g'
}
extract_guard() { extract_guard_as "$BRANCH"; }
# ローカル削除ブロックの抽出。リモート側と別アンカーが要る — `# リモートブランチ削除` を開始
# アンカーにする extract_guard はローカル側を範囲外にするため、ローカルの契約 (事前検証 case /
# 存在確認 rc の 3 分岐) がどの検査にも掛からない状態だった (#2016 cycle 3 で実測)。
# 終端はリモートブロックの開始コメント。{pr_merged} / {plugin_root} もこのブロックで展開される。
# raw 版は placeholder を残す (静的 pin は `{branch_name}` を含む literal を要求するため)。
extract_local_guard_raw() {
  awk '/^## ステップ 5: ローカル \/ リモートブランチを削除/{s=1} s && /^```bash$/{f=1; next} f && /^# リモートブランチ削除/{exit} f{print}' "$CLEANUP_MD"
}
extract_local_guard_as() {
  local _replacement
  _replacement=$(printf '%s' "$1" | sed 's/[&|\\]/\\&/g')
  extract_local_guard_raw \
    | sed -e "s|{branch_name}|$_replacement|g" -e "s|{pr_merged}|true|g" -e 's|{branch_identity_verified}|true|g' -e "s|{plugin_root}|$TEST_DIR/no-plugin|g"
}
GUARD_SNIPPET="$TEST_DIR/guard.sh"
extract_guard > "$GUARD_SNIPPET"
# 必須文字列を 2 群に分け、**診断文面を分ける**。抽出の破損とガード契約の消失は原因も対処も別物で、
# 後者を「アンカーが変更された可能性」と報じると、本テストが検出すべき #2016 の退行そのものを
# 「テスト側の問題」に誤帰属させる (本ファイルが随所で欠陥として扱っている誤帰属)。
#
# 群 1: 抽出の**構造**健全性のみ。閉じアンカーが抽出結果の末尾に来ていることを見る。
# 契約文字列 (marker 名や `[CONTEXT] ` prefix) はここに置かない — 置くと契約の消失を
# 「アンカーが変更された可能性」と報じてしまい、群を分けた目的そのものが失われる。
for required in '^case "' '^esac$'; do
  if ! grep -q "$required" "$GUARD_SNIPPET"; then
    echo "FAIL: cleanup/SKILL.md からのガード抽出に失敗しました ('$required' 不在。アンカーが変更された可能性)"
    echo "  抽出結果: $(wc -l < "$GUARD_SNIPPET") 行"
    exit 1
  fi
done
# 列 0 の `case`/`esac` が 2 組あること。ガードは外側 (ブランチ名の事前検証) と内側 (ls-remote の
# rc 分岐) の 2 段構造で、外側を de-wrap する mutation は内側だけで `^case`/`^esac` を充足するため
# 存在検査では捕捉できない。組数まで要求して外側の消失を検出する。
_case_n=$(grep -c '^case "' "$GUARD_SNIPPET"); _esac_n=$(grep -c '^esac$' "$GUARD_SNIPPET")
if [ "$_case_n" -ne 2 ] || [ "$_esac_n" -ne 2 ]; then
  echo "FAIL: 抽出したガードの case/esac が 2 組ではありません (case=$_case_n, esac=$_esac_n)"
  echo "  外側のブランチ名事前検証 case が de-wrap された可能性があります (#2016 の fail-fast ガード消失)"
  exit 1
fi
# 群 2: ガードの振る舞い契約。抽出は成功しているので、不在は artifact 側で契約が失われたことを意味する。
# marker 名 4 種 / emit 箇所 8 のすべてを含める (どれか 1 経路だけが対象外という非対称を残さない)。
# `[CONTEXT] ` prefix は consumer (ステップ 12) がアンカー照合する契約の一部なので群 2 に置く。
# `grep "$required"` は BRE なので `[CONTEXT]` はブラケット式に解釈される — エスケープを外さないこと。
# `push origin --delete` は抽出範囲内のコメントにも現れるため、コード行だけに現れる形で要求する。
# 破壊的操作の namespace 修飾 (`refs/heads/` 前置) と存在確認の完全一致検証は、いずれも本 Issue の
# 核心なので literal で要求する。非修飾の `--delete <shortname>` は remote の全 namespace に解決され
# 同名タグを削除しうる。完全一致検証を落とすと `refs/heads/<任意>/{branch}` への tail 一致で
# 不在ブランチが「存在」と判定される。
# marker は `=1; branch=` まで要求する。consumer (ステップ 12) は `branch={branch_name}` まで
# スコープして照合するため emitter の `branch=` は load-bearing だが、marker 名だけを pin する形では
# emitter から `; branch=...` を落とす mutation が素通りする (実測で 8 passed を確認済み)。
# 退避テキストのインデントも要求する。SKILL.md 自身が「security boundary はインデント (列 0 に
# 到達しないこと) の側にある」と規定しており、デリミタだけを pin するのは装飾側だけを守る形になる。
for required in 'ls-remote --exit-code' \
                'if _push_err=\$(LC_ALL=C git push origin --delete "refs/heads/' \
                '-v r="refs/heads/' '$2 == r' \
                '*[\;=]*)' 'branch=<unsupported branch name>; rc=marker-delimiter-in-branch-name' \
                'branch=<unsupported branch name>; rc=empty-branch-name' \
                'REMOTE_BRANCH_CHECK_FAILED=1; branch=.*rc=invalid-refname' \
                'REMOTE_BRANCH_CHECK_FAILED=1; branch=.*rc=mktemp-failed' \
                'if \[ -z "\$_ls_out" \]; then' \
                'if \[ "\$_ls_rc" -eq 128 \]; then' \
                '_check_reason="ref-match-awk-\${_match_rc}"' 'if \[ "\$_ls_rc" -eq 0 \]; then' \
                '^  2) echo "\[CONTEXT\] REMOTE_BRANCH_ALREADY_ABSENT' \
                'REMOTE_BRANCH_DELETED=1; branch=' 'REMOTE_BRANCH_DELETE_FAILED=1; branch=' \
                'REMOTE_BRANCH_ALREADY_ABSENT=1; branch=' 'REMOTE_BRANCH_CHECK_FAILED=1; branch=' \
                '\[CONTEXT\] REMOTE_BRANCH_' \
                "sed 's/^/  /'" \
                '--- push stderr begin ---' '--- push stderr end ---' \
                '--- ls-remote stderr begin ---' '--- ls-remote stderr end ---'; do
  # `-e` は必須。`---` で始まるパターンを grep がオプションとして解釈するのを防ぐ。
  if ! grep -q -e "$required" "$GUARD_SNIPPET"; then
    echo "FAIL: 抽出したガードに '$required' がありません — cleanup/SKILL.md ステップ 5 のガード契約が失われた可能性 (#2016 の退行)"
    echo "  抽出自体は成功しています ($(wc -l < "$GUARD_SNIPPET") 行)。アンカーではなくガード本体を確認してください"
    exit 1
  fi
done
# 群 3: 抽出範囲外の data/marker 分離契約。ステップ 5 の退避サイトは 3 箇所 (ローカル削除失敗 /
# push 失敗 / ls-remote 失敗) あるが、抽出アンカー `# リモートブランチ削除` はローカル削除側を
# 範囲に含めない。群 2 (抽出結果が対象) では 3 箇所目だけが無防備という非対称が残るため、
# $CLEANUP_MD 全体を対象にする群として分離する。群 2 に混ぜると「抽出は成功しています」という
# 群 2 の診断文面と矛盾する (抽出範囲外の文字列を抽出結果に要求することになる)。
LOCAL_SNIPPET="$TEST_DIR/guard-local-raw.sh"
extract_local_guard_raw > "$LOCAL_SNIPPET"
# 抽出の健全性 (リモート側の群 1 と同形)。ファイル全体を grep する形にしてはならない —
# 判定表 (ステップ 12) に同一 literal が存在するため、emitter を消しても充足されて vacuous になる
# (テスト側で同じ穴を逆向きに開けたのが #2016 cycle 3)。
if [ ! -s "$LOCAL_SNIPPET" ] || ! grep -q '^case "{branch_name}" in' "$LOCAL_SNIPPET"; then
  echo "FAIL: cleanup/SKILL.md からローカル削除ブロックを抽出できません (アンカーが変更された可能性)"
  echo "  抽出結果: $(wc -l < "$LOCAL_SNIPPET") 行"
  exit 1
fi
if grep -q '^# リモートブランチ削除' "$LOCAL_SNIPPET"; then
  echo "FAIL: ローカル抽出がリモートブロックまで over-capture しています (終端アンカーが変更された可能性)"
  exit 1
fi
if ! bash -n "$LOCAL_SNIPPET" 2>/dev/null; then
  echo "FAIL: 抽出したローカル削除ブロックが構文的に不完全です"
  bash -n "$LOCAL_SNIPPET" 2>&1 | sed 's/^/    /'
  exit 1
fi
# ローカル側の契約。marker 名と判定値/rc 値を 1 パターンで要求する (連言) — marker 名だけを
# 要求する形は、判定値を正常系へ反転する mutation を素通しする。
for required in '--- branch delete stderr begin ---' '--- branch delete stderr end ---' \
                '"\$del_err" | tr -d ' '"\${_sr_err}" | tr -d ' \
                'git check-ref-format "refs/heads/' \
                'BRANCH_CHECK_FAILED=1; branch={branch_name}; rc=invalid-refname' \
                'git show-ref --verify --quiet "refs/heads/{branch_name}" 2>&1 >/dev/null); _sr_rc=\$?' \
                'if \[ "\$_sr_rc" -eq 1 \]; then' 'elif \[ "\$_sr_rc" -ne 0 \]; then' \
                'BRANCH_ALREADY_ABSENT=1; branch={branch_name}' \
                'BRANCH_CHECK_FAILED=1; branch={branch_name}; rc=\${_sr_rc}' \
                'branch=<unsupported branch name>; rc=empty-branch-name' \
                'branch=<unsupported branch name>; rc=marker-delimiter-in-branch-name'; do
  if ! grep -q -e "$required" "$LOCAL_SNIPPET"; then
    echo "FAIL: 抽出したローカル削除ブロックに '$required' がありません"
    echo "  ローカル側の契約 (事前検証 / refname 合法性 / 存在確認 rc の 3 分岐 / 退避 stderr の分離) が失われています"
    exit 1
  fi
done
# 抽出が構文的に完結していることを検査する。fence 終端アンカーは over-capture を構造的に防ぐが、
# **under-capture (ガード内部の入れ子が増えて閉じトークンが fence の外へ出た等) は防げない**。
# 群 1 の `^esac$` は内側 case だけでも充足するため、閉じトークンの欠落は文字列検査では捕捉できない。
# bash 自身にパースさせるのが最も直接的で、実際にこの検査が無い間に「内側 esac で切れて
# `fi ;; esac` が落ちる」抽出破損が起きた (#2016 cycle 1)。
if ! bash -n "$GUARD_SNIPPET" 2>/dev/null; then
  echo "FAIL: 抽出したガードが構文的に不完全です (閉じトークンの欠落 — アンカーが構造の変化に追随していない)"
  echo "  抽出結果: $(wc -l < "$GUARD_SNIPPET") 行"
  bash -n "$GUARD_SNIPPET" 2>&1 | sed 's/^/    /'
  exit 1
fi

# brace 無し変数展開が非 ASCII バイトに隣接していないことを検査する。`$var。` と書くと bash が
# 多バイト文字の先頭バイトを変数名に取り込み、非 UTF-8 ロケール (macOS CI) で変数が未定義化して
# 診断が消え、残った不正バイトが下流の BSD sed も落とす (TC-8b-h と同 invariant)。
# TC-8b-h のスイープは *.sh のみを走査し SKILL.md の bash fence を対象外にしている
# (同テストが scope limit として明記) ため、抽出したスニペットに対してここで検査する。
#
# 検出は `LC_ALL=C awk` で行う。perl の `[\x{80}-\x{FF}]` は入力デコードが有効な環境
# (PERLIO=:utf8 / PERL_UNICODE=SD) で多バイト文字がクラス外に出て silently 見逃す。
# awk は本ファイルが既に使っており依存も増やさない。行頭 `#` のコメント行は TC-8b-h と同じ規約で
# 除外する (周囲の rationale が anti-pattern を verbatim 引用できるようにするため)。
_brace_detect() {
  LC_ALL=C awk '!/^[[:space:]]*#/ && /\$[A-Za-z_][A-Za-z0-9_]*[^ -~]/ { printf "  L%d: %s\n", NR, $0 }' "$1"
}
# Positive control。本検査は negative assertion (何も見つからなければ PASS) のため、検出器が
# 壊れると守っているはずの違反があっても緑になる。既知の違反を **同じ関数** に通して発火することを
# 先に証明する (TC-8b-h と同形。negative assertion は検出器の非 vacuity を先に証明してから走らせる)。
# probe は trap 済みの $TEST_DIR 配下に置く。mktemp を使うと rc 未検査のとき空パスが検出器へ渡り、
# 「検出器が既知の違反を報告しません」という真因と異なる帰属で落ちる（$TEST_DIR は生成時に
# ガード済みで EXIT trap の掃除対象にも入るため、rc 検査も個別の rm -f も不要になる）。
_brace_probe="$TEST_DIR/brace-probe.sh"
printf 'echo "x: $_ls_err\xe3\x80\x82"\n' > "$_brace_probe"
if [ "$(_brace_detect "$_brace_probe" | wc -l | tr -d '[:space:]')" != "1" ]; then
  echo "FAIL: brace 検出器が既知の違反を報告しません — 以降のスキャンは vacuous です"
  exit 1
fi

_brace_violations=$(_brace_detect "$GUARD_SNIPPET")
if [ -n "$_brace_violations" ]; then
  echo "FAIL: 抽出したガードに brace 無しの変数展開が非 ASCII バイトへ直接隣接する箇所があります"
  printf '%s\n' "$_brace_violations"
  echo "  対処: \${var} の形で閉じるか、変数と多バイト文字の間に ASCII 文字を挟んでください"
  exit 1
fi

# --- git ラッパー stub: push 呼び出しを記録しつつ実 git へ委譲する ---
# 「push --delete が呼ばれなかった」を出力の不在ではなく呼び出し記録で直接検証するため
# (出力ベースだと、たまたまエラーが出ないだけの偽 PASS を許してしまう)。
BIN_DIR="$TEST_DIR/bin"
CALL_LOG="$TEST_DIR/git-calls.log"
mkdir -p "$BIN_DIR"
cat > "$BIN_DIR/git" <<EOF
#!/bin/bash
if [ "\${1:-}" = "push" ] || [ "\${1:-}" = "branch" ]; then printf '%s\n' "\$*" >> "$CALL_LOG"; fi
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$BIN_DIR/git"

# ガードを stub git 経由で実行し、stdout+stderr をまとめて返す
run_guard() {
  local snippet="$1"
  : > "$CALL_LOG"
  PATH="$BIN_DIR:$PATH" bash "$snippet" 2>&1
}
# grep の rc=1 (マッチなし = 期待動作) と rc=2 (CALL_LOG 不在 / IO エラー) を区別する。
# 融合させると記録機構が壊れたときに否定アサーションが vacuous に PASS する。
push_delete_called() {
  local rc
  grep -q -- "--delete" "$CALL_LOG"; rc=$?
  case "$rc" in
    0) return 0 ;;
    1) return 1 ;;
    *) echo "FATAL: CALL_LOG の grep が IO エラー (rc=$rc): $CALL_LOG" >&2; exit 1 ;;
  esac
}
branch_delete_called() { grep -qE '^branch -[dD]( | -- )' "$CALL_LOG"; }

# 退避 stderr のデリミタ区間が **列 0 に到達していない** ことを検査する。SKILL.md は
# 「デリミタは可読性の補助であり、data 自身が終端行を騙る経路を塞ぐ security boundary は
# インデント (列 0 に到達しないこと) の側にある」と規定しているので、デリミタ文字列だけを pin
# すると装飾側しか守らない形になる。git の複数行 stderr の 2 行目以降が列 0 に着地すると、
# consumer (列 0 の行だけを marker 候補とする) がそれを marker として読む経路が残る。
# 戻り値: 0 = 全行インデント済み (期待動作) / 1 = 列 0 の行あり (違反)。
delimited_block_indented() {
  local _text="$1" _label="$2"
  printf '%s\n' "$_text" | awk -v b="--- $_label stderr begin ---" -v e="--- $_label stderr end ---" '
    index($0, b) { f = 1; begin_count++; next }
    index($0, e) { f = 0; end_count++; next }
    f && /^[^[:space:]]/ { bad = 1 }
    END { exit (bad || begin_count != 1 || end_count != 1 || f) }
  '
}
# Positive control。本検査は negative assertion (列 0 の行が無ければ PASS) のため、検出器が壊れると
# 守っているはずの違反があっても緑になる。_brace_detect と同じ規律で、既知の違反に発火することを
# 先に証明してから走らせる。
_indent_probe=$'--- push stderr begin ---\nnot-indented\n--- push stderr end ---'
if delimited_block_indented "$_indent_probe" "push"; then
  echo "FAIL: インデント検出器が既知の違反 (列 0 の行) を報告しません — 以降のインデント検査は vacuous です"
  exit 1
fi
_missing_delimiter_probe=$'not-indented'
if delimited_block_indented "$_missing_delimiter_probe" "push"; then
  echo "FAIL: インデント検出器がデリミタ不在を PASS しました — 区間検査が vacuous です"
  exit 1
fi

# --- sandbox: bare origin + clone ---
ORIGIN="$TEST_DIR/origin.git"
REPO="$TEST_DIR/repo"
git init -q --bare -b main "$ORIGIN" || { echo "FATAL: sandbox origin init 失敗"; exit 1; }
git clone -q "$ORIGIN" "$REPO" 2>/dev/null || { echo "FATAL: sandbox clone 失敗"; exit 1; }
# cd 失敗のまま続行すると後続の git 操作が親 repo に向く
cd "$REPO" || { echo "FATAL: sandbox cd 失敗"; exit 1; }
git config user.email test@example.com
git config user.name test
# 同ディレクトリの fixture テスト群と同じ規約。global 設定で commit.gpgsign=true の環境
# (鍵切れ / tty なし / gpg 未導入) では初期 commit が失敗し、&& で push が skip され、
# TC-0/TC-1 が「origin に不在」で偶然 PASS したうえ TC-2 が真因を外した帰属で落ちる。
git config commit.gpgsign false
echo "v1" > file.txt
git add -A && git commit -qm init && git push -q origin main 2>/dev/null \
  || { echo "FATAL: sandbox bootstrap の commit/push に失敗"; exit 1; }

echo "=== remote branch delete guard tests (SKILL.md 抽出実行) ==="
echo ""

# ─── TC-0: 前提 pin — `git ls-remote --heads` (--exit-code なし) は ref 不在でも rc=0 ───
# 本 Issue の根本原因そのもの。git 側の仕様が変わればガードの前提も変わるため明示的に pin する。
echo "TC-0: git ls-remote --heads (no --exit-code) returns rc=0 for a missing ref"
git ls-remote --heads origin "$BRANCH" >/dev/null 2>&1; legacy_rc=$?
if [ "$legacy_rc" -eq 0 ]; then
  pass "TC-0 (rc=$legacy_rc — 修正前の && ガードが常に成立していた前提を確認)"
else
  fail "TC-0: expected rc=0, got '$legacy_rc' (git の exit code 仕様が変わった可能性)"
fi

# 衝突 ref を仕込む。`git ls-remote <pattern>` は slash 境界の tail 一致であり完全一致ではないため、
# ガードが `refs/heads/` を前置せず短い名前を渡していると、対象が不在でもこの ref に誤ヒットして
# rc=0 になり削除経路へ落ちる (#2016)。以降の TC はこの状態で走るので、ガードが full refname を
# 使っていることを TC-1 が回帰 pin する (短い名前へ戻すと TC-1 で push --delete が呼ばれて落ちる)。
COLLIDING="wip/$BRANCH"
_setup_err=$(LC_ALL=C git switch -qc "$COLLIDING" 2>&1) \
  || { echo "FATAL: 衝突 ref の作成に失敗: $_setup_err"; exit 1; }
_setup_err=$(LC_ALL=C git push -q origin "$COLLIDING" 2>&1) \
  || { echo "FATAL: 衝突 ref の push に失敗: $_setup_err"; exit 1; }
git switch -q main || { echo "FATAL: main への切り戻しに失敗"; exit 1; }
# 仕込みが成立していることを確認する。ここが崩れると TC-1 は「衝突なし」を検証する別物になる。
git ls-remote --exit-code --heads origin "refs/heads/$COLLIDING" >/dev/null 2>&1 \
  || { echo "FATAL: 衝突 ref が origin に存在しない — TC-1 の full refname pin が vacuous になる"; exit 1; }

# **入れ子** 衝突 ref。`refs/heads/` の前置だけでは完全一致にならない — `git ls-remote <pattern>` は
# ref の先頭または任意の slash 境界からの tail 一致なので、`refs/heads/<任意>/refs/heads/$BRANCH`
# には pattern `refs/heads/$BRANCH` が一致して rc=0 を返す (実測)。上の $COLLIDING は tail が
# `wip/$BRANCH` / `$BRANCH` / … で full refname 形の pattern には一致しないため、これだけでは
# 「完全一致検証が効いていること」を証明できない。ガードは rc=0 のあと stdout の ref 名を
# 完全一致で検証しており、TC-1 がその回帰 pin になる (検証を外すと TC-1 で push --delete が走る)。
NESTED_COLLIDING="wip/refs/heads/$BRANCH"
_setup_err=$(LC_ALL=C git switch -qc "$NESTED_COLLIDING" 2>&1) \
  || { echo "FATAL: 入れ子衝突 ref の作成に失敗: $_setup_err"; exit 1; }
_setup_err=$(LC_ALL=C git push -q origin "$NESTED_COLLIDING" 2>&1) \
  || { echo "FATAL: 入れ子衝突 ref の push に失敗: $_setup_err"; exit 1; }
git switch -q main || { echo "FATAL: main への切り戻しに失敗"; exit 1; }
# 仕込みが「full refname 形の pattern に rc=0 で一致する」ところまで確認する。ここが rc=2 だと
# TC-1 の完全一致 pin と TC-5 の mutation が両方 vacuous になる。
git ls-remote --exit-code --heads origin "refs/heads/$BRANCH" >/dev/null 2>&1 \
  || { echo "FATAL: 入れ子衝突 ref が full refname pattern に一致しない — TC-1/TC-5 の完全一致 pin が vacuous になる"; exit 1; }

# 同名タグ。`git push origin --delete <shortname>` は remote の**全 namespace** に対して <dst> を
# 解決するため、ブランチが不在でタグのみが存在すると**タグを削除する** (実測)。ガードは削除先も
# `refs/heads/` で修飾しており、この fixture がその回帰 net になる。ただし**発火の仕方は間接的**で、
# ブランチとタグが同名で共存する TC-2 の状態では非修飾 <dst> は `dst refspec ... matches more than
# one` で **push 自体が失敗する**ため、TC-2 は「タグが消えた」ではなく「ブランチが削除されていない」
# として落ちる (実測確認済み。タグ fixture を外すと同じ mutation が全 TC 緑を通る)。
_setup_err=$(LC_ALL=C git push -q origin "HEAD:refs/tags/$BRANCH" 2>&1) \
  || { echo "FATAL: 同名タグの push に失敗: $_setup_err"; exit 1; }
tag_present() { git ls-remote origin "refs/tags/$BRANCH" 2>/dev/null | grep -q .; }
tag_present || { echo "FATAL: 同名タグが origin に存在しない — namespace 修飾の pin が vacuous になる"; exit 1; }

# 対象ブランチが **完全一致で** origin に存在するか。`git ls-remote --exit-code` の rc は入れ子衝突
# ref への tail 一致で 0 になるため、テスト側の検証も完全一致で行わないと「削除されていない」と
# 誤診断する (ガード本体に入れた完全一致検証と同じ理由)。
branch_exists_exact() {
  LC_ALL=C git ls-remote --heads origin "refs/heads/$BRANCH" 2>/dev/null \
    | awk -F'\t' -v r="refs/heads/$BRANCH" '$2 == r { found = 1 } END { exit !found }'
}

# ─── TC-1 (T-01 / AC-1): ref 不在 → push --delete を呼ばず ALREADY_ABSENT ───
echo "TC-1: absent remote ref -> no push --delete, REMOTE_BRANCH_ALREADY_ABSENT"
out=$(run_guard "$GUARD_SNIPPET")
if push_delete_called; then
  fail "TC-1: git push origin --delete が呼ばれた ($(cat "$CALL_LOG"))"
elif ! printf '%s' "$out" | grep -qE "^\[CONTEXT\] REMOTE_BRANCH_ALREADY_ABSENT=1; branch=$BRANCH(;|\$)"; then
  # 照合はステップ 12 の consumer 側と同形で行う。「行頭 + `[CONTEXT] ` 込み」だけでなく
  # **`; branch=<値>` の右端境界 (直後が `;` または行末) まで**要求する。consumer は marker を
  # branch= までスコープして照合するため emitter の branch= は load-bearing だが、marker 名までしか
  # 見ない形では `; branch=...` を落とす mutation が素通りする (実測で全 TC 緑を確認済み)。
  # その退行が起きると consumer 側は全ルール不一致 → fallback へ落ち、削除成功でも
  # 「削除結果を確認できませんでした」と報告する (本 Issue が塞いだ誤報告クラスの復活)。
  fail "TC-1: REMOTE_BRANCH_ALREADY_ABSENT marker が branch= スコープ込みで行頭に出ていない (出力: '$out')"
elif printf '%s' "$out" | grep -q '^error:'; then
  fail "TC-1: error: 行が出力された (AC-1 違反。出力: '$out')"
else
  # ここでタグ非削除を assert しない — TC-1 は存在確認が不在 (rc=2) に落ちて push 自体を呼ばない
  # ため、修飾が外れていてもタグは無傷であり、assertion は構造的に到達不能になる。タグ fixture の
  # 回帰 net は TC-2 側 (ambiguous dst による push 失敗) が担う。
  pass "TC-1 (削除を試行せず既削除として marker を emit)"
fi

# ─── TC-2 (T-02 / AC-2): ref 存在 → 削除経路へ入りリモートから消える ───
echo "TC-2: existing remote ref -> push --delete runs and the ref is gone (backward compat)"
git switch -qc "$BRANCH" 2>/dev/null
echo "v2" > file.txt
_setup_err=$({ LC_ALL=C git add -A && LC_ALL=C git commit -qm work && LC_ALL=C git push -q origin "$BRANCH"; } 2>&1) \
  || { echo "FATAL: TC-2 setup: commit/push に失敗: $_setup_err"; exit 1; }
git switch -q main
branch_exists_exact \
  || { echo "FATAL: TC-2 setup: origin へのブランチ push に失敗"; exit 1; }
out=$(run_guard "$GUARD_SNIPPET")
if ! push_delete_called; then
  fail "TC-2: git push origin --delete が呼ばれていない (delete_branch_on_merge:false 環境の機能後退)"
elif branch_exists_exact; then
  fail "TC-2: リモートブランチが削除されていない (削除先の refs/heads/ 修飾が外れ、同名タグとの ambiguous dst で push が失敗した可能性)"
elif ! printf '%s' "$out" | grep -qE "^\[CONTEXT\] REMOTE_BRANCH_DELETED=1; branch=$BRANCH(;|\$)"; then
  # ステップ 12 の契約は全 emit 経路が marker を出すこと。成功も positive marker で表さないと
  # 「marker 不在 = 削除成功」に戻り、ステップ 5 の未実行と削除成功が区別できなくなる (#2016)。
  # branch= の右端境界まで要求する理由は TC-1 と同じ。
  fail "TC-2: 削除成功の marker REMOTE_BRANCH_DELETED が branch= スコープ込みで行頭に出ていない。ステップ 12 が marker 不在を成功と読む契約に退行する (出力: '$out')"
elif printf '%s' "$out" | grep -qE 'REMOTE_BRANCH_(DELETE_FAILED|CHECK_FAILED|ALREADY_ABSENT)'; then
  # 失敗系 3 marker は正常系で出てはならない。非アンカーで照合するのは意図的 — prefix の有無や
  # 行中/行頭に関わらず「出ていること」を捕捉したいので、アンカーすると検出範囲が狭まる。
  fail "TC-2: 削除成功なのに失敗系 marker が出た。ステップ 12 が正常系を未完了と報告する (出力: '$out')"
elif ! tag_present; then
  # 到達しにくいが残す — 将来 fixture が変わりタグのみが存在する状態で本 TC が走る場合の net。
  fail "TC-2: ブランチ削除に伴って同名タグ refs/tags/$BRANCH まで消えた (削除先の refs/heads/ 修飾が外れている)"
else
  pass "TC-2 (従来どおりリモートブランチを削除、REMOTE_BRANCH_DELETED を emit し失敗系 marker は不在)"
fi

# ─── TC-2b (AC-1/AC-4): rc=0 経路で push --delete が失敗 → REMOTE_BRANCH_DELETE_FAILED ───
# ステップ 12 は「REMOTE_BRANCH_* marker 不在 = 削除成功」と解釈するため、この分岐が marker を
# 出さないと削除失敗が完了 (`x`) として報告される。receive.denyDeletes で server 側拒否を再現する。
echo "TC-2b: push --delete failure -> REMOTE_BRANCH_DELETE_FAILED (not silent success)"
git switch -qc "$BRANCH" 2>/dev/null || git switch -q "$BRANCH"
echo "v3" > file.txt
_setup_err=$({ LC_ALL=C git add -A && LC_ALL=C git commit -qm work2 && LC_ALL=C git push -q origin "$BRANCH"; } 2>&1) \
  || { echo "FATAL: TC-2b setup: commit/push に失敗: $_setup_err"; exit 1; }
git switch -q main
# setup の成立を TC-2 と同形の precondition で確認する。ここを assertion 段まで遅延させると、
# setup 失敗が「marker が出ていない」という誤った診断に化ける。
branch_exists_exact \
  || { echo "FATAL: TC-2b setup: origin へのブランチ push に失敗"; exit 1; }
git -C "$ORIGIN" config receive.denyDeletes true
out=$(run_guard "$GUARD_SNIPPET")
git -C "$ORIGIN" config --unset receive.denyDeletes
# ref 残存（= setup が実際に削除を阻止できたか）を marker チェックより先に評価する。
# denyDeletes が効かない環境では push が成功して marker が出ないため、順序が逆だと
# 「marker が surface されていない」という真因と異なる診断になる。
if ! push_delete_called; then
  fail "TC-2b: setup 不備 — ref が存在するのに push --delete が呼ばれていない"
elif ! branch_exists_exact; then
  fail "TC-2b: setup 不備 — 削除が拒否されたはずだがリモート ref が消えている (receive.denyDeletes が効いていない)"
elif ! printf '%s' "$out" | grep -qE "^\[CONTEXT\] REMOTE_BRANCH_DELETE_FAILED=1; branch=$BRANCH(;|\$)"; then
  fail "TC-2b: push 失敗が branch= スコープ込みの行頭 marker で surface されていない。ステップ 12 が削除失敗を x と報告する (出力: '$out')"
elif ! printf '%s' "$out" | grep -qE 'denyDeletes|remote rejected'; then
  # TC-3 と対称。`_push_err=$(... 2>&1)` は stdout/stderr を両方飲み込むため、WARNING から
  # $_push_err が落ちると原因情報がゼロになる（ターミナルにも何も残らない）。
  fail "TC-2b: WARNING に push 失敗の原因テキストが載っていない (出力: '$out')"
elif ! delimited_block_indented "$out" "push"; then
  fail "TC-2b: 退避 stderr の行が列 0 から始まっている (data が marker を騙る経路が開く。出力: '$out')"
else
  pass "TC-2b (push 失敗を marker + 原因テキストで surface、退避 stderr は列 0 に到達しない)"
fi
# 後始末。ここで ref が残ると TC-5 の precondition（$BRANCH が origin に不在）が崩れるが、
# その状態は TC-5 precondition 自身が正しい帰属で FATAL にする。ここを致命にすると
# 「teardown 失敗」と誤帰属したうえ後続 4 TC がカスケード中断するため、警告に留めて原因だけ残す。
_td_err=$(LC_ALL=C git push -q origin --delete "refs/heads/$BRANCH" 2>&1) \
  || echo "WARN: TC-2b teardown: $BRANCH の削除に失敗: $_td_err" >&2

# ─── TC-3 (AC-2 / #2140 T-02): ls-remote 自体の恒常失敗 → CHECK_FAILED、削除は試行しない ───
# ネットワーク断・認証失敗は rc=128 になる。#2140 で rc=128 は 1 回リトライするが、
# 2 回とも 128 なら依然 CHECK_FAILED に倒す（transient 吸収は 1 回だけ。恒常失敗を「既削除」に
# 丸めると delete_branch_on_merge:false のリポジトリでリモートブランチが黙って残る）。
echo "TC-3: ls-remote failure (unreachable origin, after 1 retry) -> REMOTE_BRANCH_CHECK_FAILED, no delete attempt"
git remote set-url origin "$TEST_DIR/does-not-exist.git"
out=$(run_guard "$GUARD_SNIPPET")
if push_delete_called; then
  fail "TC-3: 存在判定できていないのに push --delete が呼ばれた ($(cat "$CALL_LOG"))"
elif printf '%s' "$out" | grep -q 'REMOTE_BRANCH_ALREADY_ABSENT=1'; then
  fail "TC-3: ネットワーク失敗を「既削除」に丸めた (出力: '$out')"
elif ! printf '%s' "$out" | grep -qE "^\[CONTEXT\] REMOTE_BRANCH_CHECK_FAILED=1; branch=$BRANCH(;|\$)"; then
  # CHECK_FAILED は `; rc=<n>` が後続するため、右端境界は `;` 側で成立する。
  fail "TC-3: REMOTE_BRANCH_CHECK_FAILED marker が branch= スコープ込みで行頭に出ていない (出力: '$out')"
elif ! printf '%s' "$out" | grep -q 'does not appear to be a git repository'; then
  # ガードは stderr のみを退避して WARNING に載せる設計 (stdout は完全一致検証に使うため別ファイルへ
  # 分離する)。退避の向きを取り違えると原因が消え rc だけになる（認証失敗・DNS 解決失敗・
  # proxy 遮断がすべて 128 に潰れて切り分け不能になる）。LC_ALL=C 固定で文言は安定する。
  fail "TC-3: WARNING に ls-remote の原因テキストが載っていない (stderr 退避の順序が壊れた可能性。出力: '$out')"
elif ! delimited_block_indented "$out" "ls-remote"; then
  fail "TC-3: 退避 stderr の行が列 0 から始まっている (data が marker を騙る経路が開く。出力: '$out')"
else
  pass "TC-3 (判定不能を未完了として surface、原因テキストも保持、退避 stderr は列 0 に到達しない)"
fi
git remote set-url origin "$ORIGIN"

# ─── TC-3b (AC-1 / #2140 T-01): 1 回目 rc=128 → 2 回目 rc=2 で不在判定・削除処方なし ───
# sandbox の HTTPS プロキシ断で 1 回目だけ 128 になり、2 回目で正常応答する経路の pin。
# git wrapper が ls-remote の 1 回目だけ fatal を返し、2 回目以降は REAL_GIT に委譲する。
echo "TC-3b: ls-remote 128 then 2 -> REMOTE_BRANCH_ALREADY_ABSENT, no delete prescription"
_ls_count_file="$TEST_DIR/ls-remote-count"
: > "$_ls_count_file"
cat > "$BIN_DIR/git" <<EOF
#!/bin/bash
if [ "\${1:-}" = "push" ]; then printf '%s\n' "push \$*" >> "$CALL_LOG"; fi
if [ "\${1:-}" = "ls-remote" ] || { [ "\${1:-}" = "-C" ] && [ "\${3:-}" = "ls-remote" ]; }; then
  # 直書きの ls-remote を数える（ガードは \`git ls-remote\` 形）
  :
fi
if [ "\${1:-}" = "ls-remote" ]; then
  n=\$(cat "$_ls_count_file" 2>/dev/null || echo 0)
  n=\$((n + 1))
  printf '%s' "\$n" > "$_ls_count_file"
  if [ "\$n" -eq 1 ]; then
    echo "fatal: unable to access 'origin': Failed to connect to localhost port 3128" >&2
    exit 128
  fi
fi
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$BIN_DIR/git"
out=$(run_guard "$GUARD_SNIPPET")
_ls_n=$(cat "$_ls_count_file" 2>/dev/null || echo 0)
# 後始末: 通常の stub に戻す（以降 TC が transient mock に引きずられないようにする）
cat > "$BIN_DIR/git" <<EOF
#!/bin/bash
if [ "\${1:-}" = "push" ]; then printf '%s\n' "push \$*" >> "$CALL_LOG"; fi
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$BIN_DIR/git"
if [ "$_ls_n" -lt 2 ]; then
  fail "TC-3b: ls-remote が 2 回呼ばれていない (count=$_ls_n — 128 リトライが消失した可能性。出力: '$out')"
elif push_delete_called; then
  fail "TC-3b: 不在判定後に push --delete が呼ばれた ($(cat "$CALL_LOG"))"
elif ! printf '%s' "$out" | grep -qE "^\[CONTEXT\] REMOTE_BRANCH_ALREADY_ABSENT=1; branch=$BRANCH(;|\$)"; then
  fail "TC-3b: 128→2 の遷移で ALREADY_ABSENT になっていない (出力: '$out')"
elif printf '%s' "$out" | grep -q 'REMOTE_BRANCH_CHECK_FAILED=1'; then
  fail "TC-3b: リトライ成功後も CHECK_FAILED を出した (出力: '$out')"
else
  pass "TC-3b (128→2 の transient を吸収し不在判定・削除処方なし)"
fi

# ─── TC-7 (#2016 cycle 3): 契約を満たせないブランチ名は削除を試行しない (fail-fast) ───
# marker 契約は `branch=<値>` の右端を「直後が `;` または行末」で照合する。`;` と `=` はどちらも
# 合法な refname 文字なので、これらを含む名前を marker に載せると別ブランチの判定ルールへ誤帰属
# しうる。ガードは実ブランチ名を載せず sentinel を出して consumer を fallback (未確認) へ倒す。
echo "TC-7: invalid branch name (marker delimiters) -> fail-fast, no push --delete, sentinel marker"
EVIL_BRANCH="fix/issue-2016;branch=other"
EVIL_SNIPPET="$TEST_DIR/guard-evil.sh"
extract_guard_as "$EVIL_BRANCH" > "$EVIL_SNIPPET"
out=$(run_guard "$EVIL_SNIPPET")
if push_delete_called; then
  fail "TC-7: 契約を満たせないブランチ名なのに push --delete が呼ばれた ($(cat "$CALL_LOG"))"
elif ! printf '%s' "$out" | grep -q '^\[CONTEXT\] REMOTE_BRANCH_CHECK_FAILED=1; branch=<unsupported branch name>; rc=marker-delimiter-in-branch-name'; then
  fail "TC-7: fail-fast の sentinel marker が行頭に出ていない (出力: '$out')"
elif printf '%s' "$out" | grep -q "^\[CONTEXT\].*branch=$EVIL_BRANCH"; then
  # 実ブランチ名を marker に載せると `branch=other` が別ブランチのルールに右端境界で一致する。
  fail "TC-7: marker 行に実ブランチ名が載っている (guard が防ぐはずの誤帰属経路が開いたまま。出力: '$out')"
else
  pass "TC-7 (契約外のブランチ名は削除を試行せず sentinel で fallback へ倒す)"
fi

echo "TC-7b: remote invalid/non-canonical names and mktemp failure are fail-fast"
tc7b_fail=""
for _bad in "fix/trailing "; do
  _bad_snippet="$TEST_DIR/guard-bad-${RANDOM}.sh"
  extract_guard_as "$_bad" > "$_bad_snippet"
  out=$(run_guard "$_bad_snippet")
  printf '%s' "$out" | grep -q '^\[CONTEXT\] REMOTE_BRANCH_CHECK_FAILED=1' \
    || tc7b_fail="remote bad name が CHECK_FAILED にならない: $_bad (出力: '$out')"
  [ -z "$tc7b_fail" ] && push_delete_called && tc7b_fail="remote bad name で push delete が呼ばれた: $_bad"
done
if [ -z "$tc7b_fail" ]; then
  : > "$CALL_LOG"
  out=$(TMPDIR="$TEST_DIR/does-not-exist" PATH="$BIN_DIR:$PATH" bash "$GUARD_SNIPPET" 2>&1)
  printf '%s' "$out" | grep -q 'rc=mktemp-failed' || tc7b_fail="mktemp 失敗が marker で surface されない (出力: '$out')"
  [ -z "$tc7b_fail" ] && push_delete_called && tc7b_fail="mktemp 失敗時に push delete が呼ばれた"
fi
if [ -z "$tc7b_fail" ]; then
  _unverified="$TEST_DIR/guard-unverified.sh"
  sed 's/\[ "true" != "true" \]/[ "false" != "true" ]/' "$GUARD_SNIPPET" > "$_unverified"
  out=$(run_guard "$_unverified")
  printf '%s' "$out" | grep -q 'rc=branch-identity-unverified' || tc7b_fail="identity 未確認が拒否されない"
  [ -z "$tc7b_fail" ] && push_delete_called && tc7b_fail="identity 未確認で push delete が呼ばれた"
fi
if [ -n "$tc7b_fail" ]; then fail "TC-7b: $tc7b_fail"; else pass "TC-7b (remote preflight/mktemp failure は削除未試行)"; fi

echo "TC-7c: exact-ref awk failure is CHECK_FAILED, not ALREADY_ABSENT"
cat > "$BIN_DIR/awk" <<'EOF'
#!/bin/bash
exit 2
EOF
chmod +x "$BIN_DIR/awk"
out=$(run_guard "$GUARD_SNIPPET")
rm -f "$BIN_DIR/awk"
if ! printf '%s' "$out" | grep -q 'reason=ref-match-awk-2'; then
  fail "TC-7c: awk rc=2 が reason 付き CHECK_FAILED にならない (出力: '$out')"
elif printf '%s' "$out" | grep -q 'REMOTE_BRANCH_ALREADY_ABSENT'; then
  fail "TC-7c: awk 異常終了を既削除へ丸めた"
elif push_delete_called; then
  fail "TC-7c: awk 異常終了時に push delete が呼ばれた"
else
  pass "TC-7c (awk 異常終了を判定不能として surface)"
fi

# ─── TC-8 (#2016 cycle 4): ローカル削除ブロックの事前検証と存在確認 rc 分岐 ───
# ローカルブロックは cycle 3 まで抽出対象外で、fail-fast と rc 3 分岐のどちらも無検証だった
# (実測で両方を revert しても全 TC 緑)。emitter 側を実行して pin する。
echo "TC-8: local delete block -> fail-fast on invalid names, rc=1 only means absent"
LOCAL_RUN="$TEST_DIR/local-run.sh"
# TC-3/3b の retry fixture が git stub を上書きするため、local 検査前に canonical call logger を復元する。
cat > "$BIN_DIR/git" <<EOF
#!/bin/bash
if [ "\${1:-}" = "push" ] || [ "\${1:-}" = "branch" ]; then printf '%s\n' "\$*" >> "$CALL_LOG"; fi
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$BIN_DIR/git"
: > "$CALL_LOG"
PATH="$BIN_DIR:$PATH" git branch -D -- definitely-not-a-real-branch >/dev/null 2>&1 || true
if ! branch_delete_called; then
  echo "FATAL: branch delete call logger が既知の delete probe を記録しません — TC-8 の negative assertions は vacuous です"
  exit 1
fi
run_local() {
  : > "$CALL_LOG"
  extract_local_guard_as "$1" > "$LOCAL_RUN"
  PATH="$BIN_DIR:$PATH" bash "$LOCAL_RUN" 2>&1
}
tc8_fail=""
# (a) デリミタ含みの名前 -> sentinel、実名を marker に載せない
out=$(run_local "fix/issue-2016;branch=other")
printf '%s' "$out" | grep -q '^\[CONTEXT\] BRANCH_CHECK_FAILED=1; branch=<unsupported branch name>; rc=marker-delimiter-in-branch-name' \
  || tc8_fail="デリミタ含みの名前で sentinel marker が行頭に出ていない (出力: '$out')"
[ -z "$tc8_fail" ] && { printf '%s' "$out" | grep -q 'branch=fix/issue-2016;branch=other' \
  && tc8_fail="marker 行に実ブランチ名が載っている (誤帰属経路が開いたまま)"; }
[ -z "$tc8_fail" ] && branch_delete_called && tc8_fail="デリミタ含み入力で git branch delete が呼ばれた"
# (b) 空名 -> sentinel。必ず失敗する処方 (`git branch -D ""`) を出さない
if [ -z "$tc8_fail" ]; then
  out=$(run_local "")
  printf '%s' "$out" | grep -q '^\[CONTEXT\] BRANCH_CHECK_FAILED=1; branch=<unsupported branch name>; rc=empty-branch-name' \
    || tc8_fail="空ブランチ名で sentinel marker が行頭に出ていない (出力: '$out')"
  [ -z "$tc8_fail" ] && { printf '%s' "$out" | grep -q 'git branch -D ""' \
    && tc8_fail="空ブランチ名に対して必ず失敗する処方 git branch -D \"\" を提示している"; }
  [ -z "$tc8_fail" ] && branch_delete_called && tc8_fail="空ブランチ名で git branch delete が呼ばれた"
fi
# (c) refname 非合法 (末尾空白) -> 「既削除」に丸めない
if [ -z "$tc8_fail" ]; then
  out=$(run_local "fix/trailing ")
  printf '%s' "$out" | grep -q '^\[CONTEXT\] BRANCH_CHECK_FAILED=1; branch=fix/trailing ; rc=invalid-refname' \
    || tc8_fail="refname 非合法な名前が invalid-refname として surface されていない (出力: '$out')"
  [ -z "$tc8_fail" ] && { printf '%s' "$out" | grep -q 'BRANCH_ALREADY_ABSENT' \
    && tc8_fail="refname 非合法な名前を「既削除 = 正常系」に丸めた (削除していないのに完了と報告する)"; }
  [ -z "$tc8_fail" ] && branch_delete_called && tc8_fail="refname 非合法入力で git branch delete が呼ばれた"
fi
# (d) identity 未確認は名前の形に依存せず拒否
if [ -z "$tc8_fail" ]; then
  extract_local_guard_as "upstream/foo" | sed 's/\[ "true" != "true" \]/[ "false" != "true" ]/' > "$LOCAL_RUN"
  : > "$CALL_LOG"; out=$(PATH="$BIN_DIR:$PATH" bash "$LOCAL_RUN" 2>&1)
  printf '%s' "$out" | grep -q 'rc=branch-identity-unverified' \
    || tc8_fail="identity 未確認入力が拒否されていない (出力: '$out')"
  [ -z "$tc8_fail" ] && branch_delete_called && tc8_fail="identity 未確認入力で git branch delete が呼ばれた"
fi
# (e) 本当に不在 -> 正常系
if [ -z "$tc8_fail" ]; then
  out=$(run_local "fix/definitely-absent")
  printf '%s' "$out" | grep -q '^\[CONTEXT\] BRANCH_ALREADY_ABSENT=1; branch=fix/definitely-absent' \
    || tc8_fail="不在ブランチが BRANCH_ALREADY_ABSENT (正常系) になっていない (出力: '$out')"
fi
if [ -n "$tc8_fail" ]; then
  fail "TC-8: $tc8_fail"
else
  pass "TC-8 (契約外の名前は削除を試行せず surface、rc=1 のみを既削除として扱う)"
fi

# ─── TC-9 (#2016 cycle 4): 存在確認が判定不能なとき「既削除」に丸めない ───
# cycle 1 の修正が rc=1 と rc=128 を融合し、cycle 2 で HIGH の回帰として検出された経路。
# 非 git ディレクトリを cwd にして show-ref を rc=128 にする。
echo "TC-9: local existence check failure (rc!=0/1) -> BRANCH_CHECK_FAILED, not ALREADY_ABSENT"
NONREPO="$TEST_DIR/nonrepo"; mkdir -p "$NONREPO"
extract_local_guard_as "fix/whatever" > "$NONREPO/run.sh"
out=$(cd "$NONREPO" && PATH="$BIN_DIR:$PATH" bash ./run.sh 2>&1)
if printf '%s' "$out" | grep -q 'BRANCH_ALREADY_ABSENT'; then
  fail "TC-9: 判定不能 (rc=128) を「既削除」に丸めた — cycle 1 の回帰そのもの (出力: '$out')"
elif ! printf '%s' "$out" | grep -qE '^\[CONTEXT\] BRANCH_CHECK_FAILED=1; branch=fix/whatever; rc=[0-9]+'; then
  fail "TC-9: BRANCH_CHECK_FAILED が行頭 marker で surface されていない (出力: '$out')"
elif ! delimited_block_indented "$out" "show-ref"; then
  fail "TC-9: 退避 stderr の行が列 0 から始まっている (出力: '$out')"
else
  pass "TC-9 (判定不能を未完了として surface、原因テキストも列 0 に到達しない)"
fi

echo "TC-9b: broken loose ref warning -> BRANCH_CHECK_FAILED, no delete"
mkdir -p .git/refs/heads
printf 'bad\n' > .git/refs/heads/broken
out=$(run_local "broken")
rm -f .git/refs/heads/broken
if ! printf '%s' "$out" | grep -q 'rc=ref-store-0'; then
  fail "TC-9b: for-each-ref rc=0 + warning を判定不能として surface しない (出力: '$out')"
elif printf '%s' "$out" | grep -q 'BRANCH_ALREADY_ABSENT'; then
  fail "TC-9b: broken ref を既削除へ丸めた"
elif branch_delete_called; then
  fail "TC-9b: broken ref で git branch delete が呼ばれた"
else
  pass "TC-9b (ref-store warning を判定不能として surface、削除未試行)"
fi

# ─── TC-4 (T-03 / AC-3): merge/SKILL.md の設計判断が保証を主張していない ───
# 「保証する」literal の不在だけを見ると「必ず残ることを保証します」等の言い換えを素通しするため
# (実測で確認)、AC-3 が要求する性質「できないことを明示している」を否定語の存在で肯定的に assert する。
echo "TC-4: merge/SKILL.md states what --delete-branch=false can and cannot suppress"
# 検査対象は bullet 全体。marker 行だけを見ると、設計判断を複数行に分割するだけで assertion を
# 回避できる。次の bullet または空行までを 1 単位として抽出する。
decision=$(awk '
  /^- \*\*`--delete-branch=false` 明示\*\*/ { f=1; print; next }
  f && (/^- \*\*/ || /^[[:space:]]*$/) { exit }
  f { print }
' "$MERGE_MD")
if [ -z "$decision" ]; then
  fail "TC-4: merge/SKILL.md に --delete-branch=false の設計判断項目が見つからない"
elif printf '%s' "$decision" | grep -qE '保証する|保証します|保証される|保証できる'; then
  fail "TC-4: 全称的な保証の主張が残っている: $decision"
elif ! printf '%s' "$decision" | grep -q 'delete_branch_on_merge'; then
  fail "TC-4: サーバサイド auto-delete (delete_branch_on_merge) への言及がない: $decision"
elif ! printf '%s' "$decision" | grep -qE '保証されない|担保されない|止められない|抑止できない'; then
  # 否定表現は **単体で否定を含意するもの** に限る。「抑止できるのは」のような断片を alternation に
  # 混ぜると、後続が「…だけである。よってマージ後はブランチが必ず残る」という過大主張でもマッチし、
  # AC-3 が禁じている当の違反に false confidence を与える (実測で確認)。
  fail "TC-4: 「抑止できないもの」を明示する否定表現がない (AC-3 が求める区別に届いていない): $decision"
elif ! printf '%s' "$decision" | grep -qE '抑止できるのは.*(gh|クライアント)'; then
  # AC-3 は「できる側」と「できない側」の**区別**を要求する。否定表現だけを pin すると、
  # 「できる側」を丸ごと削って冗長さを整理する編集で AC-3 の半分が無防備になる (実測で緑を確認済み)。
  fail "TC-4: 「抑止できるもの (gh クライアント側の削除)」の明示がない (AC-3 の片側のみ)"
else
  # 設計判断 bullet は内部 rationale で、ユーザーが読むのはステップ 3 の完了通知の方。
  # 欠陥 1 のユーザー可視な現れはそちらなので、旧文言の不在と新契約の存在を両方 pin する
  # (不在だけだと別の言い換えを素通しする)。
  branch_line=$(grep -n '^- ブランチ: {branch_name}' "$MERGE_MD" | head -1 | cut -d: -f2-)
  if [ -z "$branch_line" ]; then
    fail "TC-4: merge/SKILL.md の完了通知に '- ブランチ: {branch_name}' 行がない (アンカーが変更された可能性)"
  elif printf '%s' "$branch_line" | grep -q 'まだ削除されていません'; then
    fail "TC-4: 完了通知が「まだ削除されていません」に戻っている (delete_branch_on_merge: true では事実虚偽)"
  elif ! printf '%s' "$branch_line" | grep -q 'delete_branch_on_merge'; then
    fail "TC-4: 完了通知がリモート側の既削除可能性 (delete_branch_on_merge) に言及していない"
  elif ! printf '%s' "$branch_line" | grep -q '既に削除'; then
    # 語彙 (旧文言の不在 + トークンの存在) だけでは、同じ語彙で意味を反転した文が通る。
    # 「リモートは既に削除されている場合がある」という命題そのものを要求する。
    fail "TC-4: 完了通知が「リモートは既に削除済みの場合がある」旨を述べていない (語彙は揃うが命題が逆の文を通す)"
  elif printf '%s' "$branch_line" | grep -qE '必ず残|削除されません|残り続け'; then
    # 命題の否定形も禁止する。肯定の存在だけを要求すると、肯定と否定を同居させる文で回避できる。
    fail "TC-4: 完了通知が「リモートブランチは必ず残る」と主張している (#2016 が是正した過大主張の再導入)"
  else
    pass "TC-4 (設計判断と完了通知の双方が抑止できるもの/できないものを区別して記述)"
  fi
fi

# ─── TC-6 (AC-4): ステップ 12 リモート側判定の契約を pin する ───
# emitter (ステップ 5 のガード) だけを検証すると consumer (完了報告の判定ルール) が無防備になる。
# ステップ 12 の契約は全 emit 経路が marker を出すこと。
# 当該ブロックを削除する mutation でも全スイートが green になっていたため、散文側も静的に pin する。
echo "TC-6: cleanup/SKILL.md ステップ 12 pins the remote-side judgement rules"
remote_section=$(awk '/^  \*\*リモート側\*\*/{f=1} f{print} f && /^- `\{projects_status_result\}/{found=1; exit} END{exit !found}' "$CLEANUP_MD")
awk_rc=$?
tc6_fail=""
# 散文 pin の positive control。本ファイルは「pin が見出しラベルや語彙にだけ一致し、operative な
# 命題を捉えていない」欠陥を繰り返し出した (デリミタ pin・行頭一致 pin が、いずれも太字見出しだけで
# 充足していた)。pin を足すたびに人手で確かめる運用は同じ穴を再生産するので、pin 自身に対して
# 「弱化形にはマッチしないこと」を機械的に要求する。_brace_detect の positive control と同じ規律。
#   $1 検査対象テキスト / $2 pin パターン (grep -E) / $3 弱化形 probe / $4 失敗時の説明
assert_prose_pin() {
  local _text="$1" _pattern="$2" _probe="$3" _label="$4"
  [ -n "$tc6_fail" ] && return 0
  if ! printf '%s' "$_text" | grep -qE "$_pattern"; then
    tc6_fail="$_label"
    return 0
  fi
  # probe は「規約を弱めた形／見出しだけ残した形」。ここに一致する pin は命題を捉えていない。
  if printf '%s' "$_probe" | grep -qE "$_pattern"; then
    tc6_fail="pin が弱すぎる: $_label のパターンが弱化形にも一致する (命題ではなく語彙を捉えている)"
  fi
}
# 抽出の両端を検査する。**空抽出 (開始アンカー消失) を先に判定する** — 開始アンカーが消えると
# awk は f=0 のまま閉じアンカー規則に到達せず found=0 → rc=1 を返すため、rc ゲートを先に置くと
# 開始アンカー消失まで「over-capture」と誤診断してしまう (保守者が反対側の端を調べることになる)。
[ -n "$remote_section" ] || tc6_fail="リモート側 section が空 (開始アンカー **リモート側** が変更された可能性)"
# 閉じアンカー消失は awk が EOF まで走って section スコープが実質無効化される (over-capture)。
[ -z "$tc6_fail" ] && { [ "$awk_rc" -eq 0 ] || tc6_fail="リモート側 section の閉じアンカー (- \`{projects_status_result}\`) に到達しなかった (over-capture)"; }
# 各ルールは marker 名だけでなく **判定値そのものと処方コマンド** まで pin する。救済文言だけを
# 要求する形では、文言を残したまま判定値を ` `(未完了) → `x`(完了) に反転する mutation を素通しし、
# 本 Issue の headline 欠陥（削除失敗が完了として報告される）をそのまま通す。処方コマンドまで
# 含めるのは、リモート用 `git push origin --delete` をローカル用 `git branch -D` に差し替える
# 誤処方（アンカー化規約が防ごうとしているもの）も同時に捕捉するため。
[ -z "$tc6_fail" ] && { printf '%s' "$remote_section" | grep -qE 'REMOTE_BRANCH_DELETE_FAILED=1.*: ` ` \+.*git push origin --delete' || tc6_fail="REMOTE_BRANCH_DELETE_FAILED が「未完了 ` ` + git push origin --delete での手動削除」になっていない"; }
[ -z "$tc6_fail" ] && { printf '%s' "$remote_section" | grep -qE 'REMOTE_BRANCH_CHECK_FAILED=1.*: ` ` \+.*削除.*試行.*ls-remote --exit-code --heads' || tc6_fail="REMOTE_BRANCH_CHECK_FAILED が「未完了 ` ` + 削除未試行の案内」になっていない"; }
[ -z "$tc6_fail" ] && { printf '%s' "$remote_section" | grep -qE 'REMOTE_BRANCH_ALREADY_ABSENT=1.*: `x`' || tc6_fail="REMOTE_BRANCH_ALREADY_ABSENT が x (正常系) に割り当てられていない"; }
[ -z "$tc6_fail" ] && { printf '%s' "$remote_section" | grep -qE 'REMOTE_BRANCH_DELETED=1.*: `x`' || tc6_fail="REMOTE_BRANCH_DELETED が x (正常系) に割り当てられていない"; }
[ -z "$tc6_fail" ] && { printf '%s' "$remote_section" | grep -q 'REMOTE_BRANCH_\*' || tc6_fail="リモート側 fallback が REMOTE_BRANCH_* の marker family でスコープされていない"; }
# marker の branch= スコープ。batch-run は同一セッションで Issue ごとに cleanup をループ invoke する
# ため、先行 Issue の stale marker が後続 Issue の判定に一致する。リモート側は失敗ルールが先頭なので、
# スコープが落ちると stale な失敗が自分の成功を必ず上書きする (既削除に対する誤処方)。
# section 内に 1 箇所あれば通る形では弱い (fallback だけスコープが残っていても緑になる)。
# 4 ルールそれぞれが marker 名の直後に branch= を持つことを個別に要求する。
for _m in REMOTE_BRANCH_DELETE_FAILED REMOTE_BRANCH_CHECK_FAILED REMOTE_BRANCH_ALREADY_ABSENT REMOTE_BRANCH_DELETED; do
  [ -n "$tc6_fail" ] && break
  printf '%s' "$remote_section" | grep -q "$_m=1; branch={branch_name}" \
    || tc6_fail="リモート側ルール $_m が branch={branch_name} までスコープされていない (batch-run の stale marker に誤一致する)"
done
# fallback の判定値。marker 不在を `x` に倒す mutation は「ステップ 5 が実行されなかった」と
# 「削除成功」を再び同一視し、本 Issue が塞いだ false-success を判定表側から復活させる。
# 判定値 (` `) と「成功と読むな」の禁止文の両方を要求する — 判定値だけだと禁止根拠が消え、
# 禁止文だけだと値の反転を素通しする。
[ -z "$tc6_fail" ] && { printf '%s' "$remote_section" | grep -qE 'REMOTE_BRANCH_\*.*無いとき: ` ` \+' || tc6_fail="リモート側 fallback が未完了 ` ` になっていない (marker 不在を削除成功と読む契約に退行)"; }
[ -z "$tc6_fail" ] && { printf '%s' "$remote_section" | grep -qE '不在.*削除成功.*(ならない|いけない)' || tc6_fail="リモート側 fallback に marker 不在を成功と読む禁止文がない"; }
# 判定ブロック全体 (ローカル側 + リモート側を含む {local_branch_check} の箇条書き) を抽出する。
# 以下 2 本の grep をファイル全体ではなくここへスコープする — ファイル全体を対象にすると、
# 判定ブロックから当該文を削除して「過去の設計では…」等の歴史メモへ格下げしても、文字列が
# どこかに残っていれば PASS してしまう。
judgement_block=$(awk '/^- `\{local_branch_check\}`/{f=1} f && /^- `\{projects_status_result\}`/{found=1; exit} f{print} END{exit !found}' "$CLEANUP_MD")
jb_rc=$?
[ -z "$tc6_fail" ] && { [ -n "$judgement_block" ] || tc6_fail="{local_branch_check} の判定ブロックを抽出できない"; }
[ -z "$tc6_fail" ] && { [ "$jb_rc" -eq 0 ] || tc6_fail="判定ブロックの閉じアンカーに到達しなかった (over-capture — スコープ限定が無効化されている)"; }
# 両側独立評価の AND ルール文 (ローカル成功でリモート失敗が握り潰される回帰の pin)
assert_prose_pin "$judgement_block" '両方が `x` 相当のとき(だけ|に限り) `x`' \
  'ローカル側判定とリモート側判定を独立に評価する' \
  "ローカル/リモート独立評価の AND ルール文が判定ブロックにない"
# marker 名の部分文字列衝突: REMOTE_BRANCH_DELETE_FAILED ⊃ BRANCH_DELETE_FAILED のため、
# ローカル側ルールが非アンカーだとリモート marker 行に誤一致し誤処方になる。
# ローカル側の 4 ルール + fallback がすべて `[CONTEXT] ` prefix 込みでアンカーされていることを pin。
local_section=$(awk '/^  \*\*ローカル側\*\*/{f=1} f && /^  \*\*リモート側\*\*/{exit} f{print}' "$CLEANUP_MD")
[ -z "$tc6_fail" ] && { [ -n "$local_section" ] || tc6_fail="ローカル側 section が空 (開始アンカー **ローカル側** が変更された可能性)"; }
if [ -z "$tc6_fail" ]; then
  unanchored=$(printf '%s\n' "$local_section" | grep -nE '^  - `BRANCH_DELETE'); grep_rc=$?
  case "$grep_rc" in
    0) tc6_fail="ローカル側ルールが非アンカー (REMOTE_BRANCH_DELETE_FAILED に誤一致する): $unanchored" ;;
    1) : ;;  # 非アンカー行なし (期待動作)
    *) tc6_fail="ローカル側アンカー検査の grep が IO エラー (rc=$grep_rc)" ;;
  esac
fi
# ローカル側 fallback の marker family スコープ (リモート側と対称に pin する)。無条件形へ戻す
# mutation が素通りしていたため追加。SKILL.md 自身がこの形を「リモート側 marker の存在で偽になり
# 判定が破綻する」と明記して禁じている。
[ -z "$tc6_fail" ] && { printf '%s' "$local_section" | grep -q 'BRANCH_DELETE_\*' || tc6_fail="ローカル側 fallback が marker family でスコープされていない"; }
# ローカル側 fallback の判定値。リモート側と同じ到達条件なので同じ意味 (` ` = 未確認) でなければ
# ならない。片側だけ `x` に倒す mutation は「同一条件に正反対の意味」という矛盾を復活させる。
[ -z "$tc6_fail" ] && { printf '%s' "$local_section" | grep -qE 'BRANCH_DELETE_\*.*無いとき: ` ` \+' || tc6_fail="ローカル側 fallback が未完了 ` ` になっていない (リモート側と非対称: marker 不在を削除成功と読む契約に退行)"; }
# ローカル側もリモート側と対称に branch= スコープを要求する。grep 対象は $local_section に限定する
# — ファイル全体を対象にするとステップ 5 の emitter コード行 (`echo "[CONTEXT] BRANCH_DELETED=1;
# branch={branch_name}"`) に一致してしまい、判定表側からルールを消しても vacuous に PASS する。
for _m in BRANCH_DELETE_DEFERRED BRANCH_DELETED BRANCH_DELETE_FAILED BRANCH_DELETE_UNMERGED BRANCH_ALREADY_ABSENT BRANCH_CHECK_FAILED; do
  [ -n "$tc6_fail" ] && break
  printf '%s' "$local_section" | grep -q "\[CONTEXT\] $_m=1; branch={branch_name}" \
    || tc6_fail="ローカル側ルール $_m が branch={branch_name} までスコープされていない (batch-run の stale marker に誤一致する)"
done
[ -z "$tc6_fail" ] && { printf '%s' "$local_section" | grep -q 'BRANCH_DELETE_\*.*branch={branch_name}' || tc6_fail="ローカル側 fallback が branch={branch_name} までスコープされていない"; }
# 「既に不在」を正常系 (`x`) に倒すルール。ローカル側だけこれが無いと、cleanup 再実行時に
# `git branch -d` が "not found" で失敗して BRANCH_DELETE_FAILED に落ち、判定表が
# 「`git branch -D` で手動削除」という**必ず失敗する処方**を出す (リモート側 ALREADY_ABSENT を
# 正常系に倒したのと同型の症状がローカル側に残る、#2016)。fallback の family 列挙にも含める。
[ -z "$tc6_fail" ] && { printf '%s' "$local_section" | grep -qE 'BRANCH_ALREADY_ABSENT=1; branch=\{branch_name\}.*: `x`' || tc6_fail="ローカル側の BRANCH_ALREADY_ABSENT が x (正常系) に割り当てられていない"; }
[ -z "$tc6_fail" ] && { printf '%s' "$local_section" | grep -q 'BRANCH_DELETE_\*.*BRANCH_ALREADY_ABSENT' || tc6_fail="ローカル側 fallback の marker family 列挙に BRANCH_ALREADY_ABSENT が含まれていない"; }
# 「存在確認に失敗 = 判定不能」を正常系に倒さないルール。リモート側 REMOTE_BRANCH_CHECK_FAILED と
# 対称で、これが無いと `git show-ref` の rc=128 (リポジトリ外での実行等) が「既に不在」に丸められ、
# ローカルブランチが残ったまま完了と報告される (#2016)。
[ -z "$tc6_fail" ] && { printf '%s' "$local_section" | grep -qE 'BRANCH_CHECK_FAILED=1; branch=\{branch_name\}.*: ` ` \+' || tc6_fail="ローカル側の BRANCH_CHECK_FAILED が未完了 ` ` になっていない (判定不能を正常系に倒す退行)"; }
[ -z "$tc6_fail" ] && { printf '%s' "$local_section" | grep -q 'BRANCH_DELETE_\*.*BRANCH_CHECK_FAILED' || tc6_fail="ローカル側 fallback の marker family 列挙に BRANCH_CHECK_FAILED が含まれていない"; }
# 3 つ目の marker family ({session_worktree_check}) の fallback スコープ。同一の失敗モードを
# 2 family で pin しておきながら 3 個目を落とすと、旧無条件形へ戻す退行が検出されない。
wt_section=$(awk '/^- `\{session_worktree_check\}`/{f=1} f && /^- `\{local_branch_check\}`/{found=1; exit} f{print} END{exit !found}' "$CLEANUP_MD")
wt_rc=$?
[ -z "$tc6_fail" ] && { [ -n "$wt_section" ] || tc6_fail="{session_worktree_check} section を抽出できない"; }
[ -z "$tc6_fail" ] && { [ "$wt_rc" -eq 0 ] || tc6_fail="{session_worktree_check} section の閉じアンカーに到達しなかった (over-capture)"; }
[ -z "$tc6_fail" ] && { printf '%s' "$wt_section" | grep -q 'WORKTREE_REMOVE_\*' || tc6_fail="{session_worktree_check} fallback が WORKTREE_REMOVE_* の marker family でスコープされていない"; }
# この family は「marker 不在 = 削除成功」が正当 (ステップ 4-W は成功時に marker を出さない)。
# 他 2 family と前提が逆なので、判定値とその根拠の両方を pin する。
[ -z "$tc6_fail" ] && { printf '%s' "$wt_section" | grep -qE 'WORKTREE_REMOVE_\*.*無い（削除成功）とき: `x`' || tc6_fail="{session_worktree_check} fallback の判定値 x が pin されていない"; }
# デリミタ + 肯定/否定とも行頭一致の規約を pin する
# 契約は **サイト非依存の形** で要求する。デリミタを個別に列挙する形 (`--- push stderr ---` /
# `--- ls-remote stderr ---` …) は、退避サイトを増やすたびに列挙更新を忘れて契約とコードが drift する
# (実際にローカル削除側の 3 組目が契約から漏れていた)。probe は旧サイト列挙形。
assert_prose_pin "$judgement_block" 'に挟まれた区間を.*一律 data として扱い' \
  'デリミタに挟まれた行を data として扱い、marker として解釈しない' \
  "退避 stderr の data 扱い規約がサイト非依存の形で判定ブロックにない (サイト列挙形は drift する)"
# recency ルールを pin する
# recency は「存在」だけでなく**適用順序**まで要求する。順序が未規定だと各側見出しの
# 「上から評価し最初に一致」と正面から矛盾し、同一入力に 2 通りの答えが出る。
assert_prose_pin "$judgement_block" '最後の出現を採用.*判定ルールを評価する前' \
  '同一 marker family で複数行が一致したときは最後の出現を採用する' \
  "recency の適用順序 (ルール評価より前) が判定ブロックに明記されていない"
# 各側見出しが 2 段手順になっていること。段の入れ替え禁止まで要求する。
assert_prose_pin "$judgement_block" '段の順序を入れ替えてはならない' \
  '上から評価し最初に一致したものを採用' \
  "各側の見出しが 2 段手順 (recency で 1 行選択 → ルール評価) になっていない"
# branch= の右端。左端だけ塞いで右端を開けたままにしない。
assert_prose_pin "$judgement_block" '直後が `;` または行末' \
  'branch={branch_name} までスコープして照合する' \
  "branch= の右端 (直後が ; または行末) が規定されていない"
assert_prose_pin "$judgement_block" 'marker 名.*\[CONTEXT\].*prefix 込みで一致させる' \
  'marker は [CONTEXT] と一緒に扱う' \
  "アンカー照合の規約文が判定ブロックにない"
# 行頭一致の規約。ステップ 5 は git の stderr (外部由来・複数行) を marker と同じストリームへ
# 流すため、prefix だけ要求して位置を要求しないと WARNING 本文中の断片が marker として読まれる。
# operative 節を要求する。probe は太字見出しだけの形 — 以前の pin はこれで充足していた。
assert_prose_pin "$judgement_block" '肯定・否定とも行頭一致' \
  '**さらに prefix は行頭から一致させ、デリミタ内は data として無視する**' \
  "行頭一致の規約が肯定・否定の両方に掛かっていない (fallback が先行ルールの否定にならない)"
# インデントが security boundary である旨と、列 0 のみを marker 候補とする契約
assert_prose_pin "$judgement_block" '列 0 から始まる行だけを marker 候補' \
  '退避テキストはデリミタで囲む' \
  "退避テキストのインデント契約 (列 0 のみ marker 候補) が判定ブロックにない"
if [ -n "$tc6_fail" ]; then
  fail "TC-6: $tc6_fail"
else
  pass "TC-6 (ステップ 12 リモート側判定 4 ルール + fallback 判定値/禁止文 + アンカー/行頭規約 + AND ルールを pin)"
fi

# ─── TC-5 (T-04): mutation — 修正前のガード式に戻すと TC-1 が落ちる ───
# TC-5 の assertion が依存するのは「$BRANCH が origin に不在」。TC-3 が origin を差し替えたままでも
# 前段 TC-2b の後始末が失敗しても、いずれも mutant が「別の理由で push を呼ぶ」経路になり、
# 非 vacuity を証明するはずの TC 自身が vacuous 化する。両方を rc で切り分けて明示 assert する。
git remote set-url origin "$ORIGIN"
# 対象ブランチが **完全一致で** 不在であることを確認する。`--exit-code` の rc は入れ子衝突 ref への
# tail 一致で 0 になる (TC-5 の fixture がまさにその状態) ため、rc だけで判定すると「残存」と
# 誤診断して FATAL になる。ref 名の完全一致で判定する。
_pc_err="$TEST_DIR/tc5-precondition-err.txt"
_pc_out=$(LC_ALL=C git ls-remote --heads origin "refs/heads/$BRANCH" 2>"$_pc_err"); _pc_rc=$?
if [ "$_pc_rc" -ne 0 ]; then
  echo "FATAL: TC-5 precondition: origin の存在確認に失敗 (rc=$_pc_rc): $(cat "$_pc_err")"; exit 1
fi
if printf '%s\n' "$_pc_out" | awk -F'\t' -v r="refs/heads/$BRANCH" '$2 == r { found = 1 } END { exit !found }'; then
  echo "FATAL: TC-5 precondition: $BRANCH が origin に残存 (TC-2b の後始末が失敗) — TC-5 が vacuous になる"; exit 1
fi
# 入れ子衝突 ref が残っていること (= mutant が rc=0 経路へ入れること) も確認する。これが消えると
# mutant は「出力なし」で不在判定に落ち、TC-5 が誤帰属の FAIL を出す。
git ls-remote --exit-code --heads origin "refs/heads/$BRANCH" >/dev/null 2>&1 \
  || { echo "FATAL: TC-5 precondition: 入れ子衝突 ref が消えている — mutant が rc=0 経路へ入れず TC-5 が vacuous になる"; exit 1; }
# ガードが load-bearing であることの実証 (経験則「Mutation testing で test の真正性を
# empirical 検証する」)。vacuous pass (ガードを外しても緑のまま) を排除する。
echo "TC-5: mutation — weakening the exact-ref-match check makes TC-1 fail (the check is load-bearing)"
MUTANT="$TEST_DIR/guard-mutant.sh"
# 変異対象は **完全一致検証** (`$2 == r`)。`--exit-code` の除去ではない — 完全一致検証を入れた結果、
# 不在判定は「stdout に完全一致 ref が無い」で成立するようになり、`--exit-code` は同じ結論へ
# 早く着く fast path に後退した (外しても挙動が変わらないので mutation 対象として非 load-bearing)。
# 一方、完全一致検証を「出力があれば存在」に弱めると、入れ子衝突 ref への tail 一致で rc=0 が
# 成立し、不在ブランチにも push --delete が走る。これが本 Issue の headline 欠陥そのもの。
# mutant は **抽出した実物** ($GUARD_SNIPPET) から導出する。ハードコードした修正前の式を実行しても、
# それは git の exit code 仕様を再確認しているだけで、cleanup/SKILL.md の現在のガードが
# load-bearing であることの証明にはならない (TC-5 の PASS/FAIL が artifact から独立してしまう)。
sed 's/\$2 == r/$2 != ""/' "$GUARD_SNIPPET" > "$MUTANT" \
  || { echo "FATAL: TC-5: mutant の生成に失敗"; exit 1; }
# 変異が実際に入ったことを確認する。抽出側の文字列が変わって sed が空振りすると、mutant が原本と
# 同一になり「ガードが効いている」= push が呼ばれない、で TC-5 が誤帰属の FAIL を出す。
if ! grep -q '\$2 != ""' "$MUTANT"; then
  fail "TC-5: mutant に変異が入っていない (完全一致検証の式が変わり sed が空振りした可能性)"
else
  out=$(run_guard "$MUTANT")
  if ! push_delete_called; then
    fail "TC-5: 完全一致検証を弱めても push --delete が呼ばれなかった。TC-1 がその検証を検証できていない (vacuous pass)"
  elif printf '%s' "$out" | grep -q 'REMOTE_BRANCH_ALREADY_ABSENT=1'; then
    # 負の assertion は非アンカー (ファイル冒頭の規約どおり)。prefix や位置に関わらず marker の
    # 出現を捕捉したいので、アンカーすると検出範囲が狭まる。TC-2 / TC-3 の負 assertion と同形。
    fail "TC-5: 完全一致検証を弱めても不在判定が成立した。ガードが完全一致検証に依存していない (出力: '$out')"
  else
    pass "TC-5 (完全一致検証を弱めると入れ子衝突 ref への tail 一致で不在ブランチにも push --delete が走る = 検証は load-bearing)"
  fi
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -gt 0 ] && exit 1
exit 0
