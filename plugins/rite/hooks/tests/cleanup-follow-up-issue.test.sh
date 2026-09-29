#!/bin/bash
# cleanup-follow-up-issue.test.sh
#
# Behavioral tests for hooks/scripts/cleanup-follow-up-issue.sh
# (/rite:cleanup ステップ 6.0)。
#
# Coverage (T-01..T-06 + D-03 lookup fail + caller coupling):
#   T-01/T-02 残存指摘ありで 1 件起票され、body に出典・finding 要点・marker が含まれる
#             Projects status=todo (role) / enabled=true を args.json に pin
#   T-03 起票 API 失敗で WARNING + exit 0 (cleanup を止めない)
#   T-03g 最新が空でも先行 cycle の指摘が和集合で転記される
#   T-03u 一部 parse 不能でも健全側の和集合で起票する
#   T-03x 全 JSON が parse 不能なら json_undecidable
#   T-04 0 件で起票なし
#   T-05 既存 marker があれば重複起票しない
#   T-05c ラベル一覧に既存が居ない場合は起票する
#   T-05d 100 件を超える follow-up があっても marker 不在なら起票する (全ページ取得)
#   T-05i 2 ページ目の末尾にある既存 marker でも重複起票しない
#   T-05j ページ配列でない検索結果 (空応答 / 複数ドキュメント / [] / object / フラット配列) は起票せず lookup_api
#   T-05k 同じ marker を先頭行に持つ PR は既存 follow-up とみなさない
#   T-05e 説明欄へ他 PR の marker を植えても skip しない
#   T-05f body 2 行目の完全 HTML コメント marker では already_exists に倒さない
#   T-05g body 先頭行の裸 marker では already_exists に倒さない
#   T-05h body 先頭行の完全 HTML コメント marker + 後続テキストでは already_exists に倒さない
#   T-06 JSON 不在で skip + WARNING
#   T-07 同定 API 失敗は起票せず WARNING (D-03)
#   T-08 cleanup SKILL.md が helper を archive より前に呼ぶ
#   T-09 project-number 非数値は Projects skip + WARNING
#   T-10 project_registration=skipped は WARNING
#
# Coverage (T-01..T-05 = 本ファイルの T-11..T-15):
#   T-11 --exclude-ids で指定した finding だけが body から落ち、残りは全文が載る (AC-1)
#   T-12 全件除外は all_resolved で起票せず、既存 follow-up の検索もしない (AC-2)
#   T-13 未知 key は WARNING のうえ既知 key の除外だけ適用して起票を続行する (AC-3)
#   T-14 --exclude-ids 未指定 / 空文字列は既存挙動と完全一致 (AC-4)
#   T-15 cleanup SKILL.md が再検証手順・3 値語彙・除外引数・和集合抽出を持つ (AC-5 / AC-6)
#
# Coverage (全 cycle 和集合):
#   T-17 2 本の JSON の指摘が和集合で body に載る + 本数の stderr 1 行 (AC-1)
#   T-18 同一 id でも別 cycle の指摘は畳まず全件載る (AC-2)
#   T-19 --exclude-ids は和集合後に適用される (AC-3)
#   T-20 和集合の全件除外は all_resolved (AC-4)
#   T-21 全 JSON が 0 件なら no_findings (AC-7 非回帰)
#   T-22 id 欠落 / 書式外 id の finding を落とさない (MUST NOT)
#   T-23 parse 不能な JSON を 1 本だけ除外し、jq の原因行と union 内訳を surface する
#   T-23b 空 JSON の統合失敗でも健全側を転記する
#   T-24 同一 JSON 内で重複する id の key は除外せず WARNING + marker で surface する (別 JSON の同じ id は影響しない)
#   T-24b 重複 key でも --exclude-ids が指していなければ曖昧扱いしない
#   T-24c 形の検証に落ちた --exclude-ids の素値は neutralize_ctrl を通してから WARNING に載せる
#   T-25 曖昧判定の失敗ハンドラは安全側へ倒し marker も出す
#   T-25b 除外処理の jq 失敗でも件数付き marker を出し全 finding を保持する
#   T-27 除外拒否後の検索・起票失敗を成功として報告しない
#   T-28 再検証用一時ファイルの確保失敗を明示する
#
# Coverage (sweep 起票済み除外):
#   T-29 全件が sweep で issued なら all_issued で起票しない (--exclude-ids との合成を含む)。出典付き 5 列の
#        REJECT 行は出典が一致するときだけ除外する
#   T-30 issued だけを除き recorded は転記する / 記録コメント以外・issued 以外の行では除外しない
#   T-31 台帳を読めない (記録コメントの取得失敗 / 解析不能 / 関連 Issue 無し) ときは WARNING + marker で全件転記
#   T-32 台帳が無い PR は従来どおり全件転記
#   T-33 出典の無い 4 列の issued 行では、除外は最新 JSON 由来で組が一致する finding に限る。再掲マーカーの無い
#        先行 cycle の finding は id・位置が同じでも転記し、同じ file:line のものだけ重複候補として WARNING に出す。
#        行がずれた再報告は WARNING なしで重複しうる / 最新 JSON を照合できなければ apply_failed
#   T-34 cleanup SKILL.md が all_issued と除外不能 note を完了報告へ配線する
#   T-35 記録コメントは nb-sweep-collect.sh と同じく review-nonblocking-record.sh --print-record-body で読み
#        (前方一致の全件連結をしない)、台帳行の分解式も揃っている。CRLF の正規化は helper の 1 か所
#   T-35b 記録コメントが 2 件あっても helper が PATCH する 1 件の台帳だけを読む
#   T-36 CRLF 本文の却下台帳も (helper の正規化を経て) issued 行を読める
#
# Coverage (出典 JSON + id の除外 key):
#   T-37 別 JSON の同じ id は key が指す finding だけを除外し (同秒衝突 suffix `~{4 桁小文字 hex}` 付きの
#        出典を含む)、corrupt 退避ファイル由来は除外しない
#   T-38 複数 JSON にまたがる全 finding を key で除外すると all_resolved で起票しない
#   T-39 key 形式でないトークン (形が合わない suffix を含む) を 1 つでも含む --exclude-ids は除外を全く適用しない
#   T-41 6.0.V の射影が finding ごとに自分の出典の key を出し (同秒衝突 suffix 付きを含む)、形が合わなければ null にする
#
# Coverage (完全一致 finding の集約):
#   T-42 _src だけ異なる非隣接の完全一致 finding を初出順で 1 件にまとめる
#   T-43 1 フィールドでも異なる finding はまとめない
#   T-44 再検証による除外後に完全一致を判定し、残った finding を転記する
#   T-45 集約判定に失敗したら WARNING を出し、全 finding を元の順序で転記する
#
# Coverage (起票前の確認):
#   T-46 --preview-body は起票せず、起票時と同じ本文を書き出す
#   T-47 --preview-body でも 0 件・全件解消・全件起票済み・既存ありは従来の skip で終わり、判定済み記録を書く
#   T-48 preview 本文を書き出せなければ起票も preview もしない
#   T-49 SKILL 6.0.C の確認判定（batch --merge が今の Issue を処理中のときだけ確認しない）と
#        helper 呼び出しの配線、完了報告の declined / preview 行。壊れた・空・未置換の
#        run-queue は区別できる reason=queue_unreadable で確認する。完了報告の
#        failed; reason=preview_write 行は起票未試行の文言で汎用 failed 行と分離する
#
# Coverage (archive/ にある JSON):
#   T-50 読み元の列挙は直下と archive/ を basename のバイト順で合わせ、同名は直下だけを返す
#        (呼び出し元が C 以外の照合でも同秒衝突の `{ts}.json` → `{ts}~{hex}.json` の順)
#   T-51 archive/ にだけある JSON から転記する (no_json にしない)
#   T-52 直下と archive/ の同名 JSON は 1 回だけ数え、除外 key を曖昧にしない
#   T-53 最新 JSON が archive/ にあっても sweep 起票済みを除外する
#   T-54 6.0.V の再検証も archive/ の JSON を読む
#   T-55 マージ後に orphan 回収 → follow-up 起票 → cleanup の archive → orphan 回収の順で転記でき、
#        archive/ の JSON を二重に退避しない
#   T-56 C 以外の照合でも、最新 JSON は nb-sweep-collect.sh と同じ同秒衝突側 (archive/) を選ぶ
#   T-57 6.0.V で review-results-sources.sh を source できない場合は sources_lib_unavailable を出し、
#        no_json とは区別する
#
# Coverage (台帳の出典列):
#   T-58 先行 cycle の JSON を出典とする issued 行は、最新 JSON が変わっても (archive/ にあっても) 除外する
#   T-59 出典が最新 JSON の 5 列行は 4 列行と除外件数・重複候補・WARNING が一致する
#   T-60 出典の無い 4 列行は最新 JSON とだけ照合し、判定文のエスケープ済みパイプを出典と読まない
#   T-61 出典が一致しない再掲マーカーの無い finding は id・位置が同じでも転記し、出典で除外した先行 cycle 指摘の位置は
#        重複候補に数えない。その位置に別の先行 cycle の指摘があっても重複候補に数えない（3 cycle）
#   T-62 存在しない JSON を指す出典は除外しない / 形の合わない出典は出典無しとして扱う
#   T-63 末尾空白・エスケープ済みパイプ・CRLF の行からも出典を読む
#   T-64 記録コメントの取得失敗・最新 JSON の照合失敗では出典付きの行でも除外しない
#
# Coverage (起票済み指摘の再掲):
#   T-73 前後の cycle が再掲マーカー付きで id を変えて再報告した指摘も除外し、再掲として結んだ件数を出す
#        (マーカーの 2 つの書き方、最新 cycle で起票した場合、reviewer の帰属が変わった / 無い場合を含む)
#   T-74 同じ位置でもマーカーで結ばれない別の指摘は転記する (括弧外で id に触れる本文を含む)
#   T-75 マーカーが直前の cycle の同じ id・位置 (line・ファイル) を指さない / NOT_FIXED・再掲が無い / PARTIAL /
#        直前の cycle が 0 件・parse 不能・別の指摘のときは結ばない
#   T-76 起票済みの指摘と出典だけ、または出典と id だけが違う完全一致の指摘も除外する (reviewer が違えば転記)
#
# Coverage (Decision Log で先送りした欠陥):
#   T-65 指摘 0 件でも先送り欠陥があれば起票し、Section 9 内の本 PR のトークン行だけをトークンを除いて順に転記する
#   T-66 Section 9 の終端 3 種 (見出し / --- / </details>) の後ろと CRLF 本文
#   T-67 指摘と先送り欠陥を 1 件に載せる
#   T-68 元 Issue 本文の取得失敗は FOLLOW_UP_DEFERRED=unavailable を出し、採否ゲートも本文を読めず保留する
#   T-69 all_resolved / all_issued でも先送り欠陥があれば候補にして起票し、already_exists / json_undecidable は従来どおり。
#        JSON が無い (no_json) ときは PR の head を対象 commit にして列挙・判定し (記録が無ければ no_records で保留、
#        あれば起票)、PR の head を取れない / state root の git で解決できなければ head_unresolved で失敗する
#   T-70 preview の件数は指摘と先送り欠陥の合計
#   T-71 トークンと Section 9 の境界が pr-review 7.4.3 と helper で一致し、7.4.3 の {deferred_token} 付与条件表（2 行。トークンは採否ゲートの verdict が file の行だけ）が変わらない
#   T-72 cleanup SKILL.md の完了報告の配線
#   T-82 severity-levels / review-result-schema の follow-up 規則 (先送り欠陥も候補にする・採否ゲートの出口で
#        根因ごとに起票・出口が無ければ held で起票も退避もしない) が 1 回ずつあり、PR ごとに 1 件とする旧文を
#        持たず、周辺の節と正本 §6.0 の規則も残る。PR ごとに 1 件へ全文転記する旧契約の文は pr-review SKILL.md・
#        設定テンプレート・docs の CONFIGURATION.md / SPEC.md にも無い
#
# Coverage (判定済み記録):
#   T-77 判定後に purge が JSON を片付けた PR の再実行は already_processed で skip し no_json を出さない
#        (--preview-body 付きの呼び出しでも同じ)
#   T-78 判定済み記録の内容が不一致・読めないときは no_json に倒す
#   T-79 判定済み記録があっても先送り欠陥・archive/ の JSON がある経路は従来どおり
#   T-80 判定できなかった PR は記録を書かず再実行も no_json、SKILL.md は already_processed を x 相当に置く
#   T-81 判定済み記録を書けなくても結果は変えず WARNING を出し、影響（再実行の報告が no_json に戻る）を示す
#
# Coverage (採否ゲートの出口で起票を決める。判定記録を明示的に置く):
#   T-83 候補の列挙は指摘と先送り行を全文・出典・対象 commit つきで書き、起票も判定済み記録もしない。
#        旧形式の先送り行も候補にし、記録が無ければ保留する (終端にしない)
#   T-84 判定記録なし / ERROR / DIAGNOSE (preview 中も) は起票 helper を呼ばず held。判定済み記録を書かず、
#        hold ファイルに候補の全文・出典・対象 commit・再開位置が残る
#   T-84b ゲートが 0 / 3 以外で終わる (gate_failed_rc<n>) / ゲートの出力を読めない (gate_output_invalid) ときは
#        hold_file=none の held で、保存されていないことと失敗理由を示し、起票も判定済み記録もしない
#   T-85 根因ごとに 1 件起票し再実行で増えない。2 根因のうち 1 件が起票済みなら残り 1 件だけ。根因 key は ids の
#        整列で、ids が減った再実行も重なる起票済みの根因は増やさない。本文に契約の引用・根拠・受入条件。
#        一部の起票に失敗したら failed で、再実行は残りだけ
#   T-86 保留の後に判定記録を補うと保留分だけ起票し、起票済みの根因は増えない。purge 後の再実行も増えない。
#        purge で最新 JSON が消えて対象 commit が変わると、記録の head を合わせるまで保留する
#   T-87 調査として引き受けた DIAGNOSE は命題・到達条件とその出所・完了条件つきの調査 Issue を 1 件
#   T-88 REJECT / RESOLVED / LINK は起票せず all_recorded と件数。CLOSED の追跡先は LINK にしない
#   T-89 対象 commit は basename の降順で最初に読める commit_sha (archive/ を含む)
#   T-90 cleanup SKILL.md の判定記録の節・呼び出し引数・held の配線
#   T-91 採否ゲートが保留した候補は --exclude-ids で除かず列挙にも起票実行にも残し、RESOLVED の記録で処分すると
#        保留が解ける。hold ファイルが無ければ従来どおり除外し、読めなければ列挙も起票実行も hold_unreadable で失敗する
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_test-helpers.sh"

TARGET="$SCRIPT_DIR/../scripts/cleanup-follow-up-issue.sh"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
[ -f "$TARGET" ] || { echo "FATAL: target not found: $TARGET" >&2; exit 1; }

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/rite-fu-test-XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT INT TERM HUP

OUT="$TMP_ROOT/out"; ERR="$TMP_ROOT/err"; RC=0
STUB_DIR="$TMP_ROOT/stub"
export STUB_DIR
mkdir -p "$STUB_DIR" "$TMP_ROOT/bin"
CREATE_STUB="$STUB_DIR/create-issue-with-projects.sh"
GH_BIN="$TMP_ROOT/bin/gh"

# 採否ゲートが照合する対象 commit。fixture の JSON object に commit_sha が無ければ put_json / put_archived が足す
TEST_HEAD="0123456789abcdef0123456789abcdef01234567"
# 採否ゲートが PR 本文から引用を確かめる契約の行 (gh shim の pr view がどの PR にも返す)
PR_CONTRACT_LINE="契約: マージ時の残存指摘は follow-up で扱う"

# 判定記録の自動注入 (ADOPT_MODE=auto、既定)。起票の前提を固定する既存テスト用で、helper の
# --list-candidates が返した全候補を 1 根因 (ADOPT・pre_existing・受入条件あり) に束ねた記録を書き、
# 起票実行へ --adoption で渡す。保留・ERROR・出口ごとの挙動を固定するテストは ADOPT_MODE=manual で
# 判定記録を明示的に置く (自動注入の記録ではゲートを無視する変異を捕まえられない)。
# 列挙の実行は gh / jq の shim ログと起票回数を汚さないよう、実行前の内容へ戻す。
AUTO_ADOPTION="$TMP_ROOT/adoption-auto.json"
auto_adopt() {
  local saved="$TMP_ROOT/auto-saved" f
  mkdir -p "$saved"
  for f in gh.log comment.log jq-fail.log create_count; do
    if [ -e "$STUB_DIR/$f" ]; then cp "$STUB_DIR/$f" "$saved/$f"; else rm -f "$saved/$f"; fi
  done
  rm -f "$AUTO_ADOPTION" "$TMP_ROOT/auto-cands.json"
  PATH="$TMP_ROOT/bin:$PATH" bash "$TARGET" "$@" --list-candidates "$TMP_ROOT/auto-cands.json" >/dev/null 2>&1
  if [ -s "$TMP_ROOT/auto-cands.json" ] && [ "$(jq '.candidates | length' "$TMP_ROOT/auto-cands.json")" -gt 0 ]; then
    jq --arg c "$PR_CONTRACT_LINE" '{adoption: {head: .head, records: [
      {ids: [.candidates[].id], V: true, C: false, T: false, contract: {ref: "pr", text: $c},
       evidence: "テストの根拠", origin: "pre_existing", present: true, tracker: null, prior: null,
       reason: "", proposition: null, acceptance: "テストの受入条件"}]}}' \
      "$TMP_ROOT/auto-cands.json" > "$AUTO_ADOPTION"
  fi
  for f in gh.log comment.log jq-fail.log create_count; do
    if [ -e "$saved/$f" ]; then cp "$saved/$f" "$STUB_DIR/$f"; else rm -f "$STUB_DIR/$f"; fi
  done
}

# 引数はすべての helper 引数 (--base は足す)。ADOPT_MODE=auto なら判定記録を注入して --adoption で渡す
run_raw() {
  local -a extra=(--base develop)
  if [ "${ADOPT_MODE:-auto}" = auto ]; then
    auto_adopt "$@"
    extra+=(--adoption "$AUTO_ADOPTION")
  fi
  PATH="$TMP_ROOT/bin:$PATH" bash "$TARGET" "${extra[@]}" "$@" >"$OUT" 2>"$ERR"
  RC=$?
}

# $1=state_root remaining=extra helper args
run_target() {
  local root="$1"; shift
  run_raw \
      --state-root "$root" \
      --pr 9 \
      --owner acme \
      --repo demo \
      --source-issue 42 \
      --project-number 11 \
      --project-owner acme \
      --projects-enabled true \
      --create-script "$CREATE_STUB" \
      "$@"
}

new_root() {
  local root="$TMP_ROOT/root-$1"
  mkdir -p "$root/.rite/review-results"
  printf '%s' "$root"
}

# 1 つの JSON object で commit_sha を持たないものにだけ TEST_HEAD を足す (壊れた JSON はそのまま書く)
with_head() {
  if printf '%s\n' "$1" | jq -se 'length == 1 and (.[0] | type == "object" and (has("commit_sha") | not))' >/dev/null 2>&1; then
    printf '%s\n' "$1" | jq -c --arg h "$TEST_HEAD" '. + {commit_sha: $h}'
  else
    printf '%s\n' "$1"
  fi
}
put_json() { with_head "$3" > "$1/.rite/review-results/$2"; }

# $1=state_root。state root を git リポジトリにして commit を 1 つ作り、その commit id を出す。commit_sha を持つ
# レビュー結果 JSON が無いとき、helper は PR の head をこの git で解決できる場合だけ対象 commit にする
git_head_commit() {
  local tree
  git -C "$1" init -q >/dev/null 2>&1 || return 1
  tree=$(git -C "$1" hash-object -w -t tree /dev/null) || return 1
  git -C "$1" -c user.name=rite-test -c user.email=rite-test@example.invalid -c commit.gpgsign=false \
    commit-tree "$tree" -m fixture
}

# gh shim: list / label create / issue comment
cat > "$GH_BIN" <<'GH'
#!/bin/bash
echo "gh $*" >> "${GH_LOG:-/dev/null}"
cmd="$*"
case "$cmd" in
  *"label create"*) exit 0 ;;
  # 既存 follow-up の検索は follow-up ラベルの全ページ。取得先と pagination 指定まで一致したときだけ応答する
  "api --paginate --slurp repos/acme/demo/issues?labels=follow-up&state=all&per_page=100")
    if [ -n "${GH_LIST_RC:-}" ] && [ "${GH_LIST_RC}" != "0" ]; then
      echo "gh: simulated list failure" >&2
      exit "$GH_LIST_RC"
    fi
    cat "${GH_LIST_JSON:-/dev/null}"
    exit 0
    ;;
  *"issue comment"*)
    echo "gh $*" >> "${GH_COMMENT_LOG:-/dev/null}"
    exit "${GH_COMMENT_RC:-0}"
    ;;
  # 記録 helper の読み取り専用モード: 自 login / 関連 Issue の解決 (closing keyword) / Issue body (durable id なし)
  "api user --jq .login") echo rite-bot; exit 0 ;;
  "pr view 9 -R acme/demo --json body --jq .body") echo "Closes #42"; echo "契約: マージ時の残存指摘は follow-up で扱う"; exit 0 ;;
  # closing keyword を持たない PR (関連 Issue は解決できない)。採否ゲートが引用を確かめる契約の行だけを返す
  "pr view "*" -R acme/demo --json body --jq .body") echo "契約: マージ時の残存指摘は follow-up で扱う"; exit 0 ;;
  "pr view "*" -R acme/demo --json headRefName --jq .headRefName") echo "feature/no-related"; exit 0 ;;
  # 採否ゲートが判定記録の tracker の状態を読む
  "issue view 7 --json state --jq .state") echo "${GH_TRACKER_STATE:-OPEN}"; exit 0 ;;
  "issue view 42 -R acme/demo --json body --jq .body")
    if [ -n "${GH_ISSUE_BODY_RC:-}" ] && [ "${GH_ISSUE_BODY_RC}" != "0" ]; then
      echo "gh: simulated issue view failure" >&2
      exit "$GH_ISSUE_BODY_RC"
    fi
    cat "${GH_ISSUE_BODY:-/dev/null}"
    exit 0
    ;;
  # pr-cycle-cleanup.sh の orphan review 回収が見る PR の状態
  "pr view 9 -R acme/demo --json state --jq .state") echo MERGED; exit 0 ;;
  # commit_sha を持つレビュー結果 JSON が無いときに helper が対象 commit にする PR の head。GH_HEAD_OID が無ければ失敗する
  "pr view 9 -R acme/demo --json headRefOid --jq .headRefOid")
    if [ -z "${GH_HEAD_OID:-}" ]; then
      echo "gh: simulated pr view failure" >&2
      exit 1
    fi
    echo "$GH_HEAD_OID"
    exit 0
    ;;
  # 記録 helper が却下台帳を書いた本文で記録コメントを更新する (本文を GH_PATCH_OUT へ保存する)
  "api repos/acme/demo/issues/comments/"*" -X PATCH --input -")
    jq -r '.body' > "${GH_PATCH_OUT:-/dev/null}"
    exit "${GH_PATCH_RC:-0}"
    ;;
  # 記録 helper が PATCH 先と決めた 1 件の GET
  "api repos/acme/demo/issues/comments/"*)
    jq --argjson id "${cmd##*/}" '[.[][] | select(.id == $id)][0]' "${GH_API_JSON:-/dev/null}"
    exit 0
    ;;
  # 却下台帳の取得元は関連 Issue のコメント全ページ。取得先と pagination 指定まで一致したときだけ応答する
  "api --paginate --slurp repos/acme/demo/issues/42/comments")
    if [ -n "${GH_API_RC:-}" ] && [ "${GH_API_RC}" != "0" ]; then
      echo "gh: simulated api failure" >&2
      exit "$GH_API_RC"
    fi
    cat "${GH_API_JSON:-/dev/null}"
    exit 0
    ;;
esac
echo "unexpected gh: $*" >&2
exit 1
GH
chmod +x "$GH_BIN"

# 指定した jq フィルタだけを失敗させ、その他は実体へ委譲する。
export RITE_TEST_REAL_JQ="$(command -v jq)"
cat > "$TMP_ROOT/bin/jq" <<'JQ'
#!/bin/bash
for arg in "$@"; do
  case "${RITE_TEST_JQ_FAIL:-}:$arg" in
    ledger:*'split("### 却下台帳'*|parse:*'split("\n") | join(",") | split(",")'*|ambiguity:*'map(select(length > 1)'*|release:'. - $amb'|apply:*'[.[] | select(key as $k'*|dedupe:*'reduce .[] as $finding'*)
      printf '%s\n' "$RITE_TEST_JQ_FAIL" >> "$STUB_DIR/jq-fail.log"
      cat >/dev/null
      echo "jq: injected $RITE_TEST_JQ_FAIL failure" >&2
      exit 5 ;;
  esac
done
exec "$RITE_TEST_REAL_JQ" "$@"
JQ
chmod +x "$TMP_ROOT/bin/jq"

# create-issue stub: copies body, emits success JSON unless CREATE_RC set
cat > "$CREATE_STUB" <<'STUB'
#!/bin/bash
printf '%s\n' "$1" > "${STUB_DIR}/args.json"
body=$(printf '%s' "$1" | jq -r '.issue.body_file // empty')
if [ -n "$body" ] && [ -f "$body" ]; then
  cp "$body" "${STUB_DIR}/body.md"
fi
echo 1 >> "${STUB_DIR}/create_count"
if [ -n "${CREATE_RC:-}" ] && [ "$CREATE_RC" != "0" ]; then
  echo "create-issue: simulated failure" >&2
  exit "$CREATE_RC"
fi
reg="${CREATE_REG:-ok}"
num=99
# CREATE_SEQ=1: 起票ごとに別の番号 (60, 61, ...) を返し、本文ごと既存 follow-up の一覧へ足す
# (再実行が一覧の先頭行 marker で起票済みを見分けることを実際に通す)
if [ -n "${CREATE_SEQ:-}" ]; then
  num=$((59 + $(wc -l < "${STUB_DIR}/create_count")))
  cp "$body" "${STUB_DIR}/body-${num}.md"
  jq --rawfile b "$body" --argjson n "$num" '.[0] += [{number: $n, body: $b}]' "$GH_LIST_JSON" > "$GH_LIST_JSON.tmp" \
    && mv "$GH_LIST_JSON.tmp" "$GH_LIST_JSON"
fi
printf '%s\n' "{\"issue_url\":\"https://example.test/issues/${num}\",\"issue_number\":${num},\"project_id\":\"PVT_x\",\"item_id\":\"PVTI_x\",\"project_registration\":\"${reg}\",\"warnings\":[]}"
STUB
chmod +x "$CREATE_STUB"

reset_stubs() {
  rm -f "$STUB_DIR/args.json" "$STUB_DIR/body.md" "$STUB_DIR/create_count"
  : > "$STUB_DIR/create_count"
  export STUB_DIR
  export GH_LOG="$STUB_DIR/gh.log"
  export GH_COMMENT_LOG="$STUB_DIR/comment.log"
  export GH_LIST_JSON="$STUB_DIR/list.json"
  export GH_LIST_RC=0
  export GH_COMMENT_RC=0
  export GH_API_JSON="$STUB_DIR/comments.json"
  export GH_API_RC=0
  printf '%s\n' '[[]]' > "$GH_API_JSON"
  unset CREATE_RC
  unset CREATE_REG CREATE_SEQ
  unset GH_ISSUE_BODY GH_ISSUE_BODY_RC GH_TRACKER_STATE GH_HEAD_OID
  unset RITE_TEST_JQ_FAIL
  ADOPT_MODE=auto
  : > "$STUB_DIR/jq-fail.log"
  printf '%s\n' '[[]]' > "$GH_LIST_JSON"
  : > "$GH_LOG"
  : > "$GH_COMMENT_LOG"
}

create_count() {
  if [ -f "$STUB_DIR/create_count" ]; then
    wc -l < "$STUB_DIR/create_count" | tr -d ' '
  else
    echo 0
  fi
}

FINDING_JSON='{"non_blocking_findings":[{"id":"F-01","reviewer":"code-quality-reviewer","severity":"LOW","file":"plugins/rite/skills/cleanup/SKILL.md","line":12,"description":"実測なしの指摘本文","suggestion":"別 PR で対応"}]}'

echo "--- T-01/T-02: 残存指摘ありで 1 件起票 + body 要点 ---"
reset_stubs
r=$(new_root t01)
put_json "$r" "9-20260101120000.json" "$FINDING_JSON"
run_target "$r"
assert "T-01 exit 0" "0" "$RC"
assert_grep "T-01 created marker" "$ERR" 'FOLLOW_UP_ISSUE=created; issue=99; existing=0; recorded=0; pr=9'
assert "T-01 create 1 回" "1" "$(create_count)"
assert "T-02 body 先頭行は根因単位の HTML コメント marker" "<!-- [rite-follow-up-from-pr:9:9-20260101120000.json#F-01] -->" "$(head -1 "$STUB_DIR/body.md")"
assert "T-02 body 2 行目 Type" "**Type**: fix" "$(sed -n '2p' "$STUB_DIR/body.md")"
assert "T-02 body 3 行目 Complexity" "**Complexity**: S" "$(sed -n '3p' "$STUB_DIR/body.md")"
assert "T-02 body 4 行目 空行" "" "$(sed -n '4p' "$STUB_DIR/body.md")"
assert "T-02 body 5 行目 概要" "## 概要" "$(sed -n '5p' "$STUB_DIR/body.md")"
_t01_extracted=$(sed -n 's/^[[:space:]]*\*\*Complexity\*\*:[[:space:]]*\([A-Za-z][A-Za-z]*\).*$/\1/p' "$STUB_DIR/body.md" | head -1)
assert "T-01 記法1 sed 抽出" "S" "$_t01_extracted"
_t01_args_complexity=$(jq -r '.projects.complexity' "$STUB_DIR/args.json")
assert "T-01 args.json complexity は抽出値と同一" "$_t01_extracted" "$_t01_args_complexity"
assert_grep "T-01 --arg complexity は _fu_complexity" "$TARGET" '[[:space:]]--arg complexity "\$_fu_complexity"'
assert_grep "T-01 --arg priority は _fu_priority" "$TARGET" '[[:space:]]--arg priority "\$_fu_priority"'
assert_grep "T-02 元 PR" "$STUB_DIR/body.md" '元 PR: #9'
assert_grep "T-02 元 Issue" "$STUB_DIR/body.md" '元 Issue: #42'
assert_grep "T-02 reviewer" "$STUB_DIR/body.md" 'code-quality-reviewer'
assert_grep "T-02 severity" "$STUB_DIR/body.md" 'LOW'
assert_grep "T-02 file:line" "$STUB_DIR/body.md" 'cleanup/SKILL.md:12'
assert_grep "T-02 description" "$STUB_DIR/body.md" '実測なしの指摘本文'
assert_grep "T-02 labels follow-up" "$STUB_DIR/args.json" '"follow-up"'
assert_grep "T-02 source cleanup" "$STUB_DIR/args.json" '"source": "cleanup"'
assert_grep "T-01 status todo role" "$STUB_DIR/args.json" '"status": "todo"'
assert_grep "T-01 projects enabled true" "$STUB_DIR/args.json" '"enabled": true'
assert_grep "T-01 follow-up ラベルを全ページで検索する" "$GH_LOG" '^gh api --paginate --slurp repos/acme/demo/issues\?labels=follow-up&state=all&per_page=100$'
assert_not_grep "T-01 gh は Search API を使わない" "$GH_LOG" 'rite-follow-up-from-pr'
assert_not_grep "T-01 先送り欠陥の取得失敗 marker を出さない" "$ERR" 'FOLLOW_UP_DEFERRED'
assert_not_grep "T-01 先送り節を出さない" "$STUB_DIR/body.md" '^## Decision Log で先送りした欠陥$'
assert_grep "T-02 元 Issue へコメント" "$GH_COMMENT_LOG" 'issue comment 42'
# 残存指摘には実測済みの非 fatal 指摘も含まれるため、タイトル・節名・概要・元 Issue コメントは非実測と断定しない。
assert "T-02 title は非実測と断定せず先頭候補の説明を付ける" "follow-up: PR #9 の残存指摘（実測なしの指摘本文）" "$(jq -r '.issue.title' "$STUB_DIR/args.json")"
assert "T-02 概要文" "1" "$(grep -cxF 'PR #9 のレビュー候補のうち、採否判定で起票と決まった既存の欠陥を follow-up として切り出す。' "$STUB_DIR/body.md")"
assert "T-02 節名" "1" "$(grep -cxF '## 残存 non-blocking 指摘' "$STUB_DIR/body.md")"
assert "T-02 元 Issue コメント文" "1" "$(grep -cF '"PR #${PR_NUMBER} の follow-up（採否判定で起票と決まった根因ごと）:"' "$TARGET")"
assert "T-02 本文・タイトルに非実測の断定なし" "0" "$(cat "$STUB_DIR/body.md" "$STUB_DIR/args.json" | grep -c '非実測' || true)"
assert_not_grep "T-01 台帳取得は成功経路" "$ERR" 'FOLLOW_UP_SWEEP_ISSUED=unavailable'

echo "--- T-03: 起票 API 失敗は WARNING + exit 0 ---"
reset_stubs
export CREATE_RC=1
r=$(new_root t03)
put_json "$r" "9-a.json" "$FINDING_JSON"
run_target "$r"
assert "T-03 exit 0 (non-blocking)" "0" "$RC"
assert_grep "T-03 failed marker" "$ERR" 'FOLLOW_UP_ISSUE=failed; reason=create_api; pr=9'
assert_grep "T-03 WARNING" "$ERR" '起票に失敗'
assert "T-03 起票失敗では判定済み記録を書かない" "no" "$([ -e "$r/.rite/state/follow-up-judged-9.txt" ] && echo yes || echo no)"
unset CREATE_RC

echo "--- T-03g: 最新が空でも先行 cycle の指摘は和集合で転記される (AC-1) ---"
reset_stubs
r=$(new_root t03g)
put_json "$r" "9-20260101120000.json" "$FINDING_JSON"
put_json "$r" "9-20260102120000.json" '{"non_blocking_findings":[]}'
run_target "$r"
assert "T-03g exit 0" "0" "$RC"
assert_grep "T-03g created" "$ERR" 'FOLLOW_UP_ISSUE=created; issue=99; existing=0; recorded=0; pr=9'
assert "T-03g create 1 回" "1" "$(create_count)"
assert_grep "T-03g 先行 cycle の finding が body に載る" "$STUB_DIR/body.md" '実測なしの指摘本文'

echo "--- T-03u: 一部 parse 不能でも健全側で起票する (AC-5) ---"
reset_stubs
r=$(new_root t03u)
put_json "$r" "9-20260101120000.json" "$FINDING_JSON"
put_json "$r" "9-20260102120000.json" 'not-json{'
run_target "$r"
assert "T-03u exit 0" "0" "$RC"
assert_grep "T-03u WARNING (和集合から除外)" "$ERR" '和集合から除外します'
assert_grep "T-03u created" "$ERR" 'FOLLOW_UP_ISSUE=created; issue=99; existing=0; recorded=0; pr=9'
assert "T-03u create 1 回" "1" "$(create_count)"
assert_grep "T-03u 健全側の finding が body に載る" "$STUB_DIR/body.md" '実測なしの指摘本文'

echo "--- T-03x: 全 JSON が parse 不能なら json_undecidable ---"
reset_stubs
r=$(new_root t03x)
put_json "$r" "9-20260101120000.json" 'not-json{'
put_json "$r" "9-20260102120000.json" '{"non_blocking_findings":"abc"}'
run_target "$r"
assert "T-03x exit 0" "0" "$RC"
assert_grep "T-03x json_undecidable" "$ERR" 'reason=json_undecidable; pr=9'
assert "T-03x create 0 回" "0" "$(create_count)"

echo "--- T-04: 0 件で起票なし ---"
reset_stubs
r=$(new_root t04)
put_json "$r" "9-empty.json" '{"non_blocking_findings":[]}'
run_target "$r"
assert "T-04 exit 0" "0" "$RC"
assert_grep "T-04 skipped no_findings" "$ERR" 'reason=no_findings; pr=9'
assert "T-04 create 0 回" "0" "$(create_count)"
assert_not_grep "T-04 台帳取得 (gh api) を叩かない" "$GH_LOG" '^gh api '

echo "--- T-05: 既存 marker なら重複起票しない ---"
reset_stubs
printf '%s\n' '[[{"number":50,"body":"<!-- [rite-follow-up-from-pr:9] -->\n既存"}]]' > "$GH_LIST_JSON"
r=$(new_root t05)
put_json "$r" "9-a.json" "$FINDING_JSON"
run_target "$r"
assert "T-05 exit 0" "0" "$RC"
assert_grep "T-05 already_exists" "$ERR" 'reason=already_exists; issue=50; pr=9'
assert "T-05 create 0 回" "0" "$(create_count)"
assert "T-05 already_exists でも判定済み記録を書く" "pr=9" "$(cat "$r/.rite/state/follow-up-judged-9.txt" 2>/dev/null)"

echo "--- T-05b: PR 9 の marker は PR 90 と一致しない ---"
reset_stubs
printf '%s\n' '[[{"number":51,"body":"<!-- [rite-follow-up-from-pr:90] -->"}]]' > "$GH_LIST_JSON"
r=$(new_root t05b)
put_json "$r" "9-a.json" "$FINDING_JSON"
run_target "$r"
assert "T-05b prefix 非一致なら起票する" "1" "$(create_count)"

echo "--- T-05c: ラベル一覧に既存 marker が居なければ起票する ---"
reset_stubs
printf '%s\n' '[[{"number":60,"body":"unrelated follow-up"}]]' > "$GH_LIST_JSON"
r=$(new_root t05c)
put_json "$r" "9-a.json" "$FINDING_JSON"
run_target "$r"
assert "T-05c create 1 回" "1" "$(create_count)"
assert_grep "T-05c created" "$ERR" 'FOLLOW_UP_ISSUE=created; issue=99; existing=0; recorded=0; pr=9'

echo "--- T-05d: 100 件を超えても marker 不在なら 1 件起票する ---"
reset_stubs
jq -n '[[range(100) | {number: (1000+.), body: "no marker"}], [range(50) | {number: (1100+.), body: "no marker"}]]' > "$GH_LIST_JSON"
r=$(new_root t05d)
put_json "$r" "9-a.json" "$FINDING_JSON"
run_target "$r"
assert "T-05d exit 0" "0" "$RC"
assert_grep "T-05d created" "$ERR" 'FOLLOW_UP_ISSUE=created; issue=99; existing=0; recorded=0; pr=9'
assert "T-05d create 1 回" "1" "$(create_count)"
assert_not_grep "T-05d 件数で止めない" "$ERR" 'reason=lookup_api|limit'
assert "T-05d 全ページ取得は 1 回の呼び出し" "1" "$(grep -c '^gh api --paginate --slurp repos/acme/demo/issues?labels=' "$GH_LOG")"

echo "--- T-05i: 2 ページ目の末尾にある既存 marker でも重複起票しない ---"
reset_stubs
jq -n '[([range(99) | {number: (1000+.), body: "no marker"}] + [{number: 1099, body: "<!-- [rite-follow-up-from-pr:90] -->"}]), ([range(49) | {number: (1100+.), body: "no marker"}] + [{number: 1149, body: "<!-- [rite-follow-up-from-pr:9] -->\n既存"}])]' > "$GH_LIST_JSON"
r=$(new_root t05i)
put_json "$r" "9-a.json" "$FINDING_JSON"
run_target "$r"
assert "T-05i exit 0" "0" "$RC"
assert_grep "T-05i already_exists" "$ERR" 'reason=already_exists; issue=1149; pr=9'
assert "T-05i create 0 回" "0" "$(create_count)"

echo "--- T-05j: ページ配列でない検索結果は起票せず lookup_api ---"
for shape in none multi empty object flat; do
  reset_stubs
  case "$shape" in
    none) : > "$GH_LIST_JSON" ;;
    multi) printf '%s\n%s\n' '[[]]' '[[{"number":1,"body":"<!-- [rite-follow-up-from-pr:9] -->"}]]' > "$GH_LIST_JSON" ;;
    empty) printf '%s\n' '[]' > "$GH_LIST_JSON" ;;
    object) printf '%s\n' '{"message":"not pages"}' > "$GH_LIST_JSON" ;;
    flat) printf '%s\n' '[{"number":1,"body":"<!-- [rite-follow-up-from-pr:9] -->"}]' > "$GH_LIST_JSON" ;;
  esac
  r=$(new_root "t05j-$shape")
  put_json "$r" "9-a.json" "$FINDING_JSON"
  run_target "$r"
  assert "T-05j $shape exit 0" "0" "$RC"
  assert_grep "T-05j $shape lookup_api" "$ERR" 'reason=lookup_api; pr=9'
  assert_grep "T-05j $shape 解析失敗の経路を通る" "$ERR" '検索結果を解析できません'
  assert_not_grep "T-05j $shape 想定外の gh 呼び出しなし" "$ERR" 'unexpected gh'
  assert "T-05j $shape create 0 回" "0" "$(create_count)"
done

echo "--- T-05k: 同じ marker を先頭行に持つ PR は既存 follow-up とみなさない ---"
reset_stubs
printf '%s\n' '[[{"number":70,"body":"<!-- [rite-follow-up-from-pr:9] -->","pull_request":{"url":"https://example.test/pulls/70"}}]]' > "$GH_LIST_JSON"
r=$(new_root t05k)
put_json "$r" "9-a.json" "$FINDING_JSON"
run_target "$r"
assert "T-05k exit 0" "0" "$RC"
assert_not_grep "T-05k already_exists に倒さない" "$ERR" 'already_exists'
assert "T-05k create 1 回" "1" "$(create_count)"

echo "--- T-05e: 説明欄の他 PR marker では already_exists に倒さない ---"
reset_stubs
printf '%s\n' '[[{"number":99,"body":"<!-- [rite-follow-up-from-pr:9] -->\n説明: [rite-follow-up-from-pr:123]"}]]' > "$GH_LIST_JSON"
r=$(new_root t05e)
put_json "$r" "123-a.json" "$FINDING_JSON"
run_raw \
    --state-root "$r" \
    --pr 123 \
    --owner acme \
    --repo demo \
    --projects-enabled false \
    --create-script "$CREATE_STUB"
assert "T-05e exit 0" "0" "$RC"
assert "T-05e create 1 回" "1" "$(create_count)"
assert_grep "T-05e created for pr 123" "$ERR" 'FOLLOW_UP_ISSUE=created; issue=99; existing=0; recorded=0; pr=123'
assert_not_grep "T-05e already_exists に倒さない" "$ERR" 'already_exists'

echo "--- T-05f: body 2 行目の完全 HTML コメント marker では already_exists に倒さない ---"
reset_stubs
printf '%s\n' '[[{"number":99,"body":"概要\n<!-- [rite-follow-up-from-pr:123] -->"}]]' > "$GH_LIST_JSON"
r=$(new_root t05f)
put_json "$r" "123-a.json" "$FINDING_JSON"
run_raw \
    --state-root "$r" \
    --pr 123 \
    --owner acme \
    --repo demo \
    --projects-enabled false \
    --create-script "$CREATE_STUB"
assert "T-05f exit 0" "0" "$RC"
assert "T-05f create 1 回" "1" "$(create_count)"
assert_grep "T-05f created for pr 123" "$ERR" 'FOLLOW_UP_ISSUE=created; issue=99; existing=0; recorded=0; pr=123'
assert_not_grep "T-05f already_exists に倒さない" "$ERR" 'already_exists'

echo "--- T-05g: 先頭行の裸 marker では already_exists に倒さない ---"
reset_stubs
printf '%s\n' '[[{"number":99,"body":"参照: [rite-follow-up-from-pr:123] を見よ"}]]' > "$GH_LIST_JSON"
r=$(new_root t05g)
put_json "$r" "123-a.json" "$FINDING_JSON"
run_raw \
    --state-root "$r" \
    --pr 123 \
    --owner acme \
    --repo demo \
    --projects-enabled false \
    --create-script "$CREATE_STUB"
assert "T-05g exit 0" "0" "$RC"
assert "T-05g create 1 回" "1" "$(create_count)"
assert_grep "T-05g created for pr 123" "$ERR" 'FOLLOW_UP_ISSUE=created; issue=99; existing=0; recorded=0; pr=123'
assert_not_grep "T-05g already_exists に倒さない" "$ERR" 'already_exists'

echo "--- T-05h: 先頭行の完全 HTML コメント marker + 後続テキストでは already_exists に倒さない ---"
reset_stubs
printf '%s\n' '[[{"number":99,"body":"<!-- [rite-follow-up-from-pr:123] --> extra"}]]' > "$GH_LIST_JSON"
r=$(new_root t05h)
put_json "$r" "123-a.json" "$FINDING_JSON"
run_raw \
    --state-root "$r" \
    --pr 123 \
    --owner acme \
    --repo demo \
    --projects-enabled false \
    --create-script "$CREATE_STUB"
assert "T-05h exit 0" "0" "$RC"
assert "T-05h create 1 回" "1" "$(create_count)"
assert_grep "T-05h created for pr 123" "$ERR" 'FOLLOW_UP_ISSUE=created; issue=99; existing=0; recorded=0; pr=123'
assert_not_grep "T-05h already_exists に倒さない" "$ERR" 'already_exists'

echo "--- T-06: JSON 不在で skip + WARNING ---"
reset_stubs
r=$(new_root t06)
assert "T-06 前提: 判定済み記録が無い" "no" "$([ -e "$r/.rite/state/follow-up-judged-9.txt" ] && echo yes || echo no)"
run_target "$r"
assert "T-06 exit 0" "0" "$RC"
assert_grep "T-06 skipped no_json" "$ERR" 'reason=no_json; pr=9'
assert_grep "T-06 WARNING" "$ERR" 'レビュー結果 JSON が見つかりません'
assert "T-06 create 0 回" "0" "$(create_count)"
assert_not_grep "T-06 台帳取得 (gh api) を叩かない" "$GH_LOG" '^gh api '

echo "--- T-07: 同定 API 失敗は起票しない ---"
reset_stubs
export GH_LIST_RC=1
r=$(new_root t07)
put_json "$r" "9-a.json" "$FINDING_JSON"
run_target "$r"
assert "T-07 exit 0" "0" "$RC"
assert_grep "T-07 lookup_api" "$ERR" 'reason=lookup_api; pr=9'
assert_grep "T-07 検索 API の失敗経路を通る" "$ERR" 'simulated list failure'
assert_not_grep "T-07 想定外の gh 呼び出しなし" "$ERR" 'unexpected gh'
assert "T-07 lookup_api では判定済み記録を書かない" "no" "$([ -e "$r/.rite/state/follow-up-judged-9.txt" ] && echo yes || echo no)"
assert "T-07 create 0 回" "0" "$(create_count)"
unset GH_LIST_RC

echo "--- T-08: cleanup ステップ 6.0 が helper を archive より前に呼ぶ ---"
CLEANUP_MD="$SCRIPT_DIR/../../skills/cleanup/SKILL.md"
if [ ! -f "$CLEANUP_MD" ]; then
  fail "T-08 cleanup/SKILL.md が見つからない: $CLEANUP_MD"
else
  # 6.0.A の候補列挙と 6.0.C 後の起票実行の 2 本
  assert "T-08 helper 呼び出しが実行位置に 2 本 (列挙と起票)" "2" \
    "$(grep -cE '^[[:space:]]*bash [^[:space:]]*hooks/scripts/cleanup-follow-up-issue\.sh' "$CLEANUP_MD" || true)"
  # archive 呼び出しは cleanup-pr-state-purge.sh へ抽出済み。SKILL.md 上の順序 pin は
  # 「follow-up 起票 → state purge helper」の並びで見る（archive は purge helper の中で走る）。
  # JSON が元の場所にあるうちに読む、という 6.0 の前提はこの並びが保つ。
  fu_line=$(grep -nE 'hooks/scripts/cleanup-follow-up-issue\.sh' "$CLEANUP_MD" | head -1 | cut -d: -f1)
  ar_line=$(grep -nE 'hooks/scripts/cleanup-pr-state-purge\.sh' "$CLEANUP_MD" | head -1 | cut -d: -f1)
  if [ -n "$fu_line" ] && [ -n "$ar_line" ] && [ "$fu_line" -lt "$ar_line" ]; then
    pass "T-08 follow-up 呼び出しが state purge (archive を含む) より前"
  else
    fail "T-08 follow-up ($fu_line) が state purge ($ar_line) より前に無い"
  fi
  assert "T-08 helper の rc を捕捉している" "1" \
    "$(grep -cF '|| _fu_rc=$?' "$CLEANUP_MD" || true)"
  assert_grep "T-08 owner_repo を slash split する" "$CLEANUP_MD" 'IFS=/ read -r _gh_owner _gh_repo <<< "\{owner_repo\}"'
  assert_grep "T-08 --owner は repo owner" "$CLEANUP_MD" 'owner "\$\{_gh_owner\}"'
  assert_grep "T-08 --project-owner は Projects owner" "$CLEANUP_MD" 'project-owner "\{owner\}"'
  assert_grep "T-08 project-number を引用する" "$CLEANUP_MD" 'project-number "\{project_number\}"'
  assert_grep "T-08 projects-enabled を引用する" "$CLEANUP_MD" 'projects-enabled "\{projects_enabled\}"'
  assert_grep "T-08 pr= の値は直後が ; または行末" "$CLEANUP_MD" 'pr=` の値は直後が `;` または行末であることまで含めて一致させる'
  assert_grep "T-08 recency 適用範囲は follow-up 側に限定" "$CLEANUP_MD" 'follow-up 側で同一 marker family の複数行が一致したときは最後の出現（recency）を採る'
  assert "T-08 recency 選択は follow-up 側に限定" "1" \
    "$(grep -cF 'この選択は**follow-up 側**の判定ルールを評価する前に行う' "$CLEANUP_MD" || true)"
fi

echo "--- T-09: project-number 非数値は Projects skip + WARNING ---"
reset_stubs
r=$(new_root t09)
put_json "$r" "9-a.json" "$FINDING_JSON"
run_raw \
    --state-root "$r" \
    --pr 9 \
    --owner acme \
    --repo demo \
    --project-number null \
    --projects-enabled true \
    --create-script "$CREATE_STUB"
assert "T-09 exit 0" "0" "$RC"
assert_grep "T-09 created" "$ERR" 'FOLLOW_UP_ISSUE=created; issue=99; existing=0; recorded=0; pr=9'
assert_grep "T-09 project-number WARNING" "$ERR" '数値ではないため Projects 登録を skip'
assert_grep "T-09 projects enabled false" "$STUB_DIR/args.json" '"enabled": false'
assert_not_grep "T-09 enabled true を残さない" "$STUB_DIR/args.json" '"enabled": true'

echo "--- T-10: project_registration=skipped は WARNING ---"
reset_stubs
export CREATE_REG=skipped
r=$(new_root t10)
put_json "$r" "9-a.json" "$FINDING_JSON"
run_target "$r"
assert "T-10 exit 0" "0" "$RC"
assert_grep "T-10 created" "$ERR" 'FOLLOW_UP_ISSUE=created; issue=99; existing=0; recorded=0; pr=9'
assert_grep "T-10 skipped WARNING" "$ERR" 'Projects 登録: skipped'
unset CREATE_REG

TWO_FINDING_JSON='{"non_blocking_findings":[{"id":"F-01","reviewer":"code-quality-reviewer","severity":"LOW","file":"a.md","line":3,"description":"残存する指摘の本文","suggestion":"残存する提案"},{"id":"F-05","reviewer":"tech-writer-reviewer","severity":"LOW","file":"b.md","line":9,"description":"解消済みの指摘の本文","suggestion":"解消済みの提案"}]}'

echo "--- T-11: 部分除外は除外 id だけを落とし残りは全文を載せる (AC-1) ---"
reset_stubs
r=$(new_root t11)
put_json "$r" "9-20260101120000.json" "$TWO_FINDING_JSON"
run_target "$r" --exclude-ids "9-20260101120000.json#F-05"
assert "T-11 exit 0" "0" "$RC"
assert_grep "T-11 created" "$ERR" 'FOLLOW_UP_ISSUE=created; issue=99; existing=0; recorded=0; pr=9'
assert "T-11 create 1 回" "1" "$(create_count)"
# 件数一致では除外 id と残存 id の入れ替わりを検出できないため id と本文の present/absent で pin
assert_grep "T-11 残存 id が body にある" "$STUB_DIR/body.md" 'F-01'
assert_grep "T-11 残存 description が body にある" "$STUB_DIR/body.md" '残存する指摘の本文'
assert_grep "T-11 残存 suggestion が body にある" "$STUB_DIR/body.md" '残存する提案'
assert_not_grep "T-11 除外 id が body に無い" "$STUB_DIR/body.md" 'F-05'
assert_not_grep "T-11 除外 description が body に無い" "$STUB_DIR/body.md" '解消済みの指摘の本文'
assert_not_grep "T-11 除外 suggestion が body に無い" "$STUB_DIR/body.md" '解消済みの提案'
assert_not_grep "T-11 未知 key WARNING は出ない" "$ERR" '一致しない key'

echo "--- T-12: 全件除外は all_resolved で起票せず lookup も叩かない (AC-2) ---"
reset_stubs
r=$(new_root t12)
put_json "$r" "9-20260101120000.json" "$TWO_FINDING_JSON"
run_target "$r" --exclude-ids "9-20260101120000.json#F-01,9-20260101120000.json#F-05"
assert "T-12 exit 0" "0" "$RC"
assert_grep "T-12 all_resolved marker" "$ERR" 'FOLLOW_UP_ISSUE=skipped; reason=all_resolved; pr=9'
assert_grep "T-12 stdout summary も all_resolved" "$OUT" 'result=skipped; reason=all_resolved; pr=9'
assert "T-12 create 0 回" "0" "$(create_count)"
assert "T-12 all_resolved でも判定済み記録を書く" "pr=9" "$(cat "$r/.rite/state/follow-up-judged-9.txt" 2>/dev/null)"
# 除外判定が already_exists lookup より前に立つことの観測条件 (全件除外ケース限定)
assert_not_grep "T-12 既存 follow-up を検索しない" "$GH_LOG" 'labels=follow-up'
assert_not_grep "T-12 台帳取得 (gh api) を叩かない" "$GH_LOG" '^gh api '
assert_not_grep "T-12 no_findings には倒さない" "$ERR" 'reason=no_findings'

echo "--- T-13: 未知 key は WARNING + 既知分だけ除外して起票継続 (AC-3) ---"
reset_stubs
r=$(new_root t13)
put_json "$r" "9-20260101120000.json" "$TWO_FINDING_JSON"
run_target "$r" --exclude-ids "9-20260101120000.json#F-99,9-20260101120000.json#F-05"
assert "T-13 exit 0 (非ブロッキング)" "0" "$RC"
assert_grep "T-13 未知 key WARNING" "$ERR" '一致しない key が含まれます: 9-20260101120000.json#F-99 '
# WARNING の有無だけでは「未知 id で起票を止める実装」も通るため起票継続まで pin する
assert_grep "T-13 起票は継続する" "$ERR" 'FOLLOW_UP_ISSUE=created; issue=99; existing=0; recorded=0; pr=9'
assert "T-13 create 1 回" "1" "$(create_count)"
assert_grep "T-13 既知 key の除外は効く" "$STUB_DIR/body.md" 'F-01'
assert_not_grep "T-13 除外した既知 id は body に無い" "$STUB_DIR/body.md" 'F-05'

echo "--- T-14: --exclude-ids 未指定 / 空文字列は既存挙動と一致 (AC-4) ---"
reset_stubs
r=$(new_root t14a)
put_json "$r" "9-20260101120000.json" "$TWO_FINDING_JSON"
run_target "$r"
assert "T-14 未指定 exit 0" "0" "$RC"
assert_grep "T-14 未指定は created" "$ERR" 'FOLLOW_UP_ISSUE=created; issue=99; existing=0; recorded=0; pr=9'
assert_grep "T-14 未指定は F-01 を転記" "$STUB_DIR/body.md" 'F-01'
assert_grep "T-14 未指定は F-05 も転記" "$STUB_DIR/body.md" 'F-05'
_t14_default_body=$(cat "$STUB_DIR/body.md")

reset_stubs
r=$(new_root t14b)
put_json "$r" "9-20260101120000.json" "$TWO_FINDING_JSON"
run_target "$r" --exclude-ids ""
assert "T-14 空文字列 exit 0 (引数不正にしない)" "0" "$RC"
assert_grep "T-14 空文字列は created" "$ERR" 'FOLLOW_UP_ISSUE=created; issue=99; existing=0; recorded=0; pr=9'
assert "T-14 空文字列の body は未指定と同一" "$_t14_default_body" "$(cat "$STUB_DIR/body.md")"
assert_not_grep "T-14 空文字列は all_resolved に倒さない" "$ERR" 'reason=all_resolved'

reset_stubs
r=$(new_root t14c)
put_json "$r" "9-20260101120000.json" '{"non_blocking_findings":[]}'
run_target "$r" --exclude-ids ""
assert "T-14 除外前 0 件は no_findings のまま" "0" "$RC"
assert_grep "T-14 no_findings を維持" "$ERR" 'reason=no_findings; pr=9'
assert_not_grep "T-14 除外前 0 件を all_resolved にしない" "$ERR" 'reason=all_resolved'

echo "--- T-15: cleanup SKILL.md の再検証契約 (AC-5 / AC-6) ---"
CLEANUP_MD="$SCRIPT_DIR/../../skills/cleanup/SKILL.md"
CLEANUP_RATIONALE="$SCRIPT_DIR/../../skills/cleanup/references/rationale.md"
if [ ! -f "$CLEANUP_MD" ]; then
  fail "T-15 cleanup/SKILL.md が見つからない: $CLEANUP_MD"
else
  # rationale.md の不在は assert_grep の file-not-found 分岐が fail-loud に捕まえる。
  # ここで elif guard を足すと、rationale.md が消えたときに SKILL.md 対象の兄弟 assert まで
  # まるごと skip され、診断粒度が落ちる
  # 判定結果はリテラル置換で helper へ渡す。シェル変数経由は Bash 呼び出し境界で失われるため、
  # `$_fu_exclude_ids` が復活していないことを両方向で pin する。
  assert_grep "T-15 helper へ --exclude-ids をリテラル置換で渡す" "$CLEANUP_MD" 'exclude-ids "\{resolved_ids_csv\}"'
  # 散文は禁止理由として名前に言及するため、pin はコード形 (引数渡し / 既定初期化) に絞る
  assert_not_grep "T-15 シェル変数経由の引数渡しを残さない" "$CLEANUP_MD" 'exclude-ids "\$_fu_exclude_ids"'
  assert_not_grep "T-15 既定初期化行を残さない" "$CLEANUP_MD" '_fu_exclude_ids="\$\{_fu_exclude_ids:-\}"'
  assert_grep "T-15 別 Bash 呼び出しである旨を明記" "$CLEANUP_MD" '別 Bash 呼び出しである'
  assert_grep "T-15 再検証節の見出し" "$CLEANUP_MD" '6\.0\.V helper 呼び出し前の再検証'
  # ERE の bare `|` は alternation となり `^` 単独の枝が全行にマッチする (常に PASS する
  # false positive)。Markdown テーブル行を pin するときは `\|` でエスケープする。
  assert_grep "T-15 3 値 resolved" "$CLEANUP_MD" '^\| `resolved` \|'
  assert_grep "T-15 3 値 remains" "$CLEANUP_MD" '^\| `remains` \|'
  assert_grep "T-15 3 値 undecidable" "$CLEANUP_MD" '^\| `undecidable` \|'
  assert_grep "T-15 undecidable は転記する" "$CLEANUP_MD" '\*\*転記する\*\*（`--exclude-ids` へ渡さない）'
  assert_grep "T-15 判定内訳 marker" "$CLEANUP_MD" 'FOLLOW_UP_REVERIFY=done; resolved='
  assert_grep "T-15 marker に resolved_ids を載せる" "$CLEANUP_MD" 'resolved_ids=\{resolved_ids_csv\}'
  assert_grep "T-15 再検証不能時は除外なしへ倒す" "$CLEANUP_MD" '全件を `undecidable` 扱い'
  # AC-6 (同型: 元 PR のマージコミット自身で修正済み) を resolved に落とす判定材料
  assert_grep "T-15 resolved の機械的判定材料" "$CLEANUP_MD" '既に修正後の形になっている'
  assert_grep "T-15 all_resolved を x 相当に置く" "$CLEANUP_MD" 'skipped; reason=all_resolved` / .*\| x 相当'
  # 抽出は id 書式で絞る (書式外 id がリテラル置換先でコマンド置換として展開されるのを防ぐ)
  assert_grep "T-15 抽出 jq が id 書式で絞る" "$CLEANUP_MD" 'test\("\^F-\[0-9\]\{2,\}\$"\)'
  # 1 finding = 1 行の JSON で出す (TSV は description の改行で行が割れ id 対応が崩れる)
  assert_grep "T-15 抽出は 1 finding = 1 行の JSON" "$CLEANUP_MD" "jq -c '\.\[\]$"
  # 再検証も helper と同じ和集合を見る (最新 1 本だと転記集合と食い違う)
  assert_grep "T-15 再検証は全 JSON の和集合" "$CLEANUP_MD" '全ファイルの `non_blocking_findings\[\]` を和集合'
  assert_not_grep "T-15 id による畳み込みを残さない" "$CLEANUP_MD" 'group_by\(\.id\)'
  # jq リテラルの pin だけでは「その挙動を指示する散文」の drift を検出できない
  assert_not_grep "T-15 畳み込みを指示する散文を残さない" "$CLEANUP_MD" '同一 id は後の JSON'
  assert_grep "T-15 重複 id は独立に判定する旨を書く" "$CLEANUP_MD" '同じ id が複数行\*\*現れることがある'
  # 射影失敗と parse 失敗は別 reason (完了報告へ誤った原因を転記しない)
  assert_grep "T-15 射影失敗を WARNING で surface" "$CLEANUP_MD" '再検証用 JSON の射影に失敗しました'
  assert_grep "T-15 射影失敗は projection_failed" "$CLEANUP_MD" 'reason=projection_failed'
  assert "T-15 parse_failed は全滅経路のみ" "1" \
    "$(grep -c 'FOLLOW_UP_REVERIFY=unavailable; reason=parse_failed' "$CLEANUP_MD" | tr -d ' ')"
  # 6.0.V の統合 jq も stderr を捨てない（helper 側の union ループと同形）。
  # パターンは**単引用符**で書く — 二重引用符だと `\$` がシェル段階で `$` へ潰れ、ERE の
  # 中間アンカーになって決して一致しない（= 空振りする negative pin になる）。
  assert_not_grep "T-15 統合 jq の stderr を捨てない" "$CLEANUP_MD" 'argjson add "\$_part" .\. \+ \$add. "\$_rv_union" 2>/dev/null'
  # read 側の id 述語も末尾改行を排除する（write 側 gate と同一述語を保つ invariant）
  assert "T-15 射影 id 述語は末尾改行も排除する" "1" \
    "$(grep -c 'test("\^F-\[0-9\]{2,}\$") and (contains("\\n") | not)' "$CLEANUP_MD" | tr -d ' ')"
  # ループ本体での原因行 emit。既出 2 箇所に一致するため区間を限って pin する
  # 件数だけでは「ループ外へ移設」を素通しするため、for 〜 done の区間に限って pin する
  assert "T-15 ループ本体で原因行を emit する" "1" \
    "$(awk '/^      for f in "\$\{_rv_srcs\[@\]\}"/,/^      done$/' "$CLEANUP_MD" | grep -c 'head -5 "\$_rv_errf"' | tr -d ' ')"
  # 区間 pin は「位置」を守るが「本数」は守らない（区間外 2 箇所の削除を素通しする）ので併置する
  assert "T-15 原因行 emit は全体で 3 箇所" "3" \
    "$(grep -c 'head -5 "\$_rv_errf"' "$CLEANUP_MD" | tr -d ' ')"
  # 追記オープンにすると過去周の残骸が混ざり、毎周トランケート前提の emit 位置が意味を失う
  assert_not_grep "T-15 errf を追記で開かない" "$CLEANUP_MD" '2>>"\$\{_rv_errf'
  # 無効な明示トランケートを残さない（2> が毎周 O_TRUNC で開くため冗長）
  assert_not_grep "T-15 冗長な明示トランケートを残さない" "$CLEANUP_MD" '\[ -n "\$_rv_errf" \] && : > "\$_rv_errf"'
  # 曖昧 key marker に完了報告側の消費規則がある
  assert_grep "T-15 曖昧 key marker の消費規則がある" "$CLEANUP_MD" 'FOLLOW_UP_EXCLUDE_AMBIGUOUS=1; reason=\{r\}; count=\{n\}; pr=\{pr_number\}'
  # 除外を全破棄した経路は「曖昧 key」「他の key は適用済み」を主張しない別文面へ分岐させる
  assert_grep "T-15 note は reason で文面を分岐する" "$CLEANUP_MD" 'それ以外の `reason` のとき'
  _note_section="$TMP_ROOT/ambiguous-note.md"
  awk '/^- `\{follow_up_ambiguous_note\}`:/ {p=1} p && /^- `\{wiki_ingest_check\}`:/ {exit} p' "$CLEANUP_MD" > "$_note_section"
  assert_grep "T-15 最終起票結果を先に選ぶ" "$_note_section" '先に.*最終 `FOLLOW_UP_ISSUE` を選ぶ'
  assert_grep "T-15 除外拒否は同一PRの最後の通知を採る" "$_note_section" '行末まで一致する最後の出現を採る'
  assert_grep "T-15 created の場合だけ転記完了と表現する" "$_note_section" '最終 `FOLLOW_UP_ISSUE=created` の場合だけ.*「転記対象としました」を「転記しました」に置換'
  assert_grep "T-15 失敗や既存Issueでは転記済みにしない" "$_note_section" '失敗・未確認・`already_exists` を含むその他の結果では置換しない'
  assert_grep "T-15 未通知から成功を推定しない" "$_note_section" '除外適用・起票の成功は推定しない'
  assert_grep "T-15 起票と削除の完了判定を維持する" "$_note_section" '起票結果と state 削除結果から決めた `\{review_cleanup_check\}` を変更しない'
  assert_not_grep "T-15 除外拒否だけで成功を断定しない" "$_note_section" '起票自体は成功|`x` 相当'
  # placeholder の presence だけだと定義側 bullet で充足し、完了報告への配線を消す変異を素通しする
  assert_grep "T-15 完了報告に曖昧 note を差し込む" "$CLEANUP_MD" '\{follow_up_reverify_note\}\{follow_up_ambiguous_note\}'
  # note のリテラルは 1 本の code span に保つ（分断すると出力すべき文字列が不定になる）
  assert_not_grep "T-15 note リテラルに別 placeholder 名を埋めない" "$CLEANUP_MD" '曖昧 key \{count\}.*`\{follow_up_reverify_note\}`'
  assert_grep "T-15 曖昧 note は key 単位で数える" "$CLEANUP_MD" '曖昧 key \{count\} 件の指摘を除外せず転記対象としました'
  assert_grep "T-15 和集合は連結のみ" "$CLEANUP_MD" 'argjson add "\$_part" .\. \+ \$add.'
  assert_grep "T-15 最終射影の rc を検査する" "$CLEANUP_MD" 'if _rv_out=\$\(jq -c'
  assert_not_grep "T-15 最新 1 本を選ぶループを残さない" "$CLEANUP_MD" '_rv_src="\$f"; _rv_base="\$b"'
  # reason 語彙を helper に揃える (合成 reason は誤った原因を完了報告へ転記する)
  assert_grep "T-15 reason=state_root_unresolved" "$CLEANUP_MD" 'reason=state_root_unresolved'
  assert_grep "T-15 reason=jq_missing" "$CLEANUP_MD" 'FOLLOW_UP_REVERIFY=unavailable; reason=jq_missing'
  assert_grep "T-15 reason=no_json" "$CLEANUP_MD" 'FOLLOW_UP_REVERIFY=unavailable; reason=no_json"'
  # 合成 reason の emit を残さない (散文は禁止理由として語に言及するため emit 形で pin)
  assert_not_grep "T-15 合成 reason を emit しない" "$CLEANUP_MD" 'reason=no_json_or_jq'
  # state root 解決失敗を無言にしない。文言の後半まで pin する — 接頭辞だけだと隣接ブロックの
  # 同一文字列に一致するうえ、旧文言 (cwd をフォールバック使用します) へ revert しても通る
  assert_grep "T-15 state root 解決失敗を WARNING で surface" "$CLEANUP_MD" \
    'state-path-resolve.sh の解決に失敗。follow-up 再検証は行わず全件を転記対象とします'
  # 書式外 id は落とさず null へ写す (落とすと件数を数える第 2 の述語が要り drift 経路になる)
  assert_grep "T-15 書式外 id を null へ写す" "$CLEANUP_MD" 'then \.id else null end'
  # 極性まで pin する (キーだけだと「必ず resolved」への反転が通る)
  assert_grep "T-15 key null は undecidable 固定" "$CLEANUP_MD" '`"key": null` の finding.*\*\*必ず `undecidable`\*\*'
  # 除外 key は出典 JSON の basename と id の組。和集合の各要素へ basename を付け、射影で連結する
  assert_grep "T-15 和集合の要素へ出典 basename を付ける" "$CLEANUP_MD" 'jq -c --arg src "\$\{f##\*/\}" .*\{_src: \$src\}'
  assert_grep "T-15 射影が basename と id から key を作る" "$CLEANUP_MD" 'key: \(if \$fid and \(\(\._src // ""\) \| test\("\^\[0-9\]\+-\[0-9\]\{14\}\(~\[0-9a-f\]\{4\}\)\?\\\\\.json\$"\)\) then \._src \+ "#" \+ \.id else null end\)'
  assert_grep "T-15 key トークンだけを resolved_ids_csv に置く" "$CLEANUP_MD" '`\{resolved_ids_csv\}` に置けるのは出力の `key` の値'
  assert_grep "T-15 resolved の key を CSV に組む" "$CLEANUP_MD" '`resolved` の `key` を CSV'
  assert_not_grep "T-15 id だけの CSV を組ませない" "$CLEANUP_MD" '`resolved` の id を CSV'
  # helper の受理形と 6.0.V の射影が同じ basename 形を使う (片方だけ広げると key が一致しなくなる)
  _basename_re='test("^[0-9]+-[0-9]{14}(~[0-9a-f]{4})?\\.json'
  assert "T-15 射影の basename 形" "1" "$(grep -cF "$_basename_re" "$CLEANUP_MD" | tr -d ' ')"
  # helper は除外 key の受理形と、却下台帳の出典列の受理形の 2 か所で同じ basename 形を使う
  assert "T-15 helper の受理形も同じ basename 形" "2" "$(grep -cF "$_basename_re" "$TARGET" | tr -d ' ')"
  assert_not_grep "T-15 件数カウント機構を残さない" "$CLEANUP_MD" 'dropped_id_format'
  # 抽出成功時は marker を出さない。判定後の done が唯一の成功 marker (0 件時に抽出 marker が
  # 最後に残ると判定表が「未完了」と誤報告し、done の前置詞として前方一致でも衝突する)
  assert_not_grep "T-15 抽出成功 marker を残さない" "$CLEANUP_MD" 'FOLLOW_UP_REVERIFY=done_extract'
  assert_grep "T-15 0 件でも done を必ず出す" "$CLEANUP_MD" '抽出結果が 0 件でもこの marker を必ず出す'
  assert_grep "T-15 unavailable 経路では done を出さない" "$CLEANUP_MD" '既に `unavailable` を出した経路では `done` を出さない'
  # 判定表の 3 行を pin する (emit 側の pin だけでは表から行を削る変異が生存する)
  # 件数内訳まで pin する (「解消済み」で切ると内訳を削る変異が生存する)
  assert_grep "T-15 判定表の done 行" "$CLEANUP_MD" '`done` のとき: .*follow-up 再検証: 解消済み \{n_resolved\} / 残存 \{n_remains\} / 判定不能 \{n_undecidable\}'
  # 廃止 marker の設計理由は rationale へ退避し 1 行ポインタを張る
  assert_grep "T-15 抽出 marker 廃止の rationale ポインタ" "$CLEANUP_MD" 'rationale: references/rationale.md#reverify-no-extract-marker'
  assert_grep "T-15 rationale 節が実在する" "$CLEANUP_RATIONALE" '^## reverify-no-extract-marker$'
  assert_grep "T-15 判定表の unavailable 行" "$CLEANUP_MD" '`unavailable` のとき: .*follow-up 再検証: 未実施'
  # marker 不在は成功と読まない (兄弟分岐と同じ fail-loud 規約。空文字列に戻す変異を検出する)
  assert_grep "T-15 marker 不在も付記する" "$CLEANUP_MD" 'marker が無いとき: .*実施結果を確認できませんでした'
  assert_grep "T-15 marker 不在を成功と読まない" "$CLEANUP_MD" '\*\*marker 不在を成功と読んではならない\*\*'
  # 新設 stderr 経路の regression proof。捕捉先と surface の両側を pin する
  # (surface 側だけだと、捕捉先を /dev/null へ切る変異が生存して本文が永久に出なくなる)
  assert_grep "T-15 jq の stderr を _rv_errf へ捕捉する" "$CLEANUP_MD" '2>"\$\{_rv_errf:-/dev/null\}"'
  assert_grep "T-15 parse_failed で jq の stderr 本文を surface" "$CLEANUP_MD" 'head -5 "\$_rv_errf"'
  assert_grep "T-15 mktemp 失敗を surface" "$CLEANUP_MD" '一時ファイルを確保できません'
  # rc を汚さない形 (`&&` 単独文だと mktemp 失敗時にブロック全体が rc=1 で終わる)
  assert_grep "T-15 cleanup は if 形で rc を汚さない" "$CLEANUP_MD" 'if \[ -n "\$_rv_errf" \]; then rm -f "\$_rv_errf"; fi'
  # `\s` は GNU 拡張で BSD の ERE では未定義に落ち negative assert が fail-open する
  assert_not_grep "T-15 rm を && 単独文にしない" "$CLEANUP_MD" '^[[:space:]]*\[ -n "\$_rv_errf" \] && rm -f'
  # 0 件時に空行を出さない (空行が finding として読まれる余地を残さない)
  assert_grep "T-15 非空時だけ出力する" "$CLEANUP_MD" 'if \[ -n "\$_rv_out" \]; then printf'
  # 射影フィルタは 1 パス。grep -c は行数しか数えないため出現回数で数える
  assert "T-15 射影フィルタは 1 パス" "1" \
    "$(grep -o 'file, line, description, suggestion}' "$CLEANUP_MD" | wc -l | tr -d ' ')"
  # id 書式 regex も 1 箇所 (射影用と否定形で分裂すると片方だけ広げた時に乖離する)
  assert "T-15 id 書式 regex は 1 箇所" "1" \
    "$(grep -o 'test("\^F-\[0-9\]{2,}\$")' "$CLEANUP_MD" | wc -l | tr -d ' ')"
fi

echo "--- T-16: 改行入り --exclude-ids でも未知 key WARNING が消えない (AC-3) ---"
reset_stubs
r=$(new_root t16)
put_json "$r" "9-20260101120000.json" "$TWO_FINDING_JSON"
# jq -R は行単位処理のため、改行入りは JSON 配列が複数連結された文字列になる。
# 非空判定だけを通すと後段の --argjson が rc=2 で落ち、AC-3 の WARNING が無言で消える。
run_target "$r" --exclude-ids "$(printf '9-20260101120000.json#F-99\n9-20260101120000.json#F-05')"
assert "T-16 exit 0" "0" "$RC"
# 改行も区切りとして畳むため AC-3 の未知 key WARNING がそのまま成立する
assert_grep "T-16 未知 key WARNING が消えない" "$ERR" '一致しない key が含まれます: 9-20260101120000.json#F-99 '
assert_grep "T-16 起票は継続する" "$ERR" 'FOLLOW_UP_ISSUE=created; issue=99; existing=0; recorded=0; pr=9'
# 既知 key の除外も効く (無言の全件転記にならない)
assert_grep "T-16 残存 id を転記" "$STUB_DIR/body.md" 'F-01'
assert_not_grep "T-16 除外した既知 id は body に無い" "$STUB_DIR/body.md" 'F-05'

echo "--- T-17: 2 本の JSON の指摘が和集合で body に載る (AC-1 / T-01) ---"
reset_stubs
r=$(new_root t17)
put_json "$r" "9-20260101120000.json" '{"non_blocking_findings":[{"id":"F-05","reviewer":"a","severity":"LOW","file":"a.md","line":1,"description":"先行 cycle の指摘","suggestion":"先行の提案"},{"id":"F-09","reviewer":"a","severity":"LOW","file":"a.md","line":2,"description":"先行 cycle の指摘 2","suggestion":"先行の提案 2"}]}'
put_json "$r" "9-20260102120000.json" '{"non_blocking_findings":[{"id":"F-11","reviewer":"b","severity":"LOW","file":"b.md","line":3,"description":"後続 cycle の指摘","suggestion":"後続の提案"}]}'
run_target "$r"
assert "T-17 exit 0" "0" "$RC"
assert_grep "T-17 created" "$ERR" 'FOLLOW_UP_ISSUE=created; issue=99; existing=0; recorded=0; pr=9'
assert_grep "T-17 F-05 が載る" "$STUB_DIR/body.md" '先行 cycle の指摘'
assert_grep "T-17 F-09 が載る" "$STUB_DIR/body.md" '先行 cycle の指摘 2'
assert_grep "T-17 F-11 が載る" "$STUB_DIR/body.md" '後続 cycle の指摘'
# SHOULD: どの範囲から転記したかを 1 行で出す
assert_grep "T-17 和集合の本数を stderr へ出す" "$ERR" 'union: pr=9; json_total=2; json_parsed=2; json_unparsed=0'

echo "--- T-18: 同一 id でも別 cycle の指摘は畳まず全件載る (AC-2) ---"
# `id` は各 JSON 内の連番であり cycle を跨いだ identity を持たない (cycle 跨ぎの identity は
# cycle 間の同一性判断は semantic 判断が担い、本配列に機械的 identity キーは無い)。
# 同じ `F-05` が cycle ごとに別の指摘を指すため、
# id で畳むと別々の指摘が黙って消える。よって両方が body に載るのが正しい。
reset_stubs
r=$(new_root t18)
put_json "$r" "9-20260101120000.json" '{"non_blocking_findings":[{"id":"F-05","reviewer":"a","severity":"LOW","file":"a.md","line":1,"description":"古い cycle の本文","suggestion":"古い提案"}]}'
put_json "$r" "9-20260102120000.json" '{"non_blocking_findings":[{"id":"F-05","reviewer":"b","severity":"LOW","file":"b.md","line":7,"description":"新しい cycle の本文","suggestion":"新しい提案"}]}'
run_target "$r"
assert "T-18 exit 0" "0" "$RC"
assert "T-18 F-05 の見出しは 2 回出る (別々の指摘)" "2" \
  "$(grep -c '^### F-05 ' "$STUB_DIR/body.md" | tr -d ' ')"
assert_grep "T-18 後の JSON の本文が載る" "$STUB_DIR/body.md" '新しい cycle の本文'
assert_grep "T-18 先行 JSON の本文も落とさない" "$STUB_DIR/body.md" '古い cycle の本文'

echo "--- T-19: --exclude-ids は和集合後に適用される (AC-3) ---"
reset_stubs
r=$(new_root t19)
put_json "$r" "9-20260101120000.json" '{"non_blocking_findings":[{"id":"F-01","reviewer":"a","severity":"LOW","file":"a.md","line":1,"description":"残す指摘 1","suggestion":"s1"},{"id":"F-02","reviewer":"a","severity":"LOW","file":"a.md","line":2,"description":"消す指摘 2","suggestion":"s2"}]}'
put_json "$r" "9-20260102120000.json" '{"non_blocking_findings":[{"id":"F-03","reviewer":"b","severity":"LOW","file":"b.md","line":3,"description":"残す指摘 3","suggestion":"s3"},{"id":"F-04","reviewer":"b","severity":"LOW","file":"b.md","line":4,"description":"消す指摘 4","suggestion":"s4"},{"id":"F-05","reviewer":"b","severity":"LOW","file":"b.md","line":5,"description":"残す指摘 5","suggestion":"s5"}]}'
run_target "$r" --exclude-ids "9-20260101120000.json#F-02,9-20260102120000.json#F-04"
assert "T-19 exit 0" "0" "$RC"
assert_grep "T-19 created" "$ERR" 'FOLLOW_UP_ISSUE=created; issue=99; existing=0; recorded=0; pr=9'
assert_grep "T-19 F-01 が残る" "$STUB_DIR/body.md" '残す指摘 1'
assert_grep "T-19 F-03 が残る" "$STUB_DIR/body.md" '残す指摘 3'
assert_grep "T-19 F-05 が残る" "$STUB_DIR/body.md" '残す指摘 5'
assert_not_grep "T-19 F-02 は落ちる" "$STUB_DIR/body.md" '消す指摘 2'
assert_not_grep "T-19 F-04 は落ちる" "$STUB_DIR/body.md" '消す指摘 4'

echo "--- T-20: 和集合の全件除外は all_resolved (AC-4) ---"
reset_stubs
r=$(new_root t20)
put_json "$r" "9-20260101120000.json" '{"non_blocking_findings":[{"id":"F-01","reviewer":"a","severity":"LOW","file":"a.md","line":1,"description":"d1","suggestion":"s1"}]}'
put_json "$r" "9-20260102120000.json" '{"non_blocking_findings":[{"id":"F-02","reviewer":"b","severity":"LOW","file":"b.md","line":2,"description":"d2","suggestion":"s2"},{"id":"F-03","reviewer":"b","severity":"LOW","file":"b.md","line":3,"description":"d3","suggestion":"s3"}]}'
run_target "$r" --exclude-ids "9-20260101120000.json#F-01,9-20260102120000.json#F-02,9-20260102120000.json#F-03"
assert "T-20 exit 0" "0" "$RC"
assert_grep "T-20 all_resolved" "$ERR" 'FOLLOW_UP_ISSUE=skipped; reason=all_resolved; pr=9'
assert "T-20 create 0 回" "0" "$(create_count)"

echo "--- T-21: 全 JSON が 0 件なら no_findings (AC-7 非回帰) ---"
reset_stubs
r=$(new_root t21)
put_json "$r" "9-20260101120000.json" '{"non_blocking_findings":[]}'
put_json "$r" "9-20260102120000.json" '{"non_blocking_findings":[]}'
run_target "$r"
assert "T-21 exit 0" "0" "$RC"
assert_grep "T-21 no_findings" "$ERR" 'FOLLOW_UP_ISSUE=skipped; reason=no_findings; pr=9'
assert "T-21 create 0 回" "0" "$(create_count)"

echo "--- T-22: id 欠落 / 書式外 id の finding を落とさない ---"
reset_stubs
r=$(new_root t22)
put_json "$r" "9-20260101120000.json" '{"non_blocking_findings":[{"reviewer":"a","severity":"LOW","file":"a.md","line":1,"description":"id 無しの指摘 A","suggestion":"sA"},{"reviewer":"a","severity":"LOW","file":"a.md","line":2,"description":"id 無しの指摘 B","suggestion":"sB"}]}'
put_json "$r" "9-20260102120000.json" '{"non_blocking_findings":[{"id":"H-01","reviewer":"b","severity":"LOW","file":"b.md","line":3,"description":"書式外 id の指摘","suggestion":"sC"}]}'
run_target "$r"
assert "T-22 exit 0" "0" "$RC"
assert_grep "T-22 id 無し A が残る" "$STUB_DIR/body.md" 'id 無しの指摘 A'
assert_grep "T-22 id 無し B が残る" "$STUB_DIR/body.md" 'id 無しの指摘 B'
assert_grep "T-22 書式外 id が残る" "$STUB_DIR/body.md" '書式外 id の指摘'

echo "--- T-23: parse 不能な JSON を 1 本だけ除外し、jq の原因行を surface する ---"
# 本 test が突くのは兄弟の parse 失敗分岐で、T-03u との差分は「jq の原因行 emit」と「union 内訳」。
reset_stubs
r=$(new_root t23)
put_json "$r" "9-20260101120000.json" '{"non_blocking_findings":[{"id":"F-01","reviewer":"a","severity":"LOW","file":"a.md","line":1,"description":"健全な指摘","suggestion":"s1"}]}'
put_json "$r" "9-20260102120000.json" '{ this is not json'
run_target "$r"
assert "T-23 exit 0" "0" "$RC"
assert_grep "T-23 created" "$ERR" 'FOLLOW_UP_ISSUE=created; issue=99; existing=0; recorded=0; pr=9'
assert_grep "T-23 健全な側は載る" "$STUB_DIR/body.md" '健全な指摘'
assert_grep "T-23 除外を WARNING で surface" "$ERR" '和集合から除外します'
# 原因行が無いと「どの JSON がなぜ落ちたか」が消える (WARNING 本文だけでは退行を検出できない)
assert_grep "T-23 jq の原因行を surface" "$ERR" 'jq: parse error'
assert_grep "T-23 除外本数を stderr の内訳に出す" "$ERR" 'union: pr=9; json_total=2; json_parsed=1; json_unparsed=1'
assert_grep "T-23 欠落確認を WARNING で促す" "$ERR" 'WARNING: 和集合から除外された JSON が 1 本あります'

echo "--- T-23b: 空 JSON の統合失敗でも健全側を転記する ---"
reset_stubs
r=$(new_root t23b)
put_json "$r" "9-20260101120000.json" ''
put_json "$r" "9-20260102120000.json" "$FINDING_JSON"
run_target "$r"
assert "T-23b exit 0" "0" "$RC"
assert_grep "T-23b 統合失敗の WARNING" "$ERR" '和集合の統合に失敗したため当該 JSON を除外します'
assert_grep "T-23b 統合失敗の原因行" "$ERR" 'invalid JSON text passed to --argjson'
assert_grep "T-23b 除外本数" "$ERR" 'union: pr=9; json_total=2; json_parsed=1; json_unparsed=1'
assert_grep "T-23b 健全側で created" "$ERR" 'FOLLOW_UP_ISSUE=created; issue=99; existing=0; recorded=0; pr=9'
assert_grep "T-23b 健全 finding が本文に残る" "$STUB_DIR/body.md" '実測なしの指摘本文'

echo "--- T-24: 同一 JSON 内で重複する id の key は除外しない (曖昧 key の silent drop 防止) ---"
# 同じ JSON に同じ `F-05` が別内容で 2 件載ると、key (出典 basename + id) も同じになる。6.0.V が
# 片方だけを resolved と判定してその key を渡すと、key 一致で両方が落ちて残存している側が黙って
# 消える。曖昧な key は除外せず過剰転記側へ倒す。別 JSON の同じ id は key が違うので巻き込まない。
reset_stubs
r=$(new_root t24)
put_json "$r" "9-20260101120000.json" '{"non_blocking_findings":[{"id":"F-05","reviewer":"a","severity":"LOW","file":"a.md","line":1,"description":"重複した F-05 の片方","suggestion":"s1"},{"id":"F-06","reviewer":"a","severity":"LOW","file":"a.md","line":2,"description":"消える F-06","suggestion":"s2"},{"id":"F-05","reviewer":"a","severity":"LOW","file":"a.md","line":4,"description":"重複した F-05 のもう片方","suggestion":"s4"}]}'
put_json "$r" "9-20260102120000.json" '{"non_blocking_findings":[{"id":"F-05","reviewer":"b","severity":"LOW","file":"b.md","line":3,"description":"cycle2 の F-05","suggestion":"s3"}]}'
run_target "$r" --exclude-ids "9-20260101120000.json#F-05,9-20260101120000.json#F-06"
assert "T-24 exit 0" "0" "$RC"
assert_grep "T-24 created (all_resolved に倒れない)" "$ERR" 'FOLLOW_UP_ISSUE=created; issue=99; existing=0; recorded=0; pr=9'
assert_grep "T-24 重複 key の片方が残る" "$STUB_DIR/body.md" '重複した F-05 の片方'
assert_grep "T-24 重複 key のもう片方も残る" "$STUB_DIR/body.md" '重複した F-05 のもう片方'
assert_grep "T-24 別 JSON の同じ id は指定外なので残る" "$STUB_DIR/body.md" 'cycle2 の F-05'
assert_grep "T-24 曖昧 key を WARNING で surface" "$ERR" '和集合内で複数の finding に一致するため除外しません: 9-20260101120000.json#F-05 \(2 件\)'
assert_not_grep "T-24 一意な F-06 は従来どおり除外される" "$STUB_DIR/body.md" '消える F-06'
assert_grep "T-24 過剰転記を marker で surface" "$ERR" 'FOLLOW_UP_EXCLUDE_AMBIGUOUS=1; reason=ambiguous; count=1; pr=9'

echo "--- T-24c: 形の検証に落ちた --exclude-ids の素値は neutralize_ctrl を通してから WARNING に載せる ---"
# 除外指定は外部から来る値。生の ESC が stderr へ素通りすると端末表示を欺瞞できる。
reset_stubs
r=$(new_root t24c)
_esc=$(printf '\033')
put_json "$r" "9-20260101120000.json" "$TWO_FINDING_JSON"
run_target "$r" --exclude-ids "9-20260101120000.json#F-05${_esc}[31m"
assert "T-24c exit 0" "0" "$RC"
assert "T-24c stderr に生 ESC を残さない" "0" \
  "$(LC_ALL=C grep -c "$_esc" "$ERR" | tr -d ' ')"
assert_grep "T-24c 中和後の値を WARNING に載せる" "$ERR" "解析できませんでした \\('9-20260101120000.json#F-05\\?\\[31m'\\)"
assert_grep "T-24c 除外を全破棄した marker" "$ERR" 'FOLLOW_UP_EXCLUDE_AMBIGUOUS=1; reason=parse_failed; count=unknown; pr=9'
assert_grep "T-24c 除外は適用されない" "$STUB_DIR/body.md" '解消済みの指摘の本文'

echo "--- T-24b: 重複 key があっても --exclude-ids が指していなければ曖昧扱いしない ---"
# 曖昧判定の絞り込み (`$ex` に含まれる key だけを曖昧とする) を削る変異を捕まえる。
reset_stubs
r=$(new_root t24b)
put_json "$r" "9-20260101120000.json" '{"non_blocking_findings":[{"id":"F-05","reviewer":"a","severity":"LOW","file":"a.md","line":1,"description":"重複した F-05 の片方","suggestion":"s1"},{"id":"F-01","reviewer":"a","severity":"LOW","file":"a.md","line":2,"description":"消える F-01","suggestion":"s2"},{"id":"F-05","reviewer":"a","severity":"LOW","file":"a.md","line":3,"description":"重複した F-05 のもう片方","suggestion":"s3"}]}'
run_target "$r" --exclude-ids "9-20260101120000.json#F-01"
assert "T-24b exit 0" "0" "$RC"
assert_not_grep "T-24b 無関係な key で曖昧 WARNING を出さない" "$ERR" '和集合内で複数の finding に一致するため除外しません'
assert_not_grep "T-24b 曖昧 marker を出さない" "$ERR" 'FOLLOW_UP_EXCLUDE_AMBIGUOUS'
assert_not_grep "T-24b F-01 は除外される" "$STUB_DIR/body.md" '消える F-01'
assert_grep "T-24b 重複 key は両方残る (片方)" "$STUB_DIR/body.md" '重複した F-05 の片方'
assert_grep "T-24b 重複 key は両方残る (もう片方)" "$STUB_DIR/body.md" '重複した F-05 のもう片方'

echo "--- T-25: 曖昧判定の失敗ハンドラは安全側へ倒し marker も出す ---"
# 曖昧判定 jq の入力はレビュアーが書く外部 JSON の和集合なので、非 object 要素を 1 つ置けば
# `.id` 索引が落ちて当該ハンドラへ到達する（save 側の id 書式 gate が正規経路では弾く形）。
reset_stubs
r=$(new_root t25)
put_json "$r" "9-20260101120000.json" '{"non_blocking_findings":["plain-string-finding"]}'
put_json "$r" "9-20260102120000.json" '{"non_blocking_findings":[{"id":"F-01","reviewer":"a","severity":"LOW","file":"a.md","line":1,"description":"残るはずの指摘","suggestion":"s1"}]}'
run_target "$r" --exclude-ids "9-20260102120000.json#F-01"
assert "T-25 exit 0" "0" "$RC"
assert_grep "T-25 判定失敗を WARNING で surface" "$ERR" '曖昧 key の判定に失敗しました'
assert_grep "T-25 判定失敗でも marker を出す" "$ERR" 'FOLLOW_UP_EXCLUDE_AMBIGUOUS=1; reason=undecidable; count=1; pr=9'
# 非 object 要素は下流の本文生成 jq も落とすため起票までは至らない（fail-loud で終端する）。
# ここで確かめるのは「除外を適用しないまま先へ進んだ」ことと、それが marker で見えることの 2 点。
assert_grep "T-25 除外は適用されず fail-loud で終端する" "$ERR" 'FOLLOW_UP_ISSUE=failed'
assert_not_grep "T-25 除外適用の成功を主張しない" "$ERR" 'FOLLOW_UP_ISSUE=skipped; reason=all_resolved'
# 向きが戻る変異（exclude_json を捨てない）を捕まえるソース pin も併置する
assert_grep "T-25 判定失敗は除外なしへ倒す" "$TARGET" "ambiguous_json=\"\[\]\"; exclude_json='\[\]'"
assert_not_grep "T-25 除外をそのまま適用する文言を残さない" "$TARGET" '除外をそのまま適用します'

echo "--- T-26: object でない指摘が混ざり候補を作れなければ起票しない ---"
reset_stubs
r=$(new_root t26)
put_json "$r" "9-20260101120000.json" '{"non_blocking_findings":[{"id":"F-01","description":"先行する正常指摘"},"plain-string-finding"]}'
put_json "$r" "9-20260102120000.json" '{"non_blocking_findings":[{"id":"F-02","description":"後続する正常指摘"}]}'
run_target "$r"
assert "T-26 exit 0" "0" "$RC"
assert "T-26 部分本文を起票しない" "0" "$(create_count)"
assert_grep "T-26 候補を作れない WARNING" "$ERR" '候補の一覧を作れません'
assert_grep "T-26 失敗 marker" "$ERR" 'FOLLOW_UP_ISSUE=failed; reason=json_undecidable; pr=9'
assert_not_grep "T-26 起票成功を主張しない" "$ERR" 'FOLLOW_UP_ISSUE=created'
assert_grep "T-26 sweep 起票済みの除外も適用失敗を surface" "$ERR" 'FOLLOW_UP_SWEEP_ISSUED=unavailable; reason=apply_failed; pr=9'

echo "--- T-25b: 除外処理の失敗後も全 finding を保持する ---"
for stage in parse ambiguity release apply; do
  reset_stubs
  r=$(new_root "t25b-$stage")
  put_json "$r" "9-20260101120000.json" '{"non_blocking_findings":[{"id":"F-05","description":"曖昧な指摘A"},{"id":"F-06","description":"一意な指摘"},{"id":"F-05","description":"曖昧な指摘B"}]}'
  export RITE_TEST_JQ_FAIL="$stage"
  run_target "$r" --exclude-ids '9-20260101120000.json#F-05,9-20260101120000.json#F-06'
  assert "T-25b $stage 対象 jq が1回失敗" "$stage" "$(cat "$STUB_DIR/jq-fail.log")"
  assert "T-25b $stage exit 0" "0" "$RC"
  case "$stage" in
    parse) reason=parse_failed; count=unknown; warning='--exclude-ids を解析できませんでした' ;;
    ambiguity) reason=undecidable; count=2; warning='曖昧 key の判定に失敗しました' ;;
    release) reason=undecidable; count=2; warning='曖昧 key の除外解除に失敗しました' ;;
    apply) reason=apply_failed; count=1; warning='除外適用に失敗しました' ;;
  esac
  assert_grep "T-25b $stage WARNING" "$ERR" "WARNING: $warning"
  marker="[CONTEXT] FOLLOW_UP_EXCLUDE_AMBIGUOUS=1; reason=$reason; count=$count; pr=9"
  actual_markers=$(grep '^\[CONTEXT\] FOLLOW_UP_EXCLUDE_AMBIGUOUS=' "$ERR")
  expected_markers="$marker"
  case "$stage" in
    release|apply) expected_markers=$(printf '%s\n%s' '[CONTEXT] FOLLOW_UP_EXCLUDE_AMBIGUOUS=1; reason=ambiguous; count=1; pr=9' "$marker") ;;
  esac
  assert "T-25b $stage marker の順序・件数" "$expected_markers" "$actual_markers"
  assert "T-25b $stage 起票1回" "1" "$(create_count)"
  assert_grep "T-25b $stage created" "$ERR" 'FOLLOW_UP_ISSUE=created; issue=99; existing=0; recorded=0; pr=9'
  for description in 曖昧な指摘A 曖昧な指摘B 一意な指摘; do
    assert_grep "T-25b $stage $description を保持" "$STUB_DIR/body.md" "$description"
  done
done

echo "--- T-27: 除外拒否後も検索・起票結果で成否を確定する ---"
for stage in lookup create; do
  reset_stubs
  r=$(new_root "t27-$stage")
  put_json "$r" "9-20260101120000.json" '{"non_blocking_findings":[{"id":"F-05","description":"指摘A"},{"id":"F-05","description":"指摘B"}]}'
  if [ "$stage" = lookup ]; then export GH_LIST_RC=1; expected_creates=0; else export CREATE_RC=1; expected_creates=1; fi
  run_target "$r" --exclude-ids 9-20260101120000.json#F-05
  assert "T-27 $stage exit 0" "0" "$RC"
  assert "T-27 $stage 起票試行数" "$expected_creates" "$(create_count)"
  assert "T-27 $stage 除外拒否の後に失敗通知" \
    "$(printf '%s\n%s' '[CONTEXT] FOLLOW_UP_EXCLUDE_AMBIGUOUS=1; reason=ambiguous; count=1; pr=9' "[CONTEXT] FOLLOW_UP_ISSUE=failed; reason=${stage}_api; pr=9")" \
    "$(grep '^\[CONTEXT\] FOLLOW_UP_' "$ERR")"
  assert_not_grep "T-27 $stage 成功通知なし" "$ERR" 'FOLLOW_UP_ISSUE=created'
  assert_not_grep "T-27 $stage 想定外の gh 呼び出しなし" "$ERR" 'unexpected gh'
  if [ "$stage" = lookup ]; then
    assert_grep "T-27 lookup 検索 API の失敗経路を通る" "$ERR" 'simulated list failure'
  fi
done

echo "--- T-28: 再検証用一時ファイルの確保失敗を明示する ---"
reset_stubs
r=$(new_root t28)
put_json "$r" "9-20260101120000.json" "$FINDING_JSON"
# SKILL の 6.0.V 実ブロックを実行する。state root だけ fixture に置換する。
# ステップ 3 と 6.0 helper 呼び出しも `_state_root=$(bash` で始まるため先頭一致では
# 6.0.V を取れない。SKILL.md の T-28 アンカーコメントを起点にする。
awk -v root="$r" -v plugin="$PLUGIN_ROOT" '
  /cleanup-follow-up-issue.test.sh T-28/ {p=1}
  p && /^_state_root=\$\(bash / {print "_state_root=\"" root "\""; next}
  p && /^```/ {exit}
  p {gsub(/\{pr_number\}/, "9"); gsub(/\{plugin_root\}/, plugin); print}
' "$CLEANUP_MD" > "$TMP_ROOT/reverify.sh"
if ! grep -q 'rite-fu-reverify-union' "$TMP_ROOT/reverify.sh"; then
  fail "T-28 6.0.V 再検証ブロックを抽出できない"
else
  assert_not_grep "T-28 ステップ3ブロックを抽出しない" "$TMP_ROOT/reverify.sh" 'WM_SOURCE='
  TMPDIR="$TMP_ROOT/absent" bash "$TMP_ROOT/reverify.sh" > "$OUT" 2> "$ERR"; RC=$?
  assert "T-28 exit 0" "0" "$RC"
  assert_grep "T-28 union 一時ファイル失敗の WARNING" "$ERR" '再検証用の一時ファイルを確保・初期化できません'
  assert_grep "T-28 再検証不能を surface" "$ERR" '再検証を実施できません（対象 1 本）'
  assert_grep "T-28 unavailable marker" "$OUT" 'FOLLOW_UP_REVERIFY=unavailable; reason=parse_failed'
  assert_not_grep "T-28 JSON 破損と断定しない" "$ERR" '1 本も解析できません'
fi

# $1=本文。関連 Issue 記録コメント 1 件分の JSON object を出す
# $1=本文 $2=comment id (省略時 1) $3=author (省略時 rite-bot)。記録 helper は author と id で 1 件に決める
comment_obj() { jq -n --arg b "$1" --argjson id "${2:-1}" --arg login "${3:-rite-bot}" '{id: $id, user: {login: $login}, body: $b}'; }
# $1=台帳行 (改行区切り)。見出し + 却下台帳 + 最終行 sentinel を持つ記録コメント本文
record_body() {
  printf '%s\n' '## 📜 rite 非実測指摘の記録 (non-blocking)' '' '本 cycle の非実測指摘: 2 件' '' \
    '### 却下台帳' '' '| finding_id | file:line | 判定 | 判定文 |' '|------------|-----------|------|--------|' \
    "$1" '' '📎 non_blocking_count: 2' '📎 reviewed_commit: abc' '' '<!-- rite:nbr:v1 -->'
}
ISSUED_A='| F-01 | a.md:3 | issued | #77 https://example.test/issues/77 |'

echo "--- T-29: sweep 起票済みだけが残るなら起票しない ---"
reset_stubs
r=$(new_root t29)
put_json "$r" "9-20260101120000.json" "$FINDING_JSON"
jq -n --argjson c "$(comment_obj "$(record_body '| F-01 | plugins/rite/skills/cleanup/SKILL.md:12 | issued | #77 https://example.test/issues/77 |')")" '[[$c]]' > "$GH_API_JSON"
run_target "$r"
assert "T-29 exit 0" "0" "$RC"
assert_grep "T-29 all_issued marker" "$ERR" 'FOLLOW_UP_ISSUE=skipped; reason=all_issued; pr=9'
assert_grep "T-29 stdout summary も all_issued" "$OUT" 'result=skipped; reason=all_issued; pr=9'
assert "T-29 create 0 回" "0" "$(create_count)"
assert "T-29 all_issued でも判定済み記録を書く" "pr=9" "$(cat "$r/.rite/state/follow-up-judged-9.txt" 2>/dev/null)"
assert_grep "T-29 除外件数を出す" "$ERR" '^\[cleanup-follow-up-issue\] sweep_issued: pr=9; excluded=1; possible_duplicates=0$'
assert_not_grep "T-29 既存 follow-up を検索しない" "$GH_LOG" 'labels=follow-up'
assert_not_grep "T-29 除外不能に倒さない" "$ERR" 'FOLLOW_UP_SWEEP_ISSUED=unavailable'
assert_not_grep "T-29 重複しうる指摘が無ければ WARNING を出さない" "$ERR" 'WARNING: sweep 起票済みの指摘と同じ位置'
for t29_disp in REJECT RESOLVED LINK; do
  reset_stubs
  r=$(new_root "t29-$t29_disp")
  put_json "$r" "9-20260101120000.json" "$FINDING_JSON"
  jq -n --argjson c "$(comment_obj "$(record_body "| F-01 | plugins/rite/skills/cleanup/SKILL.md:12 | $t29_disp | 処分済み |")")" '[[$c]]' > "$GH_API_JSON"
  run_target "$r"
  assert "T-29 sweep が $t29_disp で処分した指摘は候補に戻さない" "skipped:0" \
    "$(grep -q 'FOLLOW_UP_ISSUE=skipped; reason=all_issued; pr=9' "$ERR" && echo skipped):$(create_count)"
done
for t29_disp in recorded rejected; do
  reset_stubs
  r=$(new_root "t29-$t29_disp")
  put_json "$r" "9-20260101120000.json" "$FINDING_JSON"
  jq -n --argjson c "$(comment_obj "$(record_body "| F-01 | plugins/rite/skills/cleanup/SKILL.md:12 | $t29_disp | 旧形式 |")")" '[[$c]]' > "$GH_API_JSON"
  run_target "$r"
  assert_not_grep "T-29 旧形式の $t29_disp 行は終端にしない" "$ERR" 'reason=all_issued'
done
# 一覧は台帳の issued / LINK / REJECT 行を運び、id・位置が変わった候補を分類役が既存 Issue へ紐づけられる
reset_stubs
r=$(new_root t29-ledger)
put_json "$r" "9-20260101120000.json" "$FINDING_JSON"
jq -n --argjson c "$(comment_obj "$(record_body "$(printf '%s\n' \
  '| F-01 | plugins/rite/skills/cleanup/SKILL.md:12 | recorded | 旧形式 |' \
  '| F-07 | other.md:5 | issued | #77 https://example.test/issues/77 |' \
  '| F-08 | x.md:2 | LINK | 追跡先 #5 |' \
  '| F-09 | y.md:3 | REJECT | a \| b の間は不要 | 9-20251231120000.json |' \
  '| F-10 | z.md:4 | RESOLVED | 解消の根拠 | 9-20251231120000.json |' \
  '| F-11 | w.md:5 | ADOPT | 採用の前提 | 9-20251231120000.json |')")")" '[[$c]]' > "$GH_API_JSON"
ADOPT_MODE=manual
run_target "$r" --list-candidates "$TMP_ROOT/t29-ledger.json"
assert "T-29 一覧の ledger は issued / LINK / REJECT 行だけを運ぶ" "F-07:issued,F-08:LINK,F-09:REJECT" \
  "$(jq -r '[.ledger[] | "\(.id):\(.disposition)"] | join(",")' "$TMP_ROOT/t29-ledger.json")"
assert "T-29 ledger の issued 行は起票先の番号を運ぶ" "other.md:5|#77 https://example.test/issues/77" \
  "$(jq -r '.ledger[] | select(.id == "F-07") | "\(.loc)|\(.premise)"' "$TMP_ROOT/t29-ledger.json")"
assert "T-29 ledger の REJECT 行はエスケープ済みパイプを判定文に保ち、出典を運ぶ" 'a \| b の間は不要|9-20251231120000.json' \
  "$(jq -r '.ledger[] | select(.id == "F-09") | "\(.premise)|\(.source)"' "$TMP_ROOT/t29-ledger.json")"
assert "T-29 id も位置も違う issued 行では候補を除外しない" "1" "$(jq '.candidates | length' "$TMP_ROOT/t29-ledger.json")"
assert_grep "T-29 6.0.A は ledger から既存 Issue へ紐づける" "$PLUGIN_ROOT/skills/cleanup/SKILL.md" \
  '既存の Issue が候補と同じ根因を追跡していれば、文面・位置・id が変わっていても記録の `tracker` にその番号を入れる'
assert_grep "T-29 6.0 の note は apply_failed で台帳を読めなかったと言わない" "$PLUGIN_ROOT/skills/cleanup/SKILL.md" \
  '（`apply_failed` は台帳を読めているので付けない）'
assert_grep "T-29 6.0.A は ledger 行のキーを prior のキーへ写す" "$PLUGIN_ROOT/skills/cleanup/SKILL.md" \
  '行の `id` を `finding_id`、`loc` を `file_line` に写し、`source` は写さない'
# 候補が先送り欠陥だけでも、一覧は台帳の行を運ぶ (指摘が無くても sweep 起票済みの根因へ紐づけられる)
reset_stubs
r=$(new_root t29-ledger-deferred)
printf '%s\n' '## 9. Decision Log' '' '- 2026-01-01 D-01: first defect / Reason: r1 / Impact: i1 <!-- rite:deferred-defect pr=9 -->' > "$STUB_DIR/issue-body.md"
export GH_ISSUE_BODY="$STUB_DIR/issue-body.md"
GH_HEAD_OID=$(git_head_commit "$r") || fail "T-29 fixture の commit を作れない"
export GH_HEAD_OID
jq -n --argjson c "$(comment_obj "$(record_body '| F-07 | other.md:5 | issued | #77 https://example.test/issues/77 |')")" '[[$c]]' > "$GH_API_JSON"
ADOPT_MODE=manual
run_target "$r" --list-candidates "$TMP_ROOT/t29-ledger-deferred.json"
assert "T-29 先送り欠陥だけの一覧も ledger に issued 行を運ぶ" "deferred|F-07:issued" \
  "$(jq -r '"\([.candidates[].kind] | unique | join(","))|\([.ledger[] | "\(.id):\(.disposition)"] | join(","))"' "$TMP_ROOT/t29-ledger-deferred.json")"
assert_not_grep "T-29 台帳を読めたときは unavailable を出さない" "$ERR" 'FOLLOW_UP_SWEEP_ISSUED=unavailable'
# 先送り欠陥だけの一覧で台帳を読めないときは、空の ledger を「行が無い」と区別できるよう WARNING と marker を出す
export GH_API_RC=1
ADOPT_MODE=manual
run_target "$r" --list-candidates "$TMP_ROOT/t29-ledger-unread.json"
assert "T-29 台帳を読めない一覧の ledger は空" "0" "$(jq '.ledger | length' "$TMP_ROOT/t29-ledger-unread.json")"
assert_grep "T-29 台帳を読めない一覧は unavailable を出す" "$ERR" 'FOLLOW_UP_SWEEP_ISSUED=unavailable; reason=comments_api; pr=9'
assert_grep "T-29 台帳を読めない一覧は WARNING を出す" "$ERR" 'WARNING: 関連 Issue の却下台帳を読めないため'
# 先送り欠陥がある起票実行も、前回処分した先送り欠陥を除くために台帳を読む。読めなければ unavailable を出す
ADOPT_MODE=manual
run_target "$r"
assert_grep "T-29 先送り欠陥の起票実行は台帳を読み、読めなければ unavailable を出す" "$ERR" 'FOLLOW_UP_SWEEP_ISSUED=unavailable; reason=comments_api; pr=9'
unset GH_API_RC
# sweep が書く出典付きの 5 列の REJECT 行は、出典が finding の出典 JSON と一致するときだけ除外する
for t29_src in 9-20260101120000.json 9-20251231120000.json; do
  reset_stubs
  r=$(new_root "t29-reject5-$t29_src")
  put_json "$r" "9-20260101120000.json" "$FINDING_JSON"
  jq -n --argjson c "$(comment_obj "$(record_body "| F-01 | plugins/rite/skills/cleanup/SKILL.md:12 | REJECT | 処分済み | $t29_src |")")" '[[$c]]' > "$GH_API_JSON"
  run_target "$r"
  if [ "$t29_src" = 9-20260101120000.json ]; then
    assert "T-29 出典が一致する 5 列の REJECT 行は候補に戻さない" "skipped:0" \
      "$(grep -q 'FOLLOW_UP_ISSUE=skipped; reason=all_issued; pr=9' "$ERR" && echo skipped):$(create_count)"
  else
    assert_grep "T-29 出典が一致しない 5 列の REJECT 行では除外しない" "$ERR" 'FOLLOW_UP_ISSUE=created; issue=99; existing=0; recorded=0; pr=9'
    assert_grep "T-29 出典が一致しない 5 列の REJECT 行の指摘は転記する" "$STUB_DIR/body.md" '実測なしの指摘本文'
  fi
done

reset_stubs
r=$(new_root t29b)
put_json "$r" "9-20260101120000.json" "$TWO_FINDING_JSON"
jq -n --argjson c "$(comment_obj "$(record_body "$ISSUED_A")")" '[[$c]]' > "$GH_API_JSON"
run_target "$r" --exclude-ids "9-20260101120000.json#F-05"
assert "T-29b 解消済み + 起票済みで 0 件は起票しない" "0" "$(create_count)"
assert_grep "T-29b 最後の除外で 0 件なら all_issued" "$ERR" 'reason=all_issued; pr=9'
assert_not_grep "T-29b all_resolved に倒さない" "$ERR" 'reason=all_resolved'

echo "--- T-30: issued だけを除き recorded は転記する (2 ページ目の台帳) ---"
reset_stubs
r=$(new_root t30)
put_json "$r" "9-20260101120000.json" "$TWO_FINDING_JSON"
jq -n --argjson u "$(comment_obj '作業メモリ')" \
  --argjson c "$(comment_obj "$(record_body "$(printf '%s\n%s' "$ISSUED_A" '| F-05 | b.md:9 | recorded | severity=LOW; measured=false |')")" 2)" \
  '[[$u],[$c]]' > "$GH_API_JSON"
run_target "$r"
assert "T-30 exit 0" "0" "$RC"
assert_grep "T-30 created" "$ERR" 'FOLLOW_UP_ISSUE=created; issue=99; existing=0; recorded=0; pr=9'
assert "T-30 create 1 回" "1" "$(create_count)"
assert_grep "T-30 recorded の finding は転記する" "$STUB_DIR/body.md" 'b.md:9'
assert_not_grep "T-30 issued の finding は転記しない" "$STUB_DIR/body.md" 'a.md:3'
assert_not_grep "T-30 issued の description も載らない" "$STUB_DIR/body.md" '残存する指摘の本文'
assert_grep "T-30 除外件数 1" "$ERR" 'sweep_issued: pr=9; excluded=1; possible_duplicates=0$'
assert_grep "T-30 取得先は関連 Issue の全ページ" "$GH_LOG" '^gh api --paginate --slurp repos/acme/demo/issues/42/comments$'

for variant in no_heading no_sentinel not_issued; do
  reset_stubs
  r=$(new_root "t30-$variant")
  put_json "$r" "9-20260101120000.json" "$TWO_FINDING_JSON"
  case "$variant" in
    no_heading)  _body=$(record_body "$ISSUED_A" | sed '1s/.*/## 別のコメント/') ;;
    no_sentinel) _body=$(record_body "$ISSUED_A" | sed '$s/.*/末尾は別の行/') ;;
    not_issued)  _body=$(record_body "$(printf '%s\n%s' '| F-01 | a.md:3 | recorded | severity=LOW; measured=false |' '| F-05 | b.md:9 | rejected | 旧形式 |')") ;;
  esac
  jq -n --argjson c "$(comment_obj "$_body")" '[[$c]]' > "$GH_API_JSON"
  run_target "$r"
  assert_grep "T-30 $variant は除外しない (a.md)" "$STUB_DIR/body.md" 'a.md:3'
  assert_grep "T-30 $variant は除外しない (b.md)" "$STUB_DIR/body.md" 'b.md:9'
  assert_grep "T-30 $variant の除外件数 0" "$ERR" 'sweep_issued: pr=9; excluded=0; possible_duplicates=0$'
done

echo "--- T-31: 台帳を読めないときは除外を適用せず WARNING + marker、採否ゲートも文脈を読めず保留する ---"
reset_stubs
export GH_API_RC=1
r=$(new_root t31)
put_json "$r" "9-20260101120000.json" "$TWO_FINDING_JSON"
run_target "$r"
assert "T-31 exit 0" "0" "$RC"
assert_grep "T-31 WARNING" "$ERR" 'WARNING: 関連 Issue の記録コメントを取得できませんでした'
assert_grep "T-31 helper の失敗理由を surface" "$ERR" 'NONBLOCKING_RECORD_BODY=failed; pr=9; reason=lookup_failed'
assert_grep "T-31 unavailable marker" "$ERR" 'FOLLOW_UP_SWEEP_ISSUED=unavailable; reason=comments_api; pr=9'
assert_grep "T-31 gh の原因行を surface" "$ERR" 'simulated api failure'
assert_grep "T-31 採否ゲートは台帳を読めず保留する" "$ERR" 'FOLLOW_UP_ISSUE=held; reason=context_unavailable; hold_file='
assert "T-31 保留は起票しない" "0" "$(create_count)"
assert_grep "T-31 保留した候補に両方の指摘 (a.md)" "$r/.rite/state/adoption-hold-9-followup.json" 'a.md'
assert_grep "T-31 保留した候補に両方の指摘 (b.md)" "$r/.rite/state/adoption-hold-9-followup.json" 'b.md'
assert_not_grep "T-31 除外件数を出さない" "$ERR" 'sweep_issued:'

reset_stubs
printf '%s\n' '{"message":"not pages"}' > "$GH_API_JSON"
r=$(new_root t31b)
put_json "$r" "9-20260101120000.json" "$TWO_FINDING_JSON"
run_target "$r"
assert_grep "T-31b 記録コメントを同定できない応答は comments_api" "$ERR" 'FOLLOW_UP_SWEEP_ISSUED=unavailable; reason=comments_api; pr=9'
assert_grep "T-31b 採否ゲートも記録コメントを読めず保留する" "$ERR" 'FOLLOW_UP_ISSUE=held; reason=context_unavailable;'
assert "T-31b 保留は起票しない" "0" "$(create_count)"

reset_stubs
jq -n --argjson c "$(comment_obj "$(record_body "$ISSUED_A")")" '[[$c]]' > "$GH_API_JSON"
r=$(new_root t31b2)
put_json "$r" "9-20260101120000.json" "$TWO_FINDING_JSON"
RITE_TEST_JQ_FAIL=ledger run_target "$r"
assert_grep "T-31b 台帳行を分解できなければ ledger_invalid" "$ERR" 'FOLLOW_UP_SWEEP_ISSUED=unavailable; reason=ledger_invalid; pr=9'
assert_grep "T-31b 台帳行の分解の失敗を実際に注入した" "$STUB_DIR/jq-fail.log" '^ledger$'
assert_grep "T-31b 除外せず転記 (a.md)" "$STUB_DIR/body.md" 'a.md:3'

reset_stubs
r=$(new_root t31c)
put_json "$r" "9-20260101120000.json" "$TWO_FINDING_JSON"
run_raw --state-root "$r" --pr 9 --owner acme --repo demo \
    --projects-enabled false --create-script "$CREATE_STUB"
assert "T-31c exit 0" "0" "$RC"
assert_grep "T-31c 関連 Issue 無しは no_source_issue" "$ERR" 'FOLLOW_UP_SWEEP_ISSUED=unavailable; reason=no_source_issue; pr=9'
assert_grep "T-31c WARNING" "$ERR" 'WARNING: 関連 Issue が無いため却下台帳を読めません'
assert "T-31c 起票は継続する" "1" "$(create_count)"
assert_grep "T-31c 起票した本文に両方の指摘 (b.md)" "$STUB_DIR/body.md" 'b.md:9'

echo "--- T-32: 台帳が無い PR は従来どおり全件転記 ---"
reset_stubs
r=$(new_root t32)
put_json "$r" "9-20260101120000.json" "$TWO_FINDING_JSON"
jq -n --argjson c "$(comment_obj '作業メモリ')" '[[$c]]' > "$GH_API_JSON"
run_target "$r"
assert_grep "T-32 created" "$ERR" 'FOLLOW_UP_ISSUE=created; issue=99; existing=0; recorded=0; pr=9'
assert_grep "T-32 a.md を転記" "$STUB_DIR/body.md" 'a.md:3'
assert_grep "T-32 b.md を転記" "$STUB_DIR/body.md" 'b.md:9'
assert_not_grep "T-32 除外不能に倒さない" "$ERR" 'FOLLOW_UP_SWEEP_ISSUED=unavailable'

echo "--- T-33: 台帳行は最新 JSON と組が一致したときだけ採用する ---"
reset_stubs
r=$(new_root t33)
put_json "$r" "9-20260101120000.json" "$TWO_FINDING_JSON"
jq -n --argjson c "$(comment_obj "$(record_body '| F-01 | b.md:9 | issued | #77 https://example.test/issues/77 |')")" '[[$c]]' > "$GH_API_JSON"
run_target "$r"
assert_grep "T-33 id だけ一致する finding は除外しない" "$STUB_DIR/body.md" 'a.md:3'
assert_grep "T-33 位置だけ一致する finding は除外しない" "$STUB_DIR/body.md" 'b.md:9'
assert_grep "T-33 除外件数 0" "$ERR" 'sweep_issued: pr=9; excluded=0; possible_duplicates=0$'

reset_stubs
r=$(new_root t33b)
put_json "$r" "9-20260101120000.json" '{"non_blocking_findings":[{"id":"F-01","file":"a.md","line":3,"description":"cycle1"}]}'
put_json "$r" "9-20260102120000.json" '{"non_blocking_findings":[{"id":"F-01","file":"a.md","line":3,"description":"cycle2"},{"id":"F-02","file":"c.md","line":1,"description":"別の指摘"}]}'
jq -n --argjson c "$(comment_obj "$(record_body "$ISSUED_A")")" '[[$c]]' > "$GH_API_JSON"
run_target "$r"
assert_grep "T-33b 別 key の finding は転記" "$STUB_DIR/body.md" 'c.md:1'
assert_not_grep "T-33b 最新 JSON の組の指摘は転記しない" "$STUB_DIR/body.md" '説明: cycle2$'
assert_grep "T-33b 同じ id・同じ位置でも先行 cycle の指摘は転記" "$STUB_DIR/body.md" '説明: cycle1$'
assert_grep "T-33b 除外は最新 JSON 由来の 1 件だけ" "$ERR" 'sweep_issued: pr=9; excluded=1; possible_duplicates=1$'
assert_grep "T-33b 重複しうる位置を WARNING で出す" "$ERR" 'WARNING: sweep 起票済みの指摘と同じ位置に先行 cycle の指摘が 1 件あります \(a.md:3\)'
assert_not_grep "T-33b 曖昧 marker を出さない" "$ERR" 'FOLLOW_UP_EXCLUDE_AMBIGUOUS'

# 同じ指摘が行ずれして再報告された場合、台帳の file:line だけでは先行 cycle の同一性を判定できない
reset_stubs
r=$(new_root t33b_shifted)
put_json "$r" "9-20260101120000.json" '{"non_blocking_findings":[{"id":"F-07","file":"a.md","line":3,"description":"行ずれ前の指摘"}]}'
put_json "$r" "9-20260102120000.json" '{"non_blocking_findings":[{"id":"F-01","file":"a.md","line":5,"description":"行ずれ後の起票済み指摘"}]}'
jq -n --argjson c "$(comment_obj "$(record_body '| F-01 | a.md:5 | issued | #77 https://example.test/issues/77 |')")" '[[$c]]' > "$GH_API_JSON"
run_target "$r"
assert_grep "T-33b 行ずれ前の先行 cycle 指摘は転記" "$STUB_DIR/body.md" '行ずれ前の指摘'
assert_not_grep "T-33b 行ずれ後の最新指摘は転記しない" "$STUB_DIR/body.md" '行ずれ後の起票済み指摘'
assert_grep "T-33b 行ずれは重複候補に数えない" "$ERR" 'sweep_issued: pr=9; excluded=1; possible_duplicates=0$'
assert_not_grep "T-33b 行ずれは重複 WARNING を出さない" "$ERR" 'WARNING: sweep 起票済みの指摘と同じ位置'

# 先行 cycle にしか無い指摘は、最新 JSON の同じ位置が全件 sweep 起票済みでも転記する
# (再掲マーカーが無ければ、id が振り直された同じ指摘か別の指摘かを台帳から判定できない)
reset_stubs
r=$(new_root t33c)
put_json "$r" "9-20260101120000.json" '{"non_blocking_findings":[{"id":"F-07","file":"a.md","line":3,"description":"先行 cycle にのみ載る指摘"}]}'
put_json "$r" "9-20260102120000.json" '{"non_blocking_findings":[{"id":"F-01","file":"a.md","line":3,"description":"cycle2 の起票済み指摘"}]}'
jq -n --argjson c "$(comment_obj "$(record_body "$ISSUED_A")")" '[[$c]]' > "$GH_API_JSON"
run_target "$r"
assert "T-33c 先行 cycle の指摘が残るので起票する" "1" "$(create_count)"
assert_not_grep "T-33c all_issued に倒さない" "$ERR" 'reason=all_issued'
assert_grep "T-33c 先行 cycle の指摘を転記" "$STUB_DIR/body.md" '先行 cycle にのみ載る指摘'
assert_not_grep "T-33c 最新 JSON の起票済み指摘は転記しない" "$STUB_DIR/body.md" 'cycle2 の起票済み指摘'
assert_grep "T-33c 除外件数 1" "$ERR" 'sweep_issued: pr=9; excluded=1; possible_duplicates=1$'
assert_grep "T-33c 重複しうることを WARNING で出す" "$ERR" 'WARNING: sweep 起票済みの指摘と同じ位置に先行 cycle の指摘が 1 件あります'

reset_stubs
r=$(new_root t33d)
put_json "$r" "9-20260101120000.json" '{"non_blocking_findings":[{"id":"F-01","file":"a.md","line":3,"description":"cycle1 の指摘"}]}'
put_json "$r" "9-20260102120000.json" '{"non_blocking_findings":[{"id":"F-02","file":"c.md","line":1,"description":"最新 cycle の指摘"}]}'
jq -n --argjson c "$(comment_obj "$(record_body "$ISSUED_A")")" '[[$c]]' > "$GH_API_JSON"
run_target "$r"
assert_grep "T-33d 最新 JSON に組が無い台帳行は採用しない" "$STUB_DIR/body.md" 'a.md:3'
assert_grep "T-33d 最新 cycle の指摘も転記" "$STUB_DIR/body.md" 'c.md:1'
assert_grep "T-33d 除外件数 0" "$ERR" 'sweep_issued: pr=9; excluded=0; possible_duplicates=0$'

# 先行 cycle の id が最新 JSON と衝突する (F-01) 場合も、組の照合は先行 cycle の指摘に当てない
for cycle1_id in F-04 F-01; do
  reset_stubs
  r=$(new_root "t33e-$cycle1_id")
  put_json "$r" "9-20260101120000.json" "{\"non_blocking_findings\":[{\"id\":\"$cycle1_id\",\"file\":\"a.md\",\"line\":3,\"description\":\"cycle1 の指摘\"}]}"
  put_json "$r" "9-20260102120000.json" '{"non_blocking_findings":[{"id":"F-01","file":"a.md","line":3,"description":"起票済みの指摘"},{"id":"F-02","file":"a.md","line":3,"description":"同じ位置の記録のみの指摘"}]}'
  jq -n --argjson c "$(comment_obj "$(record_body "$(printf '%s\n%s' "$ISSUED_A" '| F-02 | a.md:3 | recorded | severity=LOW; measured=false |')")")" '[[$c]]' > "$GH_API_JSON"
  run_target "$r"
  assert_grep "T-33e $cycle1_id 同じ位置の recorded は転記" "$STUB_DIR/body.md" '同じ位置の記録のみの指摘'
  assert_not_grep "T-33e $cycle1_id 採用した組の指摘は転記しない" "$STUB_DIR/body.md" '説明: 起票済みの指摘$'
  assert_grep "T-33e $cycle1_id 先行 cycle の指摘は転記" "$STUB_DIR/body.md" 'cycle1 の指摘'
  assert_grep "T-33e $cycle1_id 除外件数 1" "$ERR" 'sweep_issued: pr=9; excluded=1; possible_duplicates=1$'
done

for variant in broken not_array; do
  reset_stubs
  r=$(new_root "t33f-$variant")
  put_json "$r" "9-20260101120000.json" '{"non_blocking_findings":[{"id":"F-01","file":"a.md","line":3,"description":"起票済みの指摘"}]}'
  case "$variant" in
    broken)    put_json "$r" "9-20260102120000.json" '{broken' ;;
    not_array) put_json "$r" "9-20260102120000.json" '{"non_blocking_findings":"x"}' ;;
  esac
  jq -n --argjson c "$(comment_obj "$(record_body "$ISSUED_A")")" '[[$c]]' > "$GH_API_JSON"
  run_target "$r"
  assert "T-33f $variant exit 0" "0" "$RC"
  assert_grep "T-33f $variant 照合できない WARNING" "$ERR" 'WARNING: sweep 起票済みの指摘を最新のレビュー結果 JSON と照合できません'
  assert_grep "T-33f $variant apply_failed marker" "$ERR" 'FOLLOW_UP_SWEEP_ISSUED=unavailable; reason=apply_failed; pr=9'
  assert_grep "T-33f $variant 除外せず転記" "$STUB_DIR/body.md" 'a.md:3'
  assert_not_grep "T-33f $variant 除外件数を出さない" "$ERR" 'sweep_issued:'
done

echo "--- T-34: cleanup SKILL.md が sweep 起票済み除外の結果を完了報告へ配線する ---"
assert_grep "T-34 all_issued を x 相当に置く" "$CLEANUP_MD" '^  \| `created` .*`skipped; reason=all_issued` .*\| x 相当 \|'
assert_grep "T-34 sweep note の定義" "$CLEANUP_MD" '^- `\{follow_up_sweep_note\}`:'
assert_grep "T-34 sweep note は unavailable marker を読む" "$CLEANUP_MD" 'FOLLOW_UP_SWEEP_ISSUED=unavailable; reason=\{r\}; pr=\{pr_number\}'
assert_grep "T-34 完了報告に sweep note を差し込む" "$CLEANUP_MD" '\{follow_up_reverify_note\}\{follow_up_ambiguous_note\}\{follow_up_sweep_note\}'

echo "--- T-35: 記録コメントは書き込み経路と同じ helper で読み、台帳行の分解式が nb-sweep-collect.sh と揃っている ---"
COLLECT_SH="$SCRIPT_DIR/../scripts/nb-sweep-collect.sh"
NBR_HELPER="$SCRIPT_DIR/../review-nonblocking-record.sh"
for f in "$TARGET" "$COLLECT_SH"; do
  assert "T-35 読み取り専用モードを 1 回呼ぶ ($(basename "$f"))" "1" "$(grep -cE '^[^#]*--print-record-body' "$f")"
  assert "T-35 記録見出しの前方一致で選ばない ($(basename "$f"))" "0" "$(grep -cF 'startswith("## 📜 rite 非実測指摘の記録")' "$f")"
  assert "T-35 コメント一覧を直接読まない ($(basename "$f"))" "0" "$(grep -cE 'issues/[^ ]*/comments' "$f")"
  assert_grep "T-35 台帳節の切り出し ($(basename "$f"))" "$f" 'split\("### 却下台帳\\n"\)\[1:\]\[\]'
  # CRLF は helper が正規化して渡す。読み手ごとに正規化を持たない
  assert "T-35 読み手は CRLF を正規化しない ($(basename "$f"))" "0" "$(grep -cF 'gsub("\r\n"; "\n")' "$f")"
done
# CRLF の正規化は読み取り専用モードが PATCH 先の本文を取る 1 か所だけにある
assert "T-35 helper の CRLF 正規化は 1 か所" "1" "$(grep -cF 'gsub("\r\n"; "\n")' "$NBR_HELPER")"
assert_grep "T-35 helper の CRLF 正規化は PATCH 先の本文取得と同じパイプライン" "$NBR_HELPER" \
  "jq -r '\(\.body // \"\"\) \| gsub\(\"\\\\r\\\\n\"; \"\\\\n\"\)'"

echo "--- T-35b: 記録コメントが 2 件あっても helper が PATCH する 1 件の台帳だけを読む ---"
reset_stubs
r=$(new_root t35b)
put_json "$r" "9-20260101120000.json" "$TWO_FINDING_JSON"
# 古い記録 (id 11) は F-05 を issued、新しい記録 (id 13 = PATCH 先) は F-01 を issued、他人のコメント (id 99) は F-05 を issued
ISSUED_B='| F-05 | b.md:9 | issued | #78 https://example.test/issues/78 |'
jq -n --argjson old "$(comment_obj "$(record_body "$ISSUED_B")" 11)" \
  --argjson new "$(comment_obj "$(record_body "$ISSUED_A")" 13)" \
  --argjson foreign "$(comment_obj "$(record_body "$ISSUED_B")" 99 someone-else)" \
  '[[$old, $new], [$foreign]]' > "$GH_API_JSON"
run_target "$r"
assert "T-35b exit 0" "0" "$RC"
assert_not_grep "T-35b PATCH 先の台帳 (F-01 issued) は除外する" "$STUB_DIR/body.md" 'a.md:3'
assert_grep "T-35b 古い記録・他人のコメントの台帳 (F-05 issued) は使わない" "$STUB_DIR/body.md" 'b.md:9'
assert_grep "T-35b 除外件数 1" "$ERR" 'sweep_issued: pr=9; excluded=1; possible_duplicates=0$'
assert_grep "T-35b 読み取りは PATCH 先 (id 13) を指す" "$ERR" 'NONBLOCKING_RECORD_BODY=found; pr=9; comment_id=13$'

echo "--- T-36: CRLF 本文の却下台帳も issued 行を読める ---"
reset_stubs
r=$(new_root t36)
put_json "$r" "9-20260101120000.json" "$FINDING_JSON"
crlf_body=$(record_body '| F-01 | plugins/rite/skills/cleanup/SKILL.md:12 | issued | #77 https://example.test/issues/77 |' | sed 's/$/\r/')
assert "T-36 fixture は CR を含む" "yes" "$(printf '%s' "$crlf_body" | grep -c >/dev/null $'\r' && echo yes || echo no)"
jq -n --argjson c "$(comment_obj "$crlf_body")" '[[$c]]' > "$GH_API_JSON"
run_target "$r"
assert "T-36 exit 0" "0" "$RC"
assert_grep "T-36 CRLF でも all_issued" "$ERR" 'FOLLOW_UP_ISSUE=skipped; reason=all_issued; pr=9'
assert_grep "T-36 CRLF でも除外件数 1" "$ERR" 'sweep_issued: pr=9; excluded=1; possible_duplicates=0$'
assert "T-36 create 0 回" "0" "$(create_count)"

echo "--- T-37: 別 JSON の同じ id は key が指す finding だけを除外する ---"
reset_stubs
r=$(new_root t37)
put_json "$r" "9-20260101120000.json" '{"non_blocking_findings":[{"id":"F-03","file":"a.md","line":1,"description":"cycle1 の F-03"}]}'
put_json "$r" "9-20260102120000.json" '{"non_blocking_findings":[{"id":"F-03","file":"a.md","line":1,"description":"cycle2 の F-03"}]}'
put_json "$r" "9-20260103120000.json" '{"non_blocking_findings":[{"id":"F-03","file":"a.md","line":1,"description":"cycle3 の F-03"}]}'
# 保存 helper が同秒衝突時に作る suffix 付きファイルも、自分の basename の key で除外できる
put_json "$r" "9-20260102120000~1a2b.json" '{"non_blocking_findings":[{"id":"F-03","file":"a.md","line":1,"description":"同秒衝突の F-03"}]}'
# 同じ timestamp の corrupt 退避ファイルも和集合に入る。basename が違うので正規 JSON の key では消えない
put_json "$r" "9-20260101120000.json.corrupt-1" '{"non_blocking_findings":[{"id":"F-03","file":"a.md","line":1,"description":"corrupt 由来の F-03"}]}'
run_target "$r" --exclude-ids "9-20260101120000.json#F-03,9-20260102120000.json#F-03,9-20260102120000~1a2b.json#F-03"
assert "T-37 exit 0" "0" "$RC"
assert_grep "T-37 created" "$ERR" 'FOLLOW_UP_ISSUE=created; issue=99; existing=0; recorded=0; pr=9'
assert_not_grep "T-37 cycle1 の指摘は除外" "$STUB_DIR/body.md" '説明: cycle1 の F-03$'
assert_not_grep "T-37 cycle2 の指摘は除外" "$STUB_DIR/body.md" '説明: cycle2 の F-03$'
assert_not_grep "T-37 同秒衝突 suffix 付きの指摘も除外" "$STUB_DIR/body.md" '説明: 同秒衝突の F-03$'
assert_not_grep "T-37 同秒衝突 suffix 付き key を解析失敗にしない" "$ERR" 'exclude-ids を解析できませんでした'
assert_grep "T-37 指定していない cycle3 の指摘は転記" "$STUB_DIR/body.md" '説明: cycle3 の F-03$'
assert_grep "T-37 corrupt 由来の指摘は転記" "$STUB_DIR/body.md" '説明: corrupt 由来の F-03$'
assert "T-37 F-03 の見出しは 2 件" "2" "$(grep -c '^### F-03 ' "$STUB_DIR/body.md" | tr -d ' ')"
assert_not_grep "T-37 曖昧 marker を出さない" "$ERR" 'FOLLOW_UP_EXCLUDE_AMBIGUOUS'
assert_not_grep "T-37 未知 key WARNING を出さない" "$ERR" '一致しない key'

echo "--- T-38: 複数 JSON にまたがる全 finding を key で除外すると起票しない ---"
reset_stubs
r=$(new_root t38)
put_json "$r" "9-20260101120000.json" '{"non_blocking_findings":[{"id":"F-01","file":"a.md","line":1,"description":"d1"}]}'
put_json "$r" "9-20260102120000.json" '{"non_blocking_findings":[{"id":"F-01","file":"b.md","line":2,"description":"d2"},{"id":"F-02","file":"b.md","line":3,"description":"d3"}]}'
run_target "$r" --exclude-ids "9-20260101120000.json#F-01,9-20260102120000.json#F-01,9-20260102120000.json#F-02"
assert "T-38 exit 0" "0" "$RC"
assert_grep "T-38 all_resolved" "$ERR" 'FOLLOW_UP_ISSUE=skipped; reason=all_resolved; pr=9'
assert "T-38 create 0 回" "0" "$(create_count)"
assert_not_grep "T-38 既存 follow-up を検索しない" "$GH_LOG" 'labels=follow-up'
assert_not_grep "T-38 台帳取得 (gh api) を叩かない" "$GH_LOG" '^gh api '
assert_not_grep "T-38 曖昧 marker を出さない" "$ERR" 'FOLLOW_UP_EXCLUDE_AMBIGUOUS'

echo "--- T-39: key 形式でないトークンを含む --exclude-ids は除外を全く適用しない ---"
for variant in bare_id command_subst space upper_suffix short_suffix long_suffix bare_tilde; do
  reset_stubs
  r=$(new_root "t39-$variant")
  put_json "$r" "9-20260101120000.json" "$TWO_FINDING_JSON"
  case "$variant" in
    bare_id)       _ex='9-20260101120000.json#F-01,F-05' ;;
    command_subst) _ex='9-20260101120000.json#F-01,9-$(true).json#F-05' ;;
    space)         _ex='9-20260101120000.json#F-01,9-20260101 120000.json#F-05' ;;
    # 保存 helper の suffix は printf '%04x' の小文字 hex 4 桁だけ。形を広げすぎていないことを固定する
    upper_suffix)  _ex='9-20260101120000.json#F-01,9-20260101120000~1A2B.json#F-05' ;;
    short_suffix)  _ex='9-20260101120000.json#F-01,9-20260101120000~1a2.json#F-05' ;;
    long_suffix)   _ex='9-20260101120000.json#F-01,9-20260101120000~1a2b3.json#F-05' ;;
    bare_tilde)    _ex='9-20260101120000.json#F-01,9-20260101120000~.json#F-05' ;;
  esac
  run_target "$r" --exclude-ids "$_ex"
  assert "T-39 $variant exit 0" "0" "$RC"
  assert_grep "T-39 $variant WARNING" "$ERR" 'WARNING: --exclude-ids を解析できませんでした'
  assert "T-39 $variant marker は parse_failed のみ" \
    '[CONTEXT] FOLLOW_UP_EXCLUDE_AMBIGUOUS=1; reason=parse_failed; count=unknown; pr=9' \
    "$(grep '^\[CONTEXT\] FOLLOW_UP_EXCLUDE_AMBIGUOUS=' "$ERR")"
  assert_grep "T-39 $variant 正しい key の finding も転記" "$STUB_DIR/body.md" '残存する指摘の本文'
  assert_grep "T-39 $variant 残りの finding も転記" "$STUB_DIR/body.md" '解消済みの指摘の本文'
  assert_not_grep "T-39 $variant all_resolved に倒さない" "$ERR" 'reason=all_resolved'
done

echo "--- T-41: 6.0.V の射影が finding ごとに出典の key を出す ---"
reset_stubs
r=$(new_root t41)
put_json "$r" "9-20260101120000.json" '{"non_blocking_findings":[{"id":"F-03","file":"a.md","line":1,"description":"p1"}]}'
put_json "$r" "9-20260102120000.json" '{"non_blocking_findings":[{"id":"F-03","file":"a.md","line":1,"description":"p2"},{"id":"H-01","file":"a.md","line":2,"description":"p3"}]}'
put_json "$r" "9-20260102120000.json.corrupt-1" '{"non_blocking_findings":[{"id":"F-04","file":"a.md","line":3,"description":"p4"}]}'
put_json "$r" "9-20260102120000~1a2b.json" '{"non_blocking_findings":[{"id":"F-03","file":"a.md","line":1,"description":"p5"}]}'
# 大文字 hex は小文字版と別名にする (macOS の case-insensitive FS では ~1A2B と ~1a2b が同じファイルになる)
put_json "$r" "9-20260102120000~ABCD.json" '{"non_blocking_findings":[{"id":"F-05","file":"a.md","line":4,"description":"p6"}]}'
put_json "$r" "9-20260102120000~1a2b.json.corrupt-1" '{"non_blocking_findings":[{"id":"F-06","file":"a.md","line":5,"description":"p7"}]}'
# T-28 と同じアンカーから 6.0.V の実ブロックを抽出し、state root だけ fixture に置換する
awk -v root="$r" -v plugin="$PLUGIN_ROOT" '
  /cleanup-follow-up-issue.test.sh T-28/ {p=1}
  p && /^_state_root=\$\(bash / {print "_state_root=\"" root "\""; next}
  p && /^```/ {exit}
  p {gsub(/\{pr_number\}/, "9"); gsub(/\{plugin_root\}/, plugin); print}
' "$CLEANUP_MD" > "$TMP_ROOT/reverify-t41.sh"
if ! grep -q 'rite-fu-reverify-union' "$TMP_ROOT/reverify-t41.sh"; then
  fail "T-41 6.0.V 再検証ブロックを抽出できない"
else
  bash "$TMP_ROOT/reverify-t41.sh" > "$OUT" 2> "$ERR"; RC=$?
  assert "T-41 exit 0" "0" "$RC"
  assert "T-41 出力行数は和集合の finding 数" "7" "$(grep -c '^{' "$OUT" | tr -d ' ')"
  _t41_key() { jq -r --arg d "$1" 'select(.description == $d) | .key // "null"' "$OUT"; }
  assert "T-41 1 本目の F-03 は自分の出典を指す" "9-20260101120000.json#F-03" "$(_t41_key p1)"
  assert "T-41 2 本目の F-03 は自分の出典を指す" "9-20260102120000.json#F-03" "$(_t41_key p2)"
  assert "T-41 書式外 id は key null" "null" "$(_t41_key p3)"
  assert "T-41 corrupt 退避ファイル由来は key null" "null" "$(_t41_key p4)"
  assert "T-41 同秒衝突 suffix 付きの出典も自分の key を持つ" "9-20260102120000~1a2b.json#F-03" "$(_t41_key p5)"
  assert "T-41 大文字 hex の suffix は key null" "null" "$(_t41_key p6)"
  assert "T-41 suffix 付き出典の corrupt 退避ファイルは key null" "null" "$(_t41_key p7)"
  assert "T-41 形が合わない suffix でも id は残す" "F-05,F-06" "$(jq -r 'select(.description == "p6" or .description == "p7") | .id' "$OUT" | LC_ALL=C sort | paste -sd, -)"
  assert "T-41 corrupt 由来でも id は残す" "F-04" "$(jq -r 'select(.description == "p4") | .id' "$OUT")"
  assert_not_grep "T-41 抽出段で unavailable にしない" "$OUT" 'FOLLOW_UP_REVERIFY=unavailable'
fi

echo "--- T-42: _src だけ異なる非隣接の完全一致 finding を初出順で 1 件にまとめる ---"
reset_stubs
r=$(new_root t42)
put_json "$r" "9-20260101120000.json" '{"non_blocking_findings":[{"id":"F-01","reviewer":"test-reviewer","severity":"LOW","file":"a.md","line":1,"description":"same","suggestion":"same fix"},{"id":"F-02","reviewer":"test-reviewer","severity":"LOW","file":"b.md","line":2,"description":"middle","suggestion":"middle fix"}]}'
put_json "$r" "9-20260102120000.json" '{"non_blocking_findings":[{"id":"F-01","reviewer":"test-reviewer","severity":"LOW","file":"a.md","line":1,"description":"same","suggestion":"same fix"}]}'
run_target "$r"
assert "T-42 exit 0" "0" "$RC"
assert "T-42 完全一致は 1 件" "1" "$(grep -c '説明: same$' "$STUB_DIR/body.md" | tr -d ' ')"
assert "T-42 初出順を維持" "same,middle" "$(sed -n 's/^- 説明: //p' "$STUB_DIR/body.md" | paste -sd, -)"
assert_grep "T-42 削減件数" "$ERR" '^\[cleanup-follow-up-issue\] deduplicated: pr=9; removed=1$'

echo "--- T-43: 1 フィールドでも異なる finding はまとめない ---"
reset_stubs
r=$(new_root t43)
put_json "$r" "9-20260101120000.json" '{"non_blocking_findings":[{"id":"F-01","reviewer":"test-reviewer","severity":"LOW","file":"a.md","line":1,"description":"line differs","suggestion":"same"},{"id":"F-02","reviewer":"test-reviewer","severity":"LOW","file":"b.md","line":2,"description":"suggestion differs","suggestion":"first"}]}'
put_json "$r" "9-20260102120000.json" '{"non_blocking_findings":[{"id":"F-01","reviewer":"test-reviewer","severity":"LOW","file":"a.md","line":9,"description":"line differs","suggestion":"same"},{"id":"F-02","reviewer":"test-reviewer","severity":"LOW","file":"b.md","line":2,"description":"suggestion differs","suggestion":"second"}]}'
run_target "$r"
assert "T-43 exit 0" "0" "$RC"
assert "T-43 line 差は 2 件" "2" "$(grep -c '説明: line differs$' "$STUB_DIR/body.md" | tr -d ' ')"
assert "T-43 suggestion 差は 2 件" "2" "$(grep -c '説明: suggestion differs$' "$STUB_DIR/body.md" | tr -d ' ')"
assert_not_grep "T-43 集約ログなし" "$ERR" 'deduplicated:'

echo "--- T-44: 再検証で先行コピーを除外しても後続コピーを転記する ---"
reset_stubs
r=$(new_root t44)
put_json "$r" "9-20260101120000.json" '{"non_blocking_findings":[{"id":"F-01","reviewer":"test-reviewer","severity":"LOW","file":"a.md","line":1,"description":"remaining copy","suggestion":"fix"}]}'
put_json "$r" "9-20260102120000.json" '{"non_blocking_findings":[{"id":"F-01","reviewer":"test-reviewer","severity":"LOW","file":"a.md","line":1,"description":"remaining copy","suggestion":"fix"}]}'
run_target "$r" --exclude-ids "9-20260101120000.json#F-01"
assert "T-44 exit 0" "0" "$RC"
assert_grep "T-44 created" "$ERR" 'FOLLOW_UP_ISSUE=created; issue=99; existing=0; recorded=0; pr=9'
assert "T-44 残ったコピーを 1 件転記" "1" "$(grep -c '説明: remaining copy$' "$STUB_DIR/body.md" | tr -d ' ')"
assert_not_grep "T-44 除外後は集約なし" "$ERR" 'deduplicated:'

echo "--- T-45: 集約失敗は全 finding を元の順序で転記する ---"
reset_stubs
export RITE_TEST_JQ_FAIL=dedupe
r=$(new_root t45)
put_json "$r" "9-20260101120000.json" '{"non_blocking_findings":[{"id":"F-01","reviewer":"test-reviewer","severity":"LOW","file":"a.md","line":1,"description":"first","suggestion":"fix"}]}'
put_json "$r" "9-20260102120000.json" '{"non_blocking_findings":[{"id":"F-02","reviewer":"test-reviewer","severity":"LOW","file":"b.md","line":2,"description":"second","suggestion":"fix"}]}'
run_target "$r"
assert "T-45 exit 0" "0" "$RC"
assert "T-45 全件を元の順序で維持" "first,second" "$(sed -n 's/^- 説明: //p' "$STUB_DIR/body.md" | paste -sd, -)"
assert_grep "T-45 WARNING" "$ERR" 'WARNING: 完全一致する指摘の集約に失敗したため全件を転記します'
assert "T-45 故障注入 1 回" "1" "$(grep -c '^dedupe$' "$STUB_DIR/jq-fail.log" | tr -d ' ')"

echo "--- T-46: --preview-body は起票せず、起票時と同じ本文を書き出す ---"
reset_stubs
r=$(new_root t46)
put_json "$r" "9-20260101120000.json" '{"non_blocking_findings":[{"id":"F-01","reviewer":"test-reviewer","severity":"LOW","file":"a.md","line":1,"description":"first","suggestion":"fix"},{"id":"F-02","reviewer":"test-reviewer","severity":"LOW","file":"b.md","line":2,"description":"second","suggestion":"fix"}]}'
preview="$TMP_ROOT/preview-t46.md"
run_target "$r" --preview-body "$preview"
assert "T-46 exit 0" "0" "$RC"
assert_grep "T-46 preview marker（件数と本文パス）" "$ERR" "FOLLOW_UP_ISSUE=preview; count=2; deferred=0; issues=1; body=${preview}; pr=9"
assert_grep "T-46 stdout summary" "$OUT" 'result=preview; count=2; issues=1; pr=9'
assert "T-46 起票しない" "0" "$(create_count)"
assert_not_grep "T-46 label を作らない" "$GH_LOG" 'label create'
assert "T-46 元 Issue へコメントしない" "0" "$(wc -l < "$GH_COMMENT_LOG" | tr -d ' ')"
assert "T-46 result=preview では判定済み記録を書かない" "no" "$([ -e "$r/.rite/state/follow-up-judged-9.txt" ] && echo yes || echo no)"
# 同じ入力で起票すると、プレビューと同じ本文で作られる
run_target "$r"
assert_grep "T-46 通常実行は起票する" "$ERR" 'FOLLOW_UP_ISSUE=created; issue=99; existing=0; recorded=0; pr=9'
assert "T-46 起票後は判定済み記録を書く" "pr=9" "$(cat "$r/.rite/state/follow-up-judged-9.txt" 2>/dev/null)"
if cmp -s "$preview" "$STUB_DIR/body.md"; then
  pass "T-46 プレビュー本文と起票本文が一致"
else
  fail "T-46 プレビュー本文と起票本文が一致しない"
fi

echo "--- T-47: --preview-body でも 0 件・全件解消・全件起票済み・既存は従来の skip で終わる ---"
reset_stubs
r=$(new_root t47)
put_json "$r" "9-20260101120000.json" '{"non_blocking_findings":[]}'
run_target "$r" --preview-body "$TMP_ROOT/preview-t47.md"
assert_grep "T-47 0 件は no_findings" "$ERR" 'FOLLOW_UP_ISSUE=skipped; reason=no_findings; pr=9'
assert_not_grep "T-47 preview marker を出さない" "$ERR" 'FOLLOW_UP_ISSUE=preview'
assert "T-47 no_findings でも preview 付きで判定済み記録を書く" "pr=9" "$(cat "$r/.rite/state/follow-up-judged-9.txt" 2>/dev/null)"
reset_stubs
r=$(new_root t47b)
put_json "$r" "9-20260101120000.json" "$FINDING_JSON"
printf '%s\n' '[[{"number":77,"body":"<!-- [rite-follow-up-from-pr:9] -->\nbody"}]]' > "$GH_LIST_JSON"
run_target "$r" --preview-body "$TMP_ROOT/preview-t47b.md"
assert_grep "T-47 既存は already_exists" "$ERR" 'FOLLOW_UP_ISSUE=skipped; reason=already_exists; issue=77; pr=9'
assert_not_grep "T-47 既存でも preview を出さない" "$ERR" 'FOLLOW_UP_ISSUE=preview'
assert "T-47 already_exists でも preview 付きで判定済み記録を書く" "pr=9" "$(cat "$r/.rite/state/follow-up-judged-9.txt" 2>/dev/null)"
reset_stubs
r=$(new_root t47c)
put_json "$r" "9-20260101120000.json" "$FINDING_JSON"
run_target "$r" --exclude-ids "9-20260101120000.json#F-01" --preview-body "$TMP_ROOT/preview-t47c.md"
assert_grep "T-47 全件解消は all_resolved" "$ERR" 'FOLLOW_UP_ISSUE=skipped; reason=all_resolved; pr=9'
assert_not_grep "T-47 全件解消でも preview を出さない" "$ERR" 'FOLLOW_UP_ISSUE=preview'
assert "T-47 全件解消は起票しない" "0" "$(create_count)"
assert "T-47 all_resolved でも preview 付きで判定済み記録を書く" "pr=9" "$(cat "$r/.rite/state/follow-up-judged-9.txt" 2>/dev/null)"
reset_stubs
r=$(new_root t47d)
put_json "$r" "9-20260101120000.json" "$FINDING_JSON"
jq -n --argjson c "$(comment_obj "$(record_body '| F-01 | plugins/rite/skills/cleanup/SKILL.md:12 | issued | #77 https://example.test/issues/77 |')")" '[[$c]]' > "$GH_API_JSON"
run_target "$r" --preview-body "$TMP_ROOT/preview-t47d.md"
assert_grep "T-47 全件起票済みは all_issued" "$ERR" 'FOLLOW_UP_ISSUE=skipped; reason=all_issued; pr=9'
assert_not_grep "T-47 全件起票済みでも preview を出さない" "$ERR" 'FOLLOW_UP_ISSUE=preview'
assert "T-47 all_issued の preview 実行は起票しない" "0" "$(create_count)"
assert "T-47 all_issued でも preview 付きで判定済み記録を書く" "pr=9" "$(cat "$r/.rite/state/follow-up-judged-9.txt" 2>/dev/null)"

echo "--- T-48: preview 本文を書き出せなければ起票も preview もしない ---"
reset_stubs
r=$(new_root t48)
put_json "$r" "9-20260101120000.json" "$FINDING_JSON"
run_target "$r" --preview-body "$TMP_ROOT/no-such-dir/preview.md"
assert "T-48 exit 0" "0" "$RC"
assert_grep "T-48 failed marker" "$ERR" 'FOLLOW_UP_ISSUE=failed; reason=preview_write; pr=9'
assert_not_grep "T-48 preview marker を出さない" "$ERR" 'FOLLOW_UP_ISSUE=preview'
assert "T-48 起票しない" "0" "$(create_count)"
assert_not_grep "T-48 label を作らない" "$GH_LOG" 'label create'

echo "--- T-49: SKILL 6.0.C の確認判定と helper 呼び出しの配線 ---"
# helper 呼び出しが preview の配線を持つ（外すと手動 cleanup が確認なしで起票する）
assert_grep "T-49 helper 呼び出しが確認用の本文書き出しオプションを受け取れる" "$CLEANUP_MD" '[-]-exclude-ids "\{resolved_ids_csv\}" \{preview_option\} \|\| _fu_rc=\$\?'
# 中断時の非確認は cursor が当該 Issue を指す run に限る限定句
assert_grep "T-49 非確認は cursor が当該 Issue を指す run に限る" "$CLEANUP_MD" 'この非確認は cursor が中断時点でまだ当該 Issue を指している run に限る'
# 6.0.C の判定 bash を抽出し、state root / flow-state path / issue 番号を fixture に置き換えて実行する
t49_root="$TMP_ROOT/root-t49"
mkdir -p "$t49_root/.rite/state"
awk -v root="$t49_root" '
  /^#### 6\.0\.C / {c=1}
  c && /^```bash/ {p=1; next}
  p && /^```/ {exit}
  p && /^_state_root=\$\(bash / {print "_state_root=\"${T49_ROOT-" root "}\""; next}
  p && /^_fu_flow=\$\(bash / {print "_fu_flow=\"${T49_FLOW-/x/.rite/sessions/sess-49.flow-state}\""; next}
  p {gsub(/\{issue_number\}/, "42"); print}
' "$CLEANUP_MD" > "$TMP_ROOT/confirm.sh"
# 未置換 {issue_number} を再現する別抽出（gsub しない）。caller 側の substitute 漏れを検出する経路
awk -v root="$t49_root" '
  /^#### 6\.0\.C / {c=1}
  c && /^```bash/ {p=1; next}
  p && /^```/ {exit}
  p && /^_state_root=\$\(bash / {print "_state_root=\"${T49_ROOT-" root "}\""; next}
  p && /^_fu_flow=\$\(bash / {print "_fu_flow=\"${T49_FLOW-/x/.rite/sessions/sess-49.flow-state}\""; next}
  p {print}
' "$CLEANUP_MD" > "$TMP_ROOT/confirm-raw.sh"
t49_queue="$t49_root/.rite/state/run-queue-sess-49.json"
t49_run() { bash "$TMP_ROOT/confirm.sh" 2>/dev/null; }
t49_run_raw() { bash "$TMP_ROOT/confirm-raw.sh" 2>/dev/null; }
if ! grep -q 'FOLLOW_UP_CONFIRM=skip' "$TMP_ROOT/confirm.sh"; then
  fail "T-49 6.0.C の判定ブロックを抽出できない"
elif grep -qF '{issue_number}' "$TMP_ROOT/confirm.sh"; then
  fail "T-49 issue_number の置換が効いていない fixture になっている"
elif ! grep -qF '{issue_number}' "$TMP_ROOT/confirm-raw.sh"; then
  fail "T-49 未置換 issue_number 再現用の抽出まで置換されてしまっている"
else
  printf '%s\n' '{"issues":[41,42,43],"cursor":1,"active":true,"mode":"merge"}' > "$t49_queue"
  assert "T-49 batch --merge が今の Issue を処理中なら確認しない" "[CONTEXT] FOLLOW_UP_CONFIRM=skip; reason=batch_merge" "$(t49_run)"
  printf '%s\n' '{"issues":[41,42,43],"cursor":0,"active":true,"mode":"merge"}' > "$t49_queue"
  assert "T-49 別 Issue を指す active キューは確認する" "[CONTEXT] FOLLOW_UP_CONFIRM=ask; reason=not_this_batch" "$(t49_run)"
  printf '%s\n' '{"issues":[42],"cursor":0,"active":true,"mode":"default"}' > "$t49_queue"
  assert "T-49 default モードは確認する" "[CONTEXT] FOLLOW_UP_CONFIRM=ask; reason=not_this_batch" "$(t49_run)"
  printf '%s\n' '{"issues":[42],"cursor":0,"active":false,"mode":"merge"}' > "$t49_queue"
  assert "T-49 inactive は確認する" "[CONTEXT] FOLLOW_UP_CONFIRM=ask; reason=not_this_batch" "$(t49_run)"
  printf '%s\n' '{broken' > "$t49_queue"
  assert "T-49 壊れたキューは区別できる reason で確認する" "[CONTEXT] FOLLOW_UP_CONFIRM=ask; reason=queue_unreadable" "$(t49_run)"
  : > "$t49_queue"
  assert "T-49 空のキューは区別できる reason で確認する" "[CONTEXT] FOLLOW_UP_CONFIRM=ask; reason=queue_unreadable" "$(t49_run)"
  printf '%s\n' '{"issues":[42],"cursor":0,"active":true,"mode":"merge"}' > "$t49_queue"
  assert "T-49 未置換 issue_number は区別できる reason で確認する" "[CONTEXT] FOLLOW_UP_CONFIRM=ask; reason=queue_unreadable" "$(t49_run_raw)"
  rm -f "$t49_queue"
  assert "T-49 キューが無ければ確認する" "[CONTEXT] FOLLOW_UP_CONFIRM=ask; reason=no_queue" "$(t49_run)"
  printf '%s\n' '{"issues":[42],"cursor":0,"active":true,"mode":"merge"}' > "$t49_queue"
  assert "T-49 flow-state が解決できなければ確認する" "[CONTEXT] FOLLOW_UP_CONFIRM=ask; reason=state_unresolved" "$(T49_FLOW="" t49_run)"
  assert "T-49 state root が解決できなければ確認する" "[CONTEXT] FOLLOW_UP_CONFIRM=ask; reason=state_unresolved" "$(T49_ROOT="" t49_run)"
fi
# 判定結果を helper のオプションと marker に結ぶ手順（外すと確認なしの起票・batch での確認・見送りの記録漏れになる）
assert_grep "T-49 ask なら本文を書き出して起票しない" "$CLEANUP_MD" '^- `ask` → `\{preview_option\}` を `--preview-body "\$\{TMPDIR:-/tmp\}/rite-follow-up-preview-\{pr_number\}\.md"` にして実行する'
assert_grep "T-49 skip なら確認せず起票する" "$CLEANUP_MD" '^- `skip` → 下の helper 呼び出しを `\{preview_option\}` を空にして実行する'
assert_grep "T-49 起票するを選んだら確認なしで再実行する" "$CLEANUP_MD" '^  - 「起票する」→ `\{preview_option\}` を空にして helper 呼び出しをもう一度実行する'
assert_grep "T-49 起票しないを選んだら declined を出す" "$CLEANUP_MD" '^  - 「起票しない」→ `echo "\[CONTEXT\] FOLLOW_UP_ISSUE=declined; count=\{fu_count\}; pr=\{pr_number\}" >&2`'
# item 1: 「起票しない」後は起票せず state 削除（archive）へ進む契約を全行 pin
assert "T-49 起票しない後は起票せず state 削除へ進む（全行一致）" "1" \
  "$(grep -cxF '  - 「起票しない」→ `echo "[CONTEXT] FOLLOW_UP_ISSUE=declined; count={fu_count}; pr={pr_number}" >&2`（`{fu_count}` は preview marker の `count=` の値をリテラル置換する） を実行し、Issue は作らずに下の state 削除（archive）へ進む。' "$CLEANUP_MD")"
# item 2: 6.0.V 内訳（marker 不在は unavailable と同じ書き方）を全行 pin
assert "T-49 preview 説明に 6.0.V 内訳と marker 不在時の扱いを pin する（全行一致）" "1" \
  "$(grep -cxF -- '- `preview` のとき AskUserQuestion で「起票する / 起票しない / 本文を確認してから決める」を確認する。説明には起票する Issue 数 `{fu_issues}`（preview marker の `issues=` の値。根因の数）、転記件数 `{fu_count}`（同 `count=` の値。指摘と先送り欠陥の合計）、うち先送り欠陥 `{fu_deferred}`（同 `deferred=` の値）と、6.0.V の内訳（`done` なら「残存 {n_remains} / 判定不能 {n_undecidable}」、`unavailable` なら「再検証未実施（全件を判定不能扱い）」）を入れる。6.0.V の marker が 1 つも出ていない場合も `unavailable` と同じ書き方にする。6.0.V の内訳は指摘だけを数え、件数は重複の集約と sweep 起票済みの除外の後の値なので、内訳の合計と一致しないことがある。' "$CLEANUP_MD")"
# 完了報告の判定表が見送りと確認未完了を持つ
# item 3: declined 行の完全一致（セル追記でも通る前方一致を排除）
assert "T-49 完了報告の declined 行を完全一致で固定する" "1" \
  "$(grep -cxF '  | `declined`（ステップ 6.0.C で「起票しない」を選んだ） | x 相当 | `ℹ️ 確認のうえ follow-up Issue の起票を見送りました（{count} 件）。指摘の全文は review-results/archive/ の JSON に、先送り欠陥は元 Issue の Decision Log（Section 9）にあります` |' "$CLEANUP_MD")"
assert_grep "T-49 完了報告に preview 行（未完了）" "$CLEANUP_MD" '^  \| `preview`（確認の回答前に止まった） \| 未完了'
# item 4: declined 付記の count 由来を全行 pin
assert "T-49 declined 付記の count 由来を全行 pin する" "1" \
  "$(grep -cxF '  `held` の付記の `{reason}` / `{hold_file}` は held marker の同名の値。`declined` の付記の `{count}` は declined marker の `count=` の値。x 相当でもこの付記は `{review_cleanup_check}` の行に続けて出す。' "$CLEANUP_MD")"
# AC-2: failed; reason=preview_write 専用行・汎用行からの除外・評価順（上から最初に一致が preview_write 側に落ちること）
assert "T-49 preview_write 専用行を完全一致で固定する" "1" \
  "$(grep -cxF '  | `FOLLOW_UP_ISSUE=failed; reason=preview_write` | 未完了 | `⚠️ follow-up 起票の確認用の本文を書き出せず、起票を試みていません。書き出し先を確認して /rite:cleanup {pr_number} を再実行してください` |' "$CLEANUP_MD")"
assert_not_grep "T-49 汎用 failed 行に preview_write を残さない" "$CLEANUP_MD" 'reason 問わず。`helper_rc` / `lookup_api` / `create_api` / `create_script_missing` / `json_undecidable` / `preview_write`'
assert_grep "T-49 汎用 failed 行は preview_write 以外と明記する" "$CLEANUP_MD" 'reason 問わず。preview_write 以外。'
t49_pw_line=$(grep -nF '`FOLLOW_UP_ISSUE=failed; reason=preview_write`' "$CLEANUP_MD" | head -1 | cut -d: -f1)
t49_generic_line=$(grep -nF 'reason 問わず。preview_write 以外。' "$CLEANUP_MD" | head -1 | cut -d: -f1)
assert "T-49 preview_write 専用行は汎用 failed 行より先に評価される" "true" \
  "$([ -n "$t49_pw_line" ] && [ -n "$t49_generic_line" ] && [ "$t49_pw_line" -lt "$t49_generic_line" ] && echo true || echo false)"

# archive/ に JSON を置く
put_archived() { mkdir -p "$1/.rite/review-results/archive"; with_head "$3" > "$1/.rite/review-results/archive/$2"; }
SOURCES_LIB="$PLUGIN_ROOT/hooks/scripts/lib/review-results-sources.sh"
# $1=results_dir $2=suffix。呼び出し元の照合は T50_LOCALE (C 以外の照合を持つ環境ではそれ)
list_sources() { LC_ALL="$T50_LOCALE" bash -c '. "$1"; rite_review_results_sources "$2" 9 "$3"' _ "$SOURCES_LIB" "$1" "$2"; }
# en_US.UTF-8 の照合は `.` と `~` を第 1 段階で無視し、同秒衝突の 2 本を C と逆に並べる。
# 無い環境では C のまま実行する (順序の assert は C でも成り立つので fail しない)
T50_LOCALE=C
t50_utf8=$(locale -a 2>/dev/null | grep -iE '^en_US\.utf-?8$' | head -1)
if [ -n "$t50_utf8" ]; then T50_LOCALE="$t50_utf8"; else echo "  (en_US.UTF-8 が無いため C 照合で実行)"; fi

echo "--- T-50: 読み元の列挙は直下と archive/ を basename 昇順で合わせる ---"
r=$(new_root t50)
put_archived "$r" "9-20260101120000.json" '{}'
put_json "$r" "9-20260102120000.json" '{}'
put_archived "$r" "9-20260103120000.json" '{}'
put_json "$r" "9-20260104120000.json.corrupt-1" '{}'
put_json "$r" "9-20260105120000.json" '{"where":"top"}'
put_archived "$r" "9-20260105120000.json" '{"where":"archive"}'
put_json "$r" "9-20260106120000.json" '{}'
put_archived "$r" "9-20260106120000~1a2b.json" '{}'
put_json "$r" "9-20260107120000.json.corrupt-1" '{}'
put_archived "$r" "19-20260101120000.json" '{}'
d="$r/.rite/review-results"
t50_want=$(printf '%s\n' "$d/archive/9-20260101120000.json" "$d/9-20260102120000.json" \
  "$d/archive/9-20260103120000.json" "$d/9-20260104120000.json.corrupt-1" "$d/9-20260105120000.json" \
  "$d/9-20260106120000.json" "$d/archive/9-20260106120000~1a2b.json" "$d/9-20260107120000.json.corrupt-1")
assert "T-50 basename のバイト順で合わせ、同名は直下だけ、別 PR は含めない ($T50_LOCALE)" "$t50_want" "$(list_sources "$d" '.json*')"
t50_want_json=$(printf '%s\n' "$d/archive/9-20260101120000.json" "$d/9-20260102120000.json" \
  "$d/archive/9-20260103120000.json" "$d/9-20260105120000.json" \
  "$d/9-20260106120000.json" "$d/archive/9-20260106120000~1a2b.json")
assert "T-50 .json 指定は corrupt 退避ファイルを含めない ($T50_LOCALE)" "$t50_want_json" "$(list_sources "$d" '.json')"
assert "T-50 ディレクトリが無ければ何も返さない" "" "$(list_sources "$TMP_ROOT/absent" '.json*')"

echo "--- T-51: archive/ にだけある JSON から転記する ---"
reset_stubs
r=$(new_root t51)
put_archived "$r" "9-20260101120000.json" "$FINDING_JSON"
run_target "$r"
assert "T-51 exit 0" "0" "$RC"
assert_grep "T-51 created" "$ERR" 'FOLLOW_UP_ISSUE=created; issue=99; existing=0; recorded=0; pr=9'
assert_not_grep "T-51 no_json にしない" "$ERR" 'reason=no_json'
assert_grep "T-51 archive の JSON を和集合に数える" "$ERR" 'union: pr=9; json_total=1; json_parsed=1; json_unparsed=0'
assert_grep "T-51 archive の指摘を転記する" "$STUB_DIR/body.md" '実測なしの指摘本文'

echo "--- T-52: 直下と archive/ の同名 JSON は 1 回だけ数える ---"
reset_stubs
r=$(new_root t52)
put_json "$r" "9-20260101120000.json" "$TWO_FINDING_JSON"
put_archived "$r" "9-20260101120000.json" "$TWO_FINDING_JSON"
run_target "$r" --exclude-ids "9-20260101120000.json#F-05"
assert_grep "T-52 同名は 1 本として数える" "$ERR" 'union: pr=9; json_total=1; json_parsed=1; json_unparsed=0'
assert_not_grep "T-52 除外 key を曖昧にしない" "$ERR" 'FOLLOW_UP_EXCLUDE_AMBIGUOUS'
assert_not_grep "T-52 除外した指摘は転記しない" "$STUB_DIR/body.md" '解消済みの指摘の本文'
assert_grep "T-52 残った指摘は転記する" "$STUB_DIR/body.md" '残存する指摘の本文'

echo "--- T-53: 最新 JSON が archive/ にあっても sweep 起票済みを除外する ---"
reset_stubs
r=$(new_root t53)
put_archived "$r" "9-20260101120000.json" "$FINDING_JSON"
jq -n --argjson c "$(comment_obj "$(record_body '| F-01 | plugins/rite/skills/cleanup/SKILL.md:12 | issued | #77 https://example.test/issues/77 |')")" '[[$c]]' > "$GH_API_JSON"
run_target "$r"
assert_grep "T-53 all_issued" "$ERR" 'FOLLOW_UP_ISSUE=skipped; reason=all_issued; pr=9'
assert_not_grep "T-53 最新 JSON を見失わない" "$ERR" 'FOLLOW_UP_SWEEP_ISSUED=unavailable'
assert "T-53 create 0 回" "0" "$(create_count)"

echo "--- T-54: 6.0.V の再検証も archive/ の JSON を読む ---"
reset_stubs
r=$(new_root t54)
put_archived "$r" "9-20260101120000.json" "$FINDING_JSON"
awk -v root="$r" -v plugin="$PLUGIN_ROOT" '
  /cleanup-follow-up-issue.test.sh T-28/ {p=1}
  p && /^_state_root=\$\(bash / {print "_state_root=\"" root "\""; next}
  p && /^```/ {exit}
  p {gsub(/\{pr_number\}/, "9"); gsub(/\{plugin_root\}/, plugin); print}
' "$CLEANUP_MD" > "$TMP_ROOT/reverify-t54.sh"
bash "$TMP_ROOT/reverify-t54.sh" > "$OUT" 2> "$ERR"; RC=$?
assert "T-54 exit 0" "0" "$RC"
assert_not_grep "T-54 no_json にしない" "$OUT" 'reason=no_json'
assert "T-54 archive の指摘に key を付ける" "9-20260101120000.json#F-01" "$(jq -r '.key' "$OUT")"

echo "--- T-55: マージ後・cleanup 前の orphan 回収を挟んでも転記できる ---"
reset_stubs
r=$(new_root t55)
git -C "$r" init --quiet
git -C "$r" -c user.email=t@example.test -c user.name=t commit --quiet --allow-empty -m init
git -C "$r" remote add origin git@github.com:acme/demo.git
put_json "$r" "9-20260101120000.json" "$FINDING_JSON"
cp "$r/.rite/review-results/9-20260101120000.json" "$TMP_ROOT/t55-original.json"
# $1=出力先。回収は TMPDIR 配下の古い rite-* ディレクトリも掃除するため、テスト専用の TMPDIR で実行する
mkdir -p "$TMP_ROOT/t55-tmp"
t55_gc() { (cd "$r" && TMPDIR="$TMP_ROOT/t55-tmp" PATH="$TMP_ROOT/bin:$PATH" bash "$PLUGIN_ROOT/hooks/scripts/pr-cycle-cleanup.sh") > "$1" 2>&1; }
t55_gc "$TMP_ROOT/t55-gc1.out"
assert_grep "T-55 マージ済み PR の JSON は orphan 回収で archive/ へ移る" "$TMP_ROOT/t55-gc1.out" 'orphan_reviews_archived=1'
assert "T-55 直下には残らない" "no" "$([ -e "$r/.rite/review-results/9-20260101120000.json" ] && echo yes || echo no)"
run_target "$r"
assert_grep "T-55 cleanup の follow-up 起票は archive/ の JSON から転記する" "$ERR" 'FOLLOW_UP_ISSUE=created; issue=99; existing=0; recorded=0; pr=9'
bash "$PLUGIN_ROOT/hooks/scripts/cleanup-pr-state-purge.sh" --pr 9 --state-root "$r" > "$TMP_ROOT/t55-purge.out" 2>&1
assert_not_grep "T-55 cleanup の archive は失敗しない" "$TMP_ROOT/t55-purge.out" 'REVIEW_CLEANUP_PARTIAL_FAILURE'
if cmp -s "$TMP_ROOT/t55-original.json" "$r/.rite/review-results/archive/9-20260101120000.json"; then
  pass "T-55 archive/ の JSON は二重に退避されず元の内容のまま"
else
  fail "T-55 archive/ の JSON が変わった / 消えた"
fi
assert "T-55 archive/ の JSON は 1 本" "1" "$(find "$r/.rite/review-results/archive" -type f -name '9-*' | wc -l | tr -d ' ')"
t55_gc "$TMP_ROOT/t55-gc2.out"
assert_grep "T-55 2 回目の orphan 回収は何も移さない" "$TMP_ROOT/t55-gc2.out" 'orphan_reviews_archived=0'

echo "--- T-56: C 以外の照合でも最新 JSON は同秒衝突側を選ぶ ---"
reset_stubs
r=$(new_root t56)
# 直下に古い cycle、archive/ に同秒衝突の新しい側。sweep (nb-sweep-collect.sh は LC_ALL=C) が読むのは ~1a2b
put_json "$r" "9-20260101120000.json" '{"non_blocking_findings":[]}'
put_archived "$r" "9-20260101120000~1a2b.json" "$FINDING_JSON"
jq -n --argjson c "$(comment_obj "$(record_body '| F-01 | plugins/rite/skills/cleanup/SKILL.md:12 | issued | #77 https://example.test/issues/77 |')")" '[[$c]]' > "$GH_API_JSON"
LC_ALL="$T50_LOCALE" run_target "$r"
assert_grep "T-56 sweep 起票済みを除外して all_issued ($T50_LOCALE)" "$ERR" 'FOLLOW_UP_ISSUE=skipped; reason=all_issued; pr=9'
assert "T-56 create 0 回" "0" "$(create_count)"

echo "--- T-57: review-results-sources.sh を source できないと sources_lib_unavailable ---"
reset_stubs
r=$(new_root t57)
put_json "$r" "9-20260101120000.json" "$FINDING_JSON"
# {plugin_root} を存在しないディレクトリへ向け、review-results-sources.sh の source 失敗を再現する。
# _state_root は T-28/T-54 と同じくアンカー直後の行を fixture root の literal に差し替えるため、
# 1 つ目の分岐 (state_root_unresolved) は通らない。
awk -v root="$r" -v plugin="$TMP_ROOT/nonexistent-plugin-root-xyz" '
  /cleanup-follow-up-issue.test.sh T-28/ {p=1}
  p && /^_state_root=\$\(bash / {print "_state_root=\"" root "\""; next}
  p && /^```/ {exit}
  p {gsub(/\{pr_number\}/, "9"); gsub(/\{plugin_root\}/, plugin); print}
' "$CLEANUP_MD" > "$TMP_ROOT/reverify-t57.sh"
if ! grep -q 'rite-fu-reverify-union' "$TMP_ROOT/reverify-t57.sh"; then
  fail "T-57 6.0.V 再検証ブロックを抽出できない"
else
  bash "$TMP_ROOT/reverify-t57.sh" > "$OUT" 2> "$ERR"; RC=$?
  assert "T-57 exit 0" "0" "$RC"
  # 部分一致だけだと、elif 連鎖が崩れて sources_lib_unavailable の後に別の
  # FOLLOW_UP_REVERIFY マーカーが続けて出る退行 (else 側へ抜けて no_json 等を追加出力する)
  # を見逃す。マーカー行の集合を完全一致で固定する。
  assert "T-57 sources_lib_unavailable marker のみ (完全一致)" \
    "[CONTEXT] FOLLOW_UP_REVERIFY=unavailable; reason=sources_lib_unavailable" \
    "$(grep '^\[CONTEXT\] FOLLOW_UP_REVERIFY=' "$OUT")"
fi

# $1=finding_id $2=file:line $3=出典 JSON の basename。sweep が書く 5 列の issued 行
issued_row5() { printf '| %s | %s | issued | #77 https://example.test/issues/77 | %s |' "$1" "$2" "$3"; }
CYCLE_A=9-20260101120000.json
CYCLE_B=9-20260102120000.json
CYCLE_C=9-20260103120000.json

echo "--- T-58: 先行 cycle の JSON を出典とする issued 行は、最新 JSON が変わっても除外する ---"
reset_stubs
r=$(new_root t58)
put_json "$r" "$CYCLE_A" '{"non_blocking_findings":[{"id":"F-01","file":"a.md","line":3,"description":"cycle A で起票済みの指摘"}]}'
put_json "$r" "$CYCLE_B" '{"non_blocking_findings":[{"id":"F-02","file":"c.md","line":1,"description":"cycle B の指摘"}]}'
jq -n --argjson c "$(comment_obj "$(record_body "$(issued_row5 F-01 a.md:3 "$CYCLE_A")")")" '[[$c]]' > "$GH_API_JSON"
run_target "$r"
assert "T-58 exit 0" "0" "$RC"
assert_not_grep "T-58 起票済みの指摘は転記しない" "$STUB_DIR/body.md" 'cycle A で起票済みの指摘'
assert_grep "T-58 他の指摘は転記する" "$STUB_DIR/body.md" 'cycle B の指摘'
assert_grep "T-58 除外件数 1、重複候補 0" "$ERR" '^\[cleanup-follow-up-issue\] sweep_issued: pr=9; excluded=1; possible_duplicates=0$'
assert_not_grep "T-58 重複 WARNING を出さない" "$ERR" 'WARNING: sweep 起票済みの指摘と同じ位置'
assert_not_grep "T-58 除外不能に倒さない" "$ERR" 'FOLLOW_UP_SWEEP_ISSUED=unavailable'

# 出典 JSON が archive/ へ移っていても、finding の出典 basename と台帳の出典で照合する
reset_stubs
r=$(new_root t58-archive)
put_archived "$r" "$CYCLE_A" '{"non_blocking_findings":[{"id":"F-01","file":"a.md","line":3,"description":"cycle A で起票済みの指摘"}]}'
put_json "$r" "$CYCLE_B" '{"non_blocking_findings":[]}'
jq -n --argjson c "$(comment_obj "$(record_body "$(issued_row5 F-01 a.md:3 "$CYCLE_A")")")" '[[$c]]' > "$GH_API_JSON"
run_target "$r"
assert_grep "T-58 archive/ の出典でも all_issued" "$ERR" 'FOLLOW_UP_ISSUE=skipped; reason=all_issued; pr=9'
assert "T-58 archive/ の出典でも起票しない" "0" "$(create_count)"

echo "--- T-59: 出典が最新 JSON の 5 列行は 4 列行と同じ結果になる ---"
for t59_row in "$ISSUED_A" "$(issued_row5 F-01 a.md:3 "$CYCLE_B")"; do
  reset_stubs
  r=$(new_root "t59-$(printf '%s' "$t59_row" | awk -F'|' '{print NF}')")
  put_json "$r" "$CYCLE_A" '{"non_blocking_findings":[{"id":"F-01","file":"a.md","line":3,"description":"cycle1"}]}'
  put_json "$r" "$CYCLE_B" '{"non_blocking_findings":[{"id":"F-01","file":"a.md","line":3,"description":"cycle2"},{"id":"F-02","file":"c.md","line":1,"description":"別の指摘"}]}'
  jq -n --argjson c "$(comment_obj "$(record_body "$t59_row")")" '[[$c]]' > "$GH_API_JSON"
  run_target "$r"
  assert_not_grep "T-59 最新 JSON の起票済み指摘は転記しない ($t59_row)" "$STUB_DIR/body.md" '説明: cycle2$'
  assert_grep "T-59 出典の違う先行 cycle の指摘は転記 ($t59_row)" "$STUB_DIR/body.md" '説明: cycle1$'
  assert_grep "T-59 除外件数 1、重複候補 1 ($t59_row)" "$ERR" 'sweep_issued: pr=9; excluded=1; possible_duplicates=1$'
  assert_grep "T-59 重複 WARNING ($t59_row)" "$ERR" 'WARNING: sweep 起票済みの指摘と同じ位置に先行 cycle の指摘が 1 件あります \(a.md:3\)'
done

echo "--- T-60: 出典の無い 4 列行は最新 JSON とだけ照合する (判定文にエスケープ済みパイプがあっても出典と読まない) ---"
reset_stubs
r=$(new_root t60)
put_json "$r" "$CYCLE_A" '{"non_blocking_findings":[{"id":"F-01","file":"a.md","line":3,"description":"先行 cycle の同じ組の指摘"}]}'
put_json "$r" "$CYCLE_B" '{"non_blocking_findings":[{"id":"F-01","file":"a.md","line":3,"description":"最新 cycle の起票済み指摘"}]}'
jq -n --argjson c "$(comment_obj "$(record_body '| F-01 | a.md:3 | issued | #77 a \| b |')")" '[[$c]]' > "$GH_API_JSON"
run_target "$r"
assert_not_grep "T-60 最新 JSON 由来は除外" "$STUB_DIR/body.md" '最新 cycle の起票済み指摘'
assert_grep "T-60 先行 cycle 由来は転記" "$STUB_DIR/body.md" '先行 cycle の同じ組の指摘'
assert_grep "T-60 除外件数 1" "$ERR" 'sweep_issued: pr=9; excluded=1; possible_duplicates=1$'

echo "--- T-61: 出典が一致しない finding は id・位置が同じでも除外しない ---"
reset_stubs
r=$(new_root t61)
put_json "$r" "$CYCLE_A" '{"non_blocking_findings":[{"id":"F-09","file":"z.md","line":1,"description":"cycle A の別の指摘"}]}'
put_json "$r" "$CYCLE_B" '{"non_blocking_findings":[{"id":"F-01","file":"a.md","line":3,"description":"cycle B にだけある同じ組の指摘"}]}'
jq -n --argjson c "$(comment_obj "$(record_body "$(issued_row5 F-01 a.md:3 "$CYCLE_A")")")" '[[$c]]' > "$GH_API_JSON"
run_target "$r"
assert_grep "T-61 出典不一致の指摘は転記" "$STUB_DIR/body.md" 'cycle B にだけある同じ組の指摘'
assert_grep "T-61 除外件数 0" "$ERR" 'sweep_issued: pr=9; excluded=0; possible_duplicates=0$'
assert_not_grep "T-61 除外不能に倒さない" "$ERR" 'FOLLOW_UP_SWEEP_ISSUED=unavailable'

# 出典で先行 cycle の指摘を除外しても、最新 JSON の同じ位置の指摘は重複候補に数えない
reset_stubs
r=$(new_root t61-same-loc)
put_json "$r" "$CYCLE_A" '{"non_blocking_findings":[{"id":"F-01","file":"a.md","line":3,"description":"cycle A で起票済みの指摘"}]}'
put_json "$r" "$CYCLE_B" '{"non_blocking_findings":[{"id":"F-01","file":"a.md","line":3,"description":"cycle B の同じ位置の指摘"}]}'
jq -n --argjson c "$(comment_obj "$(record_body "$(issued_row5 F-01 a.md:3 "$CYCLE_A")")")" '[[$c]]' > "$GH_API_JSON"
run_target "$r"
assert_not_grep "T-61 出典一致の先行 cycle 指摘は除外" "$STUB_DIR/body.md" 'cycle A で起票済みの指摘'
assert_grep "T-61 最新 cycle の同じ位置の指摘は転記" "$STUB_DIR/body.md" 'cycle B の同じ位置の指摘'
assert_grep "T-61 除外件数 1、重複候補 0" "$ERR" 'sweep_issued: pr=9; excluded=1; possible_duplicates=0$'
assert_not_grep "T-61 重複 WARNING を出さない" "$ERR" 'WARNING: sweep 起票済みの指摘と同じ位置'

# 出典で除外した先行 cycle 指摘の位置は重複候補の絞り込みに使わない。同じ位置に別の先行 cycle の
# 指摘があっても、最新 JSON 由来の除外が無ければ重複候補 0 のまま転記する
reset_stubs
r=$(new_root t61-prior-loc)
put_json "$r" "$CYCLE_A" '{"non_blocking_findings":[{"id":"F-01","file":"a.md","line":3,"description":"cycle A で起票済みの指摘"}]}'
put_json "$r" "$CYCLE_B" '{"non_blocking_findings":[{"id":"F-02","file":"a.md","line":3,"description":"cycle B の同じ位置の先行指摘"}]}'
put_json "$r" "$CYCLE_C" '{"non_blocking_findings":[{"id":"F-01","file":"c.md","line":1,"description":"cycle C の指摘"}]}'
jq -n --argjson c "$(comment_obj "$(record_body "$(issued_row5 F-01 a.md:3 "$CYCLE_A")")")" '[[$c]]' > "$GH_API_JSON"
run_target "$r"
assert_not_grep "T-61 出典一致の先行 cycle 指摘は除外 (3 cycle)" "$STUB_DIR/body.md" 'cycle A で起票済みの指摘'
assert_grep "T-61 同じ位置の別の先行 cycle 指摘は転記" "$STUB_DIR/body.md" 'cycle B の同じ位置の先行指摘'
assert_grep "T-61 最新 cycle の指摘は転記 (3 cycle)" "$STUB_DIR/body.md" 'cycle C の指摘'
assert_grep "T-61 除外件数 1、重複候補 0 (3 cycle)" "$ERR" 'sweep_issued: pr=9; excluded=1; possible_duplicates=0$'
assert_not_grep "T-61 先行 cycle 除外の位置で重複 WARNING を出さない" "$ERR" 'WARNING: sweep 起票済みの指摘と同じ位置'

echo "--- T-62: 出典の値が JSON を指さない / 形が合わないとき ---"
# 存在しない JSON を指す出典: どの finding とも一致せず、除外しない (重複側に倒す)
reset_stubs
r=$(new_root t62-missing)
put_json "$r" "$CYCLE_B" '{"non_blocking_findings":[{"id":"F-01","file":"a.md","line":3,"description":"最新 cycle の指摘"}]}'
jq -n --argjson c "$(comment_obj "$(record_body "$(issued_row5 F-01 a.md:3 9-20250101120000.json)")")" '[[$c]]' > "$GH_API_JSON"
run_target "$r"
assert_grep "T-62 存在しない出典では除外しない" "$STUB_DIR/body.md" '最新 cycle の指摘'
assert_grep "T-62 存在しない出典の除外件数 0" "$ERR" 'sweep_issued: pr=9; excluded=0; possible_duplicates=0$'
assert_not_grep "T-62 存在しない出典で除外不能に倒さない" "$ERR" 'FOLLOW_UP_SWEEP_ISSUED=unavailable'
# 形の合わない出典: 出典無しの行として最新 JSON とだけ照合する
for t62_src in review.json "$CYCLE_A.corrupt-1" ''; do
  reset_stubs
  r=$(new_root "t62-invalid-${t62_src:-empty}")
  put_json "$r" "$CYCLE_A" '{"non_blocking_findings":[{"id":"F-01","file":"a.md","line":3,"description":"先行 cycle の指摘"}]}'
  put_json "$r" "$CYCLE_B" '{"non_blocking_findings":[{"id":"F-01","file":"a.md","line":3,"description":"最新 cycle の指摘"}]}'
  jq -n --argjson c "$(comment_obj "$(record_body "$(issued_row5 F-01 a.md:3 "$t62_src")")")" '[[$c]]' > "$GH_API_JSON"
  run_target "$r"
  assert_not_grep "T-62 形の合わない出典 '$t62_src' は最新 JSON 由来を除外" "$STUB_DIR/body.md" '最新 cycle の指摘'
  assert_grep "T-62 形の合わない出典 '$t62_src' は先行 cycle 由来を転記" "$STUB_DIR/body.md" '先行 cycle の指摘'
  assert_grep "T-62 形の合わない出典 '$t62_src' の除外件数 1" "$ERR" 'sweep_issued: pr=9; excluded=1; possible_duplicates=1$'
done

echo "--- T-63: 出典セルの読み取り (末尾空白・エスケープ済みパイプ・CRLF) ---"
for t63_variant in trailing escaped crlf; do
  reset_stubs
  r=$(new_root "t63-$t63_variant")
  put_json "$r" "$CYCLE_A" '{"non_blocking_findings":[{"id":"F-01","file":"a.md","line":3,"description":"cycle A で起票済みの指摘"}]}'
  put_json "$r" "$CYCLE_B" '{"non_blocking_findings":[]}'
  case "$t63_variant" in
    trailing) _t63_body=$(record_body "$(issued_row5 F-01 a.md:3 "$CYCLE_A")   ") ;;
    escaped)  _t63_body=$(record_body "| F-01 | a.md:3 | issued | #77 a \| b | $CYCLE_A |") ;;
    crlf)     _t63_body=$(record_body "$(issued_row5 F-01 a.md:3 "$CYCLE_A")" | sed 's/$/\r/') ;;
  esac
  jq -n --argjson c "$(comment_obj "$_t63_body")" '[[$c]]' > "$GH_API_JSON"
  run_target "$r"
  assert_grep "T-63 $t63_variant でも出典を読んで all_issued" "$ERR" 'FOLLOW_UP_ISSUE=skipped; reason=all_issued; pr=9'
  assert_grep "T-63 $t63_variant の除外件数 1" "$ERR" 'sweep_issued: pr=9; excluded=1; possible_duplicates=0$'
done

echo "--- T-64: 台帳・JSON を読めないときは出典付きの行でも除外しない ---"
reset_stubs
export GH_API_RC=1
r=$(new_root t64-comments)
put_json "$r" "$CYCLE_A" '{"non_blocking_findings":[{"id":"F-01","file":"a.md","line":3,"description":"cycle A の指摘"}]}'
jq -n --argjson c "$(comment_obj "$(record_body "$(issued_row5 F-01 a.md:3 "$CYCLE_A")")")" '[[$c]]' > "$GH_API_JSON"
run_target "$r"
assert_grep "T-64 取得失敗は comments_api" "$ERR" 'FOLLOW_UP_SWEEP_ISSUED=unavailable; reason=comments_api; pr=9'
assert_grep "T-64 取得失敗の WARNING" "$ERR" 'WARNING: 関連 Issue の記録コメントを取得できませんでした'
assert_grep "T-64 取得失敗では除外せず候補に残し、採否ゲートが保留する" "$r/.rite/state/adoption-hold-9-followup.json" 'cycle A の指摘'
assert "T-64 取得失敗の保留は起票しない" "0" "$(create_count)"
# 最新 JSON を照合できないときは、出典が先行 cycle を指す行も含めて除外を適用しない
reset_stubs
r=$(new_root t64-latest)
put_json "$r" "$CYCLE_A" '{"non_blocking_findings":[{"id":"F-01","file":"a.md","line":3,"description":"cycle A の指摘"}]}'
put_json "$r" "$CYCLE_B" '{broken'
jq -n --argjson c "$(comment_obj "$(record_body "$(issued_row5 F-01 a.md:3 "$CYCLE_A")")")" '[[$c]]' > "$GH_API_JSON"
run_target "$r"
assert_grep "T-64 最新 JSON を読めなければ apply_failed" "$ERR" 'FOLLOW_UP_SWEEP_ISSUED=unavailable; reason=apply_failed; pr=9'
assert_grep "T-64 最新 JSON を読めなければ除外せず転記" "$STUB_DIR/body.md" 'cycle A の指摘'
assert_not_grep "T-64 最新 JSON を読めなければ除外件数を出さない" "$ERR" 'sweep_issued:'
# apply_failed は台帳を読めた後の失敗なので、一覧の ledger は台帳の行を運ぶ
ADOPT_MODE=manual
run_target "$r" --list-candidates "$TMP_ROOT/t64-latest-list.json"
assert_grep "T-64 最新 JSON を読めない一覧も apply_failed" "$ERR" 'FOLLOW_UP_SWEEP_ISSUED=unavailable; reason=apply_failed; pr=9'
assert "T-64 apply_failed の一覧の ledger は台帳の行を運ぶ" "F-01:issued" \
  "$(jq -r '[.ledger[] | "\(.id):\(.disposition)"] | join(",")' "$TMP_ROOT/t64-latest-list.json")"

echo "--- T-65: 指摘 0 件でも Decision Log で先送りした欠陥があれば起票し、本 PR のトークン行だけを転記する ---"
# $1=Section 9 の後に続ける行 (終端の検証用)。Section 9 の外・別 PR・トークンなしの行は転記しない
deferred_body() {
  printf '%s\n' '## 概要' '' '- 散文 D-99: section 外 <!-- rite:deferred-defect pr=9 -->' '' '## 9. Decision Log' '' \
    '- 2026-01-01 D-01: first defect / Reason: r1 / Impact: i1 <!-- rite:deferred-defect pr=9 -->' \
    '- 2026-01-01 D-02: not deferred / Reason: r2 / Impact: i2' \
    '- 2026-01-01 D-03: other pr / Reason: r3 / Impact: i3 <!-- rite:deferred-defect pr=90 -->' \
    '- 2026-01-01 D-04: second defect / Reason: r4 / Impact: i4 <!-- rite:deferred-defect pr=9 -->  ' \
    "$1"
}
DEFERRED_EXPECTED='- 2026-01-01 D-01: first defect / Reason: r1 / Impact: i1
- 2026-01-01 D-04: second defect / Reason: r4 / Impact: i4'
# body.md の「## Decision Log で先送りした欠陥」節から転記行 (- で始まる行) だけを取り出す
deferred_lines() { awk '/^## Decision Log で先送りした欠陥$/ { s = 1; next } s && /^## / { s = 0 } s && /^- / { print }' "$1"; }
reset_stubs
r=$(new_root t65)
put_json "$r" "9-20260101120000.json" '{"non_blocking_findings":[]}'
deferred_body '' > "$STUB_DIR/issue-body.md"
export GH_ISSUE_BODY="$STUB_DIR/issue-body.md"
run_target "$r"
assert "T-65 exit 0" "0" "$RC"
assert_grep "T-65 created" "$ERR" 'FOLLOW_UP_ISSUE=created; issue=99; existing=0; recorded=0; pr=9'
assert "T-65 create 1 回" "1" "$(create_count)"
assert "T-65 転記行はトークンを除いた元の行と完全一致し、出現順に並ぶ" "$DEFERRED_EXPECTED" "$(deferred_lines "$STUB_DIR/body.md")"
assert_not_grep "T-65 トークンを本文に残さない" "$STUB_DIR/body.md" 'rite:deferred-defect'
assert_not_grep "T-65 指摘節を出さない" "$STUB_DIR/body.md" '^## 残存 non-blocking 指摘$'
assert "T-65 body 先頭行は根因単位の marker (先送り行の D-NN)" "<!-- [rite-follow-up-from-pr:9:D-01,D-04] -->" "$(head -1 "$STUB_DIR/body.md")"
assert "T-65 body 5 行目 概要" "## 概要" "$(sed -n '5p' "$STUB_DIR/body.md")"
assert "T-65 title" "follow-up: PR #9 の残存指摘（- 2026-01-01 D-01: first defect / Reason）" "$(jq -r '.issue.title' "$STUB_DIR/args.json")"
assert_not_grep "T-65 no_findings に倒さない" "$ERR" 'reason=no_findings'
assert_grep "T-65 既存 follow-up の検索は gh を呼ぶ (GH_LOG が記録される)" "$GH_LOG" '^gh api --paginate --slurp repos/acme/demo/issues\?labels=follow-up&state=all&per_page=100$'
assert_not_grep "T-65 sweep 起票済みの照合をしない" "$ERR" 'sweep_issued:'
assert_not_grep "T-65 取得失敗 marker を出さない" "$ERR" 'FOLLOW_UP_DEFERRED'

echo "--- T-66: Section 9 の終端 3 種の後ろにあるトークン行は転記しない (CRLF 本文を含む) ---"
for variant in heading rule details crlf; do
  reset_stubs
  r=$(new_root "t66-$variant")
  put_json "$r" "9-20260101120000.json" '{"non_blocking_findings":[]}'
  after='- 2026-01-01 D-09: after section / Reason: r / Impact: i <!-- rite:deferred-defect pr=9 -->'
  case "$variant" in
    heading) deferred_body "$(printf '%s\n' '## 10. 次の節' "$after")" > "$STUB_DIR/issue-body.md" ;;
    rule)    deferred_body "$(printf '%s\n' '---' "$after")" > "$STUB_DIR/issue-body.md" ;;
    details) deferred_body "$(printf '%s\n' '</details>' "$after")" > "$STUB_DIR/issue-body.md" ;;
    crlf)    deferred_body '' | sed 's/$/\r/' > "$STUB_DIR/issue-body.md" ;;
  esac
  export GH_ISSUE_BODY="$STUB_DIR/issue-body.md"
  run_target "$r"
  assert "T-66 $variant create 1 回" "1" "$(create_count)"
  assert "T-66 $variant 転記行は Section 9 内の本 PR 行だけ" "$DEFERRED_EXPECTED" "$(deferred_lines "$STUB_DIR/body.md")"
done

echo "--- T-67: 同じ根因に束ねた指摘と先送り欠陥を 1 件の follow-up に載せる ---"
reset_stubs
r=$(new_root t67)
put_json "$r" "9-20260101120000.json" "$FINDING_JSON"
deferred_body '' > "$STUB_DIR/issue-body.md"
export GH_ISSUE_BODY="$STUB_DIR/issue-body.md"
run_target "$r"
assert "T-67 create 1 回" "1" "$(create_count)"
assert "T-67 指摘節" "1" "$(grep -cxF '## 残存 non-blocking 指摘' "$STUB_DIR/body.md")"
assert_grep "T-67 指摘本文" "$STUB_DIR/body.md" '実測なしの指摘本文'
assert "T-67 転記行" "$DEFERRED_EXPECTED" "$(deferred_lines "$STUB_DIR/body.md")"
assert "T-67 title" "follow-up: PR #9 の残存指摘（実測なしの指摘本文）" "$(jq -r '.issue.title' "$STUB_DIR/args.json")"
assert "T-67 指摘節は先送り節より前" "1" "$(awk '/^## 残存 non-blocking 指摘$/ { a = NR } /^## Decision Log で先送りした欠陥$/ { b = NR } END { print (a && b && a < b) ? 1 : 0 }' "$STUB_DIR/body.md")"

echo "--- T-68: 元 Issue 本文を取得できなければ marker を出し、採否ゲートも本文を読めず保留する ---"
reset_stubs
r=$(new_root t68)
put_json "$r" "9-20260101120000.json" "$FINDING_JSON"
export GH_ISSUE_BODY_RC=1
run_target "$r"
assert "T-68 exit 0" "0" "$RC"
assert_grep "T-68 unavailable marker" "$ERR" 'FOLLOW_UP_DEFERRED=unavailable; reason=issue_body_api; pr=9'
assert_grep "T-68 WARNING" "$ERR" 'WARNING: 元 Issue #42 の本文を取得できないため'
assert "T-68 先送り欠陥を読めないまま起票しない" "0" "$(create_count)"
assert_grep "T-68 採否ゲートが本文を読めず保留する" "$ERR" 'FOLLOW_UP_ISSUE=held; reason=context_unavailable;'
assert_grep "T-68 保留した候補に指摘本文" "$r/.rite/state/adoption-hold-9-followup.json" '実測なしの指摘本文'
# 記録コメントの特定も同じ本文取得を使う。記録 helper は本文照合へ fallback するので、台帳側は除外不能にならない
assert_grep "T-68 記録 helper は id 解決失敗を fallback で扱う" "$ERR" 'NONBLOCKING_ID_UNRESOLVED=1; pr=9; reason=id_read_failed; action=fallback'
assert_not_grep "T-68 台帳側は除外不能にならない" "$ERR" 'FOLLOW_UP_SWEEP_ISSUED'
reset_stubs
r=$(new_root t68b)
put_json "$r" "9-20260101120000.json" '{"non_blocking_findings":[]}'
export GH_ISSUE_BODY_RC=1
run_target "$r"
assert_grep "T-68b 指摘 0 件なら no_findings" "$ERR" 'FOLLOW_UP_ISSUE=skipped; reason=no_findings; pr=9'
assert_grep "T-68b unavailable marker" "$ERR" 'FOLLOW_UP_DEFERRED=unavailable; reason=issue_body_api; pr=9'
assert "T-68b create 0 回" "0" "$(create_count)"

echo "--- T-69: 指摘側の skip 理由でも先送り欠陥があれば起票する / 既存あり・JSON 判定不能は従来どおり ---"
reset_stubs
r=$(new_root t69-nojson)
deferred_body '' > "$STUB_DIR/issue-body.md"
export GH_ISSUE_BODY="$STUB_DIR/issue-body.md"
GH_HEAD_OID=$(git_head_commit "$r") || fail "T-69 fixture の commit を作れない"
export GH_HEAD_OID
# JSON が無ければ PR の head を対象 commit にして候補を列挙する
PATH="$TMP_ROOT/bin:$PATH" bash "$TARGET" --state-root "$r" --pr 9 --owner acme --repo demo --source-issue 42 \
  --list-candidates "$TMP_ROOT/t69-cands.json" >"$OUT" 2>"$ERR"
assert "T-69 no_json + 先送り欠陥は PR の head で候補を列挙する" "$GH_HEAD_OID|D-01 D-04" \
  "$(jq -r '"\(.head)|\([.candidates[].id] | join(" "))"' "$TMP_ROOT/t69-cands.json")"
assert_grep "T-69 列挙 marker の head は PR の head" "$ERR" "^\[CONTEXT\] FOLLOW_UP_CANDIDATES=listed; count=2; deferred=2; head=${GH_HEAD_OID}; "
assert_grep "T-69 PR の head を対象 commit にしたことを出す" "$ERR" "PR #9 の head ${GH_HEAD_OID} を対象 commit にします"
assert_grep "T-69 no_json の WARNING" "$ERR" 'Decision Log で先送りした欠陥だけを転記します'
# 記録が無ければ no_records で保留し、ゲートへ渡した対象 commit は列挙と同じ PR の head
ADOPT_MODE=manual
run_target "$r"
assert_grep "T-69 no_json + 先送り欠陥は記録が無ければ no_records で保留" "$ERR" \
  "^\[CONTEXT\] FOLLOW_UP_ISSUE=held; reason=no_records; hold_file=$r/.rite/state/adoption-hold-9-followup.json; pr=9$"
assert "T-69 保留した対象 commit は列挙と同じ PR の head" "$GH_HEAD_OID" "$(jq -r '.head' "$r/.rite/state/adoption-hold-9-followup.json")"
assert_grep "T-69 保留した候補に先送り行" "$r/.rite/state/adoption-hold-9-followup.json" 'D-04: second defect'
assert "T-69 保留中は起票しない" "0" "$(create_count)"
assert "T-69 保留中は判定済み記録を書かない" "no" "$([ -e "$r/.rite/state/follow-up-judged-9.txt" ] && echo yes || echo no)"
assert_not_grep "T-69 no_json に倒さない" "$ERR" 'reason=no_json'
# PR の head を head に持つ判定記録を書けば判定に進み、起票する
jq -n --arg h "$GH_HEAD_OID" --arg c "$PR_CONTRACT_LINE" '{adoption: {head: $h, records: [
  {ids: ["D-01", "D-04"], V: true, C: false, T: false, contract: {ref: "pr", text: $c},
   evidence: "テストの根拠", origin: "pre_existing", present: true, tracker: null, prior: null,
   reason: "", proposition: null, acceptance: "テストの受入条件"}]}}' > "$r/.rite/state/adoption-9-followup.json"
run_target "$r"
assert_grep "T-69 記録を書けば起票する" "$ERR" '^\[CONTEXT\] FOLLOW_UP_ISSUE=created; issue=99; existing=0; recorded=0; pr=9$'
assert "T-69 起票は 1 回" "1" "$(create_count)"
assert_grep "T-69 本文の対象 commit は PR の head" "$STUB_DIR/body.md" "^- 対象 commit: \`${GH_HEAD_OID}\`\$"
assert "T-69 起票後は判定済み記録を書く" "pr=9" "$(cat "$r/.rite/state/follow-up-judged-9.txt" 2>/dev/null)"
# PR の head を取れない / state root の git で解決できないときは、保留ではなく失敗で止める
for t69_case in gh_failed unresolvable; do
  reset_stubs
  r=$(new_root "t69-$t69_case")
  deferred_body '' > "$STUB_DIR/issue-body.md"
  export GH_ISSUE_BODY="$STUB_DIR/issue-body.md"
  case "$t69_case" in
    gh_failed) t69_cause='PR の head を取得できません' ;;
    unresolvable) export GH_HEAD_OID="fedcba9876543210fedcba9876543210fedcba98"; t69_cause='git で解決できません' ;;
  esac
  run_target "$r"
  assert_grep "T-69 $t69_case: head_unresolved で失敗" "$ERR" '^\[CONTEXT\] FOLLOW_UP_ISSUE=failed; reason=head_unresolved; pr=9$'
  assert "T-69 $t69_case: stdout は failed" "[cleanup-follow-up-issue] result=failed; reason=head_unresolved; pr=9" "$(cat "$OUT")"
  assert_grep "T-69 $t69_case: 原因を WARNING に出す" "$ERR" "$t69_cause"
  assert "T-69 $t69_case: 起票しない" "0" "$(create_count)"
  assert "T-69 $t69_case: 判定済み記録を書かない" "no" "$([ -e "$r/.rite/state/follow-up-judged-9.txt" ] && echo yes || echo no)"
  assert "T-69 $t69_case: 保留しない (hold ファイルを作らない)" "no" "$([ -e "$r/.rite/state/adoption-hold-9-followup.json" ] && echo yes || echo no)"
  assert_not_grep "T-69 $t69_case: held に倒さない" "$ERR" 'FOLLOW_UP_ISSUE=held'
  rm -f "$TMP_ROOT/t69-fail-cands.json"
  PATH="$TMP_ROOT/bin:$PATH" bash "$TARGET" --state-root "$r" --pr 9 --owner acme --repo demo --source-issue 42 \
    --list-candidates "$TMP_ROOT/t69-fail-cands.json" >"$OUT" 2>"$ERR"
  assert_grep "T-69 $t69_case: 列挙も head_unresolved で失敗" "$ERR" '^\[CONTEXT\] FOLLOW_UP_CANDIDATES=failed; reason=head_unresolved; pr=9$'
  assert "T-69 $t69_case: 列挙は一覧を書かない" "no" "$([ -e "$TMP_ROOT/t69-fail-cands.json" ] && echo yes || echo no)"
done
reset_stubs
r=$(new_root t69-resolved)
put_json "$r" "9-20260101120000.json" "$TWO_FINDING_JSON"
deferred_body '' > "$STUB_DIR/issue-body.md"
export GH_ISSUE_BODY="$STUB_DIR/issue-body.md"
run_target "$r" --exclude-ids "9-20260101120000.json#F-01,9-20260101120000.json#F-05"
assert "T-69 all_resolved + 先送り欠陥は起票" "1" "$(create_count)"
assert_not_grep "T-69 all_resolved に倒さない" "$ERR" 'reason=all_resolved'
assert "T-69 all_resolved 後は先送り節だけ" "0" "$(grep -cxF '## 残存 non-blocking 指摘' "$STUB_DIR/body.md")"
reset_stubs
r=$(new_root t69-issued)
put_json "$r" "9-20260101120000.json" "$FINDING_JSON"
jq -n --argjson c "$(comment_obj "$(record_body '| F-01 | plugins/rite/skills/cleanup/SKILL.md:12 | issued | #77 https://example.test/issues/77 |')")" '[[$c]]' > "$GH_API_JSON"
deferred_body '' > "$STUB_DIR/issue-body.md"
export GH_ISSUE_BODY="$STUB_DIR/issue-body.md"
run_target "$r"
assert "T-69 all_issued + 先送り欠陥は起票" "1" "$(create_count)"
assert_not_grep "T-69 all_issued に倒さない" "$ERR" 'reason=all_issued'
assert "T-69 all_issued 後の転記行" "$DEFERRED_EXPECTED" "$(deferred_lines "$STUB_DIR/body.md")"
reset_stubs
printf '%s\n' '[[{"number":50,"body":"<!-- [rite-follow-up-from-pr:9] -->\n既存"}]]' > "$GH_LIST_JSON"
r=$(new_root t69-exists)
put_json "$r" "9-20260101120000.json" '{"non_blocking_findings":[]}'
deferred_body '' > "$STUB_DIR/issue-body.md"
export GH_ISSUE_BODY="$STUB_DIR/issue-body.md"
run_target "$r"
assert_grep "T-69 既存 follow-up があれば already_exists" "$ERR" 'reason=already_exists; issue=50; pr=9'
assert "T-69 既存ありは起票しない" "0" "$(create_count)"
reset_stubs
r=$(new_root t69-undecidable)
put_json "$r" "9-20260101120000.json" 'not-json{'
deferred_body '' > "$STUB_DIR/issue-body.md"
export GH_ISSUE_BODY="$STUB_DIR/issue-body.md"
run_target "$r"
assert_grep "T-69 JSON 判定不能は先送り欠陥があっても failed" "$ERR" 'FOLLOW_UP_ISSUE=failed; reason=json_undecidable; pr=9'
assert "T-69 JSON 判定不能は起票しない" "0" "$(create_count)"

echo "--- T-70: preview の件数は指摘と先送り欠陥の合計 ---"
reset_stubs
r=$(new_root t70)
put_json "$r" "9-20260101120000.json" "$FINDING_JSON"
deferred_body '' > "$STUB_DIR/issue-body.md"
export GH_ISSUE_BODY="$STUB_DIR/issue-body.md"
preview="$TMP_ROOT/preview-t70.md"
run_target "$r" --preview-body "$preview"
assert_grep "T-70 preview marker" "$ERR" "FOLLOW_UP_ISSUE=preview; count=3; deferred=2; issues=1; body=${preview}; pr=9"
assert "T-70 preview 本文にも転記行" "$DEFERRED_EXPECTED" "$(deferred_lines "$preview")"
assert "T-70 起票しない" "0" "$(create_count)"

echo "--- T-71: トークンと Section 9 の境界は pr-review 7.4.3 と helper で一致する ---"
SCOPE_TRIAGE_MD="$PLUGIN_ROOT/skills/pr-review/references/scope-triage.md"
TEMPLATE_STRUCTURE_MD="$PLUGIN_ROOT/templates/issue/template-structure.md"
assert_grep "T-71 7.4.3 は行末に {deferred_token} を置く" "$SCOPE_TRIAGE_MD" '^\{decision\} / Reason: \{reason\} / Impact: \{impact\}\{deferred_token\}$'
assert_grep "T-71 7.4.3 のトークン値" "$SCOPE_TRIAGE_MD" '` <!-- rite:deferred-defect pr=\{pr_number\} -->`'
assert_grep "T-71 helper のトークン" "$TARGET" '^DEFERRED_TOKEN="<!-- rite:deferred-defect pr=\$\{PR_NUMBER\} -->"$'
_boundary='in_section && (/^## / || /^---[[:space:]]*$/ || /^<\/details>/)'
assert "T-71 helper の Section 9 終端は 7.4.3 と同じ" "1" "$(grep -cF "$_boundary" "$TARGET")"
assert "T-71 7.4.3 の Section 9 終端 (採番と追記の 2 か所)" "2" "$(grep -cF "$_boundary" "$SCOPE_TRIAGE_MD")"
assert_grep "T-71 template-structure の行書式にトークンを記載" "$TEMPLATE_STRUCTURE_MD" '<!-- rite:deferred-defect pr=N -->'
# 表は見出しから空行までを 1 ブロックとして比べる。行ごとの一致だけでは、行の追加（例: boundary にもトークンを付ける行）を検出できない。
_t71_table='| 候補 | `{deferred_token}` |
|---|---|
| 採否ゲートの verdict が `file` | ` <!-- rite:deferred-defect pr={pr_number} -->`（先頭に半角空白 1 つ。`{pr_number}` は本レビューの PR 番号） |
| それ以外（verdict が `record`） | 空文字列 |'
assert "T-71 7.4.3 の {deferred_token} 付与条件表" "$_t71_table" \
  "$(awk '$0 == "| 候補 | `{deferred_token}` |" { f = 1 } f && /^$/ { exit } f { print }' "$SCOPE_TRIAGE_MD")"

echo "--- T-72: cleanup SKILL.md が先送り欠陥の取得失敗を完了報告へ配線する ---"
assert_grep "T-72 完了報告に deferred note を差し込む" "$CLEANUP_MD" '\{follow_up_sweep_note\}\{follow_up_deferred_note\}$'
assert_grep "T-72 deferred note の定義" "$CLEANUP_MD" '^- `\{follow_up_deferred_note\}`:'
assert_grep "T-72 deferred note は unavailable marker を読む" "$CLEANUP_MD" 'FOLLOW_UP_DEFERRED=unavailable; reason=\{r\}; pr=\{pr_number\}'
assert_grep "T-72 先送り欠陥側は未完了" "$CLEANUP_MD" '^  \| `FOLLOW_UP_DEFERRED=unavailable` \| 未完了 \|'
assert_grep "T-72 review_cleanup_check は 3 側で判定" "$CLEANUP_MD" '先送り欠陥の読み取り（`FOLLOW_UP_DEFERRED`）・state 削除'

# $1=id $2=file $3=line $4=reviewer (空なら reviewer キーを持たない) $5=description。non_blocking_findings 1 件分
nb_finding() {
  jq -nc --arg id "$1" --arg f "$2" --argjson l "$3" --arg rv "$4" --arg d "$5" \
    '{id: $id, file: $f, line: $l, description: $d} + (if $rv == "" then {} else {reviewer: $rv} end)'
}
# $@=finding object。1 cycle 分のレビュー結果 JSON
nb_json() { jq -nc '{non_blocking_findings: $ARGS.positional}' --jsonargs "$@"; }
# $1=起票元の出典 basename。sweep が `t.sh:310` の F-01 を起票した台帳を置く
put_issued_ledger() { jq -n --argjson c "$(comment_obj "$(record_body "$(issued_row5 F-01 t.sh:310 "$1")")")" '[[$c]]' > "$GH_API_JSON"; }
relinked_lines() { grep -c '^\[cleanup-follow-up-issue\] sweep_issued_relinked:' "$ERR"; }
RELINK_A=$(nb_finding F-02 t.sh 310 test-reviewer 'cycle A の初出の指摘')
RELINK_B=$(nb_finding F-01 t.sh 310 test-reviewer '【前回 F-02、NOT_FIXED】cycle B で sweep が起票した指摘')
RELINK_C=$(nb_finding F-01 t.sh 310 test-reviewer '【F-01 再掲・NOT_FIXED】cycle C の言い直し')

echo "--- T-73: sweep 起票済みの指摘を前後の cycle が ID を変えて再掲していても転記しない ---"
reset_stubs
r=$(new_root t73)
put_json "$r" "$CYCLE_A" "$(nb_json "$RELINK_A")"
put_json "$r" "$CYCLE_B" "$(nb_json "$RELINK_B")"
put_json "$r" "$CYCLE_C" "$(nb_json "$RELINK_C")"
put_issued_ledger "$CYCLE_B"
run_target "$r"
assert "T-73 exit 0" "0" "$RC"
assert_grep "T-73 全件が起票済みの指摘の再掲なら all_issued" "$ERR" 'FOLLOW_UP_ISSUE=skipped; reason=all_issued; pr=9'
assert "T-73 起票しない" "0" "$(create_count)"
assert_grep "T-73 除外件数 3、重複候補 0" "$ERR" '^\[cleanup-follow-up-issue\] sweep_issued: pr=9; excluded=3; possible_duplicates=0$'
assert_grep "T-73 再掲として結んだ件数" "$ERR" '^\[cleanup-follow-up-issue\] sweep_issued_relinked: pr=9; relinked=2$'
assert "T-73 再掲件数の行は 1 行" "1" "$(relinked_lines)"
assert_not_grep "T-73 除外不能に倒さない" "$ERR" 'FOLLOW_UP_SWEEP_ISSUED=unavailable'

# マーカーの 2 つの書き方がそれぞれ単独で、直前の cycle の指摘と結ぶ。
# reviewer は cycle ごとに帰属が変わりうる (指摘の identity ではない) ので、違っても無くても結ぶ
for t73_form in prior_id same_id other_reviewer no_reviewer; do
  reset_stubs
  r=$(new_root "t73-$t73_form")
  case "$t73_form" in
    prior_id) t73_later=$(nb_finding F-01 t.sh 310 test-reviewer '【前回 F-02、NOT_FIXED】後の cycle の言い直し')
              t73_first=$(nb_finding F-02 t.sh 310 test-reviewer 'sweep が起票した指摘') ;;
    same_id)  t73_later=$RELINK_C
              t73_first=$(nb_finding F-01 t.sh 310 test-reviewer 'sweep が起票した指摘') ;;
    other_reviewer)
              t73_later=$(nb_finding F-05 t.sh 310 application-reviewer '（F-08 再掲・NOT_FIXED）別の reviewer の言い直し')
              t73_first=$(nb_finding F-08 t.sh 310 tech-writer-reviewer 'sweep が起票した指摘') ;;
    no_reviewer)
              t73_later=$(nb_finding F-01 t.sh 310 '' '【F-01 再掲・NOT_FIXED】reviewer の無い言い直し')
              t73_first=$(nb_finding F-01 t.sh 310 '' 'sweep が起票した指摘') ;;
  esac
  put_json "$r" "$CYCLE_A" "$(nb_json "$t73_first")"
  put_json "$r" "$CYCLE_B" "$(nb_json "$t73_later")"
  jq -n --argjson c "$(comment_obj "$(record_body "$(issued_row5 "$(printf '%s' "$t73_first" | jq -r .id)" t.sh:310 "$CYCLE_A")")")" '[[$c]]' > "$GH_API_JSON"
  run_target "$r"
  assert_grep "T-73 $t73_form の形でも all_issued" "$ERR" 'FOLLOW_UP_ISSUE=skipped; reason=all_issued; pr=9'
  assert_grep "T-73 $t73_form の形の再掲件数 1" "$ERR" '^\[cleanup-follow-up-issue\] sweep_issued_relinked: pr=9; relinked=1$'
done

# 最新 cycle で起票した場合: 先行 cycle の再掲元も除外し、重複候補の WARNING を出さない
reset_stubs
r=$(new_root t73-latest)
put_json "$r" "$CYCLE_A" "$(nb_json "$RELINK_A")"
put_json "$r" "$CYCLE_B" "$(nb_json "$RELINK_B")"
put_issued_ledger "$CYCLE_B"
run_target "$r"
assert_grep "T-73 最新 cycle 起票でも all_issued" "$ERR" 'FOLLOW_UP_ISSUE=skipped; reason=all_issued; pr=9'
assert_grep "T-73 最新 cycle 起票の除外件数 2、重複候補 0" "$ERR" '^\[cleanup-follow-up-issue\] sweep_issued: pr=9; excluded=2; possible_duplicates=0$'
assert_not_grep "T-73 再掲元を重複候補として WARNING しない" "$ERR" 'WARNING: sweep 起票済みの指摘と同じ位置'

echo "--- T-74: 同じ位置でも再掲マーカーで結ばれない別の指摘は転記する ---"
for t74_variant in no_marker mention; do
  reset_stubs
  r=$(new_root "t74-$t74_variant")
  case "$t74_variant" in
    no_marker) t74_desc='同じ位置の別の指摘: 失敗経路のテストも無い' ;;
    # 括弧の外で id に触れるだけの本文は再掲マーカーではない
    mention)   t74_desc='同じ位置の別の指摘: F-01 とは別に NOT_FIXED 判定の経路も未検証' ;;
  esac
  put_json "$r" "$CYCLE_A" "$(nb_json "$RELINK_A")"
  put_json "$r" "$CYCLE_B" "$(nb_json "$RELINK_B")"
  put_json "$r" "$CYCLE_C" "$(nb_json "$RELINK_C" "$(nb_finding F-02 t.sh 310 test-reviewer "$t74_desc")")"
  put_issued_ledger "$CYCLE_B"
  run_target "$r"
  assert "T-74 $t74_variant: 残る 1 件で起票する" "1" "$(create_count)"
  assert_grep "T-74 $t74_variant: 同じ位置の別の指摘は転記" "$STUB_DIR/body.md" '同じ位置の別の指摘'
  assert_not_grep "T-74 $t74_variant: 起票済みの指摘は転記しない" "$STUB_DIR/body.md" 'cycle B で sweep が起票した指摘'
  assert_not_grep "T-74 $t74_variant: 先行 cycle の初出は転記しない" "$STUB_DIR/body.md" 'cycle A の初出の指摘'
  assert_not_grep "T-74 $t74_variant: 後の cycle の再掲は転記しない" "$STUB_DIR/body.md" 'cycle C の言い直し'
  assert_grep "T-74 $t74_variant: 除外件数 3、重複候補 0" "$ERR" '^\[cleanup-follow-up-issue\] sweep_issued: pr=9; excluded=3; possible_duplicates=0$'
done

echo "--- T-75: 再掲マーカーは直前の cycle の同じ id・同じ位置の指摘とだけ結ぶ ---"
# どれか 1 つでも外れれば結ばず、後の cycle の指摘を転記する (欠落より重複)。
# 各 variant は cycle A または B の起票済み指摘に対する cycle C の指摘 (と cycle B) だけを変える
for t75_variant in other_line other_file other_id no_verdict partial no_bracket skip_cycle empty_cycle broken_cycle; do
  reset_stubs
  r=$(new_root "t75-$t75_variant")
  t75_desc='【F-01 再掲・NOT_FIXED】cycle C の指摘'
  t75_file=t.sh; t75_line=310; t75_prev="$CYCLE_B"
  case "$t75_variant" in
    other_line)     t75_line=311 ;;
    # 同じ id・同じ line でもファイルが違えば別の位置
    other_file)     t75_file=u.sh ;;
    other_id)       t75_desc='【F-09 再掲・NOT_FIXED】cycle C の指摘' ;;
    no_verdict)     t75_desc='【前回 F-01】cycle C の指摘' ;;
    # 一部だけ直った指摘の本文は残りの問題を書き直しているので、起票済みの本文と同じ指摘ではない
    partial)        t75_desc='【前回 F-01、PARTIAL】cycle C の指摘' ;;
    no_bracket)     t75_desc='F-01 再掲・NOT_FIXED cycle C の指摘' ;;
    # 直前の cycle が起票元でなければ、2 つ前の cycle へは遡らない
    skip_cycle|empty_cycle|broken_cycle) t75_prev="$CYCLE_A" ;;
  esac
  put_json "$r" "$t75_prev" "$(nb_json "$(nb_finding F-01 t.sh 310 test-reviewer 'sweep が起票した指摘')")"
  case "$t75_variant" in
    skip_cycle)   put_json "$r" "$CYCLE_B" "$(nb_json "$(nb_finding F-05 z.md 1 test-reviewer 'cycle B の無関係な指摘')")" ;;
    empty_cycle)  put_json "$r" "$CYCLE_B" '{"non_blocking_findings":[]}' ;;
    broken_cycle) put_json "$r" "$CYCLE_B" '{broken' ;;
  esac
  put_json "$r" "$CYCLE_C" "$(nb_json "$(nb_finding F-01 "$t75_file" "$t75_line" test-reviewer "$t75_desc")")"
  put_issued_ledger "$t75_prev"
  run_target "$r"
  assert_grep "T-75 $t75_variant: 後の cycle の指摘は転記" "$STUB_DIR/body.md" 'cycle C の指摘'
  assert_not_grep "T-75 $t75_variant: 起票済みの指摘は転記しない" "$STUB_DIR/body.md" 'sweep が起票した指摘'
  assert_grep "T-75 $t75_variant: 除外件数 1" "$ERR" '^\[cleanup-follow-up-issue\] sweep_issued: pr=9; excluded=1; possible_duplicates=0$'
  assert_not_grep "T-75 $t75_variant: 再掲として結ばない" "$ERR" 'sweep_issued_relinked:'
done

echo "--- T-76: 起票済みの指摘と出典 (と id) だけが違う完全一致の指摘は転記しない ---"
# renumbered: 後の cycle が id を振り直し、マーカーを付けずに同じ内容で再報告した場合
# other_reviewer: 写しは reviewer も比べるので、reviewer だけが違う指摘は結ばずに転記する
for t76_variant in same_id renumbered other_reviewer; do
  reset_stubs
  r=$(new_root "t76-$t76_variant")
  t76_later_id=F-01; t76_later_reviewer=test-reviewer
  [ "$t76_variant" = renumbered ] && t76_later_id=F-07
  [ "$t76_variant" = other_reviewer ] && t76_later_reviewer=code-quality-reviewer
  put_json "$r" "$CYCLE_A" "$(nb_json "$(nb_finding F-01 a.md 3 test-reviewer '出典だけが違う同じ指摘')")"
  put_json "$r" "$CYCLE_B" "$(nb_json "$(nb_finding "$t76_later_id" a.md 3 "$t76_later_reviewer" '出典だけが違う同じ指摘')" "$(nb_finding F-02 c.md 1 test-reviewer 'cycle B の別の指摘')")"
  jq -n --argjson c "$(comment_obj "$(record_body "$(issued_row5 F-01 a.md:3 "$CYCLE_A")")")" '[[$c]]' > "$GH_API_JSON"
  run_target "$r"
  if [ "$t76_variant" = other_reviewer ]; then
    assert_grep "T-76 other_reviewer: reviewer だけが違う指摘は転記" "$STUB_DIR/body.md" '出典だけが違う同じ指摘'
    assert_grep "T-76 other_reviewer: 転記したのは reviewer が違う写しの側" "$STUB_DIR/body.md" 'code-quality-reviewer'
    assert_grep "T-76 other_reviewer: 別の指摘は転記" "$STUB_DIR/body.md" 'cycle B の別の指摘'
    assert_grep "T-76 other_reviewer: 除外件数 1" "$ERR" '^\[cleanup-follow-up-issue\] sweep_issued: pr=9; excluded=1; possible_duplicates=0$'
    assert_not_grep "T-76 other_reviewer: 写しとして結ばない" "$ERR" 'sweep_issued_relinked:'
    continue
  fi
  assert_not_grep "T-76 $t76_variant: 完全一致のコピーも転記しない" "$STUB_DIR/body.md" '出典だけが違う同じ指摘'
  assert_grep "T-76 $t76_variant: 別の指摘は転記" "$STUB_DIR/body.md" 'cycle B の別の指摘'
  assert_grep "T-76 $t76_variant: 除外件数 2" "$ERR" '^\[cleanup-follow-up-issue\] sweep_issued: pr=9; excluded=2; possible_duplicates=0$'
  assert_grep "T-76 $t76_variant: 起票元以外から結んだ件数に数える" "$ERR" '^\[cleanup-follow-up-issue\] sweep_issued_relinked: pr=9; relinked=1$'
  assert_not_grep "T-76 $t76_variant: 後段の完全一致の集約には残さない" "$ERR" 'deduplicated:'
done

PURGE="$SCRIPT_DIR/../scripts/cleanup-pr-state-purge.sh"
JUDGED_RECORD_REL=".rite/state/follow-up-judged-9.txt"

echo "--- T-77: 判定後に purge が JSON を片付けた PR の再実行は already_processed ---"
# preview は手動 cleanup の既定経路 (ask で --preview-body を付けて呼ぶ)
for t77_variant in plain preview; do
  reset_stubs
  r=$(new_root "t77-$t77_variant")
  t77_args=()
  [ "$t77_variant" = preview ] && t77_args=(--preview-body "$TMP_ROOT/preview-t77.md")
  # --preview-body の有無は出力に差を生まないため、t77_args の組み立てから --preview-body が落ちる退行はここでしか捕まらない（run_target への受け渡しは確かめない）
  if [ "$t77_variant" = preview ]; then
    assert "T-77 $t77_variant: --preview-body を渡す" "--preview-body $TMP_ROOT/preview-t77.md" "${t77_args[*]}"
  fi
  put_json "$r" "9-20260101120000.json" '{"non_blocking_findings":[]}'
  assert "T-77 $t77_variant: 前提: 判定済み記録が無い" "no" "$([ -e "$r/$JUDGED_RECORD_REL" ] && echo yes || echo no)"
  run_target "$r" ${t77_args[@]+"${t77_args[@]}"}
  assert_grep "T-77 $t77_variant: 1 回目は no_findings" "$ERR" 'reason=no_findings; pr=9'
  assert "T-77 $t77_variant: 1 回目で判定済み記録を書く" "pr=9" "$(cat "$r/$JUDGED_RECORD_REL" 2>/dev/null)"
  bash "$PURGE" --pr 9 --state-root "$r" >/dev/null 2>&1
  assert "T-77 $t77_variant: purge で JSON が片付く" "no" "$([ -e "$r/.rite/review-results/9-20260101120000.json" ] && echo yes || echo no)"
  assert "T-77 $t77_variant: purge は判定済み記録を消さない" "yes" "$([ -f "$r/$JUDGED_RECORD_REL" ] && echo yes || echo no)"
  run_target "$r" ${t77_args[@]+"${t77_args[@]}"}
  assert "T-77 $t77_variant: exit 0" "0" "$RC"
  assert_grep "T-77 $t77_variant: already_processed で skip" "$ERR" 'FOLLOW_UP_ISSUE=skipped; reason=already_processed; pr=9$'
  assert_not_grep "T-77 $t77_variant: no_json を出さない" "$ERR" 'reason=no_json'
  assert "T-77 $t77_variant: 起票しない" "0" "$(create_count)"
done

echo "--- T-78: 判定済み記録の内容が不一致・読めないときは no_json ---"
for t78_case in 'pr=90' 'pr=0' 'pr=9x' '' $'pr=9\nextra'; do
  reset_stubs
  r=$(new_root "t78-$(printf '%s' "$t78_case" | tr -c 'a-z0-9' '_')")
  mkdir -p "$r/.rite/state"
  printf '%s' "$t78_case" > "$r/$JUDGED_RECORD_REL"
  run_target "$r"
  assert_grep "T-78 [$t78_case] no_json" "$ERR" 'reason=no_json; pr=9'
  assert_grep "T-78 [$t78_case] WARNING" "$ERR" '判定済み記録'
  assert_not_grep "T-78 [$t78_case] already_processed にしない" "$ERR" 'already_processed'
done
reset_stubs
r=$(new_root t78-dir)
mkdir -p "$r/$JUDGED_RECORD_REL"
run_target "$r"
assert_grep "T-78 記録パスがディレクトリなら no_json" "$ERR" 'reason=no_json; pr=9'
assert_not_grep "T-78 記録パスがディレクトリなら already_processed にしない" "$ERR" 'already_processed'
if [ "$(id -u)" != 0 ]; then
  reset_stubs
  r=$(new_root t78-unreadable)
  mkdir -p "$r/.rite/state"
  printf 'pr=9' > "$r/$JUDGED_RECORD_REL"
  chmod 000 "$r/$JUDGED_RECORD_REL"
  run_target "$r"
  chmod 600 "$r/$JUDGED_RECORD_REL"
  assert_grep "T-78 読めない記録は no_json" "$ERR" 'reason=no_json; pr=9'
  assert_grep "T-78 読めない記録は WARNING" "$ERR" '判定済み記録'
  assert_not_grep "T-78 読めない記録は already_processed にしない" "$ERR" 'already_processed'
else
  echo "  SKIP: T-78 chmod 000 のケースは root では読めてしまうため実行しない"
fi

echo "--- T-79: 判定済み記録があっても先送り欠陥・archive/ の JSON は従来経路 ---"
reset_stubs
r=$(new_root t79-deferred)
mkdir -p "$r/.rite/state"; printf 'pr=9\n' > "$r/$JUDGED_RECORD_REL"
deferred_body '' > "$STUB_DIR/issue-body.md"
export GH_ISSUE_BODY="$STUB_DIR/issue-body.md"
GH_HEAD_OID=$(git_head_commit "$r") || fail "T-79 fixture の commit を作れない"
export GH_HEAD_OID
run_target "$r"
assert_grep "T-79 先送り欠陥は JSON が無くても PR の head で判定して起票する" "$ERR" 'FOLLOW_UP_ISSUE=created; issue=99; existing=0; recorded=0; pr=9'
assert_not_grep "T-79 先送り欠陥ありは already_processed にしない" "$ERR" 'already_processed'
reset_stubs
r=$(new_root t79-archive)
mkdir -p "$r/.rite/state"; printf 'pr=9\n' > "$r/$JUDGED_RECORD_REL"
put_archived "$r" "9-20260101120000.json" "$FINDING_JSON"
run_target "$r"
assert_grep "T-79 archive/ の JSON は和集合から起票" "$ERR" 'FOLLOW_UP_ISSUE=created; issue=99; existing=0; recorded=0; pr=9'
assert_not_grep "T-79 archive/ ありは already_processed にしない" "$ERR" 'already_processed'

echo "--- T-80: 判定できなかった PR は purge 後の再実行でも no_json、SKILL.md は x 相当に置く ---"
for t80_json in '{"non_blocking_findings":null}' '{}'; do
  reset_stubs
  r=$(new_root "t80-$(printf '%s' "$t80_json" | tr -c 'a-z' '_')")
  put_json "$r" "9-20260101120000.json" "$t80_json"
  run_target "$r"
  assert_grep "T-80 [$t80_json] 1 回目は json_undecidable" "$ERR" 'reason=json_undecidable; pr=9'
  assert "T-80 [$t80_json] 判定済み記録を書かない" "no" "$([ -e "$r/$JUDGED_RECORD_REL" ] && echo yes || echo no)"
  bash "$PURGE" --pr 9 --state-root "$r" >/dev/null 2>&1
  assert "T-80 [$t80_json] purge で JSON が片付く" "no" "$([ -e "$r/.rite/review-results/9-20260101120000.json" ] && echo yes || echo no)"
  run_target "$r"
  assert_grep "T-80 [$t80_json] 再実行は no_json" "$ERR" 'reason=no_json; pr=9'
  assert_not_grep "T-80 [$t80_json] already_processed にしない" "$ERR" 'already_processed'
done
assert "T-80 already_processed は created と同じ x 相当行" "1" \
  "$(grep -c '^  | `created` / .*`skipped; reason=already_processed`.* | x 相当 | — |$' "$CLEANUP_MD")"
assert "T-80 already_processed を未完了行に置かない" "0" "$(grep 'already_processed' "$CLEANUP_MD" | grep -c '| 未完了 |')"
assert "T-80 no_json 行は failed 行の直後のまま (同上の参照先)" "1" \
  "$(awk '/^  \| `FOLLOW_UP_ISSUE=failed`（reason 問わず/ { getline nxt; if (nxt ~ /^  \| `skipped; reason=no_json` \| 未完了 \| 同上/) print "ok" }' "$CLEANUP_MD" | grep -c ok)"

echo "--- T-81: 判定済み記録を書けなくても結果は変えず、WARNING と影響を出す ---"
for t81_variant in no_findings created; do
  reset_stubs
  r=$(new_root "t81-$t81_variant")
  if [ "$t81_variant" = no_findings ]; then
    put_json "$r" "9-20260101120000.json" '{"non_blocking_findings":[]}'
    t81_result='skipped; reason=no_findings; pr=9'
    t81_creates=0
  else
    put_json "$r" "9-20260101120000.json" "$FINDING_JSON"
    t81_result='created; issue=99; existing=0; recorded=0; pr=9'
    t81_creates=1
  fi
  # ディレクトリの位置に通常ファイルを置き、mkdir を権限に依らず失敗させる
  printf 'x\n' > "$r/.rite/state"
  run_target "$r"
  assert "T-81 $t81_variant: exit 0" "0" "$RC"
  assert_grep "T-81 $t81_variant: 結果 marker は変わらない" "$ERR" "FOLLOW_UP_ISSUE=${t81_result}\$"
  assert_not_grep "T-81 $t81_variant: failed を出さない" "$ERR" 'FOLLOW_UP_ISSUE=failed'
  assert "T-81 $t81_variant: stdout は結果行 1 行のみ" "[cleanup-follow-up-issue] result=${t81_result}" "$(cat "$OUT")"
  assert "T-81 $t81_variant: 起票回数は変わらない" "$t81_creates" "$(create_count)"
  assert_grep "T-81 $t81_variant: WARNING" "$ERR" '^WARNING: follow-up の判定済み記録を書けません \(PR #9\): '
  assert_grep "T-81 $t81_variant: 原因行を indent 付きで出す" "$ERR" '^  mkdir: '
  assert_grep "T-81 $t81_variant: 影響行" "$ERR" '^  影響: レビュー結果 JSON を片付けた後に cleanup を再実行すると no_json'
  assert "T-81 $t81_variant: WARNING→原因→影響→結果 marker の順" "1" \
    "$(awk -v want="FOLLOW_UP_ISSUE=${t81_result}" '
      /^WARNING: follow-up の判定済み記録を書けません/ { w = NR; next }
      w && NR == w + 1 && /^  mkdir: / { c = NR; next }
      c && NR == c + 1 && /^  影響: / { i = NR; next }
      i && index($0, want) { print "ok"; exit }' "$ERR" | grep -c ok)"
done

echo "--- T-82: reference の follow-up 規則は採否ゲートの出口で根因ごとに起票し、出口が無ければ保留する ---"
# 対象の段落はどちらも物理 1 行なので、件数は行数ではなく出現回数で数える。
_t82_rule='指摘が 0 件になっても、元 Issue の Decision Log に本 PR のレビューが先送りした欠陥があれば候補にし、指摘も先送り欠陥も無ければ判定も起票もしない（条件の正本は `/rite:cleanup` ステップ 6.0）。'
_t82_gate='採否ゲート（`review-adoption-gate.sh --kind followup`）の出口が `file` の判定記録（根因）ごとに follow-up Issue を 1 件起票して全文'
_t82_held='出口が出ていない候補が 1 件でもあれば held として何も起票せず、レビュー結果の退避・削除もしない。'
_t82_count() { grep -oF -- "$1" | wc -l | tr -d ' '; }
for _t82_md in "$PLUGIN_ROOT/references/severity-levels.md" "$PLUGIN_ROOT/references/review-result-schema.md"; do
  _t82_name=$(basename "$_t82_md")
  assert "T-82 $_t82_name: 候補の規則文が 1 回" "1" "$(_t82_count "$_t82_rule" < "$_t82_md")"
  assert "T-82 $_t82_name: 起票は採否ゲートの出口で根因ごとに 1 件" "1" "$(_t82_count "$_t82_gate" < "$_t82_md")"
  assert "T-82 $_t82_name: 出口が出ていなければ held で起票も退避もしない" "1" "$(_t82_count "$_t82_held" < "$_t82_md")"
  assert "T-82 $_t82_name: 却下台帳を読めないときの節が残る" "1" \
    "$(_t82_count '却下台帳か最新のレビュー結果 JSON を読めなければ' < "$_t82_md")"
done
# follow-up を PR ごとに 1 件とする旧契約 (先送り欠陥だけで起票すると読める文を含む) を、利用者向けの文書・
# 設定テンプレートにも残さない
_t82_repo="$(cd "$PLUGIN_ROOT/../.." && pwd)"
for _t82_name in plugins/rite/references/severity-levels.md plugins/rite/references/review-result-schema.md \
    plugins/rite/skills/pr-review/SKILL.md plugins/rite/templates/config/rite-config.yml \
    docs/CONFIGURATION.md docs/SPEC.md; do
  for _t82_old in 'follow-up Issue 1 件へ転記' 'follow-up Issue 1 件へ全文転記' 'one follow-up Issue' \
      '先送りした欠陥があれば follow-up Issue を起票し'; do
    assert "T-82 ${_t82_name}: 旧契約「${_t82_old}」が無い" "0" "$(_t82_count "$_t82_old" < "$_t82_repo/$_t82_name")"
  done
done
assert "T-82 severity-levels.md: 判定不能を候補側へ倒す節が残る" "1" \
  "$(_t82_count '判定不能なものは候補側へ倒す。' < "$PLUGIN_ROOT/references/severity-levels.md")"
assert "T-82 review-result-schema.md: 判定不能を候補側へ倒す節が太字の中に残る" "1" \
  "$(_t82_count '解消済みと判定された指摘は除外する（判定不能は候補側へ倒す）**' < "$PLUGIN_ROOT/references/review-result-schema.md")"
assert "T-82 review-result-schema.md: read 側の扱いから実測必須ゲートへのリンクが残る" "1" \
  "$(grep -F -- '**read 側の扱い**' "$PLUGIN_ROOT/references/review-result-schema.md" | _t82_count '](./severity-levels.md#実測必須ゲート-measured-confirmed-gate)')"
assert "T-82 正本 §6.0 の規則が残る" "1" \
  "$(awk '/^### 6\.0 /{ f = 1; next } f && /^### /{ exit } f' "$CLEANUP_MD" | _t82_count '指摘が 0 件でも先送り欠陥があれば候補にする。')"

# ---------------------------------------------------------------------------
# 採否ゲートの出口で起票を決める (判定記録を明示的に置く。ADOPT_MODE=manual)
# 候補: 9-20260101120000.json の F-01 と F-05（a.md / b.md の指摘）と、Decision Log の D-01 / D-04
# ---------------------------------------------------------------------------
ADOPT_JSON_NAME="9-20260101120000.json"
C_F01="${ADOPT_JSON_NAME}#F-01"
C_F05="${ADOPT_JSON_NAME}#F-05"
# $1=ids の JSON 配列、$2=既定の記録 (ADOPT・pre_existing・受入条件あり) に上書きする欄の JSON
rec() {
  jq -nc --argjson ids "$1" --argjson extra "${2:-"{}"}" --arg c "$PR_CONTRACT_LINE" '
    {ids: $ids, V: true, C: false, T: false, contract: {ref: "pr", text: $c},
     evidence: "再現: 空の入力で exit 0 になる", origin: "pre_existing", present: true, tracker: null,
     prior: null, reason: "", proposition: null, acceptance: "Given 空の入力, When 実行する, Then exit 1 になる"} + $extra'
}
REJECT_FIELDS='{"V": false, "contract": null, "evidence": "", "reason": "文書化された挙動 / 仕様が変わったら再検討"}'
RESOLVED_FIELDS='{"present": false, "evidence": "マージ後 HEAD で修正済み"}'
UNKNOWN_FIELDS='{"V": "unknown", "contract": null, "evidence": "", "reason": "再現できていない"}'
# $1=state_root、残り=記録 (1 行 1 JSON)。既定の置き場 (<state-root>/.rite/state/adoption-9-followup.json) に書く
write_adoption() {
  local root="$1"; shift
  mkdir -p "$root/.rite/state"
  printf '%s\n' "$@" | jq -s --arg h "${ADOPT_HEAD:-$TEST_HEAD}" '{adoption: {head: $h, records: .}}' > "$root/.rite/state/adoption-9-followup.json"
}
# $1=名前。state root を r に置く (GH_ISSUE_BODY を export するのでサブシェルで呼ばない)
adopt_root() {
  r=$(new_root "$1")
  put_json "$r" "$ADOPT_JSON_NAME" "$TWO_FINDING_JSON"
  deferred_body '' > "$STUB_DIR/issue-body.md"
  export GH_ISSUE_BODY="$STUB_DIR/issue-body.md"
}
ROOT_A="[\"$C_F01\",\"D-01\"]"
ROOT_B="[\"$C_F05\",\"D-04\"]"
MARKER_A="<!-- [rite-follow-up-from-pr:9:${C_F01},D-01] -->"
MARKER_B="<!-- [rite-follow-up-from-pr:9:${C_F05},D-04] -->"
HOLD_REL=".rite/state/adoption-hold-9-followup.json"

echo "--- T-83: 候補の列挙 (AC-3: 旧形式の先送り行も終端にせず候補にする) ---"
reset_stubs
ADOPT_MODE=manual
adopt_root t83
PATH="$TMP_ROOT/bin:$PATH" bash "$TARGET" --state-root "$r" --pr 9 --owner acme --repo demo --source-issue 42 \
  --list-candidates "$TMP_ROOT/t83-cands.json" >"$OUT" 2>"$ERR"
assert "T-83 exit 0" "0" "$?"
assert "T-83 候補 id (指摘は出典 JSON + id、先送り行は D-NN)" "$C_F01 $C_F05 D-01 D-04" \
  "$(jq -r '[.candidates[].id] | join(" ")' "$TMP_ROOT/t83-cands.json")"
assert "T-83 先送り行は全文と出典つき" "- 2026-01-01 D-01: first defect / Reason: r1 / Impact: i1|Issue #42 Decision Log (Section 9)" \
  "$(jq -r '.candidates[] | select(.id == "D-01") | "\(.text)|\(.source)"' "$TMP_ROOT/t83-cands.json")"
assert "T-83 指摘は全文と出典つき" "残存する指摘の本文|$ADOPT_JSON_NAME" \
  "$(jq -r --arg i "$C_F01" '.candidates[] | select(.id == $i) | "\(.finding.description)|\(.source)"' "$TMP_ROOT/t83-cands.json")"
assert "T-83 対象 commit と判定記録の置き場" "$TEST_HEAD|$r/.rite/state/adoption-9-followup.json" \
  "$(jq -r '"\(.head)|\(.adoption)"' "$TMP_ROOT/t83-cands.json")"
assert_grep "T-83 列挙 marker" "$ERR" "^\[CONTEXT\] FOLLOW_UP_CANDIDATES=listed; count=4; deferred=2; head=${TEST_HEAD}; file=$TMP_ROOT/t83-cands.json; pr=9$"
assert_not_grep "T-83 列挙は起票結果の marker を出さない" "$ERR" 'FOLLOW_UP_ISSUE='
assert "T-83 列挙は起票しない" "0" "$(create_count)"
assert "T-83 列挙は判定済み記録を書かない" "no" "$([ -e "$r/$JUDGED_RECORD_REL" ] && echo yes || echo no)"
assert_not_grep "T-83 列挙は既存 follow-up を検索しない" "$GH_LOG" 'labels=follow-up'
# 先送り行に記録が無ければ、旧形式の行でも処分済みにせず保留する
write_adoption "$r" "$(rec "[\"$C_F01\",\"$C_F05\"]")"
run_target "$r"
assert_grep "T-83 先送り行に記録が無ければ保留 (終端にしない)" "$ERR" 'FOLLOW_UP_ISSUE=held; reason=adoption_error;'
assert_grep "T-83 保留理由は記録の無い候補" "$r/$HOLD_REL" 'candidates_uncovered'
assert "T-83 起票しない" "0" "$(create_count)"
# 0 件で終える経路は空の一覧と理由を書く
r=$(new_root t83-empty)
put_json "$r" "$ADOPT_JSON_NAME" '{"non_blocking_findings":[]}'
unset GH_ISSUE_BODY
PATH="$TMP_ROOT/bin:$PATH" bash "$TARGET" --state-root "$r" --pr 9 --owner acme --repo demo --source-issue 42 \
  --list-candidates "$TMP_ROOT/t83-empty.json" >"$OUT" 2>"$ERR"
assert "T-83 0 件は空の一覧と理由" '{"candidates":[],"reason":"no_findings"}' "$(jq -c . "$TMP_ROOT/t83-empty.json")"
assert_grep "T-83 0 件の列挙 marker" "$ERR" '^\[CONTEXT\] FOLLOW_UP_CANDIDATES=listed; count=0; reason=no_findings; '
assert "T-83 0 件の列挙も判定済み記録を書かない" "no" "$([ -e "$r/$JUDGED_RECORD_REL" ] && echo yes || echo no)"

echo "--- T-84: 判定記録が無い / ERROR / DIAGNOSE は起票せず保留する (AC-5) ---"
for t84_case in no_records error diagnose preview; do
  reset_stubs
  ADOPT_MODE=manual
  adopt_root "t84-$t84_case"
  t84_args=()
  case "$t84_case" in
    no_records|preview) t84_reason=no_records ;;
    error) write_adoption "$r" "$(rec "$ROOT_A")"; t84_reason=adoption_error ;;
    diagnose) write_adoption "$r" "$(rec "$ROOT_A" "$UNKNOWN_FIELDS")" "$(rec "$ROOT_B")"; t84_reason=undecided ;;
  esac
  [ "$t84_case" = preview ] && t84_args=(--preview-body "$TMP_ROOT/t84-preview.md")
  rm -f "$TMP_ROOT/t84-preview.md"
  run_target "$r" ${t84_args[@]+"${t84_args[@]}"}
  assert "T-84 $t84_case exit 0" "0" "$RC"
  assert_grep "T-84 $t84_case held marker (declined でも skipped でもない)" "$ERR" \
    "^\[CONTEXT\] FOLLOW_UP_ISSUE=held; reason=${t84_reason}; hold_file=$r/$HOLD_REL; pr=9$"
  assert "T-84 $t84_case stdout は held" "[cleanup-follow-up-issue] result=held; reason=${t84_reason}; hold_file=$r/$HOLD_REL; pr=9" "$(cat "$OUT")"
  assert "T-84 $t84_case 起票 helper を呼ばない" "0" "$(create_count)"
  assert "T-84 $t84_case 判定済み記録を書かない" "no" "$([ -e "$r/$JUDGED_RECORD_REL" ] && echo yes || echo no)"
  assert_grep "T-84 $t84_case 再開は hold ファイルの resume に従うと案内する" "$ERR" "hold ファイル \(hold_file=$r/$HOLD_REL\) の resume"
  assert_not_grep "T-84 $t84_case 判定記録を補う固定の案内を出さない" "$ERR" 'を補って /rite:cleanup 9 を再実行してください'
  assert_not_grep "T-84 $t84_case 既存 follow-up の検索もしない (ゲートが先)" "$GH_LOG" 'labels=follow-up'
  assert_not_grep "T-84 $t84_case label も作らない" "$GH_LOG" 'label create'
  assert_not_grep "T-84 $t84_case 元 Issue へコメントしない" "$GH_LOG" 'issue comment'
  assert "T-84 $t84_case preview 本文を書かない" "no" "$([ -e "$TMP_ROOT/t84-preview.md" ] && echo yes || echo no)"
  assert "T-84 $t84_case hold ファイルに対象 commit" "$TEST_HEAD" "$(jq -r '.head' "$r/$HOLD_REL")"
  assert_grep "T-84 $t84_case hold ファイルに再開位置" "$r/$HOLD_REL" '/rite:cleanup 9'
  assert "T-84 $t84_case hold ファイルに出典 (レビュー結果 JSON)" "$r/.rite/review-results/$ADOPT_JSON_NAME" "$(jq -r '.review_result' "$r/$HOLD_REL")"
done
# 保留した候補は全文で残る (no_records は全候補、DIAGNOSE は未処分の根因だけ)
r="$TMP_ROOT/root-t84-no_records"
assert "T-84 no_records は全候補を保留" "$C_F01 $C_F05 D-01 D-04" "$(jq -r '.held_ids | join(" ")' "$r/$HOLD_REL")"
assert "T-84 保留した指摘の全文" "残存する指摘の本文|残存する提案|a.md|3" \
  "$(jq -r --arg i "$C_F01" '.candidates[] | select(.id == $i) | .finding | "\(.description)|\(.suggestion)|\(.file)|\(.line)"' "$r/$HOLD_REL")"
assert "T-84 保留した先送り行の全文と出典" "- 2026-01-01 D-04: second defect / Reason: r4 / Impact: i4|Issue #42 Decision Log (Section 9)" \
  "$(jq -r '.candidates[] | select(.id == "D-04") | "\(.text)|\(.source)"' "$r/$HOLD_REL")"
assert "T-84 diagnose は未処分の根因だけを保留" "$C_F01 D-01" "$(jq -r '.held_ids | join(" ")' "$TMP_ROOT/root-t84-diagnose/$HOLD_REL")"

echo "--- T-84b: ゲート自体が失敗した / ゲートの出力を読めないときは hold_file=none で保留する ---"
reset_stubs
ADOPT_MODE=manual
adopt_root t84b-gate-failed
# hold ファイルの一時ファイルの位置をディレクトリにして、ゲートの hold 保存を失敗させる
mkdir -p "$r/$HOLD_REL.tmp"
run_target "$r"
assert "T-84b gate_failed exit 0" "0" "$RC"
assert_grep "T-84b ゲートが rc=1 で終われば gate_failed_rc1" "$ERR" '^\[CONTEXT\] FOLLOW_UP_ISSUE=held; reason=gate_failed_rc1; hold_file=none; pr=9$'
assert "T-84b gate_failed stdout は held" "[cleanup-follow-up-issue] result=held; reason=gate_failed_rc1; hold_file=none; pr=9" "$(cat "$OUT")"
assert_grep "T-84b gate_failed は hold ファイルが保存されていないことを示す" "$ERR" 'hold ファイルは保存されていません'
assert_grep "T-84b gate_failed はゲートの失敗理由を示す" "$ERR" '採否ゲートが rc=1 で失敗しました'
assert "T-84b gate_failed 起票しない" "0" "$(create_count)"
assert "T-84b gate_failed 判定済み記録を書かない" "no" "$([ -e "$r/$JUDGED_RECORD_REL" ] && echo yes || echo no)"
assert_not_grep "T-84b gate_failed 既存 follow-up を検索しない" "$GH_LOG" 'labels=follow-up'
# ゲートを差し替えた配置 (helper の写しの隣に偽のゲートを置く) で、読めない出力を固定する
T84B_FAKE="$TMP_ROOT/fake-plugin/hooks/scripts"
mkdir -p "$T84B_FAKE"
cp "$TARGET" "$T84B_FAKE/cleanup-follow-up-issue.sh"
ln -s "$(cd "$SCRIPT_DIR/../scripts/lib" && pwd)" "$T84B_FAKE/lib"
ln -s "$(cd "$SCRIPT_DIR/.." && pwd)/control-char-neutralize.sh" "$T84B_FAKE/../control-char-neutralize.sh"
cat > "$T84B_FAKE/review-adoption-gate.sh" <<'GATE'
#!/bin/bash
printf '%s\n' "$FAKE_GATE_OUT"
exit "$FAKE_GATE_RC"
GATE
for t84b_case in '0:{}' '3:not-json{'; do
  reset_stubs
  r=$(new_root "t84b-invalid-${t84b_case%%:*}")
  put_json "$r" "9-20260101120000.json" "$FINDING_JSON"
  FAKE_GATE_RC="${t84b_case%%:*}" FAKE_GATE_OUT="${t84b_case#*:}" PATH="$TMP_ROOT/bin:$PATH" \
    bash "$T84B_FAKE/cleanup-follow-up-issue.sh" --state-root "$r" --pr 9 --owner acme --repo demo --base develop \
    --create-script "$CREATE_STUB" >"$OUT" 2>"$ERR"
  assert_grep "T-84b ゲート rc=${t84b_case%%:*} の読めない出力は gate_output_invalid" "$ERR" \
    '^\[CONTEXT\] FOLLOW_UP_ISSUE=held; reason=gate_output_invalid; hold_file=none; pr=9$'
  assert_grep "T-84b gate_output_invalid は出力を読めず hold ファイルを確認できないことを示す (rc=${t84b_case%%:*})" "$ERR" \
    '採否ゲートの出力を読めません。hold ファイルが保存されたかを確認できません'
  assert "T-84b gate_output_invalid 起票しない (rc=${t84b_case%%:*})" "0" "$(create_count)"
  assert "T-84b gate_output_invalid 判定済み記録を書かない (rc=${t84b_case%%:*})" "no" "$([ -e "$r/$JUDGED_RECORD_REL" ] && echo yes || echo no)"
done

echo "--- T-85: 根因ごとに 1 件起票し、再実行で増えない (AC-1 / AC-4) ---"
reset_stubs
ADOPT_MODE=manual
export CREATE_SEQ=1
adopt_root t85
write_adoption "$r" "$(rec "$ROOT_A")" "$(rec "$ROOT_B")"
run_target "$r"
assert_grep "T-85 根因 2 件を起票" "$ERR" '^\[CONTEXT\] FOLLOW_UP_ISSUE=created; issue=60,61; existing=0; recorded=0; pr=9$'
assert "T-85 起票は根因の数" "2" "$(create_count)"
assert "T-85 1 件目の先頭行は根因 A の marker" "$MARKER_A" "$(head -1 "$STUB_DIR/body-60.md")"
assert "T-85 2 件目の先頭行は根因 B の marker" "$MARKER_B" "$(head -1 "$STUB_DIR/body-61.md")"
assert_grep "T-85 根因 A に束ねた指摘" "$STUB_DIR/body-60.md" 'a.md:3'
assert_not_grep "T-85 根因 A に別の根因の指摘を混ぜない" "$STUB_DIR/body-60.md" 'b.md:9'
assert "T-85 根因 A に束ねた先送り行" "- 2026-01-01 D-01: first defect / Reason: r1 / Impact: i1" "$(deferred_lines "$STUB_DIR/body-60.md")"
# AC-4: 契約の引用・根拠・受入条件
assert "T-85 契約の節" "1" "$(grep -cxF '## 契約' "$STUB_DIR/body-60.md")"
assert_grep "T-85 契約の引用元" "$STUB_DIR/body-60.md" '^- 引用元: `pr`$'
assert_grep "T-85 契約の原文を引用する" "$STUB_DIR/body-60.md" "^> ${PR_CONTRACT_LINE}\$"
assert "T-85 根拠" "再現: 空の入力で exit 0 になる" "$(awk '/^## 根拠$/ { getline; getline; print; exit }' "$STUB_DIR/body-60.md")"
assert "T-85 受入条件" "- [ ] Given 空の入力, When 実行する, Then exit 1 になる" "$(awk '/^## 受入条件$/ { getline; getline; print; exit }' "$STUB_DIR/body-60.md")"
assert_grep "T-85 対象 commit" "$STUB_DIR/body-60.md" "^- 対象 commit: \`${TEST_HEAD}\`\$"
assert_grep "T-85 元 Issue へ起票した番号をまとめてコメント" "$GH_COMMENT_LOG" 'issue comment 42'
assert "T-85 判定済み記録" "pr=9" "$(cat "$r/$JUDGED_RECORD_REL" 2>/dev/null)"
run_target "$r"
assert_grep "T-85 再実行は起票済み" "$ERR" '^\[CONTEXT\] FOLLOW_UP_ISSUE=skipped; reason=already_exists; issue=60,61; pr=9$'
assert "T-85 再実行で増えない" "2" "$(create_count)"
# 2 根因のうち 1 件だけ起票済みなら、残り 1 件だけを起票する
reset_stubs
ADOPT_MODE=manual
export CREATE_SEQ=1
adopt_root t85-one
write_adoption "$r" "$(rec "$ROOT_A")" "$(rec "$ROOT_B")"
jq -n --arg b "$MARKER_A"$'\n本文' '[[{number: 50, body: $b}]]' > "$GH_LIST_JSON"
run_target "$r"
assert_grep "T-85 起票済みの根因は数え、残りだけを起票" "$ERR" '^\[CONTEXT\] FOLLOW_UP_ISSUE=created; issue=60; existing=1; recorded=0; pr=9$'
assert "T-85 残り 1 件だけ" "1" "$(create_count)"
assert "T-85 起票したのは根因 B" "$MARKER_B" "$(head -1 "$STUB_DIR/body-60.md")"
run_target "$r"
assert "T-85 その再実行でも増えない" "1" "$(create_count)"
# 根因 key は ids を整列して連結する (記録の ids の並びが変わっても同じ根因)
reset_stubs
ADOPT_MODE=manual
adopt_root t85-order
write_adoption "$r" "$(rec "[\"D-01\",\"$C_F01\"]")" "$(rec "$ROOT_B" "$REJECT_FIELDS")"
jq -n --arg b "$MARKER_A" '[[{number: 50, body: $b}]]' > "$GH_LIST_JSON"
run_target "$r"
assert_grep "T-85 ids の並びが違っても同じ根因" "$ERR" 'FOLLOW_UP_ISSUE=skipped; reason=already_exists; issue=50; pr=9'
# 再実行で候補が解消済みになり記録の ids が減っても、ids が重なる起票済みの根因は増やさない
adopt_root t85-shrink
write_adoption "$r" "$(rec "[\"D-01\"]")" "$(rec "$ROOT_B")"
jq -n --arg a "$MARKER_A" --arg b "$MARKER_B" '[[{number: 50, body: $a}, {number: 51, body: $b}]]' > "$GH_LIST_JSON"
run_target "$r" --exclude-ids "$C_F01"
assert_grep "T-85 ids が減った根因も起票済み" "$ERR" 'FOLLOW_UP_ISSUE=skipped; reason=already_exists; issue=50,51; pr=9'
assert "T-85 ids が減っても増えない" "0" "$(create_count)"
# 一部の起票に失敗したら failed にし、再実行で残りだけを起票する
reset_stubs
ADOPT_MODE=manual
export CREATE_SEQ=1
adopt_root t85-partial
write_adoption "$r" "$(rec "$ROOT_A")" "$(rec "$ROOT_B")"
cat > "$TMP_ROOT/create-second-fails.sh" <<'STUB'
#!/bin/bash
[ "$(wc -l < "${STUB_DIR}/create_count")" -ge 1 ] && { echo 1 >> "${STUB_DIR}/create_attempts"; echo "simulated failure" >&2; exit 1; }
exec bash "$CREATE_STUB_REAL" "$@"
STUB
export CREATE_STUB_REAL="$CREATE_STUB"
run_target "$r" --create-script "$TMP_ROOT/create-second-fails.sh"
unset CREATE_STUB_REAL
assert_grep "T-85 一部失敗は failed (起票できた番号つき)" "$ERR" '^\[CONTEXT\] FOLLOW_UP_ISSUE=failed; reason=create_api; issue=60; pr=9$'
assert "T-85 一部失敗は判定済み記録を書かない" "no" "$([ -e "$r/$JUDGED_RECORD_REL" ] && echo yes || echo no)"
run_target "$r"
assert_grep "T-85 再実行は残りだけ" "$ERR" '^\[CONTEXT\] FOLLOW_UP_ISSUE=created; issue=61; existing=1; recorded=0; pr=9$'
assert "T-85 合計は根因の数" "2" "$(create_count)"

echo "--- T-86: 保留の後に判定記録を補って再実行すると保留分だけ起票する (AC-6) ---"
reset_stubs
ADOPT_MODE=manual
export CREATE_SEQ=1
adopt_root t86
write_adoption "$r" "$(rec "$ROOT_A")" "$(rec "$ROOT_B" "$REJECT_FIELDS")"
run_target "$r"
assert_grep "T-86 1 回目は根因 A だけ起票 (B は REJECT)" "$ERR" '^\[CONTEXT\] FOLLOW_UP_ISSUE=created; issue=60; existing=0; recorded=1; pr=9$'
rm -f "$r/$JUDGED_RECORD_REL"
write_adoption "$r" "$(rec "$ROOT_A")" "$(rec "$ROOT_B" "$UNKNOWN_FIELDS")"
run_target "$r"
assert_grep "T-86 未処分が出たら保留" "$ERR" 'FOLLOW_UP_ISSUE=held; reason=undecided;'
assert "T-86 保留中は増えない" "1" "$(create_count)"
assert "T-86 保留は判定済み記録を書かない (再実行を already_processed にしない)" "no" "$([ -e "$r/$JUDGED_RECORD_REL" ] && echo yes || echo no)"
write_adoption "$r" "$(rec "$ROOT_A")" "$(rec "$ROOT_B")"
run_target "$r"
assert_grep "T-86 補った後は保留分だけ起票、起票済みの根因は増えない" "$ERR" '^\[CONTEXT\] FOLLOW_UP_ISSUE=created; issue=61; existing=1; recorded=0; pr=9$'
assert "T-86 合計 2 件" "2" "$(create_count)"
assert "T-86 決定した再実行は hold ファイルを消す" "no" "$([ -e "$r/$HOLD_REL" ] && echo yes || echo no)"
# 判定後の state 整理 (purge) を経た再実行も、判定記録が残るので増えない
bash "$PURGE" --pr 9 --state-root "$r" >/dev/null 2>&1
assert "T-86 purge は follow-up の判定記録を残す" "yes" "$([ -f "$r/.rite/state/adoption-9-followup.json" ] && echo yes || echo no)"
run_target "$r"
assert_grep "T-86 purge 後の再実行は起票済み" "$ERR" 'FOLLOW_UP_ISSUE=skipped; reason=already_exists; issue=60,61; pr=9'
assert "T-86 purge 後の再実行でも増えない" "2" "$(create_count)"

# 最新の JSON が指摘 0 件だと purge で消え、対象 commit が変わる。記録の head を列挙し直した値に合わせるまで保留し、
# 合わせた後の再実行は起票済みの根因を増やさない
reset_stubs
ADOPT_MODE=manual
export CREATE_SEQ=1
adopt_root t86-head
T86_NEW_HEAD="fedcba9876543210fedcba9876543210fedcba98"
put_json "$r" "9-20260102120000.json" "{\"commit_sha\":\"$T86_NEW_HEAD\",\"non_blocking_findings\":[]}"
ADOPT_HEAD="$T86_NEW_HEAD" write_adoption "$r" "$(rec "$ROOT_A")" "$(rec "$ROOT_B")"
run_target "$r"
assert_grep "T-86 head: 最新 JSON の commit で起票" "$ERR" '^\[CONTEXT\] FOLLOW_UP_ISSUE=created; issue=60,61; existing=0; recorded=0; pr=9$'
bash "$PURGE" --pr 9 --state-root "$r" >/dev/null 2>&1
assert "T-86 head: purge は指摘 0 件の最新 JSON を消す" "no" "$([ -e "$r/.rite/review-results/9-20260102120000.json" ] && echo yes || echo no)"
run_target "$r"
assert_grep "T-86 head: 記録の head が古ければ保留" "$ERR" 'FOLLOW_UP_ISSUE=held; reason=adoption_error;'
assert_grep "T-86 head: 保留理由は head_mismatch" "$r/$HOLD_REL" 'head_mismatch'
PATH="$TMP_ROOT/bin:$PATH" bash "$TARGET" --state-root "$r" --pr 9 --owner acme --repo demo --source-issue 42 \
  --list-candidates "$TMP_ROOT/t86-cands.json" >/dev/null 2>&1
assert "T-86 head: 列挙し直した head は残った JSON の commit" "$TEST_HEAD" "$(jq -r '.head' "$TMP_ROOT/t86-cands.json")"
ADOPT_HEAD="$(jq -r '.head' "$TMP_ROOT/t86-cands.json")" write_adoption "$r" "$(rec "$ROOT_A")" "$(rec "$ROOT_B")"
run_target "$r"
assert_grep "T-86 head: head を合わせた再実行は起票済み" "$ERR" 'FOLLOW_UP_ISSUE=skipped; reason=already_exists; issue=60,61; pr=9'
assert "T-86 head: 増えない" "2" "$(create_count)"

echo "--- T-87: 調査として引き受けた DIAGNOSE は調査 Issue を 1 件起票する (AC-8) ---"
reset_stubs
ADOPT_MODE=manual
adopt_root t87
t87_fields=$(jq -c '. + {investigate: true, proposition: {claim: "空の入力が通る", reach: "tool \"\" を実行する", reach_source: "a.md:3", done: "exit code を観測した"}}' <<< "$UNKNOWN_FIELDS")
write_adoption "$r" "$(rec "[\"$C_F01\",\"$C_F05\",\"D-01\",\"D-04\"]" "$t87_fields")"
run_target "$r"
assert_grep "T-87 調査 Issue を 1 件" "$ERR" '^\[CONTEXT\] FOLLOW_UP_ISSUE=created; issue=99; existing=0; recorded=0; pr=9$'
assert "T-87 create 1 回" "1" "$(create_count)"
assert "T-87 タイトルは調査" "follow-up: PR #9 の調査（残存する指摘の本文）" "$(jq -r '.issue.title' "$STUB_DIR/args.json")"
assert_grep "T-87 命題" "$STUB_DIR/body.md" '^- 命題: 空の入力が通る$'
assert_grep "T-87 到達条件とその出所" "$STUB_DIR/body.md" '^- 到達条件: tool "" を実行する（出所: a.md:3）$'
assert_grep "T-87 完了条件" "$STUB_DIR/body.md" '^- 完了条件: exit code を観測した$'
assert_grep "T-87 受入条件" "$STUB_DIR/body.md" '^- \[ \] Given 空の入力, When 実行する, Then exit 1 になる$'
assert_grep "T-87 未確定の根拠は理由を書く" "$STUB_DIR/body.md" '^未確定: 再現できていない$'
assert_grep "T-87 採否の出口" "$STUB_DIR/body.md" '^- 採否: DIAGNOSE / investigate（origin=pre_existing）$'

echo "--- T-88: REJECT / RESOLVED / LINK は起票せず、件数を marker に出す ---"
reset_stubs
ADOPT_MODE=manual
adopt_root t88
write_adoption "$r" "$(rec "[\"$C_F01\"]" "$REJECT_FIELDS")" "$(rec "[\"$C_F05\"]" "$RESOLVED_FIELDS")" "$(rec '["D-01","D-04"]' '{"tracker": 7}')"
run_target "$r"
assert_grep "T-88 record だけなら all_recorded" "$ERR" '^\[CONTEXT\] FOLLOW_UP_ISSUE=skipped; reason=all_recorded; recorded=3; pr=9$'
assert "T-88 起票しない" "0" "$(create_count)"
assert_not_grep "T-88 既存 follow-up を検索しない" "$GH_LOG" 'labels=follow-up'
assert "T-88 判定済み記録を書く" "pr=9" "$(cat "$r/$JUDGED_RECORD_REL" 2>/dev/null)"
assert_grep "T-88 LINK は追跡先の状態を読む" "$GH_LOG" '^gh issue view 7 --json state --jq .state$'
# CLOSED の追跡先は LINK にならず、記録どおり ADOPT で起票する
reset_stubs
ADOPT_MODE=manual
export GH_TRACKER_STATE=CLOSED
adopt_root t88-closed
write_adoption "$r" "$(rec "[\"$C_F01\"]" "$REJECT_FIELDS")" "$(rec "[\"$C_F05\"]" "$RESOLVED_FIELDS")" "$(rec '["D-01","D-04"]' '{"tracker": 7}')"
run_target "$r"
assert_grep "T-88 CLOSED の追跡先は起票し、record の件数も出す" "$ERR" '^\[CONTEXT\] FOLLOW_UP_ISSUE=created; issue=99; existing=0; recorded=2; pr=9$'
assert "T-88 CLOSED 起票は先送り行の根因だけ" "<!-- [rite-follow-up-from-pr:9:D-01,D-04] -->" "$(head -1 "$STUB_DIR/body.md")"

echo "--- T-89: 対象 commit は basename の降順で最初に読める commit_sha ---"
reset_stubs
r=$(new_root t89)
put_json "$r" "9-20260101120000.json" '{"commit_sha":"aaa1","non_blocking_findings":[{"id":"F-01","description":"x"}]}'
put_json "$r" "9-20260102120000.json" '{"commit_sha":"bbb2","non_blocking_findings":[]}'
PATH="$TMP_ROOT/bin:$PATH" bash "$TARGET" --state-root "$r" --pr 9 --owner acme --repo demo \
  --list-candidates "$TMP_ROOT/t89.json" >/dev/null 2>&1
assert "T-89 最新の JSON (指摘 0 件でも) の commit_sha" "bbb2|$r/.rite/review-results/9-20260102120000.json" "$(jq -r '"\(.head)|\(.review_result)"' "$TMP_ROOT/t89.json")"
put_json "$r" "9-20260103120000.json" 'not-json{'
PATH="$TMP_ROOT/bin:$PATH" bash "$TARGET" --state-root "$r" --pr 9 --owner acme --repo demo \
  --list-candidates "$TMP_ROOT/t89.json" >/dev/null 2>&1
assert "T-89 最新が読めなければ次に新しい JSON" "bbb2" "$(jq -r '.head' "$TMP_ROOT/t89.json")"
mkdir -p "$r/.rite/review-results/archive"
mv "$r/.rite/review-results/9-20260102120000.json" "$r/.rite/review-results/archive/"
PATH="$TMP_ROOT/bin:$PATH" bash "$TARGET" --state-root "$r" --pr 9 --owner acme --repo demo \
  --list-candidates "$TMP_ROOT/t89.json" >/dev/null 2>&1
assert "T-89 archive/ の JSON も読む" "bbb2" "$(jq -r '.head' "$TMP_ROOT/t89.json")"

echo "--- T-90: cleanup SKILL.md の判定記録と held の配線 ---"
t90_section=$(awk '/^### 6\.0 /{ f = 1 } f && /^## ステップ 7/{ exit } f' "$CLEANUP_MD")
assert "T-90 判定記録の節が 6.0.V と 6.0.C の間にある" "1" \
  "$(printf '%s\n' "$t90_section" | awk '/^#### 6\.0\.V /{ v = NR } /^#### 6\.0\.A /{ a = NR } /^#### 6\.0\.C /{ c = NR } END { print (v && a && c && v < a && a < c) ? 1 : 0 }')"
assert "T-90 列挙は --list-candidates で呼ぶ" "1" "$(printf '%s\n' "$t90_section" | grep -c -- '--list-candidates "${TMPDIR:-/tmp}/rite-follow-up-candidates-{pr_number}.json"')"
assert "T-90 起票の呼び出しは --base と --adoption を渡す" "2" "$(printf '%s\n' "$t90_section" | grep -cE -- '--base "origin/\{base_branch\}"|--adoption "\$_state_root/\.rite/state/adoption-\{pr_number\}-followup\.json"')"
assert "T-90 列挙と起票に同じ --exclude-ids を渡す" "2" "$(printf '%s\n' "$t90_section" | grep -cF -- '--exclude-ids "{resolved_ids_csv}"')"
assert "T-90 保留は state 削除の held で判定し、ステップ 7 を実行しない" "1" "$(printf '%s\n' "$t90_section" | grep -cF '`[CONTEXT] PR_STATE_PURGE=held` を出す。このときはステップ 7 を実行せず')"
assert "T-90 hold ファイルの無い保留では state 削除もステップ 7 も実行しない" "1" "$(printf '%s\n' "$t90_section" | grep -cF 'hold_file=none` を出したとき（ゲート自体が失敗し hold ファイルが無い）で、このときは state 削除もステップ 7 も実行しない')"
assert "T-90 完了報告の held 行は未完了" "1" "$(grep -c '^  | `FOLLOW_UP_ISSUE=held` | 未完了 |' "$CLEANUP_MD")"
assert "T-90 all_recorded は x 相当" "1" "$(grep -c '^  | `created` / .*`skipped; reason=all_recorded`.* | x 相当 | — |$' "$CLEANUP_MD")"

echo "--- T-91: 採否ゲートが保留した候補は --exclude-ids で除かず、RESOLVED の記録で処分する ---"
T91_INFO='^INFO: 採否ゲートが保留した候補は解消済みでも除外せず候補に残します'
# 記録なしで保留した後、再検証がその 1 件を解消済みと判定しても、列挙にも起票実行にも残る
reset_stubs
ADOPT_MODE=manual
adopt_root t91
run_target "$r"
assert_grep "T-91 前提: 記録が無ければ保留" "$ERR" 'FOLLOW_UP_ISSUE=held; reason=no_records;'
assert_grep "T-91 前提: 保留した候補に解消済みにする指摘がある" "$r/$HOLD_REL" "$C_F01"
PATH="$TMP_ROOT/bin:$PATH" bash "$TARGET" --state-root "$r" --pr 9 --owner acme --repo demo --source-issue 42 \
  --exclude-ids "$C_F01" --list-candidates "$TMP_ROOT/t91-cands.json" >"$OUT" 2>"$ERR"
assert "T-91 列挙: 保留した候補は除外指定があっても残る" "$C_F01 $C_F05 D-01 D-04" \
  "$(jq -r '[.candidates[].id] | join(" ")' "$TMP_ROOT/t91-cands.json")"
assert_grep "T-91 列挙: 残した id を INFO で出す" "$ERR" "${T91_INFO}.*${C_F01}"
assert_not_grep "T-91 列挙: 除外拒否の marker は出さない" "$ERR" 'FOLLOW_UP_EXCLUDE_AMBIGUOUS'
write_adoption "$r" "$(rec "[\"$C_F01\"]" "$RESOLVED_FIELDS")" "$(rec "[\"$C_F05\",\"D-01\",\"D-04\"]")"
run_target "$r" --exclude-ids "$C_F01"
assert_grep "T-91 起票: 残した候補は RESOLVED で処分し、保留が解けて残りを起票する" "$ERR" \
  '^\[CONTEXT\] FOLLOW_UP_ISSUE=created; issue=99; existing=0; recorded=1; pr=9$'
assert_grep "T-91 起票: 残した id を INFO で出す" "$ERR" "${T91_INFO}.*${C_F01}"
assert "T-91 起票: 決定した実行は hold ファイルを消す" "no" "$([ -e "$r/$HOLD_REL" ] && echo yes || echo no)"
# hold ファイルが無ければ従来どおり除外する
reset_stubs
adopt_root t91-nohold
PATH="$TMP_ROOT/bin:$PATH" bash "$TARGET" --state-root "$r" --pr 9 --owner acme --repo demo --source-issue 42 \
  --exclude-ids "$C_F01" --list-candidates "$TMP_ROOT/t91-cands.json" >"$OUT" 2>"$ERR"
assert "T-91 hold なし: 除外指定の候補は列挙に無い" "$C_F05 D-01 D-04" \
  "$(jq -r '[.candidates[].id] | join(" ")' "$TMP_ROOT/t91-cands.json")"
assert_not_grep "T-91 hold なし: INFO を出さない" "$ERR" "$T91_INFO"
write_adoption "$r" "$(rec "[\"$C_F05\",\"D-01\",\"D-04\"]")"
run_target "$r" --exclude-ids "$C_F01"
assert_grep "T-91 hold なし: 除外した候補の記録なしで起票する" "$ERR" '^\[CONTEXT\] FOLLOW_UP_ISSUE=created; issue=99; existing=0; recorded=0; pr=9$'
# hold ファイルを読めなければ除外に倒さず、列挙も起票実行も失敗で止める
for t91_bad in 'not-json{' '{"head": "x", "candidates": {}}'; do
  reset_stubs
  adopt_root t91-bad
  mkdir -p "$r/.rite/state"
  printf '%s\n' "$t91_bad" > "$r/$HOLD_REL"
  rm -f "$TMP_ROOT/t91-bad-cands.json"
  PATH="$TMP_ROOT/bin:$PATH" bash "$TARGET" --state-root "$r" --pr 9 --owner acme --repo demo --source-issue 42 \
    --exclude-ids "$C_F01" --list-candidates "$TMP_ROOT/t91-bad-cands.json" >"$OUT" 2>"$ERR"
  assert "T-91 壊れた hold ($t91_bad): 列挙 exit 0" "0" "$?"
  assert_grep "T-91 壊れた hold ($t91_bad): 列挙は hold_unreadable で失敗" "$ERR" '^\[CONTEXT\] FOLLOW_UP_CANDIDATES=failed; reason=hold_unreadable; pr=9$'
  assert "T-91 壊れた hold ($t91_bad): 列挙は一覧を書かない" "no" "$([ -e "$TMP_ROOT/t91-bad-cands.json" ] && echo yes || echo no)"
  write_adoption "$r" "$(rec "[\"$C_F05\",\"D-01\",\"D-04\"]")"
  run_target "$r" --exclude-ids "$C_F01"
  assert_grep "T-91 壊れた hold ($t91_bad): 起票実行は hold_unreadable で失敗" "$ERR" '^\[CONTEXT\] FOLLOW_UP_ISSUE=failed; reason=hold_unreadable; pr=9$'
  assert "T-91 壊れた hold ($t91_bad): 起票しない" "0" "$(create_count)"
  assert "T-91 壊れた hold ($t91_bad): 判定済み記録を書かない" "no" "$([ -e "$r/$JUDGED_RECORD_REL" ] && echo yes || echo no)"
  assert "T-91 壊れた hold ($t91_bad): hold ファイルを残す" "$t91_bad" "$(cat "$r/$HOLD_REL")"
done
assert "T-91 SKILL 6.0.A: 保留した候補は RESOLVED の記録で処分する" "1" \
  "$(grep -cF '採否ゲートが保留した候補は、6.0.V が `resolved` と判定しても一覧に残る。' "$CLEANUP_MD")"
assert "T-91 SKILL 6.0.A: PR 起因の保留は人間に報告する" "1" \
  "$(grep -cF 'ゲートは保留のまま止め、人間に報告する（再実行しても同じ保留になる）' "$CLEANUP_MD")"
assert "T-91 SKILL 6.0.A: PM に返す旧文が無い" "0" "$(grep -cF 'PM に返す' "$CLEANUP_MD")"

echo "--- T-92: PR 起因の LINK は追跡先への処分で決着し、record の出口は台帳に残って再実行で判定し直さない ---"
reset_stubs
ADOPT_MODE=manual
adopt_root t92
export GH_PATCH_OUT="$STUB_DIR/t92-patched.md"
rm -f "$GH_PATCH_OUT"
jq -n --argjson c "$(comment_obj "$(record_body '| F-77 | other.md:1 | issued | #77 https://example.test/issues/77 | 9-20251231120000.json |')")" '[[$c]]' > "$GH_API_JSON"
for t92_origin in unknown pr; do
  t92_link='{"origin": "unknown", "tracker": 7}'
  [ "$t92_origin" = pr ] && t92_link='{"origin": "pr", "origin_cause": {"contract": {"ref": "pr", "text": "契約: マージ時の残存指摘は follow-up で扱う"}}, "tracker": 7}'
  write_adoption "$r" "$(rec "[\"$C_F01\",\"D-01\"]" "$t92_link")" "$(rec "[\"$C_F05\"]" "$REJECT_FIELDS")" "$(rec '["D-04"]' "$RESOLVED_FIELDS")"
  run_target "$r"
  assert_grep "T-92 origin=$t92_origin の LINK は保留せず all_recorded" "$ERR" '^\[CONTEXT\] FOLLOW_UP_ISSUE=skipped; reason=all_recorded; recorded=3; pr=9$'
  assert "T-92 origin=$t92_origin の LINK は起票しない" "0" "$(create_count)"
  assert "T-92 origin=$t92_origin の LINK は hold を残さない" "no" "$([ -e "$r/$HOLD_REL" ] && echo yes || echo no)"
  assert_grep "T-92 origin=$t92_origin の出口を台帳へ書く" "$ERR" '^\[CONTEXT\] FOLLOW_UP_LEDGER=recorded; rows=4; pr=9$'
done
assert_grep "T-92 LINK 行は追跡先の番号と指摘の出典を持つ" "$GH_PATCH_OUT" '^| F-01 | a.md:3 | LINK | 追跡先 #7 | 9-20260101120000.json |$'
assert_grep "T-92 先送り欠陥の LINK 行は出典 <pr>-deferred" "$GH_PATCH_OUT" '^| D-01 | - | LINK | 追跡先 #7 | 9-deferred |$'
assert_grep "T-92 REJECT 行は reason を判定文にする" "$GH_PATCH_OUT" '^| F-05 | b.md:9 | REJECT | 文書化された挙動 / 仕様が変わったら再検討 | 9-20260101120000.json |$'
assert_grep "T-92 reason の無い RESOLVED 行は evidence を判定文にする" "$GH_PATCH_OUT" '^| D-04 | - | RESOLVED | マージ後 HEAD で修正済み | 9-deferred |$'
assert_grep "T-92 既存の台帳行を残す" "$GH_PATCH_OUT" '^| F-77 | other.md:1 | issued |'
# 書いた台帳で再実行すると、処分済みの候補は候補に戻らず、追跡先も読み直さず、保留もしない
jq -n --argjson c "$(comment_obj "$(cat "$GH_PATCH_OUT")")" '[[$c]]' > "$GH_API_JSON"
: > "$GH_LOG"
PATH="$TMP_ROOT/bin:$PATH" bash "$TARGET" --state-root "$r" --pr 9 --owner acme --repo demo --source-issue 42 \
  --list-candidates "$TMP_ROOT/t92-cands.json" >"$OUT" 2>"$ERR"
assert "T-92 再実行の列挙は処分済みの候補を含まない" "0" "$(jq '.candidates | length' "$TMP_ROOT/t92-cands.json")"
run_target "$r"
assert_not_grep "T-92 再実行は保留しない" "$ERR" 'FOLLOW_UP_ISSUE=held'
assert_not_grep "T-92 再実行は追跡先の状態を読み直さない" "$GH_LOG" 'issue view 7'
assert "T-92 再実行も起票しない" "0" "$(create_count)"
# 台帳へ書けなくても起票の判断は変えず、失敗を marker で出す
reset_stubs
ADOPT_MODE=manual
adopt_root t92-fail
export GH_PATCH_RC=1
jq -n --argjson c "$(comment_obj "$(record_body '| F-77 | other.md:1 | issued | #77 | 9-20251231120000.json |')")" '[[$c]]' > "$GH_API_JSON"
write_adoption "$r" "$(rec "[\"$C_F01\",\"D-01\"]" '{"origin": "unknown", "tracker": 7}')" "$(rec "[\"$C_F05\",\"D-04\"]" "$REJECT_FIELDS")"
run_target "$r"
assert_grep "T-92 台帳へ書けなければ FOLLOW_UP_LEDGER=failed" "$ERR" '^\[CONTEXT\] FOLLOW_UP_LEDGER=failed; pr=9$'
assert_grep "T-92 台帳へ書けなくても all_recorded" "$ERR" 'FOLLOW_UP_ISSUE=skipped; reason=all_recorded; recorded=2; pr=9'
unset GH_PATCH_RC GH_PATCH_OUT
# プレビューでは台帳へ書かない
reset_stubs
ADOPT_MODE=manual
adopt_root t92-preview
write_adoption "$r" "$(rec "[\"$C_F01\"]")" "$(rec "[\"$C_F05\",\"D-01\",\"D-04\"]" "$REJECT_FIELDS")"
run_target "$r" --preview-body "$TMP_ROOT/t92-preview.md"
assert_not_grep "T-92 プレビューは台帳へ書かない" "$ERR" 'FOLLOW_UP_LEDGER='

echo "--- T-arg: 引数 gate ---"
bash "$TARGET" --pr abc --state-root "$TMP_ROOT" --owner a --repo b >"$OUT" 2>"$ERR"; RC=$?
assert "T-arg --pr 非数値は exit 1" "1" "$RC"
bash "$TARGET" --pr 9 --owner a --repo b >"$OUT" 2>"$ERR"; RC=$?
assert "T-arg --state-root 欠落は exit 1" "1" "$RC"
r=$(new_root targ)
run_target "$r" --bogus x
assert "T-arg 未知オプションは exit 1" "1" "$RC"
reset_stubs
put_json "$r" "9-20260101120000.json" "$FINDING_JSON"
run_target "$r" --preview-body ""
assert "T-arg --preview-body の空値は exit 1" "1" "$RC"
assert "T-arg --preview-body の空値で起票しない" "0" "$(create_count)"

print_summary "cleanup-follow-up-issue.test.sh"
