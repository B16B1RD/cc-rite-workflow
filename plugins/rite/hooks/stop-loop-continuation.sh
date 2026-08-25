#!/bin/bash
# rite workflow - Stop Hook: review↔fix loop continuation + terminal finalize
#                 + cleanup → wiki-ingest → wiki-lint チェーン継続保証
#
# Guarantees that /rite:iterate の review↔fix ループが、LLM が継続/終了 sentinel を
# 出した直後に turn を終了してしまっても、構造的な層で差し戻すことを保証する。
#   - 継続 sentinel ([review:fix-needed:N] / [fix:pushed] / [fix:pushed-wm-stale]) → 次ループへ自動継続
#   - 終了 sentinel ([review:mergeable] / [fix:replied-only] / [fix:cancelled-by-user]) → 完了通知を強制
#     FINALIZE:review:mergeable では transcript 最終 assistant に「未処理 non-blocking」欄があるか
#     検査し、欠落 / 判定不能は差し戻し reason に欄の再出力を要求する（1 回制限は consume に相乗り）
# 同じ one-shot handoff 機構で /rite:cleanup の wiki チェーン (cleanup → wiki-ingest →
# wiki-lint --auto) の未完走も差し戻す:
#   - ネスト最深部の [lint:returned-to-caller:auto] / [ingest:returned-to-caller] 直後に
#     turn が閉じても、cleanup ステップ 10-12 までの継続を 1 回だけ強制する
#
# 仕組み (one-shot consume / stop_hook_active に依存しない設計):
#   - 継続 sentinel を出す sub-skill (pr-review.md Step 8.0 / fix.md Step 5.1) が
#     flow-state に継続 handoff (例 "/rite:fix 99") をセットする。
#   - 終了 sentinel を出す sub-skill (pr-review.md Step 8.0 / fix.md Step 5.1 / Step 1.4 cancel) が
#     flow-state に終了 handoff (例 "FINALIZE:review:mergeable:99") をセットする。
#   - cleanup.md ステップ 9 が wiki-ingest invoke 直前にチェーン handoff
#     (例 "WIKICHAIN:cleanup:99") をセットする。チェーンがステップ 12 まで
#     完走した場合はステップ 12 末尾の flow-state.sh set (--handoff なし) が default-clear する。
#   - 本 hook は turn 終了時に flow-state.sh consume-handoff で handoff を
#     **読み取り + 削除** する (one-shot)。非空なら decision:block で停止を差し戻す。
#     handoff の prefix で reason を分岐する: "/rite:..." は次コマンド再注入、"FINALIZE:..." は
#     /rite:iterate ステップ5 完了通知の出力を要求、"WIKICHAIN:..." は cleanup チェーンの
#     残り step (ingest 残処理 → cleanup ステップ 10-12) の継続を要求する。
#   - 削除済みのため、進捗 (次コマンド実行 / 完了通知出力) の後に再度停止すれば handoff は空
#     → block しない (無限 block ループ防止)。
#   - 各継続点で継続 handoff が再セットされるため複数サイクル継続する。
#     終了点では FINALIZE handoff が 1 回だけ block し、完了通知出力後はクリーン終了する。
#     WIKICHAIN handoff も 1 回だけ block する one-shot で、チェーン再開後の再停止は許可される。
#
# Exit behavior:
#   exit 0 (no stdout)        — allow stop (handoff 不在 / loop 外 / 解決失敗 = fail-open)
#   stdout {"decision":"block"} — block stop and re-inject the continuation command or finalize directive
set -euo pipefail

# Double-execution guard (hooks.json + settings.local.json migration 由来の二重登録対策)
[ -z "${_RITE_HOOK_RUNNING_STOP:-}" ] || exit 0
export _RITE_HOOK_RUNNING_STOP=1

# Hook version resolution preamble (must be before INPUT=$(cat) to preserve stdin)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/hook-preamble.sh" 2>/dev/null || true

# Shared control-char neutralization (C0 + DEL + C1 0x80-0x9f → ?)。
# flow-state.sh と同じ必須依存扱い (unguarded source): 同 dir に無い = プラグイン破損であり、
# set -e による hook 全体終了は「解決失敗 = fail-open (停止許可)」の既存設計軸に収束する。
source "$SCRIPT_DIR/control-char-neutralize.sh"

# cat failure does not abort under set -e; || guard is defensive
INPUT=$(cat) || INPUT=""

# Parse session_id + cwd + transcript_path from the Stop payload (single jq invocation).
# Unit separator (\x1f) avoids IFS collapsing an empty field and left-shifting cwd.
# transcript_path が string 以外（array/object）なら空扱い = 残件欄検査不能 → fail-safe 差し戻し。
_jq_out=$(printf '%s' "$INPUT" | jq -r '[(.session_id // ""), (.cwd // ""), ((.transcript_path | if type == "string" then . else "" end) // "")] | join("")' 2>/dev/null) || _jq_out=$'\x1f\x1f'
IFS=$'\x1f' read -r SESSION_ID CWD TRANSCRIPT_PATH <<< "$_jq_out"

# session_id 不在 → loop state を解決できない → 停止許可 (fail-open)。
# Claude Code の Stop payload は常に session_id を含むため、空は非 Claude Code クライアント等の例外。
[ -n "$SESSION_ID" ] || exit 0
[ -n "$CWD" ] && [ -d "$CWD" ] || exit 0

# Resolve state root (git root or CWD) — post-tool-wm-sync.sh と同じ解決経路。
STATE_ROOT=$("$SCRIPT_DIR/state-path-resolve.sh" "$CWD" 2>/dev/null) || STATE_ROOT="$CWD"

# Read + clear the one-shot handoff marker. 通常は stderr を握る (loop 外セッションでは
# state file 不在が常態で diagnostic がノイズになるため)。RITE_DEBUG set 時のみ consume-handoff の
# 診断 ERROR (handoff clear 失敗等) を surface する — flow-state.sh consume-handoff は削除失敗時に
# stderr へ ERROR を emit するため、RITE_DEBUG gate を通せば永続 FS 障害の triage が可能になる。
if [ -n "${RITE_DEBUG:-}" ]; then
  HANDOFF=$(RITE_STATE_ROOT="$STATE_ROOT" "$SCRIPT_DIR/flow-state.sh" consume-handoff --session "$SESSION_ID") || HANDOFF=""
else
  HANDOFF=$(RITE_STATE_ROOT="$STATE_ROOT" "$SCRIPT_DIR/flow-state.sh" consume-handoff --session "$SESSION_ID" 2>/dev/null) || HANDOFF=""
fi

# handoff 不在 → 継続待ちでも終了通知待ちでもない → 停止許可。
[ -n "$HANDOFF" ] || exit 0

# handoff pending: 停止を差し戻す。handoff の prefix で reason を分岐する。
# block 可否は「handoff 非空」の軸のみで決まり、prefix は reason 文面の選択にのみ影響する。
#   FINALIZE:{result}:{pr}  = 終了 sentinel 到達 → /rite:iterate ステップ5 完了通知を強制
#   WIKICHAIN:{caller}:{pr} = cleanup チェーン未完走 → 残り step の継続を強制
#   /rite:...               = 継続 sentinel 到達 → 次ループコマンドを再注入
#   それ以外                 = 未知 prefix。silent に既定動作へ吸収せず WARNING で可視化した上で
#                             verbatim 再注入する (prefix 名前空間拡張時の分岐漏れ検出)
case "$HANDOFF" in
  FINALIZE:*)
    _result="${HANDOFF#FINALIZE:}"
    _nb_note=""
    case "$_result" in
      review:mergeable:*)
        # 残件欄検査。判定不能は差し戻す側へ fail-safe。1 回制限は既存 consume に相乗り。
        _nb_status=unknown
        if [ -n "${TRANSCRIPT_PATH:-}" ] && [ -f "$TRANSCRIPT_PATH" ] && [ -r "$TRANSCRIPT_PATH" ]; then
          _last_text=$(tail -n 200 "$TRANSCRIPT_PATH" | jq -rs '
            [ .[]
              | select(.type == "assistant")
              | .message.content
              | if type == "string" then .
                elif type == "array" then ([.[] | select(.type == "text") | .text] | join("\n"))
                else empty end
            ] | last // empty
          ' 2>/dev/null) || _last_text=""
          if [ -z "$_last_text" ]; then
            _nb_status=unknown
          elif printf '%s' "$_last_text" | grep -q '未処理 non-blocking'; then
            _nb_status=present
          else
            _nb_status=missing
          fi
        fi
        case "$_nb_status" in
          present) _nb_note="完了通知に「未処理 non-blocking:」欄を必ず含めてください（0 件でも省略しない）。" ;;
          missing) _nb_note="直前の完了通知に「未処理 non-blocking:」欄がありません。欄を含む完了通知を再出力してください（0 件でも省略しない）。" ;;
          *)       _nb_note="残件欄の有無を判定できなかったため、確認を出す側へ倒します。「未処理 non-blocking:」欄を含む完了通知を再出力してください（0 件でも省略しない）。" ;;
        esac
        ;;
    esac
    _reason="rite の review↔fix ループ (/rite:iterate) が終了 sentinel (${_result}) に到達しました。停止する前に /rite:iterate ステップ5 の完了通知 (終了理由 + 次ステップ案内) を必ず出力してください。${_nb_note:+
$_nb_note}

handoff は consume 済みのため、完了通知を出力した後に再度停止すれば停止が許可されます (無限 block しません)。"
    ;;
  WIKICHAIN:*)
    _pr="${HANDOFF##*:}"
    _reason="rite の cleanup → wiki-ingest → wiki-lint チェーン (PR #${_pr}) がまだ完走していません。停止せず、未実行の step を順に継続してください: wiki-ingest の残り step (lint 結果 parse → 完了レポート + [ingest:returned-to-caller]) → /rite:cleanup ステップ 10 (関連 Issue close) → ステップ 11 (作業メモリ最終化 + ローカルファイル削除) → ステップ 12 (完了報告 + flow-state terminal)。wiki-ingest / wiki-lint の成否に関わらず cleanup ステップ 10 以降へ進むのが契約です。

handoff は consume 済みのため、進捗なく再度停止した場合は次回は停止が許可されます (無限 block しません)。"
    ;;
  /rite:*)
    _reason="rite の review↔fix ループ (/rite:iterate) が継続中です。停止せず、次を実行してください: ${HANDOFF}

このループは [review:mergeable] / [fix:replied-only] / [fix:cancelled-by-user] のいずれかに到達するか、ユーザーが Ctrl+C で中断するまで継続します。handoff は consume 済みのため、進捗なく再度停止した場合は次回は停止が許可されます。"
    ;;
  *)
    # 未知 prefix: 新 prefix 追加時の case 分岐漏れを silent 吸収しない (fail-loud)。block 自体は
    # 「handoff 非空 → block」の設計軸を維持し、handoff 値を verbatim で差し戻す。
    # WARNING への埋め込みは共通ヘルパー neutralize_ctrl で制御文字を neutralize する
    # (flow-state.sh _emit_jq_err_snippet と同一規約。旧 ${HANDOFF//[[:cntrl:]]/?} が素通し
    # していた C1 0x80-0x9f もカバー / ANSI escape による operator 端末乗っ取り防止)。
    # neutralize 失敗時は raw 値を echo せず placeholder へ縮退 (fail-closed)。
    _handoff_safe=$(printf '%s' "$HANDOFF" | neutralize_ctrl) || _handoff_safe="(neutralize failed)"
    echo "WARNING: stop-loop-continuation: unknown handoff prefix (re-injecting verbatim; add an explicit case arm for new prefixes): ${_handoff_safe}" >&2
    _reason="rite の handoff マーカーが未消化のまま残っていました。停止せず、次を実行してください: ${HANDOFF}

handoff は consume 済みのため、進捗なく再度停止した場合は次回は停止が許可されます (無限 block しません)。"
    ;;
esac

# decision:block を JSON で emit。jq 失敗時は literal JSON にフォールバックして継続意図を保つ
# (pre-tool-bash-guard.sh の fail-closed フォールバックと同様の堅牢化)。
# 手動エスケープは \ / " / 改行のみのため、HANDOFF 由来の C0 生バイト (raw ESC 等) が残ると
# RFC 8259 違反の invalid JSON になる — neutralize_ctrl --c0-only で ? 化する。
# default モードを使わないのは、バイト単位の C1 置換が _reason の UTF-8 日本語 (モデルへの
# 継続指示文) を破壊するため。C1 素通しが jq プライマリ経路と対称なのは valid UTF-8 の
# C1 (0xc2 0x9b 等) のみで、raw 8-bit 単独の C1 バイト (0x9b 等) は jq が U+FFFD に
# 置換するのに対し本経路は素通しする (非対称 — control-char-neutralize.sh の Contract 参照)。
# neutralize 失敗時は raw を emit せず placeholder へ縮退 (fail-closed — unknown-prefix
# WARNING 経路と同じ規約)。
if ! jq -n --arg r "$_reason" '{decision:"block", reason:$r}'; then
  _r_esc="${_reason//\\/\\\\}"
  _r_esc="${_r_esc//\"/\\\"}"
  _r_esc="${_r_esc//$'\n'/\\n}"
  _r_esc=$(printf '%s' "$_r_esc" | neutralize_ctrl --c0-only) \
    || _r_esc="rite handoff continuation pending (reason neutralization failed). Re-run the previous /rite command or run /rite:recover."
  printf '{"decision":"block","reason":"%s"}\n' "$_r_esc"
fi
exit 0
