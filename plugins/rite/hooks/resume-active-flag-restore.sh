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
# The seven no-state paths (canonical enumeration in resume.md — verified-review cycle 36 F-07 fix):
#   (a) per-session AND legacy files both absent (conjunctive)
#   (b) file present but phase is null/missing/false (jq // operator)
#   (c) phase is an empty string
#   (d) file is empty (size 0) or corrupt JSON
#   (e) foreign:* — schema_v=2 + per-session absent + legacy.session_id is foreign session
#   (f) corrupt:* — schema_v=2 + per-session absent + legacy jq parse fails
#   (g) invalid_uuid:* — schema_v=2 + per-session absent + legacy.session_id JSON-parseable but UUID-invalid
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
# verified-review cycle 38 F-01 HIGH / F-09 MEDIUM (cycle 39 数値ドリフト解消): expand existence check to all
# directly invoked helpers (具体的なリストは下記 for loop が SoT。旧コメントは「all 4 directly invoked helpers」と
# 書いていたが実際の loop は 5 helper を検査しており数値ドリフトを起こしていたため、verified-review cycle 39 で
# 数値削除に統一)。本 helper は state-read.sh / flow-state-update.sh / state-path-resolve.sh /
# `_resolve-session-id.sh` / `_resolve-session-id-from-file.sh` を `bash <missing>` invocation 経路で直接依存する。
# state-read.sh / flow-state-update.sh が呼ぶ transitive helpers (`_resolve-schema-version.sh` 等) はそれぞれの
# スクリプト先頭の同型チェックで塞がれる。Issue #687 root cause (writer/reader 片肺更新型 silent regression) と
# 同型の deploy regression を構造的に防ぐ。state-read.sh / flow-state-update.sh の同型ブロックと統一表記。
for _helper in state-read.sh flow-state-update.sh state-path-resolve.sh \
               _resolve-session-id.sh _resolve-session-id-from-file.sh; do
  if [ ! -x "$PLUGIN_ROOT/hooks/$_helper" ]; then
    echo "ERROR: $_helper not found or not executable: $PLUGIN_ROOT/hooks/$_helper" >&2
    exit 1
  fi
done
unset _helper

# PR #688 followup F-02 LOW / cycle 38 F-15 LOW: state-read.sh の per-session resolver
# (.rite-session-id を tr で読み `_resolve-session-id.sh` に渡す block) および
# flow-state-update.sh の `_resolve_session_id` 関数と対称化。
# STATE_ROOT を state-path-resolve.sh 経由で解決してから .rite-session-id を読む (cycle 34 F-01
# の DRY 化主張との整合)。cwd != repo root で invoke された場合でも正しく解決される。
# cycle 38 F-15: 旧コメント「state-read.sh:93」は state-read.sh の per-session resolver
# (.rite-session-id を tr で読んで `_resolve-session-id.sh` に渡す block) を指す stale 行番号参照
# だった (Wiki 経験則「semantic anchor 必須」原則違反)。関数名 / 動作記述 anchor に置換。
STATE_ROOT=$("$PLUGIN_ROOT/hooks/state-path-resolve.sh" "$(pwd)") || STATE_ROOT="$(pwd)"

# state-read.sh は per-session/legacy 両方を transparent に解決し、両方不在時は default を返す。
# 本 helper の field は hardcoded 値 (phase / next_action) のため state-read.sh の field validation
# は通過する想定 (FIELD allowlist `^[a-zA-Z_][a-zA-Z0-9_]*$` に match)。
#
# verified-review cycle 33 fix (F-02 HIGH): 旧 `|| true` を fail-fast に変更。
# 本 helper の field allowlist は実装上必ず通過するため、吸収すべき non-zero は実質的に
# 「helper 起動失敗」(SCRIPT_DIR 解決失敗 / `_resolve-schema-version.sh` ENOENT 等) のみで、
# それを silent suppression するのは Fail-Fast First 原則と矛盾する (Wiki: 累積対策方針 = silent
# failure 抑制系の reasonable 防御は cycle 22-32 で確立済み)。stderr は state-read.sh から
# 直接 pass-through し (上流で WARNING / ERROR が出る場合に観測可能)、exit code を check して
# 失敗時は本 helper を fail-fast 終了する。
# verified-review cycle 36 F-14 fix: switch from `cmd || { rc=$?; ... }` to canonical
# `if cmd; then :; else rc=$?; fi` form for consistency with the 6 caller sites in
# commands/issue/start.md / implement.md / pr/review.md (cycle 35 F-04 fix). Both
# `||` short-circuit and `if/else` correctly preserve `$?`, but style unification
# helps maintainers grep for the canonical anti-pattern check.
if curr_phase=$(bash "$PLUGIN_ROOT/hooks/state-read.sh" --field phase --default ""); then
  :
else
  rc=$?
  echo "ERROR: state-read.sh failed (rc=$rc) for --field phase" >&2
  exit 1
fi
if curr_next=$(bash "$PLUGIN_ROOT/hooks/state-read.sh" --field next_action --default "Resume continuation."); then
  :
else
  rc=$?
  echo "ERROR: state-read.sh failed (rc=$rc) for --field next_action" >&2
  exit 1
fi

# .rite-session-id を STATE_ROOT 経由で読む (不在時 / 無効 UUID 時は空文字)。
# verified-review cycle 38 F-05 MEDIUM: `tr + _resolve-session-id.sh + fallback` の compound sequence を
# `_resolve-session-id-from-file.sh` 共通 helper に置換。state-read.sh の per-session resolver / flow-state-update.sh の
# `_resolve_session_id` 関数と writer/reader/resume 3 layer 対称化。UUID validation 自体は cycle 34 F-01 で
# 既に DRY 化済 (`_resolve-session-id.sh`) で、本 cycle はその上流の compound 動作も DRY 化する。
_sid=$(bash "$PLUGIN_ROOT/hooks/_resolve-session-id-from-file.sh" "$STATE_ROOT")

# PR #688 cycle 10 fix (F-01 CRITICAL): curr_phase 空文字ガード。
# state-read.sh が空文字を返す経路 (resume.md Phase 3.0.1 trailing prose の canonical enumeration
# of the four paths のいずれか) で `flow-state-update.sh patch --phase ""` を呼ぶと、
# flow-state-update.sh patch mode の `[[ -z "$PHASE" || -z "$NEXT" ]]` validation が `--if-exists`
# check より先に評価されて exit 1 し、resume が hard abort する (cycle 9 で実際に発生した
# CRITICAL 経路)。空文字時はそもそも patch を呼ばずに skip し、invoked command
# (e.g., rite:issue:start) の create mode に委譲する。
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
# tempfile leak を防ぐ。flow-state-update.sh の `trap 'rm -f "$TMP_STATE" 2>/dev/null' EXIT TERM INT HUP`
# (perform_atomic_write 関数内) と統一する。Linux の /tmp 自動 cleanup でカバーされるが convention
# 統一のため追加。
#
# PR #688 cycle 24 fix (F-01 CRITICAL): EXIT trap 経路で script exit code を保持する。
# 旧実装 (cycle 22) は `trap '_rite_resume_active_cleanup' EXIT` で関数を直接 trap 登録していたが、
# `_rite_resume_active_cleanup` の最終評価式 `[ -n "${_err:-}" ] && rm -f "$_err"` は `_err=""` 時に
# `[ -n "" ]` (rc=1) で短絡し関数 return code 1 になる。`set -euo pipefail` 下で EXIT trap の
# return code が script exit code を上書きするため、helper の最終 `exit 0` が exit 1 で kill され、
# resume.md Phase 3.0.1 末尾の `if ! bash {plugin_root}/hooks/resume-active-flag-restore.sh` invocation
# guard で hard-abort 経路に流れる。patch 自体は成功しているのに resume が中断される silent regression。
#
# 修正:
#   (A) cleanup 関数末尾に `return 0` を追加 — 関数自体が非 0 を返さないようにする。
#       これが **必要十分な fix**。`set -euo pipefail` 下で cleanup 関数が非 0 を返すと trap action
#       が `set -e` で中断され、後続の `exit $rc` に到達しない (実証済: bash -c で `[ -n "" ] && rm`
#       の後に exit 0 でも rc=1)。bash-trap-patterns.md の "cleanup 関数の契約" 節 Form B (portability
#       variant: `[ -n "${var:-}" ] && rm -f "$var"` 形式) では `return 0` が必須と明記されており、
#       本 helper の `_rite_resume_active_cleanup` 関数 (Form B 形式: `[ -n "${var:-}" ] && rm -f`
#       + 末尾 `return 0`) と整合する (function rc 漏洩の防止)。
#   (B) trap action を `rc=$?; cleanup; exit $rc` の wiki-query-inject.sh の signal-specific trap pattern
#       (4 行 EXIT/INT/TERM/HUP) と同型に統一 — canonical pattern との表記統一 (cosmetic alignment)。
#
# 重要 — (B) は defense-in-depth として機能しない: cleanup 関数が `return N (N≠0)` を返すと、(B) の
# trap action は `rc=$?` で原 exit code を退避するものの、後続の `cleanup` 呼び出しで `set -e` が
# trap action を中断し、`exit $rc` に到達せずに cleanup の rc=N が script exit code として伝播する
# (cycle 25 reviewer による empirical 検証済み: `cleanup return 7` + (B) trap → script exit 7、
# 原 exit code 0 は保持されない)。よって (B) のみで cycle 22 regression を修正することは**不可能**。
# (A) `return 0` の削除は cycle 22 silent regression の再導入になるため厳禁。
_err=""
_rite_resume_active_cleanup() {
  [ -n "${_err:-}" ] && rm -f "$_err"
  return 0  # (A) 関数を強制 0 復帰させ、`set -e` 下での trap action 中断を防ぐ
}
trap 'rc=$?; _rite_resume_active_cleanup; exit $rc' EXIT
trap '_rite_resume_active_cleanup; exit 130' INT
trap '_rite_resume_active_cleanup; exit 143' TERM
trap '_rite_resume_active_cleanup; exit 129' HUP

# verified-review (PR #688 cycle 39) MEDIUM (code-reviewer L-02): mktemp に `2>/dev/null` を追加。
# state-read.sh L247 / _resolve-cross-session-guard.sh L83 と同形式に統一する (mktemp 失敗時に
# `mktemp: cannot create temp file: ...` が WARNING より先に stderr に出て二重表示される問題を解消)。
_err=$(mktemp /tmp/rite-resume-flow-err-XXXXXX 2>/dev/null) || {
  echo "WARNING: stderr 退避用 tempfile の mktemp に失敗しました (/tmp full / permission denied?)" >&2
  echo "  影響: 次の error 発生時、flow-state-update.sh の具体的失敗原因 (mv 失敗 / UUID validation 失敗 / jq parse error 等) が表示されません" >&2
  _err=""
}

# PR #688 cycle 22 fix (F-02 MEDIUM): sid 有無の if/else 完全 duplication を patch_args 配列パターンに統一。
# flow-state-update.sh の確立済 `JQ_ARGS=()` + `JQ_ARGS+=()` 条件付き append convention と同型
# (変数名は本 helper の文脈に合わせて patch_args)。失敗ハンドラブロック (echo / head -3 sed / exit 1) を
# 1 か所にまとめ、将来 `--phase` / `--next` 等の patch 引数を変更する際の片肺更新 drift を防ぐ
# (tempfile cleanup は `_rite_resume_active_cleanup` 関数 + EXIT/INT/TERM/HUP trap で別途対応)。
# PR #688 cycle 24 fix (F-03 MEDIUM): cycle 22 で導入されたコメントの drift を修正
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

# PR #688 cycle 32 F-06 fix: even on patch success, surface WORKFLOW_INCIDENT sentinels
# from flow-state-update.sh stderr (e.g. cross-session takeover refused — the patch silent-skips
# via --if-exists but the incident sentinel must reach the orchestrator for observability).
if [ -n "$_err" ] && [ -s "$_err" ] && LC_ALL=C grep -qF 'WORKFLOW_INCIDENT' "$_err"; then
  cat "$_err" >&2
fi

exit 0
