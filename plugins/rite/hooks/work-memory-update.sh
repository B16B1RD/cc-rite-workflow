#!/bin/bash
# rite workflow - Work Memory Update (shared helper)
# Provides a function to update local work memory files (.rite-work-memory/issue-{n}.md).
# Handles: lock acquisition, YAML frontmatter parsing, atomic file write, lock release.
#
# Usage (source from another script or inline):
#   source {plugin_root}/hooks/work-memory-update.sh
#   WM_SOURCE="implement" WM_PHASE="phase5_lint" WM_PHASE_DETAIL="品質チェック準備" \
#     WM_NEXT_ACTION="rite:lint を実行" WM_BODY_TEXT="Post-implementation." \
#     WM_PLUGIN_ROOT="/path/to/plugin" \
#     update_local_work_memory
#
# Required environment variables:
#   WM_SOURCE       - Source identifier (e.g., "implement", "lint", "fix")
#   WM_PHASE        - Phase value (e.g., "phase5_lint")
#   WM_PHASE_DETAIL - Phase detail description
#   WM_NEXT_ACTION  - Next action description
#   WM_BODY_TEXT    - Body text after YAML frontmatter closing ---
#   WM_PLUGIN_ROOT  - Absolute path to the plugin root directory
#
# Optional environment variables:
#   WM_ISSUE_NUMBER         - Override issue number detection (skip branch-based parsing).
#                             Use when the caller already knows the issue number (e.g., pre-compact).
#                             (default: extracted from branch name)
#   WM_SKIP_LOCK            - If "true", skip lock acquisition/release. Use when the caller
#                             already holds an outer lock protecting the work memory file.
#                             (default: "false")
#   WM_PR_NUMBER            - PR number override. Effective only when WM_LOOP_INCREMENT != "true"
#                             and WM_READ_FROM_FLOW_STATE != "true". Otherwise, the value is read
#                             from existing WM (fix pattern) or .rite-flow-state (lint pattern).
#                             (default: read from existing WM or "null")
#   WM_LOOP_COUNT           - Loop count override. Same effective conditions as WM_PR_NUMBER.
#                             (default: read from existing WM or 0)
#   WM_LOOP_INCREMENT       - If "true", increment loop_count from existing WM (fix pattern).
#                             When set, WM_PR_NUMBER/WM_LOOP_COUNT overrides are ignored;
#                             values are parsed from the existing work memory file instead.
#                             (default: "false")
#   WM_REQUIRE_FLOW_STATE   - If "true", skip if flow-state phase cannot be resolved via
#                             state-read.sh (per-session and legacy file both absent, or phase
#                             is null/empty). Uses state-read.sh under the hood so schema_version=2
#                             per-session files are resolved transparently. (default: "false")
#   WM_READ_FROM_FLOW_STATE - If "true", read pr_number/loop_count from .rite-flow-state (lint pattern).
#                             When set, overrides WM_PR_NUMBER/WM_LOOP_COUNT and values from existing WM.
#                             (default: "false")
#
# Security note:
#   PR #688 followup: cycle 41 review F-13 MEDIUM (security Hypothetical exception) — 旧実装は
#   WM_* 環境変数を caller 責務で sanitize する設計だったが、orchestrator 経由で LLM 出力 / Issue
#   タイトル / next_action 等の動的文字列が直接 frontmatter に流入する経路があり defense-in-depth
#   不在だった。本 PR で `_sanitize_yaml_value()` helper を導入し、frontmatter 書き込み箇所すべてで
#   適用する (`"` を `\"` に escape、改行を除去)。WM_BODY_TEXT は frontmatter 外なので除外。
#   caller 責務は引き続き有効 (helper は defense-in-depth の二段目)。
#
# Exit codes:
#   0: Success (work memory updated)
#   1: Skipped (no issue number in branch or flow state required but missing)
#   2: Lock acquisition failed (non-fatal, logged as warning)

# Source lock helper at file load time (not inside the function)
# This avoids re-sourcing on every function call and prevents BASH_SOURCE issues.
source "$(dirname "${BASH_SOURCE[0]}")/work-memory-lock.sh"

# verified-review F-04 MEDIUM: state-read.sh 呼び出し boilerplate を helper 関数に抽出。
# 旧実装は (a) helper executable check と (b) `if cmd; then :; else rc=$?; ...; return 2; fi` 形式の
# fail-fast capture を 3 箇所 (line 96-110 / 175-186 / 187-193) で完全に同一構造で複製していた。
# 共通 helper に集約することで spec 変更を 1 箇所で完結させる。
#
# verified-review (PR #688 cycle 14) F-05 (MEDIUM) 対応: 旧コメントは
# 「resume-active-flag-restore.sh にも 2 site 存在し計 5 site の boilerplate 重複を集約する
# (writer/reader/resume 3 layer DRY 化)」と主張していたが、resume layer の 2 site
# (resume-active-flag-restore.sh の curr_phase / curr_next 抽出ブロック) は **本 PR では consolidate
# されていない**。したがって本 helper の集約スコープは work-memory-update.sh 内 3 site のみで、
# resume layer の片肺更新リスクは別 Issue で追跡する必要がある (claim と実装の整合性回復)。
#
# Arguments:
#   $1 var_name  caller 側で値を受け取る変数名 (e.g., "_phase")
#   $2 field     state-read.sh の --field に渡す値 (e.g., "phase" / "pr_number" / "loop_count")
#   $3 default   state-read.sh の --default に渡す値 (e.g., "" / "null" / "0")
# Returns:
#   0 — success (var_name に値が代入される)
#   2 — helper 不在 / helper exit != 0 (fail-fast)
_wm_state_read_field() {
  local _var_name="$1"
  local _field="$2"
  local _default="$3"
  if [ ! -x "$WM_PLUGIN_ROOT/hooks/state-read.sh" ]; then
    echo "rite: ${WM_SOURCE}: state-read.sh not found at $WM_PLUGIN_ROOT/hooks/" >&2
    return 2
  fi
  local _val _rc
  if _val=$(bash "$WM_PLUGIN_ROOT/hooks/state-read.sh" --field "$_field" --default "$_default"); then
    printf -v "$_var_name" '%s' "$_val"
    return 0
  else
    _rc=$?
    echo "rite: ${WM_SOURCE}: state-read.sh failed (rc=$_rc) for --field $_field" >&2
    return 2
  fi
}

update_local_work_memory() {
  local issue_number current_branch
  current_branch=$(git branch --show-current 2>/dev/null || echo "")
  issue_number="${WM_ISSUE_NUMBER:-}"
  if [ -n "$issue_number" ] && ! [[ "$issue_number" =~ ^[0-9]+$ ]]; then
    echo "rite: ${WM_SOURCE:-work-memory-update}: invalid WM_ISSUE_NUMBER: $issue_number" >&2
    issue_number=""
  fi
  if [ -z "$issue_number" ]; then
    issue_number=$(echo "$current_branch" | grep -oE 'issue-[0-9]+' | grep -oE '[0-9]+')
  fi
  if [ -z "$issue_number" ]; then
    return 1
  fi

  # PR #688 cycle 12 fix (F-01 HIGH AC-4 caller migration完遂):
  # legacy `.rite-flow-state` 直接 `[ ! -f ]` check を state-read.sh 経由に変更。
  # cycle 10 で WM_READ_FROM_FLOW_STATE 分岐の同種 read を移行済みだが、本箇所
  # (WM_REQUIRE_FLOW_STATE check) は cycle 11 review で取り残しが指摘された。
  # (verified-review cycle 29 F-04 MEDIUM: cycle 28 で確立した semantic anchor 規範を本箇所
  # にも適用。旧 "line 130 / line 72" は code shift で drift 済み)
  # schema_version=2 環境で per-session file (`.rite/sessions/{sid}.flow-state`)
  # のみ存在し legacy file 不在のとき、旧 check は false negative で skip し work memory が更新されない
  # (例: lint pattern で session 起点の caller が WM_REQUIRE_FLOW_STATE=true を渡しても skip される)。
  # state-read.sh は per-session/legacy 両方を transparent に解決し、両方不在時のみ default ("") を
  # 返すため、空文字判定で「flow-state が解決できない」状態を正確に検出できる。
  #
  # verified-review cycle 33 fix (F-01 HIGH): state-read.sh 起動失敗 (ENOENT / WM_PLUGIN_ROOT 不正 /
  # permission denied 等) が「両 file 不在 → DEFAULT 返却」と区別不能で silent skip される regression
  # を解消する。helper が **存在しない** ケースは return 2 で fail-fast、**存在するが exit != 0** の
  # ケース (jq エラー / 内部失敗) も独立 exit code 捕捉で fail-fast。**存在し exit == 0 だが空文字**
  # のみが legitimate な「両 file 不在」として return 1 で skip される (Fail-Fast First 原則)。
  if [ "${WM_REQUIRE_FLOW_STATE:-false}" = "true" ]; then
    local _phase=""
    _wm_state_read_field _phase phase "" || return $?
    if [ -z "$_phase" ]; then
      return 1
    fi
  fi

  local local_wm=".rite-work-memory/issue-${issue_number}.md"
  local lockdir="${local_wm}.lockdir"

  # Defensive: ensure parent directory exists before lock acquisition
  mkdir -p .rite-work-memory 2>/dev/null || { echo "rite: ${WM_SOURCE}: failed to create .rite-work-memory directory" >&2; return 2; }
  chmod 700 .rite-work-memory 2>/dev/null || true

  if [ "${WM_SKIP_LOCK:-false}" = "true" ]; then
    :  # Lock skipping; RETURN trap set later in this function after mktemp (anchor: tmp_wm_mktemp below)
  else
    WM_LOCK_STALE_THRESHOLD="${WM_LOCK_STALE_THRESHOLD:-300}"

    if ! acquire_wm_lock "$lockdir"; then
      echo "rite: ${WM_SOURCE}: local work memory lock failed" >&2
      return 2
    fi

    # Ensure lock is released on function return (normal or abnormal exit)
    trap 'release_wm_lock "$lockdir"' RETURN
  fi

  local sync_rev=1
  local loop_cnt="${WM_LOOP_COUNT:-0}"
  local pr_num="${WM_PR_NUMBER:-null}"
  local parse_script="${WM_PLUGIN_ROOT}/hooks/work-memory-parse.py"

  if [ -f "$local_wm" ]; then
    if [ "${WM_LOOP_INCREMENT:-false}" = "true" ]; then
      # fix pattern: parse full output, increment loop_count and sync_revision
      local parse_out=""
      if [ -f "$parse_script" ]; then
        parse_out=$(python3 "$parse_script" "$local_wm" 2>/dev/null) || parse_out=""
      fi
      if [ -n "$parse_out" ]; then
        local parsed
        parsed=$(echo "$parse_out" | jq -r '[(.data.sync_revision // 0) + 1, (.data.loop_count // 0) + 1, (.data.pr_number // "null")] | @tsv' 2>/dev/null) || parsed=""
        if [ -n "$parsed" ]; then
          read -r sync_rev loop_cnt pr_num <<< "$parsed"
        else
          sync_rev=1; loop_cnt=1; pr_num="null"
        fi
      fi
    else
      # implement/lint pattern: just increment sync_revision
      local existing_rev="0"
      if [ -f "$parse_script" ]; then
        existing_rev=$(python3 "$parse_script" "$local_wm" 2>/dev/null | jq -r '.data.sync_revision // 0' 2>/dev/null) || existing_rev="0"
      fi
      if [[ "$existing_rev" =~ ^[0-9]+$ ]]; then sync_rev=$((existing_rev + 1)); fi
    fi
  fi

  # Read flow-state fields if requested (lint pattern).
  # PR #688 cycle 10 fix (F-02 HIGH AC-4 caller migration): legacy `.rite-flow-state` 直接読みを
  # state-read.sh 経由に変更。schema_version=2 環境では state-read.sh が per-session file を解決
  # するため、別 session の stale residue を読まなくなる。state-read.sh は per-session/legacy
  # 両方を transparent に解決し、両方不在時は default を返すので、外側の `[ -f ]` check は不要。
  #
  # verified-review cycle 33 fix (F-01 HIGH): WM_REQUIRE_FLOW_STATE 経路と対称化。helper 存在性 +
  # exit code を独立 capture して silent skip を防ぐ (Fail-Fast First 原則)。`|| pr_num="null"` と
  # `|| loop_cnt="0"` の旧 fallback パターンは「両 file 不在 → DEFAULT 返却」と「helper 起動失敗」を
  # 区別不能で silent fallback していたため fail-fast に変更。
  if [ "${WM_READ_FROM_FLOW_STATE:-false}" = "true" ]; then
    _wm_state_read_field pr_num pr_number "null" || return $?
    _wm_state_read_field loop_cnt loop_count 0 || return $?
  fi

  local last_commit tmp_wm
  local branch="$current_branch"
  last_commit=$(git rev-parse --short HEAD 2>/dev/null || echo "")
  # anchor: tmp_wm_mktemp (referenced by lock-skip path comment above)
  tmp_wm=$(mktemp "${local_wm}.tmp.XXXXXX") || { echo "rite: ${WM_SOURCE}: mktemp failed" >&2; return 2; }
  # Extend RETURN trap to also clean up temp file (rm -f is safe even after successful mv)
  if [ "${WM_SKIP_LOCK:-false}" = "true" ]; then
    trap 'rm -f "$tmp_wm"' RETURN
  else
    trap 'rm -f "$tmp_wm"; release_wm_lock "$lockdir"' RETURN
  fi

  # PR #688 followup: cycle 41 review F-13 MEDIUM (security Hypothetical exception) —
  # YAML frontmatter 値の defense-in-depth sanitization。改行除去 + backslash escape + `"` を `\"` に escape して
  # frontmatter 破損 / 子 key injection を防ぐ (caller 責務に加えた二段目の防御層)。
  # WM_BODY_TEXT は frontmatter 外なので除外 (markdown body は改行を保持する必要がある)。
  #
  # verified-review cycle 44 F-12 MEDIUM (security Hypothetical exception):
  # backslash escape を追加。値が `\` で終わる場合、YAML double-quoted string では
  # closing `"` が `\"` の escape sequence と解釈されて閉じクォート消失 → 後続の
  # `phase_detail: "..."` 行を value continuation として誤 parse する経路があった。
  # 例: WM_PHASE='foo\' → `phase: "foo\"` → escaped quote → continuation。
  # まず backslash を `\\` に escape してから `"` → `\"` の順で sed を実行する
  # (順序逆転すると新たに作った escape sequence の `\` が更に escape されてしまう)。
  # tr -d '[:cntrl:]' に拡張し、tab / BEL (0x07) / DEL (0x7F) 等の他制御文字も strip する。
  # workflow-incident-emit.sh / _emit-cross-session-incident.sh / _resolve-session-id-from-file.sh の
  # superset cntrl char strip 規範と対称化 (tab / BEL を含む caller-supplied 値が frontmatter の
  # double-quoted string に literal で混入する経路を遮断する)。
  _sanitize_yaml_value() {
    printf '%s' "$1" | tr -d '[:cntrl:]' | sed 's/\\/\\\\/g; s/"/\\"/g'
  }
  # 数値フィールド (pr_num / loop_cnt) の YAML literal 化 helper。state-read.sh 経由で取得される
  # 値に改行 / 制御文字 / その他非数値が混入していた場合 (tampered/corrupt な flow-state file の防御)、
  # `null` (YAML literal) に降格して frontmatter parse の破壊を防ぐ。
  # 引数: $1 = 値, $2 = フィールド名 (WARNING に出力)。stdout に YAML literal を出力。
  _validate_numeric_yaml_value() {
    local _v="$1" _name="$2"
    case "$_v" in
      ''|null) printf 'null'; return 0 ;;
    esac
    case "$_v" in
      *[!0-9]*)
        echo "WARNING: $_name contains non-numeric character (probable YAML injection attempt or state corruption), forcing 'null'" >&2
        printf 'null'
        return 0
        ;;
    esac
    printf '%s' "$_v"
  }
  local _wm_phase_san _wm_phase_detail_san _wm_next_san _wm_source_san _branch_san _last_commit_san
  _wm_phase_san=$(_sanitize_yaml_value "$WM_PHASE")
  _wm_phase_detail_san=$(_sanitize_yaml_value "$WM_PHASE_DETAIL")
  _wm_next_san=$(_sanitize_yaml_value "$WM_NEXT_ACTION")
  _wm_source_san=$(_sanitize_yaml_value "$WM_SOURCE")
  _branch_san=$(_sanitize_yaml_value "$branch")
  _last_commit_san=$(_sanitize_yaml_value "$last_commit")

  # verified-review (PR #688 cycle 15) F-04 (MEDIUM) 対応 + post-review F-01 (MEDIUM) DRY 化:
  # pr_num / loop_cnt は state-read.sh 経由で flow-state JSON から取得されるが、jq -r は raw string を
  # 返すため、tampered/corrupt な flow-state file (例: `{"pr_number": "123\nmalicious: injection"}`) で
  # 改行込みの値が返ると YAML frontmatter parse が破壊される (Issue #687 同型の writer/reader 対称化破綻)。
  # 数値型 validation を _validate_numeric_yaml_value() helper に集約し、新規数値フィールド追加時の
  # 片肺更新リスクを構造的に解消した (本 PR review F-01)。
  local _pr_num_san _loop_cnt_san
  _pr_num_san=$(_validate_numeric_yaml_value "$pr_num" pr_num)
  _loop_cnt_san=$(_validate_numeric_yaml_value "$loop_cnt" loop_cnt)

  {
    printf '# 📜 rite 作業メモリ\n\n'
    printf '## Summary\n'
    printf -- '---\n'
    printf 'schema_version: 1\n'
    printf 'issue_number: %s\n' "$issue_number"
    printf 'sync_revision: %s\n' "$sync_rev"
    printf 'sync_status: pending\n'
    printf 'source: %s\n' "$_wm_source_san"
    printf 'last_modified_at: "%s"\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    printf 'phase: "%s"\n' "$_wm_phase_san"
    printf 'phase_detail: "%s"\n' "$_wm_phase_detail_san"
    printf 'next_action: "%s"\n' "$_wm_next_san"
    printf 'branch: "%s"\n' "$_branch_san"
    printf 'pr_number: %s\n' "$_pr_num_san"
    printf 'last_commit: "%s"\n' "$_last_commit_san"
    printf 'loop_count: %s\n' "$_loop_cnt_san"
    printf -- '---\n'
    printf '\n%s\n' "$WM_BODY_TEXT"
    printf '\n## Detail\nPhase: %s\nBranch: %s\n' "$_wm_phase_san" "$_branch_san"
  } > "$tmp_wm"

  chmod 600 "$tmp_wm" 2>/dev/null || true
  mv "$tmp_wm" "$local_wm"
  return 0
}
