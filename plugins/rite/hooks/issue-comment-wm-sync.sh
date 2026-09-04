#!/bin/bash
# rite workflow - Issue Comment Work Memory Sync
# Deterministic script for Issue comment work memory operations.
# Handles: comment creation (init), retrieval, transformation, safety checks, and PATCH.
# Text transformations are delegated to issue-comment-wm-update.py (stdin→stdout).
#
# Usage:
#   Init mode (create new work memory comment):
#     bash issue-comment-wm-sync.sh init --issue 42 --branch "feat/issue-42-test"
#
#   Fetch mode (GET body once into a file; no PATCH):
#     bash issue-comment-wm-sync.sh fetch --issue 42 --out /tmp/wm-body.md
#
#   Patch mode (safety_check + PATCH an already-transformed file):
#     bash issue-comment-wm-sync.sh patch --issue 42 --in /tmp/wm-updated.md \
#       --original-length 1234 --transform-label update-phase
#
#   Update mode (transform and PATCH existing comment):
#     bash issue-comment-wm-sync.sh update --issue 42 \
#       --transform update-phase --phase "phase5_review" --phase-detail "レビュー中"
#
#     bash issue-comment-wm-sync.sh update --issue 42 \
#       --transform update-progress \
#       --impl-status "✅ 完了" --test-status "⬜ 未着手" --doc-status "⬜ 未着手" \
#       --changed-files-file "${TMPDIR:-/tmp}/files.md"
#
#     bash issue-comment-wm-sync.sh update --issue 42 \
#       --transform append-section --section "品質チェック履歴" --content-file "${TMPDIR:-/tmp}/lint.md"
#
#     bash issue-comment-wm-sync.sh update --issue 42 \
#       --transform append-eof --content-file "${TMPDIR:-/tmp}/completion.md"
#
#     bash issue-comment-wm-sync.sh update --issue 42 \
#       --transform merge-checklist --section 進捗サマリー --content-file "${TMPDIR:-/tmp}/items.md"
#
# Options:
#   --issue            Issue number (required)
#   --branch           Branch name (init mode)
#   --transform        Python subcommand to apply (update mode, required)
#   --out              Output file for fetch mode
#   --in               Input file for patch mode
#   --original-length  Original body byte length (patch mode, 50% rule)
#   --transform-label  Transform name for safety_check (patch mode)
#   (remaining args are passed through to the Python script)
#
# Exit codes:
#   0: Success or non-blocking skip (WARNING on stderr)
#   1: Argument error
#
# Status output (stdout, update mode) — caller shim 用の機械可読 1 行:
#   status=success                          PATCH 成功
#   status=skipped; reason=no_comment       作業メモリ comment 不在 (初回 fix 等, legitimate no-op)
#   status=skipped; reason=body_fetch_failed gh api での body 取得失敗 (auth/rate/network/404)
#   status=skipped; reason=safety_check_failed body 空 / header 欠落 / <50% で PATCH 拒否
#   status=skipped; reason=section_absent   merge-checklist: 対象 ### section 不在で新規 items を置けず
#                                           (Python exit 10。items は破棄せず PATCH もしない —)
#   status=error; reason=transform_failed   Python transform が非ゼロ exit (exit 10 以外)
#   status=error; reason=patch_failed       jq | gh api PATCH が失敗
#   skills/fix/SKILL.md ステップ 4.5.2 はこの行を read し、no_comment 以外の skipped/error を
#   `[CONTEXT] WM_UPDATE_FAILED=1` にマップする (`[fix:pushed-wm-stale]` routing 用)。
#
# Status output (stdout, init mode) — caller shim 用の機械可読 1 行:
#   status=success                          replica 投稿 + 検証成功
#   status=skipped; reason=already_exists   replica 既存 (冪等 pre-check による skip)
#   status=unverified                       投稿は実行されたが検証 (3 回 retry) で発見できず
#   (status 行なし)                          投稿本体 gh issue comment / owner-repo 取得 / mktemp の
#                                           失敗 (WARNING + exit 0、non-blocking)
#   skills/open/SKILL.md ステップ 2.5 はこの行を read し、status 分岐表で続行判断する。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=control-char-neutralize.sh
source "$SCRIPT_DIR/control-char-neutralize.sh"
PYTHON_SCRIPT="$SCRIPT_DIR/issue-comment-wm-update.py"

# --- File-wide tmpfile trap 保護 ---
# trap + cleanup パターンの canonical 説明は references/bash-trap-patterns.md#signal-specific-trap-template 参照
# (rationale: signal 別 exit code、race window 回避、rc=$? capture、${var:-} safety、関数契約)
# 対象は親シェル top-level で mktemp する tmpfile 全部。関数 local の tmpfile は対象外:
# get_owner_repo / get_comment_id (_err) は command substitution subshell 経由のため親の trap
# から構造的に到達不能。cache_comment_id (tmp / _jq_err / _cid_mv_err) は init mode で親シェル
# から直接呼ばれる経路もあるが、いずれも通常経路は各関数の inline rm -f が清掃し、signal 時の
# 残存は許容する。
# backup_file は失敗時 post-mortem 用に意図的に trap 対象外 (成功時のみ明示 rm)。
_fs_err=""
_pre_err=""
tmpfile=""
_init_err=""
_verify_err=""
_cb_err=""
body_tmp=""
updated_tmp=""
py_err_tmp=""
patch_err=""
_fetch_out=""
_rite_wm_sync_cleanup() {
  rm -f "${_fs_err:-}" "${_pre_err:-}" "${tmpfile:-}" "${_init_err:-}" "${_verify_err:-}" \
    "${_cb_err:-}" "${body_tmp:-}" "${updated_tmp:-}" "${py_err_tmp:-}" "${patch_err:-}" \
    "${_fetch_out:-}"
}
trap 'rc=$?; _rite_wm_sync_cleanup; exit $rc' EXIT
trap '_rite_wm_sync_cleanup; exit 130' INT
trap '_rite_wm_sync_cleanup; exit 143' TERM
trap '_rite_wm_sync_cleanup; exit 129' HUP

# ⚠ 下行はテスト hooks/tests/issue-comment-wm-sync.test.sh が awk 抽出アンカーとして参照する。変更時はテスト側の awk パターンも同時更新すること
# Resolve repository root for .rite-flow-state access
CWD="${CWD:-$(pwd)}"
STATE_ROOT=$("$SCRIPT_DIR/state-path-resolve.sh" "$CWD" 2>/dev/null) || STATE_ROOT="$CWD"

# Resolve the current session's flow-state path via the canonical resolver
# (flow-state.sh path — schema_v2/v3 per-session file under .rite/sessions/).
# The legacy shared file (.rite-flow-state) does not exist in schema_v2/v3-only
# environments, so caching against it always misses and forces a full gh api
# comments scan on every call ( same root cause as 's
# cleanup-work-memory.sh). Fall back to the legacy shared file only when
# session resolution itself fails (no .rite-session-id / session env var
# available) — surface that fallback with a WARNING for diagnosability.
_fs_err=$(mktemp 2>/dev/null) || _fs_err=""
if RESOLVED_FLOW_STATE=$(RITE_STATE_ROOT="$STATE_ROOT" "$SCRIPT_DIR/flow-state.sh" path 2>"${_fs_err:-/dev/null}"); then
  :
else
  echo "WARNING: issue-comment-wm-sync: flow-state.sh path resolution failed — falling back to legacy $(basename "$STATE_ROOT/.rite-flow-state") (session_id may be missing or invalid)" >&2
  [ -n "$_fs_err" ] && [ -s "$_fs_err" ] && head -3 "$_fs_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
  RESOLVED_FLOW_STATE=""
fi
[ -n "$_fs_err" ] && rm -f "$_fs_err"
# This fallback is one of the two paths that can still write `.rite-flow-state`;
# see the LEGACY_STATE comment in flow-state.sh for the full picture.
FLOW_STATE="${RESOLVED_FLOW_STATE:-$STATE_ROOT/.rite-flow-state}"

# --- Get owner/repo ---
# stderr を完全抑止すると、auth expiry / network outage / cwd outside repo の区別がつかず
# 「owner/repo 取得不能 = Issue comment 経路の機能停止」が silent に発生する。stderr を
# tempfile capture して、失敗時に WARNING で根本原因を expose する。
get_owner_repo() {
  local _err _rc=0 _out _git_err _git_or_line _git_owner _git_repo
  # git-remote parse first: works even when `origin` is an SSH Host alias
  # unrecognized by gh's host allowlist. Falls through to
  # `gh repo view` below whenever the parse fails (no origin remote,
  # unparseable URL, charset-rejected).
  # Anchored to `cd "$STATE_ROOT"` (same as post-compact.sh) so this resolves
  # the intended repo rather than whatever git repo the ambient process cwd
  # happens to sit in — `cd` here is subshell-scoped via the `$(...)` this
  # function is always called through, so it cannot affect the caller's cwd.
  _git_err=$(mktemp 2>/dev/null) || _git_err=""
  _git_or_line=$(cd "$STATE_ROOT" 2>/dev/null && bash "$SCRIPT_DIR/scripts/lib/git-remote.sh" resolve-owner-repo 2>"${_git_err:-/dev/null}") || _git_or_line=""
  if [ -n "$_git_or_line" ]; then
    IFS=$'\t' read -r _git_owner _git_repo <<< "$_git_or_line"
    if [ -n "$_git_owner" ] && [ -n "$_git_repo" ]; then
      [ -n "$_git_err" ] && rm -f "$_git_err"
      printf '%s/%s' "$_git_owner" "$_git_repo"
      return
    fi
  fi
  _err=$(mktemp 2>/dev/null) || _err=""
  # cd "$STATE_ROOT" here too (same as the git-remote fast path above and
  # post-compact.sh's fallback) — without it, this fallback could resolve a
  # different repo than the fast path when cwd != STATE_ROOT.
  _out=$(cd "$STATE_ROOT" 2>/dev/null && gh repo view --json owner,name --jq '.owner.login + "/" + .name' 2>"${_err:-/dev/null}") || _rc=$?
  if [ "$_rc" -ne 0 ] || [ -z "$_out" ]; then
    # WARNING header is unconditional — gh repo view's own stderr may be
    # empty (e.g. `cd "$STATE_ROOT"` itself failed, short-circuiting before
    # gh ever ran), which must not suppress the header itself, only the
    # optional detail lines below it.
    echo "[rite] WARNING: issue-comment-wm-sync: gh repo view failed (rc=$_rc)" >&2
    if [ -n "$_err" ] && [ -s "$_err" ]; then
      head -3 "$_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
    fi
    # Both resolution paths failed at this point — also surface why the
    # git-remote fast path bailed, or this WARNING would show only the
    # fallback's side of a two-sided failure.
    if [ -n "$_git_err" ] && [ -s "$_git_err" ]; then
      head -3 "$_git_err" | neutralize_ctrl --keep-newline | sed 's/^/  git-remote: /' >&2
    fi
    _out=""
  fi
  [ -n "$_err" ] && rm -f "$_err"
  [ -n "$_git_err" ] && rm -f "$_git_err"
  printf '%s' "$_out"
}

# Caching is best-effort because get_comment_id() falls back to a full gh api
# scan, but a silent cache failure makes every subsequent invocation re-scan
# all comments — accelerating rate-limit hits. Surface mktemp / jq / mv
# failures so this degradation can be diagnosed instead of mistaken for normal
# behaviour.
cache_comment_id() {
  local cid="$1"
  [ -f "$FLOW_STATE" ] || return 0
  local tmp
  if ! tmp=$(mktemp 2>/dev/null); then
    echo "[rite] WARNING: issue-comment-wm-sync: cache_comment_id mktemp failed; wm_comment_id will not be cached (gh api full-scan every call)" >&2
    return 0
  fi
  local _jq_err
  _jq_err=$(mktemp 2>/dev/null) || _jq_err=""
  local _jq_rc=0
  if jq --arg cid "$cid" '. + {wm_comment_id: ($cid | tonumber)} | del(.wm_replica)' "$FLOW_STATE" > "$tmp" 2>"${_jq_err:-/dev/null}"; then
    # Capture both rc and stderr so EXDEV / EACCES / ENOSPC / SELinux deny is
    # distinguishable. `if ! mv ...; then _rc=$?` would zero $? in its
    # then-branch (bash `!` semantics) and collapse the real errno.
    local _cid_mv_err
    _cid_mv_err=$(mktemp 2>/dev/null) || _cid_mv_err=""
    if mv "$tmp" "$FLOW_STATE" 2>"${_cid_mv_err:-/dev/null}"; then
      :
    else
      local _mv_rc=$?
      echo "[rite] WARNING: issue-comment-wm-sync: cache_comment_id mv failed (rc=$_mv_rc)" >&2
      [ -n "$_cid_mv_err" ] && [ -s "$_cid_mv_err" ] && head -3 "$_cid_mv_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
      rm -f "$tmp"
    fi
    [ -n "$_cid_mv_err" ] && rm -f "$_cid_mv_err"
  else
    _jq_rc=$?
    echo "[rite] WARNING: issue-comment-wm-sync: cache_comment_id jq failed (rc=$_jq_rc — FLOW_STATE may be corrupt or cid='$cid' not numeric)" >&2
    [ -n "$_jq_err" ] && [ -s "$_jq_err" ] && head -3 "$_jq_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
    rm -f "$tmp"
  fi
  [ -n "$_jq_err" ] && rm -f "$_jq_err"
}

# Negative cache: replica 不在を flow-state に記録する (wm_comment_id には sentinel を入れない)。
# jq+mktemp+mv は cache_comment_id と同じ契約。書込失敗は WARNING を出して rc=1 を返し、
# 呼び出し側は success を捏造しない (caller/hook が systemMessage する)。
record_wm_replica_absent() {
  if [ ! -f "$FLOW_STATE" ]; then
    echo "[rite] WARNING: issue-comment-wm-sync: wm_replica を記録できない (FLOW_STATE missing)" >&2
    return 1
  fi
  local tmp
  if ! tmp=$(mktemp 2>/dev/null); then
    echo "[rite] WARNING: issue-comment-wm-sync: record_wm_replica_absent mktemp failed; wm_replica は記録されない" >&2
    return 1
  fi
  local _jq_err
  _jq_err=$(mktemp 2>/dev/null) || _jq_err=""
  local _jq_rc=0
  if jq '. + {wm_replica: "absent"} | del(.wm_comment_id)' "$FLOW_STATE" > "$tmp" 2>"${_jq_err:-/dev/null}"; then
    local _mv_err
    _mv_err=$(mktemp 2>/dev/null) || _mv_err=""
    if mv "$tmp" "$FLOW_STATE" 2>"${_mv_err:-/dev/null}"; then
      :
    else
      local _mv_rc=$?
      echo "[rite] WARNING: issue-comment-wm-sync: record_wm_replica_absent mv failed (rc=$_mv_rc)" >&2
      [ -n "$_mv_err" ] && [ -s "$_mv_err" ] && head -3 "$_mv_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
      rm -f "$tmp"
      [ -n "$_mv_err" ] && rm -f "$_mv_err"
      [ -n "$_jq_err" ] && rm -f "$_jq_err"
      return 1
    fi
    [ -n "$_mv_err" ] && rm -f "$_mv_err"
  else
    _jq_rc=$?
    echo "[rite] WARNING: issue-comment-wm-sync: record_wm_replica_absent jq failed (rc=$_jq_rc — FLOW_STATE may be corrupt)" >&2
    [ -n "$_jq_err" ] && [ -s "$_jq_err" ] && head -3 "$_jq_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
    rm -f "$tmp"
    [ -n "$_jq_err" ] && rm -f "$_jq_err"
    return 1
  fi
  [ -n "$_jq_err" ] && rm -f "$_jq_err"
  return 0
}

# Stale cached id を消す (404 後の rescan 前)。失敗は WARNING のみ (best-effort)。
clear_cached_comment_id() {
  [ -f "$FLOW_STATE" ] || return 0
  local tmp
  if ! tmp=$(mktemp 2>/dev/null); then
    echo "[rite] WARNING: issue-comment-wm-sync: clear_cached_comment_id mktemp failed" >&2
    return 0
  fi
  local _jq_err
  _jq_err=$(mktemp 2>/dev/null) || _jq_err=""
  if jq 'del(.wm_comment_id)' "$FLOW_STATE" > "$tmp" 2>"${_jq_err:-/dev/null}"; then
    mv "$tmp" "$FLOW_STATE" 2>/dev/null || rm -f "$tmp"
  else
    echo "[rite] WARNING: issue-comment-wm-sync: clear_cached_comment_id jq failed" >&2
    [ -n "$_jq_err" ] && [ -s "$_jq_err" ] && head -3 "$_jq_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
    rm -f "$tmp"
  fi
  [ -n "$_jq_err" ] && rm -f "$_jq_err"
}

# comments list を 1 回 GET し、作業メモリ comment の id と body を取り出す。
# stdout: 成功時は JSON object {id, body}。不在は空。API 失敗は rc=1。
# 検証 GET は行わない (abolished)。body は list レスポンスから取るので list+body の 2 GET にしない。
scan_wm_comment() {
  local issue="$1"
  local owner_repo="$2"
  local _err _rc=0 _payload
  _err=$(mktemp 2>/dev/null) || _err=""
  _payload=$(gh api "repos/${owner_repo}/issues/${issue}/comments" \
    --jq '[.[] | select(.body | contains("📜 rite 作業メモリ"))] | last | select(. != null) | {id, body}' \
    2>"${_err:-/dev/null}") || _rc=$?
  if [ "$_rc" -ne 0 ]; then
    echo "[rite] WARNING: issue-comment-wm-sync: comment 一覧取得 gh api 失敗 (rc=$_rc — auth/rate/network 系の可能性)" >&2
    [ -n "$_err" ] && [ -s "$_err" ] && head -3 "$_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
    [ -n "$_err" ] && rm -f "$_err"
    return 1
  fi
  [ -n "$_err" ] && rm -f "$_err"
  printf '%s' "$_payload"
  return 0
}

_read_cached_comment_id() {
  local cached="" _err _rc=0
  [ -f "$FLOW_STATE" ] || { printf '%s' ""; return 0; }
  _err=$(mktemp 2>/dev/null) || _err=""
  cached=$(jq -r '.wm_comment_id // empty' "$FLOW_STATE" 2>"${_err:-/dev/null}") || _rc=$?
  if [ "$_rc" -ne 0 ]; then
    echo "[rite] WARNING: issue-comment-wm-sync: cache 読み取り jq 失敗 (rc=$_rc — FLOW_STATE may be corrupt)" >&2
    [ -n "$_err" ] && [ -s "$_err" ] && head -3 "$_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
    cached=""
  fi
  [ -n "$_err" ] && rm -f "$_err"
  if [ "$cached" = "null" ]; then
    cached=""
  fi
  printf '%s' "$cached"
}

# 取得済み replica body が対象 Issue のものかを判定する (rc=0 一致 / rc=1 不一致・判定不能)。
# 判定材料は init テンプレの `- **Issue**: #N` 行のみ。この行は既に GET 済みの body から読むため、
# 検証のための gh 往復は増えない。行が無い / 読めない場合は「一致」と主張せず rc=1 に倒し、
# 呼び出し側を scan 経路へフォールバックさせる (誤 PATCH より往復増を選ぶ)。
_body_belongs_to_issue() {
  local body="$1" issue="$2" found
  # `` が `` に前方一致しないよう、番号の直後を行末か非数字に固定する。
  # `head -1` の早期クローズは pipefail 下で sed を SIGPIPE 失敗させうる。判定不能は rc=1 側
  # (= scan フォールバック) が正しい挙動なので、抽出失敗は空文字へ縮退させる。
  found=$(printf '%s\n' "$body" \
    | sed -n 's/^- \*\*Issue\*\*:[[:space:]]*#\([0-9][0-9]*\)[^0-9]*$/\1/p' | head -1) || found=""
  [ -n "$found" ] && [ "$found" = "$issue" ]
}

# fetch: GET body を outfile に書く。キャッシュ検証 GET はしない。
# stdout: status=success / status=skipped; reason=no_comment / status=skipped; reason=body_fetch_failed
# 成功時は COMMENT_ID グローバルをセットする (同一プロセスの patch / update 用)。
COMMENT_ID=""
do_fetch() {
  local outfile="$1"
  local cached body _err _rc _payload _id _body

  cached=$(_read_cached_comment_id)
  if [ -n "$cached" ]; then
    _err=$(mktemp 2>/dev/null) || _err=""
    _rc=0
    body=$(gh api "repos/${OWNER_REPO}/issues/comments/${cached}" --jq '.body // empty' 2>"${_err:-/dev/null}") || _rc=$?
    if [ "$_rc" -eq 0 ] && [ -n "$body" ] && ! _body_belongs_to_issue "$body" "$ISSUE"; then
      # cache された id は別 Issue の replica (batch 実行で前 Issue の値が残った等) か、
      # Issue 行を持たない別物。この id では PATCH せず、キャッシュを捨てて scan 経路へ落ちる。
      # `repos/{owner}/{repo}/issues/comments/{id}` は Issue 非依存のため、GET が成功したこと
      # 自体は所属の証明にならない。
      [ -n "$_err" ] && rm -f "$_err"
      # 「不一致」と「判定不能 (Issue 行が無い / 読めない)」は同じ rc=1 に畳まれるため、文言も
      # 非所属を断定しない。断定すると判定不能ケースで operator の triage が「Issue 跨ぎ汚染」へ
      # 誤誘導される。
      echo "[rite] WARNING: issue-comment-wm-sync: cache された wm_comment_id=$cached は Issue #${ISSUE} の replica と確認できなかったため破棄しスキャンし直します (別 Issue の replica か、Issue 行を欠く body)" >&2
      clear_cached_comment_id
      cached=""
      body=""
    elif [ "$_rc" -eq 0 ] && [ -n "$body" ]; then
      [ -n "$_err" ] && rm -f "$_err"
      COMMENT_ID="$cached"
      if ! printf '%s' "$body" > "$outfile"; then
        echo "[rite] WARNING: issue-comment-wm-sync: fetch --out 書き込み失敗" >&2
        echo "status=skipped; reason=body_fetch_failed"
        return 0
      fi
      echo "status=success"
      return 0
    elif [ "$_rc" -ne 0 ] && [ -n "$_err" ] && [ -s "$_err" ] && grep -qiE 'HTTP[[:space:]]*404' "$_err"; then
      [ -n "$_err" ] && rm -f "$_err"
      clear_cached_comment_id
      cached=""
    elif [ "$_rc" -ne 0 ]; then
      echo "[rite] WARNING: issue-comment-wm-sync: comment body 取得 gh api 失敗 (rc=$_rc — auth/rate/network/404 系)" >&2
      [ -n "$_err" ] && [ -s "$_err" ] && head -3 "$_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
      [ -n "$_err" ] && rm -f "$_err"
      echo "status=skipped; reason=body_fetch_failed"
      return 0
    else
      [ -n "$_err" ] && rm -f "$_err"
      echo "WARNING: Could not retrieve comment body. Skipping update." >&2
      echo "status=skipped; reason=body_fetch_failed"
      return 0
    fi
    [ -n "$_err" ] && rm -f "$_err"
  fi

  _payload=$(scan_wm_comment "$ISSUE" "$OWNER_REPO") || {
    echo "status=skipped; reason=body_fetch_failed"
    return 0
  }
  if [ -z "$_payload" ]; then
    record_wm_replica_absent || true
    echo "WARNING: Work memory comment not found for Issue #${ISSUE}. Skipping update." >&2
    echo "status=skipped; reason=no_comment"
    return 0
  fi
  _id=$(printf '%s' "$_payload" | jq -r '.id // empty' 2>/dev/null) || _id=""
  _body=$(printf '%s' "$_payload" | jq -r '.body // empty' 2>/dev/null) || _body=""
  if [ -z "$_id" ] || [ -z "$_body" ]; then
    record_wm_replica_absent || true
    echo "WARNING: Work memory comment not found for Issue #${ISSUE}. Skipping update." >&2
    echo "status=skipped; reason=no_comment"
    return 0
  fi
  cache_comment_id "$_id"
  COMMENT_ID="$_id"
  if ! printf '%s' "$_body" > "$outfile"; then
    echo "[rite] WARNING: issue-comment-wm-sync: fetch --out 書き込み失敗" >&2
    echo "status=skipped; reason=body_fetch_failed"
    return 0
  fi
  echo "status=success"
  return 0
}

# patch: safety_check のあと PATCH 1 回。COMMENT_ID 未設定なら flow-state の wm_comment_id を読む。
do_patch() {
  local in_file="${1:-}"
  local orig_len="${2:-}"
  local tlabel="${3:-}"
  local cid="${COMMENT_ID:-}"
  local _err _rc

  if [ -z "$cid" ] && [ -f "$FLOW_STATE" ]; then
    _err=$(mktemp 2>/dev/null) || _err=""
    _rc=0
    cid=$(jq -r '.wm_comment_id // empty' "$FLOW_STATE" 2>"${_err:-/dev/null}") || _rc=$?
    [ -n "$_err" ] && rm -f "$_err"
    if [ "$_rc" -ne 0 ] || [ -z "$cid" ] || [ "$cid" = "null" ]; then
      cid=""
    fi
  fi
  if [ -z "$cid" ]; then
    echo "[rite] WARNING: issue-comment-wm-sync: PATCH 先 comment id が無い" >&2
    echo "status=error; reason=patch_failed"
    return 0
  fi
  COMMENT_ID="$cid"

  if ! safety_check "$in_file" "$orig_len" "${backup_file:-$in_file}" "$tlabel"; then
    echo "status=skipped; reason=safety_check_failed"
    return 0
  fi

  patch_err=$(mktemp 2>/dev/null) || patch_err=""
  local patch_status=0
  ( set -o pipefail; jq -n --rawfile body "$in_file" '{"body": $body}' \
    | gh api "repos/${OWNER_REPO}/issues/comments/${cid}" -X PATCH --input - > /dev/null 2>"${patch_err:-/dev/null}" ) || patch_status=$?

  if [ "$patch_status" -ne 0 ]; then
    echo "[rite] WARNING: issue-comment-wm-sync: PATCH failed (rc=$patch_status, Backup: ${backup_file:-retained})" >&2
    [ -n "$patch_err" ] && [ -s "$patch_err" ] && head -3 "$patch_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
    [ -n "$patch_err" ] && rm -f "$patch_err"
    echo "status=error; reason=patch_failed"
    return 0
  fi
  [ -n "$patch_err" ] && rm -f "$patch_err"
  echo "status=success"
  return 0
}

# --- Safety checks ---
safety_check() {
  local updated_file="$1"
  local original_length="$2"
  local backup_file="$3"
  local transform="${4:-}"

  # Empty or too short
  if [ ! -s "$updated_file" ] || [[ "$(wc -c < "$updated_file")" -lt 10 ]]; then
    echo "WARNING: Updated body is empty or too short. Skipping PATCH. Backup: $backup_file" >&2
    return 1
  fi

  # Header validation
  if ! grep -q '📜 rite 作業メモリ' "$updated_file"; then
    echo "WARNING: Updated body missing work memory header. Skipping PATCH. Backup: $backup_file" >&2
    return 1
  fi

  # 50% rule (only for update-progress, update-phase, update-plan-status, update-checkboxes)
  # Skip for append-section, replace-section, append-eof, and merge-checklist (content grows or changes size unpredictably)
  case "$transform" in
    append-section|replace-section|append-eof|merge-checklist)
      ;;
    *)
      local updated_length
      updated_length=$(wc -c < "$updated_file")
      if [[ "${updated_length:-0}" -lt $(( ${original_length:-1} / 2 )) ]]; then
        echo "WARNING: Updated body < 50% of original (${updated_length}/${original_length}). Skipping PATCH. Backup: $backup_file" >&2
        return 1
      fi
      ;;
  esac

  return 0
}

# --- Argument parsing ---
MODE="${1:-}"
shift 2>/dev/null || true

ISSUE=""
BRANCH=""
TRANSFORM=""
OUTFILE=""
INFILE=""
ORIGINAL_LENGTH=""
TRANSFORM_LABEL=""
TRANSFORM_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --issue)             ISSUE="$2"; shift 2 ;;
    --branch)            BRANCH="$2"; shift 2 ;;
    --transform)         TRANSFORM="$2"; shift 2 ;;
    --out)               OUTFILE="$2"; shift 2 ;;
    --in)                INFILE="$2"; shift 2 ;;
    --original-length)   ORIGINAL_LENGTH="$2"; shift 2 ;;
    --transform-label)   TRANSFORM_LABEL="$2"; shift 2 ;;
    --)
      shift
      TRANSFORM_ARGS+=("$@")
      break
      ;;
    *)
      # Forward to Python script (issue-comment-wm-update.py validates and rejects unknown options)
      TRANSFORM_ARGS+=("$1")
      shift
      ;;
  esac
done

# --- Validation ---
if [ -z "$ISSUE" ]; then
  echo "ERROR: --issue is required" >&2
  exit 1
fi

case "$MODE" in
  init)
    ;;
  update)
    if [ -z "$TRANSFORM" ]; then
      echo "ERROR: update mode requires --transform" >&2
      exit 1
    fi
    ;;
  fetch)
    if [ -z "$OUTFILE" ]; then
      echo "ERROR: fetch mode requires --out" >&2
      exit 1
    fi
    ;;
  patch)
    if [ -z "$INFILE" ]; then
      echo "ERROR: patch mode requires --in" >&2
      exit 1
    fi
    if [ -z "$ORIGINAL_LENGTH" ]; then
      echo "ERROR: patch mode requires --original-length" >&2
      exit 1
    fi
    if [ -z "$TRANSFORM_LABEL" ]; then
      echo "ERROR: patch mode requires --transform-label" >&2
      exit 1
    fi
    ;;
  *)
    echo "ERROR: Unknown mode: $MODE. Use 'init', 'update', 'fetch' or 'patch'" >&2
    exit 1
    ;;
esac

# --- Get owner/repo ---
OWNER_REPO=$(get_owner_repo)
if [ -z "$OWNER_REPO" ]; then
  echo "WARNING: Could not determine owner/repo. Skipping." >&2
  exit 0
fi

# ============================================================
# INIT MODE
# ============================================================
if [ "$MODE" = "init" ]; then
  TIMESTAMP=$(date +'%Y-%m-%dT%H:%M:%S+09:00')

  # 冪等 pre-check: replica が既に存在する場合は二重投稿せず skip する (作成後の validation と
  # 同じ query)。pre-check の gh api 失敗は「存在不明」であり、ここで止めると replica が永遠に
  # 作られない恐れがあるため投稿続行に倒す (non-blocking)。
  _pre_err=$(mktemp 2>/dev/null) || _pre_err=""
  _pre_rc=0
  existing_id=$(gh api "repos/${OWNER_REPO}/issues/${ISSUE}/comments" \
    --jq '[.[] | select(.body | contains("📜 rite 作業メモリ"))] | last | .id // empty' \
    2>"${_pre_err:-/dev/null}") || _pre_rc=$?
  if [ "$_pre_rc" -ne 0 ]; then
    echo "[rite] WARNING: issue-comment-wm-sync: init pre-check gh api 失敗 (rc=$_pre_rc) — 存在不明のため投稿を続行します" >&2
    [ -n "$_pre_err" ] && [ -s "$_pre_err" ] && head -3 "$_pre_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
    existing_id=""
  fi
  [ -n "$_pre_err" ] && rm -f "$_pre_err"
  if [ -n "$existing_id" ]; then
    cache_comment_id "$existing_id"
    echo "status=skipped; reason=already_exists"
    exit 0
  fi

  # set -e 配下で mktemp が /tmp full / inode 枯渇 / readonly fs で失敗しても file-wide trap
  # 設置済みのため orphan は残らない。明示 rc check で degrade させ、init mode を skip して
  # 上位で続行する (cleanup は file-wide の _rite_wm_sync_cleanup に委譲)。
  if ! tmpfile=$(mktemp 2>/dev/null); then
    echo "[rite] WARNING: issue-comment-wm-sync: init mode mktemp failed (/tmp full or readonly?). Skipping comment creation." >&2
    exit 0
  fi

  cat <<INIT_EOF > "$tmpfile"
## 📜 rite 作業メモリ

### セッション情報
- **Issue**: #${ISSUE}
- **開始**: ${TIMESTAMP}
- **ブランチ**: ${BRANCH}
- **最終更新**: ${TIMESTAMP}
- **コマンド**: /rite:open
- **フェーズ**: branch
- **フェーズ詳細**: ブランチ作成完了

### 進捗サマリー

| 項目 | 状態 | 備考 |
|------|------|------|
| 実装 | ⬜ 未着手 | - |
| テスト | ⬜ 未着手 | - |
| ドキュメント | ⬜ 未着手 | - |

### 要確認事項
<!-- 作業中に発生した確認事項を蓄積。セッション終了時にまとめて確認 -->
_確認事項はありません_

### 変更ファイル
<!-- 自動更新 -->
_まだ変更はありません_

### 決定事項・メモ
<!-- 重要な判断や発見 -->

### 計画逸脱ログ
<!-- 実装中に計画から逸脱した場合に記録 -->
_計画逸脱はありません_

### ボトルネック検出ログ
<!-- ボトルネック検出 → Oracle 発見 → 再分解の履歴 -->
_ボトルネック検出はありません_

### レビュー対応履歴
<!-- レビュー対応時に自動記録 -->
_レビュー対応はありません_

### 次のステップ
1. Issue の内容を確認
2. 実装を開始
INIT_EOF

  # gh の成功時 stdout は comment URL なので、`2>&1` で merge すると失敗時の stderr 詳細と
  # 成功時の URL の見分けがつかない。stderr は tempfile に分離 capture して根本原因を残す。
  _init_err=""
  _init_err=$(mktemp 2>/dev/null) || _init_err=""
  _init_rc=0
  # --repo を明示: shorthand の `gh issue comment` は内部で `gh repo view` と同じ
  # host-allowlist 解決を行うため、明示しないと origin が SSH Host alias のとき
  # OWNER_REPO が解決済みでもここで再び失敗する。
  result=$(gh issue comment "$ISSUE" --repo "$OWNER_REPO" --body-file "$tmpfile" 2>"${_init_err:-/dev/null}") || _init_rc=$?
  if [ "$_init_rc" -ne 0 ]; then
    echo "[rite] WARNING: issue-comment-wm-sync: gh issue comment 作成失敗 (rc=$_init_rc)" >&2
    [ -n "$_init_err" ] && [ -s "$_init_err" ] && head -3 "$_init_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
    [ -n "$_init_err" ] && rm -f "$_init_err"
    exit 0
  fi
  [ -n "$_init_err" ] && rm -f "$_init_err"

  # Validate creation (retry up to 3 times with 1s intervals).
  # Capture per-attempt gh stderr so transient rate-limit / auth / network
  # failures surface in the WARNING instead of silently routing to
  # status=unverified — symmetric with the get_comment_id and init write paths
  # above.
  created_id=""
  for attempt in 1 2 3; do
    _verify_err=$(mktemp 2>/dev/null) || _verify_err=""
    _verify_rc=0
    created_id=$(gh api "repos/${OWNER_REPO}/issues/${ISSUE}/comments" \
      --jq '[.[] | select(.body | contains("📜 rite 作業メモリ"))] | last | .id // empty' \
      2>"${_verify_err:-/dev/null}") || _verify_rc=$?
    if [ "$_verify_rc" -ne 0 ]; then
      _verify_tag=""
      [ -z "$_verify_err" ] && _verify_tag=" stderr_capture=disabled"
      echo "[rite] WARNING: issue-comment-wm-sync: validation gh api 失敗 (attempt=$attempt, rc=$_verify_rc${_verify_tag})" >&2
      [ -n "$_verify_err" ] && [ -s "$_verify_err" ] && head -3 "$_verify_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
      created_id=""
    fi
    [ -n "$_verify_err" ] && rm -f "$_verify_err"
    [ -n "$created_id" ] && break
    [ "$attempt" -lt 3 ] && sleep 1
  done

  if [ -n "$created_id" ]; then
    cache_comment_id "$created_id"
    echo "status=success"
  else
    echo "WARNING: Could not verify work memory comment creation." >&2
    echo "status=unverified"
  fi

  exit 0
fi

# ============================================================
# FETCH MODE
# ============================================================
if [ "$MODE" = "fetch" ]; then
  do_fetch "$OUTFILE"
  exit 0
fi

# ============================================================
# PATCH MODE
# ============================================================
if [ "$MODE" = "patch" ]; then
  do_patch "$INFILE" "$ORIGINAL_LENGTH" "$TRANSFORM_LABEL"
  exit 0
fi

# ============================================================
# UPDATE MODE (fetch → one python transform → patch)
# ============================================================
# /tmp 関連の failure (inode 枯渇 / readonly fs / quota) は各 mktemp で rc を見て degrade させる
# (途中失敗時の先行 tmpfile は file-wide trap が清掃する)。
if ! body_tmp=$(mktemp 2>/dev/null); then
  echo "[rite] WARNING: issue-comment-wm-sync: update mode body_tmp mktemp 失敗。skip." >&2
  exit 0
fi
if ! updated_tmp=$(mktemp 2>/dev/null); then
  echo "[rite] WARNING: issue-comment-wm-sync: update mode updated_tmp mktemp 失敗。skip." >&2
  exit 0
fi
if ! py_err_tmp=$(mktemp 2>/dev/null); then
  echo "[rite] WARNING: issue-comment-wm-sync: update mode py_err_tmp mktemp 失敗。skip." >&2
  exit 0
fi
# do_fetch をコマンド置換で呼ぶと COMMENT_ID 代入がサブシェルに閉じ、
# flow-state 不在時に do_patch が id を失う。stdout だけファイルへ書いて親で読む。
if ! _fetch_out=$(mktemp 2>/dev/null); then
  echo "[rite] WARNING: issue-comment-wm-sync: update mode _fetch_out mktemp 失敗。skip." >&2
  exit 0
fi
do_fetch "$body_tmp" > "$_fetch_out"
_fetch_line=$(cat "$_fetch_out")
case "$_fetch_line" in
  status=success)
    ;;
  *)
    # no_comment / body_fetch_failed / その他。status 行は 1 本だけ出す (fetch が既に出力済み)。
    printf '%s\n' "$_fetch_line"
    exit 0
    ;;
esac

# Backup は失敗時の post-mortem 用。蓄積した場合は `rm -f "${TMPDIR:-/tmp}"/rite-wm-backup-*` で手動清掃。
# /tmp 直書きは sandbox 環境で読み込み専用のため set -euo pipefail 下で即死する。
backup_file="${TMPDIR:-/tmp}/rite-wm-backup-${ISSUE}-$(date +%s).md"
cp "$body_tmp" "$backup_file" || true
original_length=$(wc -c < "$body_tmp" | tr -d ' ')

# Apply Python transformation
# pipefail を local subshell で有効にすることで、cat 失敗 (permission denied / IO error) が
# python3 の rc に隠蔽されず transform_status に反映される。直接リダイレクトに切り替えれば
# cat のみ確実だが、後続の transform で stdin が pipe 終端であることを期待しているため pipe 形式を保つ。
transform_status=0
( set -o pipefail; cat "$body_tmp" | python3 "$PYTHON_SCRIPT" "$TRANSFORM" "${TRANSFORM_ARGS[@]}" > "$updated_tmp" 2>"$py_err_tmp" ) || transform_status=$?

# merge-checklist: exit 10 = target section absent with new items remaining.
# Distinguish from transform_failed so caller can show "セクション不在のためスキップ"
# instead of reporting a successful no-op merge (AC-1).
if [ "$transform_status" -eq 10 ]; then
  py_err=$(cat "$py_err_tmp" 2>/dev/null)
  echo "WARNING: merge-checklist: target section absent; items not merged. Skipping PATCH. Backup: $backup_file" >&2
  [ -n "$py_err" ] && echo "  Detail: $py_err" >&2
  echo "status=skipped; reason=section_absent"
  exit 0
fi

if [ "$transform_status" -ne 0 ]; then
  py_err=$(cat "$py_err_tmp" 2>/dev/null)
  echo "WARNING: Python transform failed (exit $transform_status). Skipping PATCH. Backup: $backup_file" >&2
  [ -n "$py_err" ] && echo "  Detail: $py_err" >&2
  echo "status=error; reason=transform_failed"
  exit 0
fi

_patch_line=$(do_patch "$updated_tmp" "$original_length" "$TRANSFORM")
if [ "$_patch_line" = "status=success" ]; then
  rm -f "$backup_file"
fi
printf '%s\n' "$_patch_line"
exit 0
