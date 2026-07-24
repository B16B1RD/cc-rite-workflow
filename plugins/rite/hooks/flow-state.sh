#!/bin/bash
# rite workflow - Unified flow-state management (schema_version=3)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=state-path-resolve.sh
source "$SCRIPT_DIR/state-path-resolve.sh"
# shellcheck source=control-char-neutralize.sh
source "$SCRIPT_DIR/control-char-neutralize.sh"

# Callers may pre-resolve STATE_ROOT (e.g., session-start.sh resolves it from
# the hook payload's `cwd` field, which differs from flow-state.sh's own CWD)
# and pass it via the RITE_STATE_ROOT env var so the resolver does not silently
# fall back to its own pwd. Falls back to the CWD-based resolver when unset.
if [ -n "${RITE_STATE_ROOT:-}" ] && [ -d "$RITE_STATE_ROOT" ]; then
  STATE_ROOT="$RITE_STATE_ROOT"
else
  STATE_ROOT=$(resolve_state_root)
fi
SESSION_DIR="$STATE_ROOT/.rite/sessions"
LEGACY_STATE="$STATE_ROOT/.rite-flow-state"
SESSION_ID_FILE="$STATE_ROOT/.rite-session-id"

# Phase enum SoT (13 values); also referenced from resume.md cross-check.
PHASE_ENUM_V3="init branch plan implement lint pr review fix ready ready_error cleanup ingest completed"
SCHEMA_VERSION_V3=3

_phase_is_valid() {
  for v in $PHASE_ENUM_V3; do [ "$v" = "$1" ] && return 0; done
  return 1
}

# Legacy v1/v2 phase → v3 reduction (PR 2a SoT). Unknown values pass through.
_phase_migrate() {
  case "$1" in
    cleanup_pre_ingest|cleanup_post_ingest|cleanup_completed) echo cleanup ;;
    ingest_pre_lint|ingest_post_lint|ingest_completed) echo ingest ;;
    implementing) echo implement ;;
    create_*|parent_progress_sync|unknown) echo init ;;
    *) echo "$1" ;;
  esac
}

# Reject path-traversal characters and control characters (log injection vector).
# All session_id sources (override, SESSION_ID_FILE content, env vars) MUST pass through
# this validator before being printed or used in path construction. Control-character
# rejection prevents attackers from injecting fake "WARNING:" lines into stderr by setting
# env var to e.g. $'innocent\nWARNING: fake injected'. Path-traversal rejection prevents
# CLAUDE_CODE_SESSION_ID="../../tmp/owned" from writing state files outside .rite/sessions/.
#
# Contract (SoT: references/session-id-validation-contract.md): this is the Layer 1
# security-boundary validator and is **format-agnostic by design** — it does NOT enforce
# UUID form. Non-UUID opaque sids (e.g. `session-aaaa-1371`) MUST keep passing. Do NOT
# route this through `_resolve-session-id.sh` (strict RFC 4122 / Layer 2) or add UUID-shape
# checks here: hook tests pass non-UUID sids directly to flow-state.sh and would silently
# go vacuous if this validator were tightened. The acceptance side is pinned by
# flow-state.test.sh TC-24.
_validate_session_id() {
  # `origin` (引数 2) は session_id の出所 (override / SESSION_ID_FILE / env var) を識別する
  # エラーメッセージ用ラベル。bash builtin `source` の shadow を避けるため `origin` を採用。
  local sid="$1" origin="$2"
  case "$sid" in
    *..*|*/*)
      echo "ERROR: invalid session_id from $origin: contains path-traversal characters ('..' or '/')" >&2
      return 1
      ;;
  esac
  # contains_ctrl (control-char-neutralize.sh) は C0 + DEL + C1 8-bit (0x80-0x9f)
  # をバイト単位で検出する。旧 `=~ [[:cntrl:]]` は glibc が C1 を cntrl と分類しない
  # ため 0x9b (8-bit CSI) 入り session_id を素通ししていた。
  if contains_ctrl "$sid"; then
    echo "ERROR: invalid session_id from $origin: contains control characters (newline / tab / C1 8-bit bytes / etc.)" >&2
    return 1
  fi
  return 0
}

_resolve_session_id() {
  local override="${1:-}"
  if [ -n "$override" ]; then
    _validate_session_id "$override" "--session override" || return 1
    printf '%s\n' "$override"; return 0
  fi
  # Priority (Issue #1530): override → env CLAUDE_CODE_SESSION_ID → env
  # CLAUDE_SESSION_ID → `.rite-session-id` file (env-absent fallback).
  #
  # The env var is per-session, so it isolates concurrent Claude sessions that
  # share one state root (the main checkout). The `.rite-session-id` file is a
  # single shared path that every session-start hook used to overwrite, so
  # preferring it (the previous order) let the last session's id "leak" into the
  # others — flow-state was written to a foreign `{sid}.flow-state` and an in-use
  # worktree could be mis-reaped. Demoting the file to the env-absent fallback
  # keeps backward compatibility for CI / headless / non-Code runtimes (which set
  # no env var) while making the env var authoritative whenever it is present.
  #
  # Claude Code exposes CLAUDE_CODE_SESSION_ID; older / non-Code clients used
  # CLAUDE_SESSION_ID — accept both. Every source (override / env / file) passes
  # through _validate_session_id before reaching _state_path, blocking the
  # unvalidated path-traversal / log-injection vector (§4.4 MUST NOT).
  if [ -n "${CLAUDE_CODE_SESSION_ID:-}" ]; then
    _validate_session_id "$CLAUDE_CODE_SESSION_ID" "CLAUDE_CODE_SESSION_ID env" || return 1
    printf '%s\n' "$CLAUDE_CODE_SESSION_ID"
    return 0
  fi
  if [ -n "${CLAUDE_SESSION_ID:-}" ]; then
    _validate_session_id "$CLAUDE_SESSION_ID" "CLAUDE_SESSION_ID env" || return 1
    printf '%s\n' "$CLAUDE_SESSION_ID"
    return 0
  fi
  if [ -f "$SESSION_ID_FILE" ]; then
    local sid; sid=$(tr -d '[:space:]' < "$SESSION_ID_FILE" 2>/dev/null) || sid=""
    if [ -n "$sid" ]; then
      _validate_session_id "$sid" "$SESSION_ID_FILE" || return 1
      printf '%s\n' "$sid"
      return 0
    fi
  fi
  echo "ERROR: cannot resolve session_id" >&2; return 1
}

_state_path() {
  mkdir -p "$SESSION_DIR" 2>/dev/null || true
  printf '%s\n' "$SESSION_DIR/${1}.flow-state"
}

# Returns: 0 on successful atomic replace, 1 on tmpfile mktemp / write IO failure
# or any non-zero from the flock+mv subshell. Callers MUST check rc (e.g.
# `_atomic_write "$f" "$updated" || return 1`) — silent success leads to false
# "migrated:" announcements when EROFS/ENOSPC/EXDEV/EACCES truncate the tmpfile.
# Degrades to a plain atomic mv when flock is unavailable (stock macOS /
# Windows Git Bash without util-linux) — matches _atomic_claim_write and the
# wiki helpers; rename(2) atomicity holds without the advisory lock.
_atomic_write() {
  local target="$1" content="$2" lockfile="${1}.lock" tmpfile rc=0
  tmpfile=$(mktemp "${target}.XXXXXX") || return 1
  # printf rc を必ず check し、disk-full / EROFS / quota exceeded で empty/partial tmpfile が
  # 生成されたまま下流の mv が "成功" して target を破損内容で上書きする経路を遮断する。
  # Additionally guard the post-write non-empty invariant: jq filters in this script always
  # produce a non-empty JSON object, so a 0-byte tmpfile is a write-time corruption signal.
  # printf 失敗分岐と 0-byte invariant 違反分岐は下流の flock+mv の ERROR emission (`flock timeout`
  # 分岐) と対称的に診断 ERROR を必ず emit する。rc=1 だけでは EROFS / ENOSPC / EXDEV / EACCES /
  # 0-byte write のどの失敗種別か区別できず、operator がトリアージできない。
  printf '%s' "$content" > "$tmpfile" || {
    echo "ERROR: _atomic_write write failed: $target" >&2
    rm -f "$tmpfile" 2>/dev/null
    return 1
  }
  [ -s "$tmpfile" ] || {
    echo "ERROR: _atomic_write produced empty tmpfile (invariant violation): $target" >&2
    rm -f "$tmpfile" 2>/dev/null
    return 1
  }
  if command -v flock >/dev/null 2>&1; then
    ( flock -w 3 9 || { echo "ERROR: flock timeout: $lockfile" >&2; exit 1; }
      mv "$tmpfile" "$target" ) 9>"$lockfile" || rc=$?
  else
    # No flock (stock macOS / Windows Git Bash): lock skip + plain atomic mv.
    mv "$tmpfile" "$target" || rc=$?
  fi
  [ -f "$tmpfile" ] && rm -f "$tmpfile" 2>/dev/null || true
  return $rc
}

# Emit up to 3 lines of a jq stderr capture ($1 = error file) to stderr, 2-space
# indented, with control characters neutralized to '?' via the shared
# neutralize_ctrl helper (control-char-neutralize.sh) — covers C0 + DEL + C1
# 0x80-0x9f, which the former inline `s/[[:cntrl:]]/?/g` missed.
# Shared with the stop-loop-continuation.sh unknown-prefix WARNING so the
# neutralization convention lives in one place: a corrupt state file fragment can
# carry ANSI escape / control bytes that, echoed raw, would let the corrupt
# content drive the operator's terminal (cursor moves, color, title rewrites)
# via the diagnostic path. --keep-newline preserves the 3-line snippet structure.
# No-op when the file is unset or empty (preserves the prior -n/-s guard); always
# returns 0 so a caller under `set -e` never aborts on the diagnostic line.
_emit_jq_err_snippet() {
  if [ -n "${1:-}" ] && [ -s "$1" ]; then
    head -3 "$1" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2 || true
  fi
}

cmd_set() {
  # Merge semantics: unspecified scalar fields preserve existing values (旧 patch 互換).
  # Required: --phase, --next. Optional fields fall back to existing JSON or defaults.
  local phase="" next="" session="" if_exists=0 preserve_error=0 require_worktree=0
  local issue="" branch="" pr="" parent_issue="" active="" handoff="" worktree="" cycle_count=""
  while [ $# -gt 0 ]; do case "$1" in
    --phase) phase="$2"; shift 2 ;;
    --issue) issue="$2"; shift 2 ;;
    --branch) branch="$2"; shift 2 ;;
    --worktree) worktree="$2"; shift 2 ;;
    --cycle-count) cycle_count="$2"; shift 2 ;;
    --pr) pr="$2"; shift 2 ;;
    --parent-issue) parent_issue="$2"; shift 2 ;;
    --next) next="$2"; shift 2 ;;
    --active) active="$2"; shift 2 ;;
    --handoff) handoff="$2"; shift 2 ;;
    --session) session="$2"; shift 2 ;;
    --if-exists) if_exists=1; shift ;;
    --preserve-error-count) preserve_error=1; shift ;;
    --require-worktree) require_worktree=1; shift ;;
    *) echo "ERROR: unknown option: $1" >&2; return 1 ;;
  esac; done
  [ -z "$phase" ] && { echo "ERROR: --phase is required" >&2; return 1; }
  [ -z "$next" ] && { echo "ERROR: --next is required" >&2; return 1; }
  _phase_is_valid "$phase" || echo "WARNING: unknown phase: $phase (allowed: $PHASE_ENUM_V3)" >&2
  local sid path; sid=$(_resolve_session_id "$session") || return 1
  path=$(_state_path "$sid")
  if [ $if_exists -eq 1 ] && [ ! -f "$path" ]; then
    # `.rite-session-id` exists ⇒ a session-start hook ran and the caller expects an
    # active session. Resolved path missing means stale/drifted session_id
    # — emit a WARNING so the silent skip is observable. Truly first-time sessions (no
    # `.rite-session-id`) stay silent to preserve the graceful no-op contract that
    # `skills/wiki-ingest/SKILL.md` / `skills/ready/SKILL.md` 等の `--if-exists` caller が depend on
    # (issue-create は flow-state 非依存化され、本契約の依存者ではなくなった)。
    if [ -f "$SESSION_ID_FILE" ]; then
      # basename only — multi-tenant 環境での絶対 path leakage を最小化 (cmd_get と対称化)
      echo "WARNING: flow-state.sh cmd_set: --if-exists skipped (resolved session_id=$sid has no state file at file: $(basename "$path"); possible stale .rite-session-id or sid drift)" >&2
    fi
    return 0
  fi
  # Pull existing values for fields the caller did not specify (merge behavior).
  # `cur_last_synced` は post-tool-wm-sync.sh が runtime-only field として書き続けるため、
  # cmd_set が schema 構築時に既存値を merge しないと毎回 wipe され、wm-sync の diff guard
  # が常に「変化あり」と判定 → GitHub API spam (issue-comment-wm-sync 連発)。
  # 既存値が無い場合は空文字 → null として書き込み、wm-sync 側の `// "" | tostring` で
  # 空文字に縮退する (空 vs 非空 を別値として扱う wm-sync の diff guard と整合)。
  # `cur_wm_comment_id` も同型: issue-comment-wm-sync.sh の cache_comment_id() が
  # flow-state ファイルへ直接書き込む runtime-only field。lsp と同様に merge-preserve しないと
  # 直後の他 skill の set 呼び出しで無警告に消える (#1810)。
  #
  # Single composite jq read: 6 つの独立 jq 呼び出しの silent fallback chain
  # では既存 state が corrupt JSON でも全フィールドが default に縮退して silent overwrite
  # される。1 回の composite jq + stderr capture に集約し、jq 失敗時に WARNING を stderr emit
  # して operator が corrupt overwrite を検出できるようにする。Unit separator () で field
  # を分割し、IFS で安全に split (whitespace collapse 防止)。
  local cur_issue=0 cur_branch="" cur_pr=0 cur_parent=0 cur_active=true cur_err=0 cur_last_synced="" cur_worktree="" cur_cycle=0 cur_wm_comment_id=""
  if [ -f "$path" ]; then
    local _cur_jq_err="" _cur_data _cur_rc=0
    _cur_jq_err=$(mktemp 2>/dev/null) || _cur_jq_err=""
    # インライン rm では set -e / signal 中断時に orphan tempfile が残るため RETURN trap で保証する。
    trap '[ -n "${_cur_jq_err:-}" ] && rm -f "${_cur_jq_err:-}"' RETURN
    _cur_data=$(jq -r '[(.issue_number // 0 | tostring),
                       (.branch // ""),
                       (.pr_number // 0 | tostring),
                       (.parent_issue_number // 0 | tostring),
                       (.active // true | tostring),
                       (.error_count // 0 | tostring),
                       (.last_synced_phase // ""),
                       (.worktree // ""),
                       (.cycle_count // 0 | tostring),
                       (.wm_comment_id // "" | tostring)] | join("")' "$path" 2>"${_cur_jq_err:-/dev/null}") || _cur_rc=$?
    if [ "$_cur_rc" -ne 0 ]; then
      # basename only — multi-tenant 環境での絶対 path leakage を最小化 (cmd_get / cmd_set --if-exists と対称化)
      echo "WARNING: flow-state.sh cmd_set: existing state read failed for $(basename "$path") (may be corrupt; merged write will use defaults)" >&2
      _emit_jq_err_snippet "$_cur_jq_err"
    else
      IFS=$'\x1f' read -r cur_issue cur_branch cur_pr cur_parent cur_active cur_err cur_last_synced cur_worktree cur_cycle cur_wm_comment_id <<< "$_cur_data"
    fi
  fi
  [ -z "$issue" ] && issue=$cur_issue
  [ -z "$branch" ] && branch=$cur_branch
  # `worktree` (multi-session §2): merge-preserve like `branch` (NOT default-clear
  # like `handoff`). Unspecified --worktree preserves the existing session
  # worktree path so phase-transition sets do not wipe it. Written conditionally
  # in the jq below so non-worktree sessions never gain the key (additive → no
  # schema bump, byte-identical state file for single-session use).
  [ -z "$worktree" ] && worktree=$cur_worktree
  # `cycle_count` (#1701 review⇄fix サーキットブレーカー): merge-preserve like `branch`/`worktree`.
  # /rite:iterate がループ頭で increment し `--cycle-count N` で書き込む review⇄fix cycle カウンタ。
  # `--cycle-count` を伴わない他 skill の set (review/fix/open/ready 等) が毎 phase transition で
  # 値を wipe しないよう既存値を merge preserve する。iterate は fresh entry で 0 を明示指定して
  # stale 値をリセットし、resume 時は既存値を継承してカウンタを継続する (AC-3)。
  [ -z "$cycle_count" ] && cycle_count=$cur_cycle
  # --require-worktree (#1595): データ層で「multi_session 有効経路の set は worktree path を伴う」
  # invariant を検知する。merge-preserve 後も worktree が空 = open の worktree 化漏れ
  # (Step 1.4 marker 欠落 → legacy `git switch -c` への silent fallback) の兆候。loud に
  # WARNING + `[CONTEXT] WORKTREE_INVARIANT=` marker を stderr へ emit する (orchestrator の
  # hard gate が読む)。書き込み自体は継続する — non-blocking で state を失わない。停止判断は
  # caller (open.md の hard gate) 側に委ねる (flow-state は state 記録の SoT であり制御層ではない)。
  if [ "$require_worktree" -eq 1 ]; then
    if [ -z "$worktree" ]; then
      echo "WARNING: flow-state.sh cmd_set: --require-worktree set but worktree path is empty (phase=$phase; multi_session worktree 化漏れの可能性 — #1595)" >&2
      echo "[CONTEXT] WORKTREE_INVARIANT=missing; phase=$phase" >&2
    else
      echo "[CONTEXT] WORKTREE_INVARIANT=ok; phase=$phase; worktree=$worktree" >&2
    fi
  fi
  [ -z "$pr" ] && pr=$cur_pr
  [ -z "$parent_issue" ] && parent_issue=$cur_parent
  [ -z "$active" ] && active=$cur_active
  local err_count=0
  [ $preserve_error -eq 1 ] && err_count=$cur_err
  # `handoff` は review↔fix loop / cleanup wiki チェーンの one-shot マーカー。`error_count` と同様に
  # **phase transition (= 毎 set) でデフォルトクリア** する設計のため、merge-read (cur_*) に含めず
  # `--handoff` が明示指定された時だけ書き込む。`--handoff` 省略時は key 自体を付与しない
  # (= 空) ことで、loop 外の set が自動的に handoff をクリアし、stale handoff が次サイクルに漏れない。
  # handoff には 3 種類の値が入る:
  #   - 継続 handoff "/rite:..." : 継続 sentinel (review:fix-needed / fix:pushed) を出す sub-skill が渡す。
  #   - 終了 handoff "FINALIZE:{result}:{pr}" : 終了 sentinel (mergeable / replied-only / cancelled) を
  #     出す sub-skill が渡す。
  #   - チェーン handoff "WIKICHAIN:{caller}:{pr}" : cleanup.md ステップ 9 が wiki-ingest invoke 直前に
  #     渡す。チェーン完走時はステップ 12 の set (--handoff なし) が default-clear する。
  #   `flow-state.sh` 自体は任意文字列を verbatim 格納するため
  #   機構変更は不要 — prefix 分岐は Stop hook (stop-loop-continuation.sh) 側の reason 生成で行う。
  # Stop hook が `consume-handoff` で読み取り + 削除し、prefix で reason を分岐して block する
  # (block 可否は handoff 非空かどうかで決まり、prefix は再注入する reason の選択にのみ影響する)。
  local now new; now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  # `_new_jq_err` capture (symmetric with the composite read's `_cur_jq_err`): the
  # `tonumber` conversion below can fail on a corrupt on-disk `wm_comment_id`, and jq's
  # own error text quotes the offending raw value. Without capturing stderr here it went
  # straight to the terminal unneutralized, bypassing the `_emit_jq_err_snippet` control-char
  # convention every other diagnostic site in this file uses (#1810 cycle 2 security finding).
  local _new_jq_err="" _new_rc=0
  _new_jq_err=$(mktemp 2>/dev/null) || _new_jq_err=""
  new=$(jq -n \
    --argjson schema "$SCHEMA_VERSION_V3" --arg session "$sid" \
    --arg phase "$phase" --argjson issue "$issue" --arg branch "$branch" \
    --argjson pr "$pr" --argjson parent "$parent_issue" \
    --arg next "$next" --argjson active "$active" \
    --argjson err "$err_count" --arg ts "$now" \
    --arg lsp "$cur_last_synced" --arg handoff "$handoff" --arg worktree "$worktree" \
    --argjson cycle "$cycle_count" --arg wmcid "$cur_wm_comment_id" \
    '{schema_version:$schema, session_id:$session, phase:$phase,
      issue_number:$issue, branch:$branch, pr_number:$pr,
      parent_issue_number:$parent, next_action:$next, active:$active,
      error_count:$err, updated_at:$ts}
     | (if $lsp != "" then .last_synced_phase = $lsp else . end)
     | (if $worktree != "" then .worktree = $worktree else . end)
     | (if $handoff != "" then .handoff = $handoff else . end)
     | (if $cycle != 0 then .cycle_count = $cycle else . end)
     | (if $wmcid != "" then .wm_comment_id = ($wmcid | tonumber) else . end)' 2>"${_new_jq_err:-/dev/null}") || _new_rc=$?
  if [ "$_new_rc" -ne 0 ]; then
    echo "WARNING: flow-state.sh cmd_set: state write failed for $(basename "$path") (wm_comment_id not numeric, or other jq failure)" >&2
    _emit_jq_err_snippet "$_new_jq_err"
    [ -n "$_new_jq_err" ] && rm -f "$_new_jq_err"
    return 1
  fi
  [ -n "$_new_jq_err" ] && rm -f "$_new_jq_err"
  # `_atomic_write` の header コメント ("Callers MUST check rc") を遵守。現状は cmd_set の
  # 最終 statement のため set -e で rc が暗黙伝播するが、将来 `_atomic_write` の後に log 行を
  # 1 つ足す等の小修正で silent failure path が即復活する fragile pattern を避けるため、明示的
  # に `|| return 1` で rc を伝播させる (`_migrate_file` の `_atomic_write` 呼び出し直前と対称化)。
  _atomic_write "$path" "$new" || return 1
}

# clear-worktree: surgically remove the `worktree` field from a session's
# flow-state, returning the file to its non-worktree (additive-key-absent) shape.
# Mirrors cmd_deactivate's single-field write (`.active=false`) rather than going
# through cmd_set, so callers need NOT know/preserve --phase/--next: cmd_set
# requires both and would overwrite phase, forcing a read-modify-write of the
# owner's phase/next just to clear one key (wider race window). Two callers:
#   1. pr-cycle-cleanup.sh Step 5 reap → null the owning session's dangling
#      `worktree` after the directory is removed (--session targets the owner).
#   2. session-start.sh dangling self-heal → null the current session's `worktree`
#      when the recorded path no longer exists.
# Idempotent: no-op (no write, no updated_at churn) when the key is already
# absent or the state file does not exist — keeps wm-sync's diff guard quiet and
# preserves the merge-preserve contract of cmd_set untouched (the `--worktree ""`
# merge-preserve path in cmd_set is intentionally NOT changed). Routes through
# `_atomic_write` per the corruption-prevention convention; rc is propagated.
cmd_clear_worktree() {
  local session=""
  while [ $# -gt 0 ]; do case "$1" in
    --session) session="$2"; shift 2 ;;
    *) echo "ERROR: unknown option: $1" >&2; return 1 ;;
  esac; done
  local sid path; sid=$(_resolve_session_id "$session") || return 1
  path=$(_state_path "$sid"); [ ! -f "$path" ] && return 0
  # Idempotent: skip the write when there is no worktree key. jq read failure
  # (corrupt JSON) falls through to "false" → no-op; a corrupt file is left for
  # the cmd_set/cmd_get WARNING paths to surface rather than rewritten blindly here.
  local has_wt; has_wt=$(jq -r 'has("worktree")' "$path" 2>/dev/null) || has_wt="false"
  [ "$has_wt" = "true" ] || return 0
  local now updated; now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  updated=$(jq --arg ts "$now" 'del(.worktree) | .updated_at = $ts' "$path") || return 1
  # `_atomic_write` rc 伝播 (cmd_set / cmd_deactivate / `_migrate_file` と対称、header 契約遵守)。
  _atomic_write "$path" "$updated" || return 1
}

cmd_get() {
  local field="" default="" session="" jq_filter=""
  while [ $# -gt 0 ]; do case "$1" in
    --field) field="$2"; shift 2 ;;
    --default) default="$2"; shift 2 ;;
    --session) session="$2"; shift 2 ;;
    --jq-filter) jq_filter="$2"; shift 2 ;;
    *) echo "ERROR: unknown option: $1" >&2; return 1 ;;
  esac; done
  local sid path jq_err=""
  # RETURN trap で mktemp tempfile cleanup を集約する。SIGINT / set -e / 関数 early
  # return / 関数末尾 fall-through すべての経路で確実に削除される。
  trap '[ -n "${jq_err:-}" ] && rm -f "${jq_err:-}"' RETURN
  # Do not silence _resolve_session_id stderr: when neither `.rite-session-id` nor
  # the env vars are usable, the helper's ERROR message must surface so the silent
  # "empty + rc=0" failure path becomes diagnosable.
  sid=$(_resolve_session_id "$session") || { printf '%s\n' "$default"; return 0; }
  path=$(_state_path "$sid")
  if [ ! -f "$path" ]; then
    # Stale `.rite-session-id` pointing to a nonexistent state file is a drift signal —
    # WARN so it is observable. Truly first-time sessions (no `.rite-session-id`) stay
    # silent: the caller's --default fallback is the legitimate graceful path.
    # path 全体ではなく basename のみを露出し、multi-tenant 環境での絶対 path leakage
    # を最小化する。診断に必要な情報 (どのファイル名か / SESSION_DIR は既知) は basename
    # で十分。
    if [ -f "$SESSION_ID_FILE" ]; then
      echo "WARNING: flow-state.sh cmd_get: state file not found for resolved session_id=$sid (file: $(basename "$path"); possible stale .rite-session-id); returning --default" >&2
    fi
    printf '%s\n' "$default"
    return 0
  fi
  jq_err=$(mktemp 2>/dev/null) || jq_err=""
  if [ -n "$jq_filter" ]; then
    if ! jq -r "$jq_filter" "$path" 2>"${jq_err:-/dev/null}"; then
      echo "WARNING: flow-state.sh cmd_get: jq filter failed for $(basename "$path") (filter: $jq_filter); returning --default" >&2
      _emit_jq_err_snippet "$jq_err"
      printf '%s\n' "$default"
    fi
    return 0
  fi
  if [ -z "$field" ]; then
    echo "ERROR: --field or --jq-filter required" >&2
    return 1
  fi
  if ! jq -r --arg d "$default" ".${field} // \$d" "$path" 2>"${jq_err:-/dev/null}"; then
    echo "WARNING: flow-state.sh cmd_get: jq read failed for $(basename "$path") (field: $field); returning --default" >&2
    _emit_jq_err_snippet "$jq_err"
    printf '%s\n' "$default"
  fi
  return 0
}

cmd_deactivate() {
  local next="" session=""
  while [ $# -gt 0 ]; do case "$1" in
    --next) next="$2"; shift 2 ;;
    --session) session="$2"; shift 2 ;;
    *) echo "ERROR: unknown option: $1" >&2; return 1 ;;
  esac; done
  local sid path; sid=$(_resolve_session_id "$session") || return 1
  path=$(_state_path "$sid"); [ ! -f "$path" ] && return 0
  local now updated; now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  updated=$(jq --argjson a false --arg n "$next" --arg ts "$now" \
    '.active = $a | (if $n != "" then .next_action = $n else . end) | .updated_at = $ts' "$path") || return 1
  # `_atomic_write` rc 伝播 (cmd_set / `_migrate_file` と対称、header 契約遵守)。
  _atomic_write "$path" "$updated" || return 1
}

# consume-handoff: review↔fix loop / cleanup wiki チェーンの one-shot 継続マーカーを
# **読み取り + 削除** する。
# Stop hook (stop-loop-continuation.sh) が turn 終了時に呼ぶ。`handoff` が非空ならその値を stdout に
# 出力し、同じ呼び出しで file から削除 (atomic) する。これにより:
#   - handoff 非空 → 値を出力 → hook が block + 再注入。削除済みなので次に LLM が何もせず止まれば
#     handoff は空 → block しない (無限 block ループ防止 / AC-3)。
#   - 継続 sentinel を出すたびに sub-skill が handoff を再セットするため複数サイクル継続する (AC-1)。
# session 解決失敗 / state file 不在 / handoff 空 のいずれも「出力なし + rc=0」(= block しない) に縮退する。
# 削除を **値の出力より前** に行う (fail-closed 順序): 削除に成功した周回だけ値を stdout に出す。
# これにより `_atomic_write` が永続的に失敗する環境 (read-only FS / ENOSPC / EACCES) でも、削除できない
# 周回は値を出さない = hook が block しないため、stale handoff による無限 block (AC-3 違反) を起こさない。
# 削除失敗は rc=0 で握るが、診断 ERROR を stderr に emit する (cmd_set / `_atomic_write` の他経路と対称化し、
# fail-open を無診断にしない)。"print してから削除する" 旧順序では削除失敗時に値が既に出力済みで block が
# 確定するため、回収不能な永続障害下で無限 block する経路があった。
cmd_consume_handoff() {
  local session=""
  while [ $# -gt 0 ]; do case "$1" in
    --session) session="$2"; shift 2 ;;
    *) echo "ERROR: unknown option: $1" >&2; return 1 ;;
  esac; done
  local sid path; sid=$(_resolve_session_id "$session") || return 0
  path=$(_state_path "$sid"); [ ! -f "$path" ] && return 0
  # corrupt JSON でも空 handoff に縮退して停止を許可するのは AC-3 の fail-open (安全側) で正しい。
  # 欠落しているのは observability のみ — 無診断だと corrupt を検出できないため、jq rc を捕捉し
  # cmd_set / cmd_get と対称に WARNING + stderr スニペットを emit する。関数内は無条件 emit とし、
  # RITE_DEBUG gate は唯一の呼び出し元 stop-loop-continuation.sh の 2>/dev/null に委譲する
  # (本関数の handoff-clear ERROR と同じ方式)。`handoff` キー欠落の正常系は `// ""` で rc=0 のまま
  # WARNING を出さない。
  local handoff _ho_jq_err="" _ho_rc=0
  _ho_jq_err=$(mktemp 2>/dev/null) || _ho_jq_err=""
  trap '[ -n "${_ho_jq_err:-}" ] && rm -f "${_ho_jq_err:-}"' RETURN
  handoff=$(jq -r '.handoff // ""' "$path" 2>"${_ho_jq_err:-/dev/null}") || _ho_rc=$?
  if [ "$_ho_rc" -ne 0 ]; then
    echo "WARNING: flow-state.sh consume-handoff: handoff read failed for $(basename "$path") (may be corrupt; treating as empty → stop allowed)" >&2
    _emit_jq_err_snippet "$_ho_jq_err"
    handoff=""
  fi
  [ -z "$handoff" ] && return 0
  local updated; updated=$(jq 'del(.handoff)' "$path" 2>/dev/null) || {
    echo "ERROR: consume-handoff: jq del(.handoff) failed for $(basename "$path") (handoff not cleared; value withheld to avoid re-block)" >&2
    return 0
  }
  _atomic_write "$path" "$updated" || {
    echo "ERROR: consume-handoff: handoff clear failed for $(basename "$path") (stale handoff may re-block under persistent FS failure; value withheld)" >&2
    return 0
  }
  printf '%s\n' "$handoff"
}

# Returns:
#   0 on actually-performed migration (`migrated:` announced unconditionally on stderr, AC-8)
#   0 on `--dry-run` (no rewrite; "would migrate:" printed to **stderr** for stdout/stderr
#                     consistency with the migration announcement — session-start silences
#                     only stdout, so dry-run preview surfaces alongside real migrations)
#   1 on skip (already v3) or error (jq parse failure / _atomic_write IO failure)
# Caller `cmd_migrate` uses `&& migrated=$((migrated + 1)) || true` and therefore skip is
# NOT counted in the "Migration complete: N" summary (only rc=0 increments). Treating skip
# and error identically as rc=1 is intentional — both mean "no rewrite happened".
_migrate_file() {
  local f="$1" dry="$2" verbose="$3" sv cp np
  sv=$(jq -r '.schema_version // 1' "$f" 2>/dev/null) || sv=1
  cp=$(jq -r '.phase // ""' "$f" 2>/dev/null) || cp=""
  [ "$sv" = "$SCHEMA_VERSION_V3" ] && { [ "$verbose" = 1 ] && echo "  skip (already v3): $f" >&2; return 1; }
  np=$(_phase_migrate "$cp")
  # `--dry-run` の preview を stderr に統一する (本関数末尾の `migrated:` announcement と対称化)。
  # session-start.sh は stdout のみ silence するため、dry-run preview を stderr に出すことで
  # 実際の migration announcement と同じ経路で observability を確保する。
  [ "$dry" = 1 ] && { echo "  would migrate: $f (schema v$sv→v$SCHEMA_VERSION_V3, phase $cp→$np)" >&2; return 0; }
  local now updated; now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  # v3 schema: drop legacy `previous_phase` (replaced by step name discrimination in v3) and
  # normalize legacy `branch_name` → `branch`. `last_synced_phase` is preserved because
  # post-tool-wm-sync.sh continues to use it as a runtime-only diff guard field;
  # dropping it during migrate would cause one round of unnecessary GitHub API spam right after
  # migration.
  updated=$(jq --argjson s "$SCHEMA_VERSION_V3" --arg p "$np" --arg ts "$now" \
    'del(.previous_phase)
     | (if .branch_name and (.branch | not) then .branch = .branch_name else . end)
     | del(.branch_name)
     | .schema_version = $s | .phase = $p | .updated_at = $ts' "$f") || return 1
  # _atomic_write の rc を必ず伝播させる。`cmd_migrate` の `&&` 連結により _migrate_file 内で
  # set -e が抑制されるため、`_atomic_write` が flock timeout / mv 失敗 / EXDEV / EACCES /
  # ENOSPC / EROFS / printf 書き込み失敗で rc=1 を返しても、`|| return 1` がなければ実行は
  # 下流の `echo "  migrated: ..."` まで継続し、false announcement (migration counter inflate +
  # AC-8 invariant 違反) を引き起こす。`|| return 1` で early-return することで、announce は
  # physical-completion (atomic mv 成功) 後の経路でのみ出ることを保証する。
  _atomic_write "$f" "$updated" || return 1
  # AC-8 (silent skip forbidden): an actually-performed migration is always
  # announced on stderr, even without --verbose, so the session-start auto path
  # (session-start.sh silences only stdout) surfaces it. The no-op "skip (already
  # v3)" case above stays --verbose-gated to keep quiet session starts quiet.
  echo "  migrated: $f (v$sv→v$SCHEMA_VERSION_V3, $cp→$np)" >&2
  return 0
}

cmd_migrate() {
  local dry=0 verbose=0 migrated=0
  while [ $# -gt 0 ]; do case "$1" in
    --dry-run) dry=1; shift ;;
    --verbose) verbose=1; shift ;;
    *) echo "ERROR: unknown option: $1" >&2; return 1 ;;
  esac; done
  if [ -d "$SESSION_DIR" ]; then
    for f in "$SESSION_DIR"/*.flow-state; do
      [ -f "$f" ] || continue
      _migrate_file "$f" "$dry" "$verbose" && migrated=$((migrated + 1)) || true
    done
  fi
  [ -f "$LEGACY_STATE" ] && _migrate_file "$LEGACY_STATE" "$dry" "$verbose" && migrated=$((migrated + 1)) || true
  echo "Migration complete: $migrated file(s) processed"
}

cmd_path() {
  local session=""
  while [ $# -gt 0 ]; do case "$1" in
    --session) session="$2"; shift 2 ;;
    *) echo "ERROR: unknown option: $1" >&2; return 1 ;;
  esac; done
  local sid; sid=$(_resolve_session_id "$session") || return 1
  _state_path "$sid"
}

case "${1:-}" in
  set) shift; cmd_set "$@" ;;
  get) shift; cmd_get "$@" ;;
  deactivate) shift; cmd_deactivate "$@" ;;
  clear-worktree) shift; cmd_clear_worktree "$@" ;;
  consume-handoff) shift; cmd_consume_handoff "$@" ;;
  migrate) shift; cmd_migrate "$@" ;;
  path) shift; cmd_path "$@" ;;
  *)
    cat >&2 <<EOF
Usage: $0 {set|get|deactivate|clear-worktree|consume-handoff|migrate|path} [options]
  set --phase <P> --next <T> [--issue N] [--branch S] [--pr N] [--parent-issue N]
      [--active true|false] [--handoff CMD] [--session UUID] [--if-exists] [--preserve-error-count]
      [--worktree PATH] [--require-worktree]   # --require-worktree: warn + emit WORKTREE_INVARIANT marker when worktree empty (non-blocking)
  get --field <F> [--default V] [--session UUID]
      | --jq-filter <FILTER> [--default V] [--session UUID]
  deactivate [--next T] [--session UUID]
  clear-worktree [--session UUID]    # surgically del(.worktree); idempotent, no phase/next needed
  consume-handoff [--session UUID]   # print + clear the one-shot handoff marker
  migrate [--dry-run] [--verbose]
  path [--session UUID]
Phase enum (v3): $PHASE_ENUM_V3
EOF
    exit 1
    ;;
esac
