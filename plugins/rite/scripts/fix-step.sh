#!/bin/bash
# rite workflow - /rite:fix step bodies
#
# Responsibility: hold the shell body of every multi-statement step in
# skills/fix/SKILL.md and the procedures it reads from skills/fix/references/,
# so that the skill calls each step as one top-level
# `bash {plugin_root}/scripts/fix-step.sh <subcommand> --opt value ...`.
# A session worktree entered natively isolates the host shell, and the host
# refuses blocks that source files or mix command substitution, loops and git
# with other statements. A single top-level `bash <file> <literal args>` passes
# (see references/git-worktree-patterns.md#host-worktree-execution).
#
# The skill keeps the routing tables for every marker emitted here. This file
# only moves where the shell text lives; marker names, values and exit codes
# are the contract the skill reads.
#
# The fix commit itself is not here. The PreToolUse guard inspects `git commit`
# in the Bash command text, so the skill runs the commit as a literal command.
#
# Free text written by the caller (reply body, findings_addressed JSON, the
# issue title and body filed by the NB sweep, the wiki raw source body and title,
# the wiki commit message, the accepted finding JSON) arrives as a file the caller
# wrote with its Write tool, never as an argument value.
#
# Usage:
#   bash fix-step.sh load-work-memory
#   bash fix-step.sh wiki-query-config
#   bash fix-step.sh wiki-capture --keywords K --changed-paths P
#   bash fix-step.sh parse-args --arguments A
#   bash fix-step.sh resolve-owner-repo
#   bash fix-step.sh pr-view --owner-repo O/R [--pr N]
#   bash fix-step.sh ensure-worktree --head-ref B
#   bash fix-step.sh resolve-review-source --pr N --review-file-path P --conversation-decision D
#                    --p1-scan-turns N --p1-scan-found B --target-comment-id C
#   bash fix-step.sh gate-receipt --review-source S --review-source-path P
#   bash fix-step.sh p3-raw-json --pr N
#   bash fix-step.sh fallback-abort --reason user_cancelled|user_file_path_invalid
#   bash fix-step.sh broad-retrieval --pr N --owner O --repo R --owner-repo O/R
#   bash fix-step.sh review-threads --pr N --owner O --repo R
#   bash fix-step.sh conversation-review-json --pr N --reviewed-commit-sha S
#   bash fix-step.sh explicit-review-json --review-source-path P --materialized-json M
#   bash fix-step.sh triage --triage-review-path P --triage-helper-source S
#   bash fix-step.sh triage-state --pr N --non-fatal-moved-count N --triage-review-path P
#   bash fix-step.sh cancel-cleanup --pr N --target-comment-id C
#   bash fix-step.sh cancelled-by-user
#   bash fix-step.sh fast-path-cleanup --pr N --target-comment-id C
#   bash fix-step.sh stagnation-replan --fix-plan-file F --fix-issue-file F
#   bash fix-step.sh scope-check --fix-plan-file F --fix-issue-file F
#   bash fix-step.sh impact-scan --symbol S
#   bash fix-step.sh reply-post --pr N --owner O --repo R --comment-id N --reply-body-file F
#   bash fix-step.sh scope-verify --fix-plan-file F --fix-issue-file F
#   bash fix-step.sh commit-guard
#   bash fix-step.sh skip-cycle-state --pr N --findings-addressed-file F
#                    --non-fatal-moved-count N --triage-review-path P
#   bash fix-step.sh cycle-base-sha
#   bash fix-step.sh show-changes
#   bash fix-step.sh number-ref-check --base-branch B --changed-files 'F ...'
#   bash fix-step.sh schema-drift-check
#   bash fix-step.sh root-cause-gate --status ok|missing
#   bash fix-step.sh cycle-state --pr N --fix-cycle-base-sha S --findings-addressed-file F
#                    --findings-fixed-count N --propagation-applied-count N
#                    --non-fatal-moved-count N --triage-review-path P
#   bash fix-step.sh push
#   bash fix-step.sh resolve-thread --thread-id T
#   bash fix-step.sh wm-update --pr-body-file F --history-file F
#                    --impl-status S --test-status S --doc-status S
#   bash fix-step.sh accept-count --pr N
#   bash fix-step.sh wiki-ingest-check
#   bash fix-step.sh output-handoff --pr N --result pushed|pushed-wm-stale|non-fatal-only|replied-only|sweep-done|error
#   bash fix-step.sh local-wm-sync --issue N   (空可: hook が branch から解決し、解決できなければ WARNING で続ける)
#   bash fix-step.sh nb-sweep-done-file --pr N
#   bash fix-step.sh override-cleanup --pr N
#   bash fix-step.sh target-comment-fetch --owner-repo O/R --pr N --target-comment-id C
#   bash fix-step.sh override-read --pr N
#   bash fix-step.sh accept-persist --pr N --finding-file F
#   bash fix-step.sh non-fatal-record --pr N --owner-repo O/R --triage-review-path P
#                    --non-fatal-moved-count N --review-cycle-id ID
#   bash fix-step.sh nb-sweep-collect --pr N
#   bash fix-step.sh nb-sweep-gate --pr N --base-branch B --owner-repo O/R
#   bash fix-step.sh nb-sweep-file-issue --pr N --issue-title-file F --issue-body-file F
#                    --record-ids JSON --projects-enabled true|false --project-number N
#                    --project-owner O
#   bash fix-step.sh nb-sweep-persist --pr N --owner-repo O/R
#   bash fix-step.sh nb-sweep-finish --pr N
#   bash fix-step.sh wiki-trigger --pr N --content-file F --title-file F
#   bash fix-step.sh wiki-trigger-result --content-write-failed 0|1 --trigger-exit N
#   bash fix-step.sh wiki-raw-commit --pr N --message-file F
#   bash fix-step.sh wiki-push-retry --pr N --attempt A
#
# Exit 2: unknown subcommand, unknown option, missing required argument, an
# argument value still carrying an unsubstituted `{placeholder}` or an
# unexpanded `$ARGUMENTS`, an enum value outside its set, or a non-numeric
# number option. The PR number becomes part of state file names, so a bad
# value must stop here, before any step touches a file.

plugin_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage_error() {
  echo "ERROR: fix-step.sh: $1" >&2
  exit 2
}

# 診断スニペットは control-char-neutralize.sh の canonical idiom
# （`head -N ... | neutralize_ctrl --keep-newline | sed ... >&2`）で出す。未定義のまま pipe すると
# 診断本文ごと消えるため不在時は素通しへ縮退させるが、縮退は必ず WARNING で告知する。
# shellcheck source=../hooks/control-char-neutralize.sh
source "$plugin_root"/hooks/control-char-neutralize.sh
if ! command -v neutralize_ctrl >/dev/null 2>&1; then
  echo "WARNING: control-char-neutralize.sh を読み込めませんでした。診断スニペットの制御文字が素通しします" >&2
  neutralize_ctrl() { cat; }
fi

# --- pr-view -------------------------------------------------------------------
step_pr_view() {
if [ -n "${pr_number}" ]; then
  gh pr view ${pr_number} -R ${owner_repo} --json number,title,state,isDraft,headRefName,baseRefName,url,body
else
  git branch --show-current
  # -R 指定時は selector が必須のため、現在のブランチ名を selector に渡す（従来どおり「現在ブランチの PR」を特定する）
  gh pr view "$(git branch --show-current)" -R ${owner_repo} --json number,title,state,isDraft,headRefName,baseRefName,url,body
fi
}

# --- fallback-abort ------------------------------------------------------------
step_fallback_abort() {
case "$reason" in
  user_cancelled)
    echo "ユーザーが Interactive Fallback で「中止」を選択しました" >&2
    echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=user_cancelled" >&2
    ;;
  user_file_path_invalid)
    # 「ファイルパス指定」の再実行でも invalid だった場合
    echo "エラー: 指定されたファイルパスでもレビュー結果を取得できませんでした" >&2
    echo "  /rite:pr-review を実行してローカル JSON を生成するか、有効な JSON path を確認してください" >&2
    echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=user_file_path_invalid" >&2
    ;;
esac
echo "[fix:error]"
exit 1
}

# --- cancelled-by-user ---------------------------------------------------------
step_cancelled_by_user() {
# cleanup + (E2E 時は handoff set) 後に exit
echo "[fix:cancelled-by-user]"
exit 0
}

# --- root-cause-gate -----------------------------------------------------------
step_root_cause_gate() {
# 判定は caller が ステップ 3.2 の commit body（本文禁止時は Step 1 の溢れ先）を読んで行い、結果だけを渡す
case "$status" in
  ok) echo "[CONTEXT] ROOT_CAUSE_GATE=ok" ;;
  missing) echo "[CONTEXT] ROOT_CAUSE_GATE=missing" ;;
esac
}

# --- output-handoff ------------------------------------------------------------
step_output_handoff() {
case "$result" in
  pushed|pushed-wm-stale)
    # 継続 ([fix:pushed] / [fix:pushed-wm-stale]: push 完了 OR 本 cycle accept 発生 & fatal フラグ無し) の場合 (継続 handoff):
    bash "$plugin_root"/hooks/flow-state.sh set \
      --phase "fix" \
      --active true \
      --next "rite:fix completed. Check recent result pattern in context: [fix:pushed]->caller の review-fix loop (/rite:pr-review を起動。範囲は 1.2.4 が cycle に応じて決定し、指摘の採否基準の緩和は禁止). [fix:pushed-wm-stale]->caller の review-fix loop (同上) with WM stale warning (work memory was not updated, manual intervention recommended). [fix:replied-only]->caller の iterate ステップ 5.S、成功後も replied-only で完了通知（mergeable へ昇格しない）. Do NOT stop." \
      --handoff "/rite:pr-review ${pr_number} --from-iterate" \
      --if-exists
    ;;
  non-fatal-only)
    # 非 fatal のみ ([fix:non-fatal-only]: row 4.5) の場合 (FINALIZE。5.S が先):
    bash "$plugin_root"/hooks/flow-state.sh set \
      --phase "fix" \
      --active true \
      --next "rite:fix completed. [fix:non-fatal-only]->caller の iterate ステップ 5.S NB digest sweep → PR 内推奨の修正 → 完了前確認 → ステップ 5 完了通知. Do NOT re-enter /rite:pr-review otherwise." \
      --handoff "FINALIZE:fix:non-fatal-only:${pr_number}" \
      --if-exists
    ;;
  replied-only)
    # 正常終了 ([fix:replied-only]: row 5。非 fatal 移送との混在も含む) の場合 (FINALIZE 終了通知 handoff):
    bash "$plugin_root"/hooks/flow-state.sh set \
      --phase "fix" \
      --active true \
      --next "rite:fix completed. Check recent result pattern in context: [fix:pushed]->caller の review-fix loop (/rite:pr-review を起動。範囲は 1.2.4 が cycle に応じて決定し、指摘の採否基準の緩和は禁止). [fix:pushed-wm-stale]->caller の review-fix loop (同上) with WM stale warning (work memory was not updated, manual intervention recommended). [fix:replied-only]->caller の iterate ステップ 5.S、成功後も replied-only で完了通知（mergeable へ昇格しない）. Do NOT stop." \
      --handoff "FINALIZE:fix:replied-only:${pr_number}" \
      --if-exists
    ;;
  sweep-done)
    # sweep 完了 ([fix:sweep-done]: NB_SWEEP=1 かつ (NB_SWEEP_RESULT=done または NB_SWEEP_DONE_FILE=1)) の場合 (FINALIZE。ステップ 1 に戻らない):
    bash "$plugin_root"/hooks/flow-state.sh set \
      --phase "fix" \
      --active true \
      --next "rite:fix completed. Check recent result pattern in context: [fix:sweep-done]->caller の iterate 5.S 後の PR 内推奨の修正（未着手の推奨があれば /rite:fix の後にステップ 1）→ 完了前確認 → ステップ 5 完了通知. Do NOT re-enter /rite:pr-review otherwise." \
      --handoff "FINALIZE:fix:sweep-done:${pr_number}" \
      --if-exists
    ;;
  error)
    # エラー ([fix:error]: fatal フラグ有り) の場合 (--handoff 行を省略 = handoff クリア):
    bash "$plugin_root"/hooks/flow-state.sh set \
      --phase "fix" \
      --active true \
      --next "rite:fix completed. Check recent result pattern in context: [fix:pushed]->caller の review-fix loop (/rite:pr-review を起動。範囲は 1.2.4 が cycle に応じて決定し、指摘の採否基準の緩和は禁止). [fix:pushed-wm-stale]->caller の review-fix loop (同上) with WM stale warning (work memory was not updated, manual intervention recommended). [fix:replied-only]->caller の iterate ステップ 5.S、成功後も replied-only で完了通知（mergeable へ昇格しない）. Do NOT stop." \
      --if-exists
    ;;
esac
}

# --- load-work-memory -----------------------------------------------------------
step_load_work_memory() {
# ブランチ名から Issue 番号を抽出
issue_number=$(git branch --show-current | grep -oE 'issue-[0-9]+' | grep -oE '[0-9]+')

# リポジトリ情報を取得（SSH host alias 対応: git-remote.sh 優先 + gh repo view fallback。
# canonical: references/gh-cli-patterns.md#ownerrepo-resolution-ssh-host-alias-safe）
owner_repo=$(bash "$plugin_root"/hooks/scripts/lib/git-remote.sh resolve-owner-repo 2>/dev/null) || owner_repo=""
owner=""; repo=""
[ -n "$owner_repo" ] && IFS=$'\t' read -r owner repo <<< "$owner_repo"
[ -n "$owner" ] && [ -n "$repo" ] || {
  owner=$(gh repo view --json owner --jq '.owner.login')
  repo=$(gh repo view --json name --jq '.name')
}
# 空の値を marker として渡すと、後続の gh 呼び出しが解決失敗とは別の形式エラーで止まる。
[ -n "$owner" ] && [ -n "$repo" ] || {
  echo "ERROR: fix-step.sh: owner/repo を解決できませんでした (git-remote.sh と gh repo view の両方が失敗)" >&2
  exit 1
}
echo "[CONTEXT] FIX_OWNER_REPO=$owner/$repo"

# 作業メモリを取得
gh api repos/${owner}/${repo}/issues/${issue_number}/comments \
  --jq '.[] | select(.body | contains("📜 rite 作業メモリ")) | .body'
}

# --- wiki-query-config ----------------------------------------------------------
step_wiki_query_config() {
# config は worktree 自身のもの、無ければ main checkout のものを読む
rite_config=$(bash "$plugin_root"/hooks/scripts/lib/rite-config-path.sh --or-devnull) || exit 1
wiki_section=$(sed -n '/^wiki:/,/^[^[:space:]#]/p' "$rite_config" 2>/dev/null) || wiki_section=""
wiki_enabled=""
if [[ -n "$wiki_section" ]]; then
  wiki_enabled=$(printf '%s\n' "$wiki_section" | awk '/^[[:space:]]+enabled:/ { print; exit }' \
    | sed 's/[[:space:]]#.*//' | sed 's/.*enabled:[[:space:]]*//' | tr -d '[:space:]"'"'"'' | tr '[:upper:]' '[:lower:]')
fi
auto_query=""
if [[ -n "$wiki_section" ]]; then
  auto_query=$(printf '%s\n' "$wiki_section" | awk '/^[[:space:]]+auto_query:/ { print; exit }' \
    | sed 's/[[:space:]]#.*//' | sed 's/.*auto_query:[[:space:]]*//' | tr -d '[:space:]"'"'"'' | tr '[:upper:]' '[:lower:]')
fi
case "$wiki_enabled" in false|no|0) wiki_enabled="false" ;; true|yes|1) wiki_enabled="true" ;; *) wiki_enabled="true" ;; esac  # opt-out default
case "$auto_query" in true|yes|1) auto_query="true" ;; *) auto_query="false" ;; esac
echo "wiki_enabled=$wiki_enabled auto_query=$auto_query"
}

# --- wiki-capture ---------------------------------------------------------------
step_wiki_capture() {
capture_args=(--keywords "${keywords}")
[ -n "${changed_paths}" ] && capture_args+=(--paths "${changed_paths}")
wiki_context=$(bash "$plugin_root"/hooks/scripts/wiki-apply-capture.sh "${capture_args[@]}") || {
  echo "ERROR: Wiki 検索に失敗したため、コミットへ進みません" >&2
  exit 1
}
printf '%s\n' "$wiki_context"
}

# --- parse-args -----------------------------------------------------------------
step_parse_args() {
# ステップ 1.0.1: flag トークンを $ARGUMENTS から pre-strip
# {review_file_path} と remaining_args (pr_number / pr_url / comment_url) を分離する
# rationale: skills/fix/references/design-rationale.md#review-file-flag-parsing

# --- Step 0: bash 4+ compat guard (C-3: inlined from references/bash-compat-guard.md) ---
# rationale: skills/fix/references/design-rationale.md#bash-compat-guard
if ! command -v mapfile >/dev/null 2>&1; then
  bash_version=$("$BASH" --version 2>/dev/null | head -1)
  echo "ERROR: bash 4.0+ が必要ですが、現在のシェルは mapfile builtin を持っていません" >&2
  echo "  検出: $bash_version" >&2
  echo "  対処: macOS では brew install bash で 4+ をインストールし、PATH の先頭に追加してください" >&2
  echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=bash_version_incompatible" >&2
  echo "[fix:error]"
  exit 1
fi

original_args="$arguments"
review_file_path="__RITE_UNSET__"  # explicit set (undefined 参照防止、衝突安全な sentinel)
remaining_args="$original_args"
# flag style (equals / space) を別変数に保持してエラーメッセージで区別する
review_file_flag_style="none"

# Pattern 1: --review-file=<path> (GNU-long-option style)
# `[^[:space:]]*` (0+) は空値検出のため、境界 `([[:space:]]|$)` は prefix 誤検出防止のため変更禁止
# rationale: skills/fix/references/design-rationale.md#review-file-flag-parsing
if [[ "$remaining_args" =~ (^|[[:space:]])--review-file=([^[:space:]]*)([[:space:]]|$) ]]; then
  review_file_path="${BASH_REMATCH[2]}"
  review_file_flag_style="equals"
  remaining_args=$(printf '%s' "$remaining_args" | sed -E 's/(^|[[:space:]])--review-file=[^[:space:]]*//')
# Pattern 2: --review-file <path> (POSIX style with space/tab)
# Pattern 1 と対称に `[^[:space:]]*` (0+) + 末尾境界。変更禁止 (同上 rationale 参照)
elif [[ "$remaining_args" =~ (^|[[:space:]])--review-file([[:space:]]+([^[:space:]]*))?([[:space:]]|$) ]]; then
  review_file_path="${BASH_REMATCH[3]:-}"
  review_file_flag_style="space"
  remaining_args=$(printf '%s' "$remaining_args" | sed -E 's/(^|[[:space:]])--review-file([[:space:]]+[^[:space:]]*)?//')
fi

# remaining_args の前後 whitespace を trim
remaining_args=$(printf '%s' "$remaining_args" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')

# --nb-sweep (値なし)。iterate 5.S 専用。通常ループは非 set のまま。
nb_sweep=0
if [[ "$remaining_args" =~ (^|[[:space:]])--nb-sweep([[:space:]]|$) ]]; then
  nb_sweep=1
  remaining_args=$(printf '%s' "$remaining_args" | sed -E 's/(^|[[:space:]])--nb-sweep([[:space:]]|$)/\1\2/')
  remaining_args=$(printf '%s' "$remaining_args" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
fi

# --review-file=<空> を明示エラー化 (fail-fast、ステップ 5.1 評価順 1 で [fix:error] へ昇格)
# flag_style == "none" のときは sentinel `__RITE_UNSET__` のままなのでこの分岐に来ない
if [ "$review_file_flag_style" != "none" ] && [ "$review_file_path" = "" ]; then
  case "$review_file_flag_style" in
    equals)
      echo "エラー: --review-file= に値がありません (style: equals — \`--review-file=<path>\` の \`=\` の右側にパスを指定してください)" >&2
      ;;
    space)
      echo "エラー: --review-file の後にパスがありません (style: space — \`--review-file <path>\` のように空白で区切ってパスを指定してください)" >&2
      ;;
  esac
  echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=review_file_path_empty_value; flag_style=$review_file_flag_style" >&2
  echo "[fix:error]"
  exit 1
fi

# [CONTEXT] emit は本ブロックの成功パス値も含め stderr に統一する (引数解析系の規約、ステップ 1.2.0 Priority 0/2/3・6.1.a・5.1 retained flags と統一。canonical: references/common-error-handling.md#context-emit-stdout-stderr-convention-canonical)
echo "[CONTEXT] REVIEW_FILE_PATH=$review_file_path" >&2
echo "[CONTEXT] NB_SWEEP=$nb_sweep" >&2
echo "[CONTEXT] REMAINING_ARGS=$remaining_args" >&2
}

# --- resolve-owner-repo ---------------------------------------------------------
step_resolve_owner_repo() {
# ステップ 0.2 と同一パターン（スタンドアロン実行時のみ使用。e2e フローでは ステップ 0.2 の値を再利用）
owner_repo=$(bash "$plugin_root"/hooks/scripts/lib/git-remote.sh resolve-owner-repo 2>/dev/null) || owner_repo=""
owner=""; repo=""
[ -n "$owner_repo" ] && IFS=$'\t' read -r owner repo <<< "$owner_repo"
[ -n "$owner" ] && [ -n "$repo" ] || {
  owner=$(gh repo view --json owner --jq '.owner.login')
  repo=$(gh repo view --json name --jq '.name')
}
# 空の値を marker として渡すと、後続の gh 呼び出しが解決失敗とは別の形式エラーで止まる。
[ -n "$owner" ] && [ -n "$repo" ] || {
  echo "ERROR: fix-step.sh: owner/repo を解決できませんでした (git-remote.sh と gh repo view の両方が失敗)" >&2
  exit 1
}
echo "[CONTEXT] FIX_OWNER_REPO=$owner/$repo"
}

# --- ensure-worktree ------------------------------------------------------------
step_ensure_worktree() {
issue_number=$(printf '%s' "${head_ref}" | grep -oE 'issue-[0-9]+' | grep -oE '[0-9]+')
if [ -n "$issue_number" ]; then
  claim_state=$(bash "$plugin_root"/hooks/issue-claim.sh check --issue "$issue_number") || exit $?
  if [ "$claim_state" != own ]; then
    bash "$plugin_root"/hooks/issue-claim.sh claim --issue "$issue_number" || exit $?
  fi
  bash "$plugin_root"/hooks/scripts/lib/worktree-git.sh ensure-session-worktree --issue "$issue_number" --branch "${head_ref}"
else
  # head_ref が issue ブランチでない（session worktree の対象外）→ 従来どおり単一ツリーで続行
  echo "[CONTEXT] WT_ENSURE=skip (head_ref が issue ブランチでないため worktree 対象外: ${head_ref})"
fi
}

# --- resolve-review-source ------------------------------------------------------
step_resolve_review_source() {
# ステップ 1.2.0 Hybrid Review Source Resolution — scripts/review-source-resolve.sh へ委譲
# 引数の意味は SKILL.md ステップ 1.2.0 の Selection logic 節が定める。
# caller guard: helper の非ゼロ exit で `[fix:error]` を stdout 出力する (helper 自身は [fix:error] を出さない = stdout 分離)。
# rationale: skills/fix/references/design-rationale.md#review-source-resolution
bash "$plugin_root"/scripts/review-source-resolve.sh \
  --pr-number "${pr_number}" \
  --review-file-path "${review_file_path}" \
  --conversation-decision "${conversation_decision}" \
  --p1-scan-turns "${p1_scan_turns}" \
  --p1-scan-found "${p1_scan_found}" \
  --target-comment-id "${target_comment_id}" || {
  echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=review_source_resolve_failed" >&2
  echo "[fix:error]"
  exit 1
}
}

# --- gate-receipt ---------------------------------------------------------------
step_gate_receipt() {
case "$review_source" in
  explicit_file|local_file)
    if ! jq -e '
      (.measured_gate | type) == "object"
      and (.measured_gate.commit_sha | type) == "string"
      and (.measured_gate.commit_sha | length) > 0
      and (.measured_gate.applied_at | type) == "string"
      and (.measured_gate.applied_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?Z$"))
      and ([.measured_gate.blocking, .measured_gate.demoted, .measured_gate.anchor_undetermined]
           | all(type == "number" and . >= 0 and . == floor))
      and .measured_gate.commit_sha == .commit_sha
    ' "$review_source_path" >/dev/null 2>&1; then
      echo "ERROR: review-result JSON に実測必須ゲートの適用記録が無いか、commit_sha と一致しません。/rite:pr-review を再実行してください" >&2
      echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=gate_not_applied" >&2
      echo "[fix:error] reason=gate_not_applied"
      exit 1
    fi
    ;;
esac
}

# --- p3-raw-json ----------------------------------------------------------------
step_p3_raw_json() {
# pr_review_comment_body を tempfile から読み出す (ステップ 1.2 Broad Retrieval bash block が
# ${TMPDIR:-/tmp}/rite-fix-pr-comment-${pr_number}.txt に書き出している前提)。
# rationale: skills/fix/references/design-rationale.md#pr-comment-raw-json-extraction
pr_comment_body_file="${TMPDIR:-/tmp}/rite-fix-pr-comment-${pr_number}.txt"
_rite_fix_p3_cleanup() {
  rm -f "${pr_comment_body_file:-}"
}
trap 'rc=$?; _rite_fix_p3_cleanup; exit $rc' EXIT
trap '_rite_fix_p3_cleanup; exit 130' INT
trap '_rite_fix_p3_cleanup; exit 143' TERM
trap '_rite_fix_p3_cleanup; exit 129' HUP
if [ -f "$pr_comment_body_file" ]; then
  if [ ! -s "$pr_comment_body_file" ]; then
    # tempfile は存在するが空 = Broad Retrieval が書き出そうとしたが本文取得が空だった
    # (rite review コメント本文の jq 抽出は成功したが本文 0 byte の異常経路)
    echo "ERROR: pr_review_comment_body tempfile が空です: $pr_comment_body_file" >&2
    echo "  原因候補:" >&2
    echo "    - Broad Retrieval bash block が異常終了した (gh api の 401/403/404/timeout/5xx 等)" >&2
    echo "    - PR コメント本文 jq 抽出は成功したが本文が完全に空だった" >&2
    echo "    - 並列 fix セッションが同一 PR に実行され、他セッションが tempfile を truncate した" >&2
    echo "      (low-probability。同一 pr_number で複数 terminal から /rite:fix を実行したケース)" >&2
    echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=comment_body_tempfile_empty" >&2
    exit 1
  fi
  # cat の exit code を if-else で独立 capture する (IO エラーの silent 空文字列化を防ぐ)
  cat_err=$(mktemp "${TMPDIR:-/tmp}/rite-fix-cat-err-XXXXXX" 2>/dev/null) || cat_err=""
  if pr_review_comment_body=$(cat "$pr_comment_body_file" 2>"${cat_err:-/dev/null}"); then
    :
  else
    cat_pr_comment_body_rc=$?
    echo "WARNING: pr_comment_body_file の cat が失敗しました (rc=$cat_pr_comment_body_rc): $pr_comment_body_file" >&2
    [ -n "$cat_err" ] && [ -s "$cat_err" ] && head -3 "$cat_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
    echo "  原因候補: permission 変更 / NFS timeout / TOCTOU truncate" >&2
    echo "  legacy Markdown parser に fallthrough します" >&2
    echo "[CONTEXT] REVIEW_SOURCE_PARSE_FAILED=1; reason=pr_comment_tempfile_read_io_error; rc=$cat_pr_comment_body_rc" >&2
    pr_review_comment_body=""
  fi
  [ -n "$cat_err" ] && rm -f "$cat_err"
else
  # tempfile 不在の 2 ケース (legitimate な未作成 / Broad Retrieval skip の前提条件違反) を
  # [INFO] emit で可視化する (rationale: skills/fix/references/design-rationale.md#pr-comment-raw-json-extraction)
  echo "[INFO] pr_comment_body_file 不在 → legacy Markdown parser に fallthrough ($pr_comment_body_file)" >&2
  echo "       legitimate な経路: 新規 PR / /rite:pr-review 未実行 / コメント削除済み" >&2
  echo "       もし /rite:pr-review 実行直後にこのメッセージが出た場合、Claude が Priority 3 進入前に" >&2
  echo "       ステップ 1.2 Broad Retrieval bash block を呼び出し忘れた可能性があります (前提条件違反)" >&2
  echo "[CONTEXT] BROAD_RETRIEVAL_SKIPPED_OR_NO_COMMENT=1" >&2
  pr_review_comment_body=""
fi

# Raw JSON section の抽出は helper (実ファイル) に委譲する。skill 本文の fenced bash に awk を
# 書くと Skill loader が位置パラメータを起動引数へ展開して行バッファが壊れる
# (静的検出: hooks/scripts/dollar-zero-check.sh)。どの section を採るかの規則は helper header 参照。
# here-string `<<<` は printf | awk の SIGPIPE 回避 (bash-defensive-patterns.md Pattern 5)。
# rationale: skills/fix/references/design-rationale.md#pr-comment-raw-json-extraction
raw_json=$(bash "$plugin_root"/hooks/scripts/review-raw-json-extract.sh <<< "$pr_review_comment_body")
# 変数名は helper の rc であることを表す。reason 文字列 pr_comment_raw_json_awk_failed は
# reason 表と Eval-order enumeration に登録済の documented set のため改名しない。
raw_json_extract_rc=$?
# exit code を明示検査 (空出力と「Raw JSON section なし」の区別を保つ)
if [ "$raw_json_extract_rc" -ne 0 ]; then
  echo "WARNING: PR コメントからの Raw JSON 抽出 helper が失敗 (rc=$raw_json_extract_rc)" >&2
  echo "  原因候補: helper 解決不能 (rc=127) / awk バイナリ異常 / OOM (行バッファが大きすぎ) / SIGPIPE" >&2
  echo "[CONTEXT] REVIEW_SOURCE_PARSE_FAILED=1; reason=pr_comment_raw_json_awk_failed; rc=$raw_json_extract_rc" >&2
  raw_json=""
fi

# raw_json="" だけが legitimate な legacy fallthrough。それ以外の壊れた新形式 JSON は
# 検証失敗を [fix:error] で停止する。新形式の metadata を legacy 表で補完しない。
if [ -z "$raw_json" ]; then
  # legitimate legacy format: PR コメントに Raw JSON section なし → 旧 Markdown table parser へ
  :
elif ! printf '%s' "$raw_json" | jq empty 2>/dev/null; then
  echo "WARNING: PR コメント内の Raw JSON が syntactically invalid です。[fix:error] で停止します。" >&2
  echo "  対処: PR コメントを再投稿するか、ローカル JSON ファイルを使用してください" >&2
  echo "[CONTEXT] REVIEW_SOURCE_PARSE_FAILED=1; reason=pr_comment_raw_json_parse_failure" >&2
  echo "[fix:error] reason=pr_comment_raw_json_parse_failure"
  exit 1
elif ! printf '%s' "$raw_json" | jq -e '
  (.schema_version | type == "string" and length > 0)
  and (.pr_number | type == "number")
  and (.findings | type == "array")
' >/dev/null 2>&1; then
  # 明示型ガード (jq truthiness は false/null のみ falsy — 空文字列や型違反を silent pass させない)
  echo "WARNING: PR コメント内の Raw JSON が必須フィールドを欠いています。[fix:error] で停止します。" >&2
  echo "[CONTEXT] REVIEW_SOURCE_PARSE_FAILED=1; reason=pr_comment_schema_required_fields_missing" >&2
  echo "[fix:error] reason=pr_comment_schema_required_fields_missing"
  exit 1
elif ! printf '%s' "$raw_json" | jq -e '
  (.measured_gate | type) == "object"
  and (.measured_gate.commit_sha | type) == "string"
  and (.measured_gate.commit_sha | length) > 0
  and (.measured_gate.applied_at | type) == "string"
  and (.measured_gate.applied_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?Z$"))
  and ([.measured_gate.blocking, .measured_gate.demoted, .measured_gate.anchor_undetermined]
       | all(type == "number" and . >= 0 and . == floor))
  and .measured_gate.commit_sha == .commit_sha
' >/dev/null 2>&1; then
  echo "ERROR: PR コメント内 Raw JSON に実測必須ゲートの適用記録が無いか、commit_sha と一致しません。/rite:pr-review を再実行してください" >&2
  echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=gate_not_applied" >&2
  echo "[fix:error] reason=gate_not_applied"
  exit 1
elif ! printf '%s' "$raw_json" | jq -e '
  (.overall_assessment != "mergeable")
  or (all(.findings[]?; (.severity != "CRITICAL" and .severity != "HIGH") or (.status != "open")))
' >/dev/null 2>&1; then
  # Cross-field invariant (review-result-schema.md): mergeable × open CRITICAL/HIGH は禁止。
  # 実測必須ゲートによる `measured == false` 除外は本経路に入れない — 同一 invariant は P0/P2
  # (`scripts/review-source-resolve.sh`) と SoT (review-result-schema.md invariant #2) にも実装があり、
  # P3 だけ緩めると同一 JSON が経路により受理/拒否に割れる。write 側が `verification` を出力する
  # 前提は で満たされたが、3 経路 + SoT の同時更新は依然として不要 — gated な
  # `measured == false` は `non_blocking_findings[]` へ移送されるため `findings[]` に残る非実測
  # finding は `scope == "nit-noted"` のみ。CRITICAL/HIGH × nit-noted は invariant #4 が禁じる
  # 組合せなので、CRITICAL/HIGH を見る本述語の判定対象に非実測 finding は現れない。
  echo "WARNING: PR コメント内の Raw JSON が cross-field invariant に違反しています (mergeable だが open な CRITICAL/HIGH finding あり)。[fix:error] で停止します。" >&2
  echo "[CONTEXT] REVIEW_SOURCE_CROSS_FIELD_INVARIANT_VIOLATED=1; reason=pr_comment_cross_field_invariant_violated" >&2
  echo "[fix:error] reason=pr_comment_cross_field_invariant_violated"
  exit 1
elif ! printf '%s' "$raw_json" | jq -e '
  [.findings[]? | select((.severity == "CRITICAL" or .severity == "HIGH") and .scope == "nit-noted")] | length == 0
' >/dev/null 2>&1; then
  # Cross-field invariant #4: severity ∈ {CRITICAL, HIGH} × scope == "nit-noted" は禁止
  # (1.0/1.0.0 JSON では .scope 欠落のため規約的に発火しない — 後方互換)
  violation_count=$(printf '%s' "$raw_json" | jq '[.findings[]? | select((.severity == "CRITICAL" or .severity == "HIGH") and .scope == "nit-noted")] | length' 2>/dev/null || echo "?")
  echo "WARNING: PR コメント内の Raw JSON が cross-field invariant #4 に違反しています (severity ∈ {CRITICAL, HIGH} で scope=\"nit-noted\" の finding が $violation_count 件)。[fix:error] で停止します。" >&2
  echo "[CONTEXT] REVIEW_SOURCE_CROSS_FIELD_INVARIANT_VIOLATED=1; reason=pr_comment_critical_high_scope_nit_noted; count=$violation_count" >&2
  echo "[fix:error] reason=pr_comment_critical_high_scope_nit_noted"
  exit 1
elif ! printf '%s' "$raw_json" | jq -e '.overall_assessment == "mergeable" or .overall_assessment == "fix-needed"' >/dev/null 2>&1; then
  # overall_assessment enum validation (review-result-schema.md)
  oa_val=$(printf '%s' "$raw_json" | jq -r '.overall_assessment // "(null)"' 2>/dev/null)
  echo "WARNING: PR コメント内の Raw JSON の overall_assessment が未知値です: $oa_val (受理値: mergeable / fix-needed)。[fix:error] で停止します。" >&2
  echo "[CONTEXT] REVIEW_SOURCE_ENUM_UNKNOWN=1; reason=overall_assessment_unknown_value; value=$oa_val" >&2
  echo "[fix:error] reason=overall_assessment_unknown_value"
  exit 1
else
  # canonical jq validation (see common-error-handling.md#jq-required-fields-snippet-canonical)
  # exit code 捕捉は `if cmd; then :; else rc=$?; fi` 形式 (「!」否定は $? を反転するため使用禁止)
  if schema_version=$(printf '%s' "$raw_json" | jq -r '.schema_version // "unknown"' 2>/dev/null); then
    : # jq 成功
  else
    jq_sv_rc=$?
    echo "WARNING: PR コメント内 Raw JSON の schema_version 抽出で jq が失敗 (rc=$jq_sv_rc)" >&2
    echo "  原因候補: jq バイナリ異常 / OOM / pipe write error" >&2
    echo "[CONTEXT] REVIEW_SOURCE_PARSE_FAILED=1; reason=pr_comment_schema_version_jq_failed; rc=$jq_sv_rc" >&2
    schema_version="unknown"
  fi
  case "$schema_version" in
    "1.0.0"|"1.0"|"1.1.0")
      # accept list 3 値は Priority 0/2/3 + hooks/scripts/review-trend-divergence.sh の 4 sites で完全同期 (review-result-schema.md Schema Version SoT 契約)
      # commit_sha stale detection: mismatch は WARNING のみで continue
      # rationale: skills/fix/references/design-rationale.md#schema-normalization-mirror
      json_commit_sha_err=$(mktemp "${TMPDIR:-/tmp}/rite-fix-p3-commit-sha-err-XXXXXX" 2>/dev/null) || json_commit_sha_err=""
      if json_commit_sha=$(printf '%s' "$raw_json" | jq -r '.commit_sha // empty' 2>"${json_commit_sha_err:-/dev/null}"); then
        :
      else
        jq_p3_commit_sha_rc=$?
        echo "WARNING: PR コメント内 Raw JSON の commit_sha 抽出で jq が失敗 (rc=$jq_p3_commit_sha_rc)" >&2
        [ -n "$json_commit_sha_err" ] && [ -s "$json_commit_sha_err" ] && head -3 "$json_commit_sha_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
        echo "[CONTEXT] REVIEW_SOURCE_STALE_CHECK_FAILED=1; reason=jq_error_on_commit_sha; priority=3" >&2
        json_commit_sha=""
      fi
      [ -n "$json_commit_sha_err" ] && rm -f "$json_commit_sha_err"
      if ! head_sha=$(git rev-parse HEAD 2>/dev/null); then
        echo "WARNING: git rev-parse HEAD に失敗しました。commit_sha stale detection を skip します" >&2
        echo "[CONTEXT] REVIEW_SOURCE_STALE_CHECK_FAILED=1; reason=git_rev_parse_head_failed" >&2
        head_sha=""
      fi
      if [ -n "$json_commit_sha" ] && [ -n "$head_sha" ] && [ "$json_commit_sha" != "$head_sha" ]; then
        echo "⚠️ WARNING: PR コメント内 Raw JSON の commit_sha ($json_commit_sha) が現 HEAD ($head_sha) と不一致です (stale)" >&2
        echo "  本 Raw JSON は古い commit に対して生成されました。既修正項目を再指摘する可能性があります。" >&2
        echo "  注意: Priority 2 (ローカルファイル) も stale だった場合、本 Priority 3 が stale のまま消費されます。" >&2
        echo "  対処: /rite:pr-review を再実行して PR コメントを更新してください。" >&2
        echo "[CONTEXT] REVIEW_SOURCE_STALE=1; reason=pr_comment_commit_sha_mismatch; json_sha=$json_commit_sha; head_sha=$head_sha" >&2
      fi
      # Raw JSON の解析が成功したら全経路共通のステップ 1.2.2 へ。
      # raw_json を永続 JSON に保存し、helper による triage 後に reload する。
      # triage 失敗は [fix:error]。legacy Markdown parser への fallback 禁止。
      ;;
    *)
      echo "WARNING: PR コメント内の Raw JSON schema_version が未知: $schema_version" >&2
      echo "  [fix:error] で停止します。" >&2
      echo "[CONTEXT] REVIEW_SOURCE_SCHEMA_UNKNOWN=1; reason=pr_comment_schema_version_unknown" >&2
  echo "[fix:error] reason=pr_comment_schema_version_unknown"
  exit 1
      ;;
  esac
fi
}

# --- broad-retrieval ------------------------------------------------------------
step_broad_retrieval() {
# confidence_override tempfile の orphan 防止: Fast Path 経路と同様、ステップ 1.2 進入時に
# **無条件 truncate** (specific path 必須 — wildcard glob は絶対に使わない)
: > "${TMPDIR:-/tmp}/rite-fix-confidence-override-${pr_number}.txt" 2>/dev/null || \
  echo "WARNING: ${TMPDIR:-/tmp}/rite-fix-confidence-override-${pr_number}.txt の truncate に失敗しました (read-only / permission denied?)" >&2

# Broad Retrieval 経路の exit code check (Fast Path と同じ fail-fast + stderr 退避 + canonical 4 行 trap)
gh_api_err=""
_rite_fix_broad_retrieval_cleanup() {
  rm -f "${gh_api_err:-}"
}
trap 'rc=$?; _rite_fix_broad_retrieval_cleanup; exit $rc' EXIT
trap '_rite_fix_broad_retrieval_cleanup; exit 130' INT
trap '_rite_fix_broad_retrieval_cleanup; exit 143' TERM
trap '_rite_fix_broad_retrieval_cleanup; exit 129' HUP

gh_api_err=$(mktemp "${TMPDIR:-/tmp}/rite-fix-broad-retrieval-err-XXXXXX") || {
  echo "エラー: Broad Retrieval stderr 一時ファイルの作成に失敗しました" >&2
  echo "[CONTEXT] COMMENT_FETCH_FAILED=1; reason=mktemp_failed_gh_api_err" >&2
  exit 1
}

# レビューコメント（PR レビューに紐づくコメント）
# node_id はスレッド解決時の GraphQL mutation で必要
if ! gh api repos/${owner}/${repo}/pulls/${pr_number}/comments --jq '.[] | {id, node_id, path, line, original_line, body, user: .user.login, created_at, in_reply_to_id, pull_request_review_id}' 2>"$gh_api_err"; then
  echo "エラー: レビューコメントの取得に失敗しました (gh api pulls/${pr_number}/comments)" >&2
  echo "詳細 (gh api stderr 先頭 5 行):" >&2
  head -5 "$gh_api_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
  echo "[CONTEXT] COMMENT_FETCH_FAILED=1; reason=gh_api_comments_fetch_failed" >&2
  exit 1
fi

# PR レビュー自体のコメント
if ! gh api repos/${owner}/${repo}/pulls/${pr_number}/reviews --jq '.[] | {id, node_id, state, body, user: .user.login, submitted_at}' 2>"$gh_api_err"; then
  echo "エラー: PR レビューの取得に失敗しました (gh api pulls/${pr_number}/reviews)" >&2
  echo "詳細 (gh api stderr 先頭 5 行):" >&2
  head -5 "$gh_api_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
  echo "[CONTEXT] COMMENT_FETCH_FAILED=1; reason=gh_api_comments_fetch_failed" >&2
  exit 1
fi

# 通常のコメント（PR コメント欄）を一括取得して保存（ステップ 1.2.1 で再利用）
if ! pr_comments=$(gh pr view ${pr_number} -R ${owner_repo} --json comments --jq '.comments' 2>"$gh_api_err"); then
  echo "エラー: PR コメントの取得に失敗しました (gh pr view --json comments)" >&2
  echo "詳細 (gh pr view stderr 先頭 5 行):" >&2
  head -5 "$gh_api_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
  echo "[CONTEXT] COMMENT_FETCH_FAILED=1; reason=gh_api_comments_fetch_failed" >&2
  exit 1
fi
echo "$pr_comments" | jq '.[] | {id: .id, body: .body, author: .author.login, createdAt: .createdAt}'

# ステップ 1.2.1: 取得済みの pr_comments から rite レビュー結果を検索する（API 呼び出しなし）。
# pr_comments はこの呼び出しのシェル変数なので、同じ呼び出しの中で検索する。
echo "$pr_comments" | jq '[.[] | select(.body | contains("## 📜 rite レビュー結果"))] | sort_by(.createdAt) | last | {id: .id, body: .body, author: .author.login, createdAt: .createdAt}'

# pr_review_comment_body は tempfile 経由で Priority 3 block へ hand-off する (specific path 必須)。
# 書き出し失敗時は WARNING で continue (tempfile が無ければ Priority 3 が fail-fast する)。
# rationale: skills/fix/references/design-rationale.md#pr-comment-raw-json-extraction
pr_comment_body_file="${TMPDIR:-/tmp}/rite-fix-pr-comment-${pr_number}.txt"
jq_broad_err=$(mktemp "${TMPDIR:-/tmp}/rite-fix-broad-jq-err-XXXXXX" 2>/dev/null) || jq_broad_err=""
if rite_review_body=$(printf '%s' "$pr_comments" | jq -r '
  [.[] | select(.body | contains("## 📜 rite レビュー結果"))]
  | sort_by(.createdAt) | last | .body // empty
' 2>"${jq_broad_err:-/dev/null}"); then
  if [ -n "$rite_review_body" ]; then
    if ! printf '%s' "$rite_review_body" > "$pr_comment_body_file"; then
      echo "WARNING: pr_review_comment_body tempfile への書き出しに失敗: $pr_comment_body_file" >&2
      echo "  対処: /tmp の容量 / permission を確認してください" >&2
      echo "  影響: ステップ 1.2.0 Priority 3 が tempfile を読めず fail-fast する可能性があります" >&2
    else
      echo "[CONTEXT] PR_REVIEW_COMMENT_BODY_FILE=$pr_comment_body_file" >&2
    fi
  else
    # rite review result コメントが PR に存在しない (legitimate な legacy / 初回経路)
    # tempfile を作成しないことで、ステップ 1.2.0 Priority 3 は別のソース判定経路を辿る
    :
  fi
else
  jq_extract_rc=$?
  echo "WARNING: pr_comments から rite review コメント抽出 jq が失敗しました (rc=$jq_extract_rc)" >&2
  if [ -n "$jq_broad_err" ] && [ -s "$jq_broad_err" ]; then
    echo "  jq stderr (先頭 3 行):" >&2
    head -3 "$jq_broad_err" | neutralize_ctrl --keep-newline | sed 's/^/    /' >&2
  fi
  echo "  原因候補: jq バイナリ異常 / OOM / GitHub API レスポンスの JSON 破損" >&2
  echo "  影響: ステップ 1.2.0 Priority 3 が tempfile 不在として BROAD_RETRIEVAL_SKIPPED_OR_NO_COMMENT に routing される" >&2
  echo "[CONTEXT] REVIEW_SOURCE_PARSE_FAILED=1; reason=broad_retrieval_jq_extraction_failed; rc=$jq_extract_rc" >&2
fi
[ -n "$jq_broad_err" ] && rm -f "$jq_broad_err"
}

# --- review-threads -------------------------------------------------------------
step_review_threads() {
# スレッド情報と解決状態を取得（GraphQL）
# 注: first: 100 の制限があるため、100件を超える大規模 PR では取得漏れの可能性あり
gh_api_err=""
_rite_fix_broad_graphql_cleanup() {
  rm -f "${gh_api_err:-}"
}
trap 'rc=$?; _rite_fix_broad_graphql_cleanup; exit $rc' EXIT
trap '_rite_fix_broad_graphql_cleanup; exit 130' INT
trap '_rite_fix_broad_graphql_cleanup; exit 143' TERM
trap '_rite_fix_broad_graphql_cleanup; exit 129' HUP

gh_api_err=$(mktemp "${TMPDIR:-/tmp}/rite-fix-broad-retrieval-err-XXXXXX") || {
  echo "エラー: Broad Retrieval stderr 一時ファイルの作成に失敗しました" >&2
  exit 1
}

if ! gh api graphql -f query='
query($owner: String!, $repo: String!, $pr: Int!) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $pr) {
      reviewThreads(first: 100) {
        nodes {
          id
          isResolved
          comments(first: 100) {
            nodes {
              id
              body
              author { login }
              path
              line
            }
          }
        }
      }
    }
  }
}' -f owner="${owner}" -f repo="${repo}" -F pr=${pr_number} 2>"$gh_api_err"; then
  echo "エラー: reviewThreads の取得に失敗しました (gh api graphql)" >&2
  echo "詳細 (gh api stderr 先頭 5 行):" >&2
  head -5 "$gh_api_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
  echo "[CONTEXT] COMMENT_FETCH_FAILED=1; reason=gh_api_comments_fetch_failed" >&2
  exit 1
fi
}

# --- conversation-review-json ---------------------------------------------------
step_conversation_review_json() {
# fix-conversation-review-json
materialized=""
source_name=""
# 表の出所がレビューした commit が HEAD と違えば、HEAD の保存済み JSON は別レビューなので読まない。
if [ "${reviewed_commit_sha}" = "$(git rev-parse HEAD)" ]; then
  # helper の本文と marker は pr-review 8.0.4 向けなので、見つかった・該当なしのどちらでもないときだけ全文を表示する。
  verify_rc=0
  verify_out=$(bash "$plugin_root"/hooks/scripts/review-save-json-verify.sh \
    --pr "${pr_number}" --commit-sha "${reviewed_commit_sha}" 2>&1) || verify_rc=$?
  source_name=$(printf '%s\n' "$verify_out" | sed -n 's/^\[CONTEXT\] REVIEW_SAVE_JSON_OK=1; pr=[0-9]*; result_json=//p' | tail -1)
  if [ -z "$source_name" ] \
    && ! printf '%s\n' "$verify_out" | grep -q '^\[CONTEXT\] REVIEW_SAVE_GATE_FAILED=1; reason=save_result_json_absent;'; then
    printf '%s\n' "$verify_out" >&2
    echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=conversation_json_verify_failed; rc=$verify_rc" >&2
    echo "[fix:error] reason=conversation_json_verify_failed"
    exit 1
  fi
fi
if [ -n "$source_name" ]; then
  if ! state_root=$(bash "$plugin_root"/hooks/state-path-resolve.sh) || [ -z "$state_root" ]; then
    echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=conversation_json_resolve_failed" >&2
    echo "[fix:error] reason=conversation_json_resolve_failed"
    exit 1
  fi
  materialized="$state_root/.rite/review-results/$source_name"
  # 完了記録と修正計画の検査は同じ review_context の最古のファイルを receipt として読む。
  # fix が作った別名ファイルが最新にあると、それを triage しても receipt は未 triage のまま残る。
  # 読めないファイルは次の triage helper が止める。
  if [ "$(jq -r '.producer // ""' "$materialized")" = "fix" ]; then
    echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=conversation_json_not_original" >&2
    echo "[fix:error] reason=conversation_json_not_original"
    exit 1
  fi
fi
echo "[CONTEXT] FIX_MATERIALIZED_JSON=$materialized" >&2
}

# --- explicit-review-json -------------------------------------------------------
step_explicit_review_json() {
# fix-explicit-review-json
compare_rc=0
jq -n -e --slurpfile given "${review_source_path}" --slurpfile saved "${materialized_json}" \
  '[$given[0], $saved[0]] | map({findings, non_blocking_findings, measured_gate}) | .[0] == .[1]' \
  >/dev/null || compare_rc=$?
case "$compare_rc" in
  0) ;;
  1)
    echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=explicit_json_differs_from_saved" >&2
    echo "[fix:error] reason=explicit_json_differs_from_saved"
    exit 1
    ;;
  *)
    echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=explicit_json_compare_failed; rc=$compare_rc" >&2
    echo "[fix:error] reason=explicit_json_compare_failed"
    exit 1
    ;;
esac
}

# --- triage ---------------------------------------------------------------------
step_triage() {
if triage_maps=$(bash "$plugin_root"/scripts/review-findings-maps.sh \
  --review-source "${triage_helper_source}" \
  --review-source-path "$triage_review_path"); then
  :
else
  printf '%s\n' "$triage_maps"
  echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=fatal_triage_failed" >&2
  echo "[fix:error] reason=fatal_triage_failed"
  exit 1
fi
# 永続化された結果を reload。会話・raw_json の旧 findings を後続へ渡さない。
if ! triaged_review=$(jq -c '.' "$triage_review_path"); then
  echo "[fix:error] reason=triage_reload_failed"
  exit 1
fi
printf '%s\n' "$triage_maps"
echo "[CONTEXT] FIX_TRIAGE_REVIEW_PATH=$triage_review_path" >&2
}

# --- triage-state ---------------------------------------------------------------
step_triage_state() {
triage_state_root=$(bash "$plugin_root"/hooks/state-path-resolve.sh) || {
  echo "[fix:error] reason=triage_state_root_failed"
  exit 1
}
triage_state_dir="$triage_state_root/.rite/fix-cycle-state"
mkdir -p "$triage_state_dir" || { echo "[fix:error] reason=triage_state_write_failed"; exit 1; }
triage_state_file="$triage_state_dir/${pr_number}.json"
triage_state_tmp=""
_rite_fix_triage_state_cleanup() {
  rm -f "${triage_state_tmp:-}"
}
trap 'rc=$?; _rite_fix_triage_state_cleanup; exit $rc' EXIT
trap '_rite_fix_triage_state_cleanup; exit 130' INT
trap '_rite_fix_triage_state_cleanup; exit 143' TERM
trap '_rite_fix_triage_state_cleanup; exit 129' HUP
triage_state_tmp=$(mktemp "$triage_state_dir/.triage-XXXXXX") || {
  echo "[fix:error] reason=triage_state_write_failed"
  exit 1
}
triage_existing='{"pr_number":'"${pr_number}"',"cycles":[]}'
if [ -f "$triage_state_file" ]; then
  triage_existing=$(cat "$triage_state_file") || {
    echo "[fix:error] reason=triage_state_read_failed"
    exit 1
  }
fi
if ! printf '%s\n' "$triage_existing" | jq \
  --argjson moved "${non_fatal_moved_count}" --arg pointer "${triage_review_path}" \
  '.non_fatal_moved_count = $moved | .review_json_path = $pointer' > "$triage_state_tmp" \
  || [ ! -s "$triage_state_tmp" ] \
  || ! mv "$triage_state_tmp" "$triage_state_file"; then
  echo "[fix:error] reason=triage_state_write_failed"
  exit 1
fi
}

# --- cancel-cleanup -------------------------------------------------------------
step_cancel_cleanup() {
# ステップ 1.4 「キャンセル」選択時の cleanup (silent orphan ファイル防止)
# Fast Path bash block 外なので変数は失われている → specific path で直接削除する
# (wildcard glob 絶対禁止。Broad Retrieval 経路ではファイル不在のため rm -f は silent no-op)
rm -f "${TMPDIR:-/tmp}/rite-fix-target-body-${pr_number}-${target_comment_id}.txt" \
      "${TMPDIR:-/tmp}/rite-fix-target-author-${pr_number}-${target_comment_id}.txt" \
      "${TMPDIR:-/tmp}/rite-fix-target-author-skip-${pr_number}-${target_comment_id}.txt" \
      "${TMPDIR:-/tmp}/rite-fix-confidence-override-${pr_number}.txt" \
      "${TMPDIR:-/tmp}/rite-fix-raw-${pr_number}-${target_comment_id}.json" \
      "${TMPDIR:-/tmp}/rite-fix-intermediate-body-${pr_number}-${target_comment_id}.txt" \
      "${TMPDIR:-/tmp}/rite-fix-intermediate-author-${pr_number}-${target_comment_id}.txt" \
      "${TMPDIR:-/tmp}/rite-fix-intermediate-skip-${pr_number}-${target_comment_id}.txt" \
      "${TMPDIR:-/tmp}/rite-fix-pr-comment-${pr_number}.txt"
}

# --- fast-path-cleanup ----------------------------------------------------------
step_fast_path_cleanup() {
# ステップ 1.5: Fast Path Handoff File Cleanup
# 実行条件: Fast Path 経由 (target_comment_id が set されている場合) のみ。
# Broad Comment Retrieval 経路では silent no-op (rm -f は idempotent)。
# 注: confidence_override tempfile はここでは削除しない (fix ループ全体で参照。削除は ステップ 5.1 /
# ステップ 4.6 後)。
rm -f "${TMPDIR:-/tmp}/rite-fix-target-body-${pr_number}-${target_comment_id}.txt" \
      "${TMPDIR:-/tmp}/rite-fix-target-author-${pr_number}-${target_comment_id}.txt" \
      "${TMPDIR:-/tmp}/rite-fix-target-author-skip-${pr_number}-${target_comment_id}.txt" \
      "${TMPDIR:-/tmp}/rite-fix-raw-${pr_number}-${target_comment_id}.json" \
      "${TMPDIR:-/tmp}/rite-fix-intermediate-body-${pr_number}-${target_comment_id}.txt" \
      "${TMPDIR:-/tmp}/rite-fix-intermediate-author-${pr_number}-${target_comment_id}.txt" \
      "${TMPDIR:-/tmp}/rite-fix-intermediate-skip-${pr_number}-${target_comment_id}.txt" \
      "${TMPDIR:-/tmp}/rite-fix-pr-comment-${pr_number}.txt"
}

# --- stagnation-replan ----------------------------------------------------------
step_stagnation_replan() {
# fix-stagnation-replan
fix_state=$(bash "$plugin_root"/hooks/flow-state.sh get --jq-filter .) || exit 1
if printf '%s' "$fix_state" | jq -e '.review_run.current_decision.action == "replan"' >/dev/null; then
  bash "$plugin_root"/hooks/flow-state.sh review-replan \
    --plan "${fix_plan_file}" --issue "${fix_issue_file}" || { echo "[fix:error]"; exit 1; }
fi
fix_state=$(bash "$plugin_root"/hooks/flow-state.sh get --jq-filter .) || exit 1
if printf '%s' "$fix_state" | jq -e '.review_run.current_decision.action == "stop"' >/dev/null; then
  echo "[fix:error]"
  exit 1
fi
}

# --- scope-check ----------------------------------------------------------------
step_scope_check() {
# fix-scope-before-edit
if ! bash "$plugin_root"/hooks/scripts/review-fix-scope-check.sh check \
  --plan "${fix_plan_file}" --issue "${fix_issue_file}"; then
  echo "[fix:error]"
  exit 1
fi
}

# --- impact-scan ----------------------------------------------------------------
step_impact_scan() {
# symbol は caller が修正対象 file から静的に決める。symbol 不在ケースは SKILL.md ステップ 2.2.A を参照
target_symbol="${symbol}"   # 例: "validate_input", "API_TIMEOUT", "UserRepo"

# caller / test / sibling を全部列挙する。git grep の rc は `if cmd; then :; else rc=$?; fi`
# 形式で捕捉する (bang pipeline は then-branch 内で $? が常に 0 を返すため使用禁止)
if git grep -nE "\\b${target_symbol}\\b" -- \
  '*.ts' '*.tsx' '*.js' '*.jsx' '*.py' '*.rb' '*.go' '*.rs' \
  '*.sh' '*.bash' '*.md' '*.yml' '*.yaml' '*.json' > "${TMPDIR:-/tmp}/rite-fix-impact-scan-$$.txt" 2>"${TMPDIR:-/tmp}/rite-fix-impact-scan-err-$$.txt"; then
  cat "${TMPDIR:-/tmp}/rite-fix-impact-scan-$$.txt"
else
  rc=$?
  case "$rc" in
    1) : ;; # match なし (期待動作)、空の影響範囲として Step 2 へ
    128|*)
      echo "WARNING: git grep failed (rc=$rc): $(cat "${TMPDIR:-/tmp}/rite-fix-impact-scan-err-$$.txt" 2>/dev/null)" >&2
      echo "[CONTEXT] IMPACT_SCAN_DEGRADED=1; reason=git_grep_rc_$rc" >&2
      echo "  Claude は grep 不可の影響範囲を手動確認し、確認結果と根拠を構造化出力すること" >&2
      ;;
  esac
fi
rm -f "${TMPDIR:-/tmp}/rite-fix-impact-scan-$$.txt" "${TMPDIR:-/tmp}/rite-fix-impact-scan-err-$$.txt"
}

# --- reply-post -----------------------------------------------------------------
step_reply_post() {
# PR レビューコメントへの返信（in_reply_to で元コメントを指定）
# jq --rawfile で安全に JSON を生成し、gh api に渡す
# trap + cleanup パターンの canonical 説明は references/bash-trap-patterns.md#signal-specific-trap-template 参照
tmpfile=""
_rite_fix_phase24_cleanup() {
  rm -f "${tmpfile:-}"
}
trap 'rc=$?; _rite_fix_phase24_cleanup; exit $rc' EXIT
trap '_rite_fix_phase24_cleanup; exit 130' INT
trap '_rite_fix_phase24_cleanup; exit 143' TERM
trap '_rite_fix_phase24_cleanup; exit 129' HUP

tmpfile=$(mktemp) || {
  echo "ERROR: tmpfile mktemp 失敗 (/tmp が read-only / inode 枯渇 / permission 拒否)" >&2
  # mktemp 失敗経路にも retained flag を emit (rationale: skills/fix/references/design-rationale.md#retained-flag-emission)
  echo "[CONTEXT] REPLY_POST_FAILED=1; comment_id=$comment_id; reason=mktemp_failed_reply_tmpfile" >&2
  exit 1
}

# 返信本文は caller が Write で置いたファイルから写す。cat の exit code を捕捉する (truncated tmpfile の silent POST 防止)
if ! cat "$reply_body_file" > "$tmpfile"; then
  echo "ERROR: reply body の書き込みに失敗 (本文ファイル不在 / /tmp full / permission 拒否 / inode 枯渇)" >&2
  echo "[CONTEXT] REPLY_POST_FAILED=1; comment_id=$comment_id; reason=cat_redirection_failed" >&2
  exit 1
fi

# 追加 post-condition: 書き込み成功扱いだが空ファイル (空の本文 / seek race / quota 等) も捕捉
if [ ! -s "$tmpfile" ]; then
  echo "ERROR: reply body tmpfile が空です (書き込み後 post-condition 違反)" >&2
  echo "[CONTEXT] REPLY_POST_FAILED=1; comment_id=$comment_id; reason=reply_tmpfile_empty" >&2
  exit 1
fi

# pipefail を有効化して jq | gh api パイプの前段失敗を確実に検出
set -o pipefail
if ! jq -n --rawfile body "$tmpfile" --argjson in_reply_to "$comment_id" \
  '{"body": $body, "in_reply_to": $in_reply_to}' | gh api repos/${owner}/${repo}/pulls/${pr_number}/comments \
  -X POST \
  --input -; then
  echo "ERROR: reply 投稿 (jq | gh api POST) に失敗しました" >&2
  echo "  対処: gh auth status / network 接続 / rate limit / PR #${pr_number} の存在を確認してください" >&2
  echo "  影響: レビュアーへの返信が PR に残らないまま fix loop が完了扱いになる silent regression のリスク" >&2
  # retained flag emit (ステップ 5.1 評価順テーブルで detect され [fix:error] へ昇格する)
  echo "[CONTEXT] REPLY_POST_FAILED=1; comment_id=$comment_id" >&2
  set +o pipefail
  exit 1
fi
set +o pipefail
}

# --- scope-verify ---------------------------------------------------------------
step_scope_verify() {
# fix-scope-final-verification
if ! bash "$plugin_root"/hooks/scripts/review-fix-scope-check.sh verify \
  --plan "${fix_plan_file}" --issue "${fix_issue_file}" --kind all; then
  echo "[fix:error]"
  exit 1
fi
}

# --- commit-guard ---------------------------------------------------------------
step_commit_guard() {
# helper の rc 非 0 (mktemp 失敗等) は dirty 側 = ガード非発火 = 従来どおりステップ 3 実行 に倒す
# (working tree の状態が判定できないまま commit を skip すると、実際にあった変更を取りこぼすため)
dirty=$(bash "$plugin_root"/hooks/scripts/lib/git-status-filtered.sh --tracked-only) || dirty="__RITE_STATUS_UNKNOWN__"
if [ -z "$dirty" ]; then
  echo "[CONTEXT] FIX_COMMIT_GUARD=skip; reason=worktree_clean" >&2
elif [ "$dirty" = "__RITE_STATUS_UNKNOWN__" ]; then
  # helper が rc 非 0 (mktemp 失敗 / git repo 外 等)。安全側 = ステップ 3 実行 に倒すが、
  # 「本当に汚れている」と「検出不能だった」を機械可読チャネル上で区別する
  echo "[CONTEXT] FIX_COMMIT_GUARD=proceed; reason=status_unknown" >&2
else
  echo "[CONTEXT] FIX_COMMIT_GUARD=proceed; reason=worktree_dirty" >&2
fi
}

# --- skip-cycle-state -----------------------------------------------------------
step_skip_cycle_state() {
# FIX_COMMIT_GUARD=skip のときだけ。findings_addressed_file は ステップ 2.3 で記録した配列を caller が Write で置いたファイル
# （fix は path:line / path:start-end、reply/accept/nit-noted は changes: []。diff_verified は書かない）。
# JSON は single-quote に直接埋めず、ファイル + --rawfile で渡す（ステップ 2.4 の reply と同じ形）。
# trap + cleanup パターンの canonical 説明は references/bash-trap-patterns.md#signal-specific-trap-template 参照
_state_root=$(bash "$plugin_root"/hooks/state-path-resolve.sh 2>/dev/null) || _state_root=""
[ -n "$_state_root" ] || { echo "WARNING: state-path-resolve.sh の解決に失敗。cwd をフォールバック使用します" >&2; _state_root="$(pwd)"; }
mkdir -p "$_state_root/.rite/fix-cycle-state"
state_file="$_state_root/.rite/fix-cycle-state/${pr_number}.json"
head_sha=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S+00:00" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%S")
if [ -f "$state_file" ]; then
  existing=$(cat "$state_file")
else
  existing='{"pr_number":'"$pr_number"',"cycles":[]}'
fi
addressed_file=""
state_tmp=""
_rite_fix_skip_addressed_cleanup() {
  rm -f "${addressed_file:-}" "${state_tmp:-}"
}
trap 'rc=$?; _rite_fix_skip_addressed_cleanup; exit $rc' EXIT
trap '_rite_fix_skip_addressed_cleanup; exit 130' INT
trap '_rite_fix_skip_addressed_cleanup; exit 143' TERM
trap '_rite_fix_skip_addressed_cleanup; exit 129' HUP
addressed_file=$(mktemp "${TMPDIR:-/tmp}/rite-fix-addressed-XXXXXX") || {
  echo "ERROR: findings_addressed 用 mktemp に失敗" >&2
  echo "[fix:error]"
  exit 1
}
if ! cat "$findings_addressed_file" > "$addressed_file"; then
  echo "ERROR: findings_addressed の書き込みに失敗 (記録ファイル不在 / /tmp full / permission 拒否)" >&2
  echo "[fix:error]"
  exit 1
fi
new_cycle=$(jq -n \
  --arg ts "$timestamp" \
  --arg head "$head_sha" \
  --rawfile addressed_raw "$addressed_file" \
  --argjson moved "${non_fatal_moved_count}" \
  --arg review_json "${triage_review_path}" \
  '{
    "cycle": 0,
    "timestamp": $ts,
    "commit_sha_before": $head,
    "commit_sha_after": $head,
    "findings_fixed": 0,
    "non_fatal_moved_count": $moved,
    "review_json_path": $review_json,
    "findings_new_from_fix": 0,
    "files_changed_by_fix": [],
    "lines_added": 0,
    "lines_deleted": 0,
    "propagation_applied": 0,
    "findings_addressed": ($addressed_raw | fromjson)
  }') || {
  echo "ERROR: cycle entry の生成に失敗 (findings_addressed が不正な JSON)" >&2
  echo "[fix:error]"
  exit 1
}
# 既存 state を直接開かない。生成に失敗したまま redirect すると履歴ごと truncate される。
# 既存 state が空だと jq は rc=0 のまま何も出さないため、空出力も -s で設置前に止める。
state_tmp=$(mktemp "${state_file%/*}/.cycle-XXXXXX") || {
  echo "ERROR: cycle state 用 mktemp に失敗" >&2
  echo "[fix:error]"
  exit 1
}
if ! printf '%s\n' "$existing" | jq --argjson entry "$new_cycle" '
  (.cycles | length) as $len |
  .cycles += [$entry | .cycle = ($len + 1)] |
  if (.cycles | length) > 20 then .cycles = .cycles[-20:] else . end
' > "$state_tmp" || [ ! -s "$state_tmp" ] || ! mv "$state_tmp" "$state_file"; then
  rm -f "$state_tmp"
  echo "ERROR: cycle state の書き込みに失敗 (jq 失敗 / 出力が空 / mv 失敗)" >&2
  echo "[fix:error]"
  exit 1
fi
printf '[CONTEXT] FIX_CYCLE_STATE_WRITTEN file=%s cycle=%d skip=1\n' "$state_file" "$(jq '.cycles | length' "$state_file")"
}

# --- cycle-base-sha -------------------------------------------------------------
step_cycle_base_sha() {
fix_cycle_base_sha=$(git rev-parse HEAD) || { echo "[fix:error]"; exit 1; }
printf '[CONTEXT] FIX_CYCLE_BASE_SHA=%s\n' "$fix_cycle_base_sha"
}

# --- show-changes ---------------------------------------------------------------
step_show_changes() {
git status
git diff
}

# --- number-ref-check -----------------------------------------------------------
step_number_ref_check() {
nref_base="origin/${base_branch}"
git rev-parse --verify "${nref_base}^{commit}" >/dev/null 2>&1 || nref_base="${base_branch}"
if [ -n "${changed_files}" ]; then
  nref_addn=""
  for f in ${changed_files}; do
    [ -e "$f" ] && nref_addn="$nref_addn $f"
  done
  if [ -n "$nref_addn" ]; then
    nref_stage_rc=0
    git add -N -- $nref_addn || nref_stage_rc=$?
    if [ "$nref_stage_rc" -ne 0 ]; then
      echo "ERROR: intent-to-add に失敗しました (rc=$nref_stage_rc)。新規ファイルが検査されないため commit しません" >&2
      echo "[fix:error]"
      exit 1
    fi
  fi
fi
nref_rc=0
bash "$plugin_root"/hooks/scripts/number-reference-check.sh --diff "$nref_base" || nref_rc=$?
case "$nref_rc" in
  0) echo "[CONTEXT] NUMBER_REF_CHECK=clean" ;;
  1)
    echo "ERROR: 追加行に Issue/PR 番号参照がある。コミットしない。ステップ 2.3 で書き直す。" >&2
    echo "[CONTEXT] NUMBER_REF_CHECK=hits" >&2
    ;;
  *)
    echo "ERROR: number-reference-check.sh failed (rc=$nref_rc)" >&2
    echo "[fix:error]"
    exit 1
    ;;
esac
}

# --- schema-drift-check ---------------------------------------------------------
step_schema_drift_check() {
bash "$plugin_root"/hooks/scripts/review-schema-version-check.sh --all
drift_exit=$?
printf '[CONTEXT] PRE_COMMIT_DRIFT_CHECK exit=%d\n' "$drift_exit"
}

# --- cycle-state ----------------------------------------------------------------
step_cycle_state() {
# fix-cycle-state もリポジトリ共通 state ルート基準 (pr-review.md ステップ 5.3.8 の読取側と同一解決)
_state_root=$(bash "$plugin_root"/hooks/state-path-resolve.sh 2>/dev/null) || _state_root=""
[ -n "$_state_root" ] || { echo "WARNING: state-path-resolve.sh の解決に失敗。cwd をフォールバック使用します" >&2; _state_root="$(pwd)"; }
mkdir -p "$_state_root/.rite/fix-cycle-state"

state_file="$_state_root/.rite/fix-cycle-state/${pr_number}.json"
commit_sha_after=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
commit_sha_before="${fix_cycle_base_sha}"
if ! git cat-file -e "${commit_sha_before}^{commit}" 2>/dev/null; then
  echo "ERROR: FIX_CYCLE_BASE_SHA が未展開または無効です: $commit_sha_before" >&2
  echo "[fix:error]"
  exit 1
fi
timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S+00:00" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%S")
files_changed=$(git diff --name-only "$commit_sha_before"..HEAD 2>/dev/null | jq -R -s 'split("\n") | map(select(length > 0))' 2>/dev/null || echo '[]')
# 既存の cycle state に当該 fix cycle 全体の行数差分を記録する。バイナリの `-` は行数に含めない。
diff_stats=$(git diff --numstat "$commit_sha_before"..HEAD 2>/dev/null | awk '
  $1 ~ /^[0-9]+$/ { added += $1 }
  $2 ~ /^[0-9]+$/ { deleted += $2 }
  END { printf "%d %d", added, deleted }
')
lines_added=${diff_stats%% *}
lines_deleted=${diff_stats##* }

# Read existing state or initialize
if [ -f "$state_file" ]; then
  existing=$(cat "$state_file")
else
  existing='{"pr_number":'"$pr_number"',"cycles":[]}'
fi

# Append new cycle entry (propagation_applied is set by ステップ 2.3.1 context)
# findings_addressed_file は ステップ 2.3 で記録した配列を caller が Write で置いたファイル（diff_verified は書かない。gate が書き戻す）
# JSON は single-quote に直接埋めず、ファイル + --rawfile で渡す（ステップ 2.4 の reply と同じ形）。
# trap + cleanup パターンの canonical 説明は references/bash-trap-patterns.md#signal-specific-trap-template 参照
addressed_file=""
state_tmp=""
_rite_fix_cycle_addressed_cleanup() {
  rm -f "${addressed_file:-}" "${state_tmp:-}"
}
trap 'rc=$?; _rite_fix_cycle_addressed_cleanup; exit $rc' EXIT
trap '_rite_fix_cycle_addressed_cleanup; exit 130' INT
trap '_rite_fix_cycle_addressed_cleanup; exit 143' TERM
trap '_rite_fix_cycle_addressed_cleanup; exit 129' HUP
addressed_file=$(mktemp "${TMPDIR:-/tmp}/rite-fix-addressed-XXXXXX") || {
  echo "ERROR: findings_addressed 用 mktemp に失敗" >&2
  echo "[fix:error]"
  exit 1
}
if ! cat "$findings_addressed_file" > "$addressed_file"; then
  echo "ERROR: findings_addressed の書き込みに失敗 (記録ファイル不在 / /tmp full / permission 拒否)" >&2
  echo "[fix:error]"
  exit 1
fi
new_cycle=$(jq -n \
  --arg ts "$timestamp" \
  --arg before "$commit_sha_before" \
  --arg after "$commit_sha_after" \
  --argjson fixed "${findings_fixed_count}" \
  --argjson propagated "${propagation_applied_count}" \
  --argjson files "$files_changed" \
  --argjson added "$lines_added" \
  --argjson deleted "$lines_deleted" \
  --argjson moved "${non_fatal_moved_count}" \
  --arg review_json "${triage_review_path}" \
  --rawfile addressed_raw "$addressed_file" \
  '{
    "cycle": 0,
    "timestamp": $ts,
    "commit_sha_before": $before,
    "commit_sha_after": $after,
    "findings_fixed": $fixed,
    "non_fatal_moved_count": $moved,
    "review_json_path": $review_json,
    "findings_new_from_fix": 0,
    "files_changed_by_fix": $files,
    "lines_added": $added,
    "lines_deleted": $deleted,
    "propagation_applied": $propagated,
    "findings_addressed": ($addressed_raw | fromjson)
  }') || {
  echo "ERROR: cycle entry の生成に失敗 (findings_addressed が不正な JSON)" >&2
  echo "[fix:error]"
  exit 1
}

# Append and assign cycle number, enforce ring buffer (max 20 entries)
# 既存 state を直接開かない。生成に失敗したまま redirect すると履歴ごと truncate される。
# 既存 state が空だと jq は rc=0 のまま何も出さないため、空出力も -s で設置前に止める。
state_tmp=$(mktemp "${state_file%/*}/.cycle-XXXXXX") || {
  echo "ERROR: cycle state 用 mktemp に失敗" >&2
  echo "[fix:error]"
  exit 1
}
if ! printf '%s\n' "$existing" | jq --argjson entry "$new_cycle" '
  (.cycles | length) as $len |
  .cycles += [$entry | .cycle = ($len + 1)] |
  if (.cycles | length) > 20 then .cycles = .cycles[-20:] else . end
' > "$state_tmp" || [ ! -s "$state_tmp" ] || ! mv "$state_tmp" "$state_file"; then
  rm -f "$state_tmp"
  echo "ERROR: cycle state の書き込みに失敗 (jq 失敗 / 出力が空 / mv 失敗)" >&2
  echo "[fix:error]"
  exit 1
fi

printf '[CONTEXT] FIX_CYCLE_STATE_WRITTEN file=%s cycle=%d\n' "$state_file" "$(jq '.cycles | length' "$state_file")"
}

# --- push -----------------------------------------------------------------------
step_push() {
git push origin HEAD
}

# --- resolve-thread -------------------------------------------------------------
step_resolve_thread() {
# 注: thread_id は GraphQL の Node ID を使用（ステップ 1.2 で取得した reviewThreads.nodes[].id）
gh api graphql -f query='
mutation($threadId: ID!) {
  resolveReviewThread(input: {threadId: $threadId}) {
    thread {
      isResolved
    }
  }
}' -f threadId="${thread_id}"
}

# --- wm-update ------------------------------------------------------------------
step_wm_update() {
trap 'rc=$?; rm -f "$pr_body_file" "$history_file"; exit "$rc"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
wm_update_rc=0
wm_update_out=$(bash "$plugin_root/scripts/fix-work-memory-update.sh" \
  --pr-body-file "$pr_body_file" --history-file "$history_file" \
  --impl-status "${impl_status}" --test-status "${test_status}" --doc-status "${doc_status}") || wm_update_rc=$?
printf '%s\n' "$wm_update_out"
if ! printf '%s\n' "$wm_update_out" | grep -qE '^\[CONTEXT\] FIX_WM_UPDATE=(success|skipped|failed); issue_number=[0-9]*$'; then
  echo "ERROR: work memory helper の結果を取得できませんでした (rc=$wm_update_rc)" >&2
  echo "[CONTEXT] WM_UPDATE_FAILED=1; reason=wm_update_helper_failed" >&2
  [ "$wm_update_rc" -ne 0 ] || wm_update_rc=1
fi
if [ "$wm_update_rc" -ne 0 ]; then
  echo "ERROR: work memory helper が非ゼロ終了しました (rc=$wm_update_rc)" >&2
fi
exit "$wm_update_rc"
}

# --- accept-count ---------------------------------------------------------------
step_accept_count() {
_state_root=$(bash "$plugin_root"/hooks/state-path-resolve.sh 2>/dev/null) || _state_root=""
[ -n "$_state_root" ] || { echo "WARNING: state-path-resolve.sh の解決に失敗。cwd をフォールバック使用します" >&2; _state_root="$(pwd)"; }
accept_count=$(wc -l < "$_state_root/.rite/state/accepted-fingerprints-${pr_number}.txt" 2>/dev/null | tr -d '[:space:]')
case "$accept_count" in ''|*[!0-9]*) accept_count=0 ;; esac
echo "accept_count=$accept_count"
}

# --- wiki-ingest-check ----------------------------------------------------------
step_wiki_ingest_check() {
# config は worktree 自身のもの、無ければ main checkout のものを読む
rite_config=$(bash "$plugin_root"/hooks/scripts/lib/rite-config-path.sh --or-devnull) || exit 1
wiki_section=$(sed -n '/^wiki:/,/^[^[:space:]#]/p' "$rite_config" 2>/dev/null) || wiki_section=""
wiki_enabled=""
if [[ -n "$wiki_section" ]]; then
  wiki_enabled=$(printf '%s\n' "$wiki_section" | awk '/^[[:space:]]+enabled:/ { print; exit }' \
    | sed 's/[[:space:]]#.*//' | sed 's/.*enabled:[[:space:]]*//' | tr -d '[:space:]"'"'"'' | tr '[:upper:]' '[:lower:]')
fi
auto_ingest=""
if [[ -n "$wiki_section" ]]; then
  auto_ingest=$(printf '%s\n' "$wiki_section" | awk '/^[[:space:]]+auto_ingest:/ { print; exit }' \
    | sed 's/[[:space:]]#.*//' | sed 's/.*auto_ingest:[[:space:]]*//' | tr -d '[:space:]"'"'"'' | tr '[:upper:]' '[:lower:]')
fi
case "$wiki_enabled" in false|no|0) wiki_enabled="false" ;; true|yes|1) wiki_enabled="true" ;; *) wiki_enabled="true" ;; esac  # opt-out default
case "$auto_ingest" in true|yes|1) auto_ingest="true" ;; *) auto_ingest="false" ;; esac
echo "wiki_enabled=$wiki_enabled auto_ingest=$auto_ingest"

# 無効なら skip の status 行を出す（caller は ステップ 5.0 の gate でこの行を探す）
if [ "$wiki_enabled" = "false" ]; then
  reason="disabled"
elif [ "$auto_ingest" = "false" ]; then
  reason="auto_ingest_off"
else
  reason=""
fi
if [ -n "$reason" ]; then
  echo "[CONTEXT] WIKI_INGEST_SKIPPED=1; reason=$reason"
  echo "WARNING: fix ステップ 4.6.W Wiki ingest skipped: $reason" >&2
fi
}

# --- local-wm-sync --------------------------------------------------------------
step_local_wm_sync() {
# hook stderr を tempfile に退避し、lock failure と他 failure を区別して分岐する
# rationale: skills/fix/references/design-rationale.md#output-pattern-notes
hook_err=$(mktemp "${TMPDIR:-/tmp}/rite-fix-hook-err-XXXXXX") || {
  echo "WARNING: hook_err mktemp 失敗 — local work memory hook を skip します (E2E flow 続行)" >&2
  hook_err=""
}
if [ -n "$hook_err" ]; then
  # rc 捕捉は `if cmd; then :; else rc=$?; fi` の else 節形式 (「!」否定は $? を反転する)
  if WM_SOURCE="fix" \
      WM_PHASE="fix" \
      WM_PHASE_DETAIL="レビュー修正後処理" \
      WM_NEXT_ACTION="re-review or completion" \
      WM_BODY_TEXT="Post-fix sync." \
      WM_ISSUE_NUMBER="${issue_number}" \
      bash "$plugin_root"/hooks/local-wm-update.sh 2>"$hook_err"; then
    : # success
  else
    hook_wm_update_rc=$?
    # exact phrase pattern (canonical: common-error-handling.md#hook-lock-contention-classification-canonical)
    if grep -qiE '(file is locked|lock contention|resource busy)' "$hook_err"; then
      # lock failure (best-effort skip 該当): WARNING のみで継続
      echo "WARNING: local work memory lock contention (best-effort skip, rc=$hook_wm_update_rc)" >&2
    else
      # 非 lock failure: hook 自体の障害 (script 不在 / permission / syntax / internal error)
      echo "WARNING: local work memory update hook failed (non-lock failure, rc=$hook_wm_update_rc):" >&2
      head -5 "$hook_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
      echo "  対処: hooks/local-wm-update.sh の存在 / 実行権限 / 内容を確認してください" >&2
      echo "  影響: local .rite/work-memory/issue-*.md が GitHub comment 側と一時的に不整合になる (E2E flow は続行)" >&2
    fi
  fi
  rm -f "$hook_err"
else
  # hook_err mktemp 失敗時は 2>&1 + head -5 の簡易 fallback で WARNING を可視化する (silent skip 禁止)
  echo "WARNING: hook_err mktemp 失敗により local-wm-update.sh の stderr 詳細が取得できません" >&2
  if hook_combined=$(WM_SOURCE="fix" \
        WM_PHASE="fix" \
        WM_PHASE_DETAIL="レビュー修正後処理" \
        WM_NEXT_ACTION="re-review or completion" \
        WM_BODY_TEXT="Post-fix sync." \
        WM_ISSUE_NUMBER="${issue_number}" \
        bash "$plugin_root"/hooks/local-wm-update.sh 2>&1); then
    : # success
  else
    hook_fallback_rc=$?
    echo "WARNING: local-wm-update.sh failed (fallback no-tempfile path, rc=$hook_fallback_rc):" >&2
    printf '%s\n' "$hook_combined" | head -5 | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
    echo "  対処: /tmp の空き容量と hooks/local-wm-update.sh の状態を確認してください" >&2
  fi
fi
}

# --- nb-sweep-done-file ---------------------------------------------------------
step_nb_sweep_done_file() {
_nb_done_root=$(bash "$plugin_root"/hooks/state-path-resolve.sh) || _nb_done_root=""
_nb_done_file=""
_nb_range=""
_nb_latest=""
_nb_latest_base=""
if [ -n "$_nb_done_root" ]; then
  _nb_done_file="$_nb_done_root/.rite/state/nb-sweep-done-${pr_number}.txt"
  [ -f "$_nb_done_file" ] && _nb_range=$(awk 'NR==1 { print $2 }' "$_nb_done_file")
  _nb_latest=$(find "$_nb_done_root/.rite/review-results" -maxdepth 1 -type f -name "${pr_number}-*.json" 2>/dev/null | LC_ALL=C sort | tail -1)
  [ -n "$_nb_latest" ] && _nb_latest_base=$(basename "$_nb_latest")
fi
if [ -n "$_nb_range" ] && [ "$_nb_range" = "$_nb_latest_base" ]; then
  echo "[CONTEXT] NB_SWEEP_DONE_FILE=1" >&2
else
  echo "[CONTEXT] NB_SWEEP_DONE_FILE=0" >&2
fi
}

# --- override-cleanup -----------------------------------------------------------
step_override_cleanup() {
# confidence_override + pr-comment tempfile の明示的 cleanup (E2E の ステップ 5.1 / standalone の 5.2)
# fix ループ全体で append されてきたファイルを終了時に削除する。
# rationale: skills/fix/references/design-rationale.md#confidence-gate-notes
# pr-comment tempfile も追加 (Broad Retrieval が書き出した
# ${TMPDIR:-/tmp}/rite-fix-pr-comment-${pr_number}.txt の正常時 cleanup)。Fast Path 経路では存在しないため
# silent no-op となる。
rm -f "${TMPDIR:-/tmp}/rite-fix-confidence-override-${pr_number}.txt" \
      "${TMPDIR:-/tmp}/rite-fix-pr-comment-${pr_number}.txt"
}

# --- target-comment-fetch ------------------------------------------------------
step_target_comment_fetch() {
# 取得・所属 PR 検証・handoff の生成は helper が順番に実行する。非ゼロ終了後は解析へ進まない。
bash "$plugin_root"/scripts/review-target-comment-fetch.sh \
  --owner-repo "${owner_repo}" --pr "${pr_number}" --comment-id "${target_comment_id}" || {
  echo "[fix:error]"
  exit 1
}
}

# --- override-read --------------------------------------------------------------
step_override_read() {
# confidence override の件数と一覧をファイルから読む（会話履歴の grep に依存しない）。
# 値は stdout の confidence_override_count= / confidence_override_findings= で渡す。
override_path="${TMPDIR:-/tmp}/rite-fix-confidence-override-${pr_number}.txt"
if [ -f "$override_path" ]; then
  # wc -l の stderr を独立退避 (IO エラーの silent count=0 化で監査トレースが drop するのを防ぐ)
  override_err=$(mktemp "${TMPDIR:-/tmp}/rite-fix-confidence-override-err-XXXXXX") || {
    echo "ERROR: override_err mktemp 失敗" >&2
    echo "[CONTEXT] CONFIDENCE_OVERRIDE_READ_FAILED=1; reason=mktemp_failed_override_err" >&2
    exit 1
  }
  if ! confidence_override_count_raw=$(wc -l < "$override_path" 2>"$override_err"); then
    echo "ERROR: wc -l による override_path 読み出し失敗: $(cat "$override_err")" >&2
    echo "[CONTEXT] CONFIDENCE_OVERRIDE_READ_FAILED=1; reason=wc_io_error; path=$override_path" >&2
    rm -f "$override_err"
    exit 1
  fi
  confidence_override_count=$(printf '%s' "$confidence_override_count_raw" | tr -d ' ')
  # findings 一覧 (1 行 1 finding) は paste で "; " 区切りに変換
  if ! confidence_override_findings_raw=$(paste -sd ';' "$override_path" 2>"$override_err"); then
    echo "ERROR: paste による override_path 読み出し失敗: $(cat "$override_err")" >&2
    echo "[CONTEXT] CONFIDENCE_OVERRIDE_READ_FAILED=1; reason=paste_io_error; path=$override_path" >&2
    rm -f "$override_err"
    exit 1
  fi
  confidence_override_findings_str=$(printf '%s' "$confidence_override_findings_raw" | sed 's/;/; /g')
  rm -f "$override_err"
else
  confidence_override_count=0
  confidence_override_findings_str=""
fi
echo "confidence_override_count=$confidence_override_count"
echo "confidence_override_findings=$confidence_override_findings_str"
}

# --- accept-persist -------------------------------------------------------------
step_accept_persist() {
# ステップ 2.1.A accept fingerprint 永続化
# canonical trap pattern は references/bash-trap-patterns.md#signal-specific-trap-template 参照
# (rationale: パス先行宣言 → trap 先行設定 → mktemp の順序、signal 別 exit code、関数契約)
# pr_number の空値・placeholder 残留・非数値は dispatcher が exit 2 で先に止める。

# 自由文を二重引用符へ置換するとシェル展開された値を hash してしまうため、JSON から生のまま読む
# (pr-review-step.sh fingerprint-check と同じ述語・同じ jq)
if [ ! -r "$finding_file" ] || ! jq -e 'type == "object" and (.file | type) == "string" and (.category | type) == "string" and (.category | length) > 0 and (.description | type) == "string"' "$finding_file" >/dev/null 2>&1; then
  echo "WARNING: ステップ 2.1.A の finding ファイルが file / category / description を文字列で持つ JSON ではありません ($finding_file) — fingerprint 永続化を skip します" >&2
  echo "[CONTEXT] ACCEPT_FINGERPRINT_PERSIST_FAILED=1; reason=finding_file_invalid" >&2
  exit 0
fi
file_path=$(jq -r '.file' "$finding_file") || exit 1
line_no=$(jq -r '.line // ""' "$finding_file") || exit 1
category=$(jq -r '.category' "$finding_file") || exit 1
description=$(jq -r '.description' "$finding_file") || exit 1
# line=null → anchor sentinel に正規化 (ステップ 1.3 の thread lookup 規約と統一)
case "$line_no" in
  ''|null|0) line_no="anchor" ;;
esac

# パス先行宣言 → cleanup 関数定義 → 4 行 trap 設置 → mktemp の順 (canonical pattern)
tmpfile=""
# state ファイルはリポジトリ共通の state ルート基準 (state-path-resolve.sh)。セッション worktree /
# main checkout のどちらから実行しても同一パスに解決される (pr-review ステップ 5.1.2.A の
# 読取側と同一解決。解決失敗時は cwd fallback)
_state_root=$(bash "$plugin_root"/hooks/state-path-resolve.sh 2>/dev/null) || _state_root=""
[ -n "$_state_root" ] || { echo "WARNING: state-path-resolve.sh の解決に失敗。cwd をフォールバック使用します" >&2; _state_root="$(pwd)"; }
state_dir="$_state_root/.rite/state"
state_file="${state_dir}/accepted-fingerprints-${pr_number}.txt"
_rite_fix_phase21A_cleanup() {
  rm -f "${tmpfile:-}"
}
trap 'rc=$?; _rite_fix_phase21A_cleanup; exit $rc' EXIT
trap '_rite_fix_phase21A_cleanup; exit 130' INT
trap '_rite_fix_phase21A_cleanup; exit 143' TERM
trap '_rite_fix_phase21A_cleanup; exit 129' HUP

# fingerprint 計算 (ステップ 2.1.A 独自 simplified normalize — accept 抑止専用)
# normalize(file_path): `./` prefix のみ collapse、case-sensitive path 保護のため lowercase 化しない
# normalize(message): trim + whitespace collapse、identifier mask しない (audit log の human readability 重視)
norm_file=$(printf '%s' "$file_path" | sed 's@^\./@@')
norm_cat="$category"
norm_msg=$(printf '%s' "$description" | tr -s '[:space:]' ' ' | sed 's/^ *//;s/ *$//')

# portable SHA-1 helper (BSD shasum / GNU sha1sum 両対応)
if command -v sha1sum >/dev/null 2>&1; then
  fingerprint=$(printf '%s:%s:%s' "$norm_file" "$norm_cat" "$norm_msg" | sha1sum | awk '{print $1}')
elif command -v shasum >/dev/null 2>&1; then
  fingerprint=$(printf '%s:%s:%s' "$norm_file" "$norm_cat" "$norm_msg" | shasum -a 1 | awk '{print $1}')
else
  echo "WARNING: sha1sum / shasum が見つかりません — fingerprint 永続化を skip します" >&2
  echo "[CONTEXT] ACCEPT_FINGERPRINT_PERSIST_FAILED=1; reason=sha1_helper_missing" >&2
  exit 0  # non-blocking: accept reply 投稿は完了済、suppression は諦めるだけ
fi

# state directory + tempfile
if ! mkdir -p "$state_dir" 2>/dev/null; then
  echo "WARNING: .rite/state/ ディレクトリ作成に失敗しました — fingerprint 永続化を skip します" >&2
  echo "[CONTEXT] ACCEPT_FINGERPRINT_PERSIST_FAILED=1; reason=mkdir_failed" >&2
  exit 0
fi

if ! tmpfile=$(mktemp "${TMPDIR:-/tmp}/rite-fix-accept-fp-${pr_number}-XXXXXX" 2>/dev/null); then
  echo "[CONTEXT] ACCEPT_FINGERPRINT_PERSIST_FAILED=1; reason=mktemp_failed" >&2
  exit 0
fi

# idempotent append (sort -u で重複排除) + atomic mv
{ [ -f "$state_file" ] && cat "$state_file"; printf '%s\n' "$fingerprint"; } | sort -u > "$tmpfile"
if ! mv "$tmpfile" "$state_file" 2>/dev/null; then
  echo "WARNING: accepted-fingerprints state file の atomic mv に失敗しました ($state_file)" >&2
  echo "[CONTEXT] ACCEPT_FINGERPRINT_PERSIST_FAILED=1; reason=mv_failed" >&2
  exit 0
fi
tmpfile=""  # mv 成功後は trap cleanup 対象から外す (二重 rm 回避)

# 成功時 retained flag (bash 変数経由で placeholder 残留を防ぐ)
echo "[CONTEXT] ACCEPT_FINGERPRINT_PERSISTED=1; fingerprint=$fingerprint; pr=$pr_number; file=$file_path; line=$line_no" >&2

# accept ≥5 件警告
# wc -l 出力に platform 依存の空白が含まれるため tr -d で剥がす (BSD wc は 先頭に空白を付ける)
accept_count=$(wc -l < "$state_file" 2>/dev/null | tr -d '[:space:]')
case "$accept_count" in ''|*[!0-9]*) accept_count=0 ;; esac
if [ "$accept_count" -ge 5 ]; then
  echo "⚠️ WARNING: 本 PR で accept (認知のみ) 累計件数が 5 件以上 (${accept_count} 件) に達しました。reviewer の精度を疑うべき水準です。" >&2
  echo "  対処: reviewer agent の prompt / scope assignment / pattern check ロジックを見直すか、本 PR を別 Issue に分割することを検討してください。" >&2
  echo "[CONTEXT] ACCEPT_LIMIT_EXCEEDED=1; pr=$pr_number; accept_count=$accept_count" >&2
fi
}

# --- non-fatal-record -----------------------------------------------------------
step_non_fatal_record() {
# 共通 triage が永続化した JSON から既存の関連 Issue 記録を更新する。終端 outcome の確認を終えるまで成功を返さない。
record_body=$(mktemp "${TMPDIR:-/tmp}/rite-fix-nbr-body-XXXXXX") || {
  echo "[fix:error] reason=nonblocking_record_tempfile_failed"
  exit 1
}
record_log=$(mktemp "${TMPDIR:-/tmp}/rite-fix-nbr-log-XXXXXX") || {
  rm -f "$record_body"
  echo "[fix:error] reason=nonblocking_record_tempfile_failed"
  exit 1
}
if ! non_blocking_count=$(jq '[.non_blocking_findings[]? | select(.scope != "nit-noted")] | length' "$triage_review_path"); then
  rm -f "$record_body" "$record_log"
  echo "[fix:error] reason=nonblocking_record_read_failed"
  exit 1
fi
# 既存 marker / count / 最終行 sentinel を維持し、pointer と降格理由を記録する（全文・証跡は永続 JSON のみに保持）。
# 非 fatal の移送は実測済みの指摘も運ぶため、見出しは実測の有無を断定せず、行ごとの理由で区別する。
if ! jq -r --arg pr "${pr_number}" --arg pointer "$triage_review_path" \
  --arg moved "${non_fatal_moved_count}" --arg count "$non_blocking_count" '
  "## 📜 rite 非実測指摘の記録",
  "", "PR #" + $pr, "",
  "### non-blocking（fix 対象外）",
  "今回の移送: " + $moved + "件", "記録 JSON: " + $pointer,
  "", "📎 non_blocking_count: " + $count, "",
  (.non_blocking_findings[]? | select(.scope != "nit-noted")
    | [.id, (.reviewer // ""), .severity, (.file + ":" + ((.line // "anchor") | tostring)),
       (if has("demotion") then "class B 降格: " + (.demotion.reason | tostring)
        elif (.verification | if type == "object" then .measured else null end) == true then "実測済み（非 fatal）"
        else "実測なし" end)] | @tsv),
  "", "<!-- rite:nbr:v1 -->"
' "$triage_review_path" > "$record_body"; then
  rm -f "$record_body" "$record_log"
  echo "[fix:error] reason=nonblocking_record_body_failed"
  exit 1
fi
# helper は既存の記録を全文 PATCH で置き換えるので、その却下台帳を新本文へ引き継ぐ。
# 既存本文は helper が PATCH する 1 件を、同じ helper の読み取り専用モードで読む（関連 Issue の解決も helper が行う）。
ledger_existing=$(mktemp "${TMPDIR:-/tmp}/rite-fix-nbr-existing-XXXXXX") \
  && ledger_file=$(mktemp "${TMPDIR:-/tmp}/rite-fix-nbr-ledger-XXXXXX") || {
  rm -f "$record_body" "$record_log" "${ledger_existing:-}"
  echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=nonblocking_record_tempfile_failed" >&2
  echo "[fix:error] reason=nonblocking_record_tempfile_failed"
  exit 1
}
if ! bash "$plugin_root"/hooks/review-nonblocking-record.sh --print-record-body \
  --pr "${pr_number}" --owner-repo "${owner_repo}" > "$ledger_existing"; then
  rm -f "$record_body" "$record_log" "$ledger_existing" "$ledger_file"
  echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=nonblocking_record_ledger_fetch_failed" >&2
  echo "[fix:error] reason=nonblocking_record_ledger_fetch_failed"
  exit 1
fi
if [ -s "$ledger_existing" ] \
  && ! bash "$plugin_root"/hooks/scripts/nb-sweep-ledger.sh extract --body-file "$ledger_existing" > "$ledger_file"; then
  rm -f "$record_body" "$record_log" "$ledger_existing" "$ledger_file"
  echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=nonblocking_record_ledger_extract_failed" >&2
  echo "[fix:error] reason=nonblocking_record_ledger_extract_failed"
  exit 1
fi
if ! bash "$plugin_root"/hooks/scripts/nb-sweep-ledger.sh merge-into --body-file "$record_body" --ledger-file "$ledger_file"; then
  rm -f "$record_body" "$record_log" "$ledger_existing" "$ledger_file"
  echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=nonblocking_record_ledger_merge_failed" >&2
  echo "[fix:error] reason=nonblocking_record_ledger_merge_failed"
  exit 1
fi
rm -f "$ledger_existing" "$ledger_file"
echo "[CONTEXT] REJECTED_LEDGER_PRESERVE=ok" >&2
record_rc=0
bash "$plugin_root"/hooks/review-nonblocking-record.sh \
  --pr "${pr_number}" --owner-repo "${owner_repo}" \
  --count "$non_blocking_count" --iteration-id "${review_cycle_id}" \
  --content-file "$record_body" 2> "$record_log" || record_rc=$?
neutralize_ctrl --keep-newline < "$record_log" >&2
# helper は failed でも rc=0 を返しうる。終端 outcome を必ず検査する。
record_done=$(sed -n 's/^\[CONTEXT\] NONBLOCKING_RECORD_DONE=1; .*outcome=\([^;]*\);.*/\1/p' "$record_log" | tail -1)
record_ok=0
if [ "$record_rc" -eq 0 ]; then
  case "$record_done" in
    created|updated) record_ok=1 ;;
    skipped) [ "$non_blocking_count" -eq 0 ] && record_ok=1 ;;
  esac
fi
rm -f "$record_body" "$record_log"
if [ "$record_ok" -ne 1 ]; then
  echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=nonblocking_record_failed" >&2
  echo "[fix:error] reason=nonblocking_record_failed"
  exit 1
fi
}

# --- nb-sweep-collect -----------------------------------------------------------
step_nb_sweep_collect() {
# iterate 5.S と同じ collect helper（冪等）
source "$plugin_root"/hooks/scripts/lib/context-marker.sh || { echo "ERROR: context-marker.sh を読み込めませんでした" >&2; echo "[fix:error]"; exit 1; }
sweep_root=$(bash "$plugin_root"/hooks/state-path-resolve.sh) || sweep_root=""
if [ -z "$sweep_root" ]; then
  echo "ERROR: state-path-resolve が空。NB sweep 対象を取得できない" >&2
  echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=nb_sweep_state_root_unresolved" >&2
  echo "[fix:error]"
  exit 1
fi
collect_err=$(mktemp "${TMPDIR:-/tmp}/rite-fix-nb-collect-XXXXXX") || { echo "[fix:error]"; exit 1; }
collect_out=$(bash "$plugin_root"/hooks/scripts/nb-sweep-collect.sh --pr "${pr_number}" --state-root "$sweep_root" 2>"$collect_err") || collect_rc=$?
collect_rc=${collect_rc:-0}
neutralize_ctrl --keep-newline < "$collect_err" >&2
rm -f -- "$collect_err"
sweep_status=$(printf '%s' "$collect_out" | jq -r '.status // empty') || sweep_status=""
nb_record=$(printf '%s' "$collect_out" | jq -r '.record // empty')
nb_record_base=""
[ -n "$nb_record" ] && nb_record_base=$(basename "$nb_record")
# 残っている entries は台帳 persist で止まった sweep のもので、起票済みの件数を持つ。
# 今回読んだ review JSON の sweep のものでなければ、起票済みの代わりにも今回の件数にもせずに止まる。
nb_entries_file="$sweep_root/.rite/state/nb-sweep-entries-${pr_number}.md"
nb_counts=""
if [ "$collect_rc" -eq 0 ] && [ -f "$nb_entries_file" ]; then
  nb_counts=$(bash "$plugin_root"/hooks/scripts/nb-sweep-ledger.sh tally --entries-file "$nb_entries_file" \
    --record "$nb_record_base") || {
    echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=nb_sweep_entries_stale" >&2
    echo "[fix:error] reason=nb_sweep_entries_stale"; exit 1
  }
fi
case "$collect_rc:$sweep_status" in
  0:empty)
    nb_kind=noop
    [ -n "$nb_counts" ] && nb_kind=done
    echo "[CONTEXT] NB_SWEEP_RESULT=done; ${nb_counts:-issued=0; recorded=0}" >&2
    mkdir -p "$sweep_root/.rite/state" || true
    source "$plugin_root"/hooks/gitignore-ensure.sh
    if ! _ensure_dir_gitignore "$sweep_root/.rite/state"; then
      echo "WARNING: $sweep_root/.rite/state/.gitignore を作成できませんでした。nb-sweep-done が git の追跡対象になる恐れがあります" >&2
      [ -n "${_RITE_GITIGNORE_ERROR:-}" ] && printf '%s\n' "$_RITE_GITIGNORE_ERROR" | sed 's/^/  /' >&2
    fi
    nb_done_file="$sweep_root/.rite/state/nb-sweep-done-${pr_number}.txt"
    # 台帳に全件載っている。前回の sweep の entries は戻り先として不要
    rm -f "$nb_entries_file"
    nb_keep=""
    if [ -f "$nb_done_file" ]; then
      nb_keep=$(sed -n '2p' "$nb_done_file" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
      case "$nb_keep" in ''|*[!0-9a-f]*) nb_keep="" ;; esac
      [ "${#nb_keep}" -ge 7 ] || nb_keep=""
    fi
    if [ -n "$nb_keep" ]; then
      nb_write_ok=$(printf '%s %s\n%s\n' "$nb_kind" "$nb_record_base" "$nb_keep" > "$nb_done_file" && echo ok || true)
    else
      nb_write_ok=$(printf '%s %s\n' "$nb_kind" "$nb_record_base" > "$nb_done_file" && echo ok || true)
    fi
    if [ -z "$nb_record_base" ] || [ "$nb_write_ok" != ok ]; then
      echo "WARNING: nb-sweep-done marker を書けませんでした" >&2
      rm -f "$sweep_root/.rite/state/nb-sweep-done-${pr_number}.txt"
    fi
    ;;
  0:ok)
    if [ -n "$nb_counts" ]; then
      echo "[CONTEXT] NB_SWEEP_ENTRIES=present; path=$nb_entries_file" >&2
    else
      echo "[CONTEXT] NB_SWEEP_ENTRIES=absent; path=$nb_entries_file" >&2
    fi
    printf '%s\n' "$collect_out"
    ;;
  *)
    echo "ERROR: NB sweep collect failed (rc=$collect_rc status=${sweep_status:-})" >&2
    echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=nb_sweep_collect_failed" >&2
    echo "[fix:error]"
    exit 1
    ;;
esac
}

# --- nb-sweep-gate --------------------------------------------------------------
step_nb_sweep_gate() {
# collect をもう一度実行し、candidates[] から候補ファイルを作って採否ゲートを呼ぶ
sweep_root=$(bash "$plugin_root"/hooks/state-path-resolve.sh) || sweep_root=""
if [ -z "$sweep_root" ] || ! collect_out=$(bash "$plugin_root"/hooks/scripts/nb-sweep-collect.sh --pr "${pr_number}" --state-root "$sweep_root"); then
  echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=nb_sweep_collect_failed" >&2
  echo "[fix:error]"; exit 1
fi
nb_candidates=$(mktemp "${TMPDIR:-/tmp}/rite-nb-candidates-XXXXXX") || { echo "[fix:error]"; exit 1; }
trap 'rm -f "$nb_candidates"' EXIT
printf '%s' "$collect_out" | jq '{candidates: .candidates}' > "$nb_candidates" \
  || { echo "[fix:error]"; exit 1; }
gate_rc=0
# 候補 0 件（already_rejected だけ）でもゲートを呼ぶ（前回の保留候補が今回の候補から消えていれば保留する）
nb_issue=$(git branch --show-current 2>/dev/null | grep -oE 'issue-[0-9]+' | grep -oE '[0-9]+' | head -1)
gate_out=$(bash "$plugin_root"/hooks/scripts/review-adoption-gate.sh --pr "${pr_number}" --kind sweep \
  --state-root "$sweep_root" --candidates "$nb_candidates" \
  --review-result "$(printf '%s' "$collect_out" | jq -r '.record')" \
  --base "origin/${base_branch}" --owner-repo "${owner_repo}" ${nb_issue:+--issue "$nb_issue"}) || gate_rc=$?
case "$gate_rc" in
  0) ;;
  3)
    echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=nb_sweep_adoption_held" >&2
    echo "[fix:error] reason=nb_sweep_adoption_held"; exit 1 ;;
  *)
    echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=nb_sweep_adoption_gate_failed" >&2
    echo "[fix:error] reason=nb_sweep_adoption_gate_failed"; exit 1 ;;
esac
# verdict が欠落・未知値なら、起票も台帳 persist も始めない
if ! printf '%s' "$gate_out" | jq -e '.held == false and (.verdicts | type) == "array"
    and all(.verdicts[]; .verdict == "file" or .verdict == "record")' >/dev/null 2>&1; then
  echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=nb_sweep_verdict_invalid" >&2
  echo "[fix:error] reason=nb_sweep_verdict_invalid"; exit 1
fi
printf '%s\n' "$gate_out"
}

# --- nb-sweep-file-issue --------------------------------------------------------
step_nb_sweep_file_issue() {
# verdict=file の記録 1 件を起票し、起票した番号を判定記録の tracker に書き戻す。
# タイトルと本文は caller が Write tool で作業ツリー外に置いたファイル。
issue_title=""
[ -r "$issue_title_file" ] && issue_title=$(head -n 1 -- "$issue_title_file")
if [ -z "$issue_title" ] || [ ! -s "$issue_body_file" ]; then
  echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=nb_sweep_issue_body_failed" >&2
  echo "[fix:error]"
  exit 1
fi
issue_args=$(jq -n \
  --arg title "$issue_title" \
  --arg body_file "$issue_body_file" \
  --argjson projects_enabled "${projects_enabled}" \
  --argjson project_number "${project_number}" \
  --arg owner "${project_owner}" \
  --arg complexity "S" \
  '{
    issue: { title: $title, body_file: $body_file },
    projects: { enabled: $projects_enabled, project_number: $project_number, owner: $owner, status: "todo", complexity: $complexity, iteration: { mode: "none" } },
    options: { source: "pr_review", non_blocking_projects: true }
  }') || { echo "[fix:error]"; exit 1; }
if ! issue_result=$(bash "$plugin_root"/scripts/create-issue-with-projects.sh "$issue_args") ||
   ! printf '%s' "$issue_result" | jq -e '.issue_number > 0 and (.issue_url | type == "string" and length > 0)' >/dev/null; then
  echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=nb_sweep_issue_failed" >&2
  echo "[fix:error]"
  exit 1
fi
# 起票した番号を判定記録の tracker に書き戻す。途中で止まって再実行すると、ゲートはこの記録を LINK にし、同じ根因を二度起票しない
nb_adoption="$(bash "$plugin_root"/hooks/state-path-resolve.sh)/.rite/state/adoption-${pr_number}-sweep.json"
nb_issue_number=$(printf '%s' "$issue_result" | jq '.issue_number')
if ! jq --argjson ids "$record_ids" --argjson n "$nb_issue_number" \
     'if any(.adoption.records[]; .ids == $ids) then (.adoption.records[] | select(.ids == $ids) | .tracker) = $n
      else error("ids \($ids) の記録がありません") end' "$nb_adoption" > "$nb_adoption.tmp" ||
   ! mv -- "$nb_adoption.tmp" "$nb_adoption"; then
  rm -f -- "$nb_adoption.tmp"
  echo "ERROR: 起票した #$nb_issue_number を $nb_adoption の記録の tracker に書き戻せません。書き戻してから再実行する（書かずに再実行すると同じ根因を二度起票する）" >&2
  echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=nb_sweep_tracker_write_failed" >&2
  echo "[fix:error]"; exit 1
fi
printf '%s\n' "$issue_result"
}

# --- nb-sweep-persist -----------------------------------------------------------
step_nb_sweep_persist() {
# 全 target と already_rejected を却下台帳へ記録する
sweep_root=$(bash "$plugin_root"/hooks/state-path-resolve.sh) || sweep_root=""
entries_file="$sweep_root/.rite/state/nb-sweep-entries-${pr_number}.md"
if [ -z "$sweep_root" ] || [ ! -s "$entries_file" ]; then
  echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=nb_sweep_entries_missing" >&2
  echo "[fix:error]"; exit 1
else
  ledger=$(mktemp "${TMPDIR:-/tmp}/rite-nb-ledger-XXXXXX") || { echo "[fix:error]"; exit 1; }
  body=$(mktemp "${TMPDIR:-/tmp}/rite-nb-body-XXXXXX") || { echo "[fix:error]"; exit 1; }
  # 既存本文は記録 helper が PATCH する 1 件を、同じ helper の読み取り専用モードで読む（関連 Issue の解決も helper が行う）
  bash "$plugin_root"/hooks/review-nonblocking-record.sh --print-record-body \
    --pr "${pr_number}" --owner-repo "${owner_repo}" > "$body" || {
    echo "ERROR: 6.1.d コメント取得失敗" >&2
    echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=nb_sweep_ledger_fetch_failed" >&2
    echo "[fix:error]"; exit 1
  }
  if [ ! -s "$body" ]; then
    printf '%s\n\n%s\n\n%s\n%s\n\n%s\n' \
      '## 📜 rite 非実測指摘の記録 (non-blocking)' \
      '本 cycle の非実測指摘: 0 件 (前 cycle の記録内容は本 cycle では再報告されていません)' \
      '📎 non_blocking_count: 0' \
      '📎 reviewed_commit: unknown' \
      '<!-- rite:nbr:v1 -->' > "$body"
  fi
  bash "$plugin_root"/hooks/scripts/nb-sweep-ledger.sh extract --body-file "$body" > "$ledger" || {
    echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=nb_sweep_ledger_extract_failed" >&2
    echo "[fix:error]"; exit 1
  }
  bash "$plugin_root"/hooks/scripts/nb-sweep-ledger.sh append --ledger-file "$ledger" --entries-file "$entries_file" || {
    echo "ERROR: 却下台帳 append 失敗" >&2
    echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=nb_sweep_ledger_append_failed" >&2
    echo "[fix:error]"; exit 1
  }
  bash "$plugin_root"/hooks/scripts/nb-sweep-ledger.sh merge-into --body-file "$body" --ledger-file "$ledger" || {
    echo "ERROR: 却下台帳 merge-into 失敗" >&2
    echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=nb_sweep_ledger_merge_failed" >&2
    echo "[fix:error]"; exit 1
  }
  # 抽出式は review-nonblocking-record.sh の count/body 整合検査と同一にする。この値は直下で
  # 同 helper へ `--count` として渡され、helper が同じ行を再検証するため、述語がずれると
  # producer が通した body を validator が count_body_mismatch で落とす経路が生まれる。
  # awk のフィールド番号で取ってはならない — 行頭の 📎 が第 1 フィールドを占める。
  body_count=$(grep -E '^📎 non_blocking_count:[[:space:]]*[0-9]+[[:space:]]*$' "$body" | tail -1 | grep -oE '[0-9]+')
  case "$body_count" in ''|*[!0-9]*)
    echo "ERROR: merge-into 後の non_blocking_count が読めない" >&2
    echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=nb_sweep_ledger_count_unreadable" >&2
    echo "[fix:error]"; exit 1
    ;;
  esac
  record_err=$(mktemp "${TMPDIR:-/tmp}/rite-nb-record-XXXXXX") || { echo "[fix:error]"; exit 1; }
  bash "$plugin_root"/hooks/review-nonblocking-record.sh \
    --pr "${pr_number}" --owner-repo "${owner_repo}" --count "$body_count" \
    --iteration-id "nb-sweep-${pr_number}" --content-file "$body" 2>"$record_err"
  record_rc=$?
  neutralize_ctrl --keep-newline < "$record_err" >&2
  record_outcome=$(sed -n 's/^\[CONTEXT\] NONBLOCKING_RECORD_DONE=1; .*outcome=\([^;]*\);.*/\1/p' "$record_err" | tail -1)
  # entries は常に 1 件以上あるため、skipped は台帳が投稿されなかったことを意味する
  case "$record_rc:$record_outcome" in
    0:created|0:updated) ;;
    *)
      echo "ERROR: 却下台帳 記録失敗 (rc=$record_rc outcome=${record_outcome:-<欠落>})" >&2
      echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=nb_sweep_ledger_record_failed" >&2
      echo "[fix:error]"; exit 1
      ;;
  esac
  rm -f -- "$record_err"
  # 外部への書き込みはすべて済んだ。持ち越した保留候補はもう要らないので sweep の hold を消す
  rm -f -- "$sweep_root/.rite/state/adoption-hold-${pr_number}-sweep.json"
fi
}

# --- nb-sweep-finish ------------------------------------------------------------
step_nb_sweep_finish() {
# entries の判定列から件数を数え、done の 1 行目を最新 review JSON の basename で書く
sweep_root=$(bash "$plugin_root"/hooks/state-path-resolve.sh) || sweep_root=""
if [ -n "$sweep_root" ]; then
  mkdir -p "$sweep_root/.rite/state" || true
  source "$plugin_root"/hooks/gitignore-ensure.sh
  if ! _ensure_dir_gitignore "$sweep_root/.rite/state"; then
    echo "WARNING: $sweep_root/.rite/state/.gitignore を作成できませんでした。nb-sweep-done が git の追跡対象になる恐れがあります" >&2
    [ -n "${_RITE_GITIGNORE_ERROR:-}" ] && printf '%s\n' "$_RITE_GITIGNORE_ERROR" | sed 's/^/  /' >&2
  fi
  sweep_done_file="$sweep_root/.rite/state/nb-sweep-done-${pr_number}.txt"
  nb_record=$(find "$sweep_root/.rite/review-results" -maxdepth 1 -type f -name "${pr_number}-*.json" 2>/dev/null | LC_ALL=C sort | tail -1)
  nb_record_base=""
  [ -n "$nb_record" ] && nb_record_base=$(basename "$nb_record")
  nb_keep=""
  if [ -f "$sweep_done_file" ]; then
    nb_keep=$(sed -n '2p' "$sweep_done_file" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
    case "$nb_keep" in ''|*[!0-9a-f]*) nb_keep="" ;; esac
    [ "${#nb_keep}" -ge 7 ] || nb_keep=""
  fi
  if [ -n "$nb_keep" ]; then
    nb_write_ok=$(printf 'done %s\n%s\n' "$nb_record_base" "$nb_keep" > "$sweep_done_file" && echo ok || true)
  else
    nb_write_ok=$(printf 'done %s\n' "$nb_record_base" > "$sweep_done_file" && echo ok || true)
  fi
  if [ -z "$nb_record_base" ] || [ "$nb_write_ok" != ok ]; then
    echo "WARNING: nb-sweep-done marker を書けませんでした" >&2
    rm -f "$sweep_done_file"
  fi
  entries_file="$sweep_root/.rite/state/nb-sweep-entries-${pr_number}.md"
  if nb_counts=$(bash "$plugin_root"/hooks/scripts/nb-sweep-ledger.sh tally --entries-file "$entries_file"); then
    echo "[CONTEXT] NB_SWEEP_RESULT=done; $nb_counts" >&2
    rm -f "$entries_file"
  else
    echo "[CONTEXT] FIX_FALLBACK_FAILED=1; reason=nb_sweep_entries_tally_failed" >&2
  fi
fi
}

# --- wiki-trigger ---------------------------------------------------------------
step_wiki_trigger() {
# fix の Raw Source を生成して wiki-ingest-trigger.sh へ渡す（非ブロッキング）。
# 本文とタイトルは caller が Write tool で書いたファイル。本文は写さずに trigger へ渡し、
# trigger 自身の symlink 拒否とパス allowlist ($PWD 配下・/tmp/rite-*・$TMPDIR/rite-*) を caller のパスに効かせる。
trigger_stderr=$(mktemp "${TMPDIR:-/tmp}/rite-wiki-trigger-err-XXXXXX") || trigger_stderr=/dev/null
# rm -f /dev/null は EPERM (exit 1) を返すため trap で条件分岐する
trap '[ "$trigger_stderr" != "/dev/null" ] && rm -f "$trigger_stderr"' EXIT
content_write_failed=0  # 入力不在フラグ (wiki-trigger-result で genuine trigger 失敗と区別するため carry-forward)
wiki_title=""
[ -r "$title_file" ] && wiki_title=$(head -n 1 -- "$title_file")

# 入力の不在・空で空の raw source が ingest されるのを防ぐ。wiki ingest は非ブロッキングのため ingest をスキップ
if [ -z "$wiki_title" ] || [ ! -s "$content_file" ]; then
  echo "[CONTEXT] WIKI_CONTENT_WRITE_FAILED=1; reason=input_file_missing" >&2
  echo "WARNING: fix ステップ 4.6.W: 本文またはタイトルのファイルが無いか空 (content=$content_file, title=$title_file)。wiki ingest を非ブロッキングにスキップ。" >&2
  trigger_exit=1
  content_write_failed=1
  echo "trigger_exit=$trigger_exit"
else
  bash "$plugin_root"/hooks/wiki-ingest-trigger.sh \
    --type fixes \
    --source-ref "pr-${pr_number}" \
    --content-file "$content_file" \
    --pr-number "${pr_number}" \
    --title "${wiki_title}（修正結果）" \
    2>"$trigger_stderr"
  trigger_exit=$?
  echo "trigger_exit=$trigger_exit"
  if [ "$trigger_exit" -ne 0 ] && [ "$trigger_stderr" != "/dev/null" ] && [ -s "$trigger_stderr" ]; then
    # UTF-8 multi-byte 境界を safe にする (head -c 500 で切れた invalid sequence を drop)
    # iconv 不在環境 (Alpine 等) では LC_ALL=C tr で ASCII-only fallback
    # 制御文字は --keep-newline で中和する (UTF-8 の文字を ? に潰さないため。改行は tr で空白化済み)
    if command -v iconv >/dev/null 2>&1; then
      _wiki_err_snippet=$(tr '\n' ' ' < "$trigger_stderr" | head -c 500 | iconv -c -f UTF-8 -t UTF-8 2>/dev/null | neutralize_ctrl --keep-newline)
    else
      _wiki_err_snippet=$(tr '\n' ' ' < "$trigger_stderr" | head -c 500 | LC_ALL=C tr -cd '\11\12\15\40-\176' | neutralize_ctrl --keep-newline)
    fi
    echo "[CONTEXT] WIKI_TRIGGER_STDERR=${_wiki_err_snippet}" >&2
  fi
fi
echo "content_write_failed=$content_write_failed"
}

# --- wiki-trigger-result --------------------------------------------------------
step_wiki_trigger_result() {
if [ "${content_write_failed:-0}" -eq 1 ]; then
  # write 失敗経路: trigger は未起動。gate (ステップ 5.0) は WIKI_INGEST_* のみ認識するため
  # accurate な reason を付けて WIKI_INGEST_FAILED を emit する (trigger_exit_1 への誤帰属を防ぐ)。
  echo "[CONTEXT] WIKI_INGEST_FAILED=1; reason=content_write_failed; exit_code=1"
  echo "WARNING: fix ステップ 4.6.W: content write 失敗のため wiki ingest をスキップ (trigger は未起動)。" >&2
elif [ "${trigger_exit:-1}" -ne 0 ] && [ "${trigger_exit:-1}" -ne 2 ]; then
  echo "[CONTEXT] WIKI_INGEST_FAILED=1; reason=trigger_exit_$trigger_exit; exit_code=$trigger_exit"
  echo "WARNING: wiki-ingest-trigger.sh exited $trigger_exit during skills/fix/SKILL.md ステップ 4.6.W" >&2
fi
}

# --- wiki-raw-commit ------------------------------------------------------------
step_wiki_raw_commit() {
# raw source だけを wiki ブランチへ commit する（page 統合は /rite:wiki-ingest）。
# コミットメッセージは caller が Write tool で作業ツリー外に置いたファイル。
commit_err=""
_rite_wic_commit_cleanup() {
  rm -f "${commit_err:-}"
}
trap '_rite_wic_commit_cleanup' EXIT INT TERM HUP

# mktemp failure must NOT silently swallow wiki-ingest-commit.sh stderr (review / fix / close で対称)。
# rc 捕捉は `if cmd; then :; else rc=$?; fi` 形式 (「!」否定は $? を反転するため使用禁止)
# rationale: skills/fix/references/design-rationale.md#wiki-ingest-notes
if commit_err=$(mktemp "${TMPDIR:-/tmp}/rite-wiki-commit-err-XXXXXX" 2>/dev/null); then
  : # mktemp 成功 — commit_err は valid path
else
  mktemp_commit_err_rc=$?
  echo "WARNING: mktemp failed for wiki-ingest-commit stderr capture (rc=$mktemp_commit_err_rc) — script stderr will be suppressed" >&2
  echo "  hint: check /tmp permission / disk space / inode exhaustion" >&2
  commit_err="/dev/null"
fi
wiki_ingest_commit_rc=0
wiki_push_attempt="fix-${pr_number}-$(date +%s)-$$-$RANDOM"
echo "[CONTEXT] WIKI_PUSH_ATTEMPT=$wiki_push_attempt; source=fix; pr=${pr_number}"
if [ ! -s "$message_file" ]; then
  echo "WARNING: コミットメッセージのファイルを読めません ($message_file)。wiki ingest commit をスキップします" >&2
  echo "[CONTEXT] WIKI_INGEST_FAILED=1; reason=msg_file_missing; exit_code=1"
else
case "$(cat -- "$message_file")" in
  "{"*"}")
    echo "ERROR: Wiki コミットメッセージの placeholder が未置換です" >&2
    echo "[CONTEXT] WIKI_INGEST_FAILED=1; reason=msg_placeholder_residue; exit_code=1"
    exit 1
    ;;
esac
if commit_out=$(bash "$plugin_root"/hooks/scripts/wiki-ingest-commit.sh --message-file "$message_file" 2>"${commit_err}"); then
  # Success — the script prints exactly one status line to stdout, e.g.
  #   [wiki-ingest-commit] committed=1; branch=wiki; head=<sha>; push=ok
  #   [wiki-ingest-commit] committed=0; branch=wiki; reason=no-pending
  echo "$commit_out"
  echo "[CONTEXT] WIKI_INGEST_DONE=1; pr=${pr_number}; type=fixes; attempt=$wiki_push_attempt"
else
  wiki_ingest_commit_rc=$?
  if [ "$commit_err" != "/dev/null" ] && [ -s "$commit_err" ]; then
    head -5 "$commit_err" | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
  fi
  # exit 2 = legitimate skip / exit 4 = commit landed but push failed (observable に surface する)
  case "$wiki_ingest_commit_rc" in
    2)
      echo "[CONTEXT] WIKI_INGEST_SKIPPED=1; reason=commit_branch_missing; exit_code=$wiki_ingest_commit_rc"
      echo "WARNING: wiki-ingest-commit.sh exited 2 (wiki branch missing / disabled) during skills/fix/references/wiki-recording.md ステップ 4.6.W.2" >&2
      ;;
    4)
      echo "[CONTEXT] WIKI_INGEST_PUSH_FAILED=1; reason=commit_rc_4; exit_code=$wiki_ingest_commit_rc; pr=${pr_number}; attempt=$wiki_push_attempt"
      if [ -n "${commit_out:-}" ]; then
        echo "$commit_out"
      fi
      echo "WARNING: wiki-ingest-commit.sh exited 4 (commit landed locally, push failed) during skills/fix/references/wiki-recording.md ステップ 4.6.W.2" >&2
      ;;
    *)
      echo "[CONTEXT] WIKI_INGEST_FAILED=1; reason=commit_rc_$wiki_ingest_commit_rc; exit_code=$wiki_ingest_commit_rc"
      echo "WARNING: wiki-ingest-commit.sh exited $wiki_ingest_commit_rc during skills/fix/references/wiki-recording.md ステップ 4.6.W.2" >&2
      ;;
  esac
fi
fi
[ "$commit_err" != "/dev/null" ] && rm -f "$commit_err"
commit_err=""
trap - EXIT INT TERM HUP
}

# --- wiki-push-retry ------------------------------------------------------------
step_wiki_push_retry() {
# caller は直前の wiki-raw-commit が exit 4 のときだけ、dangerouslyDisableSandbox で 1 回呼ぶ
if retry_out=$(bash "$plugin_root"/hooks/scripts/wiki-ingest-commit.sh --push-only 2>&1); then
  echo "$retry_out"
  echo "[CONTEXT] WIKI_INGEST_PUSH_RETRY=ok; source=fix; pr=${pr_number}; attempt=${attempt}"
else
  retry_rc=$?
  printf '%s\n' "$retry_out" | head -5 | neutralize_ctrl --keep-newline | sed 's/^/  /' >&2
  echo "[CONTEXT] WIKI_INGEST_PUSH_RETRY=failed; source=fix; pr=${pr_number}; attempt=${attempt}; exit_code=$retry_rc"
fi
}

# --- dispatch ----------------------------------------------------------------
[ "$#" -ge 1 ] || usage_error "subcommand is required"
subcommand=$1
shift

# 受け付けるオプション。`--pr` / `--issue` 以外は、オプション名の `-` を `_` にした変数へ入る。
options=" pr issue owner repo owner-repo keywords changed-paths arguments head-ref review-file-path
  conversation-decision p1-scan-turns p1-scan-found target-comment-id review-source review-source-path
  reviewed-commit-sha materialized-json triage-review-path triage-helper-source non-fatal-moved-count
  fix-plan-file fix-issue-file symbol comment-id reply-body-file findings-addressed-file base-branch
  changed-files fix-cycle-base-sha findings-fixed-count propagation-applied-count thread-id
  pr-body-file history-file impl-status test-status doc-status reason status result
  finding-file review-cycle-id issue-title-file issue-body-file record-ids projects-enabled
  project-number project-owner content-file title-file content-write-failed trigger-exit
  message-file attempt "
option_var() {
  case "$1" in
    pr) echo pr_number ;;
    issue) echo issue_number ;;
    *) echo "${1//-/_}" ;;
  esac
}
for opt in $options; do
  printf -v "$(option_var "$opt")" '%s' ""
done
given=" "
while [ "$#" -gt 0 ]; do
  [ "$#" -ge 2 ] || usage_error "$1 requires a value"
  case "$2" in
    '{'*'}') usage_error "$1 received an unsubstituted placeholder: $2" ;;
    '$ARGUMENTS') usage_error "$1 received an unexpanded \$ARGUMENTS" ;;
  esac
  name=${1#--}
  case "$1" in
    --*) case "$options" in *[[:space:]]"$name"[[:space:]]*) ;; *) usage_error "unknown option: $1" ;; esac ;;
    *) usage_error "unknown option: $1" ;;
  esac
  printf -v "$(option_var "$name")" '%s' "$2"
  given="$given$name "
  shift 2
done
for opt in pr issue non-fatal-moved-count comment-id findings-fixed-count propagation-applied-count \
  trigger-exit; do
  var=$(option_var "$opt")
  case "${!var}" in
    ''|*[!0-9]*) [ -z "${!var}" ] || usage_error "--$opt must be a number: ${!var}" ;;
  esac
done

# 値が必須のオプション。
require() {
  local opt var
  for opt in "$@"; do
    var=$(option_var "$opt")
    [ -n "${!var}" ] || usage_error "$subcommand requires --$opt"
  done
}
# 空の値も意味を持つオプション（例: 空の changed-paths は --paths を省く）は、渡されたことだけを要求する。
require_given() {
  local opt
  for opt in "$@"; do
    case "$given" in *" $opt "*) ;; *) usage_error "$subcommand requires --$opt" ;; esac
  done
}
one_of() {
  local value=$1 opt=$2
  shift 2
  local allowed
  for allowed in "$@"; do
    [ "$value" = "$allowed" ] && return 0
  done
  usage_error "--$opt must be one of: $*"
}

case "$subcommand" in
  load-work-memory) step_load_work_memory ;;
  wiki-query-config) step_wiki_query_config ;;
  wiki-capture) require keywords; require_given changed-paths; step_wiki_capture ;;
  parse-args) require_given arguments; step_parse_args ;;
  resolve-owner-repo) step_resolve_owner_repo ;;
  pr-view) require owner-repo; step_pr_view ;;
  ensure-worktree) require head-ref; step_ensure_worktree ;;
  resolve-review-source)
    require pr review-file-path conversation-decision p1-scan-turns p1-scan-found target-comment-id
    step_resolve_review_source ;;
  gate-receipt) require review-source; require_given review-source-path; step_gate_receipt ;;
  p3-raw-json) require pr; step_p3_raw_json ;;
  fallback-abort)
    require reason
    one_of "$reason" reason user_cancelled user_file_path_invalid
    step_fallback_abort ;;
  broad-retrieval) require pr owner repo owner-repo; step_broad_retrieval ;;
  review-threads) require pr owner repo; step_review_threads ;;
  conversation-review-json) require pr reviewed-commit-sha; step_conversation_review_json ;;
  explicit-review-json) require review-source-path materialized-json; step_explicit_review_json ;;
  triage) require triage-review-path triage-helper-source; step_triage ;;
  triage-state) require pr non-fatal-moved-count triage-review-path; step_triage_state ;;
  cancel-cleanup) require pr; require_given target-comment-id; step_cancel_cleanup ;;
  cancelled-by-user) step_cancelled_by_user ;;
  fast-path-cleanup) require pr; require_given target-comment-id; step_fast_path_cleanup ;;
  stagnation-replan) require fix-plan-file fix-issue-file; step_stagnation_replan ;;
  scope-check) require fix-plan-file fix-issue-file; step_scope_check ;;
  impact-scan) require symbol; step_impact_scan ;;
  reply-post) require pr owner repo comment-id reply-body-file; step_reply_post ;;
  scope-verify) require fix-plan-file fix-issue-file; step_scope_verify ;;
  commit-guard) step_commit_guard ;;
  skip-cycle-state)
    require pr findings-addressed-file non-fatal-moved-count triage-review-path
    step_skip_cycle_state ;;
  cycle-base-sha) step_cycle_base_sha ;;
  show-changes) step_show_changes ;;
  number-ref-check) require base-branch; require_given changed-files; step_number_ref_check ;;
  schema-drift-check) step_schema_drift_check ;;
  root-cause-gate)
    require status
    one_of "$status" status ok missing
    step_root_cause_gate ;;
  cycle-state)
    require pr fix-cycle-base-sha findings-addressed-file findings-fixed-count propagation-applied-count \
      non-fatal-moved-count triage-review-path
    step_cycle_state ;;
  push) step_push ;;
  resolve-thread) require thread-id; step_resolve_thread ;;
  wm-update)
    require_given pr-body-file history-file
    require impl-status test-status doc-status
    step_wm_update ;;
  accept-count) require pr; step_accept_count ;;
  wiki-ingest-check) step_wiki_ingest_check ;;
  output-handoff)
    require pr result
    one_of "$result" result pushed pushed-wm-stale non-fatal-only replied-only sweep-done error
    step_output_handoff ;;
  local-wm-sync) require_given issue; step_local_wm_sync ;;
  nb-sweep-done-file) require pr; step_nb_sweep_done_file ;;
  override-cleanup) require pr; step_override_cleanup ;;
  target-comment-fetch) require owner-repo pr target-comment-id; step_target_comment_fetch ;;
  override-read) require pr; step_override_read ;;
  accept-persist) require pr finding-file; step_accept_persist ;;
  non-fatal-record)
    require pr owner-repo triage-review-path non-fatal-moved-count review-cycle-id
    step_non_fatal_record ;;
  nb-sweep-collect) require pr; step_nb_sweep_collect ;;
  nb-sweep-gate) require pr base-branch owner-repo; step_nb_sweep_gate ;;
  nb-sweep-file-issue)
    require pr issue-title-file issue-body-file record-ids projects-enabled project-number project-owner
    one_of "$projects_enabled" projects-enabled true false
    jq -e 'type == "array"' <<< "$record_ids" >/dev/null 2>&1 || usage_error "--record-ids must be a JSON array: $record_ids"
    step_nb_sweep_file_issue ;;
  nb-sweep-persist) require pr owner-repo; step_nb_sweep_persist ;;
  nb-sweep-finish) require pr; step_nb_sweep_finish ;;
  wiki-trigger) require pr content-file title-file; step_wiki_trigger ;;
  wiki-trigger-result)
    require content-write-failed trigger-exit
    one_of "$content_write_failed" content-write-failed 0 1
    step_wiki_trigger_result ;;
  wiki-raw-commit) require pr message-file; step_wiki_raw_commit ;;
  wiki-push-retry) require pr attempt; step_wiki_push_retry ;;
  *) usage_error "unknown subcommand: $subcommand" ;;
esac
