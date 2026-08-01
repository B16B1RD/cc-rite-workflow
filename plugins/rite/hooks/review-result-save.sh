#!/bin/bash
# rite workflow - Review Result Local Save
# Deterministic helper for skills/pr-review/SKILL.md ステップ 6.1.a (Local JSON File Save).
#
# pr-review.md ステップ 6.1.a のローカル JSON 保存処理 (timestamp 注入 / 多段 jq validation /
# 同秒衝突回避 / atomic mv) を担う。本文側の巨大 inline bash を helper に切り出すことで、単一 Bash
# invocation での malform 無言停止を回避する。JSON body は
# caller が Write tool で tmpfile に書き出し `--content-file` で渡す (heredoc malform 源を撤廃)。
#
# Usage:
#   bash review-result-save.sh --pr <number> --content-file <path> [--results-dir <dir>]
#                              [--pending-id <token>]
#
#   caller (pr-review.md ステップ 6.1.a) は以下を行う:
#     1. review-result-schema.md に従う JSON body を生成し、`"timestamp"` フィールドに
#        literal sentinel "__RITE_TS_PLACEHOLDER_7f3a9b2c__" を書き込んだ上で **Write tool** で
#        tmpfile (例: ${TMPDIR:-/tmp}/rite-review-result-<pr>.json — 実パスは
#        caller が [CONTEXT] REVIEW_TMP_DIR marker 値で解決する) に保存する。
#     2. `bash review-result-save.sh --pr <pr> --content-file <tmp>` を実行する。
#   本 helper が timestamp 算出 / sentinel 注入 / schema validation / collision 回避 /
#   atomic mv を担う。
#
# Options:
#   --pr            PR number (required, 数値のみ)
#   --content-file  JSON body tmpfile path (required)
#   --results-dir   保存先ディレクトリ (default: $(state-path-resolve.sh)/.rite/review-results —
#                   セッション worktree からも main checkout と同一パスに解決。解決失敗時は
#                   cwd 相対 .rite/review-results へフォールバック)
#   --pending-id    本 review cycle の save-pending marker の id token (任意、`{pr}-{epoch}` 形式)。
#                   marker path は本 helper が `${TMPDIR:-/tmp}/rite-p61a-pending-<id>` として
#                   **内部導出**する (sibling の review-nonblocking-record.sh --iteration-id と同形)。
#                   pr-review.md ステップ 5.3.0.M step 2 が実測必須ゲート適用の直後に marker を
#                   生成し、本 helper が EXIT trap で削除する。ステップ 8.0.4 は残存 = 「6.1.a が
#                   本 cycle で走っていない」の機械的証拠として result pattern の emit を差し戻す。
#                   未指定時は no-op (marker 機構を持たない caller との後方互換)。
#                   full path を受け取らないのは、caller 由来の任意文字列が削除対象と機械可読
#                   sentinel の両方へ同時に流れる設計を避けるため — その形では traversal /
#                   sentinel 偽造 / 制御文字を個別に塞ぐ guard が要り、guard が生成側の値域
#                   (${TMPDIR} の文字種) と食い違うと「保存は成功したのに marker が消えず
#                   8.0.4 が恒久的に落ちる」非収束を生む。内部導出はその失敗クラスを構造的に消す。
#
# 契約 (pr-review.md ステップ 6.1.a / D-04 と verbatim 一致):
#   - 非ブロッキング: 失敗経路では `[CONTEXT] LOCAL_SAVE_FAILED=1; reason=...` を stderr に emit する。
#     reason 語彙は 15 種で、**うち 14 種は exit 0** (ステップ 6 全体を fail させない)。
#     `signal_aborted` のみ signal trap 由来で rc=130/143/129 を返す (reason emit と marker 削除は
#     他 14 種と同一。ステップ 6 の exit code は 6.1.c が決める)。
#   - reason 語彙: pr_number_placeholder_residue / date_command_failure / mkdir_failure /
#     mktemp_failure / write_failure / timestamp_injection_mv_failure / json_invalid /
#     schema_required_fields_missing / finding_id_format_or_uniqueness_violation /
#     scope_enum_violation / critical_high_scope_nit_noted_invariant /
#     collision_resolution_exhausted / mktemp_failure_mv_err / mv_failure / signal_aborted
#     (末尾の signal_aborted のみ signal trap 由来で線形の emit 順に載らない)。
#     `signal_aborted` は **保存が未完了のときだけ** emit する — mv 成功後に signal が届いた場合は
#     JSON が実在するため失敗宣言せず、WARNING のみを出す (保存済み cycle を 6.1.c ケース 2 で
#     停止させない)。
#   - 同秒衝突は `~$RANDOM` suffix (separator `~` は `.` より ASCII 大で sort -r 時に
#     collision-resolved 版が先頭に来る)。再衝突は collision_resolution_exhausted で skip。
#   - EXIT trap で `[CONTEXT] FILE_TIMESTAMP=` / `ISO_TIMESTAMP=` / `JSON_SAVED=` を必ず emit
#     (normal/abnormal 両経路、ステップ 6.1.c が emit 前提で動作)。
#   - 同 trap で save-pending marker を削除し `[CONTEXT] REVIEW_SAVE_DONE=1; pr=; marker=; saved=`
#     を emit する。marker が意味するのは「本 helper が完走した」であって「保存に成功した」では
#     ない — 保存失敗 (LOCAL_SAVE_FAILED) で marker を残すと D-04 非ブロッキング契約が
#     ステップ 8.0.4 経由で blocking gate に化けるため。保存の成否は `saved=` / `JSON_SAVED=` /
#     `LOCAL_SAVE_FAILED=` が担う。marker が残るのは (i) trap 設置前の `exit 1`
#     (`--content-file` 未指定 / unknown option — caller 契約違反、review-nonblocking-record.sh の
#     exit-1 群と同じ扱い) と、`--pending-id` の形状違反で path を導出できなかった場合、
#     (ii) `rm` 自体が失敗した場合の 2 群。(i) は caller 側を直せば 1 iteration で収束するが、
#     (ii) は環境起因で再実行では収束せず手動削除を要する。`--pr` 欠落 / 非数値
#     (`pr_number_placeholder_residue`) は trap 設置**後**の `exit 0` かつ marker path は
#     `--pending-id` から独立に導出されるため marker は削除される (可視化は 6.1.c ケース 2 が担う)。
#   - [CONTEXT] / WARNING は全て stderr。stdout は使わない (observability とデータの境界保持)。
#
# Exit codes:
#   0: 常に (success / 非ブロッキング失敗どちらも)。caller は LOCAL_SAVE_FAILED / JSON_SAVED で判定。
#   1: caller 契約違反 (--content-file 未指定 / unknown option — いずれも trap 設置前)。
#      注: --pr 欠落 / 非数値 と --content-file 不在 は trap 設置後の exit 0 (非ブロッキング)。
#   130/143/129: signal 中断 (INT / TERM / HUP)。
set -uo pipefail
# shellcheck source=control-char-neutralize.sh
source "$(dirname "${BASH_SOURCE[0]}")/control-char-neutralize.sh"

# --- Argument parsing ---
PR_NUMBER=""
CONTENT_FILE=""
PENDING_ID=""
# 保存先の既定はリポジトリ共通の state ルート (state-path-resolve.sh)。セッション worktree 内から
# 実行しても main checkout と同一パスに解決され、書込 (本 helper) / 読取 (review-source-resolve.sh
# Priority 2) / 削除 (cleanup ステップ 6) が一貫する。wiki-ingest-trigger.sh の STATE_ROOT anchor と
# 同一方式。解決失敗時は従来の cwd 相対へフォールバック (non-blocking 契約、単一 checkout では
# state-path-resolve が同一パスを返すため挙動不変)。--results-dir 明示指定はこの既定を上書きする。
_save_script_dir="$(dirname "${BASH_SOURCE[0]}")"
if _state_root=$("$_save_script_dir/state-path-resolve.sh" "$PWD" 2>/dev/null) && [ -n "$_state_root" ]; then
  REVIEW_RESULTS_DIR="$_state_root/.rite/review-results"
else
  echo "WARNING: review-result-save: state-path-resolve.sh の解決に失敗。cwd 相対の .rite/review-results へフォールバックします" >&2
  REVIEW_RESULTS_DIR=".rite/review-results"
fi

# 各値付きフラグは `shift; shift` で消費する。値なしフラグが末尾に来た場合 ($#=1)、
# `shift 2` は $# を減らせず set -e 非設定 + `${2:-}` (nounset 非発火) の下で無限ループに
# 陥る。1 回目の shift で $# を確実に 0 にし、2 回目は no-op で安全に抜ける。
while [[ $# -gt 0 ]]; do
  case "$1" in
    --pr)           PR_NUMBER="${2:-}"; shift; shift ;;
    --content-file) CONTENT_FILE="${2:-}"; shift; shift ;;
    --results-dir)  REVIEW_RESULTS_DIR="${2:-}"; shift; shift ;;
    --pending-id)   PENDING_ID="${2:-}"; shift; shift ;;
    *) echo "ERROR: review-result-save: unknown option: $1" >&2; exit 1 ;;
  esac
done

if [ -z "$CONTENT_FILE" ]; then
  echo "ERROR: review-result-save: --content-file is required" >&2
  exit 1
fi
# 注: --content-file の存在チェック (`! -f`) は trap 登録 + pr_number gate の後ろ (下記) に移動した。
# D-04 非ブロッキング契約 (全失敗で exit 0 + EXIT trap での FILE_TIMESTAMP/ISO_TIMESTAMP/JSON_SAVED
# 必須 emit) を満たすため。引数自体の未指定 (上記 -z) は caller bug の fail-fast として exit 1 を維持する。

# --- save-pending marker path の内部導出 ---
# marker path は caller から受け取らず、id token から helper 内で組み立てる (sibling の
# review-nonblocking-record.sh と同形)。full path を受け取る設計は、caller 由来の任意文字列が
# 削除対象・機械可読 sentinel の両方へ同時に流れるため、traversal / sentinel 偽造 / 制御文字の
# 3 方向を個別に塞ぐ guard が必要になり、しかもその guard が生成側の値域 (${TMPDIR} の文字種) と
# 食い違うと「保存は成功したのに marker が消えず 8.0.4 が恒久的に落ちる」非収束を生む。
# 内部導出ならその失敗クラス自体が存在しない。
#
# 未指定は marker 機構 opt-out (後方互換)。非空かつ不正な id は導出せず marker を残す —
# 8.0.4 が loud に落ちて caller の置換漏れを差し戻す方向 (誤 pass ではない安全側)。
PENDING_MARKER=""
case "${PENDING_ID:-}" in
  '') ;;
  *'{'*|*'}'*|*[!A-Za-z0-9._-]*)
    # 値の verbatim echo は禁止 (sibling の ITERATION_ID gate と同じ理由 — 改行入りの値をそのまま
    # 出すと診断行の中に完全な形の sentinel を再現できる)。neutralize_ctrl で 1 行に潰す。
    echo "WARNING: review-result-save: --pending-id が literal substitute されていないか不正な文字を含みます (値: '$(printf '%s' "$PENDING_ID" | neutralize_ctrl)')" >&2
    echo "  期待: 英数字 / '.' / '_' / '-' のみからなる非空文字列 (例: 2078-1799999999)" >&2
    echo "  marker path を導出できないため削除しません — ステップ 8.0.4 が残存を検出して差し戻します" >&2
    ;;
  *) PENDING_MARKER="${TMPDIR:-/tmp}/rite-p61a-pending-${PENDING_ID}" ;;
esac

# --- trap 保護対象 + observability emit ---
# json_tmp / mktemp_err / jq_val_err_r は trap 保護 (orphan 防止)。file_timestamp /
# json_saved emit を EXIT trap 内に移動し normal/abnormal 両経路で必ず emit する
# (ステップ 6.1.c が前提)。
json_tmp=""
mktemp_err=""
iso_timestamp=""
file_timestamp=""
file_timestamp_emitted="false"
json_saved="false"
jq_val_err_r=""
_rite_review_p61a_cleanup() {
  rm -f "${json_tmp:-}" "${mktemp_err:-}" "${jq_val_err_r:-}"
  if [ "$file_timestamp_emitted" = "false" ]; then
    echo "[CONTEXT] FILE_TIMESTAMP=${file_timestamp:-unknown}" >&2
    echo "[CONTEXT] ISO_TIMESTAMP=${iso_timestamp:-unknown}" >&2
    echo "[CONTEXT] JSON_SAVED=${json_saved:-false}" >&2
    # save-pending marker の consume。本 trap に到達した = 本 helper が完走した、が marker の意味。
    # path は引数確定時に内部導出済 (未導出なら空 = no-op)。`rm` の stderr は抑止しない —
    # 削除失敗は決定論的で 6.1.a の再実行では収束しないため、errno がそのまま見えている必要がある。
    # `-e` は dangling symlink を偽と判定するため `-L` も見る (8.0.4 Pre-Check と同条件)。
    # `rm -f` は symlink を追随しないので誤削除にはならない。
    if [ -n "$PENDING_MARKER" ] && { [ -e "$PENDING_MARKER" ] || [ -L "$PENDING_MARKER" ]; } \
       && ! LC_ALL=C rm -f "$PENDING_MARKER"; then
      echo "WARNING: save-pending marker の削除に失敗しました ($PENDING_MARKER)。ステップ 8.0.4 は本 cycle の 6.1.a を未実行と誤判定します" >&2
      echo "  対処: 削除失敗は決定論的なため 6.1.a の再実行では収束しません。marker を手動で rm してから ステップ 8.0 を再評価してください" >&2
    fi
    echo "[CONTEXT] REVIEW_SAVE_DONE=1; pr=${PR_NUMBER:-}; marker=${PENDING_MARKER:-}; saved=${json_saved:-false}" >&2
    file_timestamp_emitted="true"
  fi
}
# signal 中断で **保存が未完了**なら失敗として扱う。cleanup だけを呼ぶと marker は消え
# `saved=false` は出るが `LOCAL_SAVE_FAILED` が 1 件も出ず、(a) ステップ 8.0.4 の「`saved=false` なら
# reason を転記」が入力を持たず、(b) 既定 `post_comment: false` では ステップ 6.1.c が
# `--local-save-failed` だけを見るためケース 1 に落ち、存在しないパスを「保存済み」として提示する。
#
# **`json_saved` を見ることが必須** — mv 成功後に signal が届く窓があり、そこで無条件に失敗を
# 宣言すると JSON が実在するのに 6.1.c ケース 2 が `exit 2` してレビュー結果を「失われた」と
# 誤報告する (保存が成功した cycle を停止させるのは MUST NOT「保存失敗で review cycle を
# 停止しない」より強い違反)。sibling の review-nonblocking-record.sh が signal 中断について
# 「投稿されたか否かは不明として扱う」と設計しているのと同じ、断定を避ける分類。
_rite_review_p61a_signal() {
  if [ "$json_saved" != "true" ]; then
    echo "WARNING: review-result-save: $2 で中断されました。レビュー結果 JSON は保存されていません" >&2
    echo "  対処: 中断原因 (Bash tool timeout / 手動 Ctrl-C) を取り除き ステップ 6.1.a を step 0 から再実行してください" >&2
    echo "[CONTEXT] LOCAL_SAVE_FAILED=1; reason=signal_aborted; signal=$2" >&2
  else
    echo "WARNING: review-result-save: $2 で中断されましたが JSON は保存済みです。ステップ 6 は続行して差し支えありません" >&2
  fi
  _rite_review_p61a_cleanup
  exit "$1"
}
trap 'rc=$?; _rite_review_p61a_cleanup; exit $rc' EXIT
trap '_rite_review_p61a_signal 130 INT' INT
trap '_rite_review_p61a_signal 143 TERM' TERM
trap '_rite_review_p61a_signal 129 HUP' HUP

# pr_number 数値 fail-fast gate (cleanup.md ステップ 6 の numeric glob と対称)。
# literal placeholder 残留 / 空文字 / 異常値を reject (非ブロッキングで skip)。
case "$PR_NUMBER" in
  ''|*[!0-9]*)
    echo "ERROR: review-result-save: pr_number が数値ではありません (値: '$PR_NUMBER', 期待: 数値のみ非空)" >&2
    echo "  caller は ステップ 1.0 で正規化された pr_number を --pr に渡す必要があります" >&2
    echo "[CONTEXT] LOCAL_SAVE_FAILED=1; reason=pr_number_placeholder_residue" >&2
    exit 0
    ;;
esac

# --content-file 存在チェック (trap 登録後 = 非ブロッキング経路)。
# 本チェックを trap 登録前 (arg parse 直後) に置いて exit 1 すると、(a) D-04「全失敗経路で
# exit 0」契約を破り、(b) EXIT trap が emit する FILE_TIMESTAMP/ISO_TIMESTAMP/JSON_SAVED
# (ステップ 6.1.c が前提) を skip してしまうため、trap 登録後に配置する。
# caller が Write tool での JSON body 書き出しを忘れる / Write 先 path と --content-file path が
# 食い違う runtime 失敗を write_failure (JSON body を読めない = write 系失敗) として非ブロッキングに扱う。
if [ ! -f "$CONTENT_FILE" ]; then
  echo "WARNING: review-result-save: --content-file not found: $CONTENT_FILE" >&2
  echo "  caller (ステップ 6.1.a) が Write tool での JSON body 書き出しを忘れたか、Write 先 path と --content-file path が食い違っている可能性があります" >&2
  echo "[CONTEXT] LOCAL_SAVE_FAILED=1; reason=write_failure" >&2
  exit 0
fi

# ISO 8601 timestamp (TZ=Asia/Tokyo, JST 固定, BSD/GNU date 両対応)。
# 単一 date 呼出から iso/file 両 timestamp を導出し秒跨ぎズレを排除する。
_ts_raw=$(TZ='Asia/Tokyo' date +'%Y-%m-%dT%H:%M:%S+09:00|%Y%m%d%H%M%S') || _ts_raw=""
iso_timestamp="${_ts_raw%%|*}"
file_timestamp="${_ts_raw##*|}"

if [ -z "$iso_timestamp" ] || [ -z "$file_timestamp" ]; then
  echo "WARNING: date コマンドの実行に失敗しました。ローカル保存をスキップします" >&2
  echo "  対処: TZ=Asia/Tokyo / date バイナリの存在を確認してください" >&2
  echo "[CONTEXT] LOCAL_SAVE_FAILED=1; reason=date_command_failure" >&2
  exit 0
fi

json_path="${REVIEW_RESULTS_DIR}/${PR_NUMBER}-${file_timestamp}.json"

# Create directory (失敗してもステップ 6 を fail させない)
mkdir_err=$(mktemp "${TMPDIR:-/tmp}/rite-review-p61a-mkdir-err-XXXXXX" 2>/dev/null) || mkdir_err=""
if ! mkdir -p "$REVIEW_RESULTS_DIR" 2>"${mkdir_err:-/dev/null}"; then
  echo "WARNING: .rite/review-results/ ディレクトリの作成に失敗しました。会話コンテキストのみで続行します。" >&2
  [ -n "$mkdir_err" ] && [ -s "$mkdir_err" ] && head -5 "$mkdir_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
  echo "  対処: 親ディレクトリの permission / disk space / read-only filesystem を確認してください" >&2
  echo "[CONTEXT] LOCAL_SAVE_FAILED=1; reason=mkdir_failure" >&2
  [ -n "$mkdir_err" ] && rm -f "$mkdir_err"
  exit 0
fi
[ -n "$mkdir_err" ] && rm -f "$mkdir_err"

# mktemp stderr 退避 (失敗原因 disk full / permission / readonly を可視化)。
# 退避 tempfile を作る mktemp 自体の失敗も silent 化しない。
if ! mktemp_err=$(mktemp "${TMPDIR:-/tmp}/rite-review-p61a-mktemp-err-XXXXXX" 2>/dev/null); then
  echo "WARNING: mktemp stderr 退避用 tempfile の mktemp に失敗しました (meta エラー)。json_tmp 失敗時の stderr 詳細は失われます" >&2
  mktemp_err=""
fi

if ! json_tmp=$(mktemp "${TMPDIR:-/tmp}/rite-review-p61a-json-XXXXXX.json" 2>"${mktemp_err:-/dev/null}"); then
  echo "WARNING: JSON 一時ファイルの作成に失敗しました" >&2
  [ -n "$mktemp_err" ] && [ -s "$mktemp_err" ] && { echo "  詳細 (mktemp stderr):" >&2; head -5 "$mktemp_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2; }
  echo "  対処: /tmp の容量 / permission / readonly filesystem を確認してください" >&2
  echo "[CONTEXT] LOCAL_SAVE_FAILED=1; reason=mktemp_failure" >&2
  [ -n "$mktemp_err" ] && rm -f "$mktemp_err"
  exit 0
fi
[ -n "$mktemp_err" ] && rm -f "$mktemp_err"

# caller が Write tool で書いた JSON body を json_tmp にコピーする (旧 heredoc 相当)。
if ! cat "$CONTENT_FILE" > "$json_tmp"; then
  echo "WARNING: JSON 一時ファイルへの書き込みに失敗しました" >&2
  echo "[CONTEXT] LOCAL_SAVE_FAILED=1; reason=write_failure" >&2
  exit 0
fi
if [ ! -s "$json_tmp" ]; then
  echo "WARNING: JSON 一時ファイルが空です (cat 成功だが post-condition 違反)" >&2
  echo "[CONTEXT] LOCAL_SAVE_FAILED=1; reason=write_failure" >&2
  exit 0
fi

# Approach C: bash-internal jq timestamp injection。
# caller が `"timestamp": "__RITE_TS_PLACEHOLDER_7f3a9b2c__"` を書き込み、ここで $iso_timestamp に
# 置換する。JSON body / ファイル名 / [CONTEXT] emit の 3 値が helper 内で完全同期する。
json_ts_injected=$(mktemp "${TMPDIR:-/tmp}/rite-review-p61a-json-ts-XXXXXX.json" 2>/dev/null) || json_ts_injected=""
jq_ts_err=$(mktemp "${TMPDIR:-/tmp}/rite-review-p61a-jq-ts-err-XXXXXX" 2>/dev/null) || jq_ts_err=""
if [ -z "$json_ts_injected" ]; then
  echo "WARNING: timestamp 注入用 tempfile の mktemp に失敗しました" >&2
  echo "[CONTEXT] LOCAL_SAVE_FAILED=1; reason=write_failure" >&2
  exit 0
elif jq --arg ts "$iso_timestamp" '.timestamp = $ts' "$json_tmp" > "$json_ts_injected" 2>"${jq_ts_err:-/dev/null}"; then
  # inner mv 失敗時は sentinel 残留 JSON を final path に書かないよう skip する。
  if ! mv "$json_ts_injected" "$json_tmp" 2>/dev/null; then
    echo "WARNING: timestamp 注入済み tmpfile の mv に失敗しました (cross-fs / permission / TOCTOU)" >&2
    echo "[CONTEXT] LOCAL_SAVE_FAILED=1; reason=timestamp_injection_mv_failure" >&2
    rm -f "$json_ts_injected"
    [ -n "$jq_ts_err" ] && rm -f "$jq_ts_err"
    exit 0
  fi
else
  echo "WARNING: jq による timestamp 注入に失敗しました (sentinel 置換不可)" >&2
  [ -n "$jq_ts_err" ] && [ -s "$jq_ts_err" ] && head -3 "$jq_ts_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
  echo "  対処: --content-file で渡した JSON body ($CONTENT_FILE) が valid JSON で、.timestamp フィールド (sentinel __RITE_TS_PLACEHOLDER_7f3a9b2c__) を持つか確認してください" >&2
  echo "[CONTEXT] LOCAL_SAVE_FAILED=1; reason=write_failure" >&2
  rm -f "$json_ts_injected"
  [ -n "$jq_ts_err" ] && rm -f "$jq_ts_err"
  exit 0
fi
[ -n "$jq_ts_err" ] && rm -f "$jq_ts_err"

# --- Validation chain (全て非ブロッキング: WARNING + reason emit + exit 0) ---
# 直前の jq timestamp 注入が入力 JSON を parse・再シリアライズして valid JSON を保証するため、
# syntactically invalid JSON (literal substitute 漏れ含む) はそこで write_failure として既に fail する。
# 下記 json_invalid は注入成功後に走る defense-in-depth backstop であり、syntactic invalidity 経由では
# effectively unreachable (その経路の実発火 reason は write_failure)。
jq_val_err_r=$(mktemp "${TMPDIR:-/tmp}/rite-jq-val-err-r-XXXXXX" 2>/dev/null) || jq_val_err_r=""
if ! jq empty "$json_tmp" 2>"${jq_val_err_r:-/dev/null}"; then
  echo "WARNING: JSON 一時ファイルが syntactically invalid です (注入後に外部要因で破損した稀ケース。通常の literal substitute 漏れは upstream の write_failure で検出済)" >&2
  [ -n "${jq_val_err_r:-}" ] && [ -s "$jq_val_err_r" ] && head -3 "$jq_val_err_r" | neutralize_ctrl --keep-newline | sed 's/^/  jq: /' >&2
  echo "  内容 preview (先頭 5 行):" >&2
  head -5 "$json_tmp" 2>/dev/null | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
  echo "  対処: review-result-schema.md に従った正しい JSON が生成されているか確認してください" >&2
  echo "[CONTEXT] LOCAL_SAVE_FAILED=1; reason=json_invalid" >&2
  exit 0
fi

if ! jq -e '
  (.schema_version | type == "string" and length > 0)
  and (.pr_number | type == "number")
  and (.findings | type == "array")
  ' "$json_tmp" >/dev/null 2>&1; then
  echo "WARNING: JSON が必須フィールド (schema_version 非空文字列 / pr_number 数値型 / findings[] 配列型) を欠いています" >&2
  echo "  対処: review-result-schema.md に従った完全な JSON が生成されているか確認してください" >&2
  echo "[CONTEXT] LOCAL_SAVE_FAILED=1; reason=schema_required_fields_missing" >&2
  exit 0
fi

# NOTE:
#   pr-review.md ステップ 6.1.a の原実装は `[.findings[].id] | unique | length == (.findings | length)`
#   と書いており、jq では `length == (.findings | length)` の `.findings` がパイプ後の配列
#   (unique 結果) に対して評価され "Cannot index array with string findings" でエラーになる。
#   その結果 findings を 1 件でも持つレビューは本 check が常に jq エラー → `! jq -e` が true →
#   finding_id_format_or_uniqueness_violation を emit して local save に失敗していた
#   (D-04 非ブロッキング + 会話/PR コメント fallback で production では露見していなかった)。
#   委譲時に左辺を `([.findings[].id] | unique | length)` と括弧付けして本来意図した
#   「書式 + 一意性」検証に修正した (空配列 PASS / valid F-NN PASS / dup・F-1 violation で検証済)。
# non_blocking_findings は write 側で 0 件でも空配列を出す義務がある
# (review-result-schema.md §non_blocking_findings: キー省略は「本ゲート適用前の世代」を意味し、
#  「降格ゼロ」と区別できないと降格が記録されなかった事故を後から検出できない)。
#
# **本 check は save を中止しない**。LOCAL_SAVE_FAILED 経路は JSON_SAVED=false でファイルを
# 保存しないため、キー欠落や型崩れを hard fail にすると「降格記録の欠落」を理由に blocking
# findings ごと永続チャネルから失う fail-unsafe になる (救おうとした対象より大きなものを落とす)。
# observability marker のみ emit して保存は続行する。
#
# **順序が重要**: 本 check は下段の id gate より **前** に置く。後ろに置くと、非配列で
# `length` が非 0 になる値 ("abc"→3 / 3→3 / {"a":1}→1 / true→error) が id gate の $total を
# 水増しし、`.non_blocking_findings[]?` が要素を返さないことによる arity 不一致で hard fail する
# (= 非ブロッキングと宣言した経路が型によって hard fail に化ける)。
if ! jq -e 'has("non_blocking_findings") and (.non_blocking_findings | type == "array")' "$json_tmp" >/dev/null 2>&1; then
  echo "WARNING: JSON に non_blocking_findings[] がないか配列ではありません (保存は続行します)" >&2
  echo "  期待: 0 件でも \"non_blocking_findings\": [] を出力する (キー省略は本ゲート適用前の世代を意味し区別不能になる)" >&2
  echo "  対処: review-result-schema.md §non_blocking_findings 配列 を確認してください" >&2
  echo "[CONTEXT] NON_BLOCKING_FINDINGS_KEY_MISSING=1; pr=$PR_NUMBER" >&2
fi

# id 書式 + 一意性を `findings[]` と `non_blocking_findings[]` の **和集合** で評価する
# (review-result-schema.md §non_blocking_findings の「id は 2 配列の和集合で一意」規則の強制層。
#  findings[] だけを見ると、配列ごとに F-01 から独立採番した JSON が素通りして永続化される)。
# reason 語彙は既存を流用し増やさない (reason 表 / Eval-order enumeration の同期不要)。
#
# 非配列は上段の type check で marker 済みなので、ここでは `$nb` に空配列として畳んで
# 判定から外す (型崩れを id 欠陥として誤診断せず、かつ hard fail に化けさせない)。
#
# **hard fail の対象は `findings[]` 側の id 欠陥に限る**。`non_blocking_findings[]` 側に閉じた
# id 欠陥 (独立採番による和集合重複 / id 欠落) で save 全体を落とすと、上段と同じ fail-unsafe
# (advisory な記録の欠陥を理由に blocking findings を失う) になるため、marker のみ emit する。
if ! jq -e '
  (.findings | length == 0)
  or (
    (.findings | all(.id? // "" | test("^F-[0-9]{2,}$")))
    and (([.findings[].id] | unique | length) == (.findings | length))
  )
  ' "$json_tmp" >/dev/null 2>&1; then
  echo "WARNING: JSON の findings[].id が書式 (F-NN) または一意性の要件を満たしていません" >&2
  echo "  期待: 全 finding が ^F-[0-9]{2,}\$ に match し、かつ全 id が一意" >&2
  echo "  対処: review-result-schema.md の findings[] id 仕様を確認してください" >&2
  echo "[CONTEXT] LOCAL_SAVE_FAILED=1; reason=finding_id_format_or_uniqueness_violation" >&2
  exit 0
fi

# 和集合一意性 (non_blocking_findings[] 側を含む) は非ブロッキング marker で報告する
if ! jq -e '
  ((if (.non_blocking_findings | type) == "array" then .non_blocking_findings else [] end)) as $nb
  | ((.findings | length) + ($nb | length)) as $total
  | ($total == 0)
  or (
    ([(.findings[]?, $nb[])] | all(.id? // "" | test("^F-[0-9]{2,}$")))
    and (([(.findings[]?, $nb[]) | .id] | unique | length) == $total)
  )
  ' "$json_tmp" >/dev/null 2>&1; then
  echo "WARNING: findings[] と non_blocking_findings[] の id が和集合で一意でないか、書式 (F-NN) 違反があります (保存は続行します)" >&2
  echo "  期待: 5.3.0.M の降格時に id を振り直さず、2 配列の和集合で ^F-[0-9]{2,}\$ かつ一意" >&2
  echo "  対処: review-result-schema.md §non_blocking_findings 配列 の id 規則を確認してください" >&2
  echo "[CONTEXT] NON_BLOCKING_FINDINGS_ID_UNION_VIOLATION=1; pr=$PR_NUMBER" >&2
fi

_schema_ver=$(jq -r '.schema_version // "unknown"' "$json_tmp" 2>/dev/null)
if [ "$_schema_ver" = "1.1.0" ] && ! jq -e '
  .findings | all(
    (.scope // null) as $s
    | $s == "current-pr" or $s == "follow-up" or $s == "nit-noted"
  )
  ' "$json_tmp" >/dev/null 2>&1; then
  echo "WARNING: JSON の findings[].scope が enum 違反 (期待: current-pr / follow-up / nit-noted)" >&2
  echo "  対処: reviewer が schema 1.1.0 の scope 列を正しく出力しているか確認" >&2
  echo "[CONTEXT] LOCAL_SAVE_FAILED=1; reason=scope_enum_violation" >&2
  exit 0
fi

if [ "$_schema_ver" = "1.1.0" ] && ! jq -e '
  [.findings[]? | select((.severity == "CRITICAL" or .severity == "HIGH") and .scope == "nit-noted")] | length == 0
  ' "$json_tmp" >/dev/null 2>&1; then
  violation_count_review=$(jq '[.findings[]? | select((.severity == "CRITICAL" or .severity == "HIGH") and .scope == "nit-noted")] | length' "$json_tmp" 2>/dev/null || echo "?")
  echo "WARNING: JSON の findings[] に cross-field invariant #4 違反 (severity ∈ {CRITICAL, HIGH} × scope == nit-noted) が $violation_count_review 件存在します" >&2
  echo "  invariant #4: blocker (CRITICAL/HIGH) 級の指摘を nit-noted として受け流すことは禁止" >&2
  echo "  対処: reviewer が severity を MEDIUM/LOW へ自己降格し、original_severity フィールドに元値を保持する経路を使う" >&2
  echo "[CONTEXT] LOCAL_SAVE_FAILED=1; reason=critical_high_scope_nit_noted_invariant; count=$violation_count_review" >&2
  exit 0
fi

# --- 同一秒衝突回避 + atomic mv ---
# `~$RANDOM` suffix (separator `~` は `.` より ASCII 大で sort -r 時に collision-resolved 版が先頭)。
# 再衝突は collision_resolution_exhausted で skip (silent overwrite 防止、履歴保持契約)。
if [ -e "$json_path" ]; then
  json_path_alt="${REVIEW_RESULTS_DIR}/${PR_NUMBER}-${file_timestamp}~$(printf '%04x' "${RANDOM:-0}").json"
  if [ -e "$json_path_alt" ]; then
    echo "WARNING: collision suffix 付与後も再衝突を検出しました ($json_path_alt)。保存を skip します" >&2
    echo "  原因候補: 同秒 3 回目以降の連続実行 / \$RANDOM が fallback '0' に落ちた / parallel race" >&2
    echo "  対処: 1 秒待機してから /rite:pr-review を再実行してください" >&2
    echo "[CONTEXT] LOCAL_SAVE_FAILED=1; reason=collision_resolution_exhausted; original=$json_path; resolved_attempt=$json_path_alt" >&2
    json_saved="false"
    exit 0
  fi
  echo "WARNING: 同一秒衝突を検出しました ($json_path)。collision suffix を追加します: $json_path_alt" >&2
  echo "[CONTEXT] LOCAL_SAVE_COLLISION=1; original=$json_path; resolved=$json_path_alt" >&2
  json_path="$json_path_alt"
fi

# mv stderr 退避 (cross-FS / perm / TOCTOU / path-too-long を区別可能に)。
if ! mv_err=$(mktemp "${TMPDIR:-/tmp}/rite-review-p61a-mv-err-XXXXXX"); then
  echo "WARNING: mv stderr 退避用 tempfile の mktemp に失敗しました。mv 失敗時の stderr は失われます" >&2
  echo "[CONTEXT] LOCAL_SAVE_FAILED=1; reason=mktemp_failure_mv_err" >&2
  mv_err=""
fi
if mv "$json_tmp" "$json_path" 2>"${mv_err:-/dev/null}"; then
  echo "✅ レビュー結果を保存しました: $json_path" >&2
  json_saved="true"
  json_tmp=""  # mv 成功後は trap 削除対象から外す
  [ -n "$mv_err" ] && rm -f "$mv_err"
else
  echo "WARNING: JSON ファイルの配置に失敗しました" >&2
  echo "  from: $json_tmp" >&2
  echo "  to:   $json_path" >&2
  [ -n "$mv_err" ] && [ -s "$mv_err" ] && { echo "  詳細 (mv stderr 先頭 5 行):" >&2; head -5 "$mv_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2; }
  echo "  対処: cross-filesystem / permission denied / read-only FS / path-too-long / TOCTOU のいずれかを確認してください" >&2
  echo "[CONTEXT] LOCAL_SAVE_FAILED=1; reason=mv_failure" >&2
  [ -n "$mv_err" ] && rm -f "$mv_err"
fi

exit 0
