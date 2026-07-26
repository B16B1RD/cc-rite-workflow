#!/bin/bash
# remote-branch-delete-guard.test.sh
#
# cleanup/SKILL.md ステップ 5 のリモートブランチ削除ガードを SKILL.md から literal 抽出して
# sandbox で実行し、`git ls-remote --exit-code` の exit code 3 分岐を pin する (Issue #2016)。
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
# TC 対応 (Issue #2016 Section 7)。実行順は TC-0 → 1 → 2 → 2b → 3 → 4 → 6 → 5 で、TC-5 だけ
# 番号順から外れる (precondition が「対象ブランチが origin に不在」で前段 TC の後始末に依存する)。
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
# - TC-5 = T-04       : 抽出した実物のガードから --exit-code を除いた mutant で TC-1 相当が
#                      落ちる (ガードが load-bearing であることの実証)
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
TEST_DIR="$(cd "$TEST_DIR" && pwd -P)" || exit 1
REAL_GIT="$(command -v git)" || { echo "FATAL: git が見つかりません"; exit 1; }
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

BRANCH="fix/issue-2016-sample"

# --- SKILL.md からリモート削除ガードを抽出 ({branch_name} はテスト用ブランチ名に置換) ---
# アンカー: 導入コメント行 `# リモートブランチ削除` 〜 case を閉じる `esac`
extract_guard() {
  awk '/^# リモートブランチ削除/{f=1} f{print} f && /^esac$/{exit}' "$CLEANUP_MD" \
    | sed -e "s|{branch_name}|$BRANCH|g"
}
GUARD_SNIPPET="$TEST_DIR/guard.sh"
extract_guard > "$GUARD_SNIPPET"
# 必須文字列を 2 群に分け、**診断文面を分ける**。抽出の破損とガード契約の消失は原因も対処も別物で、
# 後者を「アンカーが変更された可能性」と報じると、本テストが検出すべき #2016 の退行そのものを
# 「テスト側の問題」に誤帰属させる (本ファイルが随所で欠陥として扱っている誤帰属)。
#
# 群 1: 抽出アンカーの健全性。marker 名だけでなく `[CONTEXT] ` prefix 込みで pin する — ステップ 12 の
# リモート側ルールは `[CONTEXT] REMOTE_BRANCH_...` でアンカー照合するため、emitter から prefix が
# 落ちると全ルールが不一致になり fallback が発火する。`grep "$required"` は BRE なので `[CONTEXT]` は
# ブラケット式に解釈される — `\[` `\]` のエスケープを外さないこと。
for required in '\[CONTEXT\] REMOTE_BRANCH_' '^esac$'; do
  if ! grep -q "$required" "$GUARD_SNIPPET"; then
    echo "FAIL: cleanup/SKILL.md からのガード抽出に失敗しました ('$required' 不在。アンカーが変更された可能性)"
    echo "  抽出結果: $(wc -l < "$GUARD_SNIPPET") 行"
    exit 1
  fi
done
# 群 2: ガードの振る舞い契約。抽出は成功しているので、不在は artifact 側で契約が失われたことを意味する。
# 4 経路すべてを含める (どれか 1 経路だけが対象外という非対称を残さない)。
for required in 'ls-remote --exit-code' 'push origin --delete' 'REMOTE_BRANCH_DELETED' \
                'REMOTE_BRANCH_DELETE_FAILED' 'REMOTE_BRANCH_ALREADY_ABSENT' \
                'REMOTE_BRANCH_CHECK_FAILED'; do
  if ! grep -q "$required" "$GUARD_SNIPPET"; then
    echo "FAIL: 抽出したガードに '$required' がありません — cleanup/SKILL.md ステップ 5 のガード契約が失われた可能性 (#2016 の退行)"
    echo "  抽出自体は成功しています ($(wc -l < "$GUARD_SNIPPET") 行)。アンカーではなくガード本体を確認してください"
    exit 1
  fi
done
# 閉じアンカー `^esac$` は cleanup/SKILL.md 内で一意ではない (5 箇所) ため、必須文字列チェックだけでは
# over-capture (ガードの esac を書き換えると抽出が後続ブロックまで膨張する) を検出できない。
# 抽出が bash fence を越えていないことで代替検出する — 正常な抽出に fence terminator は現れない。
if grep -q '^```' "$GUARD_SNIPPET"; then
  echo "FAIL: 抽出が bash fence を越えました (閉じアンカー esac が変更された可能性)"
  echo "  抽出結果: $(wc -l < "$GUARD_SNIPPET") 行"
  exit 1
fi

# brace 無し変数展開が非 ASCII バイトに隣接していないことを検査する。`$var。` と書くと bash が
# 多バイト文字の先頭バイトを変数名に取り込み、非 UTF-8 ロケール (macOS CI) で変数が未定義化して
# 診断が消え、残った不正バイトが下流の BSD sed も落とす (Issue #2008 / TC-8b-h と同 invariant)。
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
# 先に証明する (TC-8b-h と同形。develop f45be675 の「positive control を付け vacuous pass を排除する」
# と同じ規律)。
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
if [ "\${1:-}" = "push" ]; then printf '%s\n' "push \$*" >> "$CALL_LOG"; fi
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
git switch -qc "$COLLIDING" 2>/dev/null || { echo "FATAL: 衝突 ref の作成に失敗"; exit 1; }
git push -q origin "$COLLIDING" 2>/dev/null || { echo "FATAL: 衝突 ref の push に失敗"; exit 1; }
git switch -q main || { echo "FATAL: main への切り戻しに失敗"; exit 1; }
# 仕込みが成立していることを確認する。ここが崩れると TC-1 は「衝突なし」を検証する別物になる。
git ls-remote --exit-code --heads origin "refs/heads/$COLLIDING" >/dev/null 2>&1 \
  || { echo "FATAL: 衝突 ref が origin に存在しない — TC-1 の full refname pin が vacuous になる"; exit 1; }

# ─── TC-1 (T-01 / AC-1): ref 不在 → push --delete を呼ばず ALREADY_ABSENT ───
echo "TC-1: absent remote ref -> no push --delete, REMOTE_BRANCH_ALREADY_ABSENT"
out=$(run_guard "$GUARD_SNIPPET")
if push_delete_called; then
  fail "TC-1: git push origin --delete が呼ばれた ($(cat "$CALL_LOG"))"
elif ! printf '%s' "$out" | grep -q '^\[CONTEXT\] REMOTE_BRANCH_ALREADY_ABSENT=1'; then
  # 照合はステップ 12 の consumer 側と同形の「行頭 + `[CONTEXT] ` 込み」で行う。marker 名だけを
  # 見ると emitter から prefix が落ちた退行を通し、行頭を要求しないと marker を WARNING 本文の
  # 行中へ移す退行を通す。どちらも consumer 側では全ルール不一致 → fallback 行きになる。
  fail "TC-1: REMOTE_BRANCH_ALREADY_ABSENT marker が行頭に出力されていない (出力: '$out')"
elif printf '%s' "$out" | grep -q '^error:'; then
  fail "TC-1: error: 行が出力された (AC-1 違反。出力: '$out')"
else
  pass "TC-1 (削除を試行せず既削除として marker を emit)"
fi

# ─── TC-2 (T-02 / AC-2): ref 存在 → 削除経路へ入りリモートから消える ───
echo "TC-2: existing remote ref -> push --delete runs and the ref is gone (backward compat)"
git switch -qc "$BRANCH" 2>/dev/null
echo "v2" > file.txt
git add -A && git commit -qm work && git push -q origin "$BRANCH" 2>/dev/null
git switch -q main
git ls-remote --exit-code --heads origin "refs/heads/$BRANCH" >/dev/null 2>&1 \
  || { echo "FATAL: TC-2 setup: origin へのブランチ push に失敗"; exit 1; }
out=$(run_guard "$GUARD_SNIPPET")
if ! push_delete_called; then
  fail "TC-2: git push origin --delete が呼ばれていない (delete_branch_on_merge:false 環境の機能後退)"
elif git ls-remote --exit-code --heads origin "refs/heads/$BRANCH" >/dev/null 2>&1; then
  fail "TC-2: リモートブランチが削除されていない"
elif ! printf '%s' "$out" | grep -q '^\[CONTEXT\] REMOTE_BRANCH_DELETED=1'; then
  # ステップ 12 の契約は 4 経路すべてが marker を出すこと。成功も positive marker で表さないと
  # 「marker 不在 = 削除成功」に戻り、ステップ 5 の未実行と削除成功が区別できなくなる (#2016)。
  fail "TC-2: 削除成功の marker REMOTE_BRANCH_DELETED が行頭に出ていない。ステップ 12 が marker 不在を成功と読む契約に退行する (出力: '$out')"
elif printf '%s' "$out" | grep -qE 'REMOTE_BRANCH_(DELETE_FAILED|CHECK_FAILED|ALREADY_ABSENT)'; then
  # 失敗系 3 marker は正常系で出てはならない。非アンカーで照合するのは意図的 — prefix の有無や
  # 行中/行頭に関わらず「出ていること」を捕捉したいので、アンカーすると検出範囲が狭まる。
  fail "TC-2: 削除成功なのに失敗系 marker が出た。ステップ 12 が正常系を未完了と報告する (出力: '$out')"
else
  pass "TC-2 (従来どおりリモートブランチを削除、REMOTE_BRANCH_DELETED を emit し失敗系 marker は不在)"
fi

# ─── TC-2b (AC-1/AC-4): rc=0 経路で push --delete が失敗 → REMOTE_BRANCH_DELETE_FAILED ───
# ステップ 12 は「REMOTE_BRANCH_* marker 不在 = 削除成功」と解釈するため、この分岐が marker を
# 出さないと削除失敗が完了 (`x`) として報告される。receive.denyDeletes で server 側拒否を再現する。
echo "TC-2b: push --delete failure -> REMOTE_BRANCH_DELETE_FAILED (not silent success)"
git switch -qc "$BRANCH" 2>/dev/null || git switch -q "$BRANCH"
echo "v3" > file.txt
git add -A && git commit -qm work2 && git push -q origin "$BRANCH" 2>/dev/null
git switch -q main
# setup の成立を TC-2 と同形の precondition で確認する。ここを assertion 段まで遅延させると、
# setup 失敗が「marker が出ていない」という誤った診断に化ける。
git ls-remote --exit-code --heads origin "refs/heads/$BRANCH" >/dev/null 2>&1 \
  || { echo "FATAL: TC-2b setup: origin へのブランチ push に失敗"; exit 1; }
git -C "$ORIGIN" config receive.denyDeletes true
out=$(run_guard "$GUARD_SNIPPET")
git -C "$ORIGIN" config --unset receive.denyDeletes
# ref 残存（= setup が実際に削除を阻止できたか）を marker チェックより先に評価する。
# denyDeletes が効かない環境では push が成功して marker が出ないため、順序が逆だと
# 「marker が surface されていない」という真因と異なる診断になる。
if ! push_delete_called; then
  fail "TC-2b: setup 不備 — ref が存在するのに push --delete が呼ばれていない"
elif ! git ls-remote --exit-code --heads origin "refs/heads/$BRANCH" >/dev/null 2>&1; then
  fail "TC-2b: setup 不備 — 削除が拒否されたはずだがリモート ref が消えている (receive.denyDeletes が効いていない)"
elif ! printf '%s' "$out" | grep -q '^\[CONTEXT\] REMOTE_BRANCH_DELETE_FAILED=1'; then
  fail "TC-2b: push 失敗が行頭 marker で surface されていない。ステップ 12 が削除失敗を x と報告する (出力: '$out')"
elif ! printf '%s' "$out" | grep -qE 'denyDeletes|remote rejected'; then
  # TC-3 と対称。`_push_err=$(... 2>&1)` は stdout/stderr を両方飲み込むため、WARNING から
  # $_push_err が落ちると原因情報がゼロになる（ターミナルにも何も残らない）。
  fail "TC-2b: WARNING に push 失敗の原因テキストが載っていない (出力: '$out')"
else
  pass "TC-2b (push 失敗を marker + 原因テキストで surface)"
fi
# 後始末。ここで ref が残ると TC-5 の precondition（$BRANCH が origin に不在）が崩れるが、
# その状態は TC-5 precondition 自身が正しい帰属で FATAL にする。ここを致命にすると
# 「teardown 失敗」と誤帰属したうえ後続 4 TC がカスケード中断するため、警告に留めて原因だけ残す。
_td_err=$(LC_ALL=C git push -q origin --delete "$BRANCH" 2>&1) \
  || echo "WARN: TC-2b teardown: $BRANCH の削除に失敗: $_td_err" >&2

# ─── TC-3 (AC-1): ls-remote 自体の失敗 → CHECK_FAILED、削除は試行しない ───
# ネットワーク断・認証失敗は rc=128 になる。これを rc=2 (不在) と取り違えて「既削除」に
# 丸めると、delete_branch_on_merge:false のリポジトリでリモートブランチが黙って残る (§8 リスク)。
echo "TC-3: ls-remote failure (unreachable origin) -> REMOTE_BRANCH_CHECK_FAILED, no delete attempt"
git remote set-url origin "$TEST_DIR/does-not-exist.git"
out=$(run_guard "$GUARD_SNIPPET")
if push_delete_called; then
  fail "TC-3: 存在判定できていないのに push --delete が呼ばれた ($(cat "$CALL_LOG"))"
elif printf '%s' "$out" | grep -q 'REMOTE_BRANCH_ALREADY_ABSENT=1'; then
  fail "TC-3: ネットワーク失敗を「既削除」に丸めた (出力: '$out')"
elif ! printf '%s' "$out" | grep -q '^\[CONTEXT\] REMOTE_BRANCH_CHECK_FAILED=1'; then
  fail "TC-3: REMOTE_BRANCH_CHECK_FAILED marker が行頭に出力されていない (出力: '$out')"
elif ! printf '%s' "$out" | grep -q 'does not appear to be a git repository'; then
  # ガードは `2>&1 >/dev/null` で stderr のみ退避して WARNING に載せる設計。順序を
  # `>/dev/null 2>&1` に取り違えると原因が消え rc だけになる（認証失敗・DNS 解決失敗・
  # proxy 遮断がすべて 128 に潰れて切り分け不能になる）。LC_ALL=C 固定で文言は安定する。
  fail "TC-3: WARNING に ls-remote の原因テキストが載っていない (stderr 退避の順序が壊れた可能性。出力: '$out')"
else
  pass "TC-3 (判定不能を未完了として surface、原因テキストも保持)"
fi
git remote set-url origin "$ORIGIN"

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
else
  pass "TC-4 (抑止できるもの/できないものを区別して記述)"
fi

# ─── TC-6 (AC-4): ステップ 12 リモート側判定の契約を pin する ───
# emitter (ステップ 5 のガード) だけを検証すると consumer (完了報告の判定ルール) が無防備になる。
# 当該ブロックを削除する mutation でも全スイートが green になっていたため、散文側も静的に pin する。
echo "TC-6: cleanup/SKILL.md ステップ 12 pins the remote-side judgement rules"
remote_section=$(awk '/^  \*\*リモート側\*\*/{f=1} f{print} f && /^- `\{projects_status_result\}/{found=1; exit} END{exit !found}' "$CLEANUP_MD")
awk_rc=$?
tc6_fail=""
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
[ -z "$tc6_fail" ] && { printf '%s' "$remote_section" | grep -qE 'REMOTE_BRANCH_CHECK_FAILED=1.*: ` ` \+.*削除.*試行' || tc6_fail="REMOTE_BRANCH_CHECK_FAILED が「未完了 ` ` + 削除未試行の案内」になっていない"; }
[ -z "$tc6_fail" ] && { printf '%s' "$remote_section" | grep -qE 'REMOTE_BRANCH_ALREADY_ABSENT=1.*: `x`' || tc6_fail="REMOTE_BRANCH_ALREADY_ABSENT が x (正常系) に割り当てられていない"; }
[ -z "$tc6_fail" ] && { printf '%s' "$remote_section" | grep -qE 'REMOTE_BRANCH_DELETED=1.*: `x`' || tc6_fail="REMOTE_BRANCH_DELETED が x (正常系) に割り当てられていない"; }
[ -z "$tc6_fail" ] && { printf '%s' "$remote_section" | grep -q 'REMOTE_BRANCH_\*' || tc6_fail="リモート側 fallback が REMOTE_BRANCH_* の marker family でスコープされていない"; }
# fallback の判定値。marker 不在を `x` に倒す mutation は「ステップ 5 が実行されなかった」と
# 「削除成功」を再び同一視し、本 Issue が塞いだ false-success を判定表側から復活させる。
# 判定値 (` `) と「成功と読むな」の禁止文の両方を要求する — 判定値だけだと禁止根拠が消え、
# 禁止文だけだと値の反転を素通しする。
[ -z "$tc6_fail" ] && { printf '%s' "$remote_section" | grep -qE 'REMOTE_BRANCH_\*.*いずれの行も無いとき: ` ` \+' || tc6_fail="リモート側 fallback が未完了 ` ` になっていない (marker 不在を削除成功と読む契約に退行)"; }
[ -z "$tc6_fail" ] && { printf '%s' "$remote_section" | grep -qE '不在.*削除成功.*(ならない|いけない)' || tc6_fail="リモート側 fallback に marker 不在を成功と読む禁止文がない"; }
# 判定ブロック全体 (ローカル側 + リモート側を含む {local_branch_check} の箇条書き) を抽出する。
# 以下 2 本の grep をファイル全体ではなくここへスコープする — ファイル全体を対象にすると、
# 判定ブロックから当該文を削除して「過去の設計では…」等の歴史メモへ格下げしても、文字列が
# どこかに残っていれば PASS してしまう。
judgement_block=$(awk '/^- `\{local_branch_check\}`/{f=1} f && /^- `\{projects_status_result\}`/{exit} f{print}' "$CLEANUP_MD")
[ -z "$tc6_fail" ] && { [ -n "$judgement_block" ] || tc6_fail="{local_branch_check} の判定ブロックを抽出できない"; }
# 両側独立評価の AND ルール文 (ローカル成功でリモート失敗が握り潰される回帰の pin)
[ -z "$tc6_fail" ] && { printf '%s' "$judgement_block" | grep -qE '両方が `x` 相当のとき(だけ|に限り) `x`' || tc6_fail="ローカル/リモート独立評価の AND ルール文が判定ブロックにない"; }
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
[ -z "$tc6_fail" ] && { printf '%s' "$local_section" | grep -qE 'BRANCH_DELETE_\*.*いずれの行も無いとき: ` ` \+' || tc6_fail="ローカル側 fallback が未完了 ` ` になっていない (リモート側と非対称: marker 不在を削除成功と読む契約に退行)"; }
[ -z "$tc6_fail" ] && { printf '%s' "$judgement_block" | grep -qE 'marker 名.*\[CONTEXT\].*prefix 込み' || tc6_fail="アンカー照合の規約文が判定ブロックにない"; }
# 行頭一致の規約。ステップ 5 は git の stderr (外部由来・複数行) を marker と同じストリームへ
# 流すため、prefix だけ要求して位置を要求しないと WARNING 本文中の断片が marker として読まれる。
[ -z "$tc6_fail" ] && { printf '%s' "$judgement_block" | grep -qE 'prefix.*行頭.*一致' || tc6_fail="行頭一致の規約文が判定ブロックにない (行中の [CONTEXT] が marker として読まれる)"; }
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
_pc_err=$(LC_ALL=C git ls-remote --exit-code --heads origin "refs/heads/$BRANCH" 2>&1 >/dev/null); _pc_rc=$?
case "$_pc_rc" in
  0) echo "FATAL: TC-5 precondition: $BRANCH が origin に残存 (TC-2b の後始末が失敗) — TC-5 が vacuous になる"; exit 1 ;;
  2) : ;;  # 期待状態: 対象ブランチは origin に不在
  *) echo "FATAL: TC-5 precondition: origin の存在確認に失敗 (rc=$_pc_rc): $_pc_err"; exit 1 ;;
esac
# ガードが load-bearing であることの実証 (経験則「Mutation testing で test の真正性を
# empirical 検証する」)。vacuous pass (ガードを外しても緑のまま) を排除する。
echo "TC-5: mutation — removing --exit-code from the extracted guard makes TC-1 fail (guard is load-bearing)"
MUTANT="$TEST_DIR/guard-mutant.sh"
# mutant は **抽出した実物** ($GUARD_SNIPPET) から導出する。ハードコードした修正前の式を実行しても、
# それは git の exit code 仕様を再確認しているだけで、cleanup/SKILL.md の現在のガードが
# load-bearing であることの証明にはならない (TC-5 の PASS/FAIL が artifact から独立してしまう)。
sed 's/ls-remote --exit-code/ls-remote/' "$GUARD_SNIPPET" > "$MUTANT" \
  || { echo "FATAL: TC-5: mutant の生成に失敗"; exit 1; }
# 変異が実際に入ったことを確認する。抽出側の文字列が変わって sed が空振りすると、mutant が原本と
# 同一になり「ガードが効いている」= push が呼ばれない、で TC-5 が誤帰属の FAIL を出す。
if grep -q 'ls-remote --exit-code' "$MUTANT"; then
  fail "TC-5: mutant に --exit-code が残っている (sed の対象文字列が変わった可能性)"
else
  out=$(run_guard "$MUTANT")
  if ! push_delete_called; then
    fail "TC-5: --exit-code を外しても push --delete が呼ばれなかった。TC-1 がガードを検証できていない (vacuous pass)"
  elif printf '%s' "$out" | grep -q 'REMOTE_BRANCH_ALREADY_ABSENT=1'; then
    # 負の assertion は非アンカー (ファイル冒頭の規約どおり)。prefix や位置に関わらず marker の
    # 出現を捕捉したいので、アンカーすると検出範囲が狭まる。TC-2 / TC-3 の負 assertion と同形。
    fail "TC-5: --exit-code を外しても不在判定 (rc=2) が成立した。ガードが --exit-code に依存していない (出力: '$out')"
  else
    pass "TC-5 (--exit-code を外すと不在ブランチにも push --delete が走る = ガードは load-bearing)"
  fi
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -gt 0 ] && exit 1
exit 0
