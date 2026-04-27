#!/bin/bash
# rite workflow - Resume Active Flag Restore (helper script)
#
# Purpose: Restore the `active=true` flag in flow-state during /rite:resume,
# guarding against the cycle 9 hard abort regression (empty phase passed to
# flow-state-update.sh patch validation).
#
# Extracted from resume.md Phase 3.0.1 bash block (PR #688 cycle 18 fix F-03)
# to enable direct test coverage in tests/resume-active-flag-restore.test.sh.
# Previously the bash block was inline in resume.md and could not be tested
# without extracting / eval'ing the markdown — TC-1.2 / TC-3.2 ended up
# tautologically asserting the bash language semantics rather than the
# actual guard implementation.
#
# Usage:
#   bash plugins/rite/hooks/resume-active-flag-restore.sh <plugin_root>
#
# Behavior:
#   1. Read curr_phase / curr_next via state-read.sh (per-session/legacy 透過解決)
#   2. If curr_phase is empty (state-read.sh returned default ""):
#      - Print informational skip message to stderr
#      - Exit 0 (legitimate skip — invoked command will create mode init)
#   3. Otherwise: invoke flow-state-update.sh patch with --if-exists,
#      passing --session if .rite-session-id is present, omitting if not
#
# The four no-state paths (canonical enumeration in resume.md):
#   (a) per-session AND legacy files both absent (conjunctive)
#   (b) file present but phase is null/missing/false (jq // operator)
#   (c) phase is an empty string
#   (d) file is empty (size 0) or corrupt JSON
#
# Exit codes:
#   0: success (patch executed) or legitimate skip (curr_phase empty)
#   1: flow-state-update.sh patch failed (validation error / IO failure)

set -euo pipefail

PLUGIN_ROOT="${1:-}"
if [ -z "$PLUGIN_ROOT" ]; then
  echo "ERROR: plugin_root argument required" >&2
  echo "  Usage: bash $0 <plugin_root>" >&2
  exit 1
fi
if [ ! -x "$PLUGIN_ROOT/hooks/state-read.sh" ]; then
  echo "ERROR: state-read.sh not found or not executable: $PLUGIN_ROOT/hooks/state-read.sh" >&2
  exit 1
fi
if [ ! -x "$PLUGIN_ROOT/hooks/flow-state-update.sh" ]; then
  echo "ERROR: flow-state-update.sh not found or not executable: $PLUGIN_ROOT/hooks/flow-state-update.sh" >&2
  exit 1
fi

# state-read.sh は per-session/legacy 両方を transparent に解決し、両方不在時は default を返す。
# `|| true` で state-read.sh の non-zero exit を吸収する (set -e 下での silent abort 回避)。
# 本 helper の field は hardcoded 値 (phase / next_action) のため state-read.sh の field validation
# は通過する想定 (FIELD allowlist `^[a-zA-Z_][a-zA-Z0-9_]*$` に match)。
curr_phase=$(bash "$PLUGIN_ROOT/hooks/state-read.sh" --field phase --default "" || true)
curr_next=$(bash "$PLUGIN_ROOT/hooks/state-read.sh" --field next_action --default "Resume continuation." || true)

# .rite-session-id を読む (不在時は空文字)。改行 / 空白を tr で除去。
# `|| _sid=""` で cat 失敗 (file 不在 / permission denied 等) を吸収。
_sid=$(cat .rite-session-id 2>/dev/null | tr -d '[:space:]') || _sid=""

# PR #688 cycle 22 fix (F-01 HIGH): tampered .rite-session-id (non-UUID) を空扱いに正規化。
# state-read.sh:75 / flow-state-update.sh:78 と対称な「invalid → empty で legacy fallback」semantics
# を本 helper にも適用する。これがないと tampered content (例: `../../../etc/passwd`) が
# `--session "$_sid"` として下流 flow-state-update.sh の _resolve_session_id (provided_sid path)
# に流入し、UUID validation で reject されて helper exit 1 → resume hard-abort する経路が成立する
# (cycle 9-10 で修正した F-01 CRITICAL empty phase hard-abort と同類型の regression)。
# RFC 4122 strict: 8-4-4-4-12 hex with hyphens at fixed positions。
if [[ -n "$_sid" && ! "$_sid" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
  _sid=""
fi

# PR #688 cycle 10 fix (F-01 CRITICAL): curr_phase 空文字ガード。
# state-read.sh が空文字を返す経路 (resume.md L391 の canonical enumeration の 4 path) で
# `flow-state-update.sh patch --phase ""` を呼ぶと、flow-state-update.sh patch mode の
# `[[ -z "$PHASE" || -z "$NEXT" ]]` validation が `--if-exists` check より先に評価されて
# exit 1 し、resume が hard abort する (cycle 9 で実際に発生した CRITICAL 経路)。
# 空文字時はそもそも patch を呼ばずに skip し、invoked command (e.g., rite:issue:start)
# の create mode に委譲する。
if [ -z "$curr_phase" ]; then
  echo "ℹ️  flow-state phase が解決できなかったため active flag 復元を skip しました (per-session/legacy file 両不在、または phase が null/空文字 — invoked command が create mode で初期化します)" >&2
  exit 0
fi

# PR #688 cycle 8 fix (F-01 旧 CRITICAL): pipeline `2>&1 | head -3` を除去し stderr を tmpfile に
# 退避する pattern に変更。pipefail 未設定下では pipeline 終端 head -3 の exit 0 が支配的になり、
# 上流 flow-state-update.sh の exit 1 を silent に握りつぶしていた経路を解消。
#
# PR #688 cycle 10 fix (F-03 MEDIUM): mktemp 失敗時に WARNING を追加。`_err=""` fallback で
# `2>"${_err:-/dev/null}"` が /dev/null に redirect される経路で flow-state-update.sh の具体的
# 失敗原因 (`ERROR: mv failed (patch mode)` 等) が消える silent suppression 反パターンを可視化する。
#
# PR #688 cycle 22 fix (LOW recommendation): signal-specific trap で SIGINT/SIGTERM/SIGHUP 中断時の
# tempfile leak を防ぐ。flow-state-update.sh:228 の `trap 'rm -f "$TMP_STATE" 2>/dev/null' EXIT TERM INT HUP`
# と統一する。Linux の /tmp 自動 cleanup でカバーされるが convention 統一のため追加。
#
# PR #688 cycle 24 fix (F-01 CRITICAL): EXIT trap 経路で script exit code を保持する。
# 旧実装 (cycle 22) は `trap '_rite_resume_active_cleanup' EXIT` で関数を直接 trap 登録していたが、
# `_rite_resume_active_cleanup` の最終評価式 `[ -n "${_err:-}" ] && rm -f "$_err"` は `_err=""` 時に
# `[ -n "" ]` (rc=1) で短絡し関数 return code 1 になる。`set -euo pipefail` 下で EXIT trap の
# return code が script exit code を上書きするため、helper の最終 `exit 0` が exit 1 で
# kill され、resume.md L344 の `if ! bash {plugin_root}/hooks/...` で hard-abort 経路に流れる。
# patch 自体は成功しているのに resume が中断される silent regression。
#
# 修正は **二重防御** で対応:
#   (A) cleanup 関数末尾に `return 0` を追加 — 関数自体が非 0 を返さないようにする。
#       `set -euo pipefail` 下で cleanup 関数が非 0 を返すと trap action が `set -e` で中断され
#       後続の `exit $rc` に到達しない (実証済: bash -c で `[ -n "" ] && rm` の後に exit 0 でも rc=1)
#   (B) trap action を `rc=$?; cleanup; exit $rc` の wiki-query-inject.sh:59 同型 pattern に統一 —
#       元の exit code を `rc=$?` で退避して `exit $rc` で復元する defense-in-depth
# (A) のみでも修正可能だが、(B) を併用することで将来 cleanup 関数に他のコマンドが追加されて非 0 を
# 返す経路が増えても script exit code が保持される。
_err=""
_rite_resume_active_cleanup() {
  [ -n "${_err:-}" ] && rm -f "$_err"
  return 0  # (A) 関数を強制 0 復帰させ、`set -e` 下での trap action 中断を防ぐ
}
trap 'rc=$?; _rite_resume_active_cleanup; exit $rc' EXIT
trap '_rite_resume_active_cleanup; exit 130' INT
trap '_rite_resume_active_cleanup; exit 143' TERM
trap '_rite_resume_active_cleanup; exit 129' HUP

_err=$(mktemp /tmp/rite-resume-flow-err-XXXXXX) || {
  echo "WARNING: stderr 退避用 tempfile の mktemp に失敗しました (/tmp full / permission denied?)" >&2
  echo "  影響: 次の error 発生時、flow-state-update.sh の具体的失敗原因 (mv 失敗 / UUID validation 失敗 / jq parse error 等) が表示されません" >&2
  _err=""
}

# PR #688 cycle 22 fix (F-02 MEDIUM): sid 有無の if/else 完全 duplication を patch_args 配列パターンに統一。
# flow-state-update.sh:374-390 で確立済の `JQ_ARGS=()` + `JQ_ARGS+=()` 条件付き append convention と同型
# (変数名は本 helper の文脈に合わせて patch_args)。失敗ハンドラブロック (echo / head -3 sed / exit 1) を
# 1 か所にまとめ、将来 `--phase` / `--next` 等の patch 引数を変更する際の片肺更新 drift を防ぐ
# (tempfile cleanup は L99-105 の trap で別途 EXIT/INT/TERM/HUP に対応)。
# PR #688 cycle 24 fix (F-03 MEDIUM): cycle 22 cycle 22 コメントの drift を修正
# (旧表記の "JQ_ARGS 配列パターン" / "rm -f を含む failure handler" が実装と乖離していた)。
patch_args=(--phase "$curr_phase" --next "$curr_next" --active true --if-exists)
if [ -n "$_sid" ]; then
  patch_args+=(--session "$_sid")
fi

if ! bash "$PLUGIN_ROOT/hooks/flow-state-update.sh" patch "${patch_args[@]}" 2>"${_err:-/dev/null}"; then
  echo "ERROR: failed to restore active flag, abort resume" >&2
  [ -n "$_err" ] && [ -s "$_err" ] && head -3 "$_err" | sed 's/^/  /' >&2
  exit 1
fi

exit 0
