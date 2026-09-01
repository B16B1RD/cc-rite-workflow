#!/usr/bin/env bash
# cleanup-branch-delete.sh — ローカル / リモートブランチの削除。
# cleanup/SKILL.md ステップ 5 から抽出した後片付けロジックで、`/rite:cleanup` と
# `/rite:issue-cancel` の双方から呼ばれる。振る舞いは抽出前と同一。
#
# 順序: branch 削除は **worktree 削除後にのみ成功する**（Git 制約: worktree で checkout 中の
# branch は削除不可）。multi_session 時は cleanup-session-worktree-teardown.sh remove の後に呼ぶ。
#
# Usage:
#   cleanup-branch-delete.sh --branch <name> --pr-merged <true|false> \
#     --branch-identity-verified <true|false> [--dry-run]
#
# 出力: ローカル 6 marker + リモート 4 marker。成功系（BRANCH_DELETED /
#   BRANCH_ALREADY_ABSENT / REMOTE_BRANCH_DELETED / REMOTE_BRANCH_ALREADY_ABSENT）は stdout、
#   失敗・未試行系（*_CHECK_FAILED / *_DELETE_FAILED / BRANCH_DELETE_UNMERGED）は stderr。
#   全 marker に `; branch=<name>` を付ける（呼び出し側は branch= までスコープして照合する）。
#   fail-fast 経路のみ sentinel `branch=<unsupported branch name>` でどのルールにも一致させない。
#   **どの経路も必ず marker を emit する** — marker 不在は「削除成功」ではなく
#   「実行結果を確認できていない」を意味する契約。
#
# --branch-identity-verified を必須にする理由:
#   削除対象が PR head と一致することの確認は呼び出し側（Step 1.3 の headRefName 完全一致）の
#   判断で、bash からは導出できない。デフォルトを置くと「検証していないのに削除する」経路ができる。
#   --pr-merged も同じ（PR の mergedAt に基づく判断）。
#
# exit code: 全運用経路 0（非ブロッキング）。usage error のみ 2。
#
# `set -e` は使わない: 判定は rc の捕捉（_cf_rc / _sr_rc / _ls_rc / _match_rc / del_err）に
# 全面依存しており、-e は分岐を黙って殺す。
set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

branch=""
pr_merged=""
branch_identity_verified=""
dry_run=false

usage() {
  echo "ERROR: $1" >&2
  echo "Usage: cleanup-branch-delete.sh --branch <name> --pr-merged <true|false> --branch-identity-verified <true|false> [--dry-run]" >&2
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --branch)
      shift; [ "$#" -gt 0 ] || usage "--branch requires a value"; branch=$1; shift ;;
    --pr-merged)
      shift; [ "$#" -gt 0 ] || usage "--pr-merged requires a value"; pr_merged=$1; shift ;;
    --branch-identity-verified)
      shift; [ "$#" -gt 0 ] || usage "--branch-identity-verified requires a value"; branch_identity_verified=$1; shift ;;
    --dry-run)
      dry_run=true; shift ;;
    *) usage "unknown option: $1" ;;
  esac
done

case "$pr_merged" in true|false) ;; *) usage "--pr-merged must be true or false" ;; esac
case "$branch_identity_verified" in true|false) ;; *) usage "--branch-identity-verified must be true or false" ;; esac
# --branch は空値・marker デリミタ混入を運用経路（fail-fast marker）で扱うため usage error にしない。

# ---------------------------------------------------------------------------
# ローカルブランチ削除
# ---------------------------------------------------------------------------
# worktree 削除が遅延した場合（teardown helper が WORKTREE_REMOVE_SKIPPED_LIVE_CWD = 別 live
# セッションが worktree 使用中、または WORKTREE_REMOVE_SKIPPED_SANDBOX_MASK = sandbox マスク
# 検知で自セッション worktree の削除を試行しなかった（sandbox マスク）、のいずれかを残した場合）、
# branch は worktree で checkout 中のため削除できない。その場合は強制削除せず reap manifest に
# 記録し、worktree が解放（遅延 reap の corpse 回収含む）されたあと pr-cycle-cleanup.sh Step 5 が
# 次セッションで branch・worktree の双方を回収する（dead-letter 解消）。
# manifest 記録は Step 5 の free-claim 24h age guard 自体もバイパスさせる（ハーネスが worktree
# root の mtime をセッション毎に更新するため、記録なしでは回収が永遠に始まらない）。
# 自セッションの worktree は通常 self-exclusion 後に即時削除されるが、sandbox マスク検知時は
# 削除を試行しないため自セッション由来でも本経路に入る（「別セッション在席時のみ」ではない）。
# git 診断メッセージは locale 翻訳で揺れるため LC_ALL=C で固定して substring マッチを安定させる。
# squash merge では feature のコミットが base の祖先にならないため、worktree 解放後でも
# `git branch -d` が "not fully merged" で拒否する。PR が merged 済み（--pr-merged true）なら
# これは squash の残渣であり強制削除して安全（ユニークな未マージ作業は無い）。
# ブランチ名の事前検証。空値と marker のデリミタ文字（`;` `=`）はいずれも本ステップの契約を
# 満たせない: 空値は `git show-ref --verify "refs/heads/"` が rc=1（不在）を返すため
# 「既削除 = 正常系」に倒れ、**削除していないのに完了と報告する**。`;` `=` はどちらも合法な
# refname 文字で、`branch=` フィールドの右端境界を騙って別ブランチの判定ルールに一致しうる。
# エンコード規約を emitter/consumer の両側へ増やすより、契約を満たせない入力を fail-fast で弾く
# （Fail-Fast First）。sentinel は空白を含めて refname として非合法にし、実在ブランチとの衝突を
# 構造的に排除する。リモート削除ブロックも同じ検査を独立に持つ（各ブロックが単体で抽出・実行
# されうるため、ガードもブロック単位で自己完結させる）。
if [ "$branch_identity_verified" != "true" ]; then
  echo "[CONTEXT] BRANCH_CHECK_FAILED=1; branch=<unsupported branch name>; rc=branch-identity-unverified" >&2
  echo "WARNING: 削除対象が PR head と一致すると確認できないためローカル削除を試行していません。" >&2
else
case "$branch" in
  '')
    # 空値は処方を出さない。存在しないブランチに対する `git branch -D ""` は必ず失敗するため、
    # 「必ず失敗する処方」を新設することになる。
    echo "[CONTEXT] BRANCH_CHECK_FAILED=1; branch=<unsupported branch name>; rc=empty-branch-name" >&2
    echo "WARNING: 削除対象のブランチ名が空のため、ローカルブランチの削除を試行していません。対象ブランチを特定してから再実行してください。" >&2 ;;
  *[\;=]*)
    echo "[CONTEXT] BRANCH_CHECK_FAILED=1; branch=<unsupported branch name>; rc=marker-delimiter-in-branch-name" >&2
    echo "WARNING: ブランチ名に marker のデリミタ文字 (=) が含まれるため、ローカルブランチの削除を試行していません。手動で削除してください: git branch -D \"$branch\"" >&2 ;;
  *)
# rc を捕捉して **rc=1（不在）だけ**を「既削除」に倒す。否定付き if の短絡形だと rc=128（リポジトリ外での
# 実行等）まで「不在」に丸め、ローカルブランチが残ったまま完了と報告される（リモート側が rc=0/2
# 以外を REMOTE_BRANCH_CHECK_FAILED に倒すのと同じ扱いにする）。
# ただし rc=1 は「本当に不在」だけを意味しない — refname として非合法な値（末尾空白 / `:` 混入 /
# `..` や制御文字の混入等）でも rc=1 になり、同じく「既削除 = 正常系」へ倒れて削除していないのに
# 完了と報告する。そこで **refname 構文に起因する rc=1 を分離する**ために先に合法性を検査する。
# 構文的に合法だが対象と別物の値は、呼び出し側の headRefName 完全一致で排除する。
# ref store 側の障害は show-ref rc=1 後の for-each-ref positive control で、非 0 rc または stderr warning
# のどちらも `ref-store-*` として判定不能へ倒す。
# stderr は退避して WARNING に載せる（rc=128 の原因が消えると認証失敗・リポジトリ外・破損が
# 区別できない。リモート側が $_ls_err で原因を surface するのと対称）。
LC_ALL=C git check-ref-format "refs/heads/$branch" >/dev/null 2>&1; _cf_rc=$?
_sr_err=$(LC_ALL=C git show-ref --verify --quiet "refs/heads/$branch" 2>&1 >/dev/null); _sr_rc=$?
if [ "$_cf_rc" -ne 0 ]; then
  echo "[CONTEXT] BRANCH_CHECK_FAILED=1; branch=$branch; rc=invalid-refname" >&2
  echo "WARNING: ブランチ名が refname として非合法なため、ローカルブランチの存在を判定できず削除を試行していません (git check-ref-format rc=${_cf_rc})。" >&2
elif [ "$_sr_rc" -eq 1 ]; then
  # show-ref の rc=1 は不在だけでなく ref store 障害でも返りうる。全 local heads の走査が正常完了
  # した場合だけ不在と確定し、走査不能は CHECK_FAILED へ倒す。
  _fr_err=$(LC_ALL=C git for-each-ref --format='%(refname)' refs/heads 2>&1 >/dev/null); _fr_rc=$?
  if [ "$_fr_rc" -ne 0 ] || [ -n "$_fr_err" ]; then
    echo "[CONTEXT] BRANCH_CHECK_FAILED=1; branch=$branch; rc=ref-store-${_fr_rc}" >&2
    echo "WARNING: ローカル ref store を走査できないため削除を試行していません:" >&2
    printf '%s\n' "$_fr_err" | tr -d '\r' | sed 's/^/  /' >&2
  else
  # 既に不在（cleanup の再実行 / 別セッションで削除済み）は正常系。存在確認せず `git branch -d` に
  # 渡すと "branch not found" で失敗して下の `*)` に落ち、BRANCH_DELETE_FAILED として
  # 「削除に失敗。`git branch -D` で手動削除」という**必ず失敗する処方**を出す。これはリモート側で
  # REMOTE_BRANCH_ALREADY_ABSENT として正常系に倒した症状と同型。
  # git の診断メッセージ文字列に依存しないよう show-ref で判定する。
  echo "[CONTEXT] BRANCH_ALREADY_ABSENT=1; branch=$branch"
  fi
elif [ "$_sr_rc" -ne 0 ]; then
  # 存在有無が不明。削除を試行せず未完了として surface する（安全側）。
  echo "[CONTEXT] BRANCH_CHECK_FAILED=1; branch=$branch; rc=${_sr_rc}" >&2
  echo "WARNING: ローカルブランチ $branch の存在確認に失敗したため削除を試行していません (git show-ref rc=${_sr_rc}):" >&2
  echo "--- show-ref stderr begin ---" >&2
  printf '%s\n' "${_sr_err}" | tr -d '\r' | sed 's/^/  /' >&2
  echo "--- show-ref stderr end ---" >&2
elif [ "$dry_run" = "true" ]; then
  # 存在確認済みで削除対象。削除は行わず対象のみ報告する。marker family は本番経路と分離し、
  # 呼び出し側の {local_branch_check} 判定を dry-run が汚染しないようにする。
  echo "[CONTEXT] BRANCH_DELETE_DRY_RUN=1; branch=$branch"
elif del_err=$(LC_ALL=C git branch -d -- "$branch" 2>&1); then
  echo "[CONTEXT] BRANCH_DELETED=1; branch=$branch"
else
  case "$del_err" in
    *"used by worktree"*|*"checked out"*)
      # Why: 遅延ブランチを次セッション回収へ配線する（dead-letter 解消）。PR が merged 済み
      # （--pr-merged true）のときのみ reap manifest に記録し、worktree が解放（別セッション終了
      # または遅延 reap での回収 — 原因は断定しない）されたあと pr-cycle-cleanup.sh Step 5 が
      # 安全に回収できるようにする。未マージ PR の強制 cleanup 時は記録しない（作業損失防止）。
      # **recovery= の意味**: rite-tmp-artifact.sh は非ブロッキング契約で、append 失敗でも
      # WARNING を出して exit 0 を返す。したがって record の exit code では記録成否を判定できない。
      # 共有 manifest を直接 verify し、エントリが実在するときだけ recovery=auto を emit する
      # （記録できていない経路で「自動で回収されます」と偽らない）。判定は helper へ委譲済み。
      bash "$SCRIPT_DIR/cleanup-deferred-branch-recovery.sh" \
        --branch "$branch" --pr-merged "$pr_merged" ;;
    *"not fully merged"*)
      if [ "$pr_merged" = "true" ]; then
        # squash merge の残渣 — PR は merged 済みなので強制削除して安全。
        LC_ALL=C git branch -D -- "$branch" >/dev/null 2>&1 \
          && echo "[CONTEXT] BRANCH_DELETED=1; branch=$branch; via=squash-merged" \
          || echo "[CONTEXT] BRANCH_DELETE_FAILED=1; branch=$branch" >&2
      else
        echo "[CONTEXT] BRANCH_DELETE_UNMERGED=1; branch=$branch" >&2
      fi ;;
    *)
      echo "[CONTEXT] BRANCH_DELETE_FAILED=1; branch=$branch" >&2
      echo "WARNING: ローカルブランチ $branch の削除に失敗しました:" >&2
      echo "--- branch delete stderr begin ---" >&2
      # 外部由来テキストの CR を除去してからインデントする。`sed 's/^/  /'` は `\n` 区切りの行頭
      # にしか空白を付けないため、`\r` が残ると CR 以降が表示上は列 0 に着地し、marker を騙る
      # 経路が開く（security boundary はインデント側にあるという規約の穴になる）。
      printf '%s\n' "$del_err" | tr -d '\r' | sed 's/^/  /' >&2
      echo "--- branch delete stderr end ---" >&2 ;;
  esac
fi
    ;;
esac
fi

# ⚠ 下行はテスト hooks/tests/remote-branch-delete-guard.test.sh が awk 抽出アンカーとして参照する。変更時はテスト側の awk パターンも同時更新すること
# リモートブランチ削除。`git ls-remote --heads` は ref 不在でも rc=0（空 stdout）を返すため、
# `&&` では「存在するときだけ削除する」ガードにならない。--exit-code で ref 不在を rc=2 として
# 判別する。リポジトリ設定 delete_branch_on_merge: true では merge 時にサーバサイドで head が
# 削除済みのため、この経路は通常 rc=2 に落ちる。
# rc=2（不在）だけを「既削除」とみなし、それ以外の非 0（ネットワーク断・認証失敗の 128 等）は
# 存在有無が不明なため削除を試行せず未完了として surface する（不明を「既削除」に丸めると、
# delete_branch_on_merge: false のリポジトリでリモートブランチが黙って残る）。
# ただし rc=128 は sandbox の HTTPS プロキシ断など **transient** で再現することがある
# （初回 128 の後に状態が確定して 2 へ変わる実測がある）。1 回目が 128 のときだけ
# **1 回再試行**し、2 回目の結果を採用する。2 回とも 128 なら従来どおり CHECK_FAILED で
# 削除を処方しない（確認できていない状態での偽処方）。rc=0/2 の即返しは
# 再試行せず 1 回で確定する（正常系の遅延を増やさない）。
# stderr は捨てず退避して WARNING に載せる（rc だけでは認証失敗・DNS 解決失敗・proxy 遮断がすべて
# 128 に潰れて切り分けられない。直上のローカル削除が $del_err で原因を surface するのと対称）。
# stdout は完全一致検証に使うため別ファイルへ分離する（`2>&1 >/dev/null` で捨てない）。
# pattern は full refname で渡すが、**それだけでは完全一致にならない**。`git ls-remote <pattern>` は
# ref の先頭または任意の slash 境界からの tail 一致であり、`refs/heads/` を前置しても anchor されない
# （実測: origin に `refs/heads/wip/refs/heads/X` があると pattern `refs/heads/X` が rc=0 で一致する）。
# そのため rc=0 のあとに stdout の ref 名が `refs/heads/$branch` と完全一致することを検証し、
# 一致しなければ不在（rc=2 相当）に落とす。この検証がないと、対象が不在でも rc=0 で削除経路へ入り、
# 存在しないブランチに対する偽の残作業と必ず失敗する処方を報告することになる。
# ブランチ名が marker のデリミタ文字（`;` `=`）を含む場合は、`branch=` フィールドの右端境界を騙って
# 別ブランチの判定ルールに一致しうる（`;` `=` はいずれも合法な refname 文字）。エンコード規約を
# emitter/consumer の両側に増やすより、契約を満たせない入力を fail-fast で弾く（Fail-Fast First）。
if [ "$branch_identity_verified" != "true" ]; then
  echo "[CONTEXT] REMOTE_BRANCH_CHECK_FAILED=1; branch=<unsupported branch name>; rc=branch-identity-unverified" >&2
  echo "WARNING: 削除対象が PR head と一致すると確認できないためリモート削除を試行していません。" >&2
else
case "$branch" in
  '')
    echo "[CONTEXT] REMOTE_BRANCH_CHECK_FAILED=1; branch=<unsupported branch name>; rc=empty-branch-name" >&2
    echo "WARNING: 削除対象のブランチ名が空のため、リモート削除を試行していません。対象ブランチを特定してから再実行してください。" >&2 ;;
  *[\;=]*)
    # sentinel 値を使い、実ブランチ名を marker へ載せない（載せると誤帰属そのものを再現する）。
    # 値に空白を含めて refname として非合法にし、実在ブランチとの衝突を構造的に排除する。
    # consumer 側は `branch=<name>` に一致しないため fallback（未確認）に落ちる。
    # 空値も弾く — 空だと完全一致検証が決して一致せず「既削除 = 正常系」に倒れ、削除していない
    # のに完了と報告する。
    echo "[CONTEXT] REMOTE_BRANCH_CHECK_FAILED=1; branch=<unsupported branch name>; rc=marker-delimiter-in-branch-name" >&2
    echo "WARNING: ブランチ名に marker のデリミタ文字 (=) が含まれるため、リモート削除の自動判定を行いません。手動で削除してください: git push origin --delete \"refs/heads/$branch\"" >&2
    ;;
  *)
# refname 非合法な値は ls-remote の完全一致検証が決して一致せず「既削除 = 正常系」へ倒れるため、
# ローカル側と対称に先に弾く（削除していないのに完了と報告するのを防ぐ）。
if ! LC_ALL=C git check-ref-format "refs/heads/$branch" >/dev/null 2>&1; then
  echo "[CONTEXT] REMOTE_BRANCH_CHECK_FAILED=1; branch=$branch; rc=invalid-refname" >&2
  echo "WARNING: ブランチ名が refname として非合法なため、リモートブランチの存在を判定できず削除を試行していません。" >&2
else
# `_ls_out` は先行宣言 → cleanup 関数 → 4 行 trap → mktemp の順で確保する
# （rationale: ../../references/bash-trap-patterns.md#signal-specific-trap-template）。`git ls-remote` は本ブロック唯一のネットワーク
# 操作で最も長くブロックしうるため、Ctrl-C の着弾点になりやすい。
_ls_out=""
_check_reason=""
_rite_cleanup_phase5_cleanup() { [ -n "${_ls_out:-}" ] && rm -f "$_ls_out"; return 0; }
trap 'rc=$?; _rite_cleanup_phase5_cleanup; exit $rc' EXIT
trap '_rite_cleanup_phase5_cleanup; exit 130' INT
trap '_rite_cleanup_phase5_cleanup; exit 143' TERM
trap '_rite_cleanup_phase5_cleanup; exit 129' HUP
_ls_out=$(mktemp "${TMPDIR:-/tmp}/rite-cleanup-lsremote-XXXXXX") || _ls_out=""
if [ -z "$_ls_out" ]; then
  # stdout を分離できない = 完全一致検証ができない。検証なしで削除経路へ入ると tail 一致の
  # 誤ヒットで別 ref を削除しうるため、削除を試行せず未確認として surface する（安全側）。
  echo "[CONTEXT] REMOTE_BRANCH_CHECK_FAILED=1; branch=$branch; rc=mktemp-failed" >&2
  echo "WARNING: 一時ファイルを作成できずリモートブランチの存在確認ができないため、削除を試行していません。" >&2
else
_ls_err=$(LC_ALL=C git ls-remote --exit-code --heads origin "refs/heads/$branch" 2>&1 >"$_ls_out"); _ls_rc=$?
# transient 失敗 (rc=128: ネットワーク断・proxy 遮断等) は一過性たり得るため 1 回だけ再試行する。
# 2 回目の結果を採用する。rc=0/2 の即返しは従来どおり 1 回で確定。2 回とも 128 なら
# 下の `*)` が CHECK_FAILED を emit し、削除は処方しない（確認できていない状態での偽処方を防ぐ）。
if [ "$_ls_rc" -eq 128 ]; then
  _ls_err=$(LC_ALL=C git ls-remote --exit-code --heads origin "refs/heads/$branch" 2>&1 >"$_ls_out"); _ls_rc=$?
fi
# rc=0 でも完全一致でなければ不在扱いに落とす（tail 一致による誤ヒットの排除）。ls-remote の出力は
# `<sha>\t<refname>` 形式。ブランチ名は `.` 等の正規表現メタ文字を含みうるため、regex ではなく
# awk のフィールド完全一致で比較する。
# awk の rc は 0（一致）/ 1（不一致）/ その他（awk 自体の異常終了）の 3 値に分ける。否定付き awk 呼び出しの
# 短絡形だと 1 とその他を融合し、awk が異常終了しただけで「既削除 = 正常系」に倒れてリモート
# ブランチが黙って残る（直上の mktemp 失敗経路が「判定不能は削除を試行せず surface する」と
# している契約に反する）。
if [ "$_ls_rc" -eq 0 ]; then
  awk -F'\t' -v r="refs/heads/$branch" '$2 == r { found = 1 } END { exit !found }' "$_ls_out"
  _match_rc=$?
  case "$_match_rc" in
    0) : ;;                       # 完全一致 = 存在
    1) _ls_rc=2 ;;                # 不一致 = 不在
    # 判定不能 → 下の `*)` が CHECK_FAILED を emit。`_ls_rc` は数値のまま保ち、原因は別変数へ
    # 分ける（文字列を代入すると後続で数値比較を足した瞬間に壊れ、診断も ls-remote に誤帰属する）。
    *) _ls_rc=3; _check_reason="ref-match-awk-${_match_rc}" ;;
  esac
fi
rm -f "$_ls_out"; _ls_out=""
case "$_ls_rc" in
  0)
    # リモート状態を実際に変更する唯一の分岐。push は protected branch / 権限不足 /
    # ls-remote 〜 push 間の race で失敗しうるため、成否の**両方**を marker で surface する。
    # 成功側も positive marker を出すのは、marker 不在を「削除成功」の符号化に使わないため。
    # 不在を成功と読むと、本ブロックがそもそも実行されなかった経路・出力が
    # compact で失われた経路と削除成功が区別できず、consumer が不在を根拠に完了と断定する。
    # 全経路が marker を持てば、marker 不在は「実行結果を確認できていない」という
    # 別の意味だけを持つ。
    # 削除先も namespace 修飾する。非修飾の <dst> は remote の**全 namespace** に対して解決されるため、
    # `refs/heads/$branch` が不在で `refs/tags/$branch` が存在する状態では**タグを削除する**
    # （実測確認済み。共有リモートのタグ削除は不可逆でリリース/CI を壊す）。存在確認した ref 集合と
    # 削除する ref 集合を定義上一致させる。
    if [ "$dry_run" = "true" ]; then
      echo "[CONTEXT] REMOTE_BRANCH_DELETE_DRY_RUN=1; branch=$branch"
    elif _push_err=$(LC_ALL=C git push origin --delete "refs/heads/$branch" 2>&1); then
      echo "[CONTEXT] REMOTE_BRANCH_DELETED=1; branch=$branch"
    else
      echo "[CONTEXT] REMOTE_BRANCH_DELETE_FAILED=1; branch=$branch" >&2
      # 外部由来テキストはデリミタで囲む。行頭一致だけでは複数行 stderr の 2 行目以降が列 0 に
      # 着地して marker として読まれうる（dirty ファイル一覧と同じ data/marker 分離）。
      echo "WARNING: リモートブランチ $branch の削除に失敗しました:" >&2
      echo "--- push stderr begin ---" >&2
      printf '%s\n' "$_push_err" | tr -d '\r' | sed 's/^/  /' >&2
      echo "--- push stderr end ---" >&2
    fi ;;
  2) echo "[CONTEXT] REMOTE_BRANCH_ALREADY_ABSENT=1; branch=$branch" ;;
  *)
    echo "[CONTEXT] REMOTE_BRANCH_CHECK_FAILED=1; branch=$branch; rc=${_ls_rc}${_check_reason:+; reason=${_check_reason}}" >&2
    # 多バイト文字に隣接する変数展開は必ず brace で閉じる。日本語文中で `$_ls_err。` と書くと
    # bash が `。` の先頭バイト (0xE3) を変数名に取り込み、非 UTF-8 ロケール (macOS CI 等) で
    # 変数が未定義化して原因テキストが消える。残った不正バイトは下流の BSD sed 等も落とす
    # （同 invariant: hooks/tests/flow-state.test.sh TC-8b-h）。
    # 捕捉した stderr は文末に置く。ls-remote の stderr は空行を含む複数行が常態のため、文中に
    # 挿入すると operative な日本語（削除を試行していない旨）が英文パラグラフの末尾に孤立する。
    # 直上のローカル削除が $del_err を文末に置いているのと同じ配置。
    # 原因は ls-remote とは限らない（完全一致検証の異常終了も本分岐へ落ちる）ため、コマンドを
    # 名指しせず rc と reason で示す。
    echo "WARNING: リモートブランチ $branch の存在確認に失敗したため削除を試行していません (rc=${_ls_rc}${_check_reason:+, ${_check_reason}}):" >&2
    echo "--- ls-remote stderr begin ---" >&2
    printf '%s\n' "${_ls_err}" | tr -d '\r' | sed 's/^/  /' >&2
    echo "--- ls-remote stderr end ---" >&2 ;;
esac
trap - EXIT INT TERM HUP
fi
fi
  ;;
esac
fi
exit 0
