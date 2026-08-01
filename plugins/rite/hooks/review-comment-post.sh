#!/bin/bash
# rite workflow - Review Result PR Comment Post
# Deterministic helper for skills/pr-review/SKILL.md ステップ 6.1.b (PR Comment Post)。
#
# pr-review.md ステップ 6.1.b の PR コメント投稿処理 (post_comment_mode gate + 複数 case gate +
# scope 限定 awk sentinel 置換 + 2 つの post-condition + atomic mv + gh pr comment + signal 検出)
# を担う。本文側の巨大 inline bash を helper に切り出すことで、単一 Bash invocation での malform
# 無言停止を回避する。PR コメント本文 (Markdown + Raw JSON
# section) は caller が Write tool で tmpfile に書き出し `--content-file` で渡す (heredoc malform 源を撤廃)。
#
# Usage:
#   bash review-comment-post.sh \
#     --pr <number> \
#     --post-comment-mode <true|false> \
#     --json-saved <true|false> \
#     --iso-timestamp <ISO8601> \
#     --content-file <path>
#
#   caller (pr-review.md ステップ 6.1.b) は以下を行う:
#     1. ステップ 5.4 統合レポート (Markdown) + ステップ 6.1.a と構造的に同一の Raw JSON
#        (timestamp フィールドに literal sentinel "__RITE_TS_PLACEHOLDER_7f3a9b2c__") を含む
#        PR コメント本文を生成し、**Write tool** で tmpfile に保存する。
#     2. ステップ 6.1.a の [CONTEXT] ISO_TIMESTAMP= / JSON_SAVED= を会話コンテキストから読み取り、
#        --iso-timestamp / --json-saved に渡す。
#     3. 本 helper を実行する。
#
# 契約 (pr-review.md ステップ 6.1.b と verbatim 一致):
#   - post_comment_mode machine-enforced gate: true→続行 / false→exit 0 silent skip
#     (gh pr comment を絶対に実行しない) / その他→ERROR + [review:error] + exit 1。
#   - ブロッキング: 失敗は `[CONTEXT] REVIEW_OUTPUT_FAILED=1; reason=...` を emit し exit 1
#     (ステップ 6.1.a の非ブロッキング契約とは対照的)。reason 語彙:
#       p61b_post_comment_mode_invalid / p61b_pr_number_invalid / json_saved_from_p61a_unset /
#       iso_timestamp_from_p61a_unset / tmpfile_write_failure /
#       raw_json_timestamp_injection_failed / gh_comment_post_failure
#   - Raw JSON section 内 (`### 📄 Raw JSON` 見出し後の ```json ~ ``` fence 内) の sentinel のみを
#     scope 限定 awk で $iso_timestamp に置換。post-condition (a) Raw JSON 内 sentinel 残留なし /
#     (b) Markdown 本文 (Raw JSON section 外) の literal sentinel 保存、の 2 点を検証。
#   - EXIT/INT/TERM/HUP trap で中間 tmpfile を cleanup。gh pr comment 失敗時は signal (rc>=128) を併記。
#   - [CONTEXT] / WARNING / [review:error] 以外の人間向けログは stderr。
#
# Exit codes:
#   0: PR コメント投稿成功、または post_comment_mode=false の silent skip。
#   1: gate 違反 / 操作失敗 (REVIEW_OUTPUT_FAILED emit 済)。引数エラー (--content-file 欠落等)。
set -uo pipefail
# shellcheck source=control-char-neutralize.sh
source "$(dirname "${BASH_SOURCE[0]}")/control-char-neutralize.sh"

SENTINEL='__RITE_TS_PLACEHOLDER_7f3a9b2c__'

# --- Argument parsing ---
PR_NUMBER=""
POST_COMMENT_MODE=""
JSON_SAVED=""
ISO_TIMESTAMP=""
CONTENT_FILE=""

# 各値付きフラグは `shift; shift` で消費する。値なしフラグが末尾に来た場合 ($#=1)、
# `shift 2` は $# を減らせず set -e 非設定 + `${2:-}` (nounset 非発火) の下で無限ループに
# 陥る。1 回目の shift で $# を確実に 0 にし、2 回目は no-op で安全に抜ける。
while [[ $# -gt 0 ]]; do
  case "$1" in
    --pr)                PR_NUMBER="${2:-}"; shift; shift ;;
    --post-comment-mode) POST_COMMENT_MODE="${2:-}"; shift; shift ;;
    --json-saved)        JSON_SAVED="${2:-}"; shift; shift ;;
    --iso-timestamp)     ISO_TIMESTAMP="${2:-}"; shift; shift ;;
    --content-file)      CONTENT_FILE="${2:-}"; shift; shift ;;
    *) echo "ERROR: review-comment-post: unknown option: $1" >&2; exit 1 ;;
  esac
done

# post_comment_mode machine-enforced gate。
# true→続行 / false→silent skip (gh pr comment 遮断、データ破壊なし) / その他→fail-fast。
case "$POST_COMMENT_MODE" in
  true) ;;
  false)
    exit 0
    ;;
  *)
    echo "ERROR: review-comment-post: post_comment_mode が true/false ではありません (値: '$POST_COMMENT_MODE')" >&2
    echo "  caller は ステップ 1.0 の [CONTEXT] POST_COMMENT_MODE=true|false emit 値を --post-comment-mode に渡す必要があります" >&2
    echo "[CONTEXT] REVIEW_OUTPUT_FAILED=1; reason=p61b_post_comment_mode_invalid; value=$POST_COMMENT_MODE" >&2
    echo "[review:error]"
    exit 1
    ;;
esac

# pr_number numeric gate
case "$PR_NUMBER" in
  ''|*[!0-9]*)
    echo "ERROR: review-comment-post: pr_number が数値ではありません (値: '$PR_NUMBER', 期待: 数値のみ非空)" >&2
    echo "[CONTEXT] REVIEW_OUTPUT_FAILED=1; reason=p61b_pr_number_invalid" >&2
    echo "[review:error]"
    exit 1
    ;;
esac

# json_saved gate (ステップ 6.1.a の [CONTEXT] JSON_SAVED=true|false)
case "$JSON_SAVED" in
  true|false) ;;
  *)
    echo "ERROR: review-comment-post: json_saved が true/false ではありません (値: '$JSON_SAVED')" >&2
    echo "  caller は ステップ 6.1.a の [CONTEXT] JSON_SAVED=true|false emit 値を --json-saved に渡す必要があります" >&2
    echo "[CONTEXT] REVIEW_OUTPUT_FAILED=1; reason=json_saved_from_p61a_unset" >&2
    exit 1
    ;;
esac

if [ -z "$CONTENT_FILE" ] || [ ! -f "$CONTENT_FILE" ]; then
  echo "ERROR: review-comment-post: --content-file が指定されていないか存在しません (値: '$CONTENT_FILE')" >&2
  echo "[CONTEXT] REVIEW_OUTPUT_FAILED=1; reason=tmpfile_write_failure" >&2
  exit 1
fi

# iso_timestamp fail-fast gate (ISO 8601 allowlist)。
# 旧 denylist (`{`-prefix / `}`-suffix / 空 / sentinel 完全一致のみ reject) は placeholder 残留の
# 典型形しか弾けず、`&`/`\` 等の awk replacement metacharacter や任意の不正値を素通ししていた。
# ISO 8601 形状 (`YYYY-MM-DDTHH:MM:SS` + `±HH:MM` または `Z`) の allowlist 検証に置換し、
# sentinel 残留 / 空文字 / placeholder 形式 / 非 ISO 形状をすべて同一 reason で reject する
# (substitute 漏れ時 sentinel が Raw JSON に残留し、fix.md Priority 3 が sentinel 付き timestamp で
# findings を解釈する silent regression を防ぐ機械的強制)。
# bash 組込み `[[ =~ ]]` を使う: `printf | grep -qE` は行単位マッチのため複数行値の
# いずれか 1 行が ISO 形状なら gate を通過する bypass 穴がある。`[[ =~ ]]` の `^`/`$` は
# 文字列全体に anchor され、改行を含む値を構造的に reject する (hooks/ の支配的 gate パターンとも整合)。
# `unknown` は ステップ 6.1.a の EXIT trap が timestamp 算出前の早期失敗時に emit する正規の
# degraded 値 (review-result-save.sh の `${iso_timestamp:-unknown}`)。読取漏れではないため、
# 「emit 値を渡せ」という誤診断で caller を同一値の再投入ループに誘導しないよう専用診断で reject する。
if [ "$ISO_TIMESTAMP" = "unknown" ]; then
  echo "ERROR: review-comment-post: iso_timestamp が degraded 値 'unknown' です (ステップ 6.1.a が timestamp 算出前に失敗)" >&2
  echo "  --iso-timestamp の再投入では解決しません。ステップ 6.1.a の [CONTEXT] LOCAL_SAVE_FAILED=1; reason=... を確認し、原因 (date 失敗 / 書込失敗等) を解消してから review をやり直してください" >&2
  echo "[CONTEXT] REVIEW_OUTPUT_FAILED=1; reason=iso_timestamp_from_p61a_unset" >&2
  exit 1
fi
_iso8601_re='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}([+-][0-9]{2}:[0-9]{2}|Z)$'
if ! [[ "$ISO_TIMESTAMP" =~ $_iso8601_re ]]; then
  echo "ERROR: review-comment-post: iso_timestamp が ISO 8601 形状ではありません (値: '$ISO_TIMESTAMP')" >&2
  echo "  caller は ステップ 6.1.a の [CONTEXT] ISO_TIMESTAMP=... emit 値を --iso-timestamp に渡す必要があります (例: 2026-04-11T12:34:56+09:00)" >&2
  echo "[CONTEXT] REVIEW_OUTPUT_FAILED=1; reason=iso_timestamp_from_p61a_unset" >&2
  exit 1
fi

# --- trap 保護 ---
tmpfile_patched=""
gh_err=""
_rite_review_p61b_cleanup() {
  rm -f "${tmpfile_patched:-}" "${gh_err:-}"
}
trap 'rc=$?; _rite_review_p61b_cleanup; exit $rc' EXIT
trap '_rite_review_p61b_cleanup; exit 130' INT
trap '_rite_review_p61b_cleanup; exit 143' TERM
trap '_rite_review_p61b_cleanup; exit 129' HUP

# テンプレートの `X` は**末尾**に置く。BSD/macOS の mktemp(1) は "trailing Xs" しか置換しない
# ため、`-XXXXXX.md` のように suffix が続く形では X が展開されず literal 名がそのまま使われる。
# その場合 O_CREAT|O_EXCL は初回だけ成功し、同名ファイルが 1 つでも残っていると以降の全実行が
# EEXIST で失敗する (下記 trap は SIGKILL では動かないため、残留は起こりうる)。
# 拡張子は不要 — 本 tempfile は awk の出力先と `gh pr comment --body-file` の引数としてのみ使う。
tmpfile_patched=$(mktemp "${TMPDIR:-/tmp}/rite-review-p61b-comment-patched-XXXXXX") || {
  echo "ERROR: timestamp 置換用 tmpfile 作成失敗" >&2
  echo "[CONTEXT] REVIEW_OUTPUT_FAILED=1; reason=tmpfile_write_failure" >&2
  exit 1
}

# Raw JSON section 内 (`### 📄 Raw JSON` 見出し後の ```json fence 内) の sentinel のみを
# $ISO_TIMESTAMP に置換する (Markdown 本文の literal sentinel には触れない scope 限定置換)。
# State machine: 全行を buffer し END block で最後の heading 以降の fence 内のみリテラル置換する
# (finding 列に literal `### 📄 Raw JSON` が含まれる反例に備え fix.md Priority 3 と同じ「last」方式)。
awk -v ts="$ISO_TIMESTAMP" -v sentinel="$SENTINEL" '
  { lines[NR] = $0 }
  /^### 📄 Raw JSON/ { last_heading = NR }
  END {
    in_fence = 0
    for (i = 1; i <= NR; i++) {
      if (i == last_heading) { past = 1; print lines[i]; continue }
      if (past && lines[i] ~ /^```json$/) { in_fence = 1; print lines[i]; continue }
      if (past && in_fence && lines[i] ~ /^```$/) { in_fence = 0; print lines[i]; continue }
      if (in_fence) {
        # index()/substr() ベースのリテラル置換。gsub の replacement に ts を
        # 直接埋め込むと `&` (マッチ全体に展開) / `\` (エスケープ) が metacharacter として
        # 解釈され置換結果が壊れる。index/substr は needle / replacement とも純リテラル扱い。
        # needle は SENTINEL 変数を -v で受け取る (値は backslash を含まないため -v の
        # escape 解釈は安全)。post-condition (a) 側の awk も同じ -v sentinel +
        # index() 検査で統一されている (参照経路の対称性)。
        needle = "\"" sentinel "\""
        repl = "\"" ts "\""
        line = lines[i]
        out = ""
        while ((pos = index(line, needle)) > 0) {
          out = out substr(line, 1, pos - 1) repl
          line = substr(line, pos + length(needle))
        }
        lines[i] = out line
      }
      print lines[i]
    }
  }
' "$CONTENT_FILE" > "$tmpfile_patched"
awk_rc=$?
if [ "$awk_rc" -ne 0 ]; then
  echo "ERROR: Raw JSON 内 sentinel の awk 置換に失敗しました (rc=$awk_rc)" >&2
  echo "[CONTEXT] REVIEW_OUTPUT_FAILED=1; reason=raw_json_timestamp_injection_failed" >&2
  exit 1
fi

# Post-condition (a): Raw JSON section 内に sentinel が残留していないこと。
# needle は置換側 awk と同じく SENTINEL 変数を -v で受け取り index() でリテラル検査する
# (置換側と検証側の sentinel 参照を変数経由に統一 — 片側だけ literal だと SENTINEL 値の
# 変更時に検証側が旧 literal を検索して空振り pass する silent drift の余地が生じる)。
remaining_in_raw_json=$(awk -v sentinel="$SENTINEL" '
  { lines[NR] = $0 }
  /^### 📄 Raw JSON/ { last_heading = NR }
  END {
    in_fence = 0
    needle = "\"" sentinel "\""
    for (i = 1; i <= NR; i++) {
      if (i == last_heading) { past = 1; continue }
      if (past && lines[i] ~ /^```json$/) { in_fence = 1; continue }
      if (past && in_fence && lines[i] ~ /^```$/) { in_fence = 0; continue }
      if (in_fence && index(lines[i], needle) > 0) { print lines[i] }
    }
  }
' "$tmpfile_patched")
if [ -n "$remaining_in_raw_json" ]; then
  echo "ERROR: 置換後も Raw JSON section 内に sentinel が残留しています" >&2
  echo "  ステップ 6.1.a が生成する JSON は timestamp フィールドを 1 箇所のみ持つ invariant が破られた可能性" >&2
  echo "[CONTEXT] REVIEW_OUTPUT_FAILED=1; reason=raw_json_timestamp_injection_failed" >&2
  exit 1
fi

# Post-condition (b): Markdown 本文 (Raw JSON section 外) の literal sentinel が保存されていること。
original_markdown=$(awk '
  /^### 📄 Raw JSON/ { last_heading = NR }
  { lines[NR] = $0 }
  END { for (i = 1; i < (last_heading ? last_heading : NR+1); i++) print lines[i] }
' "$CONTENT_FILE")
patched_markdown=$(awk '
  /^### 📄 Raw JSON/ { last_heading = NR }
  { lines[NR] = $0 }
  END { for (i = 1; i < (last_heading ? last_heading : NR+1); i++) print lines[i] }
' "$tmpfile_patched")
if [ "$original_markdown" != "$patched_markdown" ]; then
  echo "ERROR: sentinel 置換が Markdown 本文 (Raw JSON section 外) まで波及しました" >&2
  echo "  scope 限定 awk が Raw JSON section を正しく特定できなかった可能性" >&2
  echo "[CONTEXT] REVIEW_OUTPUT_FAILED=1; reason=raw_json_timestamp_injection_failed" >&2
  exit 1
fi

# gh pr comment 投稿 (exit code 明示捕捉、silent failure 防止)。
gh_err=$(mktemp "${TMPDIR:-/tmp}/rite-review-p61b-gh-err-XXXXXX") || gh_err=""
if gh pr comment "$PR_NUMBER" --body-file "$tmpfile_patched" 2>"${gh_err:-/dev/null}"; then
  if [ "$JSON_SAVED" = "false" ]; then
    echo "ℹ️ ローカルファイル保存は失敗しましたが、PR コメントへの投稿は成功しました。" >&2
    echo "  次回 /rite:fix は Priority 3 (PR コメント) から読取ります" >&2
  fi
  [ -n "$gh_err" ] && rm -f "$gh_err"
else
  gh_rc=$?
  echo "ERROR: PR コメント投稿に失敗しました (gh rc=$gh_rc)" >&2
  [ -n "$gh_err" ] && [ -s "$gh_err" ] && { echo "  詳細 (gh stderr 先頭 5 行):" >&2; head -5 "$gh_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2; }
  echo "  対処: gh auth status / network 接続 / PR #${PR_NUMBER} の権限を確認してください" >&2
  if [ "$JSON_SAVED" = "true" ]; then
    echo "ℹ️ ただし、レビュー結果はローカルファイルに保存済みです (ステップ 6.1.a)" >&2
    echo "  そのまま /rite:fix を実行できます (Priority 2 で自動読取)" >&2
  fi
  # SIGPIPE 等の signal 終了 (rc>=128) を retained flag に併記する (data 破損なしと write error を区別)。
  if [ "${gh_rc:-1}" -ge 128 ]; then
    gh_signal=$((gh_rc - 128))
    echo "[CONTEXT] REVIEW_OUTPUT_FAILED=1; reason=gh_comment_post_failure; rc=$gh_rc; signal=$gh_signal; json_saved=$JSON_SAVED" >&2
  else
    echo "[CONTEXT] REVIEW_OUTPUT_FAILED=1; reason=gh_comment_post_failure; rc=$gh_rc; json_saved=$JSON_SAVED" >&2
  fi
  [ -n "$gh_err" ] && rm -f "$gh_err"
  exit 1
fi

exit 0
