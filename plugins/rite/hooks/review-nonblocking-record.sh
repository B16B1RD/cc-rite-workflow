#!/bin/bash
# rite workflow - Non-measured Findings PR Comment Record
# Deterministic helper for skills/pr-review/SKILL.md ステップ 6.1.d (非実測指摘の PR コメント記録)。
#
# 実測必須ゲート (severity-levels.md §実測必須ゲート) が non-blocking へ降格した非実測指摘を、
# PR 上の単一コメント (update-in-place) に記録する。Issue #2024 D-01「非実測指摘は破棄せず
# PR コメント記録」の担保であり、`pr_review.post_comment` 設定には**依存しない** (opt-out 対象外)。
#
# Usage:
#   bash review-nonblocking-record.sh \
#     --pr <number> \
#     --owner-repo <owner/repo> \
#     --count <N> \
#     --iteration-id <id> \
#     --content-file <path>
#
#   caller (pr-review.md ステップ 6.1.d) は以下を行う:
#     1. 件数 (`non_blocking_findings` の件数) に応じた本文 (variant A / B) を生成し、
#        **Write tool** で tmpfile に保存する。1 行目は必ず MARKER 見出しにする。
#     2. ステップ 6.1.a step 0 の [CONTEXT] REVIEW_CYCLE_ID= を --iteration-id に渡す。
#     3. 本 helper を 1 回だけ実行する。
#
# 契約 (pr-review.md ステップ 6.1.d と verbatim 一致):
#   - **単一 invocation**: 既存コメント lookup → skip 判定 → PATCH / create を 1 プロセスに閉じる。
#     lookup だけ実行して記録を skip した状態が構造的に存在しえないため、terminal sentinel の
#     存在 = 「記録経路が終端まで走った」を意味する (動作前 marker を gate の入力にしてはならない)。
#     caller は existing_comment_id を受け渡さない。
#   - **terminal sentinel は 1 種のみ**: EXIT trap が
#       [CONTEXT] NONBLOCKING_RECORD_DONE=1; pr=N; outcome=<...>; count=K; iteration_id=ID; comment_id=<id|空>; degraded=<0|1>
#     を stderr に emit する。outcome は created / updated / skipped / failed / aborted。
#     `aborted` は trap の初期値で、判定に到達する前に落ちた場合にのみ残る (早期 exit が
#     success を騙れない構造)。個別の RECORDED / CLEAR_SKIPPED marker は持たない (consumer が
#     いない marker を作らないため)。
#   - **非ブロッキング (AC-3)**: gh / jq / IO の失敗は WARNING + `[CONTEXT] NONBLOCKING_RECORD_FAILED=1;
#     reason=...` を emit して **exit 0**。overall_assessment / result pattern に一切影響しない。
#     例外は placeholder residue 系 gate (skill 定義のバグ) で、loud に exit 1 する。
#     reason 語彙: pr_number_placeholder_residue / owner_repo_placeholder_residue /
#       non_blocking_count_placeholder_residue / iteration_id_placeholder_residue /
#       content_file_placeholder_residue / content_file_missing / body_file_empty /
#       body_marker_missing / patch_failed / create_failed
#   - **既存コメントの特定は「自分が投稿した」∧「1 行目 marker への前方一致 (startswith)」の連言**。
#     author 条件を欠くと、marker で始まるコメントを第三者が 1 件投稿するだけで PATCH 先を奪える。
#     `contains` (本文全体を対象) も別コメントを掴む。
#   - **投稿する本文は「非空」かつ「1 行目が MARKER で始まる」ことを投稿前に検査する**。
#     どちらの契約違反も、1 行目 marker を失ったコメントを PATCH で作り出し以降の lookup を
#     恒久的に miss させる。
#     rationale: ../skills/pr-review/references/measured-gate-record.md#startswith
#   - **create は count > 0 でガード**: 0 件 ∧ 既存なしで「0 件です」という事実と異なるコメントを
#     新規作成しない (AC-4 非退行)。
#   - [CONTEXT] / WARNING は stderr (6.1.a/b/c の 3 兄弟 helper と同一)。
#
# Exit codes:
#   0: 記録成功 / 正当な skip / 非ブロッキングな失敗 (gh・IO)。
#   1: placeholder residue / content_file 不在 等の caller 契約違反 (skill 定義のバグ)。
set -uo pipefail
# shellcheck source=control-char-neutralize.sh
source "$(dirname "${BASH_SOURCE[0]}")/control-char-neutralize.sh"

# 記録コメントの 1 行目見出し。lookup の前方一致 needle であり、caller が生成する本文の
# 1 行目が本値で **始まる** こと (前方一致) が write 側契約 (SKILL.md ステップ 6.1.d step 1)。
# variant A / B の 1 行目は末尾に ` (non-blocking)` が付くため完全一致ではない。
MARKER='## 📜 rite 非実測指摘の記録'

# --- Argument parsing ---
PR_NUMBER=""
OWNER_REPO=""
NB_COUNT=""
ITERATION_ID=""
CONTENT_FILE=""

# 各値付きフラグは `shift; shift` で消費する (値なしフラグが末尾に来た場合の無限ループ回避。
# review-comment-post.sh と同一 idiom)。
while [[ $# -gt 0 ]]; do
  case "$1" in
    --pr)           PR_NUMBER="${2:-}"; shift; shift ;;
    --owner-repo)   OWNER_REPO="${2:-}"; shift; shift ;;
    --count)        NB_COUNT="${2:-}"; shift; shift ;;
    --iteration-id) ITERATION_ID="${2:-}"; shift; shift ;;
    --content-file) CONTENT_FILE="${2:-}"; shift; shift ;;
    # 値の verbatim echo は禁止 (下記 iteration_id gate と同根)。本分岐は trap 設置**前**のため
    # real sentinel が 1 本も出ず、偽 sentinel が唯一の sentinel になりうる。
    *) echo "ERROR: review-nonblocking-record: unknown option: $(printf '%s' "$1" | neutralize_ctrl)" >&2; exit 1 ;;
  esac
done

# --- placeholder residue gates ---
# いずれも「caller が {placeholder} をリテラル置換し忘れた」= skill 定義のバグであり、記録の失敗
# ではない。正常系と同じ marker で silent に skip させず loud に落とす (D-01 の無音喪失を防ぐ)。
# 本 gate 群は terminal sentinel の trap 設置より **前** に置く: ここで落ちた場合は記録経路が
# 一度も走っていないため、outcome=failed を名乗らせずに exit 1 の非ゼロ rc で caller に返す。
case "$PR_NUMBER" in
  ''|*[!0-9]*)
    echo "ERROR: review-nonblocking-record: pr_number が数値ではありません (値: '$(printf '%s' "$PR_NUMBER" | neutralize_ctrl)', 期待: 数値のみ非空)" >&2
    echo "[CONTEXT] NONBLOCKING_RECORD_FAILED=1; reason=pr_number_placeholder_residue" >&2
    exit 1
    ;;
esac
case "$OWNER_REPO" in
  */*)
    case "$OWNER_REPO" in
      *'{'*|*'}'*|*' '*)
        echo "ERROR: review-nonblocking-record: owner_repo に placeholder / 空白が残留しています (値: '$(printf '%s' "$OWNER_REPO" | neutralize_ctrl)')" >&2
        echo "[CONTEXT] NONBLOCKING_RECORD_FAILED=1; pr=$PR_NUMBER; reason=owner_repo_placeholder_residue" >&2
        exit 1
        ;;
    esac
    ;;
  *)
    echo "ERROR: review-nonblocking-record: owner_repo が owner/repo 形式ではありません (値: '$(printf '%s' "$OWNER_REPO" | neutralize_ctrl)')" >&2
    echo "[CONTEXT] NONBLOCKING_RECORD_FAILED=1; pr=$PR_NUMBER; reason=owner_repo_placeholder_residue" >&2
    exit 1
    ;;
esac
case "$NB_COUNT" in
  ''|*[!0-9]*)
    echo "ERROR: review-nonblocking-record: count が数値ではありません (値: '$(printf '%s' "$NB_COUNT" | neutralize_ctrl)')" >&2
    echo "  0 件のときも明示的に --count 0 を渡してください (空文字は substitute 漏れと区別できません)" >&2
    echo "[CONTEXT] NONBLOCKING_RECORD_FAILED=1; pr=$PR_NUMBER; reason=non_blocking_count_placeholder_residue" >&2
    exit 1
    ;;
esac
# iteration_id は terminal sentinel に無加工で埋め込まれ、その sentinel は 6.1.d step 3 / 8.0.3 の
# 2 gate が唯一の pass 条件として読む機械可読 control line である。denylist だけでは改行入りの値を
# 通してしまい、完全な形の 2 本目の sentinel 行 (= gate 入力の偽装) を生成できる。形状 allowlist で
# 弾く (REVIEW_CYCLE_ID の実値は `{pr}-{epoch}` 形式でこの範囲に収まる)。
case "$ITERATION_ID" in
  ''|*'{'*|*'}'*|*[!A-Za-z0-9._-]*)
    # 値の verbatim echo は禁止 — 改行入りの値をそのまま出すと、診断行の中に完全な形の
    # `[CONTEXT] NONBLOCKING_RECORD_DONE=1; ...` を再現でき、gate を読む LLM を欺ける。
    # neutralize_ctrl で改行ごと `?` 化してから 1 行に収める。
    echo "ERROR: review-nonblocking-record: iteration_id が literal substitute されていないか不正な文字を含みます (値: '$(printf '%s' "$ITERATION_ID" | neutralize_ctrl)')" >&2
    echo "  期待: 英数字 / '.' / '_' / '-' のみからなる非空文字列 (例: 2038-1799999999)" >&2
    echo "  caller は ステップ 6.1.a step 0 の [CONTEXT] REVIEW_CYCLE_ID= emit 値を --iteration-id に渡す必要があります" >&2
    echo "[CONTEXT] NONBLOCKING_RECORD_FAILED=1; pr=$PR_NUMBER; reason=iteration_id_placeholder_residue" >&2
    exit 1
    ;;
esac
# content-file のブレース残留は body_file_empty (Write の失敗) と別 reason にする。融合させると
# 「skill 定義のバグ」と「本文生成の失敗」が同一診断に潰れ、caller が誤った復旧手順に誘導される。
case "$CONTENT_FILE" in
  ''|*'{'*|*'}'*)
    echo "ERROR: review-nonblocking-record: content_file のパスが literal substitute されていません (値: '$(printf '%s' "$CONTENT_FILE" | neutralize_ctrl)')" >&2
    echo "  caller は ステップ 6.1.a step 0 の [CONTEXT] REVIEW_TMP_DIR= emit 値でパスを解決する必要があります" >&2
    echo "[CONTEXT] NONBLOCKING_RECORD_FAILED=1; pr=$PR_NUMBER; reason=content_file_placeholder_residue" >&2
    exit 1
    ;;
esac
# ファイル**不在**は caller 契約違反 (step 1 の Write tool 呼び出し漏れ) であり IO 失敗ではない。
# 後段の非空検査 (`[ ! -s ]`) に潰すと、記録が一度も行われないまま outcome=failed で exit 0 し、
# 8.0.3 gate は「評価された」として pass する — D-01 の記録が無音で失われる。placeholder residue
# 5 gate と同じ loud fail に揃える (兄弟 review-comment-post.sh の --content-file 不在 reject と対称)。
# 「存在するが空」は本 gate を通過し、後段で非ブロッキング body_file_empty として扱う。
if [ ! -f "$CONTENT_FILE" ]; then
  echo "ERROR: review-nonblocking-record: content_file が存在しません (値: '$(printf '%s' "$CONTENT_FILE" | neutralize_ctrl)')" >&2
  echo "  caller は ステップ 6.1.d step 1 の Write tool による本文保存を先に実行する必要があります" >&2
  echo "[CONTEXT] NONBLOCKING_RECORD_FAILED=1; pr=$PR_NUMBER; reason=content_file_missing" >&2
  exit 1
fi

# --- terminal sentinel (EXIT trap) ---
# outcome の初期値は `aborted`。success 値 (created / updated / skipped) は該当分岐に到達して
# はじめて代入されるため、途中終了が success を騙ることは構造的に起きない。
outcome="aborted"
existing_id=""
lookup_degraded=0
gh_err=""
# signal trap は emit 後に exit するため EXIT trap が再入する。兄弟 review-result-save.sh と同じ
# 冪等ガードを置き、terminal sentinel が 1 回だけ出ることを保証する。
_terminal_emitted="false"
_rite_p61d_cleanup() {
  rm -f "${gh_err:-}"
}
# 記録できなかったときの共通案内。非ブロッキングな失敗 reason (body_file_empty /
# body_marker_missing / patch_failed / create_failed) のすべてから呼べるよう trap 定義直後に置く。
_record_failure_hint() {
  echo "  対処: gh auth status / network 接続 / PR #${PR_NUMBER} への write 権限を確認し、レビューをやり直してください" >&2
  echo "  mergeable 判定には影響しません (非ブロッキング)。記録内容は ステップ 5.4 統合レポートの「実測なし指摘」section と ステップ 6.1.a のローカル JSON (non_blocking_findings[]) から参照できます (後者は gitignore 対象のためレビュアーとは共有されません)" >&2
}
_rite_p61d_emit_terminal() {
  [ "$_terminal_emitted" = "true" ] && return 0
  _terminal_emitted="true"
  echo "[CONTEXT] NONBLOCKING_RECORD_DONE=1; pr=$PR_NUMBER; outcome=$outcome; count=$NB_COUNT; iteration_id=$ITERATION_ID; comment_id=$existing_id; degraded=$lookup_degraded" >&2
}
trap 'rc=$?; _rite_p61d_emit_terminal; _rite_p61d_cleanup; exit $rc' EXIT
trap '_rite_p61d_emit_terminal; _rite_p61d_cleanup; exit 130' INT
trap '_rite_p61d_emit_terminal; _rite_p61d_cleanup; exit 143' TERM
trap '_rite_p61d_emit_terminal; _rite_p61d_cleanup; exit 129' HUP

# --- 既存記録コメントの探索 ---
# `--paginate --slurp` + 外側 jq で全ページ走査する (非 paginate は既定 30 件・昇順のため
# コメント 30 件超の PR で marker を miss し、update-in-place が silent に破綻する)。
# pipefail なしでは gh 失敗が末尾 jq の rc=0 に mask され degraded 分岐が dead code になる。
gh_err=$(bash "$(dirname "${BASH_SOURCE[0]}")/_mktemp-stderr-guard.sh" \
  review-nonblocking-record p61d-gh-err "gh/jq 失敗時の詳細が表示されません") || gh_err=""

# **author 条件は必須**: 前方一致だけでは、marker で始まるコメントを第三者が 1 件投稿するだけで
# `last` がそれを掴み PATCH 先を奪われる (書込権限があれば他人のコメントを破壊、無ければ 403 で
# 記録が恒久的に失われる)。自分の login と一致する投稿のみを対象にする。
gh_login=$(gh api user --jq '.login' 2>"${gh_err:-/dev/null}") || gh_login=""
if [ -z "$gh_login" ]; then
  echo "WARNING: gh api user による自 login の取得に失敗しました。既存コメントを特定できないため存在不明として扱います" >&2
  [ -n "$gh_err" ] && [ -s "$gh_err" ] && head -5 "$gh_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
  _record_failure_hint
  existing_id=""
  lookup_degraded=1
elif existing_id=$(gh api --paginate --slurp "repos/$OWNER_REPO/issues/$PR_NUMBER/comments" 2>"${gh_err:-/dev/null}" \
     | jq -r --arg marker "$MARKER" --arg me "$gh_login" \
         'add | [.[] | select(((.body // "") | startswith($marker)) and ((.user.login // "") == $me))] | last | .id // empty'); then
  :
else
  echo "WARNING: 既存の非実測記録コメントの検索に失敗しました (gh/jq)。存在不明として扱います" >&2
  [ -n "$gh_err" ] && [ -s "$gh_err" ] && head -5 "$gh_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
  existing_id=""
  lookup_degraded=1
fi
[ -n "$gh_err" ] && { rm -f "$gh_err"; gh_err=""; }

# --- 記録 / skip の分岐 ---
# 検索 degraded 時は `0 件 → skip` / `>0 件 → 新規作成に縮退` (WARNING と degraded=1 は emit 済で
# silent 縮退にはならない)。
if [ -z "$existing_id" ] && [ "$NB_COUNT" -eq 0 ]; then
  # 0 件 ∧ 既存なし: 投稿しない (AC-4 非退行)。事実と異なる「0 件」コメントを新規作成しない。
  outcome="skipped"
  exit 0
fi

if [ ! -s "$CONTENT_FILE" ]; then
  echo "WARNING: 非実測記録の本文ファイルが空です ($(printf '%s' "$CONTENT_FILE" | neutralize_ctrl))。投稿を中止します (既存コメントの marker 破壊を防ぐ)" >&2
  _record_failure_hint
  echo "[CONTEXT] NONBLOCKING_RECORD_FAILED=1; pr=$PR_NUMBER; reason=body_file_empty" >&2
  outcome="failed"
  exit 0
fi

# 1 行目 marker 検査。空 body と同様に「marker を欠いた本文で PATCH する」と 1 行目 marker が消え、
# 以降の lookup が恒久的に miss する。空 body だけを塞いでも本文生成が失敗した非空ケースが素通りする。
# 診断分離のため body_file_empty とは別 reason にする (兄弟 issue-comment-wm-sync.sh の header 検査と同型)。
case "$(head -n 1 "$CONTENT_FILE")" in
  "$MARKER"*) ;;
  *)
    echo "WARNING: 非実測記録の本文 1 行目が marker 見出しで始まっていません ($(printf '%s' "$CONTENT_FILE" | neutralize_ctrl))。投稿を中止します" >&2
    echo "  期待: 1 行目が '$MARKER' で始まること (SKILL.md ステップ 6.1.d step 1 の variant A / B)" >&2
    _record_failure_hint
    echo "[CONTEXT] NONBLOCKING_RECORD_FAILED=1; pr=$PR_NUMBER; reason=body_marker_missing" >&2
    outcome="failed"
    exit 0
    ;;
esac

gh_err=$(bash "$(dirname "${BASH_SOURCE[0]}")/_mktemp-stderr-guard.sh" \
  review-nonblocking-record p61d-gh-err "gh 失敗時の stderr 詳細が表示されません") || gh_err=""

# PATCH / create の失敗診断は差分が label と reason の 2 語だけなので 1 関数に寄せる
# (片側にだけ診断を足す drift を構造的に防ぐ。関数定義を trap ブロック側へ集約する点は
# _record_failure_hint と同じ)。
_record_gh_failure() {  # $1=label $2=reason $3=rc
  echo "WARNING: 非実測指摘の PR コメント$1 に失敗しました (gh rc=$3)" >&2
  [ -n "$gh_err" ] && [ -s "$gh_err" ] && head -5 "$gh_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
  _record_failure_hint
  # signal 終了 (rc>=128) を retained flag に併記する (兄弟 review-comment-post.sh と対称)
  if [ "$3" -ge 128 ]; then
    echo "[CONTEXT] NONBLOCKING_RECORD_FAILED=1; pr=$PR_NUMBER; reason=$2; rc=$3; signal=$(($3 - 128))" >&2
  else
    echo "[CONTEXT] NONBLOCKING_RECORD_FAILED=1; pr=$PR_NUMBER; reason=$2; rc=$3" >&2
  fi
  outcome="failed"
}

if [ -n "$existing_id" ]; then
  # 本文の受け渡しは gh-cli-patterns.md §"For comment update (gh api PATCH)" の正規形に従う
  # (jq --rawfile で JSON を組み --input - へ渡す)。subshell で pipefail を局所化し、jq 段の
  # 失敗も rc に伝播させる (issue-comment-wm-sync.sh と同型)。
  if ( set -o pipefail
       jq -n --rawfile body "$CONTENT_FILE" '{"body": $body}' \
         | gh api "repos/$OWNER_REPO/issues/comments/$existing_id" -X PATCH --input - >/dev/null ) 2>"${gh_err:-/dev/null}"; then
    outcome="updated"
  else
    _record_gh_failure "更新 (PATCH)" patch_failed "$?"
  fi
else
  # ここに来るのは count > 0 のときのみ (0 件 ∧ 既存なしは上で skip 済)。
  if gh pr comment "$PR_NUMBER" -R "$OWNER_REPO" --body-file "$CONTENT_FILE" >/dev/null 2>"${gh_err:-/dev/null}"; then
    outcome="created"
  else
    _record_gh_failure "記録 (新規作成)" create_failed "$?"
  fi
fi

exit 0
