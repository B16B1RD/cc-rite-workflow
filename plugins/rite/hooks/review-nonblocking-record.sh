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
#     存在 = 「記録経路が終端まで走った」を意味する (Issue #2034 F-02: 動作前 marker を gate の
#     入力にしてはならない)。caller は existing_comment_id を受け渡さない。
#   - **terminal sentinel は 1 種のみ**: EXIT trap が
#       [CONTEXT] NONBLOCKING_RECORD_DONE=1; pr=N; outcome=<...>; count=K; iteration_id=ID; comment_id=<id|空>; degraded=<0|1>
#     を stderr に emit する。outcome は created / updated / skipped / failed / aborted。
#     `aborted` は trap の初期値で、判定に到達する前に落ちた場合にのみ残る (早期 exit が
#     success を騙れない構造)。個別の RECORDED / CLEAR_SKIPPED marker は持たない (consumer ゼロの
#     marker を作らない — F-02)。
#   - **非ブロッキング (AC-3)**: gh / jq / IO の失敗は WARNING + `[CONTEXT] NONBLOCKING_RECORD_FAILED=1;
#     reason=...` を emit して **exit 0**。overall_assessment / result pattern に一切影響しない。
#     例外は placeholder residue 系 gate (skill 定義のバグ) で、loud に exit 1 する。
#     reason 語彙: pr_number_placeholder_residue / owner_repo_placeholder_residue /
#       non_blocking_count_placeholder_residue / iteration_id_placeholder_residue /
#       content_file_placeholder_residue / body_file_empty / patch_failed / create_failed
#   - **既存コメントの特定は 1 行目 marker への前方一致 (startswith)**。`contains` は marker 文字列を
#     引用しただけの別コメント (6.1.b のレビュー結果コメント / 人間の Quote reply) を掴み、
#     PATCH がそれを丸ごと上書き破壊する。
#   - **本文ファイルの非空検査**: 空 body の PATCH は 1 行目 marker を消し、以降の lookup を
#     恒久的に miss させる (update-in-place の永久破綻)。投稿する経路でのみ検査する。
#   - **create は count > 0 でガード**: 0 件 ∧ 既存なしで「0 件です」という事実と異なるコメントを
#     新規作成しない (AC-4 非退行)。
#   - [CONTEXT] / WARNING は stderr (6.1.a/b/c の 3 兄弟 helper と同一)。
#
# Exit codes:
#   0: 記録成功 / 正当な skip / 非ブロッキングな失敗 (gh・IO)。
#   1: placeholder residue 等の引数 gate 違反 (skill 定義のバグ)。
set -uo pipefail
# shellcheck source=control-char-neutralize.sh
source "$(dirname "${BASH_SOURCE[0]}")/control-char-neutralize.sh"

# 記録コメントの 1 行目見出し。lookup の前方一致 needle であり、caller が生成する本文の
# 1 行目と **完全一致** させる必要がある (SKILL.md ステップ 6.1.d step 1 の write 側契約)。
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
    *) echo "ERROR: review-nonblocking-record: unknown option: $1" >&2; exit 1 ;;
  esac
done

# --- placeholder residue gates ---
# いずれも「caller が {placeholder} をリテラル置換し忘れた」= skill 定義のバグであり、記録の失敗
# ではない。正常系と同じ marker で silent に skip させず loud に落とす (D-01 の無音喪失を防ぐ)。
# 本 gate 群は terminal sentinel の trap 設置より **前** に置く: ここで落ちた場合は記録経路が
# 一度も走っていないため、outcome=failed を名乗らせずに exit 1 の非ゼロ rc で caller に返す。
case "$PR_NUMBER" in
  ''|*[!0-9]*)
    echo "ERROR: review-nonblocking-record: pr_number が数値ではありません (値: '$PR_NUMBER', 期待: 数値のみ非空)" >&2
    echo "[CONTEXT] NONBLOCKING_RECORD_FAILED=1; reason=pr_number_placeholder_residue" >&2
    exit 1
    ;;
esac
case "$OWNER_REPO" in
  */*)
    case "$OWNER_REPO" in
      *'{'*|*'}'*|*' '*)
        echo "ERROR: review-nonblocking-record: owner_repo に placeholder / 空白が残留しています (値: '$OWNER_REPO')" >&2
        echo "[CONTEXT] NONBLOCKING_RECORD_FAILED=1; pr=$PR_NUMBER; reason=owner_repo_placeholder_residue" >&2
        exit 1
        ;;
    esac
    ;;
  *)
    echo "ERROR: review-nonblocking-record: owner_repo が owner/repo 形式ではありません (値: '$OWNER_REPO')" >&2
    echo "[CONTEXT] NONBLOCKING_RECORD_FAILED=1; pr=$PR_NUMBER; reason=owner_repo_placeholder_residue" >&2
    exit 1
    ;;
esac
case "$NB_COUNT" in
  ''|*[!0-9]*)
    echo "ERROR: review-nonblocking-record: count が数値ではありません (値: '$NB_COUNT')" >&2
    echo "  0 件のときも明示的に --count 0 を渡してください (空文字は substitute 漏れと区別できません)" >&2
    echo "[CONTEXT] NONBLOCKING_RECORD_FAILED=1; pr=$PR_NUMBER; reason=non_blocking_count_placeholder_residue" >&2
    exit 1
    ;;
esac
case "$ITERATION_ID" in
  ''|*'{'*|*'}'*)
    echo "ERROR: review-nonblocking-record: iteration_id が literal substitute されていません (値: '$ITERATION_ID')" >&2
    echo "  caller は ステップ 6.1.a step 0 の [CONTEXT] REVIEW_CYCLE_ID= emit 値を --iteration-id に渡す必要があります" >&2
    echo "[CONTEXT] NONBLOCKING_RECORD_FAILED=1; pr=$PR_NUMBER; reason=iteration_id_placeholder_residue" >&2
    exit 1
    ;;
esac
# content-file のブレース残留は body_file_empty (Write の失敗) と別 reason にする。融合させると
# 「skill 定義のバグ」と「本文生成の失敗」が同一診断に潰れ、caller が誤った復旧手順に誘導される。
case "$CONTENT_FILE" in
  ''|*'{'*|*'}'*)
    echo "ERROR: review-nonblocking-record: content_file のパスが literal substitute されていません (値: '$CONTENT_FILE')" >&2
    echo "  caller は ステップ 6.1.a step 0 の [CONTEXT] REVIEW_TMP_DIR= emit 値でパスを解決する必要があります" >&2
    echo "[CONTEXT] NONBLOCKING_RECORD_FAILED=1; pr=$PR_NUMBER; reason=content_file_placeholder_residue" >&2
    exit 1
    ;;
esac

# --- terminal sentinel (EXIT trap) ---
# outcome の初期値は `aborted`。success 値 (created / updated / skipped) は該当分岐に到達して
# はじめて代入されるため、途中終了が success を騙ることは構造的に起きない。
outcome="aborted"
existing_id=""
lookup_degraded=0
gh_err=""
_rite_p61d_cleanup() {
  rm -f "${gh_err:-}"
}
_rite_p61d_emit_terminal() {
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
gh_err=$(mktemp "${TMPDIR:-/tmp}/rite-p61d-gh-err-XXXXXX" 2>/dev/null) || gh_err=""
if existing_id=$(gh api --paginate --slurp "repos/$OWNER_REPO/issues/$PR_NUMBER/comments" 2>"${gh_err:-/dev/null}" \
     | jq -r --arg marker "$MARKER" 'add | [.[] | select((.body // "") | startswith($marker))] | last | .id // empty'); then
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
  echo "WARNING: 非実測記録の本文ファイルが空または不在です ($CONTENT_FILE)。投稿を中止します (既存コメントの marker 破壊を防ぐ)" >&2
  echo "[CONTEXT] NONBLOCKING_RECORD_FAILED=1; pr=$PR_NUMBER; reason=body_file_empty" >&2
  outcome="failed"
  exit 0
fi

_record_failure_hint() {
  echo "  mergeable 判定には影響しません (非ブロッキング)。記録内容は ステップ 5.4 統合レポートの「実測なし指摘」section と ステップ 6.1.a のローカル JSON (non_blocking_findings[]) から参照できます" >&2
}

gh_err=$(mktemp "${TMPDIR:-/tmp}/rite-p61d-gh-err-XXXXXX" 2>/dev/null) || gh_err=""
if [ -n "$existing_id" ]; then
  if gh api --method PATCH "repos/$OWNER_REPO/issues/comments/$existing_id" \
       --field body=@"$CONTENT_FILE" >/dev/null 2>"${gh_err:-/dev/null}"; then
    outcome="updated"
  else
    echo "WARNING: 非実測指摘の PR コメント更新 (PATCH) に失敗しました" >&2
    [ -n "$gh_err" ] && [ -s "$gh_err" ] && head -5 "$gh_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
    _record_failure_hint
    echo "[CONTEXT] NONBLOCKING_RECORD_FAILED=1; pr=$PR_NUMBER; reason=patch_failed" >&2
    outcome="failed"
  fi
else
  # ここに来るのは count > 0 のときのみ (0 件 ∧ 既存なしは上で skip 済)。
  if gh pr comment "$PR_NUMBER" -R "$OWNER_REPO" --body-file "$CONTENT_FILE" >/dev/null 2>"${gh_err:-/dev/null}"; then
    outcome="created"
  else
    echo "WARNING: 非実測指摘の PR コメント記録 (新規作成) に失敗しました" >&2
    [ -n "$gh_err" ] && [ -s "$gh_err" ] && head -5 "$gh_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
    _record_failure_hint
    echo "[CONTEXT] NONBLOCKING_RECORD_FAILED=1; pr=$PR_NUMBER; reason=create_failed" >&2
    outcome="failed"
  fi
fi

exit 0
